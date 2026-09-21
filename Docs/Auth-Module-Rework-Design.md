# Auth Module Rework Design

Tracks the design decisions and implementation plan for splitting `Auth\Get-AuthToken.ps1`
into two focused authentication modules plus a shared common layer.

**Status:** Implemented
**Initiated:** 2026-08-17
**Completed:** 2026-08-17

---

## 1. Motivation

`Get-AuthToken.ps1` is a 1 600-line monolith with three distinct concerns mixed together:

| Concern | Lines (approx.) |
|---|---|
| ISPSS authentication logic | ~320 |
| Self-Hosted authentication logic | ~220 |
| WebView2 browser window (shared) | ~150 |
| Public orchestration (`Get-AuthToken`, `Update-AuthToken`) | ~130 |
| Profile persistence (`Save/Import-AuthToken` etc.) | ~400 |
| Helpers + constants | ~200 |

Problems this causes:
- `Get-AuthToken` has 13 parameters, most of which apply to only one system type.
- `Update-AuthToken` dispatches across 9+ auth methods with shared scope — a fix for one ISPSS path risks breaking SelfHosted paths.
- Token refresh and fresh auth are conflated: `Get-AuthToken -TokenToRefresh` is a hidden second entry point.
- Profile persistence is unrelated to authentication but lives in the same file.
- The file is dot-sourced as a script, not loaded as a module — there is no export surface, no private scope, and no isolation.

---

## 2. Proposed Module Structure

```
Auth\
  CyberArk.Auth.Common.psm1       # shared types, WebView2, profile persistence
  CyberArk.Auth.ISPSS.psm1        # Privilege Cloud / CyberArk Identity auth only
  CyberArk.Auth.SelfHosted.psm1   # Self-Hosted PVWA auth only
```

The current `Get-AuthToken.ps1` becomes a thin compatibility shim or is removed
once all call sites are updated to use the new module functions.

### Module loading

Driver imports all three modules at startup. The Driver already knows which
system type a session is using (`$script:SessionToken.SystemType`), so it can
call the correct module directly without any `SystemType` routing inside the modules.

```powershell
Import-Module (Join-Path $PSScriptRoot 'Auth\CyberArk.Auth.Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'Auth\CyberArk.Auth.ISPSS.psm1')
Import-Module (Join-Path $PSScriptRoot 'Auth\CyberArk.Auth.SelfHosted.psm1')
```

---

## 3. Public API Surface

### 3.1 CyberArk.Auth.Common.psm1

Responsibilities: token object factory, SecureString helpers, WebView2 browser window,
profile persistence, certificate picker.

**Exported functions:**

| Function | Purpose |
|---|---|
| `New-AuthTokenObject` | Creates the standard token PSCustomObject — the shared return contract |
| `ConvertTo-PlainText` | SecureString → plain text (kept public so modules can import it) |
| `Import-WebView2Assembly` | Loads WebView2 DLL; memoises path |
| `Invoke-WebView2Window` | Opens browser window; used by ISPSS SSO and SelfHosted SAML/OIDC |
| `Get-FilteredClientCertificate` | Certificate store picker; used by SelfHosted PKI/PKIPN |
| `Save-AuthToken` | DPAPI-serialises token to `.cred` file |
| `Import-AuthToken` | Loads and optionally auto-refreshes a saved token |
| `Get-AuthTokenProfiles` | Lists all saved profiles |
| `Remove-AuthTokenProfile` | Deletes a saved profile |

**Constants that move here:**
- `WEBVIEW2_TIMEOUT_SEC`
- `CLIENT_AUTH_OID`

---

### 3.2 CyberArk.Auth.ISPSS.psm1

Responsibilities: all CyberArk Identity / Privilege Cloud authentication.
Imports `CyberArk.Auth.Common.psm1`.

**Exported functions:**

```powershell
function Get-ISPSSAuthToken {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ClientCredentials','Interactive','SSO')]
        [string]$AuthMethod,

        [Parameter(Mandatory)]
        [string]$PCloudSubdomain,

        [string]$IdentityTenantURL,         # skips discovery when provided (TenantAuth profile field)

        [string]$ClientId,                  # ClientCredentials: OAuth2 client ID
                                            # Interactive: username (optional — prompted if absent)
        [System.Security.SecureString]$ClientSecret,

        [System.Management.Automation.PSCredential]$Credential,

        [string]$WebView2AssemblyPath       # SSO only — path to WebView2 DLL
    )
}

function Update-ISPSSAuthToken {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$TokenObject        # existing token with valid _RefreshContext
    )
}

function Resolve-IdentityTenantURL {
    param(
        [Parameter(Mandatory)]
        [string]$PCloudSubdomain,

        [string]$ExistingIdentityHost       # returns immediately if provided
    )
}
```

**Private (not exported):**
- `Invoke-ISPSSClientCredentials`
- `Invoke-IdentityAdvancedAuth`
- `Invoke-IdentityChallengeLoop`
- `Invoke-ISPSSInteractive`
- `Invoke-ISPSSSO`

