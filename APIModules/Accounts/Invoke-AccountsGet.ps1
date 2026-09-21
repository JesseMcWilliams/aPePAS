#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Get Account'
    Category         = 'Accounts'
    Action           = 'Get'
    Description      = 'Retrieve full details of a single account by ID.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountName'; Required = $true;  Description = 'Account name or username. Matched locally against name and userName fields within the specified Safe.' }
        @{ Column = 'Safe';        Required = $true;  Description = 'Safe containing the account.' }
    )
    Priority         = 31
    Version          = '1.2.0'
}

function Get-AccountsGetInput {
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

    $id = Show-FieldPrompt -Label 'Account ID' `
        -Default $(if ($Defaults['AccountID']) { $Defaults['AccountID'] } else { '' }) `
        -Description 'Account ID from List Accounts, or leave blank to search by name/username/address.'

    if (-not $id) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Name, username, or address to find the account.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $id = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/Accounts' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'value' `
                -IdProperty 'id' `
                -DisplayProperties @('name', 'userName', 'address', 'safeName') `
                -EntityLabel 'account' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $id) { return $null }
    }

    return @{
        AccountID = $id
    }
}

function Invoke-AccountsGet {
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

    $accountId   = if ($InputData['AccountID'])   { "$($InputData['AccountID'])".Trim()   } else { '' }
    $accountName = if ($InputData['AccountName']) { "$($InputData['AccountName'])".Trim() } else { '' }
    $targetSafe  = if ($InputData['Safe'])        { "$($InputData['Safe'])".Trim()        } else { '' }

    if (-not $accountId) {
        if (-not $accountName) {
            $msg = 'AccountName is required when AccountID is not provided.'
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }
        if (-not $targetSafe) {
            $msg = 'Safe is required to locate the account.'
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        Write-CyberArkLog -Level 'DEBUG' -Message "Fetching accounts in safe '$targetSafe' to locate '$accountName'."

        $lookupResp = Invoke-CyberArkAPI `
            -Token       $Token `
            -Method      'GET' `
            -Endpoint    '/API/Accounts' `
            -QueryParams @{ filter = (New-CyberArkSearchFilter -Criteria @{ safeName = $targetSafe }); limit = 1000 }

        if (-not $lookupResp.IsSuccess) {
            $msg = "Account lookup failed (HTTP $($lookupResp.StatusCode)): $($lookupResp.ErrorMessage)"
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $lookupResp.ErrorDetails })
            $result.Failures++
            $result.ItemsProcessed++
            $result.IsFatal = ($lookupResp.StatusCode -in @(401, 0))
            return $result
        }

        [array]$acctList = if ($lookupResp.Data -and
                               $lookupResp.Data.PSObject.Properties['value'] -and
                               $null -ne $lookupResp.Data.value) {
            @($lookupResp.Data.value)
        } else { @() }

        $acctMatch = $acctList | Where-Object {
            $_ -and
            (($_.PSObject.Properties['name']     -and $_.name     -eq $accountName) -or
             ($_.PSObject.Properties['userName'] -and $_.userName -eq $accountName))
        }
        [array]$acctMatches = @($acctMatch)

        if (-not $acctMatches -or $acctMatches.Count -eq 0) {
            $msg = "Account '$accountName' not found in safe '$targetSafe'."
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        if ($acctMatches.Count -gt 1) {
            Write-CyberArkLog -Level 'WARN' -Message "Multiple accounts matched '$accountName' in safe '$targetSafe' - using first match."
        }

        $accountId = if ($acctMatches[0].PSObject.Properties['id']) { $acctMatches[0].id } else { '' }
        if (-not $accountId) {
            $msg = "Account '$accountName' found in safe '$targetSafe' but has no ID."
            Write-CyberArkLog -Level 'ERROR' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            $result.ItemsProcessed++
            return $result
        }

        Write-CyberArkLog -Level 'DEBUG' -Message "Resolved account ID: $accountId"
    }

    $encodedId = [Uri]::EscapeDataString($accountId)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting account retrieval for ID: $accountId"
    Write-CyberArkLog -Level 'DEBUG' -Message "GET /API/Accounts/$encodedId"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint "/API/Accounts/$encodedId" `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Account get failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
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

    $acct = $response.Data

    # secretManagement (AutomaticSecretManagement) and remoteMachinesAccess (RemoteMachinesAccess)
    # are nested objects on the AccountModel response - confirmed against the bundled
    # Swagger\CyberArk_PasswordVault_Swagger_14.6.v1.json. Flattened into top-level Results
    # columns below so nothing is lost when this gets exported to CSV.
    $secretMgmt   = if ($acct.PSObject.Properties['secretManagement'])   { $acct.secretManagement }   else { $null }
    $remoteAccess = if ($acct.PSObject.Properties['remoteMachinesAccess']) { $acct.remoteMachinesAccess } else { $null }

    $createdDate = if ($acct.PSObject.Properties['createdTime'] -and $acct.createdTime) {
        try { [DateTimeOffset]::FromUnixTimeSeconds($acct.createdTime).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    $categoryModifiedDate = if ($acct.PSObject.Properties['categoryModificationTime'] -and $acct.categoryModificationTime) {
        try { [DateTimeOffset]::FromUnixTimeSeconds($acct.categoryModificationTime).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    $deletedDate = if ($acct.PSObject.Properties['deletionTime'] -and $acct.deletionTime) {
        try { [DateTimeOffset]::FromUnixTimeSeconds($acct.deletionTime).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    $lastCPMModifiedDate = if ($secretMgmt -and $secretMgmt.PSObject.Properties['lastModifiedTime'] -and $secretMgmt.lastModifiedTime) {
        try { [DateTimeOffset]::FromUnixTimeSeconds($secretMgmt.lastModifiedTime).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    $lastReconciledDate = if ($secretMgmt -and $secretMgmt.PSObject.Properties['lastReconciledTime'] -and $secretMgmt.lastReconciledTime) {
        try { [DateTimeOffset]::FromUnixTimeSeconds($secretMgmt.lastReconciledTime).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    $lastVerifiedDate = if ($secretMgmt -and $secretMgmt.PSObject.Properties['lastVerifiedTime'] -and $secretMgmt.lastVerifiedTime) {
        try { [DateTimeOffset]::FromUnixTimeSeconds($secretMgmt.lastVerifiedTime).LocalDateTime.ToString('yyyy-MM-dd') }
        catch { '' }
    } else { '' }

    # id, name, address, userName, and secretType are all optional per the Swagger schema (only
    # platformId and safeName are required on AccountModel) - guarded the same way as the nested
    # fields below so a real account missing one of them doesn't crash this under strict mode.
    #
    # secret (the account's password/key value) is deliberately never surfaced here, even though
    # it is a field on the schema - CyberArk does not return it from this endpoint (retrieving it
    # requires the separate Invoke-AccountsGetCredential.ps1 action), and writing credentials into
    # a plaintext CSV export by default would be a security hazard regardless.
    $outRow = [ordered]@{
        AccountID              = if ($acct.PSObject.Properties['id'])         { $acct.id }         else { '' }
        AccountName            = if ($acct.PSObject.Properties['name'])       { $acct.name }       else { '' }
        Address                = if ($acct.PSObject.Properties['address'])    { $acct.address }    else { '' }
        UserName               = if ($acct.PSObject.Properties['userName'])   { $acct.userName }   else { '' }
        PlatformID             = $acct.platformId
        SafeName               = $acct.safeName
        SecretType             = if ($acct.PSObject.Properties['secretType']) { $acct.secretType } else { '' }
        AutoManaged            = if ($secretMgmt -and $secretMgmt.PSObject.Properties['automaticManagementEnabled']) { $secretMgmt.automaticManagementEnabled } else { $false }
        CPMStatus              = if ($secretMgmt -and $secretMgmt.PSObject.Properties['status']) { $secretMgmt.status } else { '' }
        ManualReason           = if ($secretMgmt -and $secretMgmt.PSObject.Properties['manualManagementReason']) { $secretMgmt.manualManagementReason } else { '' }
        LastCPMModified        = $lastCPMModifiedDate
        LastReconciled         = $lastReconciledDate
        LastVerified           = $lastVerifiedDate
        RemoteMachines         = if ($remoteAccess -and $remoteAccess.PSObject.Properties['remoteMachines']) { $remoteAccess.remoteMachines } else { '' }
        RemoteAccessRestricted = if ($remoteAccess -and $remoteAccess.PSObject.Properties['accessRestrictedToRemoteMachines']) { $remoteAccess.accessRestrictedToRemoteMachines } else { $false }
        CategoryModified       = $categoryModifiedDate
        Deleted                = $deletedDate
        Created                = $createdDate
    }

    # platformAccountProperties is a free-form object whose keys vary per platform (e.g.
    # LogonDomain, Port) - not a fixed schema, confirmed against the bundled Swagger spec
    # (additionalProperties: string). Flatten every key onto its own column, prefixed
    # "Platform_" so it can never collide with a fixed column name above.
    if ($acct.PSObject.Properties['platformAccountProperties'] -and $acct.platformAccountProperties) {
        foreach ($prop in $acct.platformAccountProperties.PSObject.Properties) {
            $outRow["Platform_$($prop.Name)"] = $prop.Value
        }
    }

    $result.Results.Add([PSCustomObject]$outRow)
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Account get complete. Account retrieved: $accountId."
    return $result
}
