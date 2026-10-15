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

function Invoke-SessionLoop {
    $script:SessionStartTime = [DateTime]::UtcNow

    Import-APIModules
    # Re-dot-source each module file into this scope so child functions (Invoke-ActionModule)
    # can call both entry points and custom-input functions by name.
    foreach ($m in $script:LoadedModules) {
        if ($m.PSObject.Properties['Failed'] -and $m.Failed) { continue }
        . $m.FilePath
    }

    $crumbs = @($script:ActiveProfile.ProfileName)

    while ($true) {

        # --- Inactivity check (idle = time since the last API call; the menu footer shows the warning) ---
        if (Test-SessionTimedOut) { return 'Exit' }

        # --- Token health ---
        Invoke-ProactiveRefresh
        switch (Test-TokenExpiry) {
            'Expired' {
                if (-not (Invoke-TokenRefresh)) {
                    Write-CyberArkLog -Message 'Session ended - could not renew token.' -Level 'ERROR'
                    return 'Exit'
                }
            }
            'Warning' {
                Invoke-SelfHostedKeepalive
            }
        }

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
                    $catName     = $selectedCat.Name
                    $catModules  = @(Get-CategoryMenuModules -Category $catName -Modules @($selectedCat.Group))
                    $catCrumbs   = $crumbs + @($catName)

                    # --- Action loop for this category ---
                    while ($true) {
                        # --- Inactivity + token health, mirroring the outer category-menu loop
                        # above. Without this block, a user who stays inside one category
                        # (performing several actions in a row without pressing [B] to return to
                        # the category menu) never got the SelfHosted keepalive call or the ISPSS
                        # proactive refresh, and the inactivity timeout/warning never fired -
                        # since all of that previously lived only in the outer loop. The user's
                        # very next action after the real session actually expired would then
                        # force a full re-auth prompt instead of the silent keepalive/refresh this
                        # logic exists to provide.
                        if (Test-SessionTimedOut) { return 'Exit' }

                        Invoke-ProactiveRefresh
                        switch (Test-TokenExpiry) {
                            'Expired' {
                                if (-not (Invoke-TokenRefresh)) {
                                    Write-CyberArkLog -Message 'Session ended - could not renew token.' -Level 'ERROR'
                                    return 'Exit'
                                }
                            }
                            'Warning' {
                                Invoke-SelfHostedKeepalive
                            }
                        }

                        Show-ActionMenu -Breadcrumbs $catCrumbs -CategoryModules $catModules
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
                                if ($actNum -lt 1 -or $actNum -gt $catModules.Count) {
                                    Write-Host '  Invalid selection.' -ForegroundColor Red
                                    Start-Sleep -Seconds 1
                                } else {
                                    Invoke-ActionModule -ModuleEntry $catModules[$actNum - 1]
                                    # A 401 during the module call force-expires the token via
                                    # Invoke-TokenInvalidate. Re-check immediately so the re-auth
                                    # prompt appears now, not only after the user presses [B].
                                    if ((Test-TokenExpiry) -eq 'Expired' -and -not (Invoke-TokenRefresh)) {
                                        return 'Exit'
                                    }
                                }
                            }
                            { $_ -match '^B\d*$' } { break }
                            default {
                                if ($actChoice) {
                                    Write-Host '  Invalid input.' -ForegroundColor Red
                                    Start-Sleep -Seconds 1
                                }
                            }
                        }

                        if ($actChoice.ToUpper() -match '^B\d*$') { break }
                    }   # end action loop
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
