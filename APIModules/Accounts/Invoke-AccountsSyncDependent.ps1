#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Sync Dependent Account'
    Category         = 'Accounts'
    Action           = 'SyncDependent'
    Description      = 'Synchronize a dependent account with its master account''s current password (Self-Hosted PVWA 14.6 or later).'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountID';          Required = $false; Description = 'Master account ID. Give this, or AccountName and/or UserName with Safe. When set, the other identifier columns are ignored.' }
        @{ Column = 'AccountName';        Required = $false; Description = 'Master account (object) name: the name field, not the username. An ObjectName column is also accepted. Needs Safe.' }
        @{ Column = 'UserName';           Required = $false; Description = 'Master account username. Needs Safe. With AccountName, the account must match both. More than one match fails the row.' }
        @{ Column = 'Safe';               Required = $false; Description = 'Safe containing the master account. Required unless AccountID is set.' }
        @{ Column = 'DependentAccountID'; Required = $true;  Description = 'ID of the dependent account to synchronize (from List Dependent Accounts).' }
    )
    Priority         = 56
    Version          = '1.0.0'
}

# Interactive picker: lists the master account's dependent accounts and returns the chosen
# dependentAccountId, or $null. Read-MenuChoice comes from the driver scope.
function script:Select-AccountsSyncDependentId {
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$Token,
        [Parameter(Mandatory = $true)] [string]$AccountID,
        [bool]$IgnoreSSL = $false
    )
    $resp = Invoke-CyberArkAPI -Token $Token -Method 'GET' `
        -Endpoint "/API/Accounts/$([Uri]::EscapeDataString($AccountID))/DependentAccounts" -PageSize 0 -IgnoreSSL:$IgnoreSSL
    if (-not $resp.IsSuccess) {
        $hint = if ($resp.StatusCode -eq 404) { ' (if the account exists, the PVWA may be older than 14.6, which added dependent accounts)' } else { '' }
        Write-Host "    Could not list dependent accounts: $($resp.ErrorMessage)$hint" -ForegroundColor Red
        return $null
    }
    $data  = $resp.Data
    $items = @()
    if ($data -is [array]) { $items = @($data) }
    elseif ($null -ne $data) {
        $prop = $null
        foreach ($name in @('value', 'dependentAccounts', 'items')) { if (-not $prop -and $data.PSObject.Properties[$name]) { $prop = $name } }
        if (-not $prop) { foreach ($p in $data.PSObject.Properties) { if (-not $prop -and $p.Value -is [array]) { $prop = $p.Name } } }
        if ($prop) { $items = @($data.$prop) }
        elseif ($data.PSObject.Properties['dependentAccountId']) { $items = @($data) }
    }
    $items = @($items | Where-Object { $null -ne $_ -and $_.PSObject.Properties['dependentAccountId'] -and $_.dependentAccountId })
    if ($items.Count -eq 0) {
        Write-Host "    No dependent accounts found for account $AccountID." -ForegroundColor Yellow
        return $null
    }
    Write-Host ''
    Write-Host "    Found $($items.Count) dependent account$(if ($items.Count -ne 1) { 's' }):" -ForegroundColor Cyan
    Write-Host ''
    for ($i = 0; $i -lt $items.Count; $i++) {
        $item  = $items[$i]
        $parts = @("$($item.dependentAccountId)")
        foreach ($n in @('name', 'platformId')) {
            if ($item.PSObject.Properties[$n] -and $item.$n) { $parts += "$($item.$n)" }
        }
        Write-Host "    [$($i + 1)]  $($parts -join '  |  ')" -ForegroundColor White
    }
    $sel = Read-MenuChoice -Prompt "Select dependent account [1-$($items.Count)] or B to cancel"
    if ($sel -match '^\d+$') {
        $idx = [int]$sel - 1
        if ($idx -ge 0 -and $idx -lt $items.Count) { return "$($items[$idx].dependentAccountId)" }
    }
    return $null
}

function Get-AccountsSyncDependentInput {
    <#
        Called by the driver when HasCustomInput = $true.
        Show-FieldPrompt, Read-MenuChoice and Invoke-EntitySearch are available because this module is dot-sourced into the driver scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }
    $profileVar = Get-Variable -Name 'ActiveProfile' -Scope 'Script' -ErrorAction SilentlyContinue
    $ignoreSSL  = if ($profileVar -and $profileVar.Value -and $profileVar.Value.PSObject.Properties['IgnoreSSL']) { [bool]$profileVar.Value.IgnoreSSL } else { $false }

    $accountID = Show-FieldPrompt -Label 'Master Account ID' `
        -Default $(if ($Defaults['AccountID']) { $Defaults['AccountID'] } else { '' }) `
        -Description 'Master account ID, or leave blank to search by name/username/address.'

    if (-not $accountID) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Name, username, or address to find the master account.'
        if ($searchTerm) {
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

    $dependentID = Show-FieldPrompt -Label 'Dependent Account ID' `
        -Default $(if ($Defaults['DependentAccountID']) { $Defaults['DependentAccountID'] } else { '' }) `
        -Description 'Dependent account ID to synchronize, or leave blank to pick from this account''s dependent accounts.'

    if (-not $dependentID) {
        $dependentID = script:Select-AccountsSyncDependentId -Token $Token -AccountID $accountID -IgnoreSSL $ignoreSSL
        if (-not $dependentID) { return $null }
    }

    return @{
        AccountID          = $accountID
        DependentAccountID = $dependentID
    }
}

function Invoke-AccountsSyncDependent {
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

    $dependentId = if ($null -ne $InputData['DependentAccountID']) { "$($InputData['DependentAccountID'])".Trim() } else { '' }
    if (-not $dependentId) {
        $msg = 'DependentAccountID is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

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
        Write-CyberArkLog -Level 'DEBUG' -Message "Fetching accounts in safe '$($ident.Safe)' to locate the master account."

        $lookupResp = Invoke-CyberArkAPI `
            -Token       $Token `
            -Method      'GET' `
            -Endpoint    '/API/Accounts' `
            -QueryParams @{ filter = (New-CyberArkSearchFilter -Criteria @{ safeName = $ident.Safe }); limit = 1000 }

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
        Write-CyberArkLog -Level 'DEBUG' -Message "Resolved master account ID: $accountId"
    }

    $endpoint = "/API/Accounts/$([Uri]::EscapeDataString($accountId))/DependentAccounts/$([Uri]::EscapeDataString($dependentId))/Sync"

    Write-CyberArkLog -Level 'INFO'  -Message "Synchronizing dependent account $dependentId of master account $accountId"
    Write-CyberArkLog -Level 'DEBUG' -Message "POST $endpoint"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST $endpoint would be performed."
        $result.Results.Add([PSCustomObject]@{ MasterAccountID = $accountId; DependentAccountID = $dependentId; Status = 'WhatIf' })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # No body (14.6 Swagger and psPAS Sync-PASDependentAccount, single-account form).
    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint $endpoint `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $errMsg = $response.ErrorMessage
        if ($response.StatusCode -eq 404) {
            $errMsg = "$errMsg (if the account and dependent account exist, the PVWA may be older than 14.6, which added dependent accounts)"
        }
        Write-CyberArkLog -Level 'ERROR' -Message "Sync Dependent Account failed (HTTP $($response.StatusCode)): $errMsg"
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $errMsg
            ErrorDetails = $response.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $result.Results.Add([PSCustomObject]@{ MasterAccountID = $accountId; DependentAccountID = $dependentId; Status = 'Success' })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Sync Dependent Account complete: $dependentId."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
