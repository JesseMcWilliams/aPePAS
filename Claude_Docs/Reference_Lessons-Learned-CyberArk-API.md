# Lessons Learned: CyberArk API Behavior

CyberArk PVWA, Privilege Cloud (ISPSS) and Identity API behavior found in testing or live use: response
shapes, field casing, URL and query encoding, and Self-Hosted versus ISPSS differences. Many of these are
not documented in the CyberArk developer portal, and they vary by tenant or version. Each entry lists the
symptom, the cause, the fix or rule, and one example. The "Old" line gives the entry's section numbers in
the original single file.

**General rule:** when you map a response, log `$obj.PSObject.Properties.Name -join ', '` at DEBUG level
and confirm the real field names and casing from a live run. Don't assume parity between versions or
between Self-Hosted and ISPSS.

---

## 1. Privilege Cloud: find the Identity tenant URL through redirect discovery

*Old: §11.1*

**Symptom:** `StartAuthentication` returns HTTP 404.

**Cause:** the portal (`{sub}.privilegecloud.cyberark.cloud`) sends the browser to the Identity tenant
(`{sub}.id.cyberark.cloud`) with **JavaScript**, not HTTP 301/302. `Invoke-WebRequest` can't follow that,
so it returns the portal host. The Identity API path doesn't exist there.

**Rule:** probe up to three candidates with `-MaximumRedirection 0`. That setting makes the **first**
redirect throw, and the exception's `Response.ResponseUri` is the redirect target. Following redirects
(for example `-MaximumRedirection 8`) can land on the JavaScript portal page. Accept a host that matches
`\.id\.cyberark\.cloud$`, and otherwise fall back to building the URL directly. Read the exception safely
(PowerShell §8, §9).
- Cache the result in the profile's `TenantAuth` field, and pass it as `-IdentityTenantURL` to
  `Get-AuthToken` so discovery is skipped.
- After each successful ISPSS login, write the token's `IdentityURL` back to `TenantAuth`, so the profile
  corrects itself if the URL changes.
- Never hard-code `{sub}.id.cyberark.cloud` without discovery. The subdomain mapping isn't guaranteed to
  be 1:1.

```powershell
$candidates = @("https://$sub.cyberark.cloud", "https://$sub-userportal.cyberark.cloud",
                "https://$sub.privilegecloud.cyberark.cloud")
foreach ($candidate in $candidates) {
    try {
        $resp = Invoke-WebRequest -Uri $candidate -Method Get -MaximumRedirection 0 -TimeoutSec 20 -ErrorAction Stop -UseBasicParsing
        $h = Get-WebResponseHost -Response $resp
        if ($h -match '\.id\.cyberark\.cloud$') { return "https://$h" }
    } catch {
        $caughtError = $_
        $h = Get-ExceptionRedirectHost -ErrorRecord $caughtError
        if ($h -match '\.id\.cyberark\.cloud$') { return "https://$h" }
    }
}
return "https://$sub.id.cyberark.cloud"
```

---

## 2. Identity `AdvanceAuthentication`: the token field name and location vary

*Old: §11.2*

**Cause:** where the token appears depends on the Identity version, the tenant configuration and the step:

| Scenario | Token location |
|---|---|
| Normal completion (most tenants) | `$resp.Result.Token` |
| Some tenant configurations | `$resp.Result.Auth` |
| After OOB approval (some versions) | `$resp.Token` or `$resp.Auth` at the root; `$resp.Result` is the string `"LoginSuccess"` |
| Intermediate MFA step | `$resp.Result` is an object with neither field, so keep looping |

Under strict mode, `$resp.Result.Token` throws when it is absent. `-isnot [string]` doesn't prove the
field exists.

"Still pending" also has two shapes: `{"Result": "OobPending"}` and `{"Result": {"Summary": "..."}}`. A
loop that only waits while `Result -ieq 'OobPending'` exits early on the object shape.

