#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsResumeAutoManagement.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsResumeAutoManagement.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsResumeAutoManagementTests' -MinLevel 'ERROR'
}

Describe 'Invoke-AccountsResumeAutoManagement' {

    Context 'Missing AccountID' {
        It 'returns failure when AccountID is not provided' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-AccountsResumeAutoManagement -Token $token -InputData @{}
            $result.Failures    | Should -Be 1
            $result.Successes   | Should -Be 0
            $result.IsFatal     | Should -Be $false
        }
    }

    Context 'API call failure' {
        It 'records error on non-success response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 404; ErrorMessage = 'Not Found'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-AccountsResumeAutoManagement -Token $token -InputData @{ AccountID = 'acc123' }
            $result.Failures    | Should -BeGreaterThan 0
            $result.IsFatal     | Should -Be $false
        }
    }

    Context 'Successful operation' {
        It 'records success on 200/204 response' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{} }
            }
            $result = Invoke-AccountsResumeAutoManagement -Token $token -InputData @{ AccountID = 'acc123' }
            $result.Successes   | Should -BeGreaterThan 0
            $result.Failures    | Should -Be 0
        }
    }

    Context 'WhatIf mode' {
        It 'does not call the API when WhatIf is set' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI { throw 'Should not be called in WhatIf mode' }
            Mock Add-CyberArkLogSummaryEntry {}
            { Invoke-AccountsResumeAutoManagement -Token $token -InputData @{ AccountID = 'acc123' } -WhatIf } | Should -Not -Throw
        }
    }

}

# ─────────────────────────────────────────────────────────────────
# Endpoint and method differ by platform for this action - Self-Hosted confirmed against a
# live tenant (POST .../Resume/, no body), ISPSS unconfirmed and unchanged (PATCH .../ with a
# JSON Patch body). See Invoke-AccountsResumeAutoManagement.ps1's $isSelfHosted branch.
Describe 'Invoke-AccountsResumeAutoManagement - endpoint by platform' {

    It 'Self-Hosted: calls POST /API/Accounts/{id}/Resume/ with no body' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1); SystemType = 'SelfHosted' }
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedCall -Value $PSBoundParameters -Scope Script
            [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{} }
        }
        Invoke-AccountsResumeAutoManagement -Token $token -InputData @{ AccountID = 'acc123' }
        $script:capturedCall.Method   | Should -Be 'POST'
        $script:capturedCall.Endpoint | Should -Be '/API/Accounts/acc123/Resume/'
        $script:capturedCall.ContainsKey('Body') | Should -Be $false
    }

    It 'ISPSS: calls PATCH /API/Accounts/{id}/ with a JSON Patch body re-enabling automatic management' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1); SystemType = 'ISPSS' }
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedCall -Value $PSBoundParameters -Scope Script
            [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{} }
        }
        Invoke-AccountsResumeAutoManagement -Token $token -InputData @{ AccountID = 'acc123' }
        $script:capturedCall.Method   | Should -Be 'PATCH'
        $script:capturedCall.Endpoint | Should -Be '/API/Accounts/acc123/'

        [array]$body = $script:capturedCall.Body
        $body.Count | Should -Be 2
        $body[0].op    | Should -Be 'replace'
        $body[0].path  | Should -Be '/secretManagement/automaticManagementEnabled'
        $body[0].value | Should -Be 'true'
        $body[1].op    | Should -Be 'replace'
        $body[1].path  | Should -Be '/secretManagement/manualManagementReason'
        $body[1].value | Should -Be ''
    }

    It 'no SystemType on token (legacy fixture) - defaults to the ISPSS/PATCH path' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            Set-Variable -Name capturedCall -Value $PSBoundParameters -Scope Script
            [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{} }
        }
        Invoke-AccountsResumeAutoManagement -Token $token -InputData @{ AccountID = 'acc123' }
        $script:capturedCall.Method   | Should -Be 'PATCH'
        $script:capturedCall.Endpoint | Should -Be '/API/Accounts/acc123/'
    }
}

Describe 'Invoke-AccountsResumeAutoManagement - pre-15.2 Self-Hosted fallback (404 on /Resume/)' {

    It 'falls back to PATCH automaticManagementEnabled and succeeds when /Resume/ 404s' {
        # /Resume/ requires PVWA 15.2+ (per psPAS's Resume-PASCPMAutoManagement.ps1) and there
        # is no reliable way to check the PVWA version up front, so a 404 here is treated as
        # "this endpoint doesn't exist on this server" and retried with the same version-
        # agnostic AutoManaged-attribute PATCH already used for ISPSS.
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1); SystemType = 'SelfHosted' }
        $calls = [System.Collections.Generic.List[PSCustomObject]]::new()
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            $calls.Add([PSCustomObject]@{ Method = $Method; Endpoint = $Endpoint; Body = $Body })
            if ($Method -eq 'POST') {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 404; ErrorMessage = 'Not Found'; ErrorDetails = $null; Data = $null }
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
            }
        }
        $result = Invoke-AccountsResumeAutoManagement -Token $token -InputData @{ AccountID = 'acc123' }
        $result.Successes | Should -Be 1
        $result.Failures  | Should -Be 0
        $calls.Count | Should -Be 2
        $calls[0].Method   | Should -Be 'POST'
        $calls[0].Endpoint | Should -Be '/API/Accounts/acc123/Resume/'
        $calls[1].Method   | Should -Be 'PATCH'
        $calls[1].Endpoint | Should -Be '/API/Accounts/acc123/'
        [array]$fallbackBody = $calls[1].Body
        $fallbackBody[0].path | Should -Be '/secretManagement/automaticManagementEnabled'
    }

    It 'does not fall back on a non-404 failure (e.g. 403) - only one API call is made' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1); SystemType = 'SelfHosted' }
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{ IsSuccess = $false; StatusCode = 403; ErrorMessage = 'Forbidden'; ErrorDetails = $null; Data = $null }
        }
        $result = Invoke-AccountsResumeAutoManagement -Token $token -InputData @{ AccountID = 'acc123' }
        $result.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1
    }

    It 'reports failure when the fallback also fails' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1); SystemType = 'SelfHosted' }
        Mock Invoke-CyberArkAPI {
            param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
            if ($Method -eq 'POST') {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 404; ErrorMessage = 'Not Found'; ErrorDetails = $null; Data = $null }
            } else {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 500; ErrorMessage = 'Server Error'; ErrorDetails = $null; Data = $null }
            }
        }
        $result = Invoke-AccountsResumeAutoManagement -Token $token -InputData @{ AccountID = 'acc123' }
        $result.Failures  | Should -Be 1
        $result.Successes | Should -Be 0
        Should -Invoke Invoke-CyberArkAPI -Times 2
    }
}
