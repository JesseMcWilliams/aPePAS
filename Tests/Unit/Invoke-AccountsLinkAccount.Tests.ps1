#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsLinkAccount.
#>

BeforeAll {
    Set-StrictMode -Version Latest
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsLinkAccount.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsLinkAccountTests' -MinLevel 'ERROR'
}

Describe 'Invoke-AccountsLinkAccount' {

    Context 'Missing AccountID' {
        It 'returns failure when AccountID is not provided' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-AccountsLinkAccount -Token $token -InputData @{}
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
            $result = Invoke-AccountsLinkAccount -Token $token -InputData @{ AccountID = 'acc123' }
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
            # Bug: this InputData previously used 'Name'/'Safe', which don't match the
            # InputSchema's 'LinkName'/'LinkSafe' columns. $InputData['LinkName'] returned
            # $null (key absent from the hashtable), so the production function correctly
            # rejected the call with "LinkName is required." - the test was exercising the
            # validation-failure path while asserting success-path expectations.
            $result = Invoke-AccountsLinkAccount -Token $token -InputData @{
                AccountID          = 'acc123'
                ExtraPasswordIndex = '1'
                LinkName           = 'LinkedAcct'
                LinkSafe           = 'TestSafe'
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
            { Invoke-AccountsLinkAccount -Token $token -InputData @{ AccountID = 'acc123' } -WhatIf } | Should -Not -Throw
        }
    }

}

Describe 'Invoke-AccountsLinkAccount - ExtraPasswordIndex wording' {

    It 'describes ExtraPasswordIndex exactly as 1 = Logon, 2 = Elevate, 3 = Reconcile (same as Unlink Account)' {
        $col = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'ExtraPasswordIndex' }
        $col.Description | Should -BeExactly '1 = Logon, 2 = Elevate, 3 = Reconcile.'
    }

    It 'has no leftover enable/link3 wording anywhere in the module file' {
        $text = Get-Content -Path $script:ModulePath -Raw
        $text | Should -Not -Match '(?i)\benable\b'
        $text | Should -Not -Match '(?i)link3'
    }
}
