# Robocurse GUI Dialogs
# Utility dialogs, completion dialog, and schedule configuration.

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

function Show-ConfirmDialog {
    <#
    .SYNOPSIS
        Shows a styled confirmation dialog matching the app's dark theme
    .DESCRIPTION
        Displays a modal confirmation dialog with customizable title, message, and button text.
        Styled to match the application's dark theme. Supports mouse dragging and Escape key
        cancellation. Used for user confirmations throughout the GUI (delete profile, stop
        replication, etc.).
    .PARAMETER Title
        Dialog title text
    .PARAMETER Message
        Message to display
    .PARAMETER ConfirmText
        Text for the confirm button (default: "Confirm")
    .PARAMETER CancelText
        Text for the cancel button (default: "Cancel")
    .OUTPUTS
        $true if confirmed, $false if cancelled
    #>
    [CmdletBinding()]
    param(
        [string]$Title = "Confirm",
        [string]$Message = "Are you sure?",
        [string]$ConfirmText = "Confirm",
        [string]$CancelText = "Cancel"
    )

    try {
        # Load XAML from resource file
        $xaml = Get-XamlResource -ResourceName 'ConfirmDialog.xaml'
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()

        # Get controls
        $txtTitle = $dialog.FindName("txtTitle")
        $txtMessage = $dialog.FindName("txtMessage")
        $btnConfirm = $dialog.FindName("btnConfirm")
        $btnCancel = $dialog.FindName("btnCancel")

        # Set content
        $txtTitle.Text = $Title
        $txtMessage.Text = $Message
        $btnConfirm.Content = $ConfirmText
        $btnCancel.Content = $CancelText

        # Track result
        $script:ConfirmDialogResult = $false

        # Confirm button handler
        $btnConfirm.Add_Click({
            $script:ConfirmDialogResult = $true
            $dialog.Close()
        })

        # Cancel button handler
        $btnCancel.Add_Click({
            $script:ConfirmDialogResult = $false
            $dialog.Close()
        })

        # Allow dragging the window
        $dialog.Add_MouseLeftButtonDown({
            param($sender, $e)
            if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
                $dialog.DragMove()
            }
        })

        # Escape key to cancel
        $dialog.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                $script:ConfirmDialogResult = $false
                $dialog.Close()
            }
        })

        # Set owner to main window for proper modal behavior
        if ($script:Window) {
            $dialog.Owner = $script:Window
        }
        $dialog.ShowDialog() | Out-Null

        return $script:ConfirmDialogResult
    }
    catch {
        Write-GuiLog "Error showing confirm dialog: $($_.Exception.Message)"
        # Fallback to MessageBox
        $result = [System.Windows.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        return ($result -eq 'Yes')
    }
}

