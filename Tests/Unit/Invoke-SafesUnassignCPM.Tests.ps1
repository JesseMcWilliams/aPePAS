#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Safes\Invoke-SafesUnassignCPM.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafesUnassignCPMInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesUnassignCPM.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-SafesUnassignCPM into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafesUnassignCPMTests' -MinLevel 'ERROR'

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
        SafeName = 'TestSafe'
    }

    # Current safe state returned by the GET call - CPM assigned
    $script:CurrentSafe = [PSCustomObject]@{
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

    # Updated safe state returned by the PUT call - CPM cleared
    $script:UpdatedSafe = [PSCustomObject]@{
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

    It 'N01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'N02 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'N03 - Category is Safes and Action is UnassignCPM' {
        $ModuleMeta.Category | Should -Be 'Safes'
        $ModuleMeta.Action   | Should -Be 'UnassignCPM'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesUnassignCPM - success' {

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

    It 'N04 - two API calls made total (GET then PUT)' {
        Invoke-SafesUnassignCPM -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 2 -Exactly
    }

    It 'N05 - PUT body forces ManagingCPM to empty regardless of the current value' {
        Invoke-SafesUnassignCPM -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'PUT' -and $Body.ManagingCPM -eq '' -and $Body.Description -eq 'Original'
        } -Times 1
    }

    It 'N06 - Successes=1 and Failures=0' {
        $r = Invoke-SafesUnassignCPM -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes | Should -Be 1
        $r.Failures  | Should -Be 0
    }

    It 'N07 - result entry ManagingCPM is empty' {
        $r = Invoke-SafesUnassignCPM -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].ManagingCPM | Should -Be ''
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesUnassignCPM - WhatIf' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }

        Mock Invoke-CyberArkAPI {
            script:New-SafeApiResponse -Safe $script:CurrentSafe
        }
    }

    It 'N08 - WhatIf: Successes=1 and IsFatal=$false' {
        $r = Invoke-SafesUnassignCPM -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
        $r.IsFatal   | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesUnassignCPM - validation' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { }
    }

    It 'N09 - empty SafeName: Failures=1 and no API call made' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = ''
        $r = Invoke-SafesUnassignCPM -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'N10 - null InputData: Failures=1' {
        $r = Invoke-SafesUnassignCPM -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesUnassignCPM - GET phase errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'N11 - GET 401: IsFatal=$true and no PUT attempted' {
        Mock Invoke-CyberArkAPI {
            script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized'
        }
        $r = Invoke-SafesUnassignCPM -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesUnassignCPM - PUT phase errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'N12 - PUT 400 Bad Request: IsFatal=$false and Failures=1' {
        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                script:New-SafeApiResponse -Safe $script:CurrentSafe
            } else {
                script:New-ApiErrorResponse -StatusCode 400 -ErrorMessage 'Bad Request'
            }
        }
        $r = Invoke-SafesUnassignCPM -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal  | Should -BeFalse
        $r.Failures | Should -Be 1
    }

    It 'N13 - PUT 401 Unauthorized: IsFatal=$true' {
        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                script:New-SafeApiResponse -Safe $script:CurrentSafe
            } else {
                script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized'
            }
        }
        $r = Invoke-SafesUnassignCPM -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}
