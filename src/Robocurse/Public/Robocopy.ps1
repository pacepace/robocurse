# Robocurse Robocopy wrapper Functions
# Script-level bandwidth limit (set from config during replication start)
$script:BandwidthLimitMbps = 0

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

        [switch]$DryRun,

        # If false (default), adds /NFL /NDL to suppress per-file logging for smaller log files
        [switch]$VerboseFileLogging
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
    $argList.Add("/R:$retryCount")
    $argList.Add("/W:$retryWait")
    $argList.Add("/LOG:$(Format-QuotedPath -Path $safeLogPath)")
    $argList.Add("/TEE")
    $argList.Add("/NP")

    # Suppress per-file logging unless verbose mode is enabled
    # /NFL = No File List, /NDL = No Directory List
    if (-not $VerboseFileLogging) {
        $argList.Add("/NFL")
        $argList.Add("/NDL")
    }
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

        [switch]$DryRun,

        # If true, log every file copied; if false (default), only log summary
        [switch]$VerboseFileLogging
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
        -DryRun:$DryRun `
        -VerboseFileLogging:$VerboseFileLogging

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
    $psi.RedirectStandardOutput = $false  # Using /LOG and /TEE instead
    # Note: Not redirecting stderr - robocopy rarely writes to stderr,
    # and redirecting without reading can cause deadlock on large error output.
    # Robocopy errors are captured in the log file via /LOG and exit codes.
    $psi.RedirectStandardError = $false

    Write-RobocurseLog -Message "Robocopy args: $($argList -join ' ')" -Level 'Debug' -Component 'Robocopy'
    Write-Host "[ROBOCOPY CMD] $($psi.FileName) $($psi.Arguments)"

    # Start the process
    $process = [System.Diagnostics.Process]::Start($psi)

    return [PSCustomObject]@{
        Process = $process
        Chunk = $Chunk
        StartTime = [datetime]::Now
        LogPath = $LogPath
        DryRun = $DryRun.IsPresent
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
        # Exit code 8: Some files couldn't be copied - this is an error condition
        # Robocopy already retried per-file with /R:n so chunk-level retry may help
        # for transient issues (file locks released, network recovered, etc.)
        $result.Severity = "Error"
        $result.Message = "Some files could not be copied"
        $result.ShouldRetry = $true
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
        Parses a robocopy log file for progress and statistics
    .PARAMETER LogPath
        Path to log file
    .PARAMETER TailLines
        Number of lines to read from end (for in-progress parsing)
    .OUTPUTS
        PSCustomObject with file counts, byte counts, speed, and current file
    .NOTES
        Handles file locking by using FileShare.ReadWrite when robocopy has the file open
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogPath,

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

    # Check if log file exists
    if (-not (Test-Path $LogPath)) {
        $result.ParseWarning = "Log file does not exist: $LogPath"
        return $result
    }

    # Read log file with ReadWrite sharing to handle file locking
    # Use try-finally to ensure proper disposal even if ReadToEnd() throws
    $fs = $null
    $sr = $null
    try {
        $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)
        $content = $sr.ReadToEnd()
    }
    catch {
        # If we can't read the file, log the warning and return zeros
        $result.ParseWarning = "Failed to read log file: $($_.Exception.Message)"
        Write-RobocurseLog "Failed to read robocopy log file '$LogPath': $_" -Level 'Warning' -Component 'Robocopy'
        return $result
    }
    finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
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
        $lines = $content -split "`n"

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

        # Parse Speed line - look for numeric pattern followed by common speed units
        # Robocopy outputs speed in format like "50.123 MegaBytes/min" or "2621440 Bytes/sec"
        # The unit names may be localized but the numeric pattern is consistent
        if ($content -match '([\d.]+)\s+(Mega)?Bytes[/\s]*(min|sec)') {
            $speedValue = $matches[1]
            $isMega = $matches[2] -eq 'Mega'
            $timeUnit = $matches[3]
            $result.Speed = if ($isMega) { "$speedValue MB/$timeUnit" } else { "$speedValue B/$timeUnit" }
        }

        # Parse current file from progress lines (locale-independent)
        # Robocopy progress lines have: indicator (may contain spaces), size, path
        # Format: "  New File  1024  path\file.txt" or "  *EXTRA File  100  path\file.txt"
        # Key insight: look for a number followed by a backslash path
        $progressMatches = [regex]::Matches($content, '([\d.]+)\s*[kmgt]?\s+(\S*[\\\/].+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
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
        if ($content -and $content.Length -gt 100) {
            if (-not $result.ParseWarning) {
                $result.ParseWarning = "No statistics found in log file (job may be in progress or log format unexpected)"
            }
            Write-RobocurseLog "Could not extract statistics from robocopy log '$LogPath' ($($content.Length) bytes) - job may still be in progress" `
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
    if ($content) {
        $errorLines = @()
        $lines = $content -split "`r?`n"
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
    .PARAMETER Job
        Job object from Start-RobocopyJob
    .OUTPUTS
        PSCustomObject with CurrentFile, BytesCopied, FilesCopied, etc.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Job
    )

    # Use ConvertFrom-RobocopyLog with tail parsing to get current status
    return ConvertFrom-RobocopyLog -LogPath $Job.LogPath -TailLines 100
}

function Wait-RobocopyJob {
    <#
    .SYNOPSIS
        Waits for a robocopy job to complete
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

        # Parse final statistics from log
        $finalStats = ConvertFrom-RobocopyLog -LogPath $Job.LogPath

        return [PSCustomObject]@{
            ExitCode = $exitCode
            ExitMeaning = $exitMeaning
            Duration = $duration
            Stats = $finalStats
        }
    }
    finally {
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
