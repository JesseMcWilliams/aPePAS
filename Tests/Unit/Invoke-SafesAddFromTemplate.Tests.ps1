#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Safes\Invoke-SafesAddFromTemplate.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafesAddFromTemplateInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesAddFromTemplate.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-SafesAddFromTemplate into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafesAddFromTemplateTests' -MinLevel 'ERROR'

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

    $script:ValidInput = @{
        SafeName    = 'NewSafe'
        Description = 'Stamped from template'
    }

    # Sample template safe settings (GET /API/Safes/TemplateSafe response shape - camelCase)
    $script:TemplateSafeResponse = [PSCustomObject]@{
        safeName                  = 'TemplateSafe'
        description               = 'The standard template'
        location                  = '\Templates'
        managingCPM              = 'PasswordManager'
        numberOfVersionsRetention = 7
        numberOfDaysRetention     = 0
        autoPurgeEnabled          = $true
        olacEnabled               = $true
    }

    # Sample template safe member list (GET /API/Safes/TemplateSafe/Members response shape).
    # One role group (excluded by prefix), one non-role group, one user (both copied).
    $script:TemplateMembersResponse = [PSCustomObject]@{
        value = @(
            [PSCustomObject]@{
                memberName = 'CyberArk_TemplateSafe_Admins'
                memberType = 'Group'
                membershipExpirationDate = '2026-01-01'
                permissions = [PSCustomObject]@{ manageSafe = $true; manageSafeMembers = $true }
            },
            [PSCustomObject]@{
                memberName = 'AdminGroup'
                memberType = 'Group'
                membershipExpirationDate = $null
                permissions = [PSCustomObject]@{ useAccounts = $true; listAccounts = $true }
            },
            [PSCustomObject]@{
                memberName = 'jdoe'
                memberType = 'User'
                membershipExpirationDate = $null
                permissions = [PSCustomObject]@{ useAccounts = $true; retrieveAccounts = $true; listAccounts = $true }
            }
        )
    }

    $script:CreatedSafeResponse = [PSCustomObject]@{
        safeName                  = 'NewSafe'
        description               = 'Stamped from template'
        location                  = '\Templates'
        managingCPM              = 'PasswordManager'
        numberOfVersionsRetention = 7
        numberOfDaysRetention     = 0
        autoPurgeEnabled          = $true
        olacEnabled               = $true
    }

    # Factory: standard success envelope
    function script:New-OkResponse {
        param([object]$Data, [int]$StatusCode = 200)
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = $StatusCode
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $Data
        }
    }

    # Factory: standard failure envelope
    function script:New-ErrResponse {
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

    # Routes the single Invoke-CyberArkAPI mock to the right canned response by Method/Endpoint.
    # Member-add POSTs echo back the submitted memberName/memberType, like the real API does.
    function script:Invoke-DefaultRouting {
        param($Method, $Endpoint, $Body)
        if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe') {
            return script:New-OkResponse -Data $script:TemplateSafeResponse
        }
        if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe/Members') {
            return script:New-OkResponse -Data $script:TemplateMembersResponse
        }
        if ($Method -eq 'POST' -and $Endpoint -eq '/API/Safes') {
            # Echo back ManagingCPM from the submitted body, like the real API does - the rest
            # of the fixture stays fixed since no other field is InputData-driven.
            $echoedCPM = if ($Body -and $Body.ContainsKey('ManagingCPM')) { $Body.ManagingCPM } else { $script:CreatedSafeResponse.managingCPM }
            return script:New-OkResponse -Data ([PSCustomObject]@{
                safeName                  = $script:CreatedSafeResponse.safeName
                description               = $script:CreatedSafeResponse.description
                location                  = $script:CreatedSafeResponse.location
                managingCPM               = $echoedCPM
                numberOfVersionsRetention = $script:CreatedSafeResponse.numberOfVersionsRetention
                numberOfDaysRetention     = $script:CreatedSafeResponse.numberOfDaysRetention
                autoPurgeEnabled          = $script:CreatedSafeResponse.autoPurgeEnabled
                olacEnabled               = $script:CreatedSafeResponse.olacEnabled
            }) -StatusCode 201
        }
        if ($Method -eq 'POST' -and $Endpoint -like '/API/Safes/NewSafe/Members') {
            return script:New-OkResponse -Data ([PSCustomObject]@{ safeName = 'NewSafe'; memberName = $Body.memberName; memberType = $Body.memberType }) -StatusCode 201
        }
        return script:New-ErrResponse -StatusCode 500 -ErrorMessage 'Unrouted mock call'
    }

    function script:Reset-MockActiveProfile {
        $script:ActiveProfile = [PSCustomObject]@{
            Role_Template_Safe = 'TemplateSafe'
            Role_Group_Prefix  = 'CyberArk_'
            IgnoreSSL          = $false
        }
        # Manage-Privilege.ps1 defines this as a script:-scoped constant, dot-sourced into every
        # module's effective scope. Tests dot-source only the module file, so it must be
        # set explicitly here - same reason $script:ActiveProfile is faked above.
        $script:ExcludedTemplateMemberNames = @()
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
    Remove-Variable -Name ActiveProfile -Scope Script -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'T01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'T02 - Category is Safes and Action is AddFromTemplate' {
        $ModuleMeta.Category | Should -Be 'Safes'
        $ModuleMeta.Action   | Should -Be 'AddFromTemplate'
    }

    It 'T03 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'T04 - SupportedSystems contains ISPSS and SelfHosted' {
        $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
    }

    It 'T05 - InputSchema contains SafeName with Required=$true' {
        $safeNameField = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'SafeName' }
        $safeNameField          | Should -Not -BeNullOrEmpty
        $safeNameField.Required | Should -BeTrue
    }

    It 'T06 - InputSchema contains Description with Required=$false' {
        $descField = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'Description' }
        $descField          | Should -Not -BeNullOrEmpty
        $descField.Required | Should -BeFalse
    }

    It 'T06a - InputSchema contains ManagingCPM with Required=$false' {
        $field = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'ManagingCPM' }
        $field          | Should -Not -BeNullOrEmpty
        $field.Required | Should -BeFalse
    }

    It 'T06b - InputSchema contains ExtraMembers with Required=$false' {
        $field = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'ExtraMembers' }
        $field          | Should -Not -BeNullOrEmpty
        $field.Required | Should -BeFalse
    }

    It 'T06c - ExtraMembers Example demonstrates the Type:Name:RoleName;... CSV syntax' {
        $field = $ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'ExtraMembers' }
        $field.Example | Should -Match '^(User|Group):[^:;]+:[^:;]+(;(User|Group):[^:;]+:[^:;]+)*$'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAddFromTemplate - success' {

    BeforeEach {
        Set-StrictMode -Version Latest
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI { script:Invoke-DefaultRouting -Method $Method -Endpoint $Endpoint -Body $Body }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'T07 - IsFatal is $false' {
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'T08 - creates the safe: one Results row with ItemType=Safe' {
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        @($r.Results | Where-Object { $_.ItemType -eq 'Safe' }).Count | Should -Be 1
    }

    It 'T09 - copies only the two non-role members (excludes the CyberArk_ group)' {
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $memberRows = @($r.Results | Where-Object { $_.ItemType -eq 'Member' })
        $memberRows.Count            | Should -Be 2
        $memberRows.MemberName       | Should -Not -Contain 'CyberArk_TemplateSafe_Admins'
        $memberRows.MemberName       | Should -Contain 'AdminGroup'
    }

    It 'T09a - global $script:ExcludedTemplateMemberNames also excludes a member, regardless of type' {
        $script:ExcludedTemplateMemberNames = @('jdoe')
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $memberRows = @($r.Results | Where-Object { $_.ItemType -eq 'Member' })
        $memberRows.Count      | Should -Be 1
        $memberRows.MemberName | Should -Not -Contain 'jdoe'
        $memberRows.MemberName | Should -Contain 'AdminGroup'
    }

    It 'T09b - exclusion match is case-insensitive and exact (not a prefix match)' {
        $script:ExcludedTemplateMemberNames = @('JDOE', 'AdminGroupExtra')
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $memberRows = @($r.Results | Where-Object { $_.ItemType -eq 'Member' })
        $memberRows.MemberName | Should -Not -Contain 'jdoe'
        $memberRows.MemberName | Should -Contain 'AdminGroup'
    }

    It 'T09c - the template safe creator is excluded from the copy even though not role-prefixed (confirmed live: CyberArk rejects re-adding it with HTTP 403)' {
        $script:TemplateSafeResponse | Add-Member -NotePropertyName 'creator' -NotePropertyValue ([PSCustomObject]@{ id = '34'; name = 'CA_Admin' }) -Force
        $script:TemplateMembersResponse.value += [PSCustomObject]@{
            memberName = 'CA_Admin'
            memberType = 'User'
            membershipExpirationDate = $null
            permissions = [PSCustomObject]@{ manageSafe = $true }
        }
        try {
            $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
            $memberRows = @($r.Results | Where-Object { $_.ItemType -eq 'Member' })
            $memberRows.MemberName | Should -Not -Contain 'CA_Admin'
            $memberRows.MemberName | Should -Contain 'AdminGroup'
        } finally {
            $script:TemplateSafeResponse.PSObject.Properties.Remove('creator')
            $script:TemplateMembersResponse.value = @($script:TemplateMembersResponse.value | Where-Object { $_.memberName -ne 'CA_Admin' })
        }
    }

    It 'T10 - Successes=3 (1 safe + 2 members), Failures=0' {
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes | Should -Be 3
        $r.Failures  | Should -Be 0
    }

    It 'T11 - safe creation POST body copies Location/AutoPurgeEnabled from the template; ManagingCPM defaults to blank (not copied)' {
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Safes' -and
            $Body.SafeName -eq 'NewSafe' -and
            $Body.Description -eq 'Stamped from template' -and
            $Body.Location -eq '\Templates' -and
            $Body.ManagingCPM -eq '' -and
            $Body.AutoPurgeEnabled -eq $true
        } -Times 1
    }

    It 'T11d - ManagingCPM in InputData is sent as-is, still not copied from the template' {
        $testInput = $script:ValidInput.Clone()
        $testInput.ManagingCPM = 'ChosenCPM'
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $testInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Safes' -and
            $Body.ManagingCPM -eq 'ChosenCPM'
        } -Times 1
    }

    It 'T11e - result Safe row reflects the chosen ManagingCPM' {
        $testInput = $script:ValidInput.Clone()
        $testInput.ManagingCPM = 'ChosenCPM'
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $testInput
        ($r.Results | Where-Object { $_.ItemType -eq 'Safe' }).ManagingCPM | Should -Be 'ChosenCPM'
    }

    It 'T11a - OLACEnabled is never included in the safe creation body' {
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Safes' -and
            -not $Body.ContainsKey('OLACEnabled')
        } -Times 1
    }

    It 'T11b - template has NumberOfDaysRetention=0: only NumberOfVersionsRetention is sent' {
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Safes' -and
            $Body.NumberOfVersionsRetention -eq 7 -and
            (-not $Body.ContainsKey('NumberOfDaysRetention'))
        } -Times 1
    }

    It 'T11c - template has NumberOfDaysRetention>0: only NumberOfDaysRetention is sent' {
        $script:TemplateSafeResponse.numberOfDaysRetention = 90
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Safes' -and
            $Body.NumberOfDaysRetention -eq 90 -and
            (-not $Body.ContainsKey('NumberOfVersionsRetention'))
        } -Times 1
        $script:TemplateSafeResponse.numberOfDaysRetention = 0
    }

    It 'T12 - member copy POST omits membershipExpirationDate (always null)' {
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Safes/NewSafe/Members' -and
            $null -eq $Body.membershipExpirationDate
        } -Times 2
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAddFromTemplate - ExtraMembers' {

    BeforeEach {
        Set-StrictMode -Version Latest
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI { script:Invoke-DefaultRouting -Method $Method -Endpoint $Endpoint -Body $Body }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'T25 - one valid ExtraMembers entry: added with the resolved role permissions and memberType' {
        $testInput = $script:ValidInput.Clone()
        $testInput.ExtraMembers = 'User:newuser:CyberArk_TemplateSafe_Admins'
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $testInput

        $extraRow = $r.Results | Where-Object { $_.ItemType -eq 'Member' -and $_.MemberName -eq 'newuser' }
        $extraRow                | Should -Not -BeNullOrEmpty
        $extraRow.MemberType     | Should -Be 'User'
        $extraRow.RoleName       | Should -Be 'CyberArk_TemplateSafe_Admins'

        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Safes/NewSafe/Members' -and
            $Body.memberName -eq 'newuser' -and
            $Body.memberType -eq 'User' -and
            $null -eq $Body.membershipExpirationDate -and
            $Body.permissions.manageSafe -eq $true -and
            $Body.permissions.manageSafeMembers -eq $true
        } -Times 1
    }

    It 'T26 - two ExtraMembers entries (semicolon-separated): both added' {
        $testInput = $script:ValidInput.Clone()
        $testInput.ExtraMembers = 'User:newuser:CyberArk_TemplateSafe_Admins;Group:newgroup:CyberArk_TemplateSafe_Admins'
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $testInput

        $extraRows = $r.Results | Where-Object { $_.ItemType -eq 'Member' -and $_.MemberName -in @('newuser', 'newgroup') }
        $extraRows.Count | Should -Be 2
        ($extraRows | Where-Object { $_.MemberName -eq 'newgroup' }).MemberType | Should -Be 'Group'
    }

    It 'T27 - malformed ExtraMembers entry: recorded as an error, safe still created, other entries unaffected' {
        $testInput = $script:ValidInput.Clone()
        $testInput.ExtraMembers = 'NotAType:baduser:CyberArk_TemplateSafe_Admins;User:gooduser:CyberArk_TemplateSafe_Admins'
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $testInput

        @($r.Results | Where-Object { $_.ItemType -eq 'Safe' }).Count | Should -Be 1
        @($r.Results | Where-Object { $_.MemberName -eq 'gooduser' }).Count | Should -Be 1
        $r.Errors.Count | Should -Be 1
        $r.IsFatal       | Should -BeFalse
    }

    It 'T28 - RoleName not found among template role members: error recorded, safe and other members unaffected' {
        $testInput = $script:ValidInput.Clone()
        $testInput.ExtraMembers = 'User:newuser:CyberArk_NoSuchRole'
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $testInput

        @($r.Results | Where-Object { $_.ItemType -eq 'Safe' }).Count | Should -Be 1
        $r.Errors.Count | Should -Be 1
        $r.IsFatal       | Should -BeFalse
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Safes/NewSafe/Members' -and $Body.memberName -eq 'newuser'
        } -Times 0
    }

    It 'T29 - blank ExtraMembers: no extra members added, no error' {
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.Errors.Count | Should -Be 0
        ($r.Results | Where-Object { $_.ItemType -eq 'Member' }).Count | Should -Be 2   # only the two template-copied members
    }
}

