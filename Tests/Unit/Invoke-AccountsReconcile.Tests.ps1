#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsReconcile.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsReconcile.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsReconcileTests' -MinLevel 'ERROR'
}

Describe 'Invoke-AccountsReconcile' {

    Context 'Missing AccountID' {
        It 'returns failure when AccountID is not provided' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-AccountsReconcile -Token $token -InputData @{}
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
            $result = Invoke-AccountsReconcile -Token $token -InputData @{ AccountID = 'acc123' }
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
            $result = Invoke-AccountsReconcile -Token $token -InputData @{ AccountID = 'acc123' }
            $result.Successes   | Should -BeGreaterThan 0
            $result.Failures    | Should -Be 0
        }
    }

    Context 'WhatIf mode' {
        It 'does not call the API when WhatIf is set' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI { throw 'Should not be called in WhatIf mode' }
            Mock Add-CyberArkLogSummaryEntry {}
            { Invoke-AccountsReconcile -Token $token -InputData @{ AccountID = 'acc123' } -WhatIf } | Should -Not -Throw
        }
    }

    Context 'Account identifiers (AccountID, AccountName/ObjectName, UserName + Safe)' {
        BeforeEach {
            $script:token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $script:posts = [System.Collections.Generic.List[string]]::new()
            Mock Add-CyberArkLogSummaryEntry {}
            Mock Invoke-CyberArkAPI {
                param($Token, $Method, $Endpoint, $QueryParams, [switch]$WhatIf)
                if ($Method -eq 'GET') {
                    return [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{
                        value = @(
                            [PSCustomObject]@{ id = '11_1'; name = 'srv1-root'; userName = 'root';  safeName = 'Linux' }
                            [PSCustomObject]@{ id = '11_2'; name = 'srv2-root'; userName = 'root';  safeName = 'Linux' }
                            [PSCustomObject]@{ id = '11_3'; name = 'root';      userName = 'admin'; safeName = 'Linux' }
                        ) } }
                }
                $script:posts.Add($Endpoint)
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{} }
            }
        }

        It 'AccountID skips the lookup entirely' {
            $r = Invoke-AccountsReconcile -Token $script:token -InputData @{ AccountID = '11_2' }
            $r.Successes | Should -Be 1
            Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly -ParameterFilter { $Method -eq 'GET' }
            $script:posts | Should -Be @('/API/Accounts/11_2/Reconcile')
        }

        It 'AccountName matches the object name, not the username' {
            $r = Invoke-AccountsReconcile -Token $script:token -InputData @{ AccountName = 'root'; Safe = 'Linux' }
            $r.Successes | Should -Be 1
            $script:posts | Should -Be @('/API/Accounts/11_3/Reconcile')
        }

        It 'ObjectName works as an alias for AccountName' {
            $r = Invoke-AccountsReconcile -Token $script:token -InputData @{ ObjectName = 'srv1-root'; Safe = 'Linux' }
            $r.Successes | Should -Be 1
            $script:posts | Should -Be @('/API/Accounts/11_1/Reconcile')
        }

        It 'UserName with AccountName narrows to one account' {
            $r = Invoke-AccountsReconcile -Token $script:token -InputData @{ AccountName = 'srv2-root'; UserName = 'root'; Safe = 'Linux' }
            $r.Successes | Should -Be 1
            $script:posts | Should -Be @('/API/Accounts/11_2/Reconcile')
        }

        It 'an ambiguous UserName fails the row and never sends the reconcile' {
            $r = Invoke-AccountsReconcile -Token $script:token -InputData @{ UserName = 'root'; Safe = 'Linux' }
            $r.Failures                | Should -Be 1
            $r.Successes               | Should -Be 0
            $r.Errors[0].ErrorMessage  | Should -Match "^2 accounts with UserName 'root' found in safe 'Linux'"
            $script:posts.Count        | Should -Be 0
        }
    }

}
