#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Platforms\Invoke-PlatformsGet.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-PlatformsGetInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Platforms\Invoke-PlatformsGet.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-PlatformsGet into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'PlatformsGetTests' -MinLevel 'ERROR'

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

    # Factory: build a mock API success response for a single platform object
    function script:New-PlatformApiResponse {
        param([PSCustomObject]$Platform)
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $Platform
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

    # A sample platform object matching the CyberArk v14.6 API shape (single object)
    $script:SamplePlatform = [PSCustomObject]@{
        id           = 'WinServerLocal'
        name         = 'Windows Server Local'
        description  = 'Manages local accounts on Windows servers.'
        active       = $true
        platformType = 'Regular'
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'ModuleMeta' {

    It 'PG01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'PG02 - required fields are all present' {
        $ModuleMeta.Name             | Should -Not -BeNullOrEmpty
        $ModuleMeta.Category         | Should -Not -BeNullOrEmpty
        $ModuleMeta.Action           | Should -Not -BeNullOrEmpty
        $ModuleMeta.SupportedSystems | Should -Not -BeNullOrEmpty
        $ModuleMeta.Version          | Should -Not -BeNullOrEmpty
    }

    It 'PG03 - Category is Platforms and Action is Get' {
        $ModuleMeta.Category | Should -Be 'Platforms'
        $ModuleMeta.Action   | Should -Be 'Get'
    }

    It 'PG04 - AcceptsInputFile is $true' {
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
    }

    It 'PG05 - SupportsWhatIf is $false' {
        $ModuleMeta.SupportsWhatIf | Should -BeFalse
    }

    It 'PG06 - SupportedSystems contains ISPSS and SelfHosted' {
        $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-PlatformsGet - success' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-PlatformApiResponse -Platform $script:SamplePlatform
        }
        Mock Write-CyberArkLog { }
    }

    It 'PG07 - returns result object with all 9 required fields' {
        $r = Invoke-PlatformsGet -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
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

    It 'PG08 - Successes=1, ItemsProcessed=1, Failures=0' {
        $r = Invoke-PlatformsGet -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Successes      | Should -Be 1
        $r.ItemsProcessed | Should -Be 1
        $r.Failures       | Should -Be 0
    }

    It 'PG09 - id is mapped to PlatformID' {
        $r = Invoke-PlatformsGet -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Results[0].PlatformID | Should -Be 'WinServerLocal'
    }

    It 'PG10 - name is mapped to Name' {
        $r = Invoke-PlatformsGet -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Results[0].Name | Should -Be 'Windows Server Local'
    }

    It 'PG11 - description is mapped to Description' {
        $r = Invoke-PlatformsGet -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Results[0].Description | Should -Be 'Manages local accounts on Windows servers.'
    }

    It 'PG12 - active is mapped to Active' {
        $r = Invoke-PlatformsGet -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Results[0].Active | Should -BeTrue
    }

    It 'PG13 - platformType is mapped to PlatformType' {
        $r = Invoke-PlatformsGet -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Results[0].PlatformType | Should -Be 'Regular'
    }

    It 'PG14 - IsFatal=$false on success' {
        $r = Invoke-PlatformsGet -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.IsFatal | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-PlatformsGet - validation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-PlatformApiResponse -Platform $script:SamplePlatform
        }
        Mock Write-CyberArkLog { }
    }

    It 'PG15 - empty PlatformID: Failures=1 and no API call made' {
        $r = Invoke-PlatformsGet -Token $script:MockToken -InputData @{ PlatformID = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'PG16 - null InputData: Failures=1 and no API call made' {
        $r = Invoke-PlatformsGet -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-PlatformsGet - errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'PG17 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-PlatformsGet -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.IsFatal | Should -BeTrue
    }

    It 'PG18 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-PlatformsGet -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.IsFatal | Should -BeTrue
    }

    It 'PG17b - 403 Forbidden: IsFatal=$false and error added' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-PlatformsGet -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.IsFatal      | Should -BeFalse
        $r.Failures     | Should -Be 1
        $r.Errors.Count | Should -Be 1
    }

    It 'PG18b - 404 Not Found: IsFatal=$false and error added' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        $r = Invoke-PlatformsGet -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.IsFatal      | Should -BeFalse
        $r.Failures     | Should -Be 1
        $r.Errors.Count | Should -Be 1
    }
}
