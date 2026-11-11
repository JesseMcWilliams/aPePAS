# Lessons Learned: PowerShell HTTP Calls

> **Stage: Reference.** `Invoke-WebRequest` and `WebException` behavior on PS 5.1 and PS 7: catching HTTP errors,
> reading error bodies and redirects, and binary responses. Split out of `Reference_Lessons-Learned-PowerShell.md` on
> 2026-11-11; its §9, §10, §11 and §18 point here (§10 and §18 were merged into §1). Each entry lists the symptom, the
> cause, the rule, and one example.

---

## 1. Catch HTTP errors with one `catch` and `Get-CyberArkHttpErrorResponse`

**Symptom:** two failures with one fix:
- Under PowerShell 7, every HTTP error from `Invoke-CyberArkAPI` (404, 400, even an expected 404 fallback) came back
  as StatusCode 0, and the driver re-authenticated as if it were a 401. PS 5.1 was fine (F70).
- Under PS 5.1, the status code and headers came through but the captured error body was always `''`, so
  `ConvertFrom-Json` gave `$null`. A real CyberArk 400 with `Content-Length: 80` arrived this way in
  `Invoke-CustomTestApi.ps1`, whose only purpose is to show that body.

**Cause:** PS 5.1's `Invoke-WebRequest` throws `System.Net.WebException` (its `Response` is an `HttpWebResponse`).
PS 7 throws `Microsoft.PowerShell.Commands.HttpResponseException` (its `Response` is an `HttpResponseMessage`),
which does not derive from `WebException`, so `catch [System.Net.WebException]` never sees it. Separately, PS 5.1
has already read the forward-only, single-read error stream to fill `$_.ErrorDetails.Message`, so a second read of
`GetResponseStream()` returns empty. Both were confirmed with a local `HttpListener`.

**Rule:** don't catch HTTP errors by `[System.Net.WebException]`, and don't read the error stream yourself. Use one
`catch` and call `Get-CyberArkHttpErrorResponse` (`CyberArkComms.psm1`). It returns the status, body and headers
from either type, or `$null` for a non-HTTP error. It matches the PS 7 type by name, because that type doesn't
exist in 5.1, and reads the body from `$_.ErrorDetails.Message` first. Test thrown errors against a real local
`HttpListener` (`CyberArkComms.Tests.ps1` C44+): neither `Response` type can be faked in pure PowerShell.

```powershell
} catch [System.Net.WebException] { ... }                            # wrong: PS 7 errors skip this
} catch { $httpErr = Get-CyberArkHttpErrorResponse -ErrorRecord $_ }  # correct: both editions
```

---

## 2. Read `.Response` only after a `[System.Net.WebException]` type check

**Symptom:** an exception is thrown **inside** the `catch` block while reading the HTTP status or redirect
host.

**Cause:** there are two separate failures:
- **A, invalid state:** after an SSL/TLS, certificate or mid-stream abort failure, `WebException.Response`
  is non-null but invalid. A null check passes, then reading `.ResponseUri` or `.StatusCode` throws
  `InvalidOperationException`.
- **B, wrong type:** `$_.Exception` isn't always a `WebException` (`UriFormatException`,
  `RuntimeException`, `CmdletInvocationException`, `HttpRequestException`, ...). Under strict mode,
  `.Response` throws `PropertyNotFoundException: The property 'Response' cannot be found on this object.`
  In PS 5.1 this can escape an enclosing `try/catch`, especially the `$x = try {...} catch {...}` form with
  `$ErrorActionPreference = 'Stop'`.

| Network condition | Exception type | `.Response` |
|---|---|---|
| HTTP redirect (`-MaximumRedirection 0`) | `WebException` | valid, `.ResponseUri` readable |
| DNS failure / TCP refused | `WebException` | `$null`, safe |
| SSL/TLS, certificate error, connection abort | `WebException` | non-null but **invalid** |
| URI format / script throw / wrapped cmdlet error | other types | no property: **PropertyNotFoundException** |

**Rule:** walk `InnerException` to find a `[System.Net.WebException]`, read `.Response` only on that, and
still wrap the read in `try/catch` for failure A. For redirect probing, prefer `HttpWebRequest` with
`AllowAutoRedirect = $false`. It returns a 3xx as a normal response with a `Location` header, not as an
exception, and a typed `catch [System.Net.WebException]` makes `.Response` safe.

```powershell
$webEx = $null; $cur = $null
try { $cur = $caughtError.Exception } catch { }
while ($cur) {
    if ($cur -is [System.Net.WebException]) { $webEx = $cur; break }
    $next = $null; try { $next = $cur.InnerException } catch { }; $cur = $next
}
$statusCode = 0
if ($webEx) { try { $statusCode = [int]($webEx.Response.StatusCode) } catch { } }
```

---

## 3. `Invoke-WebRequest .Content` can corrupt binary data: use `RawContentStream`

**Symptom:** a downloaded file (the `Platforms/Export` `.zip`) is corrupted, or JSON-versus-binary is
guessed wrong.

**Cause:** this was confirmed with a local `HttpListener` test under real PS 5.1. With `-UseBasicParsing`,
`.Content` is a correct `[byte[]]` when `Content-Type` is binary (`application/octet-stream`,
`application/zip`). When `Content-Type` implies a text charset (e.g. `text/html; charset=utf-8`),
`.Content` is a lossily decoded `[string]`, even for a binary body. Invalid bytes become U+FFFD, and no
re-encoding (Latin-1 included) recovers them. `.RawContentStream` (a `MemoryStream`) held the exact
original bytes in every test. psPAS's `Get-PASResponse.ps1` relies on `.Content`'s runtime type alone, with
no `RawContentStream` fallback.

**Rule:** decide by the headers, not by whether `ConvertFrom-Json` throws. Read `RawContentStream`
whenever `Content-Type` can't be trusted. A `Content-Disposition` header on a non-JSON response is that
signal. When you change a shared function this way, check every caller. For this fix, no module depended
on the old `Binary` shape, and every test mock had to gain a `Headers` property.

```powershell
if ($response.Content -is [byte[]]) { $bytes = $response.Content }
elseif ($contentDisposition -and $contentType -notmatch '(?i)application/json') {
    $ms = $response.RawContentStream; $ms.Position = 0
    $bytes = New-Object byte[] $ms.Length; $ms.Read($bytes, 0, $ms.Length) | Out-Null
}
```
