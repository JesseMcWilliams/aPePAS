#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for Auth\CyberArk.Auth.SelfHosted.psm1 - the -NoPrompt guard added for
    Testing_Findings-and-Known-Issues.md K06 (Invoke-SelfHostedPasswordAuth falling back to an interactive
    Get-Credential prompt during an unattended automation-mode refresh).

.DESCRIPTION
    Invoke-SelfHostedPasswordAuth itself is a private function (not in the module's
    Export-ModuleMember list), so it's exercised here only indirectly, through the public
    Update-SelfHostedAuthToken - the same call path automation mode actually uses. Every other
    auth method (Shared, PKI/PKIPN, SAML, OIDC) requires a live server, a certificate store, or a
    WebView2 browser window and is exercised manually/live instead (see Testing_Plan.md),
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

Describe 'Get-SelfHostedAuthToken - SAML forwards -IgnoreSSL to Invoke-WebView2Window; OIDC is refused (Testing_Findings-and-Known-Issues.md K03)' {
    <#
        Confirms the actual K03 fix: Invoke-SelfHostedSAML/Invoke-SelfHostedOIDC previously
        accepted -IgnoreSSL but silently dropped it at their Invoke-WebView2Window call site
        (only ever forwarding it to the unrelated follow-up Get-PVWASessionTimeoutMinutes call).
        Invoke-WebView2Window itself - the actual WebView2/CoreWebView2 control - requires a live
        WinForms/STA runspace and is exercised manually/live instead (see Testing_Plan.md), matching
        this module's existing testing boundary; only the parameter-forwarding is unit-tested here.
    #>

    BeforeEach {
        Mock Import-WebView2Assembly { } -ModuleName 'CyberArk.Auth.SelfHosted'
        Mock Get-PVWASessionTimeoutMinutes { 20 } -ModuleName 'CyberArk.Auth.SelfHosted'
        # SAML (F102) starts with a form POST to PVWA and expects the window to return the IdP's form fields.
        Mock Invoke-PVWAFormPost { if ($Fields.Count -eq 0) { 'https://idp.test/sso?SAMLRequest=x' } else { 'fake-token' } } -ModuleName 'CyberArk.Auth.SelfHosted'
        Mock Invoke-WebView2Window { @{ Token = 'fake-token'; TokenType = 'CyberArkSession'; FormFields = @{ SAMLResponse = 'PHNhbWw+' } } } -ModuleName 'CyberArk.Auth.SelfHosted'
    }

    It 'SH-SSL01 - SAML forwards -IgnoreSSL through to Invoke-WebView2Window when set' {
        Get-SelfHostedAuthToken -AuthMethod 'SAML' -PVWAUrl $script:PVWAUrl -IgnoreSSL | Out-Null

        Should -Invoke Invoke-WebView2Window -ModuleName 'CyberArk.Auth.SelfHosted' -Times 1 -ParameterFilter {
            $IgnoreSSL -eq $true
        }
    }

    It 'SH-SSL02 - SAML does not set IgnoreSSL on Invoke-WebView2Window when not requested' {
        Get-SelfHostedAuthToken -AuthMethod 'SAML' -PVWAUrl $script:PVWAUrl | Out-Null

        Should -Invoke Invoke-WebView2Window -ModuleName 'CyberArk.Auth.SelfHosted' -Times 1 -ParameterFilter {
            -not $IgnoreSSL
        }
    }

    It 'SH-SSL03 - OIDC is refused with a clear message and opens no window (F103)' {
        { Get-SelfHostedAuthToken -AuthMethod 'OIDC' -PVWAUrl $script:PVWAUrl -IgnoreSSL } | Should -Throw "*OIDC sign-in isn't supported on Self-Hosted*"
        Should -Invoke Invoke-WebView2Window -ModuleName 'CyberArk.Auth.SelfHosted' -Times 0
    }

    It 'SH-SSL04 - a saved OIDC token refresh is refused with the same message, and OIDC is not in the method list (F103)' {
        $old = [PSCustomObject]@{ _RefreshContext = @{ Method = 'OIDC'; PVWAUrl = $script:PVWAUrl; WebView2AssemblyPath = $null; IgnoreSSL = $false } }
        { Update-SelfHostedAuthToken -TokenObject $old } | Should -Throw "*OIDC sign-in isn't supported on Self-Hosted*"
        Should -Invoke Invoke-WebView2Window -ModuleName 'CyberArk.Auth.SelfHosted' -Times 0
        $driver = Get-Content (Join-Path $PSScriptRoot '..\..\Driver\Driver.ProfileUI.ps1') -Raw
        $driver | Should -Match "selfHostedAuthMethods = @\('CyberArk', 'LDAP', 'RADIUS', 'SAML', 'Shared', 'PKI', 'PKIPN'\)"
    }
}

