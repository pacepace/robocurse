# Robocurse Gui Functions
# XAML resources are stored in the Resources folder for maintainability.
# The Get-XamlResource function loads them at runtime with fallback to embedded content.

function Get-XamlResource {
    <#
    .SYNOPSIS
        Loads XAML content from a resource file or falls back to embedded content
    .PARAMETER ResourceName
        Name of the XAML resource file (without path)
    .PARAMETER FallbackContent
        Optional embedded XAML content to use if file not found
    .OUTPUTS
        XAML string content
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceName,

        [string]$FallbackContent
    )

    # Try to load from Resources folder
    $resourcePath = Join-Path $PSScriptRoot "..\Resources\$ResourceName"
    if (Test-Path $resourcePath) {
        try {
            return Get-Content -Path $resourcePath -Raw -ErrorAction Stop
        }
        catch {
            Write-Verbose "Failed to load XAML resource '$ResourceName': $_"
        }
    }

    # Fall back to embedded content if provided
    if ($FallbackContent) {
        return $FallbackContent
    }

    throw "XAML resource '$ResourceName' not found and no fallback provided"
}

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
        PSCustomObject with saved state or $null if not found
    #>
    [CmdletBinding()]
    param()

    $settingsPath = Get-GuiSettingsPath
    if (-not (Test-Path $settingsPath)) {
        return $null
    }

    try {
        $json = Get-Content -Path $settingsPath -Raw -ErrorAction Stop
        return $json | ConvertFrom-Json
    }
    catch {
        Write-Verbose "Failed to load GUI settings: $_"
        return $null
    }
}

