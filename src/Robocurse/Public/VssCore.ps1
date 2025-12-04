# Robocurse VSS Core Functions
# Shared infrastructure for both local and remote VSS operations

# Path to track active VSS snapshots (for orphan cleanup)
# Handle cross-platform: TEMP on Windows, TMPDIR on macOS, /tmp fallback
$script:VssTempDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { "/tmp" }
$script:VssTrackingFile = Join-Path $script:VssTempDir "Robocurse-VSS-Tracking.json"

# Shared retryable HRESULT codes for VSS operations (language-independent)
$script:VssRetryableHResults = @(
    0x8004230F,  # VSS_E_INSUFFICIENT_STORAGE - Insufficient storage (might clear up)
    0x80042316,  # VSS_E_SNAPSHOT_SET_IN_PROGRESS - Another snapshot operation in progress
    0x80042302,  # VSS_E_OBJECT_NOT_FOUND - Object not found (transient state)
    0x80042317,  # VSS_E_MAXIMUM_NUMBER_OF_VOLUMES_REACHED - Might clear after cleanup
    0x8004231F,  # VSS_E_WRITERERROR_TIMEOUT - Writer timeout
    0x80042325   # VSS_E_FLUSH_WRITES_TIMEOUT - Flush timeout
)

# Shared retryable patterns for VSS errors (English fallback for errors without HRESULT)
$script:VssRetryablePatterns = @(
    'busy',
    'timeout',
    'lock',
    'in use',
    'try again'
)

function Test-VssErrorRetryable {
    <#
    .SYNOPSIS
        Determines if a VSS error is retryable (transient failure)
    .DESCRIPTION
        Checks error messages and HRESULT codes to determine if a VSS operation
        failure is transient and should be retried. Uses language-independent
        HRESULT codes where possible, with English pattern fallback.

        Non-retryable errors include: invalid path, permissions, VSS not supported
        Retryable errors include: VSS busy, lock contention, timeout, storage issues
    .PARAMETER ErrorMessage
        The error message string to check
    .PARAMETER HResult
        Optional HRESULT code (as integer) to check
    .OUTPUTS
        Boolean - $true if the error is retryable, $false otherwise
    .EXAMPLE
        if (Test-VssErrorRetryable -ErrorMessage $result.ErrorMessage) {
            # Retry the operation
        }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ErrorMessage,

        [int]$HResult = 0
    )

    # Check HRESULT code first (language-independent)
    if ($HResult -ne 0 -and $HResult -in $script:VssRetryableHResults) {
        return $true
    }

    # Check for HRESULT patterns in error message (e.g., "0x8004230F")
    foreach ($code in $script:VssRetryableHResults) {
        $hexPattern = "0x{0:X8}" -f $code
        if ($ErrorMessage -match $hexPattern) {
            return $true
        }
    }

    # Check English fallback patterns
    foreach ($pattern in $script:VssRetryablePatterns) {
        if ($ErrorMessage -match $pattern) {
            return $true
        }
    }

    return $false
}

function Invoke-WithVssTrackingMutex {
    <#
    .SYNOPSIS
        Executes a scriptblock while holding the VSS tracking file mutex
    .DESCRIPTION
        Acquires a named mutex to synchronize access to the VSS tracking file
        across multiple processes. Releases the mutex in a finally block to
        ensure cleanup even on errors.
    .PARAMETER ScriptBlock
        Code to execute while holding the mutex
    .PARAMETER TimeoutMs
        Milliseconds to wait for mutex acquisition (default: 10000)
    .OUTPUTS
        Result of the scriptblock, or $null if mutex acquisition times out
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [int]$TimeoutMs = 10000
    )

    $mutex = $null
    $mutexAcquired = $false
    try {
        # Include session ID in mutex name to isolate different user sessions
        # This prevents DoS attacks on multi-user systems where another user
        # could create the mutex first
        $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $mutexName = "Global\RobocurseVssTracking_Session$sessionId"
        $mutex = [System.Threading.Mutex]::new($false, $mutexName)

        $mutexAcquired = $mutex.WaitOne($TimeoutMs)
        if (-not $mutexAcquired) {
            Write-RobocurseLog -Message "Timeout waiting for VSS tracking file lock" -Level 'Warning' -Component 'VSS'
            return $null
        }

        return & $ScriptBlock
    }
    finally {
        if ($mutex) {
            if ($mutexAcquired) {
                try { $mutex.ReleaseMutex() } catch {
                    # Log release failures - may indicate logic bugs (releasing unowned mutex)
                    Write-RobocurseLog -Message "Failed to release VSS tracking mutex: $($_.Exception.Message)" -Level 'Warning' -Component 'VSS'
                }
            }
            $mutex.Dispose()
        }
    }
}

