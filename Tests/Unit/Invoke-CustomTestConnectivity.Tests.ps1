#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Custom\Invoke-CustomTestConnectivity.ps1.

.NOTES
    Resolve-ConnectivityTarget and Test-TcpPortOpen are exercised against real DNS/loopback
    sockets (localhost resolution, a real TCP listener) rather than mocked - both are safe,
    deterministic, and require no external network access or CyberArk connection. The
    orchestration function (Invoke-CustomTestConnectivity) mocks all four helper functions
    (Resolve-ConnectivityTarget, Test-TcpPortOpen, Test-WindowsSmbAuth, Test-LinuxSshAuth,
    Resolve-VaultPassword) so its own logic - validation, port-gating before auth, the
    password-blank-falls-back-to-vault path, and output shape - is tested in isolation from
    real network/SMB/SSH calls. Get-CustomTestConnectivityInput is NOT tested here because it
    depends on Show-FieldPrompt, which is defined in Manage-Privilege.ps1 - same exemption as
    every other interactive-only input function in this codebase.
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Custom\Invoke-CustomTestConnectivity.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'CustomTestConnectivityTests' -MinLevel 'ERROR'

    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault'
    }

    function script:New-VaultAccountsResponse {
        param([object[]]$Accounts = @())
        return [PSCustomObject]@{
            IsSuccess     = $true
            StatusCode    = 200
            StatusMessage = 'OK'
            ErrorMessage  = $null
            ErrorDetails  = $null
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = [PSCustomObject]@{ value = @($Accounts) }
        }
    }

    function script:New-ApiErrorResponse {
        param([int]$StatusCode = 403, [string]$ErrorMessage = 'Forbidden')
        return [PSCustomObject]@{
            IsSuccess     = $false
            StatusCode    = $StatusCode
            StatusMessage = "HTTP $StatusCode"
            ErrorMessage  = $ErrorMessage
            ErrorDetails  = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $ErrorMessage; Details = $null }
            DataType      = 'JSON'
            RawResponse   = ''
            Data          = $null
        }
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

Describe 'ModuleMeta' {
    It 'TC01 - Name = Test Connectivity' {
        $ModuleMeta.Name | Should -Be 'Test Connectivity'
    }
    It 'TC02 - Category / Action' {
        $ModuleMeta.Category | Should -Be 'Custom'
        $ModuleMeta.Action   | Should -Be 'TestConnectivity'
    }
    It 'TC03 - AcceptsInputFile is true (supports both interactive and CSV)' {
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
    }
    It 'TC04 - AutoSaveCsv is true' {
        $ModuleMeta.AutoSaveCsv | Should -BeTrue
    }
    It 'TC05 - InputSchema requires Address, ServerType, Account; Password is optional' {
        ($ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'Address' }).Required    | Should -BeTrue
        ($ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'ServerType' }).Required | Should -BeTrue
        ($ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'Account' }).Required    | Should -BeTrue
        ($ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'Password' }).Required   | Should -BeFalse
    }
    It 'TC44 - InputSchema includes optional AdditionalPorts' {
        ($ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'AdditionalPorts' }).Required | Should -BeFalse
    }
}

Describe 'Resolve-ConnectivityTarget - real DNS (no mocking, deterministic inputs)' {
    It 'TC06 - localhost resolves successfully' {
        $r = Resolve-ConnectivityTarget -Address 'localhost'
        $r.Success   | Should -BeTrue
        $r.IPAddress | Should -Not -BeNullOrEmpty
    }

    It 'TC07 - an address in the reserved .invalid TLD (RFC 2606) fails to resolve' {
        $r = Resolve-ConnectivityTarget -Address 'this-host-does-not-exist.invalid'
        $r.Success      | Should -BeFalse
        $r.ErrorMessage | Should -Not -BeNullOrEmpty
    }

    It 'TC08 - a literal IP address is echoed back as IPAddress unchanged' {
        $r = Resolve-ConnectivityTarget -Address '127.0.0.1'
        $r.Success   | Should -BeTrue
        $r.IPAddress | Should -Be '127.0.0.1'
    }

    It 'TC40 - a literal IP with no reverse-DNS (PTR) record still succeeds, per live user report' {
        # Confirmed live against a real, fully reachable test host: GetHostEntry throws "No such
        # host is known" for a literal IP that simply has no PTR record configured - common for
        # internal/test hosts - which previously aborted the whole connectivity test before any
        # port/auth check even ran. 192.0.2.0/24 (RFC 5737 TEST-NET-1) is reserved specifically
        # for documentation/testing and is guaranteed to never have a PTR record, making this a
        # deterministic repro of the live bug without depending on any specific real host.
        $r = Resolve-ConnectivityTarget -Address '192.0.2.123'
        $r.Success   | Should -BeTrue
        $r.IPAddress | Should -Be '192.0.2.123'
        $r.FQDN      | Should -Be ''
    }
}

