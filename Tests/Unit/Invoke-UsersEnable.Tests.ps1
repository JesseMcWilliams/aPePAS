#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Users\Invoke-UsersEnable.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-UsersEnableInput is NOT tested here because it depends on Show-FieldPrompt and
    Invoke-EntitySearch, which are defined in Manage-Privilege.ps1.
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Users\Invoke-UsersEnable.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'UsersEnableTests' -MinLevel 'ERROR'

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
    It 'UEN01 - metadata is correct' {
        $ModuleMeta.Name             | Should -Be 'Enable User'
        $ModuleMeta.Category         | Should -Be 'Users'
        $ModuleMeta.Action           | Should -Be 'Enable'
        $ModuleMeta.SupportsWhatIf   | Should -BeTrue
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.HasCustomInput   | Should -BeTrue
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
        $ModuleMeta.SupportedSystems | Should -Not -Contain 'ISPSS'
        @($ModuleMeta.InputSchema | ForEach-Object { $_.Column }) | Should -Be @('UserID', 'Username')
    }
}

Describe 'Invoke-UsersEnable - success' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { New-OkResponse -StatusCode 204 }
    }

    It 'UEN02 - POST /API/Users/{id}/enable by UserID' {
        $r = Invoke-UsersEnable -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.Successes      | Should -Be 1
        $r.Failures       | Should -Be 0
        $r.ItemsProcessed | Should -Be 1
        $r.Results[0].Enabled | Should -Be $true
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Endpoint -eq '/API/Users/42/enable' }
    }

    It 'UEN03 - Username is resolved to the ID of the exact match' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            New-UserSearchResponse -Users @(
                [PSCustomObject]@{ id = 41; username = 'jdoe.admin' }
                [PSCustomObject]@{ id = 42; username = 'jdoe' }
            )
        }
        $r = Invoke-UsersEnable -Token $script:MockToken -InputData @{ Username = 'jdoe' }
        $r.Successes | Should -Be 1
        $r.Results[0].UserID | Should -Be '42'
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Endpoint -eq '/API/Users' -and $QueryParams['search'] -eq 'jdoe' }
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Endpoint -eq '/API/Users/42/enable' }
    }
}

Describe 'Invoke-UsersEnable - WhatIf' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { New-OkResponse }
    }

    It 'UEN04 - WhatIf makes no API call and counts a success' {
        $r = Invoke-UsersEnable -Token $script:MockToken -InputData @{ UserID = '42' } -WhatIf
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UEN05 - WhatIf with Username still resolves (read-only GET) but never POSTs' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } { New-UserSearchResponse -Users @([PSCustomObject]@{ id = 42; username = 'jdoe' }) }
        $r = Invoke-UsersEnable -Token $script:MockToken -InputData @{ Username = 'jdoe' } -WhatIf
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'POST' }
    }
}

Describe 'Invoke-UsersEnable - validation and username resolution' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { New-OkResponse }
    }

    It 'UEN06 - no UserID or Username fails with no API call' {
        $r = Invoke-UsersEnable -Token $script:MockToken -InputData @{}
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Be 'UserID or Username is required.'
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UEN07 - null InputData fails with no API call' {
        $r = Invoke-UsersEnable -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UEN08 - several users with the same username fail the row and nothing is changed' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            New-UserSearchResponse -Users @([PSCustomObject]@{ id = 1; username = 'svc' }, [PSCustomObject]@{ id = 2; username = 'SVC' })
        }
        $r = Invoke-UsersEnable -Token $script:MockToken -InputData @{ Username = 'svc' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match '2 users'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'POST' }
    }

    It 'UEN09 - no exact match (only partial search hits) fails the row' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } { New-UserSearchResponse -Users @([PSCustomObject]@{ id = 5; username = 'jdoe2' }) }
        $r = Invoke-UsersEnable -Token $script:MockToken -InputData @{ Username = 'jdoe' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Be "No user with Username 'jdoe' found."
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'POST' }
    }
}

Describe 'Invoke-UsersEnable - API errors' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'UEN10 - 401 is fatal' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-UsersEnable -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.IsFatal  | Should -BeTrue
        $r.Failures | Should -Be 1
    }

    It 'UEN11 - 404 fails the row, not fatal, and the error includes the ErrorCode' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 404 -ErrorMessage 'User not found' }
        $r = Invoke-UsersEnable -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.IsFatal  | Should -BeFalse
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'ERR404'
    }

    It 'UEN12 - 401 on the username lookup is fatal' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-UsersEnable -Token $script:MockToken -InputData @{ Username = 'jdoe' }
        $r.IsFatal | Should -BeTrue
    }
}

Describe 'Invoke-UsersEnable - 404 fallback to PUT (PVWA before 12.6)' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        $script:PutBody = $null
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' } { New-ErrResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            New-OkResponse -Data ([PSCustomObject]@{ id = 42; username = 'jdoe'; description = 'keep me'; enableUser = (-not $true); source = 'CyberArk' })
        }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'PUT' } {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name PutBody -Value $Body -Scope Script
            New-OkResponse -Data ([PSCustomObject]@{ id = 42; username = 'jdoe' })
        }
    }

    It 'UEN13 - a 404 falls back to GET + PUT with enableUser and keeps the other fields' {
        $r = Invoke-UsersEnable -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.Successes | Should -Be 1
        $r.Results[0].Username | Should -Be 'jdoe'
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' -and $Endpoint -eq '/API/Users/42' }
        $script:PutBody['enableUser']  | Should -Be $true
        $script:PutBody['description'] | Should -Be 'keep me'
        $script:PutBody.ContainsKey('source') | Should -BeFalse
    }

    It 'UEN14 - a 403 does not fall back' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' } { New-ErrResponse -StatusCode 403 -ErrorMessage 'Forbidden' }
        $r = Invoke-UsersEnable -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'PUT' }
    }
}
