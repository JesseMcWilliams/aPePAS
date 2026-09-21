#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Disable Platform'
    Category         = 'Platforms'
    Action           = 'Disable'
    Description      = 'Deactivate a target platform, matching psPAS''s Disable-PASPlatform.ps1. Target platforms only.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'PlatformID'; Required = $true; Description = 'Target platform ID (e.g. WinServerLocal).' }
    )
    Priority         = 43
    Version          = '1.0.0'
}

function Get-PlatformsDisableInput {
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

    $platformID = Show-FieldPrompt -Label 'Platform ID' `
        -Default $(if ($Defaults['PlatformID']) { $Defaults['PlatformID'] } else { '' }) `
        -Description 'Target platform ID (e.g. WinServerLocal), or leave blank to search by name.'

    if (-not $platformID) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Platform name to search for.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            # /API/Platforms/Targets also wraps its results under a 'Platforms' property, but
            # its 'search' query param does not reliably match against PlatformID (confirmed
            # live) - search the classic /API/Platforms endpoint instead (same one
            # Invoke-PlatformsGet.ps1 uses), which returns the string PlatformID this function
            # needs. The main Invoke-X function resolves that to the numeric internal ID
            # separately (by fetching /API/Platforms/Targets unfiltered and matching
            # client-side) before the actual API call.
            $platformID = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/Platforms' `
                -SearchTerm $searchTerm `
                -SearchParam 'Search' `
                -ResponseProperty 'Platforms' `
                -IdProperty 'id' `
                -DisplayProperties @('id', 'name', 'description') `
                -EntityLabel 'platform' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $platformID) { return $null }
    }

    return @{
        PlatformID = $platformID
    }
}

function Invoke-PlatformsDisable {
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

    $platformID = if ($InputData['PlatformID']) { "$($InputData['PlatformID'])".Trim() } else { '' }

    if (-not $platformID) {
        $msg = 'PlatformID is required and must not be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # See Invoke-PlatformsEnable.ps1 for why this numeric-ID resolution step is needed.
    Write-CyberArkLog -Level 'DEBUG' -Message "Resolving numeric platform ID for PlatformID '$platformID'."

    $lookupResp = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/API/Platforms/Targets'

    if (-not $lookupResp.IsSuccess) {
        $msg = "Platform lookup failed (HTTP $($lookupResp.StatusCode)): $($lookupResp.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $lookupResp.ErrorDetails })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($lookupResp.StatusCode -in @(401, 0))
        return $result
    }

    # /API/Platforms/Targets wraps its results under a 'Platforms' property - confirmed live
    # against a real tenant, not a bare array as previously assumed. Its 'search' query param
    # also does not reliably match against PlatformID (confirmed live: searching for the exact
    # PlatformID string returned zero results for a platform that does exist) - fetch unfiltered
    # and match client-side by PlatformID instead.
    [array]$candidates = if ($lookupResp.Data -and $lookupResp.Data.PSObject.Properties['Platforms']) {
        @($lookupResp.Data.Platforms)
    } elseif ($lookupResp.Data) {
        @($lookupResp.Data)
    } else {
        @()
    }
    $match = $candidates | Where-Object {
        $_ -and $_.PSObject.Properties['PlatformID'] -and $_.PlatformID -eq $platformID
    } | Select-Object -First 1

    if (-not $match) {
        $msg = "Target platform '$platformID' not found."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $numericId = if ($match.PSObject.Properties['ID']) { $match.ID } else { $null }
    if ($null -eq $numericId) {
        $msg = "Target platform '$platformID' was found but has no numeric ID in the response."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $endpoint = "/API/Platforms/Targets/$numericId/deactivate"

    Write-CyberArkLog -Level 'INFO'  -Message "Starting platform disable for PlatformID='$platformID' (numeric ID $numericId)."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST $endpoint"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST $endpoint would be performed."
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint $endpoint

    if (-not $response.IsSuccess) {
        $msg = "Platform disable failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    $result.Results.Add([PSCustomObject]@{
        PlatformID = $platformID
        ID         = $numericId
        Active     = $false
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Platform disable complete for PlatformID='$platformID'."

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
