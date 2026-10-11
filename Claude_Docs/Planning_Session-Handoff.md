# aPePAS: Session Handoff (2026-10-11)

> **Stage: Planning.** Picks up the work queue from the session that ended 2026-10-11. Work through the numbered items, using the same numbers as the user did. When an item is done, delete it here and record it where CLAUDE.md's docs table says to. Delete this file once it's empty, or rename it `Archive_Planning_Session-Handoff.md` if it still has history worth keeping.

## 1. Where things stand

| Item | State |
|---|---|
| `main` | `75007fc` (PRs #42 to #51 merged: #48 is F94 to F96, #49 is the item 11 Accounts actions, #50 is the token review, #51 is a handoff update). No open PRs in aPePAS |
| aPeTemplate | PR #6 merged (`Tools/`, "File tools" / "Session habits" sections, `New-ClaudeTokenSettings.ps1`). PR #7 merged (`3a48127`): Git preference in `user-claude/CLAUDE.md` (merge deletes the branch) |
| Unit suite | 100% on branch `2026-10-11-authmethod-live` (2026-10-11): pwsh 1838 passed / 5 skipped, Windows PowerShell 5.1 1843 passed. 93 modules |
| Highest IDs | Finding **F98**, Known Issue **K21**, lessons CyberArk-API **§25**, Pester **§18**. New test prefixes: RJ, VJ, SK, LD, GD, OD, DD, OP, DL, DW, DG, DA, DU, DX, DS, DR |
| Live lab objects | Nothing left over. Account `30_25` was deleted 2026-10-11 through the classic v1 route (K21) and sits in the safe's 7-day retention. Deleted: users `aPePAS-LT-User1`/`User2`/`User3` and dependents `49_7`/`49_8`. Dependent `49_6` on master `49_3` existed before and was left alone |
| Claude settings | `.claude/settings.local.json` (gitignored) turns off all 11 synced plugins and the claude.ai connectors (R9/R10). To re-enable one, edit that file |
| Remote branches | Only `main` on origin in both repos (checked 2026-10-11). Merges use `gh pr merge <n> --merge --delete-branch` |

## 2. Work queue

### 11. Accounts gaps: what's left
- Live-tested 2026-10-11: Retrieve SSH Key (throwaway key), CheckIn, Sync/Resume Dependent. Still open: JIT grant (needs a profile that logs on as an LDAP user) and Get/Onboard/Delete Discovered (the Pending list is empty). See the Testing backlog in `Testing_Status.md`.
- Deferred by the user's order: 11.3 Discovered Local Accounts (ISPSS only) and 11.6 Personal Admin Accounts (path conflict between the Swagger and psPAS).

### 13. High-risk changes: each needs the user's explicit go-ahead
Done items (13.1-13.3, 13.5-13.9) were removed; the remaining numbers stay as they were.
- **13.4** Split `Manage-Privilege.ps1` (R7, long-term). It's a large refactor of the driver that every module and test depends on.

### 15. K21: v2 account delete refuses an SSH key account
- v2 `DELETE /API/Accounts/{id}` gave 400 PASWS056E for key account `30_25`; classic v1 `DELETE /WebServices/PIMServices.svc/Accounts/{id}` worked (lessons CyberArk-API §25). Ask the user whether `Accounts/Delete` should fall back to v1 on PASWS056E; confirm with a second key account first.

## 3. Other open items (not yet approved as work)
- Open live tests (ISPSS pass, lab-blocked items, ready-to-run Self-Hosted items, unlabeled runs to turn into `LT-*`) are listed in the Testing backlog at the end of `Testing_Status.md`.
- Unverified: Users ISPSS support; Reports `ReportID` origin and export `Content-Type`; SafeMembers List `sort` format; `PlatformType` filter on ISPSS.
- `Custom/TestApi` has no unit test file (gap since before 2026-09-25).
- Other aPe* projects: retrofit them with the merged template (`ape-project-setup`) to get `Tools/`, the new CLAUDE.md sections and the `.gitignore` entries. On hold for aPeDiscovery since 2026-09-25 (user decision): its awkward generic lab-name replacements and its CLAUDE.md test-runner TODO.

## 4. Working notes that saved time
- **Live testing:** run a job file through the credential driver on PS 5.1 (`Invoke-AutomationWithCredential.ps1 -ProfileName '{Profile}' -JobFile ...`). Give each step its own `OutputFolder` (`out/3`) and write paths with forward slashes. Actions with `ProducesOutput = $false` write no CSV, so check the log.
- **Files:** use `Tools/Repair-FileEncoding.ps1` and `Tools/Test-FileHygiene.ps1` (see `CLAUDE.md`). Don't build JSON or regex through bash quoting; write a `.ps1` to the scratchpad and run it with `-File`.
- **Swagger:** read it with `ConvertFrom-Json -AsHashtable` (keys differ only by case).
- **Tool guards:** command text containing `Remove-Item` is blocked, and `rm -rf "$VAR"/*` is blocked (use a literal path). `git push --delete` is blocked for Claude, so merges use `gh pr merge <n> --merge --delete-branch`.
- **`claude` CLI:** not on PATH on this host (VS Code extension only), so `claude mcp list` / `claude plugin list` aren't available.