**Rule:** guard every field and check the root as a fallback. Poll until a token appears. Never base the
loop condition on the shape of `Result`. Poll every **5 seconds**, stop on a token, on `success = $false`,
or after a **5-minute** timeout, and show elapsed time in place with `` "`r" ``.

```powershell
if ($resp.Result -isnot [string]) {
    if ($resp.Result.PSObject.Properties['Token'] -and $resp.Result.Token) { $tok = $resp.Result.Token }
    elseif ($resp.Result.PSObject.Properties['Auth'] -and $resp.Result.Auth) { $tok = $resp.Result.Auth }
}
if (-not $tok -and $resp.PSObject.Properties['Token'] -and $resp.Token) { $tok = $resp.Token }
if (-not $tok -and $resp.PSObject.Properties['Auth']  -and $resp.Auth)  { $tok = $resp.Auth }
# OOB: do { ...poll every 5s, run the extraction above... } while (-not $tok -and $resp -and $resp.success -ne $false)
```

---

## 3. Privilege Cloud base URL: fix it at the constant, not in callers

*Old: §11.4*

**Symptom:** some ISPSS tokens had a bare host `BaseURL`, and API calls built wrong paths.

**Cause:** the driver appended `/PasswordVault` to `token.BaseURL` after authentication, but tokens come
from several paths: fresh auth, silent ClientCredentials refresh (`Invoke-TokenRefresh`), and expired-token
AutoRefresh (`Import-AuthToken -AutoRefresh`). The patch didn't run on all of them.

**Rule:** when several paths share a URL base, fix the constant. `Get-AuthToken`, `Update-AuthToken`,
`Import-AuthToken -AutoRefresh` and `RefreshContext.BaseURL` all use it. The driver-side patches remain as
a migration safety net for tokens saved before the fix.

```powershell
$script:PCLOUD_BASE_TEMPLATE = 'https://{0}.privilegecloud.cyberark.cloud/PasswordVault'
```

---

## 4. Platform GET and List: fields may be nested under `general` or sit at the root

*Old: §12.1*

**Symptom:** Privilege Cloud output is mostly blank.

**Cause:**

| Version | Structure | Field names |
|---|---|---|
| PVWA v12+ | nested under a `general` sub-object | `id`, `name`, `description`, `active`, `platformType` |
| Privilege Cloud / older | at the response root | `PlatformID`, `Name`/`name`, `SystemType` instead of `platformType` |

Confirmed live later: `/API/Platforms` **list** entries nest `id`, `active`, `platformType` and similar
fields under `general`.

**Rule:** probe both locations and both name variants. Log the root and `general` property names at
DEBUG level. Apply the same probing to the List module (`Invoke-PlatformsList.ps1` once checked only
`id`/`platformType`).

```powershell
$gen = if ($platform.PSObject.Properties['general'] -and $platform.general) { $platform.general } else { $platform }
$PlatformType = if ($gen.PSObject.Properties['platformType']) { $gen.platformType }
                elseif ($gen.PSObject.Properties['SystemType']) { $gen.SystemType }
                elseif ($platform.PSObject.Properties['platformType']) { $platform.platformType }
                elseif ($platform.PSObject.Properties['SystemType']) { $platform.SystemType } else { '' }
```

---

## 5. `GET /API/Configuration/LDAP/Directories` (GetDirectoryServices): shape not confirmed

*Old: §12.2*

**Status: needs live verification.** `Get-SafeMembersSearchInOptions` (`Invoke-SafeMembersAdd.ps1`, added
2026-08-20 for the SearchIn picker) calls this endpoint. The envelope (bare array or wrapped in `value`)
and the ID and display-name fields were not confirmed against a live system.

**Current mitigation:** it probes `id`, `domainName`, `directoryName` and `name`, logs the first item's
properties at DEBUG (`GetDirectoryServices item properties: ...`), and falls back to Vault-only. It never
throws or blocks the flow.

