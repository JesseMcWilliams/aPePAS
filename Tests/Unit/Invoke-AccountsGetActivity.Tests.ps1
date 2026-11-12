#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsGetActivity.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsGetActivity.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsGetActivityTests' -MinLevel 'ERROR'
}

Describe 'Invoke-AccountsGetActivity' {

    Context 'Missing AccountID' {
        It 'returns failure when AccountID is not provided' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-AccountsGetActivity -Token $token -InputData @{}
            $result.Failures    | Should -Be 1
            $result.Successes   | Should -Be 0
            $result.IsFatal     | Should -Be $false
        }
    }

    Context 'API call failure' {
        It 'records error on non-success response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 404; ErrorMessage = 'Not Found'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-AccountsGetActivity -Token $token -InputData @{ AccountID = 'acc123' }
            $result.Failures    | Should -BeGreaterThan 0
            $result.IsFatal     | Should -Be $false
        }
    }

    Context 'Successful operation' {
        It 'returns activity rows on success' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $actData = [PSCustomObject]@{
                Activities = @(
                    [PSCustomObject]@{ time = '12345'; action = 'LogonByUser'; reason = ''; User = 'Admin' }
                )
            }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $actData }
            }
            $result = Invoke-AccountsGetActivity -Token $token -InputData @{ AccountID = 'acc123' }
            $result.Successes   | Should -BeGreaterThan 0
            $result.Failures    | Should -Be 0
        }

        It 'the single-account Activities GET passes -PageSize 0, so no limit/offset is sent' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ Activities = @() } }
            }
            $null = Invoke-AccountsGetActivity -Token $token -InputData @{ AccountID = 'acc123' }
            Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'GET' -and $Endpoint -eq '/API/Accounts/acc123/Activities' -and $PageSize -eq 0
            }
        }
    }
    # GetActivity is a GET - SupportsWhatIf=$false; WhatIf does not suppress GET calls

    Context 'Activity row mapping (v2 response shape seen live on PVWA 14.6)' {
        BeforeAll {
            $script:actToken = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $script:epoch    = 1794451565
            $script:expected = [DateTimeOffset]::FromUnixTimeSeconds($script:epoch).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
        }

        It 'AT01 - Time comes from Date (Unix seconds), shown as local yyyy-MM-dd HH:mm:ss' {
            $row = [PSCustomObject]@{ Alert = $false; Date = $script:epoch; User = 'PasswordManager'; Action = 'CPM Reconcile Password'; ActionID = 31; ClientID = 'CPM'; MoreInfo = 'Address: company.com'; Reason = 'Password was scheduled for immediate task' }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ Activities = @($row) } }
            }
            $result = Invoke-AccountsGetActivity -Token $script:actToken -InputData @{ AccountID = '50_3' }
            $result.Results[0].Time | Should -Be $script:expected
        }

        It 'AT02 - maps Action, Reason, User, ClientID, MoreInfo, ActionID and Alert' {
            $row = [PSCustomObject]@{ Alert = $true; Date = $script:epoch; User = 'PasswordManager'; Action = 'CPM Reconcile Password'; ActionID = 31; ClientID = 'CPM'; MoreInfo = 'Address: company.com'; Reason = 'scheduled' }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ Activities = @($row) } }
            }
            $r = (Invoke-AccountsGetActivity -Token $script:actToken -InputData @{ AccountID = '50_3' }).Results[0]
            $r.Action   | Should -Be 'CPM Reconcile Password'
            $r.Reason   | Should -Be 'scheduled'
            $r.User     | Should -Be 'PasswordManager'
            $r.ClientID | Should -Be 'CPM'
            $r.MoreInfo | Should -Be 'Address: company.com'
            $r.ActionID | Should -Be 31
            $r.Alert    | Should -Be $true
        }

        It 'AT03 - a Date in milliseconds gives the same time as seconds' {
            $row = [PSCustomObject]@{ Date = [long]$script:epoch * 1000; Action = 'Retrieve password' }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ Activities = @($row) } }
            }
            (Invoke-AccountsGetActivity -Token $script:actToken -InputData @{ AccountID = '50_3' }).Results[0].Time | Should -Be $script:expected
        }

        It 'AT04 - a row with no Date and no optional fields maps to blanks without a strict-mode error' {
            $row = [PSCustomObject]@{ Action = 'Retrieve password' }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ Activities = @($row) } }
            }
            $result = Invoke-AccountsGetActivity -Token $script:actToken -InputData @{ AccountID = '50_3' }
            $result.Failures             | Should -Be 0
            $result.Results[0].Time      | Should -Be ''
            $result.Results[0].MoreInfo  | Should -Be ''
            $result.Results[0].Alert     | Should -Be ''
        }

        It 'AT05 - a Date that is not a number is passed through as text' {
            $row = [PSCustomObject]@{ Date = '2026-11-12T05:26:05Z'; Action = 'Retrieve password' }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ Activities = @($row) } }
            }
            (Invoke-AccountsGetActivity -Token $script:actToken -InputData @{ AccountID = '50_3' }).Results[0].Time | Should -Be '2026-11-12T05:26:05Z'
        }
    }

}
