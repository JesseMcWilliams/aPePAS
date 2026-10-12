#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Users\Invoke-UsersRemoveAuthMethod.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-UsersRemoveAuthMethodInput is NOT tested here because it depends on Show-FieldPrompt and
    Invoke-EntitySearch, which are defined in Manage-Privilege.ps1.
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Users\Invoke-UsersRemoveAuthMethod.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'UsersRemoveAuthMethodTests' -MinLevel 'ERROR'

    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://test.cyberark.local'
    }

    function New-OkResponse {
        param($Data = $null, [int]$StatusCode = 200)
        [PSCustomObject]@{
            IsSuccess = $true; StatusCode = $StatusCode; StatusMessage = 'OK'; ErrorMessage = $null
            ErrorDetails = $null; DataType = 'JSON'; RawResponse = ''; Data = $Data
        }
    }

    function New-ErrResponse {
        param([int]$StatusCode = 403, [string]$ErrorMessage = 'Forbidden')
        [PSCustomObject]@{
            IsSuccess = $false; StatusCode = $StatusCode; StatusMessage = "HTTP $StatusCode"
            ErrorMessage = "ERR$($StatusCode): $ErrorMessage"
            ErrorDetails = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $ErrorMessage; Details = $null }
            DataType = 'JSON'; RawResponse = ''; Data = $null
        }
    }

    function New-UserSearchResponse {
        param([object[]]$Users)
        New-OkResponse -Data ([PSCustomObject]@{ Users = $Users; Total = @($Users).Count })
    }
}


AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

Describe 'ModuleMeta' {
    It 'URA01 - metadata is correct' {
        $ModuleMeta.Name             | Should -Be 'Remove User Allowed Auth Method'
        $ModuleMeta.Action           | Should -Be 'RemoveAuthMethod'
        $ModuleMeta.SupportsWhatIf   | Should -BeTrue
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.SupportedSystems | Should -Be @('SelfHosted')
        @($ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'AuthMethods' })[0].Required | Should -BeTrue
    }
}

Describe 'Invoke-UsersRemoveAuthMethod - success' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        $script:SentJson = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            if ($Body) { Set-Variable -Name SentJson -Value (ConvertTo-Json -InputObject $Body -Depth 10 -Compress) -Scope Script }
            New-OkResponse
        }
    }

    It 'URA02 - PATCH the Bulk endpoint with one BulkItem for the user' {
        $r = Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ UserID = '42'; AuthMethods = 'SAML; PKI' }
        $r.Successes | Should -Be 1
        $r.Results[0].AuthMethods | Should -Be 'SAML;PKI'
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Endpoint -eq '/API/Users/RemoveAllowedAuthenticationMethods/Bulk' }
        $script:SentJson | Should -Match '^\{"BulkItems":\[\{'
        $script:SentJson | Should -Match '"AllowedAuthenticationMethods":\["SAML","PKI"\]'
        $script:SentJson | Should -Match '"UserIds":\[42\]'
    }

    It 'URA03 - a single method is still sent as arrays' {
        Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ UserID = '42'; AuthMethods = 'SAML' } | Out-Null
        $script:SentJson | Should -Match '"AllowedAuthenticationMethods":\["SAML"\]'
        $script:SentJson | Should -Match '"UserIds":\[42\]'
    }

    It 'URA04 - Username is resolved to the exact match' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            New-UserSearchResponse -Users @([PSCustomObject]@{ id = 7; username = 'jdoe' }, [PSCustomObject]@{ id = 8; username = 'jdoe_adm' })
        }
        Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ Username = 'jdoe'; AuthMethods = 'SAML' } | Out-Null
        $script:SentJson | Should -Match '"UserIds":\[7\]'
    }
}

Describe 'Invoke-UsersRemoveAuthMethod - WhatIf' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { New-OkResponse }
    }

    It 'URA05 - WhatIf makes no API call' {
        $r = Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ UserID = '42'; AuthMethods = 'SAML' } -WhatIf
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

Describe 'Invoke-UsersRemoveAuthMethod - validation' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { New-OkResponse }
    }

    It 'URA06 - blank AuthMethods fails with no API call' {
        $r = Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ UserID = '42'; AuthMethods = ' ; ' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'URA07 - no user identifier fails with no API call' {
        $r = Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ AuthMethods = 'SAML' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'URA08 - an ambiguous Username fails and nothing is changed' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            New-UserSearchResponse -Users @([PSCustomObject]@{ id = 1; username = 'svc' }, [PSCustomObject]@{ id = 2; username = 'svc' })
        }
        $r = Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ Username = 'svc'; AuthMethods = 'SAML' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'PATCH' }
    }
}

