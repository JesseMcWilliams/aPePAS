#Requires -Version 5.1
<#
.SYNOPSIS
    Shared logging module for CyberArk PAS Scripts.

.DESCRIPTION
    Provides Write-CyberArkLog, Initialize-CyberArkLog, Close-CyberArkLog, and
    Remove-OldCyberArkLogs. All components import this module and use it for
    consistent structured log output.

    Log format:
        PID   | yyyy-MM-dd HH:mm:ss | LEVEL   | FunctionName             | Message

    Log levels (in order): VERBOSE, DEBUG, INFO, WARN, ERROR
    Bare mode: message only, no prefix fields.
#>

Set-StrictMode -Version Latest

#region --- Module State ---

$script:LogState = @{
    FilePath         = $null
    MinLevel         = 'INFO'
    Destination      = 'Both'      # 'File' | 'Console' | 'Both'
    PID              = $PID
    ProfileName      = $null
    SessionSummary   = [System.Collections.Generic.List[PSCustomObject]]::new()
    Initialized      = $false
}

# Numeric rank used for level filtering comparisons
$script:LevelRank = @{
    VERBOSE = 0
    DEBUG   = 1
    INFO    = 2
    WARN    = 3
    ERROR   = 4
}

# Console foreground colors per level
$script:LevelColor = @{
    VERBOSE = 'Gray'
    DEBUG   = 'Cyan'
    INFO    = 'White'
    WARN    = 'Yellow'
    ERROR   = 'Red'
}

# Patterns whose values are masked in log messages
$script:SensitivePatterns = @(
    # Bearer / session token values after 'Authorization:' or 'Bearer '
    '(?i)(Authorization:\s*Bearer\s+)\S+'
    '(?i)(Authorization:\s+)\S+'
    # Password / secret keyword assignments (key=value or key: value) - bare/non-JSON form
    '(?i)(password|secret|token|clientsecret|refreshtoken|credential|credentials|newcredentials|newpassword|authvalue)\s*[:=]\s*\S+'
    # OAuth access_token or refresh_token JSON values
    '(?i)"(access_token|refresh_token|id_token)"\s*:\s*"[^"]+"'
    # Any JSON-quoted key containing password/secret/token/credential/authvalue, case-insensitive
    # (covers request-body fields like "NewCredentials", "ClientSecret", "AuthValue" (Applications
    # auth-method value - a hash/path/cert-serial credential) that the plain key=value pattern
    # above misses because the value is quoted, not bare - CyberArkComms logs full POST/PUT/PATCH
    # request bodies at DEBUG/-FileOnly, so an unmatched JSON key here means a real vault
    # password/secret/token/auth value is written to the log file in clear text).
    '(?i)("[^"]*(?:password|secret|token|credential|authvalue)[^"]*")\s*:\s*"[^"\\]*(?:\\.[^"\\]*)*"'
)

#endregion

#region --- Internal Helpers ---

function script:Get-PaddedField {
    param([string]$Value, [int]$Width, [string]$Align = 'Center')
    if ($Value.Length -gt $Width) {
        return $Value.Substring(0, $Width - 1) + [char]0x2026  # …
    }
    $pad = $Width - $Value.Length
    switch ($Align) {
        'Left'   { return $Value.PadRight($Width) }
        'Right'  { return $Value.PadLeft($Width) }
        'Center' {
            $left  = [Math]::Floor($pad / 2)
            $right = $pad - $left
            return (' ' * $left) + $Value + (' ' * $right)
        }
    }
}

function script:Mask-SensitiveData {
    param([string]$Message)
    foreach ($pattern in $script:SensitivePatterns) {
        $Message = [System.Text.RegularExpressions.Regex]::Replace(
            $Message,
            $pattern,
            { param($m)
                # Preserve the key/label portion (group 1) and replace value with ***
                if ($m.Groups.Count -gt 1 -and $m.Groups[1].Success) {
                    return $m.Groups[1].Value + '***'
                }
                return '***'
            }
        )
    }
    return $Message
}

