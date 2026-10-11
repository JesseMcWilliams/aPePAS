#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Safe Member'
    Category         = 'SafeMembers'
    Action           = 'Add'
    Description      = 'Add a user, group, or role as a member of a safe with defined permissions.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';       Required = $true;  Description = 'Name of the safe.' }
        @{ Column = 'MemberName';     Required = $true;  Description = 'Username, group name, or role name to add.' }
        @{ Column = 'SearchIn';       Required = $false; Description = 'Domain ID (from GetDirectoryServices) or Vault for system component users. Leave blank to use the API default (Vault). CSV/bulk input only - interactive mode shows a picker with Vault plus directories from GetDirectoryServices.' }
        @{ Column = 'MemberType';     Required = $false; Description = 'User / Group / Role (default: User).' }
        @{ Column = 'PermissionRole'; Required = $false; Description = 'ReadOnlyStrict / EndUser / PowerUser / SafeManager applies that preset to every permission (the individual permission columns are ignored). Blank or Specified uses the individual permission columns; the row fails if those are all blank too.' }
        @{ Column = 'ExpirationDate'; Required = $false; Description = 'Membership expiration date (yyyy-MM-dd). Blank (or None) adds the member with no expiration date.' }
        @{ Column = 'UseAccounts';                            Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'RetrieveAccounts';                       Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'ListAccounts';                           Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'AddAccounts';                            Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'UpdateAccountContent';                   Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'UpdateAccountProperties';                Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'InitiateCPMAccountManagementOperations'; Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'SpecifyNextAccountContent';              Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'RenameAccounts';                         Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'DeleteAccounts';                         Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'UnlockAccounts';                         Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'ManageSafe';                             Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'ManageSafeMembers';                      Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'BackupSafe';                             Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'ViewAuditLog';                           Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'ViewSafeMembers';                        Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'AccessWithoutConfirmation';              Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'CreateFolders';                          Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'DeleteFolders';                          Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'MoveAccountsAndFolders';                 Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'RequestsAuthorizationLevel1';            Required = $false; Description = 'Dual-control: require 1 approver (True/False). Mutually exclusive with RequestsAuthorizationLevel2. Used only when PermissionRole is blank or Specified. Blank means False.' }
        @{ Column = 'RequestsAuthorizationLevel2';            Required = $false; Description = 'Dual-control: require 2 approvers (True/False). Mutually exclusive with RequestsAuthorizationLevel1. Used only when PermissionRole is blank or Specified. Blank means False.' }
    )
    Priority         = 21
    Version          = '1.6.1'
}

function script:Get-PermissionSet {
    <#
        Returns a hashtable of all 22 CyberArk safe member permission fields (camelCase API keys)
        set to the values appropriate for the requested role.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$Role
    )

    # Base: all permissions off — keys are camelCase to match the API request body
    $perms = @{
        useAccounts                            = $false
        retrieveAccounts                       = $false
        listAccounts                           = $false
        addAccounts                            = $false
        updateAccountContent                   = $false
        updateAccountProperties                = $false
        initiateCPMAccountManagementOperations = $false
        specifyNextAccountContent              = $false
        renameAccounts                         = $false
        deleteAccounts                         = $false
        unlockAccounts                         = $false
        manageSafe                             = $false
        manageSafeMembers                      = $false
        backupSafe                             = $false
        viewAuditLog                           = $false
        viewSafeMembers                        = $false
        accessWithoutConfirmation              = $false
        createFolders                          = $false
        deleteFolders                          = $false
        moveAccountsAndFolders                 = $false
        requestsAuthorizationLevel1            = $false
        requestsAuthorizationLevel2            = $false
    }

    switch ($Role) {
        'EndUser' {
            $perms.useAccounts      = $true
            $perms.retrieveAccounts = $true
            $perms.listAccounts     = $true
        }
        'PowerUser' {
            $perms.useAccounts             = $true
            $perms.retrieveAccounts        = $true
            $perms.listAccounts            = $true
            $perms.addAccounts             = $true
            $perms.updateAccountContent    = $true
            $perms.updateAccountProperties = $true
            $perms.renameAccounts          = $true
            $perms.deleteAccounts          = $true
            $perms.unlockAccounts          = $true
        }
        'SafeManager' {
            $perms.useAccounts                            = $true
            $perms.retrieveAccounts                       = $true
            $perms.listAccounts                           = $true
            $perms.addAccounts                            = $true
            $perms.updateAccountContent                   = $true
            $perms.updateAccountProperties                = $true
            $perms.initiateCPMAccountManagementOperations = $true
            $perms.renameAccounts                         = $true
            $perms.deleteAccounts                         = $true
            $perms.unlockAccounts                         = $true
            $perms.manageSafe                             = $true
            $perms.manageSafeMembers                      = $true
            $perms.backupSafe                             = $true
            $perms.viewAuditLog                           = $true
            $perms.viewSafeMembers                        = $true
            $perms.createFolders                          = $true
            $perms.deleteFolders                          = $true
            $perms.moveAccountsAndFolders                 = $true
        }
        default {
            # ReadOnlyStrict (and unknown roles) - deliberately does NOT grant retrieveAccounts,
            # unlike PVWA's/psPAS's own built-in "ReadOnly" role. Named ReadOnlyStrict (not
            # ReadOnly) specifically to avoid that name collision - see README.md.
            $perms.listAccounts    = $true
            $perms.viewAuditLog    = $true
            $perms.viewSafeMembers = $true
        }
    }

    return $perms
}

