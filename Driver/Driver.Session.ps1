<#
    Manage-Privilege.ps1 driver part: API module discovery and the token lifecycle.
    Dot-sourced by Manage-Privilege.ps1 (Driver Parts region) into its script scope; not run on its own.
#>

#region --- Module Discovery ---

function Import-APIModules {
    $script:LoadedModules = @()
    if (-not (Test-Path -LiteralPath $script:APIModulesPath)) {
        Write-CyberArkLog -Message "APIModules folder not found: $($script:APIModulesPath)" -Level 'WARN'
        return
    }

    $files = Get-ChildItem -LiteralPath $script:APIModulesPath -Filter '*.ps1' -Recurse -File |
             Sort-Object { $_.Directory.Name }, Name

    $num = 1
    foreach ($file in $files) {
        try {
            $ModuleMeta = $null
            . $file.FullName

            if (-not $ModuleMeta) { continue }
            if ($ModuleMeta.SupportedSystems -notcontains $script:SessionToken.SystemType) { continue }

            $script:LoadedModules += [PSCustomObject]@{
                Number   = $num
                Meta     = $ModuleMeta
                FilePath = $file.FullName
            }
            $num++
            Write-CyberArkLog -Message "Loaded module: $($ModuleMeta.Name) v$($ModuleMeta.Version)" -Level 'DEBUG'
        } catch {
            $loadErr = "$_"
            Write-Host "  [Module Load Error] $($file.Name): $loadErr" -ForegroundColor Red
            Write-CyberArkLog -Message "Failed to load module '$($file.Name)': $loadErr" -Level 'WARN'
            $script:LoadedModules += [PSCustomObject]@{
                Number    = $num
                Meta      = @{
                    Name             = $file.BaseName
                    Category         = 'Errors'
                    Action           = 'LoadFailed'
                    Description      = $loadErr
                    SupportedSystems = @('ISPSS', 'SelfHosted')
                    SupportsWhatIf   = $false
                    AcceptsInputFile = $false
                    ProducesOutput   = $false
                    HasCustomInput   = $false
                    Priority         = 999
                }
                FilePath  = $file.FullName
                Failed    = $true
                FailError = $loadErr
            }
            $num++
        }
    }

    Write-CyberArkLog -Message "Module discovery complete: $($script:LoadedModules.Count) module(s) for $($script:SessionToken.SystemType)." -Level 'INFO'
}

#endregion

#region --- Token Lifecycle ---

function Get-TokenRemainingMinutes {
    if (-not $script:SessionToken -or -not $script:SessionToken.Expiry) { return 0 }
    return ($script:SessionToken.Expiry - (Get-Date).ToUniversalTime()).TotalMinutes
}

function Test-TokenExpiry {
    $remaining = Get-TokenRemainingMinutes
    if ($remaining -le 0)                         { return 'Expired' }
    if ($remaining -le $script:TokenExpiryWarnMin) { return 'Warning' }
    return 'Valid'
}

function Invoke-ClearNonRefreshableContext {
    # Removes stored credentials from _RefreshContext for methods that cannot silently refresh.
    # Reduces the in-memory exposure window for SSO/SAML/OIDC sessions. ISPSS Interactive is
    # deliberately excluded as of K12: it CAN now silently refresh from a retained Credential
    # (Update-ISPSSAuthToken -NoPrompt), the same tradeoff already accepted for SelfHosted
    # CyberArk/LDAP/RADIUS, which has always retained its Credential for this exact reason.
    # Username is retained so it can pre-fill prompts on manual re-auth.
    param([PSCustomObject]$Token)
    if (-not $Token -or -not $Token.PSObject.Properties['_RefreshContext'] -or -not $Token._RefreshContext) { return }
    if ($Token.AuthMethod -in @('SSO', 'SAML', 'OIDC')) {
        $Token._RefreshContext.Remove('Credential')
        $Token._RefreshContext.Remove('ClientSecret')
    }
}

