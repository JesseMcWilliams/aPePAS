# aPePAS: User Docs Backlog

> **Stage: Planning.** Add one line per user-visible change when it's made. At the end of the project, `User_Docs/` is written from this list instead of re-reading the project history. Once an entry is covered in `User_Docs/`, delete it.

| Date | Change | User doc / section it affects |
|---|---|---|
| 2026-10-10 | F93: Safe member expiration dates now work (Add/Update failed with any date before). List Safe Members, the Update results and Export Entitlements show them as local `yyyy-MM-dd HH:mm` instead of a raw number. CSV-Reference already updated. | User-Guide §6 SafeMembers; Export Entitlements output columns |
| 2026-10-10 | F94: Get User now shows the business email (it was always blank) plus Enabled, Suspended, Description, Location and ExpiryDate. List Users drops its always-blank Email column and adds Enabled, Suspended and Location. User-Guide §6 Users updated | `User-Guide.md` §6 Users, `CSV-Reference.md` (output columns, if documented) |
| 2026-10-10 | F95: List Users (and username lookups) now page correctly on vaults with more users than one page holds | None needed unless paging is documented |
