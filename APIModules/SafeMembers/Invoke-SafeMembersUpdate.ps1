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
        @{ Column = 'PermissionRole'; Required = $false; Description = 'Role or Specified. Role values: ReadOnlyStrict / EndUser / PowerUser / SafeManager. Use Specified to set individual permissions.' }
        @{ Column = 'ExpirationDate'; Required = $false; Description = 'Membership expiration date (yyyy-MM-dd) or blank.' }
        @{ Column = 'UseAccounts';                            Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'RetrieveAccounts';                       Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'ListAccounts';                           Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'AddAccounts';                            Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'UpdateAccountContent';                   Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'UpdateAccountProperties';                Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'InitiateCPMAccountManagementOperations'; Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'SpecifyNextAccountContent';              Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'RenameAccounts';                         Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'DeleteAccounts';                         Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'UnlockAccounts';                         Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'ManageSafe';                             Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'ManageSafeMembers';                      Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'BackupSafe';                             Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'ViewAuditLog';                           Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'ViewSafeMembers';                        Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'AccessWithoutConfirmation';              Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'CreateFolders';                          Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'DeleteFolders';                          Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'MoveAccountsAndFolders';                 Required = $false; Description = 'Permission (True/False). Used when PermissionRole is Specified.' }
        @{ Column = 'RequestsAuthorizationLevel1';            Required = $false; Description = 'Dual-control: require 1 approver (True/False). Mutually exclusive with RequestsAuthorizationLevel2.' }
        @{ Column = 'RequestsAuthorizationLevel2';            Required = $false; Description = 'Dual-control: require 2 approvers (True/False). Mutually exclusive with RequestsAuthorizationLevel1.' }
    )
    Priority         = 22
    Version          = '1.2.0'
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

function script:Get-SpecifiedPermissions {
    param([hashtable]$Data)
    $perms = @{}
    foreach ($col in $script:PermissionColumns) {
        $raw      = if ($Data.ContainsKey($col)) { "$($Data[$col])".Trim() } else { '' }
        $camelKey = $col.Substring(0,1).ToLower() + $col.Substring(1)
        $perms[$camelKey] = ($raw -match '^(true|yes|1|y)$')
    }
    # Authorization levels — mutually exclusive; validated separately in Invoke-SafeMembersUpdate
    $perms['requestsAuthorizationLevel1'] = (
        $Data.ContainsKey('RequestsAuthorizationLevel1') -and
        "$($Data['RequestsAuthorizationLevel1'])".Trim() -match '^(true|yes|1|y)$'
    )
    $perms['requestsAuthorizationLevel2'] = (
        $Data.ContainsKey('RequestsAuthorizationLevel2') -and
        "$($Data['RequestsAuthorizationLevel2'])".Trim() -match '^(true|yes|1|y)$'
    )
    return $perms
}

function script:Test-HasSpecifiedColumns {
    param([hashtable]$Data)
    foreach ($col in $script:PermissionColumns) {
        if ($Data.ContainsKey($col)) { return $true }
    }
    if ($Data.ContainsKey('RequestsAuthorizationLevel1')) { return $true }
    if ($Data.ContainsKey('RequestsAuthorizationLevel2')) { return $true }
    return $false
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
    Write-Host '    1 = Role       (named permission preset)' -ForegroundColor DarkGray
    Write-Host '    2 = Specified  (enter each permission individually)' -ForegroundColor DarkGray
    Write-Host ''

    $modeChoice = Show-FieldPrompt -Label 'PermissionMode' `
        -Default '1' `
        -Description 'Select 1 for Role or 2 for Specified.'

    $permissionRole = 'ReadOnlyStrict'
    $specifiedPerms = $null

    if ($modeChoice.Trim() -eq '2') {
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
        Write-Host '    1 = Level 1  (requestsAuthorizationLevel1 - requires 1 approver)'
        Write-Host '    2 = Level 2  (requestsAuthorizationLevel2 - requires 2 approvers)'
        Write-Host ''
        $authChoice = Read-Host '  Select (0-2, default=0)'
        $specifiedPerms['requestsAuthorizationLevel1'] = ($authChoice -eq '1')
        $specifiedPerms['requestsAuthorizationLevel2'] = ($authChoice -eq '2')
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
        -Description 'Membership expiration date (yyyy-MM-dd). Leave blank for no expiration.'

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

    # Resolve permissions: interactive Specified > CSV Specified columns > named role
    $permissions = if ($InputData['Permissions'] -and $InputData['Permissions'] -is [hashtable]) {
        $InputData['Permissions']
    } elseif ((script:Test-HasSpecifiedColumns -Data $InputData) -or $InputData['PermissionRole'] -eq 'Specified') {
        script:Get-SpecifiedPermissions -Data $InputData
    } else {
        $role = if ($InputData['PermissionRole']) { "$($InputData['PermissionRole'])".Trim() } else { 'ReadOnlyStrict' }
        script:Get-PermissionSet -Role $role
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

    # Resolve expiration date - null when blank (API expects null for no expiration)
    $expirationDate = if ($InputData['ExpirationDate'] -and "$($InputData['ExpirationDate'])".Trim() -ne '') {
        "$($InputData['ExpirationDate'])".Trim()
    } else {
        $null
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
            MembershipExpirationDate = $expirationDate
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
        MembershipExpirationDate = if ($member -and $member.PSObject.Properties['membershipExpirationDate']) { $member.membershipExpirationDate } else { $expirationDate }
        IsPredefinedUser         = if ($member -and $member.PSObject.Properties['isPredefinedUser'])         { [bool]$member.isPredefinedUser }   else { $false }
        Permissions              = if ($member -and $member.PSObject.Properties['permissions'])              { $member.permissions }              else { $permissions }
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Safe member '$memberName' updated successfully in safe '$safeName'."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
