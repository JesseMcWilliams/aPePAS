#Requires -Version 5.1
<#
.SYNOPSIS
    Checks PowerShell files for the project's file rules: they parse, start with a UTF-8 BOM and
    use CRLF line endings only.
.DESCRIPTION
    With no paths, checks every .ps1/.psm1 file that differs from main (committed, staged,
    unstaged or untracked). Prints one line per problem file and exits 1 if any file fails, 0 if
    all pass. Read-only.
.EXAMPLE
    pwsh -NoProfile -File Tools/Test-FileHygiene.ps1
.EXAMPLE
    pwsh -NoProfile -File Tools/Test-FileHygiene.ps1 APIModules/Accounts/Invoke-AccountsGet.ps1 Modules/CyberArkComms.psm1
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    # Files to check. Several paths may follow the script name (ValueFromRemainingArguments, so
    # this works with `pwsh -File`, where a [string[]] parameter would bind only the first one).
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Path,

    [string]$BaseBranch = 'main'
)

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
Push-Location $repoRoot
try {
    if (-not $Path -or $Path.Count -eq 0) {
        $changed = @(git diff --name-only $BaseBranch -- '*.ps1' '*.psm1' 2>$null)
        $changed += @(git ls-files --others --exclude-standard -- '*.ps1' '*.psm1' 2>$null)
        $Path = @($changed | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique)
    }
    if (-not $Path -or $Path.Count -eq 0) { 'No PowerShell files to check.'; exit 0 }

    $failed = 0
    foreach ($p in $Path) {
        $full = (Resolve-Path -LiteralPath $p).Path
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$errors) | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($full)
        $bom   = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $text  = [System.Text.Encoding]::UTF8.GetString($bytes)
        $bareLf = ([regex]::Matches($text, "(?<!`r)`n")).Count
        $problems = @()
        if ($errors -and @($errors).Count -gt 0) { $problems += "parse errors: $(@($errors).Count) (first: line $($errors[0].Extent.StartLineNumber) $($errors[0].Message))" }
        if (-not $bom)    { $problems += 'no UTF-8 BOM' }
        if ($bareLf -gt 0) { $problems += "$bareLf LF-only line endings" }
        if ($problems.Count -gt 0) { $failed++; "FAIL $p : $($problems -join '; ')" }
    }
    "Checked $($Path.Count) file(s): $failed failed."
    if ($failed -gt 0) { exit 1 }
} finally {
    Pop-Location
}
