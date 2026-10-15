#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Retrieve SSH Key'
    Category         = 'Accounts'
    MenuGroup        = 'Access and retrieval'
    Action           = 'RetrieveSshKey'
    Description      = 'Retrieve an SSH key account''s private key and save it to a file in the Output Folder. The key is never shown, logged or written to the results CSV.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'AccountID';       Required = $false; Description = 'Account ID. Give this, or AccountName and/or UserName with Safe. When set, the other identifier columns are ignored.' }
        @{ Column = 'AccountName';     Required = $false; Description = 'Account (object) name: the name field, not the username. An ObjectName column is also accepted. Needs Safe.' }
        @{ Column = 'UserName';        Required = $false; Description = 'Account username. Needs Safe. With AccountName, the account must match both. More than one match fails the row.' }
        @{ Column = 'Safe';            Required = $false; Description = 'Safe containing the account. Required unless AccountID is set.' }
        @{ Column = 'Reason';          Required = $false; Description = 'Reason for the retrieval (required when the platform asks for one).' }
        @{ Column = 'TicketingSystem'; Required = $false; Description = 'Ticketing system name, when the platform requires a ticket.' }
        @{ Column = 'TicketId';        Required = $false; Description = 'Ticket ID, when the platform requires a ticket.' }
        @{ Column = 'Machine';         Required = $false; Description = 'Target machine the key will be used on, when the account allows several.' }
    )
    Priority         = 49
    Version          = '1.0.0'
}

