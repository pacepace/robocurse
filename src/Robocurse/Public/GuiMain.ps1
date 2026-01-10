# Robocurse GUI Main
# Core window initialization, event wiring, and logging functions.

# GUI Log ring buffer (uses $script:GuiLogMaxLines from constants)
$script:GuiLogBuffer = [System.Collections.Generic.List[string]]::new()
$script:GuiLogDirty = $false  # Track if buffer needs to be flushed to UI

# Error tracking for visual indicator
$script:GuiErrorCount = 0  # Count of errors encountered during current run

# Flag to suppress save during initialization (prevents checkbox/combo events from saving)
$script:GuiInitializing = $true

function Initialize-RobocurseGui {
    <#
    .SYNOPSIS
        Initializes and displays the WPF GUI
    .DESCRIPTION
        Loads XAML from Resources folder, wires up event handlers, initializes the UI state.
        Only works on Windows due to WPF dependency.
    .PARAMETER ConfigPath
        Path to the configuration file. Defaults to .\config.json
    .OUTPUTS
        Window object if successful, $null if not supported
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath = ".\config.json"
    )

    # Store ConfigPath in script scope for use by event handlers and background jobs
    # Resolve to absolute path immediately - background runspaces have different working directories
    if ([System.IO.Path]::IsPathRooted($ConfigPath)) {
        $script:ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    } else {
        $script:ConfigPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $ConfigPath))
    }

    # Check platform
    if (-not (Test-IsWindowsPlatform)) {
        Write-Warning "WPF GUI is only supported on Windows. Use -Headless mode on other platforms."
        return $null
    }

    try {
        # Load WPF assemblies
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase
        # Load Windows Forms for Forms.Timer (more reliable than DispatcherTimer in PowerShell)
        Add-Type -AssemblyName System.Windows.Forms
    }
    catch {
        Write-Warning "Failed to load WPF assemblies. GUI not available: $_"
        return $null
    }

    try {
        # Load XAML from resource file
        $xamlContent = Get-XamlResource -ResourceName 'MainWindow.xaml'
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xamlContent))
        $script:Window = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()
    }
    catch {
        Write-Error "Failed to load XAML: $_"
        return $null
    }

    # Get control references
    # Note: txtLog and svLog removed - now in separate log window (see GuiLogWindow.ps1)
    $script:Controls = @{}
    @(
        'lstProfiles', 'btnAddProfile', 'btnRemoveProfile',
        'txtProfileName', 'txtSource', 'txtDest', 'btnBrowseSource', 'btnBrowseDest',
        'chkUseVss', 'cmbScanMode', 'txtMaxDepth',
        'tabSnapshotConfig', 'chkSourcePersistentSnapshot', 'txtSourceRetentionCount',
        'chkDestPersistentSnapshot', 'txtDestRetentionCount',
        'tabProfileSnapshots', 'dgSourceSnapshots', 'dgDestSnapshots',
        'btnRefreshSourceSnapshots', 'btnDeleteSourceSnapshot', 'btnRefreshDestSnapshots', 'btnDeleteDestSnapshot',
        'btnProfileSchedule', 'btnValidateProfile',
        'sldWorkers', 'txtWorkerCount', 'btnRunAll', 'btnRunSelected', 'btnStop',
        'dgChunks', 'pbProfile', 'pbOverall', 'txtProfileProgress', 'txtOverallProgress',
        'txtEta', 'txtSpeed', 'txtChunks', 'txtStatus',
        'pnlProfileErrors', 'pnlProfileErrorItems',
        'btnNavProfiles', 'btnNavSettings', 'btnNavSnapshots', 'btnNavProgress', 'btnNavLogs',
        'panelProfiles', 'panelSettings', 'panelSnapshots', 'panelProgress', 'panelLogs',
        'pnlProfileSettingsContent', 'pnlNoProfileMessage',
        'chkLogDebug', 'chkLogInfo', 'chkLogWarning', 'chkLogError',
        'chkLogAutoScroll', 'txtLogLineCount', 'txtLogContent',
        'btnLogClear', 'btnLogCopy', 'btnLogSave', 'btnLogPopOut',
        'sldSettingsJobs', 'txtSettingsJobs', 'sldSettingsThreads', 'txtSettingsThreads',
        'txtSettingsBandwidth', 'txtSettingsLogPath', 'btnSettingsLogBrowse',
        'cmbSettingsLogLevel', 'chkSettingsVerboseLogging',
        'chkSettingsSiem', 'txtSettingsSiemPath', 'btnSettingsSiemBrowse',
        'chkSettingsEmailEnabled', 'txtSettingsSmtp', 'txtSettingsSmtpPort',
        'chkSettingsTls', 'txtSettingsCredential', 'btnSettingsSetCredential', 'txtSettingsEmailFrom', 'txtSettingsEmailTo',
        'btnSettingsSchedule', 'txtSettingsScheduleStatus', 'btnSettingsRevert', 'btnSettingsSave',
        'cmbSnapshotVolume', 'cmbSnapshotServer', 'btnRefreshSnapshots', 'dgSnapshots',
        'btnCreateSnapshot', 'btnDeleteSnapshot',
        'cmChunks', 'miRetryChunk', 'miSkipChunk', 'miOpenLog'
    ) | ForEach-Object {
        $script:Controls[$_] = $script:Window.FindName($_)
    }

    # Wire up event handlers
    Initialize-EventHandlers

    # Add keyboard shortcut handler
    $script:Window.Add_PreviewKeyDown({
        param($sender, $e)

        Invoke-SafeEventHandler -HandlerName 'Window_PreviewKeyDown' -ScriptBlock {
            $ctrl = ($e.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0

            # Check if TextBox has focus
            $focusedElement = [System.Windows.Input.Keyboard]::FocusedElement
            $isTextBoxFocused = $focusedElement -is [System.Windows.Controls.TextBox]

            $handled = Invoke-KeyboardShortcut -Key $e.Key.ToString() -Ctrl $ctrl -IsTextBoxFocused $isTextBoxFocused

            if ($handled) {
                $e.Handled = $true
            }
        }
    })

    # Log version first (before any profile loading)
    $version = if ($script:RobocurseVersion) { $script:RobocurseVersion } else { "dev.local" }
    $initMessage = "Robocurse (https://github.com/pacepace/robocurse) $version initialized"
    Write-RobocurseLog -Message $initMessage -Level 'Info' -Component 'GUI'
    Write-GuiLog $initMessage

    # Load config and populate UI
    $script:Config = Get-RobocurseConfig -Path $script:ConfigPath
    Update-ProfileList

    # Set MinLogLevel from config (defaults to Info)
    if ($script:Config.GlobalSettings.LogLevel) {
        $script:MinLogLevel = $script:Config.GlobalSettings.LogLevel
    }

    # Restore saved GUI state (window position, size, worker count, selected profile)
    Restore-GuiState -Window $script:Window

    # Save GUI state on window close
    $script:Window.Add_Closing({
        $selectedProfile = $script:Controls.lstProfiles.SelectedItem
        $selectedName = if ($selectedProfile) { $selectedProfile.Name } else { $null }
        $workerCount = [int]$script:Controls.sldWorkers.Value

        # Get LastRun from in-memory state (updated by Save-LastRunSummary after each run)
        $lastRun = if ($script:CurrentGuiState -and $script:CurrentGuiState.LastRun) { $script:CurrentGuiState.LastRun } else { $null }
        Write-Verbose "Window closing: LastRun from CurrentGuiState = $(if ($lastRun) { $lastRun.Timestamp } else { 'null' })"

        # Create state object to save
        $state = [PSCustomObject]@{
            WindowLeft = $script:Window.Left
            WindowTop = $script:Window.Top
            WindowWidth = $script:Window.Width
            WindowHeight = $script:Window.Height
            WindowState = $script:Window.WindowState.ToString()
            WorkerCount = $workerCount
            SelectedProfile = $selectedName
            ActivePanel = if ($script:ActivePanel) { $script:ActivePanel } else { 'Profiles' }
            LastRun = $lastRun
            SavedAt = [datetime]::Now.ToString('o')
        }

        Save-GuiState -StateObject $state
    })

    # Initialize progress timer - use Forms.Timer instead of DispatcherTimer
    # Forms.Timer uses Windows message queue (WM_TIMER) which is more reliable in PowerShell
    # than WPF's DispatcherTimer which gets starved during background runspace operations
    $script:ProgressTimer = New-Object System.Windows.Forms.Timer
    $script:ProgressTimer.Interval = $script:GuiProgressUpdateIntervalMs
    $script:ProgressTimer.Add_Tick({ Update-GuiProgress })

    # Mark initialization complete - event handlers can now save
    $script:GuiInitializing = $false

    # Initialize Snapshots panel
    Initialize-SnapshotsPanel

    # Set active panel (from restored state or default to Profiles)
    $panelToActivate = if ($script:RestoredActivePanel) { $script:RestoredActivePanel } else { 'Profiles' }
    Set-ActivePanel -PanelName $panelToActivate

    # Set window title with version (version already logged earlier)
    $script:Window.Title = "Robocurse $version - Replication Cursed Robo"

    return $script:Window
}

