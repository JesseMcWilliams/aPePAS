#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsAddDependent.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsAddDependent.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsAddDependentTests' -MinLevel 'ERROR'

    $script:Token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }

    function script:New-OkResponse {
        param([object]$Data = [PSCustomObject]@{}, [int]$StatusCode = 201)
        [PSCustomObject]@{ IsSuccess = $true; StatusCode = $StatusCode; ErrorMessage = ''; ErrorDetails = $null; Data = $Data }
    }
    function script:New-ErrResponse {
        param([int]$StatusCode, [string]$Message = 'Error')
        [PSCustomObject]@{ IsSuccess = $false; StatusCode = $StatusCode; ErrorMessage = $Message
                           ErrorDetails = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $Message }; Data = $null }
    }
    function script:New-Created {
        [PSCustomObject]@{
            dependentAccountId        = '12_40'
            accountId                 = '12_34'
            name                      = 'dep-svc'
            platformId                = 'WinService'
            platformAccountProperties = [PSCustomObject]@{ Address = 'srv01'; ServiceName = 'svcA' }
            secretManagement          = [PSCustomObject]@{ automaticManagementEnabled = $false; manualManagementReason = 'window' }
        }
    }
}

Describe 'Invoke-AccountsAddDependent - ModuleMeta' {

    It 'DA01 - Category, Action, Name, Version and Priority are set' {
        $ModuleMeta.Category | Should -Be 'Accounts'
        $ModuleMeta.Action   | Should -Be 'AddDependent'
        $ModuleMeta.Name     | Should -Be 'Add Dependent Account'
        $ModuleMeta.Version  | Should -Be '1.0.0'
        $ModuleMeta.Priority | Should -Be 53
    }

    It 'DA02 - write action: SupportsWhatIf, AcceptsInputFile, ProducesOutput and HasCustomInput are $true' {
        $ModuleMeta.SupportsWhatIf   | Should -BeTrue
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.ProducesOutput   | Should -BeTrue
        $ModuleMeta.HasCustomInput   | Should -BeTrue
    }

    It 'DA03 - InputSchema columns; only PlatformID is required' {
        $cols = @($ModuleMeta.InputSchema | ForEach-Object { $_['Column'] })
        $cols | Should -Be @('AccountID', 'AccountName', 'UserName', 'Safe', 'Name', 'PlatformID', 'AutomaticManagementEnabled', 'ManualManagementReason', 'PlatformAccountProperties')
        @($ModuleMeta.InputSchema | Where-Object { $_['Required'] } | ForEach-Object { $_['Column'] }) | Should -Be @('PlatformID')
    }

    It 'DA04 - SupportedSystems is SelfHosted only' {
        @($ModuleMeta.SupportedSystems) | Should -Be @('SelfHosted')
    }
}

