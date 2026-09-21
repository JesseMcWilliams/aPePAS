#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CyberArk.Auth.Common.psm1') -Force -Global

#region Constants

# Fallback only - used when the server's actual configured idle timeout cannot be
# retrieved (older PVWA without /api/Settings/Timeout, or the request fails for any
# reason). See Get-PVWASessionTimeoutMinutes, which queries the real value.
$script:PVWA_SESSION_EXPIRY_MIN = 20

$script:PVWA_LOGON_PATHS = @{
    CyberArk = '/API/auth/CyberArk/Logon'
    LDAP     = '/API/auth/LDAP/Logon'
    RADIUS   = '/API/auth/RADIUS/Logon'
    Shared   = '/API/auth/Shared/Logon'
    PKI      = '/API/auth/PKI/Logon'
    PKIPN    = '/API/auth/PKIPN/Logon'
}

#endregion

#region Self-Hosted Authentication Methods (private)

function Invoke-PVWALogon {
    param(
        [string]$Url,
        [string]$Body,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [switch]$IgnoreSSL
    )
    $params = @{
        Uri         = $Url
        Method      = 'POST'
        Headers     = @{ 'Content-Type' = 'application/json' }
        # Encode as raw UTF8 bytes rather than a String so PowerShell's own ParameterBinding/
        # module logging (e.g. GPO-enabled Module Logging / Script Block Logging) records a
        # non-revealing System.Byte[] type name instead of the literal request content - which
        # for every one of these logon methods includes the plaintext vault password. Mirrors
        # psPAS's New-PASSession.ps1 / Invoke-PASRestMethod.ps1.
        Body        = [System.Text.Encoding]::UTF8.GetBytes($Body)
        ErrorAction = 'Stop'
    }
    if ($Certificate) { $params.Certificate = $Certificate }
    if ($IgnoreSSL) {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $params.SkipCertificateCheck = $true
        } else {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
    }
    $result = Invoke-RestMethod @params
    return $result.ToString().Trim('"')
}

