#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-ApplicationsDelete.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Applications\Invoke-ApplicationsDelete.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'ApplicationsDeleteTests' -MinLevel 'ERROR'
}

Describe 'Invoke-ApplicationsDelete' {

    Context 'ModuleMeta' {
        It 'SupportedSystems includes both SelfHosted and ISPSS' {
            $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
            $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
            $ModuleMeta.SupportedSystems.Count | Should -Be 2
        }
    }

    Context 'Missing AppID' {
        It 'returns failure when AppID is not provided' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-ApplicationsDelete -Token $token -InputData @{}
            $result.Failures  | Should -Be 1
            $result.Successes | Should -Be 0
            $result.IsFatal   | Should -Be $false
        }
    }

    Context 'API call failure' {
        It 'records error on non-success response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 404; ErrorMessage = 'Not Found'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-ApplicationsDelete -Token $token -InputData @{ AppID = 'OldApp' }
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
            $result = Invoke-ApplicationsDelete -Token $token -InputData @{ AppID = 'OldApp' }
            $result.Successes          | Should -Be 1
            $result.Failures           | Should -Be 0
            $result.Results[0].AppID   | Should -Be 'OldApp'
            $result.Results[0].Status  | Should -Be 'Deleted'
        }
    }

    Context 'WhatIf mode' {
        It 'does not call API when WhatIf is set' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI { throw 'Should not be called in WhatIf mode' }
            Mock Add-CyberArkLogSummaryEntry {}
            { Invoke-ApplicationsDelete -Token $token -InputData @{ AppID = 'WhatIfApp' } -WhatIf } | Should -Not -Throw
        }
    }

}
