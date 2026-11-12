#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Set Next Password'
    Category         = 'Accounts'
    MenuGroup        = 'CPM tasks'
    Action           = 'SetNextPassword'
    Description      = 'Give the CPM the password to set at its next change, on the target system and in the vault. With ChangeImmediately = Yes the CPM changes it now.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountID';         Required = $false; Description = 'Account ID. Give this, or AccountName and/or UserName with Safe. When set, the other identifier columns are ignored.' }
        @{ Column = 'AccountName';       Required = $false; Description = 'Account (object) name: the name field, not the username. An ObjectName column is also accepted. Needs Safe.' }
        @{ Column = 'UserName';          Required = $false; Description = 'Account username. Needs Safe. With AccountName, the account must match both. More than one match fails the row.' }
        @{ Column = 'Safe';              Required = $false; Description = 'Safe containing the account. Required unless AccountID is set.' }
        @{ Column = 'NewCredentials';    Required = $true;  Description = 'Password the CPM sets on the target and in the vault. It is never logged and is masked in the results CSV, but the input CSV holds it in clear text: protect and delete the file after use.' }
        @{ Column = 'ChangeImmediately'; Required = $false; Description = 'Yes/No (default Yes). Yes: the CPM changes the password now. No: the CPM uses it at the next scheduled change.' }
    )
    Priority         = 59
    Version          = '1.0.0'
}

function Get-AccountsSetNextPasswordInput {
    <#
        Called by the driver when HasCustomInput = $true.
        Show-FieldPrompt, Read-ConfirmedSecret and Invoke-EntitySearch are available because this
        module is dot-sourced into the driver scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Set Next Password  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $accountID = Show-FieldPrompt -Label 'Account ID' `
        -Default $(if ($Defaults['AccountID']) { $Defaults['AccountID'] } else { '' }) `
        -Description 'Account ID, or leave blank to search by name/username/address.'

    if (-not $accountID) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Name, username, or address to find the account.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $accountID = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/Accounts' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'value' `
                -IdProperty 'id' `
                -DisplayProperties @('name', 'userName', 'address', 'safeName') `
                -EntityLabel 'account' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $accountID) { return $null }
    }

    $newCredentials = Read-ConfirmedSecret -Label 'NewCredentials' `
        -Description 'Password for the CPM to set on the target and in the vault (input is hidden):'
    if (-not $newCredentials) { return $null }

    $changeImmediately = Show-FieldPrompt -Label 'Change Immediately' `
        -Default $(if ($Defaults['ChangeImmediately']) { $Defaults['ChangeImmediately'] } else { 'Yes' }) `
        -Description 'Yes: the CPM changes the password now. No: at the next scheduled change.'

    return @{
        AccountID         = $accountID
        NewCredentials    = $newCredentials
        ChangeImmediately = $changeImmediately
    }
}

function Invoke-AccountsSetNextPassword {
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

    # Keep the password out of the error objects' InputData, in case a caller ever prints or saves them.
    $safeInput = @{}
    foreach ($key in $InputData.Keys) {
        $safeInput[$key] = if ("$key" -match '(?i)password|secret|credential') { '***' } else { $InputData[$key] }
    }

    $fail = {
        param([string]$Message, $Details, [bool]$Fatal)
        Write-CyberArkLog -Level 'ERROR' -Message $Message
        $result.Errors.Add([PSCustomObject]@{ InputData = $safeInput; ErrorMessage = $Message; ErrorDetails = $Details })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = $Fatal
        return $result
    }

    # Validate the inputs that need no API call first.
    $newCredentials = if ($InputData['NewCredentials']) { "$($InputData['NewCredentials'])".Trim() } else { '' }
    if (-not $newCredentials) { return (& $fail 'NewCredentials is required.' $null $false) }

    $changeRaw = "$($InputData['ChangeImmediately'])".Trim()
    $changeImmediately = $true
    if ($changeRaw) {
        if ($changeRaw -match '^(true|yes|y|1)$')      { $changeImmediately = $true }
        elseif ($changeRaw -match '^(false|no|n|0)$') { $changeImmediately = $false }
        else { return (& $fail "ChangeImmediately must be Yes or No (got '$changeRaw')." $null $false) }
    }

    $ident     = Get-CyberArkAccountIdentifier -InputData $InputData
    $accountId = $ident.AccountID
    if ($ident.ErrorMessage) { return (& $fail $ident.ErrorMessage $null $false) }

    if ($ident.NeedsLookup) {
        Write-CyberArkLog -Level 'DEBUG' -Message "Fetching accounts in safe '$($ident.Safe)' to locate the account."

        $lookupResp = Invoke-CyberArkAPI `
            -Token       $Token `
            -Method      'GET' `
            -Endpoint    '/API/Accounts' `
            -QueryParams @{ filter = (New-CyberArkSearchFilter -Criteria @{ safeName = $ident.Safe }); limit = 1000 }

        if (-not $lookupResp.IsSuccess) {
            $msg = "Account lookup failed (HTTP $($lookupResp.StatusCode)): $($lookupResp.ErrorMessage)"
            return (& $fail $msg $lookupResp.ErrorDetails ($lookupResp.StatusCode -in @(401, 0)))
        }

        [array]$acctList = @(if ($lookupResp.Data -and
                                 $lookupResp.Data.PSObject.Properties['value'] -and
                                 $null -ne $lookupResp.Data.value) {
            $lookupResp.Data.value
        })

        $acctMatch = Select-CyberArkAccountMatch -Accounts $acctList `
            -AccountName $ident.AccountName -UserName $ident.UserName -Safe $ident.Safe
        if ($acctMatch.ErrorMessage) { return (& $fail $acctMatch.ErrorMessage $null $false) }

        $accountId = $acctMatch.AccountID
        Write-CyberArkLog -Level 'DEBUG' -Message "Resolved account ID: $accountId"
    }

    $encodedId = [Uri]::EscapeDataString($accountId)
    $when      = if ($changeImmediately) { 'now' } else { 'at the next scheduled change' }

    Write-CyberArkLog -Level 'INFO'  -Message "Setting the next password for account ID: $accountId (CPM changes it $when)."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Accounts/$accountId/SetNextPassword"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST /API/Accounts/$accountId/SetNextPassword would be performed (ChangeImmediately = $changeImmediately)."
        $result.Successes++
        $result.ItemsProcessed++
        return $result
    }

    $body = @{
        NewCredentials    = $newCredentials
        ChangeImmediately = $changeImmediately
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint "/API/Accounts/$encodedId/SetNextPassword" `
        -Body     $body

    if (-not $response.IsSuccess) {
        $msg = "Set Next Password failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
        return (& $fail $msg $response.ErrorDetails ($response.StatusCode -in @(401, 0)))
    }

    $result.Results.Add([PSCustomObject]@{
        AccountID         = $accountId
        ChangeImmediately = $changeImmediately
        Status            = 'Success'
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Set Next Password complete for account ID: $accountId."

    return $result
}
