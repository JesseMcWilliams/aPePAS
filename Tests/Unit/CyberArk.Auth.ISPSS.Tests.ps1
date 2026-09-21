#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for Auth\CyberArk.Auth.ISPSS.psm1 - ClientCredentials response parsing.

.DESCRIPTION
    Only the ClientCredentials path is covered here - Interactive and SSO require a live
    challenge/response loop or a WebView2 browser window and are exercised manually/live
    instead (see Testing-Plan.md). Invoke-RestMethod is fully mocked; no network access required.
    Mocks target -ModuleName 'CyberArk.Auth.ISPSS' since Invoke-RestMethod is called from inside
    that real .psm1 module, not from this test file's own scope.
#>

BeforeAll {
    $script:CommonPath = Join-Path $PSScriptRoot '..\..\Auth\CyberArk.Auth.Common.psm1'
    $script:ISPSSPath  = Join-Path $PSScriptRoot '..\..\Auth\CyberArk.Auth.ISPSS.psm1'

    Import-Module $script:CommonPath -Force -ErrorAction Stop
    Import-Module $script:ISPSSPath  -Force -ErrorAction Stop

    $script:IdentityURL = 'https://acme.id.cyberark.cloud'
    $script:BaseURL     = 'https://acme.privilegecloud.cyberark.cloud/PasswordVault'

    function script:New-PlatformTokenResponse {
        # Matches the documented response shape exactly (C:\Code\References\CyberArk ISPSS\
        # API Token\Create an API token _ Create an API token.md) - no refresh_token field.
        param([string]$AccessToken = 'eyJ-fake-access-token', [int]$ExpiresIn = 900)
        [PSCustomObject]@{
            access_token = $AccessToken
            token_type   = 'Bearer'
            expires_in   = $ExpiresIn
        }
    }
}

Describe 'Get-ISPSSAuthToken - ClientCredentials' {

    BeforeEach {
        Mock Invoke-RestMethod { script:New-PlatformTokenResponse } -ModuleName 'CyberArk.Auth.ISPSS'
    }

    It 'ISPSS-CC01 - does not throw when the response has no refresh_token field (the documented shape)' {
        {
            Get-ISPSSAuthToken -AuthMethod 'ClientCredentials' -PCloudSubdomain 'acme' `
                -IdentityTenantURL $script:IdentityURL -ClientId 'svc-account' `
                -ClientSecret (ConvertTo-SecureString 'secret123!' -AsPlainText -Force)
        } | Should -Not -Throw
    }

    It 'ISPSS-CC02 - Token/RefreshToken/Expiry are set correctly from the response' {
        $token = Get-ISPSSAuthToken -AuthMethod 'ClientCredentials' -PCloudSubdomain 'acme' `
            -IdentityTenantURL $script:IdentityURL -ClientId 'svc-account' `
            -ClientSecret (ConvertTo-SecureString 'secret123!' -AsPlainText -Force)

        $token.Token        | Should -Be 'eyJ-fake-access-token'
        $token.SystemType   | Should -Be 'ISPSS'
        $token.AuthMethod   | Should -Be 'ClientCredentials'
        $token.RefreshToken | Should -BeNullOrEmpty
    }

    It 'ISPSS-CC03 - POSTs to {IdentityURL}/oauth2/platformtoken with grant_type=client_credentials' {
        Get-ISPSSAuthToken -AuthMethod 'ClientCredentials' -PCloudSubdomain 'acme' `
            -IdentityTenantURL $script:IdentityURL -ClientId 'svc-account' `
            -ClientSecret (ConvertTo-SecureString 'secret123!' -AsPlainText -Force) | Out-Null

        Should -Invoke Invoke-RestMethod -ModuleName 'CyberArk.Auth.ISPSS' -Times 1 -ParameterFilter {
            $Uri -eq "$($script:IdentityURL)/oauth2/platformtoken" -and $Method -eq 'POST'
        }
    }

    It 'ISPSS-CC04 - still works if the response does include a refresh_token (defensive, not just the documented shape)' {
        Mock Invoke-RestMethod {
            $r = script:New-PlatformTokenResponse
            $r | Add-Member -NotePropertyName 'refresh_token' -NotePropertyValue 'a-refresh-token'
            $r
        } -ModuleName 'CyberArk.Auth.ISPSS'
        $token = Get-ISPSSAuthToken -AuthMethod 'ClientCredentials' -PCloudSubdomain 'acme' `
            -IdentityTenantURL $script:IdentityURL -ClientId 'svc-account' `
            -ClientSecret (ConvertTo-SecureString 'secret123!' -AsPlainText -Force)

        $token.RefreshToken | Should -Be 'a-refresh-token'
    }

    It 'ISPSS-CC05 - falls back to a 3600s expiry if expires_in is absent from the response' {
        Mock Invoke-RestMethod { [PSCustomObject]@{ access_token = 'tok' } } -ModuleName 'CyberArk.Auth.ISPSS'
        $before = [DateTime]::UtcNow
        $token = Get-ISPSSAuthToken -AuthMethod 'ClientCredentials' -PCloudSubdomain 'acme' `
            -IdentityTenantURL $script:IdentityURL -ClientId 'svc-account' `
            -ClientSecret (ConvertTo-SecureString 'secret123!' -AsPlainText -Force)

        $token.Expiry | Should -BeGreaterThan $before.AddSeconds(3500)
        $token.Expiry | Should -BeLessThan $before.AddSeconds(3700)
    }
}

