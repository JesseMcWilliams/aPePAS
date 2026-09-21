# Lessons Learned — PowerShell 5.1 & Pester v6

Patterns discovered during unit test development for the Idira Unified Scripts project.
Each entry describes the root cause, the symptom, and the correct pattern.

---

## 1. PowerShell 5.1 Compatibility

### 1.1 `return if (...)` is not valid in PS 5.1

**Root cause:** In PowerShell 7+, `if` can be used as an expression (it returns a value).
In PS 5.1, `if` is a statement only — it cannot follow `return`.

**Symptom:** `ParserError: Unexpected token 'if'` when running under PS 5.1.

**Wrong:**
```powershell
return if ($map.ContainsKey($Code)) { $map[$Code] } else { "HTTP $Code" }
```

**Correct:**
```powershell
if ($map.ContainsKey($Code)) { return $map[$Code] } else { return "HTTP $Code" }
```

---

### 1.2 Ternary `?:`, null-coalescing `??`, and null-conditional `?.` are PS 7+ only

**Root cause:** These operators were introduced in PowerShell 7. PS 5.1 throws a parser error.

**Symptom:** `ParserError` or unexpected behavior on any host running PS 5.1 (Windows PowerShell).

**Wrong:**
```powershell
$value = $x ?? 'default'
$name  = $obj?.Name
$label = $flag ? 'yes' : 'no'
```

**Correct:**
```powershell
$value = if ($x) { $x } else { 'default' }
$name  = if ($obj) { $obj.Name } else { $null }
$label = if ($flag) { 'yes' } else { 'no' }
```

---

### 1.3 UTF-8 without BOM causes parse errors in PS 5.1

**Root cause:** PS 5.1 defaults to Windows-1252 encoding. If a `.psm1` or `.ps1` file is saved
as UTF-8 without BOM and contains non-ASCII characters (e.g. em dash `—`, ellipsis `…`),
PS 5.1 misreads the bytes and produces garbled tokens that cascade into parser errors.

**Symptom:** Cryptic parse errors on lines that look correct, especially near special characters.
The em dash `—` (U+2014, bytes E2 80 94) is decoded as `"` (right double-quote, U+201D) in
Windows-1252, which terminates double-quoted strings.

**Fix:** Save all `.ps1` and `.psm1` files as **UTF-8 with BOM**.
In VS Code: bottom-right encoding selector → "Save with Encoding" → UTF-8 with BOM.
In PowerShell: `$content | Set-Content -Path $file -Encoding UTF8` (PS 5.1 writes BOM with this flag).

---

## 2. Pester v6 Mock Patterns

### 2.1 `$PSBoundParameters` is empty in mock scriptblocks without `param()`

**Root cause:** Pester v6 does not populate `$PSBoundParameters` inside a mock scriptblock
unless parameters are explicitly declared with a `param()` block.

**Symptom:** Any assertion against `$PSBoundParameters.SomeParam` returns `$null`.
`$capturedCalls[n].Method | Should -Be 'PUT'` → got `$null`.

**Wrong:**
```powershell
Mock Invoke-CyberArkAPI {
    Set-Variable -Name capturedEndpoint -Value $PSBoundParameters.Endpoint -Scope Script
    [PSCustomObject]@{ IsSuccess = $true }
}
```

**Correct:**
```powershell
Mock Invoke-CyberArkAPI {
    param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams,
          [switch]$WhatIf, [switch]$IgnoreSSL,
          $PageSizeParam, $PageOffsetParam, $PageSize)
    Set-Variable -Name capturedEndpoint -Value $PSBoundParameters.Endpoint -Scope Script
    [PSCustomObject]@{ IsSuccess = $true }
}
```

The `param()` block must match the mocked function's signature. After adding it,
`$PSBoundParameters` is populated correctly and capture patterns work.

---

### 2.6 Variable assignment inside `{ } | Should -Not -Throw` does not escape to the `It` scope

**Root cause:** The scriptblock passed to `Should -Not -Throw` runs in its own child scope.
A variable assigned inside that block (`$r = Invoke-X`) is local to the scriptblock, not to
the surrounding `It` block. The outer `$r` remains `$null`.

**Symptom:** `PropertyNotFoundException: The property 'Successes' cannot be found` — `$r` is
`$null` in the `It` block even though the function succeeded inside the scriptblock.

**Wrong:**
```powershell
It 'does not throw on null input' {
    $r = $null
    { $r = Invoke-MyModule -Token $t -InputData $null } | Should -Not -Throw
    $r.Successes | Should -Be 0   # $r is still $null here
}
```

**Correct (option A — use `$script:` scope inside the block):**
```powershell
It 'does not throw on null input' {
    { Set-Variable -Name r -Value (Invoke-MyModule -Token $t -InputData $null) -Scope Script } |
        Should -Not -Throw
    $script:r.Successes | Should -Be 0
}
```

**Correct (option B — only test that it does not throw; drop the result assertion):**
```powershell
It 'does not throw on null input' {
    { Invoke-MyModule -Token $t -InputData $null } | Should -Not -Throw
}
```

Option B is simpler and sufficient when the goal is just to verify no exception is raised.
Behavior assertions (Successes, Failures, IsFatal) belong in separate tests with controlled
non-null InputData.

---

### 2.2 Helper functions defined outside `BeforeAll` are not accessible inside `It` blocks

**Root cause:** In Pester v6, the execution scope for `It` blocks is different from the file's
top-level scope. Functions defined at the top level with `script:` prefix are not reliably
accessible inside `It` blocks via `script:FunctionName` syntax.

**Symptom:** `CommandNotFoundException: The term 'script:MyHelper' is not recognized`.

**Wrong:**
```powershell
# top level of test file
function script:Get-LatestLog { ... }

It 'some test' {
    script:Get-LatestLog | Should -Not -BeNullOrEmpty
}
```

**Correct:**
```powershell
BeforeAll {
    function Get-LatestLog { ... }   # no script: prefix, inside BeforeAll
}

It 'some test' {
    Get-LatestLog | Should -Not -BeNullOrEmpty
}
```

---

### 2.3 `(Get-Function -split "\`n")` passes `-split` as an argument, not a binary operator

**Root cause:** Inside a parenthesized expression, PowerShell parses `Get-Function -split "\`n"`
in command mode. `-split` is treated as a named parameter to `Get-Function`, not as the binary
split operator. The function ignores the unknown parameter and returns the full result.
The subsequent `| Where-Object` receives the entire multi-line string as a single item,
so the filter matches the whole file instead of individual lines.

**Symptom:** `$line` contains the entire file content. Splitting `$line` by `|` gives segments
that span multiple log lines, producing unexpected lengths (e.g. 52 instead of 8).

**Wrong:**
```powershell
$line = (Get-LatestLogContent -split "`n") | Where-Object { $_ -match 'marker' }
```

**Correct:**
```powershell
$line = (Get-LatestLogContent) -split "`n" | Where-Object { $_ -match 'marker' }
```

The outer `(Get-LatestLogContent)` forces evaluation to a value first; `-split` then operates
on that value as the binary operator.

---

### 2.4 `[char]0x2026` in `Should -Match` is not evaluated as a cast

**Root cause:** `Should -Match` expects a regex pattern string. In command mode (after `|`),
`[char]0x2026` may not be parsed as a PowerShell type-cast expression. Pester receives the
literal string `[char]0x2026`, which is a valid regex character class (`[char]` = any of
c, h, a, r) followed by literal characters — it does not match the ellipsis character `…`.

**Symptom:** `Expected regular expression '[char]0x2026' to match '...…...', but it did not match.`

**Wrong:**
```powershell
$field | Should -Match [char]0x2026
```

**Correct:**
```powershell
$field.Contains([char]0x2026) | Should -BeTrue
# or force expression mode with parens:
$field | Should -Match ([char]0x2026)
```

---

### 2.5 Split by `|` includes the surrounding spaces from ` | ` separators

**Root cause:** If a log format uses ` | ` (space-pipe-space) as a field separator, splitting
by `\|` leaves one trailing space on the left segment and one leading space on the right segment.

**Example:** Format: `"$pidField | $tsField | $lvlField | ..."`
After `-split '\|'`:
- `[0]` = `"  18560 "` (7-char PID + 1 trailing space = 8 chars)
- `[1]` = `" 2026-08-15 10:00:00 "` (1 + 19 + 1 = 21 chars)
- `[2]` = `"  INFO   "` (1 + 7 + 1 = 9 chars)

**Fix:** Account for surrounding spaces in assertions, or trim before checking:
```powershell
# Check field width (subtracting 2 for the surrounding separator spaces):
($levelField.Length - 2) | Should -Be 7

# Or trim the trailing separator space before checking PID width:
$pidField.TrimEnd().Length | Should -Be 7

# Or trim completely and check the text value:
$levelField.Trim() | Should -Be 'WARN'
```

---

## 3. API Module Conventions

### 3.1 WhatIf check must come BEFORE calling `Invoke-CyberArkAPI`

**Root cause:** Tests assert `Should -Invoke Invoke-CyberArkAPI -Times 0` when WhatIf is active.
If the WhatIf check is AFTER the API call (even when passing `-WhatIf:$WhatIf.IsPresent`),
the mock records a call and the assertion fails.

**Symptom:** `Expected Invoke-CyberArkAPI to be called 0 times exactly, but was called 1 time`.

**Wrong:**
```powershell
$response = Invoke-CyberArkAPI -Token $Token -Method 'DELETE' -Endpoint $endpoint -WhatIf: $WhatIf.IsPresent

if ($WhatIf.IsPresent) {
    $result.Successes++
    return $result
}
```

**Correct:**
```powershell
if ($WhatIf.IsPresent) {
    Write-CyberArkLog -Level 'INFO' -Message "WhatIf: DELETE $endpoint would be performed."
    $result.Successes++
    $result.ItemsProcessed++
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}

$response = Invoke-CyberArkAPI -Token $Token -Method 'DELETE' -Endpoint $endpoint
```

---

### 3.2 `Add-CyberArkLogSummaryEntry` requires all four parameters

**Root cause:** All four parameters are mandatory: `-ModuleName`, `-ItemsProcessed`,
`-Successes`, `-Failures`. Omitting any one throws a `ParameterBindingException` at runtime,
even when the function is mocked (the real function may be called if the mock scope doesn't
intercept the call from a dot-sourced module).

**Symptom:** `ParameterBindingException: Cannot process command because of one or more missing
mandatory parameters: ItemsProcessed` — test fails with a terminating error.

**Wrong:**
```powershell
Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -Successes $result.Successes -Failures $result.Failures
```

**Correct:**
```powershell
Add-CyberArkLogSummaryEntry `
    -ModuleName     $ModuleMeta.Name `
    -ItemsProcessed $result.ItemsProcessed `
    -Successes      $result.Successes `
    -Failures       $result.Failures
```

Call this at every exit point that has incremented `$result.ItemsProcessed`: the WhatIf path,
the error path, and the success path.

---

### 3.3 Pagination mock must return a partial page to terminate the loop

**Root cause:** The pagination loop uses `$hasMoreByCount = ($collection.Count -eq $PageSize)`
as its continuation heuristic. If a mock always returns exactly `$PageSize` items, the loop
never terminates.

**Symptom:** Test hangs indefinitely (timeout or infinite loop).

**Fix:** The final mock response must return fewer items than `$PageSize` (including an empty
`value` array):

```powershell
$page1 = '{"value":[{"id":"1"},{"id":"2"}],"count":4}'   # 2 items = PageSize → more pages
$page2 = '{"value":[{"id":"3"},{"id":"4"}],"count":4}'   # 2 items = PageSize → more pages
$page3 = '{"value":[],"count":4}'                          # 0 items < PageSize → loop ends

Mock Invoke-WebRequest {
    $script:callCount++
    if     ($script:callCount -eq 1) { [PSCustomObject]@{ StatusCode = 200; Content = $page1 } }
    elseif ($script:callCount -eq 2) { [PSCustomObject]@{ StatusCode = 200; Content = $page2 } }
    else                             { [PSCustomObject]@{ StatusCode = 200; Content = $page3 } }
} -ModuleName 'CyberArkComms'
```

---

## 4. PS 5.1 Strict Mode (`Set-StrictMode -Version Latest`)

`Set-StrictMode -Version Latest` is active in both `CyberArkLogging.psm1` and `CyberArkComms.psm1`,
and is also set in `Run-Tests.ps1` before calling `Invoke-Pester`. Because Pester executes test
scriptblocks as child scopes, strict mode propagates into every `It`, `BeforeAll`, and `BeforeEach`
block. This surfaces latent bugs in module code when running tests, even if the code works at the
REPL without strict mode enabled.

---

### 4.1 Hashtable dot notation on missing keys throws `PropertyNotFoundException`

**Root cause:** Under `Set-StrictMode -Version Latest`, accessing a key that does not exist in a
hashtable via dot notation (`.`) throws `PropertyNotFoundException`. This affects every
`$InputData.KeyName` access where the key may be absent — including optional fields and the case
where `$InputData` was set to `@{}` from a null parameter.

**Symptom:** `PropertyNotFoundException: The property 'SafeName' cannot be found on this object.`
Usually at the line immediately after `if (-not $InputData) { $InputData = @{} }`.

**Wrong:**
```powershell
if (-not $InputData) { $InputData = @{} }
$safeName = if ($InputData.SafeName) { $InputData.SafeName } else { '' }
```

**Correct — always use bracket notation for hashtable key access:**
```powershell
if (-not $InputData) { $InputData = @{} }
$safeName = if ($InputData['SafeName']) { "$($InputData['SafeName'])".Trim() } else { '' }
```

Bracket notation (`['Key']`) returns `$null` safely when the key is absent. Apply this to
**every** `$InputData` access — required fields, optional fields, and body-building expressions.

**This rule applies equally to `$ModuleMeta`/`$meta` hashtables, not just `$InputData`.** This
exact bug recurred in `Manage-Privilege.ps1` (reported live by the user as a `[FATAL]
PropertyNotFoundException` on `AutoSaveCsv` at `Invoke-ActionModule`, hit via *any* module lacking
that key - i.e. every module except the 4 that declare it) when a new optional `ModuleMeta` field
(`AutoSaveCsv`) was added and read as `$meta.AutoSaveCsv` instead of `$meta['AutoSaveCsv']`. Every
other `$meta.<Field>` access in that file was already safe only because it happens to read a field
every module's `$ModuleMeta` always defines (`Name`, `Category`, `Action`, etc.) - this was the
first *optional* field ever read that way. Before adding a new optional `ModuleMeta` field, check
this section (and 4.7 below) first, and use bracket notation from the start.

---

### 4.2 PSCustomObject optional property access throws `PropertyNotFoundException`

**Root cause:** API responses deserialized from JSON are `PSCustomObject` instances. If the API
omits an optional field (e.g. `createdTime` when no creation time is available), that property
does not exist on the object. Accessing it with dot notation under strict mode throws.

**Symptom:** `PropertyNotFoundException: The property 'createdTime' cannot be found on this object.`
Inside a response-mapping block, typically after a successful `IsSuccess` check.

**Wrong:**
```powershell
$createdDate = if ($acct.createdTime) {
    [DateTimeOffset]::FromUnixTimeSeconds($acct.createdTime).LocalDateTime.ToString('yyyy-MM-dd')
} else { '' }
```

**Correct — guard with `PSObject.Properties` before accessing:**
```powershell
$createdDate = if ($acct.PSObject.Properties['createdTime'] -and $acct.createdTime) {
    try { [DateTimeOffset]::FromUnixTimeSeconds($acct.createdTime).LocalDateTime.ToString('yyyy-MM-dd') }
    catch { '' }
} else { '' }
```

`$obj.PSObject.Properties['fieldName']` returns `$null` (not a throw) when the property is
absent, making the outer `if` safely falsy. The inner `try/catch` guards against malformed
epoch values.

---

### 4.3 `$collection.Count` on a potentially-null collection throws

**Root cause:** In PS 5.1, the result of `@($someExpression)` can be `$null` when the inner
expression evaluates to an empty array under certain conditions. `$null.Count` throws under
strict mode. `Get-ChildItem` also returns a single `FileInfo` object (not an array) when exactly
one file is found — `.Count` does not exist on `FileInfo`.

**Symptom:** `PropertyNotFoundException: The property 'Count' cannot be found on this object.`

**Wrong:**
```powershell
if ($items.Count -eq 0) { ... }
$files = Get-ChildItem $dir -Filter '*.log' -File
$files.Count | Should -BeGreaterThan 0
```

**Correct:**
```powershell
# Null-safe check — always use this pattern for collection-empty guards:
if ((-not $items) -or $items.Count -eq 0) { ... }

# Force array semantics with @() before calling .Count:
$files = Get-ChildItem $dir -Filter '*.log' -File
@($files).Count | Should -BeGreaterThan 0
```

The `@()` wrapper forces PowerShell to treat the result as an array regardless of how many items
`Get-ChildItem` returned (zero, one, or many).

**Real-world instance (2026-08-20):** `Get-SafeMembersAddInput` in `Invoke-SafeMembersAdd.ps1`
called `$searchInOptions = script:Get-SafeMembersSearchInOptions -Token $Token` without wrapping
in `@()`. The helper always returns `$options.ToArray()`, but when it falls back to Vault-only
(the directory lookup failed or returned nothing - a single-item array), the caller's assignment
unwrapped it to a bare `PSCustomObject`, and `$searchInOptions.Count` on the next line threw
exactly the `PropertyNotFoundException` this section describes - in production, under real
Windows PowerShell 5.1. **It was not caught by unit tests**, because those tests call the helper
directly under `pwsh` (PowerShell 7 via this session's tooling), which adds a synthetic `Count`
property to scalar objects that PS 5.1 does not have - masking the exact bug this rule warns
about. Fixed with `[array]$searchInOptions = @(script:Get-SafeMembersSearchInOptions -Token $Token)`
at the call site. **Takeaway:** a passing unit test run under `pwsh` does not prove a function's
return value is unwrap-safe under PS 5.1 - always wrap a function call whose result might be a
single-item array in `@()` at the point of capture, per this section, regardless of what the
tests show.

---

### 4.6 PS 5.1: empty `@()` in a script block outputs nothing — `[array]` alone does not prevent null

**Root cause:** In PS 5.1, `@()` in a **script block body** does not write the empty array to the
pipeline — it writes the array's *contents*, which are nothing. So `$x = & { @() }` assigns
`$null` to `$x`, not an empty array. The same applies to any `if`-expression branch that produces
`@()`:

```powershell
# If the TRUE branch executes @($emptyArray), $x becomes $null — NOT @()
$x = if ($cond) { @($response.Data.value) } else { @() }
```

Adding `[array]` **only** fixes the single-item unwrap problem:

| Case | Without `[array]` | With `[array]` |
|---|---|---|
| 0 items from API | `$null` | Still `$null` — `{ @() }` outputs nothing |
| 1 item from API | bare `PSCustomObject` | `@(item)` — type coercion wraps it |
| 2+ items from API | `Object[]` (works) | `Object[]` (works) |

**Symptom:** `[array]$items = if (cond) { @($response.Data.value) } else { @() }` gives
`$null` for `$items` when the API returns 0 items, and then `$items.Count` throws.

**Fix — always pair `[array]` with the null-safe Count guard:**
```powershell
# [array] handles single-item unwrap; (-not $items) handles the empty-array-becomes-null case
[array]$items = if ($response.Data -and $response.Data.PSObject.Properties['value']) {
    @($response.Data.value)
} else { @() }

