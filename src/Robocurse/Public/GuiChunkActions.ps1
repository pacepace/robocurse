# Robocurse GUI Chunk Actions
# Context menu actions for failed chunks in the DataGrid

function Invoke-ChunkRetry {
    <#
    .SYNOPSIS
        Retries a failed chunk by moving it back to the chunk queue
    .DESCRIPTION
        Removes the chunk from FailedChunks, resets its status and retry count,
        and adds it back to the ChunkQueue for reprocessing. This allows users
        to manually retry chunks that failed due to transient errors.
    .PARAMETER ChunkId
        The ID of the chunk to retry
    .NOTES
        ConcurrentQueue does not have a Remove method, so we drain and rebuild
        the queue excluding the target chunk. This is safe because this function
        runs on the GUI thread while the background orchestration thread only
        dequeues from the queue.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$ChunkId
    )

    if (-not $script:OrchestrationState) {
        Write-GuiLog "Cannot retry chunk: No orchestration state available"
        return
    }

    # Find and remove chunk from FailedChunks
    $failedChunks = $script:OrchestrationState.FailedChunks.ToArray()
    $targetChunk = $failedChunks | Where-Object { $_.ChunkId -eq $ChunkId }

    if (-not $targetChunk) {
        Write-GuiLog "Cannot retry chunk $ChunkId - chunk not found in failed chunks"
        return
    }

    # Drain and rebuild FailedChunks without the target chunk
    $remainingChunks = @()
    while ($script:OrchestrationState.FailedChunks.TryDequeue([ref]$null)) {
        # Drain all items
    }
    foreach ($chunk in $failedChunks) {
        if ($chunk.ChunkId -ne $ChunkId) {
            $script:OrchestrationState.FailedChunks.Enqueue($chunk)
        }
    }

    # Reset chunk state for retry
    $targetChunk.Status = 'Pending'
    $targetChunk.RetryCount = 0
    # Clear error details from previous attempt
    if ($targetChunk.PSObject.Properties['LastExitCode']) {
        $targetChunk.PSObject.Properties.Remove('LastExitCode')
    }
    if ($targetChunk.PSObject.Properties['LastErrorMessage']) {
        $targetChunk.PSObject.Properties.Remove('LastErrorMessage')
    }

    # Add back to chunk queue
    $script:OrchestrationState.ChunkQueue.Enqueue($targetChunk)

    Write-GuiLog "Chunk $ChunkId moved from failed to pending queue for retry"
    Write-RobocurseLog -Level 'Info' -Component 'GUI' -Message "User triggered retry for chunk $ChunkId"
    Write-SiemEvent -EventType 'ChunkWarning' -Data @{
        ChunkId = $ChunkId
        SourcePath = $targetChunk.SourcePath
        DestinationPath = $targetChunk.DestinationPath
        Action = 'UserRetry'
        Message = "User manually retried chunk $ChunkId"
    }
}

function Invoke-ChunkSkip {
    <#
    .SYNOPSIS
        Skips a failed chunk by removing it from the failed queue
    .DESCRIPTION
        Removes the chunk from FailedChunks and marks its status as 'Skipped'.
        The chunk will not be retried or displayed in the failed chunks list.
        This allows users to manually skip chunks that are known to be problematic
        or not critical to the overall replication.
    .PARAMETER ChunkId
        The ID of the chunk to skip
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$ChunkId
    )

    if (-not $script:OrchestrationState) {
        Write-GuiLog "Cannot skip chunk: No orchestration state available"
        return
    }

    # Find and remove chunk from FailedChunks
    $failedChunks = $script:OrchestrationState.FailedChunks.ToArray()
    $targetChunk = $failedChunks | Where-Object { $_.ChunkId -eq $ChunkId }

    if (-not $targetChunk) {
        Write-GuiLog "Cannot skip chunk $ChunkId - chunk not found in failed chunks"
        return
    }

    # Drain and rebuild FailedChunks without the target chunk
    while ($script:OrchestrationState.FailedChunks.TryDequeue([ref]$null)) {
        # Drain all items
    }
    foreach ($chunk in $failedChunks) {
        if ($chunk.ChunkId -ne $ChunkId) {
            $script:OrchestrationState.FailedChunks.Enqueue($chunk)
        }
    }

    # Mark chunk as skipped
    $targetChunk.Status = 'Skipped'

    Write-GuiLog "Chunk $ChunkId removed from failed queue and marked as skipped"
    Write-RobocurseLog -Level 'Info' -Component 'GUI' -Message "User skipped chunk $ChunkId"
    Write-SiemEvent -EventType 'ChunkWarning' -Data @{
        ChunkId = $ChunkId
        SourcePath = $targetChunk.SourcePath
        DestinationPath = $targetChunk.DestinationPath
        Action = 'UserSkip'
        Message = "User manually skipped chunk $ChunkId"
    }
}

function Open-ChunkLog {
    <#
    .SYNOPSIS
        Opens the log file for a specific chunk
    .DESCRIPTION
        Uses Start-Process to open the chunk's log file in the default text editor.
        If the log file doesn't exist, shows an error message.
    .PARAMETER LogPath
        Full path to the chunk log file
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$LogPath
    )

    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        Write-GuiLog "Cannot open log: Log path is empty"
        Show-AlertDialog -Title "Cannot Open Log" `
            -Message "Log path is not available for this chunk." -Icon Warning
        return
    }

    if (-not (Test-Path -Path $LogPath -PathType Leaf)) {
        Write-GuiLog "Cannot open log: File not found at $LogPath"
        Show-AlertDialog -Title "Cannot Open Log" `
            -Message "Log file not found:`n$LogPath" -Icon Warning
        return
    }

    try {
        Start-Process -FilePath $LogPath
        Write-GuiLog "Opened chunk log: $LogPath"
        Write-RobocurseLog -Level 'Debug' -Component 'GUI' -Message "User opened chunk log file: $LogPath"
    }
    catch {
        Write-GuiLog "Failed to open log file: $_"
        Show-AlertDialog -Title "Error Opening Log" `
            -Message "Failed to open log file:`n$($_.Exception.Message)" -Icon Error
    }
}
