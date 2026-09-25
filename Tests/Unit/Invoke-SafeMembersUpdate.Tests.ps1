#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\SafeMembers\Invoke-SafeMembersUpdate.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafeMembersUpdateInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\SafeMembers\Invoke-SafeMembersUpdate.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta, Get-PermissionSet, and Invoke-SafeMembersUpdate
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafeMembersUpdateTests' -MinLevel 'ERROR'

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

    # Standard valid input used by most tests
    $script:ValidInput = @{
        SafeName       = 'TestSafe'
        MemberName     = 'jsmith'
        PermissionRole = 'EndUser'
        ExpirationDate = ''
    }

    # Factory: build a mock API success response for an update (returns updated member object)
    function script:New-UpdateApiResponse {
        param(
            [string]$SafeName   = 'TestSafe',
            [string]$MemberName = 'jsmith'
        )
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = [PSCustomObject]@{
                safeName                 = $SafeName
                safeUrlId                = $SafeName
                memberName               = $MemberName
                memberType               = 'User'
                membershipExpirationDate = $null
                isExpiredMembershipEnable = $false
                isPredefinedUser         = $false
                isMemberOfSafe           = $true
                permissions              = [PSCustomObject]@{
                    UseAccounts                            = $true
                    RetrieveAccounts                       = $true
                    ListAccounts                           = $true
                    AddAccounts                            = $false
                    UpdateAccountContent                   = $false
                    UpdateAccountProperties                = $false
                    InitiateCPMAccountManagementOperations = $false
                    SpecifyNextAccountContent              = $false
                    RenameAccounts                         = $false
                    DeleteAccounts                         = $false
                    UnlockAccounts                         = $false
                    ManageSafe                             = $false
                    ManageSafeMembers                      = $false
                    BackupSafe                             = $false
                    ViewAuditLog                           = $false
                    ViewSafeMembers                        = $false
                    AccessWithoutConfirmation              = $false
                    CreateFolders                          = $false
                    DeleteFolders                          = $false
                    MoveAccountsAndFolders                 = $false
                }
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
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'MU01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'MU02 - required fields are all present' {
        $ModuleMeta.Name             | Should -Not -BeNullOrEmpty
        $ModuleMeta.Category         | Should -Not -BeNullOrEmpty
        $ModuleMeta.Action           | Should -Not -BeNullOrEmpty
        $ModuleMeta.SupportedSystems | Should -Not -BeNullOrEmpty
        $ModuleMeta.Version          | Should -Not -BeNullOrEmpty
    }

    It 'MU03 - Category=SafeMembers and Action=Update' {
        $ModuleMeta.Category | Should -Be 'SafeMembers'
        $ModuleMeta.Action   | Should -Be 'Update'
    }

    It 'MU04 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersUpdate - successful response' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-UpdateApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'MU05 - returns a result object with all 9 required fields' {
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
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

    It 'MU06 - PUT method is used' {
        Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'MU07 - Successes=1, Failures=0, ItemsProcessed=1' {
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes      | Should -Be 1
        $r.Failures       | Should -Be 0
        $r.ItemsProcessed | Should -Be 1
    }

    It 'MU08 - endpoint contains SafeName' {
        Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Endpoint -like '*TestSafe*' }
    }

    It 'MU09 - endpoint contains MemberName' {
        Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Endpoint -like '*jsmith*' }
    }

    It 'MU10 - IsFatal=$false on success' {
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersUpdate - WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-UpdateApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'MU11 - WhatIf: API is NOT called' {
        Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'MU12 - WhatIf: Successes=1 and result entry is returned' {
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes      | Should -Be 1
        $r.Results.Count  | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersUpdate - validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-UpdateApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'MU13 - empty SafeName: Failures=1 and API not called' {
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData @{ SafeName = ''; MemberName = 'jsmith' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'MU14 - empty MemberName: Failures=1 and API not called' {
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData @{ SafeName = 'TestSafe'; MemberName = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersUpdate - errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'MU15 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'MU16 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'MU17 - 404 Not Found: IsFatal=$false and error added' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal      | Should -BeFalse
        $r.Errors.Count | Should -Be 1
    }

    It 'MU18 - error entry ErrorMessage is not null or empty' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Errors[0].ErrorMessage | Should -Not -BeNullOrEmpty
    }
}
