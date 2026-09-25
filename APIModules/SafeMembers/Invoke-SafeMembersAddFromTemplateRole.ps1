#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Safe Member From Template Role'
    Category         = 'SafeMembers'
    Action           = 'AddFromTemplateRole'
    Description      = 'Add a user, group, or role as a member of a safe, using permissions copied from a role member of the profile template safe.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';       Required = $true;  Description = 'Name of the safe.' }
        @{ Column = 'MemberName';     Required = $true;  Description = 'Username, group name, or role name to add.' }
        @{ Column = 'SearchIn';       Required = $false; Description = 'Domain ID (from GetDirectoryServices) or Vault for system component users. Leave blank to use the API default (Vault). CSV/bulk input only - interactive mode shows a picker.' }
        @{ Column = 'MemberType';     Required = $false; Description = 'User / Group / Role (default: User).' }
        @{ Column = 'RoleName';       Required = $true;  Description = 'Exact name of a role member on the profile template safe (Role_Template_Safe) whose name matches Role_Group_Prefix. Its permissions are copied verbatim. CSV/bulk input only - interactive mode shows a picker.' }
        @{ Column = 'ExpirationDate'; Required = $false; Description = 'Membership expiration date (yyyy-MM-dd) or blank.' }
    )
    Priority         = 24
    Version          = '1.0.0'
}

function script:Get-SafeMembersSearchInOptions {
    <#
        Returns the SearchIn choice list for the interactive prompt: Vault is always first;
        additional entries come from GetDirectoryServices (GET /API/Configuration/LDAP/Directories).
        NOTE: the exact response field names for this endpoint have not been confirmed against a
        live CyberArk system - this probes several plausible property names for the ID and display
        name (see Claude_Docs\Reference_Lessons-Learned-CyberArk-API.md Section 5). Falls back to Vault-only
        if the call fails, errors, or returns nothing usable - it never blocks the flow.

        Duplicated from Invoke-SafeMembersAdd.ps1 rather than shared, consistent with how
        script:Get-PermissionSet is already duplicated between the Add/Update SafeMembers
        modules in this codebase - each module file is dot-sourced and unit-tested standalone.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token
    )

    $options = [System.Collections.Generic.List[PSCustomObject]]::new()
    $options.Add([PSCustomObject]@{ DisplayName = 'Vault'; Value = 'Vault' })

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

