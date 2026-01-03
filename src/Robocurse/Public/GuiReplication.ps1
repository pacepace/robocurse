# Robocurse GUI Replication Lifecycle
# High-level replication control: profile selection, start, and completion handling.
# Background runspace management is in GuiRunspace.ps1.

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

    # Early VSS privilege check - verify before starting replication
    # This prevents wasted time if VSS is required but privileges are missing
    $vssProfiles = @($profilesToRun | Where-Object { $_.UseVSS -eq $true })
    if ($vssProfiles.Count -gt 0) {
        $vssCheck = Test-VssPrivileges
        if (-not $vssCheck.Success) {
            $vssProfileNames = ($vssProfiles | ForEach-Object { $_.Name }) -join ", "
            Show-GuiError -Message "VSS is required for profile(s) '$vssProfileNames' but VSS prerequisites are not met: $($vssCheck.ErrorMessage)"
            return $null
        }
        Write-GuiLog "VSS privileges verified for $($vssProfiles.Count) profile(s)"
    }

    return $profilesToRun
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

    # Persist in-memory config to disk before creating snapshot
    # This ensures background runspace sees current settings (snapshot/retention, etc.)
    $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
    if (-not $saveResult.Success) {
        Write-GuiLog "Warning: Could not save config before replication: $($saveResult.ErrorMessage)"
        # Continue anyway - the in-memory config might still work for current session
    }

    # Get and validate profiles (force array context to handle PowerShell's single-item unwrapping)
    $profilesToRun = @(Get-ProfilesToRun -AllProfiles:$AllProfiles -SelectedOnly:$SelectedOnly)
    if ($profilesToRun.Count -eq 0) { return }

    # Update UI state for replication mode
    $script:Controls.btnRunAll.IsEnabled = $false
    $script:Controls.btnRunSelected.IsEnabled = $false
    $script:Controls.btnStop.IsEnabled = $true
    $script:Controls.txtStatus.Text = "Replication in progress..."
    $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::Gray  # Reset error color
    $script:Controls.txtStatus.Cursor = [System.Windows.Input.Cursors]::Arrow  # Reset cursor
    $script:Controls.txtStatus.TextDecorations = $null  # Clear underline
    $script:GuiErrorCount = 0  # Reset error count for new run

    # Clear error history for new run
    if ($script:ErrorHistoryBuffer) {
        [System.Threading.Monitor]::Enter($script:ErrorHistoryBuffer)
        try {
            $script:ErrorHistoryBuffer.Clear()
        }
        finally {
            [System.Threading.Monitor]::Exit($script:ErrorHistoryBuffer)
        }
    }

    # Reset per-profile error tracking
    Reset-ProfileErrorTracking

    $script:LastGuiUpdateState = $null
    $script:Controls.dgChunks.ItemsSource = $null

    Write-GuiLog "Starting replication with $($profilesToRun.Count) profile(s)"

    # Auto-switch to Progress panel
    Set-ActivePanel -PanelName 'Progress'

    # Get worker count and start progress timer
    $maxWorkers = [int]$script:Controls.sldWorkers.Value
    $script:ProgressTimer.Start()

    # Initialize orchestration state (must happen before runspace creation)
    Initialize-OrchestrationState

    # Compute absolute log root BEFORE creating config snapshot
    # This ensures logs go to the correct location (relative to original config, not temp snapshot)
    $logRoot = if ($script:Config.GlobalSettings.LogPath) { $script:Config.GlobalSettings.LogPath } else { '.\Logs' }
    if (-not [System.IO.Path]::IsPathRooted($logRoot)) {
        $configDir = Split-Path -Parent $script:ConfigPath
        $logRoot = [System.IO.Path]::GetFullPath((Join-Path $configDir $logRoot))
    }

    # Initialize log session so GUI and background share the same log file
    if (-not $script:CurrentOperationalLogPath) {
        try {
            Initialize-LogSession -LogRoot $logRoot
        }
        catch {
            Write-GuiLog "Warning: Could not initialize log session: $($_.Exception.Message)"
        }
    }

    # Create and start background runspace (using original config path for immediate persistence)
    # Pass current log path so background writes to same log file
    $currentLogPath = $script:CurrentOperationalLogPath
    try {
        $runspaceInfo = New-ReplicationRunspace -Profiles $profilesToRun -MaxWorkers $maxWorkers -ConfigPath $script:ConfigPath -LogRoot $logRoot -SessionLogPath $currentLogPath

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

function Complete-GuiReplication {
    <#
    .SYNOPSIS
        Called when replication completes
    .DESCRIPTION
        Handles GUI cleanup after replication: stops timer, re-enables buttons,
        disposes of background runspace resources, and shows completion message.

        THREAD SAFETY: Delegates runspace cleanup to Close-ReplicationRunspace
        which uses Interlocked.Exchange for atomic capture-and-clear. This prevents
        race conditions if window close and completion handler fire simultaneously.
    #>
    [CmdletBinding()]
    param()

    # Stop timer
    $script:ProgressTimer.Stop()

    # Wait for background runspace to fully complete and flush ALL streams
    # The phase is set to 'Complete' inside the script before BeginInvoke finishes
    if ($script:ReplicationHandle -and -not $script:ReplicationHandle.IsCompleted) {
        Write-GuiLog "Waiting for background runspace to finish..."
        try {
            # Wait up to 5 seconds for the handle to complete
            $null = $script:ReplicationHandle.AsyncWaitHandle.WaitOne(5000)
        }
        catch {
            Write-GuiLog "Warning: Timeout waiting for background runspace"
        }
    }

    # Flush any remaining log messages from the background runspace
    # Filter by MinLogLevel to match GUI's log level setting
    # Check if method exists (handles mock objects in tests)
    if ($script:OrchestrationState -and $script:OrchestrationState.PSObject.Methods['DequeueLogs']) {
        $logs = $script:OrchestrationState.DequeueLogs()
        foreach ($log in $logs) {
            if ($log -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[(\w+)\]') {
                $logLevel = $Matches[1]
                if (Test-ShouldLog -Level $logLevel) {
                    Write-Host $log
                }
            }
            else {
                Write-Host $log
            }
        }
    }

    # Capture background errors/warnings
    if ($script:ReplicationPowerShell -and $script:ReplicationPowerShell.Streams) {
        foreach ($warn in $script:ReplicationPowerShell.Streams.Warning) {
            Write-GuiLog "[BACKGROUND WARNING] $warn"
        }
        foreach ($err in $script:ReplicationPowerShell.Streams.Error) {
            $errorLocation = if ($err.InvocationInfo) {
                "$($err.InvocationInfo.ScriptName):$($err.InvocationInfo.ScriptLineNumber)"
            } else { "Unknown" }
            Write-GuiLog "[BACKGROUND ERROR] [$errorLocation] $($err.Exception.Message)"
        }
    }

    # Delegate to the thread-safe cleanup function (uses Interlocked.Exchange)
    # This prevents race conditions with window close handler
    Close-ReplicationRunspace

    # Re-enable buttons
    $script:Controls.btnRunAll.IsEnabled = $true
    $script:Controls.btnRunSelected.IsEnabled = $true
    $script:Controls.btnStop.IsEnabled = $false

    # Update status with error/warning indicator if applicable
    # Note: GuiErrorCount includes both errors and warnings from EnqueueError
    $tempStatus = Get-OrchestrationStatus
    if ($tempStatus.ChunksFailed -gt 0) {
        $script:Controls.txtStatus.Text = "Replication complete ($($tempStatus.ChunksFailed) failed)"
        $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::OrangeRed
    } elseif ($tempStatus.ChunksWarning -gt 0) {
        $script:Controls.txtStatus.Text = "Replication complete ($($tempStatus.ChunksWarning) with warnings)"
        $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::Orange
    } else {
        $script:Controls.txtStatus.Text = "Replication complete"
        $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::LimeGreen
    }

    # Get final status
    $status = Get-OrchestrationStatus
    $statusParts = @("$($status.ChunksComplete)/$($status.ChunksTotal) chunks")
    if ($status.ChunksWarning -gt 0) { $statusParts += "$($status.ChunksWarning) with warnings" }
    if ($status.ChunksFailed -gt 0) { $statusParts += "$($status.ChunksFailed) failed" }
    Write-GuiLog "Replication completed: $($statusParts -join ', ')"

    # Save last run summary for empty state display
    try {
        # Capture profile names from orchestration state
        $profileNames = @()
        if ($script:OrchestrationState -and $script:OrchestrationState.Profiles) {
            $profileNames = @($script:OrchestrationState.Profiles | ForEach-Object { $_.Name })
        }

        # Calculate elapsed time
        $elapsed = if ($script:OrchestrationState.StartTime) {
            [datetime]::Now - $script:OrchestrationState.StartTime
        } else {
            [timespan]::Zero
        }

        # Determine status
        $runStatus = if ($status.ChunksFailed -gt 0) {
            if ($status.ChunksComplete -gt 0) { 'PartialFailure' } else { 'Failed' }
        } elseif ($status.ChunksWarning -gt 0) {
            'SuccessWithWarnings'
        } else {
            'Success'
        }

        $lastRun = @{
            Timestamp = ([datetime]::Now).ToString('o')
            ProfilesRun = $profileNames
            ChunksTotal = $status.ChunksTotal
            ChunksCompleted = $status.ChunksComplete
            ChunksFailed = $status.ChunksFailed
            ChunksWarning = $status.ChunksWarning
            BytesCopied = $status.BytesComplete
            FilesCopied = $status.FilesCopied
            FilesFailed = $status.FilesFailed
            Duration = $elapsed.ToString('hh\:mm\:ss')
            Status = $runStatus
        }

        Save-LastRunSummary -Summary $lastRun
    }
    catch {
        Write-GuiLog "Warning: Failed to save last run summary: $_"
    }

    # Generate failed files summary
    # Calculate log root the same way the background runspace does
    $failedFilesSummaryPath = $null
    try {
        if ($status.FilesFailed -gt 0) {
            # Get log root from config, same logic as GuiRunspace.ps1
            $logRoot = if ($script:Config.GlobalSettings.LogPath) { $script:Config.GlobalSettings.LogPath } else { '.\Logs' }
            if (-not [System.IO.Path]::IsPathRooted($logRoot)) {
                $configDir = Split-Path -Parent $script:ConfigPath
                $logRoot = [System.IO.Path]::GetFullPath((Join-Path $configDir $logRoot))
            }
            $dateFolderName = (Get-Date).ToString('yyyy-MM-dd')
            Write-GuiLog "Failed files check: FilesFailed=$($status.FilesFailed), LogRoot=$logRoot, Date=$dateFolderName"
            $failedFilesSummaryPath = New-FailedFilesSummary -LogPath $logRoot -Date $dateFolderName
            if ($failedFilesSummaryPath) {
                Write-GuiLog "Generated failed files summary: $failedFilesSummaryPath"
            }
            else {
                Write-GuiLog "No error entries found in chunk logs"
            }
        }
        else {
            Write-GuiLog "No failed files to summarize"
        }
    }
    catch {
        Write-GuiLog "Warning: Failed to generate failed files summary: $($_.Exception.Message)"
    }

    # Send email notification using shared function
    $emailResult = Send-ReplicationCompletionNotification -Config $script:Config -OrchestrationState $script:OrchestrationState -FailedFilesSummaryPath $failedFilesSummaryPath

    if ($emailResult.Skipped) {
        Write-GuiLog "Email notifications not enabled, skipping"
    }
    elseif ($emailResult.Success) {
        Write-GuiLog "Completion email sent successfully"
    }
    else {
        Write-GuiLog "ERROR: Failed to send completion email: $($emailResult.ErrorMessage)"
    }

    # Gather failed and warning chunk details for the completion dialog
    $failedDetails = @()
    if ($script:OrchestrationState.FailedChunks.Count -gt 0) {
        $failedDetails = @($script:OrchestrationState.FailedChunks.ToArray())
    }
    $warningDetails = @()
    if ($script:OrchestrationState.WarningChunks.Count -gt 0) {
        $warningDetails = @($script:OrchestrationState.WarningChunks.ToArray())
    }

    # Gather pre-flight errors from profile results
    $preflightErrors = @()
    $profileResults = $script:OrchestrationState.GetProfileResultsArray()
    foreach ($pr in $profileResults) {
        if ($pr.PreflightError) {
            $preflightErrors += $pr.PreflightError
        }
    }

    # Show completion dialog (modal - blocks until user clicks OK)
    $dialogFilesCopied = if ($status.FilesCopied) { $status.FilesCopied } else { 0 }
    $dialogFilesSkipped = if ($status.FilesSkipped) { $status.FilesSkipped } else { 0 }
    $dialogFilesFailed = if ($status.FilesFailed) { $status.FilesFailed } else { 0 }
    Show-CompletionDialog -ChunksComplete $status.ChunksComplete -ChunksTotal $status.ChunksTotal -ChunksFailed $status.ChunksFailed -ChunksWarning $status.ChunksWarning -FilesCopied $dialogFilesCopied -FilesSkipped $dialogFilesSkipped -FilesFailed $dialogFilesFailed -FailedFilesSummaryPath $failedFilesSummaryPath -FailedChunkDetails $failedDetails -WarningChunkDetails $warningDetails -PreflightErrors $preflightErrors
}
