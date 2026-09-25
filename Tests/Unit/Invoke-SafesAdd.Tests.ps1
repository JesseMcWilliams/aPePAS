#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Safes\Invoke-SafesAdd.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafesAddInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    Set-StrictMode -Version Latest
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesAdd.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-SafesAdd into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafesAddTests' -MinLevel 'ERROR'

    # Minimal token stub
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault'
    }

    $script:ValidInput = @{
        SafeName                  = 'TestSafe'
        Description               = 'A test safe'
        Location                  = '\'
        ManagingCPM              = ''
        NumberOfVersionsRetention = '5'
        NumberOfDaysRetention     = '0'
        AutoPurgeEnabled          = 'false'
    }

    # Factory: build a mock API success response containing a single safe object
    function script:New-SafeApiResponse {
        param(
            [PSCustomObject]$Safe,
            [int]$StatusCode = 201
        )
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = $StatusCode
            StatusMessage = 'Created'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $Safe
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

    # Sample safe object matching the CyberArk API shape for a POST /API/Safes response
    $script:SampleSafeResponse = [PSCustomObject]@{
        safeName                  = 'TestSafe'
        description               = 'A test safe'
        location                  = '\'
        managingCPM              = ''
        numberOfVersionsRetention = 5
        numberOfDaysRetention     = 0
        autoPurgeEnabled          = $false
        olacEnabled               = $false
        creator                   = [PSCustomObject]@{ id = 'u1'; name = 'Admin' }
        creationTime              = 1700000000
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'A01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'A02 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'A03 - AcceptsInputFile is $true' {
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
    }

    It 'A04 - Category is Safes and Action is Add' {
        $ModuleMeta.Category | Should -Be 'Safes'
        $ModuleMeta.Action   | Should -Be 'Add'
    }

    It 'A05 - InputSchema contains SafeName with Required=$true' {
        $safeNameField = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'SafeName' }
        $safeNameField           | Should -Not -BeNullOrEmpty
        $safeNameField.Required  | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAdd - success (201)' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Invoke-CyberArkAPI {
            script:New-SafeApiResponse -Safe $script:SampleSafeResponse -StatusCode 201
        }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'A06 - returns a result object with all 9 required fields' {
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.PSObject.Properties.Name | Should -Contain 'ModuleName'
        $r.PSObject.Properties.Name | Should -Contain 'Category'
        $r.PSObject.Properties.Name | Should -Contain 'Action'
        $r.PSObject.Properties.Name | Should -Contain 'ItemsProcessed'
        $r.PSObject.Properties.Name | Should -Contain 'Successes'
        $r.PSObject.Properties.Name | Should -Contain 'Failures'
        $r.PSObject.Properties.Name | Should -Contain 'IsFatal'
        $r.PSObject.Properties.Name | Should -Contain 'Results'
        $r.PSObject.Properties.Name | Should -Contain 'Errors'
    }

    It 'A07 - Successes=1, ItemsProcessed=1, Failures=0' {
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes      | Should -Be 1
        $r.ItemsProcessed | Should -Be 1
        $r.Failures       | Should -Be 0
    }

    It 'A08 - result SafeName matches input' {
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].SafeName | Should -Be 'TestSafe'
    }

    It 'A09 - IsFatal is $false on success' {
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'A10 - POST method is used' {
        Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' } -Times 1
    }

    It 'A11 - endpoint is /API/Safes' {
        Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Endpoint -eq '/API/Safes' } -Times 1
    }

    It 'A11a - OLACEnabled is never included in the request body' {
        Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { -not $Body.ContainsKey('OLACEnabled') } -Times 1
    }

    It 'A11b - NumberOfDaysRetention=0: only NumberOfVersionsRetention is sent' {
        Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Body.NumberOfVersionsRetention -eq 5 -and (-not $Body.ContainsKey('NumberOfDaysRetention'))
        } -Times 1
    }

    It 'A11c - NumberOfDaysRetention>0: only NumberOfDaysRetention is sent' {
        $testInput = $script:ValidInput.Clone()
        $testInput.NumberOfDaysRetention = '90'
        Invoke-SafesAdd -Token $script:MockToken -InputData $testInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Body.NumberOfDaysRetention -eq 90 -and (-not $Body.ContainsKey('NumberOfVersionsRetention'))
        } -Times 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAdd - WhatIf' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{
                IsSuccess     = $true
                StatusCode    = 200
                StatusMessage = 'WhatIf'
                ErrorMessage  = $null
                ErrorDetails  = $null
                DataType      = 'JSON'
                RawResponse   = ''
                Data          = $null
            }
        }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'A12 - WhatIf: API is NOT called' {
        Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'A13 - WhatIf: Successes=1 (synthetic result counted)' {
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
    }

    It 'A14 - WhatIf: IsFatal=$false' {
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.IsFatal | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAdd - validation' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Invoke-CyberArkAPI { }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'A15 - empty SafeName: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = ''
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'A16 - null InputData: Failures=1, no API call' {
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'A21 - SafeName exceeding 28 characters: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = 'A' * 29
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'A22 - SafeName containing a reserved character: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = 'Safe/Name'
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'A23 - SafeName with leading whitespace: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = ' TestSafe'
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'A24 - SafeName at exactly 28 characters: no validation failure' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = 'A' * 28
        Mock Invoke-CyberArkAPI { script:New-SafeApiResponse -Safe $script:SampleSafeResponse }
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 0
        Should -Invoke Invoke-CyberArkAPI -Times 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAdd - errors' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'A17 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'A18 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'A19 - 409 Conflict: IsFatal=$false, error added' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 409 -ErrorMessage 'Safe already exists' }
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal      | Should -BeFalse
        $r.Errors.Count | Should -Be 1
    }

    It 'A20 - error entry ErrorMessage is not null or empty' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 409 -ErrorMessage 'Safe already exists' }
        $r = Invoke-SafesAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.Errors[0].ErrorMessage | Should -Not -BeNullOrEmpty
    }
}
