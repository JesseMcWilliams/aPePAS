# aPePAS: Test Status Before the Merge (archive)

> **Stage: Archive (Testing).** On 2026-10-11 (R16, handoff item 13.3) test status moved into one place, [Testing_Status.md](Testing_Status.md). This file keeps the three sections it replaced, verbatim, for their detail and history. Don't update it; record new status in `Testing_Status.md`. Links inside the copied text are relative to `Claude_Docs/` and may point at sections that no longer exist.

## 1. Testing_Plan.md: Component Test Matrix


This table was significantly out of date relative to the actual `Tests\Unit\` folder (which
already had unit tests for every shipped module) — it listed only a handful of modules. It now
lists every component and module that exists in this project, its unit-test file, and whether it
also needs manual/live Self-Hosted integration verification per this test pass. "SH" = SupportedSystems
includes SelfHosted; "Both" = SelfHosted + ISPSS declared (see the caution section above).

### Core / Shared

| Component | Unit Tests | Test File | Live Self-Hosted Verification Needed |
|---|---|---|---|
| `CyberArkLogging.psm1` | Yes | `Unit\CyberArkLogging.Tests.ps1` | No |
| `CyberArkComms.psm1` | Partial (helpers + success path; account identifier helpers C48-C62 (F72); explicit `-PageSize 0` beats the profile page size, C66-C67 (F90); `/api/Users` pages with `pageSize`/`pageOffset`, C72-C74 (F95); 401/429/504 error paths need `Invoke-CyberArkAPI` mocking at the module-caller level - see Testing Boundaries). `Disable-SSLValidation`/`Reset-SSLValidation` (C34-C39) only run under real Windows PowerShell 5.1 - `ICertificatePolicy` isn't usable under `pwsh`/.NET Core at all, confirmed directly (see Finding F57). `Expect100Continue` is disabled unconditionally at module-load time (C43, K16/F66) - runs under both `pwsh` and PS 5.1, since unlike `ICertificatePolicy` this is a plain settable property under both hosts Thrown HTTP errors on both editions are now covered against a real local HttpListener (C44-C47, F70). | `Unit\CyberArkComms.Tests.ps1` | Yes — 429 backoff and 504 retry/page-shrink against a real PVWA; confirm the K02 IgnoreSSL-reset fix against a real host (A19); **K16 (Expect100Continue) fix live-verification against the original `Accounts/ChangeImmediate` hang is still pending** - see Finding F66 **F70:** confirm a real 404/401 keeps its status code under PS 7 (for example Master Policy on ISPSS gives 404, not StatusCode 0). |
| `CyberArkCredentialStore.psm1` | Yes (CS01-CS08) - extracted from `Manage-Privilege.ps1` (see Finding F61) so a standalone helper script can reuse the same `.autocred` store | `Unit\CyberArkCredentialStore.Tests.ps1` | No (pure file I/O, same DPAPI mechanism as the already-verified `.cred` token file) |
| `Auth\CyberArk.Auth.Common.psm1` | No direct test file (WebView2/cert-store/DPAPI all require a live Windows session), but `Invoke-WebView2Window`'s `-IgnoreSSL` parameter-forwarding is covered indirectly via `Auth\CyberArk.Auth.SelfHosted.psm1`'s own tests (SH-SSL01-SH-SSL04, mocking `Invoke-WebView2Window` itself); `Get-ISPSSAuthThrottle`/`Set-ISPSSAuthThrottle` (K17/F67, F68) are covered via `CyberArk.Auth.ISPSS.Tests.ps1`'s K17-01 through K17-07 (imported there transitively - no separate test file needed, pure file I/O, no live session required); the sidecar file's own extension not colliding with `Get-AllDriverProfiles`' profile-discovery glob (F68) is covered by `Manage-Privilege.Tests.ps1` DP10a | — | Yes — `Save-AuthToken`/`Import-AuthToken` round-trip, `Get-FilteredClientCertificate` picker, and (Finding F58) the WebView2 `ServerCertificateErrorDetected`/`AlwaysAllow` behavior against a real self-signed/internal-CA host (A07/A08); **K17's `RetryWaitingTime` throttle not yet live-verified** - blocked on the same SaaS tenant re-authentication issue F66/F67 investigate |
| `Auth\CyberArk.Auth.SelfHosted.psm1` | Partial - `Update-SelfHostedAuthToken`'s `-NoPrompt` guard (SH-NP01-SH-NP04) and SAML/OIDC's `-IgnoreSSL` forwarding to `Invoke-WebView2Window` (SH-SSL01-SH-SSL04); the 8 live auth flows themselves are not unit-tested | `Unit\CyberArk.Auth.SelfHosted.Tests.ps1` | Yes (manual, all 8 methods — see the dedicated section below) |
| `Auth\CyberArk.Auth.ISPSS.psm1` | Partial - `ClientCredentials` response parsing, (K12/F62) `Interactive`'s `-NoPrompt` silent-refresh/credential-capture behavior, and (K17/F67) `RetryWaitingTime` throttle recording/carry-through via mocked `StartAuthentication`/`AdvanceAuthentication`; `SSO`'s WebView2 flow and Interactive's own live MFA-challenge UX are not unit-tested | `Unit\CyberArk.Auth.ISPSS.Tests.ps1` (ISPSS-CC01-CC06, ISPSS-INT01-05, K17-01 through K17-07) | Partially done — `AuthMethod=Interactive` confirmed live end-to-end via automation mode (K12/F62, 2026-09-21, `Company_AutoUser` profile, Custom/ExportAll, ExitCode=0). Still needed: `SSO`, `ClientCredentials` against a live tenant, observing K12's silent-refresh-on-expiry path specifically triggering mid-run (this run's token didn't need a refresh), and K17's `RetryWaitingTime` throttle against a real StartAuthentication response |
| `Manage-Privilege.ps1` — profile CRUD | Yes (filesystem) | `Unit\Manage-Privilege.Tests.ps1` | No |
| `Manage-Privilege.ps1` — profile backup/restore (`Backup-DriverProfiles`/`Restore-DriverProfiles`, `Invoke-ProfileBackupFlow`/`Invoke-ProfileRestoreFlow`) | Partial - verified via a standalone dot-sourced repro script, not Pester (see Finding F51 for why). K14/F64's single-profile-selection array-unwrapping fix verified the same way, including that the selection itself is correct (not just non-crashing) | — (repro script, not checked into `Tests\`) | Yes (manual — D26-D30 below) |
| `Manage-Privilege.ps1` — stored automation credential (`Use-StoredCredentialIfMissing`, `Invoke-ClearNonRefreshableContext`, and the driver's own call sites for `Save-/Get-/Remove-ProfileCredential` — the functions themselves now live in `CyberArkCredentialStore.psm1`, see Finding F61; both functions now also cover ISPSS Interactive, see K12/F62) | Yes (AM41-AM50, AM71-76) - the `[A]` menu action itself is interactive UI and not unit-tested | `Unit\Manage-Privilege.Automation.Tests.ps1` | Yes (manual — D43 below) |
| `Manage-Privilege.ps1` — token/profile Base URL staleness (`Get-ExpectedTokenBaseURL`, `Test-TokenBaseURLStale`, `Invoke-ProfileConnect`/Test Connection/`Invoke-TokenRefresh`'s use of them) | Yes (AM52-AM63) - the pure comparison logic and `Invoke-ProfileConnect`'s discard behavior are unit-tested; the Test Connection flow's own staleness check is not (interactive UI) | `Unit\Manage-Privilege.Automation.Tests.ps1` | Yes (manual — D44 below) |
| `Manage-Privilege.ps1` — `WebView2AssemblyPath` profile field (`Invoke-ProfileConnect`/Test Connection forwarding it to `Get-SelfHostedAuthToken`/`Get-ISPSSAuthToken`) | Yes (AM66-AM68) - the `Invoke-ProfileEditFlow` prompt and `Show-ProfileDetail` display are interactive UI and not unit-tested | `Unit\Manage-Privilege.Automation.Tests.ps1` | Yes (manual — D46 below) |
| `Manage-Privilege.ps1` — `-StartProfile`/`-AutoConnect` startup, `Invoke-ProfileConnect` | Partial - the automation-mode fresh-auth guard is covered (AM11-AM14); the interactive `-AutoConnect` fallback path itself is UI/interactive and untested; `-AutoConnect`'s parameter validation was spot-checked directly | `Unit\Manage-Privilege.Automation.Tests.ps1` | Yes (manual — D31-D36 below) |
| `Manage-Privilege.ps1` — session loop, keepalive, token refresh, CSV loop | Partial - `Invoke-TokenRefresh`'s automation-mode branch (AM15-AM18) and `Invoke-CsvProcessing -FilePaths` (AM08-AM10) are covered; the interactive session loop itself is UI/interactive and untested | `Unit\Manage-Privilege.Automation.Tests.ps1` | Yes (manual — D-series below, including the new D23-D25 regression/known-gap cases) |
| `Manage-Privilege.ps1` — automation mode (`-Category`/`-Action`, `Invoke-AutomatedAction`, `Get-AutomationExitCode`) | Partial - parameter validation, the CSV/JSON input routes' summary-to-exit-code mapping (`Get-AutomationExitCode`), every automation-mode guard, the `-OutputFolder`/`-FilenameFormat` overrides, `ModuleMeta.CsvFilenameNoDate` (`Format-AutomationFilename`, `Get-CsvSavePath`'s override/`-NoDateSuffix` params, `Save-ModuleResultCsv`'s wiring), and (K15/F65) a structural guard confirming `Invoke-AutomatedAction` never calls `Invoke-SessionLogoff` are unit-tested; `Invoke-AutomatedAction` itself (module resolution, end-to-end dispatch) has no full mock-based coverage, for the same reason the rest of the driver's dispatch logic doesn't - see Testing Boundaries. **K15 IS live-verified** (2026-09-21): 3 consecutive real automation-mode runs against a real Self-Hosted PVWA, reusing one session with no re-auth between them | `Unit\Manage-Privilege.Automation.Tests.ps1` | Yes (manual — D37-D46 below) |
| `Invoke-AutomationWithCredential.ps1` (driver) | Yes (IW01-IW10) - config parsing and validation, argument passthrough, in-process run and exit codes, `-ResolveOnly`, no password on the console; a stand-in aPeSecrets and Manage-Privilege.ps1 replace the real ones | `Unit\Invoke-AutomationWithCredential.Tests.ps1` | Self-Hosted confirmed 2026-10-10 (LT-DRIVER-01); ISPSS open |
| `Manage-Privilege.ps1` — `-Credential` (driver login, refresh, secret kept out of `.cred`) | Yes (AM88-AM97) | `Unit\Manage-Privilege.Automation.Tests.ps1` | Self-Hosted confirmed 2026-10-10 (LT-DRIVER-01) |
| `Manage-Privilege.ps1` — inactivity timeout from the last API call; `-InputFile` skipped files exit 3 | Yes (AM98-AM102; Comms C63-C65) | `Unit\Manage-Privilege.Automation.Tests.ps1`, `Unit\CyberArkComms.Tests.ps1` | Not yet live-checked |
| `Manage-Privilege.ps1` — job files (`-JobFile`) and the detail CSV | Yes (AM103-AM110; driver script IW11) | `Unit\Manage-Privilege.Automation.Tests.ps1`, `Unit\Invoke-AutomationWithCredential.Tests.ps1` | Self-Hosted confirmed 2026-10-10 (LT-JOB-01) |

### APIModules — SelfHosted only (no ISPSS ambiguity)

| Module | Unit Tests | Test File | Live Self-Hosted Verification Needed |
|---|---|---|---|
| Platforms / Rename | Yes | `Unit\Invoke-PlatformsRename.Tests.ps1` | Yes — PVWA 15.0+ required, confirm against this lab host's actual version |
| Policies / SetMasterPolicy | Yes | `Unit\Invoke-PoliciesSetMasterPolicy.Tests.ps1` | Yes — PVWA 14.6+ required. Mutates tenant-wide config, not a scoped object — test against a dedicated lab host only, never a shared/production one |

### APIModules — dual-use (Both; ISPSS coverage unverified — see caution section)

| Module | Unit Tests | Test File | Live Self-Hosted Verification Needed |
|---|---|---|---|
| Accounts / Add | Yes | `Unit\Invoke-AccountsAdd.Tests.ps1` | Yes |
| Accounts / CancelCpmTask | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsCancelCpmTask.Tests.ps1` | Yes |
| Accounts / ChangeImmediate | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsChangeImmediate.Tests.ps1` | Yes |
| Accounts / ChangeInVault | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsChangeInVault.Tests.ps1` | Yes — confirm the corrected `Password/Update` endpoint (F12, this session — was `SetNextPassword` before) actually changes the vault password immediately; also confirm the JSON-key log-masking pattern keeps the new vault password out of the log file at DEBUG level against a real call |
| Accounts / CheckIn | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsCheckIn.Tests.ps1` | Yes |
| Accounts / Delete | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsDelete.Tests.ps1` | Yes |
| Accounts / Get | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsGet.Tests.ps1` | Yes |
| Accounts / GetActivity | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsGetActivity.Tests.ps1` | Yes |
| Accounts / GetCredential | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsGetCredential.Tests.ps1` | Yes |
| Accounts / LinkAccount | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsLinkAccount.Tests.ps1` | **Confirmed (2026-09-04)** — previously logged as a live-tenant HTTP 404 limitation (F41), the user has since retested and confirmed it now works correctly |
| Accounts / List (incl. By-Safe mode) | Yes | `Unit\Invoke-AccountsList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted |
| Accounts / Reconcile | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsReconcile.Tests.ps1` | Yes |
| Accounts / ResumeAutoManagement | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsResumeAutoManagement.Tests.ps1` | Yes |
| Accounts / UnlinkAccount | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsUnlinkAccount.Tests.ps1` | **Confirmed (2026-09-04)** — same as LinkAccount above (F41) |
| Accounts / Unlock | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsUnlock.Tests.ps1` | Yes |
| Accounts / Update (JSON Patch) | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsUpdate.Tests.ps1` | Yes |
| Accounts / Verify | Yes; account lookup via the shared identifier helpers (F72) | `Unit\Invoke-AccountsVerify.Tests.ps1` | Yes |
| Accounts / RequestJitAccess | Yes (RJ01-RJ13): POST with no body, account lookup, WhatIf, error paths | `Unit\Invoke-AccountsRequestJitAccess.Tests.ps1` | Partly: 2026-10-10 Self-Hosted, endpoint answers PASWS211E for a Vault (non-LDAP) caller. A grant needs an LDAP-user profile and a Windows platform with ad hoc access |
| Accounts / ListDependents | Yes (DL01-DL18), including `-PageSize 0` and bare or wrapped responses | `Unit\Invoke-AccountsListDependents.Tests.ps1` | **Confirmed live 2026-10-11** (Self-Hosted, master 49_3) |
| Accounts / ListAllDependents | Yes (DW01-DW13): platformId/SafeName filter, no master filter, paging of a bare array | `Unit\Invoke-AccountsListAllDependents.Tests.ps1` | **Confirmed live 2026-10-11**: wrapped (paged) response; `platformId` and quoted `SafeName` filters work; `MasterAccountId`/`masterAccountId`/`accountId` get 400 PASWS357E |
| Accounts / GetDependent | Yes (DG01-DG16), including the picker and LinkedAccounts | `Unit\Invoke-AccountsGetDependent.Tests.ps1` | **Confirmed live 2026-10-11** |
| Accounts / AddDependent | Yes (DA01-DA18), including the PlatformAccountProperties / `Platform_<Key>` input | `Unit\Invoke-AccountsAddDependent.Tests.ps1` | **Confirmed live 2026-10-11** (201). A platform that doesn't fit the master gets 400 PASWS366E |
| Accounts / UpdateDependent | Yes (DU01-DU20): GET + merge + PUT, blank keeps | `Unit\Invoke-AccountsUpdateDependent.Tests.ps1` | **Confirmed live 2026-10-11**: changed reason and TaskName, Address kept |
| Accounts / DeleteDependent | Yes (DX01-DX14) | `Unit\Invoke-AccountsDeleteDependent.Tests.ps1` | **Confirmed live 2026-10-11** (204) |
| Accounts / SyncDependent | Yes (DS01-DS13) | `Unit\Invoke-AccountsSyncDependent.Tests.ps1` | No: makes the CPM act on a real machine; run on a disposable target |
| Accounts / ResumeDependent | Yes (DR01-DR13) | `Unit\Invoke-AccountsResumeDependent.Tests.ps1` | No: same reason as Sync |
| Accounts / ListDiscovered | Yes (LD01-LD09): query/filter building (quoted values, AND, boolean check), row mapping, 403/404/401 | `Unit\Invoke-AccountsListDiscovered.Tests.ps1` | Endpoint confirmed 2026-10-11 (200, Pending list empty in the lab) |
| Accounts / GetDiscovered | Yes (GD01-GD07), including `-PageSize 0` and the extended columns | `Unit\Invoke-AccountsGetDiscovered.Tests.ps1` | Error path only: 2026-10-11 a made-up ID gave 400 PASWS168E. Needs a pending account |
| Accounts / OnboardDiscovered | Yes (OD01-OD11): body vs query placement, password never logged, WhatIf, validation | `Unit\Invoke-AccountsOnboardDiscovered.Tests.ps1` | No: needs a pending account |
| Accounts / DeleteDiscovered | Yes (DD01-DD05), including never calling the clear-all DELETE | `Unit\Invoke-AccountsDeleteDiscovered.Tests.ps1` | No: needs a pending account |
| Accounts / ListOnboardingPlatforms | Yes (OP01-OP05) | `Unit\Invoke-AccountsListOnboardingPlatforms.Tests.ps1` | **Confirmed live 2026-10-11** (15 platforms for Test Accounts / Windows Desktop Local) |
| Accounts / RetrieveSshKey | Yes (SK01-SK13): body has only the given fields; key saved to a no-BOM `.key` file from text, JSON string, `Content` or File bytes; key never in results or log; unknown shape reports property names only | `Unit\Invoke-AccountsRetrieveSshKey.Tests.ps1` | No: needs an SSH key account in the lab (not run against a password account, to avoid retrieving a live password) |
| Accounts / RevokeJitAccess | Yes (VJ01-VJ13), same shape as RequestJitAccess | `Unit\Invoke-AccountsRevokeJitAccess.Tests.ps1` | Partly: 2026-10-10 Self-Hosted, PASWS293E for a non-LDAP caller |
| Safes / Add | Yes, including AutoPurgeEnabled accepting true/yes/y/1 (F79) | `Unit\Invoke-SafesAdd.Tests.ps1` | Yes — F44's new `SafeName` length/charset/leading-whitespace rejection is unit-tested only, not yet confirmed against a real Vault's own naming rule |
| Safes / AddFromTemplate | Yes, including ExtraMembers SearchIn and skipping the template CPM member (F74), and the F76 SearchIn picker (T63-T65) | `Unit\Invoke-SafesAddFromTemplate.Tests.ps1` | Yes |
| Safes / AssignCPM | Yes | `Unit\Invoke-SafesAssignCPM.Tests.ps1` | Yes — confirm the live CPM query against the real host |
| Safes / Delete | Yes | `Unit\Invoke-SafesDelete.Tests.ps1` | Yes |
| Safes / Get | Yes | `Unit\Invoke-SafesGet.Tests.ps1` | Yes |
| Safes / List | Yes | `Unit\Invoke-SafesList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted |
| Safes / UnassignCPM | Yes | `Unit\Invoke-SafesUnassignCPM.Tests.ps1` | Yes |
| Safes / Update | Yes, including AutoPurgeEnabled never sent and the warning when supplied (F77) | `Unit\Invoke-SafesUpdate.Tests.ps1` | Yes — F44's new `SafeName` length/charset/leading-whitespace rejection is unit-tested only, not yet confirmed live |
| SafeMembers / Add | Yes, including the SearchIn picker's `/api/settings/AddSafeMember` source and its fallback (F76), and the F85 PermissionRole / blank-column rules, and F93 (ExpirationDate sent as Unix seconds; a bad date fails the row) | `Unit\Invoke-SafeMembersAdd.Tests.ps1` | Yes — confirm the SearchIn directory picker lists real LDAP directories. F47's `ReadOnly` -> `ReadOnlyStrict` preset rename is unit-tested only |
| SafeMembers / AddFromTemplateRole | Yes (shares the F76 SearchIn picker tested under SafeMembers / Add) | `Unit\Invoke-SafeMembersAddFromTemplateRole.Tests.ps1` | Yes |
| SafeMembers / List | Yes, including the includePredefinedUsers filter and its HTTP 400 retry (F78), and the optional MemberType / MembershipExpired / Sort filters, applied locally after that retry (ML24-ML32) | `Unit\Invoke-SafeMembersList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted | The MemberType / MembershipExpired / Sort filters are not live-tested.
| SafeMembers / Remove | Yes | `Unit\Invoke-SafeMembersRemove.Tests.ps1` | Yes |
| SafeMembers / Update | Yes, including F85 (role vs. individual columns; blank columns and ExpirationDate keep the current values via a member GET) and F93 (Unix-seconds ExpirationDate) | `Unit\Invoke-SafeMembersUpdate.Tests.ps1` | Yes — F93 and F85's expiration rules **confirmed live 2026-10-10**; F47's `ReadOnly` -> `ReadOnlyStrict` preset rename is unit-tested only |
| SafeMembers / UpdateFromTemplateRole | Yes, including F85's blank-ExpirationDate rule and F93 (Unix-seconds ExpirationDate) | `Unit\Invoke-SafeMembersUpdateFromTemplateRole.Tests.ps1` | Yes — F85 unit-tested only |
| Platforms / Copy | Yes | `Unit\Invoke-PlatformsCopy.Tests.ps1` | Yes — Target platforms only this pass (see `Planning_E2E-Automation.md`); confirmed against psPAS source + the 14.6 Swagger spec, never against a live tenant |
| Platforms / Disable | Yes | `Unit\Invoke-PlatformsDisable.Tests.ps1` | Yes — same caveat as Copy |
| Platforms / Enable | Yes | `Unit\Invoke-PlatformsEnable.Tests.ps1` | Yes — same caveat as Copy |
| Platforms / Export | Yes | `Unit\Invoke-PlatformsExport.Tests.ps1` | `PlatformID` variant **confirmed (2026-09-04)** — live download of a real `.zip`, verified openable with real policy files inside. `RotationalGroupID`/`DependentID`/`GroupPlatformID` variants unit-tested against psPAS's documented shapes only, not yet live-confirmed - no existing module can discover a real ID for those types |
| Platforms / Get | Yes | `Unit\Invoke-PlatformsGet.Tests.ps1` | Yes |
| Platforms / Import | Yes | `Unit\Invoke-PlatformsImport.Tests.ps1` | Yes — the ZIP-as-byte-array request shape is unverified against a live tenant (see its own code comment and `Planning_E2E-Automation.md`) |
| Platforms / List | Yes, including the `PlatformType` (Regular/Group) filter (PL21-PL26) | `Unit\Invoke-PlatformsList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted (the alternate-field-name fallback and `SystemType` filter noted here are covered by that confirmation) | `PlatformType` is not live-tested.
| Platforms / Remove | Yes | `Unit\Invoke-PlatformsRemove.Tests.ps1` | Yes — destructive; test against a disposable sandbox platform only, same caveat as Copy otherwise |
| Platforms / SetPSMConfig | Yes | `Unit\Invoke-PlatformsSetPSMConfig.Tests.ps1` | Yes — same caveat as Copy; needs a real PSM server ID from the test tenant |
| Policies / GetMasterPolicy | Yes (incl. PGMP08/PGMP09 for the dual-use/graceful-404 behavior) PGMP10: `ExportAllSystems` keeps it out of Export All on ISPSS. | `Unit\Invoke-PoliciesGetMasterPolicy.Tests.ps1` | Self-Hosted **confirmed (2026-09-04)** — live retrieval against the real tenant, including through the `Custom/ExportAll` `IncludeInExportAll` path. **ISPSS/Privilege Cloud confirmed (2026-09-04) to have no Master Policy equivalent endpoint** — the user verified this live against a real Privilege Cloud tenant. `SupportedSystems` is kept dual-use anyway (per user direction, current behavior is fine): the module's existing non-fatal failure handling already turns that into a clean `Failure`, not a crash, so no code change was needed. See Finding F40 |
| Applications / Add | Yes | `Unit\Invoke-ApplicationsAdd.Tests.ps1` | **Confirmed (2026-09-02)** — the only Applications action the user found visible/working on the ISPSS Applications menu, confirming its earlier dual-use `SupportedSystems`. F45's new `AccessPermittedFrom`/`To` range check and `AppID`/`Description`/`BusinessOwnerFName`/`BusinessOwnerPhone` length/charset checks are unit-tested only, not yet confirmed live |
| Applications / AddAuthMethod | Yes, including `certificateattr` (Subject/Issuer/SAN arrays, at-least-one rule, entry-format and SAN-name validation including `RFC822 Name`, entry order kept) | `Unit\Invoke-ApplicationsAddAuthMethod.Tests.ps1` | `certificateattr` (added 2026-10-06): Self-Hosted confirmed live 2026-10-06; ISPSS unverified. Menu visibility only — user's 2026-09-02 ISPSS test showed this action missing from the menu (it was still Self-Hosted-only); now expanded to dual-use. Actual ISPSS request/response behavior is unverified |
| Applications / Delete | Yes | `Unit\Invoke-ApplicationsDelete.Tests.ps1` | Menu visibility only — same 2026-09-02 finding and expansion as AddAuthMethod above; ISPSS request/response behavior unverified |
| Applications / DeleteAuthMethod | Yes, including the picker's `certificateattr` display value (`Format-AuthMethodValue`) | `Unit\Invoke-ApplicationsDeleteAuthMethod.Tests.ps1` | Menu visibility only — same 2026-09-02 finding and expansion as AddAuthMethod above; ISPSS request/response behavior unverified |
| Applications / Get | Yes | `Unit\Invoke-ApplicationsGet.Tests.ps1` | Menu visibility only — same 2026-09-02 finding and expansion as AddAuthMethod above; ISPSS request/response behavior unverified |
| Applications / List | Yes | `Unit\Invoke-ApplicationsList.Tests.ps1` | **Confirmed (2026-09-02) on Self-Hosted** (the `Join-CyberArkUrl` trailing-slash/PIMServices.svc routing fix noted here is covered by that confirmation). On ISPSS, only menu visibility was confirmed the same day — it had been Self-Hosted-only and is now expanded to dual-use; ISPSS request/response behavior is unverified |
| Applications / ListAuthMethods | Yes, including `certificateattr` Subject/Issuer/SAN mapping from the live response shape (AM05a/AM05b) | `Unit\Invoke-ApplicationsListAuthMethods.Tests.ps1` | Self-Hosted: Yes — **not** covered by the "all List actions confirmed" status below, since its `Action` is `ListAuthMethods`, not `List`. The blank-`AppID`-lists-every-application behavior (added this session, per user request) is new and unverified against a real host. On ISPSS, only menu visibility was confirmed 2026-09-02 — it had been Self-Hosted-only and is now expanded to dual-use; ISPSS request/response behavior is unverified |
| Reports / List (RL16: `ExcludeFromExportAll`, never run by Export All.) | Yes, including the 14.6 Swagger `reports` response shape and its Safe/Location/FileName columns (RL17-RL18, F91) | `Unit\Invoke-ReportsList.Tests.ps1` | **Confirmed Self-Hosted-only (2026-09-02)** — the user tested this live against an ISPSS/Privilege Cloud tenant and got an HTTP 404 (`GET /API/Reports` doesn't exist there), reversing Phase 1's dual-use expansion. `SupportedSystems` reverted to `@('SelfHosted')`; the module is now hidden from the ISPSS menu entirely |
| Reports / Export (Self-Hosted only, PVWA 14.6+) | Yes: name resolution (zero/several matches fail), `GET /API/ClassicReports` with psPAS's `data` encoding, the `/API/Reports/{id}/content` route, Excel/CSV saving, `-PageSize 0`, WhatIf (RX01-RX21) | `Unit\Invoke-ReportsExport.Tests.ps1` | Not live-tested |
| Users / Get | Yes, including Email from `internet.businessEmail` (F94), the Enabled/Suspended/Description/Location/ExpiryDate columns and `-PageSize 0` (F96) | `Unit\Invoke-UsersGet.Tests.ps1` | **Confirmed live 2026-10-10** (Self-Hosted): new columns, Enabled after Disable/Enable, ExpiryDate after Update |
| Users / List | Yes, including no Email column (F94) and the Enabled/Suspended/Location columns | `Unit\Invoke-UsersList.Tests.ps1` | **Confirmed (2026-09-02)**; paging with `pageSize`/`pageOffset` (F95) **confirmed live 2026-10-10** at page size 5 |
| Users / Add | Yes, including the password never logged/returned/sent in WhatIf, and field validation | `Unit\Invoke-UsersAdd.Tests.ps1` | **Confirmed live 2026-10-10** (Self-Hosted, disposable user; password not in log or CSV) |
| Users / AddAuthMethod | Yes, including the Bulk body shape and the 404 fallback to GET + PUT | `Unit\Invoke-UsersAddAuthMethod.Tests.ps1` | Yes — Self-Hosted only; needs PVWA 14.6 for the Bulk endpoint, and an older PVWA to exercise the fallback |
| Users / Delete | Yes, including Username resolution (no match / several matches fail the row) | `Unit\Invoke-UsersDelete.Tests.ps1` | **Confirmed live 2026-10-10** (Self-Hosted, by Username). Destructive; disposable test user only. ISPSS support comes from CyberArk's Privilege Cloud tools, not tested |
| Users / Disable | Yes, including the 404 fallback to GET + PUT with `enableUser` | `Unit\Invoke-UsersDisable.Tests.ps1` | **Confirmed live 2026-10-10** (Self-Hosted; primary endpoint, fallback not exercised) |
| Users / Enable | Yes, including the 404 fallback to GET + PUT with `enableUser` | `Unit\Invoke-UsersEnable.Tests.ps1` | **Confirmed live 2026-10-10** (Self-Hosted; primary endpoint, fallback not exercised) |
| Users / RemoveAuthMethod | Yes, including the Bulk body shape and the 404 fallback to GET + PUT | `Unit\Invoke-UsersRemoveAuthMethod.Tests.ps1` | Yes — Self-Hosted only; needs PVWA 14.6 |
| Users / ResetPassword | Yes, including the password never logged/returned/sent in WhatIf, and the 39-character limit | `Unit\Invoke-UsersResetPassword.Tests.ps1` | **Confirmed live 2026-10-10** (Self-Hosted, disposable user; password not in log); on ISPSS only Vault-local users apply (not tested) |
| Users / Unblock | Yes | `Unit\Invoke-UsersUnblock.Tests.ps1` | **Confirmed live 2026-10-10** on a user that wasn't suspended (call succeeds); a suspended user and ISPSS not tested |
| Users / Update | Yes, including GET + merge (blank fields keep current values) and read-only fields left out of the PUT | `Unit\Invoke-UsersUpdate.Tests.ps1` | **Confirmed live 2026-10-10** (Self-Hosted): blank fields (LastName, BusinessEmail, ChangePassOnNextLogon) kept; stored ExpiryDate not checked |
| Groups / Add | Yes | `Unit\Invoke-GroupsAdd.Tests.ps1` | Yes |
| Groups / AddMember | Yes (incl. GAM07/GAM08 for the username-not-integer fix) | `Unit\Invoke-GroupsAddMember.Tests.ps1` | **Confirmed (2026-09-04)** — previously logged as a live-tenant HTTP 400 limitation (F42: the "memberId" field is the username, not a numeric ID), the user reported the fix and it was live-verified end-to-end (create test group -> add member by username -> HTTP 201) |
| Groups / Delete | Yes | `Unit\Invoke-GroupsDelete.Tests.ps1` | Yes |
| Groups / GetMembers | Yes (incl. GM17 for the missing-userType/componentUser fix) | `Unit\Invoke-GroupsGetMembers.Tests.ps1` | **Confirmed (2026-09-04)** — found and fixed live (F43) during F42's verification: a real member entry is only `{id, username}`, no `userType`/`componentUser`, which previously crashed the mapping loop under strict mode |
| Groups / List | Yes, including the `Directory` column from a string or object `directory` (F75) | `Unit\Invoke-GroupsList.Tests.ps1` | **Confirmed (2026-09-02)** — user reports all List actions tested against Self-Hosted (the `GroupType` filter noted here is covered by that confirmation) |
| Groups / RemoveMember | Yes | `Unit\Invoke-GroupsRemoveMember.Tests.ps1` | **Confirmed (2026-09-04)** — live-verified as part of F42's end-to-end test (remove by username -> HTTP 204); already treated MemberID as a string, so no code change was needed here, only the description |
| Groups / Update | Yes | `Unit\Invoke-GroupsUpdate.Tests.ps1` | Yes |
| Custom / ExportAll | Yes, including automation mode's `-OutputFolder` override (3 new cases) F71: sub-module failures, IsFatal token re-check and stop (EA1-EA7); `ExportAllSystems` filter (EA8). | `Unit\Invoke-CustomExportAll.Tests.ps1` | Yes — now also discovers and runs Applications/ListAuthMethods (added this session, per user request), not previously part of Export All. That specific addition is unverified against a real host. **Also now discovers Policies/GetMasterPolicy via a new generic `ModuleMeta.IncludeInExportAll` opt-in (any non-List/ListAuthMethods module can use it) - confirmed live (2026-09-04) against the real Self-Hosted tenant, saving a real `Export_PoliciesGetMasterPolicy.csv`**. `-OutputFolder` (F54) is unit-tested only, not yet live-verified **F71:** confirm on both systems and both editions that a failed sub-report shows as a Failed row and the run continues, that Reports/List never runs and Master Policy runs on Self-Hosted only, and that an expired token stops the run and re-authenticates (the ISPSS re-check uses `GET /API/Safes?limit=1`, unverified live). |
| Custom / ExportEntitlements | Yes | `Unit\Invoke-CustomExportEntitlements.Tests.ps1` | Yes |
| Custom / ExportGroupMembersLDAP | Yes | `Unit\Invoke-CustomExportGroupMembersLDAP.Tests.ps1` | Yes — requires line-of-sight from wherever the script runs to the actual Active Directory (ADSI-based, not a CyberArk API call) |
| Custom / ExportGroupMembersLocal | Yes (incl. new ISPSS-groupType-quirk regression test this session) | `Unit\Invoke-CustomExportGroupMembersLocal.Tests.ps1` | Yes |
| Custom / ExportPlatformDetails | Yes (PPD01-PPD12; uses real in-memory-built `.zip` archives, not mocked-away zip parsing) | `Unit\Invoke-CustomExportPlatformDetails.Tests.ps1` | **Confirmed (2026-09-04)** — live run against the real Self-Hosted tenant: 10/10 active platforms (of 15 total) processed successfully, 104 dynamic columns, spot-checked type-specific fields (e.g. `Ini.ExtraInfo.Port`, `Ini.KeySize`) populate only where applicable and blank-fill elsewhere. The `OtherFiles`/META-INF-exclusion logic is implemented exactly per spec and unit-tested, but no real example of a platform with extra bundled files or a META-INF folder was found on this tenant across the platforms sampled, so that part remains live-unconfirmed |
| Custom / TestApi | **No unit test file exists** (interactive raw API tester — same exemption class as other `Read-Host`-driven helpers) | — | Yes (manual smoke test only) |
| Custom / TestConnectivity | Yes (orchestration mocked; DNS/TCP helpers, `ConvertTo-Win32QuotedArgument`, `ConvertTo-PortList`, `Find-PlinkExecutable`, the F86 `Safe` filter and multiple-match `Note`, and the plink trust-on-first-use retry exercised for real/mocked deterministically - no CyberArk connection needed for those) | `Unit\Invoke-CustomTestConnectivity.Tests.ps1` | The Linux/plink path is now fully confirmed live end-to-end against a real target with real credentials (172.21.20.14, user-provided test account): DNS resolution (F28), plink-first with host-key trust-on-first-use (F27/F29), a successful login (`AuthStatus: Success`), and a wrong password failing cleanly - the CSV filename change (F26) was also confirmed live in the same pass. Not yet confirmed live: the actual Windows SMB (`New-SmbMapping`) auth attempt, the PS7 SSH transport path's own success case (it's documented to time out on password auth and plink is now tried first, so this may never need separate confirmation), the `Safe`/`Username`/`PasswordSource` output columns (F22) against a real vault-backed lookup (the live test above supplied the password directly, not via vault lookup), F52's new `AdditionalPorts` field, and F86's `Safe` input / `Note` column |


## 2. Testing_Checklist-Self-Hosted.md: per-action checklist

### Auth (see the Self-Hosted Auth section of Testing_Manual-Integration-Procedures.md for the full A01-A18 procedures)
- [ ] All 8 auth methods: CyberArk, LDAP, RADIUS, Shared, PKI, PKIPN, SAML, OIDC
- [ ] Token save/load/refresh/keepalive/logoff lifecycle

### Accounts (19 actions)
- [x] ListDependents · [x] ListAllDependents · [x] GetDependent · [x] AddDependent · [x] UpdateDependent · [x] DeleteDependent
      (**confirmed live 2026-10-11** on master 49_3 with a disposable SchedTask dependent, since deleted) ·
      [ ] SyncDependent · [ ] ResumeDependent (both make the CPM act on the target; use a disposable machine)
- [x] ListDiscovered (endpoint, 2026-10-11: 200, Pending list empty) · [x] ListOnboardingPlatforms (**confirmed live 2026-10-11**) ·
      [ ] GetDiscovered · [ ] OnboardDiscovered · [ ] DeleteDiscovered: need a pending account. Run a discovery scan (or add one
      to the Pending list) first, then Get it, Onboard one with ShouldReconcileAccount blank, and Delete another
- [ ] RetrieveSshKey (PVWA 11.5): on an SSH key account, check the `.key` file in the Output Folder opens in an SSH client, and that the log and results CSV hold only the path. Also try a platform that requires a Reason / ticket
- [ ] RequestJitAccess · [ ] RevokeJitAccess (PVWA 10.6 / 12.0): 2026-10-10 both endpoints answered
      for a Vault user with HTTP 403 PASWS211E / PASWS293E ("non-LDAP user"), shown with the code. A
      real grant needs a profile that logs on as an LDAP user, and a Windows account on a platform that
      allows ad hoc access; check the user lands in local Administrators, then Revoke removes it
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
- [x] Account identifiers (F72, LT-ACCOUNTS-01): a CSV run finds the account by `AccountID` alone, by `AccountName` (object name, not username), by an `ObjectName` column, and by a unique `UserName`; a shared `UserName` and an `AccountName` that is only a username both fail the row without calling the action endpoint. **Confirmed live 2026-10-09** (PS 5.1 and PS 7, `Get` and `Reconcile -WhatIf`, in a safe whose name has a space): AccountID, AccountName, ObjectName and unique UserName rows all resolved to the same account, and the username-in-AccountName row failed with "No account with AccountName ... found"; exit code 2. The shared-UserName row passed the same day against two disposable accounts created for it (and deleted afterwards): it failed with "2 accounts with UserName ... found" and Reconcile sent nothing for it, while adding AccountName narrowed it to the right account.
- [x] Driver script `Invoke-AutomationWithCredential.ps1` (LT-DRIVER-01): **confirmed live 2026-10-10** (PS 5.1, CP source) - `-ResolveOnly`, a run on an expired session, and a cold start with the saved token moved aside all exited 0; the new saved session held no credential.
- [x] Job files and the detail CSV (LT-JOB-01): **confirmed live 2026-10-10** (PS 5.1, through the driver script) - three steps on one login, exit codes 0/0/2 and overall 2; the detail CSV kept every Get Safe column and the failed row's error.

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
- [x] Add Safe From Template (F74): an additional member added with SearchIn = an LDAP directory and one with Vault are both added; and with a template safe that has a CPM, picking that same CPM creates the safe without a member-copy error (the CPM member is not copied). **Confirmed live 2026-10-09** (LT-SAFES-01, PS 5.1): picking the template's CPM gave no error and logged the skip, the CPM appeared once, and a Vault member and an LDAP member were added with their role's permissions; the test safe was then deleted.
- [ ] SearchIn picker (F76): in interactive Add Safe Member, Add Safe Member From Template Role and Add Safe From Template, the picker lists the lab's LDAP directory after Vault (from `/api/settings/AddSafeMember`, or from GetDirectoryServices if that returns 404), and a member added with it succeeds. The log's DEBUG lines show which source answered.
- [x] Update Safe and AutoPurgeEnabled (F77): **confirmed live 2026-10-09** - CyberArk ignores AutoPurgeEnabled on update (the PUT succeeded and it stayed false); Update Safe no longer offers it and warns when a CSV supplies it.

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
- [ ] List Safe Members filters (not live-tested): `MemberType` = Group returns only groups, `MembershipExpired` = true/false splits expired and current members, `Sort` = desc reverses the name order, and no HTTP 400 retry appears in the log.
- [ ] F85 - with the full CSV template (every permission column present): Add and Update with a
      `PermissionRole` use the preset; with `PermissionRole` blank, the filled columns apply. Update:
      blank columns and a blank `ExpirationDate` keep the member's current values, `None` removes the
      expiration, and a row with only `ExpirationDate` changes only the expiration. Add: a row with no
      role and no permission values fails. UpdateFromTemplateRole: a blank `ExpirationDate` keeps it
- [x] F93 - ExpirationDate is sent as Unix seconds: **confirmed live 2026-10-10** - Add with `2027-01-31` succeeded (it was HTTP 400 PASWS167E before the fix) and List showed `2027-01-31 00:00`; Update with a new role and a blank `ExpirationDate` kept the date; Update with `None` removed it. AddFromTemplateRole and UpdateFromTemplateRole use the same helper but weren't run live.
- [x] List Safe Members shows predefined users and groups (F78): **confirmed live 2026-10-09** - Master, Batch, Backup Users, Auditors, Operators, DR Users and Notification Engines listed with `IsPredefinedUser` = True.

### Platforms (10 actions)
- [x] Get (**confirmed live 2026-09-21**, `WinDesktopLocal`) ·
      [x] List (confirm F06 field-fallback fix and the new `SystemType` filter — **confirmed
      2026-09-02**, re-confirmed 2026-09-21: 20 platforms) ·
      [ ] List with `PlatformType` = Group, then Regular (not live-tested) ·
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

### Users (11 actions)
- [x] Get (**confirmed live 2026-09-21**, UserID 90 - `Company_Automation_User` itself) ·
      [x] List (**confirmed 2026-09-02**, re-confirmed 2026-09-21: 38 users)
- [x] Add, Update, Disable, Enable, Unblock, ResetPassword, Delete: **confirmed live 2026-10-10** on a
      disposable user, run as a job file. The password never appeared in the log or a CSV. Update
      (Description, FirstName, ExpiryDate only) kept LastName, BusinessEmail and ChangePassOnNextLogon.
      Unblock succeeded on a user that wasn't suspended. A Get after Delete returned 404 PASWS261E.
- [x] Get shows Email, Enabled, Suspended, Description, Location, ExpiryDate (F94, **confirmed live
      2026-10-10**): Email from BusinessEmail, ExpiryDate 2027-12-31 after Update, Enabled
      True → False after Disable → True after Enable
- [x] List pages with `pageSize`/`pageOffset` (F95, **confirmed live 2026-10-10**): with a profile page
      size of 5, 8 requests returned all 39 users with no duplicates
- [ ] AddAuthMethod · [ ] RemoveAuthMethod (Bulk endpoint, PVWA 14.6): 2026-10-10 the PATCH reached
      the API, but `radius` was rejected with HTTP 400 PASWS347E (only external, non-Vault method IDs
      are valid). Rerun with an ID from `/api/Configuration/AuthenticationMethods` that is enabled in the lab.
- [ ] Username resolution with a username that is ambiguous in `?search=` (row must fail, not guess)

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
      disposable test application) · [x] AddAuthMethod `certificateattr` (**confirmed live 2026-10-06**:
      Subject-only and SAN-only methods added; the raw GET returned them, see
      `Reference_Lessons-Learned-CyberArk-API.md` §17) · [ ] ListAuthMethods / DeleteAuthMethod
      picker show the certificateattr Subject/Issuer/SAN columns (added after that run) · [ ] AddAuthMethod `certificateattr` with an `RFC822 Name=` SAN entry (spelling taken from CyberArk docs, not yet confirmed live) · [x] Delete (**confirmed live 2026-09-21** - cleaned up
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

### Reports (2 actions — Self-Hosted only, see caution section)
- [ ] List shows rows on PVWA 14.6+ with `Safe`, `Location`, `FileName`, `Status` and `CreatedAt` filled in (F91, the 14.6 `reports` response shape; not live-tested)
- [ ] Export (not live-tested; needs a user with Reports access and a generated report): by `ReportName` as Excel and as CSV, files open correctly in the Output Folder; a name with no match and a name shared by two reports both fail cleanly; by `ReportID` (only if a report ID can be found, since the 14.6 list response has no ID field); WhatIf saves nothing
- [x] List (confirm F04 sparse-field guards against a real report with missing fields, if any
      exist — **confirmed 2026-09-02**, Self-Hosted only. Also confirmed 2026-09-02 that this
      endpoint 404s on ISPSS/Privilege Cloud — `SupportedSystems` reverted to Self-Hosted-only,
      reversing Phase 1's dual-use expansion. **Re-tested 2026-09-21 with the `Company_Automation_User`
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
- [ ] F86 - TestConnectivity with Password blank: when several vault accounts match Address +
      Account, the output `Note` column gives the count and the safe used; with `Safe` set, only that
      safe is searched and a single match leaves `Note` blank

### Driver-level (Manage-Privilege.ps1)
- [ ] D01-D25 (see Manage-Privilege.ps1 manual test procedures in [Testing_Manual-Integration-Procedures.md](Testing_Manual-Integration-Procedures.md), including new D23-D25)
- [ ] D26-D36 (profile backup/restore, `-StartProfile`/`-AutoConnect` startup)
- [x] D37-D40 (automation mode - `-Category`/`-Action`, a non-interactive host, a token-less/never-silently-refreshable profile, and the two known interactive-touchpoint guards. **Confirmed live 2026-09-21**: dozens of real `-Category`/`-Action` invocations against a real Self-Hosted PVWA via `powershell.exe` from a non-interactive host, covering nearly every module action - see K15/F65 and the Accounts/Safes/SafeMembers/Groups/Platforms/Applications/Custom checklist entries above for specifics. This same pass is what found and fixed K15 - multiple SEQUENTIAL automation-mode runs against one saved session now work correctly)
- [ ] D41 (automation mode - `-OutputFolder`/`-FilenameFormat` overrides, for both a single-file export and Export All's multi-file output)
- [ ] D42 (Custom export tools' date-free filenames overwrite on each run - all 4 non-ExportAll modules)
- [ ] D43 (K06 fix - automation mode's `-NoPrompt` guard and the stored `.autocred` fallback)
- [ ] D44 (K04 fix - a profile's edited Base URL forces a fresh login instead of reusing a stale token)
- [ ] D45 (K07 fix - the profile Username fallback in Invoke-TokenRefresh's SelfHosted branch)
- [ ] D46 (K11 fix - the WebView2AssemblyPath profile field actually recovers a missing-DLL error)
- [ ] F70/F71 (PS 7 and PS 5.1) - Export All: Reports/List is not run and Master Policy is; a sub-report that fails shows as a Failed row with its ErrorCode, the run continues, and no re-login happens; with the token revoked mid-run, the run stops at the first 401 and re-authenticates
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

## 3. Testing_Checklist-ISPSS.md: setup steps and per-action checklist

### Step 1 — Profile setup

- [ ] Create or select a profile; set **System Type = `[1] Privilege Cloud`**.
- [ ] Set **Auth Method = `[2] Interactive`** or **`[3] SSO`** (not `[1] ClientCredentials`, for the
      reason above).
- [ ] Enter the tenant's **Privilege Cloud Subdomain** (the `acme` in
      `acme.privilegecloud.cyberark.cloud`); confirm `Tenant Portal`/`Tenant Vault` are derived
      correctly and `Discovering identity URL...` resolves to a real `Tenant Auth` value (`AI07`) —
      or falls back cleanly with a `WARN` if discovery fails (`AI08`).

### Step 2 — Authentication (see the ISPSS Auth section of Testing_Manual-Integration-Procedures.md for full AI01-AI12 procedures)

- [ ] `AI02`/`AI03`/`AI04`/`AI05` — whichever `Interactive` challenge shape(s) the tenant is
      configured for (single-factor, MFA mechanism picker, OOB push, or external IdP redirect)
- [ ] `AI06` — `SSO`, if also configured for this tenant
- [ ] `AI09`/`AI10`/`AI11` — re-authentication path for whichever method was used above (let a
      session run long enough to trigger this, or force it by manually expiring/deleting the saved
      token)
- [ ] `AI12` — session-timeout-endpoint 404 fallback (see the expected-behavior note above)

### Step 3 — Driver-level ISPSS-specific checks

- [ ] `D18` — confirm `Platforms/Rename`, `Policies/SetMasterPolicy`, `Reports/List` and `Reports/Export` are **all
      absent** from this profile's category menus (Self-Hosted-only, hidden for ISPSS)
- [ ] Profile list / header display correctly shows `Privilege Cloud` as the System Type
- [ ] WhatIf mode toggled on for this profile — confirm write suppression works identically to
      Self-Hosted

### Accounts (19 actions, all dual-use)

- Dependent and Discovered account actions are Self-Hosted only for now (ISPSS paths from psPAS differ and are unconfirmed)
- [ ] RequestJitAccess · [ ] RevokeJitAccess · [ ] RetrieveSshKey (ISPSS support is from psPAS only; no local ISPSS doc covers them)
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
- [ ] Account identifiers (F72, LT-ACCOUNTS-01): a CSV run finds the account by `AccountID` alone, by `AccountName` (object name, not username), by an `ObjectName` column, and by a unique `UserName`; a shared `UserName` and an `AccountName` that is only a username both fail the row without calling the action endpoint.
- [ ] Driver script `Invoke-AutomationWithCredential.ps1` (LT-DRIVER-01): a ClientCredentials profile (username = client ID, password = secret) and an Interactive profile without MFA both log in fresh with no saved session.
- [ ] Job files (LT-JOB-01): a multi-step job logs in once (watch the CyberArk Identity rate limit) and each step's exit code is right.

### Safes (8 actions, all dual-use)

- [ ] Add (confirm the `Get-CpmOptions` live CPM query populates the picker on ISPSS, and that it
      falls back to the profile's `CPM_List` if the query fails) ·
      [ ] AddFromTemplate · [ ] AssignCPM (confirm `GET /API/Users?userType=CPM&componentUser=true`
      returns the expected CPM accounts on ISPSS) · [ ] Delete · [ ] Get ·
      [x] List (**confirmed live 2026-09-21**: 29 safes) ·
      [ ] UnassignCPM · [ ] Update
- [ ] This session's `SafeName` validation (length/reserved-characters/leading-whitespace — Finding
      F44) is unit-tested only; confirm it doesn't reject a legitimately-valid ISPSS safe name.
- [ ] Add Safe From Template (F74): an additional member added with SearchIn = an LDAP directory and one with Vault are both added; and with a template safe that has a CPM, picking that same CPM creates the safe without a member-copy error (the CPM member is not copied).
- [ ] SearchIn picker (F76/K20): the interactive picker lists the tenant's Identity directories after Vault, with their GUID as the value, and an LDAP member added with one succeeds. Before F76 it likely offered Vault only.
- [ ] Update Safe and AutoPurgeEnabled (F77): confirm a CSV value logs the warning and the safe's AutoPurge is unchanged.

### SafeMembers (6 actions, all dual-use)

- [ ] Add (confirm the `SearchIn` directory picker — `GET /API/Configuration/LDAP/Directories` —
      against ISPSS; unconfirmed on any live tenant as of this writing) ·
      [ ] AddFromTemplateRole · [ ] List · [ ] Remove · [ ] Update · [ ] UpdateFromTemplateRole
- [ ] F85 - with the full CSV template (every permission column present): Add and Update with a
      `PermissionRole` use the preset; with `PermissionRole` blank, the filled columns apply. Update:
      blank columns and a blank `ExpirationDate` keep the member's current values, `None` removes the
      expiration, and a row with only `ExpirationDate` changes only the expiration. Add: a row with no
      role and no permission values fails. UpdateFromTemplateRole: a blank `ExpirationDate` keeps it
- [ ] Confirm all four permission-role presets (`ReadOnlyStrict`, `EndUser`, `PowerUser`,
      `SafeManager` — renamed from `ReadOnly` this session, Finding F47) produce the correct
      permission set on Add and Update.
- [ ] List Safe Members filters (not live-tested): confirm `MemberType`, `MembershipExpired` and `Sort` are accepted on ISPSS (no HTTP 400 retry in the log) and filter as on Self-Hosted.
- [ ] List Safe Members shows predefined users and groups (F78): confirm the `includePredefinedUsers` filter is accepted on ISPSS (no HTTP 400 retry in the log) and which predefined members appear.

### Platforms (9 of 10 actions — `Rename` is Self-Hosted only, excluded)

- [ ] Get (confirm field-shape handling — `id` vs `PlatformID`, `general`-nested vs root — on
      ISPSS, unconfirmed) ·
      [x] List (same field-shape note - **confirmed live 2026-09-21**: 39 platforms, no field-shape
      issue observed) · [ ] List with `PlatformType` = Group / Regular (not live-tested; confirm
      ISPSS accepts the parameter) · [ ] Copy · [ ] Disable · [ ] Enable ·
      [x] Export (confirmed live on Self-Hosted only, for the `PlatformID` variant — **confirmed
      live 2026-09-21** for that same variant on ISPSS too, via `Custom/ExportPlatformDetails`:
      14/14 platforms succeeded) · [ ] Import · [ ] Remove (destructive — disposable sandbox
      platform only) · [ ] SetPSMConfig

### Policies (1 of 2 actions — `SetMasterPolicy` is Self-Hosted only, excluded)

- [x] GetMasterPolicy — **already confirmed (2026-09-04)**: no Master Policy equivalent exists on
      ISPSS; returns a clean, non-fatal `Failure`. **Re-confirmed live 2026-09-21**: clean `HTTP
      404`, handled as a non-fatal item within `Custom/ExportAll` (8/8 modules still reported
      success overall). No further action needed.

### Users (5 actions on ISPSS)

- [ ] Get · [x] List (**confirmed live 2026-09-21**: 40 users)
- [ ] Delete · [ ] Unblock · [ ] ResetPassword: declared dual-use because CyberArk's own Privilege
      Cloud tools call these endpoints on a tenant. Test on a Vault-local (non-Identity) test user only.
      Add, Update, Enable, Disable and the AuthMethod actions are Self-Hosted only and must not
      appear on the ISPSS menu.

### Groups (7 actions, dual-use — see the `GroupType='Vault'` note above)

- [ ] Add · [ ] AddMember (fixed and confirmed live on Self-Hosted this session — F42; ISPSS
      unconfirmed) · [ ] Delete · [ ] GetMembers (same — F43, Self-Hosted confirmed only) ·
      [x] List (**confirmed live 2026-09-21**: 70 groups; expect the `GroupType` filter to be
      unusable — see the known-behavior note above, not a bug to report) · [ ] RemoveMember ·
      [ ] Update

### Applications (7 actions, dual-use — only menu visibility has been confirmed on ISPSS so far)

- [ ] Add (menu visibility confirmed 2026-09-02; this session's new validation hardening — F45 — is
      unconfirmed on any live tenant) · [ ] AddAuthMethod (include a `certificateattr` method, new
      2026-10-06) · [ ] Delete · [ ] DeleteAuthMethod ·
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
- [ ] F86 - TestConnectivity with Password blank: when several vault accounts match Address +
      Account, the output `Note` column gives the count and the safe used; with `Safe` set, only that
      safe is searched and a single match leaves `Note` blank

- [ ] F70/F71 (PS 7 and PS 5.1) - Export All no longer runs `Policies/GetMasterPolicy`; running Get Master
      Policy directly returns a real 404 (not StatusCode 0) and no re-login; with the token expired mid-run,
      Export All's `GET /API/Safes?limit=1` re-check returns 401 and the run stops and re-authenticates

