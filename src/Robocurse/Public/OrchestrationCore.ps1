# Robocurse Orchestration Core Functions
# Core types, state management, and circuit breaker logic
#
# This module contains the foundational orchestration infrastructure:
# - C# OrchestrationState type (thread-safe cross-runspace communication)
# - State initialization and reset
# - Circuit breaker pattern for failure handling

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

        // Last snapshot result (for source/dest persistent snapshots)
        private object _lastSnapshotResult;
        public object LastSnapshotResult
        {
            get { lock (_lock) { return _lastSnapshotResult; } }
            set { lock (_lock) { _lastSnapshotResult = value; } }
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
                _lastSnapshotResult = null;
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
                _lastSnapshotResult = null;
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

# Script-scoped callback handlers (used by JobManagement.ps1)
$script:OnProgress = $null
$script:OnChunkComplete = $null
$script:OnProfileComplete = $null

# Script-scoped replication run settings (preserved across profile transitions)
$script:CurrentMaxConcurrentJobs = $null

#region Circuit Breaker
# Circuit breaker configuration and state
# Trips after consecutive failures to prevent wasted effort on persistent issues

$script:CircuitBreakerThreshold = 10       # Consecutive failures before tripping
$script:CircuitBreakerConsecutiveFailures = 0
$script:CircuitBreakerTripped = $false
$script:CircuitBreakerReason = $null

function Reset-CircuitBreaker {
    <#
    .SYNOPSIS
        Resets the circuit breaker state for a new run
    #>
    [CmdletBinding()]
    param()
    $script:CircuitBreakerConsecutiveFailures = 0
    $script:CircuitBreakerTripped = $false
    $script:CircuitBreakerReason = $null
}

function Test-CircuitBreakerTripped {
    <#
    .SYNOPSIS
        Checks if the circuit breaker has tripped
    .OUTPUTS
        $true if circuit breaker has tripped, $false otherwise
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return $script:CircuitBreakerTripped
}

function Invoke-CircuitBreakerCheck {
    <#
    .SYNOPSIS
        Checks if circuit breaker should trip after a failure
    .DESCRIPTION
        Increments the consecutive failure counter and trips the circuit breaker
        if the threshold is reached. When tripped, the orchestrator will stop
        processing and mark the run as stopped.
    .PARAMETER ChunkId
        The chunk that failed (for logging)
    .PARAMETER ErrorMessage
        The error message from the failure
    .OUTPUTS
        $true if circuit breaker was just tripped, $false otherwise
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$ChunkId,
        [string]$ErrorMessage
    )

    $script:CircuitBreakerConsecutiveFailures++

    if ($script:CircuitBreakerConsecutiveFailures -ge $script:CircuitBreakerThreshold -and -not $script:CircuitBreakerTripped) {
        $script:CircuitBreakerTripped = $true
        $script:CircuitBreakerReason = "Circuit breaker tripped after $($script:CircuitBreakerThreshold) consecutive chunk failures. Last error: $ErrorMessage"

        Write-RobocurseLog -Message $script:CircuitBreakerReason -Level 'Error' -Component 'CircuitBreaker'
        Write-SiemEvent -EventType 'ChunkError' -Data @{
            type = 'CircuitBreakerTripped'
            consecutiveFailures = $script:CircuitBreakerConsecutiveFailures
            lastChunkId = $ChunkId
            lastError = $ErrorMessage
        }

        # Signal orchestrator to stop
        if ($script:OrchestrationState) {
            $script:OrchestrationState.StopRequested = $true
            $script:OrchestrationState.EnqueueError($script:CircuitBreakerReason)
        }

        return $true
    }

    return $false
}

function Reset-CircuitBreakerOnSuccess {
    <#
    .SYNOPSIS
        Resets the consecutive failure counter after a successful chunk
    .DESCRIPTION
        Called when a chunk completes successfully to reset the circuit breaker
        failure counter. This allows the system to recover from transient failures.
    #>
    [CmdletBinding()]
    param()

    if ($script:CircuitBreakerConsecutiveFailures -gt 0) {
        Write-RobocurseLog -Message "Circuit breaker reset after successful chunk (was at $($script:CircuitBreakerConsecutiveFailures) consecutive failures)" `
            -Level 'Debug' -Component 'CircuitBreaker'
        $script:CircuitBreakerConsecutiveFailures = 0
    }
}

#endregion Circuit Breaker

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

    # Reset circuit breaker state for new run
    Reset-CircuitBreaker

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

function Get-OrchestrationState {
    <#
    .SYNOPSIS
        Returns the current orchestration state object
    .DESCRIPTION
        Provides access to the thread-safe orchestration state for other modules.
        Used by JobManagement.ps1 and HealthCheck.ps1.
    .OUTPUTS
        Robocurse.OrchestrationState object, or $null if not initialized
    #>
    [CmdletBinding()]
    param()

    return $script:OrchestrationState
}