**Follow-up:** after a live run, read that DEBUG line. Then trim the probe list, or document the confirmed
shape in `Reference_Interfaces.md`, which leaves it out on purpose until then.

---

## 6. `GET /API/UserGroups/{id}/Members` returns HTTP 405: read members from the group GET

*Old: §8.5*

**Symptom:** `HTTP 405 The remote server returned an error: (405) Method Not Allowed.
[GET https://pvwa.company.com/PasswordVault/API/UserGroups/8/Members?offset=0&limit=1000]`

**Cause:** the `/Members` sub-resource is missing on some PVWA versions, even where the docs list it. The
bare `GET /API/UserGroups/{id}` returns members inline.

**Rule:** never use `/Members`. Call the bare GET with `-PageSize 0`, because it is a single resource and
`offset`/`limit` can cause errors. The member property name varies: probe `members` (most common),
`Members`, `groupMembers` (older versions), then `value` (rare). An empty list is not a failure. In tests,
mock `*/UserGroups/{id}` returning `members = @(...)`.

```powershell
$response = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint "/API/UserGroups/$encodedId" -PageSize 0
[array]$members = @()
foreach ($prop in @('members', 'Members', 'groupMembers', 'value')) {
    if ($response.Data -and $response.Data.PSObject.Properties[$prop] -and $response.Data.$prop) {
        [array]$members = @($response.Data.$prop); break
    }
}
```

---

## 7. ISPSS groups: `groupType` is always `'Vault'`, and directory groups use UPN names

*Old: §16.1, §16.4*

**Cause:** on ISPSS, `/API/UserGroups` returns **every** group, LDAP/AD-backed ones included, with
`groupType = 'Vault'` and no `directoryType`. Filtering on `groupType` doesn't work. Directory-backed
groups have a UPN-style `groupName` (`MyGroup@corp.com`), and Vault-only groups have no `@`. An ADSI
`sAMAccountName` lookup with the full UPN finds nothing.

**Rule:** treat an `@` in the name as the sign of a directory group, and filter on it before any ADSI
work. That also keeps progress counts accurate. Before an ADSI lookup, strip both a `DOMAIN\` prefix and
an `@domain` suffix. A group that isn't found in AD is likely Vault-only: skip it with a DEBUG log, and
don't record it as a failure.

```powershell
$sam = if ($name -match '^[^\\]+\\(.+)$') { $Matches[1] } else { $name }   # strip DOMAIN\
$sam = if ($sam  -match '^([^@]+)@.+$')   { $Matches[1] } else { $sam  }   # strip @domain
if ($gname -and $gname -match '@') { $ldapGroups.Add(...) }
```

---

## 8. `GET /API/Accounts` caps at about 20,000 results without a safe filter

*Old: §16.2*

**Cause:** this is a server-side cap. Pagination doesn't get past it.

**Rule:** list the safes with `GET /API/Safes`, then call `GET /API/Accounts?filter=safeName eq <safe>` for
each safe (paginated normally), and combine the results. The cap doesn't apply per safe. This is
`Invoke-AccountsList`'s "By Safe" mode.

---

## 9. Filter values: build them with `New-CyberArkSearchFilter`, and don't hand-roll `eq` strings

*Old: §16.3, §33*

> **Conflict between the original sections. This needs the user's decision.** §16.3 (2026-08-18) said
> filter values must **not** be quoted: `EscapeDataString` turns `"` into `%22`, and the server was said to
> take the quotes as part of the name and return zero results with HTTP 200. §33 (2026-09-02) says the
> opposite. `New-CyberArkSearchFilter` (`CyberArkComms.psm1`) wraps a value in double quotes when it
> contains whitespace, which matches psPAS's `Private/ConvertTo-FilterString.ps1` for API 14.6+. That
> section says the unquoted hand-built filters "most likely" broke safe names containing spaces. Neither
> section records a live confirmation. The code today follows §33.

