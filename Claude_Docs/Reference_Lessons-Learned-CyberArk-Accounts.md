# Lessons Learned: CyberArk Accounts API

> **Stage: Reference.** Behavior of the Accounts endpoints (list limits, saved filters, JIT access, dependent accounts,
> delete, discovered accounts, CPM tasks) found in testing or live use. Split out of
> `Reference_Lessons-Learned-CyberArk-API.md` on 2026-11-11; its §8 and §23 to §28 point here. Each entry lists the
> symptom, the cause, the rule, and one example. Add a new Accounts lesson as a new numbered section at the end.

---

## 1. `GET /API/Accounts` caps at about 20,000 results without a safe filter

**Cause:** this is a server-side cap. Pagination doesn't get past it.

**Rule:** list the safes with `GET /API/Safes`, then call `GET /API/Accounts?filter=safeName eq <safe>` for
each safe (paginated normally), and combine the results. The cap doesn't apply per safe. This is
`Invoke-AccountsList`'s "By Safe" mode.

---

## 2. JIT access (GrantAdministrativeAccess) works only for an LDAP caller

**Symptom:** `POST /API/Accounts/{id}/GrantAdministrativeAccess` and `.../RevokeAdministrativeAccess` return HTTP 403
PASWS211E "Cannot grant access to a non-LDAP user" / PASWS293E "Cannot revoke access to a non-LDAP user" (confirmed live
2026-10-10, logged on as a Vault user).

**Cause:** the PVWA adds the *logged-on* user to the target machine's local Administrators group, so that user must be a
domain (LDAP) user. There is no body and no way to name another user. psPAS sends no body either.

**Rule:** a JIT live test needs a profile that logs on as an LDAP user, plus a Windows account on a platform that allows ad
hoc access. Testing as the Vault automation user only proves the endpoint exists.

---

## 3. Dependent accounts: the vault-wide filter has no master-account field

**Symptom:** `GET /API/DependentAccounts?filter=MasterAccountId eq 49_3` returns HTTP 400 PASWS357E "Parameter
`MasterAccountId` is not valid". `masterAccountId` and `accountId` fail the same way (confirmed live 2026-10-11).
`platformId eq SchedTask` and `SafeName eq "Test Accounts"` work. Adding a dependent whose platform doesn't fit the master
gets 400 PASWS366E "Dependent platform `X` is invalid for platform `Y`".

**Cause:** psPAS 8.0.20 documents a `MasterAccountId` filter that this PVWA doesn't accept. The 14.6 Swagger describes
`filter` only as "keywords". The vault-wide list comes back wrapped (it paged normally), not as the bare array the Swagger shows.

**Rule:** to list one master's dependents, use `GET /API/Accounts/{id}/DependentAccounts`. Don't add a master filter to the
vault-wide list without a live check. Pick a dependent platform (for example `SchedTask`) that matches the master's platform.

---

## 4. Deleting an SSH key account: v2 refused, classic v1 worked

**Symptom:** on the lab PVWA (2026-10-11), `DELETE /API/Accounts/{id}` on a `UnixSSHKeys` account (`secretType` = key,
automatic management off) returned HTTP 400 `{"ErrorCode":"PASWS056E","ErrorMessage":"The account is not valid for delete"}`,
with no other detail, both before and after CheckIn. The account had no lock or check-out in its Activities.
`DELETE /WebServices/PIMServices.svc/Accounts/{id}` (classic v1) returned 200, and a GET afterwards showed `deletionTime`
(the safe keeps it for its retention period).

**Cause:** unconfirmed. v2 deletes of password accounts in the same safe work, so the secret type is the likely difference.
No local reference (Swagger, psPAS, ISPSS docs) mentions PASWS056E.

**Rule:** if a v2 account delete gets PASWS056E, retry on the classic v1 route. `Accounts/Delete` does this for that error code only
(K21) and reports `DeleteRoute` = v1. psPAS `Remove-PASAccount` also has a v2 SSH key option (`deleteSshKeyFromVaultAndTarget`
on Self-Hosted 15.2+, `deleteOnlyPrivateSshKey` on Privilege Cloud). It isn't in the 14.6 Swagger and wasn't tried against PASWS056E.

