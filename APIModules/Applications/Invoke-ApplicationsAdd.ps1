#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Application'
    Category         = 'Applications'
    Action           = 'Add'
    Description      = 'Create a new CyberArk application.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AppID';               Required = $true;  Description = 'Unique Application ID (1-127 chars, cannot contain "&").' }
        @{ Column = 'Description';         Required = $false; Description = 'Application description (max 99 chars).' }
        @{ Column = 'Location';            Required = $true;  Description = 'Location in the vault (e.g. \Applications).' }
        @{ Column = 'AccessPermittedFrom'; Required = $false; Description = 'Start hour for permitted access (0-23).' }
        @{ Column = 'AccessPermittedTo';   Required = $false; Description = 'End hour for permitted access (0-23).' }
        @{ Column = 'ExpirationDate';      Required = $false; Description = 'Expiration date in MM/DD/YYYY format.' }
        @{ Column = 'Disabled';            Required = $false; Description = 'Set to true to create the application as disabled.' }
        @{ Column = 'BusinessOwnerFName';  Required = $false; Description = 'Business owner first name (max 29 chars).' }
        @{ Column = 'BusinessOwnerLName';  Required = $false; Description = 'Business owner last name.' }
        @{ Column = 'BusinessOwnerEmail';  Required = $false; Description = 'Business owner email.' }
        @{ Column = 'BusinessOwnerPhone';  Required = $false; Description = 'Business owner phone (max 24 chars).' }
    )
    Priority         = 87
    Version          = '1.2.0'
}

function Get-ApplicationsAddInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Add Application  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $appId = Show-FieldPrompt -Label 'App ID' `
        -Default $(if ($Defaults['AppID']) { $Defaults['AppID'] } else { '' }) `
        -Required $true `
        -Description 'Unique Application ID (required, 1-127 chars, cannot contain "&").'

    $description = Show-FieldPrompt -Label 'Description' `
        -Default $(if ($Defaults['Description']) { $Defaults['Description'] } else { '' }) `
        -Description 'Application description (max 99 chars).'

    $location = Show-FieldPrompt -Label 'Location' `
        -Default $(if ($Defaults['Location']) { $Defaults['Location'] } else { '' }) `
        -Required $true `
        -Description 'Vault location (e.g. \Applications).'

    $accessFrom = Show-FieldPrompt -Label 'Access Permitted From' `
        -Default $(if ($Defaults['AccessPermittedFrom']) { $Defaults['AccessPermittedFrom'] } else { '' }) `
        -Description 'Start hour for permitted access (0-23). Leave blank for unrestricted.'

    $accessTo = Show-FieldPrompt -Label 'Access Permitted To' `
        -Default $(if ($Defaults['AccessPermittedTo']) { $Defaults['AccessPermittedTo'] } else { '' }) `
        -Description 'End hour for permitted access (0-23). Leave blank for unrestricted.'

    $expirationDate = Show-FieldPrompt -Label 'Expiration Date' `
        -Default $(if ($Defaults['ExpirationDate']) { $Defaults['ExpirationDate'] } else { '' }) `
        -Description 'Expiration date (MM/DD/YYYY). Leave blank for no expiration.'

    $disabledStr = Show-FieldPrompt -Label 'Disabled' `
        -Default $(if ($Defaults['Disabled']) { 'Y' } else { 'N' }) `
        -Description 'Create application as disabled? (Y/N)'

    $ownerFName = Show-FieldPrompt -Label 'Owner First Name' `
        -Default $(if ($Defaults['BusinessOwnerFName']) { $Defaults['BusinessOwnerFName'] } else { '' }) `
        -Description 'Business owner first name (max 29 chars).'

    $ownerLName = Show-FieldPrompt -Label 'Owner Last Name' `
        -Default $(if ($Defaults['BusinessOwnerLName']) { $Defaults['BusinessOwnerLName'] } else { '' }) `
        -Description 'Business owner last name.'

    $ownerEmail = Show-FieldPrompt -Label 'Owner Email' `
        -Default $(if ($Defaults['BusinessOwnerEmail']) { $Defaults['BusinessOwnerEmail'] } else { '' }) `
        -Description 'Business owner email address.'

    $ownerPhone = Show-FieldPrompt -Label 'Owner Phone' `
        -Default $(if ($Defaults['BusinessOwnerPhone']) { $Defaults['BusinessOwnerPhone'] } else { '' }) `
        -Description 'Business owner phone number (max 24 chars).'

    return @{
        AppID               = $appId
        Description         = $description
        Location            = $location
        AccessPermittedFrom = $accessFrom
        AccessPermittedTo   = $accessTo
        ExpirationDate      = $expirationDate
        Disabled            = ($disabledStr -match '^[Yy]$')
        BusinessOwnerFName  = $ownerFName
        BusinessOwnerLName  = $ownerLName
        BusinessOwnerEmail  = $ownerEmail
        BusinessOwnerPhone  = $ownerPhone
    }
}

