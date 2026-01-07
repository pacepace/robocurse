# Robocurse Robocopy wrapper Functions
# Script-level bandwidth limit (set from config during replication start)
$script:BandwidthLimitMbps = 0

# Script variable to track if RobocopyProgressBuffer type has been initialized
$script:RobocopyProgressBufferTypeInitialized = $false

# Script variable to track if ProcessJobObject type has been initialized
$script:ProcessJobObjectTypeInitialized = $false

# Script variable to hold the Job Object handle (kills all children on parent exit)
$script:RobocopyJobObject = $null

function Initialize-RobocopyProgressBufferType {
    <#
    .SYNOPSIS
        Lazy-loads the C# RobocopyProgressBuffer type for streaming stdout capture
    .DESCRIPTION
        Compiles and loads the C# RobocopyProgressBuffer class only when first needed.
        This class provides thread-safe storage for robocopy output lines and progress
        counters, enabling real-time progress updates during file copy operations.

        The type is only compiled once per PowerShell session. Subsequent calls
        return immediately if the type already exists.
    .OUTPUTS
        $true if type is available, $false on compilation failure
    #>
    [CmdletBinding()]
    param()

    # Fast path: already initialized this session
    if ($script:RobocopyProgressBufferTypeInitialized) {
        return $true
    }

    # Check if type exists from a previous session/import
    if (([System.Management.Automation.PSTypeName]'Robocurse.RobocopyProgressBuffer').Type) {
        $script:RobocopyProgressBufferTypeInitialized = $true
        return $true
    }

    # Compile the C# type
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Threading;

namespace Robocurse
{
    /// <summary>
    /// Thread-safe buffer for streaming robocopy stdout capture.
    /// Used for real-time progress updates during file copy operations.
    /// Event handler runs on thread pool - all operations must be thread-safe.
    /// </summary>
    public class RobocopyProgressBuffer
    {
        /// <summary>Lines captured from stdout - use Enqueue/TryDequeue for thread safety</summary>
        public ConcurrentQueue<string> Lines { get; private set; }

        /// <summary>Bytes from files that have completed (reached 100%)</summary>
        private long _completedFilesBytes;
        public long CompletedFilesBytes
        {
            get { return Interlocked.Read(ref _completedFilesBytes); }
        }

        /// <summary>Add bytes from a completed file to the total</summary>
        public long AddCompletedBytes(long bytes)
        {
            return Interlocked.Add(ref _completedFilesBytes, bytes);
        }

        /// <summary>Size of the file currently being copied</summary>
        private long _currentFileSize;
        public long CurrentFileSize
        {
            get { return Interlocked.Read(ref _currentFileSize); }
            set { Interlocked.Exchange(ref _currentFileSize, value); }
        }

        /// <summary>Bytes copied of the current file (calculated from percentage)</summary>
        private long _currentFileBytes;
        public long CurrentFileBytes
        {
            get { return Interlocked.Read(ref _currentFileBytes); }
            set { Interlocked.Exchange(ref _currentFileBytes, value); }
        }

        /// <summary>Total bytes copied = completed files + current file progress</summary>
        public long BytesCopied
        {
            get { return Interlocked.Read(ref _completedFilesBytes) + Interlocked.Read(ref _currentFileBytes); }
        }

        /// <summary>Count of files that have completed copying</summary>
        private int _filesCopied;
        public int FilesCopied
        {
            get { return Interlocked.CompareExchange(ref _filesCopied, 0, 0); }
            set { Interlocked.Exchange(ref _filesCopied, value); }
        }

        /// <summary>Atomically increment files copied counter</summary>
        public int IncrementFiles()
        {
            return Interlocked.Increment(ref _filesCopied);
        }

        /// <summary>Current file being copied (for progress display)</summary>
        private string _currentFile = "";
        private readonly object _fileLock = new object();
        public string CurrentFile
        {
            get { lock (_fileLock) { return _currentFile; } }
            set { lock (_fileLock) { _currentFile = value ?? ""; } }
        }

        /// <summary>Timestamp of last progress update</summary>
        private long _lastUpdateTicks;
        public DateTime LastUpdate
        {
            get { return new DateTime(Interlocked.Read(ref _lastUpdateTicks)); }
            set { Interlocked.Exchange(ref _lastUpdateTicks, value.Ticks); }
        }

        /// <summary>Create a new progress buffer with empty collections</summary>
        public RobocopyProgressBuffer()
        {
            Lines = new ConcurrentQueue<string>();
            _completedFilesBytes = 0;
            _currentFileSize = 0;
            _currentFileBytes = 0;
            _filesCopied = 0;
            _currentFile = "";
            _lastUpdateTicks = DateTime.Now.Ticks;
        }

        /// <summary>Get all buffered lines as array (for final parsing)</summary>
        public string[] GetAllLines()
        {
            return Lines.ToArray();
        }

        /// <summary>Get count of buffered lines</summary>
        public int LineCount
        {
            get { return Lines.Count; }
        }
    }
}
'@ -ErrorAction Stop

        $script:RobocopyProgressBufferTypeInitialized = $true
        Write-Verbose "RobocopyProgressBuffer C# type compiled and initialized"
        return $true
    }
    catch {
        Write-RobocurseLog -Message "Failed to compile RobocopyProgressBuffer type: $($_.Exception.Message)" `
            -Level 'Error' -Component 'Robocopy'
        return $false
    }
}

function Initialize-ProcessJobObjectType {
    <#
    .SYNOPSIS
        Lazy-loads the C# ProcessJobObject type for child process cleanup
    .DESCRIPTION
        Compiles and loads a C# class that wraps Windows Job Objects.
        When processes are assigned to this job, they are automatically
        terminated when the parent process exits (even on crash).

        This ensures robocopy child processes don't become orphaned.
    .OUTPUTS
        $true if type is available, $false on compilation failure
    #>
    [CmdletBinding()]
    param()

    # Fast path: already initialized this session
    if ($script:ProcessJobObjectTypeInitialized) {
        return $true
    }

    # Check if type exists from a previous session/import
    if (([System.Management.Automation.PSTypeName]'Robocurse.ProcessJobObject').Type) {
        $script:ProcessJobObjectTypeInitialized = $true
        return $true
    }

    # Compile the C# type with P/Invoke for Windows Job Object APIs
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Robocurse
{
    /// <summary>
    /// Windows Job Object wrapper that automatically kills child processes on parent exit.
    /// When processes are assigned to this job with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    /// they are automatically terminated when the job handle is closed (including on crash).
    /// </summary>
    public class ProcessJobObject : IDisposable
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInfoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        // Job object info class for extended limit information
        private const int JobObjectExtendedLimitInformation = 9;

        // Limit flag to kill all processes when job handle is closed
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        private IntPtr _jobHandle;
        private bool _disposed;
        private readonly object _lock = new object();

        /// <summary>Creates a new Job Object configured to kill children on close</summary>
        public ProcessJobObject()
        {
            _jobHandle = CreateJobObject(IntPtr.Zero, null);
            if (_jobHandle == IntPtr.Zero)
            {
                throw new InvalidOperationException("Failed to create job object. Error: " + Marshal.GetLastWin32Error());
            }

            // Configure job to kill all processes when handle is closed
            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION
            {
                BasicLimitInformation = new JOBOBJECT_BASIC_LIMIT_INFORMATION
                {
                    LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                }
            };

            int infoSize = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr infoPtr = Marshal.AllocHGlobal(infoSize);
            try
            {
                Marshal.StructureToPtr(info, infoPtr, false);
                if (!SetInformationJobObject(_jobHandle, JobObjectExtendedLimitInformation, infoPtr, (uint)infoSize))
                {
                    int error = Marshal.GetLastWin32Error();
                    CloseHandle(_jobHandle);
                    _jobHandle = IntPtr.Zero;
                    throw new InvalidOperationException("Failed to set job object information. Error: " + error);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(infoPtr);
            }
        }

        /// <summary>Assigns a process to this job object</summary>
        public bool AssignProcess(Process process)
        {
            if (process == null) return false;
            lock (_lock)
            {
                if (_disposed || _jobHandle == IntPtr.Zero) return false;
                try
                {
                    return AssignProcessToJobObject(_jobHandle, process.Handle);
                }
                catch
                {
                    return false;
                }
            }
        }

        /// <summary>Assigns a process to this job object by handle</summary>
        public bool AssignProcess(IntPtr processHandle)
        {
            if (processHandle == IntPtr.Zero) return false;
            lock (_lock)
            {
                if (_disposed || _jobHandle == IntPtr.Zero) return false;
                return AssignProcessToJobObject(_jobHandle, processHandle);
            }
        }

        public void Dispose()
        {
            lock (_lock)
            {
                if (!_disposed && _jobHandle != IntPtr.Zero)
                {
                    CloseHandle(_jobHandle);
                    _jobHandle = IntPtr.Zero;
                }
                _disposed = true;
            }
        }
    }
}
'@ -ErrorAction Stop

        $script:ProcessJobObjectTypeInitialized = $true
        Write-Verbose "ProcessJobObject C# type compiled and initialized"
        return $true
    }
    catch {
        Write-RobocurseLog -Message "Failed to compile ProcessJobObject type: $($_.Exception.Message)" `
            -Level 'Warning' -Component 'Robocopy'
        return $false
    }
}

