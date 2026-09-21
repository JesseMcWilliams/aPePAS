# CyberArk PAS Scripts — Interface Definitions

This document is the single source of truth for all shared data contracts. Any component that
produces or consumes one of these objects must match the shape defined here exactly.

---

## Token Object

Returned by `Get-ISPSSAuthToken` and `Get-SelfHostedAuthToken`; accepted by every API module as the `$Token` parameter.

```powershell
[PSCustomObject]@{
    Token           = [string]              # Raw bearer token or PVWA session token
    TokenType       = [string]              # 'Bearer' | 'CyberArkSession'
    Headers         = [hashtable]           # Ready-to-use HTTP headers (includes Authorization)
    Expiry          = [DateTime]            # UTC expiry time
    RefreshToken    = [string]              # OAuth2 refresh token — $null if not applicable
    SystemType      = [string]              # 'ISPSS' | 'SelfHosted'
    AuthMethod      = [string]              # 'ClientCredentials' | 'Interactive' | 'SSO' |
                                            # 'CyberArk' | 'LDAP' | 'RADIUS' | 'SAML' |
                                            # 'OIDC' | 'Shared' | 'PKI' | 'PKIPN'
    BaseURL         = [string]              # PVWA or PCloud base URL (no trailing slash)
    IdentityURL     = [string]              # ISPSS: Identity tenant URL. SelfHosted: $null
    TenantId        = [string]              # ISPSS: Identity tenant ID. SelfHosted: $null
    _RefreshContext = [hashtable]           # Internal — used by Update-ISPSSAuthToken / Update-SelfHostedAuthToken (see below)
    Created         = [DateTime]            # UTC - when this token instance was established (fresh auth or refresh).
                                            # Carried forward from the persisted SavedAt timestamp on Import-AuthToken,
                                            # not reset to now on load. Used by Manage-Privilege.ps1's logon-phase age check
                                            # (a still-valid token older than $script:LogonTokenMaxAgeMin is refreshed).
}
```

### Headers shape by TokenType

| TokenType | Headers content |
|---|---|
| `Bearer` (ClientCredentials) | `Authorization: Bearer <token>`, `Content-Type: application/json` |
| `Bearer` (Interactive / SSO) | `Authorization: Bearer <token>`, `X-IDAP-NATIVE-CLIENT: true`, `Content-Type: application/json` |
| `CyberArkSession` | `Authorization: <token>`, `Content-Type: application/json` |

### _RefreshContext shape

All fields are optional depending on `AuthMethod`. Only fields relevant to the method are populated.

```powershell
@{
    Method                = [string]              # Same as Token.AuthMethod
    IdentityURL           = [string]
    PCloudSubdomain       = [string]
    Username              = [string]
    ClientId              = [string]
    ClientSecret          = [SecureString]        # DPAPI-protected when saved to disk
    Credential            = [PSCredential]        # DPAPI-protected when saved to disk
    Certificate           = [X509Certificate2]    # Not serialized — reloaded from store by thumbprint
    CertificateThumbprint = [string]
    ConcurrentSession     = [bool]
    IgnoreSSL             = [bool]
    PVWAUrl               = [string]
    BaseURL               = [string]
    WebView2AssemblyPath  = [string]
}
```

---

## Auth Module Public Functions

### CyberArk.Auth.Common.psm1

