#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Update Account'
    Category         = 'Accounts'
    Action           = 'Update'
    Description      = 'Update properties of an existing account. Does not change the stored credential.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountName'; Required = $true;  Description = 'Account name or username. Matched locally against name and userName fields within the specified Safe.' }
        @{ Column = 'Safe';        Required = $true;  Description = 'Safe containing the account.' }
        @{ Column = 'Address';     Required = $false; Description = 'New target address.' }
        @{ Column = 'UserName';    Required = $false; Description = 'New username.' }
        @{ Column = 'PlatformID';  Required = $false; Description = 'New platform ID.' }
        @{ Column = 'AutoManaged'; Required = $false; Description = 'Enable automatic management: true/false.' }
    )
    Priority         = 33
    Version          = '1.2.2'   # 1.2.0 switched from GET+full-PUT-merge to a JSON Patch (RFC 6902) PATCH
                                  # call carrying only the fields actually being changed, matching the
                                  # CyberArk API's current /API/Accounts/{id} contract (PATCH-only, PUT removed)
                                  # 1.2.1 fixed real production bug: single-op patches were sent as a bare
                                  # object instead of a JSON array (root cause in Invoke-CyberArkAPI, see
                                  # CyberArkComms.psm1); also hardened the result-mapping block's field
                                  # access with PSObject.Properties guards
                                  # 1.2.2 dropped Name and SafeName from InputSchema (and so from the
                                  # generated CSV template) per user request - still usable if a CSV
                                  # includes them manually, since CSV processing isn't limited to schema
                                  # columns and both are optional (Test-CsvSchema only enforces Required)
}