function Test-VssPrivileges {
    <#
    .SYNOPSIS
        Checks if the current session has privileges required for VSS operations
    .DESCRIPTION
        VSS snapshot creation requires Administrator privileges on Windows.
        This function performs a preflight check to verify privileges before
        attempting VSS operations that would otherwise fail.

        Also checks that the VSS service is running.
    .OUTPUTS
        OperationResult - Success=$true if all checks pass, Success=$false with details on failure
    .EXAMPLE
        $check = Test-VssPrivileges
        if (-not $check.Success) {
            Write-Warning "VSS not available: $($check.ErrorMessage)"
        }
    #>
    [CmdletBinding()]
    param()

    # Skip if not Windows
    if (-not (Test-IsWindowsPlatform)) {
        return New-OperationResult -Success $false -ErrorMessage "VSS is only available on Windows platforms"
    }

    $issues = @()

    # Check for Administrator privileges
    try {
        $currentPrincipal = [System.Security.Principal.WindowsPrincipal]::new(
            [System.Security.Principal.WindowsIdentity]::GetCurrent()
        )
        $isAdmin = $currentPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

        if (-not $isAdmin) {
            $issues += "Administrator privileges required for VSS operations. Run PowerShell as Administrator."
        }
    }
    catch {
        $issues += "Unable to check administrator privileges: $($_.Exception.Message)"
    }

    # Check if VSS service is running
    try {
        $vssService = Get-Service -Name 'VSS' -ErrorAction SilentlyContinue
        if ($null -eq $vssService) {
            $issues += "VSS (Volume Shadow Copy) service not found"
        }
        elseif ($vssService.Status -ne 'Running') {
            # VSS service is demand-start, so not running is OK - it will start when needed
            # But if it's disabled, that's a problem
            if ($vssService.StartType -eq 'Disabled') {
                $issues += "VSS service is disabled. Enable it via services.msc or: Set-Service -Name VSS -StartupType Manual"
            }
        }
    }
    catch {
        $issues += "Unable to check VSS service status: $($_.Exception.Message)"
    }

    if ($issues.Count -gt 0) {
        $errorMsg = $issues -join "; "
        Write-RobocurseLog -Message "VSS privilege check failed: $errorMsg" -Level 'Warning' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage $errorMsg
    }

    Write-RobocurseLog -Message "VSS privilege check passed" -Level 'Debug' -Component 'VSS'
    return New-OperationResult -Success $true -Data "All VSS prerequisites met"
}