if ((-not $items) -or $items.Count -eq 0) { return $result }
```

**Alternative — two-step assignment avoids the issue entirely:**
```powershell
[array]$items = @()   # direct assignment — always an empty array, never null
if ($response.Data -and $response.Data.PSObject.Properties['value']) {
    [array]$items = @($response.Data.value)  # also direct — safe for 0, 1, or many items
}
if ((-not $items) -or $items.Count -eq 0) { return $result }
```

**Rule:** Every list module must use BOTH `[array]` on the variable declaration (to fix the
single-item unwrap) AND `(-not $items) -or $items.Count -eq 0` as the empty-check guard (to
handle the zero-item case). Never use bare `$items.Count -eq 0` without the null guard.

---

### 4.4 `Run-Tests.ps1` propagates strict mode into Pester child scopes

**Root cause:** `Run-Tests.ps1` calls `Set-StrictMode -Version Latest` before `Invoke-Pester`.
Pester v6 executes `BeforeAll`, `BeforeEach`, `It`, and `AfterAll` scriptblocks as child scopes
of the calling scope, inheriting the strict mode setting. This means any latent strict-mode bug
in production module code is surfaced when that code runs inside a test.

**Implication:** A module that "works" at the REPL may fail in the test suite due to strict mode.
Treat all test failures as genuine bugs, not test-environment artifacts.

**Rule:** Write all module code as if `Set-StrictMode -Version Latest` is always active:
- Bracket notation for all hashtable key access
- `PSObject.Properties` guard for all optional PSCustomObject fields
- `(-not $x) -or $x.Count -eq 0` for all empty-collection checks

---

### 4.5 `$Defaults` hashtable in custom input functions also requires bracket notation

**Root cause:** The `$Defaults` parameter in `Get-<Category><Action>Input` functions is a
`[hashtable]`. When the driver calls a custom input function for the first time (no prior entry to
copy), it passes `$null`, which the function body converts to `@{}`. Under
`Set-StrictMode -Version Latest`, dot notation on that empty hashtable throws
`PropertyNotFoundException` for every key that doesn't exist — which is all of them on a fresh
interactive run.

**Symptom:** `PropertyNotFoundException: The property 'SafeName' cannot be found on this object.`
at the first `Show-FieldPrompt -Default $(if ($Defaults.SafeName) …)` call, even though the
guard `if (-not $Defaults) { $Defaults = @{} }` ran correctly.

**Wrong:**
```powershell
if (-not $Defaults) { $Defaults = @{} }
$safeName = Show-FieldPrompt -Label 'Safe Name' `
    -Default $(if ($Defaults.SafeName) { $Defaults.SafeName } else { '' })
```

**Correct:**
```powershell
if (-not $Defaults) { $Defaults = @{} }
$safeName = Show-FieldPrompt -Label 'Safe Name' `
    -Default $(if ($Defaults['SafeName']) { $Defaults['SafeName'] } else { '' })
```

This applies to **every** `$Defaults` key access — not just `SafeName`. The same
`$InputData['Key']` rule from 4.1 applies identically to `$Defaults`.

### 4.7 `PSObject.Properties` on a hashtable finds object members, NOT key-value entries

**Root cause:** PowerShell hashtables (`@{}`) are `System.Collections.Hashtable` instances. When
you call `$ht.PSObject.Properties['Key']`, the Extended Type System introspects the *object itself* —
returning the hashtable's own .NET members (`Count`, `Keys`, `Values`, `IsFixedSize`, etc.) plus
any ETS script or note properties. It does **not** enumerate the hashtable's key-value entries.

This means `$ht.PSObject.Properties['SomeKey']` is **always `$null`** for any key that is a
hashtable entry, even if `$ht['SomeKey']` would return a value.

**Symptom:** A flag stored in a module metadata hashtable (e.g. `ExcludeFromExportAll = $true`)
is silently never detected. The guard always evaluates to false and every item passes the filter,
including the one that should be excluded.

**Wrong — PSObject.Properties does not see hashtable entries:**
```powershell
# $_.Meta is a hashtable with key ExcludeFromExportAll = $true
$listModules = @($script:LoadedModules | Where-Object {
    -not ($_.Meta.PSObject.Properties['ExcludeFromExportAll'] -and $_.Meta.ExcludeFromExportAll)
    # PSObject.Properties['ExcludeFromExportAll'] is always $null for a hashtable entry — never matches
})
```

**Correct — use bracket notation for hashtable key access:**
```powershell
$listModules = @($script:LoadedModules | Where-Object {
    -not $_.Meta['ExcludeFromExportAll']
})
```

**Rule:** `PSObject.Properties['Key']` is for **PSCustomObject** property existence checks (e.g.
JSON-deserialized API responses). For **hashtable** key access always use bracket notation
`$ht['Key']` or `$ht.ContainsKey('Key')`. Never mix the two: if `$Meta` is a hashtable use
`$Meta['Key']`; if it is a PSCustomObject use `$Meta.PSObject.Properties['Key']`.

---

## 5. PowerShell Reserved and Automatic Variable Names

PowerShell maintains a set of automatic variables that the runtime owns. Assigning to them
(or declaring a parameter with the same name) either throws a runtime error or silently
corrupts the variable's expected behaviour. The PSScriptAnalyzer rule
`PSAvoidAssignmentToAutomaticVariable` flags these.

### 5.1 Never use automatic variable names as parameters or local variables

**Root cause:** PowerShell's automatic variables are populated by the runtime before your code
runs. Declaring `param([string]$Profile)` or writing `$input = ...` inside a function shadows
the automatic value for that scope. Under `Set-StrictMode -Version Latest`, attempting to read
the automatic variable later can also result in `PropertyNotFoundException` if the shadowed
value is not the expected type.

`$Profile` (the user's profile script path) is particularly dangerous: a function parameter
named `-Profile` will never bind correctly when called with `-Profile $obj` because PowerShell
cannot determine whether the caller meant the automatic variable or the parameter.

**Automatic variables never to use as variable or parameter names:**

| Variable | What it is |
|----------|------------|
| `$Profile` | Path to the current user's PowerShell profile script |
| `$Error` | Circular buffer of recent errors |
| `$Host` | Current `PSHost` object |
| `$input` | Pipeline input enumerator in `process {}` blocks |
| `$Args` | Array of unbound positional arguments |
| `$Matches` | Hash of named and positional regex capture groups |
| `$null` / `$true` / `$false` | Language literals — cannot be assigned |
| `$OFS` | Output Field Separator used by `-join` |
| `$foreach` / `$switch` | Active enumerators inside `foreach` / `switch` |
| `$PID` | Current process ID |
| `$PSScriptRoot` | Directory of the running script |
| `$PSCommandPath` | Full path of the running script |
| `$PSBoundParameters` | Bound parameters for the current function |
| `$MyInvocation` | Invocation metadata for the current command |
| `$ExecutionContext` | Current execution context |

Preference variables (`$ErrorActionPreference`, `$VerbosePreference`, etc.) **may** be assigned
intentionally at the top of a script to configure behaviour — that is their purpose. They must
**not** be used as function parameter names.

**Wrong:**
```powershell
function Save-DriverProfile {
    param([PSCustomObject]$Profile)   # shadows $PROFILE automatic variable
    ...
}

It 'validates input' {
    $input = $script:ValidInput.Clone()   # shadows $input pipeline enumerator
    $input.SafeName = ''
    ...
}
```

**Correct:**
```powershell
function Save-DriverProfile {
    param([PSCustomObject]$currentProfile)   # unambiguous name
    ...
}

It 'validates input' {
    $testInput = $script:ValidInput.Clone()   # unambiguous name
    $testInput.SafeName = ''
    ...
}
```

**Rule:** Run PSScriptAnalyzer with the `PSAvoidAssignmentToAutomaticVariable` rule enabled
on all `.ps1` and `.psm1` files. Any warning from this rule must be treated as an error and
resolved before merging.

---

## 6. Driver Scope and Module Loading

### 6.1 Functions dot-sourced inside a called function are lost when it returns

**Root cause:** In PowerShell, dot-sourcing a script (`. $path`) brings the definitions from
that script into the **current scope** — which, when called from inside a function, is that
function's **local scope**. When the function returns, its local scope is destroyed, taking all
dot-sourced definitions with it. Any other function that runs later cannot see them.

In `Manage-Privilege.ps1`, `Import-APIModules` dot-sources every module file to read its `$ModuleMeta`.
This creates both `$ModuleMeta` and the module functions (`Invoke-SafeMembersList`,
`Get-SafeMembersListInput`, etc.) in `Import-APIModules`'s local scope. When
`Import-APIModules` returns to `Invoke-SessionLoop`, those function definitions vanish.

Later, `Invoke-ActionModule` (called from `Invoke-SessionLoop`) tries to call
`Get-SafeMembersListInput` by name. PowerShell searches the scope chain:
1. `Invoke-ActionModule`'s local scope
2. `Invoke-SessionLoop`'s local scope (the caller)
3. Script scope
4. Global scope

`Import-APIModules`'s scope is **not** in this chain — it returned before `Invoke-ActionModule`
was called. The function is not found.

**Symptom:** `CommandNotFoundException: The term 'Get-SafeMembersListInput' is not recognized`
at the driver's `& "Get-$($meta.Category)$($meta.Action)Input"` call. Modules without
`HasCustomInput = $true` are unaffected because they never invoke the custom input function
by name.

**Wrong — dot-source inside the discovery function (functions lost on return):**
```powershell
function Import-APIModules {
    foreach ($file in $files) {
        . $file.FullName           # functions go into Import-APIModules's local scope
        $script:LoadedModules += ...
    }
}

function Invoke-SessionLoop {
    Import-APIModules              # discovery runs, then returns — functions gone
    ...
    Invoke-ActionModule ...        # tries to call Get-SafeMembersListInput — not found
}
```

**Correct — re-dot-source in the scope that calls Invoke-ActionModule:**
```powershell
function Import-APIModules {
    foreach ($file in $files) {
        . $file.FullName           # still needed to read $ModuleMeta
        $script:LoadedModules += ...
    }
}

function Invoke-SessionLoop {
    Import-APIModules
    # Re-dot-source each file into Invoke-SessionLoop's scope so that child
    # callers (Invoke-ActionModule) can resolve module functions by name.
    foreach ($m in $script:LoadedModules) { . $m.FilePath }
    ...
    Invoke-ActionModule ...        # Get-SafeMembersListInput now in scope chain ✓
}
```

The double dot-source is intentional. `Import-APIModules` reads `$ModuleMeta` (data).
The second pass in `Invoke-SessionLoop` makes the **functions** available to all code that
runs within `Invoke-SessionLoop`'s lifetime, including child calls like `Invoke-ActionModule`.

**Rule:** If a function is called by name (via `& "FunctionName"`) from a scope that was
**not** the scope where the dot-source occurred, the function will not be found. Dot-source
at the scope level of the long-lived caller, not inside a helper that immediately returns.

---

### 6.2 Logging from a `.psm1` module when the logging module may not be loaded

**Root cause:** `CyberArkLogging.psm1` is imported by the Driver before the auth modules, so
`Write-CyberArkLog` is available in the session during live use. But auth modules can also be
imported in isolation — in Pester tests, standalone scripts, or interactive debugging — where the
logging module is not loaded. Calling `Write-CyberArkLog` directly in a `.psm1` throws
`CommandNotFoundException` in those contexts.

**Wrong — direct call breaks isolated import:**
```powershell
# Inside CyberArk.Auth.ISPSS.psm1
function Resolve-IdentityTenantURL { ...
    Write-CyberArkLog -Message "Probing $candidate" -Level 'DEBUG'   # throws if logger not loaded
}
```

**Correct — private wrapper with `Get-Command` guard:**
```powershell
# Private, not exported — only callable within this module
function script:Write-ISPSSLog {
    param([string]$Message, [string]$Level = 'DEBUG', [string]$Fn)
    if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
        Write-CyberArkLog -Message $Message -Level $Level -FunctionName $Fn
    } else {
        Write-Verbose $Message
    }
}