function Show-AlertDialog {
    <#
    .SYNOPSIS
        Shows a styled alert/warning dialog matching the app's dark theme
    .DESCRIPTION
        Displays a modal alert dialog with customizable icon, title, message, and button text.
        Supports three icon types (Warning, Error, Info) with appropriate color coding. Styled
        to match the application's dark theme. Used for non-interactive notifications and
        warnings throughout the GUI.
    .PARAMETER Title
        Dialog title text
    .PARAMETER Message
        Message to display
    .PARAMETER Icon
        Icon type: 'Warning', 'Error', 'Info' (default: Warning)
    .PARAMETER ButtonText
        Text for the OK button (default: "OK")
    .OUTPUTS
        Nothing (void)
    #>
    [CmdletBinding()]
    param(
        [string]$Title = "Alert",
        [string]$Message = "",
        [ValidateSet('Warning', 'Error', 'Info')]
        [string]$Icon = 'Warning',
        [string]$ButtonText = "OK"
    )

    try {
        # Load XAML from resource file
        $xaml = Get-XamlResource -ResourceName 'AlertDialog.xaml'
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()

        # Get controls
        $txtTitle = $dialog.FindName("txtTitle")
        $txtMessage = $dialog.FindName("txtMessage")
        $txtIcon = $dialog.FindName("txtIcon")
        $iconBorder = $dialog.FindName("iconBorder")
        $dialogBorder = $dialog.FindName("dialogBorder")
        $btnOk = $dialog.FindName("btnOk")

        # Set content
        $txtTitle.Text = $Title
        $txtMessage.Text = $Message
        $btnOk.Content = $ButtonText

        # Set icon and colors based on type
        switch ($Icon) {
            'Error' {
                $txtIcon.Text = "X"
                $iconBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF6B6B")
                $dialogBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF6B6B")
            }
            'Info' {
                $txtIcon.Text = "i"
                $iconBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#0078D4")
                $dialogBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#0078D4")
            }
            default {
                # Warning (default)
                $txtIcon.Text = "!"
                $iconBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FFB340")
                $dialogBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FFB340")
            }
        }

        # OK button handler
        $btnOk.Add_Click({
            $dialog.Close()
        })

        # Allow dragging the window
        $dialog.Add_MouseLeftButtonDown({
            param($sender, $e)
            if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
                $dialog.DragMove()
            }
        })

        # Escape or Enter key to close
        $dialog.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape -or $e.Key -eq [System.Windows.Input.Key]::Return) {
                $dialog.Close()
            }
        })

        # Set owner to main window for proper modal behavior
        if ($script:Window) {
            $dialog.Owner = $script:Window
        }
        $dialog.ShowDialog() | Out-Null
    }
    catch {
        Write-GuiLog "Error showing alert dialog: $($_.Exception.Message)"
        # Fallback to MessageBox
        $mbIcon = switch ($Icon) {
            'Error' { [System.Windows.MessageBoxImage]::Error }
            'Info' { [System.Windows.MessageBoxImage]::Information }
            default { [System.Windows.MessageBoxImage]::Warning }
        }
        [System.Windows.MessageBox]::Show($Message, $Title, [System.Windows.MessageBoxButton]::OK, $mbIcon) | Out-Null
    }
}

