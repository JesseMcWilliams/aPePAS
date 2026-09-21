#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Delete Account'
    Category         = 'Accounts'
    Action           = 'Delete'
    Description      = 'Permanently delete an account from CyberArk.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountName'; Required = $true;  Description = 'Account name or username. Matched locally against name and userName fields within the specified Safe.' }
        @{ Column = 'Safe';        Required = $true;  Description = 'Safe containing the account.' }
    )
    Priority         = 34
    Version          = '1.1.0'
}

function Get-AccountsDeleteInput {
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

    Write-Host '  Account to Delete' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  WARNING: This operation permanently deletes the account and cannot be undone.' -ForegroundColor Red
    Write-Host ''

    $accountId = Show-FieldPrompt -Label 'Account ID' `
        -Default $(if ($Defaults['AccountID']) { $Defaults['AccountID'] } else { '' }) `
        -Description 'Account ID to delete, or leave blank to search by name/username/address.'

    if (-not $accountId) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Name, username, or address to find the account.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $accountId = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/Accounts' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'value' `
                -IdProperty 'id' `
                -DisplayProperties @('name', 'userName', 'address', 'safeName') `
                -EntityLabel 'account' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $accountId) { return $null }
    }

    return @{
        AccountID = $accountId
    }
}

function Invoke-AccountsDelete {
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
        $msg = 'InputData is null or missing. AccountName and Safe are required.'
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

    $accountId   = if ($InputData['AccountID'])   { "$($InputData['AccountID'])".Trim()   } else { '' }
    $accountName = if ($InputData['AccountName']) { "$($InputData['AccountName'])".Trim() } else { '' }
    $targetSafe  = if ($InputData['Safe'])        { "$($InputData['Safe'])".Trim()        } else { '' }

    if (-not $accountId) {
        if (-not $accountName) {
            $msg = 'AccountName is required when AccountID is not provided.'
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }
        if (-not $targetSafe) {
            $msg = 'Safe is required to locate the account.'
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        Write-CyberArkLog -Level 'DEBUG' -Message "Fetching accounts in safe '$targetSafe' to locate '$accountName'."

        $lookupResp = Invoke-CyberArkAPI `
            -Token       $Token `
            -Method      'GET' `
            -Endpoint    '/API/Accounts' `
            -QueryParams @{ filter = (New-CyberArkSearchFilter -Criteria @{ safeName = $targetSafe }); limit = 1000 }

        if (-not $lookupResp.IsSuccess) {
            $msg = "Account lookup failed (HTTP $($lookupResp.StatusCode)): $($lookupResp.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $lookupResp.ErrorDetails })
            $result.Failures++
            $result.ItemsProcessed++
            $result.IsFatal = ($lookupResp.StatusCode -in @(401, 0))
            return $result
        }

        [array]$acctList = if ($lookupResp.Data -and
                               $lookupResp.Data.PSObject.Properties['value'] -and
                               $null -ne $lookupResp.Data.value) {
            @($lookupResp.Data.value)
        } else { @() }

        $acctMatch = $acctList | Where-Object {
            $_ -and
            (($_.PSObject.Properties['name']     -and $_.name     -eq $accountName) -or
             ($_.PSObject.Properties['userName'] -and $_.userName -eq $accountName))
        }
        [array]$acctMatches = @($acctMatch)

        if (-not $acctMatches -or $acctMatches.Count -eq 0) {
            $msg = "Account '$accountName' not found in safe '$targetSafe'."
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        if ($acctMatches.Count -gt 1) {
            Write-CyberArkLog -Level 'WARN' -Message "Multiple accounts matched '$accountName' in safe '$targetSafe' - using first match."
        }

        $accountId = if ($acctMatches[0].PSObject.Properties['id']) { $acctMatches[0].id } else { '' }
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

    $encodedId = [Uri]::EscapeDataString($accountId)
    $endpoint  = "/API/Accounts/$encodedId"

    Write-CyberArkLog -Level 'INFO'  -Message "Starting account delete. AccountID='$accountId'."
    Write-CyberArkLog -Level 'DEBUG' -Message "DELETE $endpoint"

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
        -Endpoint $endpoint

    if (-not $response.IsSuccess) {
        $msg = "Account delete failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Success - 204 No Content
    $result.Results.Add([PSCustomObject]@{
        AccountID = $accountId
        Deleted   = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Account delete complete. AccountID='$accountId'."

    Add-CyberArkLogSummaryEntry `
        -ModuleName     $ModuleMeta.Name `
        -ItemsProcessed $result.ItemsProcessed `
        -Successes      $result.Successes `
        -Failures       $result.Failures

    return $result
}
