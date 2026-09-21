---
name: phase0-credential-logging-fix-status
description: Work-in-progress status for the Phase 0 credential-logging fix branch, as of 2026-09-02. Read this first if resuming after a restart.
---

# Phase 0 Status — resume point

**Branch:** `phase0-credential-logging-fix` (created from `main`)
**As of:** 2026-09-02
**State:** Committed to git (commit `edb6d4e` in this environment's sandbox clone — device shell access on `desktop-tiju5c2` was still unavailable when this was picked back up, so the commit was made in a separate git clone and needs to reach the real `C:\Code\aPePAS` via bundle/patch, same delivery mechanism as the `selfhosted-test-review-2026-09-02` branch). **Still not tested against real PowerShell or a live tenant.**

## Why this file exists

This session's shell access to this computer (`desktop-tiju5c2`) was unavailable throughout this work — the isolated Linux environment for device tools failed to start, so nothing could run `git`, `pwsh`, or `Invoke-Pester` here. Every file below was written directly to disk via the file bridge (not through git), so the changes themselves survive an app or session restart independent of this document. This file is the record of what changed and what's still open, so a new session (or you, picking this up manually) doesn't have to reconstruct that from scratch.

## What's done

All six Phase 0 items from `Docs\aPePAS-Improvement-Plan-2026-09-02.md` are implemented, plus two Phase 4 items the user asked to pull forward (the PVWA timeout API call and the ISPSS identity-URL discovery rework). Files changed, all currently uncommitted on this branch:

- `Modules\CyberArkComms.psm1` — `Invoke-CyberArkAPI` now encodes the JSON request body as UTF8 bytes before calling `Invoke-WebRequest`, instead of passing a plain string.
- `Auth\CyberArk.Auth.SelfHosted.psm1` — same byte-encoding fix in `Invoke-PVWALogon`. Added `Get-PVWASessionTimeoutMinutes` (calls `GET /api/Settings/Timeout` after logon; falls back to the old hardcoded 20-minute constant only on failure) and wired it into all five self-hosted auth-method functions (`Invoke-SelfHostedPasswordAuth`, `-Shared`, `-PKI`, `-SAML`, `-OIDC`).
- `Auth\CyberArk.Auth.ISPSS.psm1` — byte-encoding fix at all four raw `Invoke-RestMethod` call sites (`Invoke-ISPSSClientCredentials`, `Invoke-IdentityAdvancedAuth`, `Invoke-ISPSSInteractive`'s `StartAuthentication` call, and the refresh_token grant inside `Update-ISPSSAuthToken` — this last one was found during implementation, not in the original plan). `Resolve-IdentityTenantURL` rewritten to call CyberArk's platform-discovery endpoint (`https://platform-discovery.cyberark.cloud/api/v2/services/subdomain/{subdomain}`) instead of probing three guessed hostnames; the old constructed-URL fallback is kept as a last resort if that call fails.
- `Modules\CyberArkLogging.psm1` — added `AuthValue` to `$script:SensitivePatterns` so Applications auth-method credentials are masked in the app's own debug log.
- `Tests\Unit\CyberArkComms.Tests.ps1` — updated test `C25a` (which inspected `Invoke-WebRequest`'s `Body` parameter as a string) to decode the new byte array first; added `C25d` asserting the body is `System.Byte[]` and round-trips correctly.
- `Tests\Unit\CyberArkLogging.Tests.ps1` — added `L22d`, masking test for the new `AuthValue` pattern.

## Update — picked back up 2026-09-02, later the same day

A follow-up session reviewed all six files before committing and found one real regression:
**`Auth\CyberArk.Auth.SelfHosted.psm1` and `Auth\CyberArk.Auth.ISPSS.psm1` had lost their required
UTF-8 BOM** during the original editing pass (confirmed via byte inspection — no `EF BB BF` at the
start of either file, present on the other four). Both files contain a pre-existing em-dash inside
a string literal (`throw "Token object missing _RefreshContext — cannot refresh."` in each file's
`Update-*AuthToken` function). Per this project's own `Lessons-Learned-PowerShell-Pester.md`
Section 26, an em-dash inside a string literal in a no-BOM file breaks PS 5.1 parsing — Windows
PowerShell reads the file as Windows-1252, and the UTF-8 byte sequence for the em-dash is misread
as a closing double-quote, truncating the string and corrupting the rest of the line. This wasn't
a pre-existing bug (the files always had a BOM before this branch's edits) — it was introduced by
whatever process wrote the files during this branch's implementation. Fixed by restoring the BOM
byte-for-byte with content otherwise unchanged; no logic was touched. All six files were then
syntax-sanity-checked (brace/paren/bracket balance) with no other issues found, and committed as
`edb6d4e` on this branch.

## What's NOT done

1. **Tests still haven't been run.** No PowerShell interpreter was available to either this session
   or the one that wrote the original changes — no pwsh in the cloud workspace either time, and no
   shell access to this computer either time. Run `.\Tests\Run-Tests.ps1` (or at minimum
   `Invoke-Pester Tests\Unit\CyberArkComms.Tests.ps1`, `Tests\Unit\CyberArkLogging.Tests.ps1`)
   before trusting this branch — this is now the single most important open item, since two
   separate sessions have made non-trivial changes to security-sensitive, widely-shared code
   (`Invoke-CyberArkAPI`, all Self-Hosted and ISPSS logon paths) with zero real test execution.
2. **Live-tenant verification of the timeout/discovery changes hasn't happened.** `Get-PVWASessionTimeoutMinutes` and the platform-discovery call in `Resolve-IdentityTenantURL` are new network calls to endpoints that were only verified by reading psPAS's source, not by hitting a real PVWA/ISPSS tenant. Worth a manual auth test against a real environment before merging.
3. **Phases 1 through 6 of the improvement plan are untouched** — see `Docs\aPePAS-Improvement-Plan-2026-09-02.md` for the full list (endpoint-path verification, the Platforms scope gap, validation hardening, etc.).
4. **This branch and `selfhosted-test-review-2026-09-02` (a separate, earlier piece of work — a Self-Hosted test plan, 10 unrelated bug fixes, and an ISPSS test plan) both currently sit as uncommitted/bundle-only work relative to the real `C:\Code\aPePAS` repo.** They touch different files except both modified `Auth\CyberArk.Auth.ISPSS.psm1` and `Auth\CyberArk.Auth.SelfHosted.psm1` in different, likely-compatible ways (one rewrote `Resolve-IdentityTenantURL` and auth-body encoding; the other fixed two driver-adjacent items and deleted the dead `Get-AuthToken.ps1` shim elsewhere). They have not been merged or rebased against each other — decide the intended merge order before landing both on `main`.

## Reference documents already saved in this repo

- `Docs\psPAS-Comparison-Review-2026-09-02.md` — the full comparison review this work is based on.
- `Docs\aPePAS-Improvement-Plan-2026-09-02.md` — the phased plan; Phase 0 is what this branch implements.

## To resume

If shell access to this computer is working again: run the test suite, fix anything it surfaces, decide how this branch and `selfhosted-test-review-2026-09-02` should be merged relative to each other, then merge both into `main`. If shell access is still down: this status file plus the git history on this branch (delivered as a bundle/patch — ask the session that made commit `edb6d4e` for the latest one, or check `C:\Code\` for `phase0-credential-logging-fix.bundle`) is everything needed to pick the work back up.
