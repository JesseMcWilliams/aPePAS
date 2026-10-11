#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsSyncDependent.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsSyncDependent.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsSyncDependentTests' -MinLevel 'ERROR'

    $script:Token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }

    function script:New-OkResponse {
        param([object]$Data = $null)
        [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $Data }
    }
    function script:New-ErrResponse {
        param([int]$StatusCode, [string]$Message = 'Error')
        [PSCustomObject]@{ IsSuccess = $false; StatusCode = $StatusCode; ErrorMessage = $Message
                           ErrorDetails = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $Message }; Data = $null }
    }
}

Describe 'Invoke-AccountsSyncDependent - ModuleMeta' {

    It 'DS01 - Category, Action, Name, Version and Priority are set' {
        $ModuleMeta.Category | Should -Be 'Accounts'
        $ModuleMeta.Action   | Should -Be 'SyncDependent'
        $ModuleMeta.Name     | Should -Be 'Sync Dependent Account'
        $ModuleMeta.Version  | Should -Be '1.0.0'
        $ModuleMeta.Priority | Should -Be 56
    }

    It 'DS02 - write action: SupportsWhatIf, AcceptsInputFile and HasCustomInput are $true' {
        $ModuleMeta.SupportsWhatIf   | Should -BeTrue
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.HasCustomInput   | Should -BeTrue
    }

    It 'DS03 - InputSchema: master identifier columns plus required DependentAccountID' {
        $cols = @($ModuleMeta.InputSchema | ForEach-Object { $_['Column'] })
        $cols | Should -Be @('AccountID', 'AccountName', 'UserName', 'Safe', 'DependentAccountID')
        @($ModuleMeta.InputSchema | Where-Object { $_['Required'] } | ForEach-Object { $_['Column'] }) | Should -Be @('DependentAccountID')
    }

    It 'DS04 - SupportedSystems is SelfHosted only' {
        @($ModuleMeta.SupportedSystems) | Should -Be @('SelfHosted')
    }
}

Describe 'Invoke-AccountsSyncDependent - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'DS05 - POSTs to /API/Accounts/{id}/DependentAccounts/{depId}/Sync with no body' {
        Invoke-AccountsSyncDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Accounts/12_34/DependentAccounts/12_40/Sync' -and $null -eq $Body
        }
    }

    It 'DS06 - Successes=1, Status=Success' {
        $r = Invoke-AccountsSyncDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.Successes                     | Should -Be 1
        $r.Failures                      | Should -Be 0
        $r.Results[0].DependentAccountID | Should -Be '12_40'
        $r.Results[0].Status             | Should -Be 'Success'
    }

    It 'DS07 - AccountName + Safe resolves the master account first' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            script:New-OkResponse -Data ([PSCustomObject]@{ value = @([PSCustomObject]@{ id = '55_1'; name = 'svc-master'; userName = 'svc'; safeName = 'WinSafe' }) })
        }
        $r = Invoke-AccountsSyncDependent -Token $script:Token -InputData @{ AccountName = 'svc-master'; Safe = 'WinSafe'; DependentAccountID = '55_9' }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Endpoint -eq '/API/Accounts/55_1/DependentAccounts/55_9/Sync' }
    }
}

Describe 'Invoke-AccountsSyncDependent - validation and WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'DS08 - WhatIf: no API call, success with Status WhatIf' {
        $r = Invoke-AccountsSyncDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' } -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
        $r.Successes         | Should -Be 1
        $r.Results[0].Status | Should -Be 'WhatIf'
    }

    It 'DS09 - missing DependentAccountID: Failures=1, no API call' {
        $r = Invoke-AccountsSyncDependent -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'DS10 - missing master identifier: Failures=1, no API call' {
        $r = Invoke-AccountsSyncDependent -Token $script:Token -InputData @{ DependentAccountID = '12_40' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }
}

Describe 'Invoke-AccountsSyncDependent - errors' {

    BeforeEach { Mock Add-CyberArkLogSummaryEntry { } }

    It 'DS11 - 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        $r = Invoke-AccountsSyncDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.IsFatal | Should -BeTrue
    }

    It 'DS12 - 404: message keeps the API ErrorCode/ErrorMessage and adds the 14.6 hint, not fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -Message 'ERR404: Not found' }
        $r = Invoke-AccountsSyncDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.IsFatal                | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'ERR404: Not found'
        $r.Errors[0].ErrorMessage | Should -Match 'older than 14\.6'
    }

    It 'DS13 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 0 -Message 'Network failure' }
        $r = Invoke-AccountsSyncDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.IsFatal | Should -BeTrue
    }
}