Describe 'Test-TcpPortOpen - real loopback socket (no mocking)' {
    It 'TC09 - an open port on a real listener returns True' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = $listener.LocalEndpoint.Port
            $open = Test-TcpPortOpen -ComputerName '127.0.0.1' -Port $port -TimeoutMs 2000
            $open | Should -BeTrue
        } finally {
            $listener.Stop()
        }
    }

    It 'TC10 - a closed port returns False' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $listener.Stop()
        # Port is now guaranteed closed (listener stopped) - a fast, deterministic negative case.
        $open = Test-TcpPortOpen -ComputerName '127.0.0.1' -Port $port -TimeoutMs 1000
        $open | Should -BeFalse
    }
}

Describe 'ConvertTo-Win32QuotedArgument' {
    # Regression coverage for a live crash: PropertyNotFoundException on ProcessStartInfo's
    # ArgumentList under Set-StrictMode, reproduced on TWO different .NET Framework versions
    # with two different symptoms (a true missing-member exception on the user's machine; a
    # present-but-unusable $null property here) - so Invoke-ExternalProcessWithTimeout falls
    # back to this manual quoting instead of relying on ArgumentList at all when it's not usable.

    It 'TC30 - a plain argument with no special characters is returned unchanged' {
        script:ConvertTo-Win32QuotedArgument -Value 'plain' | Should -Be 'plain'
    }

    It 'TC31 - an argument containing a space is wrapped in double quotes' {
        script:ConvertTo-Win32QuotedArgument -Value 'has space' | Should -Be '"has space"'
    }

    It 'TC32 - an embedded double quote is escaped with a preceding backslash' {
        script:ConvertTo-Win32QuotedArgument -Value 'has"quote' | Should -Be '"has\"quote"'
    }

    It 'TC33 - a trailing backslash with no surrounding spaces is left alone (no quoting needed)' {
        script:ConvertTo-Win32QuotedArgument -Value 'trail\' | Should -Be 'trail\'
    }

    It 'TC34 - an empty string is quoted as an empty pair of double quotes' {
        script:ConvertTo-Win32QuotedArgument -Value '' | Should -Be '""'
    }

    # A real-child-process, end-to-end round-trip of these tricky arguments (spaces, an embedded
    # quote, a trailing backslash) through Invoke-ExternalProcessWithTimeout's manual-quoting
    # fallback was verified manually against a real powershell.exe child - not included as an
    # automated test here because it requires writing and executing a temporary .ps1 file, which
    # depends on the local machine's PowerShell execution policy (unrelated to this fix) rather
    # than anything this code path controls.
}

Describe 'ConvertTo-PortList' {
    It 'TC45 - blank/empty value returns an empty, successful result' {
        $r = script:ConvertTo-PortList -Value ''
        $r.Success | Should -BeTrue
        @($r.Ports).Count | Should -Be 0
    }

    It 'TC46 - a single valid port is parsed' {
        $r = script:ConvertTo-PortList -Value '8080'
        $r.Success | Should -BeTrue
        @($r.Ports) | Should -Be @(8080)
    }

    It 'TC47 - multiple comma-separated ports, with surrounding whitespace, are all parsed in order' {
        $r = script:ConvertTo-PortList -Value ' 443, 8080 ,21 '
        $r.Success | Should -BeTrue
        @($r.Ports) | Should -Be @(443, 8080, 21)
    }

    It 'TC48 - a duplicate port is de-duplicated, keeping first-seen order' {
        $r = script:ConvertTo-PortList -Value '8080,443,8080'
        $r.Success | Should -BeTrue
        @($r.Ports) | Should -Be @(8080, 443)
    }

    It 'TC49 - a non-numeric token fails with a specific error naming it' {
        $r = script:ConvertTo-PortList -Value '443,notaport'
        $r.Success      | Should -BeFalse
        $r.ErrorMessage | Should -Match 'notaport'
    }

    It 'TC50 - a port of 0 is out of range and fails' {
        $r = script:ConvertTo-PortList -Value '0'
        $r.Success | Should -BeFalse
    }

    It 'TC51 - a port of 65536 is out of range and fails' {
        $r = script:ConvertTo-PortList -Value '65536'
        $r.Success | Should -BeFalse
    }

    It 'TC52 - a port of exactly 65535 (upper bound) succeeds' {
        $r = script:ConvertTo-PortList -Value '65535'
        $r.Success | Should -BeTrue
        @($r.Ports) | Should -Be @(65535)
    }

    It 'TC53 - trailing/leading commas and blank tokens between commas are ignored, not treated as errors' {
        $r = script:ConvertTo-PortList -Value ',443,,8080,'
        $r.Success | Should -BeTrue
        @($r.Ports) | Should -Be @(443, 8080)
    }
}

