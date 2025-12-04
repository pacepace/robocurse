# Robocurse Logging Functions
# Script-scoped variables for current session state
$script:CurrentSessionId = $null
# Note: LogMutexTimeoutMs is defined in Robocurse.psm1 CONSTANTS region

function Invoke-WithLogMutex {
    <#
    .SYNOPSIS
        Executes a scriptblock while holding the log file mutex
    .DESCRIPTION
        Acquires a named mutex to synchronize log file writes across multiple
        threads and processes. Releases the mutex in a finally block to ensure
        cleanup even on errors.
    .PARAMETER ScriptBlock
        Code to execute while holding the mutex
    .PARAMETER MutexSuffix
        Suffix for the mutex name (e.g., 'Operational', 'SIEM')
    .OUTPUTS
        Result of the scriptblock, or $null if mutex acquisition times out
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory)]
        [string]$MutexSuffix
    )

    $mutex = $null
    $mutexAcquired = $false
    try {
        $fullMutexName = "Global\RobocurseLog_$MutexSuffix"
        $mutex = [System.Threading.Mutex]::new($false, $fullMutexName)

        $mutexAcquired = $mutex.WaitOne($script:LogMutexTimeoutMs)
        if (-not $mutexAcquired) {
            # Timeout - still execute the scriptblock (better than lost log)
            # This is a fallback; ideally should never happen
            return & $ScriptBlock
        }

        return & $ScriptBlock
    }
    finally {
        if ($mutex) {
            if ($mutexAcquired) {
                try { $mutex.ReleaseMutex() } catch {
                    # Cannot log here (infinite loop) - release failure is rare
                }
                # Dispose after release to avoid disposing while acquired
                $mutex.Dispose()
            }
            # Note: Only dispose if we acquired it - otherwise caller still owns it
        }
    }
}
$script:CurrentOperationalLogPath = $null
$script:CurrentSiemLogPath = $null
$script:CurrentJobsPath = $null

function Initialize-LogSession {
    <#
    .SYNOPSIS
        Creates log directory for today, generates session ID, initializes log files
    .DESCRIPTION
        Initializes logging for a new session. Also performs log rotation/cleanup
        to compress old logs and delete ancient ones based on retention settings.
    .PARAMETER LogRoot
        Root directory for logs (default: .\Logs)
    .PARAMETER CompressAfterDays
        Compress logs older than this many days (default from script constant or config)
    .PARAMETER DeleteAfterDays
        Delete compressed logs older than this many days (default from script constant or config)
    .OUTPUTS
        Hashtable with SessionId, OperationalLogPath, SiemLogPath
    #>
    [CmdletBinding()]
    param(
        [string]$LogRoot = ".\Logs",
        [ValidateRange(1, 365)]
        [int]$CompressAfterDays = $script:LogCompressAfterDays,
        [ValidateRange(1, 3650)]
        [int]$DeleteAfterDays = $script:LogDeleteAfterDays
    )

    # Validate that CompressAfterDays is less than DeleteAfterDays
    if ($CompressAfterDays -ge $DeleteAfterDays) {
        Write-Warning "CompressAfterDays ($CompressAfterDays) should be less than DeleteAfterDays ($DeleteAfterDays). Adjusting CompressAfterDays to $([Math]::Max(1, $DeleteAfterDays - 7))."
        $CompressAfterDays = [Math]::Max(1, $DeleteAfterDays - 7)
    }

    # Generate unique session ID based on timestamp
    $timestamp = Get-Date -Format "HHmmss"
    $milliseconds = (Get-Date).Millisecond
    $sessionId = "${timestamp}_${milliseconds}"

    # Create date-based directory structure
    $dateFolder = Get-Date -Format "yyyy-MM-dd"
    $logDirectory = Join-Path $LogRoot $dateFolder

    # Create the directory and Jobs subdirectory
    # Using New-Item -Force directly avoids TOCTOU race condition between Test-Path and New-Item
    # -Force succeeds silently if directory already exists
    New-Item -ItemType Directory -Path $logDirectory -Force -ErrorAction SilentlyContinue | Out-Null

    $jobsDirectory = Join-Path $logDirectory "Jobs"
    New-Item -ItemType Directory -Path $jobsDirectory -Force -ErrorAction SilentlyContinue | Out-Null

    # Define log file paths
    $operationalLogPath = Join-Path $logDirectory "Session_${sessionId}.log"
    $siemLogPath = Join-Path $logDirectory "Audit_${sessionId}.jsonl"

    # Create empty log files
    New-Item -ItemType File -Path $operationalLogPath -Force | Out-Null
    New-Item -ItemType File -Path $siemLogPath -Force | Out-Null

    # Update script-scoped variables
    $script:CurrentSessionId = $sessionId
    $script:CurrentOperationalLogPath = $operationalLogPath
    $script:CurrentSiemLogPath = $siemLogPath
    $script:CurrentJobsPath = $jobsDirectory

    # Perform log rotation/cleanup (compress old, delete ancient)
    # This runs at session start to maintain log hygiene
    try {
        Invoke-LogRotation -LogRoot $LogRoot -CompressAfterDays $CompressAfterDays -DeleteAfterDays $DeleteAfterDays
    }
    catch {
        Write-Warning "Log rotation failed: $($_.Exception.Message)"
        # Non-fatal - continue with session initialization
    }

    # Return session information
    return @{
        SessionId = $sessionId
        OperationalLogPath = $operationalLogPath
        SiemLogPath = $siemLogPath
        JobsPath = $jobsDirectory
    }
}

