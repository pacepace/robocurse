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
        if ($script:Controls -and $state.SelectedProfile -and $script:Controls.lstProfiles) {
            $profileToSelect = $script:Controls.lstProfiles.Items | Where-Object { $_.Name -eq $state.SelectedProfile }
            if ($profileToSelect) {
                $script:Controls.lstProfiles.SelectedItem = $profileToSelect
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
    $script:ConfigPath = $ConfigPath

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

    # Initialize progress timer
    $script:ProgressTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ProgressTimer.Interval = [TimeSpan]::FromMilliseconds(500)
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

    # Stop and dispose the progress timer to prevent memory leaks
    if ($script:ProgressTimer) {
        $script:ProgressTimer.Stop()
        # DispatcherTimer doesn't implement IDisposable, but we should null the reference
        # to allow the event handler closure to be garbage collected
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
    .OUTPUTS
        PSCustomObject with PowerShell, Handle, and Runspace properties
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject[]]$Profiles,

        [Parameter(Mandatory)]
        [int]$MaxWorkers
    )

    # Get the path to this script for dot-sourcing into the runspace
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = Join-Path (Get-Location) "Robocurse.ps1"
    }

    $runspace = [runspacefactory]::CreateRunspace()
    # Use MTA for background I/O work (STA is only needed for COM/UI operations)
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace

    # Build a script that loads the main script and runs replication
    # Note: We pass the C# OrchestrationState object which is inherently thread-safe
    # Callbacks are intentionally NOT shared - GUI uses timer-based polling instead
    $backgroundScript = @"
        param(`$ScriptPath, `$SharedState, `$Profiles, `$MaxWorkers, `$ConfigPath)

        # Load the script to get all functions (with -Help to prevent main execution)
        . `$ScriptPath -Help

        # Use the shared C# OrchestrationState instance (thread-safe by design)
        `$script:OrchestrationState = `$SharedState

        # Clear callbacks - GUI mode uses timer-based polling, not callbacks
        `$script:OnProgress = `$null
        `$script:OnChunkComplete = `$null
        `$script:OnProfileComplete = `$null

        # Start replication with -SkipInitialization since UI thread already initialized
        Start-ReplicationRun -Profiles `$Profiles -MaxConcurrentJobs `$MaxWorkers -SkipInitialization

        # Run the orchestration loop until complete
        while (`$script:OrchestrationState.Phase -notin @('Complete', 'Stopped', 'Idle')) {
            Invoke-ReplicationTick -MaxConcurrentJobs `$MaxWorkers
            Start-Sleep -Milliseconds 250
        }
"@

    $powershell.AddScript($backgroundScript)
    $powershell.AddArgument($scriptPath)
    $powershell.AddArgument($script:OrchestrationState)
    $powershell.AddArgument($Profiles)
    $powershell.AddArgument($MaxWorkers)
    $powershell.AddArgument($script:ConfigPath)

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

    # Get and validate profiles
    $profilesToRun = Get-ProfilesToRun -AllProfiles:$AllProfiles -SelectedOnly:$SelectedOnly
    if (-not $profilesToRun) { return }

    # Update UI state for replication mode
    $script:Controls.btnRunAll.IsEnabled = $false
    $script:Controls.btnRunSelected.IsEnabled = $false
    $script:Controls.btnStop.IsEnabled = $true
    $script:Controls.txtStatus.Text = "Replication in progress..."
    $script:LastGuiUpdateState = $null
    $script:Controls.dgChunks.ItemsSource = $null

    Write-GuiLog "Starting replication with $($profilesToRun.Count) profile(s)"

    # Get worker count and start progress timer
    $maxWorkers = [int]$script:Controls.sldWorkers.Value
    $script:ProgressTimer.Start()

    # Initialize orchestration state (must happen before runspace creation)
    Initialize-OrchestrationState

    # Create and start background runspace
    $runspaceInfo = New-ReplicationRunspace -Profiles $profilesToRun -MaxWorkers $maxWorkers

    $script:ReplicationHandle = $runspaceInfo.Handle
    $script:ReplicationPowerShell = $runspaceInfo.PowerShell
    $script:ReplicationRunspace = $runspaceInfo.Runspace
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

    # Update status
    $script:Controls.txtStatus.Text = "Replication complete"

    # Show completion message
    $status = Get-OrchestrationStatus
    $message = "Replication completed!`n`nChunks: $($status.ChunksComplete)/$($status.ChunksTotal)`nFailed: $($status.ChunksFailed)"

    [System.Windows.MessageBox]::Show(
        $message,
        "Replication Complete",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    )

    Write-GuiLog "Replication completed: $($status.ChunksComplete)/$($status.ChunksTotal) chunks, $($status.ChunksFailed) failed"
}

# Cache for GUI progress updates - avoids unnecessary rebuilds
$script:LastGuiUpdateState = $null

