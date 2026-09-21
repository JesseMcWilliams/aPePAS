#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Safes\Invoke-SafesDelete.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafesDeleteInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesDelete.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-SafesDelete into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafesDeleteTests' -MinLevel 'ERROR'

    # Minimal token stub (SelfHosted)
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://test.cyberark.local'
    }

    $script:ValidInput = @{ SafeName = 'TestSafe' }

    # Factory: build a mock API success response for a delete (204 No Content)
    function script:New-DeleteApiResponse {
        param([bool]$IsSuccess = $true, [int]$StatusCode = 204)
        return [PSCustomObject]@{
            IsSuccess     = $IsSuccess
            StatusCode    = $StatusCode
            StatusMessage = if ($StatusCode -eq 204) { 'No Content' } else { 'OK' }
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $null
        }
    }

    # Factory: build a mock API failure response
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
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'D01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'D02 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'D03 - AcceptsInputFile is $true' {
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
    }

    It 'D04 - ProducesOutput is $false' {
        $ModuleMeta.ProducesOutput | Should -BeFalse
    }

    It 'D05 - Category=Safes and Action=Delete' {
        $ModuleMeta.Category | Should -Be 'Safes'
        $ModuleMeta.Action   | Should -Be 'Delete'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesDelete - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'D06 - Successes=1, Failures=0, ItemsProcessed=1' {
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes      | Should -Be 1
        $r.Failures       | Should -Be 0
        $r.ItemsProcessed | Should -Be 1
    }

    It 'D07 - IsFatal=$false on success' {
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'D08 - DELETE method is used' {
        Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'D09 - endpoint contains SafeName' {
        Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Endpoint -like '*TestSafe*' }
    }

    It 'D10 - result entry has Deleted=$true' {
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Results.Count       | Should -Be 1
        $r.Results[0].Deleted  | Should -BeTrue
        $r.Results[0].SafeName | Should -Be 'TestSafe'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesDelete - WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'D11 - WhatIf: API is NOT called' {
        Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'D12 - WhatIf: Successes=1' {
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesDelete - validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'D13 - empty SafeName: Failures=1 and API not called' {
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData @{ SafeName = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'D14 - null InputData: Failures=1' {
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesDelete - errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'D15 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'D16 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'D17 - 403 Forbidden: IsFatal=$false and error added' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal      | Should -BeFalse
        $r.Errors.Count | Should -Be 1
    }

    It 'D18 - 404 Not Found: IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
# HTTP 409 rename-instead fallback (Safe History Retention can block delete even on an
# empty safe - confirmed live 2026-09-04; see Testing-Plan.md K10).
Describe 'Invoke-SafesDelete - 409 rename fallback' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }

        function script:New-SafeGetResponse {
            param([string]$Description = 'Original description', [string]$Location = '\', [int]$VersionsRetention = 5, [int]$DaysRetention = 0, [bool]$AutoPurge = $false)
            [PSCustomObject]@{
                IsSuccess     = $true
                StatusCode    = 200
                ErrorMessage  = $null
                ErrorDetails  = $null
                DataType      = 'JSON'
                RawResponse   = ''
                Data          = [PSCustomObject]@{
                    safeName                  = 'TestSafe'
                    description               = $Description
                    location                  = $Location
                    managingCPM              = ''
                    numberOfVersionsRetention = $VersionsRetention
                    numberOfDaysRetention     = $DaysRetention
                    autoPurgeEnabled          = $AutoPurge
                }
            }
        }
    }

    It 'D19 - user accepts rename: renames to 1_DEL_ prefix plus SafeName, reports Success not Failure' {
        Mock Read-Host { 'Y' }
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'DELETE') { script:New-ApiErrorResponse -StatusCode 409 -ErrorMessage 'Conflict' }
            elseif ($Method -eq 'GET') { script:New-SafeGetResponse }
            else { script:New-DeleteApiResponse -StatusCode 200 }
        }
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes           | Should -Be 1
        $r.Failures            | Should -Be 0
        $r.Results[0].Renamed  | Should -BeTrue
        $r.Results[0].Deleted  | Should -BeFalse
        $r.Results[0].NewSafeName | Should -Be '1_DEL_TestSafe'
    }

    It 'D20 - user declines rename: original 409 reported as a normal Failure' {
        Mock Read-Host { 'N' }
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 409 -ErrorMessage 'Conflict' }
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Failures     | Should -Be 1
        $r.Successes    | Should -Be 0
        $r.Errors.Count | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'D21 - new safe name is truncated to stay at or under 28 characters for a long SafeName' {
        Mock Read-Host { 'Y' }
        $longName = 'ThisSafeNameIsDefinitelyTooLongForCyberArk'
        Mock Invoke-CyberArkAPI {
            param($Method, $Body)
            if ($Method -eq 'DELETE') { script:New-ApiErrorResponse -StatusCode 409 -ErrorMessage 'Conflict' }
            elseif ($Method -eq 'GET') { script:New-SafeGetResponse }
            else {
                $Body['SafeName'].Length | Should -BeLessOrEqual 28
                script:New-DeleteApiResponse -StatusCode 200
            }
        }
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData @{ SafeName = $longName }
        $r.Results[0].NewSafeName.Length | Should -BeLessOrEqual 28
        $r.Results[0].NewSafeName        | Should -Match '^1_DEL_'
    }

    It 'D22 - existing description gets the delete-requested date appended' {
        Mock Read-Host { 'Y' }
        $capturedBody = $null
        Mock Invoke-CyberArkAPI {
            param($Method, $Body)
            if ($Method -eq 'DELETE') { script:New-ApiErrorResponse -StatusCode 409 -ErrorMessage 'Conflict' }
            elseif ($Method -eq 'GET') { script:New-SafeGetResponse -Description 'Prod app safe' }
            else {
                $script:capturedBody = $Body
                script:New-DeleteApiResponse -StatusCode 200
            }
        }
        Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $script:capturedBody['Description'] | Should -Match '^Prod app safe \| Delete requested \d{4}-\d{2}-\d{2}$'
    }

    It 'D23 - no existing description is left blank, not given a standalone date note' {
        Mock Read-Host { 'Y' }
        Mock Invoke-CyberArkAPI {
            param($Method, $Body)
            if ($Method -eq 'DELETE') { script:New-ApiErrorResponse -StatusCode 409 -ErrorMessage 'Conflict' }
            elseif ($Method -eq 'GET') { script:New-SafeGetResponse -Description '' }
            else {
                $Body['Description'] | Should -Be ''
                script:New-DeleteApiResponse -StatusCode 200
            }
        }
        Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
    }

    It 'D24 - rename PUT itself fails: reported as a Failure with both the original and rename errors' {
        Mock Read-Host { 'Y' }
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'DELETE') { script:New-ApiErrorResponse -StatusCode 409 -ErrorMessage 'Conflict' }
            elseif ($Method -eq 'GET') { script:New-SafeGetResponse }
            else { script:New-ApiErrorResponse -StatusCode 400 -ErrorMessage 'Bad Request' }
        }
        $r = Invoke-SafesDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Failures              | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'Rename fallback also failed'
    }
}
