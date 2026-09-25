# Automation Credential Sources — Design

Tracks the design for resolving an automation-mode credential from one of several pluggable
sources and handing it to `Manage-Privilege.ps1` (via the existing `.autocred` store), so a
scheduled task doesn't need a credential typed in by hand or committed to disk in plaintext.

**Status:** Implemented — via a separate sibling project, `aPeSecrets`
**Initiated:** 2026-09-21
**Origin:** user request ("I want to create a helper script for providing a credential to this
script during automation. I would like to support multiple sources for retrieving the
credential.") and the follow-up direction to extract the existing credential-store functions
first, research `Microsoft.PowerShell.SecretManagement`'s PS 5.1 compatibility, and produce this
design document before writing the multi-source helper itself.

**2026-09-21 pivot:** the original plan (Sections 5-6 below, kept for their reasoning) proposed
building a new dispatcher inside aPePAS itself, with CP/CCP/Conjur blocked on missing local
reference material. Before implementing, the user asked to move this capability to its own
dedicated project instead (**aPeSecrets**, at `..\aPeSecrets`), reusable by anything, not just
aPePAS. While scoping that out, a sibling project (**aPeDiscovery**) turned out to already have a
working, partly live-verified credential resolver (`CurrentUser`/`PSCredential`/`CP`/`CCP`/
`Conjur`) — CP itself live-verified end-to-end against a real Credential Provider on 2026-09-17.
That resolver was extracted into aPeSecrets as the one canonical implementation (aPeDiscovery now
depends on aPeSecrets too, rather than each project carrying its own copy), `WindowsCredentialManager`
was added and live-verified there as the 5th source, and aPePAS got a thin wrapper script,
`Sync-AutomationCredential.ps1`, instead of the dispatcher module Section 5 originally proposed.
See Section 9 for what actually shipped.

---

## 1. Why this is worth doing

Testing_Plan.md's K06 finding (resolved, see Finding F56) established that automation mode is only
viable for a profile that already has a valid, refreshable saved session token, and that the
*fallback* mechanism for silently refreshing that session — when the token's own `_RefreshContext`
has no usable credential — is a per-profile `.autocred` file: a `PSCredential` DPAPI-encrypted via
`Export-Clixml`, set once through the driver's interactive `[A]` profile-detail menu action.

That one-time interactive setup step is fine for a single machine a person can log into, but it
doesn't fit every deployment:
- A credential rotation policy means the `.autocred` file's password goes stale and someone has to
  interactively re-set it, defeating the point of unattended automation.
- Some environments already have an authoritative secret store (CyberArk itself, via CP/CCP/Conjur,
  or Windows Credential Manager) that should be the source of truth, not a second DPAPI file that
  can drift out of sync with it.
- A deployment/provisioning pipeline may want to seed a brand-new machine's `.autocred` file
  non-interactively, from whatever secret store that pipeline already has access to.

The goal is a small, standalone helper that can pull a credential from any of several sources and
write it into the same `.autocred` store `Manage-Privilege.ps1` already reads — without changing
`Manage-Privilege.ps1`'s own automation-mode contract at all.

---

## 2. Goals / Non-Goals

**Goals:**
- Support exactly 5 credential sources, each pluggable independently: DPAPI (already built),
  Windows Credential Manager, CyberArk CP (Credential Provider), CyberArk CCP (Central Credential
  Provider), CyberArk Conjur.
- A single, small dispatch function (`Get-AutomationCredential -Source <name> ...`) that returns a
  `PSCredential` or `$null` — every source implementation behind it looks the same to the caller.
- Integrate with the *existing* `.autocred` mechanism (`Save-ProfileCredential` in
  `Modules\CyberArkCredentialStore.psm1`, extracted this session — see Finding F61) rather than
  inventing a second, parallel credential-injection path into `Manage-Privilege.ps1`.
- Stay on Windows PowerShell 5.1, matching this project's one hard platform constraint (see Known
  Issue K01 and the `pwsh`/`ICertificatePolicy` limitation already documented in Testing Boundaries).
- No new *required* external module dependency for the common case (DPAPI and Windows Credential
  Manager should work with nothing beyond what ships in Windows PowerShell 5.1 itself).

