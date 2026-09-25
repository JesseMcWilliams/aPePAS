# CyberArk PAS Scripts — Architecture Overview

## Purpose

A PowerShell-based driver for interacting with CyberArk Privilege Access Security (PAS) REST APIs
across both ISPSS (Privilege Cloud SaaS) and Self-Hosted PAM deployments. The system provides
profile-managed, authenticated sessions, a categorized interactive action menu, robust logging,
and a pluggable API module system that allows new API operations to be added without modifying
the driver.

---

## Build Status

| Component | Status |
|---|---|
| `Auth\CyberArk.Auth.Common.psm1` | Complete |
| `Auth\CyberArk.Auth.ISPSS.psm1` | Complete |
| `Auth\CyberArk.Auth.SelfHosted.psm1` | Complete |
| `Modules\CyberArkLogging.psm1` | Complete |
| `Modules\CyberArkComms.psm1` | Complete |
| `Modules\CyberArkCredentialStore.psm1` | Complete |
| `Manage-Privilege.ps1` | Complete |
| API Modules (67 modules across 10 categories) | Complete |

---

## Component Diagram

```
  ┌──────────────────────────────────────────────────────────────────┐
  │                       Manage-Privilege.ps1                        │
  │                                                                   │
  │  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────────┐  │
  │  │    Profile      │  │    Session       │  │  Module Loader  │  │
  │  │   Management   │  │    Lifecycle     │  │  Action Menu    │  │
  │  └────────┬────────┘  └────────┬─────────┘  └────────┬────────┘  │
  └───────────┼────────────────────┼────────────────────┼────────────┘
              │                    │                     │
              ▼                    ▼                     ▼
  ┌───────────────────┐  ┌─────────────────────────────────┐  ┌─────────────────────┐
  │   Profile Files   │  │         Auth Modules            │  │    API Modules      │
  │  <Name>.json      │  │  CyberArk.Auth.Common.psm1      │  │  APIModules\<Cat>\  │
  │  <Name>.cred      │  │  CyberArk.Auth.ISPSS.psm1       │  │  Invoke-<Cat><Act>  │
  └───────────────────┘  │  CyberArk.Auth.SelfHosted.psm1  │  └──────────┬──────────┘
                         └─────────────────────────────────┘
                                                           │
                    ┌──────────────────────────────────────┘
                    ▼
       ┌────────────────────────┐     ┌──────────────────────────┐
       │   CyberArkComms.psm1  │     │  CyberArkLogging.psm1    │
       │   (Shared Comms)      │     │  (Logging)               │
       └────────────┬───────────┘     └──────────────────────────┘
                    │                         ▲
                    │            used by all components
                    ▼
       ┌────────────────────────┐
       │   CyberArk REST API   │
       │  ISPSS / Self-Hosted  │
       └────────────────────────┘
```

---

## Folder Structure

```
aPePAS\
├── Manage-Privilege.ps1                # Interactive driver script
├── Auth\
│   ├── CyberArk.Auth.Common.psm1       # Shared auth utilities: token object, WebView2, profile persistence
│   ├── CyberArk.Auth.ISPSS.psm1        # Privilege Cloud / CyberArk Identity authentication
│   └── CyberArk.Auth.SelfHosted.psm1   # Self-Hosted PVWA authentication
├── Modules\
│   ├── CyberArkComms.psm1              # Shared REST communications module (pagination, rate limiting, binary/JSON detection)
│   ├── CyberArkLogging.psm1            # Structured log writer
│   └── CyberArkCredentialStore.psm1    # Local DPAPI-encrypted automation-credential store (.autocred files)
├── APIModules\                         # 67 action modules across 10 categories
│   ├── Accounts\                       # 17 actions
│   │   ├── Invoke-AccountsAdd.ps1
│   │   ├── Invoke-AccountsCancelCpmTask.ps1
│   │   ├── Invoke-AccountsChangeImmediate.ps1
│   │   ├── Invoke-AccountsChangeInVault.ps1
│   │   ├── Invoke-AccountsCheckIn.ps1
│   │   ├── Invoke-AccountsDelete.ps1
│   │   ├── Invoke-AccountsGet.ps1
│   │   ├── Invoke-AccountsGetActivity.ps1
│   │   ├── Invoke-AccountsGetCredential.ps1
│   │   ├── Invoke-AccountsLinkAccount.ps1
│   │   ├── Invoke-AccountsList.ps1
│   │   ├── Invoke-AccountsReconcile.ps1
│   │   ├── Invoke-AccountsResumeAutoManagement.ps1
│   │   ├── Invoke-AccountsUnlinkAccount.ps1
│   │   ├── Invoke-AccountsUnlock.ps1
│   │   ├── Invoke-AccountsUpdate.ps1
│   │   └── Invoke-AccountsVerify.ps1
│   ├── Safes\                          # 8 actions
│   │   ├── Invoke-SafesAdd.ps1
│   │   ├── Invoke-SafesAddFromTemplate.ps1
│   │   ├── Invoke-SafesAssignCPM.ps1
│   │   ├── Invoke-SafesDelete.ps1              # Offers a rename-instead fallback on HTTP 409
│   │   ├── Invoke-SafesGet.ps1
│   │   ├── Invoke-SafesList.ps1
│   │   ├── Invoke-SafesUnassignCPM.ps1
│   │   └── Invoke-SafesUpdate.ps1
│   ├── SafeMembers\                    # 6 actions
│   │   ├── Invoke-SafeMembersAdd.ps1
│   │   ├── Invoke-SafeMembersAddFromTemplateRole.ps1
│   │   ├── Invoke-SafeMembersList.ps1
│   │   ├── Invoke-SafeMembersRemove.ps1
│   │   ├── Invoke-SafeMembersUpdate.ps1
│   │   └── Invoke-SafeMembersUpdateFromTemplateRole.ps1
│   ├── Platforms\                      # 10 actions
│   │   ├── Invoke-PlatformsCopy.ps1
│   │   ├── Invoke-PlatformsDisable.ps1
│   │   ├── Invoke-PlatformsEnable.ps1
│   │   ├── Invoke-PlatformsExport.ps1          # Download a platform .zip (all 4 psPAS target types)
│   │   ├── Invoke-PlatformsGet.ps1
│   │   ├── Invoke-PlatformsImport.ps1
│   │   ├── Invoke-PlatformsList.ps1
│   │   ├── Invoke-PlatformsRemove.ps1
│   │   ├── Invoke-PlatformsRename.ps1          # Self-Hosted only (PVWA 15.0+)
│   │   └── Invoke-PlatformsSetPSMConfig.ps1
│   ├── Policies\                       # 2 actions (PVWA 14.6+)
│   │   ├── Invoke-PoliciesGetMasterPolicy.ps1  # Dual-use; confirmed absent on ISPSS, fails gracefully there
│   │   └── Invoke-PoliciesSetMasterPolicy.ps1  # Self-Hosted only
│   ├── Users\                          # 2 actions
│   │   ├── Invoke-UsersGet.ps1
│   │   └── Invoke-UsersList.ps1
│   ├── Groups\                         # 7 actions
│   │   ├── Invoke-GroupsAdd.ps1
│   │   ├── Invoke-GroupsAddMember.ps1          # MemberID is the member's username, not a numeric ID
│   │   ├── Invoke-GroupsDelete.ps1
│   │   ├── Invoke-GroupsGetMembers.ps1
│   │   ├── Invoke-GroupsList.ps1
│   │   ├── Invoke-GroupsRemoveMember.ps1
│   │   └── Invoke-GroupsUpdate.ps1
│   ├── Applications\                   # 7 actions, dual-use
│   │   ├── Invoke-ApplicationsAdd.ps1
│   │   ├── Invoke-ApplicationsAddAuthMethod.ps1
│   │   ├── Invoke-ApplicationsDelete.ps1
│   │   ├── Invoke-ApplicationsDeleteAuthMethod.ps1
│   │   ├── Invoke-ApplicationsGet.ps1
│   │   ├── Invoke-ApplicationsList.ps1
│   │   └── Invoke-ApplicationsListAuthMethods.ps1
│   ├── Reports\                        # 1 action, Self-Hosted only
│   │   └── Invoke-ReportsList.ps1
│   └── Custom\                         # 7 actions
│       ├── Invoke-CustomExportAll.ps1               # Runs every List/ListAuthMethods action (+ opt-in modules) to CSV
│       ├── Invoke-CustomExportEntitlements.ps1      # All safes + members -> single CSV
│       ├── Invoke-CustomExportGroupMembersLDAP.ps1  # LDAP/Directory group members via ADSI
│       ├── Invoke-CustomExportGroupMembersLocal.ps1 # Local group members with nesting
│       ├── Invoke-CustomExportPlatformDetails.ps1   # Every active platform's INI/XML settings -> one CSV
│       ├── Invoke-CustomTestApi.ps1                 # Interactive raw API tester
│       └── Invoke-CustomTestConnectivity.ps1        # DNS/port/credential connectivity tester
├── Profiles\                           # Created at runtime (default: %APPDATA%\IdiraUnifiedScripts\Profiles\)
│   ├── Production.json
│   ├── Production.cred                 # DPAPI-encrypted token
│   ├── Development.json
│   └── Development.cred
├── Claude_Docs\                        # Project docs, named <Stage>_<Topic>.md (see CLAUDE.md)
│   ├── Design_Architecture.md          # This document
│   ├── Design_*.md                     # Current feature designs
│   ├── Planning_*.md                   # Proposals, backlogs (incl. Planning_User-Docs-Backlog.md)
│   ├── Testing_Plan.md                 # Test matrix, open findings, known issues, checklists
│   ├── Reference_*.md                  # Interfaces, API module guide, lessons learned
│   └── Archive_*.md                    # Finished or superseded material - not read by default
└── User_Docs\                          # End-user docs
    ├── User-Guide.md
    └── Features.md
```