function script:Format-LogLine {
    param([string]$Level, [string]$FunctionName, [string]$Message)

    $ts       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $pidField = script:Get-PaddedField -Value "$($script:LogState.PID)" -Width 7 -Align 'Right'
    $tsField  = script:Get-PaddedField -Value $ts           -Width 19 -Align 'Left'
    $lvlField = script:Get-PaddedField -Value $Level        -Width 7  -Align 'Center'
    $fnField  = script:Get-PaddedField -Value $FunctionName -Width 24 -Align 'Left'

    return "$pidField | $tsField | $lvlField | $fnField | $Message"
}

function script:Write-ToDestinations {
    param([string]$Line, [string]$Level, [bool]$IsBare, [bool]$FileOnly = $false)

    $dest  = $script:LogState.Destination
    $color = if ($script:LevelColor.ContainsKey($Level)) { $script:LevelColor[$Level] } else { 'White' }

    if ($dest -in 'File', 'Both') {
        if ($script:LogState.FilePath) {
            Add-Content -LiteralPath $script:LogState.FilePath -Value $Line -Encoding UTF8
        }
    }

    if (-not $FileOnly -and $dest -in 'Console', 'Both') {
        if ($IsBare) {
            Write-Host $Line
        } else {
            Write-Host $Line -ForegroundColor $color
        }
    }
}

#endregion

#region --- Public Functions ---

function Initialize-CyberArkLog {
    <#
    .SYNOPSIS
        Opens a log file and writes the startup header block.
    .PARAMETER LogFolder
        Folder in which to create the log file. Created if it does not exist.
        If omitted, only console output is written.
    .PARAMETER ProfileName
        Profile name embedded in the log filename and startup line.
    .PARAMETER MinLevel
        Minimum log level written. Default: INFO. Values: VERBOSE, DEBUG, INFO, WARN, ERROR.
    .PARAMETER Destination
        Where to write log output. Default: Both. Values: File, Console, Both.
    .PARAMETER OverwriteFile
        When present, writes to a fixed 'startup.log' filename (overwriting any previous content)
        instead of creating a timestamped log file. Intended for the pre-session startup phase.
    .PARAMETER SystemType
        ISPSS or SelfHosted - included in the startup header line.
    .PARAMETER AuthMethod
        Auth method name - included in the startup header line.
    .PARAMETER BaseURL
        Base URL - included in the startup header line.
    .PARAMETER WhatIfMode
        Whether WhatIf is active for this session - noted in startup header.
    #>
    [CmdletBinding()]
    param(
        [string]$LogFolder,
        [string]$ProfileName    = 'Unknown',
        [string]$MinLevel       = 'INFO',
        [string]$Destination    = 'Both',
        [switch]$OverwriteFile,
        [string]$SystemType     = '',
        [string]$AuthMethod     = '',
        [string]$BaseURL        = '',
        [bool]$WhatIfMode       = $false
    )

    if (-not $script:LevelRank.ContainsKey($MinLevel.ToUpper())) {
        throw "Invalid MinLevel '$MinLevel'. Valid values: VERBOSE, DEBUG, INFO, WARN, ERROR"
    }
    if ($Destination -notin 'File', 'Console', 'Both') {
        throw "Invalid Destination '$Destination'. Valid values: File, Console, Both"
    }

    $script:LogState.MinLevel    = $MinLevel.ToUpper()
    $script:LogState.Destination = $Destination
    $script:LogState.ProfileName = $ProfileName
    $script:LogState.PID         = $PID
    $script:LogState.SessionSummary.Clear()

    # Create log file if a folder was provided
    if ($LogFolder -and $Destination -in 'File', 'Both') {
        if (-not (Test-Path -LiteralPath $LogFolder)) {
            New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
        }
        if ($OverwriteFile) {
            $script:LogState.FilePath = Join-Path $LogFolder 'startup.log'
            [System.IO.File]::WriteAllText($script:LogState.FilePath, [string]::Empty, [System.Text.Encoding]::UTF8)
        } else {
            $timestamp = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
            $safeName  = $ProfileName -replace '[\\/:*?"<>|]', '_'
            $fileName  = "$timestamp`_$safeName`_$PID.log"
            $script:LogState.FilePath = Join-Path $LogFolder $fileName
        }
    } else {
        $script:LogState.FilePath = $null
    }

    $script:LogState.Initialized = $true

    # --- Startup header block ---
    $stars      = '*' * 40
    $whatIfNote = if ($WhatIfMode) { ' [WhatIf ON]' } else { '' }
    $headerParts = @($ProfileName, $SystemType, $AuthMethod, $BaseURL) | Where-Object { $_ }
    $headerLine  = "PID $PID | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $($headerParts -join ' | ')$whatIfNote"

    script:Write-ToDestinations -Line $stars      -Level 'INFO' -IsBare $true
    script:Write-ToDestinations -Line $headerLine -Level 'INFO' -IsBare $true
}

