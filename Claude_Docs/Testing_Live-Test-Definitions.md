# aPePAS: Live Test Definitions

> **Stage: Testing.** Repeatable live tests against a real PVWA or ISPSS tenant, each with a short label. This file is tracked, so it holds **no lab details**: every environment-specific value is a `{Placeholder}`. The gitignored `Live-Testing.local.md` supplies the values for each environment and lists which labels to run. Live tests run only when asked (see CLAUDE.md, "Live testing").

## How to use
1. Pick a label below and an environment from `Live-Testing.local.md`.
2. Replace each `{Placeholder}` with that environment's value. `{Shell}` is `powershell.exe` (Windows PowerShell 5.1, the runtime target) or `pwsh` (PowerShell 7). Run both when a test says "both editions".
3. Run the command from the repo root, and check every "Pass when" item.
4. Record the result (date, edition, pass/fail) in the matching `Testing_Checklist-*.md` row.

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
- **Covers:** the F70/F71 rows in `Testing_Checklist-Self-Hosted.md` and `Testing_Checklist-ISPSS.md`, apart from the expired-token case.

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
- **Covers:** the F72 rows in `Testing_Checklist-Self-Hosted.md` and `Testing_Checklist-ISPSS.md`.

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
- **Covers:** the F74 rows in `Testing_Checklist-Self-Hosted.md` and `Testing_Checklist-ISPSS.md`. On ISPSS the LDAP part depends on K20.

## Adding a test
- Give it the next label in its group (`LT-<GROUP>-<NN>`), and never reuse or renumber a label: `Live-Testing.local.md` refers to it.
- Use placeholders for every environment-specific value. Put real values only in `Live-Testing.local.md`.
- A password placeholder, if one is ever needed in an example, is `ThisIsMy_FAKE_Password6!`.
