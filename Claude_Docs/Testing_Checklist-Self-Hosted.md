# aPePAS: Self-Hosted Full Functional Checklist

> **Stage: Testing.** Per-action live test checklist for Self-Hosted PVWA. Split out of [Testing_Plan.md](Testing_Plan.md) on 2026-09-25; keep it under ~500 lines.

## Self-Hosted Full Functional Checklist

This is the master checklist for the live functional pass against `https://pvwa.company.com`
(or whichever Self-Hosted lab host is in use). It enumerates every module action in the project.
For each, run it at least once against the live host with realistic input (including at least one
CSV-batch run where the module supports one), confirm the result matches what's actually in the
Vault/PVWA (not just that the tool reported success), and note the PVWA version under test — see
the caution section in [Testing_Plan.md](Testing_Plan.md) for why version matters for Platforms/SafeMembers field-shape
differences.

Use a **dedicated test Safe and test accounts** for every write action (Add/Update/Delete/Change/
Reconcile/etc.) — never point a write action at production data.

### Auth (see the Self-Hosted Auth section of Testing_Manual-Integration-Procedures.md for the full A01-A18 procedures)
- [ ] All 8 auth methods: CyberArk, LDAP, RADIUS, Shared, PKI, PKIPN, SAML, OIDC
- [ ] Token save/load/refresh/keepalive/logoff lifecycle

