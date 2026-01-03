# Robocurse Job Management Functions
# Chunk job execution, retry logic, and profile management
#
# This module handles the execution lifecycle:
# - Starting and stopping replication runs
# - Profile processing and transitions
# - Chunk job creation and completion
# - Retry logic with exponential backoff
# - Control requests (stop, pause, resume)

function Start-ReplicationRun {
    <#
    .SYNOPSIS
        Starts replication for specified profiles
    .DESCRIPTION
        Initializes orchestration state (unless SkipInitialization is set) and begins
        replication of the specified profiles. Use SkipInitialization when the state
        has already been initialized by the caller (e.g., GUI mode where state is
        shared across threads).

        Supports resume from checkpoint: if a checkpoint file exists, completed chunks
        will be skipped. Use -IgnoreCheckpoint to start fresh.
    .PARAMETER Profiles
        Array of profile objects from config
    .PARAMETER MaxConcurrentJobs
        Maximum parallel robocopy processes
    .PARAMETER SkipInitialization
        Skip state initialization. Use when state was pre-initialized by caller
        (e.g., GUI mode for cross-thread state sharing)
    .PARAMETER IgnoreCheckpoint
        Ignore any existing checkpoint file and start fresh
    .PARAMETER OnProgress
        Scriptblock called on progress updates
    .PARAMETER OnChunkComplete
        Scriptblock called when chunk finishes
    .PARAMETER OnProfileComplete
        Scriptblock called when profile finishes
    .PARAMETER DryRun
        Preview mode - runs robocopy with /L flag to show what would be copied
    .PARAMETER Config
        Full configuration object (required for snapshot retention settings)
    .PARAMETER ConfigPath
        Path to config file (required for snapshot registry updates)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ValidateScript({
            if ($_.Count -eq 0) {
                throw "At least one profile is required in the Profiles array"
            }
            foreach ($p in $_) {
                if (-not $p.Name) {
                    throw "Profile is missing the required 'Name' property"
                }
                if (-not $p.Source) {
                    throw "Profile '$($p.Name)' is missing the required 'Source' property"
                }
                if (-not $p.Destination) {
                    throw "Profile '$($p.Name)' is missing the required 'Destination' property"
                }
            }
            $true
        })]
        [PSCustomObject[]]$Profiles,

        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [ValidateRange(1, 128)]
        [int]$MaxConcurrentJobs = $script:DefaultMaxConcurrentJobs,

        [ValidateRange(0, 10000)]
        [int]$BandwidthLimitMbps = 0,

        [switch]$SkipInitialization,

        [switch]$IgnoreCheckpoint,

        [switch]$DryRun,

        [scriptblock]$OnProgress,
        [scriptblock]$OnChunkComplete,
        [scriptblock]$OnProfileComplete
    )

    # Initialize state (unless caller already did - e.g., GUI cross-thread scenario)
    if (-not $SkipInitialization) {
        Initialize-OrchestrationState
    }

    # Load checkpoint if resuming
    $script:CurrentCheckpoint = $null
    $script:CompletedPathsHashSet = $null  # HashSet for O(1) lookups during resume
    if (-not $IgnoreCheckpoint) {
        $script:CurrentCheckpoint = Get-ReplicationCheckpoint
        if ($script:CurrentCheckpoint) {
            $skippedCount = $script:CurrentCheckpoint.CompletedChunkPaths.Count
            Write-RobocurseLog -Message "Resuming from checkpoint: $skippedCount chunks will be skipped" `
                -Level 'Info' -Component 'Checkpoint'

            # Create HashSet for O(1) lookups instead of O(N) linear search per chunk
            # This significantly improves resume performance with thousands of completed chunks
            $script:CompletedPathsHashSet = New-CompletedPathsHashSet -Checkpoint $script:CurrentCheckpoint
        }
    }

    # Set bandwidth limit for dynamic IPG calculation
    $script:BandwidthLimitMbps = $BandwidthLimitMbps
    if ($BandwidthLimitMbps -gt 0) {
        Write-RobocurseLog -Message "Aggregate bandwidth limit: $BandwidthLimitMbps Mbps across all jobs" `
            -Level 'Info' -Component 'Orchestrator'
    }

    # Set dry-run mode for Start-ChunkJob to use
    $script:DryRunMode = $DryRun.IsPresent
    if ($script:DryRunMode) {
        Write-RobocurseLog -Message "DRY-RUN MODE: No files will be copied (robocopy /L)" `
            -Level 'Warning' -Component 'Orchestrator'
    }

    # Validate robocopy is available before starting
    $robocopyCheck = Test-RobocopyAvailable
    if (-not $robocopyCheck.Success) {
        throw "Cannot start replication: $($robocopyCheck.ErrorMessage)"
    }
    Write-RobocurseLog -Message "Using robocopy from: $($robocopyCheck.Data)" -Level 'Debug' -Component 'Orchestrator'

    # Store callbacks and run settings
    $script:OnProgress = $OnProgress
    $script:OnChunkComplete = $OnChunkComplete
    $script:OnProfileComplete = $OnProfileComplete
    $script:CurrentMaxConcurrentJobs = $MaxConcurrentJobs
    $script:Config = $Config
    $script:ConfigPath = $ConfigPath

    # Store profiles and start timing
    $script:OrchestrationState.Profiles = $Profiles
    $script:OrchestrationState.StartTime = [datetime]::Now
    $script:OrchestrationState.Phase = "Replicating"

    Write-RobocurseLog -Message "Starting replication run with $($Profiles.Count) profile(s)" `
        -Level 'Info' -Component 'Orchestrator'

    Write-SiemEvent -EventType 'SessionStart' -Data @{
        profileCount = $Profiles.Count
        maxConcurrentJobs = $MaxConcurrentJobs
    }

    # Process first profile
    if ($Profiles.Count -gt 0) {
        Start-ProfileReplication -Profile $Profiles[0] -MaxConcurrentJobs $MaxConcurrentJobs
    }
}

function Invoke-ProfileSnapshots {
    <#
    .SYNOPSIS
        Creates persistent VSS snapshots for source and/or destination at profile start
    .DESCRIPTION
        Creates persistent snapshots based on profile configuration:
        1. Source snapshot (if SourceSnapshot.PersistentEnabled = $true)
        2. Destination snapshot (if DestinationSnapshot.PersistentEnabled = $true)

        For each snapshot:
        - Determines the volume (local or remote)
        - Computes effective retention using MAX across all profiles sharing that volume
        - Enforces retention policy (deletes old snapshots to make room)
        - Creates a new persistent snapshot
        - Registers the snapshot in the config's SnapshotRegistry

        The snapshots remain after backup completes for point-in-time recovery.
    .PARAMETER Profile
        The sync profile object
    .PARAMETER Config
        The full configuration object (for computing effective retention)
    .PARAMETER ConfigPath
        Path to the config file (for saving registry updates)
    .PARAMETER State
        Optional OrchestrationState object for updating GUI status
    .OUTPUTS
        OperationResult with Data containing:
        - SourceSnapshot: snapshot info or $null
        - DestinationSnapshot: snapshot info or $null
        - SourceRetention: retention summary or $null
        - DestinationRetention: retention summary or $null
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,

        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter()]
        [object]$State
    )

    $results = @{
        SourceSnapshot = $null
        DestinationSnapshot = $null
        SourceRetention = $null
        DestinationRetention = $null
        Errors = @()
    }

    # Source snapshot
    if ($Profile.SourceSnapshot -and $Profile.SourceSnapshot.PersistentEnabled) {
        $sourcePath = $Profile.Source
        if ($State) { $State.CurrentActivity = "Creating source snapshot..." }
        Write-RobocurseLog -Message "Creating source persistent snapshot for profile '$($Profile.Name)': $sourcePath" -Level 'Info' -Component 'Orchestration'

        $isRemote = $sourcePath -match '^\\\\[^\\]+\\[^\\]+'

        if ($isRemote) {
            $sourceResult = Invoke-RemotePersistentSnapshot -Path $sourcePath -Side "Source" -Config $Config -ConfigPath $ConfigPath
        }
        else {
            $sourceResult = Invoke-LocalPersistentSnapshot -Path $sourcePath -Side "Source" -Config $Config -ConfigPath $ConfigPath
        }

        if ($sourceResult.Success) {
            $results.SourceSnapshot = $sourceResult.Data.Snapshot
            $results.SourceRetention = $sourceResult.Data.Retention
        }
        else {
            $results.Errors += "Source: $($sourceResult.ErrorMessage)"
        }
    }
    else {
        Write-RobocurseLog -Message "Source persistent snapshots not enabled for profile '$($Profile.Name)'" -Level 'Debug' -Component 'Orchestration'
    }

    # Destination snapshot
    if ($Profile.DestinationSnapshot -and $Profile.DestinationSnapshot.PersistentEnabled) {
        $destPath = $Profile.Destination
        if ($State) { $State.CurrentActivity = "Creating destination snapshot..." }
        Write-RobocurseLog -Message "Creating destination persistent snapshot for profile '$($Profile.Name)': $destPath" -Level 'Info' -Component 'Orchestration'

        $isRemote = $destPath -match '^\\\\[^\\]+\\[^\\]+'

        if ($isRemote) {
            $destResult = Invoke-RemotePersistentSnapshot -Path $destPath -Side "Destination" -Config $Config -ConfigPath $ConfigPath
        }
        else {
            $destResult = Invoke-LocalPersistentSnapshot -Path $destPath -Side "Destination" -Config $Config -ConfigPath $ConfigPath
        }

        if ($destResult.Success) {
            $results.DestinationSnapshot = $destResult.Data.Snapshot
            $results.DestinationRetention = $destResult.Data.Retention
        }
        else {
            $results.Errors += "Destination: $($destResult.ErrorMessage)"
        }
    }
    else {
        Write-RobocurseLog -Message "Destination persistent snapshots not enabled for profile '$($Profile.Name)'" -Level 'Debug' -Component 'Orchestration'
    }

    $success = $results.Errors.Count -eq 0
    $errorMessage = if ($results.Errors.Count -gt 0) { $results.Errors -join "; " } else { $null }

    return New-OperationResult -Success $success -Data ([PSCustomObject]$results) -ErrorMessage $errorMessage
}

