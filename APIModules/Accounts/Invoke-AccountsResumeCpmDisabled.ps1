#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Resume CPM-Disabled Accounts'
    Category         = 'Accounts'
    MenuGroup        = 'CPM tasks'
    Action           = 'ResumeCpmDisabled'
    Description      = 'Resume automatic management on every account the CPM disabled, narrowed by safe, platform or search. Accounts a user disabled are never touched.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'Safe';       Required = $false; Description = 'Only accounts in this safe (exact name). Blank = all safes.' }
        @{ Column = 'PlatformID'; Required = $false; Description = 'Only accounts on this platform ID (exact, any case). Blank = all platforms.' }
        @{ Column = 'Search';     Required = $false; Description = 'Only accounts matching this search text (the API''s search: name, username, address).' }
        @{ Column = 'Confirm';    Required = $false; Description = 'Must be Yes to resume (automation). Not needed with -WhatIf, which lists the accounts only.' }
    )
    Priority         = 58
    Version          = '1.0.0'
}

# Feature item 9. The list always uses savedFilter=DisabledPasswordByCPM, so an account a user
# disabled is never selected (decision Q4). Safe and Search go to the API; PlatformID is matched
# here, because the 14.6 Swagger documents no platformId filter for GET /API/Accounts. Each account
# is resumed on its own with Invoke-CyberArkAccountResume (CyberArkComms.psm1): the bulk
# /API/Accounts/Resume/Bulk endpoint is Self-Hosted 15.2+ only.
function script:Get-CpmDisabledAccountList {
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$Token,
        [string]$Safe       = '',
        [string]$PlatformID = '',
        [string]$Search     = ''
    )

    $query = @{ savedFilter = 'DisabledPasswordByCPM' }
    if ($Safe)   { $query['filter'] = (New-CyberArkSearchFilter -Criteria @{ safeName = $Safe }) }
    if ($Search) { $query['search'] = $Search }

    $resp = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/Accounts' -QueryParams $query
    $out  = [PSCustomObject]@{ Response = $resp; Accounts = @() }
    if (-not $resp.IsSuccess) { return $out }

    [array]$all = @(if ($resp.Data -and $resp.Data.PSObject.Properties['value'] -and $null -ne $resp.Data.value) { $resp.Data.value })
    $out.Accounts = @($all | Where-Object {
        $_ -and $_.PSObject.Properties['id'] -and $_.id -and
        ((-not $PlatformID) -or ($_.PSObject.Properties['platformId'] -and "$($_.platformId)" -ieq $PlatformID))
    })
    return $out
}

function script:ConvertTo-CpmDisabledRow {
    param([object]$Account, [string]$Status, [string]$Detail = '')
    $read = { param($o, $n) if ($o -and $o.PSObject.Properties[$n] -and $null -ne $o.$n) { "$($o.$n)" } else { '' } }
    $sm   = if ($Account.PSObject.Properties['secretManagement']) { $Account.secretManagement } else { $null }
    return [PSCustomObject]@{
        AccountID    = & $read $Account 'id'
        AccountName  = & $read $Account 'name'
        UserName     = & $read $Account 'userName'
        Address      = & $read $Account 'address'
        SafeName     = & $read $Account 'safeName'
        PlatformID   = & $read $Account 'platformId'
        ManualReason = & $read $sm 'manualManagementReason'
        Status       = $Status
        Detail       = $Detail
    }
}

