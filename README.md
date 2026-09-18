# aPePAS

A PowerShell 5.1 interactive driver for CyberArk Privileged Access Security (PAS), supporting both **ISPSS (Privilege Cloud)** and **Self-Hosted PVWA** environments. Provides a menu-driven console interface for common administrative tasks — account management, safe management, user and group operations, platform administration, connectivity testing, and bulk exports.

> **New to the tool?** See [Docs/User-Guide.md](Docs/User-Guide.md) for a full walkthrough of profiles, menus, CSV batch mode, and every module category. This README is a technical/developer-facing overview.

---

## Features

- **Profile management** — Store multiple named environments (PVWA URL, auth method, output folder, SSL settings). Profiles are encrypted and stored locally per user. One profile can be marked as default.
- **Profile backup/restore** — Back up one or more profiles to a single `.zip` (settings + saved session token, if any) from the `[K]` action on the profile list; restore from `[X]`. The saved token is DPAPI-encrypted to the Windows user + machine that created it (see the Design Decisions table in `Docs/Architecture.md`) — a backup restored elsewhere restores the settings fine but flags the token as non-portable, prompting re-authentication rather than silently failing later.
- **Startup profile selection** — `-StartProfile <name>` pre-selects a profile at the list screen; add `-AutoConnect` to skip the menus entirely and connect directly, useful for scripted/scheduled launches. Falls back to the normal interactive menu on any failure (profile not found, incomplete, or an auth error).
- **Multi-environment support** — ISPSS (Privilege Cloud) and Self-Hosted PVWA v12+.
- **Authentication methods** — CyberArk, LDAP, RADIUS, SAML, OIDC, Shared, PKI, PKIPN (Self-Hosted); ClientCredentials, Interactive, SSO (ISPSS).
- **Proactive token refresh** — Silently refreshes client-credentials tokens 10 minutes before expiry; prompts for re-auth on interactive session tokens. At logon, a saved token that's still valid but more than 15 minutes old is refreshed before the session starts.
- **Modular API actions** — Each operation is a standalone `.ps1` module loaded dynamically. The driver discovers and presents only the modules supported by the connected system type.
- **CSV batch processing** — Every write operation (Add, Update, Delete) can process a CSV file row-by-row, or collect input interactively.
- **CSV template generation** — Generate a header-only CSV template for any module's input schema.
- **SafeMembers permission-role presets** — `PermissionRole` (Add/Update) accepts `ReadOnlyStrict`, `EndUser`, `PowerUser`, `SafeManager`, or `Specified` (set each of the 22 permission fields individually). Deliberately named `ReadOnlyStrict` rather than `ReadOnly`: PVWA's and psPAS's own built-in `ReadOnly` role grants `retrieveAccounts` (password retrieval), while aPePAS's preset is list/audit/view only and never grants it — the distinct name heads off an administrator carrying PVWA/psPAS intuition over and assuming retrieve access is included.
- **Safe-scoped account lookup** — Account modules accept `AccountName` + `Safe` in CSV input and resolve the account ID server-side, avoiding the need to know internal account IDs.
- **List drill-down** — From any list result, enter a row number to open the corresponding Get/Details view pre-populated with that row's data.
- **WhatIf mode** — A session-wide dry-run flag, set via the `-WhatIf` launch parameter or a profile's WhatIf Default setting; all write operations are suppressed and logged instead of executed.
- **Interactive API tester** — Send raw requests to any CyberArk API endpoint, inspect request and response headers, and save full session details to JSON.
- **Connectivity testing** — Check DNS resolution, TCP port reachability, and Windows (SMB) or Linux (SSH) credential validation against a target server, single-item or CSV batch, with the credential looked up from the vault if not supplied.
- **Token lifecycle management** — Automatic keepalive, expiry warnings, transparent re-authentication, and token persistence across sessions.
- **Structured logging** — All actions, errors, and summaries are written to a rotating log file. POST/PUT/PATCH bodies and error responses are written to the log file at DEBUG level.
- **Configurable display limit** — Profile setting controls how many rows are shown on screen for list results (default 20, 0 = unlimited).

---

## Requirements

| Requirement | Version |
|---|---|
| PowerShell | 5.1 (Windows PowerShell) |
| CyberArk PVWA | v12.0+ (Self-Hosted) |
| CyberArk ISPSS | Any current Privilege Cloud tenant |
| .NET Framework | 4.7.2+ (ships with Windows 10/Server 2019+) |
| Pester (tests only) | v6.x |

