#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Groups\Invoke-GroupsGetMembers.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-GroupsGetMembersInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Groups\Invoke-GroupsGetMembers.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-GroupsGetMembers into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'GroupsGetMembersTests' -MinLevel 'ERROR'

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

    # Sample member objects matching the CyberArk API shape
    $script:Member1 = [PSCustomObject]@{ id = 1; username = 'jsmith';      userType = 'EPVUser'; componentUser = $false }
    $script:Member2 = [PSCustomObject]@{ id = 2; username = 'svc_account'; userType = 'EPVUser'; componentUser = $true  }

    $script:ValidInput = @{ GroupID = '42' }

    # Factory: build a mock API success response containing the given member objects.
    # Members are returned inline on GET /API/UserGroups/{id} under the 'members' property.
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
                id      = 42
                members = $Members
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

    It 'GM01 - ModuleMeta.Name = Get Group Members' {
        $ModuleMeta.Name | Should -Be 'Get Group Members'
    }

    It 'GM02 - ModuleMeta.SupportsWhatIf = $false' {
        $ModuleMeta.SupportsWhatIf | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsGetMembers - successful response' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-MembersApiResponse -Members @($script:Member1, $script:Member2)
        }
        Mock Write-CyberArkLog { }
    }

    It 'GM03 - Successes=2, ItemsProcessed=2 when two members returned' {
        $r = Invoke-GroupsGetMembers -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes      | Should -Be 2
        $r.ItemsProcessed | Should -Be 2
    }

    It 'GM04 - result entries have MemberID, Username, UserType, ComponentUser' {
        $r = Invoke-GroupsGetMembers -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'MemberID'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'Username'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'UserType'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'ComponentUser'
    }

    It 'GM05 - MemberID=1, Username=jsmith from response' {
        $r = Invoke-GroupsGetMembers -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].MemberID  | Should -Be 1
        $r.Results[0].Username  | Should -Be 'jsmith'
    }

    It 'GM07 - GET method used' {
        Invoke-GroupsGetMembers -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'GET' }
    }

    It 'GM08 - endpoint is bare group GET with GroupID (/API/UserGroups/42)' {
        Invoke-GroupsGetMembers -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Endpoint -eq '/API/UserGroups/42' }
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsGetMembers - empty result' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-MembersApiResponse -Members @()
        }
        Mock Write-CyberArkLog { }
    }

    It 'GM06 - empty value array - Successes=0, Failures=0' {
        $r = Invoke-GroupsGetMembers -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes | Should -Be 0
        $r.Failures  | Should -Be 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsGetMembers - validation' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'GM09 - empty GroupID - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-GroupsGetMembers -Token $script:MockToken -InputData @{ GroupID = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'GM10 - null InputData - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-GroupsGetMembers -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsGetMembers - API errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'GM11 - 401 - IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-GroupsGetMembers -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'GM12 - status 0 - IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-GroupsGetMembers -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsGetMembers - URL encoding' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'GM13 - GroupID URL-encoded in endpoint (42 Admins -> 42%20Admins)' {
        $capturedEndpoint = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedEndpoint -Value $PSBoundParameters.Endpoint -Scope Script
            script:New-MembersApiResponse -Members @()
        }
        Invoke-GroupsGetMembers -Token $script:MockToken -InputData @{ GroupID = '42 Admins' }
        $script:capturedEndpoint | Should -Match '42%20Admins'
    }
}

# ─────────────────────────────────────────────────────────────────
# includeMembers is optional and defaults to false server-side (confirmed against a live
# tenant) - omitting it is the pre-existing default behavior, not the silent-empty-results
# risk originally suspected. Exposed as an opt-in field matching psPAS's own parameter.
Describe 'Invoke-GroupsGetMembers - IncludeMembers' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'GM14 - IncludeMembers not provided - no includeMembers query param sent' {
        $capturedQueryParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedQueryParams -Value $PSBoundParameters.QueryParams -Scope Script
            script:New-MembersApiResponse -Members @()
        }
        Invoke-GroupsGetMembers -Token $script:MockToken -InputData $script:ValidInput
        $script:capturedQueryParams.ContainsKey('includeMembers') | Should -Be $false
    }

    It 'GM15 - IncludeMembers=true - includeMembers=true query param sent' {
        $capturedQueryParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedQueryParams -Value $PSBoundParameters.QueryParams -Scope Script
            script:New-MembersApiResponse -Members @()
        }
        Invoke-GroupsGetMembers -Token $script:MockToken -InputData @{ GroupID = '42'; IncludeMembers = 'true' }
        $script:capturedQueryParams['includeMembers'] | Should -Be 'true'
    }

    It 'GM16 - IncludeMembers=false (explicit CSV string) - no includeMembers query param sent' {
        $capturedQueryParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedQueryParams -Value $PSBoundParameters.QueryParams -Scope Script
            script:New-MembersApiResponse -Members @()
        }
        Invoke-GroupsGetMembers -Token $script:MockToken -InputData @{ GroupID = '42'; IncludeMembers = 'false' }
        $script:capturedQueryParams.ContainsKey('includeMembers') | Should -Be $false
    }
}

# ─────────────────────────────────────────────────────────────────
# Confirmed live (2026-09-04) against a real Self-Hosted tenant: a real member entry is only
# { "username", "id" } - no userType/componentUser at all, with or without includeMembers=true.
# $script:Member1/Member2 above use psPAS's documented (fuller) shape, which is why this gap was
# never caught before - dot-accessing a genuinely absent property throws PropertyNotFoundException
# under Set-StrictMode, and every member mapped that way became a silent Failure instead of a
# Result row (confirmed live: "Members retrieved: 0" for a group that actually had 1 member).
Describe 'Invoke-GroupsGetMembers - real live member shape (no userType/componentUser)' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'GM17 - a member with only id/username (the real live shape) does not throw and maps correctly' {
        Set-StrictMode -Version Latest
        try {
            $realMember = [PSCustomObject]@{ id = 34; username = 'CA_Admin' }
            Mock Invoke-CyberArkAPI { script:New-MembersApiResponse -Members @($realMember) }
            $r = Invoke-GroupsGetMembers -Token $script:MockToken -InputData $script:ValidInput
            $r.Failures            | Should -Be 0
            $r.Successes           | Should -Be 1
            $r.Results[0].MemberID | Should -Be 34
            $r.Results[0].Username | Should -Be 'CA_Admin'
            $r.Results[0].UserType | Should -BeNullOrEmpty
            $r.Results[0].ComponentUser | Should -BeNullOrEmpty
        } finally {
            Set-StrictMode -Off
        }
    }
}
