#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Update Dependent Account'
    Category         = 'Accounts'
    MenuGroup        = 'Dependent accounts'
    Action           = 'UpdateDependent'
    Description      = 'Update the name, platform properties or management settings of a dependent account. Blank fields keep their current values (Self-Hosted PVWA 14.6 or later).'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountID';                  Required = $false; Description = 'Master account ID. Give this, or AccountName and/or UserName with Safe. When set, the other identifier columns are ignored.' }
        @{ Column = 'AccountName';                Required = $false; Description = 'Master account (object) name: the name field, not the username. An ObjectName column is also accepted. Needs Safe.' }
        @{ Column = 'UserName';                   Required = $false; Description = 'Master account username. Needs Safe. With AccountName, the account must match both. More than one match fails the row.' }
        @{ Column = 'Safe';                       Required = $false; Description = 'Safe containing the master account. Required unless AccountID is set.' }
        @{ Column = 'DependentAccountID';         Required = $true;  Description = 'ID of the dependent account to update (from List Dependent Accounts).' }
        @{ Column = 'Name';                       Required = $false; Description = 'New dependent account name. Blank keeps the current name.' }
        @{ Column = 'AutomaticManagementEnabled'; Required = $false; Description = 'true/false. Blank keeps the current setting.' }
        @{ Column = 'ManualManagementReason';     Required = $false; Description = 'Reason for manual management. Blank keeps the current reason.' }
        @{ Column = 'PlatformAccountProperties';  Required = $false; Description = 'Properties to change as Key=Value pairs separated by semicolons. Keys not listed keep their current values. Platform_<Key> columns are also read and win over this column.' }
    )
    Priority         = 54
    Version          = '1.0.0'
}

# Reads the platform properties to change from one input row. Same two forms as Add Dependent
# Account: PlatformAccountProperties = 'Key=Value;Key2=Value2' and Platform_<Key> columns (the
# names Get/List Dependent Accounts output). A Platform_<Key> column wins over the same key in
# PlatformAccountProperties. Blank values are skipped, so the current value is kept.
function script:ConvertFrom-AccountsUpdateDependentPlatformInput {
    param([Parameter(Mandatory = $true)] [hashtable]$InputData)
    $props = @{}
    $text  = if ($null -ne $InputData['PlatformAccountProperties']) { "$($InputData['PlatformAccountProperties'])".Trim() } else { '' }
    if ($text) {
        foreach ($segment in ($text -split ';')) {
            $seg = $segment.Trim()
            if (-not $seg) { continue }
            $eq = $seg.IndexOf('=')
            if ($eq -lt 1) {
                return [PSCustomObject]@{ Properties = $null; ErrorMessage = "PlatformAccountProperties entry '$seg' must be Key=Value." }
            }
            $key   = $seg.Substring(0, $eq).Trim()
            $value = $seg.Substring($eq + 1).Trim()
            if ($value -ne '') { $props[$key] = $value }
        }
    }
    foreach ($colName in @($InputData.Keys)) {
        if ("$colName" -like 'Platform_?*') {
            $value = if ($null -ne $InputData[$colName]) { "$($InputData[$colName])".Trim() } else { '' }
            if ($value -ne '') { $props["$colName".Substring(9)] = $value }
        }
    }
    return [PSCustomObject]@{ Properties = $props; ErrorMessage = '' }
}

