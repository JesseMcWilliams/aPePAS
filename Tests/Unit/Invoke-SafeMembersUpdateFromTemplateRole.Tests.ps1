#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\SafeMembers\Invoke-SafeMembersUpdateFromTemplateRole.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafeMembersUpdateFromTemplateRoleInput is NOT tested here because it depends on
    Show-FieldPrompt, which is defined in Manage-Privilege.ps1. That function is covered by manual
    integration tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\SafeMembers\Invoke-SafeMembersUpdateFromTemplateRole.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafeMembersUpdateFromTemplateRoleTests' -MinLevel 'ERROR'

    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'ISPSS'
        AuthMethod = 'ClientCredentials'
        BaseURL    = 'https://test.privilegecloud.cyberark.cloud'
    }

    $script:ValidInput = @{
        SafeName       = 'TargetSafe'
        MemberName     = 'jdoe'
        RoleName       = 'CyberArk_SafeManagers'
        ExpirationDate = ''
    }

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
        if ($Method -eq 'PUT' -and $Endpoint -eq '/API/Safes/TargetSafe/Members/jdoe') {
            return script:New-OkResponse -Data ([PSCustomObject]@{
                safeName = 'TargetSafe'; memberName = 'jdoe'
                membershipExpirationDate = $Body.membershipExpirationDate
                permissions = $Body.permissions
            })
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

    It 'UTR01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'UTR02 - Category is SafeMembers and Action is UpdateFromTemplateRole' {
        $ModuleMeta.Category | Should -Be 'SafeMembers'
        $ModuleMeta.Action   | Should -Be 'UpdateFromTemplateRole'
    }

    It 'UTR03 - InputSchema has no individual permission columns' {
        $ModuleMeta.InputSchema.Column | Should -Not -Contain 'UseAccounts'
        $ModuleMeta.InputSchema.Column | Should -Not -Contain 'PermissionRole'
    }

    It 'UTR04 - InputSchema RoleName is Required=$true' {
        $col = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'RoleName' }
        $col          | Should -Not -BeNullOrEmpty
        $col.Required | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersUpdateFromTemplateRole - success' {

    BeforeEach {
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI { script:Invoke-DefaultRouting -Method $Method -Endpoint $Endpoint -Body $Body }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'UTR05 - IsFatal is $false' {
        $r = Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'UTR06 - Successes=1, Failures=0' {
        $r = Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes | Should -Be 1
        $r.Failures  | Should -Be 0
    }

    It 'UTR07 - PUT body permissions come from the matched role member, verbatim' {
        Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'PUT' -and $Endpoint -eq '/API/Safes/TargetSafe/Members/jdoe' -and
            $Body.permissions.manageSafe -eq $true -and
            $Body.permissions.useAccounts -eq $true
        } -Times 1
    }

    It 'UTR08 - PUT endpoint uses URL-encoded SafeName and MemberName' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName   = 'Target Safe'
        $testInput.MemberName = 'j doe'
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET') { script:New-OkResponse -Data $script:TemplateMembersResponse }
            else { script:New-OkResponse -Data ([PSCustomObject]@{ safeName = 'Target Safe'; memberName = 'j doe' }) }
        }
        Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $testInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'PUT' -and $Endpoint -match 'Target%20Safe' -and $Endpoint -match 'j%20doe'
        } -Times 1
    }

    It 'UTR09 - Results row includes the RoleName used' {
        $r = Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].RoleName | Should -Be 'CyberArk_SafeManagers'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersUpdateFromTemplateRole - WhatIf' {

    BeforeEach {
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET') { script:Invoke-DefaultRouting -Method $Method -Endpoint $Endpoint -Body $Body }
            else { script:New-OkResponse -Data $null }
        }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'UTR10 - WhatIf: no PUT call is made' {
        Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } -Times 0
    }

    It 'UTR11 - WhatIf: still resolves the role (GET call happens), Successes=1' {
        $r = Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } -Times 1
        $r.Successes | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersUpdateFromTemplateRole - validation' {

    BeforeEach {
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI { }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'UTR12 - empty SafeName: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = ''
        $r = Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UTR13 - empty MemberName: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.MemberName = ''
        $r = Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UTR14 - empty RoleName: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.RoleName = ''
        $r = Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UTR15 - Role_Template_Safe blank on profile: Failures=1, no API call' {
        $script:ActiveProfile.Role_Template_Safe = ''
        $r = Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UTR16 - Role_Group_Prefix blank on profile: Failures=1, no API call' {
        $script:ActiveProfile.Role_Group_Prefix = ''
        $r = Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafeMembersUpdateFromTemplateRole - errors' {

    BeforeEach {
        script:Reset-MockActiveProfile
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'UTR17 - RoleName does not match any role-prefixed template member: Failures=1, IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:Invoke-DefaultRouting -Method $Method -Endpoint $Endpoint -Body $Body }
        $testInput = $script:ValidInput.Clone()
        $testInput.RoleName = 'AdminGroup'
        $r = Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } -Times 0
    }

    It 'UTR18 - template members GET returns 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'UTR19 - template members GET returns 404: IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -ErrorMessage 'Safe not found' }
        $r = Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal      | Should -BeFalse
        $r.Errors.Count | Should -Be 1
    }

    It 'UTR20 - Update PUT fails (400): IsFatal=$false, error added' {
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET') { script:New-OkResponse -Data $script:TemplateMembersResponse }
            else { script:New-ErrResponse -StatusCode 400 -ErrorMessage 'Bad Request' }
        }
        $r = Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal      | Should -BeFalse
        $r.Errors.Count | Should -Be 1
    }

    It 'UTR21 - Update PUT returns 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET') { script:New-OkResponse -Data $script:TemplateMembersResponse }
            else { script:New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        }
        $r = Invoke-SafeMembersUpdateFromTemplateRole -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}
