#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Platforms\Invoke-PlatformsExport.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-PlatformsExportInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Platforms\Invoke-PlatformsExport.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Invoke-FileWriteWithRetry's real implementation (Manage-Privilege.ps1) prompts
    # interactively (via Confirm-Action) on failure - this stub just runs Action once and
    # surfaces whether it threw, matching Invoke-CustomExportAll.Tests.ps1's own convention for
    # this same driver-scope dependency.
    function global:Invoke-FileWriteWithRetry {
        param([scriptblock]$Action, [string]$Path)
        try { & $Action; return $true } catch { return $false }
    }

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'PlatformsExportTests' -MinLevel 'ERROR'

    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault'
    }

    $script:TestZipBytes = [byte[]](80, 75, 3, 4, 1, 2, 3, 4)

    function script:New-FileResponse {
        param([string]$FileName = $null)
        [PSCustomObject]@{
            IsSuccess         = $true
            StatusCode        = 200
            ErrorMessage      = ''
            ErrorDetails      = $null
            DataType          = 'File'
            Data              = $script:TestZipBytes
            SuggestedFileName = $FileName
        }
    }

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
    It 'PE01 - Name = Export Platform' {
        $ModuleMeta.Name | Should -Be 'Export Platform'
    }
    It 'PE02 - SupportsWhatIf = $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }
}

Describe 'Invoke-PlatformsExport - success, PlatformID' {

    BeforeEach {
        $script:ActiveProfile = [PSCustomObject]@{ OutputFolder = $TestDrive }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PE03 - POSTs to /API/Platforms/{id}/Export with platformID query param and saves the file' {
        Mock Invoke-CyberArkAPI { script:New-FileResponse -FileName 'WinServerLocal.zip' }

        $r = Invoke-PlatformsExport -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Platforms/WinServerLocal/Export' -and $QueryParams['platformID'] -eq 'WinServerLocal'
        }
        $r.Results[0].SavedPath | Should -Be (Join-Path $TestDrive 'WinServerLocal.zip')
        [System.IO.File]::ReadAllBytes($r.Results[0].SavedPath) | Should -Be $script:TestZipBytes
    }

    It 'PE04 - falls back to a generated filename when the response has no SuggestedFileName' {
        Mock Invoke-CyberArkAPI { script:New-FileResponse }

        $r = Invoke-PlatformsExport -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Successes | Should -Be 1
        $r.Results[0].SavedPath | Should -Match 'Platform-Export-PlatformID-WinServerLocal-\d{8}-\d{6}\.zip$'
        Test-Path -LiteralPath $r.Results[0].SavedPath | Should -BeTrue
    }
}

Describe 'Invoke-PlatformsExport - success, other export types' {

    BeforeEach {
        $script:ActiveProfile = [PSCustomObject]@{ OutputFolder = $TestDrive }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PE05 - RotationalGroupID uses the lowercase /api/Platforms/RotationalGroups/{id}/Export endpoint, no query params' {
        Mock Invoke-CyberArkAPI { script:New-FileResponse -FileName 'Rot.zip' }
        Invoke-PlatformsExport -Token $script:MockToken -InputData @{ RotationalGroupID = 'RG1' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/api/Platforms/RotationalGroups/RG1/Export' -and -not $QueryParams
        }
    }

    It 'PE06 - DependentID uses the lowercase /api/Platforms/Dependents/{id}/Export endpoint' {
        Mock Invoke-CyberArkAPI { script:New-FileResponse -FileName 'Dep.zip' }
        Invoke-PlatformsExport -Token $script:MockToken -InputData @{ DependentID = '42' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/api/Platforms/Dependents/42/Export'
        }
    }

    It 'PE07 - GroupPlatformID uses the /API/Platforms/Groups/{id}/Export endpoint' {
        Mock Invoke-CyberArkAPI { script:New-FileResponse -FileName 'Grp.zip' }
        Invoke-PlatformsExport -Token $script:MockToken -InputData @{ GroupPlatformID = 'GP1' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Platforms/Groups/GP1/Export'
        }
    }
}

Describe 'Invoke-PlatformsExport - validation' {

    BeforeEach {
        $script:ActiveProfile = [PSCustomObject]@{ OutputFolder = $TestDrive }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PE08 - no ID column supplied - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PlatformsExport -Token $script:MockToken -InputData @{}
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PE09 - more than one ID column supplied - Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called' }
        $r = Invoke-PlatformsExport -Token $script:MockToken -InputData @{ PlatformID = 'A'; DependentID = '1' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'PE10 - API failure (e.g. 404 unknown platform) - non-fatal, no file written' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        $r = Invoke-PlatformsExport -Token $script:MockToken -InputData @{ PlatformID = 'NoSuchPlatform' }
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeFalse
    }

    It 'PE11 - a successful HTTP response with no file content (unexpected DataType) is a non-fatal Failure' {
        Mock Invoke-CyberArkAPI { [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; DataType = 'JSON'; Data = $null; SuggestedFileName = $null } }
        $r = Invoke-PlatformsExport -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Failures | Should -Be 1
    }

    It 'PE12 - the save failing (Invoke-FileWriteWithRetry declines) is a non-fatal Failure' {
        Mock Invoke-CyberArkAPI { script:New-FileResponse -FileName 'WinServerLocal.zip' }
        Mock Invoke-FileWriteWithRetry { return $false }
        $r = Invoke-PlatformsExport -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' }
        $r.Failures | Should -Be 1
    }
}

Describe 'Invoke-PlatformsExport - WhatIf' {

    BeforeEach {
        $script:ActiveProfile = [PSCustomObject]@{ OutputFolder = $TestDrive }
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PE13 - WhatIf does not call the API or write a file' {
        Mock Invoke-CyberArkAPI { throw 'Should not be called in WhatIf mode' }
        $r = Invoke-PlatformsExport -Token $script:MockToken -InputData @{ PlatformID = 'WinServerLocal' } -WhatIf
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}
