<#
    Manage-Privilege.ps1 driver part: the action menu and Invoke-ActionModule.
    Dot-sourced by Manage-Privilege.ps1 (Driver Parts region) into its script scope; not run on its own.
#>

#region --- Action Menu ---

function Show-CategoryMenu {
    param([string[]]$Breadcrumbs, [object[]]$Categories)
    Show-Header -Breadcrumbs $Breadcrumbs

    if (-not $Categories -or $Categories.Count -eq 0) {
        Write-Host '  No API modules loaded for this system type.' -ForegroundColor DarkGray
        Write-Host "  Add .ps1 files to: $($script:APIModulesPath)" -ForegroundColor DarkGray
        Write-Host ''
    } else {
        $i = 1
        foreach ($cat in $Categories) {
            $n    = $cat.Count
            $noun = if ($n -eq 1) { 'action' } else { 'actions' }
            Write-Host ("  [{0,2}]  {1,-20}  ({2} {3})" -f $i, $cat.Name, $n, $noun) -ForegroundColor White
            $i++
        }
        Write-Host ''
    }

    Show-Divider
    $remaining = [Math]::Round((Get-TokenRemainingMinutes), 1)
    $expColor  = if ($remaining -le $script:TokenExpiryWarnMin) { 'Yellow' } else { 'DarkGray' }
    $idleSec   = Get-SessionIdleSeconds
    $idleMin   = [Math]::Round($idleSec / 60, 1)
    Write-Host ("  Token: {0} min remaining    Idle: {1} of {2} min" -f $remaining, $idleMin, $script:InactivityTimeoutMin) -ForegroundColor $expColor
    # The warning lives here, under the menu, so the menu's Clear-Host can't wipe it.
    if ($idleSec -ge ($script:InactivityTimeoutMin * 60 * 0.9)) {
        $remainSec = [Math]::Max(0, [int]($script:InactivityTimeoutMin * 60 - $idleSec))
        Write-Host "  Inactivity warning: the session ends in ~$remainSec seconds unless an action calls the API." -ForegroundColor Yellow
    }
    if ($script:WhatIfMode) {
        Write-Host '  WhatIf mode is ON - write operations will be suppressed.' -ForegroundColor Yellow
    }
    Write-Host '  [R] Restart to profile selection    [X] Exit' -ForegroundColor White
}

function Get-ModuleMenuGroup {
    # ModuleMeta.MenuGroup, or '' when the module doesn't declare one. Bracket notation: Meta
    # is a hashtable, and most modules don't declare this optional key.
    param([PSCustomObject]$ModuleEntry)
    $group = $ModuleEntry.Meta['MenuGroup']
    if ($group) { return "$group" }
    return ''
}

function Get-CategoryMenuModules {
    <#
        Returns one category's modules in action-menu order; the menu number is the index into
        this list. Without MenuGroup: List first, then by name. With MenuGroup: by the group's
        place in $script:MenuGroupOrder (unlisted groups next, alphabetically; ungrouped modules
        last), then List* actions first within the group, then by name.
    #>
    param([string]$Category, [object[]]$Modules)

    $order = @()
    if ($script:MenuGroupOrder -and $script:MenuGroupOrder.ContainsKey($Category)) {
        $order = @($script:MenuGroupOrder[$Category])
    }
    $hasGroups = @($Modules | Where-Object { Get-ModuleMenuGroup -ModuleEntry $_ }).Count -gt 0

    if (-not $hasGroups) {
        return @($Modules | Sort-Object @(
            @{ Expression = { [int]($_.Meta.Action -ne 'List') }; Descending = $false }
            @{ Expression = { $_.Meta.Name }; Descending = $false }
        ))
    }

    return @($Modules | Sort-Object @(
        @{ Expression = {
            $g = Get-ModuleMenuGroup -ModuleEntry $_
            if (-not $g) { [int]::MaxValue }
            else {
                $idx = [array]::IndexOf([string[]]$order, $g)
                if ($idx -ge 0) { $idx } else { $order.Count }
            }
        }; Descending = $false }
        @{ Expression = { Get-ModuleMenuGroup -ModuleEntry $_ }; Descending = $false }
        @{ Expression = { [int]("$($_.Meta.Action)" -notlike 'List*') }; Descending = $false }
        @{ Expression = { $_.Meta.Name }; Descending = $false }
    ))
}