Describe 'Find-PlinkExecutable' {
    # Per user direction: check PATH, then the project root, then Program Files (x86), then
    # Program Files, in that order. Get-Command/Test-Path are mocked so each tier can be tested
    # in isolation, deterministically, regardless of what's actually installed on the machine
    # running these tests.

    It 'TC36 - found on PATH - returned directly, no further locations checked' {
        Mock Get-Command { [PSCustomObject]@{ Source = 'C:\PATH\plink.exe' } } -ParameterFilter { $Name -eq 'plink.exe' }
        Mock Test-Path { throw 'Should not check any further location when found on PATH' }
        script:Find-PlinkExecutable | Should -Be 'C:\PATH\plink.exe'
    }

    It 'TC37 - not on PATH, found at the project root' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'plink.exe' }
        Mock Test-Path { $LiteralPath -like '*\..\..\plink.exe' } -ParameterFilter { $PathType -eq 'Leaf' }
        Mock Resolve-Path { [PSCustomObject]@{ Path = 'C:\Code\aPePAS\plink.exe' } }
        script:Find-PlinkExecutable | Should -Be 'C:\Code\aPePAS\plink.exe'
    }

    It 'TC38 - not on PATH or project root, found in Program Files (x86)' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'plink.exe' }
        Mock Test-Path { $LiteralPath -like '*PuTTY\plink.exe' -and $LiteralPath -like '*(x86)*' } -ParameterFilter { $PathType -eq 'Leaf' }
        Mock Resolve-Path { [PSCustomObject]@{ Path = 'C:\Program Files (x86)\PuTTY\plink.exe' } }
        script:Find-PlinkExecutable | Should -Be 'C:\Program Files (x86)\PuTTY\plink.exe'
    }

    It 'TC39 - not found anywhere - returns $null' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'plink.exe' }
        Mock Test-Path { $false } -ParameterFilter { $PathType -eq 'Leaf' }
        script:Find-PlinkExecutable | Should -BeNullOrEmpty
    }
}

