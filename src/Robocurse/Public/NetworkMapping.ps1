# Robocurse Network Path Mapping
# Maps UNC paths to drive letters for reliable network access in Session 0 scheduled tasks
#
# =====================================================================================
# WHY THIS EXISTS - DO NOT REMOVE
# =====================================================================================
# Windows Task Scheduler runs tasks in Session 0 (non-interactive, isolated session).
# When accessing SMB/UNC shares via IP address (e.g., \\192.168.1.1\share):
#   1. Kerberos authentication CANNOT work (requires hostname for SPN lookup)
#   2. Windows falls back to NTLM authentication
#   3. NTLM does NOT properly delegate credentials in Session 0
#   4. Result: SMB server sees ANONYMOUS LOGON -> Access Denied
#
# SOLUTION: Explicitly mount UNC paths to drive letters using New-PSDrive.
# This forces Windows to establish a proper authenticated SMB session.
#
# Without this mounting:
#   - GUI mode (user session): Works fine - user's credentials are available
#   - Scheduled task (Session 0): FAILS with "Access Denied" on network shares
#
# With this mounting:
#   - Both modes work because we force explicit SMB connection establishment
#
# Reference: https://duffney.io (scheduled task network access patterns)
# =====================================================================================

# Tracking file for network mappings - enables cleanup after crash
$script:NetworkMappingTrackingFile = $null  # Initialized when needed

function Initialize-NetworkMappingTracking {
    <#
    .SYNOPSIS
        Initializes the network mapping tracking file path
    .DESCRIPTION
        Sets up the tracking file path in the logs directory.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:LogPath) {
        # Use default if logging not initialized
        $script:LogPath = ".\Logs"
    }

    $script:NetworkMappingTrackingFile = Join-Path $script:LogPath "robocurse-mappings-active.json"
}

