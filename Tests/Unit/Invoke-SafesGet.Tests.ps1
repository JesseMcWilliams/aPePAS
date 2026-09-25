#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Safes\Invoke-SafesGet.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafesGetInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesGet.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-SafesGet into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafesGetTests' -MinLevel 'ERROR'

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

    # Factory: build a mock API success response for a single safe object
    function script:New-SafeApiResponse {
        param([PSCustomObject]$Safe)
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $Safe
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

    # A sample safe object matching the CyberArk API shape (single object, not wrapped in value array)
    $script:SampleSafe = [PSCustomObject]@{
        safeName                  = 'TestSafe'
        description               = 'A test safe'
        location                  = '\'
        managingCPM               = 'PasswordManager'
        numberOfVersionsRetention = 7
        numberOfDaysRetention     = 0
        autoPurgeEnabled          = $false
        olacEnabled               = $false
        creator                   = [PSCustomObject]@{ id = 'u1'; name = 'Admin' }
        creationTime              = 1700000000   # 2023-11-14 (UTC)
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'G01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'G02 - required fields are all present' {
        $ModuleMeta.Name             | Should -Not -BeNullOrEmpty
        $ModuleMeta.Category         | Should -Not -BeNullOrEmpty
        $ModuleMeta.Action           | Should -Not -BeNullOrEmpty
        $ModuleMeta.SupportedSystems | Should -Not -BeNullOrEmpty
        $ModuleMeta.Version          | Should -Not -BeNullOrEmpty
    }

    It 'G03 - Category is Safes and Action is Get' {
        $ModuleMeta.Category | Should -Be 'Safes'
        $ModuleMeta.Action   | Should -Be 'Get'
    }

    It 'G04 - AcceptsInputFile is $true' {
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
    }

    It 'G05 - SupportsWhatIf is $false' {
        $ModuleMeta.SupportsWhatIf | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesGet - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-SafeApiResponse -Safe $script:SampleSafe
        }
        Mock Write-CyberArkLog { }
    }

    It 'G06 - returns result object with all 9 required fields' {
        $r = Invoke-SafesGet -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
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

    It 'G07 - Successes=1, ItemsProcessed=1, Failures=0' {
        $r = Invoke-SafesGet -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.Successes      | Should -Be 1
        $r.ItemsProcessed | Should -Be 1
        $r.Failures       | Should -Be 0
    }

    It 'G08 - safeName mapped correctly to SafeName' {
        $r = Invoke-SafesGet -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.Results[0].SafeName | Should -Be 'TestSafe'
    }

    It 'G09 - description mapped correctly to Description' {
        $r = Invoke-SafesGet -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.Results[0].Description | Should -Be 'A test safe'
    }

    It 'G10 - creator.name mapped to Creator' {
        $r = Invoke-SafesGet -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.Results[0].Creator | Should -Be 'Admin'
    }

    It 'G11 - creationTime epoch converted to yyyy-MM-dd string' {
        $r = Invoke-SafesGet -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.Results[0].Created | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }

    It 'G12 - null creationTime returns empty string for Created' {
        $safeNoTime = [PSCustomObject]@{
            safeName                  = 'NoTime'
            description               = ''
            location                  = '\'
            managingCPM               = ''
            numberOfVersionsRetention = 0
            numberOfDaysRetention     = 0
            autoPurgeEnabled          = $false
            olacEnabled               = $false
            creator                   = $null
            # creationTime deliberately absent
        }
        Mock Invoke-CyberArkAPI { script:New-SafeApiResponse -Safe $safeNoTime }
        $r = Invoke-SafesGet -Token $script:MockToken -InputData @{ SafeName = 'NoTime' }
        $r.Results[0].Created | Should -Be ''
    }

    It 'G13 - IsFatal=$false on success' {
        $r = Invoke-SafesGet -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.IsFatal | Should -BeFalse
    }

    It 'G14 - null creator returns empty string for Creator' {
        $safeNoCreator = [PSCustomObject]@{
            safeName                  = 'NoCreator'
            description               = ''
            location                  = '\'
            managingCPM               = ''
            numberOfVersionsRetention = 0
            numberOfDaysRetention     = 0
            autoPurgeEnabled          = $false
            olacEnabled               = $false
            creator                   = $null
            creationTime              = 1700000000
        }
        Mock Invoke-CyberArkAPI { script:New-SafeApiResponse -Safe $safeNoCreator }
        $r = Invoke-SafesGet -Token $script:MockToken -InputData @{ SafeName = 'NoCreator' }
        $r.Results[0].Creator | Should -Be ''
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesGet - validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-SafeApiResponse -Safe $script:SampleSafe }
        Mock Write-CyberArkLog { }
    }

    It 'G15 - empty SafeName: Failures=1 and no API call made' {
        $r = Invoke-SafesGet -Token $script:MockToken -InputData @{ SafeName = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'G16 - null InputData: Failures=1 and no API call made' {
        $r = Invoke-SafesGet -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesGet - errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'G17 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-SafesGet -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.IsFatal | Should -BeTrue
    }

    It 'G18 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-SafesGet -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.IsFatal | Should -BeTrue
    }

    It 'G19 - 403 Forbidden: IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-SafesGet -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.IsFatal | Should -BeFalse
    }

    It 'G20 - 404 Not Found: IsFatal=$false and error added' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        $r = Invoke-SafesGet -Token $script:MockToken -InputData @{ SafeName = 'TestSafe' }
        $r.IsFatal      | Should -BeFalse
        $r.Failures     | Should -Be 1
        $r.Errors.Count | Should -Be 1
    }
}