Describe 'Test-LinuxSshAuth - plink trust-on-first-use retry' {
    # Per user report and live verification: plink has no CLI flag to blindly trust an unknown
    # host key, but its "host key is not cached" failure always includes the fingerprint it
    # computed - Test-LinuxSshAuth parses that out and retries once with -hostkey set to it,
    # confirmed live to succeed against a genuinely fresh (never-before-seen) real host.

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Find-PlinkExecutable { 'C:\fake\plink.exe' }
    }

    It 'TC41 - an unrecognized host key is retried once with -hostkey, and the retry result is returned' {
        $callCount = 0
        Mock Invoke-ExternalProcessWithTimeout {
            $script:callCount++
            if ($script:callCount -eq 1) {
                return @{
                    TimedOut = $false; ExitCode = 1; StdOut = ''
                    StdErr   = "The host key is not cached for this server:`n  test.example.com (port 22)`nThe server's ssh-ed25519 key fingerprint is:`n  ssh-ed25519 255 SHA256:AbCdEf1234567890+/=`nConnection abandoned.`nFATAL ERROR: Cannot confirm a host key in batch mode"
                }
            }
            return @{ TimedOut = $false; ExitCode = 0; StdOut = ''; StdErr = '' }
        }
        $script:callCount = 0

        $result = script:Test-LinuxSshAuth -Address 'test.example.com' -Account 'user1' -Password 'pw' -TimeoutSec 15
        $result.Success | Should -BeTrue
        Should -Invoke Invoke-ExternalProcessWithTimeout -Times 2
        Should -Invoke Invoke-ExternalProcessWithTimeout -Times 1 -ParameterFilter {
            $ArgumentList -contains '-hostkey' -and $ArgumentList -contains 'SHA256:AbCdEf1234567890+/='
        }
    }

    It 'TC42 - a non-host-key failure (e.g. wrong password) is not retried' {
        Mock Invoke-ExternalProcessWithTimeout {
            @{ TimedOut = $false; ExitCode = 1; StdOut = ''; StdErr = "Access denied`nFATAL ERROR: Configured password was not accepted" }
        }
        $result = script:Test-LinuxSshAuth -Address 'test.example.com' -Account 'user1' -Password 'wrongpw' -TimeoutSec 15
        $result.Success      | Should -BeFalse
        $result.ErrorMessage | Should -Match 'Access denied'
        Should -Invoke Invoke-ExternalProcessWithTimeout -Times 1
    }

    It 'TC43 - a host-key failure whose message has no parseable fingerprint is not retried' {
        Mock Invoke-ExternalProcessWithTimeout {
            @{ TimedOut = $false; ExitCode = 1; StdOut = ''; StdErr = 'host key is not cached for this server, but no fingerprint line here' }
        }
        $result = script:Test-LinuxSshAuth -Address 'test.example.com' -Account 'user1' -Password 'pw' -TimeoutSec 15
        $result.Success | Should -BeFalse
        Should -Invoke Invoke-ExternalProcessWithTimeout -Times 1
    }
}

Describe 'Resolve-VaultPassword' {

    BeforeEach {
        Mock Write-CyberArkLog { }
    }

    It 'TC11 - exact Address+Account match found - retrieves and returns the password, SafeName, and Username' {
        Mock Invoke-CyberArkAPI {
            param($Method, $Endpoint)
            if ($Method -eq 'GET') {
                script:New-VaultAccountsResponse -Accounts @(
                    [PSCustomObject]@{ id = '123_456'; address = 'server1.corp.local'; userName = 'svc_account'; safeName = 'ServerAdmins' }
                )
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = 'S3cr3tPass'; RawResponse = 'S3cr3tPass' }
            }
        }
        $r = Resolve-VaultPassword -Token $script:MockToken -Address 'server1.corp.local' -Account 'svc_account'
        $r.Success  | Should -BeTrue
        $r.Password | Should -Be 'S3cr3tPass'
        $r.SafeName | Should -Be 'ServerAdmins'
        $r.Username | Should -Be 'svc_account'
    }

    It 'TC12 - no matching account - Success=$false, ErrorMessage=Password Not Found, SafeName/Username blank' {
        Mock Invoke-CyberArkAPI { script:New-VaultAccountsResponse -Accounts @() }
        $r = Resolve-VaultPassword -Token $script:MockToken -Address 'server1.corp.local' -Account 'svc_account'
        $r.Success      | Should -BeFalse
        $r.ErrorMessage | Should -Be 'Password Not Found'
        $r.SafeName     | Should -Be ''
        $r.Username     | Should -Be ''
    }

    It 'TC13 - account found but address does not match exactly - not treated as a match' {
        Mock Invoke-CyberArkAPI { script:New-VaultAccountsResponse -Accounts @(
            [PSCustomObject]@{ id = '1'; address = 'other-server.corp.local'; userName = 'svc_account' }
        ) }
        $r = Resolve-VaultPassword -Token $script:MockToken -Address 'server1.corp.local' -Account 'svc_account'
        $r.Success | Should -BeFalse
    }

    It 'TC14 - search API call fails - Success=$false, ErrorMessage=Password Not Found' {
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 500 -ErrorMessage 'Server Error' }
        $r = Resolve-VaultPassword -Token $script:MockToken -Address 'server1.corp.local' -Account 'svc_account'
        $r.Success      | Should -BeFalse
        $r.ErrorMessage | Should -Be 'Password Not Found'
    }

    It 'TC15 - account found but Password/Retrieve call fails - Success=$false, ErrorMessage=Password Not Found' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                script:New-VaultAccountsResponse -Accounts @([PSCustomObject]@{ id = '1'; address = 'server1.corp.local'; userName = 'svc_account' })
            } else {
                script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden'
            }
        }
        $r = Resolve-VaultPassword -Token $script:MockToken -Address 'server1.corp.local' -Account 'svc_account'
        $r.Success      | Should -BeFalse
        $r.ErrorMessage | Should -Be 'Password Not Found'
    }

    It 'TC16 - multiple matches - uses the first without throwing' {
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') {
                script:New-VaultAccountsResponse -Accounts @(
                    [PSCustomObject]@{ id = '1'; address = 'server1.corp.local'; userName = 'svc_account' }
                    [PSCustomObject]@{ id = '2'; address = 'server1.corp.local'; userName = 'svc_account' }
                )
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = 'FirstMatchPass'; RawResponse = 'FirstMatchPass' }
            }
        }
        $r = Resolve-VaultPassword -Token $script:MockToken -Address 'server1.corp.local' -Account 'svc_account'
        $r.Success  | Should -BeTrue
        $r.Password | Should -Be 'FirstMatchPass'
    }
}