---

## 5. Onboarding a discovered account fails without a default password

**Symptom:** on the lab PVWA (14.6, 2026-10-14), `POST /API/DiscoveredAccounts/{id}/Onboard` with only `platformId` and
`safeName` returned HTTP 400 `{"ErrorCode":"DAFWS005E","ErrorMessage":"Failed to onboard account."}` for two pending
Windows Server Local accounts, one with a `LastPasswordSet` date and one without. Safe permissions, the platform and the
safe all checked out. The same call with `defaultPassword` added returned 200 with an **empty body** (no new account ID).

**Cause:** the PVWA log for the request's `X-Correlation-ID` showed its permission and platform checks passing, then
`System.NullReferenceException` in the onboard's password handling (`a52.a(PVPassword ...)`), rethrown as the generic
DAFWS005E. psPAS `Publish-PASDiscoveredAccount` and the 14.6 Swagger both treat `defaultPassword` as optional.

**Rule:** send `defaultPassword` when onboarding from the Pending list on a 14.6 PVWA. `Accounts/OnboardDiscovered` adds a
hint to DAFWS005E when none was given. Find the new account by username afterwards, since the response has no ID. For
any generic 4xx, run with `-Verbose` (or `-LogLevel VERBOSE`) and give the PVWA admin the response's `X-Correlation-ID`.

---

## 6. Accounts `savedFilter` is dropped from `nextLink`

**Source:** psPAS 8.0.20 `Private/Get-NextLink.ps1` ("SavedFilter is not included in NextLink value") re-adds it to every
follow-up URL. Not yet seen live in aPePAS.

**Rule:** never page `GET /API/Accounts?savedFilter=...` by following `nextLink` alone, or pages after the first come
back unfiltered. `Invoke-CyberArkAPI` pages by offset and re-sends all `QueryParams`, so it is safe. Valid values come
from `Get-CyberArkAccountSavedFilterList` (Swagger 14.6 enum plus Privilege Cloud-only `DeleteInsightStatus`).

---

## 7. A manual Verify or Reconcile re-enables a CPM-disabled account; a user-disabled one is refused

**Seen live** on Self-Hosted PVWA 14.6, 2026-11-11 (LT-ACCOUNTS-03):
- CPM-disabled (`(CPM)MaxRetries`): `POST /API/Accounts/{id}/Verify` and `.../Reconcile` return 200, and afterwards the
  account has `automaticManagementEnabled` true and an empty `manualManagementReason`. No resume call was needed.
- User-disabled (a manual reason): `POST .../Verify` returns `400 EPVWA174E` `Automatic management for this account was
  disabled by the user`. (The feature plan cites the UI message EPVPA007E for a disabled account; whether it is this case
  isn't confirmed.)
- `POST /API/Accounts/{id}/Resume/` returns 404 with an empty body on 14.6 (it is 15.2+). The JSON Patch fallback
  (`automaticManagementEnabled` true, `manualManagementReason` empty) works.
- A second Verify sent while the first is still pending returns `400 PASWS143E` `Password is locked by another user`.

**Rule:** don't assume a CPM-disabled account blocks a manual CPM task on Self-Hosted 14.6. Change Immediate, ISPSS and
other PVWA versions are not yet checked.

## 8. CPM tasks on an account whose safe has no CPM fail with EPVWA173E

**Seen live** on Self-Hosted PVWA 14.6, 2026-11-11 (LT-ACCOUNTS-05):
- `POST /API/Accounts/{id}/SetNextPassword/` returned `400 EPVWA173E` `The account is not managed by the CPM` while
  the account had `automaticManagementEnabled` true. The account's safe had no `managingCPM`. After a CPM was
  assigned to the safe, the same call returned 200.
- With `ChangeImmediately: true`, the activity log shows `Update File Category: Value=[ChangeTask]` (the immediate task),
  then the CPM change. `ChangeInVault` with `ChangeEntireGroup: true` on an account outside a group returns 200.

**Rule:** when a CPM task returns EPVWA173E, check the safe's `managingCPM` before the account's
`automaticManagementEnabled`. The account flag alone doesn't mean a CPM will act on it.
