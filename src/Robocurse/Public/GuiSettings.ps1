# Robocurse GUI Settings and State Persistence
# Handles saving and restoring window position, size, worker count, and selected profile.

function Get-GuiSettingsPath {
    <#
    .SYNOPSIS
        Gets the path to the GUI settings file
    #>
    [CmdletBinding()]
    param()

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
    return Join-Path $scriptDir "Robocurse.settings.json"
}

function Get-GuiState {
    <#
    .SYNOPSIS
        Loads GUI state from settings file
    .OUTPUTS
        PSCustomObject with saved state or defaults if not found
    #>
    [CmdletBinding()]
    param()

    # Define defaults
    $defaults = [PSCustomObject]@{
        WindowLeft = 100
        WindowTop = 100
        WindowWidth = 650
        WindowHeight = 550
        WindowState = 'Normal'
        WorkerCount = 4
        SelectedProfile = $null
        ActivePanel = 'Profiles'
        LastRun = $null
        SavedAt = $null
    }

    $settingsPath = Get-GuiSettingsPath
    if (-not (Test-Path $settingsPath)) {
        return $defaults
    }

    try {
        $json = Get-Content -Path $settingsPath -Raw -ErrorAction Stop
        $loaded = $json | ConvertFrom-Json

        # Merge loaded state with defaults (preserve any new properties)
        $merged = [PSCustomObject]@{}
        foreach ($prop in $defaults.PSObject.Properties) {
            if ($null -ne $loaded.PSObject.Properties[$prop.Name]) {
                $merged | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $loaded.PSObject.Properties[$prop.Name].Value
            } else {
                $merged | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
            }
        }

        # Migration: Update old 1100x800 defaults to new 650x550
        if ($merged.WindowWidth -eq 1100 -and $merged.WindowHeight -eq 800) {
            Write-Verbose "Migrating window size from 1100x800 to 650x550"
            $merged.WindowWidth = 650
            $merged.WindowHeight = 550
        }

        return $merged
    }
    catch {
        Write-Verbose "Failed to load GUI settings: $_"
        return $defaults
    }
}

function Save-GuiState {
    <#
    .SYNOPSIS
        Saves GUI state to settings file
    .DESCRIPTION
        Persists GUI state to JSON settings file including window position/size, worker count,
        selected profile, and panel selection. Supports both direct state object saving and
        building state from Window parameters. Preserves existing LastRun and ActivePanel
        values when saving from Window. Used for restoring user preferences on next launch.
    .PARAMETER Window
        WPF Window object (optional - for saving window position/size)
    .PARAMETER WorkerCount
        Current worker slider value
    .PARAMETER SelectedProfileName
        Name of currently selected profile
    .PARAMETER StateObject
        Existing state object to save directly (alternative to Window parameters)
    #>
    [CmdletBinding()]
    param(
        $Window,

        [int]$WorkerCount,

        [string]$SelectedProfileName,

        [PSCustomObject]$StateObject
    )

    try {
        if ($StateObject) {
            # Save provided state object directly
            $stateToSave = $StateObject
            # Update SavedAt timestamp
            $stateToSave | Add-Member -NotePropertyName 'SavedAt' -NotePropertyValue ([datetime]::Now.ToString('o')) -Force
        } elseif ($Window) {
            # Get existing state to preserve LastRun and ActivePanel
            $existingState = Get-GuiState
            $lastRun = if ($existingState) { $existingState.LastRun } else { $null }
            $activePanel = if ($existingState) { $existingState.ActivePanel } else { 'Profiles' }

            $stateToSave = [PSCustomObject]@{
                WindowLeft = $Window.Left
                WindowTop = $Window.Top
                WindowWidth = $Window.Width
                WindowHeight = $Window.Height
                WindowState = $Window.WindowState.ToString()
                WorkerCount = $WorkerCount
                SelectedProfile = $SelectedProfileName
                ActivePanel = $activePanel
                SavedAt = [datetime]::Now.ToString('o')
                LastRun = $lastRun
            }
        } else {
            throw "Either Window or StateObject parameter must be provided"
        }

        $settingsPath = Get-GuiSettingsPath
        $stateToSave | ConvertTo-Json -Depth 5 | Set-Content -Path $settingsPath -Encoding UTF8 -ErrorAction Stop
        Write-Verbose "GUI state saved to $settingsPath"
    }
    catch {
        Write-Verbose "Failed to save GUI settings: $_"
    }
}

