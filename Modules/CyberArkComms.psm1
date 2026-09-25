#Requires -Version 5.1
<#
.SYNOPSIS
    Shared REST communications module for CyberArk PAS Scripts.

.DESCRIPTION
    Provides Invoke-CyberArkAPI and supporting helpers used by all API modules and the driver.
    Handles:
      - HTTP request execution with proper headers from the token object
      - Transparent pagination (all pages fetched and combined)
      - Rate limiting with exponential backoff (HTTP 429)
      - WhatIf blocking (POST/PUT/PATCH/DELETE suppressed; synthetic success returned)
      - Response normalization into a standard API response object
      - URL joining and CyberArk query string building
      - IgnoreSSL bypass, re-asserted correctly on every call from the active profile's own
        setting - process-wide once applied (a .NET Framework/PS 5.1 limitation, not scoped per
        call), but never left silently active after switching to a profile that doesn't want it
#>

Set-StrictMode -Version Latest

#region --- Module State ---

$script:MaxRateLimitRetries  = 5
$script:RateLimitBaseDelaySec = 2

# HTTP 504 Gateway Timeout retry - fixed delay (not exponential backoff like 429),
# and the page size is reduced by 25% on each retry when pagination is in use.
$script:MaxGatewayTimeoutRetries = 2
$script:GatewayTimeoutDelaySec   = 5

# Windows PowerShell 5.1's Invoke-WebRequest/Invoke-RestMethod (built on the .NET Framework
# HttpWebRequest stack) send an "Expect: 100-continue" header by default on every POST/PUT/PATCH
# request that has a body. Confirmed live: CyberArk's ISPSS rotation microservice (SRS, fronting
# Accounts/ChangeImmediate and likely Reconcile/Verify) does not handle this correctly, and the
# request hangs indefinitely under PS 5.1 instead of failing fast - the identical call completes
# in under a second under PowerShell 7, whose Invoke-WebRequest is HttpClient-based and never
# sends this header. Set once, process-wide, unconditionally (there's no scenario where this
# codebase wants the header) - PS7's HttpClient ignores ServicePointManager entirely, so this is
# a harmless no-op there. See Testing_Plan.md K16.
[System.Net.ServicePointManager]::Expect100Continue = $false

#endregion

#region --- Internal Helpers ---

function script:Get-StatusMessage {
    param([int]$Code)
    $map = @{
        200 = 'OK'; 201 = 'Created'; 202 = 'Accepted'; 204 = 'No Content'
        400 = 'Bad Request'; 401 = 'Unauthorized'; 403 = 'Forbidden'
        404 = 'Not Found'; 405 = 'Method Not Allowed'; 408 = 'Request Timeout'
        409 = 'Conflict'; 429 = 'Too Many Requests'
        500 = 'Internal Server Error'; 502 = 'Bad Gateway'; 503 = 'Service Unavailable'
        504 = 'Gateway Timeout'
    }
    if ($map.ContainsKey($Code)) { return $map[$Code] } else { return "HTTP $Code" }
}

function script:New-ApiResponse {
    param(
        [bool]  $IsSuccess,
        [int]   $StatusCode,
        [string]$RawResponse  = '',
        [object]$Data         = $null,
        [string]$DataType     = 'Empty',
        [string]$ErrorMessage = $null,
        [object]$ErrorDetails = $null,

        # Filename suggested by the response's Content-Disposition header (e.g. an exported
        # platform's .zip name) - populated only for DataType='File' responses. $null otherwise.
        [string]$SuggestedFileName = $null
    )
    return [PSCustomObject]@{
        IsSuccess          = $IsSuccess
        StatusCode         = $StatusCode
        StatusMessage      = script:Get-StatusMessage -Code $StatusCode
        ErrorMessage       = $ErrorMessage
        ErrorDetails       = $ErrorDetails
        Data               = $Data
        RawResponse        = $RawResponse
        DataType           = $DataType
        SuggestedFileName  = $SuggestedFileName
    }
}

