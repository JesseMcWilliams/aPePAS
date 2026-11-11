# aPePAS: Feature Requests (from 2026-11-11)

> **Stage: Planning.** None of this is built yet. Item numbers match the user's request list. Keep them stable. When an item is built, move its design into a `Design_` doc (or the module's own metadata and tests), record it as the CLAUDE.md docs table says, and delete it here.

Sources: the API facts below come from the local Idira docs (`C:\Code\References\Idira_Documents`), the PVWA 14.6 Swagger in `Swagger/`, and the current code. Anything marked **(unconfirmed)** has no local source and must be probed live with Custom/TestApi before it's coded. psPAS 8.0.20 is in `C:\Code\References\pspas.8.0.20` (restored 2026-11-11) and wasn't searched for this plan; check it before each item's probe.

Abbreviations: SH = Self-Hosted, ISPSS = Privilege Cloud on the Shared Services platform.

## 1. Summary

| # | Request | Systems | What exists now | Proposed work | Size | Phase |
|---|---|---|---|---|---|---|
| 1 | Set the account "Network" for accounts with an IP address | ISPSS | Nothing | New `Accounts SetNetwork` (plus Get/Clear) | M | 3 |
| 2 | Enable service account login | ISPSS | Nothing (ISPSS auth only) | Depends on what it means. See Q2 | M-L | 3 |
| 3 | Generate reports with automation | ISPSS (and SH) | Reports List/Export, SH only, already run in automation mode | Probe ISPSS; add report-task creation | S-M | 2 |
| 4 | Reconcile and Verify resume CPM-disabled accounts | Both | Reconcile/Verify don't check; Resume Auto Management exists | `ResumeIfDisabled` option on Reconcile, Verify and Change | S | 1 |
| 5 | Get the "reset immediately" (pending task) status | Both | List/Get show `CPMStatus`, dates only | **Built 2026-11-11** (proposals 1-2, PR #71; LT-ACCOUNTS-02 passed on SH; 3 not done) | S | 1 |
| 6 | Reliably find the reconcile account linked to an account | Both | Link/Unlink exist; nothing reads links | Probe for a read endpoint first | S-M | 1 (probe) |
| 7 | Report: a user's access, and the groups needed to match it | Both (SH first) | Export Entitlements (all safe members) | New `Custom ExportUserAccess` | M | 2 |
| 8 | Verify credential pull works under Task Scheduler | Both | Documented, never tested under Task Scheduler | Live test + doc notes | S | 1 |
| 9 | Resume all, or a subset of, CPM-disabled accounts | Both | Resume by ID/name or CSV only | Filter-driven bulk resume | S | 1 |
| 10 | Remove or deactivate users not logged on for N days | SH (ISPSS: see Q10) | Users List has no last-login field; Disable/Delete take a CSV | `LastLogin` column + `InactiveDays` filter on Users List | S-M | 1 |
| 11 | Bulk update of vaulted account passwords | Both | Change in Vault already works from a CSV | Add Set Next Password; document the CSV route | S | 1 |
| 12 | Nested group members with path, across domains | Both | LDAP/Local exports already expand nesting with a path; one domain per run | Multi-domain support | M | 2 |
| 13 | Snapshot and compare CP and health state before/after upgrades | SH (ISPSS: see Q13) | Nothing | New `Custom ExportHealthSnapshot` + offline compare | M | 2 |
| 14 | Users and groups common to safes | Both | Export Entitlements, Count-AccountsPerSafe | New `Custom ExportSafeMemberOverlap` menu action | S-M | 2 |
| 15 | Manage the other Shared Services (Identity, Connector Management, ...) | SaaS | Privilege Cloud only; ISPSS auth already gets a platform token | Self-Hosted/SaaS target, service menu, per-service URLs | L | 3 |

The old `Planning_Feature-Requests.txt` held one entry, "Export Profiles / Backup". It's already built (the profile menu's [K] Backup and [X] Restore), so that file was removed.

## 2. Phases