# 20 standard boolean permission column names (PascalCase, matching InputSchema and CSV headers).
# Used for interactive prompts and CSV parsing. API body uses camelCase — first letter lowercased.
$script:PermissionColumns = @(
    'UseAccounts', 'RetrieveAccounts', 'ListAccounts', 'AddAccounts',
    'UpdateAccountContent', 'UpdateAccountProperties',
    'InitiateCPMAccountManagementOperations', 'SpecifyNextAccountContent',
    'RenameAccounts', 'DeleteAccounts', 'UnlockAccounts',
    'ManageSafe', 'ManageSafeMembers', 'BackupSafe',
    'ViewAuditLog', 'ViewSafeMembers', 'AccessWithoutConfirmation',
    'CreateFolders', 'DeleteFolders', 'MoveAccountsAndFolders'
)

function script:Get-SafeMemberPermissionRole {
    <#
        Returns the row's PermissionRole, trimmed. Returns '' when it is blank or 'Specified' -
        both mean "use the individual permission columns". Any other value is a preset name
        for script:Get-PermissionSet (unknown names fall through to ReadOnlyStrict there).

        Kept identical in Invoke-SafeMembersAdd.ps1 and Invoke-SafeMembersUpdate.ps1 - both
        files are dot-sourced into the driver's one scope, so the copies share one name.
    #>
    param([hashtable]$Data)
    $role = if ($Data.ContainsKey('PermissionRole') -and $null -ne $Data['PermissionRole']) { "$($Data['PermissionRole'])".Trim() } else { '' }
    if ($role -eq 'Specified') { $role = '' }
    return $role
}

