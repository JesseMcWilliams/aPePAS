#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Users\Invoke-UsersAdd.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-UsersAddInput is NOT tested here because it depends on Show-FieldPrompt (and Read-Host),
    which are interactive / defined in Manage-Privilege.ps1.
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Users\Invoke-UsersAdd.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath
    $script:FakePassword = 'ThisIsMy_FAKE_Password6!'

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'UsersAddTests' -MinLevel 'ERROR'

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
    It 'UAD01 - metadata is correct' {
        $ModuleMeta.Name             | Should -Be 'Add User'
        $ModuleMeta.Action           | Should -Be 'Add'
        $ModuleMeta.SupportsWhatIf   | Should -BeTrue
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.SupportedSystems | Should -Be @('SelfHosted')
        @($ModuleMeta.InputSchema | Where-Object { $_.Required }).Column | Should -Be 'Username'
    }
}

Describe 'Invoke-UsersAdd - success' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        $script:SentBody = $null
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name SentBody -Value (ConvertTo-Json -InputObject $Body -Depth 10 | ConvertFrom-Json) -Scope Script
            New-OkResponse -StatusCode 201 -Data ([PSCustomObject]@{
                id = 99; username = 'jdoe'; userType = 'EPVUser'; location = '\Applications'; enableUser = $true
                personalDetails = [PSCustomObject]@{ firstName = 'Jane'; lastName = 'Doe' }
            })
        }
    }

    It 'UAD02 - POST /API/Users with the mapped body and result' {
        $row = @{
            Username = 'jdoe'; InitialPassword = $script:FakePassword; UserType = 'EPVUser'; Location = '\Applications'
            FirstName = 'Jane'; LastName = 'Doe'; BusinessEmail = 'jane@example.com'; EnableUser = 'true'
            ChangePassOnNextLogon = 'false'; VaultAuthorization = 'AddSafes;AuditUsers'; AuthenticationMethod = 'AuthTypePass'
        }
        $r = Invoke-UsersAdd -Token $script:MockToken -InputData $row
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Endpoint -eq '/API/Users' }
        $script:SentBody.username                        | Should -Be 'jdoe'
        $script:SentBody.initialPassword                 | Should -Be $script:FakePassword
        $script:SentBody.personalDetails.firstName       | Should -Be 'Jane'
        $script:SentBody.internet.businessEmail          | Should -Be 'jane@example.com'
        $script:SentBody.enableUser                      | Should -BeTrue
        $script:SentBody.changePassOnNextLogon           | Should -BeFalse
        @($script:SentBody.vaultAuthorization)           | Should -Be @('AddSafes', 'AuditUsers')
        @($script:SentBody.authenticationMethod)         | Should -Be @('AuthTypePass')
        $r.Results[0].UserID    | Should -Be 99
        $r.Results[0].FirstName | Should -Be 'Jane'
    }

    It 'UAD03 - blank optional columns are not sent' {
        Invoke-UsersAdd -Token $script:MockToken -InputData @{ Username = 'jdoe'; InitialPassword = ''; Description = ''; EnableUser = '' } | Out-Null
        $names = @($script:SentBody.PSObject.Properties.Name)
        $names | Should -Be @('username')
    }
}

Describe 'Invoke-UsersAdd - the password is never logged, returned or sent in WhatIf' {
    BeforeEach {
        $script:LogLines = [System.Collections.Generic.List[string]]::new()
        Mock Write-CyberArkLog { param($Message, $Level, $FunctionName, [switch]$FileOnly) $script:LogLines.Add("$Message") }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'UAD04 - success: not in any log line or result' {
        Mock Invoke-CyberArkAPI { New-OkResponse -Data ([PSCustomObject]@{ id = 1; username = 'jdoe' }) }
        $r = Invoke-UsersAdd -Token $script:MockToken -InputData @{ Username = 'jdoe'; InitialPassword = $script:FakePassword }
        ($script:LogLines -join "`n") | Should -Not -Match 'FAKE_Password'
        ($r.Results | ConvertTo-Json -Depth 5) | Should -Not -Match 'FAKE_Password'
    }

    It 'UAD05 - failure: not in any log line, error message or error InputData' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 400 -ErrorMessage 'Password policy' }
        $r = Invoke-UsersAdd -Token $script:MockToken -InputData @{ Username = 'jdoe'; InitialPassword = $script:FakePassword }
        $r.Failures | Should -Be 1
        ($script:LogLines -join "`n") | Should -Not -Match 'FAKE_Password'
        ($r.Errors | ConvertTo-Json -Depth 5) | Should -Not -Match 'FAKE_Password'
    }

    It 'UAD06 - WhatIf: no API call' {
        Mock Invoke-CyberArkAPI { New-OkResponse }
        $r = Invoke-UsersAdd -Token $script:MockToken -InputData @{ Username = 'jdoe'; InitialPassword = $script:FakePassword; FirstName = 'Jane' } -WhatIf
        $r.Successes | Should -Be 1
        $r.Results[0].FirstName | Should -Be 'Jane'
        Should -Invoke Invoke-CyberArkAPI -Times 0
        ($script:LogLines -join "`n") | Should -Not -Match 'FAKE_Password'
    }

    It 'UAD13 - the start line says whether a password was given without tripping the log masker (F97)' {
        Mock Invoke-CyberArkAPI { New-OkResponse -Data ([PSCustomObject]@{ id = 1; username = 'jdoe' }) }
        $null = Invoke-UsersAdd -Token $script:MockToken -InputData @{ Username = 'jdoe' }
        $null = Invoke-UsersAdd -Token $script:MockToken -InputData @{ Username = 'jdoe'; InitialPassword = $script:FakePassword }
        $start = @($script:LogLines | Where-Object { $_ -like 'Starting user add*' })
        $start.Count | Should -Be 2
        $start[0] | Should -Match 'Initial password not provided'
        $start[1] | Should -Match 'Initial password provided'
        # CyberArkLogging masks any value after 'password:' or 'password='.
        ($start -join "`n") | Should -Not -Match '(?i)password\s*[:=]'
    }
}

Describe 'Invoke-UsersAdd - validation' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { New-OkResponse }
    }

    It 'UAD07 - missing Username fails with no API call' {
        $r = Invoke-UsersAdd -Token $script:MockToken -InputData @{ FirstName = 'Jane' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'Username is required'
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UAD08 - a password over 39 characters fails with no API call' {
        $r = Invoke-UsersAdd -Token $script:MockToken -InputData @{ Username = 'jdoe'; InitialPassword = ('a' * 40) }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UAD09 - a bad boolean or vault authorization fails with no API call' {
        $r = Invoke-UsersAdd -Token $script:MockToken -InputData @{ Username = 'jdoe'; EnableUser = 'sometimes'; VaultAuthorization = 'Nope' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'EnableUser'
        $r.Errors[0].ErrorMessage | Should -Match 'Nope'
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UAD10 - null InputData fails with no API call' {
        (Invoke-UsersAdd -Token $script:MockToken -InputData $null).Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }
}

Describe 'Invoke-UsersAdd - API errors' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'UAD11 - 401 is fatal' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        (Invoke-UsersAdd -Token $script:MockToken -InputData @{ Username = 'jdoe' }).IsFatal | Should -BeTrue
    }

    It 'UAD12 - 409 (user exists) fails the row with the ErrorCode, not fatal' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 409 -ErrorMessage 'User already exists' }
        $r = Invoke-UsersAdd -Token $script:MockToken -InputData @{ Username = 'jdoe' }
        $r.IsFatal | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'ERR409'
    }
}
