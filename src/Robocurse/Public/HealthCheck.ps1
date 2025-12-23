# Robocurse Health Check Functions
# Health monitoring endpoint for external monitoring systems
#
# This module provides health check functionality:
# - JSON status file for monitoring tools
# - Staleness detection for hung process detection
# - Atomic writes to prevent partial reads

# Track last health check update time
$script:LastHealthCheckUpdate = $null

function Write-HealthCheckStatus {
    <#
    .SYNOPSIS
        Writes current orchestration status to a JSON file for external monitoring
    .DESCRIPTION
        Creates a health check file that can be read by external monitoring systems
        to track the status of running replication jobs. The file includes:
        - Current phase (Idle, Profiling, Replicating, Complete, Stopped)
        - Active job count and queue depth
        - Progress statistics (chunks completed, bytes copied)
        - Current profile being processed
        - Last update timestamp
        - ETA estimate

        The file is written atomically to prevent partial reads.
    .PARAMETER Force
        Write immediately regardless of interval setting
    .OUTPUTS
        OperationResult - Success=$true if file written, Success=$false with ErrorMessage on failure
    .EXAMPLE
        Write-HealthCheckStatus
        # Updates health file if interval has elapsed
    .EXAMPLE
        Write-HealthCheckStatus -Force
        # Updates health file immediately
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    # Check if enough time has elapsed since last update
    $now = [datetime]::Now
    if (-not $Force -and $script:LastHealthCheckUpdate) {
        $elapsed = ($now - $script:LastHealthCheckUpdate).TotalSeconds
        if ($elapsed -lt $script:HealthCheckIntervalSeconds) {
            return New-OperationResult -Success $true -Data "Skipped - interval not elapsed"
        }
    }

    try {
        $state = $script:OrchestrationState
        if ($null -eq $state) {
            # No orchestration state - write idle status
            $healthStatus = [PSCustomObject]@{
                Timestamp = $now.ToString('o')
                Phase = 'Idle'
                CurrentProfile = $null
                ProfileIndex = 0
                ProfileCount = 0
                ChunksCompleted = 0
                ChunksTotal = 0
                ChunksPending = 0
                ChunksFailed = 0
                ActiveJobs = 0
                BytesCompleted = 0
                EtaSeconds = $null
                SessionId = $null
                Healthy = $true
                Message = 'No active replication'
            }
        }
        else {
            # Get ETA estimate
            $eta = Get-ETAEstimate
            $etaSeconds = if ($eta) { [int]$eta.TotalSeconds } else { $null }

            # Calculate health status
            $failedCount = $state.FailedChunks.Count
            $isHealthy = $state.Phase -ne 'Stopped' -and $failedCount -eq 0

            $healthStatus = [PSCustomObject]@{
                Timestamp = $now.ToString('o')
                Phase = $state.Phase
                CurrentProfile = if ($state.CurrentProfile) { $state.CurrentProfile.Name } else { $null }
                ProfileIndex = $state.ProfileIndex
                ProfileCount = if ($state.Profiles) { $state.Profiles.Count } else { 0 }
                ChunksCompleted = $state.CompletedCount
                ChunksTotal = $state.TotalChunks
                ChunksPending = $state.ChunkQueue.Count
                ChunksFailed = $failedCount
                ActiveJobs = $state.ActiveJobs.Count
                BytesCompleted = $state.BytesComplete
                EtaSeconds = $etaSeconds
                SessionId = $state.SessionId
                Healthy = $isHealthy
                Message = if (-not $isHealthy) {
                    if ($state.Phase -eq 'Stopped') { 'Replication stopped' }
                    elseif ($failedCount -gt 0) { "$failedCount chunks failed" }
                    else { 'OK' }
                } else { 'OK' }
            }
        }

        # Write atomically by writing to temp file then renaming
        $tempPath = "$($script:HealthCheckStatusFile).tmp"
        $healthStatus | ConvertTo-Json -Depth 5 | Set-Content -Path $tempPath -Encoding UTF8

        # Rename is atomic on most filesystems
        Move-Item -Path $tempPath -Destination $script:HealthCheckStatusFile -Force

        $script:LastHealthCheckUpdate = $now

        return New-OperationResult -Success $true -Data $script:HealthCheckStatusFile
    }
    catch {
        Write-RobocurseLog -Message "Failed to write health check status: $($_.Exception.Message)" -Level 'Warning' -Component 'Health'
        return New-OperationResult -Success $false -ErrorMessage "Failed to write health check: $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Get-HealthCheckStatus {
    <#
    .SYNOPSIS
        Reads the health check status file with staleness detection
    .DESCRIPTION
        Reads and returns the current health check status from the JSON file.
        Useful for external monitoring scripts or GUI status checks.

        When MaxAgeSeconds is specified, the function checks if the status file
        is stale (older than the specified age). This is useful for detecting
        hung or crashed replication processes that stopped updating the health file.
    .PARAMETER MaxAgeSeconds
        Maximum age in seconds before the status is considered stale.
        If the status file's Timestamp is older than this, the returned
        object will have IsStale=$true and Healthy=$false.
        Default: 0 (no staleness check)
    .OUTPUTS
        PSCustomObject with health status, or $null if file doesn't exist.
        When MaxAgeSeconds is specified, includes additional properties:
        - IsStale: $true if the status file is older than MaxAgeSeconds
        - StaleSeconds: How many seconds over the threshold (if stale)
    .EXAMPLE
        $status = Get-HealthCheckStatus
        if ($status -and -not $status.Healthy) {
            Send-Alert "Robocurse issue: $($status.Message)"
        }
    .EXAMPLE
        # Check for staleness (e.g., if health updates should occur every 30s)
        $status = Get-HealthCheckStatus -MaxAgeSeconds 90
        if ($status.IsStale) {
            Send-Alert "Robocurse may be hung - no health update for $($status.StaleSeconds)s"
        }
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxAgeSeconds = 0
    )

    if (-not (Test-Path $script:HealthCheckStatusFile)) {
        return $null
    }

    try {
        $content = Get-Content -Path $script:HealthCheckStatusFile -Raw -ErrorAction Stop
        $status = $content | ConvertFrom-Json

        # Add staleness detection if MaxAgeSeconds specified
        if ($MaxAgeSeconds -gt 0 -and $status.Timestamp) {
            $lastUpdate = [datetime]::Parse($status.Timestamp)
            $ageSeconds = ([datetime]::Now - $lastUpdate).TotalSeconds

            # Add staleness properties
            $status | Add-Member -NotePropertyName 'IsStale' -NotePropertyValue ($ageSeconds -gt $MaxAgeSeconds) -Force
            $status | Add-Member -NotePropertyName 'AgeSeconds' -NotePropertyValue ([int]$ageSeconds) -Force

            if ($status.IsStale) {
                $status | Add-Member -NotePropertyName 'StaleSeconds' -NotePropertyValue ([int]($ageSeconds - $MaxAgeSeconds)) -Force
                # Override Healthy to false if stale
                $status.Healthy = $false
                $status.Message = "Health check stale (no update for $([int]$ageSeconds)s, threshold: ${MaxAgeSeconds}s)"
            }
        }
        else {
            $status | Add-Member -NotePropertyName 'IsStale' -NotePropertyValue $false -Force
            $status | Add-Member -NotePropertyName 'AgeSeconds' -NotePropertyValue 0 -Force
        }

        return $status
    }
    catch {
        Write-RobocurseLog -Message "Failed to read health check status: $($_.Exception.Message)" -Level 'Warning' -Component 'Health'
        return $null
    }
}

function Remove-HealthCheckStatus {
    <#
    .SYNOPSIS
        Removes the health check status file
    .DESCRIPTION
        Cleans up the health check file when replication is complete or on shutdown.
    .EXAMPLE
        Remove-HealthCheckStatus
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (Test-Path $script:HealthCheckStatusFile) {
        if ($PSCmdlet.ShouldProcess($script:HealthCheckStatusFile, "Remove health check status file")) {
            try {
                Remove-Item -Path $script:HealthCheckStatusFile -Force -ErrorAction Stop
                Write-RobocurseLog -Message "Removed health check status file" -Level 'Debug' -Component 'Health'
            }
            catch {
                Write-RobocurseLog -Message "Failed to remove health check status file: $($_.Exception.Message)" -Level 'Warning' -Component 'Health'
            }
        }
    }

    $script:LastHealthCheckUpdate = $null
}
