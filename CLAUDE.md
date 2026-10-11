# aPePAS: Claude Code project notes

aPePAS is a menu-driven PowerShell console driver for CyberArk PAS (Self-Hosted PVWA and ISPSS/Privilege Cloud). It also has a non-interactive automation mode. Its **runtime target is Windows PowerShell 5.1**, and `Set-StrictMode -Version Latest` is always active.

## Folder map
- `Manage-Privilege.ps1`: the driver (menus, profiles, auth flow, automation mode). About 3,700 lines, so **grep for the function and read a line range; don't read the whole file.**
- `APIModules/<Category>/Invoke-<Category><Action>.ps1`: one file per action. The categories are Accounts, Applications, Custom, Groups, Platforms, Policies, Reports, SafeMembers, Safes and Users.
- `Auth/`: `CyberArk.Auth.Common|ISPSS|SelfHosted.psm1`. `Auth/WebView2/` holds local DLLs and is gitignored.
- `Modules/`: `CyberArkComms.psm1` (`Invoke-CyberArkAPI`, query/URL helpers), `CyberArkLogging.psm1`, `CyberArkCredentialStore.psm1`.
- `Tests/Unit/<Name>.Tests.ps1`: Pester unit tests, one per module. `Tests/Integration/` runs against live PVWA, so **only run it when asked.**
- `Swagger/`: PVWA 14.6 swagger JSON.
- Standalone utilities in the root: `Count-AccountsPerPlatform.ps1`, `Count-AccountsPerSafe.ps1`, `Sync-AutomationCredential.ps1` (the wrapper for the separate aPeSecrets project).
- External references are in `C:\Code\References\` (psPAS 8.0.20, Self-Hosted Swagger, CyberArk ISPSS docs). Check there before guessing at API behavior.
- `Tools/`: helper scripts for Claude sessions (see "File tools" below).
- The root `*.csv`, `Logs/` and `plink.exe` are runtime output or local tools and are gitignored. Don't read them.

## Tests
```
pwsh -NoProfile -File Tests/Run-Tests.ps1 > <scratchpad>/test.txt 2>&1; tail -40 <scratchpad>/test.txt
pwsh -NoProfile -File Tests/Run-Tests.ps1 -Path Tests/Unit/<Name>.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Tests\Run-Tests.ps1   # PS 5.1 check
```
- `-Verbosity` accepts None, Normal (the default), Detailed or Diagnostic. Use `Detailed` only when you're diagnosing a failure.
- Redirect the output to a file and read only the summary or failures. Don't stream full test output into the conversation.
- The suite must stay at 100% pass. Run the single test file while iterating and the full suite before you commit.

## Code rules (details in the linked sections, not repeated here)
- New API modules must follow `Claude_Docs/Reference_API-Module-Guide.md`, especially its "New Module Checklist" section: metadata, the result object, WhatIf before the API call, and strict-mode guards.
- `.ps1`/`.psm1` files must be saved as **UTF-8 with BOM**, and no PS 7-only syntax (`?:`, `??`, `?.`) is allowed. See `Claude_Docs/Reference_Lessons-Learned-PowerShell.md` §1 and §2.
- Under strict mode, guard optional properties and `.Count` (`Reference_Lessons-Learned-StrictMode.md` §2 to §6). `Reference_Lessons-Learned.md` indexes the topic files and maps old section numbers. Search the topic files by heading with grep before you read them.
- Menus are sorted alphabetically, with `List` first. See the "Action menu ordering" row in the `Claude_Docs/Design_Architecture.md` Design Decisions section.
- Every "pick a CPM" prompt uses the shared `Get-CpmOptions` helper.
- Error messages include CyberArk `ErrorCode` plus `ErrorMessage` (`Format-CyberArkErrorMessage` in `CyberArkComms.psm1`).
- For endpoints that need a minimum PVWA version, fall back when the response is a 404. Don't detect the version.
- In `?search=` values, literal periods must be encoded as `%2E` (`Reference_Lessons-Learned-CyberArk-API.md` §10).
- Self-Hosted and ISPSS endpoints and values can differ. Don't assume they're the same. Each module's metadata declares its supported systems.

## Documentation layout
- `README.md` (root): an **overview only**. It covers purpose, requirements, a quick start and a short feature list, and links to `User_Docs/` and `Claude_Docs/` for everything else. Put detail in a doc and link to it rather than adding it to the README.
- `Claude_Docs/` holds every doc Claude creates or works from, named `<Stage>_<Topic-With-Hyphens>.md`:
  - `Planning_`: proposals and backlogs that aren't built yet. Once built, the doc becomes `Design_` or is renamed `Archive_Planning_...`.
  - `Design_`: how the current system works. Keep it current. Archive it only when the feature is removed or replaced.
  - `Testing_`: test plans, open findings and known issues. Closed findings move to `Archive_Testing_...`.
  - `Reference_`: rules that apply at every stage (lessons learned, conventions, interface contracts).
  - `Archive_<OriginalStage>_<Topic>.md`: finished or superseded material. **Don't read `Archive_*` unless the user asks or the task needs history.**
- `User_Docs/`: end-user documentation, usually written near the end of the project from `Claude_Docs/Planning_User-Docs-Backlog.md`. It's output, not a source of facts. Take facts from the code and `Claude_Docs/`.
- When you make a user-visible change, add one line for it to `Planning_User-Docs-Backlog.md`.
- Keep each doc to about 500 lines. Past that, move closed or old content into an `Archive_` file. Don't keep revision logs, because git has the history. Put dates in file names only for point-in-time snapshots, such as reviews.
- Rename docs with `git mv`, and update every link to them in the same change.
- If a doc is large, find the target with grep and read a narrow range. Keep table rows to one or two sentences.


## Docs: what to update for each kind of change
| Change | Update |
|---|---|
| New or changed API module | Unit test file; its row in `Claude_Docs/Testing_Status.md` (the only place for test status; add what-to-check steps to `Testing_Checklist-Self-Hosted.md` / `Testing_Checklist-ISPSS.md` only when they're not obvious); one line in `Planning_User-Docs-Backlog.md`. Don't edit `User_Docs/` per change: it's refreshed from the backlog at release. `README.md` only if the overview changes (it carries no action count) |
| Live test run | The row in `Testing_Status.md` (and its Testing backlog entry), plus the run in `Live-Testing.local.md` |
| Bug fix | `Testing_Findings-and-Known-Issues.md`: add a one-line `F##` row to Findings and Fixes (move its detail to `Archive_Testing_Findings-Closed.md` once closed), or update the `K##` status in Known Issues / Risk Register |
| Design decision or new convention | `Claude_Docs/Design_Architecture.md` Design Decisions table |
| New PowerShell/Pester/CyberArk gotcha | The matching `Claude_Docs/Reference_Lessons-Learned-<Topic>.md` file, as a new numbered section at its end |
| Any user-visible change | One line in `Claude_Docs/Planning_User-Docs-Backlog.md` |

