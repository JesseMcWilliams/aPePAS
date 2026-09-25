#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Test API'
    Category         = 'Custom'
    Action           = 'TestApi'
    Description      = 'Send raw requests to the CyberArk API and inspect request and response details.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $false
    InputSchema      = @()
    Priority         = 95
    # Its entire request (method/path/headers/body) is built via an interactive Read-Host/
    # Show-FieldPrompt loop inside Invoke-CustomTestApi itself - InputData is never consulted.
    # There is no non-interactive path at all, so automation mode rejects it up front rather
    # than risking an indefinite prompt in a console-less host. See
    # Claude_Docs\Reference_API-Module-Guide.md for this ModuleMeta flag.
    SupportsAutomation = $false
    Version          = '1.5.1'   # 1.5.1 merged forward a fix from the develop branch: 401 retry was not
                                  # actually re-authenticating, since Invoke-TokenRefresh short-circuits
                                  # when Test-TokenExpiry still reports the token locally Valid/Warning,
                                  # which it did here since a server-side 401 doesn't move the local
                                  # expiry clock - now calls Invoke-TokenInvalidate first
}

function Invoke-CustomTestApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$InputData,
        [Parameter(Mandatory = $false)] [switch]$WhatIf
    )

    $result = [PSCustomObject]@{
        ModuleName     = $ModuleMeta.Name
        Category       = $ModuleMeta.Category
        Action         = $ModuleMeta.Action
        ItemsProcessed = 0
        Successes      = 0
        Failures       = 0
        IsFatal        = $false
        Results        = [System.Collections.Generic.List[PSCustomObject]]::new()
        Errors         = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    $bodyMethods    = @('POST', 'PUT', 'PATCH')
    $allRuns        = [System.Collections.Generic.List[PSCustomObject]]::new()
    $verbose        = $false
    $retryRequest   = $false
    $method         = 'GET'
    $cleanPath      = ''
    $queryString    = ''
    $fullUri        = ''

    # Reuses CyberArkComms.psm1's Disable-SSLValidation (a compiled ICertificatePolicy class)
    # instead of assigning a raw PowerShell scriptblock to ServerCertificateValidationCallback.
    # The latter used to be this module's own approach and is a known hazard: if .NET's TLS
    # stack ever invokes that delegate off the runspace's own thread - plausible for a fresh
    # handshake triggered by the re-authentication request below - it can crash the whole
    # process silently, with no catchable exception. Every other module already avoids this via
    # Invoke-CyberArkAPI's -IgnoreSSL switch; this module can't use that (it calls
    # Invoke-WebRequest directly to reach arbitrary methods/paths) but can call the same
    # underlying helper directly.
    $ignoreSSL = $script:ActiveProfile.PSObject.Properties['IgnoreSSL'] -and [bool]$script:ActiveProfile.IgnoreSSL
    if ($ignoreSSL) {
        Disable-SSLValidation
    }

    # Strip the trailing /PasswordVault segment from the token's BaseURL - every other
    # module needs it (PVWA's PasswordVault-scoped REST API), but Test API is meant to let
    # an admin poke at any endpoint on the host, and a lot of the host's API surface (e.g.
    # ISPSS Identity/platform-discovery-adjacent endpoints, PVWA endpoints outside the
    # PasswordVault app) lives outside that path. -Endpoint below still supplies the full
    # path from root, so this only widens what's reachable - it doesn't change how any
    # other module builds its own requests.
    $baseUrl = $Token.BaseURL.TrimEnd('/') -replace '(?i)/PasswordVault$', ''

    Write-Host '  Base URL : ' -ForegroundColor DarkGray -NoNewline
    Write-Host $baseUrl -ForegroundColor Cyan
    Write-Host ''

    while ($true) {

        Write-Host ('  ' + ('-' * 70)) -ForegroundColor DarkGray
        $verboseLabel = if ($verbose) { 'ON ' } else { 'OFF' }
        Write-Host "  Verbose headers: $verboseLabel   ([V] to toggle)" -ForegroundColor DarkGray
        Write-Host ''

        if (-not $retryRequest) {
            # --- Method ---
            Write-Host '  Method:' -ForegroundColor DarkGray
            Write-Host '    [1] GET    [2] POST    [3] PUT    [4] PATCH    [5] DELETE' -ForegroundColor White
            Write-Host ''
            $methodInput = Read-Host '  Select (1-5, or type method name, default=GET)'
            $method = switch ($methodInput.Trim().ToUpper()) {
                '2'      { 'POST'   }
                '3'      { 'PUT'    }
                '4'      { 'PATCH'  }
                '5'      { 'DELETE' }
                'POST'   { 'POST'   }
                'PUT'    { 'PUT'    }
                'PATCH'  { 'PATCH'  }
                'DELETE' { 'DELETE' }
                default  { 'GET'    }
            }

            # --- API Path ---
            $apiPath = Show-FieldPrompt -Label 'API Path' -Required
            if (-not $apiPath) { continue }
            $cleanPath = if ($apiPath.Trim().StartsWith('/')) { $apiPath.Trim() } else { "/$($apiPath.Trim())" }

            # --- Query Params (GET only, per user request) ---
            $queryString = if ($method -eq 'GET') {
                Show-FieldPrompt -Label 'Query Params' `
                    -Description 'Optional: key=value&key2=value2  (leave blank for none)'
            } else { '' }
        } else {
            Write-Host "  Reusing: $method $cleanPath" -ForegroundColor DarkGray
            if ($queryString -and $queryString.Trim()) {
                Write-Host "  Query  : $($queryString.Trim())" -ForegroundColor DarkGray
            }
            Write-Host ''
        }
        $retryRequest = $false

        # --- Body ---
        $bodyString = $null
        if ($method -in $bodyMethods) {
            $bodyInput = Show-FieldPrompt -Label 'Body (JSON)' `
                -Description "Single-line JSON body for $method. Leave blank for no body."
            if ($bodyInput -and $bodyInput.Trim()) {
                try {
                    $bodyObj    = $bodyInput | ConvertFrom-Json
                    $bodyString = $bodyObj | ConvertTo-Json -Depth 20 -Compress
                } catch {
                    Write-Host '  Warning: body is not valid JSON - sending as-is.' -ForegroundColor Yellow
                    $bodyString = $bodyInput.Trim()
                }
            }
        }

        # --- Build full URI ---
        $fullUri = $baseUrl + $cleanPath
        if ($cleanPath.TrimEnd('/').Split('/')[-1] -match '\.') { $fullUri += '/' }
        if ($queryString -and $queryString.Trim()) {
            $sep     = if ($fullUri -match '\?') { '&' } else { '?' }
            $fullUri = "$fullUri$sep$($queryString.Trim())"
        }

        # Build headers from current token for verbose display (rebuilt inside loop on retry)
        $reqHeaders = @{}
        foreach ($key in $Token.Headers.Keys) { $reqHeaders[$key] = $Token.Headers[$key] }

        Write-Host ''
        Write-Host "  --> $method $fullUri" -ForegroundColor Cyan

        # --- Verbose: show request headers and body before sending ---
        if ($verbose) {
            Write-Host ''
            Write-Host '  Request Headers:' -ForegroundColor DarkCyan
            foreach ($key in ($reqHeaders.Keys | Sort-Object)) {
                $val = if ($key -imatch 'authoriz|bearer|token|apikey|secret|password') {
                    "$($reqHeaders[$key].Substring(0, [Math]::Min(8, $reqHeaders[$key].Length)))***"
                } else { $reqHeaders[$key] }
                Write-Host "    $($key): $val" -ForegroundColor DarkGray
            }
            if ($bodyString) {
                Write-Host ''
                Write-Host '  Request Body:' -ForegroundColor DarkCyan
                try {
                    ($bodyString | ConvertFrom-Json | ConvertTo-Json -Depth 20).Split("`n") |
                        ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                } catch {
                    Write-Host "    $bodyString" -ForegroundColor DarkGray
                }
            }
            Write-Host ''
        }

        # --- Execute (up to 2 attempts: retry once after 401 + token refresh) ---
        $timestamp   = Get-Date
        $statusCode  = 0
        $rawBody     = ''
        $respHeaders = @{}
        $success     = $false
        $errMsg      = $null

        for ($attempt = 1; $attempt -le 2; $attempt++) {

            # Rebuild headers each attempt so a refreshed token is picked up
            $reqHeaders = @{}
            foreach ($key in $Token.Headers.Keys) { $reqHeaders[$key] = $Token.Headers[$key] }

            try {
                $iwrParams = @{
                    Uri             = $fullUri
                    Method          = $method
                    Headers         = $reqHeaders
                    UseBasicParsing = $true
                    ErrorAction     = 'Stop'
                }
                if ($bodyString) {
                    $iwrParams['Body']        = $bodyString
                    $iwrParams['ContentType'] = 'application/json'
                }

                $response   = Invoke-WebRequest @iwrParams
                $statusCode = [int]$response.StatusCode
                $rawBody    = $response.Content
                $success    = $true
                foreach ($key in $response.Headers.Keys) {
                    $val = $response.Headers[$key]
                    $respHeaders[$key] = if ($val -is [array]) { $val -join ', ' } else { "$val" }
                }

            } catch [System.Net.WebException] {
                $caughtErr  = $_
                $webEx      = $caughtErr.Exception
                $webResp    = $webEx.Response -as [System.Net.HttpWebResponse]
                $statusCode = if ($webResp) { [int]$webResp.StatusCode } else { 0 }
                $rawBody    = ''
                $respHeaders = @{}
                if ($webResp) {
                    foreach ($key in $webResp.Headers.AllKeys) {
                        $respHeaders[$key] = $webResp.Headers[$key]
                    }
                }
                # Windows PowerShell 5.1's Invoke-WebRequest already reads the error response
                # stream once internally to populate $_.ErrorDetails.Message - by the time this
                # catch block runs, $webResp.GetResponseStream() has already been consumed and
                # reads back empty, silently losing the server's actual error body (discovered
                # live: a real CyberArk 400 with an 80-byte JSON body came back as ResponseBody
                # = null). Prefer ErrorDetails.Message, which already has that content; fall
                # back to a manual stream read only if it's unexpectedly empty.
                if ($caughtErr.ErrorDetails -and $caughtErr.ErrorDetails.Message) {
                    $rawBody = $caughtErr.ErrorDetails.Message
                } elseif ($webResp) {
                    try {
                        $reader  = [System.IO.StreamReader]::new($webResp.GetResponseStream())
                        $rawBody = $reader.ReadToEnd()
                        $reader.Dispose()
                    } catch {}
                }
                $errMsg = $webEx.Message

            } catch {
                $caughtErr = $_
                $errMsg    = "$caughtErr"
            }

            # On 401, attempt a token refresh and retry once
            if ($statusCode -eq 401 -and $attempt -eq 1) {
                Write-Host ''
                Write-Host '  401 Unauthorized - attempting token refresh...' -ForegroundColor Yellow
                # Invoke-TokenRefresh short-circuits (returns $true without re-authenticating) when
                # Test-TokenExpiry still reports the token as locally Valid/Warning - which it will
                # here, since the server just rejected a token our local expiry clock hasn't caught
                # up to yet. Invoke-TokenInvalidate force-expires it first so the refresh actually
                # runs, matching the pattern every other module relies on via the IsFatal/driver loop.
                Invoke-TokenInvalidate
                $refreshed = Invoke-TokenRefresh
                if (-not $refreshed) {
                    Write-Host '  Token refresh failed or cancelled.' -ForegroundColor Red
                    $result.IsFatal = $true
                    break
                }
                $Token = $script:SessionToken
                Write-Host '  Token refreshed - retrying request...' -ForegroundColor Green
                Write-Host ''
                continue
            }

            break   # success, non-401 failure, or second attempt exhausted
        }

        if ($result.IsFatal) { break }

        # --- Display status ---
        Write-Host ''
        $statusColor = if    ($statusCode -ge 200 -and $statusCode -lt 300) { 'Green'   }
                       elseif ($statusCode -ge 300 -and $statusCode -lt 400) { 'Yellow'  }
                       elseif ($statusCode -ge 400)                          { 'Red'     }
                       else                                                  { 'DarkGray'}
        $statusLabel = if ($success) { "HTTP $statusCode" } else { "HTTP $statusCode  [FAILED]" }
        Write-Host "  Status: $statusLabel" -ForegroundColor $statusColor
        if ($errMsg -and $statusCode -eq 0) {
            Write-Host "  Error:  $errMsg" -ForegroundColor Red
        }

        # --- Display response body ---
        if ($rawBody) {
            Write-Host ''
            Write-Host '  Response Body:' -ForegroundColor DarkCyan
            try {
                $pretty = $rawBody | ConvertFrom-Json | ConvertTo-Json -Depth 20
                $lines  = $pretty.Split("`n")
                if ($lines.Count -gt 40) {
                    $lines[0..39] | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
                    Write-Host "    ... ($($lines.Count - 40) more lines - full body in log)" -ForegroundColor DarkGray
                } else {
                    $lines | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
                }
            } catch {
                if ($rawBody.Length -gt 2000) {
                    Write-Host "    $($rawBody.Substring(0, 2000))" -ForegroundColor Gray
                    Write-Host "    ... ($($rawBody.Length - 2000) more chars)" -ForegroundColor DarkGray
                } else {
                    Write-Host "    $rawBody" -ForegroundColor Gray
                }
            }
        }

        # --- Verbose: show response headers ---
        if ($verbose -and $respHeaders.Count -gt 0) {
            Write-Host ''
            Write-Host '  Response Headers:' -ForegroundColor DarkCyan
            foreach ($key in ($respHeaders.Keys | Sort-Object)) {
                Write-Host "    $($key): $($respHeaders[$key])" -ForegroundColor DarkGray
            }
        }

        # --- Log ---
        Write-CyberArkLog -Level 'DEBUG' -Message "Test API: $method $fullUri -> HTTP $statusCode"
        if ($rawBody) {
            Write-CyberArkLog -Level 'DEBUG' -Message "Test API response body: $rawBody" -FileOnly
        }

        # --- Accumulate results ---
        $safeReqHdrs = @{}
        foreach ($key in $reqHeaders.Keys) {
            $safeReqHdrs[$key] = if ($key -imatch 'authoriz|bearer|token|apikey|secret|password') {
                '***'
            } else { $reqHeaders[$key] }
        }
        $allRuns.Add([PSCustomObject]@{
            Timestamp       = $timestamp.ToUniversalTime().ToString('o')
            Method          = $method
            Uri             = $fullUri
            Path            = $cleanPath
            QueryParams     = if ($queryString) { $queryString.Trim() } else { '' }
            RequestHeaders  = $safeReqHdrs
            RequestBody     = $bodyString
            StatusCode      = $statusCode
            Success         = $success
            ErrorMessage    = $errMsg
            ResponseHeaders = $respHeaders
            ResponseBody    = try { $rawBody | ConvertFrom-Json } catch { $rawBody }
        })

        if ($success) {
            $result.Successes++
        } else {
            $result.Failures++
            $result.Errors.Add([PSCustomObject]@{
                InputData    = @{ Method = $method; Path = $cleanPath }
                ErrorMessage = if ($errMsg) { $errMsg } else { "HTTP $statusCode" }
                ErrorDetails = $null
            })
        }
        $result.ItemsProcessed++

        $result.Results.Add([PSCustomObject]@{
            Time        = $timestamp.ToString('HH:mm:ss')
            Method      = $method
            Path        = $cleanPath
            QueryParams = if ($queryString) { $queryString.Trim() } else { '' }
            StatusCode  = $statusCode
            Success     = $success
        })

        # --- Next action ---
        Write-Host ''
        Write-Host '  [A] Another request    [R] Retry (re-enter body)    [S] Save full details (JSON)    [V] Toggle verbose    [B] Back' -ForegroundColor White
        $next = Read-MenuChoice -Prompt '[A] / [R] / [S] / [V] / [B]ack (default: B)'
        if (-not $next) { $next = 'B' }
        $nextUp = $next.Trim().ToUpper()

        if ($nextUp -eq 'V') {
            $verbose = -not $verbose
            continue
        }

        if ($nextUp -eq 'R') {
            $retryRequest = $true
            continue
        }

        if ($nextUp -eq 'A') { continue }

        if ($nextUp -eq 'S') {
            $folder = if ($script:ActiveProfile.PSObject.Properties['OutputFolder'] -and
                          $script:ActiveProfile.OutputFolder) {
                $script:ActiveProfile.OutputFolder
            } else { '' }
            if (-not $folder) { $folder = (Get-Location).Path }
            elseif (-not [System.IO.Path]::IsPathRooted($folder)) {
                $folder = Join-Path (Get-Location).Path $folder
            }
            if (-not (Test-Path -LiteralPath $folder)) {
                try { New-Item -ItemType Directory -Path $folder -Force | Out-Null } catch {}
            }
            $savePath = Join-Path $folder "TestAPI_$($timestamp.ToString('yyyy-MM-dd_HHmmss')).json"
            $json     = $allRuns | ConvertTo-Json -Depth 20
            # Invoke-FileWriteWithRetry (defined in Manage-Privilege.ps1) is available because
            # this module is dot-sourced into the driver scope. If the file is open/locked, it
            # prompts to retry rather than discarding the captured run history.
            $saved = Invoke-FileWriteWithRetry -Path $savePath -Action {
                [System.IO.File]::WriteAllText($savePath, $json, [System.Text.Encoding]::UTF8)
            }
            if ($saved) {
                Write-Host "  Saved: $savePath" -ForegroundColor Green
                Write-CyberArkLog -Level 'INFO' -Message "Test API details saved to: $savePath"
            } else {
                Write-Host '  Failed to save (user declined to retry).' -ForegroundColor Red
                Write-CyberArkLog -Level 'ERROR' -Message "Test API save failed for '$savePath' (user declined to retry)."
            }
            continue
        }

        break   # [B] or unrecognised input
    }

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name `
        -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
