#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Onboarding Platforms'
    Category         = 'Accounts'
    Action           = 'ListOnboardingPlatforms'
    Description      = 'List the platforms a discovered account of a given type can be onboarded with, in a given safe.'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';              Required = $true; Description = 'Safe the account would be onboarded into.' }
        @{ Column = 'DiscoveryPlatformType'; Required = $true; Description = 'Discovery platform type, as List Discovered Accounts shows it (for example Windows Server Local).' }
    )
    Priority         = 54
    Version          = '1.0.0'
}

function Get-AccountsListOnboardingPlatformsInput {
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

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Description 'Safe the account would be onboarded into.'
    if (-not $safeName) { return $null }

    $type = Show-FieldPrompt -Label 'DiscoveryPlatformType' `
        -Default $(if ($Defaults['DiscoveryPlatformType']) { $Defaults['DiscoveryPlatformType'] } else { '' }) `
        -Description 'For example Windows Server Local, Windows Domain, Unix, Unix SSH Key (the PlatformType column of List Discovered Accounts).'
    if (-not $type) { return $null }

    return @{ SafeName = $safeName; DiscoveryPlatformType = $type }
}

function Invoke-AccountsListOnboardingPlatforms {
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

    $safeName = if ($InputData['SafeName'])              { "$($InputData['SafeName'])".Trim() }              else { '' }
    $type     = if ($InputData['DiscoveryPlatformType']) { "$($InputData['DiscoveryPlatformType'])".Trim() } else { '' }
    if ((-not $safeName) -or (-not $type)) {
        $msg = 'SafeName and DiscoveryPlatformType are both required.'
        Write-CyberArkLog -Level 'ERROR' -Message "Invoke-AccountsListOnboardingPlatforms: $msg"
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Starting onboarding platform list for safe '$safeName', type '$type'."
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/DiscoveredAccounts/Platforms | safeName='$safeName' discoveryPlatformType='$type'"

    # Not a paged collection (14.6 Swagger: only safeName and discoveryPlatformType), so no limit/offset.
    $response = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/DiscoveredAccounts/Platforms' `
        -QueryParams @{ safeName = $safeName; discoveryPlatformType = $type } -PageSize 0

    if (-not $response.IsSuccess) {
        $hint = if ($response.StatusCode -eq 404) { ' (This endpoint is in the PVWA 14.6 API; older versions may not have it.)' } else { '' }
        $msg  = "Onboarding platform list failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)$hint"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $response.ErrorDetails })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        return $result
    }

    [array]$platforms = @(if ($response.Data -and $response.Data.PSObject.Properties['Platforms'] -and $null -ne $response.Data.Platforms) {
        $response.Data.Platforms
    })
    if ((-not $platforms) -or $platforms.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message "No onboarding platforms returned for safe '$safeName', type '$type'."
        return $result
    }

    foreach ($p in $platforms) {
        $get = { param([string]$Name) if ($p.PSObject.Properties[$Name] -and $null -ne $p.$Name) { $p.$Name } else { '' } }
        $result.Results.Add([PSCustomObject]@{
            SafeName                    = $safeName
            DiscoveryPlatformType       = $type
            PlatformID                  = & $get 'platformID'
            PlatformName                = & $get 'platformName'
            IsRecommended               = & $get 'isRecommended'
            IsSSHKeysPlatform           = & $get 'isSSHKeysPlatform'
            IsAutomaticReconcileAllowed = & $get 'isAutomaticReconcileAllowed'
        })
        $result.Successes++
        $result.ItemsProcessed++
    }

    Write-CyberArkLog -Level 'INFO' -Message "Onboarding platform list complete. Platforms: $($result.Successes)."
    return $result
}
