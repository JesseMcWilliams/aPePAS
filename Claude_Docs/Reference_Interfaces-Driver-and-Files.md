# Interface Definitions: Driver Profile, Files and Configuration

The contracts for what the driver stores and writes: profiles, token files, output CSV columns, log entries and script-level settings. Split out of [Reference_Interfaces.md](Reference_Interfaces.md), which has the token, auth function, result object, module and API response contracts.

---

## Driver Profile — JSON Schema

Stored at `%APPDATA%\IdiraUnifiedScripts\Profiles\<ProfileName>.json` (default location).
Non-sensitive settings only. Human-readable without decryption.

```json
{
    "ProfileName":        "Production",
    "AuthTokenProfile":   "Production",
    "SystemType":         "Privilege Cloud",
    "AppName":            "PasswordVault",
    "AuthMethod":         "ClientCredentials",
    "Username":           "svc-cyberark",
    "BaseURL":            "https://acme.privilegecloud.cyberark.cloud",
    "TenantPortal":       "acme.cyberark.com",
    "TenantVault":        "vault-acme.privilegecloud.cyberark.com",
    "TenantAuth":         "https://acme.id.cyberark.cloud",
    "LogFolder":          "",
    "InputFolder":        "",
    "OutputFolder":       "",
    "IgnoreSSL":          false,
    "WhatIfDefault":      false,
    "Limit":              0,
    "DisplayLimit":       20,
    "Role_Template_Safe": "",
    "Role_Group_Prefix":  "",
    "CPM_List":           "",
    "LastUsed":           "2026-01-15T14:32:01Z",
    "Created":            "2026-01-01T09:00:00Z",
    "Modified":           "2026-01-15T14:32:01Z"
}
```

### Field reference