function Add-NetworkMappingTracking {
    <#
    .SYNOPSIS
        Adds a network mapping to the tracking file for crash recovery
    .PARAMETER Mapping
        The mapping object from Mount-SingleNetworkPath
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Mapping
    )

    if (-not $script:NetworkMappingTrackingFile) {
        Initialize-NetworkMappingTracking
    }

    $trackedMappings = @()

    if (Test-Path $script:NetworkMappingTrackingFile) {
        try {
            $content = Get-Content $script:NetworkMappingTrackingFile -Raw | ConvertFrom-Json
            $trackedMappings = @($content)
        }
        catch {
            Write-RobocurseLog -Message "Failed to read mapping tracking file, starting fresh: $($_.Exception.Message)" `
                -Level 'Warning' -Component 'NetworkMapping'
        }
    }

    $trackedMappings += @{
        DriveLetter = $Mapping.DriveLetter
        Root = $Mapping.Root
        OriginalPath = $Mapping.OriginalPath
        MappedPath = $Mapping.MappedPath
        CreatedAt = [datetime]::Now.ToString('o')
    }

    # Ensure directory exists
    $trackingDir = Split-Path $script:NetworkMappingTrackingFile -Parent
    if (-not (Test-Path $trackingDir)) {
        New-Item -Path $trackingDir -ItemType Directory -Force | Out-Null
    }

    $trackedMappings | ConvertTo-Json -Depth 5 | Set-Content $script:NetworkMappingTrackingFile -Encoding UTF8

    Write-RobocurseLog -Message "Added mapping to tracking: $($Mapping.DriveLetter) -> $($Mapping.Root)" `
        -Level 'Debug' -Component 'NetworkMapping'
}

function Remove-NetworkMappingTracking {
    <#
    .SYNOPSIS
        Removes a network mapping from the tracking file
    .PARAMETER DriveLetter
        The drive letter to remove (e.g., "Y:" or "Y")
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DriveLetter
    )

    if (-not $script:NetworkMappingTrackingFile -or -not (Test-Path $script:NetworkMappingTrackingFile)) {
        return
    }

    $letter = $DriveLetter.TrimEnd(':')

    try {
        # Read and parse JSON separately to avoid pipeline issues with array wrapping
        $rawContent = Get-Content $script:NetworkMappingTrackingFile -Raw
        $parsed = ConvertFrom-Json $rawContent
        $trackedMappings = @($parsed)

        $remainingMappings = @($trackedMappings | Where-Object { $_.DriveLetter -ne "$letter`:" -and $_.DriveLetter -ne $letter })

        if ($remainingMappings.Count -eq 0) {
            Remove-Item $script:NetworkMappingTrackingFile -Force -ErrorAction SilentlyContinue
            Write-RobocurseLog -Message "All mappings removed, deleted tracking file" `
                -Level 'Debug' -Component 'NetworkMapping'
        }
        else {
            # Use -InputObject to preserve array structure (piping unrolls arrays)
            ConvertTo-Json -InputObject $remainingMappings -Depth 5 | Set-Content $script:NetworkMappingTrackingFile -Encoding UTF8
        }

        Write-RobocurseLog -Message "Removed mapping from tracking: $letter" `
            -Level 'Debug' -Component 'NetworkMapping'
    }
    catch {
        Write-RobocurseLog -Message "Failed to update mapping tracking: $($_.Exception.Message)" `
            -Level 'Warning' -Component 'NetworkMapping'
    }
}

function Clear-OrphanNetworkMappings {
    <#
    .SYNOPSIS
        Cleans up network drive mappings that may have been left behind from crashed runs
    .DESCRIPTION
        Reads the network mapping tracking file and removes any mappings that are still present.
        This should be called at startup to clean up after unexpected terminations.

        Only mappings tracked by Robocurse are removed - other user-created mappings are left alone.
    .OUTPUTS
        Number of mappings cleaned up
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $script:NetworkMappingTrackingFile) {
        Initialize-NetworkMappingTracking
    }

    if (-not (Test-Path $script:NetworkMappingTrackingFile)) {
        return 0
    }

    $cleaned = 0
    $failedMappings = @()

    try {
        $content = Get-Content $script:NetworkMappingTrackingFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content)) {
            # Empty file - just clean it up
            Remove-Item $script:NetworkMappingTrackingFile -Force -ErrorAction SilentlyContinue
            return 0
        }

        $trackedMappings = $content | ConvertFrom-Json
        $trackedMappings = @($trackedMappings | Where-Object { $null -ne $_ })

        foreach ($mapping in $trackedMappings) {
            if (-not $mapping -or -not $mapping.DriveLetter) {
                continue  # Skip invalid entries
            }
            $letter = $mapping.DriveLetter.TrimEnd(':')
            $displayName = "$($mapping.DriveLetter) -> $($mapping.Root)"

            if ($PSCmdlet.ShouldProcess($displayName, "Remove orphan network mapping")) {
                try {
                    # Check if drive is actually mapped
                    $existingDrive = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue

                    if ($existingDrive) {
                        # Verify it's the same mapping (not a different user mapping)
                        if ($existingDrive.Root -eq $mapping.Root) {
                            Remove-PSDrive -Name $letter -Force -ErrorAction Stop
                            Write-RobocurseLog -Message "Cleaned up orphan network mapping: $displayName" `
                                -Level 'Info' -Component 'NetworkMapping'
                            $cleaned++
                        }
                        else {
                            # Drive exists but points elsewhere - remove from tracking only
                            Write-RobocurseLog -Message "Drive $letter exists but points to different location, removing from tracking" `
                                -Level 'Debug' -Component 'NetworkMapping'
                        }
                    }
                    else {
                        # Drive not mapped - just clean up tracking
                        Write-RobocurseLog -Message "Tracked mapping $letter no longer exists, cleaning up tracking" `
                            -Level 'Debug' -Component 'NetworkMapping'
                    }
                }
                catch {
                    Write-RobocurseLog -Message "Failed to cleanup orphan mapping $displayName`: $($_.Exception.Message)" `
                        -Level 'Warning' -Component 'NetworkMapping'
                    $failedMappings += $mapping
                }
            }
        }

        # Update tracking file
        if ($PSCmdlet.ShouldProcess($script:NetworkMappingTrackingFile, "Update tracking file")) {
            if ($failedMappings.Count -eq 0) {
                Remove-Item $script:NetworkMappingTrackingFile -Force -ErrorAction SilentlyContinue
                Write-RobocurseLog -Message "All orphan mappings cleaned - removed tracking file" `
                    -Level 'Debug' -Component 'NetworkMapping'
            }
            elseif ($cleaned -gt 0) {
                # Some succeeded, some failed - keep failed entries
                $failedMappings | ConvertTo-Json -Depth 5 | Set-Content $script:NetworkMappingTrackingFile -Encoding UTF8
                Write-RobocurseLog -Message "Updated tracking file: $($failedMappings.Count) mappings remain for retry" `
                    -Level 'Warning' -Component 'NetworkMapping'
            }
        }
    }
    catch {
        Write-RobocurseLog -Message "Error during orphan mapping cleanup: $($_.Exception.Message)" `
            -Level 'Warning' -Component 'NetworkMapping'
    }

    return $cleaned
}