Describe 'Invoke-AccountsAddDependent - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data (script:New-Created) }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'DA05 - POSTs to /API/Accounts/{id}/DependentAccounts with name, platformId, platformAccountProperties and secretManagement' {
        Invoke-AccountsAddDependent -Token $script:Token -InputData @{
            AccountID = '12_34'; Name = 'dep-svc'; PlatformID = 'WinService'
            PlatformAccountProperties = 'Address=srv01; ServiceName=svcA'
            AutomaticManagementEnabled = 'False'; ManualManagementReason = 'window'
        } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Accounts/12_34/DependentAccounts' -and
            $Body['name'] -eq 'dep-svc' -and $Body['platformId'] -eq 'WinService' -and
            $Body['platformAccountProperties']['Address'] -eq 'srv01' -and
            $Body['platformAccountProperties']['ServiceName'] -eq 'svcA' -and
            $Body['platformAccountProperties'].Count -eq 2 -and
            $Body['secretManagement']['automaticManagementEnabled'] -eq $false -and
            $Body['secretManagement']['automaticManagementEnabled'] -is [bool] -and
            $Body['secretManagement']['manualManagementReason'] -eq 'window'
        }
    }

    It 'DA06 - body serializes to the expected JSON fields' {
        $script:captured = $null
        Mock Invoke-CyberArkAPI { $script:captured = ConvertTo-Json -InputObject $Body -Depth 5 -Compress; script:New-OkResponse -Data (script:New-Created) }
        Invoke-AccountsAddDependent -Token $script:Token -InputData @{ AccountID = '12_34'; PlatformID = 'WinService'; PlatformAccountProperties = 'Address=srv01' } | Out-Null
        $json = $script:captured | ConvertFrom-Json
        $json.platformId                        | Should -Be 'WinService'
        $json.platformAccountProperties.Address | Should -Be 'srv01'
        $json.PSObject.Properties['name']             | Should -BeNullOrEmpty
        $json.PSObject.Properties['secretManagement'] | Should -BeNullOrEmpty
    }

    It 'DA07 - only PlatformID given: body has platformId only' {
        Invoke-AccountsAddDependent -Token $script:Token -InputData @{ AccountID = '12_34'; PlatformID = 'WinService' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Body.Count -eq 1 -and $Body['platformId'] -eq 'WinService'
        }
    }

    It 'DA08 - Platform_ prefixed columns are read and win over the same key in PlatformAccountProperties; blanks are skipped' {
        Invoke-AccountsAddDependent -Token $script:Token -InputData @{
            AccountID = '12_34'; PlatformID = 'WinService'
            PlatformAccountProperties = 'Address=old;Port=1'
            Platform_Address = 'srv02'; Platform_ServiceName = 'svcB'; Platform_Empty = ' '
        } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $p = $Body['platformAccountProperties']
            $p['Address'] -eq 'srv02' -and $p['ServiceName'] -eq 'svcB' -and $p['Port'] -eq '1' -and -not $p.ContainsKey('Empty')
        }
    }

    It 'DA09 - result row comes from the 201 response: DependentAccountID, Status Added, Platform_ columns' {
        $r = Invoke-AccountsAddDependent -Token $script:Token -InputData @{ AccountID = '12_34'; PlatformID = 'WinService' }
        $r.Successes | Should -Be 1
        $row = $r.Results[0]
        $row.DependentAccountID   | Should -Be '12_40'
        $row.MasterAccountID      | Should -Be '12_34'
        $row.Name                 | Should -Be 'dep-svc'
        $row.Status               | Should -Be 'Added'
        $row.AutoManaged          | Should -BeFalse
        $row.ManualReason         | Should -Be 'window'
        $row.Platform_ServiceName | Should -Be 'svcA'
    }

    It 'DA10 - empty response body: success with input values and blank DependentAccountID' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data $null }
        $r = Invoke-AccountsAddDependent -Token $script:Token -InputData @{ AccountID = '12_34'; PlatformID = 'WinService'; Name = 'n1' }
        $r.Successes                     | Should -Be 1
        $r.Results[0].DependentAccountID | Should -Be ''
        $r.Results[0].Name               | Should -Be 'n1'
    }
}

Describe 'Invoke-AccountsAddDependent - validation and WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data (script:New-Created) }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'DA11 - WhatIf: no API call, success with Status WhatIf' {
        $r = Invoke-AccountsAddDependent -Token $script:Token -InputData @{ AccountID = '12_34'; PlatformID = 'WinService' } -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
        $r.Successes         | Should -Be 1
        $r.Results[0].Status | Should -Be 'WhatIf'
    }

    It 'DA12 - missing PlatformID: Failures=1, no API call' {
        $r = Invoke-AccountsAddDependent -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'PlatformID'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'DA13 - missing master identifier: Failures=1, no API call' {
        $r = Invoke-AccountsAddDependent -Token $script:Token -InputData @{ PlatformID = 'WinService' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'DA14 - malformed PlatformAccountProperties: Failures=1, no API call' {
        $r = Invoke-AccountsAddDependent -Token $script:Token -InputData @{ AccountID = '12_34'; PlatformID = 'WinService'; PlatformAccountProperties = 'Address' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'Key=Value'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'DA15 - AutomaticManagementEnabled not true/false: Failures=1, no API call' {
        $r = Invoke-AccountsAddDependent -Token $script:Token -InputData @{ AccountID = '12_34'; PlatformID = 'WinService'; AutomaticManagementEnabled = 'no' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }
}

Describe 'Invoke-AccountsAddDependent - errors' {

    BeforeEach { Mock Add-CyberArkLogSummaryEntry { } }

    It 'DA16 - 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        $r = Invoke-AccountsAddDependent -Token $script:Token -InputData @{ AccountID = '12_34'; PlatformID = 'WinService' }
        $r.IsFatal | Should -BeTrue
    }

    It 'DA17 - 404: message keeps the API ErrorCode/ErrorMessage and adds the 14.6 hint, not fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -Message 'ERR404: Not found' }
        $r = Invoke-AccountsAddDependent -Token $script:Token -InputData @{ AccountID = '12_34'; PlatformID = 'WinService' }
        $r.IsFatal                | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'ERR404: Not found'
        $r.Errors[0].ErrorMessage | Should -Match 'older than 14\.6'
    }

    It 'DA18 - 400 (for example a missing platform property): API message recorded unchanged' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 400 -Message 'PASWS999E: bad property' }
        $r = Invoke-AccountsAddDependent -Token $script:Token -InputData @{ AccountID = '12_34'; PlatformID = 'WinService' }
        $r.IsFatal                | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Be 'PASWS999E: bad property'
    }
}
