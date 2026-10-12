<#
    Manage-Privilege.ps1 driver part: automation mode (non-interactive -Category/-Action and -JobFile runs).
    Dot-sourced by Manage-Privilege.ps1 (Driver Parts region) into its script scope; not run on its own.
#>

#region --- Automation Mode ---

function Get-AutomationExitCode {
    <#
        Maps either a CSV-batch summary (Invoke-CsvProcessing's return value) or a single module
        result object to Invoke-AutomatedAction's exit-code contract (0 = full success, 2 =
        partial/item-level failures, 3 = could not run/fatal - see User_Docs\User-Guide.md for the
        full contract as documented for automation callers). Factored out of Invoke-AutomatedAction
        purely so this mapping is unit-testable on its own, without driving the whole entry point.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Csv')]
        [PSCustomObject]$Summary,

        [Parameter(Mandatory = $true, ParameterSetName = 'Result')]
        [PSCustomObject]$Result
    )
    if ($PSCmdlet.ParameterSetName -eq 'Csv') {
        if ($Summary.AnyFatal)    { return 3 }
        # A file that couldn't be used at all (unreadable, empty, missing a required column)
        # means the run didn't do what was asked - "could not run", not success.
        if ($Summary.PSObject.Properties['SkippedFiles'] -and $Summary.SkippedFiles -gt 0) { return 3 }
        if ($Summary.TotalFail -gt 0) { return 2 }
        return 0
    }
    if ($Result.IsFatal)      { return 3 }
    if ($Result.Failures -gt 0) { return 2 }
    return 0
}

function Read-AutomationJobFile {
    <#
        Reads and checks a -JobFile before anything logs in, so a typo costs no login. Returns
        the steps as objects (Name, Category, Action, InputFile, InputJson, OutputFolder,
        FilenameFormat, WhatIf, StopOnFailure). Relative paths are made absolute against the job
        file's folder. Throws a clear message for any problem.
    #>
    param([Parameter(Mandatory = $true)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "job file '$Path' was not found." }
    try {
        $job = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "job file '$Path' is not valid JSON: $($_.Exception.Message)"
    }
    if (-not $job -or -not $job.PSObject.Properties['Steps'] -or -not $job.Steps) { throw "job file '$Path' has no Steps." }
    $baseDir     = Split-Path -Parent (Resolve-Path -LiteralPath $Path).Path
    $defaultStop = [bool]($job.PSObject.Properties['StopOnFailure'] -and $job.StopOnFailure -eq $true)
    $steps = [System.Collections.Generic.List[PSCustomObject]]::new()
    $n = 0
    foreach ($s in @($job.Steps)) {
        $n++
        $get = { param([string]$Name) if ($s -and $s.PSObject.Properties[$Name] -and $null -ne $s.$Name) { $s.$Name } else { $null } }
        $category = "$(& $get 'Category')".Trim()
        $action   = "$(& $get 'Action')".Trim()
        if (-not $category -or -not $action) { throw "step $n needs both Category and Action." }
        $modulePath = Join-Path $script:APIModulesPath "$category\Invoke-$category$action.ps1"
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "step $n ($category/$action): no such action." }
        $inputFile = "$(& $get 'InputFile')".Trim()
        $inputJson = & $get 'InputJson'
        if ($inputFile -and $null -ne $inputJson) { throw "step $n ($category/$action): use InputFile or InputJson, not both." }
        if ($inputFile) {
            if (-not [System.IO.Path]::IsPathRooted($inputFile)) { $inputFile = Join-Path $baseDir $inputFile }
            if (-not (Test-Path -LiteralPath $inputFile -PathType Leaf)) { throw "step $n ($category/$action): InputFile '$inputFile' was not found." }
        }
        $outputFolder = "$(& $get 'OutputFolder')".Trim()
        if ($outputFolder -and -not [System.IO.Path]::IsPathRooted($outputFolder)) { $outputFolder = Join-Path $baseDir $outputFolder }
        $stop = & $get 'StopOnFailure'
        $steps.Add([PSCustomObject]@{
            Name           = "$(& $get 'Name')".Trim()
            Category       = $category
            Action         = $action
            InputFile      = $inputFile
            InputJson      = $inputJson
            OutputFolder   = $outputFolder
            FilenameFormat = "$(& $get 'FilenameFormat')".Trim()
            WhatIf         = [bool]((& $get 'WhatIf') -eq $true)
            StopOnFailure  = if ($null -ne $stop) { [bool]($stop -eq $true) } else { $defaultStop }
        })
    }
    return $steps.ToArray()
}

