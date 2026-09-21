#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Unassign CPM from Safe'
    Category         = 'Safes'
    Action           = 'UnassignCPM'
    Description      = 'Remove the CPM assignment from a safe, leaving it manually managed.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName'; Required = $true; Description = 'Name of the safe to unassign the CPM from.' }
    )
    Priority         = 17
    Version          = '1.0.0'
}

function Get-SafesUnassignCPMInput {
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

    Write-Host '  Unassign CPM from Safe' -ForegroundColor DarkGray
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Name of the safe to unassign the CPM from.'

    return @{
        SafeName = $safeName
    }
}

function Invoke-SafesUnassignCPM {
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

    if (-not $InputData) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-SafesUnassignCPM: InputData is null or missing.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $null
            ErrorMessage = 'InputData is null or missing.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $safeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])".Trim() } else { '' }

    if (-not $safeName) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-SafesUnassignCPM: SafeName is required but was empty.'
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = 'SafeName is required but was empty.'
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $encodedSafeName = [Uri]::EscapeDataString($safeName)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting CPM unassignment for safe '$safeName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Safes/$encodedSafeName"

    # GET current safe - the Safes API PUT is a full replace, so every other field must be
    # carried forward unchanged. Same pattern as Invoke-SafesUpdate.ps1.
    $getResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Safes/$encodedSafeName"

    if (-not $getResponse.IsSuccess) {
        $msg = "Failed to retrieve safe '$safeName' before CPM unassignment (HTTP $($getResponse.StatusCode)): $($getResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $getResponse.ErrorMessage
            ErrorDetails = $getResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($getResponse.StatusCode -in @(401, 0))
        return $result
    }

    $currentSafe = $getResponse.Data

    # ManagingCPM is deliberately forced to '' here - this is the one field this module exists
    # to clear, unlike Invoke-SafesUpdate.ps1 where a blank input means "keep current value".
    $body = @{
        SafeName         = $safeName
        Description      = if ($currentSafe.description) { $currentSafe.description } else { '' }
        Location         = if ($currentSafe.location)     { $currentSafe.location }     else { '' }
        ManagingCPM      = ''
        AutoPurgeEnabled = [bool]$currentSafe.autoPurgeEnabled
    }
    if ([int]$currentSafe.numberOfDaysRetention -gt 0) {
        $body['NumberOfDaysRetention'] = [int]$currentSafe.numberOfDaysRetention
    } else {
        $body['NumberOfVersionsRetention'] = [int]$currentSafe.numberOfVersionsRetention
    }

    Write-CyberArkLog -Level 'DEBUG' -Message "PUT /API/Safes/$encodedSafeName"

    $putResponse = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'PUT' `
        -Endpoint "/API/Safes/$encodedSafeName" `
        -Body     $body `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $putResponse.IsSuccess) {
        $msg = "CPM unassignment failed for '$safeName' (HTTP $($putResponse.StatusCode)): $($putResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $putResponse.ErrorMessage
            ErrorDetails = $putResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($putResponse.StatusCode -in @(401, 0))
        return $result
    }

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: CPM unassignment suppressed for '$safeName'."
        $result.Results.Add([PSCustomObject]@{
            SafeName    = $safeName
            ManagingCPM = ''
        })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $updatedSafe = $putResponse.Data

    $result.Results.Add([PSCustomObject]@{
        SafeName    = if ($updatedSafe -and $updatedSafe.safeName) { $updatedSafe.safeName } else { $safeName }
        ManagingCPM = if ($updatedSafe) { $updatedSafe.managingCPM } else { '' }
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "CPM unassignment complete for '$safeName'."

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
