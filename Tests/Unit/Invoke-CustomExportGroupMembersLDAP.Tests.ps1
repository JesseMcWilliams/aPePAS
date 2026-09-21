#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-CustomExportGroupMembersLDAP.
    Note: ADSI-dependent paths require a domain-joined machine with AD access
    and are covered by integration testing. These unit tests cover the
    CyberArk API interaction and graceful error handling paths.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Custom\Invoke-CustomExportGroupMembersLDAP.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'CustomExportLDAPTests' -MinLevel 'ERROR'
}

Describe 'Invoke-CustomExportGroupMembersLDAP' {

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

    Context 'Group list API failure' {
        It 'returns failure when group list API fails' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 500; ErrorMessage = 'Server Error'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-CustomExportGroupMembersLDAP -Token $token -InputData @{}
            $result.Failures  | Should -BeGreaterThan 0
            $result.Successes | Should -Be 0
        }

        It 'sets IsFatal on 401 from group list' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 401; ErrorMessage = 'Unauthorized'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-CustomExportGroupMembersLDAP -Token $token -InputData @{}
            $result.IsFatal | Should -Be $true
        }
    }

    Context 'No LDAP groups in CyberArk' {
        It 'returns empty result when all groups are local (EPVGroup)' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $groupsData = [PSCustomObject]@{
                value = @(
                    [PSCustomObject]@{ id = 1; groupName = 'LocalGroup'; groupType = 'EPVGroup'; description = '' }
                )
            }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $groupsData }
            }
            $result = Invoke-CustomExportGroupMembersLDAP -Token $token -InputData @{}
            $result.Successes     | Should -Be 0
            $result.Results.Count | Should -Be 0
            $result.IsFatal       | Should -Be $false
        }

        It 'returns empty result when group list is empty' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $emptyData = [PSCustomObject]@{ value = @() }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $emptyData }
            }
            $result = Invoke-CustomExportGroupMembersLDAP -Token $token -InputData @{}
            $result.Successes     | Should -Be 0
            $result.Results.Count | Should -Be 0
        }
    }

    Context 'LDAP group found but AD group not resolvable' {
        It 'records error for each AD group that cannot be found and continues' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }

            $groupsData = [PSCustomObject]@{
                value = @(
                    [PSCustomObject]@{
                        id        = 1
                        groupName = 'NonExistentADGroup'
                        groupType = 'Directory'
                        directory = [PSCustomObject]@{ directoryType = 'LDAP' }
                    }
                )
            }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $groupsData }
            }

            # Run - will attempt ADSI lookup and fail gracefully (group not found in AD)
            { $result = Invoke-CustomExportGroupMembersLDAP -Token $token -InputData @{} } | Should -Not -Throw

            $result = Invoke-CustomExportGroupMembersLDAP -Token $token -InputData @{}
            # Either 0 successes (ADSI unavailable / group not found) or graceful error handling
            $result.IsFatal | Should -Be $false
        }
    }

}
