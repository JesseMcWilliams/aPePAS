#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for APIModules\Safes\Invoke-SafesList.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-SafesListInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing-Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Safes\Invoke-SafesList.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-SafesList into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'SafesListTests' -MinLevel 'ERROR'

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

    # Factory: build a mock API success response containing the given safe objects
    function script:New-SafesApiResponse {
        param([object[]]$Safes = @())
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = [PSCustomObject]@{
                value = $Safes
                count = $Safes.Count
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

    # A sample safe object matching the CyberArk API shape
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

    It 'S01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'S02 - required fields are all present' {
        $ModuleMeta.Name             | Should -Not -BeNullOrEmpty
        $ModuleMeta.Category         | Should -Not -BeNullOrEmpty
        $ModuleMeta.Action           | Should -Not -BeNullOrEmpty
        $ModuleMeta.SupportedSystems | Should -Not -BeNullOrEmpty
        $ModuleMeta.Version          | Should -Not -BeNullOrEmpty
    }

    It 'S03 - SupportedSystems contains ISPSS and SelfHosted' {
        $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
    }

    It 'S04 - SupportsWhatIf is $false (list operation)' {
        $ModuleMeta.SupportsWhatIf | Should -BeFalse
    }

    It 'S05 - HasCustomInput is $true' {
        $ModuleMeta.HasCustomInput | Should -BeTrue
    }

    It 'S06 - AcceptsInputFile is $false' {
        $ModuleMeta.AcceptsInputFile | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesList - successful response' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            script:New-SafesApiResponse -Safes @($script:SampleSafe)
        }
        Mock Write-CyberArkLog { }
    }

    It 'S07 - returns a result object with all 9 required fields' {
        $r = Invoke-SafesList -Token $script:MockToken
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

    It 'S08 - single safe: Successes=1, ItemsProcessed=1, Failures=0' {
        $r = Invoke-SafesList -Token $script:MockToken
        $r.Successes      | Should -Be 1
        $r.ItemsProcessed | Should -Be 1
        $r.Failures       | Should -Be 0
    }

    It 'S09 - multiple safes: count matches value array' {
        $safe2 = $script:SampleSafe.PSObject.Copy()
        $safe2.safeName = 'Safe2'
        Mock Invoke-CyberArkAPI {
            script:New-SafesApiResponse -Safes @($script:SampleSafe, $safe2)
        }
        $r = Invoke-SafesList -Token $script:MockToken
        $r.Successes | Should -Be 2
    }

    It 'S10 - safeName is mapped to SafeName' {
        $r = Invoke-SafesList -Token $script:MockToken
        $r.Results[0].SafeName | Should -Be 'TestSafe'
    }

    It 'S11 - description is mapped to Description' {
        $r = Invoke-SafesList -Token $script:MockToken
        $r.Results[0].Description | Should -Be 'A test safe'
    }

    It 'S12 - managingCPM is mapped to ManagingCPM' {
        $r = Invoke-SafesList -Token $script:MockToken
        $r.Results[0].ManagingCPM | Should -Be 'PasswordManager'
    }

    It 'S13 - creator.name is mapped to Creator' {
        $r = Invoke-SafesList -Token $script:MockToken
        $r.Results[0].Creator | Should -Be 'Admin'
    }

    It 'S14 - creationTime epoch is converted to a yyyy-MM-dd string' {
        $r = Invoke-SafesList -Token $script:MockToken
        $r.Results[0].Created | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }

    It 'S15 - missing creationTime does not throw and returns empty string' {
        $safeNoTime = [PSCustomObject]@{
            safeName = 'NoTime'; description = ''; location = '\'
            managingCPM = ''; numberOfVersionsRetention = 0; numberOfDaysRetention = 0
            autoPurgeEnabled = $false; olacEnabled = $false; creator = $null
            # creationTime deliberately absent
        }
        Mock Invoke-CyberArkAPI { script:New-SafesApiResponse -Safes @($safeNoTime) }
        $r = Invoke-SafesList -Token $script:MockToken
        $r.Results[0].Created | Should -Be ''
    }

    It 'S16 - IsFatal is $false on success' {
        $r = Invoke-SafesList -Token $script:MockToken
        $r.IsFatal | Should -BeFalse
    }

    It 'S17 - Search value is passed in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-SafesApiResponse
        }
        Invoke-SafesList -Token $script:MockToken -InputData @{ Search = 'myvault'; Filter = ''; ExtendedDetails = $false }
        $script:capturedParams.QueryParams['search'] | Should -Be 'myvault'
    }

    It 'S18 - Filter value is passed in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-SafesApiResponse
        }
        Invoke-SafesList -Token $script:MockToken -InputData @{ Search = ''; Filter = 'safeName eq X'; ExtendedDetails = $false }
        $script:capturedParams.QueryParams['filter'] | Should -Be 'safeName eq X'
    }

    It 'S19 - ExtendedDetails=$true sends extendedDetails=true' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-SafesApiResponse
        }
        Invoke-SafesList -Token $script:MockToken -InputData @{ Search = ''; Filter = ''; ExtendedDetails = $true }
        $script:capturedParams.QueryParams['extendedDetails'] | Should -Be 'true'
    }

    It 'S20 - empty Search string means no search key in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-SafesApiResponse
        }
        Invoke-SafesList -Token $script:MockToken -InputData @{ Search = ''; Filter = ''; ExtendedDetails = $false }
        $script:capturedParams.QueryParams.ContainsKey('search') | Should -BeFalse
    }

    It 'S21 - empty Filter string means no filter key in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-SafesApiResponse
        }
        Invoke-SafesList -Token $script:MockToken -InputData @{ Search = ''; Filter = ''; ExtendedDetails = $false }
        $script:capturedParams.QueryParams.ContainsKey('filter') | Should -BeFalse
    }

    It 'S22 - ExtendedDetails=$false means no extendedDetails key in QueryParams' {
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-SafesApiResponse
        }
        Invoke-SafesList -Token $script:MockToken -InputData @{ Search = ''; Filter = ''; ExtendedDetails = $false }
        $script:capturedParams.QueryParams.ContainsKey('extendedDetails') | Should -BeFalse
    }

    It 'S22a - ExtendedDetails as the CSV string "false" (bulk/CSV mode) means no extendedDetails key in QueryParams' {
        # Regression test: [bool]$InputData['ExtendedDetails'] casts ANY non-empty string to
        # $true, including the literal text "false" - only a genuinely empty string casts to
        # $false. Every other test in this file passes a real PowerShell $false, which happens
        # to already cast correctly, masking this bug in CSV/bulk mode (Import-Csv values are
        # always strings).
        $capturedParams = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedParams -Value $PSBoundParameters -Scope Script
            script:New-SafesApiResponse
        }
        Invoke-SafesList -Token $script:MockToken -InputData @{ Search = ''; Filter = ''; ExtendedDetails = 'false' }
        $script:capturedParams.QueryParams.ContainsKey('extendedDetails') | Should -BeFalse
    }

    It 'S23 - null InputData does not throw' {
        { Invoke-SafesList -Token $script:MockToken -InputData $null } | Should -Not -Throw
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesList - empty result' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-SafesApiResponse -Safes @() }
        Mock Write-CyberArkLog { }
    }

    It 'S24 - empty value array: Successes=0, Failures=0, IsFatal=$false' {
        $r = Invoke-SafesList -Token $script:MockToken
        $r.Successes | Should -Be 0
        $r.Failures  | Should -Be 0
        $r.IsFatal   | Should -BeFalse
    }

    It 'S25 - response with no value property does not throw' {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{
                IsSuccess = $true; StatusCode = 200; StatusMessage = 'OK'
                ErrorMessage = $null; ErrorDetails = $null; DataType = 'JSON'
                RawResponse = '{}'; Data = [PSCustomObject]@{ count = 0 }   # no 'value' property
            }
        }
        { Invoke-SafesList -Token $script:MockToken } | Should -Not -Throw
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-SafesList - API errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'S26 - 403 Forbidden: error added, IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-SafesList -Token $script:MockToken
        $r.Failures        | Should -Be 1
        $r.Errors.Count    | Should -Be 1
        $r.IsFatal         | Should -BeFalse
    }

    It 'S27 - 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-SafesList -Token $script:MockToken
        $r.IsFatal | Should -BeTrue
    }

    It 'S28 - status 0 (network error): IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 0 -ErrorMessage 'Network failure' }
        $r = Invoke-SafesList -Token $script:MockToken
        $r.IsFatal | Should -BeTrue
    }

    It 'S29 - 404 Not Found: IsFatal=$false' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        $r = Invoke-SafesList -Token $script:MockToken
        $r.IsFatal | Should -BeFalse
    }

    It 'S30 - error entry ErrorMessage is not null or empty' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-SafesList -Token $script:MockToken
        $r.Errors[0].ErrorMessage | Should -Not -BeNullOrEmpty
    }

    It 'S31 - ItemsProcessed incremented on failure' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 500 -ErrorMessage 'Server Error' }
        $r = Invoke-SafesList -Token $script:MockToken
        $r.ItemsProcessed | Should -Be 1
    }
}
