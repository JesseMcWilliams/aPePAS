#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Disable User'
    Category         = 'Users'
    Action           = 'Disable'
    Description      = 'Disable a Vault user so they can no longer log on (the user is kept).'
    # POST /API/Users/{id}/disable: PVWA 14.6 Swagger and psPAS Disable-PASUser (12.6+). Self-Hosted
    # only: no reference shows it on Privilege Cloud, where most users live in CyberArk Identity.
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'UserID';   Required = $false; Description = 'Numeric user ID (from List Users). Give this or Username. When set, Username is ignored.' }
        @{ Column = 'Username'; Required = $false; Description = 'Exact username. Resolved to a user ID; the row fails when no user or more than one user matches.' }
    )
    Priority         = 54
    Version          = '1.0.0'
}

function Get-UsersDisableInput {
    <#
        Called by the driver when HasCustomInput = $true.
        Show-FieldPrompt is available because this module is dot-sourced into the driver scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  User to Disable' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  WARNING: The user can''t log on until they are enabled again (Enable User).' -ForegroundColor Red
    Write-Host ''

    $userID = Show-FieldPrompt -Label 'User ID' `
        -Default $(if ($Defaults['UserID']) { $Defaults['UserID'] } else { '' }) `
        -Description 'Numeric user ID to disable, or leave blank to search by username.'

    if (-not $userID) {
        $searchTerm = Show-FieldPrompt -Label 'Search' -Description 'Username or name to search for.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $userID = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/Users' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'Users' `
                -IdProperty 'id' `
                -DisplayProperties @('username', 'userType', 'source') `
                -EntityLabel 'user' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $userID) { return $null }
    }

    return @{
        UserID = $userID
    }
}

function Invoke-UsersDisable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token,

        [Parameter(Mandatory = $false)]
        [hashtable]$InputData,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $result = [PSCustomObject]@{
        ModuleName     = $ModuleMeta.Name
        Category       = $ModuleMeta.Category
        Action         = $ModuleMeta.Action
        ItemsProcessed = 0
        Successes      = 0
        Failures       = 0
        IsFatal        = $false
        Results        = [System.Collections.Generic.List[PSCustomObject]]::new()
        Errors         = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    if (-not $InputData) { $InputData = @{} }

    $enable = $false

    $addError = {
        param([string]$Message, $Details, [int]$StatusCode = -1)
        Write-CyberArkLog -Level 'ERROR' -Message $Message
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $Message; ErrorDetails = $Details })
        $result.Failures++
        $result.ItemsProcessed++
        if ($StatusCode -in @(401, 0)) { $result.IsFatal = $true }
    }

    # ── Identify the user ─────────────────────────────────────────────────────

    $ident = Get-CyberArkUserIdentifier -InputData $InputData
    if ($ident.ErrorMessage) { & $addError $ident.ErrorMessage $null; return $result }

    $userId   = $ident.UserID
    $userName = $ident.Username

    if ($ident.NeedsLookup) {
        Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Users?search=$userName (resolve Username to UserID)"
        $lookupResp = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/Users' -QueryParams @{ search = $userName }
        if (-not $lookupResp.IsSuccess) {
            & $addError "User lookup for '$userName' failed (HTTP $($lookupResp.StatusCode)): $($lookupResp.ErrorMessage)" $lookupResp.ErrorDetails $lookupResp.StatusCode
            return $result
        }
        [array]$userList = @(if ($lookupResp.Data -and $lookupResp.Data.PSObject.Properties['Users'] -and $null -ne $lookupResp.Data.Users) { $lookupResp.Data.Users })
        $match = Select-CyberArkUserMatch -Users $userList -Username $userName
        if ($match.ErrorMessage) { & $addError $match.ErrorMessage $null; return $result }
        $userId = $match.UserID
        Write-CyberArkLog -Level 'DEBUG' -Message "Resolved Username '$userName' to UserID $userId."
    }

    $verb     = if ($enable) { 'enable' } else { 'disable' }
    $userPath = "/API/Users/$([Uri]::EscapeDataString($userId))"
    $endpoint = "$userPath/$verb"

    Write-CyberArkLog -Level 'INFO'  -Message "Starting user $verb. UserID='$userId'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST $endpoint"

    # ── WhatIf ────────────────────────────────────────────────────────────────

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST $endpoint would be performed."
        $result.Results.Add([PSCustomObject]@{ UserID = $userId; Username = $userName; Enabled = (-not $enable) })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # ── API call ──────────────────────────────────────────────────────────────

    $response = Invoke-CyberArkAPI -Token $Token -Method 'POST' -Endpoint $endpoint

    # The /enable and /disable endpoints need PVWA 12.6+. On a 404, fall back to the older
    # PUT /API/Users/{id} with enableUser (psPAS Set-PASUser, 11.1+). PUT replaces the user, so
    # GET it first and resend its current values. A 404 on that GET means the user doesn't exist.
    if (-not $response.IsSuccess -and $response.StatusCode -eq 404) {
        Write-CyberArkLog -Level 'WARN' -Message "POST $endpoint returned 404 (needs PVWA 12.6 or later). Falling back to PUT $userPath with enableUser=$enable."
        $getResp = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint $userPath -PageSize 0
        if (-not $getResp.IsSuccess) {
            & $addError "User $verb failed: could not read UserID '$userId' (HTTP $($getResp.StatusCode)): $($getResp.ErrorMessage)" $getResp.ErrorDetails $getResp.StatusCode
            return $result
        }
        $putBody  = ConvertTo-CyberArkUserPutBody -User $getResp.Data -Changes @{ enableUser = $enable }
        $response = Invoke-CyberArkAPI -Token $Token -Method 'PUT' -Endpoint $userPath -Body $putBody
        if ((-not $userName) -and $getResp.Data -and $getResp.Data.PSObject.Properties['username']) { $userName = "$($getResp.Data.username)" }
    }

    if (-not $response.IsSuccess) {
        & $addError "User $verb failed for UserID '$userId' (HTTP $($response.StatusCode)): $($response.ErrorMessage)" $response.ErrorDetails $response.StatusCode
        return $result
    }

    $result.Results.Add([PSCustomObject]@{ UserID = $userId; Username = $userName; Enabled = $enable })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "User $verb complete. UserID='$userId'."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
