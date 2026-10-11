#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Update Safe Member From Template Role'
    Category         = 'SafeMembers'
    Action           = 'UpdateFromTemplateRole'
    Description      = 'Update the permissions of an existing safe member, using permissions copied from a role member of the profile template safe.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';       Required = $true;  Description = 'Name of the safe.' }
        @{ Column = 'MemberName';     Required = $true;  Description = 'Username, group, or role to update.' }
        @{ Column = 'RoleName';       Required = $true;  Description = 'Exact name of a role member on the profile template safe (Role_Template_Safe) whose name matches Role_Group_Prefix. Its permissions are copied verbatim. CSV/bulk input only - interactive mode shows a picker.' }
        @{ Column = 'ExpirationDate'; Required = $false; Description = 'Membership expiration date (yyyy-MM-dd). Blank keeps the current expiration date. None removes it.' }
    )
    Priority         = 25
    Version          = '1.1.1'
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

        Duplicated from Invoke-SafeMembersAddFromTemplateRole.ps1 rather than shared, consistent
        with how script:Get-PermissionSet is already duplicated between the Add/Update
        SafeMembers modules in this codebase - each module file is dot-sourced and unit-tested
        standalone.
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

function Get-SafeMembersUpdateFromTemplateRoleInput {
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

    Write-Host '  Update Safe Member From Template Role  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Name of the safe containing the member to update. (Required)'

    $memberName = Show-FieldPrompt -Label 'MemberName' `
        -Default $(if ($Defaults['MemberName']) { $Defaults['MemberName'] } else { '' }) `
        -Required $true `
        -Description 'Username, group name, or role to update. (Required)'

    [array]$roleOptions = @(script:Get-TemplateRoleOptions -Token $Token)
    $roleName = ''

    if ($roleOptions.Count -gt 0) {
        Write-Host ''
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
        Write-Host ''
        Write-Host '  No template roles found (check Role_Template_Safe / Role_Group_Prefix in Profile Settings).' -ForegroundColor Yellow
        $roleName = Show-FieldPrompt -Label 'RoleName' `
            -Default $(if ($Defaults['RoleName']) { $Defaults['RoleName'] } else { '' }) `
            -Required $true `
            -Description 'Exact name of the template role member to base permissions on.'
    }

    $expirationDate = Show-FieldPrompt -Label 'ExpirationDate' `
        -Default $(if ($Defaults['ExpirationDate']) { $Defaults['ExpirationDate'] } else { '' }) `
        -Description 'Membership expiration date (yyyy-MM-dd). Leave blank to keep the current expiration date; enter None to remove it.'

    return @{
        SafeName       = $safeName
        MemberName     = $memberName
        RoleName       = $roleName
        ExpirationDate = $expirationDate
    }
}

function Invoke-SafeMembersUpdateFromTemplateRole {
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

    $templateSafe = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['Role_Template_Safe']) {
        "$($script:ActiveProfile.Role_Template_Safe)".Trim()
    } else { '' }
    $rolePrefix = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['Role_Group_Prefix']) {
        "$($script:ActiveProfile.Role_Group_Prefix)".Trim()
    } else { '' }

    if (-not $templateSafe) {
        $msg = 'Role_Template_Safe is not configured on the active profile. Set it via Profile Settings before using Update Safe Member From Template Role.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    if (-not $rolePrefix) {
        $msg = 'Role_Group_Prefix is not configured on the active profile. Set it via Profile Settings before using Update Safe Member From Template Role.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $encodedSafe = [Uri]::EscapeDataString($safeName)
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

    $encodedMember  = [Uri]::EscapeDataString($memberName)

    # Expiration date (F85): blank keeps the member's current expiration date, None removes it.
    # Keeping it needs the current membership; the GET is read-only, so it also runs under WhatIf.
    $expirationText = if ($InputData.ContainsKey('ExpirationDate') -and $null -ne $InputData['ExpirationDate']) { "$($InputData['ExpirationDate'])".Trim() } else { '' }
    # A new date is sent as Unix seconds, as the API requires (a yyyy-MM-dd string gets PASWS167E).
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
    if ($expirationText -eq '') {
        Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes/$encodedSafe/Members/$encodedMember (read current expiration date)"
        $currentResponse = Invoke-CyberArkAPI `
            -Token    $Token `
            -Method   'GET' `
            -Endpoint "/API/Safes/$encodedSafe/Members/$encodedMember" `
            -PageSize 0

        if (-not $currentResponse.IsSuccess) {
            $msg = "Could not read the current membership of '$memberName' in '$safeName' to keep its expiration date (HTTP $($currentResponse.StatusCode)): $($currentResponse.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $currentResponse.ErrorDetails })
            $result.Failures++
            $result.ItemsProcessed++
            $result.IsFatal = ($currentResponse.StatusCode -in @(401, 0))
            Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
            return $result
        }

        $current = $currentResponse.Data
        $expirationDate = if ($current -and $current.PSObject.Properties['membershipExpirationDate']) { $current.membershipExpirationDate } else { $null }
        # A negative value from the API means no expiration; send null (same as psPAS Set-PASSafeMember)
        $parsedExpiration = [long]0
        if ($null -ne $expirationDate -and [long]::TryParse("$expirationDate", [ref]$parsedExpiration) -and $parsedExpiration -lt 0) {
            $expirationDate = $null
        }
    }

    # Build PUT body - all keys camelCase to match the API contract. Permissions are copied
    # verbatim from the resolved template role member.
    $body = @{
        membershipExpirationDate = $expirationDate
        permissions              = $permissions
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Updating safe member '$memberName' in safe '$safeName' using template role '$roleName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "PUT /API/Safes/$encodedSafe/Members/$encodedMember"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: safe member update suppressed for '$memberName' in '$safeName' using role '$roleName'."
        $result.Results.Add([PSCustomObject]@{
            SafeName                 = $safeName
            MemberName               = $memberName
            RoleName                 = $roleName
            MembershipExpirationDate = ConvertFrom-CyberArkExpirationTime -Value $expirationDate
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
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $response.ErrorMessage; ErrorDetails = $response.ErrorDetails })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $member = if ($response.Data) { $response.Data } else { $null }

    $result.Results.Add([PSCustomObject]@{
        SafeName                 = if ($member -and $member.PSObject.Properties['safeName'])                 { $member.safeName }                 else { $safeName }
        MemberName               = if ($member -and $member.PSObject.Properties['memberName'])               { $member.memberName }               else { $memberName }
        RoleName                 = $roleName
        MembershipExpirationDate = ConvertFrom-CyberArkExpirationTime -Value $(if ($member -and $member.PSObject.Properties['membershipExpirationDate']) { $member.membershipExpirationDate } else { $expirationDate })
        Permissions              = if ($member -and $member.PSObject.Properties['permissions'])              { $member.permissions }              else { $permissions }
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Safe member '$memberName' updated successfully in safe '$safeName' using template role '$roleName'."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