function script:Get-SafeMemberPermissionColumnValues {
    <#
        Reads the 20 permission columns plus RequestsAuthorizationLevel1/2 from an input row.
        Returns a hashtable keyed by the camelCase API name. Each value is $true or $false, or
        $null when the column is missing or blank - blank means "not given", never False.
        True / Yes / Y / 1 (any case) is True; any other non-blank value is False.
        When the row carries the interactive Permissions hashtable, its values are read instead
        ($null there also means "not given").

        The two dual-control levels are mutually exclusive, so setting one True while the other
        is blank makes the other False (it must not inherit a True from the current member).

        Kept identical in Invoke-SafeMembersAdd.ps1 and Invoke-SafeMembersUpdate.ps1 - both
        files are dot-sourced into the driver's one scope, so the copies share one name.
    #>
    param([hashtable]$Data)

    $values      = @{}
    $columns     = @($script:PermissionColumns) + @('RequestsAuthorizationLevel1', 'RequestsAuthorizationLevel2')
    $interactive = if ($Data.ContainsKey('Permissions') -and $Data['Permissions'] -is [hashtable]) { $Data['Permissions'] } else { $null }

    foreach ($col in $columns) {
        $camelKey = $col.Substring(0,1).ToLower() + $col.Substring(1)
        $raw = $null
        if ($null -ne $interactive) {
            if ($interactive.ContainsKey($camelKey)) { $raw = $interactive[$camelKey] }
        } elseif ($Data.ContainsKey($col)) {
            $raw = $Data[$col]
        }
        if ($raw -is [bool]) { $values[$camelKey] = $raw; continue }
        $text = if ($null -ne $raw) { "$raw".Trim() } else { '' }
        $values[$camelKey] = if ($text -eq '') { $null } else { [bool]($text -match '^(true|yes|y|1)$') }
    }

    if ($values['requestsAuthorizationLevel1'] -eq $true -and $null -eq $values['requestsAuthorizationLevel2']) { $values['requestsAuthorizationLevel2'] = $false }
    if ($values['requestsAuthorizationLevel2'] -eq $true -and $null -eq $values['requestsAuthorizationLevel1']) { $values['requestsAuthorizationLevel1'] = $false }
    return $values
}

function script:Get-SafeMembersSearchInOptions {
    <#
        Returns the SearchIn choice list for the interactive prompt: Vault is always first, then
        the available directories.

        Source 1: GET /api/settings/AddSafeMember (psPAS Get-PASDirectoryID). Its Directories
        array has Name and ID, and ID is the SearchIn value: the directory's Identity GUID on
        Privilege Cloud, the mapped directory's own name on Self-Hosted. Not in the 14.6 Swagger.
        Source 2, when source 1 returns 404, fails, or has no Directories array: GET
        /API/Configuration/LDAP/Directories (GetDirectoryServices, Self-Hosted only per psPAS),
        probing several plausible property names for the ID and display name. Falls back to
        Vault-only if neither works - it never blocks the flow (K20).

        Kept identical in Invoke-SafeMembersAdd.ps1, Invoke-SafeMembersAddFromTemplateRole.ps1 and
        Invoke-SafesAddFromTemplate.ps1 rather than shared - each module file is dot-sourced and
        unit-tested standalone, and the copies share one name in the driver scope.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token
    )

    $options = [System.Collections.Generic.List[PSCustomObject]]::new()
    $options.Add([PSCustomObject]@{ DisplayName = 'Vault'; Value = 'Vault' })

    # --- Source 1: /api/settings/AddSafeMember ---
    $settingsResponse = $null
    try {
        $settingsResponse = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/api/settings/AddSafeMember'
    } catch {
        Write-CyberArkLog -Level 'WARN' -Message "AddSafeMember settings call threw an exception: $_"
    }

    if ($settingsResponse -and $settingsResponse.IsSuccess -and $settingsResponse.Data -and
        $settingsResponse.Data.PSObject.Properties['Directories']) {
        foreach ($dir in @($settingsResponse.Data.Directories)) {
            if (-not $dir) { continue }
            $id   = if ($dir.PSObject.Properties['ID']   -and $dir.ID)   { "$($dir.ID)" }   else { '' }
            $name = if ($dir.PSObject.Properties['Name'] -and $dir.Name) { "$($dir.Name)" } else { '' }
            $value = if ($id) { $id } else { $name }
            if (-not $value) { continue }
            if (@($options | Where-Object { $_.Value -eq $value }).Count -gt 0) { continue }
            $options.Add([PSCustomObject]@{ DisplayName = $(if ($name) { $name } else { $value }); Value = $value })
        }
        return $options.ToArray()
    }

    if ($settingsResponse -and -not $settingsResponse.IsSuccess -and $settingsResponse.StatusCode -ne 404) {
        Write-CyberArkLog -Level 'WARN' -Message "AddSafeMember settings call failed (HTTP $($settingsResponse.StatusCode)): $($settingsResponse.ErrorMessage). Trying GetDirectoryServices."
    } else {
        Write-CyberArkLog -Level 'DEBUG' -Message 'AddSafeMember settings returned no Directories list; trying GetDirectoryServices.'
    }

    # --- Source 2: /API/Configuration/LDAP/Directories ---
    try {
        $response = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/Configuration/LDAP/Directories'
    } catch {
        Write-CyberArkLog -Level 'WARN' -Message "GetDirectoryServices call threw an exception: $_"
        return $options.ToArray()
    }

    if (-not $response.IsSuccess) {
        Write-CyberArkLog -Level 'WARN' -Message "GetDirectoryServices failed (HTTP $($response.StatusCode)): $($response.ErrorMessage). SearchIn will offer Vault only."
        return $options.ToArray()
    }

    if (-not $response.Data) { return $options.ToArray() }

    [array]$directories = if ($response.Data -is [array]) {
        $response.Data
    } elseif ($response.Data.PSObject.Properties['value']) {
        @($response.Data.value)
    } else {
        @($response.Data)
    }

    if ($directories.Count -gt 0) {
        $sampleProps = ($directories[0].PSObject.Properties.Name) -join ', '
        Write-CyberArkLog -Level 'DEBUG' -Message "GetDirectoryServices item properties: $sampleProps"
    }

    foreach ($dir in $directories) {
        $value = $null
        foreach ($prop in @('id', 'domainName', 'directoryName', 'name')) {
            if ($dir.PSObject.Properties[$prop] -and $dir.$prop) { $value = "$($dir.$prop)"; break }
        }
        if (-not $value) { continue }

        $displayName = $null
        foreach ($prop in @('domainName', 'directoryName', 'name', 'id')) {
            if ($dir.PSObject.Properties[$prop] -and $dir.$prop) { $displayName = "$($dir.$prop)"; break }
        }
        if (-not $displayName) { $displayName = $value }

        $options.Add([PSCustomObject]@{ DisplayName = $displayName; Value = $value })
    }

    return $options.ToArray()
}