# ─────────────────────────────────────────────────────────────────
# Regression coverage for a real production crash: [array]$x = if (cond) {@(...)} else {@()}
# collapses to $null (not an empty array) when the else branch fires, because PowerShell
# unrolls a script block's output and an empty @() emits zero objects. $null.Count then throws
# PropertyNotFoundException under Set-StrictMode - which every real invocation runs under (via
# Manage-Privilege.ps1), but this test file does NOT, since it dot-sources only the module file.
# Every test below sets Set-StrictMode -Version Latest itself (scoped to its own It block, not
# leaked to siblings - confirmed by T29 above and the ExtraMembers tests still passing) so it
# actually catches a regression instead of silently passing regardless, the way T09a/T09b
# already did for the $excludedNames instance of this same bug before it was fixed. See
# Docs\Lessons-Learned-PowerShell-Pester.md, "Unit tests do not run under Set-StrictMode".
Describe 'Invoke-SafesAddFromTemplate - array-collapse regression (strict mode)' {

    BeforeEach {
        Set-StrictMode -Version Latest
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI { script:Invoke-DefaultRouting -Method $Method -Endpoint $Endpoint -Body $Body }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'T30 - empty $script:ExcludedTemplateMemberNames does not throw under strict mode' {
        # No explicit try/catch or "Should -Not -Throw" needed: Pester already fails an It block
        # on any uncaught exception, and wrapping the call in a scriptblock for
        # "Should -Not -Throw" would run it in a child scope, so a result variable assigned
        # inside would not actually propagate back out for the assertions below.
        Set-StrictMode -Version Latest
        $script:ExcludedTemplateMemberNames = @()
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'T31 - template safe with zero members does not throw under strict mode' {
        Set-StrictMode -Version Latest
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe') {
                return script:New-OkResponse -Data $script:TemplateSafeResponse
            }
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe/Members') {
                return script:New-OkResponse -Data ([PSCustomObject]@{ value = @() })
            }
            if ($Method -eq 'POST' -and $Endpoint -eq '/API/Safes') {
                return script:New-OkResponse -Data $script:CreatedSafeResponse -StatusCode 201
            }
            return script:New-ErrResponse -StatusCode 500 -ErrorMessage 'Unrouted mock call'
        }
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        # @(...) wrap required here too: zero matches from Where-Object collapses to $null on
        # capture (same bug this whole Describe is about), and .Count on that throws.
        @($r.Results | Where-Object { $_.ItemType -eq 'Member' }).Count | Should -Be 0
    }

    # T32-T35 (script:Get-ProfileCPMOptions strict-mode-safety tests) were removed 2026-09-03:
    # that function was deleted when the CPM picker moved to the shared Get-CpmOptions
    # (Manage-Privilege.ps1, live API with a CPM_List fallback - see Architecture.md). Like the
    # similar shared helper Invoke-EntitySearch, it has no unit test coverage of its own - see
    # Testing-Plan.md for the manual-verification note.
}

