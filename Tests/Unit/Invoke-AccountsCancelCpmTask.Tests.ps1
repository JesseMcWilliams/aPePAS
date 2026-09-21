#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsCancelCpmTask.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsCancelCpmTask.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsCancelCpmTaskTests' -MinLevel 'ERROR'
}

Describe 'Invoke-AccountsCancelCpmTask' {

    Context 'Missing AccountID' {
        It 'returns failure when AccountID is not provided' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-AccountsCancelCpmTask -Token $token -InputData @{}
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
            $result = Invoke-AccountsCancelCpmTask -Token $token -InputData @{ AccountID = 'acc123' }
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
            $result = Invoke-AccountsCancelCpmTask -Token $token -InputData @{ AccountID = 'acc123' }
            $result.Successes   | Should -BeGreaterThan 0
            $result.Failures    | Should -Be 0
        }
    }

    Context 'WhatIf mode' {
        It 'does not call the API when WhatIf is set' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI { throw 'Should not be called in WhatIf mode' }
            Mock Add-CyberArkLogSummaryEntry {}
            { Invoke-AccountsCancelCpmTask -Token $token -InputData @{ AccountID = 'acc123' } -WhatIf } | Should -Not -Throw
        }
    }

    Context 'Pre-15.2 PVWA fallback (404 on /Cancel/)' {
        It 'falls back to /StopImmediateAutoMgmtOperations and succeeds when /Cancel/ 404s' {
            # /Cancel/ requires PVWA 15.2+ (per psPAS's Stop-PASCPMTask.ps1) and there is no
            # reliable way to check the PVWA version up front, so a 404 here is treated as
            # "this endpoint doesn't exist on this server" and retried against the older,
            # version-agnostic endpoint this module used before this session's Phase 1 change.
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $calledEndpoints = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-CyberArkAPI {
                param($Token, $Method, $Endpoint, [switch]$WhatIf)
                $calledEndpoints.Add($Endpoint)
                if ($Endpoint -like '*/Cancel/*') {
                    [PSCustomObject]@{ IsSuccess = $false; StatusCode = 404; ErrorMessage = 'Not Found'; ErrorDetails = $null; Data = $null }
                } else {
                    [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
                }
            }
            $result = Invoke-AccountsCancelCpmTask -Token $token -InputData @{ AccountID = 'acc123' }
            $result.Successes | Should -Be 1
            $result.Failures  | Should -Be 0
            $calledEndpoints.Count | Should -Be 2
            $calledEndpoints[0] | Should -BeLike '*/Cancel/*'
            $calledEndpoints[1] | Should -BeLike '*/StopImmediateAutoMgmtOperations*'
        }

        It 'does not fall back on a non-404 failure (e.g. 403) - only one API call is made' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 403; ErrorMessage = 'Forbidden'; ErrorDetails = $null; Data = $null }
            }
            $result = Invoke-AccountsCancelCpmTask -Token $token -InputData @{ AccountID = 'acc123' }
            $result.Failures | Should -Be 1
            Should -Invoke Invoke-CyberArkAPI -Times 1
        }

        It 'reports failure when the fallback also fails' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI {
                param($Token, $Method, $Endpoint, [switch]$WhatIf)
                if ($Endpoint -like '*/Cancel/*') {
                    [PSCustomObject]@{ IsSuccess = $false; StatusCode = 404; ErrorMessage = 'Not Found'; ErrorDetails = $null; Data = $null }
                } else {
                    [PSCustomObject]@{ IsSuccess = $false; StatusCode = 500; ErrorMessage = 'Server Error'; ErrorDetails = $null; Data = $null }
                }
            }
            $result = Invoke-AccountsCancelCpmTask -Token $token -InputData @{ AccountID = 'acc123' }
            $result.Failures | Should -Be 1
            $result.Successes | Should -Be 0
            Should -Invoke Invoke-CyberArkAPI -Times 2
        }
    }

    Context 'Safe name with spaces (AccountName+Safe lookup)' {
        It 'quotes the safe name in the filter expression, matching psPAS''s ConvertTo-FilterString behavior' {
            # Regression test: a raw "safeName eq $targetSafe" string interpolation (this
            # module's original implementation) sends an unquoted value for a multi-word safe
            # name, which CyberArk's filter grammar requires to be wrapped in double quotes
            # (URL-encoded to %22) - confirmed against psPAS's own ConvertTo-FilterString.ps1.
            # Fixed by routing through the shared, already-tested New-CyberArkSearchFilter
            # helper instead of building the filter string inline.
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $capturedQueryParams = $null
            Mock Invoke-CyberArkAPI {
                param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams, [switch]$WhatIf, [switch]$IgnoreSSL, $PageSizeParam, $PageOffsetParam, $PageSize)
                if ($Method -eq 'GET') {
                    Set-Variable -Name capturedQueryParams -Value $QueryParams -Scope Script
                    [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ value = @() } }
                } else {
                    [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
                }
            }
            Invoke-AccountsCancelCpmTask -Token $token -InputData @{ AccountName = 'svc-account'; Safe = 'My Safe' } | Out-Null
            $script:capturedQueryParams['filter'] | Should -Be 'safeName eq "My Safe"'
        }
    }

}