> **SAML/OIDC (Self-Hosted) and SSO (ISPSS) authentication** additionally require the [Microsoft Edge WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/) (the browser engine - often already installed on Windows 10/11) and its separate .NET WinForms assembly, `Microsoft.Web.WebView2.WinForms.dll`. `Import-WebView2Assembly` (`Auth\CyberArk.Auth.Common.psm1`) looks for it in `Auth\`, `Auth\WebView2\`, or the NuGet global package cache (`%USERPROFILE%\.nuget\packages\microsoft.web.webview2\`), in that order. The most reliable way to get it: download the `Microsoft.Web.WebView2` package from [nuget.org](https://www.nuget.org/packages/Microsoft.Web.WebView2) (it's a `.zip` under a different extension) and copy `Microsoft.Web.WebView2.WinForms.dll`, `Microsoft.Web.WebView2.Core.dll`, and the architecture-matching `WebView2Loader.dll` (from `lib\net462\` and `runtimes\win-<x64|x86|arm64>\native\` inside the package) into a new `Auth\WebView2\` folder - these are gitignored, not distributed with the repo, and installed once per machine. Note: the `-WebView2AssemblyPath` parameter these functions accept for a custom location is not currently exposed through `Manage-Privilege.ps1`'s profile fields or launch parameters, despite being mentioned in the error message - it's only reachable by calling the `Auth` functions directly.

> **Custom > Test Connectivity's Linux (SSH) password validation** works most reliably with PuTTY's `plink.exe` available - checked on PATH, then the project root, then the standard PuTTY install locations (`Program Files (x86)`, then `Program Files`). Without it, the tool falls back to PowerShell 7's SSH transport, which can confirm reachability and key-based auth but cannot reliably validate a password non-interactively.

---

## Installation

1. **Clone or download** this repository to a local folder.

   ```powershell
   git clone <repo-url> C:\Tools\aPePAS
   cd C:\Tools\aPePAS
   ```

2. **Unblock files** if downloaded as a ZIP (Windows marks files from the internet as untrusted).

   ```powershell
   Get-ChildItem -Recurse | Unblock-File
   ```

3. **Run the driver** — no installation or import required. The driver dot-sources all modules on startup.

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\Manage-Privilege.ps1
   ```

   Or open a PowerShell 5.1 console and run:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\Manage-Privilege.ps1
   ```

---

## Quick Start

1. Launch `Manage-Privilege.ps1`.
2. At the **Profile Selection** screen, press **N** to create a new profile.
3. Enter a profile name, your PVWA URL (Self-Hosted) or Privilege Cloud subdomain (ISPSS), and choose your authentication method.
4. Authenticate when prompted. Your token is saved for future sessions.
5. Use the category and action menus to perform operations.

---

## Project Structure

```
aPePAS/
- Manage-Privilege.ps1          # Main interactive driver
- Auth/
  - CyberArk.Auth.Common.psm1   # Shared auth utilities: token object, WebView2, profile I/O
  - CyberArk.Auth.ISPSS.psm1    # Privilege Cloud / CyberArk Identity authentication
  - CyberArk.Auth.SelfHosted.psm1 # Self-Hosted PVWA authentication
- Modules/
  - CyberArkComms.psm1          # REST communication layer (pagination, rate limiting, query/filter builders)
  - CyberArkLogging.psm1        # Structured log writer
- APIModules/                   # 67 action modules across 10 categories - see `Invoke-<Category><Action>.ps1`
  - Accounts/                   # 17 actions: Add, CancelCpmTask, ChangeImmediate, ChangeInVault, CheckIn, Delete,
                                 #   Get, GetActivity, GetCredential, LinkAccount, List, Reconcile,
                                 #   ResumeAutoManagement, UnlinkAccount, Unlock, Update, Verify
  - Safes/                      # 8 actions: Add, AddFromTemplate, AssignCPM, Delete, Get, List, UnassignCPM, Update
  - SafeMembers/                # 6 actions: Add, AddFromTemplateRole, List, Remove, Update, UpdateFromTemplateRole
  - Platforms/                  # 10 actions: Copy, Disable, Enable, Export, Get, Import, List, Remove,
                                 #   Rename (Self-Hosted only, PVWA 15.0+), SetPSMConfig
  - Policies/                   # 2 actions: GetMasterPolicy (PVWA 14.6+; declared dual-use, but
                                 #   confirmed absent on ISPSS - fails gracefully there),
                                 #   SetMasterPolicy (Self-Hosted only, PVWA 14.6+)
  - Users/                      # 2 actions: Get, List
  - Groups/                     # 7 actions: Add, AddMember, Delete, GetMembers, List, RemoveMember, Update
  - Applications/               # 7 actions: Add, AddAuthMethod, Delete, DeleteAuthMethod, Get, List, ListAuthMethods
  - Reports/                    # 1 action: List (Self-Hosted only)
  - Custom/                     # 7 actions: ExportAll, ExportEntitlements, ExportGroupMembersLDAP,
                                 #   ExportGroupMembersLocal, ExportPlatformDetails, TestApi, TestConnectivity
