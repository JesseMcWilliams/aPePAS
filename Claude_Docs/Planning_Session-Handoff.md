# aPePAS: Session Handoff (2026-10-11)

> **Stage: Planning.** Picks up the work queue from the session that ended 2026-10-11. Work through the numbered items, using the same numbers as the user did. When an item is done, delete it here and record it where CLAUDE.md's docs table says to. Delete this file once it's empty, or rename it `Archive_Planning_Session-Handoff.md` if it still has history worth keeping.

## 1. Where things stand

| Item | State |
|---|---|
| `main` | `c24076c` (PRs #42 to #53 merged: #48 is F94 to F96, #49 is the item 11 Accounts actions, #50 is the token review, #51 is a handoff update, #52 is the Testing_Status merge plus F97/F98, #53 is the K21 fix and the 13.4 plan). Branch `2026-10-11-driver-split` holds 13.4 work |
| aPeTemplate | PR #6 merged (`Tools/`, "File tools" / "Session habits" sections, `New-ClaudeTokenSettings.ps1`). PR #7 merged (`3a48127`): Git preference in `user-claude/CLAUDE.md` (merge deletes the branch) |
| Unit suite | 100% on `main` `c24076c` (2026-10-11): pwsh 1842 passed / 5 skipped, Windows PowerShell 5.1 1847 passed. 93 modules |
| Highest IDs | Finding **F99**, Known Issue **K21**, lessons CyberArk-API **§25**, Pester **§18**. New test prefixes: RJ, VJ, SK, LD, GD, OD, DD, OP, DL, DW, DG, DA, DU, DX, DS, DR |
| Live lab objects | Nothing left over. SSH key accounts `30_25`, `30_26` and `30_27` were deleted 2026-10-11 through the classic v1 route (K21; 30_26/30_27 by the new fallback) and sit in the safe's 7-day retention. Deleted: users `aPePAS-LT-User1`/`User2`/`User3` and dependents `49_7`/`49_8`. Dependent `49_6` on master `49_3` existed before and was left alone |
| Claude settings | `.claude/settings.local.json` (gitignored) turns off all 11 synced plugins and the claude.ai connectors (R9/R10). To re-enable one, edit that file |
| Remote branches | Only `main` on origin in both repos (checked 2026-10-11). Merges use `gh pr merge <n> --merge --delete-branch` |

## 2. Work queue

### 11. Accounts gaps: what's left
- Live-tested 2026-10-11: Retrieve SSH Key (throwaway key), CheckIn, Sync/Resume Dependent. Still open: JIT grant (needs a profile that logs on as an LDAP user) and Get/Onboard/Delete Discovered (the Pending list is empty). See the Testing backlog in `Testing_Status.md`.
- Deferred by the user's order: 11.3 Discovered Local Accounts (ISPSS only) and 11.6 Personal Admin Accounts (path conflict between the Swagger and psPAS).

### 13. High-risk changes: each needs the user's explicit go-ahead
Done items (13.1-13.3, 13.5-13.9) were removed; the remaining numbers stay as they were.
- **13.4** Split `Manage-Privilege.ps1` (R7, long-term; the user calls it item 12). The plan is in `Planning_Driver-Split.md`; its §6 decisions are answered (dot-sourced `.ps1`, `Driver/`, nine files). In progress on branch `2026-10-11-driver-split`, PR #54 (**do not merge before a full live test**). Steps 1 to 7 done: all nine parts are in `Driver/`, `Manage-Privilege.ps1` is 385 lines, references and docs updated; see the plan's §4. **Next: the live test** (LT-SPLIT-01 to 05 plus LT-LOGON-01, LT-DRIVER-01, LT-JOB-01 from the branch; Testing backlog item 6 in `Testing_Status.md`). Then merge with the user's OK and rename the plan to `Design_`.

### 15. K21: v2 account delete refuses an SSH key account
- The user calls this item 13. The v1 fallback on PASWS056E is coded, unit-tested (AD17-AD20) and confirmed live on Self-Hosted (30_26 and 30_27). Still open: ISPSS behavior, and F99 (automation Session Summary counts each action twice; the interactive path is not yet checked), found during the run.

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
