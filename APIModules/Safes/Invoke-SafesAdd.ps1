#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Safe'
    Category         = 'Safes'
    Action           = 'Add'
    Description      = 'Create a new CyberArk safe.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';                   Required = $true;  Description = 'Unique safe name (1-28 chars, no leading whitespace, cannot contain \ / : * < > " . |).' }
        @{ Column = 'Description';                Required = $false; Description = 'Safe description.' }
        @{ Column = 'Location';                   Required = $false; Description = 'Safe location path (default: \). Not prompted for interactively - every safe is created at the default location unless overridden here via CSV/bulk input.' }
        @{ Column = 'ManagingCPM';               Required = $false; Description = 'CPM user managing this safe. Interactive mode shows a picker sourced live from the CPM user list, falling back to the profile CPM_List if that call fails.' }
        @{ Column = 'NumberOfVersionsRetention';  Required = $false; Description = 'Password versions to retain (default: 5). Mutually exclusive with NumberOfDaysRetention - set that instead for days-based retention.' }
        @{ Column = 'NumberOfDaysRetention';      Required = $false; Description = 'Days to retain (default: 0 = not used). Mutually exclusive with NumberOfVersionsRetention - when this is greater than 0, only this is sent and NumberOfVersionsRetention is ignored.' }
        @{ Column = 'AutoPurgeEnabled';           Required = $false; Description = 'Auto-purge enabled: true/false (default: false).' }
    )
    Priority         = 12
    Version          = '1.3.0'
}

