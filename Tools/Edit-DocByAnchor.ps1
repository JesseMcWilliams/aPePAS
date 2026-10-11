#Requires -Version 5.1
<#
.SYNOPSIS
    Applies exact text replacements to a doc, keeping its BOM and line-ending style. Each anchor
    must occur exactly once.
.DESCRIPTION
    Meant for the long-line Testing_* docs, where an exact anchor is cheaper than reading the file.
    Replacements come from a JSON file: an array of {"Old": "...", "New": "..."} objects. Newlines
    in Old/New may be written as \n; they are matched and written in the file's own style. If any
    anchor is missing or occurs more than once, nothing is written and the script exits 1.
.EXAMPLE
    pwsh -NoProfile -File Tools/Edit-DocByAnchor.ps1 -Path Claude_Docs/Testing_Plan.md -ReplacementsFile edits.json
#>
param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [string]$ReplacementsFile
)

$full  = (Resolve-Path -LiteralPath $Path).Path
$bytes = [System.IO.File]::ReadAllBytes($full)
$bom   = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$text  = [System.Text.Encoding]::UTF8.GetString($bytes)
if ($bom) { $text = $text.Substring(1) }
$nl    = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }

$pairs = @(Get-Content -LiteralPath $ReplacementsFile -Raw -Encoding UTF8 | ConvertFrom-Json)
foreach ($pair in $pairs) {
    $old = ([string]$pair.Old) -replace "`r?`n", $nl
    $new = ([string]$pair.New) -replace "`r?`n", $nl
    $count = ([regex]::Matches($text, [regex]::Escape($old))).Count
    if ($count -ne 1) {
        $preview = if ($old.Length -gt 80) { $old.Substring(0, 80) + '...' } else { $old }
        "Anchor found $count times (must be 1): $preview"
        exit 1
    }
    $text = $text.Replace($old, $new)
}

[System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding($bom)))
"edited $Path ($($pairs.Count) replacement(s))"
