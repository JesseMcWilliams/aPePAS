#Requires -Version 5.1
<#
.SYNOPSIS
    Rewrites files with CRLF line endings. .ps1/.psm1/.psd1 files always get a UTF-8 BOM; other
    files keep whether they had one.
.DESCRIPTION
    Use after creating a file with a tool that writes LF or no BOM (for example a Write tool or a
    bash heredoc). Content is otherwise unchanged. Prints one line per file.
.EXAMPLE
    pwsh -NoProfile -File Tools/Repair-FileEncoding.ps1 APIModules/Accounts/Invoke-AccountsNew.ps1 Tests/Unit/Invoke-AccountsNew.Tests.ps1
#>
param(
    # Several paths may follow the script name (works with `pwsh -File`).
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]]$Path
)

foreach ($p in $Path) {
    $full  = (Resolve-Path -LiteralPath $p).Path
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $hadBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text  = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $text  = [regex]::Replace($text, "(?<!`r)`n", "`r`n")
    $bom   = $hadBom -or ([System.IO.Path]::GetExtension($full) -in @('.ps1', '.psm1', '.psd1'))
    [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding($bom)))
    "fixed $p (BOM=$bom, CRLF)"
}
