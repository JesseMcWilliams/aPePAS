<#
    Manage-Privilege.ps1 driver part: display and prompt helpers that the menus and API modules call.
    Dot-sourced by Manage-Privilege.ps1 (Driver Parts region) into its script scope; not run on its own.
#>

#region --- Display Helpers ---

function Get-SignedInUsername {
    # Prefers the credential actually used to authenticate (_RefreshContext, set on the token
    # by the Auth modules) over the profile's own Username field, which can be blank or stale
    # for auth methods that don't require a stored username. _RefreshContext is a hashtable
    # (see Reference_Interfaces.md) - bracket notation, not dot notation, matching Invoke-TokenRefresh's
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
        # $DefaultFolder below (which silently falls back to $script:AppRoot if it can't be
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
            Join-Path $script:AppRoot $FolderOverride
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
            Join-Path $script:AppRoot $DefaultFolder
        }
        if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved } else { $script:AppRoot }
    } else {
        $script:AppRoot
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
    # userType values considered a component user) and uses that result whenever it lists at
    # least one CPM. Falls back to the profile's manually-maintained CPM_List when the call
    # fails, throws, or succeeds with no CPMs (per user direction, 2026-10-10: the user who can't
    # see any CPM through the API should still get the list they configured). This supersedes the prior per-page choice recorded in Design_Architecture.md (Add Safe
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
        if ($options.Count -gt 0) { return $options.ToArray() }
        Write-CyberArkLog -Level 'INFO' -Message "CPM user list query returned no CPMs. Falling back to the profile's CPM_List."
    } elseif ($response) {
        Write-CyberArkLog -Level 'WARN' -Message "CPM user list query failed (HTTP $($response.StatusCode)): $($response.ErrorMessage). Falling back to the profile's CPM_List."
    }

    if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['CPM_List'] -and $script:ActiveProfile.CPM_List) {
        return @(("$($script:ActiveProfile.CPM_List)" -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    return $options.ToArray()
}

#endregion