function Get-AccountsUpdateInput {
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

    Write-Host '  Account Update  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $accountID = Show-FieldPrompt -Label 'Account ID' `
        -Default $(if ($Defaults['AccountID']) { $Defaults['AccountID'] } else { '' }) `
        -Description 'Account ID to update, or leave blank to search by name/username/address.'

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

    $name = Show-FieldPrompt -Label 'Name' `
        -Default $(if ($Defaults['Name']) { $Defaults['Name'] } else { '' }) `
        -Description 'New account name. Leave blank to keep the current value.'

    $address = Show-FieldPrompt -Label 'Address' `
        -Default $(if ($Defaults['Address']) { $Defaults['Address'] } else { '' }) `
        -Description 'New target address. Leave blank to keep the current value.'

    $userName = Show-FieldPrompt -Label 'UserName' `
        -Default $(if ($Defaults['UserName']) { $Defaults['UserName'] } else { '' }) `
        -Description 'New username. Leave blank to keep the current value.'

    $platformID = Show-FieldPrompt -Label 'PlatformID' `
        -Default $(if ($Defaults['PlatformID']) { $Defaults['PlatformID'] } else { '' }) `
        -Description 'New platform ID. Leave blank to keep the current value.'

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Description 'New safe name (moves account). Leave blank to keep the current value.'

    $autoManaged = Show-FieldPrompt -Label 'AutoManaged' `
        -Default $(if ($Defaults['AutoManaged']) { $Defaults['AutoManaged'] } else { '' }) `
        -Description 'Enable automatic management: true/false. Leave blank to keep the current value.'

    return @{
        AccountID  = $accountID
        Name       = $name
        Address    = $address
        UserName   = $userName
        PlatformID = $platformID
        SafeName   = $safeName
        AutoManaged= $autoManaged
    }
}

function Invoke-AccountsUpdate {
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

    # Validate InputData presence
    if (-not $InputData) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-AccountsUpdate: InputData is null or missing.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $null
            ErrorMessage = 'InputData is null or missing.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $accountId   = if ($InputData['AccountID'])   { "$($InputData['AccountID'])".Trim()   } else { '' }
    $accountName = if ($InputData['AccountName']) { "$($InputData['AccountName'])".Trim() } else { '' }
    $targetSafe  = if ($InputData['Safe'])        { "$($InputData['Safe'])".Trim()        } else { '' }

    if (-not $accountId) {
        if (-not $accountName) {
            $msg = 'AccountName is required when AccountID is not provided.'
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }
        if (-not $targetSafe) {
            $msg = 'Safe is required to locate the account.'
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        Write-CyberArkLog -Level 'DEBUG' -Message "Fetching accounts in safe '$targetSafe' to locate '$accountName'."

        $lookupResp = Invoke-CyberArkAPI `
            -Token       $Token `
            -Method      'GET' `
            -Endpoint    '/API/Accounts' `
            -QueryParams @{ filter = (New-CyberArkSearchFilter -Criteria @{ safeName = $targetSafe }); limit = 1000 }

        if (-not $lookupResp.IsSuccess) {
            $msg = "Account lookup failed (HTTP $($lookupResp.StatusCode)): $($lookupResp.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $lookupResp.ErrorDetails })
            $result.Failures++
            $result.ItemsProcessed++
            $result.IsFatal = ($lookupResp.StatusCode -in @(401, 0))
            return $result
        }

        [array]$acctList = if ($lookupResp.Data -and
                               $lookupResp.Data.PSObject.Properties['value'] -and
                               $null -ne $lookupResp.Data.value) {
            @($lookupResp.Data.value)
        } else { @() }

        $acctMatch = $acctList | Where-Object {
            $_ -and
            (($_.PSObject.Properties['name']     -and $_.name     -eq $accountName) -or
             ($_.PSObject.Properties['userName'] -and $_.userName -eq $accountName))
        }
        [array]$acctMatches = @($acctMatch)

        if (-not $acctMatches -or $acctMatches.Count -eq 0) {
            $msg = "Account '$accountName' not found in safe '$targetSafe'."
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        if ($acctMatches.Count -gt 1) {
            Write-CyberArkLog -Level 'WARN' -Message "Multiple accounts matched '$accountName' in safe '$targetSafe' - using first match."
        }

        $accountId = if ($acctMatches[0].PSObject.Properties['id']) { $acctMatches[0].id } else { '' }
        if (-not $accountId) {
            $msg = "Account '$accountName' found in safe '$targetSafe' but has no ID."
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        Write-CyberArkLog -Level 'DEBUG' -Message "Resolved account ID: $accountId"
    }

    $encodedId = [System.Uri]::EscapeDataString($accountId)

    # Build a JSON Patch (RFC 6902) body containing only the fields actually supplied - the
    # CyberArk /API/Accounts/{id} endpoint is PATCH-only (PUT full-replace is no longer offered)
    # and leaves any property not named in the patch untouched. Array order matters for JSON
    # Patch semantics, so this is built as an ordered array of hashtables, not a hashtable/object.
    $patchOps = [System.Collections.Generic.List[hashtable]]::new()

    if ($InputData.ContainsKey('Name') -and "$($InputData['Name'])".Trim() -ne '') {
        $patchOps.Add(@{ op = 'replace'; path = '/name'; value = "$($InputData['Name'])".Trim() })
    }
    if ($InputData.ContainsKey('Address') -and "$($InputData['Address'])".Trim() -ne '') {
        $patchOps.Add(@{ op = 'replace'; path = '/address'; value = "$($InputData['Address'])".Trim() })
    }
    if ($InputData.ContainsKey('UserName') -and "$($InputData['UserName'])".Trim() -ne '') {
        $patchOps.Add(@{ op = 'replace'; path = '/userName'; value = "$($InputData['UserName'])".Trim() })
    }
    if ($InputData.ContainsKey('PlatformID') -and "$($InputData['PlatformID'])".Trim() -ne '') {
        $patchOps.Add(@{ op = 'replace'; path = '/platformId'; value = "$($InputData['PlatformID'])".Trim() })
    }
    if ($InputData.ContainsKey('SafeName') -and "$($InputData['SafeName'])".Trim() -ne '') {
        $patchOps.Add(@{ op = 'replace'; path = '/safeName'; value = "$($InputData['SafeName'])".Trim() })
    }
    if ($InputData.ContainsKey('AutoManaged') -and "$($InputData['AutoManaged'])".Trim() -ne '') {
        $autoManagedValue = if ("$($InputData['AutoManaged'])".Trim() -eq 'true') { 'true' } else { 'false' }
        $patchOps.Add(@{ op = 'replace'; path = '/secretManagement/automaticManagementEnabled'; value = $autoManagedValue })
    }

    [array]$patchOps = @($patchOps)

    if ($patchOps.Count -eq 0) {
        $msg = 'At least one optional field (Name, Address, UserName, PlatformID, SafeName, or AutoManaged) must be provided to update.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Starting account update for ID: $accountId"
    Write-CyberArkLog -Level 'DEBUG' -Message "PATCH /API/Accounts/$encodedId"

    $patchResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'PATCH' `
        -Endpoint "/API/Accounts/$encodedId" `
        -Body     $patchOps `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $patchResponse.IsSuccess) {
        $msg = "Account update failed for '$accountId' (HTTP $($patchResponse.StatusCode)): $($patchResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $patchResponse.ErrorMessage
            ErrorDetails = $patchResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($patchResponse.StatusCode -in @(401, 0))
        return $result
    }

    # WhatIf: Invoke-CyberArkAPI returns IsSuccess=$true without actually calling the API. No GET
    # is performed under the PATCH-only approach, so fields not included in this update are not
    # known here and are left blank rather than guessed at.
    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: Account update suppressed for '$accountId'."
        $result.Results.Add([PSCustomObject]@{
            AccountID   = $accountId
            AccountName = if ($InputData.ContainsKey('Name'))       { "$($InputData['Name'])".Trim() }       else { '' }
            Address     = if ($InputData.ContainsKey('Address'))    { "$($InputData['Address'])".Trim() }    else { '' }
            UserName    = if ($InputData.ContainsKey('UserName'))   { "$($InputData['UserName'])".Trim() }   else { '' }
            PlatformID  = if ($InputData.ContainsKey('PlatformID')) { "$($InputData['PlatformID'])".Trim() } else { '' }
            SafeName    = if ($InputData.ContainsKey('SafeName'))   { "$($InputData['SafeName'])".Trim() }   else { '' }
            SecretType  = ''
            AutoManaged = if ($InputData.ContainsKey('AutoManaged') -and "$($InputData['AutoManaged'])".Trim() -ne '') {
                              "$($InputData['AutoManaged'])".Trim() -eq 'true'
                          } else { '' }
            CPMStatus   = ''
            Created     = ''
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # Map response fields - PATCH returns the full updated AccountModel, same shape as the old PUT response
    $acct = $patchResponse.Data

    $createdDate = if ($acct.PSObject.Properties['createdTime'] -and $acct.createdTime) {
        try { [DateTimeOffset]::FromUnixTimeSeconds($acct.createdTime).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    $result.Results.Add([PSCustomObject]@{
        AccountID   = if ($acct.PSObject.Properties['id'])         { $acct.id }         else { $accountId }
        AccountName = if ($acct.PSObject.Properties['name'])       { $acct.name }       else { '' }
        Address     = if ($acct.PSObject.Properties['address'])    { $acct.address }    else { '' }
        UserName    = if ($acct.PSObject.Properties['userName'])   { $acct.userName }   else { '' }
        PlatformID  = if ($acct.PSObject.Properties['platformId']) { $acct.platformId } else { '' }
        SafeName    = if ($acct.PSObject.Properties['safeName'])   { $acct.safeName }   else { '' }
        SecretType  = if ($acct.PSObject.Properties['secretType']) { $acct.secretType } else { '' }
        AutoManaged = if ($acct.PSObject.Properties['secretManagement'] -and $acct.secretManagement -and
                          $acct.secretManagement.PSObject.Properties['automaticManagementEnabled']) {
                            $acct.secretManagement.automaticManagementEnabled } else { $false }
        CPMStatus   = if ($acct.PSObject.Properties['secretManagement'] -and $acct.secretManagement -and
                          $acct.secretManagement.PSObject.Properties['status']) {
                            $acct.secretManagement.status } else { '' }
        Created     = $createdDate
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Account update complete for '$accountId'."

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
