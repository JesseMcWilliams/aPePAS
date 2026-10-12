# API Module Shared Helpers

How API modules call the shared Comms and Logging modules. Split out of [Reference_API-Module-Guide.md](Reference_API-Module-Guide.md), which has the module contract and the New Module Checklist.

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

### Account identifiers: Get-CyberArkAccountIdentifier and Select-CyberArkAccountMatch

Every Accounts action that acts on an existing account finds it the same way. Declare these optional
`InputSchema` columns: `AccountID`, `AccountName`, `UserName` (leave it out when UserName is a value the
module sets, as in Update) and `Safe`. Then:

```powershell
$ident     = Get-CyberArkAccountIdentifier -InputData $InputData   # add -IgnoreUserName if UserName is a value to set
$accountId = $ident.AccountID
if ($ident.ErrorMessage) { <# record a failure with $ident.ErrorMessage and return #> }
if ($ident.NeedsLookup) {
    $lookupResp = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/Accounts' `
        -QueryParams @{ filter = (New-CyberArkSearchFilter -Criteria @{ safeName = $ident.Safe }); limit = 1000 }
    # ...handle a failed lookup, build [array]$acctList from $lookupResp.Data.value...
    $acctMatch = Select-CyberArkAccountMatch -Accounts $acctList -AccountName $ident.AccountName -UserName $ident.UserName -Safe $ident.Safe
    if ($acctMatch.ErrorMessage) { <# record a failure and return #> }
    $accountId = $acctMatch.AccountID
}
```

- AccountID wins when set. AccountName is the object name (`name`), never the username; an `ObjectName`
  column is read as AccountName. UserName matches `userName`. Given both, the account must match both.
- Zero or several matches return an `ErrorMessage`. Never fall back to the first match.
- Keep the `GET` in the module: tests mock `Invoke-CyberArkAPI` in the module's scope, and a call made
  inside `CyberArkComms.psm1` would bypass that mock.

### User identifiers and bodies: Get-CyberArkUserIdentifier, Select-CyberArkUserMatch, ConvertTo-CyberArkUserFields, ConvertTo-CyberArkUserPutBody

Every Users action that acts on an existing user declares optional `UserID` and `Username` columns, then:

```powershell
$ident = Get-CyberArkUserIdentifier -InputData $InputData   # UserID (numeric) wins; Username needs a lookup
if ($ident.ErrorMessage) { <# record a failure and return #> }
if ($ident.NeedsLookup) {
    $lookupResp = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/Users' -QueryParams @{ search = $ident.Username }
    # ...handle a failed lookup, build [array]$userList from $lookupResp.Data.Users...
    $match = Select-CyberArkUserMatch -Users $userList -Username $ident.Username
    if ($match.ErrorMessage) { <# record a failure and return #> }
    $userId = $match.UserID
}
```

- `?search=` matches part of the username, first name or last name, so `Select-CyberArkUserMatch` keeps only an exact
  (case-insensitive) `username` match. Zero or several matches return an `ErrorMessage`.
- `ConvertTo-CyberArkUserFields -InputData $row [-IncludeCreateOnly]` turns the non-blank user property columns into
  the nested POST/PUT body fields (`personalDetails`, `internet`), parsing booleans, lists and `ExpiryDate`, and
  returns `Fields`, `Columns` and `Errors`.
- `ConvertTo-CyberArkUserPutBody -User $getResponse.Data -Changes $fields` builds a full `PUT /API/Users/{id}` body:
  the editable fields of the current user (EditUserRequest model, without `authenticationMethod`, as psPAS does) with
  the changes merged on top, nested objects field by field. Use it for any PUT to a user, because PUT replaces the user.
- `ConvertTo-CyberArkUserList` splits a semicolon- or comma-separated value into a string array (always an array).
  `ConvertTo-CyberArkUserPutBody` also leaves out a negative `expiryDate` (the "never expires" value; F101).
- `Wait-CyberArkBulkAction -Token $Token -BulkId $id [-TimeoutSec 20]` polls `GET /API/BulkActions/{id}` until every item
  has succeeded or failed, and returns `Completed`, `Succeeded`, `Status`, `ErrorMessage` and `StatusCode`. A Bulk PATCH's
  HTTP 200 only means the job was queued (F100).

### Resolve-CyberArkOutputFolder

For a module that saves its own file (an SSH key, a platform ZIP, a report) instead of returning `Results` for the driver
to save. It returns the first non-blank of `-OverrideFolder` (automation mode's `-OutputFolder` or a job step's
`OutputFolder`; pass it only when `$script:AutomationMode` is set), `-ProfileFolder`, then `-ProjectRoot`. A relative path
resolves against the project root, and the folder is created when missing (F98). See
`Invoke-AccountsRetrieveSshKey.ps1` for the `Get-Variable` calls that read the driver variables safely.

### Get-CyberArkHttpErrorResponse

For the rare module that calls `Invoke-WebRequest` directly (for example `Custom/TestApi`): pass the `catch` block's
`$_` to get `StatusCode`, `Body`, `Headers` and `Message` from either PS 5.1's `WebException` or PS 7's
`HttpResponseException`. It returns `$null` for an error that isn't an HTTP/web error. Never use
`catch [System.Net.WebException]`: PS 7 errors skip it (PowerShell Lessons Learned section 18).

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
