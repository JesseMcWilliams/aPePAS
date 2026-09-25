# Testing Plan

## Testing documents

| Document | Contents |
|---|---|
| [Testing_Findings-and-Known-Issues.md](Testing_Findings-and-Known-Issues.md) | Open findings (one-line index; closed detail is in `Archive_Testing_Findings-Closed.md`) and the known-issues / risk register. |
| [Testing_Unit-Test-Cases.md](Testing_Unit-Test-Cases.md) | Per-module unit test case IDs and expectations. |
| [Testing_Manual-Integration-Procedures.md](Testing_Manual-Integration-Procedures.md) | Step-by-step manual procedures for auth and the driver against a live PVWA / ISPSS tenant. |
| [Testing_Checklist-Self-Hosted.md](Testing_Checklist-Self-Hosted.md) | Per-action live test checklist for Self-Hosted PVWA. |
| [Testing_Checklist-ISPSS.md](Testing_Checklist-ISPSS.md) | Per-action live test checklist for ISPSS / Privilege Cloud. |
| [Archive_Testing_Findings-Closed.md](Archive_Testing_Findings-Closed.md) | Full detail of the closed findings F01-F68 (archive, not read by default). |

## Overview

This document describes the testing strategy for the aPePAS project.
Tests are organized into **unit tests** (no live CyberArk connection required) and
**integration tests** (require a real CyberArk environment). All unit tests use
[Pester v6](https://pester.dev) and live under `Tests\Unit\`.

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
`Archive_Planning_Improvement-Plan-2026-09-02.md` — see `Archive_Planning_Documentation-Tracker.md` for the full history):

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
    live ISPSS tenant remains unverified (see [Testing_Checklist-ISPSS.md](Testing_Checklist-ISPSS.md)).
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
  `Reference_Lessons-Learned-CyberArk-API.md` §7-§9 (formerly Section 16) for the originals):
  - ISPSS returns `groupType='Vault'` (and no `directory.directoryType`) for **every** group,
    including LDAP/directory-backed ones. `Groups/Invoke-GroupsList.ps1`'s `GroupType` filter is
    effectively unusable on ISPSS as a result — filtering for anything but `Vault` silently
    returns zero rows with no explanation. `Custom/Invoke-CustomExportGroupMembersLDAP.ps1` and
    `Custom/Invoke-CustomExportGroupMembersLocal.ps1` both work around this with a
    groupName-contains-`@` heuristic (this session fixed the Local module, which had not received
    that fix when the LDAP module did — see [Testing_Findings-and-Known-Issues.md](Testing_Findings-and-Known-Issues.md)).
  - CyberArk's `/API/Accounts` endpoint caps results at roughly 20,000 without a safe filter
    (`Invoke-AccountsList.ps1`'s "By-Safe" mode works around this) — confirm whether the same cap
    applies identically on the Self-Hosted PVWA version under test; it may differ by version.
  - Field-name/response-shape differences by PVWA version are common for Platforms (`id` vs
    `PlatformID`, `platformType` vs `SystemType`, nested under `general` or at the root) and Safe
    Members (camelCase vs PascalCase permission keys) - see `Reference_Lessons-Learned-CyberArk-API.md` §4, §5 and §13 (formerly Sections 12 and 19).
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

Pester v6 is required. `Run-Tests.ps1` checks for it and prints installation
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
| `CyberArkComms.psm1` | Partial (helpers + success path; 401/429/504 error paths need `Invoke-CyberArkAPI` mocking at the module-caller level - see Testing Boundaries). `Disable-SSLValidation`/`Reset-SSLValidation` (C34-C39) only run under real Windows PowerShell 5.1 - `ICertificatePolicy` isn't usable under `pwsh`/.NET Core at all, confirmed directly (see Finding F57). `Expect100Continue` is disabled unconditionally at module-load time (C43, K16/F66) - runs under both `pwsh` and PS 5.1, since unlike `ICertificatePolicy` this is a plain settable property under both hosts Thrown HTTP errors on both editions are now covered against a real local HttpListener (C44-C47, F70). | `Unit\CyberArkComms.Tests.ps1` | Yes — 429 backoff and 504 retry/page-shrink against a real PVWA; confirm the K02 IgnoreSSL-reset fix against a real host (A19); **K16 (Expect100Continue) fix live-verification against the original `Accounts/ChangeImmediate` hang is still pending** - see Finding F66 **F70:** confirm a real 404/401 keeps its status code under PS 7 (for example Master Policy on ISPSS gives 404, not StatusCode 0). |
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
| Policies / GetMasterPolicy | Yes (incl. PGMP08/PGMP09 for the dual-use/graceful-404 behavior) PGMP10: `ExportAllSystems` keeps it out of Export All on ISPSS. | `Unit\Invoke-PoliciesGetMasterPolicy.Tests.ps1` | Self-Hosted **confirmed (2026-09-04)** — live retrieval against the real tenant, including through the `Custom/ExportAll` `IncludeInExportAll` path. **ISPSS/Privilege Cloud confirmed (2026-09-04) to have no Master Policy equivalent endpoint** — the user verified this live against a real Privilege Cloud tenant. `SupportedSystems` is kept dual-use anyway (per user direction, current behavior is fine): the module's existing non-fatal failure handling already turns that into a clean `Failure`, not a crash, so no code change was needed. See Finding F40 |
| Applications / Add | Yes | `Unit\Invoke-ApplicationsAdd.Tests.ps1` | **Confirmed (2026-09-02)** — the only Applications action the user found visible/working on the ISPSS Applications menu, confirming its earlier dual-use `SupportedSystems`. F45's new `AccessPermittedFrom`/`To` range check and `AppID`/`Description`/`BusinessOwnerFName`/`BusinessOwnerPhone` length/charset checks are unit-tested only, not yet confirmed live |
| Applications / AddAuthMethod | Yes | `Unit\Invoke-ApplicationsAddAuthMethod.Tests.ps1` | Menu visibility only — user's 2026-09-02 ISPSS test showed this action missing from the menu (it was still Self-Hosted-only); now expanded to dual-use. Actual ISPSS request/response behavior is unverified |
| Applications / Delete | Yes | `Unit\Invoke-ApplicationsDelete.Tests.ps1` | Menu visibility only — same 2026-09-02 finding and expansion as AddAuthMethod above; ISPSS request/response behavior unverified |
| Applications / DeleteAuthMethod | Yes | `Unit\Invoke-ApplicationsDeleteAuthMethod.Tests.ps1` | Menu visibility only — same 2026-09-02 finding and expansion as AddAuthMethod above; ISPSS request/response behavior unverified |
| Applications / Get | Yes | `Unit\Invoke-ApplicationsGet.Tests.ps1` | Menu visibility only — same 2026-09-02 finding and expansion as AddAuthMethod above; ISPSS request/response behavior unverified |
| Applications / List | Yes | `Unit\Invoke-ApplicationsList.Tests.ps1` | **Confirmed (2026-09-02) on Self-Hosted** (the `Join-CyberArkUrl` trailing-slash/PIMServices.svc routing fix noted here is covered by that confirmation). On ISPSS, only menu visibility was confirmed the same day — it had been Self-Hosted-only and is now expanded to dual-use; ISPSS request/response behavior is unverified |
| Applications / ListAuthMethods | Yes | `Unit\Invoke-ApplicationsListAuthMethods.Tests.ps1` | Self-Hosted: Yes — **not** covered by the "all List actions confirmed" status below, since its `Action` is `ListAuthMethods`, not `List`. The blank-`AppID`-lists-every-application behavior (added this session, per user request) is new and unverified against a real host. On ISPSS, only menu visibility was confirmed 2026-09-02 — it had been Self-Hosted-only and is now expanded to dual-use; ISPSS request/response behavior is unverified |
| Reports / List (RL16: `ExcludeFromExportAll`, never run by Export All.) | Yes | `Unit\Invoke-ReportsList.Tests.ps1` | **Confirmed Self-Hosted-only (2026-09-02)** — the user tested this live against an ISPSS/Privilege Cloud tenant and got an HTTP 404 (`GET /API/Reports` doesn't exist there), reversing Phase 1's dual-use expansion. `SupportedSystems` reverted to `@('SelfHosted')`; the module is now hidden from the ISPSS menu entirely |
| Users / Get | Yes | `Unit\Invoke-UsersGet.Tests.ps1` | Yes |
| Users / List | Yes | `Unit\Invoke-UsersList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted |
| Groups / Add | Yes | `Unit\Invoke-GroupsAdd.Tests.ps1` | Yes |
| Groups / AddMember | Yes (incl. GAM07/GAM08 for the username-not-integer fix) | `Unit\Invoke-GroupsAddMember.Tests.ps1` | **Confirmed (2026-09-04)** — previously logged as a live-tenant HTTP 400 limitation (F42: the "memberId" field is the username, not a numeric ID), the user reported the fix and it was live-verified end-to-end (create test group -> add member by username -> HTTP 201) |
| Groups / Delete | Yes | `Unit\Invoke-GroupsDelete.Tests.ps1` | Yes |
| Groups / GetMembers | Yes (incl. GM17 for the missing-userType/componentUser fix) | `Unit\Invoke-GroupsGetMembers.Tests.ps1` | **Confirmed (2026-09-04)** — found and fixed live (F43) during F42's verification: a real member entry is only `{id, username}`, no `userType`/`componentUser`, which previously crashed the mapping loop under strict mode |
| Groups / List | Yes | `Unit\Invoke-GroupsList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted (the `GroupType` filter noted here is covered by that confirmation) |
| Groups / RemoveMember | Yes | `Unit\Invoke-GroupsRemoveMember.Tests.ps1` | **Confirmed (2026-09-04)** — live-verified as part of F42's end-to-end test (remove by username -> HTTP 204); already treated MemberID as a string, so no code change was needed here, only the description |
| Groups / Update | Yes | `Unit\Invoke-GroupsUpdate.Tests.ps1` | Yes |
| Custom / ExportAll | Yes, including automation mode's `-OutputFolder` override (3 new cases) F71: sub-module failures, IsFatal token re-check and stop (EA1-EA7); `ExportAllSystems` filter (EA8). | `Unit\Invoke-CustomExportAll.Tests.ps1` | Yes — now also discovers and runs Applications/ListAuthMethods (added this session, per user request), not previously part of Export All. That specific addition is unverified against a real host. **Also now discovers Policies/GetMasterPolicy via a new generic `ModuleMeta.IncludeInExportAll` opt-in (any non-List/ListAuthMethods module can use it) - confirmed live (2026-09-04) against the real Self-Hosted tenant, saving a real `Export_PoliciesGetMasterPolicy.csv`**. `-OutputFolder` (F54) is unit-tested only, not yet live-verified **F71:** confirm on both systems and both editions that a failed sub-report shows as a Failed row and the run continues, that Reports/List never runs and Master Policy runs on Self-Hosted only, and that an expired token stops the run and re-authenticates (the ISPSS re-check uses `GET /API/Safes?limit=1`, unverified live). |
| Custom / ExportEntitlements | Yes | `Unit\Invoke-CustomExportEntitlements.Tests.ps1` | Yes |
| Custom / ExportGroupMembersLDAP | Yes | `Unit\Invoke-CustomExportGroupMembersLDAP.Tests.ps1` | Yes — requires line-of-sight from wherever the script runs to the actual Active Directory (ADSI-based, not a CyberArk API call) |
| Custom / ExportGroupMembersLocal | Yes (incl. new ISPSS-groupType-quirk regression test this session) | `Unit\Invoke-CustomExportGroupMembersLocal.Tests.ps1` | Yes |
| Custom / ExportPlatformDetails | Yes (PPD01-PPD12; uses real in-memory-built `.zip` archives, not mocked-away zip parsing) | `Unit\Invoke-CustomExportPlatformDetails.Tests.ps1` | **Confirmed (2026-09-04)** — live run against the real Self-Hosted tenant: 10/10 active platforms (of 15 total) processed successfully, 104 dynamic columns, spot-checked type-specific fields (e.g. `Ini.ExtraInfo.Port`, `Ini.KeySize`) populate only where applicable and blank-fill elsewhere. The `OtherFiles`/META-INF-exclusion logic is implemented exactly per spec and unit-tested, but no real example of a platform with extra bundled files or a META-INF folder was found on this tenant across the platforms sampled, so that part remains live-unconfirmed |
| Custom / TestApi | **No unit test file exists** (interactive raw API tester — same exemption class as other `Read-Host`-driven helpers) | — | Yes (manual smoke test only) |
| Custom / TestConnectivity | Yes (orchestration mocked; DNS/TCP helpers, `ConvertTo-Win32QuotedArgument`, `ConvertTo-PortList`, `Find-PlinkExecutable`, and the plink trust-on-first-use retry exercised for real/mocked deterministically - no CyberArk connection needed for those) | `Unit\Invoke-CustomTestConnectivity.Tests.ps1` | The Linux/plink path is now fully confirmed live end-to-end against a real target with real credentials (172.21.20.14, user-provided test account): DNS resolution (F28), plink-first with host-key trust-on-first-use (F27/F29), a successful login (`AuthStatus: Success`), and a wrong password failing cleanly - the CSV filename change (F26) was also confirmed live in the same pass. Not yet confirmed live: the actual Windows SMB (`New-SmbMapping`) auth attempt, the PS7 SSH transport path's own success case (it's documented to time out on password auth and plink is now tried first, so this may never need separate confirmation), the `Safe`/`Username`/`PasswordSource` output columns (F22) against a real vault-backed lookup (the live test above supplied the password directly, not via vault lookup), and F52's new `AdditionalPorts` field |

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

## Revision Log

The revision log is no longer kept here. Use git history instead (`git log -- Claude_Docs/Testing_Plan.md`). Entries up to 2026-09-25 are in [Archive_Testing_Revision-Log.md](Archive_Testing_Revision-Log.md).