---

## Data Flow

### 1. Startup

```
Manage-Privilege.ps1 launched
  └─ Import CyberArkCredentialStore.psm1 (unconditional - see its own section above)
  └─ Check prerequisites (PS version, WebView2 if needed)
  └─ Import CyberArkLogging.psm1
  └─ Import CyberArkComms.psm1
  └─ Import CyberArk.Auth.Common.psm1
  └─ Import CyberArk.Auth.ISPSS.psm1
  └─ Import CyberArk.Auth.SelfHosted.psm1
  └─ Initialize log (PID assigned, file created with 40-star header)
  └─ Scan profile directory → display profile summary
```

### 2. Profile Selection and Authentication

```
User selects / creates / edits profile
  └─ Load <ProfileName>.json (driver settings)
  └─ Validate profile (folders accessible, auth file present)
  └─ Load <ProfileName>.cred via Import-AuthToken (DPAPI decrypt)
  └─ Check token expiry
       ├─ Valid         → proceed to session
       ├─ Expiring soon → ask user: refresh now or proceed?
       └─ Expired       → Update-ISPSSAuthToken (ISPSS: silent refresh_token or re-auth)
                          or Update-SelfHostedAuthToken (Self-Hosted: re-auth)
  └─ Re-initialize log with profile name in filename
  └─ Log session start: profile, SystemType, AuthMethod, BaseURL, WhatIf mode
```

### 3. Main Action Loop

```
Display breadcrumb header  (e.g.  [Production] > Accounts)
Display categorized action menu
User enters choice (number) or navigation (B / B2 / B3)
  ├─ Navigation → update breadcrumb, redisplay menu
  └─ Action selected
       └─ Check token expiry (warn if < TokenExpiryWarningMinutes remaining)
       └─ Collect input
            ├─ Interactive  → driver prompts from InputSchema
            │                  or calls Get-<Category><Action>Input if HasCustomInput
            │                  ID-based modules: blank ID → search by name via Invoke-EntitySearch
            └─ CSV file(s)  → user selects via open-file dialog
                              driver validates schema against InputSchema
       └─ Invoke-<Category><Action> -Token $token -InputData $row -WhatIf:$mode
       └─ Display results (table)
       └─ Offer save to file (prompt defaults to N)
            └─ Yes → save-file dialog → output folder default → write CSV
       └─ Return to menu
```

### 4. CSV Processing (driver loop)

```
For each selected input CSV file:
  └─ Validate columns against module InputSchema
       └─ Missing required column → skip file with WARN log
  └─ Prepare output CSV path: <OutputFolder>\<original>_<yyyy-MM-dd>_output.csv
  └─ For each row in CSV:
       └─ Check token expiry
       └─ Call module entry point with row as InputData
       └─ Append IsSuccess, Summary columns to output CSV
       └─ If result.IsFatal → break loop, return to menu
  └─ Log per-file summary (ItemsProcessed / Successes / Failures)
```

### 5. Session End

```
User selects Exit or Restart
  └─ Self-Hosted: POST /API/auth/Logoff
  └─ Log session summary (all write/modify operations: total / success / failures)
  └─ Save refreshed token back to profile (if token was renewed during session)
  └─ Restart → return to profile selection with current profile as default
     Exit    → script terminates
```

---

## Component Descriptions

### Manage-Privilege.ps1

