# aPePAS User Guide

This guide is for people **using** aPePAS to manage a CyberArk PAS environment: creating a profile, running actions, scheduling unattended runs and getting results out. For CSV column details, see the [CSV Reference](CSV-Reference.md). To change the tool itself, see [Design_Architecture.md](../Claude_Docs/Design_Architecture.md) and [Reference_API-Module-Guide.md](../Claude_Docs/Reference_API-Module-Guide.md).

---

## 1. Before You Start

You'll need, depending on your environment:

- **Self-Hosted PVWA**: the PVWA base URL (for example `https://pvwa.example.com`) and, if it isn't the default, the PVWA application name (default `PasswordVault`).
- **Privilege Cloud (ISPSS)**: your tenant subdomain. For a tenant at `acme.privilegecloud.cyberark.cloud`, that's `acme`.
- Your username and the authentication method you've been given: CyberArk, LDAP, RADIUS, SAML, Shared, PKI or PKIPN on Self-Hosted (OIDC isn't supported); ClientCredentials, Interactive or SSO on Privilege Cloud.

aPePAS runs on **Windows PowerShell 5.1**. If you run it under PowerShell 7 instead, API errors report their real HTTP status (for example 404).

### Installing and launching

1. Clone or download the repository to a local folder, for example `C:\Tools\aPePAS`.
2. If you downloaded a ZIP, unblock the files: `Get-ChildItem -Recurse | Unblock-File`
3. Keep the folders together: `Manage-Privilege.ps1` needs `Driver`, `Modules`, `Auth` and `APIModules` next to it. If one is missing, startup lists it under "Prerequisite check failed" and exits with code 1.
4. Run the driver. Nothing needs to be installed or imported.

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\Manage-Privilege.ps1
   ```

### WebView2 (SAML and SSO only)

Self-Hosted SAML and Privilege Cloud SSO open a sign-in window. They need the [Microsoft Edge WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/) (often already installed on Windows 10 and 11) and the `Microsoft.Web.WebView2.WinForms.dll` assembly. aPePAS looks for the DLL in this order:

1. The profile's **WebView2 Assembly Path**, if set.
2. The `Auth\` folder.
3. The `Auth\WebView2\` folder.
4. The NuGet package cache, `%USERPROFILE%\.nuget\packages\microsoft.web.webview2\`.

To get the DLLs, download the `Microsoft.Web.WebView2` package from [nuget.org](https://www.nuget.org/packages/Microsoft.Web.WebView2) (a `.zip` with a different extension). Copy `Microsoft.Web.WebView2.WinForms.dll` and `Microsoft.Web.WebView2.Core.dll` from `lib\net462\`, and the `WebView2Loader.dll` for your architecture from `runtimes\win-<x64|x86|arm64>\native\`, into a new `Auth\WebView2\` folder. They aren't included in the repository.

**Self-Hosted SAML** needs SAML set up on the PVWA. The sign-in starts at the PVWA: aPePAS asks it for a sign-in request, opens your identity provider in the window, and the window closes by itself once you've signed in ("Signed in. This window closes by itself."). Your user must be allowed to use the PVWA's `saml` method. A sign-in started from the identity provider's own portal isn't accepted by the PVWA.

The window keeps its browser data (including the identity provider's sign-in cookies) in `%LOCALAPPDATA%\aPePAS\WebView2`. Delete that folder to forget them.

**OIDC** isn't supported on Self-Hosted: the PVWA ends an OIDC sign-in with a browser session, not a token aPePAS can use. A profile saved with OIDC stops with a message; edit it and choose another method.

### Linux connectivity tests

**Custom > Test Connectivity** validates Linux (SSH) passwords most reliably with PuTTY's `plink.exe`. It's looked for on the PATH, then in the aPePAS folder, then in `Program Files (x86)\PuTTY` and `Program Files\PuTTY`. Without plink, the test needs **PowerShell 7 (`pwsh`)** installed and uses its SSH transport, which confirms reachability but can't reliably check a password.

### Running the unit tests (optional)

`.\Tests\Run-Tests.ps1` needs Pester 6.0 or later.

---

## 2. Profiles

A **profile** holds everything aPePAS needs to connect to one environment. Profiles are stored per Windows user in `%APPDATA%\IdiraUnifiedScripts\Profiles\`:

| File | Contents | Protected? |
|---|---|---|
| `<name>.json` | Profile settings | No: plain JSON |
| `<name>.cred` | Saved session token | Yes: DPAPI, readable only by the same Windows user on the same machine |
| `<name>.autocred` | Stored automation credential (see `[A]` below) | Yes: DPAPI, same as above |
| `CredentialSources.json` | Config for `Invoke-AutomationWithCredential.ps1` (no secrets) | No |

### Creating a profile

At **Profile Selection**, press **N**. This runs the full edit flow: profile name, system type (**[1] Privilege Cloud** or **[2] Self-Hosted**), auth method, then the subdomain or PVWA URL and every other setting in [Profile Settings](#8-profile-settings-reference). Press Enter to keep a value. System type and auth method always need a choice. For Privilege Cloud, aPePAS fills in the tenant portal and vault URLs and tries to discover the CyberArk Identity URL.

### The profile list

The list shows `#`, `Profile Name`, `System`, `Auth Method`, `Last Used` and `Token` (Valid, Expired, Unreadable or No Token). The default profile is marked `*`. Type a number or a profile name, or press Enter for the default profile (profile 1 if none is set). Other keys: **[N]** New, **[K]** Backup, **[X]** Restore, **[Q]** Quit.

