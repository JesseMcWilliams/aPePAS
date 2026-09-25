# Lessons Learned: PowerShell 5.1 Language and Runtime

Windows PowerShell 5.1 compatibility, encoding, `catch`-block safety, parameter binding, serialization,
and .NET or Windows API behavior. Strict-mode property and `.Count` issues are in
`Reference_Lessons-Learned-StrictMode.md`. Each entry lists the symptom, the cause, the fix or rule, and
one example. The "Old" line gives the entry's section numbers in the original single file.

---

## 1. PS 7-only syntax fails to parse in PS 5.1

*Old: §1.1, §1.2*

**Symptom:** `ParserError: Unexpected token 'if'`, or another `ParserError`, on any host running
Windows PowerShell 5.1.

**Cause:** in PS 7+, `if` is an expression and the ternary `?:`, null-coalescing `??` and
null-conditional `?.` operators exist. In PS 5.1, `if` is a statement only (it can't follow `return`), and
those operators don't exist.

**Rule:** use `if/else` statements.

```powershell
# Wrong (PS 7+ only)
return if ($map.ContainsKey($Code)) { $map[$Code] } else { "HTTP $Code" }
$value = $x ?? 'default';  $name = $obj?.Name;  $label = $flag ? 'yes' : 'no'
# Correct
if ($map.ContainsKey($Code)) { return $map[$Code] } else { return "HTTP $Code" }
$value = if ($x) { $x } else { 'default' }
$name  = if ($obj) { $obj.Name } else { $null }
$label = if ($flag) { 'yes' } else { 'no' }
```

---

## 2. Save `.ps1`/`.psm1` as UTF-8 with BOM, and keep string literals ASCII

*Old: §1.3, §10.1, §10.2, §10.3, §26*

**Symptom:** parse errors on lines that look correct, often reported near the **end** of the function
rather than at the bad character:
```
The string is missing the terminator: '.
Missing closing '}' in statement block or type definition.
The Try statement is missing its Catch or Finally block.
```
At runtime this showed up as `WARN | Import-APIModules | Failed to load module
'Invoke-CustomExportAll.ps1': At Invoke-CustomExportAll.ps1:128 char:35 ... The string is missing the
terminator`. Other forms are `ParserError: Unexpected token` and silent string truncation.

**Cause:** `powershell.exe` reads a BOM-less file with the system ANSI code page (usually Windows-1252),
not UTF-8. An em dash `—` (U+2014) is `E2 80 94` in UTF-8. In Windows-1252 that decodes to `â`, `€` and
`"` (U+201D, right double quote). PowerShell accepts U+201D as a double-quote string terminator, so the
string ends early. With a BOM (`EF BB BF`), PS 5.1 decodes the file as UTF-8. `pwsh` reads BOM-less UTF-8
by default and also respects a BOM.

**Rule:**
- Save every `.ps1` and `.psm1` as **UTF-8 with BOM**.
- Use a plain ASCII `-` in string literals whatever the encoding, because some editors silently strip
  the BOM. An em dash inside a `#` comment is safe, because comment text isn't tokenized.
- The Claude Code `Write` tool writes UTF-8 **without** a BOM, so re-save the file with a BOM afterwards.

```powershell
# Wrong in a BOM-less file: the em dash ends the string
Write-CyberArkLog -Level 'WARN' -Message "Account '$name' not found — skipping."
# Correct
Write-CyberArkLog -Level 'WARN' -Message "Account '$name' not found - skipping."

# Re-save files with a BOM
$utf8Bom = New-Object System.Text.UTF8Encoding $true
Get-ChildItem -Recurse -Include '*.ps1','*.psm1' | ForEach-Object {
    $text = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($_.FullName, $text, $utf8Bom)
}
```

Other ways to write a BOM: in VS Code, set `"files.encoding": "utf8bom"` or choose "Save with Encoding"
then "UTF-8 with BOM". In PS 5.1, `Set-Content -Encoding UTF8` writes a BOM.

**Bytes that are dangerous without a BOM** (the last UTF-8 byte, read as Windows-1252):

| Last byte | Windows-1252 char | Effect in PowerShell |
|---|---|---|
| `0x94` | U+201D right double quote | Ends a double-quoted string |
| `0x93` | U+201C left double quote | Starts a new double-quoted string |
| `0x92` | U+2019 right single quote | Ends a single-quoted string |
| `0x91` | U+2018 left single quote | Starts a new single-quoted string |

| Character | Unicode | UTF-8 bytes | Danger |
|---|---|---|---|
| Em dash `—` | U+2014 | `E2 80 94` | Ends a double-quoted string |
| En dash `–` | U+2013 | `E2 80 93` | Starts a rogue double-quoted string |
| Curly `“` / `”` | U+201C / U+201D | `E2 80 9C` / `E2 80 9D` | Double-quote opener / terminator |
| Curly `‘` / `’` | U+2018 / U+2019 | `E2 80 98` / `E2 80 99` | Single-quote opener / terminator |

---

## 3. Never use automatic variable names as parameters or variables

*Old: §5.1*

**Symptom:** runtime errors, a parameter that never binds (`-Profile $obj`), or silently wrong behavior.

**Cause:** the runtime owns the automatic variables. Declaring `param($Profile)` or assigning `$input`
shadows them. `$Profile` is especially bad as a parameter name.

**Rule:** don't use any of these as a variable or parameter name: `$Profile`, `$Error`, `$Host`,
`$input`, `$Args`, `$Matches`, `$null`/`$true`/`$false`, `$OFS`, `$foreach`, `$switch`, `$PID`,
`$PSScriptRoot`, `$PSCommandPath`, `$PSBoundParameters`, `$MyInvocation`, `$ExecutionContext`.
You may assign preference variables (`$ErrorActionPreference`, ...) on purpose at the top of a script, but
never use them as parameter names. Run PSScriptAnalyzer's `PSAvoidAssignmentToAutomaticVariable` on every
`.ps1`/`.psm1`, and fix every warning before merging.

```powershell
param([PSCustomObject]$currentProfile)   # not $Profile
$testInput = $script:ValidInput.Clone()  # not $input
```

---

## 4. `-Switch $true` binds `$true` to the next positional parameter

*Old: §29.1*

**Symptom:** a prompt shows `[default: True]` or `[default: False]` for no clear reason.

**Cause:** a `[switch]` doesn't consume the next token. `-Required $true` sets the switch, then passes
`$true` as a positional argument. That fills the next positional parameter (`[string]$Default`), which
becomes `"True"`.

**Rule:** never pass a value to a switch. Use the bare flag, or splat when a variable decides it.

```powershell
Show-FieldPrompt -Label 'API Path' -Required            # not -Required $true
$params = @{ Label = 'API Path' }; if ($isRequired) { $params['Required'] = $true }; Show-FieldPrompt @params
```

---

## 5. `Import-Module -Force` inside a `.psm1` needs `-Global`

*Old: §18.1*

**Symptom:** `Could not save refreshed token*** term 'Save-AuthToken' is not recognized as the name of a
cmdlet, function, script file, or operable program.` The function exists and is exported.

**Cause:** an `Import-Module X -Force` inside a module reimports X as a **nested** module. `-Force` removes
X's global registration. The driver imports `CyberArk.Auth.Common.psm1` globally, then
`CyberArk.Auth.SelfHosted.psm1` and `CyberArk.Auth.ISPSS.psm1` each reimport Common with `-Force`. After
that, `Save-AuthToken` exists only inside the ISPSS module.

**Rule:** when a `.psm1` imports a module whose functions the driver or other modules call directly, add
`-Global`.

```powershell
Import-Module (Join-Path $PSScriptRoot 'CyberArk.Auth.Common.psm1') -Force -Global
```

---

## 6. Piping a one-element array into `ConvertTo-Json` drops the `[ ]`

*Old: §30.1*

**Symptom:** a production HTTP 400 from `Invoke-AccountsUpdate.ps1` (v1.2.0) when a CSV row updated
exactly one field (`Name`). The DEBUG log showed `{"path":"/name","op":"replace","value":"Test_user"}`
instead of `[{...}]`. CyberArk expects a JSON Patch (RFC 6902) **document**, which is a top-level array.

**Cause:** the pipeline unrolls the single element before `ConvertTo-Json` sees it. Zero elements and
2+ elements serialize correctly, so tests with "a couple of items" miss it. The bug was in the shared
`Invoke-CyberArkAPI` body serialization (`Modules/CyberArkComms.psm1`), so every single-element array
body was affected.

**Rule:** serialize anything that might be a one-element array with `-InputObject`, never through the
pipeline. Regression test: `Tests\Unit\CyberArkComms.Tests.ps1` C25a.

```powershell
$arr = @(@{a=1})
$arr | ConvertTo-Json -Compress            # {"a":1}   wrong
ConvertTo-Json -InputObject $arr -Compress # [{"a":1}] correct
$bodyString = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
```

---

## 7. `[bool]"false"` is `$true`: never cast string booleans directly

*Old: §31.1*

**Symptom:** a CSV row that sets a boolean column to `false`, `0` or `no` is processed as true. The
2026-09-02 Self-Hosted review found this in five modules: `Invoke-ApplicationsAdd.ps1` (`Disabled`),
`Invoke-ApplicationsAddAuthMethod.ps1` (`IsFolder`, `AllowInternalScripts`), `Invoke-ApplicationsList.ps1`
(`IncludeSublocations`), `Invoke-PlatformsList.ps1` (`ActiveOnly`) and `Invoke-SafesList.ps1`
(`ExtendedDetails`).

**Cause:** converting a `[string]` to `[bool]` checks only for an empty string. Every CSV value is a
string.

**Rule:** match against an explicit truthy pattern. Before you ship a new boolean CSV field, grep for
`[bool]$`. Each affected module has a regression test that asserts the literal `"false"` is not true.

```powershell
$disabled = [bool]$row.Disabled                        # wrong: "false" -> $true
$disabled = $row.Disabled -match '(?i)^(true|yes|y|1)$' # correct
```

---

## 8. Capture `$_` on the first line of a `catch` block

*Old: §14.1*

**Symptom:** `InvalidOperationException: Operation is not valid due to the current state of the object` on
`$_.Exception`, even though `$_` was valid when the catch block started.

**Cause:** in PS 5.1, `$_` is the current pipeline object. Any pipeline (`$_ | Get-Member`), function call
that uses the pipeline, or nested `try/catch` inside the `catch` overwrites it, and a nested catch doesn't
reliably restore it. It becomes a string, a `MemberDefinition` or `$null`.

**Rule:** if a `catch` block uses `$_` more than once, make `$caughtError = $_` its first statement, and
never pipe `$_` directly.

```powershell
} catch {
    $caughtError = $_                                   # line 1
    $members   = $caughtError | Get-Member | Out-String
    $exMessage = try { $caughtError.Exception.Message } catch { 'unavailable' }
}
```

---

## 9. Read `.Response` only after a `[System.Net.WebException]` type check

*Old: §14.2 (and the note in §11.1)*

**Symptom:** an exception is thrown **inside** the `catch` block while reading the HTTP status or redirect
host.

**Cause:** there are two separate failures:
- **A, invalid state:** after an SSL/TLS, certificate or mid-stream abort failure, `WebException.Response`
  is non-null but invalid. A null check passes, then reading `.ResponseUri` or `.StatusCode` throws
  `InvalidOperationException`.
- **B, wrong type:** `$_.Exception` isn't always a `WebException` (`UriFormatException`,
  `RuntimeException`, `CmdletInvocationException`, `HttpRequestException`, ...). Under strict mode,
  `.Response` throws `PropertyNotFoundException: The property 'Response' cannot be found on this object.`
  In PS 5.1 this can escape an enclosing `try/catch`, especially the `$x = try {...} catch {...}` form with
  `$ErrorActionPreference = 'Stop'`.

