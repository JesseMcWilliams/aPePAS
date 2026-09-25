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
- New API modules must follow `Docs/API-Module-Development-Guide.md`, especially its "New Module Checklist" section: metadata, the result object, WhatIf before the API call, and strict-mode guards.
- `.ps1`/`.psm1` files must be saved as **UTF-8 with BOM**, and no PS 7-only syntax (`?:`, `??`, `?.`) is allowed. See `Docs/Lessons-Learned-PowerShell-Pester.md` §1, §10 and §26.
- Under strict mode, guard optional properties and `.Count` (Lessons-Learned §4, §24, §27). Search Lessons-Learned by heading with grep before you read it.
- Menus are sorted alphabetically, with `List` first. See the "Action menu ordering" row in the `Docs/Architecture.md` Design Decisions section.
- Every "pick a CPM" prompt uses the shared `Get-CpmOptions` helper.
- Error messages include CyberArk `ErrorCode` plus `ErrorMessage` (`Format-CyberArkErrorMessage` in `CyberArkComms.psm1`).
- For endpoints that need a minimum PVWA version, fall back when the response is a 404. Don't detect the version.
- In `?search=` values, literal periods must be encoded as `%2E` (Lessons-Learned §34).
- Self-Hosted and ISPSS endpoints and values can differ. Don't assume they're the same. Each module's metadata declares its supported systems.

## Docs: what to update for each kind of change
| Change | Update |
|---|---|
| New or changed API module | Unit test file; `Docs/Testing-Plan.md` Component Test Matrix and the matching Full Functional Checklist row; `Docs/User-Guide.md` §6 or §9; `README.md` Features, if user-visible |
| Bug fix | `Testing-Plan.md`: add an `F##` row to Findings and Fixes, or update the `K##` status in Known Issues / Risk Register |
| Design decision or new convention | `Docs/Architecture.md` Design Decisions table |
| New PowerShell/Pester/CyberArk gotcha | `Docs/Lessons-Learned-PowerShell-Pester.md`, as a new numbered section |
| Any of the above | Add one short entry to the `Docs/Documentation-Tracker.md` Revision Log |

- `Testing-Plan.md` and `Documentation-Tracker.md` are very large and have very long table lines. **Find the target with grep, then read a narrow range, or edit by anchor text.** Don't read them whole, and don't grep them without `| cut -c1-200`.
- Keep new table rows to one or two sentences. Longer detail belongs in the commit message.
- For "verify the docs are updated", use a subagent to diff the branch against this checklist and report the gaps only.

## Git
- Don't work directly on `main`. Create a topic branch named `YYYY-MM-DD-<topic>` and open a PR into `main` with `gh`.
- Commit subjects look like `Fix K16: <what>`, `Add <thing>` or `Record live verification of <item>`.
- Commit, push, open a PR or merge only when asked. "Commit and push" means both.

## Live testing
- Lab environment details (PVWA URL, ISPSS tenant, App IDs, test profiles, test safes and objects) are in `Live-Testing.local.md` in the project root. That file is gitignored. **Read it only when a task involves live testing.** Never copy its contents into tracked files, commit messages or PR descriptions.
- If `Live-Testing.local.md` is missing, ask for the details. Don't guess.
- ISPSS rate-limits auth, so keep the auth throttle and delays (K16/K17) in place.
- Never write secrets into any file, log or commit message, including `Live-Testing.local.md`. That file names *where* the credentials live (CP/CCP object or saved profile), not the credentials themselves.