function script:Format-CyberArkErrorMessage {
    <#
        Single place both Invoke-CyberArkAPI error-response branches build their ErrorMessage
        from, so every module's own displayed/logged error text stays consistent with no
        per-module changes needed. Preference order, per user direction: the CyberArk
        "<ErrorCode>: <ErrorMessage>" envelope when both are present; the bare ErrorMessage when
        only that parsed; the raw response body when structured parsing found neither but the
        server still sent content; and only then the generic HTTP-status fallback text.
    #>
    param(
        [object]$ErrorDetails,
        [int]   $StatusCode,
        [string]$RawBody,
        [string]$FallbackMessage
    )
    if ($ErrorDetails -and $ErrorDetails.ErrorCode) {
        return "$($ErrorDetails.ErrorCode): $($ErrorDetails.ErrorMessage)"
    }
    if ($ErrorDetails -and $ErrorDetails.ErrorMessage) {
        return $ErrorDetails.ErrorMessage
    }
    if ($RawBody -and $RawBody.Trim()) {
        return "HTTP $StatusCode - $RawBody"
    }
    return $FallbackMessage
}

function script:Parse-CyberArkError {
    param([string]$Body)
    if (-not $Body) { return $null }
    try {
        $parsed = $Body | ConvertFrom-Json
        # PSObject.Properties guards, not direct dot access: this module runs under its own
        # Set-StrictMode, and a body with only one of these two fields (e.g. {"ErrorMessage":
        # "Not Found"} with no ErrorCode) would otherwise throw PropertyNotFoundException on
        # the missing one - discarding the field that WAS present too, since the whole object
        # literal fails to construct.
        return [PSCustomObject]@{
            ErrorCode    = if ($parsed.PSObject.Properties['ErrorCode'])    { $parsed.ErrorCode }    else { $null }
            ErrorMessage = if ($parsed.PSObject.Properties['ErrorMessage']) { $parsed.ErrorMessage } else { $null }
            Details      = $parsed
        }
    } catch {
        return $null
    }
}

function script:Find-CyberArkCollectionProperty {
    <#
        Returns the name of the property on a paginated CyberArk JSON response that holds the
        collection of items, or $null if none is found. Tries a short list of names CyberArk
        consistently uses across today's pageable endpoints first (value, Safes, Members,
        Accounts, Users, Platforms, Groups) - this preserves exact existing behavior for every
        endpoint already in use. If none of those are present, falls back to the first property
        whose value is an array, so a future endpoint whose response uses a collection name not
        anticipated here still paginates correctly instead of silently returning only its first
        page. Same generalization psPAS's Get-NextLink.ps1 falls back to when it doesn't
        recognize a response's known property names (value/items) either.
    #>
    param([Parameter(Mandatory = $true)] $Data)

    foreach ($prop in @('value', 'Safes', 'Members', 'Accounts', 'Users', 'Platforms', 'Groups')) {
        if ($Data.PSObject.Properties[$prop]) { return $prop }
    }

    foreach ($p in $Data.PSObject.Properties) {
        if ($p.Value -is [array]) { return $p.Name }
    }

    return $null
}