| Network condition | Exception type | `.Response` |
|---|---|---|
| HTTP redirect (`-MaximumRedirection 0`) | `WebException` | valid, `.ResponseUri` readable |
| DNS failure / TCP refused | `WebException` | `$null`, safe |
| SSL/TLS, certificate error, connection abort | `WebException` | non-null but **invalid** |
| URI format / script throw / wrapped cmdlet error | other types | no property: **PropertyNotFoundException** |

**Rule:** walk `InnerException` to find a `[System.Net.WebException]`, read `.Response` only on that, and
still wrap the read in `try/catch` for failure A. For redirect probing, prefer `HttpWebRequest` with
`AllowAutoRedirect = $false`. It returns a 3xx as a normal response with a `Location` header, not as an
exception, and a typed `catch [System.Net.WebException]` makes `.Response` safe.

```powershell
$webEx = $null; $cur = $null
try { $cur = $caughtError.Exception } catch { }
while ($cur) {
    if ($cur -is [System.Net.WebException]) { $webEx = $cur; break }
    $next = $null; try { $next = $cur.InnerException } catch { }; $cur = $next
}
$statusCode = 0
if ($webEx) { try { $statusCode = [int]($webEx.Response.StatusCode) } catch { } }
```

---

## 10. Read a `WebException` error body from `$_.ErrorDetails.Message`, not the response stream