**Non-Goals (this phase):**
- Not implementing anything yet — this document is the design only.
- Not changing `Manage-Privilege.ps1`'s automation-mode contract, exit codes, or the
  `Use-StoredCredentialIfMissing` logic — the helper is additive, feeding the same `.autocred` file
  that mechanism already reads.
- Not attempting to make CyberArk CP/CCP/Conjur retrieval solve the "cold start" problem (a profile
  with no saved token at all) — per the existing automation-mode design, a profile still needs at
  least one interactive login to obtain its first session token; this helper only addresses *how
  the fallback refresh credential is supplied*, not fresh/cold authentication.

---

## 3. Existing foundation: the DPAPI local store (already built)

`Modules\CyberArkCredentialStore.psm1` (added this session, Finding F61) already provides:

| Function | Purpose |
|---|---|
| `Get-ProfileCredentialPath -Name -ProfileDir` | Path of the `<Name>.autocred` file |
| `Save-ProfileCredential -Name -Credential -ProfileDir` | Stores a `PSCredential`, DPAPI-encrypted via `Export-Clixml` |
| `Get-ProfileCredential -Name -ProfileDir` | Returns the stored `PSCredential`, or `$null` |
| `Remove-ProfileCredential -Name -ProfileDir` | Deletes the stored credential |

