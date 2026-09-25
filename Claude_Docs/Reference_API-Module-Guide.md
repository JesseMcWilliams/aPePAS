# CyberArk PAS Scripts — API Module Development Guide

## Overview

Each API module encapsulates a single CyberArk REST API action (e.g., list accounts, add a safe
member). Modules are discovered automatically by the driver — no changes to the driver are needed
to add a new module. The driver handles file I/O, CSV looping, output file creation, token
validation, and result summarization. The module's only job is to execute one API action for one
item and return a standard result object.

---

## Project Structure

```
PowerShell/
├── Manage-Privilege.ps1
├── Modules/
│   ├── CyberArkComms.psm1          # Shared communications module (loaded by driver at startup)
│   └── CyberArkLogging.psm1        # Logging module (loaded by driver at startup)
├── APIModules/
│   ├── Accounts/
│   │   ├── Invoke-AccountsList.ps1
│   │   ├── Invoke-AccountsGet.ps1
│   │   └── Invoke-AccountsAdd.ps1
│   ├── Safes/
│   │   ├── Invoke-SafesList.ps1
│   │   └── Invoke-SafesAdd.ps1
│   └── SafeMembers/
│       ├── Invoke-SafeMembersList.ps1
│       └── Invoke-SafeMembersAdd.ps1
├── Auth/
│   ├── CyberArk.Auth.Common.psm1
│   ├── CyberArk.Auth.ISPSS.psm1
│   └── CyberArk.Auth.SelfHosted.psm1
└── Docs/
    └── Reference_API-Module-Guide.md
```

> **Note:** Modules assume `CyberArkComms.psm1` and `CyberArkLogging.psm1` are already imported
> by the driver. Do not import them inside a module file.

---

## File Encoding

All `.ps1` module files **must** be saved as **UTF-8 with BOM**.

PowerShell 5.1 reads BOM-less files using the Windows system ANSI codepage (Windows-1252 on
English systems). In Windows-1252, the last byte of the UTF-8 em-dash (`0x94`) decodes to
`"` (U+201D), which PowerShell treats as a string terminator. This silently corrupts any
double-quoted string that contains an em-dash or other non-ASCII character, producing cascading
parse errors that prevent the module from loading entirely.

**Required:** Save every `.ps1` file in this project as UTF-8 with BOM before committing.

In VS Code: set `"files.encoding": "utf8bom"` in workspace settings, or select
`UTF-8 with BOM` from the encoding picker in the status bar.

When writing files programmatically (e.g. from the Claude Code Write tool, which generates
UTF-8 without BOM), run the project-wide conversion after generating new files:

```powershell
$utf8Bom = New-Object System.Text.UTF8Encoding $true
Get-ChildItem -Recurse -Include '*.ps1','*.psm1' | ForEach-Object {
    $text = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($_.FullName, $text, $utf8Bom)
}
```

See **Section 2** of [Reference_Lessons-Learned-PowerShell.md](Reference_Lessons-Learned-PowerShell.md)
for the full root-cause analysis and a table of all dangerous Unicode code points.

---

## Naming Conventions

| Item | Convention | Example |
|---|---|---|
| Category folder | PascalCase noun | `Accounts`, `SafeMembers` |
| Module file | `Invoke-<Category><Action>.ps1` | `Invoke-AccountsList.ps1` |
| Entry point function | Same as file name (no extension) | `Invoke-AccountsList` |
| Custom input function | `Get-<Category><Action>Input` | `Get-AccountsListInput` |

---

## Required Components

### 1. Module Metadata

`$ModuleMeta` must be the **first statement** in every module file. The driver reads this block
during discovery before executing any code.

```powershell
$ModuleMeta = @{
    Name             = 'List Accounts'           # Display name shown in the action menu
    Category         = 'Accounts'                # Must match the folder name exactly
    Action           = 'List'                    # Short verb: List | Get | Add | Update | Delete
    Description      = 'Retrieve accounts with optional search and filter criteria.'
    SupportedSystems = @('ISPSS', 'SelfHosted')  # Limit to one system if API differs
    SupportsWhatIf   = $false                    # $true for any write, modify, or delete operation
    AcceptsInputFile = $false                    # $true when the module processes CSV rows
    ProducesOutput   = $true                     # $true when results are displayed / saveable
    HasCustomInput   = $false                    # $true when Get-<Category><Action>Input is defined
    InputSchema      = @()                       # Populated when AcceptsInputFile = $true
    Version          = '1.0.0'
}
```

