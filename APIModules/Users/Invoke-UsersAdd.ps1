#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add User'
    Category         = 'Users'
    Action           = 'Add'
    Description      = 'Create a new Vault user.'
    # POST /API/Users (CreateUserRequest): PVWA 14.6 Swagger and psPAS New-PASUser (Gen2, 10.9+).
    # Self-Hosted only: on Privilege Cloud, users are created in CyberArk Identity, and no reference
    # shows this endpoint used on a tenant.
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'Username';                     Required = $true;  Description = 'Name of the new user (up to 128 characters).' }
        @{ Column = 'InitialPassword';              Required = $false; Description = 'First-logon password (up to 39 characters, must meet the Vault password policy). Leave blank for users that don''t log on with a Vault password. Never logged, but a CSV file holds it in clear text: protect and delete the file after use.' }
        @{ Column = 'UserType';                     Required = $false; Description = 'License user type (for example EPVUser). Blank uses the Vault default.' }
        @{ Column = 'Location';                     Required = $false; Description = 'Vault location, starting with a backslash (for example \Applications). Blank uses the root.' }
        @{ Column = 'Description';                  Required = $false; Description = 'Notes about the user (up to 99 characters).' }
        @{ Column = 'FirstName';                    Required = $false; Description = 'First name (up to 29 characters).' }
        @{ Column = 'LastName';                     Required = $false; Description = 'Last name (up to 29 characters).' }
        @{ Column = 'BusinessEmail';                Required = $false; Description = 'Business email address.' }
        @{ Column = 'DistinguishedName';            Required = $false; Description = 'Distinguished name, used to match a certificate for PKI authentication.' }
        @{ Column = 'EnableUser';                   Required = $false; Description = 'true/false: whether the user is enabled when created.' }
        @{ Column = 'ChangePassOnNextLogon';        Required = $false; Description = 'true/false: whether the user must change the password at first logon.' }
        @{ Column = 'PasswordNeverExpires';         Required = $false; Description = 'true/false: whether the password never expires.' }
        @{ Column = 'ExpiryDate';                   Required = $false; Description = 'Date the user expires, as yyyy-MM-dd.' }
        @{ Column = 'VaultAuthorization';           Required = $false; Description = 'Vault authorizations separated by semicolons (for example AddSafes;AuditUsers). You must hold each one yourself.'; Example = 'AddSafes;AuditUsers' }
        @{ Column = 'AuthenticationMethod';         Required = $false; Description = 'Logon method(s) separated by semicolons (for example AuthTypePass or AuthTypeLDAP).' }
        @{ Column = 'AllowedAuthenticationMethods'; Required = $false; Description = 'Allowed external authentication method IDs separated by semicolons (for example SAML;PKI).' }
    )
    Priority         = 51
    Version          = '1.0.0'
}