| Function | Parameters | Returns | Notes |
|---|---|---|---|
| `New-AuthTokenObject` | _(positional — all fields of token shape)_ | `[PSCustomObject]` token | Factory; ensures all fields are present |
| `ConvertTo-PlainText` | `-SecureString [SecureString]` | `[string]` | Zeroes unmanaged memory after conversion |
| `Get-FilteredClientCertificate` | `-Thumbprint [string]` (optional) | `[X509Certificate2]` or `$null` | Prompts cert picker if no thumbprint |
| `Import-WebView2Assembly` | `-AssemblyPath [string]` | `[void]` (throws on failure) | Memoises — only loads DLL once per session |
| `Invoke-WebView2Window` | `-NavigateUrl [string]`, `-CookieName [string]`, `-TargetHost [string]`, `-Title [string]` (default `'CyberArk Authentication'`) | `[hashtable]` with `Token`, `TokenType` (`'Bearer'` or `'CyberArkSession'`), or `$null` on timeout | STA runspace; timeout is the fixed `$script:WEBVIEW2_TIMEOUT_SEC` constant, not a parameter |
| `Save-AuthToken` | `-TokenObject [PSCustomObject]`, `-ProfileName [string]` | `[void]` | DPAPI via `Export-Clixml` to `.cred` |
| `Import-AuthToken` | `-Path [string]`, `-IgnoreExpiry [switch]` | `[PSCustomObject]` or `$null` | Warns if expired; caller handles refresh |
| `Get-AuthTokenProfiles` | _(none)_ | `[PSCustomObject[]]` | Lists all `.cred` profiles in profile directory |
| `Remove-AuthTokenProfile` | `-ProfileName [string]` | `[void]` | Deletes `.json` + `.cred` pair |

> **Note:** `Import-AuthToken` does **not** have an `-AutoRefresh` switch. The driver explicitly calls
> `Update-ISPSSAuthToken` or `Update-SelfHostedAuthToken` after loading an expired token.

---

### CyberArk.Auth.ISPSS.psm1

```powershell
function Get-ISPSSAuthToken {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ClientCredentials', 'Interactive', 'SSO')]
        [string]$AuthMethod,

        [Parameter(Mandatory)]
        [string]$PCloudSubdomain,

        [string]$IdentityTenantURL,          # skips HTTP probe when provided (TenantAuth field)

        [string]$ClientId,                   # ClientCredentials: OAuth2 client ID
                                             # Interactive: pre-fill username (prompted if absent)
        [System.Security.SecureString]$ClientSecret,

        [System.Management.Automation.PSCredential]$Credential,

        [string]$WebView2AssemblyPath        # SSO only
    )
    # Returns: [PSCustomObject] token object
}

function Update-ISPSSAuthToken {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$TokenObject          # Must have valid _RefreshContext
    )
    # Returns: [PSCustomObject] refreshed token object
    # ClientCredentials: attempts refresh_token grant; falls back to full re-auth on failure
    # Interactive / SSO: re-runs the full interactive flow
}

function Resolve-IdentityTenantURL {
    param(
        [Parameter(Mandatory)]
        [string]$PCloudSubdomain,

        [string]$ExistingIdentityHost         # Returns immediately if provided (cache hit)
    )
    # Returns: [string] full Identity URL (e.g. 'https://acme.id.cyberark.cloud')
}
```

---

### CyberArk.Auth.SelfHosted.psm1

```powershell
function Get-SelfHostedAuthToken {
    param(
        # NOT actually [Parameter(Mandatory)] in the implementation, despite being
        # conceptually required - both AuthMethod and PVWAUrl fall back to an interactive
        # Read-Host prompt when omitted (deliberately, per Auth-Module-Rework-Design.md
        # "prompts for missing mandatory inputs only when not provided - same as today").
        # A caller expecting the PowerShell binding engine to reject a missing value outright
        # (e.g. an unattended/scheduled script) will instead hang on the prompt.
        [ValidateSet('CyberArk','LDAP','RADIUS','Shared','PKI','PKIPN','SAML','OIDC')]
        [string]$AuthMethod,

        [string]$PVWAUrl,                    # Full URL including AppName (e.g. https://pvwa.co/PasswordVault)

        [System.Management.Automation.PSCredential]$Credential,

        [string]$Username,

        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$CertificateThumbprint,      # Alternative to Certificate object

        [switch]$ConcurrentSession,

        [switch]$IgnoreSSL,

        [string]$WebView2AssemblyPath        # SAML / OIDC only
    )
    # Returns: [PSCustomObject] token object
}

function Update-SelfHostedAuthToken {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$TokenObject          # Must have valid _RefreshContext
    )
    # Returns: [PSCustomObject] refreshed token object
    # Re-authenticates using the same method and credentials stored in _RefreshContext
}
```