**Symptom (§33):** an `AccountName`+`Safe` lookup fails for a safe name with a space (e.g.
`"Prod Web Servers"`), but works for one-word names. It shows as a normal "account not found".

**Cause (§33):** 16 call sites in the Accounts category built `safeName eq X` by string interpolation
instead of calling the existing, Pester-tested (C13 to C16) helper.

**Rule:** build filters with `New-CyberArkSearchFilter`. To find hand-built filters, grep `APIModules\`
for `"eq \$`. `New-CyberArkQuery` URL-encodes the whole value. See also Module-Conventions §8.

```powershell
-QueryParams @{ filter = "safeName eq $targetSafe"; limit = 1000 }                                        # wrong
-QueryParams @{ filter = (New-CyberArkSearchFilter -Criteria @{ safeName = $targetSafe }); limit = 1000 } # correct
```

---

## 10. `?search=` needs a literal period percent-encoded as `%2E`

*Old: §34*

**Symptom (confirmed live by the user):** a `search` value that contains `.` (a UPN like `jdoe.admin`, an
email address or an IP address) finds nothing, with no error.

**Cause:** `[Uri]::EscapeDataString` leaves `.` alone, because RFC 3986 treats it as unreserved.
CyberArk's `search` parsing needs `%2E`.

**Rule:** this is fixed centrally in `New-CyberArkQuery` (`CyberArkComms.psm1`), so no module changes are
needed. The key match is case-insensitive, because `Invoke-EntitySearch`'s Platforms callers pass
`-SearchParam 'Search'`. Only the `search` key is encoded this way. `filter` and other values are left as
they are, since there is no evidence they need it.

```powershell
$encodedVal = [Uri]::EscapeDataString($val)
if ($key -ieq 'search') { $encodedVal = $encodedVal.Replace('.', '%2E') }   # ?search=jdoe%2Eadmin
```

---

## 11. Trailing slash: add one when the last path segment contains a dot, and keep it for PIMServices

*Old: §28.1, §31.2*

**Symptom:** requests whose last segment contains a dot (`domain.user`, `12_34.56`) return errors or the
wrong content type.

**Cause:** servers and proxies read a dot in the last segment as a file extension. A trailing slash marks
the path as a collection. In a separate case, the WCF `/WebServices/PIMServices.svc` Applications
endpoints need their trailing slash kept.

**History (§31.2):** the fix regressed once. `Join-CyberArkUrl`'s own trailing-slash trim, added to fix an
unrelated test regression (C12), undid it for the Applications endpoints. The 2026-08-16 entries in
`Archive_Planning_Documentation-Tracker.md` show the slash being added and reverted the same day. The
current fix restores the slash at the `Invoke-CyberArkAPI` call site, based on the caller's `-Endpoint`,
instead of changing `Join-CyberArkUrl`'s general contract again (see Module-Conventions §8).

**Rule:** any code that assembles the final URI adds the slash **before** appending query parameters.

```powershell
if ($result.Split('/')[-1] -match '\.') { $result += '/' }                          # Join-CyberArkUrl
if ($cleanPath.TrimEnd('/').Split('/')[-1] -match '\.') { $fullUri += '/' }         # Invoke-CustomTestApi
```

---

## 12. Applications API: legacy PIMServices endpoint with wrapped bodies

*Old: §8.4*

**Rule:**
- The path is `/WebServices/PIMServices.svc/Applications`, not `/API/Applications`.
- List: `{ "application": [ ... ] }`. Get: `{ "application": { ... } }`. Auth methods:
  `{ "authentication": [ ... ] }`.
- The Add body **must** be wrapped: `@{ application = @{ ... } }`.
- `SupportedSystems = @('SelfHosted')`, because ISPSS doesn't expose this endpoint.
- Check `PSObject.Properties['application']` or `['authentication']` first, and normalize with `@(...)`,
  because the payload can be a single object or an array.