function Initialize-RobocopyJobObject {
    <#
    .SYNOPSIS
        Creates the Job Object for robocopy child process management
    .DESCRIPTION
        Initializes a Windows Job Object that will automatically kill all
        assigned robocopy processes when the parent process exits.
        Call this once at application startup.
    .OUTPUTS
        $true if Job Object created successfully, $false otherwise
    #>
    [CmdletBinding()]
    param()

    if ($script:RobocopyJobObject) {
        return $true  # Already initialized
    }

    if (-not (Initialize-ProcessJobObjectType)) {
        Write-RobocurseLog -Message "Job Object type not available - child processes may become orphaned on crash" `
            -Level 'Warning' -Component 'Robocopy'
        return $false
    }

    try {
        $script:RobocopyJobObject = [Robocurse.ProcessJobObject]::new()
        Write-RobocurseLog -Message "Robocopy Job Object initialized - child processes will be cleaned up on exit" `
            -Level 'Debug' -Component 'Robocopy'
        return $true
    }
    catch {
        Write-RobocurseLog -Message "Failed to create Job Object: $($_.Exception.Message)" `
            -Level 'Warning' -Component 'Robocopy'
        return $false
    }
}

function Add-ProcessToJobObject {
    <#
    .SYNOPSIS
        Assigns a process to the robocopy Job Object
    .DESCRIPTION
        Adds a process to the Job Object so it will be automatically
        terminated when the parent process exits.
    .PARAMETER Process
        The System.Diagnostics.Process to assign
    .OUTPUTS
        $true if assigned successfully, $false otherwise
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process
    )

    if (-not $script:RobocopyJobObject) {
        # Job Object not initialized - try to initialize it now
        if (-not (Initialize-RobocopyJobObject)) {
            return $false
        }
    }

    try {
        $result = $script:RobocopyJobObject.AssignProcess($Process)
        if ($result) {
            Write-Verbose "Assigned process $($Process.Id) to Job Object"
        }
        return $result
    }
    catch {
        Write-Verbose "Failed to assign process to Job Object: $($_.Exception.Message)"
        return $false
    }
}

function Get-BandwidthThrottleIPG {
    <#
    .SYNOPSIS
        Calculates Inter-Packet Gap (IPG) for bandwidth throttling
    .DESCRIPTION
        Computes the robocopy /IPG:n value based on:
        - Total bandwidth limit (Mbps)
        - Number of active concurrent jobs

        The IPG is the delay in milliseconds between 512-byte packets.
        Formula: IPG = (PacketSize / TargetBytesPerSec) * 1000
               = 512 * 1000 / PerJobBytesPerSec
               = 512000 / PerJobBytesPerSec

        Returns 0 (unlimited) if no bandwidth limit is set.
    .PARAMETER BandwidthLimitMbps
        Total bandwidth limit in Megabits per second (0 = unlimited)
    .PARAMETER ActiveJobs
        Number of currently active jobs (minimum 1)
    .PARAMETER PendingJobStart
        Set to $true when calculating for a new job about to start
    .OUTPUTS
        Integer IPG value in milliseconds, or 0 for unlimited
    .EXAMPLE
        # 100 Mbps total, 4 active jobs = 25 Mbps per job
        $ipg = Get-BandwidthThrottleIPG -BandwidthLimitMbps 100 -ActiveJobs 4
        # Returns approximately 164 ms
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$BandwidthLimitMbps,

        [Parameter(Mandatory)]
        [int]$ActiveJobs,

        [switch]$PendingJobStart
    )

    # No limit set
    if ($BandwidthLimitMbps -le 0) {
        return 0
    }

    # Account for the job we're about to start
    $effectiveJobs = if ($PendingJobStart) { $ActiveJobs + 1 } else { [Math]::Max(1, $ActiveJobs) }

    # Convert Mbps to bytes per second per job
    # 1 Mbps = 125,000 bytes/sec (1,000,000 bits / 8)
    $totalBytesPerSec = $BandwidthLimitMbps * 125000
    $perJobBytesPerSec = $totalBytesPerSec / $effectiveJobs

    # Robocopy IPG is delay in ms between 512-byte packets
    # Formula derivation:
    #   - Robocopy sends data in 512-byte packets
    #   - IPG (Inter-Packet Gap) = time between packets in milliseconds
    #   - To achieve target bytes/sec: IPG = (packet_size / target_bytes_per_sec) * 1000
    #   - IPG = (512 / perJobBytesPerSec) * 1000 = 512000 / perJobBytesPerSec
    $robocopyPacketSize = 512  # bytes per packet (robocopy default)
    $msPerSecond = 1000
    $ipg = [Math]::Ceiling(($robocopyPacketSize * $msPerSecond) / $perJobBytesPerSec)

    # Clamp to reasonable range (1ms to 10000ms)
    $ipg = [Math]::Max(1, [Math]::Min(10000, $ipg))

    Write-RobocurseLog -Message "Bandwidth throttle: $BandwidthLimitMbps Mbps / $effectiveJobs jobs = IPG ${ipg}ms" `
        -Level 'Debug' -Component 'Bandwidth'

    return $ipg
}

function Format-QuotedPath {
    <#
    .SYNOPSIS
        Properly quotes a path for use in command-line arguments
    .DESCRIPTION
        When a path ends with a backslash and is quoted (e.g., "D:\"), the
        backslash-quote sequence (\" ) is interpreted as an escaped quote by
        the Windows command-line parser. This causes argument parsing to fail.

        This function doubles trailing backslashes to prevent this issue:
        - "D:\" becomes "D:\\" (the \\ is parsed as a single \)
        - "C:\Users\Test\" becomes "C:\Users\Test\\"
        - "C:\Users\Test" stays "C:\Users\Test" (no trailing backslash)
    .PARAMETER Path
        The path to quote
    .OUTPUTS
        String - Properly quoted path safe for command-line use
    .EXAMPLE
        Format-QuotedPath -Path "D:\"  # Returns "D:\\"
        Format-QuotedPath -Path "C:\Users\Test"  # Returns "C:\Users\Test"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # If path ends with backslash, double it to escape the \" problem
    if ($Path.EndsWith('\')) {
        return "`"$Path\`""
    }
    return "`"$Path`""
}

function New-RobocopyArguments {
    <#
    .SYNOPSIS
        Builds robocopy command-line arguments from options
    .DESCRIPTION
        Constructs the argument array for robocopy based on:
        - Source and destination paths
        - Copy mode (mirror vs regular)
        - Custom switches from RobocopyOptions
        - Threading, retry, and logging settings
        - Exclusion patterns
        - Chunk-specific arguments

        This function is separated from Start-RobocopyJob for:
        - Easier unit testing of argument generation
        - Reusability for displaying planned operations
        - Cleaner separation of concerns
    .PARAMETER SourcePath
        Source directory path
    .PARAMETER DestinationPath
        Destination directory path
    .PARAMETER LogPath
        Path for robocopy log file
    .PARAMETER ThreadsPerJob
        Number of threads for robocopy (/MT:n)
    .PARAMETER RobocopyOptions
        Hashtable of robocopy options (see Start-RobocopyJob for details)
    .PARAMETER ChunkArgs
        Additional arguments specific to the chunk (e.g., /LEV:1)
    .PARAMETER DryRun
        If true, adds /L flag to list what would be copied without copying
    .OUTPUTS
        String[] - Array of robocopy arguments ready to join
    .EXAMPLE
        $args = New-RobocopyArguments -SourcePath "C:\Source" -DestinationPath "D:\Dest" -LogPath "C:\log.txt"
        $argString = $args -join ' '
    .EXAMPLE
        $args = New-RobocopyArguments -SourcePath "C:\Source" -DestinationPath "D:\Dest" -LogPath "C:\log.txt" -DryRun
        # Returns args with /L flag for preview mode
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [ValidateRange(1, 128)]
        [int]$ThreadsPerJob = $script:DefaultThreadsPerJob,

        [hashtable]$RobocopyOptions = @{},

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ChunkArgs,

        [switch]$DryRun
    )

    # Handle null ChunkArgs (PS 5.1 unwraps empty arrays to null)
    if ($null -eq $ChunkArgs) {
        $ChunkArgs = @()
    }

    # Validate paths for command injection before using them
    $safeSourcePath = Get-SanitizedPath -Path $SourcePath -ParameterName "SourcePath"
    $safeDestPath = Get-SanitizedPath -Path $DestinationPath -ParameterName "DestinationPath"
    $safeLogPath = Get-SanitizedPath -Path $LogPath -ParameterName "LogPath"

    # Extract options with defaults
    # Use ContainsKey() to distinguish between "not set" and "set to 0/false"
    $retryCount = if ($RobocopyOptions.ContainsKey('RetryCount')) { $RobocopyOptions.RetryCount } else { $script:RobocopyRetryCount }
    $retryWait = if ($RobocopyOptions.ContainsKey('RetryWait')) { $RobocopyOptions.RetryWait } else { $script:RobocopyRetryWaitSeconds }
    $skipJunctions = if ($RobocopyOptions.ContainsKey('SkipJunctions')) { $RobocopyOptions.SkipJunctions } else { $true }
    $noMirror = if ($RobocopyOptions.ContainsKey('NoMirror')) { $RobocopyOptions.NoMirror } else { $false }
    $interPacketGapMs = if ($RobocopyOptions.ContainsKey('InterPacketGapMs') -and $RobocopyOptions.InterPacketGapMs) { [int]$RobocopyOptions.InterPacketGapMs } else { $null }

    # Build argument list
    $argList = [System.Collections.Generic.List[string]]::new()

    # Source and destination (use Format-QuotedPath to handle trailing backslash escaping)
    $argList.Add((Format-QuotedPath -Path $safeSourcePath))
    $argList.Add((Format-QuotedPath -Path $safeDestPath))

    # Copy mode: /MIR (mirror with delete) or /E (copy subdirs including empty)
    $argList.Add($(if ($noMirror) { "/E" } else { "/MIR" }))

    # Profile-specified switches or defaults
    if ($RobocopyOptions.Switches -and $RobocopyOptions.Switches.Count -gt 0) {
        # Filter out switches we handle separately (case-insensitive)
        $filteredSwitches = $RobocopyOptions.Switches | Where-Object {
            $_ -notmatch '^/(MT|R|W|LOG|MIR|E|TEE|NP|BYTES)' -and
            $_ -notmatch '^/LOG:'
        }
        # Validate remaining switches against security whitelist to prevent injection
        $customSwitches = Get-SanitizedRobocopySwitches -Switches $filteredSwitches
        foreach ($sw in $customSwitches) {
            $argList.Add($sw)
        }
    }
    else {
        # Default copy options
        $argList.Add("/COPY:DAT")
        $argList.Add("/DCOPY:T")
    }

    # Threading, retry, and logging (always applied)
    $argList.Add("/MT:$ThreadsPerJob")
    $argList.Add("/J")  # Unbuffered I/O - prevents memory exhaustion on large files
    $argList.Add("/R:$retryCount")
    $argList.Add("/W:$retryWait")
    $argList.Add("/LOG:$(Format-QuotedPath -Path $safeLogPath)")
    $argList.Add("/TEE")
    # Note: /NP removed to enable percentage progress output for real-time monitoring

    # /NDL = No Directory List (reduce log noise)
    # Note: /NFL removed - file output is required for real-time BytesCopied progress tracking
    $argList.Add("/NDL")
    $argList.Add("/BYTES")

    # Junction handling
    if ($skipJunctions) {
        $argList.Add("/XJD")
        $argList.Add("/XJF")
    }

    # Bandwidth throttling
    if ($interPacketGapMs -and $interPacketGapMs -gt 0) {
        $argList.Add("/IPG:$interPacketGapMs")
    }

    # Exclude files (sanitized to prevent injection)
    if ($RobocopyOptions.ExcludeFiles -and $RobocopyOptions.ExcludeFiles.Count -gt 0) {
        $safeExcludeFiles = Get-SanitizedExcludePatterns -Patterns $RobocopyOptions.ExcludeFiles -Type 'Files'
        if ($safeExcludeFiles.Count -gt 0) {
            $argList.Add("/XF")
            foreach ($pattern in $safeExcludeFiles) {
                $argList.Add((Format-QuotedPath -Path $pattern))
            }
        }
    }

    # Exclude directories (sanitized to prevent injection)
    if ($RobocopyOptions.ExcludeDirs -and $RobocopyOptions.ExcludeDirs.Count -gt 0) {
        $safeExcludeDirs = Get-SanitizedExcludePatterns -Patterns $RobocopyOptions.ExcludeDirs -Type 'Dirs'
        if ($safeExcludeDirs.Count -gt 0) {
            $argList.Add("/XD")
            foreach ($dir in $safeExcludeDirs) {
                $argList.Add((Format-QuotedPath -Path $dir))
            }
        }
    }

    # Chunk-specific arguments (e.g., /LEV:1 for files-only chunks)
    # Sanitized to prevent command injection
    $safeChunkArgs = Get-SanitizedChunkArgs -ChunkArgs $ChunkArgs
    foreach ($arg in $safeChunkArgs) {
        $argList.Add($arg)
    }

    # Dry-run mode: /L lists what would be copied without actually copying
    if ($DryRun) {
        $argList.Add("/L")
    }

    return $argList.ToArray()
}

function Start-RobocopyJob {
    <#
    .SYNOPSIS
        Starts a robocopy process for a chunk
    .DESCRIPTION
        Launches a robocopy background process for chunk replication with comprehensive argument
        building, validation, and logging. Supports mirror/non-mirror modes, bandwidth throttling,
        exclusions, dry-run preview, and custom robocopy switches. Constructs argument list via
        New-RobocopyArguments, validates chunk paths, and returns job tracking object for
        orchestration. Core execution primitive for parallel chunk processing.
    .PARAMETER Chunk
        Chunk object with SourcePath, DestinationPath, RobocopyArgs
    .PARAMETER LogPath
        Path for robocopy log file
    .PARAMETER ThreadsPerJob
        Number of threads for robocopy (/MT:n)
    .PARAMETER RobocopyOptions
        Hashtable of robocopy options from profile. Supports:
        - Switches: Array of robocopy switches (e.g., @("/MIR", "/COPYALL"))
        - ExcludeFiles: Array of file patterns to exclude (e.g., @("*.tmp", "~*"))
        - ExcludeDirs: Array of directory names to exclude
        - RetryCount: Override default retry count
        - RetryWait: Override default retry wait seconds
        - NoMirror: Set to $true to use /E instead of /MIR (copy without deleting)
        - SkipJunctions: Set to $false to include junction points (default: skip)
        - InterPacketGapMs: Bandwidth throttling - milliseconds between packets (robocopy /IPG:n)
          Use this to limit network bandwidth consumption. Higher values = slower transfer.
          Example: 50 gives roughly 40 Mbps per job, 100 gives roughly 20 Mbps.
    .PARAMETER DryRun
        If true, runs robocopy with /L flag (list only, no actual copying)
    .OUTPUTS
        PSCustomObject with Process, Chunk, StartTime, LogPath, DryRun
    .EXAMPLE
        $options = @{
            Switches = @("/COPYALL", "/DCOPY:DAT")
            ExcludeFiles = @("*.tmp", "*.log")
            ExcludeDirs = @("temp", "cache")
            NoMirror = $true
            InterPacketGapMs = 50  # Throttle bandwidth
        }
        Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $options
    .EXAMPLE
        Start-RobocopyJob -Chunk $chunk -LogPath $logPath -DryRun
        # Preview mode - shows what would be copied
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSCustomObject]$Chunk,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [ValidateRange(1, 128)]
        [int]$ThreadsPerJob = $script:DefaultThreadsPerJob,

        [hashtable]$RobocopyOptions = @{},

        [switch]$DryRun
    )

    # Validate Chunk properties
    if ([string]::IsNullOrWhiteSpace($Chunk.SourcePath)) {
        throw "Chunk.SourcePath is required and cannot be null or empty"
    }
    if ([string]::IsNullOrWhiteSpace($Chunk.DestinationPath)) {
        throw "Chunk.DestinationPath is required and cannot be null or empty"
    }

    # Build arguments using the dedicated function
    $chunkArgs = if ($Chunk.RobocopyArgs) { @($Chunk.RobocopyArgs) } else { @() }
    $argList = New-RobocopyArguments `
        -SourcePath $Chunk.SourcePath `
        -DestinationPath $Chunk.DestinationPath `
        -LogPath $LogPath `
        -ThreadsPerJob $ThreadsPerJob `
        -RobocopyOptions $RobocopyOptions `
        -ChunkArgs $chunkArgs `
        -DryRun:$DryRun

    # Initialize the progress buffer type (lazy load C# class)
    if (-not (Initialize-RobocopyProgressBufferType)) {
        throw "Failed to initialize RobocopyProgressBuffer type. Check logs for compilation errors."
    }

    # Create thread-safe progress buffer for streaming stdout capture
    $progressBuffer = [Robocurse.RobocopyProgressBuffer]::new()

    # Create process start info
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    # Require validated robocopy path - no fallback to prevent unvalidated execution
    if (-not $script:RobocopyPath) {
        throw "Robocopy path not validated. Call Test-RobocopyAvailable before starting jobs."
    }
    $psi.FileName = $script:RobocopyPath
    $psi.Arguments = $argList -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # Capture stdout for reliable stat parsing - avoids file system flush race conditions
    # that occur in Session 0 (scheduled tasks) where log file may not be fully written
    # when process exits. Stdout is immediately available in memory when process completes.
    $psi.RedirectStandardOutput = $true
    # Note: Not redirecting stderr - robocopy rarely writes to stderr,
    # and redirecting without reading can cause deadlock on large error output.
    # Robocopy errors are captured in the log file via /LOG and exit codes.
    $psi.RedirectStandardError = $false

    Write-RobocurseLog -Message "Robocopy args: $($argList -join ' ')" -Level 'Debug' -Component 'Robocopy'
    Write-Host "[ROBOCOPY CMD] $($psi.FileName) $($psi.Arguments)"

    # Create and configure the process object
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    # Enable events for async output capture
    $process.EnableRaisingEvents = $true

    # Set up streaming output handler for real-time progress
    # Event handler runs on thread pool - keep it fast, use thread-safe operations only
    # Note: We use Register-ObjectEvent instead of add_OutputDataReceived/.GetNewClosure()
    # because .GetNewClosure() + delegate crashes PowerShell when called from async I/O thread
    $outputEvent = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action {
        param($sender, $eventArgs)
        if ($null -ne $eventArgs.Data) {
            $line = $eventArgs.Data
            $buffer = $Event.MessageData

            # Add to buffer for final parsing (ConcurrentQueue.Enqueue is thread-safe)
            $buffer.Lines.Enqueue($line)

            # Parse line and update progress counters in real-time
            # Pattern: "New File|Newer|Older|Changed" followed by size and path
            if ($line -match '^\s*(New File|Newer|Older|Changed)\s+(\d+)\s+(.+)$') {
                # A new file is starting - finalize previous file and start tracking new one
                $prevSize = $buffer.CurrentFileSize
                if ($prevSize -gt 0) {
                    # Previous file completed (reached 100%), add its bytes to total
                    $buffer.AddCompletedBytes($prevSize)
                    $buffer.IncrementFiles()
                }
                # Start tracking new file
                $buffer.CurrentFileSize = [long]$Matches[2]
                $buffer.CurrentFileBytes = 0
                $buffer.CurrentFile = $Matches[3]
            }
            # Pattern: Progress percentage (e.g., "  5.0%", " 50.0%", "100%")
            elseif ($line -match '^\s*(\d+(?:\.\d+)?)\s*%') {
                $percentage = [double]$Matches[1]
                $currentSize = $buffer.CurrentFileSize
                if ($currentSize -gt 0) {
                    $buffer.CurrentFileBytes = [long]($currentSize * $percentage / 100)
                }
            }

            # Update timestamp
            $buffer.LastUpdate = [datetime]::Now
        }
    } -MessageData $progressBuffer

    # Start the process
    $process.Start() | Out-Null

    # Assign to Job Object for automatic cleanup on parent exit
    # This ensures robocopy processes don't become orphaned if the GUI is closed or crashes
    Add-ProcessToJobObject -Process $process | Out-Null

    # Begin async output reading (triggers OutputDataReceived events)
    $process.BeginOutputReadLine()

    return [PSCustomObject]@{
        Process = $process
        Chunk = $Chunk
        StartTime = [datetime]::Now
        LogPath = $LogPath
        DryRun = $DryRun.IsPresent
        ProgressBuffer = $progressBuffer
        OutputEvent = $outputEvent  # Keep reference for cleanup
    }
}

function Get-RobocopyExitMeaning {
    <#
    .SYNOPSIS
        Interprets robocopy exit code using bitmask logic
    .PARAMETER ExitCode
        Robocopy exit code (bitmask)
    .PARAMETER MismatchSeverity
        How to treat mismatch exit codes (bit 2/value 4). Valid values:
        - "Warning" (default): Treat as warning but not failure
        - "Error": Treat as error, trigger retry
        - "Success": Ignore mismatches entirely
    .OUTPUTS
        PSCustomObject with Severity, Message, ShouldRetry, and bit flags
    .NOTES
        Exit code bits:
        Bit 0 (1)  = Files copied successfully
        Bit 1 (2)  = Extra files/dirs in destination
        Bit 2 (4)  = Mismatched files/dirs detected
        Bit 3 (8)  = Some files could NOT be copied (copy errors)
        Bit 4 (16) = Fatal error (no files copied, serious error)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 255)]
        [int]$ExitCode,

        [ValidateSet("Warning", "Error", "Success")]
        [string]$MismatchSeverity = $script:DefaultMismatchSeverity
    )

    # Parse bitmask flags
    $result = [PSCustomObject]@{
        ExitCode = $ExitCode
        Severity = "Success"
        Message = ""
        ShouldRetry = $false
        FilesCopied = ($ExitCode -band 1) -ne 0
        ExtrasDetected = ($ExitCode -band 2) -ne 0
        MismatchesFound = ($ExitCode -band 4) -ne 0
        CopyErrors = ($ExitCode -band 8) -ne 0
        FatalError = ($ExitCode -band 16) -ne 0
    }

    # Determine severity based on priority (worst case first)
    if ($result.FatalError) {
        $result.Severity = "Fatal"
        $result.Message = "Fatal error occurred"
        # Fatal errors (exit code 16) are often permanent: path not found, access denied, invalid parameters
        # Only retry if combined with copy errors (exit code 24 = 16+8) which suggests partial success
        # Pure fatal (16) without copy errors is likely permanent and shouldn't be retried indefinitely
        $result.ShouldRetry = $result.CopyErrors  # Retry only if there were also copy errors
    }
    elseif ($result.CopyErrors) {
        # Exit code 8: Some files couldn't be copied (e.g., open files, permission issues)
        # Robocopy already retried per-file with /R:n - treat as warning, not failure
        # The chunk completed, just with some files skipped
        $result.Severity = "Warning"
        $result.Message = "Some files could not be copied"
        $result.ShouldRetry = $false
    }
    elseif ($result.MismatchesFound) {
        # Configurable severity for mismatches
        $result.Severity = $MismatchSeverity
        $result.Message = "Mismatched files detected"
        $result.ShouldRetry = ($MismatchSeverity -eq "Error")
    }
    elseif ($result.ExtrasDetected) {
        $result.Severity = "Success"
        $result.Message = "Extra files cleaned from destination"
    }
    elseif ($result.FilesCopied) {
        $result.Severity = "Success"
        $result.Message = "Files copied successfully"
    }
    else {
        $result.Severity = "Success"
        $result.Message = "No changes needed"
    }

    return $result
}

function ConvertFrom-RobocopyLog {
    <#
    .SYNOPSIS
        Parses robocopy output for progress and statistics
    .DESCRIPTION
        Extracts file counts, byte counts, speed metrics, and error messages from robocopy
        output using locale-independent patterns. Supports both direct content parsing (from
        captured stdout) and file-based reading. Prefer passing Content parameter over LogPath
        for reliability - captured stdout avoids file system flush race conditions that occur
        in Session 0 scheduled tasks where log files may not be fully written when the
        robocopy process exits.
    .PARAMETER LogPath
        Path to log file. Used if Content not provided.
    .PARAMETER Content
        Raw robocopy output content. When provided, LogPath is ignored for reading.
        This avoids file system flush race conditions in Session 0 scheduled tasks.
    .PARAMETER TailLines
        Number of lines to read from end (for in-progress parsing)
    .OUTPUTS
        PSCustomObject with file counts, byte counts, speed, and current file
    .NOTES
        Prefer passing Content (captured stdout) over LogPath for reliability.
        File-based reading can fail in Session 0 due to buffering delays.
    #>
    [CmdletBinding()]
    param(
        [string]$LogPath,

        [string]$Content,

        [int]$TailLines = 100
    )

    # Initialize result with zero values
    # ParseSuccess indicates if we successfully extracted statistics from the log
    # ParseWarning contains any non-fatal issues encountered during parsing
    $result = [PSCustomObject]@{
        FilesCopied = 0
        FilesSkipped = 0
        FilesFailed = 0
        DirsCopied = 0
        DirsSkipped = 0
        DirsFailed = 0
        BytesCopied = 0
        Speed = ""
        CurrentFile = ""
        ParseSuccess = $false
        ParseWarning = $null
        ErrorMessage = $null  # Extracted error message(s) from robocopy output
    }

    # Track whether we're reading from file (progress polling) vs provided content (final parsing)
    # When reading from file, missing stats is expected (job still running) - log at Debug level
    # When content is provided, missing stats is unexpected (job completed) - log at Warning level
    $isProgressPolling = [string]::IsNullOrEmpty($Content)

    # Get content from parameter or read from file
    if ($isProgressPolling) {
        # No content provided, read from file (progress polling case)
        if ([string]::IsNullOrEmpty($LogPath)) {
            $result.ParseWarning = "Neither Content nor LogPath provided"
            return $result
        }

        if (-not (Test-Path $LogPath)) {
            $result.ParseWarning = "Log file does not exist: $LogPath"
            return $result
        }

        # Use FileShare.ReadWrite to allow robocopy to continue writing while we read
        # This prevents ERROR 32 (sharing violation) when progress polling reads active log files
        $fs = $null
        $sr = $null
        try {
            $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs)
            $Content = $sr.ReadToEnd()
        }
        catch {
            # Log at Debug level - file lock during progress polling is expected behavior
            # The ParseWarning in the result object surfaces actual issues to callers
            $result.ParseWarning = "Failed to read log file: $($_.Exception.Message)"
            Write-RobocurseLog "Failed to read robocopy log file '$LogPath': $_" -Level 'Debug' -Component 'Robocopy'
            return $result
        }
        finally {
            if ($sr) { $sr.Dispose() }
            if ($fs) { $fs.Dispose() }
        }
    }

    if ([string]::IsNullOrEmpty($Content)) {
        $result.ParseWarning = "Content was empty"
        return $result
    }

    # Parse summary statistics using locale-independent patterns
    # The summary table structure is consistent across locales:
    #   - Three data lines (Dirs, Files, Bytes) with 6 numeric columns each
    #   - The label text varies by locale but column structure is fixed
    #   - May or may not have a separator line of dashes before the table
    #
    # Strategy: Find lines that match the stats pattern (text : numbers) directly
    # Column order: Total, Copied, Skipped, Mismatch, FAILED, Extras
    #
    # Locale considerations:
    #   - Some locales use comma as decimal separator (1,5 instead of 1.5)
    #   - Some use period as thousands separator (1.000 instead of 1000)
    #   - We normalize by replacing commas with periods and removing spaces in numbers

    try {
        $lines = $Content -split "`n"

        # Find all lines that match the stats pattern: "label : numbers"
        # The last 3 such lines should be Dirs, Files, Bytes
        # Pattern accepts both . and , as potential decimal separators
        # Note: Don't allow spaces within number groups as that breaks column separation
        $statsPattern = ':\s*([\d.,]+)\s*[kmgt]?\s+([\d.,]+)\s*[kmgt]?\s+([\d.,]+)\s*[kmgt]?\s+([\d.,]+)\s*[kmgt]?\s+([\d.,]+)\s*[kmgt]?\s+([\d.,]+)'
        $statsLines = @()
        foreach ($line in $lines) {
            if ($line -match $statsPattern) {
                $statsLines += $line
            }
        }

        # Helper function to parse locale-flexible numbers
        $parseLocaleNumber = {
            param([string]$numStr)
            if ([string]::IsNullOrWhiteSpace($numStr)) { return 0 }
            # Remove spaces (thousands separator in some locales)
            $cleaned = $numStr -replace '\s', ''
            # Detect European format: periods as thousands separator, comma as decimal
            # Pattern: digits with optional period groups, then comma, then any decimal digits
            # Examples: "1.234,56" "1.234.567,89" "1,5" "1.234,567"
            if ($cleaned -match '^[\d.]+,\d+$' -and $cleaned -notmatch '\.\d{1,2}\.') {
                # Looks like European format - comma is the decimal separator
                # Remove periods (thousands separators) and convert comma to period
                $cleaned = $cleaned -replace '\.', '' -replace ',', '.'
            }
            elseif ($cleaned -match ',') {
                # Has commas but doesn't look like European decimal format
                # Likely commas are thousands separators (US format: 1,234,567.89)
                $cleaned = $cleaned -replace ',', ''
            }
            $parsedValue = 0.0
            if ([double]::TryParse($cleaned, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedValue)) {
                return $parsedValue
            }
            return 0
        }

        # If we found at least 3 matching lines, parse them
        if ($statsLines.Count -ge 3) {
            # Mark as successful parse (we found stats lines)
            $result.ParseSuccess = $true
            Write-RobocurseLog -Message "Found $($statsLines.Count) stats lines in robocopy log" -Level 'Debug' -Component 'Robocopy'

            # Last 3 lines: Dirs, Files, Bytes (in order)
            $dirsLine = $statsLines[$statsLines.Count - 3]
            $filesLine = $statsLines[$statsLines.Count - 2]
            $bytesLine = $statsLines[$statsLines.Count - 1]

            # Parse Dirs line (all integers)
            if ($dirsLine -match $statsPattern) {
                $result.DirsCopied = [int](& $parseLocaleNumber $matches[2])
                $result.DirsSkipped = [int](& $parseLocaleNumber $matches[3])
                $result.DirsFailed = [int](& $parseLocaleNumber $matches[5])
            }

            # Parse Files line (all integers)
            if ($filesLine -match $statsPattern) {
                $result.FilesCopied = [int](& $parseLocaleNumber $matches[2])
                $result.FilesSkipped = [int](& $parseLocaleNumber $matches[3])
                $result.FilesFailed = [int](& $parseLocaleNumber $matches[5])
                Write-RobocurseLog -Message "Parsed stats - FilesCopied: $($result.FilesCopied), FilesSkipped: $($result.FilesSkipped), FilesFailed: $($result.FilesFailed)" -Level 'Debug' -Component 'Robocopy'
            }
            else {
                Write-RobocurseLog -Message "Files line did not match stats pattern. Line: '$filesLine'" -Level 'Warning' -Component 'Robocopy'
            }

            # Parse Bytes line - need to handle unit suffixes (k, m, g, t)
            # Pattern: captures number+unit pairs (Total, Copied with their units)
            $bytesPattern = ':\s*([\d.,]+)\s*([kmgt]?)\s+([\d.,]+)\s*([kmgt]?)'
            if ($bytesLine -match $bytesPattern) {
                $byteValue = & $parseLocaleNumber $matches[3]
                $unit = if ($matches[4]) { $matches[4].ToLower() } else { '' }

                $result.BytesCopied = switch ($unit) {
                    'k' { [long]($byteValue * 1KB) }
                    'm' { [long]($byteValue * 1MB) }
                    'g' { [long]($byteValue * 1GB) }
                    't' { [long]($byteValue * 1TB) }
                    default { [long]$byteValue }
                }
            }
        }
        else {
            # No final summary table yet - job is still in progress
            # Parse file listing lines to calculate incremental BytesCopied
            # Pattern: "New File|Newer|Older|Changed" followed by size and path
            [int64]$bytesCopied = 0
            [int]$filesCopied = 0
            [string]$currentFile = ""
            [int64]$currentFileSize = 0
            [int64]$currentFileBytes = 0

            foreach ($line in $lines) {
                # Pattern: "New File [size] [path]" - announces a new file about to be copied
                if ($line -match '^\s*(New File|Newer|Older|Changed)\s+(\d+)\s+(.+)$') {
                    # Finalize previous file (add its full size - it completed before this line appeared)
                    if ($currentFileSize -gt 0) {
                        $bytesCopied += $currentFileSize
                        $filesCopied++
                    }
                    # Start tracking new file
                    $currentFile = $Matches[3]
                    $currentFileSize = [int64]$Matches[2]
                    $currentFileBytes = 0
                }
                # Pattern: Progress percentage (e.g., "  5.0%", " 50.0%", "100%")
                elseif ($line -match '^\s*(\d+(?:\.\d+)?)\s*%') {
                    $percentage = [double]$Matches[1]
                    if ($currentFileSize -gt 0) {
                        $currentFileBytes = [int64]($currentFileSize * $percentage / 100)
                    }
                }
            }

            # Add current file's partial progress
            $bytesCopied += $currentFileBytes

            # Update result with incremental progress
            $result.BytesCopied = $bytesCopied
            $result.FilesCopied = $filesCopied
            $result.CurrentFile = $currentFile

            # During progress polling, missing final stats is expected
            if (-not $isProgressPolling) {
                Write-RobocurseLog -Message "No stats lines found in robocopy log (found $($statsLines.Count), need 3). Log path: $LogPath" -Level 'Warning' -Component 'Robocopy'
            }
        }

        # Parse Speed line - look for numeric pattern followed by common speed units
        # Robocopy outputs speed in format like "50.123 MegaBytes/min" or "2621440 Bytes/sec"
        # The unit names may be localized but the numeric pattern is consistent
        if ($Content -match '([\d.]+)\s+(Mega)?Bytes[/\s]*(min|sec)') {
            $speedValue = $matches[1]
            $isMega = $matches[2] -eq 'Mega'
            $timeUnit = $matches[3]
            $result.Speed = if ($isMega) { "$speedValue MB/$timeUnit" } else { "$speedValue B/$timeUnit" }
        }

        # Parse current file from progress lines (locale-independent)
        # Robocopy progress lines have: indicator (may contain spaces), size, path
        # Format: "  New File  1024  path\file.txt" or "  *EXTRA File  100  path\file.txt"
        # Key insight: look for a number followed by a backslash path
        $progressMatches = [regex]::Matches($Content, '([\d.]+)\s*[kmgt]?\s+(\S*[\\\/].+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if ($progressMatches.Count -gt 0) {
            $lastMatch = $progressMatches[$progressMatches.Count - 1]
            $potentialPath = $lastMatch.Groups[2].Value.Trim()
            # Verify it looks like a path (not a summary line with just numbers)
            if ($potentialPath -match '[a-zA-Z]') {
                $result.CurrentFile = $potentialPath
            }
        }
    }
    catch {
        # Log parsing errors but don't fail - return partial results
        $result.ParseWarning = "Parse error: $($_.Exception.Message)"
        Write-RobocurseLog "Error parsing robocopy log '$LogPath': $_" -Level 'Warning' -Component 'Robocopy'
    }

    # If we didn't find stats lines, this might be an in-progress job or unexpected format
    if (-not $result.ParseSuccess) {
        # Only warn if file had content (empty file is normal for just-started jobs)
        if ($Content -and $Content.Length -gt 100) {
            if (-not $result.ParseWarning) {
                $result.ParseWarning = "No statistics found in log file (job may be in progress or log format unexpected)"
            }
            Write-RobocurseLog "Could not extract statistics from robocopy log '$LogPath' ($($Content.Length) bytes) - job may still be in progress" `
                -Level 'Debug' -Component 'Robocopy'
        }
    }

    # Extract error messages from log content
    # Robocopy error lines typically contain "ERROR" followed by error code and message
    # Common patterns:
    #   - "ERROR 5 (0x00000005) Access is denied."
    #   - "ERROR 2 (0x00000002) The system cannot find the file specified."
    #   - "ERROR 3 (0x00000003) The system cannot find the path specified."
    #   - "ERROR : xxx" (generic error lines)
    if ($Content) {
        $errorLines = @()
        $lines = $Content -split "`r?`n"
        foreach ($line in $lines) {
            # Match ERROR followed by error code or message
            if ($line -match '\bERROR\s+(\d+|:)\s*(.*)') {
                $trimmedLine = $line.Trim()
                if ($trimmedLine -and $trimmedLine.Length -gt 5) {
                    $errorLines += $trimmedLine
                }
            }
        }
        # Deduplicate and limit to first few unique errors
        if ($errorLines.Count -gt 0) {
            $uniqueErrors = $errorLines | Select-Object -Unique | Select-Object -First 5
            $result.ErrorMessage = $uniqueErrors -join "; "
        }
    }

    return $result
}

function Get-RobocopyProgress {
    <#
    .SYNOPSIS
        Gets current progress from a running robocopy job
    .DESCRIPTION
        Returns real-time progress from the streaming stdout buffer.
        The ProgressBuffer C# class tracks bytes in real-time as OutputDataReceived
        events fire, providing smooth progress updates.
    .PARAMETER Job
        Job object from Start-RobocopyJob
    .OUTPUTS
        PSCustomObject with CurrentFile, BytesCopied, FilesCopied, IsComplete, LastUpdate
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Job
    )

    # Use the ProgressBuffer which tracks bytes in real-time from stdout events
    $buffer = $Job.ProgressBuffer
    if (-not $buffer) {
        # Fallback to log file if no buffer (shouldn't happen with current implementation)
        return ConvertFrom-RobocopyLog -LogPath $Job.LogPath -TailLines 100
    }

    return [PSCustomObject]@{
        BytesCopied = $buffer.BytesCopied
        FilesCopied = $buffer.FilesCopied
        CurrentFile = $buffer.CurrentFile
        LastUpdate = $buffer.LastUpdate
        ParseSuccess = $true
    }
}

function Wait-RobocopyJob {
    <#
    .SYNOPSIS
        Waits for a robocopy job to complete
    .DESCRIPTION
        Waits for the robocopy process to exit and collects final statistics.
        Uses the streaming progress buffer to get captured output, avoiding
        file system race conditions that occur in Session 0 scheduled tasks.
    .PARAMETER Job
        Job object from Start-RobocopyJob
    .PARAMETER TimeoutSeconds
        Max wait time (0 = infinite)
    .OUTPUTS
        PSCustomObject with ExitCode, ExitMeaning, Duration, Stats
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Job,

        [int]$TimeoutSeconds = 0
    )

    # Wait for process to complete with proper resource cleanup
    $capturedOutput = $null
    try {
        if ($TimeoutSeconds -gt 0) {
            $completed = $Job.Process.WaitForExit($TimeoutSeconds * 1000)
            if (-not $completed) {
                try { $Job.Process.Kill() } catch { }
                throw "Robocopy job timed out after $TimeoutSeconds seconds"
            }
        }
        else {
            $Job.Process.WaitForExit()
        }

        # Calculate duration
        $duration = [datetime]::Now - $Job.StartTime

        # Get exit code and interpret it
        $exitCode = $Job.Process.ExitCode
        $exitMeaning = Get-RobocopyExitMeaning -ExitCode $exitCode

        # Parse final stats from log file (authoritative source - robocopy flushes before exit)
        # Note: ProgressBuffer is for real-time progress during the job (Get-RobocopyProgress).
        # Do NOT use captured stdout for final stats - race condition with OutputDataReceived events.
        $finalStats = ConvertFrom-RobocopyLog -LogPath $Job.LogPath

        return [PSCustomObject]@{
            ExitCode = $exitCode
            ExitMeaning = $exitMeaning
            Duration = $duration
            Stats = $finalStats
        }
    }
    finally {
        # Wait for async OutputDataReceived events to finish processing
        # Events run on thread pool and may still be queued after WaitForExit()
        if ($Job.ProgressBuffer) {
            try {
                $lastCount = -1
                $stableIterations = 0
                for ($i = 0; $i -lt 50; $i++) {
                    $currentCount = $Job.ProgressBuffer.LineCount
                    if ($currentCount -eq $lastCount) {
                        $stableIterations++
                        if ($stableIterations -ge 3) {
                            break  # LineCount stable for 3 iterations, events are done
                        }
                    } else {
                        $stableIterations = 0
                    }
                    $lastCount = $currentCount
                    Start-Sleep -Milliseconds 20
                }
            } catch { }
        }

        # Clean up event subscription to prevent orphaned subscriptions
        # Must happen before process disposal
        if ($Job.OutputEvent) {
            try {
                Unregister-Event -SourceIdentifier $Job.OutputEvent.Name -ErrorAction SilentlyContinue
                Remove-Job -Id $Job.OutputEvent.Id -Force -ErrorAction SilentlyContinue
            } catch { }
        }

        # Always dispose process handle to prevent handle leaks
        # Critical for long-running operations with many jobs
        try { $Job.Process.Dispose() } catch { }
    }
}

function Test-RobocopyVerification {
    <#
    .SYNOPSIS
        Verifies a copy operation by comparing source and destination
    .DESCRIPTION
        Runs robocopy in list mode (/L) to compare source and destination directories.
        This is useful as a post-copy verification step to detect:
        - Files that failed to copy silently
        - Files that were modified during copy
        - Timestamp mismatches (when using /FFT for FAT file time tolerance)

        The function returns a verification result indicating whether the
        directories are in sync and details about any discrepancies.
    .PARAMETER SourcePath
        Source directory path that was copied from
    .PARAMETER DestinationPath
        Destination directory path that was copied to
    .PARAMETER UseFatTimeTolerance
        Use FAT file system time tolerance (/FFT - 2 second granularity).
        Useful when copying to/from FAT32 or network shares with time precision issues.
    .PARAMETER RobocopyOptions
        Optional hashtable of robocopy options (ExcludeFiles, ExcludeDirs) to match
        the original copy operation
    .OUTPUTS
        PSCustomObject with:
        - Verified: $true if source and destination are in sync
        - MissingFiles: Count of files in source but not destination
        - ExtraFiles: Count of files in destination but not source
        - MismatchedFiles: Count of files with different sizes/timestamps
        - Details: Detailed verification message
        - LogPath: Path to verification log file
    .EXAMPLE
        $result = Test-RobocopyVerification -SourcePath "C:\Source" -DestinationPath "D:\Backup"
        if ($result.Verified) { "Backup verified successfully" }
    .EXAMPLE
        # Verify with FAT time tolerance for network shares
        $result = Test-RobocopyVerification -SourcePath "C:\Data" -DestinationPath "\\server\share" -UseFatTimeTolerance
    .NOTES
        This function is designed for post-copy verification and does NOT modify any files.
        It uses robocopy /L (list-only) mode exclusively.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [switch]$UseFatTimeTolerance,

        [hashtable]$RobocopyOptions = @{}
    )

    # Validate paths
    $safeSourcePath = Get-SanitizedPath -Path $SourcePath -ParameterName "SourcePath"
    $safeDestPath = Get-SanitizedPath -Path $DestinationPath -ParameterName "DestinationPath"

    # Create temp log file for verification
    $tempLogPath = Join-Path ([System.IO.Path]::GetTempPath()) "Robocurse-Verify-$([guid]::NewGuid().ToString('N')).log"

    # Build verification arguments
    # /L = List only (no copying)
    # /E = Include subdirectories including empty
    # /NJH /NJS = No job header/summary (cleaner parsing)
    # /BYTES = Show sizes in bytes for precision
    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.Add((Format-QuotedPath -Path $safeSourcePath))
    $argList.Add((Format-QuotedPath -Path $safeDestPath))
    $argList.Add("/L")
    $argList.Add("/E")
    $argList.Add("/NJH")
    $argList.Add("/NJS")
    $argList.Add("/BYTES")
    $argList.Add("/R:0")
    $argList.Add("/W:0")
    $argList.Add("/LOG:$(Format-QuotedPath -Path $tempLogPath)")

    # Add FAT time tolerance if requested
    if ($UseFatTimeTolerance) {
        $argList.Add("/FFT")
    }

    # Add exclusions from original copy options
    if ($RobocopyOptions.ExcludeFiles -and $RobocopyOptions.ExcludeFiles.Count -gt 0) {
        $safeExcludeFiles = Get-SanitizedExcludePatterns -Patterns $RobocopyOptions.ExcludeFiles -Type 'Files'
        if ($safeExcludeFiles.Count -gt 0) {
            $argList.Add("/XF")
            foreach ($pattern in $safeExcludeFiles) {
                $argList.Add((Format-QuotedPath -Path $pattern))
            }
        }
    }

    if ($RobocopyOptions.ExcludeDirs -and $RobocopyOptions.ExcludeDirs.Count -gt 0) {
        $safeExcludeDirs = Get-SanitizedExcludePatterns -Patterns $RobocopyOptions.ExcludeDirs -Type 'Dirs'
        if ($safeExcludeDirs.Count -gt 0) {
            $argList.Add("/XD")
            foreach ($dir in $safeExcludeDirs) {
                $argList.Add((Format-QuotedPath -Path $dir))
            }
        }
    }

    # Run robocopy in verification mode
    $result = [PSCustomObject]@{
        Verified = $false
        MissingFiles = 0
        ExtraFiles = 0
        MismatchedFiles = 0
        Details = ""
        LogPath = $tempLogPath
    }

    try {
        # Require validated robocopy path
        if (-not $script:RobocopyPath) {
            throw "Robocopy path not validated. Call Test-RobocopyAvailable before verification."
        }

        Write-RobocurseLog -Message "Running verification: $safeSourcePath -> $safeDestPath" -Level 'Debug' -Component 'Robocopy'

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:RobocopyPath
        $psi.Arguments = $argList -join ' '
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError = $false

        $process = [System.Diagnostics.Process]::Start($psi)
        $process.WaitForExit()

        $exitCode = $process.ExitCode
        $exitMeaning = Get-RobocopyExitMeaning -ExitCode $exitCode

        # Parse the verification log
        if (Test-Path $tempLogPath) {
            $logContent = Get-Content -Path $tempLogPath -Raw -ErrorAction SilentlyContinue

            if ($logContent) {
                # Count files that would be copied (missing from destination)
                $newFileMatches = [regex]::Matches($logContent, '^\s*New File', [System.Text.RegularExpressions.RegexOptions]::Multiline)
                $result.MissingFiles = $newFileMatches.Count

                # Count extra files (in destination but not source) - only with /MIR would remove them
                $extraFileMatches = [regex]::Matches($logContent, '^\s*\*EXTRA File', [System.Text.RegularExpressions.RegexOptions]::Multiline)
                $result.ExtraFiles = $extraFileMatches.Count

                # Count mismatched files (different size/time)
                $newerMatches = [regex]::Matches($logContent, '^\s*(Newer|Older|Changed)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
                $result.MismatchedFiles = $newerMatches.Count
            }
        }

        # Determine verification status
        # Exit codes 0-3 are generally successful states
        # 0 = No changes needed (perfect sync)
        # 1 = Files were different (would be copied)
        # 2 = Extra files detected
        # 3 = Both 1 and 2
        $result.Verified = ($result.MissingFiles -eq 0 -and $result.MismatchedFiles -eq 0)

        if ($result.Verified) {
            $result.Details = "Verification passed: Source and destination are in sync"
            if ($result.ExtraFiles -gt 0) {
                $result.Details += " ($($result.ExtraFiles) extra files in destination)"
            }
        }
        else {
            $issues = @()
            if ($result.MissingFiles -gt 0) { $issues += "$($result.MissingFiles) missing files" }
            if ($result.MismatchedFiles -gt 0) { $issues += "$($result.MismatchedFiles) mismatched files" }
            $result.Details = "Verification failed: " + ($issues -join ", ")
        }

        Write-RobocurseLog -Message "Verification result: $($result.Details)" -Level 'Info' -Component 'Robocopy'
    }
    catch {
        $result.Details = "Verification error: $($_.Exception.Message)"
        Write-RobocurseLog -Message "Verification failed: $_" -Level 'Error' -Component 'Robocopy'
    }

    return $result
}

function Write-RobocopyCompletionEvent {
    <#
    .SYNOPSIS
        Emits structured SIEM events for robocopy job completion
    .DESCRIPTION
        Parses robocopy job results and emits structured SIEM events for:
        - ChunkComplete: Successful chunk replication with detailed stats
        - ChunkError: Failed chunks with error details

        This enables enterprise monitoring and alerting on file replication operations.
    .PARAMETER Job
        Job object from Start-RobocopyJob
    .PARAMETER JobResult
        Result from Wait-RobocopyJob containing ExitCode, ExitMeaning, Duration, Stats
    .PARAMETER ChunkId
        Unique identifier for the chunk
    .PARAMETER ProfileName
        Name of the profile this chunk belongs to
    .EXAMPLE
        $result = Wait-RobocopyJob -Job $job
        Write-RobocopyCompletionEvent -Job $job -JobResult $result -ChunkId 42 -ProfileName "DailyBackup"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Job,

        [Parameter(Mandatory)]
        [PSCustomObject]$JobResult,

        [Parameter(Mandatory)]
        [int]$ChunkId,

        [string]$ProfileName = "Unknown"
    )

    $stats = $JobResult.Stats
    $exitMeaning = $JobResult.ExitMeaning

    # Determine event type based on exit code severity
    $eventType = if ($exitMeaning.Severity -in @('Fatal', 'Error')) {
        'ChunkError'
    } else {
        'ChunkComplete'
    }

    # Build structured event data
    $eventData = @{
        chunkId = $ChunkId
        profileName = $ProfileName
        sourcePath = $Job.Chunk.SourcePath
        destinationPath = $Job.Chunk.DestinationPath
        exitCode = $JobResult.ExitCode
        exitSeverity = $exitMeaning.Severity
        exitMessage = $exitMeaning.Message
        durationSeconds = [math]::Round($JobResult.Duration.TotalSeconds, 2)
        dryRun = $Job.DryRun

        # File statistics
        filesCopied = if ($stats) { $stats.FilesCopied } else { 0 }
        filesSkipped = if ($stats) { $stats.FilesSkipped } else { 0 }
        filesFailed = if ($stats) { $stats.FilesFailed } else { 0 }

        # Directory statistics
        dirsCopied = if ($stats) { $stats.DirsCopied } else { 0 }
        dirsSkipped = if ($stats) { $stats.DirsSkipped } else { 0 }
        dirsFailed = if ($stats) { $stats.DirsFailed } else { 0 }

        # Byte statistics
        bytesCopied = if ($stats) { $stats.BytesCopied } else { 0 }

        # Throughput calculation
        bytesPerSecond = if ($JobResult.Duration.TotalSeconds -gt 0 -and $stats.BytesCopied -gt 0) {
            [math]::Round($stats.BytesCopied / $JobResult.Duration.TotalSeconds, 0)
        } else { 0 }

        # Exit code flags for detailed analysis
        flags = @{
            filesCopied = $exitMeaning.FilesCopied
            extrasDetected = $exitMeaning.ExtrasDetected
            mismatchesFound = $exitMeaning.MismatchesFound
            copyErrors = $exitMeaning.CopyErrors
            fatalError = $exitMeaning.FatalError
        }
    }

    # Add error message if present
    if ($stats -and $stats.ErrorMessage) {
        $eventData.errorMessage = $stats.ErrorMessage
    }

    # Emit the SIEM event
    Write-SiemEvent -EventType $eventType -Data $eventData

    # Log summary
    $logLevel = if ($eventType -eq 'ChunkError') { 'Error' } else { 'Info' }
    $summaryMsg = "Chunk #$ChunkId completed: $($eventData.filesCopied) files, $(Format-FileSize -Bytes $eventData.bytesCopied) in $([math]::Round($JobResult.Duration.TotalSeconds, 1))s"
    if ($eventData.filesFailed -gt 0) {
        $summaryMsg += " ($($eventData.filesFailed) failed)"
    }
    Write-RobocurseLog -Message $summaryMsg -Level $logLevel -Component 'Robocopy'
}

function New-FailedFilesSummary {
    <#
    .SYNOPSIS
        Generates a summary file of all failed file operations from chunk logs
    .DESCRIPTION
        Parses chunk log files in the Jobs folder and extracts ERROR lines indicating
        files that failed to copy (locked, access denied, in use, etc.). Creates a summary
        file that can be viewed by the user or attached to emails. When SessionId is provided,
        only logs from that session are included, preventing stale data from previous runs.
    .PARAMETER JobsPath
        The Jobs folder path containing chunk logs (e.g., C:\Logs\Robocurse\2025-12-21\Jobs)
    .PARAMETER SessionId
        Optional orchestration session ID (GUID) to filter chunk logs. When provided,
        only logs matching {SessionId}_Chunk_*.log are processed.
    .OUTPUTS
        String path to the created summary file, or $null if no failed files found
    .EXAMPLE
        $summaryPath = New-FailedFilesSummary -JobsPath "C:\Logs\2025-12-21\Jobs" -SessionId "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobsPath,

        [Parameter(Mandatory = $false)]
        [string]$SessionId
    )

    if (-not (Test-Path $JobsPath)) {
        Write-RobocurseLog -Message "Jobs folder not found: $JobsPath" -Level 'Debug' -Component 'FailedFiles'
        return $null
    }

    # Filter by session ID if provided, otherwise get all chunk logs (backward compatible)
    $pattern = if ($SessionId) { "${SessionId}_Chunk_*.log" } else { "*Chunk_*.log" }
    $chunkLogs = Get-ChildItem -Path $JobsPath -Filter $pattern -ErrorAction SilentlyContinue
    if (-not $chunkLogs -or $chunkLogs.Count -eq 0) {
        Write-RobocurseLog -Message "No chunk logs found in: $JobsPath (pattern: $pattern)" -Level 'Debug' -Component 'FailedFiles'
        return $null
    }

    # Common Windows error codes and their meanings
    $errorDescriptions = @{
        2 = "File not found"
        3 = "Path not found"
        5 = "Access denied"
        6 = "Invalid handle"
        19 = "Media write-protected"
        21 = "Device not ready"
        29 = "Write fault"
        30 = "Read fault"
        32 = "File in use by another process"
        33 = "File locked"
        39 = "Disk full"
        80 = "File already exists"
        112 = "Disk full"
        121 = "Timeout"
        122 = "Buffer too small"
        123 = "Invalid filename"
        183 = "File already exists"
        206 = "Filename too long"
        1314 = "Privilege not held"
        1920 = "File encrypted (EFS)"
    }

    # Collect all ERROR entries from robocopy logs
    # Robocopy ERROR lines have format: [timestamp] ERROR <code> (0x<hex>) <message>
    # Example: 2024/01/15 10:30:45 ERROR 32 (0x00000020) Copying File D:\path\to\file.txt
    # Example: ERROR 5 (0x00000005) Access is denied.
    # The timestamp is optional, so match ERROR anywhere in the line
    # Robocopy retries files (R:3 = 3 retries), so deduplicate by file path
    $failedEntries = [System.Collections.Generic.List[string]]::new()
    $seenFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $errorCodePattern = '\bERROR\s+(\d+)\s+'
    # Pattern to extract file path from error line for deduplication
    # Includes: "Copying File", "Creating Destination Directory", "Changing File Attributes"
    $filePathPattern = '(?:Copying File|Creating Destination Directory|Changing File Attributes)\s+(.+)$'
    $currentChunk = ""

    foreach ($logFile in $chunkLogs) {
        try {
            $logContent = Get-Content -Path $logFile.FullName -ErrorAction Stop
            $chunkName = $logFile.BaseName
            $chunkHasErrors = $false

            foreach ($line in $logContent) {
                if ($line -match $errorCodePattern) {
                    $cleanLine = $line.Trim()
                    $errorCode = [int]$matches[1]

                    # Extract file path for deduplication (robocopy retries cause duplicate errors)
                    $filePath = $null
                    if ($cleanLine -match $filePathPattern) {
                        $filePath = $matches[1].Trim()
                    }

                    # Skip if we've already seen this file path
                    if ($filePath -and $seenFiles.Contains($filePath)) {
                        continue
                    }

                    # Track this file path
                    if ($filePath) {
                        $null = $seenFiles.Add($filePath)
                    }

                    if (-not $chunkHasErrors) {
                        # Add chunk header on first error
                        $failedEntries.Add("")
                        $failedEntries.Add("=== $chunkName ===")
                        $chunkHasErrors = $true
                    }

                    # Add error description if known (on same line)
                    $description = $errorDescriptions[$errorCode]
                    if ($description) {
                        $failedEntries.Add("$cleanLine [$description]")
                    }
                    else {
                        $failedEntries.Add($cleanLine)
                    }
                }
            }
        }
        catch {
            Write-RobocurseLog -Message "Failed to read log file $($logFile.Name): $($_.Exception.Message)" -Level 'Warning' -Component 'FailedFiles'
        }
    }

    if ($failedEntries.Count -eq 0) {
        Write-RobocurseLog -Message "No error entries found in chunk logs" -Level 'Debug' -Component 'FailedFiles'
        return $null
    }

    # Write the summary file (in parent of Jobs folder, with session ID if provided)
    $datePath = Split-Path -Parent $JobsPath
    $summaryFilename = if ($SessionId) { "FailedFiles_${SessionId}.txt" } else { "FailedFiles.txt" }
    $summaryPath = Join-Path $datePath $summaryFilename
    try {
        # Count unique files (entries minus chunk headers and blank lines)
        $uniqueFileCount = ($failedEntries | Where-Object { $_ -and $_ -notmatch '^===' }).Count
        $header = @(
            "Robocurse Failed Files Summary"
            "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "Total Failed Files: $uniqueFileCount"
            ""
            "These files could not be copied due to errors (locked, access denied, in use, etc.)"
            "=" * 80
        )

        $content = $header + $failedEntries
        $content | Out-File -FilePath $summaryPath -Encoding UTF8 -Force

        Write-RobocurseLog -Message "Created failed files summary: $summaryPath ($($failedEntries.Count) entries)" -Level 'Info' -Component 'FailedFiles'
        return $summaryPath
    }
    catch {
        Write-RobocurseLog -Message "Failed to write failed files summary: $($_.Exception.Message)" -Level 'Error' -Component 'FailedFiles'
        return $null
    }
}
