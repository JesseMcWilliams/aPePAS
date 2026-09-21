#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Remove Group Member'
    Category         = 'Groups'
    Action           = 'RemoveMember'
    # Per user report (confirmed) on Invoke-GroupsAddMember.ps1's identical "memberId" field:
    # this is the user's USERNAME (e.g. "ca_jesse"), not a numeric user ID - confirmed by psPAS's
    # own Remove-PASGroupMember.ps1, whose equivalent $Member parameter carries [Alias('UserName')].
    # This module's DELETE path segment was already treated as a plain string, so no functional
    # bug existed here, but the description/prompt below were mislabeled the same way.
    Description      = 'Remove a user from a user group by username (the API path segment expects the username, e.g. "ca_jesse" - not a numeric user ID).'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'GroupID';  Required = $true; Description = 'Numeric ID of the group.' }
        @{ Column = 'MemberID'; Required = $true; Description = 'Username of the member to remove (e.g. "ca_jesse") - despite the column name, this is NOT a numeric user ID.' }
    )
    Priority         = 66
    Version          = '1.1.0'
}

function Get-GroupsRemoveMemberInput {
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

    Write-Host '  Remove Group Member' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  WARNING: This removes the specified member from the group.' -ForegroundColor Yellow
    Write-Host ''

    $groupId = Show-FieldPrompt -Label 'Group ID' `
        -Default $(if ($Defaults['GroupID']) { $Defaults['GroupID'] } else { '' }) `
        -Description 'Numeric group ID, or leave blank to search by name.'

    if (-not $groupId) {
        $searchTerm = Show-FieldPrompt -Label 'Search Group' `
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

    $memberId = Show-FieldPrompt -Label 'Member (username)' `
        -Default $(if ($Defaults['MemberID']) { $Defaults['MemberID'] } else { '' }) `
        -Description 'Username to remove (e.g. "ca_jesse"), or leave blank to search.'

    if (-not $memberId) {
        $searchTerm = Show-FieldPrompt -Label 'Search User' `
            -Description 'Username to search for.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $memberId = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/Users' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'Users' `
                -IdProperty 'username' `
                -DisplayProperties @('username', 'userType') `
                -EntityLabel 'user' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $memberId) { return $null }
    }

    return @{
        GroupID  = $groupId
        MemberID = $memberId
    }
}

function Invoke-GroupsRemoveMember {
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
        $msg = 'InputData is null or missing. GroupID and MemberID are required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $null
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

    # Validate MemberID
    $memberId = if ($InputData['MemberID']) { "$($InputData['MemberID'])".Trim() } else { '' }

    if (-not $memberId) {
        $msg = 'MemberID is required and must not be empty.'
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

    $encodedGroup  = [Uri]::EscapeDataString($groupId)
    $encodedMember = [Uri]::EscapeDataString($memberId)
    $endpoint      = "/API/UserGroups/$encodedGroup/Members/$encodedMember"

    Write-CyberArkLog -Level 'INFO'  -Message "Starting group member remove. GroupID='$groupId', MemberID='$memberId'."
    Write-CyberArkLog -Level 'DEBUG' -Message "DELETE $endpoint"

    # WhatIf check BEFORE API call
    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: DELETE $endpoint would be performed."
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'DELETE' `
        -Endpoint $endpoint `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Remove group member failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Success - 204 No Content
    $result.Results.Add([PSCustomObject]@{
        GroupID  = $groupId
        MemberID = $memberId
        Removed  = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Group member remove complete. GroupID='$groupId', MemberID='$memberId'."

    Add-CyberArkLogSummaryEntry `
        -ModuleName     $ModuleMeta.Name `
        -ItemsProcessed $result.ItemsProcessed `
        -Successes      $result.Successes `
        -Failures       $result.Failures

    return $result
}
