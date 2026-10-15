#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Request JIT Access'
    Category         = 'Accounts'
    MenuGroup        = 'Access and retrieval'
    Action           = 'RequestJitAccess'
    Description      = 'Grant yourself just-in-time administrative access to the account''s Windows machine (adds you to its local Administrators group).'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountID';   Required = $false; Description = 'Account ID. Give this, or AccountName and/or UserName with Safe. When set, the other identifier columns are ignored.' }
        @{ Column = 'AccountName'; Required = $false; Description = 'Account (object) name: the name field, not the username. An ObjectName column is also accepted. Needs Safe.' }
        @{ Column = 'UserName';    Required = $false; Description = 'Account username. Needs Safe. With AccountName, the account must match both. More than one match fails the row.' }
        @{ Column = 'Safe';        Required = $false; Description = 'Safe containing the account. Required unless AccountID is set.' }
    )
    Priority         = 47
    Version          = '1.0.0'
}

function Get-AccountsRequestJitAccessInput {
    <#
        Called by the driver when HasCustomInput = $true.
        Show-FieldPrompt and Invoke-EntitySearch are available because this module is dot-sourced into the driver scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  JIT access needs a Windows account on a platform that allows ad hoc access,' -ForegroundColor DarkGray
    Write-Host '  and List and Use accounts on its safe. You (the logged-on user) get the access,' -ForegroundColor DarkGray
    Write-Host '  so you must be logged on as an LDAP (domain) user: a Vault user gets PASWS211E.' -ForegroundColor DarkGray
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

    return @{
        AccountID = $accountID
    }
}

function Invoke-AccountsRequestJitAccess {
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

    $ident     = Get-CyberArkAccountIdentifier -InputData $InputData
    $accountId = $ident.AccountID

    if ($ident.ErrorMessage) {
        Write-CyberArkLog -Level 'ERROR' -Message $ident.ErrorMessage
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $ident.ErrorMessage; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    if ($ident.NeedsLookup) {
        Write-CyberArkLog -Level 'DEBUG' -Message "Fetching accounts in safe '$($ident.Safe)' to locate the account."

        $lookupResp = Invoke-CyberArkAPI `
            -Token       $Token `
            -Method      'GET' `
            -Endpoint    '/API/Accounts' `
            -QueryParams @{ filter = (New-CyberArkSearchFilter -Criteria @{ safeName = $ident.Safe }) }

        if (-not $lookupResp.IsSuccess) {
            $msg = "Account lookup failed (HTTP $($lookupResp.StatusCode)): $($lookupResp.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $lookupResp.ErrorDetails })
            $result.Failures++
            $result.ItemsProcessed++
            $result.IsFatal = ($lookupResp.StatusCode -in @(401, 0))
            return $result
        }

        [array]$acctList = @(if ($lookupResp.Data -and
                                 $lookupResp.Data.PSObject.Properties['value'] -and
                                 $null -ne $lookupResp.Data.value) {
            $lookupResp.Data.value
        })

        $acctMatch = Select-CyberArkAccountMatch -Accounts $acctList `
            -AccountName $ident.AccountName -UserName $ident.UserName -Safe $ident.Safe
        if ($acctMatch.ErrorMessage) {
            Write-CyberArkLog -Level 'ERROR' -Message $acctMatch.ErrorMessage
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $acctMatch.ErrorMessage; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        $accountId = $acctMatch.AccountID
        Write-CyberArkLog -Level 'DEBUG' -Message "Resolved account ID: $accountId"
    }

    $encodedId = [Uri]::EscapeDataString($accountId)
    $endpoint  = "/API/Accounts/$encodedId/GrantAdministrativeAccess"

    Write-CyberArkLog -Level 'INFO'  -Message "Starting JIT access request for account ID: $accountId"
    Write-CyberArkLog -Level 'DEBUG' -Message "POST $endpoint"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST $endpoint would be performed."
        $result.Results.Add([PSCustomObject]@{ AccountID = $accountId; Status = 'WhatIf' })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # No body: the PVWA grants access to the logged-on user (PVWA 10.6+, psPAS Request-PASJustInTimeAccess).
    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint $endpoint `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Request JIT Access failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $response.ErrorMessage
            ErrorDetails = $response.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        return $result
    }

    $result.Results.Add([PSCustomObject]@{
        AccountID = $accountId
        Status    = 'Granted'
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Request JIT Access complete for account ID: $accountId."

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
