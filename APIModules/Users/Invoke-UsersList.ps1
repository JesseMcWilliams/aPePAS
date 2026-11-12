#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Users'
    Category         = 'Users'
    Action           = 'List'
    Description      = 'Retrieve CyberArk Vault users, optionally with their last logon or only the inactive ones.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @()
    Priority         = 50
    Version          = '1.1.0'   # 1.1.0: IncludeLastLogin / InactiveOnly / InactiveDays (feature item 10)
}

# User types that are never reported as inactive (feature item 10, decision B3), on top of every
# user the API flags componentUser (CPM, PVWA, PSM, AppProvider, AIMAccount, ENE, ...). Lab check
# 2026-11-12 on PVWA 14.6: the predefined users (Administrator, Auditor, Backup, Batch, DR, Master,
# Operator, CyberarkSecureAccessService) have userType 'Built-InAdmins'; a DR replication user has
# 'DRUser'. Neither is flagged componentUser.
$script:UsersListInternalUserTypes = @('Built-InAdmins', 'DRUser')
$script:UsersListDefaultInactiveDays = 90

function Get-UsersListInput {
    <#
        Called by the driver when HasCustomInput = $true.
        Show-FieldPrompt is available because this module is dot-sourced into the driver scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Search Criteria  (press Enter to skip each field)' -ForegroundColor DarkGray
    Write-Host ''

    $search = Show-FieldPrompt -Label 'Search' `
        -Default $(if ($Defaults['Search']) { $Defaults['Search'] } else { '' }) `
        -Description 'Free-text search across username and user details. Leave blank for all users.'

    $userType = Show-FieldPrompt -Label 'UserType' `
        -Default $(if ($Defaults['UserType']) { $Defaults['UserType'] } else { '' }) `
        -Description 'Filter by user type (e.g. EPVUser, BasicUser). Leave blank for all types.'

    $inactiveOnly = Show-FieldPrompt -Label 'InactiveOnly' `
        -Default $(if ($Defaults['InactiveOnly']) { $Defaults['InactiveOnly'] } else { 'No' }) `
        -Description 'Yes: keep only users with no logon in InactiveDays days (never-logged-on users count). Component, built-in and the profile''s Inactive Exclude users are left out. One extra request per user.'

    $inactiveDays     = ''
    $includeLastLogin = ''
    if ("$inactiveOnly".Trim() -match '^(true|yes|y|1)$') {
        $inactiveDays = Show-FieldPrompt -Label 'InactiveDays' `
            -Default $(if ($Defaults['InactiveDays']) { $Defaults['InactiveDays'] } else { "$script:UsersListDefaultInactiveDays" }) `
            -Description 'Days without a logon before a user counts as inactive.'
    } else {
        $includeLastLogin = Show-FieldPrompt -Label 'IncludeLastLogin' `
            -Default $(if ($Defaults['IncludeLastLogin']) { $Defaults['IncludeLastLogin'] } else { 'No' }) `
            -Description 'Yes: add a LastLogin column. The list response has no logon date, so this costs one extra request per user.'
    }

    return @{
        Search           = $search
        UserType         = $userType
        InactiveOnly     = $inactiveOnly
        InactiveDays     = $inactiveDays
        IncludeLastLogin = $includeLastLogin
    }
}

function script:ConvertFrom-UsersLastLogin {
    <#
        Turns lastSuccessfulLoginDate (Unix seconds) into a local DateTime, or $null for "never".
        PVWA 14.6 returns -62135568000 (DateTime.MinValue) for a user who never logged on, so any
        value of zero or less means never, as does a missing or non-numeric value.
    #>
    param([AllowNull()] [object]$Value)
    if ($null -eq $Value) { return $null }
    $number = [long]0
    if (-not [long]::TryParse("$Value".Trim(), [ref]$number)) { return $null }
    if ($number -le 0) { return $null }
    if ($number -gt 100000000000) { $number = [long]($number / 1000) }
    return [DateTimeOffset]::FromUnixTimeSeconds($number).LocalDateTime
}

function script:Test-UsersListExcluded {
    <#
        $true when an inactive-users run must leave this user out: componentUser, an internal user
        type, or a username matching one of the profile's Inactive_Exclude_Users patterns (-like,
        case-insensitive).
    #>
    param(
        [Parameter(Mandatory = $true)] [object]$User,
        [string[]]$ExcludePatterns = @()
    )
    if ($User.PSObject.Properties['componentUser'] -and $User.componentUser -eq $true) { return $true }
    if ($User.PSObject.Properties['userType'] -and ("$($User.userType)" -in $script:UsersListInternalUserTypes)) { return $true }
    $name = if ($User.PSObject.Properties['username']) { "$($User.username)" } else { '' }
    foreach ($pattern in $ExcludePatterns) {
        if ($name -like $pattern) { return $true }
    }
    return $false
}

