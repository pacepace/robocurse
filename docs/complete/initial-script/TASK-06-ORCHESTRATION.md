# Task 06: Job Orchestration

## Overview
Implement the orchestration layer that manages multiple parallel robocopy jobs, handles completion/failure, retries, and coordinates profile execution.

## Research Required

### Web Research
- PowerShell job queue patterns
- Process pool management
- Timer-based polling vs event-driven approaches
- Thread-safe collections in PowerShell

### Key Concepts
- **Job Queue**: Pending chunks waiting to run
- **Active Jobs**: Currently running robocopy processes
- **Completed/Failed**: Finished jobs with results
- **Throttling**: Max concurrent jobs limit

## Task Description

### State Object
```powershell
$script:OrchestrationState = [PSCustomObject]@{
    SessionId        = ""
    CurrentProfile   = $null
    Phase            = "Idle"  # Idle, Scanning, Replicating, Complete
    Profiles         = @()     # All profiles to process
    ProfileIndex     = 0       # Current profile index

    # Current profile state
    ChunkQueue       = [System.Collections.Generic.Queue[PSCustomObject]]::new()
    ActiveJobs       = [System.Collections.Generic.Dictionary[int,PSCustomObject]]::new()  # ProcessId -> Job
    CompletedChunks  = [System.Collections.Generic.List[PSCustomObject]]::new()
    FailedChunks     = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Statistics
    TotalChunks      = 0
    CompletedCount   = 0
    TotalBytes       = 0
    BytesComplete    = 0
    StartTime        = $null
    ProfileStartTime = $null

    # Control
    StopRequested    = $false
    PauseRequested   = $false
}
```

### Function: Start-ReplicationRun
```powershell
function Start-ReplicationRun {
    <#
    .SYNOPSIS
        Starts replication for specified profiles
    .PARAMETER Profiles
        Array of profile objects from config
    .PARAMETER MaxConcurrentJobs
        Maximum parallel robocopy processes
    .PARAMETER OnProgress
        Scriptblock called on progress updates
    .PARAMETER OnChunkComplete
        Scriptblock called when chunk finishes
    .PARAMETER OnProfileComplete
        Scriptblock called when profile finishes
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject[]]$Profiles,

        [int]$MaxConcurrentJobs = 4,

        [scriptblock]$OnProgress,
        [scriptblock]$OnChunkComplete,
        [scriptblock]$OnProfileComplete
    )

    # Initialize state
    # For each profile:
    #   1. Create VSS snapshot if needed
    #   2. Scan and chunk
    #   3. Queue chunks
    #   4. Process queue
    #   5. Cleanup VSS
    # Send completion notification
}
```

### Function: Start-ProfileReplication
```powershell
function Start-ProfileReplication {
    <#
    .SYNOPSIS
        Starts replication for a single profile
    .PARAMETER Profile
        Profile object from config
    .PARAMETER MaxConcurrentJobs
        Maximum parallel processes
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,

        [int]$MaxConcurrentJobs = 4
    )

    # 1. Validate paths
    # 2. Create VSS snapshot if UseVSS
    # 3. Scan source (using VSS path if applicable)
    # 4. Generate chunks
    # 5. Initialize queue
    # 6. Start processing
}
```