Describe 'Invoke-CustomTestConnectivity - validation' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'TC17 - empty Address - Failures=1' {
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ ServerType = 'Windows'; Account = 'user1' }
        $r.Failures | Should -Be 1
    }

    It 'TC18 - invalid ServerType - Failures=1' {
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server1'; ServerType = 'Solaris'; Account = 'user1' }
        $r.Failures | Should -Be 1
    }

    It 'TC19 - empty Account - Failures=1' {
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server1'; ServerType = 'Windows' }
        $r.Failures | Should -Be 1
    }

    It 'TC54 - invalid AdditionalPorts token - Failures=1, no port/auth calls, error names the bad token' {
        Mock Test-TcpPortOpen { throw 'Should not be called when AdditionalPorts is invalid' }
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server1'; ServerType = 'Windows'; Account = 'user1'; Password = 'pw'; AdditionalPorts = '443,notaport' }
        $r.Failures | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'notaport'
        Should -Invoke Test-TcpPortOpen -Times 0
    }
}

Describe 'Invoke-CustomTestConnectivity - DNS failure' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Resolve-ConnectivityTarget { return @{ Success = $false; FQDN = ''; IPAddress = ''; ErrorMessage = "DNS resolution failed for 'bogus': test error" } }
        Mock Test-TcpPortOpen { throw 'Should not be called when DNS fails' }
        Mock Test-WindowsSmbAuth { throw 'Should not be called when DNS fails' }
        Mock Test-LinuxSshAuth { throw 'Should not be called when DNS fails' }
    }

    It 'TC20 - DNS failure produces a Fail row with DNSMatch=$false and no port/auth calls' {
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'bogus'; ServerType = 'Windows'; Account = 'user1'; Password = 'x' }
        $r.Failures | Should -Be 1
        $r.Results[0].DNSMatch       | Should -BeFalse
        $r.Results[0].AuthStatus     | Should -Be 'Fail'
        $r.Results[0].ErrorMessage   | Should -Match 'DNS resolution failed'
        # No vault lookup is attempted before DNS resolves, so these stay blank.
        $r.Results[0].Safe           | Should -Be ''
        $r.Results[0].Username       | Should -Be ''
        $r.Results[0].PasswordSource | Should -Be ''
        Should -Invoke Test-TcpPortOpen -Times 0
    }
}

