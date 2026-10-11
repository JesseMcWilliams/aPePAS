#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsOnboardDiscovered.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsOnboardDiscovered.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsOnboardDiscoveredTests' -MinLevel 'ERROR'

    $script:Token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
    $script:Valid = @{ DiscoveredAccountID = 'd-1'; SafeName = 'Win Safe'; PlatformID = 'WinServerLocal' }

    function script:New-OkResponse { param([object]$Data = [PSCustomObject]@{}) [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $Data } }
    function script:New-ErrResponse {
        param([int]$StatusCode, [string]$Message = 'Error')
        [PSCustomObject]@{ IsSuccess = $false; StatusCode = $StatusCode; ErrorMessage = $Message
                           ErrorDetails = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $Message }; Data = $null }
    }
}

Describe 'Invoke-AccountsOnboardDiscovered - ModuleMeta' {

    It 'OD01 - write action, CSV input, Self-Hosted only; DiscoveredAccountID, SafeName, PlatformID required' {
        $ModuleMeta.Action           | Should -Be 'OnboardDiscovered'
        $ModuleMeta.SupportsWhatIf   | Should -BeTrue
        $ModuleMeta.AcceptsInputFile | Should -BeTrue
        $ModuleMeta.SupportedSystems | Should -Be @('SelfHosted')
        $required = @($ModuleMeta.InputSchema | Where-Object { $_.Required } | ForEach-Object { $_.Column })
        $required | Should -Be @('DiscoveredAccountID', 'SafeName', 'PlatformID')
    }
}

Describe 'Invoke-AccountsOnboardDiscovered - request' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'OD02 - POST /API/DiscoveredAccounts/{id}/Onboard with platformId and safeName, no query when not asked' {
        Invoke-AccountsOnboardDiscovered -Token $script:Token -InputData $script:Valid | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/DiscoveredAccounts/d-1/Onboard' -and
            $Body['platformId'] -eq 'WinServerLocal' -and $Body['safeName'] -eq 'Win Safe' -and
            -not $Body.ContainsKey('shouldReconcileAccount') -and -not $Body.ContainsKey('defaultPassword') -and $null -eq $QueryParams
        }
    }

    It 'OD03 - ShouldReconcileAccount goes in the body as a boolean; AllowAccountDuplications goes in the query (14.6 Swagger)' {
        $in = $script:Valid.Clone(); $in['ShouldReconcileAccount'] = 'TRUE'; $in['AllowAccountDuplications'] = 'false'
        Invoke-AccountsOnboardDiscovered -Token $script:Token -InputData $in | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Body['shouldReconcileAccount'] -eq $true -and $QueryParams['allowAccountDuplications'] -eq 'false'
        }
    }

    It 'OD04 - DefaultPassword is sent as defaultPassword, untrimmed' {
        $in = $script:Valid.Clone(); $in['DefaultPassword'] = ' ThisIsMy_FAKE_Password6! '
        Invoke-AccountsOnboardDiscovered -Token $script:Token -InputData $in | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Body['defaultPassword'] -eq ' ThisIsMy_FAKE_Password6! ' }
    }

    It 'OD05 - DefaultPassword never appears in the log' {
        Mock Write-CyberArkLog { }
        $in = $script:Valid.Clone(); $in['DefaultPassword'] = 'ThisIsMy_FAKE_Password6!'
        Invoke-AccountsOnboardDiscovered -Token $script:Token -InputData $in | Out-Null
        Should -Invoke Write-CyberArkLog -Times 0 -ParameterFilter { $Message -match 'FAKE_Password' }
    }

    It 'OD06 - result shows the new account ID when the PVWA returns one' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data ([PSCustomObject]@{ id = '30_99' }) }
        $r = Invoke-AccountsOnboardDiscovered -Token $script:Token -InputData $script:Valid
        $r.Successes            | Should -Be 1
        $r.Results[0].AccountID | Should -Be '30_99'
        $r.Results[0].Status    | Should -Be 'Onboarded'
    }

    It 'OD07 - WhatIf: no API call' {
        $r = Invoke-AccountsOnboardDiscovered -Token $script:Token -InputData $script:Valid -WhatIf
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
        $r.Results[0].Status | Should -Be 'WhatIf'
    }
}

Describe 'Invoke-AccountsOnboardDiscovered - validation and errors' {

    BeforeEach { Mock Add-CyberArkLogSummaryEntry { } }

    It 'OD08 - missing SafeName and PlatformID: one failure naming both, no API call' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        $r = Invoke-AccountsOnboardDiscovered -Token $script:Token -InputData @{ DiscoveredAccountID = 'd-1' }
        $r.Failures               | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'SafeName, PlatformID'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'OD09 - ShouldReconcileAccount that is not true/false fails with no API call' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        $in = $script:Valid.Clone(); $in['ShouldReconcileAccount'] = 'maybe'
        (Invoke-AccountsOnboardDiscovered -Token $script:Token -InputData $in).Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'OD10 - 404 adds the PVWA 12.6 hint and keeps the API message' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 404 -Message 'ERR404: not found' }
        $msg = (Invoke-AccountsOnboardDiscovered -Token $script:Token -InputData $script:Valid).Errors[0].ErrorMessage
        $msg | Should -Match 'ERR404: not found'
        $msg | Should -Match '12\.6'
    }

    It 'OD11 - 401 is fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        (Invoke-AccountsOnboardDiscovered -Token $script:Token -InputData $script:Valid).IsFatal | Should -BeTrue
    }
}
