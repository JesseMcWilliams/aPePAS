#Requires -Version 5.1
<#
.SYNOPSIS
    aPePAS - CyberArk PAS interactive driver.

.DESCRIPTION
    Profile-managed, authenticated sessions for CyberArk ISPSS (Privilege Cloud SaaS)
    and Self-Hosted PAM. Provides profile management, categorized API action menus,
    CSV bulk processing, and robust session logging.

.PARAMETER StartProfile
    Pre-select a profile by name at the profile list screen (used internally by the Restart flow).
    Combine with -AutoConnect to skip the menus entirely and connect directly.

.PARAMETER AutoConnect
    Requires -StartProfile. Skips the profile list/detail menus entirely and connects directly to
    the named profile - useful for scripted/scheduled launches. Applies only on the initial launch,
    not on a later Restart (which always returns to the profile list, matching existing behavior).
    On any failure (profile not found, incomplete, or authentication error), falls back to the
    normal interactive profile list rather than exiting.

.PARAMETER Category
    Requires -StartProfile and -Action together. Runs one module action non-interactively and
    exits - no menus, no prompts. Without -Credential, requires the named profile to already have
    a valid, refreshable saved session (has been authenticated interactively at least once), and
    exits with a clear message instead of attempting a cold-start login. With -Credential (normally
    passed by Invoke-AutomationWithCredential.ps1), a missing or expired session is replaced by a
    fresh, non-interactive login for the methods that need only a credential (see -Credential).
    If anything else would normally require interaction, this exits
    stating the issue rather than waiting for input that will never come. See User_Docs\User-Guide.md
    for the full automation contract and exit code meanings.

.PARAMETER Action
    Requires -Category. The action within that category to run (e.g. Category=Safes, Action=Add).

.PARAMETER InputFile
    Automation mode only. Path to a CSV file, for a module that accepts CSV input
    (ModuleMeta.AcceptsInputFile). Mutually exclusive with -InputJson.

.PARAMETER InputJson
    Automation mode only. A literal JSON string, or a path to a .json file, providing the single
    item's InputData. Mutually exclusive with -InputFile. If neither -InputFile nor -InputJson is
    given, InputData defaults to an empty set and the module's own field validation reports any
    missing required value as a normal failure.

.PARAMETER OutputFolder
    Automation mode only. Overrides the active profile's own OutputFolder for this run's saved
    CSV(s) - the folder is created if it does not already exist. Applies to every
    ModuleMeta.ProducesOutput module run via -Category/-Action (including Custom's Export
    Entitlements/Export Group Members/Export Platform Details), and to Custom/ExportAll's own
    per-sub-report files (which keep their existing fixed names either way - see -FilenameFormat).

.PARAMETER FilenameFormat
    Automation mode only. Overrides the default saved CSV filename ("<Module Name> <yyyy-MM-dd>.csv")
    for a single-file ProducesOutput module. A template string supporting {ModuleName}, {Category},
    {Action}, {Profile}, and {Date} (yyyy-MM-dd) - e.g. '{Profile}_{ModuleName}_{Date}'. The '.csv'
    extension is added automatically if not already present. Not applied to Custom/ExportAll, whose
    output is inherently one file per sub-report rather than a single name.

.PARAMETER JobFile
    Automation mode with several steps: a JSON job file listing actions to run one after another
    under a single login to -StartProfile (instead of -Category/-Action). Each step has Category and
    Action, and optionally InputFile, InputJson (string or object), OutputFolder, FilenameFormat,
    WhatIf and StopOnFailure; the top level may set StopOnFailure for every step. Relative paths
    are relative to the job file's folder. The whole file is checked before logging in. The exit
    code is the worst step's (3 > 2 > 0); a step that ends the session stops the job. See
    JobFile.example.json and User_Docs\User-Guide.md.

.PARAMETER Credential
    Automation mode only. A credential supplied in memory, normally by
    Invoke-AutomationWithCredential.ps1 (which resolves it through aPeSecrets). Used for a fresh
    login when the profile has no usable saved session, and for any token refresh during the run,
    in place of the profile's stored .autocred. Supported methods: Self-Hosted CyberArk, LDAP and
    RADIUS (username and password); Privilege Cloud ClientCredentials (username = client ID,
    password = client secret) and Interactive (password-only, no MFA). Other methods exit 3. The
    credential's secret is never written to the saved session file.

.PARAMETER WhatIf
    Enable WhatIf mode for the session (suppresses all write/modify/delete API calls).

.PARAMETER LogLevel
    Minimum log level written to the log file and console. Valid values: VERBOSE, DEBUG, INFO, WARN, ERROR.
    Defaults to INFO.

.PARAMETER LogFolder
    Default folder for log files when the active profile does not specify one.
    Defaults to a 'Logs' subfolder of the folder this script is in.
#>
[CmdletBinding()]
param(
    [string]$StartProfile,
    [switch]$AutoConnect,
    [string]$Category,
    [string]$Action,
    [string]$InputFile,
    [string]$InputJson,
    [string]$OutputFolder,
    [string]$FilenameFormat,
    [string]$JobFile,
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$WhatIf,
    [ValidateSet('VERBOSE', 'DEBUG', 'INFO', 'WARN', 'ERROR')]
    [string]$LogLevel = 'INFO',
    [string]$LogFolder
)

if ($AutoConnect.IsPresent -and -not $StartProfile) {
    throw '-AutoConnect requires -StartProfile <name>.'
}

