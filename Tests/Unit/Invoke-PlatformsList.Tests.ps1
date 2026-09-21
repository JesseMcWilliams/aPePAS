#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Platforms\Invoke-PlatformsList.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-PlatformsListInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Platforms\Invoke-PlatformsList.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-PlatformsList into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'PlatformsListTests' -MinLevel 'ERROR'

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

    # A sample platform object matching the CyberArk v14.6 API shape
    $script:SamplePlatform = [PSCustomObject]@{
        id           = 'WinServerLocal'
        name         = 'Windows Server Local'
        description  = 'Windows local accounts'
        active       = $true
        platformType = 'Regular'
    }

    # Factory: build a mock API success response containing the given platform objects.
    # NOTE: Platforms API uses 'Platforms' property - NOT 'value'.
    function script:New-PlatformsApiResponse {
        param([object[]]$Platforms = @())
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = [PSCustomObject]@{
                Platforms = $Platforms
                Total     = $Platforms.Count
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

    It 'PL01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'PL02 - required fields are all present' {
        $ModuleMeta.Name             | Should -Not -BeNullOrEmpty
        $ModuleMeta.Category         | Should -Not -BeNullOrEmpty
        $ModuleMeta.Action           | Should -Not -BeNullOrEmpty
        $ModuleMeta.SupportedSystems | Should -Not -BeNullOrEmpty
        $ModuleMeta.Version          | Should -Not -BeNullOrEmpty
    }

    It 'PL03 - Category is Platforms and Action is List' {
        $ModuleMeta.Category | Should -Be 'Platforms'
        $ModuleMeta.Action   | Should -Be 'List'
    }

    It 'PL04 - SupportsWhatIf is $false (read-only operation)' {
        $ModuleMeta.SupportsWhatIf | Should -BeFalse
    }

    It 'PL05 - SupportedSystems contains ISPSS and SelfHosted' {
        $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-PlatformsList - successful response' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-PlatformsApiResponse -Platforms @($script:SamplePlatform)
        }
        Mock Write-CyberArkLog { }
    }

    It 'PL06 - returns a result object with all 9 required fields' {
        $r = Invoke-PlatformsList -Token $script:MockToken
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

    It 'PL07 - single platform: Successes=1, ItemsProcessed=1, Failures=0' {
        $r = Invoke-PlatformsList -Token $script:MockToken
        $r.Successes      | Should -Be 1
        $r.ItemsProcessed | Should -Be 1
        $r.Failures       | Should -Be 0
    }

    It 'PL08 - platform.id is mapped to PlatformID' {
        $r = Invoke-PlatformsList -Token $script:MockToken
        $r.Results[0].PlatformID | Should -Be 'WinServerLocal'
    }

    It 'PL09 - platform.name is mapped to Name' {
        $r = Invoke-PlatformsList -Token $script:MockToken
        $r.Results[0].Name | Should -Be 'Windows Server Local'
    }

    It 'PL10 - platform.active is mapped to Active' {
        $r = Invoke-PlatformsList -Token $script:MockToken
        $r.Results[0].Active | Should -BeTrue
    }

    It 'PL11 - platform.description is mapped to Description' {
        $r = Invoke-PlatformsList -Token $script:MockToken
        $r.Results[0].Description | Should -Be 'Windows local accounts'
    }

    It 'PL12 - platform.platformType is mapped to PlatformType' {
        $r = Invoke-PlatformsList -Token $script:MockToken
        $r.Results[0].PlatformType | Should -Be 'Regular'
    }

    It 'PL12a - alternate field-name shape (root-level PlatformID/SystemType instead of id/platformType) still maps PlatformID and PlatformType' {
        # Regression test: Invoke-PlatformsGet.ps1 already handles both id/PlatformID and
        # platformType/SystemType field-name variants (Lessons-Learned-PowerShell-Pester.md
        # Section 12 documents this as a real PVWA-version response-shape difference), but this
        # sibling module only checked id/platformType - a PVWA version/response using the
        # alternate names returned a blank PlatformID/PlatformType for every row here while
        # Get Platform for the same platform worked fine.
        $altShapePlatform = [PSCustomObject]@{
            PlatformID  = 'UnixSSH'
            Name        = 'Unix via SSH'
            Description = 'Unix accounts managed via SSH'
            Active      = $true
            SystemType  = 'Regular'
        }
        Mock Invoke-CyberArkAPI { script:New-PlatformsApiResponse -Platforms @($altShapePlatform) }
        $r = Invoke-PlatformsList -Token $script:MockToken
        $r.Results[0].PlatformID   | Should -Be 'UnixSSH'
        $r.Results[0].PlatformType | Should -Be 'Regular'
    }

    It 'PL13 - empty Platforms array: Successes=0, Failures=0, IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-PlatformsApiResponse -Platforms @() }
        $r = Invoke-PlatformsList -Token $script:MockToken
        $r.Successes | Should -Be 0
        $r.Failures  | Should -Be 0
        $r.IsFatal   | Should -BeFalse
    }

    It 'PL14 - response with no Platforms property does not throw and returns empty results' {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{
                IsSuccess     = $true
                StatusCode    = 200
                StatusMessage = 'OK'
                ErrorMessage  = $null
                ErrorDetails  = $null
                DataType      = 'JSON'
                RawResponse   = '{}'
                Data          = [PSCustomObject]@{ Total = 0 }   # no 'Platforms' property
            }
        }
        { Invoke-PlatformsList -Token $script:MockToken } | Should -Not -Throw
        $r = Invoke-PlatformsList -Token $script:MockToken
        $r.Results.Count | Should -Be 0
    }

    It 'PL14b - IsFatal is $false on success' {
        $r = Invoke-PlatformsList -Token $script:MockToken
        $r.IsFatal | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-PlatformsList - query parameters' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'PL15 - Search value is sent in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-PlatformsApiResponse
        }
        Invoke-PlatformsList -Token $script:MockToken -InputData @{ Search = 'windows'; ActiveOnly = $false }
        $script:capturedParams.QueryParams['Search'] | Should -Be 'windows'
    }

    It 'PL16 - ActiveOnly=$true sends Active=true in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-PlatformsApiResponse
        }
        Invoke-PlatformsList -Token $script:MockToken -InputData @{ Search = ''; ActiveOnly = $true }
        $script:capturedParams.QueryParams['Active'] | Should -Be 'true'
    }

    It 'PL17 - empty Search string means no Search key in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-PlatformsApiResponse
        }
        Invoke-PlatformsList -Token $script:MockToken -InputData @{ Search = ''; ActiveOnly = $false }
        $script:capturedParams.QueryParams.ContainsKey('Search') | Should -BeFalse
    }

    It 'PL17a - ActiveOnly as the CSV string "false" (bulk/CSV mode) means no Active key in QueryParams' {
        # Regression test: [bool]$InputData['ActiveOnly'] casts ANY non-empty string to $true,
        # including the literal text "false" - only a genuinely empty string casts to $false.
        # PL15-PL17 above all pass a real PowerShell $false/$true, which happens to already cast
        # correctly, masking this bug in CSV/bulk mode (Import-Csv values are always strings).
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-PlatformsApiResponse
        }
        Invoke-PlatformsList -Token $script:MockToken -InputData @{ Search = ''; ActiveOnly = 'false' }
        $script:capturedParams.QueryParams.ContainsKey('Active') | Should -BeFalse
    }

    It 'PL18 - SystemType value is sent in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-PlatformsApiResponse
        }
        Invoke-PlatformsList -Token $script:MockToken -InputData @{ SystemType = 'Windows' }
        $script:capturedParams.QueryParams['SystemType'] | Should -Be 'Windows'
    }

    It 'PL19 - empty SystemType means no SystemType key in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-PlatformsApiResponse
        }
        Invoke-PlatformsList -Token $script:MockToken -InputData @{ SystemType = '' }
        $script:capturedParams.QueryParams.ContainsKey('SystemType') | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-PlatformsList - API errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'PL18 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-PlatformsList -Token $script:MockToken
        $r.IsFatal | Should -BeTrue
    }

    It 'PL19 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-PlatformsList -Token $script:MockToken
        $r.IsFatal | Should -BeTrue
    }

    It 'PL20 - 403 Forbidden: error added, IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-PlatformsList -Token $script:MockToken
        $r.Failures        | Should -Be 1
        $r.Errors.Count    | Should -Be 1
        $r.IsFatal         | Should -BeFalse
    }
}
