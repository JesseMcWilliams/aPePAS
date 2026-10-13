<#
    Manage-Privilege.ps1 driver part: profile connect and the profile management loop.
    Dot-sourced by Manage-Privilege.ps1 (Driver Parts region) into its script scope; not run on its own.
#>

#region --- Main currentProfile Management Loop ---

function Invoke-ProfileConnect {
    <#
        Authenticates to the given profile and, on success, sets $script:SessionToken /
        $script:ActiveProfile / $script:WhatIfMode and returns the profile name for the caller to
        start the session loop; returns $null on any failure (incomplete profile, auth error, no
        token returned). Extracted from the profile-detail menu's 'C' (Connect) case so both the
        interactive menu and -StartProfile/-AutoConnect at startup share one authentication path.
    #>
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$Summary,
        [Parameter(Mandatory = $true)] [string[]]$Breadcrumbs,

        # Suppresses the "Press Enter to..." pauses on failure paths - used by the unattended
        # -AutoConnect startup path, which falls back to the normal interactive menu immediately
        # rather than blocking on Read-Host with no one present to press it. Interactive callers
        # (the profile-detail menu's 'C' case) leave this off, preserving today's behavior exactly.
        [switch]$NoPause
    )

    $missingSystemType = [string]::IsNullOrWhiteSpace($Summary.currentProfile.SystemType)
    $missingBaseURL    = [string]::IsNullOrWhiteSpace($Summary.currentProfile.BaseURL)
    if ($missingSystemType -or $missingBaseURL) {
        Write-Host '  Cannot connect: Base URL is required. Use [E]dit to add it first.' -ForegroundColor Red
        Start-Sleep -Seconds 2
        return $null
    }
    # Continue to session - authenticate and return token
    $selectedProfile = $Summary.currentProfile
    $selectedProfile.LastUsed = (Get-Date).ToUniversalTime().ToString('o')
    Save-DriverProfile -currentProfile $selectedProfile

    $xmlPath = Get-ProfileTokenPath -Name $selectedProfile.AuthTokenProfile
    $token   = $null

    if (Test-Path -LiteralPath $xmlPath) {
        # A token made with another sign-in method than the profile's current one is never refreshed
        # or reused: its refresh would sign in the old way, prefilled with the old username (F104).
        $savedToken = $null
        try { $savedToken = Import-AuthToken -Path $xmlPath -IgnoreExpiry } catch { $savedToken = $null }
        $methodChanged = $savedToken -and (Test-TokenAuthMethodStale -Token $savedToken -DriverProfile $selectedProfile)
        $savedToken = $null
        if ($methodChanged) {
            Write-CyberArkLog -Level 'WARN' -Message "Profile '$($selectedProfile.ProfileName)': the saved session was made with another authentication method or system type than the profile now uses (AuthMethod '$($selectedProfile.AuthMethod)'). Discarding it; a fresh login is required."
            if (-not $script:AutomationMode) {
                Write-Host "  The profile's authentication method has changed since this session was saved - a fresh login is required." -ForegroundColor Yellow
            }
        }
        try {
            if ($methodChanged) {
                # $token stays $null: the fresh-login path below uses the profile's own method.
            } elseif ($Summary.TokenStatus -eq 'Valid') {
                # Token known-good - load directly, no refresh needed...
                $token = Import-AuthToken -Path $xmlPath

                # ...unless it's old. A token can be well inside its expiry window
                # but still have sat unused for hours - refresh it now, at logon,
                # rather than starting the session on a stale token and waiting for
                # Invoke-ProactiveRefresh (which only fires near expiry, and only
                # for ClientCredentials).
                if ($token -and $token.PSObject.Properties['Created'] -and $token.Created) {
                    $ageMinutes = ([DateTime]::UtcNow - $token.Created).TotalMinutes
                    if ($ageMinutes -gt $script:LogonTokenMaxAgeMin) {
                        # K17: a CyberArk Identity soft lockout (confirmed live) can be tripped by
                        # repeated authentication attempts within its own RetryWaitingTime window -
                        # this age-based refresh fires on every single automation-mode run once a
                        # token crosses the age threshold, so skip it entirely (rather than making
                        # another doomed attempt) when a prior attempt's throttle hasn't elapsed
                        # yet; the existing, still-locally-valid token is used as-is either way.
                        $throttleSec = if ($token.SystemType -eq 'ISPSS') {
                            Get-ISPSSAuthThrottle -AuthTokenProfileName $selectedProfile.AuthTokenProfile -ProfileDir $script:ProfileDir
                        } else { 0 }
                        if ($throttleSec -gt 0) {
                            Write-CyberArkLog -Message "Logon-phase age-based refresh skipped: CyberArk Identity asked us to wait $throttleSec more second(s) before the next authentication attempt (Testing_Findings-and-Known-Issues.md K17). Using the existing token as-is." -Level 'INFO'
                        } else {
                            Write-Host "  Saved token is $([int]$ageMinutes) minute(s) old - refreshing..." -ForegroundColor DarkGray
                            try {
                                if ($script:AutomationMode) {
                                    Use-StoredCredentialIfMissing -Token $token -AuthTokenProfileName $selectedProfile.AuthTokenProfile
                                }
                                $refreshed = if ($token.SystemType -eq 'ISPSS') {
                                    Update-ISPSSAuthToken -TokenObject $token -NoPrompt:$script:AutomationMode
                                } else {
                                    Update-SelfHostedAuthToken -TokenObject $token -NoPrompt:$script:AutomationMode
                                }
                                if ($refreshed -and $refreshed.Token) { $token = $refreshed }
                            } catch {
                                Write-CyberArkLog -Message "Logon-phase age-based refresh failed: $_" -Level 'WARN'
                                # Keep using the existing, still-valid-but-old token rather than failing logon
                            }
                        }
                    }
                }
            } elseif ($Summary.TokenStatus -eq 'Expired') {
                # Load the token and attempt a refresh appropriate to its SystemType
                $expiredToken = Import-AuthToken -Path $xmlPath -IgnoreExpiry
                if ($expiredToken) {
                    # K17: skip a doomed refresh attempt if CyberArk Identity's own RetryWaitingTime
                    # hasn't elapsed yet - same rationale as the age-based refresh block above.
                    # $token is left $null either way, falling through to the existing "no token"
                    # handling below exactly as if this refresh attempt had failed normally.
                    $throttleSec = if ($expiredToken.SystemType -eq 'ISPSS') {
                        Get-ISPSSAuthThrottle -AuthTokenProfileName $selectedProfile.AuthTokenProfile -ProfileDir $script:ProfileDir
                    } else { 0 }
                    if ($throttleSec -gt 0) {
                        Write-CyberArkLog -Message "Expired-token refresh skipped: CyberArk Identity asked us to wait $throttleSec more second(s) before the next authentication attempt (Testing_Findings-and-Known-Issues.md K17)." -Level 'INFO'
                    } else {
                        try {
                            Write-Host '  Token expired, refreshing...' -ForegroundColor DarkGray
                            if ($script:AutomationMode) {
                                Use-StoredCredentialIfMissing -Token $expiredToken -AuthTokenProfileName $selectedProfile.AuthTokenProfile
                            }
                            $token = if ($expiredToken.SystemType -eq 'ISPSS') {
                                Update-ISPSSAuthToken -TokenObject $expiredToken -NoPrompt:$script:AutomationMode
                            } else {
                                Update-SelfHostedAuthToken -TokenObject $expiredToken -NoPrompt:$script:AutomationMode
                            }
                        } catch {
                            Write-CyberArkLog -Message "Auto-refresh failed: $_" -Level 'WARN'
                            $token = $null
                        }
                    }
                }
            }
            # No Token / Unreadable: skip Import-AuthToken, go straight to fresh auth
        } catch {
            Write-CyberArkLog -Message "Failed to load the saved token. $_" -Level 'WARN'
        }

        # The profile's Base URL may have been edited since this token was saved/refreshed - a
        # token's own BaseURL is frozen at original login time and never reconciled automatically
        # (Testing_Findings-and-Known-Issues.md K04), and Invoke-CyberArkAPI builds every request from the token's
        # BaseURL, not the active profile's. Never trust/reuse a session against an unverified
        # server: discard it here so the code below falls straight through to a fresh,
        # interactive login against the profile's current URL - the one path already known to use
        # the right URL.
        if ($token -and (Test-TokenBaseURLStale -Token $token -DriverProfile $selectedProfile)) {
            $expectedUrl = Get-ExpectedTokenBaseURL -DriverProfile $selectedProfile
            Write-CyberArkLog -Level 'WARN' -Message "Profile '$($selectedProfile.ProfileName)': saved session's Base URL ('$($token.BaseURL)') no longer matches the profile's current Base URL ('$expectedUrl') - discarding it and requiring a fresh login."
            if (-not $script:AutomationMode) {
                Write-Host "  Profile's Base URL has changed since this session was saved - a fresh login is required." -ForegroundColor Yellow
            }
            $token = $null
        }

        # Validate the loaded token against the server before trusting it
        if ($token) {
            if ($token.SystemType -eq 'ISPSS') {
                Write-Host '  Privilege Cloud: token accepted based on local expiry.' -ForegroundColor DarkGray
            } else {
                Write-Host '  Validating token...' -ForegroundColor DarkGray
                $valResp = Invoke-TokenValidate -Token $token -IgnoreSSL:$selectedProfile.IgnoreSSL
                if ($valResp -and $valResp.IsSuccess) {
                    $logonUser = if ($valResp.Data -and $valResp.Data.PSObject.Properties['username']) {
                        " (as $($valResp.Data.username))"
                    } else { '' }
                    Write-Host "  Token verified$logonUser." -ForegroundColor Green
                } elseif ($valResp -and $valResp.StatusCode -eq 401) {
                    Write-Host '  Server rejected saved token (401). Please re-authenticate.' -ForegroundColor Yellow
                    Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
                    $token = $null
                }
                # Non-401 errors (network unreachable, etc.) - proceed with the loaded token
            }
        }
        # Ensure ISPSS BaseURL includes AppName (pre-fix saved tokens may lack it)
        if ($token -and $token.SystemType -eq 'ISPSS' -and $token.BaseURL) {
            $diskUri = [Uri]$token.BaseURL
            if (-not $diskUri.AbsolutePath -or $diskUri.AbsolutePath -eq '/') {
                $diskAppName = if ($selectedProfile.AppName) { $selectedProfile.AppName.Trim('/') } else { 'PasswordVault' }
                $token.BaseURL = "$($token.BaseURL.TrimEnd('/'))/$diskAppName"
            }
        }
    }

    if (-not $token) {
        # A fresh login with no inputs is interactive for every method: a password prompt
        # (CyberArk/LDAP/RADIUS), a certificate picker (PKI/PKIPN), a Client ID/Secret prompt
        # (ISPSS ClientCredentials), or a WebView2/MFA popup (SAML/OIDC/Interactive/SSO). So
        # automation mode only logs in fresh when Invoke-AutomationWithCredential.ps1 handed in a
        # credential (-Credential) for a method that needs nothing else; otherwise it exits here
        # with a clear reason - the "exit stating the issue, don't hang" contract.
        $driverLogin = $script:AutomationMode -and $script:AutomationCredential -and
            (Test-AutomationCredentialMethod -SystemType $selectedProfile.SystemType -AuthMethod $selectedProfile.AuthMethod)
        if ($script:AutomationMode -and -not $driverLogin) {
            $reason = switch ($Summary.TokenStatus) {
                'Expired'    { 'its saved token has expired and could not be silently refreshed' }
                'Unreadable' { 'its saved token could not be read (missing, corrupt, or restored from a different Windows user/machine)' }
                default      { 'it has no saved token' }
            }
            $msg = if ($script:AutomationCredential) {
                "Automation mode: profile '$($selectedProfile.ProfileName)' cannot log in unattended - $reason, and its auth method ($($selectedProfile.AuthMethod)) can't use a supplied credential. Supported: Self-Hosted CyberArk/LDAP/RADIUS, Privilege Cloud ClientCredentials/Interactive."
            } else {
                "Automation mode: profile '$($selectedProfile.ProfileName)' cannot be used unattended - $reason, and fresh authentication is interactive. Log in to this profile interactively once, or run it through Invoke-AutomationWithCredential.ps1."
            }
            Write-CyberArkLog -Message $msg -Level 'ERROR'
            Write-Host "  $msg" -ForegroundColor Red
            return $null
        }
        if ($driverLogin) {
            Write-CyberArkLog -Level 'INFO' -Message "Automation mode: logging in to '$($selectedProfile.ProfileName)' with the supplied credential ('$($script:AutomationCredential.UserName)') - $($Summary.TokenStatus) saved session."
        } else {
            Show-Header -Breadcrumbs ($Breadcrumbs + @('Authenticate'))
            $authStatusMsg = switch ($Summary.TokenStatus) {
                'Expired'    { 'Saved token has expired. Please re-authenticate.' }
                'Unreadable' { 'Could not read saved token. Please re-authenticate.' }
                default      { 'No saved token found. Please authenticate.' }
            }
            Write-Host "  $authStatusMsg" -ForegroundColor Yellow
            Write-Host ''
        }
        try {
            $appName = if ($selectedProfile.AppName) { $selectedProfile.AppName.Trim('/') } else { 'PasswordVault' }
            if ($selectedProfile.SystemType -eq 'Privilege Cloud') {
                $authParams = @{}
                if ($selectedProfile.AuthMethod) { $authParams['AuthMethod'] = $selectedProfile.AuthMethod }
                if ($selectedProfile.Username)   { $authParams['Username']   = $selectedProfile.Username }
                if ($selectedProfile.BaseURL -match '^https://(.+)\.privilegecloud\.cyberark\.cloud') {
                    $authParams['PCloudSubdomain'] = $Matches[1]
                }
                if ($selectedProfile.PSObject.Properties['TenantAuth'] -and $selectedProfile.TenantAuth) {
                    $authParams['IdentityTenantURL'] = $selectedProfile.TenantAuth
                }
                # Testing_Findings-and-Known-Issues.md K11: makes Import-WebView2Assembly's own "specify
                # -WebView2AssemblyPath" error message actually actionable through the driver -
                # only consulted for the SSO method, and only as a last resort after every other
                # candidate path already fails.
                if ($selectedProfile.PSObject.Properties['WebView2AssemblyPath'] -and $selectedProfile.WebView2AssemblyPath) {
                    $authParams['WebView2AssemblyPath'] = $selectedProfile.WebView2AssemblyPath
                }
                $authParams['AuthTokenProfileName'] = $selectedProfile.AuthTokenProfile
                $authParams['ProfileDir']           = $script:ProfileDir
                # K17: honor CyberArk Identity's RetryWaitingTime hint. A person waits it out here;
                # an unattended driver login fails instead of sleeping or adding another attempt.
                $throttleSec = Get-ISPSSAuthThrottle -AuthTokenProfileName $selectedProfile.AuthTokenProfile -ProfileDir $script:ProfileDir
                if ($throttleSec -gt 0) {
                    if ($driverLogin) {
                        throw "CyberArk Identity asked us to wait $throttleSec more second(s) before the next authentication attempt (K17). Try the run again later."
                    }
                    Write-Host "  CyberArk Identity asked us to wait before retrying - waiting $throttleSec more second(s)..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $throttleSec
                }
                if ($driverLogin) {
                    if ($selectedProfile.AuthMethod -eq 'ClientCredentials') {
                        $authParams['ClientId']     = $script:AutomationCredential.UserName
                        $authParams['ClientSecret'] = $script:AutomationCredential.Password
                    } else {
                        $authParams['Username']   = $script:AutomationCredential.UserName
                        $authParams['Credential'] = $script:AutomationCredential
                        $authParams['NoPrompt']   = $true
                    }
                }
                $token = Get-ISPSSAuthToken @authParams
            } elseif ($selectedProfile.SystemType -eq 'Self-Hosted') {
                $authParams = @{ IgnoreSSL = $selectedProfile.IgnoreSSL }
                if ($selectedProfile.AuthMethod) { $authParams['AuthMethod'] = $selectedProfile.AuthMethod }
                if ($selectedProfile.Username)   { $authParams['Username']   = $selectedProfile.Username }
                if ($selectedProfile.BaseURL) {
                    $authParams['PVWAUrl'] = "$($selectedProfile.BaseURL.TrimEnd('/'))/$appName"
                }
                if ($selectedProfile.PSObject.Properties['WebView2AssemblyPath'] -and $selectedProfile.WebView2AssemblyPath) {
                    $authParams['WebView2AssemblyPath'] = $selectedProfile.WebView2AssemblyPath
                }
                if ($driverLogin) { $authParams['Credential'] = $script:AutomationCredential }
                $token = Get-SelfHostedAuthToken @authParams
            } else {
                throw "Profile SystemType '$($selectedProfile.SystemType)' is not configured. Edit the profile to set it."
            }
            # If user entered credentials, save username back to profile for next-login pre-fill.
            # Not for a driver login: the supplied credential doesn't change the profile.
            if (-not $driverLogin -and $token -and $token._RefreshContext -and $token._RefreshContext['Credential']) {
                $enteredUser = $token._RefreshContext['Credential'].UserName
                if ($enteredUser -and $enteredUser -ne $selectedProfile.Username) {
                    $selectedProfile.Username = $enteredUser
                    Save-DriverProfile -currentProfile $selectedProfile
                }
            }
        } catch {
            $caughtAuthError = $_   # capture before any expression that could overwrite $_
            $urlInfo = if ($selectedProfile.SystemType -eq 'Self-Hosted' -and $selectedProfile.BaseURL) {
                $an = if ($selectedProfile.AppName) { $selectedProfile.AppName.Trim('/') } else { 'PasswordVault' }
                " [URL: $($selectedProfile.BaseURL.TrimEnd('/'))/$an]"
            } else { '' }
            Write-Host "  Authentication failed$($urlInfo): $caughtAuthError" -ForegroundColor Red
            Write-CyberArkLog -Message "Authentication failed for profile '$($selectedProfile.ProfileName)'$($urlInfo): $caughtAuthError" -Level 'ERROR'
            if (-not $NoPause) {
                Write-Host '  Press Enter to return to profile selection.' -ForegroundColor DarkGray
                Read-Host | Out-Null
            }
            return $null
        }
    }

    if ($token -and $token.Token) {
        # Persist the (possibly refreshed) token
        try {
            $null = Save-SessionToken -TokenObject $token -ProfileName $selectedProfile.AuthTokenProfile
        } catch {
            Write-CyberArkLog -Message "Could not save the refreshed token. $_" -Level 'WARN'
        }

        # Display token details as informational output before entering session
        Write-Host ''
        $tokenUsername = ''
        if ($token.PSObject.Properties['_RefreshContext'] -and $token._RefreshContext) {
            $rc = $token._RefreshContext
            if ($rc.PSObject.Properties['Credential'] -and $rc.Credential) {
                $tokenUsername = $rc.Credential.UserName
            }
        }
        if (-not $tokenUsername -and $selectedProfile.Username) {
            $tokenUsername = $selectedProfile.Username
        }
        if ($tokenUsername) {
            Write-Host ("    Signed in as : $tokenUsername") -ForegroundColor Cyan
        }
        $sysLabel = switch ($token.SystemType) {
            'ISPSS'      { 'Privilege Cloud' }
            'SelfHosted' { 'Self-Hosted' }
            default      { if ($token.PSObject.Properties['SystemType']) { $token.SystemType } else { '' } }
        }
        if ($sysLabel) { Write-Host ("    System       : $sysLabel") -ForegroundColor Cyan }
        if ($token.PSObject.Properties['AuthMethod'] -and $token.AuthMethod) {
            Write-Host ("    Auth Method  : $($token.AuthMethod)") -ForegroundColor Cyan
        }
        if ($token.PSObject.Properties['BaseURL'] -and $token.BaseURL) {
            Write-Host ("    Base URL     : $($token.BaseURL)") -ForegroundColor Cyan
        }
        if ($token.PSObject.Properties['Expiry'] -and $token.Expiry) {
            $expiryStr = try {
                ([datetime]$token.Expiry).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
            } catch { "$($token.Expiry)" }
            Write-Host ("    Token Expiry : $expiryStr") -ForegroundColor Cyan
        }
        Write-Host ''

        Invoke-ClearNonRefreshableContext -Token $token
        $script:SessionToken  = $token
        $script:ActiveProfile = $selectedProfile
        $script:WhatIfMode    = $selectedProfile.WhatIfDefault -or $script:WhatIfMode
        # Inject profile page size into token so Invoke-CyberArkAPI can apply it per paginated request
        $profileLimit = 0
        if ($selectedProfile.PSObject.Properties['Limit']) {
            try { $profileLimit = [int]$selectedProfile.Limit } catch { }
        }
        if ($profileLimit -gt 0) {
            $script:SessionToken | Add-Member -NotePropertyName 'PageSize' -NotePropertyValue $profileLimit -Force
        }

        # Persist discovered identity URL back to profile so future logins skip rediscovery
        if ($token.SystemType -eq 'ISPSS' -and $token.IdentityURL -and
            $token.IdentityURL -ne $selectedProfile.TenantAuth) {
            $selectedProfile.TenantAuth = $token.IdentityURL
            Save-DriverProfile -currentProfile $selectedProfile
        }

        # Return the profile name - caller starts the session loop
        return $selectedProfile.ProfileName
    }

    Write-Host '  Authentication returned no token.' -ForegroundColor Red
    if (-not $NoPause) {
        Write-Host '  Press Enter to return.' -ForegroundColor DarkGray
        Read-Host | Out-Null
    }
    return $null
}