function Get-SafesAddInput {
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

    Write-Host '  New Safe Details  (press Enter to accept each default)' -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Unique safe name (1-28 chars, no leading whitespace, cannot contain \ / : * < > " . |).'

    $description = Show-FieldPrompt -Label 'Description' `
        -Default $(if ($Defaults['Description']) { $Defaults['Description'] } else { '' }) `
        -Description 'Safe description.'

    # Location is no longer prompted for interactively, per user request - every safe is
    # created at the default root location ('\'). CSV/bulk input can still override it via the
    # Location column (unchanged - see Invoke-SafesAdd's InputSchema and body-building below).
    $location = if ($Defaults['Location']) { $Defaults['Location'] } else { '\' }

    # --- CPM picker: same display as Add Safe From Template - sourced from Get-CpmOptions
    # (Manage-Privilege.ps1), which queries live and falls back to the profile's CPM_List only
    # if that call fails. Per user request, 2026-09-03.
    Write-Host ''
    [array]$cpmList = @(Get-CpmOptions -Token $Token)

    $managingCPM = ''
    if ($cpmList.Count -gt 0) {
        Write-Host '  Managing CPM:' -ForegroundColor DarkGray
        Write-Host '    1 = (none)'
        for ($i = 0; $i -lt $cpmList.Count; $i++) {
            Write-Host "    $($i + 2) = $($cpmList[$i])"
        }
        Write-Host ''

        $defaultCpmIndex = 1
        if ($Defaults['ManagingCPM']) {
            for ($i = 0; $i -lt $cpmList.Count; $i++) {
                if ($cpmList[$i] -eq $Defaults['ManagingCPM']) { $defaultCpmIndex = $i + 2; break }
            }
        }

        $cpmChoice = Read-Host "  Select CPM (1-$($cpmList.Count + 1), default=$defaultCpmIndex)"
        $cpmIndex  = $defaultCpmIndex
        $parsedCpm = 0
        if ($cpmChoice -and [int]::TryParse($cpmChoice, [ref]$parsedCpm) -and $parsedCpm -ge 1 -and $parsedCpm -le ($cpmList.Count + 1)) {
            $cpmIndex = $parsedCpm
        }
        if ($cpmIndex -gt 1) { $managingCPM = $cpmList[$cpmIndex - 2] }
    } else {
        Write-Host '  (No CPMs available - enter the username manually, or leave blank for none.)' -ForegroundColor Yellow
        $managingCPM = Show-FieldPrompt -Label 'ManagingCPM' `
            -Default $(if ($Defaults['ManagingCPM']) { $Defaults['ManagingCPM'] } else { '' }) `
            -Description 'CPM username to assign, or leave blank for none.'
    }

    $numberOfVersionsRetention = Show-FieldPrompt -Label 'NumberOfVersionsRetention' `
        -Default $(if ($Defaults['NumberOfVersionsRetention']) { $Defaults['NumberOfVersionsRetention'] } else { '5' }) `
        -Description 'Password versions to retain (default: 5). Mutually exclusive with NumberOfDaysRetention.'

    $numberOfDaysRetention = Show-FieldPrompt -Label 'NumberOfDaysRetention' `
        -Default $(if ($Defaults['NumberOfDaysRetention']) { $Defaults['NumberOfDaysRetention'] } else { '0' }) `
        -Description 'Days to retain (default: 0 = not used). Set this instead of NumberOfVersionsRetention for days-based retention - only one is sent.'

    $autoPurgeEnabled = Show-FieldPrompt -Label 'AutoPurgeEnabled' `
        -Default $(if ($Defaults['AutoPurgeEnabled']) { $Defaults['AutoPurgeEnabled'] } else { 'false' }) `
        -Description 'Auto-purge enabled? (true/false)'

    return @{
        SafeName                  = $safeName
        Description               = $description
        Location                  = $location
        ManagingCPM              = $managingCPM
        NumberOfVersionsRetention = $numberOfVersionsRetention
        NumberOfDaysRetention     = $numberOfDaysRetention
        AutoPurgeEnabled          = $autoPurgeEnabled
    }
}

function Invoke-SafesAdd {
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

    # Validate required field SafeName. Note: SafeName is checked against the raw (untrimmed) input
    # for leading whitespace, since CyberArk rejects it - trimming here first would silently accept
    # what the Vault itself would reject.
    $rawSafeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])" } else { '' }
    $safeName = $rawSafeName.Trim()
    if (-not $safeName) {
        $msg = 'SafeName is required and cannot be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # SafeName: max 28 chars, no leading whitespace, and none of the reserved characters CyberArk
    # itself disallows in a safe name (\ / : * < > " . |) - matches psPAS's Add-PASSafe.ps1
    # [ValidateLength(0,28)] plus the Vault's own reserved-character rule.
    if ($safeName.Length -gt 28 -or $rawSafeName -match '^\s' -or $safeName -match '[\\/:*<>"\.\|]') {
        $msg = "SafeName '$safeName' is invalid - must be 1-28 characters, no leading whitespace, and cannot contain any of: \ / : * < > `" . |"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # NumberOfVersionsRetention and NumberOfDaysRetention are mutually exclusive on this API -
    # only one may be sent. Days wins when set to a value greater than 0; otherwise Versions is sent.
    $numberOfVersionsRetention = if ($InputData['NumberOfVersionsRetention']) { [int]$InputData['NumberOfVersionsRetention'] } else { 5 }
    $numberOfDaysRetention     = if ($InputData['NumberOfDaysRetention'])     { [int]$InputData['NumberOfDaysRetention'] }     else { 0 }

    # Build request body. OLACEnabled is intentionally never sent - it is not a supported input for this module.
    $body = @{
        SafeName         = $safeName
        Description      = if ($InputData['Description']) { $InputData['Description'] } else { '' }
        Location         = if ($InputData['Location'])     { $InputData['Location'] }     else { '\' }
        ManagingCPM      = if ($InputData['ManagingCPM'])   { $InputData['ManagingCPM'] }   else { '' }
        AutoPurgeEnabled = ("$($InputData['AutoPurgeEnabled'])" -match '^true$')
    }
    if ($numberOfDaysRetention -gt 0) {
        $body['NumberOfDaysRetention'] = $numberOfDaysRetention
    } else {
        $body['NumberOfVersionsRetention'] = $numberOfVersionsRetention
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Adding safe '$safeName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Safes | SafeName='$safeName'"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "[WhatIf] Would POST /API/Safes for '$safeName'."
        $result.Results.Add([PSCustomObject]@{
            SafeName         = $safeName
            Description      = $body.Description
            Location         = $body.Location
            ManagingCPM      = $body.ManagingCPM
            # Pattern C: NumberOfVersionsRetention and NumberOfDaysRetention are mutually
            # exclusive in $body (only one is ever set, per the retention rule above) -
            # dot-accessing the absent one throws under Set-StrictMode. Bracket notation with
            # ContainsKey avoids the crash. See Invoke-SafesAddFromTemplate.ps1 for the
            # identical fix.
            VersionRetention = if ($body.ContainsKey('NumberOfVersionsRetention')) { $body['NumberOfVersionsRetention'] } else { $null }
            DayRetention     = if ($body.ContainsKey('NumberOfDaysRetention'))     { $body['NumberOfDaysRetention'] }     else { $null }
            AutoPurge        = $body.AutoPurgeEnabled
            Creator          = ''
            Created          = ''
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint '/API/Safes' `
        -Body     $body

    if (-not $response.IsSuccess) {
        $msg = "Add safe failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $response.ErrorMessage
            ErrorDetails = $response.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # Map result - WhatIf returns a synthetic success with no Data object
    $safe = if ($response.Data) { $response.Data } else { $null }

    $creationDate = if ($safe -and $safe.creationTime) {
        try { [DateTimeOffset]::FromUnixTimeSeconds($safe.creationTime).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    $result.Results.Add([PSCustomObject]@{
        SafeName         = if ($safe -and $safe.safeName)                   { $safe.safeName }                   else { $safeName }
        Description      = if ($safe -and $safe.description)                { $safe.description }                else { $body.Description }
        Location         = if ($safe -and $safe.location)                   { $safe.location }                   else { $body.Location }
        ManagingCPM      = if ($safe -and $safe.managingCPM)               { $safe.managingCPM }               else { $body.ManagingCPM }
        # Pattern C: bracket notation with ContainsKey on the $body fallback branches - same
        # reasoning as the WhatIf block above. NumberOfVersionsRetention and
        # NumberOfDaysRetention are mutually exclusive in $body, so dot-accessing whichever one
        # was not sent throws under Set-StrictMode.
        VersionRetention = if ($safe -and $safe.numberOfVersionsRetention)  { $safe.numberOfVersionsRetention }  elseif ($body.ContainsKey('NumberOfVersionsRetention')) { $body['NumberOfVersionsRetention'] } else { $null }
        DayRetention     = if ($safe -and $safe.numberOfDaysRetention)      { $safe.numberOfDaysRetention }      elseif ($body.ContainsKey('NumberOfDaysRetention'))     { $body['NumberOfDaysRetention'] }     else { $null }
        AutoPurge        = if ($safe)                                        { $safe.autoPurgeEnabled }           else { $body.AutoPurgeEnabled }
        Creator          = if ($safe -and $safe.creator)                    { $safe.creator.name }               else { '' }
        Created          = $creationDate
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Safe '$safeName' created successfully."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