function Resolve-IdentityTenantURL { ...
    script:Write-ISPSSLog -Message "Probing $candidate" -Level 'DEBUG' -Fn 'Resolve-IdentityTenantURL'
}
```

**Why `script:` prefix:** The `script:` scope modifier makes the function private to the module
file. `Export-ModuleMember` cannot accidentally expose it, and it cannot collide with same-named
functions in the caller's scope.

**Why `-FunctionName` is explicit:** `Write-CyberArkLog` auto-detects the calling function name
from the call stack. When called via the wrapper, the stack frame shows `Write-ISPSSLog`, not the
real caller. Passing `-FunctionName` explicitly restores the correct function name in the log entry.

**Rule:** Never call session-level functions (from other modules) directly from inside a `.psm1`.
Gate the call with `Get-Command -ErrorAction SilentlyContinue` and fall back to a built-in
alternative (`Write-Verbose`, `Write-Warning`) so the module remains safe to import in any context.

---

## 7. Custom Input Functions and Cancellation

### 7.1 Return `$null` from a custom input function to signal cancellation

**Root cause:** Custom input functions (`Get-<Category><Action>Input`) are called from
`Invoke-ActionModule` in the driver. When the user searches for an entity and cancels (no selection
made, empty search, or nothing found), the module has no way to throw or set a flag — it must
communicate cancellation through its return value.

`Invoke-ActionModule` already checks:
```powershell
if ($null -eq $inputData) { return }   # User cancelled in custom input function
```

**Pattern:** If an ID search produces no result or the user explicitly cancels, return `$null` from the
input function to return to the action menu without running the module:

```powershell
function Get-AccountsGetInput {
    param([PSCustomObject]$Token, [hashtable]$Defaults)
    if (-not $Defaults) { $Defaults = @{} }

    $id = Show-FieldPrompt -Label 'Account ID' -Description 'ID or blank to search.'
    if (-not $id) {
        $id = Invoke-EntitySearch -Token $Token -Endpoint '/API/Accounts' `
            -SearchTerm (Show-FieldPrompt -Label 'Search') `
            -ResponseProperty 'value' -IdProperty 'id' `
            -DisplayProperties @('name','userName','address') -EntityLabel 'account'
        if (-not $id) { return $null }   # <-- cancellation signal
    }
    return @{ AccountID = $id }
}
```

**Rule:** Whenever a required field cannot be resolved (empty input + failed search), return
`$null` from the custom input function. Never call `exit` or `throw` — let the driver decide how
to handle the return.

---

### 7.2 Nested `PSObject.Properties` guard required for optional sub-fields

**Root cause:** The guard `if ($obj.PSObject.Properties['parent'])` confirms `parent` exists on
`$obj`, but does **not** confirm that sub-fields exist on `$obj.parent`. Under
`Set-StrictMode -Version Latest`, accessing `$obj.parent.child` when `child` is absent on the
nested PSCustomObject throws `PropertyNotFoundException`.

**Symptom:** `PropertyNotFoundException: The property 'email' cannot be found on this object.`
even though the outer guard `if ($user.personalDetails)` passed.

**Wrong:**
```powershell
Email = if ($user.personalDetails) { $user.personalDetails.email } else { '' }
```

**Correct — guard both levels:**
```powershell
Email = if ($user.personalDetails -and $user.personalDetails.PSObject.Properties['email']) {
    $user.personalDetails.email
} else { '' }
```

**Rule:** For any API response property accessed as `$obj.parent.child`, guard both levels:
1. `$obj.PSObject.Properties['parent']` (or simply `-and $obj.parent` as a truthiness check)
2. `$obj.parent.PSObject.Properties['child']`

This applies to all nested optional fields: `personalDetails.email`, `secretManagement.status`,
`directory.directoryType`, etc.

---

## 8. Orchestration Modules and External Queries

### 8.1 Orchestration modules can call other module entry-point functions directly

**Root cause:** All module files are re-dot-sourced into `Invoke-SessionLoop`'s scope, so
`Invoke-SafesList`, `Invoke-GroupsList`, etc. are all in the same scope at runtime. An orchestration
module (like `Invoke-CustomExportAll`) can call them with `& $fnName -Token $Token -InputData @{}`.

**Important:** `$ModuleMeta` in those called functions resolves to the last module loaded (a known
benign scope issue), so `$moduleResult.ModuleName` / `Category` / `Action` on the returned object
may be wrong. Use only `Results`, `Successes`, `Failures`, and `Errors` from the returned object.

**Pattern:**
```powershell
$fnName = "Invoke-$($module.Meta.Category)$($module.Meta.Action)"
$moduleResult = & $fnName -Token $Token -InputData @{}
# Use $moduleResult.Results, $moduleResult.Successes, $moduleResult.Failures
```

**Rule:** Orchestration modules iterate `$script:LoadedModules` (set by `Import-APIModules`). Skip
`Category = 'Custom'` to prevent recursive calls. Handle exceptions with try/catch per module so one
failure does not abort the entire export.

---

### 8.2 AD queries in PS 5.1 must use ADSI objects, not the ActiveDirectory module

**Root cause:** The ActiveDirectory PowerShell module (`Get-ADGroup`, `Get-ADGroupMember`, etc.) is
not available on all systems and is not required to be present. `System.DirectoryServices` ADSI
objects are part of .NET Framework and available in all PS 5.1 environments on domain-joined Windows.

**Symptom:** `CommandNotFoundException: Get-ADGroup` or dependency on optional RSAT tools.

**Wrong:**
```powershell
$members = Get-ADGroupMember -Identity $groupName -Recursive
```

**Correct — use DirectorySearcher:**
```powershell
$searcher = New-Object System.DirectoryServices.DirectorySearcher
$searcher.Filter = "(&(objectClass=group)(sAMAccountName=$groupSAM))"
$searcher.PropertiesToLoad.Add('distinguishedName') | Out-Null
$searcher.PropertiesToLoad.Add('member') | Out-Null
$entry = $searcher.FindOne()
if ($entry) {
    $dn  = "$($entry.Properties['distinguishedName'][0])"
    $dns = @($entry.Properties['member'])
}
```

**Property access:** `$entry.Properties['key'][0]` returns the value — ALWAYS access by bracket
index, as the value is a `ResultPropertyValueCollection`. String interpolation `"$(...)"` is needed
since `[0]` returns `[object]`, not `[string]`.

**Rule:** Use `New-Object System.DirectoryServices.DirectorySearcher` (or `DirectoryEntry`) for all
AD queries. Never use `Get-ADGroup`, `Get-ADGroupMember`, or other `ActiveDirectory` module cmdlets.
Wrap all ADSI operations in `try/catch` — domain connectivity failures must be caught gracefully.

---

### 8.3 Stack-based iteration avoids recursion depth limits for nested group traversal

**Root cause:** PowerShell's default call stack is limited (~500 frames). Recursive function calls
for deeply nested group structures (10+ levels) can exhaust the stack and throw a
`StackOverflowException`.

**Pattern — use an explicit stack instead of recursion:**
```powershell
$stack   = [System.Collections.Generic.Stack[hashtable]]::new()
$visited = [System.Collections.Generic.HashSet[string]]::new()

$stack.Push(@{ ID = $rootId; Path = $rootName; Depth = 1 })

while ($stack.Count -gt 0) {
    $current = $stack.Pop()
    if ($visited.Contains($current['ID'])) { continue }  # Prevents circular loops
    [void]$visited.Add($current['ID'])

    # Process current item, push children
    foreach ($child in $children) {
        if (-not $visited.Contains($child.ID)) {
            $stack.Push(@{
                ID    = $child.ID
                Path  = "$($current['Path']) > $($child.Name)"
                Depth = $current['Depth'] + 1
            })
        }
    }
}
```

**Rule:** For any traversal that may be more than ~3 levels deep or involves potentially circular
references, use a `Stack[hashtable]` with a `HashSet[string]` visited guard instead of recursive
function calls. This applies to both CyberArk group member traversal and AD nested group expansion.

---

### 8.4 Applications API uses legacy PIMServices endpoint and nested body wrapper

**Root cause:** The CyberArk Applications API (`WebServices/PIMServices.svc`) predates the modern
REST API (`/API/`) and uses different URL patterns and body shapes.

**Key differences from `/API/` modules:**
- Endpoint path: `/WebServices/PIMServices.svc/Applications` (not `/API/Applications`)
- List response: `{ "application": [ {...} ] }` — array under `application` key
- Get response: `{ "application": { ... } }` — single object under `application` key
- Auth methods list: `{ "authentication": [ {...} ] }` — under `authentication` key
- **Add body must be wrapped:** `@{ application = @{ AppID = ...; ... } }` (not a flat body)
- `SupportedSystems = @('SelfHosted')` — Privilege Cloud (ISPSS) does not expose this endpoint

**Correct body for Add Application:**
```powershell
$response = Invoke-CyberArkAPI `
    -Token    $Token `
    -Method   'POST' `
    -Endpoint '/WebServices/PIMServices.svc/Applications' `
    -Body     @{ application = @{ AppID = $appId; Description = $desc; Disabled = $false } }
```

**Rule:** When mapping API response fields, always check `PSObject.Properties['application']` or
`PSObject.Properties['authentication']` before accessing the inner object/array. The inner payload
may be a single object OR an array depending on the endpoint — cast with `@(...)` to normalize.

---

### 8.5 CyberArk Groups `/Members` sub-resource returns HTTP 405 on some PVWA versions

**Root cause:** The `GET /API/UserGroups/{id}/Members` endpoint does not exist in all PVWA
versions. On older or differently-patched instances it returns HTTP 405 Method Not Allowed, even
though the CyberArk documentation may list it. The correct endpoint for retrieving group members
is the bare group GET: `GET /API/UserGroups/{id}`, which returns the members inline on the group
object itself.

**Symptom:**
```
HTTP 405 The remote server returned an error: (405) Method Not Allowed.
[GET https://pvwa.company.com/PasswordVault/API/UserGroups/8/Members?offset=0&limit=1000]
```

**Wrong (sub-resource endpoint that 405s on many PVWA versions):**
```powershell
$response = Invoke-CyberArkAPI `
    -Token    $Token `
    -Method   'GET' `
    -Endpoint "/API/UserGroups/$encodedId/Members"
```

**Correct (bare group GET with `-PageSize 0` to suppress pagination):**
```powershell
$response = Invoke-CyberArkAPI `
    -Token    $Token `
    -Method   'GET' `
    -Endpoint "/API/UserGroups/$encodedId" `
    -PageSize 0
```

Use `-PageSize 0` because this is a single-resource GET (not a paginated collection endpoint).
Passing `offset` / `limit` query parameters to a single-resource endpoint may cause errors on
some PVWA versions.

**Member property name varies by PVWA version.** The inline member list may appear under any of:

| Property name | Observed in |
|---|---|
| `members` | Most common |
| `Members` | Some versions (case-sensitive in PS 5.1 PSObject access) |
| `groupMembers` | Some older versions |
| `value` | Rare (appears on some paginated wrappers) |

**Correct extraction pattern — probe each property name in priority order:**
```powershell
[array]$members = @()
if ($response.Data) {
    foreach ($prop in @('members', 'Members', 'groupMembers', 'value')) {
        if ($response.Data.PSObject.Properties[$prop] -and $response.Data.$prop) {
            [array]$members = @($response.Data.$prop)
            break
        }
    }
}
if ((-not $members) -or $members.Count -eq 0) {
    # empty — not a failure
}
```

**Rule for tests:** Mock the response using `members = @(...)` (the most common property name).
Do not mock a `*/Members` sub-resource endpoint — mock the bare group endpoint (`*/UserGroups/{id}`)
so the test verifies the actual API call the code makes:
```powershell
# Correct test mock
Mock Invoke-CyberArkAPI -ParameterFilter { $Endpoint -eq '/API/UserGroups/42' } {
    [PSCustomObject]@{
        IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null
        Data = [PSCustomObject]@{ id = 42; members = @($member1, $member2) }
    }
}
```

**Rule:** Never use the `/Members` sub-resource endpoint. Always call the bare group GET and
extract members from the response inline. Use the multi-property fallback probe loop to handle
PVWA version differences without code changes.

---

## 9. Pester v6 Test File Structure

Patterns discovered when fixing a systematic test regression across 22 test files (all new modules
created in the Custom, Applications, and extended Accounts categories). All 22 files failed with
`InvalidOperationException: A 'break' or 'continue' statement with a label that does not match any
enclosing loop escaped from your code` (Pester issue #2669).

### 9.1 `BeforeAll` must be at file level, not inside `Describe`

**Root cause:** In Pester v6.1+, a `BeforeAll` block nested **inside** a `Describe` runs inside
Pester's own internal `foreach` loop. Any `break` or `continue` statement encountered in user code
at that point — even one that lives inside a function body of an imported module and would never
execute at import time — can escape Pester's `foreach` and throw `InvalidOperationException`.
`CyberArkComms.psm1` contains `break` and `continue` inside `Invoke-CyberArkAPI`'s retry loop;
this triggered the error in every new-style test file.

**Symptom:** Every test in every new file fails immediately with the escape-loop error. Old-style
test files (that already had file-level `BeforeAll`) continue to pass unchanged.

**Wrong (all new test files had this pattern):**
```powershell
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath  = Join-Path (Split-Path (Split-Path $here)) 'APIModules\...'
$commsPath   = Join-Path (Split-Path (Split-Path $here)) 'Modules\CyberArkComms.psm1'
$loggingPath = Join-Path (Split-Path (Split-Path $here)) 'Modules\CyberArkLogging.psm1'

Describe 'Invoke-Xxx' {
    BeforeAll {                          # ← WRONG: BeforeAll inside Describe
        Import-Module $loggingPath -Force
        Import-Module $commsPath   -Force
        . $modulePath
    }
    ...
}
```

**Correct:**
```powershell
BeforeAll {                              # ← file level, before any Describe
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\...\Invoke-Xxx.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'XxxTests' -MinLevel 'ERROR'
}

Describe 'Invoke-Xxx' {
    ...
}
```

**Rule:** Always place the `BeforeAll` that imports modules at the **file level** (before any
`Describe` block). Use `$PSScriptRoot` (available in all scopes in Pester v6) instead of
`Split-Path -Parent $MyInvocation.MyCommand.Path`. Use `$script:` prefix for any variable set
in file-level `BeforeAll` that is needed inside `Describe` or `Context` blocks.

---

### 9.2 Always call `Initialize-CyberArkLog` in file-level `BeforeAll`

**Root cause:** All production modules call `Write-CyberArkLog` internally. Without initialising
the logging module, each test run spits log lines to the console and — if the default log folder
doesn't exist on the test machine — throws on first write.

**Rule:** Every test file must include `Initialize-CyberArkLog -Destination 'Console'
-ProfileName '<ModuleName>Tests' -MinLevel 'ERROR'` in the file-level `BeforeAll`, after the
module imports. Use a unique `ProfileName` per file to avoid cross-contamination of summary
entries between test files.

---

### 9.3 Driver-scope helper functions must be stubbed before Mocking

**Root cause:** Functions defined in `Manage-Privilege.ps1` (e.g. `Get-CsvSavePath`) are not imported by
the unit test file. In Pester v6, you **cannot** call `Mock SomeFunction` if `SomeFunction` does
not already exist in the session — Pester will throw `CommandNotFoundException` before the test
even runs.

**Symptom:** `CommandNotFoundException: Could not find Command Get-CsvSavePath` inside Pester's
`Mock` setup, causing every test in the `Describe` to fail.

**Fix:** Define a minimal global stub in the file-level `BeforeAll` **before** any `Mock` calls:
```powershell
BeforeAll {
    ...
    # Stub for Driver helper — not available outside Manage-Privilege.ps1
    function global:Get-CsvSavePath {
        param([string]$DefaultFolder, [string]$ModuleName)
        return $null
    }
}
```

The stub only needs to have the same parameter signature; its body can be a no-op. Pester's
`Mock` then replaces the stub in each test that needs it.

**Rule:** Any function that the module under test calls, but that lives in a file not imported by
the test, must be stubbed in `BeforeAll`. Check the module's code for `& $fnName` and bare
function calls to names not defined in `CyberArkComms.psm1` or `CyberArkLogging.psm1`.

---

### 9.4 Success tests must satisfy all module-level validation

**Root cause:** Several "Successful operation" tests only provided the minimum primary key
(`AccountID`) in `InputData` but forgot other fields the module validates as required before
calling the API. The module returned early with `Failures = 1`; the mocked API was never called.

**Symptom:** `$result.Successes | Should -BeGreaterThan 0` evaluates to 0 even though the mock
is set up correctly.

**Affected tests and the missing fields:**

| Test file | Missing required fields |
|---|---|
| `Invoke-AccountsChangeInVault.Tests.ps1` | `NewCredentials` |
| `Invoke-AccountsLinkAccount.Tests.ps1` | `ExtraPasswordIndex`, `Name`, `Safe` |
| `Invoke-AccountsUnlinkAccount.Tests.ps1` | `ExtraPasswordIndex` |

**Rule:** Before writing the success-path `It` block, read the module's validation section to
identify every field that causes an early-return failure. The success test's `InputData` must
include all required fields. The failure-path `It` blocks intentionally omit them — keep those
as-is.

---

### 9.5 `WhatIf` does not suppress `GET` operations

**Root cause:** `Invoke-CyberArkAPI` only suppresses the API call when `$WhatIfPreference` is set
**and** the HTTP method is one of `POST`, `PUT`, `PATCH`, or `DELETE`. `GET` calls execute
regardless of `-WhatIf`. `Invoke-AccountsGetActivity` uses `GET`; its test incorrectly asserted
that `-WhatIf` would prevent the API call.

**Symptom:** The mocked `Invoke-CyberArkAPI` throws `'Should not be called in WhatIf mode'`,
causing the `Should -Not -Throw` assertion to fail.

**Rule:** Only write a WhatIf test for modules that use a mutating HTTP method (`POST`, `PUT`,
`PATCH`, `DELETE`). Modules with `SupportsWhatIf = $false` in their metadata (or those that only
use `GET`) should not have a WhatIf `Context` block in their test file. If a module is read-only
(GET only), remove or omit the WhatIf context entirely — do not adjust the mock to make it pass,
because passing would mask the misunderstanding.

---

### 9.6 `Invoke-Pester` with `-Configuration` returns nothing without `PassThru`

**Root cause:** When calling `Invoke-Pester -Configuration $config`, the return value is `$null`
unless `$config.Run.PassThru = $true` is set. Without `PassThru`, Pester runs the tests and
writes output to the host, but does not return the result object to the caller. Under
`Set-StrictMode -Version Latest`, any subsequent access to result properties (`$result.FailedCount`)
throws `PropertyNotFoundException: The property '...' cannot be found on this object` because
`$result` is `$null`.

**Symptom:**
```
The property 'FailedCount' cannot be found on this object. Verify that the property exists.
At Run-Tests.ps1:113 char:17
```
even though the property name is correct for Pester v6.

**Pester v6 result properties** (for reference):

| Property | Type | Description |
|---|---|---|
| `FailedCount` | `int` | Count of failed tests |
| `PassedCount` | `int` | Count of passed tests |
| `SkippedCount` | `int` | Count of skipped tests |
| `TotalCount` | `int` | Total test count |
| `Failed` | `List[Pester.Test]` | Collection of failed test objects |
| `Passed` | `List[Pester.Test]` | Collection of passed test objects |
| `Tests` | `List[Pester.Test]` | All tests |
| `Duration` | `TimeSpan` | Total run duration |

**Wrong:**
```powershell
$config = New-PesterConfiguration
$config.Run.Path = $path
$result = Invoke-Pester -Configuration $config   # $result is $null
$result.FailedCount                               # throws PropertyNotFoundException
```

**Correct:**
```powershell
$config = New-PesterConfiguration
$config.Run.Path     = $path
$config.Run.PassThru = $true                      # required — return the result object
$result = Invoke-Pester -Configuration $config
$result.FailedCount                               # works — returns an int
```

**Rule:** Always set `$config.Run.PassThru = $true` in `Run-Tests.ps1` and any other script that
reads the Pester result object after calling `Invoke-Pester -Configuration`.

---

### 9.7 A new `Describe` appended to `Manage-Privilege.Tests.ps1` can hang instead of failing fast

**Root cause:** Unknown precisely, but reliably reproduced. Adding `Invoke-FileWriteWithRetry`
(a `Manage-Privilege.ps1` helper shaped `while ($true) { try { & $Action; return $true } catch
{ ...; if (-not (Confirm-Action ...)) { return $false } } }`) to `Manage-Privilege.ps1`, then
appending a new `Describe` block to `Manage-Privilege.Tests.ps1` that calls it — even in the
simplest, non-throwing, no-retry-needed case — caused the whole Pester run to hang indefinitely
right after printing the new `Describe`'s header, before any `It` result printed. This is a
variant of the same family as 9.1 (Pester issue #2669: `break`/`continue` label confusion from
user code interacting with Pester's own control flow), but manifests as a silent hang rather
than 9.1's fast `InvalidOperationException` — much harder to diagnose, since `-Output Detailed`
gives no indication where execution stopped.

**How this was actually diagnosed (worth repeating, since several dead ends looked promising
first):**
1. Copying `Manage-Privilege.Tests.ps1`'s content into a scratch-directory file to attempt a
   faster, isolated repro is **invalid** — the file computes its dot-source target as
   `Split-Path (Split-Path $PSScriptRoot)` (two levels up from its own location) to find
   `Manage-Privilege.ps1`. Moved to any other directory, that resolves to the wrong path, dot-
   sourcing silently no-ops or fails, and the resulting `CommandNotFoundException`-flavored
   breakage looks confusingly similar to the real bug (same `break`/`continue` exception text,
   different actual cause). Every finding produced this way was a false lead.
2. `[Console]::Error.WriteLine('MARK-N')` breadcrumbs placed directly inside the real `It` block
   (bypassing `Write-Host`, which may be mocked, and stdout buffering) pinpointed the hang to
   inside the call to `Invoke-FileWriteWithRetry` itself — after entering the `It`, after both
   `Mock` calls, but before the function returned.
3. Calling the *exact same function*, dot-sourced from the *exact same file*, from a plain
   `pwsh` session with **no Pester involved** (via `Start-Job` + `Wait-Job -Timeout`, so a real
   hang doesn't block the diagnosis) returned correctly in well under a second, every time. This
   is the decisive test: it proves the function itself is correct and the bug is specific to
   Pester's test-execution machinery interacting with this file, not a real defect.

**Fix attempted and found NOT sufficient:** Moving the offending `BeforeAll { Mock Write-Host
{} }` out of the `Describe` block (the 9.1 fix) did not resolve this — the hang persisted with
`Mock Write-Host` inlined into each `It` instead. This is not the same trigger as 9.1's.

**Rule:** Don't unit-test a new `while`-loop-shaped driver helper by appending a `Describe` to
`Manage-Privilege.Tests.ps1`, even if it looks like every existing pattern in that file. If a
new test for such a helper hangs, verify the helper directly with `Start-Job`/`Wait-Job
-Timeout` outside Pester before assuming the helper is broken — if it returns correctly there,
the helper is fine and the safest fix is to leave it untested with a comment explaining why
(consistent with the project's existing testing boundary that `Read-Host`-driven interactive
helpers aren't unit tested — see `Testing-Plan.md`), rather than spending further time chasing
this specific Pester/file interaction.

---

### 9.8 `[array]$x = if (cond) {@(...)} else {@()}` collapses to `$null`, not an empty array

**Root cause:** PowerShell auto-unrolls a script block's output onto the pipeline. An empty
`@()` emitted as a branch's last statement produces *zero* output objects - not "one empty
array object." When that's captured by an assignment, even one with an `[array]` type
constraint on the left-hand side, the result is `$null`, because the constraint applies to
what was actually emitted (nothing), not to what the literal looked like in the source. Later
code calling `.Count`, `.Length`, or indexing that variable throws `PropertyNotFoundException`
under `Set-StrictMode` - which every real invocation runs under, since `Manage-Privilege.ps1`
sets it and every API module is dot-sourced into that same scope.

**This caused a real production crash**, reported directly by the user: `Get-
SafesAddFromTemplateInput` (`Invoke-SafesAddFromTemplate.ps1`) built its CPM picker list with
`[array]$cpmList = if (cond) { @(...) } else { @() }`; any profile without `CPM_List` set took
the `else` branch, `$cpmList` became `$null`, and `$cpmList.Count` crashed the whole session
loop. The same file had two more instances of the identical pattern (`$templateMembers`,
`$excludedNames`) that hadn't crashed yet only because nobody had hit the right condition -
`$script:ExcludedTemplateMemberNames` ships non-empty by default, and a template safe with
zero members is uncommon but entirely valid.

**Wrong:**
```powershell
[array]$x = if ($cond) { @($thingWithContent) } else { @() }
```

**Correct - wrap the WHOLE if/else, not just a branch:**
```powershell
[array]$x = @(if ($cond) { $thingWithContent })
```
Dropping the `else` entirely is fine and clearer: if `$cond` is false, the `if` block itself
emits nothing, and the outer `@(...)` turns "nothing" into a real empty array either way. This
matches the pattern already used correctly elsewhere in this codebase for API-response
wrapping, e.g. `[array]$searchInOptions = @(script:Get-SafeMembersSearchInOptions -Token
$Token)` (`Invoke-SafeMembersAdd.ps1`) - the key is that the `@()` wraps the *entire*
expression that might emit zero, one, or many objects, not just whichever branch happens to
have visible content in the source.

**The same bug can hide in an inline pipeline result**, not just an `if/else`:
```powershell
# Wrong - if Where-Object matches zero items, (...).Count throws:
($list | Where-Object { $_.Foo -eq $bar }).Count

# Correct:
@($list | Where-Object { $_.Foo -eq $bar }).Count
```
This exact form caused a false failure in this codebase's own regression test for the bug
above (`Tests\Unit\Invoke-SafesAddFromTemplate.Tests.ps1`, T31) - the fix for the production
bug was correct, but the *test asserting the fix* used the same unguarded pipeline pattern
and threw the identical exception when the expected match count was zero, which then had to
be debugged as if it were a second production bug before the real cause (the test's own
assertion line) was found.

**Rule:** Whenever assigning to an `[array]`-typed variable from an `if/else`, a pipeline, or
a function call, wrap the *entire* right-hand expression in `@(...)` - never just the branch
that happens to have content, and never assume a bare `@()` literal is safe just because it
looks like an array.

**A second manifestation, found later via a live user report: exactly one item collapses to a
bare scalar, not `$null`, and this happens even with no `[array]` type constraint at all.**
`Manage-Privilege.ps1`'s `Invoke-ActionModule` built the results table with `$tableData = if
($meta.Action -eq 'List') { @(...) } else { @($result.Results) }` (no `[array]` cast on the
left-hand side). When a List action returned exactly one row, `$tableData` did not become a
one-element array - it became the single `[PSCustomObject]` itself, because PowerShell
auto-unrolls the `if` block's one-item array output onto the pipeline as a single object, and
the assignment then captures that lone object as-is. `$tableData.Count` on the next line then
threw `PropertyNotFoundException` under `Set-StrictMode` - reported directly by the user as
"List Accounts gives this error when there is 1 result." Confirmed the collapse and the fix in
real `powershell.exe` (Windows PowerShell 5.1, the project's actual runtime), not `pwsh`
(PowerShell 7+): PS7 silently masked this exact case, since PS7 added a synthetic `Count`
property (returning `1`) to every scalar object as a convenience - `.Count` on the collapsed
scalar returns `1` without error there, hiding the bug entirely in a PS7 test session even
though the type is still wrong (`-is [array]` is `$false`). The fix was the same as 9.8's:
wrap the *entire* `if/else` in one outer `@(...)`, e.g. `$tableData = @(if (...) {...} else
{...})` - no `[array]` cast was needed once the outer wrap was added. A second, identical
assignment two lines later (`$displayData = if (...) {$tableData[...]} else {$tableData}`) had
the same latent bug and was fixed the same way, even though it hadn't been reported yet.
**Rule, extended:** don't reach for `pwsh`/PowerShell 7 to "quickly check" a suspected
collection-collapse bug in this codebase - it has engine-level behavior differences from the
Windows PowerShell 5.1 this project actually ships on that can make a real bug look fixed when
it isn't. Reproduce and verify strict-mode collection bugs with `powershell.exe`.

---

### 9.9 Unit tests for individual API modules do not run under `Set-StrictMode` - and that hid the bug above

**Root cause:** `Set-StrictMode -Version Latest` is set once, at the top of
`Manage-Privilege.ps1`. Every API module is dot-sourced *into that same scope* at runtime, so
in real usage strict mode is always active. But each module's own `*.Tests.ps1` file dot-
sources only the module file itself (plus `CyberArkLogging.psm1`/`CyberArkComms.psm1`) -
never `Manage-Privilege.ps1` - so strict mode is **not** active when a module's tests run in
isolation. `Manage-Privilege.Tests.ps1` is the one exception, since it dot-sources the driver
directly.

**This is exactly why the bug in 9.8 shipped and passed every test.** The existing tests
`T09a`/`T09b` in `Invoke-SafesAddFromTemplate.Tests.ps1` already set
`$script:ExcludedTemplateMemberNames = @()` - the precise condition that collapses
`$excludedNames` to `$null` - and passed cleanly, because `.Count` on `$null` doesn't throw
without strict mode; it just doesn't crash. The bug was invisible to the test suite by
construction, not by bad luck.

**Complication found while fixing this:** running the *entire* suite via `Tests\Run-Tests.ps1`
(all files in one `Invoke-Pester` process) showed a different, larger set of failures than
running `Invoke-SafesAddFromTemplate.Tests.ps1` in isolation - because `Set-StrictMode`, once
set by `Manage-Privilege.Tests.ps1` dot-sourcing the driver, is not perfectly contained to that
file's own Pester container and can affect later-run containers in the same process. Earlier
sessions working on this codebase (see prior Documentation-Tracker.md entries referencing "N
pre-existing unrelated failures, confirmed via `git stash`") treated the full-suite-only
failures in `Invoke-SafesAdd.ps1`, `Invoke-SafesUpdate.ps1`, `Invoke-AccountsList.ps1`, and
others as unrelated cross-file pollution, on the reasoning that they predated the change being
made and reproduced identically before and after via `git stash`. That reasoning correctly
identified them as *pre-existing*, but likely mischaracterized *why*: fixing the two other
instances of the 9.8 bug in `Invoke-SafesAddFromTemplate.ps1` (`$templateMembers`,
`$excludedNames`) made every one of that file's full-suite failures disappear - strongly
suggesting the same bug class, not incidental pollution, is the actual cause in at least some
of the still-failing files. This was raised as a hypothesis, not a proven diagnosis, and
flagged for follow-up rather than acted on immediately.

**Follow-up audit (same day):** dispatched five parallel investigations, one per remaining
full-suite-only failure cluster - `Invoke-SafesAdd.ps1`, `Invoke-SafesUpdate.ps1`,
`Invoke-SafeMembersList.ps1`, `Invoke-AccountsList.ps1`, `Invoke-AccountsLinkAccount.ps1` -
each told to add `Set-StrictMode -Version Latest` to its test file's `BeforeEach`/`BeforeAll`
blocks, reproduce under strict mode, and fix whatever it found (production code, test code, or
both), following the exact methodology in this section. Results, confirming the hypothesis was
directionally right but not universally the *same* bug:

- `Invoke-SafesAdd.ps1` / `Invoke-SafesUpdate.ps1` - **real production bugs**, both Pattern C
  (dot notation on a hashtable for a maybe-missing key): `$body.NumberOfVersionsRetention` /
  `$body.NumberOfDaysRetention`, the identical mutually-exclusive-retention-keys shape already
  fixed in `Invoke-SafesAddFromTemplate.ps1`. In `Invoke-SafesAdd.ps1` this hit both the
  `WhatIf` branch and the success-result-mapping branch; in `Invoke-SafesUpdate.ps1`, the
  `WhatIf` branch only. Both meant **WhatIf mode crashed unconditionally, every time**, in real
  usage - the same severity as the original AddFromTemplate finding.
- `Invoke-SafeMembersList.ps1` - a **different real production bug**, not from section 9.8/9.9
  at all: a genuine logic/bookkeeping gap (a per-safe API failure branch, introduced by an
  earlier refactor, never recorded the failure on `$result` the way the equivalent top-level
  branch did - silently dropped errors instead of reporting them). Also found and hardened one
  latent (not-yet-crashing) Pattern A instance while in there. Two of that file's four failing
  tests turned out to be stale (asserting pre-refactor validation behavior the module
  intentionally no longer has) and were rewritten to match documented current behavior.
- `Invoke-AccountsList.ps1` - **no production bug at all**: the test file simply never
  initialized `$script:ActiveProfile`, which the module legitimately expects to exist (real
  invocations always have it, via `Manage-Privilege.ps1`). Fixed in the test file only.
- `Invoke-AccountsLinkAccount.ps1` - **also no strict-mode bug**: the single failing test used
  the wrong `InputData` hashtable keys (`Name`/`Safe` instead of the schema's `LinkName`/
  `LinkSafe`), so production correctly rejected it as a validation failure while the test
  asserted success. Reproduced identically with or without strict mode - a plain test-data
  error, unrelated to 9.8/9.9. Two latent (currently-safe) Pattern A instances were hardened
  anyway while investigating.

Net result: the full suite went from 44 failing to 1 (the pre-existing, separately-diagnosed
`AG06` InputSchema mismatch in `Invoke-AccountsGetCredential.Tests.ps1`, unrelated to any of
this). **Confirms the rule below, but also confirms it cuts both ways**: "fails only in the
full suite" is a real signal worth investigating with strict mode, but the cause found there
is not always the 9.8 array-collapse bug specifically - it can be any bug strict mode
surfaces, a genuine non-strict-mode logic error uncovered along the way, or nothing in
production at all (a test-only setup gap or a stale/wrong test).

**Rule:** Don't treat "fails only in the full suite, passes in isolation, and failed before my
change too" as proof a failure is unrelated noise safe to ignore. It rules out *your specific
change* as the cause, but it does not rule out a real bug that strict mode (leaked or direct)
is the only thing currently exposing - and per the follow-up above, don't assume that bug will
match the specific pattern you already found elsewhere. When touching a file with this
signature, add `Set-StrictMode -Version Latest` to the relevant test(s) (scoped to the
`It`/`BeforeEach`, not the file's `BeforeAll` where it can trigger the 9.1/9.7 hang risk),
reproduce, and read the actual exception rather than assuming which pattern it'll be.

---

## 10. File Encoding: UTF-8 with BOM is Required for PowerShell 5.1

### 10.1 Em-dash and other multi-byte Unicode characters silently corrupt double-quoted strings

**Root cause:** PowerShell 5.1 (`powershell.exe`) reads `.ps1` and `.psm1` files using the
Windows system ANSI codepage (typically Windows-1252 on English systems) when the file has no
Byte Order Mark (BOM). It does NOT assume UTF-8 for BOM-less files.

The UTF-8 encoding of `U+2014` (em-dash `—`) is three bytes: `0xE2 0x80 0x94`.

When decoded as Windows-1252:
- `0xE2` -> `â`
- `0x80` -> `€`
- `0x94` -> `"` (U+201D, RIGHT DOUBLE QUOTATION MARK)

PowerShell accepts `"` (U+201D) as a string terminator for double-quoted strings — it is part
of the language spec as a "typographic double quote". This means every em-dash inside a
double-quoted string silently ends that string early. Everything after the em-dash up to the
next `"` or `"` becomes bare code, producing cascading parse errors:

```
The string is missing the terminator: '.
Missing closing '}' in statement block or type definition.
The Try statement is missing its Catch or Finally block.
```

These errors are reported near the END of the function, not at the actual em-dash line, making
the root cause hard to spot.

**Symptom (runtime):**
```
WARN | Import-APIModules | Failed to load module 'Invoke-CustomExportAll.ps1':
At Invoke-CustomExportAll.ps1:128 char:35
+ ... -Level 'INFO' -Message "Export All complete. Modules: $($result.Items...
The string is missing the terminator: '.
```

**Wrong (UTF-8 without BOM, em-dash in double-quoted string):**
```powershell
# File saved as UTF-8, no BOM — PS 5.1 reads it as Windows-1252
Write-Host " — $count records" -ForegroundColor Green   # em-dash terminates the string!
```

**Correct option 1 — Save all PS files as UTF-8 with BOM:**
```
BOM bytes at start of file: 0xEF 0xBB 0xBF
```
When a BOM is present, PowerShell 5.1 correctly identifies the file as UTF-8 and all Unicode
characters are decoded properly, including em-dashes, accented letters, and any other codepoints.
This is the **recommended standard** for this project.

**Correct option 2 — Avoid non-ASCII characters in string literals:**
```powershell
# Safe on any encoding — no non-ASCII bytes in string literals
Write-Host " - $count records" -ForegroundColor Green   # plain hyphen
```
Use a regular ASCII hyphen (`-`) instead of an em-dash. This works regardless of encoding but
sacrifices typographic quality in displayed output.

### 10.2 Encoding standard for this project

All `.ps1` and `.psm1` files in this project **must** be saved as **UTF-8 with BOM**
(`UTF-8-BOM`, `utf-8-sig`, or equivalent). This ensures correct parsing by both:
- PowerShell 5.1 (`powershell.exe`) on Windows — reads BOM as UTF-8 signal
- PowerShell 7+ (`pwsh`) — reads BOM-less UTF-8 by default; also respects BOM

**In Visual Studio Code:** set `"files.encoding": "utf8bom"` in workspace settings, or choose
`UTF-8 with BOM` from the encoding picker in the status bar before saving a PS file.

**In PowerShell when writing files programmatically:**
```powershell
# Write with BOM
$utf8Bom = New-Object System.Text.UTF8Encoding $true
[IO.File]::WriteAllText($path, $content, $utf8Bom)
```

**In the `Write` tool (Claude Code):** the Write tool generates UTF-8 without BOM. Always
run the project-wide BOM conversion script after generating new PS files:
```powershell
$utf8Bom = New-Object System.Text.UTF8Encoding $true
Get-ChildItem -Recurse -Include '*.ps1','*.psm1' | ForEach-Object {
    $text = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($_.FullName, $text, $utf8Bom)
}
```

### 10.3 Affected characters and byte sequences

Any UTF-8 multi-byte sequence whose last byte maps to a string-significant character in
Windows-1252 can corrupt parsing. Known dangerous bytes:

| UTF-8 last byte | Windows-1252 char | PowerShell meaning |
|---|---|---|
| `0x94` | `"` (U+201D right double-quote) | Terminates double-quoted string |
| `0x93` | `"` (U+201C left double-quote) | Opens a new double-quoted string |
| `0x92` | `'` (U+2019 right single-quote) | Terminates single-quoted string |
| `0x91` | `'` (U+2018 left single-quote) | Opens a new single-quoted string |

Common Unicode characters that contain these dangerous last bytes in UTF-8:

| Character | Unicode | UTF-8 bytes | Danger |
|---|---|---|---|
| Em-dash `—` | U+2014 | `E2 80 94` | Double-quoted string terminator |
| En-dash `—` | U+2013 | `E2 80 93` | Double-quote opener (opens rogue string) |
| Curly `"` | U+201C | `E2 80 9C` | Double-quote opener |
| Curly `"` | U+201D | `E2 80 9D` | Double-quote terminator |
| Curly `'` | U+2018 | `E2 80 98` | Single-quote opener |
| Curly `'` | U+2019 | `E2 80 99` | Single-quote terminator |

**Rule:** Never use any of these characters in `.ps1` or `.psm1` source files unless the file
is saved with a UTF-8 BOM. In double-quoted strings, prefer plain ASCII `-` over em-dash `—`
regardless of encoding, because some editors silently strip the BOM.

---

## 11. CyberArk Identity and Privilege Cloud Runtime Behaviors

Lessons from live testing against a Privilege Cloud (ISPSS) tenant. These behaviors are not
documented in the CyberArk developer portal and vary by tenant/version.

---

### 11.1 Privilege Cloud Identity tenant URL requires multi-candidate HTTP redirect discovery

**Root cause:** The Privilege Cloud portal (`{sub}.privilegecloud.cyberark.cloud`) uses
*JavaScript-based* redirects — not HTTP 301/302 — to navigate the browser to the Identity
tenant (`{sub}.id.cyberark.cloud`). `Invoke-WebRequest` follows HTTP-level redirects but cannot
execute JavaScript, so it lands on the portal page and returns the portal's own host. Calling
`StartAuthentication` against the portal URL then returns HTTP 404 because the Identity API
path does not exist on the portal.

**Discovery approach:** Try up to three candidate URLs for the subdomain. After each attempt
(success or caught exception), check whether the response's final host matches `*.id.cyberark.cloud`.
The helper functions below extract the final host from both normal and exception paths:

```powershell
function Get-WebResponseHost {
    param($Response)
    if (-not $Response) { return $null }
    try {
        if ($Response.BaseResponse -and $Response.BaseResponse.ResponseUri) {
            return $Response.BaseResponse.ResponseUri.Host
        }
    } catch {
        # BaseResponse may be disposed or in an invalid state; treat as no host
    }
    return $null
}

function Get-ExceptionRedirectHost {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    if (-not $ex) { return $null }
    try {
        if ($ex.Response -and $ex.Response.ResponseUri) {
            return $ex.Response.ResponseUri.Host
        }
    } catch {
        # Response object may be in an invalid state (e.g. SSL/TLS or connection-level failure)
    }
    return $null
}

function Resolve-IdentityTenantURL {
    param([string]$PCloudSubdomain, [string]$ExistingIdentityHost)

    if (-not [string]::IsNullOrWhiteSpace($ExistingIdentityHost)) {
        $cleaned = $ExistingIdentityHost.Trim().Replace('https://', '').TrimEnd('/')
        return "https://$cleaned"
    }

    $candidates = @(
        "https://$PCloudSubdomain.cyberark.cloud",
        "https://$PCloudSubdomain-userportal.cyberark.cloud",
        "https://$PCloudSubdomain.privilegecloud.cyberark.cloud"
    )

    foreach ($candidate in $candidates) {
        try {
            $resp = Invoke-WebRequest -Uri $candidate -Method Get -MaximumRedirection 0 `
                -TimeoutSec 20 -ErrorAction Stop -UseBasicParsing
            $h = Get-WebResponseHost -Response $resp
            if ($h -match '\.id\.cyberark\.cloud$') { return "https://$h" }
        } catch {
            # Capture $_ immediately — any pipeline or function call overwrites it in PS 5.1
            $caughtError = $_
            $h = Get-ExceptionRedirectHost -ErrorRecord $caughtError
            if ($h -match '\.id\.cyberark\.cloud$') { return "https://$h" }
        }
    }

    return "https://$PCloudSubdomain.id.cyberark.cloud"   # direct-construct fallback
}
```

> **Note:** The null-check `if ($ex.Response -and ...)` is not sufficient. When a network or
> SSL/TLS failure occurs, `$ex.Response` may be a non-null object in an invalid internal state.
> Accessing `.ResponseUri` on such an object throws `InvalidOperationException`. Wrapping the
> property access in `try/catch` inside the helper is the correct guard. See Section 14 for the
> full catch-block safety pattern.

**Why `MaximumRedirection 0` is intentional:** Setting it to `0` means `Invoke-WebRequest` throws
on the *very first* redirect response (HTTP 301/302/307) rather than following the chain silently.
The exception object carries `exception.Response.ResponseUri`, which is the redirect *target* URL —
exactly the `*.id.cyberark.cloud` host we need. With `MaximumRedirection 8` (follow redirects),
`Invoke-WebRequest` lands on the final page after all redirects, which may be the portal itself
(a JavaScript-driven page), making the redirect target undetectable. `MaximumRedirection 0`
ensures the redirect URL is always captured in the catch block regardless of what the final page
does.

**Rule:** Cache the resolved URL in the profile's `TenantAuth` field to avoid the multi-candidate
probe on every session. Pass `TenantAuth` as `-IdentityTenantURL` when calling `Get-AuthToken` so
`Resolve-IdentityTenantURL` is skipped entirely. After each successful ISPSS login, write the token's
`IdentityURL` back to `TenantAuth` in the profile JSON (self-healing if the identity URL changes).
Never hardcode `{sub}.id.cyberark.cloud` without verifying via redirect discovery — tenant subdomain
mappings are not guaranteed to be 1:1 with the portal subdomain.

---

### 11.2 `AdvanceAuthentication` token extraction: dual field names and root-level fallback

**Root cause:** The CyberArk Identity `AdvanceAuthentication` response returns the auth token in
different locations depending on the Identity version, tenant configuration, and authentication step:

| Scenario | Token location |
|---|---|
| Normal completion (most tenants) | `$resp.Result.Token` |
| Some tenant configurations | `$resp.Result.Auth` (alternate field name) |
| After OOB approval (some Identity versions) | `$resp.Token` or `$resp.Auth` at response root; `$resp.Result` is the string `"LoginSuccess"` |
| Intermediate MFA challenge step | `$resp.Result` is a PSCustomObject but has neither `Token` nor `Auth` — the loop must continue |

Under `Set-StrictMode -Version Latest`, accessing `$resp.Result.Token` when `Token` is absent throws
`PropertyNotFoundException`. The guard `$resp.Result -isnot [string]` allows PSCustomObject responses
through but does not verify that `Token` exists on that object.

**Correct extraction pattern — guard every field and fall back to response root:**
```powershell
if ($resp) {
    $authToken = $null

    # Try Result object fields first (normal completion path)
    if ($resp.Result -isnot [string]) {
        if ($resp.Result.PSObject.Properties['Token'] -and $resp.Result.Token) {
            $authToken = $resp.Result.Token
        } elseif ($resp.Result.PSObject.Properties['Auth'] -and $resp.Result.Auth) {
            $authToken = $resp.Result.Auth
        }
    }

    # Fallback: token at response root level — seen when Result is string 'LoginSuccess'
    # on some Identity versions after OOB approval
    if (-not $authToken -and $resp.PSObject.Properties['Token'] -and $resp.Token) {
        $authToken = $resp.Token
    }
    if (-not $authToken -and $resp.PSObject.Properties['Auth'] -and $resp.Auth) {
        $authToken = $resp.Auth
    }

    if ($authToken) { return $authToken }
}
```

**OOB poll loop pattern — loop until token found, not until result string changes:**

CyberArk Identity returns two different "still pending" shapes depending on tenant version:
- `{"Result": "OobPending"}` — a plain string
- `{"Result": {"Summary": "..."}}` — a PSCustomObject with only a Summary field

A loop that checks `while ($resp.Result -is [string] -and $resp.Result -ieq 'OobPending')` exits
immediately when the server returns the PSCustomObject shape, before the user can approve the push.

**Correct approach — extract the token inside the loop and poll until it appears:**
```powershell
$oobStart   = Get-Date
$oobTimeout = 300   # 5 minutes
$oobToken   = $null
do {
    $elapsed = [int]((Get-Date) - $oobStart).TotalSeconds
    Write-Host "`r  Waiting for out-of-band approval... ($($elapsed)s)" -NoNewline
    if ($elapsed -ge $oobTimeout) {
        Write-Host ''
        throw "Authentication failed: Out-of-band approval timed out after $($oobTimeout / 60) minutes."
    }
    Start-Sleep -Seconds 5
    $resp = Invoke-IdentityAdvancedAuth -Action 'Poll' ...
    # Try all known token locations on every poll response
    if ($resp) {
        if ($resp.Result -isnot [string]) {
            if ($resp.Result.PSObject.Properties['Token'] -and $resp.Result.Token) { $oobToken = $resp.Result.Token }
            elseif ($resp.Result.PSObject.Properties['Auth'] -and $resp.Result.Auth) { $oobToken = $resp.Result.Auth }
        }
        if (-not $oobToken -and $resp.PSObject.Properties['Token'] -and $resp.Token) { $oobToken = $resp.Token }
        if (-not $oobToken -and $resp.PSObject.Properties['Auth']  -and $resp.Auth)  { $oobToken = $resp.Auth  }
    }
} while (-not $oobToken -and $resp -and $resp.success -ne $false)
Write-Host ''
if ($oobToken) { return $oobToken }
```

Key OOB details:
- Poll every **5 seconds** — less aggressive than 2s, reduces server load
- Loop exits when a token is found OR explicit API failure (`success = $false`) OR 5-minute timeout
- Never key the loop condition on the shape of `$resp.Result` — the shape varies by tenant version
- Show elapsed time in-place using `` "`r" `` to overwrite the previous line

