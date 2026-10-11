# aPePAS: psPAS Gap Backlog

> **Stage: Planning.** Capability gaps versus psPAS that are not built. Carried over from the 2026-09-02 improvement plan (now [Archive_Planning_Improvement-Plan-2026-09-02.md](Archive_Planning_Improvement-Plan-2026-09-02.md)), whose other items are all done. Confirm there's a real use case before building any of these.

## Platforms: remaining Get/List scope

List has the `SystemType`, `PlatformType` (Regular/Group) and `Active` filters. Get takes one platform ID (`GET /API/Platforms/{id}` has no other parameters), so it needs no filters. Not built (they exist only as Export target types in `Invoke-PlatformsExport.ps1`):

- The group / rotational-group / dependents list views psPAS exposes (`/API/Platforms/Groups`, `/RotationalGroups`, `/Dependents`), and the `/API/Platforms/Targets` view with psPAS's PeriodicVerify/ManualChange/... filters. Build only if there's a real use case.

## Other gaps: confirm need before building

These are real capability gaps versus psPAS, but each represents a distinct CyberArk feature area that may be deliberately out of scope for aPePAS's purpose. Don't build any of these without confirming there's an actual use case first:

- Accounts: Dependent Accounts, Discovered/Discovered-Local Accounts (onboarding), Personal Admin Accounts, Just-In-Time Access, SSH key retrieval.
- SafeMembers: `Quota` support on Add/Update; `useCache` on List (in the 14.6 Swagger for the members GET, but psPAS sends it only for a single member's GET). List already has `memberType`/`membershipExpired`/`sort`; `includeAccounts` is a Safes GET parameter, not a members one.
- Users: create/update/enable/disable/unblock/password-reset/allowed-auth-method management (currently intentionally read-only).
- Reports: report-task scheduling (`/API/Tasks`, psPAS Get/New/Set/Remove-PASReportTask, PVWA 14.6+), report activity parameters (`/API/ReportParams/Activities`, PVWA 15.0+), Privilege Cloud license reporting (psPAS Get-PASUserLicenseReport, `{ApiURI}/API/licenses/pcloud/`), and List's search/filter/sort (psPAS asserts PVWA 15.0). Export (Excel/CSV download) is built.