function Write-CyberArkLog {
    <#
    .SYNOPSIS
        Writes a structured log entry.
    .PARAMETER Message
        The log message. Sensitive data is automatically masked.
    .PARAMETER Level
        Log level: VERBOSE, DEBUG, INFO, WARN, ERROR. Default: INFO.
    .PARAMETER FunctionName
        Calling function name. If omitted, auto-detected from call stack.
    .PARAMETER Bare
        When present, writes message only - no PID/timestamp/level/function prefix.
    .PARAMETER FileOnly
        When present, suppresses console output. The entry is written to the log file only.
        Useful for large or sensitive content (e.g. request bodies) that should not appear on screen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [ValidateSet('VERBOSE','DEBUG','INFO','WARN','ERROR')]
        [string]$Level = 'INFO',

        [string]$FunctionName,

        [switch]$Bare,

        [switch]$FileOnly
    )

    # Level filter
    if (-not $Bare) {
        $minRank = $script:LevelRank[$script:LogState.MinLevel]
        $msgRank = $script:LevelRank[$Level.ToUpper()]
        if ($msgRank -lt $minRank) { return }
    }

    # Mask sensitive data
    $safeMessage = script:Mask-SensitiveData -Message $Message

    if ($Bare) {
        script:Write-ToDestinations -Line $safeMessage -Level $Level -IsBare $true
        return
    }

    # Auto-detect function name from call stack if not supplied
    if (-not $FunctionName) {
        $frame = (Get-PSCallStack)[1]
        $FunctionName = if ($frame.FunctionName -and $frame.FunctionName -ne '<ScriptBlock>') {
            $frame.FunctionName
        } else {
            if ($frame.ScriptName) { [System.IO.Path]::GetFileName($frame.ScriptName) } else { '<unknown>' }
        }
    }

    $line = script:Format-LogLine -Level $Level.ToUpper() -FunctionName $FunctionName -Message $safeMessage
    script:Write-ToDestinations -Line $line -Level $Level.ToUpper() -IsBare $false -FileOnly:$FileOnly.IsPresent
}

function Add-CyberArkLogSummaryEntry {
    <#
    .SYNOPSIS
        Records a write/modify operation result for inclusion in the session-end summary.
        View/list operations should not be recorded here.
    .PARAMETER ModuleName
        Name of the API module that performed the operation.
    .PARAMETER ItemsProcessed
        Total rows attempted.
    .PARAMETER Successes
        Rows that succeeded.
    .PARAMETER Failures
        Rows that failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [string]$ModuleName,
        [Parameter(Mandatory = $true)]  [int]$ItemsProcessed,
        [Parameter(Mandatory = $true)]  [int]$Successes,
        [Parameter(Mandatory = $true)]  [int]$Failures
    )

    $script:LogState.SessionSummary.Add([PSCustomObject]@{
        ModuleName     = $ModuleName
        ItemsProcessed = $ItemsProcessed
        Successes      = $Successes
        Failures       = $Failures
    })
}

