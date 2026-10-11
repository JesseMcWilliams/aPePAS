#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsUnlinkAccount.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsUnlinkAccount.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsUnlinkAccountTests' -MinLevel 'ERROR'
}

Describe 'Invoke-AccountsUnlinkAccount' {

    Context 'Missing AccountID' {
        It 'returns failure when AccountID is not provided' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-AccountsUnlinkAccount -Token $token -InputData @{}
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
            $result = Invoke-AccountsUnlinkAccount -Token $token -InputData @{ AccountID = 'acc123' }
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
            $result = Invoke-AccountsUnlinkAccount -Token $token -InputData @{
                AccountID          = 'acc123'
                ExtraPasswordIndex = '1'
            }
            $result.Successes   | Should -BeGreaterThan 0
            $result.Failures    | Should -Be 0
        }
    }

    Context 'WhatIf mode' {
        It 'does not call the API when WhatIf is set' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI { throw 'Should not be called in WhatIf mode' }
            Mock Add-CyberArkLogSummaryEntry {}
            { Invoke-AccountsUnlinkAccount -Token $token -InputData @{ AccountID = 'acc123' } -WhatIf } | Should -Not -Throw
        }
    }

}

Describe 'Invoke-AccountsUnlinkAccount - ExtraPasswordIndex wording' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { }
        Mock Write-CyberArkLog { }
    }

    It 'describes ExtraPasswordIndex exactly as 1 = Logon, 2 = Elevate, 3 = Reconcile (same as Link Account)' {
        $col = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'ExtraPasswordIndex' }
        $col.Description | Should -BeExactly '1 = Logon, 2 = Elevate, 3 = Reconcile.'
    }

    It 'missing ExtraPasswordIndex error names the index meanings' {
        $tok = [PSCustomObject]@{ BaseURL = 'https://pvwa.example.com/PasswordVault'; Headers = @{}; SystemType = 'SelfHosted' }
        $r = Invoke-AccountsUnlinkAccount -Token $tok -InputData @{ AccountID = '12_34'; ExtraPasswordIndex = '' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match '1 = Logon, 2 = Elevate, 3 = Reconcile'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'has no leftover reconcile-as-2 or link3 wording anywhere in the module file' {
        $text = Get-Content -Path $script:ModulePath -Raw
        $text | Should -Not -Match '2 = reconcile'
        $text | Should -Not -Match '(?i)link3'
    }
}
