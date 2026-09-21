#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Platforms\Invoke-PlatformsEnable.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-PlatformsEnableInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Platforms\Invoke-PlatformsEnable.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'PlatformsEnableTests' -MinLevel 'ERROR'

    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault'
    }

    # A /API/Platforms/Targets search-response candidate matching the CyberArk 14.6
    # self-hosted Swagger's TargetPlatform schema (bare array, ID + PlatformID both present).
    function script:New-TargetPlatformCandidate {
        param([string]$PlatformID = 'WinServerLocal', [int]$ID = 42)
        [PSCustomObject]@{ ID = $ID; PlatformID = $PlatformID; Name = $PlatformID; Active = $true }
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
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

Describe 'ModuleMeta' {
    It 'PE01 - Name = Enable Platform' {
        $ModuleMeta.Name | Should -Be 'Enable Platform'
    }
    It 'PE02 - SupportsWhatIf = $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }
    It 'PE03 - SupportedSystems includes both SelfHosted and ISPSS' {
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
        $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
    }
}

Describe 'Invoke-PlatformsEnable - success' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PE04 - resolves PlatformID to numeric ID and POSTs to .../activate' {
        $capturedCalls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $capturedCalls.Add($PSBoundParameters) | Out-Null
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate) }
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
            }
        }
        $r = Invoke-PlatformsEnable -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Successes | Should -Be 1
        $r.Failures  | Should -Be 0
        $capturedCalls[1].Method   | Should -Be 'POST'
        $capturedCalls[1].Endpoint | Should -Be '/API/Platforms/Targets/42/activate'
    }

    It 'PE10 - resolves numeric ID when /API/Platforms/Targets wraps results under a Platforms property (real live shape)' {
        $capturedCalls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $capturedCalls.Add($PSBoundParameters) | Out-Null
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ Platforms = @(script:New-TargetPlatformCandidate); Total = 1 } }
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
            }
        }
        $r = Invoke-PlatformsEnable -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Successes | Should -Be 1
        $capturedCalls[1].Endpoint | Should -Be '/API/Platforms/Targets/42/activate'
    }

    It 'PE05 - result row reflects Active=$true' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate) }
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
            }
        }
        $r = Invoke-PlatformsEnable -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Results[0].Active | Should -BeTrue
        $r.Results[0].ID     | Should -Be 42
    }
}

Describe 'Invoke-PlatformsEnable - validation and lookup failures' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PE06 - empty PlatformID - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PlatformsEnable -Token $script:MockToken -InputData @{ PlatformID = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PE07 - platform not found among search results - Failures=1, no activate call' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate -PlatformID 'OtherPlatform' -ID 99) }
            } else {
                throw 'Should not be called - platform not found'
            }
        }
        $r = Invoke-PlatformsEnable -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
    }

    It 'PE08 - lookup API call fails (401) - IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-PlatformsEnable -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeTrue
    }

    It 'PE09 - activate call fails (403) - non-fatal failure' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate) }
            } else {
                script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden'
            }
        }
        $r = Invoke-PlatformsEnable -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
    }
}

Describe 'Invoke-PlatformsEnable - WhatIf' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PE10 - WhatIf resolves the numeric ID (GET) but does not call activate (POST)' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate) }
            } else {
                throw 'Should not POST in WhatIf mode'
            }
        }
        $r = Invoke-PlatformsEnable -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' } -WhatIf
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'GET' }
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'POST' }
    }
}
