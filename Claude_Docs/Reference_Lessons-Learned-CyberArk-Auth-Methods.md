# Lessons Learned: Self-Hosted External Authentication Methods

> **Stage: Reference.** SAML, OIDC and LDAP on a Self-Hosted PVWA, and how users' allowed methods are set. Found while
> wiring a lab IdP (Authentik 2026.8) to PVWA 14.6 on 2026-10-12. Lab details stay in `Live-Testing.local.md`.

## 1. SAML: PVWA accepts only a response it asked for (SP-initiated)

**Symptom:** a correct, signed SAML response posted to `/api/auth/saml/logon` returns HTTP 400 PASWS035E
"Authentication failure". The PVWA log says `SamlInResponseToMismatchException: SAML response was not authorized.
IdP initiated SSO is disabled.` A browser logon from the PVWA logon page works.

**Cause:** the response must answer a request PVWA issued (`InResponseTo`). An IdP-initiated response has none.
On 14.6 the old psPAS start URL `{PVWA}/auth/saml/` only redirects to `/v10/`.

**Rule:** start every SAML logon at PVWA:
1. `POST {PVWA}/api/auth/saml/logon` with an empty form body returns the IdP URL (a JSON string carrying a `SAMLRequest`).
2. Sign in at that URL. The IdP form-posts `SAMLResponse` back to `/api/auth/saml/logon`.
3. `POST` that `SAMLResponse` with `apiUse=true` (and `concurrentSession=true` if wanted) to the same endpoint, as a
   form. The body is the REST token.

Use one web session for steps 1 and 3. PVWA stores each assertion it accepts, so the browser must not deliver the
response itself before step 3 (aPePAS catches the post in the WebView2 window: F102). `GET` on the endpoint is 405.

## 2. OIDC: the start URL names the provider, and the logon ends in cookies

**Facts (PVWA 14.6, live 2026-10-12):**
- Start: `GET {PVWA}/api/auth/OIDC/{providerId}/Authorize` returns a 302 to the IdP with `response_mode=form_post`.
  The redirect URI is `{PVWA}/api/Auth/OIDC/{providerId}/Token`.
- The IdP form-posts `code` and `state` to the Token URL. PVWA exchanges the code and answers 302 to `/v10` with
  session cookies (`CA11111`, `CA22222`, `CA55555`, `CA66666`). No token is returned, and `apiUse=true` on the
  Authorize URL changes nothing.
- With those cookies, v2 calls work (`/API/Safes`, `/api/currentuser`) and logoff works. Classic
  `/WebServices/PIMServices.svc/...` calls fail with CAIWS001E "Couldn't retrieve session token from request
  header". No cookie value works as an `Authorization` header.
- An OIDC provider also needs a `/API/Configuration/AuthenticationMethods` entry with the same ID (CyberArk docs).
  Its `displayName` can't contain parentheses (PASWS258E).

**Rule:** an API client can't get a header token from an OIDC logon on 14.6. Supporting OIDC means sending the
session cookies, and the classic endpoints stay out of reach (F103).

## 3. OIDC: a silent failure after the code exchange

**Symptom:** the PVWA log shows `Exchanging code for id token ... [Basic]`, then `Token Response:: Code: 302`
with no error, and the browser lands back on the logon page.

**Causes found:** the IdP's OAuth provider had no grant types set, and the IdP's origin was missing from the PVWA
Allowed Referrers (`/API/Configuration/AccessRestriction/AllowedReferrers`). Fixing both made it work. A user
whose allowed methods don't include the provider's method ID is a third possible cause.

**Rule:** for a new OIDC provider, check the IdP grant types (`authorization_code`, plus `refresh_token`
if wanted), add the IdP origin to Allowed Referrers, and add the method to the user before testing.

## 4. Allowed methods: a disabled method is dropped without an error

**Symptom:** `PUT /API/Users/{id}` with `allowedAuthenticationMethods` that includes a method returns 200, but the
saved list (in the PUT response and a later GET) leaves that method out. It stuck once the method was enabled.

**Rule:** after a PUT, compare the `allowedAuthenticationMethods` the response returns with what was sent.
aPePAS Users AddAuthMethod and RemoveAuthMethod fail the row when they differ (F100). The cause (the method being
disabled at the time) fits what was seen but isn't confirmed.

## 5. Allowed-methods Bulk endpoints: 200 means queued, and the job can fail

**Facts:** `PATCH /API/Users/AddAllowedAuthenticationMethods/Bulk` (and `Remove...`) returns HTTP 200 with a bare
number: the bulk job ID. `GET /API/BulkActions/{id}?displayExtendedItems=true` returns `Status`,
`Summary {Total, Succeeded, Failed}` and `FailedItems[].Error {ErrorCode, ErrorMessage}` (14.6 Swagger
`BulkInfraOperationStatus`). On the lab PVWA every job failed with `CAWS00001E Not a valid Win32 FileTime.` for
users with no expiry date, including the automation user.

**Rule:** wait on the job (`Wait-CyberArkBulkAction`) before reporting success, and fall back to `PUT` on failure.

## 6. A user with no expiry reads back `expiryDate = -62135568000`

**Symptom:** a `PUT /API/Users/{id}` built from the user's own GET fails with PASWS284E.

**Cause:** "never expires" comes back as `-62135568000` (DateTime.MinValue in Unix seconds), and PVWA won't accept
that value on a PUT.

**Rule:** leave a negative `expiryDate` out of the PUT body (`ConvertTo-CyberArkUserPutBody`, F101).

## 7. LDAP users: allowed methods come from the directory mapping

**Symptom:** for a user with `source: LDAP`, the allowed-methods field is greyed out in the PVWA user page, even
for the built-in Administrator.

**Rule:** set `AllowedAuthenticationMethods` on the directory mapping that matches the user
(`/API/Configuration/LDAP/Directories/{dir}/Mappings/{mappingId}`, 14.6 Swagger `LDAPMappingData`). It applies to
every user the mapping covers. The lab admin set it in the PVWA UI.

## 8. Adding an LDAP directory: send Port and SSLConnect at the top level too

**Symptom:** `POST /API/Configuration/LDAP/Directories/` with `DCList: [{ Name, Port: 636, SSLConnect: true }]`
returns 400 PASWS233E "LDAP Directory can't contains diffrenet DCs with diffrenet ports/ssl configuration".

**Rule:** also send top-level `Port` and `SSLConnect` matching the DC entries, even though the Swagger marks
`SSLConnect` read-only. `DirectoryType` is a profile file name such as `MicrosoftADProfile.ini`. An IdP's LDAP
facade that exposes `sAMAccountName` and `memberOf` (Authentik does) works with the AD profile. A mapped LDAP user
is created in the Vault at first logon. The lab's PVWA `ldap` method was disabled and was enabled before that logon.

## 9. WebView2: set the user data folder

**Symptom:** under Windows PowerShell 5.1 the sign-in window shows "We couldn't create the data directory ...
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe.WebView2\EBWebView".

**Cause:** with no user data folder set, WebView2 creates `<host exe>.WebView2` next to the running program, and a normal
user can't write under System32.

**Rule:** set `CoreWebView2CreationProperties.UserDataFolder` (WinForms control, before `EnsureCoreWebView2Async`) to a
per-user folder. aPePAS uses `%LOCALAPPDATA%\aPePAS\WebView2` (F105).
