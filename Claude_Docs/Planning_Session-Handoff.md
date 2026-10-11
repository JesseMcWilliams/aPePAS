# aPePAS: Session Handoff (2026-10-11)

> **Stage: Planning.** Picks up the work queue from the session that ended 2026-10-11. Work through the numbered items, using the same numbers as the user did. When an item is done, delete it here and record it where CLAUDE.md's docs table says to. Delete this file once it's empty, or rename it `Archive_Planning_Session-Handoff.md` if it still has history worth keeping.

## 1. Where things stand

| Item | State |
|---|---|
| `main` | `075d21b` (PRs #42 to #50 merged: #48 is F94 to F96, #49 is the item 11 Accounts actions, #50 is the token review). No open PRs in aPePAS |
| aPeTemplate | PR #6 merged (`Tools/`, "File tools" / "Session habits" sections, `New-ClaudeTokenSettings.ps1`). PR #7 **open**: Git preference in `user-claude/CLAUDE.md` (merge deletes the branch). Merge only when the user asks |
| Unit suite | 100% on `main` (2026-10-11): pwsh 1829 passed / 5 skipped, Windows PowerShell 5.1 1834 passed. 93 modules |
| Highest IDs | Finding **F96**, Known Issue **K20**, lessons CyberArk-API **§24**, Pester **§18**. New test prefixes: RJ, VJ, SK, LD, GD, OD, DD, OP, DL, DW, DG, DA, DU, DX, DS, DR |
| Live lab objects | Nothing left over: users `aPePAS-LT-User1`/`User2` and dependent `49_7` were deleted. Dependent `49_6` on master `49_3` existed before and was left alone |
| Claude settings | `.claude/settings.local.json` (gitignored) turns off all 11 synced plugins and the claude.ai connectors (R9/R10). To re-enable one, edit that file |
| Remote branches | Only `origin/2026-10-11-token-cost` (merged) is left in aPePAS and `origin/2026-10-11-token-saving` (merged) in aPeTemplate. **The user deletes them**: `git push origin --delete <branch>` in each repo. Future merges use `--delete-branch` |

## 2. Work queue

### 7. Live-test Users AddAuthMethod / RemoveAuthMethod with the lab's LDAP/AD method
- 2026-10-10: `radius` got HTTP 400 PASWS347E. The lab's external method is LDAP/AD, ID unconfirmed. Try `ldap`; if that fails, ask the user for the ID. Don't guess further.
- Use a disposable user in a job file (Add, AddAuthMethod, Get, RemoveAuthMethod, Delete).

### 11. Accounts gaps: what's left
- Not live-tested: Retrieve SSH Key (needs an SSH key account; the lab has a `UnixSSHKeys` platform), JIT grant (needs a profile that logs on as an LDAP user), Get/Onboard/Delete Discovered (the Pending list is empty), Sync/Resume Dependent (the CPM would act on a real machine).
- Deferred by the user's order: 11.3 Discovered Local Accounts (ISPSS only) and 11.6 Personal Admin Accounts (path conflict between the Swagger and psPAS).

### 12. Token cost: R16 is what's left (`Planning_Token-Usage-Recommendations.md`)
- R9/R10 were applied 2026-10-11 (see "Claude settings" above). R16 restructures the Testing docs (13.3).

### 13. High-risk changes: each needs the user's explicit go-ahead
Done items (13.1, 13.2, 13.5, 13.8, 13.9) were removed; the remaining numbers stay as they were.
- **13.3** Merge test status into one place (R16). This rewrites the Testing Plan matrix and two checklists, with many cross-links.
- **13.4** Split `Manage-Privilege.ps1` (R7, long-term). It's a large refactor of the driver that every module and test depends on.
- **13.6** Run Sync/Resume Dependent live. The CPM would act on the lab machine behind master `49_3`.
- **13.7** Run an SSH key retrieval or JIT grant live. One returns a real secret; the other grants local admin.

## 3. Other open items (not yet approved as work)
- Add `LT-*` definitions to `Testing_Live-Test-Definitions.md` for the ad-hoc runs recorded as "(unlabeled)" in `Live-Testing.local.md` (2026-10-10 and 2026-10-11).
- Live tests not yet run: LT-EXPORT-01 on Self-Hosted, and every `LT-*` on ISPSS (LT-SETUP-01/02 first). Status is tracked in `Live-Testing.local.md`.
- AddFromTemplateRole and UpdateFromTemplateRole expiration (F93) are unit-tested only, not live.
- Unverified: Users ISPSS support; Reports `ReportID` origin and export `Content-Type`; SafeMembers List `sort` format; `PlatformType` filter on ISPSS.
- `Custom/TestApi` has no unit test file (gap since before 2026-09-25).
- Other aPe* projects: retrofit them with the merged template (`ape-project-setup`) to get `Tools/`, the new CLAUDE.md sections and the `.gitignore` entries. On hold for aPeDiscovery since 2026-09-25 (user decision): its awkward generic lab-name replacements and its CLAUDE.md test-runner TODO.

## 4. Working notes that saved time
- **Live testing:** run a job file through the credential driver on PS 5.1 (`Invoke-AutomationWithCredential.ps1 -ProfileName '{Profile}' -JobFile ...`). Give each step its own `OutputFolder` (`out/3`) and write paths with forward slashes. Actions with `ProducesOutput = $false` write no CSV, so check the log.
- **Files:** use `Tools/Repair-FileEncoding.ps1` and `Tools/Test-FileHygiene.ps1` (see `CLAUDE.md`). Don't build JSON or regex through bash quoting; write a `.ps1` to the scratchpad and run it with `-File`.
- **Swagger:** read it with `ConvertFrom-Json -AsHashtable` (keys differ only by case).
- **Tool guards:** command text containing `Remove-Item` is blocked, and `rm -rf "$VAR"/*` is blocked (use a literal path). `git push --delete` is blocked for Claude, so merges use `gh pr merge <n> --merge --delete-branch`.
- **`claude` CLI:** not on PATH on this host (VS Code extension only), so `claude mcp list` / `claude plugin list` aren't available.
