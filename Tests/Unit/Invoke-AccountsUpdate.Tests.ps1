#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Accounts\Invoke-AccountsUpdate.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-AccountsUpdateInput is NOT tested here because it depends on Show-FieldPrompt,
    which is defined in Manage-Privilege.ps1. That function is covered by manual integration
    tests (Manage-Privilege.ps1 - D-series in Testing_Plan.md).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsUpdate.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Dot-source the module to load $ModuleMeta and Invoke-AccountsUpdate into this scope
    . $script:ModulePath

    # Suppress log output
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsUpdateTests' -MinLevel 'ERROR'

    # Minimal token stub (ISPSS)
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'ISPSS'
        AuthMethod = 'ClientCredentials'
        BaseURL    = 'https://test.privilegecloud.cyberark.cloud'
    }

    # Standard valid input - Address updated; other optional fields blank (left untouched by the patch)
    $script:ValidInput = @{
        AccountID  = '123_456'
        Name       = ''
        Address    = '10.0.0.99'
        UserName   = ''
        PlatformID = ''
        SafeName   = ''
        AutoManaged= ''
    }

    # Updated account state returned by the PATCH call
    $script:UpdatedAccount = [PSCustomObject]@{
        id          = '123_456'
        name        = 'acct-original'
        address     = '10.0.0.99'
        userName    = 'svcuser'
        platformId  = 'WinServerLocal'
        safeName    = 'TestSafe'
        secretType  = 'password'
        createdTime = 1700000000
        secretManagement = [PSCustomObject]@{
            automaticManagementEnabled = $true
            manualManagementReason     = ''
            status                     = 'success'
        }
    }

    # Factory: build a mock API success response for a single account object
    function script:New-AccountApiResponse {
        param(
            [Parameter(Mandatory = $true)] [PSCustomObject]$Account,
            [int]$StatusCode = 200
        )
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = $StatusCode
            StatusMessage = 'OK'
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
            [int]$StatusCode      = 403,
            [string]$ErrorMessage = 'Forbidden'
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

    It 'AU01 - $ModuleMeta is defined after dot-sourcing' {
        $ModuleMeta | Should -Not -BeNullOrEmpty
    }

    It 'AU02 - SupportsWhatIf is $true' {
        $ModuleMeta.SupportsWhatIf | Should -BeTrue
    }

    It 'AU03 - AcceptsInputFile is $true' {
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
    }

    It 'AU04 - Category is Accounts and Action is Update' {
        $ModuleMeta.Category | Should -Be 'Accounts'
        $ModuleMeta.Action   | Should -Be 'Update'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsUpdate - success' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }

        Mock Invoke-CyberArkAPI {
            script:New-AccountApiResponse -Account $script:UpdatedAccount -StatusCode 200
        }
    }

    It 'AU05 - one API call made total (PATCH only, no pre-fetch GET)' {
        Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly
    }

    It 'AU06 - the API call uses PATCH method' {
        $capturedCalls = [System.Collections.Generic.List[hashtable]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $capturedCalls.Add($PSBoundParameters)
            script:New-AccountApiResponse -Account $script:UpdatedAccount -StatusCode 200
        }
        Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $capturedCalls[0].Method | Should -Be 'PATCH'
    }

    It 'AU06a - the PATCH body is a JSON Patch array containing only the supplied field' {
        $capturedCalls = [System.Collections.Generic.List[hashtable]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $capturedCalls.Add($PSBoundParameters)
            script:New-AccountApiResponse -Account $script:UpdatedAccount -StatusCode 200
        }
        Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        [array]$body = @($capturedCalls[0].Body)
        $body.Count      | Should -Be 1
        $body[0].op      | Should -Be 'replace'
        $body[0].path    | Should -Be '/address'
        $body[0].value   | Should -Be '10.0.0.99'
    }

    It 'AU07 - Successes=1 and Failures=0' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Successes | Should -Be 1
        $r.Failures  | Should -Be 0
    }

    It 'AU08 - IsFatal is $false on success' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeFalse
    }

    It 'AU09 - result entry AccountID matches input' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].AccountID | Should -Be '123_456'
    }

    It 'AU10 - result entry Address reflects the updated value from PATCH response' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].Address | Should -Be '10.0.0.99'
    }

    It 'AU11 - result entry has all expected fields' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'AccountID'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'AccountName'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'Address'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'UserName'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'PlatformID'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'SafeName'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'SecretType'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'AutoManaged'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'CPMStatus'
        $r.Results[0].PSObject.Properties.Name | Should -Contain 'Created'
    }

    It 'AU12 - createdTime epoch is converted to a yyyy-MM-dd string' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Results[0].Created | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }

    It 'AU13 - blank optional fields are omitted from the patch entirely, not sent as empty values' {
        $capturedCalls = [System.Collections.Generic.List[hashtable]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $capturedCalls.Add($PSBoundParameters)
            script:New-AccountApiResponse -Account $script:UpdatedAccount -StatusCode 200
        }
        Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        # Only Address was non-blank in $script:ValidInput - Name/UserName/PlatformID/SafeName/
        # AutoManaged were blank and must not appear as ops in the patch body.
        [array]$body = @($capturedCalls[0].Body)
        $body.path | Should -Not -Contain '/name'
        $body.path | Should -Not -Contain '/userName'
        $body.path | Should -Not -Contain '/platformId'
        $body.path | Should -Not -Contain '/safeName'
        $body.path | Should -Not -Contain '/secretManagement/automaticManagementEnabled'
    }

    It 'AU13a - multiple non-blank fields each produce their own patch op' {
        $capturedCalls = [System.Collections.Generic.List[hashtable]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $capturedCalls.Add($PSBoundParameters)
            script:New-AccountApiResponse -Account $script:UpdatedAccount -StatusCode 200
        }
        $testInput = $script:ValidInput.Clone()
        $testInput.UserName    = 'newuser'
        $testInput.AutoManaged = 'true'
        Invoke-AccountsUpdate -Token $script:MockToken -InputData $testInput
        [array]$body = @($capturedCalls[0].Body)
        $body.Count  | Should -Be 3
        $body.path   | Should -Contain '/address'
        $body.path   | Should -Contain '/userName'
        $body.path   | Should -Contain '/secretManagement/automaticManagementEnabled'
        ($body | Where-Object { $_.path -eq '/secretManagement/automaticManagementEnabled' }).value | Should -Be 'true'
    }

    It 'AU21 - a minimal PATCH response missing optional AccountModel fields does not throw under strict mode' {
        # Real CyberArk responses always include these fields, but nothing in the AccountModel
        # schema guarantees it - the result-mapping block must not assume their presence.
        Mock Invoke-CyberArkAPI {
            script:New-AccountApiResponse -Account ([PSCustomObject]@{ id = '123_456'; name = 'X' }) -StatusCode 200
        }
        { Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput } | Should -Not -Throw
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.Failures            | Should -Be 0
        $r.Results[0].AccountID | Should -Be '123_456'
        $r.Results[0].Address   | Should -Be ''
        $r.Results[0].Created   | Should -Be ''
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsUpdate - WhatIf' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }

        # WhatIf PATCH returns success without actually calling out (Invoke-CyberArkAPI's own
        # WhatIf handling); the mock mirrors that synthetic success shape.
        Mock Invoke-CyberArkAPI {
            script:New-AccountApiResponse -Account $script:UpdatedAccount -StatusCode 200
        }
    }

    It 'AU14 - WhatIf: Successes=1 and IsFatal=$false' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Successes | Should -Be 1
        $r.IsFatal   | Should -BeFalse
    }

    It 'AU15 - WhatIf: result entry exists in Results' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Results.Count | Should -Be 1
    }

    It 'AU15a - WhatIf: result entry reflects only the supplied field, blank for the rest' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput -WhatIf
        $r.Results[0].Address     | Should -Be '10.0.0.99'
        $r.Results[0].AccountName | Should -Be ''
        $r.Results[0].UserName    | Should -Be ''
        $r.Results[0].SecretType  | Should -Be ''
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsUpdate - validation' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { }
    }

    It 'AU16 - empty AccountID: Failures=1 and no API call made' {
        $testInput = $script:ValidInput.Clone()
        $testInput.AccountID = ''
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'AU17 - null InputData: Failures=1' {
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
    }

    It 'AU18 - no optional fields supplied: Failures=1 and no API call made' {
        $testInput = @{
            AccountID  = '123_456'
            Name       = ''
            Address    = ''
            UserName   = ''
            PlatformID = ''
            SafeName   = ''
            AutoManaged= ''
        }
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $testInput
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-AccountsUpdate - PATCH phase errors' {

    BeforeEach {
        Set-StrictMode -Version Latest
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'AU19 - PATCH 400 Bad Request: IsFatal=$false and Failures=1' {
        Mock Invoke-CyberArkAPI {
            script:New-ApiErrorResponse -StatusCode 400 -ErrorMessage 'Bad Request'
        }
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal  | Should -BeFalse
        $r.Failures | Should -Be 1
    }

    It 'AU20 - PATCH 401 Unauthorized: IsFatal=$true' {
        Mock Invoke-CyberArkAPI {
            script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized'
        }
        $r = Invoke-AccountsUpdate -Token $script:MockToken -InputData $script:ValidInput
        $r.IsFatal | Should -BeTrue
    }
}
