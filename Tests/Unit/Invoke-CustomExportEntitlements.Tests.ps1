#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-CustomExportEntitlements.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Custom\Invoke-CustomExportEntitlements.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'CustomExportEntitlementsTests' -MinLevel 'ERROR'
}

Describe 'Invoke-CustomExportEntitlements' {

    BeforeEach {
        $script:ActiveProfile = $null
    }

    Context 'ModuleMeta' {
        It 'AutoSaveCsv is true (bulk export tool - CSV saves with no prompt)' {
            $ModuleMeta.AutoSaveCsv | Should -BeTrue
        }

        It 'CsvFilenameNoDate is true (matches Custom/ExportAll''s fixed-name convention)' {
            $ModuleMeta.CsvFilenameNoDate | Should -BeTrue
        }
    }

    Context 'Safe list API failure' {
        It 'returns failure result when safe list API call fails' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 500; ErrorMessage = 'Server Error'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-CustomExportEntitlements -Token $token -InputData @{}
            $result.Failures  | Should -BeGreaterThan 0
            $result.Successes | Should -Be 0
        }

        It 'sets IsFatal when safe list returns 401' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 401; ErrorMessage = 'Unauthorized'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-CustomExportEntitlements -Token $token -InputData @{}
            $result.IsFatal | Should -Be $true
        }
    }

    Context 'Safe list returns no safes' {
        It 'returns empty result when safe list is empty' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $emptyData = [PSCustomObject]@{ value = @() }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $emptyData }
            }
            $result = Invoke-CustomExportEntitlements -Token $token -InputData @{}
            $result.Successes      | Should -Be 0
            $result.Results.Count  | Should -Be 0
            $result.IsFatal        | Should -Be $false
        }
    }

    Context 'Successful safe + member retrieval' {
        It 'returns combined member rows for all safes' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }

            $safesData = [PSCustomObject]@{
                value = @(
                    [PSCustomObject]@{ safeName = 'Safe1' }
                )
            }

            $perms = [PSCustomObject]@{
                UseAccounts = $true; RetrieveAccounts = $true; ListAccounts = $true
                AddAccounts = $false; UpdateAccountContent = $false; UpdateAccountProperties = $false
                ManageSafe = $false; ManageSafeMembers = $false; BackupSafe = $false
                ViewAuditLog = $true; ViewSafeMembers = $true
                DeleteAccounts = $false; UnlockAccounts = $false; RenameAccounts = $false
            }
            $membersData = [PSCustomObject]@{
                value = @(
                    [PSCustomObject]@{ memberName = 'User1'; memberType = 'User'; isPredefinedUser = $false; permissions = $perms }
                )
            }

            Mock Invoke-CyberArkAPI -ParameterFilter { $Endpoint -eq '/API/Safes' } {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $safesData }
            }
            Mock Invoke-CyberArkAPI -ParameterFilter { $Endpoint -like '*/Members' } {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $membersData }
            }

            $result = Invoke-CustomExportEntitlements -Token $token -InputData @{}
            $result.Successes          | Should -BeGreaterThan 0
            $result.Results.Count      | Should -BeGreaterThan 0
            $result.Results[0].SafeName    | Should -Be 'Safe1'
            $result.Results[0].MemberName  | Should -Be 'User1'
        }

        It 'continues to next safe when member retrieval fails with non-fatal error' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }

            $safesData = [PSCustomObject]@{
                value = @(
                    [PSCustomObject]@{ safeName = 'Safe1' }
                    [PSCustomObject]@{ safeName = 'Safe2' }
                )
            }

            Mock Invoke-CyberArkAPI -ParameterFilter { $Endpoint -eq '/API/Safes' } {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $safesData }
            }
            Mock Invoke-CyberArkAPI -ParameterFilter { $Endpoint -like '*/Members' } {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 403; ErrorMessage = 'Forbidden'; ErrorDetails = $null; Data = $null }
            }

            $result = Invoke-CustomExportEntitlements -Token $token -InputData @{}
            $result.IsFatal   | Should -Be $false
            $result.Failures  | Should -BeGreaterThan 0
        }
    }

}
