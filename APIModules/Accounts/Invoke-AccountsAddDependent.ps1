#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Dependent Account'
    Category         = 'Accounts'
    Action           = 'AddDependent'
    Description      = 'Add a dependent account (for example a Windows service or scheduled task) to a master account (Self-Hosted PVWA 14.6 or later).'
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
        @{ Column = 'Name';                       Required = $false; Description = 'Dependent account name. Leave blank to let the PVWA name it.' }
        @{ Column = 'PlatformID';                 Required = $true;  Description = 'Dependent account platform ID (for example a Windows Service platform).' }
        @{ Column = 'AutomaticManagementEnabled'; Required = $false; Description = 'true/false. Leave blank for the PVWA default (true).' }
        @{ Column = 'ManualManagementReason';     Required = $false; Description = 'Reason for turning automatic management off.' }
        @{ Column = 'PlatformAccountProperties';  Required = $false; Description = 'Platform properties as Key=Value pairs separated by semicolons, for example Address=srv01;ServiceName=svcA. Platform_<Key> columns are also read and win over this column.' }
    )
    Priority         = 53
    Version          = '1.0.0'
}

# Reads the dependent account's platform properties from one input row. Two forms are accepted:
#   PlatformAccountProperties = 'Key=Value;Key2=Value2'  (split on ';', then on the first '=')
#   Platform_<Key> columns, the same names Get/List Dependent Accounts output, so an exported
#   row can be edited and fed back. A Platform_<Key> column wins over the same key in
#   PlatformAccountProperties. Blank values are skipped (not set).
# Values can't contain ';' in the combined column; use a Platform_<Key> column for those.
function script:ConvertFrom-AccountsAddDependentPlatformInput {
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

function Get-AccountsAddDependentInput {
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

    Write-Host '  Add Dependent Account  (Self-Hosted PVWA 14.6 or later; press Enter to skip optional fields)' -ForegroundColor DarkGray
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

    $name = Show-FieldPrompt -Label 'Name' `
        -Default $(if ($Defaults['Name']) { $Defaults['Name'] } else { '' }) `
        -Description 'Dependent account name. Leave blank to let the PVWA name it.'

    $platformID = Show-FieldPrompt -Label 'PlatformID' `
        -Default $(if ($Defaults['PlatformID']) { $Defaults['PlatformID'] } else { '' }) `
        -Description 'Dependent account platform ID. Required.'

    $platformProps = Show-FieldPrompt -Label 'PlatformAccountProperties' `
        -Default $(if ($Defaults['PlatformAccountProperties']) { $Defaults['PlatformAccountProperties'] } else { '' }) `
        -Description 'Platform properties as Key=Value;Key2=Value2 (for example Address=srv01;ServiceName=svcA).'

    $autoManaged = Show-FieldPrompt -Label 'AutomaticManagementEnabled' `
        -Default $(if ($Defaults['AutomaticManagementEnabled']) { $Defaults['AutomaticManagementEnabled'] } else { '' }) `
        -Description 'true/false. Leave blank for the PVWA default (true).'

    $reason = Show-FieldPrompt -Label 'ManualManagementReason' `
        -Default $(if ($Defaults['ManualManagementReason']) { $Defaults['ManualManagementReason'] } else { '' }) `
        -Description 'Reason for turning automatic management off. Leave blank to skip.'

    return @{
        AccountID                  = $accountID
        Name                       = $name
        PlatformID                 = $platformID
        PlatformAccountProperties  = $platformProps
        AutomaticManagementEnabled = $autoManaged
        ManualManagementReason     = $reason
    }
}

function Invoke-AccountsAddDependent {
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
    $name       = & $readText 'Name'
    $platformID = & $readText 'PlatformID'
    $autoText   = & $readText 'AutomaticManagementEnabled'
    $reason     = & $readText 'ManualManagementReason'

    # -- Validation (before any API call) -------------------------------------
    $validationError = ''
    if (-not $platformID) {
        $validationError = 'PlatformID is required.'
    } elseif ($autoText -and $autoText -notmatch '^(?i)(true|false)$') {
        $validationError = "AutomaticManagementEnabled must be true or false (got '$autoText')."
    }
    $platformInput = $null
    if (-not $validationError) {
        $platformInput = script:ConvertFrom-AccountsAddDependentPlatformInput -InputData $InputData
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

    # -- Build request body (BaseDependentAccountModel, 14.6 Swagger) --------
    $body = @{ platformId = $platformID }
    if ($name) { $body['name'] = $name }
    if ($platformInput.Properties.Count -gt 0) { $body['platformAccountProperties'] = $platformInput.Properties }
    if ($autoText -or $reason) {
        $secretMgmt = @{}
        if ($autoText) { $secretMgmt['automaticManagementEnabled'] = ($autoText -ieq 'true') }
        if ($reason)   { $secretMgmt['manualManagementReason']     = $reason }
        $body['secretManagement'] = $secretMgmt
    }

    $endpoint = "/API/Accounts/$([Uri]::EscapeDataString($accountId))/DependentAccounts"
    Write-CyberArkLog -Level 'INFO'  -Message "Adding dependent account (platform $platformID) to master account $accountId"
    Write-CyberArkLog -Level 'DEBUG' -Message "POST $endpoint"

    $newRow = {
        param([string]$DependentId, [string]$Status, $Source)
        $row = [ordered]@{
            MasterAccountID    = $accountId
            DependentAccountID = $DependentId
            Name               = $name
            PlatformID         = $platformID
            AutoManaged        = if ($autoText) { ($autoText -ieq 'true') } else { '' }
            ManualReason       = $reason
            Status             = $Status
        }
        $props = $platformInput.Properties
        if ($null -ne $Source) {
            if ($Source.PSObject.Properties['name'] -and $Source.name)             { $row['Name'] = $Source.name }
            if ($Source.PSObject.Properties['platformId'] -and $Source.platformId) { $row['PlatformID'] = $Source.platformId }
            if ($Source.PSObject.Properties['secretManagement'] -and $null -ne $Source.secretManagement) {
                $sm = $Source.secretManagement
                if ($sm.PSObject.Properties['automaticManagementEnabled'] -and $null -ne $sm.automaticManagementEnabled) { $row['AutoManaged'] = $sm.automaticManagementEnabled }
                if ($sm.PSObject.Properties['manualManagementReason'] -and $null -ne $sm.manualManagementReason)         { $row['ManualReason'] = $sm.manualManagementReason }
            }
            if ($Source.PSObject.Properties['platformAccountProperties'] -and $null -ne $Source.platformAccountProperties) {
                $props = @{}
                foreach ($p in $Source.platformAccountProperties.PSObject.Properties) { $props[$p.Name] = $p.Value }
            }
        }
        foreach ($key in @($props.Keys | Sort-Object)) { $row["Platform_$key"] = $props[$key] }
        [PSCustomObject]$row
    }

    # -- WhatIf (before the API call) -----------------------------------------
    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST $endpoint would be performed."
        $result.Results.Add((& $newRow '' 'WhatIf' $null))
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint $endpoint `
        -Body     $body `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $errMsg = $response.ErrorMessage
        if ($response.StatusCode -eq 404) {
            $errMsg = "$errMsg (if the account exists, the PVWA may be older than 14.6, which added dependent accounts)"
        }
        Write-CyberArkLog -Level 'ERROR' -Message "Add Dependent Account failed (HTTP $($response.StatusCode)): $errMsg"
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

    # 201 returns BaseDependentAccountModel. Guard every property; fall back to the input values.
    $created = $response.Data
    if ($created -is [array]) { $created = @($created)[0] }
    if ($null -ne $created -and -not ($created.PSObject.Properties['dependentAccountId'] -or $created.PSObject.Properties['platformId'])) { $created = $null }
    $newId = if ($null -ne $created -and $created.PSObject.Properties['dependentAccountId'] -and $created.dependentAccountId) { "$($created.dependentAccountId)" } else { '' }

    $result.Results.Add((& $newRow $newId 'Added' $created))
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Add Dependent Account complete. DependentAccountID=$newId MasterAccountID=$accountId"
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
