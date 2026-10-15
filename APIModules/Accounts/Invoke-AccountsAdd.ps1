#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Account'
    Category         = 'Accounts'
    MenuGroup        = 'Accounts'
    Action           = 'Add'
    Description      = 'Create a new account (privileged credential) in a CyberArk safe.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'Name';        Required = $false; Description = 'Account name (auto-generated if blank).' }
        @{ Column = 'Address';     Required = $true;  Description = 'Target system address (hostname or IP).' }
        @{ Column = 'UserName';    Required = $true;  Description = 'Privileged username.' }
        @{ Column = 'PlatformID';  Required = $true;  Description = 'Platform ID (e.g. WinServerLocal).' }
        @{ Column = 'SafeName';    Required = $true;  Description = 'Safe where the account will be stored.' }
        @{ Column = 'SecretType';  Required = $false; Description = 'Credential type: password / key (default: password).' }
        @{ Column = 'Secret';      Required = $false; Description = 'Initial password value (leave blank for CPM-managed).' }
        @{ Column = 'AutoManaged'; Required = $false; Description = 'Enable automatic CPM management: true/false (default: true).' }
    )
    Priority         = 32
    Version          = '1.1.0'
}

function Get-AccountsAddInput {
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

    Write-Host '  Add Account  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $name = Show-FieldPrompt -Label 'Name' `
        -Default $(if ($Defaults['Name']) { $Defaults['Name'] } else { '' }) `
        -Description 'Account name. Leave blank to auto-generate as UserName@Address.'

    $address = Show-FieldPrompt -Label 'Address' `
        -Default $(if ($Defaults['Address']) { $Defaults['Address'] } else { '' }) `
        -Description 'Target system address (hostname or IP). Required.'

    $userName = Show-FieldPrompt -Label 'UserName' `
        -Default $(if ($Defaults['UserName']) { $Defaults['UserName'] } else { '' }) `
        -Description 'Privileged username. Required.'

    $platformID = Show-FieldPrompt -Label 'PlatformID' `
        -Default $(if ($Defaults['PlatformID']) { $Defaults['PlatformID'] } else { '' }) `
        -Description 'Platform ID (e.g. WinServerLocal). Required.'

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Description 'Safe where the account will be stored. Required.'

    $secretType = Show-FieldPrompt -Label 'SecretType' `
        -Default $(if ($Defaults['SecretType']) { $Defaults['SecretType'] } else { 'password' }) `
        -Description 'Credential type: password or key. Leave blank for default (password).'

    Write-Host '  Secret (leave blank for CPM-managed):' -ForegroundColor DarkGray
    $secureSecret = Read-Host -AsSecureString '  Secret'
    $bstr         = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
    $secretPlain  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    $autoManaged = Show-FieldPrompt -Label 'AutoManaged' `
        -Default $(if ($Defaults['AutoManaged']) { $Defaults['AutoManaged'] } else { 'true' }) `
        -Description 'Enable automatic CPM management: true/false (default: true).'

    return @{
        Name        = $name
        Address     = $address
        UserName    = $userName
        PlatformID  = $platformID
        SafeName    = $safeName
        SecretType  = $secretType
        Secret      = $secretPlain
        AutoManaged = $autoManaged
    }
}

function Invoke-AccountsAdd {
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

    # ── Validation ────────────────────────────────────────────────────────────

    $validationErrors = @()

    if (-not $InputData['Address'])    { $validationErrors += 'Address is required.' }
    if (-not $InputData['UserName'])   { $validationErrors += 'UserName is required.' }
    if (-not $InputData['PlatformID']) { $validationErrors += 'PlatformID is required.' }
    if (-not $InputData['SafeName'])   { $validationErrors += 'SafeName is required.' }

    if ($validationErrors.Count -gt 0) {
        foreach ($msg in $validationErrors) {
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = $InputData
                ErrorMessage = $msg
                ErrorDetails = $null
            })
            $result.Failures++
            $result.ItemsProcessed++
        }
        return $result
    }

    # ── Build request body ────────────────────────────────────────────────────

    $accountName = if ($InputData['Name']) { $InputData['Name'] } else { "$($InputData['UserName'])@$($InputData['Address'])" }
    $secretType  = if ($InputData['SecretType']) { $InputData['SecretType'] } else { 'password' }
    $autoManaged = ($InputData['AutoManaged'] -notmatch '^false$')

    $secretMgmt = @{ automaticManagementEnabled = $autoManaged }
    if (-not $autoManaged) { $secretMgmt['manualManagementReason'] = '' }

    $body = @{
        name             = $accountName
        address          = $InputData['Address']
        userName         = $InputData['UserName']
        platformId       = $InputData['PlatformID']
        safeName         = $InputData['SafeName']
        secretType       = $secretType
        secretManagement = $secretMgmt
    }

    if ($InputData['Secret']) { $body['secret'] = $InputData['Secret'] }

    Write-CyberArkLog -Level 'INFO' -Message "Adding account UserName=$($InputData['UserName']) to SafeName=$($InputData['SafeName'])"

    # ── WhatIf ────────────────────────────────────────────────────────────────

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "[WhatIf] Would POST /API/Accounts for UserName=$($InputData.UserName) in SafeName=$($InputData.SafeName)"
        $result.Results.Add([PSCustomObject]@{
            AccountID   = ''
            AccountName = $accountName
            Address     = $InputData.Address
            UserName    = $InputData.UserName
            PlatformID  = $InputData.PlatformID
            SafeName    = $InputData.SafeName
            SecretType  = $secretType
            AutoManaged = $autoManaged
            CPMStatus   = ''
            Created     = ''
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # ── API call ──────────────────────────────────────────────────────────────

    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Accounts | Secret=***"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint '/API/Accounts' `
        -Body     $body `
        -WhatIf:  $false

    # Clear the secret from the body immediately after the call
    if ($body['secret']) { $body['secret'] = '***' }

    if (-not $response.IsSuccess) {
        $msg = "Add account failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $response.ErrorMessage
            ErrorDetails = $response.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # ── Map response ──────────────────────────────────────────────────────────

    $acct = $response.Data

    $created = if ($acct.PSObject.Properties['createdTime'] -and $acct.createdTime) {
        try { [DateTimeOffset]::FromUnixTimeSeconds($acct.createdTime).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    $result.Results.Add([PSCustomObject]@{
        AccountID   = if ($acct.PSObject.Properties['id'])         { $acct.id }         else { '' }
        AccountName = if ($acct.PSObject.Properties['name'])       { $acct.name }       else { '' }
        Address     = if ($acct.PSObject.Properties['address'])    { $acct.address }    else { '' }
        UserName    = if ($acct.PSObject.Properties['userName'])   { $acct.userName }   else { '' }
        PlatformID  = if ($acct.PSObject.Properties['platformId']) { $acct.platformId } else { '' }
        SafeName    = if ($acct.PSObject.Properties['safeName'])   { $acct.safeName }   else { '' }
        SecretType  = if ($acct.PSObject.Properties['secretType']) { $acct.secretType } else { '' }
        AutoManaged = if ($acct.PSObject.Properties['secretManagement'] -and $acct.secretManagement -and
                          $acct.secretManagement.PSObject.Properties['automaticManagementEnabled']) {
                          $acct.secretManagement.automaticManagementEnabled
                      } else { $false }
        CPMStatus   = if ($acct.PSObject.Properties['secretManagement'] -and $acct.secretManagement -and
                          $acct.secretManagement.PSObject.Properties['status']) {
                          $acct.secretManagement.status
                      } else { '' }
        Created     = $created
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Account added successfully. AccountID=$($acct.id) UserName=$($acct.userName) SafeName=$($acct.safeName)"
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
