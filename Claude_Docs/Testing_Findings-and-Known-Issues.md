# aPePAS: Findings and Known Issues

> **Stage: Testing.** Open findings (one-line index; closed detail is in `Archive_Testing_Findings-Closed.md`) and the known-issues / risk register. Split out of [Testing_Plan.md](Testing_Plan.md) on 2026-09-25; keep it under ~500 lines.

## Findings and Fixes — 2026-09-02 Self-Hosted Review

All 68 findings (F01 to F68) are fixed. Their full detail (issue, fix and tests added) is archived in [Archive_Testing_Findings-Closed.md](Archive_Testing_Findings-Closed.md). This index keeps the IDs resolvable. Add new findings to the table below as one-line rows, and move each one's detail to the archive when it's closed.

| # | File(s) | Status |
|---|---|---|
| F01 | `Modules/CyberArkComms.psm1` | Fixed. |
| F02 | `Modules/CyberArkLogging.psm1` | Fixed. |
| F03 | `APIModules/Applications/Invoke-ApplicationsAdd.ps1` | Fixed. |
| F04 | `APIModules/Reports/Invoke-ReportsList.ps1` | Fixed. |
| F05 | `Invoke-ApplicationsAdd.ps1` (`Disabled`), ... | Fixed. |
| F06 | `APIModules/Platforms/Invoke-PlatformsList.ps1` | Fixed. |
| F07 | `APIModules/Custom/Invoke-CustomExportGroupMembersLocal.ps1` | Fixed. |
| F08 | `Manage-Privilege.ps1` — `Invoke-SelfHostedKeepalive` | Fixed. |
| F09 | `Manage-Privilege.ps1` — inner category/action loop (`Invoke-SessionLoop`) | Fixed. |
| F10 | `Auth/Get-AuthToken.ps1` | Fixed. |
| F11 | `README.md`, `Claude_Docs/Reference_API-Module-Guide.md`, ... | Fixed. |
| F12 | `APIModules/Accounts/Invoke-AccountsChangeInVault.ps1` | Fixed. |
| F13 | `Manage-Privilege.ps1` — `Invoke-ActionModule` (results display) | Fixed. |
| F14 | `APIModules/Accounts/Invoke-AccountsCancelCpmTask.ps1`, ... | Fixed. |
| F15 | `APIModules/Custom/Invoke-CustomTestApi.ps1` | Fixed. |
| F16 | `APIModules/Custom/Invoke-CustomTestApi.ps1` | Fixed. |
| F17 | `Modules/CyberArkComms.psm1` | Fixed. |
| F18 | `APIModules/Custom/Invoke-CustomTestApi.ps1` | Fixed. |
| F19 | `Modules/CyberArkComms.psm1` | Fixed. |
| F20 | `APIModules/Safes/Invoke-SafesAdd.ps1`, `Invoke-SafesAddFromTemplate.ps1`, ... | Fixed. |
| F21 | `Modules/CyberArkComms.psm1` | Fixed. |
| F22 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F23 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F24 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F25 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F26 | `Manage-Privilege.ps1`, `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F27 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F28 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F29 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F30 | `Tests/Unit/Invoke-SafeMembersAdd.Tests.ps1`, ... | Fixed. |
| F31 | `Invoke-SafesAdd.ps1`, `Invoke-SafesUpdate.ps1`, `Invoke-SafesUnassignCPM.ps1`, ... | Fixed. |
| F32 | `Invoke-PlatformsCopy.ps1`, `Invoke-PlatformsEnable.ps1`, ... | Fixed. |
| F33 | `Invoke-SafesUpdate.ps1`, `Invoke-SafesAssignCPM.ps1`, `Invoke-SafesUnassignCPM.ps1` | Fixed. |
| F34 | `Invoke-SafesAddFromTemplate.ps1` | Fixed. |
| F35 | `Invoke-SafesDelete.ps1` | Fixed. |
| F36 | `Auth\CyberArk.Auth.ISPSS.psm1` | Fixed. |
| F37 | `Modules\CyberArkComms.psm1` | Fixed. |
| F38 | `APIModules\Platforms\Invoke-PlatformsExport.ps1` (new module) | Fixed. |
| F39 | `APIModules\Custom\Invoke-CustomExportPlatformDetails.ps1` (new module) | Fixed. |
| F40 | `APIModules\Policies\Invoke-PoliciesGetMasterPolicy.ps1`, ... | Fixed. |
| F41 | `APIModules\Accounts\Invoke-AccountsLinkAccount.ps1`, `Invoke-AccountsUnlinkAccount.ps1` | Fixed. |
| F42 | `APIModules\Groups\Invoke-GroupsAddMember.ps1`, `Invoke-GroupsRemoveMember.ps1` | Fixed. |
| F43 | `APIModules\Groups\Invoke-GroupsGetMembers.ps1` | Fixed. |
| F44 | `APIModules\Safes\Invoke-SafesAdd.ps1`, `Invoke-SafesUpdate.ps1` | Fixed. |
| F45 | `APIModules\Applications\Invoke-ApplicationsAdd.ps1` | Fixed. |
| F46 | `Modules\CyberArkComms.psm1` | Fixed. |
| F47 | `APIModules\SafeMembers\Invoke-SafeMembersAdd.ps1` (v1.4.0), ... | Fixed. |
| F48 | `Auth\CyberArk.Auth.Common.psm1` (`Import-WebView2Assembly`) | Fixed. |
| F49 | `Auth\CyberArk.Auth.Common.psm1` (`Invoke-WebView2Window`) | Fixed. |
| F50 | `Auth\CyberArk.Auth.Common.psm1` (`Invoke-WebView2Window`) | Fixed. |
| F51 | `Manage-Privilege.ps1` | Fixed. |
| F52 | `APIModules/Custom/Invoke-CustomTestConnectivity.ps1` | Fixed. |
| F53 | `Manage-Privilege.ps1`, `APIModules/Safes/Invoke-SafesDelete.ps1`, ... | Fixed. |
| F54 | `Manage-Privilege.ps1`, `APIModules/Custom/Invoke-CustomExportAll.ps1` | Fixed. |
| F55 | `Manage-Privilege.ps1`, `APIModules/Custom/Invoke-CustomExportEntitlements.ps1`, ... | Fixed. |
| F56 | `Auth/CyberArk.Auth.SelfHosted.psm1`, `Manage-Privilege.ps1` | Fixed. Remaining limitation (profile backup/restore doesn't include `.autocred`) accepted by the user on 2026-09-25. Detail is in the archive. |
| F57 | `Modules\CyberArkComms.psm1`, `Auth\CyberArk.Auth.Common.psm1`, ... | Fixed. |
| F58 | `Auth\CyberArk.Auth.Common.psm1` (`Invoke-WebView2Window`), ... | Fixed. |
| F59 | `Manage-Privilege.ps1` | Fixed. |
| F60 | `Manage-Privilege.ps1`, `Claude_Docs\Reference_Interfaces.md`, README.md, ... | Fixed. |
| F61 | `Manage-Privilege.ps1`, `Modules\CyberArkCredentialStore.psm1` (new), ... | Fixed. |
| F62 | `Auth\CyberArk.Auth.ISPSS.psm1`, `Manage-Privilege.ps1`, ... | Fixed. |
| F63 | `Manage-Privilege.ps1`, `Tests\Unit\Manage-Privilege.Tests.ps1` | Fixed. |
| F64 | `Manage-Privilege.ps1` | Fixed. |
| F65 | `Manage-Privilege.ps1`, `Tests\Unit\Manage-Privilege.Automation.Tests.ps1` | Fixed. |
| F66 | `Modules\CyberArkComms.psm1`, `Tests\Unit\CyberArkComms.Tests.ps1` | Fixed. |
| F67 | `Auth\CyberArk.Auth.Common.psm1`, `Auth\CyberArk.Auth.ISPSS.psm1`, ... | Fixed. |
| F68 | `Auth\CyberArk.Auth.Common.psm1`, `Tests\Unit\CyberArk.Auth.ISPSS.Tests.ps1`, ... | Fixed. |
| F69 | `Auth\CyberArk.Auth.ISPSS.psm1` | Fixed. |

**Live-tenant limitations found but NOT fixable via aPePAS code changes** (confirmed via raw HTTP requests matching psPAS's own documented shapes exactly, still failing identically - treated as environment/PVWA-version restrictions, not code bugs, per this project's no-guessing policy on undocumented API behavior):
- `DELETE /API/Safes/{safeName}` can return HTTP 409 for a safe whose own GET response shows `"accounts": []` (confirmed empty) shortly after accounts were added and deleted in it - likely an internal CyberArk retention/lifecycle delay unrelated to this module's request, which is a plain, correct `DELETE` with no equivalent "force" option in psPAS either.
- ~~`POST /API/Accounts/{id}/LinkAccount` and its bulk sibling returned HTTP 404~~ — **resolved, see Finding F41 above.** The user has since confirmed live that both the single and bulk endpoints now work correctly against the real tenant; this was an environment-side condition at the time, not a code bug, and required no aPePAS change.
- ~~`POST /API/UserGroups/{id}/Members` (`Invoke-GroupsAddMember`) returns an unconditional, empty-body HTTP 400 regardless of payload shape, field casing, or member type~~ — **resolved, see Finding F42 below.** This was actually a real code bug all along, not an environment limitation: every variant tried still sent a numeric-looking value for `memberId`, when CyberArk's API expects the member's username there instead (confusingly named field). Fixed and live-verified.

> **Note on F08/F09:** `Manage-Privilege.Tests.ps1` is documented (in `Archive_Planning_Documentation-Tracker.md`) as
> having a reproducible Pester v6.1 hang risk when new `Describe` blocks are added around
> `Invoke-FileWriteWithRetry`-adjacent code. No new automated test was added for these two driver
> fixes for that reason. **These two fixes are Self-Hosted-critical and must be verified manually**
> — see D23/D24 in the Manage-Privilege.ps1 section of [Testing_Manual-Integration-Procedures.md](Testing_Manual-Integration-Procedures.md).

---

## Known Issues / Risk Register (not fixed this session — verify manually)

These were identified during this review but are **not yet fixed**. None of them block this test
pass, but each is a real gap worth confirming (or scheduling a follow-up fix for) during live
Self-Hosted testing.

| # | Area | Risk | Recommended manual check |
|---|---|---|---|
| K01 | `CyberArkComms.psm1` error handling | Assumes Windows PowerShell 5.1's `[System.Net.WebException]` typing for HTTP error responses. Behavior if this project is ever run under PowerShell 7/`pwsh` (where the underlying exception types differ) is untested and likely broken, even though the project is documented as Windows PowerShell 5.1 only. | Confirm the driver is never launched with `pwsh.exe`; consider adding an explicit version guard at startup if this risk needs closing. |
| K02 | `Modules\CyberArkComms.psm1` (**resolved - see Finding F57**) | Confirmed directly: the SSL certificate validation bypass `IgnoreSSL` enables (`ServicePointManager.CertificatePolicy`) is a .NET Framework process-wide static with no per-call scoping possible in PS 5.1 - and was never reset, so switching from an `IgnoreSSL=$true` profile to a different one left the bypass silently active for the rest of the process's life. | Resolved - no further action needed. |
| K03 | `Auth\CyberArk.Auth.Common.psm1` (`Invoke-WebView2Window`) (**resolved - see Finding F58**) | Confirmed directly (via reflection against the shipped WebView2 Core DLL): the embedded WebView2 browser control used for SAML/OIDC login wraps its own Chromium/CoreWebView2 engine with a completely separate network stack and certificate validation from `ServicePointManager` - `IgnoreSSL` reached `Invoke-WebView2Window` for neither `-IgnoreSSL` itself (not even a parameter) nor any WebView2-specific bypass mechanism. | Resolved - no further action needed. |
| K04 | `Manage-Privilege.ps1` (**resolved - see Finding F59**) | Confirmed directly: `Invoke-CyberArkAPI` builds every request's URI from the *token's* `BaseURL` (`Modules\CyberArkComms.psm1:398`), never the active profile's - and a token's `BaseURL` is frozen at original login time, never reconciled against a later profile edit. At 3 call sites (`Invoke-ProfileConnect`, the Test Connection flow, `Invoke-TokenRefresh`'s SelfHosted password branch), the profile's current `BaseURL` was either never consulted or was actively out-preferred by the stale token/context value. | Resolved - no further action needed. |
| K05 | `Groups/Invoke-GroupsList.ps1` `GroupType` filter | Works correctly on Self-Hosted but is silently unusable on ISPSS (see the groupType caution above) with no warning surfaced to the user — a filtered ISPSS query just returns zero rows. | Out of scope for this Self-Hosted pass; flag as a UX follow-up if ISPSS is tested later. |
| K06 | `Auth\CyberArk.Auth.SelfHosted.psm1` (`Invoke-SelfHostedPasswordAuth`) (**resolved - see Finding F56**) | Confirmed directly (not just theorized): `Invoke-SelfHostedPasswordAuth`, called by `Update-SelfHostedAuthToken` for CyberArk/LDAP/RADIUS, falls back to an interactive `Get-Credential` prompt when the stored `_RefreshContext` has no `Credential` - reachable from 3 call sites in `Manage-Privilege.ps1` (`Invoke-ProfileConnect`'s logon-time age-based refresh, its `Expired`-token refresh, and `Invoke-TokenRefresh`'s automation branch), all of which now supply automation mode's own `$script:AutomationMode` flag as a real `-NoPrompt` parameter. | Resolved - no further action needed. |
| K07 | `Invoke-TokenRefresh` (SelfHosted branch) (**resolved - see Finding F59**) | Confirmed directly: the SelfHosted CyberArk/LDAP/RADIUS re-auth branch computed `$username` with only one fallback tier (`_RefreshContext['Credential'].UserName`, else blank), missing the `$script:ActiveProfile.Username` tier the sibling ISPSS branch already has - forcing an unnecessary extra `Read-Host` username prompt whenever `_RefreshContext` had no captured credential but the profile already had a `Username` set. | Resolved - no further action needed. |
| K08 | `Invoke-GroupsAddMember.ps1` (**resolved - see Finding F42**) | `POST /API/UserGroups/{id}/Members` returned an unconditional, empty-body HTTP 400 on the 2026-09-04 live test tenant regardless of payload shape, field casing, or member type - reproduced with the module's own request shape, psPAS's `Add-PASGroupMember.ps1`'s exact shape, and several variants (int vs. string `memberId`, with/without `memberType`), all identical. ~~Not fixed - no aPePAS-side request shape was found that succeeds~~ - this was wrong: every variant tried still sent a numeric-looking `memberId` value, when the field actually expects the member's username (per user report, later the same day). Fixed and live-verified: `POST` now returns HTTP 201. | Resolved - no further action needed. |
| K09 | `Invoke-AccountsLinkAccount.ps1` / `Invoke-AccountsUnlinkAccount.ps1` (**resolved - see Finding F41**) | `POST /API/Accounts/{id}/LinkAccount` and the bulk equivalent `POST /API/Accounts/Link/Bulk` both returned HTTP 404 on the 2026-09-04 live test tenant against a freshly confirmed-to-exist account (verified via a direct `GET` on that same account ID immediately before). ~~Not fixed - both endpoint shapes documented by psPAS (`Set-PASLinkedAccount.ps1`) were tried and both 404d identically~~ - the user retested live later the same day and confirmed both endpoints now work correctly with no code change; the 404 was a transient environment-side condition, not a code or request-shape defect. | Resolved - no further action needed. |
| K10 | `Invoke-SafesDelete.ps1` (**closed - see F35, per user direction 2026-09-21**) | `DELETE /API/Safes/{safeName}` returned HTTP 409 on the 2026-09-04 live test tenant for three safes whose own `GET` response showed `"accounts": []` (confirmed empty) shortly after accounts had been added to and then deleted from them. Per user direction, the most likely cause is Safe History Retention - a plain, correct `DELETE` call with no equivalent "force" parameter in psPAS's `Remove-PASSafe.ps1` either, so no delete-side aPePAS fix was identified. F35 added a rename-instead-of-delete fallback, which resolved 2 of the 3 stuck safes; the third (`ZZ-ClaudeTest-DiagSafeLink2`) 409'd on the rename `PUT` too. | Closed per explicit user direction - the remaining stuck safe is an environment-side/CyberArk-support matter outside this codebase's reach (no API-visible way to inspect or override the underlying lock), not an aPePAS defect. No further action tracked here. |
| K11 | `Manage-Privilege.ps1` (**resolved - see Finding F60**) | Confirmed directly: `Get-SelfHostedAuthToken`/`Get-ISPSSAuthToken` and the whole call chain down to `Invoke-WebView2Window` already fully supported `-WebView2AssemblyPath` (including persisting it through `_RefreshContext` for refresh continuity) - the only actual gap was `Manage-Privilege.ps1` itself never setting it, and no profile field existing for a user to supply a value at all. | Resolved - no further action needed. |
| K12 | `Auth\CyberArk.Auth.ISPSS.psm1`, `Manage-Privilege.ps1` (**resolved - see Finding F62**) | Confirmed directly: ISPSS `Interactive` (plain CyberArk Identity username/password, no MFA) could never refresh silently in automation mode, for two independent reasons - a fresh login's typed password was never assembled into a `PSCredential` for `_RefreshContext`, and `Use-StoredCredentialIfMissing` (K06's `.autocred` fallback) explicitly excluded ISPSS entirely regardless of `AuthMethod`. `Invoke-TokenRefresh` also classified `Interactive` as categorically `$neverSilent`, the same as `SSO`. | Resolved - no further action needed. |
| K13 | `Manage-Privilege.ps1` (**resolved - see Finding F63**) | Confirmed directly, from a live user-reported crash: `Get-AllDriverProfiles`'s field-backfill normalization (which lets an older saved profile gain a field added after it was created, e.g. `CPM_List`) never included `WebView2AssemblyPath` when K11/F60 added that field - so editing any profile saved before K11 crashed `Invoke-ProfileEditFlow` with `SetValueInvocationException` the moment it tried to assign the field, since `Set-StrictMode -Version Latest` disallows setting a genuinely nonexistent PSCustomObject property. | Resolved - no further action needed. |
| K14 | `Manage-Privilege.ps1` (**resolved - see Finding F64**) | Confirmed directly, from a live user-reported crash: selecting exactly one profile (e.g. entering `1`) in either `Invoke-ProfileBackupFlow` or `Invoke-ProfileRestoreFlow`'s comma-separated numbered picker crashed with `PropertyNotFoundException: The property 'Count' cannot be found on this object`. Root cause is a genuine PowerShell behavior, confirmed via isolated repro: assigning the result of an `if/else` expression to a variable unwraps a single-element array (even a strongly-typed one) down to its bare scalar element - `$names = if (...) { ... } else { $picked.ToArray() }` became a plain `[string]` whenever exactly one profile was picked, and `$names.Count` then threw under `Set-StrictMode -Version Latest`. | Resolved - no further action needed. |
| K15 | `Manage-Privilege.ps1` (**resolved - see Finding F65**) | Confirmed directly, live, while running a self-hosted functional test pass: `Invoke-AutomatedAction` unconditionally called `Invoke-SessionLogoff` at the end of every single automation-mode (`-Category`/`-Action`) run, and `Invoke-SessionLogoff` genuinely revokes the session server-side (`POST /API/auth/Logoff`) - so a SECOND automation-mode invocation against the same profile always failed with a 401, even though the local `.cred` file and `Invoke-ProfileConnect`'s own "Validating token..." check (`GET /API/LoggedOnUser`) both looked fine, since that endpoint doesn't appear to detect an explicit prior logoff the way a real data-fetching call does. This defeated the entire point of the saved/refreshable session K06/K12 built - any real-world use of automation mode beyond a single one-shot invocation per login was silently broken. | Resolved - no further action needed. |
| K16 | `Modules\CyberArkComms.psm1` (**resolved - see Finding F66**) | Confirmed directly, live, while running a SaaS write-action test pass: `Accounts/ChangeImmediate` against an ISPSS account with no CPM assigned hung indefinitely under real Windows PowerShell 5.1 (the project's only declared/supported runtime), with no error and no exit - a direct violation of automation mode's "never hang" design contract. Root cause: PS 5.1's `HttpWebRequest`-based `Invoke-WebRequest` sends `Expect: 100-continue` on every POST/PUT/PATCH with a body, which whatever gateway fronts CyberArk's ISPSS rotation microservice (SRS) does not appear to handle correctly; `pwsh` (HttpClient-based, never sends this header) was unaffected. | Fixed - `[System.Net.ServicePointManager]::Expect100Continue = $false` set once, process-wide, at `CyberArkComms.psm1` module-load time. **Live-verified 2026-09-23**: the identical `Accounts/ChangeImmediate` call against the same account, run twice under real Windows PowerShell 5.1, completed in ~1 second both times (a real HTTP 401 response, correctly classified) instead of hanging indefinitely - resolved. A separate, not-yet-explained observation surfaced during this same verification: both times, a token obtained moments earlier via a fresh Interactive login (not aged, not refreshed) was rejected with an immediate 401 on this specific call - not investigated further to avoid additional live authentication attempts without checking in first; flagged for awareness, not yet a diagnosed finding. |
| K17 | `Auth\CyberArk.Auth.Common.psm1`, `Auth\CyberArk.Auth.ISPSS.psm1`, `Manage-Privilege.ps1` (**fixed, per user direction - see Finding F67**) | Confirmed live, while investigating K16: repeated CyberArk Identity authentication attempts within a short window (both this session's own manual re-auth attempts and, independently, the driver's automatic age-based silent refresh, which re-attempts on every single automation-mode run once a saved token crosses its age threshold) triggered a soft lockout - subsequent attempts were rejected with a generic `"Authentication (login or challenge) has failed"` even with the correct password, confirmed via a raw diagnostic call succeeding moments after an identical call through the real code path failed. CyberArk Identity's own `StartAuthentication` response includes a `RetryWaitingTime` field (observed live: 30 seconds) that aPePAS completely ignored. | Added `Get-ISPSSAuthThrottle`/`Set-ISPSSAuthThrottle` (`CyberArk.Auth.Common.psm1`) - a small per-profile JSON sidecar file (no secrets) recording a `NextAllowedAt` timestamp, since in-memory state doesn't survive across separate process invocations (the real-world risk: a scheduled automation-mode task, or a human retrying by hand). `Invoke-ISPSSInteractive` now records `RetryWaitingTime` from `StartAuthentication` whenever `-AuthTokenProfileName`/`-ProfileDir` are supplied, and carries both into the returned token's `_RefreshContext` so `Update-ISPSSAuthToken`'s later silent refreshes keep recording it automatically, with no extra plumbing needed at those call sites. `Manage-Privilege.ps1`'s three ISPSS auth-attempt call sites (`Invoke-ProfileConnect`'s age-based and expired-token refresh blocks, `Invoke-TokenRefresh`'s mid-run refresh) now check the throttle first and skip a doomed attempt entirely rather than making it; the one genuinely-interactive fresh-login call site waits out the remaining time (a human is already waiting) instead of immediately re-attempting into another likely rejection. Per user direction ("Any ideas on this?" / "Yes"), this directly targets the mechanism CyberArk itself signals, rather than a guessed fixed delay. | Added 7 new tests to `CyberArk.Auth.ISPSS.Tests.ps1` (K17-01 through K17-07): the throttle file's read/write/elapsed-expiry behavior in isolation, that a live `StartAuthentication` response's `RetryWaitingTime` is recorded only when a profile identity is supplied (never blocking a standalone/no-profile caller), that it's carried into `_RefreshContext`, and that a later `Update-ISPSSAuthToken -NoPrompt` silent refresh re-records it using that carried context. Added 4 new tests to `Manage-Privilege.Automation.Tests.ps1` (AM78-81): the fresh-login call site forwards the profile identity and correctly waits (`Start-Sleep`, mocked) only when throttled, and `Invoke-TokenRefresh` skips (never calls `Update-ISPSSAuthToken`) when throttled. All 1254 unit tests pass (1243 + 11 new), 5 skipped (unchanged). **Live-verified 2026-09-23**: a single fresh Interactive login against the real `bannermen-nfr` tenant succeeded on its first attempt (the prior soft lockout had cleared overnight), and `Get-ISPSSAuthThrottle` correctly reported ~29 seconds remaining immediately afterward - confirming the sidecar file is created from a real `StartAuthentication` response's `RetryWaitingTime` (observed live: 30 seconds, matching this Finding's earlier observation) and read back correctly. |
| K18 | `Auth\CyberArk.Auth.ISPSS.psm1` (**resolved - see Finding F69**) | Under Windows PowerShell 5.1 only, 7 tests fail with `The property 'Count' cannot be found on this object`: ISPSS-INT01, INT02 and INT05 (K12) and K17-04 to K17-07. pwsh passes all of them, and `main` fails the same way, so it is not a regression from PR #26. It is likely a strict-mode collection collapse (StrictMode §6/§7) in the tests or in `Get-ISPSSAuthToken`. | Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Tests\Run-Tests.ps1 -Path Tests\Unit\CyberArk.Auth.ISPSS.Tests.ps1 -Verbosity Detailed` and find which `.Count` throws. |
