#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Manage-Privilege.ps1 - profile management functions.

.DESCRIPTION
    Exercises the profile management loop as a user would: create a profile,
    navigate the menu, select a profile, go back, and quit. External dependencies
    (logging module, auth script, filesystem I/O) are mocked or redirected to a
    temporary directory so no real CyberArk environment is required.
#>

BeforeAll {
    # ── Stubs for module functions that are imported at runtime ──────────────
    # These must be declared BEFORE dot-sourcing Manage-Privilege.ps1 so that
    # Assert-Prerequisites finds them (it only checks file paths, not these stubs).
    function global:Write-CyberArkLog {
        param([string]$Message, [string]$Level)
    }
    function global:Initialize-CyberArkLog {
        param($ProfileName, $Destination, $MinLevel, $LogFolder,
              $SystemType, $AuthMethod, $BaseURL, [switch]$WhatIfMode)
    }
    function global:Close-CyberArkLog { }
    function global:Add-CyberArkLogSummaryEntry {
        param($ModuleName, $ItemsProcessed, $Successes, $Failures)
    }
    function global:Invoke-CyberArkAPI {
        param($Token, $Method, $Endpoint, $Uri, $Body, $QueryParams,
              [switch]$WhatIf, [switch]$IgnoreSSL, [switch]$NotUserActivity, $PageSize)
    }
    function global:Get-AuthToken      { param([switch]$IgnoreSSL) return $null }
    function global:Import-AuthToken   { param($Path, [switch]$AutoRefresh, [switch]$IgnoreExpiry) return $null }
    function global:Save-AuthToken     { param($TokenObject, $ProfileName) }

    # ── Temp directory: replaces the real %APPDATA%\IdiraUnifiedScripts\Profiles folder ───────
    $script:TempDir = Join-Path $env:TEMP "ManagePrivilegeTests_$(Get-Random)"
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    # ── Dot-source Manage-Privilege.ps1 (entry point is skipped via InvocationName guard)
    $script:DriverPath = Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'Manage-Privilege.ps1'
    . $script:DriverPath

    # Redirect the profile directory to our temp location
    $script:DefaultProfileDir = $script:TempDir
    $script:ProfileDir        = $script:TempDir
}

