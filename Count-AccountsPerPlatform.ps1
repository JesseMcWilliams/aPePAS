#Requires -Version 5.1
<#
.SYNOPSIS
    Counts how many accounts are assigned to each CyberArk platform, from already-exported CSVs.

.DESCRIPTION
    Standalone utility - does not connect to CyberArk and does not depend on Manage-Privilege.ps1
    or any APIModules file. It reads two CSV files already produced by this project's Platforms/
    List and Accounts/List modules (e.g. via the "Export All" action, which names them
    Export_PlatformsList.csv and Export_AccountsList.csv), joins them on PlatformID, and writes a
    new CSV listing every platform alongside a count of accounts assigned to it.

    Platforms with zero matching accounts are still included (Count = 0). Accounts whose
    PlatformID does not match any row in the platforms CSV are counted separately under a
    "(Not Found)" placeholder row rather than silently dropped, since that gap usually means a
    platform was deleted or renamed after accounts were already assigned to it. Accounts with a
    blank PlatformID are counted under a "(No Platform Assigned)" placeholder row.

.PARAMETER PlatformsCsvPath
    Path to the exported platforms CSV (must have PlatformID and Name columns - the shape
    produced by Invoke-PlatformsList.ps1). If omitted, an Open File dialog is shown.

.PARAMETER AccountsCsvPath
    Path to the exported accounts CSV (must have a PlatformID column - the shape produced by
    Invoke-AccountsList.ps1). If omitted, an Open File dialog is shown.

.PARAMETER OutputCsvPath
    Path to write the resulting CSV. If omitted, a Save File dialog is shown, pre-filled with
    Count-AccountsPerPlatform_<yyyy-MM-dd>.csv in the same folder as PlatformsCsvPath.

.EXAMPLE
    .\Count-AccountsPerPlatform.ps1
    No paths supplied - prompts with an Open File dialog for each input CSV and a Save File
    dialog for the output.

.EXAMPLE
    .\Count-AccountsPerPlatform.ps1 -PlatformsCsvPath 'Output\Export_PlatformsList.csv' -AccountsCsvPath 'Output\Export_AccountsList.csv' -OutputCsvPath 'Output\PlatformUsage.csv'
    All three paths supplied explicitly - no dialogs shown.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$PlatformsCsvPath,

    [Parameter(Mandatory = $false)]
    [string]$AccountsCsvPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputCsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NotFoundLabel    = '(Not Found)'
$NoPlatformLabel  = '(No Platform Assigned)'

# Single-file Open dialog. Falls back to a Read-Host prompt if System.Windows.Forms is
# unavailable (e.g. a headless/non-desktop session) - matches the fallback pattern already used
# by Get-CsvSavePath in Manage-Privilege.ps1. Returns $null on cancel.
function Select-CsvOpenDialog {
    param(
        [Parameter(Mandatory = $true)] [string]$Title,
        [Parameter(Mandatory = $false)][string]$InitialDirectory
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog                  = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title            = $Title
        $dialog.Filter           = 'CSV Files (*.csv)|*.csv|All Files (*.*)|*.*'
        $dialog.Multiselect      = $false
        $dialog.InitialDirectory = if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory -PathType Container)) {
            $InitialDirectory
        } else { (Get-Location).Path }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.FileName
        }
        return $null
    } catch {
        $path = Read-Host "$Title (full path, blank to cancel)"
        if ($path) { return $path } else { return $null }
    }
}

# Save dialog pre-filled with a suggested name/folder. Same WinForms-unavailable fallback as
# Select-CsvOpenDialog above, except blank at the Read-Host prompt accepts the suggested default
# (matching Get-CsvSavePath's Show-FieldPrompt behavior) rather than cancelling - X cancels.
# Returns $null on cancel.
function Select-CsvSaveDialog {
    param(
        [Parameter(Mandatory = $true)] [string]$Title,
        [Parameter(Mandatory = $true)] [string]$DefaultFileName,
        [Parameter(Mandatory = $false)][string]$InitialDirectory
    )
    $initialDir = if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory -PathType Container)) {
        $InitialDirectory
    } else { (Get-Location).Path }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog                  = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Title            = $Title
        $dialog.Filter           = 'CSV Files (*.csv)|*.csv|All Files (*.*)|*.*'
        $dialog.DefaultExt       = 'csv'
        $dialog.FileName         = $DefaultFileName
        $dialog.InitialDirectory = $initialDir
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.FileName
        }
        return $null
    } catch {
        $defaultPath = Join-Path $initialDir $DefaultFileName
        $entered = Read-Host "$Title`nPress Enter to accept [$defaultPath], type a different path, or X to cancel"
        if ($entered -match '^[Xx]$') { return $null }
        if ($entered) { return $entered } else { return $defaultPath }
    }
}

if (-not $PlatformsCsvPath) {
    $PlatformsCsvPath = Select-CsvOpenDialog -Title 'Select Platforms CSV'
    if (-not $PlatformsCsvPath) {
        Write-Host 'Cancelled - no platforms CSV selected.' -ForegroundColor Yellow
        exit 0
    }
}
if (-not $AccountsCsvPath) {
    $accountsInitialDir = if (Test-Path -LiteralPath $PlatformsCsvPath -PathType Leaf) {
        Split-Path -Path (Resolve-Path -LiteralPath $PlatformsCsvPath).Path -Parent
    } else { $null }
    $AccountsCsvPath = Select-CsvOpenDialog -Title 'Select Accounts CSV' -InitialDirectory $accountsInitialDir
    if (-not $AccountsCsvPath) {
        Write-Host 'Cancelled - no accounts CSV selected.' -ForegroundColor Yellow
        exit 0
    }
}

