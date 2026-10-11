#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Users'
    Category         = 'Users'
    Action           = 'List'
    Description      = 'Retrieve CyberArk Vault users.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @()
    Priority         = 50
    Version          = '1.0.0'
}

function Get-UsersListInput {
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
        -Description 'Free-text search across username and user details. Leave blank for all users.'

    $userType = Show-FieldPrompt -Label 'UserType' `
        -Default $(if ($Defaults['UserType']) { $Defaults['UserType'] } else { '' }) `
        -Description 'Filter by user type (e.g. EPVUser, BasicUser). Leave blank for all types.'

    return @{
        Search   = $search
        UserType = $userType
    }
}

function Invoke-UsersList {
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

    $search   = if ($InputData['Search'])   { "$($InputData['Search'])".Trim()   } else { $null }
    $userType = if ($InputData['UserType']) { "$($InputData['UserType'])".Trim() } else { $null }

    # Build query parameters - only include keys that have a value
    $queryParams = @{}
    if ($search)   { $queryParams['search']   = $search   }
    if ($userType) { $queryParams['UserType'] = $userType }

    $criteriaLog = $(
        $parts = @()
        if ($search)   { $parts += "Search='$search'" }
        if ($userType) { $parts += "UserType='$userType'" }
        if ($parts)    { $parts -join '  ' } else { '(all users)' }
    )

    Write-CyberArkLog -Level 'INFO'  -Message 'Starting user list retrieval.'
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Users | $criteriaLog"

    $response = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/API/Users' `
        -QueryParams $queryParams `
        -WhatIf:     $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "User list failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Users API returns a 'Users' property (not 'value')
    [array]$users = if ($response.Data -and $response.Data.PSObject.Properties['Users']) {
        @($response.Data.Users)
    } else { @() }

    if ((-not $users) -or $users.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message 'No users returned for the given criteria.'
        # Not a failure - a valid empty result
        return $result
    }

    foreach ($user in $users) {
        try {
            # No Email column: the 14.6 UserSummary model has no email field (it's only on the
            # single-user GET, under internet.businessEmail - see Get User).
            $details = if ($user.PSObject.Properties['personalDetails'] -and $user.personalDetails) { $user.personalDetails } else { $null }
            $result.Results.Add([PSCustomObject]@{
                UserID        = $user.id
                Username      = $user.username
                UserType      = $user.userType
                Source        = $user.source
                ComponentUser = $user.componentUser
                FirstName     = if ($details -and $details.PSObject.Properties['firstName']) { $details.firstName } else { '' }
                LastName      = if ($details -and $details.PSObject.Properties['lastName'])  { $details.lastName  } else { '' }
                Enabled       = if ($user.PSObject.Properties['enableUser']) { $user.enableUser } else { '' }
                Suspended     = if ($user.PSObject.Properties['suspended'])  { $user.suspended  } else { '' }
                Location      = if ($user.PSObject.Properties['location'])   { $user.location   } else { '' }
            })
            $result.Successes++
            $result.ItemsProcessed++
        } catch {
            $userId = try { "$($user.id)" } catch { '(unknown)' }
            $msg = "Unexpected error mapping user '$userId': $_"
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

    Write-CyberArkLog -Level 'INFO' -Message "User list complete. Users retrieved: $($result.Successes)."
    return $result
}