### Function: Invoke-ReplicationTick
```powershell
function Invoke-ReplicationTick {
    <#
    .SYNOPSIS
        Called periodically (by timer) to manage job queue
    .DESCRIPTION
        - Checks for completed jobs
        - Starts new jobs if capacity available
        - Updates progress
        - Handles profile transitions
    .PARAMETER MaxConcurrentJobs
        Maximum concurrent jobs
    #>
    param(
        [int]$MaxConcurrentJobs = 4
    )

    $state = $script:OrchestrationState

    # Check for stop/pause requests
    if ($state.StopRequested) {
        Stop-AllJobs
        return
    }

    if ($state.PauseRequested) {
        return  # Don't start new jobs, but let running ones complete
    }

    # Check completed jobs
    $completedIds = @()
    foreach ($kvp in $state.ActiveJobs.GetEnumerator()) {
        $job = $kvp.Value
        if ($job.Process.HasExited) {
            # Process completion
            $result = Complete-RobocopyJob -Job $job
            $completedIds += $kvp.Key

            if ($result.ExitMeaning.Severity -in @('Error', 'Fatal')) {
                Handle-FailedChunk -Job $job -Result $result
            }
            else {
                $state.CompletedChunks.Add($job.Chunk)
            }
            $state.CompletedCount++

            # Invoke callback
            if ($script:OnChunkComplete) {
                & $script:OnChunkComplete $job $result
            }
        }
    }

    # Remove completed from active
    foreach ($id in $completedIds) {
        $state.ActiveJobs.Remove($id)
    }

    # Start new jobs
    while (($state.ActiveJobs.Count -lt $MaxConcurrentJobs) -and
           ($state.ChunkQueue.Count -gt 0)) {
        $chunk = $state.ChunkQueue.Dequeue()
        $job = Start-ChunkJob -Chunk $chunk
        $state.ActiveJobs[$job.Process.Id] = $job
    }

    # Check if profile complete
    if (($state.ChunkQueue.Count -eq 0) -and ($state.ActiveJobs.Count -eq 0)) {
        Complete-CurrentProfile
    }

    # Update progress
    Update-ProgressStats
}
```

### Function: Complete-RobocopyJob
```powershell
function Complete-RobocopyJob {
    <#
    .SYNOPSIS
        Processes a completed robocopy job
    .PARAMETER Job
        Job object that has finished
    .OUTPUTS
        Result object with exit code, stats, etc.
    #>
    param(
        [PSCustomObject]$Job
    )

    $exitCode = $Job.Process.ExitCode
    $exitMeaning = Get-RobocopyExitMeaning -ExitCode $exitCode
    $stats = Parse-RobocopyLog -LogPath $Job.LogPath
    $duration = [datetime]::Now - $Job.StartTime

    # Update chunk status
    $Job.Chunk.Status = switch ($exitMeaning.Severity) {
        'Success' { 'Complete' }
        'Warning' { 'CompleteWithWarnings' }
        'Error'   { 'Failed' }
        'Fatal'   { 'Failed' }
    }

    # Log result
    Write-RobocurseLog -Message "Chunk $($Job.Chunk.ChunkId) completed: $($exitMeaning.Message)" `
        -Level $(if ($exitMeaning.Severity -eq 'Success') { 'Info' } else { 'Warning' }) `
        -Component 'Orchestrator'

    # Write SIEM event
    Write-SiemEvent -EventType 'ChunkComplete' -Data @{
        chunkId = $Job.Chunk.ChunkId
        source = $Job.Chunk.SourcePath
        destination = $Job.Chunk.DestinationPath
        exitCode = $exitCode
        severity = $exitMeaning.Severity
        filesCopied = $stats.FilesCopied
        bytesCopied = $stats.BytesCopied
        durationMs = $duration.TotalMilliseconds
    }

    return [PSCustomObject]@{
        Job = $Job
        ExitCode = $exitCode
        ExitMeaning = $exitMeaning
        Stats = $stats
        Duration = $duration
    }
}
```

