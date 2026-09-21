#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Copy Platform'
    Category         = 'Platforms'
    Action           = 'Copy'
    Description      = 'Duplicate a target platform under a new name, matching psPAS''s Copy-PASPlatform.ps1. Target platforms only.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'PlatformID';  Required = $true;  Description = 'Source target platform ID to duplicate (e.g. WinServerLocal).' }
        @{ Column = 'Name';        Required = $true;  Description = 'Display name for the new platform. Letters, numbers, underscore, hyphen, and spaces only.' }
        @{ Column = 'Description'; Required = $false; Description = 'Description for the new platform.' }
    )
    Priority         = 45
    Version          = '1.0.0'
}

function Get-PlatformsCopyInput {
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

    $platformID = Show-FieldPrompt -Label 'Source Platform ID' `
        -Default $(if ($Defaults['PlatformID']) { $Defaults['PlatformID'] } else { '' }) `
        -Description 'Target platform ID to duplicate (e.g. WinServerLocal), or leave blank to search by name.'

    if (-not $platformID) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Platform name to search for.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            # See Invoke-PlatformsEnable.ps1 for why /API/Platforms (not /API/Platforms/Targets)
            # is used for this interactive search.
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

    $name = Show-FieldPrompt -Label 'New Platform Name' `
        -Default $(if ($Defaults['Name']) { $Defaults['Name'] } else { '' }) `
        -Required $true `
        -Description 'Display name for the new platform.'

    $description = Show-FieldPrompt -Label 'Description' `
        -Default $(if ($Defaults['Description']) { $Defaults['Description'] } else { '' }) `
        -Description 'Description for the new platform.'

    return @{
        PlatformID  = $platformID
        Name        = $name
        Description = $description
    }
}

function Invoke-PlatformsCopy {
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
    $newName    = if ($InputData['Name'])       { "$($InputData['Name'])".Trim()       } else { '' }
    $description = if ($InputData['Description']) { "$($InputData['Description'])".Trim() } else { '' }

    if (-not $platformID) {
        $msg = 'PlatformID is required and must not be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    if (-not $newName) {
        $msg = 'Name is required and must not be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # CyberArk requires the new platform Name to match [a-zA-Z0-9_\- ]+ (confirmed via the
    # DuplicatePlatform schema in the CyberArk 14.6 self-hosted Swagger spec) - validate here
    # so a bad value fails fast with a clear message instead of a late, unclear API error.
    if ($newName -notmatch '^[a-zA-Z0-9_\- ]+$') {
        $msg = "Name '$newName' is invalid. Only letters, numbers, underscore, hyphen, and spaces are allowed."
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

    $endpoint = "/API/Platforms/Targets/$numericId/Duplicate"

    $body = @{ Name = $newName }
    if ($description) { $body['Description'] = $description }

    Write-CyberArkLog -Level 'INFO'  -Message "Starting platform copy from PlatformID='$platformID' (numeric ID $numericId) to Name='$newName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST $endpoint"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST $endpoint would be performed."
        $result.Results.Add([PSCustomObject]@{
            SourcePlatformID = $platformID
            NewName          = $newName
            Copied           = $true
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint $endpoint `
        -Body     $body

    if (-not $response.IsSuccess) {
        $msg = "Platform copy failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Response schema is undocumented ("object") in the CyberArk Swagger spec - read whatever
    # ID-shaped field is present without assuming a specific shape, rather than guessing.
    $newPlatform  = $response.Data
    $newPlatformId = if ($newPlatform -and $newPlatform.PSObject.Properties['PlatformID']) { $newPlatform.PlatformID }
                     elseif ($newPlatform -and $newPlatform.PSObject.Properties['ID'])     { $newPlatform.ID }
                     elseif ($newPlatform -and $newPlatform.PSObject.Properties['id'])     { $newPlatform.id }
                     else { '' }

    $result.Results.Add([PSCustomObject]@{
        SourcePlatformID = $platformID
        NewName          = $newName
        NewPlatformID    = $newPlatformId
        Copied           = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Platform copy complete. New platform: '$newName'$(if ($newPlatformId) { " (ID $newPlatformId)" })."

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