# Interactive picker: lists the master account's dependent accounts and returns the chosen
# dependentAccountId, or $null. Read-MenuChoice comes from the driver scope.
function script:Select-AccountsUpdateDependentId {
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

function Get-AccountsUpdateDependentInput {
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

    Write-Host '  Update Dependent Account  (Self-Hosted PVWA 14.6 or later; blank fields keep their current values)' -ForegroundColor DarkGray
    Write-Host ''

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
        -Description 'Dependent account ID, or leave blank to pick from this account''s dependent accounts.'

    if (-not $dependentID) {
        $dependentID = script:Select-AccountsUpdateDependentId -Token $Token -AccountID $accountID -IgnoreSSL $ignoreSSL
        if (-not $dependentID) { return $null }
    }

    $name = Show-FieldPrompt -Label 'Name' `
        -Default $(if ($Defaults['Name']) { $Defaults['Name'] } else { '' }) `
        -Description 'New name. Leave blank to keep the current value.'

    $platformProps = Show-FieldPrompt -Label 'PlatformAccountProperties' `
        -Default $(if ($Defaults['PlatformAccountProperties']) { $Defaults['PlatformAccountProperties'] } else { '' }) `
        -Description 'Properties to change as Key=Value;Key2=Value2. Keys not listed keep their current values.'

    $autoManaged = Show-FieldPrompt -Label 'AutomaticManagementEnabled' `
        -Default $(if ($Defaults['AutomaticManagementEnabled']) { $Defaults['AutomaticManagementEnabled'] } else { '' }) `
        -Description 'true/false. Leave blank to keep the current value.'

    $reason = Show-FieldPrompt -Label 'ManualManagementReason' `
        -Default $(if ($Defaults['ManualManagementReason']) { $Defaults['ManualManagementReason'] } else { '' }) `
        -Description 'Reason for manual management. Leave blank to keep the current value.'

    return @{
        AccountID                  = $accountID
        DependentAccountID         = $dependentID
        Name                       = $name
        PlatformAccountProperties  = $platformProps
        AutomaticManagementEnabled = $autoManaged
        ManualManagementReason     = $reason
    }
}

function Invoke-AccountsUpdateDependent {
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
    $dependentId = & $readText 'DependentAccountID'
    $name        = & $readText 'Name'
    $autoText    = & $readText 'AutomaticManagementEnabled'
    $reason      = & $readText 'ManualManagementReason'

    # --- Validation (before any API call) ---
    $validationError = ''
    if (-not $dependentId) {
        $validationError = 'DependentAccountID is required.'
    } elseif ($autoText -and $autoText -notmatch '^(?i)(true|false)$') {
        $validationError = "AutomaticManagementEnabled must be true or false (got '$autoText')."
    }
    $platformInput = $null
    if (-not $validationError) {
        $platformInput = script:ConvertFrom-AccountsUpdateDependentPlatformInput -InputData $InputData
        $validationError = $platformInput.ErrorMessage
    }
    if ($validationError) {
        Write-CyberArkLog -Level 'ERROR' -Message $validationError
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $validationError; ErrorDetails = $null })
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

    $endpoint = "/API/Accounts/$([Uri]::EscapeDataString($accountId))/DependentAccounts/$([Uri]::EscapeDataString($dependentId))"
    $hint404  = ' (if the account and dependent account exist, the PVWA may be older than 14.6, which added dependent accounts)'

    # --- GET the current values (psPAS Set-PASDependentAccount does the same) ---
    Write-CyberArkLog -Level 'INFO'  -Message "Updating dependent account $dependentId of master account $accountId"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET $endpoint"

    $current = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint $endpoint -PageSize 0

    if (-not $current.IsSuccess) {
        $errMsg = $current.ErrorMessage
        if ($current.StatusCode -eq 404) { $errMsg = "$errMsg$hint404" }
        Write-CyberArkLog -Level 'ERROR' -Message "Reading the dependent account failed (HTTP $($current.StatusCode)): $errMsg"
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $errMsg; ErrorDetails = $current.ErrorDetails })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($current.StatusCode -in @(401, 0))
        return $result
    }

    $cur = $current.Data
    if ($cur -is [array]) { $cur = @($cur)[0] }
    $read = {
        param($Object, [string]$Prop)
        if ($null -ne $Object -and $Object.PSObject.Properties[$Prop] -and $null -ne $Object.$Prop) { $Object.$Prop } else { $null }
    }
    $curSm = & $read $cur 'secretManagement'

    # --- Merge: input wins, blank keeps the current value ---
    $mergedName = if ($name) { $name } else { & $read $cur 'name' }

    $mergedProps = @{}
    $curProps = & $read $cur 'platformAccountProperties'
    if ($curProps -is [System.Collections.IDictionary]) {
        foreach ($key in $curProps.Keys) { $mergedProps["$key"] = $curProps[$key] }
    } elseif ($null -ne $curProps) {
        foreach ($p in $curProps.PSObject.Properties) { $mergedProps[$p.Name] = $p.Value }
    }
    foreach ($key in $platformInput.Properties.Keys) { $mergedProps[$key] = $platformInput.Properties[$key] }

    $mergedAuto   = if ($autoText) { ($autoText -ieq 'true') } else { & $read $curSm 'automaticManagementEnabled' }
    $mergedReason = if ($reason)   { $reason }                 else { & $read $curSm 'manualManagementReason' }

    # UpdateDependentAccountRequest (14.6 Swagger): name, platformAccountProperties, secretManagement.
    # Only the two writable secretManagement fields are sent, never status or the timestamps.
    $body = @{}
    if ($null -ne $mergedName -and "$mergedName" -ne '') { $body['name'] = "$mergedName" }
    if ($mergedProps.Count -gt 0) { $body['platformAccountProperties'] = $mergedProps }
    $secretMgmt = @{}
    if ($null -ne $mergedAuto)   { $secretMgmt['automaticManagementEnabled'] = [bool]$mergedAuto }
    if ($null -ne $mergedReason) { $secretMgmt['manualManagementReason']     = "$mergedReason" }
    if ($secretMgmt.Count -gt 0) { $body['secretManagement'] = $secretMgmt }

    $platformID = & $read $cur 'platformId'
    $newRow = {
        param([string]$Status, $Source)
        $outName  = $body['name']
        $outAuto  = if ($secretMgmt.ContainsKey('automaticManagementEnabled')) { $secretMgmt['automaticManagementEnabled'] } else { '' }
        $outWhy   = if ($secretMgmt.ContainsKey('manualManagementReason'))     { $secretMgmt['manualManagementReason'] }     else { '' }
        $outProps = $mergedProps
        if ($null -ne $Source) {
            $v = & $read $Source 'name'; if ($null -ne $v) { $outName = $v }
            $sm = & $read $Source 'secretManagement'
            $v = & $read $sm 'automaticManagementEnabled'; if ($null -ne $v) { $outAuto = $v }
            $v = & $read $sm 'manualManagementReason';     if ($null -ne $v) { $outWhy  = $v }
            $sp = & $read $Source 'platformAccountProperties'
            if ($null -ne $sp -and $sp -isnot [System.Collections.IDictionary]) {
                $outProps = @{}
                foreach ($p in $sp.PSObject.Properties) { $outProps[$p.Name] = $p.Value }
            }
        }
        $row = [ordered]@{
            MasterAccountID    = $accountId
            DependentAccountID = $dependentId
            Name               = if ($null -ne $outName) { $outName } else { '' }
            PlatformID         = if ($null -ne $platformID) { $platformID } else { '' }
            AutoManaged        = $outAuto
            ManualReason       = $outWhy
            Status             = $Status
        }
        foreach ($key in @($outProps.Keys | Sort-Object)) { $row["Platform_$key"] = $outProps[$key] }
        [PSCustomObject]$row
    }

    # --- WhatIf (before the PUT) ---
    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: PUT $endpoint would be performed."
        $result.Results.Add((& $newRow 'WhatIf' $null))
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    Write-CyberArkLog -Level 'DEBUG' -Message "PUT $endpoint"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'PUT' `
        -Endpoint $endpoint `
        -Body     $body `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $errMsg = $response.ErrorMessage
        if ($response.StatusCode -eq 404) { $errMsg = "$errMsg$hint404" }
        Write-CyberArkLog -Level 'ERROR' -Message "Update Dependent Account failed (HTTP $($response.StatusCode)): $errMsg"
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

    # 200 returns DependentAccountModel. Use it when present, else the values that were sent.
    $updated = $response.Data
    if ($updated -is [array]) { $updated = @($updated)[0] }
    if ($null -ne $updated -and -not ($updated.PSObject.Properties['dependentAccountId'] -or $updated.PSObject.Properties['platformId'])) { $updated = $null }

    $result.Results.Add((& $newRow 'Updated' $updated))
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Update Dependent Account complete: $dependentId."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
