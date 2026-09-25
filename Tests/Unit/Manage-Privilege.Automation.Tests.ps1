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
        param($AuthMethod, $PVWAUrl, $Credential, $Certificate, [switch]$ConcurrentSession, [switch]$IgnoreSSL,
              $Username, $WebView2AssemblyPath)
        return $null
    }
    function global:Get-ISPSSAuthToken {
        param($AuthMethod, $Subdomain, $ClientId, $ClientSecret, [switch]$IgnoreSSL,
              $Username, $PCloudSubdomain, $IdentityTenantURL, $WebView2AssemblyPath,
              $AuthTokenProfileName, $ProfileDir)
        return $null
    }
    function global:Update-SelfHostedAuthToken { param($TokenObject, [switch]$NoPrompt) return $null }
    function global:Update-ISPSSAuthToken      { param($TokenObject, [switch]$NoPrompt) return $null }
    function global:Get-ISPSSAuthThrottle      { param($AuthTokenProfileName, $ProfileDir) return 0 }
    function global:Set-ISPSSAuthThrottle      { param($AuthTokenProfileName, $ProfileDir, $WaitSeconds) }

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

    It 'AM17 - a never-silent ISPSS method (SSO) returns false without prompting or refreshing' {
        $script:SessionToken.SystemType = 'ISPSS'
        $script:SessionToken.AuthMethod = 'SSO'
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

    It 'AM69 - ISPSS Interactive (K12) refreshes silently via -NoPrompt and returns true' {
        $script:SessionToken.SystemType = 'ISPSS'
        $script:SessionToken.AuthMethod = 'Interactive'
        Mock Read-Host { throw 'Read-Host must not be called in automation mode.' }
        Mock Update-ISPSSAuthToken {
            [PSCustomObject]@{ SystemType = 'ISPSS'; AuthMethod = 'Interactive'; Token = 'new-token'; Expiry = (Get-Date).ToUniversalTime().AddHours(1) }
        } -ParameterFilter { $NoPrompt -eq $true }

        $result = Invoke-TokenRefresh

        $result | Should -Be $true
        Should -Invoke Read-Host -Times 0 -Scope It
        Should -Invoke Update-ISPSSAuthToken -Times 1 -Scope It -ParameterFilter { $NoPrompt -eq $true }
    }

    It 'AM70 - ISPSS Interactive (K12) with no usable stored credential fails cleanly, not by prompting' {
        $script:SessionToken.SystemType = 'ISPSS'
        $script:SessionToken.AuthMethod = 'Interactive'
        Mock Read-Host { throw 'Read-Host must not be called in automation mode.' }
        Mock Update-ISPSSAuthToken { throw 'Automation mode: mechanism requires interactive input.' }

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

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Format-AutomationFilename' {

    BeforeEach {
        $script:ActiveProfile = $null
    }

    It 'AM25 - expands every placeholder' {
        $script:ActiveProfile = [PSCustomObject]@{ ProfileName = 'Prod' }
        $name = Format-AutomationFilename -Format '{Profile}_{Category}_{Action}_{ModuleName}_{Date}' `
            -ModuleName 'Export Entitlements' -Category 'Custom' -Action 'ExportEntitlements'
        $today = Get-Date -Format 'yyyy-MM-dd'
        $name | Should -Be "Prod_Custom_ExportEntitlements_Export Entitlements_$today.csv"
    }

    It 'AM26 - {Profile} is blank when there is no active profile' {
        $name = Format-AutomationFilename -Format '{Profile}Export' -ModuleName 'X' -Category 'C' -Action 'A'
        $name | Should -Be 'Export.csv'
    }

    It 'AM27 - a .csv extension is not duplicated when already present' {
        $name = Format-AutomationFilename -Format '{ModuleName}.csv' -ModuleName 'Report' -Category 'C' -Action 'A'
        $name | Should -Be 'Report.csv'
    }

    It 'AM28 - a .csv extension is appended when absent' {
        $name = Format-AutomationFilename -Format '{ModuleName}' -ModuleName 'Report' -Category 'C' -Action 'A'
        $name | Should -Be 'Report.csv'
    }

    It 'AM29 - a literal format with no placeholders is used as-is (plus extension)' {
        $name = Format-AutomationFilename -Format 'FixedName' -ModuleName 'Ignored' -Category 'C' -Action 'A'
        $name | Should -Be 'FixedName.csv'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Get-CsvSavePath -FolderOverride/-FileNameOverride' {

    BeforeEach {
        $script:OverrideDir = Join-Path $script:TempDir "CsvOverride_$(Get-Random)"
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:OverrideDir) {
            Remove-Item -LiteralPath $script:OverrideDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'AM30 - FolderOverride creates a missing folder and saves there' {
        Test-Path -LiteralPath $script:OverrideDir | Should -Be $false

        $path = Get-CsvSavePath -DefaultFolder 'SomewhereElse' -ModuleName 'Report' -AutoSave -FolderOverride $script:OverrideDir

        Test-Path -LiteralPath $script:OverrideDir -PathType Container | Should -Be $true
        (Split-Path -Path $path -Parent) | Should -Be $script:OverrideDir
    }

    It 'AM31 - FileNameOverride is used verbatim (plus extension) instead of the module-name/date default' {
        New-Item -ItemType Directory -Path $script:OverrideDir -Force | Out-Null

        $path = Get-CsvSavePath -DefaultFolder $script:OverrideDir -ModuleName 'Report' -AutoSave -FileNameOverride 'CustomName'

        (Split-Path -Path $path -Leaf) | Should -Be 'CustomName.csv'
    }

    It 'AM32 - FolderOverride takes precedence over DefaultFolder' {
        $path = Get-CsvSavePath -DefaultFolder $script:TempDir -ModuleName 'Report' -AutoSave -FolderOverride $script:OverrideDir
        (Split-Path -Path $path -Parent) | Should -Be $script:OverrideDir
    }

    It 'AM33 - with no overrides, behavior is unchanged from before this feature' {
        $path = Get-CsvSavePath -DefaultFolder $script:TempDir -ModuleName 'Report' -AutoSave
        (Split-Path -Path $path -Parent) | Should -Be $script:TempDir
        (Split-Path -Path $path -Leaf)   | Should -Match '^Report \d{4}-\d{2}-\d{2}\.csv$'
    }

    It 'AM37 - NoDateSuffix produces a plain "ModuleName.csv" with no date' {
        $path = Get-CsvSavePath -DefaultFolder $script:TempDir -ModuleName 'Report' -AutoSave -NoDateSuffix
        (Split-Path -Path $path -Leaf) | Should -Be 'Report.csv'
    }

    It 'AM38 - FileNameOverride still takes precedence over NoDateSuffix' {
        $path = Get-CsvSavePath -DefaultFolder $script:TempDir -ModuleName 'Report' -AutoSave -NoDateSuffix -FileNameOverride 'Explicit'
        (Split-Path -Path $path -Leaf) | Should -Be 'Explicit.csv'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Save-ModuleResultCsv -OutputFolder/-FilenameFormat overrides' {

    BeforeAll {
        # Meta must be a hashtable, not a PSCustomObject - Save-ModuleResultCsv reads optional
        # keys like AutoSaveCsv/CsvFilenameField via bracket notation ($meta['Key']), which
        # PSCustomObject does not support (throws "Unable to index into..."), matching every
        # module's real $ModuleMeta = @{...} hashtable declaration.
        $script:SaveCsvEntry = [PSCustomObject]@{
            Meta = @{
                Name = 'Export Entitlements'; Category = 'Custom'; Action = 'ExportEntitlements'
                ProducesOutput = $true
            }
        }
        $script:NoDateEntry = [PSCustomObject]@{
            Meta = @{
                Name = 'Export Entitlements'; Category = 'Custom'; Action = 'ExportEntitlements'
                ProducesOutput = $true; CsvFilenameNoDate = $true
            }
        }
        $script:SaveCsvResult = [PSCustomObject]@{
            Results = @([PSCustomObject]@{ Name = 'Row1' })
        }
    }

    BeforeEach {
        $script:OverrideDir   = Join-Path $script:TempDir "SaveCsvOverride_$(Get-Random)"
        $script:ActiveProfile = [PSCustomObject]@{ ProfileName = 'AutomationProfile'; OutputFolder = $script:TempDir }
        # Explicitly (re-)establish both as real script-scope variables before every It, even
        # when a given test only cares about one of them - the outer BeforeAll's initial
        # no-args dot-source bound $OutputFolder/$FilenameFormat inside ITS OWN scope, not this
        # file's actual script-scope container, so a bare reference to either wouldn't otherwise
        # exist there yet the first time an It sets only the other one.
        $script:OutputFolder   = $null
        $script:FilenameFormat = $null
    }

    AfterEach {
        $script:AutomationMode = $false
        $script:OutputFolder   = $null
        $script:FilenameFormat = $null
        if (Test-Path -LiteralPath $script:OverrideDir) {
            Remove-Item -LiteralPath $script:OverrideDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'AM34 - in automation mode, -OutputFolder redirects the saved CSV away from the profile folder' {
        $script:AutomationMode = $true
        $script:OutputFolder   = $script:OverrideDir

        Save-ModuleResultCsv -ModuleEntry $script:SaveCsvEntry -Result $script:SaveCsvResult -InputData @{}

        $saved = @(Get-ChildItem -LiteralPath $script:OverrideDir -Filter '*.csv')
        $saved.Count | Should -Be 1
    }

    It 'AM35 - in automation mode, -FilenameFormat controls the saved filename' {
        $script:AutomationMode = $true
        $script:FilenameFormat = '{Profile}-{ModuleName}'

        Save-ModuleResultCsv -ModuleEntry $script:SaveCsvEntry -Result $script:SaveCsvResult -InputData @{}

        $expected = Join-Path $script:TempDir 'AutomationProfile-Export Entitlements.csv'
        Test-Path -LiteralPath $expected | Should -Be $true
    }

    It 'AM36 - -OutputFolder/-FilenameFormat are ignored outside automation mode' {
        $script:AutomationMode = $false
        $script:OutputFolder   = $script:OverrideDir
        $script:FilenameFormat = 'ShouldNotBeUsed'
        # AutoSaveCsv isn't declared on this test module, so outside automation mode
        # Save-ModuleResultCsv asks interactively - decline, so nothing is saved either way.
        Mock Read-MenuChoice { 'N' }

        Save-ModuleResultCsv -ModuleEntry $script:SaveCsvEntry -Result $script:SaveCsvResult -InputData @{}

        Test-Path -LiteralPath $script:OverrideDir | Should -Be $false
        @(Get-ChildItem -LiteralPath $script:TempDir -Filter 'ShouldNotBeUsed*.csv').Count | Should -Be 0
    }

    It 'AM39 - ModuleMeta.CsvFilenameNoDate saves a plain "Module Name.csv" with no date' {
        $script:AutomationMode = $true

        Save-ModuleResultCsv -ModuleEntry $script:NoDateEntry -Result $script:SaveCsvResult -InputData @{}

        $expected = Join-Path $script:TempDir 'Export Entitlements.csv'
        Test-Path -LiteralPath $expected | Should -Be $true
    }

    It 'AM40 - -FilenameFormat still takes precedence over ModuleMeta.CsvFilenameNoDate' {
        $script:AutomationMode = $true
        $script:FilenameFormat = '{ModuleName}_{Date}'

        Save-ModuleResultCsv -ModuleEntry $script:NoDateEntry -Result $script:SaveCsvResult -InputData @{}

        $today    = Get-Date -Format 'yyyy-MM-dd'
        $expected = Join-Path $script:TempDir "Export Entitlements_$today.csv"
        Test-Path -LiteralPath $expected | Should -Be $true
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Save-ProfileCredential / Get-ProfileCredential / Remove-ProfileCredential' {

    AfterEach {
        Remove-ProfileCredential -Name 'CredTestProfile' -ProfileDir $script:TempDir
    }

    It 'AM41 - Get-ProfileCredential returns null when nothing is stored' {
        Get-ProfileCredential -Name 'CredTestProfile' -ProfileDir $script:TempDir | Should -BeNullOrEmpty
    }

    It 'AM42 - Save-ProfileCredential then Get-ProfileCredential round-trips the username and password' {
        $cred = [System.Management.Automation.PSCredential]::new('svc-account', (ConvertTo-SecureString 'p@ssw0rd!' -AsPlainText -Force))
        Save-ProfileCredential -Name 'CredTestProfile' -Credential $cred -ProfileDir $script:TempDir | Out-Null

        $loaded = Get-ProfileCredential -Name 'CredTestProfile' -ProfileDir $script:TempDir

        $loaded.UserName                             | Should -Be 'svc-account'
        $loaded.GetNetworkCredential().Password       | Should -Be 'p@ssw0rd!'
    }

    It 'AM43 - Get-ProfileCredential returns null (not a throw) for a file that cannot be deserialized' {
        $path = Get-ProfileCredentialPath -Name 'CredTestProfile' -ProfileDir $script:TempDir
        Set-Content -LiteralPath $path -Value 'not a real Clixml credential file'

        { Get-ProfileCredential -Name 'CredTestProfile' -ProfileDir $script:TempDir } | Should -Not -Throw
        Get-ProfileCredential -Name 'CredTestProfile' -ProfileDir $script:TempDir | Should -BeNullOrEmpty
    }

    It 'AM44 - Remove-ProfileCredential deletes the file' {
        $cred = [System.Management.Automation.PSCredential]::new('svc-account', (ConvertTo-SecureString 'pw' -AsPlainText -Force))
        Save-ProfileCredential -Name 'CredTestProfile' -Credential $cred -ProfileDir $script:TempDir | Out-Null

        Remove-ProfileCredential -Name 'CredTestProfile' -ProfileDir $script:TempDir

        Test-Path -LiteralPath (Get-ProfileCredentialPath -Name 'CredTestProfile' -ProfileDir $script:TempDir) | Should -Be $false
    }

    It 'AM45 - Remove-ProfileCredential on a profile with none stored does not throw' {
        { Remove-ProfileCredential -Name 'CredTestProfile' -ProfileDir $script:TempDir } | Should -Not -Throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Use-StoredCredentialIfMissing' {

    AfterEach {
        Remove-ProfileCredential -Name 'UseCredTestProfile' -ProfileDir $script:TempDir
    }

    It 'AM46 - injects the stored credential when the token has none' {
        $stored = [System.Management.Automation.PSCredential]::new('svc-account', (ConvertTo-SecureString 'pw' -AsPlainText -Force))
        Save-ProfileCredential -Name 'UseCredTestProfile' -Credential $stored -ProfileDir $script:TempDir | Out-Null

        $token = [PSCustomObject]@{
            SystemType = 'SelfHosted'; AuthMethod = 'CyberArk'
            _RefreshContext = @{ Method = 'CyberArk'; Credential = $null }
        }

        Use-StoredCredentialIfMissing -Token $token -AuthTokenProfileName 'UseCredTestProfile'

        $token._RefreshContext['Credential'].UserName | Should -Be 'svc-account'
    }

    It 'AM47 - does not overwrite a credential the token already has' {
        Save-ProfileCredential -Name 'UseCredTestProfile' -Credential ([System.Management.Automation.PSCredential]::new('stored-user', (ConvertTo-SecureString 'pw' -AsPlainText -Force))) -ProfileDir $script:TempDir | Out-Null
        $existing = [System.Management.Automation.PSCredential]::new('already-present-user', (ConvertTo-SecureString 'pw' -AsPlainText -Force))

        $token = [PSCustomObject]@{
            SystemType = 'SelfHosted'; AuthMethod = 'CyberArk'
            _RefreshContext = @{ Method = 'CyberArk'; Credential = $existing }
        }

        Use-StoredCredentialIfMissing -Token $token -AuthTokenProfileName 'UseCredTestProfile'

        $token._RefreshContext['Credential'].UserName | Should -Be 'already-present-user'
    }

    It 'AM48 - is a no-op for ISPSS ClientCredentials (never uses a Credential)' {
        Save-ProfileCredential -Name 'UseCredTestProfile' -Credential ([System.Management.Automation.PSCredential]::new('svc-account', (ConvertTo-SecureString 'pw' -AsPlainText -Force))) -ProfileDir $script:TempDir | Out-Null

        $token = [PSCustomObject]@{
            SystemType = 'ISPSS'; AuthMethod = 'ClientCredentials'
            _RefreshContext = @{ Method = 'ClientCredentials' }
        }

        { Use-StoredCredentialIfMissing -Token $token -AuthTokenProfileName 'UseCredTestProfile' } | Should -Not -Throw
        $token._RefreshContext.ContainsKey('Credential') | Should -Be $false
    }

    It 'AM49 - is a no-op for SelfHosted methods that do not use a Credential (e.g. Shared)' {
        Save-ProfileCredential -Name 'UseCredTestProfile' -Credential ([System.Management.Automation.PSCredential]::new('svc-account', (ConvertTo-SecureString 'pw' -AsPlainText -Force))) -ProfileDir $script:TempDir | Out-Null

        $token = [PSCustomObject]@{
            SystemType = 'SelfHosted'; AuthMethod = 'Shared'
            _RefreshContext = @{ Method = 'Shared' }
        }

        Use-StoredCredentialIfMissing -Token $token -AuthTokenProfileName 'UseCredTestProfile'

        $token._RefreshContext.ContainsKey('Credential') | Should -Be $false
    }

    It 'AM50 - leaves the credential null when nothing is stored either' {
        $token = [PSCustomObject]@{
            SystemType = 'SelfHosted'; AuthMethod = 'CyberArk'
            _RefreshContext = @{ Method = 'CyberArk'; Credential = $null }
        }

        Use-StoredCredentialIfMissing -Token $token -AuthTokenProfileName 'UseCredTestProfile'

        $token._RefreshContext['Credential'] | Should -BeNullOrEmpty
    }

    It 'AM71 - injects the stored credential for ISPSS Interactive tokens (K12)' {
        $stored = [System.Management.Automation.PSCredential]::new('svc-account', (ConvertTo-SecureString 'pw' -AsPlainText -Force))
        Save-ProfileCredential -Name 'UseCredTestProfile' -Credential $stored -ProfileDir $script:TempDir | Out-Null

        $token = [PSCustomObject]@{
            SystemType = 'ISPSS'; AuthMethod = 'Interactive'
            _RefreshContext = @{ Method = 'Interactive'; Credential = $null }
        }

        Use-StoredCredentialIfMissing -Token $token -AuthTokenProfileName 'UseCredTestProfile'

        $token._RefreshContext['Credential'].UserName | Should -Be 'svc-account'
    }

    It 'AM72 - is a no-op for ISPSS SSO (never uses a Credential)' {
        Save-ProfileCredential -Name 'UseCredTestProfile' -Credential ([System.Management.Automation.PSCredential]::new('svc-account', (ConvertTo-SecureString 'pw' -AsPlainText -Force))) -ProfileDir $script:TempDir | Out-Null

        $token = [PSCustomObject]@{
            SystemType = 'ISPSS'; AuthMethod = 'SSO'
            _RefreshContext = @{ Method = 'SSO' }
        }

        { Use-StoredCredentialIfMissing -Token $token -AuthTokenProfileName 'UseCredTestProfile' } | Should -Not -Throw
        $token._RefreshContext.ContainsKey('Credential') | Should -Be $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Invoke-ClearNonRefreshableContext (Testing_Findings-and-Known-Issues.md K12)' {

    It 'AM73 - retains Credential for ISPSS Interactive (K12 - it can now silently refresh from it)' {
        $token = [PSCustomObject]@{
            AuthMethod = 'Interactive'
            _RefreshContext = @{ Method = 'Interactive'; Credential = ([System.Management.Automation.PSCredential]::new('user', (ConvertTo-SecureString 'pw' -AsPlainText -Force))) }
        }

        Invoke-ClearNonRefreshableContext -Token $token

        $token._RefreshContext.ContainsKey('Credential') | Should -Be $true
    }

    It 'AM74 - still strips Credential for ISPSS SSO' {
        $token = [PSCustomObject]@{
            AuthMethod = 'SSO'
            _RefreshContext = @{ Method = 'SSO'; Credential = ([System.Management.Automation.PSCredential]::new('user', (ConvertTo-SecureString 'pw' -AsPlainText -Force))) }
        }

        Invoke-ClearNonRefreshableContext -Token $token

        $token._RefreshContext.ContainsKey('Credential') | Should -Be $false
    }

    It 'AM75 - still strips Credential/ClientSecret for SelfHosted SAML and OIDC' {
        foreach ($method in @('SAML', 'OIDC')) {
            $token = [PSCustomObject]@{
                AuthMethod = $method
                _RefreshContext = @{ Method = $method; Credential = ([System.Management.Automation.PSCredential]::new('user', (ConvertTo-SecureString 'pw' -AsPlainText -Force))); ClientSecret = 'secret' }
            }

            Invoke-ClearNonRefreshableContext -Token $token

            $token._RefreshContext.ContainsKey('Credential')   | Should -Be $false
            $token._RefreshContext.ContainsKey('ClientSecret') | Should -Be $false
        }
    }

    It 'AM76 - does not touch Credential for SelfHosted CyberArk (never was in the strip list)' {
        $token = [PSCustomObject]@{
            AuthMethod = 'CyberArk'
            _RefreshContext = @{ Method = 'CyberArk'; Credential = ([System.Management.Automation.PSCredential]::new('user', (ConvertTo-SecureString 'pw' -AsPlainText -Force))) }
        }

        Invoke-ClearNonRefreshableContext -Token $token

        $token._RefreshContext.ContainsKey('Credential') | Should -Be $true
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Get-ExpectedTokenBaseURL / Test-TokenBaseURLStale (Testing_Findings-and-Known-Issues.md K04)' {

    It 'AM52 - Self-Hosted: appends the profile AppName to the profile BaseURL' {
        $driverProfile = New-BlankProfile -Name 'X'
        $driverProfile.SystemType = 'Self-Hosted'; $driverProfile.BaseURL = 'https://pvwa.test.com'; $driverProfile.AppName = 'PasswordVault'
        Get-ExpectedTokenBaseURL -DriverProfile $driverProfile | Should -Be 'https://pvwa.test.com/PasswordVault'
    }

    It 'AM53 - Self-Hosted: defaults AppName to PasswordVault when unset' {
        $driverProfile = New-BlankProfile -Name 'X'
        $driverProfile.SystemType = 'Self-Hosted'; $driverProfile.BaseURL = 'https://pvwa.test.com'; $driverProfile.AppName = ''
        Get-ExpectedTokenBaseURL -DriverProfile $driverProfile | Should -Be 'https://pvwa.test.com/PasswordVault'
    }

    It 'AM54 - ISPSS: builds the hardcoded /PasswordVault template from the subdomain, ignoring AppName' {
        $driverProfile = New-BlankProfile -Name 'X'
        $driverProfile.SystemType = 'Privilege Cloud'; $driverProfile.BaseURL = 'https://acme.privilegecloud.cyberark.cloud'
        $driverProfile.AppName = 'SomethingElse'
        Get-ExpectedTokenBaseURL -DriverProfile $driverProfile | Should -Be 'https://acme.privilegecloud.cyberark.cloud/PasswordVault'
    }

    It 'AM55 - ISPSS: returns null when BaseURL does not match the standard privilegecloud shape' {
        $driverProfile = New-BlankProfile -Name 'X'
        $driverProfile.SystemType = 'Privilege Cloud'; $driverProfile.BaseURL = 'https://something-else.example.com'
        Get-ExpectedTokenBaseURL -DriverProfile $driverProfile | Should -BeNullOrEmpty
    }

    It 'AM56 - returns null when the profile has no BaseURL at all' {
        $driverProfile = New-BlankProfile -Name 'X'
        Get-ExpectedTokenBaseURL -DriverProfile $driverProfile | Should -BeNullOrEmpty
    }

    It 'AM57 - Test-TokenBaseURLStale is false when the token matches the profile' {
        $driverProfile = New-BlankProfile -Name 'X'
        $driverProfile.SystemType = 'Self-Hosted'; $driverProfile.BaseURL = 'https://pvwa.test.com'; $driverProfile.AppName = 'PasswordVault'
        $token = [PSCustomObject]@{ BaseURL = 'https://pvwa.test.com/PasswordVault' }
        Test-TokenBaseURLStale -Token $token -DriverProfile $driverProfile | Should -Be $false
    }

    It 'AM58 - Test-TokenBaseURLStale ignores a trailing-slash-only difference' {
        $driverProfile = New-BlankProfile -Name 'X'
        $driverProfile.SystemType = 'Self-Hosted'; $driverProfile.BaseURL = 'https://pvwa.test.com'; $driverProfile.AppName = 'PasswordVault'
        $token = [PSCustomObject]@{ BaseURL = 'https://pvwa.test.com/PasswordVault/' }
        Test-TokenBaseURLStale -Token $token -DriverProfile $driverProfile | Should -Be $false
    }

    It 'AM59 - Test-TokenBaseURLStale ignores a case-only difference' {
        $driverProfile = New-BlankProfile -Name 'X'
        $driverProfile.SystemType = 'Self-Hosted'; $driverProfile.BaseURL = 'https://pvwa.test.com'; $driverProfile.AppName = 'PasswordVault'
        $token = [PSCustomObject]@{ BaseURL = 'HTTPS://PVWA.TEST.COM/PasswordVault' }
        Test-TokenBaseURLStale -Token $token -DriverProfile $driverProfile | Should -Be $false
    }

    It 'AM60 - Test-TokenBaseURLStale is true when the profile Base URL has genuinely changed' {
        $driverProfile = New-BlankProfile -Name 'X'
        $driverProfile.SystemType = 'Self-Hosted'; $driverProfile.BaseURL = 'https://new-pvwa.test.com'; $driverProfile.AppName = 'PasswordVault'
        $token = [PSCustomObject]@{ BaseURL = 'https://old-pvwa.test.com/PasswordVault' }
        Test-TokenBaseURLStale -Token $token -DriverProfile $driverProfile | Should -Be $true
    }

    It 'AM61 - Test-TokenBaseURLStale never reports a false positive when the expected URL cannot be computed' {
        $driverProfile = New-BlankProfile -Name 'X'
        $driverProfile.SystemType = 'Privilege Cloud'; $driverProfile.BaseURL = 'https://something-else.example.com'
        $token = [PSCustomObject]@{ BaseURL = 'https://whatever.example.com' }
        Test-TokenBaseURLStale -Token $token -DriverProfile $driverProfile | Should -Be $false
    }

    It 'AM62 - Test-TokenBaseURLStale is false when the token has no BaseURL at all' {
        $driverProfile = New-BlankProfile -Name 'X'
        $driverProfile.SystemType = 'Self-Hosted'; $driverProfile.BaseURL = 'https://pvwa.test.com'
        $token = [PSCustomObject]@{ BaseURL = '' }
        Test-TokenBaseURLStale -Token $token -DriverProfile $driverProfile | Should -Be $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Invoke-ProfileConnect discards a stale-BaseURL token (Testing_Findings-and-Known-Issues.md K04)' {

    BeforeEach {
        $script:AutomationMode = $true
        $script:TestProfileK04 = New-BlankProfile -Name 'K04GuardTest'
        $script:TestProfileK04.SystemType = 'Self-Hosted'
        $script:TestProfileK04.AuthMethod = 'CyberArk'
        $script:TestProfileK04.BaseURL    = 'https://new-pvwa.test.com'

        $tokenPath = Get-ProfileTokenPath -Name $script:TestProfileK04.AuthTokenProfile
        if (Test-Path -LiteralPath $tokenPath) { Remove-Item -LiteralPath $tokenPath -Force }
        Set-Content -LiteralPath $tokenPath -Value 'placeholder'

        Mock Import-AuthToken {
            [PSCustomObject]@{ SystemType = 'SelfHosted'; AuthMethod = 'CyberArk'; Token = 'stale-token'; BaseURL = 'https://old-pvwa.test.com/PasswordVault' }
        }
        Mock Get-SelfHostedAuthToken { $null }
        Mock Get-ISPSSAuthToken      { $null }
    }

    AfterEach {
        $script:AutomationMode = $false
    }

    It 'AM63 - a Valid token whose BaseURL no longer matches the profile is discarded, not trusted' {
        $summary = [PSCustomObject]@{ currentProfile = $script:TestProfileK04; TokenStatus = 'Valid' }

        $result = Invoke-ProfileConnect -Summary $summary -Breadcrumbs @('Test') -NoPause

        $result | Should -BeNullOrEmpty
        Should -Invoke Get-SelfHostedAuthToken -Times 0 -Scope It
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Invoke-TokenRefresh SelfHosted Username fallback (Testing_Findings-and-Known-Issues.md K07)' {

    BeforeEach {
        $script:AutomationMode = $false
        $script:ActiveProfile  = New-BlankProfile -Name 'K07Test'
        $script:ActiveProfile.Username = 'profile-user'
        $script:ActiveProfile.BaseURL  = 'https://pvwa.test.com'
        $script:ActiveProfile.AppName  = 'PasswordVault'
        $script:SessionToken = [PSCustomObject]@{
            SystemType = 'SelfHosted'; AuthMethod = 'CyberArk'; Token = 'old-token'
            Expiry     = (Get-Date).ToUniversalTime().AddMinutes(-5)
            _RefreshContext = @{ Method = 'CyberArk'; PVWAUrl = 'https://pvwa.test.com/PasswordVault' }
        }
    }

    AfterEach {
        $script:AutomationMode = $false
    }

    It 'AM64 - falls back to the profile Username when _RefreshContext has no Credential, without an extra prompt' {
        Mock Read-Host {
            if ($AsSecureString) { return (ConvertTo-SecureString 'pw123!' -AsPlainText -Force) }
            return ''
        }
        Mock Get-SelfHostedAuthToken { [PSCustomObject]@{ Token = 'new-token'; BaseURL = 'https://pvwa.test.com/PasswordVault' } }
        Mock Save-AuthToken { }

        $result = Invoke-TokenRefresh

        $result | Should -Be $true
        Should -Invoke Get-SelfHostedAuthToken -Times 1 -Scope It -ParameterFilter {
            $Credential.UserName -eq 'profile-user'
        }
        Should -Invoke Read-Host -Times 0 -Scope It -ParameterFilter { $Prompt -eq '  Username' }
    }

    It 'AM65 - a Credential already present in _RefreshContext still takes precedence over the profile Username' {
        $script:SessionToken._RefreshContext['Credential'] =
            [System.Management.Automation.PSCredential]::new('context-user', (ConvertTo-SecureString 'pw' -AsPlainText -Force))

        Mock Read-Host {
            if ($AsSecureString) { return (ConvertTo-SecureString 'pw123!' -AsPlainText -Force) }
            return ''
        }
        Mock Get-SelfHostedAuthToken { [PSCustomObject]@{ Token = 'new-token'; BaseURL = 'https://pvwa.test.com/PasswordVault' } }
        Mock Save-AuthToken { }

        Invoke-TokenRefresh | Out-Null

        Should -Invoke Get-SelfHostedAuthToken -Times 1 -Scope It -ParameterFilter {
            $Credential.UserName -eq 'context-user'
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Invoke-ProfileConnect forwards WebView2AssemblyPath (Testing_Findings-and-Known-Issues.md K11)' {
    <#
        Import-WebView2Assembly's own error message tells a user to "specify
        -WebView2AssemblyPath", but that parameter was never reachable through the driver at all
        - no profile field or launch parameter exposed it. These confirm the new profile field
        actually reaches Get-SelfHostedAuthToken/Get-ISPSSAuthToken's fresh-auth call (where
        Auth\CyberArk.Auth.Common.psm1 already threads it the rest of the way to
        Invoke-WebView2Window - see Testing_Findings-and-Known-Issues.md K03/F58).
    #>

    BeforeEach {
        $script:AutomationMode = $false
        $script:TestProfileK11 = New-BlankProfile -Name 'K11Test'
        $script:TestProfileK11.SystemType = 'Self-Hosted'
        $script:TestProfileK11.AuthMethod = 'SAML'
        $script:TestProfileK11.BaseURL    = 'https://pvwa.test.com'
        $script:TestProfileK11.WebView2AssemblyPath = 'C:\Custom\WebView2.dll'

        $tokenPath = Get-ProfileTokenPath -Name $script:TestProfileK11.AuthTokenProfile
        if (Test-Path -LiteralPath $tokenPath) { Remove-Item -LiteralPath $tokenPath -Force }

        Mock Show-Header { }
        Mock Get-SelfHostedAuthToken { [PSCustomObject]@{ Token = 'fake-token'; SystemType = 'SelfHosted'; AuthMethod = 'SAML'; _RefreshContext = @{} } }
        Mock Get-ISPSSAuthToken      { [PSCustomObject]@{ Token = 'fake-token'; SystemType = 'ISPSS'; AuthMethod = 'SSO'; IdentityURL = ''; _RefreshContext = @{} } }
    }

    AfterEach {
        $script:AutomationMode = $false
    }

    It 'AM66 - Self-Hosted: forwards the profile WebView2AssemblyPath to Get-SelfHostedAuthToken' {
        $summary = [PSCustomObject]@{ currentProfile = $script:TestProfileK11; TokenStatus = 'No Token' }

        Invoke-ProfileConnect -Summary $summary -Breadcrumbs @('Test') -NoPause | Out-Null

        Should -Invoke Get-SelfHostedAuthToken -Times 1 -Scope It -ParameterFilter {
            $WebView2AssemblyPath -eq 'C:\Custom\WebView2.dll'
        }
    }

    It 'AM67 - ISPSS: forwards the profile WebView2AssemblyPath to Get-ISPSSAuthToken' {
        $script:TestProfileK11.SystemType = 'Privilege Cloud'
        $script:TestProfileK11.AuthMethod = 'SSO'
        $script:TestProfileK11.BaseURL    = 'https://acme.privilegecloud.cyberark.cloud'
        $summary = [PSCustomObject]@{ currentProfile = $script:TestProfileK11; TokenStatus = 'No Token' }

        Invoke-ProfileConnect -Summary $summary -Breadcrumbs @('Test') -NoPause | Out-Null

        Should -Invoke Get-ISPSSAuthToken -Times 1 -Scope It -ParameterFilter {
            $WebView2AssemblyPath -eq 'C:\Custom\WebView2.dll'
        }
    }

    It 'AM68 - is omitted from authParams entirely when not set on the profile' {
        $script:TestProfileK11.WebView2AssemblyPath = ''
        $summary = [PSCustomObject]@{ currentProfile = $script:TestProfileK11; TokenStatus = 'No Token' }

        Invoke-ProfileConnect -Summary $summary -Breadcrumbs @('Test') -NoPause | Out-Null

        Should -Invoke Get-SelfHostedAuthToken -Times 1 -Scope It -ParameterFilter {
            -not $WebView2AssemblyPath
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Invoke-AutomatedAction does not log off the session (Testing_Findings-and-Known-Issues.md K15)' {
    <#
        Invoke-AutomatedAction itself is not otherwise unit-tested (module resolution/dispatch
        complexity - see Testing Boundaries), so this is a lightweight structural regression guard
        rather than an end-to-end mock, confirmed live instead (K15/F65): POST /API/auth/Logoff
        genuinely revokes the session server-side, so a previous fix that called
        Invoke-SessionLogoff unconditionally at the end of every automation-mode run meant a
        SECOND automation-mode invocation against the same profile always failed with a 401 -
        defeating the entire point of the saved/refreshable session K06/K12 built for exactly this
        multi-run scenario. Live-verified 2026-09-21: 3 consecutive real automation-mode runs
        against a real Self-Hosted PVWA, reusing the same saved session with no re-authentication
        between them, all succeeded after this fix.
    #>
    It 'AM77 - the function body never calls Invoke-SessionLogoff' {
        # Strip comment lines first - the function's own explanatory comment mentions
        # Invoke-SessionLogoff by name (explaining why it's deliberately NOT called), which would
        # otherwise false-positive a naive text match.
        $codeLines = (Get-Command Invoke-AutomatedAction).ScriptBlock.ToString() -split "`n" |
            Where-Object { $_.Trim() -notmatch '^#' }
        ($codeLines -join "`n") | Should -Not -Match 'Invoke-SessionLogoff'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - ISPSS authentication throttle (Testing_Findings-and-Known-Issues.md K17)' {
    <#
        Confirmed live: repeated CyberArk Identity authentication attempts within its own
        RetryWaitingTime window (a field on StartAuthentication's response) can trip a soft
        lockout, which then rejects even a correct password. These confirm the driver forwards
        the profile identity needed to record/honor that hint, waits it out before a fresh login a
        human is actively waiting on, and skips (rather than attempts) a refresh that's already
        known to be throttled.
    #>

    BeforeEach {
        $script:AutomationMode = $false
        $script:TestProfileK17 = New-BlankProfile -Name 'K17Test'
        $script:TestProfileK17.SystemType = 'Privilege Cloud'
        $script:TestProfileK17.AuthMethod = 'Interactive'
        $script:TestProfileK17.BaseURL    = 'https://acme.privilegecloud.cyberark.cloud'

        $tokenPath = Get-ProfileTokenPath -Name $script:TestProfileK17.AuthTokenProfile
        if (Test-Path -LiteralPath $tokenPath) { Remove-Item -LiteralPath $tokenPath -Force }

        Mock Show-Header { }
        Mock Get-ISPSSAuthToken { [PSCustomObject]@{ Token = 'fake-token'; SystemType = 'ISPSS'; AuthMethod = 'Interactive'; IdentityURL = ''; _RefreshContext = @{} } }
        Mock Start-Sleep { }
    }

    AfterEach {
        $script:AutomationMode = $false
    }

    It 'AM78 - a fresh ISPSS login forwards the profile AuthTokenProfileName/ProfileDir to Get-ISPSSAuthToken' {
        Mock Get-ISPSSAuthThrottle { 0 }
        $summary = [PSCustomObject]@{ currentProfile = $script:TestProfileK17; TokenStatus = 'No Token' }

        Invoke-ProfileConnect -Summary $summary -Breadcrumbs @('Test') -NoPause | Out-Null

        Should -Invoke Get-ISPSSAuthToken -Times 1 -Scope It -ParameterFilter {
            $AuthTokenProfileName -eq $script:TestProfileK17.AuthTokenProfile -and $ProfileDir -eq $script:ProfileDir
        }
    }

    It 'AM79 - a fresh ISPSS login waits out an active throttle before authenticating (a human is actively waiting)' {
        Mock Get-ISPSSAuthThrottle { 12 }
        $summary = [PSCustomObject]@{ currentProfile = $script:TestProfileK17; TokenStatus = 'No Token' }

        Invoke-ProfileConnect -Summary $summary -Breadcrumbs @('Test') -NoPause | Out-Null

        Should -Invoke Start-Sleep -Times 1 -Scope It -ParameterFilter { $Seconds -eq 12 }
        Should -Invoke Get-ISPSSAuthToken -Times 1 -Scope It
    }

    It 'AM80 - a fresh ISPSS login does not wait when no throttle is active' {
        Mock Get-ISPSSAuthThrottle { 0 }
        $summary = [PSCustomObject]@{ currentProfile = $script:TestProfileK17; TokenStatus = 'No Token' }

        Invoke-ProfileConnect -Summary $summary -Breadcrumbs @('Test') -NoPause | Out-Null

        Should -Invoke Start-Sleep -Times 0 -Scope It
    }

    It 'AM81 - Invoke-TokenRefresh (automation mode) skips a throttled ISPSS refresh instead of attempting it' {
        $script:AutomationMode = $true
        $script:ActiveProfile  = $script:TestProfileK17
        $script:SessionToken   = [PSCustomObject]@{
            SystemType = 'ISPSS'; AuthMethod = 'Interactive'; Token = 'old-token'
            Expiry     = (Get-Date).ToUniversalTime().AddMinutes(-5)
            _RefreshContext = @{ Method = 'Interactive' }
        }
        Mock Get-ISPSSAuthThrottle { 8 }
        Mock Update-ISPSSAuthToken { [PSCustomObject]@{ Token = 'should-not-be-used' } }

        $result = Invoke-TokenRefresh

        $result | Should -Be $false
        Should -Invoke Update-ISPSSAuthToken -Times 0 -Scope It
    }
}