function Restore-GuiState {
    <#
    .SYNOPSIS
        Restores GUI state from settings file
    .PARAMETER Window
        WPF Window object to restore state to
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Window]$Window
    )

    $state = Get-GuiState
    if ($null -eq $state) {
        return
    }

    try {
        # Restore window position and size (validate bounds are on screen)
        if ($state.WindowLeft -ne $null -and $state.WindowTop -ne $null) {
            # Basic bounds check - ensure window is at least partially visible
            $screenWidth = [System.Windows.SystemParameters]::VirtualScreenWidth
            $screenHeight = [System.Windows.SystemParameters]::VirtualScreenHeight

            if ($state.WindowLeft -ge -100 -and $state.WindowLeft -lt $screenWidth -and
                $state.WindowTop -ge -100 -and $state.WindowTop -lt $screenHeight) {
                $Window.Left = $state.WindowLeft
                $Window.Top = $state.WindowTop
            }
        }

        # Restore window size with minimum bounds
        if ($state.WindowWidth -gt 0 -and $state.WindowHeight -gt 0) {
            $Window.Width = [math]::Max($state.WindowWidth, 500)
            $Window.Height = [math]::Max($state.WindowHeight, 400)
        }

        # Restore window state (but not Minimized - that would be annoying)
        if ($state.WindowState -eq 'Maximized') {
            $Window.WindowState = [System.Windows.WindowState]::Maximized
        }

        # Restore worker count (check $script:Controls exists first for headless safety)
        if ($script:Controls -and $state.WorkerCount -gt 0 -and $script:Controls.sldWorkers) {
            $script:Controls.sldWorkers.Value = [math]::Min($state.WorkerCount, $script:Controls.sldWorkers.Maximum)
        }

        # Restore selected profile (after profile list is populated)
        # Handle case where saved profile no longer exists in config (deleted externally)
        if ($script:Controls -and $state.SelectedProfile -and $script:Controls.lstProfiles) {
            $profileToSelect = $script:Controls.lstProfiles.Items | Where-Object { $_.Name -eq $state.SelectedProfile }
            if ($profileToSelect) {
                $script:Controls.lstProfiles.SelectedItem = $profileToSelect
            } else {
                # Profile was deleted - log warning and select first available if any
                Write-Verbose "Saved profile '$($state.SelectedProfile)' no longer exists in config"
                if ($script:Controls.lstProfiles.Items.Count -gt 0) {
                    $script:Controls.lstProfiles.SelectedIndex = 0
                }
            }
        }

        # Restore active panel
        $validPanels = @('Profiles', 'Settings', 'Progress', 'Logs')
        if ($state.ActivePanel -and $state.ActivePanel -in $validPanels) {
            # Note: Set-ActivePanel will be called after controls are initialized
            # Store in script scope for later use in Initialize-RobocurseGui
            $script:RestoredActivePanel = $state.ActivePanel
        } else {
            $script:RestoredActivePanel = 'Profiles'
        }

        # Store the full state including LastRun for preservation on window close
        $script:CurrentGuiState = $state

        Write-Verbose "GUI state restored"
    }
    catch {
        Write-Verbose "Failed to restore GUI settings: $_"
    }
}

