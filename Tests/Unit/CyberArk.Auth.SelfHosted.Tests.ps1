#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for Auth\CyberArk.Auth.SelfHosted.psm1 - the -NoPrompt guard added for
    Testing-Plan.md K06 (Invoke-SelfHostedPasswordAuth falling back to an interactive
    Get-Credential prompt during an unattended automation-mode refresh).

.DESCRIPTION
    Invoke-SelfHostedPasswordAuth itself is a private function (not in the module's
    Export-ModuleMember list), so it's exercised here only indirectly, through the public
    Update-SelfHostedAuthToken - the same call path automation mode actually uses. Every other
    auth method (Shared, PKI/PKIPN, SAML, OIDC) requires a live server, a certificate store, or a
    WebView2 browser window and is exercised manually/live instead (see Testing-Plan.md),
    matching this module's existing, documented testing boundary. This is the first automated
    coverage this module has ever had (mirroring CyberArk.Auth.ISPSS.Tests.ps1, added for Finding
    F36). Mocks target -ModuleName 'CyberArk.Auth.SelfHosted' since Get-Credential/
    Invoke-PVWALogon are called from inside that real .psm1 module, not from this test file's
    own scope.
#>

BeforeAll {
    $script:CommonPath     = Join-Path $PSScriptRoot '..\..\Auth\CyberArk.Auth.Common.psm1'
    $script:SelfHostedPath = Join-Path $PSScriptRoot '..\..\Auth\CyberArk.Auth.SelfHosted.psm1'

    Import-Module $script:CommonPath     -Force -ErrorAction Stop
    Import-Module $script:SelfHostedPath -Force -ErrorAction Stop

    $script:PVWAUrl = 'https://pvwa.test.com/PasswordVault'
}

Describe 'Update-SelfHostedAuthToken -NoPrompt' {

    BeforeEach {
        $script:TokenNoCred = [PSCustomObject]@{
            _RefreshContext = @{
                Method = 'CyberArk'; PVWAUrl = $script:PVWAUrl; Credential = $null
                ConcurrentSession = $false; IgnoreSSL = $false
            }
        }
    }

    It 'SH-NP01 - NoPrompt with no stored credential throws immediately without calling Get-Credential' {
        Mock Get-Credential { throw 'Get-Credential should not be called when -NoPrompt is set.' } -ModuleName 'CyberArk.Auth.SelfHosted'

        { Update-SelfHostedAuthToken -TokenObject $script:TokenNoCred -NoPrompt } |
            Should -Throw '*interactive prompting is disabled*'
        Should -Invoke Get-Credential -ModuleName 'CyberArk.Auth.SelfHosted' -Times 0
    }

    It 'SH-NP02 - without NoPrompt, the existing interactive Get-Credential fallback is unchanged' {
        Mock Get-Credential { throw 'SENTINEL_PROMPTED' } -ModuleName 'CyberArk.Auth.SelfHosted'

        { Update-SelfHostedAuthToken -TokenObject $script:TokenNoCred } | Should -Throw '*SENTINEL_PROMPTED*'
    }

    It 'SH-NP03 - a token whose _RefreshContext already has a Credential refreshes normally with NoPrompt set' {
        Mock Get-Credential { throw 'Should not be called - a credential was already present.' } -ModuleName 'CyberArk.Auth.SelfHosted'
        Mock Invoke-PVWALogon { 'fake-cyberark-token' } -ModuleName 'CyberArk.Auth.SelfHosted'
        Mock Get-PVWASessionTimeoutMinutes { 20 } -ModuleName 'CyberArk.Auth.SelfHosted'

        $script:TokenNoCred._RefreshContext['Credential'] =
            [System.Management.Automation.PSCredential]::new('svc-account', (ConvertTo-SecureString 'pw123!' -AsPlainText -Force))

        { Update-SelfHostedAuthToken -TokenObject $script:TokenNoCred -NoPrompt } | Should -Not -Throw
        Should -Invoke Get-Credential -ModuleName 'CyberArk.Auth.SelfHosted' -Times 0
    }

    It 'SH-NP04 - NoPrompt is scoped to CyberArk/LDAP/RADIUS only - Shared needs no credential either way' {
        Mock Invoke-PVWALogon { 'fake-shared-token' } -ModuleName 'CyberArk.Auth.SelfHosted'
        Mock Get-PVWASessionTimeoutMinutes { 20 } -ModuleName 'CyberArk.Auth.SelfHosted'

        $sharedToken = [PSCustomObject]@{
            _RefreshContext = @{ Method = 'Shared'; PVWAUrl = $script:PVWAUrl; ConcurrentSession = $false; IgnoreSSL = $false }
        }

        { Update-SelfHostedAuthToken -TokenObject $sharedToken -NoPrompt } | Should -Not -Throw
    }
}
