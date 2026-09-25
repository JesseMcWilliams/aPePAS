# Lessons Learned: Index

PowerShell 5.1, Pester v6 and CyberArk API gotchas found while building aPePAS. The lessons are split by
topic. Search the topic files by heading, for example `grep -n "^## " Claude_Docs/Reference_Lessons-Learned-*.md`.
Add a new lesson as a new numbered section at the end of the file it fits, and add a row to the table
below only if you renumber something.

| File | What it covers |
|---|---|
| [Reference_Lessons-Learned-PowerShell.md](Reference_Lessons-Learned-PowerShell.md) | PS 5.1 syntax, UTF-8 BOM/encoding, automatic variables, switch binding, `Import-Module -Global`, `ConvertTo-Json`, `[bool]` casts, `catch`/`WebException` safety, `Invoke-WebRequest` binary content, `ProcessStartInfo`, paths, dialogs, ADSI |
| [Reference_Lessons-Learned-StrictMode.md](Reference_Lessons-Learned-StrictMode.md) | `Set-StrictMode -Version Latest`: where it is active, hashtable keys, `PSObject.Properties` guards, `$null.PSObject`, zero/one-item collapse and `.Count` |
| [Reference_Lessons-Learned-Pester.md](Reference_Lessons-Learned-Pester.md) | Pester v6 file structure, mocks and stubs, `Should -Not -Throw` scope, assertions, test names, full-suite-only failures |
| [Reference_Lessons-Learned-CyberArk-API.md](Reference_Lessons-Learned-CyberArk-API.md) | Identity/ISPSS auth, response shapes by version, ISPSS versus Self-Hosted, field casing, filters, `?search=` encoding, trailing slashes, timestamps |
| [Reference_Lessons-Learned-Module-Conventions.md](Reference_Lessons-Learned-Module-Conventions.md) | Driver and API module patterns: WhatIf, summaries, dot-sourcing scope, `script:` helpers, logging and masking, shared helpers, session tokens |

## Old section numbers → new location

Older citations such as "Lessons-Learned §34" or "Section 9.8" refer to the original single file. File
abbreviations: **PS** = PowerShell, **SM** = StrictMode, **Pester**, **CA** = CyberArk-API,
**Mod** = Module-Conventions.

| Old | New | Old | New |
|---|---|---|---|
| §1.1 | PS §1 | §11 (intro) | CA (file intro) |
| §1.2 | PS §1 | §11.1 | CA §1 |
| §1.3 | PS §2 | §11.2 | CA §2 |
| §2.1 | Pester §5 | §11.3 | Mod §13 |
| §2.2 | Pester §3 | §11.4 | CA §3 |
| §2.3 | Pester §10 | §12.1 | CA §4 |
| §2.4 | Pester §11 | §12.2 | CA §5 |
| §2.5 | Pester §12 | §13.1 | PS §14 |
| §2.6 | Pester §6 | §14 (intro), §14.1 | PS §8 |
| §3.1 | Mod §1 | §14.2 | PS §9 |
| §3.2 | Mod §2 | §14.3 | PS §10 |
| §3.3 | Pester §7 | §15.1 | Mod §11 |
| §4 (intro) | SM §1 | §15.2 | Mod §12 |
| §4.1 | SM §2 | §16.1 | CA §7 |
| §4.2 | SM §4 | §16.2 | CA §8 |
| §4.3 | SM §6 (takeaway: SM §7) | §16.3 | CA §9 |
| §4.4 | SM §1 | §16.4 | CA §7 |
| §4.5 | SM §2 | §17.1 | Mod §5 |
| §4.6 | SM §6 | §18.1 | PS §5 |
| §4.7 | SM §3 | §19.1 | CA §13 |
| §5.1 | PS §3 | §20.1 | PS §13 |
| §6.1 | Mod §4 | §21.1 | CA §14 |
| §6.2 | Mod §6 | §22.1 | CA §15 |
| §7.1 | Mod §3 | §23.1 | CA §16 |
| §7.2 | SM §4 | §24.1 | SM §4 |
| §8.1 | Mod §7 | §25.1 | Mod §9 |
| §8.2 | PS §15 | §26.1 | PS §2 |
| §8.3 | PS §16 | §27.1 | SM §5 |
| §8.4 | CA §12 | §28.1 | CA §11 |
| §8.5 | CA §6 | §29.1 | PS §4 |
| §9 (intro), §9.1 | Pester §1 | §30.1 | PS §6 |
| §9.2 | Pester §2 | §31.1 | PS §7 |
| §9.3 | Pester §4 | §31.2 | CA §11 (rule: Mod §8) |
| §9.4 | Pester §8 | §31.3 | Mod §10 |
| §9.5 | Pester §9 | §32 | Pester §6 (follow-up: Pester §15) |
| §9.6 | Pester §14 | §33 | CA §9 (rule: Mod §8) |
| §9.7 | Pester §16 | §34 | CA §10 |
| §9.8 | SM §6 (PS 7 masking: SM §7) | §35 | PS §12 |
| §9.9 | SM §1 (audit and rule: Pester §15) | §36 | SM §6 (full-suite rule: Pester §15) |
| §10.1, §10.2, §10.3 | PS §2 | §37 | SM §2 |
| | | §38 | Pester §13 |
| | | §39 | PS §11 |

**Old headings cited by name:**
- "Pester v6 Test File Structure" (old §9): Pester §1 to §4, §8, §9, §14, §16.
- "Unit tests do not run under Set-StrictMode" (old §9.9): StrictMode §1 and Pester §15.
- "Section 12" (old §12): CyberArk-API §4 and §5. "Section 16" (old §16): CyberArk-API §7 to §9.
  "Section 4/24": StrictMode §2 and §4.
- "Section 40" (cited in `Invoke-CustomExportPlatformDetails.ps1`): no such section existed. The XML/XPath
  lesson it points to was never written down.
