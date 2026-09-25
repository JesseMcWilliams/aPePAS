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
