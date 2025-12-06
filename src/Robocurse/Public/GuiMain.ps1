# Robocurse GUI Main
# Core window initialization, event wiring, and logging functions.

# GUI Log ring buffer (uses $script:GuiLogMaxLines from constants)
$script:GuiLogBuffer = [System.Collections.Generic.List[string]]::new()
$script:GuiLogDirty = $false  # Track if buffer needs to be flushed to UI

# Error tracking for visual indicator
$script:GuiErrorCount = 0  # Count of errors encountered during current run

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
        'chkUseVss', 'cmbScanMode', 'txtMaxSize', 'txtMaxFiles', 'txtMaxDepth',
        'sldWorkers', 'txtWorkerCount', 'btnRunAll', 'btnRunSelected', 'btnStop', 'btnSchedule', 'btnLogs',
        'dgChunks', 'pbProfile', 'pbOverall', 'txtProfileProgress', 'txtOverallProgress',
        'txtEta', 'txtSpeed', 'txtChunks', 'txtStatus'
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
    $script:ProgressTimer.Interval = $script:GuiProgressUpdateIntervalMs
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

    # Logs button - opens popup log viewer window
    $script:Controls.btnLogs.Add_Click({
        Invoke-SafeEventHandler -HandlerName "Logs" -ScriptBlock { Show-LogWindow }
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
