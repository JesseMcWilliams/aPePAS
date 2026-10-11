# Testing Plan

## Testing documents

| Document | Contents |
|---|---|
| [Testing_Findings-and-Known-Issues.md](Testing_Findings-and-Known-Issues.md) | Open findings (one-line index; closed detail is in `Archive_Testing_Findings-Closed.md`) and the known-issues / risk register. |
| [Testing_Unit-Test-Cases.md](Testing_Unit-Test-Cases.md) | Per-module unit test case IDs and expectations. |
| [Testing_Manual-Integration-Procedures.md](Testing_Manual-Integration-Procedures.md) | Step-by-step manual procedures for auth and the driver against a live PVWA / ISPSS tenant. |
| [Testing_Status.md](Testing_Status.md) | **The one place for test status:** unit and live (Self-Hosted and ISPSS) status per component, module action and cross-cutting check, plus the testing backlog. |
| [Testing_Live-Test-Definitions.md](Testing_Live-Test-Definitions.md) | Labeled, repeatable live tests (`LT-*`) with placeholders; `Live-Testing.local.md` supplies the values. |
| [Testing_Checklist-Self-Hosted.md](Testing_Checklist-Self-Hosted.md) | How to run a live pass on Self-Hosted PVWA (no status). |
| [Testing_Checklist-ISPSS.md](Testing_Checklist-ISPSS.md) | How to run a live pass on ISPSS / Privilege Cloud (no status). |
| [Archive_Testing_Status-Before-Merge.md](Archive_Testing_Status-Before-Merge.md) | The Component Test Matrix and per-action checklists as they were before the 2026-10-11 merge (archive, not read by default). |
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

- **SelfHosted-only (10 modules):** the six Users write actions with no Privilege Cloud reference
  (`Users/Add`, `Update`, `Enable`, `Disable`, `AddAuthMethod`, `RemoveAuthMethod`; Privilege Cloud
  manages most users in CyberArk Identity), `Platforms/Invoke-PlatformsRename.ps1` (confirmed via psPAS's
  explicit version/platform assertion — a PVWA 15.0+ feature), `Policies/Invoke-PoliciesSetMasterPolicy.ps1`
  (confirmed the same way, PVWA 14.6+ - and now doubly moot on ISPSS, since the user has verified
  live that no Master Policy equivalent exists there at all, per the note below),
  `Reports/Invoke-ReportsList.ps1` and `Reports/Invoke-ReportsExport.ps1` (same `/API/Reports` family; the download
  endpoints are in the Self-Hosted 14.6 Swagger only). These are hidden from the menu entirely for an ISPSS profile.
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
    live ISPSS tenant remains unverified (see [Testing_Status.md](Testing_Status.md)).
- **Dual-use (the remaining 67 of 77 total modules, across Accounts, Safes, SafeMembers, Platforms
  (9 of its 10 actions - only `Rename` is Self-Hosted-only), Applications, Users (Get, List,
  Delete, Unblock, ResetPassword), Groups, Custom,
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

## Test Status

Unit and live test status for every component, module action and cross-cutting check is in
[Testing_Status.md](Testing_Status.md), and only there (R16, 2026-10-11). The old Component Test Matrix
is archived verbatim in [Archive_Testing_Status-Before-Merge.md](Archive_Testing_Status-Before-Merge.md).

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
