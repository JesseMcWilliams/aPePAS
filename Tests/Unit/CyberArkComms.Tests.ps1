#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for CyberArkComms.psm1.
    No CyberArk connection required.

.NOTES
    A thrown HTTP error's Response (HttpWebResponse on PS 5.1, HttpResponseMessage on PS 7)
    can't be faked in pure PowerShell, so the thrown-error tests (C44+) use a real local
    HttpListener instead of mocking Invoke-WebRequest. 429/504 retries aren't covered there
    (they sleep); module-level handling of those codes is tested by mocking Invoke-CyberArkAPI.
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

    It 'C44 - quoted value reaches the query string as URL-encoded double quotes (%22)' {
        $filter = New-CyberArkSearchFilter -Criteria @{ safeName = 'My Safe' }
        New-CyberArkQuery -Params @{ filter = $filter } |
            Should -Be '?filter=safeName%20eq%20%22My%20Safe%22'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Get-CyberArkAccountIdentifier' {

    It 'C48 - AccountID alone is enough and needs no lookup; other columns are ignored' {
        $i = Get-CyberArkAccountIdentifier -InputData @{ AccountID = ' 12_34 '; AccountName = 'x'; Safe = '' }
        $i.AccountID    | Should -Be '12_34'
        $i.NeedsLookup  | Should -BeFalse
        $i.ErrorMessage | Should -Be ''
    }

    It 'C49 - AccountName with Safe needs a lookup' {
        $i = Get-CyberArkAccountIdentifier -InputData @{ AccountName = 'srv1-root'; Safe = 'Linux' }
        $i.NeedsLookup  | Should -BeTrue
        $i.AccountName  | Should -Be 'srv1-root'
        $i.Safe         | Should -Be 'Linux'
    }

    It 'C50 - ObjectName is used as AccountName when AccountName is blank' {
        (Get-CyberArkAccountIdentifier -InputData @{ ObjectName = 'srv1-root'; Safe = 'Linux' }).AccountName |
            Should -Be 'srv1-root'
        (Get-CyberArkAccountIdentifier -InputData @{ AccountName = 'a'; ObjectName = 'b'; Safe = 'S' }).AccountName |
            Should -Be 'a'
    }

    It 'C51 - UserName with Safe needs a lookup' {
        $i = Get-CyberArkAccountIdentifier -InputData @{ UserName = 'root'; Safe = 'Linux' }
        $i.NeedsLookup | Should -BeTrue
        $i.UserName    | Should -Be 'root'
    }

    It 'C52 - no identifier at all is an error' {
        $i = Get-CyberArkAccountIdentifier -InputData @{ Safe = 'Linux' }
        $i.NeedsLookup  | Should -BeFalse
        $i.ErrorMessage | Should -Be 'AccountID is required, or AccountName and/or UserName with Safe.'
    }

    It 'C53 - a name without Safe is an error' {
        (Get-CyberArkAccountIdentifier -InputData @{ AccountName = 'srv1-root' }).ErrorMessage |
            Should -Be 'Safe is required to locate the account by AccountName or UserName.'
    }

    It 'C54 - -IgnoreUserName leaves UserName out of the lookup and the messages' {
        $i = Get-CyberArkAccountIdentifier -InputData @{ UserName = 'newname'; Safe = 'Linux' } -IgnoreUserName
        $i.UserName     | Should -Be ''
        $i.ErrorMessage | Should -Be 'AccountID is required, or AccountName with Safe.'
        (Get-CyberArkAccountIdentifier -InputData @{ AccountName = 'a'; UserName = 'newname' } -IgnoreUserName).ErrorMessage |
            Should -Be 'Safe is required to locate the account by AccountName.'
    }

    It 'C55 - null or missing InputData is an error, not a crash' {
        (Get-CyberArkAccountIdentifier -InputData $null).ErrorMessage | Should -Not -BeNullOrEmpty
        (Get-CyberArkAccountIdentifier).ErrorMessage                  | Should -Not -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Select-CyberArkAccountMatch' {
    BeforeAll {
        $script:SafeAccounts = @(
            [PSCustomObject]@{ id = '1'; name = 'srv1-root';  userName = 'root';  safeName = 'Linux' }
            [PSCustomObject]@{ id = '2'; name = 'srv2-root';  userName = 'root';  safeName = 'Linux' }
            [PSCustomObject]@{ id = '3'; name = 'root';       userName = 'admin'; safeName = 'Linux' }
            [PSCustomObject]@{ id = '4'; name = 'srv1-oracle'; userName = 'oracle'; safeName = 'Linux' }
        )
    }

    It 'C56 - AccountName matches the name field only, never userName' {
        # 'root' is the userName of ids 1 and 2 but the name of id 3 only.
        $m = Select-CyberArkAccountMatch -Accounts $script:SafeAccounts -AccountName 'root' -Safe 'Linux'
        $m.ErrorMessage | Should -Be ''
        $m.AccountID    | Should -Be '3'
    }

    It 'C57 - AccountName match is case-insensitive' {
        (Select-CyberArkAccountMatch -Accounts $script:SafeAccounts -AccountName 'SRV1-ORACLE' -Safe 'Linux').AccountID |
            Should -Be '4'
    }

    It 'C58 - UserName matches the userName field; one match succeeds' {
        (Select-CyberArkAccountMatch -Accounts $script:SafeAccounts -UserName 'oracle' -Safe 'Linux').AccountID |
            Should -Be '4'
    }

    It 'C59 - more than one match is an error that names the count and the criteria' {
        $m = Select-CyberArkAccountMatch -Accounts $script:SafeAccounts -UserName 'root' -Safe 'Linux'
        $m.AccountID    | Should -Be ''
        $m.ErrorMessage | Should -Be "2 accounts with UserName 'root' found in safe 'Linux'. Use AccountID, or add AccountName or UserName to match exactly one."
    }

    It 'C60 - AccountName and UserName together must both match' {
        (Select-CyberArkAccountMatch -Accounts $script:SafeAccounts -AccountName 'srv2-root' -UserName 'root' -Safe 'Linux').AccountID |
            Should -Be '2'
        (Select-CyberArkAccountMatch -Accounts $script:SafeAccounts -AccountName 'srv2-root' -UserName 'admin' -Safe 'Linux').ErrorMessage |
            Should -Be "No account with AccountName 'srv2-root' and UserName 'admin' found in safe 'Linux'."
    }

    It 'C61 - empty or null account list is a not-found error' {
        (Select-CyberArkAccountMatch -Accounts @() -AccountName 'x' -Safe 'S').ErrorMessage |
            Should -Be "No account with AccountName 'x' found in safe 'S'."
        (Select-CyberArkAccountMatch -Accounts $null -AccountName 'x' -Safe 'S').ErrorMessage |
            Should -Be "No account with AccountName 'x' found in safe 'S'."
    }

    It 'C62 - a single match without an id is an error' {
        $m = Select-CyberArkAccountMatch -Accounts @([PSCustomObject]@{ name = 'noid' }) -AccountName 'noid' -Safe 'S'
        $m.ErrorMessage | Should -Be "Account with AccountName 'noid' found in safe 'S' but has no ID."
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Get-CyberArkUserIdentifier' {

    It 'CU01 - UserID wins and needs no lookup' {
        $i = Get-CyberArkUserIdentifier -InputData @{ UserID = ' 42 '; Username = 'someone' }
        $i.UserID       | Should -Be '42'
        $i.NeedsLookup  | Should -BeFalse
        $i.ErrorMessage | Should -Be ''
    }

    It 'CU02 - Username alone needs a lookup' {
        $i = Get-CyberArkUserIdentifier -InputData @{ Username = ' jdoe ' }
        $i.Username    | Should -Be 'jdoe'
        $i.NeedsLookup | Should -BeTrue
    }

    It 'CU03 - neither column is an error' {
        (Get-CyberArkUserIdentifier -InputData @{ UserID = ''; Username = '' }).ErrorMessage | Should -Be 'UserID or Username is required.'
        (Get-CyberArkUserIdentifier -InputData $null).ErrorMessage | Should -Be 'UserID or Username is required.'
    }

    It 'CU04 - a non-numeric UserID is an error' {
        (Get-CyberArkUserIdentifier -InputData @{ UserID = 'abc' }).ErrorMessage | Should -Match 'not valid'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Select-CyberArkUserMatch' {
    BeforeAll {
        $script:SearchUsers = @(
            [PSCustomObject]@{ id = 10; username = 'jdoe' }
            [PSCustomObject]@{ id = 11; username = 'jdoe2' }
            [PSCustomObject]@{ id = 12; username = 'ajdoe' }
        )
    }

    It 'CU05 - exact username match only, case-insensitive' {
        $m = Select-CyberArkUserMatch -Users $script:SearchUsers -Username 'JDOE'
        $m.ErrorMessage | Should -Be ''
        $m.UserID       | Should -Be '10'
    }

    It 'CU06 - no exact match is an error' {
        (Select-CyberArkUserMatch -Users $script:SearchUsers -Username 'doe').ErrorMessage | Should -Be "No user with Username 'doe' found."
        (Select-CyberArkUserMatch -Users @() -Username 'x').ErrorMessage | Should -Be "No user with Username 'x' found."
        (Select-CyberArkUserMatch -Users $null -Username 'x').ErrorMessage | Should -Be "No user with Username 'x' found."
    }

    It 'CU07 - several exact matches is an error, never the first one' {
        $dupes = @([PSCustomObject]@{ id = 1; username = 'svc' }, [PSCustomObject]@{ id = 2; username = 'SVC' })
        $m = Select-CyberArkUserMatch -Users $dupes -Username 'svc'
        $m.UserID       | Should -Be ''
        $m.ErrorMessage | Should -Be "2 users with Username 'svc' found. Use UserID to pick one."
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'ConvertTo-CyberArkUserFields' {

    It 'CU08 - blank columns are left out' {
        $c = ConvertTo-CyberArkUserFields -InputData @{ Description = ''; FirstName = '  '; UserType = $null }
        $c.Fields.Count  | Should -Be 0
        $c.Columns.Count | Should -Be 0
        $c.Errors.Count  | Should -Be 0
    }

    It 'CU09 - nested fields go under personalDetails and internet' {
        $c = ConvertTo-CyberArkUserFields -InputData @{ FirstName = 'Jane'; LastName = 'Doe'; BusinessEmail = 'jane@example.com'; Description = 'x' }
        $c.Fields['personalDetails']['firstName'] | Should -Be 'Jane'
        $c.Fields['personalDetails']['lastName']  | Should -Be 'Doe'
        $c.Fields['internet']['businessEmail']    | Should -Be 'jane@example.com'
        $c.Fields['description']                  | Should -Be 'x'
    }

    It 'CU10 - booleans parse true/false words and reject anything else' {
        $c = ConvertTo-CyberArkUserFields -InputData @{ ChangePassOnNextLogon = 'No'; PasswordNeverExpires = 'yes' }
        $c.Fields['changePassOnNextLogon'] | Should -BeFalse
        $c.Fields['passwordNeverExpires']  | Should -BeTrue
        (ConvertTo-CyberArkUserFields -InputData @{ PasswordNeverExpires = 'maybe' }).Errors[0] | Should -Match 'true or false'
    }

    It 'CU11 - EnableUser, AuthenticationMethod and AllowedAuthenticationMethods only with -IncludeCreateOnly' {
        $row = @{ EnableUser = 'true'; AuthenticationMethod = 'authtypeldap'; AllowedAuthenticationMethods = 'SAML; PKI' }
        (ConvertTo-CyberArkUserFields -InputData $row).Fields.Count | Should -Be 0
        $c = ConvertTo-CyberArkUserFields -InputData $row -IncludeCreateOnly
        $c.Fields['enableUser']                   | Should -BeTrue
        $c.Fields['authenticationMethod']         | Should -Be @('AuthTypeLDAP')
        $c.Fields['allowedAuthenticationMethods'] | Should -Be @('SAML', 'PKI')
    }

    It 'CU12 - VaultAuthorization is validated and normalized; a single value is still an array' {
        $c = ConvertTo-CyberArkUserFields -InputData @{ VaultAuthorization = 'addsafes' }
        , $c.Fields['vaultAuthorization'] | Should -BeOfType [string[]]
        $c.Fields['vaultAuthorization'][0] | Should -Be 'AddSafes'
        (ConvertTo-CyberArkUserFields -InputData @{ VaultAuthorization = 'AddSafes;FlyPlanes' }).Errors[0] | Should -Match 'FlyPlanes'
    }

    It 'CU13 - ExpiryDate becomes Unix seconds; a bad date is an error' {
        $c = ConvertTo-CyberArkUserFields -InputData @{ ExpiryDate = '2030-01-15' }
        $expected = ([DateTimeOffset][datetime]::new(2030, 1, 15, 0, 0, 0, [DateTimeKind]::Local)).ToUnixTimeSeconds()
        $c.Fields['expiryDate'] | Should -Be $expected
        (ConvertTo-CyberArkUserFields -InputData @{ ExpiryDate = '15/01/2030' }).Errors[0] | Should -Match 'yyyy-MM-dd'
    }

    It 'CU14 - over-long values are errors' {
        (ConvertTo-CyberArkUserFields -InputData @{ Description = ('x' * 100) }).Errors[0] | Should -Match '99 characters'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'ConvertTo-CyberArkUserPutBody' {
    BeforeAll {
        $script:CurrentUser = [PSCustomObject]@{
            id                      = 7
            username                = 'jdoe'
            source                  = 'CyberArk'
            componentUser           = $false
            groupsMembership        = @([PSCustomObject]@{ groupID = 1 })
            lastSuccessfulLoginDate = 1700000000
            authenticationMethod    = @('AuthTypePass')
            userType                = 'EPVUser'
            description             = 'old'
            location                = '\'
            enableUser              = $true
            distinguishedName       = $null
            vaultAuthorization      = @('AddSafes')
            personalDetails         = [PSCustomObject]@{ firstName = 'Jane'; lastName = 'Doe'; city = 'Boston' }
            internet                = [PSCustomObject]@{ businessEmail = 'old@example.com' }
        }
    }

    It 'CU15 - keeps editable fields and drops read-only ones and nulls' {
        $b = ConvertTo-CyberArkUserPutBody -User $script:CurrentUser
        $b['username']    | Should -Be 'jdoe'
        $b['description'] | Should -Be 'old'
        $b['enableUser']  | Should -BeTrue
        foreach ($k in 'id', 'source', 'componentUser', 'groupsMembership', 'lastSuccessfulLoginDate', 'authenticationMethod', 'distinguishedName') {
            $b.ContainsKey($k) | Should -BeFalse -Because "$k must not be sent"
        }
    }

    It 'CU16 - changes merge into nested objects without blanking their other fields' {
        $b = ConvertTo-CyberArkUserPutBody -User $script:CurrentUser -Changes @{ personalDetails = @{ firstName = 'Janet' }; description = 'new' }
        $b['personalDetails']['firstName'] | Should -Be 'Janet'
        $b['personalDetails']['lastName']  | Should -Be 'Doe'
        $b['personalDetails']['city']      | Should -Be 'Boston'
        $b['internet']['businessEmail']    | Should -Be 'old@example.com'
        $b['description']                  | Should -Be 'new'
    }

    It 'CU17 - a change can add a nested object the user did not have' {
        $b = ConvertTo-CyberArkUserPutBody -User ([PSCustomObject]@{ username = 'x' }) -Changes @{ phones = @{ cellularNumber = '1' } }
        $b['phones']['cellularNumber'] | Should -Be '1'
    }

    It 'CU18 - a negative (never-expires) expiryDate is left out, a real one is kept (F101)' {
        $never = ConvertTo-CyberArkUserPutBody -User ([PSCustomObject]@{ username = 'x'; expiryDate = -62135568000 })
        $never.ContainsKey('expiryDate') | Should -BeFalse
        $real = ConvertTo-CyberArkUserPutBody -User ([PSCustomObject]@{ username = 'x'; expiryDate = 1893456000 })
        $real['expiryDate'] | Should -Be 1893456000
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-CyberArkAPI - success paths (mocked Invoke-WebRequest)' {

    BeforeAll {
        # Build a minimal success response object that Invoke-WebRequest returns.
        # UseBasicParsing returns an object with StatusCode, Content, Headers, and
        # RawContentStream - Headers is always present on a real response (confirmed live
        # against a real HttpListener - see Reference_Lessons-Learned-PowerShell.md Section 11),
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
        # before Should sees it (see Reference_Lessons-Learned-PowerShell.md Section 6).
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
# ConvertFrom-Json and catching failure. See Reference_Lessons-Learned-PowerShell.md Section 11
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

    It 'C66 - an explicit -PageSize 0 still disables pagination when the token carries a profile page size (F90)' {
        # Regression test: the profile page size (Token.PageSize, set from the profile's Limit)
        # used to override -PageSize 0, so single-resource GETs and file downloads got
        # limit/offset appended and could be paged. Two items with a page size of 1 means the old
        # code stops after one page (2 -ne 1) and fails on the URI check rather than looping.
        $json = '{"value":[{"safeName":"S1"},{"safeName":"S2"}],"count":2}'
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 200; Content = $json ; Headers = @{} } } `
            -ModuleName 'CyberArkComms'
        $profileToken = $script:MockToken.PSObject.Copy()
        $profileToken | Add-Member -NotePropertyName 'PageSize' -NotePropertyValue 1 -Force

        Invoke-CyberArkAPI -Token $profileToken -Method 'GET' -Endpoint '/API/Safes' -PageSize 0 | Out-Null
        Should -Invoke Invoke-WebRequest -Times 1 -ModuleName 'CyberArkComms'
        Should -Invoke Invoke-WebRequest -ModuleName 'CyberArkComms' -ParameterFilter { $Uri -notmatch 'limit=|offset=' } -Times 1
    }

    It 'C67 - without -PageSize, the profile page size is still used for paginated GETs' {
        $json = '{"value":[],"count":0}'
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 200; Content = $json ; Headers = @{} } } `
            -ModuleName 'CyberArkComms'
        $profileToken = $script:MockToken.PSObject.Copy()
        $profileToken | Add-Member -NotePropertyName 'PageSize' -NotePropertyValue 7 -Force

        Invoke-CyberArkAPI -Token $profileToken -Method 'GET' -Endpoint '/API/Safes' | Out-Null
        Should -Invoke Invoke-WebRequest -ModuleName 'CyberArkComms' -ParameterFilter { $Uri -match 'limit=7' } -Times 1
    }

    It 'C72 - GET /API/Users pages with pageSize/pageOffset, not limit/offset (14.6 Swagger)' {
        $page1 = '{"Users":[{"id":1},{"id":2}],"Total":3}'
        $page2 = '{"Users":[{"id":3}],"Total":3}'
        Mock Invoke-WebRequest {
            if ($Uri -match 'pageOffset=0') { [PSCustomObject]@{ StatusCode = 200; Content = $page1 ; Headers = @{} } }
            else                            { [PSCustomObject]@{ StatusCode = 200; Content = $page2 ; Headers = @{} } }
        } -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Users' -PageSize 2
        $r.Data.Users.Count | Should -Be 3
        Should -Invoke Invoke-WebRequest -ModuleName 'CyberArkComms' -Times 2 -Exactly
        Should -Invoke Invoke-WebRequest -ModuleName 'CyberArkComms' -Times 1 -Exactly -ParameterFilter { $Uri -match 'pageSize=2' -and $Uri -match 'pageOffset=2' }
        Should -Invoke Invoke-WebRequest -ModuleName 'CyberArkComms' -Times 0 -Exactly -ParameterFilter { $Uri -match '[?&](limit|offset)=' }
    }

    It 'C73 - caller-supplied -PageSizeParam/-PageOffsetParam still win for /API/Users' {
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 200; Content = '{"Users":[]}' ; Headers = @{} } } -ModuleName 'CyberArkComms'
        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Users' -PageSizeParam 'limit' -PageOffsetParam 'offset' | Out-Null
        Should -Invoke Invoke-WebRequest -ModuleName 'CyberArkComms' -Times 1 -Exactly -ParameterFilter { $Uri -match 'limit=1000' -and $Uri -match 'offset=0' }
    }

    It 'C74 - other endpoints, including /API/UserGroups, keep limit/offset' {
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}' ; Headers = @{} } } -ModuleName 'CyberArkComms'
        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/UserGroups' | Out-Null
        Should -Invoke Invoke-WebRequest -ModuleName 'CyberArkComms' -Times 1 -Exactly -ParameterFilter { $Uri -match 'limit=1000' -and $Uri -notmatch 'pageSize' }
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
        $json = '{"ErrorCode":"PASWS001W","ErrorMessage":"The account is locked by: [ca_company_user]."}'
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 400; Content = $json ; Headers = @{} } } `
            -ModuleName 'CyberArkComms'

        $r = Invoke-CyberArkAPI -Token $script:MockToken -Method 'POST' -Endpoint '/API/Accounts/60_5/Password/Update' `
            -Body @{ NewCredentials = 'x' }
        $r.IsSuccess          | Should -BeFalse
        $r.StatusCode         | Should -Be 400
        $r.ErrorMessage       | Should -Be 'PASWS001W: The account is locked by: [ca_company_user].'
        $r.ErrorDetails.ErrorCode    | Should -Be 'PASWS001W'
        $r.ErrorDetails.ErrorMessage | Should -Be 'The account is locked by: [ca_company_user].'
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
        # scriptblock in a child scope, so $r never reaches this scope (Lessons-Learned-Pester 6).
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

Describe 'Expect100Continue disabled on module load (Testing_Findings-and-Known-Issues.md K16)' {

    It 'C43 - importing the module sets ServicePointManager.Expect100Continue to false' {
        [System.Net.ServicePointManager]::Expect100Continue = $true
        Import-Module $script:CommsPath -Force
        [System.Net.ServicePointManager]::Expect100Continue | Should -Be $false
    }
}

Describe 'Disable-SSLValidation / Reset-SSLValidation' {

    AfterEach {
        # Every test in this Describe touches real process-wide ServicePointManager state (the
        # exact thing Testing_Findings-and-Known-Issues.md K02 is about) - always leave it at the real default
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
Describe 'Invoke-CyberArkAPI - IgnoreSSL reset on profile switch (Testing_Findings-and-Known-Issues.md K02)' {

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

# ─────────────────────────────────────────────────────────────────
# Real thrown HTTP errors from a local HttpListener, not a mock: PS 5.1 throws WebException, PS 7
# throws HttpResponseException (which is not a WebException), and neither exception's Response
# can be faked in pure PowerShell. Before this fix every PS 7 HTTP error came back as StatusCode 0,
# which modules treat as IsFatal (401/connectivity) - forcing a needless re-authentication.
Describe 'Invoke-CyberArkAPI - thrown HTTP errors on both editions (local HttpListener)' {

    BeforeAll {
        $script:ListenerPort = Get-Random -Minimum 20000 -Maximum 40000
        $script:Listener     = New-Object System.Net.HttpListener
        $script:Listener.Prefixes.Add("http://localhost:$($script:ListenerPort)/")
        $script:Listener.Start()
        # Serve requests on a background runspace until AfterAll stops the listener: the path's
        # last segment is the status code to return, always with a CyberArk-style JSON error body.
        $script:ListenerPs = [PowerShell]::Create()
        $null = $script:ListenerPs.AddScript({
            param($listener)
            while ($listener.IsListening) {
                try { $ctx = $listener.GetContext() } catch { break }
                $code = [int](($ctx.Request.Url.AbsolutePath -split '/')[-1])
                $body = [Text.Encoding]::UTF8.GetBytes("{`"ErrorCode`":`"TEST$code`",`"ErrorMessage`":`"Status $code`"}")
                $ctx.Response.StatusCode  = $code
                $ctx.Response.ContentType = 'application/json'
                $ctx.Response.OutputStream.Write($body, 0, $body.Length)
                $ctx.Response.Close()
            }
        }).AddArgument($script:Listener)
        $script:ListenerHandle = $script:ListenerPs.BeginInvoke()

        $script:LocalToken = [PSCustomObject]@{
            Token      = 'mock-bearer-token'
            TokenType  = 'Bearer'
            Headers    = @{ 'Authorization' = 'Bearer mock-bearer-token' }
            Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
            SystemType = 'SelfHosted'
            AuthMethod = 'CyberArk'
            BaseURL    = "http://localhost:$($script:ListenerPort)"
        }
    }

    AfterAll {
        $script:Listener.Stop()
        $script:Listener.Close()
        $script:ListenerPs.Dispose()
    }

    It 'C44 - a thrown 404 keeps its real status code and CyberArk ErrorCode (was StatusCode 0 on PS 7)' {
        $r = Invoke-CyberArkAPI -Token $script:LocalToken -Method 'GET' -Endpoint '/API/Test/404' -PageSize 0
        $r.IsSuccess                 | Should -BeFalse
        $r.StatusCode                | Should -Be 404
        $r.ErrorDetails.ErrorCode    | Should -Be 'TEST404'
        $r.ErrorMessage              | Should -BeLike 'TEST404: Status 404*'
    }

    It 'C45 - a thrown 401 comes back as StatusCode 401' {
        $r = Invoke-CyberArkAPI -Token $script:LocalToken -Method 'GET' -Endpoint '/API/Test/401' -PageSize 0
        $r.StatusCode                | Should -Be 401
        $r.ErrorDetails.ErrorCode    | Should -Be 'TEST401'
    }

    It 'C46 - a thrown 400 on a POST with a body keeps its status code' {
        $r = Invoke-CyberArkAPI -Token $script:LocalToken -Method 'POST' -Endpoint '/API/Test/400' -Body @{ Name = 'x' }
        $r.StatusCode                | Should -Be 400
        $r.ErrorDetails.ErrorMessage | Should -Be 'Status 400'
    }

    It 'C47 - Get-CyberArkHttpErrorResponse returns $null for an error that is not an HTTP/web error' {
        $record = $null
        try { throw 'not a web error' } catch { $record = $_ }
        Get-CyberArkHttpErrorResponse -ErrorRecord $record | Should -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Invoke-CyberArkAPI - session activity time' {

    BeforeEach {
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 200; Content = '{"value":[]}'; Headers = @{}; RawContentStream = $null } } -ModuleName 'CyberArkComms'
    }

    It 'C63 - a real request records the last API call time' {
        $before = [DateTime]::UtcNow.AddSeconds(-1)
        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' -PageSize 0 | Out-Null
        $last = Get-CyberArkLastApiCallTime
        $last | Should -Not -BeNullOrEmpty
        ($last -ge $before) | Should -BeTrue
    }

    It 'C64 - -NotUserActivity requests, and WhatIf writes that send nothing, leave the time unchanged' {
        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/Safes' -PageSize 0 | Out-Null
        $mark = Get-CyberArkLastApiCallTime
        Start-Sleep -Milliseconds 20
        Invoke-CyberArkAPI -Token $script:MockToken -Method 'GET' -Endpoint '/API/LoggedOnUser' -PageSize 0 -NotUserActivity | Out-Null
        Invoke-CyberArkAPI -Token $script:MockToken -Method 'POST' -Endpoint '/API/Safes' -Body @{ SafeName = 'X' } -WhatIf | Out-Null
        Get-CyberArkLastApiCallTime | Should -Be $mark
    }

    It 'C65 - Update-CyberArkLastApiCallTime records now (used by modules that send their own requests)' {
        $before = [DateTime]::UtcNow.AddSeconds(-1)
        Update-CyberArkLastApiCallTime
        ((Get-CyberArkLastApiCallTime) -ge $before) | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Safe membership expiration date conversion (F93)' {

    It 'C68 - ConvertTo-CyberArkExpirationTime turns yyyy-MM-dd into local-midnight Unix seconds' {
        $expected = ([DateTimeOffset](New-Object DateTime 2027, 1, 31, 0, 0, 0, ([DateTimeKind]::Local))).ToUnixTimeSeconds()
        $value = ConvertTo-CyberArkExpirationTime -Value ' 2027-01-31 '
        $value | Should -BeOfType [long]
        $value | Should -Be $expected
        $withTime = ([DateTimeOffset](New-Object DateTime 2027, 1, 31, 17, 30, 0, ([DateTimeKind]::Local))).ToUnixTimeSeconds()
        ConvertTo-CyberArkExpirationTime -Value '2027-01-31 17:30' | Should -Be $withTime
    }

    It 'C69 - ConvertTo-CyberArkExpirationTime passes Unix seconds through and returns null for blank' {
        ConvertTo-CyberArkExpirationTime -Value '1800000000' | Should -Be 1800000000
        ConvertTo-CyberArkExpirationTime -Value ''    | Should -BeNullOrEmpty
        ConvertTo-CyberArkExpirationTime -Value $null | Should -BeNullOrEmpty
    }

    It 'C70 - ConvertTo-CyberArkExpirationTime throws a yyyy-MM-dd hint for text that is not a date' {
        { ConvertTo-CyberArkExpirationTime -Value '31/01/2027' } | Should -Throw '*yyyy-MM-dd*'
        { ConvertTo-CyberArkExpirationTime -Value '2027-02-30' } | Should -Throw '*yyyy-MM-dd*'
    }

    It 'C71 - ConvertFrom-CyberArkExpirationTime shows local yyyy-MM-dd HH:mm; none, negative and text pass sensibly' {
        $local = [DateTimeOffset]::FromUnixTimeSeconds(1767225600).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
        ConvertFrom-CyberArkExpirationTime -Value 1767225600        | Should -Be $local
        ConvertFrom-CyberArkExpirationTime -Value 1767225600000     | Should -Be $local
        ConvertFrom-CyberArkExpirationTime -Value $null             | Should -Be ''
        ConvertFrom-CyberArkExpirationTime -Value -62135596800      | Should -Be ''
        ConvertFrom-CyberArkExpirationTime -Value '2027-01-31'      | Should -Be '2027-01-31'
    }
}

Describe 'Resolve-CyberArkOutputFolder (F98)' {

    It 'C75 - the override wins over the profile folder' {
        Resolve-CyberArkOutputFolder -OverrideFolder (Join-Path $TestDrive 'o1') -ProfileFolder (Join-Path $TestDrive 'p1') -ProjectRoot $TestDrive |
            Should -Be (Join-Path $TestDrive 'o1')
    }

    It 'C76 - with no override the profile folder is used, and a blank profile folder falls back to the project root' {
        Resolve-CyberArkOutputFolder -OverrideFolder '' -ProfileFolder (Join-Path $TestDrive 'p2') -ProjectRoot $TestDrive |
            Should -Be (Join-Path $TestDrive 'p2')
        Resolve-CyberArkOutputFolder -ProfileFolder '' -ProjectRoot $TestDrive | Should -Be $TestDrive
    }

    It 'C77 - a relative folder resolves against the project root and is created' {
        $folder = Resolve-CyberArkOutputFolder -OverrideFolder 'rel\out' -ProjectRoot $TestDrive
        $folder | Should -Be (Join-Path $TestDrive 'rel\out')
        Test-Path -LiteralPath $folder -PathType Container | Should -BeTrue
    }
}

Describe 'Wait-CyberArkBulkAction (F100)' {
    BeforeAll {
        $script:BulkToken = [PSCustomObject]@{ Token = 't'; Headers = @{ Authorization = 't' }; BaseURL = 'https://test.cyberark.local'; SystemType = 'SelfHosted' }
        function script:New-BulkJobResponse {
            param([string]$Status, [int]$Total, [int]$Succeeded, [int]$Failed, $FailedItems = @())
            [PSCustomObject]@{
                IsSuccess = $true; StatusCode = 200; ErrorMessage = $null; ErrorDetails = $null
                Data = [PSCustomObject]@{
                    Id = 11; Status = $Status
                    Summary = [PSCustomObject]@{ Total = $Total; Succeeded = $Succeeded; Failed = $Failed }
                    SucceededItems = @(); FailedItems = @($FailedItems)
                }
            }
        }
    }

    BeforeEach { Mock Start-Sleep -ModuleName CyberArkComms { } }

    It 'C78 - a finished job with no failures is Completed and Succeeded, read with displayExtendedItems' {
        Mock Invoke-CyberArkAPI -ModuleName CyberArkComms { New-BulkJobResponse -Status 'Succeeded' -Total 1 -Succeeded 1 -Failed 0 }
        $r = Wait-CyberArkBulkAction -Token $script:BulkToken -BulkId '11'
        $r.Completed | Should -BeTrue
        $r.Succeeded | Should -BeTrue
        Should -Invoke Invoke-CyberArkAPI -ModuleName CyberArkComms -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq '/API/BulkActions/11' -and $QueryParams['displayExtendedItems'] -eq 'true' -and $PageSize -eq 0
        }
    }

    It 'C79 - a failed job reports each failed item''s ErrorCode and message' {
        $item = [PSCustomObject]@{ Status = 'Failed'; Error = [PSCustomObject]@{ ErrorCode = 'CAWS00001E'; ErrorMessage = 'Not a valid Win32 FileTime.' } }
        Mock Invoke-CyberArkAPI -ModuleName CyberArkComms { New-BulkJobResponse -Status 'Failed' -Total 1 -Succeeded 0 -Failed 1 -FailedItems @($item) }
        $r = Wait-CyberArkBulkAction -Token $script:BulkToken -BulkId '11'
        $r.Completed | Should -BeTrue
        $r.Succeeded | Should -BeFalse
        $r.ErrorMessage | Should -Be 'CAWS00001E: Not a valid Win32 FileTime.'
    }

    It 'C80 - a job still running is polled again until it finishes' {
        $script:BulkCalls = 0
        Mock Invoke-CyberArkAPI -ModuleName CyberArkComms {
            $script:BulkCalls++
            if ($script:BulkCalls -lt 3) { New-BulkJobResponse -Status 'InProgress' -Total 1 -Succeeded 0 -Failed 0 }
            else { New-BulkJobResponse -Status 'Succeeded' -Total 1 -Succeeded 1 -Failed 0 }
        }
        $r = Wait-CyberArkBulkAction -Token $script:BulkToken -BulkId '11' -TimeoutSec 60
        $r.Succeeded | Should -BeTrue
        Should -Invoke Invoke-CyberArkAPI -ModuleName CyberArkComms -Times 3 -Exactly
        Should -Invoke Start-Sleep -ModuleName CyberArkComms -Times 2 -Exactly
    }

    It 'C81 - a job that never finishes, or an unreadable job, is not Completed' {
        Mock Invoke-CyberArkAPI -ModuleName CyberArkComms { New-BulkJobResponse -Status 'InProgress' -Total 1 -Succeeded 0 -Failed 0 }
        $r = Wait-CyberArkBulkAction -Token $script:BulkToken -BulkId '11' -TimeoutSec 0
        $r.Completed | Should -BeFalse
        $r.ErrorMessage | Should -Match 'did not finish'

        Mock Invoke-CyberArkAPI -ModuleName CyberArkComms {
            [PSCustomObject]@{ IsSuccess = $false; StatusCode = 404; ErrorMessage = 'Not found'; ErrorDetails = $null; Data = $null }
        }
        $r = Wait-CyberArkBulkAction -Token $script:BulkToken -BulkId '11'
        $r.Completed | Should -BeFalse
        $r.StatusCode | Should -Be 404
    }
}
