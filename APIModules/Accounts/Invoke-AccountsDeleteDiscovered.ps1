#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Delete Discovered Account'
    Category         = 'Accounts'
    Action           = 'DeleteDiscovered'
    Description      = 'Remove an account from the Pending (discovered) list. The account itself, on its machine, is not touched.'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'DiscoveredAccountID'; Required = $true; Description = 'ID of the pending account (from List Discovered Accounts).' }
    )
    Priority         = 53
    Version          = '1.0.0'
}

function Get-AccountsDeleteDiscoveredInput {
    <#
        Called by the driver when HasCustomInput = $true.
        Show-FieldPrompt and Invoke-EntitySearch are available because this module is dot-sourced into the driver scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Pending Account to Delete' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  WARNING: This removes the account from the Pending list and cannot be undone.' -ForegroundColor Red
    Write-Host '  It comes back only if a later discovery scan finds it again.' -ForegroundColor Red
    Write-Host ''

    $id = Show-FieldPrompt -Label 'Discovered Account ID' `
        -Default $(if ($Defaults['DiscoveredAccountID']) { $Defaults['DiscoveredAccountID'] } else { '' }) `
        -Description 'ID from List Discovered Accounts, or leave blank to search by username or address.'

    if (-not $id) {
        $searchTerm = Show-FieldPrompt -Label 'Search' -Description 'Username or address of the pending account.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $id = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/DiscoveredAccounts' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'value' `
                -IdProperty 'id' `
                -DisplayProperties @('userName', 'address', 'platformType') `
                -EntityLabel 'pending account' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $id) { return $null }
    }

    return @{ DiscoveredAccountID = $id }
}

function Invoke-AccountsDeleteDiscovered {
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

    $id = if ($InputData['DiscoveredAccountID']) { "$($InputData['DiscoveredAccountID'])".Trim() } else { '' }
    if (-not $id) {
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-AccountsDeleteDiscovered: DiscoveredAccountID is required but was not provided.'
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = 'DiscoveredAccountID is required.'; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # Only DELETE /{id}: the Swagger's DELETE /API/DiscoveredAccounts (clear the whole list) is
    # deliberately not offered.
    $endpoint = "/API/DiscoveredAccounts/$([Uri]::EscapeDataString($id))"
    Write-CyberArkLog -Level 'INFO'  -Message "Starting delete of discovered account ID: $id"
    Write-CyberArkLog -Level 'DEBUG' -Message "DELETE $endpoint"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: DELETE $endpoint would be performed."
        $result.Results.Add([PSCustomObject]@{ DiscoveredAccountID = $id; Status = 'WhatIf' })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI -Token $Token -Method 'DELETE' -Endpoint $endpoint

    if (-not $response.IsSuccess) {
        $hint = if ($response.StatusCode -eq 404) { ' (If the ID is right, the PVWA may be older than 12.1, which added deleting pending accounts.)' } else { '' }
        $msg  = "Delete failed for discovered account ID $id (HTTP $($response.StatusCode)): $($response.ErrorMessage)$hint"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $response.ErrorDetails })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        return $result
    }

    $result.Results.Add([PSCustomObject]@{ DiscoveredAccountID = $id; Status = 'Deleted' })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Delete complete for discovered account ID: $id."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
