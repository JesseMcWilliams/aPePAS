#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Accounts\Invoke-AccountsDelete.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-AccountsDeleteInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsDelete.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-AccountsDelete into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsDeleteTests' -MinLevel 'ERROR'

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

    $script:ValidInput = @{ AccountID = '12_3' }

    # Factory: build a mock API success response for a delete (204 No Content)
    function script:New-DeleteApiResponse {
        param([bool]$IsSuccess = $true, [int]$StatusCode = 204)
        return [PSCustomObject]@{
            IsSuccess     = $IsSuccess
            StatusCode    = $StatusCode
            StatusMessage = if ($StatusCode -eq 204) { 'No Content' } else { 'OK' }
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

    It 'AD01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'AD02 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'AD03 - AcceptsInputFile is $true' {
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
    }

    It 'AD04 - ProducesOutput is $false' {
        $ModuleMeta.ProducesOutput | Should -BeFalse
    }

    It 'AD05 - Category=Accounts and Action=Delete' {
        $ModuleMeta.Category | Should -Be 'Accounts'
        $ModuleMeta.Action   | Should -Be 'Delete'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsDelete - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AD06 - Successes=1, Failures=0, ItemsProcessed=1' {
        $r = Invoke-AccountsDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes      | Should -Be 1
        $r.Failures       | Should -Be 0
        $r.ItemsProcessed | Should -Be 1
    }

    It 'AD07 - IsFatal=$false on success' {
        $r = Invoke-AccountsDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'AD08 - DELETE method is used' {
        Invoke-AccountsDelete -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'AD09 - endpoint contains AccountID' {
        Invoke-AccountsDelete -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Endpoint -like '*12_3*' }
    }

    It 'AD10 - result entry has Deleted=$true and AccountID set' {
        $r = Invoke-AccountsDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Results.Count          | Should -Be 1
        $r.Results[0].Deleted     | Should -BeTrue
        $r.Results[0].AccountID   | Should -Be '12_3'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsDelete - WhatIf' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AD11 - WhatIf: API is NOT called' {
        Invoke-AccountsDelete -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'AD12 - WhatIf: Successes=1' {
        $r = Invoke-AccountsDelete -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsDelete - validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AD13 - empty AccountID: Failures=1 and API not called' {
        $r = Invoke-AccountsDelete -Token $script:MockToken -InputData @{ AccountID = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'AD14 - null InputData: Failures=1' {
        $r = Invoke-AccountsDelete -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsDelete - errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AD15 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-AccountsDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'AD16 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-AccountsDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsDelete - K21 classic v1 fallback' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        $script:Pasws056E = [PSCustomObject]@{
            IsSuccess     = $false
            StatusCode    = 400
            StatusMessage = 'HTTP 400'
            ErrorMessage  = 'PASWS056E: The account is not valid for delete'
            ErrorDetails  = [PSCustomObject]@{ ErrorCode = 'PASWS056E'; ErrorMessage = 'The account is not valid for delete'; Details = $null }
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $null
        }
    }

    It 'AD17 - PASWS056E on v2: retries v1 route and succeeds with DeleteRoute=v1' {
        Mock Invoke-CyberArkAPI { $script:Pasws056E } -ParameterFilter { $Endpoint -like '/API/Accounts/*' }
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse -StatusCode 200 } -ParameterFilter { $Endpoint -eq '/WebServices/PIMServices.svc/Accounts/12_3' }
        $r = Invoke-AccountsDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes              | Should -Be 1
        $r.Failures               | Should -Be 0
        $r.Results[0].DeleteRoute | Should -Be 'v1'
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'DELETE' -and $Endpoint -eq '/WebServices/PIMServices.svc/Accounts/12_3' }
    }

    It 'AD18 - PASWS056E on v2 and v1 also fails: Failures=1, message names both routes' {
        Mock Invoke-CyberArkAPI { $script:Pasws056E } -ParameterFilter { $Endpoint -like '/API/Accounts/*' }
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' } -ParameterFilter { $Endpoint -like '/WebServices/*' }
        $r = Invoke-AccountsDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Failures                | Should -Be 1
        $r.IsFatal                 | Should -BeFalse
        $r.Errors[0].ErrorMessage  | Should -BeLike '*PASWS056E*v1 fallback*Forbidden*'
    }

    It 'AD19 - other 400 error code: no v1 retry' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 400 -ErrorMessage 'Bad request' }
        $r = Invoke-AccountsDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Endpoint -like '/WebServices/*' }
    }

    It 'AD20 - plain v2 success reports DeleteRoute=v2 and makes one call' {
        Mock Invoke-CyberArkAPI { script:New-DeleteApiResponse }
        $r = Invoke-AccountsDelete -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].DeleteRoute | Should -Be 'v2'
        Should -Invoke Invoke-CyberArkAPI -Times 1
    }
}
