<#
    Manage-Privilege.ps1 driver part: profile display, edit flow, and test connection.
    Dot-sourced by Manage-Privilege.ps1 (Driver Parts region) into its script scope; not run on its own.
#>

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
    Field 'Log Folder'      $(if ($p.LogFolder)    { $p.LogFolder    } else { '(script folder\Logs)' })
    Field 'Input Folder'    $(if ($p.InputFolder)  { $p.InputFolder  } else { '(script folder)' })
    Field 'Output Folder'   $(if ($p.OutputFolder) { $p.OutputFolder } else { '(script folder)' })
    Field 'Ignore SSL'      $p.IgnoreSSL     $(if ($p.IgnoreSSL)     { 'Yellow' } else { 'Gray' })
    if ($p.PSObject.Properties['WebView2AssemblyPath'] -and $p.WebView2AssemblyPath) { Field 'WebView2 Assembly' $p.WebView2AssemblyPath }
    Field 'WhatIf Default'  $p.WhatIfDefault $(if ($p.WhatIfDefault) { 'Yellow' } else { 'Gray' })
    $isDefault = $p.PSObject.Properties['IsDefault'] -and [bool]$p.IsDefault
    Field 'Default Profile' $(if ($isDefault) { 'Yes' } else { 'No' }) $(if ($isDefault) { 'Green' } else { 'Gray' })
    $dpLimit = if ($p.PSObject.Properties['DisplayLimit']) { [int]$p.DisplayLimit } else { 20 }
    Field 'Display Limit'   $(if ($dpLimit -eq 0) { 'Show all' } else { "$dpLimit rows" })
    $pageSize = 0; if ($p.PSObject.Properties['Limit']) { try { $pageSize = [int]$p.Limit } catch { } }
    Field 'Page Size'       $(if ($pageSize -gt 0) { "$pageSize per request" } else { 'Default (1000)' })
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
    Write-Host "  [C] Continue    [E] Edit    [P] Copy    [D] Delete    [T] Test Connection    [L] Log Out" -ForegroundColor White
    Write-Host "  $fLabel    [A] Automation Credential    [B] Back    [Q] Quit" -ForegroundColor White
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
    $selfHostedAuthMethods = @('CyberArk', 'LDAP', 'RADIUS', 'SAML', 'Shared', 'PKI', 'PKIPN')   # no OIDC (F103)
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
        -Description 'Folder for log files. Leave blank for the Logs subfolder of the script folder.'

    $currentProfile.InputFolder = Show-FieldPrompt -Label 'Input Folder' -Default $currentProfile.InputFolder `
        -Description 'Starting folder for the CSV file picker. Leave blank for the script folder.'

    $currentProfile.OutputFolder = Show-FieldPrompt -Label 'Output Folder' -Default $currentProfile.OutputFolder `
        -Description 'Destination for output CSV files. Leave blank for the script folder. A relative path is relative to the script folder.'

    Write-Host ''
    $sslStr = Show-FieldPrompt -Label 'Ignore SSL Errors' -Default $(if ($currentProfile.IgnoreSSL) { 'Y' } else { 'N' }) `
        -Description 'Bypass SSL certificate validation? (Y/N) - Use only for lab/dev environments.'
    $currentProfile.IgnoreSSL = $sslStr -match '^[Yy]$'

    $currentProfile.WebView2AssemblyPath = Show-FieldPrompt -Label 'WebView2 Assembly Path' `
        -Default $(if ($currentProfile.PSObject.Properties['WebView2AssemblyPath']) { $currentProfile.WebView2AssemblyPath } else { '' }) `
        -Description 'Only used for SAML (Self-Hosted) or SSO (Privilege Cloud) login. Full path to Microsoft.Web.WebView2.WinForms.dll. When set, it is tried first, before the Auth, Auth\WebView2 and NuGet locations. Leave blank to auto-detect.'

    $wiStr = Show-FieldPrompt -Label 'WhatIf Default' -Default $(if ($currentProfile.WhatIfDefault) { 'Y' } else { 'N' }) `
        -Description 'Default to WhatIf mode for this profile? (Y/N) - Recommended for production.'
    $currentProfile.WhatIfDefault = $wiStr -match '^[Yy]$'

    $currentLimitDefault = if ($currentProfile.PSObject.Properties['Limit'] -and $currentProfile.Limit -gt 0) { "$($currentProfile.Limit)" } else { '0' }
    # Stored as 'Limit' for compatibility with saved profiles; it is the per-request page size.
    $limitStr = Show-FieldPrompt -Label 'Page Size' -Default $currentLimitDefault `
        -Description 'Records requested per API page (0 = the default, 1000). Paging continues until every result is fetched; this does not cap the total.'
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
        Testing_Findings-and-Known-Issues.md K04.
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
        reconciled against a later profile edit on its own (Testing_Findings-and-Known-Issues.md K04) -
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
                    # See Testing_Findings-and-Known-Issues.md K04: the profile's Base URL has changed since this
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
            # see Testing_Findings-and-Known-Issues.md K04) one; a saved token's URL is only a fallback for the rare
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
                $null = Save-SessionToken -TokenObject $token -ProfileName $Summary.currentProfile.AuthTokenProfile
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