function ConvertTo-AutomationInputData {
    <# -InputJson or a step's InputJson (JSON text, a path to a .json file, or an object from a job file) as a hashtable. Throws if it can't be parsed. #>
    param([AllowNull()] [object]$InputJson)
    $data = @{}
    if ($null -eq $InputJson -or ($InputJson -is [string] -and -not $InputJson.Trim())) { return $data }
    $parsed = if ($InputJson -is [string]) {
        $jsonText = if (Test-Path -LiteralPath $InputJson -PathType Leaf) { Get-Content -LiteralPath $InputJson -Raw } else { $InputJson }
        $jsonText | ConvertFrom-Json -ErrorAction Stop
    } else { $InputJson }
    # PS 5.1's ConvertFrom-Json returns a PSCustomObject, not a hashtable (no -AsHashtable there).
    foreach ($prop in $parsed.PSObject.Properties) { $data[$prop.Name] = $prop.Value }
    return $data
}

function Invoke-AutomationStep {
    <#
        Runs one automation step (from -Category/-Action or a job file) on the current session and
        returns its exit code (0/2/3). The step's OutputFolder/FilenameFormat/WhatIf apply only to
        this step; the launch parameters are the defaults. Module functions are visible here
        because Invoke-AutomatedAction dot-sourced them into its own scope (dynamic scoping).
    #>
    param([Parameter(Mandatory = $true)] [PSCustomObject]$Step)

    $entry = $script:LoadedModules | Where-Object {
        -not ($_.PSObject.Properties['Failed'] -and $_.Failed) -and
        $_.Meta.Category -ieq $Step.Category -and $_.Meta.Action -ieq $Step.Action
    } | Select-Object -First 1

    if (-not $entry) {
        $rawPath = Join-Path $script:APIModulesPath "$($Step.Category)\Invoke-$($Step.Category)$($Step.Action).ps1"
        $reason  = if (Test-Path -LiteralPath $rawPath -PathType Leaf) {
            "the module exists but does not support '$($script:SessionToken.SystemType)'"
        } else {
            'no such module exists'
        }
        Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: Category='$($Step.Category)' Action='$($Step.Action)' - $reason."
        return 3
    }
    if ($entry.Meta.PSObject.Properties['SupportsAutomation'] -and $entry.Meta['SupportsAutomation'] -eq $false) {
        Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: '$($entry.Meta.Name)' does not support automation (ModuleMeta.SupportsAutomation = `$false) - it always requires interactive input."
        return 3
    }

    $fnName = "Invoke-$($entry.Meta.Category)$($entry.Meta.Action)"
    # Every module was dot-sourced into one scope, so give the called module its own metadata (F73).
    $ModuleMeta = $entry.Meta

    # Per-step overrides, restored afterwards. Save-ModuleResultCsv / Get-OutputCsvPath read
    # $script:OutputFolder and $script:FilenameFormat (the launch parameters).
    $savedOutput   = Get-Variable -Name 'OutputFolder'   -Scope 'Script' -ValueOnly -ErrorAction SilentlyContinue
    $savedFilename = Get-Variable -Name 'FilenameFormat' -Scope 'Script' -ValueOnly -ErrorAction SilentlyContinue
    $savedWhatIf   = $script:WhatIfMode
    if ($Step.OutputFolder)   { $script:OutputFolder   = $Step.OutputFolder }
    if ($Step.FilenameFormat) { $script:FilenameFormat = $Step.FilenameFormat }
    if ($Step.WhatIf)         { $script:WhatIfMode     = $true }
    try {
        if ($Step.InputFile) {
            if (-not $entry.Meta.AcceptsInputFile) {
                Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: '$($entry.Meta.Name)' does not accept CSV input (InputFile) - use InputJson instead."
                return 3
            }
            if (-not (Test-Path -LiteralPath $Step.InputFile -PathType Leaf)) {
                Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: InputFile '$($Step.InputFile)' was not found."
                return 3
            }
            $summary = Invoke-CsvProcessing -ModuleEntry $entry -FilePaths @($Step.InputFile)
            return (Get-AutomationExitCode -Summary $summary)
        }

        try {
            $inputData = ConvertTo-AutomationInputData -InputJson $Step.InputJson
        } catch {
            Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: InputJson could not be parsed: $_"
            return 3
        }
        # Deliberately never calls Get-<Category><Action>Input - that function is interactive by
        # design. A module with required fields left unsupplied here reports its own normal
        # per-field validation Failure, exactly as an incomplete CSV row already does today.
        $result = & $fnName -Token $script:SessionToken -InputData $inputData -WhatIf:$script:WhatIfMode
        if ($entry.Meta.ProducesOutput) {
            Save-ModuleResultCsv -ModuleEntry $entry -Result $result -InputData $inputData
        }
        if ($entry.Meta.Action -notin @('List', 'Get')) {
            Add-CyberArkLogSummaryEntry -ModuleName $entry.Meta.Name `
                -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        }
        if ($result.IsFatal) {
            # Matches Invoke-ActionModule's interactive behavior: a 401/connectivity failure
            # invalidates the saved token so a next run doesn't waste time retrying it.
            Invoke-TokenInvalidate
        }
        return (Get-AutomationExitCode -Result $result)
    } finally {
        $script:OutputFolder   = $savedOutput
        $script:FilenameFormat = $savedFilename
        $script:WhatIfMode     = $savedWhatIf
    }
}


