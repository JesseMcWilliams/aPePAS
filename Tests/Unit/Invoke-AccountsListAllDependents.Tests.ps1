#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsListAllDependents.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsListAllDependents.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsListAllDependentsTests' -MinLevel 'ERROR'

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
        param([string]$Id = '12_40')
        [PSCustomObject]@{
            dependentAccountId        = $Id
            accountId                 = '12_34'
            name                      = "dep-$Id"
            platformId                = 'WinService'
            safeName                  = 'WinSafe'
            createdTime               = 1700000000
            isDeleted                 = $true
            deletionTime              = 1700000500
            platformAccountProperties = [PSCustomObject]@{ Address = 'srv01' }
            secretManagement          = [PSCustomObject]@{ automaticManagementEnabled = $false; manualManagementReason = 'window'; status = 'failure' }
        }
    }
}

Describe 'Invoke-AccountsListAllDependents - ModuleMeta' {

    It 'DW01 - Category, Action, Name, Version and Priority are set' {
        $ModuleMeta.Category | Should -Be 'Accounts'
        $ModuleMeta.Action   | Should -Be 'ListAllDependents'
        $ModuleMeta.Name     | Should -Be 'List All Dependent Accounts'
        $ModuleMeta.Version  | Should -Be '1.0.0'
        $ModuleMeta.Priority | Should -Be 51
    }

    It 'DW02 - read action: SupportsWhatIf and AcceptsInputFile are $false; ProducesOutput and HasCustomInput are $true' {
        $ModuleMeta.SupportsWhatIf   | Should -BeFalse
        $ModuleMeta.AcceptsInputFile | Should -BeFalse
        $ModuleMeta.ProducesOutput   | Should -BeTrue
        $ModuleMeta.HasCustomInput   | Should -BeTrue
    }

    It 'DW03 - SupportedSystems is SelfHosted only' {
        @($ModuleMeta.SupportedSystems) | Should -Be @('SelfHosted')
    }
}

Describe 'Invoke-AccountsListAllDependents - success' {

    BeforeEach { Mock Add-CyberArkLogSummaryEntry { } }

    It 'DW04 - no input: one GET to /API/DependentAccounts with normal paging and no filter' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data ([PSCustomObject]@{ value = @((script:New-Dependent)); Total = 1 }) }
        $r = Invoke-AccountsListAllDependents -Token $script:Token -InputData @{}
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq '/API/DependentAccounts' -and -not $PSBoundParameters.ContainsKey('PageSize') -and $QueryParams.Count -eq 0
        }
    }

    It 'DW05 - maps columns including IsDeleted, Deleted, ManualReason and Platform_ columns' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data ([PSCustomObject]@{ value = @((script:New-Dependent)); Total = 1 }) }
        $row = (Invoke-AccountsListAllDependents -Token $script:Token -InputData @{}).Results[0]
        $row.MasterAccountID    | Should -Be '12_34'
        $row.DependentAccountID | Should -Be '12_40'
        $row.IsDeleted          | Should -BeTrue
        $row.Deleted            | Should -Be (ConvertFrom-CyberArkExpirationTime 1700000500)
        $row.Created            | Should -Be (ConvertFrom-CyberArkExpirationTime 1700000000)
        $row.AutoManaged        | Should -BeFalse
        $row.ManualReason       | Should -Be 'window'
        $row.CPMStatus          | Should -Be 'failure'
        $row.Platform_Address   | Should -Be 'srv01'
    }

    It 'DW06 - SafeName and PlatformID build the filter; no master-account filter is sent (PASWS357E live); Search and IncludeDeleted are query params' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data @() }
        Invoke-AccountsListAllDependents -Token $script:Token -InputData @{
            SafeName = 'Win Safe'; PlatformID = 'WinService'; MasterAccountID = '12_34'; Search = 'svc'; IncludeDeleted = 'True'
        } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $f = "$($QueryParams['filter'])"
            $f -notmatch '(?i)accountId' -and $f -match 'platformId eq WinService' -and $f -match 'SafeName eq "Win Safe"' -and
            ([regex]::Matches($f, ' AND ')).Count -eq 1 -and
            $QueryParams['search'] -eq 'svc' -and $QueryParams['includeDeleted'] -eq 'true'
        }
    }

    It 'DW07 - bare array response with fewer items than a page: no extra page request' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data @((script:New-Dependent -Id '1_1'), (script:New-Dependent -Id '1_2')) }
        $r = Invoke-AccountsListAllDependents -Token $script:Token -InputData @{}
        $r.Results.Count | Should -Be 2
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly
    }

    It 'DW08 - bare array response filling a page: fetches the next page by offset with -PageSize 0' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1); PageSize = 2 }
        Mock Invoke-CyberArkAPI -ParameterFilter { -not $QueryParams.ContainsKey('offset') } {
            script:New-OkResponse -Data @((script:New-Dependent -Id '1_1'), (script:New-Dependent -Id '1_2'))
        }
        Mock Invoke-CyberArkAPI -ParameterFilter { $QueryParams['offset'] -eq 2 } {
            script:New-OkResponse -Data @((script:New-Dependent -Id '1_3'))
        }
        $r = Invoke-AccountsListAllDependents -Token $token -InputData @{}
        $r.Results.Count | Should -Be 3
        $r.Results[2].DependentAccountID | Should -Be '1_3'
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $QueryParams['offset'] -eq 2 -and $QueryParams['limit'] -eq 2 -and $PageSize -eq 0 }
    }

    It 'DW09 - bare array paging stops when the server repeats the same page' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1); PageSize = 2 }
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data @((script:New-Dependent -Id '1_1'), (script:New-Dependent -Id '1_2')) }
        $r = Invoke-AccountsListAllDependents -Token $token -InputData @{}
        $r.Results.Count | Should -Be 2
        Should -Invoke Invoke-CyberArkAPI -Times 2 -Exactly
    }

    It 'DW10 - empty result: no rows, no failures' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data ([PSCustomObject]@{ value = @(); Total = 0 }) }
        $r = Invoke-AccountsListAllDependents -Token $script:Token -InputData @{}
        $r.Results.Count | Should -Be 0
        $r.Failures      | Should -Be 0
    }
}

Describe 'Invoke-AccountsListAllDependents - validation and errors' {

    BeforeEach { Mock Add-CyberArkLogSummaryEntry { } }

    It 'DW11 - IncludeDeleted that is not true/false: Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data @() }
        $r = Invoke-AccountsListAllDependents -Token $script:Token -InputData @{ IncludeDeleted = 'maybe' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'DW12 - 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        $r = Invoke-AccountsListAllDependents -Token $script:Token -InputData @{}
        $r.IsFatal  | Should -BeTrue
        $r.Failures | Should -Be 1
    }

    It 'DW13 - 404: message keeps the API ErrorCode/ErrorMessage and adds the 14.6 hint, not fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -Message 'ERR404: Not found' }
        $r = Invoke-AccountsListAllDependents -Token $script:Token -InputData @{}
        $r.IsFatal                | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'ERR404: Not found'
        $r.Errors[0].ErrorMessage | Should -Match 'older than 14\.6'
    }
}