function Write-RobocurseLog {
    <#
    .SYNOPSIS
        Writes to operational log and optionally SIEM log
    .DESCRIPTION
        Logs messages to the operational log file with automatic caller information
        (function name and line number) for easier debugging.
    .PARAMETER Message
        Log message
    .PARAMETER Level
        Log level: Debug, Info, Warning, Error
    .PARAMETER Component
        Which component is logging (Orchestrator, Chunker, etc.)
    .PARAMETER SessionId
        Correlation ID for the current session
    .PARAMETER WriteSiem
        Also write a SIEM event (default: true for Warning/Error)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [string]$Component = 'General',

        [string]$SessionId = $script:CurrentSessionId,

        [bool]$WriteSiem = ($Level -in @('Warning', 'Error'))
    )

    # Get caller information from call stack
    # Index 1 is the immediate caller (index 0 is this function)
    $callStack = Get-PSCallStack
    $callerInfo = ""
    if ($callStack.Count -gt 1) {
        $caller = $callStack[1]
        $functionName = if ($caller.FunctionName -and $caller.FunctionName -ne '<ScriptBlock>') {
            $caller.FunctionName
        } else {
            'Main'
        }
        $lineNumber = $caller.ScriptLineNumber
        $callerInfo = "${functionName}:${lineNumber}"
    }

    # Format the log entry with caller info
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $levelUpper = $Level.ToUpper()
    $logEntry = "${timestamp} [${levelUpper}] [${Component}] [${callerInfo}] ${Message}"

    # Check if log session is initialized
    $logPath = $script:CurrentOperationalLogPath
    if (-not $logPath) {
        # For important messages, fall back to console
        if ($Level -in @('Error', 'Warning')) {
            switch ($Level) {
                'Error'   { Write-Error $logEntry }
                'Warning' { Write-Warning $logEntry }
            }
        }
        # For Info/Debug, silently skip
        return
    }

    # Write to operational log with mutex protection for thread safety
    try {
        # Ensure directory exists
        $logDir = Split-Path -Path $logPath -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        # Append to log file with mutex protection to prevent concurrent write corruption
        Invoke-WithLogMutex -MutexSuffix 'Operational' -ScriptBlock {
            Add-Content -Path $logPath -Value $logEntry -Encoding UTF8
        }.GetNewClosure()
    }
    catch {
        Write-Warning "Failed to write to operational log: $_"
    }

    # Write to SIEM if requested
    if ($WriteSiem) {
        # Map log level and component to appropriate SIEM event type
        # Use component context to determine the most accurate event type
        $eventType = switch ($Level) {
            'Error' {
                switch -Wildcard ($Component) {
                    'Chunk*'      { 'ChunkError' }
                    'Robocopy'    { 'ChunkError' }
                    'Config*'     { 'ConfigChange' }
                    'Email'       { 'EmailSent' }
                    'VSS'         { 'VssSnapshotRemoved' }
                    'Session'     { 'SessionEnd' }
                    'Profile'     { 'ProfileComplete' }
                    default       { 'ChunkError' }
                }
            }
            'Warning' {
                switch -Wildcard ($Component) {
                    'Chunk*'      { 'ChunkError' }
                    'Robocopy'    { 'ChunkError' }
                    'Config*'     { 'ConfigChange' }
                    'VSS'         { 'VssSnapshotRemoved' }
                    default       { 'ChunkError' }
                }
            }
            default { 'ChunkError' }  # Fallback for unexpected levels routed to SIEM
        }
        Write-SiemEvent -EventType $eventType -Data @{
            Level = $Level
            Component = $Component
            Caller = $callerInfo
            Message = $Message
        } -SessionId $SessionId
    }
}

