# Robocurse Vss Functions
# Path to track active VSS snapshots (for orphan cleanup)
# Handle cross-platform: TEMP on Windows, TMPDIR on macOS, /tmp fallback
$script:VssTempDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { "/tmp" }
$script:VssTrackingFile = Join-Path $script:VssTempDir "Robocurse-VSS-Tracking.json"

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

function Clear-OrphanVssSnapshots {
    <#
    .SYNOPSIS
        Cleans up VSS snapshots that may have been left behind from crashed runs
    .DESCRIPTION
        Reads the VSS tracking file and removes any snapshots that are still present.
        This should be called at startup to clean up after unexpected terminations.
    .OUTPUTS
        Number of snapshots cleaned up
    .EXAMPLE
        $cleaned = Clear-OrphanVssSnapshots
        if ($cleaned -gt 0) { Write-Host "Cleaned up $cleaned orphan snapshots" }
    .EXAMPLE
        Clear-OrphanVssSnapshots -WhatIf
        # Shows what snapshots would be cleaned without actually removing them
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    # Skip if not Windows
    if (-not (Test-IsWindowsPlatform)) {
        return 0
    }

    if (-not (Test-Path $script:VssTrackingFile)) {
        return 0
    }

    $cleaned = 0
    try {
        $trackedSnapshots = Get-Content $script:VssTrackingFile -Raw | ConvertFrom-Json

        foreach ($snapshot in $trackedSnapshots) {
            if ($snapshot.ShadowId) {
                if ($PSCmdlet.ShouldProcess($snapshot.ShadowId, "Remove orphan VSS snapshot")) {
                    $removeResult = Remove-VssSnapshot -ShadowId $snapshot.ShadowId
                    if ($removeResult.Success) {
                        Write-RobocurseLog -Message "Cleaned up orphan VSS snapshot: $($snapshot.ShadowId)" -Level 'Info' -Component 'VSS'
                        $cleaned++
                    }
                }
            }
        }

        # Clear the tracking file after cleanup
        if ($PSCmdlet.ShouldProcess($script:VssTrackingFile, "Remove VSS tracking file")) {
            Remove-Item $script:VssTrackingFile -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-RobocurseLog -Message "Error during orphan VSS cleanup: $($_.Exception.Message)" -Level 'Warning' -Component 'VSS'
    }

    return $cleaned
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
        Invoke-WithVssTrackingMutex -ScriptBlock {
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

            # Use -InputObject to preserve JSON array format (PS 5.1 compatibility)
            ConvertTo-Json -InputObject $tracked -Depth 5 | Set-Content $script:VssTrackingFile -Encoding UTF8
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
        Invoke-WithVssTrackingMutex -ScriptBlock {
            if (-not (Test-Path $script:VssTrackingFile)) {
                return
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
                return
            }

            $tracked = @($tracked | Where-Object { $_.ShadowId -ne $ShadowId })

            if ($tracked.Count -eq 0) {
                Remove-Item $script:VssTrackingFile -Force -ErrorAction SilentlyContinue
            } else {
                # Use -InputObject to preserve JSON array format (PS 5.1 compatibility)
                ConvertTo-Json -InputObject $tracked -Depth 5 | Set-Content $script:VssTrackingFile -Encoding UTF8
            }
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

function New-VssSnapshot {
    <#
    .SYNOPSIS
        Creates a VSS shadow copy of a volume
    .DESCRIPTION
        Creates a Volume Shadow Copy snapshot using WMI. The snapshot is created as
        "ClientAccessible" type which can be read by applications.

        Supports retry logic for transient failures (lock contention, VSS busy).
        Configurable via -RetryCount and -RetryDelaySeconds parameters.
    .PARAMETER SourcePath
        Path on the volume to snapshot (used to determine volume)
    .PARAMETER RetryCount
        Number of retry attempts for transient failures (default: 3)
    .PARAMETER RetryDelaySeconds
        Delay between retry attempts in seconds (default: 5)
    .OUTPUTS
        OperationResult - Success=$true with Data=SnapshotInfo (ShadowId, ShadowPath, SourceVolume, CreatedAt),
        Success=$false with ErrorMessage on failure
    .NOTES
        Requires Administrator privileges.
    .EXAMPLE
        $result = New-VssSnapshot -SourcePath "C:\Users"
        if ($result.Success) { $snapshot = $result.Data }
    .EXAMPLE
        $result = New-VssSnapshot -SourcePath "C:\Data" -RetryCount 5 -RetryDelaySeconds 10
        # More aggressive retry for busy systems
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            if ($_ -match '^\\\\') {
                throw "SourcePath '$_' is a UNC path. VSS snapshots can only be created for local paths (e.g., C:\path)"
            }
            if (-not ($_ -match '^[A-Za-z]:')) {
                throw "SourcePath '$_' must be a local path with a drive letter (e.g., C:\path)"
            }
            $true
        })]
        [string]$SourcePath,

        [ValidateRange(0, 10)]
        [int]$RetryCount = 3,

        [ValidateRange(1, 60)]
        [int]$RetryDelaySeconds = 5
    )

    # Pre-flight privilege check - fail fast if we don't have required privileges
    $privCheck = Test-VssPrivileges
    if (-not $privCheck.Success) {
        Write-RobocurseLog -Message "VSS privilege check failed: $($privCheck.ErrorMessage)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "VSS privileges not available: $($privCheck.ErrorMessage)"
    }

    # Retry loop for transient VSS failures (lock contention, VSS busy, etc.)
    $attempt = 0
    $lastError = $null

    while ($attempt -le $RetryCount) {
        $attempt++
        $isRetry = $attempt -gt 1

        if ($isRetry) {
            Write-RobocurseLog -Message "VSS snapshot retry $($attempt - 1)/$RetryCount for '$SourcePath' after ${RetryDelaySeconds}s delay" `
                -Level 'Warning' -Component 'VSS'
            Start-Sleep -Seconds $RetryDelaySeconds
        }

        $result = New-VssSnapshotInternal -SourcePath $SourcePath
        if ($result.Success) {
            if ($isRetry) {
                Write-RobocurseLog -Message "VSS snapshot succeeded on retry $($attempt - 1)" -Level 'Info' -Component 'VSS'
            }
            return $result
        }

        $lastError = $result.ErrorMessage

        # Check if error is retryable (transient failures)
        # Non-retryable: invalid path, permissions, VSS not supported
        # Retryable: VSS busy, lock contention, timeout
        $retryablePatterns = @(
            'busy',
            'timeout',
            'lock',
            'in use',
            '0x8004230F',  # Insufficient storage (might clear up)
            '0x80042316',  # VSS service not running (might start up)
            'try again'
        )

        $isRetryable = $false
        foreach ($pattern in $retryablePatterns) {
            if ($lastError -match $pattern) {
                $isRetryable = $true
                break
            }
        }

        if (-not $isRetryable) {
            Write-RobocurseLog -Message "VSS snapshot failed with non-retryable error: $lastError" -Level 'Error' -Component 'VSS'
            return $result
        }
    }

    # All retries exhausted
    Write-RobocurseLog -Message "VSS snapshot failed after $RetryCount retries: $lastError" -Level 'Error' -Component 'VSS'
    return New-OperationResult -Success $false -ErrorMessage "VSS snapshot failed after $RetryCount retries: $lastError"
}

function New-VssSnapshotInternal {
    <#
    .SYNOPSIS
        Internal function that performs the actual VSS snapshot creation
    .DESCRIPTION
        Called by New-VssSnapshot. Separated for retry logic.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath
    )

    try {
        # Determine volume from path
        $volume = Get-VolumeFromPath -Path $SourcePath
        if (-not $volume) {
            return New-OperationResult -Success $false -ErrorMessage "Cannot create VSS snapshot: Unable to determine volume from path '$SourcePath'"
        }

        Write-RobocurseLog -Message "Creating VSS snapshot for volume $volume (from path: $SourcePath)" -Level 'Info' -Component 'VSS'

        # Create shadow copy via CIM (modern replacement for WMI)
        # Note: Requires Administrator privileges
        $result = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{
            Volume = "$volume\"
            Context = "ClientAccessible"
        }

        if ($result.ReturnValue -ne 0) {
            # Common error codes:
            # 0x8004230F - Insufficient storage space
            # 0x80042316 - VSS service not running
            # 0x80042302 - Volume not supported for shadow copies
            $errorCode = "0x{0:X8}" -f $result.ReturnValue
            return New-OperationResult -Success $false -ErrorMessage "Failed to create shadow copy: Error $errorCode (ReturnValue: $($result.ReturnValue))"
        }

        # Get shadow copy details
        $shadowId = $result.ShadowID
        Write-RobocurseLog -Message "VSS snapshot created with ID: $shadowId" -Level 'Debug' -Component 'VSS'

        $shadow = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowId }
        if (-not $shadow) {
            return New-OperationResult -Success $false -ErrorMessage "Shadow copy created but could not retrieve details for ID: $shadowId"
        }

        $snapshotInfo = [PSCustomObject]@{
            ShadowId     = $shadowId
            ShadowPath   = $shadow.DeviceObject  # Format: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyN
            SourceVolume = $volume
            CreatedAt    = [datetime]::Now
        }

        Write-RobocurseLog -Message "VSS snapshot ready. Shadow path: $($snapshotInfo.ShadowPath)" -Level 'Info' -Component 'VSS'

        # Track snapshot for orphan cleanup in case of crash
        Add-VssToTracking -SnapshotInfo $snapshotInfo

        return New-OperationResult -Success $true -Data $snapshotInfo
    }
    catch {
        Write-RobocurseLog -Message "Failed to create VSS snapshot for '$SourcePath': $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "Failed to create VSS snapshot for '$SourcePath': $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Remove-VssSnapshot {
    <#
    .SYNOPSIS
        Deletes a VSS shadow copy
    .DESCRIPTION
        Removes a shadow copy using WMI by its ShadowId. This frees up storage space
        used by the snapshot.
    .PARAMETER ShadowId
        ID of shadow copy to delete (GUID string)
    .OUTPUTS
        OperationResult - Success=$true with Data=$ShadowId on success, Success=$false with ErrorMessage on failure
    .EXAMPLE
        $result = Remove-VssSnapshot -ShadowId "{12345678-1234-1234-1234-123456789012}"
        if ($result.Success) { "Snapshot deleted" }
    .EXAMPLE
        Remove-VssSnapshot -ShadowId $id -WhatIf
        # Shows what would happen without actually deleting
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ShadowId
    )

    try {
        Write-RobocurseLog -Message "Attempting to delete VSS snapshot: $ShadowId" -Level 'Debug' -Component 'VSS'

        $shadow = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $ShadowId }
        if ($shadow) {
            if ($PSCmdlet.ShouldProcess($ShadowId, "Remove VSS Snapshot")) {
                Remove-CimInstance -InputObject $shadow
                Write-RobocurseLog -Message "Deleted VSS snapshot: $ShadowId" -Level 'Info' -Component 'VSS'
                # Remove from tracking file ONLY after successful deletion
                # This prevents orphaned snapshots when ShouldProcess returns false
                Remove-VssFromTracking -ShadowId $ShadowId
                return New-OperationResult -Success $true -Data $ShadowId
            }
            else {
                # ShouldProcess returned false (e.g., -WhatIf) - don't remove from tracking
                # Return success but data indicates it was a WhatIf operation
                return New-OperationResult -Success $true -Data "WhatIf: Would remove $ShadowId"
            }
        }
        else {
            Write-RobocurseLog -Message "VSS snapshot not found: $ShadowId (may have been already deleted)" -Level 'Warning' -Component 'VSS'
            # Remove from tracking even if not found (cleanup of stale tracking entry)
            Remove-VssFromTracking -ShadowId $ShadowId
            # Still return success since the snapshot is gone (idempotent operation)
            return New-OperationResult -Success $true -Data $ShadowId
        }
    }
    catch {
        Write-RobocurseLog -Message "Error deleting VSS snapshot $ShadowId : $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "Failed to delete VSS snapshot '$ShadowId': $($_.Exception.Message)" -ErrorRecord $_
    }
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

function Test-VssSupported {
    <#
    .SYNOPSIS
        Tests if VSS is supported for a given path
    .DESCRIPTION
        Checks if Volume Shadow Copy can be used for a path. Returns $false for UNC paths
        (network shares) as they require VSS to be created on the file server. For local paths,
        tests WMI availability.
    .PARAMETER Path
        Path to test
    .OUTPUTS
        $true if VSS can be used, $false otherwise
    .EXAMPLE
        Test-VssSupported -Path "C:\Users"
        Returns: $true (if WMI is available)
    .EXAMPLE
        Test-VssSupported -Path "\\server\share"
        Returns: $false (UNC path)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        # Check if local path
        $volume = Get-VolumeFromPath -Path $Path
        if (-not $volume) {
            # UNC path - would need remote CIM session (complex, not supported in v1.0)
            Write-RobocurseLog -Message "VSS not supported for path: $Path (UNC path)" -Level 'Debug' -Component 'VSS'
            return $false
        }

        # Check if CIM is available and we can access Win32_ShadowCopy class
        $shadowClass = Get-CimClass -ClassName Win32_ShadowCopy -ErrorAction Stop
        if ($shadowClass) {
            Write-RobocurseLog -Message "VSS is supported for path: $Path" -Level 'Debug' -Component 'VSS'
            return $true
        }
        else {
            Write-RobocurseLog -Message "VSS not supported: Win32_ShadowCopy class not available" -Level 'Warning' -Component 'VSS'
            return $false
        }
    }
    catch {
        Write-RobocurseLog -Message "VSS not supported for path: $Path. Error: $($_.Exception.Message)" -Level 'Debug' -Component 'VSS'
        return $false
    }
}

function Invoke-WithVssSnapshot {
    <#
    .SYNOPSIS
        Executes a scriptblock with VSS snapshot, cleaning up afterward
    .DESCRIPTION
        Creates a VSS snapshot, executes the provided scriptblock, and ensures cleanup
        even if the scriptblock throws an error. The scriptblock receives a -VssPath parameter
        with the translated shadow copy path.
    .PARAMETER SourcePath
        Path to snapshot
    .PARAMETER ScriptBlock
        Code to execute (receives $VssPath parameter)
    .OUTPUTS
        OperationResult - Success=$true with Data=scriptblock result, Success=$false with ErrorMessage on failure
    .NOTES
        Cleanup is guaranteed via finally block.
    .EXAMPLE
        $result = Invoke-WithVssSnapshot -SourcePath "C:\Users" -ScriptBlock {
            param($VssPath)
            Copy-Item -Path "$VssPath\*" -Destination "D:\Backup" -Recurse
        }
        if (-not $result.Success) { Write-Error $result.ErrorMessage }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $snapshot = $null
    try {
        Write-RobocurseLog -Message "Creating VSS snapshot for $SourcePath" -Level 'Info' -Component 'VSS'
        $snapshotResult = New-VssSnapshot -SourcePath $SourcePath

        if (-not $snapshotResult.Success) {
            return New-OperationResult -Success $false -ErrorMessage "Failed to create VSS snapshot: $($snapshotResult.ErrorMessage)" -ErrorRecord $snapshotResult.ErrorRecord
        }

        $snapshot = $snapshotResult.Data
        $vssPath = Get-VssPath -OriginalPath $SourcePath -VssSnapshot $snapshot

        Write-RobocurseLog -Message "VSS path: $vssPath" -Level 'Debug' -Component 'VSS'

        # Execute the scriptblock with the VSS path
        $scriptResult = & $ScriptBlock -VssPath $vssPath

        return New-OperationResult -Success $true -Data $scriptResult
    }
    catch {
        Write-RobocurseLog -Message "Error during VSS snapshot operation for '$SourcePath': $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "Failed to execute VSS snapshot operation for '$SourcePath': $($_.Exception.Message)" -ErrorRecord $_
    }
    finally {
        if ($snapshot) {
            Write-RobocurseLog -Message "Cleaning up VSS snapshot" -Level 'Info' -Component 'VSS'
            $removeResult = Remove-VssSnapshot -ShadowId $snapshot.ShadowId
            if (-not $removeResult.Success) {
                Write-RobocurseLog -Message "Failed to cleanup VSS snapshot: $($removeResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
            }
        }
    }
}


function New-VssJunction {
    <#
    .SYNOPSIS
        Creates an NTFS junction pointing to a VSS shadow path
    .DESCRIPTION
        Creates a junction (directory symbolic link) that allows tools like robocopy
        to access VSS shadow copy paths. Robocopy cannot directly access VSS paths
        like \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1, but it CAN access
        junctions that point to them.
    .PARAMETER VssPath
        The VSS shadow path (e.g., \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Users)
    .PARAMETER JunctionPath
        Where to create the junction. If not specified, creates in temp directory.
    .OUTPUTS
        OperationResult - Success=$true with Data=JunctionPath, Success=$false with ErrorMessage
    .NOTES
        Junctions do not require admin privileges to create (unlike symlinks).
        The junction must be removed before the VSS snapshot is deleted.
    .EXAMPLE
        $result = New-VssJunction -VssPath $snapshot.ShadowPath
        if ($result.Success) { robocopy $result.Data $dest /MIR }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VssPath,

        [string]$JunctionPath
    )

    # Generate junction path if not provided
    if (-not $JunctionPath) {
        $junctionName = "RobocurseVss_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        $JunctionPath = Join-Path $env:TEMP $junctionName
    }

    # Ensure junction path doesn't already exist
    if (Test-Path $JunctionPath) {
        return New-OperationResult -Success $false `
            -ErrorMessage "Junction path already exists: '$JunctionPath'"
    }

    try {
        Write-RobocurseLog -Message "Creating junction '$JunctionPath' -> '$VssPath'" -Level 'Debug' -Component 'VSS'

        # Use cmd mklink /J to create junction
        # Junctions don't require admin (unlike symlinks with /D)
        $output = cmd /c "mklink /J `"$JunctionPath`" `"$VssPath`"" 2>&1

        if ($LASTEXITCODE -ne 0) {
            return New-OperationResult -Success $false `
                -ErrorMessage "Failed to create junction: $output"
        }

        # Verify junction was created and is accessible
        if (-not (Test-Path $JunctionPath)) {
            return New-OperationResult -Success $false `
                -ErrorMessage "Junction was created but path is not accessible: '$JunctionPath'"
        }

        Write-RobocurseLog -Message "Created VSS junction: '$JunctionPath'" -Level 'Info' -Component 'VSS'

        return New-OperationResult -Success $true -Data $JunctionPath
    }
    catch {
        Write-RobocurseLog -Message "Error creating VSS junction: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false `
            -ErrorMessage "Failed to create VSS junction: $($_.Exception.Message)" `
            -ErrorRecord $_
    }
}


function Remove-VssJunction {
    <#
    .SYNOPSIS
        Removes an NTFS junction created for VSS access
    .DESCRIPTION
        Safely removes a junction without following it or deleting the target contents.
        This must be called BEFORE removing the VSS snapshot.
    .PARAMETER JunctionPath
        Path to the junction to remove
    .OUTPUTS
        OperationResult - Success=$true on success, Success=$false with ErrorMessage on failure
    .NOTES
        Uses rmdir to remove junction without following it.
    .EXAMPLE
        Remove-VssJunction -JunctionPath "C:\Temp\RobocurseVss_abc123"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$JunctionPath
    )

    if (-not (Test-Path $JunctionPath)) {
        Write-RobocurseLog -Message "Junction already removed or doesn't exist: '$JunctionPath'" -Level 'Debug' -Component 'VSS'
        return New-OperationResult -Success $true -Data $JunctionPath
    }

    try {
        Write-RobocurseLog -Message "Removing VSS junction: '$JunctionPath'" -Level 'Debug' -Component 'VSS'

        # Use rmdir to remove junction without following it
        # Do NOT use Remove-Item -Recurse as it would try to delete contents
        $output = cmd /c "rmdir `"$JunctionPath`"" 2>&1

        if ($LASTEXITCODE -ne 0) {
            # Try alternative method
            try {
                [System.IO.Directory]::Delete($JunctionPath, $false)
            }
            catch {
                return New-OperationResult -Success $false `
                    -ErrorMessage "Failed to remove junction: $output"
            }
        }

        if (Test-Path $JunctionPath) {
            return New-OperationResult -Success $false `
                -ErrorMessage "Junction still exists after removal attempt: '$JunctionPath'"
        }

        Write-RobocurseLog -Message "Removed VSS junction: '$JunctionPath'" -Level 'Info' -Component 'VSS'
        return New-OperationResult -Success $true -Data $JunctionPath
    }
    catch {
        Write-RobocurseLog -Message "Error removing VSS junction: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false `
            -ErrorMessage "Failed to remove VSS junction: $($_.Exception.Message)" `
            -ErrorRecord $_
    }
}


function Invoke-WithVssJunction {
    <#
    .SYNOPSIS
        Executes a scriptblock with VSS snapshot accessible via junction for robocopy
    .DESCRIPTION
        Creates a VSS snapshot, creates a junction to make it robocopy-accessible,
        executes the provided scriptblock, and ensures cleanup of both junction and
        snapshot even if the scriptblock throws an error.

        The scriptblock receives a -SourcePath parameter with the junction path
        that robocopy can use as a source.
    .PARAMETER SourcePath
        Original path to snapshot (e.g., C:\Users\Data)
    .PARAMETER ScriptBlock
        Code to execute. Receives $SourcePath parameter with junction path.
    .PARAMETER JunctionRoot
        Directory where junction will be created. Defaults to TEMP.
    .OUTPUTS
        OperationResult - Success=$true with Data=scriptblock result, Success=$false with ErrorMessage
    .NOTES
        Cleanup order is important: junction first, then snapshot.
    .EXAMPLE
        $result = Invoke-WithVssJunction -SourcePath "C:\Users\Data" -ScriptBlock {
            param($SourcePath)
            robocopy $SourcePath "D:\Backup" /MIR /LOG:backup.log
            return $LASTEXITCODE
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [string]$JunctionRoot
    )

    $snapshot = $null
    $junctionPath = $null

    try {
        # Step 1: Create VSS snapshot
        Write-RobocurseLog -Message "Creating VSS snapshot for '$SourcePath'" -Level 'Info' -Component 'VSS'
        $snapshotResult = New-VssSnapshot -SourcePath $SourcePath

        if (-not $snapshotResult.Success) {
            return New-OperationResult -Success $false `
                -ErrorMessage "Failed to create VSS snapshot: $($snapshotResult.ErrorMessage)" `
                -ErrorRecord $snapshotResult.ErrorRecord
        }
        $snapshot = $snapshotResult.Data

        # Step 2: Get the VSS path for the source
        $vssPath = Get-VssPath -OriginalPath $SourcePath -VssSnapshot $snapshot
        Write-RobocurseLog -Message "VSS path: '$vssPath'" -Level 'Debug' -Component 'VSS'

        # Step 3: Create junction to VSS path
        $junctionParams = @{ VssPath = $vssPath }
        if ($JunctionRoot) {
            $junctionName = "RobocurseVss_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
            $junctionParams.JunctionPath = Join-Path $JunctionRoot $junctionName
        }

        $junctionResult = New-VssJunction @junctionParams
        if (-not $junctionResult.Success) {
            return New-OperationResult -Success $false `
                -ErrorMessage "Failed to create VSS junction: $($junctionResult.ErrorMessage)" `
                -ErrorRecord $junctionResult.ErrorRecord
        }
        $junctionPath = $junctionResult.Data
        Write-RobocurseLog -Message "Created junction '$junctionPath' for robocopy access" -Level 'Info' -Component 'VSS'

        # Step 4: Execute the scriptblock with junction path
        $scriptResult = & $ScriptBlock -SourcePath $junctionPath

        return New-OperationResult -Success $true -Data $scriptResult
    }
    catch {
        Write-RobocurseLog -Message "Error during VSS junction operation: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false `
            -ErrorMessage "VSS junction operation failed: $($_.Exception.Message)" `
            -ErrorRecord $_
    }
    finally {
        # Cleanup in correct order: junction first, then snapshot

        # Step 5a: Remove junction
        if ($junctionPath) {
            Write-RobocurseLog -Message "Cleaning up VSS junction" -Level 'Info' -Component 'VSS'
            $removeJunctionResult = Remove-VssJunction -JunctionPath $junctionPath
            if (-not $removeJunctionResult.Success) {
                Write-RobocurseLog -Message "Failed to cleanup VSS junction: $($removeJunctionResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
            }
        }

        # Step 5b: Remove snapshot
        if ($snapshot) {
            Write-RobocurseLog -Message "Cleaning up VSS snapshot" -Level 'Info' -Component 'VSS'
            $removeSnapshotResult = Remove-VssSnapshot -ShadowId $snapshot.ShadowId
            if (-not $removeSnapshotResult.Success) {
                Write-RobocurseLog -Message "Failed to cleanup VSS snapshot: $($removeSnapshotResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
            }
        }
    }
}


#region Remote VSS Functions

function Get-UncPathComponents {
    <#
    .SYNOPSIS
        Parses a UNC path into its components
    .DESCRIPTION
        Extracts the server name, share name, and relative path from a UNC path.
        Also attempts to determine the local path on the server by querying the share.
    .PARAMETER UncPath
        The UNC path to parse (e.g., \\server\share\folder\file.txt)
    .OUTPUTS
        PSCustomObject with ServerName, ShareName, RelativePath, and optionally LocalPath
    .EXAMPLE
        Get-UncPathComponents -UncPath "\\FileServer01\Data\Projects\Report.docx"
        Returns: @{ ServerName = "FileServer01"; ShareName = "Data"; RelativePath = "Projects\Report.docx"; LocalPath = $null }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^\\\\[^\\]+\\[^\\]+')]
        [string]$UncPath
    )

    # Parse UNC path: \\server\share\path\to\file
    if ($UncPath -match '^\\\\([^\\]+)\\([^\\]+)(?:\\(.*))?$') {
        $serverName = $Matches[1]
        $shareName = $Matches[2]
        $relativePath = if ($Matches[3]) { $Matches[3] } else { "" }

        return [PSCustomObject]@{
            ServerName   = $serverName
            ShareName    = $shareName
            RelativePath = $relativePath
            UncPath      = $UncPath
        }
    }

    Write-RobocurseLog -Message "Failed to parse UNC path: $UncPath" -Level 'Error' -Component 'VSS'
    return $null
}


function Get-RemoteShareLocalPath {
    <#
    .SYNOPSIS
        Gets the local path on a remote server for a given share
    .DESCRIPTION
        Uses CIM to query the Win32_Share class on the remote server to find
        the local path that the share points to.
    .PARAMETER ServerName
        The remote server name
    .PARAMETER ShareName
        The share name to look up
    .PARAMETER CimSession
        Optional existing CIM session to use
    .OUTPUTS
        The local path on the server, or $null if not found
    .EXAMPLE
        Get-RemoteShareLocalPath -ServerName "FileServer01" -ShareName "Data"
        Returns: "D:\SharedData"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerName,

        [Parameter(Mandatory)]
        [string]$ShareName,

        [Microsoft.Management.Infrastructure.CimSession]$CimSession
    )

    try {
        $ownSession = $false
        if (-not $CimSession) {
            $CimSession = New-CimSession -ComputerName $ServerName -ErrorAction Stop
            $ownSession = $true
        }

        try {
            $share = Get-CimInstance -CimSession $CimSession -ClassName Win32_Share |
                Where-Object { $_.Name -eq $ShareName }

            if ($share) {
                Write-RobocurseLog -Message "Share '$ShareName' on '$ServerName' maps to local path: $($share.Path)" -Level 'Debug' -Component 'VSS'
                return $share.Path
            }

            Write-RobocurseLog -Message "Share '$ShareName' not found on server '$ServerName'" -Level 'Warning' -Component 'VSS'
            return $null
        }
        finally {
            if ($ownSession -and $CimSession) {
                Remove-CimSession -CimSession $CimSession -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-RobocurseLog -Message "Failed to get share info from '$ServerName': $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return $null
    }
}


function Test-RemoteVssSupported {
    <#
    .SYNOPSIS
        Tests if remote VSS operations are supported for a given UNC path
    .DESCRIPTION
        Checks if we can establish a CIM session to the remote server and
        if the Win32_ShadowCopy class is available.
    .PARAMETER UncPath
        The UNC path to test
    .OUTPUTS
        OperationResult - Success=$true if remote VSS is supported
    .EXAMPLE
        $result = Test-RemoteVssSupported -UncPath "\\FileServer01\Data"
        if ($result.Success) { "Remote VSS available" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UncPath
    )

    $components = Get-UncPathComponents -UncPath $UncPath
    if (-not $components) {
        return New-OperationResult -Success $false -ErrorMessage "Invalid UNC path: $UncPath"
    }

    $serverName = $components.ServerName

    try {
        # Test CIM connectivity
        $cimSession = New-CimSession -ComputerName $serverName -ErrorAction Stop

        try {
            # Check if Win32_ShadowCopy is available
            $shadowClass = Get-CimClass -CimSession $cimSession -ClassName Win32_ShadowCopy -ErrorAction Stop

            if ($shadowClass) {
                Write-RobocurseLog -Message "Remote VSS supported on server '$serverName'" -Level 'Debug' -Component 'VSS'
                return New-OperationResult -Success $true -Data @{
                    ServerName = $serverName
                    ShareName  = $components.ShareName
                }
            }

            return New-OperationResult -Success $false -ErrorMessage "Win32_ShadowCopy class not available on '$serverName'"
        }
        finally {
            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-RobocurseLog -Message "Cannot connect to remote server '$serverName': $($_.Exception.Message)" -Level 'Warning' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "Cannot connect to remote server '$serverName': $($_.Exception.Message)"
    }
}


function New-RemoteVssSnapshot {
    <#
    .SYNOPSIS
        Creates a VSS snapshot on a remote server
    .DESCRIPTION
        Uses a remote CIM session to create a VSS shadow copy on the file server
        that hosts the specified UNC path.
    .PARAMETER UncPath
        The UNC path to the share/folder to snapshot
    .PARAMETER RetryCount
        Number of retry attempts for transient failures (default: 3)
    .PARAMETER RetryDelaySeconds
        Delay between retry attempts (default: 5)
    .OUTPUTS
        OperationResult with Data containing:
        - ShadowId: The shadow copy ID
        - ShadowPath: The shadow device path (local to the server)
        - ServerName: The remote server name
        - ShareName: The share name
        - ShareLocalPath: The local path on the server the share points to
        - SourceVolume: The volume on the server
        - CreatedAt: Timestamp
    .EXAMPLE
        $result = New-RemoteVssSnapshot -UncPath "\\FileServer01\Data\Projects"
        if ($result.Success) { $snapshot = $result.Data }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^\\\\[^\\]+\\[^\\]+')]
        [string]$UncPath,

        [ValidateRange(0, 10)]
        [int]$RetryCount = 3,

        [ValidateRange(1, 60)]
        [int]$RetryDelaySeconds = 5
    )

    $components = Get-UncPathComponents -UncPath $UncPath
    if (-not $components) {
        return New-OperationResult -Success $false -ErrorMessage "Invalid UNC path: $UncPath"
    }

    $serverName = $components.ServerName
    $shareName = $components.ShareName

    Write-RobocurseLog -Message "Creating remote VSS snapshot on '$serverName' for share '$shareName'" -Level 'Info' -Component 'VSS'

    $cimSession = $null
    try {
        # Establish CIM session
        $cimSession = New-CimSession -ComputerName $serverName -ErrorAction Stop
        Write-RobocurseLog -Message "CIM session established to '$serverName'" -Level 'Debug' -Component 'VSS'

        # Get the local path for the share
        $shareLocalPath = Get-RemoteShareLocalPath -ServerName $serverName -ShareName $shareName -CimSession $cimSession
        if (-not $shareLocalPath) {
            return New-OperationResult -Success $false -ErrorMessage "Cannot determine local path for share '$shareName' on server '$serverName'"
        }

        # Determine volume from the share's local path
        if ($shareLocalPath -match '^([A-Za-z]:)') {
            $volume = $Matches[1].ToUpper()
        }
        else {
            return New-OperationResult -Success $false -ErrorMessage "Cannot determine volume from share local path: $shareLocalPath"
        }

        # Retry loop
        $attempt = 0
        $lastError = $null

        while ($attempt -le $RetryCount) {
            $attempt++
            $isRetry = $attempt -gt 1

            if ($isRetry) {
                Write-RobocurseLog -Message "Remote VSS snapshot retry $($attempt - 1)/$RetryCount after ${RetryDelaySeconds}s delay" `
                    -Level 'Warning' -Component 'VSS'
                Start-Sleep -Seconds $RetryDelaySeconds
            }

            try {
                # Create shadow copy on remote server
                $result = Invoke-CimMethod -CimSession $cimSession -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{
                    Volume  = "$volume\"
                    Context = "ClientAccessible"
                }

                if ($result.ReturnValue -ne 0) {
                    $errorCode = "0x{0:X8}" -f $result.ReturnValue
                    $lastError = "Failed to create remote shadow copy: Error $errorCode"

                    # Check if retryable
                    if ($result.ReturnValue -in @(0x8004230F, 0x80042316)) {
                        continue  # Retry
                    }
                    return New-OperationResult -Success $false -ErrorMessage $lastError
                }

                # Get shadow copy details
                $shadowId = $result.ShadowID
                Write-RobocurseLog -Message "Remote VSS snapshot created with ID: $shadowId" -Level 'Debug' -Component 'VSS'

                $shadow = Get-CimInstance -CimSession $cimSession -ClassName Win32_ShadowCopy |
                    Where-Object { $_.ID -eq $shadowId }

                if (-not $shadow) {
                    return New-OperationResult -Success $false -ErrorMessage "Remote shadow copy created but could not retrieve details for ID: $shadowId"
                }

                $snapshotInfo = [PSCustomObject]@{
                    ShadowId       = $shadowId
                    ShadowPath     = $shadow.DeviceObject
                    ServerName     = $serverName
                    ShareName      = $shareName
                    ShareLocalPath = $shareLocalPath
                    SourceVolume   = $volume
                    CreatedAt      = [datetime]::Now
                    IsRemote       = $true
                }

                Write-RobocurseLog -Message "Remote VSS snapshot ready on '$serverName'. Shadow path: $($snapshotInfo.ShadowPath)" -Level 'Info' -Component 'VSS'

                # Track for orphan cleanup
                Add-VssToTracking -SnapshotInfo ([PSCustomObject]@{
                    ShadowId     = $shadowId
                    SourceVolume = "$serverName`:$volume"  # Include server name for remote tracking
                    CreatedAt    = $snapshotInfo.CreatedAt
                    ServerName   = $serverName
                    IsRemote     = $true
                })

                return New-OperationResult -Success $true -Data $snapshotInfo
            }
            catch {
                $lastError = $_.Exception.Message
                Write-RobocurseLog -Message "Remote VSS attempt $attempt failed: $lastError" -Level 'Warning' -Component 'VSS'
            }
        }

        return New-OperationResult -Success $false -ErrorMessage "Remote VSS snapshot failed after $RetryCount retries: $lastError"
    }
    catch {
        Write-RobocurseLog -Message "Failed to create remote VSS snapshot: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "Failed to create remote VSS snapshot: $($_.Exception.Message)" -ErrorRecord $_
    }
    finally {
        if ($cimSession) {
            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
        }
    }
}