#### InputSchema

Populate `InputSchema` whenever `AcceptsInputFile = $true`. Each entry defines one expected CSV
column. The driver validates the file against this schema before starting and rejects files with
missing required columns.

```powershell
InputSchema = @(
    @{ Column = 'SafeName';    Required = $true;  Description = 'Target safe name.' }
    @{ Column = 'MemberName';  Required = $true;  Description = 'User or group to add.' }
    @{ Column = 'Permissions'; Required = $false; Description = 'Permission set. Defaults to Read.' }
)
```

#### Optional ModuleMeta Fields

These are all omitted by default (falsy/absent) and only need to be set when a module wants the
non-default behavior:

| Field | Purpose |
|---|---|
| `AutoSaveCsv = $true` | The driver automatically writes `$result.Results` to a CSV in the profile's `OutputFolder` after the module returns - the module itself does not need to write any file. Used by bulk-report-style modules (e.g. `Custom/ExportPlatformDetails`). |
| `CsvFilenameField = '<InputData column name>'` | Appends that column's value to the auto-saved single-run CSV filename (e.g. `'Address'` on `Custom/TestConnectivity` produces `"Test Connectivity - 172.21.20.14 <date>.csv"`), so testing several targets in one session doesn't silently overwrite the same file each time. |
| `CsvFilenameNoDate = $true` | Drops the date from the auto-saved filename, producing a fixed `"<Module Name>.csv"` that's overwritten on every run instead of accumulating one dated file per day - matching `Custom/ExportAll`'s own fixed `Export_<Module>.csv` naming. Used by all 4 of the other `Custom` export tools (`ExportEntitlements`, `ExportGroupMembersLocal`, `ExportGroupMembersLDAP`, `ExportPlatformDetails`) so every Custom export behaves the same. Ignored when automation mode's `-FilenameFormat` already took over the filename entirely - an explicit format is authoritative. |
| `IncludeInExportAll = $true` | Opts a module into `Custom/ExportAll`'s bulk run even though its `Action` isn't `List`/`ListAuthMethods` (which `ExportAll` auto-discovers by default). Use this for a single-row settings snapshot that still makes sense as part of a full-tenant export - e.g. `Policies/GetMasterPolicy`. `ExportAll` calls the module with empty `InputData`, so make sure your module has sensible defaults for every field in that case. |
| `ExcludeFromExportAll = $true` | The opposite of `IncludeInExportAll` - excludes a `List`/`ListAuthMethods` module that would otherwise be auto-discovered (e.g. `SafeMembers/List`, whose data is already covered by `Custom/ExportEntitlements`'s combined safes+members export). |
| `SupportsAutomation = $false` | Opts a module out of `Manage-Privilege.ps1 -Category -Action` automation mode entirely - it is rejected at module-resolution time with a clear error instead of being invoked. Use this only when a module's entry point has no `InputData`-driven path at all, i.e. it builds its entire request interactively inside the function body itself with no way to skip that. The only current case is `Custom/TestApi`. See "Automation Mode" below for the more common case of a module that is mostly automatable but has one interactive branch. |

---

### 2. Entry Point Function

```powershell
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

    # ... implementation ...
}
```

#### Parameters

| Parameter | Always present | Description |
|---|---|---|
| `$Token` | Yes | Full token object from `Get-AuthToken`. Contains `Token`, `Headers`, `BaseURL`, `SystemType`, `Expiry`, etc. |
| `$InputData` | When `AcceptsInputFile = $true` or interactive single-item mode | Keys match `InputSchema` column names. `$null` for list/view operations that take no input. |
| `$WhatIf` | Yes | Forward to every `Invoke-CyberArkAPI` call. Shared comms handles blocking. |

---

### 3. Standard Result Object

Initialize at the **top** of the entry point function. Return it at **every** exit path — including
early returns on error.

```powershell
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
```

#### IsFatal

Set `IsFatal = $true` when the error is unrecoverable for the current session — the driver will
abort any active CSV loop and return the user to the main menu.

| Condition | IsFatal |
|---|---|
| HTTP 401 Unauthorized | Yes |
| HTTP 403 Forbidden | No — specific item failed, continue |
| HTTP 404 Not Found | No — specific item failed, continue |
| Network unreachable | Yes |
| Token refresh failed | Yes |
| Schema validation failed | Yes (set before starting any processing) |
| Single item validation failed | No |

#### Adding a success result

```powershell
$result.Results.Add([PSCustomObject]@{
    AccountId   = $response.Data.id
    AccountName = $response.Data.name
    SafeName    = $response.Data.safeName
    PlatformId  = $response.Data.platformId
})
$result.Successes++
$result.ItemsProcessed++
```

#### Adding an error result

```powershell
$result.Errors.Add([PSCustomObject]@{
    InputData    = $InputData
    ErrorMessage = $response.ErrorMessage
    ErrorDetails = $response.ErrorDetails
})
$result.Failures++
$result.ItemsProcessed++
```

---

## Using the Shared Communications Module

### Invoke-CyberArkAPI

```powershell
$response = Invoke-CyberArkAPI `
    -Token    $Token `
    -Method   'GET' `
    -Endpoint '/API/Accounts' `
    -Query    $query `
    -Body     $body `
    -WhatIf   $WhatIf.IsPresent
```

| Parameter | Type | Required | Description |
|---|---|---|---|
| `Token` | PSCustomObject | Yes | Token object from `Get-AuthToken` |
| `Method` | string | Yes | `GET` `POST` `PUT` `PATCH` `DELETE` |
| `Endpoint` | string | Yes | API path starting with `/` (e.g., `/API/Accounts`) |
| `Query` | hashtable | No | Query string parameters |
| `Body` | hashtable or PSCustomObject | No | Request body — serialized to JSON automatically |
| `WhatIf` | bool | No | When `$true`, blocks `POST`/`PUT`/`PATCH`/`DELETE` and logs the skipped call |

#### Response Object

```powershell
[PSCustomObject]@{
    IsSuccess     = $true       # $true for HTTP 200-299; $false for all others
    StatusCode    = 200         # Actual HTTP status code
    StatusMessage = 'OK'        # Plain-language description of the status code
    ErrorMessage  = $null       # $null on success; human-readable summary on error
    ErrorDetails  = $null       # $null on success; parsed CyberArk error object on error
    Data          = [object]    # Parsed response body (PSCustomObject for JSON)
    RawResponse   = [string]    # Raw response body
    DataType      = 'JSON'      # JSON | Binary | File | Empty
}
```

### Query Builder Helpers

```powershell
# Build a query string from a hashtable of parameters
$queryString = New-CyberArkQuery -Params @{ search = 'admin'; limit = 100; offset = 0; sort = 'name asc' }
# Result: '?search=admin&sort=name%20asc&offset=0&limit=100' (key order is not guaranteed -
# hashtable enumeration order in PS 5.1 is not the insertion order)

# Build a filter= expression - always use this instead of hand-writing "field eq value",
# even for a single field. It quotes any value containing spaces (safeName eq "My Safe")
# to match CyberArk's own filter grammar - confirmed against psPAS's ConvertTo-FilterString.ps1,
# which does the identical auto-quote-on-whitespace for API 14.6+. A hand-written
# "safeName eq $targetSafe" silently breaks the moment a safe name contains a space; this
# bug shipped in 16 Accounts modules before being caught and fixed (see
# Archive_Planning_Documentation-Tracker.md, 2026-09-02).
$filter = New-CyberArkSearchFilter -Criteria @{ safeName = $targetSafe }
# $targetSafe = 'TestSafe'  -> 'safeName eq TestSafe'
# $targetSafe = 'My Safe'   -> 'safeName eq "My Safe"'  (URL-encodes to ...eq%20%22My%20Safe%22)

$queryParams = @{ filter = $filter; limit = 1000 }

# Join URL segments — trims and normalizes slashes between segments
$url = Join-CyberArkUrl $Token.BaseURL '/API/Accounts' $accountId
# Result: 'https://pvwa.company.com/PasswordVault/API/Accounts/abc-123'
```

> **Pagination:** Handled automatically by `Invoke-CyberArkAPI`. When the API response contains
> pagination data, the function fetches all pages and returns the combined result set. No looping
> is needed in the module.

> **Rate limiting:** Handled automatically with exponential backoff. A WARN log is written when
> backoff occurs. After `$script:MaxRateLimitRetries` consecutive 429 responses the function
> returns a failure response — set `IsFatal = $true` if this is returned.

> **Gateway timeouts (504):** Handled automatically with a fixed delay (`$script:GatewayTimeoutDelaySec`,
> default 5s — not exponential like 429). Retried up to `$script:MaxGatewayTimeoutRetries` times
> (default 2). If pagination is in use for the call, the page size is reduced by 25% before each
> retry (a smaller page is less likely to time out again). After the retry limit is exhausted the
> function returns a normal failure response with `StatusCode = 504` — treat it like any other
> non-2xx response (per the `IsFatal` table above: not fatal, item-level failure).

---

## Using the Logging Module

```powershell
# Standard levels — the function name is captured automatically
Write-CyberArkLog -Level VERBOSE -Message "Full request body: $($body | ConvertTo-Json -Depth 5)"
Write-CyberArkLog -Level DEBUG   -Message "Calling endpoint: GET /API/Accounts"
Write-CyberArkLog -Level INFO    -Message 'Account list retrieved successfully.'
Write-CyberArkLog -Level WARN    -Message 'No accounts matched the search criteria.'
Write-CyberArkLog -Level ERROR   -Message "API call failed: $($response.ErrorMessage)"

# Bare mode — no prefix, used for formatted display blocks
Write-CyberArkLog -Bare -Message '----------------------------------------'
Write-CyberArkLog -Bare -Message "  Total accounts returned: $($result.Successes)"
Write-CyberArkLog -Bare -Message '----------------------------------------'
```

**Log format** (standard):
```
12345 | 2026-01-15 14:32:01 | INFO    | Invoke-AccountsList     | Account list retrieved successfully.
```

**Sensitive data rules — never log:**
- Authentication tokens or bearer values
- Passwords or secrets in any form
- Full credential objects

---

## WhatIf Support

When `$ModuleMeta.SupportsWhatIf = $true`, simply forward `$WhatIf.IsPresent` to every
`Invoke-CyberArkAPI` call. No conditional branching is needed in the module — the shared
communications module logs the would-have-been call and returns a synthetic success response.

```powershell
# Correct — just pass it through
$response = Invoke-CyberArkAPI `
    -Token    $Token `
    -Method   'POST' `
    -Endpoint '/API/Accounts' `
    -Body     $body `
    -WhatIf   $WhatIf.IsPresent
```

The driver always passes `$WhatIf` to the entry point, even when `SupportsWhatIf = $false`.
Declaring `SupportsWhatIf = $false` only affects the menu display — the parameter is still present.

---

## Automation Mode

`Manage-Privilege.ps1 -StartProfile <name> -Category <cat> -Action <action>` runs one module
non-interactively and exits with a status code (see `User_Docs\User-Guide.md` for the exit-code
contract). The driver already skips a module's `Get-<Category><Action>Input` function entirely in
this mode — `InputData` comes straight from `-InputFile`/`-InputJson` (or `@{}`), so any module
whose entry point relies only on `InputData` and `InputSchema` validation is automation-safe with
no changes.

The one hazard is a `Read-Host`, `Get-Credential`, or other interactive prompt living inside the
`Invoke-<Category><Action>` function body itself (not the `Get-*Input` function, which is already
bypassed). A module with one of these must check `$script:AutomationMode` — read the same way
`$script:WhatIfMode` already is, since every module is dot-sourced into the driver's own scope —
and skip straight to its non-interactive fallback when it's set, exactly as `WhatIf` support does.
`APIModules\Safes\Invoke-SafesDelete.ps1`'s HTTP-409 rename offer is the existing precedent: on a
409 it normally asks whether to rename the safe and retry, but in automation mode it skips that
prompt and reports the original 409 as a plain `Failure`, unchanged.

Because a module file can also be dot-sourced standalone in its own unit test (without
`Manage-Privilege.ps1`'s Configuration region ever running), `$script:AutomationMode` may not
exist in that scope at all — a direct reference throws under strict mode instead of evaluating
falsy. Use a safe existence check rather than referencing it directly:

```powershell
$automationVar = Get-Variable -Name 'AutomationMode' -Scope 'Script' -ErrorAction SilentlyContinue
if ($automationVar -and $automationVar.Value) {
    # non-interactive fallback
}
```

`-OutputFolder <path>` and `-FilenameFormat <template>` are two further automation-only launch
parameters that redirect/rename a saved CSV (see `User_Docs\User-Guide.md`'s Automation mode section
for the full `{ModuleName}`/`{Category}`/`{Action}`/`{Profile}`/`{Date}` template syntax). Most
modules never need to read these directly - `Save-ModuleResultCsv` (`Manage-Privilege.ps1`)
already applies them for every `ModuleMeta.ProducesOutput` module saved through the normal path.
The only reason to read them directly in a module's own file is when, like
`Custom\Invoke-CustomExportAll.ps1`, a module writes its own file(s) itself rather than returning
`Results` for the driver to save - that module reads `$script:OutputFolder` the same
`Get-Variable -ErrorAction SilentlyContinue` way as `$script:AutomationMode` above, for the same
reason (dot-sourced standalone by its own unit test, where the variable was never set at all).

If a module has no non-interactive path at all for any part of its request (its entire body is
built interactively, with nothing to fall back to), declare `SupportsAutomation = $false` in
`$ModuleMeta` instead — see the Optional ModuleMeta Fields table above.

---

## Custom Input Function (Optional)

When `HasCustomInput = $true`, define a `Get-<Category><Action>Input` function in the same file.
The driver calls this function instead of generating generic prompts from `InputSchema`. Use this
when inputs require live lookups (selecting from a list of existing safes, etc.) or cross-field
validation.

```powershell
function Get-AccountsAddInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token,

        [Parameter(Mandatory = $false)]
        [hashtable]$Defaults    # Pre-filled values when the user copies or edits an entry
    )

    # Example: fetch available safes for the user to choose from
    $safesResponse = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/Safes'
    $safeNames = $safesResponse.Data.Safes | Select-Object -ExpandProperty SafeName

    $safeName = Show-SelectionMenu -Title 'Select target safe' -Options $safeNames `
                    -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' })

    return @{
        SafeName   = $safeName
        UserName   = Read-Host -Prompt "Username$(if ($Defaults['UserName']) { " [$($Defaults['UserName'])]" })"
        PlatformId = Read-Host -Prompt "Platform ID$(if ($Defaults['PlatformId']) { " [$($Defaults['PlatformId'])]" })"
        Address    = Read-Host -Prompt "Address$(if ($Defaults['Address']) { " [$($Defaults['Address'])]" })"
    }
}
```

