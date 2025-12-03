# Robocurse Orchestration Functions
# Script variable to track if C# type has been initialized (for lazy loading)
$script:OrchestrationTypeInitialized = $false
$script:OrchestrationState = $null

function Initialize-OrchestrationStateType {
    <#
    .SYNOPSIS
        Lazy-loads the C# orchestration state type
    .DESCRIPTION
        Compiles and loads the C# OrchestrationState class only when first needed.
        This defers the Add-Type overhead until orchestration is actually used,
        improving script startup time for GUI and help commands.

        The type is only compiled once per PowerShell session. Subsequent calls
        return immediately if the type already exists.
    .OUTPUTS
        $true if type is available, $false on compilation failure
    #>
    [CmdletBinding()]
    param()

    # Fast path: already initialized this session
    if ($script:OrchestrationTypeInitialized -and $script:OrchestrationState) {
        return $true
    }

    # Check if type exists from a previous session/import
    if (([System.Management.Automation.PSTypeName]'Robocurse.OrchestrationState').Type) {
        $script:OrchestrationTypeInitialized = $true
        if (-not $script:OrchestrationState) {
            $script:OrchestrationState = [Robocurse.OrchestrationState]::new()
        }
        return $true
    }

    # Compile the C# type (this is the expensive operation we're deferring)
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Threading;

namespace Robocurse
{
    /// <summary>
    /// Thread-safe orchestration state for cross-runspace communication.
    /// Scalar properties use locking, collections use concurrent types.
    /// </summary>
    public class OrchestrationState
    {
        private readonly object _lock = new object();

        // Session identity (set once, read many - but locked for safety)
        private string _sessionId;
        public string SessionId
        {
            get { lock (_lock) { return _sessionId; } }
            set { lock (_lock) { _sessionId = value; } }
        }

        // Current execution phase: Idle, Scanning, Replicating, Complete, Stopped
        private string _phase = "Idle";
        public string Phase
        {
            get { lock (_lock) { return _phase; } }
            set { lock (_lock) { _phase = value; } }
        }

        // Current profile being processed (PSCustomObject from PowerShell)
        private object _currentProfile;
        public object CurrentProfile
        {
            get { lock (_lock) { return _currentProfile; } }
            set { lock (_lock) { _currentProfile = value; } }
        }

        // Index into Profiles array
        private int _profileIndex;
        public int ProfileIndex
        {
            get { lock (_lock) { return _profileIndex; } }
            set { lock (_lock) { _profileIndex = value; } }
        }

        // Total chunks for current profile
        private int _totalChunks;
        public int TotalChunks
        {
            get { lock (_lock) { return _totalChunks; } }
            set { lock (_lock) { _totalChunks = value; } }
        }

        // Completed chunk count (use Interlocked for atomic increment)
        private int _completedCount;
        public int CompletedCount
        {
            get { return Interlocked.CompareExchange(ref _completedCount, 0, 0); }
            set { Interlocked.Exchange(ref _completedCount, value); }
        }

        /// <summary>Atomically increment CompletedCount and return new value</summary>
        public int IncrementCompletedCount()
        {
            return Interlocked.Increment(ref _completedCount);
        }

        // Total bytes for current profile
        private long _totalBytes;
        public long TotalBytes
        {
            get { return Interlocked.Read(ref _totalBytes); }
            set { Interlocked.Exchange(ref _totalBytes, value); }
        }

        // Bytes completed (use Interlocked for atomic add)
        private long _bytesComplete;
        public long BytesComplete
        {
            get { return Interlocked.Read(ref _bytesComplete); }
            set { Interlocked.Exchange(ref _bytesComplete, value); }
        }

        /// <summary>Atomically add to BytesComplete and return new value</summary>
        public long AddBytesComplete(long bytes)
        {
            return Interlocked.Add(ref _bytesComplete, bytes);
        }

        // Cumulative bytes from completed chunks (avoids iterating CompletedChunks queue)
        // This is the running total of EstimatedSize from all completed chunks
        private long _completedChunkBytes;
        public long CompletedChunkBytes
        {
            get { return Interlocked.Read(ref _completedChunkBytes); }
            set { Interlocked.Exchange(ref _completedChunkBytes, value); }
        }

        /// <summary>Atomically add bytes from a completed chunk</summary>
        public long AddCompletedChunkBytes(long bytes)
        {
            return Interlocked.Add(ref _completedChunkBytes, bytes);
        }

        // Cumulative files copied from completed chunks
        private long _completedChunkFiles;
        public long CompletedChunkFiles
        {
            get { return Interlocked.Read(ref _completedChunkFiles); }
            set { Interlocked.Exchange(ref _completedChunkFiles, value); }
        }

        /// <summary>Atomically add files from a completed chunk</summary>
        public long AddCompletedChunkFiles(long files)
        {
            return Interlocked.Add(ref _completedChunkFiles, files);
        }

        // Skipped chunk tracking (for checkpoint resume - not added to CompletedChunks queue)
        private int _skippedChunkCount;
        public int SkippedChunkCount
        {
            get { return Interlocked.CompareExchange(ref _skippedChunkCount, 0, 0); }
            set { Interlocked.Exchange(ref _skippedChunkCount, value); }
        }

        /// <summary>Atomically increment skipped chunk count</summary>
        public int IncrementSkippedCount()
        {
            return Interlocked.Increment(ref _skippedChunkCount);
        }

        private long _skippedChunkBytes;
        public long SkippedChunkBytes
        {
            get { return Interlocked.Read(ref _skippedChunkBytes); }
            set { Interlocked.Exchange(ref _skippedChunkBytes, value); }
        }

        /// <summary>Atomically add bytes from a skipped chunk</summary>
        public long AddSkippedChunkBytes(long bytes)
        {
            return Interlocked.Add(ref _skippedChunkBytes, bytes);
        }

        // Snapshot of files at profile start (for per-profile file counting)
        private long _profileStartFiles;
        public long ProfileStartFiles
        {
            get { return Interlocked.Read(ref _profileStartFiles); }
            set { Interlocked.Exchange(ref _profileStartFiles, value); }
        }

        // Timing (nullable DateTime via object boxing)
        private object _startTime;
        public object StartTime
        {
            get { lock (_lock) { return _startTime; } }
            set { lock (_lock) { _startTime = value; } }
        }

        private object _profileStartTime;
        public object ProfileStartTime
        {
            get { lock (_lock) { return _profileStartTime; } }
            set { lock (_lock) { _profileStartTime = value; } }
        }

        // Control flags (volatile for cross-thread visibility)
        private volatile bool _stopRequested;
        public bool StopRequested
        {
            get { return _stopRequested; }
            set { _stopRequested = value; }
        }

        private volatile bool _pauseRequested;
        public bool PauseRequested
        {
            get { return _pauseRequested; }
            set { _pauseRequested = value; }
        }

        // Arrays set once per run (protected by lock for reference safety)
        private object[] _profiles;
        public object[] Profiles
        {
            get { lock (_lock) { return _profiles; } }
            set { lock (_lock) { _profiles = value; } }
        }

        // Per-profile configuration (set once per profile, read during execution)
        private object _currentRobocopyOptions;
        public object CurrentRobocopyOptions
        {
            get { lock (_lock) { return _currentRobocopyOptions; } }
            set { lock (_lock) { _currentRobocopyOptions = value; } }
        }

        private object _currentVssSnapshot;
        public object CurrentVssSnapshot
        {
            get { lock (_lock) { return _currentVssSnapshot; } }
            set { lock (_lock) { _currentVssSnapshot = value; } }
        }

        // Thread-safe collections (no additional locking needed)
        public ConcurrentQueue<object> ChunkQueue { get; private set; }
        public ConcurrentDictionary<int, object> ActiveJobs { get; private set; }
        public ConcurrentQueue<object> CompletedChunks { get; private set; }  // Queue for ordering
        public ConcurrentQueue<object> FailedChunks { get; private set; }     // Queue for consistency
        public ConcurrentQueue<object> ProfileResults { get; private set; }   // Accumulated results
        public ConcurrentQueue<string> ErrorMessages { get; private set; }    // Real-time error streaming

        /// <summary>Add an error message to the queue for GUI consumption</summary>
        public void EnqueueError(string message)
        {
            ErrorMessages.Enqueue(message);
        }

        /// <summary>Dequeue all pending error messages</summary>
        public string[] DequeueErrors()
        {
            var errors = new System.Collections.Generic.List<string>();
            string error;
            while (ErrorMessages.TryDequeue(out error))
            {
                errors.Add(error);
            }
            return errors.ToArray();
        }

        /// <summary>Create a new orchestration state with fresh collections</summary>
        public OrchestrationState()
        {
            _sessionId = Guid.NewGuid().ToString();
            ChunkQueue = new ConcurrentQueue<object>();
            ActiveJobs = new ConcurrentDictionary<int, object>();
            CompletedChunks = new ConcurrentQueue<object>();
            FailedChunks = new ConcurrentQueue<object>();
            ProfileResults = new ConcurrentQueue<object>();
            ErrorMessages = new ConcurrentQueue<string>();
        }

        /// <summary>Reset state for a new replication run</summary>
        public void Reset()
        {
            lock (_lock)
            {
                _sessionId = Guid.NewGuid().ToString();
                _phase = "Idle";
                _currentProfile = null;
                _profileIndex = 0;
                _totalChunks = 0;
                _totalBytes = 0;
                _startTime = null;
                _profileStartTime = null;
                _profiles = null;
                _currentRobocopyOptions = null;
                _currentVssSnapshot = null;
            }

            // Reset atomic counters
            Interlocked.Exchange(ref _completedCount, 0);
            Interlocked.Exchange(ref _bytesComplete, 0);
            Interlocked.Exchange(ref _completedChunkBytes, 0);
            Interlocked.Exchange(ref _completedChunkFiles, 0);
            Interlocked.Exchange(ref _profileStartFiles, 0);
            Interlocked.Exchange(ref _skippedChunkCount, 0);
            Interlocked.Exchange(ref _skippedChunkBytes, 0);

            // Reset volatile flags
            _stopRequested = false;
            _pauseRequested = false;

            // Clear concurrent collections
            ChunkQueue = new ConcurrentQueue<object>();
            ActiveJobs.Clear();
            CompletedChunks = new ConcurrentQueue<object>();
            FailedChunks = new ConcurrentQueue<object>();
            ProfileResults = new ConcurrentQueue<object>();
            ErrorMessages = new ConcurrentQueue<string>();
        }

        /// <summary>Reset collections for a new profile within the same run</summary>
        public void ResetForNewProfile()
        {
            lock (_lock)
            {
                _currentProfile = null;
                _profileStartTime = null;
                _totalChunks = 0;
                _totalBytes = 0;
                _currentRobocopyOptions = null;
                _currentVssSnapshot = null;
            }

            Interlocked.Exchange(ref _completedCount, 0);
            Interlocked.Exchange(ref _bytesComplete, 0);
            Interlocked.Exchange(ref _completedChunkBytes, 0);
            Interlocked.Exchange(ref _completedChunkFiles, 0);
            Interlocked.Exchange(ref _skippedChunkCount, 0);
            Interlocked.Exchange(ref _skippedChunkBytes, 0);

            ChunkQueue = new ConcurrentQueue<object>();
            ActiveJobs.Clear();
            CompletedChunks = new ConcurrentQueue<object>();
            FailedChunks = new ConcurrentQueue<object>();
            // Note: ProfileResults and ErrorMessages are NOT cleared - accumulate across profiles
        }

        /// <summary>Clear just the chunk collections (used between profiles)</summary>
        /// <remarks>
        /// Drains queues instead of reassigning references to prevent race conditions.
        /// Reassigning collection references is NOT thread-safe - another thread could be
        /// iterating with ToArray() during the assignment.
        /// </remarks>
        public void ClearChunkCollections()
        {
            // Drain queues instead of replacing references (thread-safe)
            object item;
            while (ChunkQueue.TryDequeue(out item)) { }
            while (CompletedChunks.TryDequeue(out item)) { }
            while (FailedChunks.TryDequeue(out item)) { }
            // ConcurrentDictionary.Clear() is atomic
            ActiveJobs.Clear();
        }

        /// <summary>Get ProfileResults as an array for PowerShell enumeration</summary>
        public object[] GetProfileResultsArray()
        {
            return ProfileResults.ToArray();
        }

        /// <summary>Get CompletedChunks as an array for PowerShell enumeration</summary>
        public object[] GetCompletedChunksArray()
        {
            return CompletedChunks.ToArray();
        }

        /// <summary>Get FailedChunks as an array for PowerShell enumeration</summary>
        public object[] GetFailedChunksArray()
        {
            return FailedChunks.ToArray();
        }
    }
}
'@ -ErrorAction Stop

        # Create the singleton instance
        $script:OrchestrationState = [Robocurse.OrchestrationState]::new()
        $script:OrchestrationTypeInitialized = $true

        Write-Verbose "OrchestrationState C# type compiled and initialized"
        return $true
    }
    catch {
        Write-RobocurseLog -Message "Failed to compile OrchestrationState type: $($_.Exception.Message)" `
            -Level 'Error' -Component 'Orchestration'
        return $false
    }
}

# Script-scoped callback handlers
$script:OnProgress = $null
$script:OnChunkComplete = $null
$script:OnProfileComplete = $null

# Script-scoped replication run settings (preserved across profile transitions)
$script:CurrentMaxConcurrentJobs = $null

function Initialize-OrchestrationState {
    <#
    .SYNOPSIS
        Resets orchestration state for a new run
    .DESCRIPTION
        Resets the thread-safe orchestration state object for a new replication run.
        Uses the C# class's Reset() method to properly clear all state.
        Also clears the directory profile cache to prevent memory growth across runs
        and cleans up any orphaned VSS snapshots from previous crashed runs.

        If this is the first call, lazy-loads the C# OrchestrationState type.
    #>
    [CmdletBinding()]
    param()

    # Ensure the C# type is compiled and instance exists (lazy load)
    if (-not (Initialize-OrchestrationStateType)) {
        throw "Failed to initialize OrchestrationState type. Check logs for compilation errors."
    }

    # Reset the existing state object (don't create a new one - that breaks cross-thread sharing)
    $script:OrchestrationState.Reset()

    # Clear profile cache to prevent unbounded memory growth across runs
    Clear-ProfileCache

    # Reset chunk ID counter (plain integer - [ref] applied at Interlocked.Increment call site)
    $script:ChunkIdCounter = 0

    # Clean up any orphaned VSS snapshots from crashed previous runs
    $orphansCleared = Clear-OrphanVssSnapshots
    if ($orphansCleared -gt 0) {
        Write-RobocurseLog -Message "Cleaned up $orphansCleared orphaned VSS snapshot(s) from previous run" `
            -Level 'Info' -Component 'VSS'
    }

    Write-RobocurseLog -Message "Orchestration state initialized: $($script:OrchestrationState.SessionId)" `
        -Level 'Info' -Component 'Orchestrator'
}

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
    if (-not $IgnoreCheckpoint) {
        $script:CurrentCheckpoint = Get-ReplicationCheckpoint
        if ($script:CurrentCheckpoint) {
            $skippedCount = $script:CurrentCheckpoint.CompletedChunkPaths.Count
            Write-RobocurseLog -Message "Resuming from checkpoint: $skippedCount chunks will be skipped" `
                -Level 'Info' -Component 'Checkpoint'
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

