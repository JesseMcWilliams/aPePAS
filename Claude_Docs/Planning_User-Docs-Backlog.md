# aPePAS: User Docs Backlog

> **Stage: Planning.** Add one line per user-visible change when it's made. At the end of the project, `User_Docs/` is written from this list instead of re-reading the project history. Once an entry is covered in `User_Docs/`, delete it.

| Date | Change | User doc / section it affects |
|---|---|---|
| 2026-09-25 | `Tests\Run-Tests.ps1` now requires Pester 6.0 or later (was 5.0). Its banner and the driver header say "aPePAS" instead of "Idira Unified Scripts". | User-Guide requirements / running tests |
| 2026-09-25 | On PowerShell 7, API errors now report their real HTTP status (a 404 used to show as a failed connection and force a needless re-login). Export All now shows a failed sub-report as Failed with its error, re-checks the login once before stopping on a 401, and in automation mode exits 2 (not 0) when any sub-report fails. Export All no longer runs List Reports, and runs the Master Policy snapshot on Self-Hosted only. | User-Guide Export All and automation exit codes |
| 2026-10-06 | Add Application Authentication Method supports `certificateattr` (certificate attributes). New optional CSV columns `Subject`, `Issuer` and `SubjectAlternativeName` take semicolon-separated `Attribute=value` pairs; at least one is needed, and `AuthValue` is no longer a required CSV column (it's still required for every other type). | User-Guide §6 Applications; CSV input reference |
| 2026-10-06 | List Application Authentication Methods now has `Subject`, `Issuer` and `SubjectAlternativeName` columns (filled for `certificateattr` methods, blank otherwise), and the Delete Application Authentication Method picker shows those values instead of a blank Value. | User-Guide §6 Applications |
| 2026-10-06 | Not a code change: Test API strips `/PasswordVault` from the base URL, so PVWA paths must include it (for example `/PasswordVault/WebServices/PIMServices.svc/...`). Without it you get a 404. | User-Guide §9 Test API |
| 2026-10-06 | Generate Template for Add Application Authentication Method now writes an example `certificateattr` row under the header. Like the Add Safe From Template example, delete it before running the CSV. | User-Guide CSV templates |
