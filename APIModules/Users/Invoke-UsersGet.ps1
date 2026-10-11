#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Get User'
    Category         = 'Users'
    Action           = 'Get'
    Description      = 'Retrieve details of a single user by ID.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'UserID'; Required = $true; Description = 'Numeric user ID (from List Users).' }
    )
    Priority         = 51
    Version          = '1.0.0'
}

function Get-UsersGetInput {
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

    $userID = Show-FieldPrompt -Label 'User ID' `
        -Default $(if ($Defaults['UserID']) { $Defaults['UserID'] } else { '' }) `
        -Description 'Numeric user ID from List Users, or leave blank to search by username.'

    if (-not $userID) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Username or name to search for.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $userID = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/Users' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'Users' `
                -IdProperty 'id' `
                -DisplayProperties @('username', 'userType', 'source') `
                -EntityLabel 'user' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $userID) { return $null }
    }

    return @{
        UserID = $userID
    }
}

function Invoke-UsersGet {
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

    $userID = if ($InputData['UserID']) { "$($InputData['UserID'])".Trim() } else { '' }

    if (-not $userID) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-UsersGet: UserID is required but was not provided.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'UserID is required.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.IsFatal = $false
        return $result
    }

    $encodedUserID = [Uri]::EscapeDataString($userID)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting user retrieval for ID: $userID"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Users/$encodedUserID"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Users/$encodedUserID" `
        -PageSize 0 `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "User get failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    $user = $response.Data

    # The 14.6 User model keeps email addresses under internet (businessEmail), not personalDetails.
    $details  = if ($user.PSObject.Properties['personalDetails'] -and $user.personalDetails) { $user.personalDetails } else { $null }
    $internet = if ($user.PSObject.Properties['internet'] -and $user.internet) { $user.internet } else { $null }
    $readProp = { param($Object, [string]$Name) if ($Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { '' } }

    $result.Results.Add([PSCustomObject]@{
        UserID        = $user.id
        Username      = $user.username
        UserType      = $user.userType
        Source        = $user.source
        ComponentUser = $user.componentUser
        Email         = & $readProp $internet 'businessEmail'
        FirstName     = & $readProp $details 'firstName'
        LastName      = & $readProp $details 'lastName'
        Enabled       = & $readProp $user 'enableUser'
        Suspended     = & $readProp $user 'suspended'
        Description   = & $readProp $user 'description'
        Location      = & $readProp $user 'location'
        ExpiryDate    = ConvertFrom-CyberArkExpirationTime -Value $(& $readProp $user 'expiryDate')
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "User get complete. User retrieved: $userID."
    return $result
}
