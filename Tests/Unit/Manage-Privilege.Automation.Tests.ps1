#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Manage-Privilege.ps1's non-interactive automation mode
    (-StartProfile -Category -Action).

.DESCRIPTION
    Deliberately kept in its own file, separate from Tests\Unit\Manage-Privilege.Tests.ps1,
    which has a documented Pester/file-interaction hang tied to Invoke-FileWriteWithRetry in that
    exact file (see that file's own trailing comment, referencing Pester issue #2669). Covers:
    -Category/-Action/-InputFile/-InputJson parameter validation, Invoke-CsvProcessing's
    -FilePaths automation route, Invoke-ProfileConnect's automation-mode fresh-auth guard,
    Invoke-TokenRefresh's automation-mode silent-refresh branch, and the
    Get-AutomationExitCode result-to-exit-code mapping.
#>

BeforeAll {
    # ── Stubs for module functions imported at runtime ────────────────────────────────────
    # Same convention as Manage-Privilege.Tests.ps1. Also stubs the four Auth-module functions
    # (Get-/Update-SelfHostedAuthToken, Get-/Update-ISPSSAuthToken) that Manage-Privilege.ps1
    # normally Import-Module's near the bottom of the file, AFTER the "return if dot-sourced"
    # guard - so dot-sourcing the driver for tests never loads the real ones, unlike a real launch.
    function global:Write-CyberArkLog {
        param([string]$Message, [string]$Level)
    }
    function global:Initialize-CyberArkLog {
        param($ProfileName, $Destination, $MinLevel, $LogFolder,
              $SystemType, $AuthMethod, $BaseURL, [switch]$WhatIfMode, [switch]$OverwriteFile)
    }
    function global:Close-CyberArkLog { }
    function global:Add-CyberArkLogSummaryEntry {
        param($ModuleName, $ItemsProcessed, $Successes, $Failures)
    }
    function global:Invoke-CyberArkAPI {
        param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams,
              [switch]$WhatIf, [switch]$IgnoreSSL)
    }
    function global:Get-AuthToken           { param([switch]$IgnoreSSL) return $null }
    function global:Import-AuthToken        { param($Path, [switch]$AutoRefresh, [switch]$IgnoreExpiry) return $null }
    function global:Save-AuthToken          { param($TokenObject, $ProfileName) }
    function global:Get-SelfHostedAuthToken {
        param($AuthMethod, $PVWAUrl, $Credential, $Certificate, [switch]$ConcurrentSession, [switch]$IgnoreSSL)
        return $null
    }
    function global:Get-ISPSSAuthToken {
        param($AuthMethod, $Subdomain, $ClientId, $ClientSecret, [switch]$IgnoreSSL)
        return $null
    }
    function global:Update-SelfHostedAuthToken { param($TokenObject) return $null }
    function global:Update-ISPSSAuthToken      { param($TokenObject) return $null }

    # ── Temp directory: replaces the real profile/token folder ─────────────────────────────
    $script:TempDir = Join-Path $env:TEMP "ManagePrivilegeAutomationTests_$(Get-Random)"
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    # ── Dot-source Manage-Privilege.ps1 with no params (entry point skipped via InvocationName
    # guard). $script:AutomationMode is set $false by this initial call - individual Describes
    # below set it $true directly where automation-mode behavior is under test.
    $script:DriverPath = Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'Manage-Privilege.ps1'
    . $script:DriverPath

    $script:DefaultProfileDir = $script:TempDir
    $script:ProfileDir        = $script:TempDir
}

