#Requires -Version 5.1
<#
.SYNOPSIS
    Runs integration tests against a live CyberArk PVWA instance.

.DESCRIPTION
    Prompts for credentials at runtime - nothing is stored in files.
    Read-only tests (List/Get) always run.
    Write tests (Add/Update/Delete) require explicit -IncludeWrite flag.

    Excluded safe: Z_Template_Safe_Permissions - this safe is NEVER touched.

.PARAMETER Suite
    Which test suite to run. Default: All.
    Values: All, Safes, SafeMembers, Accounts, Platforms, Users

.PARAMETER IncludeWrite
    Include write operations (Add, Update, Delete). Off by default.
    Write tests create and then delete a safe named in Config.psd1:TestSafeName.

.PARAMETER SkipLogoff
    Do not logoff at the end of the test run (useful for chaining test suites).

.EXAMPLE
    # Run all read-only tests
    .\Tests\Integration\Run-IntegrationTests.ps1

.EXAMPLE
    # Run Safes suite including write tests
    .\Tests\Integration\Run-IntegrationTests.ps1 -Suite Safes -IncludeWrite

.EXAMPLE
    # Run all suites including writes
    .\Tests\Integration\Run-IntegrationTests.ps1 -IncludeWrite
#>
[CmdletBinding()]
param(
    [ValidateSet('All','Safes','SafeMembers','Accounts','Platforms','Users')]
    [string]$Suite        = 'All',

    [switch]$IncludeWrite,
    [switch]$SkipLogoff
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot

#region --- Banner ---
Write-Host ''
Write-Host ('=' * 70) -ForegroundColor Cyan
Write-Host '  aPePAS - CyberArk Integration Tests' -ForegroundColor White
Write-Host "  Suite: $Suite  |  Write tests: $(if ($IncludeWrite) { 'YES' } else { 'NO (read-only)' })" -ForegroundColor DarkGray
Write-Host '  Excluded safe (never touched): Z_Template_Safe_Permissions' -ForegroundColor Yellow
Write-Host ('=' * 70) -ForegroundColor Cyan
Write-Host ''
#endregion

#region --- Load helper ---
$helperPath = Join-Path $scriptDir 'IntegrationTestHelper.ps1'
if (-not (Test-Path $helperPath)) {
    Write-Host "  IntegrationTestHelper.ps1 not found at: $helperPath" -ForegroundColor Red
    exit 1
}
. $helperPath
#endregion

#region --- Connect ---
$config = Get-IntegrationConfig
Write-Host "  PVWA: $($config.PVWABaseURL)" -ForegroundColor DarkGray
Write-Host "  Auth: $($config.AuthMethod)  User: $($config.Username)" -ForegroundColor DarkGray
Write-Host ''

$token = $null
try {
    $token = Get-IntegrationToken -Config $config
    Write-Host '  Connected successfully.' -ForegroundColor Green
    Write-Host ''
} catch {
    Write-Host "  Connection failed: $_" -ForegroundColor Red
    exit 1
}
#endregion

#region --- Suite dispatch ---

$suites = @()
switch ($Suite) {
    'All'         { $suites = @('Safes','SafeMembers','Accounts','Platforms','Users') }
    default       { $suites = @($Suite) }
}

$totalPass = 0
$totalFail = 0
$allErrors  = [System.Collections.Generic.List[string]]::new()

foreach ($suiteName in $suites) {
    $suitePath = Join-Path $scriptDir "Test-$suiteName.ps1"

    if (-not (Test-Path $suitePath)) {
        Write-Host "  [SKIP] $suiteName - test file not found: $suitePath" -ForegroundColor Yellow
        continue
    }

    Write-Host ('─' * 70) -ForegroundColor DarkGray
    Write-Host "  Running: $suiteName" -ForegroundColor White
    Write-Host ''

    # Each suite script exposes $script:PassCount, $script:FailCount, $script:Errors
    # by dot-sourcing into this scope via a child script block.
    $suiteResult = & {
        $script:SuiteToken      = $token
        $script:SuiteConfig     = $config
        $script:SuiteSkipWrite  = -not $IncludeWrite.IsPresent

        # Dot-source the suite
        . $suitePath -Token $token -Config $config -SkipWrite:(-not $IncludeWrite.IsPresent)

        [PSCustomObject]@{
            PassCount = if (Test-Path Variable:script:PassCount) { $script:PassCount } else { 0 }
            FailCount = if (Test-Path Variable:script:FailCount) { $script:FailCount } else { 0 }
            Errors    = if (Test-Path Variable:script:Errors)    { $script:Errors    } else { @() }
        }
    }

    $totalPass += $suiteResult.PassCount
    $totalFail += $suiteResult.FailCount
    foreach ($e in $suiteResult.Errors) { $allErrors.Add("[$suiteName] $e") }

    Write-Host ''
    $color = if ($suiteResult.FailCount -eq 0) { 'Green' } else { 'Red' }
    Write-Host "  $suiteName: $($suiteResult.PassCount) passed, $($suiteResult.FailCount) failed" -ForegroundColor $color
    Write-Host ''
}

#endregion

#region --- Logoff ---
if (-not $SkipLogoff) {
    try {
        Invoke-LogoffIfToken -Config $config -Token $token
        Write-Host '  Session logged off.' -ForegroundColor DarkGray
    } catch {
        Write-Host "  Logoff error (non-fatal): $_" -ForegroundColor DarkGray
    }
}
#endregion

#region --- Final summary ---
Write-Host ''
Write-Host ('=' * 70) -ForegroundColor Cyan
Write-Host '  Integration Test Results' -ForegroundColor White
Write-Host ('=' * 70) -ForegroundColor Cyan
Write-Host ("  Passed : {0}" -f $totalPass) -ForegroundColor Green
Write-Host ("  Failed : {0}" -f $totalFail) -ForegroundColor $(if ($totalFail -gt 0) { 'Red' } else { 'Green' })
Write-Host ''

if ($allErrors.Count -gt 0) {
    Write-Host '  Failed tests:' -ForegroundColor Red
    foreach ($e in $allErrors) {
        Write-Host "    $e" -ForegroundColor Yellow
    }
    Write-Host ''
}

if ($totalFail -gt 0) {
    Write-Host '  Some tests FAILED.' -ForegroundColor Red
    exit 1
}

Write-Host '  All tests passed.' -ForegroundColor Green
Write-Host ''
exit 0
#endregion
