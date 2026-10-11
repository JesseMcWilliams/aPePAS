#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsListDependents.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsListDependents.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsListDependentsTests' -MinLevel 'ERROR'

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
    function script:New-Dependent {
        param([string]$Id = '12_40', [hashtable]$Props = @{ Address = 'srv01'; ServiceName = 'svcA' })
        [PSCustomObject]@{
            dependentAccountId        = $Id
            accountId                 = '12_34'
            name                      = "dep-$Id"
            platformId                = 'WinService'
            safeName                  = 'WinSafe'
            folderName                = 'Root'
            createdTime               = 1700000000
            categoryModificationTime  = 1700000100
            platformAccountProperties = [PSCustomObject]$Props
            secretManagement          = [PSCustomObject]@{
                automaticManagementEnabled = $true
                status                     = 'success'
                lastModifiedTime           = 1700000200
                lastReconciledTime         = 1700000300
                lastVerifiedTime           = 1700000400
            }
        }
    }
}

Describe 'Invoke-AccountsListDependents - ModuleMeta' {

    It 'DL01 - Category, Action, Name, Version and Priority are set' {
        $ModuleMeta.Category | Should -Be 'Accounts'
        $ModuleMeta.Action   | Should -Be 'ListDependents'
        $ModuleMeta.Name     | Should -Be 'List Dependent Accounts'
        $ModuleMeta.Version  | Should -Be '1.0.0'
        $ModuleMeta.Priority | Should -Be 50
    }

    It 'DL02 - read action: SupportsWhatIf is $false; AcceptsInputFile, ProducesOutput and HasCustomInput are $true' {
        $ModuleMeta.SupportsWhatIf   | Should -BeFalse
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.ProducesOutput   | Should -BeTrue
        $ModuleMeta.HasCustomInput   | Should -BeTrue
    }

    It 'DL03 - InputSchema has the master identifier columns plus Search and Failed' {
        $cols = @($ModuleMeta.InputSchema | ForEach-Object { $_['Column'] })
        $cols | Should -Be @('AccountID', 'AccountName', 'UserName', 'Safe', 'Search', 'Failed')
    }

    It 'DL04 - SupportedSystems is SelfHosted only' {
        @($ModuleMeta.SupportedSystems) | Should -Be @('SelfHosted')
    }
}

