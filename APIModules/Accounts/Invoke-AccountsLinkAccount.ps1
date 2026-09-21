#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Link Account'
    Category         = 'Accounts'
    Action           = 'LinkAccount'
    Description      = 'Link an extra credential (reconcile or logon account) to an existing account.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountName';       Required = $true;  Description = 'Account name or username of the target account. Matched locally against the name and userName fields of accounts in the specified Safe.' }
        @{ Column = 'Safe';              Required = $true;  Description = 'Safe containing the target account.' }
        @{ Column = 'ExtraPasswordIndex'; Required = $true; Description = '1 = logon, 2 = enable, 3 = reconcile.' }
        @{ Column = 'LinkName';          Required = $true;  Description = 'Name of the linked account (the credential being attached).' }
        @{ Column = 'LinkSafe';          Required = $true;  Description = 'Safe containing the linked account.' }
        @{ Column = 'LinkFolder';        Required = $false; Description = 'Folder of the linked account (default: Root).' }
    )
    Priority         = 36
    Version          = '1.2.1'
}

function script:Search-LinkedAccount {
    <#
        Prompts the user to search for the linked credential and returns a hashtable
        with LinkName, LinkSafe, and LinkFolder pre-populated from the selected account.
        Returns $null if the user skips the search.
    #>
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [bool]$IgnoreSSL = $false
    )

    $searchTerm = Show-FieldPrompt -Label 'Search Linked Account' `
        -Default '' `
        -Description 'Search by account name, username, or address to find the account to link. Leave blank to enter details manually.'

    if (-not $searchTerm) { return $null }

    $searchResp = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/API/Accounts' `
        -QueryParams @{ search = $searchTerm } `
        -IgnoreSSL:  $IgnoreSSL

    if (-not $searchResp.IsSuccess) {
        Write-Host "  Search failed (HTTP $($searchResp.StatusCode)). Enter details manually." -ForegroundColor Yellow
        return $null
    }

    # Pattern A fix: outer @(...) around the whole if, not just the true branch - an empty
    # else-branch @() would otherwise collapse to $null on capture (PowerShell unrolls a
    # script block's output; zero-length output becomes $null even with [array] typing on
    # the LHS). Currently masked here by the `-not $accounts` short-circuit below, but fixed
    # for consistency with the rest of the codebase's audited defensive pattern.
    [array]$accounts = @(if ($searchResp.Data -and $searchResp.Data.PSObject.Properties['value']) {
        $searchResp.Data.value
    })

    if (-not $accounts -or $accounts.Count -eq 0) {
        Write-Host '  No accounts found. Enter details manually.' -ForegroundColor Yellow
        return $null
    }

    $selected = $null
    if ($accounts.Count -eq 1) {
        $selected = $accounts[0]
        $nm = if ($selected.PSObject.Properties['name'])     { $selected.name }     else { '' }
        $sf = if ($selected.PSObject.Properties['safeName']) { $selected.safeName } else { '' }
        Write-Host "  Found: $nm  (Safe: $sf)" -ForegroundColor Green
    } else {
        Write-Host ''
        Write-Host "  $($accounts.Count) accounts found. Select one:" -ForegroundColor DarkGray
        Write-Host ''
        for ($i = 0; $i -lt $accounts.Count; $i++) {
            $a  = $accounts[$i]
            $nm = if ($a.PSObject.Properties['name'])     { $a.name }     else { '' }
            $un = if ($a.PSObject.Properties['userName']) { $a.userName } else { '' }
            $ad = if ($a.PSObject.Properties['address'])  { $a.address }  else { '' }
            $sf = if ($a.PSObject.Properties['safeName']) { $a.safeName } else { '' }
            Write-Host "    $($i+1)) $nm  [$un @ $ad]  Safe: $sf" -ForegroundColor White
        }
        Write-Host ''
        $choice = Read-Host "  Select (1-$($accounts.Count), or Enter to skip)"
        if ($choice -match '^\d+$') {
            $idx = [int]$choice - 1
            if ($idx -ge 0 -and $idx -lt $accounts.Count) { $selected = $accounts[$idx] }
        }
    }

    if (-not $selected) { return $null }

    return @{
        LinkName   = if ($selected.PSObject.Properties['name'])     { $selected.name }     else { '' }
        LinkSafe   = if ($selected.PSObject.Properties['safeName']) { $selected.safeName } else { '' }
        LinkFolder = 'Root'
    }
}

function Get-AccountsLinkAccountInput {
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

    # ── Target account (the account being linked TO) ──────────────────────────
    Write-Host '  Target Account  (the account that will have a linked credential)' -ForegroundColor DarkGray
    Write-Host ''

    $accountID = Show-FieldPrompt -Label 'Account ID' `
        -Default $(if ($Defaults['AccountID']) { $Defaults['AccountID'] } else { '' }) `
        -Description 'Account ID, or leave blank to search.'

    if (-not $accountID) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Name, username, or address to find the target account.'
        if ($searchTerm) {
            $accountID = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/Accounts' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'value' `
                -IdProperty 'id' `
                -DisplayProperties @('name', 'userName', 'address', 'safeName') `
                -EntityLabel 'account' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $accountID) { return $null }
    }

    # ── Link type ────────────────────────────────────────────────────────────
    Write-Host ''
    Write-Host '  Link Type:' -ForegroundColor DarkGray
    Write-Host '    1 = Logon Account   (ExtraPasswordIndex 1)'
    Write-Host '    2 = Enable Account  (ExtraPasswordIndex 2)'
    Write-Host '    3 = Reconcile       (ExtraPasswordIndex 3)'
    Write-Host ''

    $defaultIdx = if ($Defaults['ExtraPasswordIndex']) { $Defaults['ExtraPasswordIndex'] } else { '1' }
    $idxChoice  = Read-Host "  Select link type (1-3, default=$defaultIdx)"
    $extraPasswordIndex = switch ($idxChoice) {
        '1' { 1 }
        '2' { 2 }
        '3' { 3 }
        default { if ($defaultIdx -match '^[123]$') { [int]$defaultIdx } else { 1 } }
    }

    # ── Linked account search ─────────────────────────────────────────────────
    Write-Host ''
    Write-Host '  Linked Account  (the credential being attached)' -ForegroundColor DarkGray
    Write-Host ''

    $linkedDefaults = script:Search-LinkedAccount -Token $Token -IgnoreSSL $ignoreSSL

    $defaultLinkName   = if ($linkedDefaults -and $linkedDefaults['LinkName'])   { $linkedDefaults['LinkName']   }
                         elseif ($Defaults['LinkName'])                           { $Defaults['LinkName']         }
                         else { '' }
    $defaultLinkSafe   = if ($linkedDefaults -and $linkedDefaults['LinkSafe'])   { $linkedDefaults['LinkSafe']   }
                         elseif ($Defaults['LinkSafe'])                           { $Defaults['LinkSafe']         }
                         else { '' }
    $defaultLinkFolder = if ($linkedDefaults -and $linkedDefaults['LinkFolder']) { $linkedDefaults['LinkFolder'] }
                         elseif ($Defaults['LinkFolder'])                         { $Defaults['LinkFolder']       }
                         else { 'Root' }

    $linkName = Show-FieldPrompt -Label 'LinkName' `
        -Default $defaultLinkName `
        -Required $true `
        -Description 'Name of the linked account (auto-populated if found by search).'

    $linkSafe = Show-FieldPrompt -Label 'LinkSafe' `
        -Default $defaultLinkSafe `
        -Required $true `
        -Description 'Safe containing the linked account (auto-populated if found by search).'

    $linkFolder = Show-FieldPrompt -Label 'LinkFolder' `
        -Default $defaultLinkFolder `
        -Description 'Folder within the safe (default: Root).'

    return @{
        AccountID          = $accountID
        ExtraPasswordIndex = $extraPasswordIndex
        LinkName           = $linkName
        LinkSafe           = $linkSafe
        LinkFolder         = $linkFolder
    }
}

