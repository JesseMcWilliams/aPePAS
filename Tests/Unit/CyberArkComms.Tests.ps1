#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for CyberArkComms.psm1.
    No CyberArk connection required.

.NOTES
    Invoke-CyberArkAPI error paths (401, 429, etc.) require System.Net.HttpWebResponse
    which cannot be instantiated in pure PowerShell. Those paths are covered by the
    API module tests (Invoke-SafesList.Tests.ps1) via mocking Invoke-CyberArkAPI.
#>

BeforeAll {
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Minimal token stub - no real credentials
    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-bearer-token'
        TokenType  = 'Bearer'
        Headers    = @{
            'Authorization' = 'Bearer mock-bearer-token'
            'Content-Type'  = 'application/json'
        }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'ISPSS'
        AuthMethod = 'ClientCredentials'
        BaseURL    = 'https://test.privilegecloud.cyberark.cloud'
    }

    # Suppress log output to console during tests
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'CommsTests' -MinLevel 'ERROR'
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────
Describe 'New-CyberArkQuery' {

    It 'C01 - empty hashtable returns empty string' {
        New-CyberArkQuery -Params @{} | Should -Be ''
    }

    It 'C02 - single param returns query string with leading ?' {
        $result = New-CyberArkQuery -Params @{ search = 'vault' }
        $result | Should -Be '?search=vault'
    }

    It 'C03 - multiple params all appear in the result' {
        $result = New-CyberArkQuery -Params @{ search = 'vault'; limit = '25' }
        $result | Should -Match '^\?'
        $result | Should -Match 'search=vault'
        $result | Should -Match 'limit=25'
    }

    It 'C04 - null value is omitted' {
        $result = New-CyberArkQuery -Params @{ search = 'vault'; filter = $null }
        $result | Should -Not -Match 'filter'
    }

    It 'C05 - empty string value is omitted' {
        $result = New-CyberArkQuery -Params @{ search = 'vault'; sort = '' }
        $result | Should -Not -Match 'sort'
    }

    It 'C06 - value with spaces is URL-encoded' {
        $result = New-CyberArkQuery -Params @{ filter = 'safeName eq My Safe' }
        $result | Should -Not -Match ' '
        $result | Should -Match 'filter='
    }

    It 'C07 - special characters in value are encoded' {
        $result = New-CyberArkQuery -Params @{ filter = 'name eq a&b' }
        # Ampersand should be encoded
        $result | Should -Match '%26'
    }

    It 'C34 - a period in a "search" value is percent-encoded as %2E, per user report' {
        # [Uri]::EscapeDataString treats '.' as unreserved (RFC 3986) and leaves it literal,
        # but CyberArk's ?search= endpoints fail to match on a literal period - confirmed live.
        $result = New-CyberArkQuery -Params @{ search = 'jdoe.admin' }
        $result | Should -Be '?search=jdoe%2Eadmin'
    }

    It 'C35 - a period in a "Search" value (capitalized key) is also percent-encoded' {
        # Invoke-EntitySearch's interactive picker uses -SearchParam 'Search' in several
        # Platforms modules, so the key match must be case-insensitive.
        $result = New-CyberArkQuery -Params @{ Search = '192.168.1.5' }
        $result | Should -Be '?Search=192%2E168%2E1%2E5'
    }

    It 'C36 - a period in a non-search value is left alone' {
        $result = New-CyberArkQuery -Params @{ filter = 'safeName eq My.Vault' }
        $result | Should -Match 'My\.Vault'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Join-CyberArkUrl' {

    It 'C08 - base and one segment joined with single slash' {
        Join-CyberArkUrl -Base 'https://host.example.com' -Segments @('/API/Safes') |
            Should -Be 'https://host.example.com/API/Safes'
    }

    It 'C09 - trailing slash on base is trimmed' {
        Join-CyberArkUrl -Base 'https://host.example.com/' -Segments @('/API/Safes') |
            Should -Be 'https://host.example.com/API/Safes'
    }

    It 'C10 - leading slash on segment is trimmed (no double slash)' {
        Join-CyberArkUrl -Base 'https://host.example.com' -Segments @('/API/Safes') |
            Should -Not -Match '//API'
    }

    It 'C11 - multiple segments all joined' {
        Join-CyberArkUrl -Base 'https://host.example.com' -Segments @('API', 'Safes', 'MySafe') |
            Should -Be 'https://host.example.com/API/Safes/MySafe'
    }

    It 'C12 - segment with trailing slash is trimmed' {
        Join-CyberArkUrl -Base 'https://host.example.com' -Segments @('API/Safes/') |
            Should -Be 'https://host.example.com/API/Safes'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'New-CyberArkSearchFilter' {

    It 'C13 - single criterion produces correct expression' {
        New-CyberArkSearchFilter -Criteria @{ safeName = 'MySafe' } |
            Should -Be 'safeName eq MySafe'
    }

    It 'C14 - two criteria joined with AND by default' {
        $result = New-CyberArkSearchFilter -Criteria @{ safeName = 'MySafe'; location = 'Root' }
        $result | Should -Match 'AND'
        $result | Should -Match 'safeName eq MySafe'
        $result | Should -Match 'location eq Root'
    }

    It 'C15 - value containing spaces is double-quoted' {
        New-CyberArkSearchFilter -Criteria @{ description = 'My Safe Description' } |
            Should -Match '"My Safe Description"'
    }

    It 'C16 - custom operator OR used when specified' {
        $result = New-CyberArkSearchFilter -Criteria @{ a = '1'; b = '2' } -Operator 'OR'
        $result | Should -Match 'OR'
        $result | Should -Not -Match 'AND'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-CyberArkAPI - success paths (mocked Invoke-WebRequest)' {

    BeforeAll {
        # Build a minimal success response object that Invoke-WebRequest returns.
        # UseBasicParsing returns an object with StatusCode, Content, Headers, and
        # RawContentStream - Headers is always present on a real response (confirmed live
        # against a real HttpListener - see Reference_Lessons-Learned.md Section 39),
        # so it's included here by default too rather than only on tests that need it.
        function script:New-MockWebResponse {
            param(
                [int]$StatusCode = 200,
                [object]$Body = '',
                [hashtable]$Headers = @{},
                [byte[]]$RawBytes = $null
            )
            $rawStream = if ($RawBytes) { [System.IO.MemoryStream]::new($RawBytes) } else { $null }
            return [PSCustomObject]@{
                StatusCode       = $StatusCode
                Content          = $Body
                Headers          = $Headers
                RawContentStream = $rawStream
            }
        }
    }

    It 'C17 - GET 200 with JSON body returns IsSuccess=$true and parsed Data' {
        $json = '{"value":[{"safeName":"TestSafe"}],"count":1}'
        Mock Invoke-WebRequest { script:New-MockWebResponse -StatusCode 200 -Body $json } `
            -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' -PageSize 0
        $r.IsSuccess     | Should -BeTrue
        $r.StatusCode    | Should -Be 200
        $r.DataType      | Should -Be 'JSON'
        $r.Data          | Should -Not -BeNullOrEmpty
        $r.Data.value[0].safeName | Should -Be 'TestSafe'
    }

    It 'C18 - POST 201 returns IsSuccess=$true and StatusCode=201' {
        $json = '{"id":"abc123","safeName":"NewSafe"}'
        Mock Invoke-WebRequest { script:New-MockWebResponse -StatusCode 201 -Body $json } `
            -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'POST' -Endpoint '/API/Safes' `
            -Body @{ safeName = 'NewSafe' }
        $r.IsSuccess  | Should -BeTrue
        $r.StatusCode | Should -Be 201
    }

    It 'C19 - 204 No Content returns IsSuccess=$true and DataType=Empty' {
        Mock Invoke-WebRequest { script:New-MockWebResponse -StatusCode 204 -Body '' } `
            -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'DELETE' -Endpoint '/API/Safes/OldSafe'
        $r.IsSuccess | Should -BeTrue
        $r.DataType  | Should -Be 'Empty'
        $r.Data      | Should -BeNullOrEmpty
    }

    It 'C20 - WhatIf suppresses POST and returns synthetic success' {
        Mock Invoke-WebRequest { throw 'Should not be called' } -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'POST' `
            -Endpoint '/API/Safes' -Body @{ safeName = 'X' } -WhatIf
        $r.IsSuccess  | Should -BeTrue
        $r.StatusCode | Should -Be 200
        Should -Invoke Invoke-WebRequest -Times 0 -ModuleName 'CyberArkComms'
    }

    It 'C21 - WhatIf suppresses PUT' {
        Mock Invoke-WebRequest { throw 'Should not be called' } -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'PUT' `
            -Endpoint '/API/Safes/X' -Body @{ description = 'Y' } -WhatIf
        $r.IsSuccess | Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 0 -ModuleName 'CyberArkComms'
    }

    It 'C22 - WhatIf suppresses DELETE' {
        Mock Invoke-WebRequest { throw 'Should not be called' } -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'DELETE' `
            -Endpoint '/API/Safes/X' -WhatIf
        $r.IsSuccess | Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 0 -ModuleName 'CyberArkComms'
    }

    It 'C23 - WhatIf does NOT suppress GET' {
        $json = '{"value":[],"count":0}'
        Mock Invoke-WebRequest { script:New-MockWebResponse -StatusCode 200 -Body $json } `
            -ModuleName 'CyberArkComms'

        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' `
            -WhatIf -PageSize 0 | Out-Null
        Should -Invoke Invoke-WebRequest -Times 1 -ModuleName 'CyberArkComms'
    }

    It 'C24 - QueryParams are appended to the request URI' {
        $json = '{"value":[],"count":0}'
        $capturedUri = $null
        Mock Invoke-WebRequest {
            param($Uri) ; Set-Variable -Name capturedUri -Value $Uri -Scope Script
            script:New-MockWebResponse -StatusCode 200 -Body $json
        } -ModuleName 'CyberArkComms'

        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' `
            -QueryParams @{ search = 'myvault' } -PageSize 0 | Out-Null

        $script:capturedUri | Should -Match 'search=myvault'
    }

    It 'C25 - Body is sent with JSON Content-Type' {
        $json = '{"id":"123"}'
        $capturedContentType = $null
        Mock Invoke-WebRequest {
            param($Uri, $Method, $Headers, $Body, $ContentType, $UseBasicParsing, $ErrorAction)
            Set-Variable -Name capturedContentType -Value $ContentType -Scope Script
            script:New-MockWebResponse -StatusCode 201 -Body $json
        } -ModuleName 'CyberArkComms'

        Invoke-CyberArkAPI -Token $script:MockToken -Method 'POST' -Endpoint '/API/Safes' `
            -Body @{ safeName = 'X' } | Out-Null

        $script:capturedContentType | Should -Be 'application/json'
    }

    It 'C25a - a single-element array Body is serialized as a JSON array, not unwrapped to a bare object' {
        $json = '{"id":"123"}'
        $capturedBody = $null
        Mock Invoke-WebRequest {
            param($Uri, $Method, $Headers, $Body, $ContentType, $UseBasicParsing, $ErrorAction)
            Set-Variable -Name capturedBody -Value $Body -Scope Script
            script:New-MockWebResponse -StatusCode 200 -Body $json
        } -ModuleName 'CyberArkComms'

        # A one-operation JSON Patch body - the case that regressed when ConvertTo-Json was fed
        # via the pipeline (which unrolls a single-element array before serializing it). Parsed
        # back rather than compared as a literal string, since PS 5.1 hashtable key order isn't
        # guaranteed - the bug under test is the missing `[ ]` wrapper, not key ordering.
        Invoke-CyberArkAPI -Token $script:MockToken -Method 'PATCH' -Endpoint '/API/Accounts/1' `
            -Body @(@{ op = 'replace'; path = '/name'; value = 'X' }) | Out-Null

        # Body is sent as raw UTF8 bytes, not a String (see C25d) - decode before asserting on content.
        # Comma operator prevents the pipeline from unrolling the byte[] into individual bytes
        # before Should sees it (see Reference_Lessons-Learned.md Section 30).
        ,$script:capturedBody | Should -BeOfType 'System.Byte[]'
        $decodedBody = [System.Text.Encoding]::UTF8.GetString($script:capturedBody)
        $decodedBody.TrimStart() | Should -Match '^\['
        [array]$parsed = @($decodedBody | ConvertFrom-Json)
        $parsed.Count      | Should -Be 1
        $parsed[0].op      | Should -Be 'replace'
        $parsed[0].path    | Should -Be '/name'
        $parsed[0].value   | Should -Be 'X'
    }

    It 'C25d - Body is encoded as raw UTF8 bytes, not a plain String, so PowerShell module/script-block logging cannot record the literal JSON (credential exposure fix)' {
        $json = '{"id":"123"}'
        $capturedBody = $null
        Mock Invoke-WebRequest {
            param($Uri, $Method, $Headers, $Body, $ContentType, $UseBasicParsing, $ErrorAction)
            Set-Variable -Name capturedBody -Value $Body -Scope Script
            script:New-MockWebResponse -StatusCode 201 -Body $json
        } -ModuleName 'CyberArkComms'

        Invoke-CyberArkAPI -Token $script:MockToken -Method 'POST' -Endpoint '/API/Accounts' `
            -Body @{ secret = 'CorrectHorseBatteryStaple' } | Out-Null

        ,$script:capturedBody | Should -BeOfType 'System.Byte[]'
        $decoded = [System.Text.Encoding]::UTF8.GetString($script:capturedBody)
        $decoded | Should -Match 'CorrectHorseBatteryStaple'
    }

    It 'C25b - a trailing slash on -Endpoint is preserved in the request URI (PIMServices.svc requires it)' {
        $json = '{"application":[]}'
        $capturedUri = $null
        Mock Invoke-WebRequest {
            param($Uri) ; Set-Variable -Name capturedUri -Value $Uri -Scope Script
            script:New-MockWebResponse -StatusCode 200 -Body $json
        } -ModuleName 'CyberArkComms'

        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' `
            -Endpoint '/WebServices/PIMServices.svc/Applications/' -PageSize 0 | Out-Null

        # Join-CyberArkUrl itself still trims a bare trailing slash (C12) - Invoke-CyberArkAPI
        # restores it at the call site when the caller's own -Endpoint string ended with '/'.
        $script:capturedUri | Should -Match '/Applications/(\?|$)'
    }

    It 'C25c - no trailing slash added when -Endpoint does not end with one' {
        $json = '{"value":[],"count":0}'
        $capturedUri = $null
        Mock Invoke-WebRequest {
            param($Uri) ; Set-Variable -Name capturedUri -Value $Uri -Scope Script
            script:New-MockWebResponse -StatusCode 200 -Body $json
        } -ModuleName 'CyberArkComms'

        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' -PageSize 0 | Out-Null

        $script:capturedUri | Should -Match '/API/Safes(\?|$)'
        $script:capturedUri | Should -Not -Match '/API/Safes/'
    }
}

# ─────────────────────────────────────────────────────────────────
# Binary/file responses (e.g. Platforms/Export downloading a .zip) - response shape is
# determined from the actual Content-Type/Content-Disposition headers, not by trying
# ConvertFrom-Json and catching failure. See Reference_Lessons-Learned.md Section 39
# for why RawContentStream (not .Content) is used when Content-Type is absent/misleading.
Describe 'Invoke-CyberArkAPI - binary/file responses (mocked Invoke-WebRequest)' {

    BeforeEach {
        $script:TestZipBytes = [byte[]](0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF, 0x80, 0x41, 0x0A, 0x0D)
    }

    It 'C37 - a correctly-labeled binary Content-Type (.Content already byte[]) returns DataType=File with exact bytes' {
        Mock Invoke-WebRequest {
            script:New-MockWebResponse -StatusCode 200 -Body $script:TestZipBytes `
                -Headers @{ 'Content-Type' = 'application/octet-stream'; 'Content-Disposition' = 'attachment; filename="MyPlatform.zip"' }
        } -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'POST' -Endpoint '/API/Platforms/WinServerLocal/Export'
        $r.IsSuccess    | Should -BeTrue
        $r.DataType     | Should -Be 'File'
        ,$r.Data | Should -BeOfType 'System.Byte[]'
        [System.Linq.Enumerable]::SequenceEqual([byte[]]$r.Data, [byte[]]$script:TestZipBytes) | Should -BeTrue
        $r.SuggestedFileName | Should -Be 'MyPlatform.zip'
    }

    It 'C38 - a mislabeled Content-Type (text/html) with Content-Disposition still recovers exact bytes via RawContentStream' {
        # .Content would be a lossily-decoded string in this real-world case (confirmed live -
        # see Section 39) - RawContentStream is what must be used to avoid corrupting the file.
        Mock Invoke-WebRequest {
            script:New-MockWebResponse -StatusCode 200 -Body 'PK ??A' `
                -Headers @{ 'Content-Type' = 'text/html; charset=utf-8'; 'Content-Disposition' = 'attachment; filename="MyPlatform.zip"' } `
                -RawBytes $script:TestZipBytes
        } -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'POST' -Endpoint '/API/Platforms/WinServerLocal/Export'
        $r.DataType | Should -Be 'File'
        [System.Linq.Enumerable]::SequenceEqual([byte[]]$r.Data, [byte[]]$script:TestZipBytes) | Should -BeTrue
        $r.SuggestedFileName | Should -Be 'MyPlatform.zip'
    }

    It 'C39 - binary content with no Content-Disposition header still returns DataType=File, with SuggestedFileName null' {
        Mock Invoke-WebRequest {
            script:New-MockWebResponse -StatusCode 200 -Body $script:TestZipBytes `
                -Headers @{ 'Content-Type' = 'application/zip' }
        } -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'POST' -Endpoint '/API/Platforms/WinServerLocal/Export'
        $r.DataType          | Should -Be 'File'
        $r.SuggestedFileName | Should -BeNullOrEmpty
    }

    It 'C40 - a normal JSON response (Content-Type: application/json) is unaffected by the binary-detection logic' {
        Mock Invoke-WebRequest {
            script:New-MockWebResponse -StatusCode 200 -Body '{"value":[],"count":0}' `
                -Headers @{ 'Content-Type' = 'application/json' }
        } -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' -PageSize 0
        $r.DataType | Should -Be 'JSON'
        $r.SuggestedFileName | Should -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-CyberArkAPI - pagination (mocked Invoke-WebRequest)' {

    It 'C26 - two full pages combined into single value array' {
        $page1 = '{"value":[{"safeName":"Safe1"},{"safeName":"Safe2"}],"count":4}'
        $page2 = '{"value":[{"safeName":"Safe3"},{"safeName":"Safe4"}],"count":4}'
        $page3 = '{"value":[],"count":4}'  # empty page terminates pagination
        $callCount = 0
        Mock Invoke-WebRequest {
            $script:callCount++
            if ($script:callCount -eq 1) {
                [PSCustomObject]@{ StatusCode = 200; Content = $page1 ; Headers = @{} }
            } elseif ($script:callCount -eq 2) {
                [PSCustomObject]@{ StatusCode = 200; Content = $page2 ; Headers = @{} }
            } else {
                [PSCustomObject]@{ StatusCode = 200; Content = $page3 ; Headers = @{} }
            }
        } -ModuleName 'CyberArkComms'

        $script:callCount = 0
        # PageSize=2 so two items per page triggers a second fetch; empty 3rd page terminates
        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' `
            -PageSize 2
        $r.Data.value.Count | Should -Be 4
    }

    It 'C27 - final page smaller than PageSize stops pagination' {
        $page1 = '{"value":[{"safeName":"S1"},{"safeName":"S2"}],"count":3}'
        $page2 = '{"value":[{"safeName":"S3"}],"count":3}'
        $callCount = 0
        Mock Invoke-WebRequest {
            $script:callCount++
            if ($script:callCount -eq 1) {
                [PSCustomObject]@{ StatusCode = 200; Content = $page1 ; Headers = @{} }
            } else {
                [PSCustomObject]@{ StatusCode = 200; Content = $page2 ; Headers = @{} }
            }
        } -ModuleName 'CyberArkComms'

        $script:callCount = 0
        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' `
            -PageSize 2 | Out-Null
        $script:callCount | Should -Be 2   # exactly 2 requests, not 3
    }

    It 'C28 - PageSize=0 disables pagination (single request)' {
        $json = '{"value":[{"safeName":"S1"}],"count":1}'
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 200; Content = $json ; Headers = @{} } } `
            -ModuleName 'CyberArkComms'

        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' `
            -PageSize 0 | Out-Null
        Should -Invoke Invoke-WebRequest -Times 1 -ModuleName 'CyberArkComms'
    }

    It 'C41 - an unrecognized collection property name still paginates via dynamic array detection' {
        # "Widgets" is not in the hardcoded property list (value/Safes/Members/Accounts/Users/
        # Platforms/Groups) - proves Find-CyberArkCollectionProperty's fallback to the first
        # array-valued property, not just the fast-path known-name list.
        $page1 = '{"Widgets":[{"id":1},{"id":2}],"Total":4}'
        $page2 = '{"Widgets":[{"id":3},{"id":4}],"Total":4}'
        $page3 = '{"Widgets":[],"Total":4}'
        $callCount = 0
        Mock Invoke-WebRequest {
            $script:callCount++
            if ($script:callCount -eq 1) {
                [PSCustomObject]@{ StatusCode = 200; Content = $page1 ; Headers = @{} }
            } elseif ($script:callCount -eq 2) {
                [PSCustomObject]@{ StatusCode = 200; Content = $page2 ; Headers = @{} }
            } else {
                [PSCustomObject]@{ StatusCode = 200; Content = $page3 ; Headers = @{} }
            }
        } -ModuleName 'CyberArkComms'

        $script:callCount = 0
        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Widgets' `
            -PageSize 2
        $r.Data.Widgets.Count | Should -Be 4
        $r.Data.Widgets[3].id | Should -Be 4
    }

    It 'C42 - a single-page response with an unrecognized collection property name is returned as-is' {
        $json = '{"Widgets":[{"id":1}],"Total":1}'
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 200; Content = $json ; Headers = @{} } } `
            -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Widgets' `
            -PageSize 50
        $r.Data.Widgets.Count | Should -Be 1
    }
}

# ─────────────────────────────────────────────────────────────────
# Non-2xx responses returned directly by a mocked Invoke-WebRequest (no exception thrown) still
# reach the same $isSuccess/error-parsing logic real HTTP errors do - $isSuccess is derived
# purely from $statusCode, so this covers the ErrorCode-prefixing fix below without needing a
# real System.Net.HttpWebResponse (a WebException's Response, which is documented at the top of
# this file as impractical to construct in pure PowerShell for the thrown-exception path).
Describe 'Invoke-CyberArkAPI - error responses (mocked Invoke-WebRequest, no exception)' {

    It 'C29 - a 4xx body with ErrorCode and ErrorMessage produces "CODE: message" in ErrorMessage' {
        $json = '{"ErrorCode":"PASWS001W","ErrorMessage":"The account is locked by: [ca_jesse]."}'
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 400; Content = $json ; Headers = @{} } } `
            -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'POST' -Endpoint '/API/Accounts/60_5/Password/Update' `
            -Body @{ NewCredentials = 'x' }
        $r.IsSuccess          | Should -BeFalse
        $r.StatusCode         | Should -Be 400
        $r.ErrorMessage       | Should -Be 'PASWS001W: The account is locked by: [ca_jesse].'
        $r.ErrorDetails.ErrorCode    | Should -Be 'PASWS001W'
        $r.ErrorDetails.ErrorMessage | Should -Be 'The account is locked by: [ca_jesse].'
    }

    It 'C30 - a 5xx body with ErrorCode and ErrorMessage also gets the "CODE: message" prefix' {
        $json = '{"ErrorCode":"CAWS00001E","ErrorMessage":"Internal error."}'
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 500; Content = $json ; Headers = @{} } } `
            -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes'
        $r.ErrorMessage | Should -Be 'CAWS00001E: Internal error.'
    }

    It 'C31 - a 4xx body with no ErrorCode field falls back to the bare ErrorMessage (no leading colon)' {
        $json = '{"ErrorMessage":"Not Found"}'
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 404; Content = $json ; Headers = @{} } } `
            -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Accounts/nope'
        $r.ErrorMessage | Should -Be 'Not Found'
    }

    It 'C32 - a non-JSON 4xx body with content is included in ErrorMessage, per user request' {
        # Direct assignment, not `{ $r = ... } | Should -Not -Throw` - that form runs the
        # scriptblock in a child scope, so $r never reaches this scope (Lessons-Learned 32).
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 400; Content = '<html>Bad Request</html>' ; Headers = @{} } } `
            -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes'
        $r.ErrorMessage | Should -Be 'HTTP 400 - <html>Bad Request</html>'
    }

    It 'C33 - a genuinely blank 4xx body falls back to a bare HTTP-status message' {
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 400; Content = '' ; Headers = @{} } } `
            -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes'
        $r.ErrorMessage | Should -Be 'HTTP 400'
    }
}