if (-not (Test-Path -LiteralPath $PlatformsCsvPath -PathType Leaf)) {
    Write-Error "Platforms CSV not found: $PlatformsCsvPath"
    exit 1
}
if (-not (Test-Path -LiteralPath $AccountsCsvPath -PathType Leaf)) {
    Write-Error "Accounts CSV not found: $AccountsCsvPath"
    exit 1
}

$platformsFullPath  = (Resolve-Path -LiteralPath $PlatformsCsvPath).Path
$defaultOutputFolder = Split-Path -Path $platformsFullPath -Parent
$defaultOutputName   = "Count-AccountsPerPlatform_$((Get-Date).ToString('yyyy-MM-dd')).csv"

if (-not $OutputCsvPath) {
    $OutputCsvPath = Select-CsvSaveDialog -Title 'Save Platform Account Counts As' `
        -DefaultFileName $defaultOutputName -InitialDirectory $defaultOutputFolder
    if (-not $OutputCsvPath) {
        Write-Host 'Cancelled - no output path selected.' -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "Platforms CSV : $PlatformsCsvPath" -ForegroundColor DarkGray
Write-Host "Accounts CSV  : $AccountsCsvPath" -ForegroundColor DarkGray
Write-Host "Output CSV    : $OutputCsvPath" -ForegroundColor DarkGray
Write-Host ''

try {
    [array]$platforms = @(Import-Csv -LiteralPath $PlatformsCsvPath)
} catch {
    Write-Error "Failed to read platforms CSV '$PlatformsCsvPath': $_"
    exit 1
}
try {
    [array]$accounts = @(Import-Csv -LiteralPath $AccountsCsvPath)
} catch {
    Write-Error "Failed to read accounts CSV '$AccountsCsvPath': $_"
    exit 1
}

if ($platforms.Count -eq 0) {
    Write-Warning "'$PlatformsCsvPath' contains no platform rows."
}
if ($platforms.Count -gt 0 -and -not $platforms[0].PSObject.Properties['PlatformID']) {
    Write-Error "'$PlatformsCsvPath' has no PlatformID column - is this the correct file?"
    exit 1
}
if ($accounts.Count -gt 0 -and -not $accounts[0].PSObject.Properties['PlatformID']) {
    Write-Error "'$AccountsCsvPath' has no PlatformID column - is this the correct file?"
    exit 1
}

# Count accounts per PlatformID. PowerShell hashtables are case-insensitive for string keys by
# default, matching how CyberArk platform IDs are compared elsewhere in this project.
$countsByPlatform = @{}
foreach ($account in $accounts) {
    $platformId = if ($account.PSObject.Properties['PlatformID']) { "$($account.PlatformID)".Trim() } else { '' }
    $key = if ($platformId) { $platformId } else { $NoPlatformLabel }
    if ($countsByPlatform.ContainsKey($key)) {
        $countsByPlatform[$key]++
    } else {
        $countsByPlatform[$key] = 1
    }
}

$rows = [System.Collections.Generic.List[PSCustomObject]]::new()
$matchedKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

foreach ($platform in $platforms) {
    $platformId = if ($platform.PSObject.Properties['PlatformID']) { "$($platform.PlatformID)".Trim() } else { '' }
    $name       = if ($platform.PSObject.Properties['Name'])       { $platform.Name }                  else { '' }
    $count      = if ($platformId -and $countsByPlatform.ContainsKey($platformId)) { $countsByPlatform[$platformId] } else { 0 }
    if ($platformId) { [void]$matchedKeys.Add($platformId) }

    $rows.Add([PSCustomObject]@{
        PlatformID   = $platformId
        PlatformName = $name
        AccountCount = $count
    })
}

# Any PlatformID seen in the accounts CSV that never matched a platform row (deleted/renamed
# platform, or the "no platform assigned" bucket) - surfaced rather than silently dropped, so
# the sum of AccountCount across every row always equals the total account count.
foreach ($key in $countsByPlatform.Keys) {
    if ($key -eq $NoPlatformLabel -or -not $matchedKeys.Contains($key)) {
        $rows.Add([PSCustomObject]@{
            PlatformID   = if ($key -eq $NoPlatformLabel) { '' } else { $key }
            PlatformName = if ($key -eq $NoPlatformLabel) { $NoPlatformLabel } else { $NotFoundLabel }
            AccountCount = $countsByPlatform[$key]
        })
    }
}

$sortedRows = $rows | Sort-Object -Property @{ Expression = 'AccountCount'; Descending = $true }, @{ Expression = 'PlatformName'; Descending = $false }

try {
    $sortedRows | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Encoding UTF8 -Force
} catch {
    Write-Error "Failed to write output CSV '$OutputCsvPath': $_"
    exit 1
}

$totalAccounts  = ($sortedRows | Measure-Object -Property AccountCount -Sum).Sum
$platformsUsed  = @($sortedRows | Where-Object {
    $_.AccountCount -gt 0 -and $_.PlatformName -ne $NotFoundLabel -and $_.PlatformName -ne $NoPlatformLabel
}).Count

Write-Host "Platforms listed : $($sortedRows.Count)" -ForegroundColor Green
Write-Host "Platforms in use : $platformsUsed" -ForegroundColor Green
Write-Host "Accounts totaled : $totalAccounts" -ForegroundColor Green
Write-Host "Saved: $OutputCsvPath" -ForegroundColor Green
