#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Safe From Template'
    Category         = 'Safes'
    Action           = 'AddFromTemplate'
    Description      = 'Create a new safe by copying settings and non-role-group members from the profile template safe.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';     Required = $true;  Description = 'Unique name for the new safe (max 28 chars).'; Example = 'NewSafe01' }
        @{ Column = 'Description';  Required = $false; Description = 'Description for the new safe. Never copied from the template safe.'; Example = 'Created from template' }
        @{ Column = 'ManagingCPM';  Required = $false; Description = 'CPM username to assign to the new safe. Leave blank for no CPM (default) - no longer copied from the template safe. Interactive mode shows a picker sourced live from the CPM user list, falling back to the profile CPM_List if that call fails.'; Example = 'PasswordManager' }
        @{ Column = 'ExtraMembers'; Required = $false; Description = 'Additional members beyond those copied from the template, as Type:Name:RoleName triples separated by semicolons, e.g. "User:jdoe:Role_Viewer;Group:AdminsGroup:Role_Admin". Type is User or Group. RoleName must exactly match a role-prefixed member (Role_Group_Prefix) on the template safe (Role_Template_Safe) - its permissions are copied verbatim, same as SafeMembers/AddFromTemplateRole. Interactive mode collects these one at a time via prompts instead.'; Example = 'User:jdoe:Role_Viewer;Group:AdminsGroup:Role_Admin' }
    )
    Priority         = 15
    Version          = '1.5.0'
}