function Invoke-ApplicationsAdd {
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
        $msg = 'Invoke-ApplicationsAdd: AppID is required.'
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

    # AppID: 1-127 chars, no '&' - matches psPAS's Add-PASApplication.ps1 ValidateLength/ValidateScript.
    if ($appId.Length -gt 127 -or $appId -match '&') {
        $msg = "Invoke-ApplicationsAdd: AppID '$appId' is invalid - must be 1-127 characters and cannot contain '&'."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = "AppID must be 1-127 characters and cannot contain '&'."
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $description  = if ($InputData['Description'])         { "$($InputData['Description'])".Trim()         } else { '' }
    $location     = if ($InputData['Location'])            { "$($InputData['Location'])".Trim()            } else { '' }

    if (-not $location) {
        $msg = 'Invoke-ApplicationsAdd: Location is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'Location is required.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    if ($description.Length -gt 99) {
        $msg = "Invoke-ApplicationsAdd: Description exceeds 99 characters ($($description.Length))."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'Description cannot exceed 99 characters.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $accessFrom   = if ($InputData['AccessPermittedFrom']) { "$($InputData['AccessPermittedFrom'])".Trim() } else { '' }
    $accessTo     = if ($InputData['AccessPermittedTo'])   { "$($InputData['AccessPermittedTo'])".Trim()   } else { '' }
    $expDate      = if ($InputData['ExpirationDate'])      { "$($InputData['ExpirationDate'])".Trim()      } else { '' }
    # [bool]$x on a CSV string casts ANY non-empty string to $true, including the literal text
    # "false"/"no"/"0" - only a truly empty string casts to $false. A CSV author writing
    # Disabled,false would therefore create the application with Disabled=$true, the opposite
    # of intent. Match against known truthy tokens instead (also handles a real interactive-mode
    # [bool] input, since PowerShell stringifies $true/$false to "True"/"False").
    $disabled     = "$($InputData['Disabled'])".Trim() -match '(?i)^(true|yes|y|1)$'
    $ownerFName   = if ($InputData['BusinessOwnerFName'])  { "$($InputData['BusinessOwnerFName'])".Trim()  } else { '' }
    $ownerLName   = if ($InputData['BusinessOwnerLName'])  { "$($InputData['BusinessOwnerLName'])".Trim()  } else { '' }
    $ownerEmail   = if ($InputData['BusinessOwnerEmail'])  { "$($InputData['BusinessOwnerEmail'])".Trim()  } else { '' }
    $ownerPhone   = if ($InputData['BusinessOwnerPhone'])  { "$($InputData['BusinessOwnerPhone'])".Trim()  } else { '' }

    if ($ownerFName.Length -gt 29) {
        $msg = "Invoke-ApplicationsAdd: BusinessOwnerFName exceeds 29 characters ($($ownerFName.Length))."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'BusinessOwnerFName cannot exceed 29 characters.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    if ($ownerPhone.Length -gt 24) {
        $msg = "Invoke-ApplicationsAdd: BusinessOwnerPhone exceeds 24 characters ($($ownerPhone.Length))."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'BusinessOwnerPhone cannot exceed 24 characters.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Starting add application for App ID: $appId"
    Write-CyberArkLog -Level 'DEBUG' -Message 'POST /WebServices/PIMServices.svc/Applications'

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST /WebServices/PIMServices.svc/Applications '$appId' would be performed."
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # AccessPermittedFrom/To are hour-of-day values (0-23), not epoch seconds - they arrive as raw
    # CSV/interactive text, so validate with TryParse rather than casting directly with [int], which
    # throws an uncaught exception on a non-numeric value. Manage-Privilege.ps1's CSV loop
    # (Invoke-CsvProcessing) has no try/catch around the module call, so an uncaught exception here
    # would abort the entire CSV file's row loop instead of failing just this one row - the
    # documented "single item validation failure" contract (Reference_Interfaces.md IsFatal table) requires
    # this to be a non-fatal, per-row failure. Range-checked to 0-23, matching psPAS's
    # Add-PASApplication.ps1 [ValidateRange(0,23)].
    $parsedAccessFrom = 0
    if ($accessFrom -and (-not [int]::TryParse($accessFrom, [ref]$parsedAccessFrom) -or $parsedAccessFrom -lt 0 -or $parsedAccessFrom -gt 23)) {
        $msg = "Invoke-ApplicationsAdd: AccessPermittedFrom '$accessFrom' is not a valid hour-of-day (0-23)."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = "AccessPermittedFrom '$accessFrom' is not a valid hour-of-day (0-23)."
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }
    $parsedAccessTo = 0
    if ($accessTo -and (-not [int]::TryParse($accessTo, [ref]$parsedAccessTo) -or $parsedAccessTo -lt 0 -or $parsedAccessTo -gt 23)) {
        $msg = "Invoke-ApplicationsAdd: AccessPermittedTo '$accessTo' is not a valid hour-of-day (0-23)."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = "AccessPermittedTo '$accessTo' is not a valid hour-of-day (0-23)."
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $appBody = @{ AppID = $appId }
    if ($description) { $appBody['Description']         = $description }
    if ($location)    { $appBody['Location']            = $location    }
    if ($accessFrom)  { $appBody['AccessPermittedFrom'] = $parsedAccessFrom }
    if ($accessTo)    { $appBody['AccessPermittedTo']   = $parsedAccessTo   }
    if ($expDate)     { $appBody['ExpirationDate']      = $expDate     }
    $appBody['Disabled'] = $disabled
    if ($ownerFName)  { $appBody['BusinessOwnerFName']  = $ownerFName  }
    if ($ownerLName)  { $appBody['BusinessOwnerLName']  = $ownerLName  }
    if ($ownerEmail)  { $appBody['BusinessOwnerEmail']  = $ownerEmail  }
    if ($ownerPhone)  { $appBody['BusinessOwnerPhone']  = $ownerPhone  }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint '/WebServices/PIMServices.svc/Applications/' `
        -Body     @{ application = $appBody } `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Add Application failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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
        Status = 'Created'
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Add Application complete for App ID: $appId."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