---

### 11.4 Fix Privilege Cloud BaseURL at the constant, not in downstream callers

**Root cause:** `Get-AuthToken` builds the ISPSS base URL from a single constant:
```powershell
$script:PCLOUD_BASE_TEMPLATE = 'https://{0}.privilegecloud.cyberark.cloud'
```
The Driver was patching `token.BaseURL` post-auth to append `/PasswordVault`. But the token object
flows through multiple paths — fresh auth, silent ClientCredentials refresh (`Invoke-TokenRefresh`),
expired token AutoRefresh (`Import-AuthToken -AutoRefresh`) — and Driver-side patches only ran in
some of them. Any newly-returned token from an unpatched path had a bare hostname URL and API calls
constructed the wrong path.

**Fix:** Include `/PasswordVault` in the template constant itself:
```powershell
$script:PCLOUD_BASE_TEMPLATE = 'https://{0}.privilegecloud.cyberark.cloud/PasswordVault'
```
All code paths (`Get-AuthToken`, `Update-AuthToken`, `Import-AuthToken -AutoRefresh`) share this
constant, so every ISPSS token is correct from creation. The `RefreshContext.BaseURL` — used when
refreshing a token in-session — is also correct, ensuring refreshed tokens inherit the right URL.

Driver-side patches remain as a migration safety net for tokens saved before the fix.

