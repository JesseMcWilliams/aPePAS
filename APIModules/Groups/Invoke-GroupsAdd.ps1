#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Group'
    Category         = 'Groups'
    Action           = 'Add'
    Description      = 'Create a new CyberArk user group.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'GroupName';    Required = $true;  Description = 'Unique group name.' }
        @{ Column = 'Description';  Required = $false; Description = 'Group description.' }
        @{ Column = 'Location';     Required = $false; Description = 'Group location path (default: \).' }
    )
    Priority         = 61
    Version          = '1.0.0'
}

function Get-GroupsAddInput {
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

    Write-Host '  New Group Details  (press Enter to accept each default)' -ForegroundColor DarkGray
    Write-Host ''

    $groupName = Show-FieldPrompt -Label 'GroupName' `
        -Default $(if ($Defaults['GroupName']) { $Defaults['GroupName'] } else { '' }) `
        -Required $true `
        -Description 'Unique group name.'

    $description = Show-FieldPrompt -Label 'Description' `
        -Default $(if ($Defaults['Description']) { $Defaults['Description'] } else { '' }) `
        -Description 'Group description.'

    $location = Show-FieldPrompt -Label 'Location' `
        -Default $(if ($Defaults['Location']) { $Defaults['Location'] } else { '\' }) `
        -Description 'Group location path (default: \).'

    return @{
        GroupName   = $groupName
        Description = $description
        Location    = $location
    }
}

function Invoke-GroupsAdd {
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

    # Validate required field GroupName
    $groupName = if ($InputData['GroupName']) { "$($InputData['GroupName'])".Trim() } else { '' }
    if (-not $groupName) {
        $msg = 'GroupName is required and cannot be empty.'
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

    # Build request body
    $body = @{
        groupName   = $groupName
        description = if ($InputData['Description']) { $InputData['Description'] } else { '' }
        location    = if ($InputData['Location'])    { $InputData['Location'] }    else { '\' }
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Adding group '$groupName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/UserGroups | groupName='$groupName'"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "[WhatIf] Would POST /API/UserGroups for '$groupName'."
        $result.Results.Add([PSCustomObject]@{
            GroupID     = $null
            GroupName   = $groupName
            Description = $body.description
            Location    = $body.location
            GroupType   = ''
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint '/API/UserGroups' `
        -Body     $body

    if (-not $response.IsSuccess) {
        $msg = "Add group failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Map response - group object has id, groupName, description, location, groupType
    $group = if ($response.Data) { $response.Data } else { $null }

    $result.Results.Add([PSCustomObject]@{
        GroupID     = if ($group -and $null -ne $group.id)          { $group.id }          else { $null }
        GroupName   = if ($group -and $group.groupName)             { $group.groupName }   else { $groupName }
        Description = if ($group -and $group.description)           { $group.description } else { $body.description }
        Location    = if ($group -and $group.location)              { $group.location }    else { $body.location }
        GroupType   = if ($group -and $group.groupType)             { $group.groupType }   else { '' }
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Group '$groupName' created successfully."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
