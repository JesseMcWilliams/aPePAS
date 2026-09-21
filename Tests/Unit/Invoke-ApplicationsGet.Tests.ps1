#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-ApplicationsGet.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Applications\Invoke-ApplicationsGet.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'ApplicationsGetTests' -MinLevel 'ERROR'
}

Describe 'Invoke-ApplicationsGet' {

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
            $result = Invoke-ApplicationsGet -Token $token -InputData @{}
            $result.Failures    | Should -Be 1
            $result.Successes   | Should -Be 0
            $result.IsFatal     | Should -Be $false
        }
    }

    Context 'API call failure' {
        It 'records error on non-success response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 404; ErrorMessage = 'Not Found'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-ApplicationsGet -Token $token -InputData @{ AppID = 'MyApp' }
            $result.Failures  | Should -BeGreaterThan 0
            $result.IsFatal   | Should -Be $false
        }
    }

    Context 'Successful retrieval' {
        It 'maps application fields from wrapped response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $appData = [PSCustomObject]@{
                application = [PSCustomObject]@{
                    AppID       = 'MyApp'
                    Description = 'My Application'
                    Location    = '\Applications'
                    Disabled    = $false
                }
            }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $appData }
            }
            $result = Invoke-ApplicationsGet -Token $token -InputData @{ AppID = 'MyApp' }
            $result.Successes            | Should -Be 1
            $result.Results[0].AppID     | Should -Be 'MyApp'
            $result.Results[0].Description | Should -Be 'My Application'
        }

        It 'handles unwrapped response (direct app object)' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $appData = [PSCustomObject]@{
                AppID       = 'MyApp2'
                Description = 'Direct Response'
            }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $appData }
            }
            $result = Invoke-ApplicationsGet -Token $token -InputData @{ AppID = 'MyApp2' }
            $result.Successes | Should -Be 1
        }
    }

}
