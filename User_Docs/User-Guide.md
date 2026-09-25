# aPePAS User Guide

This guide is for people **using** aPePAS to manage a CyberArk PAS environment — creating a
profile, running actions, and getting results out. If you're looking to modify the tool itself
or write a new module, see [Design_Architecture.md](../Claude_Docs/Design_Architecture.md) and
[Reference_API-Module-Guide.md](../Claude_Docs/Reference_API-Module-Guide.md) instead.

---

## 1. Before You Start

You'll need, depending on your environment:

- **Self-Hosted PVWA**: the PVWA base URL (e.g. `https://pvwa.company.com`) and, if your
  installation uses something other than the default, the PVWA application name (defaults to
  `PasswordVault`).
- **ISPSS / Privilege Cloud**: your tenant subdomain (e.g. `acme` for a tenant at
  `acme.cyberark.cloud`).
- Your username and the authentication method your CyberArk administrator has enabled for you
  (CyberArk, LDAP, RADIUS, SAML, OIDC, Shared, PKI, or PKIPN on Self-Hosted; ClientCredentials,
  Interactive, or SSO on ISPSS).
- **SAML or OIDC only**: the [Microsoft Edge WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/)
  must be installed - these methods open a sign-in window using it.

### Installing and launching

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

### WebView2 setup (SAML/OIDC/SSO only)

