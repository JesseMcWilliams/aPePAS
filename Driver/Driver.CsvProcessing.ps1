<#
    Manage-Privilege.ps1 driver part: input file selection and CSV batch processing.
    Dot-sourced by Manage-Privilege.ps1 (Driver Parts region) into its script scope; not run on its own.
#>

#region --- Input and CSV Processing ---

function Select-InputFiles {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    $dialog.Title       = 'Select Input CSV File(s)'
    $dialog.Filter      = 'CSV Files (*.csv)|*.csv|All Files (*.*)|*.*'
    $dialog.Multiselect = $true
    $dialog.InitialDirectory = if ($script:ActiveProfile.InputFolder) {
        $resolved = if ([System.IO.Path]::IsPathRooted($script:ActiveProfile.InputFolder)) {
            $script:ActiveProfile.InputFolder
        } else {
            Join-Path $script:AppRoot $script:ActiveProfile.InputFolder
        }
        if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved } else { $script:AppRoot }
    } else { $script:AppRoot }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileNames
    }
    return @()
}

function Get-OutputCsvPath {
    param([string]$InputPath)
    # Automation mode's -OutputFolder applies to the per-file results CSV too, with the same
    # create-if-missing rule as Get-CsvSavePath; if it can't be created, fall back below.
    # Get-Variable rather than $script:OutputFolder: when this file is dot-sourced (tests) the
    # top-level param doesn't exist, and strict mode would throw.
    $outputOverride = Get-Variable -Name 'OutputFolder' -Scope 'Script' -ValueOnly -ErrorAction SilentlyContinue
    if ($script:AutomationMode -and $outputOverride) {
        $override = if ([System.IO.Path]::IsPathRooted($outputOverride)) { $outputOverride } else { Join-Path $script:AppRoot $outputOverride }
        if (-not (Test-Path -LiteralPath $override -PathType Container)) {
            try { New-Item -ItemType Directory -Path $override -Force -ErrorAction Stop | Out-Null } catch {
                Write-CyberArkLog -Level 'WARN' -Message "Automation mode: could not create -OutputFolder '$override' for the results CSV ($_). Using the profile or input-file folder."
            }
        }
        if (Test-Path -LiteralPath $override -PathType Container) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
            return Join-Path $override "$($base)_$((Get-Date).ToString('yyyy-MM-dd'))_output.csv"
        }
    }
    $folder = if ($script:ActiveProfile.OutputFolder) {
        $resolved = if ([System.IO.Path]::IsPathRooted($script:ActiveProfile.OutputFolder)) {
            $script:ActiveProfile.OutputFolder
        } else {
            Join-Path $script:AppRoot $script:ActiveProfile.OutputFolder
        }
        if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved } else { Split-Path $InputPath }
    } else { Split-Path $InputPath }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    return Join-Path $folder "$($base)_$((Get-Date).ToString('yyyy-MM-dd'))_output.csv"
}

#region --- Detailed CSV results ---
# A CSV run's <input>_<date>_output.csv keeps one IsSuccess/Summary line per input row. The
# matching <input>_<date>_detail.csv keeps everything each row returned, so Get actions and
# tools like Test Connectivity don't lose their output when run from a CSV.

function ConvertTo-DetailCsvValue {
    <# One cell: arrays joined with '; ', nested objects as compact JSON, secrets masked by the caller. #>
    param([AllowNull()] [object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Security.SecureString] -or $Value -is [System.Management.Automation.PSCredential]) { return '***' }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [PSCustomObject]) {
        try { return (ConvertTo-Json -InputObject $Value -Depth 5 -Compress) } catch { return "$Value" }
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return ((@($Value) | ForEach-Object { "$(ConvertTo-DetailCsvValue -Value $_)" }) -join '; ')
    }
    return "$Value"
}