Describe 'Invoke-CustomTestConnectivity - Windows flow' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Resolve-ConnectivityTarget { return @{ Success = $true; FQDN = 'server1.corp.local'; IPAddress = '10.0.0.1'; ErrorMessage = '' } }
    }

    It 'TC21 - all 4 ports open, auth succeeds - PortCheck lists all 4 in order, Protocol=RPC, AuthStatus=Success' {
        Mock Test-TcpPortOpen { return $true }
        Mock Test-WindowsSmbAuth { return @{ Success = $true; ErrorMessage = '' } }
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server1'; ServerType = 'Windows'; Account = 'user1'; Password = 'pw' }
        $r.Results[0].PortCheck  | Should -Be '135(True),139(True),445(True),3389(True)'
        $r.Results[0].Protocol   | Should -Be 'RPC'
        $r.Results[0].AuthStatus | Should -Be 'Success'
        $r.Successes | Should -Be 1
        # A password was supplied directly, so no vault account was used.
        $r.Results[0].Safe           | Should -Be ''
        $r.Results[0].Username       | Should -Be ''
        $r.Results[0].PasswordSource | Should -Be 'Provided'
    }

    It 'TC22 - port 445 closed - no auth attempted, AuthStatus=Fail, ErrorMessage notes port 445' {
        Mock Test-TcpPortOpen { param($Port) return ($Port -ne 445) }
        Mock Test-WindowsSmbAuth { throw 'Should not be called when 445 is closed' }
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server1'; ServerType = 'Windows'; Account = 'user1'; Password = 'pw' }
        $r.Results[0].PortCheck    | Should -Be '135(True),139(True),445(False),3389(True)'
        $r.Results[0].AuthStatus   | Should -Be 'Fail'
        $r.Results[0].ErrorMessage | Should -Match '445'
        Should -Invoke Test-WindowsSmbAuth -Times 0
    }

    It 'TC23 - 445 open but auth fails - AuthStatus=Fail with the auth error message' {
        Mock Test-TcpPortOpen { return $true }
        Mock Test-WindowsSmbAuth { return @{ Success = $false; ErrorMessage = 'Logon failure: unknown user name or bad password.' } }
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server1'; ServerType = 'Windows'; Account = 'user1'; Password = 'pw' }
        $r.Results[0].AuthStatus   | Should -Be 'Fail'
        $r.Results[0].ErrorMessage | Should -Be 'Logon failure: unknown user name or bad password.'
    }

    It 'TC55 - AdditionalPorts are appended after the built-in 4, tested and reported' {
        Mock Test-TcpPortOpen { param($Port) return ($Port -in @(135, 139, 445, 3389, 8080)) }
        Mock Test-WindowsSmbAuth { return @{ Success = $true; ErrorMessage = '' } }
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server1'; ServerType = 'Windows'; Account = 'user1'; Password = 'pw'; AdditionalPorts = '8080,9443' }
        $r.Results[0].PortCheck | Should -Be '135(True),139(True),445(True),3389(True),8080(True),9443(False)'
    }

    It 'TC56 - an AdditionalPorts value that duplicates a built-in port is not tested or reported twice' {
        $script:CallCount = 0
        Mock Test-TcpPortOpen {
            param($Port)
            $script:CallCount++
            return $true
        }
        Mock Test-WindowsSmbAuth { return @{ Success = $true; ErrorMessage = '' } }
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server1'; ServerType = 'Windows'; Account = 'user1'; Password = 'pw'; AdditionalPorts = '445,8080' }
        $r.Results[0].PortCheck | Should -Be '135(True),139(True),445(True),3389(True),8080(True)'
        $script:CallCount | Should -Be 5   # 4 built-in + 8080 only - 445 not tested a second time
    }

    It 'TC57 - blank AdditionalPorts leaves the existing 4-port behavior unchanged' {
        Mock Test-TcpPortOpen { return $true }
        Mock Test-WindowsSmbAuth { return @{ Success = $true; ErrorMessage = '' } }
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server1'; ServerType = 'Windows'; Account = 'user1'; Password = 'pw'; AdditionalPorts = '' }
        $r.Results[0].PortCheck | Should -Be '135(True),139(True),445(True),3389(True)'
    }
}

