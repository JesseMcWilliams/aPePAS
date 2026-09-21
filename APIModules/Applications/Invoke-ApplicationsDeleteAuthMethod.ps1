#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Delete Application Authentication Method'
    Category         = 'Applications'
    Action           = 'DeleteAuthMethod'
    Description      = 'Delete an authentication method from a CyberArk application.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AppID';  Required = $true; Description = 'Application ID, or leave blank to search.' }
        @{ Column = 'AuthID'; Required = $true; Description = 'Authentication method ID to delete.' }
    )
    Priority         = 91
    Version          = '1.0.0'
}

function Get-ApplicationsDeleteAuthMethodInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Delete Application Authentication Method' -ForegroundColor DarkGray
    Write-Host ''

    # Step 1 - resolve AppID
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

    # Step 2 - list auth methods inline so user can pick
    $authId = ''

    if ($Defaults['AuthID']) {
        $authId = "$($Defaults['AuthID'])"
    } else {
        $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
        $encodedApp = [Uri]::EscapeDataString($appId)

        try {
            $authResponse = Invoke-CyberArkAPI -Token $Token -Method 'GET' `
                -Endpoint "/WebServices/PIMServices.svc/Applications/$encodedApp/Authentications/" `
                -IgnoreSSL:$ignoreSSL
        } catch {
            Write-Host "    Error retrieving auth methods: $_" -ForegroundColor Red
            return $null
        }

        if (-not $authResponse -or -not $authResponse.IsSuccess) {
            $errMsg = if ($authResponse) { $authResponse.ErrorMessage } else { '(no response)' }
            Write-Host "    Failed to retrieve auth methods: $errMsg" -ForegroundColor Red
            return $null
        }

        $auths = @()
        if ($authResponse.Data -and $authResponse.Data.PSObject.Properties['authentication']) {
            $raw = $authResponse.Data.authentication
            if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string])) {
                $auths = @($raw)
            } elseif ($raw) {
                $auths = @($raw)
            }
        }

        if ($auths.Count -eq 0) {
            Write-Host "    No authentication methods found for '$appId'." -ForegroundColor Yellow
            return $null
        }

        Write-Host ''
        Write-Host "    Authentication methods for '$appId':" -ForegroundColor Cyan
        Write-Host ''
        for ($i = 0; $i -lt $auths.Count; $i++) {
            $a       = $auths[$i]
            $aId     = if ($a.PSObject.Properties['authID']    -and $a.authID)    { $a.authID }    else { '?' }
            $aType   = if ($a.PSObject.Properties['authType']  -and $a.authType)  { $a.authType }  else { '?' }
            $aValue  = if ($a.PSObject.Properties['authValue'] -and $a.authValue) { $a.authValue } else { '' }
            Write-Host "    [$($i + 1)]  ID: $aId  |  Type: $aType  |  Value: $aValue" -ForegroundColor White
        }
        Write-Host ''
        $sel = Read-MenuChoice -Prompt "Select authentication method to delete [1-$($auths.Count)] or B to cancel"

        if ($sel -match '^\d+$') {
            $idx = [int]$sel - 1
            if ($idx -ge 0 -and $idx -lt $auths.Count) {
                $picked = $auths[$idx]
                if ($picked.PSObject.Properties['authID'] -and $null -ne $picked.authID) {
                    $authId = "$($picked.authID)"
                }
            }
        }

        if (-not $authId) { return $null }
    }

    return @{
        AppID  = $appId
        AuthID = $authId
    }
}

function Invoke-ApplicationsDeleteAuthMethod {
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

    $appId  = if ($InputData['AppID'])  { "$($InputData['AppID'])".Trim()  } else { '' }
    $authId = if ($InputData['AuthID']) { "$($InputData['AuthID'])".Trim() } else { '' }

    if (-not $appId) {
        $msg = 'Invoke-ApplicationsDeleteAuthMethod: AppID is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = 'AppID is required.'; ErrorDetails = $null })
        $result.Failures++; $result.ItemsProcessed++
        return $result
    }
    if (-not $authId) {
        $msg = 'Invoke-ApplicationsDeleteAuthMethod: AuthID is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = 'AuthID is required.'; ErrorDetails = $null })
        $result.Failures++; $result.ItemsProcessed++
        return $result
    }

    $encodedApp  = [Uri]::EscapeDataString($appId)
    $encodedAuth = [Uri]::EscapeDataString($authId)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting delete auth method ID $authId for App ID: $appId"
    Write-CyberArkLog -Level 'DEBUG' -Message "DELETE /WebServices/PIMServices.svc/Applications/$appId/Authentications/$authId"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: DELETE auth method '$authId' for App '$appId' would be performed."
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'DELETE' `
        -Endpoint "/WebServices/PIMServices.svc/Applications/$encodedApp/Authentications/$encodedAuth/" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Delete Auth Method failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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
        AuthID = $authId
        Status = 'Deleted'
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Delete Auth Method complete. App ID: $appId, Auth ID: $authId."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
