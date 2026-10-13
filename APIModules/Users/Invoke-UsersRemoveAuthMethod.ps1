#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Remove User Allowed Auth Method'
    Category         = 'Users'
    Action           = 'RemoveAuthMethod'
    Description      = 'Remove allowed authentication methods (for example SAML, PKI) from a Vault user.'
    # PATCH /API/Users/RemoveAllowedAuthenticationMethods/Bulk {BulkItems:[{UserIds,AllowedAuthenticationMethods}]}:
    # PVWA 14.6 Swagger and psPAS Remove-PASUserAllowedAuthenticationMethod (14.6+). Self-Hosted only:
    # no reference shows it on Privilege Cloud.
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'UserID';      Required = $false; Description = 'Numeric user ID (from List Users). Give this or Username. When set, Username is ignored.' }
        @{ Column = 'Username';    Required = $false; Description = 'Exact username. Resolved to a user ID; the row fails when no user or more than one user matches.' }
        @{ Column = 'AuthMethods'; Required = $true;  Description = 'Allowed authentication method IDs to remove, separated by semicolons (for example SAML;PKI).'; Example = 'SAML;PKI' }
    )
    Priority         = 56
    Version          = '1.0.0'
}

function Get-UsersRemoveAuthMethodInput {
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

    Write-Host '  Remove User Allowed Authentication Methods' -ForegroundColor DarkGray
    Write-Host ''

    $userID = Show-FieldPrompt -Label 'User ID' `
        -Default $(if ($Defaults['UserID']) { $Defaults['UserID'] } else { '' }) `
        -Description 'Numeric user ID, or leave blank to search by username.'

    if (-not $userID) {
        $searchTerm = Show-FieldPrompt -Label 'Search' -Description 'Username or name to search for.'
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

    $authMethods = Show-FieldPrompt -Label 'AuthMethods' `
        -Default $(if ($Defaults['AuthMethods']) { $Defaults['AuthMethods'] } else { '' }) `
        -Description 'Authentication method IDs separated by semicolons (for example SAML;PKI).'
    if (-not $authMethods) { return $null }

    return @{
        UserID      = $userID
        AuthMethods = $authMethods
    }
}

function Invoke-UsersRemoveAuthMethod {
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

    $adding = $false

    $addError = {
        param([string]$Message, $Details, [int]$StatusCode = -1)
        Write-CyberArkLog -Level 'ERROR' -Message $Message
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $Message; ErrorDetails = $Details })
        $result.Failures++
        $result.ItemsProcessed++
        if ($StatusCode -in @(401, 0)) { $result.IsFatal = $true }
    }

    # ── Validation ────────────────────────────────────────────────────────────

    $ident = Get-CyberArkUserIdentifier -InputData $InputData
    if ($ident.ErrorMessage) { & $addError $ident.ErrorMessage $null; return $result }

    $methodsText = if ($InputData.ContainsKey('AuthMethods') -and $null -ne $InputData['AuthMethods']) { "$($InputData['AuthMethods'])" } else { '' }
    [string[]]$methods = ConvertTo-CyberArkUserList -Value $methodsText
    if ($methods.Count -eq 0) { & $addError 'AuthMethods is required (one or more method IDs separated by semicolons).' $null; return $result }

    # ── Identify the user ─────────────────────────────────────────────────────

    $userId   = $ident.UserID
    $userName = $ident.Username

    if ($ident.NeedsLookup) {
        Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Users?search=$userName (resolve Username to UserID)"
        $lookupResp = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/Users' -QueryParams @{ search = $userName }
        if (-not $lookupResp.IsSuccess) {
            & $addError "User lookup for '$userName' failed (HTTP $($lookupResp.StatusCode)): $($lookupResp.ErrorMessage)" $lookupResp.ErrorDetails $lookupResp.StatusCode
            return $result
        }
        [array]$userList = @(if ($lookupResp.Data -and $lookupResp.Data.PSObject.Properties['Users'] -and $null -ne $lookupResp.Data.Users) { $lookupResp.Data.Users })
        $match = Select-CyberArkUserMatch -Users $userList -Username $userName
        if ($match.ErrorMessage) { & $addError $match.ErrorMessage $null; return $result }
        $userId = $match.UserID
        Write-CyberArkLog -Level 'DEBUG' -Message "Resolved Username '$userName' to UserID $userId."
    }

    $verb       = if ($adding) { 'Add' } else { 'Remove' }
    $endpoint   = "/API/Users/$($verb)AllowedAuthenticationMethods/Bulk"
    $userPath   = "/API/Users/$([Uri]::EscapeDataString($userId))"
    $methodList = $methods -join ';'

    Write-CyberArkLog -Level 'INFO'  -Message "Starting $($verb.ToLower()) of allowed authentication methods '$methodList' for UserID '$userId'."
    Write-CyberArkLog -Level 'DEBUG' -Message "PATCH $endpoint"

    # ── WhatIf ────────────────────────────────────────────────────────────────

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: PATCH $endpoint would be performed for UserID '$userId'."
        $result.Results.Add([PSCustomObject]@{ UserID = $userId; Username = $userName; AuthMethods = $methodList; Updated = $false })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # ── API call ──────────────────────────────────────────────────────────────

    # Field casing from the 14.6 Swagger UserAuthBulkItem model.
    $body = @{
        BulkItems = @(
            @{
                UserIds                      = @([long]$userId)
                AllowedAuthenticationMethods = [string[]]$methods
            }
        )
    }
    $response = Invoke-CyberArkAPI -Token $Token -Method 'PATCH' -Endpoint $endpoint -Body $body

    # The Bulk endpoints need PVWA 14.6+. On a 404, fall back to PUT /API/Users/{id} with the
    # merged allowedAuthenticationMethods list (field added in 14.4, per psPAS Set-PASUser). PUT
    # replaces the user, so GET it first and resend its current values.
    $fallback = (-not $response.IsSuccess -and $response.StatusCode -eq 404)
    if ($fallback) {
        Write-CyberArkLog -Level 'WARN' -Message "PATCH $endpoint returned 404 (needs PVWA 14.6 or later). Falling back to PUT $userPath with allowedAuthenticationMethods."
    }

    # A 200 only means the job was queued: the body is the bulk job ID, and the change itself can
    # still fail (on PVWA 14.6 it fails with "Not a valid Win32 FileTime" for a user with no expiry
    # date). Wait for the job, and on a failed job use the same PUT fallback (F100).
    if ($response.IsSuccess) {
        $bulkId = 0L
        if ($null -ne $response.Data -and [long]::TryParse("$($response.Data)", [ref]$bulkId)) {
            $job = Wait-CyberArkBulkAction -Token $Token -BulkId "$bulkId"
            if ($job.Completed -and -not $job.Succeeded) {
                Write-CyberArkLog -Level 'WARN' -Message "Bulk job $bulkId failed: $($job.ErrorMessage.TrimEnd('.')). Falling back to PUT $userPath with allowedAuthenticationMethods."
                $fallback = $true
            } elseif (-not $job.Completed) {
                & $addError "Allowed authentication method update for UserID '$userId' was not confirmed: $($job.ErrorMessage)" $null $job.StatusCode
                return $result
            }
        } else {
            Write-CyberArkLog -Level 'WARN' -Message "PATCH $endpoint returned no bulk job ID; the change could not be confirmed."
        }
    }

    if ($fallback) {
        $getResp = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint $userPath -PageSize 0
        if (-not $getResp.IsSuccess) {
            & $addError "Allowed authentication method update failed: could not read UserID '$userId' (HTTP $($getResp.StatusCode)): $($getResp.ErrorMessage)" $getResp.ErrorDetails $getResp.StatusCode
            return $result
        }
        [string[]]$current = @(if ($getResp.Data -and $getResp.Data.PSObject.Properties['allowedAuthenticationMethods'] -and
                                   $null -ne $getResp.Data.allowedAuthenticationMethods) {
            @($getResp.Data.allowedAuthenticationMethods) | ForEach-Object { "$_" }
        })
        $newList = [System.Collections.Generic.List[string]]::new()
        if ($adding) {
            foreach ($m in $current) { $newList.Add($m) }
            foreach ($m in $methods) { if (@($newList | Where-Object { $_ -eq $m }).Count -eq 0) { $newList.Add($m) } }
        } else {
            foreach ($m in $current) { if (@($methods | Where-Object { $_ -eq $m }).Count -eq 0) { $newList.Add($m) } }
        }
        $putBody  = ConvertTo-CyberArkUserPutBody -User $getResp.Data -Changes @{ allowedAuthenticationMethods = [string[]]$newList.ToArray() }
        $response = Invoke-CyberArkAPI -Token $Token -Method 'PUT' -Endpoint $userPath -Body $putBody
        if ((-not $userName) -and $getResp.Data -and $getResp.Data.PSObject.Properties['username']) { $userName = "$($getResp.Data.username)" }

        # PVWA can answer 200 and still leave a method out of the saved list (seen live with a
        # method that was disabled at the time), so compare the list the PUT response returns.
        if ($response.IsSuccess -and $response.Data -and $response.Data.PSObject.Properties['allowedAuthenticationMethods']) {
            [string[]]$saved = @(@($response.Data.allowedAuthenticationMethods) | Where-Object { $null -ne $_ } | ForEach-Object { "$_" })
            [string[]]$wrong = @(if ($adding) { $methods | Where-Object { $saved -notcontains $_ } } else { $methods | Where-Object { $saved -contains $_ } })
            if ($wrong.Count -gt 0) {
                $state = if ($adding) { 'missing from' } else { 'still in' }
                & $addError "PUT $userPath returned success, but '$($wrong -join ';')' is $state the saved list [$($saved -join ';')]. Check that the method exists and is enabled in the PVWA." $null
                return $result
            }
        }
    }

    if (-not $response.IsSuccess) {
        & $addError "Allowed authentication method update failed for UserID '$userId' (HTTP $($response.StatusCode)): $($response.ErrorMessage)" $response.ErrorDetails $response.StatusCode
        return $result
    }

    $result.Results.Add([PSCustomObject]@{ UserID = $userId; Username = $userName; AuthMethods = $methodList; Updated = $true })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Allowed authentication method $($verb.ToLower()) complete for UserID '$userId'."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
