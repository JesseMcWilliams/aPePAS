#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Update User'
    Category         = 'Users'
    Action           = 'Update'
    Description      = 'Update properties of an existing Vault user. Blank fields keep their current values.'
    # PUT /API/Users/{id} (EditUserRequest): PVWA 14.6 Swagger and psPAS Set-PASUser (Gen2, 11.1+).
    # PUT replaces the user, so this GETs the user first and resends every value it isn't changing,
    # as psPAS does. Self-Hosted only: Privilege Cloud users are managed in CyberArk Identity, and no
    # reference shows this endpoint used on a tenant.
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'UserID';                Required = $false; Description = 'Numeric user ID (from List Users). Give this or Username. When set, Username is ignored.' }
        @{ Column = 'Username';              Required = $false; Description = 'Exact username of the user to update. Resolved to a user ID; the row fails when no user or more than one user matches. It can''t rename the user.' }
        @{ Column = 'UserType';              Required = $false; Description = 'New license user type. Blank keeps the current value.' }
        @{ Column = 'Location';              Required = $false; Description = 'New Vault location (for example \Applications). Blank keeps the current value.' }
        @{ Column = 'Description';           Required = $false; Description = 'New notes (up to 99 characters). Blank keeps the current value.' }
        @{ Column = 'FirstName';             Required = $false; Description = 'New first name. Blank keeps the current value.' }
        @{ Column = 'LastName';              Required = $false; Description = 'New last name. Blank keeps the current value.' }
        @{ Column = 'BusinessEmail';         Required = $false; Description = 'New business email. Blank keeps the current value.' }
        @{ Column = 'DistinguishedName';     Required = $false; Description = 'New distinguished name (PKI). Blank keeps the current value.' }
        @{ Column = 'ChangePassOnNextLogon'; Required = $false; Description = 'true/false. Blank keeps the current value.' }
        @{ Column = 'PasswordNeverExpires';  Required = $false; Description = 'true/false. Blank keeps the current value.' }
        @{ Column = 'ExpiryDate';            Required = $false; Description = 'New expiry date as yyyy-MM-dd. Blank keeps the current value.' }
        @{ Column = 'VaultAuthorization';    Required = $false; Description = 'Replaces the whole list of Vault authorizations (semicolon-separated). Blank keeps the current list.'; Example = 'AddSafes;AuditUsers' }
    )
    Priority         = 59
    Version          = '1.0.0'
}

function Get-UsersUpdateInput {
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

    Write-Host '  User Update  (press Enter to keep the current value)' -ForegroundColor DarkGray
    Write-Host ''

    $userID = Show-FieldPrompt -Label 'User ID' `
        -Default $(if ($Defaults['UserID']) { $Defaults['UserID'] } else { '' }) `
        -Description 'Numeric user ID to update, or leave blank to search by username.'

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

    $data = @{ UserID = $userID }
    $prompts = @(
        @{ Column = 'UserType';              Text = 'New license user type.' }
        @{ Column = 'Location';              Text = 'New Vault location (for example \Applications).' }
        @{ Column = 'Description';           Text = 'New notes (up to 99 characters).' }
        @{ Column = 'FirstName';             Text = 'New first name.' }
        @{ Column = 'LastName';              Text = 'New last name.' }
        @{ Column = 'BusinessEmail';         Text = 'New business email.' }
        @{ Column = 'DistinguishedName';     Text = 'New distinguished name (PKI).' }
        @{ Column = 'ChangePassOnNextLogon'; Text = 'true/false: must change the password at next logon.' }
        @{ Column = 'PasswordNeverExpires';  Text = 'true/false: password never expires.' }
        @{ Column = 'ExpiryDate';            Text = 'New expiry date as yyyy-MM-dd.' }
        @{ Column = 'VaultAuthorization';    Text = 'Replaces the whole list of Vault authorizations (semicolon-separated).' }
    )
    foreach ($p in $prompts) {
        $data[$p.Column] = Show-FieldPrompt -Label $p.Column `
            -Default $(if ($Defaults[$p.Column]) { $Defaults[$p.Column] } else { '' }) `
            -Description "$($p.Text) Leave blank to keep the current value."
    }

    return $data
}

