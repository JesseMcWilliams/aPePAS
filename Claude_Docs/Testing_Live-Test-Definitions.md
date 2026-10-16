# aPePAS: Live Test Definitions

> **Stage: Testing.** Repeatable live tests against a real PVWA or ISPSS tenant, each with a short label. This file is tracked, so it holds **no lab details**: every environment-specific value is a `{Placeholder}`. The gitignored `Live-Testing.local.md` supplies the values for each environment and lists which labels to run. Live tests run only when asked (see CLAUDE.md, "Live testing").

## How to use
1. Pick a label below and an environment from `Live-Testing.local.md`.
2. Replace each `{Placeholder}` with that environment's value. `{Shell}` is `powershell.exe` (Windows PowerShell 5.1, the runtime target) or `pwsh` (PowerShell 7). Run both when a test says "both editions".
3. Run the command from the repo root, and check every "Pass when" item.
4. Record the result (date, edition, pass/fail) in the matching row of `Testing_Status.md`, and the run itself in `Live-Testing.local.md`.

## Placeholders

| Placeholder | Meaning | Example (fake) |
|---|---|---|
| `{Profile}` | The aPePAS profile name, exactly as passed to `-StartProfile` | `Lab_Automation` |
| `{Username}` | The account the profile signs in as. Checked against the "Signed in as" line | `svc_apepas` |
| `{Shell}` | `powershell.exe -NoProfile -ExecutionPolicy Bypass` or `pwsh -NoProfile` | `pwsh -NoProfile` |
| `{OutputDir}` | A scratch folder for CSV output, outside the repo | `C:\Temp\apepas-live` |
| `{CP.AppID}`, `{CP.Safe}`, `{CP.Object}` | Where the Credential Provider finds the profile's password | `APP_Example`, `Automation Safe`, `svc_apepas` |
| `{AcctSafe}`, `{AcctID}`, `{AcctName}`, `{AcctUser}`, `{SharedUser}` | A test safe; one account's ID, object name and unique username; a username that two accounts in that safe share | `aPePAS-Test`, `11_3`, `srv1-oracle`, `oracle`, `root` |
| `{TemplateSafe}`, `{RolePrefix}`, `{RoleReadOnly}` | The profile's `Role_Template_Safe` (a safe with a CPM assigned and role-group members), its `Role_Group_Prefix`, and one role group on it | `Test-Template`, `RTG_`, `RTG_Test_ReadOnly` |
| `{TemplateCPM}` | The CPM assigned to `{TemplateSafe}` | `PasswordManager` |
| `{VaultUser}` | An ordinary Vault (EPV) user that is not the profile's own user | `test_user01` |
| `{LdapDirectory}`, `{LdapUser}` | A SearchIn value for an LDAP directory, and a user in it | `company.com`, `jdoe` |
| `{SamlProfile}`, `{SamlUser}` | A Self-Hosted profile with AuthMethod SAML and a WebView2 path, and the IdP user it signs in as (allowed method `saml`) | `Lab_SAML`, `saml.tester` |
| `{LdapLogonProfile}`, `{LdapLogonUser}`, `{LdapCP.Object}` | A Self-Hosted profile with AuthMethod LDAP, a user in a mapped LDAP group, and the CP object holding its password | `Lab_LDAP`, `ldap.tester`, `ldap.tester` |
| `{AuthUserID}`, `{ExtMethod}` | A Vault (CyberArk-source) test user with no expiry date, and an enabled external method ID | `98`, `saml` |

## Setup tests

### LT-SETUP-01: Saved token exists
Automation mode refuses a profile with no saved token, because a first logon is always interactive.

- **Run:** `{Shell} -File .\Manage-Privilege.ps1`, select `{Profile}`, connect and log in, then exit.
- **Pass when:** `%APPDATA%\IdiraUnifiedScripts\Profiles\{Profile}.cred` exists.
- **Once per:** host and profile, or after the token file is deleted.

