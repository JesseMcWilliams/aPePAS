<#
    Manage-Privilege.ps1 driver part: idle timeout and the interactive session loop.
    Dot-sourced by Manage-Privilege.ps1 (Driver Parts region) into its script scope; not run on its own.
#>

#region --- Session Loop ---

function Get-SessionIdleSeconds {
    <#
        Seconds since the last API call made for the user (Get-CyberArkLastApiCallTime), or since
        the session started if none yet. Menu navigation doesn't count, and neither do background
        calls (keepalive, token checks), which pass -NotUserActivity.
    #>
    $since = $script:SessionStartTime
    $last  = if (Get-Command -Name 'Get-CyberArkLastApiCallTime' -ErrorAction SilentlyContinue) { Get-CyberArkLastApiCallTime } else { $null }
    if ($last -and (-not $since -or $last -gt $since)) { $since = $last }
    if (-not $since) { return 0 }
    return ([DateTime]::UtcNow - $since).TotalSeconds
}

function Test-SessionTimedOut {
    <# True (and says so) when the session has been idle for $script:InactivityTimeoutMin. #>
    if ((Get-SessionIdleSeconds) -lt ($script:InactivityTimeoutMin * 60)) { return $false }
    $msg = "Inactivity timeout: no API call for $($script:InactivityTimeoutMin) minutes. Ending session."
    Write-CyberArkLog -Message $msg -Level 'INFO'
    Write-Host "  $msg" -ForegroundColor Yellow
    return $true
}

function Test-SessionHealthy {
    <#
        Run at the top of every menu loop (category, group, action): the inactivity timeout,
        then token health. $false means the session must end ('Exit'). Each menu level runs it,
        so a user who stays inside one category or group still gets the SelfHosted keepalive,
        the ISPSS proactive refresh and the inactivity timeout - without it, the next action
        after the real session expired forced a full re-auth instead of a silent refresh.
    #>
    # Idle = time since the last API call; the category menu footer shows the warning.
    if (Test-SessionTimedOut) { return $false }

    Invoke-ProactiveRefresh
    switch (Test-TokenExpiry) {
        'Expired' {
            if (-not (Invoke-TokenRefresh)) {
                Write-CyberArkLog -Message 'Session ended - could not renew token.' -Level 'ERROR'
                return $false
            }
        }
        'Warning' {
            Invoke-SelfHostedKeepalive
        }
    }
    return $true
}

