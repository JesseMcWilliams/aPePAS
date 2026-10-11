#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Unblock User'
    Category         = 'Users'
    Action           = 'Unblock'
    Description      = 'Unblock (activate) a Vault user who was suspended after too many failed logons.'
    # POST /API/Users/{id}/Activate: PVWA 14.6 Swagger and psPAS Unblock-PASUser (10.10+). Privilege
    # Cloud: CyberArk's own createCredFile-Helper (Privilege Cloud Tools) calls it on a tenant.
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'UserID';   Required = $false; Description = 'Numeric user ID (from List Users). Give this or Username. When set, Username is ignored.' }
        @{ Column = 'Username'; Required = $false; Description = 'Exact username. Resolved to a user ID; the row fails when no user or more than one user matches.' }
    )
    Priority         = 58
    Version          = '1.0.0'
}

function Get-UsersUnblockInput {
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

    Write-Host '  User to Unblock' -ForegroundColor DarkGray
    Write-Host ''

    $userID = Show-FieldPrompt -Label 'User ID' `
        -Default $(if ($Defaults['UserID']) { $Defaults['UserID'] } else { '' }) `
        -Description 'Numeric user ID to unblock, or leave blank to search by username.'

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

function Invoke-UsersUnblock {
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

    $endpoint = "/API/Users/$([Uri]::EscapeDataString($userId))/Activate"

    Write-CyberArkLog -Level 'INFO'  -Message "Starting user unblock. UserID='$userId'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST $endpoint"

    # ── WhatIf ────────────────────────────────────────────────────────────────

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST $endpoint would be performed."
        $result.Results.Add([PSCustomObject]@{ UserID = $userId; Username = $userName; Unblocked = $false })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # ── API call ──────────────────────────────────────────────────────────────

    $response = Invoke-CyberArkAPI -Token $Token -Method 'POST' -Endpoint $endpoint

    if (-not $response.IsSuccess) {
        & $addError "User unblock failed for UserID '$userId' (HTTP $($response.StatusCode)): $($response.ErrorMessage)" $response.ErrorDetails $response.StatusCode
        return $result
    }

    $result.Results.Add([PSCustomObject]@{ UserID = $userId; Username = $userName; Unblocked = $true })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "User unblock complete. UserID='$userId'."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
