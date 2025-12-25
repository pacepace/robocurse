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

    return [PSCustomObject]@{
        DriveLetter = [string]$letter
        Root        = $root
        OriginalPath = $UncPath
        MappedPath  = "${letter}:$remainder"
    }
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
        }
        catch {
            Write-RobocurseLog -Message "Failed to unmount $($mapping.DriveLetter): $($_.Exception.Message)" -Level 'Warning' -Component 'NetworkMapping'
        }
    }
}
