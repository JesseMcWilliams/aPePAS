#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Reports'
    Category         = 'Reports'
    Action           = 'List'
    # Self-Hosted only - confirmed by the user against a live ISPSS/Privilege Cloud tenant,
    # which returns HTTP 404 for this endpoint (GET /API/Reports). Phase 1 (earlier this
    # session) had expanded this to dual-use based on psPAS's own comparison review claiming
    # ISPSS support from v14.6+; that claim did not hold up against a real tenant.
    Description      = 'Retrieve CyberArk PVWA reports. Self-Hosted only.'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @()
    Priority         = 70
    Version          = '1.2.0'
}

function Get-ReportsListInput {
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

    Write-Host '  Search Criteria  (press Enter to skip each field)' -ForegroundColor DarkGray
    Write-Host ''

    $search = Show-FieldPrompt -Label 'Search' `
        -Default $(if ($Defaults['Search']) { $Defaults['Search'] } else { '' }) `
        -Description 'Free-text search across report name. Leave blank for all reports.'

    return @{
        Search = $search
    }
}

function Invoke-ReportsList {
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

    $search = if ($InputData['Search']) { "$($InputData['Search'])".Trim() } else { $null }

    $queryParams = @{}
    if ($search) { $queryParams['search'] = $search }

    $criteriaLog = if ($search) { "Search='$search'" } else { '(all reports)' }

    Write-CyberArkLog -Level 'INFO'  -Message 'Starting report list retrieval.'
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Reports | $criteriaLog"

    $response = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/API/Reports' `
        -QueryParams $queryParams `
        -WhatIf:     $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Report list failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    [array]$reports = if ($response.Data -and $response.Data.PSObject.Properties['value']) {
        @($response.Data.value)
    } else { @() }

    if ((-not $reports) -or $reports.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message 'No reports returned for the given criteria.'
        return $result
    }

    foreach ($report in $reports) {
        try {
            # Every field is guarded with PSObject.Properties[...] (matching the convention used
            # throughout the rest of this codebase - see Lessons-Learned-PowerShell-Pester.md
            # Section 4/24): a report missing any one optional field would otherwise throw
            # PropertyNotFoundException under Set-StrictMode (always active via
            # Manage-Privilege.ps1), silently converting a successful row into a Failures entry
            # and corrupting ItemsProcessed/Successes/Failures and the output CSV.
            $result.Results.Add([PSCustomObject]@{
                ReportID    = if ($report.PSObject.Properties['reportId'])    { $report.reportId }    else { '' }
                ReportName  = if ($report.PSObject.Properties['reportName'])  { $report.reportName }  else { '' }
                Description = if ($report.PSObject.Properties['description']) { $report.description } else { '' }
                ReportType  = if ($report.PSObject.Properties['reportType'])  { $report.reportType }  else { '' }
                RunDate     = if ($report.PSObject.Properties['runDate'])     { $report.runDate }     else { '' }
                Aggregated  = if ($report.PSObject.Properties['aggregated'])  { [bool]$report.aggregated } else { $false }
            })
            $result.Successes++
            $result.ItemsProcessed++
        } catch {
            $reportId = try { "$($report.reportId)" } catch { '(unknown)' }
            $msg = "Unexpected error mapping report '$reportId': $_"
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

    Write-CyberArkLog -Level 'INFO' -Message "Report list complete. Reports retrieved: $($result.Successes)."
    return $result
}