function Invoke-ProactiveRefresh {
    # Silently refreshes a ClientCredentials token when it is approaching expiry,
    # before the expiry check would normally trigger a re-auth prompt.
    if (-not $script:SessionToken) { return }
    if ($script:SessionToken.SystemType -ne 'ISPSS') { return }
    if ($script:SessionToken.AuthMethod -ne 'ClientCredentials') { return }
    $remaining = Get-TokenRemainingMinutes
    if ($remaining -le 0 -or $remaining -gt $script:ProactiveRefreshThresholdMin) { return }

    Write-CyberArkLog -Message "Proactively refreshing ClientCredentials token ($([Math]::Round($remaining, 1)) min remaining)." -Level 'INFO'
    try {
        $refreshed = Update-ISPSSAuthToken -TokenObject $script:SessionToken
        if ($refreshed -and $refreshed.Token) {
            Set-SessionToken -NewToken $refreshed
            $null = Save-SessionToken -TokenObject $refreshed -ProfileName $script:ActiveProfile.AuthTokenProfile
            Write-CyberArkLog -Message 'Proactive token refresh succeeded.' -Level 'INFO'
        }
    } catch {
        Write-CyberArkLog -Message "Proactive token refresh failed (will retry on expiry): $_" -Level 'WARN'
    }
}

