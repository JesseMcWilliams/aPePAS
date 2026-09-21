#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Get Group Members'
    Category         = 'Groups'
    Action           = 'GetMembers'
    Description      = 'Retrieve all members of a user group.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'GroupID';         Required = $true;  Description = 'Numeric ID of the group.' }
        @{ Column = 'IncludeMembers';  Required = $false; Description = 'Include full member details in the response (optional, default false).' }
    )
    Priority         = 64
    Version          = '1.2.0'
}

function Get-GroupsGetMembersInput {
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

    Write-Host '  Get Group Members Criteria' -ForegroundColor DarkGray
    Write-Host ''

    $groupId = Show-FieldPrompt -Label 'Group ID' `
        -Default $(if ($Defaults['GroupID']) { $Defaults['GroupID'] } else { '' }) `
        -Description 'Numeric group ID, or leave blank to search by name.'

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

    $includeMembersStr = Show-FieldPrompt -Label 'Include Members' `
        -Default $(if ($Defaults['IncludeMembers']) { 'Y' } else { 'N' }) `
        -Description 'Include full member details in the response? (Y/N, default N).'

    return @{
        GroupID        = $groupId
        IncludeMembers = ($includeMembersStr -match '^[Yy]$')
    }
}

function Invoke-GroupsGetMembers {
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

    # Validate InputData
    if (-not $InputData) {
        $msg = 'InputData is null or missing. GroupID is required.'
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

    $groupId = if ($InputData['GroupID']) { "$($InputData['GroupID'])".Trim() } else { '' }

    if ([string]::IsNullOrEmpty($groupId)) {
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

    # includeMembers is optional and defaults to false server-side, so omitting it (the
    # pre-existing behavior) is not the silent-empty-results risk originally suspected -
    # confirmed against a live tenant. Exposed as an opt-in field matching psPAS's own
    # parameter, same CSV-string-to-bool matching used elsewhere (see Lessons-Learned 31.1 -
    # never cast a CSV-sourced string directly to [bool]).
    $includeMembers = "$($InputData['IncludeMembers'])".Trim() -match '(?i)^(true|yes|y|1)$'
    $queryParams    = @{}
    if ($includeMembers) { $queryParams['includeMembers'] = 'true' }

    Write-CyberArkLog -Level 'INFO'  -Message "Starting group members retrieval for group ID: $groupId"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/UserGroups/$encodedId | IncludeMembers=$includeMembers"

    $response = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    "/API/UserGroups/$encodedId" `
        -QueryParams $queryParams `
        -PageSize    0 `
        -WhatIf:     $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Get group members failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Members are returned inline on the group GET; property name varies by PVWA version
    [array]$members = @()
    if ($response.Data) {
        foreach ($prop in @('members', 'Members', 'groupMembers', 'value')) {
            if ($response.Data.PSObject.Properties[$prop] -and $response.Data.$prop) {
                [array]$members = @($response.Data.$prop)
                break
            }
        }
    }

    if ((-not $members) -or $members.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message 'No members found in group.'
        # Not a failure - a valid empty result
        return $result
    }

    foreach ($m in $members) {
        try {
            # Confirmed live: a real member entry on this tenant is only { "username", "id" } -
            # no userType/componentUser at all, with or without includeMembers=true. Guarded with
            # PSObject.Properties[] existence checks (this codebase's established pattern) rather
            # than assuming psPAS's documented shape is complete, since dot-accessing an absent
            # property throws PropertyNotFoundException under Set-StrictMode.
            $result.Results.Add([PSCustomObject]@{
                MemberID      = if ($m.PSObject.Properties['id'])            { $m.id }            else { $null }
                Username      = if ($m.PSObject.Properties['username'])      { $m.username }      else { $null }
                UserType      = if ($m.PSObject.Properties['userType'])      { $m.userType }      else { $null }
                ComponentUser = if ($m.PSObject.Properties['componentUser']) { $m.componentUser } else { $null }
            })
            $result.Successes++
            $result.ItemsProcessed++
        } catch {
            $memberId = try { "$($m.id)" } catch { '(unknown)' }
            $msg = "Unexpected error mapping group member '$memberId': $_"
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

    Write-CyberArkLog -Level 'INFO' -Message "Group members retrieval complete. Members retrieved: $($result.Successes)."
    return $result
}
