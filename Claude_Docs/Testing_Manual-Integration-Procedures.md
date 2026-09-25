# aPePAS: Manual Integration Test Procedures

> **Stage: Testing.** Step-by-step manual procedures for auth and the driver against a live PVWA / ISPSS tenant. Split out of [Testing_Plan.md](Testing_Plan.md) on 2026-09-25; keep it under ~500 lines.

## Self-Hosted Auth — Manual Integration Test Procedures

`Auth/Get-AuthToken.ps1` was a dead legacy shim (see Findings F10 above) and has been deleted; the
current auth surface for this pass is `Auth/CyberArk.Auth.SelfHosted.psm1` (plus the shared
`CyberArk.Auth.Common.psm1` for token persistence, WebView2, and profile I/O). Unit testing is not
feasible for these modules (browser auth flows, DPAPI, interactive prompts, live directory/PKI
dependencies) — run these procedures manually against the live Self-Hosted lab host for **all 8**
Self-Hosted auth methods. **SAML, OIDC, PKI, and PKIPN are the highest-risk methods** for this pass:
they depend on the WebView2 runtime, a real IdP, or a real certificate/smart-card being present in
the test environment, none of which can be simulated. `IgnoreSSL` now reaches the WebView2 control
too (Finding F58) - unit-tested only for the parameter-forwarding half (SH-SSL01-04); the actual
`ServerCertificateErrorDetected`/`AlwaysAllow` behavior inside the real Chromium control has not
been confirmed live yet against a self-signed/internal-CA host - see A07/A08 below.

