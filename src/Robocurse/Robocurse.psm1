# Robocurse PowerShell Module
# Multi-share parallel robocopy orchestrator for Windows environments.

#region ==================== MODULE CONFIGURATION ====================
# Set strict error handling at module level.
# This ensures non-terminating errors become terminating, preventing silent failures.
# Individual functions can override with -ErrorAction where appropriate (e.g., SilentlyContinue for optional lookups).
$ErrorActionPreference = 'Stop'

# Preserve the previous preference for restoration if needed
$script:PreviousErrorActionPreference = $ErrorActionPreference
#endregion

#region ==================== CONSTANTS ====================
# Chunking defaults
# Maximum size for a single chunk. Larger directories will be split into smaller chunks.
# 10GB is chosen to balance parallelism vs. overhead - large enough to avoid excessive splitting,
# small enough to allow meaningful parallel processing.
$script:DefaultMaxChunkSizeBytes = 10GB

# Maximum number of files in a single chunk before splitting.
# 50,000 files is chosen to prevent robocopy from being overwhelmed by file enumeration
# while still processing meaningful batches.
$script:DefaultMaxFilesPerChunk = 50000

# Maximum directory depth to traverse when creating chunks.
# Depth of 5 prevents excessive recursion while allowing reasonable directory structure analysis.
$script:DefaultMaxChunkDepth = 5

# Minimum size threshold for creating a separate chunk.
# 100MB ensures we don't create chunks for trivial directories, reducing overhead.
$script:DefaultMinChunkSizeBytes = 100MB

# Retry policy
# Maximum retry attempts for failed chunks before marking as permanently failed.
# 3 retries handles transient network issues without indefinite loops.
$script:MaxChunkRetries = 3

# Exponential backoff settings for chunk retries.
# Base delay in seconds for first retry. Subsequent retries use: base * (multiplier ^ retryCount)
# Example with base=5, multiplier=2: 5s -> 10s -> 20s
$script:RetryBackoffBaseSeconds = 5

# Multiplier for exponential backoff calculation.
# 2.0 doubles the delay each retry, providing good balance between retry speed and backoff.
$script:RetryBackoffMultiplier = 2.0

# Maximum delay cap in seconds to prevent excessively long waits.
# 120 seconds (2 minutes) is the upper bound regardless of retry count.
$script:RetryBackoffMaxSeconds = 120

# Number of times robocopy will retry a failed file copy (maps to /R: parameter).
# 3 retries is sufficient for transient file locks or network glitches.
$script:RobocopyRetryCount = 3

# Wait time in seconds between robocopy retry attempts (maps to /W: parameter).
# 10 seconds allows time for locks to clear without excessive delay.
$script:RobocopyRetryWaitSeconds = 10

# Threading
# Default number of threads per robocopy job (maps to /MT: parameter).
# 8 threads provides good parallelism without overwhelming the network or disk I/O.
$script:DefaultThreadsPerJob = 8

# Maximum number of concurrent robocopy jobs to run in parallel.
# 4 concurrent jobs balances system resources while maintaining good throughput.
$script:DefaultMaxConcurrentJobs = 4

# Caching
# Maximum age in hours for cached directory profiles before re-scanning.
# 24 hours prevents unnecessary re-scans while ensuring reasonably fresh data.
$script:ProfileCacheMaxAgeHours = 24

# Maximum number of entries in the profile cache before triggering cleanup.
# 10,000 entries is sufficient for large directory trees while preventing unbounded growth.
$script:ProfileCacheMaxEntries = 10000

# Logging
# Compress log files older than this many days to save disk space.
# 7 days keeps recent logs readily accessible while compressing older logs.
$script:LogCompressAfterDays = 7

# Delete compressed log files older than this many days.
# 30 days aligns with typical retention policies and provides adequate audit history.
$script:LogDeleteAfterDays = 30

# GUI display limits
# Maximum number of completed chunks to display in the GUI grid.
# Limits prevent UI lag with large chunk counts while showing recent activity.
$script:GuiMaxCompletedChunksDisplay = 20

# Maximum number of log lines to retain in GUI ring buffer.
# 500 lines provides sufficient context without excessive memory use.
$script:GuiLogMaxLines = 500

# Maximum number of errors to display in email notifications.
# 10 errors provides useful context without overwhelming the email.
$script:EmailMaxErrorsDisplay = 10

# Default mismatch severity
# Controls how robocopy exit code 4 (mismatches) is treated.
# Valid values: "Warning" (default), "Error", "Success" (ignore mismatches)
$script:DefaultMismatchSeverity = "Warning"

# Orchestration intervals
# Polling interval in milliseconds for replication tick loop.
# 500ms balances responsiveness with CPU overhead.
$script:ReplicationTickIntervalMs = 500

