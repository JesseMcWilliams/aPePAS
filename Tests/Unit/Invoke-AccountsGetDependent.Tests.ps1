#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsGetDependent.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsGetDependent.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsGetDependentTests' -MinLevel 'ERROR'

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
    function script:New-ExtendedDependent {
        [PSCustomObject]@{
            dependentAccountId        = '12_40'
            accountId                 = '12_34'
            name                      = 'dep-svc'
            platformId                = 'WinService'
            safeName                  = 'WinSafe'
            folderName                = 'Root'
            createdTime               = 1700000000
            platformAccountProperties = [PSCustomObject]@{ ServiceName = 'svcA' }
            secretManagement          = [PSCustomObject]@{ automaticManagementEnabled = $true; status = 'success'; lastVerifiedTime = 1700000400 }
            linkedAccounts            = @(
                [PSCustomObject]@{ type = 'logon';     displayName = 'Logon Account';     name = 'logon-acct'; extraPasswordIndex = 1 }
                [PSCustomObject]@{ type = 'reconcile'; displayName = 'Reconcile Account'; name = $null;        extraPasswordIndex = 3 }
            )
        }
    }
}

Describe 'Invoke-AccountsGetDependent - ModuleMeta' {

    It 'DG01 - Category, Action, Name, Version and Priority are set' {
        $ModuleMeta.Category | Should -Be 'Accounts'
        $ModuleMeta.Action   | Should -Be 'GetDependent'
        $ModuleMeta.Name     | Should -Be 'Get Dependent Account'
        $ModuleMeta.Version  | Should -Be '1.0.0'
        $ModuleMeta.Priority | Should -Be 52
    }

    It 'DG02 - read action with CSV input: SupportsWhatIf $false; AcceptsInputFile, ProducesOutput, HasCustomInput $true' {
        $ModuleMeta.SupportsWhatIf   | Should -BeFalse
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.ProducesOutput   | Should -BeTrue
        $ModuleMeta.HasCustomInput   | Should -BeTrue
    }

    It 'DG03 - InputSchema: master identifier columns plus required DependentAccountID' {
        $cols = @($ModuleMeta.InputSchema | ForEach-Object { $_['Column'] })
        $cols | Should -Be @('AccountID', 'AccountName', 'UserName', 'Safe', 'DependentAccountID')
        ($ModuleMeta.InputSchema | Where-Object { $_['Column'] -eq 'DependentAccountID' })['Required'] | Should -BeTrue
    }

    It 'DG04 - SupportedSystems is SelfHosted only' {
        @($ModuleMeta.SupportedSystems) | Should -Be @('SelfHosted')
    }
}

Describe 'Invoke-AccountsGetDependent - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data (script:New-ExtendedDependent) }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'DG05 - GETs /API/Accounts/{id}/DependentAccounts/{depId} once with extendedDetails=true and -PageSize 0' {
        Invoke-AccountsGetDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq '/API/Accounts/12_34/DependentAccounts/12_40' -and
            $QueryParams['extendedDetails'] -eq 'true' -and $PageSize -eq 0
        }
    }

    It 'DG06 - maps the row: ids, platform, dates, Platform_ columns' {
        $r = Invoke-AccountsGetDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.Successes | Should -Be 1
        $row = $r.Results[0]
        $row.MasterAccountID       | Should -Be '12_34'
        $row.DependentAccountID    | Should -Be '12_40'
        $row.Name                  | Should -Be 'dep-svc'
        $row.PlatformID            | Should -Be 'WinService'
        $row.AutoManaged           | Should -BeTrue
        $row.Created               | Should -Be (ConvertFrom-CyberArkExpirationTime 1700000000)
        $row.LastVerified          | Should -Be (ConvertFrom-CyberArkExpirationTime 1700000400)
        $row.Platform_ServiceName  | Should -Be 'svcA'
    }

    It 'DG07 - LinkedAccounts summarizes each slot; an empty slot shows (none)' {
        $row = (Invoke-AccountsGetDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }).Results[0]
        $row.LinkedAccounts | Should -Be 'Logon Account: logon-acct (index 1); Reconcile Account: (none) (index 3)'
    }

    It 'DG08 - minimal response (no optional properties) does not throw and falls back to the input IDs' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data ([PSCustomObject]@{ platformId = 'P' }) }
        $r = Invoke-AccountsGetDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.Successes | Should -Be 1
        $r.Results[0].DependentAccountID | Should -Be '12_40'
        $r.Results[0].MasterAccountID    | Should -Be '12_34'
        $r.Results[0].LinkedAccounts     | Should -Be ''
    }

    It 'DG09 - AccountName + Safe resolves the master account first' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Endpoint -eq '/API/Accounts' } {
            script:New-OkResponse -Data ([PSCustomObject]@{ value = @([PSCustomObject]@{ id = '55_1'; name = 'svc-master'; userName = 'svc'; safeName = 'WinSafe' }) })
        }
        $r = Invoke-AccountsGetDependent -Token $script:Token -InputData @{ AccountName = 'svc-master'; Safe = 'WinSafe'; DependentAccountID = '55_9' }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Endpoint -eq '/API/Accounts/55_1/DependentAccounts/55_9' -and $PageSize -eq 0 }
    }
}