function Show-ActionMenu {
    param([string[]]$Breadcrumbs, [PSCustomObject[]]$CategoryModules)
    Show-Header -Breadcrumbs $Breadcrumbs

    # Group headings only when the category uses MenuGroup. A heading is printed when the group
    # changes, so a group with no loaded modules never shows. Ungrouped modules in a grouped
    # category go under 'Other'.
    $hasGroups = @($CategoryModules | Where-Object { Get-ModuleMenuGroup -ModuleEntry $_ }).Count -gt 0
    $lastGroup = $null

    $i = 1
    foreach ($entry in $CategoryModules) {
        if ($hasGroups) {
            $group = Get-ModuleMenuGroup -ModuleEntry $entry
            if (-not $group) { $group = 'Other' }
            if ($group -ne $lastGroup) {
                if ($null -ne $lastGroup) { Write-Host '' }
                Write-Host "  $group" -ForegroundColor Cyan
                $lastGroup = $group
            }
        }
        if ($entry.PSObject.Properties['Failed'] -and $entry.Failed) {
            Write-Host ("    {0,3}.  {1}  [Load Failed]" -f $i, $entry.Meta.Name) -ForegroundColor Red
            Write-Host ("           $($entry.Meta.Description)") -ForegroundColor DarkRed
        } else {
            $tags = @()
            if ($entry.Meta.AcceptsInputFile)                       { $tags += 'CSV' }
            if ($entry.Meta.SupportsWhatIf -and $script:WhatIfMode) { $tags += 'WhatIf' }
            $tagStr = if ($tags) { "  [$($tags -join ', ')]" } else { '' }
            Write-Host ("    {0,3}.  {1}{2}" -f $i, $entry.Meta.Name, $tagStr) -ForegroundColor White
            Write-Host ("           {0}" -f $entry.Meta.Description) -ForegroundColor DarkGray
        }
        $i++
    }
    Write-Host ''

    Show-Divider
    $remaining = [Math]::Round((Get-TokenRemainingMinutes), 1)
    $expColor  = if ($remaining -le $script:TokenExpiryWarnMin) { 'Yellow' } else { 'DarkGray' }
    Write-Host ("  Token: {0} min remaining" -f $remaining) -ForegroundColor $expColor
    if ($script:WhatIfMode) {
        Write-Host '  WhatIf mode is ON - write operations will be suppressed.' -ForegroundColor Yellow
    }
    Write-Host '  [B] Back to categories    [R] Restart    [X] Exit' -ForegroundColor White
}