1. **Phase 1, small extensions to existing modules (Both):** 4, 5, 9, 11, 10, then the probes for 6 and the Task Scheduler test (8). These share one piece of new plumbing: a `SavedFilter` input on Accounts List.
2. **Phase 2, reports and analysis:** 7, 14, 12, 13, 3. Items 7 and 14 share the safe-member collection code from Export Entitlements.
3. **Phase 3, ISPSS-only platform services:** 1 and 2. They call services outside the Privilege Cloud base URL, so they need a design check on how `Invoke-CyberArkAPI` builds URLs for other ISPSS services.

Each item is its own branch and PR, following the "New Module Checklist" in `Reference_API-Module-Guide.md`.

## 3. Item details

### 1. Account Network (ISPSS only)
- **What it is:** an ISPSS account property: the Connector Management network linked to a connector pool, which picks the connectors that rotate the account. Automatic matching uses the FQDN only, so accounts with an IP address need the network set by hand (`privcloud-accounts-view-details.md`, `account-properties.md`).
- **API (documented):** `GET`, `POST` (`{"networkId":"..."}`) and `DELETE` on `/API/accounts/{account-id}/network` (`privcloud-account-network*.md`). Whether it lives under the Gen 2 base (`/PasswordVault/API`) or Gen 3 (`/api`) must be checked live.
- **Listing networks:** the docs link to a Connector Management "List Networks API" (base `https://<sub>.connectormanagement.cyberark.cloud/api`) whose page isn't in the local copy **(endpoint unconfirmed)**.
- **Proposal:**
  1. `Accounts GetNetwork` and `Accounts SetNetwork` (CSV: AccountID or Name+Safe, plus NetworkName or NetworkID), SupportedSystems ISPSS.
  2. A `-OnlyIpAddress` style option that picks accounts whose `address` parses as an IPv4/IPv6 address, so a run can target "every IP-addressed account in safe X".
  3. Resolving a NetworkName to an ID needs the CM list endpoint. Until that's confirmed, accept NetworkID only.

### 2. Enable service account login (ISPSS)
- What this means is open (Q2). The candidates the docs support:
  1. Identity **"Is Service User"** flag: service users can't log on to the User Portal. API: `POST /CDirectoryService/ChangeUser` with a `ServiceUser` boolean (cloud users only).
  2. Identity user state: `POST /CDirectoryService/SetUserState` (None, Locked, Disabled, Expired) or `ChangeUserState` (Active/Suspended).
  3. "Is OAuth confidential client" (what aPePAS automation logs on with): no API field to set it was found **(unconfirmed)**.
- Any of these needs calls to the Identity tenant (`https://<tenant>.id.cyberark.cloud`), which aPePAS only uses for auth today. That's a new "Identity" API surface and gets a short design note first.

### 3. Reports with automation
- SH: Reports List/Export already run in automation mode (14.6+). The documented `GET/POST /API/Tasks` (type `Report`) would let a job *generate* a fresh report, not just download the last run; the valid `subType` values aren't documented **(unconfirmed)**.
- ISPSS: the Reports UI exists (reports go to the `PVWAReports` safe), but the Reports/Tasks API isn't in the ISPSS docs. Reports List already gets a 404 on ISPSS.
- **Proposal:**
  1. Probe `/API/Reports`, `/API/Tasks` and `/API/ClassicReports` on ISPSS with TestApi.
  2. If they all 404, the fallback is aPePAS-built reports (items 7, 14, Export All) run from job files, plus retrieving the saved report files from the `PVWAReports` safe, if the API allows that.
  3. Add `Reports CreateTask` on SH only if a probe shows which subTypes work.

