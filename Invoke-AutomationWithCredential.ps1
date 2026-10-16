#Requires -Version 5.1
<#
.SYNOPSIS
    Retrieves a profile's credential through aPeSecrets (CyberArk CP/CCP/Conjur, a DPAPI credential
    file, or Windows Credential Manager), then runs one Manage-Privilege.ps1 automation action with it.

.DESCRIPTION
    For scheduled, unattended runs. The credential source for each profile comes from a JSON config
    file (see -ConfigPath). The credential is resolved with aPeSecrets's Get-ResolvedCredential and
    handed to Manage-Privilege.ps1's -Credential parameter in memory, in this same PowerShell process:
    it is never written to disk, and Manage-Privilege.ps1 leaves its secret out of the saved session
    file. With it, automation mode can log in fresh when the profile has no usable saved session.

    Supported auth methods (the profile's own setting): Self-Hosted CyberArk, LDAP and RADIUS;
    Privilege Cloud ClientCredentials (username = client ID, password = client secret) and Interactive
    (password-only, no MFA). Other methods exit 3.

    Config file format (no secrets - only where to find them):

        {
          "Profiles": {
            "Prod-SelfHosted": {
              "Source": "CCP",
              "Params": { "BaseUrl": "https://ccp.example.com", "AppID": "aPePAS-Prod",
                          "Safe": "AutomationSafe", "Object": "svc-apepas" }
            },
            "Lab-Local": {
              "Source": "PSCredential",
              "Params": { "CredentialFilePath": "C:\\Secure\\svc-apepas.xml" }
            }
          }
        }

    Source is one of PSCredential (a DPAPI Export-Clixml file), WindowsCredentialManager, CP, CCP,
    Conjur. Params are passed to aPeSecrets unchanged; see aPeSecrets\Claude_Docs\Reference_Configuration.md.
    CredentialSources.example.json in this folder is a starting point.

    Audit reason: add "Reason" to a profile's Params and CP and CCP record it with the retrieval, so
    it shows in the PVWA audit trail (Activities). The text may use these tokens: {Profile},
    {Category}, {Action}, {JobFile} (the file name), {JobDescription} (the job file's optional
    top-level "Description" text), {Host} and {Date} (yyyy-MM-dd). Unknown tokens stay as written.
    Example: "Reason": "aPePAS {Profile} {JobFile}: {JobDescription}". Conjur has no reason field
    and warns. Needs an aPeSecrets with Reason support (CP ignores it in older copies).

.PARAMETER ProfileName
    The Manage-Privilege.ps1 profile to run (its -StartProfile). Also the key in the config file.

.PARAMETER Category
.PARAMETER Action
    The automation action to run, as for Manage-Privilege.ps1. Required unless -JobFile or -ResolveOnly.

.PARAMETER JobFile
    A Manage-Privilege.ps1 job file: several steps run under one login with this credential
    (instead of -Category/-Action). See JobFile.example.json.

.PARAMETER InputFile
.PARAMETER InputJson
.PARAMETER OutputFolder
.PARAMETER FilenameFormat
.PARAMETER WhatIf
.PARAMETER LogLevel
.PARAMETER LogFolder
    Passed through to Manage-Privilege.ps1 unchanged when given.

.PARAMETER ConfigPath
    The credential-source config file. Default: CredentialSources.json in Manage-Privilege.ps1's
    profile folder (%APPDATA%\IdiraUnifiedScripts\Profiles).

.PARAMETER APeSecretsPath
    aPeSecrets's Modules\CredentialResolver.psm1. Default: the sibling project
    (..\aPeSecrets\Modules\CredentialResolver.psm1, relative to this script).

.PARAMETER ManagePrivilegePath
    Default: Manage-Privilege.ps1 next to this script.

.PARAMETER ResolveOnly
    Resolve the credential, print its username, and exit (0 = resolved, 3 = not) without running
    anything. Use it to check a new config entry.

.EXAMPLE
    .\Invoke-AutomationWithCredential.ps1 -ProfileName 'Prod-SelfHosted' -Category Safes -Action List -OutputFolder 'D:\Reports'

.EXAMPLE
    .\Invoke-AutomationWithCredential.ps1 -ProfileName 'Prod-SelfHosted' -JobFile 'D:\Jobs\nightly.json'

.EXAMPLE
    .\Invoke-AutomationWithCredential.ps1 -ProfileName 'Prod-SelfHosted' -ResolveOnly

.NOTES
    Exit codes: Manage-Privilege.ps1's own (0 success, 1 crash, 2 partial failure, 3 could not run),
    or 3 when this script can't read the config or resolve the credential. Never prints the secret.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$ProfileName,
    [string]$Category,
    [string]$Action,
    [string]$JobFile,
    [string]$InputFile,
    [string]$InputJson,
    [string]$OutputFolder,
    [string]$FilenameFormat,
    [switch]$WhatIf,
    [ValidateSet('VERBOSE', 'DEBUG', 'INFO', 'WARN', 'ERROR')]
    [string]$LogLevel,
    [string]$LogFolder,
    # Path defaults are filled in below, not here: Windows PowerShell 5.1 leaves $PSScriptRoot
    # empty inside param() defaults when a script runs with -File.
    [string]$ConfigPath,
    [string]$APeSecretsPath,
    [string]$ManagePrivilegePath,
    [switch]$ResolveOnly
)