function Invoke-LocalPersistentSnapshot {
    <#
    .SYNOPSIS
        Creates a persistent VSS snapshot for a local path
    .DESCRIPTION
        Creates a VSS snapshot for a local volume, enforcing retention policy first.
        Uses Get-EffectiveVolumeRetention to compute MAX retention across all profiles
        sharing this volume.
        The snapshot persists after backup completes for point-in-time recovery.
        Registers the snapshot ID in the config's SnapshotRegistry for tracking.
    .PARAMETER Path
        The local path to snapshot (used to determine volume)
    .PARAMETER Side
        "Source" or "Destination" - which side this snapshot is for
    .PARAMETER Config
        The full configuration object (for computing effective retention)
    .PARAMETER ConfigPath
        Path to the config file (for saving registry updates)
    .OUTPUTS
        OperationResult with Data containing Snapshot and Retention info
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet("Source", "Destination")]
        [string]$Side,

        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    # Get volume from path
    $volume = Get-VolumeFromPath -Path $Path
    if (-not $volume) {
        return New-OperationResult -Success $false -ErrorMessage "Cannot determine volume from path: $Path"
    }

    # Get effective retention count for this volume (MAX across all profiles)
    $keepCount = Get-EffectiveVolumeRetention -Volume $volume -Side $Side -Config $Config

    Write-RobocurseLog -Message "Enforcing $Side retention for $volume (keep: $keepCount)" -Level 'Info' -Component 'Orchestration'

    # Step 1: Enforce retention BEFORE creating new snapshot (only our registered snapshots)
    # Use KeepCount-1 to make room for the new snapshot we're about to create
    $retentionTarget = [Math]::Max(0, $keepCount - 1)
    $retentionResult = Invoke-VssRetentionPolicy -Volume $volume -KeepCount $retentionTarget -Config $Config -ConfigPath $ConfigPath
    $retentionInfo = $null
    if (-not $retentionResult.Success) {
        Write-RobocurseLog -Message "Retention enforcement failed: $($retentionResult.ErrorMessage)" -Level 'Warning' -Component 'Orchestration'
        # Continue anyway - we'll try to create the snapshot
    }
    else {
        Write-RobocurseLog -Message "Retention: deleted $($retentionResult.Data.DeletedCount), kept $($retentionResult.Data.KeptCount)" -Level 'Debug' -Component 'Orchestration'
        $retentionInfo = [PSCustomObject]@{
            Volume = $volume
            Location = "Local"
            KeptCount = $retentionResult.Data.KeptCount
            DeletedCount = $retentionResult.Data.DeletedCount
            TotalBefore = $retentionResult.Data.KeptCount + $retentionResult.Data.DeletedCount
        }
    }

    # Step 2: Create new persistent snapshot (skip tracking so it survives restarts)
    $snapshotResult = New-VssSnapshot -SourcePath $Path -SkipTracking
    if (-not $snapshotResult.Success) {
        return New-OperationResult -Success $false -ErrorMessage "Failed to create persistent snapshot: $($snapshotResult.ErrorMessage)"
    }

    # Step 3: Register the snapshot in our registry
    $registered = Register-PersistentSnapshot -Config $Config -Volume $volume -ShadowId $snapshotResult.Data.ShadowId -ConfigPath $ConfigPath
    if (-not $registered.Success) {
        Write-RobocurseLog -Message "Warning: Failed to register snapshot in registry: $($registered.ErrorMessage)" -Level 'Warning' -Component 'Orchestration'
    }

    Write-RobocurseLog -Message "Created persistent $Side snapshot: $($snapshotResult.Data.ShadowId)" -Level 'Info' -Component 'Orchestration'

    return New-OperationResult -Success $true -Data ([PSCustomObject]@{
        Snapshot = $snapshotResult.Data
        Retention = $retentionInfo
    })
}

function Invoke-RemotePersistentSnapshot {
    <#
    .SYNOPSIS
        Creates a persistent VSS snapshot on a remote server
    .DESCRIPTION
        Creates a VSS snapshot on a remote server for a UNC path,
        enforcing retention policy first. Uses Get-EffectiveVolumeRetention
        to compute MAX retention across all profiles sharing that volume.
        The snapshot persists after backup completes for point-in-time recovery.
        Registers the snapshot ID in the config's SnapshotRegistry for tracking.
    .PARAMETER Path
        The UNC path to snapshot (e.g., \\server\share)
    .PARAMETER Side
        "Source" or "Destination" - which side this snapshot is for
    .PARAMETER Config
        The full configuration object (for computing effective retention)
    .PARAMETER ConfigPath
        Path to the config file (for saving registry updates)
    .PARAMETER Credential
        Optional credential for CIM session authentication. Required for scheduled tasks
        running in Session 0 where credentials don't delegate automatically.
    .OUTPUTS
        OperationResult with Data containing Snapshot and Retention info
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet("Source", "Destination")]
        [string]$Side,

        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [PSCredential]$Credential
    )

    # Parse UNC path
    $components = Get-UncPathComponents -UncPath $Path
    if (-not $components) {
        return New-OperationResult -Success $false -ErrorMessage "Invalid UNC path: $Path"
    }

    $serverName = $components.ServerName
    $shareName = $components.ShareName

    # Get share's local path to determine volume
    $shareLocalPath = Get-RemoteShareLocalPath -ServerName $serverName -ShareName $shareName -Credential $Credential
    if (-not $shareLocalPath) {
        return New-OperationResult -Success $false -ErrorMessage "Cannot determine local path for share '$shareName' on '$serverName'"
    }

    # Extract volume
    if ($shareLocalPath -match '^([A-Za-z]:)') {
        $volume = $Matches[1].ToUpper()
    }
    else {
        return New-OperationResult -Success $false -ErrorMessage "Cannot determine volume from share path: $shareLocalPath"
    }

    # Get effective retention count (MAX across all profiles sharing this volume)
    $keepCount = Get-EffectiveVolumeRetention -Volume $volume -Side $Side -Config $Config

    Write-RobocurseLog -Message "Enforcing remote $Side retention on '$serverName' for $volume (keep: $keepCount)" -Level 'Info' -Component 'Orchestration'

    # Step 1: Enforce retention (only our registered snapshots)
    # Use KeepCount-1 to make room for the new snapshot we're about to create
    $retentionTarget = [Math]::Max(0, $keepCount - 1)
    $retentionResult = Invoke-RemoteVssRetentionPolicy -ServerName $serverName -Volume $volume -KeepCount $retentionTarget -Config $Config -ConfigPath $ConfigPath -Credential $Credential
    $retentionInfo = $null
    if (-not $retentionResult.Success) {
        Write-RobocurseLog -Message "Remote retention failed: $($retentionResult.ErrorMessage)" -Level 'Warning' -Component 'Orchestration'
    }
    else {
        Write-RobocurseLog -Message "Remote retention: deleted $($retentionResult.Data.DeletedCount), kept $($retentionResult.Data.KeptCount)" -Level 'Debug' -Component 'Orchestration'
        $retentionInfo = [PSCustomObject]@{
            Volume = $volume
            Location = "Remote:$serverName"
            KeptCount = $retentionResult.Data.KeptCount
            DeletedCount = $retentionResult.Data.DeletedCount
            TotalBefore = $retentionResult.Data.KeptCount + $retentionResult.Data.DeletedCount
        }
    }

    # Step 2: Create new persistent snapshot (skip tracking so it survives restarts)
    $snapshotResult = New-RemoteVssSnapshot -UncPath $Path -SkipTracking -Credential $Credential
    if (-not $snapshotResult.Success) {
        return New-OperationResult -Success $false -ErrorMessage "Failed to create remote persistent snapshot: $($snapshotResult.ErrorMessage)"
    }

    # Step 3: Register the snapshot in our registry
    $registered = Register-PersistentSnapshot -Config $Config -Volume $volume -ShadowId $snapshotResult.Data.ShadowId -ConfigPath $ConfigPath
    if (-not $registered.Success) {
        Write-RobocurseLog -Message "Warning: Failed to register remote snapshot in registry: $($registered.ErrorMessage)" -Level 'Warning' -Component 'Orchestration'
    }

    Write-RobocurseLog -Message "Created remote persistent $Side snapshot on '$serverName': $($snapshotResult.Data.ShadowId)" -Level 'Info' -Component 'Orchestration'

    return New-OperationResult -Success $true -Data ([PSCustomObject]@{
        Snapshot = $snapshotResult.Data
        Retention = $retentionInfo
    })
}