function Close-CyberArkLog {
    <#
    .SYNOPSIS
        Writes the session summary block and closes the log.
        Call this at script exit (both normal and error paths).
    #>
    [CmdletBinding()]
    param()

    $summary = $script:LogState.SessionSummary

    if ($summary.Count -gt 0) {
        $totalItems     = ($summary | Measure-Object -Property ItemsProcessed -Sum).Sum
        $totalSuccesses = ($summary | Measure-Object -Property Successes      -Sum).Sum
        $totalFailures  = ($summary | Measure-Object -Property Failures       -Sum).Sum

        $divider = '-' * 40
        script:Write-ToDestinations -Line $divider             -Level 'INFO' -IsBare $true
        script:Write-ToDestinations -Line '  Session Summary'  -Level 'INFO' -IsBare $true

        foreach ($entry in $summary) {
            $line = "  $($entry.ModuleName): $($entry.ItemsProcessed) processed, $($entry.Successes) succeeded, $($entry.Failures) failed"
            script:Write-ToDestinations -Line $line -Level 'INFO' -IsBare $true
        }

        script:Write-ToDestinations -Line "  ─────────────────────────"      -Level 'INFO' -IsBare $true
        script:Write-ToDestinations -Line "  Operations logged: $($summary.Count)"    -Level 'INFO' -IsBare $true
        script:Write-ToDestinations -Line "  Total items:       $totalItems"           -Level 'INFO' -IsBare $true
        script:Write-ToDestinations -Line "  Successes:         $totalSuccesses"       -Level 'INFO' -IsBare $true
        script:Write-ToDestinations -Line "  Failures:          $totalFailures"        -Level 'INFO' -IsBare $true
        script:Write-ToDestinations -Line $divider -Level 'INFO' -IsBare $true
    }

    Write-CyberArkLog -Message "Session ended." -Level 'INFO' -FunctionName 'Close-CyberArkLog'
    $script:LogState.Initialized = $false
    $script:LogState.FilePath    = $null
}

function Remove-OldCyberArkLogs {
    <#
    .SYNOPSIS
        Deletes log files older than a specified number of days from a log folder.
    .PARAMETER LogFolder
        Folder to clean.
    .PARAMETER RetentionDays
        Files older than this many days are deleted. Default: 30.
    .PARAMETER WhatIf
        When present, logs which files would be deleted without removing them.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogFolder,

        [int]$RetentionDays = 30
    )

    if (-not (Test-Path -LiteralPath $LogFolder)) {
        Write-CyberArkLog -Message "Log folder not found: $LogFolder" -Level 'WARN'
        return
    }

    $cutoff   = (Get-Date).AddDays(-$RetentionDays)
    $logFiles = Get-ChildItem -LiteralPath $LogFolder -Filter '*.log' -File |
                Where-Object { $_.LastWriteTime -lt $cutoff }

    if (-not $logFiles) {
        Write-CyberArkLog -Message "No log files older than $RetentionDays days found in '$LogFolder'." -Level 'DEBUG'
        return
    }

    foreach ($file in $logFiles) {
        if ($PSCmdlet.ShouldProcess($file.FullName, "Delete log file older than $RetentionDays days")) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force
                Write-CyberArkLog -Message "Deleted old log: $($file.Name)" -Level 'DEBUG'
            } catch {
                Write-CyberArkLog -Message "Failed to delete log '$($file.Name)': $_" -Level 'WARN'
            }
        }
    }
}

function Get-CyberArkLogPath {
    <#
    .SYNOPSIS
        Returns the current log file path, or $null if no file is open.
    #>
    [CmdletBinding()]
    param()
    return $script:LogState.FilePath
}

function Set-CyberArkLogLevel {
    <#
    .SYNOPSIS
        Changes the minimum log level for the current session without re-initializing.
    .PARAMETER Level
        VERBOSE, DEBUG, INFO, WARN, or ERROR.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('VERBOSE','DEBUG','INFO','WARN','ERROR')]
        [string]$Level
    )
    $script:LogState.MinLevel = $Level.ToUpper()
    Write-CyberArkLog -Message "Log level changed to $Level." -Level 'INFO' -FunctionName 'Set-CyberArkLogLevel'
}

function Set-CyberArkLogDestination {
    <#
    .SYNOPSIS
        Changes where log output is written for the current session.
    .PARAMETER Destination
        File, Console, or Both.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('File','Console','Both')]
        [string]$Destination
    )
    $script:LogState.Destination = $Destination
    Write-CyberArkLog -Message "Log destination changed to $Destination." -Level 'INFO' -FunctionName 'Set-CyberArkLogDestination'
}

#endregion

Export-ModuleMember -Function @(
    'Initialize-CyberArkLog'
    'Write-CyberArkLog'
    'Add-CyberArkLogSummaryEntry'
    'Close-CyberArkLog'
    'Remove-OldCyberArkLogs'
    'Get-CyberArkLogPath'
    'Set-CyberArkLogLevel'
    'Set-CyberArkLogDestination'
)