Describe 'Invoke-AccountsGetDependent - validation and errors' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data (script:New-ExtendedDependent) }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'DG10 - missing DependentAccountID: Failures=1, no API call' {
        $r = Invoke-AccountsGetDependent -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'DependentAccountID'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'DG11 - missing master identifier: Failures=1, no API call' {
        $r = Invoke-AccountsGetDependent -Token $script:Token -InputData @{ DependentAccountID = '12_40' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'DG12 - 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        $r = Invoke-AccountsGetDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.IsFatal | Should -BeTrue
    }

    It 'DG13 - 404: message keeps the API ErrorCode/ErrorMessage and adds the 14.6 hint, not fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -Message 'ERR404: Not found' }
        $r = Invoke-AccountsGetDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.IsFatal                | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'ERR404: Not found'
        $r.Errors[0].ErrorMessage | Should -Match 'older than 14\.6'
    }
}

Describe 'Get-AccountsGetDependentInput - dependent account picker' {

    It 'DG14 - blank Dependent Account ID lists the master''s dependents (-PageSize 0) and returns the chosen one' {
        Mock Show-FieldPrompt -ParameterFilter { $Label -eq 'Master Account ID' } { '12_34' }
        Mock Show-FieldPrompt -ParameterFilter { $Label -eq 'Dependent Account ID' } { '' }
        Mock Read-MenuChoice { '2' }
        Mock Write-Host { }
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data @(
            [PSCustomObject]@{ dependentAccountId = '12_40'; name = 'a'; platformId = 'P' },
            [PSCustomObject]@{ dependentAccountId = '12_41'; name = 'b'; platformId = 'P' }) }
        $in = Get-AccountsGetDependentInput -Token $script:Token -Defaults @{}
        $in['AccountID']          | Should -Be '12_34'
        $in['DependentAccountID'] | Should -Be '12_41'
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq '/API/Accounts/12_34/DependentAccounts' -and $PageSize -eq 0
        }
    }

    It 'DG15 - picker cancelled: returns $null' {
        Mock Show-FieldPrompt -ParameterFilter { $Label -eq 'Master Account ID' } { '12_34' }
        Mock Show-FieldPrompt -ParameterFilter { $Label -eq 'Dependent Account ID' } { '' }
        Mock Read-MenuChoice { 'B' }
        Mock Write-Host { }
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data @([PSCustomObject]@{ dependentAccountId = '12_40' }) }
        Get-AccountsGetDependentInput -Token $script:Token -Defaults @{} | Should -BeNullOrEmpty
    }

    It 'DG16 - typed Dependent Account ID skips the picker' {
        Mock Show-FieldPrompt -ParameterFilter { $Label -eq 'Master Account ID' } { '12_34' }
        Mock Show-FieldPrompt -ParameterFilter { $Label -eq 'Dependent Account ID' } { '12_49' }
        Mock Invoke-CyberArkAPI { throw 'should not be called' }
        $in = Get-AccountsGetDependentInput -Token $script:Token -Defaults @{}
        $in['DependentAccountID'] | Should -Be '12_49'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }
}
