#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-ApplicationsList.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Applications\Invoke-ApplicationsList.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'ApplicationsListTests' -MinLevel 'ERROR'
}

Describe 'Invoke-ApplicationsList' {

    Context 'ModuleMeta' {
        It 'SupportedSystems includes both SelfHosted and ISPSS' {
            $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
            $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
            $ModuleMeta.SupportedSystems.Count | Should -Be 2
        }
    }

    Context 'API call failure' {
        It 'records error on non-success response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 500; ErrorMessage = 'Server Error'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-ApplicationsList -Token $token -InputData @{}
            $result.Failures  | Should -BeGreaterThan 0
            $result.Successes | Should -Be 0
        }

        It 'sets IsFatal on 401 response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 401; ErrorMessage = 'Unauthorized'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-ApplicationsList -Token $token -InputData @{}
            $result.IsFatal | Should -Be $true
        }
    }

    Context 'No applications returned' {
        It 'returns empty result with no errors' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $emptyData = [PSCustomObject]@{ application = @() }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $emptyData }
            }
            $result = Invoke-ApplicationsList -Token $token -InputData @{}
            $result.Successes     | Should -Be 0
            $result.Failures      | Should -Be 0
            $result.Results.Count | Should -Be 0
        }
    }

    Context 'Successful retrieval' {
        It 'returns application rows with mapped fields' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $appsData = [PSCustomObject]@{
                application = @(
                    [PSCustomObject]@{
                        AppID               = 'MyApp'
                        Description         = 'Test Application'
                        Location            = '\Applications'
                        AccessPermittedFrom = 0
                        AccessPermittedTo   = 23
                        Disabled            = $false
                        BusinessOwnerEmail  = 'owner@corp.com'
                    }
                )
            }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $appsData }
            }
            $result = Invoke-ApplicationsList -Token $token -InputData @{}
            $result.Successes          | Should -Be 1
            $result.Results.Count      | Should -Be 1
            $result.Results[0].AppID   | Should -Be 'MyApp'
            $result.Results[0].Description | Should -Be 'Test Application'
        }

        It 'handles optional fields missing from application object' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $appsData = [PSCustomObject]@{
                application = @(
                    [PSCustomObject]@{ AppID = 'MinimalApp' }
                )
            }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $appsData }
            }
            { $result = Invoke-ApplicationsList -Token $token -InputData @{} } | Should -Not -Throw
            $result = Invoke-ApplicationsList -Token $token -InputData @{}
            $result.Results[0].AppID | Should -Be 'MinimalApp'
        }
    }

    Context 'IncludeSublocations CSV-string boolean handling' {
        It 'does not send IncludeSublocations=true when given the CSV string "false"' {
            # Regression test: [bool]$InputData['IncludeSublocations'] casts ANY non-empty
            # string to $true, including the literal text "false" - only a genuinely empty
            # string casts to $false. Import-Csv values are always strings, so a CSV row
            # containing IncludeSublocations,false previously sent IncludeSublocations=true.
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $capturedParams = $null
            Mock Invoke-CyberArkAPI {
                param($Token, $Method, $Endpoint, $QueryParams, [switch]$WhatIf)
                Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ application = @() } }
            }
            Invoke-ApplicationsList -Token $token -InputData @{ IncludeSublocations = 'false' } | Out-Null
            $script:capturedParams.QueryParams['IncludeSublocations'] | Should -Be 'false'
        }

        It 'sends IncludeSublocations=true when given the CSV string "true"' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $capturedParams = $null
            Mock Invoke-CyberArkAPI {
                param($Token, $Method, $Endpoint, $QueryParams, [switch]$WhatIf)
                Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ application = @() } }
            }
            Invoke-ApplicationsList -Token $token -InputData @{ IncludeSublocations = 'true' } | Out-Null
            $script:capturedParams.QueryParams['IncludeSublocations'] | Should -Be 'true'
        }
    }

}
