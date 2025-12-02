# Robocurse Logging Functions
# Script-scoped variables for current session state
$script:CurrentSessionId = $null
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
    param(
        [string]$LogRoot = ".\Logs",
        [int]$CompressAfterDays = $script:LogCompressAfterDays,
        [int]$DeleteAfterDays = $script:LogDeleteAfterDays
    )

    # Generate unique session ID based on timestamp
    $timestamp = Get-Date -Format "HHmmss"
    $milliseconds = (Get-Date).Millisecond
    $sessionId = "${timestamp}_${milliseconds}"

    # Create date-based directory structure
    $dateFolder = Get-Date -Format "yyyy-MM-dd"
    $logDirectory = Join-Path $LogRoot $dateFolder

    # Create the directory and Jobs subdirectory
    if (-not (Test-Path $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }

    $jobsDirectory = Join-Path $logDirectory "Jobs"
    if (-not (Test-Path $jobsDirectory)) {
        New-Item -ItemType Directory -Path $jobsDirectory -Force | Out-Null
    }

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

    # Write to operational log
    try {
        # Ensure directory exists
        $logDir = Split-Path -Path $logPath -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        # Append to log file
        Add-Content -Path $logPath -Value $logEntry -Encoding UTF8
    }
    catch {
        Write-Warning "Failed to write to operational log: $_"
    }

    # Write to SIEM if requested
    if ($WriteSiem) {
        $eventType = if ($Level -eq 'Error') { 'ChunkError' } else { 'SessionStart' }
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

    # Convert to JSON (single line)
    try {
        $jsonLine = $siemEvent | ConvertTo-Json -Compress -Depth 10

        # Ensure directory exists
        $siemDir = Split-Path -Path $siemPath -Parent
        if ($siemDir -and -not (Test-Path $siemDir)) {
            New-Item -ItemType Directory -Path $siemDir -Force | Out-Null
        }

        # Append to SIEM log (JSON Lines format)
        Add-Content -Path $siemPath -Value $jsonLine -Encoding UTF8
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
    #>
    param(
        [string]$LogRoot = ".\Logs",
        [int]$CompressAfterDays = $script:LogCompressAfterDays,
        [int]$DeleteAfterDays = $script:LogDeleteAfterDays
    )

    if (-not (Test-Path $LogRoot)) {
        Write-Verbose "Log root directory does not exist: $LogRoot"
        return
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

                # Skip if this is today's directory (currently in use)
                if ($dirDate.Date -eq $now.Date) {
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

                    # Compress the directory
                    Compress-Archive -Path $dir.FullName -DestinationPath $zipPath -Force -ErrorAction Stop

                    # Remove the original directory after successful compression
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
