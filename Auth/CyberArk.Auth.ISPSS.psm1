#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CyberArk.Auth.Common.psm1') -Force -Global

#region Constants

$script:PCLOUD_BASE_TEMPLATE = 'https://{0}.privilegecloud.cyberark.cloud/PasswordVault'

# Fallback only - used when Get-PVWASessionTimeoutMinutes (GET {BaseURL}/api/Settings/Timeout)
# cannot be reached. Privilege Cloud/ISPSS tenants have been observed returning 404 for this
# endpoint (it's a self-hosted PVWA setting not exposed the same way there), so this fallback
# is expected to be used routinely on most ISPSS tenants today - it's kept in case CyberArk
# exposes the setting for some tenants, and to match the Self-Hosted module's pattern.
$script:ISPSS_SESSION_EXPIRY_HOURS = 4

# CyberArk's documented platform-discovery service - the same endpoint psPAS's
# Find-SharedServicesURL.ps1 and New-PASSession's ISPSS-Subdomain-* auth path use to resolve
# a Privilege Cloud subdomain's Identity tenant URL. See Resolve-IdentityTenantURL.
$script:PLATFORM_DISCOVERY_URL = 'https://platform-discovery.cyberark.cloud/api/v2/services/subdomain/'

#endregion

#region Private Helpers

# Calls Write-CyberArkLog when the logging module is loaded in the session (live use).
# Falls back to Write-Verbose so the module is safe to import in test contexts.
function script:Write-ISPSSLog {
    param([string]$Message, [string]$Level = 'DEBUG', [string]$Fn)
    if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
        Write-CyberArkLog -Message $Message -Level $Level -FunctionName $Fn
    } else {
        Write-Verbose $Message
    }
}

#endregion

#region Identity Tenant Discovery