function Start-ProfileReplication {
    <#
    .SYNOPSIS
        Starts replication for a single profile
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

    $state = $script:OrchestrationState
    $state.CurrentProfile = $Profile
    $state.ProfileStartTime = [datetime]::Now
    $state.ProfileStartFiles = $state.CompletedChunkFiles  # Snapshot for per-profile file counting

    # Pre-flight validation: Source path accessibility
    $sourceCheck = Test-SourcePathAccessible -Path $Profile.Source
    if (-not $sourceCheck.Success) {
        $errorMsg = "Profile '$($Profile.Name)' failed pre-flight check: $($sourceCheck.ErrorMessage)"
        Write-RobocurseLog -Message $errorMsg -Level 'Error' -Component 'Orchestrator'
        $state.EnqueueError($errorMsg)

        # Skip to next profile instead of failing the whole run
        Complete-CurrentProfile
        return
    }

    # Pre-flight validation: Destination disk space (warning only)
    $diskCheck = Test-DestinationDiskSpace -Path $Profile.Destination
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

    Write-RobocurseLog -Message "Starting profile: $($Profile.Name)" `
        -Level 'Info' -Component 'Orchestrator'

    Write-SiemEvent -EventType 'ProfileStart' -Data @{
        profileName = $Profile.Name
        source = $Profile.Source
        destination = $Profile.Destination
    }

    # VSS snapshot handling - allows copying of locked files
    $state.CurrentVssSnapshot = $null
    $effectiveSource = $Profile.Source

    if ($Profile.UseVSS) {
        if (Test-VssSupported -Path $Profile.Source) {
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
            }
            else {
                Write-RobocurseLog -Message "Failed to create VSS snapshot, continuing without VSS: $($snapshotResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
                $state.CurrentVssSnapshot = $null
                $effectiveSource = $Profile.Source
            }
        }
        else {
            Write-RobocurseLog -Message "VSS not supported for path: $($Profile.Source), continuing without VSS" -Level 'Warning' -Component 'VSS'
        }
    }

    # Scan source directory (using VSS path if available)
    $state.Phase = "Scanning"
    $scanResult = Get-DirectoryProfile -Path $effectiveSource

    # Generate chunks based on scan mode
    # Convert ChunkMaxSizeGB to bytes
    $maxChunkBytes = if ($Profile.ChunkMaxSizeGB) { $Profile.ChunkMaxSizeGB * 1GB } else { $script:DefaultMaxChunkSizeBytes }
    $maxFiles = if ($Profile.ChunkMaxFiles) { $Profile.ChunkMaxFiles } else { $script:DefaultMaxFilesPerChunk }
    $maxDepth = if ($Profile.ChunkMaxDepth) { $Profile.ChunkMaxDepth } else { $script:DefaultMaxChunkDepth }

    $chunks = switch ($Profile.ScanMode) {
        'Flat' {
            New-FlatChunks `
                -Path $effectiveSource `
                -DestinationRoot $Profile.Destination `
                -MaxChunkSizeBytes $maxChunkBytes `
                -MaxFiles $maxFiles
        }
        'Smart' {
            New-SmartChunks `
                -Path $effectiveSource `
                -DestinationRoot $Profile.Destination `
                -MaxChunkSizeBytes $maxChunkBytes `
                -MaxFiles $maxFiles `
                -MaxDepth $maxDepth
        }
        default {
            New-SmartChunks `
                -Path $effectiveSource `
                -DestinationRoot $Profile.Destination `
                -MaxChunkSizeBytes $maxChunkBytes `
                -MaxFiles $maxFiles `
                -MaxDepth $maxDepth
        }
    }

    # Clear chunk collections for the new profile using the C# class method
    $state.ClearChunkCollections()

    # Enqueue all chunks (RetryCount is now part of New-Chunk)
    foreach ($chunk in $chunks) {
        $state.ChunkQueue.Enqueue($chunk)
    }

    $state.TotalChunks = $chunks.Count
    $state.TotalBytes = $scanResult.TotalSize
    $state.CompletedCount = 0
    $state.BytesComplete = 0
    $state.Phase = "Replicating"

    # Debug: verify TotalChunks was set correctly
    Write-Host "[DEBUG] Set TotalChunks = $($chunks.Count), verified read = $($state.TotalChunks)"

    Write-RobocurseLog -Message "Profile scan complete: $($chunks.Count) chunks, $([math]::Round($scanResult.TotalSize/1GB, 2)) GB" `
        -Level 'Info' -Component 'Orchestrator'
}