function Invoke-ProfileManagementLoop {
    param(
        [string]$DefaultProfileName = '',

        # Skips the list/detail menus entirely and connects directly to $DefaultProfileName - see
        # the -AutoConnect launch parameter. Falls back to the normal interactive flow below (not
        # a hard failure) if the profile can't be found, is incomplete, or authentication fails.
        [switch]$AutoConnect
    )

    Initialize-ProfileDirectory

    # Seed the default selection from the stored IsDefault flag when none was passed in
    if (-not $DefaultProfileName) {
        $isDefaultEntry = @(Get-AllDriverProfiles) | Where-Object {
            $_.currentProfile.PSObject.Properties['IsDefault'] -and [bool]$_.currentProfile.IsDefault
        } | Select-Object -First 1
        if ($isDefaultEntry) { $DefaultProfileName = $isDefaultEntry.ProfileName }
    }

    $breadcrumbRoot = @('Profile Selection')
    $selected       = $null   # initialize so StrictMode doesn't throw if a branch skips setting it

    if ($AutoConnect.IsPresent -and $DefaultProfileName) {
        $autoMatch = @(Get-AllDriverProfiles) | Where-Object { $_.ProfileName -ieq $DefaultProfileName } | Select-Object -First 1
        if (-not $autoMatch) {
            Write-Host "  -AutoConnect: no profile named '$DefaultProfileName' was found. Falling back to profile selection." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        } else {
            $autoIncomplete = [string]::IsNullOrWhiteSpace($autoMatch.currentProfile.SystemType) -or
                              [string]::IsNullOrWhiteSpace($autoMatch.currentProfile.BaseURL)
            if ($autoIncomplete) {
                Write-Host "  -AutoConnect: profile '$DefaultProfileName' is incomplete (missing System Type or Base URL). Falling back to profile selection." -ForegroundColor Yellow
                Start-Sleep -Seconds 2
            } else {
                $autoResult = Invoke-ProfileConnect -Summary $autoMatch `
                    -Breadcrumbs ($breadcrumbRoot + @($autoMatch.ProfileName)) -NoPause
                if ($autoResult) { return $autoResult }
                Write-Host '  -AutoConnect failed. Falling back to profile selection.' -ForegroundColor Yellow
                Start-Sleep -Seconds 2
            }
        }
    }

    while ($true) {

        # --- currentProfile List ---
        $selectedProfiles = @(Get-AllDriverProfiles)
        Show-ProfileList -selectedProfiles $selectedProfiles -Breadcrumbs $breadcrumbRoot

        if (-not $selectedProfiles -or $selectedProfiles.Count -eq 0) {
            $choice = Read-MenuChoice -Prompt '[N] New    [X] Restore    [Q] Quit'
        } else {
            # Resolve the default profile name to its current 1-based list index
            $defaultIdx = 1
            if ($DefaultProfileName) {
                for ($i = 0; $i -lt $selectedProfiles.Count; $i++) {
                    if ($selectedProfiles[$i].ProfileName -ieq $DefaultProfileName) {
                        $defaultIdx = $i + 1
                        break
                    }
                }
            }
            $choice = Read-MenuChoice -Prompt "Number / [N]ew / [K]Backup / [X]Restore / [Q]uit (default: $defaultIdx)"
            if (-not $choice) { $choice = "$defaultIdx" }
        }

        switch -Regex ($choice.ToUpper()) {

            '^Q$' {
                Write-Host "`n  Goodbye.`n" -ForegroundColor DarkGray
                return $null   # Signal: exit
            }

            '^N$' {
                # --- Create new profile ---
                $blank = New-BlankProfile -Name ''
                $edited = Invoke-ProfileEditFlow -currentProfile $blank -Breadcrumbs ($breadcrumbRoot + @('New Profile')) -IsNew
                if ($edited) { $DefaultProfileName = $edited.ProfileName }
                continue
            }

            '^K$' {
                Invoke-ProfileBackupFlow -Breadcrumbs ($breadcrumbRoot + @('Backup'))
                continue
            }

            '^X$' {
                Invoke-ProfileRestoreFlow -Breadcrumbs ($breadcrumbRoot + @('Restore'))
                continue
            }

            '^\d+$' {
                $idx = [int]$choice - 1
                if ($idx -lt 0 -or $idx -ge $selectedProfiles.Count) {
                    Write-Host '  Invalid selection.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                    continue
                }
                $selected = $selectedProfiles[$idx]
                $DefaultProfileName = $selected.ProfileName
            }

            default {
                # Try matching by profile name (for Restart flow passing a name)
                $byName = $selectedProfiles | Where-Object { $_.ProfileName -ieq $choice }
                if ($byName) {
                    $selected = $byName[0]
                    $DefaultProfileName = $selected.ProfileName
                } else {
                    Write-Host '  Invalid input.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                    continue
                }
            }
        }

        # --- currentProfile Detail Loop ---
        if (-not $selected) { continue }   # guard: switch branch skipped assignment (StrictMode safety)
        $selectedProfileName = $selected.ProfileName
        $detailCrumbs        = $breadcrumbRoot + @($selectedProfileName)

        while ($true) {
            $selected = @(Get-AllDriverProfiles) | Where-Object { $_.ProfileName -eq $selectedProfileName }
            if (-not $selected) { break }   # currentProfile was deleted

            Show-ProfileDetail -Summary $selected -Breadcrumbs $detailCrumbs

            $missingSystemType = [string]::IsNullOrWhiteSpace($selected.currentProfile.SystemType)
            $missingBaseURL    = [string]::IsNullOrWhiteSpace($selected.currentProfile.BaseURL)
            $isIncomplete      = $missingSystemType -or $missingBaseURL
            if ($isIncomplete) {
                $missingFields = @()
                if ($missingSystemType) { $missingFields += 'System Type' }
                if ($missingBaseURL)    { $missingFields += 'Base URL' }
                Write-Host ''
                Write-Host ("  WARNING: Profile incomplete - missing: $($missingFields -join ', ').") -ForegroundColor Yellow
                Write-Host '  Choose E to edit it or D to delete this profile.' -ForegroundColor Yellow
            }

            $action = Read-MenuChoice -Prompt 'C / E / P / D / T / L / F / A / B / Q (default: C)'
            if (-not $action) { $action = 'C' }

            switch ($action.ToUpper()) {

                'C' {
                    $result = Invoke-ProfileConnect -Summary $selected -Breadcrumbs $detailCrumbs
                    if ($result) { return $result }
                }

                'E' {
                    # Edit profile
                    Invoke-ProfileEditFlow -currentProfile $selected.currentProfile `
                        -Breadcrumbs ($detailCrumbs + @('Edit'))
                }

                'F' {
                    # Toggle default profile flag
                    $isCurrentlyDefault = $selected.currentProfile.PSObject.Properties['IsDefault'] -and [bool]$selected.currentProfile.IsDefault
                    if ($isCurrentlyDefault) {
                        $selected.currentProfile.IsDefault = $false
                        Save-DriverProfile -currentProfile $selected.currentProfile
                        Write-CyberArkLog -Level 'INFO' -Message "Cleared default flag from profile '$($selected.ProfileName)'."
                        Write-Host "  '$($selected.ProfileName)' is no longer the default profile." -ForegroundColor Yellow
                    } else {
                        # Clear the previous default profile first
                        foreach ($other in (Get-AllDriverProfiles)) {
                            if ($other.ProfileName -ne $selected.ProfileName -and
                                $other.currentProfile.PSObject.Properties['IsDefault'] -and
                                [bool]$other.currentProfile.IsDefault) {
                                $other.currentProfile.IsDefault = $false
                                Save-DriverProfile -currentProfile $other.currentProfile
                                Write-CyberArkLog -Level 'DEBUG' -Message "Cleared default flag from profile '$($other.ProfileName)'."
                            }
                        }
                        $selected.currentProfile.IsDefault = $true
                        Save-DriverProfile -currentProfile $selected.currentProfile
                        Write-CyberArkLog -Level 'INFO' -Message "Profile '$($selected.ProfileName)' set as default."
                        Write-Host "  '$($selected.ProfileName)' is now the default profile." -ForegroundColor Green
                    }
                    Start-Sleep -Seconds 1
                }

                'P' {
                    # Copy profile - prompt for new name first
                    Show-Header -Breadcrumbs ($detailCrumbs + @('Copy'))
                    Write-Host '  Copy Profile' -ForegroundColor White
                    Write-Host ''
                    $newName = ''
                    while (-not $newName) {
                        $newName = Show-FieldPrompt -Label 'New Profile Name' -Required `
                            -Description 'Name for the copied profile.'
                        if (-not $newName) {
                            Write-Host '    Name is required.' -ForegroundColor Red
                        } elseif (Test-Path -LiteralPath (Get-ProfileJsonPath -Name $newName)) {
                            Write-Host "    A profile named '$newName' already exists." -ForegroundColor Red
                            $newName = ''
                        }
                    }
                    # Clone the profile object and give it the new name
                    $copy = $selected.currentProfile | ConvertTo-Json -Depth 5 | ConvertFrom-Json
                    $copy.ProfileName      = $newName
                    $copy.AuthTokenProfile = $newName
                    $copy.Created          = (Get-Date).ToUniversalTime().ToString('o')
                    $copy.LastUsed         = $null
                    $copy.IsDefault        = $false
                    # The copy starts with no saved session: clear any token file left at its name.
                    $copyTokenPath = Get-ProfileTokenPath -Name $newName
                    if (Test-Path -LiteralPath $copyTokenPath) { Remove-Item -LiteralPath $copyTokenPath -Force -ErrorAction SilentlyContinue }
                    # Save draft first so edit flow can check for existing file
                    Save-DriverProfile -currentProfile $copy
                    Invoke-ProfileEditFlow -currentProfile $copy -Breadcrumbs ($detailCrumbs + @("Copy to $newName"))
                    $DefaultProfileName = $newName
                    # Show the copy from here on. Before F104 the loop went back to the original
                    # profile, so Connect signed in to the original with its old session.
                    $selectedProfileName = $newName
                    $detailCrumbs        = $breadcrumbRoot + @($newName)
                }

                'D' {
                    # Delete profile
                    if (Confirm-Action "Delete profile '$($selected.ProfileName)' and its token file? This cannot be undone.") {
                        Remove-DriverProfile -Name $selected.ProfileName
                        Write-CyberArkLog -Message "Profile '$($selected.ProfileName)' deleted." -Level 'INFO'
                        Write-Host "  Profile deleted." -ForegroundColor Green
                        Start-Sleep -Seconds 1
                        break   # Back to profile list
                    }
                }

                'T' {
                    # Test connection
                    Invoke-ProfileTestConnection -Summary $selected `
                        -Breadcrumbs ($detailCrumbs + @('Test Connection'))
                }

                'L' {
                    # Log out - call server logoff and delete local token file
                    if ($selected.TokenStatus -notin @('Valid', 'Expired')) {
                        Write-Host '  No saved session token to log out.' -ForegroundColor DarkGray
                        Start-Sleep -Seconds 1
                    } else {
                        if (Confirm-Action "Log out '$($selected.ProfileName)' - end server session and delete saved token?") {
                            $tokenPath   = Get-ProfileTokenPath -Name $selected.currentProfile.AuthTokenProfile
                            $logoutToken = $null
                            try { $logoutToken = Import-AuthToken -Path $tokenPath } catch {}
                            if ($logoutToken -and $logoutToken.SystemType -eq 'SelfHosted') {
                                Write-Host '  Ending server session...' -ForegroundColor DarkGray
                                try {
                                    Invoke-CyberArkAPI -Token $logoutToken -Method 'POST' `
                                        -Endpoint '/API/auth/Logoff' -NotUserActivity `
                                        -IgnoreSSL:$selected.currentProfile.IgnoreSSL | Out-Null
                                } catch {
                                    Write-CyberArkLog -Message "Logoff request failed: $_" -Level 'WARN'
                                }
                            }
                            Remove-Item -LiteralPath $tokenPath -Force -ErrorAction SilentlyContinue
                            Write-CyberArkLog -Message "Logged out profile '$($selected.ProfileName)'. Token cleared." -Level 'INFO'
                            Write-Host '  Logged out. Token cleared.' -ForegroundColor Green
                            Start-Sleep -Seconds 1
                        }
                    }
                }

                'A' {
                    # Set/clear a stored credential used only as an automation-mode fallback for
                    # unattended session refreshes (SelfHosted CyberArk/LDAP/RADIUS only) when the
                    # saved token's own _RefreshContext has no usable credential - see
                    # Use-StoredCredentialIfMissing and Testing_Findings-and-Known-Issues.md K06. A one-time interactive
                    # setup step; automation mode itself never prompts here or anywhere else.
                    Show-Header -Breadcrumbs ($detailCrumbs + @('Automation Credential'))
                    $authProfileName = $selected.currentProfile.AuthTokenProfile
                    $credPath        = Get-ProfileCredentialPath -Name $authProfileName -ProfileDir $script:ProfileDir
                    $statusMsg = if (Test-Path -LiteralPath $credPath) {
                        $existing = Get-ProfileCredential -Name $authProfileName -ProfileDir $script:ProfileDir
                        if ($existing) { "A stored credential exists for user '$($existing.UserName)'." }
                        else { 'A stored credential file exists but could not be read here (different Windows user/machine, or corrupt).' }
                    } else { 'No stored credential is set for this profile.' }
                    Write-Host "  $statusMsg" -ForegroundColor DarkGray
                    Write-Host ''
                    Write-Host '  Used only as a fallback for unattended automation-mode session refreshes when' -ForegroundColor DarkGray
                    Write-Host '  the saved token itself has no usable credential (CyberArk/LDAP/RADIUS only).' -ForegroundColor DarkGray
                    Write-Host '  Automation mode never prompts - a cold-start login is always interactive,' -ForegroundColor DarkGray
                    Write-Host '  regardless of this setting.' -ForegroundColor DarkGray
                    Write-Host ''
                    Write-Host '  [S]et/replace    [C]lear    [B]ack' -ForegroundColor White
                    $credAction = Read-MenuChoice -Prompt '[S] / [C] / [B]ack (default: B)'
                    switch ($credAction.ToUpper()) {
                        'S' {
                            $newCred = Get-Credential -Message "Credential to store for profile '$($selected.ProfileName)' (used only for unattended refresh)"
                            if ($newCred) {
                                Save-ProfileCredential -Name $authProfileName -Credential $newCred -ProfileDir $script:ProfileDir | Out-Null
                                Write-CyberArkLog -Level 'INFO' -Message "Stored automation credential set for profile '$($selected.ProfileName)'."
                                Write-Host '  Credential stored.' -ForegroundColor Green
                                Start-Sleep -Seconds 1
                            }
                        }
                        'C' {
                            if (Confirm-Action 'Remove the stored credential for this profile?') {
                                Remove-ProfileCredential -Name $authProfileName -ProfileDir $script:ProfileDir
                                Write-CyberArkLog -Level 'INFO' -Message "Stored automation credential removed for profile '$($selected.ProfileName)'."
                                Write-Host '  Removed.' -ForegroundColor Green
                                Start-Sleep -Seconds 1
                            }
                        }
                        default {}
                    }
                }

                { $_ -match '^B\d*$' } {
                    # B# navigation - B = back 1, B2 = back 2, etc.
                    $levels = if ($_ -eq 'B') { 1 } else { [int]($_ -replace '^B', '') }
                    if ($levels -ge 1) { break }   # Back to profile list
                }

                'Q' {
                    if ($selected.TokenStatus -eq 'Valid') {
                        if (Confirm-Action "Valid saved token for '$($selected.ProfileName)' exists. Clear it before quitting?") {
                            $tokenPath = Get-ProfileTokenPath -Name $selected.currentProfile.AuthTokenProfile
                            Remove-Item -LiteralPath $tokenPath -Force -ErrorAction SilentlyContinue
                            Write-CyberArkLog -Message "Token cleared for '$($selected.ProfileName)' on quit." -Level 'INFO'
                            Write-Host '  Token cleared.' -ForegroundColor Green
                            Start-Sleep -Seconds 1
                        }
                    }
                    return $null
                }

                default {
                    Write-Host '  Invalid option.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                }
            }

            # If we broke out of the inner switch (Delete or Back), exit detail loop
            if ($action.ToUpper() -in 'D' -or $action.ToUpper() -match '^B\d*$') { break }
        }

    }   # while profile list loop
}

#endregion
