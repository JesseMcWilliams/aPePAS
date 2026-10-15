#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Dependent Accounts'
    Category         = 'Accounts'
    MenuGroup        = 'Dependent accounts'
    Action           = 'ListDependents'
    Description      = 'List the dependent accounts of one master account (Self-Hosted PVWA 14.6 or later).'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountID';   Required = $false; Description = 'Master account ID. Give this, or AccountName and/or UserName with Safe. When set, the other identifier columns are ignored.' }
        @{ Column = 'AccountName'; Required = $false; Description = 'Master account (object) name: the name field, not the username. An ObjectName column is also accepted. Needs Safe.' }
        @{ Column = 'UserName';    Required = $false; Description = 'Master account username. Needs Safe. With AccountName, the account must match both. More than one match fails the row.' }
        @{ Column = 'Safe';        Required = $false; Description = 'Safe containing the master account. Required unless AccountID is set.' }
        @{ Column = 'Search';      Required = $false; Description = 'Optional keywords to search for in the dependent accounts.' }
        @{ Column = 'Failed';      Required = $false; Description = 'true to return only failed dependent accounts. Blank or false returns all.' }
    )
    Priority         = 50
    Version          = '1.0.0'
}

# Maps one dependent account object (DependentAccountModel in the PVWA 14.6 Swagger) onto a flat
# output row. Every property is optional under strict mode. Unix-time fields are shown with
# ConvertFrom-CyberArkExpirationTime. platformAccountProperties keys become Platform_<Key>
# columns, the same convention as Accounts/Get and Accounts/List.
function script:ConvertTo-AccountsListDependentsRow {
    param(
        [Parameter(Mandatory = $true)] [object]$Dependent,
        [string]$MasterAccountId = ''
    )
    $read = {
        param($Object, [string]$Name)
        if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { $Object.$Name } else { '' }
    }
    $sm = & $read $Dependent 'secretManagement'
    if ($sm -eq '') { $sm = $null }

    $master = & $read $Dependent 'accountId'
    if (-not $master) { $master = $MasterAccountId }

    $row = [ordered]@{
        MasterAccountID    = $master
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
    }

    $props = & $read $Dependent 'platformAccountProperties'
    if ($props -is [System.Collections.IDictionary]) {
        foreach ($key in $props.Keys) { $row["Platform_$key"] = $props[$key] }
    } elseif ($props -ne '' -and $null -ne $props) {
        foreach ($p in $props.PSObject.Properties) { $row["Platform_$($p.Name)"] = $p.Value }
    }
    return [PSCustomObject]$row
}

# The 14.6 Swagger says the list is a bare array of DependentAccountModel. psPAS returns the
# response as-is for this call, so a wrapped shape can't be ruled out. Accept a bare array, a
# wrapper property (value, dependentAccounts, items, or the first array-valued property), or a
# single object.
function script:Get-AccountsListDependentsItems {
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
function script:Add-AccountsListDependentsColumnParity {
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

function Get-AccountsListDependentsInput {
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

    Write-Host '  Dependent accounts need Self-Hosted PVWA 14.6 or later.' -ForegroundColor DarkGray
    Write-Host ''

    $accountID = Show-FieldPrompt -Label 'Master Account ID' `
        -Default $(if ($Defaults['AccountID']) { $Defaults['AccountID'] } else { '' }) `
        -Description 'Master account ID, or leave blank to search by name/username/address.'

    if (-not $accountID) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Name, username, or address to find the master account.'
        if ($searchTerm) {
            $profileVar = Get-Variable -Name 'ActiveProfile' -Scope 'Script' -ErrorAction SilentlyContinue
            $ignoreSSL  = if ($profileVar -and $profileVar.Value -and $profileVar.Value.PSObject.Properties['IgnoreSSL']) { [bool]$profileVar.Value.IgnoreSSL } else { $false }
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

    $search = Show-FieldPrompt -Label 'Dependent Search' `
        -Default $(if ($Defaults['Search']) { $Defaults['Search'] } else { '' }) `
        -Description 'Optional keywords to search for in the dependent accounts. Leave blank for all.'

    $failed = Show-FieldPrompt -Label 'Failed Only' `
        -Default $(if ($Defaults['Failed']) { $Defaults['Failed'] } else { '' }) `
        -Description 'true to list only failed dependent accounts. Leave blank for all.'

    return @{
        AccountID = $accountID
        Search    = $search
        Failed    = $failed
    }
}

function Invoke-AccountsListDependents {
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

    # Failed is a true/false string (or a real bool from -InputJson). Never cast a string to [bool].
    $failedText = if ($null -ne $InputData['Failed']) { "$($InputData['Failed'])".Trim() } else { '' }
    if ($failedText -and $failedText -notmatch '^(?i)(true|false)$') {
        $msg = "Failed must be true or false (got '$failedText')."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }
    $search = if ($null -ne $InputData['Search']) { "$($InputData['Search'])".Trim() } else { '' }

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

    $encodedId = [Uri]::EscapeDataString($accountId)
    $endpoint  = "/API/Accounts/$encodedId/DependentAccounts"

    $queryParams = @{}
    if ($search)     { $queryParams['search'] = $search }
    if ($failedText) { $queryParams['failed'] = $failedText.ToLowerInvariant() }

    Write-CyberArkLog -Level 'INFO'  -Message "Listing dependent accounts of master account ID: $accountId"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET $endpoint"

    # The Swagger defines no paging parameters for this endpoint, so it is a single request.
    $response = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    $endpoint `
        -QueryParams $queryParams `
        -PageSize    0

    if (-not $response.IsSuccess) {
        $errMsg = $response.ErrorMessage
        if ($response.StatusCode -eq 404) {
            $errMsg = "$errMsg (if the account exists, the PVWA may be older than 14.6, which added dependent accounts)"
        }
        Write-CyberArkLog -Level 'ERROR' -Message "List Dependent Accounts failed (HTTP $($response.StatusCode)): $errMsg"
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

    $items = script:Get-AccountsListDependentsItems -Data $response.Data
    foreach ($item in $items) {
        $result.Results.Add((script:ConvertTo-AccountsListDependentsRow -Dependent $item -MasterAccountId $accountId))
    }
    script:Add-AccountsListDependentsColumnParity -Result $result

    # One success per master account processed. The rows are the dependent accounts.
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "List Dependent Accounts complete for master account ID ${accountId}: $($items.Count) dependent account(s)."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
