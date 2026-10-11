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

    # Current membership returned by the mocked GET /API/Safes/{safe}/Members/{member} (F85)
    $script:CurrentExpiration = 1767225600
    function script:New-CurrentMemberResponse {
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = [PSCustomObject]@{
                safeName                 = 'TestSafe'
                memberName               = 'jsmith'
                memberType               = 'User'
                membershipExpirationDate = $script:CurrentExpiration
                permissions              = [PSCustomObject]@{
                    useAccounts                            = $true
                    retrieveAccounts                       = $false
                    listAccounts                           = $true
                    addAccounts                            = $false
                    updateAccountContent                   = $false
                    updateAccountProperties                = $false
                    initiateCPMAccountManagementOperations = $false
                    specifyNextAccountContent              = $false
                    renameAccounts                         = $false
                    deleteAccounts                         = $false
                    unlockAccounts                         = $false
                    manageSafe                             = $false
                    manageSafeMembers                      = $false
                    backupSafe                             = $false
                    viewAuditLog                           = $true
                    viewSafeMembers                        = $false
                    accessWithoutConfirmation              = $false
                    createFolders                          = $false
                    deleteFolders                          = $false
                    moveAccountsAndFolders                 = $false
                    requestsAuthorizationLevel1            = $true
                    requestsAuthorizationLevel2            = $false
                }
            }
        }
    }

    # The full permission header of the generated CSV template, every cell blank
    function script:New-BlankPermissionRow {
        $row = @{ SafeName = 'TestSafe'; MemberName = 'jsmith'; PermissionRole = ''; ExpirationDate = '' }
        foreach ($col in $script:PermissionColumns) { $row[$col] = '' }
        $row['RequestsAuthorizationLevel1'] = ''
        $row['RequestsAuthorizationLevel2'] = ''
        return $row
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

    It 'MU11 - WhatIf: no PUT is sent (a read-only GET of the current membership is allowed)' {
        Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } -Times 0 -Exactly
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

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersUpdate - permission and expiration rules (F85)' {

    BeforeEach {
        $script:CurrentExpiration = 1767225600
        # 2027-01-31 local midnight in Unix seconds, the value the API needs (F93)
        $script:Exp20270131 = ([DateTimeOffset](New-Object DateTime 2027, 1, 31, 0, 0, 0, ([DateTimeKind]::Local))).ToUnixTimeSeconds()
        $script:PutBody = $null
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET') { return script:New-CurrentMemberResponse }
            $script:PutBody = $Body
            script:New-UpdateApiResponse
        }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'MU19 - PermissionRole set: the preset is used even when every permission column is present (template header)' {
        $row = script:New-BlankPermissionRow
        $row.PermissionRole = 'EndUser'
        $row.ManageSafe     = 'True'
        $row.ExpirationDate = '2027-01-31'
        Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $row
        $script:PutBody.permissions.useAccounts      | Should -BeTrue
        $script:PutBody.permissions.retrieveAccounts | Should -BeTrue
        $script:PutBody.permissions.manageSafe       | Should -BeFalse
        $script:PutBody.permissions.viewAuditLog     | Should -BeFalse
    }

    It 'MU20 - PermissionRole blank: given columns are applied and blank columns keep the current value' {
        $row = script:New-BlankPermissionRow
        $row.ManageSafe     = 'True'
        $row.UseAccounts    = 'False'
        $row.ExpirationDate = '2027-01-31'
        Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $row
        $script:PutBody.permissions.manageSafe       | Should -BeTrue
        $script:PutBody.permissions.useAccounts      | Should -BeFalse
        $script:PutBody.permissions.listAccounts     | Should -BeTrue
        $script:PutBody.permissions.viewAuditLog     | Should -BeTrue
        $script:PutBody.permissions.retrieveAccounts | Should -BeFalse
        $script:PutBody.permissions.requestsAuthorizationLevel1 | Should -BeTrue
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TestSafe/Members/jsmith' } -Times 1 -Exactly
    }

    It 'MU21 - PermissionRole Specified behaves like blank (individual columns, blanks keep current)' {
        $row = script:New-BlankPermissionRow
        $row.PermissionRole = 'Specified'
        $row.DeleteAccounts = 'Yes'
        Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $row
        $script:PutBody.permissions.deleteAccounts | Should -BeTrue
        $script:PutBody.permissions.listAccounts   | Should -BeTrue
    }

    It 'MU22 - PermissionRole and every column blank: current permissions kept, only the expiration changes' {
        $row = script:New-BlankPermissionRow
        $row.ExpirationDate = '2027-01-31'
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $row
        $r.Successes | Should -Be 1
        $script:PutBody.membershipExpirationDate | Should -Be $script:Exp20270131
        $script:PutBody.permissions.useAccounts  | Should -BeTrue
        $script:PutBody.permissions.listAccounts | Should -BeTrue
        $script:PutBody.permissions.manageSafe   | Should -BeFalse
    }

    It 'MU23 - blank ExpirationDate keeps the current expiration date' {
        Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } -Times 1 -Exactly
        $script:PutBody.membershipExpirationDate | Should -Be 1767225600
    }

    It 'MU34 - the single-member GET passes -PageSize 0, so no limit/offset is sent' {
        Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TestSafe/Members/jsmith' -and $PageSize -eq 0
        }
    }

    It 'MU24 - PermissionRole and ExpirationDate both given: the current membership is not read' {
        $testInput = $script:ValidInput.Clone()
        $testInput.ExpirationDate = '2027-01-31'
        Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $testInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } -Times 0 -Exactly
        $script:PutBody.membershipExpirationDate | Should -Be $script:Exp20270131
    }

    It 'MU25 - ExpirationDate None removes the expiration (null) without reading the current membership' {
        $testInput = $script:ValidInput.Clone()
        $testInput.ExpirationDate = 'None'
        Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $testInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } -Times 0 -Exactly
        $script:PutBody.ContainsKey('membershipExpirationDate') | Should -BeTrue
        $script:PutBody.membershipExpirationDate | Should -BeNullOrEmpty
    }

    It 'MU26 - a negative current expiration is sent as null (no expiration)' {
        $script:CurrentExpiration = -62135596800
        Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
        $script:PutBody.membershipExpirationDate | Should -BeNullOrEmpty
    }

    It 'MU27 - current membership GET fails (404): Failures=1, IsFatal=$false, no PUT' {
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET') { return script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Member not found' }
            script:New-UpdateApiResponse
        }
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'current membership'
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } -Times 0 -Exactly
    }

    It 'MU28 - current membership GET returns 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'MU29 - RequestsAuthorizationLevel2 True with Level1 blank turns off the current Level1 (no exclusivity error)' {
        $row = script:New-BlankPermissionRow
        $row.RequestsAuthorizationLevel2 = 'True'
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $row
        $r.Failures | Should -Be 0
        $script:PutBody.permissions.requestsAuthorizationLevel1 | Should -BeFalse
        $script:PutBody.permissions.requestsAuthorizationLevel2 | Should -BeTrue
    }

    It 'MU30 - both authorization levels True: Failures=1 and no PUT' {
        $row = script:New-BlankPermissionRow
        $row.RequestsAuthorizationLevel1 = 'True'
        $row.RequestsAuthorizationLevel2 = 'True'
        $row.ExpirationDate = '2027-01-31'
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $row
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } -Times 0 -Exactly
    }

    It 'MU31 - interactive Permissions hashtable: $null values keep the current value' {
        $perms = @{}
        foreach ($col in $script:PermissionColumns) { $perms[$col.Substring(0,1).ToLower() + $col.Substring(1)] = $null }
        $perms['manageSafe'] = $true
        $perms['requestsAuthorizationLevel1'] = $null
        $perms['requestsAuthorizationLevel2'] = $null
        $testInput = @{ SafeName = 'TestSafe'; MemberName = 'jsmith'; PermissionRole = 'Specified'; ExpirationDate = ''; Permissions = $perms }
        Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $testInput
        $script:PutBody.permissions.manageSafe   | Should -BeTrue
        $script:PutBody.permissions.listAccounts | Should -BeTrue
        $script:PutBody.permissions.requestsAuthorizationLevel1 | Should -BeTrue
    }

    It 'MU32 - WhatIf with blanks: the result shows the merged values and no PUT is sent' {
        $row = script:New-BlankPermissionRow
        $row.ManageSafe = 'True'
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $row -WhatIf
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } -Times 0 -Exactly
        $r.Results[0].Permissions.manageSafe   | Should -BeTrue
        $r.Results[0].Permissions.listAccounts | Should -BeTrue
        $r.Results[0].MembershipExpirationDate | Should -Be ([DateTimeOffset]::FromUnixTimeSeconds(1767225600).LocalDateTime.ToString('yyyy-MM-dd HH:mm'))
    }

    It 'MU33 - an ExpirationDate that is not a date fails the row with no API call (F93)' {
        $testInput = $script:ValidInput.Clone()
        $testInput.ExpirationDate = '2027-13-45'
        $r = Invoke-SafeMembersUpdate -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'yyyy-MM-dd'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }
}
