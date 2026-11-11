#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsVerify.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsVerify.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsVerifyTests' -MinLevel 'ERROR'
}

Describe 'Invoke-AccountsVerify' {

    Context 'Missing AccountID' {
        It 'returns failure when AccountID is not provided' {
            $token  = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            $result = Invoke-AccountsVerify -Token $token -InputData @{}
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
            $result = Invoke-AccountsVerify -Token $token -InputData @{ AccountID = 'acc123' }
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
            $result = Invoke-AccountsVerify -Token $token -InputData @{ AccountID = 'acc123' }
            $result.Successes   | Should -BeGreaterThan 0
            $result.Failures    | Should -Be 0
        }
    }

    Context 'WhatIf mode' {
        It 'does not call the API when WhatIf is set' {
            $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
            Mock Invoke-CyberArkAPI { throw 'Should not be called in WhatIf mode' }
            Mock Add-CyberArkLogSummaryEntry {}
            { Invoke-AccountsVerify -Token $token -InputData @{ AccountID = 'acc123' } -WhatIf } | Should -Not -Throw
        }
    }

}

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# ResumeIfDisabled (feature item 4). The decision logic is tested with the shared helper in
# CyberArkComms.Tests.ps1; here the helper is mocked and only the module's use of it is checked.
Describe 'Invoke-AccountsVerify - ResumeIfDisabled' {

    BeforeAll {
        $script:RidToken = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1); SystemType = 'SelfHosted' }
        function script:New-ResumeStep([string]$Outcome, [int]$Code = 200) {
            [PSCustomObject]@{
                Outcome = $Outcome; Resumed = ($Outcome -eq 'Resumed')
                LogLevel = $(if ($Outcome -eq 'Failed') { 'ERROR' } else { 'INFO' }); Message = "step $Outcome"
                StatusCode = $Code; ErrorMessage = $(if ($Outcome -eq 'Failed') { 'resume failed' } else { '' }); ErrorDetails = $null
            }
        }
    }

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{} }
        }
    }

    It 'without ResumeIfDisabled the helper is not called and Resumed is False' {
        Mock Invoke-CyberArkAccountResumeIfCpmDisabled { throw 'Should not be called' }
        $result = Invoke-AccountsVerify -Token $script:RidToken -InputData @{ AccountID = '30_12' }
        $result.Successes | Should -Be 1
        $result.Results[0].Resumed | Should -Be $false
    }

    It 'ResumeIfDisabled No leaves the helper out' {
        Mock Invoke-CyberArkAccountResumeIfCpmDisabled { throw 'Should not be called' }
        $result = Invoke-AccountsVerify -Token $script:RidToken -InputData @{ AccountID = '30_12'; ResumeIfDisabled = 'No' }
        $result.Successes | Should -Be 1
    }

    It 'a CPM-disabled account is resumed, then the action runs, and Resumed is True' {
        Mock Invoke-CyberArkAccountResumeIfCpmDisabled { New-ResumeStep 'Resumed' }
        $result = Invoke-AccountsVerify -Token $script:RidToken -InputData @{ AccountID = '30_12'; ResumeIfDisabled = 'yes' }
        $result.Successes | Should -Be 1
        $result.Results[0].Resumed | Should -Be $true
        Should -Invoke Invoke-CyberArkAccountResumeIfCpmDisabled -Times 1 -Exactly -ParameterFilter { $AccountId -eq '30_12' }
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Endpoint -eq '/API/Accounts/30_12/Verify' }
    }

    It 'a JSON true value turns it on too' {
        Mock Invoke-CyberArkAccountResumeIfCpmDisabled { New-ResumeStep 'NotDisabled' }
        $result = Invoke-AccountsVerify -Token $script:RidToken -InputData @{ AccountID = '30_12'; ResumeIfDisabled = $true }
        $result.Successes | Should -Be 1
        $result.Results[0].Resumed | Should -Be $false
        Should -Invoke Invoke-CyberArkAccountResumeIfCpmDisabled -Times 1 -Exactly
    }

    It 'a user-disabled account is not resumed, and the action still runs' {
        Mock Invoke-CyberArkAccountResumeIfCpmDisabled { New-ResumeStep 'DisabledByUser' }
        $result = Invoke-AccountsVerify -Token $script:RidToken -InputData @{ AccountID = '30_12'; ResumeIfDisabled = 'Yes' }
        $result.Results[0].Resumed | Should -Be $false
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly
    }

    It 'a failed resume fails the row and skips the action' {
        Mock Invoke-CyberArkAccountResumeIfCpmDisabled { New-ResumeStep 'Failed' 403 }
        $result = Invoke-AccountsVerify -Token $script:RidToken -InputData @{ AccountID = '30_12'; ResumeIfDisabled = 'Yes' }
        $result.Failures | Should -Be 1
        $result.IsFatal  | Should -Be $false
        $result.Errors[0].ErrorMessage | Should -Be 'resume failed'
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'a 401 during the resume step is fatal' {
        Mock Invoke-CyberArkAccountResumeIfCpmDisabled { New-ResumeStep 'Failed' 401 }
        $result = Invoke-AccountsVerify -Token $script:RidToken -InputData @{ AccountID = '30_12'; ResumeIfDisabled = 'Yes' }
        $result.IsFatal | Should -Be $true
    }

    It 'WhatIf passes -WhatIf to the helper and makes no action call' {
        Mock Invoke-CyberArkAccountResumeIfCpmDisabled { New-ResumeStep 'WouldResume' }
        $result = Invoke-AccountsVerify -Token $script:RidToken -InputData @{ AccountID = '30_12'; ResumeIfDisabled = 'Yes' } -WhatIf
        $result.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAccountResumeIfCpmDisabled -Times 1 -Exactly -ParameterFilter { $WhatIf.IsPresent }
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }
}
