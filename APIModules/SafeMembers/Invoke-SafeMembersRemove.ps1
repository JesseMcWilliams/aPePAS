#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Remove Safe Member'
    Category         = 'SafeMembers'
    Action           = 'Remove'
    Description      = 'Remove a member from a safe, revoking all their permissions.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';   Required = $true; Description = 'Name of the safe.' }
        @{ Column = 'MemberName'; Required = $true; Description = 'Name of the member to remove.' }
    )
    Priority         = 23
    Version          = '1.0.0'
}

function Get-SafeMembersRemoveInput {
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

    Write-Host '  Safe Member to Remove' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  WARNING: This removes all access for the specified member.' -ForegroundColor Yellow
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Name of the safe.'

    $memberName = Show-FieldPrompt -Label 'MemberName' `
        -Default $(if ($Defaults['MemberName']) { $Defaults['MemberName'] } else { '' }) `
        -Required $true `
        -Description 'Name of the member to remove.'

    return @{
        SafeName   = $safeName
        MemberName = $memberName
    }
}

function Invoke-SafeMembersRemove {
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

    # Validate InputData presence
    if (-not $InputData) {
        $msg = 'InputData is null or missing. SafeName and MemberName are required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # Validate SafeName
    $safeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])".Trim() } else { '' }

    if (-not $safeName) {
        $msg = 'SafeName is required and must not be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # Validate MemberName
    $memberName = if ($InputData['MemberName']) { "$($InputData['MemberName'])".Trim() } else { '' }

    if (-not $memberName) {
        $msg = 'MemberName is required and must not be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $null
        })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $encodedSafe   = [Uri]::EscapeDataString($safeName)
    $encodedMember = [Uri]::EscapeDataString($memberName)
    $endpoint      = "/API/Safes/$encodedSafe/Members/$encodedMember"

    Write-CyberArkLog -Level 'INFO'  -Message "Starting safe member remove. SafeName='$safeName', MemberName='$memberName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "DELETE $endpoint"

    # WhatIf: log intent and return without calling API
    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: DELETE $endpoint would be performed."
        $result.Successes++
        $result.ItemsProcessed++
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'DELETE' `
        -Endpoint $endpoint `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Safe member remove failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    # Success - 204 No Content
    $result.Results.Add([PSCustomObject]@{
        SafeName   = $safeName
        MemberName = $memberName
        Removed    = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Safe member remove complete. SafeName='$safeName', MemberName='$memberName'."

    Add-CyberArkLogSummaryEntry `
        -ModuleName     $ModuleMeta.Name `
        -ItemsProcessed $result.ItemsProcessed `
        -Successes      $result.Successes `
        -Failures       $result.Failures

    return $result
}