function Get-UncRoot {
    <#
    .SYNOPSIS
        Extracts the \\server\share root from a UNC path
    .PARAMETER UncPath
        Full UNC path (e.g., \\192.168.1.1\share\subfolder\file.txt)
    .OUTPUTS
        The root portion (e.g., \\192.168.1.1\share)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UncPath
    )

    if ($UncPath -match '^(\\\\[^\\]+\\[^\\]+)') {
        return $Matches[1]
    }
    return $UncPath
}

function Mount-SingleNetworkPath {
    <#
    .SYNOPSIS
        Mounts a single UNC path to an available drive letter
    .PARAMETER UncPath
        UNC path to mount
    .PARAMETER Credential
        Optional PSCredential for authentication (required for Session 0 scheduled tasks)
    .OUTPUTS
        PSCustomObject with DriveLetter, Root, OriginalPath, MappedPath
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UncPath,

        [PSCredential]$Credential
    )

    # Extract \\server\share root
    $root = Get-UncRoot $UncPath
    $remainder = $UncPath.Substring($root.Length)

    # Clean up stale mapping to same root (from crashed previous runs)
    $existingDrive = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayRoot -eq $root }
    if ($existingDrive) {
        Write-RobocurseLog -Message "Removing stale mapping $($existingDrive.Name): to '$root'" -Level 'Debug' -Component 'NetworkMapping'
        Remove-PSDrive -Name $existingDrive.Name -Force -ErrorAction SilentlyContinue
    }

    # Find available letter (Z down to D)
    $used = @((Get-PSDrive -PSProvider FileSystem).Name)
    $letter = [char[]](90..68) | Where-Object { [string]$_ -notin $used } | Select-Object -First 1
    if (-not $letter) {
        throw "No available drive letters for network mapping"
    }

    # Mount with or without explicit credentials
    # With credential: Required for Session 0 scheduled tasks (NTLM doesn't delegate in Session 0)
    # Without credential: Works in interactive sessions where user credentials are available
    #
    # CRITICAL: -Persist is REQUIRED for robocopy.exe to see the drive!
    # Without -Persist, New-PSDrive creates a PowerShell-only drive invisible to external processes.
    if ($Credential) {
        Write-RobocurseLog -Message "Mounting '$root' as $letter`: with explicit credentials (user: $($Credential.UserName))" -Level 'Debug' -Component 'NetworkMapping'
        New-PSDrive -Name $letter -PSProvider FileSystem -Root $root -Credential $Credential -Scope Global -Persist -ErrorAction Stop | Out-Null
    }
    else {
        Write-RobocurseLog -Message "Mounting '$root' as $letter`: (using session credentials)" -Level 'Debug' -Component 'NetworkMapping'
        New-PSDrive -Name $letter -PSProvider FileSystem -Root $root -Scope Global -Persist -ErrorAction Stop | Out-Null
    }

    # =====================================================================================
    # VERIFY THE MOUNT ACTUALLY WORKS
    # =====================================================================================
    # New-PSDrive can succeed without actually verifying SMB connectivity (it's lazy).
    # We MUST verify the drive is accessible before returning, otherwise robocopy will
    # fail with "ERROR 3 (path not found)" even though the mount appeared to succeed.
    # =====================================================================================
    $drivePath = "${letter}:\"
    Write-RobocurseLog -Message "Verifying mount accessibility: $drivePath" -Level 'Debug' -Component 'NetworkMapping'

    try {
        # Force enumeration to verify SMB connection actually works
        $null = Get-ChildItem -Path $drivePath -ErrorAction Stop | Select-Object -First 1
        Write-RobocurseLog -Message "Mount verified accessible: $drivePath" -Level 'Debug' -Component 'NetworkMapping'
    }
    catch {
        # Mount appeared to work but drive isn't accessible - clean up and throw
        Write-RobocurseLog -Message "Mount verification FAILED for $drivePath`: $($_.Exception.Message)" -Level 'Error' -Component 'NetworkMapping'
        Remove-PSDrive -Name $letter -Force -ErrorAction SilentlyContinue
        throw "Network mount to '$root' created but drive $drivePath is not accessible: $($_.Exception.Message)"
    }

    $result = [PSCustomObject]@{
        DriveLetter = [string]$letter
        Root        = $root
        OriginalPath = $UncPath
        MappedPath  = "${letter}:$remainder"
    }

    # Track the mapping for crash recovery
    Add-NetworkMappingTracking -Mapping $result

    return $result
}

