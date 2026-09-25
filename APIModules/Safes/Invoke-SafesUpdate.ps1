#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Update Safe'
    Category         = 'Safes'
    Action           = 'Update'
    Description      = 'Update properties of an existing safe.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';                   Required = $true;  Description = 'Name of the safe to update.' }
        @{ Column = 'Description';                Required = $false; Description = 'New description (leave blank to keep current).' }
        @{ Column = 'ManagingCPM';                Required = $false; Description = 'CPM user (leave blank to keep current).' }
        @{ Column = 'NumberOfVersionsRetention';  Required = $false; Description = 'Versions to retain. Mutually exclusive with NumberOfDaysRetention - set that instead for days-based retention.' }
        @{ Column = 'NumberOfDaysRetention';      Required = $false; Description = 'Days to retain. Mutually exclusive with NumberOfVersionsRetention - when this is greater than 0, only this is sent.' }
        @{ Column = 'AutoPurgeEnabled';           Required = $false; Description = 'Auto-purge: true/false.' }
    )
    Priority         = 13
    Version          = '1.2.0'
}

function Get-SafesUpdateInput {
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

    Write-Host '  Safe Update  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Description 'Name of the safe to update. (Required)'

    $description = Show-FieldPrompt -Label 'Description' `
        -Default $(if ($Defaults['Description']) { $Defaults['Description'] } else { '' }) `
        -Description 'New description for the safe. Leave blank to keep the current value.'

    $managingCPM = Show-FieldPrompt -Label 'ManagingCPM' `
        -Default $(if ($Defaults['ManagingCPM']) { $Defaults['ManagingCPM'] } else { '' }) `
        -Description 'CPM user to manage the safe. Leave blank to keep the current value.'

    $versionsRetention = Show-FieldPrompt -Label 'NumberOfVersionsRetention' `
        -Default $(if ($Defaults['NumberOfVersionsRetention']) { $Defaults['NumberOfVersionsRetention'] } else { '' }) `
        -Description 'Number of password versions to retain. Leave blank to keep the current value.'

    $daysRetention = Show-FieldPrompt -Label 'NumberOfDaysRetention' `
        -Default $(if ($Defaults['NumberOfDaysRetention']) { $Defaults['NumberOfDaysRetention'] } else { '' }) `
        -Description 'Number of days to retain password versions. Leave blank to keep the current value.'

    $autoPurge = Show-FieldPrompt -Label 'AutoPurgeEnabled' `
        -Default $(if ($Defaults['AutoPurgeEnabled']) { $Defaults['AutoPurgeEnabled'] } else { '' }) `
        -Description 'Enable auto-purge of expired passwords: true/false. Leave blank to keep the current value.'

    return @{
        SafeName                  = $safeName
        Description               = $description
        ManagingCPM               = $managingCPM
        NumberOfVersionsRetention = $versionsRetention
        NumberOfDaysRetention     = $daysRetention
        AutoPurgeEnabled          = $autoPurge
    }
}

