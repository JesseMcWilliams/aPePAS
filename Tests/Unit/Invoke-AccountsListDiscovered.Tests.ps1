#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsListDiscovered.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsListDiscovered.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsListDiscoveredTests' -MinLevel 'ERROR'

    $script:Token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }

    $script:Sample = [PSCustomObject]@{
        id = 'd-1'; name = 'srv01-admin'; userName = 'admin'; address = 'srv01.example.com'
        platformType = 'Windows Server Local'; privileged = $true; privilegedCriteria = 'Administrators'
        accountEnabled = $true; discoveryDateTime = 1801353600; numberOfDependencies = 2; numberOfTrusts = 0
    }
    function script:New-ListResponse {
        param([object[]]$Items)
        [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null
                           Data = [PSCustomObject]@{ value = $Items; count = @($Items).Count } }
    }
    function script:New-ErrResponse {
        param([int]$StatusCode, [string]$Message = 'Error')
        [PSCustomObject]@{ IsSuccess = $false; StatusCode = $StatusCode; ErrorMessage = $Message
                           ErrorDetails = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $Message }; Data = $null }
    }
}

Describe 'Invoke-AccountsListDiscovered - ModuleMeta' {

    It 'LD01 - Accounts / ListDiscovered, Self-Hosted only, read-only list' {
        $ModuleMeta.Category         | Should -Be 'Accounts'
        $ModuleMeta.Action           | Should -Be 'ListDiscovered'
        $ModuleMeta.SupportedSystems | Should -Be @('SelfHosted')
        $ModuleMeta.SupportsWhatIf   | Should -BeFalse
        $ModuleMeta.ProducesOutput   | Should -BeTrue
    }
}

Describe 'Invoke-AccountsListDiscovered - requests' {

    BeforeEach { Mock Invoke-CyberArkAPI { script:New-ListResponse -Items @($script:Sample) } }

    It 'LD02 - no criteria: GET /API/DiscoveredAccounts with no query parameters (paging left to Invoke-CyberArkAPI)' {
        Invoke-AccountsListDiscovered -Token $script:Token -InputData @{} | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq '/API/DiscoveredAccounts' -and $QueryParams.Count -eq 0 -and $PageSize -ne 0
        }
    }

    It 'LD03 - Search, SearchType and Sort become query parameters' {
        Invoke-AccountsListDiscovered -Token $script:Token -InputData @{ Search = 'admin'; SearchType = 'startswith'; Sort = 'userName desc' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $QueryParams['search'] -eq 'admin' -and $QueryParams['searchType'] -eq 'startswith' -and $QueryParams['sort'] -eq 'userName desc'
        }
    }

    It 'LD04 - filters are joined with AND, a value with spaces is quoted, booleans are lower-case' {
        Invoke-AccountsListDiscovered -Token $script:Token -InputData @{ PlatformType = 'Windows Server Local'; Privileged = 'TRUE' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $QueryParams['filter'] -match 'platformType eq "Windows Server Local"' -and
            $QueryParams['filter'] -match 'privileged eq true' -and
            $QueryParams['filter'] -match ' AND '
        }
    }

    It 'LD05 - Privileged that is not true/false fails the run with no API call' {
        $r = Invoke-AccountsListDiscovered -Token $script:Token -InputData @{ Privileged = 'yes' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }
}

Describe 'Invoke-AccountsListDiscovered - results' {

    It 'LD06 - maps rows: ID, user, address, platform type, privileged, dependency count, local discovery date' {
        Mock Invoke-CyberArkAPI { script:New-ListResponse -Items @($script:Sample) }
        $r = Invoke-AccountsListDiscovered -Token $script:Token -InputData @{}
        $r.Successes | Should -Be 1
        $row = $r.Results[0]
        $row.DiscoveredAccountID | Should -Be 'd-1'
        $row.UserName            | Should -Be 'admin'
        $row.Address             | Should -Be 'srv01.example.com'
        $row.PlatformType        | Should -Be 'Windows Server Local'
        $row.Privileged          | Should -BeTrue
        $row.Dependencies        | Should -Be 2
        $row.DiscoveryDate       | Should -Be ([DateTimeOffset]::FromUnixTimeSeconds(1801353600).LocalDateTime.ToString('yyyy-MM-dd HH:mm'))
    }

    It 'LD07 - empty list is not a failure' {
        Mock Invoke-CyberArkAPI { script:New-ListResponse -Items @() }
        $r = Invoke-AccountsListDiscovered -Token $script:Token -InputData @{}
        $r.Failures  | Should -Be 0
        $r.Successes | Should -Be 0
    }

    It 'LD08 - 403 (not Vault Admins / PVWAAccountsFeedAdmins) keeps the API message, not fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 403 -Message 'ERR403: no permission' }
        $r = Invoke-AccountsListDiscovered -Token $script:Token -InputData @{}
        $r.IsFatal                | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'ERR403: no permission'
    }

    It 'LD09 - 404 adds the PVWA 11.6 hint; 401 is fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -Message 'ERR404: not found' }
        (Invoke-AccountsListDiscovered -Token $script:Token -InputData @{}).Errors[0].ErrorMessage | Should -Match '11\.6'
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        (Invoke-AccountsListDiscovered -Token $script:Token -InputData @{}).IsFatal | Should -BeTrue
    }
}