# Automation mode: run one module action non-interactively and exit. See
# User_Docs\User-Guide.md for the exit-code contract (0 success / 1 crash / 2 partial failure /
# 3 could not run) and Invoke-AutomatedAction below for the entry point itself.
if (($Category -and -not $Action) -or ($Action -and -not $Category)) {
    throw '-Category and -Action must be supplied together.'
}
if ($Category -and -not $StartProfile) {
    throw '-Category/-Action require -StartProfile <name>.'
}
if ($InputFile -and $InputJson) {
    throw '-InputFile and -InputJson are mutually exclusive.'
}
if ($JobFile -and ($Category -or $Action -or $InputFile -or $InputJson)) {
    throw '-JobFile replaces -Category/-Action/-InputFile/-InputJson; put those in the job file''s steps.'
}
if ($JobFile -and -not $StartProfile) {
    throw '-JobFile requires -StartProfile <name>.'
}
if ($Credential -and -not (($Category -and $Action) -or $JobFile)) {
    throw '-Credential is only used in automation mode (with -StartProfile and either -Category/-Action or -JobFile).'
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Configuration ---

# Project root. Functions use this, not $PSScriptRoot: in a dot-sourced Driver\*.ps1 part,
# $PSScriptRoot is the Driver folder (Planning_Driver-Split.md, constraint C2).
$script:AppRoot                   = $PSScriptRoot
$script:AppName                   = 'aPePAS - CyberArk PAS Driver'
$script:Version                   = '1.0.0'   # Bump this value with every release - shown in the banner and startup log line
$script:AuthCommonPath            = Join-Path $PSScriptRoot 'Auth\CyberArk.Auth.Common.psm1'
$script:AuthISPSSPath             = Join-Path $PSScriptRoot 'Auth\CyberArk.Auth.ISPSS.psm1'
$script:AuthSelfHostedPath        = Join-Path $PSScriptRoot 'Auth\CyberArk.Auth.SelfHosted.psm1'
$script:LoggingModulePath         = Join-Path $PSScriptRoot 'Modules\CyberArkLogging.psm1'
$script:CommsModulePath           = Join-Path $PSScriptRoot 'Modules\CyberArkComms.psm1'
$script:CredentialStoreModulePath = Join-Path $PSScriptRoot 'Modules\CyberArkCredentialStore.psm1'
$script:APIModulesPath            = Join-Path $PSScriptRoot 'APIModules'
$script:DefaultProfileDir         = Join-Path $env:APPDATA 'IdiraUnifiedScripts\Profiles'
$script:ProfileDir                = $script:DefaultProfileDir
$script:InactivityTimeoutMin      = 10
$script:TokenExpiryWarnMin        = 5
$script:ProactiveRefreshThresholdMin = 10
$script:PVWA_SESSION_EXPIRY_MIN   = 20   # matches SelfHosted module constant
$script:LogonTokenMaxAgeMin       = 15   # a still-valid saved token older than this is refreshed at logon
$script:LogRetentionDays          = 30   # session logs older than this are deleted when a session starts
$script:WhatIfMode                = $WhatIf.IsPresent
# Set once, here, rather than inside the automation entry point below - guarded code (e.g.
# Invoke-ProfileConnect's fresh-auth guard) can run during setup, before that function's own
# body would otherwise get a chance to set it. Read directly by API modules the same way
# $script:WhatIfMode already is, since every module is dot-sourced into this driver's own scope -
# see Claude_Docs\Reference_API-Module-Guide.md for the convention this establishes for module authors.
$script:AutomationMode            = [bool](($Category -and $Action) -or $JobFile)
# -Credential, held in memory for this run only (Invoke-AutomationWithCredential.ps1). $null otherwise.
$script:AutomationCredential      = $Credential
$script:DefaultLogLevel           = $LogLevel
$script:DefaultLogFolder          = if ($LogFolder) { $LogFolder } else { Join-Path $PSScriptRoot 'Logs' }
$script:ScreenWidth               = 80
$script:SessionToken              = $null   # Active token object - set after successful auth
$script:ActiveProfile             = $null   # Active driver profile JSON object

# Member names never copied by Safes/AddFromTemplate (or any future Safes/SafeMembers
# module that reuses it), regardless of Role_Group_Prefix. Exact match, case-insensitive,
# across all memberTypes. Empty by default - add names here as needed.
$script:ExcludedTemplateMemberNames = @("PSMAppUsers")

#endregion

#region --- Core Module Imports ---

# Unconditional (runs even when this script is dot-sourced, e.g. by Pester tests) - unlike
# Logging/Comms/Auth below, this module has no side effects at import time (pure file I/O
# function definitions, no logging or network calls) and its functions (Get-ProfileCredential
# etc.) are used by driver code that isn't itself gated behind the entry-point guard, so tests
# that dot-source this file get the real module rather than needing their own stub.
Import-Module $script:CredentialStoreModulePath -Force -ErrorAction Stop

#endregion

#region --- Startup Checks ---

function Assert-Prerequisites {
    $missing = @()
    if (-not (Test-Path -LiteralPath $script:AuthCommonPath)) {
        $missing += "Auth Common module not found: $($script:AuthCommonPath)"
    }
    if (-not (Test-Path -LiteralPath $script:AuthISPSSPath)) {
        $missing += "Auth ISPSS module not found: $($script:AuthISPSSPath)"
    }
    if (-not (Test-Path -LiteralPath $script:AuthSelfHostedPath)) {
        $missing += "Auth SelfHosted module not found: $($script:AuthSelfHostedPath)"
    }
    if (-not (Test-Path -LiteralPath $script:LoggingModulePath)) {
        $missing += "Logging module not found: $($script:LoggingModulePath)"
    }
    if (-not (Test-Path -LiteralPath $script:CommsModulePath)) {
        $missing += "Comms module not found: $($script:CommsModulePath)"
    }
    foreach ($part in $script:MissingDriverParts) {
        $missing += "Driver part not found: $part"
    }
    if ($missing) {
        Write-Host "`nPrerequisite check failed:" -ForegroundColor Red
        $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        Write-Host "`nEnsure all modules and the Driver folder are present alongside Manage-Privilege.ps1." -ForegroundColor Red
        exit 1
    }

    Import-Module $script:LoggingModulePath   -Force -ErrorAction Stop
    Import-Module $script:CommsModulePath     -Force -ErrorAction Stop
}

#endregion

#region --- Module Discovery ---

$script:LoadedModules    = @()
$script:SessionStartTime = $null   # UTC; idle time counts from this or the last API call (Get-SessionIdleSeconds)

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

#region --- Input and CSV Processing ---

function Select-InputFiles {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    $dialog.Title       = 'Select Input CSV File(s)'
    $dialog.Filter      = 'CSV Files (*.csv)|*.csv|All Files (*.*)|*.*'
    $dialog.Multiselect = $true
    $dialog.InitialDirectory = if ($script:ActiveProfile.InputFolder) {
        $resolved = if ([System.IO.Path]::IsPathRooted($script:ActiveProfile.InputFolder)) {
            $script:ActiveProfile.InputFolder
        } else {
            Join-Path $script:AppRoot $script:ActiveProfile.InputFolder
        }
        if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved } else { $script:AppRoot }
    } else { $script:AppRoot }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileNames
    }
    return @()
}

function Get-OutputCsvPath {
    param([string]$InputPath)
    # Automation mode's -OutputFolder applies to the per-file results CSV too, with the same
    # create-if-missing rule as Get-CsvSavePath; if it can't be created, fall back below.
    # Get-Variable rather than $script:OutputFolder: when this file is dot-sourced (tests) the
    # top-level param doesn't exist, and strict mode would throw.
    $outputOverride = Get-Variable -Name 'OutputFolder' -Scope 'Script' -ValueOnly -ErrorAction SilentlyContinue
    if ($script:AutomationMode -and $outputOverride) {
        $override = if ([System.IO.Path]::IsPathRooted($outputOverride)) { $outputOverride } else { Join-Path $script:AppRoot $outputOverride }
        if (-not (Test-Path -LiteralPath $override -PathType Container)) {
            try { New-Item -ItemType Directory -Path $override -Force -ErrorAction Stop | Out-Null } catch {
                Write-CyberArkLog -Level 'WARN' -Message "Automation mode: could not create -OutputFolder '$override' for the results CSV ($_). Using the profile or input-file folder."
            }
        }
        if (Test-Path -LiteralPath $override -PathType Container) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
            return Join-Path $override "$($base)_$((Get-Date).ToString('yyyy-MM-dd'))_output.csv"
        }
    }
    $folder = if ($script:ActiveProfile.OutputFolder) {
        $resolved = if ([System.IO.Path]::IsPathRooted($script:ActiveProfile.OutputFolder)) {
            $script:ActiveProfile.OutputFolder
        } else {
            Join-Path $script:AppRoot $script:ActiveProfile.OutputFolder
        }
        if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved } else { Split-Path $InputPath }
    } else { Split-Path $InputPath }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    return Join-Path $folder "$($base)_$((Get-Date).ToString('yyyy-MM-dd'))_output.csv"
}

#region --- Detailed CSV results ---
# A CSV run's <input>_<date>_output.csv keeps one IsSuccess/Summary line per input row. The
# matching <input>_<date>_detail.csv keeps everything each row returned, so Get actions and
# tools like Test Connectivity don't lose their output when run from a CSV.

