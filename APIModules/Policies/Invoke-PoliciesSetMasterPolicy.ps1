#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Set Master Policy'
    Category         = 'Policies'
    Action           = 'SetMasterPolicy'
    # Self-Hosted only, matching psPAS's Set-PASMasterPolicy.ps1, which explicitly asserts
    # -SelfHosted and PVWA 14.6+. Field names, types, and range limits (ConfirmersNumber 1-64;
    # PasswordChangeDays/PasswordVerificationDays 1-3650; RetentionPeriod 0-3650) confirmed
    # against the CyberArk 14.6 self-hosted Swagger spec's UpdatePolicyRequest schema for
    # PUT /API/Policies/{policyId}.
    Description      = 'Update one or more Master Policy fields (Self-Hosted PVWA 14.6+ only), matching psPAS''s Set-PASMasterPolicy.ps1.'
    SupportedSystems = @('SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'PolicyId';                      Required = $false; Description = 'Policy ID to update. Defaults to 1 (the Master Policy).' }
        @{ Column = 'DualControl';                    Required = $false; Description = 'Dual control policy (true/false). Leave blank to keep the current value.' }
        @{ Column = 'MultiLevelApproval';             Required = $false; Description = 'Multi-level approval policy (true/false). Leave blank to keep the current value.' }
        @{ Column = 'OnlyManagersApproval';           Required = $false; Description = 'Only-managers-approval policy (true/false). Leave blank to keep the current value.' }
        @{ Column = 'ConfirmersNumber';                Required = $false; Description = 'Number of confirmers required (1-64). Leave blank to keep the current value.' }
        @{ Column = 'EnforceExclusiveAccess';          Required = $false; Description = 'Enforce exclusive access policy (true/false). Leave blank to keep the current value.' }
        @{ Column = 'EnforceOneTimePassword';          Required = $false; Description = 'Enforce one-time password policy (true/false). Leave blank to keep the current value.' }
        @{ Column = 'TransparentConnection';           Required = $false; Description = 'Transparent connection policy (true/false). Leave blank to keep the current value.' }
        @{ Column = 'AllowViewPassword';                Required = $false; Description = 'Allow view password policy (true/false). Leave blank to keep the current value.' }
        @{ Column = 'RequireReason';                    Required = $false; Description = 'Require reason policy (true/false). Leave blank to keep the current value.' }
        @{ Column = 'AllowFreeText';                    Required = $false; Description = 'Allow free text policy (true/false). Leave blank to keep the current value.' }
        @{ Column = 'PasswordChangeDays';               Required = $false; Description = 'Password change interval in days (1-3650). Leave blank to keep the current value.' }
        @{ Column = 'PasswordVerificationDays';         Required = $false; Description = 'Password verification interval in days (1-3650). Leave blank to keep the current value.' }
        @{ Column = 'RequireMonitoringAndIsolation';   Required = $false; Description = 'Require monitoring and isolation policy (true/false). Leave blank to keep the current value.' }
        @{ Column = 'RecordActivity';                   Required = $false; Description = 'Record activity policy (true/false). Leave blank to keep the current value.' }
        @{ Column = 'RetentionPeriod';                  Required = $false; Description = 'Session recording retention period in days (0-3650). Leave blank to keep the current value.' }
    )
    Priority         = 91
    Version          = '1.0.0'
}

# Every Master Policy field is wrapped as { Value: ... } on the wire - flatten to plain
# values. Guarded against a missing field/wrapper per Lessons-Learned-PowerShell-Pester.md
# Section 27 ($null.PSObject access under Set-StrictMode). Duplicated from
# Invoke-PoliciesGetMasterPolicy.ps1 rather than shared, matching this codebase's established
# convention of keeping each API module file self-contained (see e.g.
# Invoke-AccountsCancelCpmTask.ps1 / Invoke-AccountsResumeAutoManagement.ps1's duplicated
# AccountName->AccountID resolution).
function script:Get-FlatPolicyValue {
    param($Policy, [string]$Field)
    if ($null -eq $Policy -or -not $Policy.PSObject.Properties[$Field]) { return $null }
    $wrapper = $Policy.$Field
    if ($null -eq $wrapper) { return $null }
    if ($wrapper.PSObject.Properties['Value']) { return $wrapper.Value }
    return $wrapper
}

# Boolean fields (true/false CSV columns) and integer fields (with their valid ranges),
# per the UpdatePolicyRequest schema referenced above.
$script:MasterPolicyBoolFields = @(
    'DualControl', 'MultiLevelApproval', 'OnlyManagersApproval', 'EnforceExclusiveAccess',
    'EnforceOneTimePassword', 'TransparentConnection', 'AllowViewPassword', 'RequireReason',
    'AllowFreeText', 'RequireMonitoringAndIsolation', 'RecordActivity'
)
$script:MasterPolicyIntFields = @{
    ConfirmersNumber         = @{ Min = 1; Max = 64 }
    PasswordChangeDays       = @{ Min = 1; Max = 3650 }
    PasswordVerificationDays = @{ Min = 1; Max = 3650 }
    RetentionPeriod          = @{ Min = 0; Max = 3650 }
}

