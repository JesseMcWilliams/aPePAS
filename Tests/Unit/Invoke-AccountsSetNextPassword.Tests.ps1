#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsSetNextPassword.

.DESCRIPTION
    Get-AccountsSetNextPasswordInput is NOT tested here because it depends on Show-FieldPrompt,
    Read-ConfirmedSecret and Invoke-EntitySearch from the driver scope. Read-ConfirmedSecret has
    its own tests (SC) in Manage-Privilege.Tests.ps1.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsSetNextPassword.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsSetNextPasswordTests' -MinLevel 'ERROR'

    $script:Token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
    $script:Pw    = 'ThisIsMy_FAKE_Password6!'
}

Describe 'Invoke-AccountsSetNextPassword' {

    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[hashtable]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Body, $QueryParams, [switch]$WhatIf)
            $script:Calls.Add(@{ Method = $Method; Endpoint = $Endpoint; Body = $Body; QueryParams = $QueryParams })
            if ($Method -eq 'GET') {
                return [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null
                    Data = [PSCustomObject]@{ value = @(
                        [PSCustomObject]@{ id = '12_7'; name = 'Operating System-Win-host1-admin'; userName = 'admin'; safeName = 'SafeA' }
                    ) } }
            }
            [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{} }
        }
    }

    It 'SN01 - posts NewCredentials and ChangeImmediately = true by default to /API/Accounts/{id}/SetNextPassword' {
        $result = Invoke-AccountsSetNextPassword -Token $script:Token -InputData @{ AccountID = '12_7'; NewCredentials = $script:Pw }
        $result.Successes | Should -Be 1
        $result.Failures  | Should -Be 0
        $script:Calls.Count | Should -Be 1
        $script:Calls[0].Method   | Should -Be 'POST'
        $script:Calls[0].Endpoint | Should -Be '/API/Accounts/12_7/SetNextPassword'
        $script:Calls[0].Body['NewCredentials']    | Should -Be $script:Pw
        $script:Calls[0].Body['ChangeImmediately'] | Should -BeOfType [bool]
        $script:Calls[0].Body['ChangeImmediately'] | Should -Be $true
    }

    It 'SN02 - ChangeImmediately = <Value> sends <Expected>' -TestCases @(
        @{ Value = 'No';    Expected = $false }
        @{ Value = 'false'; Expected = $false }
        @{ Value = '0';     Expected = $false }
        @{ Value = 'Yes';   Expected = $true }
        @{ Value = 'TRUE';  Expected = $true }
        @{ Value = '';      Expected = $true }
    ) {
        param($Value, $Expected)
        Invoke-AccountsSetNextPassword -Token $script:Token -InputData @{ AccountID = '12_7'; NewCredentials = $script:Pw; ChangeImmediately = $Value } | Out-Null
        $script:Calls[0].Body['ChangeImmediately'] | Should -Be $Expected
    }

    It 'SN03 - an unrecognised ChangeImmediately value fails the row without an API call' {
        $result = Invoke-AccountsSetNextPassword -Token $script:Token -InputData @{ AccountID = '12_7'; NewCredentials = $script:Pw; ChangeImmediately = 'maybe' }
        $result.Failures | Should -Be 1
        $result.Errors[0].ErrorMessage | Should -Match 'ChangeImmediately'
        $script:Calls.Count | Should -Be 0
    }

    It 'SN04 - a missing NewCredentials fails the row without an API call' {
        $result = Invoke-AccountsSetNextPassword -Token $script:Token -InputData @{ AccountID = '12_7' }
        $result.Failures       | Should -Be 1
        $result.ItemsProcessed | Should -Be 1
        $result.Errors[0].ErrorMessage | Should -Match 'NewCredentials is required'
        $script:Calls.Count | Should -Be 0
    }

    It 'SN05 - no account identifier fails the row' {
        $result = Invoke-AccountsSetNextPassword -Token $script:Token -InputData @{ NewCredentials = $script:Pw }
        $result.Failures | Should -Be 1
        $result.IsFatal  | Should -Be $false
        $script:Calls.Count | Should -Be 0
    }

    It 'SN06 - AccountName + Safe resolves the ID through a safe lookup first' {
        $result = Invoke-AccountsSetNextPassword -Token $script:Token -InputData @{
            AccountName = 'Operating System-Win-host1-admin'; Safe = 'SafeA'; NewCredentials = $script:Pw
        }
        $result.Successes | Should -Be 1
        $script:Calls.Count | Should -Be 2
        $script:Calls[0].Method   | Should -Be 'GET'
        $script:Calls[1].Endpoint | Should -Be '/API/Accounts/12_7/SetNextPassword'
        $result.Results[0].AccountID | Should -Be '12_7'
    }

    It 'SN07 - WhatIf makes no POST and counts a success' {
        $result = Invoke-AccountsSetNextPassword -Token $script:Token -InputData @{ AccountID = '12_7'; NewCredentials = $script:Pw } -WhatIf
        $result.Successes | Should -Be 1
        $script:Calls.Count | Should -Be 0
    }

    It 'SN08 - an API failure is recorded, and the error InputData masks the password' {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{ IsSuccess = $false; StatusCode = 400; ErrorMessage = 'PASWS168E bad password'; ErrorDetails = $null; Data = $null }
        }
        $result = Invoke-AccountsSetNextPassword -Token $script:Token -InputData @{ AccountID = '12_7'; NewCredentials = $script:Pw }
        $result.Failures | Should -Be 1
        $result.IsFatal  | Should -Be $false
        $result.Errors[0].ErrorMessage | Should -Match 'HTTP 400'
        $result.Errors[0].InputData['NewCredentials'] | Should -Be '***'
        $result.Errors[0].InputData['AccountID']      | Should -Be '12_7'
    }

    It 'SN09 - a 401 is fatal' {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{ IsSuccess = $false; StatusCode = 401; ErrorMessage = 'Unauthorized'; ErrorDetails = $null; Data = $null }
        }
        $result = Invoke-AccountsSetNextPassword -Token $script:Token -InputData @{ AccountID = '12_7'; NewCredentials = $script:Pw }
        $result.IsFatal | Should -Be $true
    }

    It 'SN10 - the result row carries no password' {
        $result = Invoke-AccountsSetNextPassword -Token $script:Token -InputData @{ AccountID = '12_7'; NewCredentials = $script:Pw; ChangeImmediately = 'No' }
        ($result.Results[0] | ConvertTo-Json) | Should -Not -Match 'FAKE_Password'
        $result.Results[0].ChangeImmediately | Should -Be $false
    }

    It 'SN11 - an account ID with special characters is URL-encoded in the path' {
        Invoke-AccountsSetNextPassword -Token $script:Token -InputData @{ AccountID = 'a b'; NewCredentials = $script:Pw } | Out-Null
        $script:Calls[0].Endpoint | Should -Be '/API/Accounts/a%20b/SetNextPassword'
    }
}
