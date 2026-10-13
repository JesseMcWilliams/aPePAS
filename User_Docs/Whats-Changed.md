# What's Changed in aPePAS 1.5.0

Release candidate, 2026-10-12. The startup banner and log now show version 1.5.0 (it was 1.0.0). This covers every change
since the user documentation was last rewritten (2026-10-10).
For how to use each action, see the [User Guide](User-Guide.md) and the [CSV Reference](CSV-Reference.md).

## Before you upgrade

- **Copy the new `Driver` folder.** `Manage-Privilege.ps1` now loads its menus, profiles and automation code from a
  `Driver` folder next to it, like `Modules`, `Auth` and `APIModules`. If a part is missing, startup lists it under
  "Prerequisite check failed" and exits with code 1.
- **OIDC sign-in is no longer offered for Self-Hosted.** PVWA 14.6 ends an OIDC sign-in with a browser session, not a
  token aPePAS can use, so the option never worked. A profile saved with OIDC stops with a message asking you to
  pick another method. Use SAML, LDAP or another method instead.
- **Self-Hosted SAML profiles sign in differently** (see below). Nothing needs to change in the profile, but SAML
  must be set up on the PVWA and the WebView2 DLLs must be available.

## New actions

**Accounts**
- **Request JIT Access** and **Revoke JIT Access**: add or remove yourself from the local Administrators group on
  the account's Windows machine. Needs a profile that signs in with LDAP.
- **Retrieve SSH Key**: saves an account's private key to a `.key` file in the Output Folder. The key never appears
  on screen, in the log or in the results CSV.
- **Discovered (Pending) accounts**, Self-Hosted: List, Get, Onboard and Delete Discovered Account, and List
  Onboarding Platforms.
- **Dependent accounts**, Self-Hosted: List Dependent Accounts (one master), List All Dependent Accounts, and Get,
  Add, Update, Delete, Sync and Resume Dependent Account.

**Users** (Self-Hosted unless noted)
- **Add**, **Update**, **Delete**, **Enable**, **Disable**, **Unblock**, **Reset Password**, and **Add / Remove
  Allowed Auth Method**. Users are found by UserID or exact Username. Delete, Unblock and Reset Password are also offered
  on Privilege Cloud (not yet confirmed live there). Passwords are entered twice, hidden, and never logged or written to a results file.

**Reports**
- **Export Report**, Self-Hosted (PVWA 14.6 and later): download a report as Excel or CSV by exact name or by ID.

**Filters on existing actions**
- **List Safe Members**: optional MemberType, MembershipExpired and Sort.
- **List Platforms**: optional PlatformType (Regular or Group).
- **Test Connectivity**: an optional Safe narrows the account lookup, and a new Note column reports when several
  accounts matched.

## Automation

- **Job files (`-JobFile`)**: run several actions under one sign-in. The whole file is checked before signing in.
  Each step can set its own OutputFolder, file name format and WhatIf. The run stops when a `StopOnFailure` step
  fails, and exits with the worst step's code. `JobFile.example.json` is a template.
- **Detailed results CSV**: every CSV run also writes `<input>_<date>_detail.csv`, one line per result or error, with
  the row number and status. Password-like columns are masked.
- **Output files follow `-OutputFolder`**: Retrieve SSH Key, Export Platform and Export Report now save to
  `-OutputFolder` (or the job step's OutputFolder), like the results CSVs.
- **Bad input file exits 3**: an `-InputFile` that is empty, unreadable or missing a required column now exits with
  code 3.

## Sign-in

- **Self-Hosted SAML now works with an identity provider.** The sign-in starts at the PVWA, a browser window opens at
  your identity provider, and it closes by itself once you've signed in. Before, the window opened an address the
  PVWA refuses.
- **OIDC removed from the Self-Hosted methods**, as described under "Before you upgrade".
- **Idle timeout** now counts from the last call aPePAS made to CyberArk for you, not from menu navigation.

## Fixes

- **Safe member expiration dates** work (Add and Update failed with any date). List Safe Members, the Update results
  and Export Entitlements show them as local `yyyy-MM-dd HH:mm` instead of a raw number.
- **Safe member permissions**: a PermissionRole (other than Specified) applies its preset and ignores the individual
  permission columns. On Update, blank permission columns and a blank ExpirationDate keep the member's current
  values, and `None` removes the expiration.
- **Get User** shows the business email (it was always blank), plus Enabled, Suspended, Description, Location and
  ExpiryDate. **List Users** drops its always-blank Email column, adds Enabled, Suspended and Location, and pages
  correctly on vaults with more users than one page holds.
- **Add / Remove Allowed Auth Method** reported success when the PVWA's background job had failed. It now checks the
  result, makes the change directly when the job fails, and reports a failure if the PVWA didn't save the change.
  Changing a user who never expires no longer fails with PASWS284E.
- **Delete Account** now deletes SSH key accounts that the PVWA refuses with PASWS056E, by retrying on the older
  delete route. The log shows a warning when that happens.
- **Results CSVs** no longer copy password or secret input columns in clear text.
- **Log lines** no longer show a garbled `***` where they report whether a password was given.
- **Export All**, Export Platform and Test API save to the script folder when the Output Folder is blank, like every
  other save. Export All can include safe members (off by default).
- **Reports List** reads the PVWA 14.6 report list and shows Status, CreatedAt, CreatedBy, Records, Safe, Location
  and FileName.

## Known issues

- **Duplicate summary lines in automation mode**: the Session Summary can list an action twice and double its
  totals.
- **Allowed auth methods on LDAP users** can't be changed per user. The PVWA takes them from the LDAP directory
  mapping, so change the mapping instead.