Describe 'Invoke-AccountsListDependents - success' {

    BeforeEach { Mock Add-CyberArkLogSummaryEntry { } }

    It 'DL05 - GETs /API/Accounts/{id}/DependentAccounts once with -PageSize 0 and no query params by default' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data @((script:New-Dependent)) }
        Invoke-AccountsListDependents -Token $script:Token -InputData @{ AccountID = '12_34' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq '/API/Accounts/12_34/DependentAccounts' -and $PageSize -eq 0 -and $QueryParams.Count -eq 0
        }
    }

    It 'DL06 - bare array response: maps the row columns, dates and Platform_ columns' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data @((script:New-Dependent)) }
        $r = Invoke-AccountsListDependents -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.Successes      | Should -Be 1
        $r.Failures       | Should -Be 0
        $r.Results.Count  | Should -Be 1
        $row = $r.Results[0]
        $row.MasterAccountID     | Should -Be '12_34'
        $row.DependentAccountID  | Should -Be '12_40'
        $row.Name                | Should -Be 'dep-12_40'
        $row.PlatformID          | Should -Be 'WinService'
        $row.SafeName            | Should -Be 'WinSafe'
        $row.FolderName          | Should -Be 'Root'
        $row.AutoManaged         | Should -BeTrue
        $row.CPMStatus           | Should -Be 'success'
        $row.Created             | Should -Be (ConvertFrom-CyberArkExpirationTime 1700000000)
        $row.LastVerified        | Should -Be (ConvertFrom-CyberArkExpirationTime 1700000400)
        $row.Platform_Address    | Should -Be 'srv01'
        $row.Platform_ServiceName | Should -Be 'svcA'
    }

    It 'DL07 - wrapped response (value property) is also read' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data ([PSCustomObject]@{ value = @((script:New-Dependent -Id '12_41'), (script:New-Dependent -Id '12_42')); count = 2 }) }
        $r = Invoke-AccountsListDependents -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.Results.Count | Should -Be 2
        $r.Results[1].DependentAccountID | Should -Be '12_42'
    }

    It 'DL08 - wrapped response under an unknown array property is also read' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data ([PSCustomObject]@{ dependents = @((script:New-Dependent -Id '12_43')); Total = 1 }) }
        $r = Invoke-AccountsListDependents -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.Results.Count | Should -Be 1
        $r.Results[0].DependentAccountID | Should -Be '12_43'
    }

    It 'DL09 - rows with different platform properties get the same Platform_ columns' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data @(
            (script:New-Dependent -Id '12_41' -Props @{ Address = 'a' }),
            (script:New-Dependent -Id '12_42' -Props @{ Port = '22' })) }
        $r = Invoke-AccountsListDependents -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.Results[0].PSObject.Properties['Platform_Port']    | Should -Not -BeNullOrEmpty
        $r.Results[1].PSObject.Properties['Platform_Address'] | Should -Not -BeNullOrEmpty
        $r.Results[0].Platform_Port | Should -Be ''
    }

    It 'DL10 - missing optional properties do not throw under strict mode' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data @([PSCustomObject]@{ dependentAccountId = '12_44'; platformId = 'P' }) }
        $r = Invoke-AccountsListDependents -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.Successes | Should -Be 1
        $r.Results[0].MasterAccountID | Should -Be '12_34'
        $r.Results[0].Created         | Should -Be ''
        $r.Results[0].CPMStatus       | Should -Be ''
    }

    It 'DL11 - empty list: success with no rows' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data @() }
        $r = Invoke-AccountsListDependents -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.Successes     | Should -Be 1
        $r.Results.Count | Should -Be 0
    }

    It 'DL12 - Search and Failed are sent as query params (failed lower-cased)' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data @() }
        Invoke-AccountsListDependents -Token $script:Token -InputData @{ AccountID = '12_34'; Search = 'svc'; Failed = 'TRUE' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $QueryParams['search'] -eq 'svc' -and $QueryParams['failed'] -eq 'true' -and $PageSize -eq 0
        }
    }

    It 'DL13 - AccountName + Safe resolves the master account before listing' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Endpoint -eq '/API/Accounts' } {
            script:New-OkResponse -Data ([PSCustomObject]@{ value = @([PSCustomObject]@{ id = '55_1'; name = 'svc-master'; userName = 'svc'; safeName = 'WinSafe' }) })
        }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Endpoint -ne '/API/Accounts' } { script:New-OkResponse -Data @() }
        $r = Invoke-AccountsListDependents -Token $script:Token -InputData @{ AccountName = 'svc-master'; Safe = 'WinSafe' }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Endpoint -eq '/API/Accounts/55_1/DependentAccounts' -and $PageSize -eq 0 }
    }
}

Describe 'Invoke-AccountsListDependents - validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data @() }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'DL14 - no master identifier: Failures=1, not fatal, no API call' {
        $r = Invoke-AccountsListDependents -Token $script:Token -InputData @{}
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'DL15 - Failed that is not true/false: Failures=1, no API call' {
        $r = Invoke-AccountsListDependents -Token $script:Token -InputData @{ AccountID = '12_34'; Failed = 'yes' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'true or false'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }
}

Describe 'Invoke-AccountsListDependents - errors' {

    BeforeEach { Mock Add-CyberArkLogSummaryEntry { } }

    It 'DL16 - 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        $r = Invoke-AccountsListDependents -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.IsFatal  | Should -BeTrue
        $r.Failures | Should -Be 1
    }

    It 'DL17 - 404: message keeps the API ErrorCode/ErrorMessage and adds the 14.6 hint, not fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -Message 'PASWS001E: Not found' }
        $r = Invoke-AccountsListDependents -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.IsFatal  | Should -BeFalse
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage           | Should -Match 'PASWS001E: Not found'
        $r.Errors[0].ErrorMessage           | Should -Match 'older than 14\.6'
        $r.Errors[0].ErrorDetails.ErrorCode | Should -Be 'ERR404'
    }

    It 'DL18 - 403: API message recorded unchanged, not fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 403 -Message 'ERR403: denied' }
        $r = Invoke-AccountsListDependents -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.IsFatal                | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Be 'ERR403: denied'
    }
}