function ConvertTo-DetailCsvValue {
    <# One cell: arrays joined with '; ', nested objects as compact JSON, secrets masked by the caller. #>
    param([AllowNull()] [object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Security.SecureString] -or $Value -is [System.Management.Automation.PSCredential]) { return '***' }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [PSCustomObject]) {
        try { return (ConvertTo-Json -InputObject $Value -Depth 5 -Compress) } catch { return "$Value" }
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return ((@($Value) | ForEach-Object { "$(ConvertTo-DetailCsvValue -Value $_)" }) -join '; ')
    }
    return "$Value"
}

function Add-DetailCsvRows {
    <#
        Appends one input row's results to $Rows (a List of ordered dictionaries): one line per
        result object, or per error when there are no results, or a single status line. Columns
        whose names look secret are written as '***'.
    #>
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]]$Rows,
        [Parameter(Mandatory = $true)] [int]$RowNumber,
        [AllowNull()] [object]$Result,
        [bool]$IsSuccess,
        [string]$Summary
    )
    $secret  = '(?i)(password|secret|credential|token|passphrase)'
    $added   = 0
    $results = if ($Result -and $Result.PSObject.Properties['Results'] -and $Result.Results) { @($Result.Results) } else { @() }
    foreach ($item in $results) {
        if ($null -eq $item) { continue }
        $line = [ordered]@{ RowNumber = $RowNumber; Status = 'OK' }
        if ($item -is [string] -or $item -is [ValueType]) {
            $line['Value'] = $item
        } else {
            foreach ($prop in $item.PSObject.Properties) {
                if ($prop.Name -in @('RowNumber', 'Status')) { continue }
                $line[$prop.Name] = if ($prop.Name -match $secret) { '***' } else { ConvertTo-DetailCsvValue -Value $prop.Value }
            }
        }
        $Rows.Add($line); $added++
    }
    $errors = if ($Result -and $Result.PSObject.Properties['Errors'] -and $Result.Errors) { @($Result.Errors) } else { @() }
    foreach ($err in $errors) {
        if ($null -eq $err) { continue }
        $msg = if ($err.PSObject.Properties['ErrorMessage']) { "$($err.ErrorMessage)" } else { "$err" }
        $Rows.Add([ordered]@{ RowNumber = $RowNumber; Status = 'Failed'; ErrorMessage = $msg }); $added++
    }
    if ($added -eq 0) {
        $Rows.Add([ordered]@{ RowNumber = $RowNumber; Status = $(if ($IsSuccess) { 'OK' } else { 'Failed' }); Summary = $Summary })
    }
}

function ConvertTo-DetailCsvObjects {
    <# Gives every line the union of all columns (first-seen order) so Export-Csv keeps them all. #>
    param([System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]]$Rows)
    $columns = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $Rows) { foreach ($k in $r.Keys) { if (-not $columns.Contains([string]$k)) { $columns.Add([string]$k) } } }
    foreach ($r in $Rows) {
        $o = [ordered]@{}
        foreach ($c in $columns) { $o[$c] = if ($r.Contains($c)) { $r[$c] } else { '' } }
        [PSCustomObject]$o
    }
}

#endregion

function Test-CsvSchema {
    param([string[]]$Headers, [hashtable[]]$Schema)
    return @($Schema | Where-Object { $_.Required -and ($_.Column -cnotin $Headers) })
}

