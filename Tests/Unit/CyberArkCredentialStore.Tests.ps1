#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for CyberArkCredentialStore.psm1.
    No CyberArk connection required.
#>

BeforeAll {
    $script:CredStorePath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkCredentialStore.psm1'
    Import-Module $script:CredStorePath -Force -ErrorAction Stop

    $script:TempDir = Join-Path $env:TEMP "CyberArkCredentialStoreTests_$(Get-Random)"
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null
}

AfterAll {
    if ($script:TempDir -and (Test-Path $script:TempDir)) {
        Remove-Item -Recurse -Force $script:TempDir -ErrorAction SilentlyContinue
    }
}

Describe 'CyberArkCredentialStore - Get-ProfileCredentialPath' {
    It 'CS01 - builds a .autocred path under the given ProfileDir' {
        $path = Get-ProfileCredentialPath -Name 'SomeProfile' -ProfileDir $script:TempDir
        $path | Should -Be (Join-Path $script:TempDir 'SomeProfile.autocred')
    }
}

Describe 'CyberArkCredentialStore - Save-ProfileCredential / Get-ProfileCredential / Remove-ProfileCredential' {

    AfterEach {
        Remove-ProfileCredential -Name 'CredTestProfile' -ProfileDir $script:TempDir
    }

    It 'CS02 - Get-ProfileCredential returns null when nothing is stored' {
        Get-ProfileCredential -Name 'CredTestProfile' -ProfileDir $script:TempDir | Should -BeNullOrEmpty
    }

    It 'CS03 - Save-ProfileCredential then Get-ProfileCredential round-trips the username and password' {
        $cred = [System.Management.Automation.PSCredential]::new('svc-account', (ConvertTo-SecureString 'p@ssw0rd!' -AsPlainText -Force))
        Save-ProfileCredential -Name 'CredTestProfile' -Credential $cred -ProfileDir $script:TempDir | Out-Null

        $loaded = Get-ProfileCredential -Name 'CredTestProfile' -ProfileDir $script:TempDir

        $loaded.UserName                       | Should -Be 'svc-account'
        $loaded.GetNetworkCredential().Password | Should -Be 'p@ssw0rd!'
    }

    It 'CS04 - Save-ProfileCredential returns the saved file path' {
        $cred = [System.Management.Automation.PSCredential]::new('svc-account', (ConvertTo-SecureString 'pw' -AsPlainText -Force))
        $returned = Save-ProfileCredential -Name 'CredTestProfile' -Credential $cred -ProfileDir $script:TempDir

        $returned | Should -Be (Get-ProfileCredentialPath -Name 'CredTestProfile' -ProfileDir $script:TempDir)
        Test-Path -LiteralPath $returned | Should -Be $true
    }

    It 'CS05 - Get-ProfileCredential returns null (not a throw) for a file that cannot be deserialized' {
        $path = Get-ProfileCredentialPath -Name 'CredTestProfile' -ProfileDir $script:TempDir
        Set-Content -LiteralPath $path -Value 'not a real Clixml credential file'

        { Get-ProfileCredential -Name 'CredTestProfile' -ProfileDir $script:TempDir } | Should -Not -Throw
        Get-ProfileCredential -Name 'CredTestProfile' -ProfileDir $script:TempDir | Should -BeNullOrEmpty
    }

    It 'CS06 - Remove-ProfileCredential deletes the file' {
        $cred = [System.Management.Automation.PSCredential]::new('svc-account', (ConvertTo-SecureString 'pw' -AsPlainText -Force))
        Save-ProfileCredential -Name 'CredTestProfile' -Credential $cred -ProfileDir $script:TempDir | Out-Null

        Remove-ProfileCredential -Name 'CredTestProfile' -ProfileDir $script:TempDir

        Test-Path -LiteralPath (Get-ProfileCredentialPath -Name 'CredTestProfile' -ProfileDir $script:TempDir) | Should -Be $false
    }

    It 'CS07 - Remove-ProfileCredential on a profile with none stored does not throw' {
        { Remove-ProfileCredential -Name 'CredTestProfile' -ProfileDir $script:TempDir } | Should -Not -Throw
    }

    It 'CS08 - two different profile names in the same ProfileDir do not collide' {
        $credA = [System.Management.Automation.PSCredential]::new('user-a', (ConvertTo-SecureString 'pw-a' -AsPlainText -Force))
        $credB = [System.Management.Automation.PSCredential]::new('user-b', (ConvertTo-SecureString 'pw-b' -AsPlainText -Force))
        Save-ProfileCredential -Name 'CredTestProfile'   -Credential $credA -ProfileDir $script:TempDir | Out-Null
        Save-ProfileCredential -Name 'CredTestProfileTwo' -Credential $credB -ProfileDir $script:TempDir | Out-Null

        (Get-ProfileCredential -Name 'CredTestProfile'    -ProfileDir $script:TempDir).UserName | Should -Be 'user-a'
        (Get-ProfileCredential -Name 'CredTestProfileTwo' -ProfileDir $script:TempDir).UserName | Should -Be 'user-b'

        Remove-ProfileCredential -Name 'CredTestProfileTwo' -ProfileDir $script:TempDir
    }
}