function Get-EffectiveVolumeRetention {
    <#
    .SYNOPSIS
        Computes the maximum retention count for a volume across all profiles
    .DESCRIPTION
        When multiple profiles have persistent snapshots enabled for the same
        volume (source or destination), returns the MAX of all retention counts.
        This ensures no profile's snapshots are prematurely deleted.

        For example, if Profile A wants 3 snapshots on D: and Profile B wants 7
        snapshots on D:, this function returns 7.
    .PARAMETER Volume
        The volume letter (e.g., "D:")
    .PARAMETER Side
        "Source" or "Destination" - which side to check
    .PARAMETER Config
        The full configuration object
    .OUTPUTS
        Integer - the maximum retention count for this volume (minimum 1 if any profile uses it)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Volume,

        [Parameter(Mandatory)]
        [ValidateSet("Source", "Destination")]
        [string]$Side,

        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $volumeUpper = $Volume.ToUpper()
    $maxRetention = 0

    foreach ($profile in $Config.SyncProfiles) {
        # Determine path and snapshot config based on side
        $path = if ($Side -eq "Source") { $profile.Source } else { $profile.Destination }
        $snapshotConfig = if ($Side -eq "Source") { $profile.SourceSnapshot } else { $profile.DestinationSnapshot }

        # Skip if no snapshot config or not enabled
        if (-not $snapshotConfig -or -not $snapshotConfig.PersistentEnabled) {
            continue
        }

        # Determine volume for this path
        $pathVolume = Get-VolumeFromPath -Path $path
        if (-not $pathVolume) { continue }

        # Check if same volume
        if ($pathVolume.ToUpper() -eq $volumeUpper) {
            $retention = if ($snapshotConfig.RetentionCount) { $snapshotConfig.RetentionCount } else { 3 }
            $maxRetention = [Math]::Max($maxRetention, $retention)
            Write-RobocurseLog -Message "Profile '$($profile.Name)' wants $retention snapshots on $volumeUpper ($Side)" -Level 'Debug' -Component 'Orchestration'
        }
    }

    # Return at least 1 if any profile uses this volume
    if ($maxRetention -eq 0) {
        $maxRetention = 3  # Default fallback
    }

    Write-RobocurseLog -Message "Effective retention for $volumeUpper ($Side): $maxRetention (MAX across all profiles)" -Level 'Debug' -Component 'Orchestration'
    return $maxRetention
}