**SAML/OIDC (Self-Hosted) and SSO (ISPSS) authentication** additionally require the [Microsoft Edge WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/) (the browser engine - often already installed on Windows 10/11) and its separate .NET WinForms assembly, `Microsoft.Web.WebView2.WinForms.dll`. `Import-WebView2Assembly` (`Auth\CyberArk.Auth.Common.psm1`) looks for it in `Auth\`, `Auth\WebView2\`, or the NuGet global package cache (`%USERPROFILE%\.nuget\packages\microsoft.web.webview2\`), in that order. The most reliable way to get it: download the `Microsoft.Web.WebView2` package from [nuget.org](https://www.nuget.org/packages/Microsoft.Web.WebView2) (it's a `.zip` under a different extension) and copy `Microsoft.Web.WebView2.WinForms.dll`, `Microsoft.Web.WebView2.Core.dll`, and the architecture-matching `WebView2Loader.dll` (from `lib\net462\` and `runtimes\win-<x64|x86|arm64>\native\` inside the package) into a new `Auth\WebView2\` folder - these are gitignored, not distributed with the repo, and installed once per machine. If the DLL isn't found in any of the default locations, a profile's **WebView2 Assembly Path** field (blank by default) lets you point it at a custom location directly - set via `[E]dit` on the profile, consulted only for SAML/OIDC/SSO login.

### plink.exe (Linux connectivity tests)

**Custom > Test Connectivity's Linux (SSH) password validation** works most reliably with PuTTY's `plink.exe` available - checked on PATH, then the project root, then the standard PuTTY install locations (`Program Files (x86)`, then `Program Files`). Without it, the tool falls back to PowerShell 7's SSH transport, which can confirm reachability and key-based auth but cannot reliably validate a password non-interactively.

---

## 2. Profiles

A **profile** stores everything aPePAS needs to reconnect to one environment: the URL/subdomain,
authentication method, username, and a handful of preferences (see
[Profile Settings Reference](#8-profile-settings-reference) below). Profiles are stored locally,
encrypted per-user, so only your own Windows account can read them.

### Creating a profile

The first screen you see is **Profile Selection**. If no profiles exist yet, press **N** to
create one. You'll be asked for a profile name, then whether the target is **[1] Privilege Cloud
(ISPSS)** or **[2] Self-Hosted**, then a numbered list of the authentication methods available
for that choice. Fill in the URL/subdomain and username when prompted - all of these can be
changed later.

### Selecting a profile

Once you have one or more profiles, the Profile Selection screen lists them by number, along with
system type and username. Type a number (or just press Enter to accept the default, shown in the
prompt, if one profile is marked as your default) to open it.

Opening a profile takes you to its detail screen, with these options:

| Key | Action |
|---|---|
| `[C]` | Continue - authenticate and enter the session |
| `[E]` | Edit - change any field on this profile |
| `[P]` | Copy - duplicate this profile under a new name |
| `[D]` | Delete this profile |
| `[T]` | Test Connection - verify the URL/credentials without starting a full session |
| `[L]` | Log Out - discard the saved token, so the next Continue re-authenticates from scratch |
| (label varies) | Set/Clear this profile as your default |
| `[B]` | Back to the profile list |

### Authenticating

Choosing **Continue** authenticates using the profile's saved settings, prompting for a password
or other credential as needed for the chosen method. A successful token is saved, so the next
time you open this profile you may not need to authenticate again immediately - aPePAS refreshes
or silently renews the token as needed (see [Session & Token Management](#7-session--token-management)).

### Backing up and restoring profiles

The Profile Selection screen has two more options: **`[K]`** (Backup) and **`[X]`** (Restore).

To back up, press **K**, pick one or more profiles by number (comma-separated, or type `all`),
then choose where to save the `.zip` file. To restore, press **X**, pick a `.zip` file, then pick
which of the profiles it contains to bring back (again by number, comma-separated, or `all`). If
a profile of the same name already exists locally, you're asked before it's overwritten.

Each profile's settings and its saved session token (if any) are both included. The saved token
is encrypted to your specific Windows user account and machine (this is how aPePAS protects it at
rest) - restoring a backup on a *different* machine or under a different Windows account brings
the profile's settings back correctly, but the token can't be decrypted there, so aPePAS tells you
which profile(s) this happened to and you'll simply need to authenticate again for those. Restoring
on the same machine and account you backed up from (the common case - protecting against an
accidental edit or deletion) restores everything usably.

A profile's stored automation credential (`[A]` on the profile detail menu, if set) is **not**
currently included in a backup - after restoring, re-set it via `[A]` for any profile that had
one.

### Starting at a specific profile

Launch with `-StartProfile "<name>"` to pre-select a profile on the list screen, or add
`-AutoConnect` to skip the menus entirely and connect directly - useful for a shortcut or a
scheduled task. See the main [README](../README.md) for the exact launch syntax.

### Automation mode (non-interactive)

Add `-Category <cat> -Action <action>` to `-StartProfile` to run one module action
non-interactively and exit, instead of opening any menu. This is for a scheduled task or another
script driving aPePAS unattended - for example:

```powershell
.\Manage-Privilege.ps1 -StartProfile "Prod" -Category Safes -Action List -InputJson '{}'
.\Manage-Privilege.ps1 -StartProfile "Prod" -Category Accounts -Action Add -InputFile ".\new-accounts.csv"
.\Manage-Privilege.ps1 -StartProfile "Prod" -Category Custom -Action ExportEntitlements -InputJson '{}' `
    -OutputFolder "D:\Reports\Nightly" -FilenameFormat "{Profile}_{ModuleName}_{Date}"
```

- `-InputFile <csv path>` feeds a module that accepts CSV batch input, the same as choosing a CSV
  file interactively.
- `-InputJson <json string or .json file path>` supplies input as JSON for everything else - a
  literal JSON string (`'{"SafeName":"Example"}'`) or a path to a `.json` file. Omit both and the
  module runs with empty input, which is enough for modules with no required fields.
- `-InputFile` and `-InputJson` are mutually exclusive.
- `-OutputFolder <path>` saves this run's CSV(s) to a different folder than the active profile's
  own `OutputFolder` setting - created automatically if it doesn't already exist. Applies to any
  module that produces a CSV, including the `Custom` category's export tools (Export
  Entitlements, Export Group Members, Export Platform Details, and Export All's own per-report
  files - though not to their individual filenames; see `-FilenameFormat` below).
- `-FilenameFormat <template>` overrides the default saved filename for a single-file export -
  normally `"<Module Name> <date>.csv"`, or just `"<Module Name>.csv"` with no date for the
  `Custom` category's export tools (see below). A template string with `{ModuleName}`,
  `{Category}`, `{Action}`, `{Profile}`, and `{Date}` (`yyyy-MM-dd`) placeholders - e.g.
  `-FilenameFormat '{Profile}_{ModuleName}_{Date}'`. A `.csv` extension is added automatically if
  not already present. Not applied to Export All, whose output is inherently one file per
  sub-report rather than a single name.