function Show-CompletionDialog {
    <#
    .SYNOPSIS
        Shows a modern completion dialog with replication statistics
    .DESCRIPTION
        Displays a styled completion dialog at the end of replication showing success/failure
        statistics. Color-coded based on results (success green, warnings orange). Shows detailed
        error information for failed chunks with copy-to-clipboard functionality and log viewer
        access. Provides visual feedback on overall replication health.
    .PARAMETER ChunksComplete
        Number of chunks completed successfully
    .PARAMETER ChunksTotal
        Total number of chunks
    .PARAMETER ChunksFailed
        Number of chunks that failed
    .PARAMETER ChunksWarning
        Number of chunks that completed with warnings (e.g., some files skipped)
    .PARAMETER FilesFailed
        Total number of files that failed to copy (errors, locked, access denied)
    .PARAMETER FailedFilesSummaryPath
        Path to the failed files summary file (if exists)
    .PARAMETER FailedChunkDetails
        Array of failed chunk objects with details for error display
    .PARAMETER WarningChunkDetails
        Array of warning chunk objects with details for warning display
    .PARAMETER PreflightErrors
        Array of pre-flight error messages (e.g., source path not accessible)
    #>
    [CmdletBinding()]
    param(
        [int]$ChunksComplete = 0,
        [int]$ChunksTotal = 0,
        [int]$ChunksFailed = 0,
        [int]$ChunksWarning = 0,
        [long]$FilesSkipped = 0,
        [long]$FilesFailed = 0,
        [string]$FailedFilesSummaryPath = $null,
        [PSCustomObject[]]$FailedChunkDetails = @(),
        [PSCustomObject[]]$WarningChunkDetails = @(),
        [string[]]$PreflightErrors = @()
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
        $txtSkippedValue = $dialog.FindName("txtSkippedValue")
        $txtFilesFailedValue = $dialog.FindName("txtFilesFailedValue")
        $lnkFailedFiles = $dialog.FindName("lnkFailedFiles")
        $pnlErrors = $dialog.FindName("pnlErrors")
        $lstErrors = $dialog.FindName("lstErrors")
        $txtMoreErrors = $dialog.FindName("txtMoreErrors")
        $btnCopyErrors = $dialog.FindName("btnCopyErrors")
        $btnViewLogs = $dialog.FindName("btnViewLogs")
        $btnOk = $dialog.FindName("btnOk")

        # Set values
        $txtChunksValue.Text = $ChunksComplete.ToString()
        $txtTotalValue.Text = $ChunksTotal.ToString()
        $txtFailedValue.Text = $ChunksFailed.ToString()
        $txtSkippedValue.Text = $FilesSkipped.ToString()
        $txtFilesFailedValue.Text = $FilesFailed.ToString()

        # Color files failed red if > 0
        if ($FilesFailed -gt 0) {
            $txtFilesFailedValue.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#F44336")
        }

        # Show failed files link if summary exists
        if ($FailedFilesSummaryPath -and (Test-Path $FailedFilesSummaryPath)) {
            $lnkFailedFiles.Visibility = 'Visible'
            $lnkFailedFiles.Tag = $FailedFilesSummaryPath
            $lnkFailedFiles.Add_MouseDown({
                param($sender, $e)
                if ($e.LeftButton -eq 'Pressed') {
                    try {
                        $path = $sender.Tag
                        if ($path -and (Test-Path $path)) {
                            Start-Process notepad.exe -ArgumentList "`"$path`""
                        }
                    }
                    catch {
                        # Silently ignore - dialog will close anyway
                    }
                    $e.Handled = $true
                }
            })
        }

        # Adjust appearance based on results
        if ($PreflightErrors.Count -gt 0) {
            # Pre-flight failure - show error state (red)
            $iconBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#F44336")
            $iconText.Text = [char]0x2716  # X mark
            $txtTitle.Text = "Replication Failed"
            $txtSubtitle.Text = "Pre-flight check failed - source not accessible"
            $txtFailedValue.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#F44336")

            # Show pre-flight errors in error panel
            $pnlErrors.Visibility = 'Visible'
            foreach ($err in $PreflightErrors) {
                $errorItem = New-Object System.Windows.Controls.Border
                $errorItem.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#1E1E1E")
                $errorItem.CornerRadius = 3
                $errorItem.Padding = 8
                $errorItem.Margin = "0,0,0,6"

                $errorText = New-Object System.Windows.Controls.TextBlock
                $errorText.Text = $err
                $errorText.FontSize = 11
                $errorText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#F44336")
                $errorText.TextWrapping = 'Wrap'
                $errorItem.Child = $errorText

                $lstErrors.Children.Add($errorItem) | Out-Null
            }
        }
        elseif ($ChunksFailed -gt 0) {
            # Some failures - show error state (red/orange)
            $iconBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#F44336")
            $iconText.Text = [char]0x2716  # X mark
            $txtTitle.Text = "Replication Complete with Errors"
            $txtSubtitle.Text = "$ChunksFailed chunk(s) failed"
            $txtFailedValue.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#F44336")
        }
        elseif ($ChunksWarning -gt 0) {
            # Some warnings but no failures - show warning state (orange)
            $iconBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF9800")
            $iconText.Text = [char]0x26A0  # Warning triangle
            $txtTitle.Text = "Replication Complete with Warnings"
            $txtSubtitle.Text = "$ChunksWarning chunk(s) had files that could not be copied"
            $txtFailedValue.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF9800")

            # Show warning details if we have warning chunk information
            if ($WarningChunkDetails.Count -gt 0) {
                $pnlErrors.Visibility = 'Visible'

                # Display up to 10 warnings
                $displayErrors = $WarningChunkDetails | Select-Object -First 10
                foreach ($chunk in $displayErrors) {
                    $errorItem = New-Object System.Windows.Controls.Border
                    $errorItem.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#1E1E1E")
                    $errorItem.CornerRadius = 3
                    $errorItem.Padding = 8
                    $errorItem.Margin = "0,0,0,6"

                    $errorStack = New-Object System.Windows.Controls.StackPanel

                    # Chunk ID and Source Path
                    $headerText = New-Object System.Windows.Controls.TextBlock
                    $headerText.Text = "Chunk $($chunk.ChunkId): $($chunk.SourcePath)"
                    $headerText.FontSize = 11
                    $headerText.FontWeight = 'SemiBold'
                    $headerText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#E0E0E0")
                    $headerText.TextWrapping = 'Wrap'
                    $errorStack.Children.Add($headerText) | Out-Null

                    # Exit Code
                    $exitCode = if ($chunk.PSObject.Properties['LastExitCode']) { $chunk.LastExitCode } else { 'N/A' }
                    $exitCodeText = New-Object System.Windows.Controls.TextBlock
                    $exitCodeText.Text = "Exit Code: $exitCode"
                    $exitCodeText.FontSize = 10
                    $exitCodeText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#808080")
                    $exitCodeText.Margin = "0,2,0,0"
                    $errorStack.Children.Add($exitCodeText) | Out-Null

                    # Error Message
                    $errorMsg = if ($chunk.PSObject.Properties['LastErrorMessage']) { $chunk.LastErrorMessage } else { 'Unknown error' }
                    $errorMsgText = New-Object System.Windows.Controls.TextBlock
                    $errorMsgText.Text = "Error: $errorMsg"
                    $errorMsgText.FontSize = 10
                    $errorMsgText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF6B6B")
                    $errorMsgText.TextWrapping = 'Wrap'
                    $errorMsgText.Margin = "0,2,0,0"
                    $errorStack.Children.Add($errorMsgText) | Out-Null

                    $errorItem.Child = $errorStack
                    $lstErrors.Children.Add($errorItem) | Out-Null
                }

                # Show "and X more..." if there are more than 10 warnings
                if ($WarningChunkDetails.Count -gt 10) {
                    $remaining = $WarningChunkDetails.Count - 10
                    $txtMoreErrors.Text = "...and $remaining more warning(s)"
                    $txtMoreErrors.Visibility = 'Visible'
                }

                # Copy Warnings button handler
                $btnCopyErrors.Add_Click({
                    try {
                        # Build warning report
                        $errorReport = "Robocurse Replication Warnings`n"
                        $errorReport += "=" * 50 + "`n`n"

                        foreach ($chunk in $WarningChunkDetails) {
                            $errorReport += "Chunk $($chunk.ChunkId): $($chunk.SourcePath)`n"
                            $exitCode = if ($chunk.PSObject.Properties['LastExitCode']) { $chunk.LastExitCode } else { 'N/A' }
                            $errorReport += "Exit Code: $exitCode`n"
                            $errorMsg = if ($chunk.PSObject.Properties['LastErrorMessage']) { $chunk.LastErrorMessage } else { 'Unknown error' }
                            $errorReport += "Error: $errorMsg`n"
                            $errorReport += "`n"
                        }

                        # Copy to clipboard
                        [System.Windows.Clipboard]::SetText($errorReport)

                        # Change button text temporarily
                        $originalText = $btnCopyErrors.Content
                        $btnCopyErrors.Content = "Copied!"

                        # Use DispatcherTimer to reset after 2 seconds
                        $resetTimer = New-Object System.Windows.Threading.DispatcherTimer
                        $resetTimer.Interval = [TimeSpan]::FromSeconds(2)
                        $resetTimer.Add_Tick({
                            $btnCopyErrors.Content = $originalText
                            $resetTimer.Stop()
                        })
                        $resetTimer.Start()
                    }
                    catch {
                        Write-GuiLog "Error copying errors to clipboard: $($_.Exception.Message)"
                    }
                }.GetNewClosure())

                # View Logs button handler
                $btnViewLogs.Add_Click({
                    try {
                        # Get log path from config
                        $logPath = if ($script:Config -and $script:Config.LogPath) {
                            $script:Config.LogPath
                        } else {
                            Join-Path (Get-Location) "Logs"
                        }

                        # Open log directory in explorer
                        if (Test-Path $logPath) {
                            Start-Process explorer.exe -ArgumentList $logPath
                        } else {
                            Write-GuiLog "Log directory not found: $logPath"
                        }
                    }
                    catch {
                        Write-GuiLog "Error opening log directory: $($_.Exception.Message)"
                    }
                })
            }
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
                    Show-AlertDialog -Title "Error" -Message "Invalid time format. Use HH:MM" -Icon 'Error'
                    return
                }
                $hour = [int]$timeParts[0]
                $minute = [int]$timeParts[1]

                if ($hour -lt 0 -or $hour -gt 23 -or $minute -lt 0 -or $minute -gt 59) {
                    Show-AlertDialog -Title "Error" -Message "Invalid time. Hour must be 0-23, minute must be 0-59" -Icon 'Error'
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
                        Show-AlertDialog -Title "Schedule Configured" -Message "Scheduled task has been registered.`n`nThe task will run $scheduleType at $($txtTime.Text)." -Icon 'Info'
                    }
                    else {
                        Write-GuiLog "Failed to register scheduled task: $($result.ErrorMessage)"
                        Show-AlertDialog -Title "Error" -Message "Failed to register scheduled task.`n$($result.ErrorMessage)" -Icon 'Error'
                    }
                }
                else {
                    # Remove the task if it exists
                    if ($taskExists) {
                        Write-GuiLog "Removing scheduled task..."
                        $result = Unregister-RobocurseTask
                        if ($result.Success) {
                            Write-GuiLog "Scheduled task removed"
                            Show-AlertDialog -Title "Schedule Disabled" -Message "Scheduled task has been removed." -Icon 'Info'
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

function Show-CredentialInputDialog {
    <#
    .SYNOPSIS
        Shows a dialog to input SMTP credentials and save them to Windows Credential Manager
    .DESCRIPTION
        Displays a modal dialog with username and password fields. When saved, the credentials
        are stored in Windows Credential Manager using the specified target name.
    .PARAMETER CredentialTarget
        The target name for the credential in Windows Credential Manager (default: from settings)
    .OUTPUTS
        $true if credentials were saved successfully, $false if cancelled or failed
    .EXAMPLE
        $result = Show-CredentialInputDialog -CredentialTarget "Robocurse-SMTP"
    #>
    [CmdletBinding()]
    param(
        [string]$CredentialTarget
    )

    # Get target from settings if not provided
    if (-not $CredentialTarget -and $script:Controls -and $script:Controls['txtSettingsCredential']) {
        $CredentialTarget = $script:Controls.txtSettingsCredential.Text.Trim()
    }
    if (-not $CredentialTarget) {
        $CredentialTarget = "Robocurse-SMTP"
    }

    try {
        # Load XAML from resource file
        $xaml = Get-XamlResource -ResourceName 'CredentialInputDialog.xaml'
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()

        # Get controls
        $txtTitle = $dialog.FindName("txtTitle")
        $txtSubtitle = $dialog.FindName("txtSubtitle")
        $txtUsername = $dialog.FindName("txtUsername")
        $pwdPassword = $dialog.FindName("pwdPassword")
        $btnSave = $dialog.FindName("btnSave")
        $btnCancel = $dialog.FindName("btnCancel")

        # Set title with target name
        $txtTitle.Text = "Set SMTP Credentials"
        $txtSubtitle.Text = "Target: $CredentialTarget"

        # Track result
        $script:CredentialDialogResult = $false

        # Save button handler
        $btnSave.Add_Click({
            $username = $txtUsername.Text.Trim()
            $password = $pwdPassword.Password

            if ([string]::IsNullOrWhiteSpace($username)) {
                Show-AlertDialog -Title "Validation Error" -Message "Username is required" -Icon 'Warning'
                return
            }

            if ([string]::IsNullOrWhiteSpace($password)) {
                Show-AlertDialog -Title "Validation Error" -Message "Password is required" -Icon 'Warning'
                return
            }

            try {
                # Create PSCredential
                $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)

                # Save to Credential Manager
                $result = Save-SmtpCredential -Target $CredentialTarget -Credential $credential

                if ($result.Success) {
                    Write-GuiLog "SMTP credentials saved to Credential Manager: $CredentialTarget"
                    $script:CredentialDialogResult = $true
                    Show-AlertDialog -Title "Success" -Message "Credentials saved successfully to Windows Credential Manager." -Icon 'Info'
                    $dialog.Close()
                }
                else {
                    Write-GuiLog "Failed to save SMTP credentials: $($result.ErrorMessage)"
                    Show-AlertDialog -Title "Error" -Message "Failed to save credentials:`n$($result.ErrorMessage)" -Icon 'Error'
                }
            }
            catch {
                Write-GuiLog "Error saving credentials: $($_.Exception.Message)"
                [System.Windows.MessageBox]::Show(
                    "Error saving credentials:`n$($_.Exception.Message)",
                    "Error",
                    "OK",
                    "Error"
                )
            }
        })

        # Cancel button handler
        $btnCancel.Add_Click({
            $script:CredentialDialogResult = $false
            $dialog.Close()
        })

        # Allow dragging the window
        $dialog.Add_MouseLeftButtonDown({
            param($sender, $e)
            if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
                $dialog.DragMove()
            }
        })

        # Escape key to cancel
        $dialog.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                $script:CredentialDialogResult = $false
                $dialog.Close()
            }
        })

        # Enter key to save (when in password field)
        $pwdPassword.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
                $btnSave.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
            }
        })

        # Set owner to main window for proper modal behavior
        if ($script:Window) {
            $dialog.Owner = $script:Window
        }
        $dialog.ShowDialog() | Out-Null

        return $script:CredentialDialogResult
    }
    catch {
        Write-GuiLog "Error showing credential dialog: $($_.Exception.Message)"
        # Fallback to error message
        [System.Windows.MessageBox]::Show(
            "Failed to show credential dialog:`n$($_.Exception.Message)",
            "Error",
            "OK",
            "Error"
        )
        return $false
    }
}