*Old: §14.3*

**Symptom:** no error. The status code and headers come through, but the captured body is always `''`,
and `ConvertFrom-Json` turns it into `$null`. A real CyberArk 400 with `Content-Length: 80` and
`Content-Type: application/json` arrived this way. Found live in `Invoke-CustomTestApi.ps1`, whose only
purpose is to show that body.

**Cause:** PS 5.1's `Invoke-WebRequest` already reads the forward-only, single-read error stream to fill
`$_.ErrorDetails.Message`. Reading `GetResponseStream()` again returns empty.

**Rule:** read `ErrorDetails.Message` first. Use a manual stream read only as a last-resort fallback.

```powershell
} catch [System.Net.WebException] {
    $caughtErr = $_
    $rawBody = ''
    if ($caughtErr.ErrorDetails -and $caughtErr.ErrorDetails.Message) { $rawBody = $caughtErr.ErrorDetails.Message }
}
```

---

## 11. `Invoke-WebRequest .Content` can corrupt binary data: use `RawContentStream`

*Old: §39*

**Symptom:** a downloaded file (the `Platforms/Export` `.zip`) is corrupted, or JSON-versus-binary is
guessed wrong.

**Cause:** this was confirmed with a local `HttpListener` test under real PS 5.1. With `-UseBasicParsing`,
`.Content` is a correct `[byte[]]` when `Content-Type` is binary (`application/octet-stream`,
`application/zip`). When `Content-Type` implies a text charset (e.g. `text/html; charset=utf-8`),
`.Content` is a lossily decoded `[string]`, even for a binary body. Invalid bytes become U+FFFD, and no
re-encoding (Latin-1 included) recovers them. `.RawContentStream` (a `MemoryStream`) held the exact
original bytes in every test. psPAS's `Get-PASResponse.ps1` relies on `.Content`'s runtime type alone, with
no `RawContentStream` fallback.

