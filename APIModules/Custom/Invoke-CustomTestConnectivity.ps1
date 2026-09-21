#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Test Connectivity'
    Category         = 'Custom'
    Action           = 'TestConnectivity'
    Description      = 'Test DNS resolution, port connectivity, and authentication to a Windows or Linux server. Retrieves the account credential from the vault if not supplied.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $true
    ProducesOutput   = $true
    HasCustomInput   = $true
    # Bulk export tool whose whole purpose is producing a results CSV - save automatically with
    # no "Save to CSV?" prompt or file dialog, matching the three Custom export tools. See
    # Get-CsvSavePath and the ProducesOutput handling in Invoke-ActionModule (Manage-Privilege.ps1).
    # Only applies to the interactive single-item path - CSV-batch mode already writes its own
    # output file automatically via Invoke-CsvProcessing, independent of this flag.
    AutoSaveCsv      = $true
    # Per user request: the single-interactive-run auto-saved CSV filename includes the tested
    # Address (e.g. "Test Connectivity - 172.21.20.14 2026-09-04.csv") instead of just the
    # module name and date, since a user testing several servers one at a time would otherwise
    # overwrite the same file on every run. Only applies to that single-item path - CSV-batch
    # mode names its own output file independently via Invoke-CsvProcessing.
    CsvFilenameField = 'Address'
    InputSchema      = @(
        @{ Column = 'Address';          Required = $true;  Description = 'IP address, short hostname, or FQDN of the target server.' }
        @{ Column = 'ServerType';       Required = $true;  Description = 'Windows or Linux.' }
        @{ Column = 'Account';          Required = $true;  Description = 'Username to authenticate as (e.g. DOMAIN\username or .\username for a local account).' }
        @{ Column = 'Password';         Required = $false; Description = 'Password to authenticate with. Leave blank to look up this Address+Account in the vault.' }
        @{ Column = 'AdditionalPorts';  Required = $false; Description = 'Comma-separated extra TCP ports to check (e.g. 443,8080), in addition to the built-in defaults (135/139/445/3389 for Windows, 22 for Linux). Informational only - does not affect AuthStatus. Leave blank for none.' }
    )
    Priority         = 96
    Version          = '1.6.0'
}

#region Private helpers - each isolated so Pester can mock it independently of the others

function script:Resolve-ConnectivityTarget {
    <#
        Resolves $Address (an IP, short hostname, or FQDN) to both a hostname and an IP address
        in one call - .NET's GetHostEntry performs a reverse lookup when given an IP and a
        forward lookup when given a name, so no separate IP-vs-name branch is needed here.
        Returns @{ Success; FQDN; IPAddress; ErrorMessage }.
    #>
    param([string]$Address)

    $ipObj       = $null
    $isLiteralIp = [System.Net.IPAddress]::TryParse($Address, [ref]$ipObj)

    try {
        $entry = [System.Net.Dns]::GetHostEntry($Address)

        $resolvedIp = if ($isLiteralIp) {
            # Address was already an IP literal - echo it back rather than re-deriving it from
            # AddressList, which could legitimately differ on a multi-homed host.
            $Address
        } else {
            $ipv4 = $entry.AddressList | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1
            if ($ipv4) { $ipv4.IPAddressToString } elseif ($entry.AddressList.Count -gt 0) { $entry.AddressList[0].IPAddressToString } else { '' }
        }

        return @{
            Success      = $true
            FQDN         = $entry.HostName
            IPAddress    = $resolvedIp
            ErrorMessage = ''
        }
    } catch {
        # Confirmed live: a real, fully reachable test host failed here with "No such host is
        # known" purely because it has no reverse-DNS (PTR) record - common for internal/test
        # hosts that were never registered in reverse DNS, and not a real connectivity problem.
        # For a literal IP, the address itself is already fully known and directly usable
        # without any DNS lookup at all - failing to also learn its hostname must not abort the
        # whole test before the port/auth checks even run. A name that fails to resolve, by
        # contrast, leaves nothing to connect to at all, so that case is still a hard failure.
        if ($isLiteralIp) {
            return @{
                Success      = $true
                FQDN         = ''
                IPAddress    = $Address
                ErrorMessage = ''
            }
        }
        return @{
            Success      = $false
            FQDN         = ''
            IPAddress    = ''
            ErrorMessage = "DNS resolution failed for '$Address': $_"
        }
    }
}

