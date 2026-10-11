#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Reports\Invoke-ReportsExport.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-ReportsExportInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    Set-StrictMode -Version Latest
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Reports\Invoke-ReportsExport.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Same driver-scope stub as Invoke-PlatformsExport.Tests.ps1: run Action once, report success.
    function global:Invoke-FileWriteWithRetry {
        param([scriptblock]$Action, [string]$Path)
        try { & $Action; return $true } catch { return $false }
    }

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'ReportsExportTests' -MinLevel 'ERROR'

    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault'
    }

    $script:XlsxBytes = [byte[]](80, 75, 3, 4, 9, 8, 7, 6)

    # A 14.6 Swagger 'Report' object (GET /API/Reports -> reports[])
    function script:New-SwaggerReport {
        param([string]$Name = 'Inventory')
        [PSCustomObject]@{
            name = $Name; type = 'InventoryReports.InventoryReportUI'; filename = 'Inventory_2026-10-01.xml'
            createdBy = 'admin'; status = 'Done'; safe = 'PVWAReports'; location = 'Root\33'
        }
    }

    function script:New-ReportListResponse {
        param([object[]]$Reports = @(), [string]$Property = 'reports')
        [PSCustomObject]@{
            IsSuccess = $true; StatusCode = 200; ErrorMessage = $null; ErrorDetails = $null; DataType = 'JSON'
            Data = [PSCustomObject]@{ $Property = @($Reports); totalCount = @($Reports).Count }
        }
    }

    function script:New-FileResponse {
        param([string]$FileName = $null, [string]$DataType = 'File', $Data = $script:XlsxBytes)
        [PSCustomObject]@{
            IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null
            DataType = $DataType; Data = $Data; SuggestedFileName = $FileName
        }
    }

    function script:New-ApiErrorResponse {
        param([int]$StatusCode = 403, [string]$ErrorMessage = 'Forbidden')
        [PSCustomObject]@{
            IsSuccess = $false; StatusCode = $StatusCode; StatusMessage = "HTTP $StatusCode"; ErrorMessage = $ErrorMessage
            ErrorDetails = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $ErrorMessage; Details = $null }
            DataType = 'JSON'; RawResponse = ''; Data = $null
        }
    }

    # Decodes the ClassicReports 'data' value back to its Key=Value pairs
    function script:ConvertFrom-ClassicData {
        param([string]$Value)
        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
    Remove-Item -Path function:global:Invoke-FileWriteWithRetry -ErrorAction SilentlyContinue
}

Describe 'ModuleMeta' {
    It 'RX01 - Name, Category and Action' {
        $ModuleMeta.Name     | Should -Be 'Export Report'
        $ModuleMeta.Category | Should -Be 'Reports'
        $ModuleMeta.Action   | Should -Be 'Export'
    }

    It 'RX02 - SupportedSystems is SelfHosted only' {
        @($ModuleMeta.SupportedSystems) | Should -Be @('SelfHosted')
    }

    It 'RX03 - SupportsWhatIf, AcceptsInputFile, HasCustomInput, ExcludeFromExportAll; Version 1.0.0' {
        $ModuleMeta.SupportsWhatIf       | Should -BeTrue
        $ModuleMeta.AcceptsInputFile     | Should -BeTrue
        $ModuleMeta.HasCustomInput       | Should -BeTrue
        $ModuleMeta.ExcludeFromExportAll | Should -BeTrue
        $ModuleMeta.Version              | Should -Be '1.0.0'
    }

    It 'RX04 - InputSchema has optional ReportName, ReportID and Format columns' {
        @($ModuleMeta.InputSchema.Column) | Should -Be @('ReportName', 'ReportID', 'Format')
        @($ModuleMeta.InputSchema | Where-Object { $_.Required }).Count | Should -Be 0
    }
}