function Import-SettingsToForm {
    <#
    .SYNOPSIS
        Loads global settings from config and populates the Settings panel controls
    .DESCRIPTION
        Reads settings from $script:Config.GlobalSettings, $script:Config.Email, and
        $script:Config.Schedule and populates all Settings panel form controls.
    #>
    [CmdletBinding()]
    param()

    # Guard against missing controls
    if (-not $script:Controls) {
        Write-Warning "Controls not initialized - cannot import settings to form"
        return
    }

    # Reload GlobalSettings and Email from file to ensure we have latest values
    # IMPORTANT: Do NOT replace $script:Config entirely - that breaks profile object references
    # The listbox contains references to profile objects in $script:Config.SyncProfiles.
    # If we replace $script:Config, the listbox items become orphaned and profile edits are lost.
    $diskConfig = Get-RobocurseConfig -Path $script:ConfigPath
    if (-not $diskConfig) {
        Write-GuiLog "Failed to load configuration"
        return
    }

    # Update only the settings portions, preserve profile objects
    $script:Config.GlobalSettings = $diskConfig.GlobalSettings
    $script:Config.Email = $diskConfig.Email
    if ($diskConfig.Schedule) {
        $script:Config.Schedule = $diskConfig.Schedule
    }

    # PERFORMANCE Section
    if ($script:Controls['sldSettingsJobs']) {
        $jobs = if ($script:Config.GlobalSettings.MaxConcurrentJobs) { $script:Config.GlobalSettings.MaxConcurrentJobs } else { 4 }
        $script:Controls.sldSettingsJobs.Value = $jobs
        $script:Controls.txtSettingsJobs.Text = $jobs.ToString()
    }

    if ($script:Controls['sldSettingsThreads']) {
        $threads = if ($script:Config.GlobalSettings.ThreadsPerJob) { $script:Config.GlobalSettings.ThreadsPerJob } else { 8 }
        $script:Controls.sldSettingsThreads.Value = $threads
        $script:Controls.txtSettingsThreads.Text = $threads.ToString()
    }

    if ($script:Controls['txtSettingsBandwidth']) {
        $bandwidth = if ($script:Config.GlobalSettings.BandwidthLimitMbps) { $script:Config.GlobalSettings.BandwidthLimitMbps } else { 0 }
        $script:Controls.txtSettingsBandwidth.Text = $bandwidth.ToString()
    }

    # LOGGING Section
    if ($script:Controls['txtSettingsLogPath']) {
        $logPath = if ($script:Config.GlobalSettings.LogPath) { $script:Config.GlobalSettings.LogPath } else { ".\Logs" }
        $script:Controls.txtSettingsLogPath.Text = $logPath
    }

    if ($script:Controls['cmbSettingsLogLevel']) {
        $logLevel = if ($script:Config.GlobalSettings.LogLevel) { $script:Config.GlobalSettings.LogLevel } else { "Info" }
        # Find and select the matching ComboBoxItem
        foreach ($item in $script:Controls.cmbSettingsLogLevel.Items) {
            if ($item.Content -eq $logLevel) {
                $script:Controls.cmbSettingsLogLevel.SelectedItem = $item
                break
            }
        }
        # Also update the runtime MinLogLevel
        $script:MinLogLevel = $logLevel
    }

    if ($script:Controls['chkSettingsVerboseLogging']) {
        $verboseLogging = if ($null -ne $script:Config.GlobalSettings.VerboseFileLogging) { [bool]$script:Config.GlobalSettings.VerboseFileLogging } else { $false }
        Write-RobocurseLog -Message "Loading VerboseFileLogging from config: $($script:Config.GlobalSettings.VerboseFileLogging) -> $verboseLogging" -Level 'Debug' -Component 'Settings'
        $script:Controls.chkSettingsVerboseLogging.IsChecked = $verboseLogging
    }

    # SIEM settings (not yet in config structure - use placeholder defaults)
    if ($script:Controls['chkSettingsSiem']) {
        $script:Controls.chkSettingsSiem.IsChecked = $false
    }
    if ($script:Controls['txtSettingsSiemPath']) {
        $script:Controls.txtSettingsSiemPath.Text = ".\Logs\SIEM"
    }

    # EMAIL NOTIFICATIONS Section
    if ($script:Controls['chkSettingsEmailEnabled']) {
        $enabled = if ($null -ne $script:Config.Email.Enabled) { $script:Config.Email.Enabled } else { $false }
        $script:Controls.chkSettingsEmailEnabled.IsChecked = $enabled
    }

    if ($script:Controls['txtSettingsSmtp']) {
        $smtp = if ($script:Config.Email.SmtpServer) { $script:Config.Email.SmtpServer } else { "" }
        $script:Controls.txtSettingsSmtp.Text = $smtp
    }

    if ($script:Controls['txtSettingsSmtpPort']) {
        $port = if ($script:Config.Email.Port) { $script:Config.Email.Port } else { 587 }
        $script:Controls.txtSettingsSmtpPort.Text = $port.ToString()
    }

    if ($script:Controls['chkSettingsTls']) {
        $useTls = if ($null -ne $script:Config.Email.UseTls) { $script:Config.Email.UseTls } else { $true }
        $script:Controls.chkSettingsTls.IsChecked = $useTls
    }

    if ($script:Controls['txtSettingsCredential']) {
        $cred = if ($script:Config.Email.CredentialTarget) { $script:Config.Email.CredentialTarget } else { "Robocurse-SMTP" }
        $script:Controls.txtSettingsCredential.Text = $cred
    }

    if ($script:Controls['txtSettingsEmailFrom']) {
        $from = if ($script:Config.Email.From) { $script:Config.Email.From } else { "" }
        $script:Controls.txtSettingsEmailFrom.Text = $from
    }

    if ($script:Controls['txtSettingsEmailTo']) {
        # Convert array to newline-separated string (one email per line)
        $to = if ($script:Config.Email.To -and $script:Config.Email.To.Count -gt 0) {
            $script:Config.Email.To -join "`r`n"
        } else {
            ""
        }
        $script:Controls.txtSettingsEmailTo.Text = $to
    }

    # SCHEDULE Section
    if ($script:Controls['txtSettingsScheduleStatus']) {
        if ($script:Config.Schedule.Enabled) {
            $time = if ($script:Config.Schedule.Time) { $script:Config.Schedule.Time } else { "02:00" }
            $days = if ($script:Config.Schedule.Days -and $script:Config.Schedule.Days.Count -gt 0) {
                $script:Config.Schedule.Days -join ", "
            } else {
                "Daily"
            }
            $script:Controls.txtSettingsScheduleStatus.Text = "Enabled - $days at $time"
        } else {
            $script:Controls.txtSettingsScheduleStatus.Text = "Not configured"
        }
    }

    # Note: Snapshot retention is now per-profile, configured in the Profiles tab

    Write-GuiLog "Settings loaded from configuration"
}

