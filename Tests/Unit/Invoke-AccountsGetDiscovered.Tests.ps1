#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-AccountsGetDiscovered.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Accounts\Invoke-AccountsGetDiscovered.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'AccountsGetDiscoveredTests' -MinLevel 'ERROR'

    $script:Token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }

    $script:Sample = [PSCustomObject]@{
        id = 'd-1'; userName = 'admin'; address = 'srv01.example.com'; platformType = 'Windows Server Local'
        userDisplayName = 'Local Admin'; organizationalUnit = 'OU=Servers'
        dependencies = @(
            [PSCustomObject]@{ name = 'Spooler'; address = 'srv01.example.com'; type = 'Windows Service' },
            [PSCustomObject]@{ name = 'Backup';  address = 'srv01.example.com'; type = 'Windows Scheduled Task' }
        )
    }
    function script:New-OkResponse { param([object]$Data) [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $Data } }
    function script:New-ErrResponse {
        param([int]$StatusCode, [string]$Message = 'Error')
        [PSCustomObject]@{ IsSuccess = $false; StatusCode = $StatusCode; ErrorMessage = $Message
                           ErrorDetails = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $Message }; Data = $null }
    }
}

Describe 'Invoke-AccountsGetDiscovered' {

    It 'GD01 - ModuleMeta: Accounts / GetDiscovered, Self-Hosted only, DiscoveredAccountID required' {
        $ModuleMeta.Action                 | Should -Be 'GetDiscovered'
        $ModuleMeta.SupportedSystems       | Should -Be @('SelfHosted')
        $ModuleMeta.InputSchema[0].Column   | Should -Be 'DiscoveredAccountID'
        $ModuleMeta.InputSchema[0].Required | Should -BeTrue
    }

    It 'GD02 - GET /API/DiscoveredAccounts/{id} with -PageSize 0' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data $script:Sample }
        Invoke-AccountsGetDiscovered -Token $script:Token -InputData @{ DiscoveredAccountID = 'd-1' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Endpoint -eq '/API/DiscoveredAccounts/d-1' -and $PageSize -eq 0 }
    }

    It 'GD03 - result has the extended columns, including the dependency list' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data $script:Sample }
        $row = (Invoke-AccountsGetDiscovered -Token $script:Token -InputData @{ DiscoveredAccountID = 'd-1' }).Results[0]
        $row.UserDisplayName    | Should -Be 'Local Admin'
        $row.OrganizationalUnit | Should -Be 'OU=Servers'
        $row.Dependencies       | Should -Be 2
        $row.DependencyList     | Should -Be 'Windows Service Spooler srv01.example.com; Windows Scheduled Task Backup srv01.example.com'
    }

    It 'GD04 - missing ID: Failures=1 and no API call' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data $script:Sample }
        (Invoke-AccountsGetDiscovered -Token $script:Token -InputData @{}).Failures | Should -Be 1
        Should -Invoke Invoke-CyberArkAPI -Times 0 -Exactly
    }

    It 'GD05 - 400 PASWS168E (bad ID, seen live) keeps the API message, not fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 400 -Message 'PASWS168E: Input parameter for [id] value is invalid.' }
        $r = Invoke-AccountsGetDiscovered -Token $script:Token -InputData @{ DiscoveredAccountID = 'bad' }
        $r.IsFatal                | Should -BeFalse
        $r.Errors[0].ErrorMessage | Should -Match 'PASWS168E'
    }

    It 'GD06 - success with no data fails cleanly instead of throwing' {
        Mock Invoke-CyberArkAPI { script:New-OkResponse -Data $null }
        $r = Invoke-AccountsGetDiscovered -Token $script:Token -InputData @{ DiscoveredAccountID = 'd-1' }
        $r.Failures | Should -Be 1
    }

    It 'GD07 - 401 is fatal' {
        Mock Invoke-CyberArkAPI { script:New-ErrResponse -StatusCode 401 -Message 'Unauthorized' }
        (Invoke-AccountsGetDiscovered -Token $script:Token -InputData @{ DiscoveredAccountID = 'd-1' }).IsFatal | Should -BeTrue
    }
}
