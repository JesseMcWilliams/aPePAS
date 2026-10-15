# Archive: Lessons Learned, CyberArk API (history and long examples)

> **Stage: Archive.** Moved out of `Reference_Lessons-Learned-CyberArk-API.md` on 2026-10-14 to keep it near 500 lines. Section numbers match that file, where each rule still stands.

## §1. Privilege Cloud: redirect discovery example

```powershell
$candidates = @("https://$sub.cyberark.cloud", "https://$sub-userportal.cyberark.cloud",
                "https://$sub.privilegecloud.cyberark.cloud")
foreach ($candidate in $candidates) {
    try {
        $resp = Invoke-WebRequest -Uri $candidate -Method Get -MaximumRedirection 0 -TimeoutSec 20 -ErrorAction Stop -UseBasicParsing
        $h = Get-WebResponseHost -Response $resp
        if ($h -match '\.id\.cyberark\.cloud$') { return "https://$h" }
    } catch {
        $caughtError = $_
        $h = Get-ExceptionRedirectHost -ErrorRecord $caughtError
        if ($h -match '\.id\.cyberark\.cloud$') { return "https://$h" }
    }
}
return "https://$sub.id.cyberark.cloud"
```

## §2. Identity AdvanceAuthentication: token extraction example

```powershell
if ($resp.Result -isnot [string]) {
    if ($resp.Result.PSObject.Properties['Token'] -and $resp.Result.Token) { $tok = $resp.Result.Token }
    elseif ($resp.Result.PSObject.Properties['Auth'] -and $resp.Result.Auth) { $tok = $resp.Result.Auth }
}
if (-not $tok -and $resp.PSObject.Properties['Token'] -and $resp.Token) { $tok = $resp.Token }
if (-not $tok -and $resp.PSObject.Properties['Auth']  -and $resp.Auth)  { $tok = $resp.Auth }
# OOB: do { ...poll every 5s, run the extraction above... } while (-not $tok -and $resp -and $resp.success -ne $false)
```

## §3. Privilege Cloud base URL: fix it at the constant, not in callers (old §11.4)

**Symptom:** some ISPSS tokens had a bare host `BaseURL`, and API calls built wrong paths.

**Cause:** the driver appended `/PasswordVault` to `token.BaseURL` after authentication, but tokens come
from several paths: fresh auth, silent ClientCredentials refresh (`Invoke-TokenRefresh`), and expired-token
AutoRefresh (`Import-AuthToken -AutoRefresh`). The patch didn't run on all of them.

**Rule:** when several paths share a URL base, fix the constant. `Get-AuthToken`, `Update-AuthToken`,
`Import-AuthToken -AutoRefresh` and `RefreshContext.BaseURL` all use it. The driver-side patches remain as
a migration safety net for tokens saved before the fix.

```powershell
$script:PCLOUD_BASE_TEMPLATE = 'https://{0}.privilegecloud.cyberark.cloud/PasswordVault'
```

## §9. Filter values: the call-site incident (old §33)

**Symptom (§33):** an `AccountName`+`Safe` lookup fails for a safe name with a space (e.g.
`"Prod Web Servers"`), but works for one-word names. It shows as a normal "account not found".

**Cause (§33):** 16 call sites in the Accounts category built `safeName eq X` by string interpolation
instead of calling the existing, Pester-tested (C13 to C16) helper.

## §11. Trailing slash: history (old §31.2)

**History (§31.2):** the fix regressed once. `Join-CyberArkUrl`'s own trailing-slash trim, added to fix an
unrelated test regression (C12), undid it for the Applications endpoints. The 2026-08-16 entries in
`Archive_Planning_Documentation-Tracker.md` show the slash being added and reverted the same day. The
current fix restores the slash at the `Invoke-CyberArkAPI` call site, based on the caller's `-Endpoint`,
instead of changing `Join-CyberArkUrl`'s general contract again (see Module-Conventions §8).