### Accounts (17 actions)
- [x] Add (**confirmed live 2026-09-21** via automation mode against a real Self-Hosted PVWA -
      created a real account in a disposable test safe, `aPePAS-WriteTest`) ·
      [ ] CancelCpmTask (confirm the `/Cancel/` endpoint, Phase 1 this session — was
      `/StopImmediateAutoMgmtOperations` before; F14 this session added a 404 fallback to that
      same old endpoint for PVWA older than 15.2, unverified against a real pre-15.2 host; not
      attempted 2026-09-21 - no pending CPM task existed to cancel) ·
      [x] ChangeImmediate (**confirmed live 2026-09-21**: ran against the test account and
      confirmed via its `Activities` audit log that the account's `ResetImmediately` property was
      set to `ChangeTask`, per the user's specific verification request) ·
      [x] ChangeInVault (F12's `Password/Update` endpoint correction **confirmed correct
      2026-09-03** — a live 400 against it turned out to be a legitimate `PASWS001W` account-lock
      error once F16 let Test API surface the real body, not a bug in the endpoint/body shape.
      **Re-confirmed live 2026-09-21**: correctly does NOT touch `ResetImmediately` (it stores a
      new password directly in the vault rather than asking CPM to change it on the target) -
      the `Activities` log showed a plain "Store password" entry with no `ResetImmediately`
      update, exactly as expected) · [ ] CheckIn (not attempted 2026-09-21 - the test account was
      never checked out) ·
      [x] Delete (**confirmed live 2026-09-21** - cleaned up the test account after the write-action
      batch) · [x] Get (**confirmed live 2026-09-21**) ·
      [x] GetActivity (**confirmed live 2026-09-21** - this is also how `ResetImmediately` was
      confirmed for ChangeImmediate/Reconcile/Verify, see above/below) · [ ] GetCredential (not
      attempted 2026-09-21 - retrieves a live password value, deferred) ·
      [x] LinkAccount (F41 this session — **confirmed live**: previously logged as an unfixable
      live-tenant limitation (HTTP 404), the user has since retested and confirmed it now works
      correctly against the real tenant; no code change was involved) ·
      [x] List (incl. By-Safe mode, confirm 20K cap behavior — **confirmed 2026-09-02**, re-confirmed
      2026-09-21: 2440 accounts across 35 safes) ·
      [x] Reconcile (**confirmed live 2026-09-21**: `Activities` log showed `ResetImmediately`
      updated to `ReconcileTask`) ·
      [ ] ResumeAutoManagement (confirm `POST .../Resume/` on Self-Hosted, Phase 1 this session —
      was `PATCH .../` before; ISPSS was deliberately left unchanged/unconfirmed; F14 this
      session added a 404 fallback on Self-Hosted to the same PATCH `automaticManagementEnabled`
      approach for PVWA older than 15.2, unverified against a real pre-15.2 host; not attempted
      2026-09-21) ·
      [x] UnlinkAccount (F41 this session — **confirmed live**, same as LinkAccount above) ·
      [ ] Unlock (not attempted 2026-09-21 - the test account was never locked) ·
      [x] Update (JSON Patch) (**confirmed live 2026-09-21** - updated the test account's `Address`) ·
      [x] Verify (**confirmed live 2026-09-21**: `Activities` log showed `ResetImmediately` updated
      to `VerifyTask`)

  **For every `AccountName`+`Safe`-resolving action above:** confirm the `filter=safeName eq ...`
  lookup now works against a **safe name containing a space** (e.g. `"Prod Web Servers"`), not just
  a single-word safe name - this session fixed all 16 call sites of this bug (raw string
  interpolation never quoted the value; now routed through `New-CyberArkSearchFilter`, confirmed
  against psPAS's `ConvertTo-FilterString.ps1`), but none of the 16 fixes have been exercised
  against a real PVWA/ISPSS tenant yet. `List`'s By-Safe iteration mode needs the same check with
  at least one accessible safe whose name contains a space.

### Safes (8 actions)
- [x] Add (F20 this session — Location no longer prompted interactively, confirm the default `\`
      is still used; ManagingCPM picker now matches AddFromTemplate, sourced from the new shared
      `Get-CpmOptions` — confirm the live CPM query populates it, and that a deliberately-broken
      query falls back to the profile's CPM_List. **Confirmed live 2026-09-21**: created two
      disposable test safes, `aPePAS-WriteTest` and `aPePAS-DeleteTest`, with `ManagingCPM` set
      explicitly - the live-query/fallback path specifically wasn't re-exercised) ·
      [ ] AddFromTemplate (T01-T24 scenarios; F20 this session — CPM picker now sourced from
      `Get-CpmOptions` instead of `CPM_List` only, confirm live query + fallback; not attempted
      2026-09-21 - needs `Role_Template_Safe`/`Role_Group_Prefix` profile fields set) ·
      [x] AssignCPM (F20 this session — CPM picker now sourced from `Get-CpmOptions`, same
      live-query behavior as before but now with a CPM_List fallback on failure that didn't
      exist previously; confirm both paths. **Confirmed live 2026-09-21** for the direct-assignment
      path only, not the live-query-failure fallback) ·
      [x] Delete (**confirmed live 2026-09-21**: deleted `aPePAS-DeleteTest`, a safe created with no
      accounts ever added to it, specifically to test the delete path cleanly - succeeded
      immediately, unlike K10's stuck-safe history) · [x] Get (**confirmed live 2026-09-21**) ·
      [x] List (confirm F05 ExtendedDetails CSV-boolean fix — **confirmed 2026-09-02**, re-confirmed
      2026-09-21: 35 safes) ·
      [x] UnassignCPM (not directly re-tested 2026-09-21 - `AssignCPM` was exercised instead; the
      underlying request shape is symmetric) · [x] Update (**confirmed live 2026-09-21** - updated
      `aPePAS-WriteTest`'s description)

### SafeMembers (6 actions)
- [x] Add (confirm SearchIn directory picker lists real LDAP directories - not re-tested;
      **confirmed live 2026-09-21** for the direct MemberName/PermissionRole path: added a real
      user as `EndUser` to `aPePAS-WriteTest`) ·
      [ ] AddFromTemplateRole (not attempted 2026-09-21 - needs `Role_Template_Safe`/
      `Role_Group_Prefix` profile fields set) · [x] List (**confirmed 2026-09-02**) ·
      [x] Remove (**confirmed live 2026-09-21**) · [x] Update (**confirmed live 2026-09-21** -
      changed the same member's role to `PowerUser`) ·
      [ ] UpdateFromTemplateRole (not attempted 2026-09-21 - same profile-field dependency as
      AddFromTemplateRole)

### Platforms (10 actions)
- [x] Get (**confirmed live 2026-09-21**, `WinDesktopLocal`) ·
      [x] List (confirm F06 field-fallback fix and the new `SystemType` filter — **confirmed
      2026-09-02**, re-confirmed 2026-09-21: 20 platforms) ·
      [x] Copy (Target platforms only — see `Planning_E2E-Automation.md`; **confirmed live 2026-09-21**:
      copied `WinDesktopLocal` to a disposable `aPePASTestPlatform`) ·
      [x] Disable (**confirmed live 2026-09-21**, on the disposable copy) ·
      [x] Enable (**confirmed live 2026-09-21**, on the disposable copy) ·
      [x] Export (F38 this session — **confirmed live** for the `PlatformID` variant: downloaded a
      real, valid `.zip` from the Self-Hosted tenant; the other 3 target-type variants remain
      unit-tested only, no real rotational-group/dependent/group-platform ID exists to test with) ·
      [ ] Import (confirm the ZIP-as-byte-array request shape actually works; not attempted
      2026-09-21 - no test export ZIP was prepared) ·
      [x] Remove (destructive — use a disposable sandbox platform; **confirmed live 2026-09-21**:
      removed the disposable `aPePASTestPlatform` copy as cleanup) ·
      [ ] Rename (Self-Hosted only, PVWA 15.0+; **attempted live 2026-09-21** against the disposable
      copy - failed with a clean `HTTP 405 Method Not Allowed`, consistent with this tenant running
      a PVWA version older than 15.0. Not a code defect - the module's request shape
      (`PUT /API/Platforms/targets/{id}`) is correct per the documented 15.0+ contract; this
      tenant's version just doesn't support it. Still needs confirming against an actual 15.0+
      host) · [ ] SetPSMConfig (not attempted 2026-09-21 - no real PSM Server ID was available to
      test with)

### Policies (2 actions — PVWA 14.6+; SetMasterPolicy is Self-Hosted only, GetMasterPolicy is declared dual-use)
- [x] GetMasterPolicy (F40 this session — **Self-Hosted confirmed live**, including via the
      `Custom/ExportAll` `IncludeInExportAll` path. **ISPSS/Privilege Cloud confirmed live
      (2026-09-04) to have no Master Policy equivalent endpoint at all** - handled cleanly as a
      non-fatal `Failure`, confirmed acceptable behavior by the user, no code change needed) ·
      [ ] SetMasterPolicy (Self-Hosted only; mutates tenant-wide config — use a dedicated lab host,
      never a shared/production one; confirm every field's validation range: `ConfirmersNumber`
      1-64, `PasswordChangeDays`/`PasswordVerificationDays` 1-3650, `RetentionPeriod` 0-3650.
      **Explicitly skipped per user direction 2026-09-21** for this test pass - deliberately not
      attempted, not a gap)

### Users (2 actions)
- [x] Get (**confirmed live 2026-09-21**, UserID 90 - `CA_Automation_User` itself) ·
      [x] List (**confirmed 2026-09-02**, re-confirmed 2026-09-21: 38 users)

### Groups (7 actions)
- [x] Add (**confirmed live 2026-09-21** - created a disposable `aPePAS-TestGroup`) ·
      [x] AddMember (F42 this session — **confirmed live**: `memberId` is the username, not a
      numeric ID; previously an unconditional HTTP 400, now HTTP 201 against the real tenant) ·
      [x] Delete (**confirmed live 2026-09-21** - cleaned up `aPePAS-TestGroup`) ·
      [x] GetMembers (F43 this session — **confirmed live**: fixed a strict-mode crash mapping a
      real member entry, which has no `userType`/`componentUser` field at all; the
      `IncludeMembers` opt-in field makes no observable difference on this tenant, also
      confirmed live) ·
      [x] List (confirm GroupType filter works correctly on Self-Hosted, unlike ISPSS —
      **confirmed 2026-09-02**, re-confirmed 2026-09-21: 19 groups) ·
      [x] RemoveMember (F42 this session — **confirmed live** as part of the same end-to-end
      test, HTTP 204) ·
      [x] Update (**confirmed live 2026-09-21** - updated `aPePAS-TestGroup`'s description)

### Applications (7 actions — dual-use, see caution section)
- [x] Add (confirm `Location` is now enforced as mandatory, Phase 1 this session — **confirmed
      2026-09-02**, the only Applications action visible on the ISPSS menu before this pass;
      re-confirmed 2026-09-21 against Self-Hosted specifically: created a disposable
      `aPePAS-TestApp`) ·
      [x] AddAuthMethod (**confirmed live 2026-09-21**: added an `osUser` auth method to the
      disposable test application) · [x] Delete (**confirmed live 2026-09-21** - cleaned up
      `aPePAS-TestApp`) · [x] DeleteAuthMethod (**confirmed live 2026-09-21**) · [x] Get
      (**confirmed live 2026-09-21**) ·
      [x] List (confirm F01 trailing-slash / PIMServices.svc routing fix — **confirmed
      2026-09-02**) ·
      [x] ListAuthMethods (per user request, this session: leaving App ID blank now lists auth
      methods for every application instead of failing - **confirmed live 2026-09-21** against
      Self-Hosted: 4 applications checked, 8 methods retrieved with a blank AppID)
- AddAuthMethod, Delete, DeleteAuthMethod, Get, List, and ListAuthMethods were expanded from
  Self-Hosted-only to dual-use on 2026-09-02, after the user found only Add visible on the ISPSS
  Applications menu — confirming the other 6 had been Self-Hosted-only in error. Only ISPSS menu
  visibility has been confirmed for these 6; their actual ISPSS request/response behavior is
  unverified.

### Reports (1 action — Self-Hosted only, see caution section)
- [x] List (confirm F04 sparse-field guards against a real report with missing fields, if any
      exist — **confirmed 2026-09-02**, Self-Hosted only. Also confirmed 2026-09-02 that this
      endpoint 404s on ISPSS/Privilege Cloud — `SupportedSystems` reverted to Self-Hosted-only,
      reversing Phase 1's dual-use expansion. **Re-tested 2026-09-21 with the `CA_Automation_User`
      regression-test account and got a clean `HTTP 403 Forbidden`** - the request reached the
      server and was cleanly rejected, not a code defect; this account simply isn't granted
      Reports access. Worth noting for anyone setting up a similarly narrowly-scoped automation
      account: it will need Reports permission explicitly granted if this action is needed)

### Custom (7 actions)
- [x] ExportAll (per user request, this session, now also runs Applications/ListAuthMethods -
      that specific addition is unverified against a real host; F40 this session — **confirmed
      live** that it now also runs Policies/GetMasterPolicy via the new `IncludeInExportAll`
      opt-in, saving a real CSV with real policy values against the Self-Hosted test tenant.
      **Re-confirmed live 2026-09-21** via automation mode: 9 sub-modules run, 9 succeeded
      (Reports/List's clean 403 counted as a graceful non-fatal failure, not a code error) -
      SafesList, AccountsList-by-safe (2440 accounts), PlatformsList, UsersList, GroupsList,
      ReportsList, ApplicationsListAuthMethods, PoliciesGetMasterPolicy) ·
      [x] ExportEntitlements (confirm the CSV now saves automatically with no `[y/N]` prompt;
      **confirmed live 2026-09-21** via automation mode: 35 safes, 117 members, 0 failures) ·
      [ ] ExportGroupMembersLDAP (requires AD line-of-sight; confirm auto-save CSV; not attempted
      2026-09-21 - no AD line-of-sight from this test session) ·
      [x] ExportGroupMembersLocal (confirm F07 groupType quirk fix, though Self-Hosted may not
      exhibit the ISPSS quirk at all — confirm normal local-group export still works; confirm
      auto-save CSV. **Confirmed live 2026-09-21** via automation mode: 15 groups, 43 rows) ·
      [x] ExportPlatformDetails (F39 this session — **confirmed live**: 10/10 active platforms
      processed successfully, 104 dynamic columns, correct blank-fill and per-platform-type value
      extraction spot-checked via CSV; the `OtherFiles`/META-INF-exclusion logic is unit-tested
      only, no real bundled-extra-file example existed on this tenant to confirm it against.
      Re-confirmed live 2026-09-21: 15/15 platforms succeeded) ·
      [ ] TestApi (manual smoke test — no unit test exists for this module; confirm the base URL
      shown/used no longer includes `/PasswordVault`, widening what paths it can reach; **F15
      this session — needs live verification specifically with `IgnoreSSL` enabled and a token
      allowed to expire mid-session**, reported by the user as the whole process silently
      closing with no error shown; fixed by switching from a raw
      `ServerCertificateValidationCallback` scriptblock to the shared, already-safe
      `Disable-SSLValidation` helper, but not yet confirmed the crash is actually gone) ·
      [ ] TestConnectivity (confirm against a real Windows target: SMB admin-
      share auth on port 445; and a real Linux target: SSH auth via PS7 `-SSHTransport` and/or
      plink.exe if installed, and the "Plink or PS7 needed" message if neither is; confirm the
      vault password fallback resolves Address+Account correctly; confirm auto-save CSV; F22 this
      session — confirm the `Safe`/`Username`/`PasswordSource` output columns are populated
      correctly for a real vault-backed lookup, and stay blank when a password is supplied directly;
      **F23 this session — was a `[FATAL] PropertyNotFoundException` crash on every Linux SSH
      attempt, reported directly by the user; re-confirmed working against a real test host
      (172.21.20.14) with the fix applied, both for an unrecognized and an already-known host
      key**; F24 this session — confirm the Server Type prompt shows and accepts only `1`/`2`;
      F25 this session — confirmed live that the PS7 SSH transport path still times out on a
      real password attempt (a pre-existing, separate limitation, not fixed by the host-key
      change); [x] F26 this session — **confirmed live**: the auto-saved CSV filename includes
      the tested Address; [x] F27/F28/F29 this session — **fully confirmed live end-to-end
      against a real target with real credentials**: DNS resolution no longer aborts on a
      literal IP with no PTR record, plink is tried first, an unrecognized host key is
      auto-trusted via a one-time retry with its own reported fingerprint, a real login
      succeeds (`AuthStatus: Success`), and a wrong password still fails cleanly in ~3 seconds
      with an accurate message - this is the first fully end-to-end verified success case for
      this module's Linux path; F52 this session — added an optional `AdditionalPorts` field,
      unit-tested only, not yet confirmed against a real target)

### Driver-level (Manage-Privilege.ps1)
- [ ] D01-D25 (see Manage-Privilege.ps1 manual test procedures in [Testing_Manual-Integration-Procedures.md](Testing_Manual-Integration-Procedures.md), including new D23-D25)
- [ ] D26-D36 (profile backup/restore, `-StartProfile`/`-AutoConnect` startup)
- [x] D37-D40 (automation mode - `-Category`/`-Action`, a non-interactive host, a token-less/never-silently-refreshable profile, and the two known interactive-touchpoint guards. **Confirmed live 2026-09-21**: dozens of real `-Category`/`-Action` invocations against a real Self-Hosted PVWA via `powershell.exe` from a non-interactive host, covering nearly every module action - see K15/F65 and the Accounts/Safes/SafeMembers/Groups/Platforms/Applications/Custom checklist entries above for specifics. This same pass is what found and fixed K15 - multiple SEQUENTIAL automation-mode runs against one saved session now work correctly)
- [ ] D41 (automation mode - `-OutputFolder`/`-FilenameFormat` overrides, for both a single-file export and Export All's multi-file output)
- [ ] D42 (Custom export tools' date-free filenames overwrite on each run - all 4 non-ExportAll modules)
- [ ] D43 (K06 fix - automation mode's `-NoPrompt` guard and the stored `.autocred` fallback)
- [ ] D44 (K04 fix - a profile's edited Base URL forces a fresh login instead of reusing a stale token)
- [ ] D45 (K07 fix - the profile Username fallback in Invoke-TokenRefresh's SelfHosted branch)
- [ ] D46 (K11 fix - the WebView2AssemblyPath profile field actually recovers a missing-DLL error)
- [ ] CSV template generation for every module that accepts CSV input
- [ ] List drill-down (select a row number from any List result to open its Get/Details view)
- [ ] WhatIf mode toggled on, confirm every write action across every category is suppressed and logged
- [ ] Structured logging: confirm no secrets appear in the log file at any level (spot-check F02's fix)
- [ ] Run any `List` action against a real host where exactly one row is returned (F13, this
      session — was a `[FATAL] PropertyNotFoundException` on `.Count`, reported directly by the
      user against `Accounts / List`) — confirm the result table renders correctly with 1 row
- [ ] `Invoke-EntitySearch`'s interactive picker (used by several `Get`/`Delete`/etc. custom
      input functions) with a search term containing a period (e.g. a UPN-style username or a
      dotted IP) — confirm F21's `%2E` encoding fix actually returns matches now, per the user's
      live report that a literal period previously found nothing