function Mount-NetworkPaths {
    <#
    .SYNOPSIS
        Mounts UNC paths to drive letters for reliable network access
    .DESCRIPTION
        Maps source and/or destination UNC paths to drive letters.
        If source and destination share the same \\server\share root, reuses the mapping.

        CREDENTIAL HANDLING:
        - With -Credential: Uses explicit credentials (required for Session 0 scheduled tasks)
        - Without -Credential: Uses current session credentials (works in interactive sessions)
    .PARAMETER SourcePath
        Source path (may be UNC or local)
    .PARAMETER DestinationPath
        Destination path (may be UNC or local)
    .PARAMETER Credential
        Optional PSCredential for authentication. Required for scheduled tasks running
        in Session 0 where NTLM doesn't delegate credentials properly.
    .OUTPUTS
        Hashtable with Mappings array, translated SourcePath and DestinationPath
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [PSCredential]$Credential
    )

    $mappings = @()
    $translatedSource = $SourcePath
    $translatedDest = $DestinationPath

    # Mount source if UNC
    if ($SourcePath -match '^\\\\') {
        $mapping = Mount-SingleNetworkPath -UncPath $SourcePath -Credential $Credential
        $mappings += $mapping
        $translatedSource = $mapping.MappedPath
        Write-RobocurseLog -Message "Mapped source '$SourcePath' to '$translatedSource'" -Level 'Info' -Component 'NetworkMapping'
    }

    # Mount destination if UNC (may share same root as source)
    if ($DestinationPath -match '^\\\\') {
        $destRoot = Get-UncRoot $DestinationPath
        $existing = $mappings | Where-Object { $_.Root -eq $destRoot }

        if ($existing) {
            # Reuse existing mapping for same root
            $remainder = $DestinationPath.Substring($destRoot.Length)
            $translatedDest = "$($existing.DriveLetter):$remainder"
            Write-RobocurseLog -Message "Reusing source mapping for destination: '$translatedDest'" -Level 'Debug' -Component 'NetworkMapping'
        }
        else {
            $mapping = Mount-SingleNetworkPath -UncPath $DestinationPath -Credential $Credential
            $mappings += $mapping
            $translatedDest = $mapping.MappedPath
            Write-RobocurseLog -Message "Mapped destination '$DestinationPath' to '$translatedDest'" -Level 'Info' -Component 'NetworkMapping'
        }
    }

    return @{
        Mappings        = $mappings
        SourcePath      = $translatedSource
        DestinationPath = $translatedDest
    }
}

function Dismount-NetworkPaths {
    <#
    .SYNOPSIS
        Removes drive mappings created by Mount-NetworkPaths
    .PARAMETER Mappings
        Array of mapping objects from Mount-NetworkPaths
    #>
    [CmdletBinding()]
    param(
        [array]$Mappings
    )

    foreach ($mapping in $Mappings) {
        try {
            Remove-PSDrive -Name $mapping.DriveLetter -Force -ErrorAction Stop
            Write-RobocurseLog -Message "Unmapped $($mapping.DriveLetter): from '$($mapping.Root)'" -Level 'Debug' -Component 'NetworkMapping'

            # Remove from tracking
            Remove-NetworkMappingTracking -DriveLetter $mapping.DriveLetter
        }
        catch {
            Write-RobocurseLog -Message "Failed to unmount $($mapping.DriveLetter): $($_.Exception.Message)" -Level 'Warning' -Component 'NetworkMapping'
        }
    }
}
