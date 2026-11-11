#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsResumeCpmDisabled (feature item 9).
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsResumeCpmDisabled.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsResumeCpmDisabledTests' -MinLevel 'ERROR'

    $script:Token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1); SystemType = 'SelfHosted' }

    function script:New-Acct([string]$Id, [string]$Platform = 'WinServerLocal', [string]$Safe = 'Test Accounts') {
        [PSCustomObject]@{
            id = $Id; name = "acct-$Id"; userName = "user$Id"; address = 'host.local'; safeName = $Safe; platformId = $Platform
            secretManagement = [PSCustomObject]@{ automaticManagementEnabled = $false; manualManagementReason = '(CPM)MaxRetries' }
        }
    }
    function script:New-ListResp([object[]]$Accounts) {
        [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ value = @($Accounts) } }
    }
    function script:New-ResumeOut([bool]$Ok = $true, [int]$Code = 200, [bool]$FellBack = $false) {
        [PSCustomObject]@{
            Response = [PSCustomObject]@{ IsSuccess = $Ok; StatusCode = $Code; ErrorMessage = $(if ($Ok) { '' } else { "E$Code" }); ErrorDetails = $null }
            Method = 'POST'; Endpoint = '/API/Accounts/x/Resume/'; FellBack = $FellBack
        }
    }
}

Describe 'Invoke-AccountsResumeCpmDisabled - list query' {

    It 'always asks for DisabledPasswordByCPM, with the safe filter and search when given' {
        Mock Invoke-CyberArkAPI { New-ListResp @() }
        Invoke-AccountsResumeCpmDisabled -Token $script:Token -InputData @{ Safe = 'Test Accounts'; Search = 'Server2019PSM' } -WhatIf | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq '/API/Accounts' -and
            $QueryParams['savedFilter'] -eq 'DisabledPasswordByCPM' -and
            $QueryParams['filter'] -eq 'safeName eq "Test Accounts"' -and
            $QueryParams['search'] -eq 'Server2019PSM'
        }
    }

    It 'sends no filter or search when none is given' {
        Mock Invoke-CyberArkAPI { New-ListResp @() }
        Invoke-AccountsResumeCpmDisabled -Token $script:Token -InputData @{} -WhatIf | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $QueryParams['savedFilter'] -eq 'DisabledPasswordByCPM' -and -not $QueryParams.ContainsKey('filter') -and -not $QueryParams.ContainsKey('search')
        }
    }

    It 'no matches: nothing processed, no resume' {
        Mock Invoke-CyberArkAPI { New-ListResp @() }
        Mock Invoke-CyberArkAccountResume { throw 'Should not be called' }
        $r = Invoke-AccountsResumeCpmDisabled -Token $script:Token -InputData @{ Confirm = 'Yes' }
        $r.ItemsProcessed | Should -Be 0
        $r.Failures       | Should -Be 0
    }

    It 'a failed list fails the run; 401 is fatal' {
        Mock Invoke-CyberArkAPI { [PSCustomObject]@{ IsSuccess = $false; StatusCode = 401; ErrorMessage = 'Unauthorized'; ErrorDetails = $null; Data = $null } }
        $r = Invoke-AccountsResumeCpmDisabled -Token $script:Token -InputData @{ Confirm = 'Yes' }
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -Be $true
        $r.Errors[0].ErrorMessage | Should -Match 'HTTP 401'
    }

    It 'PlatformID is matched on the client, ignoring case' {
        Mock Invoke-CyberArkAPI { New-ListResp @((New-Acct '1' 'WinServerLocal'), (New-Acct '2' 'UnixSSH'), (New-Acct '3' 'winserverlocal')) }
        $r = Invoke-AccountsResumeCpmDisabled -Token $script:Token -InputData @{ PlatformID = 'WINSERVERLOCAL' } -WhatIf
        @($r.Results | ForEach-Object { $_.AccountID }) -join ',' | Should -Be '1,3'
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { -not $QueryParams.ContainsKey('filter') }
    }
}

