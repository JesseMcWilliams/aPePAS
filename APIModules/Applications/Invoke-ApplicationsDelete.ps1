#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Delete Application'
    Category         = 'Applications'
    Action           = 'Delete'
    Description      = 'Delete a CyberArk application by App ID.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AppID'; Required = $true; Description = 'Application ID to delete, or leave blank to search.' }
    )
    Priority         = 88
    Version          = '1.0.0'
}

function Get-ApplicationsDeleteInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Delete Application' -ForegroundColor DarkGray
    Write-Host ''

    $appId = Show-FieldPrompt -Label 'App ID' `
        -Default $(if ($Defaults['AppID']) { $Defaults['AppID'] } else { '' }) `
        -Description 'Application ID to delete, or leave blank to search by name.'

    if (-not $appId) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Partial Application ID to search for.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $appId = Invoke-EntitySearch -Token $Token `
                -Endpoint           '/WebServices/PIMServices.svc/Applications/' `
                -SearchTerm         $searchTerm `
                -ResponseProperty   'application' `
                -IdProperty         'AppID' `
                -DisplayProperties  @('AppID', 'Description', 'Location') `
                -EntityLabel        'application' `
                -ClientSideFilter `
                -IgnoreSSL          $ignoreSSL
        }
        if (-not $appId) { return $null }
    }

    return @{ AppID = $appId }
}

function Invoke-ApplicationsDelete {
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

    $appId = if ($InputData['AppID']) { "$($InputData['AppID'])".Trim() } else { '' }

    if (-not $appId) {
        $msg = 'Invoke-ApplicationsDelete: AppID is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'AppID is required.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $encodedId = [Uri]::EscapeDataString($appId)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting delete application for App ID: $appId"
    Write-CyberArkLog -Level 'DEBUG' -Message "DELETE /WebServices/PIMServices.svc/Applications/$appId"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: DELETE /WebServices/PIMServices.svc/Applications/$appId would be performed."
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'DELETE' `
        -Endpoint "/WebServices/PIMServices.svc/Applications/$encodedId/" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Delete Application failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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
        AppID  = $appId
        Status = 'Deleted'
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Delete Application complete for App ID: $appId."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