**Rule:** decide by the headers, not by whether `ConvertFrom-Json` throws. Read `RawContentStream`
whenever `Content-Type` can't be trusted. A `Content-Disposition` header on a non-JSON response is that
signal. When you change a shared function this way, check every caller. For this fix, no module depended
on the old `Binary` shape, and every test mock had to gain a `Headers` property.

```powershell
if ($response.Content -is [byte[]]) { $bytes = $response.Content }
elseif ($contentDisposition -and $contentType -notmatch '(?i)application/json') {
    $ms = $response.RawContentStream; $ms.Position = 0
    $bytes = New-Object byte[] $ms.Length; $ms.Read($bytes, 0, $ms.Length) | Out-Null
}
```

---

## 12. `ProcessStartInfo.ArgumentList`: probe it, don't assume it

*Old: §35*

**Symptom:** the user reported this live with a full stack trace. `$psi.ArgumentList.Add(...)` threw
`PropertyNotFoundException: The property 'ArgumentList' cannot be found on this object` on every Linux SSH
connectivity test. Unit tests couldn't reach this path, because they mock the caller.

**Cause:** `ArgumentList` was added in .NET Framework 4.6.1. It was reproduced on a second machine with
.NET 4.8, where it showed a different symptom: `$null` without strict mode, and the same throw with it.
Neither the framework version nor `GetType().GetProperty('ArgumentList')` predicts whether it works
through PowerShell's member access. On the failing machine, reflection reported the property as present.

**Rule:** probe a **disposable** `ProcessStartInfo` in `try/catch`. If `ArgumentList` isn't usable, fall
back to `.Arguments` built with correct Win32 quoting (`ConvertTo-Win32QuotedArgument`). Don't probe the
real object: a failed `Add()` partway through a loop can leave both `.Arguments` and a partial
`.ArgumentList` set. Quoting rules (as `CommandLineToArgvW` uses): an argument with no space, tab or quote
needs no quotes. Otherwise wrap it in `"..."`, and double any run of backslashes that comes right before a
quote (then add one more) or before the end of the argument. This was verified byte-for-byte with a
real child process.