function Invoke-SafeEventHandler {
    <#
    .SYNOPSIS
        Wraps event handler code in try-catch for safe execution
    .DESCRIPTION
        Prevents GUI crashes from unhandled exceptions in event handlers.
        Logs errors and shows user-friendly message.
    .PARAMETER ScriptBlock
        The event handler code to execute safely
    .PARAMETER HandlerName
        Name of the handler for logging (optional)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [string]$HandlerName = "EventHandler"
    )

    try {
        & $ScriptBlock
    }
    catch {
        $errorMsg = "Error in $HandlerName : $($_.Exception.Message)"
        Write-GuiLog $errorMsg
        try {
            [System.Windows.MessageBox]::Show(
                "An error occurred: $($_.Exception.Message)",
                "Error",
                "OK",
                "Error"
            )
        }
        catch {
            # If even the message box fails, just log it
            Write-Warning $errorMsg
        }
    }
}

function Show-Panel {
    <#
    .SYNOPSIS
        Shows the specified panel and hides all others
    .DESCRIPTION
        Implements the navigation rail panel switching logic by setting Visibility
        to 'Visible' for the selected panel and 'Collapsed' for all others.
    .PARAMETER PanelName
        Name of the panel to show (panelProfiles, panelSettings, panelProgress, panelLogs)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('panelProfiles', 'panelSettings', 'panelProgress', 'panelLogs')]
        [string]$PanelName
    )

    # Hide all panels
    @('panelProfiles', 'panelSettings', 'panelSnapshots', 'panelProgress', 'panelLogs') | ForEach-Object {
        if ($script:Controls[$_]) {
            $script:Controls[$_].Visibility = [System.Windows.Visibility]::Collapsed
        }
    }

    # Show selected panel
    if ($script:Controls[$PanelName]) {
        $script:Controls[$PanelName].Visibility = [System.Windows.Visibility]::Visible
    }
}