function script:New-WhatIfResponse {
    param([string]$Method, [string]$Uri)
    $msg = "[WhatIf] $Method $Uri - request suppressed, no changes made."
    if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
        Write-CyberArkLog -Message $msg -Level 'INFO' -FunctionName 'Invoke-CyberArkAPI'
    }
    return script:New-ApiResponse -IsSuccess $true -StatusCode 200 -DataType 'Empty' `
        -RawResponse '' -Data $null
}


# Tracks whether Disable-SSLValidation has actually been called this session, so
# Reset-SSLValidation (and any caller checking before deciding whether to reset) doesn't need to
# inspect ServicePointManager.CertificatePolicy's runtime type to know the current state - see
# Testing_Plan.md K02.
$script:SSLValidationDisabled = $false

function script:Disable-SSLValidation {
    # Only effective within the current AppDomain - there is no way to scope this to a single
    # call/request/profile in Windows PowerShell 5.1 (.NET Framework's ServicePointManager is a
    # process-wide static with no per-HttpWebRequest override). Resetting it back to the default
    # policy IS possible, though, and is exactly what Reset-SSLValidation below does - see
    # Testing_Plan.md K02 (previously this was never reset at all, so switching from an
    # IgnoreSSL=$true profile to a different one left the bypass silently active for the rest of
    # the process's life).
    # Exported (not just used internally by Invoke-CyberArkAPI) so Invoke-CustomTestApi.ps1 -
    # which calls Invoke-WebRequest directly instead of going through Invoke-CyberArkAPI - can
    # reuse this same safe, compiled-class-based bypass instead of assigning a raw PowerShell
    # scriptblock to ServerCertificateValidationCallback, which risks a silent, uncatchable
    # process crash if .NET ever invokes that delegate off the runspace's own thread (e.g.
    # during a fresh TLS handshake triggered by a mid-session re-authentication request).
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
        Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint sp, X509Certificate cert,
        WebRequest req, int error) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
    [System.Net.ServicePointManager]::SecurityProtocol  =
        [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
    $script:SSLValidationDisabled = $true
}

function script:Reset-SSLValidation {
    <#
        Restores the default (real) certificate validation policy - the other half of the K02
        fix. A no-op if Disable-SSLValidation was never called, so callers can invoke this
        unconditionally without needing to track state themselves. Exported for the same reason
        Disable-SSLValidation is - Invoke-CustomTestApi.ps1 and the Auth modules' own raw HTTP
        calls (Invoke-PVWALogon, Get-PVWASessionTimeoutMinutes) need the same "always assert the
        correct current state" pattern Invoke-CyberArkAPI below now uses.
    #>
    if (-not $script:SSLValidationDisabled) { return }
    [System.Net.ServicePointManager]::CertificatePolicy = $null
    $script:SSLValidationDisabled = $false
}

#endregion

#region --- Query Helpers ---

function New-CyberArkQuery {
    <#
    .SYNOPSIS
        Builds a URL query string from a hashtable of CyberArk query parameters.
    .PARAMETER Params
        Hashtable of parameter names and values. Null/empty values are omitted.
    .OUTPUTS
        String - a query string including the leading '?' or empty string if no params.
    .EXAMPLE
        New-CyberArkQuery @{ search = 'vault'; filter = 'safeName eq MyVault'; limit = 25 }
        # Returns: ?search=vault&filter=safeName+eq+MyVault&limit=25
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Params
    )

    $parts = foreach ($key in $Params.Keys) {
        $val = $Params[$key]
        if ($null -ne $val -and "$val" -ne '') {
            $encodedVal = [Uri]::EscapeDataString("$val")
            # CyberArk's ?search= endpoints require a literal period in the search term to be
            # percent-encoded as %2E to match correctly - confirmed live by the user.
            # [Uri]::EscapeDataString treats '.' as an unreserved character per RFC 3986 and
            # leaves it as a literal period, which these endpoints then fail to match on.
            # Matched case-insensitively: some callers use 'search' (e.g. CancelCpmTask,
            # LinkAccount), others 'Search' (Invoke-EntitySearch's interactive picker, via
            # -SearchParam 'Search' in the Platforms modules).
            if ($key -ieq 'search') { $encodedVal = $encodedVal.Replace('.', '%2E') }
            "$([Uri]::EscapeDataString($key))=$encodedVal"
        }
    }

    $joined = $parts -join '&'
    if ($joined) { return "?$joined" } else { return '' }
}

function Join-CyberArkUrl {
    <#
    .SYNOPSIS
        Joins a base URL and one or more path segments with correct slash handling.
    .PARAMETER Base
        The base URL (e.g. 'https://cyberark.example.com').
    .PARAMETER Segments
        One or more path segments to append (leading and trailing slashes are trimmed).
    .EXAMPLE
        Join-CyberArkUrl -Base 'https://host.example.com/' -Segments '/API/', '/Safes'
        # Returns: https://host.example.com/API/Safes
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Base,

        [Parameter(Mandatory = $true)]
        [string[]]$Segments
    )

    $result = $Base.TrimEnd('/')
    foreach ($seg in $Segments) {
        $result = $result.TrimEnd('/') + '/' + $seg.Trim('/')
    }
    # A dot in the last path segment is misread as a file extension by some proxies/servers.
    # Appending a trailing slash signals it is a path, not a file.
    if ($result.Split('/')[-1] -match '\.') { $result += '/' }
    return $result
}

function New-CyberArkSearchFilter {
    <#
    .SYNOPSIS
        Builds a CyberArk filter expression string from simple key=value pairs.
    .PARAMETER Criteria
        Hashtable of field names and values. Values containing spaces are quoted.
    .PARAMETER Operator
        Logical operator joining multiple criteria. Default: 'AND'.
    .EXAMPLE
        New-CyberArkSearchFilter @{ safeName = 'MyVault'; userName = 'svc-account' }
        # Returns: safeName eq MyVault AND userName eq svc-account
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Criteria,

        [string]$Operator = 'AND'
    )

    $parts = foreach ($key in $Criteria.Keys) {
        $val = $Criteria[$key]
        if ($val -match '\s') { $val = "`"$val`"" }
        "$key eq $val"
    }
    return $parts -join " $Operator "
}

