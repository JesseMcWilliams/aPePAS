#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Groups\Invoke-GroupsList.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-GroupsListInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Groups\Invoke-GroupsList.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-GroupsList into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'GroupsListTests' -MinLevel 'ERROR'

    # Minimal token stub
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'ISPSS'
        AuthMethod = 'ClientCredentials'
        BaseURL    = 'https://test.privilegecloud.cyberark.cloud'
    }

    # Factory: build a mock API success response containing the given group objects.
    # Groups API uses a 'value' property (not 'Users').
    function script:New-GroupsApiResponse {
        param([object[]]$Groups = @())
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = [PSCustomObject]@{
                value = $Groups
                count = $Groups.Count
            }
        }
    }

    # Factory: build a mock API failure response
    function script:New-ApiErrorResponse {
        param([int]$StatusCode = 403, [string]$ErrorMessage = 'Forbidden')
        return [PSCustomObject]@{
            IsSuccess     = $false
            StatusCode    = $StatusCode
            StatusMessage = "HTTP $StatusCode"
            ErrorMessage  = $ErrorMessage
            ErrorDetails  = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $ErrorMessage; Details = $null }
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $null
        }
    }

    # Sample group objects matching the CyberArk UserGroups API shape
    $script:SampleGroup = [PSCustomObject]@{
        id          = 1
        groupName   = 'VaultAdmins'
        description = 'Vault administrators'
        location    = '\'
        groupType   = 'EPVGroup'
        directory   = $null
    }

    $script:SampleGroup2 = [PSCustomObject]@{
        id          = 2
        groupName   = 'DomainAdmins'
        description = 'Domain admin group'
        location    = '\'
        groupType   = 'LDAP'
        directory   = [PSCustomObject]@{
            directoryType = 'MicrosoftADDomain'
            domainName    = 'corp.example.com'
        }
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'GL01 - ModuleMeta.Name = ''List Groups''' {
        $ModuleMeta.Name | Should -Be 'List Groups'
    }

    It 'GL02 - ModuleMeta.Category = ''Groups''' {
        $ModuleMeta.Category | Should -Be 'Groups'
    }

    It 'GL03 - ModuleMeta.SupportsWhatIf = $false' {
        $ModuleMeta.SupportsWhatIf | Should -BeFalse
    }

    It 'GL04 - ModuleMeta.ProducesOutput = $true' {
        $ModuleMeta.ProducesOutput | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsList - successful response' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-GroupsApiResponse -Groups @($script:SampleGroup, $script:SampleGroup2)
        }
        Mock Write-CyberArkLog { }
    }

    It 'GL05 - Successes=2, ItemsProcessed=2 when two groups returned' {
        $r = Invoke-GroupsList -Token $script:MockToken
        $r.Successes      | Should -Be 2
        $r.ItemsProcessed | Should -Be 2
    }

    It 'GL06 - result entries have GroupID, GroupName, Description, Location, GroupType, DirectoryType' {
        $r = Invoke-GroupsList -Token $script:MockToken
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'GroupID'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'GroupName'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'Description'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'Location'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'GroupType'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'DirectoryType'
    }

    It 'GL07 - GroupID matches id from response' {
        $r = Invoke-GroupsList -Token $script:MockToken
        $r.Results[0].GroupID | Should -Be 1
    }

    It 'GL08 - GroupName matches groupName from response' {
        $r = Invoke-GroupsList -Token $script:MockToken
        $r.Results[0].GroupName | Should -Be 'VaultAdmins'
    }

    It 'GL09 - DirectoryType mapped from directory.directoryType' {
        $r = Invoke-GroupsList -Token $script:MockToken
        $r.Results[1].DirectoryType | Should -Be 'MicrosoftADDomain'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsList - empty result' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-GroupsApiResponse -Groups @() }
        Mock Write-CyberArkLog { }
    }

    It 'GL10 - empty value array: Successes=0, Failures=0, IsFatal=$false' {
        $r = Invoke-GroupsList -Token $script:MockToken
        $r.Successes | Should -Be 0
        $r.Failures  | Should -Be 0
        $r.IsFatal   | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsList - query parameter passing' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'GL11 - search param is passed as query param' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters.QueryParams -Scope Script
            script:New-GroupsApiResponse
        }
        Invoke-GroupsList -Token $script:MockToken -InputData @{ Search = 'Admins'; GroupType = '' }
        $script:capturedParams['search'] | Should -Be 'Admins'
    }

    It 'GL12 - groupType param is passed as query param' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters.QueryParams -Scope Script
            script:New-GroupsApiResponse
        }
        Invoke-GroupsList -Token $script:MockToken -InputData @{ Search = ''; GroupType = 'EPVGroup' }
        $script:capturedParams['groupType'] | Should -Be 'EPVGroup'
    }

    It 'GL13 - no query params when InputData is empty' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters.QueryParams -Scope Script
            script:New-GroupsApiResponse
        }
        Invoke-GroupsList -Token $script:MockToken -InputData @{ Search = ''; GroupType = '' }
        $script:capturedParams.ContainsKey('search')    | Should -BeFalse
        $script:capturedParams.ContainsKey('groupType') | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsList - API errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'GL14 - 401 response: IsFatal=$true, Failures=1' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-GroupsList -Token $script:MockToken
        $r.IsFatal  | Should -BeTrue
        $r.Failures | Should -Be 1
    }

    It 'GL15 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-GroupsList -Token $script:MockToken
        $r.IsFatal | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsList - null InputData' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-GroupsApiResponse -Groups @() }
        Mock Write-CyberArkLog { }
    }

    It 'GL16 - null InputData treated same as empty (no crash)' {
        { Invoke-GroupsList -Token $script:MockToken -InputData $null } | Should -Not -Throw
    }
}
