#Requires -Version 5.1
<#
.SYNOPSIS
    Resolves a credential from any source aPeSecrets supports and stores it as this profile's
    stored automation credential (.autocred), for Manage-Privilege.ps1's automation mode to use as
    a silent-refresh fallback (see Use-StoredCredentialIfMissing, Testing_Findings-and-Known-Issues.md K06).

.DESCRIPTION
    A thin wrapper around the sibling aPeSecrets project (..\aPeSecrets by default -
    Modules\CredentialResolver.psm1, Get-ResolvedCredential) and this project's own
    Modules\CyberArkCredentialStore.psm1 (Save-ProfileCredential). It does not change
    Manage-Privilege.ps1's automation-mode contract at all - it only seeds/refreshes the same
    .autocred file that mode already reads, from whichever source you configure, instead of
    requiring a one-time interactive [A] menu action on every machine.

    See aPeSecrets\README.md and aPeSecrets\Claude_Docs\Reference_Configuration.md for the full list of supported
    -Source values and their -Params. See Claude_Docs\Design_Automation-Credential-Sources.md in this
    project for the design this script implements.

.PARAMETER ProfileName
    The driver profile's AuthTokenProfile name (the same name Manage-Privilege.ps1's profile-detail
    [A] menu action would store a credential under). Required.

.PARAMETER Source
    One of aPeSecrets's supported sources: CurrentUser, PSCredential, WindowsCredentialManager, CP,
    CCP, Conjur. Required.

.PARAMETER Params
    Hashtable of source-specific parameters, passed straight through to aPeSecrets's
    Get-ResolvedCredential -Params. See aPeSecrets\Claude_Docs\Reference_Configuration.md for what each source needs.

.PARAMETER ProfileDir
    Where Manage-Privilege.ps1 stores its profiles. Defaults to the same location the driver itself
    defaults to ($env:APPDATA\IdiraUnifiedScripts\Profiles) - override only if you also override it
    when launching Manage-Privilege.ps1.

.PARAMETER APeSecretsPath
    Path to aPeSecrets's Modules\CredentialResolver.psm1. Defaults to the sibling project layout
    (..\aPeSecrets\Modules\CredentialResolver.psm1, relative to this script).

.EXAMPLE
    # Seed a profile's automation credential from CyberArk CCP
    .\Sync-AutomationCredential.ps1 -ProfileName 'Prod-SelfHosted' -Source CCP -Params @{
        BaseUrl = 'https://ccp.contoso.com'; AppID = 'aPePAS-Prod'; Safe = 'AutomationSafe'; Object = 'svc-apepas'
    }

.EXAMPLE
    # Seed from a credential already sitting in Windows Credential Manager
    .\Sync-AutomationCredential.ps1 -ProfileName 'Prod-SelfHosted' -Source WindowsCredentialManager -Params @{ Target = 'svc-apepas' }

.NOTES
    Exit codes: 0 = credential resolved and stored; 1 = failed (see the printed error).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ProfileName,
    [Parameter(Mandatory = $true)]
    [ValidateSet('CurrentUser', 'PSCredential', 'WindowsCredentialManager', 'CP', 'CCP', 'Conjur')]
    [string] $Source,
    [hashtable] $Params = @{},
    [string] $ProfileDir = (Join-Path $env:APPDATA 'IdiraUnifiedScripts\Profiles'),
    [string] $APeSecretsPath = (Join-Path $PSScriptRoot '..\aPeSecrets\Modules\CredentialResolver.psm1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    if (-not (Test-Path -LiteralPath $APeSecretsPath)) {
        throw "aPeSecrets not found at '$APeSecretsPath'. Deploy aPeSecrets as a sibling project (..\aPeSecrets next to this script), or pass -APeSecretsPath explicitly."
    }
    Import-Module $APeSecretsPath -Force -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'Modules\CyberArkCredentialStore.psm1') -Force -ErrorAction Stop

    if ($Source -eq 'CurrentUser') {
        throw "Source 'CurrentUser' resolves to no credential (`$null) - there is nothing to store. Use an interactive login (Manage-Privilege.ps1's profile [A] menu action) or a different -Source."
    }

    Write-Host "Resolving credential for profile '$ProfileName' from source '$Source' via aPeSecrets..."
    $credential = Get-ResolvedCredential -Source $Source -Params $Params

    if (-not $credential) {
        throw "Get-ResolvedCredential returned no credential for source '$Source'. See any warnings above, or aPeSecrets\Claude_Docs\Reference_Configuration.md for this source's required Params."
    }

    if (-not (Test-Path -LiteralPath $ProfileDir)) {
        New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
    }

    $savedPath = Save-ProfileCredential -Name $ProfileName -Credential $credential -ProfileDir $ProfileDir
    Write-Host "Stored automation credential for profile '$ProfileName' (user '$($credential.UserName)') at '$savedPath'." -ForegroundColor Green
    exit 0
} catch {
    Write-Host "Failed to sync automation credential for profile '$ProfileName': $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