function Start-ProfileReplication {
    <#
    .SYNOPSIS
        Starts replication for a single profile
    .DESCRIPTION
        Starts replication for a single profile. Includes duplicate run prevention -
        if the same profile is already running, returns an error instead of starting
        a concurrent run that could cause conflicts.
    .PARAMETER Profile
        Profile object from config
    .PARAMETER MaxConcurrentJobs
        Maximum parallel processes
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,

        [int]$MaxConcurrentJobs = $script:DefaultMaxConcurrentJobs
    )

    # =====================================================================================
    # DUPLICATE RUN PREVENTION
    # =====================================================================================
    # Check if this profile is already running. This prevents issues like:
    # - Drive letter conflicts when both runs try to mount the same UNC path
    # - Robocopy conflicts when both runs try to write to the same destination
    # - Checkpoint corruption from concurrent writes
    # =====================================================================================
    if (-not (Register-RunningProfile -ProfileName $Profile.Name)) {
        $errorMsg = "Profile '$($Profile.Name)' is already running. Cannot start duplicate run."
        Write-RobocurseLog -Message $errorMsg -Level 'Error' -Component 'Orchestrator'
        $script:OrchestrationState.EnqueueError($errorMsg)
        $script:CurrentPreflightError = $errorMsg
        # Skip to completion handler which will move to next profile
        Complete-CurrentProfile
        return
    }

    $state = $script:OrchestrationState
    $state.CurrentProfile = $Profile
    $state.ProfileStartTime = [datetime]::Now
    $state.ProfileStartFiles = $state.CompletedChunkFiles  # Snapshot for per-profile file counting

    # =====================================================================================
    # NETWORK PATH MOUNTING (Session 0 Scheduled Task Fix)
    # =====================================================================================
    # WHY: Scheduled tasks run in Session 0 where NTLM doesn't delegate credentials.
    # IP-based UNC paths (\\192.168.1.1\share) can't use Kerberos (no SPN).
    # Result: SMB server sees ANONYMOUS LOGON -> "Access Denied"
    #
    # FIX: Mount UNC paths to drive letters BEFORE any path access.
    # This forces explicit SMB connection establishment with proper authentication.
    # See: src/Robocurse/Public/NetworkMapping.ps1 for full explanation.
    # =====================================================================================
    $state.CurrentNetworkMappings = $null
    $state.NetworkMappedSource = $null
    $state.NetworkCredential = $null
    $state.NetworkMappedDest = $null
    $effectiveSource = $Profile.Source
    $effectiveDest = $Profile.Destination
    $networkCredential = $null  # Will be loaded if UNC paths are used

    if ($Profile.Source -match '^\\\\' -or $Profile.Destination -match '^\\\\') {
        try {
            # Load stored credentials for this profile (required for Session 0 scheduled tasks)
            # Credentials are saved via GUI when scheduling profiles with UNC paths
            # Uses DPAPI encryption - only the same user on the same machine can decrypt
            $networkCredential = Get-NetworkCredential -ProfileName $Profile.Name -ConfigPath $script:ConfigPath

            if ($networkCredential) {
                Write-RobocurseLog -Message "Using stored credentials for profile '$($Profile.Name)' (user: $($networkCredential.UserName))" -Level 'Info' -Component 'NetworkMapping'
                $state.NetworkCredential = $networkCredential  # Store for cleanup operations
            }
            else {
                Write-RobocurseLog -Message "No stored credentials for profile '$($Profile.Name)' - using session credentials (may fail in scheduled tasks)" -Level 'Debug' -Component 'NetworkMapping'
            }

            $mountResult = Mount-NetworkPaths -SourcePath $Profile.Source -DestinationPath $Profile.Destination -Credential $networkCredential
            $state.CurrentNetworkMappings = $mountResult.Mappings
            $state.NetworkMappedSource = $mountResult.SourcePath
            $state.NetworkMappedDest = $mountResult.DestinationPath
            $effectiveSource = $mountResult.SourcePath
            $effectiveDest = $mountResult.DestinationPath
            Write-RobocurseLog -Message "Network paths mounted: Source='$effectiveSource', Dest='$effectiveDest'" -Level 'Info' -Component 'NetworkMapping'
        }
        catch {
            $errorMsg = "Profile '$($Profile.Name)' failed to mount network paths: $($_.Exception.Message)"
            Write-RobocurseLog -Message $errorMsg -Level 'Error' -Component 'NetworkMapping'
            $state.EnqueueError($errorMsg)
            $script:CurrentPreflightError = $errorMsg
            Complete-CurrentProfile
            return
        }
    }

    # Pre-flight validation: Source path accessibility
    $sourceCheck = Test-SourcePathAccessible -Path $effectiveSource
    if (-not $sourceCheck.Success) {
        $errorMsg = "Profile '$($Profile.Name)' failed pre-flight check: $($sourceCheck.ErrorMessage)"
        Write-RobocurseLog -Message $errorMsg -Level 'Error' -Component 'Orchestrator'
        $state.EnqueueError($errorMsg)

        # Track pre-flight error for inclusion in profile result
        $script:CurrentPreflightError = $errorMsg

        # Skip to next profile instead of failing the whole run
        Complete-CurrentProfile
        return
    }

    # Clear any previous pre-flight error (successful pre-flight)
    $script:CurrentPreflightError = $null

    # Pre-flight validation: Destination disk space (warning only)
    $diskCheck = Test-DestinationDiskSpace -Path $effectiveDest
    if (-not $diskCheck.Success) {
        Write-RobocurseLog -Message "Profile '$($Profile.Name)' disk space warning: $($diskCheck.ErrorMessage)" `
            -Level 'Warning' -Component 'Orchestrator'
        # Continue anyway - this is a warning, not a blocker
    }

    # Pre-flight validation: Robocopy options (warnings for dangerous combinations)
    $robocopyOptions = if ($Profile.RobocopyOptions) { $Profile.RobocopyOptions } else { @{} }
    $optionsCheck = Test-RobocopyOptionsValid -Options $robocopyOptions
    if (-not $optionsCheck.Success) {
        Write-RobocurseLog -Message "Profile '$($Profile.Name)' robocopy options warning: $($optionsCheck.ErrorMessage)" `
            -Level 'Warning' -Component 'Orchestrator'
        # Continue anyway - this is a warning, not a blocker
    }

    # Extract robocopy options from profile
    $state.CurrentRobocopyOptions = @{}
    if ($Profile.RobocopyOptions) {
        # Profile has explicit RobocopyOptions hashtable
        $state.CurrentRobocopyOptions = $Profile.RobocopyOptions
    }
    elseif ($Profile.Switches -or $Profile.ExcludeFiles -or $Profile.ExcludeDirs) {
        # Profile has individual properties - build options hashtable
        $state.CurrentRobocopyOptions = @{
            Switches = if ($Profile.Switches) { @($Profile.Switches) } else { @() }
            ExcludeFiles = if ($Profile.ExcludeFiles) { @($Profile.ExcludeFiles) } else { @() }
            ExcludeDirs = if ($Profile.ExcludeDirs) { @($Profile.ExcludeDirs) } else { @() }
            NoMirror = if ($Profile.NoMirror) { $true } else { $false }
            SkipJunctions = if ($Profile.PSObject.Properties['SkipJunctions']) { $Profile.SkipJunctions } else { $true }
            RetryCount = if ($Profile.RetryCount) { $Profile.RetryCount } else { $null }
            RetryWait = if ($Profile.RetryWait) { $Profile.RetryWait } else { $null }
        }
    }

    # Per-profile MismatchSeverity override (falls back to global default)
    if ($Profile.MismatchSeverity) {
        $state.CurrentRobocopyOptions['MismatchSeverity'] = $Profile.MismatchSeverity
    }

    $state.Phase = "Preparing"
    $state.CurrentActivity = "Initializing profile: $($Profile.Name)"
    Write-RobocurseLog -Message "Starting profile: $($Profile.Name)" `
        -Level 'Info' -Component 'Orchestrator'

    Write-SiemEvent -EventType 'ProfileStart' -Data @{
        profileName = $Profile.Name
        source = $Profile.Source
        destination = $Profile.Destination
    }

    # Create persistent snapshots if enabled (separate from temp VSS for file copying)
    $snapshotResult = Invoke-ProfileSnapshots -Profile $Profile -Config $script:Config -ConfigPath $script:ConfigPath -State $state
    if (-not $snapshotResult.Success) {
        Write-RobocurseLog -Message "Persistent snapshot creation failed: $($snapshotResult.ErrorMessage)" -Level 'Warning' -Component 'Orchestration'
        # Don't fail the profile - persistent snapshots are optional enhancement
    }
    else {
        if ($snapshotResult.Data.SourceSnapshot) {
            Write-RobocurseLog -Message "Source persistent snapshot ready: $($snapshotResult.Data.SourceSnapshot.ShadowId)" -Level 'Info' -Component 'Orchestration'
        }
        if ($snapshotResult.Data.DestinationSnapshot) {
            Write-RobocurseLog -Message "Destination persistent snapshot ready: $($snapshotResult.Data.DestinationSnapshot.ShadowId)" -Level 'Info' -Component 'Orchestration'
        }
    }
    # Store snapshot results in state for later email reporting
    $state.LastSnapshotResult = $snapshotResult.Data

    # Check for stop request after persistent snapshots
    if ($state.StopRequested) {
        Write-RobocurseLog -Message "Stop requested after persistent snapshots, aborting profile setup" -Level 'Info' -Component 'Orchestrator'
        return
    }

    # VSS snapshot handling - allows copying of locked files
    $state.CurrentVssSnapshot = $null
    $state.CurrentVssJunction = $null
    # Use network-mapped source if available, otherwise original path
    $effectiveSource = if ($state.NetworkMappedSource) { $state.NetworkMappedSource } else { $Profile.Source }

    if ($Profile.UseVSS) {
        # Detect UNC path (network share)
        $isUncPath = $Profile.Source -match '^\\\\[^\\]+\\[^\\]+'

        if ($isUncPath) {
            # Remote VSS path - create snapshot on the file server
            # Use stored credentials for CIM session (required for Session 0 scheduled tasks)
            $state.CurrentActivity = "Checking remote VSS support..."
            $remoteCheck = Test-RemoteVssSupported -UncPath $Profile.Source -Credential $networkCredential

            # Check for stop request after remote VSS check
            if ($state.StopRequested) {
                Write-RobocurseLog -Message "Stop requested after remote VSS check, aborting profile setup" -Level 'Info' -Component 'Orchestrator'
                return
            }

            if ($remoteCheck.Success) {
                $state.CurrentActivity = "Creating remote VSS snapshot..."
                Write-RobocurseLog -Message "Creating remote VSS snapshot for: $($Profile.Source)" -Level 'Info' -Component 'VSS'

                $snapshotResult = New-RemoteVssSnapshot -UncPath $Profile.Source -Credential $networkCredential
                if ($snapshotResult.Success) {
                    $snapshot = $snapshotResult.Data
                    $state.CurrentVssSnapshot = $snapshot

                    # Check for stop request after remote VSS snapshot creation
                    if ($state.StopRequested) {
                        Write-RobocurseLog -Message "Stop requested after remote VSS snapshot, cleaning up" -Level 'Info' -Component 'Orchestrator'
                        $state.CurrentActivity = "Removing VSS snapshot..."
                        Remove-RemoteVssSnapshot -ShadowId $snapshot.ShadowId -ServerName $snapshot.ServerName -Credential $networkCredential
                        $state.CurrentVssSnapshot = $null
                        return
                    }

                    # Create junction to access VSS via UNC
                    $junctionResult = New-RemoteVssJunction -VssSnapshot $snapshot -Credential $networkCredential
                    if ($junctionResult.Success) {
                        $state.CurrentVssJunction = $junctionResult.Data
                        $effectiveSource = Get-RemoteVssPath -OriginalUncPath $Profile.Source -VssSnapshot $snapshot -JunctionInfo $state.CurrentVssJunction
                        Write-RobocurseLog -Message "Using remote VSS path: $effectiveSource" -Level 'Info' -Component 'VSS'

                        Write-SiemEvent -EventType 'VssSnapshotCreated' -Data @{
                            profileName = $Profile.Name
                            shadowId = $snapshot.ShadowId
                            shadowPath = $snapshot.ShadowPath
                            serverName = $snapshot.ServerName
                            isRemote = $true
                        }

                        # Check for stop request after remote VSS junction creation
                        if ($state.StopRequested) {
                            Write-RobocurseLog -Message "Stop requested after remote VSS junction, cleaning up" -Level 'Info' -Component 'Orchestrator'
                            $state.CurrentActivity = "Removing VSS junction..."
                            Remove-RemoteVssJunction -JunctionLocalPath $state.CurrentVssJunction.JunctionLocalPath -ServerName $snapshot.ServerName -Credential $networkCredential
                            $state.CurrentActivity = "Removing VSS snapshot..."
                            Remove-RemoteVssSnapshot -ShadowId $snapshot.ShadowId -ServerName $snapshot.ServerName -Credential $networkCredential
                            $state.CurrentVssJunction = $null
                            $state.CurrentVssSnapshot = $null
                            return
                        }
                    }
                    else {
                        # Junction failed - clean up snapshot and continue without VSS
                        Write-RobocurseLog -Message "Failed to create remote VSS junction: $($junctionResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
                        $state.CurrentActivity = "Removing VSS snapshot..."
                        Remove-RemoteVssSnapshot -ShadowId $snapshot.ShadowId -ServerName $snapshot.ServerName -Credential $networkCredential
                        $state.CurrentVssSnapshot = $null
                    }
                }
                else {
                    Write-RobocurseLog -Message "Failed to create remote VSS snapshot, continuing without VSS: $($snapshotResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
                }
            }
            else {
                Write-RobocurseLog -Message "Remote VSS not supported: $($remoteCheck.ErrorMessage)" -Level 'Warning' -Component 'VSS'
            }
        }
        else {
            # Local VSS path - existing behavior
            if (Test-VssSupported -Path $Profile.Source) {
                $state.CurrentActivity = "Creating VSS snapshot..."
                Write-RobocurseLog -Message "Creating VSS snapshot for: $($Profile.Source)" -Level 'Info' -Component 'VSS'
                $snapshotResult = New-VssSnapshot -SourcePath $Profile.Source

                if ($snapshotResult.Success) {
                    $snapshot = $snapshotResult.Data
                    $state.CurrentVssSnapshot = $snapshot

                    # Convert source path to use VSS shadow copy
                    $effectiveSource = Get-VssPath -OriginalPath $Profile.Source -VssSnapshot $snapshot
                    Write-RobocurseLog -Message "Using VSS path: $effectiveSource" -Level 'Info' -Component 'VSS'

                    Write-SiemEvent -EventType 'VssSnapshotCreated' -Data @{
                        profileName = $Profile.Name
                        shadowId = $snapshot.ShadowId
                        shadowPath = $snapshot.ShadowPath
                    }

                    # Check for stop request after local VSS snapshot creation
                    if ($state.StopRequested) {
                        Write-RobocurseLog -Message "Stop requested after local VSS snapshot, cleaning up" -Level 'Info' -Component 'Orchestrator'
                        $state.CurrentActivity = "Removing VSS snapshot..."
                        Remove-VssSnapshot -ShadowId $snapshot.ShadowId
                        $state.CurrentVssSnapshot = $null
                        return
                    }
                }
                else {
                    Write-RobocurseLog -Message "Failed to create VSS snapshot, continuing without VSS: $($snapshotResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
                    $state.CurrentVssSnapshot = $null
                    # Fall back to network-mapped source if available, otherwise original path
                    $effectiveSource = if ($state.NetworkMappedSource) { $state.NetworkMappedSource } else { $Profile.Source }
                }
            }
            else {
                Write-RobocurseLog -Message "VSS not supported for path: $($Profile.Source), continuing without VSS" -Level 'Warning' -Component 'VSS'
            }
        }
    }

    # Check for stop request before scanning (scanning can be slow for large directories)
    if ($state.StopRequested) {
        Write-RobocurseLog -Message "Stop requested before directory scan, aborting profile setup" -Level 'Info' -Component 'Orchestrator'
        # VSS cleanup will be handled by Stop-AllJobs when tick loop processes the stop
        return
    }

    # Build directory tree with single-pass enumeration (PERFORMANCE FIX)
    # Previously used Get-DirectoryProfile here, then re-enumerated in chunking (O(N^2) robocopy calls)
    # Now we enumerate once and pass the tree to chunking for O(1) size lookups
    $state.Phase = "Scanning"
    $state.ScanProgress = 0
    $state.CurrentActivity = "Building directory tree..."
    $directoryTree = New-DirectoryTree -RootPath $effectiveSource -State $state

    # Check for stop request after directory scan
    if ($state.StopRequested) {
        Write-RobocurseLog -Message "Stop requested after directory scan, aborting profile setup" -Level 'Info' -Component 'Orchestrator'
        return
    }

    # Generate chunks based on scan mode using the pre-built tree
    $state.ScanProgress = 0
    $state.CurrentActivity = "Creating chunks..."
    # MaxDepth is only used by Flat mode
    $maxDepth = if ($Profile.ChunkMaxDepth) { $Profile.ChunkMaxDepth } else { $script:DefaultMaxChunkDepth }

    Write-RobocurseLog -Message "Chunk settings: Mode=$($Profile.ScanMode), MaxDepth=$maxDepth (Flat only)" `
        -Level 'Debug' -Component 'Orchestrator'

    # Use network-mapped destination if available
    $effectiveDestination = if ($state.NetworkMappedDest) { $state.NetworkMappedDest } else { $Profile.Destination }

    $chunks = switch ($Profile.ScanMode) {
        'Flat' {
            New-FlatChunks `
                -Path $effectiveSource `
                -DestinationRoot $effectiveDestination `
                -MaxDepth $maxDepth `
                -State $state `
                -TreeNode $directoryTree
        }
        'Smart' {
            New-SmartChunks `
                -Path $effectiveSource `
                -DestinationRoot $effectiveDestination `
                -State $state `
                -TreeNode $directoryTree
        }
        default {
            # Default to Smart mode (unlimited depth)
            New-SmartChunks `
                -Path $effectiveSource `
                -DestinationRoot $effectiveDestination `
                -State $state `
                -TreeNode $directoryTree
        }
    }

    # Clear chunk collections for the new profile using the C# class method
    $state.ClearChunkCollections()

    # Force array context to handle PowerShell's single-item unwrapping
    # Without @(), a single chunk becomes a scalar and .Count returns $null
    $chunks = @($chunks)

    # Enqueue all chunks (RetryCount is now part of New-Chunk)
    foreach ($chunk in $chunks) {
        $state.ChunkQueue.Enqueue($chunk)
    }

    $state.TotalChunks = $chunks.Count
    $state.TotalBytes = $directoryTree.TotalSize
    $state.CompletedCount = 0
    $state.BytesComplete = 0
    $state.Phase = "Replicating"
    $state.CurrentActivity = ""  # Clear activity when replicating starts

    Write-RobocurseLog -Message "Profile scan complete: $($chunks.Count) chunks, $([math]::Round($directoryTree.TotalSize/1GB, 2)) GB" `
        -Level 'Debug' -Component 'Orchestrator'
}

function Start-ChunkJob {
    <#
    .SYNOPSIS
        Starts a robocopy job for a chunk
    .DESCRIPTION
        Starts a robocopy process for the specified chunk, applying:
        - Profile-specific robocopy options
        - Dynamic bandwidth throttling (IPG) based on aggregate limit and active jobs

        BANDWIDTH THROTTLING DESIGN:
        IPG (Inter-Packet Gap) is recalculated fresh for each job start, including retries.
        This ensures new/retried jobs get the correct bandwidth share based on CURRENT active
        job count.

        KNOWN LIMITATION (robocopy architecture):
        Running jobs keep their original IPG because robocopy's /IPG is set at process start
        and cannot be modified on a running process. When jobs complete, new jobs automatically
        get proportionally more bandwidth.

        EXAMPLE: With 100 Mbps limit and 4 jobs:
        - Initially: Each job gets ~25 Mbps
        - After 2 jobs complete: New jobs get ~50 Mbps each
        - Running jobs keep their original ~25 Mbps (robocopy limitation)
        - Total utilization may be <100 Mbps until all old jobs complete

        MITIGATION: Consider using smaller chunk sizes or higher MaxConcurrentJobs to ensure
        faster job turnover and better bandwidth utilization.
    .PARAMETER Chunk
        Chunk object to replicate
    .OUTPUTS
        Job object from Start-RobocopyJob
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Chunk
    )

    # Get log path for this chunk
    $logPath = Get-LogPath -Type 'ChunkJob' -ChunkId $Chunk.ChunkId

    # Console output for visibility
    Write-Host "[CHUNK START] Chunk $($Chunk.ChunkId): $($Chunk.SourcePath) -> $($Chunk.DestinationPath)"
    Write-Host "  Log file: $logPath"

    Write-RobocurseLog -Message "Starting chunk $($Chunk.ChunkId): $($Chunk.SourcePath)" `
        -Level 'Debug' -Component 'Orchestrator'

    Write-SiemEvent -EventType 'ChunkStart' -Data @{
        chunkId = $Chunk.ChunkId
        source = $Chunk.SourcePath
        destination = $Chunk.DestinationPath
        estimatedSize = $Chunk.EstimatedSize
    }

    # Build effective robocopy options, applying dynamic bandwidth throttling
    $effectiveOptions = @{}
    $profileOptions = $script:OrchestrationState.CurrentRobocopyOptions
    if ($profileOptions) {
        # Copy profile options
        foreach ($key in $profileOptions.Keys) {
            $effectiveOptions[$key] = $profileOptions[$key]
        }
    }

    # Apply dynamic bandwidth throttling if aggregate limit is set
    if ($script:BandwidthLimitMbps -gt 0) {
        $activeJobCount = $script:OrchestrationState.ActiveJobs.Count
        $dynamicIPG = Get-BandwidthThrottleIPG -BandwidthLimitMbps $script:BandwidthLimitMbps `
            -ActiveJobs $activeJobCount -PendingJobStart
        if ($dynamicIPG -gt 0) {
            # Dynamic IPG overrides any profile-level IPG when bandwidth limit is set
            $effectiveOptions['InterPacketGapMs'] = $dynamicIPG
        }
    }

    # Start the robocopy job with effective options
    $job = Start-RobocopyJob -Chunk $Chunk -LogPath $logPath `
        -ThreadsPerJob $script:DefaultThreadsPerJob `
        -RobocopyOptions $effectiveOptions `
        -DryRun:$script:DryRunMode

    return $job
}

function Invoke-ReplicationTick {
    <#
    .SYNOPSIS
        Called periodically (by timer) to manage job queue
    .DESCRIPTION
        - Checks for completed jobs
        - Starts new jobs if capacity available
        - Updates progress
        - Handles profile transitions
    .PARAMETER MaxConcurrentJobs
        Maximum concurrent jobs
    #>
    [CmdletBinding()]
    param(
        [int]$MaxConcurrentJobs = $script:DefaultMaxConcurrentJobs
    )

    $state = $script:OrchestrationState

    # Check for stop/pause requests
    if ($state.StopRequested) {
        Stop-AllJobs
        return
    }

    if ($state.PauseRequested) {
        return  # Don't start new jobs, but let running ones complete
    }

    # Update BytesComplete from active jobs for real-time progress
    # This runs in the background thread and updates the shared C# state object
    if (-not $state) {
        Write-RobocurseLog "Invoke-ReplicationTick: OrchestrationState is null" -Level 'Error' -Component 'Orchestrator'
        return
    }

    $bytesFromCompleted = $state.CompletedChunkBytes
    $bytesFromActive = 0
    $activeCount = $state.ActiveJobs.Count
    foreach ($kvp in $state.ActiveJobs.ToArray()) {
        try {
            $job = $kvp.Value
            $progress = Get-RobocopyProgress -Job $job
            if ($progress -and $progress.BytesCopied -gt 0) {
                $bytesFromActive += $progress.BytesCopied
                Write-RobocurseLog "Progress poll: Chunk=$($job.Chunk.ChunkId) BytesCopied=$($progress.BytesCopied)" -Level 'Debug' -Component 'Progress'
            }
        }
        catch {
            Write-RobocurseLog "Progress poll failed: $_" -Level 'Debug' -Component 'Progress'
        }
    }
    $state.BytesComplete = $bytesFromCompleted + $bytesFromActive

    if ($activeCount -gt 0) {
        Write-RobocurseLog "BytesComplete update: completed=$bytesFromCompleted + active=$bytesFromActive = $($state.BytesComplete) (ActiveJobs=$activeCount)" -Level 'Debug' -Component 'Progress'
    }

    # Check completed jobs - snapshot keys first for safe enumeration
    $activeJobsCopy = $state.ActiveJobs.ToArray()
    foreach ($kvp in $activeJobsCopy) {
        $job = $kvp.Value
        # Check if process has completed
        if ($job.Process.HasExited) {
            # Thread-safe removal from ConcurrentDictionary FIRST
            # This prevents race condition where multiple threads could process the same job
            $removedJob = $null
            $wasRemoved = $state.ActiveJobs.TryRemove($kvp.Key, [ref]$removedJob)

            # If we didn't remove it, another thread already claimed this job - skip
            if (-not $wasRemoved) {
                continue
            }

            # Process completion (only if we successfully claimed the job)
            # Use try-finally to ensure process handle is disposed even if an exception occurs
            try {
                $result = Complete-RobocopyJob -Job $removedJob

                if ($result.ExitMeaning.Severity -in @('Error', 'Fatal')) {
                    Invoke-FailedChunkHandler -Job $removedJob -Result $result
                }
                else {
                    $state.CompletedChunks.Enqueue($removedJob.Chunk)
                    # Track warning chunks separately for reporting
                    if ($result.ExitMeaning.Severity -eq 'Warning') {
                        $state.WarningChunks.Enqueue($removedJob.Chunk)
                        # Enqueue warning for GUI display
                        $warningMsg = "Chunk $($removedJob.Chunk.ChunkId) completed with warnings: $($removedJob.Chunk.SourcePath) - $($result.ExitMeaning.Message) (Exit code: $($result.ExitCode))"
                        $state.EnqueueError($warningMsg)
                    }
                    # Reset circuit breaker on success - consecutive failures counter goes back to 0
                    Reset-CircuitBreakerOnSuccess
                    # Track cumulative bytes from completed chunks (avoids O(n) iteration in Update-ProgressStats)
                    if ($removedJob.Chunk.EstimatedSize) {
                        $state.AddCompletedChunkBytes($removedJob.Chunk.EstimatedSize)
                    }
                    # Log stats for debugging
                    if ($result.Stats) {
                        Write-RobocurseLog -Message "Chunk $($removedJob.Chunk.ChunkId) stats: ParseSuccess=$($result.Stats.ParseSuccess), FilesCopied=$($result.Stats.FilesCopied), FilesSkipped=$($result.Stats.FilesSkipped), FilesFailed=$($result.Stats.FilesFailed)" -Level 'Debug' -Component 'Orchestrator'
                    }
                    else {
                        Write-RobocurseLog -Message "Chunk $($removedJob.Chunk.ChunkId) has no Stats object" -Level 'Warning' -Component 'Orchestrator'
                    }
                    # Track files copied from the parsed robocopy log
                    if ($result.Stats -and $result.Stats.FilesCopied -gt 0) {
                        $state.AddCompletedChunkFiles($result.Stats.FilesCopied)
                    }
                    # Track files that failed to copy (errors, locked files, access denied, etc.)
                    if ($result.Stats -and $result.Stats.FilesFailed -gt 0) {
                        $state.AddFilesFailed($result.Stats.FilesFailed)
                    }
                    # Track files skipped (already exist and are identical)
                    if ($result.Stats -and $result.Stats.FilesSkipped -gt 0) {
                        $state.AddFilesSkipped($result.Stats.FilesSkipped)
                    }
                }
                $newCompletedCount = $state.IncrementCompletedCount()

                # Invoke callback
                if ($script:OnChunkComplete) {
                    & $script:OnChunkComplete $removedJob $result
                }

                # Save checkpoint strategically to minimize race window while controlling I/O
                # Checkpoints are saved:
                # 1. First chunk completion (to establish checkpoint file early)
                # 2. Every N chunks (controlled by CheckpointSaveFrequency)
                # 3. On any failure (to preserve progress before potential crash)
                # 4. Profile completion (handled separately in Complete-Profile)
                #
                # NOTE: There is still a small race window between chunk completion and checkpoint save.
                # If process crashes in this window, the chunk will be re-processed on resume.
                # This is acceptable as robocopy /MIR is idempotent.
                $shouldSaveCheckpoint = (
                    ($newCompletedCount -eq 1) -or                                            # First chunk - establish checkpoint early
                    ($newCompletedCount % $script:CheckpointSaveFrequency -eq 0) -or          # Periodic save
                    ($result.ExitMeaning.Severity -in @('Error', 'Fatal'))                    # Save on failure
                )
                if ($shouldSaveCheckpoint) {
                    Save-ReplicationCheckpoint | Out-Null
                }
            }
            finally {
                # Dispose process handle to prevent resource leaks
                # Check for Dispose method to handle mock objects in tests
                if ($removedJob.Process -and $removedJob.Process.PSObject.Methods['Dispose']) {
                    $removedJob.Process.Dispose()
                }
            }
        }
    }

    # Start new jobs - use TryDequeue for thread-safe queue access
    # Keep a list of chunks that need to be re-queued due to backoff delay
    $chunksToRequeue = [System.Collections.Generic.List[object]]::new()

    while (($state.ActiveJobs.Count -lt $MaxConcurrentJobs) -and
           ($state.ChunkQueue.Count -gt 0)) {
        $chunk = $null
        if ($state.ChunkQueue.TryDequeue([ref]$chunk)) {
            # Check if chunk was completed in previous run (resume from checkpoint)
            # Use pre-built HashSet for O(1) lookup instead of O(N) linear search
            if ($script:CurrentCheckpoint -and (Test-ChunkAlreadyCompleted -Chunk $chunk -Checkpoint $script:CurrentCheckpoint -CompletedPathsHashSet $script:CompletedPathsHashSet)) {
                # Skip this chunk - DON'T enqueue to CompletedChunks to prevent memory leak
                # The chunk is already tracked in the checkpoint file, no need to hold in memory
                # Track separately for accurate reporting (skipped vs actually completed this run)
                $chunk.Status = 'Skipped'
                $state.IncrementCompletedCount()
                $state.IncrementSkippedCount()
                if ($chunk.EstimatedSize) {
                    $state.AddCompletedChunkBytes($chunk.EstimatedSize)
                    $state.AddSkippedChunkBytes($chunk.EstimatedSize)
                }
                Write-RobocurseLog -Message "Chunk $($chunk.ChunkId) skipped (already completed in previous run)" `
                    -Level 'Debug' -Component 'Checkpoint'
                continue
            }

            # Check if chunk is in backoff delay period (exponential backoff for retries)
            if ($chunk.RetryAfter -and [datetime]::Now -lt $chunk.RetryAfter) {
                # Not ready yet - re-queue for later
                $chunksToRequeue.Add($chunk)
                continue
            }

            $job = Start-ChunkJob -Chunk $chunk

            # Handle job start failure (null job returned)
            if ($null -eq $job -or $null -eq $job.Process) {
                Write-RobocurseLog -Message "Failed to start job for chunk $($chunk.ChunkId)" `
                    -Level 'Error' -Component 'Orchestrator'
                $chunk.RetryCount++
                if ($chunk.RetryCount -lt $script:MaxChunkRetries) {
                    # Use exponential backoff for consistency with Invoke-FailedChunkHandler
                    $backoffDelay = Get-RetryBackoffDelay -RetryCount $chunk.RetryCount
                    $chunk.RetryAfter = [datetime]::Now.AddSeconds($backoffDelay)
                    $chunksToRequeue.Add($chunk)
                }
                else {
                    $chunk.Status = 'Failed'
                    $state.FailedChunks.Enqueue($chunk)
                    $state.EnqueueError("Chunk $($chunk.ChunkId) failed to start after $($chunk.RetryCount) attempts")
                }
                continue
            }

            $state.ActiveJobs[$job.Process.Id] = $job
        }
    }

    # Re-queue any chunks that were in backoff delay
    foreach ($chunk in $chunksToRequeue) {
        $state.ChunkQueue.Enqueue($chunk)
    }

    # Check if profile complete
    if (($state.ChunkQueue.Count -eq 0) -and ($state.ActiveJobs.Count -eq 0)) {
        Complete-CurrentProfile
    }

    # Update progress
    Update-ProgressStats

    # Update health check status file (respects interval internally)
    Write-HealthCheckStatus | Out-Null

    # Invoke progress callback
    if ($script:OnProgress) {
        $status = Get-OrchestrationStatus
        & $script:OnProgress $status
    }
}

function Complete-RobocopyJob {
    <#
    .SYNOPSIS
        Processes a completed robocopy job
    .PARAMETER Job
        Job object that has finished
    .OUTPUTS
        Result object with exit code, stats, etc.
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject]$Job
    )

    $exitCode = $Job.Process.ExitCode

    # Get per-profile MismatchSeverity or use global default
    $mismatchSeverity = $script:DefaultMismatchSeverity
    $profileOptions = $script:OrchestrationState.CurrentRobocopyOptions
    if ($profileOptions -and $profileOptions['MismatchSeverity']) {
        $mismatchSeverity = $profileOptions['MismatchSeverity']
    }

    $exitMeaning = Get-RobocopyExitMeaning -ExitCode $exitCode -MismatchSeverity $mismatchSeverity

    # Clean up the event subscription to prevent memory leaks
    # Note: ProgressBuffer is used for real-time progress during the job (Get-RobocopyProgress),
    # but for final stats we always read from the log file which is reliably flushed when robocopy exits.
    # The stdout capture has race conditions - final stats lines may not be processed before we read.
    if ($Job.OutputEvent) {
        try {
            Unregister-Event -SourceIdentifier $Job.OutputEvent.Name -ErrorAction SilentlyContinue
            Remove-Job -Id $Job.OutputEvent.Id -Force -ErrorAction SilentlyContinue
        } catch { }
    }

    # Parse final stats from log file (authoritative source - robocopy flushes before exit)
    # Do NOT use captured stdout here - race condition with OutputDataReceived event processing
    $stats = ConvertFrom-RobocopyLog -LogPath $Job.LogPath

    $duration = [datetime]::Now - $Job.StartTime

    # Update chunk status
    $Job.Chunk.Status = switch ($exitMeaning.Severity) {
        'Success' { 'Complete' }
        'Warning' { 'CompleteWithWarnings' }
        'Error'   { 'Failed' }
        'Fatal'   { 'Failed' }
    }

    # Log result with error details if available
    $logMessage = "Chunk $($Job.Chunk.ChunkId) completed: $($exitMeaning.Message) (exit code $exitCode)"
    if ($exitMeaning.FatalError -or $exitMeaning.CopyErrors) {
        if ($stats.ErrorMessage) {
            $logMessage += " - Errors: $($stats.ErrorMessage)"
        }
        # Also output to console for visibility during GUI mode
        Write-Host "[ROBOCOPY FAILURE] Chunk $($Job.Chunk.ChunkId): $($stats.ErrorMessage)" -ForegroundColor Red
        Write-Host "  Source: $($Job.Chunk.SourcePath)" -ForegroundColor Red
        Write-Host "  Destination: $($Job.Chunk.DestinationPath)" -ForegroundColor Red
        Write-Host "  Log file: $($Job.LogPath)" -ForegroundColor Red
    }
    Write-RobocurseLog -Message $logMessage `
        -Level $(if ($exitMeaning.Severity -eq 'Success') { 'Debug' } else { 'Warning' }) `
        -Component 'Orchestrator'

    # Write SIEM event
    Write-SiemEvent -EventType 'ChunkComplete' -Data @{
        chunkId = $Job.Chunk.ChunkId
        source = $Job.Chunk.SourcePath
        destination = $Job.Chunk.DestinationPath
        exitCode = $exitCode
        severity = $exitMeaning.Severity
        filesCopied = $stats.FilesCopied
        bytesCopied = $stats.BytesCopied
        durationMs = $duration.TotalMilliseconds
    }

    return [PSCustomObject]@{
        Job = $Job
        ExitCode = $exitCode
        ExitMeaning = $exitMeaning
        Stats = $stats
        Duration = $duration
    }
}

function Get-RetryBackoffDelay {
    <#
    .SYNOPSIS
        Calculates exponential backoff delay for retry attempts
    .DESCRIPTION
        Uses exponential backoff formula: base * (multiplier ^ retryCount)
        with a maximum cap to prevent excessively long waits.
    .PARAMETER RetryCount
        Current retry attempt (1-based)
    .OUTPUTS
        Delay in seconds (integer)
    .EXAMPLE
        Get-RetryBackoffDelay -RetryCount 1  # Returns 5 (base delay)
        Get-RetryBackoffDelay -RetryCount 2  # Returns 10 (5 * 2^1)
        Get-RetryBackoffDelay -RetryCount 3  # Returns 20 (5 * 2^2)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 100)]
        [int]$RetryCount
    )

    $base = $script:RetryBackoffBaseSeconds
    $multiplier = $script:RetryBackoffMultiplier
    $maxDelay = $script:RetryBackoffMaxSeconds

    # Calculate: base * (multiplier ^ (retryCount - 1))
    # RetryCount 1 = base * 1 = base seconds
    # RetryCount 2 = base * multiplier
    # RetryCount 3 = base * multiplier^2
    $delay = [math]::Ceiling($base * [math]::Pow($multiplier, $RetryCount - 1))

    # Cap at maximum
    return [math]::Min($delay, $maxDelay)
}

function Invoke-FailedChunkHandler {
    <#
    .SYNOPSIS
        Processes a failed chunk - retry or mark as permanently failed
    .DESCRIPTION
        Uses exponential backoff for retries to be gentler on infrastructure
        during transient failures. Backoff delays: 5s -> 10s -> 20s (capped at 120s)
    .PARAMETER Job
        Failed job object
    .PARAMETER Result
        Result from Complete-RobocopyJob
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject]$Job,
        [PSCustomObject]$Result
    )

    $chunk = $Job.Chunk

    # Store error details on chunk for tooltip display
    $chunk | Add-Member -NotePropertyName 'LastExitCode' -NotePropertyValue $Result.ExitCode -Force
    $chunk | Add-Member -NotePropertyName 'LastErrorMessage' -NotePropertyValue $Result.ExitMeaning.Message -Force
    $chunk | Add-Member -NotePropertyName 'DestinationPath' -NotePropertyValue $chunk.DestinationPath -Force

    # Increment retry count (RetryCount is initialized in New-Chunk)
    $chunk.RetryCount++

    if ($chunk.RetryCount -lt $script:MaxChunkRetries -and $Result.ExitMeaning.ShouldRetry) {
        # Calculate exponential backoff delay
        $backoffDelay = Get-RetryBackoffDelay -RetryCount $chunk.RetryCount

        Write-RobocurseLog -Message "Chunk $($chunk.ChunkId) failed, retrying in ${backoffDelay}s ($($chunk.RetryCount)/$script:MaxChunkRetries)" `
            -Level 'Warning' -Component 'Orchestrator'

        # Store retry time on chunk for delayed re-queue
        $chunk.RetryAfter = [datetime]::Now.AddSeconds($backoffDelay)

        # Re-queue for retry (thread-safe ConcurrentQueue)
        $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
    }
    else {
        # Mark as permanently failed (thread-safe ConcurrentQueue)
        $chunk.Status = 'Failed'
        $script:OrchestrationState.FailedChunks.Enqueue($chunk)

        # Enqueue error for real-time GUI display
        $errorMsg = "Chunk $($chunk.ChunkId) failed: $($chunk.SourcePath) - $($Result.ExitMeaning.Message) (Exit code: $($Result.ExitCode))"
        $script:OrchestrationState.EnqueueError($errorMsg)

        Write-RobocurseLog -Message "Chunk $($chunk.ChunkId) failed permanently after $($chunk.RetryCount) attempts" `
            -Level 'Error' -Component 'Orchestrator'

        Write-SiemEvent -EventType 'ChunkError' -Data @{
            chunkId = $chunk.ChunkId
            source = $chunk.SourcePath
            retryCount = $chunk.RetryCount
            exitCode = $Result.ExitCode
        }

        # Check circuit breaker - trips if too many consecutive permanent failures
        Invoke-CircuitBreakerCheck -ChunkId $chunk.ChunkId -ErrorMessage $Result.ExitMeaning.Message | Out-Null
    }
}

function Complete-CurrentProfile {
    <#
    .SYNOPSIS
        Completes the current profile and moves to next
    .DESCRIPTION
        Handles profile completion: logs results, cleans up VSS snapshots,
        stores profile results for email reporting, and advances to next profile.
        Also clears completed chunks to prevent memory growth during long runs.
    #>
    [CmdletBinding()]
    param()

    $state = $script:OrchestrationState

    if ($null -eq $state.CurrentProfile) {
        return
    }

    $profileDuration = [datetime]::Now - $state.ProfileStartTime

    # Calculate profile statistics before clearing
    $completedChunksArray = $state.CompletedChunks.ToArray()
    $failedChunksArray = $state.FailedChunks.ToArray()
    $skippedChunkCount = $state.SkippedChunkCount
    $skippedChunkBytes = $state.SkippedChunkBytes

    # Calculate bytes: sum from queue (actually copied this run) + skipped (from checkpoint)
    $profileBytesCopied = 0
    foreach ($chunk in $completedChunksArray) {
        if ($chunk.EstimatedSize) {
            $profileBytesCopied += $chunk.EstimatedSize
        }
    }
    # Add bytes from skipped chunks (already completed in previous run)
    $profileBytesCopied += $skippedChunkBytes

    # Calculate files copied for this profile (delta from profile start)
    $profileFilesCopied = $state.CompletedChunkFiles - $state.ProfileStartFiles

    # Total completed = queue count (this run) + skipped (checkpoint resume)
    $totalCompleted = $completedChunksArray.Count + $skippedChunkCount

    # Determine profile status - Failed if pre-flight error, Warning if chunk failures, else Success
    $profileStatus = if ($script:CurrentPreflightError) {
        'Failed'
    } elseif ($failedChunksArray.Count -gt 0) {
        'Warning'
    } else {
        'Success'
    }

    # Build errors array - include pre-flight error if present, plus chunk errors
    $profileErrors = @()
    if ($script:CurrentPreflightError) {
        $profileErrors += $script:CurrentPreflightError
    }
    $profileErrors += @($failedChunksArray | ForEach-Object { "Chunk $($_.ChunkId): $($_.SourcePath)" })

    # Store profile result for email/reporting (prevents memory leak by summarizing)
    $profileResult = [PSCustomObject]@{
        Name = $state.CurrentProfile.Name
        Source = $state.CurrentProfile.Source
        Destination = $state.CurrentProfile.Destination
        Status = $profileStatus
        PreflightError = $script:CurrentPreflightError
        ChunksComplete = $totalCompleted
        ChunksSkipped = $skippedChunkCount
        ChunksTotal = $state.TotalChunks
        ChunksFailed = $failedChunksArray.Count
        BytesCopied = $profileBytesCopied
        FilesCopied = $profileFilesCopied
        Duration = $profileDuration
        Errors = $profileErrors
    }

    # Clear the pre-flight error after including in result
    $script:CurrentPreflightError = $null

    # Add to ProfileResults (thread-safe ConcurrentQueue)
    $state.ProfileResults.Enqueue($profileResult)

    $profileCompleteMsg = "Profile complete: $($state.CurrentProfile.Name) ($($state.CurrentProfile.Source) -> $($state.CurrentProfile.Destination)) in $($profileDuration.ToString('hh\:mm\:ss'))"
    Write-RobocurseLog -Message $profileCompleteMsg -Level 'Info' -Component 'Orchestrator'
    # Also write to host for visibility in background runspace console output
    Write-Host "[PROFILE] $profileCompleteMsg"

    Write-SiemEvent -EventType 'ProfileComplete' -Data @{
        profileName = $state.CurrentProfile.Name
        chunksCompleted = $totalCompleted
        chunksSkipped = $skippedChunkCount
        chunksFailed = $failedChunksArray.Count
        durationMs = $profileDuration.TotalMilliseconds
    }

    # Clean up remote VSS junction first (if any)
    if ($state.CurrentVssJunction) {
        Write-RobocurseLog -Message "Cleaning up remote VSS junction" -Level 'Info' -Component 'VSS'
        $state.CurrentActivity = "Removing VSS junction..."
        $removeJunctionResult = Remove-RemoteVssJunction `
            -JunctionLocalPath $state.CurrentVssJunction.JunctionLocalPath `
            -ServerName $state.CurrentVssJunction.ServerName `
            -Credential $state.NetworkCredential
        if (-not $removeJunctionResult.Success) {
            Write-RobocurseLog -Message "Failed to cleanup remote junction: $($removeJunctionResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
        }
        $state.CurrentVssJunction = $null
    }

    # Clean up VSS snapshot (local or remote)
    if ($state.CurrentVssSnapshot) {
        $state.CurrentActivity = "Removing VSS snapshot..."
        if ($state.CurrentVssSnapshot.IsRemote) {
            Write-RobocurseLog -Message "Cleaning up remote VSS snapshot: $($state.CurrentVssSnapshot.ShadowId)" -Level 'Info' -Component 'VSS'
            $removeResult = Remove-RemoteVssSnapshot -ShadowId $state.CurrentVssSnapshot.ShadowId -ServerName $state.CurrentVssSnapshot.ServerName -Credential $state.NetworkCredential
        }
        else {
            Write-RobocurseLog -Message "Cleaning up VSS snapshot: $($state.CurrentVssSnapshot.ShadowId)" -Level 'Info' -Component 'VSS'
            $removeResult = Remove-VssSnapshot -ShadowId $state.CurrentVssSnapshot.ShadowId
        }

        if ($removeResult.Success) {
            Write-SiemEvent -EventType 'VssSnapshotRemoved' -Data @{
                profileName = $state.CurrentProfile.Name
                shadowId = $state.CurrentVssSnapshot.ShadowId
                isRemote = [bool]$state.CurrentVssSnapshot.IsRemote
            }
        }
        else {
            Write-RobocurseLog -Message "Failed to clean up VSS snapshot: $($removeResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
        }

        $state.CurrentVssSnapshot = $null
    }

    # Clean up network mappings
    if ($state.CurrentNetworkMappings -and $state.CurrentNetworkMappings.Count -gt 0) {
        Write-RobocurseLog -Message "Cleaning up network mappings" -Level 'Debug' -Component 'NetworkMapping'
        Dismount-NetworkPaths -Mappings $state.CurrentNetworkMappings
        $state.CurrentNetworkMappings = $null
        $state.NetworkMappedSource = $null
        $state.NetworkMappedDest = $null
    }
    $state.NetworkCredential = $null

    # Unregister the profile as running (release the mutex)
    Unregister-RunningProfile -ProfileName $state.CurrentProfile.Name | Out-Null

    # Invoke callback
    if ($script:OnProfileComplete) {
        & $script:OnProfileComplete $state.CurrentProfile
    }

    # Clear chunk collections for next profile (results already preserved in ProfileResults)
    $state.ClearChunkCollections()

    # Move to next profile
    $state.ProfileIndex++
    if ($state.ProfileIndex -lt $state.Profiles.Count) {
        # Use MaxConcurrentJobs from current run (stored in script-scope during Start-ReplicationRun)
        $maxJobs = if ($script:CurrentMaxConcurrentJobs) { $script:CurrentMaxConcurrentJobs } else { $script:DefaultMaxConcurrentJobs }
        Start-ProfileReplication -Profile $state.Profiles[$state.ProfileIndex] -MaxConcurrentJobs $maxJobs
    }
    else {
        # All profiles complete
        $state.Phase = "Complete"
        # Guard against null StartTime (e.g., when Start-ProfileReplication called directly in tests)
        $totalDuration = if ($null -ne $state.StartTime) {
            [datetime]::Now - $state.StartTime
        } else {
            [TimeSpan]::Zero
        }

        # Remove checkpoint file on successful completion
        Remove-ReplicationCheckpoint | Out-Null

        # Write final health status and clean up
        Write-HealthCheckStatus -Force | Out-Null
        Remove-HealthCheckStatus

        Write-RobocurseLog -Message "All profiles complete in $($totalDuration.ToString('hh\:mm\:ss'))" `
            -Level 'Info' -Component 'Orchestrator'

        Write-SiemEvent -EventType 'SessionEnd' -Data @{
            profileCount = $state.Profiles.Count
            totalChunks = $state.CompletedCount
            failedChunks = ($state.GetProfileResultsArray() | Measure-Object -Property ChunksFailed -Sum).Sum
            durationMs = $totalDuration.TotalMilliseconds
        }
    }
}

function Stop-AllJobs {
    <#
    .SYNOPSIS
        Stops all running robocopy processes
    #>
    [CmdletBinding()]
    param()

    $state = $script:OrchestrationState

    Write-RobocurseLog -Message "Stopping all jobs ($($state.ActiveJobs.Count) active)" `
        -Level 'Warning' -Component 'Orchestrator'

    foreach ($job in $state.ActiveJobs.Values) {
        try {
            # Check HasExited property - only kill if process is still running
            if (-not $job.Process.HasExited) {
                $job.Process.Kill()
                # Wait briefly for process to exit before disposing
                $job.Process.WaitForExit($script:ProcessStopTimeoutMs)
                Write-RobocurseLog -Message "Killed chunk $($job.Chunk.ChunkId)" -Level 'Warning' -Component 'Orchestrator'
            }
        }
        catch {
            Write-RobocurseLog -Message "Failed to kill chunk $($job.Chunk.ChunkId): $_" -Level 'Error' -Component 'Orchestrator'
        }
        finally {
            # Always dispose the process object to release handles
            try { $job.Process.Dispose() } catch { }
        }
    }

    $state.ActiveJobs.Clear()
    $state.Phase = "Stopped"

    # Clean up remote VSS junction first (if any)
    if ($state.CurrentVssJunction) {
        Write-RobocurseLog -Message "Cleaning up remote VSS junction after stop" -Level 'Info' -Component 'VSS'
        $state.CurrentActivity = "Removing VSS junction..."
        try {
            $removeJunctionResult = Remove-RemoteVssJunction `
                -JunctionLocalPath $state.CurrentVssJunction.JunctionLocalPath `
                -ServerName $state.CurrentVssJunction.ServerName `
                -Credential $state.NetworkCredential
            if (-not $removeJunctionResult.Success) {
                Write-RobocurseLog -Message "Failed to cleanup remote junction: $($removeJunctionResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
            }
        }
        catch {
            Write-RobocurseLog -Message "Exception during remote VSS junction cleanup: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        }
        finally {
            $state.CurrentVssJunction = $null
        }
    }

    # Clean up VSS snapshot (local or remote)
    if ($state.CurrentVssSnapshot) {
        $state.CurrentActivity = "Removing VSS snapshot..."
        if ($state.CurrentVssSnapshot.IsRemote) {
            Write-RobocurseLog -Message "Cleaning up remote VSS snapshot after stop: $($state.CurrentVssSnapshot.ShadowId)" -Level 'Info' -Component 'VSS'
            try {
                $removeResult = Remove-RemoteVssSnapshot -ShadowId $state.CurrentVssSnapshot.ShadowId -ServerName $state.CurrentVssSnapshot.ServerName -Credential $state.NetworkCredential
                if (-not $removeResult.Success) {
                    Write-RobocurseLog -Message "Failed to clean up remote VSS snapshot: $($removeResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
                }
            }
            catch {
                Write-RobocurseLog -Message "Exception during remote VSS snapshot cleanup: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
            }
            finally {
                $state.CurrentVssSnapshot = $null
            }
        }
        else {
            Write-RobocurseLog -Message "Cleaning up VSS snapshot after stop: $($state.CurrentVssSnapshot.ShadowId)" -Level 'Info' -Component 'VSS'
            try {
                $removeResult = Remove-VssSnapshot -ShadowId $state.CurrentVssSnapshot.ShadowId
                if (-not $removeResult.Success) {
                    Write-RobocurseLog -Message "Failed to clean up VSS snapshot: $($removeResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
                }
            }
            catch {
                Write-RobocurseLog -Message "Exception during VSS snapshot cleanup: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
            }
            finally {
                # Always clear the reference to prevent retry attempts on stale snapshot
                $state.CurrentVssSnapshot = $null
            }
        }
    }

    # Clean up network drive mappings
    if ($state.CurrentNetworkMappings -and $state.CurrentNetworkMappings.Count -gt 0) {
        Write-RobocurseLog -Message "Cleaning up network mappings after stop ($($state.CurrentNetworkMappings.Count) mapping(s))" `
            -Level 'Info' -Component 'NetworkMapping'
        try {
            Dismount-NetworkPaths -Mappings $state.CurrentNetworkMappings
        }
        catch {
            Write-RobocurseLog -Message "Failed to cleanup network mappings: $($_.Exception.Message)" `
                -Level 'Warning' -Component 'NetworkMapping'
        }
        finally {
            $state.CurrentNetworkMappings = $null
            $state.NetworkMappedSource = $null
            $state.NetworkMappedDest = $null
        }
    }
    $state.NetworkCredential = $null

    # Unregister the current profile as running (release the mutex)
    if ($state.CurrentProfile) {
        Unregister-RunningProfile -ProfileName $state.CurrentProfile.Name | Out-Null
    }

    Write-SiemEvent -EventType 'SessionEnd' -Data @{
        reason = 'Stopped by user'
        chunksCompleted = $state.CompletedCount
        chunksPending = $state.ChunkQueue.Count
    }
}

function Request-Stop {
    <#
    .SYNOPSIS
        Requests graceful stop (finish current jobs, don't start new)
    #>
    [CmdletBinding()]
    param()

    $script:OrchestrationState.StopRequested = $true

    Write-RobocurseLog -Message "Stop requested" `
        -Level 'Info' -Component 'Orchestrator'
}

function Request-Pause {
    <#
    .SYNOPSIS
        Pauses job queue (running jobs continue, no new starts)
    #>
    [CmdletBinding()]
    param()

    $script:OrchestrationState.PauseRequested = $true

    Write-RobocurseLog -Message "Pause requested" `
        -Level 'Info' -Component 'Orchestrator'
}

function Request-Resume {
    <#
    .SYNOPSIS
        Resumes paused job queue
    #>
    [CmdletBinding()]
    param()

    $script:OrchestrationState.PauseRequested = $false

    Write-RobocurseLog -Message "Resume requested" `
        -Level 'Info' -Component 'Orchestrator'
}