function Invoke-UsersList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token,

        [Parameter(Mandatory = $false)]
        [hashtable]$InputData,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $result = [PSCustomObject]@{
        ModuleName     = $ModuleMeta.Name
        Category       = $ModuleMeta.Category
        Action         = $ModuleMeta.Action
        ItemsProcessed = 0
        Successes      = 0
        Failures       = 0
        IsFatal        = $false
        Results        = [System.Collections.Generic.List[PSCustomObject]]::new()
        Errors         = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    if (-not $InputData) { $InputData = @{} }

    $search   = if ($InputData['Search'])   { "$($InputData['Search'])".Trim()   } else { $null }
    $userType = if ($InputData['UserType']) { "$($InputData['UserType'])".Trim() } else { $null }

    # --- Inactive-users options (feature item 10) ---
    $inactiveOnly     = "$($InputData['InactiveOnly'])".Trim()     -match '^(true|yes|y|1)$'
    $includeLastLogin = $inactiveOnly -or ("$($InputData['IncludeLastLogin'])".Trim() -match '^(true|yes|y|1)$')
    $inactiveDays     = $script:UsersListDefaultInactiveDays
    if ($inactiveOnly) {
        $daysText = "$($InputData['InactiveDays'])".Trim()
        if ($daysText) {
            $parsedDays = 0
            if (-not [int]::TryParse($daysText, [ref]$parsedDays) -or $parsedDays -lt 1) {
                $msg = "InactiveDays must be a whole number of 1 or more (got '$daysText')."
                Write-CyberArkLog -Level 'ERROR' -Message $msg
                $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
                $result.Failures++
                $result.ItemsProcessed++
                return $result
            }
            $inactiveDays = $parsedDays
        }
    }

    $excludePatterns = @()
    if ($inactiveOnly) {
        $profileVar = Get-Variable -Name 'ActiveProfile' -Scope 'Script' -ErrorAction SilentlyContinue
        if ($profileVar -and $profileVar.Value -and $profileVar.Value.PSObject.Properties['Inactive_Exclude_Users'] -and $profileVar.Value.Inactive_Exclude_Users) {
            $excludePatterns = @(("$($profileVar.Value.Inactive_Exclude_Users)" -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }

    # Build query parameters - only include keys that have a value
    $queryParams = @{}
    if ($search)   { $queryParams['search']   = $search   }
    if ($userType) { $queryParams['UserType'] = $userType }

    $criteriaLog = $(
        $parts = @()
        if ($search)           { $parts += "Search='$search'" }
        if ($userType)         { $parts += "UserType='$userType'" }
        if ($inactiveOnly)     { $parts += "InactiveOnly (>= $inactiveDays days)" }
        elseif ($includeLastLogin) { $parts += 'IncludeLastLogin' }
        if ($parts)            { $parts -join '  ' } else { '(all users)' }
    )

    Write-CyberArkLog -Level 'INFO'  -Message 'Starting user list retrieval.'
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Users | $criteriaLog"

    $response = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/API/Users' `
        -QueryParams $queryParams `
        -WhatIf:     $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "User list failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $response.ErrorMessage
            ErrorDetails = $response.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        return $result
    }

    # Users API returns a 'Users' property (not 'value')
    [array]$users = if ($response.Data -and $response.Data.PSObject.Properties['Users']) {
        @($response.Data.Users)
    } else { @() }

    if ((-not $users) -or $users.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message 'No users returned for the given criteria.'
        # Not a failure - a valid empty result
        return $result
    }

    if ($inactiveOnly) {
        [array]$kept = @($users | Where-Object { -not (script:Test-UsersListExcluded -User $_ -ExcludePatterns $excludePatterns) })
        $excludedCount = $users.Count - $kept.Count
        Write-CyberArkLog -Level 'INFO' -Message "Inactive users: $excludedCount of $($users.Count) user(s) excluded (component, built-in or the profile's Inactive Exclude list); checking the last logon of $($kept.Count)."
        $users = $kept
    } elseif ($includeLastLogin) {
        Write-CyberArkLog -Level 'INFO' -Message "Reading the last logon of $($users.Count) user(s), one request each."
    }

    $cutoff      = (Get-Date).AddDays(-$inactiveDays)
    $activeCount = 0

    foreach ($user in $users) {
        try {
            $lastLoginText = ''
            if ($includeLastLogin) {
                # The list response (UserSummary) has no logon date; only GET /API/Users/{id} does.
                $userIdText = "$($user.id)"
                $detail = Invoke-CyberArkAPI `
                    -Token    $Token `
                    -Method   'GET' `
                    -Endpoint "/API/Users/$([Uri]::EscapeDataString($userIdText))" `
                    -PageSize 0 `
                    -WhatIf:  $WhatIf.IsPresent

                $msg = if (-not $detail.IsSuccess) { "Could not read the last logon of user '$($user.username)' (ID $userIdText): HTTP $($detail.StatusCode) $($detail.ErrorMessage)" } else { '' }
                $fatal = (-not $detail.IsSuccess) -and ($detail.StatusCode -in @(401, 0))
                if ($msg -and ($inactiveOnly -or $fatal)) {
                    # InactiveOnly can't classify the user without the date, so it's an error.
                    $result.Errors.Add([PSCustomObject]@{ InputData = @{ UserID = $userIdText; Username = "$($user.username)" }; ErrorMessage = $msg; ErrorDetails = $detail.ErrorDetails })
                    Write-CyberArkLog -Level 'ERROR' -Message $msg
                    $result.Failures++
                    $result.ItemsProcessed++
                    if ($fatal) { $result.IsFatal = $true; return $result }
                    continue
                }

                if ($msg) {
                    # IncludeLastLogin: the list row is still right, only the extra column is missing.
                    # PVWA 14.6 refuses GET /API/Users/0 (the built-in Master user) with 500 USRWS001E.
                    Write-CyberArkLog -Level 'WARN' -Message "$msg. LastLogin left empty."
                    $rawLogin  = $null
                    $lastLogin = $null
                } else {
                    $rawLogin  = if ($detail.Data -and $detail.Data.PSObject.Properties['lastSuccessfulLoginDate']) { $detail.Data.lastSuccessfulLoginDate } else { $null }
                    $lastLogin = script:ConvertFrom-UsersLastLogin -Value $rawLogin
                }
                if ($inactiveOnly -and $null -ne $lastLogin -and $lastLogin -ge $cutoff) {
                    # Logged on recently: active, so not part of an inactive-users result. Not
                    # counted as processed either: a run where everyone is active is an empty
                    # result, which the driver shows as success only while ItemsProcessed is 0.
                    $activeCount++
                    continue
                }
                $lastLoginText = if ($msg) { '' } elseif ($null -eq $lastLogin) { 'Never' } else { $lastLogin.ToString('yyyy-MM-dd HH:mm') }
            }

            # No Email column: the 14.6 UserSummary model has no email field (it's only on the
            # single-user GET, under internet.businessEmail - see Get User).
            $details = if ($user.PSObject.Properties['personalDetails'] -and $user.personalDetails) { $user.personalDetails } else { $null }
            $row = [ordered]@{
                UserID        = $user.id
                Username      = $user.username
                UserType      = $user.userType
                Source        = $user.source
                ComponentUser = $user.componentUser
                FirstName     = if ($details -and $details.PSObject.Properties['firstName']) { $details.firstName } else { '' }
                LastName      = if ($details -and $details.PSObject.Properties['lastName'])  { $details.lastName  } else { '' }
                Enabled       = if ($user.PSObject.Properties['enableUser']) { $user.enableUser } else { '' }
                Suspended     = if ($user.PSObject.Properties['suspended'])  { $user.suspended  } else { '' }
                Location      = if ($user.PSObject.Properties['location'])   { $user.location   } else { '' }
            }
            if ($includeLastLogin) { $row['LastLogin'] = $lastLoginText }
            $result.Results.Add([PSCustomObject]$row)
            $result.Successes++
            $result.ItemsProcessed++
        } catch {
            $userId = try { "$($user.id)" } catch { '(unknown)' }
            $msg = "Unexpected error mapping user '$userId': $_"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = $InputData
                ErrorMessage = $msg
                ErrorDetails = $null
            })
            $result.Failures++
            $result.ItemsProcessed++
        }
    }

    if ($inactiveOnly) {
        Write-CyberArkLog -Level 'INFO' -Message "User list complete. Inactive users (no logon in $inactiveDays days, or never): $($result.Successes). Active, left out: $activeCount."
    } else {
        Write-CyberArkLog -Level 'INFO' -Message "User list complete. Users retrieved: $($result.Successes)."
    }
    return $result
}
