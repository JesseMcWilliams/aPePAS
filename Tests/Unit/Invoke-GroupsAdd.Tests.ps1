#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Groups\Invoke-GroupsAdd.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-GroupsAddInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Groups\Invoke-GroupsAdd.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-GroupsAdd into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'GroupsAddTests' -MinLevel 'ERROR'

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
        GroupName   = 'VaultAdmins'
        Description = 'Vault admins'
        Location    = '\'
    }

    # Factory: build a mock API success response containing a single group object
    function script:New-GroupApiResponse {
        param(
            [PSCustomObject]$Group,
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
            Data          = $Group
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

    # Sample group object matching the CyberArk API shape for a POST /API/UserGroups response
    $script:SampleGroupResponse = [PSCustomObject]@{
        id          = 99
        groupName   = 'VaultAdmins'
        description = 'Vault admins'
        location    = '\'
        groupType   = 'EPVGroup'
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'GA01 - ModuleMeta.Name is ''Add Group''' {
        $ModuleMeta.Name | Should -Be 'Add Group'
    }

    It 'GA02 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsAdd - success (201)' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-GroupApiResponse -Group $script:SampleGroupResponse -StatusCode 201
        }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GA03 - Successes=1, Failures=0, ItemsProcessed=1 on success' {
        $r = Invoke-GroupsAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes      | Should -Be 1
        $r.Failures       | Should -Be 0
        $r.ItemsProcessed | Should -Be 1
    }

    It 'GA04 - IsFatal=$false on success' {
        $r = Invoke-GroupsAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'GA05 - POST method is used' {
        Invoke-GroupsAdd -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' } -Times 1
    }

    It 'GA06 - endpoint is /API/UserGroups' {
        Invoke-GroupsAdd -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -ParameterFilter { $Endpoint -eq '/API/UserGroups' } -Times 1
    }

    It 'GA07 - result entry has GroupID=99 and GroupName=''VaultAdmins''' {
        $r = Invoke-GroupsAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].GroupID   | Should -Be 99
        $r.Results[0].GroupName | Should -Be 'VaultAdmins'
    }

    It 'GA08 - request body contains groupName=''VaultAdmins''' {
        $script:CapturedBody = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $script:CapturedBody = $Body
            script:New-GroupApiResponse -Group $script:SampleGroupResponse -StatusCode 201
        }
        Invoke-GroupsAdd -Token $script:MockToken -InputData $script:ValidInput
        $script:CapturedBody.groupName | Should -Be 'VaultAdmins'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsAdd - WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{
                IsSuccess     = $true
                StatusCode    = 200
                StatusMessage = 'WhatIf'
                ErrorMessage  = $null
                ErrorDetails  = $null
                DataType      = 'JSON'
                RawResponse   = ''
                Data          = $null
            }
        }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GA09 - WhatIf: API is NOT called' {
        Invoke-GroupsAdd -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'GA10 - WhatIf: Successes=1 (synthetic result counted)' {
        $r = Invoke-GroupsAdd -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
    }

    It 'GA11 - WhatIf: result entry GroupName matches input' {
        $r = Invoke-GroupsAdd -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Results[0].GroupName | Should -Be $script:ValidInput.GroupName
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsAdd - validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GA12 - empty GroupName: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.GroupName = ''
        $r = Invoke-GroupsAdd -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'GA13 - null InputData: Failures=1, no API call' {
        $r = Invoke-GroupsAdd -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsAdd - errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GA14 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-GroupsAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'GA15 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-GroupsAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'GA16 - 409 Conflict: IsFatal=$false, Errors.Count=1' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 409 -ErrorMessage 'Group already exists' }
        $r = Invoke-GroupsAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal      | Should -BeFalse
        $r.Errors.Count | Should -Be 1
    }
}