function script:Get-TemplateRoleOptions {
    <#
        Returns the list of template "roles" to choose from: members of the profile's
        Role_Template_Safe whose memberName starts with Role_Group_Prefix (case-insensitive) -
        the opposite filter from Safes/AddFromTemplate, which excludes these same members.
        Each entry carries the role's raw permissions object (verbatim, camelCase, matching the
        API's own body/response shape) for use once selected.

        Returns an empty array - never throws, never blocks the flow - if Role_Template_Safe /
        Role_Group_Prefix are not configured on the active profile, or if the template safe's
        members cannot be read.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token
    )

    $options = [System.Collections.Generic.List[PSCustomObject]]::new()

    $templateSafe = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['Role_Template_Safe']) {
        "$($script:ActiveProfile.Role_Template_Safe)".Trim()
    } else { '' }
    $rolePrefix = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['Role_Group_Prefix']) {
        "$($script:ActiveProfile.Role_Group_Prefix)".Trim()
    } else { '' }

    if (-not $templateSafe -or -not $rolePrefix) { return $options.ToArray() }

    $encodedTemplateSafe = [Uri]::EscapeDataString($templateSafe)

    try {
        $response = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint "/API/Safes/$encodedTemplateSafe/Members"
    } catch {
        Write-CyberArkLog -Level 'WARN' -Message "Template role lookup failed: $_"
        return $options.ToArray()
    }

    if (-not $response.IsSuccess) {
        Write-CyberArkLog -Level 'WARN' -Message "Template role lookup failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
        return $options.ToArray()
    }

    if (-not $response.Data) { return $options.ToArray() }

    [array]$members = if ($response.Data.PSObject.Properties['value']) { @($response.Data.value) } else { @($response.Data) }

    foreach ($m in $members) {
        $name = if ($m.PSObject.Properties['memberName']) { "$($m.memberName)" } else { '' }
        if (-not $name) { continue }
        if (-not $name.StartsWith($rolePrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $perms = if ($m.PSObject.Properties['permissions'] -and $m.permissions) { $m.permissions } else { @{} }
        $options.Add([PSCustomObject]@{ Name = $name; Permissions = $perms })
    }

    return $options.ToArray()
}

function Get-SafeMembersAddFromTemplateRoleInput {
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

    Write-Host '  New Safe Member From Template Role  (press Enter to accept each default)' -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Name of the safe.'

    $memberName = Show-FieldPrompt -Label 'MemberName' `
        -Default $(if ($Defaults['MemberName']) { $Defaults['MemberName'] } else { '' }) `
        -Required $true `
        -Description 'Username, group name, or role name to add.'

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

    [array]$roleOptions = @(script:Get-TemplateRoleOptions -Token $Token)
    $roleName = ''

    if ($roleOptions.Count -gt 0) {
        Write-Host '  Template Role:' -ForegroundColor DarkGray
        for ($i = 0; $i -lt $roleOptions.Count; $i++) {
            Write-Host "    $($i + 1) = $($roleOptions[$i].Name)"
        }
        Write-Host ''

        $defaultRoleIndex = 1
        if ($Defaults['RoleName']) {
            for ($i = 0; $i -lt $roleOptions.Count; $i++) {
                if ($roleOptions[$i].Name -eq $Defaults['RoleName']) { $defaultRoleIndex = $i + 1; break }
            }
        }

        $roleChoice = Read-Host "  Select role (1-$($roleOptions.Count), default=$defaultRoleIndex)"
        $roleIndex  = $defaultRoleIndex
        $parsedRole = 0
        if ($roleChoice -and [int]::TryParse($roleChoice, [ref]$parsedRole) -and $parsedRole -ge 1 -and $parsedRole -le $roleOptions.Count) {
            $roleIndex = $parsedRole
        }
        $roleName = $roleOptions[$roleIndex - 1].Name
    } else {
        Write-Host '  No template roles found (check Role_Template_Safe / Role_Group_Prefix in Profile Settings).' -ForegroundColor Yellow
        $roleName = Show-FieldPrompt -Label 'RoleName' `
            -Default $(if ($Defaults['RoleName']) { $Defaults['RoleName'] } else { '' }) `
            -Required $true `
            -Description 'Exact name of the template role member to base permissions on.'
    }
    Write-Host ''

    $expirationDate = Show-FieldPrompt -Label 'ExpirationDate' `
        -Default $(if ($Defaults['ExpirationDate']) { $Defaults['ExpirationDate'] } else { '' }) `
        -Description 'Membership expiration date (yyyy-MM-dd), or leave blank for no expiry.'

    return @{
        SafeName       = $safeName
        MemberName     = $memberName
        SearchIn       = $searchIn
        MemberType     = $memberType
        RoleName       = $roleName
        ExpirationDate = $expirationDate
    }
}