Describe 'Invoke-ReportsExport - input validation' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Invoke-CyberArkAPI { throw 'should not be called' }
    }

    It 'RX05 - neither ReportName nor ReportID: failure, no API call' {
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{}
        $r.Failures               | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'ReportName or ReportID is required'
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'RX06 - both ReportName and ReportID: failure, no API call' {
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportName = 'A'; ReportID = 'B' }
        $r.Failures               | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'not both'
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'RX07 - an invalid Format: failure, no API call' {
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportName = 'A'; Format = 'PDF' }
        $r.Failures               | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'Excel or CSV'
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

Describe 'Invoke-ReportsExport - by name (ClassicReports)' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        $script:ActiveProfile = [PSCustomObject]@{ OutputFolder = $TestDrive }
        $script:calls = [System.Collections.Generic.List[object]]::new()
    }

    It 'RX08 - resolves the name via GET /API/Reports (no search) and downloads via GET /API/ClassicReports with the psPAS data encoding' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $QueryParams, [switch]$WhatIf, $PageSize)
            $script:calls.Add([PSCustomObject]@{ Method = $Method; Endpoint = $Endpoint; QueryParams = $QueryParams; PageSize = $PageSize })
            if ($Endpoint -eq '/API/Reports') { return script:New-ReportListResponse -Reports @((script:New-SwaggerReport), (script:New-SwaggerReport -Name 'Other')) }
            script:New-FileResponse -FileName 'Inventory.xlsx'
        }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportName = 'inventory' }
        $r.Successes | Should -Be 1
        $r.Failures  | Should -Be 0
        $script:calls.Count | Should -Be 2
        $script:calls[0].Endpoint    | Should -Be '/API/Reports'
        $null -eq $script:calls[0].QueryParams | Should -BeTrue
        $script:calls[1].Method      | Should -Be 'GET'
        $script:calls[1].Endpoint    | Should -Be '/API/ClassicReports'
        $script:calls[1].PageSize    | Should -Be 0
        script:ConvertFrom-ClassicData $script:calls[1].QueryParams['data'] |
            Should -BeExactly 'Safe=PVWAReports^@^Folder=Root\33^@^Name=Inventory_2026-10-01.xml^@^Format=excel^@^Type=InventoryReports.InventoryReportUI'
        $r.Results[0].SavedPath | Should -Be (Join-Path $TestDrive 'Inventory.xlsx')
        [System.IO.File]::ReadAllBytes($r.Results[0].SavedPath) | Should -Be $script:XlsxBytes
    }

    It 'RX09 - Format=CSV sends Format=csv; CSV text (DataType Binary) is saved as text with a .csv name' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $QueryParams, [switch]$WhatIf, $PageSize)
            $script:calls.Add([PSCustomObject]@{ Endpoint = $Endpoint; QueryParams = $QueryParams })
            if ($Endpoint -eq '/API/Reports') { return script:New-ReportListResponse -Reports @(script:New-SwaggerReport) }
            script:New-FileResponse -DataType 'Binary' -Data "Safe,Account`r`nS1,A1`r`n"
        }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportName = 'Inventory'; Format = 'csv' }
        $r.Successes | Should -Be 1
        script:ConvertFrom-ClassicData $script:calls[1].QueryParams['data'] | Should -Match '\^@\^Format=csv\^@\^'
        $r.Results[0].SavedPath | Should -Match '^.*Report-Inventory-\d{8}-\d{6}\.csv$'
        Get-Content -LiteralPath $r.Results[0].SavedPath -Raw | Should -Match 'S1,A1'
    }

    It 'RX10 - also reads the legacy ''value'' list shape' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $QueryParams, [switch]$WhatIf, $PageSize)
            if ($Endpoint -eq '/API/Reports') { return script:New-ReportListResponse -Reports @(script:New-SwaggerReport) -Property 'value' }
            script:New-FileResponse -FileName 'x.xlsx'
        }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportName = 'Inventory' }
        $r.Successes | Should -Be 1
    }

    It 'RX11 - no report with that name: failure, no download' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $QueryParams, [switch]$WhatIf, $PageSize)
            $script:calls.Add($Endpoint)
            script:New-ReportListResponse -Reports @(script:New-SwaggerReport -Name 'Other')
        }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportName = 'Inventory' }
        $r.Failures               | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'No report named'
        $script:calls.Count       | Should -Be 1
    }

    It 'RX12 - several reports with that name: failure, no download' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $QueryParams, [switch]$WhatIf, $PageSize)
            $script:calls.Add($Endpoint)
            script:New-ReportListResponse -Reports @((script:New-SwaggerReport), (script:New-SwaggerReport))
        }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportName = 'Inventory' }
        $r.Failures               | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match '2 reports are named'
        $script:calls.Count       | Should -Be 1
    }

    It 'RX13 - a report without safe/location/filename/type but with an id falls back to /API/Reports/{id}/content' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $QueryParams, [switch]$WhatIf, $PageSize)
            $script:calls.Add([PSCustomObject]@{ Endpoint = $Endpoint; QueryParams = $QueryParams })
            if ($Endpoint -eq '/API/Reports') { return script:New-ReportListResponse -Reports @([PSCustomObject]@{ reportName = 'Legacy'; reportId = 'abc-123' }) }
            script:New-FileResponse -FileName 'Legacy.xlsx'
        }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportName = 'Legacy' }
        $r.Successes                           | Should -Be 1
        $script:calls[1].Endpoint              | Should -Be '/API/Reports/abc-123/content'
        $script:calls[1].QueryParams['format'] | Should -Be 'excel'
    }

    It 'RX14 - a report with neither download fields nor an id: failure, no download' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $QueryParams, [switch]$WhatIf, $PageSize)
            $script:calls.Add($Endpoint)
            script:New-ReportListResponse -Reports @([PSCustomObject]@{ name = 'Bare' })
        }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportName = 'Bare' }
        $r.Failures               | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match "can't be downloaded"
        $script:calls.Count       | Should -Be 1
    }

    It 'RX15 - a 401 on the lookup is fatal' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportName = 'Inventory' }
        $r.IsFatal  | Should -BeTrue
        $r.Failures | Should -Be 1
    }
}

