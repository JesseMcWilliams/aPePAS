# aPePAS

A PowerShell 5.1 interactive driver for CyberArk Privileged Access Security (PAS), supporting both **ISPSS (Privilege Cloud)** and **Self-Hosted PVWA** environments. Provides a menu-driven console interface for common administrative tasks — account management, safe management, user and group operations, platform administration, connectivity testing, and bulk exports.

> **New to the tool?** Start with the [User Guide](User_Docs/User-Guide.md). This README is an overview. The detail lives in the documents linked below.

---

## Features

- **Menu-driven console** for CyberArk **Self-Hosted PVWA (v12+)** and **ISPSS / Privilege Cloud**, with 67 actions across 10 categories: Accounts, Applications, Custom, Groups, Platforms, Policies, Reports, SafeMembers, Safes and Users.
- **Profiles** for multiple environments, with encrypted local storage, backup and restore, and startup profile selection.
- **Authentication:** CyberArk, LDAP, RADIUS, SAML, OIDC, Shared, PKI and PKIPN (Self-Hosted), and ClientCredentials, Interactive and SSO (ISPSS). Tokens are refreshed proactively.
- **CSV batch processing** for every write action, plus CSV template generation.
- **Automation mode** for non-interactive, scheduled runs (`-StartProfile`, `-Category`, `-Action`).
- **WhatIf mode**, an **interactive API tester**, **connectivity testing** (DNS, TCP, SMB/SSH credentials) and **bulk exports**.
- **Structured logging** to a rotating log file.

See [User_Docs/Features.md](User_Docs/Features.md) for the full feature list.

---

## Requirements

| Requirement | Version |
|---|---|
| PowerShell | 5.1 (Windows PowerShell) |
| CyberArk PVWA | v12.0+ (Self-Hosted) |
| CyberArk ISPSS | Any current Privilege Cloud tenant |
| .NET Framework | 4.7.2+ (ships with Windows 10/Server 2019+) |
| Pester (tests only) | v6.x |

SAML/OIDC/SSO login also needs the WebView2 runtime and assembly, and the Linux connectivity test works best with `plink.exe`. See [Before You Start](User_Docs/User-Guide.md#1-before-you-start) in the User Guide.

---

## Quick start

```powershell
git clone <repo-url> C:\Tools\aPePAS
cd C:\Tools\aPePAS
powershell.exe -ExecutionPolicy Bypass -File .\Manage-Privilege.ps1
```

At the **Profile Selection** screen, press **N** to create a profile, authenticate, and then use the category and action menus. For installation details (unblocking ZIP downloads, WebView2) and a full walkthrough, see the [User Guide](User_Docs/User-Guide.md).

---

## Documentation

| Topic | Document |
|---|---|
| Using aPePAS | [User_Docs/User-Guide.md](User_Docs/User-Guide.md) |
| Full feature list | [User_Docs/Features.md](User_Docs/Features.md) |
| Architecture and design decisions | [Claude_Docs/Design_Architecture.md](Claude_Docs/Design_Architecture.md) |
| Writing new API modules | [Claude_Docs/Reference_API-Module-Guide.md](Claude_Docs/Reference_API-Module-Guide.md) |
| Data contracts (profile, token, result objects) | [Claude_Docs/Reference_Interfaces.md](Claude_Docs/Reference_Interfaces.md) |
| Testing, known issues | [Claude_Docs/Testing_Plan.md](Claude_Docs/Testing_Plan.md) |
| PowerShell 5.1 / Pester / CyberArk gotchas | [Claude_Docs/Reference_Lessons-Learned.md](Claude_Docs/Reference_Lessons-Learned.md) (index of the `Reference_Lessons-Learned-*.md` topic files) |

`Claude_Docs/` holds the working project docs, named by stage (`Planning_`, `Design_`, `Testing_`, `Reference_`, `Archive_`). `User_Docs/` holds end-user documentation.

---

## Project layout

```
Manage-Privilege.ps1   Main interactive driver
APIModules/            One Invoke-<Category><Action>.ps1 per action
Auth/                  Self-Hosted, ISPSS and shared authentication modules
Modules/               REST comms, logging and credential store
Tests/                 Pester unit tests (Run-Tests.ps1) and opt-in integration tests
Claude_Docs/           Project docs (design, testing, reference, archive)
User_Docs/             End-user docs
Count-AccountsPer*.ps1 Standalone CSV reporting utilities
```

The full folder structure is in [Design_Architecture.md](Claude_Docs/Design_Architecture.md#folder-structure).

---

## Running tests

```powershell
.\Tests\Run-Tests.ps1
```

See [Running Tests](Claude_Docs/Testing_Plan.md#running-tests) in the Testing Plan for options.

---

## License

Internal tooling — all rights reserved. Not for redistribution without authorization.