function Invoke-SafeMembersAddFromTemplateRole {
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

    $safeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])".Trim() } else { '' }
    if (-not $safeName) {
        $msg = 'SafeName is required and cannot be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $memberName = if ($InputData['MemberName']) { "$($InputData['MemberName'])".Trim() } else { '' }
    if (-not $memberName) {
        $msg = 'MemberName is required and cannot be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $roleName = if ($InputData['RoleName']) { "$($InputData['RoleName'])".Trim() } else { '' }
    if (-not $roleName) {
        $msg = 'RoleName is required and cannot be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # Resolve the template safe name and role-group prefix from the active profile.
    # Both are required - same pattern as Safes/AddFromTemplate.
    $templateSafe = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['Role_Template_Safe']) {
        "$($script:ActiveProfile.Role_Template_Safe)".Trim()
    } else { '' }
    $rolePrefix = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['Role_Group_Prefix']) {
        "$($script:ActiveProfile.Role_Group_Prefix)".Trim()
    } else { '' }

    if (-not $templateSafe) {
        $msg = 'Role_Template_Safe is not configured on the active profile. Set it via Profile Settings before using Add Safe Member From Template Role.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    if (-not $rolePrefix) {
        $msg = 'Role_Group_Prefix is not configured on the active profile. Set it via Profile Settings before using Add Safe Member From Template Role.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $encodedTemplateSafe = [Uri]::EscapeDataString($templateSafe)

    Write-CyberArkLog -Level 'INFO'  -Message "Reading template safe '$templateSafe' members to resolve role '$roleName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes/$encodedTemplateSafe/Members"

    $templateMembersResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Safes/$encodedTemplateSafe/Members"

    if (-not $templateMembersResponse.IsSuccess) {
        $msg = "Template safe '$templateSafe' members could not be read (HTTP $($templateMembersResponse.StatusCode)): $($templateMembersResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $templateMembersResponse.ErrorDetails })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($templateMembersResponse.StatusCode -in @(401, 0))
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    [array]$templateMembers = if ($templateMembersResponse.Data -and $templateMembersResponse.Data.PSObject.Properties['value']) {
        @($templateMembersResponse.Data.value)
    } else { @() }

    $roleMember = $null
    foreach ($m in $templateMembers) {
        $mName = if ($m.PSObject.Properties['memberName']) { "$($m.memberName)" } else { '' }
        if (-not $mName) { continue }
        if (-not $mName.StartsWith($rolePrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($mName.Equals($roleName, [StringComparison]::OrdinalIgnoreCase)) { $roleMember = $m; break }
    }

    if (-not $roleMember) {
        $msg = "RoleName '$roleName' was not found among template safe '$templateSafe' members matching prefix '$rolePrefix'."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $permissions = if ($roleMember.PSObject.Properties['permissions'] -and $roleMember.permissions) { $roleMember.permissions } else { @{} }

    $encodedSafe    = [Uri]::EscapeDataString($safeName)
    $searchIn       = if ($InputData['SearchIn'])   { "$($InputData['SearchIn'])".Trim() }   else { '' }
    $memberType     = if ($InputData['MemberType']) { "$($InputData['MemberType'])".Trim() } else { '' }
    $expirationDate = if ($InputData['ExpirationDate'] -and "$($InputData['ExpirationDate'])".Trim() -ne '') {
        "$($InputData['ExpirationDate'])".Trim()
    } else { $null }

    # Build body - all keys camelCase to match the API contract. Permissions are copied
    # verbatim from the resolved template role member.
    $body = @{
        memberName               = $memberName
        membershipExpirationDate = $expirationDate
        permissions              = $permissions
    }
    if ($memberType) { $body['memberType'] = $memberType }
    if ($searchIn)   { $body['searchIn']   = $searchIn   }

    Write-CyberArkLog -Level 'INFO'  -Message "Adding member '$memberName' to safe '$safeName' using template role '$roleName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Safes/$encodedSafe/Members | MemberName='$memberName' Role='$roleName'"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: would POST /API/Safes/$encodedSafe/Members for member '$memberName' using role '$roleName'."
        $result.Results.Add([PSCustomObject]@{
            SafeName   = $safeName
            MemberName = $memberName
            MemberType = if ($memberType) { $memberType } else { 'User' }
            RoleName   = $roleName
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
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $response.ErrorMessage; ErrorDetails = $response.ErrorDetails })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $member = if ($response.Data) { $response.Data } else { $null }

    $result.Results.Add([PSCustomObject]@{
        SafeName   = if ($member -and $member.PSObject.Properties['safeName'])   { $member.safeName }   else { $safeName }
        MemberName = if ($member -and $member.PSObject.Properties['memberName']) { $member.memberName } else { $memberName }
        MemberType = if ($member -and $member.PSObject.Properties['memberType']) { $member.memberType } else { if ($memberType) { $memberType } else { 'User' } }
        RoleName   = $roleName
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Member '$memberName' added to safe '$safeName' successfully using template role '$roleName'."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
