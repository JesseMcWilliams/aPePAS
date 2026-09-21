# aPePAS Improvement Plan

Derived from the 2026-09-02 psPAS comparison review. Organized as phases in priority order — earlier phases are higher-impact or lower-effort (or both) than later ones. Each item names the files involved, what changes, and whether it needs a live-tenant check before or instead of a code change.

## Phase 0 — Credential-exposure fix (do first)

This is the one finding that showed up independently across Auth, Accounts, Applications, and Safes/SafeMembers, and it's a small, mechanical change with real security payoff.

**Encode request bodies as bytes before the web call.** In `Modules\CyberArkComms.psm1`, `Invoke-CyberArkAPI` currently assigns `$bodyString` (a plain string from `ConvertTo-Json`) straight to `$iwrParams['Body']`. Change this to `$iwrParams['Body'] = [System.Text.Encoding]::UTF8.GetBytes($bodyString)` right before the `Invoke-WebRequest @iwrParams` call, mirroring psPAS's `Invoke-PASRestMethod.ps1`. This one change protects every write call across every API module, since they all route through this function.

**Apply the same fix to the three Auth call sites that bypass Comms.** `CyberArk.Auth.SelfHosted.psm1`'s `Invoke-PVWALogon` (used by CyberArk/LDAP/RADIUS/PKI/PKIPN logon — the vault password itself is in this body) and `CyberArk.Auth.ISPSS.psm1`'s `Invoke-ISPSSClientCredentials` and `Invoke-IdentityAdvancedAuth` (OAuth client secret and MFA answers) all call `Invoke-RestMethod`/`Invoke-WebRequest` directly with a string `-Body`. Apply the identical byte-encoding change at each of these three call sites.

**Add `AuthValue` to the log-masking pattern list.** `Modules\CyberArkLogging.psm1`'s `$script:SensitivePatterns` catches `password`/`secret`/`token`/`credential` keys but not `AuthValue`, so an Applications auth-method `hash` value is currently written unmasked to aPePAS's own DEBUG log even before the OS-logging issue applies. Add it to the pattern list alongside the existing keys.

Test impact: `Tests\Unit\CyberArkComms.Tests.ps1` likely asserts on `Invoke-WebRequest`'s `Body` parameter shape somewhere — update those assertions to expect a byte array rather than a string, and add a case confirming the byte array round-trips to the same JSON. Same for any Auth module unit tests that inspect the request body.

## Phase 1 — Verify-then-fix: endpoint and value-set mismatches

These all read as real discrepancies from the code alone, but each has two plausible explanations (aPePAS wrong, or psPAS reflects an older/different API version) that only a live-tenant call can resolve. Test each against a real environment before changing code, since "fixing" toward the wrong side would break something that currently works.

- `Invoke-AccountsCancelCpmTask.ps1` posts to `/API/Accounts/{id}/StopImmediateAutoMgmtOperations`; psPAS's `Stop-PASCPMTask.ps1` posts to `/API/Accounts/{id}/Cancel/`. Every sibling CPM endpoint (`/Change`, `/Reconcile`) matches psPAS exactly, which makes this one divergence worth resolving rather than leaving as-is.
- `Invoke-AccountsResumeAutoManagement.ps1` uses `PATCH /API/Accounts/{id}/`; psPAS's `Resume-PASCPMAutoManagement.ps1` uses `POST /API/Accounts/{id}/Resume/`. Likely equivalent outcomes, but worth standardizing on whichever is confirmed current.
- `Invoke-GroupsGetMembers.ps1` sends no query parameters; psPAS gates an `includeMembers` flag behind API v12.0 for the equivalent call. If that flag is actually required, `GetMembers` is silently returning empty results on some PVWA versions today — this one is worth prioritizing within this phase since a silent-empty-result bug is worse than a wrong-endpoint-path bug (which at least errors visibly).
- `Invoke-GroupsAddMember.ps1`/`Invoke-GroupsRemoveMember.ps1` default `MemberType` to `'EPVUser'`; psPAS validates the same field against `('domain','vault')` for the identical endpoint. Confirm current valid values against CyberArk docs and correct whichever side is stale.
- `Invoke-ApplicationsAdd.ps1` marks `Location` optional; psPAS marks it mandatory. Confirm against a live call and align.
- Reports is restricted to `SupportedSystems = @('SelfHosted')`; psPAS's `Get-PASReport` works against both self-hosted and ISPSS from v14.6+. Confirm whether the restriction is intentional; if not, it's a one-line change to open Reports up to ISPSS.

