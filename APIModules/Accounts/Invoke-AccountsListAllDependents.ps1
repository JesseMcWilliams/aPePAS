#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List All Dependent Accounts'
    Category         = 'Accounts'
    MenuGroup        = 'Dependent accounts'
    Action           = 'ListAllDependents'
    Description      = 'List dependent accounts across the vault, with optional safe, platform and master account filters (Self-Hosted PVWA 14.6 or later).'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @()
    Priority         = 51
    Version          = '1.0.0'
}

# Maps one dependent account object (DependentAccountWithDeletedModel in the PVWA 14.6 Swagger)
# onto a flat output row. Every property is optional under strict mode. Unix-time fields are
# shown with ConvertFrom-CyberArkExpirationTime. platformAccountProperties keys become
# Platform_<Key> columns, the same convention as Accounts/Get and Accounts/List.
function script:ConvertTo-AccountsListAllDependentsRow {
    param([Parameter(Mandatory = $true)] [object]$Dependent)
    $read = {
        param($Object, [string]$Name)
        if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { $Object.$Name } else { '' }
    }
    $sm = & $read $Dependent 'secretManagement'
    if ($sm -eq '') { $sm = $null }

    $row = [ordered]@{
        MasterAccountID    = & $read $Dependent 'accountId'
        DependentAccountID = & $read $Dependent 'dependentAccountId'
        Name               = & $read $Dependent 'name'
        PlatformID         = & $read $Dependent 'platformId'
        SafeName           = & $read $Dependent 'safeName'
        FolderName         = & $read $Dependent 'folderName'
        AutoManaged        = & $read $sm 'automaticManagementEnabled'
        ManualReason       = & $read $sm 'manualManagementReason'
        CPMStatus          = & $read $sm 'status'
        LastCPMModified    = ConvertFrom-CyberArkExpirationTime (& $read $sm 'lastModifiedTime')
        LastReconciled     = ConvertFrom-CyberArkExpirationTime (& $read $sm 'lastReconciledTime')
        LastVerified       = ConvertFrom-CyberArkExpirationTime (& $read $sm 'lastVerifiedTime')
        CategoryModified   = ConvertFrom-CyberArkExpirationTime (& $read $Dependent 'categoryModificationTime')
        Created            = ConvertFrom-CyberArkExpirationTime (& $read $Dependent 'createdTime')
        IsDeleted          = & $read $Dependent 'isDeleted'
        Deleted            = ConvertFrom-CyberArkExpirationTime (& $read $Dependent 'deletionTime')
    }

    $props = & $read $Dependent 'platformAccountProperties'
    if ($props -is [System.Collections.IDictionary]) {
        foreach ($key in $props.Keys) { $row["Platform_$key"] = $props[$key] }
    } elseif ($props -ne '' -and $null -ne $props) {
        foreach ($p in $props.PSObject.Properties) { $row["Platform_$($p.Name)"] = $p.Value }
    }
    return [PSCustomObject]$row
}

# The 14.6 Swagger says this endpoint returns a bare array. psPAS pages it by a Total count and
# reads the items from the first collection property, which implies a wrapped object. Accept a
# bare array, a wrapper property (value, dependentAccounts, items, or the first array-valued
# property), or a single object.
function script:Get-AccountsListAllDependentsItems {
    param([AllowNull()] [object]$Data)
    if ($null -eq $Data) { return ,@() }
    if ($Data -is [array]) { return ,@($Data | Where-Object { $null -ne $_ }) }
    foreach ($name in @('value', 'dependentAccounts', 'items')) {
        if ($Data.PSObject.Properties[$name]) { return ,@($Data.$name | Where-Object { $null -ne $_ }) }
    }
    foreach ($p in $Data.PSObject.Properties) {
        if ($p.Value -is [array]) { return ,@($p.Value | Where-Object { $null -ne $_ }) }
    }
    if ($Data.PSObject.Properties['dependentAccountId']) { return ,@($Data) }
    return ,@()
}

# Fills the Platform_* columns missing from a row with '' so every row has the same columns
# (Export-Csv on PS 5.1 takes its headers from the first row only).
function script:Add-AccountsListAllDependentsColumnParity {
    param([Parameter(Mandatory = $true)] [PSCustomObject]$Result)
    if ($Result.Results.Count -eq 0) { return }
    $keys = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($row in $Result.Results) {
        foreach ($prop in $row.PSObject.Properties) {
            if ($prop.Name.StartsWith('Platform_') -and $seen.Add($prop.Name)) { $keys.Add($prop.Name) }
        }
    }
    foreach ($row in $Result.Results) {
        foreach ($key in $keys) {
            if (-not $row.PSObject.Properties[$key]) { Add-Member -InputObject $row -MemberType NoteProperty -Name $key -Value '' }
        }
    }
}

function Get-AccountsListAllDependentsInput {
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

    Write-Host '  Dependent accounts need Self-Hosted PVWA 14.6 or later. Leave every field blank to list them all.' -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'Safe Name' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Description 'Only dependent accounts in this safe. Leave blank to skip.'

    $platformID = Show-FieldPrompt -Label 'Platform ID' `
        -Default $(if ($Defaults['PlatformID']) { $Defaults['PlatformID'] } else { '' }) `
        -Description 'Only dependent accounts on this platform. Leave blank to skip.'

    $search = Show-FieldPrompt -Label 'Search' `
        -Default $(if ($Defaults['Search']) { $Defaults['Search'] } else { '' }) `
        -Description 'Optional keywords to search for in the dependent accounts.'

    $includeDeleted = Show-FieldPrompt -Label 'Include Deleted' `
        -Default $(if ($Defaults['IncludeDeleted']) { $Defaults['IncludeDeleted'] } else { '' }) `
        -Description 'true to include deleted dependent accounts. Leave blank for false.'

    return @{
        SafeName        = $safeName
        PlatformID      = $platformID
        Search          = $search
        IncludeDeleted  = $includeDeleted
    }
}

