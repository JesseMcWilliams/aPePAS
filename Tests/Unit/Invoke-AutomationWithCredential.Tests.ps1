#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AutomationWithCredential.ps1. A stand-in aPeSecrets module and a stand-in
    Manage-Privilege.ps1 (both written to TestDrive) replace the real ones, so no credential source
    or CyberArk system is touched.
#>

BeforeAll {
    $script:WrapperPath = Join-Path $PSScriptRoot '..\..\Invoke-AutomationWithCredential.ps1'
    . $script:WrapperPath -ProfileName 'DotSourced'

    $script:FakeSecrets = Join-Path $TestDrive 'FakeResolver.psm1'
    Set-Content -LiteralPath $script:FakeSecrets -Encoding UTF8 -Value @'
function Get-ResolvedCredential {
    param([string]$Source, [hashtable]$Params)
    $global:FakeResolveCalls.Add(@{ Source = $Source; Params = $Params })
    if ($Params.ContainsKey('Fail'))       { throw 'source unavailable' }
    if ($Params.ContainsKey('ReturnNull')) { return $null }
    New-Object System.Management.Automation.PSCredential('svc-apepas', (ConvertTo-SecureString 'ThisIsMy_FAKE_Password6!' -AsPlainText -Force))
}
Export-ModuleMember -Function Get-ResolvedCredential
'@

    $script:FakeMP = Join-Path $TestDrive 'Manage-Privilege.ps1'
    Set-Content -LiteralPath $script:FakeMP -Encoding UTF8 -Value @'
param($StartProfile, $Category, $Action, $JobFile, $InputFile, $InputJson, $OutputFolder, $FilenameFormat,
      [System.Management.Automation.PSCredential]$Credential, [switch]$WhatIf, $LogLevel, $LogFolder)
$global:FakeMPReceived = @{
    StartProfile = $StartProfile; Category = $Category; Action = $Action; JobFile = $JobFile; OutputFolder = $OutputFolder
    InputFile = $InputFile; WhatIf = [bool]$WhatIf; LogLevel = $LogLevel
    CredentialUser = if ($Credential) { $Credential.UserName } else { $null }
    HasPassword    = [bool]($Credential -and $Credential.Password.Length -gt 0)
}
Write-Output 'fake Manage-Privilege output'
exit 2
'@

    function script:Reset-Fakes {
        $global:FakeResolveCalls = [System.Collections.Generic.List[object]]::new()
        $global:FakeMPReceived   = $null
    }
    function script:Write-Config([string]$Json) {
        $path = Join-Path $TestDrive 'CredentialSources.json'
        Set-Content -LiteralPath $path -Value $Json -Encoding UTF8
        return $path
    }
    $script:GoodConfig = @'
{ "Profiles": { "Prod-SelfHosted": { "Source": "CCP",
    "Params": { "BaseUrl": "https://ccp.example.com", "AppID": "aPePAS", "Safe": "S", "Object": "svc" } } } }
'@
}

AfterAll {
    Remove-Module FakeResolver -ErrorAction SilentlyContinue
    Remove-Variable -Name FakeResolveCalls, FakeMPReceived -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Get-CredentialSourceEntry' {
    BeforeEach { Reset-Fakes; Mock Write-Host { } }

    It 'IW01 - returns Source and Params as a hashtable, matching the profile name case-insensitively' {
        $e = Get-CredentialSourceEntry -Path (Write-Config $script:GoodConfig) -Name 'prod-selfhosted'
        $e.Source           | Should -Be 'CCP'
        $e.Params           | Should -BeOfType [hashtable]
        $e.Params['AppID']  | Should -Be 'aPePAS'
    }

    It 'IW02 - a missing file, bad JSON, no Profiles or no entry each throw a clear error' {
        { Get-CredentialSourceEntry -Path (Join-Path $TestDrive 'none.json') -Name 'X' } | Should -Throw '*not found*'
        { Get-CredentialSourceEntry -Path (Write-Config '{ not json') -Name 'X' }        | Should -Throw '*not valid JSON*'
        { Get-CredentialSourceEntry -Path (Write-Config '{ "Other": {} }') -Name 'X' }  | Should -Throw '*no ''Profiles''*'
        { Get-CredentialSourceEntry -Path (Write-Config $script:GoodConfig) -Name 'Missing' } | Should -Throw '*no entry for profile*'
    }

    It 'IW03 - an unsupported Source (including CurrentUser) is rejected' {
        $cfg = Write-Config '{ "Profiles": { "P": { "Source": "CurrentUser", "Params": {} } } }'
        { Get-CredentialSourceEntry -Path $cfg -Name 'P' } | Should -Throw '*Use one of*'
    }

    It 'IW04 - a secret in Params is refused' {
        $cfg = Write-Config '{ "Profiles": { "P": { "Source": "CP", "Params": { "AppID": "a", "Password": "ThisIsMy_FAKE_Password6!" } } } }'
        { Get-CredentialSourceEntry -Path $cfg -Name 'P' } | Should -Throw '*secret in Params*'
    }
}