Describe 'Invoke-ReportsExport - by ID' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        $script:ActiveProfile = [PSCustomObject]@{ OutputFolder = $TestDrive }
        $script:calls = [System.Collections.Generic.List[object]]::new()
    }

    It 'RX16 - ReportID calls GET /API/Reports/{id}/content?format=csv directly, with -PageSize 0' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $QueryParams, [switch]$WhatIf, $PageSize)
            $script:calls.Add([PSCustomObject]@{ Method = $Method; Endpoint = $Endpoint; QueryParams = $QueryParams; PageSize = $PageSize })
            script:New-FileResponse -FileName 'r.csv'
        }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportID = '6f1c0d2e-0000-4000-8000-000000000001'; Format = 'CSV' }
        $r.Successes                           | Should -Be 1
        $script:calls.Count                    | Should -Be 1
        $script:calls[0].Method                | Should -Be 'GET'
        $script:calls[0].Endpoint              | Should -Be '/API/Reports/6f1c0d2e-0000-4000-8000-000000000001/content'
        $script:calls[0].QueryParams['format'] | Should -Be 'csv'
        $script:calls[0].PageSize              | Should -Be 0
    }

    It 'RX17 - a 404 on the download mentions the PVWA 14.6 requirement and includes the ErrorCode' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'ERR404: Not Found' }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportID = 'x' }
        $r.Failures               | Should -Be 1
        $r.IsFatal                | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'ERR404'
        $r.Errors[0].ErrorMessage | Should -Match '14\.6'
    }

    It 'RX18 - a success with no file content is a failure' {
        Mock Invoke-CyberArkAPI { script:New-FileResponse -DataType 'Empty' -Data $null }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportID = 'x' }
        $r.Failures               | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'no file content'
    }

    It 'RX19 - status 0 on the download is fatal' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportID = 'x' }
        $r.IsFatal | Should -BeTrue
    }
}

Describe 'Invoke-ReportsExport - WhatIf' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        $script:ActiveProfile = [PSCustomObject]@{ OutputFolder = $TestDrive }
        $script:calls = [System.Collections.Generic.List[object]]::new()
    }

    It 'RX20 - WhatIf resolves the name but does not download or save' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $QueryParams, [switch]$WhatIf, $PageSize)
            $script:calls.Add($Endpoint)
            script:New-ReportListResponse -Reports @(script:New-SwaggerReport)
        }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportName = 'Inventory' } -WhatIf
        $r.Successes            | Should -Be 1
        $r.Results[0].SavedPath | Should -Be ''
        @($script:calls)        | Should -Be @('/API/Reports')
    }

    It 'RX21 - WhatIf by ID makes no API call' {
        Mock Invoke-CyberArkAPI { throw 'should not be called' }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportID = 'x' } -WhatIf
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

Describe 'Invoke-ReportsExport - automation mode Output Folder (F98)' {

    BeforeEach {
        $script:ActiveProfile  = [PSCustomObject]@{ OutputFolder = (Join-Path $TestDrive 'profile') }
        $script:OutputFolder   = Join-Path $TestDrive 'auto'
        $script:AutomationMode = $true
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    AfterEach {
        Remove-Variable -Name ActiveProfile, OutputFolder, AutomationMode -Scope Script -ErrorAction SilentlyContinue
    }

    It 'RX22 - in automation mode the report goes to -OutputFolder (or the job step''s), not the profile folder' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $QueryParams, [switch]$WhatIf, $PageSize)
            if ($Endpoint -eq '/API/Reports') { return script:New-ReportListResponse -Reports @(script:New-SwaggerReport) }
            script:New-FileResponse -FileName 'Inventory.xlsx'
        }
        $r = Invoke-ReportsExport -Token $script:MockToken -InputData @{ ReportName = 'inventory' }
        $r.Successes | Should -Be 1
        $r.Results[0].SavedPath | Should -Be (Join-Path $TestDrive 'auto\Inventory.xlsx')
    }
}
