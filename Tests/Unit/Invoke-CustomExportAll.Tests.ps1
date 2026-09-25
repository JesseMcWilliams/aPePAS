#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-CustomExportAll.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Custom\Invoke-CustomExportAll.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'CustomExportAllTests' -MinLevel 'ERROR'

    # Stubs for Driver helpers - not available outside Manage-Privilege.ps1
    function global:Get-CsvSavePath { param([string]$DefaultFolder, [string]$ModuleName) return $null }
    # Invoke-FileWriteWithRetry's real implementation prompts interactively (via Confirm-Action)
    # on failure - this stub just runs Action once and surfaces whether it threw, which is all
    # these tests need.
    function global:Invoke-FileWriteWithRetry {
        param([scriptblock]$Action, [string]$Path)
        try { & $Action; return $true } catch { return $false }
    }
}

Describe 'Invoke-CustomExportAll' {

    BeforeEach {
        $script:LoadedModules = $null
        $script:ActiveProfile = $null
    }

    Context 'No loaded modules' {
        It 'returns empty result when LoadedModules is null' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.ItemsProcessed | Should -Be 0
            $result.Successes      | Should -Be 0
            $result.Failures       | Should -Be 0
        }

        It 'returns empty result when no list modules exist' {
            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Delete Something'; Category = 'Accounts'; Action = 'Delete'; ProducesOutput = $false; Priority = 10 }
            })
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.ItemsProcessed | Should -Be 0
        }

        It 'skips Custom category modules to prevent recursion' {
            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Export All'; Category = 'Custom'; Action = 'List'; ProducesOutput = $true; Priority = 80 }
            })
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.ItemsProcessed | Should -Be 0
        }
    }

    Context 'Module function throws' {
        It 'records error and continues when a list module throws' {
            # Set up a stub function that throws
            function Invoke-TestCategoryList {
                param($Token, $InputData, [switch]$WhatIf)
                throw 'Simulated module failure'
            }

            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Test List'; Category = 'TestCategory'; Action = 'List'; ProducesOutput = $true; Priority = 10 }
            })

            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.Failures      | Should -BeGreaterThan 0
            $result.Errors.Count  | Should -BeGreaterThan 0
        }
    }

    Context 'List module returns no results' {
        It 'adds Empty status row when module returns 0 records' {
            function Invoke-EmptyCategoryList {
                param($Token, $InputData, [switch]$WhatIf)
                return [PSCustomObject]@{
                    Results = [System.Collections.Generic.List[PSCustomObject]]::new()
                    Errors  = [System.Collections.Generic.List[PSCustomObject]]::new()
                    Successes = 0; Failures = 0
                }
            }

            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Empty List'; Category = 'EmptyCategory'; Action = 'List'; ProducesOutput = $true; Priority = 10 }
            })

            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.Successes          | Should -BeGreaterThan 0
            $result.Results.Count      | Should -BeGreaterThan 0
            $result.Results[0].Status  | Should -Be 'Empty'
            $result.Results[0].Records | Should -Be 0
        }
    }

    Context 'List module returns results' {
        It 'adds result rows with correct Module name when module returns data' {
            $mockResults = [System.Collections.Generic.List[PSCustomObject]]::new()
            $mockResults.Add([PSCustomObject]@{ Name = 'Item1' })

            function Invoke-DataCategoryList {
                param($Token, $InputData, [switch]$WhatIf)
                $r = [System.Collections.Generic.List[PSCustomObject]]::new()
                $r.Add([PSCustomObject]@{ Name = 'Item1' })
                return [PSCustomObject]@{
                    Results = $r
                    Errors  = [System.Collections.Generic.List[PSCustomObject]]::new()
                    Successes = 1; Failures = 0
                }
            }

            # Mock Get-CsvSavePath to return empty (simulate cancel)
            Mock Get-CsvSavePath { return $null }

            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Data List'; Category = 'DataCategory'; Action = 'List'; ProducesOutput = $true; Priority = 10 }
            })

            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.Successes         | Should -BeGreaterThan 0
            $result.Results.Count     | Should -BeGreaterThan 0
            $result.Results[0].Module | Should -Be 'Data List'
        }

        It 'records a SaveFailed row (not Saved) when Invoke-FileWriteWithRetry reports failure' {
            # e.g. the file was locked and the user declined to retry when prompted.
            Mock Invoke-FileWriteWithRetry { return $false }

            function Invoke-LockedCategoryList {
                param($Token, $InputData, [switch]$WhatIf)
                $r = [System.Collections.Generic.List[PSCustomObject]]::new()
                $r.Add([PSCustomObject]@{ Name = 'Item1' })
                return [PSCustomObject]@{
                    Results   = $r
                    Errors    = [System.Collections.Generic.List[PSCustomObject]]::new()
                    Successes = 1; Failures = 0
                }
            }

            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Locked List'; Category = 'LockedCategory'; Action = 'List'; ProducesOutput = $true; Priority = 10 }
            })

            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.Results[0].Status    | Should -Be 'SaveFailed'
            $result.Results[0].SavedPath | Should -Be ''
        }
    }

    Context 'ListAuthMethods discovery' {
        It 'discovers and runs Applications ListAuthMethods modules alongside List modules' {
            # Confirms the Action filter includes 'ListAuthMethods', not just 'List' - added
            # so Export All picks up Invoke-ApplicationsListAuthMethods.ps1 (whose "list every
            # application" behavior with no AppID supplied makes it a natural fit here).
            function Invoke-ApplicationsListAuthMethods {
                param($Token, $InputData, [switch]$WhatIf)
                $r = [System.Collections.Generic.List[PSCustomObject]]::new()
                $r.Add([PSCustomObject]@{ AppID = 'App1'; AuthType = 'path' })
                return [PSCustomObject]@{
                    Results   = $r
                    Errors    = [System.Collections.Generic.List[PSCustomObject]]::new()
                    Successes = 1; Failures = 0
                }
            }

            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'List Application Authentication Methods'; Category = 'Applications'; Action = 'ListAuthMethods'; ProducesOutput = $true; Priority = 89 }
            })

            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.ItemsProcessed              | Should -Be 1
            $result.Results[0].Module           | Should -Be 'List Application Authentication Methods'
        }
    }

    Context 'IncludeInExportAll opt-in' {
        It 'discovers a non-List/ListAuthMethods module that opts in via IncludeInExportAll' {
            # Confirms Policies/GetMasterPolicy (Action = 'GetMasterPolicy', not a List action)
            # is still picked up because it sets ModuleMeta.IncludeInExportAll = $true.
            function Invoke-PoliciesGetMasterPolicy {
                param($Token, $InputData, [switch]$WhatIf)
                $r = [System.Collections.Generic.List[PSCustomObject]]::new()
                $r.Add([PSCustomObject]@{ PolicyId = 1; DualControl = $true })
                return [PSCustomObject]@{
                    Results   = $r
                    Errors    = [System.Collections.Generic.List[PSCustomObject]]::new()
                    Successes = 1; Failures = 0
                }
            }

            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Get Master Policy'; Category = 'Policies'; Action = 'GetMasterPolicy'; ProducesOutput = $true; Priority = 90; IncludeInExportAll = $true }
            })

            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.ItemsProcessed    | Should -Be 1
            $result.Results[0].Module | Should -Be 'Get Master Policy'
        }

        It 'does not discover a non-List/ListAuthMethods module that does not opt in' {
            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Set Master Policy'; Category = 'Policies'; Action = 'SetMasterPolicy'; ProducesOutput = $true; Priority = 90 }
            })

            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}
            $result.ItemsProcessed | Should -Be 0
        }
    }

    Context 'Relative OutputFolder resolution' {
        BeforeEach {
            # $PSScriptRoot inside Invoke-CustomExportAll.ps1 is this file's own directory
            # (APIModules\Custom), not the project root - even though Manage-Privilege.ps1
            # dot-sources it into its own scope. A relative profile OutputFolder must resolve
            # against $script:APIModulesPath's parent (set by Manage-Privilege.ps1), the same
            # project root every other save-to-CSV path uses - not against this file's own
            # location.
            $script:TempProjectRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ExportAllTest_$([System.Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $script:TempProjectRoot -Force | Out-Null
            $script:APIModulesPath = Join-Path $script:TempProjectRoot 'APIModules'
            $script:ActiveProfile  = [PSCustomObject]@{ OutputFolder = 'Output' }
        }

        AfterEach {
            $script:APIModulesPath = $null
            if (Test-Path -LiteralPath $script:TempProjectRoot) {
                Remove-Item -LiteralPath $script:TempProjectRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'saves the CSV under the project root OutputFolder, not under APIModules\Custom' {
            function Invoke-RelPathCategoryList {
                param($Token, $InputData, [switch]$WhatIf)
                $r = [System.Collections.Generic.List[PSCustomObject]]::new()
                $r.Add([PSCustomObject]@{ Name = 'Item1' })
                return [PSCustomObject]@{
                    Results   = $r
                    Errors    = [System.Collections.Generic.List[PSCustomObject]]::new()
                    Successes = 1; Failures = 0
                }
            }

            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'RelPath List'; Category = 'RelPathCategory'; Action = 'List'; ProducesOutput = $true; Priority = 10 }
            })

            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}

            $expectedPath = Join-Path $script:TempProjectRoot 'Output\Export_RelPathCategoryList.csv'
            $result.Results[0].SavedPath | Should -Be $expectedPath
            Test-Path -LiteralPath $expectedPath | Should -BeTrue
            $result.Results[0].SavedPath | Should -Not -Match ([regex]::Escape('APIModules'))
        }
    }

    Context 'Automation mode -OutputFolder override' {
        BeforeEach {
            $script:ActiveProfile = [PSCustomObject]@{ OutputFolder = Join-Path ([System.IO.Path]::GetTempPath()) "ExportAllProfileFolder_$([System.Guid]::NewGuid().ToString('N'))" }
            $script:OverrideDir   = Join-Path ([System.IO.Path]::GetTempPath()) "ExportAllOverride_$([System.Guid]::NewGuid().ToString('N'))"

            function Invoke-OverrideCategoryList {
                param($Token, $InputData, [switch]$WhatIf)
                $r = [System.Collections.Generic.List[PSCustomObject]]::new()
                $r.Add([PSCustomObject]@{ Name = 'Item1' })
                return [PSCustomObject]@{
                    Results   = $r
                    Errors    = [System.Collections.Generic.List[PSCustomObject]]::new()
                    Successes = 1; Failures = 0
                }
            }
            $script:LoadedModules = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:LoadedModules.Add([PSCustomObject]@{
                Meta = @{ Name = 'Override List'; Category = 'OverrideCategory'; Action = 'List'; ProducesOutput = $true; Priority = 10 }
            })
        }

        AfterEach {
            $script:AutomationMode = $null
            $script:OutputFolder   = $null
            foreach ($dir in @($script:ActiveProfile.OutputFolder, $script:OverrideDir)) {
                if ($dir -and (Test-Path -LiteralPath $dir)) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'saves under -OutputFolder instead of the profile folder when automation mode is on' {
            $script:AutomationMode = $true
            $script:OutputFolder   = $script:OverrideDir

            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}

            $expectedPath = Join-Path $script:OverrideDir 'Export_OverrideCategoryList.csv'
            $result.Results[0].SavedPath | Should -Be $expectedPath
            Test-Path -LiteralPath $expectedPath | Should -BeTrue
        }

        It 'ignores -OutputFolder when automation mode is off, keeping the profile folder' {
            $script:AutomationMode = $false
            $script:OutputFolder   = $script:OverrideDir

            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-CustomExportAll -Token $token -InputData @{}

            $expectedPath = Join-Path $script:ActiveProfile.OutputFolder 'Export_OverrideCategoryList.csv'
            $result.Results[0].SavedPath | Should -Be $expectedPath
            Test-Path -LiteralPath $script:OverrideDir | Should -BeFalse
        }

        It 'does not throw when $script:AutomationMode is falsy/unset' {
            # Matches how this module is actually exercised by every other test in this file
            # (and by its own standalone unit test in general) - dot-sourced without
            # Manage-Privilege.ps1's Configuration region ever running, so $script:AutomationMode
            # is never a real, script-established $true. A direct, unguarded reference to a
            # variable that was truly never set anywhere in this scope throws under strict mode
            # instead of evaluating falsy (this project hit exactly that bug once already, in
            # Invoke-SafesDelete.ps1 - see Testing_Findings-and-Known-Issues.md F53) - this confirms the Get-Variable
            # guard here avoids it.
            $script:AutomationMode = $null
            { Invoke-CustomExportAll -Token ([PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }) -InputData @{} } | Should -Not -Throw
        }
    }

}
