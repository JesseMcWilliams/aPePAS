#Requires -Version 5.1
<#
.SYNOPSIS
    Idira Unified Scripts - CyberArk PAS interactive driver.

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
    exits - no menus, no prompts. Requires the named profile to already have a valid, refreshable
    saved session (has been authenticated interactively at least once); a cold-start login is
    always interactive for every auth method, so automation mode never attempts one and exits
    with a clear message instead. If anything else would normally require interaction, this exits
    stating the issue rather than waiting for input that will never come. See Docs\User-Guide.md
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

.PARAMETER WhatIf
    Enable WhatIf mode for the session (suppresses all write/modify/delete API calls).

.PARAMETER LogLevel
    Minimum log level written to the log file and console. Valid values: VERBOSE, DEBUG, INFO, WARN, ERROR.
    Defaults to INFO.

.PARAMETER LogFolder
    Default folder for log files when the active profile does not specify one.
    Defaults to a 'Logs' subfolder under the script launch directory.
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
    [switch]$WhatIf,
    [ValidateSet('VERBOSE', 'DEBUG', 'INFO', 'WARN', 'ERROR')]
    [string]$LogLevel = 'INFO',
    [string]$LogFolder
)

if ($AutoConnect.IsPresent -and -not $StartProfile) {
    throw '-AutoConnect requires -StartProfile <name>.'
}

# Automation mode: run one module action non-interactively and exit. See
# Docs\User-Guide.md for the exit-code contract (0 success / 1 crash / 2 partial failure /
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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Configuration ---

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
$script:WhatIfMode                = $WhatIf.IsPresent
# Set once, here, rather than inside the automation entry point below - guarded code (e.g.
# Invoke-ProfileConnect's fresh-auth guard) can run during setup, before that function's own
# body would otherwise get a chance to set it. Read directly by API modules the same way
# $script:WhatIfMode already is, since every module is dot-sourced into this driver's own scope -
# see Docs\API-Module-Development-Guide.md for the convention this establishes for module authors.
$script:AutomationMode            = [bool]($Category -and $Action)
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
    if ($missing) {
        Write-Host "`nPrerequisite check failed:" -ForegroundColor Red
        $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        Write-Host "`nEnsure all modules are present alongside Manage-Privilege.ps1." -ForegroundColor Red
        exit 1
    }

    Import-Module $script:LoggingModulePath   -Force -ErrorAction Stop
    Import-Module $script:CommsModulePath     -Force -ErrorAction Stop
}

#endregion

#region --- Display Helpers ---

function Get-SignedInUsername {
    # Prefers the credential actually used to authenticate (_RefreshContext, set on the token
    # by the Auth modules) over the profile's own Username field, which can be blank or stale
    # for auth methods that don't require a stored username. _RefreshContext is a hashtable
    # (see Interfaces.md) - bracket notation, not dot notation, matching Invoke-TokenRefresh's
    # already-correct usage of the same field elsewhere in this file.
    if ($script:SessionToken -and $script:SessionToken.PSObject.Properties['_RefreshContext']) {
        $ctx = $script:SessionToken._RefreshContext
        if ($ctx -and $ctx.ContainsKey('Credential') -and $ctx['Credential']) {
            return $ctx['Credential'].UserName
        }
    }
    if ($script:ActiveProfile -and $script:ActiveProfile.Username) {
        return $script:ActiveProfile.Username
    }
    return ''
}

function Show-Header {
    param([string[]]$Breadcrumbs = @())
    Clear-Host
    $bar = '=' * $script:ScreenWidth
    Write-Host $bar -ForegroundColor Cyan
    $title = "  $($script:AppName)  v$($script:Version)"
    Write-Host $title -ForegroundColor White
    $signedInUser = Get-SignedInUsername
    if ($signedInUser) {
        Write-Host "  User: $signedInUser" -ForegroundColor DarkGray
    }
    if ($Breadcrumbs) {
        $crumb = '  ' + ($Breadcrumbs -join ' > ')
        Write-Host $crumb -ForegroundColor DarkCyan
    }
    if ($script:WhatIfMode) {
        Write-Host '  [WhatIf Mode ON - no changes will be made]' -ForegroundColor Yellow
    }
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ''
}

function Show-Divider {
    Write-Host ('-' * $script:ScreenWidth) -ForegroundColor DarkGray
}

function Read-MenuChoice {
    param([string]$Prompt = 'Choice')
    Write-Host ''
    Write-Host "  $Prompt" -ForegroundColor White -NoNewline
    Write-Host ': ' -NoNewline
    return (Read-Host).Trim()
}

function Confirm-Action {
    param([string]$Message)
    Write-Host "`n  $Message" -ForegroundColor Yellow -NoNewline
    Write-Host ' [Y/N]: ' -NoNewline
    $answer = (Read-Host).Trim()
    return $answer -match '^[Yy]$'
}

function Show-FieldPrompt {
    param(
        [string]$Label,
        [string]$Default = '',
        [string]$Description = '',
        [switch]$Required,
        [switch]$IsSecret
    )
    if ($Description) {
        Write-Host "    $Description" -ForegroundColor DarkGray
    }
    $defaultHint = if ($Default) {
        if ($IsSecret) { '  [current: ***]' } else { "  [default: $Default]" }
    } else { '' }

    Write-Host "    $Label$defaultHint" -ForegroundColor White -NoNewline
    Write-Host ': ' -NoNewline

    $value = if ($IsSecret) {
        $ss = Read-Host -AsSecureString
        if ($ss.Length -gt 0) {
            [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
        } else { $null }
    } else {
        Read-Host
    }

    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Get-CsvSavePath {
    param(
        [string]$DefaultFolder,
        [string]$ModuleName,
        # When set, skips the save dialog/prompt entirely and returns the computed default
        # path directly - used by modules whose CSV should save automatically with no user
        # interaction (see ModuleMeta.AutoSaveCsv).
        [switch]$AutoSave,

        # Automation mode's -OutputFolder/-FilenameFormat overrides (see Save-ModuleResultCsv).
        # Both optional; $null/empty preserves every existing caller's behavior exactly. Unlike
        # $DefaultFolder below (which silently falls back to $PSScriptRoot if it can't be
        # resolved - long-standing, unchanged behavior), an explicit $FolderOverride that doesn't
        # exist is created rather than silently discarded, since silently landing files somewhere
        # other than what an unattended caller explicitly asked for would be worse than a folder
        # that ends up auto-created but otherwise unexpected.
        [string]$FolderOverride   = $null,
        [string]$FileNameOverride = $null,

        # ModuleMeta.CsvFilenameNoDate: a bulk export tool whose saved file is meant to always
        # be the latest snapshot (like Custom/ExportAll's own fixed Export_<Module>.csv files)
        # rather than accumulate one dated file per run. Ignored when $FileNameOverride is set -
        # an explicit -FilenameFormat is always authoritative over this module-level default.
        [switch]$NoDateSuffix
    )
    $safeName    = ($ModuleName -replace '[\\/:*?"<>|]', '_').Trim()
    $defaultName = if ($FileNameOverride) {
        $safeOverride = ($FileNameOverride -replace '[\\/:*?"<>|]', '_').Trim()
        if ($safeOverride.ToLowerInvariant().EndsWith('.csv')) { $safeOverride } else { "$safeOverride.csv" }
    } elseif ($NoDateSuffix.IsPresent) {
        "$safeName.csv"
    } else {
        "$safeName $(Get-Date -Format 'yyyy-MM-dd').csv"
    }
    $defaultDir = if ($FolderOverride) {
        $resolved = if ([System.IO.Path]::IsPathRooted($FolderOverride)) {
            $FolderOverride
        } else {
            Join-Path $PSScriptRoot $FolderOverride
        }
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
            try { New-Item -ItemType Directory -Path $resolved -Force -ErrorAction Stop | Out-Null } catch {
                Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: could not create -OutputFolder '$resolved': $_"
            }
        }
        $resolved
    } elseif ($DefaultFolder) {
        $resolved = if ([System.IO.Path]::IsPathRooted($DefaultFolder)) {
            $DefaultFolder
        } else {
            Join-Path $PSScriptRoot $DefaultFolder
        }
        if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved } else { $PSScriptRoot }
    } else {
        $PSScriptRoot
    }
    $defaultPath = Join-Path $defaultDir $defaultName

    if ($AutoSave.IsPresent) { return $defaultPath }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog                  = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Title            = 'Save Results to CSV'
        $dialog.Filter           = 'CSV Files (*.csv)|*.csv|All Files (*.*)|*.*'
        $dialog.DefaultExt       = 'csv'
        $dialog.FileName         = $defaultName
        $dialog.InitialDirectory = $defaultDir
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.FileName
        }
        return $null
    } catch {
        $path = Show-FieldPrompt -Label 'CSV save path' -Default $defaultPath `
            -Description 'Full path for the output CSV file. Leave blank to cancel.'
        if ($path) { return $path } else { return $null }
    }
}

function Format-AutomationFilename {
    <#
        Expands automation mode's -FilenameFormat template into a concrete filename, for
        Save-ModuleResultCsv. Supports {ModuleName}, {Category}, {Action}, {Profile} (the active
        profile's name, blank if none), and {Date} (yyyy-MM-dd) - plain literal substitution, not
        regex, so none of these values need escaping. Adds a '.csv' extension if the expanded
        name doesn't already end with one.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Format,
        [string]$ModuleName = '',
        [string]$Category   = '',
        [string]$Action     = ''
    )
    $profileName = if ($script:ActiveProfile -and $script:ActiveProfile.ProfileName) { $script:ActiveProfile.ProfileName } else { '' }
    $name = $Format.
        Replace('{ModuleName}', $ModuleName).
        Replace('{Category}',   $Category).
        Replace('{Action}',     $Action).
        Replace('{Profile}',    $profileName).
        Replace('{Date}',       (Get-Date -Format 'yyyy-MM-dd'))
    if (-not $name.ToLowerInvariant().EndsWith('.csv')) { $name += '.csv' }
    return $name
}

function Invoke-FileWriteWithRetry {
    <#
        Runs $Action (a scriptblock that performs a single file write - Export-Csv,
        [System.IO.File]::WriteAllText, Set-Content, etc.) and, if it throws, prompts the user
        to retry instead of letting the error silently discard already-fetched report data. The
        most common cause is the target file being open and locked in another program (Excel, a
        text editor) - something the user can fix in a few seconds by closing it, without having
        to re-run whatever produced the data in the first place.

        Returns $true if $Action eventually completed without throwing, $false if the user
        declined to retry.
    #>
    param(
        [Parameter(Mandatory = $true)] [scriptblock]$Action,
        [Parameter(Mandatory = $true)] [string]$Path
    )
    while ($true) {
        try {
            & $Action
            return $true
        } catch {
            Write-CyberArkLog -Level 'ERROR' -Message "Failed to write '$Path': $_"
            if ($script:AutomationMode) { return $false }
            Write-Host "  Failed to write '$Path': $_" -ForegroundColor Red
            Write-Host '  The file may be open in another program (e.g. Excel).' -ForegroundColor Yellow
            if (-not (Confirm-Action 'Retry the write?')) { return $false }
        }
    }
}

function Invoke-EntitySearch {
    # Searches a list endpoint and lets the user pick from numbered results.
    # Returns the selected entity ID string, or $null if cancelled or nothing found.
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $true)]  [string]$Endpoint,
        [Parameter(Mandatory = $true)]  [string]$SearchTerm,
        [Parameter(Mandatory = $false)] [string]$SearchParam        = 'search',
        [Parameter(Mandatory = $false)] [string]$ResponseProperty   = 'value',
        [Parameter(Mandatory = $false)] [string]$IdProperty         = 'id',
        [Parameter(Mandatory = $false)] [string[]]$DisplayProperties = @('id', 'name'),
        [Parameter(Mandatory = $false)] [string]$EntityLabel        = 'item',
        [Parameter(Mandatory = $false)] [bool]$IgnoreSSL            = $false,
        # When set, fetches all results from the API without a server-side search filter
        # and performs a case-insensitive contains match on DisplayProperties client-side.
        # Use for APIs (e.g. PIMServices) that do not support partial-match search params.
        [Parameter(Mandatory = $false)] [switch]$ClientSideFilter
    )

    $response = $null
    try {
        $qParams = if ($ClientSideFilter) { @{} } else { @{ $SearchParam = $SearchTerm; limit = '25' } }
        $response = Invoke-CyberArkAPI -Token $Token -Method 'GET' `
            -Endpoint $Endpoint `
            -QueryParams $qParams `
            -IgnoreSSL:$IgnoreSSL
    } catch {
        Write-Host "    Search error: $_" -ForegroundColor Red
        return $null
    }

    if (-not $response -or -not $response.IsSuccess) {
        $errMsg = if ($response) { $response.ErrorMessage } else { '(no response)' }
        Write-Host "    Search failed: $errMsg" -ForegroundColor Red
        return $null
    }

    $items = @()
    if ($response.Data -and $response.Data.PSObject.Properties[$ResponseProperty]) {
        $items = @($response.Data.$ResponseProperty)
    }

    if ($ClientSideFilter -and $SearchTerm -and $items.Count -gt 0) {
        $lowerTerm = $SearchTerm.ToLower()
        $items = @($items | Where-Object {
            $item = $_
            $found = $false
            foreach ($p in $DisplayProperties) {
                if (-not $found -and $item.PSObject.Properties[$p] -and "$($item.$p)".ToLower().Contains($lowerTerm)) {
                    $found = $true
                }
            }
            $found
        })
    }

    if ($items.Count -eq 0) {
        Write-Host "    No ${EntityLabel}s found matching '$SearchTerm'." -ForegroundColor Yellow
        return $null
    }

    $displayCount = [Math]::Min($items.Count, 25)
    Write-Host ''
    Write-Host "    Found $($items.Count) ${EntityLabel}$(if ($items.Count -ne 1) { 's' }):" -ForegroundColor Cyan
    Write-Host ''

    for ($i = 0; $i -lt $displayCount; $i++) {
        $item = $items[$i]
        $parts = @(foreach ($prop in $DisplayProperties) {
            if ($item.PSObject.Properties[$prop] -and ($null -ne $item.$prop) -and ("$($item.$prop)" -ne '')) {
                "$($item.$prop)"
            }
        })
        Write-Host "    [$($i + 1)]  $($parts -join '  |  ')" -ForegroundColor White
    }

    Write-Host ''
    $sel = Read-MenuChoice -Prompt "Select $EntityLabel [1-$displayCount] or B to cancel"

    if ($sel -match '^\d+$') {
        $idx = [int]$sel - 1
        if ($idx -ge 0 -and $idx -lt $displayCount) {
            $item = $items[$idx]
            if ($item.PSObject.Properties[$IdProperty] -and ($null -ne $item.$IdProperty)) {
                return "$($item.$IdProperty)"
            }
        }
    }
    return $null
}