# ─────────────────────────────────────────────────────────────────
# C34/C35/C36/C37/C38 below are skipped under pwsh (PowerShell 7/.NET Core): ICertificatePolicy -
# the legacy interface Disable-SSLValidation's TrustAllCerts class implements - does not exist in
# .NET Core's System.Net surface at all, so Add-Type fails to compile it there regardless of
# whether the fix itself is correct; reading [System.Net.ServicePointManager]::CertificatePolicy
# itself was also observed to be unreliable under pwsh (Get-Member finds no such static member at
# all, yet a bare read sometimes succeeds and sometimes throws "property cannot be found"
# depending on unrelated prior test-run history in the same process - not something worth
# depending on either way). Confirmed directly (not assumed) that the real fix is correct: the
# exact same Add-Type/CertificatePolicy-assign/reset-to-$null sequence, run standalone via real
# Windows PowerShell 5.1 (powershell.exe, not pwsh), compiles and round-trips correctly every
# time. This is a test-runner/runtime mismatch, not a defect in
# Disable-SSLValidation/Reset-SSLValidation, and matches this project's own established
# Windows-PowerShell-5.1-only scope (see K01). These tests still document and verify the real
# behavior for whenever the suite is run under actual Windows PowerShell 5.1.
$script:IsFrameworkPS = $PSVersionTable.PSVersion.Major -lt 6