Set-StrictMode -Version Latest

$script:SupportedSources = @('PSCredential', 'WindowsCredentialManager', 'CP', 'CCP', 'Conjur')

function ConvertTo-ParamHashtable {
    <# Turns the config's Params object (PSCustomObject from ConvertFrom-Json) into a hashtable. #>
    param([AllowNull()] [object]$InputObject)
    $table = @{}
    if ($null -eq $InputObject) { return $table }
    foreach ($prop in $InputObject.PSObject.Properties) { $table[$prop.Name] = $prop.Value }
    return $table
}

function Get-CredentialSourceEntry {
    <#
        Reads the config file and returns @{ Source; Params } for one profile (name match is
        case-insensitive). Throws with a clear message for any problem.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Name
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Credential source config not found: '$Path'. Create it (see CredentialSources.example.json) or pass -ConfigPath."
    }
    try {
        $config = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Credential source config '$Path' is not valid JSON: $($_.Exception.Message)"
    }
    if (-not $config -or -not $config.PSObject.Properties['Profiles'] -or -not $config.Profiles) {
        throw "Credential source config '$Path' has no 'Profiles' object."
    }
    $entryProp = @($config.Profiles.PSObject.Properties | Where-Object { $_.Name -ieq $Name }) | Select-Object -First 1
    if (-not $entryProp) {
        throw "Credential source config '$Path' has no entry for profile '$Name'."
    }
    $entry  = $entryProp.Value
    $source = if ($entry -and $entry.PSObject.Properties['Source']) { "$($entry.Source)".Trim() } else { '' }
    if (-not $source) { throw "Profile '$Name' in '$Path' has no 'Source'." }
    $match = @($script:SupportedSources | Where-Object { $_ -ieq $source }) | Select-Object -First 1
    if (-not $match) {
        throw "Profile '$Name' in '$Path' has Source '$source'. Use one of: $($script:SupportedSources -join ', ')."
    }
    $params = ConvertTo-ParamHashtable -InputObject $(if ($entry.PSObject.Properties['Params']) { $entry.Params } else { $null })
    $secretKeys = @($params.Keys | Where-Object { $_ -match '^(?i)(password|secret|clientsecret|apikey|token)$' })
    if ($secretKeys.Count -gt 0) {
        throw "Profile '$Name' in '$Path' has a secret in Params ($($secretKeys -join ', ')). The config only says where the credential is; keep the secret in the source itself."
    }
    return @{ Source = $match; Params = $params }
}

function Expand-ReasonTemplate {
    <# Fills the {Token} placeholders in a Params.Reason string for this run. Unknown tokens stay as written. #>
    param(
        [AllowNull()] [string]$Template,
        [Parameter(Mandatory = $true)] [hashtable]$Bound
    )
    if ([string]::IsNullOrWhiteSpace($Template)) { return $Template }
    $jobFile = if ($Bound['JobFile']) { "$($Bound['JobFile'])" } else { '' }
    $jobDescription = ''
    if ($jobFile -and (Test-Path -LiteralPath $jobFile -PathType Leaf)) {
        try {
            $job = Get-Content -LiteralPath $jobFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($job -and $job.PSObject.Properties['Description'] -and $job.Description) { $jobDescription = "$($job.Description)" }
        } catch { $jobDescription = '' }
    }
    $values = @{
        Profile        = "$($Bound['ProfileName'])"
        Category       = if ($Bound['Category']) { "$($Bound['Category'])" } else { '' }
        Action         = if ($Bound['Action'])   { "$($Bound['Action'])" }   else { '' }
        JobFile        = if ($jobFile) { Split-Path -Leaf $jobFile } else { '' }
        JobDescription = $jobDescription
        Host           = $env:COMPUTERNAME
        Date           = (Get-Date).ToString('yyyy-MM-dd')
    }
    return [regex]::Replace($Template, '\{(\w+)\}', {
        param($m)
        if ($values.ContainsKey($m.Groups[1].Value)) { $values[$m.Groups[1].Value] } else { $m.Value }
    }).Trim()
}

