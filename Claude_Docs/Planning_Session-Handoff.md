# aPePAS: Session Handoff (2026-10-12)

> **Stage: Planning.** Picks up the work queue from the session that ended 2026-10-12. Work through the numbered items, using the same numbers as the user did. When an item is done, delete it here and record it where CLAUDE.md's docs table says to. Delete this file once it's empty, or rename it `Archive_Planning_Session-Handoff.md` if it still has history worth keeping.

## 1. Where things stand

| Item | State |
|---|---|
| `main` | PR #64 merged 2026-10-15 (Export All `IncludePendingAccounts` option, live on Self-Hosted), on top of PR #63 (2026-10-14: Discovered accounts live records, OnboardDiscovered DefaultPassword hint, CyberArk-API lessons archive) and `1eafb9c` (PR #62: Accounts group submenu and VERBOSE HTTP trace). All untagged. Last release `2764a5f`, tagged **`v1.5.0`** (PR #60: release candidate with #54 driver split, #55 SAML and allowed-method fixes, #56 OIDC removal and docs, #57 F104/F105, #58/#59 live records). Notes for users: `User_Docs/Whats-Changed.md` |
| Credential Reason | aPeSecrets PR #4 and aPePAS PR #65 both merged 2026-10-16 (in that order) |
| Current branch | `2026-11-06-f99-summary-count` (not yet committed; user said not yet): F99 fix plus Accounts Add/Update platform properties (item 16), both live-verified |
| aPeTemplate | PR #6 merged (`Tools/`, "File tools" / "Session habits" sections, `New-ClaudeTokenSettings.ps1`). PR #7 merged (`3a48127`): Git preference in `user-claude/CLAUDE.md` (merge deletes the branch) |
| Unit suite | 2026-11-06 on the F99 branch: Windows PowerShell 5.1, 1901 passed / 0 failed. **pwsh 7 is not installed on this host now**, so run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Tests\Run-Tests.ps1` and the `Tools/` scripts with `powershell.exe`. 93 modules. `Design_Architecture.md` is at the 500-line limit: archive older content before the next addition |
| Highest IDs | Finding **F105**, Known Issue **K21**, lessons CyberArk-API **§26**, CyberArk-Auth-Methods **§9**, Pester **§18**. Live test labels: LT-DRIVER-02 (Reason in the audit, passed 2026-10-15), LT-SPLIT-01 to 05, LT-SAML-01, LT-LDAP-01, LT-USERS-01. Export All tests up to EA11. New test prefixes: RJ, VJ, SK, LD, GD, OD, DD, OP, DL, DW, DG, DA, DU, DX, DS, DR, SH-SAML, MG (driver menu groups), PP (platform property input, `CyberArkComms.Tests.ps1`). Accounts Add tests up to AA28; automation tests up to AM117 |
| Live lab objects | Kept on purpose for the SAML, LDAP and auth-method live tests: Authentik test users and groups, five Vault test users with their password accounts, and a PVWA LDAP directory and mapping (details in `Live-Testing.local.md`). From earlier: SSH key accounts `30_25`, `30_26` and `30_27` were deleted 2026-10-11 through the classic v1 route (K21; 30_26/30_27 by the new fallback) and sit in the safe's 7-day retention. Deleted: users `aPePAS-LT-User1`/`User2`/`User3` and dependents `49_7`/`49_8`. Dependent `49_6` on master `49_3` existed before and was left alone. 2026-10-14: pending `19_8` (`Local_Test_CA_User01`) kept for Onboard tests; onboarded `30_29` deleted (safe retention); `CA_Automation_User` was given access to `Test Accounts` |
| Claude settings | `.claude/settings.local.json` (gitignored) turns off all 11 synced plugins and the claude.ai connectors (R9/R10). To re-enable one, edit that file |
| Remote branches | aPePAS: only `main` (tag `v1.5.0`). aPeTemplate: only `main`. Merges use `gh pr merge <n> --merge --delete-branch` |

## 2. Work queue

### 11. Accounts gaps: what's left
- Live-tested 2026-10-11: Retrieve SSH Key (throwaway key), CheckIn, Sync/Resume Dependent; 2026-10-14: List/Get/Onboard/Delete Discovered. Still open: JIT grant (needs a profile that logs on as an LDAP user). See the Testing backlog in `Testing_Status.md`.
- Deferred by the user's order: 11.3 Discovered Local Accounts (ISPSS only) and 11.6 Personal Admin Accounts (path conflict between the Swagger and psPAS).

### 13. High-risk changes: each needs the user's explicit go-ahead
Done items (13.1-13.3, 13.5-13.9) were removed; the remaining numbers stay as they were.
- **13.4** Split `Manage-Privilege.ps1` (the user calls it item 12). **Merged** in 1.5.0: nine dot-sourced parts in `Driver/`, loaded by the Driver Parts region of `Manage-Privilege.ps1`. The split code was used in the 2026-10-12 live runs (interactive SAML/LDAP on both editions, automation on both), but the formal set was not run. Remaining:
  1. **Live test, now after the release:** LT-SPLIT-01 to 05 (Testing backlog item 6 in `Testing_Status.md`). LT-SPLIT-02 to 05 are interactive, so the user runs them at the console. Record results in the `Testing_Status.md` "Driver: `Driver\*.ps1` split" row and in `Live-Testing.local.md`.
  2. `git mv` the plan to `Design_Driver-Layout.md` (or fold it into `Design_Architecture.md`), update its links, and remove the Testing backlog item 6 once the live tests pass.

### 15. K21: v2 account delete refuses an SSH key account
- The user calls this item 13. The v1 fallback on PASWS056E is coded, unit-tested (AD17-AD20) and confirmed live on Self-Hosted (30_26 and 30_27). Still open: ISPSS behavior. F99 fixed 2026-11-06 (all three driver paths and CSV per-row entries; the 167 module calls were removed, so the driver is the only writer, Module-Conventions §2, AM116-AM117).

### 16. Accounts Add: platform properties (user request 2026-11-06)
- Need: set `UseSudoOnReconcile = Yes` while onboarding (86 Unix accounts on `SNXUnixviaSSH24` had to be fixed afterwards by hand).
- Done (unit-tested, AA23-AA28, PP01-PP04): Add reads a `PlatformAccountProperties` column (`Key=Value;...`) and `Platform_<Key>` columns and sends `platformAccountProperties`. The parser moved from Add Dependent to `ConvertFrom-CyberArkPlatformPropertyInput` in `CyberArkComms.psm1`, so both use it.
- Accounts Update takes the same columns (user approved 2026-11-06): one JSON Patch `add` op per key on `/platformAccountProperties/<Key>` (AU24-AU28). The result-row helper is shared as `Add-CyberArkPlatformPropertyColumns` (PP05).
- Live on Self-Hosted 2026-11-06 (UnixSSH, Test Accounts, throwaway accounts 30_30/30_31, deleted): Add sets the property; Update `add` works with the property absent and present, by InputJson and CSV. F99 also confirmed live in the same runs. ISPSS not tested.
- This host (Windows Server 2019) now has the `CA_Automation_Test` profile and `CredentialSources.json` (CP) in `%APPDATA%\IdiraUnifiedScripts\Profiles`, created 2026-11-06; `-ResolveOnly` passes. aPeSecrets is at `C:\Code\aPeSecrets`.
- Design decision row ("the driver owns the Session Summary") not added because `Design_Architecture.md` is at 500 lines. Archive some of it first.

## 3. Other open items (not yet approved as work)
- Open live tests (ISPSS pass, lab-blocked items, ready-to-run Self-Hosted items, unlabeled runs to turn into `LT-*`) are listed in the Testing backlog at the end of `Testing_Status.md`.
- Unverified: Users ISPSS support; Reports `ReportID` origin and export `Content-Type`; SafeMembers List `sort` format; `PlatformType` filter on ISPSS.
- Credential Reason (2026-10-15): not tested on ISPSS. Conjur has no reason field (it warns), so a Conjur audit trail would need another approach (a per-job host identity, or logging on the aPePAS side). A Credential Provider cache hit is not audited again, so the reason only shows on a real vault retrieval.
- `Custom/TestApi` has no unit test file (gap since before 2026-09-25).
- Lab: the Authentik LDAP outpost trusts the domain CA only through a `docker cp` into its container, which is lost if Authentik recreates it. Permanent fix: a custom image set through the outpost `container_image` setting (details in `Live-Testing.local.md`).
- Other aPe* projects: retrofit them with the merged template (`ape-project-setup`) to get `Tools/`, the new CLAUDE.md sections and the `.gitignore` entries. On hold for aPeDiscovery since 2026-09-25 (user decision): its awkward generic lab-name replacements and its CLAUDE.md test-runner TODO.

## 4. Working notes that saved time
- **Driver layout (after PR #54):** grep `Driver/` for a function, not `Manage-Privilege.ps1`. Functions use `$script:AppRoot` for the project root; `$PSScriptRoot` inside a part is `Driver\`. A new part must be listed in `$script:DriverParts`, and parts hold only function definitions (state goes in Configuration).
- **Live testing:** run a job file through the credential driver on PS 5.1 (`Invoke-AutomationWithCredential.ps1 -ProfileName '{Profile}' -JobFile ...`). Give each step its own `OutputFolder` (`out/3`) and write paths with forward slashes. Actions with `ProducesOutput = $false` write no CSV, so check the log.
- **Files:** use `Tools/Repair-FileEncoding.ps1` and `Tools/Test-FileHygiene.ps1` (see `CLAUDE.md`). Don't build JSON or regex through bash quoting; write a `.ps1` to the scratchpad and run it with `-File`. In that `.ps1`, put doc text that contains `$` in **single-quoted** strings: a double-quoted string expanded `$PSScriptRoot` into a local path in a committed note on 2026-10-12. `sed -i` stripped CRLF again on 2026-10-12, so don't use it.
- **Comparing with `main`:** `git show main:<file>` gives the LF index copy; normalize `\r\n` before comparing AST text with working files.
- **Swagger:** read it with `ConvertFrom-Json -AsHashtable` (keys differ only by case).
- **Tool guards:** command text containing `Remove-Item` is blocked, and `rm -rf "$VAR"/*` is blocked (use a literal path). `git push --delete` is blocked for Claude, so merges use `gh pr merge <n> --merge --delete-branch`.
- **`claude` CLI:** not on PATH on this host (VS Code extension only), so `claude mcp list` / `claude plugin list` aren't available.
