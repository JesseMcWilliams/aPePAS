#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Get Application'
    Category         = 'Applications'
    Action           = 'Get'
    Description      = 'Retrieve details for a specific CyberArk application by App ID.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AppID'; Required = $true; Description = 'Application ID, or leave blank to search.' }
    )
    Priority         = 86
    Version          = '1.0.0'
}

function Get-ApplicationsGetInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Get Application Details' -ForegroundColor DarkGray
    Write-Host ''

    $appId = Show-FieldPrompt -Label 'App ID' `
        -Default $(if ($Defaults['AppID']) { $Defaults['AppID'] } else { '' }) `
        -Description 'Application ID, or leave blank to search by name.'

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

function Invoke-ApplicationsGet {
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
        $msg = 'Invoke-ApplicationsGet: AppID is required.'
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

    Write-CyberArkLog -Level 'INFO'  -Message "Starting application details retrieval for App ID: $appId"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /WebServices/PIMServices.svc/Applications/$appId/"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/WebServices/PIMServices.svc/Applications/$encodedId/" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Get Application failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Response: { "application": { ... } } - single object wrapped in application key
    $app = $null
    if ($response.Data) {
        if ($response.Data.PSObject.Properties['application'] -and $response.Data.application) {
            $app = $response.Data.application
        } else {
            $app = $response.Data
        }
    }

    if (-not $app) {
        $msg = "Get Application: no data returned for App ID '$appId'."
        Write-CyberArkLog -Level 'WARN' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    try {
        $result.Results.Add([PSCustomObject]@{
            AppID                = if ($app.PSObject.Properties['AppID'])               { $app.AppID }               else { $appId }
            Description          = if ($app.PSObject.Properties['Description'])         { $app.Description }         else { '' }
            Location             = if ($app.PSObject.Properties['Location'])            { $app.Location }            else { '' }
            AccessPermittedFrom  = if ($app.PSObject.Properties['AccessPermittedFrom']) { $app.AccessPermittedFrom } else { '' }
            AccessPermittedTo    = if ($app.PSObject.Properties['AccessPermittedTo'])   { $app.AccessPermittedTo }   else { '' }
            ExpirationDate       = if ($app.PSObject.Properties['ExpirationDate'])      { $app.ExpirationDate }      else { '' }
            Disabled             = if ($app.PSObject.Properties['Disabled'])            { $app.Disabled }            else { $false }
            BusinessOwnerFName   = if ($app.PSObject.Properties['BusinessOwnerFName'])  { $app.BusinessOwnerFName }  else { '' }
            BusinessOwnerLName   = if ($app.PSObject.Properties['BusinessOwnerLName'])  { $app.BusinessOwnerLName }  else { '' }
            BusinessOwnerEmail   = if ($app.PSObject.Properties['BusinessOwnerEmail'])  { $app.BusinessOwnerEmail }  else { '' }
            BusinessOwnerPhone   = if ($app.PSObject.Properties['BusinessOwnerPhone'])  { $app.BusinessOwnerPhone }  else { '' }
        })
        $result.Successes++
        $result.ItemsProcessed++
    } catch {
        $msg = "Unexpected error mapping application '$appId': $_"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
    }

    Write-CyberArkLog -Level 'INFO' -Message "Get Application complete for App ID: $appId."
    return $result
}