function Get-SafeMembersAddInput {
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

    Write-Host '  New Safe Member Details  (press Enter to accept each default)' -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Name of the safe.'

    $memberName = Show-FieldPrompt -Label 'MemberName' `
        -Default $(if ($Defaults['MemberName']) { $Defaults['MemberName'] } else { '' }) `
        -Required $true `
        -Description 'Username, group name, or role name to add.'

    # Wrap in @() - a single-item return (Vault-only fallback) would otherwise unwrap to a
    # bare PSCustomObject on capture, which has no .Count under PS 5.1 strict mode.
    [array]$searchInOptions = @(script:Get-SafeMembersSearchInOptions -Token $Token)

    Write-Host '  SearchIn:' -ForegroundColor DarkGray
    for ($i = 0; $i -lt $searchInOptions.Count; $i++) {
        Write-Host "    $($i + 1) = $($searchInOptions[$i].DisplayName)"
    }
    Write-Host ''

    $defaultSearchInIndex = 1
    if ($Defaults['SearchIn']) {
        for ($i = 0; $i -lt $searchInOptions.Count; $i++) {
            if ($searchInOptions[$i].Value -eq $Defaults['SearchIn']) { $defaultSearchInIndex = $i + 1; break }
        }
    }

    $searchInChoice = Read-Host "  Select SearchIn (1-$($searchInOptions.Count), default=$defaultSearchInIndex)"
    $searchInIndex  = $defaultSearchInIndex
    $parsedChoice   = 0
    if ($searchInChoice -and [int]::TryParse($searchInChoice, [ref]$parsedChoice) -and $parsedChoice -ge 1 -and $parsedChoice -le $searchInOptions.Count) {
        $searchInIndex = $parsedChoice
    }
    $searchIn = $searchInOptions[$searchInIndex - 1].Value
    Write-Host ''

    $memberType = Show-FieldPrompt -Label 'MemberType' `
        -Default $(if ($Defaults['MemberType']) { $Defaults['MemberType'] } else { 'User' }) `
        -Description 'User / Group / Role'

    $expirationDate = Show-FieldPrompt -Label 'ExpirationDate' `
        -Default $(if ($Defaults['ExpirationDate']) { $Defaults['ExpirationDate'] } else { '' }) `
        -Description 'Membership expiration date (yyyy-MM-dd), or leave blank for no expiry.'

    Write-Host ''
    Write-Host '  Permission Mode:' -ForegroundColor DarkGray
    Write-Host '    1 = Role       (named permission preset)'
    Write-Host '    2 = Specified  (enter each permission individually)'
    Write-Host ''

    $modeChoice = Read-Host '  Select mode (1-2, default=1)'

    $permissionRole = 'ReadOnlyStrict'
    $specifiedPerms = $null

    if ($modeChoice -eq '2') {
        $permissionRole = 'Specified'
        Write-Host ''
        Write-Host '  Enter Y or N for each permission (default=N):' -ForegroundColor DarkGray
        Write-Host ''
        $specifiedPerms = @{}
        foreach ($col in $script:PermissionColumns) {
            $answer   = Show-FieldPrompt -Label $col -Default 'N' -Description "Grant $col permission? (Y/N)"
            $camelKey = $col.Substring(0,1).ToLower() + $col.Substring(1)
            $specifiedPerms[$camelKey] = ($answer -match '^[Yy]$')
        }

        # Dual-control authorization level — mutually exclusive; present as a single 3-way choice
        Write-Host ''
        Write-Host '  Dual-Control Authorization Level  (mutually exclusive):' -ForegroundColor DarkGray
        Write-Host '    0 = None'
        Write-Host '    1 = Level 1  (requestsAuthorizationLevel1 — requires 1 approver)'
        Write-Host '    2 = Level 2  (requestsAuthorizationLevel2 — requires 2 approvers)'
        Write-Host ''
        $authChoice = Read-Host '  Select (0-2, default=0)'
        $specifiedPerms['requestsAuthorizationLevel1'] = ($authChoice -eq '1')
        $specifiedPerms['requestsAuthorizationLevel2'] = ($authChoice -eq '2')
    } else {
        Write-Host ''
        Write-Host '  Permission Role:' -ForegroundColor DarkGray
        Write-Host '    1 = ReadOnlyStrict'
        Write-Host '    2 = EndUser'
        Write-Host '    3 = PowerUser'
        Write-Host '    4 = SafeManager'
        Write-Host ''
        $roleChoice = Read-Host '  Select role (1-4, default=1)'
        $permissionRole = switch ($roleChoice) {
            '2' { 'EndUser' }
            '3' { 'PowerUser' }
            '4' { 'SafeManager' }
            default { 'ReadOnlyStrict' }
        }
    }

    $inputData = @{
        SafeName       = $safeName
        MemberName     = $memberName
        SearchIn       = $searchIn
        MemberType     = $memberType
        PermissionRole = $permissionRole
        ExpirationDate = $expirationDate
    }

    if ($null -ne $specifiedPerms) {
        $inputData.Permissions = $specifiedPerms
    }

    return $inputData
}

function Invoke-SafeMembersAdd {
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

    # Validate required field SafeName
    $safeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])".Trim() } else { '' }
    if (-not $safeName) {
        $msg = 'SafeName is required and cannot be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # Validate required field MemberName
    $memberName = if ($InputData['MemberName']) { "$($InputData['MemberName'])".Trim() } else { '' }
    if (-not $memberName) {
        $msg = 'MemberName is required and cannot be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $encodedSafe    = [Uri]::EscapeDataString($safeName)
    $memberType     = if ($InputData['MemberType']) { "$($InputData['MemberType'])".Trim() } else { '' }
    $searchIn       = if ($InputData['SearchIn']) { "$($InputData['SearchIn'])".Trim() } else { '' }

    # Resolve permissions (F85):
    #  - PermissionRole set (not blank, not Specified): that preset is used; the individual
    #    columns are ignored.
    #  - PermissionRole blank or Specified: the individual columns (or the interactive Permissions
    #    hashtable) are used, and a blank individual value means False. If every one of them is
    #    blank the row fails - a member with no permissions is never created.
    $permissionRole = script:Get-SafeMemberPermissionRole -Data $InputData
    if ($permissionRole) {
        $permissions = script:Get-PermissionSet -Role $permissionRole
    } else {
        $givenPerms = script:Get-SafeMemberPermissionColumnValues -Data $InputData
        if (@($givenPerms.Values | Where-Object { $null -ne $_ }).Count -eq 0) {
            $msg = "No permissions given for '$memberName' in '$safeName': PermissionRole is blank and every individual permission column is blank. Set PermissionRole (ReadOnlyStrict / EndUser / PowerUser / SafeManager) or at least one permission column."
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = $InputData
                ErrorMessage = $msg
                ErrorDetails = $null
            })
            $result.Failures++
            $result.ItemsProcessed++
            Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
            return $result
        }
        $permissions = @{}
        foreach ($key in @($givenPerms.Keys)) { $permissions[$key] = ($givenPerms[$key] -eq $true) }
        $permissionRole = 'Specified'
    }

    # Expiration date: blank (or None) means no expiration (null)
    $expirationText = if ($InputData.ContainsKey('ExpirationDate') -and $null -ne $InputData['ExpirationDate']) { "$($InputData['ExpirationDate'])".Trim() } else { '' }
    # Sent as Unix seconds, as the API requires (a yyyy-MM-dd string gets PASWS167E).
    $expirationDate = $null
    if ($expirationText -ne '' -and $expirationText -ne 'None') {
        try {
            $expirationDate = ConvertTo-CyberArkExpirationTime -Value $expirationText
        } catch {
            $msg = "$($_.Exception.Message)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }
    }

    # Validate mutual exclusivity of authorization levels
    $level1 = [bool]($permissions['requestsAuthorizationLevel1'])
    $level2 = [bool]($permissions['requestsAuthorizationLevel2'])
    if ($level1 -and $level2) {
        $msg = 'requestsAuthorizationLevel1 and requestsAuthorizationLevel2 are mutually exclusive. Set only one to true.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # Build body — all keys camelCase to match the API contract
    $body = @{
        memberName               = $memberName
        membershipExpirationDate = $expirationDate
        permissions              = $permissions
    }
    # Optional fields — omit when blank so the API applies its defaults
    if ($memberType) { $body['memberType'] = $memberType }
    if ($searchIn)   { $body['searchIn']   = $searchIn   }

    Write-CyberArkLog -Level 'INFO'  -Message "Adding member '$memberName' to safe '$safeName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Safes/$encodedSafe/Members | MemberName='$memberName' Role='$permissionRole'"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: would POST /API/Safes/$encodedSafe/Members for member '$memberName'."
        $result.Results.Add([PSCustomObject]@{
            SafeName       = $safeName
            MemberName     = $memberName
            MemberType     = if ($InputData['MemberType']) { $InputData['MemberType'] } else { 'User' }
            PermissionRole = $permissionRole
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint "/API/Safes/$encodedSafe/Members" `
        -Body     $body `
        -WhatIf:  $false

    if (-not $response.IsSuccess) {
        $msg = "Add safe member failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $response.ErrorMessage
            ErrorDetails = $response.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $member = if ($response.Data) { $response.Data } else { $null }

    $result.Results.Add([PSCustomObject]@{
        SafeName       = if ($member -and $member.PSObject.Properties['safeName'])   { $member.safeName }   else { $safeName }
        MemberName     = if ($member -and $member.PSObject.Properties['memberName']) { $member.memberName } else { $memberName }
        MemberType     = if ($member -and $member.PSObject.Properties['memberType']) { $member.memberType } else { if ($InputData['MemberType']) { $InputData['MemberType'] } else { 'User' } }
        PermissionRole = $permissionRole
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Member '$memberName' added to safe '$safeName' successfully."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