function Invoke-SafesUpdate {
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
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-SafesUpdate: InputData is null or missing.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $null
            ErrorMessage = 'InputData is null or missing.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # Validate SafeName. Checked against the raw (untrimmed) input for leading whitespace, since
    # CyberArk rejects it - trimming first would silently accept what the Vault itself would reject.
    $rawSafeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])" } else { '' }
    $safeName = $rawSafeName.Trim()

    if (-not $safeName) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-SafesUpdate: SafeName is required but was empty.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'SafeName is required but was empty.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # SafeName: max 28 chars, no leading whitespace, and none of the reserved characters CyberArk
    # itself disallows in a safe name (\ / : * < > " . |) - matches psPAS's Set-PASSafe.ps1
    # [ValidateLength(0,28)] plus the Vault's own reserved-character rule.
    if ($safeName.Length -gt 28 -or $rawSafeName -match '^\s' -or $safeName -match '[\\/:*<>"\.\|]') {
        $msg = "SafeName '$safeName' is invalid - must be 1-28 characters, no leading whitespace, and cannot contain any of: \ / : * < > `" . |"
        Write-CyberArkLog -Level 'ERROR' -Message "Invoke-SafesUpdate: $msg"
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $encodedSafeName = [System.Uri]::EscapeDataString($safeName)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting safe update for: $safeName"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes/$encodedSafeName"

    # Step 1: GET current safe to retrieve values for fields not being updated
    $getResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Safes/$encodedSafeName"

    if (-not $getResponse.IsSuccess) {
        $msg = "Failed to retrieve safe '$safeName' before update (HTTP $($getResponse.StatusCode)): $($getResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $getResponse.ErrorMessage
            ErrorDetails = $getResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($getResponse.StatusCode -in @(401, 0))
        return $result
    }

    $currentSafe = $getResponse.Data

    # Step 2: Merge - use input value when provided/non-empty, otherwise fall back to current safe value

    $mergedDescription = if ($InputData.ContainsKey('Description') -and "$($InputData.Description)".Trim() -ne '') {
        "$($InputData.Description)".Trim()
    } else {
        if ($currentSafe.description) { $currentSafe.description } else { '' }
    }

    $mergedManagingCPM = if ($InputData.ContainsKey('ManagingCPM') -and "$($InputData.ManagingCPM)".Trim() -ne '') {
        "$($InputData.ManagingCPM)".Trim()
    } else {
        if ($currentSafe.managingCPM) { $currentSafe.managingCPM } else { '' }
    }

    $mergedVersionsRetention = if ($InputData.ContainsKey('NumberOfVersionsRetention') -and "$($InputData.NumberOfVersionsRetention)".Trim() -ne '') {
        [int]"$($InputData.NumberOfVersionsRetention)".Trim()
    } else {
        [int]$currentSafe.numberOfVersionsRetention
    }

    $mergedDaysRetention = if ($InputData.ContainsKey('NumberOfDaysRetention') -and "$($InputData.NumberOfDaysRetention)".Trim() -ne '') {
        [int]"$($InputData.NumberOfDaysRetention)".Trim()
    } else {
        [int]$currentSafe.numberOfDaysRetention
    }

    $mergedAutoPurge = if ($InputData.ContainsKey('AutoPurgeEnabled') -and "$($InputData.AutoPurgeEnabled)".Trim() -ne '') {
        "$($InputData.AutoPurgeEnabled)".Trim() -eq 'true'
    } else {
        [bool]$currentSafe.autoPurgeEnabled
    }

    # Location is not updatable via PUT - keep current value as-is
    $currentLocation = if ($currentSafe.location) { $currentSafe.location } else { '' }

    # Step 3: Build PUT body. SafeName must be included in the body as well as the URL - confirmed
    # live that this PUT returns HTTP 400 (no error detail in the response body) when SafeName is
    # omitted, contrary to psPAS's Set-PASSafe.ps1, which never sends it. OLACEnabled is
    # intentionally never sent - it is not a supported input for this module.
    # NumberOfVersionsRetention and NumberOfDaysRetention are mutually exclusive on this API - only
    # one may be sent; Days wins when the merged value is greater than 0, otherwise Versions is sent.
    $body = @{
        SafeName         = $safeName
        Description      = $mergedDescription
        Location         = $currentLocation
        ManagingCPM      = $mergedManagingCPM
        AutoPurgeEnabled = $mergedAutoPurge
    }
    if ($mergedDaysRetention -gt 0) {
        $body['NumberOfDaysRetention'] = $mergedDaysRetention
    } else {
        $body['NumberOfVersionsRetention'] = $mergedVersionsRetention
    }

    Write-CyberArkLog -Level 'DEBUG' -Message "PUT /API/Safes/$encodedSafeName"

    # Step 4: PUT updated safe
    $putResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'PUT' `
        -Endpoint "/API/Safes/$encodedSafeName" `
        -Body     $body `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $putResponse.IsSuccess) {
        $msg = "Safe update failed for '$safeName' (HTTP $($putResponse.StatusCode)): $($putResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $putResponse.ErrorMessage
            ErrorDetails = $putResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($putResponse.StatusCode -in @(401, 0))
        return $result
    }

    # WhatIf: Invoke-CyberArkAPI returns IsSuccess=$true without actually calling the API
    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: Safe update suppressed for '$safeName'."
        $result.Results.Add([PSCustomObject]@{
            SafeName                 = $safeName
            Description              = $mergedDescription
            Location                 = $currentLocation
            ManagingCPM              = $mergedManagingCPM
            # Pattern C: bracket notation with ContainsKey, not dot notation - NumberOfVersionsRetention
            # and NumberOfDaysRetention are mutually exclusive in $body (only one is ever set, per the
            # retention rule in Step 3 above) - dot-accessing the absent one throws under Set-StrictMode.
            # This crashed WhatIf mode unconditionally, every time, in real usage - masked by every unit
            # test here, since this test file doesn't dot-source Manage-Privilege.ps1 and so never runs
            # under strict mode itself. See Claude_Docs\Reference_Lessons-Learned-StrictMode.md
            # Section 1. Identical bug/fix as Invoke-SafesAddFromTemplate.ps1's WhatIf block.
            VersionRetention         = if ($body.ContainsKey('NumberOfVersionsRetention')) { $body['NumberOfVersionsRetention'] } else { $null }
            DayRetention             = if ($body.ContainsKey('NumberOfDaysRetention'))     { $body['NumberOfDaysRetention'] }     else { $null }
            AutoPurge                = $mergedAutoPurge
            Creator                  = ''
            Created                  = ''
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # Map response fields
    $updatedSafe = $putResponse.Data

    $creationDate = if ($updatedSafe.creationTime) {
        try { [DateTimeOffset]::FromUnixTimeSeconds($updatedSafe.creationTime).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    $result.Results.Add([PSCustomObject]@{
        SafeName         = $updatedSafe.safeName
        Description      = $updatedSafe.description
        Location         = $updatedSafe.location
        ManagingCPM      = $updatedSafe.managingCPM
        VersionRetention = $updatedSafe.numberOfVersionsRetention
        DayRetention     = $updatedSafe.numberOfDaysRetention
        AutoPurge        = $updatedSafe.autoPurgeEnabled
        Creator          = if ($updatedSafe.creator) { $updatedSafe.creator.name } else { '' }
        Created          = $creationDate
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Safe update complete for '$safeName'."

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
