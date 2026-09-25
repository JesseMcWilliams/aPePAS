# Lessons Learned: Pester v6 Tests

Test-file structure, mocking, assertions, and diagnosing suite-level failures in this project's Pester
v6 suite. Each entry lists the symptom, the cause, the fix or rule, and one example. The "Old" line gives
the entry's section numbers in the original single file.

---

## 1. Put the module-importing `BeforeAll` at file level, not inside `Describe`

*Old: §9.1, §9 (intro)*

**Symptom:** every test in the file fails at once with `InvalidOperationException: A 'break' or 'continue'
statement with a label that does not match any enclosing loop escaped from your code` (Pester issue
#2669). This hit all 22 new test files in the Custom, Applications and extended Accounts categories, while
older files that had a file-level `BeforeAll` kept passing.

**Cause:** in Pester v6.1+, a `BeforeAll` nested inside `Describe` runs inside Pester's own `foreach`.
A `break` or `continue` in imported code can escape it, even one inside a function body that never runs
at import time. Here the trigger was the retry loop in `Invoke-CyberArkAPI` (`CyberArkComms.psm1`).

**Rule:** put the import `BeforeAll` before any `Describe`. Use `$PSScriptRoot` rather than
`Split-Path -Parent $MyInvocation.MyCommand.Path`, and use `$script:` for any variable that `Describe` or
`Context` needs.

```powershell
BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\..\APIModules\...\Invoke-Xxx.ps1'
    Import-Module (Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1')   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'XxxTests' -MinLevel 'ERROR'
}
Describe 'Invoke-Xxx' { ... }
```

---

## 2. Call `Initialize-CyberArkLog` in the file-level `BeforeAll`

*Old: §9.2*

**Cause:** production modules call `Write-CyberArkLog`. Without initialization, logs go to the console,
and the first write throws if the default log folder doesn't exist on the test machine.

**Rule:** every test file calls `Initialize-CyberArkLog -Destination 'Console' -ProfileName
'<ModuleName>Tests' -MinLevel 'ERROR'` after its imports (see the §1 example). Give each file a unique
`ProfileName`, so summary entries from different files don't mix.

---

## 3. Define test helpers inside `BeforeAll`, without a `script:` prefix

*Old: §2.2*

**Symptom:** `CommandNotFoundException: The term 'script:MyHelper' is not recognized`.

**Cause:** `It` blocks run in a different scope from the file's top level. A top-level
`function script:X` is not reliably reachable from an `It` as `script:X`.

```powershell
BeforeAll { function Get-LatestLog { ... } }       # not: function script:Get-LatestLog at top level
It 'some test' { Get-LatestLog | Should -Not -BeNullOrEmpty }
```

---

## 4. Stub driver-scope functions before you `Mock` them

*Old: §9.3*

**Symptom:** `CommandNotFoundException: Could not find Command Get-CsvSavePath` during `Mock` setup, which
fails every test in the `Describe`.

**Cause:** Pester v6 can't mock a command that doesn't exist in the session. Functions defined in
`Manage-Privilege.ps1` aren't imported by module tests.

**Rule:** in the file-level `BeforeAll`, define a global stub with the same parameters for every function
that the module calls but the test doesn't import. Check the module for `& $fnName` and for bare calls to
names not defined in `CyberArkComms.psm1` or `CyberArkLogging.psm1`.

```powershell
function global:Get-CsvSavePath { param([string]$DefaultFolder, [string]$ModuleName) return $null }
```

---

## 5. A mock scriptblock needs a `param()` block to fill `$PSBoundParameters`

*Old: §2.1*

**Symptom:** captured values are `$null`, for example `$capturedCalls[n].Method | Should -Be 'PUT'`
returns `$null`.

**Rule:** declare a `param()` block that matches the mocked function's signature.

```powershell
Mock Invoke-CyberArkAPI {
    param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams,
          [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
    Set-Variable -Name capturedEndpoint -Value $PSBoundParameters.Endpoint -Scope Script
    [PSCustomObject]@{ IsSuccess = $true }
}
```

---

## 6. `{ $r = ... } | Should -Not -Throw` never assigns `$r` in the `It` scope

*Old: §2.6, §32*

**Symptom:** `$r` is still `$null` after the call succeeded. Without strict mode, `$r.Failures | Should -Be 1`
fails with a comparison mismatch that looks like a functional bug. Under strict mode (the full suite),
it throws `PropertyNotFoundException` (e.g. `The property 'Successes' cannot be found`), which matches the
"fails only in the full suite" pattern in §15. Three `Invoke-ApplicationsAdd.Tests.ps1` tests (two older
ones and one new one) were wrongly logged as unexplained pre-existing failures because of this. RL08a
in `Invoke-ReportsList.Tests.ps1` was the same bug.

**Cause:** the piped scriptblock runs in a child scope, so the assignment creates a local variable. This
happens with or without strict mode, and without Pester too.

**Rule:** when you need the return value, assign it directly. An unexpected exception still fails the test
with its message. Use `{ ... } | Should -Not -Throw` only when nothing inside is read afterwards. If you
really need both, assign with `Set-Variable -Scope Script` inside the block, then read `$script:r`.

```powershell
# Wrong
$result = $null
{ $result = Invoke-Something -Param $x } | Should -Not -Throw
$result.Failures | Should -Be 1
# Correct
$result = Invoke-Something -Param $x
$result.Failures | Should -Be 1
```

---

## 7. A pagination mock must end with a partial page

*Old: §3.3*

**Symptom:** the test hangs.

**Cause:** the pagination loop continues while `$collection.Count -eq $PageSize`.

**Rule:** the last mocked response must return fewer items than `$PageSize`. An empty `value` array
works.

```powershell
$page1 = '{"value":[{"id":"1"},{"id":"2"}],"count":4}'; $page2 = '{"value":[{"id":"3"},{"id":"4"}],"count":4}'
$page3 = '{"value":[],"count":4}'   # 0 < PageSize, so the loop ends
Mock Invoke-WebRequest {
    $script:callCount++
    if     ($script:callCount -eq 1) { [PSCustomObject]@{ StatusCode = 200; Content = $page1 } }
    elseif ($script:callCount -eq 2) { [PSCustomObject]@{ StatusCode = 200; Content = $page2 } }
    else                             { [PSCustomObject]@{ StatusCode = 200; Content = $page3 } }
} -ModuleName 'CyberArkComms'
```

---

## 8. Success-path tests must pass every module-level validation

*Old: §9.4*

**Symptom:** `$result.Successes | Should -BeGreaterThan 0` gets 0, and the mocked API is never called.

**Cause:** `InputData` included only the primary key. Validation returned early with `Failures = 1`.
Missing fields: `NewCredentials` in `Invoke-AccountsChangeInVault.Tests.ps1`, `ExtraPasswordIndex`,
`Name` and `Safe` in `Invoke-AccountsLinkAccount.Tests.ps1`, and `ExtraPasswordIndex` in
`Invoke-AccountsUnlinkAccount.Tests.ps1`. Later, a LinkAccount test failed because it used `Name`/`Safe`
where the schema expects `LinkName`/`LinkSafe`.

**Rule:** read the module's validation section first, and supply every required field under its exact
schema key. Failure-path tests leave them out on purpose.

---

## 9. Write WhatIf tests only for mutating methods

*Old: §9.5*

**Symptom:** a mock that throws `'Should not be called in WhatIf mode'` is called, so the test fails.

**Cause:** `Invoke-CyberArkAPI` suppresses a call only when `$WhatIfPreference` is set **and** the method
is `POST`, `PUT`, `PATCH` or `DELETE`. `GET` always runs. `Invoke-AccountsGetActivity` uses `GET`.

**Rule:** a GET-only module, or one with `SupportsWhatIf = $false`, has no WhatIf `Context`. Don't change
the mock to make such a test pass, because that hides the misunderstanding. For where the module's WhatIf
check belongs, see Module-Conventions §1.

---

## 10. `(Get-X -split "`n")` passes `-split` as a parameter

*Old: §2.3*

**Symptom:** `$line` holds the whole file, so segment lengths are wrong (52 instead of 8).

**Cause:** inside the parentheses, `Get-X -split ...` is parsed in command mode, so `-split` becomes a
named argument that `Get-X` ignores.

```powershell
$line = (Get-LatestLogContent -split "`n") | Where-Object { $_ -match 'marker' }   # wrong
$line = (Get-LatestLogContent) -split "`n" | Where-Object { $_ -match 'marker' }   # correct
```

---

## 11. `Should -Match [char]0x2026` matches the literal text, not the character

*Old: §2.4*

**Symptom:** `Expected regular expression '[char]0x2026' to match '...…...', but it did not match.`

**Cause:** in command mode, the argument is the string `[char]0x2026`, a regex character class.

```powershell
$field.Contains([char]0x2026) | Should -BeTrue
$field | Should -Match ([char]0x2026)     # parentheses force expression mode
```

---

## 12. Splitting on `|` keeps the spaces from ` | ` separators

*Old: §2.5*

**Cause:** for `"$pidField | $tsField | $lvlField"`, `-split '\|'` gives `"  18560 "` (8 characters for a
7-character PID), `" 2026-08-15 10:00:00 "` (21 characters) and `"  INFO   "` (9 characters).

```powershell
($levelField.Length - 2) | Should -Be 7
$pidField.TrimEnd().Length | Should -Be 7
$levelField.Trim() | Should -Be 'WARN'
```

---

## 13. Don't put `<Word>` in an `It` or `Describe` name

*Old: §38*

**Symptom:** `'D19 - user accepts rename: renames to 1_DEL_<SafeName>, reports Success not Failure'`
passed on its own, but in the full suite it failed with `RuntimeException: The variable '$SafeName' cannot
be retrieved because it has not been set`.

**Cause:** Pester v6 (like v5) treats `<Name>` in a test name as a `-ForEach` template token, and tries to
resolve it even when `-ForEach` isn't used. Whether that throws depends on what earlier tests left in
scope.

**Rule:** use angle brackets only for real `-ForEach` placeholders. For example, write
`renames to 1_DEL_ prefix plus SafeName`.

---

## 14. `Invoke-Pester -Configuration` returns nothing unless `PassThru` is set

*Old: §9.6*

**Symptom:** `The property 'FailedCount' cannot be found on this object. Verify that the property exists.
At Run-Tests.ps1:113 char:17`, even though the name is correct for Pester v6.

**Rule:** set `$config.Run.PassThru = $true` in `Run-Tests.ps1` and in any script that reads the result.
Result properties: `FailedCount`, `PassedCount`, `SkippedCount`, `TotalCount` (int); `Failed`, `Passed`,
`Tests` (`List[Pester.Test]`); `Duration` (`TimeSpan`).

```powershell
$config = New-PesterConfiguration
$config.Run.Path = $path
$config.Run.PassThru = $true
$result = Invoke-Pester -Configuration $config
```

---

## 15. Failures that appear only in the full suite: investigate with strict mode

*Old: §9.9 (complication, audit, rule), §32 (follow-up), §36 and §38 (run-the-full-suite rules)*

**Symptom:** a test fails in `Tests\Run-Tests.ps1` but passes on its own. It also failed before your
change, as shown via `git stash`.

**Cause:** the full suite runs under strict mode, and a single file usually doesn't (StrictMode §1). "Also
failed before my change" rules out *your change*. It does not rule out a real bug that only strict mode
currently exposes. Earlier sessions filed failures in `Invoke-SafesAdd`, `Invoke-SafesUpdate`,
`Invoke-AccountsList` and other files as cross-file pollution. Fixing the two array-collapse instances in
`Invoke-SafesAddFromTemplate.ps1` cleared all of that file's full-suite failures.

**Audit results** (five parallel investigations, same day). The full suite went from 44 failures to 1:
- `Invoke-SafesAdd.ps1` / `Invoke-SafesUpdate.ps1`: real production bugs, hashtable dot notation on the
  retention keys, which made WhatIf always crash (StrictMode §2).
- `Invoke-SafeMembersList.ps1`: a different real bug. A per-safe API failure branch, added in a refactor,
  never recorded the failure on `$result`, so errors were silently dropped. One latent collapse instance
  was hardened. Two of the four failing tests were stale and were rewritten.
- `Invoke-AccountsList.ps1`: no production bug. The test never initialized `$script:ActiveProfile`.
- `Invoke-AccountsLinkAccount.ps1`: no strict-mode bug. The test used the wrong `InputData` keys (§8).
  Two latent collapse instances were hardened.
- The one left was `AG06`, a stale `InputSchema` assertion that looked for an `AccountID` column. That
  column was dropped when the module moved to `AccountName`+`Safe` resolution, with `AccountID` kept as an
  optional override. It failed with `Should -Not -BeNullOrEmpty`, not an exception, and was fixed by
  checking the declared columns. §9.9 named the file `Invoke-AccountsGetCredential.Tests.ps1`. §32 and the
  current code put it in `Invoke-AccountsGet.Tests.ps1`.
- In a later round with the same `PropertyNotFoundException`-on-`$null` signature, RL08a was the
  scriptblock-scope bug (§6), and the `Invoke-CustomExportGroupMembersLocal.Tests.ps1` ISPSS groupType test
  was an array collapse (StrictMode §6).

**Rule:** add `Set-StrictMode -Version Latest` to the affected test's `It` or `BeforeEach`. Don't add it
to the file's `BeforeAll`, which risks the §1 and §16 problems. Then reproduce the failure and read the
actual exception. The same exception text can come from different bugs, or from no production bug at all.
Always run the complete `Tests\Run-Tests.ps1` before you call a test finished or commit, even for a
docs-only change.

---

## 16. A new `Describe` in `Manage-Privilege.Tests.ps1` can hang instead of failing

*Old: §9.7*

**Symptom:** after a `Describe` was added for `Invoke-FileWriteWithRetry` (shaped
`while ($true) { try { & $Action; return $true } catch { ...; if (-not (Confirm-Action ...)) { return $false } } }`),
the run hung right after printing that `Describe`'s header, even in the simplest non-throwing case.
`-Output Detailed` gave no hint.

**Cause:** not precisely known, but reliably reproduced. It is likely in the same family as #2669 (§1),
but it hangs instead of throwing. Moving `Mock Write-Host` out of the `Describe` (the §1 fix) did **not**
help.

**Diagnosis notes:**
- Copying the test file to a scratch directory is **invalid**. It finds `Manage-Privilege.ps1` two levels
  up via `Split-Path (Split-Path $PSScriptRoot)`, so the copy dot-sources the wrong path, and the errors
  look deceptively similar.
- `[Console]::Error.WriteLine('MARK-N')` breadcrumbs inside the real `It` placed the hang inside the
  helper call. They bypass a mocked `Write-Host` and stdout buffering.
- The same function, run from plain `pwsh` with no Pester (`Start-Job` + `Wait-Job -Timeout`), returned in
  well under a second. This proves the helper is correct.

**Rule:** don't unit-test a new `while`-loop driver helper by appending to `Manage-Privilege.Tests.ps1`.
If such a test hangs, check the helper with `Start-Job`/`Wait-Job -Timeout` outside Pester. If it works
there, leave it untested with an explanatory comment, like the project's other `Read-Host`-driven helpers
(see `Testing_Plan.md`).