function Invoke-InteractiveInput {
    param([hashtable[]]$Schema)
    $data = @{}
    foreach ($field in $Schema) {
        $value = Show-FieldPrompt -Label $field.Column -Description $field.Description `
            -Required:($field.Required)
        $data[$field.Column] = $value
    }
    return $data
}

function Invoke-CsvProcessing {
    param(
        [PSCustomObject]$ModuleEntry,

        # When supplied, used directly instead of showing the interactive OpenFileDialog -
        # automation mode's route in. $null (default) preserves today's interactive behavior
        # exactly.
        [string[]]$FilePaths = $null
    )
    $meta   = $ModuleEntry.Meta
    $fnName = "Invoke-$($meta.Category)$($meta.Action)"
    # Every module was dot-sourced into one scope, so the shared $ModuleMeta holds the last
    # module loaded. Module functions read $ModuleMeta for their result and log-summary labels
    # through dynamic scoping, so shadow it here with this module's own metadata (F73).
    $ModuleMeta = $meta

    $files = if ($FilePaths) { $FilePaths } else { Select-InputFiles }
    if (-not $files) {
        Write-Host '  No files selected.' -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
        return [PSCustomObject]@{ TotalProcessed = 0; TotalOk = 0; TotalFail = 0; AnyFatal = $false }
    }

    # Aggregated across every file actually attempted (a file skipped for being unreadable/
    # empty/schema-invalid contributes nothing to these totals) - returned to the caller so
    # automation mode can map the whole batch to a single exit code.
    $totalProcessed = 0
    $totalOk        = 0
    $totalFail      = 0
    $anyFatal       = $false
    $skippedFiles   = 0   # unreadable, empty or missing required columns: automation exits 3

    foreach ($filePath in $files) {
        $fileName = [System.IO.Path]::GetFileName($filePath)
        Write-CyberArkLog -Message "Starting CSV: $filePath" -Level 'INFO'

        try { $rows = @(Import-Csv -LiteralPath $filePath) } catch {
            Write-Host "  Could not read '$fileName': $_" -ForegroundColor Red
            Write-CyberArkLog -Message "Failed to read CSV '$filePath': $_" -Level 'WARN'
            $skippedFiles++
            continue
        }

        if (-not $rows) {
            Write-Host "  '$fileName' is empty - skipped." -ForegroundColor Yellow
            Write-CyberArkLog -Message "CSV '$filePath' has no rows - skipped." -Level 'WARN'
            $skippedFiles++
            continue
        }

        if ($meta.InputSchema) {
            $missing = Test-CsvSchema -Headers $rows[0].PSObject.Properties.Name -Schema $meta.InputSchema
            if ($missing) {
                $cols = ($missing | ForEach-Object { $_.Column }) -join ', '
                Write-Host "  '$fileName' missing required columns: $cols - skipped." -ForegroundColor Red
                Write-CyberArkLog -Message "CSV schema validation failed for '$fileName'. Missing: $cols" -Level 'WARN'
                $skippedFiles++
                continue
            }
        }

        $outputPath = Get-OutputCsvPath -InputPath $filePath
        $detailPath = $outputPath -replace '_output\.csv$', '_detail.csv'
        $detailRows = [System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]]::new()
        $rowNumber  = 0
        $outputRows = [System.Collections.Generic.List[PSCustomObject]]::new()
        $okCount    = 0
        $failCount  = 0
        $fatal      = $false
        $total      = $rows.Count

        Write-Host "  Processing '$fileName' ($total rows)..." -ForegroundColor DarkGray

        foreach ($row in $rows) {
            # Token health before each row
            switch (Test-TokenExpiry) {
                'Warning' { Invoke-SelfHostedKeepalive; Invoke-TokenRefresh | Out-Null }
                'Expired' {
                    if (-not (Invoke-TokenRefresh)) {
                        Write-CyberArkLog -Message 'Auth failure mid-CSV - aborting.' -Level 'ERROR'
                        $fatal = $true
                    }
                }
            }
            if ($fatal) { break }

            $inputData = @{}
            foreach ($col in $row.PSObject.Properties) { $inputData[$col.Name] = $col.Value }

            $result = & $fnName -Token $script:SessionToken -InputData $inputData -WhatIf:$script:WhatIfMode

            # A reactive 401 (module returns IsFatal) force-expires the token and re-authenticates,
            # then retries this same row once with the refreshed token, instead of aborting the
            # whole CSV batch. IsFatal is only ever set by a module for HTTP 401 or a network-level
            # failure (StatusCode 0) - see the IsFatal table in Reference_API-Module-Guide.md.
            $reauthFailed = $false
            if ($result.IsFatal) {
                Write-Host '  Fatal API error (401 Unauthorized or connectivity) - re-authenticating...' -ForegroundColor Yellow
                Write-CyberArkLog -Message 'IsFatal returned by module - attempting re-authentication mid-CSV.' -Level 'WARN'
                # Invalidate unconditionally rather than pattern-matching the error message text:
                # a 401 whose message happens not to contain "401"/"Unauthorized" must still
                # force re-authentication, not silently leave a rejected token in place.
                Invoke-TokenInvalidate
                if (Invoke-TokenRefresh) {
                    Write-Host '  Re-authenticated - retrying row...' -ForegroundColor Green
                    $result = & $fnName -Token $script:SessionToken -InputData $inputData -WhatIf:$script:WhatIfMode
                    if ($result.IsFatal) {
                        Write-Host '  Fatal API error persisted after re-authentication - aborting.' -ForegroundColor Red
                        Write-CyberArkLog -Message 'IsFatal persisted after retry - aborting CSV loop.' -Level 'ERROR'
                        Invoke-TokenInvalidate
                        $reauthFailed = $true
                    }
                } else {
                    Write-Host '  Re-authentication failed or cancelled - aborting.' -ForegroundColor Red
                    Write-CyberArkLog -Message 'Re-authentication failed mid-CSV - aborting.' -Level 'ERROR'
                    $reauthFailed = $true
                }
            }

            $isSuccess = ($result.Failures -eq 0 -and $result.ItemsProcessed -gt 0) -or
                         ($result.Successes -gt 0)
            $summary   = if ($isSuccess) {
                if ($result.Results.Count -gt 0 -and $result.Results[0].PSObject.Properties['Summary']) {
                    $result.Results[0].Summary
                } else { 'OK' }
            } else {
                if ($result.Errors.Count -gt 0) { $result.Errors[0].ErrorMessage } else { 'Failed' }
            }

            if ($isSuccess) { $okCount++ } else { $failCount++ }

            $outRow = [ordered]@{}
            # Never copy a secret input column (e.g. Users/Add InitialPassword, Users/ResetPassword
            # NewPassword, Accounts/Add Secret) into the results CSV in clear text.
            foreach ($col in $row.PSObject.Properties) {
                $outRow[$col.Name] = if ($col.Name -match '(?i)password|secret' -and "$($col.Value)" -ne '') { '***' } else { $col.Value }
            }
            $outRow['IsSuccess'] = $isSuccess
            $outRow['Summary']   = $summary
            $outputRows.Add([PSCustomObject]$outRow)
            $rowNumber++
            Add-DetailCsvRows -Rows $detailRows -RowNumber $rowNumber -Result $result -IsSuccess $isSuccess -Summary "$summary"

            if ($reauthFailed) {
                $fatal = $true
                break
            }
        }

        if ($outputRows.Count -gt 0) {
            $saved = Invoke-FileWriteWithRetry -Path $outputPath -Action {
                $outputRows | Export-Csv -LiteralPath $outputPath -NoTypeInformation -Encoding UTF8
            }
            if ($saved) {
                Write-Host "  Output: $outputPath" -ForegroundColor Green
            } else {
                Write-CyberArkLog -Level 'ERROR' -Message "Failed to write output CSV '$outputPath' (user declined to retry)."
            }
        }

        if ($detailRows.Count -gt 0) {
            $detailObjects = @(ConvertTo-DetailCsvObjects -Rows $detailRows)
            $savedDetail = Invoke-FileWriteWithRetry -Path $detailPath -Action {
                $detailObjects | Export-Csv -LiteralPath $detailPath -NoTypeInformation -Encoding UTF8
            }
            if ($savedDetail) {
                Write-Host "  Detail: $detailPath" -ForegroundColor Green
            } else {
                Write-CyberArkLog -Level 'ERROR' -Message "Failed to write detail CSV '$detailPath' (user declined to retry)."
            }
        }

        $msg = "'$fileName': $($outputRows.Count) processed - $okCount OK, $failCount failed."
        Write-Host "  $msg" -ForegroundColor $(if ($failCount -gt 0) { 'Yellow' } else { 'White' })
        Write-CyberArkLog -Message $msg -Level 'INFO'

        if ($meta.Action -notin @('List','Get')) {
            Add-CyberArkLogSummaryEntry -ModuleName $meta.Name `
                -ItemsProcessed $outputRows.Count -Successes $okCount -Failures $failCount
        }

        $totalProcessed += $outputRows.Count
        $totalOk        += $okCount
        $totalFail      += $failCount
        if ($fatal) { $anyFatal = $true; break }
    }

    if (-not $script:AutomationMode) {
        Write-Host ''
        Write-Host '  Press Enter to return to the menu.' -ForegroundColor DarkGray
        Read-Host | Out-Null
    }

    return [PSCustomObject]@{
        TotalProcessed = $totalProcessed
        TotalOk        = $totalOk
        TotalFail      = $totalFail
        AnyFatal       = $anyFatal
        SkippedFiles   = $skippedFiles
    }
}

#endregion

#region --- Action Menu ---

function Show-CategoryMenu {
    param([string[]]$Breadcrumbs, [object[]]$Categories)
    Show-Header -Breadcrumbs $Breadcrumbs

    if (-not $Categories -or $Categories.Count -eq 0) {
        Write-Host '  No API modules loaded for this system type.' -ForegroundColor DarkGray
        Write-Host "  Add .ps1 files to: $($script:APIModulesPath)" -ForegroundColor DarkGray
        Write-Host ''
    } else {
        $i = 1
        foreach ($cat in $Categories) {
            $n    = $cat.Count
            $noun = if ($n -eq 1) { 'action' } else { 'actions' }
            Write-Host ("  [{0,2}]  {1,-20}  ({2} {3})" -f $i, $cat.Name, $n, $noun) -ForegroundColor White
            $i++
        }
        Write-Host ''
    }

    Show-Divider
    $remaining = [Math]::Round((Get-TokenRemainingMinutes), 1)
    $expColor  = if ($remaining -le $script:TokenExpiryWarnMin) { 'Yellow' } else { 'DarkGray' }
    $idleSec   = Get-SessionIdleSeconds
    $idleMin   = [Math]::Round($idleSec / 60, 1)
    Write-Host ("  Token: {0} min remaining    Idle: {1} of {2} min" -f $remaining, $idleMin, $script:InactivityTimeoutMin) -ForegroundColor $expColor
    # The warning lives here, under the menu, so the menu's Clear-Host can't wipe it.
    if ($idleSec -ge ($script:InactivityTimeoutMin * 60 * 0.9)) {
        $remainSec = [Math]::Max(0, [int]($script:InactivityTimeoutMin * 60 - $idleSec))
        Write-Host "  Inactivity warning: the session ends in ~$remainSec seconds unless an action calls the API." -ForegroundColor Yellow
    }
    if ($script:WhatIfMode) {
        Write-Host '  WhatIf mode is ON - write operations will be suppressed.' -ForegroundColor Yellow
    }
    Write-Host '  [R] Restart to profile selection    [X] Exit' -ForegroundColor White
}

