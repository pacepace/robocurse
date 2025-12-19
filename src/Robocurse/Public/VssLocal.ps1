# Robocurse VSS Local Functions
# Local VSS snapshot and junction operations
# Requires VssCore.ps1 to be loaded first (handled by Robocurse.psm1)

function Clear-OrphanVssSnapshots {
    <#
    .SYNOPSIS
        Cleans up VSS snapshots that may have been left behind from crashed runs
    .DESCRIPTION
        Reads the VSS tracking file and removes any snapshots that are still present.
        This should be called at startup to clean up after unexpected terminations.

        Only successfully deleted snapshots are removed from the tracking file.
        Failed deletions are retained for retry on the next cleanup attempt.
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
    $failedSnapshots = @()

    try {
        $trackedSnapshots = Get-Content $script:VssTrackingFile -Raw | ConvertFrom-Json
        # Ensure we have an array even for single items
        $trackedSnapshots = @($trackedSnapshots)

        foreach ($snapshot in $trackedSnapshots) {
            if ($snapshot.ShadowId) {
                if ($PSCmdlet.ShouldProcess($snapshot.ShadowId, "Remove orphan VSS snapshot")) {
                    $removeResult = Remove-VssSnapshot -ShadowId $snapshot.ShadowId
                    if ($removeResult.Success) {
                        Write-RobocurseLog -Message "Cleaned up orphan VSS snapshot: $($snapshot.ShadowId)" -Level 'Info' -Component 'VSS'
                        $cleaned++
                    }
                    else {
                        # Keep track of failed deletions for retry on next cleanup
                        Write-RobocurseLog -Message "Failed to clean up orphan VSS snapshot: $($snapshot.ShadowId) - $($removeResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
                        $failedSnapshots += $snapshot
                    }
                }
                else {
                    # WhatIf mode - don't count as cleaned, but don't add to failed either
                }
            }
        }

        # Update tracking file: only clear if all succeeded, otherwise keep failed entries
        if ($PSCmdlet.ShouldProcess($script:VssTrackingFile, "Update VSS tracking file")) {
            if ($failedSnapshots.Count -eq 0) {
                # All snapshots cleaned successfully - remove tracking file
                Remove-Item $script:VssTrackingFile -Force -ErrorAction SilentlyContinue
                Write-RobocurseLog -Message "All orphan VSS snapshots cleaned - removed tracking file" -Level 'Debug' -Component 'VSS'
            }
            elseif ($cleaned -gt 0) {
                # Some succeeded, some failed - update tracking file with failed entries only
                $tempPath = "$($script:VssTrackingFile).tmp"
                $backupPath = "$($script:VssTrackingFile).bak"
                ConvertTo-Json -InputObject $failedSnapshots -Depth 5 | Set-Content $tempPath -Encoding UTF8

                # Atomic replace with backup
                if (Test-Path $backupPath) {
                    Remove-Item -Path $backupPath -Force -ErrorAction SilentlyContinue
                }
                [System.IO.File]::Move($script:VssTrackingFile, $backupPath)
                [System.IO.File]::Move($tempPath, $script:VssTrackingFile)
                if (Test-Path $backupPath) {
                    Remove-Item -Path $backupPath -Force -ErrorAction SilentlyContinue
                }

                Write-RobocurseLog -Message "Updated tracking file: $($failedSnapshots.Count) snapshots remain for retry" -Level 'Warning' -Component 'VSS'
            }
            # If cleaned=0 and failedSnapshots.Count > 0, tracking file unchanged
        }
    }
    catch {
        Write-RobocurseLog -Message "Error during orphan VSS cleanup: $($_.Exception.Message)" -Level 'Warning' -Component 'VSS'
    }

    return $cleaned
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

    # Pre-flight storage quota check - warn if storage is low (but don't block)
    $volume = Get-VolumeFromPath -Path $SourcePath
    if ($volume) {
        $quotaCheck = Test-VssStorageQuota -Volume $volume
        if (-not $quotaCheck.Success) {
            # Log warning but proceed - the snapshot may still succeed
            Write-RobocurseLog -Message "VSS storage warning for $volume`: $($quotaCheck.ErrorMessage)" -Level 'Warning' -Component 'VSS'
        }
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

        # Check if error is retryable using shared function (VssCore.ps1)
        # Non-retryable: invalid path, permissions, VSS not supported
        # Retryable: VSS busy, lock contention, timeout
        if (-not (Test-VssErrorRetryable -ErrorMessage $lastError)) {
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
    .PARAMETER SourcePath
        Path to create snapshot for (volume will be determined from this path)
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

function Get-VssSnapshots {
    <#
    .SYNOPSIS
        Lists VSS snapshots on local volumes
    .DESCRIPTION
        Retrieves VSS shadow copies from the local system. Can filter by volume
        or return all snapshots. Results include snapshot ID, device path,
        volume, and creation time.
    .PARAMETER Volume
        Optional volume to filter (e.g., "C:", "D:"). If not specified, returns all.
    .PARAMETER IncludeSystemSnapshots
        If true, includes snapshots not created by Robocurse (default: false)
    .OUTPUTS
        OperationResult with Data = array of snapshot objects
    .EXAMPLE
        $result = Get-VssSnapshots -Volume "D:"
        $result.Data | Format-Table ShadowId, CreatedAt, SourceVolume
    #>
    [CmdletBinding()]
    param(
        [ValidatePattern('^[A-Za-z]:$')]
        [string]$Volume,

        [switch]$IncludeSystemSnapshots
    )

    # Pre-flight check
    if (-not (Test-IsWindowsPlatform)) {
        return New-OperationResult -Success $false -ErrorMessage "VSS is only available on Windows"
    }

    try {
        Write-RobocurseLog -Message "Listing VSS snapshots$(if ($Volume) { " for volume $Volume" })" -Level 'Debug' -Component 'VSS'

        $snapshots = Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop

        if (-not $snapshots) {
            return New-OperationResult -Success $true -Data @()
        }

        # Filter by volume if specified
        if ($Volume) {
            $volumeUpper = $Volume.ToUpper()
            $snapshots = $snapshots | Where-Object {
                # VolumeName format: \\?\Volume{guid}\ - need to resolve to drive letter
                $snapshotVolume = Get-VolumeLetterFromVolumeName -VolumeName $_.VolumeName
                $snapshotVolume -eq $volumeUpper
            }
        }

        # Convert to our standard format
        $result = @($snapshots | ForEach-Object {
            $snapshotVolume = Get-VolumeLetterFromVolumeName -VolumeName $_.VolumeName
            [PSCustomObject]@{
                ShadowId     = $_.ID
                ShadowPath   = $_.DeviceObject
                SourceVolume = $snapshotVolume
                CreatedAt    = $_.InstallDate
                Provider     = $_.ProviderID
                ClientAccessible = $_.ClientAccessible
            }
        })

        # Sort by creation time (newest first)
        $result = @($result | Sort-Object CreatedAt -Descending)

        Write-RobocurseLog -Message "Found $($result.Count) VSS snapshot(s)" -Level 'Debug' -Component 'VSS'
        return New-OperationResult -Success $true -Data $result
    }
    catch {
        Write-RobocurseLog -Message "Failed to list VSS snapshots: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "Failed to list VSS snapshots: $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Get-VolumeLetterFromVolumeName {
    <#
    .SYNOPSIS
        Converts a volume GUID path to a drive letter
    .DESCRIPTION
        Resolves \\?\Volume{guid}\ format to drive letter (C:, D:, etc.)
    .PARAMETER VolumeName
        The volume GUID path from Win32_ShadowCopy.VolumeName
    .OUTPUTS
        Drive letter (e.g., "C:") or $null if not found
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VolumeName
    )

    try {
        # Get all volumes and match by GUID
        $volumes = Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter }

        foreach ($vol in $volumes) {
            # DeviceID format: \\?\Volume{guid}\
            if ($vol.DeviceID -eq $VolumeName) {
                return $vol.DriveLetter
            }
        }

        # Fallback: try to extract from path patterns
        Write-RobocurseLog -Message "Could not resolve volume name to drive letter: $VolumeName" -Level 'Debug' -Component 'VSS'
        return $null
    }
    catch {
        return $null
    }
}

function Invoke-VssRetentionPolicy {
    <#
    .SYNOPSIS
        Enforces VSS snapshot retention by removing old snapshots
    .DESCRIPTION
        For each volume, keeps the newest N snapshots and removes the rest.
        This is typically called before creating a new snapshot.
    .PARAMETER Volume
        Volume to apply retention to (e.g., "D:"). Required.
    .PARAMETER KeepCount
        Number of snapshots to keep per volume (default: 3)
    .PARAMETER WhatIf
        If specified, shows what would be deleted without actually deleting
    .OUTPUTS
        OperationResult with Data containing:
        - DeletedCount: Number of snapshots removed
        - KeptCount: Number of snapshots retained
        - Errors: Array of any deletion errors
    .EXAMPLE
        $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 5
        if ($result.Success) { "Deleted $($result.Data.DeletedCount) old snapshots" }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]:$')]
        [string]$Volume,

        [ValidateRange(0, 100)]
        [int]$KeepCount = 3
    )

    Write-RobocurseLog -Message "Applying VSS retention policy for $Volume (keep: $KeepCount)" -Level 'Info' -Component 'VSS'

    # Get current snapshots for this volume
    $listResult = Get-VssSnapshots -Volume $Volume
    if (-not $listResult.Success) {
        return New-OperationResult -Success $false -ErrorMessage "Failed to list snapshots: $($listResult.ErrorMessage)"
    }

    $snapshots = @($listResult.Data)
    $currentCount = $snapshots.Count

    # Nothing to do if we're under the limit
    if ($currentCount -le $KeepCount) {
        Write-RobocurseLog -Message "Retention OK: $currentCount snapshot(s) <= $KeepCount limit" -Level 'Debug' -Component 'VSS'
        return New-OperationResult -Success $true -Data @{
            DeletedCount = 0
            KeptCount    = $currentCount
            Errors       = @()
        }
    }

    # Sort by CreatedAt ascending (oldest first) and select ones to delete
    $sortedSnapshots = $snapshots | Sort-Object CreatedAt
    $toDelete = @($sortedSnapshots | Select-Object -First ($currentCount - $KeepCount))
    $toKeep = @($sortedSnapshots | Select-Object -Last $KeepCount)

    Write-RobocurseLog -Message "Retention: Deleting $($toDelete.Count) old snapshot(s), keeping $($toKeep.Count)" -Level 'Info' -Component 'VSS'

    $deletedCount = 0
    $errors = @()

    foreach ($snapshot in $toDelete) {
        $shadowId = $snapshot.ShadowId
        $createdAt = $snapshot.CreatedAt

        if ($PSCmdlet.ShouldProcess("$shadowId (created $createdAt)", "Remove VSS Snapshot")) {
            $removeResult = Remove-VssSnapshot -ShadowId $shadowId
            if ($removeResult.Success) {
                $deletedCount++
                Write-RobocurseLog -Message "Deleted snapshot $shadowId (created $createdAt)" -Level 'Debug' -Component 'VSS'
            }
            else {
                $errors += "Failed to delete $shadowId`: $($removeResult.ErrorMessage)"
                Write-RobocurseLog -Message "Failed to delete snapshot $shadowId`: $($removeResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
            }
        }
    }

    $success = $errors.Count -eq 0
    $resultData = @{
        DeletedCount = $deletedCount
        KeptCount    = $toKeep.Count
        Errors       = $errors
    }

    if ($success) {
        Write-RobocurseLog -Message "Retention policy applied: deleted $deletedCount, kept $($toKeep.Count)" -Level 'Info' -Component 'VSS'
    }
    else {
        Write-RobocurseLog -Message "Retention policy completed with errors: deleted $deletedCount, errors: $($errors.Count)" -Level 'Warning' -Component 'VSS'
    }

    return New-OperationResult -Success $success -Data $resultData -ErrorMessage $(if (-not $success) { $errors -join "; " })
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
        # Use 16-char GUID prefix for better collision resistance in high-concurrency scenarios
        $junctionName = "RobocurseVss_$([Guid]::NewGuid().ToString('N').Substring(0,16))"
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
            # Use 16-char GUID prefix for better collision resistance in high-concurrency scenarios
        $junctionName = "RobocurseVss_$([Guid]::NewGuid().ToString('N').Substring(0,16))"
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
