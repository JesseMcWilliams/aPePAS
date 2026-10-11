#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsListOnboardingPlatforms.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsListOnboardingPlatforms.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsListOnboardingPlatformsTests' -MinLevel 'ERROR'

    $script:Token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
    $script:Valid = @{ SafeName = 'Test Accounts'; DiscoveryPlatformType = 'Windows Desktop Local' }

    # Shape confirmed live 2026-10-11: { "Platforms": [ { platformID, platformName, isRecommended, ... } ] }
    function script:New-OkResponse {
        [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null
            Data = [PSCustomObject]@{ Platforms = @(
                [PSCustomObject]@{ platformID = 'WinDesktopLocal'; platformName = 'Windows Desktop Local Accounts'; isRecommended = $true; isSSHKeysPlatform = $false; isAutomaticReconcileAllowed = $false },
                [PSCustomObject]@{ platformID = 'UnixSSHKeys'; platformName = 'Unix via SSH Keys'; isRecommended = $false; isSSHKeysPlatform = $true; isAutomaticReconcileAllowed = $false }
            ) } }
    }
    function script:New-ErrResponse {
        param([int]$StatusCode, [string]$Message = 'Error')
        [PSCustomObject]@{ IsSuccess = $false; StatusCode = $StatusCode; ErrorMessage = $Message
                           ErrorDetails = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $Message }; Data = $null }
    }
}

Describe 'Invoke-AccountsListOnboardingPlatforms' {

    It 'OP01 - ModuleMeta: Self-Hosted only; SafeName and DiscoveryPlatformType required' {
        $ModuleMeta.Action           | Should -Be 'ListOnboardingPlatforms'
        $ModuleMeta.SupportedSystems | Should -Be @('SelfHosted')
        @($ModuleMeta.InputSchema | Where-Object { $_.Required } | ForEach-Object { $_.Column }) | Should -Be @('SafeName', 'DiscoveryPlatformType')
    }

    It 'OP02 - GET /API/DiscoveredAccounts/Platforms with both query values and -PageSize 0' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        Invoke-AccountsListOnboardingPlatforms -Token $script:Token -InputData $script:Valid | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq '/API/DiscoveredAccounts/Platforms' -and $PageSize -eq 0 -and
            $QueryParams['safeName'] -eq 'Test Accounts' -and $QueryParams['discoveryPlatformType'] -eq 'Windows Desktop Local'
        }
    }

    It 'OP03 - one row per platform with the recommended and SSH key flags' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        $r = Invoke-AccountsListOnboardingPlatforms -Token $script:Token -InputData $script:Valid
        $r.Successes                    | Should -Be 2
        $r.Results[0].PlatformID        | Should -Be 'WinDesktopLocal'
        $r.Results[0].IsRecommended     | Should -BeTrue
        $r.Results[1].IsSSHKeysPlatform | Should -BeTrue
    }

    It 'OP04 - a missing required value fails with no API call' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse }
        (Invoke-AccountsListOnboardingPlatforms -Token $script:Token -InputData @{ SafeName = 'Test Accounts' }).Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'OP05 - error keeps the API message; 401 is fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 400 -Message 'ERR400: bad type' }
        $r = Invoke-AccountsListOnboardingPlatforms -Token $script:Token -InputData $script:Valid
        $r.Errors[0].ErrorMessage | Should -Match 'ERR400: bad type'
        $r.IsFatal                | Should -BeFalse
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        (Invoke-AccountsListOnboardingPlatforms -Token $script:Token -InputData $script:Valid).IsFatal | Should -BeTrue
    }
}