### Function: Handle-FailedChunk
```powershell
function Handle-FailedChunk {
    <#
    .SYNOPSIS
        Handles a failed chunk - retry or mark failed
    .PARAMETER Job
        Failed job
    .PARAMETER Result
        Result from Complete-RobocopyJob
    #>
    param(
        [PSCustomObject]$Job,
        [PSCustomObject]$Result
    )

    $chunk = $Job.Chunk

    # Check retry count
    if (-not $chunk.RetryCount) { $chunk.RetryCount = 0 }
    $chunk.RetryCount++

    if ($chunk.RetryCount -lt 3 -and $Result.ExitMeaning.ShouldRetry) {
        # Re-queue for retry
        Write-RobocurseLog -Message "Chunk $($chunk.ChunkId) failed, retrying ($($chunk.RetryCount)/3)" `
            -Level 'Warning' -Component 'Orchestrator'

        $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
    }
    else {
        # Mark as failed
        $chunk.Status = 'Failed'
        $script:OrchestrationState.FailedChunks.Add($chunk)

        Write-RobocurseLog -Message "Chunk $($chunk.ChunkId) failed permanently after $($chunk.RetryCount) attempts" `
            -Level 'Error' -Component 'Orchestrator'

        Write-SiemEvent -EventType 'ChunkError' -Data @{
            chunkId = $chunk.ChunkId
            source = $chunk.SourcePath
            retryCount = $chunk.RetryCount
            exitCode = $Result.ExitCode
        }
    }
}
```

### Function: Stop-AllJobs
```powershell
function Stop-AllJobs {
    <#
    .SYNOPSIS
        Stops all running robocopy processes
    #>
    $state = $script:OrchestrationState

    foreach ($job in $state.ActiveJobs.Values) {
        if (-not $job.Process.HasExited) {
            $job.Process.Kill()
            Write-RobocurseLog -Message "Killed chunk $($job.Chunk.ChunkId)" -Level 'Warning' -Component 'Orchestrator'
        }
    }

    $state.ActiveJobs.Clear()
    $state.Phase = "Stopped"
}
```

### Function: Request-Stop
```powershell
function Request-Stop {
    <#
    .SYNOPSIS
        Requests graceful stop (finish current jobs, don't start new)
    #>
    $script:OrchestrationState.StopRequested = $true
}
```

### Function: Request-Pause
```powershell
function Request-Pause {
    <#
    .SYNOPSIS
        Pauses job queue (running jobs continue, no new starts)
    #>
    $script:OrchestrationState.PauseRequested = $true
}
```

### Function: Request-Resume
```powershell
function Request-Resume {
    <#
    .SYNOPSIS
        Resumes paused job queue
    #>
    $script:OrchestrationState.PauseRequested = $false
}
```

### Function: Update-ProgressStats
```powershell
function Update-ProgressStats {
    <#
    .SYNOPSIS
        Updates progress statistics from active jobs
    #>
    $state = $script:OrchestrationState

    # Calculate bytes complete from completed chunks + in-progress
    $bytesFromCompleted = ($state.CompletedChunks | Measure-Object -Property EstimatedSize -Sum).Sum
    $bytesFromActive = 0

    foreach ($job in $state.ActiveJobs.Values) {
        $progress = Get-RobocopyProgress -Job $job
        if ($progress) {
            $bytesFromActive += $progress.BytesCopied
        }
    }

    $state.BytesComplete = $bytesFromCompleted + $bytesFromActive
}
```

### Function: Get-OrchestrationStatus
```powershell
function Get-OrchestrationStatus {
    <#
    .SYNOPSIS
        Returns current orchestration status for GUI
    .OUTPUTS
        PSCustomObject with all status info
    #>
    $state = $script:OrchestrationState

    $elapsed = if ($state.StartTime) {
        [datetime]::Now - $state.StartTime
    } else { [timespan]::Zero }

    $eta = Get-ETAEstimate

    return [PSCustomObject]@{
        Phase = $state.Phase
        CurrentProfile = $state.CurrentProfile.Name
        ProfileProgress = if ($state.TotalChunks -gt 0) {
            [math]::Round(($state.CompletedCount / $state.TotalChunks) * 100, 1)
        } else { 0 }
        OverallProgress = # Calculate across all profiles
        ChunksComplete = $state.CompletedCount
        ChunksTotal = $state.TotalChunks
        ChunksFailed = $state.FailedChunks.Count
        BytesComplete = $state.BytesComplete
        BytesTotal = $state.TotalBytes
        Elapsed = $elapsed
        ETA = $eta
        ActiveJobs = $state.ActiveJobs.Count
        QueuedJobs = $state.ChunkQueue.Count
    }
}
```

## Success Criteria

1. [ ] Jobs run in parallel up to max concurrent limit
2. [ ] Completed jobs are detected and processed
3. [ ] Failed jobs are retried up to 3 times
4. [ ] Stop request kills running jobs
5. [ ] Pause request stops new job starts
6. [ ] Progress stats are accurate
7. [ ] Profile transitions work correctly
8. [ ] SIEM events logged for all state changes

## Pester Tests Required

Create `tests/Unit/Orchestration.Tests.ps1`:

```powershell
Describe "Orchestration" {
    BeforeAll {
        . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
    }

    BeforeEach {
        # Reset state
        $script:OrchestrationState = [PSCustomObject]@{
            ChunkQueue = [System.Collections.Generic.Queue[PSCustomObject]]::new()
            ActiveJobs = [System.Collections.Generic.Dictionary[int,PSCustomObject]]::new()
            CompletedChunks = [System.Collections.Generic.List[PSCustomObject]]::new()
            FailedChunks = [System.Collections.Generic.List[PSCustomObject]]::new()
            TotalChunks = 0
            CompletedCount = 0
            StopRequested = $false
            PauseRequested = $false
        }
    }

    Context "Invoke-ReplicationTick" {
        It "Should start jobs up to max concurrent" {
            # Add chunks to queue
            1..10 | ForEach-Object {
                $chunk = [PSCustomObject]@{ ChunkId = $_; SourcePath = "C:\Test$_" }
                $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
            }
            $script:OrchestrationState.TotalChunks = 10

            Mock Start-ChunkJob {
                param($Chunk)
                $mockProcess = [PSCustomObject]@{
                    Id = Get-Random
                    HasExited = $false
                }
                [PSCustomObject]@{ Process = $mockProcess; Chunk = $Chunk }
            }

            Invoke-ReplicationTick -MaxConcurrentJobs 4

            $script:OrchestrationState.ActiveJobs.Count | Should -Be 4
            $script:OrchestrationState.ChunkQueue.Count | Should -Be 6
        }

        It "Should not start new jobs when paused" {
            $chunk = [PSCustomObject]@{ ChunkId = 1; SourcePath = "C:\Test" }
            $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
            $script:OrchestrationState.PauseRequested = $true

            Mock Start-ChunkJob { }

            Invoke-ReplicationTick -MaxConcurrentJobs 4

            Should -Not -Invoke Start-ChunkJob
        }
    }

    Context "Handle-FailedChunk" {
        It "Should retry failed chunk up to 3 times" {
            $chunk = [PSCustomObject]@{ ChunkId = 1; SourcePath = "C:\Test"; RetryCount = 0 }
            $job = [PSCustomObject]@{ Chunk = $chunk }
            $result = [PSCustomObject]@{
                ExitCode = 8
                ExitMeaning = [PSCustomObject]@{ Severity = 'Error'; ShouldRetry = $true }
            }

            Handle-FailedChunk -Job $job -Result $result

            $script:OrchestrationState.ChunkQueue.Count | Should -Be 1
            $chunk.RetryCount | Should -Be 1
        }

        It "Should mark as failed after max retries" {
            $chunk = [PSCustomObject]@{ ChunkId = 1; SourcePath = "C:\Test"; RetryCount = 2 }
            $job = [PSCustomObject]@{ Chunk = $chunk }
            $result = [PSCustomObject]@{
                ExitCode = 8
                ExitMeaning = [PSCustomObject]@{ Severity = 'Error'; ShouldRetry = $true }
            }

            Handle-FailedChunk -Job $job -Result $result

            $script:OrchestrationState.FailedChunks.Count | Should -Be 1
            $script:OrchestrationState.ChunkQueue.Count | Should -Be 0
        }
    }

    Context "Stop-AllJobs" {
        It "Should kill all running processes" {
            $mockProcess1 = [PSCustomObject]@{ HasExited = $false }
            $mockProcess1 | Add-Member -MemberType ScriptMethod -Name Kill -Value { $this.HasExited = $true }

            $mockProcess2 = [PSCustomObject]@{ HasExited = $false }
            $mockProcess2 | Add-Member -MemberType ScriptMethod -Name Kill -Value { $this.HasExited = $true }

            $script:OrchestrationState.ActiveJobs[1] = @{ Process = $mockProcess1; Chunk = @{ ChunkId = 1 } }
            $script:OrchestrationState.ActiveJobs[2] = @{ Process = $mockProcess2; Chunk = @{ ChunkId = 2 } }

            Stop-AllJobs

            $mockProcess1.HasExited | Should -Be $true
            $mockProcess2.HasExited | Should -Be $true
            $script:OrchestrationState.ActiveJobs.Count | Should -Be 0
        }
    }
}
```

## Dependencies
- Task 00 (Project Structure)
- Task 02 (Logging)
- Task 04 (Chunking)
- Task 05 (Robocopy Wrapper)

## Estimated Complexity
- High
- State management, parallel processing, error handling
