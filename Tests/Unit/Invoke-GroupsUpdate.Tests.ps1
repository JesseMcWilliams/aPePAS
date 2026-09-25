#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Groups\Invoke-GroupsUpdate.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-GroupsUpdateInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Groups\Invoke-GroupsUpdate.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-GroupsUpdate into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'GroupsUpdateTests' -MinLevel 'ERROR'

    # Minimal token stub (SelfHosted)
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://test.cyberark.local'
    }

    $script:ValidInput = @{
        GroupID     = '42'
        GroupName   = 'UpdatedAdmins'
        Description = 'Updated desc'
        Location    = '\'
    }

    # Factory: build a mock API success response for a group object
    function script:New-GroupApiResponse {
        param(
            [Parameter(Mandatory = $true)] [PSCustomObject]$Group,
            [int]$StatusCode = 200
        )
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = $StatusCode
            StatusMessage = 'OK'
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

    # Standard mock group returned by a successful PUT
    $script:MockGroupResponse = [PSCustomObject]@{
        id          = 42
        groupName   = 'UpdatedAdmins'
        description = 'Updated desc'
        location    = '\'
        groupType   = 'EPVGroup'
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'GU01 - ModuleMeta.Name = ''Update Group''' {
        $ModuleMeta.Name | Should -Be 'Update Group'
    }

    It 'GU02 - ModuleMeta.SupportsWhatIf = $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsUpdate - success' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { script:New-GroupApiResponse -Group $script:MockGroupResponse }
    }

    It 'GU03 - Successes=1, Failures=0, ItemsProcessed=1' {
        $r = Invoke-GroupsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes      | Should -Be 1
        $r.Failures       | Should -Be 0
        $r.ItemsProcessed | Should -Be 1
    }

    It 'GU04 - IsFatal=$false on success' {
        $r = Invoke-GroupsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'GU05 - PUT method used' {
        Invoke-GroupsUpdate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'GU06 - endpoint contains GroupID' {
        Invoke-GroupsUpdate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Endpoint -like '*42*' }
    }

    It 'GU07 - result entry GroupName from response' {
        $r = Invoke-GroupsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Results.Count           | Should -Be 1
        $r.Results[0].GroupName    | Should -Be 'UpdatedAdmins'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsUpdate - WhatIf' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { script:New-GroupApiResponse -Group $script:MockGroupResponse }
    }

    It 'GU08 - WhatIf: API NOT called' {
        Invoke-GroupsUpdate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'GU09 - WhatIf: Successes=1' {
        $r = Invoke-GroupsUpdate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsUpdate - validation' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { }
    }

    It 'GU10 - empty GroupID: Failures=1 and no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.GroupID = ''
        $r = Invoke-GroupsUpdate -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'GU11 - null InputData: Failures=1 and no API call' {
        $r = Invoke-GroupsUpdate -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsUpdate - errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GU12 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-GroupsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'GU13 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-GroupsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsUpdate - body construction' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GU14 - body contains groupId as integer' {
        $script:capturedBody = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedBody -Value $Body -Scope Script
            script:New-GroupApiResponse -Group $script:MockGroupResponse
        }
        Invoke-GroupsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $script:capturedBody                            | Should -Not -BeNullOrEmpty
        $script:capturedBody['groupId']                 | Should -Be 42
        $script:capturedBody['groupId'].GetType().Name  | Should -Be 'Int32'
    }

    It 'GU15 - body does not include keys with empty values' {
        $inputWithBlanks = @{
            GroupID     = '42'
            GroupName   = ''
            Description = ''
            Location    = ''
        }
        $script:capturedBody = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedBody -Value $Body -Scope Script
            script:New-GroupApiResponse -Group $script:MockGroupResponse
        }
        Invoke-GroupsUpdate -Token $script:MockToken -InputData $inputWithBlanks
        $script:capturedBody.ContainsKey('groupName')   | Should -BeFalse
        $script:capturedBody.ContainsKey('description') | Should -BeFalse
        $script:capturedBody.ContainsKey('location')    | Should -BeFalse
    }
}