function script:Test-TcpPortOpen {
    <#
        Lightweight TCP connect test with a short timeout - used instead of the
        Test-NetConnection cmdlet, which also performs an ICMP ping and DNS resolution by
        default and is noticeably slower across many ports/servers in a bulk CSV run.
    #>
    param(
        [string]$ComputerName,
        [int]$Port,
        [int]$TimeoutMs = 3000
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $asyncResult = $client.BeginConnect($ComputerName, $Port, $null, $null)
        $completed   = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($completed -and $client.Connected) {
            $client.EndConnect($asyncResult)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function script:Test-WindowsSmbAuth {
    <#
        Authentication test for Windows targets: maps \\<Address>\IPC$ with the supplied
        credential via New-SmbMapping, then immediately removes the mapping. This validates the
        credential over SMB (port 445) - a classic RPC endpoint-mapper test (port 135) would not
        actually exercise credential validation the way this admin-share mapping does.
        Returns @{ Success; ErrorMessage }.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'New-SmbMapping only accepts -Password as a plain string, not SecureString/PSCredential - converting and back would not reduce exposure.')]
    param(
        [string]$Address,
        [string]$Account,
        [string]$Password
    )

    $remotePath = "\\$Address\IPC$"

    try {
        New-SmbMapping -RemotePath $remotePath -UserName $Account -Password $Password -ErrorAction Stop | Out-Null
        Remove-SmbMapping -RemotePath $remotePath -Force -ErrorAction SilentlyContinue
        return @{ Success = $true; ErrorMessage = '' }
    } catch {
        return @{ Success = $false; ErrorMessage = "$_" }
    }
}

function script:ConvertTo-Win32QuotedArgument {
    <#
        Quotes a single argument per the same rules CommandLineToArgvW/CreateProcess expect,
        matching what ProcessStartInfo.ArgumentList does internally - used as the fallback
        below on .NET Framework versions older than 4.6.1, where ArgumentList does not exist.
        An argument with no spaces, tabs, or quotes is returned unchanged; otherwise it is
        wrapped in double quotes with embedded backslashes/quotes escaped correctly (a run of
        backslashes is only doubled when it immediately precedes a quote or the end of the
        argument - backslashes elsewhere are left alone).
    #>
    param([string]$Value)

    if ($null -eq $Value) { $Value = '' }
    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    $chars = $Value.ToCharArray()
    $i = 0
    while ($i -lt $chars.Length) {
        $backslashes = 0
        while ($i -lt $chars.Length -and $chars[$i] -eq '\') { $backslashes++; $i++ }
        if ($i -eq $chars.Length) {
            [void]$sb.Append('\', ($backslashes * 2))
        } elseif ($chars[$i] -eq '"') {
            [void]$sb.Append('\', ($backslashes * 2 + 1))
            [void]$sb.Append('"')
            $i++
        } else {
            [void]$sb.Append('\', $backslashes)
            [void]$sb.Append($chars[$i])
            $i++
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function script:Invoke-ExternalProcessWithTimeout {
    <#
        Runs an external executable, capturing stdout/stderr, without ever hanging past
        $TimeoutSec. Shared by both branches of Test-LinuxSshAuth below.
        Returns @{ TimedOut; ExitCode; StdOut; StdErr }.
    #>
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [int]$TimeoutSec
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath

    # ProcessStartInfo.ArgumentList was added in .NET Framework 4.6.1 and is not reliably usable
    # on every machine this driver runs on - confirmed live by the user as a full
    # PropertyNotFoundException crash under Set-StrictMode on one machine (older .NET Framework,
    # where the member genuinely does not exist), and separately reproduced here as a silent
    # $null property - present as a member, but not populated with a real collection - on
    # another (.NET Framework 4.8). Neither failure mode is safe to assume away, so detection
    # uses a disposable probe object (never the real $psi) wrapped in try/catch: if anything
    # about ArgumentList is unusable, fall back to the single-string .Arguments property with
    # each argument manually quoted per Win32 command-line rules instead. Probing separately
    # avoids ever leaving $psi in a partially-populated, ambiguous state if the real usage
    # failed partway through the loop.
    $argumentListUsable = $false
    try {
        $probe = [System.Diagnostics.ProcessStartInfo]::new()
        if ($null -ne $probe.ArgumentList) {
            $probe.ArgumentList.Add('x')
            $argumentListUsable = ($probe.ArgumentList.Count -eq 1)
        }
    } catch {
        $argumentListUsable = $false
    }

    if ($argumentListUsable) {
        # Quote every argument individually rather than joining with spaces first - avoids
        # mis-splitting an argument that itself contains a space (e.g. a password with a space in it).
        foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }
    } else {
        $psi.Arguments = (($ArgumentList | ForEach-Object { script:ConvertTo-Win32QuotedArgument -Value $_ }) -join ' ')
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $exited = $proc.WaitForExit($TimeoutSec * 1000)

    if (-not $exited) {
        try { $proc.Kill() } catch {}
        return @{ TimedOut = $true; ExitCode = -1; StdOut = ''; StdErr = '' }
    }

    return @{ TimedOut = $false; ExitCode = $proc.ExitCode; StdOut = $stdout.Result; StdErr = $stderr.Result }
}

function script:Find-PlinkExecutable {
    <#
        Locates plink.exe, checking in order (per user direction): PATH, then the project root
        (a documented drop-in location for a user who doesn't want to add it to PATH system-
        wide), then the standard PuTTY install directories - 32-bit ("Program Files (x86)")
        before 64-bit ("Program Files"), matching the user's specified check order. Uses the
        %ProgramFiles%/%ProgramFiles(x86)% environment variables rather than hardcoded drive
        letters, since Windows is not guaranteed to be installed on C:\. Returns the full path
        to plink.exe, or $null if none of these locations has it.
    #>
    $onPath = Get-Command -Name 'plink.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add((Join-Path $PSScriptRoot '..\..\plink.exe'))
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'PuTTY\plink.exe')) }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'PuTTY\plink.exe')) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function script:Test-LinuxSshAuth {
    <#
        Authentication test for Linux targets over SSH (port 22). PowerShell 5.1 has no built-in
        SSH client, so this cascades: try plink.exe (PuTTY) first if available, then PowerShell
        7's SSH transport if pwsh is available, then report neither is available.

        Plink is tried FIRST as of 2026-09-04, per the user's own live test: even after fixing
        the PS7 path's unknown-host-key hang (StrictHostKeyChecking=no, see below), a real
        password-auth attempt via that path still timed out - confirming the CAVEAT below in
        practice, not just in theory. Plink doesn't have this problem, since -pw submits the
        password directly rather than needing a TTY prompt.

        IMPORTANT CAVEAT: native OpenSSH (which PS7's -SSHTransport relies on) deliberately does
        not support non-interactive password authentication - it requires either a TTY for an
        interactive password prompt or key-based auth, by design (this is why tools like sshpass
        exist as a separate pty-emulation wrapper on Linux, with no equivalent bundled on
        Windows). The PS7 path below can confirm the SSH handshake/host reachability and will
        succeed for key-based auth, but is not a reliable way to validate a *password* - only
        plink.exe (which has its own, more permissive -pw flag) reliably does that, confirmed
        live. This path is kept as a fallback for environments without plink.exe available, with
        this limitation surfaced via ErrorMessage rather than silently treated as equivalent.

        SECURITY NOTE on the plink path: -pw passes the plaintext password as a process command-
        line argument, which is briefly visible to anything else on the machine that can enumerate
        process command lines (e.g. Get-Process, Process Explorer) while plink is running. This is
        an inherent characteristic of plink's own -pw flag, not something this wrapper can avoid
        while still using it for scripted password auth.

        Returns @{ Success; ErrorMessage }.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'Both plink -pw and the embedded pwsh command string need a plain string - converting to SecureString and back would not reduce exposure, and plink specifically has no SecureString-accepting alternative.')]
    param(
        [string]$Address,
        [string]$Account,
        [string]$Password,
        [int]$TimeoutSec = 15
    )

    # Bare name, not script:Find-PlinkExecutable - a script:-qualified call bypasses Pester's
    # Mock shadowing entirely (see Lessons-Learned-PowerShell-Pester.md), same as every other
    # helper call in this file.
    $plinkPath = Find-PlinkExecutable
    $pwshCmd   = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue

    if ($plinkPath) {
        # -batch already disables plink's own interactive prompts. Confirmed live against a
        # genuinely never-before-seen host (no HKCU:\Software\SimonTatham\PuTTY\SshHostKeys
        # existed yet on this machine): an unrecognized host key does NOT hang, unlike the PS7
        # path above - plink aborts in well under a second with a clear "host key is not cached
        # ... Connection abandoned" message, which includes its own fingerprint.
        #
        # Unlike OpenSSH's StrictHostKeyChecking=no, plink has no CLI flag to blindly trust
        # whatever key a target presents - -hostkey requires the exact key already known. But
        # confirmed live: that error message always includes the fingerprint plink itself
        # computed, so it can be parsed out and fed straight back via -hostkey on a single
        # automatic retry - trust-on-first-use, the same tradeoff already made for the PS7 path
        # above (StrictHostKeyChecking=no) and appropriate for the same reason: this is a
        # connectivity *test* tool, not a long-term managed session.
        Write-CyberArkLog -Level 'DEBUG' -Message "Using plink at '$plinkPath' for SSH auth test."
        $plinkArgs = @('-ssh', '-batch', '-pw', $Password, "$Account@$Address", 'exit')
        $procResult = Invoke-ExternalProcessWithTimeout -FilePath $plinkPath -ArgumentList $plinkArgs -TimeoutSec $TimeoutSec

        if (-not $procResult.TimedOut -and $procResult.ExitCode -ne 0) {
            $combinedOutput = "$($procResult.StdOut)`n$($procResult.StdErr)"
            if ($combinedOutput -match 'host key is not cached' -and $combinedOutput -match '(SHA256:\S+)') {
                $fingerprint = $Matches[1]
                Write-CyberArkLog -Level 'WARN' -Message "plink: host key for '$Address' not cached ($fingerprint) - retrying once with that fingerprint pre-authorized (trust-on-first-use)."
                $procResult = Invoke-ExternalProcessWithTimeout -FilePath $plinkPath `
                    -ArgumentList (@('-ssh', '-batch', '-hostkey', $fingerprint) + $plinkArgs[2..($plinkArgs.Count - 1)]) -TimeoutSec $TimeoutSec
            }
        }

        if ($procResult.TimedOut) {
            return @{ Success = $false; ErrorMessage = "SSH connection to '$Address' via plink timed out after $TimeoutSec second(s)." }
        }
        if ($procResult.ExitCode -eq 0) {
            return @{ Success = $true; ErrorMessage = '' }
        }
        $errText = if ($procResult.StdErr) { $procResult.StdErr.Trim() } elseif ($procResult.StdOut) { $procResult.StdOut.Trim() } else { "plink exited with code $($procResult.ExitCode)" }
        return @{ Success = $false; ErrorMessage = $errText }
    }

    if ($pwshCmd) {
        # See the CAVEAT above - this validates SSH reachability/handshake reliably, but password
        # auth specifically is not guaranteed to be exercised non-interactively.
        #
        # -Options @{StrictHostKeyChecking='no'} (an OpenSSH ssh_config directive, passed straight
        # through by New-PSSession's -SSHTransport): confirmed live - connecting to a target
        # whose host key isn't yet in this machine's known_hosts otherwise hangs until
        # $TimeoutSec, silently (no prompt visible), because the interactive "are you sure you
        # want to continue connecting" confirmation OpenSSH would normally ask has nothing to
        # answer it in this non-interactive child process. StrictHostKeyChecking=no answers
        # "yes" automatically on a first-time connection and still records the key in
        # known_hosts for next time (unlike disabling UserKnownHostsFile entirely) - an
        # acceptable tradeoff for a connectivity *test* tool whose purpose is confirming
        # reachability, not maintaining long-term host-key-pinning security guarantees for an
        # ongoing session.
        $innerScript = "try { `$s = New-PSSession -HostName '$Address' -UserName '$Account' -SSHTransport -Options @{StrictHostKeyChecking='no'} -ErrorAction Stop; Remove-PSSession -Session `$s -ErrorAction SilentlyContinue; Write-Output 'SUCCESS' } catch { Write-Output ('FAIL:' + `$_.Exception.Message) }"

        $procResult = Invoke-ExternalProcessWithTimeout -FilePath $pwshCmd.Source `
            -ArgumentList @('-NoProfile', '-NoLogo', '-Command', $innerScript) -TimeoutSec $TimeoutSec

        if ($procResult.TimedOut) {
            # Confirmed live: an unrecognized host key used to hang here waiting for an
            # interactive confirmation that had nothing to answer it - fixed above via
            # StrictHostKeyChecking=no. A timeout can still happen even with a known host key,
            # though: this path spawns pwsh/ssh with no console at all, and native OpenSSH's
            # password prompt (see the CAVEAT above) can hang the same way waiting for input
            # that will never arrive, rather than failing fast the way it does with a real
            # console attached. plink.exe (below) doesn't have this problem, since -pw submits
            # the password directly rather than needing a TTY prompt.
            return @{ Success = $false; ErrorMessage = "SSH connection to '$Address' timed out after $TimeoutSec second(s) (PowerShell 7 SSH transport - this can happen even with a correct password, since this path cannot reliably submit one non-interactively; install plink.exe for reliable password testing)." }
        }

        $resultLine = @($procResult.StdOut -split "`r?`n") | Where-Object { $_ -match '^(SUCCESS|FAIL:)' } | Select-Object -Last 1
        if ($resultLine -eq 'SUCCESS') {
            return @{ Success = $true; ErrorMessage = '' }
        }
        $detail = if ($resultLine) { $resultLine -replace '^FAIL:', '' } elseif ($procResult.StdErr) { $procResult.StdErr.Trim() } else { 'no result returned' }
        return @{ Success = $false; ErrorMessage = "PowerShell 7 SSH transport failed: $detail (note: password auth is not reliably testable via this path - see module source comments; plink.exe is the more reliable option for password validation)" }
    }

    return @{ Success = $false; ErrorMessage = 'Plink or PS7 needed for auth test' }
}

function script:ConvertTo-PortList {
    <#
        Parses a comma-separated port list (e.g. "443, 8080,8080") into a de-duplicated array of
        valid ints (1-65535), in the order first seen. Returns @{ Success; Ports; ErrorMessage } -
        Success=$false with a specific ErrorMessage naming the bad token if any entry isn't a
        valid port number, so a typo in CSV/interactive input fails the item clearly instead of
        silently dropping it, matching this project's established validation convention (e.g.
        Invoke-ApplicationsAdd.ps1's AccessPermittedFrom/To range checks).
    #>
    param([string]$Value)

    if (-not $Value) { return @{ Success = $true; Ports = @(); ErrorMessage = '' } }

    $ports = [System.Collections.Generic.List[int]]::new()
    foreach ($token in ($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $parsed = 0
        if (-not [int]::TryParse($token, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 65535) {
            return @{ Success = $false; Ports = @(); ErrorMessage = "AdditionalPorts: '$token' is not a valid port number (must be 1-65535)." }
        }
        if (-not $ports.Contains($parsed)) { $ports.Add($parsed) }
    }
    return @{ Success = $true; Ports = @($ports); ErrorMessage = '' }
}

function script:Resolve-VaultPassword {
    <#
        Looks up an account in the vault by exact Address + Account (userName) match when no
        password was supplied in the input row, and retrieves its current credential value.
        Searches across all safes the caller can see (no Safe column exists in this module's
        input) via a free-text /API/Accounts search narrowed to $Address, then filters
        client-side for an exact match - the same defensive "search broadly, match exactly
        client-side" pattern already used by Invoke-AccountsCancelCpmTask.ps1 and
        Invoke-AccountsGetCredential.ps1, rather than relying on an unconfirmed server-side
        filter field name for address/userName.
        Returns @{ Success; Password; SafeName; Username; ErrorMessage }. SafeName/Username
        identify the specific vaulted account that was matched and used, for the output CSV's
        Safe/Username columns - both are blank whenever Success is $false.
    #>
    param(
        [PSCustomObject]$Token,
        [string]$Address,
        [string]$Account
    )

    $searchResp = Invoke-CyberArkAPI `
        -Token       $Token `
        -Method      'GET' `
        -Endpoint    '/API/Accounts' `
        -QueryParams @{ search = $Address; limit = 1000 }

    if (-not $searchResp.IsSuccess) {
        Write-CyberArkLog -Level 'ERROR' -Message "Test Connectivity: vault account search failed for '$Address' (HTTP $($searchResp.StatusCode)): $($searchResp.ErrorMessage)"
        return @{ Success = $false; Password = ''; SafeName = ''; Username = ''; ErrorMessage = 'Password Not Found' }
    }

    [array]$candidates = if ($searchResp.Data -and $searchResp.Data.PSObject.Properties['value'] -and $null -ne $searchResp.Data.value) {
        @($searchResp.Data.value)
    } else { @() }

    $match = $candidates | Where-Object {
        $_ -and $_.PSObject.Properties['address'] -and $_.PSObject.Properties['userName'] -and
        $_.address -eq $Address -and $_.userName -eq $Account
    }
    [array]$matches = @($match)

    if ($matches.Count -eq 0) {
        Write-CyberArkLog -Level 'WARN' -Message "Test Connectivity: no vault account found for Address='$Address' Account='$Account'."
        return @{ Success = $false; Password = ''; SafeName = ''; Username = ''; ErrorMessage = 'Password Not Found' }
    }
    if ($matches.Count -gt 1) {
        Write-CyberArkLog -Level 'WARN' -Message "Test Connectivity: multiple vault accounts matched Address='$Address' Account='$Account' - using first match."
    }

    $accountId = if ($matches[0].PSObject.Properties['id']) { $matches[0].id } else { '' }
    if (-not $accountId) {
        return @{ Success = $false; Password = ''; SafeName = ''; Username = ''; ErrorMessage = 'Password Not Found' }
    }

    $matchedSafeName = if ($matches[0].PSObject.Properties['safeName']) { "$($matches[0].safeName)" } else { '' }
    $matchedUsername = if ($matches[0].PSObject.Properties['userName']) { "$($matches[0].userName)" } else { $Account }

    $body = @{
        reason              = 'aPePAS Test Connectivity module'
        TicketingSystemName = $null
        TicketId            = $null
        Version             = 0
        actionType          = $null
        isUse               = $false
        Machine             = ''
    }

    $retrieveResp = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint "/API/Accounts/$([Uri]::EscapeDataString($accountId))/Password/Retrieve" `
        -Body     $body

    if (-not $retrieveResp.IsSuccess) {
        Write-CyberArkLog -Level 'ERROR' -Message "Test Connectivity: credential retrieval failed for AccountID=$accountId (HTTP $($retrieveResp.StatusCode)): $($retrieveResp.ErrorMessage)"
        return @{ Success = $false; Password = ''; SafeName = ''; Username = ''; ErrorMessage = 'Password Not Found' }
    }

    # CRITICAL: the response is a raw string (the password), not JSON - never log this value.
    $password = if ($retrieveResp.Data) { "$($retrieveResp.Data)" } else { $retrieveResp.RawResponse }
    return @{ Success = $true; Password = $password; SafeName = $matchedSafeName; Username = $matchedUsername; ErrorMessage = '' }
}

#endregion

function Get-CustomTestConnectivityInput {
    <#
        Called by the driver when HasCustomInput = $true.
        Show-FieldPrompt is available because this module is dot-sourced into the driver scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Test Connectivity' -ForegroundColor DarkGray
    Write-Host ''

    $address = Show-FieldPrompt -Label 'Address' `
        -Default $(if ($Defaults['Address']) { $Defaults['Address'] } else { '' }) `
        -Required $true `
        -Description 'IP address, short hostname, or FQDN of the target server.'

    # Per user request: the prompt asks for the number, not the name - the shown default is
    # translated back to its number too, so it stays number-only even when re-prompting with a
    # prior value (e.g. from a CSV template) carried forward as the default.
    $currentServerType    = if ($Defaults['ServerType']) { $Defaults['ServerType'] } else { 'Windows' }
    $defaultServerTypeNum = if ($currentServerType -eq 'Linux') { '2' } else { '1' }
    $serverTypeInput = Show-FieldPrompt -Label 'Server Type' `
        -Default $defaultServerTypeNum `
        -Description 'Enter 1 for Windows or 2 for Linux.'
    $serverType = switch ($serverTypeInput.Trim()) {
        '1'       { 'Windows' }
        '2'       { 'Linux'   }
        'Linux'   { 'Linux'   }
        'linux'   { 'Linux'   }
        default   { 'Windows' }
    }

    $account = Show-FieldPrompt -Label 'Account' `
        -Default $(if ($Defaults['Account']) { $Defaults['Account'] } else { '' }) `
        -Required $true `
        -Description 'Username to authenticate as (e.g. DOMAIN\username or .\username for a local account).'

    $password = Show-FieldPrompt -Label 'Password' `
        -IsSecret `
        -Description 'Leave blank to look this account up in the vault by Address and Account.'

    $additionalPorts = Show-FieldPrompt -Label 'Additional Ports' `
        -Default $(if ($Defaults['AdditionalPorts']) { $Defaults['AdditionalPorts'] } else { '' }) `
        -Description 'Comma-separated extra TCP ports to check (e.g. 443,8080), in addition to the built-in defaults. Leave blank for none.'

    return @{
        Address         = $address
        ServerType      = $serverType
        Account         = $account
        Password        = $password
        AdditionalPorts = $additionalPorts
    }
}

function Invoke-CustomTestConnectivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token,

        [Parameter(Mandatory = $false)]
        [hashtable]$InputData,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
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

    if (-not $InputData) { $InputData = @{} }

    $address    = if ($InputData['Address'])    { "$($InputData['Address'])".Trim()    } else { '' }
    $serverType = if ($InputData['ServerType']) { "$($InputData['ServerType'])".Trim() } else { '' }
    $account    = if ($InputData['Account'])    { "$($InputData['Account'])".Trim()    } else { '' }
    $password   = if ($InputData['Password'])   { "$($InputData['Password'])".Trim()   } else { '' }

    if (-not $address) {
        $msg = 'Address is required and must not be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    if ($serverType -notin @('Windows', 'Linux')) {
        $msg = "ServerType '$serverType' is invalid. Must be Windows or Linux."
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    if (-not $account) {
        $msg = 'Account is required and must not be empty.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }

    $additionalPortsRaw = if ($InputData['AdditionalPorts']) { "$($InputData['AdditionalPorts'])".Trim() } else { '' }
    $portListResult      = ConvertTo-PortList -Value $additionalPortsRaw
    if (-not $portListResult.Success) {
        $msg = $portListResult.ErrorMessage
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $null })
        $result.Failures++
        $result.ItemsProcessed++
        return $result
    }
    $additionalPorts = $portListResult.Ports

    $result.ItemsProcessed++
    Write-CyberArkLog -Level 'INFO' -Message "Starting connectivity test for Address='$address' ServerType='$serverType' Account='$account'."

    # --- DNS resolution ---
    $dns = Resolve-ConnectivityTarget -Address $address

    if (-not $dns.Success) {
        $result.Results.Add([PSCustomObject]@{
            FQDN           = ''
            IPAddress      = ''
            DNSMatch       = $false
            PortCheck      = ''
            Protocol       = ''
            Safe           = ''
            Username       = ''
            PasswordSource = ''
            AuthStatus     = 'Fail'
            ErrorMessage   = $dns.ErrorMessage
        })
        $result.Failures++
        Write-CyberArkLog -Level 'ERROR' -Message "Test Connectivity: $($dns.ErrorMessage)"
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    # --- Password resolution (CSV/interactive value, or vault lookup) ---
    # PasswordSource, Safe, and Username are reported in the output so it's clear whether a
    # vaulted account was used to make the connection and, if so, which one - per user request.
    # Safe/Username stay blank unless a vault lookup actually matched and retrieved an account.
    $passwordSource = if ($password) { 'Provided' } else { 'Vault' }
    $vaultSafeName  = ''
    $vaultUsername  = ''
    $passwordError  = ''
    if (-not $password) {
        $lookup = Resolve-VaultPassword -Token $Token -Address $address -Account $account
        if ($lookup.Success) {
            $password      = $lookup.Password
            $vaultSafeName = $lookup.SafeName
            $vaultUsername = $lookup.Username
        } else {
            $passwordError = $lookup.ErrorMessage
        }
    }

    # --- Port check + auth attempt ---
    $protocol      = if ($serverType -eq 'Windows') { 'RPC' } else { 'SSH' }
    $portCheckParts = [System.Collections.Generic.List[string]]::new()
    $authStatus    = 'Fail'
    $authError     = ''
    $primaryPortOpen = $false

    $builtInPorts = if ($serverType -eq 'Windows') { @(135, 139, 445, 3389) } else { @(22) }

    if ($serverType -eq 'Windows') {
        foreach ($port in $builtInPorts) {
            $open = Test-TcpPortOpen -ComputerName $address -Port $port
            $portCheckParts.Add("$port($open)")
            if ($port -eq 445) { $primaryPortOpen = $open }
        }
    } else {
        foreach ($port in $builtInPorts) {
            $open = Test-TcpPortOpen -ComputerName $address -Port $port
            $portCheckParts.Add("$port($open)")
            $primaryPortOpen = $open
        }
    }

    # User-specified extra ports (AdditionalPorts) - informational only, appended after the
    # built-in ports and never affecting AuthStatus gating (still governed solely by the primary
    # port: 445 for Windows, 22 for Linux). Any port already covered above is skipped so it's
    # never tested or reported twice.
    foreach ($port in $additionalPorts) {
        if ($port -in $builtInPorts) { continue }
        $open = Test-TcpPortOpen -ComputerName $address -Port $port
        $portCheckParts.Add("$port($open)")
    }
    $portCheck = $portCheckParts -join ','

    if (-not $primaryPortOpen) {
        $authStatus = 'Fail'
        $authError  = if ($serverType -eq 'Windows') { 'Port 445 not reachable.' } else { 'Port 22 not reachable.' }
    } elseif ($passwordError) {
        $authStatus = 'Fail'
        $authError  = $passwordError
    } else {
        $authResult = if ($serverType -eq 'Windows') {
            Test-WindowsSmbAuth -Address $address -Account $account -Password $password
        } else {
            Test-LinuxSshAuth -Address $address -Account $account -Password $password
        }
        $authStatus = if ($authResult.Success) { 'Success' } else { 'Fail' }
        $authError  = $authResult.ErrorMessage
    }

    $result.Results.Add([PSCustomObject]@{
        FQDN           = $dns.FQDN
        IPAddress      = $dns.IPAddress
        DNSMatch       = $dns.Success
        PortCheck      = $portCheck
        Protocol       = $protocol
        Safe           = $vaultSafeName
        Username       = $vaultUsername
        PasswordSource = $passwordSource
        AuthStatus     = $authStatus
        ErrorMessage   = $authError
    })

    if ($authStatus -eq 'Success') {
        $result.Successes++
    } else {
        $result.Failures++
    }

    Write-CyberArkLog -Level 'INFO' -Message "Test Connectivity complete for '$address'. AuthStatus=$authStatus."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