The top-level interactive script. Owns:
- Profile management (create, edit, copy, delete, use, detail view, test connection)
- Session lifecycle (auth, token expiry monitoring, Self-Hosted keepalive, logoff)
- Module discovery (scans `APIModules\` at session start, builds action menu)
- CSV looping (driver loops over rows; modules handle one row at a time)
- Output file handling (save dialogs, output CSV column appending)
- Session summary logging at exit

### Auth Modules

Three focused `.psm1` modules replace the former `Get-AuthToken.ps1` monolith. Imported by Driver
at startup via `Import-Module`. All functions run in module scope — internal helpers are private.

**`CyberArk.Auth.Common.psm1`** — Shared utilities used by both auth modules and the driver:
- `New-AuthTokenObject` — creates the standard token PSCustomObject (the shared return contract)
- `ConvertTo-PlainText` — SecureString to plain string, zeroes unmanaged memory after use
- `Import-WebView2Assembly` / `Invoke-WebView2Window` — browser-based auth (SSO, SAML, OIDC)
- `Get-FilteredClientCertificate` — certificate store picker (PKI / PKIPN)
- `Save-AuthToken` / `Import-AuthToken` — DPAPI profile persistence (`.cred` files)
- `Get-AuthTokenProfiles` / `Remove-AuthTokenProfile` — profile listing and deletion

**`CyberArk.Auth.ISPSS.psm1`** — Privilege Cloud / CyberArk Identity authentication:
- `Get-ISPSSAuthToken` — fresh auth: `ClientCredentials`, `Interactive`, or `SSO`
- `Update-ISPSSAuthToken` — refresh: silent `refresh_token` grant (CC) or re-auth
- `Resolve-IdentityTenantURL` — discovers the `*.id.cyberark.cloud` tenant URL via HTTP probe

**`CyberArk.Auth.SelfHosted.psm1`** — Self-Hosted PVWA authentication:
- `Get-SelfHostedAuthToken` — fresh auth: `CyberArk`, `LDAP`, `RADIUS`, `Shared`, `PKI`, `PKIPN`, `SAML`, `OIDC`
- `Update-SelfHostedAuthToken` — re-authenticates using stored `_RefreshContext`

See [Reference_Interfaces.md](Reference_Interfaces.md) for token object shape and public function signatures.
See [Archive_Design_Auth-Module-Rework.md](Archive_Design_Auth-Module-Rework.md) for the design rationale.

### CyberArkComms.psm1

The shared REST communications layer. All API calls from the driver and every API module go
through this module. Responsibilities:
- Building and executing HTTP requests against ISPSS or Self-Hosted endpoints
- Transparent pagination (fetches all pages, returns combined result)
- Rate limiting with exponential backoff (logs WARN; fails after `$script:MaxRateLimitRetries`)
- WhatIf blocking (suppresses POST/PUT/PATCH/DELETE; returns synthetic success response)
- Normalizing all responses into the standard response object
- URL joining and query string building helpers

### CyberArkLogging.psm1

Logging module used by all components. Responsibilities:
- Writing formatted log entries to file and/or console
- Enforcing the log format: `PID | yyyy-MM-dd HH:mm:ss | LEVEL   | FunctionName | Message`
- Supporting log levels: VERBOSE, DEBUG, INFO, WARN, ERROR
- Bare mode (message only, no prefix)
- Startup block (40-star line + session header)
- Sensitive data masking
- Log file cleanup by age

### CyberArkCredentialStore.psm1

Local, DPAPI-encrypted store for the automation-mode fallback credential (Testing_Plan.md K06).
Extracted from `Manage-Privilege.ps1` so a standalone helper script - not just the interactive
driver - can read and write the same `.autocred` files. Every function takes an explicit
`-ProfileDir` rather than reading driver-scope state, since `Import-Module` gives it its own
isolated module scope with no visibility into the driver's `$script:ProfileDir`. Imported
unconditionally near the top of `Manage-Privilege.ps1` (not gated behind the dot-source entry-point
guard used for Logging/Comms/Auth), since it has no side effects at import time and its functions
are called by driver code that isn't itself gated - this also means Pester tests that dot-source
the driver get the real module automatically.
- `Get-ProfileCredentialPath` — path of the `<Name>.autocred` file under a given `-ProfileDir`
- `Save-ProfileCredential` — stores a `PSCredential`, DPAPI-encrypted via `Export-Clixml`
- `Get-ProfileCredential` — returns the stored `PSCredential`, or `$null` if none/unreadable
- `Remove-ProfileCredential` — deletes the stored credential, if any

### API Modules (`APIModules\<Category>\Invoke-<Category><Action>.ps1`)

Each file implements one CyberArk API action. Auto-discovered by the driver at session start.
Every module declares a `$ModuleMeta` hashtable and exports one entry-point function
(`Invoke-<Category><Action>`). The driver calls the entry point; the module returns a standard
result object. See [Reference_API-Module-Guide.md](Reference_API-Module-Guide.md).

---

## Design Decisions

| Decision | Choice | Reason |
|---|---|---|
| Profile storage | Two files: JSON + DPAPI XML | JSON for non-sensitive settings (readable without decryption); XML for credentials (DPAPI-protected). Keeps profile listing fast. |
| SystemType in profile | `'Privilege Cloud'` / `'Self-Hosted'` (user-facing labels) | Maps to auth script values `'ISPSS'`/`'SelfHosted'` at call time. User-facing labels are more descriptive than the internal values. Stored in JSON so the edit flow can tailor the Base URL prompt without loading the XML token. |
| Base URL collection | Branched by SystemType | Privilege Cloud: user enters subdomain only; `PCLOUD_BASE_TEMPLATE` in `CyberArk.Auth.ISPSS.psm1` constructs the full URL. Self-Hosted: user enters the full PVWA URL, joined with `AppName`. |
| Credential protection | `Export-Clixml` (DPAPI) | Native PowerShell, no external dependencies. User+machine locked — deliberate trade-off for security over portability. |
| Token string protection | Convert to `SecureString` before `Export-Clixml` | Ensures the bearer token is DPAPI-encrypted in the XML, not stored as plaintext. |
| Browser-based auth | WebView2 over IE `WebBrowser` | IE-based `Windows.Forms.WebBrowser` is deprecated. WebView2 uses the Edge engine, supports modern auth flows, and provides `CookieManager` API. |
| WebView2 token capture | Timer polling (750 ms) over async callbacks | Avoids deadlocks that arise from awaiting Tasks inside `CoreWebView2` async event handlers. |
| WebView2 threading | PowerShell runspace with STA apartment | WinForms requires STA. A dedicated runspace with `ApartmentState = STA` avoids requiring the host process to be STA. |
| CSV looping | Driver loops; module handles one item | Modules stay simple and testable. All file I/O and progress tracking is centralized in the driver. |
| Module discovery | Folder scan + metadata block | Adding a module requires no driver changes. The driver builds the menu from what it finds. |
| Pagination | Handled in shared comms | Modules never need to page. The comms module fetches all pages and returns a combined collection. |
| Pagination collection-property detection | Known-name list first, first array-valued property as fallback | `Find-CyberArkCollectionProperty` in `CyberArkComms.psm1` tries the short list of names CyberArk's current endpoints actually use (`value`, `Safes`, `Members`, `Accounts`, `Users`, `Platforms`, `Groups`) before falling back to generic array-property discovery - same layered approach psPAS's `Get-NextLink.ps1` uses (known names first, then any array-typed property) - so a future endpoint with an unanticipated collection name still paginates instead of silently returning only its first page. |
| SafeMembers `ReadOnly` preset renamed to `ReadOnlyStrict` | Rename, not just a documentation callout | Superseded the Phase 5 plan item ("document that aPePAS's `ReadOnly` role isn't equivalent to PVWA's/psPAS's built-in `ReadOnly`, which grants `retrieveAccounts`") per explicit user direction: rename the preset instead of only documenting the name collision. `Invoke-SafeMembersAdd.ps1`/`Invoke-SafeMembersUpdate.ps1`'s `Get-PermissionSet` has no explicit case for the old name - both `ReadOnly` and `ReadOnlyStrict` fall through to the same `default` branch, so a CSV or saved profile default still carrying the pre-rename name keeps producing the identical (and correct) list/audit/view-only permission set with no migration needed. |
| Profile backup format | Single `.zip` per backup, manual `ZipArchive` byte-stream I/O (not `ZipFile`/`CreateEntryFromFile`) | Per user request, added `Backup-DriverProfiles`/`Restore-DriverProfiles` (`Manage-Privilege.ps1`). One `.zip` can hold multiple profiles' `.json`+`.cred` pairs plus a `_manifest.json` (who/when/which machine). Built with `ZipArchive.CreateEntry()` + raw byte writes rather than `ZipFileExtensions.CreateEntryFromFile()`/`ZipFile.Open()`, since those live in the separate `System.IO.Compression.FileSystem` assembly this project doesn't otherwise depend on - matches the byte-stream pattern `Invoke-CustomExportPlatformDetails.ps1` already established for zip *reading*, extended here to zip *writing* (no prior in-repo precedent for creating a zip to a real file path existed; only a test-fixture helper built one in-memory). |
| Profile restore across machines/users | Restore the `.cred` file as-is; detect and warn via manifest, don't attempt to fix | DPAPI (see the "Credential protection" row above) makes a `.cred` backed up on one Windows user/machine fundamentally undecryptable on another - there's no code-level workaround. `Backup-DriverProfiles`'s manifest records the creating user+machine; `Restore-DriverProfiles` compares it to the current user+machine and returns a `PortabilityWarnings` list the UI surfaces clearly, but still writes the `.cred` file rather than omitting it - a restored-but-undecryptable token degrades gracefully into this driver's pre-existing `TokenStatus = 'Unreadable'` state (the same one any other corrupted/foreign token file already produces), so no new error-handling path was needed for the failure case itself. |
| Shared `Invoke-ProfileConnect` function | Extracted from the profile-detail menu's `'C'` (Connect) case | Added per user request for `-AutoConnect` (skip the interactive menus entirely when `-StartProfile <name>` is given, useful for scripted/scheduled launches). The full ~220-line authenticate/refresh/save flow previously lived inline in one `switch` case; extracting it into a standalone function (returns the profile name on success, `$null` on any failure, with a `-NoPause` switch to suppress interactive `Read-Host` pauses on the unattended auto-connect path) lets both the interactive menu and the new startup path share one authentication code path instead of duplicating it. `-AutoConnect` only applies on the very first pass through the outer restart loop - a session `Restart` always returns to the interactive profile list, matching existing behavior, and any auto-connect failure (profile not found, incomplete, or an auth error) falls back to the normal interactive flow rather than exiting. |
| Rate limiting | Handled in shared comms with backoff | Consistent behavior across all modules. Logged at WARN; fails gracefully after configurable retry limit. |
| WhatIf | Enforced in shared comms layer | Modules forward `$WhatIf.IsPresent` to `Invoke-CyberArkAPI`. No per-module branching needed. |
| Log correlation | PID (not GUID) | Shorter and immediately recognizable. Unique per script session. Filename includes timestamp for uniqueness across sessions with recycled PIDs. |
| Parallel processing | Skipped (sequential only) | Simplicity and PS 5.1 compatibility. Runspace complexity not justified for current use cases. |
| Self-Hosted keepalive | Get Logged On User Details ~2 min before expiry | Attempts to extend the 20-minute PVWA session without requiring re-authentication. |
| ISPSS token expiry | Proactive silent refresh (CC); prompt re-auth for Interactive/SSO | `ClientCredentials` tokens are silently refreshed via `Update-ISPSSAuthToken` when < 10 minutes remain (`ProactiveRefreshThresholdMin`). Interactive/SSO cannot refresh silently — user is prompted. |
| Auth module isolation | Three `.psm1` modules instead of one dot-sourced script | Proper private scope, explicit `Export-ModuleMember` surfaces, testable in isolation, no `SystemType` routing inside auth code. Driver branches externally by `SystemType`. |
| Credential scrubbing | `Invoke-ClearNonRefreshableContext` called after Connect | For Interactive/SSO/SAML/OIDC sessions, `Credential` and `ClientSecret` are removed from `_RefreshContext` in memory after the session token is set. Reduces in-memory credential exposure for methods that cannot silently refresh. |
| Navigation | `B` = back 1, `B2` = back 2, etc. | Unambiguous — `B` prefix cannot conflict with numeric menu options. |
| Default folders | Launch directory when profile has empty strings | Predictable fallback that works without any profile configuration. |
| Action menu ordering | `List` always first within each category; remaining actions sorted alphabetically by name (categories are likewise sorted alphabetically) | Users almost always want to list before acting; alphabetical order otherwise is the least surprising default and needs no per-module upkeep. Changed 2026-09-02 (per user request) from sorting the remainder by the numeric `Priority` field, which had drifted into an arbitrary, hard-to-maintain order not tied to any specific top/bottom placement request. `Priority` remains on `ModuleMeta` as a place to anchor a future explicit top/bottom-of-list request, but is otherwise unused. |
| Table display truncation | Driver truncates List actions and all Custom export operations to `DisplayLimit` rows (default 20); full data still exported to CSV | Avoids flooding the terminal with hundreds of rows while keeping the full dataset available for downstream processing. Condition is `Action -eq 'List'` OR `Category -eq 'Custom' -and ProducesOutput`. Configurable per-profile. 0 = show all. |
| Accounts List — By-Safe mode | Optional mode fetches accounts per-safe rather than a single global query | CyberArk's `/API/Accounts` endpoint caps returns at ~20,000 accounts without a safe filter. Per-safe iteration bypasses this limit while remaining within the existing pagination infrastructure. |
| Role profile fields | `Role_Template_Safe` and `Role_Group_Prefix` stored in the profile, not hardcoded | These values are environment-specific (safe naming conventions, group prefix conventions differ per tenant). Storing them in the profile makes modules portable across environments. First consumed by `Safes/AddFromTemplate` (see `Claude_Docs\Design_Add-Safe-From-Template.md`). |
| Add Safe From Template — role-group exclusion | Exclude any template member (any `memberType`) whose name starts with `Role_Group_Prefix`, case-insensitive; every other member is copied | Both fields are required on the active profile — a blank prefix fails fast rather than silently copying role groups. Filtering by name prefix (not `memberType`) matches how `Role_Group_Prefix` was already documented in `Reference_Interfaces.md` before this feature existed. |
| Add Safe From Template — settings vs. identity fields | `SafeName` and `Description` are always fresh input; `Location` and `AutoPurgeEnabled` are copied from the template safe; member `membershipExpirationDate` is never copied. `ManagingCPM` is no longer copied from the template (see the CPM picker row below) | Description and expiration are contextual to the specific safe/membership being created, not properties of the "shape" a template is meant to standardize. |
| Safe retention fields are mutually exclusive | `NumberOfVersionsRetention` and `NumberOfDaysRetention` are never both sent on `POST`/`PUT /API/Safes` — `NumberOfDaysRetention` is sent only when greater than 0, otherwise `NumberOfVersionsRetention` is sent | The API treats these as a single choice of retention mode, not two independent settings. Applies to `Invoke-SafesAdd.ps1`, `Invoke-SafesUpdate.ps1`, and `Invoke-SafesAddFromTemplate.ps1`. |
| `OLACEnabled` is not a supported field | Never read, prompted for, or sent by any Safes write module | Confirmed not a valid input for this API; removed from `Invoke-SafesAdd.ps1`, `Invoke-SafesUpdate.ps1`, and `Invoke-SafesAddFromTemplate.ps1` after initial implementations mistakenly included it. |
| Add Safe From Template — global member exclusion list | `$script:ExcludedTemplateMemberNames` defined once in `Manage-Privilege.ps1` (dot-sourced into every module's scope, same mechanism as `$script:ActiveProfile`), not a profile field | This is an environment-wide policy ("never copy these specific members from any template safe"), not a per-tenant setting like `Role_Group_Prefix` — a single hardcoded list, editable directly in `Manage-Privilege.ps1`, is simpler than adding a new profile field and keeps the door open for other Safes/SafeMembers modules to reuse the same constant. |
| Request body and error logging | POST/PUT/PATCH bodies and HTTP 4xx/5xx response bodies logged at DEBUG level with `-FileOnly` | Large structured content would flood the terminal at DEBUG. Writing to the log file only preserves the diagnostic data for post-session review without cluttering the console. Sensitive fields are masked by `Mask-SensitiveData` before the entry is written. |
| HTTP 504 retry (`Invoke-CyberArkAPI`) | Fixed 5-second delay (`$script:GatewayTimeoutDelaySec`), up to `$script:MaxGatewayTimeoutRetries` (default 2) retries; if pagination is in use, the page size is reduced by 25% before each retry | A 504 usually means the request itself was too expensive for the server to finish within its own timeout window (unlike 429, which is unrelated to request size) — a fixed delay (not exponential backoff) plus a smaller page size directly addresses the likely cause rather than just waiting longer. Same `$offset` is retried, so no items are skipped or duplicated. |
| Add Safe Member — interactive SearchIn picker | Numbered menu (Vault always first, plus directories from `GET /API/Configuration/LDAP/Directories`) replaces free-text entry, interactive mode only; CSV/bulk input via `InputSchema` is unchanged | Free-text UUID entry was error-prone; a picker removes the need to already know the directory ID. Falls back to Vault-only (never blocks the flow) if the directory lookup fails — the exact response field names for that endpoint are unconfirmed against a live system as of this writing (see `Claude_Docs\Reference_Lessons-Learned.md` Section 12.2), so the mapping defensively probes several plausible field names rather than assuming one. |
| SafeMembers — AddFromTemplateRole / UpdateFromTemplateRole | New actions that resolve permissions from a "role" — a member of `Role_Template_Safe` whose name starts with `Role_Group_Prefix` — instead of the ReadOnlyStrict/EndUser/PowerUser/SafeManager presets or manual per-permission entry. The role is picked from a numbered Index/Name menu (interactive) or supplied as an exact `RoleName` (CSV/bulk); permissions are copied verbatim from the matched role member, same as `Safes/AddFromTemplate`'s member-copy approach | Lets an admin grant "the same access as role X" without re-deriving or duplicating that role's exact permission set by hand. Uses the same `Role_Template_Safe`/`Role_Group_Prefix` fields already established for `Safes/AddFromTemplate`, but filters for role-prefixed members instead of excluding them — the opposite side of that same filter. `RoleName` match is exact and case-insensitive, not a prefix match (consistent with how `$script:ExcludedTemplateMemberNames` matches). The global `$script:ExcludedTemplateMemberNames` list does NOT apply here — that list governs which members are copied when stamping a new safe, a different concern from which role a member's permissions are drawn from. |
| Profile CPM list (`CPM_List`) | A comma-separated list of CPM usernames maintained manually via Profile Settings | **Superseded 2026-09-03 (see the `Get-CpmOptions` row below)** - was previously not queried live at all for `Safes/AddFromTemplate`'s picker, while `Safes/AssignCPM.ps1` used a live query instead and never consulted `CPM_List`, "per explicit direction, not an oversight." Per a later, explicit user direction, that split no longer applies: `CPM_List` is now the fallback for every CPM picker, used only when the live query fails. |
| `Get-CpmOptions` — shared CPM source for every "pick a CPM" prompt | A single function in `Manage-Privilege.ps1` (alongside `Invoke-EntitySearch`, `Show-FieldPrompt`, etc.) queries `GET /API/Users?userType=CPM&componentUser=true` live; whenever that call succeeds - even with zero results, which is a real environment state, not a failure - its result is used. Only on failure or a thrown exception does it fall back to the profile's `CPM_List`. Used by `Safes/Add`, `Safes/AddFromTemplate`, and `Safes/AssignCPM` as of 2026-09-03, replacing three separate, inconsistent per-module CPM-source implementations (two of which didn't have a fallback at all) | Per explicit user direction, 2026-09-03: "if the API call works then it should be used for all screens that ask for a CPM... if it fails it should fall back to what is configured on the profile." Centralizing in one driver-scope function (the same mechanism `Invoke-EntitySearch` already uses for cross-module sharing) means any future CPM-picker screen gets both behaviors for free. Like `Invoke-EntitySearch`, it has no unit test coverage of its own - manually verified via a standalone `powershell.exe` repro of all four cases (live success with/without results, live failure, live exception) rather than a Pester test, both because it makes real HTTP calls and to avoid this codebase's documented Pester v6.1 hang risk for new `Describe` blocks appended to `Manage-Privilege.Tests.ps1`. |
| Add Safe From Template — CPM prompt replaces auto-copy | Interactive mode shows a numbered picker sourced from `Get-CpmOptions`, with "(none)" as entry 1 and the default; CSV/bulk mode gets an optional `ManagingCPM` column (blank = none). Falls back to free-text entry if the picker has no options | The prior behavior (always copying the template safe's `managingCPM`) meant every stamped safe silently inherited the template's CPM whether or not that was wanted. Explicit choice, defaulting to none, matches how CPM assignment should be a deliberate decision per safe, not an accidental side effect of using a template. |
| Add Safe — Location no longer prompted; CPM picker matches Add Safe From Template | Interactive mode no longer asks for `Location` - every safe is created at the default (`\`) unless overridden via CSV/bulk input's `Location` column, which is unchanged. The `ManagingCPM` prompt was changed from free text to the same numbered `Get-CpmOptions` picker used by Add Safe From Template (`(none)` as entry 1 and the default) | Per user request, 2026-09-03: two separate but related simplifications to Add Safe's interactive flow - one less field to answer for the common case, and a consistent CPM-selection experience across both safe-creation screens instead of free text on one and a picker on the other. |
| Add Safe From Template — additional members | Interactive mode loops a single "Additional Member" name prompt per iteration, defaulting to blank - accepting the blank default is both "no (more) members" and the loop's exit condition, no separate "add another? Y/N" gate. Each non-blank name is followed by Type (User/Group), then a role picked from the same `Role_Template_Safe`/`Role_Group_Prefix` numbered menu as `SafeMembers/AddFromTemplateRole`, now annotated with each role's description (see the row below); CSV/bulk mode gets an optional `ExtraMembers` column, `Type:Name:RoleName` triples separated by semicolons (e.g. `User:jdoe:Role_Viewer;Group:AdminsGroup:Role_Admin`) | Template-copied members give the new safe its baseline shape, but a specific safe often needs one or two people/groups beyond that baseline - this avoids a separate manual `Add Safe Member From Template Role` pass immediately after creation. The delimited CSV format mirrors the existing semicolon-separated-list convention already used elsewhere in this codebase's data (e.g. `RemoteMachines` on the Accounts API). Malformed entries and role names that don't resolve are recorded as individual non-fatal errors - they never block safe creation or the other members in the same list. Role permissions are resolved from `$templateMembers` already fetched for the template-copy step, not a second API call. The single recurring name prompt replaced two separate Y/N gates ("add additional members?" then "add another?") per explicit direction - re-prompting for the next name already asks the same question the Y/N gate did. |
| Add Safe From Template — role descriptions | The template-role picker (`script:Get-TemplateRoleOptions`) now also queries `GET /API/UserGroups` (the same endpoint as `Groups/List`) and matches each role's name to a group's `description`, shown beneath the role's name on its own indented line(s) in the picker. A new `script:Get-DescriptionDisplayLines` helper splits any embedded `\r\n`/`\n` in the description and trims/drops blank lines, so a multi-line group description gets each line indented consistently instead of only its first line lining up | A role is a CyberArk group by naming convention - its description lives on the group object, not on the safe-membership record the rest of the function reads for permissions. `search=Role_Group_Prefix` narrows the query server-side as a payload hint only; matching a role to its group is always done client-side by exact `groupName` (case-insensitive), never trusting server-side search alone for exact matching - consistent with how `RoleName` resolution already works in `SafeMembers/AddFromTemplateRole`. Best-effort and non-blocking: if the lookup fails or a role's group can't be matched, `Description` stays `''` and the role remains fully usable by name. Group descriptions are free text and can contain embedded line breaks - `Write-Host` has no per-line indent of its own, so printing a raw multi-line string as-is would only visually indent its first line, with the rest landing back at the console's left margin. |
| 401 handling always invalidates the session | `Invoke-TokenInvalidate` is called unconditionally whenever a module returns `IsFatal = $true`, rather than pattern-matching the error message text for "401"/"Unauthorized" | `IsFatal` is only ever set for HTTP 401 or a network-level failure (`StatusCode 0`) — every module follows `IsFatal = ($response.StatusCode -in @(401, 0))`. The prior text-match could silently miss a genuine 401 whose message happened not to contain those exact words, leaving a rejected token in place. Invalidating on any `IsFatal` closes that gap; the only side effect is also invalidating on a transient network error, which is a safe, minor inconvenience (forces one extra re-auth prompt), not a correctness issue. |
| Logon-phase token age check | `Token.Created` (new field, carried forward from the persisted `SavedAt` timestamp by `Import-AuthToken`, not reset on load) is checked against `$script:LogonTokenMaxAgeMin` (15 min) when a saved-but-still-valid token is loaded at logon; if older, it's refreshed via `Update-ISPSSAuthToken`/`Update-SelfHostedAuthToken` before the session starts | A token can sit unused for hours while still inside its expiry window. `Invoke-ProactiveRefresh` only guards against near-expiry (and only for `ClientCredentials`), so a long-idle-but-valid token could otherwise start a whole session already partway through its life. Checking at logon, once, is cheaper and simpler than extending the mid-session proactive-refresh logic to cover every `AuthMethod`. Older `.cred` files saved before `Created` existed fall back to "age unknown" (not force-refreshed) rather than assuming staleness. |
| Version-gated CPM endpoint fallback | `Invoke-AccountsCancelCpmTask.ps1`/`Invoke-AccountsResumeAutoManagement.ps1` call their newer endpoint (`/Cancel/`, `/Resume/`) first; on an HTTP 404 specifically, they retry against an older, version-agnostic equivalent (`/StopImmediateAutoMgmtOperations`, and the PATCH `automaticManagementEnabled` update already used for ISPSS) and log a `WARN`. Any other failure (401/403/500/network) is not reinterpreted as a version issue. | Per user direction, 2026-09-02: both newer endpoints require a PVWA version this project has no reliable way to query ahead of time (15.0-15.2+ depending on source), so the fallback is response-driven rather than version-driven. A 404 is the one response that reliably means "this endpoint doesn't exist here." |
| Test API's IgnoreSSL bypass reuses `Disable-SSLValidation` | `Invoke-CustomTestApi.ps1` calls the same exported `Disable-SSLValidation` helper `Invoke-CyberArkAPI` uses internally, rather than assigning its own scriptblock to `ServerCertificateValidationCallback` | Per user report, 2026-09-02, of the whole process silently closing (no catchable error) when the session token expired mid-use of Test API. A raw PowerShell scriptblock assigned to that .NET delegate is a known hazard if invoked off the runspace's own thread; the rest of the codebase already avoids it via a compiled `ICertificatePolicy` class. Test API is the only module that calls `Invoke-WebRequest` directly (by design, to reach arbitrary methods/paths) instead of going through `Invoke-CyberArkAPI`, so it needed the helper exported to reuse it directly. |
| Banner: app name, version source, signed-in user | `$script:AppName` renamed from "Idira Unified Scripts - CyberArk PAS Driver" to "aPePAS - CyberArk PAS Driver"; `$script:Version` (already a single variable bumped per release) is unchanged in mechanism; `Show-Header` now also prints a `User: <name>` line, resolved by the new `Get-SignedInUsername` (prefers the token's `_RefreshContext.Credential.UserName` - the credential actually used to authenticate - falling back to `$script:ActiveProfile.Username`, blank before login) | Per user request, 2026-09-02. `%APPDATA%\IdiraUnifiedScripts\Profiles` (the on-disk profile/token folder, `Get-ProfileDir` in `CyberArk.Auth.Common.psm1`) was deliberately left unchanged - renaming it would orphan every existing user's saved profiles and tokens, and the request was specifically about the on-screen banner, not the storage location. |
| Error messages fall back to the raw response body | `Invoke-CyberArkAPI`'s new `Format-CyberArkErrorMessage` helper tries, in order: the CyberArk `"<ErrorCode>: <ErrorMessage>"` envelope; the bare `ErrorMessage` alone; the raw response body if it's non-blank; and only then a generic `"HTTP <code>"` fallback | Per user request, 2026-09-03: "Error messages for failed requests should include the body information unless it is blank or null." Structured `ErrorCode`/`ErrorMessage` parsing doesn't cover every error shape a server might return (e.g. an IIS-level HTML error page, or a JSON body in some other shape) - showing the raw body in those cases beats silently downgrading to a generic HTTP-status message that was already available from `StatusCode` alone. |
| `ProcessStartInfo.ArgumentList` is probed, not assumed | `Invoke-ExternalProcessWithTimeout` (`Invoke-CustomTestConnectivity.ps1`) probes a disposable `ProcessStartInfo` in a `try/catch` before deciding whether `ArgumentList` is safe to use, falling back to a manually-quoted `.Arguments` string (`ConvertTo-Win32QuotedArgument`) when it isn't | Confirmed live by the user: `ArgumentList` (added in .NET Framework 4.6.1) threw `PropertyNotFoundException` under this driver's `Set-StrictMode` on their machine. Reproduced independently here too, with a *different* symptom (silently `$null`) - neither the .NET Framework version nor reflection reliably predicts whether it's actually usable. See `Claude_Docs\Reference_Lessons-Learned.md` Section 35. |
| Linux SSH test auto-accepts an unrecognized host key (PS7 path) | `Test-LinuxSshAuth`'s PowerShell 7 SSH transport path passes `-Options @{StrictHostKeyChecking='no'}` to `New-PSSession -SSHTransport` | Confirmed live against a real test host: without this, a first-time connection hangs for the full timeout waiting on an interactive host-key confirmation with nothing able to answer it in this non-interactive child process. `StrictHostKeyChecking=no` still records the key in `known_hosts` for next time - an acceptable tradeoff for a connectivity *test* tool, not a long-term managed session. |
| Linux SSH test tries plink before the PS7 SSH transport | `Test-LinuxSshAuth` now checks for plink first (via the new `Find-PlinkExecutable`: PATH, then the project root, then `%ProgramFiles(x86)%\PuTTY`, then `%ProgramFiles%\PuTTY`) and only falls back to `pwsh`'s SSH transport if plink isn't found | Confirmed live, 2026-09-04: even with the host-key fix above, a real password-auth attempt via the PS7 path still timed out - native OpenSSH needs a console for its password prompt, and this path has none. Plink's own `-pw` flag submits the password directly, sidestepping that entirely. |
| Plink's unrecognized host key is trusted via a parsed retry, not skipped outright | On a "host key is not cached" failure, `Test-LinuxSshAuth` parses the `SHA256:...` fingerprint plink itself reports and retries once with `-hostkey <fingerprint>`, rather than any blanket bypass | PuTTY deliberately has no CLI equivalent to OpenSSH's `StrictHostKeyChecking=no` - `-hostkey` requires the exact key already known, by design, so it can't be used to blindly trust anything. Using the fingerprint plink already computed for *this specific connection* preserves that same trust-on-first-use tradeoff already made for the PS7 path, without inventing a bypass PuTTY itself doesn't offer. Confirmed live end-to-end against a real target, starting from a genuinely empty host-key cache: the retry succeeded automatically, a real login went through (`AuthStatus: Success`), and a wrong password still failed cleanly in ~3 seconds rather than hanging. |
| A literal IP with no reverse-DNS record is not a resolution failure | `Resolve-ConnectivityTarget` treats a `GetHostEntry` exception on a literal IP address as a successful resolution (empty `FQDN`, the IP echoed back as `IPAddress`) rather than aborting the whole connectivity test | Confirmed live: a fully reachable real test host has no PTR (reverse DNS) record, which is normal for an internal/test host and unrelated to reachability - `GetHostEntry` throws "No such host is known" for exactly this case. The address was already fully usable (it's a literal IP) without any DNS lookup at all, so failing to also learn its hostname must not block the port/auth checks that follow. A *name* that fails to resolve is unchanged - that's still a hard failure, since there's nothing left to connect to. |
| CSV filename can include an InputData field (`ModuleMeta.CsvFilenameField`) | A new optional `ModuleMeta` key names an `InputData` column whose value, when present and non-blank, is appended to the single-interactive-run auto-saved CSV filename (`Invoke-ActionModule`'s CSV-save block, `Manage-Privilege.ps1`) | Per user request: Test Connectivity's auto-saved filename was always just `"Test Connectivity <date>.csv"`, so testing several servers one at a time overwrote the same file each run. Implemented as a generic, opt-in mechanism rather than a name-check hardcoded to one module, so any future module can opt in the same way; only `Custom/TestConnectivity` declares it (`CsvFilenameField = 'Address'`) as of this change. |
| `/API/Platforms/Targets` is fetched unfiltered, never with `search` | The 6 modules that resolve a `PlatformID` to CyberArk's internal numeric ID (`Platforms/Copy/Enable/Disable/Remove/Rename/SetPSMConfig`) fetch the endpoint with no query parameters and unwrap a `Platforms` property from the response, falling back to treating the response as a bare array for backward compatibility | Confirmed live, 2026-09-04, during a full end-to-end module test pass: the endpoint actually wraps its results as `{"Platforms": [...], "Total": N}` (not a bare array, as every one of these modules had assumed), and its `search` query parameter does not match against `PlatformID` at all - searching for the exact string `WinServerLocal` returned zero results for a platform confirmed to exist. See Testing_Plan.md F32. |
| Safes `PUT` requires `SafeName` in the body, not just the URL | `Invoke-SafesUpdate.ps1`, `Invoke-SafesAssignCPM.ps1`, and `Invoke-SafesUnassignCPM.ps1` all include `SafeName` in their `PUT /API/Safes/{safeName}` request body | Confirmed live via a raw-HTTP isolation test: this PVWA version returns an empty-body HTTP 400 for every field combination tried unless `SafeName` is also present in the body - a real divergence from psPAS's own `Set-PASSafe.ps1`, whose `Format-PutRequestObject` keep-list never includes it. See Testing_Plan.md F33. |
| Add Safe From Template excludes the template safe's own creator from the member copy | The member-copy filter (alongside the existing role-prefix and `$script:ExcludedTemplateMemberNames` exclusions) also excludes any member whose name matches the template safe's `creator.name`, read from the same `GET` response already fetched for the safe's settings | Confirmed live: CyberArk always includes the safe's creator as an implicit member with owner-level access, and rejects an explicit attempt to re-grant that same access on the new safe with `HTTP 403 Forbidden`. This member is never role-prefixed, so it was invisible to the existing exclusion logic until this fix. See Testing_Plan.md F34. |
| Safe delete offers a rename-instead fallback on HTTP 409 | `Invoke-SafesDelete.ps1` asks (interactively, via `Read-Host`) whether to rename the safe to `1_DEL_<SafeName>` (truncated to CyberArk's 28-character limit) instead of just failing, when the delete itself returns HTTP 409. A successful rename counts as a `Success`, not a `Failure` | Per user direction, following up on a live-confirmed 409 that persisted even on a safe whose own `GET` showed zero accounts - most likely Safe History Retention, since an account is marked with the retention setting active on the safe when it was added, so mixed settings across a safe's history can block a full purge. No API-side "force delete" exists (confirmed against psPAS's `Remove-PASSafe.ps1`), so a rename achieves the practical goal (getting the safe out of normal use) without needing CyberArk to actually release the lock. See Testing_Plan.md F35/K10. |
| `$InputData.Key` dot notation replaced with bracket notation across 9 modules | `Invoke-SafesAdd/Update/AssignCPM/UnassignCPM/Delete.ps1`, `Invoke-SafeMembersRemove.ps1`, and `Invoke-GroupsAdd/Update/Delete.ps1` now read every optional `InputData` field via `$InputData['Key']` instead of `$InputData.Key` | Confirmed live: dot notation on a hashtable throws `PropertyNotFoundException` under `Set-StrictMode -Version Latest` when the key is entirely absent (not merely blank) - a real, live-reachable crash whenever a caller (a CSV row missing a column, or a direct API caller) omits an optional field outright, rather than including it blank. The existing unit test suite never caught this because every fixture always supplies every key. See Testing_Plan.md F31 and Lessons-Learned Section 37. |
| ISPSS `ClientCredentials` response fields are guarded, not assumed present | `Invoke-ISPSSClientCredentials` and `Update-ISPSSAuthToken`'s refresh branch read `access_token`/`expires_in`/`refresh_token` via `$resp.PSObject.Properties['field']` checks rather than unconditional dot access | Confirmed against CyberArk's own "Create an API token" reference and an isolated repro: the documented `POST /oauth2/platformtoken` response for this grant type is `{access_token, token_type, expires_in}` only, with no `refresh_token` field, and dot-accessing a genuinely absent JSON property throws under this project's strict mode - meaning every `ClientCredentials` login would have crashed immediately after a successful token request. See Testing_Plan.md F36. |
| `Invoke-CyberArkAPI` determines JSON vs. binary from response headers, not a JSON-parse-and-catch guess | The response's actual `Content-Type` and `Content-Disposition` headers decide the response shape. `.Content` is used directly when `Invoke-WebRequest` already returned it as a `byte[]` (the normal case for a correctly-labeled binary `Content-Type`); `RawContentStream` is read instead whenever a `Content-Disposition` header is present on a non-JSON response, since a file mislabeled with e.g. `text/html` gets `.Content` lossily decoded as text by `Invoke-WebRequest` - `RawContentStream` always holds the untouched original bytes regardless. A new `DataType='File'` (already documented, but never implemented, in `Reference_Interfaces.md`) and `SuggestedFileName` (from `Content-Disposition`) complete the response object for file downloads | Needed for `Platforms/Export` to download a real platform `.zip`. Confirmed live, via a local `HttpListener` test under real Windows PowerShell 5.1, that a mislabeled `Content-Type` genuinely and irreversibly corrupts binary data read via `.Content`, while `RawContentStream` recovers the exact original bytes in every case tried - this is more robust than psPAS's own `Get-PASResponse`, which relies on `.Content`'s runtime type alone and has no `RawContentStream` fallback for that exact scenario. See `Reference_Lessons-Learned.md` Section 39. |
| Platform export/download supports all 4 psPAS `Export-PASPlatform` target types | `Invoke-PlatformsExport.ps1` accepts exactly one of `PlatformID`, `RotationalGroupID`, `DependentID`, or `GroupPlatformID` in `InputData`, routing to the matching endpoint (`POST /API/Platforms/{id}/Export`, `/api/Platforms/RotationalGroups/{id}/Export`, `/api/Platforms/Dependents/{id}/Export`, or `/API/Platforms/Groups/{id}/Export` - casing preserved exactly as documented by psPAS, including the two lowercase `/api/` paths). The downloaded file is always auto-saved to the profile's `OutputFolder`, using the filename CyberArk suggests via `Content-Disposition`, or a generated `Platform-Export-<Type>-<ID>-<timestamp>.zip` if none is given | Per explicit user direction (all 4 variants, auto-save rather than prompting for a path). Unlike `Platforms/Copy/Enable/Disable/Remove/Rename/SetPSMConfig`, this endpoint takes the target's own string ID directly in the URL - no numeric-ID resolution via `/API/Platforms/Targets` is needed, confirmed directly from psPAS's `Export-PASPlatform.ps1`. Live-verified end-to-end for the `PlatformID` case against a real tenant: the downloaded file was a genuinely valid, openable `.zip` containing the platform's real policy files. The other 3 variants are unit-tested against psPAS's documented endpoint shapes but not yet live-confirmed, since no existing aPePAS module can discover a real rotational group/dependent/group-platform ID to test against. |
| `Custom/ExportPlatformDetails` builds a dynamic, unioned column set across every active platform | `Invoke-CustomExportPlatformDetails.ps1` lists `/API/Platforms`, filters to `general.active=$true` entries of any `platformType`, downloads each via the same standard `/API/Platforms/{id}/Export` endpoint `Platforms/Export`'s `PlatformID` variant uses, and parses each `Policy-<id>.ini`/`.xml` into `Ini.<Key>`/`Ini.<Section>.<Key>`/`Xml.<Field>` hashtable entries (using XPath, never dot-notation, for the XML). Only after every platform is processed are the final CSV rows built, using the sorted union of every key seen across all platforms - a platform lacking a given setting gets a blank value on its row rather than a missing column, since `Export-Csv` requires uniform columns across rows | Per user request: "any type" of active platform, one spreadsheet, every setting as its own column. Confirmed live that `/API/Platforms` list entries nest fields (`id`, `active`, `platformType`, etc.) under a `general` sub-object, not at the root. Also confirmed live, contradicting an initial assumption, that the list's `platformType` value (`"regular"`/`"group"`) is unrelated to psPAS's separate `GroupPlatformID` concept: a `platformType="group"` platform exported successfully (HTTP 200) via the standard endpoint, while the same ID via the dedicated `/API/Platforms/Groups/{id}/Export` endpoint returned HTTP 400 - proving these are two distinct ID-spaces, and this bulk module needs only the one standard endpoint regardless of platform type. A per-platform export failure is a non-fatal `Failure`, not an abort, matching `Custom/ExportAll`'s established continue-on-error convention for bulk reports. An `OtherFiles` column lists any zip entry that isn't one of the two expected policy files, excluding a `META-INF` folder per explicit user direction - unit-tested but not live-confirmed, since no real example of extra bundled files existed on the test tenant. See Testing_Plan.md F39. |
| `Policies/GetMasterPolicy` declared dual-use despite psPAS's Self-Hosted-only assertion (and despite Master Policy being confirmed absent on ISPSS); `Custom/ExportAll` gains a generic `IncludeInExportAll` opt-in | `Invoke-PoliciesGetMasterPolicy.ps1`'s `SupportedSystems` now includes `ISPSS` alongside `SelfHosted` (its write counterpart, `SetMasterPolicy`, was deliberately left Self-Hosted-only). A new `ModuleMeta.IncludeInExportAll = $true` flag lets `Invoke-CustomExportAll.ps1`'s module-discovery filter pick up a module whose `Action` isn't `List`/`ListAuthMethods` - the read counterpart to the pre-existing `ExcludeFromExportAll` opt-out | Per user request: "Within CyberArk's Self-Hosted and Privilege Cloud have a master policy. Is there a way to pull this information? I would like to include it in the Export All." psPAS's `Get-PASMasterPolicy.ps1` explicitly asserts `-SelfHosted`, and at the time no local CyberArk reference material documented a Privilege Cloud master-policy endpoint - though neither source confirmed one didn't exist, only that it was undocumented. The module was declared dual-use anyway, relying on its pre-existing non-fatal failure handling (a 404 or other error is a `Failure`, not a crash). Live-verified end-to-end on Self-Hosted: `Export All`, with only this module loaded, correctly discovered and ran it via the new opt-in, saving a real CSV with real policy values. **The user subsequently verified live against a real Privilege Cloud tenant that no Master Policy equivalent endpoint exists on ISPSS at all** - `SupportedSystems` was kept dual-use anyway per user direction, since the existing graceful failure handling already degrades cleanly there with no code change needed. See Testing_Plan.md F40. |
| Automation mode is guarded out of a cold start entirely, never given its own credential-supply mechanism | `$script:AutomationMode` (set once from `-Category`/`-Action`'s presence, read the same way `$script:WhatIfMode` already is) makes `Invoke-ProfileConnect`'s fresh-auth block log why and return `$null` immediately, without ever calling `Get-SelfHostedAuthToken`/`Get-ISPSSAuthToken` - automation only ever runs on top of an already-established, silently-refreshable saved session | Per user request ("If interaction is required have it exit stating the issue"): confirmed directly (not assumed) that every auth method's fresh login is interactive with no exception - `Invoke-ProfileConnect`'s `$authParams` never sets `-Credential`/`-Certificate`/`-ClientId`/`-ClientSecret` for any method. Threading a new non-interactive credential-supply mechanism through every auth method was out of scope; guarding the fresh-auth path out entirely, uniformly, is simpler and strictly safer than trying to special-case "risky" methods. The same flag also short-circuits `Invoke-TokenRefresh` (reusing the identical silent `Update-*AuthToken` path, or failing fast for SAML/OIDC/Interactive/SSO, which have no silent refresh at all) and `Invoke-FileWriteWithRetry` (no retry offer). See Testing_Plan.md F53. |
| Module loading is re-dot-sourced inline in `Invoke-AutomatedAction`, not factored into a shared helper | The automation entry point duplicates `Invoke-SessionLoop`'s 3-line "re-dot-source every loaded module file into this function's own scope" loop verbatim, rather than extracting it into a common function both callers invoke | PowerShell scoping rule, verified directly: dot-sourcing performed inside a normally-called function only persists that function's own functions for the duration of that function's own call frame - they vanish once it returns. A shared `Initialize-LoadedModules` helper would dot-source into *its own* scope and discard the result the moment it returned, leaving neither caller able to invoke a module function by name. Duplicating the loop, with a comment explaining why, is the correct tradeoff here, not an oversight. See Testing_Plan.md F53. |
| `-OutputFolder`/`-FilenameFormat` are read once, generically, in `Save-ModuleResultCsv` - not threaded per-module | Automation mode's two CSV-override launch parameters are applied by the one shared function every `ModuleMeta.ProducesOutput` module's save already routes through, so any such module (present or future) picks them up automatically with zero per-module code. The one exception, `Custom/ExportAll`, writes its own files directly and reads `-OutputFolder` itself - `-FilenameFormat` is deliberately not offered to it, since its output is inherently several fixed-name files per run, not a single name | Per user request ("Allow a new output folder and filename format to be specified" for "the Custom Export processes"), clarified via 2 rounds of questions that the actual need was generic override parameters usable by any automation run, not something hardcoded to the Custom category. Discovered mid-implementation that `Save-ModuleResultCsv` must read `$script:OutputFolder`/`$script:FilenameFormat` with an explicit `$script:` prefix, not a bare reference - a Pester-only scoping artifact (confirmed via a standalone repro outside Pester to rule out a real production bug): a top-level script parameter reassigned via `$script:Name = ...` from inside a unit test's `It` block is not visible to a same-file function's bare-name lookup, because the initial no-args dot-source (in the test's own `BeforeAll`) bound that parameter inside `BeforeAll`'s own nested scope rather than the file's true script-scope container that `$script:` always addresses regardless of nesting. See Testing_Plan.md F54. |
| `CsvFilenameNoDate` is a per-module opt-in, not a change to `Get-CsvSavePath`'s shared default | A new `ModuleMeta.CsvFilenameNoDate = $true` flag (and matching `Get-CsvSavePath -NoDateSuffix` switch) drops the date from a module's auto-saved filename - declared by all 4 non-`ExportAll` Custom export tools, but not by `Custom/TestConnectivity`, the only other `AutoSaveCsv` module | Per user request ("Remove the date from the file name so they all behave the same," after being asked which Custom export modules include one), matching `Export All`'s existing fixed-filename convention across every Custom export tool. Left as an opt-in rather than removing the date from `Get-CsvSavePath`'s shared default globally, since `TestConnectivity`'s own date suffix was added deliberately (Finding F26) to keep same-target-different-day test runs from silently overwriting each other, and removing it was never asked for. See Testing_Plan.md F55. |
| Automation-mode credential refresh gets a `-NoPrompt` guard plus an explicit, separately-stored fallback credential - not a scope-based flag | `Invoke-SelfHostedPasswordAuth`/`Update-SelfHostedAuthToken` gained a `[switch]$NoPrompt`, threaded as a real parameter rather than via a `$script:AutomationMode`-style scope check, since `CyberArk.Auth.SelfHosted.psm1` is loaded with `Import-Module` (a genuine, isolated module scope) rather than dot-sourced into the driver like API modules are - a `$script:`/`Get-Variable -Scope Script` check would silently see nothing there at all, not even via the Pester-artifact class of bug already hit twice this session. A new per-profile `.autocred` file (DPAPI via `Export-Clixml`, same mechanism as the `.cred` token file) lets a human pre-supply a credential for automation to fall back to, set via the profile detail menu's new `[A]` action | Per user direction fixing Testing_Plan.md K06 ("Automated runs will not use interactive authentication methods. The user can create a credential object that can be referenced when need for authentication."): a missing credential during an unattended mid-session or logon-time refresh now fails cleanly with a clear log message instead of risking a hang on `Get-Credential`, and a pre-stored credential lets that refresh still succeed silently rather than just failing. Scoped to CyberArk/LDAP/RADIUS only (the only methods needing a `Credential`) and to refreshing an *existing* session - never used to bootstrap a cold start, which the automation-mode design (Testing_Plan.md F53) already keeps interactive-only. See Testing_Plan.md F56. |
| `IgnoreSSL`'s bypass is reset on every call, not merely disabled once; `Auth.Common.psm1` now imports `CyberArkComms.psm1` to reuse the same mechanism | `Invoke-CyberArkAPI`'s gate changed from "disable if `-IgnoreSSL`" to "disable if `-IgnoreSSL`, else reset if currently disabled" (new `Reset-SSLValidation`, restoring `ServicePointManager.CertificatePolicy` to `$null`). 3 raw `ServerCertificateValidationCallback` assignments in the Auth module (the same crash-risk pattern Finding F15 already fixed for Test API) were consolidated onto the shared `Disable-SSLValidation`/`Reset-SSLValidation` instead, which required `Auth\CyberArk.Auth.Common.psm1` to import `Modules\CyberArkComms.psm1` (safe - `CyberArkComms.psm1` has no dependency on any Auth module, so this doesn't create a circular reference). `Invoke-WebView2Window` gained its own, separate `-IgnoreSSL` handling via `CoreWebView2.ServerCertificateErrorDetected`, since the WebView2 control's Chromium engine has an entirely independent network stack from `ServicePointManager` that the .NET Framework-level bypass can never reach | Per user request ("Work on K02 and K03 next"). K02: `ServicePointManager.CertificatePolicy` was confirmed to be a process-wide static (true, as already documented) that was never reset (not true that it "cannot be undone" - it can, just wasn't) - so switching from an `IgnoreSSL=$true` profile to one that doesn't want it left the bypass silently active for the rest of the session. K03: confirmed via .NET reflection against this project's own shipped `Microsoft.Web.WebView2.Core.dll` that `CoreWebView2ServerCertificateErrorAction.AlwaysAllow` is the available bypass mechanism there - not previously wired up at all, so `IgnoreSSL` had zero effect inside SAML/OIDC's WebView2 window regardless of the setting. See Testing_Plan.md F57/F58. |
| A stale-`BaseURL` token is discarded and forces a fresh login, never silently patched | New `Get-ExpectedTokenBaseURL`/`Test-TokenBaseURLStale` detect when a loaded/refreshed token's own `BaseURL` no longer matches what a fresh login for the active profile would produce today (`Invoke-ProfileConnect`, the Test Connection flow, and `Invoke-TokenRefresh`'s SelfHosted branch all now check this before trusting/reusing a session). On a mismatch, the token is discarded and the existing fresh-login flow runs instead - the field is never overwritten on an existing token | Per user request ("Work on K04 and K07 next"), this was flagged as a security-relevant judgment call before implementation, not assumed: `Invoke-CyberArkAPI` builds every request's URI from the token's `BaseURL` (`Modules\CyberArkComms.psm1:398`) with no cryptographic binding between a token and the server that actually issued it - `BaseURL` is pure routing metadata, trusted at face value. There is no reliable way to distinguish "the user fixed a typo in the same server's URL" from "the user re-pointed this profile at a genuinely different server/tenant" automatically, and getting that distinction wrong by silently reusing a token risks sending a live session against a server that never issued it. The user confirmed this exact tradeoff and chose the conservative default (force re-login) over the alternatives (warn-but-proceed, or silently patch the field) after it was presented, and chose to apply it to all 3 affected call sites rather than only the primary connect path. See Testing_Plan.md K04/F59. |

---

## Security Considerations

- **DPAPI scope**: Profile XML files are encrypted to the current Windows user and machine. They
  cannot be decrypted on a different machine or by a different user account. This is intentional.
- **Stored automation credential (`.autocred`)**: an optional, per-profile `PSCredential` set via
  the profile detail menu's `[A]` action and encrypted the same way (`Export-Clixml`, DPAPI,
  user+machine-locked) as a profile's saved session token. Used only as an automation-mode
  fallback to silently refresh a SelfHosted CyberArk/LDAP/RADIUS session when the saved session's
  own embedded credential is missing - never used to bootstrap a fresh/cold-start login, which
  remains interactive-only by design. The scheduled task that runs automation mode must run as
  the same Windows account that created it, or it will be unreadable (logged, not silently
  ignored) exactly like an unreadable `.cred` token file.
- **Token in memory**: Tokens are held as plain strings in memory during a session. This is
  unavoidable for making HTTP calls. Tokens are never written to disk as plaintext.
- **Logging**: Sensitive data (tokens, passwords, secrets) must never appear in log output. The
  logging module masks known patterns. Module authors are responsible for not passing sensitive
  values to `Write-CyberArkLog`.
- **IgnoreSSL**: Stored per profile. When enabled, a warning is logged at session start. Only
  appropriate for lab or development environments. The bypass itself (`ServicePointManager.CertificatePolicy`)
  is a process-wide .NET Framework static, not scoped to a single call or profile - but is now
  correctly reset on the very next API call made with `IgnoreSSL=$false` (Testing_Plan.md K02/F57),
  rather than silently staying active after switching away from an `IgnoreSSL` profile. The same
  setting also applies inside the WebView2 browser control used for SAML/OIDC login (K03/F58),
  via that control's own separate `ServerCertificateErrorDetected` mechanism.
- **WhatIf mode**: Can be defaulted to `$true` in the profile (`WhatIfDefault`). Recommended for
  production profiles to prevent accidental writes.

---

## Technology Stack

| Technology | Version | Usage |
|---|---|---|
| PowerShell | 5.1+ | Runtime |
| .NET Framework | 4.x (PS 5.1) / .NET 6+ (PS 7) | Base framework |
| Microsoft.Web.WebView2 | Latest NuGet | Browser-based auth (SSO, SAML, OIDC) |
| System.Windows.Forms | Built-in | WebView2 host, file dialogs |
| System.Net.Http | Built-in | Identity tenant URL discovery |
| DPAPI (via Export-Clixml) | Built-in | Profile credential encryption |
| Windows Certificate Store | Built-in | PKI/PKIPN certificate selection |