function Show-ActionMenu {
    param([string[]]$Breadcrumbs, [PSCustomObject[]]$CategoryModules)
    Show-Header -Breadcrumbs $Breadcrumbs

    $i = 1
    foreach ($entry in $CategoryModules) {
        if ($entry.PSObject.Properties['Failed'] -and $entry.Failed) {
            Write-Host ("    {0,3}.  {1}  [Load Failed]" -f $i, $entry.Meta.Name) -ForegroundColor Red
            Write-Host ("           $($entry.Meta.Description)") -ForegroundColor DarkRed
        } else {
            $tags = @()
            if ($entry.Meta.AcceptsInputFile)                       { $tags += 'CSV' }
            if ($entry.Meta.SupportsWhatIf -and $script:WhatIfMode) { $tags += 'WhatIf' }
            $tagStr = if ($tags) { "  [$($tags -join ', ')]" } else { '' }
            Write-Host ("    {0,3}.  {1}{2}" -f $i, $entry.Meta.Name, $tagStr) -ForegroundColor White
            Write-Host ("           {0}" -f $entry.Meta.Description) -ForegroundColor DarkGray
        }
        $i++
    }
    Write-Host ''

    Show-Divider
    $remaining = [Math]::Round((Get-TokenRemainingMinutes), 1)
    $expColor  = if ($remaining -le $script:TokenExpiryWarnMin) { 'Yellow' } else { 'DarkGray' }
    Write-Host ("  Token: {0} min remaining" -f $remaining) -ForegroundColor $expColor
    if ($script:WhatIfMode) {
        Write-Host '  WhatIf mode is ON - write operations will be suppressed.' -ForegroundColor Yellow
    }
    Write-Host '  [B] Back to categories    [R] Restart    [X] Exit' -ForegroundColor White
}