function Get-CpmOptions {
    # Shared source for every "pick a CPM" prompt in the driver (Add Safe, Add Safe From
    # Template, Assign CPM to Safe). Per user direction, 2026-09-03: queries live via
    # GET /API/Users?userType=CPM&componentUser=true (confirmed against the 14.6 Swagger spec -
    # userType/componentUser are documented server-side query filters, and CPM is one of the
    # userType values considered a component user) and uses that result whenever the call
    # succeeds, even if it comes back empty - an empty-but-successful result is a real
    # environment state, not a failure, so it is NOT treated as a reason to fall back.
    # Falls back to the profile's manually-maintained CPM_List only when the API call fails or
    # throws. This supersedes the prior per-page choice recorded in Architecture.md (Add Safe
    # From Template used CPM_List only; Assign CPM used the live query only, "per explicit
    # direction, not an oversight") - that distinction no longer applies as of this change.
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token
    )

    $options = [System.Collections.Generic.List[string]]::new()

    $response = $null
    try {
        $response = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/Users' `
            -QueryParams @{ userType = 'CPM'; componentUser = 'true' }
    } catch {
        Write-CyberArkLog -Level 'WARN' -Message "CPM user list query threw an exception: $_"
    }

    if ($response -and $response.IsSuccess) {
        [array]$users = if ($response.Data -and $response.Data.PSObject.Properties['Users']) {
            @($response.Data.Users)
        } else { @() }
        foreach ($user in $users) {
            if ($user.username) { $options.Add("$($user.username)") }
        }
        return $options.ToArray()
    }

    if ($response) {
        Write-CyberArkLog -Level 'WARN' -Message "CPM user list query failed (HTTP $($response.StatusCode)): $($response.ErrorMessage). Falling back to the profile's CPM_List."
    }

    if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['CPM_List'] -and $script:ActiveProfile.CPM_List) {
        return @(("$($script:ActiveProfile.CPM_List)" -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    return $options.ToArray()
}

#endregion

#region --- currentProfile Directory ---

function Initialize-ProfileDirectory {
    param([string]$Path = $script:DefaultProfileDir)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $script:ProfileDir = $Path
}

function Get-ProfileJsonPath       { param([string]$Name) Join-Path $script:ProfileDir "$Name.json" }
function Get-ProfileTokenPath      { param([string]$Name) Join-Path $script:ProfileDir "$Name.cred" }
# .autocred: an optional, separately-stored PSCredential (DPAPI-encrypted via Export-Clixml, same
# mechanism as the .cred token file) used only as an automation-mode fallback when a saved
# session's own _RefreshContext has no usable credential to silently refresh with - see
# Use-StoredCredentialIfMissing and the profile-detail menu's [A] action. See Testing-Plan.md K06.
# Get-ProfileCredentialPath / Save-ProfileCredential / Get-ProfileCredential /
# Remove-ProfileCredential now live in Modules\CyberArkCredentialStore.psm1 (imported
# unconditionally above) so a standalone helper script can reuse the same store - call sites here
# pass -ProfileDir $script:ProfileDir explicitly, since that module has no ambient driver state.

function Use-StoredCredentialIfMissing {
    <#
        Automation mode only (call sites gate this on $script:AutomationMode): if $Token's
        _RefreshContext is missing a Credential - documented in Testing-Plan.md K06 for SelfHosted
        CyberArk/LDAP/RADIUS, and extended to ISPSS Interactive in K12 once that method gained its
        own silent-refresh path - loads a credential previously stored for this profile via
        Save-ProfileCredential (the profile-detail menu's [A] action) and injects it, so the
        subsequent Update-SelfHostedAuthToken/Update-ISPSSAuthToken call can refresh silently
        instead of needing one. No-op for any method that doesn't use a Credential at all
        (SelfHosted Shared/PKI/PKIPN/SAML/OIDC, ISPSS ClientCredentials/SSO), when a credential is
        already present, or when nothing is stored.
    #>
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$Token,
        [Parameter(Mandatory = $true)] [string]$AuthTokenProfileName
    )
    $usesCredential =
        ($Token.SystemType -eq 'SelfHosted' -and $Token.AuthMethod -in @('CyberArk', 'LDAP', 'RADIUS')) -or
        ($Token.SystemType -eq 'ISPSS' -and $Token.AuthMethod -eq 'Interactive')
    if (-not $usesCredential) { return }
    if (-not $Token.PSObject.Properties['_RefreshContext'] -or -not $Token._RefreshContext) { return }
    if ($Token._RefreshContext['Credential']) { return }

    $stored = Get-ProfileCredential -Name $AuthTokenProfileName -ProfileDir $script:ProfileDir
    if ($stored) {
        $Token._RefreshContext['Credential'] = $stored
        Write-CyberArkLog -Level 'INFO' -Message "Automation mode: loaded stored credential for '$AuthTokenProfileName' - the saved session's own _RefreshContext had none."
    }
}

#endregion

#region --- currentProfile CRUD ---

function Get-AllDriverProfiles {
    $jsonFiles = Get-ChildItem -LiteralPath $script:ProfileDir -Filter '*.json' -File -ErrorAction SilentlyContinue
    Write-CyberArkLog -Message "Scanning profiles in '$($script:ProfileDir)': $(@($jsonFiles).Count) file(s) found." -Level 'DEBUG'
    $selectedProfiles  = foreach ($f in $jsonFiles) {
        try {
            $p        = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            # Normalize: add any fields introduced after this profile was saved
            foreach ($field in @('SystemType', 'AppName', 'AuthMethod', 'Username', 'BaseURL', 'LogFolder', 'InputFolder', 'OutputFolder', 'TenantPortal', 'TenantVault', 'TenantAuth', 'Role_Template_Safe', 'Role_Group_Prefix', 'CPM_List', 'WebView2AssemblyPath')) {
                $defaultVal = if ($field -eq 'AppName') { 'PasswordVault' } else { '' }
                if (-not $p.PSObject.Properties[$field]) {
                    $p | Add-Member -NotePropertyName $field -NotePropertyValue $defaultVal -Force
                }
            }
            foreach ($field in @('IgnoreSSL', 'WhatIfDefault', 'IsDefault')) {
                if (-not $p.PSObject.Properties[$field]) {
                    $p | Add-Member -NotePropertyName $field -NotePropertyValue $false -Force
                }
            }
            if (-not $p.PSObject.Properties['Limit']) {
                $p | Add-Member -NotePropertyName 'Limit' -NotePropertyValue 0 -Force
            }
            if (-not $p.PSObject.Properties['DisplayLimit']) {
                $p | Add-Member -NotePropertyName 'DisplayLimit' -NotePropertyValue 20 -Force
            }
            $xmlPath  = Get-ProfileTokenPath -Name $p.AuthTokenProfile
            $hasToken = Test-Path -LiteralPath $xmlPath

            $tokenStatus = 'No Token'
            $expiry      = $null
            $systemType  = ''
            $authMethod  = ''
            $baseURL     = ''

            if ($hasToken) {
                try {
                    $xml        = Import-Clixml -LiteralPath $xmlPath
                    $expiry     = $xml.Expiry
                    $systemType = $xml.SystemType
                    $authMethod = $xml.AuthMethod
                    $baseURL    = $xml.BaseURL
                    $tokenStatus = if ($expiry -and $expiry -lt (Get-Date).ToUniversalTime()) {
                        'Expired'
                    } else { 'Valid' }
                } catch {
                    $tokenStatus = 'Unreadable'
                }
            }

            # Profile's SystemType takes precedence; map legacy token values to display labels
            $displaySystemType = if ($p.SystemType) { $p.SystemType }
                                 elseif ($systemType -eq 'ISPSS')      { 'Privilege Cloud' }
                                 elseif ($systemType -eq 'SelfHosted') { 'Self-Hosted' }
                                 else                                   { $systemType }

            $expiryStr = if ($expiry) { $expiry.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { 'n/a' }
            Write-CyberArkLog -Message "  Profile '$($p.ProfileName)': $displaySystemType | $($p.AuthMethod) | Token: $tokenStatus | Expiry: $expiryStr" -Level 'DEBUG'

            [PSCustomObject]@{
                ProfileName    = $p.ProfileName
                SystemType     = $displaySystemType
                AuthMethod     = if ($authMethod) { $authMethod } elseif ($p.AuthMethod) { $p.AuthMethod } else { '' }
                BaseURL        = $baseURL
                TokenStatus    = $tokenStatus
                Expiry         = $expiry
                LastUsed       = $p.LastUsed
                JsonPath       = $f.FullName
                currentProfile = $p
            }
        } catch {
            Write-CyberArkLog -Message "Failed to read profile '$($f.Name)': $_" -Level 'WARN'
        }
    }
    return @($selectedProfiles | Sort-Object ProfileName)
}

function Read-DriverProfile {
    param([string]$Name)
    $path = Get-ProfileJsonPath -Name $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Save-DriverProfile {
    param([PSCustomObject]$currentProfile)
    $currentProfile.Modified = (Get-Date).ToUniversalTime().ToString('o')
    $path = Get-ProfileJsonPath -Name $currentProfile.ProfileName
    $currentProfile | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
}

function New-BlankProfile {
    param([string]$Name)
    return [PSCustomObject]@{
        ProfileName      = $Name
        AuthTokenProfile = $Name
        SystemType       = ''
        AppName          = 'PasswordVault'
        AuthMethod       = ''
        Username         = ''
        BaseURL          = ''
        LogFolder        = ''
        InputFolder      = ''
        OutputFolder     = ''
        IgnoreSSL        = $false
        # Only consulted for SAML/OIDC (Self-Hosted) or SSO (ISPSS) login - see
        # Import-WebView2Assembly's own candidate-path search. Empty means auto-detect.
        # Testing-Plan.md K11: previously unreachable through the driver at all.
        WebView2AssemblyPath = ''
        WhatIfDefault    = $false
        IsDefault        = $false
        Limit            = 0
        TenantPortal     = ''
        TenantVault      = ''
        TenantAuth         = ''
        Role_Template_Safe = ''
        Role_Group_Prefix  = ''
        CPM_List           = ''
        DisplayLimit       = 20
        LastUsed           = $null
        Created          = (Get-Date).ToUniversalTime().ToString('o')
        Modified         = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Remove-DriverProfile {
    param([string]$Name)
    $jsonPath = Get-ProfileJsonPath       -Name $Name
    $xmlPath  = Get-ProfileTokenPath      -Name $Name
    $credPath = Get-ProfileCredentialPath -Name $Name -ProfileDir $script:ProfileDir
    if (Test-Path -LiteralPath $jsonPath) { Remove-Item -LiteralPath $jsonPath -Force }
    if (Test-Path -LiteralPath $xmlPath)  { Remove-Item -LiteralPath $xmlPath  -Force }
    if (Test-Path -LiteralPath $credPath) { Remove-Item -LiteralPath $credPath -Force }
}

#endregion

#region --- currentProfile Backup/Restore ---

function Get-BackupSavePath {
    <#
        WinForms SaveFileDialog with a console fallback, mirroring Get-CsvSavePath - used when
        choosing where to write a profile backup .zip.
    #>
    param([string]$DefaultFileName)

    $defaultDir = $PSScriptRoot
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog                  = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Title            = 'Save Profile Backup'
        $dialog.Filter           = 'Zip Files (*.zip)|*.zip|All Files (*.*)|*.*'
        $dialog.DefaultExt       = 'zip'
        $dialog.FileName         = $DefaultFileName
        $dialog.InitialDirectory = $defaultDir
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.FileName
        }
        return $null
    } catch {
        $path = Show-FieldPrompt -Label 'Backup save path' -Default (Join-Path $defaultDir $DefaultFileName) `
            -Description 'Full path for the backup .zip file. Leave blank to cancel.'
        if ($path) { return $path } else { return $null }
    }
}

function Get-BackupOpenPath {
    <#
        WinForms OpenFileDialog with a console fallback - the "open" counterpart to
        Get-BackupSavePath, used when picking a backup .zip to restore from. No such helper
        existed anywhere in the project before this (Select-InputFiles has no console fallback).
    #>
    param()

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog                  = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title            = 'Select Profile Backup'
        $dialog.Filter           = 'Zip Files (*.zip)|*.zip|All Files (*.*)|*.*'
        $dialog.Multiselect      = $false
        $dialog.InitialDirectory = $PSScriptRoot
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.FileName
        }
        return $null
    } catch {
        $path = Show-FieldPrompt -Label 'Backup file path' `
            -Description 'Full path to the backup .zip file to restore from. Leave blank to cancel.'
        if (-not $path) { return $null }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Host "  File not found: $path" -ForegroundColor Red
            return $null
        }
        return $path
    }
}

function script:Add-ZipEntryFromFile {
    <#
        Writes $SourcePath's raw bytes into a new zip entry - manual CreateEntry()+stream-write
        rather than the ZipFileExtensions.CreateEntryFromFile() convenience method, since that
        extension method lives in the separate System.IO.Compression.FileSystem assembly this
        project doesn't otherwise depend on. Matches the byte-stream pattern already established
        by Invoke-CustomExportPlatformDetails.ps1's zip-reading code.
    #>
    param([System.IO.Compression.ZipArchive]$Zip, [string]$SourcePath, [string]$EntryName)
    $entry       = $Zip.CreateEntry($EntryName)
    $entryStream = $entry.Open()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($SourcePath)
        $entryStream.Write($bytes, 0, $bytes.Length)
    } finally {
        $entryStream.Dispose()
    }
}

function script:Save-ZipEntryToFile {
    param([System.IO.Compression.ZipArchiveEntry]$Entry, [string]$DestinationPath)
    $entryStream = $Entry.Open()
    try {
        $fileStream = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::Create)
        try { $entryStream.CopyTo($fileStream) } finally { $fileStream.Dispose() }
    } finally {
        $entryStream.Dispose()
    }
}

function Backup-DriverProfiles {
    <#
        Writes a .zip containing each named profile's .json (settings) and .cred (saved token, if
        present) files, plus a _manifest.json recording who/when/where the backup was made - used
        by Restore-DriverProfiles to warn if a .cred is being restored to a different Windows
        user/machine than it was encrypted for. DPAPI (the mechanism CyberArk.Auth.Common.psm1
        uses for .cred files) is deliberately user+machine-locked - see Architecture.md's Design
        Decisions table - so a .cred backed up here can only ever be usefully restored to the same
        user account on the same machine it came from; the .json settings are fully portable.
    #>
    param(
        [Parameter(Mandatory = $true)] [string[]]$ProfileNames,
        [Parameter(Mandatory = $true)] [string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

    $destDir = Split-Path -Path $DestinationPath -Parent
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $manifest = [PSCustomObject]@{
        CreatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        CreatedBy    = "$env:USERDOMAIN\$env:USERNAME"
        CreatedOnPC  = $env:COMPUTERNAME
        ProfileNames = @($ProfileNames)
    }

    $fs       = $null
    $zip      = $null
    $included = [System.Collections.Generic.List[string]]::new()
    $missing  = [System.Collections.Generic.List[string]]::new()
    try {
        $fs  = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::Create)
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)

        $manifestEntry  = $zip.CreateEntry('_manifest.json')
        $manifestStream = $manifestEntry.Open()
        try {
            $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 5))
            $manifestStream.Write($manifestBytes, 0, $manifestBytes.Length)
        } finally {
            $manifestStream.Dispose()
        }

        foreach ($name in $ProfileNames) {
            $jsonPath = Get-ProfileJsonPath -Name $name
            if (-not (Test-Path -LiteralPath $jsonPath)) {
                $missing.Add($name)
                continue
            }
            script:Add-ZipEntryFromFile -Zip $zip -SourcePath $jsonPath -EntryName "$name.json"

            $tokenPath = Get-ProfileTokenPath -Name $name
            if (Test-Path -LiteralPath $tokenPath) {
                script:Add-ZipEntryFromFile -Zip $zip -SourcePath $tokenPath -EntryName "$name.cred"
            }
            $included.Add($name)
        }
    } finally {
        if ($zip) { $zip.Dispose() }
        if ($fs)  { $fs.Dispose() }
    }

    return [PSCustomObject]@{
        Included = $included.ToArray()
        Missing  = $missing.ToArray()
    }
}

