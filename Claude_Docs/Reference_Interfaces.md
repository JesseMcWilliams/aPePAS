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
        [PSCustomObject]$TokenObject,         # Must have valid _RefreshContext
        [switch]$NoPrompt                     # See Testing_Findings-and-Known-Issues.md K12
    )
    # Returns: [PSCustomObject] refreshed token object
    # ClientCredentials: attempts refresh_token grant; falls back to full re-auth on failure - always silent
    # Interactive: re-runs the challenge flow. Silent (no prompt at all) only when _RefreshContext
    #              has a Credential AND the identity's policy resolves to a single password-only
    #              ('UP') mechanism - otherwise prompts as before, UNLESS -NoPrompt is set, in
    #              which case it throws instead of prompting (Testing_Findings-and-Known-Issues.md K12/F62).
    # SSO: always re-opens the WebView2 browser window - never silent, -NoPrompt has no effect
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
        # Read-Host prompt when omitted (deliberately, per Archive_Design_Auth-Module-Rework.md
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
  (see `Reference_Lessons-Learned-PowerShell.md` Section 11).
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

## Driver Profile, Token File, Output CSV, Log Format and Configuration

These contracts are in [Reference_Interfaces-Driver-and-Files.md](Reference_Interfaces-Driver-and-Files.md).
