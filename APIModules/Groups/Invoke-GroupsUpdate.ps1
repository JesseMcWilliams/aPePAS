#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Update Group'
    Category         = 'Groups'
    Action           = 'Update'
    Description      = 'Update properties of an existing CyberArk user group.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'GroupID';      Required = $true;  Description = 'Numeric ID of the group to update.' }
        @{ Column = 'GroupName';    Required = $false; Description = 'New name for the group (leave blank to keep current).' }
        @{ Column = 'Description';  Required = $false; Description = 'New description (leave blank to keep current).' }
        @{ Column = 'Location';     Required = $false; Description = 'New location (leave blank to keep current).' }
    )
    Priority         = 62
    Version          = '1.0.0'
}

function Get-GroupsUpdateInput {
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

    Write-Host '  Group Update  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $groupId = Show-FieldPrompt -Label 'Group ID' `
        -Default $(if ($Defaults['GroupID']) { $Defaults['GroupID'] } else { '' }) `
        -Description 'Numeric group ID to update, or leave blank to search by name.'

    if (-not $groupId) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Group name to search for.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $groupId = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/UserGroups' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'value' `
                -IdProperty 'id' `
                -DisplayProperties @('groupName', 'groupType', 'description') `
                -EntityLabel 'group' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $groupId) { return $null }
    }

    $groupName = Show-FieldPrompt -Label 'GroupName' `
        -Default $(if ($Defaults['GroupName']) { $Defaults['GroupName'] } else { '' }) `
        -Description 'New name for the group. Leave blank to keep the current value.'

    $description = Show-FieldPrompt -Label 'Description' `
        -Default $(if ($Defaults['Description']) { $Defaults['Description'] } else { '' }) `
        -Description 'New description for the group. Leave blank to keep the current value.'

    $location = Show-FieldPrompt -Label 'Location' `
        -Default $(if ($Defaults['Location']) { $Defaults['Location'] } else { '' }) `
        -Description 'New location for the group. Leave blank to keep the current value.'

    return @{
        GroupID     = $groupId
        GroupName   = $groupName
        Description = $description
        Location    = $location
    }
}

function Invoke-GroupsUpdate {
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

    # Validate InputData presence
    if (-not $InputData) {
        $msg = 'InputData is null or missing. GroupID is required.'
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

    # Validate GroupID
    $groupId = if ($InputData['GroupID']) { "$($InputData['GroupID'])".Trim() } else { '' }

    if (-not $groupId) {
        $msg = 'GroupID is required and must not be empty.'
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

    $encodedId = [Uri]::EscapeDataString($groupId)
    $endpoint  = "/API/UserGroups/$encodedId"

    Write-CyberArkLog -Level 'INFO'  -Message "Starting group update. GroupID='$groupId'."
    Write-CyberArkLog -Level 'DEBUG' -Message "PUT $endpoint"

    # Build body - always include groupId as integer; only include optional keys with non-empty values
    $body = @{
        groupId = [int]$groupId
    }

    $groupName   = if ($InputData['GroupName'])   { "$($InputData['GroupName'])".Trim()   } else { '' }
    $description = if ($InputData['Description']) { "$($InputData['Description'])".Trim() } else { '' }
    $location    = if ($InputData['Location'])    { "$($InputData['Location'])".Trim()    } else { '' }

    if ($groupName)   { $body['groupName']   = $groupName   }
    if ($description) { $body['description'] = $description }
    if ($location)    { $body['location']    = $location    }

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: PUT $endpoint would be performed."
        $result.Results.Add([PSCustomObject]@{
            GroupID     = $groupId
            GroupName   = $groupName
            Description = $description
            Location    = $location
            GroupType   = ''
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'PUT' `
        -Endpoint $endpoint `
        -Body     $body

    if (-not $response.IsSuccess) {
        $msg = "Group update failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Map response fields
    $updatedGroup = $response.Data

    $result.Results.Add([PSCustomObject]@{
        GroupID     = $updatedGroup.id
        GroupName   = $updatedGroup.groupName
        Description = $updatedGroup.description
        Location    = $updatedGroup.location
        GroupType   = $updatedGroup.groupType
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Group update complete. GroupID='$groupId'."

    Add-CyberArkLogSummaryEntry `
        -ModuleName     $ModuleMeta.Name `
        -ItemsProcessed $result.ItemsProcessed `
        -Successes      $result.Successes `
        -Failures       $result.Failures

    return $result
}
