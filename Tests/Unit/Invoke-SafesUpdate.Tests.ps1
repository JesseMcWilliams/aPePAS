#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Safes\Invoke-SafesUpdate.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafesUpdateInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    Set-StrictMode -Version Latest
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesUpdate.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-SafesUpdate into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafesUpdateTests' -MinLevel 'ERROR'

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

    # Standard valid input - Description provided, ManagingCPM left blank (falls back to current)
    $script:ValidInput = @{
        SafeName                  = 'TestSafe'
        Description               = 'Updated'
        ManagingCPM               = ''
        NumberOfVersionsRetention = '7'
        NumberOfDaysRetention     = '0'
        AutoPurgeEnabled          = 'false'
    }

    # Current safe state returned by the GET call
    $script:CurrentSafe = [PSCustomObject]@{
        safeName                  = 'TestSafe'
        description               = 'Original'
        location                  = '\'
        managingCPM               = 'CPM1'
        numberOfVersionsRetention = 5
        numberOfDaysRetention     = 0
        autoPurgeEnabled          = $false
        olacEnabled               = $false
        creator                   = [PSCustomObject]@{ id = 'u1'; name = 'Admin' }
        creationTime              = 1700000000
    }

    # Updated safe state returned by the PUT call
    $script:UpdatedSafe = [PSCustomObject]@{
        safeName                  = 'TestSafe'
        description               = 'Updated'
        location                  = '\'
        managingCPM               = 'CPM1'
        numberOfVersionsRetention = 7
        numberOfDaysRetention     = 0
        autoPurgeEnabled          = $false
        olacEnabled               = $false
        creator                   = [PSCustomObject]@{ id = 'u1'; name = 'Admin' }
        creationTime              = 1700000000
    }

    # Factory: build a mock API success response for a single safe object
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

    # Factory: build a mock API failure response
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

    It 'U01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'U02 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'U03 - AcceptsInputFile is $true' {
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
    }

    It 'U04 - Category is Safes and Action is Update' {
        $ModuleMeta.Category | Should -Be 'Safes'
        $ModuleMeta.Action   | Should -Be 'Update'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesUpdate - success' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }

        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                # GET - return current safe
                script:New-SafeApiResponse -Safe $script:CurrentSafe
            } else {
                # PUT - return updated safe
                script:New-SafeApiResponse -Safe $script:UpdatedSafe
            }
        }
    }

    It 'U05 - two API calls made total (GET then PUT)' {
        Invoke-SafesUpdate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 2 -Exactly
    }

    It 'U05a - OLACEnabled is never included in the PUT body' {
        Invoke-SafesUpdate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'PUT' -and (-not $Body.ContainsKey('OLACEnabled'))
        } -Times 1
    }

    It 'U05b - merged NumberOfDaysRetention=0: only NumberOfVersionsRetention is sent' {
        Invoke-SafesUpdate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'PUT' -and $Body.NumberOfVersionsRetention -eq 7 -and (-not $Body.ContainsKey('NumberOfDaysRetention'))
        } -Times 1
    }

    It 'U05c - merged NumberOfDaysRetention>0: only NumberOfDaysRetention is sent' {
        $testInput = $script:ValidInput.Clone()
        $testInput.NumberOfDaysRetention = '90'
        Invoke-SafesUpdate -Token $script:MockToken -InputData $testInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'PUT' -and $Body.NumberOfDaysRetention -eq 90 -and (-not $Body.ContainsKey('NumberOfVersionsRetention'))
        } -Times 1
    }

    It 'U06 - second API call uses PUT method' {
        $capturedCalls = [System.Collections.Generic.List[hashtable]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $capturedCalls.Add($PSBoundParameters)
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                script:New-SafeApiResponse -Safe $script:CurrentSafe
            } else {
                script:New-SafeApiResponse -Safe $script:UpdatedSafe
            }
        }
        $script:CallCount = 0
        Invoke-SafesUpdate -Token $script:MockToken -InputData $script:ValidInput
        $capturedCalls[1].Method | Should -Be 'PUT'
    }

    It 'U07 - Successes=1 and Failures=0' {
        $r = Invoke-SafesUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes | Should -Be 1
        $r.Failures  | Should -Be 0
    }

    It 'U08 - IsFatal is $false on success' {
        $r = Invoke-SafesUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'U09 - result entry SafeName matches input' {
        $r = Invoke-SafesUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].SafeName | Should -Be 'TestSafe'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesUpdate - WhatIf' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }

        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            # Both GET and WhatIf PUT return success; WhatIf flag is passed to Invoke-CyberArkAPI
            script:New-SafeApiResponse -Safe $script:CurrentSafe
        }
    }

    It 'U10 - WhatIf: Successes=1 and IsFatal=$false' {
        $r = Invoke-SafesUpdate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
        $r.IsFatal   | Should -BeFalse
    }

    It 'U11 - WhatIf: result entry exists in Results' {
        $r = Invoke-SafesUpdate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Results.Count | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesUpdate - validation' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { }
    }

    It 'U12 - empty SafeName: Failures=1 and no API call made' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = ''
        $r = Invoke-SafesUpdate -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'U13 - null InputData: Failures=1' {
        $r = Invoke-SafesUpdate -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
    }

    It 'U18 - SafeName exceeding 28 characters: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = 'A' * 29
        $r = Invoke-SafesUpdate -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'U19 - SafeName containing a reserved character: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = 'Safe|Name'
        $r = Invoke-SafesUpdate -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'U20 - SafeName with leading whitespace: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = ' TestSafe'
        $r = Invoke-SafesUpdate -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesUpdate - GET phase errors' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'U14 - GET 401: IsFatal=$true and no PUT attempted' {
        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized'
        }
        $r = Invoke-SafesUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
        # Only the GET call should have been made
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly
    }

    It 'U15 - GET status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI {
            script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure'
        }
        $r = Invoke-SafesUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesUpdate - PUT phase errors' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'U16 - PUT 400 Bad Request: IsFatal=$false and Failures=1' {
        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                script:New-SafeApiResponse -Safe $script:CurrentSafe
            } else {
                script:New-ApiErrorResponse -StatusCode 400 -ErrorMessage 'Bad Request'
            }
        }
        $r = Invoke-SafesUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal  | Should -BeFalse
        $r.Failures | Should -Be 1
    }

    It 'U17 - PUT 401 Unauthorized: IsFatal=$true' {
        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                script:New-SafeApiResponse -Safe $script:CurrentSafe
            } else {
                script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized'
            }
        }
        $r = Invoke-SafesUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}
