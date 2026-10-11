#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsRetrieveSshKey.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsRetrieveSshKey.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    # Same driver-scope stub as Invoke-ReportsExport.Tests.ps1: run Action once, report success.
    function global:Invoke-FileWriteWithRetry {
        param([scriptblock]$Action, [string]$Path)
        try { & $Action; return $true } catch { return $false }
    }

    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsRetrieveSshKeyTests' -MinLevel 'ERROR'

    $script:Token   = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
    $script:FakeKey = "-----BEGIN OPENSSH PRIVATE KEY-----`nFAKEKEYDATA`n-----END OPENSSH PRIVATE KEY-----`n"

    function script:New-OkResponse {
        param([object]$Data, [string]$DataType = 'JSON')
        [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $Data; DataType = $DataType }
    }
    function script:New-ErrResponse {
        param([int]$StatusCode, [string]$Message = 'Error')
        [PSCustomObject]@{ IsSuccess = $false; StatusCode = $StatusCode; ErrorMessage = $Message
                           ErrorDetails = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $Message }; Data = $null; DataType = 'JSON' }
    }
}

AfterAll {
    Remove-Item -Path function:global:Invoke-FileWriteWithRetry -ErrorAction SilentlyContinue
}

Describe 'Invoke-AccountsRetrieveSshKey - ModuleMeta' {

    It 'SK01 - Category, Action and Name are set' {
        $ModuleMeta.Category | Should -Be 'Accounts'
        $ModuleMeta.Action   | Should -Be 'RetrieveSshKey'
        $ModuleMeta.Name     | Should -Be 'Retrieve SSH Key'
    }

    It 'SK02 - read action with no CSV input: SupportsWhatIf and AcceptsInputFile are $false, ProducesOutput is $true' {
        $ModuleMeta.SupportsWhatIf   | Should -BeFalse
        $ModuleMeta.AcceptsInputFile | Should -BeFalse
        $ModuleMeta.ProducesOutput   | Should -BeTrue
    }
}

Describe 'Invoke-AccountsRetrieveSshKey - success' {

    BeforeEach {
        $script:ActiveProfile = [PSCustomObject]@{ OutputFolder = $TestDrive }
        Mock Add-CyberArkLogSummaryEntry { }
        Mock Write-CyberArkLog { }
    }

    AfterEach {
        Remove-Variable -Name ActiveProfile -Scope Script -ErrorAction SilentlyContinue
    }

    It 'SK03 - POSTs to /API/Accounts/{id}/Secret/Retrieve with only the fields given' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data $script:FakeKey }
        Invoke-AccountsRetrieveSshKey -Token $script:Token -InputData @{ AccountID = '12_34'; Reason = 'Maintenance'; TicketId = '' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Endpoint -eq '/API/Accounts/12_34/Secret/Retrieve' -and
            $Body['Reason'] -eq 'Maintenance' -and -not $Body.ContainsKey('TicketId') -and -not $Body.ContainsKey('TicketingSystem')
        }
    }

    It 'SK04 - a text key is saved to a .key file in the Output Folder; the result has the path, not the key' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data $script:FakeKey }
        $r = Invoke-AccountsRetrieveSshKey -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.Successes | Should -Be 1
        $path = $r.Results[0].KeyFile
        $path | Should -BeLike (Join-Path $TestDrive 'SSHKey-12_34-*.key')
        [IO.File]::ReadAllText($path) | Should -Be $script:FakeKey
        ($r.Results[0].PSObject.Properties | ForEach-Object { "$($_.Value)" }) -join '|' | Should -Not -Match 'FAKEKEYDATA'
    }

    It 'SK05 - the key file has no BOM' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data $script:FakeKey }
        $r = Invoke-AccountsRetrieveSshKey -Token $script:Token -InputData @{ AccountID = '12_34' }
        $bytes = [IO.File]::ReadAllBytes($r.Results[0].KeyFile)
        $bytes[0] | Should -Be ([byte][char]'-')
    }

    It 'SK06 - a File (bytes) response is saved byte for byte' {
        $raw = [Text.Encoding]::ASCII.GetBytes($script:FakeKey)
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data $raw -DataType 'File' }
        $r = Invoke-AccountsRetrieveSshKey -Token $script:Token -InputData @{ AccountID = '12_34' }
        [IO.File]::ReadAllBytes($r.Results[0].KeyFile) | Should -Be $raw
    }

    It 'SK07 - a JSON object with Content is saved from Content' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data ([PSCustomObject]@{ Content = $script:FakeKey }) }
        $r = Invoke-AccountsRetrieveSshKey -Token $script:Token -InputData @{ AccountID = '12_34' }
        [IO.File]::ReadAllText($r.Results[0].KeyFile) | Should -Be $script:FakeKey
    }

    It 'SK08 - the key value is never written to the log' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data $script:FakeKey }
        Invoke-AccountsRetrieveSshKey -Token $script:Token -InputData @{ AccountID = '12_34' } | Out-Null
        Should -Invoke Write-CyberArkLog -Times 0 -ParameterFilter { $Message -match 'FAKEKEYDATA' }
    }
}

Describe 'Invoke-AccountsRetrieveSshKey - failures' {

    BeforeEach {
        $script:ActiveProfile = [PSCustomObject]@{ OutputFolder = $TestDrive }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    AfterEach {
        Remove-Variable -Name ActiveProfile -Scope Script -ErrorAction SilentlyContinue
    }

    It 'SK09 - no identifier: Failures=1, no API call' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data $script:FakeKey }
        $r = Invoke-AccountsRetrieveSshKey -Token $script:Token -InputData @{}
        $r.Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'SK10 - an unknown response shape fails and reports property names only, never values' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data ([PSCustomObject]@{ privateKey = 'FAKEKEYDATA' }) }
        $r = Invoke-AccountsRetrieveSshKey -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.Failures               | Should -Be 1
        $r.Errors[0].ErrorMessage | Should -Match 'privateKey'
        $r.Errors[0].ErrorMessage | Should -Not -Match 'FAKEKEYDATA'
        @(Get-ChildItem -Path $TestDrive -Filter 'SSHKey-*' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'SK11 - 401: IsFatal=$true' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        $r = Invoke-AccountsRetrieveSshKey -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.IsFatal | Should -BeTrue
    }

    It 'SK12 - 403 (for example a reason is required): error keeps the API message, not fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 403 -Message 'ERR403: reason required' }
        $r = Invoke-AccountsRetrieveSshKey -Token $script:Token -InputData @{ AccountID = '12_34' }
        $r.IsFatal                          | Should -BeFalse
        $r.Errors[0].ErrorMessage           | Should -Match 'ERR403: reason required'
        $r.Errors[0].ErrorDetails.ErrorCode | Should -Be 'ERR403'
    }

    It 'SK13 - AccountName + Safe resolves the account ID before the POST' {
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'GET' } {
            script:New-OkResponse -Data ([PSCustomObject]@{ value = @(
                [PSCustomObject]@{ id = '77_2'; name = 'linux-root'; userName = 'root'; safeName = 'LinuxSafe' }
            ) })
        }
        Mock Invoke-CyberArkAPI -ParameterFilter { $Method -eq 'POST' } { script:New-OkResponse -Data $script:FakeKey }
        $r = Invoke-AccountsRetrieveSshKey -Token $script:Token -InputData @{ AccountName = 'linux-root'; Safe = 'LinuxSafe' }
        $r.Successes | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Endpoint -eq '/API/Accounts/77_2/Secret/Retrieve' }
    }
}