function Invoke-UsersUpdate {
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

    # ── Validation ────────────────────────────────────────────────────────────

    $ident = Get-CyberArkUserIdentifier -InputData $InputData
    if ($ident.ErrorMessage) { & $addError $ident.ErrorMessage $null; return $result }

    $conv = ConvertTo-CyberArkUserFields -InputData $InputData
    if ($conv.Errors.Count -gt 0) { & $addError ($conv.Errors -join ' ') $null; return $result }
    if ($conv.Columns.Count -eq 0) { & $addError 'Nothing to update: give at least one field to change.' $null; return $result }

    # ── Identify the user ─────────────────────────────────────────────────────

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

    $endpoint = "/API/Users/$([Uri]::EscapeDataString($userId))"

    Write-CyberArkLog -Level 'INFO'  -Message "Starting user update. UserID='$userId'. Fields: $($conv.Columns -join ', ')."
    Write-CyberArkLog -Level 'DEBUG' -Message "GET $endpoint"

    # ── GET the current user (PUT is a full replace) ──────────────────────────

    $getResp = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint $endpoint -PageSize 0
    if (-not $getResp.IsSuccess) {
        & $addError "Could not read UserID '$userId' before update (HTTP $($getResp.StatusCode)): $($getResp.ErrorMessage)" $getResp.ErrorDetails $getResp.StatusCode
        return $result
    }

    $body = ConvertTo-CyberArkUserPutBody -User $getResp.Data -Changes $conv.Fields
    if (-not $body.ContainsKey('username') -or -not $body['username']) {
        & $addError "UserID '$userId': the user record has no username, so the update can't be sent (username is required by PUT)." $null
        return $result
    }

    $mapResult = {
        param($Source)
        $pick = {
            param($Obj, [string]$Name)
            if ($null -eq $Obj) { return '' }
            if ($Obj -is [hashtable]) { if ($Obj.ContainsKey($Name) -and $null -ne $Obj[$Name]) { return $Obj[$Name] } else { return '' } }
            if ($Obj.PSObject.Properties[$Name] -and $null -ne $Obj.$Name) { return $Obj.$Name }
            return ''
        }
        $pd  = & $pick $Source 'personalDetails'
        $net = & $pick $Source 'internet'
        $va  = & $pick $Source 'vaultAuthorization'
        [PSCustomObject]@{
            UserID                = if (& $pick $Source 'id') { & $pick $Source 'id' } else { $userId }
            Username              = & $pick $Source 'username'
            UserType              = & $pick $Source 'userType'
            Location              = & $pick $Source 'location'
            Description           = & $pick $Source 'description'
            FirstName             = if ($pd)  { & $pick $pd 'firstName' }      else { '' }
            LastName              = if ($pd)  { & $pick $pd 'lastName' }       else { '' }
            BusinessEmail         = if ($net) { & $pick $net 'businessEmail' } else { '' }
            ChangePassOnNextLogon = & $pick $Source 'changePassOnNextLogon'
            PasswordNeverExpires  = & $pick $Source 'passwordNeverExpires'
            VaultAuthorization    = if ($va) { @($va) -join ';' } else { '' }
        }
    }

    # ── WhatIf ────────────────────────────────────────────────────────────────

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: PUT $endpoint would be performed."
        $result.Results.Add((& $mapResult $body))
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # ── API call ──────────────────────────────────────────────────────────────

    Write-CyberArkLog -Level 'DEBUG' -Message "PUT $endpoint"
    $response = Invoke-CyberArkAPI -Token $Token -Method 'PUT' -Endpoint $endpoint -Body $body

    if (-not $response.IsSuccess) {
        & $addError "User update failed for UserID '$userId' (HTTP $($response.StatusCode)): $($response.ErrorMessage)" $response.ErrorDetails $response.StatusCode
        return $result
    }

    $source = if ($null -ne $response.Data) { $response.Data } else { $body }
    $result.Results.Add((& $mapResult $source))
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "User update complete. UserID='$userId'."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
