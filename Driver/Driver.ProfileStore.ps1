<#
    Manage-Privilege.ps1 driver part: profile directory, profile CRUD, and backup/restore.
    Dot-sourced by Manage-Privilege.ps1 (Driver Parts region) into its script scope; not run on its own.
#>

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
# Use-StoredCredentialIfMissing and the profile-detail menu's [A] action. See Testing_Findings-and-Known-Issues.md K06.
# Get-ProfileCredentialPath / Save-ProfileCredential / Get-ProfileCredential /
# Remove-ProfileCredential now live in Modules\CyberArkCredentialStore.psm1 (imported
# unconditionally above) so a standalone helper script can reuse the same store - call sites here
# pass -ProfileDir $script:ProfileDir explicitly, since that module has no ambient driver state.

function Use-StoredCredentialIfMissing {
    <#
        Automation mode only (call sites gate this on $script:AutomationMode): if $Token's
        _RefreshContext is missing a Credential - documented in Testing_Findings-and-Known-Issues.md K06 for SelfHosted
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
    # A credential handed in by Invoke-AutomationWithCredential.ps1 wins over anything stored:
    # it's the freshest copy (a rotated password works at once) and it never touches disk.
    if (Set-AutomationCredentialOnToken -Token $Token) { return }

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

function Test-AutomationCredentialMethod {
    <#
        True when a supplied credential is all an auth method needs to log in or refresh without
        a person: Self-Hosted CyberArk/LDAP/RADIUS, Privilege Cloud ClientCredentials/Interactive.
        SystemType may be the profile label ('Self-Hosted'/'Privilege Cloud') or the token value
        ('SelfHosted'/'ISPSS').
    #>
    param([string]$SystemType, [string]$AuthMethod)
    $selfHosted = $SystemType -in @('SelfHosted', 'Self-Hosted')
    $pcloud     = $SystemType -in @('ISPSS', 'Privilege Cloud')
    return [bool](($selfHosted -and $AuthMethod -in @('CyberArk', 'LDAP', 'RADIUS')) -or
                  ($pcloud     -and $AuthMethod -in @('ClientCredentials', 'Interactive')))
}

function Set-AutomationCredentialOnToken {
    <#
        Puts the -Credential handed in for this run into the token's _RefreshContext so a refresh
        uses it: ClientCredentials gets ClientId/ClientSecret, the others get Credential. Returns
        $true when applied, $false when there is no supplied credential or the method can't use it.
    #>
    param([Parameter(Mandatory = $true)] [PSCustomObject]$Token)
    if (-not $script:AutomationCredential) { return $false }
    if (-not (Test-AutomationCredentialMethod -SystemType $Token.SystemType -AuthMethod $Token.AuthMethod)) { return $false }
    if (-not $Token.PSObject.Properties['_RefreshContext'] -or -not $Token._RefreshContext) { return $false }
    $ctx = $Token._RefreshContext
    if ($Token.SystemType -eq 'ISPSS' -and $Token.AuthMethod -eq 'ClientCredentials') {
        $ctx['ClientId']     = $script:AutomationCredential.UserName
        $ctx['ClientSecret'] = $script:AutomationCredential.Password
    } else {
        $ctx['Credential'] = $script:AutomationCredential
    }
    Write-CyberArkLog -Level 'DEBUG' -Message "Automation mode: using the supplied credential ('$($script:AutomationCredential.UserName)') for this session's refresh."
    return $true
}

function Save-SessionToken {
    <#
        Save-AuthToken, except that a credential supplied with -Credential is left out of the saved
        file: its Credential/ClientSecret are blanked for the save and put back in memory after.
        With no supplied credential it is exactly Save-AuthToken, so every caller can use it.
    #>
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$TokenObject,
        [Parameter(Mandatory = $true)] [string]$ProfileName
    )
    $hasCtx = $TokenObject.PSObject.Properties['_RefreshContext'] -and $TokenObject._RefreshContext
    if (-not $script:AutomationCredential -or -not $hasCtx) {
        return Save-AuthToken -TokenObject $TokenObject -ProfileName $ProfileName
    }
    $ctx  = $TokenObject._RefreshContext
    $held = @{}
    foreach ($key in @('Credential', 'ClientSecret')) {
        if ($ctx.ContainsKey($key) -and $ctx[$key]) { $held[$key] = $ctx[$key]; $ctx[$key] = $null }
    }
    try {
        return Save-AuthToken -TokenObject $TokenObject -ProfileName $ProfileName
    } finally {
        foreach ($key in $held.Keys) { $ctx[$key] = $held[$key] }
    }
}

#endregion

#region --- currentProfile CRUD ---

function Get-AllDriverProfiles {
    # CredentialSources.json (Invoke-AutomationWithCredential.ps1's config) lives here too but
    # isn't a profile.
    $jsonFiles = @(Get-ChildItem -LiteralPath $script:ProfileDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'CredentialSources.json' })
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
            Write-CyberArkLog -Message "  Profile '$($p.ProfileName)': $displaySystemType | $($p.AuthMethod) | Token status $tokenStatus | Expiry: $expiryStr" -Level 'DEBUG'

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
        # Testing_Findings-and-Known-Issues.md K11: previously unreachable through the driver at all.
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

    $defaultDir = $script:AppRoot
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
        $dialog.InitialDirectory = $script:AppRoot
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
        uses for .cred files) is deliberately user+machine-locked - see Design_Architecture.md's Design
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

    # Neither of these can be carried in a backup usefully: .autocred is DPAPI-locked to this
    # Windows user and machine, and CredentialSources.json belongs to the driver script setup.
    Write-Host '  Note: stored automation credentials (.autocred) and CredentialSources.json are NOT' -ForegroundColor Yellow
    Write-Host '  included. Re-create them on the target machine ([A] on the profile, or' -ForegroundColor Yellow
    Write-Host '  Sync-AutomationCredential.ps1) and copy CredentialSources.json separately.' -ForegroundColor Yellow
    Write-Host ''
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
    # Set-StrictMode -Version Latest. See Testing_Findings-and-Known-Issues.md K14.
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
    # Set-StrictMode -Version Latest. See Testing_Findings-and-Known-Issues.md K14.
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