### 4. Reconcile/Verify resume CPM-disabled accounts
- **Built 2026-11-11** (branch `2026-11-11-resume-if-disabled`): `ResumeIfDisabled` on Reconcile, Verify and Change Immediate, using three new `CyberArkComms.psm1` helpers (see `Reference_API-Module-Shared-Helpers.md`). Resume Auto Management now uses the shared resume call too. LT-ACCOUNTS-03 passed on Self-Hosted 2026-11-11 (PR #72). Finding: on 14.6 a manual Verify or Reconcile re-enables a CPM-disabled account by itself (CyberArk-Accounts lessons §7); the option was kept by the user's decision for Change, ISPSS and other versions.
- Today Reconcile and Verify (`Invoke-AccountsReconcile.ps1:152`, `Invoke-AccountsVerify.ps1:152`) don't check `secretManagement.automaticManagementEnabled`.
- **Proposal:** a `ResumeIfDisabled` (Yes/No, default No) input on Reconcile, Verify and Change Immediate. When it's Yes and the account is disabled, call the Resume Auto Management logic first (SH `POST /Resume/` with the existing 404 → PATCH fallback; ISPSS PATCH), then run the action. Record `Resumed = True` in the result.
- Move the resume call into a shared helper (in `CyberArkComms.psm1` or `Reference_API-Module-Shared-Helpers.md`'s home) so item 9 uses the same code.
- **Live check needed:** the REST `ErrorCode` returned when you reconcile a disabled account isn't documented (the UI message is EPVPA007E). Record it in the lessons file.
- Should accounts disabled **by a user** (manual reason set) be resumed too, or only those disabled **by the CPM**? See Q4.

### 5. "Reset immediately" / pending task status
- v2 has no "immediate task pending" field. What it has (Swagger, SH/ISPSS docs):
  1. `secretManagement.status`: values differ between sources (`inProcess`, `success`/`succeeded`, `failure`/`failed`, `partiallySucceeded`), so match case-insensitively and pass unknown values through.
  2. `savedFilter` on `GET /API/Accounts`: `ScheduledForChange`, `ScheduledForVerify`, `ScheduledForReconcile`, `FailedChange`, `FailedVerify`, `FailedReconcile`, `DisabledPasswordByUser`, `DisabledPasswordByCPM`, `PolicyFailures` and others.
  3. Fields like `ImmediateCPMTask`, `CPMStatus` and `LastTask` are documented only inside the Requests API's AccountDetails.
- **Proposal:**
  1. Add a `SavedFilter` input to Accounts List (menu of the documented values), combinable with Safe/Search. The ISPSS `filter` accepts AND only.
  2. Show `LastCPMModified`, `LastReconciled` and `LastVerified` with the time, not just the date (or add a full-timestamp column, to avoid changing existing CSV consumers).
  3. Optionally add `Accounts GetActivity` columns for the last CPM action. Its path differs between SH (`/PasswordVault/WebServices/PIMServices.svc/Accounts/{id}/Activities/`) and ISPSS (`/PasswordVault/API/Accounts/{id}/Activities/`).
- **Built 2026-11-11:** proposal 1 in Normal and By-Safe modes. Values come from the shared `Get-CyberArkAccountSavedFilterList` / `Resolve-CyberArkAccountSavedFilter` in `CyberArkComms.psm1`, matched in any case; an unknown value fails before any call (user's choice). Proposal 2: the three columns changed in place to `yyyy-MM-dd HH:mm` on List and Get (user's choice). Proposal 3 is not done.

### 6. Find the linked reconcile account
- Writing links is supported on both (`POST/DELETE /API/Accounts/{id}/LinkAccount`). **No documented endpoint reads an account's linked accounts**: v2 GET Accounts doesn't return them, and the 14.6 Swagger has no ExtendedAccounts/LinkedAccounts path.
- The PVWA UI shows them, so some endpoint returns them **(unconfirmed)**. Steps:
  1. Probe live with TestApi on both systems: the UI's account details call (capture it from the browser's developer tools while opening an account) and the `savedFilter=Link` value, whose meaning isn't documented.
  2. If a stable endpoint turns up, add `LinkedLogon`/`LinkedReconcile` columns to Accounts Get (opt-in, because it's one extra call per account).
  3. If not, record the gap in Known Issues and suggest the Classic report route instead.
- Get the user to confirm what "only platform assigned are showing up" refers to (which screen or report). See Q6.

### 7. User access report and the groups needed to match
- **Input:** a target user (and optionally a "model" user to compare with).
- **Data (SH, Swagger-confirmed):** `GET /API/Users/{id}` returns `groupsMembership`. Safe members come from the code Export Entitlements already uses. The output joins the two.
- **Output CSV:** per safe: Safe, AccessVia (Direct or the group name), the permission flags, and for a comparison: `ModelHas`, `TargetHas`, `Gap`, `GroupsThatWouldGrant` (groups that are members of that safe with at least the model's permissions).
- ISPSS: the UserGroups/Users APIs aren't in the ISPSS doc set, and Identity/LDAP groups are resolved outside the vault. Build SH first; check ISPSS live (Q7).
- LDAP group membership isn't visible through the vault API. Optionally reuse item 12's AD lookup to expand it.

### 8. Credential pull under Task Scheduler
- The `.autocred` file and session token use DPAPI (`CyberArkCredentialStore.psm1`), so the task must run as the Windows account that created them. The User Guide has a Task Scheduler example but it has never been tested that way.
- **Proposal:** a new live test `LT-SCHED-01` in `Testing_Live-Test-Definitions.md`: register a task (run whether the user is logged on or not) running `Invoke-AutomationWithCredential.ps1` with a read-only job, check exit code 0 and the log, then repeat for each credential source in use (CP, CCP, Conjur, saved profile).
- Check and document: the "Run whether user is logged on or not" setting, profile loading, and what happens with the SYSTEM account or a gMSA (expected: DPAPI files unreadable; the CP route doesn't depend on DPAPI).

### 9. Resume all or a subset of CPM-disabled accounts
- **Built 2026-11-11** (branch `2026-11-11-bulk-resume-cpm-disabled`) as a separate action, `Accounts ResumeCpmDisabled` (Resume CPM-Disabled Accounts), not a mode of Resume Auto Management. Per decision Q4 the list is always `savedFilter=DisabledPasswordByCPM`, so `DisabledPasswordByUser` isn't offered. Safe and Search go to the API; PlatformID is matched client-side (no documented `platformId` filter on `GET /API/Accounts`). LT-ACCOUNTS-04 passed on Self-Hosted 2026-11-11.
- **Proposal:** a `Accounts ResumeAutoManagement` mode driven by a filter rather than identifiers: Safe, PlatformID, Search, and `SavedFilter` (`DisabledPasswordByCPM`, `DisabledPasswordByUser`, or both), with a required confirmation and `-WhatIf` listing the accounts first. It reuses item 4's helper and item 5's `SavedFilter`.
- Bulk `/API/Accounts/Resume/Bulk` is SH 15.2 only, so loop per account (works on 14.x and ISPSS).

### 10. Inactive users
- SH: `GET /API/Users/{id}` returns `lastSuccessfulLoginDate` (epoch). `GET /API/Users` can't filter on it, so filter client-side.
- **Proposal:**
  1. Add `LastLogin` to Users List output. Check live whether the list response includes it; if not, it costs one Get per user, so make it opt-in.
  2. An `InactiveDays` input on Users List that keeps only users with no logon in N days (and an option for "never logged on").
  3. Users Disable/Delete already take that CSV. Add a job-file example: List (inactive) → Disable → (later) Delete.
  4. Always exclude component and internal users (B3). Add a per-profile "always exclude" user list, stored on the profile and editable from the profile menu.
- ISPSS: users live in Identity; `POST /UserMgmt/GetUserInfo` returns `LastLoginDate` but is marked CPU-heavy; the Identity Report Library has a `LastLogin` SQL field. Needs a decision (Q10).

### 11. Bulk password update for vaulted accounts
- Already possible: Change in Vault (`POST /API/Accounts/{id}/Password/Update`) with a CSV of AccountID/Name+Safe plus `NewCredentials`.
- **Proposal:**
  1. New `Accounts SetNextPassword` (`POST /API/Accounts/{id}/SetNextPassword`, `{NewCredentials, ChangeImmediately}`) for CPM-managed accounts, where the target must change too. It's in the 14.6 Swagger and the ISPSS docs.
  2. Add an optional `ChangeEntireGroup` to Change in Vault (documented for that endpoint).
  3. Document the CSV route and the risk: the CSV holds clear-text passwords. Warn in the prompt; suggest deleting the file afterwards. Never log the value.

### 12. Nested group members across domains
- Already built: both group-member exports expand nesting with a stack and record the path (`Relationship` such as `A > B`).
- Gaps:
  1. The LDAP export searches one domain or LDAP root per run (one optional domain controller), so a group in another domain is reported "not found" (`Invoke-CustomExportGroupMembersLDAP.ps1:237`).
  2. The Local export lists LDAP groups nested in vault groups but doesn't expand them.
- **Proposal:** accept a list of domain controllers or domains (or derive them from the group's `@domain` suffix, mapped through a small domain → DC table), loop them, follow cross-domain members (foreign security principals), and add a `Domain` column. Let the Local export hand its LDAP groups to the same code.

### 13. Health snapshot before and after an upgrade
- SH (documented 12.2-15.2): `GET /API/ComponentsMonitoringSummary` (includes vault replication) and `GET /API/ComponentsMonitoringDetails/{ComponentID}` for PVWA, SessionManagement, CPM, PTA and AIM (AIM = Credential Providers: IP, user, version, IsLoggedOn, LastLogonDate).
- ISPSS: these endpoints aren't in the ISPSS docs; probe live (Q13).
- **Proposal:**
  1. `Custom ExportHealthSnapshot`: writes one CSV per component (plus the server Verify info; its path differs: SH `/WebServices/PIMServices.svc/Verify/`, ISPSS `/PasswordVault/API/verify/`).
  2. A standalone `Compare-HealthSnapshot.ps1` that diffs two snapshot folders: component added or removed, version changed, IsLoggedOn turned false, LastLogonDate stopped moving.
  3. Optional local CP checks, run on the CP host itself (not through the API): `appprvmgr ShowParms`, and the install logs the docs name (`Setup.log`, `ProviderInstall.log`, `CreateEnv.log`, `APPConsole.log`). Keep this optional and read-only.

### 14. Users and groups common to safes
- Built from the same safe-member data as Export Entitlements.
- **Output:** per member: MemberName, MemberType, SafeCount, the list of safes, and a "same permissions on every safe" flag. Optionally a member × safe matrix CSV. Options: limit to a safe list or a search pattern, a minimum safe count, and excluding built-in members (Administrator, Master, the CPM users and similar).
- Built as a menu action in the Custom category (Q14).

### 15. Manage the other Shared Services (SaaS only)
- **Request (2026-11-11):** the target choice becomes **Self-Hosted** or **SaaS**. A SaaS session shows a service menu (Identity, Privilege Cloud and the others) and then that service's categories.
- **Services and API base URLs** (from `API\Create-an-API-token\latest\create-api-token.md`; all use the same platform token from `https://<identity-tenant>.id.cyberark.cloud/oauth2/platformtoken`):

| Service | Base URL |
|---|---|
| Identity | `https://<tenant>.id.cyberark.cloud` (Identity APIs: `CDirectoryService`, `UserMgmt`, `SaasManage`, ...) |
| Privilege Cloud | Gen 3 `https://<sub>.privilegecloud.cyberark.cloud/api`, Gen 2 `.../PasswordVault/API` |
| Connector Management | `https://<sub>.connectormanagement.cyberark.cloud/api` |
| Secure Infrastructure Access (SIA) | `https://<sub>.dpa.cyberark.cloud/api` |
| Secure Cloud Access (SCA) | `https://<sub>.sca.cyberark.cloud/api` |
| Secrets Hub | `https://<sub>.secretshub.cyberark.cloud/api` |
| Access Control Policies | `https://<sub>.uap.cyberark.cloud/api` |
| Access Request | `https://<sub>.uar.cyberark.cloud/api` |
| Cloud Discovery Service | `https://<sub>.cds.cyberark.cloud/api` |
| Cloud Visibility | `https://<sub>.cem.cyberark.cloud/api` |
| Discovery & Context | `https://<sub>.inventory.cyberark.cloud/api/graphql` |
| Risk Management | `https://<sub>.compass.cyberark.cloud/api` |
| Secure Access | `https://<sub>-userportal.cyberark.cloud/api` |

- **Today:** profiles carry `SystemType` `Self-Hosted` or `Privilege Cloud` (token value `ISPSS`) and the tenant fields `TenantPortal`, `TenantVault` and `TenantAuth` (`Driver/Driver.ProfileStore.ps1`). Modules live in `APIModules/<Category>/` with `SupportedSystems` metadata; `Invoke-CyberArkAPI` takes the session's base URL.
- **Shape of the work (details wait for the S-questions):**
  1. A per-service base-URL resolver from the tenant subdomain, used by `Invoke-CyberArkAPI` through a new `Service` value in module metadata (default Privilege Cloud, so the 93 existing modules don't change).
  2. A service menu level for SaaS sessions, and a `Service` field in automation job steps (default Privilege Cloud).
  3. Existing `Privilege Cloud` profiles keep working; the display label changes to SaaS.
  4. Start with Identity and Connector Management, because items 1, 2 and 10 (ISPSS) need them.
- This is a driver-level change (profiles, menus, automation, comms), so it's a high-risk item under handoff section 13 and needs a `Design_` note and your go-ahead before code.

## 4. Decisions (2026-11-11)

- **Q1.** Item 1: yes, the Connector Management network on the account.
- **Q2.** Item 2: all of (a) clear "Is Service User", (b) re-enable a locked or suspended user and (c) make the user an OAuth confidential client. (c) has no documented API field, so it starts with a probe.
- **Q4.** Items 4 and 9: resume only accounts **disabled by the CPM** (`savedFilter=DisabledPasswordByCPM`), never ones a user disabled.
- **Q6.** Item 6: the mismatch is between the PVWA account details report and aPePAS. aPePAS shows only the platform's `LinkedPasswords` (Export Platform Details); nothing in aPePAS reads links set on the account itself.
- **Q7.** Item 7: both systems, and expand LDAP group membership from AD (shares item 12's multi-domain code).
- **Q10.** Item 10: on ISPSS, handle inactive users in Identity (needs item 15). Default action is Disable; Delete is a separate later step.
- **Q13.** Item 13: SH upgrades only.
- **Q14.** Item 14: a menu action (Custom category).
- **S1.** Item 15: one SaaS profile per tenant; one logon (platform token) serves every service.
- **S2.** First services: Identity and Connector Management, alongside Privilege Cloud. Others later.
- **S3.** Existing `Privilege Cloud` profiles are relabelled SaaS automatically and keep working.
- **S4.** Menu flow: profile → service (SaaS only; Self-Hosted skips it) → category → action.
- **S5.** New services go in `APIModules/<Service>/<Category>/` with a `Service` metadata field. The existing modules stay where they are for now: they serve both Self-Hosted and Privilege Cloud, so the only accurate new home would be something like `APIModules/PAM/<Category>/`, and moving 93 modules and their tests mostly buys folder symmetry at the cost of a large rename. Revisit once item 15's loader exists, if the mixed layout proves confusing.
- **S6.** Privilege Cloud stays on Gen 2 (`/PasswordVault/API`). Gen 3 is a later, separate decision.
- **B1.** Item 2(c): if a live probe finds no API to make a user an OAuth confidential client, record it as a UI-only step.
- **B2.** Item 4: the lab already has a CPM-disabled account.
- **B3.** Item 10: default 90 days; never-logged-on users count as inactive; component and internal users are always excluded; plus a per-profile list of users to always exclude, stored on the profile.
- **B4.** Item 7: both modes (one user's access; and what user A needs to match user B).

## 5. Suggested order

1. Item 5's `SavedFilter` on Accounts List (plumbing for 9).
2. Item 4's shared resume helper and `ResumeIfDisabled`.
3. Item 9 (filter-driven bulk resume).
4. Item 11 (Set Next Password).
5. Item 10, SH part (inactive users).
6. Probes in one TestApi session: 6, 3 (ISPSS Reports), 1 (network endpoint base), 2(c).
7. Item 8 live test (Task Scheduler).
8. Items 14, 12, 7, 13, 3.
9. Item 15 design note, then its foundation (resolver, service menu, job-file field) with Identity and Connector Management.
10. Items 1, 2 and the ISPSS part of 10, on top of item 15.