function Test-VssStorageQuota {
    <#
    .SYNOPSIS
        Checks if there is sufficient VSS storage quota available for a new snapshot
    .DESCRIPTION
        Queries the VSS shadow storage settings for the specified volume to determine:
        - Maximum allocated storage for shadow copies
        - Currently used storage
        - Available storage for new snapshots

        This pre-flight check can prevent snapshot failures due to storage exhaustion.
        By default, Windows uses 10% of the volume for shadow storage.
    .PARAMETER Volume
        Volume to check (e.g., "C:" or "D:")
    .PARAMETER MinimumFreePercent
        Minimum free storage percentage required (default: 10%)
    .OUTPUTS
        OperationResult with:
        - Success=$true if sufficient storage available
        - Success=$false with details if storage is low or check fails
        - Data contains storage details (MaxSizeMB, UsedSizeMB, FreePercent)
    .EXAMPLE
        $check = Test-VssStorageQuota -Volume "C:"
        if (-not $check.Success) {
            Write-Warning "VSS storage low: $($check.ErrorMessage)"
        }
    .NOTES
        Requires Administrator privileges to query VSS storage settings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]:$')]
        [string]$Volume,

        [ValidateRange(1, 50)]
        [int]$MinimumFreePercent = 10
    )

    # Skip if not Windows
    if (-not (Test-IsWindowsPlatform)) {
        return New-OperationResult -Success $false -ErrorMessage "VSS is only available on Windows platforms"
    }

    try {
        # Query shadow storage settings using CIM (more reliable than vssadmin parsing)
        $volumeWithSlash = "${Volume}\"

        # Get shadow storage info from Win32_ShadowStorage
        $shadowStorage = Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction SilentlyContinue |
            Where-Object {
                # Match by volume - ShadowStorage.Volume is a reference like "Win32_Volume.DeviceID="\\?\Volume{guid}\""
                $_.Volume -match [regex]::Escape($Volume)
            }

        if (-not $shadowStorage) {
            # No shadow storage configured for this volume - try to get volume info
            $volumeInfo = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$Volume'" -ErrorAction SilentlyContinue
            if ($volumeInfo) {
                # Shadow storage will be created on demand using default settings
                # Default is typically 10-20% of volume size
                $defaultMaxBytes = [long]($volumeInfo.Capacity * 0.10)
                Write-RobocurseLog -Message "No VSS shadow storage configured for $Volume. Default allocation (~10%) will be used on first snapshot." `
                    -Level 'Debug' -Component 'VSS'
                return New-OperationResult -Success $true -Data @{
                    Volume = $Volume
                    MaxSizeMB = [math]::Round($defaultMaxBytes / 1MB, 0)
                    UsedSizeMB = 0
                    FreePercent = 100
                    Status = "NotConfigured"
                    Message = "Shadow storage will be allocated on first use"
                }
            }
            return New-OperationResult -Success $false -ErrorMessage "Cannot query VSS storage for volume $Volume"
        }

        # Calculate storage metrics
        $maxSizeBytes = $shadowStorage.MaxSpace
        $usedSizeBytes = $shadowStorage.UsedSpace
        $allocatedBytes = $shadowStorage.AllocatedSpace

        # Handle UNBOUNDED case (MaxSpace = -1 or very large)
        $isUnbounded = ($maxSizeBytes -lt 0) -or ($maxSizeBytes -gt 10PB)
        if ($isUnbounded) {
            Write-RobocurseLog -Message "VSS shadow storage for $Volume is UNBOUNDED (no limit)" -Level 'Debug' -Component 'VSS'
            return New-OperationResult -Success $true -Data @{
                Volume = $Volume
                MaxSizeMB = "Unbounded"
                UsedSizeMB = [math]::Round($usedSizeBytes / 1MB, 0)
                FreePercent = 100
                Status = "Unbounded"
                Message = "No storage limit configured"
            }
        }

        # Calculate free percentage
        $freeBytes = $maxSizeBytes - $usedSizeBytes
        $freePercent = if ($maxSizeBytes -gt 0) {
            [math]::Round(($freeBytes / $maxSizeBytes) * 100, 1)
        } else { 0 }

        $storageData = @{
            Volume = $Volume
            MaxSizeMB = [math]::Round($maxSizeBytes / 1MB, 0)
            UsedSizeMB = [math]::Round($usedSizeBytes / 1MB, 0)
            FreeMB = [math]::Round($freeBytes / 1MB, 0)
            FreePercent = $freePercent
            Status = "Configured"
        }

        # Check if storage is sufficient
        if ($freePercent -lt $MinimumFreePercent) {
            $errorMsg = "VSS storage for $Volume is low: $freePercent% free ($([math]::Round($freeBytes / 1MB, 0)) MB of $([math]::Round($maxSizeBytes / 1MB, 0)) MB). " +
                        "Consider running 'vssadmin delete shadows /for=$volumeWithSlash /oldest' or increasing storage with 'vssadmin resize shadowstorage'."
            Write-RobocurseLog -Message $errorMsg -Level 'Warning' -Component 'VSS'
            return New-OperationResult -Success $false -ErrorMessage $errorMsg -Data $storageData
        }

        Write-RobocurseLog -Message "VSS storage check passed for $Volume`: $freePercent% free ($([math]::Round($freeBytes / 1MB, 0)) MB available)" `
            -Level 'Debug' -Component 'VSS'
        return New-OperationResult -Success $true -Data $storageData
    }
    catch {
        $errorMsg = "Error checking VSS storage quota for $Volume`: $($_.Exception.Message)"
        Write-RobocurseLog -Message $errorMsg -Level 'Warning' -Component 'VSS'
        # Return success=true with warning - storage check failure shouldn't block snapshot attempt
        return New-OperationResult -Success $true -ErrorMessage $errorMsg -Data @{
            Volume = $Volume
            Status = "CheckFailed"
            Message = "Could not verify storage; proceeding with snapshot attempt"
        }
    }
}

function Add-VssToTracking {
    <#
    .SYNOPSIS
        Adds a VSS snapshot to the tracking file
    .DESCRIPTION
        Uses a mutex to prevent race conditions when multiple processes
        access the tracking file concurrently.
    .PARAMETER SnapshotInfo
        Snapshot info object with ShadowId
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$SnapshotInfo
    )

    try {
        $mutexResult = Invoke-WithVssTrackingMutex -ScriptBlock {
            $tracked = @()
            if (Test-Path $script:VssTrackingFile) {
                try {
                    # Note: Don't wrap ConvertFrom-Json in @() with pipeline - PS 5.1 unwraps arrays
                    # Assign first, then wrap to preserve array structure
                    $parsedJson = Get-Content $script:VssTrackingFile -Raw -ErrorAction Stop | ConvertFrom-Json
                    $tracked = @($parsedJson)
                }
                catch {
                    # File might be corrupted or empty - start fresh
                    $tracked = @()
                }
            }

            $tracked += [PSCustomObject]@{
                ShadowId = $SnapshotInfo.ShadowId
                SourceVolume = $SnapshotInfo.SourceVolume
                CreatedAt = $SnapshotInfo.CreatedAt.ToString('o')
            }

            # Atomic write with backup pattern to prevent corruption on crash
            # This prevents race condition between Remove-Item and Move
            $tempPath = "$($script:VssTrackingFile).tmp"
            $backupPath = "$($script:VssTrackingFile).bak"
            ConvertTo-Json -InputObject $tracked -Depth 5 | Set-Content $tempPath -Encoding UTF8

            # Move existing to backup first (atomic on same volume)
            if (Test-Path $script:VssTrackingFile) {
                if (Test-Path $backupPath) {
                    Remove-Item -Path $backupPath -Force -ErrorAction SilentlyContinue
                }
                [System.IO.File]::Move($script:VssTrackingFile, $backupPath)
            }
            # Now move temp to final (if this fails, we still have the backup)
            [System.IO.File]::Move($tempPath, $script:VssTrackingFile)
            # Clean up backup after successful replacement
            if (Test-Path $backupPath) {
                Remove-Item -Path $backupPath -Force -ErrorAction SilentlyContinue
            }
            return $true  # Explicit success marker
        }

        # Handle mutex timeout - null means timeout, snapshot may become orphan
        if ($null -eq $mutexResult) {
            Write-RobocurseLog -Message "VSS tracking mutex timeout - snapshot $($SnapshotInfo.ShadowId) may not be tracked (will be cleaned on next startup)" -Level 'Warning' -Component 'VSS'
        }
    }
    catch {
        Write-RobocurseLog -Message "Failed to add VSS to tracking: $($_.Exception.Message)" -Level 'Warning' -Component 'VSS'
    }
}