**Automation mode never falls back to an interactive prompt.** If something would normally require
one - a profile with no saved session yet (a first-time login is always interactive, for every
authentication method), a mid-run token expiry with no silent refresh path, or a module's own
interactive step - it logs a clear reason and exits instead of hanging. Because of this, a profile
is only usable for automation once it has been authenticated **interactively at least once**,
producing a saved, refreshable session; and if a scheduled task runs as a different Windows account
than the one that logged in interactively, the saved credential (DPAPI-encrypted to that original
account/machine) won't be readable and the run will exit with a clear error rather than prompting.

For Self-Hosted CyberArk/LDAP/RADIUS profiles and ISPSS Interactive profiles specifically, a saved
session's own refresh normally reuses the credential captured at the original interactive login -
but if that's ever missing (an older saved session, or one that predates this), refreshing it
during an automated run would otherwise have no way to succeed. Use the profile detail menu's
**`[A]` (Automation Credential)** action to store a credential just for this fallback case - set
once interactively in advance, DPAPI-encrypted the same way a saved session token already is, and
used only to silently refresh an *existing* session unattended, never to start a fresh one.
Automation mode still never prompts even without one stored; a refresh that can't proceed just
fails cleanly with a clear log message instead. For ISPSS Interactive specifically, silent refresh
also requires that your CyberArk Identity user resolves to a single password-only challenge (no
additional MFA factor) - if a second factor is required, even a stored credential can't satisfy it
non-interactively, and the refresh fails cleanly the same way.

The process exit code reports the outcome, so a calling script or scheduled task can branch on it:

| Exit code | Meaning |
|---|---|
| `0` | Full success - the action ran with no item-level failures. |
| `1` | Unhandled crash. |
| `2` | The action ran but had partial/item-level failures (not fatal) - check the log for details. |
| `3` | Could not run at all - profile not found or has no valid refreshable session, the module wasn't found or doesn't support the connected system type, the module doesn't support automation mode at all, or the module reported a fatal error (e.g. an expired/rejected session). |

Every automation-mode run writes to the profile's log file (see [Section 7](#7-session--token-management)) exactly like an interactive session, so exit code `2` or `3` can be
diagnosed there without needing console output.

---

## 3. Navigating the Menus

Once connected, you're in the main session loop: a **category menu**, then an **action menu**
within whichever category you pick.

- The **category menu** lists every module category available for your environment (some, like
  Reports, are Self-Hosted-only and won't appear on an ISPSS profile; others, like Policies, show
  only their dual-use actions on ISPSS - e.g. `SetMasterPolicy` won't appear there, but
  `GetMasterPolicy` will, even though it's confirmed to always fail on ISPSS since Privilege Cloud
  has no Master Policy equivalent at all - it fails cleanly rather than crashing), each showing how
  many actions it contains. Categories are always listed alphabetically.
- Picking a category shows its **action menu** - each action numbered, with its name, a short
  description, and tags like `[CSV]` (accepts CSV/bulk input) or `[WhatIf]` (currently suppressed
  because WhatIf mode is on). Within a category, actions are sorted alphabetically by name, except
  that any `List` action is always shown first - since you usually want to see what exists before
  acting on it.
- The screen header always shows a **breadcrumb trail** (Profile > Category > Action) so you know
  where you are, plus how many minutes remain on your session token.

**Navigation keys**, available throughout:

| Key | Action |
|---|---|
| A number | Select that category/action |
| `[B]` | Back one level (e.g. from an action menu to the category menu) |
| `[R]` | Restart - return all the way to Profile Selection |
| `[X]` | Exit the application (with a confirmation prompt) |

---

## 4. Running an Action

Selecting an action behaves differently depending on whether it accepts bulk/CSV input (shown
with the `[CSV]` tag on the action menu):

- **Actions without `[CSV]`** (most `Get`/`List` actions, for example) go straight to an
  interactive prompt for whatever fields that action needs.
