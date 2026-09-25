# Lessons Learned: Strict Mode (`Set-StrictMode -Version Latest`)

Strict-mode property, key, and `.Count` pitfalls under Windows PowerShell 5.1. Each entry lists the
symptom, the cause, the fix or rule, and one example. The "Old" line gives the section numbers the entry
had in the original single-file `Reference_Lessons-Learned.md`. The full old-to-new mapping is in the
index file.

Almost every entry here throws the same error text:
`PropertyNotFoundException: The property '<Name>' cannot be found on this object.`
The error text alone does not tell you which bug you have (see Pester §15).

---

## 1. Where strict mode is active, and where it is not

*Old: §4 (intro), §4.4, §9.9 (root cause)*

**Cause:** `Manage-Privilege.ps1` sets `Set-StrictMode -Version Latest` once, at the top. Every API module
is dot-sourced into that same scope, so strict mode is always on in real use. `CyberArkLogging.psm1` and
`CyberArkComms.psm1` also set it. `Tests\Run-Tests.ps1` sets it before `Invoke-Pester`, and Pester v6
runs `BeforeAll`, `BeforeEach`, `It` and `AfterAll` as child scopes, so the setting reaches them.

**The gap:** a module's own `*.Tests.ps1` dot-sources only the module file (plus the Logging and Comms
modules), never `Manage-Privilege.ps1`. So strict mode is **not** active when one module's tests run on
their own. `Manage-Privilege.Tests.ps1` is the exception, because it dot-sources the driver. Once that file
has set strict mode, the setting is not fully contained to its own Pester container and can affect later
containers in the same run. The result is failures that appear only in the full suite (Pester §15).

**Rule:** write all module code as if strict mode is always active:
- Bracket notation for every hashtable key (§2).
- A `PSObject.Properties` guard for every optional PSCustomObject property, at every level (§4).
- Wrap anything that can return zero, one or many items in `@(...)` before using `.Count` (§6).

A module that "works" at the REPL can still fail in the suite. Treat those failures as real bugs.

---

## 2. Hashtable keys: always use bracket notation, never dot notation

*Old: §4.1, §4.5, §37*

**Symptom:** `PropertyNotFoundException: The property 'SafeName' cannot be found on this object.`, often
on the line right after `if (-not $InputData) { $InputData = @{} }`.

**Cause:** under strict mode, `$h.Key` throws when the key is **absent**, while `$h['Key']` returns
`$null`. The two look the same when the key is present. Blank and absent are different: a CSV row
missing a column, or a direct caller that leaves out an optional key, makes the key absent.

**Rule:** use `$h['Key']` for every `InputData`, `Defaults`, `ModuleMeta`/`$meta` or other hashtable
whose keys are optional or set by the caller. `$h.ContainsKey('X')` is a method call, so it is always
safe, and `$h.ContainsKey('X') -and $h.X` is safe because `-and` short-circuits. Only unguarded dot
access is unsafe.

```powershell
if (-not $InputData) { $InputData = @{} }
# Wrong: throws when ManagingCPM is absent (not just blank)
$cpm = if ($InputData.ManagingCPM) { $InputData.ManagingCPM } else { '' }
# Correct
$cpm = if ($InputData['ManagingCPM']) { $InputData['ManagingCPM'] } else { '' }
```

**Recorded cases:**
- **`$Defaults` in `Get-<Category><Action>Input` (fixed 2026-08-15):** on a first interactive run the
  driver passes `$null`, the function turns it into `@{}`, and every `$Defaults.X` throws at the first
  `Show-FieldPrompt -Default $(if ($Defaults.SafeName) ...)`.
- **`ModuleMeta.AutoSaveCsv`:** the user reported this live as a `[FATAL] PropertyNotFoundException` in
  `Invoke-ActionModule` (`Manage-Privilege.ps1`). It hit every module except the 4 that declare the key.
  The other `$meta.<Field>` reads were safe only because they read fields every module defines (`Name`,
  `Category`, `Action`). This was the first *optional* field read with dot notation. Before you add an
  optional `ModuleMeta` field, use bracket notation from the start.
- **`$InputData.Key` in `Invoke-*` functions:** a full live end-to-end pass against a real Self-Hosted
  PVWA crashed on the first write call. `Invoke-SafesAdd` threw on `ManagingCPM`. All 1052 unit tests
  passed at the time, because every fixture supplies every key, even when blank. A grep for
  `$InputData\.[A-Za-z]` across all 65 API modules found 9 more instances in `Invoke-SafesAdd`,
  `-SafesUpdate`, `-SafesUnassignCPM`, `-SafesAssignCPM`, `-SafeMembersRemove`, `-GroupsDelete`,
  `-GroupsUpdate` and `-GroupsAdd`. The 2026-08-15 `$Defaults` pass had never touched these.