Describe 'Invoke-CustomTestConnectivity - Linux flow' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Resolve-ConnectivityTarget { return @{ Success = $true; FQDN = 'server2.corp.local'; IPAddress = '10.0.0.2'; ErrorMessage = '' } }
    }

    It 'TC24 - port 22 open, auth succeeds - PortCheck=22(True), Protocol=SSH, AuthStatus=Success' {
        Mock Test-TcpPortOpen { return $true }
        Mock Test-LinuxSshAuth { return @{ Success = $true; ErrorMessage = '' } }
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server2'; ServerType = 'Linux'; Account = 'user1'; Password = 'pw' }
        $r.Results[0].PortCheck  | Should -Be '22(True)'
        $r.Results[0].Protocol   | Should -Be 'SSH'
        $r.Results[0].AuthStatus | Should -Be 'Success'
    }

    It 'TC25 - port 22 closed - no auth attempted' {
        Mock Test-TcpPortOpen { return $false }
        Mock Test-LinuxSshAuth { throw 'Should not be called when 22 is closed' }
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server2'; ServerType = 'Linux'; Account = 'user1'; Password = 'pw' }
        $r.Results[0].PortCheck    | Should -Be '22(False)'
        $r.Results[0].AuthStatus   | Should -Be 'Fail'
        $r.Results[0].ErrorMessage | Should -Match '22'
        Should -Invoke Test-LinuxSshAuth -Times 0
    }

    It 'TC58 - AdditionalPorts are appended after the built-in port 22 on Linux too' {
        Mock Test-TcpPortOpen { param($Port) return ($Port -ne 9999) }
        Mock Test-LinuxSshAuth { return @{ Success = $true; ErrorMessage = '' } }
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server2'; ServerType = 'Linux'; Account = 'user1'; Password = 'pw'; AdditionalPorts = '2222,9999' }
        $r.Results[0].PortCheck | Should -Be '22(True),2222(True),9999(False)'
    }

    It 'TC26 - neither PS7 nor plink available - ErrorMessage reports it verbatim' {
        Mock Test-TcpPortOpen { return $true }
        Mock Test-LinuxSshAuth { return @{ Success = $false; ErrorMessage = 'Plink or PS7 needed for auth test' } }
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server2'; ServerType = 'Linux'; Account = 'user1'; Password = 'pw' }
        $r.Results[0].AuthStatus   | Should -Be 'Fail'
        $r.Results[0].ErrorMessage | Should -Be 'Plink or PS7 needed for auth test'
    }
}

Describe 'Invoke-CustomTestConnectivity - vault password fallback' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Resolve-ConnectivityTarget { return @{ Success = $true; FQDN = 'server1.corp.local'; IPAddress = '10.0.0.1'; ErrorMessage = '' } }
        Mock Test-TcpPortOpen { return $true }
    }

    It 'TC27 - Password supplied in InputData - vault is never queried' {
        Mock Resolve-VaultPassword { throw 'Should not be called when a password is supplied' }
        Mock Test-WindowsSmbAuth { return @{ Success = $true; ErrorMessage = '' } }
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server1'; ServerType = 'Windows'; Account = 'user1'; Password = 'suppliedpw' }
        $r.Results[0].AuthStatus | Should -Be 'Success'
        Should -Invoke Resolve-VaultPassword -Times 0
        $r.Results[0].PasswordSource | Should -Be 'Provided'
        $r.Results[0].Safe           | Should -Be ''
        $r.Results[0].Username       | Should -Be ''
    }

    It 'TC28 - Password blank, vault lookup succeeds - the retrieved password is used, and Safe/Username/PasswordSource report the vaulted account' {
        Mock Resolve-VaultPassword { return @{ Success = $true; Password = 'VaultPass1'; SafeName = 'ServerAdmins'; Username = 'user1'; ErrorMessage = '' } }
        $capturedPassword = $null
        Mock Test-WindowsSmbAuth {
            param($Address, $Account, $Password)
            Set-Variable -Name capturedPassword -Value $Password -Scope Script
            return @{ Success = $true; ErrorMessage = '' }
        }
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server1'; ServerType = 'Windows'; Account = 'user1' }
        $script:capturedPassword | Should -Be 'VaultPass1'
        $r.Results[0].Safe           | Should -Be 'ServerAdmins'
        $r.Results[0].Username       | Should -Be 'user1'
        $r.Results[0].PasswordSource | Should -Be 'Vault'
    }

    It 'TC29 - Password blank, vault lookup fails - AuthStatus=Fail, ErrorMessage=Password Not Found, no auth attempt made even though the port is open' {
        Mock Resolve-VaultPassword { return @{ Success = $false; Password = ''; SafeName = ''; Username = ''; ErrorMessage = 'Password Not Found' } }
        Mock Test-WindowsSmbAuth { throw 'Should not be called when no password is available' }
        $r = Invoke-CustomTestConnectivity -Token $script:MockToken -InputData @{ Address = 'server1'; ServerType = 'Windows'; Account = 'user1' }
        $r.Results[0].AuthStatus   | Should -Be 'Fail'
        $r.Results[0].ErrorMessage | Should -Be 'Password Not Found'
        Should -Invoke Test-WindowsSmbAuth -Times 0
        # A vault lookup was attempted (no password was supplied) even though it found nothing.
        $r.Results[0].PasswordSource | Should -Be 'Vault'
        $r.Results[0].Safe           | Should -Be ''
        $r.Results[0].Username       | Should -Be ''
    }
}