function Add-DetailCsvRows {
    <#
        Appends one input row's results to $Rows (a List of ordered dictionaries): one line per
        result object, or per error when there are no results, or a single status line. Columns
        whose names look secret are written as '***'.
    #>
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]]$Rows,
        [Parameter(Mandatory = $true)] [int]$RowNumber,
        [AllowNull()] [object]$Result,
        [bool]$IsSuccess,
        [string]$Summary
    )
    $secret  = '(?i)(password|secret|credential|token|passphrase)'
    $added   = 0
    $results = if ($Result -and $Result.PSObject.Properties['Results'] -and $Result.Results) { @($Result.Results) } else { @() }
    foreach ($item in $results) {
        if ($null -eq $item) { continue }
        $line = [ordered]@{ RowNumber = $RowNumber; Status = 'OK' }
        if ($item -is [string] -or $item -is [ValueType]) {
            $line['Value'] = $item
        } else {
            foreach ($prop in $item.PSObject.Properties) {
                if ($prop.Name -in @('RowNumber', 'Status')) { continue }
                $line[$prop.Name] = if ($prop.Name -match $secret) { '***' } else { ConvertTo-DetailCsvValue -Value $prop.Value }
            }
        }
        $Rows.Add($line); $added++
    }
    $errors = if ($Result -and $Result.PSObject.Properties['Errors'] -and $Result.Errors) { @($Result.Errors) } else { @() }
    foreach ($err in $errors) {
        if ($null -eq $err) { continue }
        $msg = if ($err.PSObject.Properties['ErrorMessage']) { "$($err.ErrorMessage)" } else { "$err" }
        $Rows.Add([ordered]@{ RowNumber = $RowNumber; Status = 'Failed'; ErrorMessage = $msg }); $added++
    }
    if ($added -eq 0) {
        $Rows.Add([ordered]@{ RowNumber = $RowNumber; Status = $(if ($IsSuccess) { 'OK' } else { 'Failed' }); Summary = $Summary })
    }
}

function ConvertTo-DetailCsvObjects {
    <# Gives every line the union of all columns (first-seen order) so Export-Csv keeps them all. #>
    param([System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]]$Rows)
    $columns = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $Rows) { foreach ($k in $r.Keys) { if (-not $columns.Contains([string]$k)) { $columns.Add([string]$k) } } }
    foreach ($r in $Rows) {
        $o = [ordered]@{}
        foreach ($c in $columns) { $o[$c] = if ($r.Contains($c)) { $r[$c] } else { '' } }
        [PSCustomObject]$o
    }
}

#endregion

function Test-CsvSchema {
    param([string[]]$Headers, [hashtable[]]$Schema)
    return @($Schema | Where-Object { $_.Required -and ($_.Column -cnotin $Headers) })
}

