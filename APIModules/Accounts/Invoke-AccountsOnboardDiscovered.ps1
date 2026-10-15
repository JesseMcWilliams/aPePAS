#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Onboard Discovered Account'
    Category         = 'Accounts'
    MenuGroup        = 'Discovered accounts'
    Action           = 'OnboardDiscovered'
    Description      = 'Onboard a Pending (discovered) account into a safe with a platform.'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'DiscoveredAccountID';      Required = $true;  Description = 'ID of the pending account (from List Discovered Accounts).' }
        @{ Column = 'SafeName';                 Required = $true;  Description = 'Safe to onboard the account into.' }
        @{ Column = 'PlatformID';               Required = $true;  Description = 'Platform ID to assign (List Onboarding Platforms shows the valid ones for a safe).' }
        @{ Column = 'ShouldReconcileAccount';   Required = $false; Description = 'true/false: reconcile the account after onboarding.' }
        @{ Column = 'DefaultPassword';          Required = $false; Description = 'Password to store when the account is onboarded. A 14.6 PVWA fails the onboard (DAFWS005E) without one. Never logged; masked as *** in the results file.' }
        @{ Column = 'AllowAccountDuplications'; Required = $false; Description = 'true/false: allow onboarding when the same account already exists in the Vault.' }
    )
    Priority         = 52
    Version          = '1.1.0'
}

