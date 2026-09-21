#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Application Authentication Method'
    Category         = 'Applications'
    Action           = 'AddAuthMethod'
    Description      = 'Add an authentication method to a CyberArk application.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AppID';                Required = $true;  Description = 'Application ID, or leave blank to search.' }
        @{ Column = 'AuthType';             Required = $true;  Description = 'Auth type: path, certificateSN, hash, machineAddress, osUser.' }
        @{ Column = 'AuthValue';            Required = $true;  Description = 'Authentication value (path, cert serial, hash value, IP/hostname, or OS user).' }
        @{ Column = 'IsFolder';             Required = $false; Description = 'For path auth type: match folder and subfolders. (true/false)' }
        @{ Column = 'AllowInternalScripts'; Required = $false; Description = 'For path auth type: allow scripts in the path. (true/false)' }
        @{ Column = 'Comment';              Required = $false; Description = 'Optional comment.' }
    )
    Priority         = 90
    Version          = '1.0.0'
}

function Get-ApplicationsAddAuthMethodInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Add Application Authentication Method  (press Enter to skip optional fields)' -ForegroundColor DarkGray
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

    Write-Host ''
    Write-Host '  Auth Types: path | certificateSN | hash | machineAddress | osUser' -ForegroundColor DarkGray

    $authType = Show-FieldPrompt -Label 'Auth Type' `
        -Default $(if ($Defaults['AuthType']) { $Defaults['AuthType'] } else { '' }) `
        -Required $true `
        -Description 'Authentication method type (required).'

    $authValue = Show-FieldPrompt -Label 'Auth Value' `
        -Default $(if ($Defaults['AuthValue']) { $Defaults['AuthValue'] } else { '' }) `
        -Required $true `
        -Description 'Authentication value (required).'

    $isFolder             = $false
    $allowInternalScripts = $false
    if ($authType -eq 'path') {
        $isFolderStr = Show-FieldPrompt -Label 'Is Folder' `
            -Default $(if ($Defaults['IsFolder']) { 'Y' } else { 'N' }) `
            -Description 'Match folder and all subfolders? (Y/N)'
        $allowScriptsStr = Show-FieldPrompt -Label 'Allow Internal Scripts' `
            -Default $(if ($Defaults['AllowInternalScripts']) { 'Y' } else { 'N' }) `
            -Description 'Allow scripts inside the path? (Y/N)'
        $isFolder             = ($isFolderStr -match '^[Yy]$')
        $allowInternalScripts = ($allowScriptsStr -match '^[Yy]$')
    }

    $comment = Show-FieldPrompt -Label 'Comment' `
        -Default $(if ($Defaults['Comment']) { $Defaults['Comment'] } else { '' }) `
        -Description 'Optional comment.'

    return @{
        AppID                = $appId
        AuthType             = $authType
        AuthValue            = $authValue
        IsFolder             = $isFolder
        AllowInternalScripts = $allowInternalScripts
        Comment              = $comment
    }
}

function Invoke-ApplicationsAddAuthMethod {
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

    $appId     = if ($InputData['AppID'])     { "$($InputData['AppID'])".Trim()     } else { '' }
    $authType  = if ($InputData['AuthType'])  { "$($InputData['AuthType'])".Trim()  } else { '' }
    $authValue = if ($InputData['AuthValue']) { "$($InputData['AuthValue'])".Trim() } else { '' }

    if (-not $appId) {
        $msg = 'Invoke-ApplicationsAddAuthMethod: AppID is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = 'AppID is required.'; ErrorDetails = $null })
        $result.Failures++; $result.ItemsProcessed++
        return $result
    }
    if (-not $authType) {
        $msg = 'Invoke-ApplicationsAddAuthMethod: AuthType is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = 'AuthType is required.'; ErrorDetails = $null })
        $result.Failures++; $result.ItemsProcessed++
        return $result
    }
    if (-not $authValue) {
        $msg = 'Invoke-ApplicationsAddAuthMethod: AuthValue is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = 'AuthValue is required.'; ErrorDetails = $null })
        $result.Failures++; $result.ItemsProcessed++
        return $result
    }

    # [bool]$x on a CSV string casts ANY non-empty string to $true, including the literal text
    # "false"/"no"/"0" - only a truly empty string casts to $false. Match against known truthy
    # tokens instead (also handles a real interactive-mode [bool] input, since PowerShell
    # stringifies $true/$false to "True"/"False").
    $isFolder             = "$($InputData['IsFolder'])".Trim() -match '(?i)^(true|yes|y|1)$'
    $allowInternalScripts = "$($InputData['AllowInternalScripts'])".Trim() -match '(?i)^(true|yes|y|1)$'
    $comment              = if ($InputData['Comment']) { "$($InputData['Comment'])".Trim() } else { '' }

    $encodedId = [Uri]::EscapeDataString($appId)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting add auth method ($authType) for App ID: $appId"
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /WebServices/PIMServices.svc/Applications/$appId/Authentications"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST auth method '$authType' for App '$appId' would be performed."
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $authBody = @{
        AuthType  = $authType
        AuthValue = $authValue
    }
    if ($authType -eq 'path') {
        $authBody['IsFolder']             = $isFolder
        $authBody['AllowInternalScripts'] = $allowInternalScripts
    }
    if ($comment) { $authBody['Comment'] = $comment }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint "/WebServices/PIMServices.svc/Applications/$encodedId/Authentications/" `
        -Body     @{ authentication = $authBody } `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Add Auth Method failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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
        AppID    = $appId
        AuthType = $authType
        Status   = 'Added'
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Add Auth Method complete for App ID: $appId, type: $authType."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