#endregion

#region --- Core API Function ---

function Invoke-CyberArkAPI {
    <#
    .SYNOPSIS
        Executes a CyberArk REST API call and returns a normalized response object.

    .DESCRIPTION
        Handles:
          - Header injection from the Token object
          - JSON body serialization
          - WhatIf suppression (POST/PUT/PATCH/DELETE)
          - Transparent pagination (fetches all pages, returns combined value array)
          - Rate limiting with exponential backoff
          - IgnoreSSL bypass
          - Response normalization into the standard API response shape

    .PARAMETER Token
        The token object from Get-AuthToken. Provides Headers and BaseURL.

    .PARAMETER Method
        HTTP method: GET, POST, PUT, PATCH, DELETE. Default: GET.

    .PARAMETER Endpoint
        Relative path from BaseURL (e.g. '/API/Safes'). Leading slash is optional.

    .PARAMETER Uri
        Full absolute URI. Use instead of Endpoint when the URL is already fully built.

    .PARAMETER Body
        Request body. Hashtable/PSCustomObject is serialized to JSON automatically.
        String values are sent as-is.

    .PARAMETER QueryParams
        Hashtable of query parameters. Appended to the URL.

    .PARAMETER WhatIf
        Suppresses POST/PUT/PATCH/DELETE calls. Returns a synthetic 200 success response.

    .PARAMETER IgnoreSSL
        Bypasses SSL certificate validation. Should match the profile setting.

    .PARAMETER PageSizeParam
        Query parameter name used to set the page size (e.g. 'limit'). Default: 'limit'.

    .PARAMETER PageOffsetParam
        Query parameter name used to set the page offset (e.g. 'offset'). Default: 'offset'.

    .PARAMETER PageSize
        Number of items per page. Default: 1000. Set to 0 to disable pagination.

    .OUTPUTS
        PSCustomObject - standard API response object (see Reference_Interfaces.md).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token,

        [ValidateSet('GET','POST','PUT','PATCH','DELETE')]
        [string]$Method = 'GET',

        [string]$Endpoint,
        [string]$Uri,

        [object]$Body,

        [hashtable]$QueryParams,

        [switch]$WhatIf,

        [switch]$IgnoreSSL,

        [string]$PageSizeParam   = 'limit',
        [string]$PageOffsetParam = 'offset',
        [int]   $PageSize        = 1000
    )

    # --- Resolve full URI ---
    if (-not $Uri) {
        if (-not $Endpoint) { throw "Either -Endpoint or -Uri must be supplied." }
        $Uri = Join-CyberArkUrl -Base $Token.BaseURL -Segments @($Endpoint)
        # Join-CyberArkUrl always trims a trailing slash off the joined result (by design -
        # see CyberArkComms.Tests.ps1 C12). Some endpoints require the trailing slash to be
        # preserved (the legacy PIMServices.svc WCF REST service used by every Applications
        # module rejects/misroutes requests without it - see Reference_Lessons-Learned.md
        # Section 28/Documentation-Tracker.md 2026-08-16 for the history of this exact endpoint
        # losing its trailing slash). Restore it here, at the call site, based on the caller's
        # own explicit -Endpoint string, rather than changing Join-CyberArkUrl's generic contract.
        if ($Endpoint.EndsWith('/') -and -not $Uri.EndsWith('/')) { $Uri += '/' }
    }

    # --- WhatIf blocking ---
    if ($WhatIf -and $Method -in 'POST','PUT','PATCH','DELETE') {
        return script:New-WhatIfResponse -Method $Method -Uri $Uri
    }

    # --- SSL bypass (session-wide once applied - see Testing_Plan.md K02) ---
    # Every call re-asserts the correct state for its own -IgnoreSSL value, rather than only
    # ever turning the bypass on and never off: this is what actually closes K02, since each
    # call site already passes its own active profile's IgnoreSSL value (e.g.
    # -IgnoreSSL:$selectedProfile.IgnoreSSL), so switching to a profile with IgnoreSSL=$false
    # now resets validation on its very first API call instead of leaving a previous profile's
    # bypass silently active for the rest of the process's life.
    if ($IgnoreSSL) {
        script:Disable-SSLValidation
    } elseif ($script:SSLValidationDisabled) {
        script:Reset-SSLValidation
    }

    # --- Build headers ---
    $headers = @{}
    foreach ($key in $Token.Headers.Keys) { $headers[$key] = $Token.Headers[$key] }

    # --- Serialize body ---
    # ConvertTo-Json must receive $Body via -InputObject, not the pipeline: piping a single-
    # element array unrolls it to its lone element first, so ConvertTo-Json serializes that
    # element bare instead of wrapping it in `[ ]` - silently corrupting single-op JSON Patch
    # bodies (and any other single-element array body) into a bare object.
    $bodyString = $null
    if ($Body) {
        $bodyString = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 20 -Compress }
    }

    # --- Profile page size override (PageSize on token, 0 = use parameter default) ---
    # Controls records requested per paginated call only — does not cap total results.
    $profilePageSize   = 0
    if ($Token.PSObject.Properties['PageSize']) {
        try { $profilePageSize = [int]$Token.PageSize } catch { }
    }
    $effectivePageSize = if ($profilePageSize -gt 0) { $profilePageSize } else { $PageSize }

    # --- Pagination state ---
    $allItems      = [System.Collections.Generic.List[object]]::new()
    # PIMServices.svc (legacy WCF REST) does not accept offset/limit pagination params
    $paginate      = ($Method -eq 'GET' -and $effectivePageSize -gt 0 -and $Uri -notlike '*/PIMServices.svc/*')
    $offset        = 0
    $firstPage     = $true
    $lastResponse  = $null
    $pageNum       = 1
    $progressShown = $false

    # --- Rate limit / retry state ---
    $retryCount             = 0
    $gatewayTimeoutRetryCount = 0

    do {
        # Build query string for this page
        $qParams = if ($QueryParams) { [hashtable]$QueryParams.Clone() } else { @{} }
        if ($paginate) {
            $qParams[$PageSizeParam]   = $effectivePageSize
            $qParams[$PageOffsetParam] = $offset
        }
        $query   = New-CyberArkQuery -Params $qParams
        $fullUri = "$Uri$query"

        if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
            Write-CyberArkLog -Message "$Method $fullUri" -Level 'DEBUG' -FunctionName 'Invoke-CyberArkAPI'
            if ($bodyString -and $Method -in 'POST','PUT','PATCH') {
                Write-CyberArkLog -Message "Request body: $bodyString" -Level 'DEBUG' -FunctionName 'Invoke-CyberArkAPI' -FileOnly
            }
        }

        # --- Execute request ---
        try {
            $iwrParams = @{
                Uri             = $fullUri
                Method          = $Method
                Headers         = $headers
                UseBasicParsing = $true
                ErrorAction     = 'Stop'
            }
            if ($bodyString) {
                # Encode as raw UTF8 bytes rather than a String so PowerShell's own
                # ParameterBinding/module logging (e.g. GPO-enabled Module Logging / Script
                # Block Logging) records a non-revealing System.Byte[] type name instead of the
                # literal JSON content - which for many callers includes plaintext account
                # passwords, CPM NewCredentials, or safe-member permission bodies. Mirrors
                # psPAS's Invoke-PASRestMethod.ps1.
                $iwrParams['Body']        = [System.Text.Encoding]::UTF8.GetBytes($bodyString)
                $iwrParams['ContentType'] = 'application/json'
            }

            $response    = Invoke-WebRequest @iwrParams
            $retryCount  = 0   # reset on success
            $gatewayTimeoutRetryCount = 0
            $statusCode  = [int]$response.StatusCode

            # --- Determine response body shape from the actual response headers, not by
            # guessing from success/failure of a JSON parse attempt ---
            $respContentType        = if ($response.Headers.ContainsKey('Content-Type'))        { "$($response.Headers['Content-Type'])" }        else { '' }
            $respContentDisposition = if ($response.Headers.ContainsKey('Content-Disposition')) { "$($response.Headers['Content-Disposition'])" } else { '' }

            $rawBody     = $null
            $binaryBytes = $null

            if ($response.Content -is [byte[]]) {
                # Invoke-WebRequest already determined this response is non-textual (e.g.
                # Content-Type: application/octet-stream or application/zip) - .Content is
                # already the exact original bytes here, confirmed live (see
                # Reference_Lessons-Learned.md Section 39).
                $binaryBytes = $response.Content
            } elseif ($respContentDisposition -and $respContentType -notmatch '(?i)application/json') {
                # A Content-Disposition header (a file-attachment marker) on a non-JSON response
                # means this is a file even though Invoke-WebRequest decoded .Content as a string
                # - e.g. an endpoint that mislabels a file as text/html. Reading .Content in this
                # case would silently and irreversibly corrupt the bytes (confirmed live: a
                # charset-implied text decoding cannot be undone). RawContentStream always holds
                # the untouched original bytes regardless of what Content-Type claims.
                $ms          = $response.RawContentStream
                $ms.Position = 0
                $binaryBytes = New-Object byte[] $ms.Length
                $ms.Read($binaryBytes, 0, $ms.Length) | Out-Null
            } else {
                $rawBody = $response.Content
            }

        } catch [System.Net.WebException] {
            $webEx      = $_.Exception
            $webResp    = $webEx.Response -as [System.Net.HttpWebResponse]
            $statusCode = if ($webResp) { [int]$webResp.StatusCode } else { 0 }
            $rawBody    = ''
            if ($webResp) {
                try {
                    $reader  = [System.IO.StreamReader]::new($webResp.GetResponseStream())
                    $rawBody = $reader.ReadToEnd()
                    $reader.Dispose()
                } catch {}
            }

            # --- Rate limiting ---
            if ($statusCode -eq 429) {
                $retryCount++
                if ($retryCount -gt $script:MaxRateLimitRetries) {
                    $msg = "Rate limit exceeded after $($script:MaxRateLimitRetries) retries. Giving up."
                    if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
                        Write-CyberArkLog -Message $msg -Level 'ERROR' -FunctionName 'Invoke-CyberArkAPI'
                    }
                    if ($progressShown) { Write-Progress -Activity 'Fetching results' -Completed -Id 1 }
                    return script:New-ApiResponse -IsSuccess $false -StatusCode 429 `
                        -RawResponse $rawBody -ErrorMessage $msg
                }

                $delaySec = $script:RateLimitBaseDelaySec * [Math]::Pow(2, $retryCount - 1)
                $warnMsg  = "HTTP 429 rate limit (attempt $retryCount/$($script:MaxRateLimitRetries)). Backing off $([int]$delaySec)s..."
                if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
                    Write-CyberArkLog -Message $warnMsg -Level 'WARN' -FunctionName 'Invoke-CyberArkAPI'
                }
                Start-Sleep -Seconds ([int]$delaySec)
                continue
            }

            # --- Gateway timeout retry ---
            if ($statusCode -eq 504) {
                $gatewayTimeoutRetryCount++
                if ($gatewayTimeoutRetryCount -gt $script:MaxGatewayTimeoutRetries) {
                    $msg = "Gateway timeout (504) persisted after $($script:MaxGatewayTimeoutRetries) retries. Giving up."
                    if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
                        Write-CyberArkLog -Message $msg -Level 'ERROR' -FunctionName 'Invoke-CyberArkAPI'
                    }
                    if ($progressShown) { Write-Progress -Activity 'Fetching results' -Completed -Id 1 }
                    return script:New-ApiResponse -IsSuccess $false -StatusCode 504 `
                        -RawResponse $rawBody -ErrorMessage $msg
                }

                # If a page-size limit is in use for this call, reduce it by 25% before retrying -
                # a smaller page is less likely to time out again. Same $offset is retried (this
                # page never succeeded), so no items are skipped or duplicated.
                if ($paginate -and $effectivePageSize -gt 1) {
                    $reducedPageSize = [int][Math]::Floor($effectivePageSize * 0.75)
                    if ($reducedPageSize -lt 1) { $reducedPageSize = 1 }
                    $warnMsg = "HTTP 504 gateway timeout (attempt $gatewayTimeoutRetryCount/$($script:MaxGatewayTimeoutRetries)). Reducing page size $effectivePageSize -> $reducedPageSize and retrying in $($script:GatewayTimeoutDelaySec)s..."
                    $effectivePageSize = $reducedPageSize
                } else {
                    $warnMsg = "HTTP 504 gateway timeout (attempt $gatewayTimeoutRetryCount/$($script:MaxGatewayTimeoutRetries)). Retrying in $($script:GatewayTimeoutDelaySec)s..."
                }
                if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
                    Write-CyberArkLog -Message $warnMsg -Level 'WARN' -FunctionName 'Invoke-CyberArkAPI'
                }
                Start-Sleep -Seconds $script:GatewayTimeoutDelaySec
                continue
            }

            # Non-429/504 HTTP error - fall through to response building below
            $errDetails = script:Parse-CyberArkError -Body $rawBody
            $errMsg     = script:Format-CyberArkErrorMessage -ErrorDetails $errDetails -StatusCode $statusCode `
                -RawBody $rawBody -FallbackMessage "HTTP $statusCode $($webEx.Message)"
            if ($statusCode -ge 400) { $errMsg = "$errMsg  [$Method $fullUri]" }
            if ($rawBody -and (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue)) {
                Write-CyberArkLog -Message "HTTP $statusCode response body: $rawBody" -Level 'DEBUG' -FunctionName 'Invoke-CyberArkAPI' -FileOnly
            }
            if ($progressShown) { Write-Progress -Activity 'Fetching results' -Completed -Id 1 }
            return script:New-ApiResponse -IsSuccess $false -StatusCode $statusCode `
                -RawResponse $rawBody -ErrorMessage $errMsg -ErrorDetails $errDetails

        } catch {
            $caughtErr = $_
            $msg = "Unexpected error calling $fullUri : $caughtErr"
            if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
                Write-CyberArkLog -Message $msg -Level 'ERROR' -FunctionName 'Invoke-CyberArkAPI'
            }
            if ($progressShown) { Write-Progress -Activity 'Fetching results' -Completed -Id 1 }
            return script:New-ApiResponse -IsSuccess $false -StatusCode 0 -ErrorMessage $msg
        }

        # --- Parse response body ---
        $dataType         = 'Empty'
        $data             = $null
        $suggestedFileName = $null

        if ($binaryBytes) {
            $dataType = 'File'
            $data     = $binaryBytes
            if ($respContentDisposition -match 'filename\*?=\"?([^\";]+)\"?') { $suggestedFileName = $Matches[1] }
        } elseif ($rawBody) {
            try {
                $data     = $rawBody | ConvertFrom-Json
                $dataType = 'JSON'
            } catch {
                # Not valid JSON and not identified as a file above - keep the raw text as-is.
                $data     = $rawBody
                $dataType = 'Binary'
            }
        }

        $isSuccess = ($statusCode -ge 200 -and $statusCode -le 299)

        # --- Accumulate paginated items --- (never true for a File response: paginate itself is
        # already GET-only and this endpoint class is POST-only today, but guarded explicitly
        # for clarity/future-proofing rather than relying on that incidentally)
        if ($paginate -and $isSuccess -and $data -and $dataType -ne 'File') {
            # CyberArk typically returns { value: [...], count: N, nextLink: "..." }
            # or { Safes: [...] } etc. Find-CyberArkCollectionProperty tries common collection
            # property names first, then falls back to the first array-valued property so an
            # endpoint using an unanticipated collection name still paginates correctly.
            $collection     = $null
            $collectionProp = script:Find-CyberArkCollectionProperty -Data $data
            if ($collectionProp) { $collection = $data.$collectionProp }

            if ($null -ne $collection) {
                foreach ($item in $collection) { $allItems.Add($item) }

                # Check for nextLink (ISPSS uses OData-style pagination)
                $hasNextLink    = $data.PSObject.Properties['nextLink'] -and $data.nextLink
                # Also check count-based: if we got a full page, there may be more
                $hasMoreByCount = ($collection.Count -eq $effectivePageSize)

                if ($hasNextLink -or $hasMoreByCount) {
                    $offset   += $effectivePageSize
                    $firstPage = $false
                    $pageNum++
                    Write-Progress -Activity 'Fetching results' -Status "Page $pageNum — $($allItems.Count) items retrieved" -Id 1
                    $progressShown = $true
                    $lastResponse = [PSCustomObject]@{
                        IsSuccess = $isSuccess; StatusCode = $statusCode; RawResponse = $rawBody
                        Data = $data; DataType = $dataType
                    }
                    continue
                }
            }
        }

        # --- Single-page or final page - build the response ---
        if ($paginate -and $allItems.Count -gt 0) {
            # Merge all accumulated items back onto the last data object - detected fresh here
            # (not reusing $collectionProp above) so this doesn't depend on which loop iteration
            # last populated it.
            $mergedData = if ($null -ne $data) { $data } else { [PSCustomObject]@{} }
            $mergeProp  = script:Find-CyberArkCollectionProperty -Data $mergedData
            if ($mergeProp) { $mergedData.$mergeProp = $allItems.ToArray() }
            $data = $mergedData
        }

        if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
            $itemsNote = if ($allItems.Count -gt 0) { "$($allItems.Count) total items (paginated)" } else { $dataType }
            $logMsg = "Response $statusCode - $itemsNote"
            Write-CyberArkLog -Message $logMsg -Level 'DEBUG' -FunctionName 'Invoke-CyberArkAPI'
        }

        $errDetails = $null
        $errMsg     = $null
        if (-not $isSuccess) {
            $errDetails = script:Parse-CyberArkError -Body $rawBody
            $errMsg     = script:Format-CyberArkErrorMessage -ErrorDetails $errDetails -StatusCode $statusCode `
                -RawBody $rawBody -FallbackMessage "HTTP $statusCode"
        }

        if ($progressShown) { Write-Progress -Activity 'Fetching results' -Completed -Id 1 }
        return script:New-ApiResponse -IsSuccess $isSuccess -StatusCode $statusCode `
            -RawResponse $rawBody -Data $data -DataType $dataType `
            -ErrorMessage $errMsg -ErrorDetails $errDetails -SuggestedFileName $suggestedFileName

    } while ($true)
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-CyberArkAPI'
    'New-CyberArkQuery'
    'Join-CyberArkUrl'
    'New-CyberArkSearchFilter'
    'Disable-SSLValidation'
    'Reset-SSLValidation'
)
