#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Reports\Invoke-ReportsList.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-ReportsListInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Reports\Invoke-ReportsList.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'ReportsListTests' -MinLevel 'ERROR'

    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault'
    }

    function script:New-ReportsApiResponse {
        param(
            [object[]]$Reports = @(),
            [int]$StatusCode = 200
        )
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = $StatusCode
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = [PSCustomObject]@{
                value = @($Reports)
                count = @($Reports).Count
            }
        }
    }

    function script:New-ApiErrorResponse {
        param([int]$StatusCode = 403, [string]$ErrorMessage = 'Forbidden')
        return [PSCustomObject]@{
            IsSuccess     = $false
            StatusCode    = $StatusCode
            StatusMessage = "HTTP $StatusCode"
            ErrorMessage  = $ErrorMessage
            ErrorDetails  = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $ErrorMessage; Details = $null }
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $null
        }
    }

    $script:SampleReport = [PSCustomObject]@{
        reportId    = 1
        reportName  = 'Privileged Accounts - Basic'
        description = 'Lists all privileged accounts in the vault.'
        reportType  = 'PrivilegedAccounts'
        runDate     = '2026-01-15'
        aggregated  = $false
    }

    $script:SampleReport2 = [PSCustomObject]@{
        reportId    = 2
        reportName  = 'Safe Activities'
        description = 'Lists activity within safes.'
        reportType  = 'SafeActivities'
        runDate     = '2026-01-16'
        aggregated  = $true
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------
Describe 'ModuleMeta' {

    It 'RL01 - ModuleMeta.Name is ''List Reports''' {
        $ModuleMeta.Name | Should -Be 'List Reports'
    }

    It 'RL02 - Category is ''Reports''' {
        $ModuleMeta.Category | Should -Be 'Reports'
    }

    It 'RL03 - SupportedSystems is SelfHosted only (confirmed against a live ISPSS tenant - 404)' {
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
        $ModuleMeta.SupportedSystems.Count | Should -Be 1
    }
}

# -----------------------------------------------------------------
Describe 'Invoke-ReportsList - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-ReportsApiResponse -Reports @($script:SampleReport)
        }
        Mock Write-CyberArkLog { }
    }

    It 'RL04 - Successes=1, Failures=0, ItemsProcessed=1' {
        $r = Invoke-ReportsList -Token $script:MockToken
        $r.Successes      | Should -Be 1
        $r.Failures       | Should -Be 0
        $r.ItemsProcessed | Should -Be 1
    }

    It 'RL05 - IsFatal=$false on success' {
        $r = Invoke-ReportsList -Token $script:MockToken
        $r.IsFatal | Should -BeFalse
    }

    It 'RL06 - GET method is used' {
        Invoke-ReportsList -Token $script:MockToken
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } -Times 1
    }

    It 'RL07 - endpoint is /API/Reports' {
        Invoke-ReportsList -Token $script:MockToken
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Endpoint -eq '/API/Reports' } -Times 1
    }

    It 'RL08 - result entry maps ReportName and ReportType correctly' {
        $r = Invoke-ReportsList -Token $script:MockToken
        $r.Results[0].ReportName | Should -Be 'Privileged Accounts - Basic'
        $r.Results[0].ReportType | Should -Be 'PrivilegedAccounts'
    }

    It 'RL08a - a report missing optional fields (description/runDate/aggregated) under Set-StrictMode does not throw and is still counted as a success, not a failure' {
        # Regression test: the field-mapping block previously used bare dot notation with no
        # PSObject.Properties guard, so a report missing any one of these fields threw
        # PropertyNotFoundException under Set-StrictMode (always active via Manage-Privilege.ps1)
        # - silently converting what should be a successful row into a Failures entry.
        Set-StrictMode -Version Latest
        try {
            $sparseReport = [PSCustomObject]@{ reportId = 3; reportName = 'Sparse Report' }
            Mock Invoke-CyberArkAPI { script:New-ReportsApiResponse -Reports @($sparseReport) }
            # Direct assignment, not { $r = ... } | Should -Not -Throw - that scriptblock-pipe
            # pattern runs in a child scope and never assigns $r in this scope at all (see
            # Lessons-Learned-PowerShell-Pester.md Section 32). An uncaught exception here fails
            # the test just as clearly as a Should -Not -Throw failure would.
            $r = Invoke-ReportsList -Token $script:MockToken
            $r.Successes           | Should -Be 1
            $r.Failures            | Should -Be 0
            $r.Results[0].ReportID | Should -Be 3
            $r.Results[0].ReportName | Should -Be 'Sparse Report'
            $r.Results[0].Description | Should -Be ''
            $r.Results[0].RunDate     | Should -Be ''
            $r.Results[0].Aggregated  | Should -Be $false
        } finally {
            Set-StrictMode -Off
        }
    }
}

# -----------------------------------------------------------------
Describe 'Invoke-ReportsList - multiple results' {

    It 'RL09 - two reports: Successes=2, Results.Count=2' {
        Mock Write-CyberArkLog { }
        Mock Invoke-CyberArkAPI {
            script:New-ReportsApiResponse -Reports @($script:SampleReport, $script:SampleReport2)
        }
        $r = Invoke-ReportsList -Token $script:MockToken
        $r.Successes     | Should -Be 2
        $r.Results.Count | Should -Be 2
    }
}

# -----------------------------------------------------------------
Describe 'Invoke-ReportsList - search parameter' {

    It 'RL10 - search term is sent as query parameter' {
        $script:capturedQuery = $null
        Mock Write-CyberArkLog { }
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedQuery -Value $QueryParams -Scope Script
            script:New-ReportsApiResponse -Reports @($script:SampleReport)
        }
        Invoke-ReportsList -Token $script:MockToken -InputData @{ Search = 'Privileged' }
        $script:capturedQuery['search'] | Should -Be 'Privileged'
    }
}

# -----------------------------------------------------------------
Describe 'Invoke-ReportsList - empty result' {

    It 'RL11 - empty value array: Successes=0, no errors, IsFatal=$false' {
        Mock Write-CyberArkLog { }
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{
                IsSuccess     = $true
                StatusCode    = 200
                StatusMessage = 'OK'
                ErrorMessage  = $null
                ErrorDetails  = $null
                DataType      = 'JSON'
                RawResponse   = ''
                Data          = [PSCustomObject]@{ value = @(); count = 0 }
            }
        }
        $r = Invoke-ReportsList -Token $script:MockToken
        $r.Successes    | Should -Be 0
        $r.Failures     | Should -Be 0
        $r.Errors.Count | Should -Be 0
        $r.IsFatal      | Should -BeFalse
    }
}

# -----------------------------------------------------------------
Describe 'Invoke-ReportsList - API errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'RL12 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-ReportsList -Token $script:MockToken
        $r.IsFatal | Should -BeTrue
    }

    It 'RL13 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-ReportsList -Token $script:MockToken
        $r.IsFatal | Should -BeTrue
    }

    It 'RL14 - 403 Forbidden: IsFatal=$false, Failures=1' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-ReportsList -Token $script:MockToken
        $r.IsFatal  | Should -BeFalse
        $r.Failures | Should -Be 1
    }
}

# -----------------------------------------------------------------
Describe 'Invoke-ReportsList - null InputData' {

    It 'RL15 - null InputData: no throw' {
        Mock Write-CyberArkLog { }
        Mock Invoke-CyberArkAPI {
            script:New-ReportsApiResponse -Reports @($script:SampleReport)
        }
        { Invoke-ReportsList -Token $script:MockToken -InputData $null } | Should -Not -Throw
    }
}