**Rule:** When a URL base string is referenced by multiple code paths, fix the constant — not the
callers. A caller-level patch is silently missed every time a new path is added.

---

### 11.3 Re-auth after 401 must be triggered immediately in the inner action loop

**Root cause:** `Invoke-TokenInvalidate` force-expires the session token (sets expiry to past,
removes the token file) and returns `$true`. The token expiry check only ran at the top of the
outer category loop. After a 401, the user had to press [B] to go back before the re-auth prompt
appeared — a confusing UX.

**Fix:** After calling `Invoke-ActionModule`, immediately re-check the token:
```powershell
Invoke-ActionModule -ModuleEntry $catModules[$actNum - 1]
# A 401 during the module call force-expires the token via Invoke-TokenInvalidate.
# Re-check immediately so the re-auth prompt appears now, not only after the user presses [B].
if ((Test-TokenExpiry) -eq 'Expired' -and -not (Invoke-TokenRefresh)) {
    return 'Exit'
}
```

**Rule:** Whenever an action module can trigger `Invoke-TokenInvalidate` (which it does on HTTP 401),
check token validity immediately afterward in the innermost loop — not only at the top of the outer loop.

---

## 12. CyberArk API Response Field Name Variations by Version

### 12.1 Platform GET response structure differs between PVWA v12+ and Privilege Cloud

**Root cause:** The `GET /API/Platforms/{id}` endpoint returns different response shapes depending
on the PVWA version:

| Version | Structure | Field names |
|---|---|---|
| PVWA v12+ | Fields nested under `general` sub-object | `id`, `name`, `description`, `active`, `platformType` |
| Privilege Cloud / older | Fields at response root (no `general` wrapper) | `PlatformID`, `Name`/`name`, `SystemType` instead of `platformType` |

When only mapping the `general` sub-object fields, Privilege Cloud responses produce mostly blank
output (only `active` at the root may accidentally match the lowercase lookup).

**Correct pattern — probe both locations and both field name variants:**
```powershell
$platform = $response.Data
Write-CyberArkLog -Level 'DEBUG' -Message "Platform GET root fields: $($platform.PSObject.Properties.Name -join ', ')"

$gen = if ($platform.PSObject.Properties['general'] -and $platform.general) {
    Write-CyberArkLog -Level 'DEBUG' -Message "Platform GET general fields: $($platform.general.PSObject.Properties.Name -join ', ')"
    $platform.general
} else { $platform }

[PSCustomObject]@{
    PlatformID   = if ($gen.PSObject.Properties['id'])                  { $gen.id }
                   elseif ($gen.PSObject.Properties['PlatformID'])      { $gen.PlatformID }
                   elseif ($platform.PSObject.Properties['id'])         { $platform.id }
                   elseif ($platform.PSObject.Properties['PlatformID']) { $platform.PlatformID }
                   else { $platformID }
    PlatformType = if ($gen.PSObject.Properties['platformType'])        { $gen.platformType }
                   elseif ($gen.PSObject.Properties['SystemType'])      { $gen.SystemType }
                   elseif ($platform.PSObject.Properties['platformType']) { $platform.platformType }
                   elseif ($platform.PSObject.Properties['SystemType']) { $platform.SystemType }
                   else { '' }
    # Name, Description, Active follow the same probe-both-locations pattern
}
```

**Rule:** When a CyberArk endpoint may be called against different PVWA versions, always log
`$response.Data.PSObject.Properties.Name` at DEBUG level. The log output from a live run reveals
the actual field names present and enables targeted fixes without guessing. Apply the same dual-location
fallback pattern to the corresponding List endpoint for consistency.

### 12.2 GetDirectoryServices (`GET /API/Configuration/LDAP/Directories`) response shape is unverified

**Status: needs live-system verification.** `Invoke-SafeMembersAdd.ps1`'s
`Get-SafeMembersSearchInOptions` helper (added 2026-08-20, for the interactive SearchIn picker)
calls this endpoint to list LDAP directories to offer alongside Vault. Neither the exact
response envelope (bare JSON array vs. wrapped under a `value` property) nor the field names
for a directory's ID and display name had been confirmed against a live CyberArk system at
the time this was written.

**Mitigation applied, following the pattern in 12.1:** the helper probes several plausible
field names (`id`, `domainName`, `directoryName`, `name`) for both the ID and display name,
logs the first item's actual property names at DEBUG (`GetDirectoryServices item properties: ...`),
and falls back to Vault-only (never throws or blocks the Add Safe Member flow) if the call
fails or nothing usable is returned.