function Invoke-AccountsLinkAccount {
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

    # ── Resolve target account ID ─────────────────────────────────────────────
    $accountId   = if ($InputData['AccountID']) { "$($InputData['AccountID'])".Trim() } else { '' }
    $accountName = if ($InputData['AccountName']) { "$($InputData['AccountName'])".Trim() } else { '' }
    $targetSafe  = if ($InputData['Safe']) { "$($InputData['Safe'])".Trim() } else { '' }

    if (-not $accountId) {
        # CSV path: look up the account ID from AccountName + Safe
        if (-not $accountName) {
            $msg = 'AccountName is required when AccountID is not provided.'
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }
        if (-not $targetSafe) {
            $msg = 'Safe is required to locate the target account.'
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        Write-CyberArkLog -Level 'DEBUG' -Message "Fetching accounts in safe '$targetSafe' to locate '$accountName'."

        # Filter server-side by safe only; match name/userName locally to avoid OData search encoding issues
        $searchResp = Invoke-CyberArkAPI `
            -Token       $Token `
            -Method      'GET' `
            -Endpoint    '/API/Accounts' `
            -QueryParams @{ filter = (New-CyberArkSearchFilter -Criteria @{ safeName = $targetSafe }); limit = 1000 }

        if (-not $searchResp.IsSuccess) {
            $msg = "Account lookup failed (HTTP $($searchResp.StatusCode)): $($searchResp.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $searchResp.ErrorDetails })
            $result.Failures++
            $result.ItemsProcessed++
            $result.IsFatal = ($searchResp.StatusCode -in @(401, 0))
            return $result
        }

        # Pattern A fix: outer @(...) around the whole if, not just the true branch - an empty
        # else-branch @() would otherwise collapse to $null on capture (PowerShell unrolls a
        # script block's output; zero-length output becomes $null even with [array] typing on
        # the LHS), and the `| Where-Object` below would then be piping from a bare $null.
        # Currently harmless since PowerShell handles $null | Where-Object gracefully, but
        # fixed for consistency with the rest of the codebase's audited defensive pattern.
        [array]$accounts = @(if ($searchResp.Data -and
                               $searchResp.Data.PSObject.Properties['value'] -and
                               $null -ne $searchResp.Data.value) {
            $searchResp.Data.value
        })

        # Match locally against name OR userName; $_ guard prevents null-PSObject crash under strict mode
        $match = $accounts | Where-Object {
            $_ -and
            (
                ($_.PSObject.Properties['name']     -and $_.name     -eq $accountName) -or
                ($_.PSObject.Properties['userName'] -and $_.userName -eq $accountName)
            )
        }
        [array]$matches = @($match)

        if (-not $matches -or $matches.Count -eq 0) {
            $msg = "Account '$accountName' not found in safe '$targetSafe'."
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        if ($matches.Count -gt 1) {
            Write-CyberArkLog -Level 'WARN' -Message "Multiple accounts named '$accountName' found in safe '$targetSafe' - using first match."
        }

        $accountId = if ($matches[0].PSObject.Properties['id']) { $matches[0].id } else { '' }
        if (-not $accountId) {
            $msg = "Account '$accountName' found in safe '$targetSafe' but has no ID."
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        Write-CyberArkLog -Level 'DEBUG' -Message "Resolved account ID: $accountId"
    }

    # ── Validate ExtraPasswordIndex ───────────────────────────────────────────
    $extraPasswordIndex = 0
    try { $extraPasswordIndex = [int]"$($InputData['ExtraPasswordIndex'])".Trim() } catch {}
    if ($extraPasswordIndex -lt 1) {
        $msg = 'ExtraPasswordIndex is required and must be a positive integer (1=logon, 2=enable, 3=reconcile).'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # ── Linked account fields ─────────────────────────────────────────────────
    $linkName = if ($InputData['LinkName']) { "$($InputData['LinkName'])".Trim() } else { '' }
    if (-not $linkName) {
        $msg = 'LinkName is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $linkSafe = if ($InputData['LinkSafe']) { "$($InputData['LinkSafe'])".Trim() } else { '' }
    if (-not $linkSafe) {
        $msg = 'LinkSafe is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $linkFolder = if ($InputData['LinkFolder']) { "$($InputData['LinkFolder'])".Trim() } else { 'Root' }

    $encodedId = [Uri]::EscapeDataString($accountId)

    Write-CyberArkLog -Level 'INFO'  -Message "Linking '$linkName' (index $extraPasswordIndex) to account ID $accountId."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /API/Accounts/$accountId/LinkAccount | linkName='$linkName' linkSafe='$linkSafe' linkFolder='$linkFolder'"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: would POST /API/Accounts/$accountId/LinkAccount."
        $result.Results.Add([PSCustomObject]@{
            AccountID          = $accountId
            AccountName        = $accountName
            Safe               = $targetSafe
            ExtraPasswordIndex = $extraPasswordIndex
            LinkName           = $linkName
            LinkSafe           = $linkSafe
            LinkFolder         = $linkFolder
            Status             = 'WhatIf'
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $body = @{
        extraPasswordIndex = $extraPasswordIndex
        name               = $linkName
        folder             = $linkFolder
        safe               = $linkSafe
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint "/API/Accounts/$encodedId/LinkAccount" `
        -Body     $body `
        -WhatIf:  $false

    if (-not $response.IsSuccess) {
        $msg = "Link Account failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    $result.Results.Add([PSCustomObject]@{
        AccountID          = $accountId
        AccountName        = $accountName
        Safe               = $targetSafe
        ExtraPasswordIndex = $extraPasswordIndex
        LinkName           = $linkName
        LinkSafe           = $linkSafe
        LinkFolder         = $linkFolder
        Status             = 'Linked'
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Link Account complete for account ID: $accountId."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