AfterAll {
    if ($script:TempDir -and (Test-Path $script:TempDir)) {
        Remove-Item -Recurse -Force $script:TempDir -ErrorAction SilentlyContinue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Automation mode parameter validation' {

    # Each It re-dot-sources the driver with its own bound parameters (needed to exercise the
    # top-of-script validation, which runs before any function is even defined) and restores a
    # clean, no-params state afterward so later Describes are unaffected.
    AfterEach {
        . $script:DriverPath
        $script:ProfileDir = $script:TempDir
    }

    It 'AM01 - Category without Action throws' {
        { . $script:DriverPath -StartProfile 'X' -Category 'Safes' } | Should -Throw '*Category and -Action must be supplied together*'
    }

    It 'AM02 - Action without Category throws' {
        { . $script:DriverPath -StartProfile 'X' -Action 'List' } | Should -Throw '*Category and -Action must be supplied together*'
    }

    It 'AM03 - Category/Action without StartProfile throws' {
        { . $script:DriverPath -Category 'Safes' -Action 'List' } | Should -Throw '*require -StartProfile*'
    }

    It 'AM04 - InputFile and InputJson together throws' {
        { . $script:DriverPath -StartProfile 'X' -Category 'Safes' -Action 'List' -InputFile 'a.csv' -InputJson '{}' } |
            Should -Throw '*mutually exclusive*'
    }

    It 'AM05 - AutoConnect without StartProfile throws' {
        { . $script:DriverPath -AutoConnect } | Should -Throw '*AutoConnect requires -StartProfile*'
    }

    It 'AM06 - a valid Category/Action/StartProfile combination does not throw and sets AutomationMode' {
        { . $script:DriverPath -StartProfile 'X' -Category 'Safes' -Action 'List' } | Should -Not -Throw
        $script:AutomationMode | Should -Be $true
    }

    It 'AM07 - StartProfile alone (no Category/Action) does not throw and leaves AutomationMode false' {
        { . $script:DriverPath -StartProfile 'X' } | Should -Not -Throw
        $script:AutomationMode | Should -Be $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Invoke-CsvProcessing -FilePaths (automation route)' {

    BeforeAll {
        function global:Invoke-AutomationTestRun {
            param($Token, $InputData, [switch]$WhatIf)
            if ($InputData.SafeName -eq 'BadSafe') {
                return [PSCustomObject]@{
                    ItemsProcessed = 1; Successes = 0; Failures = 1; IsFatal = $false
                    Results = @(); Errors = @([PSCustomObject]@{ ErrorMessage = 'Simulated failure' })
                }
            }
            if ($InputData.SafeName -eq 'FatalSafe') {
                return [PSCustomObject]@{
                    ItemsProcessed = 1; Successes = 0; Failures = 1; IsFatal = $true
                    Results = @(); Errors = @([PSCustomObject]@{ ErrorMessage = '401 Unauthorized' })
                }
            }
            return [PSCustomObject]@{
                ItemsProcessed = 1; Successes = 1; Failures = 0; IsFatal = $false
                Results = @([PSCustomObject]@{ Summary = 'OK' }); Errors = @()
            }
        }

        $script:AutomationEntry = [PSCustomObject]@{
            Meta = [PSCustomObject]@{
                Category = 'AutomationTest'; Action = 'Run'; Name = 'Automation Test Run'
                InputSchema = @(); AcceptsInputFile = $true; ProducesOutput = $false
            }
        }
    }

    BeforeEach {
        $script:AutomationMode = $true
        $script:WhatIfMode     = $false
        $script:ActiveProfile  = New-BlankProfile -Name 'CsvAutomationTest'
        $script:SessionToken   = [PSCustomObject]@{
            SystemType = 'SelfHosted'; AuthMethod = 'CyberArk'
            Expiry     = (Get-Date).ToUniversalTime().AddMinutes(60)
        }
    }

    AfterEach {
        $script:AutomationMode = $false
    }

    It 'AM08 - a mixed-outcome CSV reports correct OK/fail totals, not fatal' {
        $csvPath = Join-Path $script:TempDir 'mixed.csv'
        @(
            [PSCustomObject]@{ SafeName = 'GoodSafe' }
            [PSCustomObject]@{ SafeName = 'BadSafe' }
        ) | Export-Csv -LiteralPath $csvPath -NoTypeInformation

        $summary = Invoke-CsvProcessing -ModuleEntry $script:AutomationEntry -FilePaths @($csvPath)

        $summary.TotalProcessed | Should -Be 2
        $summary.TotalOk        | Should -Be 1
        $summary.TotalFail      | Should -Be 1
        $summary.AnyFatal       | Should -Be $false
    }

    It 'AM09 - a fatal row aborts the batch and is reported as AnyFatal' {
        $csvPath = Join-Path $script:TempDir 'fatal.csv'
        @(
            [PSCustomObject]@{ SafeName = 'GoodSafe' }
            [PSCustomObject]@{ SafeName = 'FatalSafe' }
            [PSCustomObject]@{ SafeName = 'GoodSafe' }
        ) | Export-Csv -LiteralPath $csvPath -NoTypeInformation

        $summary = Invoke-CsvProcessing -ModuleEntry $script:AutomationEntry -FilePaths @($csvPath)

        # Loop breaks on the fatal row - the third (never-reached) row is not counted either way.
        $summary.TotalProcessed | Should -Be 2
        $summary.AnyFatal       | Should -Be $true
    }

    It 'AM10 - does not pause on Read-Host when AutomationMode is set' {
        Mock Read-Host { throw 'Read-Host must not be called in automation mode.' }

        $csvPath = Join-Path $script:TempDir 'nopause.csv'
        @([PSCustomObject]@{ SafeName = 'GoodSafe' }) | Export-Csv -LiteralPath $csvPath -NoTypeInformation

        { Invoke-CsvProcessing -ModuleEntry $script:AutomationEntry -FilePaths @($csvPath) } | Should -Not -Throw
        Should -Invoke Read-Host -Times 0 -Scope It
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Invoke-ProfileConnect automation-mode fresh-auth guard' {

    BeforeEach {
        $script:AutomationMode = $true

        $script:TestProfile = New-BlankProfile -Name 'AutoGuardTest'
        $script:TestProfile.SystemType = 'SelfHosted'
        $script:TestProfile.AuthMethod = 'CyberArk'
        $script:TestProfile.BaseURL    = 'https://pvwa.test.com'

        # Ensure no leftover token file from a previous It in this Describe.
        $tokenPath = Get-ProfileTokenPath -Name $script:TestProfile.AuthTokenProfile
        if (Test-Path -LiteralPath $tokenPath) { Remove-Item -LiteralPath $tokenPath -Force }

        # Baseline mocks so "Should -Invoke ... -Times 0" below has a mock to assert against -
        # Pester requires a command to have been Mock'd in the current scope before it can assert
        # a call count on it, even a count of zero.
        Mock Get-SelfHostedAuthToken { $null }
        Mock Get-ISPSSAuthToken      { $null }
    }

    AfterEach {
        $script:AutomationMode = $false
    }

    It 'AM11 - no saved token file: returns null without calling fresh-auth functions' {
        $summary = [PSCustomObject]@{ currentProfile = $script:TestProfile; TokenStatus = 'No Token' }

        $result = Invoke-ProfileConnect -Summary $summary -Breadcrumbs @('Test') -NoPause

        $result | Should -BeNullOrEmpty
        Should -Invoke Get-SelfHostedAuthToken -Times 0 -Scope It
        Should -Invoke Get-ISPSSAuthToken      -Times 0 -Scope It
    }

    It 'AM12 - unreadable saved token: returns null without calling fresh-auth functions' {
        # TokenStatus = 'Unreadable' skips the Valid/Expired branches entirely regardless of
        # whether a .cred file physically exists, so $token never gets populated either way.
        $tokenPath = Get-ProfileTokenPath -Name $script:TestProfile.AuthTokenProfile
        Set-Content -LiteralPath $tokenPath -Value 'not a real token file'

        $summary = [PSCustomObject]@{ currentProfile = $script:TestProfile; TokenStatus = 'Unreadable' }

        $result = Invoke-ProfileConnect -Summary $summary -Breadcrumbs @('Test') -NoPause

        $result | Should -BeNullOrEmpty
        Should -Invoke Get-SelfHostedAuthToken -Times 0 -Scope It
        Should -Invoke Get-ISPSSAuthToken      -Times 0 -Scope It
    }

    It 'AM13 - expired token whose silent refresh throws: returns null without calling fresh-auth functions' {
        $tokenPath = Get-ProfileTokenPath -Name $script:TestProfile.AuthTokenProfile
        Set-Content -LiteralPath $tokenPath -Value 'placeholder'

        Mock Import-AuthToken {
            [PSCustomObject]@{ SystemType = 'SelfHosted'; AuthMethod = 'CyberArk'; Token = 'expired-token' }
        }
        Mock Update-SelfHostedAuthToken { throw 'Refresh endpoint unreachable' }

        $summary = [PSCustomObject]@{ currentProfile = $script:TestProfile; TokenStatus = 'Expired' }

        $result = Invoke-ProfileConnect -Summary $summary -Breadcrumbs @('Test') -NoPause

        $result | Should -BeNullOrEmpty
        Should -Invoke Get-SelfHostedAuthToken -Times 0 -Scope It
        Should -Invoke Get-ISPSSAuthToken      -Times 0 -Scope It
    }

    It 'AM14 - server rejects saved token with 401: returns null without calling fresh-auth functions' {
        $tokenPath = Get-ProfileTokenPath -Name $script:TestProfile.AuthTokenProfile
        Set-Content -LiteralPath $tokenPath -Value 'placeholder'

        Mock Import-AuthToken {
            [PSCustomObject]@{ SystemType = 'SelfHosted'; AuthMethod = 'CyberArk'; Token = 'stale-token' }
        }
        Mock Invoke-TokenValidate {
            [PSCustomObject]@{ IsSuccess = $false; StatusCode = 401 }
        }

        $summary = [PSCustomObject]@{ currentProfile = $script:TestProfile; TokenStatus = 'Valid' }

        $result = Invoke-ProfileConnect -Summary $summary -Breadcrumbs @('Test') -NoPause

        $result | Should -BeNullOrEmpty
        Should -Invoke Get-SelfHostedAuthToken -Times 0 -Scope It
        Should -Invoke Get-ISPSSAuthToken      -Times 0 -Scope It
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Invoke-TokenRefresh automation-mode branch' {

    BeforeEach {
        $script:AutomationMode = $true
        $script:ActiveProfile  = New-BlankProfile -Name 'RefreshTest'
        # Expiry in the past forces Test-TokenExpiry to report 'Expired', so Invoke-TokenRefresh
        # falls through past its early "already valid" return into the branch under test.
        $script:SessionToken = [PSCustomObject]@{
            SystemType = 'SelfHosted'; AuthMethod = 'CyberArk'; Token = 'old-token'
            Expiry     = (Get-Date).ToUniversalTime().AddMinutes(-5)
        }
    }

    AfterEach {
        $script:AutomationMode = $false
    }

    It 'AM15 - a silently-refreshable method refreshes without prompting and returns true' {
        Mock Read-Host { throw 'Read-Host must not be called in automation mode.' }
        Mock Update-SelfHostedAuthToken {
            [PSCustomObject]@{ SystemType = 'SelfHosted'; AuthMethod = 'CyberArk'; Token = 'new-token'; Expiry = (Get-Date).ToUniversalTime().AddHours(1) }
        }

        $result = Invoke-TokenRefresh

        $result | Should -Be $true
        Should -Invoke Read-Host -Times 0 -Scope It
        Should -Invoke Update-SelfHostedAuthToken -Times 1 -Scope It
    }

    It 'AM16 - a never-silent SelfHosted method (SAML) returns false without prompting or refreshing' {
        $script:SessionToken.AuthMethod = 'SAML'
        Mock Read-Host { throw 'Read-Host must not be called in automation mode.' }
        Mock Update-SelfHostedAuthToken { }

        $result = Invoke-TokenRefresh

        $result | Should -Be $false
        Should -Invoke Read-Host -Times 0 -Scope It
        Should -Invoke Update-SelfHostedAuthToken -Times 0 -Scope It
    }

    It 'AM17 - a never-silent ISPSS method (Interactive) returns false without prompting or refreshing' {
        $script:SessionToken.SystemType = 'ISPSS'
        $script:SessionToken.AuthMethod = 'Interactive'
        Mock Read-Host { throw 'Read-Host must not be called in automation mode.' }
        Mock Update-ISPSSAuthToken { }

        $result = Invoke-TokenRefresh

        $result | Should -Be $false
        Should -Invoke Read-Host -Times 0 -Scope It
        Should -Invoke Update-ISPSSAuthToken -Times 0 -Scope It
    }

    It 'AM18 - a silent refresh that throws returns false without prompting' {
        Mock Read-Host { throw 'Read-Host must not be called in automation mode.' }
        Mock Update-SelfHostedAuthToken { throw 'Refresh endpoint unreachable' }

        $result = Invoke-TokenRefresh

        $result | Should -Be $false
        Should -Invoke Read-Host -Times 0 -Scope It
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Get-AutomationExitCode' {

    It 'AM19 - a CSV summary with AnyFatal returns 3' {
        Get-AutomationExitCode -Summary ([PSCustomObject]@{ AnyFatal = $true; TotalFail = 0 }) | Should -Be 3
    }

    It 'AM20 - a CSV summary with failures but not fatal returns 2' {
        Get-AutomationExitCode -Summary ([PSCustomObject]@{ AnyFatal = $false; TotalFail = 2 }) | Should -Be 2
    }

    It 'AM21 - a clean CSV summary returns 0' {
        Get-AutomationExitCode -Summary ([PSCustomObject]@{ AnyFatal = $false; TotalFail = 0 }) | Should -Be 0
    }

    It 'AM22 - a fatal module result returns 3' {
        Get-AutomationExitCode -Result ([PSCustomObject]@{ IsFatal = $true; Failures = 0 }) | Should -Be 3
    }

    It 'AM23 - a module result with failures but not fatal returns 2' {
        Get-AutomationExitCode -Result ([PSCustomObject]@{ IsFatal = $false; Failures = 3 }) | Should -Be 2
    }

    It 'AM24 - a clean module result returns 0' {
        Get-AutomationExitCode -Result ([PSCustomObject]@{ IsFatal = $false; Failures = 0 }) | Should -Be 0
    }
}