- **`$body.NumberOfVersionsRetention` / `$body.NumberOfDaysRetention`:** found in
  `Invoke-SafesAdd.ps1` (WhatIf and result mapping) and `Invoke-SafesUpdate.ps1` (WhatIf). The two
  retention keys are mutually exclusive, so one is always absent, and **WhatIf crashed every time**. The
  same shape was fixed in `Invoke-SafesAddFromTemplate.ps1`.

**Testing note:** a suite whose fixtures always populate every key cannot reach the "key absent" path.
Add at least one fixture that leaves out optional keys entirely.

---

## 3. `PSObject.Properties['Key']` on a hashtable never finds its keys

*Old: §4.7*

**Symptom:** a flag in a metadata hashtable (e.g. `ExcludeFromExportAll = $true`) is never detected, and
the filter lets every item through.

**Cause:** `$ht.PSObject.Properties` lists the hashtable object's own .NET members (`Count`, `Keys`,
`Values`, `IsFixedSize`, ...) plus ETS members. It does not list key-value entries, so
`$ht.PSObject.Properties['SomeKey']` is always `$null`.

**Rule:** `PSObject.Properties['X']` is for **PSCustomObject** (JSON responses). For a **hashtable**, use
`$ht['X']` or `$ht.ContainsKey('X')`. Know which type you have before choosing.

```powershell
# Wrong: always $null for a hashtable entry
Where-Object { -not ($_.Meta.PSObject.Properties['ExcludeFromExportAll'] -and $_.Meta.ExcludeFromExportAll) }
# Correct
Where-Object { -not $_.Meta['ExcludeFromExportAll'] }
```

---

## 4. PSCustomObject properties: guard every level with `PSObject.Properties`

*Old: §4.2, §7.2, §24*

**Symptom:** `PropertyNotFoundException` on `createdTime`, `email` or `status` inside a response-mapping
block, even though the parent was checked. This caused the AccountsAdd crash on
`$acct.secretManagement.status`.

**Cause:** a JSON response is a `PSCustomObject`. When the API leaves out an optional field, the property
does not exist. A guard on `$obj.parent` does not prove that `child` exists on `$obj.parent`.

