#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Groups\Invoke-GroupsDelete.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-GroupsDeleteInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Groups\Invoke-GroupsDelete.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-GroupsDelete into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'GroupsDeleteTests' -MinLevel 'ERROR'

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

    $script:ValidInput = @{ GroupID = '42' }

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

    It 'GD01 - ModuleMeta.Name = ''Delete Group''' {
        $ModuleMeta.Name | Should -Be 'Delete Group'
    }

    It 'GD02 - ModuleMeta.SupportsWhatIf = $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'GD14 - SupportsWhatIf = $true (meta check)' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsDelete - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GD03 - Successes=1, Failures=0, ItemsProcessed=1 on success' {
        $r = Invoke-GroupsDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes      | Should -Be 1
        $r.Failures       | Should -Be 0
        $r.ItemsProcessed | Should -Be 1
    }

    It 'GD04 - IsFatal=$false on success' {
        $r = Invoke-GroupsDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'GD05 - DELETE method used' {
        Invoke-GroupsDelete -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'GD06 - endpoint contains GroupID' {
        Invoke-GroupsDelete -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Endpoint -like '*42*' }
    }

    It 'GD07 - result entry has Deleted=$true and GroupID set' {
        $r = Invoke-GroupsDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Results.Count      | Should -Be 1
        $r.Results[0].Deleted | Should -BeTrue
        $r.Results[0].GroupID | Should -Be '42'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsDelete - WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GD08 - WhatIf: API NOT called' {
        Invoke-GroupsDelete -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'GD09 - WhatIf: Successes=1' {
        $r = Invoke-GroupsDelete -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsDelete - validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GD10 - empty GroupID: Failures=1 and no API call' {
        $r = Invoke-GroupsDelete -Token $script:MockToken -InputData @{ GroupID = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'GD11 - null InputData: Failures=1 and no API call' {
        $r = Invoke-GroupsDelete -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-GroupsDelete - errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'GD12 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-GroupsDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'GD13 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-GroupsDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}
