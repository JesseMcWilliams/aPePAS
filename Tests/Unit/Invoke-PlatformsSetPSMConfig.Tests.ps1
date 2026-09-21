#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Platforms\Invoke-PlatformsSetPSMConfig.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-PlatformsSetPSMConfigInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Platforms\Invoke-PlatformsSetPSMConfig.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'PlatformsSetPSMConfigTests' -MinLevel 'ERROR'

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

    function script:New-PSMConfigResponse {
        param([string]$PSMServerId = 'PSMServer_old', [array]$Connectors = @([PSCustomObject]@{ PSMConnectorID = 'PSM-RDP'; Enabled = $true }))
        [PSCustomObject]@{ PSMServerId = $PSMServerId; PSMServerName = 'Old PSM'; PSMConnectors = $Connectors }
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
    It 'PPSM01 - Name = Set Platform PSM Config' {
        $ModuleMeta.Name | Should -Be 'Set Platform PSM Config'
    }
    It 'PPSM02 - SupportsWhatIf = $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }
}

Describe 'Invoke-PlatformsSetPSMConfig - success' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PPSM03 - resolves numeric ID, GETs current config, PUTs new PSMServerId preserving existing PSMConnectors' {
        $capturedCalls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $capturedCalls.Add($PSBoundParameters) | Out-Null
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Platforms/Targets') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate) }
            } elseif ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = script:New-PSMConfigResponse }
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
            }
        }
        $r = Invoke-PlatformsSetPSMConfig -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal'; PSMServerID = 'PSMServer_new' }
        $r.Successes | Should -Be 1

        $putCall = $capturedCalls | Where-Object { $_.Method -eq 'PUT' } | Select-Object -First 1
        $putCall.Endpoint | Should -Be '/API/Platforms/Targets/42/PrivilegedSessionManagement'
        $putCall.Body['PSMServerId'] | Should -Be 'PSMServer_new'
        $putCall.Body['PSMConnectors'][0].PSMConnectorID | Should -Be 'PSM-RDP'
    }

    It 'PPSM10 - resolves numeric ID when /API/Platforms/Targets wraps results under a Platforms property (real live shape)' {
        $capturedCalls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $capturedCalls.Add($PSBoundParameters) | Out-Null
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Platforms/Targets') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ Platforms = @(script:New-TargetPlatformCandidate); Total = 1 } }
            } elseif ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = script:New-PSMConfigResponse }
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
            }
        }
        $r = Invoke-PlatformsSetPSMConfig -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal'; PSMServerID = 'PSMServer_new' }
        $r.Successes | Should -Be 1
        $putCall = $capturedCalls | Where-Object { $_.Method -eq 'PUT' } | Select-Object -First 1
        $putCall.Endpoint | Should -Be '/API/Platforms/Targets/42/PrivilegedSessionManagement'
    }
}

Describe 'Invoke-PlatformsSetPSMConfig - validation and lookup failures' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PPSM04 - empty PlatformID - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PlatformsSetPSMConfig -Token $script:MockToken -InputData @{ PSMServerID = 'PSMServer_new' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PPSM05 - empty PSMServerID - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PlatformsSetPSMConfig -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PPSM06 - platform not found among search results - Failures=1' {
        Mock Invoke-CyberArkAPI {
            param($Method, $Endpoint)
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Platforms/Targets') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate -PlatformID 'OtherPlatform' -ID 99) }
            } else {
                throw 'Should not be called - platform not found'
            }
        }
        $r = Invoke-PlatformsSetPSMConfig -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal'; PSMServerID = 'PSMServer_new' }
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
    }

    It 'PPSM07 - fetching current PSM config fails - non-fatal failure, no PUT call' {
        Mock Invoke-CyberArkAPI {
            param($Method, $Endpoint)
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Platforms/Targets') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate) }
            } elseif ($Method -eq 'GET') {
                script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found'
            } else {
                throw 'Should not PUT when the config GET failed'
            }
        }
        $r = Invoke-PlatformsSetPSMConfig -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal'; PSMServerID = 'PSMServer_new' }
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
    }
}

Describe 'Invoke-PlatformsSetPSMConfig - WhatIf' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PPSM08 - WhatIf resolves ID and GETs current config but does not PUT' {
        Mock Invoke-CyberArkAPI {
            param($Method, $Endpoint)
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Platforms/Targets') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate) }
            } elseif ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = script:New-PSMConfigResponse }
            } else {
                throw 'Should not PUT in WhatIf mode'
            }
        }
        $r = Invoke-PlatformsSetPSMConfig -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal'; PSMServerID = 'PSMServer_new' } -WhatIf
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }
}
