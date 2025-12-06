# Robocurse GUI Log Window
# Separate popup window for log viewing.

# Log window instance and controls
$script:LogWindow = $null
$script:LogControls = @{}

function Show-LogWindow {
    <#
    .SYNOPSIS
        Shows the log viewer window, creating it if needed
    .DESCRIPTION
        Opens the log viewer as a non-modal window that can stay open
        while the main GUI operates. If already open, brings it to front.
        The window displays log messages from the ring buffer.
    #>
    [CmdletBinding()]
    param()

    # If window exists and is loaded, just bring to front
    if ($script:LogWindow -and $script:LogWindow.IsLoaded) {
        $script:LogWindow.Activate()
        return
    }

    # Create new window
    try {
        $script:LogWindow = Initialize-LogWindow
        if ($script:LogWindow) {
            # Set owner to main window so it stays on top of it
            $script:LogWindow.Owner = $script:Window

            # Show non-modal
            $script:LogWindow.Show()

            # Populate with current buffer contents
            Update-LogWindowContent
        }
    }
    catch {
        Write-GuiLog "Error showing log window: $($_.Exception.Message)"
        Show-GuiError -Message "Failed to open log window" -Details $_.Exception.Message
    }
}

function Initialize-LogWindow {
    <#
    .SYNOPSIS
        Creates and initializes the log viewer window from XAML
    .OUTPUTS
        Window object if successful, $null on failure
    #>
    [CmdletBinding()]
    param()

    try {
        # Load XAML from resource file
        $xaml = Get-XamlResource -ResourceName 'LogWindow.xaml'
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()

        # Get control references
        $script:LogControls = @{}
        @(
            'chkDebug', 'chkInfo', 'chkWarning', 'chkError',
            'chkAutoScroll', 'txtLineCount',
            'svLog', 'txtLog',
            'btnClear', 'btnCopyAll', 'btnSaveLog', 'btnClose'
        ) | ForEach-Object {
            $script:LogControls[$_] = $window.FindName($_)
        }

        # Wire up event handlers
        Initialize-LogWindowEventHandlers -Window $window

        return $window
    }
    catch {
        Write-Warning "Failed to initialize log window: $($_.Exception.Message)"
        return $null
    }
}

function Initialize-LogWindowEventHandlers {
    <#
    .SYNOPSIS
        Wires up event handlers for the log window
    .PARAMETER Window
        The log window object
    #>
    [CmdletBinding()]
    param([System.Windows.Window]$Window)

    # Close button
    $script:LogControls.btnClose.Add_Click({
        $script:LogWindow.Hide()
    })

    # Clear log button
    $script:LogControls.btnClear.Add_Click({
        Clear-GuiLogBuffer
        Update-LogWindowContent
    })

    # Copy all button
    $script:LogControls.btnCopyAll.Add_Click({
        $logText = $script:LogControls.txtLog.Text
        if ($logText) {
            [System.Windows.Clipboard]::SetText($logText)
            # Brief visual feedback
            $originalContent = $script:LogControls.btnCopyAll.Content
            $script:LogControls.btnCopyAll.Content = "Copied!"
            $timer = New-Object System.Windows.Threading.DispatcherTimer
            $timer.Interval = [TimeSpan]::FromSeconds(1)
            $timer.Add_Tick({
                $script:LogControls.btnCopyAll.Content = $originalContent
                $timer.Stop()
            }.GetNewClosure())
            $timer.Start()
        }
    })

    # Save to file button
    $script:LogControls.btnSaveLog.Add_Click({
        try {
            $saveDialog = New-Object Microsoft.Win32.SaveFileDialog
            $saveDialog.Filter = "Log files (*.log)|*.log|Text files (*.txt)|*.txt|All files (*.*)|*.*"
            $saveDialog.DefaultExt = ".log"
            $saveDialog.FileName = "robocurse-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

            if ($saveDialog.ShowDialog() -eq $true) {
                $script:LogControls.txtLog.Text | Set-Content -Path $saveDialog.FileName -Encoding UTF8
                Write-GuiLog "Log saved to: $($saveDialog.FileName)"
            }
        }
        catch {
            Show-GuiError -Message "Failed to save log file" -Details $_.Exception.Message
        }
    })

    # Filter checkboxes - refresh display when changed
    @('chkDebug', 'chkInfo', 'chkWarning', 'chkError') | ForEach-Object {
        $script:LogControls[$_].Add_Checked({ Update-LogWindowContent })
        $script:LogControls[$_].Add_Unchecked({ Update-LogWindowContent })
    }

    # Handle window closing - hide instead of close to preserve state
    $Window.Add_Closing({
        param($sender, $e)
        $e.Cancel = $true
        $sender.Hide()
    })
}