function Invoke-SelfHostedPasswordAuth {
    param(
        [string]$PVWAUrl,
        [string]$AuthMethod,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$Username,
        [switch]$ConcurrentSession,
        [switch]$IgnoreSSL,

        # Set by an automated (unattended) caller - see Manage-Privilege.ps1's
        # Use-StoredCredentialIfMissing and Testing-Plan.md K06. Automated runs must never fall
        # back to an interactive prompt: a missing credential is a clean, immediate failure
        # instead, not a hang waiting for console input that will never come.
        [switch]$NoPrompt
    )

    if (-not $Credential) {
        if ($NoPrompt.IsPresent) {
            throw "No credential available for $AuthMethod authentication and interactive prompting is disabled (automation mode). Store a credential for this profile first (profile detail menu's [A] action)."
        }
        $credParams = @{ Message = "Enter credentials for CyberArk $AuthMethod authentication" }
        if ($Username) { $credParams['UserName'] = $Username }
        $Credential = Get-Credential @credParams
    }

    $body = @{
        username          = $Credential.UserName
        password          = $Credential.GetNetworkCredential().Password
        concurrentSession = $ConcurrentSession.IsPresent
    } | ConvertTo-Json

    $logonUrl = "$PVWAUrl$($script:PVWA_LOGON_PATHS[$AuthMethod])"
    Write-Verbose "Authenticating via $AuthMethod at: $logonUrl"
    try {
        $token = Invoke-PVWALogon -Url $logonUrl -Body $body -IgnoreSSL:$IgnoreSSL
    } catch {
        throw "$AuthMethod authentication failed at '$logonUrl': $_"
    }

    $expiryMin = Get-PVWASessionTimeoutMinutes -PVWAUrl $PVWAUrl -Token $token -IgnoreSSL:$IgnoreSSL
    if (-not $expiryMin) { $expiryMin = $script:PVWA_SESSION_EXPIRY_MIN }

    New-AuthTokenObject `
        -Token        $token `
        -TokenType    'CyberArkSession' `
        -Headers      @{ Authorization = $token; 'Content-Type' = 'application/json' } `
        -Expiry       ([DateTime]::UtcNow.AddMinutes($expiryMin)) `
        -RefreshToken $null `
        -SystemType   'SelfHosted' `
        -AuthMethod   $AuthMethod `
        -BaseURL      $PVWAUrl `
        -IdentityURL  $null `
        -TenantId     $null `
        -RefreshContext @{
            Method            = $AuthMethod
            PVWAUrl           = $PVWAUrl
            Credential        = $Credential
            ConcurrentSession = $ConcurrentSession.IsPresent
            IgnoreSSL         = $IgnoreSSL.IsPresent
        }
}

function Invoke-SelfHostedShared {
    param(
        [string]$PVWAUrl,
        [switch]$ConcurrentSession,
        [switch]$IgnoreSSL
    )

    $body     = @{ concurrentSession = $ConcurrentSession.IsPresent } | ConvertTo-Json
    $logonUrl = "$PVWAUrl$($script:PVWA_LOGON_PATHS['Shared'])"
    Write-Verbose "Authenticating via Shared at: $logonUrl"
    try {
        $token = Invoke-PVWALogon -Url $logonUrl -Body $body -IgnoreSSL:$IgnoreSSL
    } catch {
        throw "Shared authentication failed at '$logonUrl': $_"
    }

    $expiryMin = Get-PVWASessionTimeoutMinutes -PVWAUrl $PVWAUrl -Token $token -IgnoreSSL:$IgnoreSSL
    if (-not $expiryMin) { $expiryMin = $script:PVWA_SESSION_EXPIRY_MIN }

    New-AuthTokenObject `
        -Token        $token `
        -TokenType    'CyberArkSession' `
        -Headers      @{ Authorization = $token; 'Content-Type' = 'application/json' } `
        -Expiry       ([DateTime]::UtcNow.AddMinutes($expiryMin)) `
        -RefreshToken $null `
        -SystemType   'SelfHosted' `
        -AuthMethod   'Shared' `
        -BaseURL      $PVWAUrl `
        -IdentityURL  $null `
        -TenantId     $null `
        -RefreshContext @{
            Method            = 'Shared'
            PVWAUrl           = $PVWAUrl
            ConcurrentSession = $ConcurrentSession.IsPresent
            IgnoreSSL         = $IgnoreSSL.IsPresent
        }
}

