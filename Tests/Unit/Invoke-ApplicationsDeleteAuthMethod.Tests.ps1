#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-ApplicationsDeleteAuthMethod.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Applications\Invoke-ApplicationsDeleteAuthMethod.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'ApplicationsDeleteAuthMethodTests' -MinLevel 'ERROR'
}

Describe 'Invoke-ApplicationsDeleteAuthMethod' {

    Context 'ModuleMeta' {
        It 'SupportedSystems includes both SelfHosted and ISPSS' {
            $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
            $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
            $ModuleMeta.SupportedSystems.Count | Should -Be 2
        }
    }

    Context 'Missing required inputs' {
        It 'returns failure when AppID is missing' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-ApplicationsDeleteAuthMethod -Token $token -InputData @{ AuthID = '1' }
            $result.Failures  | Should -Be 1
            $result.Successes | Should -Be 0
        }

        It 'returns failure when AuthID is missing' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-ApplicationsDeleteAuthMethod -Token $token -InputData @{ AppID = 'MyApp' }
            $result.Failures  | Should -Be 1
            $result.Successes | Should -Be 0
        }
    }

    Context 'API call failure' {
        It 'records error on non-success response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 404; ErrorMessage = 'Not Found'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-ApplicationsDeleteAuthMethod -Token $token -InputData @{ AppID = 'MyApp'; AuthID = '99' }
            $result.Failures  | Should -BeGreaterThan 0
            $result.IsFatal   | Should -Be $false
        }
    }

    Context 'Successful deletion' {
        It 'records success and returns Deleted status' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
            }
            Mock Add-CyberArkLogSummaryEntry {}
            $result = Invoke-ApplicationsDeleteAuthMethod -Token $token -InputData @{ AppID = 'MyApp'; AuthID = '1' }
            $result.Successes          | Should -Be 1
            $result.Failures           | Should -Be 0
            $result.Results[0].AppID   | Should -Be 'MyApp'
            $result.Results[0].AuthID  | Should -Be '1'
            $result.Results[0].Status  | Should -Be 'Deleted'
        }
    }

    Context 'WhatIf mode' {
        It 'does not call API when WhatIf is set' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI { throw 'Should not be called in WhatIf mode' }
            Mock Add-CyberArkLogSummaryEntry {}
            { Invoke-ApplicationsDeleteAuthMethod -Token $token -InputData @{ AppID = 'MyApp'; AuthID = '1' } -WhatIf } | Should -Not -Throw
        }
    }

}
