# Robocurse GUI Progress Updates
# Real-time progress updates with performance optimizations.

# Cache for GUI progress updates - avoids unnecessary rebuilds
$script:LastGuiUpdateState = $null

# Cache for progress text - avoids unnecessary UpdateLayout() calls
$script:LastProgressTextState = $null

# Per-profile error tracking (reset each run)
$script:ProfileErrorCounts = [System.Collections.Generic.Dictionary[string, int]]::new()

# Error history buffer for clickable error indicator
$script:ErrorHistoryBuffer = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:MaxErrorHistoryItems = 10

function Add-ErrorToHistory {
    <#
    .SYNOPSIS
        Adds an error message to the history buffer with timestamp
    .PARAMETER Message
        The error message to add
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    [System.Threading.Monitor]::Enter($script:ErrorHistoryBuffer)
    try {
        $entry = [PSCustomObject]@{
            Timestamp = [datetime]::Now.ToString('HH:mm:ss')
            Message = $Message
        }

        $script:ErrorHistoryBuffer.Add($entry)

        # Trim to max size
        while ($script:ErrorHistoryBuffer.Count -gt $script:MaxErrorHistoryItems) {
            $script:ErrorHistoryBuffer.RemoveAt(0)
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:ErrorHistoryBuffer)
    }
}

function Update-ErrorIndicatorState {
    <#
    .SYNOPSIS
        Updates the status bar to reflect current error state
    #>
    [CmdletBinding()]
    param()

    if (-not $script:Controls -or -not $script:Controls.txtStatus) {
        return
    }

    if ($script:GuiErrorCount -gt 0) {
        $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::OrangeRed
        $script:Controls.txtStatus.Text = "Replication in progress... ($($script:GuiErrorCount) error(s) - click to view)"
        $script:Controls.txtStatus.Cursor = [System.Windows.Input.Cursors]::Hand
        $script:Controls.txtStatus.TextDecorations = [System.Windows.TextDecorations]::Underline
    } else {
        $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::Gray
        $script:Controls.txtStatus.Cursor = [System.Windows.Input.Cursors]::Arrow
        $script:Controls.txtStatus.TextDecorations = $null
    }
}

function Clear-ErrorHistory {
    <#
    .SYNOPSIS
        Clears the error history buffer and resets error state
    #>
    [CmdletBinding()]
    param()

    [System.Threading.Monitor]::Enter($script:ErrorHistoryBuffer)
    try {
        $script:ErrorHistoryBuffer.Clear()
    }
    finally {
        [System.Threading.Monitor]::Exit($script:ErrorHistoryBuffer)
    }

    $script:GuiErrorCount = 0

    if ($script:Controls -and $script:Controls.txtStatus) {
        $script:Controls.txtStatus.Text = "Replication in progress..."
        $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::Gray
        $script:Controls.txtStatus.Cursor = [System.Windows.Input.Cursors]::Arrow
        $script:Controls.txtStatus.TextDecorations = $null
    }
}

function Reset-ProfileErrorTracking {
    <#
    .SYNOPSIS
        Resets all per-profile error counts
    #>
    [CmdletBinding()]
    param()

    [System.Threading.Monitor]::Enter($script:ProfileErrorCounts)
    try {
        $script:ProfileErrorCounts.Clear()
    }
    finally {
        [System.Threading.Monitor]::Exit($script:ProfileErrorCounts)
    }
}

function Add-ProfileError {
    <#
    .SYNOPSIS
        Increments the error count for a specific profile
    .PARAMETER ProfileName
        Name of the profile to increment error count for
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName
    )

    [System.Threading.Monitor]::Enter($script:ProfileErrorCounts)
    try {
        if (-not $script:ProfileErrorCounts.ContainsKey($ProfileName)) {
            $script:ProfileErrorCounts[$ProfileName] = 0
        }
        $script:ProfileErrorCounts[$ProfileName]++
    }
    finally {
        [System.Threading.Monitor]::Exit($script:ProfileErrorCounts)
    }
}

function Get-ProfileErrorSummary {
    <#
    .SYNOPSIS
        Returns a summary of errors by profile
    .OUTPUTS
        Array of objects with Name and ErrorCount properties
    #>
    [CmdletBinding()]
    param()

    $summary = [System.Collections.Generic.List[PSCustomObject]]::new()

    [System.Threading.Monitor]::Enter($script:ProfileErrorCounts)
    try {
        foreach ($kvp in $script:ProfileErrorCounts.GetEnumerator()) {
            $summary.Add([PSCustomObject]@{
                Name = $kvp.Key
                ErrorCount = $kvp.Value
            })
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:ProfileErrorCounts)
    }

    # Use Write-Output -NoEnumerate to prevent PowerShell array unwrapping
    Write-Output -NoEnumerate $summary.ToArray()
}