# Progress output interval in seconds for headless mode console output.
# 10 seconds provides regular updates without flooding the console.
$script:HeadlessProgressIntervalSeconds = 10

# Checkpoint save frequency
# Save checkpoint every N completed chunks (also saved on failures).
# 10 chunks balances disk I/O with recovery granularity.
$script:CheckpointSaveFrequency = 10

# ETA calculation settings
# Maximum ETA in days before capping. For very large replication jobs (petabyte scale),
# ETAs can become unreasonably long. This cap provides a sensible upper bound.
# Default is 365 days (1 year). Values beyond this display as "365+ days".
$script:MaxEtaDays = 365

# Health check settings
# Interval in seconds between health status file updates during replication.
# 30 seconds provides good monitoring granularity without excessive I/O.
$script:HealthCheckIntervalSeconds = 30

# Remote operation timeout in milliseconds for Invoke-Command calls.
# 30 seconds is sufficient for most remote operations while preventing indefinite hangs
# on slow or unreachable servers.
$script:RemoteOperationTimeoutMs = 30000

# Log mutex timeout in milliseconds for thread-safe log writes.
# 5 seconds is sufficient for mutex acquisition without excessive blocking.
$script:LogMutexTimeoutMs = 5000

# Minimum log level for filtering (Debug, Info, Warning, Error)
# Set to 'Debug' to capture all messages, 'Info' to skip debug messages, etc.
$script:MinLogLevel = 'Debug'

# Path to health check status file. Uses temp directory for cross-platform compatibility.
$script:HealthCheckTempDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { "/tmp" }
$script:HealthCheckStatusFile = Join-Path $script:HealthCheckTempDir "Robocurse-Health.json"

# Dry-run mode state (set during replication, used by Start-ChunkJob)
$script:DryRunMode = $false

# Timeout in milliseconds for VSS tracking file mutex acquisition.
# VSS operations are less frequent, so 10 seconds is acceptable.
$script:VssMutexTimeoutMs = 10000

# GUI update intervals
# Timer interval in milliseconds for GUI progress updates.
# 250ms provides smooth visual updates without excessive CPU usage.
$script:GuiProgressUpdateIntervalMs = 250

# Process termination
# Timeout in milliseconds when waiting for robocopy processes to exit during stop.
# 5 seconds allows graceful shutdown before force-killing.
$script:ProcessStopTimeoutMs = 5000
#endregion

#region ==================== MODULE LOADING ====================

# Get the module's root directory
$PSModuleRoot = $PSScriptRoot

# Store the module path for background runspace loading
# This will be used by New-ReplicationRunspace to load the module in the background thread
$script:RobocurseModulePath = $PSModuleRoot

# Load public functions (in dependency order)
$publicFunctionOrder = @(
    'Utility.ps1'
    'Configuration.ps1'
    'Logging.ps1'
    'DirectoryProfiling.ps1'
    'Chunking.ps1'
    'Robocopy.ps1'
    'Checkpoint.ps1'       # Checkpoint/resume (before Orchestration)
    # Orchestration modules (split for maintainability)
    'OrchestrationCore.ps1'  # C# types, state management, circuit breaker
    'HealthCheck.ps1'        # Health monitoring (before JobManagement which uses it)
    'JobManagement.ps1'      # Job execution, profile management
    'Progress.ps1'
    'VssCore.ps1'
    'VssLocal.ps1'
    'VssRemote.ps1'
    'Email.ps1'
    'Scheduling.ps1'
    'SnapshotSchedule.ps1'
    'SnapshotCli.ps1'
    # GUI modules (split for maintainability)
    'GuiResources.ps1'
    'GuiSettings.ps1'
    'GuiProfiles.ps1'
    'GuiDialogs.ps1'
    'GuiLogWindow.ps1'     # Popup log viewer window
    'GuiValidation.ps1'    # Pre-flight validation UI
    'GuiRunspace.ps1'      # Background runspace management (before GuiReplication)
    'GuiReplication.ps1'
    'GuiProgress.ps1'
    'GuiChunkActions.ps1'  # Chunk context menu actions
    'GuiSnapshots.ps1'     # Snapshot management panel
    'GuiSnapshotDialogs.ps1'  # Snapshot dialogs (create/delete)
    'GuiMain.ps1'
    'Main.ps1'
)

foreach ($functionFile in $publicFunctionOrder) {
    $path = Join-Path "$PSModuleRoot\Public" $functionFile
    if (Test-Path $path) {
        try {
            . $path
        }
        catch {
            Write-Error "Failed to load public function $path`: $_"
        }
    }
}

#endregion