The returned hashtable **keys must match** `InputSchema` column names so the driver's CSV output
column logic works consistently for both interactive and CSV-driven modes.

---

## Error Handling Patterns

### Recoverable error — item fails, processing continues

```powershell
$response = Invoke-CyberArkAPI -Token $Token -Method 'POST' -Endpoint '/API/Accounts' -Body $body -WhatIf $WhatIf.IsPresent

if (-not $response.IsSuccess) {
    Write-CyberArkLog -Level ERROR -Message "Failed to add account '$($InputData.UserName)': $($response.ErrorMessage)"
    $result.Errors.Add([PSCustomObject]@{
        InputData    = $InputData
        ErrorMessage = $response.ErrorMessage
        ErrorDetails = $response.ErrorDetails
    })
    $result.Failures++
    $result.ItemsProcessed++
    return $result
}
```

### Fatal error — abort everything

```powershell
if ($response.StatusCode -eq 401) {
    Write-CyberArkLog -Level ERROR -Message 'Authentication failure — session is no longer valid.'
    $result.IsFatal = $true
    return $result
}
```

### Input validation failure — reject before any API calls

```powershell
$safeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])".Trim() } else { '' }
if ([string]::IsNullOrWhiteSpace($safeName)) {
    Write-CyberArkLog -Level ERROR -Message 'SafeName is required but was not provided.'
    $result.Errors.Add([PSCustomObject]@{
        InputData    = $InputData
        ErrorMessage = 'SafeName is required.'
        ErrorDetails = $null
    })
    $result.Failures++
    $result.ItemsProcessed++
    return $result
}
```

