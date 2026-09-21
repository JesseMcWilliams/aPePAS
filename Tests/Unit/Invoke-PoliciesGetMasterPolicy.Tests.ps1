#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Policies\Invoke-PoliciesGetMasterPolicy.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-PoliciesGetMasterPolicyInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Policies\Invoke-PoliciesGetMasterPolicy.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'PoliciesGetMasterPolicyTests' -MinLevel 'ERROR'

    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault'
    }

    # Matches the EffectivePolicy schema in the CyberArk 14.6 self-hosted Swagger spec - every
    # field wrapped as { Value: ... }.
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
    It 'PGMP01 - Name = Get Master Policy' {
        $ModuleMeta.Name | Should -Be 'Get Master Policy'
    }
    It 'PGMP02 - SupportedSystems is dual-use (ISPSS support attempted but unconfirmed)' {
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
        $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
        $ModuleMeta.SupportedSystems.Count | Should -Be 2
    }
    It 'PGMP08 - IncludeInExportAll is true so Export All picks it up despite its non-List action' {
        $ModuleMeta.IncludeInExportAll | Should -BeTrue
    }
}

Describe 'Invoke-PoliciesGetMasterPolicy - success' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'PGMP03 - GETs /API/Policies/1 by default and flattens every field to its Value' {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = script:New-EffectivePolicyResponse }
        }
        $r = Invoke-PoliciesGetMasterPolicy -Token $script:MockToken -InputData @{}
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Endpoint -eq '/API/Policies/1' }
        $r.Successes | Should -Be 1
        $r.Results[0].DualControl        | Should -BeTrue
        $r.Results[0].ConfirmersNumber   | Should -Be 2
        $r.Results[0].PasswordChangeDays | Should -Be 90
        $r.Results[0].RetentionPeriod    | Should -Be 365
    }

    It 'PGMP04 - a custom PolicyId is used in the endpoint' {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = script:New-EffectivePolicyResponse }
        }
        Invoke-PoliciesGetMasterPolicy -Token $script:MockToken -InputData @{ PolicyId = '3' }
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Endpoint -eq '/API/Policies/3' }
    }

    It 'PGMP05 - a missing field in the response does not throw under Set-StrictMode' {
        Set-StrictMode -Version Latest
        try {
            $sparsePolicy = [PSCustomObject]@{ DualControl = [PSCustomObject]@{ Value = $true } }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $sparsePolicy }
            }
            $r = Invoke-PoliciesGetMasterPolicy -Token $script:MockToken -InputData @{}
            $r.Results[0].DualControl         | Should -BeTrue
            $r.Results[0].MultiLevelApproval  | Should -BeNullOrEmpty
        } finally {
            Set-StrictMode -Off
        }
    }
}

Describe 'Invoke-PoliciesGetMasterPolicy - validation and API failures' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'PGMP06 - invalid PolicyId - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PoliciesGetMasterPolicy -Token $script:MockToken -InputData @{ PolicyId = 'not-a-number' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PGMP07 - API failure (401) - IsFatal=$true' {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{ IsSuccess = $false; StatusCode = 401; ErrorMessage = 'Unauthorized'; ErrorDetails = $null; Data = $null }
        }
        $r = Invoke-PoliciesGetMasterPolicy -Token $script:MockToken -InputData @{}
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeTrue
    }

    It 'PGMP09 - a 404 (confirmed live: ISPSS/Privilege Cloud has no Master Policy endpoint) is a non-fatal Failure' {
        $ispssToken = $script:MockToken.PSObject.Copy()
        $ispssToken.SystemType = 'ISPSS'
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{ IsSuccess = $false; StatusCode = 404; ErrorMessage = 'Not Found'; ErrorDetails = $null; Data = $null }
        }
        $r = Invoke-PoliciesGetMasterPolicy -Token $ispssToken -InputData @{}
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
    }
}
