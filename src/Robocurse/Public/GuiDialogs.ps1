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
    .PARAMETER ChunksComplete
        Number of chunks completed successfully
    .PARAMETER ChunksTotal
        Total number of chunks
    .PARAMETER ChunksFailed
        Number of chunks that failed
    .PARAMETER FailedChunkDetails
        Array of failed chunk objects with details for error display
    #>
    [CmdletBinding()]
    param(
        [int]$ChunksComplete = 0,
        [int]$ChunksTotal = 0,
        [int]$ChunksFailed = 0,
        [PSCustomObject[]]$FailedChunkDetails = @()
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

        # Adjust appearance based on results
        if ($ChunksFailed -gt 0) {
            # Some failures - show warning state
            $iconBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF9800")
            $iconText.Text = [char]0x26A0  # Warning triangle
            $txtTitle.Text = "Replication Complete with Warnings"
            $txtSubtitle.Text = "$ChunksFailed chunk(s) failed"
            $txtFailedValue.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF9800")

            # Show error details if we have failed chunk information
            if ($FailedChunkDetails.Count -gt 0) {
                $pnlErrors.Visibility = 'Visible'

                # Display up to 10 errors
                $displayErrors = $FailedChunkDetails | Select-Object -First 10
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

                # Show "and X more..." if there are more than 10 errors
                if ($FailedChunkDetails.Count -gt 10) {
                    $remaining = $FailedChunkDetails.Count - 10
                    $txtMoreErrors.Text = "...and $remaining more error(s)"
                    $txtMoreErrors.Visibility = 'Visible'
                }

                # Copy Errors button handler
                $btnCopyErrors.Add_Click({
                    try {
                        # Build error report
                        $errorReport = "Robocurse Replication Errors`n"
                        $errorReport += "=" * 50 + "`n`n"

                        foreach ($chunk in $FailedChunkDetails) {
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
                [System.Windows.MessageBox]::Show("Username is required", "Validation Error", "OK", "Warning")
                return
            }

            if ([string]::IsNullOrWhiteSpace($password)) {
                [System.Windows.MessageBox]::Show("Password is required", "Validation Error", "OK", "Warning")
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
                    [System.Windows.MessageBox]::Show(
                        "Credentials saved successfully to Windows Credential Manager.",
                        "Success",
                        "OK",
                        "Information"
                    )
                    $dialog.Close()
                }
                else {
                    Write-GuiLog "Failed to save SMTP credentials: $($result.ErrorMessage)"
                    [System.Windows.MessageBox]::Show(
                        "Failed to save credentials:`n$($result.ErrorMessage)",
                        "Error",
                        "OK",
                        "Error"
                    )
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
