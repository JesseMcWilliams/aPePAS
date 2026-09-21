#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Platforms\Invoke-PlatformsRename.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-PlatformsRenameInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Platforms\Invoke-PlatformsRename.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'PlatformsRenameTests' -MinLevel 'ERROR'

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
    It 'PRN01 - Name = Rename Platform' {
        $ModuleMeta.Name | Should -Be 'Rename Platform'
    }
    It 'PRN02 - SupportsWhatIf = $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }
    It 'PRN03 - SupportedSystems is SelfHosted only (confirmed via psPAS -SelfHosted assertion)' {
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
        $ModuleMeta.SupportedSystems.Count | Should -Be 1
    }
}

Describe 'Invoke-PlatformsRename - success' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PRN04 - resolves PlatformID to numeric ID and PUTs to /API/Platforms/targets/{id} with Name body' {
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
        $r = Invoke-PlatformsRename -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal'; Name = 'NewName' }
        $r.Successes | Should -Be 1
        $capturedCalls[1].Method   | Should -Be 'PUT'
        $capturedCalls[1].Endpoint | Should -Be '/API/Platforms/targets/42'
        $capturedCalls[1].Body['Name'] | Should -Be 'NewName'
        $r.Results[0].NewName | Should -Be 'NewName'
    }

    It 'PRN10 - resolves numeric ID when /API/Platforms/Targets wraps results under a Platforms property (real live shape)' {
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
        $r = Invoke-PlatformsRename -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal'; Name = 'NewName' }
        $r.Successes | Should -Be 1
        $capturedCalls[1].Endpoint | Should -Be '/API/Platforms/targets/42'
    }
}

Describe 'Invoke-PlatformsRename - validation and lookup failures' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PRN05 - empty PlatformID - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PlatformsRename -Token $script:MockToken -InputData @{ Name = 'NewName' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PRN06 - empty Name - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PlatformsRename -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PRN07 - platform not found among search results - Failures=1' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate -PlatformID 'OtherPlatform' -ID 99) }
            } else {
                throw 'Should not be called - platform not found'
            }
        }
        $r = Invoke-PlatformsRename -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal'; Name = 'NewName' }
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
    }
}

Describe 'Invoke-PlatformsRename - WhatIf' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PRN08 - WhatIf resolves the numeric ID (GET) but does not call PUT' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = @(script:New-TargetPlatformCandidate) }
            } else {
                throw 'Should not PUT in WhatIf mode'
            }
        }
        $r = Invoke-PlatformsRename -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal'; Name = 'NewName' } -WhatIf
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }
}
