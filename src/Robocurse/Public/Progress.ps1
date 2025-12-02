# Robocurse Progress Functions
function Update-ProgressStats {
    <#
    .SYNOPSIS
        Updates progress statistics from active jobs
    .DESCRIPTION
        Uses the cumulative CompletedChunkBytes counter for O(1) completed bytes lookup
        instead of iterating the CompletedChunks queue (which could be O(n) with 10,000+ chunks).
        Only active jobs need to be iterated for in-progress bytes.
    #>
    [CmdletBinding()]
    param()

    $state = $script:OrchestrationState

    # Get cumulative bytes from completed chunks (O(1) - pre-calculated counter)
    $bytesFromCompleted = $state.CompletedChunkBytes

    # Snapshot ActiveJobs for safe iteration (typically < MaxConcurrentJobs, so small)
    $bytesFromActive = 0
    foreach ($kvp in $state.ActiveJobs.ToArray()) {
        $progress = Get-RobocopyProgress -Job $kvp.Value
        if ($progress) {
            $bytesFromActive += $progress.BytesCopied
        }
    }

    $state.BytesComplete = $bytesFromCompleted + $bytesFromActive
}

function Get-OrchestrationStatus {
    <#
    .SYNOPSIS
        Returns current orchestration status for GUI
    .OUTPUTS
        PSCustomObject with all status info
    #>
    [CmdletBinding()]
    param()

    # Handle case where orchestration hasn't been initialized yet
    if (-not $script:OrchestrationState) {
        return [PSCustomObject]@{
            Phase = 'Idle'
            Elapsed = [timespan]::Zero
            ETA = $null
            CurrentProfile = ""
            ProfileProgress = 0
            OverallProgress = 0
            BytesComplete = 0
            FilesCopied = 0
            ChunksTotal = 0
            ChunksComplete = 0
            ChunksFailed = 0
            ActiveJobCount = 0
            ErrorCount = 0
        }
    }

    $state = $script:OrchestrationState

    $elapsed = if ($state.StartTime) {
        [datetime]::Now - $state.StartTime
    } else { [timespan]::Zero }

    $eta = Get-ETAEstimate

    $currentProfileName = if ($state.CurrentProfile) { $state.CurrentProfile.Name } else { "" }

    # Clamp progress to 0-100 range to handle edge cases where CompletedCount > TotalChunks
    # (can happen if files are added during scan or other race conditions)
    $profileProgress = if ($state.TotalChunks -gt 0) {
        [math]::Min(100, [math]::Max(0, [math]::Round(($state.CompletedCount / $state.TotalChunks) * 100, 1)))
    } else { 0 }

    # Calculate overall progress across all profiles (also clamped)
    $totalProfileCount = if ($state.Profiles.Count -gt 0) { $state.Profiles.Count } else { 1 }
    $overallProgress = [math]::Min(100, [math]::Max(0,
        [math]::Round((($state.ProfileIndex + ($profileProgress / 100)) / $totalProfileCount) * 100, 1)))

    return [PSCustomObject]@{
        Phase = $state.Phase
        CurrentProfile = $currentProfileName
        ProfileProgress = $profileProgress
        OverallProgress = $overallProgress
        ChunksComplete = $state.CompletedCount
        ChunksTotal = $state.TotalChunks
        ChunksFailed = $state.FailedChunks.Count
        BytesComplete = $state.BytesComplete
        BytesTotal = $state.TotalBytes
        FilesCopied = $state.CompletedChunkFiles
        Elapsed = $elapsed
        ETA = $eta
        ActiveJobs = $state.ActiveJobs.Count
        QueuedJobs = $state.ChunkQueue.Count
    }
}

function Get-ETAEstimate {
    <#
    .SYNOPSIS
        Estimates completion time based on current progress
    .DESCRIPTION
        Calculates ETA based on bytes copied per second. Includes safeguards
        against integer overflow and division by zero edge cases.
    .OUTPUTS
        TimeSpan estimate or $null if cannot estimate
    #>
    [CmdletBinding()]
    param()

    $state = $script:OrchestrationState

    if (-not $state.StartTime -or $state.BytesComplete -eq 0 -or $state.TotalBytes -eq 0) {
        return $null
    }

    $elapsed = [datetime]::Now - $state.StartTime

    # Guard against division by zero (can happen if called immediately after start)
    if ($elapsed.TotalSeconds -lt 0.001) {
        return $null
    }

    # Cast to double to prevent integer overflow with large byte counts
    [double]$bytesComplete = $state.BytesComplete
    [double]$totalBytes = $state.TotalBytes
    [double]$elapsedSeconds = $elapsed.TotalSeconds

    # Guard against unreasonably large values that could cause overflow
    # Max reasonable bytes: 100 PB (should cover any realistic scenario)
    $maxBytes = [double](100 * 1PB)
    if ($bytesComplete -gt $maxBytes -or $totalBytes -gt $maxBytes) {
        return $null
    }

    $bytesPerSecond = $bytesComplete / $elapsedSeconds

    # Guard against very slow speeds that would result in unreasonable ETA
    # Minimum 1 byte per second to prevent near-infinite ETA
    if ($bytesPerSecond -lt 1.0) {
        return $null
    }

    $bytesRemaining = $totalBytes - $bytesComplete

    # Handle case where more bytes copied than expected (file sizes changed during copy)
    if ($bytesRemaining -le 0) {
        return [timespan]::Zero
    }

    $secondsRemaining = $bytesRemaining / $bytesPerSecond

    # Cap at reasonable maximum (30 days) to prevent overflow
    $maxSeconds = 30.0 * 24.0 * 60.0 * 60.0
    if ($secondsRemaining -gt $maxSeconds -or [double]::IsInfinity($secondsRemaining) -or [double]::IsNaN($secondsRemaining)) {
        $secondsRemaining = $maxSeconds
    }

    # Ensure value fits in Int32 range before casting (defensive programming)
    $safeSeconds = [Math]::Min($secondsRemaining, [int]::MaxValue)
    return [timespan]::FromSeconds([int]$safeSeconds)
}
