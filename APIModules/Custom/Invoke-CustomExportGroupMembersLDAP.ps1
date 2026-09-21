#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Export LDAP Group Members'
    Category         = 'Custom'
    Action           = 'ExportGroupMembersLDAP'
    Description      = 'Export members of all CyberArk LDAP/Directory groups by querying Active Directory using ADSI, with recursive nested group expansion and relationship path tracking.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @()
    # Bulk export tool whose whole purpose is producing a CSV - save automatically with no
    # "Save to CSV?" prompt or file dialog, straight to the default path. See Get-CsvSavePath
    # and the ProducesOutput handling in Invoke-ActionModule (Manage-Privilege.ps1).
    AutoSaveCsv      = $true
    # No date in the saved filename - matches Custom/ExportAll's own fixed-name convention, so
    # every Custom export tool behaves the same (always the latest snapshot, overwritten on the
    # next run - use automation mode's -FilenameFormat with {Date} for dated snapshots instead).
    CsvFilenameNoDate = $true
    Priority         = 83
    Version          = '1.2.0'
}

function Get-CustomExportGroupMembersLDAPInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Export LDAP Group Members  (press Enter to use current domain)' -ForegroundColor DarkGray
    Write-Host ''

    $dc = Show-FieldPrompt -Label 'Domain Controller' `
        -Default $(if ($Defaults['DomainController']) { $Defaults['DomainController'] } else { '' }) `
        -Description 'Optional LDAP path (e.g. LDAP://DC=corp,DC=com). Leave blank to use the current machine domain.'

    return @{
        DomainController = $dc
    }
}