function Save-ModuleResultCsv {
    <#
        Extracted from Invoke-ActionModule's inline CSV-auto-save block so the automation entry
        point (Invoke-AutomatedAction) can reuse it too - without this, an automated run of a
        ProducesOutput module would report success but silently write no CSV. In automation mode,
        always saves via Get-CsvSavePath -AutoSave (never shows the interactive "Save to CSV?
        [y/N]" prompt or the SaveFileDialog fallback), so this call is fully non-interactive.
    #>
    param(
        [PSCustomObject]$ModuleEntry,
        [PSCustomObject]$Result,
        [hashtable]$InputData
    )
    $meta = $ModuleEntry.Meta
    if (-not ($meta.ProducesOutput -and $Result.Results.Count -gt 0)) { return }

    # AutoSaveCsv modules (bulk export tools whose whole purpose is producing a CSV) save
    # straight to the default path with no prompt or dialog - see ModuleMeta.AutoSaveCsv.
    # Bracket notation, not dot notation: $meta is a hashtable, and most modules don't declare
    # this optional key at all - dot-accessing a missing hashtable key throws
    # PropertyNotFoundException under Set-StrictMode (always active here).
    $autoSave = [bool]$meta['AutoSaveCsv'] -or $script:AutomationMode
    $doSave   = $autoSave
    if (-not $autoSave) {
        $saveCsv = Read-MenuChoice -Prompt 'Save results to CSV? [y/N]'
        $doSave  = ($saveCsv -match '^[Yy]')
    }
    if (-not $doSave) { return }

    # Automation mode's -OutputFolder/-FilenameFormat launch parameters (see Get-CsvSavePath's
    # own FolderOverride/FileNameOverride params), guarded on $script:AutomationMode so they're
    # never picked up on an interactive run that happens to have been launched alongside
    # -Category/-Action for an unrelated reason. $script:-prefixed reads, not bare
    # $OutputFolder/$FilenameFormat: both are this script's own top-level param() variables, and
    # $script: always resolves to this file's actual script-scope container regardless of which
    # nested scope happens to be executing this line (e.g. a Pester BeforeAll block's own scope,
    # when this function is exercised from a unit test) - a bare lexical-parent-chain lookup does
    # not have that same guarantee.
    $folderOverride   = if ($script:AutomationMode -and $script:OutputFolder) { $script:OutputFolder } else { $null }
    $fileNameOverride = if ($script:AutomationMode -and $script:FilenameFormat) {
        Format-AutomationFilename -Format $script:FilenameFormat -ModuleName $meta.Name -Category $meta.Category -Action $meta.Action
    } else { $null }

    # Optional ModuleMeta.CsvFilenameField: names an InputData column whose value (when present
    # and non-blank) is appended to the saved filename - e.g. Test Connectivity declares
    # 'Address' so a single run's CSV is named after the server it tested. Bracket notation -
    # most modules don't declare this optional key. Skipped when -FilenameFormat already took
    # full control of the name - an explicit format is authoritative, not layered with this too.
    $csvNameSuffix = ''
    $csvFilenameField = $meta['CsvFilenameField']
    if (-not $fileNameOverride -and $csvFilenameField -and $InputData -and $InputData.ContainsKey($csvFilenameField)) {
        $fieldValue = "$($InputData[$csvFilenameField])".Trim()
        if ($fieldValue) { $csvNameSuffix = " - $fieldValue" }
    }
    # Optional ModuleMeta.CsvFilenameNoDate: a bulk export tool whose saved CSV is meant to
    # always be the latest snapshot, overwritten on every run, rather than accumulate one dated
    # file per run - matching Custom/ExportAll's own fixed Export_<Module>.csv naming. Bracket
    # notation - most modules don't declare this optional key. Only meaningful when nothing has
    # already taken over the filename entirely (-FilenameFormat).
    $noDateSuffix = -not $fileNameOverride -and [bool]$meta['CsvFilenameNoDate']
    $csvPath = Get-CsvSavePath -DefaultFolder $script:ActiveProfile.OutputFolder -ModuleName "$($meta.Name)$csvNameSuffix" -AutoSave:$autoSave `
        -FolderOverride $folderOverride -FileNameOverride $fileNameOverride -NoDateSuffix:$noDateSuffix
    if ($csvPath) {
        $saved = Invoke-FileWriteWithRetry -Path $csvPath -Action {
            $Result.Results | Export-Csv -Path $csvPath -NoTypeInformation -Force
        }
        if ($saved) {
            Write-Host "  Saved: $csvPath" -ForegroundColor Green
            Write-CyberArkLog -Message "Results saved to CSV: $csvPath" -Level 'INFO'
        } else {
            Write-CyberArkLog -Message "Failed to save CSV to '$csvPath' (user declined to retry)." -Level 'ERROR'
        }
    }
}

function Invoke-ActionModule {
    param(
        [PSCustomObject]$ModuleEntry,
        [hashtable]$Defaults = $null
    )

    if ($ModuleEntry.PSObject.Properties['Failed'] -and $ModuleEntry.Failed) {
        Show-Header -Breadcrumbs @($script:ActiveProfile.ProfileName, $ModuleEntry.Meta.Category, $ModuleEntry.Meta.Name)
        Write-Host "  $($ModuleEntry.Meta.Name)" -ForegroundColor Red
        Write-Host '  This module failed to load and cannot be executed.' -ForegroundColor Red
        Write-Host ''
        Write-Host "  Error: $($ModuleEntry.FailError)" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Press Enter to return.' -ForegroundColor DarkGray
        Read-Host | Out-Null
        return
    }

    $meta   = $ModuleEntry.Meta
    $fnName = "Invoke-$($meta.Category)$($meta.Action)"
    # Every module was dot-sourced into one scope, so the shared $ModuleMeta holds the last
    # module loaded. Module functions read $ModuleMeta for their result and log-summary labels
    # through dynamic scoping, so shadow it here with this module's own metadata (F73).
    $ModuleMeta = $meta

    if ($meta.AcceptsInputFile) {
        Show-Header -Breadcrumbs @($script:ActiveProfile.ProfileName, $meta.Category, $meta.Name)
        Write-Host "  $($meta.Name)" -ForegroundColor White
        Write-Host "  $($meta.Description)" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  [1] Process CSV file(s)    [2] Enter values interactively    [3] Generate Template    [B] Back' -ForegroundColor White
        $mode = Read-MenuChoice -Prompt '[1] / [2] / [3] / [B]ack (default: B)'
        if (-not $mode) { $mode = 'B' }
        switch ($mode.ToUpper()) {
            '1' { Invoke-CsvProcessing -ModuleEntry $ModuleEntry; return }
            '2' { <# fall through to interactive input below #> }
            '3' {
                $cols = @($meta.InputSchema | ForEach-Object { $_.Column })
                if ($cols.Count -eq 0) {
                    Write-Host '  This module has no input schema; no template to generate.' -ForegroundColor Yellow
                } else {
                    $csvPath = Get-CsvSavePath -DefaultFolder $script:ActiveProfile.OutputFolder `
                        -ModuleName "$($meta.Name) Template"
                    if ($csvPath) {
                        $header = ($cols | ForEach-Object { "`"$_`"" }) -join ','
                        $lines  = [System.Collections.Generic.List[string]]::new()
                        $lines.Add($header)

                        # If any InputSchema column defines an Example value, add one example
                        # row beneath the header - blank for any column that doesn't have one -
                        # so the CSV format is obvious at a glance (e.g. the Type:Name:RoleName;...
                        # syntax for a delimited-list column like ExtraMembers). Bracket/ContainsKey
                        # access, not dot notation - InputSchema entries are hashtables, and most
                        # modules' entries don't define Example at all.
                        $hasExample = @($meta.InputSchema | Where-Object { $_.ContainsKey('Example') -and $_['Example'] }).Count -gt 0
                        if ($hasExample) {
                            $exampleRow = ($meta.InputSchema | ForEach-Object {
                                $ex = if ($_.ContainsKey('Example') -and $_['Example']) { "$($_['Example'])" } else { '' }
                                "`"$ex`""
                            }) -join ','
                            $lines.Add($exampleRow)
                        }

                        try {
                            [System.IO.File]::WriteAllLines($csvPath, [string[]]$lines, [System.Text.Encoding]::UTF8)
                            Write-Host "  Template saved: $csvPath" -ForegroundColor Green
                        } catch {
                            Write-Host "  Failed to write template: $_" -ForegroundColor Red
                            Write-CyberArkLog -Level 'ERROR' -Message "Failed to write template to '$csvPath': $_"
                        }
                    }
                }
                return
            }
            { $_ -match '^B\d*$' } { return }
            default { return }
        }
    }

    Show-Header -Breadcrumbs @($script:ActiveProfile.ProfileName, $meta.Category, $meta.Name)
    Write-Host "  $($meta.Name)" -ForegroundColor White
    Write-Host "  $($meta.Description)" -ForegroundColor DarkGray
    Write-Host ''

    $inputData = if ($meta.HasCustomInput) {
        if ($Defaults) {
            & "Get-$($meta.Category)$($meta.Action)Input" -Token $script:SessionToken -Defaults $Defaults
        } else {
            & "Get-$($meta.Category)$($meta.Action)Input" -Token $script:SessionToken
        }
    } elseif ($meta.InputSchema) {
        Invoke-InteractiveInput -Schema $meta.InputSchema
    } else { @{} }

    if ($null -eq $inputData) { return }   # User cancelled in custom input function

    Write-Host ''
    Write-CyberArkLog -Message "Invoking $fnName" -Level 'DEBUG'

    $result = & $fnName -Token $script:SessionToken -InputData $inputData -WhatIf:$script:WhatIfMode
    $displayLimit    = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['DisplayLimit']) {
        [int]$script:ActiveProfile.DisplayLimit
    } else { 20 }
    # 0 = show all; otherwise truncate List actions and all Custom export operations
    $truncateDisplay = ($displayLimit -gt 0) -and (($meta.Action -eq 'List') -or ($meta.Category -eq 'Custom' -and $meta.ProducesOutput))

    Write-Host ''
    if ($result.Successes -gt 0 -or ($result.ItemsProcessed -eq 0 -and $result.Errors.Count -eq 0)) {
        Write-Host "  Result: $($result.Successes) succeeded, $($result.Failures) failed." -ForegroundColor Green
        if ($result.Results.Count -gt 0) {
            $tableData = @(if ($meta.Action -eq 'List') {
                $n = 1
                @($result.Results | ForEach-Object {
                    $props = [ordered]@{ '#' = $n++ }
                    foreach ($p in $_.PSObject.Properties) { $props[$p.Name] = $p.Value }
                    [PSCustomObject]$props
                })
            } else { @($result.Results) })
            $displayData = @(if ($truncateDisplay -and $tableData.Count -gt $displayLimit) {
                Write-Host "  Showing first $displayLimit of $($result.Results.Count) results. (Change 'Display Limit' in Profile Settings)" -ForegroundColor DarkGray
                $tableData[0..($displayLimit - 1)]
            } else { $tableData })
            $displayData | Format-Table -AutoSize | Out-String |
                Where-Object { $_.Trim() } |
                ForEach-Object { Write-Host "  $_" }
        }
    } else {
        Write-Host "  Result: $($result.Failures) failed." -ForegroundColor Red
        foreach ($err in $result.Errors) {
            Write-Host "    Error: $($err.ErrorMessage)" -ForegroundColor Yellow
            if ($err.ErrorDetails -and $err.ErrorDetails.ErrorCode) {
                Write-Host "    Code:  $($err.ErrorDetails.ErrorCode)" -ForegroundColor DarkGray
            }
        }
    }

    if ($result.IsFatal) {
        # IsFatal is only ever set by a module for HTTP 401 or a network-level failure
        # (StatusCode 0) - see the IsFatal table in Reference_API-Module-Guide.md.
        # Invalidate unconditionally rather than pattern-matching the error message text:
        # a 401 whose message happens not to contain "401"/"Unauthorized" must still
        # force re-authentication, not silently leave a rejected token in place.
        Write-Host ''
        Write-Host '  Fatal API error (401 Unauthorized or connectivity) - token invalidated.' -ForegroundColor Red
        Invoke-TokenInvalidate
        return
    }

    Save-ModuleResultCsv -ModuleEntry $ModuleEntry -Result $result -InputData $inputData

    if ($meta.Action -notin @('List','Get')) {
        Add-CyberArkLogSummaryEntry -ModuleName $meta.Name `
            -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    }

    # For List actions: offer line-number drill-down to the corresponding Get module
    if ($meta.Action -eq 'List' -and $result.Results.Count -gt 0) {
        $getModule = $script:LoadedModules | Where-Object {
            -not ($_.PSObject.Properties['Failed'] -and $_.Failed) -and
            $_.Meta.Category -eq $meta.Category -and $_.Meta.Action -in @('Get', 'GetMembers')
        } | Select-Object -First 1
        if ($getModule) {
            Write-Host ''
            Write-Host '  Enter a line number to view details, or press Enter to return.' -ForegroundColor DarkGray
            $lineInput = (Read-Host '  #').Trim()
            if ($lineInput -match '^\d+$') {
                $lineNum = [int]$lineInput
                if ($lineNum -ge 1 -and $lineNum -le $result.Results.Count) {
                    $selectedRow = $result.Results[$lineNum - 1]
                    $rowDefaults = @{}
                    foreach ($prop in $selectedRow.PSObject.Properties) {
                        $rowDefaults[$prop.Name] = $prop.Value
                    }
                    Invoke-ActionModule -ModuleEntry $getModule -Defaults $rowDefaults
                }
            }
            return
        }
    }

    Write-Host ''
    Write-Host '  Press Enter to return to the menu.' -ForegroundColor DarkGray
    Read-Host | Out-Null
}

#endregion