function Set-ActivePanel {
    <#
    .SYNOPSIS
        Switches the active panel and updates navigation button states
    .DESCRIPTION
        Sets the specified panel as active by showing it, hiding all other panels,
        and updating the navigation rail button states. Maintains state tracking
        for the currently active panel.
    .PARAMETER PanelName
        Name of the panel to activate (Profiles, Settings, Progress, Logs)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Profiles', 'Settings', 'Snapshots', 'Progress', 'Logs')]
        [string]$PanelName
    )

    Write-RobocurseLog -Level 'Debug' -Component 'GUI' -Message "Switching to panel: $PanelName"

    # Map friendly name to control name
    $panelControlName = "panel$PanelName"
    $buttonControlName = "btnNav$PanelName"

    # Hide all panels
    @('panelProfiles', 'panelSettings', 'panelSnapshots', 'panelProgress', 'panelLogs') | ForEach-Object {
        if ($script:Controls[$_]) {
            $script:Controls[$_].Visibility = [System.Windows.Visibility]::Collapsed
        }
    }

    # Show selected panel
    if ($script:Controls[$panelControlName]) {
        $script:Controls[$panelControlName].Visibility = [System.Windows.Visibility]::Visible
    }

    # Update button states - set IsChecked for the active button
    # RadioButtons in the same GroupName will automatically uncheck others
    @('btnNavProfiles', 'btnNavSettings', 'btnNavSnapshots', 'btnNavProgress', 'btnNavLogs') | ForEach-Object {
        if ($script:Controls[$_]) {
            $script:Controls[$_].IsChecked = ($_ -eq $buttonControlName)
        }
    }

    # Panel-specific initialization when switching
    if ($PanelName -eq 'Settings') {
        # Load current settings into form when switching to Settings panel
        Import-SettingsToForm
    }
    elseif ($PanelName -eq 'Snapshots') {
        # Refresh snapshot list when panel becomes visible
        Update-SnapshotList
    }
    elseif ($PanelName -eq 'Progress') {
        # Show empty state if idle (no replication running)
        if (-not $script:OrchestrationState -or
            $script:OrchestrationState.Phase -in @('Idle', 'Complete', $null)) {
            Show-ProgressEmptyState
        }
    }
    elseif ($PanelName -eq 'Logs') {
        # Refresh log content when switching to Logs panel
        # This ensures logs added while on other panels are displayed
        Update-InlineLogContent
    }

    # Store active panel in script scope
    $script:ActivePanel = $PanelName
}

