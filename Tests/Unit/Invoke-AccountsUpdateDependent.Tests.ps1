#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsUpdateDependent.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsUpdateDependent.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsUpdateDependentTests' -MinLevel 'ERROR'

    $script:Token    = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
    $script:Endpoint = '/API/Accounts/12_34/DependentAccounts/12_40'

    function script:New-OkResponse {
        param([object]$Data = [PSCustomObject]@{})
        [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $Data }
    }
    function script:New-ErrResponse {
        param([int]$StatusCode, [string]$Message = 'Error')
        [PSCustomObject]@{ IsSuccess = $false; StatusCode = $StatusCode; ErrorMessage = $Message
                           ErrorDetails = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $Message }; Data = $null }
    }
    function script:New-Current {
        [PSCustomObject]@{
            dependentAccountId        = '12_40'
            accountId                 = '12_34'
            name                      = 'current-name'
            platformId                = 'WinService'
            safeName                  = 'WinSafe'
            createdTime               = 1700000000
            platformAccountProperties = [PSCustomObject]@{ Address = 'srv01'; ServiceName = 'svcA' }
            secretManagement          = [PSCustomObject]@{
                automaticManagementEnabled = $false
                manualManagementReason     = 'current-reason'
                status                     = 'success'
                lastModifiedTime           = 1700000200
            }
        }
    }
}

Describe 'Invoke-AccountsUpdateDependent - ModuleMeta' {

    It 'DU01 - Category, Action, Name, Version and Priority are set' {
        $ModuleMeta.Category | Should -Be 'Accounts'
        $ModuleMeta.Action   | Should -Be 'UpdateDependent'
        $ModuleMeta.Name     | Should -Be 'Update Dependent Account'
        $ModuleMeta.Version  | Should -Be '1.0.0'
        $ModuleMeta.Priority | Should -Be 54
    }

    It 'DU02 - write action: SupportsWhatIf, AcceptsInputFile, ProducesOutput and HasCustomInput are $true' {
        $ModuleMeta.SupportsWhatIf   | Should -BeTrue
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.ProducesOutput   | Should -BeTrue
        $ModuleMeta.HasCustomInput   | Should -BeTrue
    }

    It 'DU03 - InputSchema columns; only DependentAccountID is required' {
        $cols = @($ModuleMeta.InputSchema | ForEach-Object { $_['Column'] })
        $cols | Should -Be @('AccountID', 'AccountName', 'UserName', 'Safe', 'DependentAccountID', 'Name', 'AutomaticManagementEnabled', 'ManualManagementReason', 'PlatformAccountProperties')
        @($ModuleMeta.InputSchema | Where-Object { $_['Required'] } | ForEach-Object { $_['Column'] }) | Should -Be @('DependentAccountID')
    }

    It 'DU04 - SupportedSystems is SelfHosted only' {
        @($ModuleMeta.SupportedSystems) | Should -Be @('SelfHosted')
    }
}