function Show-ProfileScheduleDialog {
    <#
    .SYNOPSIS
        Shows profile schedule configuration dialog
    .DESCRIPTION
        Displays a dialog for configuring scheduled runs for a specific profile.
        When saved, updates the profile's Schedule property and creates/removes
        the corresponding Windows Task Scheduler task.
    .PARAMETER Profile
        The profile object to configure scheduling for
    .OUTPUTS
        $true if schedule was saved, $false if cancelled
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile
    )

    try {
        # Load XAML
        $xaml = Get-XamlResource -ResourceName 'ProfileScheduleDialog.xaml'
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()

        # Get controls
        $txtProfileName = $dialog.FindName("txtProfileName")
        $chkEnabled = $dialog.FindName("chkEnabled")
        $cmbFrequency = $dialog.FindName("cmbFrequency")
        $txtTime = $dialog.FindName("txtTime")
        $pnlHourlyOptions = $dialog.FindName("pnlHourlyOptions")
        $pnlWeeklyOptions = $dialog.FindName("pnlWeeklyOptions")
        $pnlMonthlyOptions = $dialog.FindName("pnlMonthlyOptions")
        $cmbInterval = $dialog.FindName("cmbInterval")
        $cmbDayOfWeek = $dialog.FindName("cmbDayOfWeek")
        $cmbDayOfMonth = $dialog.FindName("cmbDayOfMonth")
        $txtStatus = $dialog.FindName("txtStatus")
        $btnSave = $dialog.FindName("btnSave")
        $btnCancel = $dialog.FindName("btnCancel")

        # Set profile name
        $txtProfileName.Text = "Configure schedule for: $($Profile.Name)"

        # Populate day of month dropdown (1-28)
        1..28 | ForEach-Object {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $_.ToString()
            $cmbDayOfMonth.Items.Add($item) | Out-Null
        }
        $cmbDayOfMonth.SelectedIndex = 0

        # Load current settings
        if ($Profile.Schedule) {
            $chkEnabled.IsChecked = $Profile.Schedule.Enabled
            $txtTime.Text = if ($Profile.Schedule.Time) { $Profile.Schedule.Time } else { "02:00" }

            # Set frequency
            $freqIndex = switch ($Profile.Schedule.Frequency) {
                "Hourly" { 0 }
                "Daily" { 1 }
                "Weekly" { 2 }
                "Monthly" { 3 }
                default { 1 }
            }
            $cmbFrequency.SelectedIndex = $freqIndex

            # Set frequency-specific values
            if ($Profile.Schedule.Interval) {
                $intervalIndex = @(1,2,3,4,6,8,12).IndexOf([int]$Profile.Schedule.Interval)
                if ($intervalIndex -ge 0) { $cmbInterval.SelectedIndex = $intervalIndex }
            }
            if ($Profile.Schedule.DayOfWeek) {
                $dayIndex = @("Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday").IndexOf($Profile.Schedule.DayOfWeek)
                if ($dayIndex -ge 0) { $cmbDayOfWeek.SelectedIndex = $dayIndex }
            }
            if ($Profile.Schedule.DayOfMonth) {
                $cmbDayOfMonth.SelectedIndex = [Math]::Max(0, [int]$Profile.Schedule.DayOfMonth - 1)
            }
        }

        # Function to update visible options
        $updateOptions = {
            $frequency = $cmbFrequency.SelectedItem.Content
            $pnlHourlyOptions.Visibility = if ($frequency -eq "Hourly") { 'Visible' } else { 'Collapsed' }
            $pnlWeeklyOptions.Visibility = if ($frequency -eq "Weekly") { 'Visible' } else { 'Collapsed' }
            $pnlMonthlyOptions.Visibility = if ($frequency -eq "Monthly") { 'Visible' } else { 'Collapsed' }
        }

        # Frequency change handler
        $cmbFrequency.Add_SelectionChanged({
            & $updateOptions
        })

        # Initialize visibility
        & $updateOptions

        # Time validation
        $txtTime.Add_TextChanged({
            param($sender, $e)
            $isValid = $sender.Text -match '^([01]?\d|2[0-3]):([0-5]\d)$'
            if ($isValid) {
                $sender.BorderBrush = [System.Windows.Media.Brushes]::Gray
                $sender.ToolTip = "Time in 24-hour format (HH:MM)"
            } else {
                $sender.BorderBrush = [System.Windows.Media.Brushes]::Red
                $sender.ToolTip = "Invalid format. Use HH:MM (24-hour, e.g., 02:00, 14:30)"
            }
        })

        # Check current task status
        $taskInfo = Get-ProfileScheduledTask -ProfileName $Profile.Name
        if ($taskInfo) {
            $nextRun = if ($taskInfo.NextRunTime) { $taskInfo.NextRunTime.ToString("g") } else { "N/A" }
            $txtStatus.Text = "Current task status: $($taskInfo.State)`nNext run: $nextRun"
        } else {
            $txtStatus.Text = "No scheduled task currently configured."
        }

        # Track result
        $script:ProfileScheduleDialogResult = $false

        # Save button
        $btnSave.Add_Click({
            # Validate time
            if ($txtTime.Text -notmatch '^([01]?\d|2[0-3]):([0-5]\d)$') {
                Show-AlertDialog -Title "Validation Error" -Message "Invalid time format. Use HH:MM (24-hour)" -Icon 'Warning'
                return
            }

            try {
                # Build schedule object
                $frequency = $cmbFrequency.SelectedItem.Content
                $newSchedule = [PSCustomObject]@{
                    Enabled = $chkEnabled.IsChecked
                    Frequency = $frequency
                    Time = $txtTime.Text
                    Interval = [int]$cmbInterval.SelectedItem.Content
                    DayOfWeek = $cmbDayOfWeek.SelectedItem.Content
                    DayOfMonth = [int]$cmbDayOfMonth.SelectedItem.Content
                }

                # Update profile - add Schedule property if missing (defensive for old profiles)
                if (-not ($Profile.PSObject.Properties.Name -contains 'Schedule')) {
                    $Profile | Add-Member -NotePropertyName 'Schedule' -NotePropertyValue $newSchedule
                } else {
                    $Profile.Schedule = $newSchedule
                }

                # Create or remove task
                if ($chkEnabled.IsChecked) {
                    # Check if profile uses network paths - if so, require credentials
                    $needsCredential = ($Profile.Source -match '^\\\\') -or ($Profile.Destination -match '^\\\\')
                    $credential = $null

                    if ($needsCredential) {
                        # Prompt for credentials - required for network share access
                        Write-GuiLog "Profile uses network paths - prompting for credentials"
                        try {
                            $credential = Get-Credential -Message "Enter credentials for scheduled task.`nRequired for network share access to:`n$($Profile.Source)" -UserName "$env:USERDOMAIN\$env:USERNAME"
                            if (-not $credential) {
                                Write-GuiLog "User cancelled credential prompt"
                                Show-AlertDialog -Title "Credentials Required" -Message "Credentials are required for scheduled tasks that access network shares.`n`nThe task cannot run without credentials because Windows Task Scheduler`ncannot authenticate to network resources without a stored password." -Icon 'Warning'
                                return
                            }
                        }
                        catch {
                            Write-GuiLog "Credential prompt failed: $($_.Exception.Message)"
                            return
                        }
                    }

                    Write-GuiLog "Creating profile schedule for $($Profile.Name)"
                    $result = New-ProfileScheduledTask -Profile $Profile -ConfigPath $script:ConfigPath -Credential $credential
                    if ($result.Success) {
                        Write-GuiLog "Profile schedule created: $($result.Data)"
                        if ($needsCredential) {
                            Write-GuiLog "Task registered with Password logon (network access enabled)"
                        }
                    } else {
                        Write-GuiLog "Failed to create profile schedule: $($result.ErrorMessage)"
                        Show-AlertDialog -Title "Error" -Message "Failed to create scheduled task:`n$($result.ErrorMessage)" -Icon 'Error'
                        return
                    }
                } else {
                    # Remove task if it exists
                    $existingTask = Get-ProfileScheduledTask -ProfileName $Profile.Name
                    if ($existingTask) {
                        Write-GuiLog "Removing profile schedule for $($Profile.Name)"
                        Remove-ProfileScheduledTask -ProfileName $Profile.Name | Out-Null
                    }
                }

                # Save config
                $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
                if (-not $saveResult.Success) {
                    Write-GuiLog "Warning: Failed to save config: $($saveResult.ErrorMessage)"
                }

                $script:ProfileScheduleDialogResult = $true
                $dialog.Close()
            }
            catch {
                Write-GuiLog "Error saving profile schedule: $($_.Exception.Message)"
                [System.Windows.MessageBox]::Show(
                    "Error saving schedule: $($_.Exception.Message)",
                    "Error", "OK", "Error"
                )
            }
        })

        # Cancel button
        $btnCancel.Add_Click({
            $script:ProfileScheduleDialogResult = $false
            $dialog.Close()
        })

        # Dragging
        $dialog.Add_MouseLeftButtonDown({
            param($sender, $e)
            if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
                $dialog.DragMove()
            }
        })

        # Escape to close
        $dialog.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                $script:ProfileScheduleDialogResult = $false
                $dialog.Close()
            }
        })

        # Set owner
        if ($script:Window) {
            $dialog.Owner = $script:Window
        }
        $dialog.ShowDialog() | Out-Null

        return $script:ProfileScheduleDialogResult
    }
    catch {
        Write-GuiLog "Error showing profile schedule dialog: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "Failed to show schedule dialog:`n$($_.Exception.Message)",
            "Error", "OK", "Error"
        )
        return $false
    }
}

function Show-ErrorPopup {
    <#
    .SYNOPSIS
        Shows a popup dialog with recent errors from the current replication run
    .DESCRIPTION
        Displays errors stored in $script:ErrorHistoryBuffer in a styled dialog.
        Allows user to view error details and clear the error history.
    #>
    [CmdletBinding()]
    param()

    try {
        # Load XAML
        $xamlPath = Join-Path $PSScriptRoot "..\Resources\ErrorPopup.xaml"
        if (-not (Test-Path $xamlPath)) {
            # Try embedded XAML for monolith builds
            if ($script:EmbeddedXaml -and $script:EmbeddedXaml['ErrorPopup.xaml']) {
                $xaml = $script:EmbeddedXaml['ErrorPopup.xaml']
            } else {
                Write-GuiLog "ErrorPopup.xaml not found"
                return
            }
        } else {
            $xaml = Get-Content $xamlPath -Raw
        }

        # Parse XAML
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)

        # Get controls
        $lstErrors = $dialog.FindName('lstErrors')
        $btnClear = $dialog.FindName('btnClear')
        $btnClose = $dialog.FindName('btnClose')

        # Populate error list from buffer
        [System.Threading.Monitor]::Enter($script:ErrorHistoryBuffer)
        try {
            $errors = $script:ErrorHistoryBuffer.ToArray()
        }
        finally {
            [System.Threading.Monitor]::Exit($script:ErrorHistoryBuffer)
        }

        $lstErrors.ItemsSource = $errors

        # Close button
        $btnClose.Add_Click({
            $dialog.Close()
        }.GetNewClosure())

        # Clear button - clears errors and closes
        $btnClear.Add_Click({
            Clear-ErrorHistory
            $dialog.Close()
        }.GetNewClosure())

        # Allow dragging the window
        $dialog.Add_MouseLeftButtonDown({
            param($sender, $e)
            if ($e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
                $dialog.DragMove()
            }
        }.GetNewClosure())

        # Set owner and show
        if ($script:Window) {
            $dialog.Owner = $script:Window
        }
        $dialog.ShowDialog() | Out-Null
    }
    catch {
        Write-GuiLog "Error showing error popup: $($_.Exception.Message)"
    }
}
