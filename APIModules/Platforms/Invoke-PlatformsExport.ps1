#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Export Platform'
    Category         = 'Platforms'
    Action           = 'Export'
    Description      = 'Download a platform (or rotational group / dependent / group platform) package as a .zip, matching psPAS''s Export-PASPlatform.ps1. Saved automatically to the profile''s Output Folder.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'PlatformID';       Required = $false; Description = 'Standard target platform ID to export. Exactly one of the four ID columns must be supplied.' }
        @{ Column = 'RotationalGroupID'; Required = $false; Description = 'Rotational group ID to export.' }
        @{ Column = 'DependentID';       Required = $false; Description = 'Dependent platform ID to export.' }
        @{ Column = 'GroupPlatformID';   Required = $false; Description = 'Group platform ID to export (requires PVWA 12.2+ - unsupported PVWA versions will fail with a normal API error, not a special fallback).' }
    )
    Priority         = 48
    Version          = '1.0.0'
}

function Get-PlatformsExportInput {
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

    Write-Host '  Export Platform' -ForegroundColor DarkGray
    Write-Host ''

    $typeInput = Show-FieldPrompt -Label 'Export Type' `
        -Default '1' `
        -Description 'Enter 1 for a standard Platform, 2 for a Rotational Group, 3 for a Dependent, or 4 for a Group Platform.'

    switch ($typeInput.Trim()) {
        '2' {
            $id = Show-FieldPrompt -Label 'Rotational Group ID' `
                -Default $(if ($Defaults['RotationalGroupID']) { $Defaults['RotationalGroupID'] } else { '' }) `
                -Required $true -Description 'Rotational group ID to export.'
            return @{ RotationalGroupID = $id }
        }
        '3' {
            $id = Show-FieldPrompt -Label 'Dependent ID' `
                -Default $(if ($Defaults['DependentID']) { $Defaults['DependentID'] } else { '' }) `
                -Required $true -Description 'Dependent platform ID to export.'
            return @{ DependentID = $id }
        }
        '4' {
            $id = Show-FieldPrompt -Label 'Group Platform ID' `
                -Default $(if ($Defaults['GroupPlatformID']) { $Defaults['GroupPlatformID'] } else { '' }) `
                -Required $true -Description 'Group platform ID to export (requires PVWA 12.2+).'
            return @{ GroupPlatformID = $id }
        }
        default {
            $id = Show-FieldPrompt -Label 'Platform ID' `
                -Default $(if ($Defaults['PlatformID']) { $Defaults['PlatformID'] } else { '' }) `
                -Required $true -Description 'Standard target platform ID to export.'
            return @{ PlatformID = $id }
        }
    }
}

