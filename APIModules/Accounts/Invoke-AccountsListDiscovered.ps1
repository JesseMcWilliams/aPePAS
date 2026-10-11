#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Discovered Accounts'
    Category         = 'Accounts'
    Action           = 'ListDiscovered'
    Description      = 'List the Pending (discovered) accounts waiting to be onboarded. Needs Vault Admins or PVWAAccountsFeedAdmins membership.'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @()
    Priority         = 50
    Version          = '1.0.0'
}

function Get-AccountsListDiscoveredInput {
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

    Write-Host '  Search Criteria  (press Enter to skip each field)' -ForegroundColor DarkGray
    Write-Host ''

    $fields = [ordered]@{
        Search         = 'Search userName and address. Leave blank for all pending accounts.'
        SearchType     = 'contains (default) or startswith.'
        PlatformType   = 'For example Windows Server Local, Windows Domain, Unix, Unix SSH Key, AWS.'
        Privileged     = 'true or false. Leave blank for both.'
        AccountEnabled = 'true or false. Leave blank for both.'
        AccountType    = 'Local or Domain.'
        AccountSource  = 'CPMScanner or ExternalSource.'
        Sort           = 'Up to 3 properties, each optionally followed by asc/desc, comma-separated (for example userName desc).'
    }
    $answers = @{}
    foreach ($name in $fields.Keys) {
        $answers[$name] = Show-FieldPrompt -Label $name `
            -Default $(if ($Defaults[$name]) { $Defaults[$name] } else { '' }) `
            -Description $fields[$name]
    }
    return $answers
}

function Invoke-AccountsListDiscovered {
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
    $read = { param([string]$Key) if ($InputData[$Key]) { "$($InputData[$Key])".Trim() } else { '' } }

    # Query parameters (14.6 Swagger, GET /api/DiscoveredAccounts). The filter keys and their
    # values are documented there; values with spaces are quoted by New-CyberArkSearchFilter.
    $queryParams = @{}
    if (& $read 'Search')     { $queryParams['search']     = & $read 'Search' }
    if (& $read 'SearchType') { $queryParams['searchType'] = & $read 'SearchType' }
    if (& $read 'Sort')       { $queryParams['sort']       = & $read 'Sort' }

    $criteria = @{}
    foreach ($pair in @(@('PlatformType', 'platformType'), @('Privileged', 'privileged'), @('AccountEnabled', 'accountEnabled'),
                        @('AccountType', 'accountType'), @('AccountSource', 'accountSource'))) {
        $value = & $read $pair[0]
        if (-not $value) { continue }
        if ($pair[0] -in @('Privileged', 'AccountEnabled')) {
            if ($value -notmatch '^(?i)(true|false)$') {
                $msg = "$($pair[0]) must be true or false (got '$value')."
                Write-CyberArkLog -Level 'ERROR' -Message $msg
                $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
                $result.Failures++
                $result.ItemsProcessed++
                return $result
            }
            $value = $value.ToLower()
        }
        $criteria[$pair[1]] = $value
    }
    if ($criteria.Count -gt 0) { $queryParams['filter'] = New-CyberArkSearchFilter -Criteria $criteria }

    Write-CyberArkLog -Level 'INFO'  -Message 'Starting discovered (pending) account list retrieval.'
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/DiscoveredAccounts | $(($queryParams.GetEnumerator() | ForEach-Object { "$($_.Key)='$($_.Value)'" }) -join '  ')"

    $response = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/API/DiscoveredAccounts' `
        -QueryParams $queryParams

    if (-not $response.IsSuccess) {
        $hint = if ($response.StatusCode -eq 404) { ' The Pending Accounts API needs PVWA 11.6 or later.' } else { '' }
        $msg  = "Discovered account list failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)$hint"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $response.ErrorDetails })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        return $result
    }

    [array]$accounts = @(if ($response.Data -and $response.Data.PSObject.Properties['value'] -and $null -ne $response.Data.value) {
        $response.Data.value
    })

    if ((-not $accounts) -or $accounts.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message 'No discovered accounts returned for the given criteria.'
        return $result
    }

    foreach ($account in $accounts) {
        $result.Results.Add((ConvertTo-CyberArkDiscoveredAccountRow -Account $account))
        $result.Successes++
        $result.ItemsProcessed++
    }

    Write-CyberArkLog -Level 'INFO' -Message "Discovered account list complete. Accounts retrieved: $($result.Successes)."
    return $result
}
