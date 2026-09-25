# aPePAS: Privilege Cloud (ISPSS) Full Functional Checklist

> **Stage: Testing.** Per-action live test checklist for ISPSS / Privilege Cloud. Split out of [Testing_Plan.md](Testing_Plan.md) on 2026-09-25; keep it under ~500 lines.

## Privilege Cloud (ISPSS) Full Functional Checklist

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
- **`Reports/List`, `Platforms/Rename`, and `Policies/SetMasterPolicy` are Self-Hosted-only** and
  will not appear on an ISPSS profile's menu at all — this is expected (see the driver-level check
  below, which confirms exactly this).
- **`Get-PVWASessionTimeoutMinutes` (`GET {BaseURL}/api/Settings/Timeout`) 404s on ISPSS** and falls
  back to a 4-hour default expiry (see `AI12` above) — an expected fallback, not an error.

### Step 1 — Profile setup

- [ ] Create or select a profile; set **System Type = `[1] Privilege Cloud`**.
- [ ] Set **Auth Method = `[2] Interactive`** or **`[3] SSO`** (not `[1] ClientCredentials`, for the
      reason above).
- [ ] Enter the tenant's **Privilege Cloud Subdomain** (the `acme` in
      `acme.privilegecloud.cyberark.cloud`); confirm `Tenant Portal`/`Tenant Vault` are derived
      correctly and `Discovering identity URL...` resolves to a real `Tenant Auth` value (`AI07`) —
      or falls back cleanly with a `WARN` if discovery fails (`AI08`).

### Step 2 — Authentication (see the ISPSS Auth section of Testing_Manual-Integration-Procedures.md for full AI01-AI12 procedures)

- [ ] `AI02`/`AI03`/`AI04`/`AI05` — whichever `Interactive` challenge shape(s) the tenant is
      configured for (single-factor, MFA mechanism picker, OOB push, or external IdP redirect)
- [ ] `AI06` — `SSO`, if also configured for this tenant
- [ ] `AI09`/`AI10`/`AI11` — re-authentication path for whichever method was used above (let a
      session run long enough to trigger this, or force it by manually expiring/deleting the saved
      token)
- [ ] `AI12` — session-timeout-endpoint 404 fallback (see the expected-behavior note above)

### Step 3 — Driver-level ISPSS-specific checks

- [ ] `D18` — confirm `Platforms/Rename`, `Policies/SetMasterPolicy`, and `Reports/List` are **all
      absent** from this profile's category menus (Self-Hosted-only, hidden for ISPSS)
- [ ] Profile list / header display correctly shows `Privilege Cloud` as the System Type
- [ ] WhatIf mode toggled on for this profile — confirm write suppression works identically to
      Self-Hosted

### Accounts (17 actions, all dual-use)

- [ ] Add · [ ] CancelCpmTask · [ ] ChangeImmediate · [ ] ChangeInVault · [ ] CheckIn · [ ] Delete ·
      [ ] Get · [ ] GetActivity · [ ] GetCredential ·
      [ ] LinkAccount (confirmed working on Self-Hosted this session — F41; ISPSS unconfirmed) ·
      [x] List (confirm By-Safe mode; confirm whether the ~20K no-safe-filter result cap behaves the
      same on ISPSS. **Confirmed live 2026-09-21** (read-only pass only - By-Safe mode/20K cap
      specifically not re-verified): 21 accounts via `Accounts/List`, 8 via `Custom/ExportAll`'s
      by-safe iteration across 29 safes) ·
      [ ] Reconcile ·
      [ ] ResumeAutoManagement (its ISPSS code path was deliberately left unchanged/unconfirmed when
      the Self-Hosted endpoint was corrected in Phase 1 — this is the first opportunity to confirm
      it actually works on a real tenant) ·
      [ ] UnlinkAccount (same as LinkAccount above) · [ ] Unlock · [ ] Update (JSON Patch) ·
      [ ] Verify
- [ ] For at least one `AccountName`+`Safe`-resolving action above, confirm the safe-name-with-a-
      space fix (all 16 call sites, routed through `New-CyberArkSearchFilter`) actually works against
      a safe whose name contains a space — unverified against any live tenant as of this writing.

### Safes (8 actions, all dual-use)

- [ ] Add (confirm the `Get-CpmOptions` live CPM query populates the picker on ISPSS, and that it
      falls back to the profile's `CPM_List` if the query fails) ·
      [ ] AddFromTemplate · [ ] AssignCPM (confirm `GET /API/Users?userType=CPM&componentUser=true`
      returns the expected CPM accounts on ISPSS) · [ ] Delete · [ ] Get ·
      [x] List (**confirmed live 2026-09-21**: 29 safes) ·
      [ ] UnassignCPM · [ ] Update
- [ ] This session's `SafeName` validation (length/reserved-characters/leading-whitespace — Finding
      F44) is unit-tested only; confirm it doesn't reject a legitimately-valid ISPSS safe name.

### SafeMembers (6 actions, all dual-use)

- [ ] Add (confirm the `SearchIn` directory picker — `GET /API/Configuration/LDAP/Directories` —
      against ISPSS; unconfirmed on any live tenant as of this writing) ·
      [ ] AddFromTemplateRole · [ ] List · [ ] Remove · [ ] Update · [ ] UpdateFromTemplateRole
