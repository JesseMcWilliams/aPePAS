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
$script:LoadedModules             = @()     # API modules found by Import-APIModules
$script:SessionStartTime          = $null   # UTC; idle time counts from this or the last API call (Get-SessionIdleSeconds)

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
    'Driver.Session.ps1',
    'Driver.CsvProcessing.ps1',
    'Driver.ActionMenu.ps1',
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
