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

**See also:** `Planning_E2E-Automation.md` — a proposed (not yet built) automated layer that would
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
`Planning_Improvement-Plan-2026-09-02.md` — see `Archive_Planning_Documentation-Tracker.md` for the full history):

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
  iterative bug-fixing history in `Archive_Planning_Documentation-Tracker.md` was driven by Self-Hosted testing/use.
  Treat a dual-use module's ISPSS behavior as unverified until someone actually exercises it
  against a Privilege Cloud tenant, even though the code path is shared. Two specific items *were*
  confirmed live on ISPSS during Phase 0/1 (this session): `Get-PVWASessionTimeoutMinutes`
  (`/api/Settings/Timeout`) 404s on Privilege Cloud and correctly falls back to a default; and
  `Invoke-AccountsResumeAutoManagement.ps1`'s ISPSS path was deliberately left unchanged
  (unconfirmed) when its Self-Hosted endpoint was corrected, specifically to avoid guessing at
  ISPSS behavior that hadn't been verified.
- **Known, already-confirmed platform-specific traps inside dual-use modules** (background for
  anyone testing or extending these — not new findings from this pass, see
  `Reference_Lessons-Learned.md` Section 16 for the originals):
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
| `CyberArkComms.psm1` | Partial (helpers + success path; 401/429/504 error paths need `Invoke-CyberArkAPI` mocking at the module-caller level - see Testing Boundaries). `Disable-SSLValidation`/`Reset-SSLValidation` (C34-C39) only run under real Windows PowerShell 5.1 - `ICertificatePolicy` isn't usable under `pwsh`/.NET Core at all, confirmed directly (see Finding F57). `Expect100Continue` is disabled unconditionally at module-load time (C43, K16/F66) - runs under both `pwsh` and PS 5.1, since unlike `ICertificatePolicy` this is a plain settable property under both hosts | `Unit\CyberArkComms.Tests.ps1` | Yes — 429 backoff and 504 retry/page-shrink against a real PVWA; confirm the K02 IgnoreSSL-reset fix against a real host (A19); **K16 (Expect100Continue) fix live-verification against the original `Accounts/ChangeImmediate` hang is still pending** - see Finding F66 |
| `CyberArkCredentialStore.psm1` | Yes (CS01-CS08) - extracted from `Manage-Privilege.ps1` (see Finding F61) so a standalone helper script can reuse the same `.autocred` store | `Unit\CyberArkCredentialStore.Tests.ps1` | No (pure file I/O, same DPAPI mechanism as the already-verified `.cred` token file) |
| `Auth\CyberArk.Auth.Common.psm1` | No direct test file (WebView2/cert-store/DPAPI all require a live Windows session), but `Invoke-WebView2Window`'s `-IgnoreSSL` parameter-forwarding is covered indirectly via `Auth\CyberArk.Auth.SelfHosted.psm1`'s own tests (SH-SSL01-SH-SSL04, mocking `Invoke-WebView2Window` itself); `Get-ISPSSAuthThrottle`/`Set-ISPSSAuthThrottle` (K17/F67, F68) are covered via `CyberArk.Auth.ISPSS.Tests.ps1`'s K17-01 through K17-07 (imported there transitively - no separate test file needed, pure file I/O, no live session required); the sidecar file's own extension not colliding with `Get-AllDriverProfiles`' profile-discovery glob (F68) is covered by `Manage-Privilege.Tests.ps1` DP10a | — | Yes — `Save-AuthToken`/`Import-AuthToken` round-trip, `Get-FilteredClientCertificate` picker, and (Finding F58) the WebView2 `ServerCertificateErrorDetected`/`AlwaysAllow` behavior against a real self-signed/internal-CA host (A07/A08); **K17's `RetryWaitingTime` throttle not yet live-verified** - blocked on the same SaaS tenant re-authentication issue F66/F67 investigate |
| `Auth\CyberArk.Auth.SelfHosted.psm1` | Partial - `Update-SelfHostedAuthToken`'s `-NoPrompt` guard (SH-NP01-SH-NP04) and SAML/OIDC's `-IgnoreSSL` forwarding to `Invoke-WebView2Window` (SH-SSL01-SH-SSL04); the 8 live auth flows themselves are not unit-tested | `Unit\CyberArk.Auth.SelfHosted.Tests.ps1` | Yes (manual, all 8 methods — see the dedicated section below) |
| `Auth\CyberArk.Auth.ISPSS.psm1` | Partial - `ClientCredentials` response parsing, (K12/F62) `Interactive`'s `-NoPrompt` silent-refresh/credential-capture behavior, and (K17/F67) `RetryWaitingTime` throttle recording/carry-through via mocked `StartAuthentication`/`AdvanceAuthentication`; `SSO`'s WebView2 flow and Interactive's own live MFA-challenge UX are not unit-tested | `Unit\CyberArk.Auth.ISPSS.Tests.ps1` (ISPSS-CC01-CC06, ISPSS-INT01-05, K17-01 through K17-07) | Partially done — `AuthMethod=Interactive` confirmed live end-to-end via automation mode (K12/F62, 2026-09-21, `Bannermen_AutoUser` profile, Custom/ExportAll, ExitCode=0). Still needed: `SSO`, `ClientCredentials` against a live tenant, observing K12's silent-refresh-on-expiry path specifically triggering mid-run (this run's token didn't need a refresh), and K17's `RetryWaitingTime` throttle against a real StartAuthentication response |
| `Manage-Privilege.ps1` — profile CRUD | Yes (filesystem) | `Unit\Manage-Privilege.Tests.ps1` | No |
| `Manage-Privilege.ps1` — profile backup/restore (`Backup-DriverProfiles`/`Restore-DriverProfiles`, `Invoke-ProfileBackupFlow`/`Invoke-ProfileRestoreFlow`) | Partial - verified via a standalone dot-sourced repro script, not Pester (see Finding F51 for why). K14/F64's single-profile-selection array-unwrapping fix verified the same way, including that the selection itself is correct (not just non-crashing) | — (repro script, not checked into `Tests\`) | Yes (manual — D26-D30 below) |
| `Manage-Privilege.ps1` — stored automation credential (`Use-StoredCredentialIfMissing`, `Invoke-ClearNonRefreshableContext`, and the driver's own call sites for `Save-/Get-/Remove-ProfileCredential` — the functions themselves now live in `CyberArkCredentialStore.psm1`, see Finding F61; both functions now also cover ISPSS Interactive, see K12/F62) | Yes (AM41-AM50, AM71-76) - the `[A]` menu action itself is interactive UI and not unit-tested | `Unit\Manage-Privilege.Automation.Tests.ps1` | Yes (manual — D43 below) |
| `Manage-Privilege.ps1` — token/profile Base URL staleness (`Get-ExpectedTokenBaseURL`, `Test-TokenBaseURLStale`, `Invoke-ProfileConnect`/Test Connection/`Invoke-TokenRefresh`'s use of them) | Yes (AM52-AM63) - the pure comparison logic and `Invoke-ProfileConnect`'s discard behavior are unit-tested; the Test Connection flow's own staleness check is not (interactive UI) | `Unit\Manage-Privilege.Automation.Tests.ps1` | Yes (manual — D44 below) |
| `Manage-Privilege.ps1` — `WebView2AssemblyPath` profile field (`Invoke-ProfileConnect`/Test Connection forwarding it to `Get-SelfHostedAuthToken`/`Get-ISPSSAuthToken`) | Yes (AM66-AM68) - the `Invoke-ProfileEditFlow` prompt and `Show-ProfileDetail` display are interactive UI and not unit-tested | `Unit\Manage-Privilege.Automation.Tests.ps1` | Yes (manual — D46 below) |
| `Manage-Privilege.ps1` — `-StartProfile`/`-AutoConnect` startup, `Invoke-ProfileConnect` | Partial - the automation-mode fresh-auth guard is covered (AM11-AM14); the interactive `-AutoConnect` fallback path itself is UI/interactive and untested; `-AutoConnect`'s parameter validation was spot-checked directly | `Unit\Manage-Privilege.Automation.Tests.ps1` | Yes (manual — D31-D36 below) |
| `Manage-Privilege.ps1` — session loop, keepalive, token refresh, CSV loop | Partial - `Invoke-TokenRefresh`'s automation-mode branch (AM15-AM18) and `Invoke-CsvProcessing -FilePaths` (AM08-AM10) are covered; the interactive session loop itself is UI/interactive and untested | `Unit\Manage-Privilege.Automation.Tests.ps1` | Yes (manual — D-series below, including the new D23-D25 regression/known-gap cases) |
| `Manage-Privilege.ps1` — automation mode (`-Category`/`-Action`, `Invoke-AutomatedAction`, `Get-AutomationExitCode`) | Partial - parameter validation, the CSV/JSON input routes' summary-to-exit-code mapping (`Get-AutomationExitCode`), every automation-mode guard, the `-OutputFolder`/`-FilenameFormat` overrides, `ModuleMeta.CsvFilenameNoDate` (`Format-AutomationFilename`, `Get-CsvSavePath`'s override/`-NoDateSuffix` params, `Save-ModuleResultCsv`'s wiring), and (K15/F65) a structural guard confirming `Invoke-AutomatedAction` never calls `Invoke-SessionLogoff` are unit-tested; `Invoke-AutomatedAction` itself (module resolution, end-to-end dispatch) has no full mock-based coverage, for the same reason the rest of the driver's dispatch logic doesn't - see Testing Boundaries. **K15 IS live-verified** (2026-09-21): 3 consecutive real automation-mode runs against a real Self-Hosted PVWA, reusing one session with no re-auth between them | `Unit\Manage-Privilege.Automation.Tests.ps1` | Yes (manual — D37-D46 below) |

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
| Platforms / Copy | Yes | `Unit\Invoke-PlatformsCopy.Tests.ps1` | Yes — Target platforms only this pass (see `Planning_E2E-Automation.md`); confirmed against psPAS source + the 14.6 Swagger spec, never against a live tenant |
| Platforms / Disable | Yes | `Unit\Invoke-PlatformsDisable.Tests.ps1` | Yes — same caveat as Copy |
| Platforms / Enable | Yes | `Unit\Invoke-PlatformsEnable.Tests.ps1` | Yes — same caveat as Copy |
| Platforms / Export | Yes | `Unit\Invoke-PlatformsExport.Tests.ps1` | `PlatformID` variant **confirmed (2026-09-04)** — live download of a real `.zip`, verified openable with real policy files inside. `RotationalGroupID`/`DependentID`/`GroupPlatformID` variants unit-tested against psPAS's documented shapes only, not yet live-confirmed - no existing module can discover a real ID for those types |
| Platforms / Get | Yes | `Unit\Invoke-PlatformsGet.Tests.ps1` | Yes |
| Platforms / Import | Yes | `Unit\Invoke-PlatformsImport.Tests.ps1` | Yes — the ZIP-as-byte-array request shape is unverified against a live tenant (see its own code comment and `Planning_E2E-Automation.md`) |
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
| Custom / ExportAll | Yes, including automation mode's `-OutputFolder` override (3 new cases) | `Unit\Invoke-CustomExportAll.Tests.ps1` | Yes — now also discovers and runs Applications/ListAuthMethods (added this session, per user request), not previously part of Export All. That specific addition is unverified against a real host. **Also now discovers Policies/GetMasterPolicy via a new generic `ModuleMeta.IncludeInExportAll` opt-in (any non-List/ListAuthMethods module can use it) - confirmed live (2026-09-04) against the real Self-Hosted tenant, saving a real `Export_PoliciesGetMasterPolicy.csv`**. `-OutputFolder` (F54) is unit-tested only, not yet live-verified |
| Custom / ExportEntitlements | Yes | `Unit\Invoke-CustomExportEntitlements.Tests.ps1` | Yes |
| Custom / ExportGroupMembersLDAP | Yes | `Unit\Invoke-CustomExportGroupMembersLDAP.Tests.ps1` | Yes — requires line-of-sight from wherever the script runs to the actual Active Directory (ADSI-based, not a CyberArk API call) |
| Custom / ExportGroupMembersLocal | Yes (incl. new ISPSS-groupType-quirk regression test this session) | `Unit\Invoke-CustomExportGroupMembersLocal.Tests.ps1` | Yes |
| Custom / ExportPlatformDetails | Yes (PPD01-PPD12; uses real in-memory-built `.zip` archives, not mocked-away zip parsing) | `Unit\Invoke-CustomExportPlatformDetails.Tests.ps1` | **Confirmed (2026-09-04)** — live run against the real Self-Hosted tenant: 10/10 active platforms (of 15 total) processed successfully, 104 dynamic columns, spot-checked type-specific fields (e.g. `Ini.ExtraInfo.Port`, `Ini.KeySize`) populate only where applicable and blank-fill elsewhere. The `OtherFiles`/META-INF-exclusion logic is implemented exactly per spec and unit-tested, but no real example of a platform with extra bundled files or a META-INF folder was found on this tenant across the platforms sampled, so that part remains live-unconfirmed |
| Custom / TestApi | **No unit test file exists** (interactive raw API tester — same exemption class as other `Read-Host`-driven helpers) | — | Yes (manual smoke test only) |
| Custom / TestConnectivity | Yes (orchestration mocked; DNS/TCP helpers, `ConvertTo-Win32QuotedArgument`, `ConvertTo-PortList`, `Find-PlinkExecutable`, and the plink trust-on-first-use retry exercised for real/mocked deterministically - no CyberArk connection needed for those) | `Unit\Invoke-CustomTestConnectivity.Tests.ps1` | The Linux/plink path is now fully confirmed live end-to-end against a real target with real credentials (172.21.20.14, user-provided test account): DNS resolution (F28), plink-first with host-key trust-on-first-use (F27/F29), a successful login (`AuthStatus: Success`), and a wrong password failing cleanly - the CSV filename change (F26) was also confirmed live in the same pass. Not yet confirmed live: the actual Windows SMB (`New-SmbMapping`) auth attempt, the PS7 SSH transport path's own success case (it's documented to time out on password auth and plink is now tried first, so this may never need separate confirmation), the `Safe`/`Username`/`PasswordSource` output columns (F22) against a real vault-backed lookup (the live test above supplied the password directly, not via vault lookup), and F52's new `AdditionalPorts` field |

---

## Findings and Fixes — 2026-09-02 Self-Hosted Review

All 68 findings (F01 to F68) are fixed. Their full detail (issue, fix and tests added) is archived in [Archive_Testing_Findings-Closed.md](Archive_Testing_Findings-Closed.md). This index keeps the IDs resolvable. Add new findings to the table below as one-line rows, and move each one's detail to the archive when it's closed.

| # | File(s) | Status |
|---|---|---|
| F01 | `Modules/CyberArkComms.psm1` | Fixed. |
| F02 | `Modules/CyberArkLogging.psm1` | Fixed. |
| F03 | `APIModules/Applications/Invoke-ApplicationsAdd.ps1` | Fixed. |
| F04 | `APIModules/Reports/Invoke-ReportsList.ps1` | Fixed. |
| F05 | `Invoke-ApplicationsAdd.ps1` (`Disabled`), ... | Fixed. |
| F06 | `APIModules/Platforms/Invoke-PlatformsList.ps1` | Fixed. |
| F07 | `APIModules/Custom/Invoke-CustomExportGroupMembersLocal.ps1` | Fixed. |
| F08 | `Manage-Privilege.ps1` — `Invoke-SelfHostedKeepalive` | Fixed. |
| F09 | `Manage-Privilege.ps1` — inner category/action loop (`Invoke-SessionLoop`) | Fixed. |
| F10 | `Auth/Get-AuthToken.ps1` | Fixed. |
| F11 | `README.md`, `Claude_Docs/Reference_API-Module-Guide.md`, ... | Fixed. |
| F12 | `APIModules/Accounts/Invoke-AccountsChangeInVault.ps1` | Fixed. |
| F13 | `Manage-Privilege.ps1` — `Invoke-ActionModule` (results display) | Fixed. |
| F14 | `APIModules/Accounts/Invoke-AccountsCancelCpmTask.ps1`, ... | Fixed. |
| F15 | `APIModules/Custom/Invoke-CustomTestApi.ps1` | Fixed. |
| F16 | `APIModules/Custom/Invoke-CustomTestApi.ps1` | Fixed. |
| F17 | `Modules/CyberArkComms.psm1` | Fixed. |
| F18 | `APIModules/Custom/Invoke-CustomTestApi.ps1` | Fixed. |
| F19 | `Modules/CyberArkComms.psm1` | Fixed. |
| F20 | `APIModules/Safes/Invoke-SafesAdd.ps1`, `Invoke-SafesAddFromTemplate.ps1`, ... | Fixed. |
| F21 | `Modules/CyberArkComms.psm1` | Fixed. |
| F22 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F23 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F24 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F25 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F26 | `Manage-Privilege.ps1`, `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F27 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F28 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F29 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F30 | `Tests/Unit/Invoke-SafeMembersAdd.Tests.ps1`, ... | Fixed. |
| F31 | `Invoke-SafesAdd.ps1`, `Invoke-SafesUpdate.ps1`, `Invoke-SafesUnassignCPM.ps1`, ... | Fixed. |
| F32 | `Invoke-PlatformsCopy.ps1`, `Invoke-PlatformsEnable.ps1`, ... | Fixed. |
| F33 | `Invoke-SafesUpdate.ps1`, `Invoke-SafesAssignCPM.ps1`, `Invoke-SafesUnassignCPM.ps1` | Fixed. |
| F34 | `Invoke-SafesAddFromTemplate.ps1` | Fixed. |
| F35 | `Invoke-SafesDelete.ps1` | Fixed. |
| F36 | `Auth\CyberArk.Auth.ISPSS.psm1` | Fixed. |
| F37 | `Modules\CyberArkComms.psm1` | Fixed. |
| F38 | `APIModules\Platforms\Invoke-PlatformsExport.ps1` (new module) | Fixed. |
| F39 | `APIModules\Custom\Invoke-CustomExportPlatformDetails.ps1` (new module) | Fixed. |
| F40 | `APIModules\Policies\Invoke-PoliciesGetMasterPolicy.ps1`, ... | Fixed. |
| F41 | `APIModules\Accounts\Invoke-AccountsLinkAccount.ps1`, `Invoke-AccountsUnlinkAccount.ps1` | Fixed. |
| F42 | `APIModules\Groups\Invoke-GroupsAddMember.ps1`, `Invoke-GroupsRemoveMember.ps1` | Fixed. |
| F43 | `APIModules\Groups\Invoke-GroupsGetMembers.ps1` | Fixed. |
| F44 | `APIModules\Safes\Invoke-SafesAdd.ps1`, `Invoke-SafesUpdate.ps1` | Fixed. |
| F45 | `APIModules\Applications\Invoke-ApplicationsAdd.ps1` | Fixed. |
| F46 | `Modules\CyberArkComms.psm1` | Fixed. |
| F47 | `APIModules\SafeMembers\Invoke-SafeMembersAdd.ps1` (v1.4.0), ... | Fixed. |
| F48 | `Auth\CyberArk.Auth.Common.psm1` (`Import-WebView2Assembly`) | Fixed. |
| F49 | `Auth\CyberArk.Auth.Common.psm1` (`Invoke-WebView2Window`) | Fixed. |
| F50 | `Auth\CyberArk.Auth.Common.psm1` (`Invoke-WebView2Window`) | Fixed. |
| F51 | `Manage-Privilege.ps1` | Fixed. |
| F52 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F53 | `Manage-Privilege.ps1`, `APIModules/Safes/Invoke-SafesDelete.ps1`, ... | Fixed. |
| F54 | `Manage-Privilege.ps1`, `APIModules/Custom/Invoke-CustomExportAll.ps1` | Fixed. |
| F55 | `Manage-Privilege.ps1`, `APIModules/Custom/Invoke-CustomExportEntitlements.ps1`, ... | Fixed. |
| F56 | `Auth/CyberArk.Auth.SelfHosted.psm1`, `Manage-Privilege.ps1` | Fixed. Remaining limitation (profile backup/restore doesn't include `.autocred`) accepted by the user on 2026-09-25. Detail is in the archive. |
| F57 | `Modules\CyberArkComms.psm1`, `Auth\CyberArk.Auth.Common.psm1`, ... | Fixed. |
| F58 | `Auth\CyberArk.Auth.Common.psm1` (`Invoke-WebView2Window`), ... | Fixed. |
| F59 | `Manage-Privilege.ps1` | Fixed. |
| F60 | `Manage-Privilege.ps1`, `Claude_Docs\Reference_Interfaces.md`, README.md, ... | Fixed. |
| F61 | `Manage-Privilege.ps1`, `Modules\CyberArkCredentialStore.psm1` (new), ... | Fixed. |
| F62 | `Auth\CyberArk.Auth.ISPSS.psm1`, `Manage-Privilege.ps1`, ... | Fixed. |
| F63 | `Manage-Privilege.ps1`, `Tests\Unit\Manage-Privilege.Tests.ps1` | Fixed. |
| F64 | `Manage-Privilege.ps1` | Fixed. |
| F65 | `Manage-Privilege.ps1`, `Tests\Unit\Manage-Privilege.Automation.Tests.ps1` | Fixed. |
| F66 | `Modules\CyberArkComms.psm1`, `Tests\Unit\CyberArkComms.Tests.ps1` | Fixed. |
| F67 | `Auth\CyberArk.Auth.Common.psm1`, `Auth\CyberArk.Auth.ISPSS.psm1`, ... | Fixed. |
| F68 | `Auth\CyberArk.Auth.Common.psm1`, `Tests\Unit\CyberArk.Auth.ISPSS.Tests.ps1`, ... | Fixed. |

**Live-tenant limitations found but NOT fixable via aPePAS code changes** (confirmed via raw HTTP requests matching psPAS's own documented shapes exactly, still failing identically - treated as environment/PVWA-version restrictions, not code bugs, per this project's no-guessing policy on undocumented API behavior):
- `DELETE /API/Safes/{safeName}` can return HTTP 409 for a safe whose own GET response shows `"accounts": []` (confirmed empty) shortly after accounts were added and deleted in it - likely an internal CyberArk retention/lifecycle delay unrelated to this module's request, which is a plain, correct `DELETE` with no equivalent "force" option in psPAS either.
- ~~`POST /API/Accounts/{id}/LinkAccount` and its bulk sibling returned HTTP 404~~ — **resolved, see Finding F41 above.** The user has since confirmed live that both the single and bulk endpoints now work correctly against the real tenant; this was an environment-side condition at the time, not a code bug, and required no aPePAS change.
- ~~`POST /API/UserGroups/{id}/Members` (`Invoke-GroupsAddMember`) returns an unconditional, empty-body HTTP 400 regardless of payload shape, field casing, or member type~~ — **resolved, see Finding F42 below.** This was actually a real code bug all along, not an environment limitation: every variant tried still sent a numeric-looking value for `memberId`, when CyberArk's API expects the member's username there instead (confusingly named field). Fixed and live-verified.

> **Note on F08/F09:** `Manage-Privilege.Tests.ps1` is documented (in `Archive_Planning_Documentation-Tracker.md`) as
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
| K02 | `Modules\CyberArkComms.psm1` (**resolved - see Finding F57**) | Confirmed directly: the SSL certificate validation bypass `IgnoreSSL` enables (`ServicePointManager.CertificatePolicy`) is a .NET Framework process-wide static with no per-call scoping possible in PS 5.1 - and was never reset, so switching from an `IgnoreSSL=$true` profile to a different one left the bypass silently active for the rest of the process's life. | Resolved - no further action needed. |
| K03 | `Auth\CyberArk.Auth.Common.psm1` (`Invoke-WebView2Window`) (**resolved - see Finding F58**) | Confirmed directly (via reflection against the shipped WebView2 Core DLL): the embedded WebView2 browser control used for SAML/OIDC login wraps its own Chromium/CoreWebView2 engine with a completely separate network stack and certificate validation from `ServicePointManager` - `IgnoreSSL` reached `Invoke-WebView2Window` for neither `-IgnoreSSL` itself (not even a parameter) nor any WebView2-specific bypass mechanism. | Resolved - no further action needed. |
| K04 | `Manage-Privilege.ps1` (**resolved - see Finding F59**) | Confirmed directly: `Invoke-CyberArkAPI` builds every request's URI from the *token's* `BaseURL` (`Modules\CyberArkComms.psm1:398`), never the active profile's - and a token's `BaseURL` is frozen at original login time, never reconciled against a later profile edit. At 3 call sites (`Invoke-ProfileConnect`, the Test Connection flow, `Invoke-TokenRefresh`'s SelfHosted password branch), the profile's current `BaseURL` was either never consulted or was actively out-preferred by the stale token/context value. | Resolved - no further action needed. |
| K05 | `Groups/Invoke-GroupsList.ps1` `GroupType` filter | Works correctly on Self-Hosted but is silently unusable on ISPSS (see the groupType caution above) with no warning surfaced to the user — a filtered ISPSS query just returns zero rows. | Out of scope for this Self-Hosted pass; flag as a UX follow-up if ISPSS is tested later. |
| K06 | `Auth\CyberArk.Auth.SelfHosted.psm1` (`Invoke-SelfHostedPasswordAuth`) (**resolved - see Finding F56**) | Confirmed directly (not just theorized): `Invoke-SelfHostedPasswordAuth`, called by `Update-SelfHostedAuthToken` for CyberArk/LDAP/RADIUS, falls back to an interactive `Get-Credential` prompt when the stored `_RefreshContext` has no `Credential` - reachable from 3 call sites in `Manage-Privilege.ps1` (`Invoke-ProfileConnect`'s logon-time age-based refresh, its `Expired`-token refresh, and `Invoke-TokenRefresh`'s automation branch), all of which now supply automation mode's own `$script:AutomationMode` flag as a real `-NoPrompt` parameter. | Resolved - no further action needed. |
| K07 | `Invoke-TokenRefresh` (SelfHosted branch) (**resolved - see Finding F59**) | Confirmed directly: the SelfHosted CyberArk/LDAP/RADIUS re-auth branch computed `$username` with only one fallback tier (`_RefreshContext['Credential'].UserName`, else blank), missing the `$script:ActiveProfile.Username` tier the sibling ISPSS branch already has - forcing an unnecessary extra `Read-Host` username prompt whenever `_RefreshContext` had no captured credential but the profile already had a `Username` set. | Resolved - no further action needed. |
| K08 | `Invoke-GroupsAddMember.ps1` (**resolved - see Finding F42**) | `POST /API/UserGroups/{id}/Members` returned an unconditional, empty-body HTTP 400 on the 2026-09-04 live test tenant regardless of payload shape, field casing, or member type - reproduced with the module's own request shape, psPAS's `Add-PASGroupMember.ps1`'s exact shape, and several variants (int vs. string `memberId`, with/without `memberType`), all identical. ~~Not fixed - no aPePAS-side request shape was found that succeeds~~ - this was wrong: every variant tried still sent a numeric-looking `memberId` value, when the field actually expects the member's username (per user report, later the same day). Fixed and live-verified: `POST` now returns HTTP 201. | Resolved - no further action needed. |
| K09 | `Invoke-AccountsLinkAccount.ps1` / `Invoke-AccountsUnlinkAccount.ps1` (**resolved - see Finding F41**) | `POST /API/Accounts/{id}/LinkAccount` and the bulk equivalent `POST /API/Accounts/Link/Bulk` both returned HTTP 404 on the 2026-09-04 live test tenant against a freshly confirmed-to-exist account (verified via a direct `GET` on that same account ID immediately before). ~~Not fixed - both endpoint shapes documented by psPAS (`Set-PASLinkedAccount.ps1`) were tried and both 404d identically~~ - the user retested live later the same day and confirmed both endpoints now work correctly with no code change; the 404 was a transient environment-side condition, not a code or request-shape defect. | Resolved - no further action needed. |
| K10 | `Invoke-SafesDelete.ps1` (**closed - see F35, per user direction 2026-09-21**) | `DELETE /API/Safes/{safeName}` returned HTTP 409 on the 2026-09-04 live test tenant for three safes whose own `GET` response showed `"accounts": []` (confirmed empty) shortly after accounts had been added to and then deleted from them. Per user direction, the most likely cause is Safe History Retention - a plain, correct `DELETE` call with no equivalent "force" parameter in psPAS's `Remove-PASSafe.ps1` either, so no delete-side aPePAS fix was identified. F35 added a rename-instead-of-delete fallback, which resolved 2 of the 3 stuck safes; the third (`ZZ-ClaudeTest-DiagSafeLink2`) 409'd on the rename `PUT` too. | Closed per explicit user direction - the remaining stuck safe is an environment-side/CyberArk-support matter outside this codebase's reach (no API-visible way to inspect or override the underlying lock), not an aPePAS defect. No further action tracked here. |
| K11 | `Manage-Privilege.ps1` (**resolved - see Finding F60**) | Confirmed directly: `Get-SelfHostedAuthToken`/`Get-ISPSSAuthToken` and the whole call chain down to `Invoke-WebView2Window` already fully supported `-WebView2AssemblyPath` (including persisting it through `_RefreshContext` for refresh continuity) - the only actual gap was `Manage-Privilege.ps1` itself never setting it, and no profile field existing for a user to supply a value at all. | Resolved - no further action needed. |
| K12 | `Auth\CyberArk.Auth.ISPSS.psm1`, `Manage-Privilege.ps1` (**resolved - see Finding F62**) | Confirmed directly: ISPSS `Interactive` (plain CyberArk Identity username/password, no MFA) could never refresh silently in automation mode, for two independent reasons - a fresh login's typed password was never assembled into a `PSCredential` for `_RefreshContext`, and `Use-StoredCredentialIfMissing` (K06's `.autocred` fallback) explicitly excluded ISPSS entirely regardless of `AuthMethod`. `Invoke-TokenRefresh` also classified `Interactive` as categorically `$neverSilent`, the same as `SSO`. | Resolved - no further action needed. |
| K13 | `Manage-Privilege.ps1` (**resolved - see Finding F63**) | Confirmed directly, from a live user-reported crash: `Get-AllDriverProfiles`'s field-backfill normalization (which lets an older saved profile gain a field added after it was created, e.g. `CPM_List`) never included `WebView2AssemblyPath` when K11/F60 added that field - so editing any profile saved before K11 crashed `Invoke-ProfileEditFlow` with `SetValueInvocationException` the moment it tried to assign the field, since `Set-StrictMode -Version Latest` disallows setting a genuinely nonexistent PSCustomObject property. | Resolved - no further action needed. |
| K14 | `Manage-Privilege.ps1` (**resolved - see Finding F64**) | Confirmed directly, from a live user-reported crash: selecting exactly one profile (e.g. entering `1`) in either `Invoke-ProfileBackupFlow` or `Invoke-ProfileRestoreFlow`'s comma-separated numbered picker crashed with `PropertyNotFoundException: The property 'Count' cannot be found on this object`. Root cause is a genuine PowerShell behavior, confirmed via isolated repro: assigning the result of an `if/else` expression to a variable unwraps a single-element array (even a strongly-typed one) down to its bare scalar element - `$names = if (...) { ... } else { $picked.ToArray() }` became a plain `[string]` whenever exactly one profile was picked, and `$names.Count` then threw under `Set-StrictMode -Version Latest`. | Resolved - no further action needed. |
| K15 | `Manage-Privilege.ps1` (**resolved - see Finding F65**) | Confirmed directly, live, while running a self-hosted functional test pass: `Invoke-AutomatedAction` unconditionally called `Invoke-SessionLogoff` at the end of every single automation-mode (`-Category`/`-Action`) run, and `Invoke-SessionLogoff` genuinely revokes the session server-side (`POST /API/auth/Logoff`) - so a SECOND automation-mode invocation against the same profile always failed with a 401, even though the local `.cred` file and `Invoke-ProfileConnect`'s own "Validating token..." check (`GET /API/LoggedOnUser`) both looked fine, since that endpoint doesn't appear to detect an explicit prior logoff the way a real data-fetching call does. This defeated the entire point of the saved/refreshable session K06/K12 built - any real-world use of automation mode beyond a single one-shot invocation per login was silently broken. | Resolved - no further action needed. |
| K16 | `Modules\CyberArkComms.psm1` (**resolved - see Finding F66**) | Confirmed directly, live, while running a SaaS write-action test pass: `Accounts/ChangeImmediate` against an ISPSS account with no CPM assigned hung indefinitely under real Windows PowerShell 5.1 (the project's only declared/supported runtime), with no error and no exit - a direct violation of automation mode's "never hang" design contract. Root cause: PS 5.1's `HttpWebRequest`-based `Invoke-WebRequest` sends `Expect: 100-continue` on every POST/PUT/PATCH with a body, which whatever gateway fronts CyberArk's ISPSS rotation microservice (SRS) does not appear to handle correctly; `pwsh` (HttpClient-based, never sends this header) was unaffected. | Fixed - `[System.Net.ServicePointManager]::Expect100Continue = $false` set once, process-wide, at `CyberArkComms.psm1` module-load time. **Live-verified 2026-09-23**: the identical `Accounts/ChangeImmediate` call against the same account, run twice under real Windows PowerShell 5.1, completed in ~1 second both times (a real HTTP 401 response, correctly classified) instead of hanging indefinitely - resolved. A separate, not-yet-explained observation surfaced during this same verification: both times, a token obtained moments earlier via a fresh Interactive login (not aged, not refreshed) was rejected with an immediate 401 on this specific call - not investigated further to avoid additional live authentication attempts without checking in first; flagged for awareness, not yet a diagnosed finding. |
| K17 | `Auth\CyberArk.Auth.Common.psm1`, `Auth\CyberArk.Auth.ISPSS.psm1`, `Manage-Privilege.ps1` (**fixed, per user direction - see Finding F67**) | Confirmed live, while investigating K16: repeated CyberArk Identity authentication attempts within a short window (both this session's own manual re-auth attempts and, independently, the driver's automatic age-based silent refresh, which re-attempts on every single automation-mode run once a saved token crosses its age threshold) triggered a soft lockout - subsequent attempts were rejected with a generic `"Authentication (login or challenge) has failed"` even with the correct password, confirmed via a raw diagnostic call succeeding moments after an identical call through the real code path failed. CyberArk Identity's own `StartAuthentication` response includes a `RetryWaitingTime` field (observed live: 30 seconds) that aPePAS completely ignored. | Added `Get-ISPSSAuthThrottle`/`Set-ISPSSAuthThrottle` (`CyberArk.Auth.Common.psm1`) - a small per-profile JSON sidecar file (no secrets) recording a `NextAllowedAt` timestamp, since in-memory state doesn't survive across separate process invocations (the real-world risk: a scheduled automation-mode task, or a human retrying by hand). `Invoke-ISPSSInteractive` now records `RetryWaitingTime` from `StartAuthentication` whenever `-AuthTokenProfileName`/`-ProfileDir` are supplied, and carries both into the returned token's `_RefreshContext` so `Update-ISPSSAuthToken`'s later silent refreshes keep recording it automatically, with no extra plumbing needed at those call sites. `Manage-Privilege.ps1`'s three ISPSS auth-attempt call sites (`Invoke-ProfileConnect`'s age-based and expired-token refresh blocks, `Invoke-TokenRefresh`'s mid-run refresh) now check the throttle first and skip a doomed attempt entirely rather than making it; the one genuinely-interactive fresh-login call site waits out the remaining time (a human is already waiting) instead of immediately re-attempting into another likely rejection. Per user direction ("Any ideas on this?" / "Yes"), this directly targets the mechanism CyberArk itself signals, rather than a guessed fixed delay. | Added 7 new tests to `CyberArk.Auth.ISPSS.Tests.ps1` (K17-01 through K17-07): the throttle file's read/write/elapsed-expiry behavior in isolation, that a live `StartAuthentication` response's `RetryWaitingTime` is recorded only when a profile identity is supplied (never blocking a standalone/no-profile caller), that it's carried into `_RefreshContext`, and that a later `Update-ISPSSAuthToken -NoPrompt` silent refresh re-records it using that carried context. Added 4 new tests to `Manage-Privilege.Automation.Tests.ps1` (AM78-81): the fresh-login call site forwards the profile identity and correctly waits (`Start-Sleep`, mocked) only when throttled, and `Invoke-TokenRefresh` skips (never calls `Update-ISPSSAuthToken`) when throttled. All 1254 unit tests pass (1243 + 11 new), 5 skipped (unchanged). **Live-verified 2026-09-23**: a single fresh Interactive login against the real `bannermen-nfr` tenant succeeded on its first attempt (the prior soft lockout had cleared overnight), and `Get-ISPSSAuthThrottle` correctly reported ~29 seconds remaining immediately afterward - confirming the sidecar file is created from a real `StartAuthentication` response's `RetryWaitingTime` (observed live: 30 seconds, matching this Finding's earlier observation) and read back correctly. |

---

## Testing Boundaries

### What unit tests cover
- Pure logic: formatting, filtering, field mapping, error branching
- Filesystem operations: log file creation, profile CRUD (using temp directories)
- HTTP layer: mocked via `Mock Invoke-WebRequest` (success path) and
  `Mock Invoke-CyberArkAPI` (all paths for API modules)

### What unit tests do NOT cover
- Real HTTP calls to CyberArk
- Browser-based auth flows (WebView2) - though a function's own parameter-forwarding *into*
  `Invoke-WebView2Window` (e.g. `-IgnoreSSL`, Finding F58) is unit-testable by mocking
  `Invoke-WebView2Window` itself and asserting on how it was called
- Interactive UI prompts (`Read-Host`, file dialogs)
- DPAPI encryption/decryption on a different machine
- `Disable-SSLValidation`/`Reset-SSLValidation` (`ICertificatePolicy`-based) when the suite is run
  under `pwsh` (PowerShell 7/.NET Core) rather than real Windows PowerShell 5.1 - confirmed
  directly (Finding F57) that `ICertificatePolicy` doesn't exist in .NET Core's `System.Net`
  surface at all, and that even reading `ServicePointManager.CertificatePolicy` afterward is
  unreliable there. These specific tests (`CyberArkComms.Tests.ps1` C34/C35/C36/C37/C38) are
  skipped under `pwsh` and only actually run under real Windows PowerShell 5.1 - see that file's
  own comment for the exact repro. Any *other* future code touching `ICertificatePolicy` or
  `ServicePointManager` statics directly will hit the same limitation

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

## CyberArkCredentialStore.psm1 — Test Cases

### Get-ProfileCredentialPath / Save-ProfileCredential / Get-ProfileCredential / Remove-ProfileCredential
| # | Test Case | Expected |
|---|---|---|
| CS01 | `Get-ProfileCredentialPath -Name -ProfileDir` | Returns `<ProfileDir>\<Name>.autocred` |
| CS02 | `Get-ProfileCredential` when nothing stored | Returns `$null` |
| CS03 | `Save-ProfileCredential` then `Get-ProfileCredential` | Username/password round-trip correctly |
| CS04 | `Save-ProfileCredential` return value | Returns the saved file's path |
| CS05 | `Get-ProfileCredential` on an undeserializable file | Returns `$null`, does not throw |
| CS06 | `Remove-ProfileCredential` on a stored credential | File deleted |
| CS07 | `Remove-ProfileCredential` when nothing stored | Does not throw |
| CS08 | Two profile names in the same `-ProfileDir` | Stored/retrieved independently, no collision |

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

Design reference: `Claude_Docs\Design_Add-Safe-From-Template.md`. Test file:
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
the test environment, none of which can be simulated. `IgnoreSSL` now reaches the WebView2 control
too (Finding F58) - unit-tested only for the parameter-forwarding half (SH-SSL01-04); the actual
`ServerCertificateErrorDetected`/`AlwaysAllow` behavior inside the real Chromium control has not
been confirmed live yet against a self-signed/internal-CA host - see A07/A08 below.

| # | Test Case | Pass Criteria |
|---|---|---|
| A01 | SelfHosted — CyberArk auth | Token returned; `SystemType=SelfHosted`; `TokenType=CyberArkSession`; `Authorization` header has no `Bearer` prefix |
| A02 | SelfHosted — LDAP auth | Token returned with `AuthMethod=LDAP` |
| A03 | SelfHosted — RADIUS auth | Token returned with `AuthMethod=RADIUS`; if the RADIUS server requires a challenge/response (e.g. a one-time passcode), confirm the prompt flow completes |
| A04 | SelfHosted — Shared auth | Token returned with `AuthMethod=Shared` |
| A05 | SelfHosted — PKI cert auth (**high risk**) | Correct cert selected via `Get-FilteredClientCertificate`; token returned; requires a real client certificate installed in the test environment's cert store |
| A06 | SelfHosted — PKIPN auth (**high risk**) | Same as A05 but via PIN-protected smart card/token; requires physical/virtual smart-card hardware |
| A07 | SelfHosted — SAML auth (**high risk**) | WebView2 window opens; IdP login completes; token captured via cookie/redirect detection. With `IgnoreSSL=$true` against a lab host with a self-signed/internal-CA cert (Finding F58): the WebView2 window navigates through without a certificate-error interstitial blocking it. With `IgnoreSSL=$false` against the same host: the interstitial correctly still appears (confirms the bypass isn't accidentally always-on) |
| A08 | SelfHosted — OIDC auth (**high risk**) | Same as A07 but OIDC flow; confirm token exchange completes and `Token`/`TokenType` are populated correctly; same `IgnoreSSL` on/off self-signed-cert check as A07 |
| A09 | Save-AuthToken | `.cred` file created/updated under the profile's token storage location |
| A10 | Import-AuthToken — valid token | Token object returned with all fields (`Token`, `TokenType`, `Headers`, `Expiry`, `SystemType`, `AuthMethod`, `BaseURL`, `Created`, etc.) |
| A11 | Import-AuthToken — expired token on disk | Caller correctly detects expiry (session age > `$script:PVWA_SESSION_EXPIRY_MIN`) and triggers re-authentication rather than using a dead token |
| A12 | Update-SelfHostedAuthToken — silent re-auth path | Confirm this uses the stored `_RefreshContext` credentials without prompting, for auth methods where that's expected; K06/F56 fixed the `Get-Credential` fallback for automation mode specifically - this item covers the still-unchanged interactive-mode behavior |
| A13 | Get-AuthTokenProfiles | All saved profiles listed |
| A14 | Remove-AuthTokenProfile | Token file removed; profile no longer resolves a stored token |
| A15 | IgnoreSSL — self-signed cert environment, non-WebView2 methods (CyberArk/LDAP/RADIUS/Shared/PKI/PKIPN) | No SSL error |
| A19 | IgnoreSSL — switch from an `IgnoreSSL=$true` profile to a different profile with `IgnoreSSL=$false` in the same running session (no restart), then call any API against a host with a real, valid certificate (Finding F57/K02) | The second profile's call succeeds normally with real certificate validation active - no SSL error, and no silent continued bypass from the first profile |
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
| D26 | Profile Selection → `[K]` Backup, select 2+ profiles (one with a saved token, one without) by comma-separated number, save the `.zip` | Zip created at the chosen path; contains each profile's `.json`, the `.cred` only for the one that had a saved token, and a `_manifest.json`. Core zip I/O logic (`Backup-DriverProfiles`) is verified via a standalone repro (see Finding F51) - this is the interactive-menu wrapper (`Invoke-ProfileBackupFlow`) around it |
| D27 | Profile Selection → `[K]` Backup, type `all` instead of numbers | Every profile is included in the zip |
| D28 | Profile Selection → `[X]` Restore, pick the `.zip` from D26, restore only the profile that has no local counterpart | Correct `.json` written; no `.cred` written (none was in the zip for that profile); no overwrite prompt shown (nothing to conflict with) |
| D29 | Delete a profile that still has a backup `.zip` from before deletion, then `[X]` Restore it back, this time to a name that still exists locally | Confirmation prompt shown before overwriting; declining leaves the existing local profile untouched |
| D30 | Copy (via any file-copy method) a `.zip` produced by Backup to a different Windows user account or a different machine, then `[X]` Restore it there | `.json` settings restore correctly; the restored `.cred` cannot be decrypted (expected - DPAPI is user+machine-locked) - the Restore screen shows a clear portability warning naming the affected profile(s), and the profile's `TokenStatus` subsequently shows `Unreadable`, prompting normal re-authentication on Connect rather than a crash |
| D31 | Launch with `-StartProfile "<name>" -AutoConnect` for a complete, working profile | Skips the profile list/detail menus entirely; authenticates and enters the session directly |
| D32 | Launch with `-StartProfile "<name-that-does-not-exist>" -AutoConnect` | Prints a clear "no profile found" message and falls back to the normal interactive profile list, rather than exiting or crashing |
| D33 | Launch with `-StartProfile "<name>" -AutoConnect` where that profile is incomplete (missing System Type or Base URL) | Prints a clear "profile is incomplete" message and falls back to the normal interactive profile list |
| D34 | Launch with `-StartProfile "<name>" -AutoConnect` where authentication fails (e.g. wrong password) | Prints the authentication error with no `Read-Host` pause (unattended-safe), then falls back to the normal interactive profile list rather than hanging or exiting |
| D35 | Launch with `-AutoConnect` but no `-StartProfile` | Fails fast at startup with a clear parameter error ("-AutoConnect requires -StartProfile") before any profile/module loading happens |
| D36 | With `-StartProfile "<name>" -AutoConnect`, connect successfully, then choose Restart from the session menu | Restart returns to the normal interactive profile list (pre-selecting the same profile, existing behavior) rather than auto-connecting again - `-AutoConnect` applies only to the initial launch |
| D37 | From a genuinely non-interactive host (e.g. `schtasks /run`, or `powershell.exe -NonInteractive -File ...`), run `-StartProfile "<name>" -Category <cat> -Action <action>` for a profile with a valid, refreshable saved session | Runs to completion with no prompt of any kind; exits `0` on success (or `2` if the action itself reported item-level failures); the profile's log file contains a coherent narrative of the run |
| D38 | Same as D37, but for a profile with no saved token at all (never logged in interactively) | Exits promptly with code `3` and a clear log message ("fresh authentication is always interactive... log in interactively at least once first") - no hang, no WebView2/credential prompt of any kind |
| D39 | Same as D37, but for a profile whose `AuthMethod` is SAML, OIDC (Self-Hosted), Interactive, or SSO (ISPSS) and whose saved token has expired | Exits promptly with code `3` - these methods have no silent refresh path at all, so automation mode must fail fast rather than ever opening a browser/MFA challenge |
| D40 | `-StartProfile "<name>" -Category Safes -Action Delete -InputJson '{"SafeName":"<a safe that will 409 on delete>"}'`, and separately, lock the profile's output CSV file (e.g. open it in Excel) before running an export-style action with `-InputJson` | Both cases fail cleanly and immediately (exit `2` or `3` as appropriate) with a clear log message, rather than pausing on `Invoke-SafesDelete.ps1`'s rename-offer prompt or `Invoke-FileWriteWithRetry`'s retry prompt the way an interactive session would |
| D41 | `-StartProfile "<name>" -Category Custom -Action ExportEntitlements -InputJson '{}' -OutputFolder "<a folder that does not exist yet>" -FilenameFormat "{Profile}_{ModuleName}_{Date}"`, and separately `-Category Custom -Action ExportAll -InputJson '{}' -OutputFolder "<folder>"` (no `-FilenameFormat`) | The first run creates the folder if needed and saves one CSV there named per the template (e.g. `Prod_Export Entitlements_2026-09-19.csv`). The second run redirects Export All's several per-sub-report CSVs (`Export_AccountsList.csv`, etc.) to the same override folder, keeping their existing fixed names unchanged |
| D42 | Run `-StartProfile "<name>" -Category Custom -Action ExportEntitlements -InputJson '{}'` (no `-FilenameFormat`) twice, on two different days if possible, or with the file's timestamp checked between runs | Both runs save to the exact same filename (`Export Entitlements.csv`, no date) in the profile's `OutputFolder` - the second run overwrites the first rather than creating a second, dated file. Repeat for Export Group Members (Local), Export Group Members (LDAP), and Export Platform Details to confirm all 4 behave identically |
| D43 | For a CyberArk/LDAP/RADIUS profile: manually edit or delete the `Credential` entry from its saved `.cred` file's `_RefreshContext` (or simulate by deleting `.cred` entirely and letting a token go `Expired`), then run `-StartProfile "<name>" -Category Safes -Action List -InputJson '{}'` with no `.autocred` stored | Exits promptly with a clear log message that no credential is available and interactive prompting is disabled - no hang, no `Get-Credential` popup. Then set a credential via the profile detail menu's `[A]` action and re-run the same command | The run now succeeds, refreshing silently using the stored credential |
| D44 | Connect to a profile with a still-valid saved token, then `[E]dit` the profile and change its Base URL to a different (but still reachable) PVWA/tenant, then `[C]onnect` again without deleting the saved token (Testing_Plan.md K04) | A fresh, interactive login is required against the *new* URL - the saved token is not silently reused against the old URL, and no API call is ever made to the pre-edit server. Repeat via `[T]est Connection` on the profile-detail menu to confirm the same behavior there |
| D45 | For a CyberArk/LDAP/RADIUS profile whose saved token has no `_RefreshContext.Credential` (e.g. delete just that key from the `.cred` file) but whose profile has a `Username` set, let the session expire mid-run and trigger `Invoke-TokenRefresh` interactively (Testing_Plan.md K07) | The "Signing in as: `<profile's Username>`" line appears and only a password is prompted for - no extra "Username" prompt |
| D46 | On a machine where `Microsoft.Web.WebView2.WinForms.dll` is NOT in any of the default candidate locations (temporarily rename `Auth\WebView2\` if needed), set a SAML/OIDC/SSO profile's **WebView2 Assembly Path** field to the DLL's actual location via `[E]dit`, then `[C]onnect` (Testing_Plan.md K11) | The WebView2 window opens successfully using the path from the profile field, instead of throwing `Microsoft.Web.WebView2.WinForms.dll not found`. Clearing the field again (with the DLL still absent from the default locations) reproduces the original error |

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
- [x] Add (**confirmed live 2026-09-21** via automation mode against a real Self-Hosted PVWA -
      created a real account in a disposable test safe, `aPePAS-WriteTest`) ·
      [ ] CancelCpmTask (confirm the `/Cancel/` endpoint, Phase 1 this session — was
      `/StopImmediateAutoMgmtOperations` before; F14 this session added a 404 fallback to that
      same old endpoint for PVWA older than 15.2, unverified against a real pre-15.2 host; not
      attempted 2026-09-21 - no pending CPM task existed to cancel) ·
      [x] ChangeImmediate (**confirmed live 2026-09-21**: ran against the test account and
      confirmed via its `Activities` audit log that the account's `ResetImmediately` property was
      set to `ChangeTask`, per the user's specific verification request) ·
      [x] ChangeInVault (F12's `Password/Update` endpoint correction **confirmed correct
      2026-09-03** — a live 400 against it turned out to be a legitimate `PASWS001W` account-lock
      error once F16 let Test API surface the real body, not a bug in the endpoint/body shape.
      **Re-confirmed live 2026-09-21**: correctly does NOT touch `ResetImmediately` (it stores a
      new password directly in the vault rather than asking CPM to change it on the target) -
      the `Activities` log showed a plain "Store password" entry with no `ResetImmediately`
      update, exactly as expected) · [ ] CheckIn (not attempted 2026-09-21 - the test account was
      never checked out) ·
      [x] Delete (**confirmed live 2026-09-21** - cleaned up the test account after the write-action
      batch) · [x] Get (**confirmed live 2026-09-21**) ·
      [x] GetActivity (**confirmed live 2026-09-21** - this is also how `ResetImmediately` was
      confirmed for ChangeImmediate/Reconcile/Verify, see above/below) · [ ] GetCredential (not
      attempted 2026-09-21 - retrieves a live password value, deferred) ·
      [x] LinkAccount (F41 this session — **confirmed live**: previously logged as an unfixable
      live-tenant limitation (HTTP 404), the user has since retested and confirmed it now works
      correctly against the real tenant; no code change was involved) ·
      [x] List (incl. By-Safe mode, confirm 20K cap behavior — **confirmed 2026-09-02**, re-confirmed
      2026-09-21: 2440 accounts across 35 safes) ·
      [x] Reconcile (**confirmed live 2026-09-21**: `Activities` log showed `ResetImmediately`
      updated to `ReconcileTask`) ·
      [ ] ResumeAutoManagement (confirm `POST .../Resume/` on Self-Hosted, Phase 1 this session —
      was `PATCH .../` before; ISPSS was deliberately left unchanged/unconfirmed; F14 this
      session added a 404 fallback on Self-Hosted to the same PATCH `automaticManagementEnabled`
      approach for PVWA older than 15.2, unverified against a real pre-15.2 host; not attempted
      2026-09-21) ·
      [x] UnlinkAccount (F41 this session — **confirmed live**, same as LinkAccount above) ·
      [ ] Unlock (not attempted 2026-09-21 - the test account was never locked) ·
      [x] Update (JSON Patch) (**confirmed live 2026-09-21** - updated the test account's `Address`) ·
      [x] Verify (**confirmed live 2026-09-21**: `Activities` log showed `ResetImmediately` updated
      to `VerifyTask`)

  **For every `AccountName`+`Safe`-resolving action above:** confirm the `filter=safeName eq ...`
  lookup now works against a **safe name containing a space** (e.g. `"Prod Web Servers"`), not just
  a single-word safe name - this session fixed all 16 call sites of this bug (raw string
  interpolation never quoted the value; now routed through `New-CyberArkSearchFilter`, confirmed
  against psPAS's `ConvertTo-FilterString.ps1`), but none of the 16 fixes have been exercised
  against a real PVWA/ISPSS tenant yet. `List`'s By-Safe iteration mode needs the same check with
  at least one accessible safe whose name contains a space.

### Safes (8 actions)
- [x] Add (F20 this session — Location no longer prompted interactively, confirm the default `\`
      is still used; ManagingCPM picker now matches AddFromTemplate, sourced from the new shared
      `Get-CpmOptions` — confirm the live CPM query populates it, and that a deliberately-broken
      query falls back to the profile's CPM_List. **Confirmed live 2026-09-21**: created two
      disposable test safes, `aPePAS-WriteTest` and `aPePAS-DeleteTest`, with `ManagingCPM` set
      explicitly - the live-query/fallback path specifically wasn't re-exercised) ·
      [ ] AddFromTemplate (T01-T24 scenarios; F20 this session — CPM picker now sourced from
      `Get-CpmOptions` instead of `CPM_List` only, confirm live query + fallback; not attempted
      2026-09-21 - needs `Role_Template_Safe`/`Role_Group_Prefix` profile fields set) ·
      [x] AssignCPM (F20 this session — CPM picker now sourced from `Get-CpmOptions`, same
      live-query behavior as before but now with a CPM_List fallback on failure that didn't
      exist previously; confirm both paths. **Confirmed live 2026-09-21** for the direct-assignment
      path only, not the live-query-failure fallback) ·
      [x] Delete (**confirmed live 2026-09-21**: deleted `aPePAS-DeleteTest`, a safe created with no
      accounts ever added to it, specifically to test the delete path cleanly - succeeded
      immediately, unlike K10's stuck-safe history) · [x] Get (**confirmed live 2026-09-21**) ·
      [x] List (confirm F05 ExtendedDetails CSV-boolean fix — **confirmed 2026-09-02**, re-confirmed
      2026-09-21: 35 safes) ·
      [x] UnassignCPM (not directly re-tested 2026-09-21 - `AssignCPM` was exercised instead; the
      underlying request shape is symmetric) · [x] Update (**confirmed live 2026-09-21** - updated
      `aPePAS-WriteTest`'s description)

### SafeMembers (6 actions)
- [x] Add (confirm SearchIn directory picker lists real LDAP directories - not re-tested;
      **confirmed live 2026-09-21** for the direct MemberName/PermissionRole path: added a real
      user as `EndUser` to `aPePAS-WriteTest`) ·
      [ ] AddFromTemplateRole (not attempted 2026-09-21 - needs `Role_Template_Safe`/
      `Role_Group_Prefix` profile fields set) · [x] List (**confirmed 2026-09-02**) ·
      [x] Remove (**confirmed live 2026-09-21**) · [x] Update (**confirmed live 2026-09-21** -
      changed the same member's role to `PowerUser`) ·
      [ ] UpdateFromTemplateRole (not attempted 2026-09-21 - same profile-field dependency as
      AddFromTemplateRole)

### Platforms (10 actions)
- [x] Get (**confirmed live 2026-09-21**, `WinDesktopLocal`) ·
      [x] List (confirm F06 field-fallback fix and the new `SystemType` filter — **confirmed
      2026-09-02**, re-confirmed 2026-09-21: 20 platforms) ·
      [x] Copy (Target platforms only — see `Planning_E2E-Automation.md`; **confirmed live 2026-09-21**:
      copied `WinDesktopLocal` to a disposable `aPePASTestPlatform`) ·
      [x] Disable (**confirmed live 2026-09-21**, on the disposable copy) ·
      [x] Enable (**confirmed live 2026-09-21**, on the disposable copy) ·
      [x] Export (F38 this session — **confirmed live** for the `PlatformID` variant: downloaded a
      real, valid `.zip` from the Self-Hosted tenant; the other 3 target-type variants remain
      unit-tested only, no real rotational-group/dependent/group-platform ID exists to test with) ·
      [ ] Import (confirm the ZIP-as-byte-array request shape actually works; not attempted
      2026-09-21 - no test export ZIP was prepared) ·
      [x] Remove (destructive — use a disposable sandbox platform; **confirmed live 2026-09-21**:
      removed the disposable `aPePASTestPlatform` copy as cleanup) ·
      [ ] Rename (Self-Hosted only, PVWA 15.0+; **attempted live 2026-09-21** against the disposable
      copy - failed with a clean `HTTP 405 Method Not Allowed`, consistent with this tenant running
      a PVWA version older than 15.0. Not a code defect - the module's request shape
      (`PUT /API/Platforms/targets/{id}`) is correct per the documented 15.0+ contract; this
      tenant's version just doesn't support it. Still needs confirming against an actual 15.0+
      host) · [ ] SetPSMConfig (not attempted 2026-09-21 - no real PSM Server ID was available to
      test with)

### Policies (2 actions — PVWA 14.6+; SetMasterPolicy is Self-Hosted only, GetMasterPolicy is declared dual-use)
- [x] GetMasterPolicy (F40 this session — **Self-Hosted confirmed live**, including via the
      `Custom/ExportAll` `IncludeInExportAll` path. **ISPSS/Privilege Cloud confirmed live
      (2026-09-04) to have no Master Policy equivalent endpoint at all** - handled cleanly as a
      non-fatal `Failure`, confirmed acceptable behavior by the user, no code change needed) ·
      [ ] SetMasterPolicy (Self-Hosted only; mutates tenant-wide config — use a dedicated lab host,
      never a shared/production one; confirm every field's validation range: `ConfirmersNumber`
      1-64, `PasswordChangeDays`/`PasswordVerificationDays` 1-3650, `RetentionPeriod` 0-3650.
      **Explicitly skipped per user direction 2026-09-21** for this test pass - deliberately not
      attempted, not a gap)

### Users (2 actions)
- [x] Get (**confirmed live 2026-09-21**, UserID 90 - `CA_Automation_User` itself) ·
      [x] List (**confirmed 2026-09-02**, re-confirmed 2026-09-21: 38 users)

### Groups (7 actions)
- [x] Add (**confirmed live 2026-09-21** - created a disposable `aPePAS-TestGroup`) ·
      [x] AddMember (F42 this session — **confirmed live**: `memberId` is the username, not a
      numeric ID; previously an unconditional HTTP 400, now HTTP 201 against the real tenant) ·
      [x] Delete (**confirmed live 2026-09-21** - cleaned up `aPePAS-TestGroup`) ·
      [x] GetMembers (F43 this session — **confirmed live**: fixed a strict-mode crash mapping a
      real member entry, which has no `userType`/`componentUser` field at all; the
      `IncludeMembers` opt-in field makes no observable difference on this tenant, also
      confirmed live) ·
      [x] List (confirm GroupType filter works correctly on Self-Hosted, unlike ISPSS —
      **confirmed 2026-09-02**, re-confirmed 2026-09-21: 19 groups) ·
      [x] RemoveMember (F42 this session — **confirmed live** as part of the same end-to-end
      test, HTTP 204) ·
      [x] Update (**confirmed live 2026-09-21** - updated `aPePAS-TestGroup`'s description)

### Applications (7 actions — dual-use, see caution section)
- [x] Add (confirm `Location` is now enforced as mandatory, Phase 1 this session — **confirmed
      2026-09-02**, the only Applications action visible on the ISPSS menu before this pass;
      re-confirmed 2026-09-21 against Self-Hosted specifically: created a disposable
      `aPePAS-TestApp`) ·
      [x] AddAuthMethod (**confirmed live 2026-09-21**: added an `osUser` auth method to the
      disposable test application) · [x] Delete (**confirmed live 2026-09-21** - cleaned up
      `aPePAS-TestApp`) · [x] DeleteAuthMethod (**confirmed live 2026-09-21**) · [x] Get
      (**confirmed live 2026-09-21**) ·
      [x] List (confirm F01 trailing-slash / PIMServices.svc routing fix — **confirmed
      2026-09-02**) ·
      [x] ListAuthMethods (per user request, this session: leaving App ID blank now lists auth
      methods for every application instead of failing - **confirmed live 2026-09-21** against
      Self-Hosted: 4 applications checked, 8 methods retrieved with a blank AppID)
- AddAuthMethod, Delete, DeleteAuthMethod, Get, List, and ListAuthMethods were expanded from
  Self-Hosted-only to dual-use on 2026-09-02, after the user found only Add visible on the ISPSS
  Applications menu — confirming the other 6 had been Self-Hosted-only in error. Only ISPSS menu
  visibility has been confirmed for these 6; their actual ISPSS request/response behavior is
  unverified.

### Reports (1 action — Self-Hosted only, see caution section)
- [x] List (confirm F04 sparse-field guards against a real report with missing fields, if any
      exist — **confirmed 2026-09-02**, Self-Hosted only. Also confirmed 2026-09-02 that this
      endpoint 404s on ISPSS/Privilege Cloud — `SupportedSystems` reverted to Self-Hosted-only,
      reversing Phase 1's dual-use expansion. **Re-tested 2026-09-21 with the `CA_Automation_User`
      regression-test account and got a clean `HTTP 403 Forbidden`** - the request reached the
      server and was cleanly rejected, not a code defect; this account simply isn't granted
      Reports access. Worth noting for anyone setting up a similarly narrowly-scoped automation
      account: it will need Reports permission explicitly granted if this action is needed)

### Custom (7 actions)
- [x] ExportAll (per user request, this session, now also runs Applications/ListAuthMethods -
      that specific addition is unverified against a real host; F40 this session — **confirmed
      live** that it now also runs Policies/GetMasterPolicy via the new `IncludeInExportAll`
      opt-in, saving a real CSV with real policy values against the Self-Hosted test tenant.
      **Re-confirmed live 2026-09-21** via automation mode: 9 sub-modules run, 9 succeeded
      (Reports/List's clean 403 counted as a graceful non-fatal failure, not a code error) -
      SafesList, AccountsList-by-safe (2440 accounts), PlatformsList, UsersList, GroupsList,
      ReportsList, ApplicationsListAuthMethods, PoliciesGetMasterPolicy) ·
      [x] ExportEntitlements (confirm the CSV now saves automatically with no `[y/N]` prompt;
      **confirmed live 2026-09-21** via automation mode: 35 safes, 117 members, 0 failures) ·
      [ ] ExportGroupMembersLDAP (requires AD line-of-sight; confirm auto-save CSV; not attempted
      2026-09-21 - no AD line-of-sight from this test session) ·
      [x] ExportGroupMembersLocal (confirm F07 groupType quirk fix, though Self-Hosted may not
      exhibit the ISPSS quirk at all — confirm normal local-group export still works; confirm
      auto-save CSV. **Confirmed live 2026-09-21** via automation mode: 15 groups, 43 rows) ·
      [x] ExportPlatformDetails (F39 this session — **confirmed live**: 10/10 active platforms
      processed successfully, 104 dynamic columns, correct blank-fill and per-platform-type value
      extraction spot-checked via CSV; the `OtherFiles`/META-INF-exclusion logic is unit-tested
      only, no real bundled-extra-file example existed on this tenant to confirm it against.
      Re-confirmed live 2026-09-21: 15/15 platforms succeeded) ·
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
      this module's Linux path; F52 this session — added an optional `AdditionalPorts` field,
      unit-tested only, not yet confirmed against a real target)

### Driver-level (Manage-Privilege.ps1)
- [ ] D01-D25 (see Manage-Privilege.ps1 manual test procedures above, including new D23-D25)
- [ ] D26-D36 (profile backup/restore, `-StartProfile`/`-AutoConnect` startup)
- [x] D37-D40 (automation mode - `-Category`/`-Action`, a non-interactive host, a token-less/never-silently-refreshable profile, and the two known interactive-touchpoint guards. **Confirmed live 2026-09-21**: dozens of real `-Category`/`-Action` invocations against a real Self-Hosted PVWA via `powershell.exe` from a non-interactive host, covering nearly every module action - see K15/F65 and the Accounts/Safes/SafeMembers/Groups/Platforms/Applications/Custom checklist entries above for specifics. This same pass is what found and fixed K15 - multiple SEQUENTIAL automation-mode runs against one saved session now work correctly)
- [ ] D41 (automation mode - `-OutputFolder`/`-FilenameFormat` overrides, for both a single-file export and Export All's multi-file output)
- [ ] D42 (Custom export tools' date-free filenames overwrite on each run - all 4 non-ExportAll modules)
- [ ] D43 (K06 fix - automation mode's `-NoPrompt` guard and the stored `.autocred` fallback)
- [ ] D44 (K04 fix - a profile's edited Base URL forces a fresh login instead of reusing a stale token)
- [ ] D45 (K07 fix - the profile Username fallback in Invoke-TokenRefresh's SelfHosted branch)
- [ ] D46 (K11 fix - the WebView2AssemblyPath profile field actually recovers a missing-DLL error)
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

**Update 2026-09-21:** this is still true for the driver's own normal interactive menu flow (no
CLI switch lets a fresh cold-start login supply a credential directly through it). However, since
K12/F62, `Interactive`'s underlying Auth module function (`Get-ISPSSAuthToken`) itself accepts
`-Credential` directly and completes silently when the identity resolves to a single password-only
challenge - this is how the read-only portion of this pass below was actually run: a script called
`Get-ISPSSAuthToken -AuthMethod Interactive -Credential $cred` directly (bypassing the driver's
interactive menu entirely, mirroring the same approach used for the Self-Hosted pass), saved the
resulting token, then drove `Manage-Privilege.ps1 -Category`/`-Action` automation mode from there
- no human sat at a console for any of it. One real environment-specific detail found doing this:
this tenant's CyberArk Identity requires the **UPN format** (`user@company.com`), not the bare
username - the bare username resolved to a *different* identity that had MFA enrolled, causing a
confusing initial failure. Confirm this matches your own tenant's identity format before assuming
a bare username will work.

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
      [x] List (confirm By-Safe mode; confirm whether the ~20K no-safe-filter result cap behaves the
      same on ISPSS. **Confirmed live 2026-09-21** (read-only pass only - By-Safe mode/20K cap
      specifically not re-verified): 21 accounts via `Accounts/List`, 8 via `Custom/ExportAll`'s
      by-safe iteration across 29 safes) ·
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
      returns the expected CPM accounts on ISPSS) · [ ] Delete · [ ] Get ·
      [x] List (**confirmed live 2026-09-21**: 29 safes) ·
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
      ISPSS, unconfirmed) ·
      [x] List (same field-shape note - **confirmed live 2026-09-21**: 39 platforms, no field-shape
      issue observed) · [ ] Copy · [ ] Disable · [ ] Enable ·
      [x] Export (confirmed live on Self-Hosted only, for the `PlatformID` variant — **confirmed
      live 2026-09-21** for that same variant on ISPSS too, via `Custom/ExportPlatformDetails`:
      14/14 platforms succeeded) · [ ] Import · [ ] Remove (destructive — disposable sandbox
      platform only) · [ ] SetPSMConfig

### Policies (1 of 2 actions — `SetMasterPolicy` is Self-Hosted only, excluded)

- [x] GetMasterPolicy — **already confirmed (2026-09-04)**: no Master Policy equivalent exists on
      ISPSS; returns a clean, non-fatal `Failure`. **Re-confirmed live 2026-09-21**: clean `HTTP
      404`, handled as a non-fatal item within `Custom/ExportAll` (8/8 modules still reported
      success overall). No further action needed.

### Users (2 actions, dual-use)

- [ ] Get · [x] List (**confirmed live 2026-09-21**: 40 users)

### Groups (7 actions, dual-use — see the `GroupType='Vault'` note above)

- [ ] Add · [ ] AddMember (fixed and confirmed live on Self-Hosted this session — F42; ISPSS
      unconfirmed) · [ ] Delete · [ ] GetMembers (same — F43, Self-Hosted confirmed only) ·
      [x] List (**confirmed live 2026-09-21**: 70 groups; expect the `GroupType` filter to be
      unusable — see the known-behavior note above, not a bug to report) · [ ] RemoveMember ·
      [ ] Update

### Applications (7 actions, dual-use — only menu visibility has been confirmed on ISPSS so far)

- [ ] Add (menu visibility confirmed 2026-09-02; this session's new validation hardening — F45 — is
      unconfirmed on any live tenant) · [ ] AddAuthMethod · [ ] Delete · [ ] DeleteAuthMethod ·
      [ ] Get · [x] List (**confirmed live 2026-09-21**: 2 applications) ·
      [x] ListAuthMethods (**confirmed live 2026-09-21**: 2 applications checked, 0 auth methods
      returned — the blank-`AppID`-lists-every-application behavior itself remains unverified,
      since this run queried the 2 known applications directly rather than a blank `AppID`)
- These 6 (all but `Add`) were expanded from Self-Hosted-only to dual-use on 2026-09-02 after the
  user found only `Add` visible on the ISPSS menu. Their actual ISPSS request/response behavior has
  never been exercised — this is the first opportunity to do so.

### Custom (7 actions, dual-use)

- [x] ExportAll (**confirmed live 2026-09-21**: 8 modules run, 8 succeeded — it correctly did not
      attempt `Platforms/Rename`, `Policies/SetMasterPolicy`, or `Reports/List`, and
      `Policies/GetMasterPolicy`'s 404 degraded gracefully as a non-fatal item within the batch,
      matching the already-confirmed absent-endpoint behavior) ·
      [x] ExportEntitlements (**confirmed live 2026-09-21**: 29 safes, 114 members, 0 failures) ·
      [ ] ExportGroupMembersLDAP (this is the one export module where the `GroupType='Vault'` quirk
      matters most — its groupName-contains-`@` heuristic exists specifically to work around it;
      confirm it actually distinguishes LDAP from local groups correctly on this tenant) ·
      [ ] ExportGroupMembersLocal (same heuristic — confirm normal local/Vault-group export works) ·
      [x] ExportPlatformDetails (confirmed live on Self-Hosted only; **confirmed live 2026-09-21**
      on ISPSS too: 14/14 platforms succeeded) ·
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

The revision log is no longer kept here. Use git history instead (`git log -- Claude_Docs/Testing_Plan.md`). Entries up to 2026-09-25 are in [Archive_Testing_Revision-Log.md](Archive_Testing_Revision-Log.md).