function Restore-DriverProfiles {
    <#
        Reads a backup .zip (written by Backup-DriverProfiles) and restores the requested profiles
        into the local Profiles folder. Always restores the .json settings file; if a .cred token
        file is present in the archive, restores it too, but flags it in PortabilityWarnings when
        the manifest recorded a different Windows user/machine than the current one - a
        DPAPI-encrypted .cred from elsewhere cannot be decrypted here (by design). The restored
        file is left in place regardless: this driver already has an "Unreadable" token status for
        exactly this case (a .cred file present but not decryptable), so an unusable restored
        token degrades gracefully into the same "please re-authenticate" flow as any other
        unreadable token, rather than needing special-case handling here.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$SourcePath,
        [Parameter(Mandatory = $true)] [string[]]$ProfileNames
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

    $fs       = $null
    $zip      = $null
    $manifest = $null
    $restored = [System.Collections.Generic.List[string]]::new()
    $skipped  = [System.Collections.Generic.List[string]]::new()
    $warned   = [System.Collections.Generic.List[string]]::new()
    try {
        $fs  = [System.IO.File]::Open($SourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)

        $manifestEntry = $zip.Entries | Where-Object { $_.FullName -eq '_manifest.json' } | Select-Object -First 1
        if ($manifestEntry) {
            $reader = $null
            try {
                $reader   = New-Object System.IO.StreamReader($manifestEntry.Open())
                $manifest = $reader.ReadToEnd() | ConvertFrom-Json
            } catch {
                Write-CyberArkLog -Message "Could not parse backup manifest in '$SourcePath': $_" -Level 'WARN'
            } finally {
                if ($reader) { $reader.Dispose() }
            }
        }
        $currentUser = "$env:USERDOMAIN\$env:USERNAME"
        $samePlace   = $manifest -and $manifest.CreatedBy -eq $currentUser -and $manifest.CreatedOnPC -eq $env:COMPUTERNAME

        foreach ($name in $ProfileNames) {
            $jsonEntry = $zip.Entries | Where-Object { $_.FullName -eq "$name.json" } | Select-Object -First 1
            if (-not $jsonEntry) {
                $skipped.Add($name)
                continue
            }

            $jsonPath = Get-ProfileJsonPath -Name $name
            if ((Test-Path -LiteralPath $jsonPath) -and -not (Confirm-Action "Profile '$name' already exists locally. Overwrite?")) {
                $skipped.Add($name)
                continue
            }

            script:Save-ZipEntryToFile -Entry $jsonEntry -DestinationPath $jsonPath

            $credEntry = $zip.Entries | Where-Object { $_.FullName -eq "$name.cred" } | Select-Object -First 1
            if ($credEntry) {
                script:Save-ZipEntryToFile -Entry $credEntry -DestinationPath (Get-ProfileTokenPath -Name $name)
                if ($manifest -and -not $samePlace) { $warned.Add($name) }
            }

            $restored.Add($name)
        }
    } finally {
        if ($zip) { $zip.Dispose() }
        if ($fs)  { $fs.Dispose() }
    }

    return [PSCustomObject]@{
        Restored            = $restored.ToArray()
        Skipped             = $skipped.ToArray()
        PortabilityWarnings = $warned.ToArray()
        Manifest            = $manifest
    }
}

