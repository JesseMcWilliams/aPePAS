#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Get Platform'
    Category         = 'Platforms'
    Action           = 'Get'
    Description      = 'Retrieve details of a single platform by ID.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'PlatformID'; Required = $true; Description = 'Platform ID (e.g. WinServerLocal).' }
    )
    Priority         = 41
    Version          = '1.1.0'
}

function Get-PlatformsGetInput {
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

    $platformID = Show-FieldPrompt -Label 'Platform ID' `
        -Default $(if ($Defaults['PlatformID']) { $Defaults['PlatformID'] } else { '' }) `
        -Description 'Platform ID (e.g. WinServerLocal), or leave blank to search by name.'

    if (-not $platformID) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Platform name to search for.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
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

function Invoke-PlatformsGet {
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
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-PlatformsGet: PlatformID is required but was not provided.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'PlatformID is required.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.IsFatal = $false
        return $result
    }

    $encodedPlatformID = [Uri]::EscapeDataString($platformID)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting platform retrieval for: $platformID"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Platforms/$encodedPlatformID"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Platforms/$encodedPlatformID" `
        -PageSize 0 `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Platform get failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    $platform = $response.Data

    # Log actual response fields for diagnostics when debugging response shape issues.
    Write-CyberArkLog -Level 'DEBUG' -Message "Platform GET root fields: $($platform.PSObject.Properties.Name -join ', ')"

    # v12+ nests fields inside 'general'; older/Privilege Cloud responses may have fields at root
    # with alternate names (e.g. 'PlatformID' instead of 'id', 'SystemType' instead of 'platformType').
    $gen = if ($platform.PSObject.Properties['general'] -and $platform.general) {
        Write-CyberArkLog -Level 'DEBUG' -Message "Platform GET general fields: $($platform.general.PSObject.Properties.Name -join ', ')"
        $platform.general
    } else { $platform }

    # Collect required and optional account properties defined by this platform
    $reqProps = @()
    $optProps = @()
    if ($platform.PSObject.Properties['properties'] -and $platform.properties) {
        $propsSection = $platform.properties
        if ($propsSection.PSObject.Properties['required'] -and $propsSection.required) {
            foreach ($p in @($propsSection.required)) {
                if ($p.PSObject.Properties['name']) { $reqProps += $p.name }
            }
        }
        if ($propsSection.PSObject.Properties['optional'] -and $propsSection.optional) {
            foreach ($p in @($propsSection.optional)) {
                if ($p.PSObject.Properties['name']) { $optProps += $p.name }
            }
        }
    }

    $result.Results.Add([PSCustomObject]@{
        PlatformID         = if ($gen.PSObject.Properties['id'])                { $gen.id                }
                             elseif ($gen.PSObject.Properties['PlatformID'])    { $gen.PlatformID        }
                             elseif ($platform.PSObject.Properties['id'])       { $platform.id           }
                             elseif ($platform.PSObject.Properties['PlatformID']) { $platform.PlatformID } else { $platformID }
        Name               = if ($gen.PSObject.Properties['name'])              { $gen.name              }
                             elseif ($gen.PSObject.Properties['Name'])          { $gen.Name              }
                             elseif ($platform.PSObject.Properties['name'])     { $platform.name         }
                             elseif ($platform.PSObject.Properties['Name'])     { $platform.Name         } else { '' }
        Description        = if ($gen.PSObject.Properties['description'])       { $gen.description       }
                             elseif ($gen.PSObject.Properties['Description'])   { $gen.Description       }
                             elseif ($platform.PSObject.Properties['description']) { $platform.description }
                             elseif ($platform.PSObject.Properties['Description']) { $platform.Description } else { '' }
        Active             = if ($gen.PSObject.Properties['active'])            { $gen.active            }
                             elseif ($gen.PSObject.Properties['Active'])        { $gen.Active            }
                             elseif ($platform.PSObject.Properties['active'])   { $platform.active       }
                             elseif ($platform.PSObject.Properties['Active'])   { $platform.Active       } else { $false }
        PlatformType       = if ($gen.PSObject.Properties['platformType'])      { $gen.platformType      }
                             elseif ($gen.PSObject.Properties['SystemType'])    { $gen.SystemType        }
                             elseif ($platform.PSObject.Properties['platformType']) { $platform.platformType }
                             elseif ($platform.PSObject.Properties['SystemType']) { $platform.SystemType } else { '' }
        RequiredProperties = $reqProps -join ', '
        OptionalProperties = $optProps -join ', '
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Platform get complete. Platform retrieved: $platformID."
    return $result
}
