#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Users\Invoke-UsersGet.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-UsersGetInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Users\Invoke-UsersGet.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-UsersGet into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'UsersGetTests' -MinLevel 'ERROR'

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

    # Factory: build a mock API success response for a single user object
    function script:New-UserApiResponse {
        param([PSCustomObject]$User)
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $User
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

    # A sample user object matching the CyberArk API shape (single object, not wrapped in Users array)
    $script:SampleUser = [PSCustomObject]@{
        id              = 42
        username        = 'jsmith'
        userType        = 'EPVUser'
        source          = 'CyberArk'
        componentUser   = $false
        personalDetails = [PSCustomObject]@{
            email     = 'jsmith@example.com'
            firstName = 'John'
            lastName  = 'Smith'
        }
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'UG01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'UG02 - required fields are all present' {
        $ModuleMeta.Name             | Should -Not -BeNullOrEmpty
        $ModuleMeta.Category         | Should -Not -BeNullOrEmpty
        $ModuleMeta.Action           | Should -Not -BeNullOrEmpty
        $ModuleMeta.SupportedSystems | Should -Not -BeNullOrEmpty
        $ModuleMeta.Version          | Should -Not -BeNullOrEmpty
    }

    It 'UG03 - Category is Users and Action is Get' {
        $ModuleMeta.Category | Should -Be 'Users'
        $ModuleMeta.Action   | Should -Be 'Get'
    }

    It 'UG04 - AcceptsInputFile is $true' {
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
    }

    It 'UG05 - SupportsWhatIf is $false' {
        $ModuleMeta.SupportsWhatIf | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-UsersGet - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-UserApiResponse -User $script:SampleUser
        }
        Mock Write-CyberArkLog { }
    }

    It 'UG06 - returns result object with all 9 required fields' {
        $r = Invoke-UsersGet -Token $script:MockToken -InputData @{ UserID = '42' }
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

    It 'UG07 - Successes=1, ItemsProcessed=1, Failures=0' {
        $r = Invoke-UsersGet -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.Successes      | Should -Be 1
        $r.ItemsProcessed | Should -Be 1
        $r.Failures       | Should -Be 0
    }

    It 'UG08 - user id mapped correctly to UserID' {
        $r = Invoke-UsersGet -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.Results[0].UserID | Should -Be 42
    }

    It 'UG09 - username mapped correctly to Username' {
        $r = Invoke-UsersGet -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.Results[0].Username | Should -Be 'jsmith'
    }

    It 'UG10 - personalDetails.email mapped correctly to Email' {
        $r = Invoke-UsersGet -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.Results[0].Email | Should -Be 'jsmith@example.com'
    }

    It 'UG11 - personalDetails.firstName mapped correctly to FirstName' {
        $r = Invoke-UsersGet -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.Results[0].FirstName | Should -Be 'John'
    }

    It 'UG12 - personalDetails.lastName mapped correctly to LastName' {
        $r = Invoke-UsersGet -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.Results[0].LastName | Should -Be 'Smith'
    }

    It 'UG13 - null personalDetails returns empty strings for Email, FirstName, LastName' {
        $userNoDetails = [PSCustomObject]@{
            id              = 99
            username        = 'nodetails'
            userType        = 'BasicUser'
            source          = 'CyberArk'
            componentUser   = $false
            personalDetails = $null
        }
        Mock Invoke-CyberArkAPI { script:New-UserApiResponse -User $userNoDetails }
        $r = Invoke-UsersGet -Token $script:MockToken -InputData @{ UserID = '99' }
        $r.Results[0].Email     | Should -Be ''
        $r.Results[0].FirstName | Should -Be ''
        $r.Results[0].LastName  | Should -Be ''
    }

    It 'UG14 - IsFatal=$false on success' {
        $r = Invoke-UsersGet -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.IsFatal | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-UsersGet - validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-UserApiResponse -User $script:SampleUser }
        Mock Write-CyberArkLog { }
    }

    It 'UG15 - empty UserID: Failures=1 and no API call made' {
        $r = Invoke-UsersGet -Token $script:MockToken -InputData @{ UserID = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'UG16 - null InputData: Failures=1 and no API call made' {
        $r = Invoke-UsersGet -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-UsersGet - errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'UG17 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-UsersGet -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.IsFatal | Should -BeTrue
    }

    It 'UG18 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-UsersGet -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.IsFatal | Should -BeTrue
    }

    It 'UG19 - 403 Forbidden: IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-UsersGet -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.IsFatal | Should -BeFalse
    }

    It 'UG20 - 404 Not Found: IsFatal=$false and error added' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        $r = Invoke-UsersGet -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.IsFatal      | Should -BeFalse
        $r.Failures     | Should -Be 1
        $r.Errors.Count | Should -Be 1
    }
}
