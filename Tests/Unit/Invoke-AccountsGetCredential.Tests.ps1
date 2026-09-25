#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Accounts\Invoke-AccountsGetCredential.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-AccountsGetCredentialInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).

    Test IDs: AC01-AC24
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsGetCredential.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-AccountsGetCredential into this scope
    . $script:ModulePath

    # Suppress log output during tests
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsGetCredentialTests' -MinLevel 'ERROR'

    # Minimal token stub (SelfHosted)
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://cyberark.example.local'
    }

    $script:ValidInput = @{ AccountID = '12345'; Reason = 'Testing' }

    # Factory: build a mock API success response for a raw credential string
    function script:New-CredentialApiResponse {
        param([string]$CredValue = 'TestPassword123')
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'Text'
            RawResponse   = $CredValue
            Data          = $CredValue
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

    # Factory: build a mock GET /API/Accounts lookup response (used to resolve AccountName+Safe
    # to an AccountID, same as Invoke-AccountsGet.ps1 / Invoke-AccountsUnlock.ps1).
    function script:New-AccountLookupResponse {
        param([object[]]$Accounts = @())
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = [PSCustomObject]@{ value = $Accounts }
        }
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'AC01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'AC02 - Action is GetCredential' {
        $ModuleMeta.Action | Should -Be 'GetCredential'
    }

    It 'AC03 - SupportsWhatIf is $false' {
        $ModuleMeta.SupportsWhatIf | Should -BeFalse
    }

    It 'AC04 - AcceptsInputFile is $false' {
        $ModuleMeta.AcceptsInputFile | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsGetCredential - successful response' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-CredentialApiResponse -CredValue 'TestPassword123'
        }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AC05 - Successes=1, Failures=0' {
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes | Should -Be 1
        $r.Failures  | Should -Be 0
    }

    It 'AC06 - Result has Credential field' {
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'Credential'
    }

    It 'AC07 - Retrieved=$true in result' {
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].Retrieved | Should -BeTrue
    }

    It 'AC08 - Credential matches mock value' {
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].Credential | Should -Be 'TestPassword123'
    }

    It 'AC09 - IsFatal=$false on success' {
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'AC10 - POST method is used' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-CredentialApiResponse
        }
        Invoke-AccountsGetCredential -Token $script:MockToken -InputData $script:ValidInput
        $script:capturedParams.Method | Should -Be 'POST'
    }

    It 'AC11 - endpoint contains AccountID and Password/Retrieve' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-CredentialApiResponse
        }
        Invoke-AccountsGetCredential -Token $script:MockToken -InputData $script:ValidInput
        $script:capturedParams.Endpoint | Should -Match '12345'
        $script:capturedParams.Endpoint | Should -Match 'Password/Retrieve'
    }

    It 'AC12 - Reason is sent in body' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-CredentialApiResponse
        }
        Invoke-AccountsGetCredential -Token $script:MockToken -InputData @{ AccountID = '12345'; Reason = 'My reason' }
        $script:capturedParams.Body.reason | Should -Be 'My reason'
    }

    It 'AC13 - empty Reason: body reason is empty string (not null)' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-CredentialApiResponse
        }
        Invoke-AccountsGetCredential -Token $script:MockToken -InputData @{ AccountID = '12345'; Reason = '' }
        $script:capturedParams.Body.reason | Should -Be ''
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsGetCredential - validation' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AC14 - empty AccountID: Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData @{ AccountID = ''; Reason = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'AC15 - null InputData: Failures=1' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsGetCredential - API errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AC16 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'AC17 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }

    It 'AC18 - 403 Forbidden: IsFatal=$false, error added' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal      | Should -BeFalse
        $r.Failures     | Should -Be 1
        $r.Errors.Count | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsGetCredential - resolve by AccountName/Safe' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AC19 - AccountID blank, AccountName+Safe resolve: lookup GET then POST retrieve' {
        $script:CallCount = 0
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                script:New-AccountLookupResponse -Accounts @(
                    [PSCustomObject]@{ id = '999'; name = 'svc-account'; userName = 'svc-account'; safeName = 'TestSafe' }
                )
            } else {
                script:New-CredentialApiResponse -CredValue 'ResolvedPassword'
            }
        }
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData @{ AccountName = 'svc-account'; Safe = 'TestSafe' }
        Should -Invoke Invoke-CyberArkAPI -Times 2 -Exactly
        $r.Successes              | Should -Be 1
        $r.Results[0].AccountID   | Should -Be '999'
        $r.Results[0].Credential  | Should -Be 'ResolvedPassword'
    }

    It 'AC20 - AccountID, AccountName, and Safe all blank: Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData @{}
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'AC21 - AccountName given but Safe blank: Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData @{ AccountName = 'svc-account' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'AC22 - lookup GET fails (401): IsFatal=$true, no retrieve attempted' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData @{ AccountName = 'svc-account'; Safe = 'TestSafe' }
        $r.IsFatal | Should -BeTrue
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly
    }

    It 'AC23 - no account matches AccountName in Safe: Failures=1' {
        Mock Invoke-CyberArkAPI { script:New-AccountLookupResponse -Accounts @() }
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData @{ AccountName = 'nonexistent'; Safe = 'TestSafe' }
        $r.Failures | Should -Be 1
    }

    It 'AC24 - multiple matches: uses the first match and still succeeds' {
        Mock Invoke-CyberArkAPI {
            $script:CallCount++
            if ($script:CallCount -eq 1) {
                script:New-AccountLookupResponse -Accounts @(
                    [PSCustomObject]@{ id = '111'; name = 'dup-account'; safeName = 'TestSafe' },
                    [PSCustomObject]@{ id = '222'; name = 'dup-account'; safeName = 'TestSafe' }
                )
            } else {
                script:New-CredentialApiResponse -CredValue 'FirstMatchPassword'
            }
        }
        $script:CallCount = 0
        $r = Invoke-AccountsGetCredential -Token $script:MockToken -InputData @{ AccountName = 'dup-account'; Safe = 'TestSafe' }
        $r.Successes            | Should -Be 1
        $r.Results[0].AccountID | Should -Be '111'
    }
}