function Resolve-IdentityTenantURL {
    <#
    .SYNOPSIS
        Discovers the CyberArk Identity tenant URL for a given Privilege Cloud subdomain.
    .DESCRIPTION
        Calls CyberArk's platform-discovery service directly - the same documented endpoint
        psPAS's Find-SharedServicesURL.ps1 and New-PASSession's ISPSS-Subdomain-* auth path use
        - rather than guessing candidate hostnames and following redirects. The service returns
        every shared-service URL for the subdomain as structured JSON; this function reads
        identity_user_portal.api from that response.
    .PARAMETER PCloudSubdomain
        The subdomain portion of the Privilege Cloud URL (e.g. 'acme' from acme.privilegecloud.cyberark.cloud).
    .PARAMETER ExistingIdentityHost
        When provided, the function returns immediately with this value (normalised to https://).
        Used to skip discovery when TenantAuth is already cached in the profile.
    #>
    param(
        [string]$PCloudSubdomain,
        [string]$ExistingIdentityHost
    )

    $fn = 'Resolve-IdentityTenantURL'

    if (-not [string]::IsNullOrWhiteSpace($ExistingIdentityHost)) {
        $cleaned = $ExistingIdentityHost.Trim().Replace('https://', '').TrimEnd('/')
        $url     = "https://$cleaned"
        script:Write-ISPSSLog -Message "Using cached TenantAuth: $url" -Level 'DEBUG' -Fn $fn
        return $url
    }

    script:Write-ISPSSLog -Message "Discovering Identity tenant URL for subdomain '$PCloudSubdomain' via platform-discovery." -Level 'INFO' -Fn $fn

    $discoveryUrl = "$script:PLATFORM_DISCOVERY_URL$PCloudSubdomain"

    try {
        $result = Invoke-RestMethod -Uri $discoveryUrl -Method GET -ErrorAction Stop

        $identityApi = $null
        if ($null -ne $result -and $result.PSObject.Properties['identity_user_portal'] -and $result.identity_user_portal) {
            $identityApi = $result.identity_user_portal | Select-Object -ExpandProperty api -ErrorAction SilentlyContinue
        }

        if ($identityApi) {
            $url = $identityApi.TrimEnd('/')
            script:Write-ISPSSLog -Message "Identity tenant resolved via platform-discovery: $url" -Level 'INFO' -Fn $fn
            return $url
        }

        script:Write-ISPSSLog -Message "platform-discovery response for '$PCloudSubdomain' did not include identity_user_portal.api." -Level 'WARN' -Fn $fn
    } catch {
        $exMessage = 'Exception details unavailable'
        try { $exMessage = $_.Exception.Message } catch { }
        script:Write-ISPSSLog -Message "platform-discovery request failed for '$PCloudSubdomain': $exMessage" -Level 'WARN' -Fn $fn
    }

    $url = "https://$PCloudSubdomain.id.cyberark.cloud"
    script:Write-ISPSSLog -Message "platform-discovery did not resolve an identity tenant. Using constructed fallback: $url" -Level 'WARN' -Fn $fn
    return $url
}

#endregion

#region ISPSS Authentication Methods (private)

function Invoke-ISPSSClientCredentials {
    param(
        [string]$IdentityURL,
        [string]$ClientId,
        [System.Security.SecureString]$ClientSecret,
        [string]$BaseURL
    )

    $plainSecret = ConvertTo-PlainText $ClientSecret
    $body = ("grant_type=client_credentials" +
             "&client_id=$([Uri]::EscapeDataString($ClientId))" +
             "&client_secret=$([Uri]::EscapeDataString($plainSecret))")
    $plainSecret = $null

    $tokenUrl = "$IdentityURL/oauth2/platformtoken"
    Write-Verbose "Requesting client_credentials token from: $tokenUrl"
    try {
        # Body is encoded as raw UTF8 bytes rather than a String so PowerShell's own
        # ParameterBinding/module logging (e.g. GPO-enabled Module Logging / Script Block
        # Logging) records a non-revealing System.Byte[] type name instead of the literal
        # request content, which includes the OAuth2 client secret. Mirrors psPAS's
        # Invoke-PASRestMethod.ps1.
        $resp = Invoke-RestMethod -Uri $tokenUrl -Method POST `
            -Headers @{ 'Content-Type' = 'application/x-www-form-urlencoded' } `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ErrorAction Stop
    } catch {
        throw "ClientCredentials token request failed: $_"
    }

    # CyberArk's own "Create an API token" reference documents the client_credentials
    # platformtoken response as { access_token, token_type, expires_in } only - no refresh_token
    # field (client_credentials grants typically aren't paired with one, since the client can
    # just re-present its own credentials for a new token). Guard every field with
    # PSObject.Properties[] rather than dot-accessing it unconditionally - confirmed live that a
    # genuinely absent property throws PropertyNotFoundException under Set-StrictMode, which
    # would otherwise crash immediately after every successful ClientCredentials login.
    $expiresIn    = if ($resp.PSObject.Properties['expires_in'])   { [int]$resp.expires_in } else { 3600 }
    $token        = if ($resp.PSObject.Properties['access_token']) { $resp.access_token }     else { $null }
    $refreshToken = if ($resp.PSObject.Properties['refresh_token']) { $resp.refresh_token }    else { $null }
    $expiry       = [DateTime]::UtcNow.AddSeconds($expiresIn)

    New-AuthTokenObject `
        -Token        $token `
        -TokenType    'Bearer' `
        -Headers      @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
        -Expiry       $expiry `
        -RefreshToken $refreshToken `
        -SystemType   'ISPSS' `
        -AuthMethod   'ClientCredentials' `
        -BaseURL      $BaseURL `
        -IdentityURL  $IdentityURL `
        -TenantId     '' `
        -RefreshContext @{
            Method       = 'ClientCredentials'
            IdentityURL  = $IdentityURL
            ClientId     = $ClientId
            ClientSecret = $ClientSecret
            BaseURL      = $BaseURL
        }
}

function Invoke-IdentityAdvancedAuth {
    param(
        [string]$IdentityURL,
        [string]$TenantId,
        [string]$SessionId,
        [string]$MechanismId,
        [string]$Action,
        [string]$Answer
    )

    $body = @{
        TenantID    = $TenantId
        SessionId   = $SessionId
        MechanismId = $MechanismId
        Action      = $Action
    }
    if ($Answer) { $body.Answer = $Answer }

    $bodyJson = $body | ConvertTo-Json

    # Body is encoded as raw UTF8 bytes rather than a String so PowerShell's own
    # ParameterBinding/module logging cannot record the literal request content, which can
    # include the user's password/OTP/other MFA answer in the Answer field. Mirrors psPAS's
    # Invoke-PASRestMethod.ps1.
    Invoke-RestMethod -Uri "$IdentityURL/Security/AdvanceAuthentication" -Method POST `
        -Headers @{ 'X-IDAP-NATIVE-CLIENT' = 'true'; 'Content-Type' = 'application/json' } `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($bodyJson)) -ErrorAction Stop
}