function Save-GuiState {
    <#
    .SYNOPSIS
        Saves GUI state to settings file
    .PARAMETER Window
        WPF Window object
    .PARAMETER WorkerCount
        Current worker slider value
    .PARAMETER SelectedProfileName
        Name of currently selected profile
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Window]$Window,

        [int]$WorkerCount,

        [string]$SelectedProfileName
    )

    try {
        $state = [PSCustomObject]@{
            WindowLeft = $Window.Left
            WindowTop = $Window.Top
            WindowWidth = $Window.Width
            WindowHeight = $Window.Height
            WindowState = $Window.WindowState.ToString()
            WorkerCount = $WorkerCount
            SelectedProfile = $SelectedProfileName
            SavedAt = [datetime]::Now.ToString('o')
        }

        $settingsPath = Get-GuiSettingsPath
        $state | ConvertTo-Json -Depth 3 | Set-Content -Path $settingsPath -Encoding UTF8 -ErrorAction Stop
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

        if ($state.WindowWidth -gt 0 -and $state.WindowHeight -gt 0) {
            $Window.Width = $state.WindowWidth
            $Window.Height = $state.WindowHeight
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

        Write-Verbose "GUI state restored"
    }
    catch {
        Write-Verbose "Failed to restore GUI settings: $_"
    }
}

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
    $script:Controls = @{}
    @(
        'lstProfiles', 'btnAddProfile', 'btnRemoveProfile',
        'txtProfileName', 'txtSource', 'txtDest', 'btnBrowseSource', 'btnBrowseDest',
        'chkUseVss', 'cmbScanMode', 'txtMaxSize', 'txtMaxFiles', 'txtMaxDepth',
        'sldWorkers', 'txtWorkerCount', 'btnRunAll', 'btnRunSelected', 'btnStop', 'btnSchedule',
        'dgChunks', 'pbProfile', 'pbOverall', 'txtProfileProgress', 'txtOverallProgress',
        'txtEta', 'txtSpeed', 'txtChunks', 'txtStatus', 'txtLog', 'svLog'
    ) | ForEach-Object {
        $script:Controls[$_] = $script:Window.FindName($_)
    }

    # Wire up event handlers
    Initialize-EventHandlers

    # Load config and populate UI
    $script:Config = Get-RobocurseConfig -Path $script:ConfigPath
    Update-ProfileList

    # Restore saved GUI state (window position, size, worker count, selected profile)
    Restore-GuiState -Window $script:Window

    # Save GUI state on window close
    $script:Window.Add_Closing({
        $selectedProfile = $script:Controls.lstProfiles.SelectedItem
        $selectedName = if ($selectedProfile) { $selectedProfile.Name } else { $null }
        $workerCount = [int]$script:Controls.sldWorkers.Value

        Save-GuiState -Window $script:Window -WorkerCount $workerCount -SelectedProfileName $selectedName
    })

    # Initialize progress timer - use Forms.Timer instead of DispatcherTimer
    # Forms.Timer uses Windows message queue (WM_TIMER) which is more reliable in PowerShell
    # than WPF's DispatcherTimer which gets starved during background runspace operations
    $script:ProgressTimer = New-Object System.Windows.Forms.Timer
    $script:ProgressTimer.Interval = 250  # Forms.Timer uses int milliseconds
    $script:ProgressTimer.Add_Tick({ Update-GuiProgress })

    Write-GuiLog "Robocurse GUI initialized"

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
            $selected = $script:Controls.lstProfiles.SelectedItem
            if ($selected) {
                Import-ProfileToForm -Profile $selected
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
            if ($path) { $script:Controls.txtSource.Text = $path }
        }
    })
    $script:Controls.btnBrowseDest.Add_Click({
        Invoke-SafeEventHandler -HandlerName "BrowseDest" -ScriptBlock {
            $path = Show-FolderBrowser -Description "Select destination folder"
            if ($path) { $script:Controls.txtDest.Text = $path }
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

    # Schedule button
    $script:Controls.btnSchedule.Add_Click({
        Invoke-SafeEventHandler -HandlerName "Schedule" -ScriptBlock { Show-ScheduleDialog }
    })

    # Form field changes - save to profile
    @('txtProfileName', 'txtSource', 'txtDest', 'txtMaxSize', 'txtMaxFiles', 'txtMaxDepth') | ForEach-Object {
        $script:Controls[$_].Add_LostFocus({
            Invoke-SafeEventHandler -HandlerName "SaveProfile" -ScriptBlock { Save-ProfileFromForm }
        })
    }

    # Numeric input validation - reject non-numeric characters in real-time
    # This provides immediate feedback before the user finishes typing
    @('txtMaxSize', 'txtMaxFiles', 'txtMaxDepth') | ForEach-Object {
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
    $script:Controls.cmbScanMode.Add_SelectionChanged({
        Invoke-SafeEventHandler -HandlerName "ScanMode" -ScriptBlock { Save-ProfileFromForm }
    })

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
        $result = [System.Windows.MessageBox]::Show(
            "Replication is in progress. Stop and exit?",
            "Confirm Exit",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($result -eq 'No') {
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

    # Clean up background runspace to prevent memory leaks
    Close-ReplicationRunspace

    # Save configuration
    $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
    if (-not $saveResult.Success) {
        Write-GuiLog "Warning: Failed to save config on exit: $($saveResult.ErrorMessage)"
    }
}

function Close-ReplicationRunspace {
    <#
    .SYNOPSIS
        Cleans up the background replication runspace
    .DESCRIPTION
        Safely stops and disposes the PowerShell instance and runspace
        used for background replication. Called during window close
        and when replication completes.

        Uses Interlocked.Exchange for atomic capture-and-clear to prevent
        race conditions when multiple threads attempt cleanup simultaneously
        (e.g., window close + completion handler firing at the same time).
    #>
    [CmdletBinding()]
    param()

    # Early exit if nothing to clean up
    if (-not $script:ReplicationPowerShell) { return }

    # Atomically capture and clear the PowerShell instance reference
    # Interlocked.Exchange ensures only ONE thread gets the reference;
    # all other threads will get $null and exit early
    $psInstance = [System.Threading.Interlocked]::Exchange([ref]$script:ReplicationPowerShell, $null)
    $handle = [System.Threading.Interlocked]::Exchange([ref]$script:ReplicationHandle, $null)
    $runspace = [System.Threading.Interlocked]::Exchange([ref]$script:ReplicationRunspace, $null)

    # If another thread already claimed the instance, exit
    if (-not $psInstance) { return }

    try {
        # Stop the PowerShell instance if still running
        if ($handle -and -not $handle.IsCompleted) {
            try {
                $psInstance.Stop()
            }
            catch [System.Management.Automation.PipelineStoppedException] {
                # Expected when pipeline is already stopped
            }
            catch [System.ObjectDisposedException] {
                # Already disposed by another thread
                return
            }
        }

        # Close and dispose the runspace
        if ($psInstance.Runspace) {
            try {
                $psInstance.Runspace.Close()
                $psInstance.Runspace.Dispose()
            }
            catch [System.ObjectDisposedException] {
                # Already disposed
            }
        }

        # Dispose the PowerShell instance
        try {
            $psInstance.Dispose()
        }
        catch [System.ObjectDisposedException] {
            # Already disposed
        }
    }
    catch {
        # Silently ignore cleanup errors during window close
        Write-Verbose "Runspace cleanup error (ignored): $($_.Exception.Message)"
    }
}

function Update-ProfileList {
    <#
    .SYNOPSIS
        Populates the profile listbox from config
    #>
    [CmdletBinding()]
    param()

    $script:Controls.lstProfiles.Items.Clear()

    if ($script:Config.SyncProfiles) {
        foreach ($profile in $script:Config.SyncProfiles) {
            $script:Controls.lstProfiles.Items.Add($profile) | Out-Null
        }
    }

    # Select first profile if available
    if ($script:Controls.lstProfiles.Items.Count -gt 0) {
        $script:Controls.lstProfiles.SelectedIndex = 0
    }
}

function Import-ProfileToForm {
    <#
    .SYNOPSIS
        Imports selected profile data into form fields
    .PARAMETER Profile
        Profile object to import
    #>
    [CmdletBinding()]
    param([PSCustomObject]$Profile)

    # Guard against null profile
    if ($null -eq $Profile) { return }

    # Load basic properties with null safety
    $script:Controls.txtProfileName.Text = if ($Profile.Name) { $Profile.Name } else { "" }
    $script:Controls.txtSource.Text = if ($Profile.Source) { $Profile.Source } else { "" }
    $script:Controls.txtDest.Text = if ($Profile.Destination) { $Profile.Destination } else { "" }
    $script:Controls.chkUseVss.IsChecked = if ($null -ne $Profile.UseVSS) { $Profile.UseVSS } else { $false }

    # Set scan mode
    $scanMode = if ($Profile.ScanMode) { $Profile.ScanMode } else { "Smart" }
    $script:Controls.cmbScanMode.SelectedIndex = if ($scanMode -eq "Quick") { 1 } else { 0 }

    # Load chunk settings with defaults for missing properties
    $maxSize = if ($null -ne $Profile.ChunkMaxSizeGB) { $Profile.ChunkMaxSizeGB } else { 10 }
    $maxFiles = if ($null -ne $Profile.ChunkMaxFiles) { $Profile.ChunkMaxFiles } else { 50000 }
    $maxDepth = if ($null -ne $Profile.ChunkMaxDepth) { $Profile.ChunkMaxDepth } else { 5 }

    $script:Controls.txtMaxSize.Text = $maxSize.ToString()
    $script:Controls.txtMaxFiles.Text = $maxFiles.ToString()
    $script:Controls.txtMaxDepth.Text = $maxDepth.ToString()
}

function Save-ProfileFromForm {
    <#
    .SYNOPSIS
        Saves form fields back to selected profile
    #>
    [CmdletBinding()]
    param()

    $selected = $script:Controls.lstProfiles.SelectedItem
    if (-not $selected) { return }

    # Update profile object
    $selected.Name = $script:Controls.txtProfileName.Text
    $selected.Source = $script:Controls.txtSource.Text
    $selected.Destination = $script:Controls.txtDest.Text
    $selected.UseVSS = $script:Controls.chkUseVss.IsChecked
    $selected.ScanMode = $script:Controls.cmbScanMode.Text

    # Parse numeric values with validation and bounds checking
    # Helper function to provide visual feedback for input corrections
    $showInputCorrected = {
        param($control, $originalValue, $correctedValue, $fieldName)
        $control.Text = $correctedValue.ToString()
        $control.ToolTip = "Value '$originalValue' was corrected to '$correctedValue'"
        # Flash the background briefly to indicate correction (uses existing theme colors)
        $originalBg = $control.Background
        $control.Background = [System.Windows.Media.Brushes]::DarkOrange
        # Reset after 1.5 seconds using a dispatcher timer
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(1500)
        $timer.Add_Tick({
            $control.Background = $originalBg
            $control.ToolTip = $null
            $this.Stop()
        })
        $timer.Start()
        Write-GuiLog "Input corrected: $fieldName '$originalValue' -> '$correctedValue'"
    }

    # ChunkMaxSizeGB: valid range 1-1000 GB
    try {
        $value = [int]$script:Controls.txtMaxSize.Text
        $selected.ChunkMaxSizeGB = [Math]::Max(1, [Math]::Min(1000, $value))
        if ($value -ne $selected.ChunkMaxSizeGB) {
            & $showInputCorrected $script:Controls.txtMaxSize $value $selected.ChunkMaxSizeGB "Max Size (GB)"
        }
    } catch {
        $originalText = $script:Controls.txtMaxSize.Text
        $selected.ChunkMaxSizeGB = 10
        & $showInputCorrected $script:Controls.txtMaxSize $originalText 10 "Max Size (GB)"
    }

    # ChunkMaxFiles: valid range 1000-10000000
    try {
        $value = [int]$script:Controls.txtMaxFiles.Text
        $selected.ChunkMaxFiles = [Math]::Max(1000, [Math]::Min(10000000, $value))
        if ($value -ne $selected.ChunkMaxFiles) {
            & $showInputCorrected $script:Controls.txtMaxFiles $value $selected.ChunkMaxFiles "Max Files"
        }
    } catch {
        $originalText = $script:Controls.txtMaxFiles.Text
        $selected.ChunkMaxFiles = 50000
        & $showInputCorrected $script:Controls.txtMaxFiles $originalText 50000 "Max Files"
    }

    # ChunkMaxDepth: valid range 1-20
    try {
        $value = [int]$script:Controls.txtMaxDepth.Text
        $selected.ChunkMaxDepth = [Math]::Max(1, [Math]::Min(20, $value))
        if ($value -ne $selected.ChunkMaxDepth) {
            & $showInputCorrected $script:Controls.txtMaxDepth $value $selected.ChunkMaxDepth "Max Depth"
        }
    } catch {
        $originalText = $script:Controls.txtMaxDepth.Text
        $selected.ChunkMaxDepth = 5
        & $showInputCorrected $script:Controls.txtMaxDepth $originalText 5 "Max Depth"
    }

    # Refresh list display
    $script:Controls.lstProfiles.Items.Refresh()

    # Auto-save config to disk
    $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
    if (-not $saveResult.Success) {
        Write-GuiLog "Warning: Auto-save failed: $($saveResult.ErrorMessage)"
    }
}

function Add-NewProfile {
    <#
    .SYNOPSIS
        Creates a new profile with defaults
    #>
    [CmdletBinding()]
    param()

    $newProfile = [PSCustomObject]@{
        Name = "New Profile"
        Source = ""
        Destination = ""
        Enabled = $true
        UseVSS = $false
        ScanMode = "Smart"
        ChunkMaxSizeGB = 10
        ChunkMaxFiles = 50000
        ChunkMaxDepth = 5
    }

    # Add to config
    if (-not $script:Config.SyncProfiles) {
        $script:Config.SyncProfiles = @()
    }
    $script:Config.SyncProfiles += $newProfile

    # Update UI
    Update-ProfileList
    $script:Controls.lstProfiles.SelectedIndex = $script:Controls.lstProfiles.Items.Count - 1

    # Auto-save config to disk
    $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
    if (-not $saveResult.Success) {
        Write-GuiLog "Warning: Auto-save failed: $($saveResult.ErrorMessage)"
    }

    Write-GuiLog "New profile created"
}

function Remove-SelectedProfile {
    <#
    .SYNOPSIS
        Removes selected profile with confirmation
    #>
    [CmdletBinding()]
    param()

    $selected = $script:Controls.lstProfiles.SelectedItem
    if (-not $selected) {
        [System.Windows.MessageBox]::Show(
            "Please select a profile to remove.",
            "No Selection",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        return
    }

    $result = [System.Windows.MessageBox]::Show(
        "Remove profile '$($selected.Name)'?",
        "Confirm Removal",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )

    if ($result -eq 'Yes') {
        $script:Config.SyncProfiles = @($script:Config.SyncProfiles | Where-Object { $_ -ne $selected })
        Update-ProfileList

        # Auto-save config to disk
        $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
        if (-not $saveResult.Success) {
            Write-GuiLog "Warning: Auto-save failed: $($saveResult.ErrorMessage)"
        }

        Write-GuiLog "Profile '$($selected.Name)' removed"
    }
}

function Show-FolderBrowser {
    <#
    .SYNOPSIS
        Opens folder browser dialog
    .PARAMETER Description
        Dialog description
    .OUTPUTS
        Selected path or $null
    #>
    [CmdletBinding()]
    param([string]$Description = "Select folder")

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }
    return $null
}

function Get-ProfilesToRun {
    <#
    .SYNOPSIS
        Determines which profiles to run based on selection mode
    .PARAMETER AllProfiles
        Include all enabled profiles
    .PARAMETER SelectedOnly
        Include only the currently selected profile
    .OUTPUTS
        Array of profile objects, or $null if validation fails
    #>
    [CmdletBinding()]
    param(
        [switch]$AllProfiles,
        [switch]$SelectedOnly
    )

    $profilesToRun = @()

    if ($AllProfiles) {
        $profilesToRun = @($script:Config.SyncProfiles | Where-Object { $_.Enabled -eq $true })
        if ($profilesToRun.Count -eq 0) {
            Show-GuiError -Message "No enabled profiles found. Please enable at least one profile."
            return $null
        }
    }
    elseif ($SelectedOnly) {
        $selected = $script:Controls.lstProfiles.SelectedItem
        if (-not $selected) {
            Show-GuiError -Message "No profile selected. Please select a profile to run."
            return $null
        }
        $profilesToRun = @($selected)
    }

    # Validate profiles have required paths
    foreach ($profile in $profilesToRun) {
        if ([string]::IsNullOrWhiteSpace($profile.Source) -or [string]::IsNullOrWhiteSpace($profile.Destination)) {
            Show-GuiError -Message "Profile '$($profile.Name)' has invalid source or destination paths."
            return $null
        }
    }

    return $profilesToRun
}

function New-ReplicationRunspace {
    <#
    .SYNOPSIS
        Creates and configures a background runspace for replication
    .PARAMETER Profiles
        Array of profiles to run
    .PARAMETER MaxWorkers
        Maximum concurrent robocopy jobs
    .PARAMETER ConfigPath
        Path to config file (can be a snapshot for isolation from external changes)
    .OUTPUTS
        PSCustomObject with PowerShell, Handle, and Runspace properties
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject[]]$Profiles,

        [Parameter(Mandatory)]
        [int]$MaxWorkers,

        [string]$ConfigPath = $script:ConfigPath
    )

    # Determine how to load Robocurse in the background runspace
    # Two modes: 1) Module mode (Import-Module), 2) Monolith mode (dot-source script)
    $loadMode = $null
    $loadPath = $null

    # Check if we're running from a module (RobocurseModulePath is set by psm1)
    if ($script:RobocurseModulePath -and (Test-Path (Join-Path $script:RobocurseModulePath "Robocurse.psd1"))) {
        $loadMode = "Module"
        $loadPath = $script:RobocurseModulePath
    }
    # Check if we have a stored script path (set by monolith)
    elseif ($script:RobocurseScriptPath -and (Test-Path $script:RobocurseScriptPath)) {
        $loadMode = "Script"
        $loadPath = $script:RobocurseScriptPath
    }
    # Try PSCommandPath (works when running as standalone script)
    elseif ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        $loadMode = "Script"
        $loadPath = $PSCommandPath
    }
    # Fall back to looking for Robocurse.ps1 in current directory
    else {
        $fallbackPath = Join-Path (Get-Location) "Robocurse.ps1"
        if (Test-Path $fallbackPath) {
            $loadMode = "Script"
            $loadPath = $fallbackPath
        }
    }

    if (-not $loadMode -or -not $loadPath) {
        $errorMsg = "Cannot find Robocurse module or script to load in background runspace. loadPath='$loadPath'"
        Write-Host "[ERROR] $errorMsg"
        Write-GuiLog "ERROR: $errorMsg"
        throw $errorMsg
    }

    $runspace = [runspacefactory]::CreateRunspace()
    # Use MTA for background I/O work (STA is only needed for COM/UI operations)
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace

    # Build a script that loads Robocurse and runs replication
    # Note: We pass the C# OrchestrationState object which is inherently thread-safe
    # Callbacks are intentionally NOT shared - GUI uses timer-based polling instead
    if ($loadMode -eq "Module") {
        # NOTE: We pass ProfileNames (strings) instead of Profile objects because
        # PSCustomObject properties don't reliably survive runspace boundaries.
        # See CLAUDE.md for details on this pattern.
        $backgroundScript = @"
            param(`$ModulePath, `$SharedState, `$ProfileNames, `$MaxWorkers, `$ConfigPath)

            try {
                Write-Host "[BACKGROUND] Loading module from: `$ModulePath"
                Import-Module `$ModulePath -Force -ErrorAction Stop
                Write-Host "[BACKGROUND] Module loaded successfully"
            }
            catch {
                Write-Host "[BACKGROUND] ERROR loading module: `$(`$_.Exception.Message)"
                `$SharedState.EnqueueError("Failed to load module: `$(`$_.Exception.Message)")
                `$SharedState.Phase = 'Complete'
                return
            }

            # Initialize logging session (required for Write-RobocurseLog)
            try {
                Write-Host "[BACKGROUND] Initializing log session..."
                `$config = Get-RobocurseConfig -Path `$ConfigPath
                `$logRoot = if (`$config.GlobalSettings.LogPath) { `$config.GlobalSettings.LogPath } else { '.\Logs' }
                # Resolve relative paths based on config file directory and normalize
                if (-not [System.IO.Path]::IsPathRooted(`$logRoot)) {
                    `$configDir = Split-Path -Parent `$ConfigPath
                    `$logRoot = [System.IO.Path]::GetFullPath((Join-Path `$configDir `$logRoot))
                }
                Write-Host "[BACKGROUND] Log root: `$logRoot"
                Initialize-LogSession -LogRoot `$logRoot
                Write-Host "[BACKGROUND] Log session initialized"
            }
            catch {
                Write-Host "[BACKGROUND] WARNING: Failed to initialize logging: `$(`$_.Exception.Message)"
                # Continue anyway - logging is not critical for replication
            }

            # Use the shared C# OrchestrationState instance (thread-safe by design)
            `$script:OrchestrationState = `$SharedState

            # Clear callbacks - GUI mode uses timer-based polling, not callbacks
            `$script:OnProgress = `$null
            `$script:OnChunkComplete = `$null
            `$script:OnProfileComplete = `$null

            try {
                Write-Host "[BACKGROUND] Starting replication run"
                # Re-read config to get fresh profile data with all properties intact
                # (PSCustomObject properties don't survive runspace boundaries - see CLAUDE.md)
                `$bgConfig = Get-RobocurseConfig -Path `$ConfigPath
                `$verboseLogging = [bool]`$bgConfig.GlobalSettings.VerboseFileLogging

                # Look up profiles by name from freshly-loaded config
                `$profiles = @(`$bgConfig.SyncProfiles | Where-Object { `$ProfileNames -contains `$_.Name })
                Write-Host "[BACKGROUND] Loaded `$(`$profiles.Count) profile(s) from config"

                # Start replication with -SkipInitialization since UI thread already initialized
                Start-ReplicationRun -Profiles `$profiles -MaxConcurrentJobs `$MaxWorkers -SkipInitialization -VerboseFileLogging:`$verboseLogging

                # Run the orchestration loop until complete
                while (`$script:OrchestrationState.Phase -notin @('Complete', 'Stopped', 'Idle')) {
                    Invoke-ReplicationTick -MaxConcurrentJobs `$MaxWorkers
                    Start-Sleep -Milliseconds 250
                }
                Write-Host "[BACKGROUND] Replication loop complete, phase: `$(`$script:OrchestrationState.Phase)"
            }
            catch {
                Write-Host "[BACKGROUND] ERROR in replication: `$(`$_.Exception.Message)"
                `$SharedState.EnqueueError("Replication error: `$(`$_.Exception.Message)")
                `$SharedState.Phase = 'Complete'
            }
"@
    }
    else {
        # Script/monolith mode
        # NOTE: We use $GuiConfigPath (not $ConfigPath) because dot-sourcing the script
        # would shadow our parameter with the script's own $ConfigPath parameter
        # NOTE: We pass ProfileNames (strings) instead of Profile objects for consistency
        # with module mode. See CLAUDE.md for the pattern.
        $backgroundScript = @"
            param(`$ScriptPath, `$SharedState, `$ProfileNames, `$MaxWorkers, `$GuiConfigPath)

            try {
                Write-Host "[BACKGROUND] Loading script from: `$ScriptPath"
                Write-Host "[BACKGROUND] Config path: `$GuiConfigPath"
                # Load the script to get all functions (with -LoadOnly to prevent main execution)
                . `$ScriptPath -LoadOnly
                Write-Host "[BACKGROUND] Script loaded successfully"
            }
            catch {
                Write-Host "[BACKGROUND] ERROR loading script: `$(`$_.Exception.Message)"
                `$SharedState.EnqueueError("Failed to load script: `$(`$_.Exception.Message)")
                `$SharedState.Phase = 'Complete'
                return
            }

            # Initialize logging session (required for Write-RobocurseLog)
            try {
                Write-Host "[BACKGROUND] Initializing log session..."
                `$config = Get-RobocurseConfig -Path `$GuiConfigPath
                `$logRoot = if (`$config.GlobalSettings.LogPath) { `$config.GlobalSettings.LogPath } else { '.\Logs' }
                # Resolve relative paths based on config file directory and normalize
                if (-not [System.IO.Path]::IsPathRooted(`$logRoot)) {
                    `$configDir = Split-Path -Parent `$GuiConfigPath
                    `$logRoot = [System.IO.Path]::GetFullPath((Join-Path `$configDir `$logRoot))
                }
                Write-Host "[BACKGROUND] Log root: `$logRoot"
                Initialize-LogSession -LogRoot `$logRoot
                Write-Host "[BACKGROUND] Log session initialized"
            }
            catch {
                Write-Host "[BACKGROUND] WARNING: Failed to initialize logging: `$(`$_.Exception.Message)"
                # Continue anyway - logging is not critical for replication
            }

            # Use the shared C# OrchestrationState instance (thread-safe by design)
            `$script:OrchestrationState = `$SharedState

            # Clear callbacks - GUI mode uses timer-based polling, not callbacks
            `$script:OnProgress = `$null
            `$script:OnChunkComplete = `$null
            `$script:OnProfileComplete = `$null

            try {
                Write-Host "[BACKGROUND] Starting replication run"
                # Re-read config to get fresh profile data (see CLAUDE.md for pattern)
                `$bgConfig = Get-RobocurseConfig -Path `$GuiConfigPath
                `$verboseLogging = [bool]`$bgConfig.GlobalSettings.VerboseFileLogging

                # Look up profiles by name from freshly-loaded config
                `$profiles = @(`$bgConfig.SyncProfiles | Where-Object { `$ProfileNames -contains `$_.Name })
                Write-Host "[BACKGROUND] Loaded `$(`$profiles.Count) profile(s) from config"

                # Start replication with -SkipInitialization since UI thread already initialized
                Start-ReplicationRun -Profiles `$profiles -MaxConcurrentJobs `$MaxWorkers -SkipInitialization -VerboseFileLogging:`$verboseLogging

                # Run the orchestration loop until complete
                while (`$script:OrchestrationState.Phase -notin @('Complete', 'Stopped', 'Idle')) {
                    Invoke-ReplicationTick -MaxConcurrentJobs `$MaxWorkers
                    Start-Sleep -Milliseconds 250
                }
                Write-Host "[BACKGROUND] Replication loop complete, phase: `$(`$script:OrchestrationState.Phase)"
            }
            catch {
                Write-Host "[BACKGROUND] ERROR in replication: `$(`$_.Exception.Message)"
                `$SharedState.EnqueueError("Replication error: `$(`$_.Exception.Message)")
                `$SharedState.Phase = 'Complete'
            }
"@
    }

    $powershell.AddScript($backgroundScript)
    $powershell.AddArgument($loadPath)
    $powershell.AddArgument($script:OrchestrationState)
    # Pass profile names (strings) - background will look up from config (see CLAUDE.md)
    $profileNames = @($Profiles | ForEach-Object { $_.Name })
    $powershell.AddArgument($profileNames)
    $powershell.AddArgument($MaxWorkers)
    # Use the provided ConfigPath (may be a snapshot for isolation from external changes)
    $powershell.AddArgument($ConfigPath)

    $handle = $powershell.BeginInvoke()

    return [PSCustomObject]@{
        PowerShell = $powershell
        Handle = $handle
        Runspace = $runspace
    }
}

function Start-GuiReplication {
    <#
    .SYNOPSIS
        Starts replication from GUI
    .PARAMETER AllProfiles
        Run all enabled profiles
    .PARAMETER SelectedOnly
        Run only selected profile
    #>
    [CmdletBinding()]
    param(
        [switch]$AllProfiles,
        [switch]$SelectedOnly
    )

    # Save any pending form changes before reading profiles
    # This ensures changes like chunk size are captured even if user clicks Run
    # without first clicking elsewhere to trigger LostFocus
    Save-ProfileFromForm

    # Get and validate profiles (force array context to handle PowerShell's single-item unwrapping)
    $profilesToRun = @(Get-ProfilesToRun -AllProfiles:$AllProfiles -SelectedOnly:$SelectedOnly)
    if ($profilesToRun.Count -eq 0) { return }

    # Update UI state for replication mode
    $script:Controls.btnRunAll.IsEnabled = $false
    $script:Controls.btnRunSelected.IsEnabled = $false
    $script:Controls.btnStop.IsEnabled = $true
    $script:Controls.txtStatus.Text = "Replication in progress..."
    $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::Gray  # Reset error color
    $script:GuiErrorCount = 0  # Reset error count for new run
    $script:LastGuiUpdateState = $null
    $script:Controls.dgChunks.ItemsSource = $null

    Write-GuiLog "Starting replication with $($profilesToRun.Count) profile(s)"

    # Get worker count and start progress timer
    $maxWorkers = [int]$script:Controls.sldWorkers.Value
    $script:ProgressTimer.Start()

    # Initialize orchestration state (must happen before runspace creation)
    Initialize-OrchestrationState

    # Create a snapshot of the config to prevent external modifications during replication
    # This ensures the running replication uses the config state at the time of start
    $script:ConfigSnapshotPath = $null
    try {
        $snapshotDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
        $script:ConfigSnapshotPath = Join-Path $snapshotDir "Robocurse-ConfigSnapshot-$([Guid]::NewGuid().ToString('N')).json"
        Copy-Item -Path $script:ConfigPath -Destination $script:ConfigSnapshotPath -Force
        Write-GuiLog "Config snapshot created for replication run"
    }
    catch {
        Write-GuiLog "Warning: Could not create config snapshot, using live config: $($_.Exception.Message)"
        $script:ConfigSnapshotPath = $script:ConfigPath  # Fall back to original
    }

    # Create and start background runspace (using snapshot path)
    try {
        $runspaceInfo = New-ReplicationRunspace -Profiles $profilesToRun -MaxWorkers $maxWorkers -ConfigPath $script:ConfigSnapshotPath

        $script:ReplicationHandle = $runspaceInfo.Handle
        $script:ReplicationPowerShell = $runspaceInfo.PowerShell
        $script:ReplicationRunspace = $runspaceInfo.Runspace
    }
    catch {
        Write-Host "[ERROR] Failed to create background runspace: $($_.Exception.Message)"
        Write-GuiLog "ERROR: Failed to start replication: $($_.Exception.Message)"
        # Reset UI state
        $script:Controls.btnRunAll.IsEnabled = $true
        $script:Controls.btnRunSelected.IsEnabled = $true
        $script:Controls.btnStop.IsEnabled = $false
        $script:Controls.txtStatus.Text = "Ready"
        $script:ProgressTimer.Stop()
    }
}

function Show-CompletionDialog {
    <#
    .SYNOPSIS
        Shows a modern completion dialog with replication statistics
    .PARAMETER ChunksComplete
        Number of chunks completed successfully
    .PARAMETER ChunksTotal
        Total number of chunks
    .PARAMETER ChunksFailed
        Number of chunks that failed
    #>
    [CmdletBinding()]
    param(
        [int]$ChunksComplete = 0,
        [int]$ChunksTotal = 0,
        [int]$ChunksFailed = 0
    )

    try {
        # Load XAML from resource file
        $xaml = Get-XamlResource -ResourceName 'CompletionDialog.xaml'
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()

        # Get controls
        $iconBorder = $dialog.FindName("iconBorder")
        $iconText = $dialog.FindName("iconText")
        $txtTitle = $dialog.FindName("txtTitle")
        $txtSubtitle = $dialog.FindName("txtSubtitle")
        $txtChunksValue = $dialog.FindName("txtChunksValue")
        $txtTotalValue = $dialog.FindName("txtTotalValue")
        $txtFailedValue = $dialog.FindName("txtFailedValue")
        $btnOk = $dialog.FindName("btnOk")

        # Set values
        $txtChunksValue.Text = $ChunksComplete.ToString()
        $txtTotalValue.Text = $ChunksTotal.ToString()
        $txtFailedValue.Text = $ChunksFailed.ToString()

        # Adjust appearance based on results
        if ($ChunksFailed -gt 0) {
            # Some failures - show warning state
            $iconBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF9800")
            $iconText.Text = [char]0x26A0  # Warning triangle
            $txtTitle.Text = "Replication Complete with Warnings"
            $txtSubtitle.Text = "$ChunksFailed chunk(s) failed"
            $txtFailedValue.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF9800")
        }
        elseif ($ChunksComplete -eq 0 -and $ChunksTotal -eq 0) {
            # Nothing to do
            $txtTitle.Text = "Replication Complete"
            $txtSubtitle.Text = "No chunks to process"
        }
        else {
            # All success
            $txtTitle.Text = "Replication Complete"
            $txtSubtitle.Text = "All tasks finished successfully"
        }

        # OK button handler
        $btnOk.Add_Click({
            $dialog.DialogResult = $true
            $dialog.Close()
        })

        # Allow dragging the window
        $dialog.Add_MouseLeftButtonDown({
            param($sender, $e)
            if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
                $dialog.DragMove()
            }
        })

        # Set owner to main window for proper modal behavior
        $dialog.Owner = $script:Window
        $dialog.ShowDialog() | Out-Null
    }
    catch {
        Write-GuiLog "Error showing completion dialog: $($_.Exception.Message)"
        # Fallback to simple message
        [System.Windows.MessageBox]::Show(
            "Replication completed!`n`nChunks: $ChunksComplete/$ChunksTotal`nFailed: $ChunksFailed",
            "Replication Complete",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
    }
}

function Complete-GuiReplication {
    <#
    .SYNOPSIS
        Called when replication completes
    .DESCRIPTION
        Handles GUI cleanup after replication: stops timer, re-enables buttons,
        disposes of background runspace resources, and shows completion message.
    #>
    [CmdletBinding()]
    param()

    # Stop timer
    $script:ProgressTimer.Stop()

    # Dispose of background runspace resources to prevent memory leaks
    if ($script:ReplicationPowerShell) {
        try {
            # End the async invocation if still running
            if ($script:ReplicationHandle -and -not $script:ReplicationHandle.IsCompleted) {
                $script:ReplicationPowerShell.Stop()
            }
            elseif ($script:ReplicationHandle) {
                # Collect any remaining output
                $script:ReplicationPowerShell.EndInvoke($script:ReplicationHandle) | Out-Null
            }

            # Check for errors from the background runspace and surface them
            if ($script:ReplicationPowerShell.HadErrors) {
                Write-GuiLog "Background replication encountered errors:"
                foreach ($err in $script:ReplicationPowerShell.Streams.Error) {
                    $errorLocation = if ($err.InvocationInfo) {
                        "$($err.InvocationInfo.ScriptName):$($err.InvocationInfo.ScriptLineNumber)"
                    } else { "Unknown" }
                    Write-GuiLog "  [$errorLocation] $($err.Exception.Message)"
                }
            }

            # Dispose the runspace
            if ($script:ReplicationPowerShell.Runspace) {
                $script:ReplicationPowerShell.Runspace.Close()
                $script:ReplicationPowerShell.Runspace.Dispose()
            }

            # Dispose the PowerShell instance
            $script:ReplicationPowerShell.Dispose()
        }
        catch {
            Write-GuiLog "Warning: Error disposing runspace: $($_.Exception.Message)"
        }
        finally {
            $script:ReplicationPowerShell = $null
            $script:ReplicationHandle = $null
            $script:ReplicationRunspace = $null  # Clear runspace reference for GC
        }
    }

    # Re-enable buttons
    $script:Controls.btnRunAll.IsEnabled = $true
    $script:Controls.btnRunSelected.IsEnabled = $true
    $script:Controls.btnStop.IsEnabled = $false

    # Update status with error indicator if applicable
    if ($script:GuiErrorCount -gt 0) {
        $script:Controls.txtStatus.Text = "Replication complete ($($script:GuiErrorCount) error(s))"
        $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::OrangeRed
    } else {
        $script:Controls.txtStatus.Text = "Replication complete"
        $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::LimeGreen
    }

    # Show completion message
    $status = Get-OrchestrationStatus
    Show-CompletionDialog -ChunksComplete $status.ChunksComplete -ChunksTotal $status.ChunksTotal -ChunksFailed $status.ChunksFailed

    Write-GuiLog "Replication completed: $($status.ChunksComplete)/$($status.ChunksTotal) chunks, $($status.ChunksFailed) failed"

    # Clean up config snapshot if it was created
    if ($script:ConfigSnapshotPath -and ($script:ConfigSnapshotPath -ne $script:ConfigPath)) {
        try {
            if (Test-Path $script:ConfigSnapshotPath) {
                Remove-Item $script:ConfigSnapshotPath -Force -ErrorAction SilentlyContinue
                Write-GuiLog "Config snapshot cleaned up"
            }
        }
        catch {
            # Non-critical - temp files will be cleaned up eventually
        }
        $script:ConfigSnapshotPath = $null
    }
}

# Cache for GUI progress updates - avoids unnecessary rebuilds
$script:LastGuiUpdateState = $null

function Update-GuiProgressText {
    <#
    .SYNOPSIS
        Updates the progress text labels from status object
    .PARAMETER Status
        Orchestration status object from Get-OrchestrationStatus
    .NOTES
        WPF RENDERING QUIRK: In PowerShell, WPF controls don't reliably repaint when
        properties change via data binding or Dispatcher.BeginInvoke. The solution is:
        1. Direct property assignment (not Dispatcher calls)
        2. Call Window.UpdateLayout() to force a complete layout pass
        This forces WPF to recalculate and repaint all controls.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Status
    )

    # Capture values for use in script block
    $profileProgress = $Status.ProfileProgress
    $overallProgress = $Status.OverallProgress
    $profileName = if ($Status.CurrentProfile) { $Status.CurrentProfile } else { "--" }
    $etaText = if ($Status.ETA) { "ETA: $($Status.ETA.ToString('hh\:mm\:ss'))" } else { "ETA: --:--:--" }

    $speedText = if ($Status.Elapsed.TotalSeconds -gt 0 -and $Status.BytesComplete -gt 0) {
        $speed = $Status.BytesComplete / $Status.Elapsed.TotalSeconds
        "Speed: $(Format-FileSize $speed)/s"
    } else {
        "Speed: -- MB/s"
    }
    $chunksText = "Chunks: $($Status.ChunksComplete)/$($Status.ChunksTotal)"

    # Direct assignment
    $script:Controls.pbProfile.Value = $profileProgress
    $script:Controls.pbOverall.Value = $overallProgress
    $script:Controls.txtProfileProgress.Text = "Profile: $profileName - $profileProgress%"
    $script:Controls.txtOverallProgress.Text = "Overall: $overallProgress%"
    $script:Controls.txtEta.Text = $etaText
    $script:Controls.txtSpeed.Text = $speedText
    $script:Controls.txtChunks.Text = $chunksText

    # Force complete window layout update
    $script:Window.UpdateLayout()
}

function Get-ChunkDisplayItems {
    <#
    .SYNOPSIS
        Builds the chunk display items list for the GUI grid
    .DESCRIPTION
        Creates display objects from active, failed, and completed chunks.
        Limits completed chunks to last 20 to prevent UI lag.

        Each display item includes:
        - ChunkId, SourcePath, Status, Speed: Standard display properties
        - Progress: 0-100 percentage for text display
        - ProgressScale: 0.0-1.0 for ScaleTransform binding (see NOTES)
    .PARAMETER MaxCompletedItems
        Maximum number of completed chunks to display (default 20)
    .OUTPUTS
        Array of display objects for DataGrid binding
    .NOTES
        WPF PROGRESSBAR QUIRK: The standard WPF ProgressBar control doesn't reliably
        render in PowerShell even when Value property is correctly set. Neither
        Dispatcher.Invoke nor direct property assignment fixes this.

        SOLUTION: Use a custom progress bar built from Border elements with ScaleTransform.
        - Background Border (gray) provides the track
        - Fill Border (green) scales horizontally via ScaleTransform.ScaleX binding
        - ProgressScale (0.0-1.0) maps directly to ScaleX for smooth scaling

        This approach bypasses ProgressBar entirely and works reliably in PowerShell WPF.
    #>
    [CmdletBinding()]
    param(
        [int]$MaxCompletedItems = $script:GuiMaxCompletedChunksDisplay
    )

    $chunkDisplayItems = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Add active jobs (typically small - MaxConcurrentJobs)
    foreach ($kvp in $script:OrchestrationState.ActiveJobs.ToArray()) {
        $job = $kvp.Value

        # Get actual progress from robocopy log parsing
        $progress = 0
        $speed = "--"
        try {
            $progressData = Get-RobocopyProgress -Job $job
            if ($progressData) {
                # Calculate percentage from bytes copied vs estimated chunk size
                if ($job.Chunk.EstimatedSize -gt 0 -and $progressData.BytesCopied -gt 0) {
                    $progress = [math]::Min(100, [math]::Round(($progressData.BytesCopied / $job.Chunk.EstimatedSize) * 100, 0))
                }
                # Use parsed speed if available
                if ($progressData.Speed) {
                    $speed = $progressData.Speed
                }
            }
        }
        catch {
            # Progress parsing failure - use defaults
        }

        $chunkDisplayItems.Add([PSCustomObject]@{
            ChunkId = $job.Chunk.ChunkId
            SourcePath = $job.Chunk.SourcePath
            Status = "Running"
            Progress = $progress
            ProgressScale = [double]($progress / 100)  # 0.0 to 1.0 for ScaleTransform
            Speed = $speed
        })
    }

    # Add failed chunks (show all - usually small or indicates problems)
    foreach ($chunk in $script:OrchestrationState.FailedChunks.ToArray()) {
        $chunkDisplayItems.Add([PSCustomObject]@{
            ChunkId = $chunk.ChunkId
            SourcePath = $chunk.SourcePath
            Status = "Failed"
            Progress = 0
            ProgressScale = [double]0.0
            Speed = "--"
        })
    }

    # Add completed chunks - limit to last N to prevent UI lag
    $completedSnapshot = $script:OrchestrationState.CompletedChunks.ToArray()
    $startIndex = [Math]::Max(0, $completedSnapshot.Length - $MaxCompletedItems)
    for ($i = $startIndex; $i -lt $completedSnapshot.Length; $i++) {
        $chunk = $completedSnapshot[$i]
        $chunkDisplayItems.Add([PSCustomObject]@{
            ChunkId = $chunk.ChunkId
            SourcePath = $chunk.SourcePath
            Status = "Complete"
            Progress = 100
            ProgressScale = [double]1.0  # Full scale for completed
            Speed = "--"
        })
    }

    return $chunkDisplayItems.ToArray()
}

function Test-ChunkGridNeedsRebuild {
    <#
    .SYNOPSIS
        Determines if the chunk grid needs to be rebuilt
    .DESCRIPTION
        Returns true when:
        - First call (no previous state)
        - Active/completed/failed counts changed
        - There are active jobs (progress values change continuously)

        The last condition is important because PSCustomObject doesn't implement
        INotifyPropertyChanged, so WPF won't see property changes. We must rebuild
        the entire ItemsSource to show updated progress values.
    .OUTPUTS
        $true if grid needs rebuild, $false otherwise
    #>
    [CmdletBinding()]
    param()

    $currentState = @{
        ActiveCount = $script:OrchestrationState.ActiveJobs.Count
        CompletedCount = $script:OrchestrationState.CompletedCount
        FailedCount = $script:OrchestrationState.FailedChunks.Count
    }

    $needsRebuild = $false
    if (-not $script:LastGuiUpdateState) {
        $needsRebuild = $true
    }
    elseif ($script:LastGuiUpdateState.ActiveCount -ne $currentState.ActiveCount -or
            $script:LastGuiUpdateState.CompletedCount -ne $currentState.CompletedCount -or
            $script:LastGuiUpdateState.FailedCount -ne $currentState.FailedCount) {
        $needsRebuild = $true
    }
    elseif ($currentState.ActiveCount -gt 0) {
        # Always refresh when there are active jobs since their progress/speed is constantly changing
        $needsRebuild = $true
    }

    if ($needsRebuild) {
        $script:LastGuiUpdateState = $currentState
    }

    return $needsRebuild
}

function Update-GuiProgress {
    <#
    .SYNOPSIS
        Called by timer to update GUI from orchestration state
    .DESCRIPTION
        Optimized for performance with large chunk counts:
        - Only rebuilds display list when chunk counts change
        - Uses efficient ToArray() snapshot for thread-safe iteration
        - Limits displayed items to prevent UI sluggishness
        - Dequeues and displays real-time error messages from background thread
    #>
    [CmdletBinding()]
    param()

    try {
        $status = Get-OrchestrationStatus

        # Debug: Log phase and state every tick (throttled to every 10th tick to reduce noise)
        # Using Write-Host because GUI thread doesn't have log session initialized
        if (-not $script:GuiTickCount) { $script:GuiTickCount = 0 }
        $script:GuiTickCount++
        if ($script:GuiTickCount % 10 -eq 0) {
            Write-Host "[GUI TICK #$($script:GuiTickCount)] Phase=$($status.Phase), Chunks=$($status.ChunksComplete)/$($status.ChunksTotal), ProfilePct=$($status.ProfileProgress)%, OverallPct=$($status.OverallProgress)%, Bytes=$($status.BytesComplete)"
        }

        # Update progress text (always - lightweight)
        Update-GuiProgressText -Status $status

        # Only flush streams when background is complete (avoid blocking)
        if ($script:ReplicationHandle -and $script:ReplicationHandle.IsCompleted) {
            # Flush background runspace output streams to console
            if ($script:ReplicationPowerShell -and $script:ReplicationPowerShell.Streams) {
                foreach ($info in $script:ReplicationPowerShell.Streams.Information) {
                    Write-Host "[BACKGROUND] $($info.MessageData)"
                }
                $script:ReplicationPowerShell.Streams.Information.Clear()

                foreach ($warn in $script:ReplicationPowerShell.Streams.Warning) {
                    Write-Host "[BACKGROUND WARNING] $warn" -ForegroundColor Yellow
                }
                $script:ReplicationPowerShell.Streams.Warning.Clear()

                foreach ($err in $script:ReplicationPowerShell.Streams.Error) {
                    Write-Host "[BACKGROUND ERROR] $($err.Exception.Message)" -ForegroundColor Red
                }
                $script:ReplicationPowerShell.Streams.Error.Clear()
            }
        }

        # Dequeue errors (thread-safe) and update error indicator
        if ($script:OrchestrationState) {
            $errors = $script:OrchestrationState.DequeueErrors()
            foreach ($err in $errors) {
                Write-GuiLog "[ERROR] $err"
                $script:GuiErrorCount++
            }

            # Update status bar with error indicator if errors occurred
            if ($script:GuiErrorCount -gt 0) {
                $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::OrangeRed
                $script:Controls.txtStatus.Text = "Replication in progress... ($($script:GuiErrorCount) error(s))"
            }
        }

        # Update chunk grid - when state changes or jobs have progress updates
        if ($script:OrchestrationState -and (Test-ChunkGridNeedsRebuild)) {
            $script:Controls.dgChunks.ItemsSource = @(Get-ChunkDisplayItems)
            # Force DataGrid to re-read all bindings (needed for non-INotifyPropertyChanged objects)
            $script:Controls.dgChunks.Items.Refresh()
            # Force visual refresh
            $script:Window.UpdateLayout()
        }

        # Check if complete
        if ($status.Phase -eq 'Complete') {
            Complete-GuiReplication
        }
    }
    catch {
        Write-Host "[ERROR] Error updating progress: $_"
        Write-GuiLog "Error updating progress: $_"
    }
}

# GUI Log ring buffer (uses $script:GuiLogMaxLines from constants)
$script:GuiLogBuffer = [System.Collections.Generic.List[string]]::new()
$script:GuiLogDirty = $false  # Track if buffer needs to be flushed to UI

# Error tracking for visual indicator
$script:GuiErrorCount = 0  # Count of errors encountered during current run

function Write-GuiLog {
    <#
    .SYNOPSIS
        Writes a message to the GUI log panel and console
    .DESCRIPTION
        Uses a fixed-size ring buffer to prevent O(n²) string concatenation
        performance issues. When the buffer exceeds GuiLogMaxLines, oldest
        entries are removed. This keeps the GUI responsive during long runs.
        Also writes to console for debugging visibility with caller info.
    .PARAMETER Message
        Message to log
    .NOTES
        WPF RENDERING QUIRK: Originally used Dispatcher.BeginInvoke for thread safety,
        but this didn't reliably update the TextBox visual in PowerShell WPF.

        SOLUTION: Use direct property assignment + Window.UpdateLayout().
        All Write-GuiLog calls originate from the GUI thread (event handlers and
        Forms.Timer tick which uses WM_TIMER), so Dispatcher isn't needed anyway.
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

    # GUI panel gets shorter format (no caller info - too verbose for UI)
    $guiLine = "[$shortTimestamp] $Message"

    if (-not $script:Controls.txtLog) { return }

    # Thread-safe buffer update using lock
    # Capture logText inside the lock to avoid race between buffer modification and join
    $logText = $null
    [System.Threading.Monitor]::Enter($script:GuiLogBuffer)
    try {
        # Add to ring buffer
        $script:GuiLogBuffer.Add($guiLine)

        # Trim if over limit (remove oldest entries)
        while ($script:GuiLogBuffer.Count -gt $script:GuiLogMaxLines) {
            $script:GuiLogBuffer.RemoveAt(0)
        }

        # Capture text while still holding the lock
        $logText = $script:GuiLogBuffer -join "`n"
    }
    finally {
        [System.Threading.Monitor]::Exit($script:GuiLogBuffer)
    }

    # Direct assignment - all Write-GuiLog calls are from GUI thread
    # (event handlers and timer tick which uses WM_TIMER on UI thread)
    $script:Controls.txtLog.Text = $logText
    $script:Controls.svLog.ScrollToEnd()

    # Force complete window layout update for immediate visual refresh
    $script:Window.UpdateLayout()
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

    [System.Windows.MessageBox]::Show(
        $fullMessage,
        "Error",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )

    Write-GuiLog "ERROR: $Message"
}

function Show-ScheduleDialog {
    <#
    .SYNOPSIS
        Shows schedule configuration dialog and registers/unregisters the scheduled task
    .DESCRIPTION
        Displays a dialog for configuring scheduled runs. When OK is clicked,
        the configuration is saved AND the Windows Task Scheduler task is
        actually created or removed based on the enabled state.
    #>
    [CmdletBinding()]
    param()

    try {
        # Load XAML from resource file
        $xaml = Get-XamlResource -ResourceName 'ScheduleDialog.xaml'
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()

        # Get controls
        $chkEnabled = $dialog.FindName("chkEnabled")
        $txtTime = $dialog.FindName("txtTime")
        $cmbFrequency = $dialog.FindName("cmbFrequency")
        $txtStatus = $dialog.FindName("txtStatus")
        $btnOk = $dialog.FindName("btnOk")
        $btnCancel = $dialog.FindName("btnCancel")

        # Load current settings
        $chkEnabled.IsChecked = $script:Config.Schedule.Enabled
        $txtTime.Text = if ($script:Config.Schedule.Time) { $script:Config.Schedule.Time } else { "02:00" }

        # Add real-time time validation with visual feedback
        $txtTime.Add_TextChanged({
            param($sender, $e)
            $isValid = $false
            $text = $sender.Text
            if ($text -match '^([01]?\d|2[0-3]):([0-5]\d)$') {
                $isValid = $true
            }
            if ($isValid) {
                $sender.BorderBrush = [System.Windows.Media.Brushes]::Gray
                $sender.ToolTip = "Time in 24-hour format (HH:MM)"
            } else {
                $sender.BorderBrush = [System.Windows.Media.Brushes]::Red
                $sender.ToolTip = "Invalid format. Use HH:MM (24-hour, e.g., 02:00, 14:30)"
            }
        })

        # Check current task status
        $taskExists = Test-RobocurseTaskExists
        if ($taskExists) {
            $taskInfo = Get-RobocurseTask
            if ($taskInfo) {
                $txtStatus.Text = "Current task status: $($taskInfo.State)`nNext run: $($taskInfo.NextRunTime)"
            }
        }
        else {
            $txtStatus.Text = "No scheduled task currently configured."
        }

        # Button handlers
        $btnOk.Add_Click({
            try {
                # Parse time
                $timeParts = $txtTime.Text -split ':'
                if ($timeParts.Count -ne 2) {
                    [System.Windows.MessageBox]::Show("Invalid time format. Use HH:MM", "Error", "OK", "Error")
                    return
                }
                $hour = [int]$timeParts[0]
                $minute = [int]$timeParts[1]

                if ($hour -lt 0 -or $hour -gt 23 -or $minute -lt 0 -or $minute -gt 59) {
                    [System.Windows.MessageBox]::Show("Invalid time. Hour must be 0-23, minute must be 0-59", "Error", "OK", "Error")
                    return
                }

                # Determine schedule type
                $scheduleType = switch ($cmbFrequency.Text) {
                    "Daily" { "Daily" }
                    "Weekdays" { "Weekdays" }
                    "Hourly" { "Hourly" }
                    default { "Daily" }
                }

                # Update config
                $script:Config.Schedule.Enabled = $chkEnabled.IsChecked
                $script:Config.Schedule.Time = $txtTime.Text
                $script:Config.Schedule.ScheduleType = $scheduleType

                if ($chkEnabled.IsChecked) {
                    # Register/update the task
                    Write-GuiLog "Registering scheduled task..."

                    $result = Register-RobocurseTask `
                        -ConfigPath $script:ConfigPath `
                        -Schedule $scheduleType `
                        -Time "$($hour.ToString('00')):$($minute.ToString('00'))"

                    if ($result.Success) {
                        Write-GuiLog "Scheduled task registered successfully"
                        [System.Windows.MessageBox]::Show(
                            "Scheduled task has been registered.`n`nThe task will run $scheduleType at $($txtTime.Text).",
                            "Schedule Configured",
                            "OK",
                            "Information"
                        )
                    }
                    else {
                        Write-GuiLog "Failed to register scheduled task: $($result.ErrorMessage)"
                        [System.Windows.MessageBox]::Show(
                            "Failed to register scheduled task.`n$($result.ErrorMessage)",
                            "Error",
                            "OK",
                            "Error"
                        )
                    }
                }
                else {
                    # Remove the task if it exists
                    if ($taskExists) {
                        Write-GuiLog "Removing scheduled task..."
                        $result = Unregister-RobocurseTask
                        if ($result.Success) {
                            Write-GuiLog "Scheduled task removed"
                            [System.Windows.MessageBox]::Show(
                                "Scheduled task has been removed.",
                                "Schedule Disabled",
                                "OK",
                                "Information"
                            )
                        }
                        else {
                            Write-GuiLog "Failed to remove scheduled task: $($result.ErrorMessage)"
                        }
                    }
                }

                $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
                if (-not $saveResult.Success) {
                    Write-GuiLog "Warning: Failed to save config: $($saveResult.ErrorMessage)"
                }
                $dialog.Close()
            }
            catch {
                [System.Windows.MessageBox]::Show(
                    "Error configuring schedule: $($_.Exception.Message)",
                    "Error",
                    "OK",
                    "Error"
                )
                Write-GuiLog "Error configuring schedule: $($_.Exception.Message)"
            }
        })

        $btnCancel.Add_Click({ $dialog.Close() })

        $dialog.ShowDialog() | Out-Null
    }
    catch {
        Show-GuiError -Message "Failed to show schedule dialog" -Details $_.Exception.Message
    }
}
