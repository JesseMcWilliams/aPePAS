#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsResumeDependent.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsResumeDependent.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsResumeDependentTests' -MinLevel 'ERROR'

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

Describe 'Invoke-AccountsResumeDependent - ModuleMeta' {

    It 'DR01 - Category, Action, Name, Version and Priority are set' {
        $ModuleMeta.Category | Should -Be 'Accounts'
        $ModuleMeta.Action   | Should -Be 'ResumeDependent'
        $ModuleMeta.Name     | Should -Be 'Resume Dependent Account'
        $ModuleMeta.Version  | Should -Be '1.0.0'
        $ModuleMeta.Priority | Should -Be 57
    }

    It 'DR02 - write action: SupportsWhatIf, AcceptsInputFile and HasCustomInput are $true' {
        $ModuleMeta.SupportsWhatIf   | Should -BeTrue
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.HasCustomInput   | Should -BeTrue
    }

    It 'DR03 - InputSchema: master identifier columns plus required DependentAccountID' {
        $cols = @($ModuleMeta.InputSchema | ForEach-Object { $_['Column'] })
        $cols | Should -Be @('AccountID', 'AccountName', 'UserName', 'Safe', 'DependentAccountID')
        @($ModuleMeta.InputSchema | Where-Object { $_['Required'] } | ForEach-Object { $_['Column'] }) | Should -Be @('DependentAccountID')
    }

    It 'DR04 - SupportedSystems is SelfHosted only' {
        @($ModuleMeta.SupportedSystems) | Should -Be @('SelfHosted')
    }
}

Describe 'Invoke-AccountsResumeDependent - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'DR05 - POSTs to /API/Accounts/{id}/DependentAccounts/{depId}/Resume with no body' {
        Invoke-AccountsResumeDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Accounts/12_34/DependentAccounts/12_40/Resume' -and $null -eq $Body
        }
    }

    It 'DR06 - Successes=1, Status=Success' {
        $r = Invoke-AccountsResumeDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.Successes                     | Should -Be 1
        $r.Failures                      | Should -Be 0
        $r.Results[0].DependentAccountID | Should -Be '12_40'
        $r.Results[0].Status             | Should -Be 'Success'
    }

    It 'DR07 - AccountName + Safe resolves the master account first' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            script:New-OkResponse -Data ([PSCustomObject]@{ value = @([PSCustomObject]@{ id = '55_1'; name = 'svc-master'; userName = 'svc'; safeName = 'WinSafe' }) })
        }
        $r = Invoke-AccountsResumeDependent -Token $script:Token -InputData @{ AccountName = 'svc-master'; Safe = 'WinSafe'; DependentAccountID = '55_9' }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Endpoint -eq '/API/Accounts/55_1/DependentAccounts/55_9/Resume' }
    }
}

Describe 'Invoke-AccountsResumeDependent - validation and WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'DR08 - WhatIf: no API call, success with Status WhatIf' {
        $r = Invoke-AccountsResumeDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' } -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
        $r.Successes         | Should -Be 1
        $r.Results[0].Status | Should -Be 'WhatIf'
    }

    It 'DR09 - missing DependentAccountID: Failures=1, no API call' {
        $r = Invoke-AccountsResumeDependent -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'DR10 - missing master identifier: Failures=1, no API call' {
        $r = Invoke-AccountsResumeDependent -Token $script:Token -InputData @{ DependentAccountID = '12_40' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }
}

Describe 'Invoke-AccountsResumeDependent - errors' {

    BeforeEach { Mock Add-CyberArkLogSummaryEntry { } }

    It 'DR11 - 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        $r = Invoke-AccountsResumeDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.IsFatal | Should -BeTrue
    }

    It 'DR12 - 404: message keeps the API ErrorCode/ErrorMessage and adds the 14.6 hint, not fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -Message 'ERR404: Not found' }
        $r = Invoke-AccountsResumeDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.IsFatal                | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'ERR404: Not found'
        $r.Errors[0].ErrorMessage | Should -Match 'older than 14\.6'
    }

    It 'DR13 - 403: API message recorded unchanged, not fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 403 -Message 'ERR403: denied' }
        $r = Invoke-AccountsResumeDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.IsFatal                | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Be 'ERR403: denied'
    }
}
