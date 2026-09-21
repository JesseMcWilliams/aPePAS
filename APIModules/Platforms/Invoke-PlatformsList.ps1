#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Platforms'
    Category         = 'Platforms'
    Action           = 'List'
    Description      = 'Retrieve all available CyberArk platforms.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SystemType'; Required = $false; Description = 'Filter by system type (e.g. Windows, Unix). Leave blank for all system types.' }
    )
    Priority         = 40
    Version          = '1.1.0'
}

function Get-PlatformsListInput {
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

    Write-Host '  Search Criteria  (press Enter to skip each field)' -ForegroundColor DarkGray
    Write-Host ''

    $search = Show-FieldPrompt -Label 'Search' `
        -Default $(if ($Defaults['Search']) { $Defaults['Search'] } else { '' }) `
        -Description 'Free-text search across platform name and description. Leave blank for all platforms.'

    $activeOnlyStr = Show-FieldPrompt -Label 'Active Only' `
        -Default $(if ($Defaults['ActiveOnly']) { 'Y' } else { 'N' }) `
        -Description 'Return only active platforms? (Y/N)'

    $systemType = Show-FieldPrompt -Label 'System Type' `
        -Default $(if ($Defaults['SystemType']) { $Defaults['SystemType'] } else { '' }) `
        -Description 'Filter by system type (e.g. Windows, Unix). Leave blank for all.'

    return @{
        Search     = $search
        ActiveOnly = ($activeOnlyStr -match '^[Yy]$')
        SystemType = $systemType
    }
}

function Invoke-PlatformsList {
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

    $search     = if ($InputData['Search'])     { "$($InputData['Search'])".Trim() } else { $null }
    # [bool]$x on a CSV string casts ANY non-empty string to $true, including the literal text
    # "false"/"no"/"0" - only a truly empty string casts to $false. Match against known truthy
    # tokens instead (also handles a real interactive-mode [bool] input, since PowerShell
    # stringifies $true/$false to "True"/"False").
    $activeOnly = "$($InputData['ActiveOnly'])".Trim() -match '(?i)^(true|yes|y|1)$'
    $systemType = if ($InputData['SystemType']) { "$($InputData['SystemType'])".Trim() } else { $null }

    # Build query parameters - only include keys that have a value
    $queryParams = @{}
    if ($search)     { $queryParams['Search']     = $search     }
    if ($activeOnly) { $queryParams['Active']     = 'true'      }
    if ($systemType) { $queryParams['SystemType'] = $systemType }

    $criteriaLog = $(
        $parts = @()
        if ($search)     { $parts += "Search='$search'" }
        if ($activeOnly) { $parts += 'Active=true' }
        if ($systemType) { $parts += "SystemType='$systemType'" }
        if ($parts)      { $parts -join '  ' } else { '(all platforms)' }
    )

    Write-CyberArkLog -Level 'INFO'  -Message 'Starting platform list retrieval.'
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Platforms | $criteriaLog"

    $response = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/API/Platforms' `
        -QueryParams $queryParams `
        -WhatIf:     $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Platform list failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Platforms API uses 'Platforms' property, not 'value'
    [array]$platforms = if ($response.Data -and $response.Data.PSObject.Properties['Platforms']) {
        @($response.Data.Platforms)
    } else { @() }

    if ((-not $platforms) -or $platforms.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message 'No platforms returned for the given criteria.'
        # Not a failure - a valid empty result
        return $result
    }

    foreach ($platform in $platforms) {
        try {
            # CyberArk v12+ nests platform detail inside 'general'; fall back to root for either shape.
            # Field-name fallback mirrors Invoke-PlatformsGet.ps1 (both id/PlatformID and
            # platformType/SystemType variants, at both the general sub-object and root level) -
            # see Lessons-Learned-PowerShell-Pester.md Section 12 for the documented PVWA-version
            # field-name differences. This file previously only checked id/platformType, so a
            # PVWA version/response shape using PlatformID/SystemType returned blank PlatformID
            # and PlatformType for every row here while Get Platform (for the same platform)
            # worked correctly - an asymmetric fix that was never applied to this sibling module.
            $gen = if ($platform.PSObject.Properties['general'] -and $platform.general) { $platform.general } else { $platform }
            $result.Results.Add([PSCustomObject]@{
                PlatformID   = if ($gen.PSObject.Properties['id'])                   { $gen.id                }
                               elseif ($gen.PSObject.Properties['PlatformID'])       { $gen.PlatformID        }
                               elseif ($platform.PSObject.Properties['id'])          { $platform.id           }
                               elseif ($platform.PSObject.Properties['PlatformID']) { $platform.PlatformID   } else { '' }
                Name         = if ($gen.PSObject.Properties['name'])                 { $gen.name              }
                               elseif ($gen.PSObject.Properties['Name'])             { $gen.Name              }
                               elseif ($platform.PSObject.Properties['name'])        { $platform.name         }
                               elseif ($platform.PSObject.Properties['Name'])        { $platform.Name         } else { '' }
                Description  = if ($gen.PSObject.Properties['description'])          { $gen.description       }
                               elseif ($gen.PSObject.Properties['Description'])      { $gen.Description       }
                               elseif ($platform.PSObject.Properties['description']) { $platform.description  }
                               elseif ($platform.PSObject.Properties['Description']) { $platform.Description  } else { '' }
                Active       = if ($gen.PSObject.Properties['active'])               { $gen.active            }
                               elseif ($gen.PSObject.Properties['Active'])           { $gen.Active            }
                               elseif ($platform.PSObject.Properties['active'])      { $platform.active       }
                               elseif ($platform.PSObject.Properties['Active'])      { $platform.Active       } else { $false }
                PlatformType = if ($gen.PSObject.Properties['platformType'])         { $gen.platformType      }
                               elseif ($gen.PSObject.Properties['SystemType'])       { $gen.SystemType        }
                               elseif ($platform.PSObject.Properties['platformType']) { $platform.platformType }
                               elseif ($platform.PSObject.Properties['SystemType'])   { $platform.SystemType   } else { '' }
            })
            $result.Successes++
            $result.ItemsProcessed++
        } catch {
            $platformId = try { "$($platform.id)" } catch { '(unknown)' }
            $msg = "Unexpected error mapping platform '$platformId': $_"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = $InputData
                ErrorMessage = $msg
                ErrorDetails = $null
            })
            $result.Failures++
            $result.ItemsProcessed++
        }
    }

    Write-CyberArkLog -Level 'INFO' -Message "Platform list complete. Platforms retrieved: $($result.Successes)."
    return $result
}
