#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Export All'
    Category         = 'Custom'
    Action           = 'ExportAll'
    Description      = 'Run the List action (plus Applications'' ListAuthMethods and any other module explicitly opted in via IncludeInExportAll, e.g. Policies'' GetMasterPolicy) for every loaded module and save each result as a separate CSV file.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $false
    InputSchema      = @()
    Priority         = 80
    Version          = '1.2.0'
}

function Invoke-CustomExportAll {
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

    # Enumerate list modules - skip other Custom modules to avoid recursion. Applications'
    # ListAuthMethods is included alongside List: with no AppID supplied (the default,
    # empty InputData below), it now lists auth methods for every application - the same
    # "leave the identifier blank for all" contract every other List action already has.
    # A module with any other Action (e.g. Policies' GetMasterPolicy, a single-row settings
    # snapshot rather than a list) can still opt in via ModuleMeta.IncludeInExportAll = $true.
    $listModules = @()
    if ($null -ne $script:LoadedModules) {
        $listModules = @($script:LoadedModules | Where-Object {
            ($_.Meta.Action -in @('List', 'ListAuthMethods') -or $_.Meta['IncludeInExportAll'] -eq $true) -and
            $_.Meta.ProducesOutput -eq $true -and
            $_.Meta.Category -ne 'Custom' -and
            -not $_.Meta['ExcludeFromExportAll']
        } | Sort-Object { [int]$_.Meta.Priority })
    }

    if ($listModules.Count -eq 0) {
        Write-Host '  No list modules found to export.' -ForegroundColor Yellow
        Write-CyberArkLog -Level 'WARN' -Message 'Export All: no list modules available.'
        return $result
    }

    Write-Host ''
    Write-Host "  Found $($listModules.Count) list module$(if ($listModules.Count -ne 1) { 's' }) to export." -ForegroundColor Cyan
    Write-Host ''

    # Automation mode's -OutputFolder launch parameter overrides the profile's own OutputFolder
    # for this run, redirecting where these per-sub-report CSVs land (their individual filenames,
    # e.g. Export_AccountsList.csv, are unaffected - -FilenameFormat does not apply to Export All,
    # since its output is inherently one file per sub-report rather than a single name). Read via
    # Get-Variable rather than a direct $script:AutomationMode/$script:OutputFolder reference:
    # this module is also dot-sourced standalone by its own unit test (without
    # Manage-Privilege.ps1's Configuration region ever running), where neither variable is ever
    # set - a direct reference would throw under strict mode instead of evaluating falsy. See
    # Claude_Docs\Reference_API-Module-Guide.md's "Automation Mode" section for this convention.
    $automationVar = Get-Variable -Name 'AutomationMode' -Scope 'Script' -ErrorAction SilentlyContinue
    $outputFolderOverride = $null
    if ($automationVar -and $automationVar.Value) {
        $outputFolderVar = Get-Variable -Name 'OutputFolder' -Scope 'Script' -ErrorAction SilentlyContinue
        if ($outputFolderVar -and $outputFolderVar.Value) { $outputFolderOverride = $outputFolderVar.Value }
    }

    $outputFolder = if ($outputFolderOverride) {
        $outputFolderOverride
    } elseif ($script:ActiveProfile -and $script:ActiveProfile.OutputFolder) {
        $script:ActiveProfile.OutputFolder
    } else { (Get-Location).Path }
    if (-not [System.IO.Path]::IsPathRooted($outputFolder)) {
        # $PSScriptRoot here is this file's own directory (APIModules\Custom), NOT the project
        # root - PowerShell binds it to where a function is lexically defined, not to the scope
        # that dot-sources it, even though Manage-Privilege.ps1 dot-sources this file into its
        # own scope. Resolve relative to the project root instead, via $script:APIModulesPath
        # (set by Manage-Privilege.ps1 before any module runs) so a relative profile
        # OutputFolder lands next to Manage-Privilege.ps1, matching every other save-to-CSV path.
        $projectRoot  = if ($script:APIModulesPath) { Split-Path -Path $script:APIModulesPath -Parent } else { (Get-Location).Path }
        $outputFolder = Join-Path $projectRoot $outputFolder
    }
    if (-not (Test-Path -LiteralPath $outputFolder)) {
        try { New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null } catch {}
    }

    foreach ($module in $listModules) {
        $fnName      = "Invoke-$($module.Meta.Category)$($module.Meta.Action)"
        $modName     = $module.Meta.Name
        $safeModName = "$($module.Meta.Category)$($module.Meta.Action)"
        $csvPath     = Join-Path $outputFolder "Export_$safeModName.csv"

        Write-Host "  [$($result.ItemsProcessed + 1)/$($listModules.Count)] $modName" -ForegroundColor White -NoNewline

        try {
            # Accounts List: use by-safe iteration to bypass the ~20,000 account API cap
            $moduleInputData = if ($module.Meta.Category -eq 'Accounts' -and $module.Meta.Action -eq 'List') {
                @{ IterateBySafe = $true }
            } else { @{} }
            $moduleResult = & $fnName -Token $Token -InputData $moduleInputData

            $recordCount = 0
            if ($null -ne $moduleResult -and $null -ne $moduleResult.Results) {
                $recordCount = $moduleResult.Results.Count
            }

            if ($recordCount -gt 0) {
                Write-Host " - $recordCount record$(if ($recordCount -ne 1) { 's' })" -ForegroundColor Green

                # Invoke-FileWriteWithRetry (defined in Manage-Privilege.ps1) is available because
                # this module is dot-sourced into the driver scope. If the file is open/locked
                # (e.g. in Excel), it prompts to retry rather than discarding the records this
                # module already fetched from the API.
                $saved = Invoke-FileWriteWithRetry -Path $csvPath -Action {
                    $moduleResult.Results | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Force
                }
                if ($saved) {
                    Write-Host "    Saved: $csvPath" -ForegroundColor DarkGreen
                    Write-CyberArkLog -Level 'INFO' -Message "Export All: saved '$safeModName' ($recordCount records) to '$csvPath'."
                    $result.Results.Add([PSCustomObject]@{
                        Module    = $modName
                        Records   = $recordCount
                        Status    = 'Saved'
                        SavedPath = $csvPath
                    })
                } else {
                    Write-Host '    Failed to save (user declined to retry).' -ForegroundColor Red
                    Write-CyberArkLog -Level 'ERROR' -Message "Export All: failed to write '$csvPath' (user declined to retry)."
                    $result.Results.Add([PSCustomObject]@{
                        Module    = $modName
                        Records   = $recordCount
                        Status    = 'SaveFailed'
                        SavedPath = ''
                    })
                }
            } else {
                Write-Host ' - no records returned.' -ForegroundColor DarkGray
                $result.Results.Add([PSCustomObject]@{
                    Module    = $modName
                    Records   = 0
                    Status    = 'Empty'
                    SavedPath = ''
                })
            }
            $result.Successes++
        } catch {
            Write-Host " - ERROR: $_" -ForegroundColor Red
            $msg = "Export All failed for module '$modName': $_"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = @{ Module = $modName }
                ErrorMessage = $msg
                ErrorDetails = $null
            })
            $result.Failures++
        }
        $result.ItemsProcessed++
        Write-Host ''
    }

    Write-CyberArkLog -Level 'INFO' -Message "Export All complete. Modules: $($result.ItemsProcessed), Success: $($result.Successes), Failures: $($result.Failures)."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
