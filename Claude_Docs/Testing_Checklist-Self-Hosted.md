# aPePAS: Self-Hosted Full Functional Checklist

> **Stage: Testing.** How to run a live pass against Self-Hosted PVWA. Status lives in [Testing_Status.md](Testing_Status.md), not here.

## Self-Hosted Live Pass

This is the guide for the live functional pass against `https://pvwa.company.com`
(or whichever Self-Hosted lab host is in use). [Testing_Status.md](Testing_Status.md) lists every module action.
For each, run it at least once against the live host with realistic input (including at least one
CSV-batch run where the module supports one), confirm the result matches what's actually in the
Vault/PVWA (not just that the tool reported success), and note the PVWA version under test — see
the caution section in [Testing_Plan.md](Testing_Plan.md) for why version matters for Platforms/SafeMembers field-shape
differences.

Use a **dedicated test Safe and test accounts** for every write action (Add/Update/Delete/Change/
Reconcile/etc.) — never point a write action at production data.

### Where things are
- **Status** of every action and check: [Testing_Status.md](Testing_Status.md). Update it there after each run; this file holds no status.
- **Auth** procedures A01-A19 and **driver** procedures D01-D46: [Testing_Manual-Integration-Procedures.md](Testing_Manual-Integration-Procedures.md).
- **Repeatable labeled tests** (`LT-*`): [Testing_Live-Test-Definitions.md](Testing_Live-Test-Definitions.md), with lab values in `Live-Testing.local.md`.
- Run write actions as a job file through `Invoke-AutomationWithCredential.ps1` on PS 5.1, one `OutputFolder` per step, and delete what you created in the last step.

### What to check for the open items
- **Dependents** Sync / Resume: the CPM acts on the machine behind the master; use a disposable master or one the user names.
- **Discovered accounts:** run a discovery scan (or add one to the Pending list) first, then Get it, Onboard one with `ShouldReconcileAccount` blank, and Delete another.
- **RetrieveSshKey** (PVWA 11.5): on an SSH key account, the `.key` file in the Output Folder opens in an SSH client, and the log and results CSV hold only the path. Also try a platform that requires a Reason or ticket.
- **RequestJitAccess / RevokeJitAccess:** needs a profile that logs on as an LDAP user and a Windows account on a platform that allows ad hoc access. The user lands in local Administrators, then Revoke removes it.
- **CancelCpmTask / ResumeAutoManagement:** the pre-15.2 404 fallback (F14) needs a host older than 15.2.
- **Safe name with a space:** `List` By-Safe needs at least one accessible safe whose name has a space.
- **SearchIn picker (F76):** in interactive Add Safe Member, Add Safe Member From Template Role and Add Safe From Template, the picker lists the lab's LDAP directory after Vault (from `/api/settings/AddSafeMember`, or GetDirectoryServices on 404), and a member added with it succeeds. DEBUG lines show which source answered.
- **List Safe Members filters:** `MemberType` = Group returns only groups, `MembershipExpired` = true/false splits expired and current members, `Sort` = desc reverses the name order, and no HTTP 400 retry appears in the log.
- **F85, full CSV template** (every permission column present): Add and Update with a `PermissionRole` use the preset; with it blank, the filled columns apply. Update: blank columns and a blank `ExpirationDate` keep current values, `None` removes the expiration, and a row with only `ExpirationDate` changes only that. Add: a row with no role and no permission values fails. UpdateFromTemplateRole: a blank `ExpirationDate` keeps it.
- **Platforms:** Import needs a ZIP from Export; `PlatformType` = Group, then Regular; Rename needs PVWA 15.0+; SetPSMConfig needs a real PSM server ID.
- **Policies / SetMasterPolicy** (only if the user reopens it): dedicated lab host only; check `ConfirmersNumber` 1-64, `PasswordChangeDays`/`PasswordVerificationDays` 1-3650, `RetentionPeriod` 0-3650.
- **Reports:** List shows `Safe`, `Location`, `FileName`, `Status` and `CreatedAt` (F91). Export by `ReportName` as Excel and as CSV opens correctly; no match and two matches both fail cleanly; by `ReportID` only if an ID can be found; WhatIf saves nothing. The user needs Reports access.
- **Users AuthMethod** (only if the lab gains an external method): use an ID from `/api/Configuration/AuthenticationMethods`; LDAP and RADIUS are rejected (PASWS347E). Username resolution with a username that's ambiguous in `?search=` must fail the row.
- **Custom:** TestApi with `IgnoreSSL` and a token that expires mid-session (F15); TestConnectivity against a Windows target (SMB on 445), a vault-backed lookup filling `Safe`/`Username`/`PasswordSource` (F22), `AdditionalPorts` (F52), and with Password blank, several matches give a `Note` with the count and safe, `Safe` set searches only that safe (F86).
- **Driver:** F70/F71 on PS 7 and PS 5.1 (Export All skips Reports/List and runs Master Policy; a failed sub-report is a Failed row with its ErrorCode and the run continues; with the token revoked mid-run, the run stops at the first 401 and re-authenticates); CSV templates; List drill-down; WhatIf across every write action; no secrets in the log (F02); a one-row List (F13); `Invoke-EntitySearch` with a period in the term (F21).