Describe 'Invoke-UsersRemoveAuthMethod - API errors and 404 fallback' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'URA09 - 401 is fatal' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        (Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ UserID = '42'; AuthMethods = 'SAML' }).IsFatal | Should -BeTrue
    }

    It 'URA10 - 400 fails the row with the ErrorCode, no fallback' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 400 -ErrorMessage 'Bad method' }
        $r = Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ UserID = '42'; AuthMethods = 'SAML' }
        $r.IsFatal | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'ERR400'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'URA11 - a 404 falls back to GET + PUT with the merged allowedAuthenticationMethods list' {
        $script:PutBody = $null
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PATCH' } { New-ErrResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            New-OkResponse -Data ([PSCustomObject]@{ id = 42; username = 'jdoe'; description = 'keep'; allowedAuthenticationMethods = @('PKI', 'RADIUS') })
        }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name PutBody -Value $Body -Scope Script
            New-OkResponse
        }
        $r = Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ UserID = '42'; AuthMethods = 'SAML;PKI' }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' -and $Endpoint -eq '/API/Users/42' }
        @($script:PutBody['allowedAuthenticationMethods']) | Should -Be @('RADIUS')
        $script:PutBody['description'] | Should -Be 'keep'
    }

    It 'URA12 - the 404-fallback single-user GET passes -PageSize 0, so no limit/offset is sent' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PATCH' } { New-ErrResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            New-OkResponse -Data ([PSCustomObject]@{ id = 42; username = 'jdoe'; allowedAuthenticationMethods = @('PKI', 'SAML') })
        }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } { New-OkResponse }
        $null = Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ UserID = '42'; AuthMethods = 'SAML' }
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq '/API/Users/42' -and $PageSize -eq 0
        }
    }
}

Describe 'Invoke-UsersRemoveAuthMethod - bulk job result (F100)' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PATCH' } { New-OkResponse -Data 11 }
    }

    It 'URA13 - the job ID is waited on, and a successful job needs no PUT' {
        Mock Wait-CyberArkBulkAction { [PSCustomObject]@{ Completed = $true; Succeeded = $true; Status = 'Succeeded'; ErrorMessage = ''; StatusCode = 200 } }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } { New-OkResponse }
        $r = Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ UserID = '42'; AuthMethods = 'SAML' }
        $r.Successes | Should -Be 1
        Should -Invoke Wait-CyberArkBulkAction -Times 1 -Exactly -ParameterFilter { $BulkId -eq '11' }
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'URA14 - a failed job falls back to GET + PUT' {
        Mock Wait-CyberArkBulkAction { [PSCustomObject]@{ Completed = $true; Succeeded = $false; Status = 'Failed'; ErrorMessage = 'CAWS00001E: Not a valid Win32 FileTime.'; StatusCode = 200 } }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            New-OkResponse -Data ([PSCustomObject]@{ id = 42; username = 'jdoe'; allowedAuthenticationMethods = @('SAML'); expiryDate = -62135568000 })
        }
        $script:PutBody = $null
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name PutBody -Value $Body -Scope Script
            New-OkResponse -Data ([PSCustomObject]@{ allowedAuthenticationMethods = @($Body['allowedAuthenticationMethods']) })
        }
        $r = Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ UserID = '42'; AuthMethods = 'SAML' }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' -and $Endpoint -eq '/API/Users/42' }
        $script:PutBody.ContainsKey('expiryDate') | Should -BeFalse
    }

    It 'URA15 - a job that does not finish fails the row, with no PUT' {
        Mock Wait-CyberArkBulkAction { [PSCustomObject]@{ Completed = $false; Succeeded = $false; Status = 'InProgress'; ErrorMessage = 'Bulk job 11 did not finish within 20 seconds'; StatusCode = 200 } }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } { New-OkResponse }
        $r = Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ UserID = '42'; AuthMethods = 'SAML' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'not confirmed'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'URA16 - a PUT that answers 200 but did not save the change fails the row' {
        Mock Wait-CyberArkBulkAction { [PSCustomObject]@{ Completed = $true; Succeeded = $false; Status = 'Failed'; ErrorMessage = 'x'; StatusCode = 200 } }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            New-OkResponse -Data ([PSCustomObject]@{ id = 42; username = 'jdoe'; allowedAuthenticationMethods = @('PKI', 'SAML') })
        }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } { New-OkResponse -Data ([PSCustomObject]@{ allowedAuthenticationMethods = @('PKI', 'SAML') }) }
        $r = Invoke-UsersRemoveAuthMethod -Token $script:MockToken -InputData @{ UserID = '42'; AuthMethods = 'SAML' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match "'SAML' is still in the saved list"
    }
}