- **Actions with `[CSV]`** first ask you to choose:

  | Key | Mode |
  |---|---|
  | `[1]` | Process CSV file(s) - point to one or more CSV files and every row is processed in turn |
  | `[2]` | Enter values interactively - the same as a non-CSV action, one item at a time |
  | `[3]` | Generate Template - writes a blank CSV with the correct header row (and an example row, for fields that have one) for this action, so you can fill it in in Excel or a text editor |
  | `[B]` | Back |

Field prompts show a description of what's expected and, where relevant, a default value in
brackets - press Enter to accept the default. Some fields (an account, a safe, a platform) offer
a numbered **search/pick list** instead of asking you to type an exact ID: enter a search term,
choose from the matches shown, and the action fills in the correct underlying ID for you.

### WhatIf mode

WhatIf mode is a session-wide, no-changes-made dry run: every write action (Add, Update, Delete,
and similar) is suppressed and logged instead of actually executed - useful for checking a CSV
file will do what you expect before committing to it. Read-only actions (`Get`, `List`) still run
normally, since they don't change anything regardless. The header shows "WhatIf mode is ON"
whenever it's active.

It isn't something you toggle mid-session - turn it on either by launching with the `-WhatIf`
switch (`.\Manage-Privilege.ps1 -WhatIf`), or by setting **WhatIf Default** to Yes when editing a
profile, so every session opened with that profile starts in WhatIf mode automatically.

---

## 5. Understanding Results

After an action runs, you'll see a summary line ("N succeeded, N failed") and, for actions that
produce output, a results table on screen.

- **Display Limit**: `List` actions and Custom export tools are capped at your profile's
  **Display Limit** setting on screen (default 20 rows, 0 = show everything) so a large result
  doesn't flood the console - the full result set is still available if you save to CSV.
- **Saving to CSV**: most actions ask **"Save results to CSV? [y/N]"** after showing results,
  offering a file save dialog (or a manual path prompt if that dialog isn't available in your
  environment). A handful of bulk export tools - `Custom > Export Entitlements`,
  `Export Group Members (Local)`, `Export Group Members (LDAP)`, and `Test Connectivity` - always
  save automatically to your profile's Output Folder with no prompt, since producing a CSV is
  their entire purpose.
- **List drill-down**: from a `List` result, you can enter a row number to jump straight into
  that item's `Get`/details view, pre-filled with the values from that row - useful for
  inspecting one result further without re-typing its name or ID.

---

## 6. Module Categories at a Glance

| Category | What it's for | Notes |
|---|---|---|
| Accounts | Add, retrieve, update, delete privileged accounts; manage their credentials (change/reconcile/verify in the vault or on the target), check them in/out, and manage automatic CPM management | Self-Hosted and ISPSS |
| Safes | Add, retrieve, update, delete safes; create a safe from a template safe's settings and members; assign/unassign a CPM | Self-Hosted and ISPSS |
| SafeMembers | Add, list, update, remove safe members; grant permissions matching a "role" member on a template safe | Self-Hosted and ISPSS |
| Platforms | Retrieve, list, enable, disable, copy, remove, import, export platforms; configure PSM settings | Self-Hosted and ISPSS; `Rename` is Self-Hosted only (PVWA 15.0+) |
| Policies | View/update the Master Policy | PVWA 14.6+; viewing (`GetMasterPolicy`) appears on both but is confirmed to always fail on ISPSS - Privilege Cloud has no Master Policy equivalent; updating (`SetMasterPolicy`) is Self-Hosted only |
| Users | Retrieve and list vault users | Self-Hosted and ISPSS |
| Groups | Add, list, update, delete groups; add/remove members | Self-Hosted and ISPSS |
| Applications | Add, retrieve, list, update, delete applications and their authentication methods | Self-Hosted and ISPSS |
| Reports | List PVWA reports | Self-Hosted only |
| Custom | Bulk export tools (including a per-platform policy detail report), a raw API request tester, and the connectivity tester (see below) | Self-Hosted and ISPSS |

A category not supported by your current environment simply won't appear in the category menu -
you don't need to remember which is which.

---

## 7. Session & Token Management

- **Automatic refresh**: aPePAS silently refreshes an ISPSS ClientCredentials token before it
  expires, and keeps a Self-Hosted session alive with periodic activity, so a normal working
  session shouldn't interrupt you with re-authentication.
