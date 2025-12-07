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

    # Create a snapshot of the config to prevent external modifications during replication
    # This ensures the running replication uses the config state at the time of start
    $script:ConfigSnapshotPath = $null
    try {
        $snapshotDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
        $script:ConfigSnapshotPath = Join-Path $snapshotDir "Robocurse-ConfigSnapshot-$([Guid]::NewGuid().ToString('N')).json"
        Copy-Item -Path $script:ConfigPath -Destination $script:ConfigSnapshotPath -Force
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

    # Capture error info from background runspace BEFORE cleanup disposes it
    # (Close-ReplicationRunspace will dispose the PowerShell instance)
    if ($script:ReplicationPowerShell -and $script:ReplicationPowerShell.Streams.Error.Count -gt 0) {
        Write-GuiLog "Background replication encountered errors:"
        foreach ($err in $script:ReplicationPowerShell.Streams.Error) {
            $errorLocation = if ($err.InvocationInfo) {
                "$($err.InvocationInfo.ScriptName):$($err.InvocationInfo.ScriptLineNumber)"
            } else { "Unknown" }
            Write-GuiLog "  [$errorLocation] $($err.Exception.Message)"
        }
    }

    # Delegate to the thread-safe cleanup function (uses Interlocked.Exchange)
    # This prevents race conditions with window close handler
    Close-ReplicationRunspace

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

    # Get final status
    $status = Get-OrchestrationStatus
    Write-GuiLog "Replication completed: $($status.ChunksComplete)/$($status.ChunksTotal) chunks, $($status.ChunksFailed) failed"

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
        $runStatus = if ($status.ChunksFailed -eq 0) {
            'Success'
        } elseif ($status.ChunksComplete -gt 0) {
            'PartialFailure'
        } else {
            'Failed'
        }

        $lastRun = @{
            Timestamp = ([datetime]::Now).ToString('o')
            ProfilesRun = $profileNames
            ChunksTotal = $status.ChunksTotal
            ChunksCompleted = $status.ChunksComplete
            ChunksFailed = $status.ChunksFailed
            BytesCopied = $status.BytesComplete
            Duration = $elapsed.ToString('hh\:mm\:ss')
            Status = $runStatus
        }

        Save-LastRunSummary -Summary $lastRun
    }
    catch {
        Write-GuiLog "Warning: Failed to save last run summary: $_"
    }

    # Send email notification if configured
    try {
        if ($script:Config.Email -and $script:Config.Email.Enabled) {
            Write-GuiLog "Email notifications enabled, attempting to send..."

            # Recalculate values for email (in case previous try block had issues)
            $emailElapsed = if ($script:OrchestrationState -and $script:OrchestrationState.StartTime) {
                [datetime]::Now - $script:OrchestrationState.StartTime
            } else {
                [timespan]::Zero
            }

            $emailProfileNames = @()
            if ($script:OrchestrationState -and $script:OrchestrationState.Profiles) {
                $emailProfileNames = @($script:OrchestrationState.Profiles | ForEach-Object { $_.Name })
            }

            $emailStatus = if ($status.ChunksFailed -eq 0) {
                'Success'
            } elseif ($status.ChunksComplete -gt 0) {
                'PartialFailure'
            } else {
                'Failed'
            }

            # Build results object matching what Send-CompletionEmail expects
            $emailResults = [PSCustomObject]@{
                Duration = $emailElapsed
                TotalBytesCopied = if ($status.BytesComplete) { $status.BytesComplete } else { 0 }
                TotalFilesCopied = if ($status.FilesCopied) { $status.FilesCopied } else { 0 }
                TotalErrors = if ($status.ChunksFailed) { $status.ChunksFailed } else { 0 }
                Profiles = @($emailProfileNames | ForEach-Object {
                    [PSCustomObject]@{
                        Name = $_
                        Status = $emailStatus
                        ChunksComplete = if ($status.ChunksComplete) { $status.ChunksComplete } else { 0 }
                        ChunksTotal = if ($status.ChunksTotal) { $status.ChunksTotal } else { 0 }
                        ChunksFailed = if ($status.ChunksFailed) { $status.ChunksFailed } else { 0 }
                        FilesCopied = if ($status.FilesCopied) { $status.FilesCopied } else { 0 }
                        BytesCopied = if ($status.BytesComplete) { $status.BytesComplete } else { 0 }
                        Errors = @()
                    }
                })
                Errors = @()
            }

            # Get session ID from orchestration state for Message-Id header
            $emailSessionId = if ($script:OrchestrationState) { $script:OrchestrationState.SessionId } else { $null }
            $emailResult = Send-CompletionEmail -Config $script:Config.Email -Results $emailResults -Status $emailStatus -SessionId $emailSessionId

            if ($emailResult.Success) {
                Write-GuiLog "Completion email sent successfully"
            }
            else {
                Write-GuiLog "ERROR: Failed to send completion email: $($emailResult.ErrorMessage)"
            }
        }
        else {
            Write-GuiLog "Email notifications not enabled, skipping"
        }
    }
    catch {
        Write-GuiLog "ERROR: Exception sending completion email: $($_.Exception.Message)"
    }

    # Gather failed chunk details for the completion dialog
    $failedDetails = @()
    if ($script:OrchestrationState.FailedChunks.Count -gt 0) {
        $failedDetails = @($script:OrchestrationState.FailedChunks.ToArray())
    }

    # Show completion dialog (modal - blocks until user clicks OK)
    Show-CompletionDialog -ChunksComplete $status.ChunksComplete -ChunksTotal $status.ChunksTotal -ChunksFailed $status.ChunksFailed -FailedChunkDetails $failedDetails

    # Clean up config snapshot if it was created
    if ($script:ConfigSnapshotPath -and ($script:ConfigSnapshotPath -ne $script:ConfigPath)) {
        try {
            if (Test-Path $script:ConfigSnapshotPath) {
                Remove-Item $script:ConfigSnapshotPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            # Non-critical - temp files will be cleaned up eventually
        }
        $script:ConfigSnapshotPath = $null
    }
}