function Update-GuiProgressText {
    <#
    .SYNOPSIS
        Updates the progress text labels from status object
    .PARAMETER Status
        Orchestration status object from Get-OrchestrationStatus
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Status
    )

    # Update progress bars
    $script:Controls.pbProfile.Value = $Status.ProfileProgress
    $script:Controls.pbOverall.Value = $Status.OverallProgress

    # Update text labels
    $profileName = if ($Status.CurrentProfile) { $Status.CurrentProfile } else { "--" }
    $script:Controls.txtProfileProgress.Text = "Profile: $profileName - $($Status.ProfileProgress)%"
    $script:Controls.txtOverallProgress.Text = "Overall: $($Status.OverallProgress)%"

    # Update ETA
    $script:Controls.txtEta.Text = if ($Status.ETA) {
        "ETA: $($Status.ETA.ToString('hh\:mm\:ss'))"
    } else {
        "ETA: --:--:--"
    }

    # Update speed (bytes per second from elapsed time)
    $script:Controls.txtSpeed.Text = if ($Status.Elapsed.TotalSeconds -gt 0 -and $Status.BytesComplete -gt 0) {
        $speed = $Status.BytesComplete / $Status.Elapsed.TotalSeconds
        "Speed: $(Format-FileSize $speed)/s"
    } else {
        "Speed: -- MB/s"
    }

    $script:Controls.txtChunks.Text = "Chunks: $($Status.ChunksComplete)/$($Status.ChunksTotal)"
}

function Get-ChunkDisplayItems {
    <#
    .SYNOPSIS
        Builds the chunk display items list for the GUI grid
    .DESCRIPTION
        Creates display objects from active, failed, and completed chunks.
        Limits completed chunks to last 20 to prevent UI lag.
    .PARAMETER MaxCompletedItems
        Maximum number of completed chunks to display (default 20)
    .OUTPUTS
        Array of display objects for DataGrid binding
    #>
    [CmdletBinding()]
    param(
        [int]$MaxCompletedItems = $script:GuiMaxCompletedChunksDisplay
    )

    $chunkDisplayItems = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Add active jobs (typically small - MaxConcurrentJobs)
    foreach ($kvp in $script:OrchestrationState.ActiveJobs.ToArray()) {
        $job = $kvp.Value
        $chunkDisplayItems.Add([PSCustomObject]@{
            ChunkId = $job.Chunk.ChunkId
            SourcePath = $job.Chunk.SourcePath
            Status = "Running"
            Progress = if ($job.Progress) { $job.Progress } else { 0 }
            Speed = "--"
        })
    }

    # Add failed chunks (show all - usually small or indicates problems)
    foreach ($chunk in $script:OrchestrationState.FailedChunks.ToArray()) {
        $chunkDisplayItems.Add([PSCustomObject]@{
            ChunkId = $chunk.ChunkId
            SourcePath = $chunk.SourcePath
            Status = "Failed"
            Progress = 0
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
            Speed = "--"
        })
    }

    return $chunkDisplayItems.ToArray()
}

function Test-ChunkGridNeedsRebuild {
    <#
    .SYNOPSIS
        Determines if the chunk grid needs to be rebuilt
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

        # Update progress text (always - lightweight)
        Update-GuiProgressText -Status $status

        # Dequeue and display any pending error messages from background thread
        if ($script:OrchestrationState) {
            $errors = $script:OrchestrationState.DequeueErrors()
            foreach ($err in $errors) {
                Write-GuiLog "[ERROR] $err"
            }
        }

        # Update chunk grid - only when state changes
        if ($script:OrchestrationState -and (Test-ChunkGridNeedsRebuild)) {
            $script:Controls.dgChunks.ItemsSource = Get-ChunkDisplayItems
        }

        # Check if complete
        if ($status.Phase -eq 'Complete') {
            Complete-GuiReplication
        }
    }
    catch {
        Write-GuiLog "Error updating progress: $_"
    }
}

# GUI Log ring buffer (uses $script:GuiLogMaxLines from constants)
$script:GuiLogBuffer = [System.Collections.Generic.List[string]]::new()
$script:GuiLogDirty = $false  # Track if buffer needs to be flushed to UI

function Write-GuiLog {
    <#
    .SYNOPSIS
        Writes a message to the GUI log panel using a ring buffer
    .DESCRIPTION
        Uses a fixed-size ring buffer to prevent O(n²) string concatenation
        performance issues. When the buffer exceeds GuiLogMaxLines, oldest
        entries are removed. This keeps the GUI responsive during long runs.
    .PARAMETER Message
        Message to log
    #>
    [CmdletBinding()]
    param([string]$Message)

    if (-not $script:Controls.txtLog) { return }

    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $Message"

    # Add to ring buffer
    $script:GuiLogBuffer.Add($line)

    # Trim if over limit (remove oldest entries)
    while ($script:GuiLogBuffer.Count -gt $script:GuiLogMaxLines) {
        $script:GuiLogBuffer.RemoveAt(0)
    }

    # Use Dispatcher.BeginInvoke for thread safety - non-blocking async update
    # Using Invoke (synchronous) could cause deadlocks if called from background thread
    # while UI thread is busy
    $logText = $script:GuiLogBuffer -join "`n"
    [void]$script:Window.Dispatcher.BeginInvoke([Action]{
        $script:Controls.txtLog.Text = $logText
        $script:Controls.svLog.ScrollToEnd()
    })
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
