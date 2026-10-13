# aPePAS: Session Handoff (2026-10-12)

> **Stage: Planning.** Picks up the work queue from the session that ended 2026-10-12. Work through the numbered items, using the same numbers as the user did. When an item is done, delete it here and record it where CLAUDE.md's docs table says to. Delete this file once it's empty, or rename it `Archive_Planning_Session-Handoff.md` if it still has history worth keeping.

## 1. Where things stand

| Item | State |
|---|---|
| `main` | `c24076c` (PRs #42 to #53 merged: #48 is F94 to F96, #49 is the item 11 Accounts actions, #50 is the token review, #51 is a handoff update, #52 is the Testing_Status merge plus F97/F98, #53 is the K21 fix and the 13.4 plan) |
| Open PR | **#54** `2026-10-11-driver-split` (handoff 13.4, the driver split). Code complete; **do not merge before the live test** (user's order, 2026-10-12) |
| aPeTemplate | PR #6 merged (`Tools/`, "File tools" / "Session habits" sections, `New-ClaudeTokenSettings.ps1`). PR #7 merged (`3a48127`): Git preference in `user-claude/CLAUDE.md` (merge deletes the branch) |
| Unit suite | 100% on `main` `c24076c` and after every commit on the PR #54 branch (2026-10-12): pwsh 1842 passed / 5 skipped, Windows PowerShell 5.1 1847 passed. 93 modules |
| Highest IDs | Finding **F99**, Known Issue **K21**, lessons CyberArk-API **§25**, Pester **§18**. Live test labels: LT-SPLIT-01 to 05 added 2026-10-12. New test prefixes: RJ, VJ, SK, LD, GD, OD, DD, OP, DL, DW, DG, DA, DU, DX, DS, DR |
| Live lab objects | Nothing left over. SSH key accounts `30_25`, `30_26` and `30_27` were deleted 2026-10-11 through the classic v1 route (K21; 30_26/30_27 by the new fallback) and sit in the safe's 7-day retention. Deleted: users `aPePAS-LT-User1`/`User2`/`User3` and dependents `49_7`/`49_8`. Dependent `49_6` on master `49_3` existed before and was left alone |
| Claude settings | `.claude/settings.local.json` (gitignored) turns off all 11 synced plugins and the claude.ai connectors (R9/R10). To re-enable one, edit that file |
| Remote branches | aPePAS: `main` and `2026-10-11-driver-split` (PR #54). aPeTemplate: only `main`. Merges use `gh pr merge <n> --merge --delete-branch` |

## 2. Work queue

### 11. Accounts gaps: what's left
- Live-tested 2026-10-11: Retrieve SSH Key (throwaway key), CheckIn, Sync/Resume Dependent. Still open: JIT grant (needs a profile that logs on as an LDAP user) and Get/Onboard/Delete Discovered (the Pending list is empty). See the Testing backlog in `Testing_Status.md`.
- Deferred by the user's order: 11.3 Discovered Local Accounts (ISPSS only) and 11.6 Personal Admin Accounts (path conflict between the Swagger and psPAS).

### 13. High-risk changes: each needs the user's explicit go-ahead
Done items (13.1-13.3, 13.5-13.9) were removed; the remaining numbers stay as they were.
- **13.4** Split `Manage-Privilege.ps1` (the user calls it item 12). Plan and per-step results: `Planning_Driver-Split.md` §4. Steps 1 to 7 are done on PR #54: nine dot-sourced parts in `Driver/` (Helpers, ProfileStore, ProfileUI, ProfileConnect, Session, CsvProcessing, ActionMenu, SessionLoop, Automation), loaded by the Driver Parts region of `Manage-Privilege.ps1` (385 lines). A whole-branch AST comparison against `main` shows only the expected changes (five `$PSScriptRoot` to `$script:AppRoot` functions, the `Assert-Prerequisites` missing-part check). Remaining, in order:
  1. **Live test** (Testing backlog item 6 in `Testing_Status.md`): LT-SPLIT-01 to 05 plus LT-LOGON-01, LT-DRIVER-01 and LT-JOB-01, from the PR branch on PS 5.1 (LT-SPLIT-02 also on pwsh). LT-SPLIT-02 to 05 are interactive, so the user runs them at the console. **Open question (asked as item 37):** should Claude run LT-SPLIT-01 and the three automation tests, or will the user run the whole set? Record results in the `Testing_Status.md` "Driver: `Driver\*.ps1` split" row and in `Live-Testing.local.md`.
  2. Merge PR #54 only on the user's OK (item 38): `gh pr merge 54 --merge --delete-branch`.
  3. After the merge, `git mv` the plan to `Design_Driver-Layout.md` (or fold it into `Design_Architecture.md`), update its links, and remove the Testing backlog item 6.

### 15. K21: v2 account delete refuses an SSH key account
- The user calls this item 13. The v1 fallback on PASWS056E is coded, unit-tested (AD17-AD20) and confirmed live on Self-Hosted (30_26 and 30_27). Still open: ISPSS behavior, and F99 (automation Session Summary counts each action twice; the interactive path is not yet checked), found during the run. F99 now lives in `Driver/Driver.Automation.ps1` (`Invoke-AutomationStep`), so fix it after PR #54 merges to avoid a conflict.

### 16. Authentik IdP: SAML, OIDC and LDAP (the user's item 8 of 2026-10-12)
Merged into the release candidate `2026-10-12-release-candidate` (PR #55, with PR #54 the driver split). Version 1.5.0. Lab setup and results are in `Live-Testing.local.md` ("Authentik IdP").
- Done: F100 (Bulk job checked, PUT fallback, saved-list check), F101 (never-expires `expiryDate` left out of user PUTs), F102 (SP-initiated SAML), lessons file `Reference_Lessons-Learned-CyberArk-Auth-Methods.md` (§1-§8), live tests LT-SAML-01, LT-LDAP-01, LT-USERS-01.
- LT-SAML-01 passed 2026-10-12, after F104 (profile copy, method change) and F105 (WebView2 data folder) found during it. LDAP sign-in passed on both editions (user-run) and LT-USERS-01 passed (remove on PS 7, add on PS 5.1), all 2026-10-12.
- Done after the decision: OIDC removed from the Self-Hosted methods (F103 closed; a saved OIDC profile fails with a message). User docs refreshed from the backlog, and `User_Docs/Whats-Changed.md` written for 1.5.0. Next: merge the release candidate into `main` (user's call; LT-SAML-01 has passed).
- Lab follow-up: the Authentik LDAP outpost trusts the domain CA only through a `docker cp` into the container, which is lost if Authentik recreates it. Permanent fix: a custom image set through the outpost `container_image` setting.

## 3. Other open items (not yet approved as work)
- Open live tests (ISPSS pass, lab-blocked items, ready-to-run Self-Hosted items, unlabeled runs to turn into `LT-*`) are listed in the Testing backlog at the end of `Testing_Status.md`.
- Unverified: Users ISPSS support; Reports `ReportID` origin and export `Content-Type`; SafeMembers List `sort` format; `PlatformType` filter on ISPSS.
- `Custom/TestApi` has no unit test file (gap since before 2026-09-25).
- Other aPe* projects: retrofit them with the merged template (`ape-project-setup`) to get `Tools/`, the new CLAUDE.md sections and the `.gitignore` entries. On hold for aPeDiscovery since 2026-09-25 (user decision): its awkward generic lab-name replacements and its CLAUDE.md test-runner TODO.

## 4. Working notes that saved time
- **Driver layout (after PR #54):** grep `Driver/` for a function, not `Manage-Privilege.ps1`. Functions use `$script:AppRoot` for the project root; `$PSScriptRoot` inside a part is `Driver\`. A new part must be listed in `$script:DriverParts`, and parts hold only function definitions (state goes in Configuration).
- **Live testing:** run a job file through the credential driver on PS 5.1 (`Invoke-AutomationWithCredential.ps1 -ProfileName '{Profile}' -JobFile ...`). Give each step its own `OutputFolder` (`out/3`) and write paths with forward slashes. Actions with `ProducesOutput = $false` write no CSV, so check the log.
- **Files:** use `Tools/Repair-FileEncoding.ps1` and `Tools/Test-FileHygiene.ps1` (see `CLAUDE.md`). Don't build JSON or regex through bash quoting; write a `.ps1` to the scratchpad and run it with `-File`. In that `.ps1`, put doc text that contains `$` in **single-quoted** strings: a double-quoted string expanded `$PSScriptRoot` into a local path in a committed note on 2026-10-12. `sed -i` stripped CRLF again on 2026-10-12, so don't use it.
- **Comparing with `main`:** `git show main:<file>` gives the LF index copy; normalize `\r\n` before comparing AST text with working files.
- **Swagger:** read it with `ConvertFrom-Json -AsHashtable` (keys differ only by case).
- **Tool guards:** command text containing `Remove-Item` is blocked, and `rm -rf "$VAR"/*` is blocked (use a literal path). `git push --delete` is blocked for Claude, so merges use `gh pr merge <n> --merge --delete-branch`.
- **`claude` CLI:** not on PATH on this host (VS Code extension only), so `claude mcp list` / `claude plugin list` aren't available.