function Remove-VssFromTracking {
    <#
    .SYNOPSIS
        Removes a VSS snapshot from the tracking file
    .DESCRIPTION
        Uses a mutex to prevent race conditions when multiple processes
        access the tracking file concurrently.
    .PARAMETER ShadowId
        Shadow ID to remove
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ShadowId
    )

    try {
        $mutexResult = Invoke-WithVssTrackingMutex -ScriptBlock {
            if (-not (Test-Path $script:VssTrackingFile)) {
                return $true  # No file means nothing to remove - success
            }

            try {
                # Note: Don't wrap ConvertFrom-Json in @() with pipeline - PS 5.1 unwraps arrays
                # Assign first, then wrap to preserve array structure
                $parsedJson = Get-Content $script:VssTrackingFile -Raw -ErrorAction Stop | ConvertFrom-Json
                $tracked = @($parsedJson)
            }
            catch {
                # File might be corrupted - just remove it
                Remove-Item $script:VssTrackingFile -Force -ErrorAction SilentlyContinue
                return $true
            }

            $tracked = @($tracked | Where-Object { $_.ShadowId -ne $ShadowId })

            if ($tracked.Count -eq 0) {
                Remove-Item $script:VssTrackingFile -Force -ErrorAction SilentlyContinue
            } else {
                # Atomic write with backup pattern to prevent corruption on crash
                # This prevents race condition between Remove-Item and Move
                $tempPath = "$($script:VssTrackingFile).tmp"
                $backupPath = "$($script:VssTrackingFile).bak"
                ConvertTo-Json -InputObject $tracked -Depth 5 | Set-Content $tempPath -Encoding UTF8

                # Move existing to backup first (atomic on same volume)
                if (Test-Path $script:VssTrackingFile) {
                    if (Test-Path $backupPath) {
                        Remove-Item -Path $backupPath -Force -ErrorAction SilentlyContinue
                    }
                    [System.IO.File]::Move($script:VssTrackingFile, $backupPath)
                }
                # Now move temp to final (if this fails, we still have the backup)
                [System.IO.File]::Move($tempPath, $script:VssTrackingFile)
                # Clean up backup after successful replacement
                if (Test-Path $backupPath) {
                    Remove-Item -Path $backupPath -Force -ErrorAction SilentlyContinue
                }
            }
            return $true  # Explicit success marker
        }

        # Handle mutex timeout - null means timeout, tracking file may have stale entry
        if ($null -eq $mutexResult) {
            Write-RobocurseLog -Message "VSS tracking mutex timeout - snapshot $ShadowId may remain in tracking file (will be cleaned on next startup)" -Level 'Warning' -Component 'VSS'
        }
    }
    catch {
        Write-RobocurseLog -Message "Failed to remove VSS from tracking: $($_.Exception.Message)" -Level 'Warning' -Component 'VSS'
    }
}