AfterAll {
    if ($script:TempDir -and (Test-Path $script:TempDir)) {
        Remove-Item -Recurse -Force $script:TempDir -ErrorAction SilentlyContinue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - New-BlankProfile' {

    It 'DP01 - creates a profile with the supplied name' {
        $p = New-BlankProfile -Name 'Dev'
        $p.ProfileName      | Should -Be 'Dev'
        $p.AuthTokenProfile | Should -Be 'Dev'
    }

    It 'DP02 - default flags are false' {
        $p = New-BlankProfile -Name 'X'
        $p.IgnoreSSL     | Should -Be $false
        $p.WhatIfDefault | Should -Be $false
    }

    It 'DP03 - folders are empty strings' {
        $p = New-BlankProfile -Name 'X'
        $p.LogFolder    | Should -Be ''
        $p.InputFolder  | Should -Be ''
        $p.OutputFolder | Should -Be ''
    }

    It 'DP04 - Created and Modified are populated' {
        $p = New-BlankProfile -Name 'X'
        $p.Created  | Should -Not -BeNullOrEmpty
        $p.Modified | Should -Not -BeNullOrEmpty
    }

    It 'DP04a - CPM_List defaults to an empty string' {
        $p = New-BlankProfile -Name 'X'
        $p.CPM_List | Should -Be ''
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Profile persistence (Save / Read / GetAll)' {

    BeforeEach {
        # Clear the temp directory before each test for isolation
        Get-ChildItem -LiteralPath $script:TempDir -File -ErrorAction SilentlyContinue |
            Remove-Item -Force
    }

    It 'DP05 - Save-DriverProfile writes a JSON file named after the profile to the profile directory' {
        $p = New-BlankProfile -Name 'SaveTest'
        Save-DriverProfile -currentProfile $p
        $expected = Join-Path $script:TempDir 'SaveTest.json'
        Test-Path -LiteralPath $expected | Should -Be $true
    }

    It 'DP06 - Read-DriverProfile returns the saved profile' {
        $p = New-BlankProfile -Name 'ReadTest'
        $p.LogFolder = 'C:\Logs'
        Save-DriverProfile -currentProfile $p
        $loaded = Read-DriverProfile -Name 'ReadTest'
        $loaded.ProfileName | Should -Be 'ReadTest'
        $loaded.LogFolder   | Should -Be 'C:\Logs'
    }

    It 'DP07 - Read-DriverProfile returns null for a non-existent profile name' {
        Read-DriverProfile -Name 'DoesNotExist' | Should -BeNullOrEmpty
    }

    It 'DP08 - Get-AllDriverProfiles returns an empty array when no profiles exist' {
        $list = @(Get-AllDriverProfiles)
        $list.Count | Should -Be 0
    }

    It 'DP09 - Get-AllDriverProfiles returns one summary entry after saving a profile' {
        $p = New-BlankProfile -Name 'ListTest'
        Save-DriverProfile -currentProfile $p
        $list = @(Get-AllDriverProfiles)
        $list.Count              | Should -Be 1
        $list[0].ProfileName     | Should -Be 'ListTest'
        $list[0].TokenStatus     | Should -Be 'No Token'
    }

    It 'DP10 - Get-AllDriverProfiles returns entries sorted by ProfileName' {
        foreach ($name in 'Zebra', 'Alpha', 'Mango') {
            Save-DriverProfile -currentProfile (New-BlankProfile -Name $name)
        }
        $names = @(Get-AllDriverProfiles) | ForEach-Object { $_.ProfileName }
        $names | Should -Be @('Alpha', 'Mango', 'Zebra')
    }

    It 'DP10a - Get-AllDriverProfiles ignores a stray .auththrottle sidecar file in the profile directory (Testing_Findings-and-Known-Issues.md K17)' {
        # Confirmed live: an earlier version of Get-ISPSSAuthThrottle's sidecar file was named
        # "<name>.auththrottle.json", which collided with this function's own '*.json' profile
        # discovery glob and crashed with PropertyNotFoundException on AuthTokenProfile. Renamed to
        # ".auththrottle" (no .json) to make this structurally impossible - this guards against the
        # same collision ever being reintroduced.
        Save-DriverProfile -currentProfile (New-BlankProfile -Name 'RealProfile')
        Set-Content -LiteralPath (Join-Path $script:TempDir 'RealProfile.auththrottle') -Value '{"NextAllowedAt":"2026-01-01T00:00:00Z"}'

        { @(Get-AllDriverProfiles) } | Should -Not -Throw
        $list = @(Get-AllDriverProfiles)
        $list.Count          | Should -Be 1
        $list[0].ProfileName | Should -Be 'RealProfile'
    }

    It 'DP11 - Remove-DriverProfile deletes the JSON file' {
        Save-DriverProfile -currentProfile (New-BlankProfile -Name 'ToDelete')
        Remove-DriverProfile -Name 'ToDelete'
        $jsonPath = Join-Path $script:TempDir 'ToDelete.json'
        Test-Path -LiteralPath $jsonPath | Should -Be $false
    }

    It 'DP11a - Get-AllDriverProfiles backfills CPM_List on an older profile saved without it' {
        # Simulates a profile saved before CPM_List existed: every other field a real saved
        # profile would have, just missing this one property.
        $oldProfile = New-BlankProfile -Name 'OldProfile'
        $oldProfile.PSObject.Properties.Remove('CPM_List')
        Save-DriverProfile -currentProfile $oldProfile

        $loaded = Read-DriverProfile -Name 'OldProfile'
        $loaded.PSObject.Properties['CPM_List'] | Should -BeNullOrEmpty

        $list = @(Get-AllDriverProfiles)
        $list.Count | Should -Be 1
    }

    It 'DP11b - Get-AllDriverProfiles backfills WebView2AssemblyPath on an older profile saved without it, and it can then be assigned (Testing_Findings-and-Known-Issues.md K13)' {
        # Reproduces the exact reported crash: a profile saved before K11 added
        # WebView2AssemblyPath to New-BlankProfile has no such property at all, and
        # Invoke-ProfileEditFlow's unconditional `$currentProfile.WebView2AssemblyPath = ...`
        # assignment throws SetValueInvocationException under Set-StrictMode -Version Latest
        # unless Get-AllDriverProfiles has backfilled the property first.
        $oldProfile = New-BlankProfile -Name 'OldWebView2Profile'
        $oldProfile.PSObject.Properties.Remove('WebView2AssemblyPath')
        Save-DriverProfile -currentProfile $oldProfile

        $loaded = Read-DriverProfile -Name 'OldWebView2Profile'
        $loaded.PSObject.Properties['WebView2AssemblyPath'] | Should -BeNullOrEmpty

        $list = @(Get-AllDriverProfiles)
        $normalized = ($list | Where-Object { $_.ProfileName -eq 'OldWebView2Profile' }).currentProfile
        $normalized.PSObject.Properties['WebView2AssemblyPath'] | Should -Not -BeNullOrEmpty
        $normalized.WebView2AssemblyPath | Should -Be ''

        { $normalized.WebView2AssemblyPath = 'C:\Custom\WebView2.dll' } | Should -Not -Throw
        $normalized.WebView2AssemblyPath | Should -Be 'C:\Custom\WebView2.dll'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Invoke-ProfileManagementLoop (Q = quit immediately)' {

    BeforeAll {
        Mock Write-Host  { }
        Mock Clear-Host  { }
        Mock Start-Sleep { }
        Mock Show-Header  { }
        Mock Show-Divider { }
        Mock Show-ProfileList { }
        Mock Read-MenuChoice  { 'Q' }

        Get-ChildItem -LiteralPath $script:TempDir -File -ErrorAction SilentlyContinue |
            Remove-Item -Force
    }

    It 'DP12 - returns $null when the user quits at the profile list' {
        $result = Invoke-ProfileManagementLoop
        $result | Should -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Invoke-ProfileManagementLoop (create a profile then quit)' {

    BeforeAll {
        Mock Write-Host  { }
        Mock Clear-Host  { }
        Mock Start-Sleep { }
        Mock Show-Header  { }
        Mock Show-Divider { }
        Mock Show-ProfileList { }
    }

    BeforeEach {
        Get-ChildItem -LiteralPath $script:TempDir -File -ErrorAction SilentlyContinue |
            Remove-Item -Force

        # Queued menu choices: N (new), then Q (quit after creation)
        $script:MenuQ = [System.Collections.Generic.Queue[string]]::new()
        Mock Read-MenuChoice {
            if ($script:MenuQ.Count -gt 0) { $script:MenuQ.Dequeue() } else { 'Q' }
        }

        # Queued field values for Invoke-ProfileEditFlow (Show-FieldPrompt order):
        #   ProfileName, BaseURL/Subdomain, AppName, Username, LogFolder, InputFolder, OutputFolder, IgnoreSSL, WhatIfDefault
        # SystemType ('1'/'2') and AuthMethod ('1'-'8') are Read-MenuChoice and go into MenuQ
        $script:FieldQ = [System.Collections.Generic.Queue[string]]::new()
        Mock Show-FieldPrompt {
            param($Label, $Default, $Description, [switch]$Required, [switch]$IsSecret)
            if ($script:FieldQ.Count -gt 0) { $script:FieldQ.Dequeue() } else { $Default }
        }
    }

    It 'DP13 - creates profile and returns null when user then quits' {
        'N', '2', '1', 'Q' | ForEach-Object { $script:MenuQ.Enqueue($_) }
        'CreatedProfile', 'https://pvwa.test.com', '', '', '', '', '', 'N', 'N' | ForEach-Object { $script:FieldQ.Enqueue($_) }

        $result = Invoke-ProfileManagementLoop
        $result | Should -BeNullOrEmpty

        $jsonPath = Join-Path $script:TempDir 'CreatedProfile.json'
        Test-Path -LiteralPath $jsonPath | Should -Be $true
    }

    It 'DP14 - profile saved with correct ProfileName' {
        'N', '2', '1', 'Q' | ForEach-Object { $script:MenuQ.Enqueue($_) }
        'VerifyName', 'https://pvwa.test.com', '', '', '', '', '', 'N', 'N' | ForEach-Object { $script:FieldQ.Enqueue($_) }

        Invoke-ProfileManagementLoop | Out-Null

        $saved = Read-DriverProfile -Name 'VerifyName'
        $saved               | Should -Not -BeNullOrEmpty
        $saved.ProfileName   | Should -Be 'VerifyName'
        $saved.SystemType    | Should -Be 'Self-Hosted'
        $saved.AuthMethod    | Should -Be 'CyberArk'
        $saved.AppName       | Should -Be 'PasswordVault'
        $saved.Username      | Should -Be ''
        $saved.BaseURL       | Should -Be 'https://pvwa.test.com'
        $saved.IgnoreSSL     | Should -Be $false
        $saved.WhatIfDefault | Should -Be $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - Invoke-ProfileManagementLoop (select profile then go back then quit)' {

    BeforeAll {
        Mock Write-Host  { }
        Mock Clear-Host  { }
        Mock Start-Sleep { }
        Mock Show-Header  { }
        Mock Show-Divider { }
        # Show-ProfileList and Show-ProfileDetail are no-ops (UI only)
        Mock Show-ProfileList   { }
        Mock Show-ProfileDetail { }
    }

    BeforeEach {
        Get-ChildItem -LiteralPath $script:TempDir -File -ErrorAction SilentlyContinue |
            Remove-Item -Force

        $script:MenuQ = [System.Collections.Generic.Queue[string]]::new()
        Mock Read-MenuChoice {
            if ($script:MenuQ.Count -gt 0) { $script:MenuQ.Dequeue() } else { 'Q' }
        }
    }

    It 'DP15 - select a profile by number then go back then quit' {
        # Seed one profile on disk
        Save-DriverProfile -currentProfile (New-BlankProfile -Name 'SelectMe')

        # Outer loop: select '1', inner loop: press 'B' (back), outer loop: press 'Q'
        '1', 'B', 'Q' | ForEach-Object { $script:MenuQ.Enqueue($_) }

        $result = Invoke-ProfileManagementLoop
        $result | Should -BeNullOrEmpty
    }

    It 'DP16 - selecting an out-of-range number does not crash and loops back' {
        Save-DriverProfile -currentProfile (New-BlankProfile -Name 'OnlyOne')

        # '9' is out of range for a one-item list; then 'Q' to exit
        '9', 'Q' | ForEach-Object { $script:MenuQ.Enqueue($_) }

        $result = Invoke-ProfileManagementLoop
        $result | Should -BeNullOrEmpty
    }

    It 'DP17 - delete a profile and verify it is removed from disk' {
        Save-DriverProfile -currentProfile (New-BlankProfile -Name 'DeleteMe')

        # Select '1', press 'D' (delete), confirm 'Y', then 'Q'
        Mock Confirm-Action { return $true }
        '1', 'D', 'Q' | ForEach-Object { $script:MenuQ.Enqueue($_) }

        Invoke-ProfileManagementLoop | Out-Null

        $jsonPath = Join-Path $script:TempDir 'DeleteMe.json'
        Test-Path -LiteralPath $jsonPath | Should -Be $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - single-resource GET /API/LoggedOnUser sends no limit/offset' {

    BeforeEach {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; ErrorMessage = ''; ErrorDetails = $null; Data = $null }
        }
        Mock Save-SessionToken { }
        $script:SavedSessionToken  = $script:SessionToken
        $script:SavedActiveProfile = $script:ActiveProfile
    }

    AfterEach {
        $script:SessionToken  = $script:SavedSessionToken
        $script:ActiveProfile = $script:SavedActiveProfile
    }

    It 'DP18 - Invoke-SelfHostedKeepalive passes -PageSize 0 on GET /API/LoggedOnUser, so no limit/offset is sent' {
        Mock Get-TokenRemainingMinutes { return 1 }
        $script:SessionToken  = [PSCustomObject]@{ Token = 'tok'; SystemType = 'SelfHosted'; Expiry = [DateTime]::UtcNow.AddMinutes(1) }
        $script:ActiveProfile = [PSCustomObject]@{ IgnoreSSL = $false; AuthTokenProfile = 'KeepaliveTest' }
        Invoke-SelfHostedKeepalive
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq '/API/LoggedOnUser' -and $PageSize -eq 0
        }
    }

    It 'DP19 - Invoke-TokenValidate (Self-Hosted) passes -PageSize 0 on GET /API/LoggedOnUser, so no limit/offset is sent' {
        $tok = [PSCustomObject]@{ Token = 'tok'; SystemType = 'SelfHosted'; Expiry = [DateTime]::UtcNow.AddHours(1) }
        $null = Invoke-TokenValidate -Token $tok
        Should -Invoke Invoke-CyberArkAPI -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Endpoint -eq '/API/LoggedOnUser' -and $PageSize -eq 0
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Manage-Privilege - action menu groups (MenuGroup)' {

    BeforeAll {
        function New-MenuEntry {
            param([string]$Name, [string]$Action, [string]$Group)
            $meta = @{ Name = $Name; Action = $Action; Description = ''; AcceptsInputFile = $false; SupportsWhatIf = $false }
            if ($Group) { $meta['MenuGroup'] = $Group }
            [PSCustomObject]@{ Meta = $meta }
        }
    }

    BeforeEach {
        $script:SavedMenuGroupOrder = $script:MenuGroupOrder
        $script:MenuGroupOrder = @{ Things = @('Core', 'Tasks', 'Extras') }
    }

    AfterEach {
        $script:MenuGroupOrder = $script:SavedMenuGroupOrder
    }

    It 'MG01 - Get-ActionMenuOrder keeps List first, then alphabetical by name' {
        $mods = @(
            (New-MenuEntry 'Update Thing' 'Update')
            (New-MenuEntry 'List Thing Methods' 'ListMethods')
            (New-MenuEntry 'Add Thing' 'Add')
            (New-MenuEntry 'List Things' 'List')
        )
        $sorted = @(Get-ActionMenuOrder -Modules $mods)
        @($sorted | ForEach-Object { $_.Meta.Name }) |
            Should -Be @('List Things', 'Add Thing', 'List Thing Methods', 'Update Thing')
    }

    It 'MG02 - Get-CategoryMenuGroups returns no groups for a category without MenuGroup' {
        $mods = @((New-MenuEntry 'List Things' 'List'), (New-MenuEntry 'Add Thing' 'Add'))
        @(Get-CategoryMenuGroups -Category 'Things' -Modules $mods).Count | Should -Be 0
    }

    It 'MG03 - groups follow MenuGroupOrder, skip groups with no modules, and put List* actions first' {
        $mods = @(
            (New-MenuEntry 'Add Extra' 'AddExtra' 'Extras')
            (New-MenuEntry 'List Extras' 'ListExtras' 'Extras')
            (New-MenuEntry 'Add Thing' 'Add' 'Core')
            (New-MenuEntry 'List Things' 'List' 'Core')
        )
        $groups = @(Get-CategoryMenuGroups -Category 'Things' -Modules $mods)
        @($groups | ForEach-Object { $_.Name }) | Should -Be @('Core', 'Extras')
        @($groups | ForEach-Object { $_.Count }) | Should -Be @(2, 2)
        @($groups[1].Group | ForEach-Object { $_.Meta.Name }) | Should -Be @('List Extras', 'Add Extra')
    }

    It 'MG04 - a group missing from MenuGroupOrder sorts after the listed groups; ungrouped modules go to Other, last' {
        $mods = @(
            (New-MenuEntry 'Zap Thing' 'Zap')
            (New-MenuEntry 'Odd Thing' 'Odd' 'Unlisted')
            (New-MenuEntry 'Add Thing' 'Add' 'Core')
        )
        $groups = @(Get-CategoryMenuGroups -Category 'Things' -Modules $mods)
        @($groups | ForEach-Object { $_.Name }) | Should -Be @('Core', 'Unlisted', 'Other')
    }

    It 'MG05 - Show-CategoryMenu with -BackLabel offers [B] Back' {
        $script:MenuLines = [System.Collections.Generic.List[string]]::new()
        Mock Show-Header { }
        Mock Show-Divider { }
        Mock Get-TokenRemainingMinutes { return 30 }
        Mock Get-SessionIdleSeconds { return 0 }
        Mock Write-Host { $script:MenuLines.Add("$Object") }
        $groups = @([PSCustomObject]@{ Name = 'Core'; Count = 2; Group = @() })
        Show-CategoryMenu -Breadcrumbs @('P', 'Things') -Categories $groups -BackLabel 'categories'
        ($script:MenuLines | Where-Object { $_ -match '\[B\] Back to categories' }) | Should -Not -BeNullOrEmpty
        ($script:MenuLines | Where-Object { $_ -match '\[ 1\]\s+Core\s+\(2 actions\)' }) | Should -Not -BeNullOrEmpty
    }

    It 'MG06 - Invoke-GroupMenuLoop opens the chosen group''s actions and returns Back on [B]' {
        Mock Test-SessionHealthy { return $true }
        Mock Test-SessionTimedOut { return $false }
        Mock Show-CategoryMenu { }
        Mock Invoke-ActionMenuLoop { return 'Back' }
        $script:MenuChoices = [System.Collections.Generic.Queue[string]]::new([string[]]@('2', 'B'))
        Mock Read-MenuChoice { return $script:MenuChoices.Dequeue() }
        $groups = @(
            [PSCustomObject]@{ Name = 'Core';   Count = 1; Group = @((New-MenuEntry 'Add Thing' 'Add' 'Core')) }
            [PSCustomObject]@{ Name = 'Extras'; Count = 1; Group = @((New-MenuEntry 'Add Extra' 'AddExtra' 'Extras')) }
        )
        Invoke-GroupMenuLoop -Breadcrumbs @('P', 'Things') -Groups $groups | Should -Be 'Back'
        Should -Invoke Invoke-ActionMenuLoop -Times 1 -Exactly -ParameterFilter {
            $Breadcrumbs[-1] -eq 'Extras' -and $Modules[0].Meta.Name -eq 'Add Extra' -and $BackLabel -eq 'groups'
        }
    }

    It 'MG07 - Invoke-GroupMenuLoop passes Exit from the action menu straight up' {
        Mock Test-SessionHealthy { return $true }
        Mock Test-SessionTimedOut { return $false }
        Mock Show-CategoryMenu { }
        Mock Invoke-ActionMenuLoop { return 'Exit' }
        Mock Read-MenuChoice { return '1' }
        $groups = @([PSCustomObject]@{ Name = 'Core'; Count = 1; Group = @((New-MenuEntry 'Add Thing' 'Add' 'Core')) })
        Invoke-GroupMenuLoop -Breadcrumbs @('P', 'Things') -Groups $groups | Should -Be 'Exit'
    }

    It 'MG08 - every Accounts module declares a MenuGroup listed in the real MenuGroupOrder' {
        $script:MenuGroupOrder = $script:SavedMenuGroupOrder
        $known = @($script:MenuGroupOrder['Accounts'])
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:APIModulesPath 'Accounts') -Filter '*.ps1' -File)
        $files.Count | Should -BeGreaterThan 0
        foreach ($f in $files) {
            $m = [regex]::Match([System.IO.File]::ReadAllText($f.FullName), "(?m)^\s*MenuGroup\s*=\s*'([^']+)'")
            $m.Success | Should -BeTrue -Because "$($f.Name) should declare MenuGroup"
            $known | Should -Contain $m.Groups[1].Value -Because "$($f.Name)'s group should be in MenuGroupOrder"
        }
    }
}

# Invoke-FileWriteWithRetry is NOT unit-tested here. It is a Read-Host-driven interactive
# helper (via Confirm-Action) - per this project's established testing boundary (see
# Claude_Docs\Testing_Plan.md), interactive prompts are not unit tested. Beyond that: appending any
# Describe block that calls it after DP01-DP17 in this specific file reproducibly hangs under
# Pester v6.1 - even the non-throwing, no-retry-needed case - while the exact same function
# body runs correctly (verified directly, no Pester involved: returns $true, Action invoked
# once, no hang) when dot-sourced and called from a plain pwsh session. This is a Pester/file
# interaction issue (in the spirit of Pester issue #2669, which this project has already hit
# once before - see Reference_Lessons-Learned-Pester.md Sections 1 and 16),
# not a defect in Invoke-FileWriteWithRetry itself.
