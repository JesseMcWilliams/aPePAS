# aPePAS: psPAS Gap Backlog

> **Stage: Planning.** Capability gaps versus psPAS that are not built. Carried over from the 2026-09-02 improvement plan (now [Archive_Planning_Improvement-Plan-2026-09-02.md](Archive_Planning_Improvement-Plan-2026-09-02.md)), whose other items are all done. Confirm there's a real use case before building any of these.

## Platforms: remaining Get/List scope

List already has the `SystemType` filter. Get has none, and the views below were not built (they exist only as Export target types in `Invoke-PlatformsExport.ps1`).

- `Invoke-PlatformsGet.ps1` / `Invoke-PlatformsList.ps1` — add `SystemType` filtering and, if there's a real use case for it, the group/rotational-group/dependents views psPAS exposes. Lower priority than the write operations above.

## Other gaps: confirm need before building

These are real capability gaps versus psPAS, but each represents a distinct CyberArk feature area that may be deliberately out of scope for aPePAS's purpose. Don't build any of these without confirming there's an actual use case first:

- Accounts: Dependent Accounts, Discovered/Discovered-Local Accounts (onboarding), Personal Admin Accounts, Just-In-Time Access, SSH key retrieval.
- Applications: `certificateattr` auth method type (Subject/Issuer/SubjectAlternativeName-based).
- SafeMembers: `Quota` support on Add/Update; server-side `sort`/`includeAccounts`/`useCache`/`memberType`/`membershipExpired` filters on Get/List (would reduce the current one-GET-per-safe pattern for full-tenant member audits).
- Users: create/update/enable/disable/unblock/password-reset/allowed-auth-method management (currently intentionally read-only).
- Reports: export (XLSX/CSV download), report-task scheduling, license reporting (currently intentionally list-only).