function Get-ManagePrivilegeArguments {
    <# Builds the splat for Manage-Privilege.ps1 from this script's own parameters. #>
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Bound,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCredential]$Credential
    )
    $mpArgs = @{
        StartProfile = $Bound['ProfileName']
        Credential   = $Credential
    }
    if ($Bound['JobFile']) {
        $mpArgs['JobFile'] = $Bound['JobFile']
    } else {
        $mpArgs['Category'] = $Bound['Category']
        $mpArgs['Action']   = $Bound['Action']
    }
    foreach ($name in @('InputFile', 'InputJson', 'OutputFolder', 'FilenameFormat', 'LogLevel', 'LogFolder')) {
        if ($Bound.ContainsKey($name) -and "$($Bound[$name])" -ne '') { $mpArgs[$name] = $Bound[$name] }
    }
    if ($Bound.ContainsKey('WhatIf') -and $Bound['WhatIf']) { $mpArgs['WhatIf'] = $true }
    # -Verbose means -LogLevel VERBOSE (the HTTP trace) in Manage-Privilege.ps1; an explicit -LogLevel wins.
    if ($Bound.ContainsKey('Verbose') -and $Bound['Verbose'] -and -not $mpArgs.ContainsKey('LogLevel')) { $mpArgs['LogLevel'] = 'VERBOSE' }
    return $mpArgs
}

function Invoke-AutomationWithCredentialMain {
    <# The whole run. Returns the exit code. #>
    param([Parameter(Mandatory = $true)] [hashtable]$Bound)

    if ($Bound['JobFile'] -and ($Bound['Category'] -or $Bound['Action'] -or $Bound['InputFile'] -or $Bound['InputJson'])) {
        Write-Host '-JobFile replaces -Category/-Action/-InputFile/-InputJson; put those in the job file''s steps.' -ForegroundColor Red
        return 3
    }
    if (-not $Bound['ResolveOnly'] -and -not $Bound['JobFile'] -and (-not $Bound['Category'] -or -not $Bound['Action'])) {
        Write-Host '-Category and -Action are required (or -JobFile, or -ResolveOnly to test the credential).' -ForegroundColor Red
        return 3
    }

    $credential = $null
    try {
        $entry = Get-CredentialSourceEntry -Path $Bound['ConfigPath'] -Name $Bound['ProfileName']
        if (-not (Test-Path -LiteralPath $Bound['APeSecretsPath'] -PathType Leaf)) {
            throw "aPeSecrets not found at '$($Bound['APeSecretsPath'])'. Deploy it as a sibling project (..\aPeSecrets) or pass -APeSecretsPath."
        }
        Import-Module $Bound['APeSecretsPath'] -Force -ErrorAction Stop
        Write-Host "Resolving the credential for profile '$($Bound['ProfileName'])' from $($entry.Source) via aPeSecrets..."
        if ($entry.Params.ContainsKey('Reason')) {
            $entry.Params['Reason'] = Expand-ReasonTemplate -Template "$($entry.Params['Reason'])" -Bound $Bound
        }
        $credential = Get-ResolvedCredential -Source $entry.Source -Params $entry.Params
        if (-not $credential -or $credential -isnot [System.Management.Automation.PSCredential]) {
            throw "$($entry.Source) returned no credential."
        }
    } catch {
        Write-Host "Could not get the credential: $($_.Exception.Message)" -ForegroundColor Red
        return 3
    }

    try {
        if ($Bound['ResolveOnly']) {
            Write-Host "Resolved a credential for '$($credential.UserName)'. (-ResolveOnly: nothing was run.)" -ForegroundColor Green
            return 0
        }
        if (-not (Test-Path -LiteralPath $Bound['ManagePrivilegePath'] -PathType Leaf)) {
            Write-Host "Manage-Privilege.ps1 not found at '$($Bound['ManagePrivilegePath'])'." -ForegroundColor Red
            return 3
        }
        $what = if ($Bound['JobFile']) { "job file '$($Bound['JobFile'])'" } else { "$($Bound['Category'])/$($Bound['Action'])" }
        Write-Host "Running $what for '$($Bound['ProfileName'])' as '$($credential.UserName)'..."
        $mpArgs = Get-ManagePrivilegeArguments -Bound $Bound -Credential $credential
        $global:LASTEXITCODE = 0
        # Out-Host: keep Manage-Privilege.ps1's console output out of this function's return value.
        & $Bound['ManagePrivilegePath'] @mpArgs | Out-Host
        return [int]$global:LASTEXITCODE
    } catch {
        Write-Host "Manage-Privilege.ps1 failed: $($_.Exception.Message)" -ForegroundColor Red
        return 1
    } finally {
        $credential = $null
    }
}

# Entry point. Skipped when dot-sourced (unit tests).
if ($MyInvocation.InvocationName -ne '.') {
    $bound = @{}
    foreach ($key in $PSBoundParameters.Keys) { $bound[$key] = $PSBoundParameters[$key] }
    $defaults = @{
        ConfigPath          = Join-Path $env:APPDATA 'IdiraUnifiedScripts\Profiles\CredentialSources.json'
        APeSecretsPath      = Join-Path $PSScriptRoot '..\aPeSecrets\Modules\CredentialResolver.psm1'
        ManagePrivilegePath = Join-Path $PSScriptRoot 'Manage-Privilege.ps1'
    }
    foreach ($name in $defaults.Keys) {
        if (-not $bound[$name]) { $bound[$name] = $defaults[$name] }
    }
    exit (Invoke-AutomationWithCredentialMain -Bound $bound)
}
