#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Invoke-ApplicationsListAuthMethods.
#>

BeforeAll {
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Applications\Invoke-ApplicationsListAuthMethods.ps1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop
    . $script:ModulePath
    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'ApplicationsListAuthMethodsTests' -MinLevel 'ERROR'

    function script:New-AppsListResponse {
        param([string[]]$AppIDs = @())
        $apps = @($AppIDs | ForEach-Object { [PSCustomObject]@{ AppID = $_ } })
        return [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ application = $apps } }
    }

    function script:New-AuthMethodsResponse {
        param([string]$AuthID = '1', [string]$AuthType = 'path', [string]$AuthValue = 'C:\Apps\MyApp')
        $authsData = [PSCustomObject]@{
            authentication = @(
                [PSCustomObject]@{
                    authID = $AuthID; authType = $AuthType; authValue = $AuthValue
                    isFolder = $false; allowInternalScripts = $false; comment = 'Test entry'
                }
            )
        }
        return [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $authsData }
    }

    function script:New-ApiErrorResponse {
        param([int]$StatusCode = 403, [string]$ErrorMessage = 'Forbidden')
        return [PSCustomObject]@{
            IsSuccess = $false; StatusCode = $StatusCode; ErrorMessage = $ErrorMessage
            ErrorDetails = [PSCustomObject]@{ ErrorCode = "ERR$StatusCode"; ErrorMessage = $ErrorMessage; Details = $null }
            Data = $null
        }
    }
}

Describe 'ModuleMeta' {
    It 'AM01 - AppID is optional in InputSchema' {
        (($ModuleMeta.InputSchema | Where-Object { $_.Column -eq 'AppID' }).Required) | Should -BeFalse
    }

    It 'AM01a - SupportedSystems includes both SelfHosted and ISPSS' {
        $ModuleMeta.SupportedSystems | Should -Contain 'SelfHosted'
        $ModuleMeta.SupportedSystems | Should -Contain 'ISPSS'
        $ModuleMeta.SupportedSystems.Count | Should -Be 2
    }
}

Describe 'Invoke-ApplicationsListAuthMethods - single AppID (unchanged behavior)' {

    It 'AM02 - API call failure records error' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 404 -ErrorMessage 'Not Found' }
        $result = Invoke-ApplicationsListAuthMethods -Token $token -InputData @{ AppID = 'MyApp' }
        $result.Failures  | Should -BeGreaterThan 0
        $result.Successes | Should -Be 0
    }

    It 'AM03 - no authentication methods returns empty result with no errors' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = [PSCustomObject]@{ authentication = @() } }
        }
        $result = Invoke-ApplicationsListAuthMethods -Token $token -InputData @{ AppID = 'MyApp' }
        $result.Successes     | Should -Be 0
        $result.Results.Count | Should -Be 0
        $result.Failures      | Should -Be 0
    }

    It 'AM04 - maps authentication method fields correctly' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
        Mock Invoke-CyberArkAPI { script:New-AuthMethodsResponse }
        $result = Invoke-ApplicationsListAuthMethods -Token $token -InputData @{ AppID = 'MyApp' }
        $result.Successes            | Should -Be 1
        $result.Results[0].AppID     | Should -Be 'MyApp'
        $result.Results[0].AuthType  | Should -Be 'path'
        $result.Results[0].AuthValue | Should -Be 'C:\Apps\MyApp'
    }

    It 'AM05 - does not call the application-list endpoint when AppID is supplied' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
        Mock Invoke-CyberArkAPI {
            param($Method, $Endpoint)
            if ($Endpoint -eq '/WebServices/PIMServices.svc/Applications/') { throw 'Should not list all applications when AppID is supplied' }
            script:New-AuthMethodsResponse
        }
        Invoke-ApplicationsListAuthMethods -Token $token -InputData @{ AppID = 'MyApp' } | Out-Null
        Should -Invoke Invoke-CyberArkAPI -Times 1
    }
}

Describe 'Invoke-ApplicationsListAuthMethods - blank AppID lists every application' {

    It 'AM06 - blank AppID retrieves the application list, then auth methods for each one' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
        Mock Invoke-CyberArkAPI {
            param($Method, $Endpoint)
            if ($Endpoint -eq '/WebServices/PIMServices.svc/Applications/') {
                script:New-AppsListResponse -AppIDs @('App1', 'App2')
            } else {
                script:New-AuthMethodsResponse
            }
        }
        $result = Invoke-ApplicationsListAuthMethods -Token $token -InputData @{}
        $result.Successes | Should -Be 2
        @($result.Results | Where-Object { $_.AppID -eq 'App1' }).Count | Should -Be 1
        @($result.Results | Where-Object { $_.AppID -eq 'App2' }).Count | Should -Be 1
    }

    It 'AM07 - omitting InputData entirely (interactive AppID='''') also lists every application' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
        Mock Invoke-CyberArkAPI {
            param($Method, $Endpoint)
            if ($Endpoint -eq '/WebServices/PIMServices.svc/Applications/') {
                script:New-AppsListResponse -AppIDs @('App1')
            } else {
                script:New-AuthMethodsResponse
            }
        }
        $result = Invoke-ApplicationsListAuthMethods -Token $token -InputData @{ AppID = '' }
        $result.Successes | Should -Be 1
    }

    It 'AM08 - application-list call failure fails the whole run' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
        Mock Invoke-CyberArkAPI { script:New-ApiErrorResponse -StatusCode 500 -ErrorMessage 'Server Error' }
        $result = Invoke-ApplicationsListAuthMethods -Token $token -InputData @{}
        $result.Failures | Should -Be 1
    }

    It 'AM09 - zero applications returned - empty result, not a failure' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
        Mock Invoke-CyberArkAPI { script:New-AppsListResponse -AppIDs @() }
        $result = Invoke-ApplicationsListAuthMethods -Token $token -InputData @{}
        $result.Successes | Should -Be 0
        $result.Failures  | Should -Be 0
    }

    It 'AM10 - a 401 on one application''s auth-methods call is fatal and stops immediately' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
        Mock Invoke-CyberArkAPI {
            param($Method, $Endpoint)
            if ($Endpoint -eq '/WebServices/PIMServices.svc/Applications/') {
                script:New-AppsListResponse -AppIDs @('App1', 'App2')
            } else {
                script:New-ApiErrorResponse -StatusCode 401 -ErrorMessage 'Unauthorized'
            }
        }
        $result = Invoke-ApplicationsListAuthMethods -Token $token -InputData @{}
        $result.IsFatal | Should -BeTrue
        # Only App1's auth-methods call should have run before stopping - App2 never reached.
        Should -Invoke Invoke-CyberArkAPI -Times 2
    }

    It 'AM11 - a non-fatal error (403) on one application continues to the next' {
        $token = [PSCustomObject]@{ Token = 'tok'; Expiry = [DateTime]::UtcNow.AddHours(1) }
        Mock Invoke-CyberArkAPI {
            param($Method, $Endpoint)
            if ($Endpoint -eq '/WebServices/PIMServices.svc/Applications/') {
                script:New-AppsListResponse -AppIDs @('App1', 'App2')
            } elseif ($Endpoint -like '*/App1/*') {
                script:New-ApiErrorResponse -StatusCode 403 -ErrorMessage 'Forbidden'
            } else {
                script:New-AuthMethodsResponse
            }
        }
        $result = Invoke-ApplicationsListAuthMethods -Token $token -InputData @{}
        $result.IsFatal   | Should -BeFalse
        $result.Failures  | Should -Be 1
        $result.Successes | Should -Be 1
        $result.Results[0].AppID | Should -Be 'App2'
    }
}
