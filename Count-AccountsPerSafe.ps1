#Requires -Version 5.1
<#
.SYNOPSIS
    Counts how many accounts are assigned to each CyberArk safe, from already-exported CSVs.

.DESCRIPTION
    Standalone utility - does not connect to CyberArk and does not depend on Manage-Privilege.ps1
    or any APIModules file. It reads two CSV files already produced by this project's Safes/
    List and Accounts/List modules (e.g. via the "Export All" action, which names them
    Export_SafesList.csv and Export_AccountsList.csv), joins them on SafeName, and writes a new
    CSV listing every safe alongside a count of accounts assigned to it.

    Safes with zero matching accounts are still included (Count = 0). Accounts whose SafeName
    does not match any row in the safes CSV are counted separately under a "(Not Found)"
    placeholder row rather than silently dropped, since that gap usually means a safe was deleted
    or renamed after accounts were already assigned to it. Accounts with a blank SafeName are
    counted under a "(No Safe Assigned)" placeholder row.

.PARAMETER SafesCsvPath
    Path to the exported safes CSV (must have a SafeName column - the shape produced by
    Invoke-SafesList.ps1). If omitted, an Open File dialog is shown.

.PARAMETER AccountsCsvPath
    Path to the exported accounts CSV (must have a SafeName column - the shape produced by
    Invoke-AccountsList.ps1). If omitted, an Open File dialog is shown.

.PARAMETER OutputCsvPath
    Path to write the resulting CSV. If omitted, a Save File dialog is shown, pre-filled with
    Count-AccountsPerSafe_<yyyy-MM-dd>.csv in the same folder as SafesCsvPath.

.EXAMPLE
    .\Count-AccountsPerSafe.ps1
    No paths supplied - prompts with an Open File dialog for each input CSV and a Save File
    dialog for the output.

.EXAMPLE
    .\Count-AccountsPerSafe.ps1 -SafesCsvPath 'Output\Export_SafesList.csv' -AccountsCsvPath 'Output\Export_AccountsList.csv' -OutputCsvPath 'Output\SafeUsage.csv'
    All three paths supplied explicitly - no dialogs shown.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SafesCsvPath,

    [Parameter(Mandatory = $false)]
    [string]$AccountsCsvPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputCsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NotFoundLabel = '(Not Found)'
$NoSafeLabel   = '(No Safe Assigned)'

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

if (-not $SafesCsvPath) {
    $SafesCsvPath = Select-CsvOpenDialog -Title 'Select Safes CSV'
    if (-not $SafesCsvPath) {
        Write-Host 'Cancelled - no safes CSV selected.' -ForegroundColor Yellow
        exit 0
    }
}
if (-not $AccountsCsvPath) {
    $accountsInitialDir = if (Test-Path -LiteralPath $SafesCsvPath -PathType Leaf) {
        Split-Path -Path (Resolve-Path -LiteralPath $SafesCsvPath).Path -Parent
    } else { $null }
    $AccountsCsvPath = Select-CsvOpenDialog -Title 'Select Accounts CSV' -InitialDirectory $accountsInitialDir
    if (-not $AccountsCsvPath) {
        Write-Host 'Cancelled - no accounts CSV selected.' -ForegroundColor Yellow
        exit 0
    }
}

if (-not (Test-Path -LiteralPath $SafesCsvPath -PathType Leaf)) {
    Write-Error "Safes CSV not found: $SafesCsvPath"
    exit 1
}
if (-not (Test-Path -LiteralPath $AccountsCsvPath -PathType Leaf)) {
    Write-Error "Accounts CSV not found: $AccountsCsvPath"
    exit 1
}

$safesFullPath       = (Resolve-Path -LiteralPath $SafesCsvPath).Path
$defaultOutputFolder = Split-Path -Path $safesFullPath -Parent
$defaultOutputName   = "Count-AccountsPerSafe_$((Get-Date).ToString('yyyy-MM-dd')).csv"