function Start-ChunkJob {
    <#
    .SYNOPSIS
        Starts a robocopy job for a chunk
    .DESCRIPTION
        Starts a robocopy process for the specified chunk, applying:
        - Profile-specific robocopy options
        - Dynamic bandwidth throttling (IPG) based on aggregate limit and active jobs

        BANDWIDTH THROTTLING NOTE:
        IPG (Inter-Packet Gap) is recalculated fresh for each job start, including retries.
        This ensures new/retried jobs get the correct bandwidth share based on CURRENT active
        job count. Running jobs keep their original IPG (robocopy limitation - /IPG is set
        at process start). As jobs complete, new jobs automatically get more bandwidth.
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
            $result = Complete-RobocopyJob -Job $removedJob

            if ($result.ExitMeaning.Severity -in @('Error', 'Fatal')) {
                Invoke-FailedChunkHandler -Job $removedJob -Result $result
            }
            else {
                $state.CompletedChunks.Enqueue($removedJob.Chunk)
                # Track cumulative bytes from completed chunks (avoids O(n) iteration in Update-ProgressStats)
                if ($removedJob.Chunk.EstimatedSize) {
                    $state.AddCompletedChunkBytes($removedJob.Chunk.EstimatedSize)
                }
                # Track files copied from the parsed robocopy log
                if ($result.Stats -and $result.Stats.FilesCopied -gt 0) {
                    $state.AddCompletedChunkFiles($result.Stats.FilesCopied)
                }
            }
            $state.IncrementCompletedCount()

            # Invoke callback
            if ($script:OnChunkComplete) {
                & $script:OnChunkComplete $removedJob $result
            }

            # Save checkpoint periodically (every N chunks or on failure)
            # This enables resume after crash without excessive disk I/O
            if (($state.CompletedCount % $script:CheckpointSaveFrequency -eq 0) -or ($result.ExitMeaning.Severity -in @('Error', 'Fatal'))) {
                Save-ReplicationCheckpoint | Out-Null
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
            if ($script:CurrentCheckpoint -and (Test-ChunkAlreadyCompleted -Chunk $chunk -Checkpoint $script:CurrentCheckpoint)) {
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
        -Level $(if ($exitMeaning.Severity -eq 'Success') { 'Info' } else { 'Warning' }) `
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

    # Store profile result for email/reporting (prevents memory leak by summarizing)
    $profileResult = [PSCustomObject]@{
        Name = $state.CurrentProfile.Name
        Status = if ($failedChunksArray.Count -gt 0) { 'Warning' } else { 'Success' }
        ChunksComplete = $totalCompleted
        ChunksSkipped = $skippedChunkCount
        ChunksTotal = $state.TotalChunks
        ChunksFailed = $failedChunksArray.Count
        BytesCopied = $profileBytesCopied
        FilesCopied = $profileFilesCopied
        Duration = $profileDuration
        Errors = @($failedChunksArray | ForEach-Object { "Chunk $($_.ChunkId): $($_.SourcePath)" })
    }

    # Add to ProfileResults (thread-safe ConcurrentQueue)
    $state.ProfileResults.Enqueue($profileResult)

    Write-RobocurseLog -Message "Profile complete: $($state.CurrentProfile.Name) in $($profileDuration.ToString('hh\:mm\:ss'))" `
        -Level 'Info' -Component 'Orchestrator'

    Write-SiemEvent -EventType 'ProfileComplete' -Data @{
        profileName = $state.CurrentProfile.Name
        chunksCompleted = $totalCompleted
        chunksSkipped = $skippedChunkCount
        chunksFailed = $failedChunksArray.Count
        durationMs = $profileDuration.TotalMilliseconds
    }

    # Clean up VSS snapshot if one was created for this profile
    if ($state.CurrentVssSnapshot) {
        Write-RobocurseLog -Message "Cleaning up VSS snapshot: $($state.CurrentVssSnapshot.ShadowId)" -Level 'Info' -Component 'VSS'
        $removeResult = Remove-VssSnapshot -ShadowId $state.CurrentVssSnapshot.ShadowId

        if ($removeResult.Success) {
            Write-SiemEvent -EventType 'VssSnapshotRemoved' -Data @{
                profileName = $state.CurrentProfile.Name
                shadowId = $state.CurrentVssSnapshot.ShadowId
            }
        }
        else {
            Write-RobocurseLog -Message "Failed to clean up VSS snapshot: $($removeResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
        }

        $state.CurrentVssSnapshot = $null
    }

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
        $totalDuration = [datetime]::Now - $state.StartTime

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
                $job.Process.WaitForExit(5000)
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

    # Clean up VSS snapshot if one exists
    if ($state.CurrentVssSnapshot) {
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

#region Health Check Functions

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
        If the status file's LastUpdate is older than this, the returned
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
        if ($MaxAgeSeconds -gt 0 -and $status.LastUpdate) {
            $lastUpdate = [datetime]::Parse($status.LastUpdate)
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

#endregion