function Initialize-EventHandlers {
    <#
    .SYNOPSIS
        Wires up all GUI event handlers
    .DESCRIPTION
        All handlers are wrapped in error boundaries to prevent GUI crashes.
    #>
    [CmdletBinding()]
    param()

    # Profile list selection
    $script:Controls.lstProfiles.Add_SelectionChanged({
        Invoke-SafeEventHandler -HandlerName "ProfileSelection" -ScriptBlock {
            Update-ProfileSettingsVisibility
            $selected = $script:Controls.lstProfiles.SelectedItem
            if ($selected) {
                Import-ProfileToForm -Profile $selected
            }
        }
    })

    # Profile row click - clicking anywhere on the row (except checkbox) should:
    # 1. Deselect all other checkboxes
    # 2. Select this profile's checkbox
    # 3. Switch to this profile
    $script:Controls.lstProfiles.Add_PreviewMouseLeftButtonDown({
        param($sender, $e)
        Invoke-SafeEventHandler -HandlerName "ProfileRowClick" -ScriptBlock {
            # Find the clicked element
            $clickedElement = $e.OriginalSource

            # Walk up the visual tree to check if we hit a CheckBox
            $current = $clickedElement
            $foundCheckBox = $false

            while ($current -ne $null) {
                if ($current -is [System.Windows.Controls.CheckBox]) {
                    $foundCheckBox = $true
                    break
                }
                # Stop at ListBoxItem level
                if ($current -is [System.Windows.Controls.ListBoxItem]) {
                    break
                }
                # Get visual parent
                $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
            }

            # Handle click anywhere on the row EXCEPT on the checkbox
            if (-not $foundCheckBox) {
                # Find the profile from the DataContext
                $profile = $null
                $current = $clickedElement
                while ($current -ne $null) {
                    if ($current.DataContext -and $current.DataContext.PSObject.Properties['Name']) {
                        $profile = $current.DataContext
                        break
                    }
                    $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
                }

                if ($profile) {
                    # Enable only this profile (disables all others)
                    Set-SingleProfileEnabled -Profile $profile

                    # Select this item in the ListBox (triggers SelectionChanged)
                    $script:Controls.lstProfiles.SelectedItem = $profile

                    # Save the config to persist the changes
                    Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath | Out-Null
                }
            }
        }
    })

    # Add/Remove profile buttons
    $script:Controls.btnAddProfile.Add_Click({
        Invoke-SafeEventHandler -HandlerName "AddProfile" -ScriptBlock { Add-NewProfile }
    })
    $script:Controls.btnRemoveProfile.Add_Click({
        Invoke-SafeEventHandler -HandlerName "RemoveProfile" -ScriptBlock { Remove-SelectedProfile }
    })

    # Browse buttons
    $script:Controls.btnBrowseSource.Add_Click({
        Invoke-SafeEventHandler -HandlerName "BrowseSource" -ScriptBlock {
            $path = Show-FolderBrowser -Description "Select source folder"
            if ($path) {
                $script:Controls.txtSource.Text = $path
                Save-ProfileFromForm  # Immediately persist the path change
            }
        }
    })
    $script:Controls.btnBrowseDest.Add_Click({
        Invoke-SafeEventHandler -HandlerName "BrowseDest" -ScriptBlock {
            $path = Show-FolderBrowser -Description "Select destination folder"
            if ($path) {
                $script:Controls.txtDest.Text = $path
                Save-ProfileFromForm  # Immediately persist the path change
            }
        }
    })

    # Validate Profile button
    $script:Controls.btnValidateProfile.Add_Click({
        Invoke-SafeEventHandler -HandlerName "ValidateProfile" -ScriptBlock {
            $selectedProfile = $script:Controls.lstProfiles.SelectedItem
            if (-not $selectedProfile) {
                Show-AlertDialog -Title "No Profile Selected" -Message "Please select a profile to validate" -Icon 'Warning'
                return
            }
            Show-ValidationDialog -Profile $selectedProfile
        }
    })

    # Profile Schedule button
    $script:Controls.btnProfileSchedule.Add_Click({
        Invoke-SafeEventHandler -HandlerName "ProfileSchedule" -ScriptBlock {
            $selectedProfile = $script:Controls.lstProfiles.SelectedItem
            if (-not $selectedProfile) {
                Show-AlertDialog -Title "No Profile Selected" -Message "Please select a profile to configure scheduling" -Icon 'Warning'
                return
            }
            $result = Show-ProfileScheduleDialog -Profile $selectedProfile
            if ($result) {
                Write-GuiLog "Profile schedule updated for $($selectedProfile.Name)"
                Update-ProfileScheduleButtonState
            }
        }
    })

    # Workers slider
    $script:Controls.sldWorkers.Add_ValueChanged({
        Invoke-SafeEventHandler -HandlerName "WorkerSlider" -ScriptBlock {
            $script:Controls.txtWorkerCount.Text = [int]$script:Controls.sldWorkers.Value
        }
    })

    # Run buttons - most critical, need error handling
    $script:Controls.btnRunAll.Add_Click({
        Invoke-SafeEventHandler -HandlerName "RunAll" -ScriptBlock { Start-GuiReplication -AllProfiles }
    })
    $script:Controls.btnRunSelected.Add_Click({
        Invoke-SafeEventHandler -HandlerName "RunSelected" -ScriptBlock { Start-GuiReplication -SelectedOnly }
    })
    $script:Controls.btnStop.Add_Click({
        Invoke-SafeEventHandler -HandlerName "Stop" -ScriptBlock { Request-Stop }
    })

    # Status text - click to show error popup when errors exist
    $script:Controls.txtStatus.Add_MouseLeftButtonUp({
        Invoke-SafeEventHandler -HandlerName "StatusClick" -ScriptBlock {
            if ($script:GuiErrorCount -gt 0) {
                Show-ErrorPopup
            }
        }
    })

    # Navigation rail buttons - toggle panel visibility
    $script:Controls.btnNavProfiles.Add_Checked({
        Invoke-SafeEventHandler -HandlerName "NavProfiles" -ScriptBlock { Set-ActivePanel -PanelName 'Profiles' }
    })
    $script:Controls.btnNavSettings.Add_Checked({
        Invoke-SafeEventHandler -HandlerName "NavSettings" -ScriptBlock { Set-ActivePanel -PanelName 'Settings' }
    })
    $script:Controls.btnNavSnapshots.Add_Checked({
        Invoke-SafeEventHandler -HandlerName "NavSnapshots" -ScriptBlock { Set-ActivePanel -PanelName 'Snapshots' }
    })
    $script:Controls.btnNavProgress.Add_Checked({
        Invoke-SafeEventHandler -HandlerName "NavProgress" -ScriptBlock { Set-ActivePanel -PanelName 'Progress' }
    })
    $script:Controls.btnNavLogs.Add_Checked({
        Invoke-SafeEventHandler -HandlerName "NavLogs" -ScriptBlock { Set-ActivePanel -PanelName 'Logs' }
    })

    # Inline log viewer - filter checkboxes
    if ($script:Controls['chkLogDebug']) {
        $script:Controls.chkLogDebug.Add_Checked({
            Invoke-SafeEventHandler -HandlerName "LogFilterDebug" -ScriptBlock { Update-InlineLogContent }
        })
        $script:Controls.chkLogDebug.Add_Unchecked({
            Invoke-SafeEventHandler -HandlerName "LogFilterDebug" -ScriptBlock { Update-InlineLogContent }
        })
    }
    if ($script:Controls['chkLogInfo']) {
        $script:Controls.chkLogInfo.Add_Checked({
            Invoke-SafeEventHandler -HandlerName "LogFilterInfo" -ScriptBlock { Update-InlineLogContent }
        })
        $script:Controls.chkLogInfo.Add_Unchecked({
            Invoke-SafeEventHandler -HandlerName "LogFilterInfo" -ScriptBlock { Update-InlineLogContent }
        })
    }
    if ($script:Controls['chkLogWarning']) {
        $script:Controls.chkLogWarning.Add_Checked({
            Invoke-SafeEventHandler -HandlerName "LogFilterWarning" -ScriptBlock { Update-InlineLogContent }
        })
        $script:Controls.chkLogWarning.Add_Unchecked({
            Invoke-SafeEventHandler -HandlerName "LogFilterWarning" -ScriptBlock { Update-InlineLogContent }
        })
    }
    if ($script:Controls['chkLogError']) {
        $script:Controls.chkLogError.Add_Checked({
            Invoke-SafeEventHandler -HandlerName "LogFilterError" -ScriptBlock { Update-InlineLogContent }
        })
        $script:Controls.chkLogError.Add_Unchecked({
            Invoke-SafeEventHandler -HandlerName "LogFilterError" -ScriptBlock { Update-InlineLogContent }
        })
    }

    # Inline log viewer - button handlers
    if ($script:Controls['btnLogClear']) {
        $script:Controls.btnLogClear.Add_Click({
            Invoke-SafeEventHandler -HandlerName "LogClear" -ScriptBlock {
                Clear-GuiLogBuffer
                Update-InlineLogContent
            }
        })
    }
    if ($script:Controls['btnLogCopy']) {
        $script:Controls.btnLogCopy.Add_Click({
            Invoke-SafeEventHandler -HandlerName "LogCopy" -ScriptBlock {
                if ($script:Controls['txtLogContent'] -and $script:Controls.txtLogContent.Text) {
                    [System.Windows.Clipboard]::SetText($script:Controls.txtLogContent.Text)
                }
            }
        })
    }
    if ($script:Controls['btnLogSave']) {
        $script:Controls.btnLogSave.Add_Click({
            Invoke-SafeEventHandler -HandlerName "LogSave" -ScriptBlock {
                try {
                    $saveDialog = New-Object Microsoft.Win32.SaveFileDialog
                    $saveDialog.Filter = "Log files (*.log)|*.log|Text files (*.txt)|*.txt|All files (*.*)|*.*"
                    $saveDialog.DefaultExt = ".log"
                    $saveDialog.FileName = "robocurse-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

                    if ($saveDialog.ShowDialog() -eq $true) {
                        if ($script:Controls['txtLogContent']) {
                            $script:Controls.txtLogContent.Text | Set-Content -Path $saveDialog.FileName -Encoding UTF8
                            Write-GuiLog "Log saved to: $($saveDialog.FileName)"
                        }
                    }
                }
                catch {
                    Show-GuiError -Message "Failed to save log file" -Details $_.Exception.Message
                }
            }
        })
    }
    if ($script:Controls['btnLogPopOut']) {
        $script:Controls.btnLogPopOut.Add_Click({
            Invoke-SafeEventHandler -HandlerName "LogPopOut" -ScriptBlock { Show-LogWindow }
        })
    }

    # Form field changes - save to profile
    @('txtProfileName', 'txtSource', 'txtDest', 'txtMaxDepth') | ForEach-Object {
        $script:Controls[$_].Add_LostFocus({
            Invoke-SafeEventHandler -HandlerName "SaveProfile" -ScriptBlock { Save-ProfileFromForm }
        })
    }

    # Numeric input validation - reject non-numeric characters in real-time
    # This provides immediate feedback before the user finishes typing
    @('txtMaxDepth') | ForEach-Object {
        $control = $script:Controls[$_]
        if ($control) {
            $control.Add_PreviewTextInput({
                param($sender, $e)
                # Only allow digits (0-9)
                $e.Handled = -not ($e.Text -match '^\d+$')
            })
            # Also handle paste - filter non-numeric content using DataObject.AddPastingHandler
            # This is the correct WPF API for handling paste events
            [System.Windows.DataObject]::AddPastingHandler($control, {
                param($sender, $e)
                if ($e.DataObject.GetDataPresent([System.Windows.DataFormats]::Text)) {
                    $text = $e.DataObject.GetData([System.Windows.DataFormats]::Text)
                    if ($text -notmatch '^\d+$') {
                        $e.CancelCommand()
                    }
                }
            })
        }
    }
    $script:Controls.chkUseVss.Add_Checked({
        Invoke-SafeEventHandler -HandlerName "VssCheckbox" -ScriptBlock { Save-ProfileFromForm }
    })
    $script:Controls.chkUseVss.Add_Unchecked({
        Invoke-SafeEventHandler -HandlerName "VssCheckbox" -ScriptBlock { Save-ProfileFromForm }
    })
    # Source snapshot controls
    if ($script:Controls['chkSourcePersistentSnapshot']) {
        $script:Controls.chkSourcePersistentSnapshot.Add_Checked({
            Invoke-SafeEventHandler -HandlerName "SourceSnapshotCheckbox" -ScriptBlock { Save-ProfileFromForm }
        })
        $script:Controls.chkSourcePersistentSnapshot.Add_Unchecked({
            Invoke-SafeEventHandler -HandlerName "SourceSnapshotCheckbox" -ScriptBlock { Save-ProfileFromForm }
        })
    }
    if ($script:Controls['txtSourceRetentionCount']) {
        $script:Controls.txtSourceRetentionCount.Add_LostFocus({
            Invoke-SafeEventHandler -HandlerName "SourceRetention" -ScriptBlock { Save-ProfileFromForm }
        })
    }

    # Destination snapshot controls
    if ($script:Controls['chkDestPersistentSnapshot']) {
        $script:Controls.chkDestPersistentSnapshot.Add_Checked({
            Invoke-SafeEventHandler -HandlerName "DestSnapshotCheckbox" -ScriptBlock { Save-ProfileFromForm }
        })
        $script:Controls.chkDestPersistentSnapshot.Add_Unchecked({
            Invoke-SafeEventHandler -HandlerName "DestSnapshotCheckbox" -ScriptBlock { Save-ProfileFromForm }
        })
    }
    if ($script:Controls['txtDestRetentionCount']) {
        $script:Controls.txtDestRetentionCount.Add_LostFocus({
            Invoke-SafeEventHandler -HandlerName "DestRetention" -ScriptBlock { Save-ProfileFromForm }
        })
    }

    # Profile snapshot management controls
    if ($script:Controls['btnRefreshSourceSnapshots']) {
        $script:Controls.btnRefreshSourceSnapshots.Add_Click({
            Invoke-SafeEventHandler -HandlerName "RefreshSourceSnapshots" -ScriptBlock { Update-ProfileSnapshotLists }
        })
    }
    if ($script:Controls['btnRefreshDestSnapshots']) {
        $script:Controls.btnRefreshDestSnapshots.Add_Click({
            Invoke-SafeEventHandler -HandlerName "RefreshDestSnapshots" -ScriptBlock { Update-ProfileSnapshotLists }
        })
    }
    if ($script:Controls['btnDeleteSourceSnapshot']) {
        $script:Controls.btnDeleteSourceSnapshot.Add_Click({
            Invoke-SafeEventHandler -HandlerName "DeleteSourceSnapshot" -ScriptBlock {
                Invoke-DeleteProfileSnapshot -SnapshotGrid $script:Controls.dgSourceSnapshots
            }
        })
    }
    if ($script:Controls['btnDeleteDestSnapshot']) {
        $script:Controls.btnDeleteDestSnapshot.Add_Click({
            Invoke-SafeEventHandler -HandlerName "DeleteDestSnapshot" -ScriptBlock {
                Invoke-DeleteProfileSnapshot -SnapshotGrid $script:Controls.dgDestSnapshots
            }
        })
    }

    # DataGrid selection changed events for delete button enabling
    if ($script:Controls['dgSourceSnapshots']) {
        $script:Controls.dgSourceSnapshots.Add_SelectionChanged({
            Invoke-SafeEventHandler -HandlerName "SourceSnapshotSelection" -ScriptBlock {
                $script:Controls.btnDeleteSourceSnapshot.IsEnabled = ($null -ne $script:Controls.dgSourceSnapshots.SelectedItem)
            }
        })
    }
    if ($script:Controls['dgDestSnapshots']) {
        $script:Controls.dgDestSnapshots.Add_SelectionChanged({
            Invoke-SafeEventHandler -HandlerName "DestSnapshotSelection" -ScriptBlock {
                $script:Controls.btnDeleteDestSnapshot.IsEnabled = ($null -ne $script:Controls.dgDestSnapshots.SelectedItem)
            }
        })
    }
    $script:Controls.cmbScanMode.Add_SelectionChanged({
        Invoke-SafeEventHandler -HandlerName "ScanMode" -ScriptBlock {
            # Enable/disable MaxDepth based on scan mode (Flat needs it, Smart doesn't)
            $isFlat = $script:Controls.cmbScanMode.Text -eq "Flat"
            $script:Controls.txtMaxDepth.IsEnabled = $isFlat
            $script:Controls.txtMaxDepth.Opacity = if ($isFlat) { 1.0 } else { 0.5 }
            Save-ProfileFromForm
        }
    })

    # Settings panel event handlers
    # Slider ValueChanged - sync text displays
    if ($script:Controls['sldSettingsJobs']) {
        $script:Controls.sldSettingsJobs.Add_ValueChanged({
            Invoke-SafeEventHandler -HandlerName "SettingsJobsSlider" -ScriptBlock {
                if ($script:Controls['txtSettingsJobs']) {
                    $script:Controls.txtSettingsJobs.Text = [int]$script:Controls.sldSettingsJobs.Value
                }
            }
        })
    }
    if ($script:Controls['sldSettingsThreads']) {
        $script:Controls.sldSettingsThreads.Add_ValueChanged({
            Invoke-SafeEventHandler -HandlerName "SettingsThreadsSlider" -ScriptBlock {
                if ($script:Controls['txtSettingsThreads']) {
                    $script:Controls.txtSettingsThreads.Text = [int]$script:Controls.sldSettingsThreads.Value
                }
            }
        })
    }

    # Browse buttons
    if ($script:Controls['btnSettingsLogBrowse']) {
        $script:Controls.btnSettingsLogBrowse.Add_Click({
            Invoke-SafeEventHandler -HandlerName "SettingsLogBrowse" -ScriptBlock {
                $path = Show-FolderBrowser -Description "Select log folder"
                if ($path -and $script:Controls['txtSettingsLogPath']) {
                    $script:Controls.txtSettingsLogPath.Text = $path
                }
            }
        })
    }
    if ($script:Controls['btnSettingsSiemBrowse']) {
        $script:Controls.btnSettingsSiemBrowse.Add_Click({
            Invoke-SafeEventHandler -HandlerName "SettingsSiemBrowse" -ScriptBlock {
                $path = Show-FolderBrowser -Description "Select SIEM log folder"
                if ($path -and $script:Controls['txtSettingsSiemPath']) {
                    $script:Controls.txtSettingsSiemPath.Text = $path
                }
            }
        })
    }

    # Snapshot Retention validation
    if ($script:Controls['txtVolumeOverrides']) {
        $script:Controls.txtVolumeOverrides.Add_LostFocus({
            Invoke-SafeEventHandler -HandlerName "VolumeOverridesValidation" -ScriptBlock {
                $text = $script:Controls.txtVolumeOverrides.Text
                if (-not (Test-VolumeOverridesFormat -Text $text)) {
                    $script:Controls.txtVolumeOverrides.BorderBrush = [System.Windows.Media.Brushes]::OrangeRed
                    $script:Controls.txtVolumeOverrides.ToolTip = "Invalid format. Use: D:=5, E:=10"
                }
                else {
                    $script:Controls.txtVolumeOverrides.BorderBrush = [System.Windows.Media.Brushes]::Gray
                    $script:Controls.txtVolumeOverrides.ToolTip = "Per-volume retention counts (e.g., D:=5, E:=10)"
                    Save-SettingsFromForm
                }
            }
        })
    }

    if ($script:Controls['txtDefaultKeepCount']) {
        $script:Controls.txtDefaultKeepCount.Add_LostFocus({
            Invoke-SafeEventHandler -HandlerName "DefaultKeepCountValidation" -ScriptBlock {
                $text = $script:Controls.txtDefaultKeepCount.Text.Trim()
                $count = 0
                if (-not [int]::TryParse($text, [ref]$count) -or $count -lt 0 -or $count -gt 100) {
                    $script:Controls.txtDefaultKeepCount.BorderBrush = [System.Windows.Media.Brushes]::OrangeRed
                    $script:Controls.txtDefaultKeepCount.ToolTip = "Enter a number between 0 and 100"
                }
                else {
                    $script:Controls.txtDefaultKeepCount.BorderBrush = [System.Windows.Media.Brushes]::Gray
                    $script:Controls.txtDefaultKeepCount.ToolTip = "Number of snapshots to retain per volume (default)"
                    Save-SettingsFromForm
                }
            }
        })
    }

    # Save and Revert buttons
    if ($script:Controls['btnSettingsSave']) {
        $script:Controls.btnSettingsSave.Add_Click({
            Invoke-SafeEventHandler -HandlerName "SettingsSave" -ScriptBlock { Save-SettingsFromForm }
        })
    }
    if ($script:Controls['btnSettingsRevert']) {
        $script:Controls.btnSettingsRevert.Add_Click({
            Invoke-SafeEventHandler -HandlerName "SettingsRevert" -ScriptBlock { Import-SettingsToForm }
        })
    }

    # Schedule button (reuses existing handler from main panel)
    if ($script:Controls['btnSettingsSchedule']) {
        $script:Controls.btnSettingsSchedule.Add_Click({
            Invoke-SafeEventHandler -HandlerName "SettingsSchedule" -ScriptBlock { Show-ScheduleDialog }
        })
    }

    # Set Credentials button
    if ($script:Controls['btnSettingsSetCredential']) {
        $script:Controls.btnSettingsSetCredential.Add_Click({
            Invoke-SafeEventHandler -HandlerName "SettingsSetCredential" -ScriptBlock { Show-CredentialInputDialog }
        })
    }

    # Context menu - Retry chunk
    if ($script:Controls['miRetryChunk']) {
        $script:Controls.miRetryChunk.Add_Click({
            Invoke-SafeEventHandler -HandlerName "RetryChunk" -ScriptBlock {
                $selectedItem = $script:Controls.dgChunks.SelectedItem
                if ($selectedItem -and $selectedItem.Status -eq 'Failed') {
                    Invoke-ChunkRetry -ChunkId $selectedItem.ChunkId
                }
            }
        })
    }

    # Context menu - Skip chunk
    if ($script:Controls['miSkipChunk']) {
        $script:Controls.miSkipChunk.Add_Click({
            Invoke-SafeEventHandler -HandlerName "SkipChunk" -ScriptBlock {
                $selectedItem = $script:Controls.dgChunks.SelectedItem
                if ($selectedItem -and $selectedItem.Status -eq 'Failed') {
                    Invoke-ChunkSkip -ChunkId $selectedItem.ChunkId
                }
            }
        })
    }

    # Context menu - Open log file
    if ($script:Controls['miOpenLog']) {
        $script:Controls.miOpenLog.Add_Click({
            Invoke-SafeEventHandler -HandlerName "OpenChunkLog" -ScriptBlock {
                $selectedItem = $script:Controls.dgChunks.SelectedItem
                if ($selectedItem -and $selectedItem.LogPath) {
                    Open-ChunkLog -LogPath $selectedItem.LogPath
                }
            }
        })
    }

    # Context menu - Opening event (enable/disable items based on selection)
    if ($script:Controls['cmChunks']) {
        $script:Controls.cmChunks.Add_Opened({
            Invoke-SafeEventHandler -HandlerName "ChunkContextMenuOpened" -ScriptBlock {
                $selectedItem = $script:Controls.dgChunks.SelectedItem

                # Enable retry/skip only for failed chunks
                $isFailed = $selectedItem -and $selectedItem.Status -eq 'Failed'
                if ($script:Controls['miRetryChunk']) {
                    $script:Controls.miRetryChunk.IsEnabled = $isFailed
                }
                if ($script:Controls['miSkipChunk']) {
                    $script:Controls.miSkipChunk.IsEnabled = $isFailed
                }

                # Enable Open Log only if log path is available
                $hasLog = $selectedItem -and -not [string]::IsNullOrWhiteSpace($selectedItem.LogPath)
                if ($script:Controls['miOpenLog']) {
                    $script:Controls.miOpenLog.IsEnabled = $hasLog
                }
            }
        })
    }

    # Window closing
    $script:Window.Add_Closing({
        Invoke-SafeEventHandler -HandlerName "WindowClosing" -ScriptBlock {
            Invoke-WindowClosingHandler -EventArgs $args[1]
        }
    })
}

