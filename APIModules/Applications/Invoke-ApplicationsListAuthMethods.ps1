#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Application Authentication Methods'
    Category         = 'Applications'
    Action           = 'ListAuthMethods'
    Description      = 'Retrieve authentication methods for one application, or for every application if none is specified.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AppID'; Required = $false; Description = 'Application ID, or leave blank to list auth methods for every application.' }
    )
    Priority         = 89
    Version          = '1.1.0'
}

function Get-ApplicationsListAuthMethodsInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  List Application Authentication Methods' -ForegroundColor DarkGray
    Write-Host ''

    $appId = Show-FieldPrompt -Label 'App ID' `
        -Default $(if ($Defaults['AppID']) { $Defaults['AppID'] } else { '' }) `
        -Description 'Application ID, or leave blank to list auth methods for EVERY application (or search by name below).'

    if (-not $appId) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Partial Application ID to search for one specific application. Leave this blank too (with App ID blank) to list every application.'
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
            # A search was attempted but nothing was found/selected - cancel rather than
            # silently falling back to "every application", which could be a much bigger and
            # slower operation than the user searching for one specific app intended.
            if (-not $appId) { return $null }
        }
        # else: App ID and Search were both left blank - fall through with $appId = '',
        # meaning "every application", per InputSchema's documented AppID contract.
    }

    return @{ AppID = $appId }
}

function Invoke-ApplicationsListAuthMethods {
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

    if ($appId) {
        $appIds = @($appId)
    } else {
        Write-CyberArkLog -Level 'INFO' -Message 'Invoke-ApplicationsListAuthMethods: no AppID specified - listing auth methods for every application.'
        Write-CyberArkLog -Level 'DEBUG' -Message 'GET /WebServices/PIMServices.svc/Applications/'

        $listResp = Invoke-CyberArkAPI `
            -Token    $Token `
            -Method   'GET' `
            -Endpoint '/WebServices/PIMServices.svc/Applications/' `
            -WhatIf:  $WhatIf.IsPresent

        if (-not $listResp.IsSuccess) {
            $msg = "Application list failed (HTTP $($listResp.StatusCode)): $($listResp.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = $InputData
                ErrorMessage = $listResp.ErrorMessage
                ErrorDetails = $listResp.ErrorDetails
            })
            $result.Failures++
            $result.ItemsProcessed++
            $result.IsFatal = ($listResp.StatusCode -in @(401, 0))
            return $result
        }

        # Response: { "application": [ {...}, ... ] } - same shape as Invoke-ApplicationsList.ps1
        $apps = @()
        if ($listResp.Data -and $listResp.Data.PSObject.Properties['application']) {
            $raw = $listResp.Data.application
            if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string])) {
                $apps = @($raw)
            } elseif ($raw) {
                $apps = @($raw)
            }
        }

        $appIds = @($apps | ForEach-Object {
            if ($_.PSObject.Properties['AppID'] -and $_.AppID) { "$($_.AppID)" }
        } | Where-Object { $_ })

        if ($appIds.Count -eq 0) {
            Write-CyberArkLog -Level 'WARN' -Message 'Invoke-ApplicationsListAuthMethods: no applications found.'
            return $result
        }
    }

    foreach ($id in $appIds) {
        $encodedId = [Uri]::EscapeDataString($id)

        Write-CyberArkLog -Level 'INFO'  -Message "Starting auth methods retrieval for App ID: $id"
        Write-CyberArkLog -Level 'DEBUG' -Message "GET /WebServices/PIMServices.svc/Applications/$id/Authentications"

        $response = Invoke-CyberArkAPI `
            -Token    $Token `
            -Method   'GET' `
            -Endpoint "/WebServices/PIMServices.svc/Applications/$encodedId/Authentications/" `
            -WhatIf:  $WhatIf.IsPresent

        if (-not $response.IsSuccess) {
            $msg = "List Auth Methods failed for App ID '$id' (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{
                InputData    = $InputData
                ErrorMessage = $response.ErrorMessage
                ErrorDetails = $response.ErrorDetails
            })
            $result.Failures++
            $result.ItemsProcessed++
            if ($response.StatusCode -in @(401, 0)) {
                # Matches the established convention elsewhere in this codebase (e.g.
                # Invoke-CustomExportGroupMembersLocal.ps1): a 401/network error anywhere in a
                # multi-item loop is fatal and stops the whole run immediately, rather than
                # continuing to the next application.
                $result.IsFatal = $true
                return $result
            }
            continue
        }

        # Response: { "authentication": [ {...}, ... ] }
        $auths = @()
        if ($response.Data -and $response.Data.PSObject.Properties['authentication']) {
            $raw = $response.Data.authentication
            if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string])) {
                $auths = @($raw)
            } elseif ($raw) {
                $auths = @($raw)
            }
        }

        if ($auths.Count -eq 0) {
            Write-CyberArkLog -Level 'WARN' -Message "No authentication methods found for App ID: $id"
            continue
        }

        foreach ($auth in $auths) {
            try {
                $result.Results.Add([PSCustomObject]@{
                    AppID                = $id
                    AuthID               = if ($auth.PSObject.Properties['authID'])               { $auth.authID }               else { '' }
                    AuthType             = if ($auth.PSObject.Properties['authType'])              { $auth.authType }             else { '' }
                    AuthValue            = if ($auth.PSObject.Properties['authValue'])             { $auth.authValue }            else { '' }
                    IsFolder             = if ($auth.PSObject.Properties['isFolder'])              { $auth.isFolder }             else { $false }
                    AllowInternalScripts = if ($auth.PSObject.Properties['allowInternalScripts'])  { $auth.allowInternalScripts } else { $false }
                    Comment              = if ($auth.PSObject.Properties['comment'])               { $auth.comment }              else { '' }
                })
                $result.Successes++
                $result.ItemsProcessed++
            } catch {
                $authId = try { "$($auth.authID)" } catch { '(unknown)' }
                $msg = "Unexpected error mapping auth method '$authId' for App ID '$id': $_"
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
    }

    Write-CyberArkLog -Level 'INFO' -Message "List Auth Methods complete. Applications checked: $($appIds.Count). Methods retrieved: $($result.Successes)."
    return $result
}
