#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Reset User Password'
    Category         = 'Users'
    Action           = 'ResetPassword'
    Description      = 'Set a new password for a Vault user (CyberArk authentication users).'
    # POST /API/Users/{id}/ResetPassword {newPassword}: PVWA 14.6 Swagger and psPAS
    # Set-PASUserPassword (10.10+). Privilege Cloud: CyberArk's own createCredFile-Helper (Privilege
    # Cloud Tools) calls it on a tenant for Vault component users. It doesn't apply to users
    # managed in CyberArk Identity.
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'UserID';      Required = $false; Description = 'Numeric user ID (from List Users). Give this or Username. When set, Username is ignored.' }
        @{ Column = 'Username';    Required = $false; Description = 'Exact username. Resolved to a user ID; the row fails when no user or more than one user matches.' }
        @{ Column = 'NewPassword'; Required = $true;  Description = 'New password (1-39 characters, must meet the Vault password policy). It is never logged, but a CSV file holds it in clear text: protect and delete the file after use.' }
    )
    Priority         = 57
    Version          = '1.0.0'
}

function Get-UsersResetPasswordInput {
    <#
        Called by the driver when HasCustomInput = $true.
        Show-FieldPrompt is available because this module is dot-sourced into the driver scope.
        The password is read with Read-Host -AsSecureString and is never offered as a default.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Reset User Password' -ForegroundColor DarkGray
    Write-Host ''

    $userID = Show-FieldPrompt -Label 'User ID' `
        -Default $(if ($Defaults['UserID']) { $Defaults['UserID'] } else { '' }) `
        -Description 'Numeric user ID, or leave blank to search by username.'

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

    Write-Host '    New password (1-39 characters; input is hidden):' -ForegroundColor DarkGray
    $first  = Read-Host -AsSecureString '    NewPassword'
    $second = Read-Host -AsSecureString '    Confirm NewPassword'

    $toPlain = {
        param([System.Security.SecureString]$Secure)
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        try { [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    $plain1 = & $toPlain $first
    $plain2 = & $toPlain $second

    if (-not $plain1) {
        Write-Host '    No password entered - cancelled.' -ForegroundColor Yellow
        return $null
    }
    if ($plain1 -cne $plain2) {
        Write-Host '    The passwords don''t match - cancelled.' -ForegroundColor Yellow
        return $null
    }

    return @{
        UserID      = $userID
        NewPassword = $plain1
    }
}

function Invoke-UsersResetPassword {
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

    # A copy of the row with the password masked, for error entries.
    $safeInput = @{}
    foreach ($k in $InputData.Keys) { $safeInput[$k] = $InputData[$k] }
    if ($safeInput.ContainsKey('NewPassword') -and $safeInput['NewPassword']) { $safeInput['NewPassword'] = '***' }

    $addError = {
        param([string]$Message, $Details, [int]$StatusCode = -1)
        Write-CyberArkLog -Level 'ERROR' -Message $Message
        $result.Errors.Add([PSCustomObject]@{ InputData = $safeInput; ErrorMessage = $Message; ErrorDetails = $Details })
        $result.Failures++
        $result.ItemsProcessed++
        if ($StatusCode -in @(401, 0)) { $result.IsFatal = $true }
    }

    # ── Validation ────────────────────────────────────────────────────────────

    $ident = Get-CyberArkUserIdentifier -InputData $InputData
    if ($ident.ErrorMessage) { & $addError $ident.ErrorMessage $null; return $result }

    # Not trimmed: leading/trailing spaces may be part of a password.
    $newPassword = if ($InputData.ContainsKey('NewPassword') -and $null -ne $InputData['NewPassword']) { "$($InputData['NewPassword'])" } else { '' }
    if (-not $newPassword) { & $addError 'NewPassword is required.' $null; return $result }
    if ($newPassword.Length -gt 39) { & $addError 'NewPassword must be 39 characters or fewer.' $null; return $result }

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

    $endpoint = "/API/Users/$([Uri]::EscapeDataString($userId))/ResetPassword"

    Write-CyberArkLog -Level 'INFO'  -Message "Starting user password reset. UserID='$userId'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST $endpoint | newPassword=***"

    # ── WhatIf (the password is never sent) ───────────────────────────────────

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST $endpoint would be performed."
        $result.Results.Add([PSCustomObject]@{ UserID = $userId; Username = $userName; PasswordReset = $false })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # ── API call ──────────────────────────────────────────────────────────────

    # Invoke-CyberArkAPI's DEBUG body log masks any JSON key containing "password".
    $body     = @{ newPassword = $newPassword }
    $response = Invoke-CyberArkAPI -Token $Token -Method 'POST' -Endpoint $endpoint -Body $body
    $body['newPassword'] = '***'
    $newPassword = $null

    if (-not $response.IsSuccess) {
        & $addError "User password reset failed for UserID '$userId' (HTTP $($response.StatusCode)): $($response.ErrorMessage)" $response.ErrorDetails $response.StatusCode
        return $result
    }

    $result.Results.Add([PSCustomObject]@{ UserID = $userId; Username = $userName; PasswordReset = $true })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "User password reset complete. UserID='$userId'."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