function script:Get-TemplateRoleOptions {
    <#
        Returns the list of template "roles" to choose from: members of the profile's
        Role_Template_Safe whose memberName starts with Role_Group_Prefix (case-insensitive).
        Each entry carries the role's raw permissions object (verbatim, camelCase, matching the
        API's own body/response shape) for use once selected, plus a Description pulled from
        GET /API/UserGroups - the same endpoint and response shape (a 'value' array of objects
        with groupName/description) already used by Invoke-GroupsList.ps1. A role is just a
        CyberArk group by naming convention, so its description lives on the group object, not
        on the safe-membership record the rest of this function reads.

        Returns an empty array - never throws, never blocks the flow - if Role_Template_Safe /
        Role_Group_Prefix are not configured on the active profile, or if the template safe's
        members cannot be read. The description lookup is best-effort on top of that: if it
        fails, or a role's group can't be matched, Description stays '' and the flow is
        otherwise unaffected - the role is still fully usable by name.

        Duplicated from Invoke-SafeMembersAddFromTemplateRole.ps1 rather than shared, consistent
        with how script:Get-SafeMembersSearchInOptions is already duplicated between SafeMembers
        modules in this codebase - each module file is dot-sourced and unit-tested standalone.
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

    # Outer @(...) around the whole if/else, not just its branches - see the comment on
    # script:Get-ProfileCPMOptions above for why. Only iterated via foreach below, so this
    # cannot crash today even when unfixed, but kept consistent to prevent a future regression.
    [array]$members = @(if ($response.Data.PSObject.Properties['value']) { $response.Data.value } else { $response.Data })

    foreach ($m in $members) {
        $name = if ($m.PSObject.Properties['memberName']) { "$($m.memberName)" } else { '' }
        if (-not $name) { continue }
        if (-not $name.StartsWith($rolePrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $perms = if ($m.PSObject.Properties['permissions'] -and $m.permissions) { $m.permissions } else { @{} }
        $options.Add([PSCustomObject]@{ Name = $name; Permissions = $perms; Description = '' })
    }

    if ($options.Count -eq 0) { return $options.ToArray() }

    # Best-effort description lookup. 'search' narrows the payload server-side (a hint only,
    # since this codebase never trusts server-side search alone for exact matching - see e.g.
    # SafeMembers/AddFromTemplateRole's role resolution) - matching a role to its group is
    # always done client-side by exact groupName, case-insensitive.
    try {
        $groupsResponse = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/UserGroups' -QueryParams @{ search = $rolePrefix }
        if ($groupsResponse.IsSuccess -and $groupsResponse.Data -and $groupsResponse.Data.PSObject.Properties['value']) {
            [array]$groups = @($groupsResponse.Data.value)
            foreach ($option in $options) {
                $matchedGroup = $groups | Where-Object {
                    $_.PSObject.Properties['groupName'] -and "$($_.groupName)".Equals($option.Name, [StringComparison]::OrdinalIgnoreCase)
                } | Select-Object -First 1
                if ($matchedGroup -and $matchedGroup.PSObject.Properties['description'] -and $matchedGroup.description) {
                    $option.Description = "$($matchedGroup.description)"
                }
            }
        }
    } catch {
        Write-CyberArkLog -Level 'WARN' -Message "Role description lookup (GET /API/UserGroups) failed: $_"
    }

    return $options.ToArray()
}

function script:Get-DescriptionDisplayLines {
    <#
        Splits a free-text description (e.g. a role/group description from GET /API/UserGroups)
        into trimmed, non-empty lines for display, one Write-Host call per line so each one can
        be indented consistently under whatever it's describing. Group descriptions are free
        text and can contain embedded CR/LF - printing a raw multi-line string would only indent
        its first line, with the rest landing back at the console's left margin. Blank lines
        (including ones that are only whitespace) are dropped rather than printed as gaps.

        Returns an empty array - never throws - for a blank, whitespace-only, or missing
        Description.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$Description
    )
    if (-not $Description) { return @() }
    return @($Description -split '\r\n|\r|\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-SafesAddFromTemplateInput {
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

    $templateSafe = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['Role_Template_Safe']) {
        "$($script:ActiveProfile.Role_Template_Safe)"
    } else { '' }

    Write-Host '  New Safe From Template  (press Enter to accept each default)' -ForegroundColor DarkGray
    Write-Host "  Template safe: $(if ($templateSafe) { $templateSafe } else { '(not configured on this profile - see Profile Settings)' })" -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Unique safe name (max 28 chars).'

    $description = Show-FieldPrompt -Label 'Description' `
        -Default $(if ($Defaults['Description']) { $Defaults['Description'] } else { '' }) `
        -Description 'Description for the new safe. Never copied from the template safe.'

    # --- CPM picker: sourced from Get-CpmOptions (Manage-Privilege.ps1), which queries live and
    # falls back to the profile's CPM_List only if that call fails - shared with Add Safe and
    # Assign CPM to Safe, per user direction (2026-09-03) superseding the prior per-page choice.
    Write-Host ''
    [array]$cpmList = @(Get-CpmOptions -Token $Token)

    $managingCPM = ''
    if ($cpmList.Count -gt 0) {
        Write-Host '  Managing CPM:' -ForegroundColor DarkGray
        Write-Host '    1 = (none)'
        for ($i = 0; $i -lt $cpmList.Count; $i++) {
            Write-Host "    $($i + 2) = $($cpmList[$i])"
        }
        Write-Host ''

        $defaultCpmIndex = 1
        if ($Defaults['ManagingCPM']) {
            for ($i = 0; $i -lt $cpmList.Count; $i++) {
                if ($cpmList[$i] -eq $Defaults['ManagingCPM']) { $defaultCpmIndex = $i + 2; break }
            }
        }

        $cpmChoice = Read-Host "  Select CPM (1-$($cpmList.Count + 1), default=$defaultCpmIndex)"
        $cpmIndex  = $defaultCpmIndex
        $parsedCpm = 0
        if ($cpmChoice -and [int]::TryParse($cpmChoice, [ref]$parsedCpm) -and $parsedCpm -ge 1 -and $parsedCpm -le ($cpmList.Count + 1)) {
            $cpmIndex = $parsedCpm
        }
        if ($cpmIndex -gt 1) { $managingCPM = $cpmList[$cpmIndex - 2] }
    } else {
        Write-Host '  (No CPMs configured on this profile - see Profile Settings.)' -ForegroundColor Yellow
        $managingCPM = Show-FieldPrompt -Label 'ManagingCPM' `
            -Default $(if ($Defaults['ManagingCPM']) { $Defaults['ManagingCPM'] } else { '' }) `
            -Description 'CPM username to assign, or leave blank for none.'
    }

    # --- Additional members: Type (User/Group) + Name + a role picked from the template
    # safe's role-prefixed members, same permission-resolution mechanism as
    # SafeMembers/AddFromTemplateRole. A single recurring prompt per member, defaulting to
    # blank: leaving it blank is both "no (more) members to add" and the loop's exit condition
    # - there is no separate "add another? Y/N" gate, since re-prompting for the next name IS
    # that question.
    Write-Host ''
    [array]$roleOptions = @(script:Get-TemplateRoleOptions -Token $Token)
    $extraMemberEntries = [System.Collections.Generic.List[string]]::new()

    while ($true) {
        $memberName = Show-FieldPrompt -Label 'Additional Member' -Default '' `
            -Description 'Username or group name to add as an additional safe member. Leave blank when done adding members.'
        if (-not $memberName) { break }

        Write-Host '  Member Type:' -ForegroundColor DarkGray
        Write-Host '    1 = User'
        Write-Host '    2 = Group'
        $typeChoice = Read-Host '  Select type (1-2, default=1)'
        $memberType = if ($typeChoice -eq '2') { 'Group' } else { 'User' }

        $roleName = ''
        if ($roleOptions.Count -gt 0) {
            Write-Host '  Template Role:' -ForegroundColor DarkGray
            for ($i = 0; $i -lt $roleOptions.Count; $i++) {
                Write-Host "    $($i + 1) = $($roleOptions[$i].Name)"
                foreach ($descLine in (script:Get-DescriptionDisplayLines -Description $roleOptions[$i].Description)) {
                    Write-Host "      $descLine" -ForegroundColor DarkGray
                }
            }
            $roleChoice = Read-Host "  Select role (1-$($roleOptions.Count), default=1)"
            $roleIndex  = 1
            $parsedRole = 0
            if ($roleChoice -and [int]::TryParse($roleChoice, [ref]$parsedRole) -and $parsedRole -ge 1 -and $parsedRole -le $roleOptions.Count) {
                $roleIndex = $parsedRole
            }
            $roleName = $roleOptions[$roleIndex - 1].Name
        } else {
            Write-Host '  No template roles found (check Role_Template_Safe / Role_Group_Prefix in Profile Settings).' -ForegroundColor Yellow
            $roleName = Show-FieldPrompt -Label 'RoleName' -Required $true `
                -Description 'Exact name of the template role member to base permissions on.'
        }

        if ($roleName) {
            $extraMemberEntries.Add("${memberType}:${memberName}:${roleName}")
        }

        Write-Host ''
    }

    return @{
        SafeName     = $safeName
        Description  = $description
        ManagingCPM  = $managingCPM
        ExtraMembers = ($extraMemberEntries -join ';')
    }
}

