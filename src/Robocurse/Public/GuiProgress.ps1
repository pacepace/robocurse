# Robocurse GUI Progress Updates
# Real-time progress updates with performance optimizations.

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
