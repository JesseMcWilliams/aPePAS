#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Groups\Invoke-GroupsRemoveMember.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-GroupsRemoveMemberInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Groups\Invoke-GroupsRemoveMember.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-GroupsRemoveMember into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'GroupsRemoveMemberTests' -MinLevel 'ERROR'

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

    # MemberID is the username despite its name (confirmed: the DELETE path segment expects the
    # username, e.g. "ca_jesse", not a numeric user ID) - this module already treated it as a
    # plain string end-to-end, so no code change was needed, only the fixture/description here.
    $script:ValidInput = @{ GroupID = '42'; MemberID = 'ca_jesse' }

    # Factory: build a mock API success response for a delete (204 No Content)
    function script:New-DeleteApiResponse {
        param([bool]$IsSuccess = $true, [int]$StatusCode = 204)
        return [PSCustomObject]@{
            IsSuccess     = $IsSuccess
            StatusCode    = $StatusCode
            StatusMessage = 'No Content'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $null
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

    It 'GRM01 - ModuleMeta.Name = Remove Group Member' {
        $ModuleMeta.Name | Should -Be 'Remove Group Member'
    }

    It 'GRM02 - ModuleMeta.SupportsWhatIf = $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsRemoveMember - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GRM03 - Successes=1, ItemsProcessed=1' {
        $r = Invoke-GroupsRemoveMember -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes      | Should -Be 1
        $r.ItemsProcessed | Should -Be 1
    }

    It 'GRM04 - IsFatal=$false' {
        $r = Invoke-GroupsRemoveMember -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'GRM05 - DELETE method used' {
        Invoke-GroupsRemoveMember -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'GRM06 - endpoint contains both GroupID and MemberID' {
        Invoke-GroupsRemoveMember -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Endpoint -like '*UserGroups/42/Members/ca_jesse*' }
    }

    It 'GRM07 - result entry has Removed=$true' {
        $r = Invoke-GroupsRemoveMember -Token $script:MockToken -InputData $script:ValidInput
        $r.Results.Count      | Should -Be 1
        $r.Results[0].Removed | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsRemoveMember - WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GRM08 - WhatIf - API NOT called (Times=0)' {
        Invoke-GroupsRemoveMember -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'GRM09 - WhatIf - Successes=1' {
        $r = Invoke-GroupsRemoveMember -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsRemoveMember - validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GRM10 - empty GroupID - Failures=1' {
        $r = Invoke-GroupsRemoveMember -Token $script:MockToken -InputData @{ GroupID = ''; MemberID = '7' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'GRM11 - empty MemberID - Failures=1' {
        $r = Invoke-GroupsRemoveMember -Token $script:MockToken -InputData @{ GroupID = '42'; MemberID = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsRemoveMember - API errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GRM12 - 401 - IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-GroupsRemoveMember -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'GRM13 - status 0 - IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-GroupsRemoveMember -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsRemoveMember - URL encoding' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GRM14 - GroupID and MemberID URL-encoded in endpoint' {
        $capturedEndpoint = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedEndpoint -Value $PSBoundParameters.Endpoint -Scope Script
            script:New-DeleteApiResponse
        }
        Invoke-GroupsRemoveMember -Token $script:MockToken -InputData @{ GroupID = 'My Group'; MemberID = 'My Member' }
        $script:capturedEndpoint | Should -Match 'My%20Group'
        $script:capturedEndpoint | Should -Match 'My%20Member'
    }
}
