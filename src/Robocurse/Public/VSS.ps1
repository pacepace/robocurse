# Robocurse Vss Functions
# Path to track active VSS snapshots (for orphan cleanup)
# Handle cross-platform: TEMP on Windows, TMPDIR on macOS, /tmp fallback
$script:VssTempDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { "/tmp" }
$script:VssTrackingFile = Join-Path $script:VssTempDir "Robocurse-VSS-Tracking.json"

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
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$SnapshotInfo
    )

    $mutex = $null
    try {
        # Use a named mutex to synchronize access across processes
        $mutexName = "Global\RobocurseVssTracking"
        $mutex = [System.Threading.Mutex]::new($false, $mutexName)

        # Wait up to 10 seconds to acquire the lock
        if (-not $mutex.WaitOne(10000)) {
            Write-RobocurseLog -Message "Timeout waiting for VSS tracking file lock" -Level 'Warning' -Component 'VSS'
            return
        }

        $tracked = @()
        if (Test-Path $script:VssTrackingFile) {
            $tracked = @(Get-Content $script:VssTrackingFile -Raw | ConvertFrom-Json)
        }

        $tracked += [PSCustomObject]@{
            ShadowId = $SnapshotInfo.ShadowId
            SourceVolume = $SnapshotInfo.SourceVolume
            CreatedAt = $SnapshotInfo.CreatedAt.ToString('o')
        }

        $tracked | ConvertTo-Json -Depth 5 | Set-Content $script:VssTrackingFile -Encoding UTF8
    }
    catch {
        Write-RobocurseLog -Message "Failed to add VSS to tracking: $($_.Exception.Message)" -Level 'Warning' -Component 'VSS'
    }
    finally {
        if ($mutex) {
            try { $mutex.ReleaseMutex() } catch { }
            $mutex.Dispose()
        }
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
    param(
        [Parameter(Mandatory)]
        [string]$ShadowId
    )

    $mutex = $null
    try {
        # Use a named mutex to synchronize access across processes
        $mutexName = "Global\RobocurseVssTracking"
        $mutex = [System.Threading.Mutex]::new($false, $mutexName)

        # Wait up to 10 seconds to acquire the lock
        if (-not $mutex.WaitOne(10000)) {
            Write-RobocurseLog -Message "Timeout waiting for VSS tracking file lock" -Level 'Warning' -Component 'VSS'
            return
        }

        if (-not (Test-Path $script:VssTrackingFile)) {
            return
        }

        $tracked = @(Get-Content $script:VssTrackingFile -Raw | ConvertFrom-Json)
        $tracked = @($tracked | Where-Object { $_.ShadowId -ne $ShadowId })

        if ($tracked.Count -eq 0) {
            Remove-Item $script:VssTrackingFile -Force -ErrorAction SilentlyContinue
        } else {
            $tracked | ConvertTo-Json -Depth 5 | Set-Content $script:VssTrackingFile -Encoding UTF8
        }
    }
    catch {
        Write-RobocurseLog -Message "Failed to remove VSS from tracking: $($_.Exception.Message)" -Level 'Warning' -Component 'VSS'
    }
    finally {
        if ($mutex) {
            try { $mutex.ReleaseMutex() } catch { }
            $mutex.Dispose()
        }
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
                # Remove from tracking file
                Remove-VssFromTracking -ShadowId $ShadowId
            }
            return New-OperationResult -Success $true -Data $ShadowId
        }
        else {
            Write-RobocurseLog -Message "VSS snapshot not found: $ShadowId (may have been already deleted)" -Level 'Warning' -Component 'VSS'
            # Remove from tracking even if not found (cleanup)
            if ($PSCmdlet.ShouldProcess($ShadowId, "Remove from VSS tracking")) {
                Remove-VssFromTracking -ShadowId $ShadowId
            }
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