function Invoke-TokenRefresh {
    $status = Test-TokenExpiry
    if ($status -in @('Valid', 'Warning')) { return $true }

    $method = $script:SessionToken.AuthMethod
    $type   = $script:SessionToken.SystemType

    if ($script:AutomationMode) {
        # Every refresh path that can ever be silent already routes through
        # Update-SelfHostedAuthToken/Update-ISPSSAuthToken using the token's own saved
        # _RefreshContext - the same mechanism Invoke-ProfileConnect's startup refresh already
        # uses, bypassing the interactive branches below entirely (including the SelfHosted
        # password branch, which normally always demands a NEW password rather than reusing the
        # stored one). SAML/OIDC (SelfHosted) and SSO (ISPSS) have no non-interactive refresh path
        # at all - their auth functions always open a WebView2 window, refresh or not - so
        # automation mode never attempts one for those; doing so would just relocate the same hang
        # one level deeper instead of avoiding it. ISPSS Interactive (K12) CAN be silent, but only
        # conditionally - Update-ISPSSAuthToken's own -NoPrompt (via Invoke-ISPSSInteractive /
        # Invoke-IdentityChallengeLoop) is what actually enforces that, failing cleanly instead of
        # prompting when no stored credential is available or this identity's policy demands a
        # second factor beyond password.
        $neverSilent = ($type -eq 'ISPSS' -and $method -eq 'SSO') -or
                        ($type -eq 'SelfHosted' -and $method -in @('SAML', 'OIDC'))
        if ($neverSilent) {
            Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: session for profile '$($script:ActiveProfile.ProfileName)' expired mid-run and its auth method ($method) has no non-interactive refresh path."
            return $false
        }
        # K17: skip a doomed re-authentication attempt if CyberArk Identity's own RetryWaitingTime
        # hasn't elapsed yet, rather than adding another attempt within its own soft-lockout window.
        if ($type -eq 'ISPSS') {
            $throttleSec = Get-ISPSSAuthThrottle -AuthTokenProfileName $script:ActiveProfile.AuthTokenProfile -ProfileDir $script:ProfileDir
            if ($throttleSec -gt 0) {
                Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: mid-run token refresh skipped - CyberArk Identity asked us to wait $throttleSec more second(s) before the next authentication attempt (Testing_Findings-and-Known-Issues.md K17)."
                return $false
            }
        }
        try {
            Use-StoredCredentialIfMissing -Token $script:SessionToken -AuthTokenProfileName $script:ActiveProfile.AuthTokenProfile
            $refreshed = if ($type -eq 'ISPSS') {
                Update-ISPSSAuthToken -TokenObject $script:SessionToken -NoPrompt
            } else {
                Update-SelfHostedAuthToken -TokenObject $script:SessionToken -NoPrompt
            }
            if ($refreshed -and $refreshed.Token) {
                Set-SessionToken -NewToken $refreshed
                $null = Save-SessionToken -TokenObject $refreshed -ProfileName $script:ActiveProfile.AuthTokenProfile
                Write-CyberArkLog -Level 'INFO' -Message 'Automation mode: token silently refreshed mid-run.'
                return $true
            }
        } catch {
            Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: silent token refresh failed: $_"
        }
        return $false
    }

    # ISPSS: ClientCredentials refreshes silently; all other ISPSS methods prompt first
    if ($type -eq 'ISPSS') {
        if ($method -ne 'ClientCredentials') {
            $ispssCtx  = if ($script:SessionToken.PSObject.Properties['_RefreshContext']) { $script:SessionToken._RefreshContext } else { $null }
            $ispssUser = if ($ispssCtx -and $ispssCtx['Credential']) { $ispssCtx['Credential'].UserName } elseif ($script:ActiveProfile.Username) { $script:ActiveProfile.Username } else { '' }
            Write-Host ''
            Write-Host '  Your session token has expired. Re-authentication required.' -ForegroundColor Yellow
            if ($ispssUser) { Write-Host "  Signing in as: $ispssUser" -ForegroundColor Cyan }
            Write-Host '  Press Enter to re-authenticate, or X to exit: ' -ForegroundColor White -NoNewline
            $r = (Read-Host).Trim()
            if ($r -match '^[Xx]$') { return $false }
        } else {
            Write-CyberArkLog -Message 'Silently refreshing ISPSS ClientCredentials token.' -Level 'INFO'
        }
        # K17: a human is actively waiting for this re-auth (or it's the always-silent
        # ClientCredentials method, where honoring the hint is equally correct) - wait out
        # CyberArk Identity's own RetryWaitingTime rather than attempting into a likely
        # soft-lockout rejection.
        $throttleSec = Get-ISPSSAuthThrottle -AuthTokenProfileName $script:ActiveProfile.AuthTokenProfile -ProfileDir $script:ProfileDir
        if ($throttleSec -gt 0) {
            Write-Host "  CyberArk Identity asked us to wait before retrying - waiting $throttleSec more second(s)..." -ForegroundColor Yellow
            Start-Sleep -Seconds $throttleSec
        }
        try {
            $refreshed = Update-ISPSSAuthToken -TokenObject $script:SessionToken
            if ($refreshed -and $refreshed.Token) {
                Set-SessionToken -NewToken $refreshed
                $null = Save-SessionToken -TokenObject $refreshed -ProfileName $script:ActiveProfile.AuthTokenProfile
                Write-CyberArkLog -Message 'Token refreshed successfully.' -Level 'INFO'
                return $true
            }
        } catch {
            Write-CyberArkLog -Message "Token refresh failed: $_" -Level 'ERROR'
            Write-Host "  Authentication failed: $_" -ForegroundColor Red
        }
        return $false
    }

    # SelfHosted password methods: prompt for password only (re-uses stored username and URL)
    if ($type -eq 'SelfHosted' -and $method -in @('CyberArk', 'LDAP', 'RADIUS')) {
        $ctx = if ($script:SessionToken.PSObject.Properties['_RefreshContext']) { $script:SessionToken._RefreshContext } else { $null }
        # The active profile's current Base URL always wins over the token's own (possibly stale -
        # Testing_Findings-and-Known-Issues.md K04) one, since this re-auth is effectively a fresh login anyway; only
        # fall back to the token's stored URL if the profile's own can't be resolved.
        $pvwaUrl  = Get-ExpectedTokenBaseURL -DriverProfile $script:ActiveProfile
        if (-not $pvwaUrl) { $pvwaUrl = if ($ctx -and $ctx['PVWAUrl']) { $ctx['PVWAUrl'] } else { $script:SessionToken.BaseURL } }
        # K07: mirrors the ISPSS branch above's identical fallback - without it, a token whose
        # _RefreshContext has no captured Credential (an older saved session, or one restored
        # without it) forces an extra "Username" prompt even when the profile already has one set.
        $username = if ($ctx -and $ctx['Credential']) { $ctx['Credential'].UserName } elseif ($script:ActiveProfile.Username) { $script:ActiveProfile.Username } else { '' }

        Write-Host ''
        Write-Host '  Your session token has expired. Re-authentication required.' -ForegroundColor Yellow
        if ($username) { Write-Host "  Signing in as: $username" -ForegroundColor Cyan }
        Write-Host '  Press Enter to enter your password, or X to exit: ' -ForegroundColor White -NoNewline
        $r = (Read-Host).Trim()
        if ($r -match '^[Xx]$') { return $false }

        try {
            $securePassword = Read-Host -AsSecureString "  Password$(if ($username) { " for $username" })"
            $uname      = if ($username) { $username } else { (Read-Host '  Username').Trim() }
            $newCred    = [System.Management.Automation.PSCredential]::new($uname, $securePassword)
            $concurrent = if ($ctx -and $ctx.ContainsKey('ConcurrentSession')) { $ctx['ConcurrentSession'] } else { $false }
            $newToken   = Get-SelfHostedAuthToken `
                -AuthMethod        $method `
                -PVWAUrl           $pvwaUrl `
                -Credential        $newCred `
                -ConcurrentSession:([switch]::new($concurrent)) `
                -IgnoreSSL:        $script:ActiveProfile.IgnoreSSL
            if ($newToken -and $newToken.Token) {
                Set-SessionToken -NewToken $newToken
                $null = Save-SessionToken -TokenObject $newToken -ProfileName $script:ActiveProfile.AuthTokenProfile
                Write-CyberArkLog -Message 'Re-authentication successful.' -Level 'INFO'
                return $true
            }
        } catch {
            Write-CyberArkLog -Message "Re-authentication failed: $_" -Level 'ERROR'
            Write-Host "  Authentication failed: $_" -ForegroundColor Red
        }
        return $false
    }

    # All other SelfHosted methods (Shared, PKI, PKIPN, SAML, OIDC) - re-auth via stored context
    Write-Host ''
    Write-Host '  Your session token has expired. Re-authentication required.' -ForegroundColor Yellow
    Write-Host '  Press Enter to re-authenticate, or X to exit: ' -ForegroundColor White -NoNewline
    $r = (Read-Host).Trim()
    if ($r -match '^[Xx]$') { return $false }

    try {
        $newToken = Update-SelfHostedAuthToken -TokenObject $script:SessionToken
        if ($newToken -and $newToken.Token) {
            Set-SessionToken -NewToken $newToken
            $null = Save-SessionToken -TokenObject $newToken -ProfileName $script:ActiveProfile.AuthTokenProfile
            Write-CyberArkLog -Message 'Re-authentication successful.' -Level 'INFO'
            return $true
        }
    } catch {
        Write-CyberArkLog -Message "Re-authentication failed: $_" -Level 'ERROR'
        Write-Host "  Authentication failed: $_" -ForegroundColor Red
    }
    return $false
}

function Invoke-SelfHostedKeepalive {
    if ($script:SessionToken.SystemType -ne 'SelfHosted') { return }
    $remaining = Get-TokenRemainingMinutes
    if ($remaining -gt 2) { return }

    Write-CyberArkLog -Message 'SelfHosted token near expiry - attempting keepalive via Get Logged On User.' -Level 'INFO'
    try {
        $resp = Invoke-CyberArkAPI -Token $script:SessionToken -Method 'GET' `
            -Endpoint '/API/LoggedOnUser' -PageSize 0 -IgnoreSSL:$script:ActiveProfile.IgnoreSSL -NotUserActivity
        if ($resp.IsSuccess) {
            $script:SessionToken.Expiry = (Get-Date).ToUniversalTime().AddMinutes($script:PVWA_SESSION_EXPIRY_MIN)
            # Persist the extended expiry, matching every sibling refresh path
            # (Invoke-ProactiveRefresh, Invoke-TokenRefresh) - without this, the on-disk .cred
            # file's Expiry goes stale after a successful keepalive, understating how long the
            # session is actually still good for (e.g. in the profile list's token-status display).
            $null = Save-SessionToken -TokenObject $script:SessionToken -ProfileName $script:ActiveProfile.AuthTokenProfile
            Write-CyberArkLog -Message 'Keepalive succeeded. Token expiry extended.' -Level 'INFO'
        } else {
            Write-CyberArkLog -Message "Keepalive call failed ($($resp.StatusCode)): $($resp.ErrorMessage)" -Level 'WARN'
        }
    } catch {
        Write-CyberArkLog -Message "Keepalive error: $_" -Level 'WARN'
    }
}

function Invoke-SessionLogoff {
    if (-not $script:SessionToken) { return }
    if ($script:SessionToken.SystemType -eq 'SelfHosted') {
        Write-CyberArkLog -Message 'Logging off Self-Hosted PVWA session.' -Level 'INFO'
        try {
            Invoke-CyberArkAPI -Token $script:SessionToken -Method 'POST' `
                -Endpoint '/API/auth/Logoff' -IgnoreSSL:$script:ActiveProfile.IgnoreSSL -NotUserActivity | Out-Null
        } catch {
            Write-CyberArkLog -Message "Logoff request failed (session may already be expired): $_" -Level 'WARN'
        }
    }
    $script:SessionToken = $null
}

function Invoke-TokenValidate {
    # Makes one quick authenticated call to confirm the server still accepts the token.
    # Self-Hosted: GET /API/LoggedOnUser. ISPSS has no dedicated validation endpoint in use here, so
    # it uses GET /API/Safes?limit=1 (unpaginated): a one-row read on an endpoint every module
    # already relies on for both systems, which any authenticated user gets a 200 from (an empty
    # list if they're a member of no safes). A 401 means the token is rejected; StatusCode 0 means
    # no connection. Returns the API response object, or $null if the call throws.
    # Note: the startup callers skip this for ISPSS (they trust local expiry there); the ISPSS
    # branch is used by the Export All re-check after a sub-module reports IsFatal.
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [bool]$IgnoreSSL = $false
    )
    try {
        if ($Token.SystemType -eq 'ISPSS') {
            return Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/Safes' `
                -QueryParams @{ limit = 1 } -PageSize 0 -IgnoreSSL:$IgnoreSSL -NotUserActivity
        }
        return Invoke-CyberArkAPI -Token $Token -Method 'GET' `
            -Endpoint '/API/LoggedOnUser' -PageSize 0 -IgnoreSSL:$IgnoreSSL -NotUserActivity
    } catch {
        Write-CyberArkLog -Message "Token validation call failed: $_" -Level 'WARN'
        return $null
    }
}

function Invoke-TokenInvalidate {
    # Deletes the saved .cred file and force-expires the in-memory token so the
    # session loop immediately triggers re-authentication on its next iteration.
    if ($script:ActiveProfile) {
        $tokenPath = Get-ProfileTokenPath -Name $script:ActiveProfile.AuthTokenProfile
        if (Test-Path -LiteralPath $tokenPath) {
            Remove-Item -LiteralPath $tokenPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($script:SessionToken) {
        $script:SessionToken.Expiry = [DateTime]::UtcNow.AddHours(-1)
    }
    Write-CyberArkLog -Message '401 Unauthorized - session token invalidated and file removed.' -Level 'WARN'
}

function Set-SessionToken {
    # Assigns a refreshed token to $script:SessionToken, copying any NoteProperties
    # (e.g. MaxResults injected from the profile limit) so they survive token renewal.
    param([PSCustomObject]$NewToken)
    if ($script:SessionToken) {
        foreach ($np in @($script:SessionToken.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' })) {
            if (-not $NewToken.PSObject.Properties[$np.Name]) {
                try { $NewToken | Add-Member -NotePropertyName $np.Name -NotePropertyValue $np.Value -Force } catch { }
            }
        }
    }
    $script:SessionToken = $NewToken
}

#endregion