function Invoke-WindowClosingHandler {
    <#
    .SYNOPSIS
        Handles the window closing event
    .DESCRIPTION
        Prompts for confirmation if replication is in progress,
        stops jobs if confirmed, cleans up resources, and saves config.
    .PARAMETER EventArgs
        The CancelEventArgs from the Closing event
    #>
    [CmdletBinding()]
    param($EventArgs)

    # Check if replication is running and confirm exit
    if ($script:OrchestrationState -and $script:OrchestrationState.Phase -eq 'Replicating') {
        $confirmed = Show-ConfirmDialog -Title "Confirm Exit" -Message "Replication is in progress. Stop and exit?" -ConfirmText "Exit" -CancelText "Cancel"
        if (-not $confirmed) {
            $EventArgs.Cancel = $true
            return
        }
        Stop-AllJobs
    }

    # Stop the progress timer to prevent memory leaks
    if ($script:ProgressTimer) {
        $script:ProgressTimer.Stop()
        $script:ProgressTimer = $null
    }

    # Close the log window if open
    Close-LogWindow

    # Clean up background runspace to prevent memory leaks
    Close-ReplicationRunspace

    # Save configuration
    $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
    if (-not $saveResult.Success) {
        Write-GuiLog "Warning: Failed to save config on exit: $($saveResult.ErrorMessage)"
    }
}

