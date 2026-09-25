#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Delete Safe'
    Category         = 'Safes'
    Action           = 'Delete'
    Description      = 'Permanently delete an existing safe and all its contents.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName'; Required = $true; Description = 'Name of the safe to delete.' }
    )
    Priority         = 14
    Version          = '1.1.0'
}

function Get-SafesDeleteInput {
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

    Write-Host '  Safe to Delete' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  WARNING: This operation permanently deletes the safe and all its accounts.' -ForegroundColor Red
    Write-Host ''

    $safeName = Show-FieldPrompt -Label 'SafeName' `
        -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' }) `
        -Required $true `
        -Description 'Name of the safe to delete.'

    return @{
        SafeName = $safeName
    }
}

function script:Get-SafesDeleteRenameFallback {
    <#
        Called by Invoke-SafesDelete when the delete fails with HTTP 409 - see the caller for why.
        Explains the likely cause and asks whether to rename the safe instead, so it's clearly
        marked for later deletion rather than left under its original name. Renames to
        "1_DEL_<SafeName>" (truncated so the total stays within CyberArk's 28-character safe name
        limit) and, if a description already exists, appends a note with today's date.

        NOTE: this uses a plain Read-Host prompt (not a driver-scope helper), so it also works
        when this module is dot-sourced standalone (unit tests) - but it also means a CSV batch
        run deleting several safes will pause waiting for console input if any one of them hits
        this same 409, since there is no separate "interactive vs. batch" signal available here -
        except in automation mode (Manage-Privilege.ps1's $script:AutomationMode), which this
        function checks directly and skips the prompt for, returning $null exactly as if the user
        had declined - the caller's existing "report the original 409 as a plain Failure" path is
        unchanged either way. See Claude_Docs\Reference_API-Module-Guide.md for this convention.

        Returns $null if the user declines (or automation mode skips the prompt), otherwise a
        PSCustomObject: { Renamed = [bool]; NewSafeName = [string]; ErrorMessage = [string] }.
    #>
    param(
        [Parameter(Mandatory = $true)] [PSCustomObject]$Token,
        [Parameter(Mandatory = $true)] [string]$SafeName
    )

    # Get-Variable ... -ErrorAction SilentlyContinue, not a direct $script:AutomationMode
    # reference - this module is also dot-sourced standalone by its own unit tests (see above),
    # where that variable was never set at all; under Set-StrictMode a direct reference to an
    # unset variable throws, it does not just evaluate falsy.
    $automationVar = Get-Variable -Name 'AutomationMode' -Scope 'Script' -ErrorAction SilentlyContinue
    if ($automationVar -and $automationVar.Value) { return $null }

    Write-Host ''
    Write-Host "  Could not delete safe '$SafeName' (HTTP 409 Conflict)." -ForegroundColor Yellow
    Write-Host '  This can happen even when the safe currently has no accounts - Safe History' -ForegroundColor Yellow
    Write-Host '  Retention marks each account with the retention settings active when it was' -ForegroundColor Yellow
    Write-Host '  added, so a safe whose accounts were added under different retention settings' -ForegroundColor Yellow
    Write-Host '  over time can end up with history CyberArk will not fully purge.' -ForegroundColor Yellow
    Write-Host ''
    $choice = Read-Host "  Rename the safe instead, so it's clearly marked for deletion later? [Y/N]"

    if ($choice -notmatch '^[Yy]') {
        return $null
    }

    $encodedSafeName = [Uri]::EscapeDataString($SafeName)
    $getResponse = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint "/API/Safes/$encodedSafeName"
    if (-not $getResponse.IsSuccess) {
        return [PSCustomObject]@{
            Renamed      = $false
            NewSafeName  = $null
            ErrorMessage = "Could not read safe before renaming (HTTP $($getResponse.StatusCode)): $($getResponse.ErrorMessage)"
        }
    }
    $currentSafe = $getResponse.Data

    # "1_DEL_" prefix per user direction - truncate the original name (not the prefix) so the
    # total stays at or under CyberArk's 28-character safe name limit (confirmed via psPAS's
    # Set-PASSafe.ps1 [ValidateLength(0, 28)]).
    $prefix        = '1_DEL_'
    $maxNameLength = 28 - $prefix.Length
    $truncatedName = if ($SafeName.Length -gt $maxNameLength) { $SafeName.Substring(0, $maxNameLength) } else { $SafeName }
    $newSafeName   = "$prefix$truncatedName"

    # Per user direction: add the delete-requested date to the description only if one already
    # exists - a safe with no description is left without one.
    $currentDescription = if ($currentSafe.description) { "$($currentSafe.description)" } else { '' }
    $newDescription = if ($currentDescription) { "$currentDescription | Delete requested $(Get-Date -Format 'yyyy-MM-dd')" } else { $currentDescription }

    # Full-replace PUT, same pattern as Invoke-SafesUpdate.ps1 - SafeName in the body (not just
    # the URL) both satisfies this PVWA version's requirement (see F33) and is how a rename is
    # actually requested: the URL identifies the safe being updated, the body's SafeName sets
    # its new name.
    $body = @{
        SafeName         = $newSafeName
        Description      = $newDescription
        Location         = if ($currentSafe.location) { $currentSafe.location } else { '' }
        ManagingCPM      = if ($currentSafe.managingCPM) { $currentSafe.managingCPM } else { '' }
        AutoPurgeEnabled = [bool]$currentSafe.autoPurgeEnabled
    }
    if ([int]$currentSafe.numberOfDaysRetention -gt 0) {
        $body['NumberOfDaysRetention'] = [int]$currentSafe.numberOfDaysRetention
    } else {
        $body['NumberOfVersionsRetention'] = [int]$currentSafe.numberOfVersionsRetention
    }

    $putResponse = Invoke-CyberArkAPI -Token $Token -Method 'PUT' -Endpoint "/API/Safes/$encodedSafeName" -Body $body
    if (-not $putResponse.IsSuccess) {
        return [PSCustomObject]@{
            Renamed      = $false
            NewSafeName  = $null
            ErrorMessage = "Rename PUT failed (HTTP $($putResponse.StatusCode)): $($putResponse.ErrorMessage)"
        }
    }

    Write-CyberArkLog -Level 'INFO' -Message "Safe '$SafeName' renamed to '$newSafeName' instead of being deleted (HTTP 409 rename fallback)."
    return [PSCustomObject]@{ Renamed = $true; NewSafeName = $newSafeName; ErrorMessage = $null }
}

function Invoke-SafesDelete {
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
        $msg = 'InputData is null or missing. SafeName is required.'
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

    $encodedSafeName = [Uri]::EscapeDataString($safeName)
    $endpoint        = "/API/Safes/$encodedSafeName"

    Write-CyberArkLog -Level 'INFO'  -Message "Starting safe delete. SafeName='$safeName'."
    Write-CyberArkLog -Level 'DEBUG' -Message "DELETE $endpoint"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: DELETE $endpoint would be performed."
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token   $Token `
        -Method  'DELETE' `
        -Endpoint $endpoint

    if (-not $response.IsSuccess) {
        $msg = "Safe delete failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg

        # HTTP 409 on Safe delete has been confirmed live even when the safe's own GET shows zero
        # accounts. The most likely cause is Safe History Retention: each account is marked with
        # the retention settings active on the safe at the time it was added, so a safe whose
        # accounts were added under different retention settings over time can end up with mixed
        # per-account history that CyberArk won't fully purge - blocking the safe delete even
        # though no live accounts remain. There is no documented way to force this from the API
        # side (confirmed against psPAS's own Remove-PASSafe.ps1, which has no such option
        # either), so offer a rename-instead fallback rather than just failing outright.
        if ($response.StatusCode -eq 409) {
            $renameResult = Get-SafesDeleteRenameFallback -Token $Token -SafeName $safeName
            if ($renameResult) {
                if ($renameResult.Renamed) {
                    $result.Results.Add([PSCustomObject]@{
                        SafeName    = $safeName
                        NewSafeName = $renameResult.NewSafeName
                        Deleted     = $false
                        Renamed     = $true
                    })
                    $result.Successes++
                    $result.ItemsProcessed++
                    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
                    return $result
                } else {
                    $msg = "$msg Rename fallback also failed: $($renameResult.ErrorMessage)"
                    Write-CyberArkLog -Level 'ERROR' -Message $msg
                }
            }
        }

        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $msg
            ErrorDetails = $response.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        return $result
    }

    # Success - 204 No Content or 200 OK
    $result.Results.Add([PSCustomObject]@{
        SafeName = $safeName
        Deleted  = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Safe delete complete. SafeName='$safeName'."

    Add-CyberArkLogSummaryEntry `
        -ModuleName     $ModuleMeta.Name `
        -ItemsProcessed $result.ItemsProcessed `
        -Successes      $result.Successes `
        -Failures       $result.Failures

    return $result
}