function Invoke-AutomatedAction {
    <#
        Non-interactive entry point: authenticate to -StartProfile, run one module action
        (-Category/-Action), and return an exit code - never enters the interactive profile
        list/detail menus or the category/action session loop. Requires $script:AutomationMode to
        already be set (done in the Configuration region, from -Category/-Action's presence).

        Exit codes: 0 = full success. 2 = the action ran but had item-level failures (not fatal).
        3 = could not run at all (profile/module resolution, no refreshable saved session, or the
        module itself reported IsFatal). 1 (unhandled crash) is the existing top-level catch's
        behavior - this function does not produce it itself.
    #>
    param()

    # The steps to run: from -JobFile (checked now, before any login) or the single -Category/-Action.
    if ($JobFile) {
        try { $steps = @(Read-AutomationJobFile -Path $JobFile) } catch {
            Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: $($_.Exception.Message)"
            return 3
        }
        Write-CyberArkLog -Level 'INFO' -Message "Automation mode: job file '$JobFile' has $($steps.Count) step(s)."
    } else {
        $steps = @([PSCustomObject]@{ Name = ''; Category = $Category; Action = $Action; InputFile = $InputFile; InputJson = $InputJson
                                      OutputFolder = ''; FilenameFormat = ''; WhatIf = $false; StopOnFailure = $false })
    }

    # A startup log is already open (Initialize-CyberArkLog, called unconditionally just before
    # this function runs) - Write-CyberArkLog calls below already land in it even before a
    # profile connects, so every automation-mode failure is captured to a file, not just an
    # unredirected Write-Host line.

    $match = @(Get-AllDriverProfiles) | Where-Object { $_.ProfileName -ieq $StartProfile } | Select-Object -First 1
    if (-not $match) {
        Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: no profile named '$StartProfile' was found."
        return 3
    }

    $connected = Invoke-ProfileConnect -Summary $match -Breadcrumbs @('Automation', $match.ProfileName) -NoPause
    if (-not $connected) {
        # Invoke-ProfileConnect (including its automation-mode fresh-auth guard) has already
        # logged the specific reason.
        return 3
    }

    # Re-initialize the log to the connected profile's own folder/metadata, mirroring the
    # interactive session's convention, so an automation-mode log file lands in the same place a
    # user would already look for one.
    $logFolder = if ($script:ActiveProfile.LogFolder -and (Test-Path -LiteralPath $script:ActiveProfile.LogFolder)) {
        $script:ActiveProfile.LogFolder
    } else { $script:DefaultLogFolder }
    Initialize-CyberArkLog `
        -LogFolder   $logFolder `
        -ProfileName $script:ActiveProfile.ProfileName `
        -MinLevel    $script:DefaultLogLevel `
        -Destination 'Both' `
        -SystemType  $script:SessionToken.SystemType `
        -AuthMethod  $script:SessionToken.AuthMethod `
        -BaseURL     $script:SessionToken.BaseURL `
        -WhatIfMode  $script:WhatIfMode
    # Keep the log folder from growing without limit: drop this tool's session logs older than the retention period.
    try { Remove-OldCyberArkLogs -LogFolder $logFolder -RetentionDays $script:LogRetentionDays } catch { Write-CyberArkLog -Level 'WARN' -Message "Old log cleanup failed: $_" }
    $what = if ($JobFile) { "Job file: $JobFile ($($steps.Count) step(s))" } else { "Category: $Category  Action: $Action" }
    Write-CyberArkLog -Level 'INFO' -Message "Automation mode: connected. Profile: $($script:ActiveProfile.ProfileName)  $what"

    Import-APIModules
    # Re-dot-source each module file into THIS function's own scope, exactly mirroring
    # Invoke-SessionLoop's identical loop above - this cannot be factored into a shared helper
    # function, since dot-sourcing done inside a normally-called function vanishes once that
    # function returns (the same reason Import-APIModules alone isn't enough - see its own
    # region). Duplicated deliberately, not an oversight.
    foreach ($m in $script:LoadedModules) {
        if ($m.PSObject.Properties['Failed'] -and $m.Failed) { continue }
        . $m.FilePath
    }

    # Run each step with this one session. A plain -Category/-Action run is a one-step job.
    $stepResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $stopReason  = ''
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $step  = $steps[$i]
        $label = "Step $($i + 1)/$($steps.Count) $($step.Category)/$($step.Action)$(if ($step.Name) { " ($($step.Name))" })"
        if ($i -gt 0) {
            # The previous step may have run long; refresh silently if the token expired.
            if ((Test-TokenExpiry) -eq 'Expired' -and -not (Invoke-TokenRefresh)) {
                $stopReason = "the session expired before $label and could not be refreshed"
                break
            }
        }
        Write-CyberArkLog -Level 'INFO' -Message "Automation mode: $label starting."
        $code = Invoke-AutomationStep -Step $step
        $stepResults.Add([PSCustomObject]@{ Label = $label; ExitCode = $code })
        Write-CyberArkLog -Level $(if ($code -eq 0) { 'INFO' } else { 'WARN' }) -Message "Automation mode: $label finished with exit code $code."
        if (-not $script:SessionToken) { $stopReason = "the session ended during $label"; break }
        if ($code -ne 0 -and $step.StopOnFailure) { $stopReason = "$label exited $code and StopOnFailure is set"; break }
    }

    $exitCode = if ($stepResults.Count -eq 0) { 3 } else { [int](($stepResults | Measure-Object -Property ExitCode -Maximum).Maximum) }
    if ($stopReason) {
        $skipped = $steps.Count - $stepResults.Count
        Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: stopped - $stopReason. $skipped step(s) not run."
        if ($skipped -gt 0 -and $exitCode -lt 3) { $exitCode = 3 }
    }
    if ($steps.Count -gt 1) {
        foreach ($r in $stepResults) { Write-CyberArkLog -Level 'INFO' -Message "Automation mode: $($r.Label) -> exit $($r.ExitCode)" }
    }

    # Deliberately does NOT call Invoke-SessionLogoff here, unlike the interactive session loop's
    # own end-of-session cleanup (see the other call site) - confirmed live that CyberArk's
    # POST /API/auth/Logoff genuinely revokes the session server-side, so calling it here would
    # kill the very session a NEXT automation-mode run against this same profile is meant to
    # reuse or silently refresh (the whole point of the saved/refreshable session K06/K12 built).
    # A prior run's own Invoke-TokenInvalidate (IsFatal above) already deletes the local .cred
    # file when the session is genuinely dead - nothing further to clean up here either way. See
    # Testing_Findings-and-Known-Issues.md K15.
    Write-CyberArkLog -Level 'INFO' -Message "Automation mode: finished. $($stepResults.Count) of $($steps.Count) step(s) run. ExitCode=$exitCode"
    Close-CyberArkLog
    return $exitCode
}

#endregion