function Get-AccountsOnboardDiscoveredInput {
    <#
        Called by the driver when HasCustomInput = $true.
        Show-FieldPrompt and Invoke-EntitySearch are available because this module is dot-sourced into the driver scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }
    $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }

    $id = Show-FieldPrompt -Label 'Discovered Account ID' `
        -Default $(if ($Defaults['DiscoveredAccountID']) { $Defaults['DiscoveredAccountID'] } else { '' }) `
        -Description 'ID from List Discovered Accounts, or leave blank to search by username or address.'
    if (-not $id) {
        $searchTerm = Show-FieldPrompt -Label 'Search' -Description 'Username or address of the pending account.'
        if ($searchTerm) {
            $id = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/DiscoveredAccounts' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'value' `
                -IdProperty 'id' `
                -DisplayProperties @('userName', 'address', 'platformType') `
                -EntityLabel 'pending account' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $id) { return $null }
    }

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Description 'Safe to onboard the account into.'
    if (-not $safeName) { return $null }

    # Offer the platforms the PVWA says fit this safe and the account's discovery platform type
    # (GET /API/DiscoveredAccounts/Platforms, 14.6 Swagger). Any failure just skips the list.
    $platformID = ''
    try {
        $acctResp = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint "/API/DiscoveredAccounts/$([Uri]::EscapeDataString($id))" -PageSize 0 -IgnoreSSL:$ignoreSSL
        $platformType = if ($acctResp.IsSuccess -and $acctResp.Data -and $acctResp.Data.PSObject.Properties['platformType']) { "$($acctResp.Data.platformType)" } else { '' }
        if ($platformType) {
            $platResp = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/DiscoveredAccounts/Platforms' `
                -QueryParams @{ safeName = $safeName; discoveryPlatformType = $platformType } -PageSize 0 -IgnoreSSL:$ignoreSSL
            [array]$platforms = @(if ($platResp.IsSuccess -and $platResp.Data -and $platResp.Data.PSObject.Properties['Platforms'] -and $platResp.Data.Platforms) { $platResp.Data.Platforms })
            if ($platforms.Count -gt 0) {
                Write-Host ''
                Write-Host "  Platforms for safe '$safeName' and type '$platformType':" -ForegroundColor DarkGray
                for ($i = 0; $i -lt $platforms.Count; $i++) {
                    $p   = $platforms[$i]
                    $tag = if ($p.PSObject.Properties['isRecommended'] -and $p.isRecommended) { '  (recommended)' } else { '' }
                    Write-Host ("    [{0}] {1}  {2}{3}" -f ($i + 1), $p.platformID, $p.platformName, $tag)
                }
                $pick = Show-FieldPrompt -Label 'Platform number' -Description 'Pick a number, or press Enter to type a platform ID.'
                $n = 0
                if ($pick -and [int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $platforms.Count) {
                    $platformID = "$($platforms[$n - 1].platformID)"
                }
            }
        }
    } catch {
        Write-CyberArkLog -Level 'DEBUG' -Message "Onboarding platform list skipped: $_"
    }
    if (-not $platformID) {
        $platformID = Show-FieldPrompt -Label 'PlatformID' `
            -Default $(if ($Defaults['PlatformID']) { $Defaults['PlatformID'] } else { '' }) `
            -Description 'Platform ID to assign to the onboarded account.'
        if (-not $platformID) { return $null }
    }

    $reconcile = Show-FieldPrompt -Label 'ShouldReconcileAccount' `
        -Default $(if ($Defaults['ShouldReconcileAccount']) { $Defaults['ShouldReconcileAccount'] } else { '' }) `
        -Description 'true/false. Leave blank for the PVWA default.'
    $password = Show-FieldPrompt -Label 'DefaultPassword' -IsSecret `
        -Description 'Password to store with the account. A 14.6 PVWA fails the onboard (DAFWS005E) without one.'
    $allowDup = Show-FieldPrompt -Label 'AllowAccountDuplications' `
        -Default $(if ($Defaults['AllowAccountDuplications']) { $Defaults['AllowAccountDuplications'] } else { '' }) `
        -Description 'true/false. Leave blank for the PVWA default (no duplicates).'

    return @{
        DiscoveredAccountID      = $id
        SafeName                 = $safeName
        PlatformID               = $platformID
        ShouldReconcileAccount   = $reconcile
        DefaultPassword          = $password
        AllowAccountDuplications = $allowDup
    }
}

function Invoke-AccountsOnboardDiscovered {
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

    $addError = {
        param([string]$Message, $Details, [int]$StatusCode = -1)
        Write-CyberArkLog -Level 'ERROR' -Message $Message
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $Message; ErrorDetails = $Details })
        $result.Failures++
        $result.ItemsProcessed++
        if ($StatusCode -in @(401, 0)) { $result.IsFatal = $true }
    }
    $read = { param([string]$Key) if ($InputData[$Key]) { "$($InputData[$Key])".Trim() } else { '' } }

    $id         = & $read 'DiscoveredAccountID'
    $safeName   = & $read 'SafeName'
    $platformID = & $read 'PlatformID'
    $missing = @(foreach ($pair in @(@('DiscoveredAccountID', $id), @('SafeName', $safeName), @('PlatformID', $platformID))) { if (-not $pair[1]) { $pair[0] } })
    if ($missing.Count -gt 0) {
        & $addError "Required field(s) missing: $($missing -join ', ')." $null
        return $result
    }

    $body = @{ platformId = $platformID; safeName = $safeName }
    $query = @{}
    foreach ($pair in @(@('ShouldReconcileAccount', 'body'), @('AllowAccountDuplications', 'query'))) {
        $value = & $read $pair[0]
        if (-not $value) { continue }
        if ($value -notmatch '^(?i)(true|false)$') {
            & $addError "$($pair[0]) must be true or false (got '$value')." $null
            return $result
        }
        if ($pair[1] -eq 'body') { $body['shouldReconcileAccount'] = ($value -eq 'true') }
        else                     { $query['allowAccountDuplications'] = $value.ToLower() }
    }
    # The password is passed through as given (not trimmed). Invoke-CyberArkAPI's DEBUG body log
    # masks any JSON key containing "password", and it is never written anywhere else.
    if ($InputData['DefaultPassword']) { $body['defaultPassword'] = "$($InputData['DefaultPassword'])" }

    $endpoint = "/API/DiscoveredAccounts/$([Uri]::EscapeDataString($id))/Onboard"
    Write-CyberArkLog -Level 'INFO'  -Message "Starting onboarding of discovered account ID $id into safe '$safeName' with platform '$platformID'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST $endpoint"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST $endpoint would be performed."
        $result.Results.Add([PSCustomObject]@{ DiscoveredAccountID = $id; SafeName = $safeName; PlatformID = $platformID; AccountID = ''; Status = 'WhatIf' })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $apiParams = @{ Token = $Token; Method = 'POST'; Endpoint = $endpoint; Body = $body }
    if ($query.Count -gt 0) { $apiParams['QueryParams'] = $query }
    $response = Invoke-CyberArkAPI @apiParams

    if (-not $response.IsSuccess) {
        # DAFWS005E is the PVWA's generic onboard failure. Confirmed live (14.6 lab, 2026-10-14): with
        # no defaultPassword the PVWA hits a NullReferenceException in its password handling and
        # returns only this code (Reference_Lessons-Learned-CyberArk-API.md §26).
        $errCode = if ($response.ErrorDetails -and $response.ErrorDetails.PSObject.Properties['ErrorCode']) { "$($response.ErrorDetails.ErrorCode)" } else { '' }
        $hint = if ($response.StatusCode -eq 404) { ' (If the ID is right, the PVWA may be older than 12.6, which added onboarding from the Pending list.)' }
                elseif ($errCode -eq 'DAFWS005E' -and -not $InputData['DefaultPassword']) { ' (No DefaultPassword was given: this PVWA may need one to onboard a discovered account.)' }
                else { '' }
        & $addError "Onboard failed for discovered account ID $id (HTTP $($response.StatusCode)): $($response.ErrorMessage)$hint" $response.ErrorDetails $response.StatusCode
        return $result
    }

    # The 14.6 Swagger declares the 200 response only as an object; show the new account ID when
    # the PVWA returns one.
    $newId = if ($response.Data -and $response.Data.PSObject -and $response.Data.PSObject.Properties['id']) { "$($response.Data.id)" } else { '' }
    $result.Results.Add([PSCustomObject]@{
        DiscoveredAccountID = $id
        SafeName            = $safeName
        PlatformID          = $platformID
        AccountID           = $newId
        Status              = 'Onboarded'
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Onboard complete for discovered account ID $id."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