function Remove-RemoteVssSnapshot {
    <#
    .SYNOPSIS
        Removes a VSS snapshot from a remote server
    .DESCRIPTION
        Uses a remote CIM session to delete a shadow copy on the remote server.
    .PARAMETER ShadowId
        The shadow copy ID to remove
    .PARAMETER ServerName
        The remote server where the snapshot exists
    .OUTPUTS
        OperationResult
    .EXAMPLE
        Remove-RemoteVssSnapshot -ShadowId "{guid}" -ServerName "FileServer01"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ShadowId,

        [Parameter(Mandatory)]
        [string]$ServerName
    )

    $cimSession = $null
    try {
        Write-RobocurseLog -Message "Removing remote VSS snapshot '$ShadowId' from '$ServerName'" -Level 'Debug' -Component 'VSS'

        $cimSession = New-CimSession -ComputerName $ServerName -ErrorAction Stop

        $shadow = Get-CimInstance -CimSession $cimSession -ClassName Win32_ShadowCopy |
            Where-Object { $_.ID -eq $ShadowId }

        if ($shadow) {
            if ($PSCmdlet.ShouldProcess("$ShadowId on $ServerName", "Remove Remote VSS Snapshot")) {
                Remove-CimInstance -CimSession $cimSession -InputObject $shadow
                Write-RobocurseLog -Message "Deleted remote VSS snapshot: $ShadowId" -Level 'Info' -Component 'VSS'
                Remove-VssFromTracking -ShadowId $ShadowId
                return New-OperationResult -Success $true -Data $ShadowId
            }
            else {
                return New-OperationResult -Success $true -Data "WhatIf: Would remove $ShadowId"
            }
        }
        else {
            Write-RobocurseLog -Message "Remote VSS snapshot not found: $ShadowId on $ServerName" -Level 'Warning' -Component 'VSS'
            Remove-VssFromTracking -ShadowId $ShadowId
            return New-OperationResult -Success $true -Data $ShadowId
        }
    }
    catch {
        Write-RobocurseLog -Message "Error removing remote VSS snapshot: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "Failed to remove remote VSS snapshot: $($_.Exception.Message)" -ErrorRecord $_
    }
    finally {
        if ($cimSession) {
            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
        }
    }
}


