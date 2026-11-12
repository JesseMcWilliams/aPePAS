#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsChangeInVault.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsChangeInVault.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsChangeInVaultTests' -MinLevel 'ERROR'
}

Describe 'Invoke-AccountsChangeInVault' {

    Context 'Missing AccountID' {
        It 'returns failure when AccountID is not provided' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-AccountsChangeInVault -Token $token -InputData @{}
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
            $result = Invoke-AccountsChangeInVault -Token $token -InputData @{ AccountID = 'acc123' }
            $result.Failures    | Should -BeGreaterThan 0
            $result.IsFatal     | Should -Be $false
        }
    }

    Context 'Successful operation' {
        It 'records success on 200/204 response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{} }
            }
            $result = Invoke-AccountsChangeInVault -Token $token -InputData @{
                AccountID      = 'acc123'
                NewCredentials = 'NewPassword1'
            }
            $result.Successes   | Should -BeGreaterThan 0
            $result.Failures    | Should -Be 0
        }

        It 'calls POST /API/Accounts/{id}/Password/Update, not SetNextPassword' {
            # Regression test: this module changes the credentials in the vault immediately, which
            # is Password/Update. SetNextPassword instead queues a value for the next CPM-driven
            # change and is a different operation - see Testing_Findings-and-Known-Issues.md Finding F12.
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $capturedParams = $null
            Mock Invoke-CyberArkAPI {
                param($Token, $Method, $Endpoint, $Body, [switch]$WhatIf)
                Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{} }
            }
            Invoke-AccountsChangeInVault -Token $token -InputData @{
                AccountID      = 'acc123'
                NewCredentials = 'NewPassword1'
            } | Out-Null
            $script:capturedParams.Endpoint | Should -Be '/API/Accounts/acc123/Password/Update'
        }
    }

    Context 'ChangeEntireGroup' {
        BeforeEach {
            $script:Bodies = [System.Collections.Generic.List[hashtable]]::new()
            Mock Invoke-CyberArkAPI {
                param($Token, $Method, $Endpoint, $Body, [switch]$WhatIf)
                $script:Bodies.Add($Body)
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{} }
            }
        }

        It 'CV01 - ChangeEntireGroup = <Value> sends ChangeEntireGroup = true' -TestCases @(
            @{ Value = 'Yes' }, @{ Value = 'true' }, @{ Value = 'Y' }, @{ Value = '1' }
        ) {
            param($Value)
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Invoke-AccountsChangeInVault -Token $token -InputData @{
                AccountID = 'acc123'; NewCredentials = 'ThisIsMy_FAKE_Password6!'; ChangeEntireGroup = $Value
            } | Out-Null
            $script:Bodies[0]['ChangeEntireGroup'] | Should -Be $true
            $script:Bodies[0]['NewCredentials']    | Should -Be 'ThisIsMy_FAKE_Password6!'
        }

        It 'CV02 - ChangeEntireGroup = <Value> leaves the field out of the body' -TestCases @(
            @{ Value = 'No' }, @{ Value = '' }, @{ Value = $null }
        ) {
            param($Value)
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Invoke-AccountsChangeInVault -Token $token -InputData @{
                AccountID = 'acc123'; NewCredentials = 'ThisIsMy_FAKE_Password6!'; ChangeEntireGroup = $Value
            } | Out-Null
            $script:Bodies[0].ContainsKey('ChangeEntireGroup') | Should -Be $false
        }
    }

    Context 'WhatIf mode' {
        It 'does not call the API when WhatIf is set' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI { throw 'Should not be called in WhatIf mode' }
            Mock Add-CyberArkLogSummaryEntry {}
            { Invoke-AccountsChangeInVault -Token $token -InputData @{ AccountID = 'acc123' } -WhatIf } | Should -Not -Throw
        }
    }

}