**Follow-up:** once run against a real tenant, check the DEBUG log line for the actual property
names and simplify the probe list to match, or add the confirmed shape as a documented example
in `Docs\Interfaces.md` (it is not documented there yet, precisely because it isn't confirmed).

---

## 13. Windows Forms Behavior

### 13.1 `SaveFileDialog.InitialDirectory` is ignored by the Vista-style dialog

**Root cause:** In .NET 4+, `SaveFileDialog.AutoUpgradeEnabled` defaults to `$true`, which causes
the dialog to use the Vista-style common file dialog. The Vista-style dialog ignores `InitialDirectory`
as the starting browse location — it instead remembers the last folder the user navigated to for
that file type/application (stored in the shell's MRU list). Setting `InitialDirectory` has no
visible effect on where the dialog opens.

`RestoreDirectory = $true` is a separate, unrelated property that controls whether the *process
working directory* is restored to its original value after the dialog closes. It has no effect
on where the dialog opens and was a mistaken diagnosis.

**Symptom:** The CSV save dialog always opens at the application's launch directory or the last
browsed folder, ignoring the profile's `OutputFolder` setting.

**Wrong (Vista-style dialog — ignores InitialDirectory):**
```powershell
$dialog = New-Object System.Windows.Forms.SaveFileDialog
$dialog.InitialDirectory = $profileOutputFolder
# AutoUpgradeEnabled defaults to $true — Vista-style dialog ignores InitialDirectory
```

**Correct — disable Vista-style dialog to restore InitialDirectory behaviour:**
```powershell
$dialog = New-Object System.Windows.Forms.SaveFileDialog
$dialog.InitialDirectory    = $profileOutputFolder
$dialog.AutoUpgradeEnabled  = $false   # Forces XP-style dialog, which respects InitialDirectory
```

**Rule:** Set `AutoUpgradeEnabled = $false` on any `SaveFileDialog` or `OpenFileDialog` where
`InitialDirectory` must control the starting folder. The XP-style dialog always opens at
`InitialDirectory`. Note that `RestoreDirectory` is unrelated — it controls the process working
directory, not where the dialog opens.

**Known trade-off:** The XP-style dialog has an outdated appearance that may be unacceptable to
users. There is no known way to honor `InitialDirectory` in the Vista-style dialog without
third-party libraries. If aesthetics take priority, `AutoUpgradeEnabled` must remain `$true` and
`InitialDirectory` will be ignored — the dialog always opens at the last browsed folder for that
application. This is the current state: the project uses the Vista-style dialog and `OutputFolder`
is not used as the dialog starting location.

---

## 14. PS 5.1 `catch` Block Safety: `$_` Stability and `WebException` Property Access

Two related failure modes that both manifest as unexpected exceptions inside a `catch` block when
working with `Invoke-WebRequest` errors.

---

### 14.1 `$_` is overwritten by any pipeline or function call inside a `catch` block

**Root cause:** In PS 5.1, `$_` is the *current pipeline object* — an automatic variable that
belongs to the active pipeline stage. Inside a `catch` block it holds the caught `ErrorRecord`,
but that assignment is not protected. Any of the following immediately overwrites it:

- Running a pipeline: `$_ | Get-Member`, `$info = $_ | Select-Object ...`
- Calling a function that itself runs a pipeline or accesses `$_`
- A nested `try { } catch { }` — the inner `catch` sets `$_` to the new error; after the inner
  `catch` exits, `$_` is *not* reliably restored to the outer caught error in PS 5.1

The overwritten `$_` typically becomes a string (the output of `Out-String`), a `MemberDefinition`
object (from `Get-Member`), or `$null`. Accessing `.Exception` on any of these throws
`InvalidOperationException: Operation is not valid due to the current state of the object`.

**Symptom:** `InvalidOperationException` on `$_.Exception` or `$_.Exception.Message` — even though
the exception was successfully caught and `$_` was valid at catch-block entry. The error is blamed
on the property access, obscuring that `$_` was already clobbered by an earlier line.

**Wrong — `$_` clobbered before `$_.Exception` is accessed:**
```powershell
} catch {
    $members = $_ | Get-Member | Out-String   # $_ is now a string — clobbered
    script:Write-ISPSSLog ("Members: {0}" -f $members)
    $exMessage = $_.Exception.Message         # throws: String has no .Exception property
```

**Correct — capture `$_` as the absolute first statement:**
```powershell
} catch {
    $caughtError = $_   # must be line 1 — nothing else before this
    $exMessage   = 'Exception details unavailable'
    $statusCode  = 0
    $redirectHost = $null

    $members = $caughtError | Get-Member | Out-String   # $caughtError is stable
    $exMessage = try { $caughtError.Exception.Message } catch { 'unavailable' }
    ...
}
```

**Rule:** The first statement of every `catch` block that accesses `$_` more than once **must**
be `$capturedName = $_`. Use the captured name everywhere after that. Never pipe `$_` directly
inside a catch block.

---

### 14.2 `.Response` access on exception objects requires a type guard, not just `try/catch`

**Two distinct failures, same symptom:**

**Failure A — `InvalidOperationException` on invalid-state `WebException.Response`:**
When `Invoke-WebRequest` fails at the SSL/TLS layer, .NET constructs a `WebException` whose
`.Response` is non-null but internally invalid (socket closed before the response was read).
A null-check passes, then the property read throws `InvalidOperationException`.

**Failure B — `PropertyNotFoundException` from strict mode on non-`WebException` types:**
Under `Set-StrictMode -Version Latest`, accessing `.Response` on ANY exception type that is NOT
`System.Net.WebException` throws `PropertyNotFoundException: The property 'Response' cannot be
found on this object.` This includes `CmdletInvocationException`, `RuntimeException`,
`HttpRequestException`, `UriFormatException`, and any other exception PS or .NET raises.

A `try/catch` wrapping the access **should** catch this, but in PS 5.1 under some conditions
(particularly `$x = try { ... } catch { ... }` expression form combined with `Set-StrictMode -Version
Latest` and `$ErrorActionPreference = 'Stop'`) the `PropertyNotFoundException` can escape the
catch block and propagate up the call stack uncaught.

**Root cause (both failures):** The assumption that `$_.Exception` is always a `WebException`
when `Invoke-WebRequest` throws is not always true. PS 5.1 can surface the exception as a
wrapping type. When it is not a `WebException`, `.Response` doesn't exist as a .NET property,
and strict mode makes that a hard error.

**Wrong — null-check plus try/catch is insufficient:**
```powershell
# Fails when $ex is not a WebException (strict-mode PropertyNotFoundException)
$statusCode = try {
    if ($caughtError.Exception.Response) {
        [int]($caughtError.Exception.Response.StatusCode)
    } else { 0 }
} catch { 0 }

# Fails when .Response is non-null but invalid (InvalidOperationException)
function Get-ExceptionRedirectHost {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    if ($ex -and $ex.Response -and $ex.Response.ResponseUri) {
        return $ex.Response.ResponseUri.Host   # throws if response is in invalid state
    }
    return $null
}
```

**Correct — type check first, then try/catch for invalid-state:**

Walk the exception chain to find the `WebException`, then only access `.Response` on that.
Any other exception type is skipped entirely — no `.Response` access, no strict-mode throw.

```powershell
# Extracting StatusCode safely — walk chain, type-check, then access
$webExForCode = $null
$exCurrent = $null
try { $exCurrent = $caughtError.Exception } catch { }
while ($exCurrent) {
    if ($exCurrent -is [System.Net.WebException]) { $webExForCode = $exCurrent; break }
    $exNext = $null
    try { $exNext = $exCurrent.InnerException } catch { }
    $exCurrent = $exNext
}
$statusCode = 0
if ($webExForCode) {
    try { $statusCode = [int]($webExForCode.Response.StatusCode) } catch { }
}

# Extracting redirect host safely — walk chain, type-check, then try/catch for invalid-state
function Get-ExceptionRedirectHost {
    param($ErrorRecord)
    if (-not $ErrorRecord) { return $null }
    $current = $null
    try { $current = $ErrorRecord.Exception } catch { return $null }
    while ($current) {
        if ($current -is [System.Net.WebException]) {
            try {
                if ($current.Response -and $current.Response.ResponseUri) {
                    return $current.Response.ResponseUri.Host
                }
            } catch {
                # Response is non-null but internally invalid (SSL/TLS or connection abort)
            }
            return $null
        }
        $next = $null
        try { $next = $current.InnerException } catch { }
        $current = $next
    }
    return $null
}
```

**Which exception types trigger each failure:**

| Network condition | `$_.Exception` type | `.Response` state |
|---|---|---|
| HTTP redirect (MaximumRedirection 0) | `WebException` | Valid — `.ResponseUri` readable |
| DNS resolution failure | `WebException` | `$null` — safe |
| TCP connection refused | `WebException` | `$null` — safe |
| SSL/TLS handshake failure | `WebException` | Non-null but **invalid** — `InvalidOperationException` |
| Certificate validation error | `WebException` | Non-null but **invalid** — `InvalidOperationException` |
| Connection abort mid-stream | `WebException` | Non-null but **invalid** — `InvalidOperationException` |
| URI format error | `UriFormatException` | No `.Response` property — **PropertyNotFoundException** |
| Script-level throw inside try | `RuntimeException` | No `.Response` property — **PropertyNotFoundException** |
| Wrapped cmdlet error | `CmdletInvocationException` | No `.Response` property — **PropertyNotFoundException** |

**Rule:** Never access `.Response` without first confirming the exception IS a
`[System.Net.WebException]`. Walk `InnerException` to find it if wrapped. Once confirmed,
still wrap in `try/catch` for the invalid-state case (Failure A).

**Preferred alternative for redirect detection:** Use `System.Net.HttpWebRequest` with
`AllowAutoRedirect = $false` instead of `Invoke-WebRequest -MaximumRedirection 0`. With
`HttpWebRequest`, 3xx responses come back as normal response objects (not exceptions), so
the `Location` header is available directly on the response. This eliminates the entire
`.Response`-on-exception problem for redirect probing:

```powershell
$req                   = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($url)
$req.Method            = 'GET'
$req.AllowAutoRedirect = $false
$req.Timeout           = 20000
$webResp = $null
try {
    $webResp    = [System.Net.HttpWebResponse]$req.GetResponse()
    $statusCode = [int]$webResp.StatusCode
    if ($statusCode -ge 300 -and $statusCode -lt 400) {
        $location     = $webResp.GetResponseHeader('Location')
        $redirectHost = $null
        if ($location) { try { $redirectHost = ([System.Uri]$location).Host } catch { } }
    }
} catch [System.Net.WebException] {
    # Typed catch — $_.Exception IS a WebException, so .Response is safe
    $webEx = $_.Exception
    if ($webEx.Response) {
        try { $statusCode = [int]([System.Net.HttpWebResponse]$webEx.Response).StatusCode } catch { }
    }
} finally {
    if ($webResp) { try { $webResp.Close() } catch { } }
}
```

---

### 14.3 Re-reading `WebException.Response.GetResponseStream()` in a `catch` block returns empty — the stream is already consumed

**Root cause:** Windows PowerShell 5.1's `Invoke-WebRequest` already reads the error response
stream once internally, to populate `$_.ErrorDetails.Message` on the `ErrorRecord` it throws.
Response streams are forward-only and single-read. By the time a `catch [System.Net.WebException]`
block runs its own `[System.IO.StreamReader]::new($webResp.GetResponseStream()).ReadToEnd()`, that
stream has already been consumed and returns an empty string — even though the server genuinely
sent a body (a real CyberArk 400 response with `Content-Length: 80` and
`Content-Type: application/json` came back this way).

**Symptom:** No exception is thrown — this fails silently. The response status code and headers
come through fine (they're read from the response object, not the stream), but the captured body
is always an empty string, which then round-trips through `ConvertFrom-Json` as `$null` rather than
throwing. This makes the bug easy to miss: everything downstream *looks* like it worked, it just
never has the one piece of information — the server's actual error detail — that the code exists
to capture. Found live in `Invoke-CustomTestApi.ps1`, whose entire purpose is displaying that exact
detail to a user debugging some other API failure.

**Wrong — re-reads an already-consumed stream:**
```powershell
} catch [System.Net.WebException] {
    $webResp = $_.Exception.Response -as [System.Net.HttpWebResponse]
    $rawBody = ''
    if ($webResp) {
        $reader  = [System.IO.StreamReader]::new($webResp.GetResponseStream())
        $rawBody = $reader.ReadToEnd()   # always '' - the stream is already spent
        $reader.Dispose()
    }
}
```

**Correct — use `$_.ErrorDetails.Message`, which PowerShell already populated from that same read:**
```powershell
} catch [System.Net.WebException] {
    $caughtErr = $_
    $webResp   = $caughtErr.Exception.Response -as [System.Net.HttpWebResponse]
    $rawBody   = ''
    if ($caughtErr.ErrorDetails -and $caughtErr.ErrorDetails.Message) {
        $rawBody = $caughtErr.ErrorDetails.Message
    } elseif ($webResp) {
        # Fallback only - by this point the stream is normally already empty
        try {
            $reader  = [System.IO.StreamReader]::new($webResp.GetResponseStream())
            $rawBody = $reader.ReadToEnd()
            $reader.Dispose()
        } catch { }
    }
}
```

**Rule:** Never try to manually re-read a `WebException`'s response stream for the body text.
`$_.ErrorDetails.Message` already holds it, populated by PowerShell itself during the original
call — read from there first, and treat a manual stream read as a last-resort fallback only.

---

## 15. Session Token and NoteProperty Preservation

### 15.1 NoteProperties are lost when the token object is replaced

When the driver refreshes a session token it creates a fresh `PSCustomObject` from the auth module.
Any NoteProperties added to the old token (e.g. `MaxResults` injected from the profile `Limit` field)
are not present on the new object.

**Wrong:**
```powershell
$script:SessionToken = $refreshedToken   # MaxResults NoteProperty silently lost
```

**Correct — copy NoteProperties before assigning:**
```powershell
function Set-SessionToken {
    param([PSCustomObject]$NewToken)
    if ($script:SessionToken) {
        foreach ($np in @($script:SessionToken.PSObject.Properties |
                          Where-Object { $_.MemberType -eq 'NoteProperty' })) {
            if (-not $NewToken.PSObject.Properties[$np.Name]) {
                try { $NewToken | Add-Member -NotePropertyName $np.Name -NotePropertyValue $np.Value -Force } catch { }
            }
        }
    }
    $script:SessionToken = $NewToken
}
```

**Rule:** Never assign directly to `$script:SessionToken`; always call `Set-SessionToken` so runtime
properties survive token renewal.

### 15.2 Token Warning branch must not call the refresh function

The session loop checks token status on each iteration: `Valid` → continue, `Warning` → approaching
expiry, `Expired` → prompt re-auth.

A common mistake is to call `Invoke-TokenRefresh | Out-Null` in the `Warning` branch to attempt
a proactive refresh. When the refresh fails (network blip, credentials expired), the failure is
silently discarded by `| Out-Null`. The session then checks status again on the next iteration,
finds the token now expired (because the failed refresh invalidated it), and exits — even though the
original token was still valid.

**Wrong:**
```powershell
'Warning' { Invoke-SelfHostedKeepalive; Invoke-TokenRefresh | Out-Null }
```

**Correct — keepalive only; `Invoke-TokenRefresh` already guards the Warning case:**
```powershell
'Warning' { Invoke-SelfHostedKeepalive }
```

`Invoke-TokenRefresh` must also short-circuit on `Warning` status (not just `Valid`) so that
callers who do check the return value don't accidentally trigger a full re-auth prompt:

```powershell
if ($status -in @('Valid', 'Warning')) { return $true }
```

---

## 16. CyberArk API Runtime Behaviors (ISPSS-Specific)

### 16.1 Groups API returns all groups as groupType='Vault' on ISPSS

On ISPSS (Privilege Cloud), the `/API/UserGroups` endpoint returns **all groups** —
including LDAP/Active Directory-backed groups — with `groupType = 'Vault'` and no
`directoryType`. Client-side filtering by `groupType` is therefore unreliable.

**Wrong approach:**
```powershell
# Breaks on ISPSS — all groups appear as Vault regardless of actual directory source
$ldapGroups = $allGroups | Where-Object { $_.groupType -match 'LDAP|directory' }
```

**Correct approach — use the AD lookup as the filter:**
```powershell
# Attempt AD lookup for every group; groups found in AD are LDAP-backed
foreach ($group in $allGroups) {
    $dn = & $fnFindGroupDN -GroupSAM $group.groupName -Root $searchRoot
    if (-not $dn) {
        Write-CyberArkLog -Level 'DEBUG' -Message "Not found in AD — likely Vault-only, skipping."
        continue
    }
    # ... process LDAP group members
}
```

Groups not found in AD are silently skipped (DEBUG log only). This is expected for
internal Vault-only groups and must not be recorded as a failure.

### 16.2 Accounts API caps at ~20,000 accounts without a safe filter

`GET /API/Accounts` without a `filter=safeName eq ...` query parameter will return at most
approximately 20,000 accounts regardless of pagination. This is a CyberArk server-side cap,
not a client-side limitation.

**Workaround — iterate by safe:**
1. Fetch all safes via `GET /API/Safes`.
2. For each safe, call `GET /API/Accounts?filter=safeName eq SafeName`.
3. Each per-safe call is paginated normally by `Invoke-CyberArkAPI`; the 20K cap does not
   apply per-safe.
4. Accumulate results across all safes.

This pattern is implemented in `Invoke-AccountsList` as the "By Safe" retrieval mode.

### 16.3 CyberArk OData filter values must NOT be quoted

`Invoke-CyberArkAPI` passes filter strings through `New-CyberArkQuery`, which calls
`[Uri]::EscapeDataString()` on every query parameter value. `EscapeDataString` encodes double
quotes as `%22`. After URL decoding, the server receives the filter with literal quote characters
as part of the value string:

```
# Filter built in code:        safeName eq "My Safe"
# After EscapeDataString:      safeName%20eq%20%22My%20Safe%22
# Server receives (decoded):   safeName eq "My Safe"   ← quotes are part of the name
# Result:                      no safe found → zero accounts returned
```

The CyberArk Accounts API filter parser does **not** support OData-style quoted string
literals. The value after `eq ` is taken literally; if the name does not include the quote
characters, no match is found and the API returns an empty result with HTTP 200.

**Wrong — quotes become part of the literal name lookup:**
```powershell
$filter = "safeName eq `"$safeName`""
```

**Correct — no quotes; URL encoding of the whole filter value handles spaces:**
```powershell
$filter = "safeName eq $safeName"
```

When `New-CyberArkQuery` encodes this, the server receives `safeName eq My Safe` (after
decoding). The CyberArk filter parser treats everything after `eq ` as the value, so safe names
with spaces are matched correctly without quoting.

**Rule:** Do not add OData-style quotes to CyberArk filter values when using
`Invoke-CyberArkAPI`. The `EscapeDataString` call in `New-CyberArkQuery` handles all
special characters at the HTTP transport layer.

### 16.4 ISPSS group names use UPN format (`GroupName@domain.com`) for directory-backed groups

**Observation:** In ISPSS (Privilege Cloud), CyberArk directory-linked groups are returned by
the `/API/UserGroups` endpoint with their `groupName` in UPN format — e.g.
`MyGroup@corp.com`. Vault-only (local) groups have plain names with no `@`.

**Implication for ADSI lookup:** Active Directory `sAMAccountName` is the portion *before* the
`@`. Passing the full UPN to the ADSI filter returns no results.

**Two-step name normalisation before ADSI search:**
```powershell
# Step 1: strip DOMAIN\ prefix (legacy netlogon format)
$sam = if ($name -match '^[^\\]+\\(.+)$') { $Matches[1] } else { $name }
# Step 2: strip @domain suffix (UPN format used by ISPSS)
$sam = if ($sam  -match '^([^@]+)@.+$')   { $Matches[1] } else { $sam  }
# $sam is now the bare sAMAccountName for ADSI filter
```

**Filtering strategy:** Because only `@`-containing names represent directory-backed groups in
ISPSS, filtering the candidate list to names that match `@` before any ADSI work is done avoids
unnecessary queries for Vault-only groups and makes the progress counter accurate.

```powershell
# Include only groups whose name contains '@' — these are directory-backed
if ($gname -and $gname -match '@') { $ldapGroups.Add(...) }
```

**Rule:** Before performing an ADSI lookup for a CyberArk group, normalise the group name by
stripping both the `DOMAIN\` prefix and the `@domain.com` suffix. Use the presence of `@` as
the reliable indicator that a group is directory-backed and worth querying.

---

## 17. Script-Scoped Helper Functions in Dot-Sourced Modules

### 17.1 Use `script:` prefix to scope helpers without polluting the global namespace

API modules are dot-sourced into the driver scope. Any function defined at module level
without qualification becomes a global function and can collide across modules.

Use the `script:` prefix to scope helper functions to the dot-sourcing context (the driver
script scope). These functions are callable with the `script:` prefix from within the same
module and from the driver scope, but are not visible to other modules or child scopes:

```powershell
# In Invoke-AccountsList.ps1 (dot-sourced into Manage-Privilege.ps1)
function script:Add-AccountToResult {
    param([PSCustomObject]$Result, [object]$Account, [hashtable]$ErrorInputData)
    # ... shared mapping logic ...
}

# Called from Invoke-AccountsList (entry-point function in same file)
foreach ($acct in $accounts) {
    script:Add-AccountToResult -Result $result -Account $acct -ErrorInputData $InputData
}
```

**Rule:** Always prefix module-internal helpers with `script:` to avoid cross-module
function name collisions and to signal that the function is not part of the public API.

---

## 18. PowerShell Module Import Scope

### 18.1 `Import-Module -Force` inside a `.psm1` removes the module from global scope

**Root cause:** When a `.psm1` module calls `Import-Module SomeModule -Force`, PowerShell
reimports `SomeModule` as a **nested module** of the calling module. A nested module's exported
functions are available within the calling module's scope but are **not** added to the global
session state. If `SomeModule` was previously imported globally (e.g. by the driver script),
the `-Force` flag removes that global registration and replaces it with the nested registration.

After the parent module finishes loading, `SomeModule`'s functions are only accessible from
within that parent module — any call from the driver script or any other module
fails with `CommandNotFoundException`.

This is exactly the failure pattern behind `Save-AuthToken is not recognized`: the driver imports
`CyberArk.Auth.Common.psm1` (globally), then imports `CyberArk.Auth.SelfHosted.psm1`, which
internally calls `Import-Module CyberArk.Auth.Common.psm1 -Force` without `-Global`. That
reimport removes Common from global scope. The driver then imports `CyberArk.Auth.ISPSS.psm1`,
which does the same thing again. After startup, `Save-AuthToken` exists only inside the ISPSS
module scope and is invisible to any caller outside it.

**Symptom:**
```
Could not save refreshed token*** term 'Save-AuthToken' is not recognized as the name of a cmdlet,
function, script file, or operable program.
```
The function exists in the module and IS exported — but the module is no longer globally visible.

**Wrong (nested import removes global registration):**
```powershell
# Inside CyberArk.Auth.SelfHosted.psm1 or CyberArk.Auth.ISPSS.psm1
Import-Module (Join-Path $PSScriptRoot 'CyberArk.Auth.Common.psm1') -Force
```

**Correct (import into global session state):**
```powershell
Import-Module (Join-Path $PSScriptRoot 'CyberArk.Auth.Common.psm1') -Force -Global
```

The `-Global` parameter tells PowerShell to import the module into the global session state
regardless of where the `Import-Module` call is made. This ensures the module's exported
functions remain accessible to all callers, including the driver script.

**Rule:** Any time a `.psm1` module calls `Import-Module` on another module that must remain
globally accessible (i.e. its functions are called directly from the driver or other modules),
always add `-Global`. Without it, the inner module becomes a nested module and loses its global
registration on reload.

---

## 19. CyberArk API Response Field Case Sensitivity

### 19.1 SafeMembers permissions are returned in camelCase, not PascalCase

The `GET /API/Safes/{safe}/Members` endpoint returns all permission fields in **camelCase**:

```json
{
    "permissions": {
        "useAccounts": true,
        "retrieveAccounts": true,
        "manageSafe": true,
        ...
    }
}
```

If the code looks up a PascalCase property name, `PSObject.Properties` returns `$null` silently:

```powershell
# WRONG — 'UseAccounts' does not exist on the permissions object; returns $null
$perms.PSObject.Properties['UseAccounts']   # → $null

# The guard evaluates as ($null -and ...) → false → else branch executes
UseAccounts = if ($perms -and $perms.PSObject.Properties['UseAccounts']) { $perms.UseAccounts } else { $false }
# Result: UseAccounts = $false for every member, even when the API returned true
```

Because `PSObject.Properties` returns `$null` for an absent property (it does not throw under
strict mode), the outer `if` silently evaluates false and all permissions default to `$false`.
There is no error, warning, or visible symptom other than every permission showing as false
in the output.

**Correct — match the exact case returned by the API:**
```powershell
UseAccounts = if ($perms -and $perms.PSObject.Properties['useAccounts']) { $perms.useAccounts } else { $false }
```

**Full permission list (camelCase as returned by the API):**

| Output column name | API property name (case-sensitive) |
|---|---|
| UseAccounts | `useAccounts` |
| RetrieveAccounts | `retrieveAccounts` |
| ListAccounts | `listAccounts` |
| AddAccounts | `addAccounts` |
| UpdateAccountContent | `updateAccountContent` |
| UpdateAccountProperties | `updateAccountProperties` |
| InitiateCPMAccountManagementOperations | `initiateCPMAccountManagementOperations` |
| SpecifyNextAccountContent | `specifyNextAccountContent` |
| RenameAccounts | `renameAccounts` |
| DeleteAccounts | `deleteAccounts` |
| UnlockAccounts | `unlockAccounts` |
| ManageSafe | `manageSafe` |
| ManageSafeMembers | `manageSafeMembers` |
| BackupSafe | `backupSafe` |
| ViewAuditLog | `viewAuditLog` |
| ViewSafeMembers | `viewSafeMembers` |
| AccessWithoutConfirmation | `accessWithoutConfirmation` |
| CreateFolders | `createFolders` |
| DeleteFolders | `deleteFolders` |
| MoveAccountsAndFolders | `moveAccountsAndFolders` |
| RequestsAuthorizationLevel1 | `requestsAuthorizationLevel1` |
| RequestsAuthorizationLevel2 | `requestsAuthorizationLevel2` |

**Missing header fields** (not in older implementations — verify against a live response):

| Column | API field |
|---|---|
| SafeUrlId | `safeUrlId` |
| SafeNumber | `safeNumber` |
| MemberId | `memberId` |
| IsExpiredMembershipEnable | `isExpiredMembershipEnable` |

**Rule:** Before implementing any API response mapping, capture a live response at DEBUG level
(`Write-CyberArkLog -Level 'DEBUG' -Message "$($obj.PSObject.Properties.Name -join ', ')"`)
to confirm exact field names and casing. Never assume PascalCase matches a JSON API that was not
explicitly verified — PowerShell's `PSObject.Properties` silently returns `$null` for mismatched
names under strict mode, producing wrong values rather than errors.

---

## 20. Relative Path Resolution in Dialog Helpers

### 20.1 `Test-Path` resolves relative paths against `Get-Location`, not `$PSScriptRoot`

**Root cause:** `Test-Path -LiteralPath $path` and `[IO.Path]::IsPathRooted()` treat paths
differently. When `$path` is a relative string (e.g. `'Output'` or `'.\Logs'`), `Test-Path`
resolves it against the *current working directory* (`Get-Location`), which is whatever
directory was active when the process started — not the directory containing the script.

If the user launches the driver from `C:\Tools` but the script lives in `C:\Scripts` and the
profile stores `OutputFolder = 'Output'`, `Test-Path` checks for `C:\Tools\Output`. When that
folder doesn't exist (but `C:\Scripts\Output` does), the path test fails and the dialog falls
back to a different default — the configured output folder is silently ignored.

**Wrong:**
```powershell
$defaultDir = if ($DefaultFolder -and (Test-Path -LiteralPath $DefaultFolder)) {
    $DefaultFolder          # relative path — resolved against Get-Location, not script dir
} else {
    (Get-Location).Path     # wrong fallback — also Get-Location, not $PSScriptRoot
}
```

**Correct — resolve relative paths against `$PSScriptRoot` before testing:**
```powershell
$defaultDir = if ($DefaultFolder) {
    $resolved = if ([System.IO.Path]::IsPathRooted($DefaultFolder)) {
        $DefaultFolder
    } else {
        Join-Path $PSScriptRoot $DefaultFolder
    }
    if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved } else { $PSScriptRoot }
} else {
    $PSScriptRoot
}
```

`[System.IO.Path]::IsPathRooted()` returns `$true` for any path that begins with a drive letter,
UNC path, or root slash — and `$false` for any relative path. Joining a relative path with
`$PSScriptRoot` makes it fully qualified against the script's own directory, which is the correct
resolution anchor for profile-relative folder settings.

**Rule:** Whenever a profile folder field (OutputFolder, InputFolder, LogFolder) is used to
construct a file path or dialog initial directory, always check `IsPathRooted` first and resolve
relative values against `$PSScriptRoot`. Use `-PathType Container` on the `Test-Path` call to
reject file paths that happen to exist but are not directories.

---

## 21. CyberArk API Request Body Field Casing Is Endpoint-Specific

### 21.1 PascalCase vs camelCase in request bodies — not consistent across endpoints

The CyberArk REST API is inconsistent about request body field naming. Some endpoints expect
**PascalCase** keys; others expect **camelCase**. Assuming one convention across all endpoints
will produce HTTP 400 errors with no descriptive message from the server.

Known examples:

| Endpoint | Body key style | Example |
|---|---|---|
| `POST /API/Safes` | PascalCase | `SafeName`, `OLACEnabled`, `ManagingCPM` |
| `POST /API/Accounts/{id}/LinkAccount` | camelCase | `name`, `safe`, `folder`, `extraPasswordIndex` |
| `POST /API/Accounts` | camelCase | `name`, `userName`, `platformId`, `safeName` |
| `POST /API/Safes/{safe}/Members` | camelCase | `memberName`, `searchIn`, `permissions` |

**Wrong (LinkAccount body using PascalCase — causes HTTP 400):**
```powershell
$body = @{
    Name               = $name        # should be 'name'
    Safe               = $safe        # should be 'safe'
    Folder             = $folder      # should be 'folder'
    ExtraPasswordIndex = $index       # should be 'extraPasswordIndex'
}
```

**Correct:**
```powershell
$body = @{
    name               = $name
    safe               = $safe
    folder             = $folder
    extraPasswordIndex = $index
}
```

**Rule:** Verify the exact body field names for each endpoint independently against the CyberArk
API reference or a captured request. Do not assume the body casing matches the response casing —
the `GET /API/Safes` response uses camelCase, but `POST /API/Safes` accepts PascalCase.

---

## 22. Numeric API Fields Must Be Typed as Integer, Not String

### 22.1 PowerShell hashtable values from user input are strings by default

User input collected via `Read-Host` or `Show-FieldPrompt` is always a `[string]`. When that
string is placed directly into a request body hashtable and serialized to JSON, it becomes a
JSON string (`"1"` instead of `1`). Some CyberArk API fields require a JSON number; sending a
string causes an HTTP 400 with no field-level explanation.

**Affected field:** `extraPasswordIndex` in `POST /API/Accounts/{id}/LinkAccount`.

**Wrong:**
```powershell
$body['ExtraPasswordIndex'] = $extraPasswordIndex   # string "1" → JSON "1" → 400
```

**Correct:**
```powershell
$body['extraPasswordIndex'] = [int]$extraPasswordIndex   # int 1 → JSON 1 → 204
```

**Rule:** Any API field documented as an integer must be explicitly cast with `[int]` before
inclusion in the body hashtable. Add the cast at body-construction time, not at validation time.

---

## 23. Safe `lastModificationTime` Is in Microseconds Since Unix Epoch

### 23.1 `creationTime` is seconds; `lastModificationTime` is microseconds

CyberArk Safe objects return two timestamp fields with different epoch units:

| Field | Unit | Example value | Converted |
|---|---|---|---|
| `creationTime` | Seconds | `1608827926` | 2020-12-24 |
| `lastModificationTime` | Microseconds | `1610319618268452` | 2021-01-10 |

The 16-digit value `1610319618268452` cannot be passed to `FromUnixTimeSeconds` or
`FromUnixTimeMilliseconds` directly:
- `FromUnixTimeSeconds(1610319618268452)` — overflow (too large)
- `FromUnixTimeMilliseconds(1610319618268452)` — year ~52985 (wrong)

**Correct conversion:**
```powershell
# Divide by 1000 to get milliseconds, then use FromUnixTimeMilliseconds
[DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]$safe.lastModificationTime / 1000))
    .LocalDateTime.ToString('yyyy-MM-dd')
```

The intermediate cast to `[double]` is needed because dividing a `[long]` by 1000 in PowerShell
performs integer division and drops the remainder, but `[double]` preserves the fractional
portion before the outer `[long]` cast truncates it.

**Rule:** Always check the unit of timestamp fields. `creationTime` and Unix-epoch account fields
are in seconds; `lastModificationTime` on Safes is in microseconds. When in doubt, inspect the
raw value: a 10-digit number is seconds, a 13-digit is milliseconds, a 16-digit is microseconds.

---

## 24. PSObject.Properties Guard Required for All Nested Property Access

### 24.1 Checking the parent object is not enough under strict mode

Under `Set-StrictMode -Version Latest`, accessing a property that does not exist on an object
throws `PropertyNotFoundException`. This includes properties on *nested* objects — checking that
the parent exists is not sufficient; you must also guard the child property access.

**Root cause of the AccountsAdd crash:**
```powershell
# $acct.secretManagement exists but may not have a 'status' property.
# The guard only checks secretManagement, not status → throws at line 231.
CPMStatus = if ($acct.secretManagement) { $acct.secretManagement.status } else { '' }
```

**Correct — guard each level independently:**
```powershell
CPMStatus = if ($acct.PSObject.Properties['secretManagement'] -and $acct.secretManagement -and
                $acct.secretManagement.PSObject.Properties['status']) {
                $acct.secretManagement.status
            } else { '' }
