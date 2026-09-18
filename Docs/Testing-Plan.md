# Testing Plan

## Overview

This document describes the testing strategy for the Idira Unified Scripts project.
Tests are organized into **unit tests** (no live CyberArk connection required) and
**integration tests** (require a real CyberArk environment). All unit tests use
[Pester v5/v6](https://pester.dev) and live under `Tests\Unit\`.

**Current focus: Self-Hosted PVWA.** This revision of the plan was produced for a full
functional test pass of the **Self-Hosted** deployment path specifically. See
[Self-Hosted vs. Privilege Cloud (SaaS) Scope and Caution](#self-hosted-vs-privilege-cloud-saas-scope-and-caution)
below before relying on this document for ISPSS/Privilege Cloud testing — the SaaS path has
**not** been fully tested, and several modules that declare support for both platforms have
only ever been exercised against Self-Hosted.

**See also:** `E2E-Automation-Design.md` — a proposed (not yet built) automated layer that would
exercise this document's manual checklist items against a real tenant with only credential entry
requiring a human. This document remains the source of truth for what the current, entirely-manual
process covers; the other tracks progress toward automating it.

---

## Test Environments

| Environment | Purpose | Required For |
|---|---|---|
| Local (no network) | Unit tests, mocked API | All unit tests |
| CyberArk ISPSS (dev/lab) | Integration tests — ISPSS | Auth, API module integration |
| CyberArk SelfHosted (dev/lab) | Integration tests — SelfHosted | Auth, API module integration |

A live Self-Hosted PVWA test/lab host is available for this test pass. Configure a profile with
`SystemType = Self-Hosted`, `BaseURL` pointed at that host, and `AppName = PasswordVault` (default)
unless the environment uses a custom application name. Do not run integration tests against
production environments, and prefer a dedicated test Safe/test accounts for any write operation
(Add/Update/Delete) so real vault data is never at risk.

**Do not run integration tests against production environments.**

---

## Self-Hosted vs. Privilege Cloud (SaaS) Scope and Caution

Every API module declares `$ModuleMeta.SupportedSystems` as `@('SelfHosted')`,
`@('ISPSS')`, or `@('ISPSS', 'SelfHosted')` (dual-use). As of this revision (post Phase 0-2 of
`aPePAS-Improvement-Plan-2026-09-02.md` — see `Documentation-Tracker.md` for the full history):

- **SelfHosted-only (3 modules):** `Platforms/Invoke-PlatformsRename.ps1` (confirmed via psPAS's
  explicit version/platform assertion — a PVWA 15.0+ feature), `Policies/Invoke-PoliciesSetMasterPolicy.ps1`
  (confirmed the same way, PVWA 14.6+ - and now doubly moot on ISPSS, since the user has verified
  live that no Master Policy equivalent exists there at all, per the note below), and
  `Reports/Invoke-ReportsList.ps1`. These are hidden from the menu entirely for an ISPSS profile.
  - **`Policies/Invoke-PoliciesGetMasterPolicy.ps1` is declared dual-use, unlike `SetMasterPolicy`,
    even though the endpoint is now confirmed absent on ISPSS** — per user request (to include
    Master Policy in `Custom/ExportAll`), even though psPAS's own `Get-PASMasterPolicy.ps1`
    explicitly asserts `-SelfHosted`. At the time this was written, no local CyberArk reference
    material documented an ISPSS/Privilege Cloud equivalent, but nothing there confirmed Privilege
    Cloud actually lacked it either. **The user has since verified live against a real Privilege
    Cloud tenant that no Master Policy equivalent endpoint exists there.** `SupportedSystems` was
    kept dual-use anyway (per user direction - current behavior is fine as-is): the module's
    pre-existing non-fatal failure handling already turns the confirmed-absent endpoint into a
    clean, non-crashing `Failure` on ISPSS (not `IsFatal` unless 401/0), so `Custom/ExportAll`
    degrades gracefully there rather than needing a separate system-type branch. Read on
    Self-Hosted remains fully live-confirmed as before. See Finding F40.
  - **`Reports/Invoke-ReportsList.ps1` is Self-Hosted-only again** — Phase 1 (earlier this
    session) had expanded it to dual-use based on psPAS's own comparison review claiming ISPSS
    support from v14.6+, but the user tested it live against an ISPSS/Privilege Cloud tenant on
    2026-09-02 and got an HTTP 404 (`GET /API/Reports` does not exist there). Reverted to
    `SupportedSystems = @('SelfHosted')`.
  - **`Applications` (all 7 modules) are confirmed dual-use** — the user tested the ISPSS
    Applications menu on 2026-09-02: only `Add` was visible (it was the only one already marked
    dual-use), confirming the other 6 (`AddAuthMethod`, `Delete`, `DeleteAuthMethod`, `Get`,
    `List`, `ListAuthMethods`) had been Self-Hosted-only in error. All 7 now declare
    `SupportedSystems = @('ISPSS', 'SelfHosted')`. Only menu visibility has been confirmed on
    ISPSS for the 6 newly-expanded modules — their actual request/response behavior against a
    live ISPSS tenant remains unverified (see the checklist below).
- **Dual-use (the remaining 64 of 67 total modules, across Accounts, Safes, SafeMembers, Platforms
  (9 of its 10 actions - only `Rename` is Self-Hosted-only), Applications, Users, Groups, Custom,
  and `Policies/GetMasterPolicy` - `SetMasterPolicy` is the only Policies action still
  Self-Hosted-only):**
  declared to support both platforms,
  but **ISPSS coverage for most of this set has not been fully tested** — most of the deep,
  iterative bug-fixing history in `Documentation-Tracker.md` was driven by Self-Hosted testing/use.
  Treat a dual-use module's ISPSS behavior as unverified until someone actually exercises it
  against a Privilege Cloud tenant, even though the code path is shared. Two specific items *were*
  confirmed live on ISPSS during Phase 0/1 (this session): `Get-PVWASessionTimeoutMinutes`
  (`/api/Settings/Timeout`) 404s on Privilege Cloud and correctly falls back to a default; and
  `Invoke-AccountsResumeAutoManagement.ps1`'s ISPSS path was deliberately left unchanged
  (unconfirmed) when its Self-Hosted endpoint was corrected, specifically to avoid guessing at
  ISPSS behavior that hadn't been verified.
- **Known, already-confirmed platform-specific traps inside dual-use modules** (background for
  anyone testing or extending these — not new findings from this pass, see
  `Lessons-Learned-PowerShell-Pester.md` Section 16 for the originals):
  - ISPSS returns `groupType='Vault'` (and no `directory.directoryType`) for **every** group,
    including LDAP/directory-backed ones. `Groups/Invoke-GroupsList.ps1`'s `GroupType` filter is
    effectively unusable on ISPSS as a result — filtering for anything but `Vault` silently
    returns zero rows with no explanation. `Custom/Invoke-CustomExportGroupMembersLDAP.ps1` and
    `Custom/Invoke-CustomExportGroupMembersLocal.ps1` both work around this with a
    groupName-contains-`@` heuristic (this session fixed the Local module, which had not received
    that fix when the LDAP module did — see the Findings section below).
  - CyberArk's `/API/Accounts` endpoint caps results at roughly 20,000 without a safe filter
    (`Invoke-AccountsList.ps1`'s "By-Safe" mode works around this) — confirm whether the same cap
    applies identically on the Self-Hosted PVWA version under test; it may differ by version.
  - Field-name/response-shape differences by PVWA version are common for Platforms (`id` vs
    `PlatformID`, `platformType` vs `SystemType`, nested under `general` or at the root) and Safe
    Members (camelCase vs PascalCase permission keys) - see Lessons-Learned Sections 12 and 19.
    These were previously fixed for `Invoke-PlatformsGet.ps1`; this session found and fixed the
    same gap in `Invoke-PlatformsList.ps1` (see Findings below). When testing against the live
    Self-Hosted host, note its exact PVWA version so a future field-shape mismatch can be
    correlated to a version boundary.
  - `SafeMembers/Invoke-SafeMembersAdd.ps1` and `SafeMembers/Invoke-SafeMembersAddFromTemplateRole.ps1`
    call `GET /API/Configuration/LDAP/Directories` for the interactive "SearchIn" directory
    picker; the exact response field names for that endpoint were unconfirmed against a live
    system when written (falls back to Vault-only, never blocks the flow, but verify the picker
    actually lists real directories against the live host).
  - `Safes/Invoke-SafesAssignCPM.ps1` queries `GET /API/Users?userType=CPM&componentUser=true`
    live for its CPM picker (deliberately different from `Safes/AddFromTemplate`'s profile-based
    `CPM_List`) — confirm this query returns the expected CPM accounts on the live host.
- **Recommendation for any module found broken specifically on ISPSS while dual-declared:**
  follow the precedent already set by `Custom/Invoke-CustomExportGroupMembersLocal.ps1` /
  `Invoke-CustomExportGroupMembersLDAP.ps1` — fix the platform-specific branch in place rather
  than forking the file, *unless* the SelfHosted and ISPSS implementations diverge so much that a
  shared function body is no longer readable/maintainable, in which case split into
  `Invoke-<Category><Action>.ps1` (SelfHosted) and a distinctly-named ISPSS counterpart, following
  the same pattern already used for the Auth layer (`CyberArk.Auth.SelfHosted.psm1` vs
  `CyberArk.Auth.ISPSS.psm1`).

---

## Running Tests

```powershell
# Run all unit tests (from the project root)
.\Tests\Run-Tests.ps1

# Run a single test file
.\Tests\Run-Tests.ps1 -Path Tests\Unit\CyberArkLogging.Tests.ps1

# Run with verbose output
.\Tests\Run-Tests.ps1 -Verbosity Detailed
```

Pester v5 is required. `Run-Tests.ps1` checks for it and prints installation
instructions if it is missing.

---

## Component Test Matrix

This table was significantly out of date relative to the actual `Tests\Unit\` folder (which
already had unit tests for every shipped module) — it listed only a handful of modules. It now
lists every component and module that exists in this project, its unit-test file, and whether it
also needs manual/live Self-Hosted integration verification per this test pass. "SH" = SupportedSystems
includes SelfHosted; "Both" = SelfHosted + ISPSS declared (see the caution section above).

### Core / Shared

| Component | Unit Tests | Test File | Live Self-Hosted Verification Needed |
|---|---|---|---|
| `CyberArkLogging.psm1` | Yes | `Unit\CyberArkLogging.Tests.ps1` | No |
| `CyberArkComms.psm1` | Partial (helpers + success path; 401/429/504 error paths need `Invoke-CyberArkAPI` mocking at the module-caller level - see Testing Boundaries) | `Unit\CyberArkComms.Tests.ps1` | Yes — 429 backoff and 504 retry/page-shrink against a real PVWA; also confirm behavior is unchanged if the driver is ever run under PowerShell 7/`pwsh` instead of Windows PowerShell 5.1 (see Known Issues) |
| `Auth\CyberArk.Auth.Common.psm1` | No (WebView2/cert-store/DPAPI all require a live Windows session) | — | Yes — `Save-AuthToken`/`Import-AuthToken` round-trip, `Get-FilteredClientCertificate` picker |
| `Auth\CyberArk.Auth.SelfHosted.psm1` | No (auth flows) | — | Yes (manual, all 8 methods — see the dedicated section below) |
| `Auth\CyberArk.Auth.ISPSS.psm1` | Partial - `ClientCredentials` response parsing only | `Unit\CyberArk.Auth.ISPSS.Tests.ps1` (ISPSS-CC01-CC06) | Yes (manual, all 3 methods — see the dedicated section below) |
| `Manage-Privilege.ps1` — profile CRUD | Yes (filesystem) | `Unit\Manage-Privilege.Tests.ps1` | No |
| `Manage-Privilege.ps1` — session loop, keepalive, token refresh, CSV loop | No (UI/interactive) | — | Yes (manual — D-series below, including the new D23-D25 regression/known-gap cases) |

### APIModules — SelfHosted only (no ISPSS ambiguity)

| Module | Unit Tests | Test File | Live Self-Hosted Verification Needed |
|---|---|---|---|
| Platforms / Rename | Yes | `Unit\Invoke-PlatformsRename.Tests.ps1` | Yes — PVWA 15.0+ required, confirm against this lab host's actual version |
| Policies / SetMasterPolicy | Yes | `Unit\Invoke-PoliciesSetMasterPolicy.Tests.ps1` | Yes — PVWA 14.6+ required. Mutates tenant-wide config, not a scoped object — test against a dedicated lab host only, never a shared/production one |

### APIModules — dual-use (Both; ISPSS coverage unverified — see caution section)

| Module | Unit Tests | Test File | Live Self-Hosted Verification Needed |
|---|---|---|---|
| Accounts / Add | Yes | `Unit\Invoke-AccountsAdd.Tests.ps1` | Yes |
| Accounts / CancelCpmTask | Yes | `Unit\Invoke-AccountsCancelCpmTask.Tests.ps1` | Yes |
| Accounts / ChangeImmediate | Yes | `Unit\Invoke-AccountsChangeImmediate.Tests.ps1` | Yes |
| Accounts / ChangeInVault | Yes | `Unit\Invoke-AccountsChangeInVault.Tests.ps1` | Yes — confirm the corrected `Password/Update` endpoint (F12, this session — was `SetNextPassword` before) actually changes the vault password immediately; also confirm the JSON-key log-masking pattern keeps the new vault password out of the log file at DEBUG level against a real call |
| Accounts / CheckIn | Yes | `Unit\Invoke-AccountsCheckIn.Tests.ps1` | Yes |
| Accounts / Delete | Yes | `Unit\Invoke-AccountsDelete.Tests.ps1` | Yes |
| Accounts / Get | Yes | `Unit\Invoke-AccountsGet.Tests.ps1` | Yes |
| Accounts / GetActivity | Yes | `Unit\Invoke-AccountsGetActivity.Tests.ps1` | Yes |
| Accounts / GetCredential | Yes | `Unit\Invoke-AccountsGetCredential.Tests.ps1` | Yes |
| Accounts / LinkAccount | Yes | `Unit\Invoke-AccountsLinkAccount.Tests.ps1` | **Confirmed (2026-09-04)** — previously logged as a live-tenant HTTP 404 limitation (F41), the user has since retested and confirmed it now works correctly |
| Accounts / List (incl. By-Safe mode) | Yes | `Unit\Invoke-AccountsList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted |
| Accounts / Reconcile | Yes | `Unit\Invoke-AccountsReconcile.Tests.ps1` | Yes |
| Accounts / ResumeAutoManagement | Yes | `Unit\Invoke-AccountsResumeAutoManagement.Tests.ps1` | Yes |
| Accounts / UnlinkAccount | Yes | `Unit\Invoke-AccountsUnlinkAccount.Tests.ps1` | **Confirmed (2026-09-04)** — same as LinkAccount above (F41) |
| Accounts / Unlock | Yes | `Unit\Invoke-AccountsUnlock.Tests.ps1` | Yes |
| Accounts / Update (JSON Patch) | Yes | `Unit\Invoke-AccountsUpdate.Tests.ps1` | Yes |
| Accounts / Verify | Yes | `Unit\Invoke-AccountsVerify.Tests.ps1` | Yes |
| Safes / Add | Yes | `Unit\Invoke-SafesAdd.Tests.ps1` | Yes — F44's new `SafeName` length/charset/leading-whitespace rejection is unit-tested only, not yet confirmed against a real Vault's own naming rule |
| Safes / AddFromTemplate | Yes | `Unit\Invoke-SafesAddFromTemplate.Tests.ps1` | Yes |
| Safes / AssignCPM | Yes | `Unit\Invoke-SafesAssignCPM.Tests.ps1` | Yes — confirm the live CPM query against the real host |
| Safes / Delete | Yes | `Unit\Invoke-SafesDelete.Tests.ps1` | Yes |
| Safes / Get | Yes | `Unit\Invoke-SafesGet.Tests.ps1` | Yes |
| Safes / List | Yes | `Unit\Invoke-SafesList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted |
| Safes / UnassignCPM | Yes | `Unit\Invoke-SafesUnassignCPM.Tests.ps1` | Yes |
| Safes / Update | Yes | `Unit\Invoke-SafesUpdate.Tests.ps1` | Yes — F44's new `SafeName` length/charset/leading-whitespace rejection is unit-tested only, not yet confirmed live |
| SafeMembers / Add | Yes | `Unit\Invoke-SafeMembersAdd.Tests.ps1` | Yes — confirm the SearchIn directory picker lists real LDAP directories. F47's `ReadOnly` -> `ReadOnlyStrict` preset rename is unit-tested only |
| SafeMembers / AddFromTemplateRole | Yes | `Unit\Invoke-SafeMembersAddFromTemplateRole.Tests.ps1` | Yes |
| SafeMembers / List | Yes | `Unit\Invoke-SafeMembersList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted |
| SafeMembers / Remove | Yes | `Unit\Invoke-SafeMembersRemove.Tests.ps1` | Yes |
| SafeMembers / Update | Yes | `Unit\Invoke-SafeMembersUpdate.Tests.ps1` | Yes — F47's `ReadOnly` -> `ReadOnlyStrict` preset rename is unit-tested only |
| SafeMembers / UpdateFromTemplateRole | Yes | `Unit\Invoke-SafeMembersUpdateFromTemplateRole.Tests.ps1` | Yes |
| Platforms / Copy | Yes | `Unit\Invoke-PlatformsCopy.Tests.ps1` | Yes — Target platforms only this pass (see `E2E-Automation-Design.md`); confirmed against psPAS source + the 14.6 Swagger spec, never against a live tenant |
| Platforms / Disable | Yes | `Unit\Invoke-PlatformsDisable.Tests.ps1` | Yes — same caveat as Copy |
| Platforms / Enable | Yes | `Unit\Invoke-PlatformsEnable.Tests.ps1` | Yes — same caveat as Copy |
| Platforms / Export | Yes | `Unit\Invoke-PlatformsExport.Tests.ps1` | `PlatformID` variant **confirmed (2026-09-04)** — live download of a real `.zip`, verified openable with real policy files inside. `RotationalGroupID`/`DependentID`/`GroupPlatformID` variants unit-tested against psPAS's documented shapes only, not yet live-confirmed - no existing module can discover a real ID for those types |
| Platforms / Get | Yes | `Unit\Invoke-PlatformsGet.Tests.ps1` | Yes |
| Platforms / Import | Yes | `Unit\Invoke-PlatformsImport.Tests.ps1` | Yes — the ZIP-as-byte-array request shape is unverified against a live tenant (see its own code comment and `E2E-Automation-Design.md`) |
| Platforms / List | Yes | `Unit\Invoke-PlatformsList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted (the alternate-field-name fallback and `SystemType` filter noted here are covered by that confirmation) |
| Platforms / Remove | Yes | `Unit\Invoke-PlatformsRemove.Tests.ps1` | Yes — destructive; test against a disposable sandbox platform only, same caveat as Copy otherwise |
| Platforms / SetPSMConfig | Yes | `Unit\Invoke-PlatformsSetPSMConfig.Tests.ps1` | Yes — same caveat as Copy; needs a real PSM server ID from the test tenant |
| Policies / GetMasterPolicy | Yes (incl. PGMP08/PGMP09 for the dual-use/graceful-404 behavior) | `Unit\Invoke-PoliciesGetMasterPolicy.Tests.ps1` | Self-Hosted **confirmed (2026-09-04)** — live retrieval against the real tenant, including through the `Custom/ExportAll` `IncludeInExportAll` path. **ISPSS/Privilege Cloud confirmed (2026-09-04) to have no Master Policy equivalent endpoint** — the user verified this live against a real Privilege Cloud tenant. `SupportedSystems` is kept dual-use anyway (per user direction, current behavior is fine): the module's existing non-fatal failure handling already turns that into a clean `Failure`, not a crash, so no code change was needed. See Finding F40 |
| Applications / Add | Yes | `Unit\Invoke-ApplicationsAdd.Tests.ps1` | **Confirmed (2026-09-02)** — the only Applications action the user found visible/working on the ISPSS Applications menu, confirming its earlier dual-use `SupportedSystems`. F45's new `AccessPermittedFrom`/`To` range check and `AppID`/`Description`/`BusinessOwnerFName`/`BusinessOwnerPhone` length/charset checks are unit-tested only, not yet confirmed live |
| Applications / AddAuthMethod | Yes | `Unit\Invoke-ApplicationsAddAuthMethod.Tests.ps1` | Menu visibility only — user's 2026-09-02 ISPSS test showed this action missing from the menu (it was still Self-Hosted-only); now expanded to dual-use. Actual ISPSS request/response behavior is unverified |
| Applications / Delete | Yes | `Unit\Invoke-ApplicationsDelete.Tests.ps1` | Menu visibility only — same 2026-09-02 finding and expansion as AddAuthMethod above; ISPSS request/response behavior unverified |
| Applications / DeleteAuthMethod | Yes | `Unit\Invoke-ApplicationsDeleteAuthMethod.Tests.ps1` | Menu visibility only — same 2026-09-02 finding and expansion as AddAuthMethod above; ISPSS request/response behavior unverified |
| Applications / Get | Yes | `Unit\Invoke-ApplicationsGet.Tests.ps1` | Menu visibility only — same 2026-09-02 finding and expansion as AddAuthMethod above; ISPSS request/response behavior unverified |
| Applications / List | Yes | `Unit\Invoke-ApplicationsList.Tests.ps1` | **Confirmed (2026-09-02) on Self-Hosted** (the `Join-CyberArkUrl` trailing-slash/PIMServices.svc routing fix noted here is covered by that confirmation). On ISPSS, only menu visibility was confirmed the same day — it had been Self-Hosted-only and is now expanded to dual-use; ISPSS request/response behavior is unverified |
| Applications / ListAuthMethods | Yes | `Unit\Invoke-ApplicationsListAuthMethods.Tests.ps1` | Self-Hosted: Yes — **not** covered by the "all List actions confirmed" status below, since its `Action` is `ListAuthMethods`, not `List`. The blank-`AppID`-lists-every-application behavior (added this session, per user request) is new and unverified against a real host. On ISPSS, only menu visibility was confirmed 2026-09-02 — it had been Self-Hosted-only and is now expanded to dual-use; ISPSS request/response behavior is unverified |
| Reports / List | Yes | `Unit\Invoke-ReportsList.Tests.ps1` | **Confirmed Self-Hosted-only (2026-09-02)** — the user tested this live against an ISPSS/Privilege Cloud tenant and got an HTTP 404 (`GET /API/Reports` doesn't exist there), reversing Phase 1's dual-use expansion. `SupportedSystems` reverted to `@('SelfHosted')`; the module is now hidden from the ISPSS menu entirely |
| Users / Get | Yes | `Unit\Invoke-UsersGet.Tests.ps1` | Yes |
| Users / List | Yes | `Unit\Invoke-UsersList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted |
| Groups / Add | Yes | `Unit\Invoke-GroupsAdd.Tests.ps1` | Yes |
| Groups / AddMember | Yes (incl. GAM07/GAM08 for the username-not-integer fix) | `Unit\Invoke-GroupsAddMember.Tests.ps1` | **Confirmed (2026-09-04)** — previously logged as a live-tenant HTTP 400 limitation (F42: the "memberId" field is the username, not a numeric ID), the user reported the fix and it was live-verified end-to-end (create test group -> add member by username -> HTTP 201) |
| Groups / Delete | Yes | `Unit\Invoke-GroupsDelete.Tests.ps1` | Yes |
| Groups / GetMembers | Yes (incl. GM17 for the missing-userType/componentUser fix) | `Unit\Invoke-GroupsGetMembers.Tests.ps1` | **Confirmed (2026-09-04)** — found and fixed live (F43) during F42's verification: a real member entry is only `{id, username}`, no `userType`/`componentUser`, which previously crashed the mapping loop under strict mode |
| Groups / List | Yes | `Unit\Invoke-GroupsList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted (the `GroupType` filter noted here is covered by that confirmation) |
| Groups / RemoveMember | Yes | `Unit\Invoke-GroupsRemoveMember.Tests.ps1` | **Confirmed (2026-09-04)** — live-verified as part of F42's end-to-end test (remove by username -> HTTP 204); already treated MemberID as a string, so no code change was needed here, only the description |
| Groups / Update | Yes | `Unit\Invoke-GroupsUpdate.Tests.ps1` | Yes |
| Custom / ExportAll | Yes | `Unit\Invoke-CustomExportAll.Tests.ps1` | Yes — now also discovers and runs Applications/ListAuthMethods (added this session, per user request), not previously part of Export All. That specific addition is unverified against a real host. **Also now discovers Policies/GetMasterPolicy via a new generic `ModuleMeta.IncludeInExportAll` opt-in (any non-List/ListAuthMethods module can use it) - confirmed live (2026-09-04) against the real Self-Hosted tenant, saving a real `Export_PoliciesGetMasterPolicy.csv`** |
| Custom / ExportEntitlements | Yes | `Unit\Invoke-CustomExportEntitlements.Tests.ps1` | Yes |
| Custom / ExportGroupMembersLDAP | Yes | `Unit\Invoke-CustomExportGroupMembersLDAP.Tests.ps1` | Yes — requires line-of-sight from wherever the script runs to the actual Active Directory (ADSI-based, not a CyberArk API call) |
| Custom / ExportGroupMembersLocal | Yes (incl. new ISPSS-groupType-quirk regression test this session) | `Unit\Invoke-CustomExportGroupMembersLocal.Tests.ps1` | Yes |
| Custom / ExportPlatformDetails | Yes (PPD01-PPD11; uses real in-memory-built `.zip` archives, not mocked-away zip parsing) | `Unit\Invoke-CustomExportPlatformDetails.Tests.ps1` | **Confirmed (2026-09-04)** — live run against the real Self-Hosted tenant: 10/10 active platforms (of 15 total) processed successfully, 104 dynamic columns, spot-checked type-specific fields (e.g. `Ini.ExtraInfo.Port`, `Ini.KeySize`) populate only where applicable and blank-fill elsewhere. The `OtherFiles`/META-INF-exclusion logic is implemented exactly per spec and unit-tested, but no real example of a platform with extra bundled files or a META-INF folder was found on this tenant across the platforms sampled, so that part remains live-unconfirmed |
| Custom / TestApi | **No unit test file exists** (interactive raw API tester — same exemption class as other `Read-Host`-driven helpers) | — | Yes (manual smoke test only) |
| Custom / TestConnectivity | Yes (orchestration mocked; DNS/TCP helpers, `ConvertTo-Win32QuotedArgument`, `Find-PlinkExecutable`, and the plink trust-on-first-use retry exercised for real/mocked deterministically - no CyberArk connection needed for those) | `Unit\Invoke-CustomTestConnectivity.Tests.ps1` | The Linux/plink path is now fully confirmed live end-to-end against a real target with real credentials (172.21.20.14, user-provided test account): DNS resolution (F28), plink-first with host-key trust-on-first-use (F27/F29), a successful login (`AuthStatus: Success`), and a wrong password failing cleanly - the CSV filename change (F26) was also confirmed live in the same pass. Not yet confirmed live: the actual Windows SMB (`New-SmbMapping`) auth attempt, the PS7 SSH transport path's own success case (it's documented to time out on password auth and plink is now tried first, so this may never need separate confirmation), and the `Safe`/`Username`/`PasswordSource` output columns (F22) against a real vault-backed lookup (the live test above supplied the password directly, not via vault lookup) |

---

## Findings and Fixes — 2026-09-02 Self-Hosted Review

This full-project review (triggered by the request to produce a Self-Hosted test plan and fix
anything found broken) turned up and fixed the following. All fixes were made via careful static
code reading and cross-reference against this project's own `Documentation-Tracker.md` and
`Lessons-Learned-PowerShell-Pester.md` history; **no PowerShell interpreter was available in the
environment this review was performed in**, so none of the fixes below have been executed against
a real PVWA or run through Pester yet — see the "Yes" rows in the Component Test Matrix above and
the checklist later in this document for what still needs live confirmation.

| # | File(s) | Issue | Fix | Test(s) added |
|---|---|---|---|---|
| F01 | `Modules/CyberArkComms.psm1` | `Join-CyberArkUrl` unconditionally trims a trailing slash from the joined URI. The legacy `PIMServices.svc` WCF REST endpoint used by every `Applications` module needs that trailing slash preserved on some routes (e.g. `Applications` list) or the request is misrouted/rejected. The slash was added once (2026-08-16) to fix this, then reverted the same day to resolve an unrelated regression in test C12, and never re-fixed. | `Invoke-CyberArkAPI` now restores the trailing slash at the call site, based on the caller's own `-Endpoint` string, when present — without changing `Join-CyberArkUrl`'s generic (always-trimmed) contract. | C25b, C25c in `CyberArkComms.Tests.ps1` |
| F02 | `Modules/CyberArkLogging.psm1` | The sensitive-data log-masking regex list only matched a hardcoded set of OAuth field names (`access_token`, `refresh_token`, `id_token`). Any other secret-shaped JSON key — notably `NewCredentials` (the literal new vault password) in `Invoke-AccountsChangeInVault.ps1`'s request body — was logged in cleartext at DEBUG/`-FileOnly` level via `CyberArkComms.psm1`'s request-body logging. | Added a generic pattern matching any quoted JSON key containing `password`, `secret`, `token`, or `credential` (case-insensitive), masking the value regardless of key name. | L22a, L22b, L22c in `CyberArkLogging.Tests.ps1` |
| F03 | `APIModules/Applications/Invoke-ApplicationsAdd.ps1` | `[int]$AccessFrom` / `[int]$AccessTo` casts on CSV input throw an unhandled exception (crashing the whole batch) if the CSV cell isn't a clean integer. | Replaced with `[int]::TryParse`, returning a normal non-fatal `Failures` entry with an `ErrorMessage` instead of throwing. | New tests under "AccessPermittedFrom / AccessPermittedTo validation" in `Invoke-ApplicationsAdd.Tests.ps1` |
| F04 | `APIModules/Reports/Invoke-ReportsList.ps1` | Dot-notation access on 6 result fields (`ReportID`, `ReportName`, `Description`, `ReportType`, `RunDate`, `Aggregated`) throws `PropertyNotFoundException` under strict mode (always active via the driver) if the live PVWA response omits any of them. | Added `PSObject.Properties[...]` existence guards on all 6 fields. | RL08a (with `Set-StrictMode -Version Latest` and a sparse report object) in `Invoke-ReportsList.Tests.ps1` |
| F05 | `Invoke-ApplicationsAdd.ps1` (`Disabled`), `Invoke-ApplicationsAddAuthMethod.ps1` (`IsFolder`, `AllowInternalScripts`), `Invoke-ApplicationsList.ps1` (`IncludeSublocations`), `Invoke-PlatformsList.ps1` (`ActiveOnly`), `Invoke-SafesList.ps1` (`ExtendedDetails`) | Five separate modules cast a CSV-sourced string directly to `[bool]`. In .NET, `[bool]"false"` evaluates to `$true` (any non-empty string is truthy), so every CSV row with the literal text `false` was silently treated as `true`. | All five now use a `-match '(?i)^(true|yes|y|1)$'`-style pattern instead of a `[bool]` cast. | New CSV-string "false"/"true" tests added to each module's test file (see Component Test Matrix rows above) |
| F06 | `APIModules/Platforms/Invoke-PlatformsList.ps1` | Field-mapping only checked one shape of the platform object (`PlatformID`/`SystemType`/nested `general`), while `Invoke-PlatformsGet.ps1` already had a 4-variant fallback chain for PVWA-version differences (`id` vs `PlatformID`, `platformType` vs `SystemType`, `general` sub-object vs root). `PlatformsList` would silently return blank fields against a PVWA version whose List response used the shape `Get` already handled. | Rewrote `PlatformsList`'s mapping to mirror `PlatformsGet`'s full fallback chain. | PL12a (alt-shape object) in `Invoke-PlatformsList.Tests.ps1` |
| F07 | `APIModules/Custom/Invoke-CustomExportGroupMembersLocal.ps1` | ISPSS returns `groupType='Vault'` for every group, including LDAP-backed ones, with no `directoryType` to disambiguate. The sibling `ExportGroupMembersLDAP` module already had an `@`-in-name heuristic to detect LDAP groups despite this; `ExportGroupMembersLocal` did not, so on ISPSS it would misclassify LDAP groups as local ones. | Added the same `-or ($gname -and $gname -match '@')` condition to the `$isLdap` check. | New "ISPSS groupType quirk" context in `Invoke-CustomExportGroupMembersLocal.Tests.ps1` |
| F08 | `Manage-Privilege.ps1` — `Invoke-SelfHostedKeepalive` | The keepalive call extends the session's expiry on the PVWA side but never persisted the new expiry to the saved `.cred` file. A crash or unexpected exit shortly after a keepalive would leave the on-disk token looking expired sooner than it actually was. | Added a `Save-AuthToken` call after a successful keepalive. | Not unit-tested (see note below) |
| F09 | `Manage-Privilege.ps1` — inner category/action loop (`Invoke-SessionLoop`) | The outer (category-selection) menu loop ran inactivity-timeout, proactive-refresh, and token-expiry checks on every iteration; the **inner** (action-within-category) loop did not run any of them. A user who stayed inside one category performing many actions in a row never got a keepalive, a proactive refresh, or an inactivity timeout until they backed out to the category menu. | Duplicated the outer loop's check block (inactivity check, `Invoke-ProactiveRefresh`, `Test-TokenExpiry` handling for `Expired`/`Warning`) at the top of the inner loop. | Not unit-tested (see note below) |
| F10 | `Auth/Get-AuthToken.ps1` | Dead file — a legacy shim with zero real call sites (only referenced by an unrelated same-named Pester mock stub), left over from the Auth-module rework. `Auth-Module-Rework-Design.md` itself documents deleting this file as a never-executed final step of that rework. | Deleted. | N/A |
| F11 | `README.md`, `Docs/API-Module-Development-Guide.md`, `Docs/Interfaces.md` | Stale documentation: project-structure trees still listed the deleted `Get-AuthToken.ps1`; `Interfaces.md` described `Invoke-WebView2Window`'s actual parameters and return shape incorrectly, and showed `Get-SelfHostedAuthToken`'s `AuthMethod`/`PVWAUrl` as falsely `[Parameter(Mandatory)]` when both actually fall back to interactive `Read-Host` prompts if omitted. | Corrected all three documents to match the actual code. | N/A (documentation only) |
| F12 | `APIModules/Accounts/Invoke-AccountsChangeInVault.ps1` | Called the wrong endpoint: `POST /API/Accounts/{id}/SetNextPassword`, which per the Swagger spec (`Swagger/CyberArk_PasswordVault_Swagger_14.6.v1.json`) "gives the ability to set the account's credentials for the next CPM change" — a queued-for-CPM operation, not an immediate vault-only change. The module's own name and description ("Change Credentials In Vault"/"does not change on the target system") match `POST /API/Accounts/{id}/Password/Update` instead, confirmed both by the Swagger spec's description ("set the account's credentials and change it in the Vault. This will not affect the credentials on the target device") and by psPAS's `Invoke-PASCPMOperation.ps1`, which treats `Password/Update` and `SetNextPassword` as two distinct parameter sets. Reported directly by the user. | Changed the endpoint to `/API/Accounts/{id}/Password/Update`. The request body was already correct (`NewCredentials`) — both endpoints share that field name per the Swagger `ChangeInVaultProperties`/`SetNextCredentialsProperties` schemas. | No new test added — the existing test file mocks `Invoke-CyberArkAPI` generically and doesn't assert on the endpoint string |
| F13 | `Manage-Privilege.ps1` — `Invoke-ActionModule` (results display) | `[FATAL] PropertyNotFoundException` on `.Count`, reported directly by the user, for any `List` action that returns exactly one row. `$tableData = if ($meta.Action -eq 'List') {@(...)} else {@($result.Results)}` had no outer `@(...)` wrapping the whole `if/else` — when the branch emitted exactly one object, PowerShell auto-unrolled it onto the pipeline as a bare scalar instead of a one-element array (the single/some-item counterpart of the empty-collapses-to-`$null` bug already documented as Lessons-Learned 9.8), and `$tableData.Count` on the very next line threw under `Set-StrictMode`. A second, identical assignment two lines later (`$displayData = if (...) {...} else {$tableData}`) had the same latent bug. | Wrapped both entire `if/else` expressions in an outer `@(...)` (`$tableData = @(if (...) {...} else {...})`), matching the already-established fix pattern from 9.8. Verified directly against real `powershell.exe` (Windows PowerShell 5.1) before and after — `pwsh`/PowerShell 7 does not reproduce the exception at all, since PS7 gives every scalar object a synthetic `Count` of `1`, masking the type defect. | No automated test added — `Invoke-ActionModule` is an interactive, `Read-Host`/dynamic-dispatch-driven function outside this project's established unit-testing boundary, and `Manage-Privilege.Tests.ps1` has a documented reproducible Pester v6.1 hang risk for new `Describe` blocks in this area (see the F08/F09 note below) |
| F14 | `APIModules/Accounts/Invoke-AccountsCancelCpmTask.ps1`, `Invoke-AccountsResumeAutoManagement.ps1` | Both call an endpoint with a minimum PVWA version requirement not previously accounted for: `/Cancel/` needs 15.2+ and `/Resume/` needs 15.0+ per the user (psPAS's own `Stop-PASCPMTask.ps1`/`Resume-PASCPMAutoManagement.ps1` assert `RequiredVersion 15.2` for both — a discrepancy from the user's stated 15.0 for Resume that's noted here but doesn't affect the fix, since neither this project nor psPAS has a reliable way to query the actual PVWA version). On an older PVWA, both endpoints simply don't exist. Reported directly by the user. | Per user direction: both modules now call the newer endpoint first; on an HTTP 404 specifically (any other failure - 401/403/500/network - stays a real, non-fallback error), they retry against a version-agnostic fallback and log a `WARN` noting the fallback. `CancelCpmTask` falls back to the pre-Phase-1 `/StopImmediateAutoMgmtOperations` endpoint (recovered from git history, commit `1f06d6e`'s parent). `ResumeAutoManagement` (Self-Hosted only - ISPSS already uses the fallback shape as its primary path) falls back to the same `PATCH .../ automaticManagementEnabled` JSON Patch body already used for ISPSS. | New tests in both modules' `*.Tests.ps1` files: fallback triggers and succeeds on 404, does NOT trigger on a non-404 failure (only one API call made), and the overall result is a failure when the fallback also fails |
| F15 | `APIModules/Custom/Invoke-CustomTestApi.ps1` | Reported directly by the user: the whole script process closes immediately with no error shown when the session token expires while using Test API. Root cause: this module is the only place in the codebase that enables the IgnoreSSL bypass via `[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }` - a raw PowerShell scriptblock assigned directly to a .NET delegate. Every other module instead goes through `Invoke-CyberArkAPI`'s `Disable-SSLValidation`, which uses a compiled `ICertificatePolicy` class. Assigning a scriptblock to `ServerCertificateValidationCallback` is a known hazard: if .NET's TLS stack invokes it off the runspace's own thread - plausible for a fresh handshake, such as the one triggered by a mid-session re-authentication request - it can silently crash the whole process with no catchable PowerShell exception, matching the reported symptom exactly. Not confirmed against a live repro (the user could not attach an error, since none is shown), but this is the only IgnoreSSL-bypass code in the entire codebase that deviates from the shared, already-safe pattern. | Exported `Disable-SSLValidation` from `CyberArkComms.psm1` (previously module-private, used only internally by `Invoke-CyberArkAPI`) and switched `Invoke-CustomTestApi.ps1` to call it instead of assigning the raw callback delegate. | No automated test added - this only matters when `IgnoreSSL` is enabled on the active profile, and this module has no existing unit test file (an interactive request/response loop, untested for the same `Show-FieldPrompt`-dependency reason as other interactive-only functions in this codebase). **Needs live verification specifically with `IgnoreSSL` enabled and a token allowed to expire mid-session** — if the crash recurs after this fix, the SSL-callback hypothesis is wrong and this needs further investigation |
| F16 | `APIModules/Custom/Invoke-CustomTestApi.ps1` | Found while using Test API to diagnose a separate live 400 error: a real CyberArk error response (400, `Content-Length: 80`, `Content-Type: application/json`) came back as `ResponseBody = null` in Test API's captured output. Root cause: Windows PowerShell 5.1's `Invoke-WebRequest` already reads the error response stream once internally to populate `$_.ErrorDetails.Message` before the `catch` block runs - by the time this module's own `catch [System.Net.WebException]` block tried to read `$webResp.GetResponseStream()` a second time, the stream was already consumed and returned empty, silently discarding the server's actual error body on every 4xx/5xx response this module has ever captured. | Changed the catch block to prefer `$caughtErr.ErrorDetails.Message` (which PowerShell already populated from the same stream) when non-empty, falling back to a manual stream read only if that's unexpectedly empty. | No automated test added, for the same reason as F15 (no unit test file exists for this interactive module) - **confirmed the fix is needed live** (the null-body repro above), but the fix itself has not yet been re-verified against a real 400 response |
| F17 | `Modules/CyberArkComms.psm1` | Per user request, following the F16 investigation: the live 400 turned out to be a legitimate CyberArk error (`PASWS001W: The account is locked by: [ca_jesse].`), not a bug in `Invoke-AccountsChangeInVault.ps1` - but `Invoke-CyberArkAPI`'s `ErrorMessage` only ever surfaced the bare `ErrorMessage` field, dropping the `ErrorCode` every module's own error text is built from. Since every module already composes its displayed/logged error from `$response.ErrorMessage`, none of them (except Test API, which shows the full raw body separately) ever showed the code. Investigating this also surfaced a real latent bug in `Parse-CyberArkError`: unguarded dot access on the parsed JSON meant a body with only one of `ErrorCode`/`ErrorMessage` (e.g. `{"ErrorMessage":"Not Found"}` with no code) threw `PropertyNotFoundException` under this module's own `Set-StrictMode`, silently discarding both fields instead of just the missing one - caught by the try/catch, but downgrading to a bare `"HTTP <code>"` fallback that lost the message even though it WAS present in the body. | `Parse-CyberArkError` now uses `PSObject.Properties[...]` guards for both fields. `Invoke-CyberArkAPI`'s two error-response-building sites now format `ErrorMessage` as `"<ErrorCode>: <ErrorMessage>"` when a code is present, falling back to the bare message (or `"HTTP <code>"`) otherwise - applied once, in the shared helper, so every module's own error text picks it up automatically with no per-module changes needed. | C29-C32 in `CyberArkComms.Tests.ps1`: code+message combines correctly for both 4xx and 5xx, a body with no `ErrorCode` falls back to the bare message, and a non-JSON body falls back to `"HTTP <code>"` without throwing |
| F18 | `APIModules/Custom/Invoke-CustomTestApi.ps1` | Per user request: the "Query Params" prompt appeared for every HTTP method, even though query parameters are conventionally only meaningful for `GET`. | The prompt is now skipped (query string forced to empty) for any method other than `GET`. | No automated test added, for the same reason as F15/F16 (no unit test file exists for this interactive module) |
| F19 | `Modules/CyberArkComms.psm1` | Per user request: "Error messages for failed requests should include the body information unless it is blank or null" - the F17 fix only covered the structured `ErrorCode`/`ErrorMessage` envelope; a body in any other shape (an IIS HTML error page, or JSON without those exact fields) still fell back to a generic, information-free `"HTTP <code>"` message even though the server sent real content. | `Format-CyberArkErrorMessage` (added for F17) now has a third preference tier: the raw response body, whenever it is non-blank, before falling back to the generic HTTP-status message. | C32 (updated) and new C33 in `CyberArkComms.Tests.ps1`: a non-blank non-JSON body is now included in `ErrorMessage`; a genuinely blank body still falls back to the bare `"HTTP <code>"` message |
| F20 | `APIModules/Safes/Invoke-SafesAdd.ps1`, `Invoke-SafesAddFromTemplate.ps1`, `Invoke-SafesAssignCPM.ps1`, `Manage-Privilege.ps1` | Per user request, three related changes to "screens that ask for a CPM": (1) Add Safe no longer prompts for `Location` interactively (always uses the default `\`); (2) Add Safe's `ManagingCPM` prompt now uses the same numbered picker as Add Safe From Template instead of free text; (3) all three CPM-picker screens now share one CPM source instead of three inconsistent per-module implementations - `Invoke-SafesAddFromTemplate.ps1` previously used only the profile's `CPM_List` (never queried live) and `Invoke-SafesAssignCPM.ps1` previously used only a live query (never fell back to `CPM_List`), a split Architecture.md had recorded as "per explicit direction, not an oversight" - that direction was explicitly superseded by this request. | Added `Get-CpmOptions` to `Manage-Privilege.ps1` (alongside similar shared driver-scope helpers like `Invoke-EntitySearch`): queries live via `GET /API/Users?userType=CPM&componentUser=true`, using that result whenever the call succeeds (even if empty - a real environment state, not a failure), falling back to the profile's `CPM_List` only on failure or a thrown exception. All three modules' own per-module CPM-source functions (`script:Get-ProfileCPMOptions`, `script:Get-SafesCPMOptions`) were deleted in favor of this one shared function. | No automated test added - like `Invoke-EntitySearch`, this class of driver-scope helper has no unit test coverage in this codebase, and `Manage-Privilege.Tests.ps1` has a documented Pester v6.1 hang risk for new `Describe` blocks. Manually verified all four cases (live success with results, live success empty, live failure, live exception) via a standalone `powershell.exe` repro instead. The 7 existing unit tests for the two deleted functions (T32-T35 in `Invoke-SafesAddFromTemplate.Tests.ps1`, A15-A17 in `Invoke-SafesAssignCPM.Tests.ps1`) were removed, since the functions they tested no longer exist |
| F21 | `Modules/CyberArkComms.psm1` | Per user report, live: `?search=` values containing a period fail to match on the CyberArk API - `[Uri]::EscapeDataString` treats `.` as an unreserved character (RFC 3986) and leaves it as a literal period, but these endpoints require it percent-encoded as `%2E` to work. Affects every module that searches by a value that can contain a period - usernames like `domain.user`, addresses/IPs, email-style account names - via `Invoke-EntitySearch`'s picker, `Invoke-AccountsLinkAccount.ps1`, `Invoke-CustomTestConnectivity.ps1`'s vault lookup, the several Platforms modules' by-ID search, and `Invoke-SafesAddFromTemplate.ps1`'s role-prefix group lookup. | `New-CyberArkQuery` now replaces `.` with `%2E` in a value's already-encoded form specifically when the query key is `search` (matched case-insensitively, since `Invoke-EntitySearch`'s Platforms callers use `-SearchParam 'Search'` while most direct callers use lowercase `search`). Applied once, in the shared query-builder every module already routes through via `Invoke-CyberArkAPI`, so no per-module changes were needed. | C34-C36 in `CyberArkComms.Tests.ps1`: a period in a lowercase `search` value is encoded, a period in a capitalized `Search` value is also encoded (case-insensitive key match), and a period in a non-search value (e.g. `filter`) is left alone |
| F22 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Per user request: the output had no way to tell, after the fact, whether a connection attempt used a password supplied directly or one pulled from the vault - and if from the vault, which specific account (Safe + Username) was used. | Added three columns to the result row: `Safe` and `Username` (the vaulted account's `safeName`/`userName`, populated only when a vault lookup actually matched and retrieved a credential - blank otherwise) and `PasswordSource` (`Provided` or `Vault`, set as soon as the password's origin is known, regardless of whether a vault lookup ultimately succeeds). `Resolve-VaultPassword` now returns `SafeName`/`Username` alongside `Password` for this purpose. | Updated TC11-TC12 (`Resolve-VaultPassword`'s new return fields) and TC20, TC21, TC27-TC29 (the three new output columns across the DNS-failure, direct-password, vault-success, and vault-failure paths) in `Invoke-CustomTestConnectivity.Tests.ps1`; also manually verified the full flow end-to-end under real `powershell.exe` strict mode |
| F23 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Reported directly by the user with a full stack trace: `[FATAL] PropertyNotFoundException: The property 'ArgumentList' cannot be found on this object`, crashing every Linux SSH auth attempt. Root cause: `ProcessStartInfo.ArgumentList` (added in .NET Framework 4.6.1) is not reliably usable under PS 5.1's `Set-StrictMode` - reproduced live on this very dev machine (.NET Framework 4.8) too, but as a *different* symptom (the property is present but silently evaluates to `$null` without `Set-StrictMode`; only throws the user's exact `PropertyNotFoundException` once strict mode is active, matching real production conditions since `Manage-Privilege.ps1` always sets it). Neither failure mode can be assumed away by checking the .NET Framework version or via `.GetType().GetProperty(...)` reflection - both looked "available" here despite failing at actual use. | Added `Invoke-ExternalProcessWithTimeout` a runtime probe (a disposable `ProcessStartInfo`, never the real one in use, wrapped in `try/catch` with a null-check) that falls back to the single-string `.Arguments` property with each argument manually quoted per Win32 command-line rules (new `ConvertTo-Win32QuotedArgument` helper) whenever `ArgumentList` isn't safely usable. Probing a separate object avoids ever leaving the real `ProcessStartInfo` in a partially-populated state if usage failed partway through. | New `ConvertTo-Win32QuotedArgument` `Describe` block (TC30-TC34) covering a plain argument, one with a space, one with an embedded quote, a trailing backslash, and an empty string. The manual-quoting fallback's real-child-process behavior was verified manually (not as an automated test - see the module's own code comment) since this dev machine's execution policy blocks running a `.ps1` file from `%TEMP%`, an unrelated sandbox restriction; the actual production code path never does that (it passes an inline command string to `plink`/`pwsh`, not a script file) |
| F24 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Per user request: the interactive Server Type prompt's description said "(or type the name)", inviting the user to type "Windows"/"Linux" when the intent was to select by number. | Changed the description to "Enter 1 for Windows or 2 for Linux." and changed the displayed default to the corresponding number (translating a prior value carried forward from `$Defaults['ServerType']`, e.g. from a CSV template, back to `1`/`2` for display) so the prompt stays number-only even on a repeat prompt. The underlying switch statement still accepts a typed `Linux`/`linux` value as a harmless legacy fallback - not removed, since only the prompt wording was reported as wrong | No automated test - `Get-CustomTestConnectivityInput` is excluded from unit testing for the same `Show-FieldPrompt`-dependency reason as every other interactive-only input function in this codebase |
| F25 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Reported by the user, guessing correctly: the Linux SSH auth test failed with a timeout, suspected to be waiting on host-key confirmation. Reproduced live against a real test host (172.21.20.14, provided by the user): with that host's key removed from `known_hosts`, `Test-LinuxSshAuth`'s PowerShell 7 SSH transport path hung for the full timeout, confirmed to be the interactive "unknown host key, continue connecting?" question having no way to be answered in this non-interactive child process. Separately discovered while verifying the fix: a timeout can *still* happen even with a known host key, because this path spawns `pwsh`/`ssh` with no console at all, and native OpenSSH's password prompt (already documented in this module as unreliable non-interactively) can hang the same way rather than failing fast the way it does with a real console attached - this is a pre-existing, separate limitation, not something this fix could also resolve. | Added `-Options @{StrictHostKeyChecking='no'}` to the `New-PSSession -SSHTransport` call - an OpenSSH `ssh_config` directive that auto-accepts (and still records, for next time) an unrecognized host key instead of asking. Confirmed live: this alone reduced a hanging first-connection attempt to under a second. The timeout `ErrorMessage` was also updated to mention the remaining password-prompt limitation and recommend `plink.exe` for reliable password testing. | No automated test - this is a live-network/live-process code path already excluded from unit testing per this module's own established convention (mocked in `Invoke-CustomTestConnectivity.Tests.ps1`); verified manually against the real test host instead, including confirming the fix does not regress the already-known-host case |
| F26 | `Manage-Privilege.ps1`, `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Per user request: the single-interactive-run auto-saved CSV for Test Connectivity was always named just `"Test Connectivity <date>.csv"`, so testing several servers one at a time in the same session would silently overwrite the same file each time. | Added a new optional `ModuleMeta.CsvFilenameField` (a generic, opt-in mechanism - not hardcoded to this one module by name) naming an `InputData` column whose value, when present and non-blank, is appended to the auto-saved filename. `Invoke-ActionModule`'s CSV-save block reads it via bracket notation (most modules don't declare it) and builds e.g. `"Test Connectivity - 172.21.20.14 <date>.csv"`. Only `Invoke-CustomTestConnectivity.ps1` declares it (`CsvFilenameField = 'Address'`) - other modules with their own `Address` column (`Invoke-AccountsAdd.ps1`, `Invoke-AccountsUpdate.ps1`) are unaffected, since they don't opt in. | Manually verified the filename-building logic in isolation (including that a module without the field declared, or a blank field value, is unaffected) - `Invoke-ActionModule`'s CSV-save block is not unit-tested (interactive driver code, same as `Invoke-EntitySearch` and similar) |
| F27 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Per user report: even with F25's host-key fix, a real Linux SSH auth attempt via the PS7 SSH transport path still timed out - confirming live the CAVEAT this module already documented (native OpenSSH cannot reliably submit a password non-interactively without a console). The user installed `plink.exe` at the project root and asked for it to be found there, and (mid-fix) also asked for it to be checked in the standard PuTTY install directories. | `Test-LinuxSshAuth` now tries plink FIRST (previously it was only used as a fallback when `pwsh` wasn't found, so a present-but-untried `pwsh` always won). New `Find-PlinkExecutable` helper checks, in the order the user specified: PATH, then the project root (`..\..\plink.exe` relative to this file), then `%ProgramFiles(x86)%\PuTTY\plink.exe`, then `%ProgramFiles%\PuTTY\plink.exe` (environment variables, not hardcoded drive letters). Verified live against the real test host with plink's own host-key cache genuinely empty (no `HKCU:\Software\SimonTatham\PuTTY\SshHostKeys` existed yet): unlike the PS7 path, plink correctly fails in well under a second with a clear, actionable "host key is not cached... Connection abandoned" message rather than hanging - confirmed PuTTY has no CLI equivalent to `StrictHostKeyChecking=no` (`-hostkey` requires the exact key already known), so this module doesn't try to work around that; the message it already produces tells the user what to do. | New `Find-PlinkExecutable` `Describe` block (TC36-TC39, mocking `Get-Command`/`Test-Path`/`Resolve-Path`): found on PATH short-circuits before checking anything else, found at the project root, found in Program Files (x86), and not found anywhere returns `$null` |
| F28 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Discovered while running the first fully live end-to-end test (real credentials against 172.21.20.14, per user-provided test account): `Resolve-ConnectivityTarget` aborted the *entire* connectivity test - before any port or auth check ran - because the target IP has no reverse-DNS (PTR) record, which is completely normal for an internal/test host and unrelated to whether the address is reachable. `[System.Net.Dns]::GetHostEntry` throws "No such host is known" for a literal IP with no PTR record, and the function treated any exception as a hard failure regardless of address type. | For a literal IP specifically, a `GetHostEntry` failure is now treated as a successful resolution with no hostname available (`FQDN=''`, `IPAddress=<the literal address>`) rather than aborting - the address was already fully usable without any DNS lookup at all. A name that fails to resolve is unchanged (still a hard failure, since there would be nothing to connect to). | New TC40 in `Invoke-CustomTestConnectivity.Tests.ps1`, using `192.0.2.123` (RFC 5737 TEST-NET-1, guaranteed to never have a PTR record) for a deterministic, portable repro of the live bug |
| F29 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Also discovered during the same live end-to-end test: plink correctly refuses an unrecognized host key rather than hanging (F27), but that meant the *first* connection to any new host still failed outright, requiring a manual one-time trust step - undermining the tool's purpose as a quick multi-host connectivity tester. Confirmed live that plink's "host key is not cached" failure always includes the exact fingerprint it computed. | `Test-LinuxSshAuth` now parses that fingerprint out of plink's failure output and retries once with `-hostkey <fingerprint>` automatically - the same trust-on-first-use tradeoff already made for the PS7 path (`StrictHostKeyChecking=no`), applied to plink using its own reported key rather than blindly accepting anything. Verified live end-to-end against the real test host, starting from a genuinely empty PuTTY host-key cache (confirmed no `HKCU:\Software\SimonTatham\PuTTY\SshHostKeys` existed beforehand): the retry succeeded automatically, and a subsequent run (now legitimately cached) succeeded on the first attempt. Also verified live that a wrong password still fails cleanly in ~3 seconds with an accurate "Access denied" message, not a false retry. While implementing this, found and fixed a second, real bug: the call site used `script:Find-PlinkExecutable` instead of a bare name, silently making it unmockable in tests (the exact `script:`-qualified-call Pester gotcha already documented in `Lessons-Learned-PowerShell-Pester.md`) - changed to match the bare-name convention already used for every other helper call in this file. | New `Test-LinuxSshAuth - plink trust-on-first-use retry` `Describe` block (TC41-TC43): an unrecognized host key is retried once with the parsed fingerprint and the retry's result is returned; a non-host-key failure (wrong password) is not retried; a host-key-shaped failure with no parseable fingerprint is not retried either. **This is the first fix in this module confirmed fully working end-to-end against a real target with real credentials - `AuthStatus: Success` for a genuine SSH login, not just a mocked or partial confirmation** |
| F30 | `Tests/Unit/Invoke-SafeMembersAdd.Tests.ps1`, `Tests/Unit/Invoke-SafesAddFromTemplate.Tests.ps1` | Surfaced by a routine full-suite run before an unrelated docs-only commit: 7 pre-existing failures (`PropertyNotFoundException: 'Count'`), all already on the branch from earlier work - `Get-SafeMembersSearchInOptions` (MA24/MA27/MA28) and `Invoke-SafesAddFromTemplate` (T08/T23/T27/T28). In every case, the assertion's right-hand side happened to produce exactly one item (the single Vault-only fallback option, or a `Where-Object` filter matching one `Results` row) - PowerShell's pipeline unwraps a single output item to a bare scalar rather than a one-element array, and a scalar has no `.Count` under `Set-StrictMode`. This was a test-only bug: the real call site (`Invoke-SafeMembersAdd.ps1`) already wraps the same call in `@(...)`, so production behavior was never affected. | Wrapped all 7 affected assertions/assignments in `@(...)`, matching the production call site's existing convention. No product code changed. | All 1052 unit tests pass after the fix; added Lessons-Learned Section 36 documenting the pattern so future tests wrap `.Count`-bound expressions defensively from the start |
| F31 | `Invoke-SafesAdd.ps1`, `Invoke-SafesUpdate.ps1`, `Invoke-SafesUnassignCPM.ps1`, `Invoke-SafesAssignCPM.ps1`, `Invoke-SafeMembersRemove.ps1`, `Invoke-GroupsDelete.ps1`, `Invoke-GroupsUpdate.ps1`, `Invoke-GroupsAdd.ps1` | Discovered during a full live end-to-end test pass (all ~65 modules called directly against a real Self-Hosted PVWA lab tenant, per user request): `Invoke-SafesAdd` crashed live with `PropertyNotFoundException: 'ManagingCPM' cannot be found` the moment `InputData` omitted that optional key entirely (as opposed to including it blank) - `$InputData.ManagingCPM` dot notation on a hashtable throws under `Set-StrictMode -Version Latest` when the key is *absent*, the same class of bug this project already fixed once (2026-08-15, "27 API modules", `$Defaults.Key` → `$Defaults['Key']`) but that earlier pass never touched these modules' own direct use of `$InputData`. A systematic grep for `$InputData\.[A-Za-z]` across every module found 9 real occurrences (a `$InputData.ContainsKey(...)` method call is safe and was left alone; call sites already guarded by a same-expression `ContainsKey(...) -and ...` check were also left alone). | Converted every unguarded `$InputData.<Key>` access in the 9 affected files to bracket notation `$InputData['<Key>']`. No behavior change for callers who already include every key (blank or not) - only callers who omit an optional key outright, like this live-test harness and any CSV row missing a column, are affected. | All 1058 unit tests still pass unmodified - existing fixtures always supplied every key, which is exactly why this bug was invisible to the test suite despite being trivially reachable from real CSV input. Added Lessons-Learned Section 37 |
| F32 | `Invoke-PlatformsCopy.ps1`, `Invoke-PlatformsEnable.ps1`, `Invoke-PlatformsDisable.ps1`, `Invoke-PlatformsRemove.ps1`, `Invoke-PlatformsRename.ps1`, `Invoke-PlatformsSetPSMConfig.ps1` | Also found during the live test pass: all 6 modules resolve a target `PlatformID` string to CyberArk's internal numeric ID via `GET /API/Platforms/Targets?search={PlatformID}`, assuming (per an in-code comment) that the response is a bare array. Confirmed live it is not: the real response is `{"Platforms": [...], "Total": N}`, so every one of these modules' client-side match against `$_.PlatformID` silently matched nothing and reported "Target platform not found" even for a platform confirmed to exist (`WinServerLocal`, live-verified via `Invoke-PlatformsGet`). Separately and independently confirmed live: the `search` query parameter does not match against `PlatformID` at all - searching for the exact string `WinServerLocal` returned zero results even though `GET /API/Platforms/Targets` unfiltered clearly lists it. | All 6 modules now fetch `/API/Platforms/Targets` unfiltered (the `search` param removed, since it doesn't work for this purpose) and unwrap the `Platforms` property when present, falling back to treating `.Data` as a bare array otherwise for backward compatibility with existing mocks. Corrected an accompanying code comment in `Invoke-PlatformsEnable.ps1`/`Invoke-PlatformsDisable.ps1` that had stated the opposite (incorrect) assumption as the reason for a different design choice elsewhere in the same files. | Added one new regression test per module (PC10/PE10/PD10/PR10/PRN10/PPSM10) asserting resolution succeeds against the real `{Platforms:[...], Total:N}` shape; all 1059 unit tests pass (existing tests, which mocked the old bare-array assumption, still pass unchanged since the fix falls back to that shape too) |
| F33 | `Invoke-SafesUpdate.ps1`, `Invoke-SafesAssignCPM.ps1`, `Invoke-SafesUnassignCPM.ps1` | Also found live: `PUT /API/Safes/{safeName}` returned HTTP 400 with an empty response body (no error detail at all) for every field combination tried, including hand-crafted raw requests matching psPAS's `Set-PASSafe.ps1` exactly. Isolated via a raw-HTTP diagnostic script that tried the body with and without a `SafeName` field: only the version that included `SafeName` in the PUT body (in addition to the URL) succeeded. This is a real, live-observed divergence from psPAS's own assumption (`Format-PutRequestObject`'s keep-list never includes `SafeName`) - on this PVWA version, the PUT body must include it too. | Added `SafeName = $safeName` to the PUT body in all three modules. | Manually verified live end-to-end: `Invoke-SafesUpdate`, `Invoke-SafesAssignCPM`, and `Invoke-SafesUnassignCPM` all now return HTTP 200 against the real tenant, where they previously failed 100% of the time. All 1059 unit tests still pass (existing mocks don't assert on body contents in a way this change affects) |
| F34 | `Invoke-SafesAddFromTemplate.ps1` | Also found live: creating a safe from a template whose member list includes the template safe's own creator (which CyberArk always includes as an implicit member with owner-level access, confirmed live via a safe's `creator` field matching an actual row in its member list) failed with `HTTP 403 Forbidden` on the one member CyberArk itself refuses to let be explicitly (re-)granted - the new safe already grants its own creator the same implicit access automatically. This member is not role-prefixed, so it was never excluded by the existing role-prefix or `$script:ExcludedTemplateMemberNames` logic. | The member-copy filter now also excludes any member whose name matches the template safe's own `creator.name` (read from the same GET response already fetched for the safe's settings), the same way it already excludes role-prefixed and globally-excluded names. | Added T09c to `Invoke-SafesAddFromTemplate.Tests.ps1`, confirming a creator-matching member is excluded from the copy while other regular members are still copied; all 1059 unit tests pass |
| F35 | `Invoke-SafesDelete.ps1` | Per user direction, following up on K10 (three safes stuck unable to delete with HTTP 409 despite showing zero accounts, likely Safe History Retention): rather than just failing, the module now offers a rename-instead fallback when the delete gets a 409. | On a 409, explains the likely cause and asks (`Read-Host`, so it works standalone in unit tests and doesn't require a driver-scope helper) whether to rename the safe to `1_DEL_<SafeName>` instead - truncated so the total stays at or under CyberArk's 28-character safe name limit - carrying forward the safe's other settings via the same full-replace `PUT` pattern as `Invoke-SafesUpdate.ps1` (including `SafeName` in the body per F33). If a description already exists, appends `" \| Delete requested <yyyy-MM-dd>"` to it; a safe with no description is left without one. A successful rename counts as a `Success` (`Renamed=$true, Deleted=$false`) rather than a `Failure`, since the operational goal - getting the unwanted safe out of normal use - was achieved. If the user declines, or the rename `PUT` itself also fails, the original 409 is still reported as a `Failure` exactly as before (with both error messages if the rename was attempted). Note: a CSV batch run deleting several safes will pause on this prompt if any one of them hits a 409, since there's no separate interactive-vs-batch signal available to this function. | Added D19-D24 to `Invoke-SafesDelete.Tests.ps1` covering acceptance, decline, name truncation, description append/no-append, and rename-itself-failing. Live-verified against all 3 stuck safes from K10: `ZZ-ClaudeTest-Safe1` and `ZZ-ClaudeTest-DiagSafeLink` were both successfully renamed (confirmed via a follow-up `GET` on the new name showing the appended description date); `ZZ-ClaudeTest-DiagSafeLink2` returned 409 on the rename `PUT` too and remains stuck - see K10's updated entry |
| F36 | `Auth\CyberArk.Auth.ISPSS.psm1` | Per user request, reviewing `C:\Code\References\CyberArk ISPSS\` to verify the ISPSS auth methods are ready for testing: `Invoke-ISPSSClientCredentials` unconditionally read `$resp.refresh_token` after a successful `POST /oauth2/platformtoken` call. CyberArk's own "Create an API token" reference documents this exact response as `{ access_token, token_type, expires_in }` only - no `refresh_token` field (client_credentials grants typically don't get one). Confirmed directly with an isolated repro: dot-accessing a genuinely absent JSON property throws `PropertyNotFoundException` under `Set-StrictMode -Version Latest` - meaning **every single `ClientCredentials` login would have crashed immediately after a successful token request**, making this the primary documented ISPSS automation auth method completely non-functional. The identical unguarded pattern (`$resp.expires_in`/`$resp.refresh_token`/`$resp.access_token`) also existed in `Update-ISPSSAuthToken`'s refresh_token-grant branch. Separately noted but not changed (insufficient documentation to act on): that refresh branch calls `/oauth2/platformtoken` again with `grant_type=refresh_token`, but CyberArk's rate-limiting reference lists `/oauth2/refreshplatformtoken` as a distinct, separate endpoint - this is now moot in practice since F36's fix means a ClientCredentials token never carries a `refresh_token` to trigger that branch at all, but flagged in-code and in AI09 in case some tenant configuration ever does return one. | Guarded every field with `PSObject.Properties[]` before dot-accessing it, in both `Invoke-ISPSSClientCredentials` and `Update-ISPSSAuthToken`'s refresh branch, matching this codebase's established defensive pattern (e.g. `Resolve-IdentityTenantURL`'s own `identity_user_portal` check earlier in the same file). | Added `Tests\Unit\CyberArk.Auth.ISPSS.Tests.ps1` (ISPSS-CC01-CC06) - the first automated coverage this module has ever had - confirming no exception is thrown against the documented response shape, correct field mapping, the exact endpoint/body called, graceful handling if a `refresh_token` *is* present (defensive), and a missing `expires_in` falling back to a 3600s default. All 1071 unit tests pass. Not yet confirmed against a real ISPSS tenant - added AI01-AI12 as a new ISPSS Auth manual test section (see below) |
| F37 | `Modules\CyberArkComms.psm1` | Per user request, adding platform download support: `Invoke-CyberArkAPI` decided JSON-vs-binary purely by trying `ConvertFrom-Json` and catching failure - it never inspected the response's actual `Content-Type`/`Content-Disposition` headers, and never accounted for what `.Content`'s real .NET type is for a binary response. Confirmed via a local `HttpListener` test under real Windows PowerShell 5.1 (not assumed): `.Content` is already a correct `byte[]` for a properly-labeled binary `Content-Type`, but becomes a **lossily, irreversibly decoded string** when `Content-Type` implies a text charset even though the body is actually binary - no encoding trick recovers the original bytes once that's happened. `RawContentStream`, however, held the exact original bytes in every case tested, including the corrupted-string one - a more robust source than even psPAS's own `Get-PASResponse.ps1`, which has no equivalent fallback and would suffer the same corruption. | `Invoke-CyberArkAPI` now reads `Content-Type`/`Content-Disposition` explicitly: `.Content` is used directly when `Invoke-WebRequest` already returned it as `byte[]`; `RawContentStream` is read instead whenever a `Content-Disposition` header appears on a non-JSON response (the mislabeled-file case). Added `DataType='File'` (already documented, never implemented, in `Interfaces.md`) and a new `SuggestedFileName` field (from `Content-Disposition`) to the response object. | Added C37-C40 to `CyberArkComms.Tests.ps1` covering a correctly-labeled binary response, a mislabeled `text/html` response with a `Content-Disposition` header (confirming `RawContentStream` recovery), binary content with no `Content-Disposition`, and confirming normal JSON responses are unaffected. Also fixed all 11 pre-existing inline mock response objects in that file, which had no `Headers` property at all (a gap this fix exposed, not created) and would otherwise have thrown for every existing test. All 1088 unit tests pass. Added Lessons-Learned Section 39 |
| F38 | `APIModules\Platforms\Invoke-PlatformsExport.ps1` (new module) | Per user request: added platform download/export support, the counterpart to the existing `Platforms/Import`, matching psPAS's `Export-PASPlatform.ps1`. Supports all 4 of its target types (`PlatformID`, `RotationalGroupID`, `DependentID`, `GroupPlatformID`) via exactly-one-of-four `InputData` columns, auto-saving to the profile's `OutputFolder` (per user direction) using the filename CyberArk suggests, or a generated fallback name. Unlike the other Platform write actions, this endpoint takes the target's own string ID directly - no numeric-ID resolution via `/API/Platforms/Targets` is needed (confirmed directly from psPAS). | New module built on F37's `Invoke-CyberArkAPI` fix. | Added `Invoke-PlatformsExport.Tests.ps1` (PE01-PE13) covering all 4 endpoint variants, validation (zero or multiple ID columns supplied), API failure, an unexpected non-File success response, a save failure, and WhatIf. **Live-verified end-to-end for the `PlatformID` case** against a real Self-Hosted tenant: the downloaded file was byte-for-byte a valid `.zip` (confirmed by actually opening it with `System.IO.Compression.ZipFile`), containing the platform's real `Policy-WinServerLocal.xml`/`.ini` files. The other 3 variants are unit-tested against psPAS's documented endpoint shapes only - no existing aPePAS module can discover a real rotational group/dependent/group-platform ID on this tenant to live-test against |
| F39 | `APIModules\Custom\Invoke-CustomExportPlatformDetails.ps1` (new module) | Per user request: a new Custom-category bulk report that downloads every *active* platform (any type) via F38's export endpoint and builds a spreadsheet summarizing each platform's `Policy-<id>.ini`/`.xml` contents, plus a column listing any bundled files that are not the two policy files (a `META-INF` folder, if present, excluded from that list per explicit user direction). Confirmed live that CyberArk's `/API/Platforms` list response nests fields (`id`, `active`, `platformType`, etc.) under a `general` sub-object, not at the root - discovered by dumping a raw list entry after an initial `PropertyNotFoundException`. Also confirmed live, contrary to an initial assumption, that the list endpoint's `platformType` field (`"regular"`/`"group"`) is unrelated to psPAS's separate `GroupPlatformID` concept: a `platformType="group"` platform (`SampleSSHKeyGroup`) exports successfully via the same standard `/API/Platforms/{id}/Export` endpoint used for every other platform (the dedicated `/API/Platforms/Groups/{id}/Export` endpoint returned HTTP 400 for the same ID) - so this module only ever needs the single standard endpoint regardless of platform type. | Each platform's INI is parsed into `Ini.<Key>` (top-level) / `Ini.<Section>.<Key>` (e.g. `[ExtraInfo]`) columns and its XML into `Xml.<Field>` columns, using XPath throughout (never dot-notation) per this project's established single-element-collapse/missing-attribute strict-mode avoidance pattern. Because different platform types have very different, non-overlapping settings, columns are built as the union of every key seen across all active platforms, with a platform lacking a given setting left blank on its row (`Export-Csv` requires uniform columns). A single per-platform export failure (e.g. an HTTP 500, observed live for one inactive platform though outside this module's active-only scope) is recorded as a non-fatal `Failure` and the rest continue processing. | Added `Invoke-CustomExportPlatformDetails.Tests.ps1` (PPD01-PPD11), including a `New-TestPlatformZipBytes` helper that builds real in-memory `.zip` archives via `System.IO.Compression.ZipArchive` so the tests exercise the actual zip-extraction/INI/XML parsing code, not a mocked-around shortcut. All 1099 unit tests pass. **Live-verified end-to-end** against the real Self-Hosted tenant: 10 of 15 platforms were active and all 10 processed successfully, producing 104 dynamic columns; spot-checked via CSV that type-specific settings (e.g. `Ini.ExtraInfo.Port`, `Ini.KeySize`) populate only for the platform types that actually have them and blank-fill elsewhere. No real example of an extra bundled file or a `META-INF` folder was found on this tenant to confirm the `OtherFiles`/exclusion logic against - that part is implemented exactly per spec and unit-tested only |
| F40 | `APIModules\Policies\Invoke-PoliciesGetMasterPolicy.ps1`, `APIModules\Custom\Invoke-CustomExportAll.ps1` | Per user request: "Within CyberArk's Self-Hosted and Privilege Cloud have a master policy. Is there a way to pull this information? I would like to include it in the Export All." Research confirmed psPAS's `Get-PASMasterPolicy.ps1` explicitly asserts `-SelfHosted` with no ISPSS branch, and no local CyberArk reference material (including the ISPSS API folder) documents a Privilege Cloud master-policy-equivalent endpoint - but nothing in those sources confirms Privilege Cloud actually lacks one either, it is simply undocumented (already flagged as a gap, not previously investigated for ISPSS, in `psPAS-Comparison-Review-2026-09-02.md`). Per explicit user direction, chose to try the existing Self-Hosted endpoint on ISPSS too rather than leave it blocked, since a failure there was already handled gracefully (non-fatal `Failure`, `IsFatal` only on 401/0) before this change. Separately, `Export-All` only auto-discovers `List`/`ListAuthMethods` actions, so a single-row settings snapshot like Master Policy needed an explicit way to opt in. | `Invoke-PoliciesGetMasterPolicy.ps1`'s `SupportedSystems` changed from `@('SelfHosted')` to `@('ISPSS', 'SelfHosted')` - `Invoke-PoliciesSetMasterPolicy.ps1` (a write, not a read) was deliberately left Self-Hosted-only, since mutating tenant-wide policy on an unconfirmed ISPSS endpoint is a materially higher risk than reading it. Added a new generic `ModuleMeta.IncludeInExportAll` opt-in flag (the read counterpart to the existing `ExcludeFromExportAll` opt-out) - `Invoke-CustomExportAll.ps1`'s module-discovery filter now also matches any module declaring it, not just `List`/`ListAuthMethods` actions. `Invoke-PoliciesGetMasterPolicy.ps1` sets `IncludeInExportAll = $true`. | Added PGMP08 (`IncludeInExportAll` is `$true`) and PGMP09 (a 404 - e.g. from an ISPSS tenant with no such endpoint - is a non-fatal `Failure`, not `IsFatal`) to `Invoke-PoliciesGetMasterPolicy.Tests.ps1`; updated PGMP02 for the dual-use `SupportedSystems`. Added 2 new cases to `Invoke-CustomExportAll.Tests.ps1` confirming a module with `IncludeInExportAll = $true` is discovered despite a non-`List` action, and one without it is not. All 1103 unit tests pass. **Live-verified end-to-end** against the real Self-Hosted tenant: running `Export All` with only `Policies/GetMasterPolicy` loaded correctly discovered and ran it, saving a real `Export_PoliciesGetMasterPolicy.csv` with real policy values. **Update (2026-09-04, same day):** the user subsequently verified live against a real Privilege Cloud tenant that no Master Policy equivalent endpoint exists on ISPSS at all - confirming the earlier "undocumented, not necessarily absent" uncertainty resolves to "confirmed absent." The user judged the current behavior (graceful non-fatal `Failure` there, `SupportedSystems` left dual-use) fine as-is, so no further code change was made |

| F41 | `APIModules\Accounts\Invoke-AccountsLinkAccount.ps1`, `Invoke-AccountsUnlinkAccount.ps1` | Not a code bug: this project had previously logged `POST /API/Accounts/{id}/LinkAccount` and its bulk sibling `POST /API/Accounts/Link/Bulk` as an unfixable live-tenant limitation, since both endpoints returned HTTP 404 against a freshly confirmed-to-exist account, on both endpoint casings, with a raw HTTP request matching psPAS's exact documented shape. | No code change - the user has since retested live and confirmed both the single-account `LinkAccount` action and the bulk `Link/Bulk` endpoint now work correctly against the real tenant. The most likely explanation is a transient environment-side condition (e.g. a CPM/plugin state or a since-resolved tenant issue) rather than anything aPePAS was doing wrong, consistent with this being a plain, unmodified request matching psPAS's documented shape both times. | No test change needed - `Invoke-AccountsLinkAccount.Tests.ps1`/`Invoke-AccountsUnlinkAccount.Tests.ps1` already mock the success path and were unaffected either way. |
| F42 | `APIModules\Groups\Invoke-GroupsAddMember.ps1`, `Invoke-GroupsRemoveMember.ps1` | Per user report: "For group member add. In the body, the memberid is actually the username. So instead of 32 it would be ca_jesse." This project had previously logged `POST /API/UserGroups/{id}/Members` as an unfixable live-tenant limitation, tried across payload shapes, field casings, and member types - all identical unconditional HTTP 400. The real root cause was semantic, not structural: `Invoke-GroupsAddMember.ps1` sent `memberId = [int]$memberId`, treating the field as a numeric user ID, but CyberArk's API expects the actual username string there despite the field's name. Confirmed against psPAS's own `Add-PASGroupMember.ps1`, which types the equivalent parameter as `[string]$memberId` (never numeric), and `Remove-PASGroupMember.ps1`, whose equivalent `$Member` parameter carries `[Alias('UserName')]`. | Removed the `[int]` cast in `Invoke-GroupsAddMember.ps1` - `memberId` is now sent as the plain username string. Updated both modules' `ModuleMeta.Description`/`InputSchema`/interactive-prompt text to say "username" instead of "numeric user ID", and changed their "search by username" fallback to return `-IdProperty 'username'` instead of `'id'` (previously, choosing to search rather than type a value would have looked up the right user but returned the wrong field). `Invoke-GroupsRemoveMember.ps1`'s DELETE path segment already treated `MemberID` as a plain string end-to-end, so no functional code change was needed there, only the corrected description/prompt/search fix. | Updated `Invoke-GroupsAddMember.Tests.ps1` (GAM07/GAM08, plus all `MemberID` fixtures) to use a realistic username instead of a numeric-looking string, so the tests can't pass merely because a numeric string still parses as `[int]`. Updated `Invoke-GroupsRemoveMember.Tests.ps1` fixtures the same way. All 1104 unit tests pass. **Live-verified end-to-end** against the real Self-Hosted tenant: created a temporary test group, added a real username as a member (`POST` returned HTTP 201, previously always HTTP 400), confirmed membership, removed the member (`DELETE` returned HTTP 204), and deleted the test group to clean up. |
| F43 | `APIModules\Groups\Invoke-GroupsGetMembers.ps1` | Found incidentally while live-verifying F42: `GetMembers` reported "Members retrieved: 0" for a group that had just been confirmed (via `RemoveMember` succeeding) to have exactly 1 member. The member-mapping loop dot-accessed `$m.id`, `$m.username`, `$m.userType`, and `$m.componentUser` unconditionally; a raw dump of the live response showed a real member entry is only `{"username": "...", "id": ...}` - no `userType` or `componentUser` at all, with or without `includeMembers=true`. Dot-accessing the two absent fields threw `PropertyNotFoundException` under `Set-StrictMode`, caught by the surrounding `try/catch` and silently recorded as a `Failure` instead of a `Result` row - explaining the "0 members" despite a real member existing. | Guarded all 4 field accesses with `PSObject.Properties[...]` existence checks (this codebase's established defensive pattern), defaulting `UserType`/`ComponentUser` to `$null` when absent rather than assuming psPAS's documented shape is always complete. | Added GM17 to `Invoke-GroupsGetMembers.Tests.ps1`, using a member object shaped exactly like the real live response (`{id, username}` only) under `Set-StrictMode -Version Latest`, confirming no crash and correct `$null` defaults for the missing fields. All 1104 unit tests pass. **Live-verified end-to-end**: re-ran the same live test group from F42 and confirmed `GetMembers` now correctly reports "Members retrieved: 1" with the right `MemberID`/`Username` values. |
| F44 | `APIModules\Safes\Invoke-SafesAdd.ps1`, `Invoke-SafesUpdate.ps1` | Phase 3 (Validation hardening) of `aPePAS-Improvement-Plan-2026-09-02.md`: both modules only checked that `SafeName` was non-empty before calling the API, letting an oversized or reserved-character name reach CyberArk as a late, unclear server error instead of failing fast client-side. psPAS's `Add-PASSafe.ps1`/`Set-PASSafe.ps1` both declare `[ValidateLength(0, 28)]` on `SafeName`; the reserved-character/leading-whitespace rule is the Vault's own documented naming restriction, not something psPAS itself validates client-side. | Both modules now reject a `SafeName` longer than 28 characters, one with leading whitespace, or one containing any of `\ / : * < > " . \|` before ever calling the API - checked against the raw (untrimmed) input for the whitespace case specifically, since trimming first would silently accept what the Vault itself rejects. Updated both modules' `InputSchema`/interactive-prompt descriptions to state the rule. `Invoke-SafesAdd.ps1` 1.2.0 -> 1.3.0, `Invoke-SafesUpdate.ps1` 1.1.1 -> 1.2.0. | Added A21-A24 to `Invoke-SafesAdd.Tests.ps1` (over-length, reserved character, leading whitespace, and exactly-28-chars passing through) and U18-U20 to `Invoke-SafesUpdate.Tests.ps1` (the same three failure cases). All 1118 unit tests pass. Not yet live-verified - no live call was made this session |
| F45 | `APIModules\Applications\Invoke-ApplicationsAdd.ps1` | Phase 3 (Validation hardening) of `aPePAS-Improvement-Plan-2026-09-02.md`: `AccessPermittedFrom`/`AccessPermittedTo` were parsed with `[int]::TryParse` but never range-checked, so a value like `32400` (a leftover epoch-seconds-shaped input from before this module's schema settled on hour-of-day) would reach the API as-is; the error text and surrounding comments still called these fields "epoch seconds" even though the module's own `InputSchema`/prompts already documented them as hour-of-day (0-23) values, per psPAS's `Add-PASApplication.ps1` `[ValidateRange(0,23)]`. `AppID`, `Description`, `BusinessOwnerFName`, and `BusinessOwnerPhone` had no length/charset checks at all, matching psPAS's `[ValidateLength]`/`[ValidateScript]` gaps identified in the 2026-09-02 comparison review. | Added a 0-23 range check to both `AccessPermittedFrom` and `AccessPermittedTo` (alongside the existing `TryParse` check) and corrected the "epoch seconds" wording in comments and error text to "hour-of-day". Added length/charset validation: `AppID` 1-127 chars and no `&` (matching psPAS's `ValidateScript`), `Description` <=99 chars, `BusinessOwnerFName` <=29 chars, `BusinessOwnerPhone` <=24 chars - each a non-fatal per-item `Failure`, consistent with this module's existing validation-failure pattern. Updated `InputSchema`/interactive-prompt descriptions to state the limits. Version 1.1.0 -> 1.2.0. | Updated the existing "passes valid numeric AccessPermittedFrom/To through" test to use in-range hour values (it previously used `32400`/`61200`, which the new range check now correctly rejects). Added 2 new range-violation tests, 2 `AppID` tests (over-length, ampersand), 1 `Description` test, and 2 `BusinessOwnerFName`/`BusinessOwnerPhone` tests to `Invoke-ApplicationsAdd.Tests.ps1`. All 1118 unit tests pass. Not yet live-verified - no live call was made this session |
| F46 | `Modules\CyberArkComms.psm1` | Per user request ("Generalize pagination"): Phase 4 of `aPePAS-Improvement-Plan-2026-09-02.md`. `Invoke-CyberArkAPI`'s pagination logic only accumulated results when the response JSON exposed one of a hardcoded property list (`value`, `Safes`, `Members`, `Accounts`, `Users`, `Platforms`, `Groups`), duplicated at two separate call sites (per-page accumulation and final-page merge). Every endpoint in use today happens to match one of those names, so this had never caused a visible bug - but a future endpoint (e.g. a Phase 2-style addition) whose response used an unanticipated collection name would silently return only its first page with no error, since neither `$collection` nor the merge target would ever be found. | Added `Find-CyberArkCollectionProperty`, a new private helper: tries the same short known-name list first (preserving exact existing behavior for every endpoint already in use, since psPAS's own `Get-NextLink.ps1` - checked directly for this - takes the identical layered approach: known names first, generic array-property discovery as the fallback), then falls back to the first property on the response object whose value is an array. Both of `Invoke-CyberArkAPI`'s hardcoded-list loops now call this one shared helper instead of duplicating the list. The merge step re-detects independently from the final page's data object (not by reusing the per-page loop variable across `do/while` iterations), matching the original code's structure and avoiding any risk of a stale property name from an earlier page. | Added C41 (a made-up `Widgets` collection property, not in the known list, correctly paginates across 3 pages via the dynamic fallback) and C42 (single-page response with the same unrecognized property name returns correctly) to `CyberArkComms.Tests.ps1`. All 1120 unit tests pass, including the pre-existing C26-C28 pagination tests (`value`-keyed responses), confirming no behavior change for existing endpoints. Not yet live-verified - every endpoint currently in production use already matches the known-name fast path, so this only changes behavior for an endpoint that doesn't exist yet |
| F47 | `APIModules\SafeMembers\Invoke-SafeMembersAdd.ps1` (v1.4.0), `Invoke-SafeMembersUpdate.ps1` (v1.2.0) | Per user request: supersedes Phase 5 of `aPePAS-Improvement-Plan-2026-09-02.md`, which called for only a documentation callout noting that aPePAS's `ReadOnly` SafeMembers permission-role preset (list/audit/view only) is not equivalent to PVWA's/psPAS's own built-in `ReadOnly` role (which grants `retrieveAccounts`) - same name, different behavior. The user asked for an actual rename instead of just documenting the collision. | Renamed the preset from `ReadOnly` to `ReadOnlyStrict` throughout both modules: `InputSchema`/interactive-prompt text, the default `$permissionRole` value, the numbered role menu, and each switch's fallback/case values. `Get-PermissionSet` in both modules has no explicit `case` for the old name - it was always handled by the `default` branch alongside any other unrecognized role string - so the old literal `ReadOnly` (e.g. in a saved CSV or profile default) still falls through to the identical `default` branch and produces the exact same permission set with no migration needed. Documented the naming rationale in-code (a comment on each module's `default` case) and in `README.md` (new Features bullet) and `Docs\User-Guide.md` (new Troubleshooting entry). | Updated `Invoke-SafeMembersAdd.Tests.ps1`'s MA11 fixture/name to `ReadOnlyStrict` and added MA11a, confirming the legacy literal `ReadOnly` still resolves to the identical permission set (`ListAccounts`/`ViewAuditLog`/`ViewSafeMembers` true, `RetrieveAccounts` false). `Invoke-SafeMembersUpdate.Tests.ps1` needed no fixture changes - its default test fixture already used `EndUser`, not the renamed preset. All 1121 unit tests pass. Not live-verified this session |
| F48 | `Auth\CyberArk.Auth.Common.psm1` (`Import-WebView2Assembly`) | Per user report, live: attempting `SSO` (ISPSS) authentication failed with `Microsoft.Web.WebView2.WinForms.dll not found`. Confirmed on the user's machine that the file genuinely didn't exist anywhere - not in `Auth\`, not in a NuGet cache - while the underlying Edge WebView2 Runtime itself (the browser engine, a separate requirement) was already installed (confirmed via the `EdgeUpdate\Clients\{F3017226-...}` registry key, v153.0.4234.46). Separately, while fixing this, found the error message's own suggested remedy is a dead end for a normal user: `-WebView2AssemblyPath` is a parameter on `Import-WebView2Assembly`/`Invoke-WebView2Window` and the SAML/OIDC/SSO auth functions, but `Manage-Privilege.ps1` never threads it through any profile field or launch parameter - it's unreachable except by calling the `Auth` functions directly. | Not a code bug - this is a missing local dependency, not a defect in `Import-WebView2Assembly`'s search logic. Downloaded the official `Microsoft.Web.WebView2` NuGet package directly from nuget.org (1.0.4191.47, latest stable at the time) and placed the three files the `net462` build + x64 native loader need - `Microsoft.Web.WebView2.WinForms.dll`, `Microsoft.Web.WebView2.Core.dll`, `WebView2Loader.dll` - into `Auth\WebView2\`, one of `Import-WebView2Assembly`'s existing candidate search paths. Verified by calling the function directly: it now loads with no `-WebView2AssemblyPath` override needed. Added `Auth/WebView2/` to `.gitignore` (matching the existing `plink.exe` precedent - a locally-installed third-party dependency, not project source). Rewrote the README Requirements callout to name the exact files needed, where to get them, and to stop implying `-WebView2AssemblyPath` is reachable through the driver when it isn't (see K11). | No test change - this is a local-environment dependency issue, not application logic; `Import-WebView2Assembly`'s existing candidate-path search was already correct and needed no code change. Live-verified on the user's own machine: the assembly now loads successfully |
| F49 | `Auth\CyberArk.Auth.Common.psm1` (`Invoke-WebView2Window`) | Per user report, live, immediately after F48: with the assembly now loading, the WebView2 window opens but stays completely blank - no page content, no error. Reading `Invoke-WebView2Window` directly found a real bug: the `CoreWebView2InitializationCompleted` handler unconditionally set `$state.Initialized = $true` and called `.Navigate()` without ever checking `$e.IsSuccess` first - WebView2's own API contract documents that environment creation can legitimately fail (user data folder permissions, a mismatched Runtime install, no available renderer, etc.), and on failure `$wv.CoreWebView2` is `$null`. Calling `.Navigate()` on it inside that event handler would throw, and .NET event-handler exceptions raised this way inside a WinForms message loop running in a background PowerShell runspace have no visible surface to report to - exactly matching a window that opens and simply sits there blank with no indication anything went wrong. A separate, more mundane possibility was raised and then ruled out: the profile involved in the F48/F49 reports pointed at `pvwa.company.com`, which happens to also be this project's own documentation placeholder domain - the user confirmed this is coincidental, it's their real lab address, chosen specifically because it doubles as an easy-to-remember placeholder. |
| F50 | `Auth\CyberArk.Auth.Common.psm1` (`Invoke-WebView2Window`) | Per user report, live, immediately after F49: with the F49 fix applied (SAML not fully configured in the user's lab), the window closed and a new error surfaced: `Index was out of range. Must be non-negative and less than the size of the collection. Parameter name: index`. Traced every collection-indexing site in the SAML call chain (`Invoke-SelfHostedSAML` -> `Invoke-WebView2Window` -> `Get-PVWASessionTimeoutMinutes` -> `New-AuthTokenObject`) and found exactly one unguarded raw index access: `$ps.Streams.Error[0]` in `Invoke-WebView2Window`'s `if ($ps.HadErrors)` branch. `PSDataCollection<ErrorRecord>.this[int]` throws precisely this exception, with this exact parameter name, when indexed out of range - and `HadErrors` can legitimately be `$true` with an empty `Streams.Error` collection in some pipeline-termination scenarios, plausibly including a WinForms `Application.Run()` message loop inside an STA runspace ending right as the user closes the window. Separately, per the user's direct request ("Is there a way to add some messaging to show what it is doing? What address it is trying to reach?"), added visible progress messaging throughout the SAML/OIDC/SSO login flow, which had none by default (only `Write-Verbose`, invisible unless `-Verbose` is passed). | Replaced the raw `$ps.Streams.Error[0]` access with `$ps.Streams.Error \| Select-Object -First 1`, which degrades to `$null` (handled with a fallback message) instead of throwing when the collection is empty. Added a status `Label` docked to the top of the WebView2 window itself, initialized to `"Connecting to: <url>"` and updated to `"Loading: <url>"` both when navigation starts and on every ~750ms timer tick thereafter (reading `$wv.CoreWebView2.Source` live) - this directly answers "what address is it trying to reach" inside the GUI itself, not just in a log file, and also means a window that previously looked identically blank whether it was stuck, loading, or actually broken now visibly shows which of those is happening. Upgraded `Invoke-SelfHostedSAML`/`Invoke-SelfHostedOIDC`/`Invoke-ISPSSSO`'s single `Write-Verbose` line each to visible `Write-Host` lines stating the exact URL being opened and (for SAML/OIDC) the host being watched for the redirect back. | No test change - matches F48/F49 and this codebase's established Testing Boundaries (WebView2/browser auth flows are not unit-testable). All 1121 unit tests still pass. Syntax-verified via `System.Management.Automation.Language.Parser]::ParseFile` on all 3 modified files. **Not yet live-verified** - the `$ps.Streams.Error[0]` fix addresses the exact exception signature reported, and the new status label/console messages should now make it visible in real time whether a future failure is a stuck/blank page, an unreachable address, or something else - but this hasn't been confirmed against the user's actual lab yet | Added an `IsSuccess` check to the `CoreWebView2InitializationCompleted` handler: on failure, captures `$e.InitializationException.Message` (falling back to a generic message if absent) into `$state.Result = @{ Error = ... }` and closes the window immediately instead of proceeding. Wrapped the subsequent `.Navigate()` call in `try/catch` for the same reason - a navigation failure (e.g. a malformed or unreachable URL) now also surfaces a specific message instead of silently leaving a blank window. `Invoke-WebView2Window`'s outer function now checks for this `Error` key on the captured result and `throw`s it verbatim, instead of only ever surfacing the generic "Authentication timed out or was cancelled" message regardless of the real cause. Renamed the handler's sender parameter from `$sender` to `$wvSender` per a PSScriptAnalyzer warning (`$Sender` is a PowerShell automatic variable). | No test change - matches F48 and this codebase's established Testing Boundaries: WebView2/browser auth flows are not unit-testable, only covered by manual procedures (A07/A08/AI06). All 1121 unit tests still pass (no regression in anything test-covered). **Not yet live-verified** - the user needs to retry `SSO`/SAML/OIDC login; if the window is still blank, the new error message (rather than nothing) should now say why |

**Live-tenant limitations found but NOT fixable via aPePAS code changes** (confirmed via raw HTTP requests matching psPAS's own documented shapes exactly, still failing identically - treated as environment/PVWA-version restrictions, not code bugs, per this project's no-guessing policy on undocumented API behavior):
- `DELETE /API/Safes/{safeName}` can return HTTP 409 for a safe whose own GET response shows `"accounts": []` (confirmed empty) shortly after accounts were added and deleted in it - likely an internal CyberArk retention/lifecycle delay unrelated to this module's request, which is a plain, correct `DELETE` with no equivalent "force" option in psPAS either.
- ~~`POST /API/Accounts/{id}/LinkAccount` and its bulk sibling returned HTTP 404~~ — **resolved, see Finding F41 above.** The user has since confirmed live that both the single and bulk endpoints now work correctly against the real tenant; this was an environment-side condition at the time, not a code bug, and required no aPePAS change.
- ~~`POST /API/UserGroups/{id}/Members` (`Invoke-GroupsAddMember`) returns an unconditional, empty-body HTTP 400 regardless of payload shape, field casing, or member type~~ — **resolved, see Finding F42 below.** This was actually a real code bug all along, not an environment limitation: every variant tried still sent a numeric-looking value for `memberId`, when CyberArk's API expects the member's username there instead (confusingly named field). Fixed and live-verified.

> **Note on F08/F09:** `Manage-Privilege.Tests.ps1` is documented (in `Documentation-Tracker.md`) as
> having a reproducible Pester v6.1 hang risk when new `Describe` blocks are added around
> `Invoke-FileWriteWithRetry`-adjacent code. No new automated test was added for these two driver
> fixes for that reason. **These two fixes are Self-Hosted-critical and must be verified manually**
> — see D23/D24 in the Manage-Privilege.ps1 manual test section below.

---

## Known Issues / Risk Register (not fixed this session — verify manually)

These were identified during this review but are **not yet fixed**. None of them block this test
pass, but each is a real gap worth confirming (or scheduling a follow-up fix for) during live
Self-Hosted testing.

| # | Area | Risk | Recommended manual check |
|---|---|---|---|
| K01 | `CyberArkComms.psm1` error handling | Assumes Windows PowerShell 5.1's `[System.Net.WebException]` typing for HTTP error responses. Behavior if this project is ever run under PowerShell 7/`pwsh` (where the underlying exception types differ) is untested and likely broken, even though the project is documented as Windows PowerShell 5.1 only. | Confirm the driver is never launched with `pwsh.exe`; consider adding an explicit version guard at startup if this risk needs closing. |
| K02 | Profile switching + `IgnoreSSL` | The SSL certificate validation bypass this profile setting enables is applied process-globally (not scoped to a single profile/session) and is never reset when the user switches from an `IgnoreSSL=$true` profile to a different profile in the same running session. | Test switching from an IgnoreSSL lab profile to a normal profile without restarting the script; confirm whether cert validation is (incorrectly) still bypassed. |
| K03 | WebView2 + `IgnoreSSL` | The `IgnoreSSL` profile setting appears to have no effect inside the embedded WebView2 browser control used for SAML/OIDC login — certificate validation in that control is governed separately from the setting. | If SAML/OIDC is tested against a lab host with a self-signed or internal CA certificate, confirm whether the WebView2 window shows a cert warning/blocks navigation regardless of `IgnoreSSL`. |
| K04 | Profile edit vs. active token | At several call sites, a freshly-edited `PVWAUrl` on a profile is not picked up if a token object saved under the old URL is still loaded — the stale `BaseURL` on the token object is used instead of the profile's current value. | Edit a profile's URL, then reuse a still-valid saved token for that profile; confirm which URL is actually called. |
| K05 | `Groups/Invoke-GroupsList.ps1` `GroupType` filter | Works correctly on Self-Hosted but is silently unusable on ISPSS (see the groupType caution above) with no warning surfaced to the user — a filtered ISPSS query just returns zero rows. | Out of scope for this Self-Hosted pass; flag as a UX follow-up if ISPSS is tested later. |
| K06 | `Update-SelfHostedAuthToken` | Falls back to an interactive `Read-Host` prompt rather than failing loudly when an expected stored credential is missing from `_RefreshContext`. In an unattended/scheduled context this would hang indefinitely waiting for console input rather than erroring out. | Not relevant to interactive manual testing; flag if this project is ever wrapped for unattended/scheduled use. |
| K07 | `Invoke-TokenRefresh` (SelfHosted branch) | Missing a `Username` fallback that the ISPSS branch has, for one re-authentication path. | Confirm re-authentication succeeds for all 8 Self-Hosted auth methods (see the Auth manual test section below) even when `Username` isn't pre-populated on the profile. |
| K08 | `Invoke-GroupsAddMember.ps1` (**resolved - see Finding F42**) | `POST /API/UserGroups/{id}/Members` returned an unconditional, empty-body HTTP 400 on the 2026-09-04 live test tenant regardless of payload shape, field casing, or member type - reproduced with the module's own request shape, psPAS's `Add-PASGroupMember.ps1`'s exact shape, and several variants (int vs. string `memberId`, with/without `memberType`), all identical. ~~Not fixed - no aPePAS-side request shape was found that succeeds~~ - this was wrong: every variant tried still sent a numeric-looking `memberId` value, when the field actually expects the member's username (per user report, later the same day). Fixed and live-verified: `POST` now returns HTTP 201. | Resolved - no further action needed. |
| K09 | `Invoke-AccountsLinkAccount.ps1` / `Invoke-AccountsUnlinkAccount.ps1` (**resolved - see Finding F41**) | `POST /API/Accounts/{id}/LinkAccount` and the bulk equivalent `POST /API/Accounts/Link/Bulk` both returned HTTP 404 on the 2026-09-04 live test tenant against a freshly confirmed-to-exist account (verified via a direct `GET` on that same account ID immediately before). ~~Not fixed - both endpoint shapes documented by psPAS (`Set-PASLinkedAccount.ps1`) were tried and both 404d identically~~ - the user retested live later the same day and confirmed both endpoints now work correctly with no code change; the 404 was a transient environment-side condition, not a code or request-shape defect. | Resolved - no further action needed. |
| K10 | `Invoke-SafesDelete.ps1` (partially mitigated - see F35) | `DELETE /API/Safes/{safeName}` returned HTTP 409 on the 2026-09-04 live test tenant for three safes whose own `GET` response showed `"accounts": []` (confirmed empty) shortly after accounts had been added to and then deleted from them. Retried after a 15-second wait with the same result - not clearly a short transient delay. Per user direction, the most likely cause is Safe History Retention: an account is marked with the retention setting active on the safe when it was added, so a safe whose accounts were added under different retention settings over time can carry mixed per-account history that blocks a full purge/delete even with zero live accounts. This is a plain, correct `DELETE` call with no equivalent "force" parameter in psPAS's `Remove-PASSafe.ps1` either, so no delete-side aPePAS fix was identified - F35 instead adds a rename-instead-of-delete fallback. Live-tested against all 3 stuck safes: 2 (`ZZ-ClaudeTest-Safe1`, `ZZ-ClaudeTest-DiagSafeLink`) were successfully renamed via the new fallback and are no longer stuck; the third (`ZZ-ClaudeTest-DiagSafeLink2`) returned HTTP 409 on the rename `PUT` too (retried once, same result) - it remains stuck and needs manual handling via the PVWA UI or CyberArk support, since the underlying lock apparently blocks modifying that specific safe entity at all, not just deleting it. | For `ZZ-ClaudeTest-DiagSafeLink2` specifically: retry after a longer wait (hours, not minutes); if it persists indefinitely, escalate to CyberArk support - likely an account-history/audit retention lock this project has no API-visible way to inspect or override. |
| K11 | `Auth\CyberArk.Auth.Common.psm1` / `Manage-Privilege.ps1` | `Import-WebView2Assembly`'s own thrown error message (F48) tells the user to "specify `-WebView2AssemblyPath`", but that parameter is never threaded through `Manage-Privilege.ps1` - no profile field or launch parameter exposes it. A user hitting this error through the normal driver has no way to act on that half of the message; the only real fix is getting the DLL into one of the function's other candidate paths (see F48 and the updated README Requirements section). | Either wire `-WebView2AssemblyPath` through to a profile field (e.g. alongside `IgnoreSSL`) so the message's advice is actually actionable, or drop that clause from the error message so it doesn't point at a dead end. Not fixed this session - documentation-only fix per user request. |

---

## Testing Boundaries

### What unit tests cover
- Pure logic: formatting, filtering, field mapping, error branching
- Filesystem operations: log file creation, profile CRUD (using temp directories)
- HTTP layer: mocked via `Mock Invoke-WebRequest` (success path) and
  `Mock Invoke-CyberArkAPI` (all paths for API modules)

### What unit tests do NOT cover
- Real HTTP calls to CyberArk
- Browser-based auth flows (WebView2)
- Interactive UI prompts (`Read-Host`, file dialogs)
- DPAPI encryption/decryption on a different machine

### Limitations of comms module unit tests
`Invoke-CyberArkAPI` catches `[System.Net.WebException]` and reads
`$exception.Response` as `[System.Net.HttpWebResponse]`. That class cannot be
instantiated in pure PowerShell, so the HTTP error paths (401, 429, etc.) are
tested via the API module layer by mocking `Invoke-CyberArkAPI` directly. This
also applies to the 504 retry loop (fixed delay + page-size reduction) added in
`Invoke-CyberArkAPI` — it is not covered by an automated unit test for the same
reason the 429 retry loop isn't; verify it manually against a lab environment
that can be made to return 504 (or by temporarily lowering
`$script:MaxGatewayTimeoutRetries`/`$script:GatewayTimeoutDelaySec` and forcing
a timeout).

---

## CyberArkLogging.psm1 — Test Cases

### Initialize-CyberArkLog
| # | Test Case | Expected |
|---|---|---|
| L01 | Call with a temp `LogFolder` | Log file created under that folder |
| L02 | Log filename format | `yyyy-MM-dd_HHmmss_<Profile>_<PID>.log` |
| L03 | Startup header | First line is exactly 40 `*` characters |
| L04 | Startup info line | Contains PID, timestamp, ProfileName |
| L05 | WhatIf note in header | `[WhatIf ON]` present when `WhatIfMode=$true` |
| L06 | Folder created if missing | No error; folder exists after call |
| L07 | Destination = Console | No log file created |
| L08 | Invalid MinLevel | Throws with clear message |
| L09 | Invalid Destination | Throws with clear message |

### Write-CyberArkLog
| # | Test Case | Expected |
|---|---|---|
| L10 | INFO at INFO minimum | Line written to file |
| L11 | DEBUG at INFO minimum | Line NOT written |
| L12 | VERBOSE at DEBUG minimum | Line NOT written |
| L13 | WARN always written above INFO | Written |
| L14 | ERROR always written | Written |
| L15 | Bare mode | File contains only the message — no pipe separators |
| L16 | PID field — right-aligned, width 7 | `"  12345 \|"` |
| L17 | LEVEL field — centered, width 7 | `"  INFO  \|"`, `" ERROR \|"` |
| L18 | FunctionName — left-aligned, width 24 | Padded to 24 chars |
| L19 | Long FunctionName truncated | Ends with `…` at width 24 |
| L20 | Sensitive: `Authorization: Bearer <token>` | Token replaced with `***` |
| L21 | Sensitive: `password=abc123` | Value replaced with `***` |
| L22 | Sensitive: `"access_token":"xyz"` | Value replaced with `***` |
| L23 | Non-sensitive message | Unchanged |
| L24 | Auto-detected FunctionName | Caller's function name appears in line |
| L25 | Explicit FunctionName | Supplied name appears, not caller's |

### Add-CyberArkLogSummaryEntry + Close-CyberArkLog
| # | Test Case | Expected |
|---|---|---|
| L26 | No entries added | Close writes no summary block |
| L27 | One entry added | Summary block contains that module's row |
| L28 | Multiple entries | Per-module rows + totals row both present |
| L29 | Totals calculation | Sum of all ItemsProcessed / Successes / Failures correct |
| L30 | Summary divider lines | 40 `-` characters present |

### Remove-OldCyberArkLogs
| # | Test Case | Expected |
|---|---|---|
| L31 | File older than retention days | File deleted |
| L32 | File within retention window | File kept |
| L33 | Non-existent folder | No error; WARN logged |
| L34 | `-WhatIf` | No files deleted |

### Set-CyberArkLogLevel / Set-CyberArkLogDestination
| # | Test Case | Expected |
|---|---|---|
| L35 | Set level to VERBOSE, write VERBOSE | Written |
| L36 | Set level to ERROR, write WARN | Not written |
| L37 | Set destination to File | No console output |

---

## CyberArkComms.psm1 — Test Cases

### New-CyberArkQuery
| # | Test Case | Expected |
|---|---|---|
| C01 | Empty hashtable | Returns `""` |
| C02 | Single param | `?key=value` |
| C03 | Multiple params | `?key1=v1&key2=v2` (any order) |
| C04 | Null value omitted | Null key skipped |
| C05 | Empty string value omitted | Empty-string key skipped |
| C06 | Value with spaces | URL-encoded (`+` or `%20`) |
| C07 | Special chars in key | URL-encoded |

### Join-CyberArkUrl
| # | Test Case | Expected |
|---|---|---|
| C08 | Base + one segment | `https://host/seg` |
| C09 | Trailing slash on base trimmed | No double slash |
| C10 | Leading slash on segment trimmed | No double slash |
| C11 | Multiple segments | All joined with single `/` |
| C12 | Segment with trailing slash | Trimmed |

### New-CyberArkSearchFilter
| # | Test Case | Expected |
|---|---|---|
| C13 | Single criterion | `field eq value` |
| C14 | Two criteria, default AND | `f1 eq v1 AND f2 eq v2` |
| C15 | Value with spaces | `field eq "value with spaces"` |
| C16 | Custom operator OR | `f1 eq v1 OR f2 eq v2` |

### Invoke-CyberArkAPI — success path (mocked Invoke-WebRequest)
| # | Test Case | Expected |
|---|---|---|
| C17 | GET returns 200 + JSON | `IsSuccess=$true`, `DataType='JSON'`, `Data` parsed |
| C18 | POST returns 201 | `IsSuccess=$true`, `StatusCode=201` |
| C19 | 204 No Content | `IsSuccess=$true`, `DataType='Empty'`, `Data=$null` |
| C20 | WhatIf + POST | Request suppressed; returns `IsSuccess=$true`, `StatusCode=200` |
| C21 | WhatIf + PUT | Suppressed |
| C22 | WhatIf + DELETE | Suppressed |
| C23 | WhatIf + GET | NOT suppressed; request proceeds |
| C24 | QueryParams appended to URL | Mock called with correct URI |
| C25 | Body serialized to JSON | Mock called with JSON Content-Type |

### Invoke-CyberArkAPI — pagination (mocked)
| # | Test Case | Expected |
|---|---|---|
| C26 | Two pages returned | All items combined in `Data.value` |
| C27 | Final page has fewer than PageSize items | No further request made |
| C28 | `PageSize = 0` | Pagination disabled; single request |

---

## Invoke-SafesList.ps1 — Test Cases

### Module Metadata
| # | Test Case | Expected |
|---|---|---|
| S01 | `$ModuleMeta` is defined | Not null after dot-sourcing |
| S02 | Required fields present | Name, Category, Action, SupportedSystems, Version all present |
| S03 | SupportedSystems | Contains `ISPSS` and `SelfHosted` |
| S04 | SupportsWhatIf | `$false` |
| S05 | HasCustomInput | `$true` |
| S06 | AcceptsInputFile | `$false` |

### Invoke-SafesList — successful response (mocked Invoke-CyberArkAPI)
| # | Test Case | Expected |
|---|---|---|
| S07 | Returns standard result object shape | All 9 required fields present |
| S08 | Single safe returned | `Successes=1`, `ItemsProcessed=1`, `Failures=0` |
| S09 | Multiple safes returned | Count matches `value` array length |
| S10 | `safeName` mapped to `SafeName` | Correct value |
| S11 | `description` mapped | Correct value |
| S12 | `managingCPM` mapped | Correct value |
| S13 | `creator.name` mapped to `Creator` | Correct value |
| S14 | `creationTime` epoch → local date string | `yyyy-MM-dd` format |
| S15 | `creationTime = 0` or missing | No exception; `Created = ''` |
| S16 | `IsFatal` | `$false` on success |
| S17 | Search passed | `QueryParams.search` in mock call args |
| S18 | Filter passed | `QueryParams.filter` in mock call args |
| S19 | ExtendedDetails = true | `QueryParams.extendedDetails = 'true'` |
| S20 | Empty Search string | `search` key absent from QueryParams |
| S21 | Empty Filter string | `filter` key absent from QueryParams |
| S22 | ExtendedDetails = false | `extendedDetails` key absent |
| S23 | Null InputData | No exception; no query params sent |

### Invoke-SafesList — empty result
| # | Test Case | Expected |
|---|---|---|
| S24 | `value` array is empty | `Successes=0`, `IsFatal=$false`, `Failures=0` |
| S25 | `value` property missing | No exception; 0 results |

### Invoke-SafesList — API errors
| # | Test Case | Expected |
|---|---|---|
| S26 | `IsSuccess=$false`, StatusCode 403 | Error added, `IsFatal=$false` |
| S27 | `IsSuccess=$false`, StatusCode 401 | Error added, `IsFatal=$true` |
| S28 | `IsSuccess=$false`, StatusCode 0 (network) | Error added, `IsFatal=$true` |
| S29 | `IsSuccess=$false`, StatusCode 404 | Error added, `IsFatal=$false` |
| S30 | Error includes `ErrorMessage` | Not null or empty |
| S31 | `ItemsProcessed` incremented on failure | `=1` after single failure |

---

## Invoke-SafesAddFromTemplate.ps1 — Test Cases

Design reference: `Docs\Add-Safe-From-Template-Design.md`. Test file:
`Unit\Invoke-SafesAddFromTemplate.Tests.ps1`.

### Module Metadata
| # | Test Case | Expected |
|---|---|---|
| T01 | `$ModuleMeta` is defined | Not null after dot-sourcing |
| T02 | Category / Action | `Safes` / `AddFromTemplate` |
| T03 | SupportsWhatIf | `$true` |
| T04 | SupportedSystems | Contains `ISPSS` and `SelfHosted` |
| T05 | InputSchema `SafeName` | `Required = $true` |
| T06 | InputSchema `Description` | `Required = $false` |

### Invoke-SafesAddFromTemplate — successful response (mocked Invoke-CyberArkAPI)
| # | Test Case | Expected |
|---|---|---|
| T07 | Template safe + members read, safe created, members copied | `IsFatal=$false` |
| T08 | Safe creation result row | One `Results` row with `ItemType='Safe'` |
| T09 | Role-group exclusion | Member whose name starts with `Role_Group_Prefix` is not copied; other members are |
| T09a | Global exclusion list | Member whose name is in `$script:ExcludedTemplateMemberNames` is not copied, regardless of `memberType`; other members are |
| T09b | Global exclusion match rule | Match is exact and case-insensitive - a name that only partially matches (e.g. `AdminGroupExtra` vs. `AdminGroup`) is not excluded |
| T10 | Success counts | `Successes` = 1 (safe) + copied member count; `Failures=0` |
| T11 | Safe POST body | `Location`, `ManagingCPM`, `AutoPurgeEnabled` copied from the template safe's GET response |
| T11a | OLACEnabled | Never included in the safe POST body — not read from the template, not asked, not sent |
| T11b | Template `NumberOfDaysRetention=0` | Only `NumberOfVersionsRetention` is sent; `NumberOfDaysRetention` key absent from the body |
| T11c | Template `NumberOfDaysRetention>0` | Only `NumberOfDaysRetention` is sent; `NumberOfVersionsRetention` key absent from the body |
| T12 | Member POST body | `membershipExpirationDate` always `$null`, never copied from the template member |

### Invoke-SafesAddFromTemplate — WhatIf
| # | Test Case | Expected |
|---|---|---|
| T13 | WhatIf | No `POST` call is made |
| T14 | WhatIf | Template safe and template member GET calls still happen (reads are not blocked) |
| T15 | WhatIf | Synthetic `Results` contains one `Safe` row plus one row per member that would be copied |

### Invoke-SafesAddFromTemplate — validation
| # | Test Case | Expected |
|---|---|---|
| T16 | Empty `SafeName` | `Failures=1`, no API call |
| T17 | `Role_Template_Safe` blank on active profile | `Failures=1`, `IsFatal=$false`, no API call |
| T18 | `Role_Group_Prefix` blank on active profile | `Failures=1`, `IsFatal=$false`, no API call |

### Invoke-SafesAddFromTemplate — errors
| # | Test Case | Expected |
|---|---|---|
| T19 | Template safe GET returns 404 | Error added, `IsFatal=$false`, no safe created |
| T20 | Template safe GET returns 401 | `IsFatal=$true` |
| T21 | Template members GET fails (403) | Error added, `IsFatal=$false`, safe not created |
| T22 | Safe creation POST fails (409) | Error added, `IsFatal=$false`, no member POSTs attempted |
| T23 | One member POST fails (403) | Loop continues; other members still copied; `Failures` reflects the one failure |
| T24 | A member POST returns 401 | `IsFatal=$true`; loop stops immediately |

---

## Self-Hosted Auth — Manual Integration Test Procedures

`Auth/Get-AuthToken.ps1` was a dead legacy shim (see Findings F10 above) and has been deleted; the
current auth surface for this pass is `Auth/CyberArk.Auth.SelfHosted.psm1` (plus the shared
`CyberArk.Auth.Common.psm1` for token persistence, WebView2, and profile I/O). Unit testing is not
feasible for these modules (browser auth flows, DPAPI, interactive prompts, live directory/PKI
dependencies) — run these procedures manually against the live Self-Hosted lab host for **all 8**
Self-Hosted auth methods. **SAML, OIDC, PKI, and PKIPN are the highest-risk methods** for this pass:
they depend on the WebView2 runtime, a real IdP, or a real certificate/smart-card being present in
the test environment, none of which can be simulated, and (per K03 above) `IgnoreSSL` is known not
to reliably apply inside the WebView2 control used by SAML/OIDC.

| # | Test Case | Pass Criteria |
|---|---|---|
| A01 | SelfHosted — CyberArk auth | Token returned; `SystemType=SelfHosted`; `TokenType=CyberArkSession`; `Authorization` header has no `Bearer` prefix |
| A02 | SelfHosted — LDAP auth | Token returned with `AuthMethod=LDAP` |
| A03 | SelfHosted — RADIUS auth | Token returned with `AuthMethod=RADIUS`; if the RADIUS server requires a challenge/response (e.g. a one-time passcode), confirm the prompt flow completes |
| A04 | SelfHosted — Shared auth | Token returned with `AuthMethod=Shared` |
| A05 | SelfHosted — PKI cert auth (**high risk**) | Correct cert selected via `Get-FilteredClientCertificate`; token returned; requires a real client certificate installed in the test environment's cert store |
| A06 | SelfHosted — PKIPN auth (**high risk**) | Same as A05 but via PIN-protected smart card/token; requires physical/virtual smart-card hardware |
| A07 | SelfHosted — SAML auth (**high risk**) | WebView2 window opens; IdP login completes; token captured via cookie/redirect detection; confirm behavior if the lab host uses a self-signed cert (see K03) |
| A08 | SelfHosted — OIDC auth (**high risk**) | Same as A07 but OIDC flow; confirm token exchange completes and `Token`/`TokenType` are populated correctly |
| A09 | Save-AuthToken | `.cred` file created/updated under the profile's token storage location |
| A10 | Import-AuthToken — valid token | Token object returned with all fields (`Token`, `TokenType`, `Headers`, `Expiry`, `SystemType`, `AuthMethod`, `BaseURL`, `Created`, etc.) |
| A11 | Import-AuthToken — expired token on disk | Caller correctly detects expiry (session age > `$script:PVWA_SESSION_EXPIRY_MIN`) and triggers re-authentication rather than using a dead token |
| A12 | Update-SelfHostedAuthToken — silent re-auth path | Confirm this uses the stored `_RefreshContext` credentials without prompting, for auth methods where that's expected; cross-check against K06 (Read-Host fallback if the context is missing) |
| A13 | Get-AuthTokenProfiles | All saved profiles listed |
| A14 | Remove-AuthTokenProfile | Token file removed; profile no longer resolves a stored token |
| A15 | IgnoreSSL — self-signed cert environment, non-WebView2 methods (CyberArk/LDAP/RADIUS/Shared/PKI/PKIPN) | No SSL error |
| A16 | Import-AuthToken — Created field | Returned token's `Created` equals the token file's persisted save time, not the load time; re-saving via `Save-AuthToken` after a refresh updates `Created` to the refresh time |
| A17 | `Invoke-SelfHostedKeepalive` persists extended expiry (Findings F08) | After a keepalive call (`GET /API/LoggedOnUser`), confirm the on-disk token file's expiry is updated, not just the in-memory session token |
| A18 | Logoff | `POST /API/auth/Logoff` called on exit (D12); confirm the PVWA session is actually invalidated server-side (a captured token can no longer be used) |

---

## ISPSS Auth — Manual Integration Test Procedures

`Auth/CyberArk.Auth.ISPSS.psm1` implements all 3 documented ISPSS/Privilege Cloud auth methods:
`ClientCredentials`, `Interactive`, and `SSO`. Reviewed 2026-09-04 against CyberArk's own reference
material at `C:\Code\References\CyberArk ISPSS\` (the "API Token" folder's two docs are the only
ones there that actually document authentication - the "Access API" and "User Management APIs"
folders are generated Swagger SDKs for *post-authentication* operations, not auth setup) - this
review found and fixed a real bug (see Finding F36) that would have crashed every
`ClientCredentials` login. `ClientCredentials`'s response-parsing logic now has unit coverage
(`Tests\Unit\CyberArk.Auth.ISPSS.Tests.ps1`, ISPSS-CC01-CC06, `Invoke-RestMethod` fully mocked) -
the first automated coverage this module has ever had. `Interactive` (a live MFA challenge/response
loop against `/Security/StartAuthentication` and `/Security/AdvanceAuthentication`) and `SSO` (a
WebView2 browser window capturing a cookie) still require a real tenant and are not unit-testable,
matching the Self-Hosted SAML/OIDC/PKI/PKIPN precedent above.

| # | Test Case | Pass Criteria |
|---|---|---|
| AI01 | ISPSS — ClientCredentials auth | Token returned; `SystemType=ISPSS`; `AuthMethod=ClientCredentials`; `Authorization` header is `Bearer <token>`; no crash regardless of whether the response includes a `refresh_token` field (F36) |
| AI02 | ISPSS — Interactive auth, single-factor (password only) | `StartAuthentication` returns one challenge with one mechanism; password submitted via `AdvanceAuthentication`; token returned with `AuthMethod=Interactive` |
| AI03 | ISPSS — Interactive auth, MFA (multiple mechanisms/challenges) | Mechanism picker shown when more than one option exists; each challenge in sequence is satisfied (password, OTP/SMS, push); token returned only after the full challenge loop completes |
| AI04 | ISPSS — Interactive auth, OOB (out-of-band) push approval | `StartOOB` triggered; polling loop shows elapsed time; approving on the mobile device returns a token before the 300s timeout; declining/timing out surfaces a clear error, not a hang |
| AI05 | ISPSS — Interactive auth, external IdP redirect (`IdpRedirectShortUrl` present) | Browser opens to the IdP; PIN prompt shown after login; PIN submitted via `AdvanceAuthentication` returns a token |
| AI06 | ISPSS — SSO auth | WebView2 window opens to `{IdentityURL}/login`; `idToken` cookie captured; token returned with `AuthMethod=SSO` |
| AI07 | Resolve-IdentityTenantURL — platform-discovery succeeds | Identity tenant URL resolved from the live `platform-discovery.cyberark.cloud` service's `identity_user_portal.api` field, not the constructed fallback |
| AI08 | Resolve-IdentityTenantURL — platform-discovery unreachable/malformed | Falls back to `https://<subdomain>.id.cyberark.cloud` without throwing; a WARN is logged |
| AI09 | Update-ISPSSAuthToken — ClientCredentials re-auth | Since a `ClientCredentials` token never carries a `refresh_token` (F36, confirmed against the documented response shape), confirm this always falls through to a full `Invoke-ISPSSClientCredentials` re-auth rather than attempting the (effectively dead, see F36's note) `refresh_token` grant branch |
| AI10 | Update-ISPSSAuthToken — Interactive re-auth | Re-runs the full MFA challenge loop; confirm this doesn't silently succeed without actually prompting (Interactive tokens have no refresh path by design) |
| AI11 | Update-ISPSSAuthToken — SSO re-auth | Re-opens the WebView2 window; confirm a fresh `idToken` is captured |
| AI12 | ISPSS token used against `Invoke-CyberArkAPI` | `Get-PVWASessionTimeoutMinutes` (`GET {BaseURL}/api/Settings/Timeout`) is expected to 404 on ISPSS (per the code comment) and fall back to the 4-hour default expiry - confirm this fallback actually triggers rather than crashing on the 404 |

---

## Manage-Privilege.ps1 — Manual Integration Test Procedures

| # | Test Case | Pass Criteria |
|---|---|---|
| D01 | First launch — no profiles | "No profiles found" shown; N/Q offered |
| D02 | Create new profile | JSON file created; profile appears in list |
| D03 | Edit profile — change log folder | JSON updated; `Modified` timestamp changed |
| D04 | Copy profile | New JSON with new name; auth token file NOT copied |
| D05 | Delete profile | Both JSON and XML removed |
| D06 | Test Connection — valid token | "Connection successful" with expiry shown |
| D07 | Continue — saved valid token | Session starts without re-auth |
| D08 | Continue — expired token, ClientCredentials | Silent refresh; session starts |
| D09 | Continue — expired token, Interactive | Re-auth prompt shown |
| D10 | B navigation | Returns to profile list |
| D11 | Restart (R) | Returns to profile list; current profile is default |
| D12 | Exit (X) | Logoff called (SelfHosted); script exits cleanly |
| D13 | Inactivity timeout | Session ends after `$InactivityTimeoutMin` of no input |
| D14 | Inactivity warning | Warning shown at 90% of timeout |
| D15 | Token expiry warning in menu footer | Yellow color; correct minutes shown |
| D16 | WhatIf mode | Menu shows `[WhatIf ON]`; write calls suppressed |
| D17 | Module discovery | All `.ps1` files in `APIModules\` appear in menu |
| D18 | SelfHosted-only module hidden for ISPSS | Module absent from ISPSS session menu |
| D19 | Logon with a valid but old saved token (`Created` > 15 min ago) | "Saved token is N minute(s) old - refreshing..." shown; a fresh/refreshed token is used for the session, not the stale one |
| D20 | Logon with a valid, recently-saved token (`Created` < 15 min ago) | No refresh message; token loaded directly, unchanged from today's behavior |
| D21 | Any module call returns HTTP 401 with a message that does NOT contain the word "401" or "Unauthorized" | Session is still invalidated — re-auth prompt appears on the next action, same as a normally-worded 401 |
| D22 | Any module call fails with a genuine network error (`StatusCode 0`) | Session is also invalidated (by design, since `IsFatal` covers both cases) — re-auth prompt appears; confirm this is the intended tradeoff, not a regression |
| D23 | **(Findings F09)** Stay inside a single category and perform several actions in a row, spanning past a keepalive interval, without ever returning to the category menu | Inactivity check, proactive refresh, and token-expiry (`Expired`/`Warning`) handling all fire correctly from *inside* the action loop, not only when returning to the category menu — this is a fix made this session and was previously broken |
| D24 | **(Findings F08)** Trigger a keepalive (`Invoke-SelfHostedKeepalive`) by staying logged in past the keepalive threshold, then kill the process (e.g. close the console) without a clean exit, then relaunch | The reloaded token's expiry reflects the keepalive-extended session, not the original pre-keepalive expiry — confirms the extended expiry was actually persisted to disk, not just held in memory |
| D25 | Full session using a live Self-Hosted profile end-to-end: profile creation → auth → category menu → several module actions across categories → inactivity warning → idle past timeout → re-auth → exit | No unhandled exceptions; log file contains a coherent full-session narrative; summary block at exit reflects all actions taken |

---

## Self-Hosted Full Functional Checklist

This is the master checklist for the live functional pass against `https://pvwa.company.com`
(or whichever Self-Hosted lab host is in use). It enumerates every module action in the project.
For each, run it at least once against the live host with realistic input (including at least one
CSV-batch run where the module supports one), confirm the result matches what's actually in the
Vault/PVWA (not just that the tool reported success), and note the PVWA version under test — see
the caution section above for why version matters for Platforms/SafeMembers field-shape
differences.

Use a **dedicated test Safe and test accounts** for every write action (Add/Update/Delete/Change/
Reconcile/etc.) — never point a write action at production data.

### Auth (see the dedicated Self-Hosted Auth section above for the full A01-A18 procedures)
- [ ] All 8 auth methods: CyberArk, LDAP, RADIUS, Shared, PKI, PKIPN, SAML, OIDC
- [ ] Token save/load/refresh/keepalive/logoff lifecycle

### Accounts (17 actions)
- [ ] Add · [ ] CancelCpmTask (confirm the `/Cancel/` endpoint, Phase 1 this session — was
      `/StopImmediateAutoMgmtOperations` before; F14 this session added a 404 fallback to that
      same old endpoint for PVWA older than 15.2, unverified against a real pre-15.2 host) ·
      [ ] ChangeImmediate ·
      [x] ChangeInVault (F12's `Password/Update` endpoint correction **confirmed correct
      2026-09-03** — a live 400 against it turned out to be a legitimate `PASWS001W` account-lock
      error once F16 let Test API surface the real body, not a bug in the endpoint/body shape;
      still confirm F02 masking against a real successful change) · [ ] CheckIn ·
      [ ] Delete · [ ] Get ·
      [ ] GetActivity · [ ] GetCredential ·
      [x] LinkAccount (F41 this session — **confirmed live**: previously logged as an unfixable
      live-tenant limitation (HTTP 404), the user has since retested and confirmed it now works
      correctly against the real tenant; no code change was involved) ·
      [x] List (incl. By-Safe mode, confirm 20K cap behavior — **confirmed 2026-09-02**) · [ ] Reconcile ·
      [ ] ResumeAutoManagement (confirm `POST .../Resume/` on Self-Hosted, Phase 1 this session —
      was `PATCH .../` before; ISPSS was deliberately left unchanged/unconfirmed; F14 this
      session added a 404 fallback on Self-Hosted to the same PATCH `automaticManagementEnabled`
      approach for PVWA older than 15.2, unverified against a real pre-15.2 host) ·
      [x] UnlinkAccount (F41 this session — **confirmed live**, same as LinkAccount above) ·
      [ ] Unlock · [ ] Update (JSON Patch) · [ ] Verify

  **For every `AccountName`+`Safe`-resolving action above:** confirm the `filter=safeName eq ...`
  lookup now works against a **safe name containing a space** (e.g. `"Prod Web Servers"`), not just
  a single-word safe name - this session fixed all 16 call sites of this bug (raw string
  interpolation never quoted the value; now routed through `New-CyberArkSearchFilter`, confirmed
  against psPAS's `ConvertTo-FilterString.ps1`), but none of the 16 fixes have been exercised
  against a real PVWA/ISPSS tenant yet. `List`'s By-Safe iteration mode needs the same check with
  at least one accessible safe whose name contains a space.

### Safes (8 actions)
- [ ] Add (F20 this session — Location no longer prompted interactively, confirm the default `\`
      is still used; ManagingCPM picker now matches AddFromTemplate, sourced from the new shared
      `Get-CpmOptions` — confirm the live CPM query populates it, and that a deliberately-broken
      query falls back to the profile's CPM_List) ·
      [ ] AddFromTemplate (T01-T24 scenarios; F20 this session — CPM picker now sourced from
      `Get-CpmOptions` instead of `CPM_List` only, confirm live query + fallback) ·
      [ ] AssignCPM (F20 this session — CPM picker now sourced from `Get-CpmOptions`, same
      live-query behavior as before but now with a CPM_List fallback on failure that didn't
      exist previously; confirm both paths) ·
      [ ] Delete · [ ] Get ·
      [x] List (confirm F05 ExtendedDetails CSV-boolean fix — **confirmed 2026-09-02**) ·
      [ ] UnassignCPM · [ ] Update

### SafeMembers (6 actions)
- [ ] Add (confirm SearchIn directory picker lists real LDAP directories) ·
      [ ] AddFromTemplateRole · [x] List (**confirmed 2026-09-02**) · [ ] Remove · [ ] Update ·
      [ ] UpdateFromTemplateRole

### Platforms (10 actions)
- [ ] Get ·
      [x] List (confirm F06 field-fallback fix and the new `SystemType` filter — **confirmed
      2026-09-02**) · [ ] Copy (Target platforms only — see `E2E-Automation-Design.md`) ·
      [ ] Disable · [ ] Enable ·
      [x] Export (F38 this session — **confirmed live** for the `PlatformID` variant: downloaded a
      real, valid `.zip` from the Self-Hosted tenant; the other 3 target-type variants remain
      unit-tested only, no real rotational-group/dependent/group-platform ID exists to test with) ·
      [ ] Import (confirm the ZIP-as-byte-array request shape actually works) ·
      [ ] Remove (destructive — use a disposable sandbox platform) ·
      [ ] Rename (Self-Hosted only, PVWA 15.0+) · [ ] SetPSMConfig

### Policies (2 actions — PVWA 14.6+; SetMasterPolicy is Self-Hosted only, GetMasterPolicy is declared dual-use)
- [x] GetMasterPolicy (F40 this session — **Self-Hosted confirmed live**, including via the
      `Custom/ExportAll` `IncludeInExportAll` path. **ISPSS/Privilege Cloud confirmed live
      (2026-09-04) to have no Master Policy equivalent endpoint at all** - handled cleanly as a
      non-fatal `Failure`, confirmed acceptable behavior by the user, no code change needed) ·
      [ ] SetMasterPolicy (Self-Hosted only; mutates tenant-wide config — use a dedicated lab host,
      never a shared/production one; confirm every field's validation range: `ConfirmersNumber`
      1-64, `PasswordChangeDays`/`PasswordVerificationDays` 1-3650, `RetentionPeriod` 0-3650)

### Users (2 actions)
- [ ] Get · [x] List (**confirmed 2026-09-02**)

### Groups (7 actions)
- [ ] Add ·
      [x] AddMember (F42 this session — **confirmed live**: `memberId` is the username, not a
      numeric ID; previously an unconditional HTTP 400, now HTTP 201 against the real tenant) ·
      [ ] Delete ·
      [x] GetMembers (F43 this session — **confirmed live**: fixed a strict-mode crash mapping a
      real member entry, which has no `userType`/`componentUser` field at all; the
      `IncludeMembers` opt-in field makes no observable difference on this tenant, also
      confirmed live) ·
      [x] List (confirm GroupType filter works correctly on Self-Hosted, unlike ISPSS —
      **confirmed 2026-09-02**) ·
      [x] RemoveMember (F42 this session — **confirmed live** as part of the same end-to-end
      test, HTTP 204) ·
      [ ] Update

### Applications (7 actions — dual-use, see caution section)
- [x] Add (confirm `Location` is now enforced as mandatory, Phase 1 this session — **confirmed
      2026-09-02**, the only Applications action visible on the ISPSS menu before this pass) ·
      [ ] AddAuthMethod · [ ] Delete · [ ] DeleteAuthMethod · [ ] Get ·
      [x] List (confirm F01 trailing-slash / PIMServices.svc routing fix — **confirmed
      2026-09-02**) ·
      [ ] ListAuthMethods (per user request, this session: leaving App ID blank now lists auth
      methods for every application instead of failing - **not** covered by the "List confirmed"
      status above, since its `Action` is `ListAuthMethods`; this new blank-App-ID behavior is
      unverified against a real host)
- AddAuthMethod, Delete, DeleteAuthMethod, Get, List, and ListAuthMethods were expanded from
  Self-Hosted-only to dual-use on 2026-09-02, after the user found only Add visible on the ISPSS
  Applications menu — confirming the other 6 had been Self-Hosted-only in error. Only ISPSS menu
  visibility has been confirmed for these 6; their actual ISPSS request/response behavior is
  unverified.

### Reports (1 action — Self-Hosted only, see caution section)
- [x] List (confirm F04 sparse-field guards against a real report with missing fields, if any
      exist — **confirmed 2026-09-02**, Self-Hosted only. Also confirmed 2026-09-02 that this
      endpoint 404s on ISPSS/Privilege Cloud — `SupportedSystems` reverted to Self-Hosted-only,
      reversing Phase 1's dual-use expansion)

### Custom (7 actions)
- [x] ExportAll (per user request, this session, now also runs Applications/ListAuthMethods -
      that specific addition is unverified against a real host; F40 this session — **confirmed
      live** that it now also runs Policies/GetMasterPolicy via the new `IncludeInExportAll`
      opt-in, saving a real CSV with real policy values against the Self-Hosted test tenant) ·
      [ ] ExportEntitlements (confirm the CSV now saves automatically with no `[y/N]` prompt) ·
      [ ] ExportGroupMembersLDAP (requires AD line-of-sight; confirm auto-save CSV) ·
      [ ] ExportGroupMembersLocal (confirm F07 groupType quirk fix, though Self-Hosted may not
      exhibit the ISPSS quirk at all — confirm normal local-group export still works; confirm
      auto-save CSV) ·
      [x] ExportPlatformDetails (F39 this session — **confirmed live**: 10/10 active platforms
      processed successfully, 104 dynamic columns, correct blank-fill and per-platform-type value
      extraction spot-checked via CSV; the `OtherFiles`/META-INF-exclusion logic is unit-tested
      only, no real bundled-extra-file example existed on this tenant to confirm it against) ·
      [ ] TestApi (manual smoke test — no unit test exists for this module; confirm the base URL
      shown/used no longer includes `/PasswordVault`, widening what paths it can reach; **F15
      this session — needs live verification specifically with `IgnoreSSL` enabled and a token
      allowed to expire mid-session**, reported by the user as the whole process silently
      closing with no error shown; fixed by switching from a raw
      `ServerCertificateValidationCallback` scriptblock to the shared, already-safe
      `Disable-SSLValidation` helper, but not yet confirmed the crash is actually gone) ·
      [ ] TestConnectivity (confirm against a real Windows target: SMB admin-
      share auth on port 445; and a real Linux target: SSH auth via PS7 `-SSHTransport` and/or
      plink.exe if installed, and the "Plink or PS7 needed" message if neither is; confirm the
      vault password fallback resolves Address+Account correctly; confirm auto-save CSV; F22 this
      session — confirm the `Safe`/`Username`/`PasswordSource` output columns are populated
      correctly for a real vault-backed lookup, and stay blank when a password is supplied directly;
      **F23 this session — was a `[FATAL] PropertyNotFoundException` crash on every Linux SSH
      attempt, reported directly by the user; re-confirmed working against a real test host
      (172.21.20.14) with the fix applied, both for an unrecognized and an already-known host
      key**; F24 this session — confirm the Server Type prompt shows and accepts only `1`/`2`;
      F25 this session — confirmed live that the PS7 SSH transport path still times out on a
      real password attempt (a pre-existing, separate limitation, not fixed by the host-key
      change); [x] F26 this session — **confirmed live**: the auto-saved CSV filename includes
      the tested Address; [x] F27/F28/F29 this session — **fully confirmed live end-to-end
      against a real target with real credentials**: DNS resolution no longer aborts on a
      literal IP with no PTR record, plink is tried first, an unrecognized host key is
      auto-trusted via a one-time retry with its own reported fingerprint, a real login
      succeeds (`AuthStatus: Success`), and a wrong password still fails cleanly in ~3 seconds
      with an accurate message - this is the first fully end-to-end verified success case for
      this module's Linux path)

### Driver-level (Manage-Privilege.ps1)
- [ ] D01-D25 (see Manage-Privilege.ps1 manual test procedures above, including new D23-D25)
- [ ] CSV template generation for every module that accepts CSV input
- [ ] List drill-down (select a row number from any List result to open its Get/Details view)
- [ ] WhatIf mode toggled on, confirm every write action across every category is suppressed and logged
- [ ] Structured logging: confirm no secrets appear in the log file at any level (spot-check F02's fix)
- [ ] Run any `List` action against a real host where exactly one row is returned (F13, this
      session — was a `[FATAL] PropertyNotFoundException` on `.Count`, reported directly by the
      user against `Accounts / List`) — confirm the result table renders correctly with 1 row
- [ ] `Invoke-EntitySearch`'s interactive picker (used by several `Get`/`Delete`/etc. custom
      input functions) with a search term containing a period (e.g. a UPN-style username or a
      dotted IP) — confirm F21's `%2E` encoding fix actually returns matches now, per the user's
      live report that a literal period previously found nothing

---

## Privilege Cloud (ISPSS) Full Functional Checklist

This is the counterpart to the Self-Hosted checklist above, for a live functional pass against a
real Privilege Cloud (ISPSS) tenant. Per the caution section near the top of this document, most of
this project's iterative bug-fixing history was driven by Self-Hosted testing — the large majority
of items below are still genuinely unconfirmed on ISPSS even though the code path is shared
(dual-use). Use a **dedicated test Safe and test accounts** for every write action, and **never run
this pass against a production Privilege Cloud tenant.**

### This pass requires interactive human authentication — it cannot be scripted or run unattended

Unlike `ClientCredentials` (a silent service-account grant, already covered by unit tests
`ISPSS-CC01`–`CC06` and not the focus of this pass), the whole point of this checklist is to
exercise a **real interactive login**, so a person must be sitting at the console for the entire
session:

- **`Interactive`** prompts for a CyberArk Identity username (if not already known), shows a
  numbered mechanism picker when more than one challenge mechanism is configured (e.g. password vs.
  OTP vs. push), and then blocks on `Read-Host` waiting for the answer to each challenge in turn —
  see `Invoke-ISPSSInteractive` in `Auth\CyberArk.Auth.ISPSS.psm1`. If out-of-band (OOB) push
  approval is configured, the process polls and blocks for up to 300 seconds waiting for approval
  on a mobile device.
- **`SSO`** opens a WebView2 browser window that requires an actual interactive sign-in (and an IdP
  redirect, if the tenant is federated) before it captures the session cookie.

Run this pass with whichever of `Interactive`/`SSO` the test tenant actually has configured; if
both are usable, run the profile-setup-and-login step once for each, since they exercise different
code paths (`AI02`–`AI06` in the ISPSS Auth section above) even though every module action below is
identical either way once a token exists.

### Known ISPSS-specific behavior (expected — do not report these as new bugs)

- **`Groups/List`'s `GroupType` filter is unusable on ISPSS.** Every group — including
  LDAP/directory-backed ones — comes back with `groupType='Vault'` and no `directory.directoryType`,
  so filtering for anything but `Vault` silently returns zero rows. `Custom/ExportGroupMembersLDAP`
  and `Custom/ExportGroupMembersLocal` work around this with a groupName-contains-`@` heuristic
  instead of trusting `GroupType` (see the caution section above and Lessons-Learned Section 16).
- **`Policies/GetMasterPolicy` has already been confirmed live to have no equivalent on ISPSS at
  all** (Finding F40, 2026-09-04) — it should return a clean, non-crashing `Failure`, not `IsFatal`.
  No further action is needed here unless specifically re-verifying after other recent changes.
- **`Reports/List`, `Platforms/Rename`, and `Policies/SetMasterPolicy` are Self-Hosted-only** and
  will not appear on an ISPSS profile's menu at all — this is expected (see the driver-level check
  below, which confirms exactly this).
- **`Get-PVWASessionTimeoutMinutes` (`GET {BaseURL}/api/Settings/Timeout`) 404s on ISPSS** and falls
  back to a 4-hour default expiry (see `AI12` above) — an expected fallback, not an error.

### Step 1 — Profile setup

- [ ] Create or select a profile; set **System Type = `[1] Privilege Cloud`**.
- [ ] Set **Auth Method = `[2] Interactive`** or **`[3] SSO`** (not `[1] ClientCredentials`, for the
      reason above).
- [ ] Enter the tenant's **Privilege Cloud Subdomain** (the `acme` in
      `acme.privilegecloud.cyberark.cloud`); confirm `Tenant Portal`/`Tenant Vault` are derived
      correctly and `Discovering identity URL...` resolves to a real `Tenant Auth` value (`AI07`) —
      or falls back cleanly with a `WARN` if discovery fails (`AI08`).

### Step 2 — Authentication (see the ISPSS Auth section above for full AI01-AI12 procedures)

- [ ] `AI02`/`AI03`/`AI04`/`AI05` — whichever `Interactive` challenge shape(s) the tenant is
      configured for (single-factor, MFA mechanism picker, OOB push, or external IdP redirect)
- [ ] `AI06` — `SSO`, if also configured for this tenant
- [ ] `AI09`/`AI10`/`AI11` — re-authentication path for whichever method was used above (let a
      session run long enough to trigger this, or force it by manually expiring/deleting the saved
      token)
- [ ] `AI12` — session-timeout-endpoint 404 fallback (see the expected-behavior note above)

### Step 3 — Driver-level ISPSS-specific checks

- [ ] `D18` — confirm `Platforms/Rename`, `Policies/SetMasterPolicy`, and `Reports/List` are **all
      absent** from this profile's category menus (Self-Hosted-only, hidden for ISPSS)
- [ ] Profile list / header display correctly shows `Privilege Cloud` as the System Type
- [ ] WhatIf mode toggled on for this profile — confirm write suppression works identically to
      Self-Hosted

### Accounts (17 actions, all dual-use)

- [ ] Add · [ ] CancelCpmTask · [ ] ChangeImmediate · [ ] ChangeInVault · [ ] CheckIn · [ ] Delete ·
      [ ] Get · [ ] GetActivity · [ ] GetCredential ·
      [ ] LinkAccount (confirmed working on Self-Hosted this session — F41; ISPSS unconfirmed) ·
      [ ] List (confirm By-Safe mode; confirm whether the ~20K no-safe-filter result cap behaves the
      same on ISPSS) ·
      [ ] Reconcile ·
      [ ] ResumeAutoManagement (its ISPSS code path was deliberately left unchanged/unconfirmed when
      the Self-Hosted endpoint was corrected in Phase 1 — this is the first opportunity to confirm
      it actually works on a real tenant) ·
      [ ] UnlinkAccount (same as LinkAccount above) · [ ] Unlock · [ ] Update (JSON Patch) ·
      [ ] Verify
- [ ] For at least one `AccountName`+`Safe`-resolving action above, confirm the safe-name-with-a-
      space fix (all 16 call sites, routed through `New-CyberArkSearchFilter`) actually works against
      a safe whose name contains a space — unverified against any live tenant as of this writing.

### Safes (8 actions, all dual-use)

- [ ] Add (confirm the `Get-CpmOptions` live CPM query populates the picker on ISPSS, and that it
      falls back to the profile's `CPM_List` if the query fails) ·
      [ ] AddFromTemplate · [ ] AssignCPM (confirm `GET /API/Users?userType=CPM&componentUser=true`
      returns the expected CPM accounts on ISPSS) · [ ] Delete · [ ] Get · [ ] List ·
      [ ] UnassignCPM · [ ] Update
- [ ] This session's `SafeName` validation (length/reserved-characters/leading-whitespace — Finding
      F44) is unit-tested only; confirm it doesn't reject a legitimately-valid ISPSS safe name.

### SafeMembers (6 actions, all dual-use)

- [ ] Add (confirm the `SearchIn` directory picker — `GET /API/Configuration/LDAP/Directories` —
      against ISPSS; unconfirmed on any live tenant as of this writing) ·
      [ ] AddFromTemplateRole · [ ] List · [ ] Remove · [ ] Update · [ ] UpdateFromTemplateRole
- [ ] Confirm all four permission-role presets (`ReadOnlyStrict`, `EndUser`, `PowerUser`,
      `SafeManager` — renamed from `ReadOnly` this session, Finding F47) produce the correct
      permission set on Add and Update.

### Platforms (9 of 10 actions — `Rename` is Self-Hosted only, excluded)

- [ ] Get (confirm field-shape handling — `id` vs `PlatformID`, `general`-nested vs root — on
      ISPSS, unconfirmed) · [ ] List (same field-shape note) · [ ] Copy · [ ] Disable · [ ] Enable ·
      [ ] Export (confirmed live on Self-Hosted only, for the `PlatformID` variant — confirm at
      least that variant on ISPSS) · [ ] Import · [ ] Remove (destructive — disposable sandbox
      platform only) · [ ] SetPSMConfig

### Policies (1 of 2 actions — `SetMasterPolicy` is Self-Hosted only, excluded)

- [x] GetMasterPolicy — **already confirmed (2026-09-04)**: no Master Policy equivalent exists on
      ISPSS; returns a clean, non-fatal `Failure`. No further action needed unless re-verifying.

### Users (2 actions, dual-use)

- [ ] Get · [ ] List

### Groups (7 actions, dual-use — see the `GroupType='Vault'` note above)

- [ ] Add · [ ] AddMember (fixed and confirmed live on Self-Hosted this session — F42; ISPSS
      unconfirmed) · [ ] Delete · [ ] GetMembers (same — F43, Self-Hosted confirmed only) ·
      [ ] List (expect the `GroupType` filter to be unusable — see the known-behavior note above,
      not a bug to report) · [ ] RemoveMember · [ ] Update

### Applications (7 actions, dual-use — only menu visibility has been confirmed on ISPSS so far)

- [ ] Add (menu visibility confirmed 2026-09-02; this session's new validation hardening — F45 — is
      unconfirmed on any live tenant) · [ ] AddAuthMethod · [ ] Delete · [ ] DeleteAuthMethod ·
      [ ] Get · [ ] List · [ ] ListAuthMethods (including the blank-`AppID`-lists-every-application
      behavior, unverified against any live host)
- These 6 (all but `Add`) were expanded from Self-Hosted-only to dual-use on 2026-09-02 after the
  user found only `Add` visible on the ISPSS menu. Their actual ISPSS request/response behavior has
  never been exercised — this is the first opportunity to do so.

### Custom (7 actions, dual-use)

- [ ] ExportAll (confirm it discovers only the modules actually visible on this ISPSS profile — it
      should never attempt `Platforms/Rename`, `Policies/SetMasterPolicy`, or `Reports/List` — and
      that `Policies/GetMasterPolicy` degrades gracefully per the already-confirmed absent-endpoint
      behavior) ·
      [ ] ExportEntitlements ·
      [ ] ExportGroupMembersLDAP (this is the one export module where the `GroupType='Vault'` quirk
      matters most — its groupName-contains-`@` heuristic exists specifically to work around it;
      confirm it actually distinguishes LDAP from local groups correctly on this tenant) ·
      [ ] ExportGroupMembersLocal (same heuristic — confirm normal local/Vault-group export works) ·
      [ ] ExportPlatformDetails (confirmed live on Self-Hosted only) ·
      [ ] TestApi (platform-agnostic; confirm the base URL construction is correct for ISPSS) ·
      [ ] TestConnectivity (platform-agnostic DNS/port/SMB/SSH checks; confirm the vault-password
      fallback correctly resolves an account via the ISPSS `Accounts` endpoint)

### Full end-to-end session

- [ ] One complete session mirroring `D25`: profile creation → `Interactive` or `SSO` login →
      category menu → several module actions spanning multiple categories → an inactivity warning
      → idle past timeout → re-auth → clean exit. Confirm no unhandled exceptions and that the log
      file and exit summary reflect a coherent narrative of everything that happened.

---

## Revision Log

| Date | Change |
|---|---|
| 2026-08-14 | Initial version |
| 2026-08-20 | Added Invoke-SafesAddFromTemplate.ps1 to Component Test Matrix; added its Test Cases section (T01-T24) |
| 2026-08-20 | Corrected test-case ID prefix from AFT to T (matching the actual test file); updated T11 and added T11a-T11c for the OLACEnabled removal / retention mutual-exclusivity fix |
| 2026-08-20 | Added T09a-T09b for the new global $script:ExcludedTemplateMemberNames exclusion list |
| 2026-08-20 | Noted that the new HTTP 504 retry loop in Invoke-CyberArkAPI (CyberArkComms.psm1) is not covered by an automated unit test, for the same reason the 429 retry loop isn't - recommend manual verification |
| 2026-08-20 | Added Invoke-SafeMembersAddFromTemplateRole.ps1 and Invoke-SafeMembersUpdateFromTemplateRole.ps1 to Component Test Matrix (44 tests: ATR01-ATR23, UTR01-UTR21) |
| 2026-08-20 | Added A13 (Import-AuthToken Created field) and D19-D22 (logon-phase age refresh, unconditional 401 invalidation including network-error side effect) manual test procedures |
| 2026-09-02 | Full Self-Hosted-focused review and rewrite: added the Self-Hosted vs. ISPSS scope/caution section; replaced the stale Component Test Matrix with a complete matrix of every module in the project; added the Findings and Fixes section (F01-F11, covering the Join-CyberArkUrl trailing-slash fix, JSON-key secret-masking fix, ApplicationsAdd TryParse validation, ReportsList strict-mode property guards, five CSV-boolean cast fixes, PlatformsList field-fallback fix, ExportGroupMembersLocal ISPSS-groupType fix, two Manage-Privilege.ps1 driver fixes, and the dead Get-AuthToken.ps1 deletion); added the Known Issues / Risk Register (K01-K07, none fixed this pass); replaced the stale Get-AuthToken.ps1-referencing auth test section with a Self-Hosted Auth section covering all 8 auth methods (A01-A18); added D23-D25 driver test cases for the two new driver fixes; added the Self-Hosted Full Functional Checklist enumerating all ~55 module actions plus driver-level checks for the live test pass |
| 2026-09-02 | Updated for Phase 0-2 of `aPePAS-Improvement-Plan-2026-09-02.md` (same day, later revision): corrected the Self-Hosted vs. ISPSS caution section's now-stale claim that `Applications`/`Reports` are Self-Hosted-only (Phase 1 confirmed both work on ISPSS and expanded `SupportedSystems`); added the new Self-Hosted-only entries (`Platforms/Rename`, the new `Policies` category) to the Component Test Matrix; added all 7 new Phase 2 Platforms modules (`Copy`/`Disable`/`Enable`/`Import`/`Remove`/`Rename`/`SetPSMConfig`) and both new Policies modules to the matrix and the Full Functional Checklist; updated the Accounts/Groups/Custom checklist entries for Phase 1's confirmed endpoint/field changes (Cancel CPM Task, Resume Auto Management, Group Member `MemberType`/`IncludeMembers`, Applications `Location`, the three Custom export tools' new auto-save-CSV behavior, and Test API's widened base URL); added a cross-reference at the top to the new `E2E-Automation-Design.md`, which tracks progress toward automating this document's manual checklist |
| 2026-09-02 | Added the new `Custom/Invoke-CustomTestConnectivity.ps1` module (DNS resolution, port checks, and Windows SMB / Linux SSH authentication testing, with a vault password fallback) to the Component Test Matrix and the Full Functional Checklist (Custom now 6 actions); updated the dual-use module count to 62 of 65 total |
| 2026-09-02 | Added a note to the Accounts checklist flagging the `filter=safeName eq ...` space-quoting fix (16 files, confirmed against psPAS's `ConvertTo-FilterString.ps1`) as needing live verification against a safe name containing a space - not yet exercised against a real tenant |
| 2026-09-02 | Per user report, marked every `Action = 'List'` module (Accounts, Safes, SafeMembers, Platforms, Users, Groups, Applications, Reports - 8 modules) as confirmed against a real Self-Hosted host in both the Component Test Matrix and the Full Functional Checklist. `Applications/ListAuthMethods` and `Custom/ExportAll` were explicitly called out as **not** covered by this confirmation - `ListAuthMethods`'s `Action` isn't literally `List`, and both gained new, unverified behavior this same session (see next entry) |
| 2026-09-02 | Per user request: `Invoke-ApplicationsListAuthMethods.ps1`'s `AppID` is now optional - leaving it blank lists auth methods for every application instead of failing with "AppID is required". `Invoke-CustomExportAll.ps1` was updated to discover and run it alongside every `List` action, so Export All now includes it automatically. Both changes are new this session and unverified against a real host - added to the Applications and Custom checklist sections above |
| 2026-09-02 | Per user report from live ISPSS testing: `Reports/Invoke-ReportsList.ps1` 404s on ISPSS/Privilege Cloud, reversing Phase 1's dual-use expansion - `SupportedSystems` reverted to `@('SelfHosted')`. Separately, the user found only `Applications/Add` visible on the ISPSS Applications menu, confirming the other 6 Applications modules (`AddAuthMethod`, `Delete`, `DeleteAuthMethod`, `Get`, `List`, `ListAuthMethods`) had been left Self-Hosted-only in error - all 7 Applications modules now declare `SupportedSystems = @('ISPSS', 'SelfHosted')`. Updated the Self-Hosted vs. ISPSS caution section (SelfHosted-only count 3 -> 4, dual-use count 62 -> 61 of 65), the Component Test Matrix rows for Reports/List and all 7 Applications modules, and the Full Functional Checklist's Applications and Reports section headings and notes accordingly. Only ISPSS menu visibility has been confirmed for the 6 newly-expanded Applications modules; their actual ISPSS request/response behavior remains unverified |
| 2026-09-02 | Per user report: `Invoke-AccountsChangeInVault.ps1` was calling `POST /API/Accounts/{id}/SetNextPassword` (a queued-for-CPM change) instead of `POST /API/Accounts/{id}/Password/Update` (an immediate vault-only change, matching the module's own name and description). Confirmed the distinction against the local Swagger spec's descriptions for both paths and against psPAS's `Invoke-PASCPMOperation.ps1`, which treats them as two separate parameter sets. Fixed the endpoint (request body unchanged - both share the `NewCredentials` field); added Finding F12 and a regression test asserting the exact endpoint string |
| 2026-09-02 | Per user report (`[FATAL] PropertyNotFoundException` on `.Count`, hit against `Accounts / List` returning exactly one row): fixed `Manage-Privilege.ps1`'s `Invoke-ActionModule`, where `$tableData`/`$displayData` were each assigned from an `if/else` without an outer `@(...)` wrap - a one-item branch result collapsed to a bare scalar instead of a one-element array, the single-item counterpart of the already-documented Lessons-Learned 9.8 empty-collapses-to-`$null` bug. Wrapped both entire `if/else` expressions in `@(...)`. Added Finding F13, a driver-level checklist item, and a Lessons-Learned 9.8 addendum documenting the new manifestation and that reproducing it requires real `powershell.exe` (PS 5.1) - PowerShell 7/`pwsh` masks it via a synthetic scalar `.Count` |
| 2026-09-02 | Per user report and design direction: `Invoke-AccountsCancelCpmTask.ps1` and `Invoke-AccountsResumeAutoManagement.ps1` now fall back to a version-agnostic endpoint on an HTTP 404 from the newer, version-gated one (`/Cancel/` needs PVWA 15.2+, `/Resume/` needs 15.0-15.2+ depending on source - neither this project nor psPAS can query the actual version). `CancelCpmTask` falls back to the pre-Phase-1 `/StopImmediateAutoMgmtOperations` endpoint; `ResumeAutoManagement` (Self-Hosted only) falls back to the same PATCH `automaticManagementEnabled` approach already used for ISPSS. Only a 404 triggers the fallback - any other failure stays a real, non-fallback error. Added Finding F14, checklist notes, and regression tests covering the fallback-succeeds, no-fallback-on-non-404, and fallback-also-fails cases for both modules |
| 2026-09-02 | Per user report (Custom Test API: the whole process silently closes with no error shown when the session token expires): found `Invoke-CustomTestApi.ps1` was the only module enabling the `IgnoreSSL` bypass via a raw `ServerCertificateValidationCallback` scriptblock instead of `Invoke-CyberArkAPI`'s already-safe, compiled-class-based `Disable-SSLValidation` - a known hazard if .NET's TLS stack ever invokes that delegate off the runspace's own thread, which a fresh handshake during re-authentication could plausibly trigger. Exported `Disable-SSLValidation` from `CyberArkComms.psm1` and switched `Invoke-CustomTestApi.ps1` to use it. Added Finding F15 and a checklist note - **not yet confirmed this was the actual cause**, since no error was available to inspect; needs live verification with `IgnoreSSL` enabled and a token allowed to expire mid-session |
| 2026-09-03 | Added Finding F16 (Test API's `catch` block re-reading an already-consumed `WebException` response stream, discovered live via a real 400 whose body came back `null`) and Finding F17 (per user request: `Invoke-CyberArkAPI`'s `ErrorMessage` now includes the CyberArk `ErrorCode` prefix, e.g. `"PASWS001W: The account is locked by: [ca_jesse]."`, applied once in the shared helper so every module's own error text picks it up automatically; also fixed a latent `Parse-CyberArkError` bug where a body missing either field threw under strict mode and discarded both). Added Finding F18 (per user request: Test API no longer prompts for Query Params on any method other than `GET`). Added C29-C32 regression tests to `CyberArkComms.Tests.ps1` for F17 |
| 2026-09-03 | Added Finding F19 (per user request: `Invoke-CyberArkAPI`'s error message now falls back to the raw response body when structured `ErrorCode`/`ErrorMessage` parsing finds neither, rather than a generic HTTP-status-only message; updated C32 and added C33). Added Finding F20 (per user request: Add Safe no longer prompts for `Location` interactively; Add Safe's `ManagingCPM` prompt now matches Add Safe From Template's numbered picker; all three CPM-picker screens - Add, AddFromTemplate, AssignCPM - now share one `Get-CpmOptions` source in `Manage-Privilege.ps1`, live-query-first with a `CPM_List` fallback on failure, superseding the prior per-page split recorded in Architecture.md). Removed T32-T35 and A15-A17, which tested the two now-deleted per-module CPM-source functions; manually verified `Get-CpmOptions`'s four cases via a standalone `powershell.exe` repro instead, for the same reason `Invoke-EntitySearch` has no unit coverage of its own. Updated the Safes checklist for all three affected actions |
| 2026-09-03 | Added Finding F21 (per user report, live: `?search=` values containing a period fail to match on the CyberArk API unless the period is percent-encoded as `%2E` - `[Uri]::EscapeDataString` leaves `.` as a literal character per RFC 3986. Fixed once in `New-CyberArkQuery`, applied case-insensitively to the `search` key only, covering every module that routes through `Invoke-CyberArkAPI`'s `-QueryParams`). Added C34-C36 to `CyberArkComms.Tests.ps1`. Added Lessons-Learned Section 34 |
| 2026-09-03 | Added Finding F22 (per user request: `Custom/TestConnectivity` output now includes `Safe`, `Username`, and `PasswordSource` columns identifying which vaulted account, if any, was used to make the connection - `Resolve-VaultPassword` returns `SafeName`/`Username` alongside `Password` to support this). Updated TC11-TC12, TC20, TC21, TC27-TC29 in `Invoke-CustomTestConnectivity.Tests.ps1`; updated the Custom checklist |
| 2026-09-03 | Added Finding F23 (per user report, full stack trace: `[FATAL] PropertyNotFoundException` on `ProcessStartInfo.ArgumentList`, crashing every Linux SSH auth attempt - reproduced live with a different symptom on this dev machine too, confirming `ArgumentList` cannot be trusted across environments even when it appears present via reflection; fixed with a probed fallback to a manually-quoted `.Arguments` string). Added Finding F24 (per user request: the Server Type prompt now says "Enter 1 for Windows or 2 for Linux" instead of inviting a typed name, and its displayed default is translated to a number). Added the `ConvertTo-Win32QuotedArgument` `Describe` block (TC30-TC34) to `Invoke-CustomTestConnectivity.Tests.ps1`. Added Lessons-Learned Section 35 |
| 2026-09-03 | Added Finding F25 (per user report, correctly guessing the cause: a Linux SSH timeout was reproduced live against a real test host with its host key removed from `known_hosts`, confirming the PS7 SSH transport path hangs on the unanswerable "unknown host key" question in a non-interactive child process; fixed with `-Options @{StrictHostKeyChecking='no'}`, verified live to reduce the hang to under a second - also discovered, while verifying, that a *known* host key can still time out due to a separate, pre-existing password-prompt-without-a-console limitation). Added Finding F26 (per user request: Test Connectivity's auto-saved CSV filename now includes the tested Address, via a new generic, opt-in `ModuleMeta.CsvFilenameField`). Updated the Custom checklist and Component Test Matrix row |
| 2026-09-04 | Added Finding F27 (per user report and follow-up direction: F25's host-key fix wasn't enough - a real Linux SSH auth attempt via the PS7 path still timed out on the password prompt itself, a pre-existing limitation. The user installed `plink.exe` at the project root and asked for it to be tried instead, then also asked for the standard PuTTY install directories (x86 before x64) to be checked. `Test-LinuxSshAuth` now tries plink first via a new `Find-PlinkExecutable` helper checking PATH, the project root, then both Program Files locations. Verified live against the real test host with plink's own host-key cache genuinely empty: it fails in well under a second with a clear, actionable message rather than hanging - confirmed PuTTY has no CLI equivalent to `StrictHostKeyChecking=no`). Added the `Find-PlinkExecutable` `Describe` block (TC36-TC39). Updated the Custom checklist and Component Test Matrix row - a successful password auth via plink still needs live confirmation, since no real credentials were available for the test host |
| 2026-09-04 | Per user-provided real test credentials, ran the first fully live end-to-end test of this module's Linux path against 172.21.20.14 and found two more real bugs in the process. Added Finding F28 (`Resolve-ConnectivityTarget` aborted the whole test for a literal IP with no reverse-DNS/PTR record - completely normal for an internal/test host - instead of proceeding with the address it already had; fixed to treat that specific case as a successful resolution with no hostname, using RFC 5737 TEST-NET-1 for a deterministic test). Added Finding F29 (plink's "host key is not cached" failure always includes its own computed fingerprint; `Test-LinuxSshAuth` now parses it and retries once with `-hostkey`, confirmed live end-to-end - also fixed a `script:`-qualified call site that silently made the plink lookup unmockable, the same Pester gotcha already documented elsewhere in this project). After both fixes, the live test succeeded completely: `AuthStatus: Success` for a real SSH login, and a wrong password confirmed to still fail cleanly rather than hang. Added TC40-TC43. Marked F26/F27/F28/F29 as fully live-confirmed in the Custom checklist and updated the Component Test Matrix row |
| 2026-09-04 | Rebranded README.md to aPePAS and reviewed it for accuracy against the live codebase; created `Docs/User-Guide.md`, a new end-user usage guide |
| 2026-09-04 | Added Finding F30: a routine pre-commit full-suite run surfaced 7 pre-existing test failures (`PropertyNotFoundException: 'Count'`) in `Invoke-SafeMembersAdd.Tests.ps1` and `Invoke-SafesAddFromTemplate.Tests.ps1`, unrelated to that commit - a single-match `Where-Object` result or a function returning its single-item fallback both unwrap to a bare scalar under PowerShell's pipeline, which has no `.Count` under strict mode. Test-only bug; the real call site already guards against it. Fixed by wrapping all 7 assertions in `@(...)`; all 1052 tests now pass. Added Lessons-Learned Section 36 |
| 2026-09-09 | Started Phase 3 (Validation hardening) of `aPePAS-Improvement-Plan-2026-09-02.md`, the next unstarted phase in the plan and the branch's namesake. Added Finding F44 (`Invoke-SafesAdd.ps1`/`Invoke-SafesUpdate.ps1` now reject a `SafeName` over 28 characters, with leading whitespace, or containing a reserved character `\ / : * < > " . \|`, matching psPAS's `[ValidateLength(0,28)]` plus the Vault's own reserved-character rule). Added Finding F45 (`Invoke-ApplicationsAdd.ps1` now range-checks `AccessPermittedFrom`/`AccessPermittedTo` to 0-23, corrects the "epoch seconds" mislabeling in comments/error text to "hour-of-day", and adds length/charset checks on `AppID` (1-127 chars, no `&`), `Description` (<=99), `BusinessOwnerFName` (<=29), and `BusinessOwnerPhone` (<=24), matching psPAS's `Add-PASApplication.ps1` validation attributes). Added A21-A24/U18-U20 (Safes) and 7 new cases (Applications) across the three modules' test files; fixed one pre-existing test (`Invoke-ApplicationsAdd.Tests.ps1`'s "passes valid numeric AccessPermittedFrom/To" case, which used epoch-seconds-shaped values now correctly rejected by the new range check) and one new test's mock fixture (`Invoke-SafesAdd.Tests.ps1`'s A24 needed the full `$script:SampleSafeResponse` fixture, not a bare object, to avoid a `PropertyNotFoundException` on `creationTime` under strict mode). All 1118 unit tests pass. None of Phase 3's changes have been live-verified yet. Reviewed the rest of the improvement plan against the current codebase first: Phases 0-2 and most of Phase 1/4 are already done (confirmed via grep against the actual code, not assumed from the plan document), leaving Phase 3, Reports' ISPSS support (Phase 1), the pagination collection-detection generalization (Phase 4), and the README ReadOnly-role callout (Phase 5) as the remaining open items |
| 2026-09-09 | Per user request ("Generalize pagination"), completed Phase 4's pagination collection-detection item. Added Finding F46: `Invoke-CyberArkAPI`'s pagination logic previously recognized only a hardcoded list of collection property names, duplicated at two call sites - a future endpoint using an unanticipated name would have silently returned only its first page with no error. Added `Find-CyberArkCollectionProperty` to `CyberArkComms.psm1`: tries the same known-name list first, then falls back to the first array-valued property on the response, mirroring psPAS's `Get-NextLink.ps1` (read directly from the local reference copy to confirm the pattern before implementing it, rather than guessing). Both call sites now share this one helper. Added C41/C42 to `CyberArkComms.Tests.ps1` using a made-up `Widgets` collection name to prove the fallback actually works, not just that the known-name fast path still passes. All 1120 unit tests pass, including the pre-existing `value`-keyed pagination tests unchanged. Added a Design Decision row to Architecture.md. Not live-verified - no endpoint in production use exercises the new fallback path yet |
| 2026-09-09 | Per user request ("Update aPePAS ReadOnly to ReadOnlyStrict and document this"), superseding Phase 5's originally-planned documentation-only callout with an actual rename. Added Finding F47: renamed the SafeMembers `ReadOnly` permission-role preset to `ReadOnlyStrict` throughout `Invoke-SafeMembersAdd.ps1`/`Invoke-SafeMembersUpdate.ps1` (schema/prompt text, default values, menus, switch cases) to avoid the same name meaning something different than PVWA's/psPAS's own built-in `ReadOnly` role (which grants `retrieveAccounts`). Confirmed the rename is backward-compatible before making it: `Get-PermissionSet`'s `switch` never had an explicit case for the old name, so it already fell through to the same `default` branch as any other unrecognized role - the old literal string still produces the identical permission set today. Added MA11a to `Invoke-SafeMembersAdd.Tests.ps1` to lock that guarantee in with a test, not just note it in prose. Documented the naming rationale in-code, in README.md's Features section, and in Docs/User-Guide.md's Troubleshooting section. All 1121 unit tests pass. Added a Design Decision row to Architecture.md |
| 2026-09-11 | Per user request, added a new "Privilege Cloud (ISPSS) Full Functional Checklist" section - the ISPSS counterpart to the existing Self-Hosted Full Functional Checklist, since almost none of that checklist's items have actually been exercised against a real Privilege Cloud tenant. Explicitly scoped to the 3 auth methods that require a human present at the console for the whole session (`Interactive`'s console MFA challenge loop, `SSO`'s WebView2 browser login) rather than the silent `ClientCredentials` grant, per the user's specific request that this pass "prompt for interactive authentication." Excludes the 3 Self-Hosted-only actions (`Platforms/Rename`, `Policies/SetMasterPolicy`, `Reports/List`) and calls out already-known ISPSS-specific behavior up front (the `GroupType='Vault'` quirk, `Policies/GetMasterPolicy`'s already-confirmed absence, the `Settings/Timeout` 404 fallback) so a tester doesn't mistake expected behavior for a new bug. Documentation-only change - no code or tests were touched |
| 2026-09-18 | Per user report, live: `SSO` authentication failed with `Microsoft.Web.WebView2.WinForms.dll not found` while attempting the interactive Privilege Cloud test pass. Added Finding F48 - the assembly genuinely didn't exist anywhere on the user's machine (confirmed directly), while the underlying Edge WebView2 Runtime was already installed. Fixed locally by downloading the official NuGet package and placing the 3 needed files in `Auth\WebView2\`, one of `Import-WebView2Assembly`'s existing candidate paths - not a code bug, a missing local dependency. While fixing it, found and added K11: the error message's own suggested `-WebView2AssemblyPath` remedy is unreachable through the normal driver, since `Manage-Privilege.ps1` never exposes that parameter anywhere. Rewrote the README Requirements callout with the exact files needed, where to get them, and corrected the `-WebView2AssemblyPath` overstatement. Added `Auth/WebView2/` to `.gitignore`. No code or tests changed - this was a local-environment fix plus a documentation correction |
| 2026-09-18 | Per user report, live, immediately after F48: the WebView2 window now opens but is completely blank, no error shown. Added Finding F49 - a real bug in `Invoke-WebView2Window` (`Auth\CyberArk.Auth.Common.psm1`): the `CoreWebView2InitializationCompleted` handler never checked `$e.IsSuccess` before calling `.Navigate()`, so an environment-creation failure (or a navigation failure) previously failed completely silently, leaving exactly this symptom. Fixed by checking `IsSuccess`, wrapping `.Navigate()` in `try/catch`, and threading a real error message back through `Invoke-WebView2Window`'s return path instead of only ever the generic "timed out or cancelled" message. Also flagged that the profile involved in F48 pointed at `pvwa.company.com`, this project's own documentation placeholder domain, as a separate, more mundane possible explanation now distinguishable from a real initialization bug. All 1121 unit tests still pass (unrelated - this class of code has never been unit-testable). **Not yet live-verified** |
| 2026-09-18 | Per user report, live, immediately after F49: the user confirmed `pvwa.company.com` is their real lab address (a deliberate, coincidental choice, not this project's placeholder), then reported a new error after closing the window: `Index was out of range... Parameter name: index`. Added Finding F50 - traced every collection-indexing site in the SAML call chain and found `$ps.Streams.Error[0]` in `Invoke-WebView2Window`, a raw index-0 access into a `PSDataCollection<ErrorRecord>` that throws exactly this exception when `HadErrors` is `$true` but the collection is actually empty (a known edge case, plausibly matching an STA runspace's WinForms message loop ending right as the window closes). Replaced with `Select-Object -First 1`. Per the user's explicit request ("Is there a way to add some messaging to show what it is doing? What address it is trying to reach?"), also added a live status label inside the WebView2 window itself (shows the current page URL, updated ~every 750ms) and upgraded the SAML/OIDC/SSO functions' single `Write-Verbose` line each to visible `Write-Host` lines. All 1121 unit tests still pass. **Not yet live-verified** |