function Write-SiemEvent {
    <#
    .SYNOPSIS
        Writes a SIEM-compatible JSON event
    .PARAMETER EventType
        Event type: SessionStart, SessionEnd, ChunkStart, ChunkComplete, ChunkError, etc.
    .PARAMETER Data
        Hashtable of event-specific data
    .PARAMETER SessionId
        Correlation ID
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('SessionStart', 'SessionEnd', 'ProfileStart', 'ProfileComplete',
                     'ChunkStart', 'ChunkComplete', 'ChunkError', 'ConfigChange', 'EmailSent',
                     'VssSnapshotCreated', 'VssSnapshotRemoved')]
        [string]$EventType,

        [hashtable]$Data = @{},

        [string]$SessionId = $script:CurrentSessionId
    )

    # Check if log session is initialized
    $siemPath = $script:CurrentSiemLogPath
    if (-not $siemPath) {
        # Silently skip if no log session
        return
    }

    # Get timestamp in ISO 8601 format with exactly 3 decimal places for milliseconds
    $now = Get-Date
    $utcTime = $now.ToUniversalTime()
    $milliseconds = $utcTime.Millisecond.ToString("000")
    $timestamp = $utcTime.ToString("yyyy-MM-ddTHH:mm:ss") + ".${milliseconds}Z"

    # Get machine name - handle both Windows and Unix
    $machineName = if ($env:COMPUTERNAME) {
        $env:COMPUTERNAME
    }
    elseif ($env:HOSTNAME) {
        $env:HOSTNAME
    }
    else {
        hostname
    }

    # Get user with domain - handle both Windows and Unix
    $userName = if ($env:USERDOMAIN) {
        "$env:USERDOMAIN\$env:USERNAME"
    }
    else {
        $env:USER
    }

    # Create SIEM event object with required fields
    $siemEvent = @{
        timestamp = $timestamp
        event = $EventType
        sessionId = $SessionId
        user = $userName
        machine = $machineName
        data = $Data
    }

    # Convert to JSON (single line) and write with mutex protection
    try {
        $jsonLine = $siemEvent | ConvertTo-Json -Compress -Depth 10

        # Ensure directory exists
        $siemDir = Split-Path -Path $siemPath -Parent
        if ($siemDir -and -not (Test-Path $siemDir)) {
            New-Item -ItemType Directory -Path $siemDir -Force | Out-Null
        }

        # Append to SIEM log (JSON Lines format) with mutex protection
        # Critical: JSONL corruption breaks SIEM ingestion, so mutex is essential
        Invoke-WithLogMutex -MutexSuffix 'SIEM' -ScriptBlock {
            Add-Content -Path $siemPath -Value $jsonLine -Encoding UTF8
        }.GetNewClosure()
    }
    catch {
        Write-Warning "Failed to write to SIEM log: $_"
    }
}