```

**General pattern for nested property access:**
```powershell
# For each level: check PSObject.Properties, then access the value
$val = if ($obj.PSObject.Properties['parent'] -and $obj.parent -and
           $obj.parent.PSObject.Properties['child']) {
    $obj.parent.child
} else { $defaultValue }
```

**Rule:** Apply `PSObject.Properties` guards at *every* level of a property chain. A guard on the
parent object does not protect against a missing property on the child object. This is especially
common in response-mapping blocks where the API may omit nested sections (e.g. `secretManagement`
may be absent entirely, or present but without a `status` field).

---

## 25. Request Body and Error Response Logging

### 25.1 POST/PUT/PATCH bodies and 4xx/5xx responses are now logged at DEBUG level (file-only)

`Invoke-CyberArkAPI` logs two additional entries at `DEBUG` level when the log level is set to
`DEBUG`:

1. **Request body** — logged immediately after the `POST/PUT/PATCH URL` line, before the API call.
   Sensitive fields (`secret`, `password`, `token`, etc.) are automatically masked by
   `Mask-SensitiveData` before the entry is written.

2. **Error response body** — when the server returns HTTP 4xx or 5xx, the raw response body
   (which contains the CyberArk-specific error code and message) is logged.

Both entries are written with `-FileOnly` — they appear in the log **file** but are suppressed
from the console. This prevents large or sensitive content from cluttering the terminal while
still making it available for post-session diagnosis.

**`Write-CyberArkLog -FileOnly` switch:**
```powershell
# Write to log file only — not printed to console.
Write-CyberArkLog -Message "Request body: $bodyString" -Level 'DEBUG' -FileOnly
```

**When to use `-FileOnly`:**
- Large structured content (JSON bodies, full error responses)
- Content that is already masked but would flood the terminal at DEBUG level
- Diagnostic data that is only useful when opening the log file after a failure

**Rule:** Use `Write-CyberArkLog -FileOnly` for any log entry that is useful for post-failure
diagnosis but would be noisy on the console. Do not use it for `ERROR` or `WARN` entries — those
should always appear on screen.

---

## 26. EM Dash in String Literals Breaks PS 5.1 Parsing on UTF-8-no-BOM Files

### 26.1 EM dash (`—`) terminates a string token under PS 5.1 when file is UTF-8-no-BOM

**Root cause:** PS 5.1 reads source files as Windows-1252 when no BOM is present. The UTF-8
byte sequence for EM DASH is `E2 80 94`. Byte `94` in Windows-1252 is the right double-quote
character (`"`), which the parser interprets as the closing delimiter of a string literal —
truncating the string and corrupting every token after it on that line.

**Symptom:** `ParserError: Unexpected token` or silent string truncation at the EM DASH position;
the actual character involved is not obvious from the error message.

**EM dash in a comment is safe** — the parser does not tokenise comment text, so bytes inside
`#` comments are ignored.

**Wrong (EM DASH inside a string literal):**
```powershell
Write-CyberArkLog -Level 'WARN' -Message "Account '$name' not found — skipping."
```

**Correct:**
```powershell
Write-CyberArkLog -Level 'WARN' -Message "Account '$name' not found - skipping."
```

**Rule:** Use ASCII hyphen (`-`) in all string literals. EM dashes are only safe inside
`# comments`. All project `.ps1` files must be saved as **UTF-8 with BOM** to prevent this class
of encoding error entirely (see Section 10).

---

## 27. `$null.PSObject` Returns `$null` in PS 5.1 — Guard Before `.Properties`

### 27.1 Accessing `.PSObject.Properties` on `$null` throws `PropertyNotFoundException`

**Root cause:** In PS 5.1, `$null.PSObject` is a language intrinsic that returns `$null` (not
the base-object PSObject). Chaining `.Properties` on that `$null` then throws
`PropertyNotFoundException: The property 'Properties' cannot be found on this object`.

This most commonly occurs after an API call where `$response.Data.value` is `$null` (the API
returned `"value": null`), and the code immediately tries to guard with
`$response.Data.value.PSObject.Properties['someKey']`.

**Symptom:** `PropertyNotFoundException` pointing at a line that accesses `.PSObject.Properties`
on a variable that appeared to be checked already.

**Wrong:**
```powershell
# $response.Data.value could be $null — $null.PSObject is $null, then .Properties throws
if ($response.Data.value.PSObject.Properties['id']) { ... }
```

**Correct — guard `$null` first, then access PSObject.Properties:**
```powershell
if ($null -ne $response.Data.value -and
    $response.Data.value.PSObject.Properties['id']) { ... }
```

**`$_ -and` short-circuit pattern in `Where-Object`:**
```powershell
# $_ could be $null when @($null) is piped (e.g. API returned value:null).
# $_ -and evaluates false immediately without accessing any properties.
$acctList | Where-Object {
    $_ -and
    (($_.PSObject.Properties['name'] -and $_.name -eq $accountName) -or
     ($_.PSObject.Properties['userName'] -and $_.userName -eq $accountName))
}
```

**How `@($null)` arises:** When `Invoke-CyberArkAPI` returns `Data.value = $null` and the
caller wraps it in `@(...)`, PS 5.1 creates a one-element array containing `$null` rather
than an empty array.

```powershell
[array]$acctList = if ($null -ne $resp.Data.value) { @($resp.Data.value) } else { @() }
```

**Rule:** Always check `$null -ne $variable` before accessing `.PSObject.Properties`. A
truthiness check (`if ($variable)`) is not sufficient — it passes for a non-null object that
happens to be an empty PSObject.

---

## 28. Trailing Slash Required When Last URL Path Segment Contains a Dot

### 28.1 Dots in the final URL path segment are misread as file extensions by proxies and servers

**Root cause:** HTTP/1.1 servers and reverse proxies (including some CyberArk-adjacent
infrastructure) examine the last path segment for a file extension. If a segment like
`domain.user` or `12_34.56` is present, the server may return an incorrect content type or
reject the request entirely. Appending a trailing slash signals that the path is a collection
(directory), not a file.

**Symptom:** Requests to endpoints where the account name, username, or other ID contains a dot
return unexpected errors or mismatched content types.

**Fix applied in `Join-CyberArkUrl` (`CyberArkComms.psm1`):**
```powershell
# After joining all segments, check the final path segment for a dot.
if ($result.Split('/')[-1] -match '\.') { $result += '/' }
```

**Fix applied in `Invoke-CustomTestApi` (direct URL builder):**
```powershell
# Applied to $cleanPath before appending query params.
if ($cleanPath.TrimEnd('/').Split('/')[-1] -match '\.') { $fullUri += '/' }
```

**Rule:** Any helper that assembles the final request URI must append a trailing slash when the
last path segment contains a dot. Apply the check **before** appending query parameters so the
slash falls between the path and the `?`.

---

## 29. PowerShell Switch Parameters: `-SwitchParam $true` Binds `$true` to the Next Positional Parameter

### 29.1 Passing a boolean value after a switch parameter silently fills the next parameter

**Root cause:** `[switch]` parameters in PowerShell do not consume the next token. Writing
`-Required $true` sets the switch (as if `-Required` were present) and then hands `$true` to
the binder as a bare argument, which fills the **next positional parameter** in the function
signature. If that parameter is `[string]$Default`, PowerShell coerces `$true` to the string
`"True"` — which then shows up as `[default: True]` in the prompt.

**Symptom:** A field prompt displays `[default: True]` or `[default: False]` with no apparent
reason when the calling code passes `-Required $true` or `-Required $false`.

**Wrong:**
```powershell
$apiPath = Show-FieldPrompt -Label 'API Path' -Required $true
# $true silently becomes the $Default parameter → shows "[default: True]"
```

**Correct (switch syntax — no value):**
```powershell
$apiPath = Show-FieldPrompt -Label 'API Path' -Required
```

**Rule:** Never pass a value to a `[switch]` parameter. Use the bare flag name to set it, or
omit it entirely to leave it unset. If you need a variable to control whether the switch is
present, use splatting:
```powershell
$params = @{ Label = 'API Path' }
if ($isRequired) { $params['Required'] = $true }
Show-FieldPrompt @params
```

## 30. Piping a Single-Element Array Into `ConvertTo-Json` Drops the Array Wrapper

### 30.1 `$arr | ConvertTo-Json` unrolls a one-item array before serializing it

**Root cause:** PowerShell's pipeline enumerates any array passed through it one element at a
time. When an array has exactly one element, `ConvertTo-Json` never sees "an array of one" - it
sees a single bare object, because the pipeline already unrolled it before `ConvertTo-Json`'s
process block ran. The result is JSON for the lone element with no `[ ]` wrapper. An array with
zero or two-or-more elements does not have this problem: zero elements means `ConvertTo-Json`
runs with no pipeline input at all (and correctly emits nothing / is skipped by an `if ($Body)`
guard), and two-or-more elements still arrive as multiple pipeline objects, which
`ConvertTo-Json` correctly collects and re-wraps in `[ ]`. Only the single-element case is silently
wrong - which makes it easy to ship, since testing tends to reach for "a couple of items" fixtures.

**Symptom:** Discovered via a real production 400 Bad Request from `Invoke-AccountsUpdate.ps1`
(v1.2.0) when a CSV row updated exactly one field (`Name`). The JSON Patch (RFC 6902) body was
built correctly as a one-element array of `{ op; path; value }`, but the DEBUG log showed the
request body as a bare object - `{"path":"/name","op":"replace","value":"Test_user"}` - instead
of an array - `[{"path":"/name","op":"replace","value":"Test_user"}]`. CyberArk's API expects a
JSON Patch **document**, i.e. a top-level array; a bare object is rejected with HTTP 400. Any
other single-op patch call (or any other single-element array body) sent through
`Invoke-CyberArkAPI` was silently broken the same way - this was a latent bug in the shared comms
layer, not specific to Accounts Update, that simply hadn't been exercised with a one-item array
body before.

**Root cause location:** `Modules/CyberArkComms.psm1`, `Invoke-CyberArkAPI`'s body-serialization
step:
```powershell
# Wrong - pipes $Body into ConvertTo-Json
$bodyString = $Body | ConvertTo-Json -Depth 20 -Compress
```

**Fix:** Pass the array via `-InputObject` instead of the pipeline. `ConvertTo-Json -InputObject`
receives the whole array as a single argument and correctly wraps it in `[ ]` regardless of
element count:
```powershell
# Correct
$bodyString = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
```
```powershell
# Demonstrating the difference directly:
$arr = @(@{a=1})
$arr | ConvertTo-Json -Compress            # {"a":1}   <- wrong, no array
ConvertTo-Json -InputObject $arr -Compress # [{"a":1}] <- correct
```

**Rule:** Whenever a value that might be a single-element array is serialized with
`ConvertTo-Json`, always pass it via `-InputObject`, never via the pipeline. This applies broadly
to any REST body, config array, or exported collection that could legitimately contain exactly
one item - not just JSON Patch documents. Caught by a new regression test
(`Tests\Unit\CyberArkComms.Tests.ps1` C25a) that sends a one-op JSON Patch body through the real
`Invoke-CyberArkAPI` (with only `Invoke-WebRequest` mocked) and asserts the captured request body
parses back as a one-element array, not a bare object.

---

## 31. `[bool]"false"` Is `$true` — CSV/String Booleans Must Never Be Cast Directly

### 31.1 Casting a CSV cell straight to `[bool]` treats every non-empty string as true

**Root cause:** In .NET/PowerShell, `[bool]` conversion from `[string]` is not a parse of "true" vs
"false" - it is a check for an empty string. `[bool]"false"`, `[bool]"0"`, and `[bool]"no"` are all
`$true`, because the string is non-empty. Since every CSV-sourced value arrives as `[string]`, any
module that wrote `[bool]$row.SomeFlag` directly was silently treating the literal text `false` (and
`0`, and `no`) from a CSV cell as `$true`. This is easy to miss in testing because a quick manual
test tends to use the pipeline/interactive path (which may pass a real `[bool]` or omit the flag
entirely) rather than a CSV file with an explicit `false` row.

**Symptom:** A CSV batch row that explicitly set a boolean-looking column to `false` (or `0`/`no`)
was processed as if the column were `true`. Found across five independent modules during the
2026-09-02 Self-Hosted review, all with the identical root cause: `Invoke-ApplicationsAdd.ps1`
(`Disabled`), `Invoke-ApplicationsAddAuthMethod.ps1` (`IsFolder`, `AllowInternalScripts`),
`Invoke-ApplicationsList.ps1` (`IncludeSublocations`), `Invoke-PlatformsList.ps1` (`ActiveOnly`),
and `Invoke-SafesList.ps1` (`ExtendedDetails`).

**Wrong:**
```powershell
$disabled = [bool]$row.Disabled   # "false" (string) -> $true
```

**Correct:**
```powershell
$disabled = $row.Disabled -match '(?i)^(true|yes|y|1)$'
```

**Rule:** Never cast a CSV-sourced (or otherwise string-typed) field directly to `[bool]`. Always
match it against an explicit truthy pattern. When writing a **new** module, grep the existing
codebase for `[bool]$` before shipping a boolean CSV field - this is a recurring bug class, not a
one-off, and every module that accepts a boolean-shaped CSV column is a candidate. Regression tests
were added to each affected module's test file asserting that the literal CSV string `"false"` is
NOT treated as true.

### 31.2 A one-off fix at the call site can regress if the underlying helper's contract changes later

The `Join-CyberArkUrl` trailing-slash issue (Section 28) recurred a second time via a different
mechanism during this same review: the helper's own trailing-slash-trim behavior (added to fix an
unrelated test regression, C12) silently undid the Section 28 fix for the `Applications` endpoints
that need the slash preserved (a separate WCF/PIMServices.svc quirk from the dot-in-segment case
Section 28 covers). The 2026-08-16 history in `Documentation-Tracker.md` shows the slash was added,
then reverted the same day, and not re-fixed until this session. **Rule:** when a shared helper
(`Join-CyberArkUrl`, `Invoke-CyberArkAPI`, etc.) changes its general contract to fix one caller's
regression, check `Documentation-Tracker.md` for any other caller that depended on the old behavior
before considering the change complete - a fix at the helper level can silently break a fix already
made at a call site, and vice versa. The current fix restores the trailing slash at the
`Invoke-CyberArkAPI` call site (keyed off the caller's own `-Endpoint` string) rather than changing
`Join-CyberArkUrl`'s generic contract again, specifically to avoid re-triggering this cycle.

### 31.3 Secret-masking regexes keyed to a fixed field-name list miss new secret-shaped fields

**Root cause:** `CyberArkLogging.psm1`'s sensitive-data masking only matched a hardcoded set of
OAuth field names (`access_token`, `refresh_token`, `id_token`). Any other JSON key that is
secret-shaped by name but not on that list — e.g. `NewCredentials` (the literal new vault password
in `Invoke-AccountsChangeInVault.ps1`'s request body) — was logged in cleartext at DEBUG/`-FileOnly`
level.

**Fix:** Added a generic pattern that masks the value of **any** quoted JSON key containing
`password`, `secret`, `token`, or `credential` (case-insensitive), rather than maintaining a
fixed list of known field names:
```powershell
'(?i)("[^"]*(?:password|secret|token|credential)[^"]*")\s*:\s*"[^"\\]*(?:\\.[^"\\]*)*"'
```

**Rule:** Prefer a name-pattern match over a fixed field-name list for secret masking. A new API
module that introduces a new secret-shaped field name (e.g. `NewPassword`, `ClientSecret`,
`ApiKey`) is automatically covered without needing a corresponding logging-module change, as long
as the field name contains one of the masked substrings.

## 32. `{ $result = Call-Something } | Should -Not -Throw` Never Assigns `$result` in the Outer Scope

**Root cause:** Piping a scriptblock into `Should -Not -Throw` runs that scriptblock in a child
scope, the same way any scriptblock invoked via the pipeline does in PowerShell. An assignment
inside it (`$result = Invoke-Something ...`) sets a new variable in that child scope and does not
write back to the `$result` already declared in the enclosing `It` block - regardless of whether
`Set-StrictMode` is active. This reproduces with a trivial repro, no Pester test needed:
```powershell
function Test-Foo { return [PSCustomObject]@{ Failures = 1 } }
$result = $null
{ $result = Test-Foo } | Should -Not -Throw
$result.Failures   # $null, not 1 - the assignment never left the scriptblock's scope
```

**Symptom:** Without `Set-StrictMode`, `$result.Failures` on the still-`$null` `$result` silently
evaluates to `$null`, so a `Should -Be 1` assertion right after it fails with a comparison mismatch
that looks like a genuine functional bug rather than a scoping mistake. Under `Set-StrictMode
-Version Latest` (which `Tests\Run-Tests.ps1` sets globally but no individual test file does), the
same `$null.Failures` throws `PropertyNotFoundException` instead - which is the exact "fails only in
the full suite, passes in isolation" signature this file already documents in Section 9.9, and three
separate `Invoke-ApplicationsAdd.Tests.ps1` tests (two pre-existing, one newly added and initially
written the same way) were misfiled under that signature as unexplained pre-existing failures before
this was traced to its actual cause here.

**Fix:** Don't rely on the scriptblock-pipe pattern to both check for no-throw and capture a return
value. Assign directly instead - `$result = Invoke-Something ...` - and let an unexpected exception
fail the test naturally (Pester reports an uncaught exception as a failure with the exception
message, which is an equally clear signal as a `Should -Not -Throw` failure would have been):
```powershell
# Wrong - $result is $null outside the scriptblock, always, regardless of strict mode:
$result = $null
{ $result = Invoke-Something -Param $x } | Should -Not -Throw
$result.Failures | Should -Be 1

# Correct:
$result = Invoke-Something -Param $x
$result.Failures | Should -Be 1
```
The `{ ... } | Should -Not -Throw` pattern is still fine on its own when nothing inside it needs to
be captured for a later assertion (e.g. `{ Invoke-Something -WhatIf } | Should -Not -Throw` with no
follow-up inspection of a return value) - the bug is specific to combining it with an inner
assignment the test then reads afterward.

**Rule:** When a test needs both "assert this doesn't throw" and "capture the return value for
further assertions," do a plain direct assignment and skip the `Should -Not -Throw` wrapper entirely
- it adds no real protection here (a thrown exception fails the test either way) and silently
discards the assignment it looks like it's making.

**Follow-up:** the two other full-suite-only failures flagged above with the same
`PropertyNotFoundException`-on-`$null` signature were checked and turned out to be two different
bugs, not this one - a good illustration of why the shared exception signature alone doesn't tell
you the cause:
- `Invoke-ReportsList.Tests.ps1`'s RL08a *was* this exact Section 32 bug (`{ $r = ... } | Should
  -Not -Throw`) - fixed the same way, direct assignment.
- `Invoke-CustomExportGroupMembersLocal.Tests.ps1`'s ISPSS groupType test was actually the
  Section 9.8/9.9 array-collapse bug instead: `($result.Results | Where-Object {...}).Count` with
  zero matches collapses to `$null`, not an empty array, so `.Count` throws under strict mode -
  fixed by wrapping in `@(...)`, same as the `Invoke-SafesAddFromTemplate.Tests.ps1` T31 case
  Section 9.8 already documents.
- `ModuleMeta.AG06` in `Invoke-AccountsGet.Tests.ps1` (a third pre-existing failure, different
  signature - `Should -Not -BeNullOrEmpty` failing outright, not an exception) turned out to be
  neither: a genuinely stale assertion checking for an `AccountID` column in `InputSchema` that
  hadn't existed since the module was refactored to the `AccountName`+`Safe` resolution pattern
  (`AccountID` remained supported as an optional direct-lookup override, just no longer a required
  CSV column) - fixed by updating the test to check for the columns the module actually declares.

**Rule:** don't assume every failure sharing a signature has the same root cause - `$null.Count`
and `$null.Successes` throwing the identical `PropertyNotFoundException` text can come from
completely different bugs (a collapsed pipeline result vs. a scriptblock-scope assignment that
never happened vs., in this case, a wholly unrelated stale test having nothing to do with strict
mode at all). Read each failure's own code before assuming a shared fix applies.

## 33. A Correct Shared Helper Existed and Was Ignored by 16 Call Sites - Hand-Rolled String Interpolation Instead

**Root cause:** `CyberArkComms.psm1` already exported `New-CyberArkSearchFilter`, a small, already
Pester-tested (C13-C16) function that builds a `field eq value` filter expression and - critically -
wraps `value` in literal double quotes whenever it contains whitespace, matching CyberArk's own
filter grammar (confirmed against psPAS's `Private/ConvertTo-FilterString.ps1`, which does the
identical auto-quote-on-whitespace for API 14.6+). Despite this helper already existing and already
being correct, 16 call sites across the Accounts category built the identical `safeName eq X`
filter by hand via raw string interpolation instead of calling it:
```powershell
# Wrong - reimplements New-CyberArkSearchFilter's job, badly (no quoting):
-QueryParams @{ filter = "safeName eq $targetSafe"; limit = 1000 }
```
None of these 16 independent reimplementations quoted the value, so any safe name containing a
space (e.g. `"Prod Web Servers"`) silently broke the `AccountName`+`Safe` account-resolution path
that every one of these modules uses - the API most likely returned zero matches or misparsed the
filter, surfacing as a normal-looking "account not found" error rather than an obvious crash.

**Symptom:** An account lookup by `AccountName`+`Safe` fails for any safe whose name contains a
space, but succeeds for single-word safe names - easy to miss in testing if test safes happen to
be named without spaces (a very plausible testing blind spot, since single-word safe names are
common in ad hoc test setups but multi-word names are common in real environments).

**Fix:** Route every one of these 16 call sites through the existing helper instead of hand-writing
the string:
```powershell
# Correct:
-QueryParams @{ filter = (New-CyberArkSearchFilter -Criteria @{ safeName = $targetSafe }); limit = 1000 }
```

**Rule:** Before building any CyberArk filter/query expression by hand, check whether
`CyberArkComms.psm1` already exports a helper for it (`New-CyberArkQuery`, `New-CyberArkSearchFilter`,
`Join-CyberArkUrl`) - a shared helper existing and being correct does not guarantee every call site
actually uses it; grep for the literal pattern being hand-built (e.g. `"eq \$`") across the whole
`APIModules\` tree before assuming a single call site's fix is complete, the same lesson Section
31.2 already draws for shared-helper *contract changes* - this is the mirror case, where the
contract was already right and simply wasn't adopted everywhere it should have been. Also add
`New-CyberArkSearchFilter` (and any other under-documented shared helper) to
`API-Module-Development-Guide.md`'s example code - its absence from that guide's own filter-building
example is a plausible reason none of these 16 sites reached for it in the first place.

---

## 34. CyberArk `?search=` Endpoints Require a Literal Period to Be Percent-Encoded as `%2E`

**Observation, confirmed live by the user:** A `search` query parameter value containing a
period (e.g. a UPN-style username like `jdoe.admin`, an email address, or a dotted IP address)
fails to match on CyberArk's `?search=` endpoints unless that period is percent-encoded as
`%2E`. A literal, unencoded period in the value causes the search to find nothing.

**Root cause:** `[Uri]::EscapeDataString` - the standard .NET URL-encoding call this project
uses everywhere (`New-CyberArkQuery`) - treats `.` as an *unreserved* character per RFC 3986 and
deliberately leaves it as a literal period rather than encoding it. That's correct, standards-
compliant URL-encoding in general, but CyberArk's own `search` parameter parsing does not accept
a literal period the way RFC 3986 says a compliant server should - it needs the percent-encoded
form specifically.

**Wrong - standard encoding leaves the period as-is, and the search fails silently (no error, just no results):**
```powershell
New-CyberArkQuery -Params @{ search = 'jdoe.admin' }
# ?search=jdoe.admin - the period is not encoded, and the API finds nothing
```

**Correct - percent-encode any period in a `search` value's already-encoded form:**
```powershell
$encodedVal = [Uri]::EscapeDataString($val)
if ($key -ieq 'search') { $encodedVal = $encodedVal.Replace('.', '%2E') }
# ?search=jdoe%2Eadmin
```

**Rule:** Fixed once, centrally, in `New-CyberArkQuery` (`CyberArkComms.psm1`) - every module
already routes its `-QueryParams` through `Invoke-CyberArkAPI`, which calls this function, so no
per-module changes were needed. The key match is case-insensitive: most direct callers use
lowercase `search`, but `Invoke-EntitySearch`'s Platforms callers pass `-SearchParam 'Search'`
(capitalized). This encoding is applied *only* to the `search` key - other query/filter values
(e.g. `filter=safeName eq My.Vault`) are left alone, since there is no evidence CyberArk's other
query mechanisms share this same quirk, and blanket-encoding periods everywhere would be an
unproven, unrequested change.

---

## 35. `ProcessStartInfo.ArgumentList` Is Not Safely Usable Under `Set-StrictMode` on Windows PowerShell 5.1

**Observation, reported live by the user with a full stack trace:** Code using
`[System.Diagnostics.ProcessStartInfo]::new()` then `$psi.ArgumentList.Add(...)` crashed with
`PropertyNotFoundException: The property 'ArgumentList' cannot be found on this object` on every
Linux SSH connectivity test - a code path this project's own unit tests could never exercise,
since they mock the function that calls this one rather than spawning a real process.

**Root cause, confirmed with two different symptoms on two machines:** `ArgumentList` was added
to `ProcessStartInfo` in .NET Framework 4.6.1. On the user's machine, accessing it under
`Set-StrictMode -Version Latest` (always active in this project - `Manage-Privilege.ps1` sets it,
and every module is dot-sourced into that same scope) threw the exact `PropertyNotFoundException`
above. Reproduced independently on a *different* machine (.NET Framework 4.8, the same version
this project's own dev environment runs) with a *different* symptom: without `Set-StrictMode`,
`$psi.ArgumentList` silently evaluated to `$null` on a freshly-constructed `ProcessStartInfo` -
not missing, but not a usable collection either - and only threw the identical
`PropertyNotFoundException` once `Set-StrictMode` was turned on to match real production
conditions. Neither the .NET Framework version number nor `$psi.GetType().GetProperty
('ArgumentList')` (raw reflection, bypassing PowerShell's adapter) reliably predicts whether the
property is actually usable through PowerShell's own member-access syntax - reflection reported
the property as present on the machine where using it still failed.

**Wrong - assumes `ArgumentList` just works because the .NET Framework version is "new enough,"
or because reflection says the member exists:**
```powershell
$psi = [System.Diagnostics.ProcessStartInfo]::new()
foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }   # can throw, or silently do nothing
```

**Correct - probe a disposable object (never the one actually being configured) for real,
in a `try/catch`, and fall back to the single-string `.Arguments` property with proper manual
quoting when `ArgumentList` isn't safely usable:**
```powershell
$argumentListUsable = $false
try {
    $probe = [System.Diagnostics.ProcessStartInfo]::new()
    if ($null -ne $probe.ArgumentList) {
        $probe.ArgumentList.Add('x')
        $argumentListUsable = ($probe.ArgumentList.Count -eq 1)
    }
} catch {
    $argumentListUsable = $false
}

