# Add Safe From Template Design

Tracks the design decisions and implementation plan for a new `Safes/AddFromTemplate`
module that creates a safe by copying settings and non-role group members from an
existing "template" safe named in the active profile.

**Status:** Implemented
**Initiated:** 2026-08-20
**Completed:** 2026-08-20

---

## 1. Motivation

Today, creating a safe that follows a standard pattern (retention settings, CPM, and a
consistent set of non-role group memberships) requires running `Safes/Add` and then a
separate `SafeMembers/Add` for every group by hand. There is no way to say "make this
safe look like our standard template safe."

Two profile fields already exist for exactly this purpose but are currently unconsumed
by any module (confirmed by grep across `APIModules\`):

| Field | Declared in | Current consumers |
|---|---|---|
| `Role_Template_Safe` | `Manage-Privilege.ps1` (`New-BlankProfile`, profile normalization, `Show-ProfileDetail`, `Invoke-ProfileEditFlow`); documented in `Claude_Docs\Reference_Interfaces.md:399` | None |
| `Role_Group_Prefix` | Same touchpoints; documented in `Claude_Docs\Reference_Interfaces.md:400` | None |

`Claude_Docs\Reference_Interfaces.md` describes both fields as "Consumed by Add/Update Safe Member
role-assignment operations" — this feature is the first real consumer. Note:
`README.md`'s Configuration table describes them differently ("exporting role-based
entitlement templates" / "prefix filter for role-based group exports") — that wording
does not match any existing code path and should be corrected to match this feature
once implemented (see Section 6).

Problems this design solves:
- No repeatable way to stamp out safes that match an organizational standard.
- Manual `SafeMembers/Add` runs per group are error-prone and easy to miss one.
- `Role_Template_Safe` / `Role_Group_Prefix` are dead profile fields with conflicting docs.

---

## 2. Proposed Module Structure

```
APIModules\Safes\
  Invoke-SafesAddFromTemplate.ps1   # New — Category=Safes, Action=AddFromTemplate
```

One new file, following the exact convention of the other four `Safes\*.ps1` modules
(`$ModuleMeta` → `Get-SafesAddFromTemplateInput` → `Invoke-SafesAddFromTemplate`). Menu
registration needs no Manage-Privilege.ps1 changes — `Import-APIModules` already does that
automatically (dynamic dot-source + menu registration by `Category`, same as every other
module). Manage-Privilege.ps1 does gain one addition: a `$script:ExcludedTemplateMemberNames`
constant (see Decision D7), the same way other driver-wide constants like
`$script:PVWA_SESSION_EXPIRY_MIN` are declared and made visible to every dot-sourced
module without an explicit import.

The module reuses the same two REST endpoints already used elsewhere in the codebase —
it does not call `Invoke-SafesAdd` or `Invoke-SafeMembersAdd` as functions (those modules
don't export anything for others to call; they are self-contained `Invoke-<Category><Action>`
entry points), it builds equivalent request bodies directly, consistent with how
`Get-PermissionSet` is already duplicated between `Invoke-SafeMembersAdd.ps1` and
`Invoke-SafeMembersUpdate.ps1` rather than shared.

---

## 3. Public API Surface

### `$ModuleMeta`

```powershell
$ModuleMeta = @{
    Name             = 'Add Safe From Template'
    Category         = 'Safes'
    Action           = 'AddFromTemplate'
    Description      = 'Create a new safe by copying settings and non-role group members from the profile''s template safe.'
    SupportedSystems = @('ISPSS', 'SelfHosted')   # both /API/Safes and /API/Safes/{safe}/Members exist on both systems
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    InputSchema      = @(
        @{ Column = 'SafeName';     Required = $true;  Description = 'Unique name for the new safe (max 28 chars).' }
        @{ Column = 'Description';  Required = $false; Description = 'Description for the new safe. Never copied from the template — leave blank for no description.' }
        @{ Column = 'ManagingCPM';  Required = $false; Description = 'CPM username to assign. Blank = none (default). No longer copied from the template (D8).' }
        @{ Column = 'ExtraMembers'; Required = $false; Description = 'Type:Name:RoleName triples, semicolon-separated (D9).' }
    )
    Priority         = 15   # after Add(12)/Get(11)/Update(13)/Delete(14) in the existing Safes priority sequence
    Version          = '1.4.1'   # 1.1.0 dropped OLACEnabled and made retention fields mutually exclusive (D5/D6)
                              # 1.2.0 added the $script:ExcludedTemplateMemberNames filter (D7)
                              # 1.3.0 added the CPM prompt (D8) and additional-members feature (D9/D10)
                              # 1.3.1 added Example values to InputSchema, used by the CSV template generator
                              # 1.3.2 fixed the [FATAL] array-collapse crash - see
                              # Reference_Lessons-Learned.md sections 9.8-9.9
                              # 1.4.0 collapsed the additional-members loop to one recurring
                              # prompt (D11) and added role descriptions from Groups/List (D12)
                              # 1.4.1 moved the role description to its own indented line(s),
                              # splitting embedded CR/LF (D12a)
}
```

`SafeName`, `Description`, `ManagingCPM`, and `ExtraMembers` are collected from the caller —
`Description` is always fresh (per D1 below); `ManagingCPM` and `ExtraMembers` are new as of
D8/D9 and are *not* copied or derived from the template. Every other safe property still
comes from reading the template safe named in the profile's `Role_Template_Safe` field.

### Algorithm

1. Resolve the template safe name from the session profile's `Role_Template_Safe` field
   and the role-group prefix from `Role_Group_Prefix`. Both are **required** — if either
   is blank, fail fast with a clear, non-fatal validation error (`IsFatal = $false`), same
   pattern as the existing `SafeName is required` guard in `Invoke-SafesAdd.ps1`. (D4)
2. `GET /API/Safes/{urlencoded Role_Template_Safe}` (same call as `Invoke-SafesGet.ps1`)
   to read the template's settings: `location`, `managingCPM`, `numberOfVersionsRetention`,
   `numberOfDaysRetention`, `autoPurgeEnabled`. The template's `description` and
   `olacEnabled` are never read or used (D1 — description is always fresh from input;
   `OLACEnabled` is not a supported field for this module and must never be sent — see D5).
   - 404 here means the configured template safe doesn't exist — treat as a validation
     failure for this run (`IsFatal = $false`), not a fatal session error.
3. `GET /API/Safes/{urlencoded Role_Template_Safe}/Members` (same call as
   `Invoke-SafeMembersList.ps1`) to read the template's member list. Each member has
   `memberName`, `memberType`, `membershipExpirationDate`, and a `permissions` object with
   the same 22 camelCase booleans used by `Invoke-SafeMembersAdd.ps1`.
4. Filter the member list: exclude any member — regardless of `memberType` (User, Group,
   or Role) — whose `memberName` starts with `Role_Group_Prefix` (case-insensitive) (D2),
   **and** exclude any member whose `memberName` exactly matches (case-insensitive) an
   entry in the global `$script:ExcludedTemplateMemberNames` list defined in `Manage-Privilege.ps1`
   (D7). Every remaining member, of any type, is copied.
4a. Parse `InputData.ExtraMembers` ("Type:Name:RoleName;Type:Name:RoleName...") into
   validated specs. `Type` must be `User` or `Group`; malformed entries (wrong shape,
   invalid `Type`, empty `Name`/`RoleName`) are recorded as individual non-fatal errors
   and skipped — they never block safe creation or the other entries (D9).
5. `POST /API/Safes` to create the new safe, body built the same way as
   `Invoke-SafesAdd.ps1`, with `SafeName` and `Description` from input (empty string if not
   supplied — `Description` is never taken from the template), `Location` and
   `AutoPurgeEnabled` copied from the template safe read in step 2, and `ManagingCPM` taken
   from `InputData.ManagingCPM` — blank (no CPM) if not supplied, **never** copied from the
   template (D1, amended by D8). `NumberOfVersionsRetention` and `NumberOfDaysRetention` are
   mutually exclusive on this API — only one is ever included in the body: the template's
   `NumberOfDaysRetention` is sent when it is greater than 0, otherwise the template's
   `NumberOfVersionsRetention` is sent. `OLACEnabled` is never included (D5).
   - If this fails, stop — do not attempt any member copy. Report as one failed item, same
     `IsFatal` rule as `Invoke-SafesAdd.ps1` (`StatusCode -in @(401, 0)`).
6. For each retained member from step 4, `POST /API/Safes/{urlencoded new SafeName}/Members`
   with the same `memberName`, `memberType` (when present), and `permissions` object taken
   verbatim from the template member, but `membershipExpirationDate` always set to `$null`
   — expiration is never copied from the template (D3). Same body shape as
   `Invoke-SafeMembersAdd.ps1:366-373`. Each member copy is one item in the result: a
   failure on one member does not stop the loop (consistent with how every other
   multi-item module in this codebase accumulates `Successes`/`Failures` per item and only
   sets `IsFatal` on 401/0).
6a. For each spec from step 4a, resolve its `RoleName` against `$templateMembers` (already
   fetched in step 3 - no second API call) filtered to members whose name starts with
   `Role_Group_Prefix`, exact case-insensitive match on the full name (same resolution as
   `SafeMembers/AddFromTemplateRole`). If no match, record a non-fatal error and skip that
   member. Otherwise `POST /API/Safes/{urlencoded new SafeName}/Members` with `memberName`/
   `memberType` from the spec, `permissions` copied verbatim from the resolved role member,
   and `membershipExpirationDate = $null` (D10). Same continue-on-error/fatal-on-401
   semantics as step 6.
7. Result: `ItemsProcessed` = 1 (safe creation) + N (template members attempted) + M (extra
   members attempted); `Results` contains one row for the created safe and one row per
   member (template-copied or extra - indistinguishable by `ItemType`, but extra members
   carry their `RoleName` in a column that's blank for everything else), mirroring the shape
   `Invoke-SafesAdd`/`Invoke-SafeMembersAdd` already use for their own `Results` rows.

`WhatIf` mode reports what would be created (the safe, and the filtered member list) without
calling `POST`, following the same synthetic-success pattern as `Invoke-SafesAdd.ps1`'s WhatIf branch.

---

## 4. Profile Field Consumption

`Role_Template_Safe` and `Role_Group_Prefix` already existed end-to-end in
`Manage-Privilege.ps1` (creation, normalization for older saved profiles, display, and
interactive edit) and were already documented in `Claude_Docs\Reference_Interfaces.md`. This feature was
their first real consumer.

As of D8, a new profile field `CPM_List` (comma-separated CPM usernames) was added with the
same four touchpoints (`New-BlankProfile`, the `Get-AllDriverProfiles` normalization array,
`Show-ProfileDetail`, `Invoke-ProfileEditFlow`) and documented in `Claude_Docs\Reference_Interfaces.md`. This
feature is its first consumer.

Follow-up doc correction once implemented: `README.md`'s Configuration table currently
describes these two fields in terms of a "Custom export" / "role-based entitlement" use case
that doesn't exist in code. That description should be replaced with wording matching this
feature (see Section 7, step 9).

---

## 5. Decisions (resolved 2026-08-20)

| # | Question | Options | Decision |
|---|---|---|---|
| D1 | **Which template safe properties get copied?** | (a) All of `location`, `managingCPM`, `numberOfVersionsRetention`, `numberOfDaysRetention`, `autoPurgeEnabled`, `olacEnabled`, plus `description` unless the caller supplies one — (b) same but never copy `description` (always fresh, blank unless supplied) — (c) let the caller override any field via `InputSchema`, defaulting to the template's value | **(b)**, later amended by D5/D6 — `description` is always fresh input, never copied. `SafeName` is always new. `olacEnabled` was dropped entirely (D5) and the two retention fields were made mutually exclusive on the wire (D6) after initial implementation. |
| D2 | **What exactly counts as a "role group" to exclude?** | (a) `memberType -eq 'Group'` AND `memberName` starts with `Role_Group_Prefix` — everything else copied — (b) same prefix rule but applied to every member type (User/Group/Role) — (c) exclude any member (any type) whose name starts with the prefix, identical in effect to (b) | **(b)/(c)** — filter by `Role_Group_Prefix` against `memberName` across all member types; type is not a factor. Only the name-prefix match excludes a member. |
| D3 | **Copy `membershipExpirationDate` on copied members?** | (a) No — always create new memberships with no expiration — (b) Yes — copy verbatim | **(a)** — copied members always get `membershipExpirationDate = $null` on the new safe. |
| D4 | **Behavior when `Role_Template_Safe` or `Role_Group_Prefix` is blank on the active profile** | (a) Hard validation failure, module refuses to run — (b) Blank prefix falls back to "no groups excluded, copy everything" | **(a) for both fields** — `Role_Group_Prefix` is required, same as `Role_Template_Safe`. The module fails fast (non-fatal validation error) if either is blank, rather than silently copying role groups. |
| D5 | **Should `OLACEnabled` ever be read from the template or sent on `POST /API/Safes`?** (raised after initial implementation) | (a) Keep copying it from the template, as originally implemented — (b) Drop it entirely: never read, never asked, never sent | **(b)** — per direct correction: OLACEnabled should never be passed, asked, or used. Removed from `$safeBody`, from both `Results` shapes (WhatIf and real), and from the equivalent code in `Invoke-SafesAdd.ps1` / `Invoke-SafesUpdate.ps1`, which had the same issue. |
| D6 | **Should `NumberOfVersionsRetention` and `NumberOfDaysRetention` both be sent together?** (raised after initial implementation) | (a) Send both, as originally implemented — (b) Send only one; `NumberOfDaysRetention` wins when greater than 0, otherwise `NumberOfVersionsRetention` is sent | **(b)** — per direct correction: the two fields are mutually exclusive on this API. Applied the same rule to `Invoke-SafesAdd.ps1` and `Invoke-SafesUpdate.ps1` (post-merge value, in the Update case) for consistency across all three Safes write paths. |
| D7 | **Global member-name exclusion list** — where should it live, how should names match, and what's the initial content? | Location: (a) `$script:`-scoped constant in the module file only — (b) shared `$script:` constant in `Manage-Privilege.ps1`, visible to every dot-sourced module. Match: (a) exact, case-insensitive — (b) prefix, case-insensitive. Scope: (a) all `memberType`s — (b) `User` only. Seed content: (a) provided names — (b) empty | **Location (b)** — `$script:ExcludedTemplateMemberNames` in `Manage-Privilege.ps1`, alongside other driver-wide constants (`$script:PVWA_SESSION_EXPIRY_MIN` etc.), so any future Safes/SafeMembers module can reuse it without plumbing. **Match (a)** — exact, case-insensitive; no partial/prefix matching. **Scope (a)** — applies across all `memberType`s, consistent with the `Role_Group_Prefix` filter. **Seed content (b)** — starts empty; names to be added directly in `Manage-Privilege.ps1` as needed. |
| D8 | **Where should the CPM to assign come from, now that it's a prompt instead of an auto-copy?** | (a) Keep copying the template's `managingCPM` as before — (b) Prompt with a picker sourced from a new profile field (`CPM_List`, comma-separated), defaulting to none — (c) Prompt with a picker sourced from a live `GET /API/Users?userType=CPM` query, same as `Safes/AssignCPM` | **(b)**, per explicit direction. `CPM_List` is a new profile field (see Section 4), picked via a numbered menu with "(none)" as entry 1 and the default. Falls back to free-text entry if the list is empty. Explicitly *not* wired to `Safes/AssignCPM`'s live-query mechanism — the two pages intentionally use different CPM sources; confirmed directly rather than assumed. CSV/bulk mode gets a plain `ManagingCPM` column (blank = none, no picker). |
| D9 | **How should "additional members" be specified, given InputSchema is a flat CSV row but the list of extra members is variable-length?** | (a) Interactive-only, no CSV/bulk equivalent — (b) One CSV row per extra member, matched to the safe by SafeName (breaks the "one row = one new safe" semantics; the safe would already exist by the second row) — (c) A single delimited-list column on the same row, `Type:Name:RoleName` triples separated by semicolons | **(c)**, per explicit direction ("full CSV support for both"). Chosen over (b) because CyberArk's `POST /API/Safes` would 409 on a second row targeting an already-created safe — this module's row-to-safe mapping is 1:1. The semicolon-list format mirrors the existing convention for list-valued CSV fields elsewhere in this codebase (e.g. `RemoteMachines` on the Accounts API, semicolon-separated). Interactive mode builds this same string internally (via a Y/N "add another member?" loop) so `Invoke-SafesAddFromTemplate` has one parsing path regardless of input source. |
| D10 | **Should adding an extra member offer a SearchIn (Vault/LDAP directory) picker, like `Add Safe Member` / `SafeMembers/AddFromTemplateRole`?** | (a) Yes, for consistency — (b) No, keep it simple: Type (User/Group) + Name + Role only, `searchIn` omitted (API default: Vault) | **(b)**, per explicit direction ("keep it simple"). `membershipExpirationDate` is also always `$null` for extra members, matching this module's existing template-copy convention (D3) rather than `AddFromTemplateRole`'s user-suppliable expiration - these are two different modules with different contracts, and this one's existing convention takes precedence for consistency within itself. |
| D11 | **Interactive additional-members loop: separate Y/N gates, or one recurring prompt?** | (a) Keep the original two-gate design ("Add additional members? Y/N" before the loop, "Add another member? Y/N" after each one) — (b) Collapse both into a single recurring "Additional Member" name prompt per iteration, defaulting to blank; accepting the blank default is both "no (more) members" and the loop's exit condition | **(b)**, per explicit direction. Removes a redundant question - re-prompting for the next member's name each time around already asks "do you want to add another," so a separate Y/N confirmation was asking the same thing twice. `MemberName` moved to be the first thing asked each iteration (previously Type was asked first) since it's now also the loop's exit check. |
| D12 | **Where should a role's description come from for the role picker?** | (a) No description shown, name only (as originally implemented) — (b) Pull it from `GET /API/UserGroups` (the same endpoint as `Groups/List`), matching each role's `memberName` against a group's `groupName` to get its `description` | **(b)**, per explicit direction ("pull the role's description from the Get Groups List"). A role is a CyberArk group by naming convention (`Role_Group_Prefix`) - its description lives on the group object, not on the safe-membership record `script:Get-TemplateRoleOptions` already reads for permissions, so this is a second, best-effort API call. `search=Role_Group_Prefix` narrows the payload server-side as a hint only; matching a specific role to its group is always done client-side by exact `groupName` (case-insensitive), consistent with how this codebase never trusts server-side search alone for exact matching (see `SafeMembers/AddFromTemplateRole`'s role resolution). Never blocks the flow: if the lookup fails, or a role's group can't be matched, `Description` stays `''` and the role is still fully usable by name - same "defensive, non-blocking" contract as every other picker-option-builder in this codebase. Skipped entirely (no API call) when there are zero role options to describe. |
| D12a | **How should the description be displayed - inline or on its own line, and what about descriptions containing embedded line breaks?** (raised after D12 shipped) | (a) Inline, `"1 = RoleName - Description"`, printing a possibly-multi-line string as-is — (b) On a new, indented line beneath the role name; split any embedded CR/LF and indent every resulting line individually | **(b)**, per explicit direction. CyberArk group descriptions are free text and can contain embedded `\r\n`/`\n` - printing one as-is would only visually indent its first line (Write-Host has no per-line indent of its own), with the rest landing back at the console's left margin. Extracted the splitting/trimming/blank-filtering logic into a new `script:Get-DescriptionDisplayLines` helper (returns an array of display-ready lines, empty array for a blank/whitespace-only/missing description) specifically so this has its own dedicated unit test coverage, rather than being inline, unindentable, untestable logic inside `Get-SafesAddFromTemplateInput`. |

---

## 6. File Layout After Implementation

```
APIModules\Safes\
  Invoke-SafesAdd.ps1
  Invoke-SafesGet.ps1
  Invoke-SafesList.ps1
  Invoke-SafesUpdate.ps1
  Invoke-SafesDelete.ps1
  Invoke-SafesAddFromTemplate.ps1   # New
```

---

## 7. Implementation Order

1. ~~Resolve Decisions D1–D4 above.~~ Done (2026-08-20).
2. ~~Create `APIModules\Safes\Invoke-SafesAddFromTemplate.ps1`.~~ Done — UTF-8 with BOM,
   `$ModuleMeta` → `Get-SafesAddFromTemplateInput` → `Invoke-SafesAddFromTemplate`.
3. ~~Implement the read-template → filter-members → create-safe → copy-members flow.~~ Done.
4. ~~Add `Tests\Unit\Invoke-SafesAddFromTemplate.Tests.ps1`.~~ Done — 24 tests (T01–T24),
   all passing; full existing Safes/SafeMembers suite re-run to confirm no regressions.
5. ~~Add a `Claude_Docs\Testing_Plan.md` entry.~~ Done — Component Test Matrix row plus
   `Invoke-SafesAddFromTemplate.ps1 — Test Cases` section (T01–T24).
6. ~~Update `Claude_Docs\Reference_Interfaces.md`.~~ Initially no change needed — the "Consumed by"
   description already matched what was implemented. Later (D7) added a
   `$script:ExcludedTemplateMemberNames` row to the Script-Level Configuration Variables
   table.
7. ~~Update `README.md`.~~ Done — corrected the `Role_Template_Safe` / `Role_Group_Prefix`
   Configuration-table descriptions; updated the Safes project-structure line.
8. ~~Update `Claude_Docs\Design_Architecture.md`.~~ Done — two Design Decisions rows added.
9. ~~Add a `Claude_Docs\Archive_Planning_Documentation-Tracker.md` entry.~~ Done.
10. ~~Fix OLACEnabled / retention-exclusivity issues (D5/D6).~~ Done (2026-08-20) — removed
    `OLACEnabled` and made retention fields mutually exclusive in `Invoke-SafesAddFromTemplate.ps1`,
    `Invoke-SafesAdd.ps1`, and `Invoke-SafesUpdate.ps1`; added T11a–T11c and equivalent
    cases to the other two modules' test files; corrected the T-prefix in `Testing_Plan.md`
    (previously mislabeled AFT01–AFT24).
11. ~~Add the global exclusion list (D7).~~ Done (2026-08-20) — added
    `$script:ExcludedTemplateMemberNames = @()` to `Manage-Privilege.ps1`; filter step in
    `Invoke-SafesAddFromTemplate.ps1` now excludes exact (case-insensitive) name matches
    across all `memberType`s in addition to the `Role_Group_Prefix` filter; added T09a–T09b;
    documented in `Reference_Interfaces.md` and `Design_Architecture.md`.

---

## 8. Revision Log

| Date | Change |
|---|---|
| 2026-08-20 | Document created — initial design draft; Decisions D1–D4 opened |
| 2026-08-20 | Decisions D1–D4 resolved; algorithm and `$ModuleMeta` updated accordingly |
| 2026-08-20 | Implementation complete — module, unit tests, and all doc updates done |
| 2026-08-20 | Decisions D5–D6 added and resolved: OLACEnabled removed entirely; NumberOfVersionsRetention/NumberOfDaysRetention made mutually exclusive. Same fix applied to Invoke-SafesAdd.ps1 and Invoke-SafesUpdate.ps1 |
| 2026-08-20 | Decision D7 added and resolved: added $script:ExcludedTemplateMemberNames global exclusion list in Manage-Privilege.ps1, consumed by Invoke-SafesAddFromTemplate.ps1's member filter |
| 2026-08-25 | Decisions D8-D10 added and resolved: ManagingCPM is no longer copied from the template - a new profile field CPM_List drives an interactive picker (default none), with a plain ManagingCPM CSV column for bulk mode; added an "additional members" feature (Type/Name/Role, role permissions resolved the same way as SafeMembers/AddFromTemplateRole) via an interactive add-another loop or a semicolon-delimited ExtraMembers CSV column. Version bumped to 1.3.0 |
| 2026-08-25 | Added `Example` values to all 4 `InputSchema` columns (1.3.1); `Manage-Privilege.ps1`'s "Generate Template" menu option now writes them as a second CSV row beneath the header, so the `ExtraMembers` `Type:Name:RoleName;...` syntax is shown by example, not just described in prose |
| 2026-08-25 | Fixed a real production crash reported by the user (1.3.2): `[array]$cpmList = if (cond) {@(...)} else {@()}` collapsed to `$null` instead of an empty array, crashing the CPM picker under `Set-StrictMode`. Full root-cause writeup lives in `Reference_Lessons-Learned.md` sections 9.8-9.9, not duplicated here - fixed 3 instances of the pattern plus 2 related hashtable dot-notation bugs in the same file (one of which crashed WhatIf mode unconditionally) |
| 2026-08-25 | Decisions D11-D12 added and resolved (1.4.0): collapsed the additional-members loop from two Y/N gates to one recurring "Additional Member" name prompt (blank = done); added role descriptions pulled from `GET /API/UserGroups` (`Groups/List`'s endpoint), shown alongside each role's name in the picker |
| 2026-08-25 | Decision D12a added and resolved (1.4.1): role description moved from inline (`"1 = RoleName - Description"`) to its own indented line(s) beneath the role name, splitting any embedded `\r\n`/`\n` in the description and indenting each resulting line individually. Extracted the split/trim/blank-filter logic into a new `script:Get-DescriptionDisplayLines` helper (returns an array of display-ready lines, empty for a blank/whitespace-only/missing description) so it has its own dedicated unit test coverage (T41-T44) rather than being inline, untestable logic inside `Get-SafesAddFromTemplateInput` |