function Invoke-IdentityChallengeLoop {
    <#
    .SYNOPSIS
        Walks CyberArk Identity's StartAuthentication challenge set to a token.
    .PARAMETER NoPrompt
        Automation mode only: throws immediately instead of any interactive fallback
        (mechanism-choice prompt, password Read-Host, or an out-of-band approval wait) - the only
        path allowed is a single Text/'UP' (password) mechanism answerable from -Credential. See
        Testing_Findings-and-Known-Issues.md K12.
    .OUTPUTS
        [PSCustomObject] with Token (the auth token string) and CapturedPassword (a SecureString,
        only populated when a 'UP' mechanism's password was freshly typed rather than supplied via
        -Credential - lets the caller build a PSCredential for _RefreshContext even when the very
        first login was done by hand).
    #>
    param(
        [string]$IdentityURL,
        [string]$TenantId,
        [string]$SessionId,
        [array]$Challenges,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$NoPrompt
    )

    foreach ($challenge in $Challenges) {
        $mechanisms   = $challenge.Mechanisms
        $selectedMech = $null

        if ($mechanisms.Count -eq 1) {
            $selectedMech = $mechanisms[0]
        } elseif ($Credential) {
            $selectedMech = $mechanisms |
                Where-Object { $_.Name -eq 'UP' -and $_.AnswerType -eq 'Text' } |
                Select-Object -First 1
        }

        if (-not $selectedMech) {
            if ($NoPrompt) {
                throw "Automation mode: this CyberArk Identity user has multiple authentication mechanisms available and no stored credential to auto-select one - cannot proceed non-interactively. Log in interactively at least once, or reduce this identity's authentication policy to a single password factor."
            }
            Write-Host "`nSelect an authentication mechanism:"
            for ($i = 0; $i -lt $mechanisms.Count; $i++) {
                Write-Host ("  [{0}] {1}" -f ($i + 1), ($mechanisms[$i].PromptMechChosen -replace '\bSent\b(?! to)', 'Send'))
            }
            $idx = 0
            do {
                $sel   = Read-Host "Choice (1-$($mechanisms.Count))"
                $valid = [int]::TryParse($sel, [ref]$idx) -and $idx -ge 1 -and $idx -le $mechanisms.Count
            } while (-not $valid)
            $selectedMech = $mechanisms[$idx - 1]
        }

        Write-Verbose "Using mechanism: $($selectedMech.Name) / AnswerType: $($selectedMech.AnswerType)"

        $isSilentUP = $selectedMech.Name -eq 'UP' -and $selectedMech.AnswerType -eq 'Text' -and $Credential
        if ($NoPrompt -and -not $isSilentUP) {
            throw "Automation mode: mechanism '$($selectedMech.Name)' requires interactive input (no usable stored credential for a password-only answer) - cannot proceed non-interactively."
        }

        $resp = $null
        $capturedPassword = $null
        switch ($selectedMech.AnswerType) {
            'Text' {
                if ($selectedMech.Name -eq 'UP' -and $Credential) {
                    $answer = $Credential.GetNetworkCredential().Password
                } else {
                    $ss     = Read-Host -Prompt ($selectedMech.PromptSelectMech -replace '\bSent\b(?! to)', 'Send') -AsSecureString
                    $answer = ConvertTo-PlainText $ss
                    if ($selectedMech.Name -eq 'UP') { $capturedPassword = $ss }
                }
                $resp = Invoke-IdentityAdvancedAuth -IdentityURL $IdentityURL -TenantId $TenantId `
                    -SessionId $SessionId -MechanismId $selectedMech.MechanismId `
                    -Action 'Answer' -Answer $answer
            }
            'StartTextOob' {
                $resp = Invoke-IdentityAdvancedAuth -IdentityURL $IdentityURL -TenantId $TenantId `
                    -SessionId $SessionId -MechanismId $selectedMech.MechanismId -Action 'StartOOB'
                Write-Host ($selectedMech.PromptMechChosen -replace '\bSent\b(?! to)', 'Send')
                $oobStart   = Get-Date
                $oobTimeout = 300
                $oobToken   = $null
                do {
                    $elapsed = [int]((Get-Date) - $oobStart).TotalSeconds
                    Write-Host "`r  Waiting for out-of-band approval... ($($elapsed)s)" -NoNewline
                    if ($elapsed -ge $oobTimeout) {
                        Write-Host ''
                        throw "Authentication failed: Out-of-band approval timed out after $($oobTimeout / 60) minutes."
                    }
                    Start-Sleep -Seconds 2
                    $resp = Invoke-IdentityAdvancedAuth -IdentityURL $IdentityURL -TenantId $TenantId `
                        -SessionId $SessionId -MechanismId $selectedMech.MechanismId -Action 'Poll'
                    if ($resp) {
                        if ($resp.Result -isnot [string]) {
                            if ($resp.Result.PSObject.Properties['Token'] -and $resp.Result.Token) { $oobToken = $resp.Result.Token }
                            elseif ($resp.Result.PSObject.Properties['Auth'] -and $resp.Result.Auth) { $oobToken = $resp.Result.Auth }
                        }
                        if (-not $oobToken -and $resp.PSObject.Properties['Token'] -and $resp.Token) { $oobToken = $resp.Token }
                        if (-not $oobToken -and $resp.PSObject.Properties['Auth']  -and $resp.Auth)  { $oobToken = $resp.Auth  }
                    }
                } while (-not $oobToken -and $resp -and $resp.success -ne $false)
                Write-Host ''
                if ($oobToken) { return [PSCustomObject]@{ Token = $oobToken; CapturedPassword = $null } }
            }
            default {
                $ss     = Read-Host -Prompt ($selectedMech.PromptSelectMech -replace '\bSent\b(?! to)', 'Send') -AsSecureString
                $answer = ConvertTo-PlainText $ss
                $resp = Invoke-IdentityAdvancedAuth -IdentityURL $IdentityURL -TenantId $TenantId `
                    -SessionId $SessionId -MechanismId $selectedMech.MechanismId `
                    -Action 'Answer' -Answer $answer
            }
        }

        if ($resp -and $resp.success -eq $false) {
            throw "Authentication failed: $($resp.Message)"
        }

        if ($resp) {
            $authToken = $null
            if ($resp.Result -isnot [string]) {
                Write-Verbose "AdvanceAuthentication Result fields: $($resp.Result.PSObject.Properties.Name -join ', ')"
                if ($resp.Result.PSObject.Properties['Token'] -and $resp.Result.Token) {
                    $authToken = $resp.Result.Token
                } elseif ($resp.Result.PSObject.Properties['Auth'] -and $resp.Result.Auth) {
                    $authToken = $resp.Result.Auth
                }
            }
            if (-not $authToken -and $resp.PSObject.Properties['Token'] -and $resp.Token) {
                $authToken = $resp.Token
            }
            if (-not $authToken -and $resp.PSObject.Properties['Auth'] -and $resp.Auth) {
                $authToken = $resp.Auth
            }
            if ($authToken) { return [PSCustomObject]@{ Token = $authToken; CapturedPassword = $capturedPassword } }
        }
    }

    throw "Challenge loop completed without returning a token."
}

function Invoke-ISPSSInteractive {
    <#
    .PARAMETER NoPrompt
        Automation mode only: fails immediately instead of any interactive fallback. Succeeds
        silently only when -Credential (or a resolvable -Username with -Credential) answers a
        single password-only ('UP') challenge - see Testing_Findings-and-Known-Issues.md K12. Forwarded to
        Invoke-IdentityChallengeLoop, which is where each specific interactive fallback is
        rejected.
    .PARAMETER AuthTokenProfileName
    .PARAMETER ProfileDir
        Both optional. When supplied, this login's StartAuthentication response is checked for a
        RetryWaitingTime hint and recorded via Set-ISPSSAuthThrottle, and both values are carried
        forward into the returned token's _RefreshContext so a later Update-ISPSSAuthToken silent
        refresh keeps recording it too, with no extra plumbing needed at that call site. See
        Testing_Findings-and-Known-Issues.md K17.
    #>
    param(
        [string]$IdentityURL,
        [string]$PCloudSubdomain,
        [string]$BaseURL,
        [string]$Username,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$NoPrompt,
        [string]$AuthTokenProfileName,
        [string]$ProfileDir
    )

    if (-not $Username -and $Credential) { $Username = $Credential.UserName }
    if (-not $Username) {
        if ($NoPrompt) { throw "Automation mode: no username available for ISPSS Interactive authentication - log in interactively at least once first." }
        $Username = Read-Host "CyberArk Identity username"
    }

    $startHeaders = @{
        'X-IDAP-NATIVE-CLIENT' = 'true'
        'OobIdPAuth'           = 'true'
        'Content-Type'         = 'application/json'
    }
    $startBody = @{ TenantId = ''; User = $Username; Version = '1.0' } | ConvertTo-Json

    Write-Verbose "Starting Identity authentication for: $Username"
    try {
        # Encoded as raw UTF8 bytes for consistency with every other request body in this
        # module - see Invoke-ISPSSClientCredentials for why.
        $startResp = Invoke-RestMethod -Uri "$IdentityURL/Security/StartAuthentication" `
            -Method POST -Headers $startHeaders -Body ([System.Text.Encoding]::UTF8.GetBytes($startBody)) -ErrorAction Stop
    } catch {
        throw "StartAuthentication failed: $_"
    }

    # Confirmed live (Testing_Findings-and-Known-Issues.md K17): this is a server-provided minimum-spacing hint
    # between authentication attempts for this identity, present on both a successful and a
    # failed StartAuthentication - record it before checking $startResp.success, so it applies
    # either way.
    if ($AuthTokenProfileName -and $startResp.Result -and $startResp.Result.PSObject.Properties['RetryWaitingTime']) {
        $retryWait = 0
        if ([int]::TryParse("$($startResp.Result.RetryWaitingTime)", [ref]$retryWait) -and $retryWait -gt 0) {
            Set-ISPSSAuthThrottle -AuthTokenProfileName $AuthTokenProfileName -ProfileDir $ProfileDir -WaitSeconds $retryWait
        }
    }

    if (-not $startResp.success) {
        throw "StartAuthentication error: $($startResp.Message)"
    }

    $tenantId   = $startResp.Result.TenantId
    $sessionId  = $startResp.Result.SessionId
    $challenges = $startResp.Result.Challenges
    $token      = $null

    if ($startResp.Result.PSObject.Properties['IdpRedirectShortUrl'] -and $startResp.Result.IdpRedirectShortUrl) {
        if ($NoPrompt) {
            throw "Automation mode: this CyberArk Identity user requires external IdP redirect authentication - cannot proceed non-interactively."
        }
        $redirectUrl = $startResp.Result.IdpRedirectShortUrl
        Write-Host "External IdP authentication required. Opening browser..."
        Start-Process $redirectUrl
        $pin    = Read-Host "Enter the PIN shown after completing external IdP login"
        $mechId = $challenges[0].Mechanisms[0].MechanismId
        $resp   = Invoke-IdentityAdvancedAuth -IdentityURL $IdentityURL -TenantId $tenantId `
            -SessionId $sessionId -MechanismId $mechId -Action 'Answer' -Answer $pin
        if ($resp.success -eq $false) {
            throw "External IdP PIN authentication failed: $($resp.Message)"
        }
        $token = $resp.Result.Token
    } else {
        $loopResult = Invoke-IdentityChallengeLoop -IdentityURL $IdentityURL -TenantId $tenantId `
            -SessionId $sessionId -Challenges $challenges -Credential $Credential -NoPrompt:$NoPrompt
        $token = $loopResult.Token
        # A fresh login typed by hand (no -Credential supplied) still yields a usable password
        # here, captured by the challenge loop - build a Credential from it so this login's
        # _RefreshContext can support a later silent refresh, not just this one call.
        if (-not $Credential -and $loopResult.CapturedPassword) {
            $Credential = New-Object System.Management.Automation.PSCredential($Username, $loopResult.CapturedPassword)
        }
    }

    if (-not $token) { throw "Interactive authentication did not return a token." }

    $expiryMin = Get-PVWASessionTimeoutMinutes -PVWAUrl $BaseURL -Token "Bearer $token"
    $expiry    = if ($expiryMin) { [DateTime]::UtcNow.AddMinutes($expiryMin) }
                 else { [DateTime]::UtcNow.AddHours($script:ISPSS_SESSION_EXPIRY_HOURS) }

    New-AuthTokenObject `
        -Token        $token `
        -TokenType    'Bearer' `
        -Headers      @{
            Authorization          = "Bearer $token"
            'X-IDAP-NATIVE-CLIENT' = 'true'
            'Content-Type'         = 'application/json'
        } `
        -Expiry       $expiry `
        -RefreshToken $null `
        -SystemType   'ISPSS' `
        -AuthMethod   'Interactive' `
        -BaseURL      $BaseURL `
        -IdentityURL  $IdentityURL `
        -TenantId     $tenantId `
        -RefreshContext @{
            Method               = 'Interactive'
            IdentityURL          = $IdentityURL
            PCloudSubdomain      = $PCloudSubdomain
            Username             = $Username
            Credential           = $Credential
            BaseURL              = $BaseURL
            AuthTokenProfileName = $AuthTokenProfileName
            ProfileDir           = $ProfileDir
        }
}

function Invoke-ISPSSSO {
    param(
        [string]$IdentityURL,
        [string]$PCloudSubdomain,
        [string]$BaseURL,
        [string]$WebView2AssemblyPath
    )

    Import-WebView2Assembly -AssemblyPath $WebView2AssemblyPath

    $loginUrl = "$IdentityURL/login?redirectUrl=$([Uri]::EscapeDataString($BaseURL))"
    Write-Host "  Opening browser for SSO login: $loginUrl" -ForegroundColor DarkGray

    $captured = Invoke-WebView2Window -NavigateUrl $loginUrl -CookieName 'idToken' `
        -Title 'CyberArk Identity SSO Login'

    $expiryMin = Get-PVWASessionTimeoutMinutes -PVWAUrl $BaseURL -Token "Bearer $($captured.Token)"
    $expiry    = if ($expiryMin) { [DateTime]::UtcNow.AddMinutes($expiryMin) }
                 else { [DateTime]::UtcNow.AddHours($script:ISPSS_SESSION_EXPIRY_HOURS) }

    New-AuthTokenObject `
        -Token        $captured.Token `
        -TokenType    'Bearer' `
        -Headers      @{
            Authorization          = "Bearer $($captured.Token)"
            'X-IDAP-NATIVE-CLIENT' = 'true'
            'Content-Type'         = 'application/json'
        } `
        -Expiry       $expiry `
        -RefreshToken $null `
        -SystemType   'ISPSS' `
        -AuthMethod   'SSO' `
        -BaseURL      $BaseURL `
        -IdentityURL  $IdentityURL `
        -TenantId     '' `
        -RefreshContext @{
            Method               = 'SSO'
            IdentityURL          = $IdentityURL
            PCloudSubdomain      = $PCloudSubdomain
            BaseURL              = $BaseURL
            WebView2AssemblyPath = $WebView2AssemblyPath
        }
}

#endregion

#region Public Functions

function Get-ISPSSAuthToken {
    <#
    .SYNOPSIS
        Authenticates to CyberArk Privilege Cloud and returns a token object.
    .PARAMETER AuthMethod
        ClientCredentials | Interactive | SSO
    .PARAMETER PCloudSubdomain
        Subdomain of the Privilege Cloud tenant (e.g. 'acme' from acme.privilegecloud.cyberark.cloud).
    .PARAMETER IdentityTenantURL
        Overrides identity URL discovery. Use the TenantAuth profile field when available.
    .PARAMETER ClientId
        OAuth2 client ID (ClientCredentials method).
    .PARAMETER ClientSecret
        OAuth2 client secret as SecureString (ClientCredentials method).
    .PARAMETER Username
        CyberArk Identity username to pre-fill the prompt (Interactive method).
    .PARAMETER Credential
        PSCredential used for Interactive password pre-fill (optional).
    .PARAMETER WebView2AssemblyPath
        Path to Microsoft.Web.WebView2.WinForms.dll (SSO method).
    .PARAMETER AuthTokenProfileName
    .PARAMETER ProfileDir
        Both optional, Interactive method only - forwarded to Invoke-ISPSSInteractive so a
        CyberArk Identity RetryWaitingTime hint can be recorded and honored on future refreshes.
        See Testing_Findings-and-Known-Issues.md K17.
    .OUTPUTS
        [PSCustomObject] Token object: Token, TokenType, Headers, Expiry, RefreshToken,
        SystemType, AuthMethod, BaseURL, IdentityURL, TenantId, _RefreshContext
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('ClientCredentials', 'Interactive', 'SSO')]
        [string]$AuthMethod,

        [string]$PCloudSubdomain,
        [string]$IdentityTenantURL,
        [string]$ClientId,
        [System.Security.SecureString]$ClientSecret,
        [string]$Username,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$WebView2AssemblyPath,
        [string]$AuthTokenProfileName,
        [string]$ProfileDir
    )

    $validMethods = @('ClientCredentials', 'Interactive', 'SSO')

    if (-not $AuthMethod -or $AuthMethod -notin $validMethods) {
        Write-Host ''
        Write-Host '  Authentication Method (Privilege Cloud):' -ForegroundColor White
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

    if (-not $PCloudSubdomain) {
        $PCloudSubdomain = Read-Host "Privilege Cloud subdomain (e.g. 'acme' from acme.privilegecloud.cyberark.cloud)"
    }

    $baseURL = $script:PCLOUD_BASE_TEMPLATE -f $PCloudSubdomain

    if (-not $IdentityTenantURL) {
        $IdentityTenantURL = Resolve-IdentityTenantURL -PCloudSubdomain $PCloudSubdomain
    }

    switch ($AuthMethod) {
        'ClientCredentials' {
            if (-not $ClientId)     { $ClientId     = Read-Host "OAuth2 Client ID" }
            if (-not $ClientSecret) { $ClientSecret = Read-Host "OAuth2 Client Secret" -AsSecureString }
            return Invoke-ISPSSClientCredentials -IdentityURL $IdentityTenantURL `
                -ClientId $ClientId -ClientSecret $ClientSecret -BaseURL $baseURL
        }
        'Interactive' {
            $usernameToUse = if ($Username)      { $Username }
                             elseif ($Credential) { $Credential.UserName }
                             else                 { $null }
            return Invoke-ISPSSInteractive -IdentityURL $IdentityTenantURL `
                -PCloudSubdomain $PCloudSubdomain -BaseURL $baseURL `
                -Username $usernameToUse -Credential $Credential `
                -AuthTokenProfileName $AuthTokenProfileName -ProfileDir $ProfileDir
        }
        'SSO' {
            return Invoke-ISPSSSO -IdentityURL $IdentityTenantURL `
                -PCloudSubdomain $PCloudSubdomain -BaseURL $baseURL `
                -WebView2AssemblyPath $WebView2AssemblyPath
        }
    }

    throw "Unhandled ISPSS auth method: '$AuthMethod'"
}

function Update-ISPSSAuthToken {
    <#
    .SYNOPSIS
        Refreshes or re-authenticates an existing ISPSS token using its stored _RefreshContext.
    .DESCRIPTION
        ClientCredentials: attempts refresh_token grant first; falls back to full client_credentials.
        Interactive: re-runs the MFA challenge flow.
        SSO: re-opens the WebView2 browser window.
    .PARAMETER TokenObject
        An existing ISPSS token returned by Get-ISPSSAuthToken or a previous Update-ISPSSAuthToken call.
    .PARAMETER NoPrompt
        Forwarded to Invoke-ISPSSInteractive for the Interactive method (see its own -NoPrompt for
        what that does and doesn't allow silently). No-op for ClientCredentials, which is already
        always silent. Not meaningful for SSO - callers should not reach this function for SSO in
        automation mode at all (see Manage-Privilege.ps1's Invoke-TokenRefresh).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$TokenObject,
        [switch]$NoPrompt
    )

    $ctx = $TokenObject._RefreshContext
    if (-not $ctx) { throw "Token object missing _RefreshContext — cannot refresh." }

    switch ($ctx['Method']) {
        'ClientCredentials' {
            if ($TokenObject.RefreshToken) {
                Write-Verbose "Attempting refresh_token grant."
                try {
                    $body = ("grant_type=refresh_token" +
                             "&refresh_token=$([Uri]::EscapeDataString($TokenObject.RefreshToken))" +
                             "&client_id=$([Uri]::EscapeDataString($ctx['ClientId']))")
                    # Body is encoded as raw UTF8 bytes rather than a String so PowerShell's own
                    # ParameterBinding/module logging cannot record the literal refresh_token
                    # value. Mirrors psPAS's Invoke-PASRestMethod.ps1.
                    # NOTE: CyberArk's own rate-limiting reference lists /oauth2/refreshplatformtoken
                    # as a separate, distinct High-API-group endpoint from /oauth2/platformtoken -
                    # this call reuses the latter with grant_type=refresh_token instead, which is
                    # unverified against live ISPSS. In practice this whole branch is unreachable
                    # today anyway, since Invoke-ISPSSClientCredentials never receives a
                    # refresh_token to begin with (see its own comment) - kept here, defensively
                    # guarded, in case some tenant configuration does return one.
                    $resp = Invoke-RestMethod -Uri "$($ctx['IdentityURL'])/oauth2/platformtoken" `
                        -Method POST `
                        -Headers @{ 'Content-Type' = 'application/x-www-form-urlencoded' } `
                        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ErrorAction Stop
                    $expiresIn  = if ($resp.PSObject.Properties['expires_in'])   { [int]$resp.expires_in } else { 3600 }
                    $newAccess  = if ($resp.PSObject.Properties['access_token']) { $resp.access_token }    else { $null }
                    $newRefresh = if ($resp.PSObject.Properties['refresh_token']) { $resp.refresh_token }  else { $TokenObject.RefreshToken }
                    return New-AuthTokenObject `
                        -Token        $newAccess `
                        -TokenType    'Bearer' `
                        -Headers      @{ Authorization = "Bearer $newAccess"; 'Content-Type' = 'application/json' } `
                        -Expiry       ([DateTime]::UtcNow.AddSeconds($expiresIn)) `
                        -RefreshToken $newRefresh `
                        -SystemType   'ISPSS' `
                        -AuthMethod   'ClientCredentials' `
                        -BaseURL      $ctx['BaseURL'] `
                        -IdentityURL  $ctx['IdentityURL'] `
                        -TenantId     '' `
                        -RefreshContext @{
                            Method       = 'ClientCredentials'
                            IdentityURL  = $ctx['IdentityURL']
                            ClientId     = $ctx['ClientId']
                            ClientSecret = $ctx['ClientSecret']
                            BaseURL      = $ctx['BaseURL']
                        }
                } catch {
                    Write-Warning "refresh_token grant failed, re-authenticating: $_"
                }
            }
            return Invoke-ISPSSClientCredentials -IdentityURL $ctx['IdentityURL'] `
                -ClientId $ctx['ClientId'] -ClientSecret $ctx['ClientSecret'] -BaseURL $ctx['BaseURL']
        }
        'Interactive' {
            return Invoke-ISPSSInteractive -IdentityURL $ctx['IdentityURL'] `
                -PCloudSubdomain $ctx['PCloudSubdomain'] -BaseURL $ctx['BaseURL'] `
                -Username $ctx['Username'] -Credential $ctx['Credential'] -NoPrompt:$NoPrompt `
                -AuthTokenProfileName $ctx['AuthTokenProfileName'] -ProfileDir $ctx['ProfileDir']
        }
        'SSO' {
            return Invoke-ISPSSSO -IdentityURL $ctx['IdentityURL'] `
                -PCloudSubdomain $ctx['PCloudSubdomain'] -BaseURL $ctx['BaseURL'] `
                -WebView2AssemblyPath $ctx['WebView2AssemblyPath']
        }
        default {
            throw "Update-ISPSSAuthToken: unknown method '$($ctx['Method'])'. Use Update-SelfHostedAuthToken for Self-Hosted tokens."
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Resolve-IdentityTenantURL',
    'Get-ISPSSAuthToken',
    'Update-ISPSSAuthToken'
)
