#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Platforms\Invoke-PlatformsImport.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-PlatformsImportInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Platforms\Invoke-PlatformsImport.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'PlatformsImportTests' -MinLevel 'ERROR'

    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault'
    }

    # A real temp .zip file - the module validates Test-Path before reading bytes.
    $script:TestZipPath = Join-Path $TestDrive 'TestPlatform.zip'
    [System.IO.File]::WriteAllBytes($script:TestZipPath, [byte[]](80, 75, 3, 4, 1, 2, 3, 4))

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

Describe 'ModuleMeta' {
    It 'PI01 - Name = Import Platform' {
        $ModuleMeta.Name | Should -Be 'Import Platform'
    }
    It 'PI02 - SupportsWhatIf = $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }
}

Describe 'Invoke-PlatformsImport - success' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PI03 - POSTs to /API/Platforms/Import with ImportFile as a byte array' {
        $capturedBody = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedBody -Value $Body -Scope Script
            [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ PlatformID = 'NewPlatform' } }
        }
        $r = Invoke-PlatformsImport -Token $script:MockToken -InputData @{ ZipFilePath = $script:TestZipPath }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'POST' -and $Endpoint -eq '/API/Platforms/Import' }
        ,$script:capturedBody['ImportFile'] | Should -BeOfType 'System.Byte[]'
        $r.Results[0].PlatformID | Should -Be 'NewPlatform'
    }

    It 'PI04 - a Warning in the response is surfaced on the result row' {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ PlatformID = 'NewPlatform'; Warning = 'Some fields were defaulted.' } }
        }
        $r = Invoke-PlatformsImport -Token $script:MockToken -InputData @{ ZipFilePath = $script:TestZipPath }
        $r.Results[0].Warning | Should -Be 'Some fields were defaulted.'
    }
}

Describe 'Invoke-PlatformsImport - validation' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PI05 - empty ZipFilePath - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PlatformsImport -Token $script:MockToken -InputData @{ ZipFilePath = '' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PI06 - path not ending in .zip - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PlatformsImport -Token $script:MockToken -InputData @{ ZipFilePath = (Join-Path $TestDrive 'notazip.txt') }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PI07 - .zip path that does not exist - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PlatformsImport -Token $script:MockToken -InputData @{ ZipFilePath = (Join-Path $TestDrive 'DoesNotExist.zip') }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PI08 - API failure (409 conflict, e.g. platform ID already exists) - non-fatal' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 409 -ErrorMessage 'Conflict' }
        $r = Invoke-PlatformsImport -Token $script:MockToken -InputData @{ ZipFilePath = $script:TestZipPath }
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
    }
}

Describe 'Invoke-PlatformsImport - WhatIf' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PI09 - WhatIf does not read the file or call the API' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called in WhatIf mode' }
        $r = Invoke-PlatformsImport -Token $script:MockToken -InputData @{ ZipFilePath = $script:TestZipPath } -WhatIf
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}
