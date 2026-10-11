#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Get Discovered Account'
    Category         = 'Accounts'
    Action           = 'GetDiscovered'
    Description      = 'Show one Pending (discovered) account, with its dependencies and trusts.'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'DiscoveredAccountID'; Required = $true; Description = 'ID of the pending account (from List Discovered Accounts).' }
    )
    Priority         = 51
    Version          = '1.0.0'
}

function Get-AccountsGetDiscoveredInput {
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

function Invoke-AccountsGetDiscovered {
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
        Write-CyberArkLog -Level 'ERROR' -Message 'Invoke-AccountsGetDiscovered: DiscoveredAccountID is required but was not provided.'
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = 'DiscoveredAccountID is required.'; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $endpoint = "/API/DiscoveredAccounts/$([Uri]::EscapeDataString($id))"
    Write-CyberArkLog -Level 'INFO'  -Message "Starting discovered account retrieval for ID: $id"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET $endpoint"

    $response = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint $endpoint -PageSize 0

    if (-not $response.IsSuccess) {
        $hint = if ($response.StatusCode -eq 404) { ' (If the ID is right, the PVWA may be older than 11.6, which added the Pending Accounts API.)' } else { '' }
        $msg  = "Discovered account get failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)$hint"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $response.ErrorDetails })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        return $result
    }

    if ($null -eq $response.Data) {
        $msg = "Discovered account get returned HTTP $($response.StatusCode) with no account data for ID: $id."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $result.Results.Add((ConvertTo-CyberArkDiscoveredAccountRow -Account $response.Data -Extended))
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Discovered account get complete for ID: $id."
    return $result
}