function Invoke-LogRotation {
    <#
    .SYNOPSIS
        Compresses old logs and deletes ancient ones
    .PARAMETER LogRoot
        Root directory for logs
    .PARAMETER CompressAfterDays
        Compress logs older than this (default: 7)
    .PARAMETER DeleteAfterDays
        Delete logs older than this (default: 30)
    .PARAMETER TimeoutSeconds
        Max time to spend on each compression operation (default: 60)
        Prevents hanging on locked files or unresponsive network shares
    #>
    [CmdletBinding()]
    param(
        [string]$LogRoot = ".\Logs",
        [ValidateRange(1, 365)]
        [int]$CompressAfterDays = $script:LogCompressAfterDays,
        [ValidateRange(1, 3650)]
        [int]$DeleteAfterDays = $script:LogDeleteAfterDays,
        [ValidateRange(5, 300)]
        [int]$TimeoutSeconds = 60
    )

    if (-not (Test-Path $LogRoot)) {
        Write-Verbose "Log root directory does not exist: $LogRoot"
        return
    }

    # Validate that CompressAfterDays is less than DeleteAfterDays
    if ($CompressAfterDays -ge $DeleteAfterDays) {
        Write-Warning "CompressAfterDays ($CompressAfterDays) should be less than DeleteAfterDays ($DeleteAfterDays). Adjusting CompressAfterDays to $([Math]::Max(1, $DeleteAfterDays - 7))."
        $CompressAfterDays = [Math]::Max(1, $DeleteAfterDays - 7)
    }

    $now = Get-Date
    $compressThreshold = $now.AddDays(-$CompressAfterDays)
    $deleteThreshold = $now.AddDays(-$DeleteAfterDays)

    try {
        # Get all date-based directories (yyyy-MM-dd format)
        $logDirectories = Get-ChildItem -Path $LogRoot -Directory | Where-Object {
            $_.Name -match '^\d{4}-\d{2}-\d{2}$'
        }

        foreach ($dir in $logDirectories) {
            try {
                # Parse directory date
                $dirDate = [DateTime]::ParseExact($dir.Name, "yyyy-MM-dd", $null)

                # Skip if this is today's directory or yesterday's (may still be in use)
                # Compare date parts only - AddDays(-1) is clearer than AddHours(-2) for "yesterday"
                if ($dirDate.Date -ge $now.Date.AddDays(-1)) {
                    continue
                }

                # Compress old directories
                if ($dirDate -lt $compressThreshold) {
                    $zipPath = Join-Path $LogRoot "$($dir.Name).zip"

                    # Skip if already compressed
                    if (Test-Path $zipPath) {
                        # Remove the directory after successful compression
                        if (Test-Path $dir.FullName) {
                            Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction Stop
                        }
                        continue
                    }

                    # Compress the directory with timeout to prevent hanging on locked files
                    $compressionJob = Start-Job -ScriptBlock {
                        param($SourcePath, $DestPath)
                        Compress-Archive -Path $SourcePath -DestinationPath $DestPath -Force -ErrorAction Stop
                    } -ArgumentList $dir.FullName, $zipPath

                    $completed = $compressionJob | Wait-Job -Timeout $TimeoutSeconds
                    if (-not $completed) {
                        Write-Warning "Compression timeout for $($dir.Name) after $TimeoutSeconds seconds - skipping (file may be locked)"
                        $compressionJob | Stop-Job -PassThru | Remove-Job -Force
                        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
                        continue
                    }

                    # Check for job errors
                    if ($compressionJob.State -eq 'Failed') {
                        $jobError = $compressionJob | Receive-Job -ErrorAction SilentlyContinue 2>&1
                        Write-Warning "Compression failed for $($dir.Name): $jobError"
                        $compressionJob | Remove-Job -Force
                        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
                        continue
                    }
                    $compressionJob | Remove-Job -Force

                    # Verify the archive was created successfully and has content
                    if (-not (Test-Path $zipPath)) {
                        Write-Warning "Failed to verify compressed archive: $zipPath"
                        continue
                    }
                    $archiveInfo = Get-Item -Path $zipPath -ErrorAction SilentlyContinue
                    if ($null -eq $archiveInfo -or $archiveInfo.Length -eq 0) {
                        Write-Warning "Compressed archive is empty or invalid, keeping original: $zipPath"
                        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
                        continue
                    }

                    # Remove the original directory only after verifying compression succeeded
                    Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction Stop

                    Write-Verbose "Compressed log directory: $($dir.Name)"
                }
            }
            catch {
                Write-Warning "Failed to compress log directory $($dir.Name): $_"
            }
        }

        # Delete ancient archives
        $archives = Get-ChildItem -Path $LogRoot -Filter "*.zip" | Where-Object {
            $_.Name -match '^\d{4}-\d{2}-\d{2}\.zip$'
        }

        foreach ($archive in $archives) {
            try {
                # Parse archive date from filename
                $archiveDateStr = $archive.BaseName
                $archiveDate = [DateTime]::ParseExact($archiveDateStr, "yyyy-MM-dd", $null)

                # Delete if older than threshold
                if ($archiveDate -lt $deleteThreshold) {
                    Remove-Item -Path $archive.FullName -Force -ErrorAction Stop
                    Write-Verbose "Deleted old archive: $($archive.Name)"
                }
            }
            catch {
                Write-Warning "Failed to delete archive $($archive.Name): $_"
            }
        }
    }
    catch {
        Write-Warning "Log rotation failed: $_"
    }
}

function Get-LogPath {
    <#
    .SYNOPSIS
        Gets path for a specific log type
    .PARAMETER Type
        Log type: Operational, Siem, ChunkJob
    .PARAMETER ChunkId
        Required for ChunkJob type
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Operational', 'Siem', 'ChunkJob')]
        [string]$Type,

        [int]$ChunkId
    )

    switch ($Type) {
        'Operational' {
            return $script:CurrentOperationalLogPath
        }
        'Siem' {
            return $script:CurrentSiemLogPath
        }
        'ChunkJob' {
            if ($null -eq $ChunkId) {
                throw "ChunkId parameter is required for ChunkJob type"
            }
            if (-not $script:CurrentJobsPath) {
                throw "No log session initialized. Call Initialize-LogSession first."
            }
            $chunkIdFormatted = $ChunkId.ToString("000")
            return Join-Path $script:CurrentJobsPath "Chunk_${chunkIdFormatted}.log"
        }
    }
}
