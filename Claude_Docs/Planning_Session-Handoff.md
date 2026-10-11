# aPePAS: Session Handoff (2026-10-10)

> **Stage: Planning.** Picks up the work queue from the session that ended 2026-10-10. Work through the numbered items, using the same numbers as the user did. When an item is done, delete it here and record it where CLAUDE.md's docs table says to. Delete this file once it's empty, or rename it `Archive_Planning_Session-Handoff.md` if it still has history worth keeping.

## 1. Where things stand

| Item | State |
|---|---|
| `main` | `8e92bb2` (PRs #42 to #47 merged, through F93) |
| Branch `2026-10-10-users-fixes` | Items 8 to 10 done (F94 Users email and columns, F95 `/api/Users` paging names, F96 `-PageSize 0` on single-resource GETs), confirmed live 2026-10-10. Pushed, no PR yet |
| Unit suite | 100% on `2026-10-10-users-fixes`: pwsh 1628 passed / 5 skipped, Windows PowerShell 5.1 1633 passed |
| Highest IDs | Finding **F96**, Known Issue **K20**, lessons CyberArk-API **§22**. Unit tests: CyberArkComms **C74**, UsersGet UG25, UsersList UL24 (per-module `-PageSize 0` tests added to 19 more files) |
| Live lab objects | Nothing left over from the 2026-10-10 runs (safe `aPePAS-LT-Exp` and users `aPePAS-LT-User1` and `aPePAS-LT-User2` were deleted). The permanent fixtures are listed in `Live-Testing.local.md` |
| Stale remote branches | `origin/2026-09-25-fix-ps7-http-errors` and `origin/2026-09-25-scrub-lab-values` are already in `main` (the one extra commit, 93b5f9a, landed as 681186b via PR #30). Deleting them was blocked for Claude, so **the user deletes them**: `git push origin --delete 2026-09-25-fix-ps7-http-errors 2026-09-25-scrub-lab-values` |

## 2. Work queue (approved by the user, 2026-10-10)

Create a topic branch from `main` for each item, or group items 8 to 10 on one Users branch. Commit, push and open a PR only when the user asks.

### 7. Live-test Users AddAuthMethod / RemoveAuthMethod with the lab's LDAP/AD method
- 2026-10-10: the PATCH to the Bulk endpoint reached the API, but `radius` got HTTP 400 PASWS347E ("only external non-Vault authentication methods can be provided").
- The user says the lab's external method is **LDAP/AD**. The exact method **ID** hasn't been confirmed. Try `ldap`; if that also gets PASWS347E, ask the user for the ID as configured in the PVWA. Don't guess further.
- Use a disposable user in a job file (Add, AddAuthMethod, Get, RemoveAuthMethod, Delete), then update `Testing_Plan.md`, `Testing_Checklist-Self-Hosted.md` (Users) and `Live-Testing.local.md`.
- Still unknown: what the Bulk endpoint returns on success (the module's response handling hasn't been seen live).

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
