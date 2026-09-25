#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\SafeMembers\Invoke-SafeMembersList.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafeMembersListInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    Set-StrictMode -Version Latest
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\SafeMembers\Invoke-SafeMembersList.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-SafeMembersList into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafeMembersListTests' -MinLevel 'ERROR'

    # Minimal token stub
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault'
    }

    # Sample member object matching the CyberArk API shape
    $script:SampleMember = [PSCustomObject]@{
        safeName                  = 'TestSafe'
        memberName                = 'john.doe'
        memberType                = 'User'
        isPredefinedUser          = $false
        isMemberOfSafe            = $true
        membershipExpirationDate  = $null
        permissions               = [PSCustomObject]@{
            UseAccounts                              = $true
            RetrieveAccounts                         = $true
            ListAccounts                             = $true
            AddAccounts                              = $false
            UpdateAccountContent                     = $false
            UpdateAccountProperties                  = $false
            InitiateCPMAccountManagementOperations   = $false
            SpecifyNextAccountContent                = $false
            RenameAccounts                           = $false
            DeleteAccounts                           = $false
            UnlockAccounts                           = $false
            ManageSafe                               = $false
            ManageSafeMembers                        = $false
            BackupSafe                               = $false
            ViewAuditLog                             = $true
            ViewSafeMembers                          = $false
            AccessWithoutConfirmation                = $false
            CreateFolders                            = $false
            DeleteFolders                            = $false
            MoveAccountsAndFolders                   = $false
        }
    }

    # Factory: build a mock API success response containing the given member objects
    function script:New-MembersApiResponse {
        param([object[]]$Members = @())
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = [PSCustomObject]@{
                value = $Members
                count = $Members.Count
            }
        }
    }

    # Factory: build a mock GET /API/Safes response (the "list all safes" lookup)
    function script:New-SafesListApiResponse {
        param([string[]]$SafeNames = @())
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = [PSCustomObject]@{
                value = @($SafeNames | ForEach-Object { [PSCustomObject]@{ safeName = $_ } })
                count = $SafeNames.Count
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

    It 'ML01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'ML02 - required fields are all present' {
        $ModuleMeta.Name             | Should -Not -BeNullOrEmpty
        $ModuleMeta.Category         | Should -Not -BeNullOrEmpty
        $ModuleMeta.Action           | Should -Not -BeNullOrEmpty
        $ModuleMeta.SupportedSystems | Should -Not -BeNullOrEmpty
        $ModuleMeta.Version          | Should -Not -BeNullOrEmpty
    }

    It 'ML03 - Category is SafeMembers and Action is List' {
        $ModuleMeta.Category | Should -Be 'SafeMembers'
        $ModuleMeta.Action   | Should -Be 'List'
    }

    It 'ML04 - SupportedSystems contains ISPSS and SelfHosted' {
        $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
    }

    It 'ML05 - SupportsWhatIf is $false (list operation)' {
        $ModuleMeta.SupportsWhatIf | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersList - successful response' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Invoke-CyberArkAPI {
            script:New-MembersApiResponse -Members @($script:SampleMember)
        }
        Mock Write-CyberArkLog { }
    }

    It 'ML06 - returns a result object with all 9 required fields' {
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
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

    It 'ML07 - single member: Successes=1, ItemsProcessed=1, Failures=0' {
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.Successes      | Should -Be 1
        $r.ItemsProcessed | Should -Be 1
        $r.Failures       | Should -Be 0
    }

    It 'ML08 - multiple members: count matches value array' {
        $member2 = $script:SampleMember.PSObject.Copy()
        $member2.memberName = 'jane.doe'
        Mock Invoke-CyberArkAPI {
            script:New-MembersApiResponse -Members @($script:SampleMember, $member2)
        }
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.Successes | Should -Be 2
    }

    It 'ML09 - memberName is mapped to MemberName' {
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.Results[0].MemberName | Should -Be 'john.doe'
    }

    It 'ML10 - UseAccounts permission is mapped correctly' {
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.Results[0].UseAccounts | Should -BeTrue
    }

    It 'ML11 - ManageSafe permission is mapped correctly' {
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.Results[0].ManageSafe | Should -BeFalse
    }

    It 'ML12 - ViewAuditLog permission is mapped correctly' {
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.Results[0].ViewAuditLog | Should -BeTrue
    }

    It 'ML13 - safeName is mapped to SafeName on result' {
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.Results[0].SafeName | Should -Be 'TestSafe'
    }

    It 'ML14 - empty member list returns Successes=0, Failures=0, IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-MembersApiResponse -Members @() }
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.Successes | Should -Be 0
        $r.Failures  | Should -Be 0
        $r.IsFatal   | Should -BeFalse
    }

    It 'ML15 - IsFatal is $false on success' {
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.IsFatal | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
# NOTE: ML16/ML17 used to assert that a blank SafeName was a validation failure that never
# called the API. Commit 0c1bef5 ("Add Groups drill-down to GetMembers and SafeMembers
# all-safes list") deliberately removed that required-SafeName validation and made blank
# SafeName mean "retrieve members for all safes" (GET /API/Safes, then Members per safe) - see
# $ModuleMeta.InputSchema and Get-SafeMembersListInput's prompt text above, both of which say
# "leave blank for all safes". These two tests were never updated for that refactor and were
# asserting behavior the production code intentionally no longer has; rewritten below to cover
# the actual, current, documented "blank SafeName" behavior instead.
Describe 'Invoke-SafeMembersList - validation' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Write-CyberArkLog { }
    }

    It 'ML16 - empty SafeName: retrieves members for all safes' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $WhatIf)
            if ($Endpoint -eq '/API/Safes') {
                script:New-SafesListApiResponse -SafeNames @('TestSafe')
            } else {
                script:New-MembersApiResponse -Members @($script:SampleMember)
            }
        }
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData @{ SafeName = '' }
        $r.Successes | Should -Be 1
        $r.Failures  | Should -Be 0
        $r.IsFatal   | Should -BeFalse
    }

    It 'ML17 - null InputData: retrieves members for all safes' {
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $WhatIf)
            if ($Endpoint -eq '/API/Safes') {
                script:New-SafesListApiResponse -SafeNames @('TestSafe')
            } else {
                script:New-MembersApiResponse -Members @($script:SampleMember)
            }
        }
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData $null
        $r.Successes | Should -Be 1
        $r.Failures  | Should -Be 0
        $r.IsFatal   | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersList - API errors' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Write-CyberArkLog { }
    }

    It 'ML18 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.IsFatal      | Should -BeTrue
        $r.Failures     | Should -Be 1
        $r.Errors.Count | Should -Be 1
    }

    It 'ML19 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.IsFatal | Should -BeTrue
    }

    It 'ML20 - 403 Forbidden: error added, IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-SafeMembersList -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.Failures        | Should -Be 1
        $r.Errors.Count    | Should -Be 1
        $r.IsFatal         | Should -BeFalse
    }
}
