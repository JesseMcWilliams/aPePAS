# Lessons Learned: Driver and API Module Conventions

Patterns specific to how `Manage-Privilege.ps1`, the API modules in `APIModules\` and the shared modules
in `Modules\` work together: WhatIf, summaries, scope and dot-sourcing, logging, shared helpers and
session tokens. Each entry lists the symptom, the cause, the fix or rule, and one example. The "Old" line
gives the entry's section numbers in the original single file.

---

## 1. Check WhatIf before calling `Invoke-CyberArkAPI`

*Old: §3.1*

**Symptom:** `Expected Invoke-CyberArkAPI to be called 0 times exactly, but was called 1 time`.

**Cause:** when the WhatIf branch comes after the API call, even with `-WhatIf:$WhatIf.IsPresent` passed
through, the mock still records a call.

**Rule:** return from the WhatIf branch before the call, and record the summary there too. `GET` is never
suppressed (Pester §9).

```powershell
if ($WhatIf.IsPresent) {
    Write-CyberArkLog -Level 'INFO' -Message "WhatIf: DELETE $endpoint would be performed."
    $result.Successes++; $result.ItemsProcessed++
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
$response = Invoke-CyberArkAPI -Token $Token -Method 'DELETE' -Endpoint $endpoint
```

---

## 2. `Add-CyberArkLogSummaryEntry` needs all four parameters at every exit

*Old: §3.2*

**Symptom:** `ParameterBindingException: Cannot process command because of one or more missing mandatory
parameters: ItemsProcessed`. This can happen even when the function is mocked, because a call from a
dot-sourced module may reach the real function.

**Rule:** always pass `-ModuleName`, `-ItemsProcessed`, `-Successes` and `-Failures`. Call it at every exit
that has incremented `ItemsProcessed`: the WhatIf path, the error path and the success path (see the §1
example).

---

## 3. A custom input function returns `$null` to cancel

*Old: §7.1*

**Cause:** `Invoke-ActionModule` calls `Get-<Category><Action>Input` and checks
`if ($null -eq $inputData) { return }`, which takes the user back to the action menu.

**Rule:** when a required field can't be resolved (empty input and a failed or cancelled search), return
`$null`. Never `exit` or `throw`. Let the driver decide.

```powershell
$id = Show-FieldPrompt -Label 'Account ID' -Description 'ID or blank to search.'
if (-not $id) {
    $id = Invoke-EntitySearch -Token $Token -Endpoint '/API/Accounts' -SearchTerm (Show-FieldPrompt -Label 'Search') `
        -ResponseProperty 'value' -IdProperty 'id' -DisplayProperties @('name','userName','address') -EntityLabel 'account'
    if (-not $id) { return $null }
}
return @{ AccountID = $id }
```

---

## 4. Functions dot-sourced inside a function disappear when it returns

*Old: §6.1*

**Symptom:** `CommandNotFoundException: The term 'Get-SafeMembersListInput' is not recognized` at the
driver's `& "Get-$($meta.Category)$($meta.Action)Input"`. Only modules with `HasCustomInput = $true` are
affected.

**Cause:** `. $path` defines things in the **current** scope. `Import-APIModules` dot-sources every module
to read its `$ModuleMeta`, so the module functions live in its local scope and are gone when it returns.
`Invoke-ActionModule` searches its own scope, then its caller `Invoke-SessionLoop`, then the script scope,
then the global scope. `Import-APIModules` is not in that chain.

**Rule:** dot-source at the scope of the long-lived caller. `Invoke-SessionLoop` dot-sources every module
file a second time on purpose: the first pass reads data, and the second makes the functions available.

```powershell
function Invoke-SessionLoop {
    Import-APIModules                                         # reads $ModuleMeta
    foreach ($m in $script:LoadedModules) { . $m.FilePath }   # functions now visible to Invoke-ActionModule
    ...
}
```

---

## 5. Prefix module-internal helpers with `script:`

*Old: §17.1*

**Cause:** API modules are dot-sourced into the driver scope, so an unqualified helper becomes a shared
function and can collide with a helper in another module.

**Rule:** define internal helpers as `function script:Name`. That signals they aren't part of the public
API and avoids name collisions. Test helpers are different (Pester §3).

```powershell
function script:Add-AccountToResult { param([PSCustomObject]$Result, [object]$Account, [hashtable]$ErrorInputData) ... }
foreach ($acct in $accounts) { script:Add-AccountToResult -Result $result -Account $acct -ErrorInputData $InputData }
```

---

## 6. A `.psm1` must not assume the logging module is loaded

*Old: §6.2*

**Symptom:** `CommandNotFoundException` for `Write-CyberArkLog` when an auth module is imported on its
own (Pester, standalone scripts, debugging).

**Rule:** never call another module's session-level function directly from a `.psm1`. Wrap the call in a
private `script:` function, check it with `Get-Command -ErrorAction SilentlyContinue`, and fall back to
`Write-Verbose` or `Write-Warning`. Pass `-FunctionName` explicitly, because auto-detection from the call
stack would otherwise report the wrapper's name.

```powershell
function script:Write-ISPSSLog {
    param([string]$Message, [string]$Level = 'DEBUG', [string]$Fn)
    if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
        Write-CyberArkLog -Message $Message -Level $Level -FunctionName $Fn
    } else { Write-Verbose $Message }
}
```

---

## 7. Orchestration modules may call other modules' entry points

*Old: §8.1*

**Cause:** every module file is dot-sourced into `Invoke-SessionLoop`'s scope (§4), so
`Invoke-CustomExportAll` can call `Invoke-SafesList`, `Invoke-GroupsList` and the others.

**Rule:** iterate `$script:LoadedModules` and skip `Category = 'Custom'` to avoid recursion. Wrap each
module call in its own `try/catch`, so one failure doesn't abort the export. Read only `Results`,
`Successes`, `Failures` and `Errors` from the returned object. `$ModuleMeta` resolves to the last module
loaded (a known, harmless scope issue), so `ModuleName`, `Category` and `Action` may be wrong.

```powershell
$fnName = "Invoke-$($module.Meta.Category)$($module.Meta.Action)"
$moduleResult = & $fnName -Token $Token -InputData @{}
```

---

## 8. Shared helpers: use the existing ones, and check every caller when a contract changes

*Old: §31.2 (rule), §33 (rule)*

**Two ways this went wrong:**
- **The helper was right, but callers ignored it:** `New-CyberArkSearchFilter` was correct and tested, yet
  16 call sites hand-built the same filter (CyberArk-API §9). It was also missing from the filter-building
  example in `Reference_API-Module-Guide.md`, which may be why nobody used it.
- **The helper contract changed and broke a caller's fix:** a general trim in `Join-CyberArkUrl` undid a
  call-site trailing-slash fix (CyberArk-API §11).

**Rule:** before you hand-build a filter, query or URL, check what `CyberArkComms.psm1` already exports
(`New-CyberArkQuery`, `New-CyberArkSearchFilter`, `Join-CyberArkUrl`). Grep the whole `APIModules\` tree
for the literal pattern before you treat a single fix as complete. When you change a shared helper's
general contract, check `Archive_Planning_Documentation-Tracker.md` and every caller for code that relied
on the old behavior. Document under-documented helpers in `Reference_API-Module-Guide.md`.

---

## 9. Log request bodies and 4xx/5xx responses at DEBUG, to the file only

*Old: §25.1*

**Rule:** at `DEBUG` level, `Invoke-CyberArkAPI` logs:
1. the POST/PUT/PATCH request body, right after the URL line, masked by `Mask-SensitiveData` (§10), and
2. the raw 4xx/5xx response body, which holds CyberArk's error code and message.

Both use `Write-CyberArkLog -FileOnly`, so they go to the log file, not the console. Use `-FileOnly` for
large or noisy diagnostic content. Never use it for `ERROR` or `WARN` entries, which must always appear on
screen.

```powershell
Write-CyberArkLog -Message "Request body: $bodyString" -Level 'DEBUG' -FileOnly
```

---

## 10. Mask secrets by a name pattern, not a fixed field list

*Old: §31.3*

**Symptom:** `NewCredentials`, the new vault password in `Invoke-AccountsChangeInVault.ps1`'s body, was
logged in cleartext at DEBUG/`-FileOnly`.

**Cause:** `CyberArkLogging.psm1` masked only `access_token`, `refresh_token` and `id_token`.

**Rule:** mask any quoted JSON key whose name contains `password`, `secret`, `token` or `credential`, case
insensitive. New fields such as `NewPassword` or `ClientSecret` are then covered automatically. A name like
`ApiKey` contains none of these words, so it would still need its own pattern.

```powershell
'(?i)("[^"]*(?:password|secret|token|credential)[^"]*")\s*:\s*"[^"\\]*(?:\\.[^"\\]*)*"'
```

---

## 11. Replace the session token only through `Set-SessionToken`

*Old: §15.1*

**Symptom:** after a refresh, runtime NoteProperties such as `MaxResults` (from the profile's `Limit`)
are gone.

**Rule:** never assign `$script:SessionToken` directly. `Set-SessionToken` copies NoteProperties that the
new object lacks.

```powershell
foreach ($np in @($script:SessionToken.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' })) {
    if (-not $NewToken.PSObject.Properties[$np.Name]) {
        try { $NewToken | Add-Member -NotePropertyName $np.Name -NotePropertyValue $np.Value -Force } catch { }
    }
}
$script:SessionToken = $NewToken
```

---

## 12. The token `Warning` branch must not call the refresh function

*Old: §15.2*

**Symptom:** the session exits on a token that was still valid.

**Cause:** `'Warning' { ...; Invoke-TokenRefresh | Out-Null }` hid a failed refresh. The failed refresh
invalidated the token, and the next check found it `Expired`.

**Rule:** in `Warning`, run only the keepalive. `Invoke-TokenRefresh` must also return early on `Warning`,
so callers that check its return value don't start a full re-authentication prompt.

```powershell
'Warning' { Invoke-SelfHostedKeepalive }
# inside Invoke-TokenRefresh:
if ($status -in @('Valid', 'Warning')) { return $true }
```

---

## 13. Re-check the token right after each action module (401 handling)

*Old: §11.3*

**Symptom:** after a 401, the re-auth prompt appeared only once the user pressed [B].

**Cause:** on a 401, `Invoke-TokenInvalidate` force-expires the token (it sets the expiry in the past and
deletes the token file). Expiry was checked only at the top of the outer category loop.

**Rule:** check token validity in the innermost loop, right after any call that can invalidate it.

```powershell
Invoke-ActionModule -ModuleEntry $catModules[$actNum - 1]
if ((Test-TokenExpiry) -eq 'Expired' -and -not (Invoke-TokenRefresh)) { return 'Exit' }
```
