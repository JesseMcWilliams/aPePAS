# aPePAS: Privilege Cloud (ISPSS) Full Functional Checklist

> **Stage: Testing.** How to run a live pass against ISPSS / Privilege Cloud. Status lives in [Testing_Status.md](Testing_Status.md), not here.

## Privilege Cloud (ISPSS) Live Pass

This is the counterpart to the [Self-Hosted checklist](Testing_Checklist-Self-Hosted.md), for a live functional pass against a
real Privilege Cloud (ISPSS) tenant. Per the caution section near the top of this document, most of
this project's iterative bug-fixing history was driven by Self-Hosted testing — the large majority
of items below are still genuinely unconfirmed on ISPSS even though the code path is shared
(dual-use). Use a **dedicated test Safe and test accounts** for every write action, and **never run
this pass against a production Privilege Cloud tenant.**

### This pass requires interactive human authentication — it cannot be scripted or run unattended

**Update 2026-09-21:** this is still true for the driver's own normal interactive menu flow (no
CLI switch lets a fresh cold-start login supply a credential directly through it). However, since
K12/F62, `Interactive`'s underlying Auth module function (`Get-ISPSSAuthToken`) itself accepts
`-Credential` directly and completes silently when the identity resolves to a single password-only
challenge - this is how the read-only portion of this pass below was actually run: a script called
`Get-ISPSSAuthToken -AuthMethod Interactive -Credential $cred` directly (bypassing the driver's
interactive menu entirely, mirroring the same approach used for the Self-Hosted pass), saved the
resulting token, then drove `Manage-Privilege.ps1 -Category`/`-Action` automation mode from there
- no human sat at a console for any of it. One real environment-specific detail found doing this:
this tenant's CyberArk Identity requires the **UPN format** (`user@company.com`), not the bare
username - the bare username resolved to a *different* identity that had MFA enrolled, causing a
confusing initial failure. Confirm this matches your own tenant's identity format before assuming
a bare username will work.

Unlike `ClientCredentials` (a silent service-account grant, already covered by unit tests
`ISPSS-CC01`–`CC06` and not the focus of this pass), the whole point of this checklist is to
exercise a **real interactive login**, so a person must be sitting at the console for the entire
session:

- **`Interactive`** prompts for a CyberArk Identity username (if not already known), shows a
  numbered mechanism picker when more than one challenge mechanism is configured (e.g. password vs.
  OTP vs. push), and then blocks on `Read-Host` waiting for the answer to each challenge in turn —
  see `Invoke-ISPSSInteractive` in `Auth\CyberArk.Auth.ISPSS.psm1`. If out-of-band (OOB) push
  approval is configured, the process polls and blocks for up to 300 seconds waiting for approval
  on a mobile device.
- **`SSO`** opens a WebView2 browser window that requires an actual interactive sign-in (and an IdP
  redirect, if the tenant is federated) before it captures the session cookie.

Run this pass with whichever of `Interactive`/`SSO` the test tenant actually has configured; if
both are usable, run the profile-setup-and-login step once for each, since they exercise different
code paths (`AI02`–`AI06` in the ISPSS Auth section of [Testing_Manual-Integration-Procedures.md](Testing_Manual-Integration-Procedures.md)) even though every module action below is
identical either way once a token exists.

### Known ISPSS-specific behavior (expected — do not report these as new bugs)

- **`Groups/List`'s `GroupType` filter is unusable on ISPSS.** Every group — including
  LDAP/directory-backed ones — comes back with `groupType='Vault'` and no `directory.directoryType`,
  so filtering for anything but `Vault` silently returns zero rows. `Custom/ExportGroupMembersLDAP`
  and `Custom/ExportGroupMembersLocal` work around this with a groupName-contains-`@` heuristic
  instead of trusting `GroupType` (see the Self-Hosted vs. Privilege Cloud caution section in [Testing_Plan.md](Testing_Plan.md) and `Reference_Lessons-Learned-CyberArk-API.md` §7).
- **`Policies/GetMasterPolicy` has already been confirmed live to have no equivalent on ISPSS at
  all** (Finding F40, 2026-09-04) — it should return a clean, non-crashing `Failure`, not `IsFatal`.
  No further action is needed here unless specifically re-verifying after other recent changes.
- **`Reports/List`, `Reports/Export`, `Platforms/Rename`, and `Policies/SetMasterPolicy` are Self-Hosted-only** and
  will not appear on an ISPSS profile's menu at all — this is expected (see the driver-level check
  below, which confirms exactly this).
- **`Get-PVWASessionTimeoutMinutes` (`GET {BaseURL}/api/Settings/Timeout`) 404s on ISPSS** and falls
  back to a 4-hour default expiry (see `AI12` above) — an expected fallback, not an error.

