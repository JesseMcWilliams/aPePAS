#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Users\Invoke-UsersResetPassword.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-UsersResetPasswordInput is NOT tested here because it depends on Show-FieldPrompt,
    Invoke-EntitySearch and Read-Host -AsSecureString (interactive).
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Users\Invoke-UsersResetPassword.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'UsersResetPasswordTests' -MinLevel 'ERROR'

    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://test.cyberark.local'
    }

    $script:FakePassword = 'ThisIsMy_FAKE_Password6!'

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
    It 'URP01 - metadata is correct' {
        $ModuleMeta.Name             | Should -Be 'Reset User Password'
        $ModuleMeta.Action           | Should -Be 'ResetPassword'
        $ModuleMeta.SupportsWhatIf   | Should -BeTrue
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
        $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
        @($ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'NewPassword' })[0].Required | Should -BeTrue
    }
}

Describe 'Invoke-UsersResetPassword - success' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        $script:SentBody = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            if ($Body) { Set-Variable -Name SentBody -Value ($Body | ConvertTo-Json -Compress) -Scope Script }
            New-OkResponse
        }
    }

    It 'URP02 - POST /API/Users/{id}/ResetPassword with newPassword' {
        $r = Invoke-UsersResetPassword -Token $script:MockToken -InputData @{ UserID = '42'; NewPassword = $script:FakePassword }
        $r.Successes | Should -Be 1
        $r.Results[0].PasswordReset | Should -BeTrue
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Endpoint -eq '/API/Users/42/ResetPassword' }
        $script:SentBody | Should -Match ([regex]::Escape($script:FakePassword))
        $script:SentBody | Should -Match '"newPassword"'
    }

    It 'URP03 - Username is resolved to the exact match before the reset' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } { New-UserSearchResponse -Users @([PSCustomObject]@{ id = 42; username = 'svc_app' }) }
        $r = Invoke-UsersResetPassword -Token $script:MockToken -InputData @{ Username = 'svc_app'; NewPassword = $script:FakePassword }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Endpoint -eq '/API/Users/42/ResetPassword' }
    }
}

Describe 'Invoke-UsersResetPassword - the password is never logged or returned' {
    BeforeEach {
        $script:LogLines = [System.Collections.Generic.List[string]]::new()
        Mock Write-CyberArkLog { param($Message, $Level, $FunctionName, [switch]$FileOnly) $script:LogLines.Add("$Message") }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'URP04 - success: not in any log line or result' {
        Mock Invoke-CyberArkAPI { New-OkResponse }
        $r = Invoke-UsersResetPassword -Token $script:MockToken -InputData @{ UserID = '42'; NewPassword = $script:FakePassword }
        ($script:LogLines -join "`n") | Should -Not -Match 'FAKE_Password'
        ($r.Results | ConvertTo-Json -Depth 5) | Should -Not -Match 'FAKE_Password'
    }

    It 'URP05 - failure: not in any log line, error message or error InputData' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 400 -ErrorMessage 'Password does not meet policy' }
        $r = Invoke-UsersResetPassword -Token $script:MockToken -InputData @{ UserID = '42'; NewPassword = $script:FakePassword }
        $r.Failures | Should -Be 1
        ($script:LogLines -join "`n") | Should -Not -Match 'FAKE_Password'
        ($r.Errors | ConvertTo-Json -Depth 5) | Should -Not -Match 'FAKE_Password'
        $r.Errors[0].InputData['NewPassword'] | Should -Be '***'
    }

    It 'URP06 - WhatIf: no API call, so the password is never sent' {
        Mock Invoke-CyberArkAPI { New-OkResponse }
        $r = Invoke-UsersResetPassword -Token $script:MockToken -InputData @{ UserID = '42'; NewPassword = $script:FakePassword } -WhatIf
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
        ($script:LogLines -join "`n") | Should -Not -Match 'FAKE_Password'
    }

    It 'URP07 - the request body DEBUG log written by Invoke-CyberArkAPI masks newPassword' {
        # The real masking function used by Write-CyberArkLog for every message.
        $masked = & (Get-Module CyberArkLogging) { param($m) script:Mask-SensitiveData -Message $m } ('Request body: ' + (@{ newPassword = $script:FakePassword } | ConvertTo-Json -Compress))
        $masked | Should -Not -Match 'FAKE_Password'
    }
}

Describe 'Invoke-UsersResetPassword - validation' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { New-OkResponse }
    }

    It 'URP08 - missing NewPassword fails with no API call' {
        $r = Invoke-UsersResetPassword -Token $script:MockToken -InputData @{ UserID = '42'; NewPassword = '' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Be 'NewPassword is required.'
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'URP09 - a password over 39 characters fails with no API call' {
        $r = Invoke-UsersResetPassword -Token $script:MockToken -InputData @{ UserID = '42'; NewPassword = ('a' * 40) }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match '39'
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'URP10 - no user identifier fails with no API call' {
        $r = Invoke-UsersResetPassword -Token $script:MockToken -InputData @{ NewPassword = $script:FakePassword }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'URP11 - an ambiguous Username fails and no password is sent' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            New-UserSearchResponse -Users @([PSCustomObject]@{ id = 1; username = 'svc' }, [PSCustomObject]@{ id = 2; username = 'svc' })
        }
        $r = Invoke-UsersResetPassword -Token $script:MockToken -InputData @{ Username = 'svc'; NewPassword = $script:FakePassword }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'POST' }
    }
}

Describe 'Invoke-UsersResetPassword - API errors' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'URP12 - 401 is fatal' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        (Invoke-UsersResetPassword -Token $script:MockToken -InputData @{ UserID = '42'; NewPassword = $script:FakePassword }).IsFatal | Should -BeTrue
    }

    It 'URP13 - 400 fails the row, not fatal, with the ErrorCode in the message' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 400 -ErrorMessage 'Bad Request' }
        $r = Invoke-UsersResetPassword -Token $script:MockToken -InputData @{ UserID = '42'; NewPassword = $script:FakePassword }
        $r.IsFatal | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'ERR400'
    }
}