- [ ] Confirm all four permission-role presets (`ReadOnlyStrict`, `EndUser`, `PowerUser`,
      `SafeManager` — renamed from `ReadOnly` this session, Finding F47) produce the correct
      permission set on Add and Update.

### Platforms (9 of 10 actions — `Rename` is Self-Hosted only, excluded)

- [ ] Get (confirm field-shape handling — `id` vs `PlatformID`, `general`-nested vs root — on
      ISPSS, unconfirmed) ·
      [x] List (same field-shape note - **confirmed live 2026-09-21**: 39 platforms, no field-shape
      issue observed) · [ ] Copy · [ ] Disable · [ ] Enable ·
      [x] Export (confirmed live on Self-Hosted only, for the `PlatformID` variant — **confirmed
      live 2026-09-21** for that same variant on ISPSS too, via `Custom/ExportPlatformDetails`:
      14/14 platforms succeeded) · [ ] Import · [ ] Remove (destructive — disposable sandbox
      platform only) · [ ] SetPSMConfig

### Policies (1 of 2 actions — `SetMasterPolicy` is Self-Hosted only, excluded)

- [x] GetMasterPolicy — **already confirmed (2026-09-04)**: no Master Policy equivalent exists on
      ISPSS; returns a clean, non-fatal `Failure`. **Re-confirmed live 2026-09-21**: clean `HTTP
      404`, handled as a non-fatal item within `Custom/ExportAll` (8/8 modules still reported
      success overall). No further action needed.

### Users (2 actions, dual-use)

- [ ] Get · [x] List (**confirmed live 2026-09-21**: 40 users)

### Groups (7 actions, dual-use — see the `GroupType='Vault'` note above)

- [ ] Add · [ ] AddMember (fixed and confirmed live on Self-Hosted this session — F42; ISPSS
      unconfirmed) · [ ] Delete · [ ] GetMembers (same — F43, Self-Hosted confirmed only) ·
      [x] List (**confirmed live 2026-09-21**: 70 groups; expect the `GroupType` filter to be
      unusable — see the known-behavior note above, not a bug to report) · [ ] RemoveMember ·
      [ ] Update

### Applications (7 actions, dual-use — only menu visibility has been confirmed on ISPSS so far)

- [ ] Add (menu visibility confirmed 2026-09-02; this session's new validation hardening — F45 — is
      unconfirmed on any live tenant) · [ ] AddAuthMethod · [ ] Delete · [ ] DeleteAuthMethod ·
      [ ] Get · [x] List (**confirmed live 2026-09-21**: 2 applications) ·
      [x] ListAuthMethods (**confirmed live 2026-09-21**: 2 applications checked, 0 auth methods
      returned — the blank-`AppID`-lists-every-application behavior itself remains unverified,
      since this run queried the 2 known applications directly rather than a blank `AppID`)
- These 6 (all but `Add`) were expanded from Self-Hosted-only to dual-use on 2026-09-02 after the
  user found only `Add` visible on the ISPSS menu. Their actual ISPSS request/response behavior has
  never been exercised — this is the first opportunity to do so.

### Custom (7 actions, dual-use)

- [x] ExportAll (**confirmed live 2026-09-21**: 8 modules run, 8 succeeded — it correctly did not
      attempt `Platforms/Rename`, `Policies/SetMasterPolicy`, or `Reports/List`, and
      `Policies/GetMasterPolicy`'s 404 degraded gracefully as a non-fatal item within the batch,
      matching the already-confirmed absent-endpoint behavior) ·
      [x] ExportEntitlements (**confirmed live 2026-09-21**: 29 safes, 114 members, 0 failures) ·
      [ ] ExportGroupMembersLDAP (this is the one export module where the `GroupType='Vault'` quirk
      matters most — its groupName-contains-`@` heuristic exists specifically to work around it;
      confirm it actually distinguishes LDAP from local groups correctly on this tenant) ·
      [ ] ExportGroupMembersLocal (same heuristic — confirm normal local/Vault-group export works) ·
      [x] ExportPlatformDetails (confirmed live on Self-Hosted only; **confirmed live 2026-09-21**
      on ISPSS too: 14/14 platforms succeeded) ·
      [ ] TestApi (platform-agnostic; confirm the base URL construction is correct for ISPSS) ·
      [ ] TestConnectivity (platform-agnostic DNS/port/SMB/SSH checks; confirm the vault-password
      fallback correctly resolves an account via the ISPSS `Accounts` endpoint)

- [ ] F70/F71 (PS 7 and PS 5.1) - Export All no longer runs `Policies/GetMasterPolicy`; running Get Master
      Policy directly returns a real 404 (not StatusCode 0) and no re-login; with the token expired mid-run,
      Export All's `GET /API/Safes?limit=1` re-check returns 401 and the run stops and re-authenticates

### Full end-to-end session

- [ ] One complete session mirroring `D25`: profile creation → `Interactive` or `SSO` login →
      category menu → several module actions spanning multiple categories → an inactivity warning
      → idle past timeout → re-auth → clean exit. Confirm no unhandled exceptions and that the log
      file and exit summary reflect a coherent narrative of everything that happened.