function Invoke-AccountsListAllDependents {
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

    $readText = {
        param([string]$Key)
        if ($InputData.ContainsKey($Key) -and $null -ne $InputData[$Key]) { "$($InputData[$Key])".Trim() } else { '' }
    }
    $safeName       = & $readText 'SafeName'
    $platformID     = & $readText 'PlatformID'
    $search         = & $readText 'Search'
    $includeDeleted = & $readText 'IncludeDeleted'

    # IncludeDeleted is a true/false string (or a real bool from -InputJson). Never cast a string to [bool].
    if ($includeDeleted -and $includeDeleted -notmatch '^(?i)(true|false)$') {
        $msg = "IncludeDeleted must be true or false (got '$includeDeleted')."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # "<field> eq <value>" joined with AND, values with spaces quoted (New-CyberArkSearchFilter).
    # platformId and SafeName confirmed live on PVWA 2026-10-11. psPAS's MasterAccountId filter
    # (and masterAccountId / accountId) gets HTTP 400 PASWS357E, so there is no master filter here:
    # List Dependent Accounts covers one master account.
    $criteria = @{}
    if ($platformID) { $criteria['platformId']      = $platformID }
    if ($safeName)   { $criteria['SafeName']        = $safeName }

    $queryParams = @{}
    if ($criteria.Count -gt 0) { $queryParams['filter'] = New-CyberArkSearchFilter -Criteria $criteria }
    if ($search)               { $queryParams['search'] = $search }
    if ($includeDeleted)       { $queryParams['includeDeleted'] = $includeDeleted.ToLowerInvariant() }

    $endpoint = '/API/DependentAccounts'
    Write-CyberArkLog -Level 'INFO'  -Message 'Listing dependent accounts across the vault.'
    Write-CyberArkLog -Level 'DEBUG' -Message "GET $endpoint filter='$($queryParams['filter'])' search='$search' includeDeleted='$includeDeleted'"

    # Normal offset/limit paging (the 14.6 Swagger lists offset and limit for this endpoint).
    $response = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    $endpoint `
        -QueryParams $queryParams

    if (-not $response.IsSuccess) {
        $errMsg = $response.ErrorMessage
        if ($response.StatusCode -eq 404) {
            $errMsg = "$errMsg (the PVWA may be older than 14.6, which added dependent accounts)"
        }
        Write-CyberArkLog -Level 'ERROR' -Message "List All Dependent Accounts failed (HTTP $($response.StatusCode)): $errMsg"
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $errMsg
            ErrorDetails = $response.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        return $result
    }

    $allItems = [System.Collections.Generic.List[object]]::new()
    foreach ($item in (script:Get-AccountsListAllDependentsItems -Data $response.Data)) { $allItems.Add($item) }

    # Invoke-CyberArkAPI can only page a wrapped response (it looks for the collection property).
    # If the PVWA sends a bare array, as the Swagger says, a full first page means there may be
    # more, so keep requesting pages here until a short or empty page comes back.
    if ($response.Data -is [array]) {
        $pageSize = 1000
        if ($Token.PSObject.Properties['PageSize']) {
            $profileSize = 0
            if ([int]::TryParse("$($Token.PageSize)", [ref]$profileSize) -and $profileSize -gt 0) { $pageSize = $profileSize }
        }
        $lastCount = $allItems.Count
        $firstId   = if ($lastCount -gt 0 -and $allItems[0].PSObject.Properties['dependentAccountId']) { "$($allItems[0].dependentAccountId)" } else { '' }
        while ($lastCount -ge $pageSize) {
            $pageParams = [hashtable]$queryParams.Clone()
            $pageParams['limit']  = $pageSize
            $pageParams['offset'] = $allItems.Count
            $pageResp = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint $endpoint -QueryParams $pageParams -PageSize 0
            if (-not $pageResp.IsSuccess) {
                $msg = "List All Dependent Accounts failed on the page at offset $($pageParams['offset']) (HTTP $($pageResp.StatusCode)): $($pageResp.ErrorMessage)"
                Write-CyberArkLog -Level 'ERROR' -Message $msg
                $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $pageResp.ErrorDetails })
                $result.Failures++
                $result.ItemsProcessed++
                $result.IsFatal = ($pageResp.StatusCode -in @(401, 0))
                break
            }
            $page = script:Get-AccountsListAllDependentsItems -Data $pageResp.Data
            if ($page.Count -eq 0) { break }
            # Guard against a server that ignores offset and returns the same page again.
            $pageFirstId = if ($page[0].PSObject.Properties['dependentAccountId']) { "$($page[0].dependentAccountId)" } else { '' }
            if ($pageFirstId -and $pageFirstId -eq $firstId) { break }
            $firstId = $pageFirstId
            foreach ($item in $page) { $allItems.Add($item) }
            $lastCount = $page.Count
        }
    }

    foreach ($item in $allItems) {
        $result.Results.Add((script:ConvertTo-AccountsListAllDependentsRow -Dependent $item))
        $result.Successes++
        $result.ItemsProcessed++
    }
    script:Add-AccountsListAllDependentsColumnParity -Result $result

    Write-CyberArkLog -Level 'INFO' -Message "List All Dependent Accounts complete: $($allItems.Count) dependent account(s)."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
