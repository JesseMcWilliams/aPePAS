# aPePAS: psPAS Gap Backlog

> **Stage: Planning.** Capability gaps versus psPAS that are not built. Carried over from the 2026-09-02 improvement plan (now [Archive_Planning_Improvement-Plan-2026-09-02.md](Archive_Planning_Improvement-Plan-2026-09-02.md)), whose other items are all done. Confirm there's a real use case before building any of these.

## Platforms: remaining Get/List scope

List has the `SystemType`, `PlatformType` (Regular/Group) and `Active` filters. Get takes one platform ID (`GET /API/Platforms/{id}` has no other parameters), so it needs no filters. Not built (they exist only as Export target types in `Invoke-PlatformsExport.ps1`):

- The group / rotational-group / dependents list views psPAS exposes (`/API/Platforms/Groups`, `/RotationalGroups`, `/Dependents`), and the `/API/Platforms/Targets` view with psPAS's PeriodicVerify/ManualChange/... filters. Build only if there's a real use case.

## Other gaps: confirm need before building

These are real capability gaps versus psPAS, but each represents a distinct CyberArk feature area that may be deliberately out of scope for aPePAS's purpose. Don't build any of these without confirming there's an actual use case first:

- Accounts: see the research section below. The user approved building it on 2026-10-10, in the order JIT, Dependent Accounts, SSH key, Discovered (Self-Hosted).

## Accounts gaps: research (2026-10-10, local references only)

Sources: the 14.6 Swagger (SW), psPAS 8.0.20 `Functions\Accounts\` and `Functions\AccountsFeed\`. `C:\Code\References\CyberArk ISPSS\` documents **none** of these areas, so every ISPSS claim here comes from psPAS code only. Minimum versions come from psPAS `Assert-VersionRequirement`.

| # | Area / action | Endpoint | Min PVWA | Self-Hosted / ISPSS | Notes |
|---|---|---|---|---|---|
| 1 | JIT: Request (**built 2026-10-10**: Accounts / RequestJitAccess) | POST `/api/Accounts/{id}/GrantAdministrativeAccess`, no body | 10.6 | Both (psPAS) | Adds the caller to local Administrators on the target Windows machine. The platform must allow ad hoc access |
| 2 | JIT: Revoke (**built 2026-10-10**: Accounts / RevokeJitAccess) | POST `/api/Accounts/{id}/RevokeAdministrativeAccess`, no body | 12.0 | Both (psPAS) | |
| 3 | Dependents: List for one account (**built 2026-10-11**: ListDependents) | GET `/api/Accounts/{id}/DependentAccounts` (search, filter, failed) | 14.6 | Both. psPAS uses `account-dependents` on ISPSS | 404 fallback |
| 4 | Dependents: List across the Vault (**built 2026-10-11**: ListAllDependents; no master filter, PASWS357E) | GET `/api/DependentAccounts` (offset, limit, filter, includeDeleted, search) | 14.6 | Self-Hosted only (psPAS blocks ISPSS) | |
| 5 | Dependents: Get, Add, Update, Delete (**built 2026-10-11**) | `.../DependentAccounts[/{depId}]`. Add needs `platformId`. psPAS Update does GET + full PUT | 14.6 | Both (path differs on ISPSS) | Delete is destructive |
| 6 | Dependents: Sync, Resume (**built 2026-10-11**, single only, Self-Hosted only) | POST `.../{depId}/Sync`, `.../{depId}/Resume`. Sync bulk: `/api/Accounts/DependentAccounts/Sync/Bulk` | 14.6 (Resume bulk 15.0, not in SW) | psPAS keeps `dependentAccounts` on ISPSS, which conflicts with its CRUD path | |
| 7 | Dependents: Link/Unlink | Self-Hosted `/Link`, `/Unlink` (15.0, not in SW). ISPSS `/link-accounts` | 15.0 | Differs | Not planned: no local request shape |
| 8 | SSH key: Retrieve (**built 2026-10-11**: Accounts / RetrieveSshKey) | POST `/api/Accounts/{id}/Secret/Retrieve` (Reason, TicketingSystem, TicketId, Version, ActionType, isUse, Machine) | 11.5 | Both (psPAS) | Secret retrieval, audited. Keep the key out of logs and CSVs |
| 9 | Discovered (Pending): List, Get (**built 2026-10-11**: ListDiscovered, GetDiscovered) | GET `/api/DiscoveredAccounts[/{id}]` | 11.6 | Self-Hosted (SW). Unconfirmed on ISPSS | Needs Vault Admins or PVWAAccountsFeedAdmins |
| 10 | Discovered: Onboard (**built 2026-10-11**: OnboardDiscovered, single only) | POST `/api/DiscoveredAccounts/{id}/Onboard` (platformId, safeName required). Bulk `/Onboard/Bulk` (SW only) | 12.6 | Self-Hosted | Can carry `defaultPassword`. SW puts `allowAccountDuplications` here; psPAS puts it on POST `/DiscoveredAccounts` |
| 11 | Discovered: Delete (**built 2026-10-11**: DeleteDiscovered, by ID only; clear-all not offered) | DELETE `/{id}`, POST `/Delete/Bulk`; DELETE `/api/DiscoveredAccounts` clears all | 12.1 | Self-Hosted | Clear-all is destructive |
| 12 | Discovered: onboarding platforms (**built 2026-10-11**: ListOnboardingPlatforms) | GET `/api/DiscoveredAccounts/Platforms` (safeName, discoveryPlatformType required) | SW 14.6 | Self-Hosted | Not in psPAS |
| 13 | Discovered Local Accounts (ISPSS) | `{tenant}/api/discovered-accounts...` (about 10 actions) | n/a | ISPSS only | Deferred until ISPSS live testing starts |
| 14 | Personal Admin Account: Add | SW: POST `/api/Accounts/PersonalPrivilegedAccount`. psPAS: POST `/api/Accounts/PersonalAdminAccount`, PCloud only | ? | Conflict | Deferred: needs a live check first. No List/Get endpoint |
- SafeMembers: `Quota` support on Add/Update; `useCache` on List (in the 14.6 Swagger for the members GET, but psPAS sends it only for a single member's GET). List already has `memberType`/`membershipExpired`/`sort`; `includeAccounts` is a Safes GET parameter, not a members one.
- Reports: report-task scheduling (`/API/Tasks`, psPAS Get/New/Set/Remove-PASReportTask, PVWA 14.6+), report activity parameters (`/API/ReportParams/Activities`, PVWA 15.0+), Privilege Cloud license reporting (psPAS Get-PASUserLicenseReport, `{ApiURI}/API/licenses/pcloud/`), and List's search/filter/sort (psPAS asserts PVWA 15.0). Export (Excel/CSV download) is built.