Describe 'Invoke-AccountsResumeCpmDisabled - WhatIf and confirmation' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { New-ListResp @((New-Acct '30_28'), (New-Acct '60_3')) }
    }

    It 'WhatIf lists every match as WouldResume and resumes nothing' {
        Mock Invoke-CyberArkAccountResume { New-ResumeOut }
        $r = Invoke-AccountsResumeCpmDisabled -Token $script:Token -InputData @{} -WhatIf
        $r.Successes | Should -Be 2
        @($r.Results | ForEach-Object { $_.Status }) -join ',' | Should -Be 'WouldResume,WouldResume'
        $r.Results[0].ManualReason | Should -Be '(CPM)MaxRetries'
        $r.Results[0].SafeName     | Should -Be 'Test Accounts'
        Should -Invoke Invoke-CyberArkAccountResume -Times 2 -Exactly -ParameterFilter { $WhatIf.IsPresent }
        Should -Invoke Invoke-CyberArkAccountResume -Times 0 -Exactly -ParameterFilter { -not $WhatIf.IsPresent }
    }

    It 'without Confirm = Yes it resumes nothing and fails the run' {
        Mock Invoke-CyberArkAccountResume { throw 'Should not be called' }
        $r = Invoke-AccountsResumeCpmDisabled -Token $script:Token -InputData @{ Confirm = 'No' }
        $r.Failures  | Should -Be 1
        $r.Successes | Should -Be 0
        $r.Errors[0].ErrorMessage | Should -Match 'Confirm is not Yes'
    }
}

Describe 'Invoke-AccountsResumeCpmDisabled - resuming' {

    BeforeEach {
        Mock Invoke-CyberArkAPI { New-ListResp @((New-Acct '30_28'), (New-Acct '60_3'), (New-Acct '32_8')) }
    }

    It 'resumes each match once and reports Resumed rows' {
        Mock Invoke-CyberArkAccountResume { New-ResumeOut }
        $r = Invoke-AccountsResumeCpmDisabled -Token $script:Token -InputData @{ Confirm = 'yes' }
        $r.Successes      | Should -Be 3
        $r.ItemsProcessed | Should -Be 3
        @($r.Results | ForEach-Object { $_.Status }) -join ',' | Should -Be 'Resumed,Resumed,Resumed'
        foreach ($id in '30_28', '60_3', '32_8') {
            Should -Invoke Invoke-CyberArkAccountResume -Times 1 -Exactly -ParameterFilter { $AccountId -eq $id }
        }
    }

    It 'a failed account is recorded and the rest still run' {
        Mock Invoke-CyberArkAccountResume { New-ResumeOut } -ParameterFilter { $AccountId -ne '60_3' }
        Mock Invoke-CyberArkAccountResume { New-ResumeOut -Ok $false -Code 403 } -ParameterFilter { $AccountId -eq '60_3' }
        $r = Invoke-AccountsResumeCpmDisabled -Token $script:Token -InputData @{ Confirm = 'Yes' }
        $r.Successes | Should -Be 2
        $r.Failures  | Should -Be 1
        $r.IsFatal   | Should -Be $false
        ($r.Results | Where-Object { $_.AccountID -eq '60_3' }).Status | Should -Be 'Failed'
        $r.Errors[0].InputData['AccountID'] | Should -Be '60_3'
    }

    It 'a 401 stops the loop and is fatal' {
        Mock Invoke-CyberArkAccountResume { New-ResumeOut -Ok $false -Code 401 }
        $r = Invoke-AccountsResumeCpmDisabled -Token $script:Token -InputData @{ Confirm = 'Yes' }
        $r.IsFatal        | Should -Be $true
        $r.ItemsProcessed | Should -Be 1
        Should -Invoke Invoke-CyberArkAccountResume -Times 1 -Exactly
    }
}

Describe 'Get-AccountsResumeCpmDisabledInput' {

    BeforeAll {
        function global:Show-FieldPrompt { param($Label, $Default, $Description, [switch]$Required, [switch]$IsSecret) return '' }
        function global:Confirm-Action { param($Message) return $global:ConfirmAnswer }
    }
    AfterAll {
        Remove-Item -Path 'Function:\global:Show-FieldPrompt', 'Function:\global:Confirm-Action' -ErrorAction SilentlyContinue
        Remove-Variable -Name ConfirmAnswer -Scope Global -ErrorAction SilentlyContinue
    }

    It 'lists the matches and returns Confirm = Yes when the user agrees' {
        Mock Invoke-CyberArkAPI { New-ListResp @((New-Acct '32_8')) }
        Mock Write-Host {}
        $global:ConfirmAnswer = $true
        $in = Get-AccountsResumeCpmDisabledInput -Token $script:Token
        $in['Confirm'] | Should -Be 'Yes'
    }

    It 'returns $null when the user declines' {
        Mock Invoke-CyberArkAPI { New-ListResp @((New-Acct '32_8')) }
        Mock Write-Host {}
        $global:ConfirmAnswer = $false
        Get-AccountsResumeCpmDisabledInput -Token $script:Token | Should -BeNullOrEmpty
    }

    It 'returns $null with no prompt when nothing matches' {
        Mock Invoke-CyberArkAPI { New-ListResp @() }
        Mock Write-Host {}
        $global:ConfirmAnswer = $true
        Get-AccountsResumeCpmDisabledInput -Token $script:Token | Should -BeNullOrEmpty
    }
}