if ($argumentListUsable) {
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }
} else {
    $psi.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-Win32QuotedArgument -Value $_ }) -join ' ')
}
```
Probing a separate, disposable object - not the real `$psi` about to be used to start the
process - matters: if the real object were used for the probe and `ArgumentList.Add()` failed
partway through a multi-argument loop, `.Arguments` and a partially-populated `.ArgumentList`
could both end up set on the same object, and .NET does not treat that combination predictably.

**The manual quoting itself must follow the actual Win32 command-line-parsing rules** (the same
ones `CommandLineToArgvW` and `ArgumentList` itself use internally) - not simply wrapping
everything in quotes or joining with spaces. An argument with no spaces, tabs, or quotes needs no
quoting at all; otherwise, wrap in `"..."` and double any run of backslashes that immediately
precedes either a literal quote (plus one more backslash) or the end of the argument - backslashes
anywhere else are left alone. Verified against a real child process receiving arguments with
embedded spaces, quotes, and trailing backslashes, confirming byte-for-byte correct round-tripping
through the manual path.

**Rule:** Never assume a .NET API added in a specific framework version behaves identically once
routed through PowerShell 5.1's member-access system, especially under `Set-StrictMode`. When a
property's exact behavior varies by environment in a way that can't be predicted from version
numbers or reflection, probe it defensively - on a disposable object, in a `try/catch` - rather
than gating on a version check or a `GetType().GetProperty(...)` existence test that can itself
be misleading.

## 36. A Test Calling `.Count` on a Function's Return Value or a `Where-Object` Result Must Wrap It in `@()` First

**Observation:** A routine pre-commit test run turned up 7 failures, all
`PropertyNotFoundException: The property 'Count' cannot be found on this object`, across two
unrelated test files - `Get-SafeMembersSearchInOptions` (`Invoke-SafeMembersAdd.Tests.ps1`,
MA24/MA27/MA28) and `Invoke-SafesAddFromTemplate.Tests.ps1` (T08/T23/T27/T28). All seven were
already on the branch from earlier work, unrelated to whatever was being changed at the time they
were noticed - a reminder to always run the full suite before a commit, even a docs-only one,
since a failure can be sitting undetected in already-committed code until something happens to
run it again.

**Root cause:** In every failing case, the right-hand side produced exactly one matching item -
either a function that returns a single-element array (`Get-SafeMembersSearchInOptions` returning
just the `Vault` fallback option), or `$r.Results | Where-Object { ... }` matching exactly one
row. PowerShell's pipeline unwraps a single item written to the output stream: the caller receives
that one object directly, not a one-element array containing it. A `[PSCustomObject]` (or any
scalar) has no `.Count` property, so `Set-StrictMode -Version Latest` throws
`PropertyNotFoundException` the moment the assertion runs. The *same* calls with 2+ matches never
tripped this, because `.Count` genuinely exists on a real multi-element array - which is exactly
why this kind of bug hides for a long time: it only reproduces for the exact cardinality (zero or
one) that the pipeline collapses, so a test suite can look green for months until a case with
exactly one match is added or exercised.

This project's own production code already guards against this everywhere it matters - e.g. the
real call site for `Get-SafeMembersSearchInOptions` reads
`[array]$searchInOptions = @(script:Get-SafeMembersSearchInOptions -Token $Token)`
(`APIModules\SafeMembers\Invoke-SafeMembersAdd.ps1`) - so none of this was a live bug; it was
purely the unit tests skipping the same guard the product code uses everywhere else.

**Wrong - fails whenever the right-hand side happens to produce exactly one item:**
```powershell
$opts = script:Get-SafeMembersSearchInOptions -Token $Token
$opts.Count | Should -Be 1

($r.Results | Where-Object { $_.ItemType -eq 'Safe' }).Count | Should -Be 1
```

**Correct - force array semantics with `@(...)` before touching `.Count`, matching how the real
call sites already do it:**
```powershell
$opts = @(script:Get-SafeMembersSearchInOptions -Token $Token)
$opts.Count | Should -Be 1

@($r.Results | Where-Object { $_.ItemType -eq 'Safe' }).Count | Should -Be 1
```

**Rule:** Any expression that might return zero, one, or many items - a function call, a
`Where-Object` filter, a property that's sometimes a single object and sometimes a collection -
must be wrapped in `@(...)` before `.Count` (or any other array-only member) is used on it, in
tests exactly as much as in product code. Don't assume a passing test proves the pattern is safe;
it may only be passing because that particular mock data happens to produce 2+ matches.

## 37. `$InputData.Key` Dot Notation Throws When a Caller Omits an Optional Key Entirely - Unit Tests Can't Catch This If Every Fixture Always Supplies Every Key

**Observation:** A full live end-to-end test pass (every `Invoke-<Category><Action>` function
called directly against a real Self-Hosted PVWA, calling each module the same way a user's input
would after passing through the driver) crashed live on the very first write call:
`Invoke-SafesAdd` threw `PropertyNotFoundException: The property 'ManagingCPM' cannot be found on
this object` the moment the caller's `InputData` hashtable didn't include a `ManagingCPM` key at
all - not blank, entirely absent. All 1052 unit tests passed at the time; none of them exercised
this path, because every test fixture in this codebase always supplies every optional field
(blank or not) rather than omitting the key outright.

**Root cause:** This is the same bug class this project already fixed once, on 2026-08-15, for
`$Defaults.Key` inside `Get-*Input` custom input functions (see the Documentation-Tracker entry
"Fixed `$Defaults.Key` dot notation → `$Defaults['Key']` bracket notation in all `Get-*Input`
custom input functions"). That earlier pass never touched the `Invoke-*` functions' own direct use
of `$InputData` - a different, but structurally identical, set of call sites. PowerShell's
hashtable dot notation (`$h.Foo`) is a convenience the ETS (Extended Type System) provides on top
of `$h['Foo']`; it looks identical for a present key, but under `Set-StrictMode -Version Latest`
it throws for an *absent* key while `$h['Foo']` quietly returns `$null` for the same case. A
systematic grep for `$InputData\.[A-Za-z]` across all 65 API modules turned up 9 more real
instances of this exact anti-pattern across `Invoke-SafesAdd.ps1`, `Invoke-SafesUpdate.ps1`,
`Invoke-SafesUnassignCPM.ps1`, `Invoke-SafesAssignCPM.ps1`, `Invoke-SafeMembersRemove.ps1`,
`Invoke-GroupsDelete.ps1`, `Invoke-GroupsUpdate.ps1`, and `Invoke-GroupsAdd.ps1` - every one of
them reachable the same way, by a real CSV row missing a column or a direct caller omitting an
optional key, not just by this test harness.

**A `$InputData.ContainsKey('X')` guard on the same expression is fine and was left alone** -
`ContainsKey` is a real method call (always safe via dot notation, regardless of what keys exist),
and short-circuit `-and` evaluation means a subsequent `$InputData.X` dot access after
`$InputData.ContainsKey('X') -and ...` never runs unless the key is already confirmed present.
Only *unguarded* dot access - typically inside `if ($InputData.Foo) { ... } else { <default> }` -
is unsafe.

**Wrong - throws the instant `ManagingCPM` is entirely absent from the hashtable, not just blank:**
```powershell
$body = @{
    ManagingCPM = if ($InputData.ManagingCPM) { $InputData.ManagingCPM } else { '' }
}
```

**Correct:**
```powershell
$body = @{
    ManagingCPM = if ($InputData['ManagingCPM']) { $InputData['ManagingCPM'] } else { '' }
}
```

**Rule:** Never use dot notation on an `InputData`/`Defaults`-style hashtable whose keys are
optional or caller-controlled - always use bracket notation, even for a quick one-line
`if`/`else` default. And don't trust a passing unit test suite to prove this is safe: if every
fixture in the suite always populates every key (even blank), the suite can never exercise the
"key entirely absent" path that live CSV input or a minimal caller will eventually hit. A live
end-to-end pass against a real system - not just mocked unit tests - is what actually caught this.

## 38. An `It`/`Describe` Name Containing `<SomeWord>` Can Crash With "Variable Cannot Be Retrieved" - Only When Run As Part of the Full Suite

**Observation:** A new test named `'D19 - user accepts rename: renames to 1_DEL_<SafeName>,
reports Success not Failure'` passed when its file was run alone, then failed with
`RuntimeException: The variable '$SafeName' cannot be retrieved because it has not been set` the
moment it ran as part of the full `Tests\Run-Tests.ps1` suite - a classic "passes in isolation,
fails in the full run" symptom that usually points at shared/leaked state between files.

**Root cause:** Pester v6 (like v5) treats `<PlaceholderName>` inside an `It`/`Describe` name as a
template token for `-ForEach` data-driven tests - it substitutes the value of a same-named
variable from that test's data context when rendering the name for output. This test used no
`-ForEach` at all; the `<SafeName>` was meant as plain descriptive text. Pester's name-rendering
still tries to resolve `<SafeName>` as if it were a template token regardless, by looking for a
variable of that name in scope - which normally doesn't exist and apparently either isn't reached
or resolves silently in some run orders, but throws outright when nothing named `$SafeName` is in
scope at render time in a different run order (i.e., depends on exactly what other tests ran
before it and what they left in scope) - explaining why isolation and full-suite runs disagreed.

**Wrong - any `<Word>` in a test name is interpreted as a template placeholder, not literal text:**
```powershell
It 'D19 - user accepts rename: renames to 1_DEL_<SafeName>, reports Success' { ... }
```

**Correct - avoid angle brackets in test names entirely unless deliberately using `-ForEach`:**
```powershell
It 'D19 - user accepts rename: renames to 1_DEL_ prefix plus SafeName, reports Success' { ... }
```

**Rule:** Never put `<...>` in an `It`/`Describe` name unless it's a genuine `-ForEach` template
placeholder bound to that test's data. Running a single new/changed test file in isolation is not
sufficient proof it's safe - this exact failure only appeared once the test ran inside the full
suite, so always run the complete `Tests\Run-Tests.ps1` before considering a test finished.

## 39. `Invoke-WebRequest`'s `.Content` Can Irreversibly Corrupt Binary Data - `RawContentStream` Is the Only Reliable Source

**Observation:** Adding platform download support (`Platforms/Export`, which returns a real `.zip`
file) required `Invoke-CyberArkAPI` to correctly receive binary response bodies for the first time.
The existing code decided JSON-vs-binary by trying `ConvertFrom-Json` on `.Content` and catching
failure - never inspecting the response headers at all, and never accounting for what `.Content`'s
actual .NET type is for a real binary response.

**Root cause, confirmed via a local `HttpListener` test under real Windows PowerShell 5.1 (not
assumed):** `Invoke-WebRequest -UseBasicParsing`'s `.Content` property is:
- A proper `[byte[]]`, byte-for-byte identical to the real response body, when the response's
  `Content-Type` is genuinely binary (`application/octet-stream`, `application/zip`, etc.).
- A **lossily, irreversibly decoded `[string]`** when `Content-Type` implies a text charset (e.g.
  `text/html; charset=utf-8`) - even if the actual body is binary. Bytes outside the target
  encoding's valid range become the Unicode replacement character during decoding; once that
  happens, there is no encoding trick (Latin-1/ISO-8859-1 round-trip included) that recovers the
  original bytes, because the information was already discarded going from bytes to string.

In both cases, `.RawContentStream` (a `MemoryStream`) held the exact, untouched original bytes -
confirmed identical to the real payload in every test, including the corrupted-string case. This
makes `RawContentStream` the only reliable way to get raw bytes back when a server's `Content-Type`
can't be trusted - a real risk, not a hypothetical one: even psPAS's own `Get-PASResponse.ps1`
(this project's normal reference for CyberArk API behavior) relies on `.Content`'s runtime type
alone and has no `RawContentStream` fallback, so it would suffer this same corruption if any
CyberArk endpoint ever mislabels a file response the way the test reproduced.

**Wrong - trusts `.Content` unconditionally, and decides "is this JSON" by whether parsing throws
rather than by what the server actually said the content type is:**
```powershell
$rawBody = $response.Content
try { $data = $rawBody | ConvertFrom-Json; $dataType = 'JSON' }
catch { $data = $rawBody; $dataType = 'Binary' }   # may already be corrupted if .Content lied
```

**Correct - read the actual headers first, and fall back to `RawContentStream` whenever the
`Content-Type` can't be trusted (a `Content-Disposition` file-attachment header on a non-JSON
response is exactly that signal):**
```powershell
$contentType        = "$($response.Headers['Content-Type'])"
$contentDisposition = "$($response.Headers['Content-Disposition'])"

if ($response.Content -is [byte[]]) {
    $bytes = $response.Content   # already correct - Invoke-WebRequest agreed this is binary
} elseif ($contentDisposition -and $contentType -notmatch '(?i)application/json') {
    $ms = $response.RawContentStream
    $ms.Position = 0
    $bytes = New-Object byte[] $ms.Length
    $ms.Read($bytes, 0, $ms.Length) | Out-Null
}
```

**Rule:** Never assume `.Content`'s .NET type or trustworthiness for a response that might be
binary - check the actual `Content-Type`/`Content-Disposition` headers, and read from
`RawContentStream` whenever there's any doubt. Don't rely on a JSON-parse-attempt's success/failure
as a proxy for "what kind of content is this" - it can't distinguish a genuinely non-JSON text
response from data that's already been silently and unrecoverably corrupted before you ever see it.
When a shared function like this is changed, verify every existing caller's expectations still
hold: here, that meant confirming no module anywhere in the codebase depended on the old `Binary`
fallback's exact shape (a grep found none), and updating every test's mock response object to
include a `Headers` property, since none of them had one before this fix needed to read it.
