#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Accounts\Invoke-AccountsList.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-AccountsListInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    Set-StrictMode -Version Latest
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsList.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-AccountsList into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsListTests' -MinLevel 'ERROR'

    # Minimal token stub
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://test.cyberark.local'
    }

    # Manage-Privilege.ps1 defines $script:ActiveProfile as a script-scoped constant, dot-sourced
    # into every module's effective scope at real runtime. This test file dot-sources only the
    # module, so $script:ActiveProfile must be faked explicitly here - same pattern as
    # Tests\Unit\Invoke-SafesAddFromTemplate.Tests.ps1's Reset-MockActiveProfile helper.
    function script:Reset-MockActiveProfile {
        $script:ActiveProfile = [PSCustomObject]@{
            IgnoreSSL = $false
        }
    }

    # Factory: build a mock API success response containing the given account objects
    function script:New-AccountsApiResponse {
        param([object[]]$Accounts = @())
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = [PSCustomObject]@{
                value = $Accounts
                count = $Accounts.Count
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

    # A sample account object matching the CyberArk v14 API shape, including the nested objects
    # and dynamic platform properties confirmed against
    # Swagger\CyberArk_PasswordVault_Swagger_14.6.v1.json's AccountModel/
    # AutomaticSecretManagement/RemoteMachinesAccess definitions.
    $script:SampleAccount = [PSCustomObject]@{
        id                        = '12345'
        name                      = 'LocalAdmin'
        address                   = 'server01.domain.com'
        userName                  = 'localadmin'
        platformId                = 'WinServerLocal'
        safeName                  = 'TestSafe'
        secretType                = 'password'
        secretManagement          = [PSCustomObject]@{
            automaticManagementEnabled = $true
            manualManagementReason     = ''
            status                     = 'success'
            lastModifiedTime           = 1700000000
            lastReconciledTime         = 0
            lastVerifiedTime           = 1700000000
        }
        remoteMachinesAccess      = [PSCustomObject]@{
            remoteMachines                    = 'host1.domain.com;host2.domain.com'
            accessRestrictedToRemoteMachines  = $true
        }
        platformAccountProperties = [PSCustomObject]@{
            LogonDomain = 'DOMAIN'
            Port        = '3389'
        }
        categoryModificationTime  = 1700000000
        deletionTime              = 0
        createdTime               = 1700000000   # 2023-11-14 (UTC)
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
    Remove-Variable -Name ActiveProfile -Scope Script -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'AL01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'AL02 - required fields are all present' {
        $ModuleMeta.Name             | Should -Not -BeNullOrEmpty
        $ModuleMeta.Category         | Should -Not -BeNullOrEmpty
        $ModuleMeta.Action           | Should -Not -BeNullOrEmpty
        $ModuleMeta.SupportedSystems | Should -Not -BeNullOrEmpty
        $ModuleMeta.Version          | Should -Not -BeNullOrEmpty
    }

    It 'AL03 - Category is Accounts' {
        $ModuleMeta.Category | Should -Be 'Accounts'
    }

    It 'AL04 - Action is List' {
        $ModuleMeta.Action | Should -Be 'List'
    }

    It 'AL05 - SupportsWhatIf is $false (list operation)' {
        $ModuleMeta.SupportsWhatIf | Should -BeFalse
    }

    It 'AL06 - AcceptsInputFile is $false' {
        $ModuleMeta.AcceptsInputFile | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsList - successful response' {

    BeforeEach {
        Set-StrictMode -Version Latest
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI {
            script:New-AccountsApiResponse -Accounts @($script:SampleAccount)
        }
        Mock Write-CyberArkLog { }
    }

    It 'AL07 - returns a result object with all 9 required fields' {
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.PSObject.Properties.Name | Should -Contain 'ModuleName'
        $r.PSObject.Properties.Name | Should -Contain 'Category'
        $r.PSObject.Properties.Name | Should -Contain 'Action'
        $r.PSObject.Properties.Name | Should -Contain 'ItemsProcessed'
        $r.PSObject.Properties.Name | Should -Contain 'Successes'
        $r.PSObject.Properties.Name | Should -Contain 'Failures'
        $r.PSObject.Properties.Name | Should -Contain 'IsFatal'
        $r.PSObject.Properties.Name | Should -Contain 'Results'
        $r.PSObject.Properties.Name | Should -Contain 'Errors'
    }

    It 'AL08 - single account: Successes=1, ItemsProcessed=1, Failures=0' {
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Successes      | Should -Be 1
        $r.ItemsProcessed | Should -Be 1
        $r.Failures       | Should -Be 0
    }

    It 'AL09 - account.id is mapped to AccountID' {
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Results[0].AccountID | Should -Be '12345'
    }

    It 'AL10 - account.userName is mapped to UserName' {
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Results[0].UserName | Should -Be 'localadmin'
    }

    It 'AL11 - account.safeName is mapped to SafeName' {
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Results[0].SafeName | Should -Be 'TestSafe'
    }

    It 'AL12 - secretManagement.automaticManagementEnabled is mapped to AutoManaged' {
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Results[0].AutoManaged | Should -BeTrue
    }

    It 'AL13 - secretManagement.status is mapped to CPMStatus' {
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Results[0].CPMStatus | Should -Be 'success'
    }

    It 'AL14 - createdTime epoch is converted to a yyyy-MM-dd string' {
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Results[0].Created | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }

    It 'AL14a - manualManagementReason and the lastModified/lastReconciled/lastVerified epochs are flattened' {
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Results[0].ManualReason    | Should -Be ''
        $r.Results[0].LastCPMModified | Should -Match '^\d{4}-\d{2}-\d{2}$'
        $r.Results[0].LastReconciled  | Should -Be ''
        $r.Results[0].LastVerified    | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }

    It 'AL14b - remoteMachinesAccess is flattened to RemoteMachines and RemoteAccessRestricted' {
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Results[0].RemoteMachines         | Should -Be 'host1.domain.com;host2.domain.com'
        $r.Results[0].RemoteAccessRestricted | Should -BeTrue
    }

    It 'AL14c - categoryModificationTime is flattened to CategoryModified' {
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Results[0].CategoryModified | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }

    It 'AL14d - platformAccountProperties keys are flattened onto Platform_-prefixed columns' {
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Results[0].Platform_LogonDomain | Should -Be 'DOMAIN'
        $r.Results[0].Platform_Port        | Should -Be '3389'
    }

    It 'AL14e - secret is never surfaced in the result, even if present on the response' {
        $acctWithSecret = [PSCustomObject]@{
            id     = '999'
            name   = 'has-secret'
            secret = 'SuperSecretPassword123!'
        }
        Mock Invoke-CyberArkAPI { script:New-AccountsApiResponse -Accounts @($acctWithSecret) }
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Results[0].PSObject.Properties.Name | Should -Not -Contain 'Secret'
        $r.Results[0].PSObject.Properties.Name | Should -Not -Contain 'secret'
    }

    It 'AL14f - accounts with different platform properties are backfilled to the same full column set' {
        $acctA = [PSCustomObject]@{
            id                        = 'A'
            name                      = 'account-a'
            platformAccountProperties = [PSCustomObject]@{ LogonDomain = 'DOMAIN' }
        }
        $acctB = [PSCustomObject]@{
            id                        = 'B'
            name                      = 'account-b'
            platformAccountProperties = [PSCustomObject]@{ Port = '22' }
        }
        Mock Invoke-CyberArkAPI { script:New-AccountsApiResponse -Accounts @($acctA, $acctB) }
        $r = Invoke-AccountsList -Token $script:MockToken

        # Both rows must carry both columns (union of the two accounts' platform keys) so
        # Export-Csv - which only reads headers from the first row in PS 5.1 - doesn't silently
        # drop a column that only the second account happened to have.
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'Platform_LogonDomain'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'Platform_Port'
        $r.Results[1].PSObject.Properties.Name | Should -Contain 'Platform_LogonDomain'
        $r.Results[1].PSObject.Properties.Name | Should -Contain 'Platform_Port'

        $r.Results[0].Platform_LogonDomain | Should -Be 'DOMAIN'
        $r.Results[0].Platform_Port        | Should -Be ''
        $r.Results[1].Platform_LogonDomain | Should -Be ''
        $r.Results[1].Platform_Port        | Should -Be '22'
    }

    It 'AL15 - IsFatal is $false on success' {
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.IsFatal | Should -BeFalse
    }

    It 'AL16 - empty value array: Successes=0, Failures=0, IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-AccountsApiResponse -Accounts @() }
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Successes | Should -Be 0
        $r.Failures  | Should -Be 0
        $r.IsFatal   | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsList - query parameters' {

    BeforeEach {
        Set-StrictMode -Version Latest
        script:Reset-MockActiveProfile
        Mock Write-CyberArkLog { }
    }

    It 'AL17 - Search value is passed in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-AccountsApiResponse
        }
        Invoke-AccountsList -Token $script:MockToken -InputData @{ Search = 'localadmin'; Filter = '' }
        $script:capturedParams.QueryParams['search'] | Should -Be 'localadmin'
    }

    It 'AL18 - Filter value is passed in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-AccountsApiResponse
        }
        Invoke-AccountsList -Token $script:MockToken -InputData @{ Search = ''; Filter = 'safeName eq TestSafe' }
        $script:capturedParams.QueryParams['filter'] | Should -Be 'safeName eq TestSafe'
    }

    It 'AL19 - empty Search string means no search key in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-AccountsApiResponse
        }
        Invoke-AccountsList -Token $script:MockToken -InputData @{ Search = ''; Filter = '' }
        $script:capturedParams.QueryParams.ContainsKey('search') | Should -BeFalse
    }

    It 'AL20 - empty Filter string means no filter key in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-AccountsApiResponse
        }
        Invoke-AccountsList -Token $script:MockToken -InputData @{ Search = ''; Filter = '' }
        $script:capturedParams.QueryParams.ContainsKey('filter') | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsList - By-Safe iteration' {

    BeforeEach {
        Set-StrictMode -Version Latest
        script:Reset-MockActiveProfile
        Mock Write-CyberArkLog { }
    }

    It 'AL20a - a safe name with spaces is quoted in the per-safe filter, matching psPAS''s ConvertTo-FilterString behavior' {
        # Regression test: a raw "safeName eq $safeName" string interpolation (this code path's
        # original implementation) sends an unquoted value for a multi-word safe name, which
        # CyberArk's filter grammar requires to be wrapped in double quotes (URL-encoded to %22)
        # - confirmed against psPAS's own ConvertTo-FilterString.ps1. Fixed by routing through
        # the shared, already-tested New-CyberArkSearchFilter helper.
        $capturedFilters = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            if ($Endpoint -eq '/API/Safes') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ value = @([PSCustomObject]@{ safeName = 'My Safe' }) } }
            } else {
                $capturedFilters.Add($QueryParams['filter']) | Out-Null
                script:New-AccountsApiResponse
            }
        }
        Invoke-AccountsList -Token $script:MockToken -InputData @{ IterateBySafe = $true } | Out-Null
        $capturedFilters[0] | Should -Be 'safeName eq "My Safe"'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsList - API errors' {

    BeforeEach {
        Set-StrictMode -Version Latest
        script:Reset-MockActiveProfile
        Mock Write-CyberArkLog { }
    }

    It 'AL21 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.IsFatal | Should -BeTrue
    }

    It 'AL22 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.IsFatal | Should -BeTrue
    }

    It 'AL23 - 403 Forbidden: error added, IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Failures     | Should -Be 1
        $r.Errors.Count | Should -Be 1
        $r.IsFatal      | Should -BeFalse
    }

    It 'AL24 - 404 Not Found: IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.IsFatal | Should -BeFalse
    }

    It 'AL25 - error entry ErrorMessage is not null or empty' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-AccountsList -Token $script:MockToken
        $r.Errors[0].ErrorMessage | Should -Not -BeNullOrEmpty
    }
}