### The profile detail screen

| Key | Action |
|---|---|
| `[C]` | Continue: log in and start the session. Enter does the same. |
| `[E]` | Edit every setting. The name can't be changed. |
| `[P]` | Copy to a new name, then edit the copy. The copy has no saved session, and the detail screen then shows the copy. |
| `[D]` | Delete the profile with its saved token and stored automation credential (asks first). |
| `[T]` | Test Connection: check the saved token with the server (Self-Hosted), or log in, without starting a session. |
| `[L]` | Log Out: delete the saved token. On Self-Hosted it also ends the server session. |
| `[F]` | Set or clear this profile as the default. |
| `[A]` | Automation Credential: set, replace or clear the stored `.autocred` credential. |
| `[B]` | Back to the profile list. |
| `[Q]` | Quit. If the saved token is valid, asks whether to clear it first. |

### Logging in

**Continue** uses a saved token when it can. A saved token older than 15 minutes is refreshed before the session starts. If the profile's Base URL changed since the token was saved, the token is discarded and you log in fresh. Otherwise you're prompted for whatever the auth method needs. See [Session & Token Management](#7-session--token-management).

### Backing up and restoring

**[K]** backs up the profiles you pick (numbers separated by commas, or `all`) to one `.zip`: each profile's settings and saved token. **[X]** restores from a `.zip` and asks before overwriting a profile with the same name. A saved token only works for the same Windows user on the same machine. Restored elsewhere, the settings come back and you're told which profiles need a fresh login. Stored automation credentials and `CredentialSources.json` aren't backed up, and the backup screen says so: re-create the credential on the target machine (**[A]** on the profile, or `Sync-AutomationCredential.ps1`) and copy `CredentialSources.json` yourself.

### Launch parameters

```powershell
.\Manage-Privilege.ps1 -StartProfile "Prod"                # list opens with Prod as the default
.\Manage-Privilege.ps1 -StartProfile "Prod" -AutoConnect   # connect to Prod straight away
.\Manage-Privilege.ps1 -WhatIf -LogLevel DEBUG
```

`-AutoConnect` needs `-StartProfile`. It's a convenience for shortcuts, **not** for unattended runs: if there's no usable saved session it still prompts you to log in, and on any failure (profile not found or incomplete, login failed) it drops back to the profile list. It applies only to the first launch, not after **[R]** Restart. For unattended runs, use automation mode.

### Automation mode

Add `-Category` and `-Action` to `-StartProfile` to run one action with no menus or prompts, then exit:

```powershell
.\Manage-Privilege.ps1 -StartProfile "Prod" -Category Safes -Action List
.\Manage-Privilege.ps1 -StartProfile "Prod" -Category Accounts -Action Add -InputFile ".\new-accounts.csv"
.\Manage-Privilege.ps1 -StartProfile "Prod" -Category Custom -Action ExportEntitlements `
    -OutputFolder "D:\Reports\Nightly" -FilenameFormat "{Profile}_{ModuleName}_{Date}"
```

| Parameter | Meaning |
|---|---|
| `-StartProfile <name>` | Profile to use. Required. |
| `-Category`, `-Action` | The action, by category and action name (the file name `APIModules\<Category>\Invoke-<Category><Action>.ps1`). Both are required. |
| `-InputFile <csv>` | CSV input, for an action that accepts CSV. Can't be combined with `-InputJson`. |
| `-InputJson <json or path>` | Input for one item: a JSON string (`'{"SafeName":"MySafe"}'`) or a `.json` file path. With neither, the action runs with empty input, and missing required values fail as normal. |
| `-OutputFolder <path>` | Where this run's CSV files go, instead of the profile's Output Folder. Created if missing. It also receives the `<input>_<yyyy-MM-dd>_output.csv` results file of an `-InputFile` run, and Export All's per-report files, and the files saved by Retrieve SSH Key, Export Platform and Export Report. |
| `-FilenameFormat <template>` | File name for the action's saved CSV, using `{ModuleName}`, `{Category}`, `{Action}`, `{Profile}` and `{Date}` (`yyyy-MM-dd`). `.csv` is added if missing. Not used for Export All's per-report files or an `-InputFile` results file. |
| `-Credential <PSCredential>` | A credential held in memory for this run, normally passed by `Invoke-AutomationWithCredential.ps1` (below). |
| `-JobFile <path>` | Run several actions under one login instead of `-Category`/`-Action`. See [Job files](#job-files). |
| `-WhatIf` | Run in WhatIf mode. |
| `-LogLevel` | `VERBOSE`, `DEBUG`, `INFO`, `WARN` or `ERROR`. Default: `INFO`. |
| `-LogFolder <path>` | Log folder for `startup.log`, and for session logs when the profile has no Log Folder or it doesn't exist. Default: `Logs` next to `Manage-Privilege.ps1`. |

**It never prompts.** Anything that would need input (a first login, a refresh with no silent path, an action that's always interactive such as Test API) is logged and the run exits instead. Without `-Credential`, the profile needs a saved session from an earlier interactive login, run under the **same Windows account** that will run the task. SAML and SSO sessions can't be refreshed unattended. For Self-Hosted CyberArk, LDAP and RADIUS, and Privilege Cloud Interactive, a refresh uses the credential captured at login, or else the profile's stored automation credential (`[A]`). Privilege Cloud Interactive refreshes only when your login needs nothing beyond a password (no MFA).

A profile with **WhatIf Default** turned on makes automation runs WhatIf too: nothing changes, and the run still exits `0`.

| Exit code | Meaning |
|---|---|
| `0` | Success. |
| `1` | Crash, missing aPePAS files, or invalid parameters (`-Category` without `-Action`, `-InputFile` with `-InputJson`, `-AutoConnect` without `-StartProfile`, `-Credential` outside automation mode). |
| `2` | The action ran, but some items failed (CSV rows, or Export All sub-reports). |
| `3` | Couldn't run: profile not found or can't log in, no such action or not supported on this system, an always-interactive action, `-InputFile` for an action that doesn't accept CSV, `-InputFile` not found, `-InputJson` that can't be parsed, or a 401/connection failure during the action. |

An `-InputFile` that's empty, unreadable or missing a required column is skipped and logged, and the run exits `3`. Problems before the profile connects (for example profile not found, or login failed) are logged to `startup.log` in the default log folder. After connecting, the run writes a session log like an interactive session (see [Logging](#logging)).

### Job files

A job file runs several actions one after another with a single login, so the steps share the profile's session (and its silent refresh) instead of logging in once per action. That matters most on Privilege Cloud, where logins are rate-limited.

```powershell
.\Manage-Privilege.ps1 -StartProfile "Prod" -JobFile "D:\Jobs\nightly.json"
```

`-JobFile` needs `-StartProfile` and replaces `-Category`, `-Action`, `-InputFile` and `-InputJson`. `-OutputFolder`, `-FilenameFormat` and `-WhatIf` on the command line are defaults for every step. `JobFile.example.json` in the aPePAS folder is a starting point:

```json
{
  "StopOnFailure": false,
  "Steps": [
    { "Name": "Nightly safe list", "Category": "Safes", "Action": "List",
      "OutputFolder": "reports", "FilenameFormat": "{Profile}_{ModuleName}_{Date}" },
    { "Name": "Onboard new accounts", "Category": "Accounts", "Action": "Add",
      "InputFile": "new-accounts.csv", "StopOnFailure": true },
    { "Name": "Check one safe", "Category": "Safes", "Action": "Get",
      "InputJson": { "SafeName": "MySafe" } }
  ]
}
```

| Step field | Meaning |
|---|---|
| `Category`, `Action` | Required. The action to run, as for `-Category`/`-Action`. |
| `Name` | Optional label for the log. |
| `InputFile` / `InputJson` | Input, as for `-InputFile`/`-InputJson` (not both). `InputJson` can be an object, as above, or JSON text. |
| `OutputFolder`, `FilenameFormat` | Override the command-line values for this step. |
| `WhatIf` | `true` runs just this step in WhatIf mode. |
| `StopOnFailure` | `true` stops the job if this step doesn't exit `0`. The top-level value is the default for every step. |

- Relative paths in the job file are relative to the job file's folder, so a job folder can be moved as a whole.
- The whole file is checked **before** logging in: bad JSON, a missing `Category`/`Action`, an action that doesn't exist, or a missing `InputFile` exits `3` without a login.
- Before each step the session is refreshed silently if it expired. A step that ends the session (401 or no connection) stops the job, and so does a failed step with `StopOnFailure`.
- The exit code is the worst step's (`3` beats `2` beats `0`), and `3` if any step didn't run. The log lists every step's result.
- `Invoke-AutomationWithCredential.ps1 -ProfileName ... -JobFile ...` runs a job with a credential from aPeSecrets.

### Unattended runs with Invoke-AutomationWithCredential.ps1

`Invoke-AutomationWithCredential.ps1` gets the profile's credential from a credential store each time it runs, then runs one automation action with it. It uses the sibling **aPeSecrets** project (default `..\aPeSecrets\Modules\CredentialResolver.psm1`; override with `-APeSecretsPath`). Supported sources:

| Source | Where the credential comes from |
|---|---|
| `CP` | CyberArk Credential Provider |
| `CCP` | CyberArk Central Credential Provider |
| `Conjur` | CyberArk Conjur |
| `PSCredential` | A DPAPI-protected credential file (`Export-Clixml`) |
| `WindowsCredentialManager` | Windows Credential Manager |

**Config file.** `CredentialSources.json` in the profile folder (override with `-ConfigPath`) maps each profile name (not case-sensitive) to a source. It says only **where** the credential is: an entry with a `Password`, `Secret`, `ClientSecret`, `ApiKey` or `Token` key is refused. Start from `CredentialSources.example.json`. Each source's `Params` are passed to aPeSecrets unchanged; see the aPeSecrets documentation for the full list.

```json
{
  "Profiles": {
    "Prod": {
      "Source": "CCP",
      "Params": { "BaseUrl": "https://ccp.example.com", "AppID": "aPePAS-Automation",
                  "Safe": "AutomationSafe", "Object": "svc-apepas" }
    }
  }
}
```

**Supported auth methods** (the profile's own setting): Self-Hosted CyberArk, LDAP and RADIUS; Privilege Cloud ClientCredentials (username = client ID, password = client secret) and Interactive without MFA. Other methods exit `3`.

**What it does.** If the profile has a usable saved session, that's used, and the credential is used for any refresh. If not, it logs in fresh, so no earlier interactive login is needed. The credential stays in memory. It's never written to disk, and the saved session leaves out the password or client secret.

**Parameters.** `-ProfileName` (required), `-Category` and `-Action` or `-JobFile` (one of them is required unless `-ResolveOnly`), and the pass-through parameters `-InputFile`, `-InputJson`, `-OutputFolder`, `-FilenameFormat`, `-WhatIf`, `-LogLevel` and `-LogFolder`. `-ResolveOnly` checks a config entry: it gets the credential, prints the username and exits without running anything (exit `0` if the credential was found, `3` if not).

**Exit codes.** Manage-Privilege.ps1's own (see above), or `3` when the config can't be read, the credential can't be resolved, or `-Category`/`-Action` is missing.

**Task Scheduler example.** Run the task as the Windows account that owns the profile folder, because the profiles and `CredentialSources.json` are under that account's `%APPDATA%`:

```text
Program:   powershell.exe
Arguments: -NoProfile -ExecutionPolicy Bypass -File "C:\Tools\aPePAS\Invoke-AutomationWithCredential.ps1" -ProfileName "Prod" -Category Safes -Action List -OutputFolder "D:\Reports"
```

The script's exit code is the one described above, so the task can be checked the same way as any automation run.

**Sync-AutomationCredential.ps1** is a separate option. It gets a credential from an aPeSecrets source once and saves it as the profile's `.autocred` file, the same file `[A]` sets. Automation mode uses that file only to refresh an existing saved session (Self-Hosted CyberArk, LDAP and RADIUS; Privilege Cloud Interactive), never to log in fresh. `Invoke-AutomationWithCredential.ps1` doesn't need it: a credential passed with `-Credential` is used instead of the `.autocred` file. Run Sync from a PowerShell prompt, because `-Params` is a hashtable:

```powershell
.\Sync-AutomationCredential.ps1 -ProfileName 'Prod' -Source WindowsCredentialManager -Params @{ Target = 'svc-apepas' }
```

It exits `0` when the credential is stored and `1` otherwise.

---

## 3. Navigating the Menus

Once connected you get a **category menu**, then an **action menu** for the category you pick.

- **Header:** `aPePAS - CyberArk PAS Driver` and its version, the signed-in user, a breadcrumb (Profile > Category > Action), and `[WhatIf Mode ON - no changes will be made]` when WhatIf is on.
- **Category menu:** every category available on your system, alphabetically, with its action count. Categories with no actions for your system don't appear (for example Reports on Privilege Cloud).
- **Action menu:** each action with a description and tags: `[CSV]` (accepts a CSV file) and `[WhatIf]` (writes are being suppressed). `List` comes first, then the rest alphabetically. An action that failed to load is shown with `[Load Failed]`.
- **Footer:** token minutes remaining (yellow at 5 minutes or less), idle minutes out of the timeout and an inactivity warning near the end (category menu only), and the available keys.

| Key | Action |
|---|---|
| A number | Select that category or action |
| `[B]` | Back to the category menu (action menu only; Enter does the same) |
| `[R]` | Restart: back to Profile Selection (asks first) |
| `[X]` | Exit the script (asks first) |

---

## 4. Running an Action

- **Actions without `[CSV]`** go straight to their prompts. This includes every `List` action and most tools.
- **Actions with `[CSV]`** first ask (Enter = Back):

  | Key | Mode |
  |---|---|
  | `[1]` | Process CSV file(s): pick one or more files. Every row is processed in turn. |
  | `[2]` | Enter values interactively, one item. |
  | `[3]` | Generate Template: save a CSV with the right header (see below). |
  | `[B]` | Back |

  The Get actions that accept CSV are Get Account, Get Account Activity, Get Platform, Get Safe and Get User.

**Prompts** show a description and any default in `[default: ...]`. Press Enter to accept it. Accounts, platforms, groups, users and applications offer a **search and pick list**: type a search term, then pick from up to 25 numbered matches (or `B` to cancel). Safes have no pick list, so type the safe name.

### CSV files

- The file picker opens in the profile's **Input Folder** (or the aPePAS folder).
- A file that's empty, unreadable, or missing a required column is skipped with a message. Column names must match exactly, including case.
- Each file produces `<inputname>_<yyyy-MM-dd>_output.csv`: the input columns plus `IsSuccess` and `Summary` (`OK`, or the first error). It goes to the profile's Output Folder if that folder exists, otherwise next to the input file. In automation mode, `-OutputFolder` takes priority.
- Each file also produces `<inputname>_<yyyy-MM-dd>_detail.csv` in the same folder: everything each row returned, one line per result (or per error), with `RowNumber` and `Status` (`OK`/`Failed`) first. Columns are the union of every row's results, so a Get or Test Connectivity run from a CSV keeps its full output. Columns whose names look secret (password, secret, credential, token) are written as `***`.
- At the end you see `'<file>': N processed - N OK, N failed.`
- For a Get action, the results file records success or failure per row, not the full details. Use interactive mode for those.
- If the server rejects the session (401) partway through, aPePAS logs in again (prompting if needed) and retries that row once.
- **Generate Template** writes the header, plus one example row when the action defines examples (Add Application Authentication Method, Add Safe From Template). Delete the example row before running the file.

Column details for every action are in the [CSV Reference](CSV-Reference.md).

### Identifying an account in a CSV

Every Accounts action that accepts CSV, except Add, finds the account by `AccountID`, or by `Safe` plus `AccountName` (the object name, not the username; an `ObjectName` column also works) and/or `UserName`. A row that matches no account, or more than one, fails and changes nothing. In Update, `UserName` is the new value, so Update matches on `AccountID` or `AccountName` with `Safe`. Get Account Credential doesn't accept CSV. See [Accounts](CSV-Reference.md#accounts) in the CSV Reference.

### WhatIf mode

WhatIf is a dry run for the whole session: every POST, PUT, PATCH and DELETE request is logged and skipped, and read-only actions run normally. Turn it on with the `-WhatIf` launch parameter, or set **WhatIf Default** on the profile. It can't be toggled during a session.

---

## 5. Understanding Results

After an action you see `Result: N succeeded, N failed.` and a results table, or `Result: N failed.` with each error and, where CyberArk returned one, its error code.

- **Display Limit** (profile setting, default 20, 0 = all) shortens the on-screen table for `List` actions and the Custom output tools only. Saved CSV files always have every row.
- **Saving:** most actions then ask `Save results to CSV? [y/N]` and open a save dialog (or a path prompt) with the name `<Action Name> <yyyy-MM-dd>.csv` in the Output Folder.
- **Auto-saving tools** save with no prompt:

  | Tool | File |
  |---|---|
  | Export Entitlements, Export Local Group Members, Export LDAP Group Members, Export Platform Details | `<Tool Name>.csv`, no date, overwritten on each run |
  | Test Connectivity (single server) | `Test Connectivity - <Address> <yyyy-MM-dd>.csv` |
  | Export All | One `Export_<Category><Action>.csv` per sub-report, overwritten on each run. Its own summary table still asks `[y/N]`, with a dated name. |
  | Platforms > Export Platform | `Platform-Export-<type>-<id>-<yyyyMMdd-HHmmss>.zip` |

- **401 or connection failure:** the saved token is discarded and you're asked to log in again.
- **Drill-down:** after a `List`, enter a row number to open that item's Get view filled in from the row. This works where the category has a Get action (Accounts, Applications, Platforms, Safes, Users) or Get Members (Groups), not for List Safe Members or List Reports.

---

## 6. Module Categories at a Glance

| Category | Actions | Notes |
|---|---|---|
| Accounts | List, Add, Cancel CPM Task, Change Credentials Immediately, Change Credentials In Vault, Check In, Add Dependent Account, Delete, Delete Dependent Account, Delete Discovered Account, Get, Get Dependent Account, Get Activity, Get Credential, Get Discovered Account, Link Account, List All Dependent Accounts, List Dependent Accounts, List Discovered Accounts, List Onboarding Platforms, Onboard Discovered Account, Reconcile, Request JIT Access, Resume Auto Management, Retrieve SSH Key, Revoke JIT Access, Unlink Account, Unlock, Update, Verify | |
| Applications | List, Add, Add Authentication Method, Delete, Delete Authentication Method, Get, List Authentication Methods | |
| Custom | Export All, Export Entitlements, Export LDAP Group Members, Export Local Group Members, Export Platform Details, Test API, Test Connectivity | See [section 9](#9-special-tools-custom-category) |
| Groups | List, Add, Add Member, Delete, Get Members, Remove Member, Update | |
| Platforms | List, Copy, Disable, Enable, Export, Get, Import, Remove, Rename, Set PSM Config | Rename: Self-Hosted only, PVWA 15.0+ |
| Policies | Get Master Policy, Set Master Policy | PVWA 14.6+. Set is Self-Hosted only. Get is listed on Privilege Cloud but always fails there (no Master Policy). |
| Reports | List, Export | Self-Hosted only. Export needs PVWA 14.6+. |
| SafeMembers | List, Add, Add From Template Role, Remove, Update, Update From Template Role | |
| Safes | List, Add, Add From Template, Assign CPM, Delete, Get, Unassign CPM, Update | |
| Users | List, Add, Add Allowed Auth Method, Delete, Disable, Enable, Get, Remove Allowed Auth Method, Reset Password, Unblock, Update | Add, Update, Enable, Disable and the Allowed Auth Method actions: Self-Hosted only |

**Accounts.** Link Account and Unlink Account use `ExtraPasswordIndex` `1` = Logon, `2` = Elevate, `3` = Reconcile. **Delete Account**: when the PVWA refuses to delete an SSH key account with PASWS056E, aPePAS retries on the older delete route and logs a warning; the result shows which route was used.

**Request JIT Access** adds you (the logged-on user) to the local Administrators group on the account's Windows machine, and **Revoke JIT Access** removes you. You must be logged on as an LDAP (domain) user, the account's platform must allow ad hoc access, and you need List and Use accounts on its safe. A Vault user gets PASWS211E / PASWS293E.

**Retrieve SSH Key** saves an SSH key account's private key to `SSHKey-<AccountID>-<date-time>.key` in the Output Folder. The key is never shown on screen, logged or written to the results CSV, which shows only the file path. Treat the file as a secret and delete it when you're done. Give a Reason, ticketing system and ticket ID when the platform requires them. It works on one account at a time (no CSV input).

**Discovered (Pending) accounts** (Self-Hosted only, PVWA 11.6+, and you must be in Vault Admins or PVWAAccountsFeedAdmins): **List Discovered Accounts** shows the accounts that discovery found and that wait to be onboarded, with filters for platform type, privileged, enabled, account type and source. **Onboard Discovered Account** (PVWA 12.6+) moves one into a safe with a platform; when you run it from the menu it lists the platforms the PVWA recommends for that safe and account type. **Delete Discovered Account** removes one entry from the Pending list. Clearing the whole list isn't offered.

**Dependent accounts** (Self-Hosted only, PVWA 14.6+) are the services, scheduled tasks and similar items that use a master account's password. **List Dependent Accounts** shows one master account's dependents and **List All Dependent Accounts** shows them across the Vault (filter by safe or platform). **Add**, **Update** and **Delete Dependent Account** manage them; Update changes only the fields you fill in. **Sync** and **Resume Dependent Account** ask the CPM to sync the dependent with its master, or to resume managing it. Platform properties (for example `TaskName`) go in `PlatformAccountProperties` as `Key=Value;Key2=Value2`, or in `Platform_<Key>` columns.

**Applications.** Authentication types are path, hash, OS user, machine address, certificate serial number (`certificateSN`) and certificate attributes (`certificateattr`). For `certificateattr`, give `Subject`, `Issuer` and/or `SubjectAlternativeName` (at least one) as semicolon-separated `Attribute=value` pairs in the same order as in the certificate. CyberArk requires that order and doesn't report a wrong one. No `AuthValue` is needed for this type. List Application Authentication Methods has `Subject`, `Issuer` and `SubjectAlternativeName` columns (blank for other types), and the Delete picker shows those values.

**Groups.** List Groups has a `Directory` column: the LDAP directory a directory group belongs to. On Self-Hosted that name is also the SearchIn value for LDAP members. Add and Remove Group Member take a **username**, not a numeric ID.

**Platforms.** Copy, Disable, Enable, Remove, Rename and Set PSM Config work on target platforms only. List Platforms can filter by Search, Active Only, System Type and **Platform Type** (`Regular` or `Group`, blank for both). In automation mode, pass them with `-InputJson`, for example `'{"PlatformType":"Group","ActiveOnly":"true"}'`.

**Reports.**
- List Reports shows each report's `Status`, `CreatedAt`, `CreatedBy`, `Records`, `Safe`, `Location` and `FileName` when PVWA returns them.
- Export Report downloads a generated report to the profile's Output Folder as Excel (`.xlsx`, the default) or CSV. Give the report's exact name as List Reports shows it (it must match exactly one report), or a report ID. PVWA 14.6 or later. See [Reports](CSV-Reference.md#reports) for CSV columns.

**SafeMembers.**
- List Safe Members includes predefined users and groups (Master, Batch, Auditors and so on), marked in the `IsPredefinedUser` column.
- List Safe Members can also filter by **Member Type** (`User` or `Group`) and **Membership Expired** (`true` or `false`), and sort by member name (`asc` or `desc`). Leave them blank for all members. In automation mode, pass them with `-InputJson`, for example `'{"SafeName":"MySafe","MemberType":"Group"}'`. On a PVWA older than 12.1, which rejects the filter, the list is fetched unfiltered and these three are applied locally (predefined users are then missing, as before).
- Add Safe Member and Add Safe Member From Template Role show a **SearchIn** picker: Vault, then your directories. On Privilege Cloud each directory's value is its Identity ID.
- Permission presets are `ReadOnlyStrict`, `EndUser`, `PowerUser` and `SafeManager`, or set each permission yourself. `ReadOnlyStrict` never grants password retrieval. A preset overrides the individual permissions. See [Permission columns](CSV-Reference.md#permission-columns-add-and-update) for CSV rules.
- Update Safe Member offers three modes: a preset, individual permissions (press Enter to keep a permission's current value), or keep the current permissions and change only the expiration date. On both Update actions a blank expiration date keeps the current one, and `None` removes it.
- The From Template Role actions copy permissions from a role member of the profile's Role Template Safe.

**Safes.**
- **Add Safe:** `AutoPurgeEnabled` accepts `true`, `yes`, `y` or `1` (any case) to turn auto-purge on. Anything else leaves it off. It can only be set here, when the safe is created.
- **Update Safe** doesn't ask for AutoPurgeEnabled. A CSV that still has the column logs a warning.
- **Add Safe From Template** copies the template safe's settings and members, except role groups and the template's own CPM when that CPM is in the CPM list. Description and Managing CPM aren't copied. Each extra member asks for SearchIn (Vault or a directory). In CSV, `ExtraMembers` entries are `Type:Name:RoleName[:SearchIn]`.
- Add Safe, Add Safe From Template and Assign CPM use the [CPM picker](#8-profile-settings-reference).

**Users.**
- The write actions work on Vault users. On Privilege Cloud most users live in CyberArk Identity, so only Delete, Unblock and Reset Password are listed there, and they apply to Vault users only (for example component users).
- Every action except Add finds the user by `UserID`, or by exact `Username`. A username that matches no user, or more than one, fails that row and nothing changes.
- **Add User** and **Reset User Password** ask for the password twice, with hidden input. It's never logged or shown in results. In a CSV file the password is in clear text, so protect the file and delete it after the run. The results file shows `***` in its place.
- **Get User** shows Email (the business email), Enabled, Suspended, Description, Location and ExpiryDate (local `yyyy-MM-dd HH:mm`) along with the name fields. **List Users** shows Enabled, Suspended and Location but no email, because the user list from the API doesn't include one. Use Get User for a user's email.
- **Update User** changes only the fields you fill in. Blank fields keep their current values. `VaultAuthorization` replaces the whole list.
- **Delete User** and **Disable User** show a warning before you pick the user. Delete can't be undone. A disabled user can't log on until **Enable User** is run.
- **Enable**, **Disable** and the **Allowed Auth Method** actions fall back to an older update call on PVWA versions that don't have the newer endpoint (before 12.6 and 14.6).
- **Add / Remove Allowed Auth Method** wait for the PVWA's background job and report its result. When the job fails (PVWA 14.6 fails it for users with no expiry date), they update the user directly instead, and the log shows a warning. A row fails if the PVWA answers but doesn't save the change, for example when the method is disabled. For LDAP users the PVWA takes allowed methods from the directory mapping, so change the mapping instead.

---

## 7. Session & Token Management

- **At login:** a saved token older than 15 minutes is refreshed first. A changed Base URL forces a fresh login. Self-Hosted tokens are checked with the server. Privilege Cloud tokens are accepted on their local expiry time.
- **Self-Hosted keepalive:** after you make a menu choice, if the token has 2 minutes or less left, aPePAS makes one small API call to extend it. There's no background timer, so an idle console isn't kept alive.
- **Privilege Cloud ClientCredentials:** refreshed silently about 10 minutes before expiry.
- **When a token expires** (interactive sessions):

  | System and method | What happens |
  |---|---|
  | Self-Hosted CyberArk, LDAP, RADIUS | Press Enter, then type your password (X exits) |
  | Self-Hosted Shared, PKI, PKIPN, SAML | Press Enter to log in again (X exits) |
  | Privilege Cloud Interactive, SSO | Press Enter to log in again (X exits) |
  | Privilege Cloud ClientCredentials | Silent |

  If the login fails or you press X, the session ends and the script exits.
- **Inactivity timeout:** 10 minutes since the last API call made for you (by an action, a search, or Test API). Moving around the menus doesn't count, and neither do aPePAS's own background calls (keepalive, token checks). It's checked when a menu is shown and again as soon as you make a menu choice, so if you come back after the timeout the session ends then. The category menu footer warns you in the last minute. When it ends, the script exits; it doesn't go back to Profile Selection.

### Logging

- Console and log file share one level, set with `-LogLevel` (default `INFO`).
- At `DEBUG`, each request's method and URI is logged (console and file). Request bodies and error response bodies are written only at `DEBUG`, and only to the file. Passwords, secrets, tokens and similar values are masked.
- `startup.log` in the default log folder (`Logs` next to `Manage-Privilege.ps1`, or `-LogFolder`) is overwritten at each launch and covers everything before a profile connects.
- Each session then writes a new file, `yyyy-MM-dd_HHmmss_<Profile>_<PID>.log`, in the profile's Log Folder if that folder exists, otherwise in the default log folder.
- When a session starts, session log files older than 30 days are deleted from that folder. Only files with that name pattern are deleted, never other `.log` files.
- The end-of-session summary lists each write action that ran, by name, with items, successes and failures.

---

## 8. Profile Settings Reference

Edit a profile with `[E]` on its detail screen. Stored fields:

| Field (prompt) | Description |
|---|---|
| ProfileName | Name shown in menus. Set when the profile is created. |
| SystemType | `Privilege Cloud` or `Self-Hosted`. |
| AuthMethod | One of the methods for that system type. |
| BaseURL | Both systems. Self-Hosted: the PVWA URL you enter. Privilege Cloud: built from the subdomain as `https://<subdomain>.privilegecloud.cyberark.cloud`. |
| AppName (Application Name) | PVWA application name. Default `PasswordVault`. |
| Username | Pre-fills the login prompt. Updated after an interactive login. |
| LogFolder | Session log folder. Blank: the default log folder (see [Logging](#logging)). |
| InputFolder | Where the CSV file picker opens. Blank: the aPePAS folder. |
| OutputFolder | Where saved CSV files and templates go. Blank: the aPePAS folder; a relative path is relative to it. This applies to every save, including Export All, Export Platform and Test API's JSON save. CSV results files go next to the input file when this is blank. |
| IgnoreSSL (Ignore SSL Errors) | Skip TLS certificate checks, including in the WebView2 sign-in window. **Lab use only.** |
| WebView2AssemblyPath | Full path to `Microsoft.Web.WebView2.WinForms.dll`. Tried first for SAML and SSO. Blank: search the standard locations (see [section 1](#webview2-saml-and-sso-only)). |
| WhatIfDefault | Every session with this profile, including automation runs, starts in WhatIf mode. |
| Limit (Page Size) | Records requested per API call (0 = 1000). aPePAS keeps paging until it has every result. This never caps the total. |
| DisplayLimit | Rows shown on screen for List actions and Custom output tools. Default 20, 0 = all. CSV files always get everything. |
| Role_Template_Safe | Template safe for Add Safe From Template and the SafeMembers From Template Role actions. |
| Role_Group_Prefix | Name prefix of the role members on the template safe. Add Safe From Template doesn't copy them. RoleName values must exactly match one of them. |
| CPM_List | CPM usernames separated by commas. The CPM picker (Add Safe, Add Safe From Template, Assign CPM) queries CPM users live and uses this list when that query fails or finds no CPMs. |
| IsDefault | Set with `[F]`. Marks the default profile. |
| TenantPortal, TenantVault, TenantAuth | Privilege Cloud only. Filled in automatically. TenantAuth is the CyberArk Identity URL, discovered and cached. |
| AuthTokenProfile, LastUsed, Created, Modified | Kept automatically: the saved-token name (same as the profile name), and timestamps. |

---

## 9. Special Tools (Custom Category)

- **Test API:** send a raw request. Pick GET, POST, PUT, PATCH or DELETE and enter a path. Query parameters are asked for GET only, and a single-line JSON body for POST, PUT and PATCH only. The base URL has `/PasswordVault` removed, so **include it in the path**, for example `/PasswordVault/API/Safes` (without it you get a 404). After each request: **[A]** another, **[R]** retry with a new body, **[S]** save the session's requests and responses to `TestAPI_<yyyy-MM-dd_HHmmss>.json`, **[V]** show request and response headers, **[B]** back. Test API is interactive only and can't run in automation mode.
- **Test Connectivity:** for a server address, type (Windows or Linux) and account, checks DNS, TCP ports (135, 139, 445 and 3389 for Windows; 22 for Linux), then the credential (SMB for Windows, SSH for Linux). Leave the password blank to look up the account in the vault by address and username, optionally only in one `Safe`. If several accounts match, the first is used and the `Note` column says so. `AdditionalPorts` checks extra ports for information only, shown in the `PortCheck` column; they never affect the sign-in result. A single server's result saves automatically. A CSV run produces the standard results file. See [Linux connectivity tests](#linux-connectivity-tests) for plink.
- **Export All:** runs every `List` action for your system, plus List Application Authentication Methods and, on Self-Hosted only, Get Master Policy. It never runs List Reports. List Safe Members is off by default because it makes one call per safe; answer **IncludeSafeMembers** with `true`/`yes`/`y`/`1` (or pass `-InputJson '{"IncludeSafeMembers":"true"}'` in automation mode) to include it. Accounts are listed safe by safe. A sub-report that fails shows as Failed with its error and the rest still run. On a 401 or connection failure it checks the login once: if the session is really rejected it stops so you can log in again, otherwise it carries on. In automation mode, any failed sub-report makes the run exit `2` (`3` if it stopped on a rejected session).
- **Export Entitlements:** every member of every safe you can see (optionally filtered by a safe search) in one CSV.
- **Export Local Group Members:** members of local CyberArk groups, with nested groups expanded and level and path columns.
- **Export LDAP Group Members:** members of CyberArk directory groups, found by querying **Active Directory** directly with nested groups expanded. The machine must be able to reach AD. You can give an LDAP path (for example `LDAP://DC=example,DC=com`) or leave it blank for the current domain.
- **Export Platform Details:** one row per active platform, every INI and XML policy setting as its own column (blank where a platform doesn't have it), plus `OtherFiles` listing any other files in the package (excluding a `META-INF` folder).

The auto-saved files from these tools are listed in [section 5](#5-understanding-results). For dated copies from automation mode, use `-FilenameFormat` with `{Date}`. It doesn't apply to Export All's per-report files.

---

## 10. Troubleshooting

- **"running scripts is disabled on this system":** launch with `powershell.exe -ExecutionPolicy Bypass -File .\Manage-Privilege.ps1` instead of changing the machine policy.
- **SAML/SSO window doesn't appear, or `Microsoft.Web.WebView2.WinForms.dll not found`:** install the WebView2 Runtime and put the DLLs in `Auth\WebView2\`, or set the profile's WebView2 Assembly Path (see [section 1](#webview2-saml-and-sso-only)).
- **SAML fails with "did not return an identity provider URL":** SAML isn't set up on the PVWA. If the window closes but the logon fails with PASWS035E, check that your user is allowed the `saml` method.
- **The CPM picker is empty or asks you to type a name:** the live CPM query failed or found no CPMs, and the profile has no CPM List. Fix the permissions or connection, or set CPM List on the profile.
- **Linux connectivity check times out:** without `plink.exe`, the PowerShell 7 SSH fallback can't reliably submit a password and can time out even with the right one. Install plink.
- **An automation run exits 3:** check `startup.log` in the default log folder for failures before connecting, and the profile's session log after.
- **Deleting a safe fails with HTTP 409:** CyberArk can refuse to delete a safe with no accounts left, most likely because Safe History Retention still holds history. aPePAS offers to rename it instead: the new name is `1_DEL_<name>`, cut to 28 characters, and `| Delete requested <date>` is added to the description if it already has one. If the rename also fails, use the PVWA UI. In a CSV run the question pauses the run. In automation mode it isn't asked and the row fails.
- **Why `ReadOnlyStrict` and not `ReadOnly`?** PVWA's and psPAS's own `ReadOnly` role grants password retrieval. aPePAS's preset doesn't, so it has a different name. Use `EndUser` or higher, or `Specified`, if you need retrieval.
- **Where are my log files?** See [Logging](#logging).

---

## 11. Getting More Help

- [CSV Reference](CSV-Reference.md): columns for every action that accepts CSV.
- [Features](Features.md): the full feature list.
- [README](../README.md): overview and requirements.
- [Claude_Docs/Testing_Plan.md](../Claude_Docs/Testing_Plan.md): known issues and what has been checked against a live system.