Describe 'Update-ISPSSAuthToken - ClientCredentials refresh' {

    It 'ISPSS-CC06 - RefreshToken is empty (per the documented response shape), so refresh falls straight through to a full re-authentication' {
        Mock Invoke-RestMethod { script:New-PlatformTokenResponse -AccessToken 'second-token' } -ModuleName 'CyberArk.Auth.ISPSS'

        $original = Get-ISPSSAuthToken -AuthMethod 'ClientCredentials' -PCloudSubdomain 'acme' `
            -IdentityTenantURL $script:IdentityURL -ClientId 'svc-account' `
            -ClientSecret (ConvertTo-SecureString 'secret123!' -AsPlainText -Force)

        { Update-ISPSSAuthToken -TokenObject $original } | Should -Not -Throw
        $refreshed = Update-ISPSSAuthToken -TokenObject $original
        $refreshed.Token | Should -Be 'second-token'
    }
}

Describe 'Get-ISPSSAuthToken / Update-ISPSSAuthToken - Interactive (Testing-Plan.md K12)' {
    <#
        Confirms the K12 fix: a fresh Interactive login (no MFA beyond a single UP/password
        mechanism) captures a usable Credential into _RefreshContext even when the password was
        typed at a prompt rather than supplied programmatically, and Update-ISPSSAuthToken
        -NoPrompt can then silently reuse it - failing cleanly instead of prompting whenever that
        isn't possible (no credential, or a real second factor is required).
    #>

    BeforeAll {
        function script:New-StartAuthResponse {
            param([array]$Mechanisms = @(@{ Name = 'UP'; AnswerType = 'Text'; MechanismId = 'MECH-UP'; PromptSelectMech = 'Password:'; PromptMechChosen = 'Password' }))
            [PSCustomObject]@{
                success = $true
                Result  = [PSCustomObject]@{
                    TenantId   = 'TENANT1'
                    SessionId  = 'SESSION1'
                    Challenges = @([PSCustomObject]@{ Mechanisms = $Mechanisms | ForEach-Object { [PSCustomObject]$_ } })
                }
            }
        }
        function script:New-AdvanceAuthResponse {
            param([string]$Token = 'fresh-interactive-token')
            [PSCustomObject]@{ success = $true; Result = [PSCustomObject]@{ Token = $Token } }
        }
    }

    BeforeEach {
        Mock Get-PVWASessionTimeoutMinutes { 30 } -ModuleName 'CyberArk.Auth.ISPSS'
    }

    It 'ISPSS-INT01 - a fresh login with a single UP mechanism and no -Credential still captures one into _RefreshContext' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*StartAuthentication*') { script:New-StartAuthResponse }
            else { script:New-AdvanceAuthResponse }
        } -ModuleName 'CyberArk.Auth.ISPSS'
        Mock Read-Host { ConvertTo-SecureString 'typed-password' -AsPlainText -Force } -ModuleName 'CyberArk.Auth.ISPSS' -ParameterFilter { $AsSecureString }

        $token = Get-ISPSSAuthToken -AuthMethod 'Interactive' -PCloudSubdomain 'acme' `
            -IdentityTenantURL $script:IdentityURL -Username 'jdoe'

        $token.Token | Should -Be 'fresh-interactive-token'
        $token._RefreshContext['Credential']                            | Should -Not -BeNullOrEmpty
        $token._RefreshContext['Credential'].UserName                   | Should -Be 'jdoe'
        $token._RefreshContext['Credential'].GetNetworkCredential().Password | Should -Be 'typed-password'
    }

    It 'ISPSS-INT02 - Update-ISPSSAuthToken -NoPrompt refreshes silently when _RefreshContext already has a Credential and only a single UP mechanism is required' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*StartAuthentication*') { script:New-StartAuthResponse }
            else { script:New-AdvanceAuthResponse -Token 'refreshed-token' }
        } -ModuleName 'CyberArk.Auth.ISPSS'
        Mock Read-Host { throw 'Read-Host must not be called under -NoPrompt.' } -ModuleName 'CyberArk.Auth.ISPSS'

        $tokenObject = [PSCustomObject]@{
            _RefreshContext = @{
                Method = 'Interactive'; IdentityURL = $script:IdentityURL; PCloudSubdomain = 'acme'
                BaseURL = $script:BaseURL; Username = 'jdoe'
                Credential = [System.Management.Automation.PSCredential]::new('jdoe', (ConvertTo-SecureString 'stored-password' -AsPlainText -Force))
            }
        }

        $refreshed = Update-ISPSSAuthToken -TokenObject $tokenObject -NoPrompt
        $refreshed.Token | Should -Be 'refreshed-token'
    }

    It 'ISPSS-INT03 - Update-ISPSSAuthToken -NoPrompt fails cleanly (no Read-Host) when _RefreshContext has no Credential' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*StartAuthentication*') { script:New-StartAuthResponse }
            else { script:New-AdvanceAuthResponse }
        } -ModuleName 'CyberArk.Auth.ISPSS'
        Mock Read-Host { throw 'Read-Host must not be called under -NoPrompt.' } -ModuleName 'CyberArk.Auth.ISPSS'

        $tokenObject = [PSCustomObject]@{
            _RefreshContext = @{
                Method = 'Interactive'; IdentityURL = $script:IdentityURL; PCloudSubdomain = 'acme'
                BaseURL = $script:BaseURL; Username = 'jdoe'; Credential = $null
            }
        }

        { Update-ISPSSAuthToken -TokenObject $tokenObject -NoPrompt } | Should -Throw
        Should -Invoke Read-Host -ModuleName 'CyberArk.Auth.ISPSS' -Times 0
    }

    It 'ISPSS-INT04 - Update-ISPSSAuthToken -NoPrompt fails cleanly (no Read-Host) when the required mechanism is not a password ("UP") at all, even with a stored Credential' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*StartAuthentication*') {
                # A single required mechanism that is NOT 'UP' - e.g. an OTP-only policy. A stored
                # password Credential cannot silently answer this, unlike the UP case in ISPSS-INT02.
                script:New-StartAuthResponse -Mechanisms @(
                    @{ Name = 'OTP'; AnswerType = 'Text'; MechanismId = 'MECH-OTP'; PromptSelectMech = 'Code:'; PromptMechChosen = 'One-time code' }
                )
            } else { script:New-AdvanceAuthResponse }
        } -ModuleName 'CyberArk.Auth.ISPSS'
        Mock Read-Host { throw 'Read-Host must not be called under -NoPrompt.' } -ModuleName 'CyberArk.Auth.ISPSS'

        $tokenObject = [PSCustomObject]@{
            _RefreshContext = @{
                Method = 'Interactive'; IdentityURL = $script:IdentityURL; PCloudSubdomain = 'acme'
                BaseURL = $script:BaseURL; Username = 'jdoe'
                Credential = [System.Management.Automation.PSCredential]::new('jdoe', (ConvertTo-SecureString 'stored-password' -AsPlainText -Force))
            }
        }

        { Update-ISPSSAuthToken -TokenObject $tokenObject -NoPrompt } | Should -Throw
        Should -Invoke Read-Host -ModuleName 'CyberArk.Auth.ISPSS' -Times 0
    }

    It 'ISPSS-INT05 - without -NoPrompt, a fresh login still prompts as before (backward compatible)' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*StartAuthentication*') { script:New-StartAuthResponse }
            else { script:New-AdvanceAuthResponse }
        } -ModuleName 'CyberArk.Auth.ISPSS'
        Mock Read-Host { ConvertTo-SecureString 'typed-password' -AsPlainText -Force } -ModuleName 'CyberArk.Auth.ISPSS' -ParameterFilter { $AsSecureString }

        { Get-ISPSSAuthToken -AuthMethod 'Interactive' -PCloudSubdomain 'acme' -IdentityTenantURL $script:IdentityURL -Username 'jdoe' } | Should -Not -Throw
        Should -Invoke Read-Host -ModuleName 'CyberArk.Auth.ISPSS' -Times 1
    }
}
