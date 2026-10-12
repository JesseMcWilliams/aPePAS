# aPePAS: Test Status

> **Stage: Testing.** The one place that records unit and live test status for every component, module action and cross-cutting check. The [Testing Plan](Testing_Plan.md) covers strategy, and the two checklists ([Self-Hosted](Testing_Checklist-Self-Hosted.md), [ISPSS](Testing_Checklist-ISPSS.md)) say how to run a live pass. Detail from before 2026-10-11 is in [Archive_Testing_Status-Before-Merge.md](Archive_Testing_Status-Before-Merge.md).

## How to use

- When a live run passes or fails, update the row here (status, date, one short note) and nothing else. Lab values stay in `Live-Testing.local.md`.
- A new module gets a row in its category table. A new cross-cutting check gets a row in [Cross-cutting checks](#cross-cutting-checks).
- When a row is open because it's waiting on something, list it in the [Testing backlog](#testing-backlog).
- **Unit tests:** every module has `Tests/Unit/Invoke-<Category><Action>.Tests.ps1`, except `Custom/TestApi`. Case IDs are in [Testing_Unit-Test-Cases.md](Testing_Unit-Test-Cases.md).

| Status | Meaning |
|---|---|
| **Live** _date_ | Confirmed against a live system on that date |
| **Part** | Partly confirmed live. The note says what's left |
| **Open** | Not run live yet |
| **Blocked** | Can't run in the current lab. The note says why |
| **Unit only** | Decided to stay unit-tested only. The note says who decided and why |
| n/a | No live check needed |
| — | Not supported on this system (hidden from the menu) |

Systems: **Both** = `SupportedSystems` includes ISPSS and SelfHosted; **SH** = SelfHosted only.

## Core and driver

| Component | Unit | Self-Hosted | ISPSS | Notes |
|---|---|---|---|---|
| `CyberArkLogging.psm1` | Yes | n/a | n/a | |
| `CyberArkCredentialStore.psm1` | Yes (CS01-CS08) | n/a | n/a | Pure file I/O with DPAPI |
| `CyberArkComms.psm1` | Partial (helpers, success path, thrown errors via HttpListener C44-C47) | Open | Part | 429 backoff, 504 retry and page shrink, K02 IgnoreSSL reset (A19) and the K16 hang (F66) need a live check. ISPSS: `/api/Settings/Timeout` 404 fallback confirmed |
| `Auth\CyberArk.Auth.Common.psm1` | Indirect (via the SelfHosted and ISPSS tests) | Open | Open | Token save/load round trip, certificate picker, WebView2 with a self-signed host (A07/A08) |
| `Auth\CyberArk.Auth.SelfHosted.psm1` | Partial (SH-NP01-04, SH-SSL01-04) | Part | — | `CyberArk` method live (LT-LOGON-01, 2026-09-25). The other 7 methods (A01-A18) are open |
| `Auth\CyberArk.Auth.ISPSS.psm1` | Partial (ISPSS-CC01-06, ISPSS-INT01-05, K17-01-07) | — | Part | `Interactive` live 2026-09-21 (K12/F62). Open: SSO, ClientCredentials, silent refresh mid-run, K17 throttle (AI01-AI12) |
| Driver: profile CRUD | Yes | n/a | n/a | |
| Driver: profile backup/restore (D26-D30) | Partial (repro script, F51) | Open | Open | |
| Driver: `-StartProfile`/`-AutoConnect` (D31-D36) | Partial (AM11-AM14) | Open | Open | |
| Driver: session loop, keepalive, refresh (D01-D25) | Partial (AM08-AM10, AM15-AM18) | Open | Open | ISPSS: one full session like D25 (see the ISPSS checklist) |
| Driver: automation mode (D37-D40) | Partial | **Live** 2026-09-21 | Part | SH: many `-Category`/`-Action` runs, sequential runs on one session (K15). ISPSS: read-only pass 2026-09-21 |
| Driver: `-OutputFolder`/`-FilenameFormat` (D41) | Yes | Open | Open | Single file and Export All. F98: RetrieveSshKey, Platforms Export and Reports Export now honor it too (Platforms Export live 2026-10-11) |
| Driver: date-free Custom export filenames (D42) | Yes | Open | Open | The 4 non-ExportAll Custom exports |
| Driver: stored `.autocred` fallback (D43, K06) | Yes (AM41-AM50, AM71-AM76) | Open | Open | |
| Driver: Base URL staleness (D44, K04) | Yes (AM52-AM63) | Open | Open | |
| Driver: profile Username fallback in refresh (D45, K07) | Partial | Open | — | SelfHosted branch only |
| Driver: `WebView2AssemblyPath` (D46, K11) | Yes (AM66-AM68) | Open | Open | |
| Driver: `-Credential` | Yes (AM88-AM97) | **Live** 2026-10-10 | Open | LT-DRIVER-01 |
| Driver: inactivity timeout; `-InputFile` skipped files exit 3 | Yes (AM98-AM102, C63-C65) | Open | Open | |
| Driver: job files and the detail CSV | Yes (AM103-AM110, IW11) | **Live** 2026-10-10 | Open | LT-JOB-01 |
| Driver: `Driver\*.ps1` split (PR #54, handoff 13.4) | Yes (whole suite; AST comparison per move) | Open | Open | LT-SPLIT-01 to 05, plus LT-LOGON-01, LT-DRIVER-01 and LT-JOB-01 run from the branch. Required before merge |
| `Invoke-AutomationWithCredential.ps1` | Yes (IW01-IW10) | **Live** 2026-10-10 | Open | LT-DRIVER-01. ISPSS: ClientCredentials and Interactive without MFA |
| ISPSS profile setup and identity discovery (AI07/AI08) | — | — | Open | |
| ISPSS menu hides Self-Hosted-only actions (D18) | — | — | Open | Rename, SetMasterPolicy, Reports, Users write actions, Dependents and Discovered |

## Module actions

### Accounts

| Action | Systems | Self-Hosted | ISPSS | Notes |
|---|---|---|---|---|
| Add | Both | **Live** 2026-09-21 | Open | |
| AddDependent | SH | **Live** 2026-10-11 | — | 201 on master 49_3. A platform that doesn't fit the master gets 400 PASWS366E |
| CancelCpmTask | Both | Open | Open | Needs a pending CPM task. The pre-15.2 404 fallback (F14) is unverified |
| ChangeImmediate | Both | **Live** 2026-09-21 | Open | Activities showed `ResetImmediately` = ChangeTask |
| ChangeInVault | Both | **Live** 2026-09-21 | Open | Stores the password without setting `ResetImmediately` (F12). DEBUG log masking not checked live |
| CheckIn | Both | **Live** 2026-10-11 | Open | On the SSH key account right after RetrieveSshKey |
| Delete | Both | **Live** 2026-09-21 | Open | K21 v1 fallback on PASWS056E (AD17-AD20) confirmed live 2026-10-11 on SSH key accounts 30_26 and 30_27 (two rounds). ISPSS: fallback untried |
| DeleteDependent | SH | **Live** 2026-10-11 | — | 204 |
| DeleteDiscovered | SH | Blocked | — | Needs a pending discovered account (the lab's Pending list was empty 2026-10-11) |
| Get | Both | **Live** 2026-09-21 | Open | |
| GetActivity | Both | **Live** 2026-09-21 | Open | |
| GetCredential | Both | Open | Open | Deferred 2026-09-21: returns a live password |
| GetDependent | SH | **Live** 2026-10-11 | — | |
| GetDiscovered | SH | Part | — | Error path only: a made-up ID gave 400 PASWS168E (2026-10-11). Needs a pending account |
| LinkAccount | Both | **Live** 2026-09-04 | Open | F41 |
| List | Both | **Live** 2026-09-21 | **Live** 2026-09-21 | SH: 2440 accounts, By-Safe over 35 safes. ISPSS: the By-Safe mode and the ~20K cap weren't checked |
| ListAllDependents | SH | **Live** 2026-10-11 | — | `platformId` and quoted `SafeName` filters work; master-account filters get 400 PASWS357E |
| ListDependents | SH | **Live** 2026-10-11 | — | |
| ListDiscovered | SH | Part | — | Endpoint returned 200 with an empty Pending list (2026-10-11) |
| ListOnboardingPlatforms | SH | **Live** 2026-10-11 | — | 15 platforms |
| OnboardDiscovered | SH | Blocked | — | Needs a pending discovered account |
| Reconcile | Both | **Live** 2026-09-21 | Open | `ResetImmediately` = ReconcileTask |
| RequestJitAccess | Both | Part | Open | 2026-10-10: 403 PASWS211E for a Vault (non-LDAP) caller. A grant needs an LDAP-user profile and a platform that allows ad hoc access |
| ResumeAutoManagement | Both | Open | Open | `POST .../Resume/`; the pre-15.2 fallback is unverified. The ISPSS path was never confirmed |
| ResumeDependent | SH | **Live** 2026-10-11 | — | Disposable SchedTask dependent: AutoManaged False to True, reason cleared |
| RetrieveSshKey | Both | **Live** 2026-10-11 | Open | Throwaway key on a disposable `UnixSSHKeys` account: same key (trailing newline dropped; `ssh-keygen` reads it), no BOM, not in the log or CSV. A Reason/ticket platform wasn't tried. F98 (saves to the step's OutputFolder) is unit-tested here; Platforms Export confirmed it live |
| RevokeJitAccess | Both | Part | Open | 2026-10-10: 403 PASWS293E for a non-LDAP caller |
| SyncDependent | SH | **Live** 2026-10-11 | — | Accepted for a disposable dependent with a task name that doesn't exist; deleted before the CPM reported a result |
| UnlinkAccount | Both | **Live** 2026-09-04 | Open | F41 |
| Unlock | Both | Open | Open | Needs a locked account |
| Update | Both | **Live** 2026-09-21 | Open | JSON Patch of `Address` |
| UpdateDependent | SH | **Live** 2026-10-11 | — | Blank fields keep their values |
| Verify | Both | **Live** 2026-09-21 | Open | `ResetImmediately` = VerifyTask |

### Applications

| Action | Systems | Self-Hosted | ISPSS | Notes |
|---|---|---|---|---|
| Add | Both | **Live** 2026-09-21 | Part | ISPSS: menu visibility only (2026-09-02). F45 validation is unit-tested only |
| AddAuthMethod | Both | **Live** 2026-10-06 | Open | `osUser` 2026-09-21; `certificateattr` 2026-10-06. An `RFC822 Name=` SAN entry isn't live-checked |
| Delete | Both | **Live** 2026-09-21 | Open | |
| DeleteAuthMethod | Both | **Live** 2026-09-21 | Open | The picker's `certificateattr` columns aren't live-checked |
| Get | Both | **Live** 2026-09-21 | Open | |
| List | Both | **Live** 2026-09-02 | **Live** 2026-09-21 | F01 routing fix. ISPSS: 2 applications |
| ListAuthMethods | Both | **Live** 2026-09-21 | **Live** 2026-09-21 | SH: blank AppID listed 8 methods across 4 applications. ISPSS: blank AppID not checked. `certificateattr` columns not live-checked |

### Custom

| Action | Systems | Self-Hosted | ISPSS | Notes |
|---|---|---|---|---|
| ExportAll | Both | **Live** 2026-09-21 | **Live** 2026-09-21 | 9 and 8 sub-modules. Open on both: `-OutputFolder` (F54) and the F70/F71 checks below |
| ExportEntitlements | Both | **Live** 2026-09-21 | **Live** 2026-09-21 | SH 35 safes / 117 members; ISPSS 29 / 114 |
| ExportGroupMembersLDAP | Both | Blocked | Open | ADSI-based: needs line of sight to AD from the test machine |
| ExportGroupMembersLocal | Both | **Live** 2026-09-21 | Open | ISPSS: check the `@` heuristic for the GroupType quirk |
| ExportPlatformDetails | Both | **Live** 2026-09-21 | **Live** 2026-09-21 | The OtherFiles / META-INF exclusion is unit-tested only (no example in the lab) |
| TestApi | Both | Open | Open | No unit test file. Manual smoke test, including F15 (IgnoreSSL and a token that expires mid-session) |
| TestConnectivity | Both | Part | Open | Linux via plink live (F23, F26-F29). Open: Windows SMB, vault-backed lookup columns (F22), `AdditionalPorts` (F52), F86 |

### Groups

| Action | Systems | Self-Hosted | ISPSS | Notes |
|---|---|---|---|---|
| Add | Both | **Live** 2026-09-21 | Open | |
| AddMember | Both | **Live** 2026-09-04 | Open | F42: `memberId` is the username |
| Delete | Both | **Live** 2026-09-21 | Open | |
| GetMembers | Both | **Live** 2026-09-04 | Open | F43 |
| List | Both | **Live** 2026-09-21 | **Live** 2026-09-21 | The GroupType filter is unusable on ISPSS (expected, see the ISPSS checklist) |
| RemoveMember | Both | **Live** 2026-09-04 | Open | |
| Update | Both | **Live** 2026-09-21 | Open | |

### Platforms

| Action | Systems | Self-Hosted | ISPSS | Notes |
|---|---|---|---|---|
| Copy | Both | **Live** 2026-09-21 | Open | Copied to a disposable platform |
| Disable | Both | **Live** 2026-09-21 | Open | |
| Enable | Both | **Live** 2026-09-21 | Open | |
| Export | Both | Part | Part | The `PlatformID` variant is live on both (SH 2026-09-04, ISPSS 2026-09-21). The other 3 ID types are unit-tested only |
| Get | Both | **Live** 2026-09-21 | Open | ISPSS: check the field shape (`id` vs `PlatformID`) |
| Import | Both | Open | Open | The ZIP-as-byte-array request shape is unverified. Needs an export ZIP |
| List | Both | **Live** 2026-09-21 | **Live** 2026-09-21 | The `PlatformType` filter isn't live-checked on either |
| Remove | Both | **Live** 2026-09-21 | Open | Disposable platform only |
| Rename | SH | Blocked | — | Needs PVWA 15.0+. The lab returned 405 (2026-09-21) |
| SetPSMConfig | Both | Blocked | Open | No PSM server ID in the lab |

### Policies

| Action | Systems | Self-Hosted | ISPSS | Notes |
|---|---|---|---|---|
| GetMasterPolicy | Both | **Live** 2026-09-04 | **Live** 2026-09-21 | ISPSS has no such endpoint: a clean 404 Failure (F40). `ExportAllSystems` keeps it out of Export All on ISPSS |
| SetMasterPolicy | SH | Unit only | — | User's decision 2026-09-21: it changes tenant-wide settings |

### Reports

| Action | Systems | Self-Hosted | ISPSS | Notes |
|---|---|---|---|---|
| Export | SH | Open | — | Needs a user with Reports access and a generated report |
| List | SH | Part | — | Live 2026-09-02. The automation user got 403 on 2026-09-21. The F91 columns (14.6 shape) aren't live-checked |

### SafeMembers

| Action | Systems | Self-Hosted | ISPSS | Notes |
|---|---|---|---|---|
| Add | Both | **Live** 2026-10-10 | Open | Direct role 2026-09-21; F93 date 2026-10-10. SearchIn picker (F76) and F47 presets open |
| AddFromTemplateRole | Both | Open | Open | The lab's template safe and role groups exist since 2026-10-09 |
| List | Both | **Live** 2026-10-09 | Open | F78 predefined users 2026-10-09. MemberType / MembershipExpired / Sort filters open |
| Remove | Both | **Live** 2026-09-21 | Open | |
| Update | Both | **Live** 2026-10-10 | Open | Role change 2026-09-21; F85/F93 expiration rules 2026-10-10 |
| UpdateFromTemplateRole | Both | Open | Open | |

### Safes

| Action | Systems | Self-Hosted | ISPSS | Notes |
|---|---|---|---|---|
| Add | Both | **Live** 2026-09-21 | Open | The `Get-CpmOptions` fallback to CPM_List wasn't exercised |
| AddFromTemplate | Both | **Live** 2026-10-09 | Open | LT-SAFES-01 (F74) |
| AssignCPM | Both | **Live** 2026-09-21 | Open | Direct assignment only. ISPSS: check the CPM user query |
| Delete | Both | **Live** 2026-09-21 | Open | |
| Get | Both | **Live** 2026-09-21 | Open | |
| List | Both | **Live** 2026-09-21 | **Live** 2026-09-21 | SH 35 safes; ISPSS 29 |
| UnassignCPM | Both | Open | Open | Ticked on 2026-09-21 because AssignCPM is symmetric, but not run itself |
| Update | Both | **Live** 2026-10-09 | Open | Description 2026-09-21; AutoPurgeEnabled ignored on update (F77) 2026-10-09 |

### Users

| Action | Systems | Self-Hosted | ISPSS | Notes |
|---|---|---|---|---|
| Add | SH | **Live** 2026-10-10 | — | The Vault needs an `InitialPassword` (PASWS260E without one) |
| AddAuthMethod | SH | Unit only | — | User's decision 2026-10-11: the lab has no external non-Vault method; `radius` and `LDAP` got PASWS347E |
| Delete | Both | **Live** 2026-10-10 | Open | |
| Disable | SH | **Live** 2026-10-10 | — | The 404 fallback wasn't exercised |
| Enable | SH | **Live** 2026-10-10 | — | The 404 fallback wasn't exercised |
| Get | Both | **Live** 2026-10-10 | Open | F94/F96 columns |
| List | Both | **Live** 2026-10-10 | **Live** 2026-09-21 | F95 paging at page size 5 |
| RemoveAuthMethod | SH | Unit only | — | Same decision and reason as AddAuthMethod |
| ResetPassword | Both | **Live** 2026-10-10 | Open | ISPSS: Vault-local users only |
| Unblock | Both | Part | Open | 2026-10-10 on a user that wasn't suspended |
| Update | SH | **Live** 2026-10-10 | — | Blank fields keep their values |

## Cross-cutting checks

| Check | Self-Hosted | ISPSS | Notes |
|---|---|---|---|
| Safe name with a space in `filter=safeName eq` | **Live** 2026-10-09 | Open | LT-ACCOUNTS-01 in a space-named safe. List By-Safe over such a safe wasn't checked separately |
| Account identifiers (F72, LT-ACCOUNTS-01) | **Live** 2026-10-09 | Open | PS 5.1 and PS 7 |
| SearchIn picker (F76/K20) | Open | Open | Lists LDAP directories after Vault; ISPSS shows GUIDs |
| F85 role vs. permission columns, full CSV template | Part | Open | Expiration rules live 2026-10-10 |
| F93 ExpirationDate as Unix seconds | **Live** 2026-10-10 | Open | AddFromTemplateRole and UpdateFromTemplateRole not live |
| F47 permission presets (`ReadOnlyStrict` etc.) | Open | Open | |
| F44 SafeName validation | Open | Open | Must not reject a valid name |
| F70/F71 Export All failure and expiry handling | Open | Open | PS 7 and PS 5.1 |
| F86 TestConnectivity `Note` and `Safe` | Open | Open | |
| F98 a job step's OutputFolder for RetrieveSshKey, Platforms Export, Reports Export | Part | Open | Platforms Export live 2026-10-11: the ZIP landed in the step folder with its CSV. The other two are unit-tested only |
| CSV template generation | Open | Open | Every module with CSV input |
| List drill-down to Get | Open | Open | |
| WhatIf suppresses every write action | Open | Open | |
| No secrets in the log at any level (F02) | Open | Open | |
| One-row List renders (F13) | Open | Open | |
| Entity search with a period (F21, `%2E`) | Open | Open | |
| K17 `RetryWaitingTime` throttle | — | Open | |

## Testing backlog

Open live tests that are waiting on something. Remove an entry when its row above changes.

1. **ISPSS pass:** nearly every ISPSS cell is Open. Start with LT-SETUP-01/02 and LT-LOGON-01 for the ISPSS profile, then LT-ACCOUNTS-01 (see `Live-Testing.local.md`). Mind the auth rate limit (K16/K17).
2. **Needs a lab object or setup:** a pending discovered account (Get/Onboard/DeleteDiscovered); an LDAP-user profile and an ad hoc access platform (JIT grant); a locked account (Unlock) and a pending CPM task (CancelCpmTask); AD line of sight (ExportGroupMembersLDAP); a PSM server ID (SetPSMConfig); a user with Reports access (Reports Export, List); PVWA 15.0+ (Rename).
3. **Ready to run on Self-Hosted:** AddFromTemplateRole, UpdateFromTemplateRole, UnassignCPM, ResumeAutoManagement, GetCredential, Import (after an Export), the SafeMembers List filters, Platforms List `PlatformType`, LT-EXPORT-01, and the cross-cutting checks above.
4. **Unit only, by decision:** Users AddAuthMethod and RemoveAuthMethod (2026-10-11, no external auth method in the lab); Policies SetMasterPolicy (2026-09-21, tenant-wide change). Reopen one if the lab gains what it needs.
5. **Not yet defined as `LT-*`:** the ad-hoc runs recorded as "(unlabeled)" in `Live-Testing.local.md` (2026-10-10 and 2026-10-11).
6. **Before PR #54 merges (driver split):** LT-SPLIT-01 to 05, plus LT-LOGON-01, LT-DRIVER-01 and LT-JOB-01, from the PR branch on PS 5.1 (LT-SPLIT-02 also on pwsh).
