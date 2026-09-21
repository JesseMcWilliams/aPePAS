#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Applications'
    Category         = 'Applications'
    Action           = 'List'
    Description      = 'Retrieve CyberArk applications with optional filters.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @()
    Priority         = 85
    Version          = '1.0.0'
}

function Get-ApplicationsListInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Search Criteria  (press Enter to skip each field)' -ForegroundColor DarkGray
    Write-Host ''

    $appId = Show-FieldPrompt -Label 'App ID Filter' `
        -Default $(if ($Defaults['AppID']) { $Defaults['AppID'] } else { '' }) `
        -Description 'Optional: filter by partial Application ID. Leave blank for all applications.'

    $location = Show-FieldPrompt -Label 'Location' `
        -Default $(if ($Defaults['Location']) { $Defaults['Location'] } else { '' }) `
        -Description 'Optional: filter by application location (e.g. \Applications).'

    $inclSubStr = Show-FieldPrompt -Label 'Include Sublocations' `
        -Default $(if ($Defaults['IncludeSublocations']) { 'Y' } else { 'N' }) `
        -Description 'Include applications in sub-locations? (Y/N)'

    return @{
        AppID               = $appId
        Location            = $location
        IncludeSublocations = ($inclSubStr -match '^[Yy]$')
    }
}

function Invoke-ApplicationsList {
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

    $appId              = if ($InputData['AppID'])    { "$($InputData['AppID'])".Trim()    } else { '' }
    $location           = if ($InputData['Location']) { "$($InputData['Location'])".Trim() } else { '' }
    # [bool]$x on a CSV string casts ANY non-empty string to $true, including the literal text
    # "false"/"no"/"0" - only a truly empty string casts to $false. Match against known truthy
    # tokens instead (also handles a real interactive-mode [bool] input, since PowerShell
    # stringifies $true/$false to "True"/"False").
    $inclSublocations   = "$($InputData['IncludeSublocations'])".Trim() -match '(?i)^(true|yes|y|1)$'

    $queryParams = @{}
    if ($appId)    { $queryParams['AppID']    = $appId    }
    if ($location) { $queryParams['Location'] = $location }
    $queryParams['IncludeSublocations'] = if ($inclSublocations) { 'true' } else { 'false' }

    $criteriaLog = $(
        $parts = @()
        if ($appId)            { $parts += "AppID='$appId'" }
        if ($location)         { $parts += "Location='$location'" }
        if ($inclSublocations) { $parts += 'IncludeSublocations=true' }
        if ($parts) { $parts -join '  ' } else { '(all applications)' }
    )

    Write-CyberArkLog -Level 'INFO'  -Message 'Starting application list retrieval.'
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /WebServices/PIMServices.svc/Applications | $criteriaLog"

    $response = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/WebServices/PIMServices.svc/Applications/' `
        -QueryParams $queryParams `
        -WhatIf:     $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Application list failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Response: { "application": [ {...}, ... ] }
    $apps = @()
    if ($response.Data) {
        if ($response.Data.PSObject.Properties['application']) {
            $raw = $response.Data.application
            if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string])) {
                $apps = @($raw)
            } elseif ($raw) {
                $apps = @($raw)
            }
        }
    }

    if ($apps.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message 'No applications returned for the given criteria.'
        return $result
    }

    foreach ($app in $apps) {
        try {
            $result.Results.Add([PSCustomObject]@{
                AppID                = if ($app.PSObject.Properties['AppID'])               { $app.AppID }               else { '' }
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
            $appIdStr = try { "$($app.AppID)" } catch { '(unknown)' }
            $msg = "Unexpected error mapping application '$appIdStr': $_"
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

    Write-CyberArkLog -Level 'INFO' -Message "Application list complete. Applications retrieved: $($result.Successes)."
    return $result
}
