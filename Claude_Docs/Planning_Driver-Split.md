# aPePAS: Splitting Manage-Privilege.ps1 (handoff 13.4)

> **Stage: Planning.** In progress (branch `2026-10-11-driver-split`, PR #54, not to merge before a full live test): steps 1 to 5 done. This is a high-risk change, so each phase below needs the user's go-ahead. When the split ships, rename this file `Design_Driver-Layout.md` (or fold it into `Design_Architecture.md`) and archive the phase list.

## 1. Why
`Manage-Privilege.ps1` is 4,135 lines (it was 3,742 when `Planning_Token-Usage-Recommendations.md` R7 was written). Each session reads parts of it, and most edits touch only one region. If each region lives in its own file of about 300 to 700 lines, sessions read less, diffs are smaller, and there are fewer merge conflicts. Runtime behavior must not change.

## 2. Constraints found in the code
| # | Constraint | Consequence for the split |
|---|---|---|
| C1 | API modules are dot-sourced into the driver's scope. They read `$script:ActiveProfile` (167 uses) and `$script:SessionToken`, and they call driver helpers (`Show-FieldPrompt`, `Invoke-EntitySearch`, `Get-CpmOptions`, `Get-CsvSavePath`, `Invoke-FileWriteWithRetry`) | The parts must be **dot-sourced `.ps1` files**, not `.psm1` modules. A `.psm1` has its own script scope and would hide that state from the modules |
| C2 | 5 functions use `$PSScriptRoot` as the project root, about 11 times: `Get-CsvSavePath`, `Get-BackupSavePath`, `Get-BackupOpenPath`, `Select-InputFiles` and `Get-OutputCsvPath` | Inside a file under a subfolder, `$PSScriptRoot` would point at that subfolder. Add `$script:AppRoot = $PSScriptRoot` in Configuration and use it in moved code first |
| C3 | Tests dot-source `Manage-Privilege.ps1`, and the `$MyInvocation.InvocationName -eq '.'` guard skips the entry point | Keep the guard and entry point in `Manage-Privilege.ps1`. Dot-source the parts **at script top level, above the guard**, so the tests load them unchanged |
| C4 | Two functions are declared `function script:...` (`Add-ZipEntryFromFile`, `Save-ZipEntryToFile`) | Phase 1 confirms that a dot-sourced file's `script:` scope is the driver's scope on PS 5.1 and 7 |
| C5 | `Invoke-AutomationWithCredential.ps1`, `Sync-AutomationCredential.ps1` and the aPeSecrets wrapper start the driver by path | The parameters and entry point stay in `Manage-Privilege.ps1`, so these callers don't change. A copy of the tool must now include the new folder |
| C6 | Runtime is PS 5.1 under `Set-StrictMode -Version Latest` | New files need UTF-8 with BOM and CRLF (`Tools/Repair-FileEncoding.ps1`). If a part file is missing, startup must fail with a clear message |

## 3. Proposed layout
`Manage-Privilege.ps1` keeps the help block, `param()`, Configuration, core imports, `Assert-Prerequisites`, the dot-source block and the entry point (about 300 lines). The new `Driver/` folder holds the regions, moved verbatim:

| File | Current region (lines) | About |
|---|---|---|
| `Driver/Driver.Helpers.ps1` | Display Helpers (220-585). These are the helpers API modules call | 365 |
| `Driver/Driver.ProfileStore.ps1` | Profile directory, CRUD, backup/restore (587-1264) | 680 |
| `Driver/Driver.ProfileUI.ps1` | Profile display, edit flow, test connection (1266-1801) | 535 |
| `Driver/Driver.ProfileConnect.ps1` | `Invoke-ProfileConnect`, `Invoke-ProfileManagementLoop` (1803-2492) | 690 |
| `Driver/Driver.Session.ps1` | Module discovery, token lifecycle (2494-2860) | 365 |
| `Driver/Driver.CsvProcessing.ps1` | Input and CSV processing (2862-3208) | 345 |
| `Driver/Driver.ActionMenu.ps1` | Action menu, `Invoke-ActionModule` (3210-3539) | 330 |
| `Driver/Driver.SessionLoop.ps1` | Idle timeout, `Invoke-SessionLoop` (3541-3707) | 165 |
| `Driver/Driver.Automation.ps1` | Automation mode (3708-4008) | 300 |

## 4. Steps
1. **Spike (scratchpad only, no repo change).** Build a 3-file model of the layout and check it on PS 5.1 and pwsh: dot-sourced functions land in the driver's script scope; `$script:` writes in a part are visible to the main file and to a dot-sourced "API module"; `function script:` works; a Pester `Mock` of a moved function works when the test dot-sources the main file; strict mode stays active. Stop and report if any check fails.
   - **Result 2026-10-11: all checks passed** on Windows PowerShell 5.1.19041 and pwsh 7.6.6 with Pester 6.1.0. A part dot-sourced at top level, above the guard, put its functions and `$script:` writes in the driver's scope. A module dot-sourced inside a part function saw that state and the part's helpers, and its `$script:` write was visible to the main file. `function script:` worked. Strict mode applied in the part. `$PSScriptRoot` inside a part function was `Driver/`, which confirms C2, and `$script:AppRoot` was the main folder. `Mock` of a part function applied to a caller in the same part when the test dot-sourced the main file. A missing part file stopped startup with a clear `throw`. The spike files were scratchpad-only and are not kept.
2. **Path root (one commit, no move).** Add `$script:AppRoot`. Replace `$PSScriptRoot` inside the functions that will move (C2). Run the full suite on both PowerShell versions.
   - **Done 2026-10-12** (`a338a21`): 12 lines in lines 220-4008 changed; suite 100% on both versions.
3. **Loader (one commit).** Add the `Driver/` dot-source block above the entry-point guard, with a missing-file check in it or in `Assert-Prerequisites`. Start with `Driver.Automation.ps1` (the last region, which has strong coverage from `Manage-Privilege.Automation.Tests.ps1`, 110 tests) to prove the mechanism.
   - **Done 2026-10-12:** Driver Parts region added; a missing part is recorded and reported by `Assert-Prerequisites` (exit 1), checked from a copy without `Driver/`. `Driver/Driver.Automation.ps1` holds the 299 moved lines; the AST comparison found 72 functions before and after with no differences. The `[FATAL]` handler now names the file the error came from. Suite 100% on both versions; a PS 5.1 automation run with an unknown profile exited 3 as expected. The move script is `Move-DriverRegion.ps1` (scratchpad): it takes the exact first line, the first line not moved, the part name and region title, refuses a range with non-function top-level code, and registers the part in `$script:DriverParts`.
4. **Move the regions, one commit each,** with a scratchpad script that cuts exact line ranges. Before and after each move, compare every function's AST text (name to body). The comparison must show no differences, and the full suite must pass on both versions.
   - **Done 2026-10-12** (`ecce1ca` to `dd74136`, plus `a6a7dba`): all eight regions moved with region markers kept; each move's AST comparison showed 72 functions and no differences, and the suite was 100% on both versions after each. The Module Discovery region set `$script:LoadedModules` and `$script:SessionStartTime` at top level, so those two lines moved into Configuration first (`a6a7dba`); every part now holds only functions. `Manage-Privilege.ps1` is 385 lines. PS 5.1 smoke repeated on the final layout: without `Driver/` all nine parts are listed and it exits 1; an unknown-profile automation run exits 3.
5. **Fix references.** Update the "defined in Manage-Privilege.ps1" comments in about 10 API modules, `Reference_API-Module-Guide.md`, the `CLAUDE.md` folder map ("grep for the function" now points at `Driver/`), and `Design_Architecture.md` (structure plus a Design Decisions row: "Driver parts are dot-sourced `.ps1`, not modules, because of shared script scope").
   - **Done 2026-10-12:** comments that named `Manage-Privilege.ps1` as a helper's home now name its `Driver\` file (10 API modules, both `Count-AccountsPer*.ps1`); `CLAUDE.md` folder map, `Reference_API-Module-Guide.md` (structure, `Save-ModuleResultCsv`), `Design_Architecture.md` (status table, folder tree, component text, `Get-CpmOptions` row; the decision row came in step 3) and the README layout. Mentions that are still true (Configuration state, the script as the thing callers run, dated history rows) were left alone.
6. **Verify.** Run the full suite on pwsh and PS 5.1 plus `Tools/Test-FileHygiene.ps1`. Then a manual smoke run: an interactive menu pass (connect, one List action, profile edit, backup) and one automation job file through `Invoke-AutomationWithCredential.ps1` on PS 5.1. Integration tests run only if the user asks.
7. **Docs and PR.** Add a `Planning_User-Docs-Backlog.md` line ("copy the `Driver` folder with the script"), update the README requirements or install line if it lists files, and open one PR with one commit per phase so any phase can be reverted on its own.

## 5. Risks
| Risk | Mitigation |
|---|---|
| A scope assumption is wrong on PS 5.1 (C1, C4) | The step 1 spike runs before any repo change |
| A missed `$PSScriptRoot` sends output or backups to `Driver/` | Step 2 runs before the move. Afterwards, grep `Driver/` for `PSScriptRoot` and expect zero hits |
| The move accidentally edits a function | Verbatim line-range cut plus the AST comparison in step 4 |
| A deployment copies only `Manage-Privilege.ps1` | Startup fails clearly (step 3), plus the backlog and README note |
| Open branches conflict with the move | Merge or park other driver work first. The split goes in as a single PR |

## 6. Decisions (user, 2026-10-11)
1. Dot-sourced `.ps1` parts: approved.
2. Folder name `Driver/`: approved.
3. Nine files as in §3: approved.
4. Step 1 spike: approved and run 2026-10-11 (passed). Steps 2 onwards each still need the user's go-ahead.
