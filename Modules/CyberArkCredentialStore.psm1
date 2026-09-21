#Requires -Version 5.1
<#
.SYNOPSIS
    Local, DPAPI-encrypted credential store for aPePAS automation mode.

.DESCRIPTION
    Extracted from Manage-Privilege.ps1 (Testing-Plan.md K06/F56) so a standalone helper script -
    not just the interactive driver - can read and write the same per-profile stored credential
    used as an automation-mode fallback when a saved session's own _RefreshContext has no usable
    credential to silently refresh with (see Manage-Privilege.ps1's Use-StoredCredentialIfMissing
    and the profile detail menu's [A] action).

    A credential is stored as a PSCredential, serialized via Export-Clixml - the same mechanism
    Auth\CyberArk.Auth.Common.psm1 already uses for the .cred session token file. This is DPAPI
    under the hood: the file can only be decrypted by the same Windows user account on the same
    machine that created it. There is no cross-machine or cross-user portability, by design - see
    Docs\Architecture.md's Security Considerations.

    Every function takes an explicit -ProfileDir rather than reading driver-scope state (e.g.
    $script:ProfileDir), so this module has no hidden dependency on Manage-Privilege.ps1's own
    scope or startup sequence and works identically whether called from the driver or a separate
    script.
#>

Set-StrictMode -Version Latest

function Get-ProfileCredentialPath {
    <#
    .SYNOPSIS
        Path of the .autocred file for a given profile name.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [string]$ProfileDir
    )
    Join-Path $ProfileDir "$Name.autocred"
}

function Save-ProfileCredential {
    <#
    .SYNOPSIS
        Stores $Credential for $Name, DPAPI-encrypted via Export-Clixml.
    .OUTPUTS
        [string] Path of the saved file.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory = $true)] [string]$ProfileDir
    )
    $path = Get-ProfileCredentialPath -Name $Name -ProfileDir $ProfileDir
    $Credential | Export-Clixml -Path $path -Force
    return $path
}

function Get-ProfileCredential {
    <#
    .SYNOPSIS
        Returns the stored PSCredential for $Name, or $null if none is stored or it can't be
        decrypted here (DPAPI is user+machine-locked - a credential stored on a different Windows
        user/machine simply isn't usable, not an error to surface).
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [string]$ProfileDir
    )
    $path = Get-ProfileCredentialPath -Name $Name -ProfileDir $ProfileDir
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return Import-Clixml -Path $path
    } catch {
        # Write-CyberArkLog is only available when this module is loaded alongside
        # CyberArkLogging.psm1 (e.g. from Manage-Privilege.ps1) - a standalone helper script may
        # not have it, so this is guarded rather than a hard dependency.
        if (Get-Command -Name 'Write-CyberArkLog' -ErrorAction SilentlyContinue) {
            Write-CyberArkLog -Level 'WARN' -Message "Stored automation credential for '$Name' could not be read (different Windows user/machine, or corrupt): $_"
        }
        return $null
    }
}

function Remove-ProfileCredential {
    <#
    .SYNOPSIS
        Deletes the stored credential for $Name, if any. No-op (not an error) if none is stored.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [string]$ProfileDir
    )
    $path = Get-ProfileCredentialPath -Name $Name -ProfileDir $ProfileDir
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

Export-ModuleMember -Function @(
    'Get-ProfileCredentialPath'
    'Save-ProfileCredential'
    'Get-ProfileCredential'
    'Remove-ProfileCredential'
)