Describe 'Invoke-AccountsUpdateDependent - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } { script:New-OkResponse -Data (script:New-Current) }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } { script:New-OkResponse -Data $null }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'DU05 - GETs the current dependent account once with -PageSize 0' {
        Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40'; Name = 'new' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq $script:Endpoint -and $PageSize -eq 0
        }
    }

    It 'DU06 - all fields given: PUT body carries the new values' {
        Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{
            AccountID = '12_34'; DependentAccountID = '12_40'; Name = 'new-name'
            AutomaticManagementEnabled = 'true'; ManualManagementReason = 'new-reason'
            PlatformAccountProperties = 'Address=srv02;Port=8080'
        } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PUT' -and $Endpoint -eq $script:Endpoint -and
            $Body['name'] -eq 'new-name' -and
            $Body['secretManagement']['automaticManagementEnabled'] -eq $true -and
            $Body['secretManagement']['manualManagementReason'] -eq 'new-reason' -and
            $Body['platformAccountProperties']['Address'] -eq 'srv02' -and
            $Body['platformAccountProperties']['Port'] -eq '8080' -and
            $Body['platformAccountProperties']['ServiceName'] -eq 'svcA'
        }
    }

    It 'DU07 - blank fields keep the current values from the GET' {
        Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{
            AccountID = '12_34'; DependentAccountID = '12_40'; Name = ''; AutomaticManagementEnabled = ''
            ManualManagementReason = ' '; PlatformAccountProperties = ''; Platform_Address = ''
        } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PUT' -and
            $Body['name'] -eq 'current-name' -and
            $Body['secretManagement']['automaticManagementEnabled'] -eq $false -and
            $Body['secretManagement']['manualManagementReason'] -eq 'current-reason' -and
            $Body['platformAccountProperties']['Address'] -eq 'srv01' -and
            $Body['platformAccountProperties']['ServiceName'] -eq 'svcA' -and
            $Body['platformAccountProperties'].Count -eq 2
        }
    }

    It 'DU08 - PUT body never carries read-only secretManagement fields or other GET properties' {
        Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PUT' -and
            @($Body.Keys | Sort-Object) -join ',' -eq 'name,platformAccountProperties,secretManagement' -and
            @($Body['secretManagement'].Keys | Sort-Object) -join ',' -eq 'automaticManagementEnabled,manualManagementReason'
        }
    }

    It 'DU09 - one Platform_ column changes only that key' {
        Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40'; Platform_ServiceName = 'svcB' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PUT' -and $Body['platformAccountProperties']['ServiceName'] -eq 'svcB' -and $Body['platformAccountProperties']['Address'] -eq 'srv01'
        }
    }

    It 'DU10 - current account without optional properties: body has only what was given' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } { script:New-OkResponse -Data ([PSCustomObject]@{ platformId = 'P' }) }
        Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40'; Name = 'n2' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PUT' -and $Body.Count -eq 1 -and $Body['name'] -eq 'n2'
        }
    }

    It 'DU11 - result row: Status Updated with the merged values' {
        $r = Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40'; Name = 'new-name' }
        $r.Successes | Should -Be 1
        $row = $r.Results[0]
        $row.Status             | Should -Be 'Updated'
        $row.DependentAccountID | Should -Be '12_40'
        $row.Name               | Should -Be 'new-name'
        $row.PlatformID         | Should -Be 'WinService'
        $row.ManualReason       | Should -Be 'current-reason'
        $row.Platform_Address   | Should -Be 'srv01'
    }
}

Describe 'Invoke-AccountsUpdateDependent - validation and WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } { script:New-OkResponse -Data (script:New-Current) }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } { script:New-OkResponse -Data $null }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'DU12 - WhatIf: no PUT (only the read-only GET), success with Status WhatIf and the merged values' {
        $r = Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40'; Name = 'new-name' } -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        $r.Successes         | Should -Be 1
        $r.Results[0].Status | Should -Be 'WhatIf'
        $r.Results[0].Name   | Should -Be 'new-name'
    }

    It 'DU13 - missing DependentAccountID: Failures=1, no API call' {
        $r = Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{ AccountID = '12_34'; Name = 'x' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'DU14 - missing master identifier: Failures=1, no API call' {
        $r = Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{ DependentAccountID = '12_40' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'DU15 - AutomaticManagementEnabled not true/false: Failures=1, no API call' {
        $r = Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40'; AutomaticManagementEnabled = 'off' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'DU16 - malformed PlatformAccountProperties: Failures=1, no API call' {
        $r = Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40'; PlatformAccountProperties = '=x' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }
}

Describe 'Invoke-AccountsUpdateDependent - errors' {

    BeforeEach { Mock Add-CyberArkLogSummaryEntry { } }

    It 'DU17 - 401 on the GET: IsFatal=$true, no PUT' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        $r = Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.IsFatal | Should -BeTrue
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'DU18 - 404 on the GET: API message plus the 14.6 hint, not fatal, no PUT' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -Message 'ERR404: Not found' }
        $r = Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.IsFatal                | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'ERR404: Not found'
        $r.Errors[0].ErrorMessage | Should -Match 'older than 14\.6'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'DU19 - 401 on the PUT: IsFatal=$true' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } { script:New-OkResponse -Data (script:New-Current) }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        $r = Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.IsFatal  | Should -BeTrue
        $r.Failures | Should -Be 1
    }

    It 'DU20 - 400 on the PUT: API message recorded unchanged, not fatal' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } { script:New-OkResponse -Data (script:New-Current) }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } { script:New-ErrResponse -StatusCode 400 -Message 'PASWS999E: bad' }
        $r = Invoke-AccountsUpdateDependent -Token $script:Token -InputData @{ AccountID = '12_34'; DependentAccountID = '12_40' }
        $r.IsFatal                | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Be 'PASWS999E: bad'
    }
}