if (-not $OutputCsvPath) {
    $OutputCsvPath = Select-CsvSaveDialog -Title 'Save Safe Account Counts As' `
        -DefaultFileName $defaultOutputName -InitialDirectory $defaultOutputFolder
    if (-not $OutputCsvPath) {
        Write-Host 'Cancelled - no output path selected.' -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "Safes CSV    : $SafesCsvPath" -ForegroundColor DarkGray
Write-Host "Accounts CSV : $AccountsCsvPath" -ForegroundColor DarkGray
Write-Host "Output CSV   : $OutputCsvPath" -ForegroundColor DarkGray
Write-Host ''

try {
    [array]$safes = @(Import-Csv -LiteralPath $SafesCsvPath)
} catch {
    Write-Error "Failed to read safes CSV '$SafesCsvPath': $_"
    exit 1
}
try {
    [array]$accounts = @(Import-Csv -LiteralPath $AccountsCsvPath)
} catch {
    Write-Error "Failed to read accounts CSV '$AccountsCsvPath': $_"
    exit 1
}

if ($safes.Count -eq 0) {
    Write-Warning "'$SafesCsvPath' contains no safe rows."
}
if ($safes.Count -gt 0 -and -not $safes[0].PSObject.Properties['SafeName']) {
    Write-Error "'$SafesCsvPath' has no SafeName column - is this the correct file?"
    exit 1
}
if ($accounts.Count -gt 0 -and -not $accounts[0].PSObject.Properties['SafeName']) {
    Write-Error "'$AccountsCsvPath' has no SafeName column - is this the correct file?"
    exit 1
}

# Count accounts per SafeName. PowerShell hashtables are case-insensitive for string keys by
# default, matching how CyberArk safe names are compared elsewhere in this project.
$countsBySafe = @{}
foreach ($account in $accounts) {
    $safeName = if ($account.PSObject.Properties['SafeName']) { "$($account.SafeName)".Trim() } else { '' }
    $key = if ($safeName) { $safeName } else { $NoSafeLabel }
    if ($countsBySafe.ContainsKey($key)) {
        $countsBySafe[$key]++
    } else {
        $countsBySafe[$key] = 1
    }
}

$rows = [System.Collections.Generic.List[PSCustomObject]]::new()
$matchedKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

foreach ($safe in $safes) {
    $safeName = if ($safe.PSObject.Properties['SafeName']) { "$($safe.SafeName)".Trim() } else { '' }
    $count    = if ($safeName -and $countsBySafe.ContainsKey($safeName)) { $countsBySafe[$safeName] } else { 0 }
    if ($safeName) { [void]$matchedKeys.Add($safeName) }

    $rows.Add([PSCustomObject]@{
        SafeName     = $safeName
        AccountCount = $count
    })
}

# Any SafeName seen in the accounts CSV that never matched a safe row (deleted/renamed safe, or
# the "no safe assigned" bucket) - surfaced rather than silently dropped, so the sum of
# AccountCount across every row always equals the total account count.
foreach ($key in $countsBySafe.Keys) {
    if ($key -eq $NoSafeLabel -or -not $matchedKeys.Contains($key)) {
        $rows.Add([PSCustomObject]@{
            SafeName     = if ($key -eq $NoSafeLabel) { $NoSafeLabel } else { "$key $NotFoundLabel" }
            AccountCount = $countsBySafe[$key]
        })
    }
}

$sortedRows = $rows | Sort-Object -Property @{ Expression = 'AccountCount'; Descending = $true }, @{ Expression = 'SafeName'; Descending = $false }

try {
    $sortedRows | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Encoding UTF8 -Force
} catch {
    Write-Error "Failed to write output CSV '$OutputCsvPath': $_"
    exit 1
}

$totalAccounts = ($sortedRows | Measure-Object -Property AccountCount -Sum).Sum
$safesUsed     = @($sortedRows | Where-Object {
    $_.AccountCount -gt 0 -and $_.SafeName -ne $NoSafeLabel -and $_.SafeName -notlike "*$NotFoundLabel"
}).Count

Write-Host "Safes listed     : $($sortedRows.Count)" -ForegroundColor Green
Write-Host "Safes in use     : $safesUsed" -ForegroundColor Green
Write-Host "Accounts totaled : $totalAccounts" -ForegroundColor Green
Write-Host "Saved: $OutputCsvPath" -ForegroundColor Green