```powershell
Invoke-CyberArkAPI -Token $Token -Method 'POST' -Endpoint '/WebServices/PIMServices.svc/Applications' `
    -Body @{ application = @{ AppID = $appId; Description = $desc; Disabled = $false } }
```

---

## 13. Safe member permissions come back in camelCase

*Old: §19.1*

**Symptom:** every permission shows `$false`, with no error.

**Cause:** `GET /API/Safes/{safe}/Members` returns camelCase permission keys. `PSObject.Properties
['UseAccounts']` returns `$null` for a name that doesn't match, so the guard quietly picks the `else`
branch.

**Rule:** use the exact API casing: `useAccounts`, `retrieveAccounts`, `listAccounts`, `addAccounts`,
`updateAccountContent`, `updateAccountProperties`, `initiateCPMAccountManagementOperations`,
`specifyNextAccountContent`, `renameAccounts`, `deleteAccounts`, `unlockAccounts`, `manageSafe`,
`manageSafeMembers`, `backupSafe`, `viewAuditLog`, `viewSafeMembers`, `accessWithoutConfirmation`,
`createFolders`, `deleteFolders`, `moveAccountsAndFolders`, `requestsAuthorizationLevel1`,
`requestsAuthorizationLevel2`. Header fields missing from older implementations (**verify against a live
response**): `safeUrlId`, `safeNumber`, `memberId`, `isExpiredMembershipEnable`.

```powershell
UseAccounts = if ($perms -and $perms.PSObject.Properties['useAccounts']) { $perms.useAccounts } else { $false }
```

---

## 14. Request body field casing depends on the endpoint

*Old: §21.1*

**Symptom:** HTTP 400 with no helpful message.

| Endpoint | Body key style | Example |
|---|---|---|
| `POST /API/Safes` | PascalCase | `SafeName`, `OLACEnabled`, `ManagingCPM` |
| `POST /API/Accounts/{id}/LinkAccount` | camelCase | `name`, `safe`, `folder`, `extraPasswordIndex` |
| `POST /API/Accounts` | camelCase | `name`, `userName`, `platformId`, `safeName` |
| `POST /API/Safes/{safe}/Members` | camelCase | `memberName`, `searchIn`, `permissions` |

**Rule:** check each endpoint's body names on their own. Response casing doesn't predict request casing:
the `GET /API/Safes` response is camelCase, but `POST /API/Safes` takes PascalCase.

---

## 15. Integer fields must be sent as JSON numbers

*Old: §22.1*

**Symptom:** HTTP 400 with no field-level detail. `extraPasswordIndex` in
`POST /API/Accounts/{id}/LinkAccount` is the known case.

**Cause:** `Read-Host`/`Show-FieldPrompt` and CSV input are strings, so the JSON has `"1"`, not `1`.

**Rule:** cast documented integer fields with `[int]` when you build the body.

```powershell
$body['extraPasswordIndex'] = [int]$extraPasswordIndex   # JSON 1, then 204
```

---

## 16. Safe `lastModificationTime` is in microseconds, and `creationTime` is in seconds

*Old: §23.1*

| Field | Unit | Example | Converted |
|---|---|---|---|
| `creationTime` | seconds | `1608827926` | 2020-12-24 |
| `lastModificationTime` | microseconds | `1610319618268452` | 2021-01-10 |

`FromUnixTimeSeconds` overflows on the 16-digit value, and `FromUnixTimeMilliseconds` gives about year
52985.

**Rule:** a 10-digit value is seconds, 13 digits is milliseconds, and 16 digits is microseconds. Divide by
1000 through `[double]`, because a `[long]` divided by 1000 in PowerShell does integer division and drops
the remainder.

```powershell
[DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]$safe.lastModificationTime / 1000)).LocalDateTime.ToString('yyyy-MM-dd')
```
