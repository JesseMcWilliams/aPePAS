#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Update Safe Member'
    Category         = 'SafeMembers'
    Action           = 'Update'
    Description      = 'Update the permissions or expiration date of an existing safe member.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';       Required = $true;  Description = 'Name of the safe.' }
        @{ Column = 'MemberName';     Required = $true;  Description = 'Username, group, or role to update.' }
        @{ Column = 'PermissionRole'; Required = $false; Description = 'ReadOnlyStrict / EndUser / PowerUser / SafeManager applies that preset to every permission (the individual permission columns are ignored). Blank or Specified uses the individual permission columns; if those are blank too, the current permissions are kept.' }
        @{ Column = 'ExpirationDate'; Required = $false; Description = 'Membership expiration date (yyyy-MM-dd). Blank keeps the current expiration date. None removes it.' }
        @{ Column = 'UseAccounts';                            Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'RetrieveAccounts';                       Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'ListAccounts';                           Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'AddAccounts';                            Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'UpdateAccountContent';                   Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'UpdateAccountProperties';                Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'InitiateCPMAccountManagementOperations'; Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'SpecifyNextAccountContent';              Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'RenameAccounts';                         Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'DeleteAccounts';                         Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'UnlockAccounts';                         Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'ManageSafe';                             Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'ManageSafeMembers';                      Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'BackupSafe';                             Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'ViewAuditLog';                           Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'ViewSafeMembers';                        Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'AccessWithoutConfirmation';              Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'CreateFolders';                          Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'DeleteFolders';                          Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'MoveAccountsAndFolders';                 Required = $false; Description = 'Permission (True/False). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'RequestsAuthorizationLevel1';            Required = $false; Description = 'Dual-control: require 1 approver (True/False). Mutually exclusive with RequestsAuthorizationLevel2 (True here sets it False when that column is blank). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
        @{ Column = 'RequestsAuthorizationLevel2';            Required = $false; Description = 'Dual-control: require 2 approvers (True/False). Mutually exclusive with RequestsAuthorizationLevel1 (True here sets it False when that column is blank). Used only when PermissionRole is blank or Specified. Blank keeps the current value.' }
    )
    Priority         = 22
    Version          = '1.3.1'
}

function script:Get-PermissionSet {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Role
    )

    # Base: all permissions off — keys are camelCase to match the API request body
    $p = @{
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
            $p.useAccounts      = $true
            $p.retrieveAccounts = $true
            $p.listAccounts     = $true
        }
        'PowerUser' {
            $p.useAccounts             = $true
            $p.retrieveAccounts        = $true
            $p.listAccounts            = $true
            $p.addAccounts             = $true
            $p.updateAccountContent    = $true
            $p.updateAccountProperties = $true
            $p.renameAccounts          = $true
            $p.deleteAccounts          = $true
            $p.unlockAccounts          = $true
        }
        'SafeManager' {
            $p.useAccounts                            = $true
            $p.retrieveAccounts                       = $true
            $p.listAccounts                           = $true
            $p.addAccounts                            = $true
            $p.updateAccountContent                   = $true
            $p.updateAccountProperties                = $true
            $p.initiateCPMAccountManagementOperations = $true
            $p.renameAccounts                         = $true
            $p.deleteAccounts                         = $true
            $p.unlockAccounts                         = $true
            $p.manageSafe                             = $true
            $p.manageSafeMembers                      = $true
            $p.backupSafe                             = $true
            $p.viewAuditLog                           = $true
            $p.viewSafeMembers                        = $true
            $p.createFolders                          = $true
            $p.deleteFolders                          = $true
            $p.moveAccountsAndFolders                 = $true
        }
        default {
            # ReadOnlyStrict (and unknown roles) - deliberately does NOT grant retrieveAccounts,
            # unlike PVWA's/psPAS's own built-in "ReadOnly" role. Named ReadOnlyStrict (not
            # ReadOnly) specifically to avoid that name collision - see README.md.
            $p.listAccounts    = $true
            $p.viewAuditLog    = $true
            $p.viewSafeMembers = $true
        }
    }

    return $p
}

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