function Get-AccountsRetrieveSshKeyInput {
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

    Write-Host '  SSH Key Retrieval  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host '  The private key is saved to a file in the Output Folder. Treat that file as a secret.' -ForegroundColor DarkGray
    Write-Host ''

    $accountID = Show-FieldPrompt -Label 'Account ID' `
        -Default $(if ($Defaults['AccountID']) { $Defaults['AccountID'] } else { '' }) `
        -Description 'Account ID, or leave blank to search by name/username/address.'

    if (-not $accountID) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Name, username, or address to find the account.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $accountID = Invoke-EntitySearch -Token $Token `
                -Endpoint '/API/Accounts' `
                -SearchTerm $searchTerm `
                -ResponseProperty 'value' `
                -IdProperty 'id' `
                -DisplayProperties @('name', 'userName', 'address', 'safeName') `
                -EntityLabel 'account' `
                -IgnoreSSL $ignoreSSL
        }
        if (-not $accountID) { return $null }
    }

    $reason = Show-FieldPrompt -Label 'Reason' `
        -Default $(if ($Defaults['Reason']) { $Defaults['Reason'] } else { '' }) `
        -Description 'Reason for the retrieval. Required by some platforms. Leave blank if not needed.'
    $ticketingSystem = Show-FieldPrompt -Label 'TicketingSystem' `
        -Default $(if ($Defaults['TicketingSystem']) { $Defaults['TicketingSystem'] } else { '' }) `
        -Description 'Ticketing system name, if the platform requires a ticket.'
    $ticketId = Show-FieldPrompt -Label 'TicketId' `
        -Default $(if ($Defaults['TicketId']) { $Defaults['TicketId'] } else { '' }) `
        -Description 'Ticket ID, if the platform requires a ticket.'

    return @{
        AccountID       = $accountID
        Reason          = $reason
        TicketingSystem = $ticketingSystem
        TicketId        = $ticketId
    }
}

function Invoke-AccountsRetrieveSshKey {
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

    $addError = {
        param([string]$Message, $Details, [int]$StatusCode = -1)
        Write-CyberArkLog -Level 'ERROR' -Message $Message
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $Message; ErrorDetails = $Details })
        $result.Failures++
        $result.ItemsProcessed++
        if ($StatusCode -in @(401, 0)) { $result.IsFatal = $true }
    }

    $ident     = Get-CyberArkAccountIdentifier -InputData $InputData
    $accountId = $ident.AccountID

    if ($ident.ErrorMessage) {
        & $addError $ident.ErrorMessage $null
        return $result
    }

    if ($ident.NeedsLookup) {
        Write-CyberArkLog -Level 'DEBUG' -Message "Fetching accounts in safe '$($ident.Safe)' to locate the account."

        $lookupResp = Invoke-CyberArkAPI `
            -Token       $Token `
            -Method      'GET' `
            -Endpoint    '/API/Accounts' `
            -QueryParams @{ filter = (New-CyberArkSearchFilter -Criteria @{ safeName = $ident.Safe }) }

        if (-not $lookupResp.IsSuccess) {
            & $addError "Account lookup failed (HTTP $($lookupResp.StatusCode)): $($lookupResp.ErrorMessage)" $lookupResp.ErrorDetails $lookupResp.StatusCode
            return $result
        }

        [array]$acctList = @(if ($lookupResp.Data -and
                                 $lookupResp.Data.PSObject.Properties['value'] -and
                                 $null -ne $lookupResp.Data.value) {
            $lookupResp.Data.value
        })

        $acctMatch = Select-CyberArkAccountMatch -Accounts $acctList `
            -AccountName $ident.AccountName -UserName $ident.UserName -Safe $ident.Safe
        if ($acctMatch.ErrorMessage) {
            & $addError $acctMatch.ErrorMessage $null
            return $result
        }

        $accountId = $acctMatch.AccountID
        Write-CyberArkLog -Level 'DEBUG' -Message "Resolved account ID: $accountId"
    }

    # Send only the fields that were given, as psPAS Get-PASAccountSSHKey does (14.6 Swagger
    # AccountContentPrerequsites has no required fields).
    $body = @{}
    foreach ($field in @('Reason', 'TicketingSystem', 'TicketId', 'Machine')) {
        $value = if ($InputData[$field]) { "$($InputData[$field])".Trim() } else { '' }
        if ($value) { $body[$field] = $value }
    }

    $endpoint = "/API/Accounts/$([Uri]::EscapeDataString($accountId))/Secret/Retrieve"

    # SECURITY: log that a key retrieval was requested, but NEVER the key itself.
    Write-CyberArkLog -Level 'WARN'  -Message "SSH key retrieval requested for AccountID=$accountId"
    Write-CyberArkLog -Level 'DEBUG' -Message "POST $endpoint"

    # Retrieval is a read (audited by the Vault), so there is no WhatIf: the driver never calls
    # this with -WhatIf because SupportsWhatIf is $false.
    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint $endpoint `
        -Body     $body

    if (-not $response.IsSuccess) {
        & $addError "SSH key retrieval failed for AccountID=$accountId (HTTP $($response.StatusCode)): $($response.ErrorMessage)" $response.ErrorDetails $response.StatusCode
        return $result
    }

    # The key can arrive as a file (bytes), as plain text, as a JSON string, or as a JSON object
    # with a Content property (psPAS returns .Content when present). Anything else is reported by
    # property names only, never values.
    $keyBytes = $null
    $data     = $response.Data
    if ($response.DataType -eq 'File' -and $data) {
        $keyBytes = [byte[]]$data
    } elseif ($data -is [string] -and $data) {
        $keyBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($data)
    } elseif ($data -and $data.PSObject.Properties['Content'] -and $data.Content) {
        $keyBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes("$($data.Content)")
    }

    if (-not $keyBytes) {
        $shape = if ($data -and $data.PSObject) { (@($data.PSObject.Properties | ForEach-Object { $_.Name }) -join ', ') } else { '' }
        & $addError "SSH key retrieval returned HTTP $($response.StatusCode) but no key content (DataType='$($response.DataType)'; properties: '$shape')." $null
        return $result
    }

    # Automation mode's -OutputFolder (or the job step's) wins over the profile's (F98). Get-Variable,
    # because the standalone unit test never sets these driver variables and strict mode is on.
    $modulesPath    = Get-Variable -Name 'APIModulesPath' -Scope 'Script' -ValueOnly -ErrorAction SilentlyContinue
    $folderOverride = if (Get-Variable -Name 'AutomationMode' -Scope 'Script' -ValueOnly -ErrorAction SilentlyContinue) {
        Get-Variable -Name 'OutputFolder' -Scope 'Script' -ValueOnly -ErrorAction SilentlyContinue
    } else { $null }
    $profileFolder  = if ($script:ActiveProfile -and $script:ActiveProfile.PSObject.Properties['OutputFolder']) { $script:ActiveProfile.OutputFolder } else { $null }
    $outputFolder   = Resolve-CyberArkOutputFolder -OverrideFolder $folderOverride -ProfileFolder $profileFolder `
        -ProjectRoot $(if ($modulesPath) { Split-Path -Path $modulesPath -Parent } else { (Get-Location).Path })

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $saveName     = "SSHKey-$accountId-$(Get-Date -Format 'yyyyMMdd-HHmmss').key"
    $safeFileName = -join ($saveName.ToCharArray() | ForEach-Object { if ($invalidChars -contains $_) { '_' } else { $_ } })
    $keyPath      = Join-Path $outputFolder $safeFileName

    $saved = Invoke-FileWriteWithRetry -Path $keyPath -Action {
        [System.IO.File]::WriteAllBytes($keyPath, $keyBytes)
    }
    if (-not $saved) {
        & $addError "SSH key retrieved but the file could not be saved to '$keyPath' (user declined to retry)." $null
        return $result
    }

    Write-CyberArkLog -Level 'INFO' -Message "SSH key for AccountID=$accountId saved to '$keyPath'. Key value not logged."

    $result.Results.Add([PSCustomObject]@{
        AccountID = $accountId
        KeyFile   = $keyPath
        Retrieved = $true
    })
    $result.Successes++
    $result.ItemsProcessed++

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
