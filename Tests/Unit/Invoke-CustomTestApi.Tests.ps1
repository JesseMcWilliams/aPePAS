#Requires -Version 5.1
<#
.SYNOPSIS
    Pester unit tests for APIModules\Custom\Invoke-CustomTestApi.ps1.
    No CyberArk connection required: Invoke-WebRequest and every driver prompt are mocked.

.NOTES
    Invoke-CustomTestApi is an interactive loop that calls Invoke-WebRequest directly (not
    Invoke-CyberArkAPI). The driver helpers it relies on (Show-FieldPrompt, Read-MenuChoice,
    Invoke-TokenRefresh, Invoke-TokenInvalidate, Invoke-FileWriteWithRetry) live in the Driver
    scripts, so minimal stubs are defined here and then mocked. The prompts are fed from
    queues ($script:Q) so each test scripts the whole "session". An empty next-action queue
    answers B (back), which ends the loop.
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Custom\Invoke-CustomTestApi.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'CustomTestApiTests' -MinLevel 'ERROR'

    # Stubs for the driver functions (defined in Driver\*.ps1, not loaded by unit tests)
    function script:Show-FieldPrompt { param($Label, $Description, [switch]$Required) }
    function script:Read-MenuChoice { param($Prompt) }
    function script:Invoke-TokenRefresh { }
    function script:Invoke-TokenInvalidate { }
    function script:Invoke-FileWriteWithRetry { param($Path, $Action) }

    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault/'
    }

    function script:New-WebResponse {
        param([int]$StatusCode = 200, [string]$Content = '{"ok":true}')
        return [PSCustomObject]@{
            StatusCode = $StatusCode
            Content    = $Content
            Headers    = @{ 'X-Test' = 'one'; 'X-Multi' = @('a', 'b') }
        }
    }

    function script:New-HttpErr {
        param([int]$StatusCode, [string]$Body = '{"ErrorCode":"X","ErrorMessage":"bad"}', [string]$Message = 'The remote server returned an error')
        return [PSCustomObject]@{ StatusCode = $StatusCode; Body = $Body; Headers = @{ 'X-Err' = 'e' }; Message = $Message }
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

Describe 'Invoke-CustomTestApi' {

    BeforeEach {
        $script:ActiveProfile = [PSCustomObject]@{ IgnoreSSL = $false }
        $script:SessionToken  = $null

        # One scripted "session": each queue is consumed in prompt order.
        $script:Q = @{
            Method = [System.Collections.Queue]::new()
            Path   = [System.Collections.Queue]::new()
            Query  = [System.Collections.Queue]::new()
            Body   = [System.Collections.Queue]::new()
            Next   = [System.Collections.Queue]::new()
        }
        $script:PathPrompts = 0
        $script:IwrBehavior = @(New-WebResponse)   # one entry per call; the last repeats
        $script:IwrCalls    = 0

        Mock Write-Host {}
        Mock Write-CyberArkLog {}
        Mock Disable-SSLValidation {}
        Mock Update-CyberArkLastApiCallTime {}
        Mock Read-Host { if ($script:Q.Method.Count) { $script:Q.Method.Dequeue() } else { '' } }
        Mock Show-FieldPrompt {
            switch ($Label) {
                'API Path'     { $script:PathPrompts++; if ($script:Q.Path.Count)  { $script:Q.Path.Dequeue() }  else { '' } }
                'Query Params' { if ($script:Q.Query.Count) { $script:Q.Query.Dequeue() } else { '' } }
                'Body (JSON)'  { if ($script:Q.Body.Count)  { $script:Q.Body.Dequeue() }  else { '' } }
            }
        }
        Mock Read-MenuChoice { if ($script:Q.Next.Count) { $script:Q.Next.Dequeue() } else { 'B' } }
        Mock Invoke-TokenInvalidate {}
        Mock Invoke-TokenRefresh { $true }
        Mock Get-CyberArkHttpErrorResponse { $null }
        Mock Invoke-WebRequest {
            $i = [Math]::Min($script:IwrCalls, $script:IwrBehavior.Count - 1)
            $script:IwrCalls++
            $b = $script:IwrBehavior[$i]
            if ($b -is [string]) { throw $b }
            return $b
        }
    }

    Context 'ModuleMeta' {
        It 'TA01 - metadata: Custom/TestApi, no WhatIf, no input file, no automation' {
            $ModuleMeta.Category           | Should -Be 'Custom'
            $ModuleMeta.Action             | Should -Be 'TestApi'
            $ModuleMeta.SupportsWhatIf     | Should -BeFalse
            $ModuleMeta.AcceptsInputFile   | Should -BeFalse
            $ModuleMeta.SupportsAutomation | Should -BeFalse
            $ModuleMeta.SupportedSystems   | Should -Contain 'ISPSS'
            $ModuleMeta.SupportedSystems   | Should -Contain 'SelfHosted'
        }
    }

    Context 'Successful requests and result shape' {
        It 'TA02 - single GET success returns the full result object shape' {
            $script:Q.Path.Enqueue('/PasswordVault/api/Safes')
            $r = Invoke-CustomTestApi -Token $script:MockToken
            $r.ModuleName     | Should -Be 'Test API'
            $r.Category       | Should -Be 'Custom'
            $r.Action         | Should -Be 'TestApi'
            $r.ItemsProcessed | Should -Be 1
            $r.Successes      | Should -Be 1
            $r.Failures       | Should -Be 0
            $r.IsFatal        | Should -BeFalse
            $r.Errors.Count   | Should -Be 0
            $r.Results.Count  | Should -Be 1
            $r.Results[0].Method     | Should -Be 'GET'
            $r.Results[0].Path       | Should -Be '/PasswordVault/api/Safes'
            $r.Results[0].StatusCode | Should -Be 200
            $r.Results[0].Success    | Should -BeTrue
        }

        It 'TA03 - strips the trailing /PasswordVault from BaseURL, adds a leading slash, and sends the token headers' {
            $script:Q.Path.Enqueue('  PasswordVault/api/Safes  ')
            Invoke-CustomTestApi -Token $script:MockToken | Out-Null
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://pvwa.company.com/PasswordVault/api/Safes' -and
                $Method -eq 'GET' -and
                $Headers['Authorization'] -eq 'Bearer mock-token'
            }
            Should -Invoke Update-CyberArkLastApiCallTime -Times 1 -Exactly
        }

        It 'TA04 - appends the query string for GET, using & when the path already has a ?' {
            $script:Q.Path.Enqueue('/api/a');     $script:Q.Query.Enqueue('search=x&limit=5')
            $script:Q.Path.Enqueue('/api/b?x=1'); $script:Q.Query.Enqueue('y=2')
            $script:Q.Next.Enqueue('A')
            Invoke-CustomTestApi -Token $script:MockToken | Out-Null
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://pvwa.company.com/api/a?search=x&limit=5' }
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://pvwa.company.com/api/b?x=1&y=2' }
        }

        It 'TA05 - adds a trailing slash when the last path segment contains a dot' {
            $script:Q.Path.Enqueue('/api/Accounts/12_3.4')
            Invoke-CustomTestApi -Token $script:MockToken | Out-Null
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://pvwa.company.com/api/Accounts/12_3.4/' }
        }

        It 'TA06 - method selection: numbers, names, and default GET' {
            foreach ($m in '2', '3', 'patch', '5', 'bogus') {
                $script:Q.Method.Enqueue($m)
                $script:Q.Path.Enqueue('/x')
            }
            foreach ($n in 1..4) { $script:Q.Next.Enqueue('A') }   # the 5th request ends on the default B
            $r = Invoke-CustomTestApi -Token $script:MockToken
            ($r.Results | ForEach-Object { $_.Method }) -join ',' | Should -Be 'POST,PUT,PATCH,DELETE,GET'
        }
    }

    Context 'Request body' {
        It 'TA07 - POST body is parsed and re-serialised compressed with a JSON content type' {
            $script:Q.Method.Enqueue('POST'); $script:Q.Path.Enqueue('/api/Safes')
            $script:Q.Body.Enqueue('{ "safeName" : "T1",  "n": 1 }')
            Invoke-CustomTestApi -Token $script:MockToken | Out-Null
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'POST' -and $Body -eq '{"safeName":"T1","n":1}' -and $ContentType -eq 'application/json'
            }
        }

        It 'TA08 - invalid JSON body is sent as-is (trimmed)' {
            $script:Q.Method.Enqueue('PUT'); $script:Q.Path.Enqueue('/api/x')
            $script:Q.Body.Enqueue('  not json {  ')
            Invoke-CustomTestApi -Token $script:MockToken | Out-Null
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Body -eq 'not json {' }
        }

        It 'TA09 - a blank body sends no Body parameter, and DELETE is never prompted for a body' {
            $script:Q.Method.Enqueue('POST'); $script:Q.Path.Enqueue('/api/x'); $script:Q.Body.Enqueue('')
            $script:Q.Method.Enqueue('DELETE'); $script:Q.Path.Enqueue('/api/y')
            $script:Q.Next.Enqueue('A')
            Invoke-CustomTestApi -Token $script:MockToken | Out-Null
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter { -not $PSBoundParameters.ContainsKey('Body') }
            Should -Invoke Show-FieldPrompt -Times 1 -Exactly -ParameterFilter { $Label -eq 'Body (JSON)' }
        }
    }

    Context 'HTTP failures' {
        It 'TA10 - HTTP error records a failure with the parsed status and message (not fatal)' {
            $script:IwrBehavior = @('boom')
            Mock Get-CyberArkHttpErrorResponse { New-HttpErr -StatusCode 404 -Message 'Not Found' }
            $script:Q.Path.Enqueue('/api/missing')
            $r = Invoke-CustomTestApi -Token $script:MockToken
            $r.ItemsProcessed         | Should -Be 1
            $r.Successes              | Should -Be 0
            $r.Failures               | Should -Be 1
            $r.IsFatal                | Should -BeFalse
            $r.Results[0].StatusCode  | Should -Be 404
            $r.Results[0].Success     | Should -BeFalse
            $r.Errors[0].ErrorMessage | Should -Be 'Not Found'
            $r.Errors[0].InputData.Path   | Should -Be '/api/missing'
            $r.Errors[0].InputData.Method | Should -Be 'GET'
        }

        It 'TA11 - a non-HTTP error (status 0) uses the exception text and is not fatal' {
            $script:IwrBehavior = @('connection refused')
            $script:Q.Path.Enqueue('/api/x')
            $r = Invoke-CustomTestApi -Token $script:MockToken
            $r.Failures               | Should -Be 1
            $r.IsFatal                | Should -BeFalse
            $r.Results[0].StatusCode  | Should -Be 0
            $r.Errors[0].ErrorMessage | Should -Match 'connection refused'
        }

        It 'TA12 - an HTTP error with an empty message falls back to HTTP plus the status code' {
            $script:IwrBehavior = @('x')
            Mock Get-CyberArkHttpErrorResponse { [PSCustomObject]@{ StatusCode = 500; Body = ''; Headers = @{}; Message = $null } }
            $script:Q.Path.Enqueue('/api/x')
            $r = Invoke-CustomTestApi -Token $script:MockToken
            $r.Errors[0].ErrorMessage | Should -Be 'HTTP 500'
        }
    }

    Context '401 handling' {
        It 'TA13 - 401 invalidates the token, refreshes, retries once with the new token and succeeds' {
            $script:IwrBehavior = @('unauthorized', (New-WebResponse))
            Mock Get-CyberArkHttpErrorResponse { New-HttpErr -StatusCode 401 -Message 'Unauthorized' }
            $script:SessionToken = [PSCustomObject]@{
                Headers = @{ Authorization = 'Bearer new-token' }
                BaseURL = $script:MockToken.BaseURL
            }
            $script:Q.Path.Enqueue('/api/x')
            $r = Invoke-CustomTestApi -Token $script:MockToken
            Should -Invoke Invoke-TokenInvalidate -Times 1 -Exactly
            Should -Invoke Invoke-TokenRefresh    -Times 1 -Exactly
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Headers['Authorization'] -eq 'Bearer new-token' }
            $r.Successes      | Should -Be 1
            $r.Failures       | Should -Be 0
            $r.IsFatal        | Should -BeFalse
            $r.ItemsProcessed | Should -Be 1
        }

        It 'TA14 - 401 with a failed refresh is fatal and records no result' {
            $script:IwrBehavior = @('unauthorized')
            Mock Get-CyberArkHttpErrorResponse { New-HttpErr -StatusCode 401 }
            Mock Invoke-TokenRefresh { $false }
            $script:Q.Path.Enqueue('/api/x')
            $r = Invoke-CustomTestApi -Token $script:MockToken
            $r.IsFatal        | Should -BeTrue
            $r.ItemsProcessed | Should -Be 0
            $r.Results.Count  | Should -Be 0
            $r.Errors.Count   | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        }

        It 'TA15 - a second 401 after the retry is a plain failure, not fatal, with no further refresh' {
            $script:IwrBehavior = @('unauthorized')
            Mock Get-CyberArkHttpErrorResponse { New-HttpErr -StatusCode 401 -Message 'Unauthorized' }
            $script:SessionToken = $script:MockToken
            $script:Q.Path.Enqueue('/api/x')
            $r = Invoke-CustomTestApi -Token $script:MockToken
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
            Should -Invoke Invoke-TokenRefresh -Times 1 -Exactly
            $r.IsFatal  | Should -BeFalse
            $r.Failures | Should -Be 1
            $r.Results[0].StatusCode | Should -Be 401
        }
    }

    Context 'Menu loop' {
        It 'TA16 - [A] runs another request and accumulates the counts' {
            $script:Q.Path.Enqueue('/api/a'); $script:Q.Path.Enqueue('/api/b')
            $script:Q.Next.Enqueue('a')
            $r = Invoke-CustomTestApi -Token $script:MockToken
            $r.ItemsProcessed | Should -Be 2
            $r.Successes      | Should -Be 2
            ($r.Results | ForEach-Object { $_.Path }) -join ',' | Should -Be '/api/a,/api/b'
        }

        It 'TA17 - [R] retry reuses the method and path without re-prompting for them but asks for the body again' {
            $script:Q.Method.Enqueue('POST'); $script:Q.Path.Enqueue('/api/x')
            $script:Q.Body.Enqueue('{"a":1}'); $script:Q.Body.Enqueue('{"a":2}')
            $script:Q.Next.Enqueue('R')
            $r = Invoke-CustomTestApi -Token $script:MockToken
            $script:PathPrompts | Should -Be 1
            Should -Invoke Read-Host -Times 1 -Exactly
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Body -eq '{"a":1}' }
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Body -eq '{"a":2}' }
            $r.ItemsProcessed | Should -Be 2
        }

        It 'TA18 - a blank API path re-prompts instead of sending a request' {
            $script:Q.Path.Enqueue(''); $script:Q.Path.Enqueue('/api/x')
            $r = Invoke-CustomTestApi -Token $script:MockToken
            $script:PathPrompts | Should -Be 2
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            $r.ItemsProcessed | Should -Be 1
        }

        It 'TA19 - [V] toggles verbose and the verbose output masks the Authorization header value' {
            $script:Q.Path.Enqueue('/api/a'); $script:Q.Path.Enqueue('/api/b')
            $script:Q.Next.Enqueue('V')   # toggles verbose on, then the second request is shown verbosely
            Invoke-CustomTestApi -Token $script:MockToken | Out-Null
            Should -Invoke Write-Host -Times 1 -ParameterFilter { "$Object" -match '^\s+Authorization: Bearer m\*\*\*$' }
            Should -Invoke Write-Host -Times 0 -ParameterFilter { "$Object" -match 'mock-token' }
        }
    }

    Context 'Save details [S]' {
        It 'TA20 - [S] writes the run history to OutputFolder with request header values masked' {
            $script:ActiveProfile = [PSCustomObject]@{ IgnoreSSL = $false; OutputFolder = $TestDrive }
            Mock Invoke-FileWriteWithRetry { & $Action; $true }
            $script:Q.Path.Enqueue('/api/x'); $script:Q.Path.Enqueue('/api/y')   # [S] loops back for another request
            $script:Q.Next.Enqueue('S')
            $r = Invoke-CustomTestApi -Token $script:MockToken
            $files = @(Get-ChildItem -Path $TestDrive -Filter 'TestAPI_*.json')
            $files.Count | Should -Be 1
            $json = Get-Content -LiteralPath $files[0].FullName -Raw
            $json | Should -Match '"StatusCode":\s*200'
            $json | Should -Match '"Authorization":\s*"\*\*\*"'
            $json | Should -Not -Match 'mock-token'
            $json | Should -Match '/api/x'
            $json | Should -Not -Match '/api/y'   # saved before the second request ran
            $r.ItemsProcessed | Should -Be 2
        }

        It 'TA21 - [S] when the user declines the write retry logs an ERROR and continues' {
            $script:ActiveProfile = [PSCustomObject]@{ IgnoreSSL = $false; OutputFolder = $TestDrive }
            Mock Invoke-FileWriteWithRetry { $false }
            $script:Q.Path.Enqueue('/api/x'); $script:Q.Path.Enqueue('/api/y')   # [S] loops back for another request
            $script:Q.Next.Enqueue('S')
            $r = Invoke-CustomTestApi -Token $script:MockToken
            Should -Invoke Write-CyberArkLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'ERROR' -and $Message -match 'save failed' }
            $r.IsFatal | Should -BeFalse
        }
    }

    Context 'SSL and WhatIf' {
        It 'TA22 - Disable-SSLValidation is called only when the active profile has IgnoreSSL set' {
            $script:Q.Path.Enqueue('/api/x')
            Invoke-CustomTestApi -Token $script:MockToken | Out-Null
            Should -Invoke Disable-SSLValidation -Times 0 -Exactly

            $script:ActiveProfile = [PSCustomObject]@{ IgnoreSSL = $true }
            $script:Q.Path.Enqueue('/api/x')
            Invoke-CustomTestApi -Token $script:MockToken | Out-Null
            Should -Invoke Disable-SSLValidation -Times 1 -Exactly
        }

        It 'TA23 - the -WhatIf switch is accepted but ignored: the request is still sent (documents current behavior)' {
            $script:Q.Path.Enqueue('/api/x')
            $r = Invoke-CustomTestApi -Token $script:MockToken -WhatIf
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            $r.Successes | Should -Be 1
        }
    }
}
