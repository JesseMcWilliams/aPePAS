#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Safes'
    Category         = 'Safes'
    Action           = 'List'
    Description      = 'Retrieve all accessible safes with optional search and filter.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @()
    Priority         = 10
    Version          = '1.1.0'
}

function Get-SafesListInput {
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
        -Default $(if ($Defaults['Search'])  { $Defaults['Search']  } else { '' }) `
        -Description 'Free-text search across safe name and description. Leave blank for all safes.'

    $filter = Show-FieldPrompt -Label 'Filter' `
        -Default $(if ($Defaults['Filter'])  { $Defaults['Filter']  } else { '' }) `
        -Description 'OData filter expression (e.g. "safeName eq MySafe"). Leave blank for no filter.'

    $extStr = Show-FieldPrompt -Label 'Extended Details' `
        -Default $(if ($Defaults['ExtendedDetails']) { 'Y' } else { 'N' }) `
        -Description 'Include extended safe details such as creator and retention settings? (Y/N)'

    return @{
        Search          = $search
        Filter          = $filter
        ExtendedDetails = ($extStr -match '^[Yy]$')
    }
}

function Invoke-SafesList {
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

    $search     = if ($InputData['Search'])  { "$($InputData['Search'])".Trim()  } else { $null }
    $filter     = if ($InputData['Filter'])  { "$($InputData['Filter'])".Trim()  } else { $null }
    # [bool]$x on a CSV string casts ANY non-empty string to $true, including the literal text
    # "false"/"no"/"0" - only a truly empty string casts to $false. Match against known truthy
    # tokens instead (also handles a real interactive-mode [bool] input, since PowerShell
    # stringifies $true/$false to "True"/"False"). This was untested because every existing test
    # passes a real PowerShell boolean, never the CSV-string form that actually reaches this line
    # in bulk/CSV mode.
    $extDetails = "$($InputData['ExtendedDetails'])".Trim() -match '(?i)^(true|yes|y|1)$'

    # Build query parameters - only include keys that have a value
    $queryParams = @{}
    if ($search)     { $queryParams['search']          = $search }
    if ($filter)     { $queryParams['filter']          = $filter }
    if ($extDetails) { $queryParams['extendedDetails'] = 'true'  }

    $criteriaLog = $(
        $parts = @()
        if ($search)     { $parts += "Search='$search'" }
        if ($filter)     { $parts += "Filter='$filter'" }
        if ($extDetails) { $parts += 'ExtendedDetails=true' }
        if ($parts)      { $parts -join '  ' } else { '(all safes)' }
    )

    Write-CyberArkLog -Level 'INFO'  -Message 'Starting safe list retrieval.'
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes | $criteriaLog"

    $response = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/API/Safes' `
        -QueryParams $queryParams `
        -WhatIf:     $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Safe list failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    [array]$safes = if ($response.Data -and $response.Data.PSObject.Properties['value']) {
        @($response.Data.value)
    } else { @() }

    if ((-not $safes) -or $safes.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message 'No safes returned for the given criteria.'
        # Not a failure - a valid empty result
        return $result
    }

    foreach ($safe in $safes) {
        try {
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
        } catch {
            $safeName = try { "$($safe.safeName)" } catch { '(unknown)' }
            $msg = "Unexpected error mapping safe '$safeName': $_"
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

    Write-CyberArkLog -Level 'INFO' -Message "Safe list complete. Safes retrieved: $($result.Successes)."
    return $result
}
