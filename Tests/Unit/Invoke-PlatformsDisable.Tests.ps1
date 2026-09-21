#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Platforms\Invoke-PlatformsDisable.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-PlatformsDisableInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Platforms\Invoke-PlatformsDisable.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'PlatformsDisableTests' -MinLevel 'ERROR'

    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault'
    }

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
    It 'PD01 - Name = Disable Platform' {
        $ModuleMeta.Name | Should -Be 'Disable Platform'
    }
    It 'PD02 - SupportsWhatIf = $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }
}

Describe 'Invoke-PlatformsDisable - success' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PD03 - resolves PlatformID to numeric ID and POSTs to .../deactivate' {
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
        $r = Invoke-PlatformsDisable -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Successes | Should -Be 1
        $capturedCalls[1].Method   | Should -Be 'POST'
        $capturedCalls[1].Endpoint | Should -Be '/API/Platforms/Targets/42/deactivate'
    }

    It 'PD10 - resolves numeric ID when /API/Platforms/Targets wraps results under a Platforms property (real live shape)' {
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
        $r = Invoke-PlatformsDisable -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Successes | Should -Be 1
        $capturedCalls[1].Endpoint | Should -Be '/API/Platforms/Targets/42/deactivate'
    }

    It 'PD04 - result row reflects Active=$false' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate) }
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
            }
        }
        $r = Invoke-PlatformsDisable -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Results[0].Active | Should -BeFalse
    }
}

Describe 'Invoke-PlatformsDisable - validation and lookup failures' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PD05 - empty PlatformID - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PlatformsDisable -Token $script:MockToken -InputData @{ PlatformID = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PD06 - platform not found among search results - Failures=1' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate -PlatformID 'OtherPlatform' -ID 99) }
            } else {
                throw 'Should not be called - platform not found'
            }
        }
        $r = Invoke-PlatformsDisable -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
    }

    It 'PD07 - deactivate call fails (403) - non-fatal failure' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate) }
            } else {
                script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden'
            }
        }
        $r = Invoke-PlatformsDisable -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
    }
}

Describe 'Invoke-PlatformsDisable - WhatIf' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PD08 - WhatIf resolves the numeric ID (GET) but does not call deactivate (POST)' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate) }
            } else {
                throw 'Should not POST in WhatIf mode'
            }
        }
        $r = Invoke-PlatformsDisable -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' } -WhatIf
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'POST' }
    }
}
