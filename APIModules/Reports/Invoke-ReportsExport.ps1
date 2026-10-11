#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Export Report'
    Category         = 'Reports'
    Action           = 'Export'
    # Self-Hosted only, like Reports/List: GET /API/Reports returned HTTP 404 on a live ISPSS
    # tenant (Testing_Checklist-Self-Hosted.md, Reports), and the download endpoints below are
    # in the Self-Hosted 14.6 Swagger only. psPAS Export-PASReport asserts PVWA 14.6+.
    Description      = 'Download a generated report (Excel or CSV) to the profile''s Output Folder, by report name or ID. Self-Hosted only, PVWA 14.6+.'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'ReportName'; Required = $false; Description = 'Exact report name as shown by Reports/List. Must match exactly one report. Supply ReportName or ReportID.' }
        @{ Column = 'ReportID';   Required = $false; Description = 'Report ID (GUID), used with GET /API/Reports/{id}/content. Supply ReportName or ReportID.' }
        @{ Column = 'Format';     Required = $false; Description = 'Excel (default, saved as .xlsx) or CSV.' }
    )
    ExcludeFromExportAll = $true
    Priority         = 71
    Version          = '1.0.0'
}

function Get-ReportsExportInput {
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

    Write-Host '  Export Report  (run Reports > List first to see report names)' -ForegroundColor DarkGray
    Write-Host ''

    $reportName = Show-FieldPrompt -Label 'Report Name' `
        -Default $(if ($Defaults['ReportName']) { $Defaults['ReportName'] } else { '' }) `
        -Description 'Exact report name. Leave blank to enter a report ID instead.'

    $reportId = ''
    if (-not $reportName) {
        $reportId = Show-FieldPrompt -Label 'Report ID' `
            -Default $(if ($Defaults['ReportID']) { $Defaults['ReportID'] } else { '' }) `
            -Description 'Report ID (GUID).'
        if (-not $reportId) { return $null }
    }

    $format = Show-FieldPrompt -Label 'Format' `
        -Default $(if ($Defaults['Format']) { $Defaults['Format'] } else { 'Excel' }) `
        -Description 'Excel or CSV.'

    return @{
        ReportName = $reportName
        ReportID   = $reportId
        Format     = $format
    }
}

function script:Get-ReportsExportField {
    # Returns the first present, non-empty property of $Object among $Names, or ''.
    param([object]$Object, [string[]]$Names)
    foreach ($n in $Names) {
        if ($Object.PSObject.Properties[$n] -and "$($Object.$n)" -ne '') { return "$($Object.$n)" }
    }
    return ''
}

