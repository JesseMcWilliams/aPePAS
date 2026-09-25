#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Accounts\Invoke-AccountsAdd.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-AccountsAddInput is NOT tested here because it depends on Show-FieldPrompt
    and Read-Host, which require interactive input. That function is covered by
    manual integration tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsAdd.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-AccountsAdd into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsAddTests' -MinLevel 'ERROR'

    # Minimal token stub
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'ISPSS'
        AuthMethod = 'ClientCredentials'
        BaseURL    = 'https://test.privilegecloud.cyberark.cloud'
    }

    # Standard valid input used across tests
    $script:ValidInput = @{
        Name        = ''
        Address     = 'server01.domain.com'
        UserName    = 'localadmin'
        PlatformID  = 'WinServerLocal'
        SafeName    = 'TestSafe'
        SecretType  = 'password'
        Secret      = ''
        AutoManaged = 'true'
    }

    # Sample account object matching CyberArk API response shape
    $script:SampleAccount = [PSCustomObject]@{
        id           = '12345'
        name         = 'localadmin@server01.domain.com'
        address      = 'server01.domain.com'
        userName     = 'localadmin'
        platformId   = 'WinServerLocal'
        safeName     = 'TestSafe'
        secretType   = 'password'
        secretManagement = [PSCustomObject]@{
            automaticManagementEnabled = $true
            manualManagementReason     = ''
            status                     = ''
            lastModifiedTime           = 0
            lastReconciledTime         = 0
            lastVerifiedTime           = 0
        }
        createdTime  = 1700000000
    }

    # Factory: build a mock API success response for an account Add (201 Created)
    function script:New-AccountApiResponse {
        param(
            [PSCustomObject]$Account,
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
            Data          = $Account
        }
    }

    # Factory: build a mock API failure response
    function script:New-ApiErrorResponse {
        param(
            [int]$StatusCode    = 400,
            [string]$ErrorMessage = 'Bad Request'
        )
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

    It 'AA01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'AA02 - required fields are all present' {
        $ModuleMeta.Name             | Should -Not -BeNullOrEmpty
        $ModuleMeta.Category         | Should -Not -BeNullOrEmpty
        $ModuleMeta.Action           | Should -Not -BeNullOrEmpty
        $ModuleMeta.SupportedSystems | Should -Not -BeNullOrEmpty
        $ModuleMeta.Version          | Should -Not -BeNullOrEmpty
    }

    It 'AA03 - SupportsWhatIf is $true (write operation)' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'AA04 - AcceptsInputFile is $true' {
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
    }

    It 'AA05 - Action is Add' {
        $ModuleMeta.Action | Should -Be 'Add'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsAdd - successful response' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-AccountApiResponse -Account $script:SampleAccount -StatusCode 201
        }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AA06 - returns a result object with all 9 required fields' {
        $r = Invoke-AccountsAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.PSObject.Properties.Name | Should -Contain 'ModuleName'
        $r.PSObject.Properties.Name | Should -Contain 'Category'
        $r.PSObject.Properties.Name | Should -Contain 'Action'
        $r.PSObject.Properties.Name | Should -Contain 'ItemsProcessed'
        $r.PSObject.Properties.Name | Should -Contain 'Successes'
        $r.PSObject.Properties.Name | Should -Contain 'Failures'
        $r.PSObject.Properties.Name | Should -Contain 'IsFatal'
        $r.PSObject.Properties.Name | Should -Contain 'Results'
        $r.PSObject.Properties.Name | Should -Contain 'Errors'
    }

    It 'AA07 - success: Successes=1, ItemsProcessed=1, Failures=0' {
        $r = Invoke-AccountsAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes      | Should -Be 1
        $r.ItemsProcessed | Should -Be 1
        $r.Failures       | Should -Be 0
    }

    It 'AA08 - POST method is used' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-AccountApiResponse -Account $script:SampleAccount
        }
        Invoke-AccountsAdd -Token $script:MockToken -InputData $script:ValidInput
        $script:capturedParams.Method | Should -Be 'POST'
    }

    It 'AA09 - AccountID is mapped from response id' {
        $r = Invoke-AccountsAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].AccountID | Should -Be '12345'
    }

    It 'AA10 - SafeName is mapped from response safeName' {
        $r = Invoke-AccountsAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].SafeName | Should -Be 'TestSafe'
    }

    It 'AA11 - IsFatal is $false on success' {
        $r = Invoke-AccountsAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'AA12 - account name is auto-generated as UserName@Address when Name is blank' {
        $testInput = $script:ValidInput.Clone()
        $testInput.Name = ''
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-AccountApiResponse -Account $script:SampleAccount
        }
        Invoke-AccountsAdd -Token $script:MockToken -InputData $testInput
        $script:capturedParams.Body.name | Should -Be 'localadmin@server01.domain.com'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsAdd - WhatIf' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AA13 - WhatIf: Invoke-CyberArkAPI is not called' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        { Invoke-AccountsAdd -Token $script:MockToken -InputData $script:ValidInput -WhatIf } | Should -Not -Throw
        Should -Not -Invoke Invoke-CyberArkAPI
    }

    It 'AA14 - WhatIf: Successes=1' {
        $r = Invoke-AccountsAdd -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
    }

    It 'AA15 - WhatIf: result entry contains SafeName from input' {
        $r = Invoke-AccountsAdd -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Results[0].SafeName | Should -Be 'TestSafe'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsAdd - input validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { throw 'Should not be called in validation tests' }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AA16 - empty Address: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.Address = ''
        $r = Invoke-AccountsAdd -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Not -Invoke Invoke-CyberArkAPI
    }

    It 'AA17 - empty UserName: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.UserName = ''
        $r = Invoke-AccountsAdd -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Not -Invoke Invoke-CyberArkAPI
    }

    It 'AA18 - empty PlatformID: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.PlatformID = ''
        $r = Invoke-AccountsAdd -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Not -Invoke Invoke-CyberArkAPI
    }

    It 'AA19 - empty SafeName: Failures=1, no API call' {
        $testInput = $script:ValidInput.Clone()
        $testInput.SafeName = ''
        $r = Invoke-AccountsAdd -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Not -Invoke Invoke-CyberArkAPI
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsAdd - API errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AA20 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-AccountsAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal  | Should -BeTrue
        $r.Failures | Should -Be 1
    }

    It 'AA21 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-AccountsAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal  | Should -BeTrue
        $r.Failures | Should -Be 1
    }

    It 'AA22 - 409 Conflict: IsFatal=$false, Failures=1' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 409 -ErrorMessage 'Account already exists' }
        $r = Invoke-AccountsAdd -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal  | Should -BeFalse
        $r.Failures | Should -Be 1
    }
}