function Update-LogWindowContent {
    <#
    .SYNOPSIS
        Updates the log window text from the ring buffer
    .DESCRIPTION
        Refreshes the log window content, applying any active filters.
        Called when the window is shown and when log entries are added.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:LogWindow -or -not $script:LogWindow.IsVisible) {
        return
    }

    # Get filter settings
    $showDebug = $script:LogControls.chkDebug.IsChecked
    $showInfo = $script:LogControls.chkInfo.IsChecked
    $showWarning = $script:LogControls.chkWarning.IsChecked
    $showError = $script:LogControls.chkError.IsChecked

    # Thread-safe buffer read
    $lines = @()
    [System.Threading.Monitor]::Enter($script:GuiLogBuffer)
    try {
        $lines = @($script:GuiLogBuffer)
    }
    finally {
        [System.Threading.Monitor]::Exit($script:GuiLogBuffer)
    }

    # Apply filters if any checkbox is unchecked (otherwise show all)
    $filteredLines = $lines | Where-Object {
        $line = $_
        # Parse log level from line format: [HH:mm:ss] [LEVEL] Message
        # Or simpler format: [HH:mm:ss] Message (treat as INFO)
        $isDebug = $line -match '\[DEBUG\]'
        $isWarning = $line -match '\[WARNING\]' -or $line -match '\[WARN\]'
        $isError = $line -match '\[ERROR\]' -or $line -match '\[ERR\]'
        $isInfo = -not $isDebug -and -not $isWarning -and -not $isError

        ($showDebug -and $isDebug) -or
        ($showInfo -and $isInfo) -or
        ($showWarning -and $isWarning) -or
        ($showError -and $isError)
    }

    # Update display
    $script:LogControls.txtLog.Text = $filteredLines -join "`n"
    $script:LogControls.txtLineCount.Text = "$($filteredLines.Count) lines"

    # Auto-scroll if enabled
    if ($script:LogControls.chkAutoScroll.IsChecked) {
        $script:LogControls.svLog.ScrollToEnd()
    }
}

function Clear-GuiLogBuffer {
    <#
    .SYNOPSIS
        Clears the GUI log buffer
    #>
    [CmdletBinding()]
    param()

    [System.Threading.Monitor]::Enter($script:GuiLogBuffer)
    try {
        $script:GuiLogBuffer.Clear()
    }
    finally {
        [System.Threading.Monitor]::Exit($script:GuiLogBuffer)
    }
}

function Update-InlineLogContent {
    <#
    .SYNOPSIS
        Updates the inline log panel content from the ring buffer
    .DESCRIPTION
        Filters log entries based on the selected log level checkboxes
        and updates the txtLogContent control in the main window's Logs panel.
        Called when filters change or when the log buffer is updated.
    #>
    [CmdletBinding()]
    param()

    # Check if control exists
    if (-not $script:Controls['txtLogContent']) {
        return
    }

    # Get filter settings (default to true if controls don't exist)
    $showDebug = if ($script:Controls['chkLogDebug']) { $script:Controls.chkLogDebug.IsChecked } else { $true }
    $showInfo = if ($script:Controls['chkLogInfo']) { $script:Controls.chkLogInfo.IsChecked } else { $true }
    $showWarning = if ($script:Controls['chkLogWarning']) { $script:Controls.chkLogWarning.IsChecked } else { $true }
    $showError = if ($script:Controls['chkLogError']) { $script:Controls.chkLogError.IsChecked } else { $true }

    # Thread-safe buffer read
    $lines = @()
    [System.Threading.Monitor]::Enter($script:GuiLogBuffer)
    try {
        $lines = @($script:GuiLogBuffer)
    }
    finally {
        [System.Threading.Monitor]::Exit($script:GuiLogBuffer)
    }

    # Apply filters - lines without level markers are always included
    $filteredLines = $lines | Where-Object {
        $line = $_
        # Parse log level from line format: [HH:mm:ss] [LEVEL] Message
        $isDebug = $line -match '\[DEBUG\]'
        $isWarning = $line -match '\[WARNING\]' -or $line -match '\[WARN\]'
        $isError = $line -match '\[ERROR\]' -or $line -match '\[ERR\]'
        $isInfo = $line -match '\[INFO\]'
        $noLevel = -not $isDebug -and -not $isWarning -and -not $isError -and -not $isInfo

        # Show lines without level markers always, or apply filters
        $noLevel -or
        ($showDebug -and $isDebug) -or
        ($showInfo -and $isInfo) -or
        ($showWarning -and $isWarning) -or
        ($showError -and $isError)
    }

    # Update display
    $script:Controls.txtLogContent.Text = $filteredLines -join "`r`n"

    # Update line count if control exists
    if ($script:Controls['txtLogLineCount']) {
        $script:Controls.txtLogLineCount.Text = "$($filteredLines.Count) lines"
    }

    # Auto-scroll if enabled
    if ($script:Controls['chkLogAutoScroll'] -and $script:Controls.chkLogAutoScroll.IsChecked) {
        # Scroll to end using Dispatcher to ensure UI is ready
        $script:Controls.txtLogContent.Dispatcher.Invoke([action]{
            $script:Controls.txtLogContent.ScrollToEnd()
        }, [System.Windows.Threading.DispatcherPriority]::Background)
    }
}

function Close-LogWindow {
    <#
    .SYNOPSIS
        Closes and disposes the log window
    .DESCRIPTION
        Called during application cleanup to properly dispose the window.
    #>
    [CmdletBinding()]
    param()

    if ($script:LogWindow) {
        try {
            $script:LogWindow.Close()
        }
        catch {
            # Window may already be closed
        }
        $script:LogWindow = $null
        $script:LogControls = @{}
    }
}
