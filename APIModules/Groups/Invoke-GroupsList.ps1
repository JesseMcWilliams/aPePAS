#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Groups'
    Category         = 'Groups'
    Action           = 'List'
    Description      = 'Retrieve CyberArk Vault user groups.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @()
    Priority         = 60
    Version          = '1.1.0'
}

function Get-GroupsListInput {
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
        -Description 'Free-text search across group name and details. Leave blank for all groups.'

    $groupType = Show-FieldPrompt -Label 'GroupType' `
        -Default $(if ($Defaults['GroupType']) { $Defaults['GroupType'] } else { '' }) `
        -Description 'Filter by group type (e.g. EPVGroup, LDAP). Leave blank for all types.'

    return @{
        Search    = $search
        GroupType = $groupType
    }
}

function Invoke-GroupsList {
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

    $search    = if ($InputData['Search'])    { "$($InputData['Search'])".Trim()    } else { $null }
    $groupType = if ($InputData['GroupType']) { "$($InputData['GroupType'])".Trim() } else { $null }

    # Build query parameters - only include keys that have a value
    $queryParams = @{}
    if ($search)    { $queryParams['search']    = $search    }
    if ($groupType) { $queryParams['groupType'] = $groupType }

    $criteriaLog = $(
        $parts = @()
        if ($search)    { $parts += "Search='$search'" }
        if ($groupType) { $parts += "GroupType='$groupType'" }
        if ($parts)     { $parts -join '  ' } else { '(all groups)' }
    )

    Write-CyberArkLog -Level 'INFO'  -Message 'Starting group list retrieval.'
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/UserGroups | $criteriaLog"

    $response = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/API/UserGroups' `
        -QueryParams $queryParams `
        -WhatIf:     $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Group list failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Groups API returns a 'value' property array (not 'Users')
    # Outer @() around the whole if: a single group would otherwise unroll to a bare object, and
    # .Count below throws under strict mode on PS 5.1 (StrictMode lessons section 6).
    [array]$groups = @(if ($response.Data -and $response.Data.PSObject.Properties['value']) {
        $response.Data.value
    })

    if ((-not $groups) -or $groups.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message 'No groups returned for the given criteria.'
        # Not a failure - a valid empty result
        return $result
    }

    foreach ($group in $groups) {
        try {
            # The 14.6 Swagger defines 'directory' as a string: the name of the LDAP directory a
            # Directory group belongs to (also its Self-Hosted SearchIn value). Older code read it
            # as an object with directoryType, so both shapes are handled (K19).
            $directoryName = ''
            $directoryType = ''
            if ($group.PSObject.Properties['directory'] -and $group.directory) {
                $dirValue = $group.directory
                if ($dirValue -is [string]) {
                    $directoryName = $dirValue
                } else {
                    if ($dirValue.PSObject.Properties['directoryType']) { $directoryType = "$($dirValue.directoryType)" }
                    foreach ($prop in @('name', 'directoryName', 'domainName')) {
                        if ($dirValue.PSObject.Properties[$prop] -and $dirValue.$prop) { $directoryName = "$($dirValue.$prop)"; break }
                    }
                }
            }

            $result.Results.Add([PSCustomObject]@{
                GroupID       = $group.id
                GroupName     = $group.groupName
                Description   = $group.description
                Location      = $group.location
                GroupType     = $group.groupType
                Directory     = $directoryName
                DirectoryType = $directoryType
            })
            $result.Successes++
            $result.ItemsProcessed++
        } catch {
            $groupId = try { "$($group.id)" } catch { '(unknown)' }
            $msg = "Unexpected error mapping group '$groupId': $_"
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

    Write-CyberArkLog -Level 'INFO' -Message "Group list complete. Groups retrieved: $($result.Successes)."
    return $result
}