function Invoke-ProfileBackupFlow {
    <#
        Interactive "back up one or more profiles" screen: numbered checklist (comma-separated
        picks, or "all"), then a save-file prompt, then calls Backup-DriverProfiles.
    #>
    param([string[]]$Breadcrumbs)

    Show-Header -Breadcrumbs $Breadcrumbs
    $profiles = @(Get-AllDriverProfiles)
    if (-not $profiles -or $profiles.Count -eq 0) {
        Write-Host '  No profiles to back up.' -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
        return
    }

    Write-Host '  Select profiles to back up:' -ForegroundColor White
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        Write-Host ("    [$($i + 1)] $($profiles[$i].ProfileName)") -ForegroundColor Gray
    }
    Write-Host ''
    $sel = Show-FieldPrompt -Label 'Profiles' `
        -Description 'Comma-separated numbers, or "all". Leave blank to cancel.'
    if (-not $sel) { return }

    # Wrapped in @(...): PowerShell unwraps a single-element array assigned from an if/else
    # expression to its bare scalar element (confirmed directly) - selecting exactly one profile
    # would otherwise make $names a plain [string], and $names.Count below would throw under
    # Set-StrictMode -Version Latest. See Testing-Plan.md K14.
    $names = @(if ($sel.Trim() -ieq 'all') {
        @($profiles.ProfileName)
    } else {
        $picked = [System.Collections.Generic.List[string]]::new()
        foreach ($idxStr in ($sel -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $idx = 0
            if ([int]::TryParse($idxStr, [ref]$idx) -and $idx -ge 1 -and $idx -le $profiles.Count) {
                $picked.Add($profiles[$idx - 1].ProfileName)
            } else {
                Write-Host "  Ignoring invalid selection: $idxStr" -ForegroundColor Yellow
            }
        }
        $picked.ToArray()
    })

    if (-not $names -or $names.Count -eq 0) {
        Write-Host '  No valid profiles selected.' -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }

    $destPath = Get-BackupSavePath -DefaultFileName "aPePAS-Profiles-Backup-$(Get-Date -Format 'yyyy-MM-dd').zip"
    if (-not $destPath) {
        Write-Host '  Backup cancelled.' -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
        return
    }

    try {
        $result = Backup-DriverProfiles -ProfileNames $names -DestinationPath $destPath
        Write-Host ''
        Write-Host "  Backed up $($result.Included.Count) profile(s) to: $destPath" -ForegroundColor Green
        if ($result.Missing.Count -gt 0) {
            Write-Host "  Skipped (no longer exist): $($result.Missing -join ', ')" -ForegroundColor Yellow
        }
        Write-CyberArkLog -Message "Backed up profiles [$($result.Included -join ', ')] to '$destPath'." -Level 'INFO'
    } catch {
        Write-Host "  Backup failed: $_" -ForegroundColor Red
        Write-CyberArkLog -Message "Profile backup failed: $_" -Level 'ERROR'
    }
    Write-Host '  Press Enter to continue.' -ForegroundColor DarkGray
    Read-Host | Out-Null
}

function Invoke-ProfileRestoreFlow {
    <#
        Interactive "restore one or more profiles" screen: picks a backup .zip, lists the
        profiles it contains, numbered checklist (comma-separated picks, or "all"), then calls
        Restore-DriverProfiles and surfaces any cross-machine/user token portability warnings.
    #>
    param([string[]]$Breadcrumbs)

    Show-Header -Breadcrumbs $Breadcrumbs
    $sourcePath = Get-BackupOpenPath
    if (-not $sourcePath) {
        Write-Host '  Restore cancelled.' -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
        return
    }

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    $fs        = $null
    $zip       = $null
    $available = @()
    try {
        $fs  = [System.IO.File]::Open($sourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
        $available = @($zip.Entries | Where-Object { $_.FullName -like '*.json' -and $_.FullName -ne '_manifest.json' } |
            ForEach-Object { $_.FullName -replace '\.json$', '' })
    } catch {
        Write-Host "  Could not read backup file: $_" -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    } finally {
        if ($zip) { $zip.Dispose() }
        if ($fs)  { $fs.Dispose() }
    }

    if ($available.Count -eq 0) {
        Write-Host '  No profiles found in that backup file.' -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }

    Write-Host ''
    Write-Host '  Profiles found in backup:' -ForegroundColor White
    for ($i = 0; $i -lt $available.Count; $i++) {
        Write-Host ("    [$($i + 1)] $($available[$i])") -ForegroundColor Gray
    }
    Write-Host ''
    $sel = Show-FieldPrompt -Label 'Profiles to restore' `
        -Description 'Comma-separated numbers, or "all". Leave blank to cancel.'
    if (-not $sel) { return }

    # Wrapped in @(...): PowerShell unwraps a single-element array assigned from an if/else
    # expression to its bare scalar element (confirmed directly) - selecting exactly one profile
    # would otherwise make $names a plain [string], and $names.Count below would throw under
    # Set-StrictMode -Version Latest. See Testing-Plan.md K14.
    $names = @(if ($sel.Trim() -ieq 'all') {
        $available
    } else {
        $picked = [System.Collections.Generic.List[string]]::new()
        foreach ($idxStr in ($sel -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $idx = 0
            if ([int]::TryParse($idxStr, [ref]$idx) -and $idx -ge 1 -and $idx -le $available.Count) {
                $picked.Add($available[$idx - 1])
            } else {
                Write-Host "  Ignoring invalid selection: $idxStr" -ForegroundColor Yellow
            }
        }
        $picked.ToArray()
    })

    if (-not $names -or $names.Count -eq 0) {
        Write-Host '  No valid profiles selected.' -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        return
    }

    try {
        $result = Restore-DriverProfiles -SourcePath $sourcePath -ProfileNames $names
        Write-Host ''
        if ($result.Restored.Count -gt 0) {
            Write-Host "  Restored: $($result.Restored -join ', ')" -ForegroundColor Green
        }
        if ($result.Skipped.Count -gt 0) {
            Write-Host "  Skipped: $($result.Skipped -join ', ')" -ForegroundColor Yellow
        }
        if ($result.PortabilityWarnings.Count -gt 0) {
            Write-Host ''
            Write-Host '  WARNING: the saved session for the following profile(s) was backed up on a' -ForegroundColor Yellow
            Write-Host '  different Windows user/machine and cannot be decrypted here (DPAPI is' -ForegroundColor Yellow
            Write-Host '  user+machine locked by design). You will need to re-authenticate:' -ForegroundColor Yellow
            Write-Host "    $($result.PortabilityWarnings -join ', ')" -ForegroundColor Yellow
        }
        Write-CyberArkLog -Message "Restored profiles [$($result.Restored -join ', ')] from '$sourcePath'." -Level 'INFO'
    } catch {
        Write-Host "  Restore failed: $_" -ForegroundColor Red
        Write-CyberArkLog -Message "Profile restore failed: $_" -Level 'ERROR'
    }
    Write-Host '  Press Enter to continue.' -ForegroundColor DarkGray
    Read-Host | Out-Null
}

#endregion

#region --- currentProfile Display ---

