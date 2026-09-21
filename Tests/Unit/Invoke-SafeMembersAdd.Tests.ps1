#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\SafeMembers\Invoke-SafeMembersAdd.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafeMembersAddInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\SafeMembers\Invoke-SafeMembersAdd.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-SafeMembersAdd into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafeMembersAddTests' -MinLevel 'ERROR'

    # Minimal token stub (SelfHosted)
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault'
    }

    $script:ValidInput = @{
        SafeName       = 'TestSafe'
        MemberName     = 'john.doe'
        SearchIn       = 'Vault'
        MemberType     = 'User'
        PermissionRole = 'ReadOnlyStrict'
        ExpirationDate = ''
    }

    # Sample API response object matching the CyberArk Members POST response shape
    $script:SampleResponse = [PSCustomObject]@{
        safeName                 = 'TestSafe'
        memberName               = 'john.doe'
        memberType               = 'User'
        isPredefinedUser         = $false
        isMemberOfSafe           = $true
        membershipExpirationDate = $null
        permissions              = [PSCustomObject]@{
            UseAccounts                            = $false
            RetrieveAccounts                       = $false
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
            ViewAuditLog                           = $true
            ViewSafeMembers                        = $true
            AccessWithoutConfirmation              = $false
            CreateFolders                          = $false
            DeleteFolders                          = $false
            MoveAccountsAndFolders                 = $false
        }
    }

    # Factory: build a mock API success response for a member POST
    function script:New-MemberApiResponse {
        param(
            [PSCustomObject]$Member,
            [int]$StatusCode = 201
        )
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = $StatusCode
            StatusMessage = 'Created'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $Member
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

    It 'MA01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'MA02 - Category is SafeMembers and Action is Add' {
        $ModuleMeta.Category | Should -Be 'SafeMembers'
        $ModuleMeta.Action   | Should -Be 'Add'
    }

    It 'MA03 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'MA04 - AcceptsInputFile is $true' {
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
    }

    It 'MA05 - InputSchema contains SafeName and MemberName both Required=$true' {
        $safeNameField   = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'SafeName' }
        $memberNameField = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'MemberName' }
        $safeNameField           | Should -Not -BeNullOrEmpty
        $safeNameField.Required  | Should -BeTrue
        $memberNameField         | Should -Not -BeNullOrEmpty
        $memberNameField.Required | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersAdd - success (201)' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-MemberApiResponse -Member $script:SampleResponse -StatusCode 201
        }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'MA06 - returns a result object with all 9 required fields' {
        $r = Invoke-SafeMembersAdd -Token $script:MockToken -InputData $script:ValidInput
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

    It 'MA07 - POST method is used' {
        Invoke-SafeMembersAdd -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' } -Times 1
    }

    It 'MA08 - Successes=1, ItemsProcessed=1, Failures=0' {
        $r = Invoke-SafeMembersAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes      | Should -Be 1
        $r.ItemsProcessed | Should -Be 1
        $r.Failures       | Should -Be 0
    }

    It 'MA09 - MemberName is present in result' {
        $r = Invoke-SafeMembersAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].MemberName | Should -Be 'john.doe'
    }

    It 'MA10 - IsFatal is $false on success' {
        $r = Invoke-SafeMembersAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersAdd - permission presets' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'MA11 - ReadOnlyStrict: only ListAccounts, ViewAuditLog, ViewSafeMembers are $true in body' {
        $capturedBody = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedBody -Value $PSBoundParameters.Body -Scope Script
            script:New-MemberApiResponse -Member $script:SampleResponse -StatusCode 201
        }
        Invoke-SafeMembersAdd -Token $script:MockToken -InputData $script:ValidInput
        $script:capturedBody.Permissions.ListAccounts    | Should -BeTrue
        $script:capturedBody.Permissions.ViewAuditLog    | Should -BeTrue
        $script:capturedBody.Permissions.ViewSafeMembers | Should -BeTrue
        $script:capturedBody.Permissions.UseAccounts     | Should -BeFalse
        $script:capturedBody.Permissions.ManageSafe      | Should -BeFalse
    }

    It 'MA11a - legacy PermissionRole=ReadOnly (pre-rename name) still resolves to the same ReadOnlyStrict permission set' {
        # Get-PermissionSet's switch has no explicit 'ReadOnly' case, so the old name falls through
        # to the same default branch as 'ReadOnlyStrict' and any other unrecognized value - a CSV or
        # saved profile default still carrying the pre-rename role name keeps working unchanged.
        $capturedBody = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedBody -Value $PSBoundParameters.Body -Scope Script
            script:New-MemberApiResponse -Member $script:SampleResponse -StatusCode 201
        }
        $legacyInput = $script:ValidInput.Clone()
        $legacyInput.PermissionRole = 'ReadOnly'
        Invoke-SafeMembersAdd -Token $script:MockToken -InputData $legacyInput
        $script:capturedBody.Permissions.ListAccounts    | Should -BeTrue
        $script:capturedBody.Permissions.ViewAuditLog    | Should -BeTrue
        $script:capturedBody.Permissions.ViewSafeMembers | Should -BeTrue
        $script:capturedBody.Permissions.RetrieveAccounts | Should -BeFalse
    }

    It 'MA12 - SafeManager: ManageSafe is $true in body' {
        $capturedBody = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedBody -Value $PSBoundParameters.Body -Scope Script
            $mgr = $script:SampleResponse.PSObject.Copy()
            script:New-MemberApiResponse -Member $mgr -StatusCode 201
        }
        $smInput = $script:ValidInput.Clone()
        $smInput.PermissionRole = 'SafeManager'
        Invoke-SafeMembersAdd -Token $script:MockToken -InputData $smInput
        $script:capturedBody.Permissions.ManageSafe        | Should -BeTrue
        $script:capturedBody.Permissions.ManageSafeMembers | Should -BeTrue
        $script:capturedBody.Permissions.UseAccounts       | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersAdd - WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'MA13 - WhatIf: API is NOT called' {
        Invoke-SafeMembersAdd -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'MA14 - WhatIf: Successes=1 (synthetic result counted)' {
        $r = Invoke-SafeMembersAdd -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersAdd - validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'MA15 - empty SafeName: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = ''
        $r = Invoke-SafeMembersAdd -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'MA16 - empty MemberName: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.MemberName = ''
        $r = Invoke-SafeMembersAdd -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'MA17 - null InputData: Failures=1, no API call' {
        $r = Invoke-SafeMembersAdd -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersAdd - API errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'MA18 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-SafeMembersAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'MA19 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-SafeMembersAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'MA20 - 409 Conflict: IsFatal=$false, error added' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 409 -ErrorMessage 'Member already exists' }
        $r = Invoke-SafeMembersAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal      | Should -BeFalse
        $r.Errors.Count | Should -Be 1
    }

    It 'MA21 - error entry ErrorMessage is not null or empty' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 409 -ErrorMessage 'Member already exists' }
        $r = Invoke-SafeMembersAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.Errors[0].ErrorMessage | Should -Not -BeNullOrEmpty
    }

    It 'MA22 - endpoint contains URL-encoded SafeName' {
        $capturedEndpoint = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedEndpoint -Value $PSBoundParameters.Endpoint -Scope Script
            script:New-MemberApiResponse -Member $script:SampleResponse -StatusCode 201
        }
        $spacedInput = $script:ValidInput.Clone()
        $spacedInput.SafeName = 'Test Safe'
        Invoke-SafeMembersAdd -Token $script:MockToken -InputData $spacedInput
        $script:capturedEndpoint | Should -Match 'Test%20Safe'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Get-SafeMembersSearchInOptions' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'MA23 - Vault is always the first option' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        $opts = @(script:Get-SafeMembersSearchInOptions -Token $script:MockToken)
        $opts[0].DisplayName | Should -Be 'Vault'
        $opts[0].Value       | Should -Be 'Vault'
    }

    It 'MA24 - GetDirectoryServices call failure: falls back to Vault-only, no exception' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $opts = @(script:Get-SafeMembersSearchInOptions -Token $script:MockToken)
        $opts.Count | Should -Be 1
    }

    It 'MA25 - GetDirectoryServices returns a bare array: directories appended after Vault' {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{
                IsSuccess = $true; StatusCode = 200; ErrorMessage = $null; ErrorDetails = $null
                DataType = 'JSON'; RawResponse = ''
                Data = @(
                    [PSCustomObject]@{ id = 'guid-1'; domainName = 'example.com' },
                    [PSCustomObject]@{ id = 'guid-2'; domainName = 'other.local' }
                )
            }
        }
        $opts = @(script:Get-SafeMembersSearchInOptions -Token $script:MockToken)
        $opts.Count            | Should -Be 3
        $opts[1].DisplayName   | Should -Be 'example.com'
        $opts[1].Value         | Should -Be 'guid-1'
        $opts[2].DisplayName   | Should -Be 'other.local'
        $opts[2].Value         | Should -Be 'guid-2'
    }

    It 'MA26 - GetDirectoryServices returns items wrapped under a value property' {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{
                IsSuccess = $true; StatusCode = 200; ErrorMessage = $null; ErrorDetails = $null
                DataType = 'JSON'; RawResponse = ''
                Data = [PSCustomObject]@{ value = @([PSCustomObject]@{ id = 'guid-1'; domainName = 'example.com' }) }
            }
        }
        $opts = @(script:Get-SafeMembersSearchInOptions -Token $script:MockToken)
        $opts.Count | Should -Be 2
        $opts[1].Value | Should -Be 'guid-1'
    }

    It 'MA27 - directory item missing all probed ID fields is skipped, not thrown' {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{
                IsSuccess = $true; StatusCode = 200; ErrorMessage = $null; ErrorDetails = $null
                DataType = 'JSON'; RawResponse = ''
                Data = @([PSCustomObject]@{ unrelatedField = 'x' })
            }
        }
        $opts = @(script:Get-SafeMembersSearchInOptions -Token $script:MockToken)
        $opts.Count | Should -Be 1
    }

    It 'MA28 - Invoke-CyberArkAPI throwing an exception: falls back to Vault-only' {
        Mock Invoke-CyberArkAPI { throw 'network failure' }
        $opts = @(script:Get-SafeMembersSearchInOptions -Token $script:MockToken)
        $opts.Count | Should -Be 1
        $opts[0].DisplayName | Should -Be 'Vault'
    }
}