function Invoke-CustomExportGroupMembersLDAP {
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

    $domainController = if ($InputData['DomainController']) { "$($InputData['DomainController'])".Trim() } else { '' }
    $ignoreSSL        = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }

    # Step 1 - retrieve all CyberArk groups
    Write-Host '  Retrieving CyberArk groups...' -ForegroundColor Cyan
    Write-CyberArkLog -Level 'INFO' -Message 'Export LDAP Group Members: retrieving group list.'

    $groupsResponse = Invoke-CyberArkAPI `
        -Token     $Token `
        -Method    'GET' `
        -Endpoint  '/API/UserGroups' `
        -IgnoreSSL:$ignoreSSL

    if (-not $groupsResponse.IsSuccess) {
        $msg = "Export LDAP Group Members: group list failed (HTTP $($groupsResponse.StatusCode)): $($groupsResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $groupsResponse.ErrorMessage
            ErrorDetails = $groupsResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($groupsResponse.StatusCode -in @(401, 0))
        return $result
    }

    $allGroups = if ($groupsResponse.Data -and $groupsResponse.Data.PSObject.Properties['value']) {
        @($groupsResponse.Data.value)
    } else { @() }

    # Build candidate list from all CyberArk groups.
    # ISPSS returns all groups with groupType='Vault' regardless of their actual directory source,
    # so client-side type filtering is not reliable. The AD lookup below is the filter:
    # groups found in AD are LDAP-backed; groups not found are silently skipped.
    $ldapGroups = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($g in $allGroups) {
        $gname  = if ($g.PSObject.Properties['groupName'] -and $g.groupName) { "$($g.groupName)" } else { '' }
        $gtype  = if ($g.PSObject.Properties['groupType'] -and $g.groupType) { "$($g.groupType)" } else { '' }
        $dirType= if ($g.PSObject.Properties['directory'] -and $g.directory -and
                      $g.directory.PSObject.Properties['directoryType'] -and $g.directory.directoryType) {
            "$($g.directory.directoryType)"
        } else { '' }
        if ($gname -and $gname -match '@') {
            $ldapGroups.Add([PSCustomObject]@{
                CyberArkGroupName = $gname
                GroupType         = $gtype
                DirectoryType     = $dirType
            })
        }
    }

    if ($ldapGroups.Count -eq 0) {
        Write-Host '  No groups found in CyberArk.' -ForegroundColor Yellow
        Write-CyberArkLog -Level 'WARN' -Message 'Export LDAP Group Members: no groups returned from CyberArk.'
        return $result
    }

    Write-Host "  Found $($ldapGroups.Count) group$(if ($ldapGroups.Count -ne 1) { 's' }). Searching in AD..." -ForegroundColor Cyan
    Write-Host ''

    # Build ADSI searcher root - use provided DC or default (current domain)
    $searchRoot = $null
    try {
        if ($domainController) {
            $searchRoot = New-Object System.DirectoryServices.DirectoryEntry($domainController)
        } else {
            $searchRoot = New-Object System.DirectoryServices.DirectoryEntry
        }
    } catch {
        $msg = "Export LDAP Group Members: failed to connect to ADSI ($domainController): $_"
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

    # Helper: get AD object info from DN using ADSI
    # Returns a hashtable or $null on failure
    $fnGetADObject = {
        param([string]$DN)
        try {
            $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$DN")
            $schemaClass = $entry.SchemaClassName
            $sam = if ($entry.Properties['sAMAccountName'] -and $entry.Properties['sAMAccountName'].Count -gt 0) {
                "$($entry.Properties['sAMAccountName'][0])"
            } else { '' }
            $displayName = if ($entry.Properties['displayName'] -and $entry.Properties['displayName'].Count -gt 0) {
                "$($entry.Properties['displayName'][0])"
            } else { $sam }
            return @{
                DN          = $DN
                SAM         = $sam
                DisplayName = $displayName
                IsGroup     = ($schemaClass -eq 'group')
            }
        } catch {
            return $null
        }
    }

    # Helper: find AD group by sAMAccountName, returns DN or $null
    $fnFindGroupDN = {
        param([string]$GroupSAM, [System.DirectoryServices.DirectoryEntry]$Root)
        try {
            $searcher = New-Object System.DirectoryServices.DirectorySearcher($Root)
            $searcher.Filter = "(&(objectClass=group)(sAMAccountName=$GroupSAM))"
            $searcher.PropertiesToLoad.Add('distinguishedName') | Out-Null
            $searcher.PropertiesToLoad.Add('member') | Out-Null
            $entry = $searcher.FindOne()
            if ($entry) {
                return "$($entry.Properties['distinguishedName'][0])"
            }
            return $null
        } catch {
            return $null
        }
    }

    # Helper: get member DNs of an AD group given its DN, returns array of DN strings
    $fnGetGroupMemberDNs = {
        param([string]$GroupDN, [System.DirectoryServices.DirectoryEntry]$Root)
        try {
            $searcher = New-Object System.DirectoryServices.DirectorySearcher($Root)
            $searcher.Filter = "(distinguishedName=$GroupDN)"
            $searcher.PropertiesToLoad.Add('member') | Out-Null
            $entry = $searcher.FindOne()
            if ($entry -and $entry.Properties['member'] -and $entry.Properties['member'].Count -gt 0) {
                return @($entry.Properties['member'])
            }
            return @()
        } catch {
            return @()
        }
    }

    $stack   = [System.Collections.Generic.Stack[hashtable]]::new()
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    $groupIdx= 0

    foreach ($cyberArkGroup in $ldapGroups) {
        $groupIdx++
        $cyGroupName = $cyberArkGroup.CyberArkGroupName

        # Strip domain prefix (e.g. DOMAIN\GroupName -> GroupName) then UPN suffix (e.g. GroupName@domain.com -> GroupName)
        $adGroupSAM = if ($cyGroupName -match '^[^\\]+\\(.+)$') { $Matches[1] } else { $cyGroupName }
        $adGroupSAM = if ($adGroupSAM  -match '^([^@]+)@.+$')   { $Matches[1] } else { $adGroupSAM  }

        Write-Host "  [$groupIdx/$($ldapGroups.Count)] $cyGroupName" -ForegroundColor White -NoNewline

        $ldapFilter = "(&(objectClass=group)(sAMAccountName=$adGroupSAM))"
        Write-CyberArkLog -Level 'DEBUG' -Message "Export LDAP Group Members: LDAP query: $ldapFilter"

        # Find the AD group
        $adGroupDN = & $fnFindGroupDN -GroupSAM $adGroupSAM -Root $searchRoot

        if (-not $adGroupDN) {
            Write-Host ' - not in this domain, skipped.' -ForegroundColor DarkGray
            Write-CyberArkLog -Level 'DEBUG' -Message "Export LDAP Group Members: '$adGroupSAM' not found in domain — likely a Vault-only group, skipping."
            $result.ItemsProcessed++
            continue
        }

        [void]$visited.Clear()
        [void]$stack.Clear()

        $stack.Push(@{
            GroupDN  = $adGroupDN
            GroupSAM = $adGroupSAM
            Path     = $cyGroupName
            Depth    = 1
        })

        $memberCount = 0

        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            $cDN     = $current['GroupDN']

            if ($visited.Contains($cDN)) { continue }
            [void]$visited.Add($cDN)

            $memberDNs = & $fnGetGroupMemberDNs -GroupDN $cDN -Root $searchRoot

            foreach ($memberDN in $memberDNs) {
                $adObj = & $fnGetADObject -DN $memberDN

                if (-not $adObj) {
                    # Could not resolve - include as unknown
                    $result.Results.Add([PSCustomObject]@{
                        CyberArkGroupName = $cyGroupName
                        ADGroupPath       = $current['GroupSAM']
                        MemberSAM         = ''
                        MemberDisplayName = "(unresolvable: $memberDN)"
                        MemberType        = 'Unknown'
                        MemberLevel       = if ($current['Depth'] -eq 1) { 'Parent' } else { 'Child' }
                        Relationship      = $current['Path']
                    })
                    $result.Successes++
                    $result.ItemsProcessed++
                    $memberCount++
                    continue
                }

                if ($adObj['IsGroup']) {
                    $result.Results.Add([PSCustomObject]@{
                        CyberArkGroupName = $cyGroupName
                        ADGroupPath       = $current['GroupSAM']
                        MemberSAM         = $adObj['SAM']
                        MemberDisplayName = $adObj['DisplayName']
                        MemberType        = 'Group'
                        MemberLevel       = if ($current['Depth'] -eq 1) { 'Parent' } else { 'Child' }
                        Relationship      = $current['Path']
                    })
                    $result.Successes++
                    $result.ItemsProcessed++
                    $memberCount++

                    # Push nested group for expansion
                    if (-not $visited.Contains($adObj['DN'])) {
                        $nestedSAM  = $adObj['SAM']
                        $nestedPath = "$($current['Path']) > $nestedSAM"
                        $stack.Push(@{
                            GroupDN  = $adObj['DN']
                            GroupSAM = $nestedSAM
                            Path     = $nestedPath
                            Depth    = $current['Depth'] + 1
                        })
                    }
                } else {
                    $result.Results.Add([PSCustomObject]@{
                        CyberArkGroupName = $cyGroupName
                        ADGroupPath       = $current['GroupSAM']
                        MemberSAM         = $adObj['SAM']
                        MemberDisplayName = $adObj['DisplayName']
                        MemberType        = 'User'
                        MemberLevel       = if ($current['Depth'] -eq 1) { 'Parent' } else { 'Child' }
                        Relationship      = $current['Path']
                    })
                    $result.Successes++
                    $result.ItemsProcessed++
                    $memberCount++
                }
            }
        }

        Write-Host " - $memberCount row$(if ($memberCount -ne 1) { 's' })" -ForegroundColor Green
        $result.ItemsProcessed++  # Count the CyberArk group itself as one processed item
    }

    Write-Host ''
    Write-CyberArkLog -Level 'INFO' -Message "Export LDAP Group Members complete. Groups: $groupIdx, Rows: $($result.Successes)."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
