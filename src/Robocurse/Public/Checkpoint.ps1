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
    [CmdletBinding()]
    param()

    $logDir = if ($script:CurrentOperationalLogPath) {
        Split-Path $script:CurrentOperationalLogPath -Parent
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
    [CmdletBinding()]
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

        # Atomic write: write to temp file first, then rename
        # This prevents corruption if the process crashes during write
        $tempPath = "$checkpointPath.tmp"
        $checkpoint | ConvertTo-Json -Depth 5 | Set-Content -Path $tempPath -Encoding UTF8

        # Use .NET File.Move with overwrite for atomic replacement
        # This avoids TOCTOU race between Test-Path/Remove-Item/Move-Item
        # On NTFS, this is an atomic operation
        [System.IO.File]::Move($tempPath, $checkpointPath, $true)

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
    [CmdletBinding()]
    param()

    $checkpointPath = Get-CheckpointPath

    if (-not (Test-Path $checkpointPath)) {
        return $null
    }

    try {
        $content = Get-Content -Path $checkpointPath -Raw -Encoding UTF8
        $checkpoint = $content | ConvertFrom-Json

        # Validate checkpoint version for forward compatibility
        $expectedVersion = "1.0"
        if ($checkpoint.Version -and $checkpoint.Version -ne $expectedVersion) {
            Write-RobocurseLog -Message "Checkpoint version mismatch: found '$($checkpoint.Version)', expected '$expectedVersion'. Starting fresh." `
                -Level 'Warning' -Component 'Checkpoint'
            return $null
        }

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
    .EXAMPLE
        Remove-ReplicationCheckpoint -WhatIf
        # Shows what would be removed without actually deleting
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $checkpointPath = Get-CheckpointPath

    if (Test-Path $checkpointPath) {
        if ($PSCmdlet.ShouldProcess($checkpointPath, "Remove checkpoint file")) {
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
    [CmdletBinding()]
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

    # Normalize the chunk path for comparison
    # Use OrdinalIgnoreCase for Windows-style case-insensitivity
    # This is more reliable than ToLowerInvariant() for international characters
    # and handles edge cases like Turkish 'I' correctly
    $chunkPath = $Chunk.SourcePath

    foreach ($completedPath in $Checkpoint.CompletedChunkPaths) {
        # Skip null entries in the completed paths array
        if (-not $completedPath) {
            continue
        }
        if ([string]::Equals($completedPath, $chunkPath, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}