# ─────────────────────────────────────────────────────────────────
Describe 'script:Get-TemplateRoleOptions - role descriptions' {

    BeforeEach {
        Set-StrictMode -Version Latest
        script:Reset-MockActiveProfile
        Mock Write-CyberArkLog { }
    }

    It 'T36 - a role matched to a group with a description gets it populated' {
        Mock Invoke-CyberArkAPI {
            if ($Endpoint -eq '/API/Safes/TemplateSafe/Members') {
                return script:New-OkResponse -Data ([PSCustomObject]@{ value = @(
                    [PSCustomObject]@{ memberName = 'CyberArk_Admins'; memberType = 'Group'; permissions = [PSCustomObject]@{ manageSafe = $true } }
                ) })
            }
            if ($Endpoint -eq '/API/UserGroups') {
                return script:New-OkResponse -Data ([PSCustomObject]@{ value = @(
                    [PSCustomObject]@{ groupName = 'CyberArk_Admins'; description = 'Full administrative access to the safe' }
                ) })
            }
            return script:New-ErrResponse -StatusCode 500 -ErrorMessage 'Unrouted mock call'
        }
        [array]$roleOptions = @(script:Get-TemplateRoleOptions -Token $script:MockToken)
        $roleOptions.Count | Should -Be 1
        $roleOptions[0].Description | Should -Be 'Full administrative access to the safe'
    }

    It 'T37 - a role matched to a group with no description stays blank' {
        Mock Invoke-CyberArkAPI {
            if ($Endpoint -eq '/API/Safes/TemplateSafe/Members') {
                return script:New-OkResponse -Data ([PSCustomObject]@{ value = @(
                    [PSCustomObject]@{ memberName = 'CyberArk_Viewers'; memberType = 'Group'; permissions = [PSCustomObject]@{ listAccounts = $true } }
                ) })
            }
            if ($Endpoint -eq '/API/UserGroups') {
                return script:New-OkResponse -Data ([PSCustomObject]@{ value = @(
                    [PSCustomObject]@{ groupName = 'CyberArk_Viewers'; description = '' }
                ) })
            }
            return script:New-ErrResponse -StatusCode 500 -ErrorMessage 'Unrouted mock call'
        }
        [array]$roleOptions = @(script:Get-TemplateRoleOptions -Token $script:MockToken)
        $roleOptions[0].Description | Should -Be ''
    }

    It 'T38 - no matching group found: role still returned, Description blank' {
        Mock Invoke-CyberArkAPI {
            if ($Endpoint -eq '/API/Safes/TemplateSafe/Members') {
                return script:New-OkResponse -Data ([PSCustomObject]@{ value = @(
                    [PSCustomObject]@{ memberName = 'CyberArk_Orphan'; memberType = 'Group'; permissions = [PSCustomObject]@{} }
                ) })
            }
            if ($Endpoint -eq '/API/UserGroups') {
                return script:New-OkResponse -Data ([PSCustomObject]@{ value = @() })
            }
            return script:New-ErrResponse -StatusCode 500 -ErrorMessage 'Unrouted mock call'
        }
        [array]$roleOptions = @(script:Get-TemplateRoleOptions -Token $script:MockToken)
        $roleOptions.Count           | Should -Be 1
        $roleOptions[0].Name         | Should -Be 'CyberArk_Orphan'
        $roleOptions[0].Description  | Should -Be ''
    }

    It 'T39 - GET /API/UserGroups fails: roles still returned with blank descriptions, no throw' {
        Mock Invoke-CyberArkAPI {
            if ($Endpoint -eq '/API/Safes/TemplateSafe/Members') {
                return script:New-OkResponse -Data ([PSCustomObject]@{ value = @(
                    [PSCustomObject]@{ memberName = 'CyberArk_Admins'; memberType = 'Group'; permissions = [PSCustomObject]@{ manageSafe = $true } }
                ) })
            }
            if ($Endpoint -eq '/API/UserGroups') {
                return script:New-ErrResponse -StatusCode 403 -ErrorMessage 'Forbidden'
            }
            return script:New-ErrResponse -StatusCode 500 -ErrorMessage 'Unrouted mock call'
        }
        [array]$roleOptions = @(script:Get-TemplateRoleOptions -Token $script:MockToken)
        $roleOptions.Count           | Should -Be 1
        $roleOptions[0].Permissions.manageSafe | Should -BeTrue
        $roleOptions[0].Description  | Should -Be ''
    }

    It 'T40 - zero roles found: GET /API/UserGroups is never called' {
        Mock Invoke-CyberArkAPI {
            if ($Endpoint -eq '/API/Safes/TemplateSafe/Members') {
                return script:New-OkResponse -Data ([PSCustomObject]@{ value = @() })
            }
            return script:New-ErrResponse -StatusCode 500 -ErrorMessage 'Unrouted mock call'
        }
        [array]$roleOptions = @(script:Get-TemplateRoleOptions -Token $script:MockToken)
        $roleOptions.Count | Should -Be 0
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Endpoint -eq '/API/UserGroups' } -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'script:Get-DescriptionDisplayLines' {

    BeforeEach {
        Set-StrictMode -Version Latest
    }

    It 'T41 - splits CRLF, LF, and mixed line breaks into separate trimmed lines' {
        $desc = "Full admin access`r`nto the safe.`n  Grants manage.`r`nSecond line."
        [array]$lines = @(script:Get-DescriptionDisplayLines -Description $desc)
        $lines.Count | Should -Be 4
        $lines[0]    | Should -Be 'Full admin access'
        $lines[1]    | Should -Be 'to the safe.'
        $lines[2]    | Should -Be 'Grants manage.'
        $lines[3]    | Should -Be 'Second line.'
    }

    It 'T42 - blank lines (including whitespace-only) are dropped, not returned as gaps' {
        $desc = "First line.`r`n`r`n   `nSecond line."
        [array]$lines = @(script:Get-DescriptionDisplayLines -Description $desc)
        $lines.Count | Should -Be 2
        $lines[0]    | Should -Be 'First line.'
        $lines[1]    | Should -Be 'Second line.'
    }

    It 'T43 - blank, whitespace-only, or null Description returns an empty array, not $null' {
        Set-StrictMode -Version Latest
        [array]$blank      = @(script:Get-DescriptionDisplayLines -Description '')
        [array]$whitespace = @(script:Get-DescriptionDisplayLines -Description "   `r`n  ")
        [array]$nullDesc   = @(script:Get-DescriptionDisplayLines -Description $null)
        $blank.Count      | Should -Be 0
        $whitespace.Count | Should -Be 0
        $nullDesc.Count   | Should -Be 0
    }

    It 'T44 - a single-line description with no line breaks returns one trimmed line' {
        [array]$lines = @(script:Get-DescriptionDisplayLines -Description '  Single line description  ')
        $lines.Count | Should -Be 1
        $lines[0]    | Should -Be 'Single line description'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAddFromTemplate - WhatIf' {

    BeforeEach {
        Set-StrictMode -Version Latest
        # Strict mode: this is the block that hid a real production crash (unconditional dot
        # notation on $safeBody.NumberOfVersionsRetention/NumberOfDaysRetention, which are
        # mutually exclusive - see the "array-collapse regression" Describe above for the full
        # explanation of why this test file needs to opt into strict mode explicitly).
        Set-StrictMode -Version Latest
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET') { script:Invoke-DefaultRouting -Method $Method -Endpoint $Endpoint }
            else { script:New-OkResponse -Data $null }
        }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'T13 - WhatIf: no POST call is made' {
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' } -Times 0
    }

    It 'T14 - WhatIf: still reads the template safe and its members (GET calls happen)' {
        Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } -Times 2
    }

    It 'T15 - WhatIf: synthetic Results contain 1 safe row + 2 member rows' {
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Results.Count | Should -Be 3
        $r.IsFatal        | Should -BeFalse
    }

    It 'T15a - WhatIf: ExtraMembers entries appear as additional synthetic Member rows, no POST' {
        $testInput = $script:ValidInput.Clone()
        $testInput.ExtraMembers = 'User:newuser:CyberArk_TemplateSafe_Admins'
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $testInput -WhatIf
        $r.Results.Count | Should -Be 4
        $extraRow = $r.Results | Where-Object { $_.MemberName -eq 'newuser' }
        $extraRow.RoleName | Should -Be 'CyberArk_TemplateSafe_Admins'
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' } -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAddFromTemplate - validation' {

    BeforeEach {
        Set-StrictMode -Version Latest
        script:Reset-MockActiveProfile
        Mock Invoke-CyberArkAPI { }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'T16 - empty SafeName: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = ''
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'T17 - Role_Template_Safe blank on profile: Failures=1, no API call' {
        $script:ActiveProfile.Role_Template_Safe = ''
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'T18 - Role_Group_Prefix blank on profile: Failures=1, no API call' {
        $script:ActiveProfile.Role_Group_Prefix = ''
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesAddFromTemplate - errors' {

    BeforeEach {
        Set-StrictMode -Version Latest
        script:Reset-MockActiveProfile
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'T19 - template safe not found (404): IsFatal=$false, error added, no safe created' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -ErrorMessage 'Safe not found' }
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal      | Should -BeFalse
        $r.Errors.Count | Should -Be 1
        $r.Results.Count | Should -Be 0
    }

    It 'T20 - template safe read returns 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'T21 - template members read fails (403): IsFatal=$false, safe not created' {
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe') {
                script:New-OkResponse -Data $script:TemplateSafeResponse
            } else {
                script:New-ErrResponse -StatusCode 403 -ErrorMessage 'Forbidden'
            }
        }
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal        | Should -BeFalse
        $r.Errors.Count   | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' } -Times 0
    }

    It 'T22 - safe creation POST fails (409): IsFatal=$false, no member POSTs attempted' {
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe') {
                script:New-OkResponse -Data $script:TemplateSafeResponse
            } elseif ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe/Members') {
                script:New-OkResponse -Data $script:TemplateMembersResponse
            } else {
                script:New-ErrResponse -StatusCode 409 -ErrorMessage 'Safe already exists'
            }
        }
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal        | Should -BeFalse
        $r.Errors.Count   | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' -and $Endpoint -like '*Members*' } -Times 0
    }

    It 'T23 - one member POST fails (403): loop continues, other member still copied' {
        $callCount = 0
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe') {
                return script:New-OkResponse -Data $script:TemplateSafeResponse
            }
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe/Members') {
                return script:New-OkResponse -Data $script:TemplateMembersResponse
            }
            if ($Method -eq 'POST' -and $Endpoint -eq '/API/Safes') {
                return script:New-OkResponse -Data $script:CreatedSafeResponse -StatusCode 201
            }
            $script:callCount++
            if ($script:callCount -eq 1) {
                return script:New-ErrResponse -StatusCode 403 -ErrorMessage 'Forbidden'
            }
            return script:New-OkResponse -Data ([PSCustomObject]@{ safeName = 'NewSafe'; memberName = 'member'; memberType = 'Group' }) -StatusCode 201
        }
        $script:callCount = 0
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal        | Should -BeFalse
        $r.Failures       | Should -Be 1
        @($r.Results | Where-Object { $_.ItemType -eq 'Member' }).Count | Should -Be 1
    }

    It 'T24 - member POST returns 401: IsFatal=$true, loop stops' {
        Mock Invoke-CyberArkAPI {
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe') {
                return script:New-OkResponse -Data $script:TemplateSafeResponse
            }
            if ($Method -eq 'GET' -and $Endpoint -eq '/API/Safes/TemplateSafe/Members') {
                return script:New-OkResponse -Data $script:TemplateMembersResponse
            }
            if ($Method -eq 'POST' -and $Endpoint -eq '/API/Safes') {
                return script:New-OkResponse -Data $script:CreatedSafeResponse -StatusCode 201
            }
            return script:New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized'
        }
        $r = Invoke-SafesAddFromTemplate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}
