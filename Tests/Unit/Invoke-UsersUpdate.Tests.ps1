#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Users\Invoke-UsersUpdate.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-UsersUpdateInput is NOT tested here because it depends on Show-FieldPrompt and
    Invoke-EntitySearch, which are defined in Manage-Privilege.ps1.
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Users\Invoke-UsersUpdate.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'UsersUpdateTests' -MinLevel 'ERROR'

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
    It 'UUP01 - metadata is correct' {
        $ModuleMeta.Name             | Should -Be 'Update User'
        $ModuleMeta.Action           | Should -Be 'Update'
        $ModuleMeta.SupportsWhatIf   | Should -BeTrue
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.SupportedSystems | Should -Be @('SelfHosted')
        @($ModuleMeta.InputSchema | Where-Object { $_.Required }).Count | Should -Be 0
    }
}

Describe 'Invoke-UsersUpdate - GET + merge + PUT' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        $script:PutBody = $null
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' -and $Endpoint -eq '/API/Users/42' } {
            New-OkResponse -Data ([PSCustomObject]@{
                id = 42; username = 'jdoe'; source = 'CyberArk'; componentUser = $false; userType = 'EPVUser'
                description = 'old desc'; location = '\'; enableUser = $true; changePassOnNextLogon = $false
                vaultAuthorization = @('AuditUsers'); groupsMembership = @(); authenticationMethod = @('AuthTypePass')
                personalDetails = [PSCustomObject]@{ firstName = 'Jane'; lastName = 'Doe'; department = 'IT' }
                internet = [PSCustomObject]@{ businessEmail = 'old@example.com' }
            })
        }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name PutBody -Value $Body -Scope Script
            New-OkResponse -Data ([PSCustomObject]@{ id = 42; username = 'jdoe'; description = $Body['description']; personalDetails = [PSCustomObject]@{ firstName = 'Jane'; lastName = 'Smith' } })
        }
    }

    It 'UUP02 - only supplied fields change; every other current value is resent' {
        $r = Invoke-UsersUpdate -Token $script:MockToken -InputData @{ UserID = '42'; LastName = 'Smith'; Description = ''; FirstName = ''; Location = '' }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' -and $Endpoint -eq '/API/Users/42' }
        $script:PutBody['personalDetails']['lastName']   | Should -Be 'Smith'
        $script:PutBody['personalDetails']['firstName']  | Should -Be 'Jane'
        $script:PutBody['personalDetails']['department'] | Should -Be 'IT'
        $script:PutBody['description']                   | Should -Be 'old desc'
        $script:PutBody['internet']['businessEmail']     | Should -Be 'old@example.com'
        $script:PutBody['username']                      | Should -Be 'jdoe'
        $script:PutBody['enableUser']                    | Should -BeTrue
        $r.Results[0].LastName | Should -Be 'Smith'
    }

    It 'UUP03 - read-only fields from the GET are not sent' {
        Invoke-UsersUpdate -Token $script:MockToken -InputData @{ UserID = '42'; Description = 'new' } | Out-Null
        foreach ($k in 'id', 'source', 'componentUser', 'groupsMembership', 'authenticationMethod') {
            $script:PutBody.ContainsKey($k) | Should -BeFalse -Because "$k is not an EditUserRequest field"
        }
        $script:PutBody['description'] | Should -Be 'new'
    }

    It 'UUP04 - VaultAuthorization replaces the list' {
        Invoke-UsersUpdate -Token $script:MockToken -InputData @{ UserID = '42'; VaultAuthorization = 'AddSafes;AuditUsers' } | Out-Null
        @($script:PutBody['vaultAuthorization']) | Should -Be @('AddSafes', 'AuditUsers')
    }

    It 'UUP05 - Username is resolved to the exact match' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' -and $Endpoint -eq '/API/Users' } {
            New-UserSearchResponse -Users @([PSCustomObject]@{ id = 41; username = 'jdoe.old' }, [PSCustomObject]@{ id = 42; username = 'jdoe' })
        }
        $r = Invoke-UsersUpdate -Token $script:MockToken -InputData @{ Username = 'jdoe'; Description = 'new' }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' -and $Endpoint -eq '/API/Users/42' }
    }

    It 'UUP06 - WhatIf GETs (read-only) but never PUTs, and shows the merged values' {
        $r = Invoke-UsersUpdate -Token $script:MockToken -InputData @{ UserID = '42'; LastName = 'Smith' } -WhatIf
        $r.Successes | Should -Be 1
        $r.Results[0].LastName  | Should -Be 'Smith'
        $r.Results[0].FirstName | Should -Be 'Jane'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'UUP14 - the single-user GET passes -PageSize 0, so no limit/offset is sent' {
        Invoke-UsersUpdate -Token $script:MockToken -InputData @{ UserID = '42'; Description = 'new' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq '/API/Users/42' -and $PageSize -eq 0
        }
    }
}

Describe 'Invoke-UsersUpdate - validation' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { New-OkResponse }
    }

    It 'UUP07 - no fields to change fails with no API call' {
        $r = Invoke-UsersUpdate -Token $script:MockToken -InputData @{ UserID = '42'; Description = ''; LastName = ' ' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'Nothing to update'
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UUP08 - no user identifier fails with no API call' {
        $r = Invoke-UsersUpdate -Token $script:MockToken -InputData @{ Description = 'x' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UUP09 - an invalid value fails with no API call' {
        $r = Invoke-UsersUpdate -Token $script:MockToken -InputData @{ UserID = '42'; ExpiryDate = 'next year' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UUP10 - an ambiguous Username fails and nothing is updated' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            New-UserSearchResponse -Users @([PSCustomObject]@{ id = 1; username = 'svc' }, [PSCustomObject]@{ id = 2; username = 'svc' })
        }
        $r = Invoke-UsersUpdate -Token $script:MockToken -InputData @{ Username = 'svc'; Description = 'x' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }
}

Describe 'Invoke-UsersUpdate - API errors' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'UUP11 - 401 on the GET is fatal' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        (Invoke-UsersUpdate -Token $script:MockToken -InputData @{ UserID = '42'; Description = 'x' }).IsFatal | Should -BeTrue
    }

    It 'UUP12 - 404 on the GET fails the row with the ErrorCode, and no PUT is sent' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 404 -ErrorMessage 'User not found' }
        $r = Invoke-UsersUpdate -Token $script:MockToken -InputData @{ UserID = '42'; Description = 'x' }
        $r.IsFatal | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'ERR404'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'UUP13 - 401 on the PUT is fatal' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } { New-OkResponse -Data ([PSCustomObject]@{ id = 42; username = 'jdoe' }) }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } { New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        (Invoke-UsersUpdate -Token $script:MockToken -InputData @{ UserID = '42'; Description = 'x' }).IsFatal | Should -BeTrue
    }
}