function Save-ModuleResultCsv {
    <#
        Extracted from Invoke-ActionModule's inline CSV-auto-save block so the automation entry
        point (Invoke-AutomatedAction) can reuse it too - without this, an automated run of a
        ProducesOutput module would report success but silently write no CSV. In automation mode,
        always saves via Get-CsvSavePath -AutoSave (never shows the interactive "Save to CSV?
        [y/N]" prompt or the SaveFileDialog fallback), so this call is fully non-interactive.
    #>
    param(
        [PSCustomObject]$ModuleEntry,
        [PSCustomObject]$Result,
        [hashtable]$InputData
    )
    $meta = $ModuleEntry.Meta
    if (-not ($meta.ProducesOutput -and $Result.Results.Count -gt 0)) { return }

    # AutoSaveCsv modules (bulk export tools whose whole purpose is producing a CSV) save
    # straight to the default path with no prompt or dialog - see ModuleMeta.AutoSaveCsv.
    # Bracket notation, not dot notation: $meta is a hashtable, and most modules don't declare
    # this optional key at all - dot-accessing a missing hashtable key throws
    # PropertyNotFoundException under Set-StrictMode (always active here).
    $autoSave = [bool]$meta['AutoSaveCsv'] -or $script:AutomationMode
    $doSave   = $autoSave
    if (-not $autoSave) {
        $saveCsv = Read-MenuChoice -Prompt 'Save results to CSV? [y/N]'
        $doSave  = ($saveCsv -match '^[Yy]')
    }
    if (-not $doSave) { return }

    # Automation mode's -OutputFolder/-FilenameFormat launch parameters (see Get-CsvSavePath's
    # own FolderOverride/FileNameOverride params), guarded on $script:AutomationMode so they're
    # never picked up on an interactive run that happens to have been launched alongside
    # -Category/-Action for an unrelated reason. $script:-prefixed reads, not bare
    # $OutputFolder/$FilenameFormat: both are this script's own top-level param() variables, and
    # $script: always resolves to this file's actual script-scope container regardless of which
    # nested scope happens to be executing this line (e.g. a Pester BeforeAll block's own scope,
    # when this function is exercised from a unit test) - a bare lexical-parent-chain lookup does
    # not have that same guarantee.
    $folderOverride   = if ($script:AutomationMode -and $script:OutputFolder) { $script:OutputFolder } else { $null }
    $fileNameOverride = if ($script:AutomationMode -and $script:FilenameFormat) {
        Format-AutomationFilename -Format $script:FilenameFormat -ModuleName $meta.Name -Category $meta.Category -Action $meta.Action
    } else { $null }

    # Optional ModuleMeta.CsvFilenameField: names an InputData column whose value (when present
    # and non-blank) is appended to the saved filename - e.g. Test Connectivity declares
    # 'Address' so a single run's CSV is named after the server it tested. Bracket notation -
    # most modules don't declare this optional key. Skipped when -FilenameFormat already took
    # full control of the name - an explicit format is authoritative, not layered with this too.
    $csvNameSuffix = ''
    $csvFilenameField = $meta['CsvFilenameField']
    if (-not $fileNameOverride -and $csvFilenameField -and $InputData -and $InputData.ContainsKey($csvFilenameField)) {
        $fieldValue = "$($InputData[$csvFilenameField])".Trim()
        if ($fieldValue) { $csvNameSuffix = " - $fieldValue" }
    }
    # Optional ModuleMeta.CsvFilenameNoDate: a bulk export tool whose saved CSV is meant to
    # always be the latest snapshot, overwritten on every run, rather than accumulate one dated
    # file per run - matching Custom/ExportAll's own fixed Export_<Module>.csv naming. Bracket
    # notation - most modules don't declare this optional key. Only meaningful when nothing has
    # already taken over the filename entirely (-FilenameFormat).
    $noDateSuffix = -not $fileNameOverride -and [bool]$meta['CsvFilenameNoDate']
    $csvPath = Get-CsvSavePath -DefaultFolder $script:ActiveProfile.OutputFolder -ModuleName "$($meta.Name)$csvNameSuffix" -AutoSave:$autoSave `
        -FolderOverride $folderOverride -FileNameOverride $fileNameOverride -NoDateSuffix:$noDateSuffix
    if ($csvPath) {
        $saved = Invoke-FileWriteWithRetry -Path $csvPath -Action {
            $Result.Results | Export-Csv -Path $csvPath -NoTypeInformation -Force
        }
        if ($saved) {
            Write-Host "  Saved: $csvPath" -ForegroundColor Green
            Write-CyberArkLog -Message "Results saved to CSV: $csvPath" -Level 'INFO'
        } else {
            Write-CyberArkLog -Message "Failed to save CSV to '$csvPath' (user declined to retry)." -Level 'ERROR'
        }
    }
}

function Invoke-ActionModule {
    param(
        [PSCustomObject]$ModuleEntry,
        [hashtable]$Defaults = $null
    )

    if ($ModuleEntry.PSObject.Properties['Failed'] -and $ModuleEntry.Failed) {
        Show-Header -Breadcrumbs @($script:ActiveProfile.ProfileName, $ModuleEntry.Meta.Category, $ModuleEntry.Meta.Name)
        Write-Host "  $($ModuleEntry.Meta.Name)" -ForegroundColor Red
        Write-Host '  This module failed to load and cannot be executed.' -ForegroundColor Red
        Write-Host ''
        Write-Host "  Error: $($ModuleEntry.FailError)" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Press Enter to return.' -ForegroundColor DarkGray
        Read-Host | Out-Null
        return
    }

    $meta   = $ModuleEntry.Meta
    $fnName = "Invoke-$($meta.Category)$($meta.Action)"
    # Every module was dot-sourced into one scope, so the shared $ModuleMeta holds the last
    # module loaded. Module functions read $ModuleMeta for their result and log-summary labels
    # through dynamic scoping, so shadow it here with this module's own metadata (F73).
    $ModuleMeta = $meta

    if ($meta.AcceptsInputFile) {
        Show-Header -Breadcrumbs @($script:ActiveProfile.ProfileName, $meta.Category, $meta.Name)
        Write-Host "  $($meta.Name)" -ForegroundColor White
        Write-Host "  $($meta.Description)" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  [1] Process CSV file(s)    [2] Enter values interactively    [3] Generate Template    [B] Back' -ForegroundColor White
        $mode = Read-MenuChoice -Prompt '[1] / [2] / [3] / [B]ack (default: B)'
        if (-not $mode) { $mode = 'B' }
        switch ($mode.ToUpper()) {
            '1' { Invoke-CsvProcessing -ModuleEntry $ModuleEntry; return }
            '2' { <# fall through to interactive input below #> }
            '3' {
                $cols = @($meta.InputSchema | ForEach-Object { $_.Column })
                if ($cols.Count -eq 0) {
                    Write-Host '  This module has no input schema; no template to generate.' -ForegroundColor Yellow
                } else {
                    $csvPath = Get-CsvSavePath -DefaultFolder $script:ActiveProfile.OutputFolder `
                        -ModuleName "$($meta.Name) Template"
                    if ($csvPath) {
                        $header = ($cols | ForEach-Object { "`"$_`"" }) -join ','
                        $lines  = [System.Collections.Generic.List[string]]::new()
                        $lines.Add($header)

                        # If any InputSchema column defines an Example value, add one example
                        # row beneath the header - blank for any column that doesn't have one -
                        # so the CSV format is obvious at a glance (e.g. the Type:Name:RoleName;...
                        # syntax for a delimited-list column like ExtraMembers). Bracket/ContainsKey
                        # access, not dot notation - InputSchema entries are hashtables, and most
                        # modules' entries don't define Example at all.
                        $hasExample = @($meta.InputSchema | Where-Object { $_.ContainsKey('Example') -and $_['Example'] }).Count -gt 0
                        if ($hasExample) {
                            $exampleRow = ($meta.InputSchema | ForEach-Object {
                                $ex = if ($_.ContainsKey('Example') -and $_['Example']) { "$($_['Example'])" } else { '' }
                                "`"$ex`""
                            }) -join ','
                            $lines.Add($exampleRow)
                        }

                        try {
                            [System.IO.File]::WriteAllLines($csvPath, [string[]]$lines, [System.Text.Encoding]::UTF8)
                            Write-Host "  Template saved: $csvPath" -ForegroundColor Green
                        } catch {
                            Write-Host "  Failed to write template: $_" -ForegroundColor Red
                            Write-CyberArkLog -Level 'ERROR' -Message "Failed to write template to '$csvPath': $_"
                        }
                    }
                }
                return
            }
            { $_ -match '^B\d*$' } { return }
            default { return }
        }
    }

    Show-Header -Breadcrumbs @($script:ActiveProfile.ProfileName, $meta.Category, $meta.Name)
    Write-Host "  $($meta.Name)" -ForegroundColor White
    Write-Host "  $($meta.Description)" -ForegroundColor DarkGray
    Write-Host ''

    $inputData = if ($meta.HasCustomInput) {
        if ($Defaults) {
            & "Get-$($meta.Category)$($meta.Action)Input" -Token $script:SessionToken -Defaults $Defaults
        } else {
            & "Get-$($meta.Category)$($meta.Action)Input" -Token $script:SessionToken
        }
    } elseif ($meta.InputSchema) {
        Invoke-InteractiveInput -Schema $meta.InputSchema
    } else { @{} }

    if ($null -eq $inputData) { return }   # User cancelled in custom input function

    Write-Host ''
    Write-CyberArkLog -Message "Invoking $fnName" -Level 'DEBUG'

    $result = & $fnName -Token $script:SessionToken -InputData $inputData -WhatIf:$script:WhatIfMode
    $displayLimit    = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['DisplayLimit']) {
        [int]$script:ActiveProfile.DisplayLimit
    } else { 20 }
    # 0 = show all; otherwise truncate List actions and all Custom export operations
    $truncateDisplay = ($displayLimit -gt 0) -and (($meta.Action -eq 'List') -or ($meta.Category -eq 'Custom' -and $meta.ProducesOutput))

    Write-Host ''
    if ($result.Successes -gt 0 -or ($result.ItemsProcessed -eq 0 -and $result.Errors.Count -eq 0)) {
        Write-Host "  Result: $($result.Successes) succeeded, $($result.Failures) failed." -ForegroundColor Green
        if ($result.Results.Count -gt 0) {
            $tableData = @(if ($meta.Action -eq 'List') {
                $n = 1
                @($result.Results | ForEach-Object {
                    $props = [ordered]@{ '#' = $n++ }
                    foreach ($p in $_.PSObject.Properties) { $props[$p.Name] = $p.Value }
                    [PSCustomObject]$props
                })
            } else { @($result.Results) })
            $displayData = @(if ($truncateDisplay -and $tableData.Count -gt $displayLimit) {
                Write-Host "  Showing first $displayLimit of $($result.Results.Count) results. (Change 'Display Limit' in Profile Settings)" -ForegroundColor DarkGray
                $tableData[0..($displayLimit - 1)]
            } else { $tableData })
            $displayData | Format-Table -AutoSize | Out-String |
                Where-Object { $_.Trim() } |
                ForEach-Object { Write-Host "  $_" }
        }
    } else {
        Write-Host "  Result: $($result.Failures) failed." -ForegroundColor Red
        foreach ($err in $result.Errors) {
            Write-Host "    Error: $($err.ErrorMessage)" -ForegroundColor Yellow
            if ($err.ErrorDetails -and $err.ErrorDetails.ErrorCode) {
                Write-Host "    Code:  $($err.ErrorDetails.ErrorCode)" -ForegroundColor DarkGray
            }
        }
    }

    if ($result.IsFatal) {
        # IsFatal is only ever set by a module for HTTP 401 or a network-level failure
        # (StatusCode 0) - see the IsFatal table in Reference_API-Module-Guide.md.
        # Invalidate unconditionally rather than pattern-matching the error message text:
        # a 401 whose message happens not to contain "401"/"Unauthorized" must still
        # force re-authentication, not silently leave a rejected token in place.
        Write-Host ''
        Write-Host '  Fatal API error (401 Unauthorized or connectivity) - token invalidated.' -ForegroundColor Red
        Invoke-TokenInvalidate
        return
    }

    Save-ModuleResultCsv -ModuleEntry $ModuleEntry -Result $result -InputData $inputData

    if ($meta.Action -notin @('List','Get')) {
        Add-CyberArkLogSummaryEntry -ModuleName $meta.Name `
            -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    }

    # For List actions: offer line-number drill-down to the corresponding Get module
    if ($meta.Action -eq 'List' -and $result.Results.Count -gt 0) {
        $getModule = $script:LoadedModules | Where-Object {
            -not ($_.PSObject.Properties['Failed'] -and $_.Failed) -and
            $_.Meta.Category -eq $meta.Category -and $_.Meta.Action -in @('Get', 'GetMembers')
        } | Select-Object -First 1
        if ($getModule) {
            Write-Host ''
            Write-Host '  Enter a line number to view details, or press Enter to return.' -ForegroundColor DarkGray
            $lineInput = (Read-Host '  #').Trim()
            if ($lineInput -match '^\d+$') {
                $lineNum = [int]$lineInput
                if ($lineNum -ge 1 -and $lineNum -le $result.Results.Count) {
                    $selectedRow = $result.Results[$lineNum - 1]
                    $rowDefaults = @{}
                    foreach ($prop in $selectedRow.PSObject.Properties) {
                        $rowDefaults[$prop.Name] = $prop.Value
                    }
                    Invoke-ActionModule -ModuleEntry $getModule -Defaults $rowDefaults
                }
            }
            return
        }
    }

    Write-Host ''
    Write-Host '  Press Enter to return to the menu.' -ForegroundColor DarkGray
    Read-Host | Out-Null
}

#endregion

#region --- Session Loop ---

function Get-SessionIdleSeconds {
    <#
        Seconds since the last API call made for the user (Get-CyberArkLastApiCallTime), or since
        the session started if none yet. Menu navigation doesn't count, and neither do background
        calls (keepalive, token checks), which pass -NotUserActivity.
    #>
    $since = $script:SessionStartTime
    $last  = if (Get-Command -Name 'Get-CyberArkLastApiCallTime' -ErrorAction SilentlyContinue) { Get-CyberArkLastApiCallTime } else { $null }
    if ($last -and (-not $since -or $last -gt $since)) { $since = $last }
    if (-not $since) { return 0 }
    return ([DateTime]::UtcNow - $since).TotalSeconds
}

function Test-SessionTimedOut {
    <# True (and says so) when the session has been idle for $script:InactivityTimeoutMin. #>
    if ((Get-SessionIdleSeconds) -lt ($script:InactivityTimeoutMin * 60)) { return $false }
    $msg = "Inactivity timeout: no API call for $($script:InactivityTimeoutMin) minutes. Ending session."
    Write-CyberArkLog -Message $msg -Level 'INFO'
    Write-Host "  $msg" -ForegroundColor Yellow
    return $true
}

function Invoke-SessionLoop {
    $script:SessionStartTime = [DateTime]::UtcNow

    Import-APIModules
    # Re-dot-source each module file into this scope so child functions (Invoke-ActionModule)
    # can call both entry points and custom-input functions by name.
    foreach ($m in $script:LoadedModules) {
        if ($m.PSObject.Properties['Failed'] -and $m.Failed) { continue }
        . $m.FilePath
    }

    $crumbs = @($script:ActiveProfile.ProfileName)

    while ($true) {

        # --- Inactivity check (idle = time since the last API call; the menu footer shows the warning) ---
        if (Test-SessionTimedOut) { return 'Exit' }

        # --- Token health ---
        Invoke-ProactiveRefresh
        switch (Test-TokenExpiry) {
            'Expired' {
                if (-not (Invoke-TokenRefresh)) {
                    Write-CyberArkLog -Message 'Session ended - could not renew token.' -Level 'ERROR'
                    return 'Exit'
                }
            }
            'Warning' {
                Invoke-SelfHostedKeepalive
            }
        }

        # --- Category selection ---
        $categories = @($script:LoadedModules | Group-Object { $_.Meta.Category } | Sort-Object Name)
        Show-CategoryMenu -Breadcrumbs $crumbs -Categories $categories
        $catChoice = Read-MenuChoice -Prompt 'Category / [R]estart / [X]it'
        # Checked again after the prompt: time spent waiting at it counts, a menu choice doesn't
        # reset it, so a user who walks away is ended when they come back.
        if (Test-SessionTimedOut) { return 'Exit' }

        switch -Regex ($catChoice.ToUpper()) {

            '^X$' {
                if (Confirm-Action 'End this session and exit the script?') { return 'Exit' }
            }

            '^R$' {
                if (Confirm-Action 'Return to profile selection?') { return 'Restart' }
            }

            '^\d+$' {
                $catNum = [int]$catChoice
                if ($catNum -lt 1 -or $catNum -gt $categories.Count) {
                    Write-Host '  Invalid selection.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                } else {
                    $selectedCat = $categories[$catNum - 1]
                    $catName     = $selectedCat.Name
                    $catModules  = @($selectedCat.Group |
                        Sort-Object @(
                            @{ Expression = { [int]($_.Meta.Action -ne 'List') }; Descending = $false }
                            @{ Expression = { $_.Meta.Name }; Descending = $false }
                        ))
                    $catCrumbs   = $crumbs + @($catName)

                    # --- Action loop for this category ---
                    while ($true) {
                        # --- Inactivity + token health, mirroring the outer category-menu loop
                        # above. Without this block, a user who stays inside one category
                        # (performing several actions in a row without pressing [B] to return to
                        # the category menu) never got the SelfHosted keepalive call or the ISPSS
                        # proactive refresh, and the inactivity timeout/warning never fired -
                        # since all of that previously lived only in the outer loop. The user's
                        # very next action after the real session actually expired would then
                        # force a full re-auth prompt instead of the silent keepalive/refresh this
                        # logic exists to provide.
                        if (Test-SessionTimedOut) { return 'Exit' }

                        Invoke-ProactiveRefresh
                        switch (Test-TokenExpiry) {
                            'Expired' {
                                if (-not (Invoke-TokenRefresh)) {
                                    Write-CyberArkLog -Message 'Session ended - could not renew token.' -Level 'ERROR'
                                    return 'Exit'
                                }
                            }
                            'Warning' {
                                Invoke-SelfHostedKeepalive
                            }
                        }

                        Show-ActionMenu -Breadcrumbs $catCrumbs -CategoryModules $catModules
                        $actChoice = Read-MenuChoice -Prompt 'Action / [B]ack (default: B)'
                        if (-not $actChoice) { $actChoice = 'B' }
                        if (Test-SessionTimedOut) { return 'Exit' }

                        switch -Regex ($actChoice.ToUpper()) {
                            '^X$' {
                                if (Confirm-Action 'End this session and exit the script?') { return 'Exit' }
                            }
                            '^R$' {
                                if (Confirm-Action 'Return to profile selection?') { return 'Restart' }
                            }
                            '^\d+$' {
                                $actNum = [int]$actChoice
                                if ($actNum -lt 1 -or $actNum -gt $catModules.Count) {
                                    Write-Host '  Invalid selection.' -ForegroundColor Red
                                    Start-Sleep -Seconds 1
                                } else {
                                    Invoke-ActionModule -ModuleEntry $catModules[$actNum - 1]
                                    # A 401 during the module call force-expires the token via
                                    # Invoke-TokenInvalidate. Re-check immediately so the re-auth
                                    # prompt appears now, not only after the user presses [B].
                                    if ((Test-TokenExpiry) -eq 'Expired' -and -not (Invoke-TokenRefresh)) {
                                        return 'Exit'
                                    }
                                }
                            }
                            { $_ -match '^B\d*$' } { break }
                            default {
                                if ($actChoice) {
                                    Write-Host '  Invalid input.' -ForegroundColor Red
                                    Start-Sleep -Seconds 1
                                }
                            }
                        }

                        if ($actChoice.ToUpper() -match '^B\d*$') { break }
                    }   # end action loop
                }
            }

            default {
                if ($catChoice) {
                    Write-Host '  Invalid input.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                }
            }
        }

    }   # while session loop
}

#endregion

#region --- Driver Parts ---

# The driver's functions live in Driver\*.ps1. They are dot-sourced here, at script top level and
# above the entry-point guard, so they share this script's scope with the dot-sourced API modules,
# and tests that dot-source this file load them too. They are .ps1 files, not .psm1 modules,
# because a module has its own script scope (Planning_Driver-Split.md, constraint C1). A missing
# part is recorded, not thrown, so Assert-Prerequisites reports it with the other missing files.
$script:DriverParts        = @(
    'Driver.Helpers.ps1',
    'Driver.ProfileStore.ps1',
    'Driver.ProfileUI.ps1',
    'Driver.ProfileConnect.ps1',
    'Driver.Automation.ps1'
)
$script:MissingDriverParts = @()
foreach ($_driverPart in $script:DriverParts) {
    $_driverPartPath = Join-Path (Join-Path $PSScriptRoot 'Driver') $_driverPart
    if (Test-Path -LiteralPath $_driverPartPath -PathType Leaf) {
        . $_driverPartPath
    } else {
        $script:MissingDriverParts += $_driverPartPath
    }
}

#endregion

#region --- Entry Point ---

# Guard: skip the interactive entry point when this script is dot-sourced (e.g. in Pester tests).
if ($MyInvocation.InvocationName -eq '.') { return }

try {

Assert-Prerequisites

# Init startup log — overwrites on each launch so the file always reflects the most recent start
Initialize-CyberArkLog `
    -LogFolder    $script:DefaultLogFolder `
    -ProfileName  'Startup' `
    -Destination  'Both' `
    -MinLevel     $script:DefaultLogLevel `
    -OverwriteFile

Write-CyberArkLog -Message "$($script:AppName) v$($script:Version) starting. PID: $PID" -Level 'INFO'
$_platform = if ($PSVersionTable.PSObject.Properties['Platform']) { $PSVersionTable.Platform } else { 'Windows' }
Write-CyberArkLog -Message "PowerShell $($PSVersionTable.PSVersion)  Platform: $_platform" -Level 'INFO'
Write-CyberArkLog -Message 'Core modules loaded: CyberArkLogging, CyberArkComms.' -Level 'DEBUG'
Remove-Variable _platform

Write-CyberArkLog -Message 'Loading auth modules...' -Level 'DEBUG'
Import-Module $script:AuthCommonPath     -Force -ErrorAction Stop
Write-CyberArkLog -Message 'Loaded: CyberArk.Auth.Common' -Level 'DEBUG'
Import-Module $script:AuthISPSSPath      -Force -ErrorAction Stop
Write-CyberArkLog -Message 'Loaded: CyberArk.Auth.ISPSS' -Level 'DEBUG'
Import-Module $script:AuthSelfHostedPath -Force -ErrorAction Stop
Write-CyberArkLog -Message 'Loaded: CyberArk.Auth.SelfHosted' -Level 'DEBUG'
Write-CyberArkLog -Message 'All modules loaded. Ready for profile selection.' -Level 'INFO'

if ($script:AutomationMode) {
    # Invoke-AutomatedAction closes the log itself before returning.
    $exitCode = Invoke-AutomatedAction
    exit $exitCode
}

# --- Outer restart loop ---
$nextDefaultProfile = $StartProfile
# -AutoConnect only applies to the very first pass through this loop - a Restart always returns
# to the interactive profile list (existing behavior), never re-auto-connects.
$autoConnectPending = $AutoConnect.IsPresent

while ($true) {
    $selectedProfile = Invoke-ProfileManagementLoop -DefaultProfileName $nextDefaultProfile -AutoConnect:$autoConnectPending
    $autoConnectPending = $false

    if (-not $selectedProfile) {
        # User chose Quit at profile selection
        Write-CyberArkLog -Message 'User exited at profile selection.' -Level 'INFO'
        Close-CyberArkLog
        exit 0
    }

    # Create log and output folders if configured but not yet present
    foreach ($folderProp in @('LogFolder', 'OutputFolder')) {
        $folderPath = $script:ActiveProfile.$folderProp
        if ($folderPath -and -not (Test-Path -LiteralPath $folderPath)) {
            try {
                New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
            } catch {
                Write-CyberArkLog -Message "Could not create folder '$folderPath': $_" -Level 'WARN'
            }
        }
    }

    # Re-initialize log with the active profile's folder and metadata
    $logFolder = if ($script:ActiveProfile.LogFolder -and (Test-Path -LiteralPath $script:ActiveProfile.LogFolder)) {
        $script:ActiveProfile.LogFolder
    } else { $script:DefaultLogFolder }

    Initialize-CyberArkLog `
        -LogFolder   $logFolder `
        -ProfileName $script:ActiveProfile.ProfileName `
        -MinLevel    $script:DefaultLogLevel `
        -Destination 'Both' `
        -SystemType  $script:SessionToken.SystemType `
        -AuthMethod  $script:SessionToken.AuthMethod `
        -BaseURL     $script:SessionToken.BaseURL `
        -WhatIfMode  $script:WhatIfMode
    # Keep the log folder from growing without limit: drop this tool's session logs older than the retention period.
    try { Remove-OldCyberArkLogs -LogFolder $logFolder -RetentionDays $script:LogRetentionDays } catch { Write-CyberArkLog -Level 'WARN' -Message "Old log cleanup failed: $_" }

    Write-CyberArkLog -Message "Session started. Profile: $selectedProfile  WhatIf: $($script:WhatIfMode)" -Level 'INFO'

    if ($script:ActiveProfile.IgnoreSSL) {
        Write-CyberArkLog -Message 'IgnoreSSL is enabled for this profile.' -Level 'WARN'
    }

    # --- Run the session ---
    $outcome = Invoke-SessionLoop

    # --- Session ended ---
    Invoke-SessionLogoff
    Close-CyberArkLog

    if ($outcome -eq 'Restart') {
        # Return to profile selection with the current profile as default
        $nextDefaultProfile = $selectedProfile
        # Re-initialize a minimal console log for the profile selection screen
        Initialize-CyberArkLog `
            -LogFolder    $script:DefaultLogFolder `
            -ProfileName  'Startup' `
            -Destination  'Both' `
            -MinLevel     $script:DefaultLogLevel `
            -OverwriteFile
        Write-CyberArkLog -Message 'Session restarted. Returned to profile selection.' -Level 'INFO'
        continue
    }

    # Exit
    break
}

} catch {
    # Name the file the error came from: since the split it can be a Driver\*.ps1 part.
    $_errFile = if ($_.InvocationInfo.ScriptName) { Split-Path -Leaf $_.InvocationInfo.ScriptName } else { 'Manage-Privilege.ps1' }
    Write-Host "`n[FATAL] Unhandled error at $($_errFile):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    Write-Host "  $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Stack trace:" -ForegroundColor DarkGray
    $_.ScriptStackTrace -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    exit 1
}

exit 0

#endregion
