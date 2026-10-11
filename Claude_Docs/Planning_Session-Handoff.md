# aPePAS: Session Handoff (2026-10-11)

> **Stage: Planning.** Picks up the work queue from the session that ended 2026-10-11. Work through the numbered items, using the same numbers as the user did. When an item is done, delete it here and record it where CLAUDE.md's docs table says to. Delete this file once it's empty, or rename it `Archive_Planning_Session-Handoff.md` if it still has history worth keeping.

## 1. Where things stand

| Item | State |
|---|---|
| `main` | `8e92bb2` (PRs #42 to #47 merged, through F93) |
| PR #48 `2026-10-10-users-fixes` | **Open.** F94 to F96 (Users email and columns, `/api/Users` paging names, `-PageSize 0` on single-resource GETs), confirmed live. Merge only when the user asks |
| Branch `2026-10-10-accounts-gaps` (stacked on #48) | Item 11, not pushed: JIT Request/Revoke, Retrieve SSH Key, 5 Discovered (Pending) actions, 8 Dependent actions, plus the template `.gitignore` entries. Open its PR after #48 merges, so the diff shrinks to item 11 |
| Branch `2026-10-11-token-cost` (stacked on accounts-gaps) | Token review: `Tools/` scripts, `CLAUDE.md` docs-table trim and "File tools" / "Session habits" sections, README count removed, recommendations R9 to R16 in `Planning_Token-Usage-Recommendations.md`. Not pushed |
| Unit suite | 100% on accounts-gaps: pwsh 1829 passed / 5 skipped, Windows PowerShell 5.1 1834 passed. 93 modules |
| Highest IDs | Finding **F96**, Known Issue **K20**, lessons CyberArk-API **§24**, Pester **§18**. New test prefixes: RJ, VJ, SK, LD, GD, OD, DD, OP, DL, DW, DG, DA, DU, DX, DS, DR |
| Live lab objects | Nothing left over: users `aPePAS-LT-User1`/`User2` and dependent `49_7` were deleted. Dependent `49_6` on master `49_3` existed before and was left alone |
| Stale remote branches | `origin/2026-09-25-fix-ps7-http-errors` and `origin/2026-09-25-scrub-lab-values` are already in `main`. Deleting them is blocked for Claude, so **the user deletes them**: `git push origin --delete 2026-09-25-fix-ps7-http-errors 2026-09-25-scrub-lab-values` |

## 2. Work queue

### 7. Live-test Users AddAuthMethod / RemoveAuthMethod with the lab's LDAP/AD method
- 2026-10-10: `radius` got HTTP 400 PASWS347E. The lab's external method is LDAP/AD, ID unconfirmed. Try `ldap`; if that fails, ask the user for the ID. Don't guess further.
- Use a disposable user in a job file (Add, AddAuthMethod, Get, RemoveAuthMethod, Delete).

### 11. Accounts gaps: what's left
- Not live-tested: Retrieve SSH Key (needs an SSH key account; the lab has a `UnixSSHKeys` platform), JIT grant (needs a profile that logs on as an LDAP user), Get/Onboard/Delete Discovered (the Pending list is empty), Sync/Resume Dependent (the CPM would act on a real machine).
- Deferred by the user's order: 11.3 Discovered Local Accounts (ISPSS only) and 11.6 Personal Admin Accounts (path conflict between the Swagger and psPAS).

### 12. Token cost (R9, R10, R16 in `Planning_Token-Usage-Recommendations.md`)
- R9/R10 change Claude Code settings or connectors, so they're the user's call. R16 restructures the Testing docs.

## 3. Other open items (not yet approved as work)
- Add `LT-*` definitions to `Testing_Live-Test-Definitions.md` for the ad-hoc runs recorded as "(unlabeled)" in `Live-Testing.local.md` (2026-10-10 and 2026-10-11).
- AddFromTemplateRole and UpdateFromTemplateRole expiration (F93) are unit-tested only, not live.
- Unverified: Users ISPSS support; Reports `ReportID` origin and export `Content-Type`; SafeMembers List `sort` format; `PlatformType` filter on ISPSS. ISPSS live testing hasn't started.
- `SESSION-HANDOFF.local.md` (2026-09-25) in the repo root looks stale.

## 4. Working notes that saved time
- **Live testing:** run a job file through the credential driver on PS 5.1 (`Invoke-AutomationWithCredential.ps1 -ProfileName '{Profile}' -JobFile ...`). Give each step its own `OutputFolder` (`out/3`) and write paths with forward slashes. Actions with `ProducesOutput = $false` write no CSV, so check the log.
- **Files:** use `Tools/Repair-FileEncoding.ps1` and `Tools/Test-FileHygiene.ps1` (see `CLAUDE.md`). Don't build JSON or regex through bash quoting; write a `.ps1` to the scratchpad and run it with `-File`.
- **Swagger:** read it with `ConvertFrom-Json -AsHashtable` (keys differ only by case).
- **Tool guards:** command text containing `Remove-Item` is blocked, and `rm -rf "$VAR"/*` is blocked (use a literal path). `git push --delete` is blocked for Claude.
