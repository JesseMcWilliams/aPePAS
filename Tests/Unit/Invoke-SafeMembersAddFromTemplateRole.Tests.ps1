#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\SafeMembers\Invoke-SafeMembersAddFromTemplateRole.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafeMembersAddFromTemplateRoleInput is NOT tested here because it depends on
    Show-FieldPrompt, which is defined in Manage-Privilege.ps1. That function is covered by manual
    integration tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\SafeMembers\Invoke-SafeMembersAddFromTemplateRole.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafeMembersAddFromTemplateRoleTests' -MinLevel 'ERROR'

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
        SafeName       = 'TargetSafe'
        MemberName     = 'jdoe'
        SearchIn       = 'Vault'
        MemberType     = 'User'
        RoleName       = 'CyberArk_SafeManagers'
        ExpirationDate = ''
    }

    # Template safe member list: one role member matching the prefix (usable), one
    # non-role member (should never be selectable as a role).
    $script:TemplateMembersResponse = [PSCustomObject]@{
        value = @(
            [PSCustomObject]@{
                memberName = 'CyberArk_SafeManagers'
                memberType = 'Group'
                permissions = [PSCustomObject]@{ manageSafe = $true; manageSafeMembers = $true; useAccounts = $true }
            },
            [PSCustomObject]@{
                memberName = 'AdminGroup'
                memberType = 'Group'
                permissions = [PSCustomObject]@{ useAccounts = $true }
            }
        )
    }

    function script:New-OkResponse {
        param([object]$Data, [int]$StatusCode = 200)
        return [PSCustomObject]@{
            IsSuccess = $true; StatusCode = $StatusCode; StatusMessage = 'OK'
            ErrorMessage = $null; ErrorDetails = $null; DataType = 'JSON'; RawResponse = ''
            Data = $Data
        }
    }

    function script:New-ErrResponse {
        param([int]$StatusCode = 403, [string]$ErrorMessage = 'Forbidden')
        return [PSCustomObject]@{
            IsSuccess = $false; StatusCode = $StatusCode; StatusMessage = "HTTP $StatusCode"
            ErrorMessage = $ErrorMessage
            ErrorDetails = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $ErrorMessage; Details = $null }
            DataType = 'JSON'; RawResponse = ''; Data = $null
        }
    }

    function script:Invoke-DefaultRouting {
        param($Method, $Endpoint, $Body)
        if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe/Members') {
            return script:New-OkResponse -Data $script:TemplateMembersResponse
        }
        if ($Method -eq 'POST' -and $Endpoint -eq '/API/Safes/TargetSafe/Members') {
            return script:New-OkResponse -Data ([PSCustomObject]@{ safeName = 'TargetSafe'; memberName = $Body.memberName; memberType = 'User' }) -StatusCode 201
        }
        return script:New-ErrResponse -StatusCode 500 -ErrorMessage 'Unrouted mock call'
    }

    function script:Reset-MockActiveProfile {
        $script:ActiveProfile = [PSCustomObject]@{
            Role_Template_Safe = 'TemplateSafe'
            Role_Group_Prefix  = 'CyberArk_'
            IgnoreSSL          = $false
        }
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'ATR01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'ATR02 - Category is SafeMembers and Action is AddFromTemplateRole' {
        $ModuleMeta.Category | Should -Be 'SafeMembers'
        $ModuleMeta.Action   | Should -Be 'AddFromTemplateRole'
    }

    It 'ATR03 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'ATR04 - InputSchema has no individual permission columns' {
        $ModuleMeta.InputSchema.Column | Should -Not -Contain 'UseAccounts'
        $ModuleMeta.InputSchema.Column | Should -Not -Contain 'PermissionRole'
    }

    It 'ATR05 - InputSchema RoleName is Required=$true' {
        $col = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'RoleName' }
        $col          | Should -Not -BeNullOrEmpty
        $col.Required | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersAddFromTemplateRole - success' {

    BeforeEach {
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI { script:Invoke-DefaultRouting -Method $Method -Endpoint $Endpoint -Body $Body }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'ATR06 - IsFatal is $false' {
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'ATR07 - Successes=1, Failures=0' {
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes | Should -Be 1
        $r.Failures  | Should -Be 0
    }

    It 'ATR08 - POST body permissions come from the matched role member, verbatim' {
        Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Safes/TargetSafe/Members' -and
            $Body.memberName -eq 'jdoe' -and
            $Body.permissions.manageSafe -eq $true -and
            $Body.permissions.useAccounts -eq $true
        } -Times 1
    }

    It 'ATR09 - membershipExpirationDate is null when ExpirationDate is blank' {
        Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $null -eq $Body.membershipExpirationDate
        } -Times 1
    }

    It 'ATR10 - Results row includes the RoleName used' {
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].RoleName | Should -Be 'CyberArk_SafeManagers'
    }

    It 'ATR11 - RoleName match is case-insensitive' {
        $testInput = $script:ValidInput.Clone()
        $testInput.RoleName = 'cyberark_safemanagers'
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $testInput
        $r.IsFatal  | Should -BeFalse
        $r.Failures | Should -Be 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersAddFromTemplateRole - WhatIf' {

    BeforeEach {
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET') { script:Invoke-DefaultRouting -Method $Method -Endpoint $Endpoint -Body $Body }
            else { script:New-OkResponse -Data $null }
        }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'ATR12 - WhatIf: no POST call is made' {
        Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' } -Times 0
    }

    It 'ATR13 - WhatIf: still resolves the role (GET call happens), Successes=1' {
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } -Times 1
        $r.Successes | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersAddFromTemplateRole - validation' {

    BeforeEach {
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI { }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'ATR14 - empty SafeName: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = ''
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'ATR15 - empty RoleName: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.RoleName = ''
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'ATR16 - Role_Template_Safe blank on profile: Failures=1, no API call' {
        $script:ActiveProfile.Role_Template_Safe = ''
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'ATR17 - Role_Group_Prefix blank on profile: Failures=1, no API call' {
        $script:ActiveProfile.Role_Group_Prefix = ''
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersAddFromTemplateRole - errors' {

    BeforeEach {
        script:Reset-MockActiveProfile
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'ATR18 - RoleName does not match any role-prefixed template member: Failures=1, IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:Invoke-DefaultRouting -Method $Method -Endpoint $Endpoint -Body $Body }
        $testInput = $script:ValidInput.Clone()
        $testInput.RoleName = 'AdminGroup'   # exists on template safe, but is NOT role-prefixed
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' } -Times 0
    }

    It 'ATR19 - RoleName not found at all: Failures=1, IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:Invoke-DefaultRouting -Method $Method -Endpoint $Endpoint -Body $Body }
        $testInput = $script:ValidInput.Clone()
        $testInput.RoleName = 'CyberArk_DoesNotExist'
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
    }

    It 'ATR20 - template members GET returns 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'ATR21 - template members GET returns 404: IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -ErrorMessage 'Safe not found' }
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal      | Should -BeFalse
        $r.Errors.Count | Should -Be 1
    }

    It 'ATR22 - Add safe member POST fails (409): IsFatal=$false, error added' {
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET') { script:New-OkResponse -Data $script:TemplateMembersResponse }
            else { script:New-ErrResponse -StatusCode 409 -ErrorMessage 'Member already exists' }
        }
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal      | Should -BeFalse
        $r.Errors.Count | Should -Be 1
    }

    It 'ATR23 - Add safe member POST returns 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET') { script:New-OkResponse -Data $script:TemplateMembersResponse }
            else { script:New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        }
        $r = Invoke-SafeMembersAddFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}