function Get-AccountsResumeCpmDisabledInput {
    <#
        Called by the driver when HasCustomInput = $true. Lists the matching accounts and asks for
        confirmation, so the user sees exactly what will be resumed. Returns $null to cancel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Resume CPM-Disabled Accounts  (press Enter to skip a filter)' -ForegroundColor DarkGray
    Write-Host '  Only accounts the CPM disabled are selected; accounts a user disabled are never touched.' -ForegroundColor DarkGray
    Write-Host ''

    $safe = Show-FieldPrompt -Label 'Safe' `
        -Default $(if ($Defaults['Safe']) { $Defaults['Safe'] } else { '' }) `
        -Description 'Only accounts in this safe (exact name). Blank = all safes.'
    $platformID = Show-FieldPrompt -Label 'Platform ID' `
        -Default $(if ($Defaults['PlatformID']) { $Defaults['PlatformID'] } else { '' }) `
        -Description 'Only accounts on this platform ID. Blank = all platforms.'
    $search = Show-FieldPrompt -Label 'Search' `
        -Default $(if ($Defaults['Search']) { $Defaults['Search'] } else { '' }) `
        -Description 'Only accounts matching this search text (name, username, address).'

    $list = script:Get-CpmDisabledAccountList -Token $Token -Safe $safe -PlatformID $platformID -Search $search
    if (-not $list.Response.IsSuccess) {
        Write-Host "  Account list failed (HTTP $($list.Response.StatusCode)): $($list.Response.ErrorMessage)" -ForegroundColor Red
        return $null
    }
    [array]$accounts = @($list.Accounts)
    if ($accounts.Count -eq 0) {
        Write-Host '  No CPM-disabled accounts match.' -ForegroundColor Yellow
        return $null
    }

    Write-Host ''
    Write-Host "  $($accounts.Count) CPM-disabled account(s):" -ForegroundColor White
    foreach ($a in $accounts) {
        $row = script:ConvertTo-CpmDisabledRow -Account $a -Status ''
        Write-Host ("    {0,-8} {1,-24} {2,-20} {3}" -f $row.AccountID, $row.SafeName, $row.PlatformID, $row.AccountName)
    }

    # The driver's WhatIf toggle; read without a strict-mode error when the variable isn't set.
    $whatIfOn = ((Get-Variable -Name 'WhatIfMode' -Scope Script -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
    if (-not $whatIfOn -and -not (Confirm-Action -Message "Resume automatic management on these $($accounts.Count) account(s)?")) {
        Write-Host '  Cancelled.' -ForegroundColor DarkGray
        return $null
    }

    return @{
        Safe       = $safe
        PlatformID = $platformID
        Search     = $search
        Confirm    = $(if ($whatIfOn) { '' } else { 'Yes' })
    }
}

function Invoke-AccountsResumeCpmDisabled {
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
    $readText = { param($k) if ($InputData.ContainsKey($k) -and $null -ne $InputData[$k]) { "$($InputData[$k])".Trim() } else { '' } }
    $safe       = & $readText 'Safe'
    $platformID = & $readText 'PlatformID'
    $search     = & $readText 'Search'
    $confirmed  = ((& $readText 'Confirm') -match '^(true|yes|y|1)$')

    $criteria = @()
    if ($safe)       { $criteria += "Safe='$safe'" }
    if ($platformID) { $criteria += "PlatformID='$platformID'" }
    if ($search)     { $criteria += "Search='$search'" }
    $criteriaText = if ($criteria) { $criteria -join '  ' } else { '(all safes and platforms)' }

    Write-CyberArkLog -Level 'INFO'  -Message "Starting resume of CPM-disabled accounts. $criteriaText"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Accounts savedFilter=DisabledPasswordByCPM | $criteriaText"

    # The list is read-only, so it also runs under WhatIf: that is how WhatIf shows the accounts.
    $list = script:Get-CpmDisabledAccountList -Token $Token -Safe $safe -PlatformID $platformID -Search $search
    if (-not $list.Response.IsSuccess) {
        $msg = "CPM-disabled account list failed (HTTP $($list.Response.StatusCode)): $($list.Response.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $list.Response.ErrorDetails })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($list.Response.StatusCode -in @(401, 0))
        return $result
    }

    [array]$accounts = @($list.Accounts)
    Write-CyberArkLog -Level 'INFO' -Message "$($accounts.Count) CPM-disabled account(s) match."
    if ($accounts.Count -eq 0) { return $result }

    if ($WhatIf.IsPresent) {
        foreach ($a in $accounts) {
            $plan = Invoke-CyberArkAccountResume -Token $Token -AccountId "$($a.id)" -WhatIf
            Write-CyberArkLog -Level 'INFO' -Message "WhatIf: $($plan.Method) $($plan.Endpoint) would resume account '$($a.id)'."
            $result.Results.Add((script:ConvertTo-CpmDisabledRow -Account $a -Status 'WouldResume'))
            $result.Successes++
            $result.ItemsProcessed++
        }
        return $result
    }

    if (-not $confirmed) {
        $msg = "$($accounts.Count) CPM-disabled account(s) match, but Confirm is not Yes, so none were resumed. Run with -WhatIf to list them, then set Confirm to Yes."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $fallbackLogged = $false
    foreach ($a in $accounts) {
        $id     = "$($a.id)"
        $resume = Invoke-CyberArkAccountResume -Token $Token -AccountId $id
        $resp   = $resume.Response
        $result.ItemsProcessed++

        if ($resume.FellBack -and -not $fallbackLogged) {
            Write-CyberArkLog -Level 'WARN' -Message "POST /Resume/ returned 404 - using PATCH automaticManagementEnabled (PVWA likely older than 15.2)."
            $fallbackLogged = $true
        }

        if ($resp.IsSuccess) {
            Write-CyberArkLog -Level 'INFO' -Message "Resumed automatic management for account '$id' ($($resume.Method) $($resume.Endpoint))."
            $result.Results.Add((script:ConvertTo-CpmDisabledRow -Account $a -Status 'Resumed'))
            $result.Successes++
            continue
        }

        $msg = "Resume failed for account '$id' (HTTP $($resp.StatusCode)): $($resp.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Results.Add((script:ConvertTo-CpmDisabledRow -Account $a -Status 'Failed' -Detail "$($resp.ErrorMessage)"))
        $result.Errors.Add([PSCustomObject]@{ InputData = @{ AccountID = $id }; ErrorMessage = $resp.ErrorMessage; ErrorDetails = $resp.ErrorDetails })
        $result.Failures++
        if ($resp.StatusCode -in @(401, 0)) {
            $result.IsFatal = $true
            Write-CyberArkLog -Level 'ERROR' -Message 'Stopping: the session is no longer valid.'
            break
        }
    }

    Write-CyberArkLog -Level 'INFO' -Message "Resume of CPM-disabled accounts complete: $($result.Successes) resumed, $($result.Failures) failed."
    return $result
}
