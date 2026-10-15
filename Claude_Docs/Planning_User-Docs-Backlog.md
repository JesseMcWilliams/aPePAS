# aPePAS: User Docs Backlog

> **Stage: Planning.** Add one line per user-visible change when it's made. At the end of the project, `User_Docs/` is written from this list instead of re-reading the project history. Once an entry is covered in `User_Docs/`, delete it.

| Date | Change | User doc / section it affects |
|---|---|---|
| 2026-10-14 | Accounts now has a group menu between the category and its actions: Accounts, CPM tasks, Access and retrieval, Linked accounts, Dependent accounts, Discovered accounts. Groups with no actions for the system type (Dependent and Discovered on ISPSS) aren't shown. Action numbers changed | Interactive menu / Accounts actions |
| 2026-10-14 | `-Verbose` (or `-LogLevel VERBOSE`) on `Manage-Privilege.ps1` and `Invoke-AutomationWithCredential.ps1` writes every API call's request headers, response headers and response body to the log file (not the console). Credential headers show as `***` and password/SSH-key retrieval bodies are withheld. Log files get large on big lists | Troubleshooting / logging, parameter reference |