This is DPAPI's own user+machine-locked encryption — no portability across machines or Windows
accounts, by design (see Design_Architecture.md's Security Considerations). It was extracted from
`Manage-Privilege.ps1` specifically so a standalone script (this helper) can call it directly
without loading the whole interactive driver.

**This is source #1, "DPAPI," in the design below** — in practice, only a *thin* source in the new
helper's own terms, since the store already exists; the helper's DPAPI "source" really means
"prompt once (or accept credential parts on the command line) and write straight to `.autocred`,"
which is already fully supported by the existing functions.

---

## 4. Should this be built on `Microsoft.PowerShell.SecretManagement`?

Before designing a custom multi-source dispatcher, it's worth asking whether Microsoft's own
pluggable-secrets framework should be adopted instead. Researched directly (module manifests,
Microsoft Learn docs, GitHub issues/changelog — not assumed) rather than guessed, since the user
was explicitly unsure ("It might be PS7 only").

**`Microsoft.PowerShell.SecretManagement` (final release: 1.1.2):**
- Its manifest declares `PowerShellVersion = '5.1'` but `CompatiblePSEditions = @('Core')` — the
  edition tag is mostly metadata (only actively enforced by PS6+ loading modules from the Windows
  PowerShell system module path) and doesn't itself block `Import-Module` under Windows PowerShell
  5.1.
- However, real Desktop-edition (5.1) problems are documented, not hypothetical: a GitHub issue
  (PowerShell/Modules#80) reports a `netstandard, Version=2.0.0.0` load failure on Windows Server
  2016/PS 5.1; the module's own CHANGELOG lists multiple 5.1-specific fixes across releases,
  including one in the *final* 1.1.2 release itself ("Fix for type initialization error on
  WindowsPowerShell, Issue #89"); and an apparently-unresolved issue (#141) reports a
  `MissingMethodException` calling `Get-SecretVault` on PS 5.1/.NET Framework 4.5 that doesn't
  reproduce on PS 7.1.3.
- **Verdict: "may work, not supported."** Basic plumbing likely runs on 5.1 in many environments,
  but Microsoft doesn't test or commit to that path, and real 5.1-specific failures exist in the
  issue tracker up through the final release.

**`Microsoft.PowerShell.SecretStore` (the companion local-vault extension, final release: 1.0.6):**
- Its manifest also nominally says `PowerShellVersion = '5.1'`, but Microsoft Learn's own overview
  page states it uses **".NET Core cryptographic APIs"** and describes it as working "on all
  platforms that support PowerShell 7" — a materially stronger PS7-orientation signal than the base
  SecretManagement module has. No explicit "5.1 works" or "5.1 unsupported" statement was found
  either way, but the .NET Core crypto dependency is a concrete, not just documentational, red flag
  for a .NET Framework-only host.
- First-use is also interactive by design (`Register-SecretVault` and, for SecretStore
  specifically, a documented interactive password prompt on first access) — friction for an
  unattended context, though scriptable via `Set-SecretStoreConfiguration -Authentication None` in
  principle (not verified against 5.1 specifically).

**Both modules are end-of-life.** Microsoft Learn states outright that "Secret modules are feature
complete and will no longer be actively developed... The code repository has been archived,"
supported going forward only for security/critical-bug fixes. 1.1.2/1.0.6 are the final releases.

**CyberArk vault extension:** exactly one exists — `SecretManagement.CyberArk` by a community
author (`aaearon`, GitHub), not an official Microsoft or CyberArk module. It's a thin
SecretManagement-shaped wrapper around two *other* third-party modules: `psPAS` (for the PVWA REST
path) and `CredentialRetriever` (for CP/CCP). Its own PowerShell version requirement could not be
confirmed. No Conjur-specific SecretManagement extension was found to exist at all.

**Both installs require PSGallery/internet access** (`Install-Module`/`Install-PSResource`) unless
manually vendored — a consideration for an "offline-friendly, no external dependency risk" goal.

**Recommendation: do not build on SecretManagement.** Stacking an archived, PS7-leaning framework
plus two more community wrapper modules (`psPAS`, `CredentialRetriever`) for CP/CCP support adds
more third-party surface area and version risk than this project's existing conventions accept —
`CyberArkComms.psm1`/`CyberArkLogging.psm1` are hand-rolled specifically to avoid exactly this kind
of dependency stacking. A small, purpose-built dispatcher (Section 5) covering exactly the 5 needed
sources, with zero required external modules for the common DPAPI/Windows Credential Manager paths,
fits this project's own established pattern better and removes the single biggest platform-risk
item (SecretStore's .NET Core crypto dependency) entirely.

---

## 5. Proposed dispatch design (superseded — see Section 9 for what actually shipped)

*Kept for its reasoning; the in-aPePAS module this section proposed was not built. aPeSecrets's
`Get-ResolvedCredential`/`Set-ResolvedCredential` (Section 9) replaced it, with a different
function/parameter naming scheme (`Params` hashtable rather than named per-source parameters like
`-CCPBaseURL`) since it needed to match aPeDiscovery's already-live-tested calling convention
rather than invent a new one.*

A single entry point, in a new module (name TBD at implementation time, e.g.
`Modules\CyberArkCredentialSources.psm1`) that the helper script calls:

```powershell
Get-AutomationCredential -Source <'DPAPI'|'WindowsCredentialManager'|'CyberArkCP'|'CyberArkCCP'|'Conjur'> @SourceParams
# Returns a PSCredential, or $null (with a logged reason) if retrieval fails.
```

Internally this dispatches to one function per source, each independently testable and each with
its own parameter set (no shared parameter blob that doesn't fit every source):

| Source | Function | Notes |
|---|---|---|
| DPAPI | *(none needed)* | Already `Get-ProfileCredential`/`Save-ProfileCredential` in `CyberArkCredentialStore.psm1` — the helper's "DPAPI source" is really just "prompt or accept credential parts, then call `Save-ProfileCredential` directly," not a new retrieval function |
| Windows Credential Manager | `Get-WindowsCredentialManagerCredential -Target <string>` | See 5.2 |
| CyberArk CP | `Get-CyberArkCPCredential -AppID -Safe -Object`(or `-Folder`/`-UserName`/`-Address`) | See 5.3 — **needs live verification, not confirmed against local references** |
| CyberArk CCP | `Get-CyberArkCCPCredential -CCPBaseURL -AppID -Safe -Object -ClientCertificate` | See 5.4 — **needs live verification, not confirmed against local references** |
| Conjur | `Get-ConjurCredential -ConjurURL -Account -HostID -ApiKey -VariableID` | See 5.5 — **needs live verification, not confirmed against local references** |

The helper script's own top-level flow would be: resolve a credential via `Get-AutomationCredential`
for whichever source is configured (per-profile config, not hardcoded — see 5.6), then call
`Save-ProfileCredential -Name <AuthTokenProfileName> -Credential $cred -ProfileDir $ProfileDir` to
seed/refresh the `.autocred` file. `Manage-Privilege.ps1` itself needs no changes — it already reads
that file via `Use-StoredCredentialIfMissing`.

### 5.1 DPAPI

Already fully implemented (Section 3). The helper's role for this source is just a thin wrapper:
prompt with `Get-Credential` (or accept `-Username`/a `SecureString` `-Password` on the command
line for a fully non-interactive seed step run by a provisioning pipeline) and call
`Save-ProfileCredential` directly — no new retrieval logic needed.

### 5.2 Windows Credential Manager

Windows ships two different Credential Manager surfaces:
- The classic Win32 API (`Advapi32.dll`'s `CredRead`/`CredWrite`/`CredDelete`), which is what the
  `cmdkey` CLI and the Control Panel "Credential Manager" applet both use — reachable from Windows
  PowerShell 5.1 today via P/Invoke, with no external module required.
- The `Windows.Security.Credentials.PasswordVault` WinRT API — a UWP-oriented surface, generally
  more awkward to call reliably from classic desktop PowerShell 5.1 than the Win32 API above.

**Recommendation:** target the classic Win32 `CredRead`/`CredWrite` API via inline P/Invoke (a
`Add-Type -TypeDefinition` block, the same general technique already used elsewhere in this
project for `ICertificatePolicy` in `CyberArkComms.psm1`), rather than depending on the community
`CredentialManager` PowerShell module (a reasonable reference implementation to consult, but not a
dependency this project needs to take on for a handful of P/Invoke calls) or the WinRT
`PasswordVault` surface. A credential would be stored under a named "target" (matching `cmdkey
/generic:<target>` naming) and retrieved by that same target name.

**Not yet verified**: the exact P/Invoke signatures/marshaling needed work correctly under Windows
PowerShell 5.1 specifically — flagged for direct testing at implementation time, following this
project's "confirm the actual .NET behavior directly, don't assume" convention (e.g. how Finding
F37's binary-response handling and F57/F58's WebView2 reflection work were both verified directly
rather than assumed).

### 5.3 CyberArk CP (Credential Provider)

**General CyberArk product architecture (not verified against this project's local reference
materials or a live environment — confirm against the target CP installation's own documentation
before implementing):** CP is an on-host agent that caches application credentials locally and
serves them to the local application via either a command-line tool (`CLIPasswordSDK.exe`,
historically shipped with the AAM/CP client installation) or a native SDK DLL. The nearest thing
found in this project's local `C:\Code\References\` materials is
`Cyberark PrivilegeCloud Tools\CreateCredFile-Helper\` — but that tool creates the CP/CPM/PSM
*component's own* Vault-authentication credential file (`CreateCredFile.exe ... /AppType "CPM"`
etc.), a different mechanism from CP *serving an application password* to a caller. No
`CLIPasswordSDK` documentation, installer, or example output was found locally.

Two integration shapes are possible and need to be decided once CP's actual local setup is known:
1. Shell out to `CLIPasswordSDK.exe` (if installed on the automation host) and parse its output.
2. P/Invoke the native CP SDK DLL directly, if a PowerShell-callable surface exists — not confirmed
   without vendor documentation.

**This source cannot be designed further without either (a) local `C:\Code\References\`-style
documentation for the specific CP client version in use, or (b) direct access to a CP-provisioned
host to test against.** Recommend the user supply CyberArk's own CP client documentation (or point
to where it can be added to `C:\Code\References\`) before implementation begins.

### 5.4 CyberArk CCP (Central Credential Provider / AIM Web Service)

**General CyberArk product architecture (not verified against local references or a live
environment — confirm before implementing):** CCP is CyberArk's REST-based central credential
retrieval service (`AIMWebService`), typically reached via a GET request identifying the target
account by `AppID`/`Safe`/`Object` (or `Folder`/`UserName`/`Address`/`PolicyID` as alternate
lookup keys), authenticated by the *calling application's own identity* — commonly a client
certificate, the OS user identity, or the calling executable's path/hash — rather than a
username/password the script itself would hold. This is architecturally similar to this project's
existing `Invoke-CyberArkAPI` (`Modules\CyberArkComms.psm1`) in that it's a REST call over HTTPS,
but it is a **separate CyberArk component and API surface from PVWA** — it does not reuse this
project's existing auth token flow at all.

If client-certificate authentication is the mechanism in use, this may be able to reuse
`Auth\CyberArk.Auth.Common.psm1`'s existing `Get-FilteredClientCertificate` certificate-store
picker (already built for Self-Hosted PKI/PKIPN auth) rather than writing a new one — worth
revisiting at implementation time once the actual CCP auth mode in use is confirmed.

**Not yet verified**: exact endpoint path, required/optional query parameters, and auth mode for
this environment's specific CCP deployment. Needs either vendor documentation or a live CCP
endpoint to test against before implementation.

### 5.5 CyberArk Conjur

**General CyberArk product architecture (not verified against local references or a live
environment — confirm before implementing):** Conjur is a separate secrets-management platform
(Conjur Enterprise or Conjur Cloud) with its own REST API and authentication model, distinct from
both PVWA and CCP. The typical flow is: authenticate an identity (a "host," identified by an API
key, or via JWT for a federated/machine identity) against `POST
/authn/<account>/<host-id>/authenticate` to obtain a short-lived signed token, then present that
token (`Authorization: Token token="<base64-encoded-token>"`) on a subsequent `GET
/secrets/<account>/variable/<variable-id>` call to retrieve the actual secret value. Conjur Cloud
and Conjur Enterprise (self-hosted) may differ in base URL shape and some auth details.

No local reference material exists for Conjur specifically (confirmed via search across
`C:\Code\References\`), and the research into SecretManagement extensions found no
Conjur-specific one either — this would be the newest-ground source of the 5, with the least
existing local grounding.

**Not yet verified**: exact API version/paths in use, whether this environment is Conjur Cloud or
Enterprise, and the specific host identity/auth mechanism to use for this script's calling
context. Needs vendor documentation or a live Conjur endpoint before implementation.

### 5.6 Per-profile source configuration

Rather than a single global source setting, each driver profile should be able to declare which
source (if any) its automation credential comes from and that source's own config — mirroring how
`WebView2AssemblyPath` (Finding F60) and other optional fields were added to the profile JSON
schema without breaking older saved profiles (guarded by `PSObject.Properties[...]` existence
checks throughout this codebase). Exact schema (a nested `CredentialSource` object vs. flat
prefixed fields) is an implementation-time decision, not fixed here.

---

## 6. Open questions from the original plan (mostly resolved by the pivot — see Section 9)

- Should the helper be invoked manually/ad hoc (an operator or provisioning script runs it once to
  seed `.autocred`), on a recurring schedule (its own separate scheduled task, to handle rotation),
  or both? **Resolved as "manual/ad hoc"** — `Sync-AutomationCredential.ps1` is a plain script with
  a 0/1 exit code; nothing prevents wrapping it in its own scheduled task later if rotation needs
  become automatic, but that wasn't built.
- CP and CCP both need the target CyberArk component's actual client documentation/environment
  access before their retrieval functions can be designed in more concrete detail than Sections 5.3
  and 5.4 above. **Resolved for CP** (aPeDiscovery's existing live-verified implementation, reused
  as-is) **and now for CCP too** (live-verified 2026-09-21 against a real PVWA/CCP host - see
  Section 9; also surfaced a real cross-provider-permission gotcha, documented in aPeSecrets's
  `Docs\Configuration.md`). **Still open for Conjur** — aPeSecrets's version implements the
  documented integration pattern but remains unverified against a live Conjur appliance.
- Whether Windows Credential Manager P/Invoke should be shared/reusable if any other part of this
  project ever wants it, or kept private to this one helper. **Resolved as shared** — it lives in
  aPeSecrets's `CredentialResolver.psm1`, available to any consumer of that module, not scoped to
  aPePAS.

---

## 7. Progress Tracker

| Step | Status |
|---|---|
| Extract DPAPI credential-store functions into `Modules\CyberArkCredentialStore.psm1` | Done (Finding F61) |
| Research `Microsoft.PowerShell.SecretManagement`/`SecretStore` PS 5.1 compatibility | Done (Section 4) |
| This design document | Done |
| Pivot to a separate `aPeSecrets` project (Section 9) | Done |
| `PSCredential` (DPAPI) source | Done — reused from aPeDiscovery |
| `WindowsCredentialManager` source | Done — new, live-verified (Section 9) |
| `CP` source | Done — reused from aPeDiscovery, live-verified there 2026-09-17 |
| `CCP` source | Done — **live-verified 2026-09-21** against a real PVWA/CCP host, cross-checked against `CP` retrieving the same account |
| `Conjur` source | Done (implements documented pattern) — **not yet live-verified against a real Conjur appliance** |
| aPePAS wrapper script (`Sync-AutomationCredential.ps1`) | Done — live-verified end-to-end (Section 9) |
| aPeDiscovery repointed at aPeSecrets instead of its own copy | Done |

---

## 8. Revision Log

| Date | Change |
|---|---|
| 2026-09-21 | Initial draft, per user request to design this before implementing. Covers the DPAPI foundation already built (F61), the SecretManagement PS 5.1 research findings, and the proposed dispatch design for all 5 sources with CP/CCP/Conjur explicitly flagged as needing live/vendor verification before implementation. |
| 2026-09-21 | Per user direction ("Create a new separate project calle aPeSecrets. In the current project we will have a simple wrapper to call this external project."), pivoted from Section 5's in-aPePAS dispatcher plan to a new sibling project. Discovered aPeDiscovery already had a working `CredentialResolver.psm1` (`CurrentUser`/`PSCredential`/`CP`/`CCP`/`Conjur`, CP live-verified 2026-09-17); per user choice, extracted it into aPeSecrets as the one canonical implementation and repointed aPeDiscovery at it, rather than building a second, divergent copy. Added `WindowsCredentialManager` as a new source in aPeSecrets, live-verified (real `CredRead`/`CredWrite` round-trip, cross-checked against `cmdkey /list`) — and, in the process, found and fixed a real bug: adding `Set-StrictMode -Version Latest` (this project's own habit) broke the ported CP/CCP/Conjur code's `$Params.OptionalKey` pattern, since strict mode throws `PropertyNotFoundException` for a missing hashtable key accessed via dot notation, not just a missing PSCustomObject property — removed strict mode from that module to match its original, already-proven configuration instead of rewriting proven code. Added `aPePAS\Sync-AutomationCredential.ps1`, a thin wrapper around aPeSecrets's `Get-ResolvedCredential` and this project's own `Save-ProfileCredential`, live-tested end-to-end (WindowsCredentialManager source → `.autocred` file, username/password round-trip confirmed). See Section 9. |
| 2026-09-21 | Per user-supplied live test credentials (PVWA address, client certificate thumbprint, Safe/Folder/Object, AppID), live-verified the `CCP` source against a real PVWA/CCP host. First attempt returned CyberArk's structured `APPAP004E` ("password object ... not found"); per user direction, cross-checked the identical Safe/Folder/Object/AppID against the local `CP` source instead, which succeeded - proving the account existed and was retrievable under that AppID, isolating the failure to CCP-side provider authorization specifically (confirmed once the user granted it: the identical CCP query then succeeded, matching username and password length against the CP retrieval). Updated aPeSecrets's `README.md`/`Docs\Configuration.md` and this document's Progress Tracker/Section 6/Section 9 to record `CCP` as live-verified, and documented the cross-provider-permission diagnostic for future reference. `Conjur` remains the one source not yet live-verified. |

---

## 9. What actually shipped

- **`C:\Code\aPeSecrets`** — new sibling project, own git repo (initialized, not yet committed).
  `Modules\CredentialResolver.psm1` exports `Get-ResolvedCredential -Source <name> -Params @{...}`
  and `Set-ResolvedCredential -Source <name> -Credential $cred -Params @{...}` (the latter only for
  the two locally-writable sources, `PSCredential`/`WindowsCredentialManager` — CP/CCP/Conjur are
  read-only views onto a CyberArk-managed store). `CurrentUser`/`PSCredential`/`CP`/`CCP`/`Conjur`
  were extracted from aPeDiscovery's own module (same logic, same live-tested CP behavior,
  `Params` key names unchanged); `WindowsCredentialManager` is new, via inline P/Invoke against the
  classic Win32 `CredRead`/`CredWrite`/`CredDelete` API (not the WinRT `PasswordVault` surface).
  17 Pester tests (`Tests\Unit\CredentialResolver.Tests.ps1`), all passing — `CurrentUser`/
  `PSCredential`/`WindowsCredentialManager` with real round-trips (DPAPI file, and a real Windows
  Credential Manager entry cross-checked against `cmdkey /list`), `CP`/`CCP`/`Conjur` with
  parameter-validation coverage only (exercising them for real needs a live CyberArk endpoint). See
  aPeSecrets's own `README.md`/`Docs\Configuration.md` for the full reference.
- **aPeDiscovery** repointed at aPeSecrets: its own `Modules\CredentialResolver.psm1` was deleted;
  `Export-ADGroups.ps1`/`Export-LocalGroups.ps1`/`Export-LocalLinuxGroups.ps1` and
  `Modules\LocalComputerScanner.psm1`/`Modules\LocalLinuxComputerScanner.psm1` now import
  `..\aPeSecrets\Modules\CredentialResolver.psm1` and call the renamed `Get-ResolvedCredential`
  (was `Get-DiscoveryCredential`). `README.md`/`Docs\Configuration.md`/`Docs\Scheduled-Task-Setup.md`
  updated to document the new sibling-project dependency (both projects must be deployed together
  on any host running a scheduled task). Historical design docs
  (`Docs\Design-Local-Linux-Discovery.md`) kept their original narrative (the live CP verification
  happened there, before the move) with a pointer added noting where the module lives now.
- **`aPePAS\Sync-AutomationCredential.ps1`** (new, root of this repo) — the "simple wrapper" the
  user asked for. Takes `-ProfileName`/`-Source`/`-Params`/`-ProfileDir`/`-APeSecretsPath`,
  imports aPeSecrets (sibling path by default) and this project's own
  `Modules\CyberArkCredentialStore.psm1`, resolves the credential, and calls
  `Save-ProfileCredential` to seed/refresh that profile's `.autocred` file.
  `Manage-Privilege.ps1` itself was not changed — this is purely additive, feeding the same file
  `Use-StoredCredentialIfMissing` already reads. Live-tested end-to-end: seeded a real Windows
  Credential Manager entry, ran the wrapper against a temp profile directory, confirmed the
  resulting `.autocred` file round-trips the exact username/password via
  `CyberArkCredentialStore.psm1`'s own `Get-ProfileCredential`.
- **Also live-verified 2026-09-21 (same day, follow-up)**: the `CCP` source, against a real
  PVWA/CCP host (`AppID=APP_AIHost`, client-certificate auth), cross-checked against `CP`
  retrieving the exact same account (matching username, matching password length). Along the way,
  an initial attempt returned CyberArk's structured `APPAP004E` ("password object ... not found")
  even though the account was confirmed to exist and be retrievable via `CP` for the same AppID -
  root cause was the AppID's CCP-side provider authorization being separate from (and initially
  missing relative to) its CP-side authorization on that Safe; once granted, the identical query
  succeeded. This confirms aPeSecrets's CCP request construction (query building, client-cert
  auth, response parsing) is correct - see aPeSecrets's `Docs\Configuration.md` for the full
  writeup, kept there since it's a reusable diagnostic for anyone else who hits the same error
  shape.
- **Not done in this pass**: no Pester test file for `Sync-AutomationCredential.ps1` itself (it was
  verified live instead — matching this project's own convention for interactive/standalone-script
  code, e.g. how profile backup/restore was verified via a standalone repro rather than Pester, per
  Finding F51); no per-profile `CredentialSource`/`CredentialParams` config schema on the driver
  profile JSON (Section 5.6's idea) — today `Sync-AutomationCredential.ps1` takes `-Source`/
  `-Params` on the command line each time rather than reading them from the profile itself; `Conjur`
  remains unverified against a real endpoint.
