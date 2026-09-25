# API Module Complete Example

A complete, working module that follows every rule in [Reference_API-Module-Guide.md](Reference_API-Module-Guide.md). Use it as the starting template for a new module.

---

## Complete Example

A complete, minimal module for listing accounts.

```powershell
#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'List Accounts'
    Category         = 'Accounts'
    Action           = 'List'
    Description      = 'Retrieve accounts with optional keyword search.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $false
    InputSchema      = @()
    Version          = '1.0.0'
}

function Invoke-AccountsList {
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

    Write-CyberArkLog -Level INFO -Message 'Starting account list retrieval.'

    $search = if ($InputData['Search']) { "$($InputData['Search'])".Trim() } else { $null }
    $query = New-CyberArkQuery -Search $search -Limit 100

    Write-CyberArkLog -Level DEBUG -Message "Endpoint: GET /API/Accounts | Search: '$search'"

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'GET' `
        -Endpoint '/API/Accounts' `
        -Query    $query `
        -WhatIf   $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        Write-CyberArkLog -Level ERROR -Message "Account list failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $response.ErrorMessage
            ErrorDetails = $response.ErrorDetails
        })
        $result.Failures++
        $result.IsFatal = ($response.StatusCode -eq 401)
        return $result
    }

    foreach ($account in $response.Data.value) {
        $result.Results.Add([PSCustomObject]@{
            AccountId   = $account.id
            AccountName = $account.name
            SafeName    = $account.safeName
            PlatformId  = $account.platformId
            Address     = $account.address
            UserName    = $account.userName
        })
        $result.Successes++
        $result.ItemsProcessed++
    }

    Write-CyberArkLog -Level INFO -Message "Completed. Accounts retrieved: $($result.Successes)."
    return $result
}
```

---