function Show-ProfileList {
    param([PSCustomObject[]]$selectedProfiles, [string[]]$Breadcrumbs)
    Show-Header -Breadcrumbs $Breadcrumbs

    if (-not $selectedProfiles -or $selectedProfiles.Count -eq 0) {
        Write-Host '  No profiles found.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  [N] New Profile    [X] Restore    [Q] Quit' -ForegroundColor White
        return
    }

    # Column widths
    $numW  = 3
    $nameW = [Math]::Max(16, ($selectedProfiles | ForEach-Object { $_.ProfileName.Length } | Measure-Object -Maximum).Maximum + 2)
    $sysW  = 15
    $authW = 20
    $useW  = 17
    $statW = 10

    $hdr = "  {0,-$numW}  {1,-$nameW}  {2,-$sysW}  {3,-$authW}  {4,-$useW}  {5,-$statW}" -f '#', 'Profile Name', 'System', 'Auth Method', 'Last Used', 'Token'
    Write-Host $hdr -ForegroundColor DarkCyan
    Write-Host ('  ' + ('-' * ($hdr.Length - 2))) -ForegroundColor DarkGray

    $i = 1
    $anyDefault = $false
    foreach ($p in $selectedProfiles) {
        $lastUsed = if ($p.LastUsed) {
            try { ([datetime]$p.LastUsed).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { '?' }
        } else { 'Never' }

        $statusColor = switch ($p.TokenStatus) {
            'Valid'       { 'Green' }
            'Expired'     { 'Yellow' }
            'Unreadable'  { 'Red' }
            default       { 'DarkGray' }
        }

        $isDefault = $p.currentProfile.PSObject.Properties['IsDefault'] -and [bool]$p.currentProfile.IsDefault
        if ($isDefault) { $anyDefault = $true }
        $numLabel = if ($isDefault) { "$i*" } else { "$i" }

        $row = "  {0,-$numW}  {1,-$nameW}  {2,-$sysW}  {3,-$authW}  {4,-$useW}" -f $numLabel, $p.ProfileName, $p.SystemType, $p.AuthMethod, $lastUsed
        Write-Host $row -NoNewline
        Write-Host ("  {0,-$statW}" -f $p.TokenStatus) -ForegroundColor $statusColor
        $i++
    }

    Write-Host ''
    if ($anyDefault) { Write-Host '  (* = default profile)' -ForegroundColor DarkGray }
    Show-Divider
    Write-Host '  Enter a number to view details, or:' -ForegroundColor DarkGray
    Write-Host '  [N] New Profile    [K] Backup    [X] Restore    [Q] Quit' -ForegroundColor White
}

function Show-ProfileDetail {
    param([PSCustomObject]$Summary, [string[]]$Breadcrumbs)
    Show-Header -Breadcrumbs $Breadcrumbs

    $p = $Summary.currentProfile

    function Field([string]$label, [string]$value, [string]$color = 'Gray') {
        Write-Host ("    {0,-22}" -f $label) -NoNewline -ForegroundColor DarkGray
        Write-Host $value -ForegroundColor $color
    }

    Write-Host '  Profile Settings' -ForegroundColor White
    Show-Divider
    Field 'Profile Name'    $p.ProfileName    'Cyan'
    Field 'Auth Profile'    $p.AuthTokenProfile
    Field 'System Type'     $(if ($p.SystemType)  { $p.SystemType }  else { '(Not Set)' }) $(if ($p.SystemType) { 'Cyan' } else { 'Yellow' })
    Field 'Auth Method'     $(if ($p.AuthMethod)  { $p.AuthMethod }  else { '(Not Set)' }) $(if ($p.AuthMethod) { 'Cyan' } else { 'Yellow' })
    Field 'Username'        $(if ($p.Username)     { $p.Username }   else { '(Not Set)' }) $(if ($p.Username)   { 'Cyan' } else { 'Yellow' })
    Field 'Base URL'        $(if ($p.BaseURL)      { $p.BaseURL } else { '(Not Set)' })
    if ($p.SystemType -eq 'Privilege Cloud') {
        if ($p.PSObject.Properties['TenantPortal'] -and $p.TenantPortal) { Field 'Tenant Portal' $p.TenantPortal }
        if ($p.PSObject.Properties['TenantVault']  -and $p.TenantVault)  { Field 'Tenant Vault'  $p.TenantVault  }
        if ($p.PSObject.Properties['TenantAuth']   -and $p.TenantAuth)   { Field 'Tenant Auth'   $p.TenantAuth   }
    }
    Field 'Application'     $(if ($p.AppName)      { $p.AppName } else { 'PasswordVault' })
    Field 'Log Folder'      $(if ($p.LogFolder)    { $p.LogFolder    } else { '(launch directory)' })
    Field 'Input Folder'    $(if ($p.InputFolder)  { $p.InputFolder  } else { '(launch directory)' })
    Field 'Output Folder'   $(if ($p.OutputFolder) { $p.OutputFolder } else { '(launch directory)' })
    Field 'Ignore SSL'      $p.IgnoreSSL     $(if ($p.IgnoreSSL)     { 'Yellow' } else { 'Gray' })
    if ($p.PSObject.Properties['WebView2AssemblyPath'] -and $p.WebView2AssemblyPath) { Field 'WebView2 Assembly' $p.WebView2AssemblyPath }
    Field 'WhatIf Default'  $p.WhatIfDefault $(if ($p.WhatIfDefault) { 'Yellow' } else { 'Gray' })
    $isDefault = $p.PSObject.Properties['IsDefault'] -and [bool]$p.IsDefault
    Field 'Default Profile' $(if ($isDefault) { 'Yes' } else { 'No' }) $(if ($isDefault) { 'Green' } else { 'Gray' })
    $dpLimit = if ($p.PSObject.Properties['DisplayLimit']) { [int]$p.DisplayLimit } else { 20 }
    Field 'Display Limit'   $(if ($dpLimit -eq 0) { 'Show all' } else { "$dpLimit rows" })
    if ($p.PSObject.Properties['Role_Template_Safe'] -and $p.Role_Template_Safe) { Field 'Role Template Safe' $p.Role_Template_Safe }
    if ($p.PSObject.Properties['Role_Group_Prefix']  -and $p.Role_Group_Prefix)  { Field 'Role Group Prefix'  $p.Role_Group_Prefix  }
    if ($p.PSObject.Properties['CPM_List'] -and $p.CPM_List) { Field 'CPM List' $p.CPM_List }
    $created  = try { ([datetime]$p.Created).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }  catch { $p.Created }
    $modified = try { ([datetime]$p.Modified).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { $p.Modified }
    Field 'Created'         $created
    Field 'Modified'        $modified

    Write-Host ''
    Write-Host '  Authentication Token' -ForegroundColor White
    Show-Divider

    if ($Summary.TokenStatus -eq 'No Token') {
        Write-Host '    No token file found.' -ForegroundColor DarkGray
    } else {
        $expiryStr = if ($Summary.Expiry) {
            $local = try { ([datetime]$Summary.Expiry).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { '?' }
            "$local ($($Summary.TokenStatus))"
        } else { 'Unknown' }

        $expiryColor = switch ($Summary.TokenStatus) {
            'Valid'      { 'Green' }
            'Expired'    { 'Yellow' }
            default      { 'Red' }
        }

        Field 'System Type'     $Summary.SystemType
        Field 'Auth Method'     $Summary.AuthMethod
        Field 'Base URL'        $Summary.BaseURL
        Field 'Token Expiry'    $expiryStr $expiryColor
        Field 'Token Value'     '***'
    }

    Write-Host ''
    Show-Divider
    $fLabel = if ($isDefault) { '[F] Clear Default' } else { '[F] Set as Default' }
    Write-Host "  [C] Continue    [E] Edit    [P] Copy    [D] Delete    [T] Test Connection    [L] Log Out    $fLabel    [B] Back" -ForegroundColor White
}

#endregion

#region --- currentProfile Edit Flow ---

function Invoke-ProfileEditFlow {
    param(
        [PSCustomObject]$currentProfile,
        [string[]]$Breadcrumbs,
        [switch]$IsNew
    )

    Show-Header -Breadcrumbs $Breadcrumbs
    Write-Host '  Profile Settings' -ForegroundColor White
    Write-Host '  (Press Enter to keep the current value)' -ForegroundColor DarkGray
    Write-Host ''

    # currentProfile Name - only editable on new profiles; for copy the name is already set
    if ($IsNew) {
        while ($true) {
            $name = Show-FieldPrompt -Label 'Profile Name' -Default $currentProfile.ProfileName -Required `
                -Description 'Unique name for this profile (e.g. Development, Production)'
            if (-not $name) {
                Write-Host '    Profile Name is required.' -ForegroundColor Red
                continue
            }
            $existingPath = Get-ProfileJsonPath -Name $name
            if ((Test-Path -LiteralPath $existingPath) -and $name -ne $currentProfile.ProfileName) {
                Write-Host "    A profile named '$name' already exists." -ForegroundColor Red
                continue
            }
            $currentProfile.ProfileName      = $name
            $currentProfile.AuthTokenProfile = $name
            break
        }
    } else {
        Write-Host "    Profile Name     : $($currentProfile.ProfileName)  (not editable)" -ForegroundColor DarkGray
    }

    Write-Host ''
    # System Type - numbered choice so the user only has to type one key
    $sysTypeMap = @{ '1' = 'Privilege Cloud'; '2' = 'Self-Hosted' }
    Write-Host '  System Type:' -ForegroundColor White
    Write-Host '    [1] Privilege Cloud   - SaaS / ISPSS  (*.privilegecloud.cyberark.cloud)' -ForegroundColor Gray
    Write-Host '    [2] Self-Hosted       - On-premises PVWA' -ForegroundColor Gray
    if ($currentProfile.SystemType) {
        Write-Host ("    Current: $($currentProfile.SystemType)") -ForegroundColor DarkCyan
    }
    $sysChoice = ''
    do {
        $sysChoice = Read-MenuChoice -Prompt '1 / 2'
        if ($sysChoice -notin @('1', '2')) {
            Write-Host '    Invalid - enter 1 or 2.' -ForegroundColor Red
        }
    } while ($sysChoice -notin @('1', '2'))
    $currentProfile.SystemType = $sysTypeMap[$sysChoice]

    # Auth Method - numbered choice, depends on SystemType
    Write-Host ''
    $ispssAuthMethods      = @('ClientCredentials', 'Interactive', 'SSO')
    $selfHostedAuthMethods = @('CyberArk', 'LDAP', 'RADIUS', 'SAML', 'OIDC', 'Shared', 'PKI', 'PKIPN')
    $authMethods = if ($currentProfile.SystemType -eq 'Privilege Cloud') { $ispssAuthMethods } else { $selfHostedAuthMethods }
    Write-Host '  Auth Method:' -ForegroundColor White
    for ($i = 0; $i -lt $authMethods.Count; $i++) {
        Write-Host ("    [$($i+1)] $($authMethods[$i])") -ForegroundColor Gray
    }
    if ($currentProfile.AuthMethod -and $currentProfile.AuthMethod -in $authMethods) {
        Write-Host ("    Current: $($currentProfile.AuthMethod)") -ForegroundColor DarkCyan
    }
    $methodChoice = ''
    do {
        $methodChoice = Read-MenuChoice -Prompt "1 - $($authMethods.Count)"
        $methodIdx = 0
        $methodValid = [int]::TryParse($methodChoice, [ref]$methodIdx) -and $methodIdx -ge 1 -and $methodIdx -le $authMethods.Count
        if (-not $methodValid) {
            Write-Host "    Invalid - enter 1 through $($authMethods.Count)." -ForegroundColor Red
        }
    } while (-not $methodValid)
    $currentProfile.AuthMethod = $authMethods[$methodIdx - 1]

    # Base URL - prompt depends on SystemType
    Write-Host ''
    $pcloudTemplate = 'https://{0}.privilegecloud.cyberark.cloud'
    switch ($currentProfile.SystemType) {
        'Privilege Cloud' {
            $subdomain = ''
            if ($currentProfile.BaseURL -match '^https://(.+)\.privilegecloud\.cyberark\.cloud/?$') {
                $subdomain = $Matches[1]
            }
            $subdomain = Show-FieldPrompt -Label 'Privilege Cloud Subdomain' -Default $subdomain `
                -Description 'Subdomain of your tenant URL. For acme.privilegecloud.cyberark.cloud, enter: acme'
            if ($subdomain) {
                $cleanSub = $subdomain.Trim()
                $currentProfile.BaseURL      = $pcloudTemplate -f $cleanSub
                $currentProfile.TenantPortal = "$cleanSub.cyberark.com"
                $currentProfile.TenantVault  = "vault-$cleanSub.privilegecloud.cyberark.com"
                Write-Host "    Tenant Portal : $($currentProfile.TenantPortal)" -ForegroundColor DarkGray
                Write-Host "    Tenant Vault  : $($currentProfile.TenantVault)"  -ForegroundColor DarkGray
                Write-Host '    Discovering identity URL...' -ForegroundColor DarkGray
                try {
                    $resolved = Resolve-IdentityTenantURL -PCloudSubdomain $cleanSub
                    Write-Verbose ("Resolution Result: {0}" -f $resolved)
                    if ($resolved) {
                        $currentProfile.TenantAuth = $resolved
                        Write-Host "    Tenant Auth   : $resolved" -ForegroundColor DarkGray
                    } else {
                        Write-Host '    Tenant Auth   : (not discovered - will resolve at login)' -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host '    Tenant Auth   : (discovery failed - will resolve at login)' -ForegroundColor Yellow
                }
            }
        }
        'Self-Hosted' {
            $currentProfile.BaseURL = Show-FieldPrompt -Label 'PVWA Base URL' -Default $currentProfile.BaseURL `
                -Description 'Base URL of your PVWA server. Example: https://pvwa.company.com'
            if ($currentProfile.BaseURL) {
                $currentProfile.BaseURL = $currentProfile.BaseURL.TrimEnd('/')
            }
        }
    }

    Write-Host ''
    $appNameDefault = if ($currentProfile.AppName) { $currentProfile.AppName } else { 'PasswordVault' }
    $enteredAppName = Show-FieldPrompt -Label 'Application Name' -Default $appNameDefault `
        -Description 'CyberArk application name in the URL path (e.g. PasswordVault). Joined with Base URL for API calls.'
    $currentProfile.AppName = if ($enteredAppName) { $enteredAppName } else { 'PasswordVault' }

    $currentProfile.Username = Show-FieldPrompt -Label 'Username' -Default $currentProfile.Username `
        -Description 'Default username pre-filled in the credential prompt at login. Leave blank to always be prompted.'

    $currentProfile.LogFolder = Show-FieldPrompt -Label 'Log Folder' -Default $currentProfile.LogFolder `
        -Description 'Absolute path for log files. Leave blank to use the script launch directory.'

    $currentProfile.InputFolder = Show-FieldPrompt -Label 'Input Folder' -Default $currentProfile.InputFolder `
        -Description 'Default folder for CSV input file pickers. Leave blank for launch directory.'

    $currentProfile.OutputFolder = Show-FieldPrompt -Label 'Output Folder' -Default $currentProfile.OutputFolder `
        -Description 'Destination for output CSV files. Leave blank for launch directory.'

    Write-Host ''
    $sslStr = Show-FieldPrompt -Label 'Ignore SSL Errors' -Default $(if ($currentProfile.IgnoreSSL) { 'Y' } else { 'N' }) `
        -Description 'Bypass SSL certificate validation? (Y/N) - Use only for lab/dev environments.'
    $currentProfile.IgnoreSSL = $sslStr -match '^[Yy]$'

    $currentProfile.WebView2AssemblyPath = Show-FieldPrompt -Label 'WebView2 Assembly Path' `
        -Default $(if ($currentProfile.PSObject.Properties['WebView2AssemblyPath']) { $currentProfile.WebView2AssemblyPath } else { '' }) `
        -Description 'Only used for SAML/OIDC (Self-Hosted) or SSO (ISPSS) login, and only if Microsoft.Web.WebView2.WinForms.dll is not found in one of the usual locations (see README Requirements). Full path to the DLL. Leave blank to auto-detect.'

    $wiStr = Show-FieldPrompt -Label 'WhatIf Default' -Default $(if ($currentProfile.WhatIfDefault) { 'Y' } else { 'N' }) `
        -Description 'Default to WhatIf mode for this profile? (Y/N) - Recommended for production.'
    $currentProfile.WhatIfDefault = $wiStr -match '^[Yy]$'

    $currentLimitDefault = if ($currentProfile.PSObject.Properties['Limit'] -and $currentProfile.Limit -gt 0) { "$($currentProfile.Limit)" } else { '0' }
    $limitStr = Show-FieldPrompt -Label 'Result Limit' -Default $currentLimitDefault `
        -Description 'Maximum results returned by List/Get operations (0 = no limit, e.g. 500).'
    $parsedLimit = 0
    if ($limitStr) { try { $parsedLimit = [int]$limitStr } catch { } }
    if ($parsedLimit -lt 0) { $parsedLimit = 0 }
    $currentProfile.Limit = $parsedLimit

    $currentDisplayLimitDefault = if ($currentProfile.PSObject.Properties['DisplayLimit'] -and $currentProfile.DisplayLimit -ge 0) { "$($currentProfile.DisplayLimit)" } else { '20' }
    $displayLimitStr = Show-FieldPrompt -Label 'Display Limit' -Default $currentDisplayLimitDefault `
        -Description 'Maximum rows shown in table output for List operations (0 = show all, default 20).'
    $parsedDisplayLimit = 20
    if ($displayLimitStr) { try { $parsedDisplayLimit = [int]$displayLimitStr } catch { } }
    if ($parsedDisplayLimit -lt 0) { $parsedDisplayLimit = 0 }
    $currentProfile.DisplayLimit = $parsedDisplayLimit

    $currentProfile.Role_Template_Safe = Show-FieldPrompt -Label 'Role Template Safe' `
        -Default $(if ($currentProfile.PSObject.Properties['Role_Template_Safe']) { $currentProfile.Role_Template_Safe } else { '' }) `
        -Description 'Safe name used as a permission template when assigning roles. Used by Add/Update Safe Member role operations.'

    $currentProfile.Role_Group_Prefix = Show-FieldPrompt -Label 'Role Group Prefix' `
        -Default $(if ($currentProfile.PSObject.Properties['Role_Group_Prefix']) { $currentProfile.Role_Group_Prefix } else { '' }) `
        -Description 'Prefix for CyberArk role groups (e.g. "CyberArk_"). Used by Add/Update Safe Member role operations.'

    $currentProfile.CPM_List = Show-FieldPrompt -Label 'CPM List' `
        -Default $(if ($currentProfile.PSObject.Properties['CPM_List']) { $currentProfile.CPM_List } else { '' }) `
        -Description 'Comma-separated list of CPM usernames (e.g. "PasswordManager,PasswordManager2"). Shown as a picker on pages that ask for a CPM, so you do not have to remember or type the names.'

    Write-Host ''
    Save-DriverProfile -currentProfile $currentProfile
    Write-Host "  Profile '$($currentProfile.ProfileName)' saved." -ForegroundColor Green

    if ($currentProfile.IgnoreSSL) {
        Write-CyberArkLog -Message "Profile '$($currentProfile.ProfileName)' has IgnoreSSL enabled - use only in lab/dev." -Level 'WARN'
    }

    return $currentProfile
}

#endregion

#region --- currentProfile Test Connection ---

function Get-ExpectedTokenBaseURL {
    <#
        Computes the BaseURL a fresh login for $DriverProfile would produce today - Self-Hosted:
        "<profile.BaseURL>/<AppName, default PasswordVault>", mirroring Invoke-ProfileConnect's
        own fresh-auth construction exactly. ISPSS: Get-ISPSSAuthToken builds its own BaseURL from
        a hardcoded "https://<subdomain>.privilegecloud.cyberark.cloud/PasswordVault" template
        (Auth\CyberArk.Auth.ISPSS.psm1's $script:PCLOUD_BASE_TEMPLATE), not from the profile's
        AppName - the subdomain is extracted from profile.BaseURL the same way
        Invoke-ProfileConnect's own authParams construction already does, so this mirrors that
        too rather than assuming Self-Hosted's AppName-based shape also applies to ISPSS.

        Returns $null when the expected URL can't be confidently computed (e.g. no BaseURL set,
        or an ISPSS profile whose BaseURL doesn't match the standard privilegecloud.cyberark.cloud
        shape) - callers should treat $null as "can't compare", never as a mismatch. See
        Testing-Plan.md K04.
    #>
    param([Parameter(Mandatory = $true)] [PSCustomObject]$DriverProfile)
    if (-not $DriverProfile.BaseURL) { return $null }
    if ($DriverProfile.SystemType -eq 'Privilege Cloud') {
        if ($DriverProfile.BaseURL -match '^https://(.+)\.privilegecloud\.cyberark\.cloud') {
            return "https://$($Matches[1]).privilegecloud.cyberark.cloud/PasswordVault"
        }
        return $null
    }
    $appName = if ($DriverProfile.AppName) { $DriverProfile.AppName.Trim('/') } else { 'PasswordVault' }
    return "$($DriverProfile.BaseURL.TrimEnd('/'))/$appName"
}

function Test-TokenBaseURLStale {
    <#
        $true when $Token's own BaseURL no longer matches what a fresh login for $DriverProfile
        would produce today. A token's BaseURL is frozen at original login/refresh time and never
        reconciled against a later profile edit on its own (Testing-Plan.md K04) -
        Invoke-CyberArkAPI builds every request's URI from the token's BaseURL, never the active
        profile's, so a stale token silently keeps calling the pre-edit server indefinitely.

        Case-insensitive, trailing-slash-normalized comparison. Never throws, and returns $false
        (i.e. "assume not stale") whenever the expected URL can't be confidently computed, since
        there's no reliable way to distinguish "genuinely different server" from "cosmetic URL
        edit to the same server" automatically - forcing an unwanted re-login on a false positive
        would be worse than occasionally missing a real edit this function couldn't resolve.
    #>
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$Token,
        [Parameter(Mandatory = $true)] [PSCustomObject]$DriverProfile
    )
    if (-not $Token.PSObject.Properties['BaseURL'] -or -not $Token.BaseURL) { return $false }
    $expected = Get-ExpectedTokenBaseURL -DriverProfile $DriverProfile
    if (-not $expected) { return $false }
    return -not ($Token.BaseURL.TrimEnd('/') -ieq $expected.TrimEnd('/'))
}

function Invoke-ProfileTestConnection {
    param([PSCustomObject]$Summary, [string[]]$Breadcrumbs)
    Show-Header -Breadcrumbs $Breadcrumbs
    Write-Host '  Test Connection' -ForegroundColor White
    Write-Host ''

    $tokenPath = Get-ProfileTokenPath -Name $Summary.currentProfile.AuthTokenProfile

    # If a saved token exists, show its status first
    if (Test-Path -LiteralPath $tokenPath) {
        try {
            $existing = Import-AuthToken -Path $tokenPath -IgnoreExpiry
            if ($existing -and $existing.Token) {
                $isExpired = $existing.Expiry -lt [DateTime]::UtcNow
                $isStale   = Test-TokenBaseURLStale -Token $existing -DriverProfile $Summary.currentProfile
                $statusLabel = if ($isExpired) { 'Expired' } else { 'Valid' }
                $statusColor = if ($isExpired) { 'Yellow'  } else { 'Green'  }
                Write-Host "  Saved token: $statusLabel" -ForegroundColor $statusColor
                Write-Host "    System  : $($existing.SystemType)"  -ForegroundColor Gray
                Write-Host "    Method  : $($existing.AuthMethod)"  -ForegroundColor Gray
                Write-Host "    Base URL: $($existing.BaseURL)"     -ForegroundColor Gray
                Write-Host "    Expires : $($existing.Expiry.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Gray
                Write-Host ''
                if ($isStale) {
                    # See Testing-Plan.md K04: the profile's Base URL has changed since this
                    # token was saved. Never reuse a session against an unverified server - fall
                    # straight through to a fresh authentication against the profile's current URL.
                    Write-Host '  Profile Base URL has changed since this token was saved.' -ForegroundColor Yellow
                    Write-Host '  Re-authenticating against the current Base URL...' -ForegroundColor Yellow
                    Write-Host ''
                } elseif (-not $isExpired) {
                    if ($existing.SystemType -eq 'ISPSS') {
                        Write-Host '  Privilege Cloud: no server validation endpoint.' -ForegroundColor DarkGray
                        Write-Host '  Token accepted based on local expiry.' -ForegroundColor DarkGray
                        Write-Host ''
                        Write-Host '  Press Enter to return.' -ForegroundColor DarkGray
                        Read-Host | Out-Null
                        return
                    }
                    Write-Host '  Verifying with server...' -ForegroundColor DarkGray
                    $valResp = Invoke-TokenValidate -Token $existing -IgnoreSSL:$Summary.currentProfile.IgnoreSSL
                    if ($valResp -and $valResp.IsSuccess) {
                        $logonUser = if ($valResp.Data -and $valResp.Data.PSObject.Properties['username']) {
                            " - logged on as $($valResp.Data.username)"
                        } else { '' }
                        Write-Host "  Token verified$logonUser." -ForegroundColor Green
                        Write-Host ''
                        Write-Host '  Press Enter to return.' -ForegroundColor DarkGray
                        Read-Host | Out-Null
                        return
                    } elseif ($valResp -and $valResp.StatusCode -eq 401) {
                        Write-Host '  Server rejected token (401). Clearing saved token.' -ForegroundColor Red
                        Remove-Item -LiteralPath $tokenPath -Force -ErrorAction SilentlyContinue
                        Write-Host '  Re-authenticating...' -ForegroundColor Yellow
                        Write-Host ''
                        # Fall through to the re-auth block below
                    } else {
                        $errDetail = if ($valResp) { " ($($valResp.StatusCode): $($valResp.ErrorMessage))" } else { ' (server unreachable)' }
                        Write-Host "  Could not verify with server$errDetail." -ForegroundColor Yellow
                        Write-Host '  Proceeding with locally-valid token.' -ForegroundColor DarkGray
                        Write-Host ''
                        Write-Host '  Press Enter to return.' -ForegroundColor DarkGray
                        Read-Host | Out-Null
                        return
                    }
                }
                Write-Host '  Token is expired. Re-authenticating...' -ForegroundColor Yellow
                Write-Host ''
            }
        } catch {
            Write-Host '  Saved token could not be read. Re-authenticating...' -ForegroundColor Yellow
            Write-Host ''
        }
    } else {
        Write-Host '  No saved token found. A new authentication is required.' -ForegroundColor Yellow
        Write-Host ''
    }

    # Token missing or expired - authenticate
    Write-Host '  Authenticating...' -ForegroundColor DarkGray
    Write-Host ''

    try {
        $savedToken = $null
        if (Test-Path -LiteralPath $tokenPath) {
            try { $savedToken = Import-AuthToken -Path $tokenPath -IgnoreExpiry } catch {}
        }

        $token = $null
        if ($Summary.currentProfile.SystemType -eq 'Privilege Cloud') {
            $params = @{}
            if ($Summary.currentProfile.AuthMethod) { $params['AuthMethod'] = $Summary.currentProfile.AuthMethod }
            if ($Summary.currentProfile.BaseURL -match '^https://(.+)\.privilegecloud\.cyberark\.cloud') {
                $params['PCloudSubdomain'] = $Matches[1]
            } elseif ($savedToken -and $savedToken.BaseURL -match 'https://([^.]+)\.privilegecloud') {
                $params['PCloudSubdomain'] = $Matches[1]
            }
            if ($Summary.currentProfile.PSObject.Properties['TenantAuth'] -and $Summary.currentProfile.TenantAuth) {
                $params['IdentityTenantURL'] = $Summary.currentProfile.TenantAuth
            }
            if ($Summary.currentProfile.Username) { $params['Username'] = $Summary.currentProfile.Username }
            if ($Summary.currentProfile.PSObject.Properties['WebView2AssemblyPath'] -and $Summary.currentProfile.WebView2AssemblyPath) {
                $params['WebView2AssemblyPath'] = $Summary.currentProfile.WebView2AssemblyPath
            }
            $token = Get-ISPSSAuthToken @params
        } else {
            $params = @{ IgnoreSSL = $Summary.currentProfile.IgnoreSSL }
            if ($Summary.currentProfile.AuthMethod) { $params['AuthMethod'] = $Summary.currentProfile.AuthMethod }
            if ($Summary.currentProfile.Username)   { $params['Username']   = $Summary.currentProfile.Username }
            # The profile's current Base URL always wins over a saved token's (possibly stale -
            # see Testing-Plan.md K04) one; a saved token's URL is only a fallback for the rare
            # case where the profile itself has no Base URL set at all.
            $expectedUrl = Get-ExpectedTokenBaseURL -DriverProfile $Summary.currentProfile
            if ($expectedUrl) {
                $params['PVWAUrl'] = $expectedUrl
            } elseif ($savedToken -and $savedToken.BaseURL) {
                $params['PVWAUrl'] = $savedToken.BaseURL
            }
            if ($Summary.currentProfile.PSObject.Properties['WebView2AssemblyPath'] -and $Summary.currentProfile.WebView2AssemblyPath) {
                $params['WebView2AssemblyPath'] = $Summary.currentProfile.WebView2AssemblyPath
            }
            $token = Get-SelfHostedAuthToken @params
        }
        if ($token -and $token.Token) {
            Write-Host '  Connection successful.' -ForegroundColor Green
            Write-Host "    System  : $($token.SystemType)"   -ForegroundColor Gray
            Write-Host "    Method  : $($token.AuthMethod)"   -ForegroundColor Gray
            Write-Host "    Base URL: $($token.BaseURL)"      -ForegroundColor Gray
            Write-Host "    Expires : $($token.Expiry.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Gray

            # Persist discovered identity URL back to the profile so future logins skip rediscovery
            if ($token.SystemType -eq 'ISPSS' -and $token.IdentityURL -and
                $token.IdentityURL -ne $Summary.currentProfile.TenantAuth) {
                $Summary.currentProfile.TenantAuth = $token.IdentityURL
                Save-DriverProfile -currentProfile $Summary.currentProfile
            }

            if (Confirm-Action 'Save this token to the profile?') {
                $null = Save-AuthToken -TokenObject $token -ProfileName $Summary.currentProfile.AuthTokenProfile
                Write-Host '  Token saved.' -ForegroundColor Green
            }
        } else {
            Write-Host '  Authentication returned no token.' -ForegroundColor Red
        }
    } catch {
        Write-Host "  Authentication failed: $_" -ForegroundColor Red
        Write-CyberArkLog -Message "Test connection failed for profile '$($Summary.currentProfile.ProfileName)': $_" -Level 'WARN'
    }

    Write-Host ''
    Write-Host '  Press Enter to return.' -ForegroundColor DarkGray
    Read-Host | Out-Null
}

#endregion

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
        try {
            if ($Summary.TokenStatus -eq 'Valid') {
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
                            Write-CyberArkLog -Message "Logon-phase age-based refresh skipped: CyberArk Identity asked us to wait $throttleSec more second(s) before the next authentication attempt (Testing-Plan.md K17). Using the existing token as-is." -Level 'INFO'
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
                        Write-CyberArkLog -Message "Expired-token refresh skipped: CyberArk Identity asked us to wait $throttleSec more second(s) before the next authentication attempt (Testing-Plan.md K17)." -Level 'INFO'
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
            Write-CyberArkLog -Message "Failed to load saved token: $_" -Level 'WARN'
        }

        # The profile's Base URL may have been edited since this token was saved/refreshed - a
        # token's own BaseURL is frozen at original login time and never reconciled automatically
        # (Testing-Plan.md K04), and Invoke-CyberArkAPI builds every request from the token's
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
        # Every auth method's FRESH (non-refresh) login is interactive for at least one reason:
        # a Get-Credential/password prompt (CyberArk/LDAP/RADIUS), a certificate picker
        # (PKI/PKIPN), an OAuth Client ID/Secret prompt (ISPSS ClientCredentials), or a
        # WebView2/MFA-challenge popup (SAML/OIDC/Interactive/SSO) - confirmed directly against
        # $authParams below, which never sets -Credential/-Certificate/-ClientId/-ClientSecret
        # for any method. So automation mode can only ever succeed on top of an already-valid,
        # silently-refreshable saved session (handled above, before reaching this block) - never
        # a cold start. Exit here with a clear reason rather than ever attempting one of the
        # branches below, which is exactly the "exit stating the issue, don't hang" contract.
        if ($script:AutomationMode) {
            $reason = switch ($Summary.TokenStatus) {
                'Expired'    { 'its saved token has expired and could not be silently refreshed' }
                'Unreadable' { 'its saved token could not be read (missing, corrupt, or restored from a different Windows user/machine)' }
                default      { 'it has no saved token' }
            }
            $msg = "Automation mode: profile '$($selectedProfile.ProfileName)' cannot be used unattended - $reason, and fresh authentication is always interactive. Log in to this profile interactively at least once first."
            Write-CyberArkLog -Message $msg -Level 'ERROR'
            Write-Host "  $msg" -ForegroundColor Red
            return $null
        }
        Show-Header -Breadcrumbs ($Breadcrumbs + @('Authenticate'))
        $authStatusMsg = switch ($Summary.TokenStatus) {
            'Expired'    { 'Saved token has expired. Please re-authenticate.' }
            'Unreadable' { 'Could not read saved token. Please re-authenticate.' }
            default      { 'No saved token found. Please authenticate.' }
        }
        Write-Host "  $authStatusMsg" -ForegroundColor Yellow
        Write-Host ''
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
                # Testing-Plan.md K11: makes Import-WebView2Assembly's own "specify
                # -WebView2AssemblyPath" error message actually actionable through the driver -
                # only consulted for the SSO method, and only as a last resort after every other
                # candidate path already fails.
                if ($selectedProfile.PSObject.Properties['WebView2AssemblyPath'] -and $selectedProfile.WebView2AssemblyPath) {
                    $authParams['WebView2AssemblyPath'] = $selectedProfile.WebView2AssemblyPath
                }
                $authParams['AuthTokenProfileName'] = $selectedProfile.AuthTokenProfile
                $authParams['ProfileDir']           = $script:ProfileDir
                # K17: this block is never reached in automation mode (guarded out above), so a
                # human is actively waiting for this login - honor CyberArk Identity's own
                # RetryWaitingTime hint by waiting it out here rather than immediately re-attempting
                # into another likely soft-lockout rejection.
                $throttleSec = Get-ISPSSAuthThrottle -AuthTokenProfileName $selectedProfile.AuthTokenProfile -ProfileDir $script:ProfileDir
                if ($throttleSec -gt 0) {
                    Write-Host "  CyberArk Identity asked us to wait before retrying - waiting $throttleSec more second(s)..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $throttleSec
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
                $token = Get-SelfHostedAuthToken @authParams
            } else {
                throw "Profile SystemType '$($selectedProfile.SystemType)' is not configured. Edit the profile to set it."
            }
            # If user entered credentials, save username back to profile for next-login pre-fill
            if ($token -and $token._RefreshContext -and $token._RefreshContext['Credential']) {
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
            $null = Save-AuthToken -TokenObject $token -ProfileName $selectedProfile.AuthTokenProfile
        } catch {
            Write-CyberArkLog -Message "Could not save refreshed token: $_" -Level 'WARN'
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

            $action = Read-MenuChoice -Prompt 'C / E / P / D / T / L / A / B / Q (default: C)'
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
                    # Save draft first so edit flow can check for existing file
                    Save-DriverProfile -currentProfile $copy
                    Invoke-ProfileEditFlow -currentProfile $copy -Breadcrumbs ($detailCrumbs + @("Copy to $newName"))
                    $DefaultProfileName = $newName
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
                                        -Endpoint '/API/auth/Logoff' `
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
                    # Use-StoredCredentialIfMissing and Testing-Plan.md K06. A one-time interactive
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

#region --- Module Discovery ---

$script:LoadedModules    = @()
$script:LastActivityTime = $null

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
            $null = Save-AuthToken -TokenObject $refreshed -ProfileName $script:ActiveProfile.AuthTokenProfile
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
                Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: mid-run token refresh skipped - CyberArk Identity asked us to wait $throttleSec more second(s) before the next authentication attempt (Testing-Plan.md K17)."
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
                $null = Save-AuthToken -TokenObject $refreshed -ProfileName $script:ActiveProfile.AuthTokenProfile
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
                $null = Save-AuthToken -TokenObject $refreshed -ProfileName $script:ActiveProfile.AuthTokenProfile
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
        # Testing-Plan.md K04) one, since this re-auth is effectively a fresh login anyway; only
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
                $null = Save-AuthToken -TokenObject $newToken -ProfileName $script:ActiveProfile.AuthTokenProfile
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
            $null = Save-AuthToken -TokenObject $newToken -ProfileName $script:ActiveProfile.AuthTokenProfile
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
            -Endpoint '/API/LoggedOnUser' -IgnoreSSL:$script:ActiveProfile.IgnoreSSL
        if ($resp.IsSuccess) {
            $script:SessionToken.Expiry = (Get-Date).ToUniversalTime().AddMinutes($script:PVWA_SESSION_EXPIRY_MIN)
            # Persist the extended expiry, matching every sibling refresh path
            # (Invoke-ProactiveRefresh, Invoke-TokenRefresh) - without this, the on-disk .cred
            # file's Expiry goes stale after a successful keepalive, understating how long the
            # session is actually still good for (e.g. in the profile list's token-status display).
            $null = Save-AuthToken -TokenObject $script:SessionToken -ProfileName $script:ActiveProfile.AuthTokenProfile
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
                -Endpoint '/API/auth/Logoff' -IgnoreSSL:$script:ActiveProfile.IgnoreSSL | Out-Null
        } catch {
            Write-CyberArkLog -Message "Logoff request failed (session may already be expired): $_" -Level 'WARN'
        }
    }
    $script:SessionToken = $null
}

function Invoke-TokenValidate {
    # Calls GET /API/LoggedOnUser to confirm the server still accepts the token.
    # Returns the API response object, or $null if the call throws or is unsupported.
    # Privilege Cloud (ISPSS) does not expose a token validation endpoint — returns $null immediately.
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [bool]$IgnoreSSL = $false
    )
    if ($Token.SystemType -eq 'ISPSS') { return $null }
    try {
        return Invoke-CyberArkAPI -Token $Token -Method 'GET' `
            -Endpoint '/API/LoggedOnUser' -IgnoreSSL:$IgnoreSSL
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
            Join-Path $PSScriptRoot $script:ActiveProfile.InputFolder
        }
        if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved } else { $PSScriptRoot }
    } else { $PSScriptRoot }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileNames
    }
    return @()
}

function Get-OutputCsvPath {
    param([string]$InputPath)
    $folder = if ($script:ActiveProfile.OutputFolder) {
        $resolved = if ([System.IO.Path]::IsPathRooted($script:ActiveProfile.OutputFolder)) {
            $script:ActiveProfile.OutputFolder
        } else {
            Join-Path $PSScriptRoot $script:ActiveProfile.OutputFolder
        }
        if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved } else { Split-Path $InputPath }
    } else { Split-Path $InputPath }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    return Join-Path $folder "$($base)_$((Get-Date).ToString('yyyy-MM-dd'))_output.csv"
}

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

    foreach ($filePath in $files) {
        $fileName = [System.IO.Path]::GetFileName($filePath)
        Write-CyberArkLog -Message "Starting CSV: $filePath" -Level 'INFO'

        try { $rows = @(Import-Csv -LiteralPath $filePath) } catch {
            Write-Host "  Could not read '$fileName': $_" -ForegroundColor Red
            Write-CyberArkLog -Message "Failed to read CSV '$filePath': $_" -Level 'WARN'
            continue
        }

        if (-not $rows) {
            Write-Host "  '$fileName' is empty - skipped." -ForegroundColor Yellow
            continue
        }

        if ($meta.InputSchema) {
            $missing = Test-CsvSchema -Headers $rows[0].PSObject.Properties.Name -Schema $meta.InputSchema
            if ($missing) {
                $cols = ($missing | ForEach-Object { $_.Column }) -join ', '
                Write-Host "  '$fileName' missing required columns: $cols - skipped." -ForegroundColor Red
                Write-CyberArkLog -Message "CSV schema validation failed for '$fileName'. Missing: $cols" -Level 'WARN'
                continue
            }
        }

        $outputPath = Get-OutputCsvPath -InputPath $filePath
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
            # failure (StatusCode 0) - see the IsFatal table in API-Module-Development-Guide.md.
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
            foreach ($col in $row.PSObject.Properties) { $outRow[$col.Name] = $col.Value }
            $outRow['IsSuccess'] = $isSuccess
            $outRow['Summary']   = $summary
            $outputRows.Add([PSCustomObject]$outRow)

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
    $idleMin   = if ($script:LastActivityTime) {
        [Math]::Round(((Get-Date) - $script:LastActivityTime).TotalMinutes, 1)
    } else { 0 }
    Write-Host ("  Token: {0} min remaining    Idle: {1} min" -f $remaining, $idleMin) -ForegroundColor $expColor
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
        # (StatusCode 0) - see the IsFatal table in API-Module-Development-Guide.md.
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

function Invoke-SessionLoop {
    $script:LastActivityTime = Get-Date
    $warnShown = $false

    Import-APIModules
    # Re-dot-source each module file into this scope so child functions (Invoke-ActionModule)
    # can call both entry points and custom-input functions by name.
    foreach ($m in $script:LoadedModules) {
        if ($m.PSObject.Properties['Failed'] -and $m.Failed) { continue }
        . $m.FilePath
    }

    $crumbs = @($script:ActiveProfile.ProfileName)

    while ($true) {

        # --- Inactivity check ---
        $idleSec      = ((Get-Date) - $script:LastActivityTime).TotalSeconds
        $timeoutSec   = $script:InactivityTimeoutMin * 60
        $warnAtSec    = $timeoutSec * 0.9

        if ($idleSec -ge $timeoutSec) {
            Write-CyberArkLog -Message "Inactivity timeout ($($script:InactivityTimeoutMin) min). Ending session." -Level 'INFO'
            return 'Exit'
        }

        if ($idleSec -ge $warnAtSec -and -not $warnShown) {
            $remainSec = [int]($timeoutSec - $idleSec)
            Write-Host ''
            Write-Host "  Inactivity warning: session will end in ~$remainSec seconds due to inactivity." -ForegroundColor Yellow
            $warnShown = $true
        }

        # --- Token health ---
        Invoke-ProactiveRefresh
        switch (Test-TokenExpiry) {
            'Expired' {
                if (-not (Invoke-TokenRefresh)) {
                    Write-CyberArkLog -Message 'Session ended - could not renew token.' -Level 'ERROR'
                    return 'Exit'
                }
                $warnShown = $false
            }
            'Warning' {
                Invoke-SelfHostedKeepalive
            }
        }

        # --- Category selection ---
        $categories = @($script:LoadedModules | Group-Object { $_.Meta.Category } | Sort-Object Name)
        Show-CategoryMenu -Breadcrumbs $crumbs -Categories $categories
        $catChoice = Read-MenuChoice -Prompt 'Category / [R]estart / [X]it'
        $script:LastActivityTime = Get-Date
        $warnShown = $false

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
                        $idleSec    = ((Get-Date) - $script:LastActivityTime).TotalSeconds
                        $timeoutSec = $script:InactivityTimeoutMin * 60
                        $warnAtSec  = $timeoutSec * 0.9

                        if ($idleSec -ge $timeoutSec) {
                            Write-CyberArkLog -Message "Inactivity timeout ($($script:InactivityTimeoutMin) min). Ending session." -Level 'INFO'
                            return 'Exit'
                        }

                        if ($idleSec -ge $warnAtSec -and -not $warnShown) {
                            $remainSec = [int]($timeoutSec - $idleSec)
                            Write-Host ''
                            Write-Host "  Inactivity warning: session will end in ~$remainSec seconds due to inactivity." -ForegroundColor Yellow
                            $warnShown = $true
                        }

                        Invoke-ProactiveRefresh
                        switch (Test-TokenExpiry) {
                            'Expired' {
                                if (-not (Invoke-TokenRefresh)) {
                                    Write-CyberArkLog -Message 'Session ended - could not renew token.' -Level 'ERROR'
                                    return 'Exit'
                                }
                                $warnShown = $false
                            }
                            'Warning' {
                                Invoke-SelfHostedKeepalive
                            }
                        }

                        Show-ActionMenu -Breadcrumbs $catCrumbs -CategoryModules $catModules
                        $actChoice = Read-MenuChoice -Prompt 'Action / [B]ack (default: B)'
                        if (-not $actChoice) { $actChoice = 'B' }
                        $script:LastActivityTime = Get-Date

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

function Get-AutomationExitCode {
    <#
        Maps either a CSV-batch summary (Invoke-CsvProcessing's return value) or a single module
        result object to Invoke-AutomatedAction's exit-code contract (0 = full success, 2 =
        partial/item-level failures, 3 = could not run/fatal - see Docs\User-Guide.md for the
        full contract as documented for automation callers). Factored out of Invoke-AutomatedAction
        purely so this mapping is unit-testable on its own, without driving the whole entry point.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Csv')]
        [PSCustomObject]$Summary,

        [Parameter(Mandatory = $true, ParameterSetName = 'Result')]
        [PSCustomObject]$Result
    )
    if ($PSCmdlet.ParameterSetName -eq 'Csv') {
        if ($Summary.AnyFatal)    { return 3 }
        if ($Summary.TotalFail -gt 0) { return 2 }
        return 0
    }
    if ($Result.IsFatal)      { return 3 }
    if ($Result.Failures -gt 0) { return 2 }
    return 0
}

function Invoke-AutomatedAction {
    <#
        Non-interactive entry point: authenticate to -StartProfile, run one module action
        (-Category/-Action), and return an exit code - never enters the interactive profile
        list/detail menus or the category/action session loop. Requires $script:AutomationMode to
        already be set (done in the Configuration region, from -Category/-Action's presence).

        Exit codes: 0 = full success. 2 = the action ran but had item-level failures (not fatal).
        3 = could not run at all (profile/module resolution, no refreshable saved session, or the
        module itself reported IsFatal). 1 (unhandled crash) is the existing top-level catch's
        behavior - this function does not produce it itself.
    #>
    param()

    # A startup log is already open (Initialize-CyberArkLog, called unconditionally just before
    # this function runs) - Write-CyberArkLog calls below already land in it even before a
    # profile connects, so every automation-mode failure is captured to a file, not just an
    # unredirected Write-Host line.

    $match = @(Get-AllDriverProfiles) | Where-Object { $_.ProfileName -ieq $StartProfile } | Select-Object -First 1
    if (-not $match) {
        Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: no profile named '$StartProfile' was found."
        return 3
    }

    $connected = Invoke-ProfileConnect -Summary $match -Breadcrumbs @('Automation', $match.ProfileName) -NoPause
    if (-not $connected) {
        # Invoke-ProfileConnect (including its automation-mode fresh-auth guard) has already
        # logged the specific reason.
        return 3
    }

    # Re-initialize the log to the connected profile's own folder/metadata, mirroring the
    # interactive session's convention, so an automation-mode log file lands in the same place a
    # user would already look for one.
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
    Write-CyberArkLog -Level 'INFO' -Message "Automation mode: connected. Profile: $($script:ActiveProfile.ProfileName)  Category: $Category  Action: $Action"

    Import-APIModules
    # Re-dot-source each module file into THIS function's own scope, exactly mirroring
    # Invoke-SessionLoop's identical loop above - this cannot be factored into a shared helper
    # function, since dot-sourcing done inside a normally-called function vanishes once that
    # function returns (the same reason Import-APIModules alone isn't enough - see its own
    # region). Duplicated deliberately, not an oversight.
    foreach ($m in $script:LoadedModules) {
        if ($m.PSObject.Properties['Failed'] -and $m.Failed) { continue }
        . $m.FilePath
    }

    $entry = $script:LoadedModules | Where-Object {
        -not ($_.PSObject.Properties['Failed'] -and $_.Failed) -and
        $_.Meta.Category -ieq $Category -and $_.Meta.Action -ieq $Action
    } | Select-Object -First 1

    if (-not $entry) {
        $rawPath = Join-Path $script:APIModulesPath "$Category\Invoke-$Category$Action.ps1"
        $reason  = if (Test-Path -LiteralPath $rawPath -PathType Leaf) {
            "the module exists but does not support '$($script:SessionToken.SystemType)'"
        } else {
            'no such module exists'
        }
        Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: Category='$Category' Action='$Action' - $reason."
        return 3
    }
    if ($entry.Meta.PSObject.Properties['SupportsAutomation'] -and $entry.Meta['SupportsAutomation'] -eq $false) {
        Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: '$($entry.Meta.Name)' does not support automation (ModuleMeta.SupportsAutomation = `$false) - it always requires interactive input."
        return 3
    }

    $fnName = "Invoke-$($entry.Meta.Category)$($entry.Meta.Action)"
    $exitCode = 3

    if ($InputFile) {
        if (-not $entry.Meta.AcceptsInputFile) {
            Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: '$($entry.Meta.Name)' does not accept CSV input (-InputFile) - use -InputJson instead."
        } elseif (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
            Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: -InputFile '$InputFile' was not found."
        } else {
            $summary = Invoke-CsvProcessing -ModuleEntry $entry -FilePaths @($InputFile)
            $exitCode = Get-AutomationExitCode -Summary $summary
        }
    } else {
        $inputData = @{}
        $parseOk   = $true
        if ($InputJson) {
            try {
                $jsonText = if (Test-Path -LiteralPath $InputJson -PathType Leaf) {
                    Get-Content -LiteralPath $InputJson -Raw
                } else { $InputJson }
                $parsed = $jsonText | ConvertFrom-Json
                # PS 5.1's ConvertFrom-Json returns a PSCustomObject, not a hashtable - convert
                # explicitly rather than relying on -AsHashtable, which does not exist here.
                foreach ($prop in $parsed.PSObject.Properties) { $inputData[$prop.Name] = $prop.Value }
            } catch {
                Write-CyberArkLog -Level 'ERROR' -Message "Automation mode: -InputJson could not be parsed: $_"
                $parseOk = $false
            }
        }
        # Deliberately never calls Get-<Category><Action>Input - that function is interactive by
        # design. A module with required fields left unsupplied here reports its own normal
        # per-field validation Failure, exactly as an incomplete CSV row already does today.
        if ($parseOk) {
            $result = & $fnName -Token $script:SessionToken -InputData $inputData -WhatIf:$script:WhatIfMode
            if ($entry.Meta.ProducesOutput) {
                Save-ModuleResultCsv -ModuleEntry $entry -Result $result -InputData $inputData
            }
            if ($entry.Meta.Action -notin @('List', 'Get')) {
                Add-CyberArkLogSummaryEntry -ModuleName $entry.Meta.Name `
                    -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
            }
            $exitCode = Get-AutomationExitCode -Result $result
            if ($result.IsFatal) {
                # Matches Invoke-ActionModule's interactive behavior: a 401/connectivity failure
                # invalidates the saved token so a next run doesn't waste time retrying it.
                Invoke-TokenInvalidate
            }
        }
    }

    # Deliberately does NOT call Invoke-SessionLogoff here, unlike the interactive session loop's
    # own end-of-session cleanup (see the other call site) - confirmed live that CyberArk's
    # POST /API/auth/Logoff genuinely revokes the session server-side, so calling it here would
    # kill the very session a NEXT automation-mode run against this same profile is meant to
    # reuse or silently refresh (the whole point of the saved/refreshable session K06/K12 built).
    # A prior run's own Invoke-TokenInvalidate (IsFatal above) already deletes the local .cred
    # file when the session is genuinely dead - nothing further to clean up here either way. See
    # Testing-Plan.md K15.
    Write-CyberArkLog -Level 'INFO' -Message "Automation mode: finished. Category=$Category Action=$Action ExitCode=$exitCode"
    Close-CyberArkLog
    return $exitCode
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
    Write-Host "`n[FATAL] Unhandled error at Manage-Privilege.ps1:$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    Write-Host "  $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Stack trace:" -ForegroundColor DarkGray
    $_.ScriptStackTrace -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    exit 1
}

exit 0

#endregion