---

## Standard Result Object

Returned by every API module entry point (`Invoke-<Category><Action>`).
The driver reads this object to display results, write output CSVs, and update the session summary.

```powershell
[PSCustomObject]@{
    ModuleName     = [string]                                    # From $ModuleMeta.Name
    Category       = [string]                                    # From $ModuleMeta.Category
    Action         = [string]                                    # From $ModuleMeta.Action
    ItemsProcessed = [int]                                       # Total rows attempted
    Successes      = [int]                                       # Rows that succeeded
    Failures       = [int]                                       # Rows that failed
    IsFatal        = [bool]                                      # $true = abort CSV loop, return to menu
    Results        = [System.Collections.Generic.List[PSCustomObject]]  # Success items
    Errors         = [System.Collections.Generic.List[PSCustomObject]]  # Failure items
}
```

### Error item shape (added to `$result.Errors`)

```powershell
[PSCustomObject]@{
    InputData    = [hashtable]    # The input row that caused the failure
    ErrorMessage = [string]       # Human-readable summary
    ErrorDetails = [object]       # Parsed CyberArk error object, or $null
}
```

### Invariants

- `ItemsProcessed` must equal `Successes + Failures` at every return path.
- Every code path must return `$result` — including early returns on validation failure.
- `IsFatal = $true` causes the driver to break the CSV loop immediately and return to the menu.
- `Results` and `Errors` are typed lists — use `.Add()`, not `+=`.

### IsFatal conditions

| Condition | IsFatal |
|---|---|
| HTTP 401 Unauthorized | `$true` |
| Network unreachable | `$true` |
| Token refresh failed | `$true` |
| CSV schema validation failure | `$true` (set before processing begins) |
| HTTP 403 Forbidden | `$false` |
| HTTP 404 Not Found | `$false` |
| HTTP 409 Conflict | `$false` |
| Single-item validation failure | `$false` |

---

## Module Metadata Contract

Declared as `$ModuleMeta` — the first statement in every module file.
The driver reads this block during module discovery.

```powershell
$ModuleMeta = @{
    Name             = [string]     # Display name in the action menu
    Category         = [string]     # Must match the folder name under APIModules\
    Action           = [string]     # Short verb: List | Get | Add | Update | Delete | etc.
    Description      = [string]     # One-sentence description shown in the menu
    SupportedSystems = [string[]]   # @('ISPSS') | @('SelfHosted') | @('ISPSS','SelfHosted')
    SupportsWhatIf   = [bool]       # $true for any write, modify, or delete operation
    AcceptsInputFile = [bool]       # $true if the module processes CSV row input
    ProducesOutput   = [bool]       # $true if results should be offered for save-to-file
    HasCustomInput   = [bool]       # $true if Get-<Category><Action>Input is defined
    InputSchema      = [hashtable[]] # Required when AcceptsInputFile = $true (see below)
    Version          = [string]     # Semantic version: '1.0.0'
}
```

### InputSchema row shape

```powershell
@{
    Column      = [string]   # Exact CSV column header name (case-sensitive)
    Required    = [bool]     # $true = driver rejects the file if this column is absent
    Description = [string]   # Shown to the user during schema validation errors
}
```

---

## Module Entry Point Contract

### Signature

```powershell
function Invoke-<Category><Action> {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token,

        [Parameter(Mandatory = $false)]
        [hashtable]$InputData,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )
}
```

### Custom Input Function Signature (when `HasCustomInput = $true`)

```powershell
function Get-<Category><Action>Input {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token,

        [Parameter(Mandatory = $false)]
        [hashtable]$Defaults    # Pre-filled values for Copy / Edit context; may be $null
    )
    # Returns: [hashtable] with keys matching InputSchema column names
}
```

### How the driver calls a module