### Where things are
- **Status** of every action and check: [Testing_Status.md](Testing_Status.md) (the ISPSS column). Update it there after each run; this file holds no status.
- Start with LT-SETUP-01/02 and LT-LOGON-01 for the ISPSS profile ([Testing_Live-Test-Definitions.md](Testing_Live-Test-Definitions.md)).

### Step 1 — Profile setup

- Create or select a profile; set **System Type = `[1] Privilege Cloud`**.
- Set **Auth Method = `[2] Interactive`** or **`[3] SSO`** (not `[1] ClientCredentials`, for the
  reason above).
- Enter the tenant's **Privilege Cloud Subdomain** (the `acme` in
  `acme.privilegecloud.cyberark.cloud`); confirm `Tenant Portal`/`Tenant Vault` are derived
  correctly and `Discovering identity URL...` resolves to a real `Tenant Auth` value (`AI07`) —
  or falls back cleanly with a `WARN` if discovery fails (`AI08`).

### Step 2 — Authentication (see the ISPSS Auth section of Testing_Manual-Integration-Procedures.md for full AI01-AI12 procedures)

- `AI02`/`AI03`/`AI04`/`AI05` — whichever `Interactive` challenge shape(s) the tenant is
  configured for (single-factor, MFA mechanism picker, OOB push, or external IdP redirect)
- `AI06` — `SSO`, if also configured for this tenant
- `AI09`/`AI10`/`AI11` — re-authentication path for whichever method was used above (let a
  session run long enough to trigger this, or force it by manually expiring/deleting the saved
  token)
- `AI12` — session-timeout-endpoint 404 fallback (see the expected-behavior note above)

### Step 3 — Driver-level ISPSS-specific checks

- `D18` — confirm `Platforms/Rename`, `Policies/SetMasterPolicy`, `Reports/List`, `Reports/Export`, the
  Users write actions and the Dependent and Discovered account actions are **all absent** from this
  profile's category menus (Self-Hosted-only, hidden for ISPSS)
- Profile list / header display correctly shows `Privilege Cloud` as the System Type
- WhatIf mode toggled on for this profile — confirm write suppression works identically to
  Self-Hosted

### What to check on ISPSS specifically

- **Accounts:** List's By-Safe mode and whether the ~20K no-safe-filter cap behaves the same;
  ResumeAutoManagement's ISPSS path, which was never confirmed; the safe-name-with-a-space filter in
  at least one `AccountName`+`Safe` action; LT-ACCOUNTS-01; JIT and RetrieveSshKey support comes from
  psPAS only.
- **Driver script and job files:** LT-DRIVER-01 with a ClientCredentials profile (username = client
  ID, password = secret) and an Interactive profile without MFA, both with no saved session; LT-JOB-01
  logs in once (watch the CyberArk Identity rate limit) with the right exit code per step.
- **Safes:** the `Get-CpmOptions` CPM query and its fallback to `CPM_List`; AssignCPM's
  `GET /API/Users?userType=CPM&componentUser=true`; F44 name validation doesn't reject a valid ISPSS
  name; F74 Add Safe From Template; F77 (an AutoPurgeEnabled value logs the warning and changes
  nothing).
- **SearchIn picker (F76/K20):** lists the tenant's Identity directories after Vault, with their GUID
  as the value, and an LDAP member added with one succeeds.
- **SafeMembers:** the four presets (`ReadOnlyStrict`, `EndUser`, `PowerUser`, `SafeManager`, F47);
  F85 as in the Self-Hosted checklist; `includePredefinedUsers` (F78) and the `MemberType` /
  `MembershipExpired` / `Sort` filters are accepted (no HTTP 400 retry in the log).
- **Platforms:** Get's field shape (`id` vs `PlatformID`, `general`-nested vs root); `PlatformType`
  is accepted.
- **Users:** Get, Delete, Unblock and ResetPassword on a Vault-local (non-Identity) test user only.
- **Groups and Custom:** AddMember / GetMembers (F42/F43); ExportGroupMembersLDAP and
  ExportGroupMembersLocal tell LDAP groups from local ones with the `@` heuristic; TestApi's base URL;
  TestConnectivity's vault-password lookup through the ISPSS `Accounts` endpoint; F86.
- **Applications:** the 6 actions other than Add have only had menu visibility checked; include a
  `certificateattr` method in AddAuthMethod, and a blank `AppID` in ListAuthMethods.
- **F70/F71** (PS 7 and PS 5.1): Export All doesn't run `Policies/GetMasterPolicy`; running it directly
  returns a real 404 (not StatusCode 0) and no re-login; with the token expired mid-run, Export All's
  `GET /API/Safes?limit=1` re-check returns 401 and the run stops and re-authenticates.

### Full end-to-end session

- One complete session mirroring `D25`: profile creation → `Interactive` or `SSO` login →
      category menu → several module actions spanning multiple categories → an inactivity warning
      → idle past timeout → re-auth → clean exit. Confirm no unhandled exceptions and that the log
      file and exit summary reflect a coherent narrative of everything that happened.
