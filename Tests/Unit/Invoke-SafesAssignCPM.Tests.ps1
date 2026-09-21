#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Safes\Invoke-SafesAssignCPM.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafesAssignCPMInput is NOT tested here because it depends on Show-FieldPrompt and
    Read-Host, which are defined in / interactive with Manage-Privilege.ps1. That flow is
    covered by manual integration tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesAssignCPM.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-SafesAssignCPM into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafesAssignCPMTests' -MinLevel 'ERROR'

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

    $script:ValidInput = @{
        SafeName    = 'TestSafe'
        ManagingCPM = 'PasswordManager'
    }

    # Current safe state returned by the GET call - no CPM assigned yet
    $script:CurrentSafe = [PSCustomObject]@{
        safeName                  = 'TestSafe'
        description               = 'Original'
        location                  = '\'
        managingCPM               = ''
        numberOfVersionsRetention = 5
        numberOfDaysRetention     = 0
        autoPurgeEnabled          = $false
        creator                   = [PSCustomObject]@{ id = 'u1'; name = 'Admin' }
        creationTime              = 1700000000
    }

    # Updated safe state returned by the PUT call
    $script:UpdatedSafe = [PSCustomObject]@{
        safeName                  = 'TestSafe'
        description               = 'Original'
        location                  = '\'
        managingCPM               = 'PasswordManager'
        numberOfVersionsRetention = 5
        numberOfDaysRetention     = 0
        autoPurgeEnabled          = $false
        creator                   = [PSCustomObject]@{ id = 'u1'; name = 'Admin' }
        creationTime              = 1700000000
    }

    function script:New-SafeApiResponse {
        param(
            [Parameter(Mandatory = $true)] [PSCustomObject]$Safe,
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
            Data          = $Safe
        }
    }

    function script:New-ApiErrorResponse {
        param(
            [int]$StatusCode      = 403,
            [string]$ErrorMessage = 'Forbidden'
        )
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

    It 'A01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'A02 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'A03 - Category is Safes and Action is AssignCPM' {
        $ModuleMeta.Category | Should -Be 'Safes'
        $ModuleMeta.Action   | Should -Be 'AssignCPM'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAssignCPM - success' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }

        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                script:New-SafeApiResponse -Safe $script:CurrentSafe
            } else {
                script:New-SafeApiResponse -Safe $script:UpdatedSafe
            }
        }
    }

    It 'A04 - two API calls made total (GET then PUT)' {
        Invoke-SafesAssignCPM -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 2 -Exactly
    }

    It 'A05 - PUT body carries ManagingCPM from input and other fields from the GET response' {
        Invoke-SafesAssignCPM -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'PUT' -and
            $Body.ManagingCPM -eq 'PasswordManager' -and
            $Body.Description -eq 'Original' -and
            $Body.NumberOfVersionsRetention -eq 5 -and
            (-not $Body.ContainsKey('NumberOfDaysRetention'))
        } -Times 1
    }

    It 'A06 - Successes=1 and Failures=0' {
        $r = Invoke-SafesAssignCPM -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes | Should -Be 1
        $r.Failures  | Should -Be 0
    }

    It 'A07 - result entry ManagingCPM matches input' {
        $r = Invoke-SafesAssignCPM -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].ManagingCPM | Should -Be 'PasswordManager'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAssignCPM - WhatIf' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }

        Mock Invoke-CyberArkAPI {
            script:New-SafeApiResponse -Safe $script:CurrentSafe
        }
    }

    It 'A08 - WhatIf: Successes=1 and IsFatal=$false' {
        $r = Invoke-SafesAssignCPM -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
        $r.IsFatal   | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAssignCPM - validation' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { }
    }

    It 'A09 - empty SafeName: Failures=1 and no API call made' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = ''
        $r = Invoke-SafesAssignCPM -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'A10 - empty ManagingCPM: Failures=1 and no API call made' {
        $testInput = $script:ValidInput.Clone()
        $testInput.ManagingCPM = ''
        $r = Invoke-SafesAssignCPM -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'A11 - null InputData: Failures=1' {
        $r = Invoke-SafesAssignCPM -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAssignCPM - GET phase errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'A12 - GET 401: IsFatal=$true and no PUT attempted' {
        Mock Invoke-CyberArkAPI {
            script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized'
        }
        $r = Invoke-SafesAssignCPM -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAssignCPM - PUT phase errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'A13 - PUT 400 Bad Request: IsFatal=$false and Failures=1' {
        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                script:New-SafeApiResponse -Safe $script:CurrentSafe
            } else {
                script:New-ApiErrorResponse -StatusCode 400 -ErrorMessage 'Bad Request'
            }
        }
        $r = Invoke-SafesAssignCPM -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal  | Should -BeFalse
        $r.Failures | Should -Be 1
    }

    It 'A14 - PUT 401 Unauthorized: IsFatal=$true' {
        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                script:New-SafeApiResponse -Safe $script:CurrentSafe
            } else {
                script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized'
            }
        }
        $r = Invoke-SafesAssignCPM -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}

# A15-A17 (script:Get-SafesCPMOptions) were removed 2026-09-03: that function was deleted when
# the CPM picker moved to the shared Get-CpmOptions (Manage-Privilege.ps1), which queries live
# the same way and now also falls back to the profile's CPM_List if that call fails. Like the
# similar shared helper Invoke-EntitySearch, it has no unit test coverage of its own - see
# Testing-Plan.md for the manual-verification note.