function Get-PoliciesSetMasterPolicyInput {
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

    Write-Host '  Set Master Policy  (press Enter to leave a field unchanged)' -ForegroundColor DarkGray
    Write-Host ''

    $inputData = @{
        PolicyId = Show-FieldPrompt -Label 'Policy ID' `
            -Default $(if ($Defaults['PolicyId']) { $Defaults['PolicyId'] } else { '1' }) `
            -Description 'Policy ID to update. Leave as 1 for the Master Policy.'
    }

    foreach ($field in $script:MasterPolicyBoolFields) {
        $inputData[$field] = Show-FieldPrompt -Label $field `
            -Default $(if ($Defaults[$field]) { $Defaults[$field] } else { '' }) `
            -Description "$field (true/false). Leave blank to keep the current value."
    }

    foreach ($field in $script:MasterPolicyIntFields.Keys) {
        $range = $script:MasterPolicyIntFields[$field]
        $inputData[$field] = Show-FieldPrompt -Label $field `
            -Default $(if ($Defaults[$field]) { $Defaults[$field] } else { '' }) `
            -Description "$field ($($range.Min)-$($range.Max)). Leave blank to keep the current value."
    }

    return $inputData
}

function Invoke-PoliciesSetMasterPolicy {
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

    $policyIdRaw = if ($InputData['PolicyId']) { "$($InputData['PolicyId'])".Trim() } else { '1' }
    $policyId    = 1
    if (-not [int]::TryParse($policyIdRaw, [ref]$policyId)) {
        $msg = "PolicyId '$policyIdRaw' is not a valid integer."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # Parse and validate every supplied field before touching the API - a bad value fails fast
    # with a clear, non-fatal message instead of a late, unclear error from the server.
    $updates = @{}

    foreach ($field in $script:MasterPolicyBoolFields) {
        $raw = "$($InputData[$field])".Trim()
        if ($raw) {
            # Never cast a CSV-sourced string directly to [bool] - see
            # Lessons-Learned-PowerShell-Pester.md Section 31.1.
            $updates[$field] = ($raw -match '(?i)^(true|yes|y|1)$')
        }
    }

    foreach ($field in $script:MasterPolicyIntFields.Keys) {
        $raw = "$($InputData[$field])".Trim()
        if ($raw) {
            $parsed = 0
            if (-not [int]::TryParse($raw, [ref]$parsed)) {
                $msg = "$field '$raw' is not a valid integer."
                Write-CyberArkLog -Level 'ERROR' -Message $msg
                $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
                $result.Failures++
                $result.ItemsProcessed++
                return $result
            }
            $range = $script:MasterPolicyIntFields[$field]
            if ($parsed -lt $range.Min -or $parsed -gt $range.Max) {
                $msg = "$field '$parsed' is out of range ($($range.Min)-$($range.Max))."
                Write-CyberArkLog -Level 'ERROR' -Message $msg
                $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
                $result.Failures++
                $result.ItemsProcessed++
                return $result
            }
            $updates[$field] = $parsed
        }
    }

    if ($updates.Count -eq 0) {
        $msg = 'At least one Master Policy field must be supplied.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    # PUT is a full replace with no PATCH alternative - GET the current policy first and merge
    # the supplied fields over it, so fields not being changed aren't reset to their schema
    # default. Mirrors psPAS's own Set-PASMasterPolicy.ps1, which does the identical
    # GET-then-merge via Format-PutRequestObject for the same reason.
    $currentResp = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint "/API/Policies/$policyId"

    if (-not $currentResp.IsSuccess) {
        $msg = "Fetching current master policy failed (HTTP $($currentResp.StatusCode)): $($currentResp.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $currentResp.ErrorDetails })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($currentResp.StatusCode -in @(401, 0))
        return $result
    }

    $currentPolicy = $currentResp.Data
    $allFields     = @($script:MasterPolicyBoolFields) + @($script:MasterPolicyIntFields.Keys)

    $body = @{}
    foreach ($field in $allFields) {
        $body[$field] = if ($updates.ContainsKey($field)) {
            $updates[$field]
        } else {
            script:Get-FlatPolicyValue -Policy $currentPolicy -Field $field
        }
    }

    Write-CyberArkLog -Level 'INFO'  -Message "Starting master policy update for PolicyId=$policyId. Fields changed: $($updates.Keys -join ', ')."
    Write-CyberArkLog -Level 'DEBUG' -Message "PUT /API/Policies/$policyId"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: PUT /API/Policies/$policyId would be performed."
        $result.Results.Add([PSCustomObject]@{ PolicyId = $policyId; FieldsChanged = ($updates.Keys -join ', '); Updated = $true })
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'PUT' `
        -Endpoint "/API/Policies/$policyId" `
        -Body     $body

    if (-not $response.IsSuccess) {
        $msg = "Master policy update failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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
        PolicyId      = $policyId
        FieldsChanged = ($updates.Keys -join ', ')
        Updated       = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Master policy update complete for PolicyId=$policyId."

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