**Constants that move here:**
- `PCLOUD_BASE_TEMPLATE`
- `VALID_AUTH_METHODS['ISPSS']`

**What `Get-ISPSSAuthToken` does (vs. current `Get-AuthToken`):**
- No `SystemType` parameter — it is implied by the function name.
- No `TokenToRefresh` parameter — use `Update-ISPSSAuthToken` explicitly.
- No `PVWAUrl`, `ConcurrentSession`, `Certificate`, `CertificateThumbprint`, `IgnoreSSL` — those are SelfHosted only.
- Prompts for missing mandatory inputs (`AuthMethod`, `PCloudSubdomain`, `ClientId` etc.) only when not provided — same as today.

---

### 3.3 CyberArk.Auth.SelfHosted.psm1

Responsibilities: all Self-Hosted PVWA authentication.
Imports `CyberArk.Auth.Common.psm1`.

**Exported functions:**

```powershell
function Get-SelfHostedAuthToken {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CyberArk','LDAP','RADIUS','Shared','PKI','PKIPN','SAML','OIDC')]
        [string]$AuthMethod,

        [Parameter(Mandatory)]
        [string]$PVWAUrl,

        [System.Management.Automation.PSCredential]$Credential,

        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$CertificateThumbprint,     # alternative to Certificate object

        [switch]$ConcurrentSession,

        [switch]$IgnoreSSL,

        [string]$WebView2AssemblyPath       # SAML / OIDC only
    )
}

function Update-SelfHostedAuthToken {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$TokenObject
    )
}
```

**Private (not exported):**
- `Invoke-PVWALogon`
- `Invoke-SelfHostedPasswordAuth`
- `Invoke-SelfHostedShared`
- `Invoke-SelfHostedPKI`
- `Invoke-SelfHostedSAML`
- `Invoke-SelfHostedOIDC`

**Constants that move here:**
- `PVWA_SESSION_EXPIRY_MIN`
- `PVWA_LOGON_PATHS`
- `VALID_AUTH_METHODS['SelfHosted']`

---

## 4. Driver Changes

### 4.1 Invoke-TokenRefresh simplification

The current three-branch `Invoke-TokenRefresh` becomes a two-branch dispatch.
The "which module to call" decision is made in the Driver (it already has `$script:SessionToken.SystemType`).

```powershell
function Invoke-TokenRefresh {
    $status = Test-TokenExpiry
    if ($status -eq 'Valid') { return $true }

    if ($script:SessionToken.SystemType -eq 'ISPSS') {
        # Always try Update-ISPSSAuthToken — it handles silent refresh
        # (ClientCredentials refresh_token grant) and falls back to interactive re-auth
        $shouldProceed = $true
        if ($script:SessionToken.AuthMethod -ne 'ClientCredentials') {
            Write-Host '  Your session token has expired. Press Enter to re-authenticate, or X to exit: ' -NoNewline -ForegroundColor White
            $r = (Read-Host).Trim()
            $shouldProceed = $r -notmatch '^[Xx]$'
        }
        if (-not $shouldProceed) { return $false }
        try {
            $refreshed = Update-ISPSSAuthToken -TokenObject $script:SessionToken
            # ... save and return $true
        } catch { ... return $false }
    }

    if ($script:SessionToken.SystemType -eq 'SelfHosted') {
        # Password methods: prompt for password only, pre-fill username
        # All other: call Update-SelfHostedAuthToken directly
        # ... (same logic as today, but calling Update-SelfHostedAuthToken)
    }
}
```

### 4.2 Connect / Test Connection call sites

Replace `Get-AuthToken -SystemType 'ISPSS' ...` with `Get-ISPSSAuthToken ...`
and `Get-AuthToken -SystemType 'SelfHosted' ...` with `Get-SelfHostedAuthToken ...`.

The profile's `SystemType` field drives which function to call — no change to profile structure needed.

### 4.3 No `TokenToRefresh` on fresh auth paths

Current Driver code passes `-TokenToRefresh` to `Get-AuthToken` in `Invoke-TokenRefresh`.
After the split, the Driver calls `Update-ISPSSAuthToken` or `Update-SelfHostedAuthToken` directly
with no hidden dual-purpose entry point.

---

## 5. Refresh / Re-auth Improvements (implement alongside the split)

These are low-effort wins that the refactor makes easier to implement cleanly:

### 5.1 Proactive refresh for ClientCredentials (high priority)

Check remaining token lifetime at the top of the session loop — before showing the action menu.
If remaining < proactive threshold (e.g. 10 min) and method is ClientCredentials, silently refresh
without any user prompt. The user never sees the expiry.

```powershell
$script:ProactiveRefreshThresholdMin = 10

function Invoke-ProactiveRefresh {
    if ($script:SessionToken.AuthMethod -ne 'ClientCredentials') { return }
    if ((Get-TokenRemainingMinutes) -gt $script:ProactiveRefreshThresholdMin) { return }
    # call Update-ISPSSAuthToken silently
}
```