Describe 'Get-SelfHostedAuthToken - SP-initiated SAML (F102)' {
    BeforeEach {
        Mock Import-WebView2Assembly { } -ModuleName 'CyberArk.Auth.SelfHosted'
        Mock Get-PVWASessionTimeoutMinutes { 20 } -ModuleName 'CyberArk.Auth.SelfHosted'
        Mock Invoke-PVWAFormPost { if ($Fields.Count -eq 0) { 'https://idp.test/sso?SAMLRequest=x' } else { 'saml-token' } } -ModuleName 'CyberArk.Auth.SelfHosted'
        Mock Invoke-WebView2Window { @{ FormFields = @{ SAMLResponse = 'PHNhbWw+'; RelayState = '' } } } -ModuleName 'CyberArk.Auth.SelfHosted'
    }

    It 'SH-SAML01 - asks PVWA for the IdP URL, opens it, then posts the caught SAMLResponse with apiUse=true' {
        $tok = Get-SelfHostedAuthToken -AuthMethod 'SAML' -PVWAUrl $script:PVWAUrl
        $tok.Token | Should -Be 'saml-token'
        $tok.Headers['Authorization'] | Should -Be 'saml-token'
        Should -Invoke Invoke-PVWAFormPost -ModuleName 'CyberArk.Auth.SelfHosted' -Times 1 -Exactly -ParameterFilter {
            $Url -eq "$script:PVWAUrl/api/auth/saml/logon" -and $Fields.Count -eq 0
        }
        Should -Invoke Invoke-WebView2Window -ModuleName 'CyberArk.Auth.SelfHosted' -Times 1 -Exactly -ParameterFilter {
            $NavigateUrl -eq 'https://idp.test/sso?SAMLRequest=x' -and $CapturePostPathSuffix -eq '/api/auth/saml/logon'
        }
        Should -Invoke Invoke-PVWAFormPost -ModuleName 'CyberArk.Auth.SelfHosted' -Times 1 -Exactly -ParameterFilter {
            $Fields['SAMLResponse'] -eq 'PHNhbWw+' -and $Fields['apiUse'] -eq 'true' -and -not $Fields.ContainsKey('concurrentSession')
        }
    }

    It 'SH-SAML02 - -ConcurrentSession is sent with the SAMLResponse and kept for the refresh' {
        $tok = Get-SelfHostedAuthToken -AuthMethod 'SAML' -PVWAUrl $script:PVWAUrl -ConcurrentSession
        Should -Invoke Invoke-PVWAFormPost -ModuleName 'CyberArk.Auth.SelfHosted' -Times 1 -Exactly -ParameterFilter { $Fields['concurrentSession'] -eq 'true' }
        $tok._RefreshContext['ConcurrentSession'] | Should -BeTrue
    }

    It 'SH-SAML03 - no IdP URL from PVWA fails before any window opens' {
        Mock Invoke-PVWAFormPost { 'not a url' } -ModuleName 'CyberArk.Auth.SelfHosted'
        { Get-SelfHostedAuthToken -AuthMethod 'SAML' -PVWAUrl $script:PVWAUrl } | Should -Throw '*did not return an identity provider URL*'
        Should -Invoke Invoke-WebView2Window -ModuleName 'CyberArk.Auth.SelfHosted' -Times 0
    }

    It 'SH-SAML04 - a window result with no SAMLResponse fails without the logon POST' {
        Mock Invoke-WebView2Window { @{ FormFields = @{ RelayState = 'x' } } } -ModuleName 'CyberArk.Auth.SelfHosted'
        { Get-SelfHostedAuthToken -AuthMethod 'SAML' -PVWAUrl $script:PVWAUrl } | Should -Throw '*did not send a SAMLResponse*'
        Should -Invoke Invoke-PVWAFormPost -ModuleName 'CyberArk.Auth.SelfHosted' -Times 1 -Exactly
    }

    It 'SH-SAML05 - a token saved before F102 (no ConcurrentSession in its refresh context) still refreshes' {
        $old = [PSCustomObject]@{ _RefreshContext = @{ Method = 'SAML'; PVWAUrl = $script:PVWAUrl; WebView2AssemblyPath = $null; IgnoreSSL = $false } }
        (Update-SelfHostedAuthToken -TokenObject $old).Token | Should -Be 'saml-token'
    }
}