function Invoke-ReportsExport {
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

    $reportName = if ($InputData['ReportName']) { "$($InputData['ReportName'])".Trim() } else { '' }
    $reportId   = if ($InputData['ReportID'])   { "$($InputData['ReportID'])".Trim() }   else { '' }
    $formatIn   = if ($InputData['Format'])     { "$($InputData['Format'])".Trim() }     else { 'Excel' }

    $inputError = $null
    if ($reportName -and $reportId) {
        $inputError = 'Supply ReportName or ReportID, not both.'
    } elseif (-not $reportName -and -not $reportId) {
        $inputError = 'ReportName or ReportID is required.'
    }
    # Both download endpoints take 'excel' or 'csv' (14.6 Swagger; psPAS Export-PASReport maps
    # XLSX/XLS to excel). XLSX is accepted as an alias for Excel.
    $format = ''
    if (-not $inputError) {
        if ($formatIn -match '^(?i)(excel|xlsx)$') { $format = 'excel' }
        elseif ($formatIn -match '^(?i)csv$')      { $format = 'csv' }
        else { $inputError = "Format '$formatIn' is not valid. Use Excel or CSV." }
    }
    if ($inputError) {
        Write-CyberArkLog -Level 'ERROR' -Message "Invoke-ReportsExport: $inputError"
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $inputError; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }
    $extension = if ($format -eq 'csv') { '.csv' } else { '.xlsx' }

    Write-CyberArkLog -Level 'INFO' -Message "Starting report export. $(if ($reportName) { "ReportName='$reportName'" } else { "ReportID='$reportId'" }) Format=$format."

    # --- Resolve the report by name via GET /API/Reports ---
    # No ?search= here: psPAS Get-PASReport asserts PVWA 15.0 for search/filter, while the
    # download needs only 14.6. The exact-name match is done locally.
    $classicData = $null
    if ($reportName) {
        Write-CyberArkLog -Level 'DEBUG' -Message 'GET /API/Reports (resolve report by name)'
        $listResp = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/Reports' -WhatIf:$WhatIf.IsPresent
        if (-not $listResp.IsSuccess) {
            $msg = "Report lookup failed (HTTP $($listResp.StatusCode)): $($listResp.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $listResp.ErrorDetails })
            $result.Failures++
            $result.ItemsProcessed++
            $result.IsFatal = ($listResp.StatusCode -in @(401, 0))
            return $result
        }

        # The 14.6 Swagger (GetReportsResponse) returns the list under 'reports'; 'value' is
        # also read, for the shape Reports/List has always expected.
        [array]$reports = @(if ($listResp.Data -and $listResp.Data.PSObject.Properties['reports']) {
            $listResp.Data.reports
        } elseif ($listResp.Data -and $listResp.Data.PSObject.Properties['value']) {
            $listResp.Data.value
        })
        [array]$found = @($reports | Where-Object { (script:Get-ReportsExportField -Object $_ -Names @('name', 'reportName')) -ieq $reportName })

        if ($found.Count -ne 1) {
            $msg = if ($found.Count -eq 0) {
                "No report named '$reportName' was found. Run Reports > List to see the report names."
            } else {
                "$($found.Count) reports are named '$reportName'. Use the ReportID column to pick one."
            }
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }
        $report = $found[0]

        # A 14.6 Report object (Swagger 'Report') carries safe, location, filename and type,
        # which are exactly what GET /API/ClassicReports needs (psPAS Export-PASReport's Safe,
        # Folder, FileName and Type). It has no ID property, so the ID route is only a fallback
        # for a response that does include one.
        $safe     = script:Get-ReportsExportField -Object $report -Names @('safe')
        $folder   = script:Get-ReportsExportField -Object $report -Names @('location')
        $fileName = script:Get-ReportsExportField -Object $report -Names @('filename')
        $type     = script:Get-ReportsExportField -Object $report -Names @('type')
        if ($safe -and $folder -and $fileName -and $type) {
            $classicData = [ordered]@{ Safe = $safe; Folder = $folder; Name = $fileName; Format = $format; Type = $type }
        } else {
            $reportId = script:Get-ReportsExportField -Object $report -Names @('id', 'reportId')
            if (-not $reportId) {
                $msg = "Report '$reportName' was found, but the response has neither its safe/location/filename/type nor an ID, so it can't be downloaded."
                Write-CyberArkLog -Level 'ERROR' -Message $msg
                $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
                $result.Failures++
                $result.ItemsProcessed++
                return $result
            }
        }
    }

    # --- Build the download request ---
    if ($classicData) {
        # psPAS Export-PASReport: Key=Value pairs, unescaped, joined with '^@^', UTF-8 Base64
        # encoded, then URL-encoded. New-CyberArkQuery does the URL encoding.
        $pairs     = foreach ($k in $classicData.Keys) { "$k=$($classicData[$k])" }
        $dataValue = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($pairs -join '^@^')))
        $endpoint  = '/API/ClassicReports'
        $query     = @{ data = $dataValue }
        $label     = if ($reportName) { $reportName } else { $classicData['Name'] }
    } else {
        $endpoint  = "/API/Reports/$([Uri]::EscapeDataString($reportId))/content"
        $query     = @{ format = $format }
        $label     = if ($reportName) { $reportName } else { $reportId }
    }
    $requestLog = if ($classicData) {
        "GET $endpoint (Safe='$($classicData['Safe'])' Folder='$($classicData['Folder'])' Name='$($classicData['Name'])' Type='$($classicData['Type'])' Format=$format)"
    } else { "GET ${endpoint}?format=$format" }
    Write-CyberArkLog -Level 'DEBUG' -Message $requestLog

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: $requestLog would be downloaded and saved."
        $result.Results.Add([PSCustomObject]@{
            ReportName = $reportName
            ReportID   = $reportId
            Format     = $format
            SavedPath  = ''
            Exported   = $true
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # -PageSize 0: a file download is a single resource, so no limit/offset may be added.
    $response = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint $endpoint -QueryParams $query -PageSize 0

    if (-not $response.IsSuccess) {
        $hint = if ($response.StatusCode -eq 404) { ' Report download needs PVWA 14.6 or later (Self-Hosted only).' } else { '' }
        $msg  = "Report download failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)$hint"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $response.ErrorDetails })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        return $result
    }

    # A binary file (Excel) arrives as DataType 'File' (bytes). CSV text without a
    # Content-Disposition header arrives as DataType 'Binary' (raw text, not JSON).
    $bytes = $null
    if ($response.DataType -eq 'File' -and $response.Data) {
        $bytes = [byte[]]$response.Data
    } elseif ($response.DataType -eq 'Binary' -and $response.Data) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("$($response.Data)")
    }
    if (-not $bytes) {
        $msg = "Report download returned HTTP $($response.StatusCode) but no file content (DataType='$($response.DataType)')."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # Output Folder resolution matches Invoke-PlatformsExport.ps1: relative paths resolve against
    # the project root ($script:APIModulesPath's parent), not this file's folder.
    $outputFolder = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['OutputFolder'] -and $script:ActiveProfile.OutputFolder) {
        $script:ActiveProfile.OutputFolder
    } else { (Get-Location).Path }
    if (-not [System.IO.Path]::IsPathRooted($outputFolder)) {
        $projectRoot  = if ($script:APIModulesPath) { Split-Path -Path $script:APIModulesPath -Parent } else { (Get-Location).Path }
        $outputFolder = Join-Path $projectRoot $outputFolder
    }
    if (-not (Test-Path -LiteralPath $outputFolder)) {
        New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
    }

    $saveName = if ($response.PSObject.Properties['SuggestedFileName'] -and $response.SuggestedFileName) {
        $response.SuggestedFileName
    } else {
        "Report-$label-$(Get-Date -Format 'yyyyMMdd-HHmmss')$extension"
    }
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $safeFileName = -join ($saveName.ToCharArray() | ForEach-Object { if ($invalidChars -contains $_) { '_' } else { $_ } })
    $savedPath    = Join-Path $outputFolder $safeFileName

    $saved = Invoke-FileWriteWithRetry -Path $savedPath -Action {
        [System.IO.File]::WriteAllBytes($savedPath, $bytes)
    }
    if (-not $saved) {
        $msg = "Report downloaded but the file could not be saved to '$savedPath' (user declined to retry)."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $result.Results.Add([PSCustomObject]@{
        ReportName = $reportName
        ReportID   = $reportId
        Format     = $format
        SavedPath  = $savedPath
        Exported   = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Report export complete. Saved: $savedPath"
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