function Invoke-SelfHostedPKI {
    param(
        [string]$PVWAUrl,
        [string]$AuthMethod,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [switch]$ConcurrentSession,
        [switch]$IgnoreSSL
    )

    $body     = @{ concurrentSession = $ConcurrentSession.IsPresent } | ConvertTo-Json
    $logonUrl = "$PVWAUrl$($script:PVWA_LOGON_PATHS[$AuthMethod])"
    Write-Verbose "Authenticating via $AuthMethod at: $logonUrl"
    try {
        $token = Invoke-PVWALogon -Url $logonUrl -Body $body -Certificate $Certificate -IgnoreSSL:$IgnoreSSL
    } catch {
        throw "$AuthMethod authentication failed at '$logonUrl': $_"
    }

    $expiryMin = Get-PVWASessionTimeoutMinutes -PVWAUrl $PVWAUrl -Token $token -IgnoreSSL:$IgnoreSSL
    if (-not $expiryMin) { $expiryMin = $script:PVWA_SESSION_EXPIRY_MIN }

    New-AuthTokenObject `
        -Token        $token `
        -TokenType    'CyberArkSession' `
        -Headers      @{ Authorization = $token; 'Content-Type' = 'application/json' } `
        -Expiry       ([DateTime]::UtcNow.AddMinutes($expiryMin)) `
        -RefreshToken $null `
        -SystemType   'SelfHosted' `
        -AuthMethod   $AuthMethod `
        -BaseURL      $PVWAUrl `
        -IdentityURL  $null `
        -TenantId     $null `
        -RefreshContext @{
            Method            = $AuthMethod
            PVWAUrl           = $PVWAUrl
            Certificate       = $Certificate
            ConcurrentSession = $ConcurrentSession.IsPresent
            IgnoreSSL         = $IgnoreSSL.IsPresent
        }
}

function Invoke-SelfHostedSAML {
    param(
        [string]$PVWAUrl,
        [string]$WebView2AssemblyPath,
        [switch]$IgnoreSSL
    )

    Import-WebView2Assembly -AssemblyPath $WebView2AssemblyPath

    $samlUrl  = "$PVWAUrl/API/auth/SAML/Logon"
    $pvwaHost = ([Uri]$PVWAUrl).Host
    Write-Host "  Opening browser for SAML login: $samlUrl" -ForegroundColor DarkGray
    Write-Host "  Waiting for redirect back to: $pvwaHost" -ForegroundColor DarkGray

    $captured = Invoke-WebView2Window -NavigateUrl $samlUrl -TargetHost $pvwaHost `
        -Title 'CyberArk PVWA SAML Login'

    $expiryMin = Get-PVWASessionTimeoutMinutes -PVWAUrl $PVWAUrl -Token $captured.Token -IgnoreSSL:$IgnoreSSL
    if (-not $expiryMin) { $expiryMin = $script:PVWA_SESSION_EXPIRY_MIN }

    New-AuthTokenObject `
        -Token        $captured.Token `
        -TokenType    'CyberArkSession' `
        -Headers      @{ Authorization = $captured.Token; 'Content-Type' = 'application/json' } `
        -Expiry       ([DateTime]::UtcNow.AddMinutes($expiryMin)) `
        -RefreshToken $null `
        -SystemType   'SelfHosted' `
        -AuthMethod   'SAML' `
        -BaseURL      $PVWAUrl `
        -IdentityURL  $null `
        -TenantId     $null `
        -RefreshContext @{
            Method               = 'SAML'
            PVWAUrl              = $PVWAUrl
            WebView2AssemblyPath = $WebView2AssemblyPath
            IgnoreSSL            = $IgnoreSSL.IsPresent
        }
}

function Invoke-SelfHostedOIDC {
    param(
        [string]$PVWAUrl,
        [string]$WebView2AssemblyPath,
        [switch]$IgnoreSSL
    )

    Import-WebView2Assembly -AssemblyPath $WebView2AssemblyPath

    $oidcUrl  = "$PVWAUrl/API/auth/OIDC/Logon"
    $pvwaHost = ([Uri]$PVWAUrl).Host
    Write-Host "  Opening browser for OIDC login: $oidcUrl" -ForegroundColor DarkGray
    Write-Host "  Waiting for redirect back to: $pvwaHost" -ForegroundColor DarkGray

    $captured = Invoke-WebView2Window -NavigateUrl $oidcUrl -TargetHost $pvwaHost `
        -Title 'CyberArk PVWA OIDC Login'

    $expiryMin = Get-PVWASessionTimeoutMinutes -PVWAUrl $PVWAUrl -Token $captured.Token -IgnoreSSL:$IgnoreSSL
    if (-not $expiryMin) { $expiryMin = $script:PVWA_SESSION_EXPIRY_MIN }

    New-AuthTokenObject `
        -Token        $captured.Token `
        -TokenType    'CyberArkSession' `
        -Headers      @{ Authorization = $captured.Token; 'Content-Type' = 'application/json' } `
        -Expiry       ([DateTime]::UtcNow.AddMinutes($expiryMin)) `
        -RefreshToken $null `
        -SystemType   'SelfHosted' `
        -AuthMethod   'OIDC' `
        -BaseURL      $PVWAUrl `
        -IdentityURL  $null `
        -TenantId     $null `
        -RefreshContext @{
            Method               = 'OIDC'
            PVWAUrl              = $PVWAUrl
            WebView2AssemblyPath = $WebView2AssemblyPath
            IgnoreSSL            = $IgnoreSSL.IsPresent
        }
}

#endregion

#region Public Functions

function Get-SelfHostedAuthToken {
    <#
    .SYNOPSIS
        Authenticates to a CyberArk Self-Hosted PVWA and returns a token object.
    .PARAMETER AuthMethod
        CyberArk | LDAP | RADIUS | Shared | PKI | PKIPN | SAML | OIDC
    .PARAMETER PVWAUrl
        Full PVWA base URL including AppName (e.g. https://pvwa.company.com/PasswordVault).
    .PARAMETER Credential
        PSCredential for password-based methods. Prompted if omitted.
    .PARAMETER Username
        Pre-fills the username prompt for password-based methods when no Credential is provided.
    .PARAMETER Certificate
        X509Certificate2 for PKI/PKIPN. Resolved from store if only -CertificateThumbprint given.
    .PARAMETER CertificateThumbprint
        Thumbprint of certificate in local store (alternative to -Certificate).
    .PARAMETER ConcurrentSession
        Allow concurrent sessions for this logon.
    .PARAMETER IgnoreSSL
        Bypass SSL certificate validation. Not recommended for production.
    .PARAMETER WebView2AssemblyPath
        Path to Microsoft.Web.WebView2.WinForms.dll (SAML / OIDC methods).
    .OUTPUTS
        [PSCustomObject] Token object: Token, TokenType, Headers, Expiry, RefreshToken,
        SystemType, AuthMethod, BaseURL, IdentityURL, TenantId, _RefreshContext
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('CyberArk', 'LDAP', 'RADIUS', 'Shared', 'PKI', 'PKIPN', 'SAML', 'OIDC')]
        [string]$AuthMethod,

        [string]$PVWAUrl,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$Username,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$CertificateThumbprint,
        [switch]$ConcurrentSession,
        [switch]$IgnoreSSL,
        [string]$WebView2AssemblyPath
    )

    $validMethods = @('CyberArk', 'LDAP', 'RADIUS', 'Shared', 'PKI', 'PKIPN', 'SAML', 'OIDC')

    if (-not $AuthMethod -or $AuthMethod -notin $validMethods) {
        Write-Host ''
        Write-Host '  Authentication Method (Self-Hosted):' -ForegroundColor White
        for ($i = 0; $i -lt $validMethods.Count; $i++) {
            Write-Host ("    [$($i+1)] $($validMethods[$i])") -ForegroundColor Gray
        }
        do {
            $sel   = Read-Host "Select method (1-$($validMethods.Count))"
            $idx   = 0
            $valid = [int]::TryParse($sel, [ref]$idx) -and $idx -ge 1 -and $idx -le $validMethods.Count
            if (-not $valid) { Write-Host "  Enter a number between 1 and $($validMethods.Count)." -ForegroundColor Yellow }
        } while (-not $valid)
        $AuthMethod = $validMethods[$idx - 1]
    }

    if (-not $PVWAUrl) {
        $PVWAUrl = Read-Host "PVWA base URL including AppName (e.g. https://pvwa.company.com/PasswordVault)"
    }
    $PVWAUrl = $PVWAUrl.TrimEnd('/')

    if ($IgnoreSSL -and $PSVersionTable.PSVersion.Major -lt 6) {
        Write-Warning "SSL certificate verification is disabled."
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }

    switch ($AuthMethod) {
        { $_ -in @('CyberArk', 'LDAP', 'RADIUS') } {
            return Invoke-SelfHostedPasswordAuth -PVWAUrl $PVWAUrl -AuthMethod $AuthMethod `
                -Credential $Credential -Username $Username `
                -ConcurrentSession:$ConcurrentSession -IgnoreSSL:$IgnoreSSL
        }
        'Shared' {
            return Invoke-SelfHostedShared -PVWAUrl $PVWAUrl `
                -ConcurrentSession:$ConcurrentSession -IgnoreSSL:$IgnoreSSL
        }
        { $_ -in @('PKI', 'PKIPN') } {
            if (-not $Certificate) {
                $Certificate = Get-FilteredClientCertificate -Thumbprint $CertificateThumbprint
            }
            return Invoke-SelfHostedPKI -PVWAUrl $PVWAUrl -AuthMethod $AuthMethod `
                -Certificate $Certificate -ConcurrentSession:$ConcurrentSession -IgnoreSSL:$IgnoreSSL
        }
        'SAML' {
            return Invoke-SelfHostedSAML -PVWAUrl $PVWAUrl `
                -WebView2AssemblyPath $WebView2AssemblyPath -IgnoreSSL:$IgnoreSSL
        }
        'OIDC' {
            return Invoke-SelfHostedOIDC -PVWAUrl $PVWAUrl `
                -WebView2AssemblyPath $WebView2AssemblyPath -IgnoreSSL:$IgnoreSSL
        }
    }

    throw "Unhandled Self-Hosted auth method: '$AuthMethod'"
}

function Update-SelfHostedAuthToken {
    <#
    .SYNOPSIS
        Re-authenticates using the stored _RefreshContext of a Self-Hosted token.
    .DESCRIPTION
        Password methods (CyberArk/LDAP/RADIUS): re-uses the stored credential.
        Browser methods (SAML/OIDC): re-opens the WebView2 window.
        Shared/PKI/PKIPN: re-authenticates with stored parameters.
    .PARAMETER TokenObject
        An existing SelfHosted token returned by Get-SelfHostedAuthToken or a previous
        Update-SelfHostedAuthToken call.
    .PARAMETER NoPrompt
        Set by an automated (unattended) caller. Password methods (CyberArk/LDAP/RADIUS) fail
        immediately with a clear error instead of falling back to an interactive Get-Credential
        prompt when the stored _RefreshContext has no usable credential - see Testing-Plan.md K06.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$TokenObject,

        [Parameter(Mandatory = $false)]
        [switch]$NoPrompt
    )

    $ctx = $TokenObject._RefreshContext
    if (-not $ctx) { throw "Token object missing _RefreshContext — cannot refresh." }

    switch ($ctx['Method']) {
        { $_ -in @('CyberArk', 'LDAP', 'RADIUS') } {
            return Invoke-SelfHostedPasswordAuth -PVWAUrl $ctx['PVWAUrl'] -AuthMethod $ctx['Method'] `
                -Credential $ctx['Credential'] `
                -ConcurrentSession:([switch]::new($ctx['ConcurrentSession'])) `
                -IgnoreSSL:([switch]::new($ctx['IgnoreSSL'])) `
                -NoPrompt:$NoPrompt
        }
        'Shared' {
            return Invoke-SelfHostedShared -PVWAUrl $ctx['PVWAUrl'] `
                -ConcurrentSession:([switch]::new($ctx['ConcurrentSession'])) `
                -IgnoreSSL:([switch]::new($ctx['IgnoreSSL']))
        }
        { $_ -in @('PKI', 'PKIPN') } {
            return Invoke-SelfHostedPKI -PVWAUrl $ctx['PVWAUrl'] -AuthMethod $ctx['Method'] `
                -Certificate $ctx['Certificate'] `
                -ConcurrentSession:([switch]::new($ctx['ConcurrentSession'])) `
                -IgnoreSSL:([switch]::new($ctx['IgnoreSSL']))
        }
        'SAML' {
            return Invoke-SelfHostedSAML -PVWAUrl $ctx['PVWAUrl'] `
                -WebView2AssemblyPath $ctx['WebView2AssemblyPath'] `
                -IgnoreSSL:([switch]::new($ctx['IgnoreSSL']))
        }
        'OIDC' {
            return Invoke-SelfHostedOIDC -PVWAUrl $ctx['PVWAUrl'] `
                -WebView2AssemblyPath $ctx['WebView2AssemblyPath'] `
                -IgnoreSSL:([switch]::new($ctx['IgnoreSSL']))
        }
        default {
            throw "Update-SelfHostedAuthToken: unknown method '$($ctx['Method'])'. Use Update-ISPSSAuthToken for ISPSS tokens."
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-SelfHostedAuthToken',
    'Update-SelfHostedAuthToken'
)
