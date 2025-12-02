# Robocurse Checkpoint Functions
# Handles checkpoint/resume functionality for crash recovery

$script:CheckpointFileName = "robocurse-checkpoint.json"

function Get-CheckpointPath {
    <#
    .SYNOPSIS
        Returns the checkpoint file path based on log directory
    .OUTPUTS
        Path to checkpoint file
    #>
    $logDir = if ($script:CurrentLogPath) {
        Split-Path $script:CurrentLogPath -Parent
    } else {
        "."
    }
    return Join-Path $logDir $script:CheckpointFileName
}

function Save-ReplicationCheckpoint {
    <#
    .SYNOPSIS
        Saves current replication progress to a checkpoint file
    .DESCRIPTION
        Persists the current state of replication to disk, allowing
        resumption after a crash or interruption. Saves:
        - Session ID
        - Profile index and name
        - Completed chunk paths (for skipping on resume)
        - Start time
        - Profiles configuration
    .PARAMETER Force
        Overwrite existing checkpoint without confirmation
    .OUTPUTS
        OperationResult indicating success/failure
    #>
    param(
        [switch]$Force
    )

    if (-not $script:OrchestrationState) {
        return New-OperationResult -Success $false -ErrorMessage "No orchestration state to checkpoint"
    }

    $state = $script:OrchestrationState

    try {
        # Build list of completed chunk paths for skip detection on resume
        $completedPaths = @()
        foreach ($chunk in $state.CompletedChunks.ToArray()) {
            $completedPaths += $chunk.SourcePath
        }

        $checkpoint = [PSCustomObject]@{
            Version = "1.0"
            SessionId = $state.SessionId
            SavedAt = (Get-Date).ToString('o')
            ProfileIndex = $state.ProfileIndex
            CurrentProfileName = if ($state.CurrentProfile) { $state.CurrentProfile.Name } else { "" }
            CompletedChunkPaths = $completedPaths
            CompletedCount = $state.CompletedCount
            FailedCount = $state.FailedChunks.Count
            BytesComplete = $state.BytesComplete
            StartTime = if ($state.StartTime) { $state.StartTime.ToString('o') } else { $null }
        }

        $checkpointPath = Get-CheckpointPath

        # Create directory if needed
        $checkpointDir = Split-Path $checkpointPath -Parent
        if ($checkpointDir -and -not (Test-Path $checkpointDir)) {
            New-Item -ItemType Directory -Path $checkpointDir -Force | Out-Null
        }

        $checkpoint | ConvertTo-Json -Depth 5 | Set-Content -Path $checkpointPath -Encoding UTF8

        Write-RobocurseLog -Message "Checkpoint saved: $($completedPaths.Count) chunks completed" `
            -Level 'Info' -Component 'Checkpoint'

        return New-OperationResult -Success $true -Data $checkpointPath
    }
    catch {
        Write-RobocurseLog -Message "Failed to save checkpoint: $($_.Exception.Message)" `
            -Level 'Error' -Component 'Checkpoint'
        return New-OperationResult -Success $false -ErrorMessage "Failed to save checkpoint: $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Get-ReplicationCheckpoint {
    <#
    .SYNOPSIS
        Loads a checkpoint file if one exists
    .OUTPUTS
        Checkpoint object or $null if no checkpoint exists
    #>

    $checkpointPath = Get-CheckpointPath

    if (-not (Test-Path $checkpointPath)) {
        return $null
    }

    try {
        $content = Get-Content -Path $checkpointPath -Raw -Encoding UTF8
        $checkpoint = $content | ConvertFrom-Json

        Write-RobocurseLog -Message "Found checkpoint: $($checkpoint.CompletedChunkPaths.Count) chunks completed at $($checkpoint.SavedAt)" `
            -Level 'Info' -Component 'Checkpoint'

        return $checkpoint
    }
    catch {
        Write-RobocurseLog -Message "Failed to load checkpoint: $($_.Exception.Message)" `
            -Level 'Warning' -Component 'Checkpoint'
        return $null
    }
}

function Remove-ReplicationCheckpoint {
    <#
    .SYNOPSIS
        Removes the checkpoint file after successful completion
    .OUTPUTS
        $true if removed, $false otherwise
    #>

    $checkpointPath = Get-CheckpointPath

    if (Test-Path $checkpointPath) {
        try {
            Remove-Item -Path $checkpointPath -Force
            Write-RobocurseLog -Message "Checkpoint file removed (replication complete)" `
                -Level 'Debug' -Component 'Checkpoint'
            return $true
        }
        catch {
            Write-RobocurseLog -Message "Failed to remove checkpoint file: $($_.Exception.Message)" `
                -Level 'Warning' -Component 'Checkpoint'
        }
    }
    return $false
}

function Test-ChunkAlreadyCompleted {
    <#
    .SYNOPSIS
        Checks if a chunk was completed in a previous run
    .PARAMETER Chunk
        Chunk object to check
    .PARAMETER Checkpoint
        Checkpoint object from previous run
    .OUTPUTS
        $true if chunk should be skipped, $false otherwise
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Chunk,

        [PSCustomObject]$Checkpoint
    )

    if (-not $Checkpoint -or -not $Checkpoint.CompletedChunkPaths) {
        return $false
    }

    # Guard against null SourcePath
    if (-not $Chunk.SourcePath) {
        return $false
    }

    # Case-insensitive check for Windows paths
    $normalizedChunkPath = $Chunk.SourcePath.ToLowerInvariant()
    foreach ($completedPath in $Checkpoint.CompletedChunkPaths) {
        # Skip null entries in the completed paths array
        if (-not $completedPath) {
            continue
        }
        if ($completedPath.ToLowerInvariant() -eq $normalizedChunkPath) {
            return $true
        }
    }

    return $false
}
