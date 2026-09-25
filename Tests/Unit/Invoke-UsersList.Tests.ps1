#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Users\Invoke-UsersList.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-UsersListInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Users\Invoke-UsersList.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-UsersList into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'UsersListTests' -MinLevel 'ERROR'

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

    # Factory: build a mock API success response containing the given user objects.
    # Users API uses a 'Users' property (not 'value').
    function script:New-UsersApiResponse {
        param([object[]]$Users = @())
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = [PSCustomObject]@{
                Users = $Users
                Total = $Users.Count
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

    # A sample user object matching the CyberArk API shape
    $script:SampleUser = [PSCustomObject]@{
        id              = 100
        username        = 'john.doe'
        userType        = 'EPVUser'
        source          = 'CyberArk'
        componentUser   = $false
        personalDetails = [PSCustomObject]@{
            email     = 'john@company.com'
            firstName = 'John'
            lastName  = 'Doe'
        }
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'UL01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'UL02 - required fields are all present' {
        $ModuleMeta.Name             | Should -Not -BeNullOrEmpty
        $ModuleMeta.Category         | Should -Not -BeNullOrEmpty
        $ModuleMeta.Action           | Should -Not -BeNullOrEmpty
        $ModuleMeta.SupportedSystems | Should -Not -BeNullOrEmpty
        $ModuleMeta.Version          | Should -Not -BeNullOrEmpty
    }

    It 'UL03 - SupportedSystems contains ISPSS and SelfHosted' {
        $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
    }

    It 'UL04 - SupportsWhatIf is $false (list operation)' {
        $ModuleMeta.SupportsWhatIf | Should -BeFalse
    }

    It 'UL05 - HasCustomInput is $true' {
        $ModuleMeta.HasCustomInput | Should -BeTrue
    }

    It 'UL06 - AcceptsInputFile is $false' {
        $ModuleMeta.AcceptsInputFile | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-UsersList - successful response' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-UsersApiResponse -Users @($script:SampleUser)
        }
        Mock Write-CyberArkLog { }
    }

    It 'UL07 - returns a result object with all 9 required fields' {
        $r = Invoke-UsersList -Token $script:MockToken
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

    It 'UL08 - single user: Successes=1, ItemsProcessed=1, Failures=0' {
        $r = Invoke-UsersList -Token $script:MockToken
        $r.Successes      | Should -Be 1
        $r.ItemsProcessed | Should -Be 1
        $r.Failures       | Should -Be 0
    }

    It 'UL09 - multiple users: count matches Users array' {
        $user2 = $script:SampleUser.PSObject.Copy()
        $user2.username = 'jane.smith'
        Mock Invoke-CyberArkAPI {
            script:New-UsersApiResponse -Users @($script:SampleUser, $user2)
        }
        $r = Invoke-UsersList -Token $script:MockToken
        $r.Successes | Should -Be 2
    }

    It 'UL10 - id is mapped to UserID' {
        $r = Invoke-UsersList -Token $script:MockToken
        $r.Results[0].UserID | Should -Be 100
    }

    It 'UL11 - username is mapped to Username' {
        $r = Invoke-UsersList -Token $script:MockToken
        $r.Results[0].Username | Should -Be 'john.doe'
    }

    It 'UL12 - personalDetails.email is mapped to Email' {
        $r = Invoke-UsersList -Token $script:MockToken
        $r.Results[0].Email | Should -Be 'john@company.com'
    }

    It 'UL13 - personalDetails.firstName is mapped to FirstName' {
        $r = Invoke-UsersList -Token $script:MockToken
        $r.Results[0].FirstName | Should -Be 'John'
    }

    It 'UL14 - personalDetails.lastName is mapped to LastName' {
        $r = Invoke-UsersList -Token $script:MockToken
        $r.Results[0].LastName | Should -Be 'Doe'
    }

    It 'UL15 - null personalDetails does not throw and returns empty strings' {
        $userNoDetails = [PSCustomObject]@{
            id = 200; username = 'svc.account'; userType = 'BasicUser'
            source = 'CyberArk'; componentUser = $true; personalDetails = $null
        }
        Mock Invoke-CyberArkAPI { script:New-UsersApiResponse -Users @($userNoDetails) }
        $r = Invoke-UsersList -Token $script:MockToken
        $r.Results[0].Email     | Should -Be ''
        $r.Results[0].FirstName | Should -Be ''
        $r.Results[0].LastName  | Should -Be ''
    }

    It 'UL16 - IsFatal is $false on success' {
        $r = Invoke-UsersList -Token $script:MockToken
        $r.IsFatal | Should -BeFalse
    }

    It 'UL17 - Users API response uses Users property (not value)' {
        # Confirm the factory sets Data.Users, not Data.value
        $apiResponse = script:New-UsersApiResponse -Users @($script:SampleUser)
        $apiResponse.Data.PSObject.Properties.Name | Should -Contain 'Users'
        $apiResponse.Data.PSObject.Properties.Name | Should -Not -Contain 'value'
    }

    It 'UL18 - Search value is passed in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-UsersApiResponse
        }
        Invoke-UsersList -Token $script:MockToken -InputData @{ Search = 'john'; UserType = '' }
        $script:capturedParams.QueryParams['search'] | Should -Be 'john'
    }

    It 'UL19 - UserType value is passed in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-UsersApiResponse
        }
        Invoke-UsersList -Token $script:MockToken -InputData @{ Search = ''; UserType = 'EPVUser' }
        $script:capturedParams.QueryParams['UserType'] | Should -Be 'EPVUser'
    }

    It 'UL20 - empty Search string means no search key in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-UsersApiResponse
        }
        Invoke-UsersList -Token $script:MockToken -InputData @{ Search = ''; UserType = '' }
        $script:capturedParams.QueryParams.ContainsKey('search') | Should -BeFalse
    }

    It 'UL21 - empty UserType string means no UserType key in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-UsersApiResponse
        }
        Invoke-UsersList -Token $script:MockToken -InputData @{ Search = ''; UserType = '' }
        $script:capturedParams.QueryParams.ContainsKey('UserType') | Should -BeFalse
    }

    It 'UL22 - null InputData does not throw' {
        { Invoke-UsersList -Token $script:MockToken -InputData $null } | Should -Not -Throw
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-UsersList - empty result' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-UsersApiResponse -Users @() }
        Mock Write-CyberArkLog { }
    }

    It 'UL - empty Users array: Successes=0, Failures=0, IsFatal=$false' {
        $r = Invoke-UsersList -Token $script:MockToken
        $r.Successes | Should -Be 0
        $r.Failures  | Should -Be 0
        $r.IsFatal   | Should -BeFalse
    }

    It 'UL - response with no Users property does not throw' {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{
                IsSuccess = $true; StatusCode = 200; StatusMessage = 'OK'
                ErrorMessage = $null; ErrorDetails = $null; DataType = 'JSON'
                RawResponse = '{}'; Data = [PSCustomObject]@{ Total = 0 }   # no 'Users' property
            }
        }
        { Invoke-UsersList -Token $script:MockToken } | Should -Not -Throw
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-UsersList - API errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'UL - 403 Forbidden: error added, IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-UsersList -Token $script:MockToken
        $r.Failures        | Should -Be 1
        $r.Errors.Count    | Should -Be 1
        $r.IsFatal         | Should -BeFalse
    }

    It 'UL - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-UsersList -Token $script:MockToken
        $r.IsFatal | Should -BeTrue
    }

    It 'UL - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-UsersList -Token $script:MockToken
        $r.IsFatal | Should -BeTrue
    }

    It 'UL - 404 Not Found: IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        $r = Invoke-UsersList -Token $script:MockToken
        $r.IsFatal | Should -BeFalse
    }

    It 'UL - error entry ErrorMessage is not null or empty' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-UsersList -Token $script:MockToken
        $r.Errors[0].ErrorMessage | Should -Not -BeNullOrEmpty
    }

    It 'UL - ItemsProcessed incremented on failure' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 500 -ErrorMessage 'Server Error' }
        $r = Invoke-UsersList -Token $script:MockToken
        $r.ItemsProcessed | Should -Be 1
    }
}