Describe 'Get-ManagePrivilegeArguments' {
    BeforeEach { Reset-Fakes; Mock Write-Host { } }

    It 'IW05 - passes the action, the credential and only the optional parameters that were given' {
        $cred = New-Object System.Management.Automation.PSCredential('u', (ConvertTo-SecureString 'ThisIsMy_FAKE_Password6!' -AsPlainText -Force))
        $a = Get-ManagePrivilegeArguments -Credential $cred -Bound @{ ProfileName = 'P'; Category = 'Safes'; Action = 'List'; OutputFolder = 'D:\out'; InputJson = ''; WhatIf = $true }
        $a['StartProfile']        | Should -Be 'P'
        $a['Credential'].UserName | Should -Be 'u'
        $a['OutputFolder']        | Should -Be 'D:\out'
        $a['WhatIf']              | Should -BeTrue
        $a.ContainsKey('InputJson') | Should -BeFalse
        $a.ContainsKey('LogLevel')  | Should -BeFalse
    }

    It 'IW12 - -Verbose passes LogLevel VERBOSE, unless -LogLevel was given' {
        $cred = New-Object System.Management.Automation.PSCredential('u', (ConvertTo-SecureString 'ThisIsMy_FAKE_Password6!' -AsPlainText -Force))
        $a = Get-ManagePrivilegeArguments -Credential $cred -Bound @{ ProfileName = 'P'; Category = 'Safes'; Action = 'List'; Verbose = $true }
        $a['LogLevel'] | Should -Be 'VERBOSE'
        $a.ContainsKey('Verbose') | Should -BeFalse
        $b = Get-ManagePrivilegeArguments -Credential $cred -Bound @{ ProfileName = 'P'; Category = 'Safes'; Action = 'List'; Verbose = $true; LogLevel = 'DEBUG' }
        $b['LogLevel'] | Should -Be 'DEBUG'
    }
}

Describe 'Invoke-AutomationWithCredentialMain' {

    BeforeEach {
        Reset-Fakes
        Mock Write-Host { }
        $script:Bound = @{
            ProfileName = 'Prod-SelfHosted'; Category = 'Safes'; Action = 'List'; OutputFolder = 'D:\out'
            ConfigPath = (Write-Config $script:GoodConfig); APeSecretsPath = $script:FakeSecrets; ManagePrivilegePath = $script:FakeMP
        }
    }

    It 'IW06 - resolves through aPeSecrets, runs Manage-Privilege.ps1 in process with -Credential, and returns its exit code' {
        $code = Invoke-AutomationWithCredentialMain -Bound $script:Bound
        $code | Should -Be 2
        $global:FakeResolveCalls.Count             | Should -Be 1
        $global:FakeResolveCalls[0].Source         | Should -Be 'CCP'
        $global:FakeResolveCalls[0].Params['Safe'] | Should -Be 'S'
        $global:FakeMPReceived.StartProfile        | Should -Be 'Prod-SelfHosted'
        $global:FakeMPReceived.Category            | Should -Be 'Safes'
        $global:FakeMPReceived.OutputFolder        | Should -Be 'D:\out'
        $global:FakeMPReceived.CredentialUser      | Should -Be 'svc-apepas'
        $global:FakeMPReceived.HasPassword         | Should -BeTrue
    }

    It 'IW07 - -ResolveOnly resolves the credential and runs nothing' {
        $script:Bound['ResolveOnly'] = $true
        $script:Bound.Remove('Category'); $script:Bound.Remove('Action')
        Invoke-AutomationWithCredentialMain -Bound $script:Bound | Should -Be 0
        $global:FakeResolveCalls.Count | Should -Be 1
        $global:FakeMPReceived         | Should -BeNullOrEmpty
    }

    It 'IW08 - a source that fails or returns nothing exits 3 without running Manage-Privilege.ps1' {
        $script:Bound['ConfigPath'] = Write-Config '{ "Profiles": { "Prod-SelfHosted": { "Source": "CP", "Params": { "AppID": "a", "Fail": "1" } } } }'
        Invoke-AutomationWithCredentialMain -Bound $script:Bound | Should -Be 3
        $script:Bound['ConfigPath'] = Write-Config '{ "Profiles": { "Prod-SelfHosted": { "Source": "CP", "Params": { "AppID": "a", "ReturnNull": "1" } } } }'
        Invoke-AutomationWithCredentialMain -Bound $script:Bound | Should -Be 3
        $global:FakeMPReceived | Should -BeNullOrEmpty
    }

    It 'IW09 - missing -Category/-Action, a missing aPeSecrets, or a missing Manage-Privilege.ps1 exits 3' {
        $b = $script:Bound.Clone(); $b.Remove('Action')
        Invoke-AutomationWithCredentialMain -Bound $b | Should -Be 3
        $b = $script:Bound.Clone(); $b['APeSecretsPath'] = Join-Path $TestDrive 'nope.psm1'
        Invoke-AutomationWithCredentialMain -Bound $b | Should -Be 3
        $b = $script:Bound.Clone(); $b['ManagePrivilegePath'] = Join-Path $TestDrive 'nope.ps1'
        Invoke-AutomationWithCredentialMain -Bound $b | Should -Be 3
        $global:FakeMPReceived | Should -BeNullOrEmpty
    }

    It 'IW10 - never writes the password to the console' {
        $script:Seen = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Seen.Add("$Object") }
        Invoke-AutomationWithCredentialMain -Bound $script:Bound | Out-Null
        ($script:Seen -join "`n") | Should -Not -Match 'ThisIsMy_FAKE_Password6!'
        ($script:Seen -join "`n") | Should -Match 'svc-apepas'
    }

    It 'IW11 - -JobFile is passed through instead of -Category/-Action, and can''t be combined with them' {
        $b = $script:Bound.Clone(); $b.Remove('Category'); $b.Remove('Action'); $b['JobFile'] = 'D:\Jobs\nightly.json'
        Invoke-AutomationWithCredentialMain -Bound $b | Should -Be 2
        $global:FakeMPReceived.JobFile  | Should -Be 'D:\Jobs\nightly.json'
        $global:FakeMPReceived.Category | Should -BeNullOrEmpty
        $global:FakeMPReceived = $null
        $b['Category'] = 'Safes'
        Invoke-AutomationWithCredentialMain -Bound $b | Should -Be 3
        $global:FakeMPReceived | Should -BeNullOrEmpty
    }
}