function Invoke-PlatformsExport {
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

    # Exactly one of the four ID columns identifies both which endpoint variant to call and the
    # value to export - matching psPAS's Export-PASPlatform.ps1's four separate parameter sets.
    $platformId       = if ($InputData['PlatformID'])       { "$($InputData['PlatformID'])".Trim() }       else { '' }
    $rotationalGroupId = if ($InputData['RotationalGroupID']) { "$($InputData['RotationalGroupID'])".Trim() } else { '' }
    $dependentId      = if ($InputData['DependentID'])       { "$($InputData['DependentID'])".Trim() }       else { '' }
    $groupPlatformId  = if ($InputData['GroupPlatformID'])   { "$($InputData['GroupPlatformID'])".Trim() }   else { '' }

    $suppliedCount = @($platformId, $rotationalGroupId, $dependentId, $groupPlatformId | Where-Object { $_ }).Count

    if ($suppliedCount -ne 1) {
        $msg = "Exactly one of PlatformID, RotationalGroupID, DependentID, or GroupPlatformID must be supplied (got $suppliedCount)."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    if ($platformId) {
        $exportType  = 'PlatformID'
        $exportValue = $platformId
        $endpoint    = "/API/Platforms/$([Uri]::EscapeDataString($platformId))/Export"
        $queryParams = @{ platformID = $platformId }
    } elseif ($rotationalGroupId) {
        $exportType  = 'RotationalGroupID'
        $exportValue = $rotationalGroupId
        # Lowercase "api" - matches psPAS's Export-PASPlatform.ps1 exactly for this endpoint.
        $endpoint    = "/api/Platforms/RotationalGroups/$([Uri]::EscapeDataString($rotationalGroupId))/Export"
        $queryParams = $null
    } elseif ($dependentId) {
        $exportType  = 'DependentID'
        $exportValue = $dependentId
        # Lowercase "api" - matches psPAS's Export-PASPlatform.ps1 exactly for this endpoint.
        $endpoint    = "/api/Platforms/Dependents/$([Uri]::EscapeDataString($dependentId))/Export"
        $queryParams = $null
    } else {
        $exportType  = 'GroupPlatformID'
        $exportValue = $groupPlatformId
        $endpoint    = "/API/Platforms/Groups/$([Uri]::EscapeDataString($groupPlatformId))/Export"
        $queryParams = $null
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Starting platform export. $exportType='$exportValue'."
    Write-CyberArkLog -Level 'DEBUG' -Message "POST $endpoint"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST $endpoint would be performed."
        $result.Results.Add([PSCustomObject]@{
            $exportType = $exportValue
            SavedPath   = ''
            Exported    = $true
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $apiParams = @{
        Token    = $Token
        Method   = 'POST'
        Endpoint = $endpoint
    }
    if ($queryParams) { $apiParams['QueryParams'] = $queryParams }

    $response = Invoke-CyberArkAPI @apiParams

    if (-not $response.IsSuccess) {
        $msg = "Platform export failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    if ($response.DataType -ne 'File' -or -not $response.Data) {
        $msg = "Platform export returned HTTP $($response.StatusCode) but no file content (DataType='$($response.DataType)')."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # Resolve the profile's Output Folder the same way Invoke-CustomExportAll.ps1 does - relative
    # paths are resolved against the project root ($script:APIModulesPath's parent), not this
    # file's own directory, since $PSScriptRoot here is APIModules\Platforms.
    $outputFolder = if ($script:ActiveProfile -and $script:ActiveProfile.OutputFolder) {
        $script:ActiveProfile.OutputFolder
    } else { (Get-Location).Path }
    if (-not [System.IO.Path]::IsPathRooted($outputFolder)) {
        $projectRoot  = if ($script:APIModulesPath) { Split-Path -Path $script:APIModulesPath -Parent } else { (Get-Location).Path }
        $outputFolder = Join-Path $projectRoot $outputFolder
    }
    if (-not (Test-Path -LiteralPath $outputFolder)) {
        New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
    }

    $fileName = if ($response.SuggestedFileName) {
        $response.SuggestedFileName
    } else {
        "Platform-Export-$exportType-$exportValue-$(Get-Date -Format 'yyyyMMdd-HHmmss').zip"
    }
    # Strip characters Windows disallows in filenames - a defensive fallback in case a suggested
    # filename from Content-Disposition or a CSV-supplied ID ever contains one.
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $safeFileName = -join ($fileName.ToCharArray() | ForEach-Object { if ($invalidChars -contains $_) { '_' } else { $_ } })
    $savedPath    = Join-Path $outputFolder $safeFileName

    $saved = Invoke-FileWriteWithRetry -Path $savedPath -Action {
        [System.IO.File]::WriteAllBytes($savedPath, $response.Data)
    }

    if (-not $saved) {
        $msg = "Platform export downloaded successfully but the file could not be saved to '$savedPath' (user declined to retry)."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $result.Results.Add([PSCustomObject]@{
        $exportType = $exportValue
        SavedPath   = $savedPath
        Exported    = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Platform export complete. $exportType='$exportValue'. Saved: $savedPath"

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