- **Re-authentication**: for auth methods that can't be silently refreshed (most ISPSS methods
  other than ClientCredentials, and most Self-Hosted methods once the token actually expires),
  you'll be prompted to re-authenticate the next time you try to do something. Your session
  simply pauses for that prompt - you don't lose your place.
- **Inactivity timeout**: if you leave the session idle too long, it ends automatically and
  returns you to Profile Selection.
- **Logging**: every action, error, and session summary is written to a log file (see your
  profile's Log Folder setting - default is a `Logs` folder next to the application). Full
  request/response detail for troubleshooting is written to the log file only, at a more verbose
  level than what's shown on screen, so it never clutters your terminal.

---

## 8. Profile Settings Reference

Edit a profile (`[E]` from its detail screen) to change any of these. The full field list,
including ones you're unlikely to need to touch by hand, is in
[All profile fields](#all-profile-fields) at the end of this section. The ones you'll use most:

- **Output Folder** - where CSV results and templates are saved by default.
- **Log Folder** - where the session's log file is written.
- **Display Limit** - how many rows of a result are shown on screen (0 = unlimited).
- **IgnoreSSL** - skip TLS certificate validation. Only for test/lab environments with a
  self-signed certificate - never enable this against a production system. Applies to every API
  call, including the WebView2 browser window used for SAML/OIDC login. Switching to a different
  profile that doesn't set this correctly restores normal certificate validation on that profile's
  very next call - it's never left silently active from a previous profile.
- **WebView2 Assembly Path** - only used for SAML/OIDC (Self-Hosted) or SSO (ISPSS) login. Leave
  blank (the default) unless you see a `Microsoft.Web.WebView2.WinForms.dll not found` error -
  aPePAS already checks several standard locations first (see
  [WebView2 setup](#webview2-setup-samloidcsso-only) in section 1), so this is only needed if the DLL lives somewhere else on your machine.
- **CPM_List** - a comma-separated list of CPM usernames you maintain yourself, used as a
  fallback for the CPM picker (Safes > Add, Add Safe From Template, Assign CPM to Safe) if a live
  lookup of registered CPM users fails. If the live lookup succeeds, it's used instead and this
  field isn't needed.
- **Role_Template_Safe** / **Role_Group_Prefix** - used by Add Safe From Template and the
  SafeMembers "From Template Role" actions to know which safe to copy from and which of its
  member groups represent assignable "roles." Ask whoever manages your safe-naming conventions
  what these should be set to.

### All profile fields

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
| WebView2AssemblyPath | Full path to `Microsoft.Web.WebView2.WinForms.dll` for SAML/OIDC/SSO login, only needed if auto-detection fails (see Requirements above) |
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

## 9. Special Tools (Custom Category)

- **Test API** - send a raw request (any method, path, query string, and JSON body) to the
  connected system and inspect the full response, including headers if you toggle verbose mode.
  Useful for confirming exactly what an endpoint returns before building a workflow around it, or
  for reaching an endpoint no dedicated module covers yet. You can save the full request/response
  history of a session to a JSON file.
- **Test Connectivity** - given a server address, type (Windows or Linux), and account, checks
  DNS resolution, the relevant TCP ports, and then attempts an actual credential validation (an
  SMB connection for Windows, SSH for Linux). If you don't supply a password, it looks the
  account up in the vault by address and username. Windows and Linux servers can be tested one at
  a time or via a CSV batch; results always save to CSV automatically. For reliable Linux
  password validation, having PuTTY's `plink.exe` available is recommended - see
  [plink.exe](#plinkexe-linux-connectivity-tests) in section 1. An optional `Additional Ports` field (or `AdditionalPorts`
  CSV column) checks any extra comma-separated TCP ports beyond the built-in ones (135/139/445/3389
  for Windows, 22 for Linux) - these are purely informational, shown in the `PortCheck` result
  column alongside the built-in ports, and never affect whether the credential check runs or its
  pass/fail outcome.
- **Export All / Export Entitlements / Export Group Members (Local, LDAP)** - bulk reporting
  tools that page through the relevant `List` endpoints and write a complete CSV, handling
  pagination and large result sets for you. On Self-Hosted, Export All also includes a one-row Master
  Policy snapshot (`Export_PoliciesGetMasterPolicy.csv`). It skips that snapshot on ISPSS, since
  Privilege Cloud has no Master Policy, and it never runs List Reports. A sub-report that fails is
  shown as Failed with its error, and the other sub-reports still run.
- **Export Platform Details** - downloads every *active* platform (of any type) and builds one
  CSV row per platform summarizing its policy settings: every INI and XML setting becomes its own
  column, plus an `OtherFiles` column listing any file bundled with the platform besides its two
  policy files (a `META-INF` folder, if present, is excluded from that list). Since different
  platform types have different settings, a platform missing a given setting simply shows a blank
  value in that column rather than the column being left out.
- **Every Custom export tool's saved filename is fixed, with no date** (`Export Entitlements.csv`,
  `Export_AccountsList.csv`, etc.) - each run overwrites the previous one's file, so the output
  folder always holds the latest snapshot rather than accumulating one file per day. If you want
  dated snapshots kept from automation mode, add `-FilenameFormat` with `{Date}` in the template
  (see Automation mode below); there's no equivalent option for interactive runs.

---

## 10. Troubleshooting

- **"running scripts is disabled on this system"** when launching - your PowerShell execution
  policy is blocking the script. Use `powershell.exe -ExecutionPolicy Bypass -File
  .\Manage-Privilege.ps1` (see [Installing and launching](#installing-and-launching)) rather than changing your
  machine's policy permanently.
- **SAML/OIDC sign-in window doesn't appear** - confirm the WebView2 Runtime is installed (see
  [Before You Start](#1-before-you-start)). If the error specifically says
  `Microsoft.Web.WebView2.WinForms.dll not found`, either place the DLL in one of the locations
  listed under [WebView2 setup](#webview2-setup-samloidcsso-only), or set the profile's **WebView2 Assembly Path** field
  to its exact location.
- **A CPM picker is empty, or falls back to typing a username manually** - the live query for
  registered CPM users failed or returned none, and no fallback `CPM_List` is set on your
  profile; either fix the underlying permissions/connectivity issue or set `CPM_List` as a
  fallback.
- **Test Connectivity's Linux check reports a timeout** - if `plink.exe` isn't available, the
  fallback path (PowerShell 7's SSH transport) cannot reliably validate a password
  non-interactively and can time out even with correct credentials. Install `plink.exe` (see the
  README) for reliable results.
- **Where are my log files?** - your profile's Log Folder (default: a `Logs` folder next to
  `Manage-Privilege.ps1`). The log records what happened at a level of detail useful for
  reporting an issue.
- **Deleting a safe fails and asks if you want to rename it instead** - this happens when
  CyberArk refuses the delete (HTTP 409) even though the safe has no accounts left in it, most
  likely because Safe History Retention is still holding onto history from accounts previously
  added or removed under different retention settings. Accepting the rename marks the safe
  `1_DEL_<name>` (with a "Delete requested" note added to its description) so it's out of normal
  use and clearly flagged for later cleanup, since there's no way to force the delete through the
  API. If the rename also fails, the safe needs manual attention via the PVWA UI.
- **Why is the SafeMembers permission role called `ReadOnlyStrict` instead of `ReadOnly`?** - PVWA's
  own built-in `ReadOnly` role (and psPAS's preset of the same name) grants `retrieveAccounts`
  (password retrieval). aPePAS's preset is list/audit/view only and never grants retrieve access,
  so it's deliberately named `ReadOnlyStrict` to avoid the same name meaning something different
  here than it does in PVWA or psPAS. If you need retrieve access, use `EndUser` or a higher
  preset, or `Specified` to set individual permissions.

---

## 11. Getting More Help

- [README.md](../README.md) - installation, requirements, and the full profile field reference.
- [Claude_Docs/Design_Architecture.md](../Claude_Docs/Design_Architecture.md) - how the tool is put together, for anyone extending it.
- [Claude_Docs/Testing_Plan.md](../Claude_Docs/Testing_Plan.md) - known issues and what has/hasn't been verified against
  a live system, if you hit unexpected behavior.
