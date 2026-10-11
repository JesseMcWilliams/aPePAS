# aPePAS: Session Handoff (2026-10-10)

> **Stage: Planning.** Picks up the work queue from the session that ended 2026-10-10. Work through the numbered items, using the same numbers as the user did. When an item is done, delete it here and record it where CLAUDE.md's docs table says to. Delete this file once it's empty, or rename it `Archive_Planning_Session-Handoff.md` if it still has history worth keeping.

## 1. Where things stand

| Item | State |
|---|---|
| `main` | `7b6cbaf` (PRs #42 to #46 merged: idle timeout, job files, detail CSV, Safe Member rules, Reports/Export, nine Users actions, F84 to F92) |
| PR #47 `2026-10-10-fix-member-expiration` | **Open, not merged.** F93: Safe Member `ExpirationDate` is sent as Unix seconds. It also holds this handoff file. Merge only when the user asks |
| Unit suite | 100% on PR #47: pwsh 1597 passed / 5 skipped, Windows PowerShell 5.1 1602 passed |
| Highest IDs | Finding **F93**, Known Issue **K20**, lessons CyberArk-API **§21**. Unit tests: CyberArkComms **C71**, SafeMembersAdd MA40, AddFromTemplateRole ATR25, Update MU33, UpdateFromTemplateRole UTR28 |
| Live lab objects | Nothing left over from the 2026-10-10 runs (safe `aPePAS-LT-Exp` and user `aPePAS-LT-User1` were deleted). The permanent fixtures are listed in `Live-Testing.local.md` |
| Stale remote branches | `origin/2026-09-25-fix-ps7-http-errors` and `origin/2026-09-25-scrub-lab-values` are already in `main` (the one extra commit, 93b5f9a, landed as 681186b via PR #30). Deleting them was blocked for Claude, so **the user deletes them**: `git push origin --delete 2026-09-25-fix-ps7-http-errors 2026-09-25-scrub-lab-values` |

## 2. Work queue (approved by the user, 2026-10-10)

Create a topic branch from `main` for each item, or group items 8 to 10 on one Users branch. Commit, push and open a PR only when the user asks.

### 7. Live-test Users AddAuthMethod / RemoveAuthMethod with the lab's LDAP/AD method
- 2026-10-10: the PATCH to the Bulk endpoint reached the API, but `radius` got HTTP 400 PASWS347E ("only external non-Vault authentication methods can be provided").
- The user says the lab's external method is **LDAP/AD**. The exact method **ID** hasn't been confirmed. Try `ldap`; if that also gets PASWS347E, ask the user for the ID as configured in the PVWA. Don't guess further.
- Use a disposable user in a job file (Add, AddAuthMethod, Get, RemoveAuthMethod, Delete), then update `Testing_Plan.md`, `Testing_Checklist-Self-Hosted.md` (Users) and `Live-Testing.local.md`.
- Still unknown: what the Bulk endpoint returns on success (the module's response handling hasn't been seen live).

### 8. Fix the Users email field (bug confirmed live)
- `APIModules/Users/Invoke-UsersGet.ps1` (about line 133) and `Invoke-UsersList.ps1` (about line 134) read `personalDetails.email`. Neither 14.6 model has that field, so `Email` is always blank.
- Get (`GET /api/Users/{id}` returns `User`): read `internet.businessEmail`.
- List (`GET /api/Users` returns `UserSummary`): `UserSummary` has **no** email field (its `personalDetails` is `BaseUserPersonalDetails`: department, firstName, lastName, middleName, organization). The endpoint takes `extendedDetails` (boolean). Check in the Swagger or live whether that adds `internet`. If it doesn't, drop the List `Email` column or fill it from per-user GETs (one call per user, which is costly).
- New `F94` row, unit tests, `Planning_User-Docs-Backlog.md` line.

### 9. Add columns to Users Get
- The output has 8 columns today. Add `Enabled` (`enableUser`), `Suspended` (`suspended`), `Description`, `Location`, `ExpiryDate` (`expiryDate`, a Unix time; show it with `ConvertFrom-CyberArkExpirationTime`). All are in the 14.6 `User` model.
- This also closes the two gaps from the 2026-10-10 live run: the Enabled flag after Disable and the stored ExpiryDate after Update were never checked. Re-check both live afterwards.

### 10. Single-resource GETs still send `offset`/`limit`
- Seen live: `GET /API/Safes/{name}?offset=0&limit=1000` and `GET /API/Users/{id}?offset=0&limit=1000`. It's harmless, but those calls should pass `-PageSize 0` (the F90 fix, see `Reports/Invoke-ReportsExport.ps1` about line 227).
- Audit every single-item GET (Get modules, the member GET in SafeMembers Update and UpdateFromTemplateRole, Users lookups by ID) and add `-PageSize 0`. Add a unit test per module asserting that no `limit` is sent.
- Related check: `/api/Users` (List) pages with **`pageOffset`/`pageSize`** in the 14.6 Swagger, not `offset`/`limit`. Confirm that List paging works past one page (the lab has fewer than 100 users, so look at the code path and the unit tests).

### 11. Accounts gaps (item 23: psPAS gap backlog)
- From `Planning_psPAS-Gap-Backlog.md`: Dependent Accounts, Discovered/Discovered-Local Accounts (onboarding), Personal Admin Accounts, Just-In-Time Access, SSH key retrieval. The user approved starting this ("23. Work on this", "11. Yes").
- The backlog says to confirm a real use case for each before building. Start by checking the 14.6 Swagger and `C:\Code\References\pspas.8.0.20\Functions\` for each area's endpoints and minimum version. Then give the user a short numbered proposal (what each action would do, Self-Hosted vs ISPSS, the version gate) and let them choose the order.
- Follow `Reference_API-Module-Guide.md` "New Module Checklist", use the 404 fallback for version-gated endpoints, and keep menus alphabetical with List first.

## 3. Other open items (not yet approved as work)
- Add `LT-*` definitions to `Testing_Live-Test-Definitions.md` for the 2026-10-10 ad-hoc runs: the Safe Member expiration rules (F85/F93) and the Users write lifecycle. They're recorded as "(unlabeled)" rows in `Live-Testing.local.md`.
- AddFromTemplateRole and UpdateFromTemplateRole expiration (F93) are unit-tested only, not live.
- Unverified agent claims from the Users/Reports work: Users ISPSS support is inferred; Reports `ReportID` origin and the export `Content-Type`; the SafeMembers List `sort` format; `PlatformType` filter on ISPSS. ISPSS live testing hasn't started (`LT-SETUP-01` ISPSS: no saved token yet).

## 4. Working notes that saved time
- **Live testing:** run a job file through the credential driver on PS 5.1. The command form is in `Testing_Live-Test-Definitions.md` (`Invoke-AutomationWithCredential.ps1 -ProfileName '{Profile}' -JobFile ...`). Give each step its own `OutputFolder` (for example `out/3`) so same-named CSVs don't overwrite each other. Write folder paths with forward slashes, because a `\` in JSON needs escaping. Write actions with `ProducesOutput = $false` (Disable, Enable, Unblock, ResetPassword, Delete, Remove) write no CSV, so check the log.
- **Editing:** use the Edit tool for code. `sed -i` once stripped CRLF, and regex scripts through Bash quoting broke files twice. For anything multi-line, write a `.ps1` to the scratchpad and run it with `-File`. After editing, check that `.ps1`/`.psm1` files still have a BOM and CRLF, and that they parse.
- **Swagger:** read it with `ConvertFrom-Json -AsHashtable` (it has keys that differ only by case).
- **Tool guards:** command text containing `Remove-Item` is blocked, and `rm -rf "$VAR"/*` is blocked (use a literal path). `git push --delete` is blocked for Claude.
