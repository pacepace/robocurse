# Robocurse Checkpoint Functions
# Handles checkpoint/resume functionality for crash recovery

$script:CheckpointFileName = "robocurse-checkpoint.json"

function Get-CheckpointPath {
    <#
    .SYNOPSIS
        Returns the checkpoint file path based on log directory
    .DESCRIPTION
        Uses the log directory if available, otherwise falls back to TEMP directory.
        This ensures checkpoints are always written to a writable location.
    .OUTPUTS
        Path to checkpoint file
    #>
    [CmdletBinding()]
    param()

    $logDir = if ($script:CurrentOperationalLogPath) {
        Split-Path $script:CurrentOperationalLogPath -Parent
    } else {
        # Fall back to TEMP directory instead of current directory
        # Current directory may be read-only or unexpected (e.g., system32)
        if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
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

        # Use atomic replacement with backup - prevents data loss on crash
        # Note: .NET Framework (PowerShell 5.1) doesn't support File.Move overwrite parameter
        $backupPath = "$checkpointPath.bak"
        if (Test-Path $checkpointPath) {
            # Move existing to backup first (atomic on same volume)
            if (Test-Path $backupPath) {
                Remove-Item -Path $backupPath -Force
            }
            [System.IO.File]::Move($checkpointPath, $backupPath)
        }
        # Now move temp to final (if this fails, we still have the backup)
        [System.IO.File]::Move($tempPath, $checkpointPath)
        # Clean up backup after successful replacement
        if (Test-Path $backupPath) {
            Remove-Item -Path $backupPath -Force -ErrorAction SilentlyContinue
        }

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

function New-CompletedPathsHashSet {
    <#
    .SYNOPSIS
        Creates a HashSet from checkpoint completed paths for O(1) lookups
    .DESCRIPTION
        Converts the CompletedChunkPaths array from a checkpoint into a case-insensitive
        HashSet for efficient lookups. This improves resume performance from O(N) to O(1)
        per chunk lookup, which is critical when resuming with thousands of completed chunks.
    .PARAMETER Checkpoint
        Checkpoint object from Get-ReplicationCheckpoint
    .OUTPUTS
        HashSet[string] with case-insensitive comparison, or $null if no checkpoint
    .EXAMPLE
        $hashSet = New-CompletedPathsHashSet -Checkpoint $checkpoint
        if ($hashSet -and $hashSet.Contains($path)) { "Already done" }
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject]$Checkpoint
    )

    if (-not $Checkpoint -or -not $Checkpoint.CompletedChunkPaths) {
        return $null
    }

    # Create case-insensitive HashSet for O(1) lookups
    # OrdinalIgnoreCase handles international characters correctly (including Turkish 'I')
    $hashSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($path in $Checkpoint.CompletedChunkPaths) {
        if ($path) {
            $hashSet.Add($path) | Out-Null
        }
    }

    Write-RobocurseLog -Message "Created HashSet with $($hashSet.Count) completed chunk paths for O(1) resume lookups" `
        -Level 'Debug' -Component 'Checkpoint'

    return $hashSet
}

function Test-ChunkAlreadyCompleted {
    <#
    .SYNOPSIS
        Checks if a chunk was completed in a previous run
    .DESCRIPTION
        Determines whether a specific chunk has already been successfully replicated in a previous
        run by checking against checkpoint data. Supports both O(1) HashSet lookups (preferred) and
        O(N) linear search (backwards compatibility). Used during resume operations to skip chunks
        that don't need to be re-replicated.
    .PARAMETER Chunk
        Chunk object to check
    .PARAMETER Checkpoint
        Checkpoint object from previous run
    .PARAMETER CompletedPathsHashSet
        Optional pre-built HashSet for O(1) lookups. If not provided, falls back to
        O(N) linear search (for backwards compatibility).
    .OUTPUTS
        $true if chunk should be skipped, $false otherwise
    .NOTES
        For best performance when checking many chunks, use New-CompletedPathsHashSet
        to create the HashSet once, then pass it to each call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Chunk,

        [PSCustomObject]$Checkpoint,

        [System.Collections.Generic.HashSet[string]]$CompletedPathsHashSet
    )

    if (-not $Checkpoint -or -not $Checkpoint.CompletedChunkPaths) {
        return $false
    }

    # Guard against null SourcePath
    if (-not $Chunk.SourcePath) {
        return $false
    }

    $chunkPath = $Chunk.SourcePath

    # Use HashSet if provided for O(1) lookup
    if ($CompletedPathsHashSet) {
        return $CompletedPathsHashSet.Contains($chunkPath)
    }

    # Fallback to O(N) linear search for backwards compatibility
    # This path is used when CompletedPathsHashSet is not provided
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
