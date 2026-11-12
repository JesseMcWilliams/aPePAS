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

    # A sample user matching the 14.6 UserSummary model (no email field anywhere - F94)
    $script:SampleUser = [PSCustomObject]@{
        id              = 100
        username        = 'john.doe'
        userType        = 'EPVUser'
        source          = 'CyberArk'
        componentUser   = $false
        enableUser      = $true
        suspended       = $false
        location        = '\'
        personalDetails = [PSCustomObject]@{
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

    It 'UL12 - no Email column (UserSummary has no email field; F94)' {
        $r = Invoke-UsersList -Token $script:MockToken
        $r.Results[0].PSObject.Properties.Name | Should -Not -Contain 'Email'
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
        $r.Results[0].FirstName | Should -Be ''
        $r.Results[0].LastName  | Should -Be ''
    }

    It 'UL16 - IsFatal is $false on success' {
        $r = Invoke-UsersList -Token $script:MockToken
        $r.IsFatal | Should -BeFalse
    }

    It 'UL23 - enableUser, suspended and location mapped to Enabled, Suspended, Location' {
        $r = Invoke-UsersList -Token $script:MockToken
        $r.Results[0].Enabled   | Should -BeTrue
        $r.Results[0].Suspended | Should -BeFalse
        $r.Results[0].Location  | Should -Be '\'
    }

    It 'UL24 - missing enableUser, suspended and location give empty values' {
        $bare = [PSCustomObject]@{ id = 300; username = 'bare'; userType = 'EPVUser'; source = 'CyberArk'; componentUser = $false }
        Mock Invoke-CyberArkAPI { script:New-UsersApiResponse -Users @($bare) }
        $r = Invoke-UsersList -Token $script:MockToken
        $r.Results[0].Enabled   | Should -Be ''
        $r.Results[0].Suspended | Should -Be ''
        $r.Results[0].Location  | Should -Be ''
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
Describe 'Invoke-UsersList - last logon and inactive users (feature item 10)' {

    BeforeAll {
        function script:New-ListUser {
            param([int]$Id, [string]$Name, [string]$Type = 'EPVUser', [bool]$Component = $false)
            [PSCustomObject]@{ id = $Id; username = $Name; userType = $Type; source = 'CyberArk'; componentUser = $Component; enableUser = $true; suspended = $false; location = '\' }
        }
        function script:Get-EpochDaysAgo { param([int]$Days) [DateTimeOffset]::UtcNow.AddDays(-$Days).ToUnixTimeSeconds() }
    }

    BeforeEach {
        Mock Write-CyberArkLog { }
        # Users in the list, and lastSuccessfulLoginDate per user ID for the single-user GET.
        $script:ListUsers = @(
            (script:New-ListUser -Id 1 -Name 'recent'),
            (script:New-ListUser -Id 2 -Name 'stale'),
            (script:New-ListUser -Id 3 -Name 'never')
        )
        $script:LoginById = @{
            '1' = (script:Get-EpochDaysAgo -Days 10)
            '2' = (script:Get-EpochDaysAgo -Days 200)
            '3' = -62135568000
        }
        $script:FailById = @{}
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            if ($Endpoint -eq '/API/Users') { return (script:New-UsersApiResponse -Users $script:ListUsers) }
            $id = ($Endpoint -split '/')[-1]
            if ($script:FailById.ContainsKey($id)) { return (script:New-ApiErrorResponse -StatusCode $script:FailById[$id] -ErrorMessage 'Nope') }
            [PSCustomObject]@{
                IsSuccess = $true; StatusCode = 200; StatusMessage = 'OK'; ErrorMessage = $null; ErrorDetails = $null; DataType = 'JSON'; RawResponse = ''
                Data = [PSCustomObject]@{ id = [int]$id; lastSuccessfulLoginDate = $script:LoginById[$id] }
            }
        }
        $script:ActiveProfile = $null
    }

    AfterEach {
        $script:ActiveProfile = $null
    }

    It 'UL25 - no option: one list call, no LastLogin column' {
        $r = Invoke-UsersList -Token $script:MockToken -InputData @{}
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly
        $r.Results[0].PSObject.Properties.Name | Should -Not -Contain 'LastLogin'
    }

    It 'UL26 - IncludeLastLogin Yes: one GET per user with -PageSize 0, LastLogin formatted, never gives Never' {
        $r = Invoke-UsersList -Token $script:MockToken -InputData @{ IncludeLastLogin = 'Yes' }
        Should -Invoke Invoke-CyberArkAPI -Times 4 -Exactly
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Endpoint -eq '/API/Users/2' -and $PageSize -eq 0 }
        $r.Successes | Should -Be 3
        $expected = [DateTimeOffset]::FromUnixTimeSeconds($script:LoginById['2']).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
        ($r.Results | Where-Object Username -eq 'stale').LastLogin | Should -Be $expected
        ($r.Results | Where-Object Username -eq 'never').LastLogin | Should -Be 'Never'
    }

    It 'UL27 - InactiveOnly Yes (default 90 days): keeps stale and never-logged-on users, drops the recent one' {
        $r = Invoke-UsersList -Token $script:MockToken -InputData @{ InactiveOnly = 'Yes' }
        @($r.Results.Username) | Should -Be @('stale', 'never')
        $r.Successes      | Should -Be 2
        $r.ItemsProcessed | Should -Be 2
        $r.Failures       | Should -Be 0
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'LastLogin'
    }

    It 'UL28 - InactiveDays 5 also reports the user who logged on 10 days ago' {
        $r = Invoke-UsersList -Token $script:MockToken -InputData @{ InactiveOnly = 'Yes'; InactiveDays = '5' }
        @($r.Results.Username) | Should -Be @('recent', 'stale', 'never')
    }

    It 'UL29 - InactiveOnly leaves out component, Built-InAdmins and DRUser users without a GET for them' {
        $script:ListUsers = @(
            (script:New-ListUser -Id 2 -Name 'stale'),
            (script:New-ListUser -Id 20 -Name 'PasswordManager' -Type 'CPM' -Component $true),
            (script:New-ListUser -Id 21 -Name 'Administrator' -Type 'Built-InAdmins'),
            (script:New-ListUser -Id 22 -Name 'Backup2' -Type 'DRUser')
        )
        $r = Invoke-UsersList -Token $script:MockToken -InputData @{ InactiveOnly = 'Yes' }
        @($r.Results.Username) | Should -Be @('stale')
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly -ParameterFilter { $Endpoint -in @('/API/Users/20', '/API/Users/21', '/API/Users/22') }
    }

    It 'UL30 - the profile Inactive_Exclude_Users list (wildcards, case-insensitive) is left out' {
        $script:ListUsers = @(
            (script:New-ListUser -Id 2 -Name 'stale'),
            (script:New-ListUser -Id 30 -Name 'SVC_backup'),
            (script:New-ListUser -Id 31 -Name 'breakglass')
        )
        $script:LoginById['30'] = -62135568000
        $script:LoginById['31'] = -62135568000
        $script:ActiveProfile = [PSCustomObject]@{ Inactive_Exclude_Users = 'svc_*, BreakGlass' }
        $r = Invoke-UsersList -Token $script:MockToken -InputData @{ InactiveOnly = 'Yes' }
        @($r.Results.Username) | Should -Be @('stale')
    }

    It 'UL31 - the exclude list and internal types do not apply without InactiveOnly' {
        $script:ListUsers = @((script:New-ListUser -Id 21 -Name 'Administrator' -Type 'Built-InAdmins'))
        $script:ActiveProfile = [PSCustomObject]@{ Inactive_Exclude_Users = 'Administrator' }
        $r = Invoke-UsersList -Token $script:MockToken -InputData @{ IncludeLastLogin = 'Yes' }
        @($r.Results.Username) | Should -Be @('Administrator')
    }

    It 'UL32 - InactiveDays not a positive whole number: Failures=1 and no API call' {
        foreach ($bad in @('abc', '0', '-3', '1.5')) {
            $r = Invoke-UsersList -Token $script:MockToken -InputData @{ InactiveOnly = 'Yes'; InactiveDays = $bad }
            $r.Failures | Should -Be 1
            $r.Errors[0].ErrorMessage | Should -Match 'InactiveDays'
        }
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'UL33 - InactiveOnly: a failed single-user GET is an error for that user and the rest continue' {
        $script:FailById['2'] = 404
        $r = Invoke-UsersList -Token $script:MockToken -InputData @{ InactiveOnly = 'Yes' }
        $r.Failures  | Should -Be 1
        $r.Successes | Should -Be 1
        $r.IsFatal   | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match "stale"
    }

    It 'UL37 - IncludeLastLogin: a failed single-user GET (Master gives 500 USRWS001E) keeps the row with an empty LastLogin and no error' {
        $script:FailById['2'] = 500
        $r = Invoke-UsersList -Token $script:MockToken -InputData @{ IncludeLastLogin = 'Yes' }
        $r.Failures     | Should -Be 0
        $r.Errors.Count | Should -Be 0
        $r.Successes    | Should -Be 3
        ($r.Results | Where-Object Username -eq 'stale').LastLogin | Should -Be ''
        Should -Invoke Write-CyberArkLog -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'stale' }
    }

    It 'UL34 - a 401 on a single-user GET is fatal and stops the run' {
        $script:FailById['1'] = 401
        $r = Invoke-UsersList -Token $script:MockToken -InputData @{ IncludeLastLogin = 'Yes' }
        $r.IsFatal   | Should -BeTrue
        $r.Successes | Should -Be 0
        Should -Invoke Invoke-CyberArkAPI -Times 2 -Exactly
    }

    It 'UL35 - everyone active: empty result with ItemsProcessed 0 and no errors (shown as success)' {
        $script:ListUsers = @((script:New-ListUser -Id 1 -Name 'recent'))
        $r = Invoke-UsersList -Token $script:MockToken -InputData @{ InactiveOnly = 'Yes' }
        $r.Results.Count  | Should -Be 0
        $r.ItemsProcessed | Should -Be 0
        $r.Errors.Count   | Should -Be 0
    }

    It 'UL36 - a missing lastSuccessfulLoginDate counts as never logged on' {
        $script:ListUsers = @((script:New-ListUser -Id 40 -Name 'nofield'))
        $script:LoginById['40'] = $null
        $r = Invoke-UsersList -Token $script:MockToken -InputData @{ InactiveOnly = 'Yes' }
        $r.Results[0].LastLogin | Should -Be 'Never'
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