- Tests/
  - Unit/                       # Pester v6 unit tests, one file per module plus shared modules/driver
  - Integration/                # Live-tenant integration test scaffolding (opt-in, not run by default)
  - Run-Tests.ps1               # Runs the full Unit suite
- Docs/
  - User-Guide.md               # End-user usage guide - profiles, menus, CSV mode, every category
  - Architecture.md             # System design, data flow, and design-decision log
  - API-Module-Development-Guide.md  # How to write new API modules
  - Interfaces.md               # Data shapes: driver profile schema, auth token object, etc.
  - Testing-Plan.md             # Component test matrix, manual test checklist, known findings
  - Lessons-Learned-PowerShell-Pester.md  # Notes on PS 5.1 / Pester gotchas
  - Documentation-Tracker.md    # Dated changelog of documentation and design changes
  - (plus dated design/planning documents for specific features or review passes)
```

---

## Writing New API Modules

See [Docs/API-Module-Development-Guide.md](Docs/API-Module-Development-Guide.md) for the full guide. Key points:

- Every module is a `.ps1` file that defines `$ModuleMeta` (a hashtable), an optional `Get-<Category><Action>Input` function, and an `Invoke-<Category><Action>` function.
- Modules are dot-sourced by the driver at startup. The driver discovers and registers them automatically via `$ModuleMeta`.
- Save all `.ps1` / `.psm1` files as **UTF-8 with BOM** — PowerShell 5.1 requires the BOM to read files as Unicode. Files without BOM are read as Windows-1252, which silently corrupts non-ASCII characters in string literals.

---

## Running Tests

```powershell
# Requires Pester v6
Install-Module -Name Pester -RequiredVersion 6.x -Force -Scope CurrentUser

# Run all unit tests
Invoke-Pester .\Tests\Unit\ -Output Detailed
```

---

## Configuration

Profiles are stored as encrypted XML files under `%APPDATA%\IdiraUnifiedScripts\Profiles\` — that folder name is unchanged from the tool's prior name and is not renamed by the aPePAS rebrand, so existing users' saved profiles and tokens keep working without any migration step. Each profile contains:

| Field | Description |
|---|---|
| ProfileName | Friendly name shown in menus |
| SystemType | `ISPSS` or `SelfHosted` |
| AuthMethod | Auth method (e.g. `CyberArk`, `LDAP`, `ClientCredentials`) |
| PVWAUrl | Base URL for Self-Hosted (e.g. `https://pvwa.company.com`) |
| AppName | PVWA application name for Self-Hosted (default `PasswordVault`) |
| PCloudSubdomain | Subdomain for ISPSS (e.g. `acme`) |
| Username | Pre-populated username for auth prompts |
| OutputFolder | Default folder for CSV exports |
| LogFolder | Override for log file location |
| IgnoreSSL | Skip TLS certificate validation (not recommended for production) |
| Limit | Maximum API results to fetch (0 = no limit) |
| DisplayLimit | Maximum rows to display on screen (default 20, 0 = unlimited) |
| WhatIfDefault | When set, every session opened with this profile starts in WhatIf mode (all write operations suppressed and logged, nothing actually changed) - equivalent to always launching with `-WhatIf` |
| IsDefault | Marks this profile as the default selection on startup |
| Role_Template_Safe | Safe name used as a settings/membership template by Safes > Add Safe From Template, and as the source of "role" permission sets by SafeMembers > Add/Update From Template Role |
| Role_Group_Prefix | Name prefix identifying role groups on the template safe - excluded when copying members in Add Safe From Template; matched exactly (not as a prefix) when picking a role by name in SafeMembers > Add/Update From Template Role |
| CPM_List | Comma-separated CPM usernames, used as the picker's fallback source on every page that asks for a CPM (Safes > Add, Add Safe From Template, Assign CPM to Safe) only if a live query for registered CPM users fails - the live query is tried first and used whenever it succeeds |
| TenantPortal | Auto-computed ISPSS portal URL (`{sub}.cyberark.com`) |
| TenantVault | Auto-computed ISPSS vault URL (`vault-{sub}.privilegecloud.cyberark.com`) |
| TenantAuth | Auto-computed CyberArk Identity tenant URL (discovered on first login, cached) |

---

## License

Internal tooling — all rights reserved. Not for redistribution without authorization.
