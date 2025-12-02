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

    $profileProgress = if ($state.TotalChunks -gt 0) {
        [math]::Round(($state.CompletedCount / $state.TotalChunks) * 100, 1)
    } else { 0 }

    # Calculate overall progress across all profiles
    $totalProfileCount = if ($state.Profiles.Count -gt 0) { $state.Profiles.Count } else { 1 }
    $overallProgress = [math]::Round((($state.ProfileIndex + ($profileProgress / 100)) / $totalProfileCount) * 100, 1)

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
    .OUTPUTS
        TimeSpan estimate or $null if cannot estimate
    #>
    $state = $script:OrchestrationState

    if (-not $state.StartTime -or $state.BytesComplete -eq 0 -or $state.TotalBytes -eq 0) {
        return $null
    }

    $elapsed = [datetime]::Now - $state.StartTime
    $bytesPerSecond = $state.BytesComplete / $elapsed.TotalSeconds

    if ($bytesPerSecond -le 0) {
        return $null
    }

    $bytesRemaining = $state.TotalBytes - $state.BytesComplete
    $secondsRemaining = $bytesRemaining / $bytesPerSecond

    return [timespan]::FromSeconds($secondsRemaining)
}
