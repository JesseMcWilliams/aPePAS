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

**Status: shape documented, now the fallback source.** The 14.6 Swagger (`LDAPDirectories_GetDirectories`)
returns a bare array of `{ DomainName, DomainBaseContext }`. Confirmed live on PVWA 14.6 (2026-10-12): a bare array
whose items have `DomainName`; a single directory (`.../Directories/{name}/`) adds `DirectoryType`, `BindUsername` and
`DCList`. Since F76 the SearchIn picker calls it only when
`/api/settings/AddSafeMember` returns 404 or no `Directories` list (see section 18).

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

**Quoting rule (the user decided this on 2026-09-25):** a filter value that contains a space must be wrapped in
double quotes, and the quotes must reach the server URL-encoded as `%22`. A value without a space is sent
unquoted. `New-CyberArkSearchFilter` adds the quotes, and `New-CyberArkQuery` encodes them through
`[Uri]::EscapeDataString`. This matches psPAS's `Private/ConvertTo-FilterString.ps1` for API 14.6+. Test C44
pins the encoded result (`safeName%20eq%20%22My%20Safe%22`). The old §16.3 rule ("never quote filter
values") is superseded.

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

---

## 17. Application `certificateattr` auth methods: arrays in, comma-joined strings out

**Symptom:** a `certificateattr` method added successfully shows a blank `AuthValue` in
ListAuthMethods, and the PVWA web console doesn't show the attributes either.

**Cause:** the type has no `AuthValue`. The POST takes `Subject`, `Issuer` and
`SubjectAlternativeName` as JSON arrays of `Attribute=value` strings. The GET
`/WebServices/PIMServices.svc/Applications/{AppID}/Authentications/` returns them as PascalCase
**strings** with the entries joined by `", "`, and returns `""` for any field that wasn't set
(confirmed live on Self-Hosted, 2026-10-06):

```json
{ "authID": "1", "AppID": "test", "AuthType": "certificateattr", "Comment": "testing",
  "Subject": "CN=app01, OU=IT, C=US", "Issuer": "", "SubjectAlternativeName": "" }
```

**Rule:** read these three fields (guarded with `PSObject.Properties`) for display, and use
`@($value) -join ', '` in case a version returns an array. Don't split the returned string back on
`,`, because attribute values can contain commas. To check what was stored, use the raw GET through
Custom > Test API, and remember that Test API paths must start with `/PasswordVault`.

**Input rules (from CyberArk's "Add application authentication method" REST reference):** the
entries in each list must be in the same order as they appear in the certificate, and the
order is not validated, so a wrong order just gives a method that never matches. SAN names are
`DNS Name`, `IP Address`, `URI` and `RFC822 Name`. psPAS 8.0.20's help says `RFC822`, but CyberArk's
page and its example body follow the longer form. RFC 5280 §4.2.1.6 only names the ASN.1 types
(`rfc822Name` and so on), not these labels. Only `DNS Name` has been confirmed live so far.

---

## 18. SearchIn values: where they come from on each system

**Symptom:** the SearchIn picker offers only Vault on Privilege Cloud, and you can't find an LDAP directory
name anywhere on a user.

**Cause:** three separate facts.
- `GET /API/Configuration/LDAP/Directories` is Self-Hosted only (psPAS `Get-PASDirectory` asserts it).
- On Privilege Cloud, SearchIn is the directory's **Identity GUID**. psPAS `Get-PASDirectoryID` reads it from
  `GET /api/settings/AddSafeMember`, whose `Directories` array has `Name` and `ID`; on Self-Hosted the same call
  returns the directory name as the `ID`. It is not in the 14.6 Swagger.
- User records carry only `source` (`LDAP`), `userDN` and `location`, not the directory. Group records carry it:
  `UserGroup.directory` is a **string**, the directory name (F75 fixed Groups/List, which read it as an object).

**Rule:** build SearchIn choices from `/api/settings/AddSafeMember` (`ID` = value, `Name` = label), fall back to
GetDirectoryServices on a 404, and never split a SearchIn value on `:`, because names like
`Active Directory: example.com` contain one. To find a Self-Hosted directory name by hand, list groups and read
the `Directory` column of a Directory group.

---

## 19. Safe update can't change AutoPurgeEnabled, and member lists hide predefined users

**Symptom:** Update Safe reports success but AutoPurgeEnabled doesn't change. List Safe Members shows no
Master, Batch, Auditors, Operators or other built-in members.

**Cause:** `PUT /API/Safes/{id}` has no AutoPurgeEnabled field (14.6 `UpdateSafeRequestBody`; psPAS
`Set-PASSafe` has none), so the value is silently ignored; only `POST /API/Safes` takes it. `GET
/API/Safes/{id}/Members` returns non-predefined members only, unless `filter=includePredefinedUsers eq true`
is sent (PVWA 12.1 and later).

**Rule:** set AutoPurgeEnabled only when creating a safe, and don't offer it on update. Send the
`includePredefinedUsers` filter wherever all members are wanted (List Safe Members), and fall back without it
on an HTTP 400. Leave it off where predefined members must not be copied (Add Safe From Template).

---

## 20. Users: PUT replaces the user, and `?search=` is a partial match

**Symptom (expected from the references, not yet seen live):** an update that sends only the changed user
fields could reset the others; a Username lookup through `GET /API/Users?search=` can return several users.

**Cause:** `PUT /API/Users/{id}` takes the whole 14.6 `EditUserRequest` model (`username` is required), and
psPAS `Set-PASUser` GETs the user first and resends every value it isn't changing (`Format-PutRequestObject`),
dropping read-only fields (`id`, `source`, `componentUser`, `groupsMembership`, `lastSuccessfulLoginDate`) and
`authenticationMethod`. `?search=` matches part of the username, first name or last name (Swagger).

**Rule:** for any PUT to a user, build the body with `ConvertTo-CyberArkUserPutBody` from a fresh GET. Resolve
a Username with `Select-CyberArkUserMatch` (exact match only; zero or several matches fail the row). Confirm
live that the PUT resets nothing it resends (see `Testing_Status.md`, Users).

## 21. Safe membership expiration is Unix seconds, not a date string

**Symptom:** `POST /API/Safes/{id}/Members` with `membershipExpirationDate` = `"2027-01-31"` returns HTTP 400
PASWS167E "There are some invalid parameters"; the same body without the field succeeds (confirmed live 2026-10-10).

**Cause:** the field is an int64 Unix time in seconds (14.6 Swagger). psPAS `Add-PASSafeMember` converts with
`ConvertTo-UnixTime`; only the legacy Gen1 WebServices call takes `MM/dd/yyyy`. The GET returns the same number,
and a negative value means "no expiration".

**Rule:** convert typed dates with `ConvertTo-CyberArkExpirationTime` before sending, and show stored values with
`ConvertFrom-CyberArkExpirationTime`. The same applies to the Users `expiryDate` field. The legacy Applications
API (`ExpirationDate`, `MM/DD/YYYY`) is a different contract; leave it alone.

## 22. `/api/Users` pages with `pageSize`/`pageOffset`, and email is under `internet`

**Symptom:** List Users sent `limit`/`offset`, which `GET /api/Users` ignores. On a vault with more users than the
server's default page, the list could stop early. Separately, Get/List `Email` was always blank.

**Cause:** in the 14.6 Swagger, `GET /api/Users` takes `pageOffset` (users to skip) and `pageSize`, unlike `Safes`,
`Accounts`, `Reports` and Safe members (`offset`/`limit`). The `User` model keeps email addresses under `internet`
(`businessEmail`, `homeEmail`, `otherEmail`). `personalDetails` has no email field. The list model (`UserSummary`)
has no email at all, and `extendedDetails=true` adds groups and `userDN`, not email. Confirmed live 2026-10-10:
`pageSize=1000` is accepted, and page size 5 returns every user once.

**Rule:** `Invoke-CyberArkAPI` switches the paging names for `/api/Users` (F95). When you add a list endpoint, check
its Swagger paging parameters before you rely on the `limit`/`offset` default. Read email from
`internet.businessEmail` on the single-user GET only.

## 23. JIT access (GrantAdministrativeAccess) works only for an LDAP caller

**Symptom:** `POST /API/Accounts/{id}/GrantAdministrativeAccess` and `.../RevokeAdministrativeAccess` return HTTP 403
PASWS211E "Cannot grant access to a non-LDAP user" / PASWS293E "Cannot revoke access to a non-LDAP user" (confirmed live
2026-10-10, logged on as a Vault user).

**Cause:** the PVWA adds the *logged-on* user to the target machine's local Administrators group, so that user must be a
domain (LDAP) user. There is no body and no way to name another user. psPAS sends no body either.

**Rule:** a JIT live test needs a profile that logs on as an LDAP user, plus a Windows account on a platform that allows ad
hoc access. Testing as the Vault automation user only proves the endpoint exists.

## 24. Dependent accounts: the vault-wide filter has no master-account field

**Symptom:** `GET /API/DependentAccounts?filter=MasterAccountId eq 49_3` returns HTTP 400 PASWS357E "Parameter
`MasterAccountId` is not valid". `masterAccountId` and `accountId` fail the same way (confirmed live 2026-10-11).
`platformId eq SchedTask` and `SafeName eq "Test Accounts"` work. Adding a dependent whose platform doesn't fit the master
gets 400 PASWS366E "Dependent platform `X` is invalid for platform `Y`".

**Cause:** psPAS 8.0.20 documents a `MasterAccountId` filter that this PVWA doesn't accept. The 14.6 Swagger describes
`filter` only as "keywords". The vault-wide list comes back wrapped (it paged normally), not as the bare array the Swagger shows.

**Rule:** to list one master's dependents, use `GET /API/Accounts/{id}/DependentAccounts`. Don't add a master filter to the
vault-wide list without a live check. Pick a dependent platform (for example `SchedTask`) that matches the master's platform.

## 25. Deleting an SSH key account: v2 refused, classic v1 worked

**Symptom:** on the lab PVWA (2026-10-11), `DELETE /API/Accounts/{id}` on a `UnixSSHKeys` account (`secretType` = key,
automatic management off) returned HTTP 400 `{"ErrorCode":"PASWS056E","ErrorMessage":"The account is not valid for delete"}`,
with no other detail, both before and after CheckIn. The account had no lock or check-out in its Activities.
`DELETE /WebServices/PIMServices.svc/Accounts/{id}` (classic v1) returned 200, and a GET afterwards showed `deletionTime`
(the safe keeps it for its retention period).

**Cause:** unconfirmed. v2 deletes of password accounts in the same safe work, so the secret type is the likely difference.
No local reference (Swagger, psPAS, ISPSS docs) mentions PASWS056E.

**Rule:** if a v2 account delete gets PASWS056E, retry on the classic v1 route. `Accounts/Delete` does this for that error code only
(K21) and reports `DeleteRoute` = v1. psPAS `Remove-PASAccount` also has a v2 SSH key option (`deleteSshKeyFromVaultAndTarget`
on Self-Hosted 15.2+, `deleteOnlyPrivateSshKey` on Privilege Cloud). It isn't in the 14.6 Swagger and wasn't tried against PASWS056E.

## 26. Onboarding a discovered account fails without a default password

**Symptom:** on the lab PVWA (14.6, 2026-10-14), `POST /API/DiscoveredAccounts/{id}/Onboard` with only `platformId` and
`safeName` returned HTTP 400 `{"ErrorCode":"DAFWS005E","ErrorMessage":"Failed to onboard account."}` for two pending
Windows Server Local accounts, one with a `LastPasswordSet` date and one without. Safe permissions, the platform and the
safe all checked out. The same call with `defaultPassword` added returned 200 with an **empty body** (no new account ID).

**Cause:** the PVWA log for the request's `X-Correlation-ID` showed its permission and platform checks passing, then
`System.NullReferenceException` in the onboard's password handling (`a52.a(PVPassword ...)`), rethrown as the generic
DAFWS005E. psPAS `Publish-PASDiscoveredAccount` and the 14.6 Swagger both treat `defaultPassword` as optional.

**Rule:** send `defaultPassword` when onboarding from the Pending list on a 14.6 PVWA. `Accounts/OnboardDiscovered` adds a
hint to DAFWS005E when none was given. Find the new account by username afterwards, since the response has no ID. For
any generic 4xx, run with `-Verbose` (or `-LogLevel VERBOSE`) and give the PVWA admin the response's `X-Correlation-ID`.
