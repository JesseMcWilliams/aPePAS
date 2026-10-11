#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Users\Invoke-UsersUnblock.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked.

.NOTES
    Get-UsersUnblockInput is NOT tested here because it depends on Show-FieldPrompt and
    Invoke-EntitySearch, which are defined in Manage-Privilege.ps1.
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Users\Invoke-UsersUnblock.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'UsersUnblockTests' -MinLevel 'ERROR'

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
    It 'UUB01 - metadata is correct' {
        $ModuleMeta.Name             | Should -Be 'Unblock User'
        $ModuleMeta.Category         | Should -Be 'Users'
        $ModuleMeta.Action           | Should -Be 'Unblock'
        $ModuleMeta.SupportsWhatIf   | Should -BeTrue
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.HasCustomInput   | Should -BeTrue
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
        $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
        @($ModuleMeta.InputSchema | ForEach-Object { $_.Column }) | Should -Be @('UserID', 'Username')
    }
}

Describe 'Invoke-UsersUnblock - success' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { New-OkResponse -StatusCode 204 }
    }

    It 'UUB02 - POST /API/Users/{id}/Activate by UserID' {
        $r = Invoke-UsersUnblock -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.Successes      | Should -Be 1
        $r.Failures       | Should -Be 0
        $r.ItemsProcessed | Should -Be 1
        $r.Results[0].Unblocked | Should -BeTrue
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Endpoint -eq '/API/Users/42/Activate' }
    }

    It 'UUB03 - Username is resolved to the ID of the exact match' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            New-UserSearchResponse -Users @(
                [PSCustomObject]@{ id = 41; username = 'jdoe.admin' }
                [PSCustomObject]@{ id = 42; username = 'jdoe' }
            )
        }
        $r = Invoke-UsersUnblock -Token $script:MockToken -InputData @{ Username = 'jdoe' }
        $r.Successes | Should -Be 1
        $r.Results[0].UserID | Should -Be '42'
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Endpoint -eq '/API/Users' -and $QueryParams['search'] -eq 'jdoe' }
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Endpoint -eq '/API/Users/42/Activate' }
    }
}

Describe 'Invoke-UsersUnblock - WhatIf' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { New-OkResponse }
    }

    It 'UUB04 - WhatIf makes no API call and counts a success' {
        $r = Invoke-UsersUnblock -Token $script:MockToken -InputData @{ UserID = '42' } -WhatIf
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UUB05 - WhatIf with Username still resolves (read-only GET) but never POSTs' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } { New-UserSearchResponse -Users @([PSCustomObject]@{ id = 42; username = 'jdoe' }) }
        $r = Invoke-UsersUnblock -Token $script:MockToken -InputData @{ Username = 'jdoe' } -WhatIf
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'POST' }
    }
}

Describe 'Invoke-UsersUnblock - validation and username resolution' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Invoke-CyberArkAPI { New-OkResponse }
    }

    It 'UUB06 - no UserID or Username fails with no API call' {
        $r = Invoke-UsersUnblock -Token $script:MockToken -InputData @{}
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Be 'UserID or Username is required.'
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UUB07 - null InputData fails with no API call' {
        $r = Invoke-UsersUnblock -Token $script:MockToken -InputData $null
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0
    }

    It 'UUB08 - several users with the same username fail the row and nothing is unblocked' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            New-UserSearchResponse -Users @([PSCustomObject]@{ id = 1; username = 'svc' }, [PSCustomObject]@{ id = 2; username = 'SVC' })
        }
        $r = Invoke-UsersUnblock -Token $script:MockToken -InputData @{ Username = 'svc' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match '2 users'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'POST' }
    }

    It 'UUB09 - no exact match (only partial search hits) fails the row' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } { New-UserSearchResponse -Users @([PSCustomObject]@{ id = 5; username = 'jdoe2' }) }
        $r = Invoke-UsersUnblock -Token $script:MockToken -InputData @{ Username = 'jdoe' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Be "No user with Username 'jdoe' found."
        Should -Invoke Invoke-CyberArkAPI -Times 0 -ParameterFilter { $Method -eq 'POST' }
    }
}

Describe 'Invoke-UsersUnblock - API errors' {
    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'UUB10 - 401 is fatal' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-UsersUnblock -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.IsFatal  | Should -BeTrue
        $r.Failures | Should -Be 1
    }

    It 'UUB11 - 404 fails the row, not fatal, and the error includes the ErrorCode' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 404 -ErrorMessage 'User not found' }
        $r = Invoke-UsersUnblock -Token $script:MockToken -InputData @{ UserID = '42' }
        $r.IsFatal  | Should -BeFalse
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'ERR404'
    }

    It 'UUB12 - 401 on the username lookup is fatal' {
        Mock Invoke-CyberArkAPI { New-ErrResponse -StatusCode 401 -ErrorMessage 'Unauthorized' }
        $r = Invoke-UsersUnblock -Token $script:MockToken -InputData @{ Username = 'jdoe' }
        $r.IsFatal | Should -BeTrue
    }
}