**Rule:** at every level of a property chain, check `PSObject.Properties['name']` before you read the
value. `PSObject.Properties['x']` returns `$null` (it doesn't throw) when the property is absent. This
applies to `personalDetails.email`, `secretManagement.status`, `directory.directoryType` and similar
fields. Add `try/catch` around conversions of values that might be malformed, such as epoch timestamps.

```powershell
$cpmStatus = if ($acct.PSObject.Properties['secretManagement'] -and $acct.secretManagement -and
                 $acct.secretManagement.PSObject.Properties['status']) {
    $acct.secretManagement.status
} else { '' }

$created = if ($acct.PSObject.Properties['createdTime'] -and $acct.createdTime) {
    try { [DateTimeOffset]::FromUnixTimeSeconds($acct.createdTime).LocalDateTime.ToString('yyyy-MM-dd') } catch { '' }
} else { '' }
```

`PSObject.Properties` matching is exact about the property name. A guard that uses the wrong case
fails silently (CyberArk-API §13).

---

## 5. `$null.PSObject` is `$null`: check for null before `.PSObject.Properties`

*Old: §27*

**Symptom:** `PropertyNotFoundException: The property 'Properties' cannot be found on this object`, on a
line that looks already guarded.

**Cause:** in PS 5.1, `$null.PSObject` returns `$null`, so `.Properties` on it throws. This usually
happens when the API returned `"value": null` and the code reads
`$response.Data.value.PSObject.Properties['id']`. Also, `@($null)` is a one-element array that holds
`$null`, not an empty array, so a pipeline over it passes `$null` as `$_`.

**Rule:** check `$null -ne $x` before `$x.PSObject.Properties`. A truthiness check is not enough, because
it passes for a non-null but empty PSObject. In `Where-Object`, start with `$_ -and`.

```powershell
if ($null -ne $response.Data.value -and $response.Data.value.PSObject.Properties['id']) { ... }

$acctList | Where-Object {
    $_ -and (($_.PSObject.Properties['name'] -and $_.name -eq $accountName) -or
             ($_.PSObject.Properties['userName'] -and $_.userName -eq $accountName))
}
```

---

## 6. Zero or one item collapses: wrap the whole expression in `@(...)` before `.Count`

*Old: §4.3, §4.6, §9.8, §36*

**Symptom:** `PropertyNotFoundException: The property 'Count' cannot be found on this object`, only when
the result has exactly zero or exactly one item. With 2 or more items it works, so the bug can hide for
months.

**Cause:** PowerShell unrolls output onto the pipeline.
- **Zero items:** a branch whose last statement is `@()` (or `@($emptyArray)`) emits nothing, so
  `$x = if (...) { @(...) } else { @() }` assigns `$null`. An `[array]` type constraint does not help,
  because it applies to what was emitted, which is nothing.
- **One item:** the caller receives the lone object, not a one-element array. A `[PSCustomObject]` has
  no `.Count`. `Get-ChildItem` that finds exactly one file returns a single `FileInfo`.
- The same applies to function return values and to inline `($list | Where-Object {...}).Count`.

| Case | Without `[array]` | With `[array]` only | With outer `@(...)` |
|---|---|---|---|
| 0 items | `$null` | still `$null` | empty array |
| 1 item | bare object | one-element array | one-element array |
| 2+ items | `Object[]` | `Object[]` | `Object[]` |

**Rule:** wrap the **entire** right-hand side (`if/else`, pipeline or function call) in one outer
`@(...)`. Don't wrap just the branch that has content, and don't assume a bare `@()` literal is safe.
Drop the `else`, because a false `if` emits nothing and `@(...)` turns that into an empty array. Tests
need the same wrap as product code. For extra safety, keep the empty check null-safe:
`if ((-not $items) -or $items.Count -eq 0)`.

```powershell
# Wrong
[array]$x = if ($cond) { @($thing) } else { @() }
($r.Results | Where-Object { $_.ItemType -eq 'Safe' }).Count
# Correct
[array]$x = @(if ($cond) { $thing })
@($r.Results | Where-Object { $_.ItemType -eq 'Safe' }).Count
[array]$searchInOptions = @(script:Get-SafeMembersSearchInOptions -Token $Token)
```

**Recorded cases:**
- **2026-08-20, production, PS 5.1:** `Get-SafeMembersAddInput` (`Invoke-SafeMembersAdd.ps1`) captured
  `script:Get-SafeMembersSearchInOptions` without `@()`. When the directory lookup failed, the result was a
  single Vault-only item, it unwrapped to a bare object, and `.Count` threw. Unit tests passed because they
  ran under `pwsh` (see §7). Fixed with the `@()` line above.
- **Production crash reported by the user (1.3.2):** `Get-SafesAddFromTemplateInput`
  (`Invoke-SafesAddFromTemplate.ps1`) built `[array]$cpmList = if (cond) { @(...) } else { @() }`. Any
  profile without `CPM_List` took the `else` branch and crashed the session loop. `$templateMembers` and
  `$excludedNames` in the same file had the same latent bug. `$script:ExcludedTemplateMemberNames` ships
  non-empty, and a template safe with zero members is uncommon but valid. Existing tests T09a/T09b set
  that list to `@()` and still passed, because those tests do not run under strict mode (§1).
- **Test-only false failure:** the regression test for that fix (T31 in
  `Tests\Unit\Invoke-SafesAddFromTemplate.Tests.ps1`) used unwrapped `(... | Where-Object).Count` and
  threw the same exception. The same thing happened in the ISPSS groupType test in
  `Invoke-CustomExportGroupMembersLocal.Tests.ps1`.
- **Single-item case, live user report:** "List Accounts gives this error when there is 1 result."
  `Invoke-ActionModule` built `$tableData = if ($meta.Action -eq 'List') { @(...) } else { @($result.Results) }`.
  With one row, `$tableData` became the bare object. Fixed with `$tableData = @(if (...) {...} else {...})`.
  No `[array]` cast was needed. `$displayData`, two lines later, had the same latent bug and got the same
  fix.
- **7 test failures found in a pre-commit run:** MA24/MA27/MA28 (`Invoke-SafeMembersAdd.Tests.ps1`) and
  T08/T23/T27/T28 (`Invoke-SafesAddFromTemplate.Tests.ps1`) all read `.Count` on a one-item result without
  `@()`. The product code already wrapped these calls, so none of them was a live bug. Run the full suite
  before every commit, even a docs-only one.

---

## 7. Reproduce collection-collapse bugs in `powershell.exe`, not `pwsh`

*Old: §4.3 (takeaway), §9.8 (extended rule)*

**Symptom:** a fix "passes" in a PowerShell 7 session but still crashes for users.

**Cause:** PowerShell 7 gives every scalar a synthetic `Count` property that returns `1`, so `.Count` on a
collapsed single object works there, even though `-is [array]` is `$false`. Windows PowerShell 5.1, the
runtime this project ships on, does not have that property. This session's tooling runs unit tests under
`pwsh`, which hid the 2026-08-20 and `$tableData` bugs in §6.

**Rule:** a passing test under `pwsh` does not prove a return value is safe to unwrap under PS 5.1.
Reproduce and verify strict-mode collection bugs with `powershell.exe`, and wrap captures in `@()`
whatever the tests show.
