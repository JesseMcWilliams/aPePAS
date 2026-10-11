#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsRequestJitAccess.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsRequestJitAccess.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsRequestJitAccessTests' -MinLevel 'ERROR'

    $script:Token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }

    function script:New-OkResponse {
        param([object]$Data = [PSCustomObject]@{})
        [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $Data }
    }
    function script:New-ErrResponse {
        param([int]$StatusCode, [string]$Message = 'Error')
        [PSCustomObject]@{ IsSuccess = $false; StatusCode = $StatusCode; ErrorMessage = $Message
                           ErrorDetails = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $Message }; Data = $null }
    }
}

Describe 'Invoke-AccountsRequestJitAccess - ModuleMeta' {

    It 'RJ01 - Category, Action and Name are set' {
        $ModuleMeta.Category | Should -Be 'Accounts'
        $ModuleMeta.Action   | Should -Be 'RequestJitAccess'
        $ModuleMeta.Name     | Should -Be 'Request JIT Access'
    }

    It 'RJ02 - write action: SupportsWhatIf, AcceptsInputFile and HasCustomInput are $true' {
        $ModuleMeta.SupportsWhatIf   | Should -BeTrue
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.HasCustomInput   | Should -BeTrue
    }

    It 'RJ03 - InputSchema has the standard account identifier columns' {
        $cols = @($ModuleMeta.InputSchema | ForEach-Object { $_.Column })
        $cols | Should -Be @('AccountID', 'AccountName', 'UserName', 'Safe')
    }

    It 'RJ04 - SupportedSystems contains ISPSS and SelfHosted' {
        $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
    }
}

Describe 'Invoke-AccountsRequestJitAccess - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'RJ05 - POSTs to /API/Accounts/{id}/GrantAdministrativeAccess with no body' {
        Invoke-AccountsRequestJitAccess -Token $script:Token -InputData @{ AccountID = '12_34' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Accounts/12_34/GrantAdministrativeAccess' -and $null -eq $Body
        }
    }

    It 'RJ06 - Successes=1, ItemsProcessed=1, Failures=0, Status=Granted' {
        $r = Invoke-AccountsRequestJitAccess -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.Successes            | Should -Be 1
        $r.ItemsProcessed       | Should -Be 1
        $r.Failures             | Should -Be 0
        $r.IsFatal              | Should -BeFalse
        $r.Results[0].AccountID | Should -Be '12_34'
        $r.Results[0].Status    | Should -Be 'Granted'
    }

    It 'RJ07 - AccountName + Safe resolves the account ID before the POST' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            script:New-OkResponse -Data ([PSCustomObject]@{ value = @(
                [PSCustomObject]@{ id = '55_1'; name = 'srv01-admin'; userName = 'admin'; safeName = 'WinSafe' }
            ) })
        }
        $r = Invoke-AccountsRequestJitAccess -Token $script:Token -InputData @{ AccountName = 'srv01-admin'; Safe = 'WinSafe' }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Endpoint -eq '/API/Accounts/55_1/GrantAdministrativeAccess' }
    }
}

Describe 'Invoke-AccountsRequestJitAccess - validation and WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'RJ08 - no identifier: Failures=1, not fatal, no API call' {
        $r = Invoke-AccountsRequestJitAccess -Token $script:Token -InputData @{}
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'RJ09 - WhatIf: no API call, success with Status WhatIf' {
        $r = Invoke-AccountsRequestJitAccess -Token $script:Token -InputData @{ AccountID = '12_34' } -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
        $r.Successes         | Should -Be 1
        $r.Results[0].Status | Should -Be 'WhatIf'
    }

    It 'RJ10 - account not found in the safe: row fails without a POST' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } { script:New-OkResponse -Data ([PSCustomObject]@{ value = @() }) }
        $r = Invoke-AccountsRequestJitAccess -Token $script:Token -InputData @{ AccountName = 'missing'; Safe = 'WinSafe' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }
}

Describe 'Invoke-AccountsRequestJitAccess - errors' {

    BeforeEach { Mock Add-CyberArkLogSummaryEntry { } }

    It 'RJ11 - 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        $r = Invoke-AccountsRequestJitAccess -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.IsFatal  | Should -BeTrue
        $r.Failures | Should -Be 1
    }

    It 'RJ12 - 403 (for example ad hoc access not allowed): API message recorded, not fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 403 -Message 'ERR403: not allowed' }
        $r = Invoke-AccountsRequestJitAccess -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.IsFatal                          | Should -BeFalse
        $r.Failures                         | Should -Be 1
        $r.Errors[0].ErrorMessage           | Should -Be 'ERR403: not allowed'
        $r.Errors[0].ErrorDetails.ErrorCode | Should -Be 'ERR403'
    }

    It 'RJ13 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 0 -Message 'Network failure' }
        $r = Invoke-AccountsRequestJitAccess -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.IsFatal | Should -BeTrue
    }
}