- The `Testing_*` docs have long table lines (the Testing Plan is a hub that links to its split-out files). **Find the target with grep, then read a narrow range, or edit by anchor text** (`Tools/Edit-DocByAnchor.ps1`). Don't grep them without `| cut -c1-200`.

## File tools (use these instead of writing one-off scripts)
- `pwsh -NoProfile -File Tools/Repair-FileEncoding.ps1 <paths...>`: CRLF everywhere, UTF-8 BOM on `.ps1`/`.psm1`/`.psd1`. Run it after creating a file with Write or a heredoc.
- `pwsh -NoProfile -File Tools/Test-FileHygiene.ps1 [paths...]`: parse + BOM + CRLF check. With no paths it checks every PowerShell file changed against `main`. Run it before committing.
- `pwsh -NoProfile -File Tools/Edit-DocByAnchor.ps1 -Path <doc> -ReplacementsFile <json>`: exact, unique-anchor replacements (`[{"Old":"...","New":"..."}]`) that keep the doc's BOM and line endings.
- Don't use `sed -i` on tracked files (it has stripped CRLF before), and pass several paths to a pwsh script only when its parameter uses `ValueFromRemainingArguments`.

## Session habits (token cost)
- One work item per session: when it's committed, suggest `/clear` and leave a handoff in `Claude_Docs/Planning_Session-Handoff.md`.
- Keep subagent jobs small (2 or 3 modules each). For mechanical work such as one test per file, pass `model: "sonnet"` or `"haiku"`.
- For "verify the docs are updated", use a subagent to diff the branch against this checklist and report the gaps only.

## Git
- Don't work directly on `main`. Create a topic branch named `YYYY-MM-DD-<topic>` and open a PR into `main` with `gh`.
- Commit subjects look like `Fix K16: <what>`, `Add <thing>` or `Record live verification of <item>`.
- Commit, push, open a PR or merge only when asked. "Commit and push" means both.
- The `Docs/` → `Claude_Docs/` move (7cea6c0) also rewrote content, so the default `git log --follow` stops there. Use `git log --follow -M30% -- <file>` to reach the older history, and `git blame -C -C` to attribute lines to their real commits. Files split out in 47ebba7 have their earlier history under the doc they came from.

## Live testing
- Lab environment details (PVWA URL, ISPSS tenant, App IDs, test profiles, test safes and objects) are in `Live-Testing.local.md` in the project root. That file is gitignored. **Read it only when a task involves live testing.** Never copy its contents into tracked files, commit messages or PR descriptions.
- If `Live-Testing.local.md` is missing, ask for the details. Don't guess.
- Live tests are defined by label (`LT-*`) in `Claude_Docs/Testing_Live-Test-Definitions.md`, with `{Placeholder}` values only. `Live-Testing.local.md` fills in the placeholders per environment and tracks which labels have run. Add new tests to the definitions file, never lab values.
- ISPSS rate-limits auth, so keep the auth throttle and delays (K16/K17) in place.
- Never write secrets into any file, log or commit message, including `Live-Testing.local.md`. That file names *where* the credentials live (CP/CCP object or saved profile), not the credentials themselves.
- When an example, doc or test needs a password placeholder, use `ThisIsMy_FAKE_Password6!`. It's obviously fake, and it satisfies typical complexity rules.