function Get-VolumeFromPath {
    <#
    .SYNOPSIS
        Extracts the volume from a path
    .DESCRIPTION
        Parses a path and returns the volume (e.g., "C:", "D:").
        Returns $null for UNC paths as VSS must be created on the file server.
    .PARAMETER Path
        Local path (C:\...) or UNC path (\\server\share\...)
    .OUTPUTS
        Volume string (C:, D:, etc.) or $null for UNC paths
    .EXAMPLE
        Get-VolumeFromPath -Path "C:\Users\John"
        Returns: "C:"
    .EXAMPLE
        Get-VolumeFromPath -Path "\\server\share\folder"
        Returns: $null
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Match drive letter (case-insensitive)
    if ($Path -match '^([A-Za-z]:)') {
        return $Matches[1].ToUpper()
    }
    elseif ($Path -match '^\\\\') {
        # UNC path - VSS must be created on the server
        Write-RobocurseLog -Message "UNC path detected: $Path. VSS not supported for remote paths." -Level 'Debug' -Component 'VSS'
        return $null
    }

    Write-RobocurseLog -Message "Unable to determine volume from path: $Path" -Level 'Warning' -Component 'VSS'
    return $null
}

function Get-VssPath {
    <#
    .SYNOPSIS
        Converts a regular path to its VSS shadow copy equivalent
    .DESCRIPTION
        Translates a path from the original volume to the shadow copy volume.
        Example: C:\Users\John\Documents -> \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Users\John\Documents

        Supports two calling conventions:
        1. With VssSnapshot object (preferred):
           Get-VssPath -OriginalPath "C:\Users" -VssSnapshot $snapshot
        2. With individual parameters (legacy/testing):
           Get-VssPath -OriginalPath "C:\Users" -ShadowPath "\\?\..." -SourceVolume "C:"
    .PARAMETER OriginalPath
        Original path (e.g., C:\Users\John\Documents)
    .PARAMETER VssSnapshot
        VSS snapshot object from New-VssSnapshot (contains ShadowPath and SourceVolume)
    .PARAMETER ShadowPath
        VSS shadow path (e.g., \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1)
        Only required if VssSnapshot is not provided.
    .PARAMETER SourceVolume
        Source volume (e.g., C:)
        Only required if VssSnapshot is not provided.
    .OUTPUTS
        Converted path pointing to shadow copy
    .EXAMPLE
        Get-VssPath -OriginalPath "C:\Users\John\Documents" -VssSnapshot $snapshot
        Returns: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Users\John\Documents
    .EXAMPLE
        Get-VssPath -OriginalPath "C:\Users\John\Documents" `
                    -ShadowPath "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1" `
                    -SourceVolume "C:"
        Returns: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Users\John\Documents
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OriginalPath,

        [Parameter(Mandatory, ParameterSetName = 'VssSnapshot')]
        [PSCustomObject]$VssSnapshot,

        [Parameter(Mandatory, ParameterSetName = 'Individual')]
        [string]$ShadowPath,

        [Parameter(Mandatory, ParameterSetName = 'Individual')]
        [string]$SourceVolume
    )

    # Extract values from VssSnapshot if provided
    if ($PSCmdlet.ParameterSetName -eq 'VssSnapshot') {
        $ShadowPath = $VssSnapshot.ShadowPath
        $SourceVolume = $VssSnapshot.SourceVolume
    }

    # Ensure SourceVolume ends with colon (C:)
    $volumePrefix = $SourceVolume.TrimEnd('\', '/')
    if (-not $volumePrefix.EndsWith(':')) {
        $volumePrefix += ':'
    }

    # Extract the relative path after the volume
    # C:\Users\John\Documents -> \Users\John\Documents
    $relativePath = $OriginalPath.Substring($volumePrefix.Length)

    # Remove leading backslash if present
    $relativePath = $relativePath.TrimStart('\', '/')

    # Combine shadow path with relative path
    # Use string concatenation instead of Join-Path for compatibility with \\?\ style paths
    $shadowPathNormalized = $ShadowPath.TrimEnd('\', '/')
    if ($relativePath) {
        $vssPath = "$shadowPathNormalized\$relativePath"
    }
    else {
        # Root directory case (e.g., C:\)
        $vssPath = $shadowPathNormalized
    }

    Write-RobocurseLog -Message "Translated path: $OriginalPath -> $vssPath" -Level 'Debug' -Component 'VSS'

    return $vssPath
}