function Invoke-InteractiveInput {
    param([hashtable[]]$Schema)
    $data = @{}
    foreach ($field in $Schema) {
        $value = Show-FieldPrompt -Label $field.Column -Description $field.Description `
            -Required:($field.Required)
        $data[$field.Column] = $value
    }
    return $data
}

function Invoke-CsvProcessing {
    param(
        [PSCustomObject]$ModuleEntry,

        # When supplied, used directly instead of showing the interactive OpenFileDialog -
        # automation mode's route in. $null (default) preserves today's interactive behavior
        # exactly.
        [string[]]$FilePaths = $null
    )
    $meta   = $ModuleEntry.Meta
    $fnName = "Invoke-$($meta.Category)$($meta.Action)"
    # Every module was dot-sourced into one scope, so the shared $ModuleMeta holds the last
    # module loaded. Module functions read $ModuleMeta for their result and log-summary labels
    # through dynamic scoping, so shadow it here with this module's own metadata (F73).
    $ModuleMeta = $meta

    $files = if ($FilePaths) { $FilePaths } else { Select-InputFiles }
    if (-not $files) {
        Write-Host '  No files selected.' -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
        return [PSCustomObject]@{ TotalProcessed = 0; TotalOk = 0; TotalFail = 0; AnyFatal = $false }
    }

    # Aggregated across every file actually attempted (a file skipped for being unreadable/
    # empty/schema-invalid contributes nothing to these totals) - returned to the caller so
    # automation mode can map the whole batch to a single exit code.
    $totalProcessed = 0
    $totalOk        = 0
    $totalFail      = 0
    $anyFatal       = $false
    $skippedFiles   = 0   # unreadable, empty or missing required columns: automation exits 3

    foreach ($filePath in $files) {
        $fileName = [System.IO.Path]::GetFileName($filePath)
        Write-CyberArkLog -Message "Starting CSV: $filePath" -Level 'INFO'

        try { $rows = @(Import-Csv -LiteralPath $filePath) } catch {
            Write-Host "  Could not read '$fileName': $_" -ForegroundColor Red
            Write-CyberArkLog -Message "Failed to read CSV '$filePath': $_" -Level 'WARN'
            $skippedFiles++
            continue
        }

        if (-not $rows) {
            Write-Host "  '$fileName' is empty - skipped." -ForegroundColor Yellow
            Write-CyberArkLog -Message "CSV '$filePath' has no rows - skipped." -Level 'WARN'
            $skippedFiles++
            continue
        }

        if ($meta.InputSchema) {
            $missing = Test-CsvSchema -Headers $rows[0].PSObject.Properties.Name -Schema $meta.InputSchema
            if ($missing) {
                $cols = ($missing | ForEach-Object { $_.Column }) -join ', '
                Write-Host "  '$fileName' missing required columns: $cols - skipped." -ForegroundColor Red
                Write-CyberArkLog -Message "CSV schema validation failed for '$fileName'. Missing: $cols" -Level 'WARN'
                $skippedFiles++
                continue
            }
        }

        $outputPath = Get-OutputCsvPath -InputPath $filePath
        $detailPath = $outputPath -replace '_output\.csv$', '_detail.csv'
        $detailRows = [System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]]::new()
        $rowNumber  = 0
        $outputRows = [System.Collections.Generic.List[PSCustomObject]]::new()
        $okCount    = 0
        $failCount  = 0
        $fatal      = $false
        $total      = $rows.Count

        Write-Host "  Processing '$fileName' ($total rows)..." -ForegroundColor DarkGray

        foreach ($row in $rows) {
            # Token health before each row
            switch (Test-TokenExpiry) {
                'Warning' { Invoke-SelfHostedKeepalive; Invoke-TokenRefresh | Out-Null }
                'Expired' {
                    if (-not (Invoke-TokenRefresh)) {
                        Write-CyberArkLog -Message 'Auth failure mid-CSV - aborting.' -Level 'ERROR'
                        $fatal = $true
                    }
                }
            }
            if ($fatal) { break }

            $inputData = @{}
            foreach ($col in $row.PSObject.Properties) { $inputData[$col.Name] = $col.Value }

            $result = & $fnName -Token $script:SessionToken -InputData $inputData -WhatIf:$script:WhatIfMode

            # A reactive 401 (module returns IsFatal) force-expires the token and re-authenticates,
            # then retries this same row once with the refreshed token, instead of aborting the
            # whole CSV batch. IsFatal is only ever set by a module for HTTP 401 or a network-level
            # failure (StatusCode 0) - see the IsFatal table in Reference_API-Module-Guide.md.
            $reauthFailed = $false
            if ($result.IsFatal) {
                Write-Host '  Fatal API error (401 Unauthorized or connectivity) - re-authenticating...' -ForegroundColor Yellow
                Write-CyberArkLog -Message 'IsFatal returned by module - attempting re-authentication mid-CSV.' -Level 'WARN'
                # Invalidate unconditionally rather than pattern-matching the error message text:
                # a 401 whose message happens not to contain "401"/"Unauthorized" must still
                # force re-authentication, not silently leave a rejected token in place.
                Invoke-TokenInvalidate
                if (Invoke-TokenRefresh) {
                    Write-Host '  Re-authenticated - retrying row...' -ForegroundColor Green
                    $result = & $fnName -Token $script:SessionToken -InputData $inputData -WhatIf:$script:WhatIfMode
                    if ($result.IsFatal) {
                        Write-Host '  Fatal API error persisted after re-authentication - aborting.' -ForegroundColor Red
                        Write-CyberArkLog -Message 'IsFatal persisted after retry - aborting CSV loop.' -Level 'ERROR'
                        Invoke-TokenInvalidate
                        $reauthFailed = $true
                    }
                } else {
                    Write-Host '  Re-authentication failed or cancelled - aborting.' -ForegroundColor Red
                    Write-CyberArkLog -Message 'Re-authentication failed mid-CSV - aborting.' -Level 'ERROR'
                    $reauthFailed = $true
                }
            }

            $isSuccess = ($result.Failures -eq 0 -and $result.ItemsProcessed -gt 0) -or
                         ($result.Successes -gt 0)
            $summary   = if ($isSuccess) {
                if ($result.Results.Count -gt 0 -and $result.Results[0].PSObject.Properties['Summary']) {
                    $result.Results[0].Summary
                } else { 'OK' }
            } else {
                if ($result.Errors.Count -gt 0) { $result.Errors[0].ErrorMessage } else { 'Failed' }
            }

            if ($isSuccess) { $okCount++ } else { $failCount++ }

            $outRow = [ordered]@{}
            # Never copy a secret input column (e.g. Users/Add InitialPassword, Users/ResetPassword
            # NewPassword, Accounts/Add Secret) into the results CSV in clear text.
            foreach ($col in $row.PSObject.Properties) {
                $outRow[$col.Name] = if ($col.Name -match '(?i)password|secret' -and "$($col.Value)" -ne '') { '***' } else { $col.Value }
            }
            $outRow['IsSuccess'] = $isSuccess
            $outRow['Summary']   = $summary
            $outputRows.Add([PSCustomObject]$outRow)
            $rowNumber++
            Add-DetailCsvRows -Rows $detailRows -RowNumber $rowNumber -Result $result -IsSuccess $isSuccess -Summary "$summary"

            if ($reauthFailed) {
                $fatal = $true
                break
            }
        }

        if ($outputRows.Count -gt 0) {
            $saved = Invoke-FileWriteWithRetry -Path $outputPath -Action {
                $outputRows | Export-Csv -LiteralPath $outputPath -NoTypeInformation -Encoding UTF8
            }
            if ($saved) {
                Write-Host "  Output: $outputPath" -ForegroundColor Green
            } else {
                Write-CyberArkLog -Level 'ERROR' -Message "Failed to write output CSV '$outputPath' (user declined to retry)."
            }
        }

        if ($detailRows.Count -gt 0) {
            $detailObjects = @(ConvertTo-DetailCsvObjects -Rows $detailRows)
            $savedDetail = Invoke-FileWriteWithRetry -Path $detailPath -Action {
                $detailObjects | Export-Csv -LiteralPath $detailPath -NoTypeInformation -Encoding UTF8
            }
            if ($savedDetail) {
                Write-Host "  Detail: $detailPath" -ForegroundColor Green
            } else {
                Write-CyberArkLog -Level 'ERROR' -Message "Failed to write detail CSV '$detailPath' (user declined to retry)."
            }
        }

        $msg = "'$fileName': $($outputRows.Count) processed - $okCount OK, $failCount failed."
        Write-Host "  $msg" -ForegroundColor $(if ($failCount -gt 0) { 'Yellow' } else { 'White' })
        Write-CyberArkLog -Message $msg -Level 'INFO'

        if ($meta.Action -notin @('List','Get')) {
            Add-CyberArkLogSummaryEntry -ModuleName $meta.Name `
                -ItemsProcessed $outputRows.Count -Successes $okCount -Failures $failCount
        }

        $totalProcessed += $outputRows.Count
        $totalOk        += $okCount
        $totalFail      += $failCount
        if ($fatal) { $anyFatal = $true; break }
    }

    if (-not $script:AutomationMode) {
        Write-Host ''
        Write-Host '  Press Enter to return to the menu.' -ForegroundColor DarkGray
        Read-Host | Out-Null
    }

    return [PSCustomObject]@{
        TotalProcessed = $totalProcessed
        TotalOk        = $totalOk
        TotalFail      = $totalFail
        AnyFatal       = $anyFatal
        SkippedFiles   = $skippedFiles
    }
}

#endregion