> **Important:** Always use bracket notation `$InputData['Key']` — never dot notation
> `$InputData.Key`. Under `Set-StrictMode -Version Latest` (active in this project),
> dot-notation access on a missing hashtable key throws `PropertyNotFoundException`.

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

## New Module Checklist

Use this checklist before considering a module complete.

### File and naming
- [ ] File is in `APIModules\<Category>\`
- [ ] File is named `Invoke-<Category><Action>.ps1`
- [ ] Entry point function name matches the file name exactly
- [ ] `#Requires -Version 5.1` is the first line

### Metadata
- [ ] `$ModuleMeta` is the first statement after `#Requires`
- [ ] All required fields are present and accurate
- [ ] `SupportedSystems` is restricted to systems that actually support this API call
- [ ] `SupportsWhatIf = $true` for all write, modify, or delete operations
- [ ] `AcceptsInputFile = $true` and `InputSchema` fully populated for input-driven modules
- [ ] `HasCustomInput = $true` if `Get-<Category><Action>Input` is defined
- [ ] `Version` is `'1.0.0'` for new modules

### Result object
- [ ] `$result` initialized at the top using the standard shape
- [ ] Every code path returns `$result`
- [ ] `ItemsProcessed`, `Successes`, `Failures` incremented correctly at every path
- [ ] `IsFatal = $true` set for 401 and other unrecoverable conditions
- [ ] Errors added to `$result.Errors` with `InputData`, `ErrorMessage`, `ErrorDetails`