function Update-ProfileErrorSummary {
    <#
    .SYNOPSIS
        Updates the profile error summary panel in the progress view
    #>
    [CmdletBinding()]
    param()

    # Check if controls exist
    if (-not $script:Controls -or -not $script:Controls.pnlProfileErrors) {
        return
    }

    # Check if orchestration state exists and has profiles
    if (-not $script:OrchestrationState) {
        $script:Controls.pnlProfileErrors.Visibility = 'Collapsed'
        return
    }

    $profiles = $script:OrchestrationState.Profiles
    $profileCount = if ($profiles) { @($profiles).Count } else { 0 }

    # Only show for 2+ profiles
    if ($profileCount -lt 2) {
        $script:Controls.pnlProfileErrors.Visibility = 'Collapsed'
        return
    }

    # Check if we have any error data
    if ($script:ProfileErrorCounts.Count -eq 0) {
        $script:Controls.pnlProfileErrors.Visibility = 'Collapsed'
        return
    }

    $script:Controls.pnlProfileErrors.Visibility = 'Visible'
    $panel = $script:Controls.pnlProfileErrorItems

    if (-not $panel) { return }

    $panel.Children.Clear()

    foreach ($profile in $profiles) {
        $errorCount = 0
        if ($script:ProfileErrorCounts.ContainsKey($profile.Name)) {
            $errorCount = $script:ProfileErrorCounts[$profile.Name]
        }

        # Create pill-style indicator
        $border = New-Object System.Windows.Controls.Border
        $border.CornerRadius = [System.Windows.CornerRadius]::new(12)
        $border.Padding = [System.Windows.Thickness]::new(10, 4, 10, 4)
        $border.Margin = [System.Windows.Thickness]::new(0, 0, 8, 4)

        # Color based on error count
        if ($errorCount -eq 0) {
            $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#2D4A2D")
        } else {
            $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#4A2D2D")
        }

        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.Orientation = 'Horizontal'

        $nameText = New-Object System.Windows.Controls.TextBlock
        $nameText.Text = $profile.Name
        $nameText.Foreground = [System.Windows.Media.Brushes]::White
        $nameText.FontSize = 11
        $nameText.VerticalAlignment = 'Center'

        $countText = New-Object System.Windows.Controls.TextBlock
        $countText.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
        $countText.FontWeight = 'Bold'
        $countText.FontSize = 11
        $countText.VerticalAlignment = 'Center'

        if ($errorCount -eq 0) {
            $countText.Text = [char]0x2713
            $countText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#4CAF50")
        } else {
            $countText.Text = $errorCount.ToString()
            $countText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF6B6B")
        }

        $stack.Children.Add($nameText)
        $stack.Children.Add($countText)
        $border.Child = $stack

        $panel.Children.Add($border)
    }

    if ($script:Window) {
        $script:Window.UpdateLayout()
    }
}

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

        PERFORMANCE OPTIMIZATION: Only call UpdateLayout() when values actually change.
        This reduces CPU usage from ~5% to <1% during idle replication periods.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Status
    )

    # Capture values for comparison and display
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

    # During scanning/preparing phases, show item count instead of chunk count
    $chunksText = if ($Status.Phase -in @('Preparing', 'Scanning') -and $Status.ScanProgress -gt 0) {
        "Items: $($Status.ScanProgress)"
    } else {
        "Chunks: $($Status.ChunksComplete)/$($Status.ChunksTotal)"
    }

    # Build current state for comparison
    $currentState = @{
        ProfileProgress = $profileProgress
        OverallProgress = $overallProgress
        ProfileName = $profileName
        EtaText = $etaText
        SpeedText = $speedText
        ChunksText = $chunksText
    }

    # Check if anything changed (skip UpdateLayout if nothing changed)
    $hasChanged = $false
    if (-not $script:LastProgressTextState) {
        $hasChanged = $true
    }
    elseif ($script:LastProgressTextState.ProfileProgress -ne $currentState.ProfileProgress -or
            $script:LastProgressTextState.OverallProgress -ne $currentState.OverallProgress -or
            $script:LastProgressTextState.ProfileName -ne $currentState.ProfileName -or
            $script:LastProgressTextState.EtaText -ne $currentState.EtaText -or
            $script:LastProgressTextState.SpeedText -ne $currentState.SpeedText -or
            $script:LastProgressTextState.ChunksText -ne $currentState.ChunksText) {
        $hasChanged = $true
    }

    if ($hasChanged) {
        # Direct assignment
        $script:Controls.pbProfile.Value = $profileProgress
        $script:Controls.pbOverall.Value = $overallProgress
        $script:Controls.txtProfileProgress.Text = "Profile: $profileName - $profileProgress%"
        $script:Controls.txtOverallProgress.Text = "Overall: $overallProgress%"
        $script:Controls.txtEta.Text = $etaText
        $script:Controls.txtSpeed.Text = $speedText
        $script:Controls.txtChunks.Text = $chunksText

        # Force complete window layout update (only when values changed)
        $script:Window.UpdateLayout()

        # Cache the current state
        $script:LastProgressTextState = $currentState
    }
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

    # Show current activity during Preparing/Scanning/Cleanup phases
    $currentActivity = $script:OrchestrationState.CurrentActivity
    $phase = $script:OrchestrationState.Phase
    if ($currentActivity -and ($phase -in @('Preparing', 'Scanning', 'Cleanup'))) {
        $scanProgress = $script:OrchestrationState.ScanProgress
        $displayStatus = if ($phase -eq 'Cleanup') { 'Cleanup' } elseif ($phase -eq 'Preparing') { 'Preparing' } else { 'Scanning' }
        $chunkDisplayItems.Add([PSCustomObject]@{
            ChunkId = "--"
            SourcePath = $currentActivity
            Status = $displayStatus
            Progress = $scanProgress
            ProgressScale = [double]0  # No bar during preparing/scanning
            Speed = "--"
        })
    }

    # 1. RUNNING JOBS AT TOP (most important - actively copying)
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
                # Calculate speed from bytes copied over elapsed time (average since chunk start)
                $elapsedSeconds = ([datetime]::Now - $job.StartTime).TotalSeconds
                if ($elapsedSeconds -gt 0 -and $progressData.BytesCopied -gt 0) {
                    $bytesPerSecond = $progressData.BytesCopied / $elapsedSeconds
                    $speed = "$(Format-FileSize $bytesPerSecond)/s"
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

    # 2. PENDING CHUNKS (first N with summary)
    $pendingSnapshot = $script:OrchestrationState.ChunkQueue.ToArray()
    $pendingToShow = [Math]::Min($pendingSnapshot.Length, 10)
    for ($i = 0; $i -lt $pendingToShow; $i++) {
        $chunk = $pendingSnapshot[$i]
        $chunkDisplayItems.Add([PSCustomObject]@{
            ChunkId = $chunk.ChunkId
            SourcePath = $chunk.SourcePath
            Status = "Pending"
            Progress = 0
            ProgressScale = [double]0
            Speed = "--"
        })
    }
    if ($pendingSnapshot.Length -gt $pendingToShow) {
        $chunkDisplayItems.Add([PSCustomObject]@{
            ChunkId = "--"
            SourcePath = "... and $($pendingSnapshot.Length - $pendingToShow) more pending"
            Status = "Pending"
            Progress = 0
            ProgressScale = [double]0
            Speed = "--"
        })
    }

    # 3. FAILED CHUNKS (show all - usually small or indicates problems)
    foreach ($chunk in $script:OrchestrationState.FailedChunks.ToArray()) {
        $chunkDisplayItems.Add([PSCustomObject]@{
            ChunkId = $chunk.ChunkId
            SourcePath = $chunk.SourcePath
            DestinationPath = $chunk.DestinationPath
            Status = "Failed"
            Progress = 0
            ProgressScale = [double]0.0
            Speed = "--"
            RetryCount = $chunk.RetryCount
            LastExitCode = $chunk.LastExitCode
            LastErrorMessage = $chunk.LastErrorMessage
        })
    }

    # 4. COMPLETED CHUNKS - show ALL (user requested full list)
    $completedSnapshot = $script:OrchestrationState.CompletedChunks.ToArray()
    foreach ($chunk in $completedSnapshot) {
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
        CurrentActivity = $script:OrchestrationState.CurrentActivity
        ScanProgress = $script:OrchestrationState.ScanProgress
    }

    $needsRebuild = $false
    if (-not $script:LastGuiUpdateState) {
        $needsRebuild = $true
    }
    elseif ($script:LastGuiUpdateState.ActiveCount -ne $currentState.ActiveCount -or
            $script:LastGuiUpdateState.CompletedCount -ne $currentState.CompletedCount -or
            $script:LastGuiUpdateState.FailedCount -ne $currentState.FailedCount -or
            $script:LastGuiUpdateState.CurrentActivity -ne $currentState.CurrentActivity -or
            $script:LastGuiUpdateState.ScanProgress -ne $currentState.ScanProgress) {
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
        # BytesComplete is updated by the background thread in Invoke-ReplicationTick
        $status = Get-OrchestrationStatus

        # Update progress text (always - lightweight)
        Update-GuiProgressText -Status $status

        # Note: Background stream flushing moved to Complete-GuiReplication
        # which waits for the async handle to complete before flushing

        # Dequeue errors (thread-safe) and update error indicator
        if ($script:OrchestrationState) {
            $errors = $script:OrchestrationState.DequeueErrors()
            foreach ($err in $errors) {
                Write-GuiLog "[ERROR] $err"
                Add-ErrorToHistory -Message $err
                $script:GuiErrorCount++

                # Track error against current profile
                $currentProfile = $script:OrchestrationState.CurrentProfile
                if ($currentProfile -and $currentProfile.Name) {
                    Add-ProfileError -ProfileName $currentProfile.Name
                }
            }

            # Dequeue and display background log messages (thread-safe)
            # Filter by MinLogLevel to match GUI's log level setting
            # Check if method exists (handles mock objects in tests)
            $logs = @()
            if ($script:OrchestrationState.PSObject.Methods['DequeueLogs']) {
                $logs = $script:OrchestrationState.DequeueLogs()
            }
            foreach ($log in $logs) {
                # Parse log level from formatted entry: "2025-12-21 HH:MM:SS [LEVEL] ..."
                if ($log -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[(\w+)\]') {
                    $logLevel = $Matches[1]
                    # Only display if log level passes the filter
                    if (Test-ShouldLog -Level $logLevel) {
                        Write-Host $log
                    }
                }
                else {
                    # If we can't parse level, show it anyway
                    Write-Host $log
                }
            }

            # Update status bar with error indicator if errors occurred
            if ($script:GuiErrorCount -gt 0) {
                $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::OrangeRed
                $script:Controls.txtStatus.Text = "Replication in progress... ($($script:GuiErrorCount) error(s))"
                Update-ErrorIndicatorState
                Update-ProfileErrorSummary
            }
            # Show preparing/scanning/cleanup activity in status bar
            elseif ($script:OrchestrationState.Phase -in @('Preparing', 'Scanning', 'Cleanup') -and $script:OrchestrationState.CurrentActivity) {
                $counter = $script:OrchestrationState.ScanProgress
                $activity = $script:OrchestrationState.CurrentActivity
                $newText = if ($counter -gt 0) { "$activity ($counter)" } else { $activity }
                $script:Controls.txtStatus.Text = $newText
                $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::CornflowerBlue
                $script:Window.UpdateLayout()
            }
            # Show replication progress during active copying
            elseif ($script:OrchestrationState.Phase -eq 'Replicating') {
                $completed = $script:OrchestrationState.CompletedCount
                $total = $script:OrchestrationState.TotalChunks
                $script:Controls.txtStatus.Text = "Replicating... ($completed/$total chunks)"
                $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::LimeGreen
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

        # Check if complete or stopped
        if ($status.Phase -in @('Complete', 'Stopped')) {
            Complete-GuiReplication
        }
    }
    catch {
        Write-Host "[ERROR] Error updating progress: $_"
        Write-GuiLog "Error updating progress: $_"
    }
}

function Show-ProgressEmptyState {
    <#
    .SYNOPSIS
        Displays the progress panel empty state (last run summary or ready message)
    .DESCRIPTION
        When no replication is active, shows a summary of the last completed run.
        If no previous run exists, shows a "ready to run" message.
    #>
    [CmdletBinding()]
    param()

    try {
        # Check if controls exist
        if (-not $script:Controls -or -not $script:Controls['txtProfileProgress']) {
            Write-Verbose "Progress controls not available for empty state display"
            return
        }

        $lastRun = Get-LastRunSummary

        if (-not $lastRun) {
            # No previous runs - show ready state
            if ($script:Controls['txtProfileProgress']) { $script:Controls['txtProfileProgress'].Text = "No previous runs" }
            if ($script:Controls['txtOverallProgress']) { $script:Controls['txtOverallProgress'].Text = "Select profiles and click Run" }
            if ($script:Controls['pbProfile']) { $script:Controls['pbProfile'].Value = 0 }
            if ($script:Controls['pbOverall']) { $script:Controls['pbOverall'].Value = 0 }
            if ($script:Controls['txtEta']) { $script:Controls['txtEta'].Text = "Ready" }
            if ($script:Controls['txtSpeed']) { $script:Controls['txtSpeed'].Text = "--" }
            if ($script:Controls['txtChunks']) { $script:Controls['txtChunks'].Text = "Ready" }
            if ($script:Controls['dgChunks']) { $script:Controls['dgChunks'].ItemsSource = $null }
        } else {
            # Show last run summary
            $timestamp = [datetime]::Parse($lastRun.Timestamp)
            $timeAgo = Get-TimeAgoString -Timestamp $timestamp

            # Format profile names
            $profileNames = if ($lastRun.ProfilesRun -is [array]) {
                $lastRun.ProfilesRun -join ", "
            } else {
                $lastRun.ProfilesRun
            }
            if ($script:Controls['txtProfileProgress']) { $script:Controls['txtProfileProgress'].Text = "Last: $profileNames" }

            # Calculate completion percentage
            $completionPct = if ($lastRun.ChunksTotal -gt 0) {
                [math]::Round(($lastRun.ChunksCompleted / $lastRun.ChunksTotal) * 100, 0)
            } else {
                0
            }

            # Set status text with color
            $statusText = "$($lastRun.Status) - $timeAgo"
            if ($script:Controls['txtOverallProgress']) { $script:Controls['txtOverallProgress'].Text = $statusText }

            # Set color based on status (only if WPF is available)
            try {
                $colorBrush = switch ($lastRun.Status) {
                    'Success' { [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0x00, 0xFF, 0x7F)) }  # LimeGreen
                    'PartialFailure' { [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0xFF, 0xB3, 0x40)) }  # Orange
                    'Failed' { [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0xFF, 0x6B, 0x6B)) }  # Red
                    default { [System.Windows.Media.Brushes]::Gray }
                }
                if ($script:Controls['txtOverallProgress']) { $script:Controls['txtOverallProgress'].Foreground = $colorBrush }
            }
            catch {
                # WPF types not available (headless/test mode) - skip color setting
                Write-Verbose "WPF color types not available - skipping color assignment"
            }

            # Set progress bars
            if ($script:Controls['pbProfile']) { $script:Controls['pbProfile'].Value = $completionPct }
            if ($script:Controls['pbOverall']) { $script:Controls['pbOverall'].Value = $completionPct }

            # Set duration and bytes copied
            if ($script:Controls['txtEta']) { $script:Controls['txtEta'].Text = "Duration: $($lastRun.Duration)" }
            if ($script:Controls['txtSpeed']) { $script:Controls['txtSpeed'].Text = "Copied: $(Format-FileSize -Bytes $lastRun.BytesCopied)" }

            # Set chunks text
            $chunksText = "Chunks: $($lastRun.ChunksCompleted)/$($lastRun.ChunksTotal)"
            if ($lastRun.ChunksFailed -gt 0) {
                $chunksText += " ($($lastRun.ChunksFailed) failed)"
            }
            if ($script:Controls['txtChunks']) { $script:Controls['txtChunks'].Text = $chunksText }

            # Clear the chunks grid
            if ($script:Controls['dgChunks']) { $script:Controls['dgChunks'].ItemsSource = $null }
        }

        # Force visual update
        if ($script:Window) { $script:Window.UpdateLayout() }
    }
    catch {
        Write-GuiLog "Error displaying empty state: $_"
    }
}

function Get-TimeAgoString {
    <#
    .SYNOPSIS
        Formats a timestamp as a "time ago" string
    .PARAMETER Timestamp
        DateTime to format
    .OUTPUTS
        String like "2 hours ago", "5 minutes ago", etc.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$Timestamp
    )

    $elapsed = [datetime]::Now - $Timestamp

    if ($elapsed.TotalDays -ge 1) {
        $days = [math]::Floor($elapsed.TotalDays)
        return "$days day$(if ($days -ne 1) {'s'}) ago"
    }
    elseif ($elapsed.TotalHours -ge 1) {
        $hours = [math]::Floor($elapsed.TotalHours)
        return "$hours hour$(if ($hours -ne 1) {'s'}) ago"
    }
    elseif ($elapsed.TotalMinutes -ge 1) {
        $minutes = [math]::Floor($elapsed.TotalMinutes)
        return "$minutes minute$(if ($minutes -ne 1) {'s'}) ago"
    }
    else {
        return "Just now"
    }
}