function Save-SettingsFromForm {
    <#
    .SYNOPSIS
        Saves Settings panel form values back to configuration file
    .DESCRIPTION
        Reads all Settings panel controls and updates $script:Config, then saves to disk.
    #>
    [CmdletBinding()]
    param()

    # Guard against missing controls
    if (-not $script:Controls -or -not $script:Config) {
        Write-Warning "Controls or config not initialized - cannot save settings"
        return
    }

    try {
        # PERFORMANCE Section
        if ($script:Controls['sldSettingsJobs']) {
            $script:Config.GlobalSettings.MaxConcurrentJobs = [int]$script:Controls.sldSettingsJobs.Value
        }

        if ($script:Controls['sldSettingsThreads']) {
            $script:Config.GlobalSettings.ThreadsPerJob = [int]$script:Controls.sldSettingsThreads.Value
        }

        if ($script:Controls['txtSettingsBandwidth']) {
            $bandwidthText = $script:Controls.txtSettingsBandwidth.Text.Trim()
            $bandwidth = 0
            if ([int]::TryParse($bandwidthText, [ref]$bandwidth)) {
                $script:Config.GlobalSettings.BandwidthLimitMbps = $bandwidth
            }
        }

        # LOGGING Section
        if ($script:Controls['txtSettingsLogPath']) {
            $script:Config.GlobalSettings.LogPath = $script:Controls.txtSettingsLogPath.Text.Trim()
        }

        if ($script:Controls['cmbSettingsLogLevel'] -and $script:Controls.cmbSettingsLogLevel.SelectedItem) {
            $logLevel = $script:Controls.cmbSettingsLogLevel.SelectedItem.Content
            $script:Config.GlobalSettings.LogLevel = $logLevel
            # Also update the runtime MinLogLevel
            $script:MinLogLevel = $logLevel
        }

        if ($script:Controls['chkSettingsVerboseLogging']) {
            $script:Config.GlobalSettings.VerboseFileLogging = [bool]$script:Controls.chkSettingsVerboseLogging.IsChecked
            Write-RobocurseLog -Message "Saving VerboseFileLogging: $($script:Config.GlobalSettings.VerboseFileLogging)" -Level 'Debug' -Component 'Settings'
        }

        # SIEM settings (placeholder - not yet in config structure)
        # Future: Add to GlobalSettings when SIEM path is implemented

        # EMAIL NOTIFICATIONS Section
        if ($script:Controls['chkSettingsEmailEnabled']) {
            $script:Config.Email.Enabled = $script:Controls.chkSettingsEmailEnabled.IsChecked
        }

        if ($script:Controls['txtSettingsSmtp']) {
            $script:Config.Email.SmtpServer = $script:Controls.txtSettingsSmtp.Text.Trim()
        }

        if ($script:Controls['txtSettingsSmtpPort']) {
            $portText = $script:Controls.txtSettingsSmtpPort.Text.Trim()
            $port = 587
            if ([int]::TryParse($portText, [ref]$port)) {
                $script:Config.Email.Port = $port
            }
        }

        if ($script:Controls['chkSettingsTls']) {
            $script:Config.Email.UseTls = $script:Controls.chkSettingsTls.IsChecked
        }

        if ($script:Controls['txtSettingsCredential']) {
            $script:Config.Email.CredentialTarget = $script:Controls.txtSettingsCredential.Text.Trim()
        }

        if ($script:Controls['txtSettingsEmailFrom']) {
            $script:Config.Email.From = $script:Controls.txtSettingsEmailFrom.Text.Trim()
        }

        if ($script:Controls['txtSettingsEmailTo']) {
            # Convert newline-separated string to array (also supports commas for backward compatibility)
            $toText = $script:Controls.txtSettingsEmailTo.Text
            if ([string]::IsNullOrWhiteSpace($toText)) {
                $script:Config.Email.To = @()
            } else {
                $script:Config.Email.To = @($toText -split '[\r\n,]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            }
        }

        # Note: Snapshot retention is now per-profile, configured in the Profiles tab

        # Save configuration to file
        $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
        if ($saveResult.Success) {
            if ($script:Controls['txtStatus']) {
                $script:Controls.txtStatus.Text = "Settings saved"
            }
            Write-GuiLog "Settings saved to configuration file"
        } else {
            Show-GuiError -Message "Failed to save settings" -Details $saveResult.ErrorMessage
        }
    }
    catch {
        Show-GuiError -Message "Error saving settings" -Details $_.Exception.Message
    }
}

function Save-LastRunSummary {
    <#
    .SYNOPSIS
        Saves the last run summary to GUI settings
    .PARAMETER Summary
        Hashtable containing last run details
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Summary
    )

    Write-Verbose "Save-LastRunSummary: Saving summary with Status=$($Summary.Status), ChunksCompleted=$($Summary.ChunksCompleted)"

    $settings = Get-GuiState
    if (-not $settings) {
        # Create minimal settings if none exist
        $settings = [PSCustomObject]@{
            WindowLeft = 100
            WindowTop = 100
            WindowWidth = 650
            WindowHeight = 550
            WindowState = 'Normal'
            WorkerCount = 4
            SelectedProfile = $null
            SavedAt = [datetime]::Now.ToString('o')
            LastRun = $Summary
        }
    } else {
        # Add or update LastRun property
        $settings | Add-Member -NotePropertyName 'LastRun' -NotePropertyValue $Summary -Force
    }

    Save-GuiState -StateObject $settings

    # CRITICAL: Also update in-memory state so window close handler has latest data
    # Without this, window close overwrites the file with stale $script:CurrentGuiState
    if ($script:CurrentGuiState) {
        $script:CurrentGuiState | Add-Member -NotePropertyName 'LastRun' -NotePropertyValue $Summary -Force
        Write-Verbose "Save-LastRunSummary: Updated in-memory CurrentGuiState.LastRun"
    } else {
        Write-Verbose "Save-LastRunSummary: Warning - CurrentGuiState not set, window close may overwrite LastRun"
    }
}

function Get-LastRunSummary {
    <#
    .SYNOPSIS
        Gets the last run summary from GUI settings
    .OUTPUTS
        Hashtable with last run details, or $null if no previous run
    #>
    [CmdletBinding()]
    param()

    $settingsPath = Get-GuiSettingsPath
    Write-Verbose "Get-LastRunSummary: Reading from $settingsPath"

    $settings = Get-GuiState
    if (-not $settings -or -not $settings.LastRun) {
        Write-Verbose "Get-LastRunSummary: No LastRun found in settings"
        return $null
    }

    Write-Verbose "Get-LastRunSummary: Found LastRun with Timestamp=$($settings.LastRun.Timestamp)"
    return $settings.LastRun
}

function Test-VolumeOverridesFormat {
    <#
    .SYNOPSIS
        Validates the volume overrides text format
    .PARAMETER Text
        The text to validate (e.g., "D:=5, E:=10")
    .OUTPUTS
        $true if valid, $false otherwise
    #>
    [CmdletBinding()]
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $true  # Empty is valid
    }

    $pairs = $Text -split '\s*,\s*'
    foreach ($pair in $pairs) {
        if ($pair -notmatch '^[A-Za-z]:\s*=\s*\d+$') {
            return $false
        }
    }

    return $true
}