```powershell
# Interactive single-item mode
$inputData = if ($meta.HasCustomInput) {
    & "Get-$($meta.Category)$($meta.Action)Input" -Token $token
} else {
    Invoke-InteractiveInput -Schema $meta.InputSchema
}
$result = & "Invoke-$($meta.Category)$($meta.Action)" -Token $token -InputData $inputData -WhatIf:$whatIfMode

# CSV mode (driver loops; module called once per row)
foreach ($row in $csvRows) {
    $inputData = @{}
    foreach ($col in $row.PSObject.Properties) { $inputData[$col.Name] = $col.Value }
    $result = & "Invoke-$($meta.Category)$($meta.Action)" -Token $token -InputData $inputData -WhatIf:$whatIfMode
    if ($result.IsFatal) { break }
}
```

---

## API Response Object

Returned by `Invoke-CyberArkAPI` (from `CyberArkComms.psm1`).
Every module must check `IsSuccess` before accessing `Data`.

```powershell
[PSCustomObject]@{
    IsSuccess         = [bool]      # $true for HTTP 200-299; $false for all other codes
    StatusCode        = [int]       # Actual HTTP status code (200, 201, 400, 401, 404, 429, etc.)
    StatusMessage     = [string]    # Plain-language description (e.g., 'OK', 'Not Found')
    ErrorMessage      = [string]    # $null on success; human-readable error summary on failure
    ErrorDetails      = [object]    # $null on success; parsed CyberArk error body on failure
    Data              = [object]    # PSCustomObject for JSON; byte[] for File; raw string for Binary
    RawResponse       = [string]    # Raw response body string — empty for a File response, since
                                     # Data holds the actual bytes and a string can't represent them
    DataType          = [string]    # 'JSON' | 'Binary' | 'File' | 'Empty'
    SuggestedFileName = [string]    # Filename from the response's Content-Disposition header -
                                     # populated only for DataType='File'; $null otherwise
}
```

### How `DataType` is determined (not by guessing from a JSON-parse attempt)

`Invoke-CyberArkAPI` inspects the actual response headers rather than trying `ConvertFrom-Json` and
catching failure:

- **`File`** — the response is binary (e.g. a downloaded platform `.zip` from `Platforms/Export`).
  Determined either because `Invoke-WebRequest` itself already returned `.Content` as a `byte[]`
  (the normal case for a correctly-labeled `Content-Type` like `application/octet-stream`/
  `application/zip`), or because a `Content-Disposition` header is present alongside a non-JSON
  `Content-Type` (a file mislabeled with something like `text/html`). In the second case, the exact
  original bytes are read from `RawContentStream`, never from `.Content` — confirmed live that
  `.Content` can irreversibly corrupt binary data once `Invoke-WebRequest` has decoded it as text
  (see `Lessons-Learned-PowerShell-Pester.md` Section 39).
- **`JSON`** — `.Content` is a string that parses successfully via `ConvertFrom-Json` (the normal
  case for nearly every other endpoint).
- **`Binary`** — a string response that isn't valid JSON and wasn't identified as a file above
  (e.g. an unexpected plain-text or HTML error page). Kept for backward compatibility; not used by
  any module today.
- **`Empty`** — no response body at all (e.g. HTTP 204).

### CyberArk error body shape (ErrorDetails)

When CyberArk returns a structured error, `ErrorDetails` contains the parsed object:

```powershell
[PSCustomObject]@{
    ErrorCode    = [string]   # CyberArk error code (e.g., 'PASWS041E')
    ErrorMessage = [string]   # Human-readable message from CyberArk
    Details      = [object]   # Additional detail fields (varies by API and error type)
}
```

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
| `IgnoreSSL` | bool | Bypasses SSL certificate validation. Applied process-wide (a .NET Framework/PS 5.1 limitation - see Architecture.md's Design Decisions table), but correctly reset the moment a call is made with this `false` - so switching to a different profile that doesn't set it no longer leaves a previous profile's bypass silently active. Also applies inside the WebView2 browser control used for SAML/OIDC login, which has its own separate certificate-error handling. |
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
