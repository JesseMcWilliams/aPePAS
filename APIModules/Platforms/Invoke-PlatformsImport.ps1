#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Import Platform'
    Category         = 'Platforms'
    Action           = 'Import'
    Description      = 'Import a new platform from a local platform ZIP package, matching psPAS''s Import-PASPlatform.ps1.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'ZipFilePath'; Required = $true; Description = 'Local path to the platform .zip package to import.' }
    )
    Priority         = 47
    Version          = '1.0.0'
}

function Get-PlatformsImportInput {
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

    $zipFilePath = Show-FieldPrompt -Label 'Platform ZIP Path' `
        -Default $(if ($Defaults['ZipFilePath']) { $Defaults['ZipFilePath'] } else { '' }) `
        -Required $true `
        -Description 'Local path to the platform .zip package to import.'

    return @{
        ZipFilePath = $zipFilePath
    }
}

function Invoke-PlatformsImport {
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

    $zipFilePath = if ($InputData['ZipFilePath']) { "$($InputData['ZipFilePath'])".Trim() } else { '' }

    if (-not $zipFilePath) {
        $msg = 'ZipFilePath is required and must not be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    if ($zipFilePath -notmatch '\.zip$') {
        $msg = "ZipFilePath '$zipFilePath' must end with .zip."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    if (-not (Test-Path -LiteralPath $zipFilePath -PathType Leaf)) {
        $msg = "ZipFilePath '$zipFilePath' does not exist or is not a file."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Starting platform import from '$zipFilePath'."
    Write-CyberArkLog -Level 'DEBUG' -Message 'POST /API/Platforms/Import'

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message 'WhatIf: POST /API/Platforms/Import would be performed.'
        $result.Results.Add([PSCustomObject]@{
            ZipFilePath = $zipFilePath
            Imported    = $true
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    try {
        # Sent as a raw JSON array of byte integers (via ConvertTo-Json on a [byte[]]), not a
        # base64 string - mirrors psPAS's Import-PASPlatform.ps1's actual, working request shape
        # (Get-ByteArray + ConvertTo-Json), even though the CyberArk Swagger spec's "format: byte"
        # annotation on this field would normally imply base64. psPAS's shipped behavior is the
        # more trustworthy source here since it's a real, in-production implementation - but this
        # is still unverified against a live tenant by this project and should be confirmed before
        # relying on it, since a mismatch here would surface as an import failure, not silent data
        # corruption.
        $fileBytes = [System.IO.File]::ReadAllBytes($zipFilePath)
    } catch {
        $msg = "Failed to read '$zipFilePath': $_"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint '/API/Platforms/Import' `
        -Body     @{ ImportFile = $fileBytes }

    if (-not $response.IsSuccess) {
        $msg = "Platform import failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    $importedPlatformId = if ($response.Data -and $response.Data.PSObject.Properties['PlatformID']) { $response.Data.PlatformID } else { '' }
    $warning            = if ($response.Data -and $response.Data.PSObject.Properties['Warning'])    { $response.Data.Warning }    else { '' }

    if ($warning) {
        Write-CyberArkLog -Level 'WARN' -Message "Platform import warning for '$zipFilePath': $warning"
    }

    $result.Results.Add([PSCustomObject]@{
        ZipFilePath = $zipFilePath
        PlatformID  = $importedPlatformId
        Warning     = $warning
        Imported    = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Platform import complete. PlatformID: $importedPlatformId."

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