function New-RemoteVssJunction {
    <#
    .SYNOPSIS
        Creates a junction on a remote server pointing to a VSS shadow path
    .DESCRIPTION
        Uses PowerShell remoting to create a junction on the remote server.
        The junction is created inside the share's directory so it's accessible
        via UNC path from the client.
    .PARAMETER VssSnapshot
        The remote VSS snapshot object from New-RemoteVssSnapshot
    .PARAMETER JunctionName
        Optional name for the junction. Defaults to a GUID-based name.
    .OUTPUTS
        OperationResult with Data containing:
        - JunctionLocalPath: The local path to the junction on the server
        - JunctionUncPath: The UNC path to access the junction from the client
    .NOTES
        The junction is created inside the share directory (e.g., \\server\share\.robocurse-vss-xxx)
        so that clients can access it via the existing share.
    .EXAMPLE
        $junction = New-RemoteVssJunction -VssSnapshot $snapshot
        robocopy $junction.Data.JunctionUncPath $destination /MIR
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$VssSnapshot,

        [string]$JunctionName
    )

    if (-not $VssSnapshot.IsRemote) {
        return New-OperationResult -Success $false -ErrorMessage "VssSnapshot is not a remote snapshot"
    }

    $serverName = $VssSnapshot.ServerName
    $shareName = $VssSnapshot.ShareName
    $shareLocalPath = $VssSnapshot.ShareLocalPath
    $shadowPath = $VssSnapshot.ShadowPath

    # Generate junction name if not provided
    if (-not $JunctionName) {
        $JunctionName = ".robocurse-vss-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    }

    # Junction will be created inside the share directory
    $junctionLocalPath = Join-Path $shareLocalPath $JunctionName
    $junctionUncPath = "\\$serverName\$shareName\$JunctionName"

    # Calculate the VSS path for the share's local path
    # Shadow path is like: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy5
    # Share local path is like: D:\SharedData
    # We need: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy5\SharedData

    $volume = $VssSnapshot.SourceVolume
    $relativePath = $shareLocalPath.Substring($volume.Length).TrimStart('\')
    $vssTargetPath = if ($relativePath) {
        "$shadowPath\$relativePath"
    } else {
        $shadowPath
    }

    Write-RobocurseLog -Message "Creating remote junction on '$serverName': '$junctionLocalPath' -> '$vssTargetPath'" -Level 'Debug' -Component 'VSS'

    try {
        # Use Invoke-Command to create the junction on the remote server
        $result = Invoke-Command -ComputerName $serverName -ScriptBlock {
            param($JunctionPath, $TargetPath)

            # Check if junction already exists
            if (Test-Path $JunctionPath) {
                return @{ Success = $false; Error = "Junction path already exists: $JunctionPath" }
            }

            # Create junction using cmd mklink /J
            $output = cmd /c "mklink /J `"$JunctionPath`" `"$TargetPath`"" 2>&1

            if ($LASTEXITCODE -ne 0) {
                return @{ Success = $false; Error = "mklink failed: $output" }
            }

            # Verify
            if (-not (Test-Path $JunctionPath)) {
                return @{ Success = $false; Error = "Junction created but not accessible" }
            }

            return @{ Success = $true; JunctionPath = $JunctionPath }
        } -ArgumentList $junctionLocalPath, $vssTargetPath -ErrorAction Stop

        if (-not $result.Success) {
            return New-OperationResult -Success $false -ErrorMessage "Failed to create remote junction: $($result.Error)"
        }

        # Verify we can access it via UNC
        if (-not (Test-Path $junctionUncPath)) {
            Write-RobocurseLog -Message "Remote junction created but UNC path not accessible: $junctionUncPath" -Level 'Warning' -Component 'VSS'
        }

        Write-RobocurseLog -Message "Created remote VSS junction: $junctionUncPath" -Level 'Info' -Component 'VSS'

        return New-OperationResult -Success $true -Data ([PSCustomObject]@{
            JunctionLocalPath = $junctionLocalPath
            JunctionUncPath   = $junctionUncPath
            ServerName        = $serverName
        })
    }
    catch {
        Write-RobocurseLog -Message "Error creating remote junction: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "Failed to create remote junction: $($_.Exception.Message)" -ErrorRecord $_
    }
}


function Remove-RemoteVssJunction {
    <#
    .SYNOPSIS
        Removes a junction from a remote server
    .DESCRIPTION
        Uses PowerShell remoting to safely remove a junction on the remote server
        without following it or deleting the target contents.
    .PARAMETER JunctionLocalPath
        The local path to the junction on the remote server
    .PARAMETER ServerName
        The remote server name
    .OUTPUTS
        OperationResult
    .EXAMPLE
        Remove-RemoteVssJunction -JunctionLocalPath "D:\Share\.robocurse-vss-abc123" -ServerName "FileServer01"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$JunctionLocalPath,

        [Parameter(Mandatory)]
        [string]$ServerName
    )

    Write-RobocurseLog -Message "Removing remote junction '$JunctionLocalPath' from '$ServerName'" -Level 'Debug' -Component 'VSS'

    try {
        $result = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            param($JunctionPath)

            if (-not (Test-Path $JunctionPath)) {
                return @{ Success = $true; Message = "Junction already removed" }
            }

            # Use rmdir to remove junction without following it
            $output = cmd /c "rmdir `"$JunctionPath`"" 2>&1

            if ($LASTEXITCODE -ne 0) {
                # Try .NET method
                try {
                    [System.IO.Directory]::Delete($JunctionPath, $false)
                }
                catch {
                    return @{ Success = $false; Error = "rmdir failed: $output" }
                }
            }

            if (Test-Path $JunctionPath) {
                return @{ Success = $false; Error = "Junction still exists after removal" }
            }

            return @{ Success = $true }
        } -ArgumentList $JunctionLocalPath -ErrorAction Stop

        if (-not $result.Success) {
            return New-OperationResult -Success $false -ErrorMessage "Failed to remove remote junction: $($result.Error)"
        }

        Write-RobocurseLog -Message "Removed remote VSS junction from '$ServerName'" -Level 'Info' -Component 'VSS'
        return New-OperationResult -Success $true -Data $JunctionLocalPath
    }
    catch {
        Write-RobocurseLog -Message "Error removing remote junction: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "Failed to remove remote junction: $($_.Exception.Message)" -ErrorRecord $_
    }
}


function Get-RemoteVssPath {
    <#
    .SYNOPSIS
        Converts a UNC path to its VSS shadow copy equivalent UNC path
    .DESCRIPTION
        Given a UNC path and a remote VSS snapshot, returns the UNC path through
        the VSS junction that provides access to the point-in-time snapshot.
    .PARAMETER OriginalUncPath
        The original UNC path (e.g., \\server\share\folder)
    .PARAMETER VssSnapshot
        The remote VSS snapshot object
    .PARAMETER JunctionInfo
        The junction info from New-RemoteVssJunction
    .OUTPUTS
        The UNC path through the junction to access the VSS copy
    .EXAMPLE
        $vssUncPath = Get-RemoteVssPath -OriginalUncPath "\\server\share\folder" -VssSnapshot $snap -JunctionInfo $junction
        # Returns: \\server\share\.robocurse-vss-xxx\folder
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OriginalUncPath,

        [Parameter(Mandatory)]
        [PSCustomObject]$VssSnapshot,

        [Parameter(Mandatory)]
        [PSCustomObject]$JunctionInfo
    )

    $components = Get-UncPathComponents -UncPath $OriginalUncPath
    if (-not $components) {
        Write-RobocurseLog -Message "Invalid UNC path: $OriginalUncPath" -Level 'Error' -Component 'VSS'
        return $null
    }

    # The junction provides access to the share's root in VSS
    # So we append the relative path from the original UNC
    $junctionUncPath = $JunctionInfo.JunctionUncPath
    $relativePath = $components.RelativePath

    if ($relativePath) {
        $vssUncPath = "$junctionUncPath\$relativePath"
    }
    else {
        $vssUncPath = $junctionUncPath
    }

    Write-RobocurseLog -Message "Translated remote path: $OriginalUncPath -> $vssUncPath" -Level 'Debug' -Component 'VSS'
    return $vssUncPath
}


function Invoke-WithRemoteVssJunction {
    <#
    .SYNOPSIS
        Executes a scriptblock with remote VSS snapshot accessible via UNC junction
    .DESCRIPTION
        Creates a VSS snapshot on the remote server, creates a junction accessible
        via UNC, executes the provided scriptblock, and ensures cleanup of both
        junction and snapshot even if the scriptblock throws.

        This enables robocopy to copy from a point-in-time snapshot of a remote
        file share.
    .PARAMETER UncPath
        The UNC path to the source (e.g., \\server\share\folder)
    .PARAMETER ScriptBlock
        Code to execute. Receives $SourcePath parameter with the UNC path to the
        VSS junction that provides access to the snapshot.
    .OUTPUTS
        OperationResult with Data containing the scriptblock result
    .NOTES
        Cleanup order: junction first, then snapshot.
        Requires:
        - Admin rights on the remote server
        - PowerShell remoting enabled on the remote server
        - CIM access to the remote server
    .EXAMPLE
        $result = Invoke-WithRemoteVssJunction -UncPath "\\FileServer01\Data\Projects" -ScriptBlock {
            param($SourcePath)
            robocopy $SourcePath "D:\Backup\Projects" /MIR /LOG:backup.log
            return $LASTEXITCODE
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^\\\\[^\\]+\\[^\\]+')]
        [string]$UncPath,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $snapshot = $null
    $junctionInfo = $null

    try {
        # Step 1: Create remote VSS snapshot
        Write-RobocurseLog -Message "Creating remote VSS snapshot for '$UncPath'" -Level 'Info' -Component 'VSS'
        $snapshotResult = New-RemoteVssSnapshot -UncPath $UncPath

        if (-not $snapshotResult.Success) {
            return New-OperationResult -Success $false `
                -ErrorMessage "Failed to create remote VSS snapshot: $($snapshotResult.ErrorMessage)" `
                -ErrorRecord $snapshotResult.ErrorRecord
        }
        $snapshot = $snapshotResult.Data

        # Step 2: Create junction on remote server
        $junctionResult = New-RemoteVssJunction -VssSnapshot $snapshot
        if (-not $junctionResult.Success) {
            return New-OperationResult -Success $false `
                -ErrorMessage "Failed to create remote VSS junction: $($junctionResult.ErrorMessage)" `
                -ErrorRecord $junctionResult.ErrorRecord
        }
        $junctionInfo = $junctionResult.Data

        # Step 3: Get the UNC path through the junction
        $vssUncPath = Get-RemoteVssPath -OriginalUncPath $UncPath -VssSnapshot $snapshot -JunctionInfo $junctionInfo
        Write-RobocurseLog -Message "Remote VSS accessible at: $vssUncPath" -Level 'Info' -Component 'VSS'

        # Step 4: Execute scriptblock with the VSS UNC path
        $scriptResult = & $ScriptBlock -SourcePath $vssUncPath

        return New-OperationResult -Success $true -Data $scriptResult
    }
    catch {
        Write-RobocurseLog -Message "Error during remote VSS operation: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false `
            -ErrorMessage "Remote VSS operation failed: $($_.Exception.Message)" `
            -ErrorRecord $_
    }
    finally {
        # Cleanup in correct order: junction first, then snapshot

        # Step 5a: Remove junction
        if ($junctionInfo) {
            Write-RobocurseLog -Message "Cleaning up remote VSS junction" -Level 'Info' -Component 'VSS'
            $removeJunctionResult = Remove-RemoteVssJunction `
                -JunctionLocalPath $junctionInfo.JunctionLocalPath `
                -ServerName $junctionInfo.ServerName
            if (-not $removeJunctionResult.Success) {
                Write-RobocurseLog -Message "Failed to cleanup remote junction: $($removeJunctionResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
            }
        }

        # Step 5b: Remove snapshot
        if ($snapshot) {
            Write-RobocurseLog -Message "Cleaning up remote VSS snapshot" -Level 'Info' -Component 'VSS'
            $removeSnapshotResult = Remove-RemoteVssSnapshot `
                -ShadowId $snapshot.ShadowId `
                -ServerName $snapshot.ServerName
            if (-not $removeSnapshotResult.Success) {
                Write-RobocurseLog -Message "Failed to cleanup remote snapshot: $($removeSnapshotResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
            }
        }
    }
}

#endregion Remote VSS Functions
