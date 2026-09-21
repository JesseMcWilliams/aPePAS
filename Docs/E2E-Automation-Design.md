# End-to-End Automation Design

Tracks the design options and rollout plan for adding a live, credential-gated end-to-end (E2E)
automation layer on top of this project's existing mocked Pester unit tests, so that verifying a
change against a real CyberArk tenant no longer depends entirely on the manual checklist in
`Testing-Plan.md`.

**Status:** Proposed — not started
**Initiated:** 2026-09-02
**Origin:** user question ("Can full end-to-end testing be done in an automated fashion for this
project? Some user interaction for providing the credentials but all other interactions
automated?") plus a follow-up level-of-effort estimate, both from the same conversation this
document was created in.

This document is a plan and a living progress tracker, not an implementation — nothing described
here has been built yet. Update the Progress Tracker (Section 7) as work actually happens, and add
a Revision Log entry (Section 9) for any change to the plan itself.

---

## 1. Why this is worth doing

Today, live verification against a real tenant is entirely manual: `Testing-Plan.md`'s Self-Hosted
Full Functional Checklist enumerates every module action and is worked through by hand. That
checklist has grown with the project — this session alone added roughly 15 new actions (Phase 2's
Platforms lifecycle modules and the new Policies category) — and nothing currently protects
against a live-tenant regression once a change passes the mocked unit suite. The goal is to close
that gap for as much of the module surface as is safely automatable, while being honest about the
parts that genuinely need a human.

## 2. What already makes this feasible

- Every `Invoke-<Category><Action>` function is a plain function taking `-Token`, `-InputData`,
  and `-WhatIf`, with no dependency on `Manage-Privilege.ps1`'s interactive menu loop. A harness
  can call these directly, the same way the existing mocked Pester tests already do — just against
  a real tenant instead of `Mock Invoke-CyberArkAPI`.
- Most modules already accept CSV-batch-shaped input (`InputSchema`-driven), so the harness reuses
  the same input contract every module already exposes rather than inventing a new one.
- Auth is already factored into plain functions (`Get-SelfHostedAuthToken`, `Get-ISPSSAuthToken`,
  `Update-*AuthToken`) separate from the menu UI, so a harness can authenticate once at startup and
  reuse the resulting token object for every subsequent call.

## 3. What is explicitly NOT in scope for this layer

- **`Manage-Privilege.ps1`'s interactive menu/prompt UI itself** — category and action selection,
  `Read-Host` field prompts, Y/N confirmations, the CSV-save dialog. The driver has no headless
  entry point (`-StartProfile`/`-WhatIf`/`-LogLevel`/`-LogFolder` only), and scripting it by piping
  keystrokes into stdin was considered and rejected as too fragile (breaks on any menu wording
  change, gives no real assertions). This layer stays manually tested, same as today.
- **The one step that genuinely needs a person:** completing certain auth methods. See Section 4.

## 4. Auth methods — which need a human, per run

| System | Method | Needs a human every run? | Why |
|---|---|---|---|
| Self-Hosted | CyberArk (password) | No | Password can be supplied programmatically (see Section 8's open question on credential storage) |
| Self-Hosted | LDAP | No | Same as above |
| Self-Hosted | Shared | No | No per-user credential — uses the PVWA-managed application identity |
| Self-Hosted | RADIUS | Usually not, **sometimes** | Scriptable unless the RADIUS server issues a challenge (e.g. a one-time passcode), per `Testing-Plan.md` A03 |
| Self-Hosted | PKI | No, after one-time setup | Needs a client certificate already present in the machine's cert store; no per-run prompt once provisioned |
| Self-Hosted | PKIPN | **Yes** | Smart-card/token PIN entry is an interactive hardware prompt |
| Self-Hosted | SAML | **Yes** | WebView2 browser popup, real IdP login |
| Self-Hosted | OIDC | **Yes** | Same as SAML |
| ISPSS | ClientCredentials | No | OAuth `client_id`/`client_secret`, fully scriptable |
| ISPSS | Interactive | **Yes** | Username/password + MFA challenge loop |
| ISPSS | SSO | **Yes** | WebView2 browser popup |

This matches the framing the user asked for directly: credential/login entry is the one place a
human stays in the loop, and that's inherent to those specific methods, not a shortcut being taken
to simplify the harness. A harness only needs to authenticate **once** per run (not once per
module action), so even a "needs a human" method only costs one interactive step per run, however
many actions the run then exercises automatically.

## 5. Proposed architecture (design sketch — not yet built)

### 5.1 Location

A new `Tests\E2E\` folder, parallel to `Tests\Unit\`, kept **out of** `Tests\Run-Tests.ps1`'s
automatic full-suite invocation — these tests hit a real tenant and must never run as a side effect
of the existing "run the unit suite" workflow. Proposed entry point:
`Tests\E2E\Invoke-E2ETests.ps1`, invoked manually and only against a designated lab/test tenant.

### 5.2 Test-definition shape (illustrative, not final)

One definition per module action, something like:

```powershell
@{
    Category  = 'Safes'
    Action    = 'Add'
    InputData = { @{ SafeName = "E2E-Sandbox-$(Get-Random)"; Description = 'E2E automation test safe' } }
    Assert    = { param($result) $result.Successes | Should -Be 1 }
    DependsOn = @()
    Cleanup   = { param($result, $token) Invoke-SafesDelete -Token $token -InputData @{ SafeName = $result.Results[0].SafeName } }
}
```

`DependsOn` lets the runner order fixture-dependent actions correctly (e.g. a SafeMembers test
needs a Safe to already exist; an AccountsUpdate test needs an Account).

### 5.3 Fixture / sandbox strategy

- A dedicated, clearly-named sandbox area (e.g. a `E2E-Automation-Sandbox` Safe) that mutating
  tests operate inside, never real/production Safes or accounts.
- Setup should be idempotent ("create if not exists") so a prior run's incomplete cleanup doesn't
  break the next run.
- Cleanup runs in reverse dependency order after each run; a separate "force cleanup orphaned test
  data" mode is worth having for when a run is interrupted mid-way.

### 5.4 Read-only vs. mutating split

Read-only actions (`Get`/`List`/exports) need no fixtures or cleanup — call and assert on response
shape. Mutating actions need the fixture/cleanup machinery above. This split is also what drives
the phased rollout in Section 6.

## 6. Phased rollout (recommended)

1. **Phase 1 — harness scaffolding + read-only coverage.** Build the runner, auth bootstrap, and
   wire up every `Get`/`List`/export action (~23 actions). No fixtures needed. Lowest risk, fastest
   to deliver, and validates the harness design itself before investing in fixture machinery.
2. **Phase 2 — low-risk mutating coverage.** Everything that creates/updates/deletes a *scoped*
   object inside the sandbox area (Accounts, Safes, SafeMembers, Groups, Applications, most of
   Platforms). Needs the fixture/cleanup design from Section 5.3.
3. **Phase 3 — high-risk / destructive / tenant-wide actions.** See Section 7's "High-risk" rows.
   Recommend running these only against a disposable/ephemeral test tenant, never a shared lab
   tenant with other people's test data in it — and possibly leaving some of them manual by design
   permanently (see Section 8).

## 7. Progress Tracker

All 67 current module actions, grouped by category. **Automation Status** starts at "Not started"
for everything except the interactive-only Custom/TestApi tool, which is out of scope by design
(it's itself a manual testing tool, not something with a fixed expected result to assert against).
Update this table as work happens — this is the living record this document exists to provide.

**Risk key:** RO = read-only, no fixture needed · Low = mutating, scoped to a sandbox object ·
High = destructive and/or tenant-wide — Phase 3, disposable-tenant-only (see Section 8).

### Accounts (17 actions)

| Action | Risk | Automation Status | Notes |
|---|---|---|---|
| Add | Low | Not started | |
| CancelCpmTask | Low | Not started | Needs an existing sandbox account |
| ChangeImmediate | Low | Not started | Needs an existing sandbox account |
| ChangeInVault | Low | Not started | Needs an existing sandbox account |
| CheckIn | Low | Not started | Needs an existing sandbox account with an active session |
| Delete | Low | Not started | Destructive, but scoped to a sandbox account — not High risk |
| Get | RO | Not started | |
| GetActivity | RO | Not started | |
| GetCredential | RO | Not started | Retrieves a real secret value — confirm the harness never logs it |
| LinkAccount | Low | Not started | Needs two existing sandbox accounts |
| List | RO | Not started | |
| Reconcile | Low | Not started | Triggers an async CPM job — completion isn't immediate, assertion needs a poll/wait or must only assert the request was accepted |
| ResumeAutoManagement | Low | Not started | |
| UnlinkAccount | Low | Not started | |
| Unlock | Low | Not started | |
| Update | Low | Not started | |
| Verify | Low | Not started | Same async-CPM-job caveat as Reconcile |

### Safes (8 actions)

| Action | Risk | Automation Status | Notes |
|---|---|---|---|
| Add | Low | Not started | |
| AddFromTemplate | Low | Not started | Needs a template safe fixture to already exist |
| AssignCPM | Low | Not started | Needs a real CPM account name from the test tenant |
| Delete | Low | Not started | Scoped to a sandbox safe |
| Get | RO | Not started | |
| List | RO | Not started | |
| UnassignCPM | Low | Not started | |
| Update | Low | Not started | |

### SafeMembers (6 actions)

| Action | Risk | Automation Status | Notes |
|---|---|---|---|
| Add | Low | Not started | Needs a sandbox safe and a real vault user/group to add |
| AddFromTemplateRole | Low | Not started | Needs template role setup on the test tenant |
| List | RO | Not started | |
| Remove | Low | Not started | |
| Update | Low | Not started | |
| UpdateFromTemplateRole | Low | Not started | |

### Platforms (10 actions)

| Action | Risk | Automation Status | Notes |
|---|---|---|---|
| Copy | Low | Not started | Needs a source platform to duplicate — use a low-value built-in platform, not a production one |
| Disable | Low | Not started | Scoped to the copied sandbox platform, not a real one |
| Enable | Low | Not started | |
| Export | RO | Not started | `PlatformID` variant is live-confirmed manually (see Testing-Plan.md F38); the other 3 target-type variants (RotationalGroupID/DependentID/GroupPlatformID) need a real ID of that type to test against, which no existing module can currently discover |
| Get | RO | Not started | |
| Import | Low | Not started | Needs a prepared test platform `.zip` fixture checked into the repo or test assets |
| List | RO | Not started | |
| Remove | **High** | Not started | Destructive; only run against a disposable platform created earlier in the same run |
| Rename | Low | Not started | Self-Hosted only |
| SetPSMConfig | Low | Not started | Needs a real PSM server ID from the test tenant |

### Policies (2 actions)

| Action | Risk | Automation Status | Notes |
|---|---|---|---|
| GetMasterPolicy | RO | Not started | Declared dual-use, but confirmed live to have no equivalent endpoint on ISPSS/Privilege Cloud at all (see Testing-Plan.md F40) - fails gracefully there rather than crashing |
| SetMasterPolicy | **High** | Not started | Self-Hosted only. This mutates **tenant-wide** configuration, not a scoped object — never run against a shared lab tenant. Disposable-tenant-only, or leave manual by design (see Section 8) |

### Users (2 actions)

| Action | Risk | Automation Status | Notes |
|---|---|---|---|
| Get | RO | Not started | |
| List | RO | Not started | |

### Groups (7 actions)

| Action | Risk | Automation Status | Notes |
|---|---|---|---|
| Add | Low | Not started | |
| AddMember | Low | Not started | |
| Delete | Low | Not started | |
| GetMembers | RO | Not started | |
| List | RO | Not started | |
| RemoveMember | Low | Not started | |
| Update | Low | Not started | |

### Applications (7 actions)

| Action | Risk | Automation Status | Notes |
|---|---|---|---|
| Add | Low | Not started | |
| AddAuthMethod | Low | Not started | |
| Delete | Low | Not started | |
| DeleteAuthMethod | Low | Not started | |
| Get | RO | Not started | |
| List | RO | Not started | |
| ListAuthMethods | RO | Not started | |

### Reports (1 action)

| Action | Risk | Automation Status | Notes |
|---|---|---|---|
| List | RO | Not started | |

### Custom (7 actions)

| Action | Risk | Automation Status | Notes |
|---|---|---|---|
| ExportAll | RO | Not started | Composite — exercises multiple List modules internally |
| ExportEntitlements | RO | Not started | |
| ExportGroupMembersLDAP | RO | Not started | Requires AD line-of-sight from wherever the harness runs, not just the CyberArk API |
| ExportGroupMembersLocal | RO | Not started | |
| ExportPlatformDetails | RO | Not started | Downloads and unzips every active platform - live-verified manually (see Testing-Plan.md F39), not yet wired into an automated harness |
| TestApi | N/A | Out of scope by design | This is itself an ad-hoc manual testing tool with no fixed expected result — not a candidate for automated assertions |
| TestConnectivity | Low | Not started | Needs a real Windows target (for the SMB admin-share auth test) and a real Linux target with a known account (for the SSH auth test) as fixtures; the SSH path additionally depends on PS7 or plink.exe being present on the machine running the harness — see the module's own code comments on the PS7-SSH-transport password-auth limitation |

### Auth (11 methods — see Section 4 for the human/no-human breakdown)

| Method | Automation Status | Notes |
|---|---|---|
| Self-Hosted: CyberArk | Not started | |
| Self-Hosted: LDAP | Not started | |
| Self-Hosted: Shared | Not started | |
| Self-Hosted: RADIUS | Not started | May need conditional human step — see Section 4 |
| Self-Hosted: PKI | Not started | One-time cert provisioning, then scriptable |
| Self-Hosted: PKIPN | Manual by design | Hardware PIN prompt |
| Self-Hosted: SAML | Manual by design | Browser IdP login |
| Self-Hosted: OIDC | Manual by design | Browser IdP login |
| ISPSS: ClientCredentials | Not started | |
| ISPSS: Interactive | Manual by design | MFA challenge loop |
| ISPSS: SSO | Manual by design | Browser login popup |

## 8. Open decisions (need an answer before Phase 1 starts)

1. **Credential storage for scriptable auth methods.** Options: reuse the existing
   `Save-AuthToken`/DPAPI `.cred` file mechanism (human runs an interactive auth once, harness
   reuses the saved, refreshable token on later runs); or prompt once at the start of each harness
   run and hold the token in memory for that run only. The former needs less human interaction
   over time but means a stored secret on disk that outlives a single run.
2. **Shared lab tenant vs. disposable/ephemeral tenant for High-risk actions.** `Testing-Plan.md`
   already establishes "use a dedicated test Safe/test accounts, never production" for manual
   testing; this automation layer needs the same discipline, but the two High-risk actions
   (`Platforms/Remove` against something not created in the same run, and
   `Policies/SetMasterPolicy` at all) argue for a tenant nobody else's data lives in, if one is
   available — otherwise those two stay manual by design permanently, same as PKIPN/SAML/OIDC/SSO
   auth already are.
3. **Async-completion actions (`Accounts/Reconcile`, `Accounts/Verify`).** Decide whether the
   harness polls for the CPM job's actual completion (more realistic, slower, needs a
   timeout/retry policy) or only asserts the request was accepted (faster, less coverage).

## 9. Revision Log

| Date | Change |
|---|---|
| 2026-09-02 | Initial version — captures the design discussion, level-of-effort estimate, and per-action progress tracker for the E2E automation layer |
| 2026-09-02 | Added `Custom/TestConnectivity` (new this session) to the Progress Tracker; total module count updated from 64 to 65 |
| 2026-09-04 | Added `Custom/ExportPlatformDetails` to the Progress Tracker (Custom: 6 -> 7 actions) |
| 2026-09-04 | Fixed staleness this update pass had missed earlier: added the `Platforms/Export` row (9 -> 10 actions), corrected `Policies/GetMasterPolicy`'s note (now dual-use, confirmed absent on ISPSS rather than "Self-Hosted only"), and corrected the Section 7 intro's total module count (65 -> 67) |