```powershell
$argumentListUsable = $false
try {
    $probe = [System.Diagnostics.ProcessStartInfo]::new()
    if ($null -ne $probe.ArgumentList) { $probe.ArgumentList.Add('x'); $argumentListUsable = ($probe.ArgumentList.Count -eq 1) }
} catch { $argumentListUsable = $false }
```

---

## 13. `Test-Path` resolves relative paths against `Get-Location`, not `$PSScriptRoot`

*Old: §20.1*

**Symptom:** a profile folder such as `OutputFolder = 'Output'` is silently ignored when the driver is
launched from another directory. It checks `C:\Tools\Output` instead of `C:\Scripts\Output`.

**Rule:** for profile folder fields (OutputFolder, InputFolder, LogFolder), resolve a non-rooted value
against `$PSScriptRoot` with `[IO.Path]::IsPathRooted()`, and use `-PathType Container`.

```powershell
$resolved = if ([System.IO.Path]::IsPathRooted($DefaultFolder)) { $DefaultFolder } else { Join-Path $PSScriptRoot $DefaultFolder }
$defaultDir = if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved } else { $PSScriptRoot }
```

---

## 14. `SaveFileDialog.InitialDirectory` is ignored by the Vista-style dialog

*Old: §13.1*

**Symptom:** the CSV save dialog opens at the launch directory or the last folder you browsed, not at the
profile's `OutputFolder`.

**Cause:** in .NET 4+, `AutoUpgradeEnabled` defaults to `$true`, which gives the Vista-style dialog. That
dialog uses the shell's per-application MRU folder and ignores `InitialDirectory`. `RestoreDirectory` is
unrelated: it restores the process working directory after the dialog closes. Treating it as the cause was
a misdiagnosis.

**Rule:** `AutoUpgradeEnabled = $false` (the XP-style dialog) respects `InitialDirectory`, but looks dated.
No way is known to make the Vista dialog honor it without third-party libraries. **Current state:** the
project keeps the Vista-style dialog, so `OutputFolder` is not the dialog's starting folder.

```powershell
$dialog.InitialDirectory   = $profileOutputFolder
$dialog.AutoUpgradeEnabled = $false   # only if InitialDirectory must be honored
```

---

## 15. Use ADSI `DirectorySearcher` for AD queries, not the ActiveDirectory module

*Old: §8.2*

**Symptom:** `CommandNotFoundException: Get-ADGroup`, or a dependency on optional RSAT tools.

**Rule:** use `System.DirectoryServices.DirectorySearcher` or `DirectoryEntry`, which ship with .NET
Framework on domain-joined Windows. Never use `ActiveDirectory` module cmdlets. Read values by bracket
index (`Properties['key'][0]`, a `ResultPropertyValueCollection`), and wrap each value in `"$(...)"`
because `[0]` is `[object]`. Put every ADSI call in `try/catch` so connectivity failures are handled.

```powershell
$searcher = New-Object System.DirectoryServices.DirectorySearcher
$searcher.Filter = "(&(objectClass=group)(sAMAccountName=$groupSAM))"
$searcher.PropertiesToLoad.Add('member') | Out-Null
$entry = $searcher.FindOne()
if ($entry) { $dn = "$($entry.Properties['distinguishedName'][0])"; $dns = @($entry.Properties['member']) }
```

---

## 16. Use an explicit stack, not recursion, for nested group traversal

*Old: §8.3*

**Cause:** the default call stack (about 500 frames) can be exhausted by deep recursion (10+ levels),
which throws `StackOverflowException`.

**Rule:** for any traversal that may go deeper than about 3 levels, or that may be circular (CyberArk
group members, AD nested groups), use `Stack[hashtable]` with a `HashSet[string]` of visited IDs.

```powershell
$stack = [System.Collections.Generic.Stack[hashtable]]::new()
$visited = [System.Collections.Generic.HashSet[string]]::new()
$stack.Push(@{ ID = $rootId; Path = $rootName; Depth = 1 })
while ($stack.Count -gt 0) {
    $cur = $stack.Pop()
    if ($visited.Contains($cur['ID'])) { continue }
    [void]$visited.Add($cur['ID'])
    foreach ($child in $children) {
        if (-not $visited.Contains($child.ID)) {
            $stack.Push(@{ ID = $child.ID; Path = "$($cur['Path']) > $($child.Name)"; Depth = $cur['Depth'] + 1 })
        }
    }
}
```
