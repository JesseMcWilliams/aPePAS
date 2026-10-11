#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsDeleteDependent.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsDeleteDependent.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsDeleteDependentTests' -MinLevel 'ERROR'

    $script:Token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }

    # Driver-scope prompt helpers, stubbed so the custom input function can be tested.
    function Show-FieldPrompt { param([string]$Label, [string]$Default = '', [string]$Description = '') $Default }
    function Read-MenuChoice  { param([string]$Prompt = 'Choice') '' }
    function Invoke-EntitySearch { param() $null }

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

Describe 'Invoke-AccountsDeleteDependent - ModuleMeta' {

    It 'DX01 - Category, Action, Name, Version and Priority are set' {
        $ModuleMeta.Category | Should -Be 'Accounts'
        $ModuleMeta.Action   | Should -Be 'DeleteDependent'
        $ModuleMeta.Name     | Should -Be 'Delete Dependent Account'
        $ModuleMeta.Version  | Should -Be '1.0.0'
        $ModuleMeta.Priority | Should -Be 55
    }

    It 'DX02 - write action: SupportsWhatIf, AcceptsInputFile and HasCustomInput are $true' {
        $ModuleMeta.SupportsWhatIf   | Should -BeTrue
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.HasCustomInput   | Should -BeTrue
    }

    It 'DX03 - InputSchema: master identifier columns plus required DependentAccountID' {
        $cols = @($ModuleMeta.InputSchema | ForEach-Object { $_['Column'] })
        $cols | Should -Be @('AccountID', 'AccountName', 'UserName', 'Safe', 'DependentAccountID')
        @($ModuleMeta.InputSchema | Where-Object { $_['Required'] } | ForEach-Object { $_['Column'] }) | Should -Be @('DependentAccountID')
    }

    It 'DX04 - SupportedSystems is SelfHosted only' {
        @($ModuleMeta.SupportedSystems) | Should -Be @('SelfHosted')
    }
}

Describe 'Invoke-AccountsDeleteDependent - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'DX05 - sends DELETE /API/Accounts/{id}/DependentAccounts/{depId} with no body' {
        Invoke-AccountsDeleteDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'DELETE' -and $Endpoint -eq '/API/Accounts/12_34/DependentAccounts/12_40' -and $null -eq $Body
        }
    }

    It 'DX06 - Successes=1, Status=Deleted' {
        $r = Invoke-AccountsDeleteDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.Successes                     | Should -Be 1
        $r.Failures                      | Should -Be 0
        $r.Results[0].MasterAccountID    | Should -Be '12_34'
        $r.Results[0].DependentAccountID | Should -Be '12_40'
        $r.Results[0].Status             | Should -Be 'Deleted'
    }

    It 'DX07 - AccountName + Safe resolves the master account first' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            script:New-OkResponse -Data ([PSCustomObject]@{ value = @([PSCustomObject]@{ id = '55_1'; name = 'svc-master'; userName = 'svc'; safeName = 'WinSafe' }) })
        }
        $r = Invoke-AccountsDeleteDependent -Token $script:Token -InputData @{ AccountName = 'svc-master'; Safe = 'WinSafe'; DependentAccountID = '55_9' }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' -and $Endpoint -eq '/API/Accounts/55_1/DependentAccounts/55_9' }
    }
}

Describe 'Invoke-AccountsDeleteDependent - validation and WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'DX08 - WhatIf: no API call, success with Status WhatIf' {
        $r = Invoke-AccountsDeleteDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' } -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
        $r.Successes         | Should -Be 1
        $r.Results[0].Status | Should -Be 'WhatIf'
    }

    It 'DX09 - missing DependentAccountID: Failures=1, no API call' {
        $r = Invoke-AccountsDeleteDependent -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'DX10 - missing master identifier: Failures=1, no API call' {
        $r = Invoke-AccountsDeleteDependent -Token $script:Token -InputData @{ DependentAccountID = '12_40' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }
}

Describe 'Invoke-AccountsDeleteDependent - errors' {

    BeforeEach { Mock Add-CyberArkLogSummaryEntry { } }

    It 'DX11 - 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        $r = Invoke-AccountsDeleteDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.IsFatal | Should -BeTrue
    }

    It 'DX12 - 404: message keeps the API ErrorCode/ErrorMessage and adds the 14.6 hint, not fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -Message 'ERR404: Not found' }
        $r = Invoke-AccountsDeleteDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.IsFatal                | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'ERR404: Not found'
        $r.Errors[0].ErrorMessage | Should -Match 'older than 14\.6'
    }
}

Describe 'Get-AccountsDeleteDependentInput' {

    It 'DX13 - shows the permanent-delete warning' {
        Mock Show-FieldPrompt -ParameterFilter { $Label -eq 'Master Account ID' } { '12_34' }
        Mock Show-FieldPrompt -ParameterFilter { $Label -eq 'Dependent Account ID' } { '12_40' }
        Mock Write-Host { }
        $in = Get-AccountsDeleteDependentInput -Token $script:Token -Defaults @{}
        $in['DependentAccountID'] | Should -Be '12_40'
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match 'WARNING: .*permanently deletes the dependent account' -and $ForegroundColor -eq 'Red' }
    }

    It 'DX14 - blank Dependent Account ID uses the picker (GET with -PageSize 0)' {
        Mock Show-FieldPrompt -ParameterFilter { $Label -eq 'Master Account ID' } { '12_34' }
        Mock Show-FieldPrompt -ParameterFilter { $Label -eq 'Dependent Account ID' } { '' }
        Mock Read-MenuChoice { '1' }
        Mock Write-Host { }
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data ([PSCustomObject]@{ value = @([PSCustomObject]@{ dependentAccountId = '12_41'; name = 'x' }) }) }
        $in = Get-AccountsDeleteDependentInput -Token $script:Token -Defaults @{}
        $in['DependentAccountID'] | Should -Be '12_41'
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Endpoint -eq '/API/Accounts/12_34/DependentAccounts' -and $PageSize -eq 0 }
    }
}
