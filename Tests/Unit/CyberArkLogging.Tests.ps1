#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for CyberArkLogging.psm1.
    No CyberArk connection required.
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    # Shared temp directory - one per test run, cleaned up in AfterAll
    $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "CyberArkLogging_Tests_$PID"
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    # Helper: get the most recently created .log file in the temp dir
    function Get-LatestLog {
        Get-ChildItem $script:TempDir -Filter '*.log' -File |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    function Get-LatestLogContent {
        $f = Get-LatestLog
        if ($f) { return Get-Content $f.FullName -Raw } else { return '' }
    }
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
    if (Test-Path $script:TempDir) { Remove-Item $script:TempDir -Recurse -Force }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Initialize-CyberArkLog' {

    BeforeEach {
        Close-CyberArkLog -ErrorAction SilentlyContinue
        # Remove any log files from prior test
        Get-ChildItem $script:TempDir -Filter '*.log' -File | Remove-Item -Force
    }

    It 'L01 - creates a log file under the specified folder' {
        Initialize-CyberArkLog -LogFolder $script:TempDir -ProfileName 'TestProfile'
        $files = Get-ChildItem $script:TempDir -Filter '*.log' -File
        @($files).Count | Should -BeGreaterThan 0
    }

    It 'L02 - log filename contains the profile name and PID' {
        Initialize-CyberArkLog -LogFolder $script:TempDir -ProfileName 'MyProfile'
        $f = Get-LatestLog
        $f.Name | Should -Match 'MyProfile'
        $f.Name | Should -Match "$PID"
    }

    It 'L03 - first line of log is exactly 40 asterisks' {
        Initialize-CyberArkLog -LogFolder $script:TempDir -ProfileName 'StarTest'
        $lines = Get-Content (Get-LatestLog).FullName
        $lines[0] | Should -Be ('*' * 40)
    }

    It 'L04 - header line contains PID and profile name' {
        Initialize-CyberArkLog -LogFolder $script:TempDir -ProfileName 'HeaderProfile'
        $content = Get-LatestLogContent
        $content | Should -Match "PID $PID"
        $content | Should -Match 'HeaderProfile'
    }

    It 'L05 - WhatIf note appears in header when WhatIfMode is true' {
        Initialize-CyberArkLog -LogFolder $script:TempDir -ProfileName 'WITest' -WhatIfMode $true
        $content = Get-LatestLogContent
        $content | Should -Match '\[WhatIf ON\]'
    }

    It 'L06 - creates the log folder if it does not exist' {
        $newFolder = Join-Path $script:TempDir 'SubFolder_L06'
        Initialize-CyberArkLog -LogFolder $newFolder -ProfileName 'FolderTest'
        Test-Path $newFolder | Should -BeTrue
    }

    It 'L07 - Destination=Console creates no log file' {
        Close-CyberArkLog -ErrorAction SilentlyContinue
        Get-ChildItem $script:TempDir -Filter '*.log' | Remove-Item -Force
        Initialize-CyberArkLog -Destination 'Console' -ProfileName 'NoFile'
        $files = Get-ChildItem $script:TempDir -Filter '*.log' -File
        @($files).Count | Should -Be 0
    }

    It 'L08 - invalid MinLevel throws' {
        { Initialize-CyberArkLog -LogFolder $script:TempDir -MinLevel 'BOGUS' } |
            Should -Throw
    }

    It 'L09 - invalid Destination throws' {
        { Initialize-CyberArkLog -LogFolder $script:TempDir -Destination 'Nowhere' } |
            Should -Throw
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Write-CyberArkLog' {

    BeforeEach {
        Close-CyberArkLog -ErrorAction SilentlyContinue
        Get-ChildItem $script:TempDir -Filter '*.log' | Remove-Item -Force
        Initialize-CyberArkLog -LogFolder $script:TempDir -ProfileName 'WriteTests' -Destination 'File' -MinLevel 'INFO'
    }

    AfterEach { Close-CyberArkLog -ErrorAction SilentlyContinue }

    It 'L10 - INFO at INFO minimum is written' {
        Write-CyberArkLog -Message 'Info message' -Level 'INFO'
        Get-LatestLogContent | Should -Match 'Info message'
    }

    It 'L11 - DEBUG at INFO minimum is NOT written' {
        Write-CyberArkLog -Message 'Debug message' -Level 'DEBUG'
        Get-LatestLogContent | Should -Not -Match 'Debug message'
    }

    It 'L12 - VERBOSE at DEBUG minimum is NOT written' {
        Set-CyberArkLogLevel -Level 'DEBUG'
        Write-CyberArkLog -Message 'Verbose message' -Level 'VERBOSE'
        Get-LatestLogContent | Should -Not -Match 'Verbose message'
    }

    It 'L13 - WARN is written when minimum is INFO' {
        Write-CyberArkLog -Message 'Warn message' -Level 'WARN'
        Get-LatestLogContent | Should -Match 'Warn message'
    }

    It 'L14 - ERROR is always written' {
        Write-CyberArkLog -Message 'Error message' -Level 'ERROR'
        Get-LatestLogContent | Should -Match 'Error message'
    }

    It 'L15 - bare mode writes message only (no pipe separators)' {
        Write-CyberArkLog -Message 'Bare line content' -Bare
        $content = Get-LatestLogContent
        # The bare line should appear and contain no pipe characters from the prefix
        $bareLine = ($content -split "`n") | Where-Object { $_ -match 'Bare line content' }
        $bareLine | Should -Not -BeNullOrEmpty
        # Bare lines have no field separators before the message
        $bareLine.Trim() | Should -Be 'Bare line content'
    }

    It 'L16 - PID field is right-aligned to width 7' {
        Write-CyberArkLog -Message 'PID width test' -Level 'INFO'
        $line = (Get-LatestLogContent) -split "`n" |
                Where-Object { $_ -match 'PID width test' } |
                Select-Object -First 1
        # PID field is before first pipe; split includes trailing space from ' | ', so TrimEnd before checking width
        $pidField = ($line -split '\|')[0]
        $pidField.TrimEnd().Length | Should -Be 7
    }

    It 'L17 - LEVEL field is centered at width 7' {
        Write-CyberArkLog -Message 'Level width test' -Level 'WARN'
        $line = (Get-LatestLogContent) -split "`n" |
                Where-Object { $_ -match 'Level width test' } |
                Select-Object -First 1
        # Level field is 3rd pipe-delimited segment (index 2); split includes 1 space on each side from ' | '
        $levelField = ($line -split '\|')[2]
        ($levelField.Length - 2) | Should -Be 7
        $levelField.Trim() | Should -Be 'WARN'
    }

    It 'L18 - FunctionName field is padded to width 24' {
        Write-CyberArkLog -Message 'Fn width test' -Level 'INFO' -FunctionName 'ShortName'
        $line = (Get-LatestLogContent) -split "`n" |
                Where-Object { $_ -match 'Fn width test' } |
                Select-Object -First 1
        # FN field index 3; split includes 1 space on each side from ' | '
        $fnField = ($line -split '\|')[3]
        ($fnField.Length - 2) | Should -Be 24
    }

    It 'L19 - long FunctionName is truncated with ellipsis' {
        $longName = 'A' * 30
        Write-CyberArkLog -Message 'Long fn test' -Level 'INFO' -FunctionName $longName
        $line = (Get-LatestLogContent) -split "`n" |
                Where-Object { $_ -match 'Long fn test' } |
                Select-Object -First 1
        $fnField = ($line -split '\|')[3]
        ($fnField.Length - 2) | Should -Be 24
        $fnField.Contains([char]0x2026) | Should -BeTrue   # ellipsis character
    }

    It 'L20 - masks Bearer token in Authorization header' {
        Write-CyberArkLog -Message 'Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.secret' -Level 'INFO'
        $content = Get-LatestLogContent
        $content | Should -Not -Match 'eyJhbGciOiJSUzI1NiJ9'
        $content | Should -Match '\*\*\*'
    }

    It 'L21 - masks password= pattern' {
        Write-CyberArkLog -Message 'password=SuperSecret123' -Level 'INFO'
        $content = Get-LatestLogContent
        $content | Should -Not -Match 'SuperSecret123'
        $content | Should -Match '\*\*\*'
    }

    It 'L22 - masks access_token JSON value' {
        Write-CyberArkLog -Message '"access_token":"eyTokenValue"' -Level 'INFO'
        $content = Get-LatestLogContent
        $content | Should -Not -Match 'eyTokenValue'
        $content | Should -Match '\*\*\*'
    }

    It 'L22a - masks a quoted JSON password value (request-body form, key and value both quoted)' {
        Write-CyberArkLog -Message 'Request body: {"username":"svc","password":"S3cr3tPass!"}' -Level 'INFO'
        $content = Get-LatestLogContent
        $content | Should -Not -Match 'S3cr3tPass!'
        $content | Should -Match '\*\*\*'
    }

    It 'L22b - masks a quoted JSON NewCredentials value (Accounts/ChangeInVault request body)' {
        Write-CyberArkLog -Message 'Request body: {"NewCredentials":"NewSecretValue123"}' -Level 'INFO'
        $content = Get-LatestLogContent
        $content | Should -Not -Match 'NewSecretValue123'
        $content | Should -Match '\*\*\*'
    }

    It 'L22c - masks a quoted JSON ClientSecret value' {
        Write-CyberArkLog -Message '{"ClientSecret":"MyClientSecretValue"}' -Level 'INFO'
        $content = Get-LatestLogContent
        $content | Should -Not -Match 'MyClientSecretValue'
        $content | Should -Match '\*\*\*'
    }

    It 'L22d - masks a quoted JSON AuthValue value (Applications auth-method credential)' {
        Write-CyberArkLog -Message 'Request body: {"AuthType":"hash","AuthValue":"a1b2c3d4e5f6"}' -Level 'INFO'
        $content = Get-LatestLogContent
        $content | Should -Not -Match 'a1b2c3d4e5f6'
        $content | Should -Match '\*\*\*'
    }

    It 'L23 - non-sensitive message is unchanged' {
        Write-CyberArkLog -Message 'SafeName is MySafe location is root' -Level 'INFO'
        Get-LatestLogContent | Should -Match 'SafeName is MySafe location is root'
    }

    It 'L24 - FunctionName auto-detected from call stack' {
        function Test-CallerDetection {
            Write-CyberArkLog -Message 'AutoDetect' -Level 'INFO'
        }
        Test-CallerDetection
        $content = Get-LatestLogContent
        $content | Should -Match 'Test-CallerDetection'
    }

    It 'L25 - explicit FunctionName overrides call stack' {
        Write-CyberArkLog -Message 'ExplicitFn' -Level 'INFO' -FunctionName 'MyExplicitFunction'
        Get-LatestLogContent | Should -Match 'MyExplicitFunction'
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Add-CyberArkLogSummaryEntry and Close-CyberArkLog' {

    BeforeEach {
        Close-CyberArkLog -ErrorAction SilentlyContinue
        Get-ChildItem $script:TempDir -Filter '*.log' | Remove-Item -Force
        Initialize-CyberArkLog -LogFolder $script:TempDir -ProfileName 'SummaryTests' -Destination 'File'
    }

    It 'L26 - no summary block when no entries added' {
        Close-CyberArkLog
        Get-LatestLogContent | Should -Not -Match 'Session Summary'
    }

    It 'L27 - summary block present when one entry added' {
        Add-CyberArkLogSummaryEntry -ModuleName 'List Safes' -ItemsProcessed 10 -Successes 9 -Failures 1
        Close-CyberArkLog
        Get-LatestLogContent | Should -Match 'Session Summary'
        Get-LatestLogContent | Should -Match 'List Safes'
    }

    It 'L28 - multiple entries each appear in summary' {
        Add-CyberArkLogSummaryEntry -ModuleName 'Add Safe'    -ItemsProcessed 5  -Successes 5  -Failures 0
        Add-CyberArkLogSummaryEntry -ModuleName 'Delete Safe' -ItemsProcessed 3  -Successes 2  -Failures 1
        Close-CyberArkLog
        $content = Get-LatestLogContent
        $content | Should -Match 'Add Safe'
        $content | Should -Match 'Delete Safe'
    }

    It 'L29 - totals are sum of all entries' {
        Add-CyberArkLogSummaryEntry -ModuleName 'ModA' -ItemsProcessed 10 -Successes 8 -Failures 2
        Add-CyberArkLogSummaryEntry -ModuleName 'ModB' -ItemsProcessed 5  -Successes 5 -Failures 0
        Close-CyberArkLog
        $content = Get-LatestLogContent
        $content | Should -Match 'Total items:\s+15'
        $content | Should -Match 'Successes:\s+13'
        $content | Should -Match 'Failures:\s+2'
    }

    It 'L30 - divider lines are 40 dashes' {
        Add-CyberArkLogSummaryEntry -ModuleName 'X' -ItemsProcessed 1 -Successes 1 -Failures 0
        Close-CyberArkLog
        Get-LatestLogContent | Should -Match ('-' * 40)
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Remove-OldCyberArkLogs' {

    BeforeAll {
        $script:LogCleanDir = Join-Path $script:TempDir 'LogClean'
        New-Item -ItemType Directory -Path $script:LogCleanDir -Force | Out-Null
    }

    BeforeEach {
        Get-ChildItem $script:LogCleanDir -Filter '*.log' | Remove-Item -Force
    }

    It 'L31 - deletes log files older than retention window' {
        $oldFile = Join-Path $script:LogCleanDir 'old.log'
        New-Item -ItemType File -Path $oldFile -Force | Out-Null
        (Get-Item $oldFile).LastWriteTime = (Get-Date).AddDays(-40)

        Remove-OldCyberArkLogs -LogFolder $script:LogCleanDir -RetentionDays 30
        Test-Path $oldFile | Should -BeFalse
    }

    It 'L32 - keeps log files within retention window' {
        $newFile = Join-Path $script:LogCleanDir 'new.log'
        New-Item -ItemType File -Path $newFile -Force | Out-Null

        Remove-OldCyberArkLogs -LogFolder $script:LogCleanDir -RetentionDays 30
        Test-Path $newFile | Should -BeTrue
    }

    It 'L33 - non-existent folder does not throw' {
        { Remove-OldCyberArkLogs -LogFolder 'C:\NonExistentFolder_L33_Test' -RetentionDays 30 } |
            Should -Not -Throw
    }

    It 'L34 - WhatIf does not delete files' {
        $oldFile = Join-Path $script:LogCleanDir 'whatif.log'
        New-Item -ItemType File -Path $oldFile -Force | Out-Null
        (Get-Item $oldFile).LastWriteTime = (Get-Date).AddDays(-40)

        Remove-OldCyberArkLogs -LogFolder $script:LogCleanDir -RetentionDays 30 -WhatIf
        Test-Path $oldFile | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────
Describe 'Set-CyberArkLogLevel and Set-CyberArkLogDestination' {

    BeforeEach {
        Close-CyberArkLog -ErrorAction SilentlyContinue
        Get-ChildItem $script:TempDir -Filter '*.log' | Remove-Item -Force
        Initialize-CyberArkLog -LogFolder $script:TempDir -ProfileName 'LevelTests' -Destination 'File' -MinLevel 'INFO'
    }

    AfterEach { Close-CyberArkLog -ErrorAction SilentlyContinue }

    It 'L35 - setting level to VERBOSE allows VERBOSE messages through' {
        Set-CyberArkLogLevel -Level 'VERBOSE'
        Write-CyberArkLog -Message 'VerboseMsg' -Level 'VERBOSE'
        Get-LatestLogContent | Should -Match 'VerboseMsg'
    }

    It 'L36 - setting level to ERROR blocks WARN messages' {
        Set-CyberArkLogLevel -Level 'ERROR'
        Write-CyberArkLog -Message 'WarnShouldBeBlocked' -Level 'WARN'
        Get-LatestLogContent | Should -Not -Match 'WarnShouldBeBlocked'
    }
}