## Phase 2 — Platforms: close the scope gap

This is the largest single gap in the review, and it contradicts aPePAS's own README, which lists platform administration as a stated feature and describes the same CSV-driven Add/Update/Delete pattern already implemented for Safes, SafeMembers, Users, and Groups. Bring Platforms up to that same standard:

- `Invoke-PlatformsEnable.ps1` / `Invoke-PlatformsDisable.ps1` — `POST /API/Platforms/{id}/Activate` and `/Deactivate` (confirm exact paths against psPAS's `Enable-PASPlatform.ps1`/`Disable-PASPlatform.ps1`).
- `Invoke-PlatformsCopy.ps1`, `Invoke-PlatformsRename.ps1`, `Invoke-PlatformsRemove.ps1` — mirroring `Copy-`/`Rename-`/`Remove-PASPlatform.ps1`.
- `Invoke-PlatformsImport.ps1` / `Invoke-PlatformsExport.ps1` — platform ZIP import/export, mirroring `Import-`/`Export-PASPlatform.ps1`. This pair is the most valuable for day-to-day platform management (cloning a platform between environments) and worth doing early within this phase even if the others slip.
- `Invoke-PlatformsSetPSMConfig.ps1` — mirroring `Set-PASPlatformPSMConfig.ps1`.
- `Invoke-PlatformsGet.ps1` / `Invoke-PlatformsList.ps1` — add `SystemType` filtering and, if there's a real use case for it, the group/rotational-group/dependents views psPAS exposes. Lower priority than the write operations above.
- New area, `APIModules\Policies\`: `Invoke-PoliciesGetMasterPolicy.ps1` / `Invoke-PoliciesSetMasterPolicy.ps1` — `GET`/`PUT /API/Policies/{id}`, covering the 16 configurable flags (DualControl, MultiLevelApproval, RequireReason, PasswordChangeDays, RecordActivity, etc.) that psPAS's `Get-`/`Set-PASMasterPolicy.ps1` expose.

Each new module needs a matching `Tests\Unit\Invoke-*.Tests.ps1` file, following the existing 1:1 convention, and an entry in `Docs\Documentation-Tracker.md`/`Interfaces.md` alongside the rest of the API surface.

## Phase 3 — Validation hardening

Client-side validation that currently doesn't exist, so bad input reaches the server as a late, unclear error instead of failing fast with a useful message:

- `Invoke-SafesAdd.ps1` / `Invoke-SafesUpdate.ps1`: add SafeName length (0–28) and charset validation (reject `\ / : * < > " . |` and leading whitespace), matching psPAS's `Add-`/`Set-PASSafe.ps1`.
- `Invoke-ApplicationsAdd.ps1`: add range validation `[ValidateRange(0,23)]` on `AccessPermittedFrom`/`AccessPermittedTo`, and fix the comments/error text that currently mislabel these as "epoch seconds" — they're hour-of-day values per the module's own schema. Add length/charset checks on `AppID` (1–127, no `&`), `Description` (≤99), `BusinessOwnerFName` (≤29), `BusinessOwnerPhone` (≤24).

## Phase 4 — Engine robustness

**Generalize pagination collection detection.** `Invoke-CyberArkAPI` in `CyberArkComms.psm1` only accumulates paginated results when the response JSON exposes one of a hardcoded property list (`value`, `Safes`, `Members`, `Accounts`, `Users`, `Platforms`, `Groups`). Every endpoint in use today happens to match, so this hasn't caused a visible bug yet — but any new endpoint added in Phase 2 whose response uses a different collection name would silently return only page one with no error. Replace the fixed list with dynamic detection (the first array-valued property on the response object), similar in spirit to how psPAS's `Get-NextLink.ps1` discovers the collection generically. Do this before or alongside Phase 2's new Platforms/Policies endpoints so they're covered from the start rather than discovered as a bug later.

**Self-hosted session lifecycle.** `CyberArk.Auth.SelfHosted.psm1` never calls the PVWA logoff endpoint (`POST /API/Auth/Logoff`, per psPAS's `Close-PASSession.ps1`) on any of its password/Shared/PKI/PKIPN methods, so a concurrent-session slot stays occupied until natural timeout instead of being released when the tool finishes. Add a `Close-SelfHostedAuthToken` (or similar) function and call it from the driver's normal exit path.

**Replace the fixed 20-minute PVWA idle-timeout assumption.** `$script:PVWA_SESSION_EXPIRY_MIN = 20` in `CyberArk.Auth.SelfHosted.psm1` is a guess; the actual value is admin-configurable per environment. Call `GET /api/Settings/Timeout` right after a successful self-hosted logon (mirroring psPAS's `Get-PASSessionTimeout`) and use the returned value for `Expiry` instead of the hardcoded constant, falling back to 20 only if that call fails.

**Simplify ISPSS identity-tenant discovery.** `Resolve-IdentityTenantURL` in `CyberArk.Auth.ISPSS.psm1` probes three guessed candidate hostnames and inspects redirects. Replace this with a call to CyberArk's documented platform-discovery endpoint (`https://platform-discovery.cyberark.cloud/api/v2/services/subdomain/{subdomain}`, the same one psPAS's `Find-SharedServicesURL.ps1` and `New-PASSession`'s `ISPSS-Subdomain-*` path use), which returns the identity and pcloud URLs directly as structured JSON — removing the guess-and-redirect-chase logic entirely and the three-candidate list as a future maintenance point.

## Phase 5 — Documentation-only fixes

- Add a short callout in `README.md` or `Docs\Interfaces.md` next to the Safes role presets, noting that aPePAS's "ReadOnly" role (list/audit/view only) is *not* equivalent to PVWA's or psPAS's built-in "ReadOnly" role (which grants `retrieveAccounts`) — same name, different behavior, to head off a reasonable but wrong assumption from anyone porting intuition from PVWA itself.

## Backlog — confirm need before building

These are real capability gaps versus psPAS, but each represents a distinct CyberArk feature area that may be deliberately out of scope for aPePAS's purpose. Don't build any of these without confirming there's an actual use case first:

- Accounts: Dependent Accounts, Discovered/Discovered-Local Accounts (onboarding), Personal Admin Accounts, Just-In-Time Access, SSH key retrieval.
- Applications: `certificateattr` auth method type (Subject/Issuer/SubjectAlternativeName-based).
- SafeMembers: `Quota` support on Add/Update; server-side `sort`/`includeAccounts`/`useCache`/`memberType`/`membershipExpired` filters on Get/List (would reduce the current one-GET-per-safe pattern for full-tenant member audits).
- Users: create/update/enable/disable/unblock/password-reset/allowed-auth-method management (currently intentionally read-only).
- Reports: export (XLSX/CSV download), report-task scheduling, license reporting (currently intentionally list-only).

## Small fix, low priority

`Invoke-CustomExportAll.ps1`'s loop over List modules doesn't check a module result's `IsFatal` flag, so a 401 partway through keeps calling remaining endpoints instead of stopping early — `Invoke-CustomExportEntitlements.ps1` already does this correctly and is the pattern to copy.

## Suggested sequencing

Phase 0 is a same-day change with no design decisions required — do it first regardless of what else is prioritized. Phase 1's items are cheap to verify (a handful of live API calls) and should happen before Phase 2, since Phase 2 adds new endpoints in the same family (Platforms) where getting the path/parameter conventions right matters. Phase 4's pagination-detection generalization is worth pulling forward to run alongside Phase 2 rather than after it, so new Platforms/Policies endpoints don't need a second pass. Phases 3 and 5 can happen anytime in parallel with the others since they're independent, low-risk, and don't block anything. The Backlog items should stay parked until there's a stated need — building them speculatively would be scope creep against what looks like a deliberately-focused tool.
