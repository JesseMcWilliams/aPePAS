#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Policies\Invoke-PoliciesSetMasterPolicy.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-PoliciesSetMasterPolicyInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Policies\Invoke-PoliciesSetMasterPolicy.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'PoliciesSetMasterPolicyTests' -MinLevel 'ERROR'

    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault'
    }

    function script:New-EffectivePolicyResponse {
        [PSCustomObject]@{
            DualControl                   = [PSCustomObject]@{ Value = $true }
            MultiLevelApproval            = [PSCustomObject]@{ Value = $false }
            OnlyManagersApproval          = [PSCustomObject]@{ Value = $false }
            ConfirmersNumber              = [PSCustomObject]@{ Value = 2 }
            EnforceExclusiveAccess        = [PSCustomObject]@{ Value = $true }
            EnforceOneTimePassword        = [PSCustomObject]@{ Value = $false }
            TransparentConnection         = [PSCustomObject]@{ Value = $false }
            AllowViewPassword             = [PSCustomObject]@{ Value = $true }
            RequireReason                 = [PSCustomObject]@{ Value = $true }
            AllowFreeText                 = [PSCustomObject]@{ Value = $false }
            PasswordChangeDays            = [PSCustomObject]@{ Value = 90 }
            PasswordVerificationDays      = [PSCustomObject]@{ Value = 7 }
            RequireMonitoringAndIsolation = [PSCustomObject]@{ Value = $true }
            RecordActivity                = [PSCustomObject]@{ Value = $true }
            RetentionPeriod               = [PSCustomObject]@{ Value = 365 }
        }
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

Describe 'ModuleMeta' {
    It 'PSMP01 - Name = Set Master Policy' {
        $ModuleMeta.Name | Should -Be 'Set Master Policy'
    }
    It 'PSMP02 - SupportsWhatIf = $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }
    It 'PSMP03 - SupportedSystems is SelfHosted only' {
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
        $ModuleMeta.SupportedSystems.Count | Should -Be 1
    }
}

Describe 'Invoke-PoliciesSetMasterPolicy - success (GET-then-merge)' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PSMP04 - changes only the supplied field, carrying every other current value through unchanged' {
        $capturedCalls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $capturedCalls.Add($PSBoundParameters) | Out-Null
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = script:New-EffectivePolicyResponse }
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
            }
        }
        $r = Invoke-PoliciesSetMasterPolicy -Token $script:MockToken -InputData @{ RequireReason = 'false' }
        $r.Successes | Should -Be 1

        $putCall = $capturedCalls | Where-Object { $_.Method -eq 'PUT' } | Select-Object -First 1
        $putCall.Endpoint | Should -Be '/API/Policies/1'
        $putCall.Body['RequireReason']    | Should -Be $false
        # Every other field carried through from the GET response unchanged
        $putCall.Body['DualControl']      | Should -Be $true
        $putCall.Body['ConfirmersNumber'] | Should -Be 2
        $putCall.Body['RetentionPeriod']  | Should -Be 365
    }

    It 'PSMP05 - multiple supplied fields are all changed together' {
        $capturedCalls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $capturedCalls.Add($PSBoundParameters) | Out-Null
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = script:New-EffectivePolicyResponse }
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
            }
        }
        Invoke-PoliciesSetMasterPolicy -Token $script:MockToken -InputData @{ DualControl = 'true'; ConfirmersNumber = '5' }
        $putCall = $capturedCalls | Where-Object { $_.Method -eq 'PUT' } | Select-Object -First 1
        $putCall.Body['DualControl']      | Should -Be $true
        $putCall.Body['ConfirmersNumber'] | Should -Be 5
    }

    It 'PSMP06 - a custom PolicyId is used in both the GET and PUT endpoints' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = script:New-EffectivePolicyResponse }
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
            }
        }
        Invoke-PoliciesSetMasterPolicy -Token $script:MockToken -InputData @{ PolicyId = '2'; DualControl = 'true' }
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'GET' -and $Endpoint -eq '/API/Policies/2' }
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'PUT' -and $Endpoint -eq '/API/Policies/2' }
    }
}

Describe 'Invoke-PoliciesSetMasterPolicy - validation' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PSMP07 - no fields supplied at all - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PoliciesSetMasterPolicy -Token $script:MockToken -InputData @{}
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PSMP08 - non-integer ConfirmersNumber - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PoliciesSetMasterPolicy -Token $script:MockToken -InputData @{ ConfirmersNumber = 'not-a-number' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PSMP09 - ConfirmersNumber out of range (65, max is 64) - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PoliciesSetMasterPolicy -Token $script:MockToken -InputData @{ ConfirmersNumber = '65' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PSMP10 - ConfirmersNumber out of range (0, min is 1) - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PoliciesSetMasterPolicy -Token $script:MockToken -InputData @{ ConfirmersNumber = '0' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PSMP11 - PasswordChangeDays out of range (3651, max is 3650) - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PoliciesSetMasterPolicy -Token $script:MockToken -InputData @{ PasswordChangeDays = '3651' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PSMP12 - RetentionPeriod=0 is accepted (min is 0, unlike the other int fields)' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = script:New-EffectivePolicyResponse }
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
            }
        }
        $r = Invoke-PoliciesSetMasterPolicy -Token $script:MockToken -InputData @{ RetentionPeriod = '0' }
        $r.Failures | Should -Be 0
    }

    It 'PSMP13 - invalid PolicyId - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PoliciesSetMasterPolicy -Token $script:MockToken -InputData @{ PolicyId = 'bad'; DualControl = 'true' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

Describe 'Invoke-PoliciesSetMasterPolicy - API failures' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PSMP14 - GET (fetch current policy) fails - non-fatal failure, no PUT call' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 404; ErrorMessage = 'Not Found'; ErrorDetails = $null; Data = $null }
            } else {
                throw 'Should not PUT when the GET failed'
            }
        }
        $r = Invoke-PoliciesSetMasterPolicy -Token $script:MockToken -InputData @{ DualControl = 'true' }
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
    }

    It 'PSMP15 - PUT fails (401) - IsFatal=$true' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = script:New-EffectivePolicyResponse }
            } else {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 401; ErrorMessage = 'Unauthorized'; ErrorDetails = $null; Data = $null }
            }
        }
        $r = Invoke-PoliciesSetMasterPolicy -Token $script:MockToken -InputData @{ DualControl = 'true' }
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeTrue
    }
}

Describe 'Invoke-PoliciesSetMasterPolicy - WhatIf' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PSMP16 - WhatIf gets the current policy but does not call PUT' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = script:New-EffectivePolicyResponse }
            } else {
                throw 'Should not PUT in WhatIf mode'
            }
        }
        $r = Invoke-PoliciesSetMasterPolicy -Token $script:MockToken -InputData @{ DualControl = 'true' } -WhatIf
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }
}