function Invoke-SafesAddFromTemplate {
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

    $description = if ($InputData['Description']) { "$($InputData['Description'])".Trim() } else { '' }

    # Resolve the template safe name and role-group prefix from the active profile.
    # Both are required - see Docs\Add-Safe-From-Template-Design.md, Decision D4.
    $templateSafe = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['Role_Template_Safe']) {
        "$($script:ActiveProfile.Role_Template_Safe)".Trim()
    } else { '' }
    $rolePrefix = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['Role_Group_Prefix']) {
        "$($script:ActiveProfile.Role_Group_Prefix)".Trim()
    } else { '' }

    if (-not $templateSafe) {
        $msg = 'Role_Template_Safe is not configured on the active profile. Set it via Profile Settings before using Add Safe From Template.'
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

    if (-not $rolePrefix) {
        $msg = 'Role_Group_Prefix is not configured on the active profile. Set it via Profile Settings before using Add Safe From Template.'
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

    $encodedTemplateSafe = [Uri]::EscapeDataString($templateSafe)

    # Step 1: read the template safe's settings.
    Write-CyberArkLog -Level 'INFO'  -Message "Reading template safe '$templateSafe' settings."
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes/$encodedTemplateSafe"

    $templateSafeResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Safes/$encodedTemplateSafe" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $templateSafeResponse.IsSuccess) {
        $msg = "Template safe '$templateSafe' could not be read (HTTP $($templateSafeResponse.StatusCode)): $($templateSafeResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $templateSafeResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($templateSafeResponse.StatusCode -in @(401, 0))
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $templateSafeData = $templateSafeResponse.Data

    # Step 2: read the template safe's member list.
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes/$encodedTemplateSafe/Members"

    $templateMembersResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Safes/$encodedTemplateSafe/Members" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $templateMembersResponse.IsSuccess) {
        $msg = "Template safe '$templateSafe' members could not be read (HTTP $($templateMembersResponse.StatusCode)): $($templateMembersResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $templateMembersResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($templateMembersResponse.StatusCode -in @(401, 0))
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # Outer @(...) around the whole if/else, not just the branch with content - an empty @()
    # emitted from the else branch would otherwise collapse to $null on capture (PowerShell
    # unrolls a script block's output; zero-length output becomes $null even with [array]
    # typing on the LHS), and $templateMembers.Count below would throw under Set-StrictMode.
    # See Docs\Lessons-Learned-PowerShell-Pester.md Section 9.8 for the full explanation - this
    # is the same bug class that crashed in production for a CPM list built the same way.
    [array]$templateMembers = @(if ($templateMembersResponse.Data -and $templateMembersResponse.Data.PSObject.Properties['value']) {
        $templateMembersResponse.Data.value
    })

    # Step 3: exclude role groups - any member whose name starts with Role_Group_Prefix
    # (case-insensitive), regardless of memberType - and exclude any member whose name
    # exactly matches (case-insensitive) an entry in the global $script:ExcludedTemplateMemberNames
    # list (defined in Manage-Privilege.ps1; shared by any Safes/SafeMembers module that reuses it).
    # Everything else is copied.
    # Same outer-@() fix as $templateMembers above - $script:ExcludedTemplateMemberNames = @()
    # (an admin clearing the list, or the default before it's ever seeded) would otherwise
    # collapse to $null and crash on $excludedNames.Count below.
    [array]$excludedNames = @(if ($script:ExcludedTemplateMemberNames) { $script:ExcludedTemplateMemberNames })

    # The template safe's creator is always present in its member list with implicit
    # owner-level access CyberArk grants automatically on safe creation - confirmed live that
    # re-adding that same membership explicitly on the new safe is rejected with HTTP 403
    # Forbidden (the new safe already grants its own creator the same implicit access). Exclude
    # it from the copy the same way role-prefixed and globally-excluded names are excluded.
    $templateCreatorName = if ($templateSafeData.PSObject.Properties['creator'] -and $templateSafeData.creator.PSObject.Properties['name']) {
        "$($templateSafeData.creator.name)"
    } else { '' }

    [array]$membersToCopy = @($templateMembers | Where-Object {
        $memberName = if ($_.PSObject.Properties['memberName']) { "$($_.memberName)" } else { '' }
        if (-not $memberName) { return $false }
        if ($memberName.StartsWith($rolePrefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ($templateCreatorName -and $memberName.Equals($templateCreatorName, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        foreach ($excluded in $excludedNames) {
            if ($memberName.Equals("$excluded", [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        return $true
    })

    Write-CyberArkLog -Level 'INFO' -Message "Template safe '$templateSafe' has $($templateMembers.Count) member(s); $($membersToCopy.Count) will be copied after excluding role groups matching prefix '$rolePrefix' and $($excludedNames.Count) globally excluded name(s)."

    # Step 3a: parse ExtraMembers ("Type:Name:RoleName;Type:Name:RoleName...") into validated
    # specs. Malformed entries are recorded as non-fatal errors and skipped individually -
    # they never block safe creation or the other extra members.
    [array]$extraMemberSpecs = @()
    $extraMembersRaw = if ($InputData['ExtraMembers']) { "$($InputData['ExtraMembers'])".Trim() } else { '' }
    if ($extraMembersRaw) {
        foreach ($entry in ($extraMembersRaw -split ';')) {
            $entry = $entry.Trim()
            if (-not $entry) { continue }
            $parts = $entry -split ':', 3
            $entryType = if ($parts.Count -ge 1) { $parts[0].Trim() } else { '' }
            $entryName = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
            $entryRole = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }

            if ($parts.Count -ne 3 -or -not $entryName -or -not $entryRole -or $entryType -notin @('User', 'Group')) {
                $msg = "Skipping malformed ExtraMembers entry '$entry' - expected 'Type:Name:RoleName' with Type of User or Group."
                Write-CyberArkLog -Level 'ERROR' -Message $msg
                $result.Errors.Add([PSCustomObject]@{ InputData = @{ SafeName = $safeName; ExtraMembers = $entry }; ErrorMessage = $msg; ErrorDetails = $null })
                $result.Failures++
                $result.ItemsProcessed++
                continue
            }

            $extraMemberSpecs += [PSCustomObject]@{ Type = $entryType; Name = $entryName; RoleName = $entryRole }
        }
    }

    # Build the new safe's request body. SafeName/Description are always fresh input;
    # Location and AutoPurgeEnabled are copied from the template safe (Decision D1).
    # ManagingCPM is NOT copied from the template - it comes from InputData (a picker sourced
    # from the profile's CPM_List in interactive mode), defaulting to '' (no CPM) when blank.
    # Field casing matches Invoke-SafesAdd.ps1 - POST /API/Safes expects PascalCase, but the
    # GET response above returns camelCase (a documented quirk of this endpoint).
    # OLACEnabled is intentionally never read or sent - it is not a supported field for
    # this module. NumberOfVersionsRetention and NumberOfDaysRetention are mutually
    # exclusive on this API - only one may be sent; Days wins when the template's value
    # is greater than 0, otherwise Versions is sent.
    $templateVersionsRetention = if ($templateSafeData.PSObject.Properties['numberOfVersionsRetention']) { [int]$templateSafeData.numberOfVersionsRetention } else { 5 }
    $templateDaysRetention     = if ($templateSafeData.PSObject.Properties['numberOfDaysRetention'])     { [int]$templateSafeData.numberOfDaysRetention }     else { 0 }
    $managingCPM               = if ($InputData['ManagingCPM'] -and "$($InputData['ManagingCPM'])".Trim() -ne '') {
        "$($InputData['ManagingCPM'])".Trim()
    } else { '' }

    $safeBody = @{
        SafeName         = $safeName
        Description      = $description
        Location         = if ($templateSafeData.PSObject.Properties['location'])         { $templateSafeData.location }                else { '\' }
        ManagingCPM      = $managingCPM
        AutoPurgeEnabled = if ($templateSafeData.PSObject.Properties['autoPurgeEnabled'])  { [bool]$templateSafeData.autoPurgeEnabled }   else { $false }
    }
    if ($templateDaysRetention -gt 0) {
        $safeBody['NumberOfDaysRetention'] = $templateDaysRetention
    } else {
        $safeBody['NumberOfVersionsRetention'] = $templateVersionsRetention
    }

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "[WhatIf] Would POST /API/Safes for '$safeName', then copy $($membersToCopy.Count) member(s) from template '$templateSafe' and add $($extraMemberSpecs.Count) extra member(s)."

        $result.Results.Add([PSCustomObject]@{
            ItemType         = 'Safe'
            SafeName         = $safeName
            Description      = $safeBody.Description
            Location         = $safeBody.Location
            ManagingCPM      = $safeBody.ManagingCPM
            # Bracket notation, not dot notation: NumberOfVersionsRetention and
            # NumberOfDaysRetention are mutually exclusive in $safeBody (only one is ever set,
            # per the retention rule above) - dot-accessing the absent one throws under
            # Set-StrictMode. This crashed WhatIf mode unconditionally, every time, in real
            # usage - masked by every unit test here, since this test file doesn't dot-source
            # Manage-Privilege.ps1 and so never runs under strict mode itself. See
            # Docs\Lessons-Learned-PowerShell-Pester.md, "Unit tests do not run under
            # Set-StrictMode".
            VersionRetention = if ($safeBody.ContainsKey('NumberOfVersionsRetention')) { $safeBody['NumberOfVersionsRetention'] } else { $null }
            DayRetention     = if ($safeBody.ContainsKey('NumberOfDaysRetention'))     { $safeBody['NumberOfDaysRetention'] }     else { $null }
            AutoPurge        = $safeBody.AutoPurgeEnabled
            MemberName       = ''
            MemberType       = ''
            RoleName         = ''
        })
        $result.Successes++
        $result.ItemsProcessed++

        foreach ($member in $membersToCopy) {
            $memberName = if ($member.PSObject.Properties['memberName']) { "$($member.memberName)" } else { '' }
            $memberType = if ($member.PSObject.Properties['memberType']) { "$($member.memberType)" } else { '' }
            $result.Results.Add([PSCustomObject]@{
                ItemType         = 'Member'
                SafeName         = $safeName
                Description      = ''
                Location         = ''
                ManagingCPM      = ''
                VersionRetention = $null
                DayRetention     = $null
                AutoPurge        = $null
                MemberName       = $memberName
                MemberType       = $memberType
                RoleName         = ''
            })
            $result.Successes++
            $result.ItemsProcessed++
        }

        foreach ($spec in $extraMemberSpecs) {
            $result.Results.Add([PSCustomObject]@{
                ItemType         = 'Member'
                SafeName         = $safeName
                Description      = ''
                Location         = ''
                ManagingCPM      = ''
                VersionRetention = $null
                DayRetention     = $null
                AutoPurge        = $null
                MemberName       = $spec.Name
                MemberType       = $spec.Type
                RoleName         = $spec.RoleName
            })
            $result.Successes++
            $result.ItemsProcessed++
        }

        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # Step 4: create the new safe.
    Write-CyberArkLog -Level 'INFO'  -Message "Creating safe '$safeName' from template '$templateSafe'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Safes | SafeName='$safeName'"

    $safeResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint '/API/Safes' `
        -Body     $safeBody

    if (-not $safeResponse.IsSuccess) {
        $msg = "Add safe failed (HTTP $($safeResponse.StatusCode)): $($safeResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $safeResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($safeResponse.StatusCode -in @(401, 0))
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $createdSafe = if ($safeResponse.Data) { $safeResponse.Data } else { $null }

    $result.Results.Add([PSCustomObject]@{
        ItemType         = 'Safe'
        SafeName         = if ($createdSafe -and $createdSafe.PSObject.Properties['safeName'])                  { $createdSafe.safeName }                  else { $safeName }
        Description      = if ($createdSafe -and $createdSafe.PSObject.Properties['description'])               { $createdSafe.description }               else { $safeBody.Description }
        Location         = if ($createdSafe -and $createdSafe.PSObject.Properties['location'])                  { $createdSafe.location }                  else { $safeBody.Location }
        ManagingCPM      = if ($createdSafe -and $createdSafe.PSObject.Properties['managingCPM'])              { $createdSafe.managingCPM }              else { $safeBody.ManagingCPM }
        # Bracket notation on $safeBody in the fallback branches - see the comment in the
        # WhatIf block above for why dot notation on these two specifically throws.
        VersionRetention = if ($createdSafe -and $createdSafe.PSObject.Properties['numberOfVersionsRetention']) { $createdSafe.numberOfVersionsRetention } elseif ($safeBody.ContainsKey('NumberOfVersionsRetention')) { $safeBody['NumberOfVersionsRetention'] } else { $null }
        DayRetention     = if ($createdSafe -and $createdSafe.PSObject.Properties['numberOfDaysRetention'])     { $createdSafe.numberOfDaysRetention }     elseif ($safeBody.ContainsKey('NumberOfDaysRetention'))     { $safeBody['NumberOfDaysRetention'] }     else { $null }
        AutoPurge        = if ($createdSafe -and $createdSafe.PSObject.Properties['autoPurgeEnabled'])          { $createdSafe.autoPurgeEnabled }          else { $safeBody.AutoPurgeEnabled }
        MemberName       = ''
        MemberType       = ''
        RoleName         = ''
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Safe '$safeName' created. Copying $($membersToCopy.Count) member(s) from template."

    # Step 5: copy each retained member onto the new safe.
    $encodedNewSafe = [Uri]::EscapeDataString($safeName)

    foreach ($member in $membersToCopy) {
        $memberName = if ($member.PSObject.Properties['memberName']) { "$($member.memberName)" } else { '' }
        if (-not $memberName) { continue }
        $memberType  = if ($member.PSObject.Properties['memberType'])  { "$($member.memberType)" } else { '' }
        $permissions = if ($member.PSObject.Properties['permissions'] -and $member.permissions) { $member.permissions } else { @{} }

        # membershipExpirationDate is never copied from the template (Decision D3).
        $memberBody = @{
            memberName               = $memberName
            membershipExpirationDate = $null
            permissions              = $permissions
        }
        if ($memberType) { $memberBody['memberType'] = $memberType }

        Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Safes/$encodedNewSafe/Members | MemberName='$memberName'"

        $memberResponse = Invoke-CyberArkAPI `
            -Token    $Token `
            -Method   'POST' `
            -Endpoint "/API/Safes/$encodedNewSafe/Members" `
            -Body     $memberBody

        if (-not $memberResponse.IsSuccess) {
            $msg = "Add member '$memberName' to safe '$safeName' failed (HTTP $($memberResponse.StatusCode)): $($memberResponse.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = @{ SafeName = $safeName; MemberName = $memberName }
                ErrorMessage = $msg
                ErrorDetails = $memberResponse.ErrorDetails
            })
            $result.Failures++
            $result.ItemsProcessed++
            if ($memberResponse.StatusCode -in @(401, 0)) {
                $result.IsFatal = $true
                Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
                return $result
            }
            continue
        }

        $addedMember = if ($memberResponse.Data) { $memberResponse.Data } else { $null }

        $result.Results.Add([PSCustomObject]@{
            ItemType         = 'Member'
            SafeName         = $safeName
            Description      = ''
            Location         = ''
            ManagingCPM      = ''
            VersionRetention = $null
            DayRetention     = $null
            AutoPurge        = $null
            OLACEnabled      = $null
            MemberName       = if ($addedMember -and $addedMember.PSObject.Properties['memberName']) { $addedMember.memberName } else { $memberName }
            MemberType       = if ($addedMember -and $addedMember.PSObject.Properties['memberType']) { $addedMember.memberType } else { $memberType }
            RoleName         = ''
        })
        $result.Successes++
        $result.ItemsProcessed++
    }

    # Step 6: add any extra members (parsed from InputData.ExtraMembers in Step 3a), resolving
    # each one's permissions from the template safe's matching role-prefixed member - same
    # mechanism as SafeMembers/AddFromTemplateRole, reusing $templateMembers already fetched in
    # Step 2 rather than a second API call.
    if ($extraMemberSpecs.Count -gt 0) {
        Write-CyberArkLog -Level 'INFO' -Message "Adding $($extraMemberSpecs.Count) extra member(s) to safe '$safeName'."
    }

    foreach ($spec in $extraMemberSpecs) {
        $roleMember = $null
        foreach ($m in $templateMembers) {
            $mName = if ($m.PSObject.Properties['memberName']) { "$($m.memberName)" } else { '' }
            if (-not $mName) { continue }
            if (-not $mName.StartsWith($rolePrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($mName.Equals($spec.RoleName, [StringComparison]::OrdinalIgnoreCase)) { $roleMember = $m; break }
        }

        if (-not $roleMember) {
            $msg = "RoleName '$($spec.RoleName)' was not found among template safe '$templateSafe' members matching prefix '$rolePrefix' (extra member '$($spec.Name)')."
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = @{ SafeName = $safeName; MemberName = $spec.Name; RoleName = $spec.RoleName }
                ErrorMessage = $msg
                ErrorDetails = $null
            })
            $result.Failures++
            $result.ItemsProcessed++
            continue
        }

        $permissions = if ($roleMember.PSObject.Properties['permissions'] -and $roleMember.permissions) { $roleMember.permissions } else { @{} }

        # membershipExpirationDate is never set here either, consistent with the template-copy
        # loop above.
        $extraMemberBody = @{
            memberName               = $spec.Name
            membershipExpirationDate = $null
            permissions              = $permissions
            memberType                = $spec.Type
        }

        Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Safes/$encodedNewSafe/Members | MemberName='$($spec.Name)' Role='$($spec.RoleName)'"

        $extraMemberResponse = Invoke-CyberArkAPI `
            -Token    $Token `
            -Method   'POST' `
            -Endpoint "/API/Safes/$encodedNewSafe/Members" `
            -Body     $extraMemberBody

        if (-not $extraMemberResponse.IsSuccess) {
            $msg = "Add extra member '$($spec.Name)' to safe '$safeName' failed (HTTP $($extraMemberResponse.StatusCode)): $($extraMemberResponse.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = @{ SafeName = $safeName; MemberName = $spec.Name }
                ErrorMessage = $msg
                ErrorDetails = $extraMemberResponse.ErrorDetails
            })
            $result.Failures++
            $result.ItemsProcessed++
            if ($extraMemberResponse.StatusCode -in @(401, 0)) {
                $result.IsFatal = $true
                Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
                return $result
            }
            continue
        }

        $addedExtraMember = if ($extraMemberResponse.Data) { $extraMemberResponse.Data } else { $null }

        $result.Results.Add([PSCustomObject]@{
            ItemType         = 'Member'
            SafeName         = $safeName
            Description      = ''
            Location         = ''
            ManagingCPM      = ''
            VersionRetention = $null
            DayRetention     = $null
            AutoPurge        = $null
            OLACEnabled      = $null
            MemberName       = if ($addedExtraMember -and $addedExtraMember.PSObject.Properties['memberName']) { $addedExtraMember.memberName } else { $spec.Name }
            MemberType       = if ($addedExtraMember -and $addedExtraMember.PSObject.Properties['memberType']) { $addedExtraMember.memberType } else { $spec.Type }
            RoleName         = $spec.RoleName
        })
        $result.Successes++
        $result.ItemsProcessed++
    }

    Write-CyberArkLog -Level 'INFO' -Message "Add Safe From Template complete. Safe '$safeName' created; $($result.Successes - 1) of $($membersToCopy.Count + $extraMemberSpecs.Count) member(s) added."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