Call `Invoke-ProactiveRefresh` at the top of the session loop before the action menu is drawn.

### 5.2 Distinguish 401 vs 403 (high priority)

`Invoke-TokenInvalidate` currently fires on any fatal response. A 403 means the token is valid
but the account lacks permission — re-auth will not fix it.

```powershell
function Invoke-TokenInvalidate {
    param([int]$StatusCode)
    if ($StatusCode -eq 403) {
        Write-Host '  Access denied (403) — re-authentication will not help.' -ForegroundColor Red
        return  # do not expire the token
    }
    # 401 only: expire and trigger re-auth
    $script:SessionToken.Expiry = [DateTime]::MinValue
    # delete .cred file
}
```

### 5.3 Transient retry on refresh failure (medium priority)

If `Update-ISPSSAuthToken` throws on a network error (not a 401/400 auth error), retry
up to 2 times with a 3-second back-off before surfacing the re-auth prompt.

```powershell
$maxRetries = 2
$attempt = 0
while ($attempt -le $maxRetries) {
    try {
        $refreshed = Update-ISPSSAuthToken -TokenObject $script:SessionToken
        break
    } catch {
        if ($_.Exception.Message -match '401|400|invalid_grant') { throw }
        $attempt++
        if ($attempt -le $maxRetries) { Start-Sleep -Seconds 3 }
    }
}
```

### 5.4 Clear unused _RefreshContext credential fields (medium priority)

After session start, clear credential fields that cannot be used for silent refresh.
This reduces the exposure window for Interactive/SSO sessions.

```powershell
function Clear-NonRefreshableContext {
    param([PSCustomObject]$Token)
    if ($Token.AuthMethod -in @('Interactive','SSO','SAML','OIDC')) {
        $Token._RefreshContext.Remove('Credential')
        $Token._RefreshContext.Remove('ClientSecret')
    }
}
```

Call this immediately after Connect sets `$script:SessionToken`.

---

## 6. Decisions Required

These questions must be decided before implementation begins:

| # | Question | Options | Recommendation |
|---|---|---|---|
| D1 | **Module format** | `.psm1` (Import-Module) vs `.ps1` (dot-source as today) | `.psm1` — proper private scope, explicit exports, testable |
| D2 | **WebView2 placement** | Common module vs duplicate in each module | Common — ~150 lines shared code, no duplication |
| D3 | **`Get-AuthToken` backward compat** | Remove it, keep as wrapper, keep both | Remove — the split is the point; update all call sites |
| D4 | **`Get-FilteredClientCertificate` placement** | Common vs SelfHosted module | Common — it is a certificate store utility, not SelfHosted-specific |
| D5 | **`ConvertTo-PlainText` visibility** | Exported vs internal to Common | Internal (module private) — callers should not need it directly |
| D6 | **Driver `Invoke-TokenRefresh` ownership** | Stay in Driver vs move into modules | Stay in Driver — it owns the UX (prompts, re-auth flow); modules own the auth mechanics |
| D7 | **Proactive refresh threshold** | Hard-coded 10 min vs profile field | Hard-coded constant to start; promote to profile field if per-environment needs differ |

---

## 7. File Layout After Rework

```
Auth\
  CyberArk.Auth.Common.psm1       # New — token object, WebView2, certificate picker, persistence
  CyberArk.Auth.ISPSS.psm1        # New — ISPSS auth + refresh
  CyberArk.Auth.SelfHosted.psm1   # New — SelfHosted auth + refresh
  Get-AuthToken.ps1                # Kept temporarily as shim, then removed
```

---

## 8. Implementation Order

1. Create `CyberArk.Auth.Common.psm1` — move shared functions; no auth logic yet.
2. Create `CyberArk.Auth.ISPSS.psm1` — move all ISPSS functions; export three public functions.
3. Create `CyberArk.Auth.SelfHosted.psm1` — move all SelfHosted functions; export two public functions.
4. Update Driver import block to `Import-Module` all three.
5. Update Driver call sites (`Invoke-TokenRefresh`, Connect, Test Connection) to use new function names.
6. Add proactive refresh (Section 5.1) to session loop.
7. Fix 401 vs 403 handling (Section 5.2).
8. Delete `Get-AuthToken.ps1` shim once all call sites are updated.
9. Update `Interfaces.md` — new module names, new public function signatures.
10. Update `Architecture.md` — new Auth folder structure.
11. Update `Testing-Plan.md` — new test file names.

---

## 9. Revision Log

| Date | Change |
|---|---|
| 2026-08-17 | Document created — initial design draft |
| 2026-08-17 | Implementation complete — all three modules created; Driver updated |
| 2026-09-02 | Step 8 (delete `Get-AuthToken.ps1` shim) completed — confirmed zero real call sites remained and deleted the file. `README.md` and `API-Module-Development-Guide.md` project-structure trees updated to drop the reference. Steps 9-11 (Interfaces.md/Architecture.md/Testing-Plan.md updates) were already done in the original 2026-08-17 implementation pass; this entry closes out the one item (step 8) left open since then |