function Get-SafeMembersUpdateInput {
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

    Write-Host '  Update Safe Member  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Name of the safe containing the member to update. (Required)'

    $memberName = Show-FieldPrompt -Label 'MemberName' `
        -Default $(if ($Defaults['MemberName']) { $Defaults['MemberName'] } else { '' }) `
        -Required $true `
        -Description 'Username, group name, or role to update. (Required)'

    Write-Host ''
    Write-Host '  Permission Mode:' -ForegroundColor DarkGray
    Write-Host '    1 = Role        (named permission preset - replaces every permission)' -ForegroundColor DarkGray
    Write-Host '    2 = Individual  (enter each permission; blank keeps the current value)' -ForegroundColor DarkGray
    Write-Host '    3 = Keep        (keep the current permissions; change only the expiration date)' -ForegroundColor DarkGray
    Write-Host ''

    $modeChoice = Show-FieldPrompt -Label 'PermissionMode' `
        -Default '1' `
        -Description 'Select 1 for Role, 2 for Individual, or 3 to keep the current permissions.'

    $permissionRole = 'ReadOnlyStrict'
    $specifiedPerms = $null

    if ($modeChoice.Trim() -eq '3') {
        # Blank role and no individual values: Invoke-SafeMembersUpdate keeps the current permissions
        $permissionRole = ''
    } elseif ($modeChoice.Trim() -eq '2') {
        $permissionRole = 'Specified'
        Write-Host ''
        Write-Host '  Enter Y or N for each permission. Press Enter to keep the current value:' -ForegroundColor DarkGray
        Write-Host ''
        $specifiedPerms = @{}
        foreach ($col in $script:PermissionColumns) {
            $answer   = Show-FieldPrompt -Label $col -Default '' -Description "Grant $col permission? (Y/N, blank = keep current)"
            $camelKey = $col.Substring(0,1).ToLower() + $col.Substring(1)
            $specifiedPerms[$camelKey] = if ("$answer".Trim() -eq '') { $null } else { ($answer -match '^[Yy]') }
        }

        # Dual-control authorization level - mutually exclusive; present as a single choice
        Write-Host ''
        Write-Host '  Dual-Control Authorization Level  (mutually exclusive):' -ForegroundColor DarkGray
        Write-Host '    0 = None'
        Write-Host '    1 = Level 1  (requestsAuthorizationLevel1 - requires 1 approver)'
        Write-Host '    2 = Level 2  (requestsAuthorizationLevel2 - requires 2 approvers)'
        Write-Host '    Enter = keep the current setting'
        Write-Host ''
        $authChoice = "$(Read-Host '  Select (0-2, default=keep current)')".Trim()
        if ($authChoice -in @('0', '1', '2')) {
            $specifiedPerms['requestsAuthorizationLevel1'] = ($authChoice -eq '1')
            $specifiedPerms['requestsAuthorizationLevel2'] = ($authChoice -eq '2')
        } else {
            $specifiedPerms['requestsAuthorizationLevel1'] = $null
            $specifiedPerms['requestsAuthorizationLevel2'] = $null
        }
    } else {
        Write-Host ''
        Write-Host '  Permission Role:' -ForegroundColor DarkGray
        Write-Host '    1 = ReadOnlyStrict' -ForegroundColor DarkGray
        Write-Host '    2 = EndUser' -ForegroundColor DarkGray
        Write-Host '    3 = PowerUser' -ForegroundColor DarkGray
        Write-Host '    4 = SafeManager' -ForegroundColor DarkGray
        Write-Host ''
        $roleChoice = Show-FieldPrompt -Label 'PermissionRole' `
            -Default $(if ($Defaults['PermissionRole']) { $Defaults['PermissionRole'] } else { '1' }) `
            -Description 'Enter role number (1-4) or role name (ReadOnlyStrict/EndUser/PowerUser/SafeManager).'
        $permissionRole = switch ($roleChoice.Trim()) {
            '1'              { 'ReadOnlyStrict' }
            '2'              { 'EndUser'         }
            '3'              { 'PowerUser'       }
            '4'              { 'SafeManager'     }
            'ReadOnlyStrict' { 'ReadOnlyStrict'  }
            'EndUser'        { 'EndUser'         }
            'PowerUser'      { 'PowerUser'       }
            'SafeManager'    { 'SafeManager'     }
            default          { 'ReadOnlyStrict'  }
        }
    }

    $expirationDate = Show-FieldPrompt -Label 'ExpirationDate' `
        -Default $(if ($Defaults['ExpirationDate']) { $Defaults['ExpirationDate'] } else { '' }) `
        -Description 'Membership expiration date (yyyy-MM-dd). Leave blank to keep the current expiration date; enter None to remove it.'

    $inputData = @{
        SafeName       = $safeName
        MemberName     = $memberName
        PermissionRole = $permissionRole
        ExpirationDate = $expirationDate
    }

    if ($null -ne $specifiedPerms) {
        $inputData.Permissions = $specifiedPerms
    }

    return $inputData
}

function Invoke-SafeMembersUpdate {
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

    # Validate SafeName
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

    # Validate MemberName
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

    $encodedSafe   = [System.Uri]::EscapeDataString($safeName)
    $encodedMember = [System.Uri]::EscapeDataString($memberName)

    # Resolve permissions (F85):
    #  - PermissionRole set (not blank, not Specified): that preset replaces every permission.
    #  - PermissionRole blank or Specified: the individual columns (or the interactive Permissions
    #    hashtable) are used, and a blank individual value keeps the member's current value.
    $permissionRole = script:Get-SafeMemberPermissionRole -Data $InputData
    $givenPerms     = $null
    $permissions    = $null
    if ($permissionRole) {
        $permissions = script:Get-PermissionSet -Role $permissionRole
    } else {
        $givenPerms = script:Get-SafeMemberPermissionColumnValues -Data $InputData
    }

    # Resolve expiration date: blank keeps the current one, None removes it (null = no expiration)
    $expirationText  = if ($InputData.ContainsKey('ExpirationDate') -and $null -ne $InputData['ExpirationDate']) { "$($InputData['ExpirationDate'])".Trim() } else { '' }
    $keepExpiration  = ($expirationText -eq '')
    # A new date is sent as Unix seconds, as the API requires (a yyyy-MM-dd string gets PASWS167E).
    $expirationDate  = $null
    if (-not $keepExpiration -and $expirationText -ne 'None') {
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

    $needsCurrentPerms = ($null -ne $givenPerms) -and (@($givenPerms.Values | Where-Object { $null -eq $_ }).Count -gt 0)

    # Read the current membership only when something has to be kept from it. A GET is read-only,
    # so it also runs under WhatIf, letting the WhatIf result show the merged values.
    if ($keepExpiration -or $needsCurrentPerms) {
        Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes/$encodedSafe/Members/$encodedMember (read current membership)"
        $currentResponse = Invoke-CyberArkAPI `
            -Token    $Token `
            -Method   'GET' `
            -Endpoint "/API/Safes/$encodedSafe/Members/$encodedMember" `
            -PageSize 0

        if (-not $currentResponse.IsSuccess) {
            $msg = "Could not read the current membership of '$memberName' in '$safeName' (HTTP $($currentResponse.StatusCode)): $($currentResponse.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = $InputData
                ErrorMessage = $msg
                ErrorDetails = $currentResponse.ErrorDetails
            })
            $result.Failures++
            $result.ItemsProcessed++
            $result.IsFatal = ($currentResponse.StatusCode -in @(401, 0))
            Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
            return $result
        }

        $current = $currentResponse.Data

        if ($keepExpiration) {
            $currentExpiration = if ($current -and $current.PSObject.Properties['membershipExpirationDate']) { $current.membershipExpirationDate } else { $null }
            # A negative value from the API means no expiration; send null so the PUT is not
            # rejected as out of range (same handling as psPAS Set-PASSafeMember).
            $parsedExpiration = [long]0
            if ($null -ne $currentExpiration -and [long]::TryParse("$currentExpiration", [ref]$parsedExpiration) -and $parsedExpiration -lt 0) {
                $currentExpiration = $null
            }
            $expirationDate = $currentExpiration
        }

        if ($needsCurrentPerms) {
            $currentPerms = if ($current -and $current.PSObject.Properties['permissions'] -and $current.permissions) { $current.permissions } else { $null }
            if ($null -eq $currentPerms) {
                $msg = "The current permissions of '$memberName' in '$safeName' could not be read, so blank permission columns cannot be kept. Fill every permission column or set PermissionRole."
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
            foreach ($key in @($givenPerms.Keys)) {
                if ($null -ne $givenPerms[$key]) { continue }
                $hasCurrent = if ($currentPerms -is [hashtable]) { $currentPerms.ContainsKey($key) } else { [bool]$currentPerms.PSObject.Properties[$key] }
                $givenPerms[$key] = if ($hasCurrent) { [bool]$currentPerms.$key } else { $false }
            }
        }
    }

    if ($null -eq $permissions) { $permissions = $givenPerms }

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

    # Build PUT body — all keys camelCase to match the API contract
    $body = @{
        membershipExpirationDate = $expirationDate
        permissions              = $permissions
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Updating safe member '$memberName' in safe '$safeName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "PUT /API/Safes/$encodedSafe/Members/$encodedMember"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: Safe member update suppressed for '$memberName' in '$safeName'."
        $result.Results.Add([PSCustomObject]@{
            SafeName                 = $safeName
            MemberName               = $memberName
            MemberType               = ''
            MembershipExpirationDate = ConvertFrom-CyberArkExpirationTime -Value $expirationDate
            IsPredefinedUser         = $false
            Permissions              = $permissions
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'PUT' `
        -Endpoint "/API/Safes/$encodedSafe/Members/$encodedMember" `
        -Body     $body

    if (-not $response.IsSuccess) {
        $msg = "Safe member update failed for '$memberName' in '$safeName' (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Map response
    $member = if ($response.Data) { $response.Data } else { $null }

    $result.Results.Add([PSCustomObject]@{
        SafeName                 = if ($member -and $member.PSObject.Properties['safeName'])                 { $member.safeName }                 else { $safeName }
        MemberName               = if ($member -and $member.PSObject.Properties['memberName'])               { $member.memberName }               else { $memberName }
        MemberType               = if ($member -and $member.PSObject.Properties['memberType'])               { $member.memberType }               else { '' }
        MembershipExpirationDate = ConvertFrom-CyberArkExpirationTime -Value $(if ($member -and $member.PSObject.Properties['membershipExpirationDate']) { $member.membershipExpirationDate } else { $expirationDate })
        IsPredefinedUser         = if ($member -and $member.PSObject.Properties['isPredefinedUser'])         { [bool]$member.isPredefinedUser }   else { $false }
        Permissions              = if ($member -and $member.PSObject.Properties['permissions'])              { $member.permissions }              else { $permissions }
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Safe member '$memberName' updated successfully in safe '$safeName'."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