Describe 'Expect100Continue disabled on module load (Testing_Plan.md K16)' {

    It 'C43 - importing the module sets ServicePointManager.Expect100Continue to false' {
        [System.Net.ServicePointManager]::Expect100Continue = $true
        Import-Module $script:CommsPath -Force
        [System.Net.ServicePointManager]::Expect100Continue | Should -Be $false
    }
}

Describe 'Disable-SSLValidation / Reset-SSLValidation' {

    AfterEach {
        # Every test in this Describe touches real process-wide ServicePointManager state (the
        # exact thing Testing_Plan.md K02 is about) - always leave it at the real default
        # afterward so no other test file running later in the same process is affected.
        Reset-SSLValidation
    }

    It 'C34 - Disable-SSLValidation installs a permissive certificate policy' -Skip:(-not $script:IsFrameworkPS) {
        Disable-SSLValidation
        [System.Net.ServicePointManager]::CertificatePolicy.GetType().Name | Should -Be 'TrustAllCerts'
    }

    It 'C35 - Reset-SSLValidation restores the real (default) certificate policy' -Skip:(-not $script:IsFrameworkPS) {
        Disable-SSLValidation
        Reset-SSLValidation
        [System.Net.ServicePointManager]::CertificatePolicy | Should -BeNullOrEmpty
    }

    It 'C36 - Reset-SSLValidation is a safe no-op when validation was never disabled' -Skip:(-not $script:IsFrameworkPS) {
        { Reset-SSLValidation } | Should -Not -Throw
        [System.Net.ServicePointManager]::CertificatePolicy | Should -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-CyberArkAPI - IgnoreSSL reset on profile switch (Testing_Plan.md K02)' {

    BeforeAll {
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}'; Headers = @{} } } `
            -ModuleName 'CyberArkComms'
    }

    AfterEach {
        Reset-SSLValidation
    }

    It 'C37 - a call with -IgnoreSSL disables certificate validation' -Skip:(-not $script:IsFrameworkPS) {
        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' -PageSize 0 -IgnoreSSL | Out-Null
        [System.Net.ServicePointManager]::CertificatePolicy.GetType().Name | Should -Be 'TrustAllCerts'
    }

    It 'C38 - a later call without -IgnoreSSL resets validation - this is the actual K02 fix' -Skip:(-not $script:IsFrameworkPS) {
        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' -PageSize 0 -IgnoreSSL | Out-Null
        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' -PageSize 0 | Out-Null
        [System.Net.ServicePointManager]::CertificatePolicy | Should -BeNullOrEmpty
    }

    It 'C39 - a call without -IgnoreSSL when validation was never disabled does not error' {
        { Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' -PageSize 0 } | Should -Not -Throw
    }
}