| # | Test Case | Pass Criteria |
|---|---|---|
| A01 | SelfHosted — CyberArk auth | Token returned; `SystemType=SelfHosted`; `TokenType=CyberArkSession`; `Authorization` header has no `Bearer` prefix |
| A02 | SelfHosted — LDAP auth | Token returned with `AuthMethod=LDAP` |
| A03 | SelfHosted — RADIUS auth | Token returned with `AuthMethod=RADIUS`; if the RADIUS server requires a challenge/response (e.g. a one-time passcode), confirm the prompt flow completes |
| A04 | SelfHosted — Shared auth | Token returned with `AuthMethod=Shared` |
| A05 | SelfHosted — PKI cert auth (**high risk**) | Correct cert selected via `Get-FilteredClientCertificate`; token returned; requires a real client certificate installed in the test environment's cert store |
| A06 | SelfHosted — PKIPN auth (**high risk**) | Same as A05 but via PIN-protected smart card/token; requires physical/virtual smart-card hardware |
| A07 | SelfHosted — SAML auth (**high risk**) | WebView2 window opens; IdP login completes; token captured via cookie/redirect detection. With `IgnoreSSL=$true` against a lab host with a self-signed/internal-CA cert (Finding F58): the WebView2 window navigates through without a certificate-error interstitial blocking it. With `IgnoreSSL=$false` against the same host: the interstitial correctly still appears (confirms the bypass isn't accidentally always-on) |
| A08 | SelfHosted — OIDC auth (**high risk**) | Same as A07 but OIDC flow; confirm token exchange completes and `Token`/`TokenType` are populated correctly; same `IgnoreSSL` on/off self-signed-cert check as A07 |
| A09 | Save-AuthToken | `.cred` file created/updated under the profile's token storage location |
| A10 | Import-AuthToken — valid token | Token object returned with all fields (`Token`, `TokenType`, `Headers`, `Expiry`, `SystemType`, `AuthMethod`, `BaseURL`, `Created`, etc.) |
| A11 | Import-AuthToken — expired token on disk | Caller correctly detects expiry (session age > `$script:PVWA_SESSION_EXPIRY_MIN`) and triggers re-authentication rather than using a dead token |
| A12 | Update-SelfHostedAuthToken — silent re-auth path | Confirm this uses the stored `_RefreshContext` credentials without prompting, for auth methods where that's expected; K06/F56 fixed the `Get-Credential` fallback for automation mode specifically - this item covers the still-unchanged interactive-mode behavior |
| A13 | Get-AuthTokenProfiles | All saved profiles listed |
| A14 | Remove-AuthTokenProfile | Token file removed; profile no longer resolves a stored token |
| A15 | IgnoreSSL — self-signed cert environment, non-WebView2 methods (CyberArk/LDAP/RADIUS/Shared/PKI/PKIPN) | No SSL error |
| A19 | IgnoreSSL — switch from an `IgnoreSSL=$true` profile to a different profile with `IgnoreSSL=$false` in the same running session (no restart), then call any API against a host with a real, valid certificate (Finding F57/K02) | The second profile's call succeeds normally with real certificate validation active - no SSL error, and no silent continued bypass from the first profile |
| A16 | Import-AuthToken — Created field | Returned token's `Created` equals the token file's persisted save time, not the load time; re-saving via `Save-AuthToken` after a refresh updates `Created` to the refresh time |
| A17 | `Invoke-SelfHostedKeepalive` persists extended expiry (Findings F08) | After a keepalive call (`GET /API/LoggedOnUser`), confirm the on-disk token file's expiry is updated, not just the in-memory session token |
| A18 | Logoff | `POST /API/auth/Logoff` called on exit (D12); confirm the PVWA session is actually invalidated server-side (a captured token can no longer be used) |

---

## ISPSS Auth — Manual Integration Test Procedures

`Auth/CyberArk.Auth.ISPSS.psm1` implements all 3 documented ISPSS/Privilege Cloud auth methods:
`ClientCredentials`, `Interactive`, and `SSO`. Reviewed 2026-09-04 against CyberArk's own reference
material at `C:\Code\References\CyberArk ISPSS\` (the "API Token" folder's two docs are the only
ones there that actually document authentication - the "Access API" and "User Management APIs"
folders are generated Swagger SDKs for *post-authentication* operations, not auth setup) - this
review found and fixed a real bug (see Finding F36) that would have crashed every
`ClientCredentials` login. `ClientCredentials`'s response-parsing logic now has unit coverage
(`Tests\Unit\CyberArk.Auth.ISPSS.Tests.ps1`, ISPSS-CC01-CC06, `Invoke-RestMethod` fully mocked) -
the first automated coverage this module has ever had. `Interactive` (a live MFA challenge/response
loop against `/Security/StartAuthentication` and `/Security/AdvanceAuthentication`) and `SSO` (a
WebView2 browser window capturing a cookie) still require a real tenant and are not unit-testable,
matching the Self-Hosted SAML/OIDC/PKI/PKIPN precedent above.

| # | Test Case | Pass Criteria |
|---|---|---|
| AI01 | ISPSS — ClientCredentials auth | Token returned; `SystemType=ISPSS`; `AuthMethod=ClientCredentials`; `Authorization` header is `Bearer <token>`; no crash regardless of whether the response includes a `refresh_token` field (F36) |
| AI02 | ISPSS — Interactive auth, single-factor (password only) | `StartAuthentication` returns one challenge with one mechanism; password submitted via `AdvanceAuthentication`; token returned with `AuthMethod=Interactive` |
| AI03 | ISPSS — Interactive auth, MFA (multiple mechanisms/challenges) | Mechanism picker shown when more than one option exists; each challenge in sequence is satisfied (password, OTP/SMS, push); token returned only after the full challenge loop completes |
| AI04 | ISPSS — Interactive auth, OOB (out-of-band) push approval | `StartOOB` triggered; polling loop shows elapsed time; approving on the mobile device returns a token before the 300s timeout; declining/timing out surfaces a clear error, not a hang |
| AI05 | ISPSS — Interactive auth, external IdP redirect (`IdpRedirectShortUrl` present) | Browser opens to the IdP; PIN prompt shown after login; PIN submitted via `AdvanceAuthentication` returns a token |
| AI06 | ISPSS — SSO auth | WebView2 window opens to `{IdentityURL}/login`; `idToken` cookie captured; token returned with `AuthMethod=SSO` |
| AI07 | Resolve-IdentityTenantURL — platform-discovery succeeds | Identity tenant URL resolved from the live `platform-discovery.cyberark.cloud` service's `identity_user_portal.api` field, not the constructed fallback |
| AI08 | Resolve-IdentityTenantURL — platform-discovery unreachable/malformed | Falls back to `https://<subdomain>.id.cyberark.cloud` without throwing; a WARN is logged |
| AI09 | Update-ISPSSAuthToken — ClientCredentials re-auth | Since a `ClientCredentials` token never carries a `refresh_token` (F36, confirmed against the documented response shape), confirm this always falls through to a full `Invoke-ISPSSClientCredentials` re-auth rather than attempting the (effectively dead, see F36's note) `refresh_token` grant branch |
| AI10 | Update-ISPSSAuthToken — Interactive re-auth | Re-runs the full MFA challenge loop; confirm this doesn't silently succeed without actually prompting (Interactive tokens have no refresh path by design) |
| AI11 | Update-ISPSSAuthToken — SSO re-auth | Re-opens the WebView2 window; confirm a fresh `idToken` is captured |
| AI12 | ISPSS token used against `Invoke-CyberArkAPI` | `Get-PVWASessionTimeoutMinutes` (`GET {BaseURL}/api/Settings/Timeout`) is expected to 404 on ISPSS (per the code comment) and fall back to the 4-hour default expiry - confirm this fallback actually triggers rather than crashing on the 404 |

---

## Manage-Privilege.ps1 — Manual Integration Test Procedures

| # | Test Case | Pass Criteria |
|---|---|---|
| D01 | First launch — no profiles | "No profiles found" shown; N/Q offered |
| D02 | Create new profile | JSON file created; profile appears in list |
| D03 | Edit profile — change log folder | JSON updated; `Modified` timestamp changed |
| D04 | Copy profile | New JSON with new name; auth token file NOT copied |
| D05 | Delete profile | Both JSON and XML removed |
| D06 | Test Connection — valid token | "Connection successful" with expiry shown |
| D07 | Continue — saved valid token | Session starts without re-auth |
| D08 | Continue — expired token, ClientCredentials | Silent refresh; session starts |
| D09 | Continue — expired token, Interactive | Re-auth prompt shown |
| D10 | B navigation | Returns to profile list |
| D11 | Restart (R) | Returns to profile list; current profile is default |
| D12 | Exit (X) | Logoff called (SelfHosted); script exits cleanly |
| D13 | Inactivity timeout | Session ends after `$InactivityTimeoutMin` of no input |
| D14 | Inactivity warning | Warning shown at 90% of timeout |
| D15 | Token expiry warning in menu footer | Yellow color; correct minutes shown |
| D16 | WhatIf mode | Menu shows `[WhatIf ON]`; write calls suppressed |
| D17 | Module discovery | All `.ps1` files in `APIModules\` appear in menu |
| D18 | SelfHosted-only module hidden for ISPSS | Module absent from ISPSS session menu |
| D19 | Logon with a valid but old saved token (`Created` > 15 min ago) | "Saved token is N minute(s) old - refreshing..." shown; a fresh/refreshed token is used for the session, not the stale one |
| D20 | Logon with a valid, recently-saved token (`Created` < 15 min ago) | No refresh message; token loaded directly, unchanged from today's behavior |
| D21 | Any module call returns HTTP 401 with a message that does NOT contain the word "401" or "Unauthorized" | Session is still invalidated — re-auth prompt appears on the next action, same as a normally-worded 401 |
| D22 | Any module call fails with a genuine network error (`StatusCode 0`) | Session is also invalidated (by design, since `IsFatal` covers both cases) — re-auth prompt appears; confirm this is the intended tradeoff, not a regression |
| D23 | **(Findings F09)** Stay inside a single category and perform several actions in a row, spanning past a keepalive interval, without ever returning to the category menu | Inactivity check, proactive refresh, and token-expiry (`Expired`/`Warning`) handling all fire correctly from *inside* the action loop, not only when returning to the category menu — this is a fix made this session and was previously broken |
| D24 | **(Findings F08)** Trigger a keepalive (`Invoke-SelfHostedKeepalive`) by staying logged in past the keepalive threshold, then kill the process (e.g. close the console) without a clean exit, then relaunch | The reloaded token's expiry reflects the keepalive-extended session, not the original pre-keepalive expiry — confirms the extended expiry was actually persisted to disk, not just held in memory |
| D25 | Full session using a live Self-Hosted profile end-to-end: profile creation → auth → category menu → several module actions across categories → inactivity warning → idle past timeout → re-auth → exit | No unhandled exceptions; log file contains a coherent full-session narrative; summary block at exit reflects all actions taken |
| D26 | Profile Selection → `[K]` Backup, select 2+ profiles (one with a saved token, one without) by comma-separated number, save the `.zip` | Zip created at the chosen path; contains each profile's `.json`, the `.cred` only for the one that had a saved token, and a `_manifest.json`. Core zip I/O logic (`Backup-DriverProfiles`) is verified via a standalone repro (see Finding F51) - this is the interactive-menu wrapper (`Invoke-ProfileBackupFlow`) around it |
| D27 | Profile Selection → `[K]` Backup, type `all` instead of numbers | Every profile is included in the zip |
| D28 | Profile Selection → `[X]` Restore, pick the `.zip` from D26, restore only the profile that has no local counterpart | Correct `.json` written; no `.cred` written (none was in the zip for that profile); no overwrite prompt shown (nothing to conflict with) |
| D29 | Delete a profile that still has a backup `.zip` from before deletion, then `[X]` Restore it back, this time to a name that still exists locally | Confirmation prompt shown before overwriting; declining leaves the existing local profile untouched |
| D30 | Copy (via any file-copy method) a `.zip` produced by Backup to a different Windows user account or a different machine, then `[X]` Restore it there | `.json` settings restore correctly; the restored `.cred` cannot be decrypted (expected - DPAPI is user+machine-locked) - the Restore screen shows a clear portability warning naming the affected profile(s), and the profile's `TokenStatus` subsequently shows `Unreadable`, prompting normal re-authentication on Connect rather than a crash |
| D31 | Launch with `-StartProfile "<name>" -AutoConnect` for a complete, working profile | Skips the profile list/detail menus entirely; authenticates and enters the session directly |
| D32 | Launch with `-StartProfile "<name-that-does-not-exist>" -AutoConnect` | Prints a clear "no profile found" message and falls back to the normal interactive profile list, rather than exiting or crashing |
| D33 | Launch with `-StartProfile "<name>" -AutoConnect` where that profile is incomplete (missing System Type or Base URL) | Prints a clear "profile is incomplete" message and falls back to the normal interactive profile list |
| D34 | Launch with `-StartProfile "<name>" -AutoConnect` where authentication fails (e.g. wrong password) | Prints the authentication error with no `Read-Host` pause (unattended-safe), then falls back to the normal interactive profile list rather than hanging or exiting |
| D35 | Launch with `-AutoConnect` but no `-StartProfile` | Fails fast at startup with a clear parameter error ("-AutoConnect requires -StartProfile") before any profile/module loading happens |
| D36 | With `-StartProfile "<name>" -AutoConnect`, connect successfully, then choose Restart from the session menu | Restart returns to the normal interactive profile list (pre-selecting the same profile, existing behavior) rather than auto-connecting again - `-AutoConnect` applies only to the initial launch |
| D37 | From a genuinely non-interactive host (e.g. `schtasks /run`, or `powershell.exe -NonInteractive -File ...`), run `-StartProfile "<name>" -Category <cat> -Action <action>` for a profile with a valid, refreshable saved session | Runs to completion with no prompt of any kind; exits `0` on success (or `2` if the action itself reported item-level failures); the profile's log file contains a coherent narrative of the run |
| D38 | Same as D37, but for a profile with no saved token at all (never logged in interactively) | Exits promptly with code `3` and a clear log message ("fresh authentication is always interactive... log in interactively at least once first") - no hang, no WebView2/credential prompt of any kind |
| D39 | Same as D37, but for a profile whose `AuthMethod` is SAML, OIDC (Self-Hosted), Interactive, or SSO (ISPSS) and whose saved token has expired | Exits promptly with code `3` - these methods have no silent refresh path at all, so automation mode must fail fast rather than ever opening a browser/MFA challenge |
| D40 | `-StartProfile "<name>" -Category Safes -Action Delete -InputJson '{"SafeName":"<a safe that will 409 on delete>"}'`, and separately, lock the profile's output CSV file (e.g. open it in Excel) before running an export-style action with `-InputJson` | Both cases fail cleanly and immediately (exit `2` or `3` as appropriate) with a clear log message, rather than pausing on `Invoke-SafesDelete.ps1`'s rename-offer prompt or `Invoke-FileWriteWithRetry`'s retry prompt the way an interactive session would |
| D41 | `-StartProfile "<name>" -Category Custom -Action ExportEntitlements -InputJson '{}' -OutputFolder "<a folder that does not exist yet>" -FilenameFormat "{Profile}_{ModuleName}_{Date}"`, and separately `-Category Custom -Action ExportAll -InputJson '{}' -OutputFolder "<folder>"` (no `-FilenameFormat`) | The first run creates the folder if needed and saves one CSV there named per the template (e.g. `Prod_Export Entitlements_2026-09-19.csv`). The second run redirects Export All's several per-sub-report CSVs (`Export_AccountsList.csv`, etc.) to the same override folder, keeping their existing fixed names unchanged |
| D42 | Run `-StartProfile "<name>" -Category Custom -Action ExportEntitlements -InputJson '{}'` (no `-FilenameFormat`) twice, on two different days if possible, or with the file's timestamp checked between runs | Both runs save to the exact same filename (`Export Entitlements.csv`, no date) in the profile's `OutputFolder` - the second run overwrites the first rather than creating a second, dated file. Repeat for Export Group Members (Local), Export Group Members (LDAP), and Export Platform Details to confirm all 4 behave identically |
| D43 | For a CyberArk/LDAP/RADIUS profile: manually edit or delete the `Credential` entry from its saved `.cred` file's `_RefreshContext` (or simulate by deleting `.cred` entirely and letting a token go `Expired`), then run `-StartProfile "<name>" -Category Safes -Action List -InputJson '{}'` with no `.autocred` stored | Exits promptly with a clear log message that no credential is available and interactive prompting is disabled - no hang, no `Get-Credential` popup. Then set a credential via the profile detail menu's `[A]` action and re-run the same command | The run now succeeds, refreshing silently using the stored credential |
| D44 | Connect to a profile with a still-valid saved token, then `[E]dit` the profile and change its Base URL to a different (but still reachable) PVWA/tenant, then `[C]onnect` again without deleting the saved token (Testing_Findings-and-Known-Issues.md K04) | A fresh, interactive login is required against the *new* URL - the saved token is not silently reused against the old URL, and no API call is ever made to the pre-edit server. Repeat via `[T]est Connection` on the profile-detail menu to confirm the same behavior there |
| D45 | For a CyberArk/LDAP/RADIUS profile whose saved token has no `_RefreshContext.Credential` (e.g. delete just that key from the `.cred` file) but whose profile has a `Username` set, let the session expire mid-run and trigger `Invoke-TokenRefresh` interactively (Testing_Findings-and-Known-Issues.md K07) | The "Signing in as: `<profile's Username>`" line appears and only a password is prompted for - no extra "Username" prompt |
| D46 | On a machine where `Microsoft.Web.WebView2.WinForms.dll` is NOT in any of the default candidate locations (temporarily rename `Auth\WebView2\` if needed), set a SAML/OIDC/SSO profile's **WebView2 Assembly Path** field to the DLL's actual location via `[E]dit`, then `[C]onnect` (Testing_Findings-and-Known-Issues.md K11) | The WebView2 window opens successfully using the path from the profile field, instead of throwing `Microsoft.Web.WebView2.WinForms.dll not found`. Clearing the field again (with the DLL still absent from the default locations) reproduces the original error |