### LT-SETUP-02: Stored automation credential from CP
Seeds `{Profile}.autocred`, which automation mode uses to refresh an expired or aged token without prompting.

```powershell
{Shell} -File .\Sync-AutomationCredential.ps1 -ProfileName '{Profile}' -Source CP `
    -Params @{ AppID = '{CP.AppID}'; Safe = '{CP.Safe}'; Object = '{CP.Object}' }
```

- **Pass when:** exit code 0, and the output says `Stored automation credential for profile '{Profile}' (user '{Username}')`.
- **Once per:** host and profile, or after the password rotates.
### LT-DRIVER-01: Driver script with a credential from aPeSecrets
Needs aPeSecrets next to this repo and a `CredentialSources.json` entry for `{Profile}` (Source CP with
`{CP.AppID}`, `{CP.Safe}`, `{CP.Object}`). **Touches the saved session:** step 3 moves `{Profile}.cred`
aside to force a fresh logon; keep the moved file until the test passes.

```powershell
{Shell} -File .\Invoke-AutomationWithCredential.ps1 -ProfileName '{Profile}' -ResolveOnly
{Shell} -File .\Invoke-AutomationWithCredential.ps1 -ProfileName '{Profile}' -Category Safes -Action List -OutputFolder '{OutputDir}'
# move %APPDATA%\IdiraUnifiedScripts\Profiles\{Profile}.cred to {OutputDir}, then:
{Shell} -File .\Invoke-AutomationWithCredential.ps1 -ProfileName '{Profile}' -Category Safes -Action List -OutputFolder '{OutputDir}'
```

- **Pass when:**
  - Step 1 exits 0 and prints `Resolved a credential for '{Username}'`.
  - Steps 2 and 3 exit 0 and show `Signed in as : {Username}`; step 3 logs `logging in ... with the supplied credential`.
  - After step 3 a new `{Profile}.cred` exists and its RefreshContext has no Credential.
  - The password never appears in the console output or the log.
- **Covers:** the driver rows in both checklists.

### LT-DRIVER-02: Reason shows in the PVWA audit
Needs the `CredentialSources.json` entry for `{Profile}` (Source CP, then again as CCP with `{CCP.BaseUrl}`)
with `"Reason": "aPePAS LT-DRIVER-02 {Profile} {JobFile}: {JobDescription}"`, and a job file `{JobFile}`
with a top-level `"Description": "Reason test"`.

```powershell
{Shell} -File .\Invoke-AutomationWithCredential.ps1 -ProfileName '{Profile}' -JobFile '{JobFile}' -ResolveOnly
```

- **Pass when:** exit code 0, and in the PVWA Activities (audit) view for the `{CP.Object}` account the
  retrieval by `{CP.AppID}` shows the expanded reason. Repeat with the CCP entry.
- **Cache caveat:** a retrieval answered from the Credential Provider cache is not audited again, so it shows no reason. Use an account the AppID has not retrieved recently (or wait out the cache).
- **Check without the PVWA UI:** run `Accounts/GetActivity` for the account (job file step with `Safe` and `UserName`) and read the `Reason` column.

### LT-JOB-01: Job file with a CSV step, through the driver script
Needs LT-DRIVER-01 to pass first. Read-only. In `{OutputDir}`, make `safes.csv` with a `SafeName` column holding `{TemplateSafe}` and a name that doesn't exist, and `job.json` with three steps: Safes/List, Safes/Get with `InputJson` `{ "SafeName": "{TemplateSafe}" }`, and Safes/Get with `InputFile` `safes.csv`, each with `OutputFolder` `out`.

```powershell
{Shell} -File .\Invoke-AutomationWithCredential.ps1 -ProfileName '{Profile}' -JobFile '{OutputDir}\job.json'
```

- **Pass when:**
  - The log shows one `connected` line and `Step 1/3` to `Step 3/3`; steps 1 and 2 exit 0, step 3 exits 2, and the run exits 2.
  - `{OutputDir}\out` holds the List and Get CSVs plus `safes_<date>_output.csv` and `safes_<date>_detail.csv`.
  - The detail CSV has `RowNumber`, `Status` and every Get Safe column for row 1, and an `ErrorMessage` with the CyberArk error code for row 2.

## Logon tests

### LT-LOGON-01: Automation logon and one read
Needs LT-SETUP-01 and LT-SETUP-02. Run on both editions.

```powershell
{Shell} -File .\Manage-Privilege.ps1 -StartProfile '{Profile}' -Category Safes -Action List -OutputFolder '{OutputDir}'
```

- **Pass when:**
  - The exit code is 0.
  - The output shows `Signed in as : {Username}`.
  - `Safes retrieved: N` has N > 0, and a `List Safes <date>.csv` is saved in `{OutputDir}`.
- **Fresh logon:** the run logs on again only when the saved token has expired or is older than `$script:LogonTokenMaxAgeMin` (15 minutes); the output then says `Token expired, refreshing...` or `Saved token is N minute(s) old - refreshing...`. To test the logon itself, run at least 15 minutes after the last run. Don't delete the token file: see LT-SETUP-01.
- **ISPSS:** auth is rate-limited, so don't repeat this in quick succession (K16/K17).

## Export All tests

### LT-EXPORT-01: Export All on a healthy session (F70/F71)
Needs LT-LOGON-01 to pass first. Run on both editions.

```powershell
{Shell} -File .\Manage-Privilege.ps1 -StartProfile '{Profile}' -Category Custom -Action ExportAll -OutputFolder '{OutputDir}'
```

- **Pass when:**
  - The exit code is 0, or 2 if a sub-report legitimately fails. Exit code 3 is a fail.
  - `List Reports` is not in the module list.
  - Self-Hosted: `Get Master Policy` runs. ISPSS: it doesn't run.
  - No `re-authenticating` or `token re-check failed` message appears.
  - Any failed sub-report shows a real HTTP status and CyberArk `ErrorCode`, never StatusCode 0.
- **Covers:** the F70/F71 row in `Testing_Status.md`, apart from the expired-token case.

## Accounts tests

### LT-ACCOUNTS-01: Account identifiers in a CSV (F72)
Needs LT-LOGON-01 to pass first. Read-only: `Get` reads the account and `Reconcile` runs under `-WhatIf`, which still does the lookup but sends nothing. Make `{OutputDir}\ids.csv`:

```csv
"AccountID","AccountName","ObjectName","UserName","Safe"
"{AcctID}","","","",""
"","{AcctName}","","","{AcctSafe}"
"","","{AcctName}","","{AcctSafe}"
"","","","{AcctUser}","{AcctSafe}"
"","","","{SharedUser}","{AcctSafe}"
"","{AcctUser}","","","{AcctSafe}"
```

```powershell
{Shell} -File .\Manage-Privilege.ps1 -StartProfile '{Profile}' -Category Accounts -Action Get -InputFile '{OutputDir}\ids.csv' -OutputFolder '{OutputDir}'
{Shell} -File .\Manage-Privilege.ps1 -StartProfile '{Profile}' -Category Accounts -Action Reconcile -InputFile '{OutputDir}\ids.csv' -WhatIf
```

- **Pass when** (both commands):
  - Rows 1 to 4 succeed and all resolve to `{AcctID}`.
  - Row 5 fails with "N accounts with UserName '{SharedUser}' found in safe '{AcctSafe}'".
  - Row 6 fails with "No account with AccountName '{AcctUser}' found" (a username is not an object name), unless an account's object name really is `{AcctUser}`.
  - The exit code is 2 (some rows failed). 0 or 3 is a fail.
- **Covers:** the F72 row in `Testing_Status.md`.

## Safes tests

### LT-SAFES-01: Add Safe From Template with SearchIn and the template's CPM (F74)
Needs LT-LOGON-01 to pass first. **Writes:** creates one safe, which you delete at the end.

```powershell
{Shell} -File .\Manage-Privilege.ps1 -StartProfile '{Profile}' -Category Safes -Action AddFromTemplate -OutputFolder '{OutputDir}' -InputJson '{"SafeName":"aPePAS-LT-SAFES-01","Description":"LT-SAFES-01 - delete after","ManagingCPM":"{TemplateCPM}","ExtraMembers":"User:{VaultUser}:{RoleReadOnly}:Vault;User:{LdapUser}:{RoleReadOnly}:{LdapDirectory}"}'
{Shell} -File .\Manage-Privilege.ps1 -StartProfile '{Profile}' -Category SafeMembers -Action List -OutputFolder '{OutputDir}' -InputJson '{"SafeName":"aPePAS-LT-SAFES-01"}'
{Shell} -File .\Manage-Privilege.ps1 -StartProfile '{Profile}' -Category Safes -Action Delete -InputJson '{"SafeName":"aPePAS-LT-SAFES-01"}'
```

- **Pass when:**
  - The first run exits 0 and logs "Template safe CPM '{TemplateCPM}' is in the CPM list; it will not be copied as a member".
  - The member list shows `{TemplateCPM}` once, and `{VaultUser}` and `{LdapUser}` with the `{RoleReadOnly}` role's permissions.
  - The delete exits 0, and a `Safes/Get` for the safe then returns HTTP 404.
- **Covers:** the Safes AddFromTemplate row (F74) in `Testing_Status.md`. On ISPSS the LDAP part depends on K20.

## External authentication tests

### LT-SAML-01: Interactive SAML logon (F102)
Needs SAML configured on the PVWA (web.config) and the IdP, and the WebView2 DLLs. Interactive: someone signs in at the IdP.

```powershell
{Shell} -File .\Manage-Privilege.ps1 -StartProfile '{SamlProfile}'
```

- **Pass when:**
  - The console shows `Requesting a SAML sign-in from:` and then `Opening browser for SAML login at: <IdP host>`.
  - After the IdP sign-in, the window shows "Signed in. This window closes by itself." and closes.
  - The driver shows `Signed in as : {SamlUser}`, and Safes / List works.
  - The PVWA log has no `IdP initiated SSO is disabled` line for this logon.
- **Run on:** both editions (WebView2 runs in an STA runspace on each).

### LT-LDAP-01: LDAP logon in automation mode
Needs LT-SETUP-02 run for `{LdapLogonProfile}` with `{LdapCP.Object}`, and a saved token from one interactive logon.

```powershell
{Shell} -File .\Manage-Privilege.ps1 -StartProfile '{LdapLogonProfile}' -Category Safes -Action List -OutputFolder '{OutputDir}'
```

- **Pass when:** the exit code is 0 and the output shows `Signed in as : {LdapLogonUser}`.
- **Also check:** a user outside the mapped groups is refused (PASWS013E) when signing in interactively.

### LT-USERS-01: Add and remove an allowed auth method (F100, F101)
Uses a test user, not a real one: on PVWA 14.6 the Bulk job fails for users with no expiry, so this exercises the PUT fallback.

```powershell
{Shell} -File .\Manage-Privilege.ps1 -StartProfile '{Profile}' -Category Users -Action AddAuthMethod -InputJson '{"UserID":"{AuthUserID}","AuthMethods":"{ExtMethod}"}' -OutputFolder '{OutputDir}'
{Shell} -File .\Manage-Privilege.ps1 -StartProfile '{Profile}' -Category Users -Action RemoveAuthMethod -InputJson '{"UserID":"{AuthUserID}","AuthMethods":"{ExtMethod}"}' -OutputFolder '{OutputDir}'
```

- **Pass when:**
  - Both runs exit 0 with `1 succeeded, 0 failed`.
  - The log shows either nothing about the job (it succeeded) or `Bulk job N failed: ... Falling back to PUT`, and no PASWS284E.
  - The user page in the PVWA shows `{ExtMethod}` after the add and not after the remove.
- **Put back:** if `{ExtMethod}` was on the user before, run the add again.
## Driver split tests

These check the `Driver/` split (handoff 13.4, PR #54) before it merges. Run them from the PR branch on Windows PowerShell 5.1, the runtime target; LT-SPLIT-02 also on `pwsh`. Also run LT-LOGON-01, LT-DRIVER-01 and LT-JOB-01 from the branch: together these touch every `Driver\*.ps1` part. Anything that behaves differently from `main` is a fail, even when it looks harmless.

### LT-SPLIT-01: Startup and the missing-part check
No lab needed.

- **Run:** copy `Manage-Privilege.ps1`, `Auth\`, `Modules\` and `APIModules\` (not `Driver\`) to an empty folder under `{OutputDir}` and run `{Shell} -File <that folder>\Manage-Privilege.ps1`. Then run `{Shell} -File .\Manage-Privilege.ps1` from the repo and choose `Q` at the profile list.
- **Pass when:**
  - The copy prints `Prerequisite check failed:` with nine `Driver part not found:` lines and exits 1.
  - The repo run shows the profile list (`Number / [N]ew / [K]Backup / [X]Restore / [Q]uit`) and `Q` exits 0.

### LT-SPLIT-02: Interactive connect, one List, save, exit
Needs LT-SETUP-01. Run on both editions.

- **Run:** `{Shell} -File .\Manage-Privilege.ps1`, pick `{Profile}`, choose `C` (connect), open Safes, run List, answer `y` to `Save results to CSV? [y/N]`, then go back and exit.
- **Pass when:**
  - The connect screen shows `Signed in as : {Username}`, and the category and action menus look as they do on `main`.
  - The save dialog (or its console fallback) starts in the profile's Output Folder, or in the repo root when that isn't set. It must never start in `Driver\`.
  - The CSV is written, the session logs off on exit, and the session log has no ERROR lines.

### LT-SPLIT-03: Profile edit, test connection, backup and restore dialogs
Needs LT-SETUP-01. **Touches the profile:** change one non-credential field and change it back.

- **Run:** `{Shell} -File .\Manage-Privilege.ps1`, pick `{Profile}`, then `E` (edit one field, save, edit it back), then `T` (test connection). Back at the profile list, choose `K` (backup) and save the `.zip` to `{OutputDir}`. Then choose `X` (restore) and cancel in the file dialog.
- **Pass when:**
  - The edit is saved and reverted, and the profile detail screen shows the original value.
  - Test Connection reports the same result as on `main`.
  - The backup `.zip` is written, and both the backup and restore dialogs start in the repo root, not in `Driver\`.

### LT-SPLIT-04: Interactive CSV processing
Needs LT-SPLIT-02. Read-only. Reuse `{OutputDir}\safes.csv` from LT-JOB-01 (one real safe, one that doesn't exist).

- **Run:** `{Shell} -File .\Manage-Privilege.ps1`, connect with `{Profile}`, open Safes, run Get, and pick `safes.csv` as the input file.
- **Pass when:**
  - The file picker starts in the profile's Input Folder, or in the repo root when that isn't set.
  - Row 1 succeeds and row 2 fails with a CyberArk error code.
  - `safes_<date>_output.csv` and `safes_<date>_detail.csv` are written to the profile's Output Folder, or next to the input file when that isn't set.

### LT-SPLIT-05: Inactivity timeout
Needs LT-SPLIT-02. Takes about 11 minutes.

- **Run:** connect with `{Profile}` interactively, run one List, then leave the menu untouched for more than `$script:InactivityTimeoutMin` (10) minutes, and press Enter.
- **Pass when:** the session ends with `Inactivity timeout: no API call for 10 minutes. Ending session.`, and the driver returns to the profile list or exits as it does on `main`.

## Adding a test
- Give it the next label in its group (`LT-<GROUP>-<NN>`), and never reuse or renumber a label: `Live-Testing.local.md` refers to it.
- Use placeholders for every environment-specific value. Put real values only in `Live-Testing.local.md`.
- A password placeholder, if one is ever needed in an example, is `ThisIsMy_FAKE_Password6!`.