function Write-GuiLog {
    <#
    .SYNOPSIS
        Writes a message to the GUI log buffer and console
    .DESCRIPTION
        Uses a fixed-size ring buffer to prevent O(n²) string concatenation
        performance issues. When the buffer exceeds GuiLogMaxLines, oldest
        entries are removed. This keeps the GUI responsive during long runs.
        Also writes to console for debugging visibility with caller info.

        The log is displayed in a separate popup log window (see GuiLogWindow.ps1).
    .PARAMETER Message
        Message to log
    .NOTES
        Log content is stored in $script:GuiLogBuffer and displayed in the
        separate log window when opened via the "Logs" button.
    #>
    [CmdletBinding()]
    param([string]$Message)

    # Get caller information from call stack for console output
    $callStack = Get-PSCallStack
    $callerInfo = ""
    if ($callStack.Count -gt 1) {
        $caller = $callStack[1]
        $functionName = if ($caller.FunctionName -and $caller.FunctionName -ne '<ScriptBlock>') {
            $caller.FunctionName
        } else {
            'Main'
        }
        $lineNumber = $caller.ScriptLineNumber
        $callerInfo = "[GUI] [${functionName}:${lineNumber}]"
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $shortTimestamp = Get-Date -Format "HH:mm:ss"

    # Console gets full format with caller info
    $consoleLine = "${timestamp} [INFO] ${callerInfo} ${Message}"
    Write-Host $consoleLine

    # GUI log gets shorter format (no caller info - too verbose for UI)
    $guiLine = "[$shortTimestamp] $Message"

    # Thread-safe buffer update using lock
    [System.Threading.Monitor]::Enter($script:GuiLogBuffer)
    try {
        # Add to ring buffer
        $script:GuiLogBuffer.Add($guiLine)

        # Trim if over limit (remove oldest entries)
        while ($script:GuiLogBuffer.Count -gt $script:GuiLogMaxLines) {
            $script:GuiLogBuffer.RemoveAt(0)
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:GuiLogBuffer)
    }

    # Update the log window if it's visible
    Update-LogWindowContent

    # Update inline log panel if visible
    if ($script:Controls['txtLogContent'] -and $script:ActivePanel -eq 'Logs') {
        Update-InlineLogContent
    }
}

function Show-GuiError {
    <#
    .SYNOPSIS
        Displays an error message in the GUI
    .PARAMETER Message
        Error message
    .PARAMETER Details
        Detailed error information
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$Details
    )

    $fullMessage = $Message
    if ($Details) {
        $fullMessage += "`n`nDetails: $Details"
    }

    Show-AlertDialog -Title "Error" -Message $fullMessage -Icon 'Error'

    Write-GuiLog "ERROR: $Message"
}