| Field | Type | Description |
|---|---|---|
| `ProfileName` | string | Display name. Also used to derive file names. |
| `AuthTokenProfile` | string | Name portion of the corresponding `.cred` auth token file. Usually identical to `ProfileName`. |
| `SystemType` | string | `Privilege Cloud` (SaaS / ISPSS) or `Self-Hosted` (on-premises PVWA). Drives the Base URL prompt and maps to the auth script's `ISPSS` / `SelfHosted` parameter values. |
| `AppName` | string | CyberArk application name in the URL path (default: `PasswordVault`). For Self-Hosted only: joined with `BaseURL` to form the `PVWAUrl` passed to `Get-SelfHostedAuthToken` (e.g. `https://pvwa.company.com/PasswordVault`). For Privilege Cloud, `/PasswordVault` is embedded in `PCLOUD_BASE_TEMPLATE` inside `CyberArk.Auth.ISPSS.psm1` and `AppName` is not used at runtime. |
| `AuthMethod` | string | Preferred authentication method for this profile. Set during profile creation; passed directly to `Get-ISPSSAuthToken` or `Get-SelfHostedAuthToken` to skip the interactive method prompt. |
| `Username` | string | Default username pre-populated in auth prompts. Captured from `Get-Credential` on first login and saved back to the profile. |
| `BaseURL` | string | Base URL without application path. For Privilege Cloud: `https://<subdomain>.privilegecloud.cyberark.cloud`. For Self-Hosted: `https://pvwa.company.com`. No trailing slash. |
| `TenantPortal` | string | **Privilege Cloud only.** Admin portal address (no scheme): `{subdomain}.cyberark.com`. Auto-computed from the subdomain when the profile is saved. Informational only — not used in API calls. |
| `TenantVault` | string | **Privilege Cloud only.** Vault FQDN: `vault-{subdomain}.privilegecloud.cyberark.com`. Auto-computed from the subdomain when the profile is saved. Informational only — not used in API calls. |
| `TenantAuth` | string | **Privilege Cloud only.** Identity tenant URL (`https://{subdomain}.id.cyberark.cloud`). Auto-discovered by `Resolve-IdentityTenantURL` during profile edit and written back after each successful ISPSS login. Passed as `-IdentityTenantURL` to `Get-ISPSSAuthToken` so the per-login HTTP redirect probe is skipped. Empty string if discovery has not yet run. |
| `LogFolder` | string | Absolute path. Empty string resolves to the script launch directory at runtime. |
| `InputFolder` | string | Default folder for open-file dialogs. Empty = launch directory. |
| `OutputFolder` | string | Destination for output CSVs and save-file dialogs. Empty = launch directory. |
| `IgnoreSSL` | bool | Bypasses SSL certificate validation. Applied process-wide (a .NET Framework/PS 5.1 limitation - see Design_Architecture.md's Design Decisions table), but correctly reset the moment a call is made with this `false` - so switching to a different profile that doesn't set it no longer leaves a previous profile's bypass silently active. Also applies inside the WebView2 browser control used for SAML/OIDC login, which has its own separate certificate-error handling. |
| `WebView2AssemblyPath` | string | Full path to `Microsoft.Web.WebView2.WinForms.dll`, only consulted for SAML/OIDC (Self-Hosted) or SSO (ISPSS) login. Empty string (the default) means auto-detect via `Import-WebView2Assembly`'s own candidate-path search (see README Requirements) - only set this if that search fails. Threaded through `Invoke-ProfileConnect`/`Invoke-ProfileTestConnection`'s fresh-auth calls to `Get-SelfHostedAuthToken`/`Get-ISPSSAuthToken`. |
| `WhatIfDefault` | bool | When `true`, WhatIf mode is active by default for this profile. |
| `Limit` | int | Maximum number of items the API returns for List operations (`MaxResults` on the session token). `0` = no limit. Passed to `Invoke-CyberArkAPI` via `Token.MaxResults`. |
| `DisplayLimit` | int | Maximum rows shown in the interactive table for List and ExportEntitlements results. `0` = show all. Default: `20`. The full result set is always available for CSV export regardless of this setting. |
| `Role_Template_Safe` | string | Safe name used as a permission template when assigning roles. Consumed by Add/Update Safe Member role-assignment operations. Empty string if not used. |
| `Role_Group_Prefix` | string | Prefix for CyberArk role-based groups (e.g. `CyberArk_`). Consumed by Add/Update Safe Member role-assignment operations. Empty string if not used. |
| `CPM_List` | string | Comma-separated list of CPM usernames (e.g. `PasswordManager,PasswordManager2`), maintained manually via Profile Settings. Shown as a numbered picker (with a "(none)" default) on pages that ask for a CPM to assign - currently `Safes/AddFromTemplate`. Not used by `Safes/AssignCPM`, which queries the API live instead (`GET /API/Users?userType=CPM&componentUser=true`) - a deliberate choice, not a shared mechanism. Empty string if not configured. |
| `LastUsed` | ISO 8601 UTC | Updated each time the profile is selected. |
| `Created` | ISO 8601 UTC | Set once at profile creation. |
| `Modified` | ISO 8601 UTC | Updated whenever any profile field changes. |

### SystemType → BaseURL prompt mapping

| `SystemType` value | Edit-flow prompt | `BaseURL` format stored |
|---|---|---|
| `Privilege Cloud` | Asks for the tenant **subdomain** (e.g. `acme`). URL is constructed automatically. | `https://<subdomain>.privilegecloud.cyberark.cloud` |
| `Self-Hosted` | Asks for the full **PVWA base URL** directly. Trailing slash is stripped on save. | `https://pvwa.company.com` |

The driver maps `SystemType` to the correct auth module function:
- `Privilege Cloud` → `Get-ISPSSAuthToken -AuthMethod <method> -PCloudSubdomain <subdomain> [-IdentityTenantURL <TenantAuth>]`
- `Self-Hosted` → `Get-SelfHostedAuthToken -AuthMethod <method> -PVWAUrl <BaseURL>/<AppName> [-IgnoreSSL]`

`AppName` is joined to `BaseURL` when constructing `PVWAUrl` for Self-Hosted calls (e.g. `https://pvwa.company.com/PasswordVault`). For Privilege Cloud, `/PasswordVault` is embedded in `PCLOUD_BASE_TEMPLATE` inside `CyberArk.Auth.ISPSS.psm1`, so all ISPSS tokens are created with the correct base URL. The driver passes `TenantAuth` as `-IdentityTenantURL` to bypass the HTTP redirect probe that discovers the Identity tenant URL.

**Privilege Cloud: auto-computed profile fields**

When the subdomain is entered during profile edit, three fields are computed automatically:

| Field | Auto-computed value |
|---|---|
| `TenantPortal` | `{subdomain}.cyberark.com` |
| `TenantVault` | `vault-{subdomain}.privilegecloud.cyberark.com` |
| `TenantAuth` | Discovered by `Resolve-IdentityTenantURL`; written back after each login |

---

## Auth Token File — Serialized Shape

Stored at `%APPDATA%\IdiraUnifiedScripts\Profiles\<ProfileName>.cred` by `Save-AuthToken` via `Export-Clixml`.
DPAPI-encrypted fields are marked below.

| Field | Type | DPAPI? | Description |
|---|---|---|---|
| `ProfileName` | string | No | Profile display name |
| `TokenSecure` | SecureString | **Yes** | The bearer / session token |
| `TokenType` | string | No | `Bearer` or `CyberArkSession` |
| `Expiry` | DateTime | No | UTC token expiry |
| `RefreshTokenSecure` | SecureString | **Yes** | OAuth2 refresh token (`$null` if none) |
| `SystemType` | string | No | `ISPSS` or `SelfHosted` |
| `AuthMethod` | string | No | Auth method used |
| `BaseURL` | string | No | PVWA or PCloud base URL |
| `IdentityURL` | string | No | Identity tenant URL (ISPSS only) |
| `TenantId` | string | No | Identity tenant ID (ISPSS only) |
| `SavedAt` | DateTime | No | UTC timestamp when file was written |
| `RefreshContext.ClientSecret` | SecureString | **Yes** | OAuth2 client secret |
| `RefreshContext.Credential` | PSCredential | **Yes** | Username + password |
| `RefreshContext.CertificateThumbprint` | string | No | Cert thumbprint (cert reloaded from store on import) |
| All other RefreshContext fields | string / bool | No | Connection parameters |

---

## Output CSV — Appended Columns

When the driver writes an output CSV from a module run, it copies all original input columns and
appends two new columns at the right.

| Column | Type | Description |
|---|---|---|
| `IsSuccess` | bool (`True` / `False`) | Whether the operation succeeded for this row |
| `Summary` | string | Success: brief description of what was created/changed. Failure: `ErrorMessage` value. |

**File naming:** `<OriginalFileName>_<yyyy-MM-dd>_output.csv`
**Location:** Profile `OutputFolder` (or launch directory if not configured).

---

## Log Entry Format

```
PID   | yyyy-MM-dd HH:mm:ss | LEVEL   | FunctionName         | Message
```

- All fields left-padded / centered to constant width before the pipe separator.
- `PID` field width: 7 characters, right-aligned.
- `Timestamp` field width: 19 characters.
- `LEVEL` field width: 7 characters, centered: `VERBOSE`, ` DEBUG `, ` INFO  `, ` WARN  `, ` ERROR `.
- `FunctionName` field width: 24 characters, left-aligned, truncated with `…` if longer.
- `Message`: remainder of line, no width limit.

**Startup block:**
```
****************************************
  PID 12345 | 2026-01-15 09:00:00 | Profile: Production | ISPSS | ClientCredentials
```

**Session summary block (end of session, write/modify ops only):**
```
----------------------------------------
  Session Summary
  Operations logged: 3
  Total items:       150
  Successes:         148
  Failures:          2
----------------------------------------
```

**Bare mode:** Message only — no PID, timestamp, level, or function name prefix.

---

## Script-Level Configuration Variables

Defined in the driver or shared modules. Override before launching for non-default behavior.

| Variable | Default | Description |
|---|---|---|
| `$script:TokenExpiryWarningMinutes` | `5` | Minutes remaining before prompting user to re-authenticate |
| `$script:ProactiveRefreshThresholdMin` | `10` | Minutes remaining at which `Invoke-ProactiveRefresh` silently refreshes a ClientCredentials token |
| `$script:MaxRateLimitRetries` | `5` | Max consecutive 429 responses before failing the call |
| `$script:RateLimitBaseDelaySec` | `2` | Initial backoff delay in seconds (doubles each retry) |
| `$script:MaxGatewayTimeoutRetries` | `2` | Max consecutive 504 responses before failing the call (defined in CyberArkComms.psm1) |
| `$script:GatewayTimeoutDelaySec` | `5` | Fixed delay in seconds before each 504 retry (not exponential, unlike 429; defined in CyberArkComms.psm1) |
| `$script:PVWA_SESSION_EXPIRY_MIN` | `20` | Expected Self-Hosted session lifetime in minutes (defined in both SelfHosted module and Manage-Privilege.ps1) |
| `$script:LogonTokenMaxAgeMin` | `15` | At logon, a saved token that is still valid (not expired) but older than this (based on `Token.Created`) is refreshed anyway before the session starts |
| `$script:WEBVIEW2_TIMEOUT_SEC` | `300` | Max seconds to wait for browser-based auth completion (defined in CyberArk.Auth.Common.psm1) |
| `$script:CLIENT_AUTH_OID` | `1.3.6.1.5.5.7.3.2` | OID for Client Authentication EKU (PKI cert filtering, defined in CyberArk.Auth.Common.psm1) |
| `$script:ExcludedTemplateMemberNames` | `@()` | Member names never copied by Safes/AddFromTemplate (or any future Safes/SafeMembers module reusing it) - exact match, case-insensitive, across all memberTypes |