function Get-UsersAddInput {
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

    Write-Host '  Add User  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $data = @{}
    $data['Username'] = Show-FieldPrompt -Label 'Username' `
        -Default $(if ($Defaults['Username']) { $Defaults['Username'] } else { '' }) `
        -Description 'Name of the new user. Required.'
    if (-not $data['Username']) { return $null }

    Write-Host '    Initial password (leave blank for none; input is hidden):' -ForegroundColor DarkGray
    $first = Read-Host -AsSecureString '    InitialPassword'
    if ($first.Length -gt 0) {
        $second  = Read-Host -AsSecureString '    Confirm InitialPassword'
        $toPlain = {
            param([System.Security.SecureString]$Secure)
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
            try { [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        $plain1 = & $toPlain $first
        $plain2 = & $toPlain $second
        if ($plain1 -cne $plain2) {
            Write-Host '    The passwords don''t match - cancelled.' -ForegroundColor Yellow
            return $null
        }
        $data['InitialPassword'] = $plain1
    } else {
        $data['InitialPassword'] = ''
    }

    $prompts = @(
        @{ Column = 'UserType';              Text = 'License user type (for example EPVUser). Blank uses the Vault default.' }
        @{ Column = 'Location';              Text = 'Vault location (for example \Applications). Blank uses the root.' }
        @{ Column = 'Description';           Text = 'Notes about the user (up to 99 characters).' }
        @{ Column = 'FirstName';             Text = 'First name.' }
        @{ Column = 'LastName';              Text = 'Last name.' }
        @{ Column = 'BusinessEmail';         Text = 'Business email address.' }
        @{ Column = 'EnableUser';            Text = 'true/false: enabled when created. Blank uses the Vault default.' }
        @{ Column = 'ChangePassOnNextLogon'; Text = 'true/false: must change the password at first logon.' }
        @{ Column = 'PasswordNeverExpires';  Text = 'true/false: password never expires.' }
        @{ Column = 'ExpiryDate';            Text = 'Date the user expires, as yyyy-MM-dd.' }
        @{ Column = 'VaultAuthorization';    Text = 'Vault authorizations separated by semicolons (for example AddSafes;AuditUsers).' }
        @{ Column = 'AuthenticationMethod';  Text = 'Logon method(s) separated by semicolons (for example AuthTypePass).' }
    )
    foreach ($p in $prompts) {
        $data[$p.Column] = Show-FieldPrompt -Label $p.Column `
            -Default $(if ($Defaults[$p.Column]) { $Defaults[$p.Column] } else { '' }) `
            -Description $p.Text
    }

    return $data
}

function Invoke-UsersAdd {
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
    if ($safeInput.ContainsKey('InitialPassword') -and $safeInput['InitialPassword']) { $safeInput['InitialPassword'] = '***' }

    $addError = {
        param([string]$Message, $Details, [int]$StatusCode = -1)
        Write-CyberArkLog -Level 'ERROR' -Message $Message
        $result.Errors.Add([PSCustomObject]@{ InputData = $safeInput; ErrorMessage = $Message; ErrorDetails = $Details })
        $result.Failures++
        $result.ItemsProcessed++
        if ($StatusCode -in @(401, 0)) { $result.IsFatal = $true }
    }

    # ── Validation ────────────────────────────────────────────────────────────

    $userName = if ($InputData.ContainsKey('Username') -and $null -ne $InputData['Username']) { "$($InputData['Username'])".Trim() } else { '' }
    $password = if ($InputData.ContainsKey('InitialPassword') -and $null -ne $InputData['InitialPassword']) { "$($InputData['InitialPassword'])" } else { '' }

    $problems = [System.Collections.Generic.List[string]]::new()
    if (-not $userName)             { $problems.Add('Username is required.') }
    elseif ($userName.Length -gt 128) { $problems.Add('Username must be 128 characters or fewer.') }
    if ($password.Length -gt 39)    { $problems.Add('InitialPassword must be 39 characters or fewer.') }

    $conv = ConvertTo-CyberArkUserFields -InputData $InputData -IncludeCreateOnly
    foreach ($e in $conv.Errors) { $problems.Add($e) }

    if ($problems.Count -gt 0) {
        & $addError ($problems -join ' ') $null
        return $result
    }

    # ── Build request body ────────────────────────────────────────────────────

    $body = @{ username = $userName }
    foreach ($key in $conv.Fields.Keys) { $body[$key] = $conv.Fields[$key] }
    if ($password) { $body['initialPassword'] = $password }

    $fieldList = if ($conv.Columns.Count -gt 0) { $conv.Columns -join ', ' } else { '(none)' }
    Write-CyberArkLog -Level 'INFO'  -Message "Starting user add. Username='$userName'. Fields: $fieldList. InitialPassword: $(if ($password) { 'set' } else { 'not set' })."
    Write-CyberArkLog -Level 'DEBUG' -Message 'POST /API/Users | initialPassword=***'

    $readBody = {
        param([string]$Parent, [string]$Name)
        if ($Parent) {
            if ($body.ContainsKey($Parent) -and $body[$Parent].ContainsKey($Name)) { $body[$Parent][$Name] } else { '' }
        } else {
            if ($body.ContainsKey($Name)) { $body[$Name] } else { '' }
        }
    }

    # ── WhatIf (the password is never sent) ───────────────────────────────────

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST /API/Users would be performed for Username='$userName'."
        $result.Results.Add([PSCustomObject]@{
            UserID    = ''
            Username  = $userName
            UserType  = & $readBody '' 'userType'
            Location  = & $readBody '' 'location'
            FirstName = & $readBody 'personalDetails' 'firstName'
            LastName  = & $readBody 'personalDetails' 'lastName'
            Enabled   = & $readBody '' 'enableUser'
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # ── API call ──────────────────────────────────────────────────────────────

    # Invoke-CyberArkAPI's DEBUG body log masks any JSON key containing "password".
    $response = Invoke-CyberArkAPI -Token $Token -Method 'POST' -Endpoint '/API/Users' -Body $body
    if ($body.ContainsKey('initialPassword')) { $body['initialPassword'] = '***' }
    $password = $null

    if (-not $response.IsSuccess) {
        & $addError "User add failed for '$userName' (HTTP $($response.StatusCode)): $($response.ErrorMessage)" $response.ErrorDetails $response.StatusCode
        return $result
    }

    # ── Map response ──────────────────────────────────────────────────────────

    $u = $response.Data
    $get = {
        param($Obj, [string]$Name)
        if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name] -and $null -ne $Obj.$Name) { $Obj.$Name } else { '' }
    }
    $details = & $get $u 'personalDetails'

    $result.Results.Add([PSCustomObject]@{
        UserID    = & $get $u 'id'
        Username  = if (& $get $u 'username') { & $get $u 'username' } else { $userName }
        UserType  = & $get $u 'userType'
        Location  = & $get $u 'location'
        FirstName = if ($details) { & $get $details 'firstName' } else { '' }
        LastName  = if ($details) { & $get $details 'lastName' }  else { '' }
        Enabled   = & $get $u 'enableUser'
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "User add complete. Username='$userName' UserID='$(& $get $u 'id')'."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
