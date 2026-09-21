#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Export Entitlements'
    Category         = 'Custom'
    Action           = 'ExportEntitlements'
    Description      = 'Export all safe members for every accessible safe into a single CSV file.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @()
    # Bulk export tool whose whole purpose is producing a CSV - save automatically with no
    # "Save to CSV?" prompt or file dialog, straight to the default path. See Get-CsvSavePath
    # and the ProducesOutput handling in Invoke-ActionModule (Manage-Privilege.ps1).
    AutoSaveCsv      = $true
    # No date in the saved filename - matches Custom/ExportAll's own fixed-name convention, so
    # every Custom export tool behaves the same (always the latest snapshot, overwritten on the
    # next run - use automation mode's -FilenameFormat with {Date} for dated snapshots instead).
    CsvFilenameNoDate = $true
    Priority         = 81
    Version          = '1.3.0'
}

function Get-CustomExportEntitlementsInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Export Entitlements  (press Enter to export all safes)' -ForegroundColor DarkGray
    Write-Host ''

    $safeFilter = Show-FieldPrompt -Label 'Safe Search' `
        -Default $(if ($Defaults['SafeSearch']) { $Defaults['SafeSearch'] } else { '' }) `
        -Description 'Optional: filter safes by name. Leave blank to export all safes.'

    return @{
        SafeSearch = $safeFilter
    }
}

