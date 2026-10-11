#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Get Safe'
    Category         = 'Safes'
    Action           = 'Get'
    Description      = 'Retrieve details of a single safe by name.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName'; Required = $true; Description = 'Name of the safe to retrieve.' }
    )
    Priority         = 11
    Version          = '1.1.0'
}

function Get-SafesGetInput {
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

    $safeName = Show-FieldPrompt -Label 'Safe Name' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Name of the safe to retrieve.'

    return @{
        SafeName = $safeName
    }
}

function Invoke-SafesGet {
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

    $safeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])".Trim() } else { '' }

    if (-not $safeName) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-SafesGet: SafeName is required but was not provided.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'SafeName is required.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.IsFatal = $false
        return $result
    }

    $encodedSafeName = [Uri]::EscapeDataString($safeName)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting safe retrieval for: $safeName"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes/$encodedSafeName"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Safes/$encodedSafeName" `
        -PageSize 0 `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Safe get failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    $safe = $response.Data

    $creationDate = if ($safe.PSObject.Properties['creationTime'] -and $safe.creationTime) {
        try { [DateTimeOffset]::FromUnixTimeSeconds($safe.creationTime).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    $lastModDate = if ($safe.PSObject.Properties['lastModificationTime'] -and $safe.lastModificationTime) {
        try { [DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]$safe.lastModificationTime / 1000)).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    $creatorId   = if ($safe.PSObject.Properties['creator'] -and $safe.creator -and
                       $safe.creator.PSObject.Properties['id'])   { $safe.creator.id   } else { '' }
    $creatorName = if ($safe.PSObject.Properties['creator'] -and $safe.creator -and
                       $safe.creator.PSObject.Properties['name']) { $safe.creator.name } else { '' }

    $result.Results.Add([PSCustomObject]@{
        SafeUrlId        = if ($safe.PSObject.Properties['safeUrlId'])               { $safe.safeUrlId               } else { '' }
        SafeName         = if ($safe.PSObject.Properties['safeName'])                { $safe.safeName                } else { '' }
        SafeNumber       = if ($safe.PSObject.Properties['safeNumber'])              { $safe.safeNumber              } else { $null }
        Description      = if ($safe.PSObject.Properties['description'])             { $safe.description             } else { '' }
        Location         = if ($safe.PSObject.Properties['location'])                { $safe.location                } else { '' }
        CreatorId        = $creatorId
        Creator          = $creatorName
        OLACEnabled      = if ($safe.PSObject.Properties['olacEnabled'])             { $safe.olacEnabled             } else { $false }
        ManagingCPM      = if ($safe.PSObject.Properties['managingCPM'])             { $safe.managingCPM             } else { '' }
        VersionRetention = if ($safe.PSObject.Properties['numberOfVersionsRetention']) { $safe.numberOfVersionsRetention } else { $null }
        DayRetention     = if ($safe.PSObject.Properties['numberOfDaysRetention'])   { $safe.numberOfDaysRetention   } else { $null }
        AutoPurge        = if ($safe.PSObject.Properties['autoPurgeEnabled'])        { $safe.autoPurgeEnabled        } else { $false }
        Created          = $creationDate
        LastModified     = $lastModDate
        IsExpiredMember  = if ($safe.PSObject.Properties['isExpiredMember'])         { $safe.isExpiredMember         } else { $false }
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Safe get complete. Safe retrieved: $safeName."
    return $result
}
