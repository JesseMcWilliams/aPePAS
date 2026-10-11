#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsDeleteDiscovered.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsDeleteDiscovered.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsDeleteDiscoveredTests' -MinLevel 'ERROR'

    $script:Token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
    function script:New-OkResponse { [PSCustomObject]@{ IsSuccess = $true; StatusCode = 204; ErrorMessage = ''; ErrorDetails = $null; Data = $null } }
    function script:New-ErrResponse {
        param([int]$StatusCode, [string]$Message = 'Error')
        [PSCustomObject]@{ IsSuccess = $false; StatusCode = $StatusCode; ErrorMessage = $Message
                           ErrorDetails = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $Message }; Data = $null }
    }
}

Describe 'Invoke-AccountsDeleteDiscovered' {

    BeforeEach { Mock Add-CyberArkLogSummaryEntry { } }

    It 'DD01 - ModuleMeta: write action, CSV input, Self-Hosted only' {
        $ModuleMeta.Action           | Should -Be 'DeleteDiscovered'
        $ModuleMeta.SupportsWhatIf   | Should -BeTrue
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.SupportedSystems | Should -Be @('SelfHosted')
    }

    It 'DD02 - DELETE /API/DiscoveredAccounts/{id} (never the clear-all DELETE on the collection)' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        $r = Invoke-AccountsDeleteDiscovered -Token $script:Token -InputData @{ DiscoveredAccountID = 'd-1' }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' -and $Endpoint -eq '/API/DiscoveredAccounts/d-1' }
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly -ParameterFilter { $Endpoint -eq '/API/DiscoveredAccounts' }
    }

    It 'DD03 - WhatIf: no API call' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        $r = Invoke-AccountsDeleteDiscovered -Token $script:Token -InputData @{ DiscoveredAccountID = 'd-1' } -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
        $r.Results[0].Status | Should -Be 'WhatIf'
    }

    It 'DD04 - missing ID: Failures=1 and no API call (so it can never fall through to clear-all)' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        (Invoke-AccountsDeleteDiscovered -Token $script:Token -InputData @{ DiscoveredAccountID = '  ' }).Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'DD05 - 404 adds the PVWA 12.1 hint; 401 is fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -Message 'ERR404: not found' }
        (Invoke-AccountsDeleteDiscovered -Token $script:Token -InputData @{ DiscoveredAccountID = 'd-1' }).Errors[0].ErrorMessage | Should -Match '12\.1'
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        (Invoke-AccountsDeleteDiscovered -Token $script:Token -InputData @{ DiscoveredAccountID = 'd-1' }).IsFatal | Should -BeTrue
    }
}