function Invoke-CustomExportEntitlements {
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

    $safeSearch = if ($InputData['SafeSearch']) { "$($InputData['SafeSearch'])".Trim() } else { '' }

    $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }

    Write-CyberArkLog -Level 'INFO' -Message 'Export Entitlements: retrieving safe list.'
    Write-Host '  Retrieving safe list...' -ForegroundColor Cyan

    $safeParams = @{}
    if ($safeSearch) { $safeParams['search'] = $safeSearch }

    $safesResponse = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/API/Safes' `
        -QueryParams $safeParams `
        -IgnoreSSL:  $ignoreSSL

    if (-not $safesResponse.IsSuccess) {
        $msg = "Export Entitlements: safe list failed (HTTP $($safesResponse.StatusCode)): $($safesResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $safesResponse.ErrorMessage
            ErrorDetails = $safesResponse.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($safesResponse.StatusCode -in @(401, 0))
        return $result
    }

    [array]$safes = if ($safesResponse.Data -and $safesResponse.Data.PSObject.Properties['value']) {
        @($safesResponse.Data.value)
    } else { @() }

    if ((-not $safes) -or $safes.Count -eq 0) {
        Write-Host '  No safes found.' -ForegroundColor Yellow
        Write-CyberArkLog -Level 'WARN' -Message 'Export Entitlements: no safes returned.'
        return $result
    }

    Write-Host "  Found $($safes.Count) safe$(if ($safes.Count -ne 1) { 's' }). Retrieving members..." -ForegroundColor Cyan
    Write-Host ''

    $safeIndex = 0
    foreach ($safe in $safes) {
        $safeIndex++
        $safeName = if ($safe.PSObject.Properties['safeName'] -and $safe.safeName) {
            "$($safe.safeName)"
        } else { continue }

        Write-Host "  [$safeIndex/$($safes.Count)] $safeName" -ForegroundColor White -NoNewline

        $encodedSafe = [Uri]::EscapeDataString($safeName)

        $membersResponse = Invoke-CyberArkAPI `
            -Token     $Token `
            -Method    'GET' `
            -Endpoint  "/API/Safes/$encodedSafe/Members" `
            -IgnoreSSL:$ignoreSSL

        if (-not $membersResponse.IsSuccess) {
            Write-Host " - skipped (HTTP $($membersResponse.StatusCode))" -ForegroundColor Yellow
            Write-CyberArkLog -Level 'WARN' -Message "Export Entitlements: members for '$safeName' failed - $($membersResponse.ErrorMessage)"
            if ($membersResponse.StatusCode -in @(401, 0)) {
                $result.IsFatal = $true
                $result.Failures++
                $result.ItemsProcessed++
                return $result
            }
            $result.Failures++
            $result.ItemsProcessed++
            continue
        }

        [array]$members = if ($membersResponse.Data -and $membersResponse.Data.PSObject.Properties['value']) {
            @($membersResponse.Data.value)
        } else { @() }

        $memberCount = if ($members) { $members.Count } else { 0 }
        Write-Host " - $memberCount member$(if ($memberCount -ne 1) { 's' })" -ForegroundColor Green

        foreach ($member in $members) {
            try {
                $perms = if ($member.PSObject.Properties['permissions'] -and $member.permissions) {
                    $member.permissions
                } else { $null }

                $result.Results.Add([PSCustomObject]@{
                    SafeUrlId                              = if ($member.PSObject.Properties['safeUrlId'])                  { $member.safeUrlId }                  else { '' }
                    SafeName                               = $safeName
                    SafeNumber                             = if ($member.PSObject.Properties['safeNumber'])                 { $member.safeNumber }                 else { $null }
                    MemberId                               = if ($member.PSObject.Properties['memberId'])                   { $member.memberId }                   else { '' }
                    MemberName                             = if ($member.PSObject.Properties['memberName'])                 { $member.memberName }                 else { '' }
                    MemberType                             = if ($member.PSObject.Properties['memberType'])                 { $member.memberType }                 else { '' }
                    MembershipExpirationDate               = if ($member.PSObject.Properties['membershipExpirationDate'] -and $member.membershipExpirationDate) { $member.membershipExpirationDate } else { '' }
                    IsExpiredMembershipEnable              = if ($member.PSObject.Properties['isExpiredMembershipEnable'])  { $member.isExpiredMembershipEnable }  else { $false }
                    IsPredefinedUser                       = if ($member.PSObject.Properties['isPredefinedUser'])           { $member.isPredefinedUser }           else { $false }
                    UseAccounts                            = if ($perms -and $perms.PSObject.Properties['useAccounts'])                            { $perms.useAccounts }                            else { $false }
                    RetrieveAccounts                       = if ($perms -and $perms.PSObject.Properties['retrieveAccounts'])                       { $perms.retrieveAccounts }                       else { $false }
                    ListAccounts                           = if ($perms -and $perms.PSObject.Properties['listAccounts'])                           { $perms.listAccounts }                           else { $false }
                    AddAccounts                            = if ($perms -and $perms.PSObject.Properties['addAccounts'])                            { $perms.addAccounts }                            else { $false }
                    UpdateAccountContent                   = if ($perms -and $perms.PSObject.Properties['updateAccountContent'])                   { $perms.updateAccountContent }                   else { $false }
                    UpdateAccountProperties                = if ($perms -and $perms.PSObject.Properties['updateAccountProperties'])                { $perms.updateAccountProperties }                else { $false }
                    InitiateCPMAccountManagementOperations = if ($perms -and $perms.PSObject.Properties['initiateCPMAccountManagementOperations']) { $perms.initiateCPMAccountManagementOperations } else { $false }
                    SpecifyNextAccountContent              = if ($perms -and $perms.PSObject.Properties['specifyNextAccountContent'])              { $perms.specifyNextAccountContent }              else { $false }
                    RenameAccounts                         = if ($perms -and $perms.PSObject.Properties['renameAccounts'])                         { $perms.renameAccounts }                         else { $false }
                    DeleteAccounts                         = if ($perms -and $perms.PSObject.Properties['deleteAccounts'])                         { $perms.deleteAccounts }                         else { $false }
                    UnlockAccounts                         = if ($perms -and $perms.PSObject.Properties['unlockAccounts'])                         { $perms.unlockAccounts }                         else { $false }
                    ManageSafe                             = if ($perms -and $perms.PSObject.Properties['manageSafe'])                             { $perms.manageSafe }                             else { $false }
                    ManageSafeMembers                      = if ($perms -and $perms.PSObject.Properties['manageSafeMembers'])                      { $perms.manageSafeMembers }                      else { $false }
                    BackupSafe                             = if ($perms -and $perms.PSObject.Properties['backupSafe'])                             { $perms.backupSafe }                             else { $false }
                    ViewAuditLog                           = if ($perms -and $perms.PSObject.Properties['viewAuditLog'])                           { $perms.viewAuditLog }                           else { $false }
                    ViewSafeMembers                        = if ($perms -and $perms.PSObject.Properties['viewSafeMembers'])                        { $perms.viewSafeMembers }                        else { $false }
                    AccessWithoutConfirmation              = if ($perms -and $perms.PSObject.Properties['accessWithoutConfirmation'])              { $perms.accessWithoutConfirmation }              else { $false }
                    CreateFolders                          = if ($perms -and $perms.PSObject.Properties['createFolders'])                          { $perms.createFolders }                          else { $false }
                    DeleteFolders                          = if ($perms -and $perms.PSObject.Properties['deleteFolders'])                          { $perms.deleteFolders }                          else { $false }
                    MoveAccountsAndFolders                 = if ($perms -and $perms.PSObject.Properties['moveAccountsAndFolders'])                 { $perms.moveAccountsAndFolders }                 else { $false }
                    RequestsAuthorizationLevel1            = if ($perms -and $perms.PSObject.Properties['requestsAuthorizationLevel1'])            { $perms.requestsAuthorizationLevel1 }            else { $false }
                    RequestsAuthorizationLevel2            = if ($perms -and $perms.PSObject.Properties['requestsAuthorizationLevel2'])            { $perms.requestsAuthorizationLevel2 }            else { $false }
                })
                $result.Successes++
            } catch {
                $msg = "Export Entitlements: error mapping member in '$safeName': $_"
                Write-CyberArkLog -Level 'ERROR' -Message $msg
                $result.Errors.Add([PSCustomObject]@{
                    InputData    = @{ SafeName = $safeName }
                    ErrorMessage = $msg
                    ErrorDetails = $null
                })
                $result.Failures++
            }
            $result.ItemsProcessed++
        }
    }

    Write-Host ''
    $safeCount = $safeIndex
    Write-CyberArkLog -Level 'INFO' -Message "Export Entitlements complete. Safes: $safeCount, Members: $($result.Successes), Failures: $($result.Failures)."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