function Invoke-ActionMenuLoop {
    <# One action menu (a category, or one of its groups). Returns 'Back', 'Exit' or 'Restart'. #>
    param([string[]]$Breadcrumbs, [object[]]$Modules, [string]$BackLabel = 'categories')

    while ($true) {
        if (-not (Test-SessionHealthy)) { return 'Exit' }

        Show-ActionMenu -Breadcrumbs $Breadcrumbs -CategoryModules $Modules -BackLabel $BackLabel
        $actChoice = Read-MenuChoice -Prompt 'Action / [B]ack (default: B)'
        if (-not $actChoice) { $actChoice = 'B' }
        if (Test-SessionTimedOut) { return 'Exit' }

        switch -Regex ($actChoice.ToUpper()) {
            '^X$' {
                if (Confirm-Action 'End this session and exit the script?') { return 'Exit' }
            }
            '^R$' {
                if (Confirm-Action 'Return to profile selection?') { return 'Restart' }
            }
            '^\d+$' {
                $actNum = [int]$actChoice
                if ($actNum -lt 1 -or $actNum -gt $Modules.Count) {
                    Write-Host '  Invalid selection.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                } else {
                    Invoke-ActionModule -ModuleEntry $Modules[$actNum - 1]
                    # A 401 during the module call force-expires the token via
                    # Invoke-TokenInvalidate. Re-check immediately so the re-auth
                    # prompt appears now, not only after the user presses [B].
                    if ((Test-TokenExpiry) -eq 'Expired' -and -not (Invoke-TokenRefresh)) {
                        return 'Exit'
                    }
                }
            }
            '^B\d*$' { return 'Back' }
            default {
                Write-Host '  Invalid input.' -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Invoke-GroupMenuLoop {
    <#
        A category's group submenu (Get-CategoryMenuGroups): pick a group, then its action menu.
        [B] from the action menu comes back here. Returns 'Back', 'Exit' or 'Restart'.
    #>
    param([string[]]$Breadcrumbs, [object[]]$Groups)

    while ($true) {
        if (-not (Test-SessionHealthy)) { return 'Exit' }

        Show-CategoryMenu -Breadcrumbs $Breadcrumbs -Categories $Groups -BackLabel 'categories'
        $grpChoice = Read-MenuChoice -Prompt 'Group / [B]ack (default: B)'
        if (-not $grpChoice) { $grpChoice = 'B' }
        if (Test-SessionTimedOut) { return 'Exit' }

        switch -Regex ($grpChoice.ToUpper()) {
            '^X$' {
                if (Confirm-Action 'End this session and exit the script?') { return 'Exit' }
            }
            '^R$' {
                if (Confirm-Action 'Return to profile selection?') { return 'Restart' }
            }
            '^\d+$' {
                $grpNum = [int]$grpChoice
                if ($grpNum -lt 1 -or $grpNum -gt $Groups.Count) {
                    Write-Host '  Invalid selection.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                } else {
                    $grp     = $Groups[$grpNum - 1]
                    $outcome = Invoke-ActionMenuLoop -Breadcrumbs ($Breadcrumbs + @($grp.Name)) -Modules @($grp.Group) -BackLabel 'groups'
                    if ($outcome -ne 'Back') { return $outcome }
                }
            }
            '^B\d*$' { return 'Back' }
            default {
                Write-Host '  Invalid input.' -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Invoke-SessionLoop {
    $script:SessionStartTime = [DateTime]::UtcNow

    Import-APIModules
    # Re-dot-source each module file into this scope so child functions (Invoke-ActionModule)
    # can call both entry points and custom-input functions by name. The menu loops are called
    # from here, so dynamic scoping still reaches these definitions.
    foreach ($m in $script:LoadedModules) {
        if ($m.PSObject.Properties['Failed'] -and $m.Failed) { continue }
        . $m.FilePath
    }

    $crumbs = @($script:ActiveProfile.ProfileName)

    while ($true) {

        if (-not (Test-SessionHealthy)) { return 'Exit' }

        # --- Category selection ---
        $categories = @($script:LoadedModules | Group-Object { $_.Meta.Category } | Sort-Object Name)
        Show-CategoryMenu -Breadcrumbs $crumbs -Categories $categories
        $catChoice = Read-MenuChoice -Prompt 'Category / [R]estart / [X]it'
        # Checked again after the prompt: time spent waiting at it counts, a menu choice doesn't
        # reset it, so a user who walks away is ended when they come back.
        if (Test-SessionTimedOut) { return 'Exit' }

        switch -Regex ($catChoice.ToUpper()) {

            '^X$' {
                if (Confirm-Action 'End this session and exit the script?') { return 'Exit' }
            }

            '^R$' {
                if (Confirm-Action 'Return to profile selection?') { return 'Restart' }
            }

            '^\d+$' {
                $catNum = [int]$catChoice
                if ($catNum -lt 1 -or $catNum -gt $categories.Count) {
                    Write-Host '  Invalid selection.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                } else {
                    $selectedCat = $categories[$catNum - 1]
                    $catCrumbs   = $crumbs + @($selectedCat.Name)
                    # A category whose modules declare MenuGroup gets a group submenu first; with
                    # only one group loaded for this system type, that step is skipped.
                    $groups  = @(Get-CategoryMenuGroups -Category $selectedCat.Name -Modules @($selectedCat.Group))
                    $outcome = if ($groups.Count -gt 1) {
                        Invoke-GroupMenuLoop -Breadcrumbs $catCrumbs -Groups $groups
                    } elseif ($groups.Count -eq 1) {
                        Invoke-ActionMenuLoop -Breadcrumbs $catCrumbs -Modules @($groups[0].Group)
                    } else {
                        Invoke-ActionMenuLoop -Breadcrumbs $catCrumbs -Modules @(Get-ActionMenuOrder -Modules @($selectedCat.Group))
                    }
                    if ($outcome -ne 'Back') { return $outcome }
                }
            }

            default {
                if ($catChoice) {
                    Write-Host '  Invalid input.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                }
            }
        }

    }   # while session loop
}

#endregion