### API calls
- [ ] `$WhatIf.IsPresent` forwarded to every `Invoke-CyberArkAPI` call
- [ ] WhatIf check is **before** the `Invoke-CyberArkAPI` call (not after)
- [ ] `IsSuccess` checked on every response before accessing `Data`
- [ ] Fatal vs. recoverable error distinction is correct

### Strict-mode safety (Set-StrictMode -Version Latest is always active)
- [ ] All `$InputData` access uses bracket notation: `$InputData['Key']` (never `$InputData.Key`)
- [ ] All optional fields on API response `PSCustomObject` are guarded: `$obj.PSObject.Properties['field']`
- [ ] All empty-collection checks use: `if ((-not $col) -or $col.Count -eq 0)`
- [ ] `Get-ChildItem` results wrapped in `@()` before calling `.Count`

### Logging
- [ ] INFO at start and end of operation
- [ ] DEBUG for endpoint and query details
- [ ] VERBOSE for full request/response bodies (when needed for troubleshooting)
- [ ] ERROR logged before every error added to `$result.Errors`
- [ ] No sensitive data (tokens, passwords, secrets) in any log message

### Custom input (when HasCustomInput = $true)
- [ ] Function named `Get-<Category><Action>Input`
- [ ] Accepts `$Token` and `$Defaults` parameters
- [ ] Returns hashtable with keys matching `InputSchema` column names
- [ ] Handles `$null` `$Defaults` gracefully: `if (-not $Defaults) { $Defaults = @{} }`
- [ ] All `$Defaults` access uses bracket notation: `$Defaults['Key']` (never `$Defaults.Key`)

### File encoding
- [ ] File saved as **UTF-8 with BOM** (not UTF-8 without BOM, not UTF-16)
- [ ] No em-dashes (`—`), curly quotes (`"` `"` `'` `'`), or other non-ASCII characters
      inside double-quoted string literals (safe in comments and single-quoted strings only
      when the BOM is present; avoid them entirely for maximum portability)