function Invoke-KeyboardShortcut {
    <#
    .SYNOPSIS
        Handles keyboard shortcuts for the GUI
    .DESCRIPTION
        Processes keyboard shortcuts and invokes the appropriate actions.
        Returns $true if the shortcut was handled, $false otherwise.
    .PARAMETER Key
        The key that was pressed (e.g., 'L', 'R', 'Escape', 'D1', 'NumPad1')
    .PARAMETER Ctrl
        Whether the Ctrl modifier key is pressed
    .PARAMETER IsTextBoxFocused
        Whether a TextBox control currently has focus
    .OUTPUTS
        Boolean - $true if shortcut was handled, $false otherwise
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [bool]$Ctrl,

        [Parameter(Mandatory)]
        [bool]$IsTextBoxFocused
    )

    # Ctrl+L: Open log popup (always works)
    if ($Ctrl -and $Key -eq 'L') {
        Show-LogWindow
        return $true
    }

    # Ctrl+R: Run selected (if enabled)
    if ($Ctrl -and $Key -eq 'R') {
        if ($script:Controls['btnRunSelected'].IsEnabled) {
            Start-GuiReplication -SelectedOnly
        }
        return $true
    }

    # Escape: Stop (if running)
    if ($Key -eq 'Escape') {
        if ($script:Controls['btnStop'].IsEnabled) {
            Request-Stop
        }
        return $true
    }

    # 1-4: Switch panels (if not in TextBox)
    if (-not $Ctrl -and -not $IsTextBoxFocused) {
        $panel = Get-PanelForKey -Key $Key
        if ($panel) {
            Set-ActivePanel -PanelName $panel
            return $true
        }
    }

    return $false
}

function Get-PanelForKey {
    <#
    .SYNOPSIS
        Maps a key to a panel name
    .DESCRIPTION
        Returns the panel name for number keys 1-4 and NumPad1-4.
        Returns $null if the key doesn't map to a panel.
    .PARAMETER Key
        The key name (e.g., 'D1', 'D2', 'NumPad1', etc.)
    .OUTPUTS
        String - Panel name ('Profiles', 'Settings', 'Progress', 'Logs') or $null
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Key
    )

    switch ($Key) {
        { $_ -in @('D1', 'NumPad1') } { return 'Profiles' }
        { $_ -in @('D2', 'NumPad2') } { return 'Settings' }
        { $_ -in @('D3', 'NumPad3') } { return 'Progress' }
        { $_ -in @('D4', 'NumPad4') } { return 'Logs' }
        { $_ -in @('D5', 'NumPad5') } { return 'Snapshots' }
        default { return $null }
    }
}
