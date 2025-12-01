#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Robocurse - Multi-share parallel robocopy orchestrator
.DESCRIPTION
    Manages multiple robocopy instances to replicate large directory
    structures that would otherwise overwhelm a single robocopy process.
.PARAMETER Headless
    Run in headless mode without GUI
.PARAMETER ConfigPath
    Path to the configuration file (default: .\Robocurse.config.json)
.PARAMETER Profile
    Specify a profile name from the configuration file
.PARAMETER Help
    Display help information
.EXAMPLE
    .\Robocurse.ps1
    Launches the GUI interface
.EXAMPLE
    .\Robocurse.ps1 -Headless -ConfigPath ".\custom.config.json" -Profile "DailyBackup"
    Runs in headless mode with a custom config and profile
#>

param(
    [switch]$Headless,
    [string]$ConfigPath = ".\Robocurse.config.json",
    [string]$Profile,
    [switch]$Help
)

#region ==================== CONFIGURATION ====================

function New-DefaultConfig {
    <#
    .SYNOPSIS
        Creates a new configuration with sensible defaults
    .DESCRIPTION
        Returns a PSCustomObject with the default Robocurse configuration structure
    .OUTPUTS
        PSCustomObject with default configuration
    .EXAMPLE
        $config = New-DefaultConfig
        Creates a new default configuration object
    #>

    $config = [PSCustomObject]@{
        Version = "1.0"
        GlobalSettings = [PSCustomObject]@{
            MaxConcurrentJobs = 4
            ThreadsPerJob = 8
            DefaultScanMode = "Smart"
            LogRetentionDays = 30
            LogPath = ".\Logs"
        }
        Email = [PSCustomObject]@{
            Enabled = $false
            SmtpServer = ""
            Port = 587
            UseTls = $true
            CredentialTarget = "Robocurse-SMTP"
            From = ""
            To = @()
        }
        Schedule = [PSCustomObject]@{
            Enabled = $false
            Time = "02:00"
            Days = @("Daily")
        }
        SyncProfiles = @()
    }

    # Ensure arrays are not null by explicitly setting them if needed
    if ($null -eq $config.Email.To) {
        $config.Email.To = @()
    }
    if ($null -eq $config.SyncProfiles) {
        $config.SyncProfiles = @()
    }

    return $config
}

function Get-RobocurseConfig {
    <#
    .SYNOPSIS
        Loads configuration from JSON file
    .DESCRIPTION
        Loads and parses the Robocurse configuration from a JSON file.
        If the file doesn't exist, returns a default configuration.
        Handles malformed JSON gracefully by returning default config with a warning.
    .PARAMETER Path
        Path to the configuration JSON file. Defaults to .\Robocurse.config.json
    .OUTPUTS
        PSCustomObject with configuration
    .EXAMPLE
        $config = Get-RobocurseConfig
        Loads configuration from default path
    .EXAMPLE
        $config = Get-RobocurseConfig -Path "C:\Configs\custom.json"
        Loads configuration from custom path
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = ".\Robocurse.config.json"
    )

    # Return default config if file doesn't exist
    if (-not (Test-Path -Path $Path)) {
        Write-Verbose "Configuration file not found at '$Path'. Returning default configuration."
        return New-DefaultConfig
    }

    # Try to load and parse the JSON file
    try {
        $jsonContent = Get-Content -Path $Path -Raw -ErrorAction Stop
        $config = $jsonContent | ConvertFrom-Json -Depth 10 -ErrorAction Stop
        Write-Verbose "Configuration loaded successfully from '$Path'"
        return $config
    }
    catch {
        Write-Warning "Failed to load configuration from '$Path': $($_.Exception.Message)"
        Write-Warning "Returning default configuration."
        return New-DefaultConfig
    }
}

function Save-RobocurseConfig {
    <#
    .SYNOPSIS
        Saves configuration to a JSON file
    .DESCRIPTION
        Saves the configuration object to a JSON file with pretty formatting.
        Creates the parent directory if it doesn't exist.
    .PARAMETER Config
        Configuration object to save (PSCustomObject)
    .PARAMETER Path
        Path to save the configuration file. Defaults to .\Robocurse.config.json
    .OUTPUTS
        Boolean - $true on success, $false on failure
    .EXAMPLE
        $config = New-DefaultConfig
        Save-RobocurseConfig -Config $config
        Saves configuration to default path
    .EXAMPLE
        Save-RobocurseConfig -Config $config -Path "C:\Configs\custom.json"
        Saves configuration to custom path
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $false)]
        [string]$Path = ".\Robocurse.config.json"
    )

    try {
        # Get the parent directory
        $parentDir = Split-Path -Path $Path -Parent

        # Create parent directory if it doesn't exist
        if ($parentDir -and -not (Test-Path -Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction Stop | Out-Null
            Write-Verbose "Created directory: $parentDir"
        }

        # Convert to JSON and save
        $jsonContent = $Config | ConvertTo-Json -Depth 10
        $jsonContent | Set-Content -Path $Path -Encoding UTF8 -ErrorAction Stop

        Write-Verbose "Configuration saved successfully to '$Path'"
        return $true
    }
    catch {
        Write-Warning "Failed to save configuration to '$Path': $($_.Exception.Message)"
        return $false
    }
}

function Test-RobocurseConfig {
    <#
    .SYNOPSIS
        Validates a configuration object
    .DESCRIPTION
        Validates that a configuration object has all required fields and valid values.
        Returns a result object with validation status and any errors found.
    .PARAMETER Config
        Configuration object to validate (PSCustomObject)
    .OUTPUTS
        PSCustomObject with IsValid (bool) and Errors (string[])
    .EXAMPLE
        $config = Get-RobocurseConfig
        $result = Test-RobocurseConfig -Config $config
        if (-not $result.IsValid) {
            $result.Errors | ForEach-Object { Write-Warning $_ }
        }
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config
    )

    $errors = @()

    # Get top-level property names safely
    $configPropertyNames = $Config.PSObject.Properties.Name
    if ($null -eq $configPropertyNames) {
        $configPropertyNames = @()
    }

    # Check for required top-level properties
    if (-not ($configPropertyNames -contains 'GlobalSettings')) {
        $errors += "Missing required property: GlobalSettings"
    }

    if (-not ($configPropertyNames -contains 'SyncProfiles')) {
        $errors += "Missing required property: SyncProfiles"
    }

    # Validate GlobalSettings if present
    if ($configPropertyNames -contains 'GlobalSettings') {
        $gs = $Config.GlobalSettings
        $gsPropertyNames = $gs.PSObject.Properties.Name
        if ($null -eq $gsPropertyNames) {
            $gsPropertyNames = @()
        }

        # Validate MaxConcurrentJobs
        if ($gsPropertyNames -contains 'MaxConcurrentJobs') {
            $maxJobs = $gs.MaxConcurrentJobs
            if ($maxJobs -lt 1 -or $maxJobs -gt 32) {
                $errors += "GlobalSettings.MaxConcurrentJobs must be between 1 and 32 (current: $maxJobs)"
            }
        }
    }

    # Validate Email configuration if enabled
    if (($configPropertyNames -contains 'Email') -and $Config.Email.Enabled -eq $true) {
        $email = $Config.Email

        if ([string]::IsNullOrWhiteSpace($email.SmtpServer)) {
            $errors += "Email.SmtpServer is required when Email.Enabled is true"
        }

        if ([string]::IsNullOrWhiteSpace($email.From)) {
            $errors += "Email.From is required when Email.Enabled is true"
        }

        if (-not $email.To -or $email.To.Count -eq 0) {
            $errors += "Email.To must contain at least one recipient when Email.Enabled is true"
        }
    }

    # Validate SyncProfiles
    if (($configPropertyNames -contains 'SyncProfiles') -and $Config.SyncProfiles) {
        for ($i = 0; $i -lt $Config.SyncProfiles.Count; $i++) {
            $profile = $Config.SyncProfiles[$i]
            $profilePrefix = "SyncProfiles[$i]"

            # Ensure profile is an object with properties
            if ($null -eq $profile -or $null -eq $profile.PSObject) {
                $errors += "$profilePrefix is not a valid profile object"
                continue
            }

            # Get property names safely
            $propertyNames = $profile.PSObject.Properties.Name
            if ($null -eq $propertyNames) {
                $propertyNames = @()
            }

            # Check required properties
            if (-not ($propertyNames -contains 'Name') -or [string]::IsNullOrWhiteSpace($profile.Name)) {
                $errors += "$profilePrefix is missing required property: Name"
            }

            if (-not ($propertyNames -contains 'Source') -or [string]::IsNullOrWhiteSpace($profile.Source)) {
                $errors += "$profilePrefix is missing required property: Source"
            }

            if (-not ($propertyNames -contains 'Destination') -or [string]::IsNullOrWhiteSpace($profile.Destination)) {
                $errors += "$profilePrefix is missing required property: Destination"
            }

            # Validate path formats (format check only, not existence)
            if (($propertyNames -contains 'Source') -and -not [string]::IsNullOrWhiteSpace($profile.Source)) {
                if (-not (Test-PathFormat -Path $profile.Source)) {
                    $errors += "$profilePrefix.Source has invalid path format: $($profile.Source)"
                }
            }

            if (($propertyNames -contains 'Destination') -and -not [string]::IsNullOrWhiteSpace($profile.Destination)) {
                if (-not (Test-PathFormat -Path $profile.Destination)) {
                    $errors += "$profilePrefix.Destination has invalid path format: $($profile.Destination)"
                }
            }
        }
    }

    # Return result
    return [PSCustomObject]@{
        IsValid = ($errors.Count -eq 0)
        Errors = $errors
    }
}

function Test-PathFormat {
    <#
    .SYNOPSIS
        Helper function to validate path format
    .PARAMETER Path
        Path to validate
    .OUTPUTS
        Boolean indicating if path format is valid
    #>
    param(
        [string]$Path
    )

    # Check for invalid characters that are not allowed in Windows paths
    # Valid paths can be: UNC (\\server\share) or local (C:\path or .\path)
    $invalidChars = [System.IO.Path]::GetInvalidPathChars() + @('|', '>', '<', '"', '?', '*')

    foreach ($char in $invalidChars) {
        if ($Path.Contains($char)) {
            return $false
        }
    }

    # Basic format validation for UNC or local paths
    # UNC: \\server\share or \\server\share\path
    # Local: C:\ or C:\path or .\ or .\path
    if ($Path -match '^\\\\[^\\]+\\[^\\]+' -or     # UNC path
        $Path -match '^[a-zA-Z]:\\' -or             # Absolute local path
        $Path -match '^\.\\' -or                    # Relative path
        $Path -match '^\.\.\\') {                   # Parent relative path
        return $true
    }

    return $false
}

#endregion

#region ==================== LOGGING ====================

# Script-scoped variables for current session state
$script:CurrentSessionId = $null
$script:CurrentOperationalLogPath = $null
$script:CurrentSiemLogPath = $null
$script:CurrentJobsPath = $null

function Initialize-LogSession {
    <#
    .SYNOPSIS
        Creates log directory for today, generates session ID, initializes log files
    .PARAMETER LogRoot
        Root directory for logs
    .OUTPUTS
        Hashtable with SessionId, OperationalLogPath, SiemLogPath
    #>
    param(
        [string]$LogRoot = ".\Logs"
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

    # Use current operational log path if available
    $logPath = $script:CurrentOperationalLogPath

    if (-not $logPath) {
        Write-Warning "No log session initialized. Call Initialize-LogSession first."
        return
    }

    # Format the log entry
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $levelUpper = $Level.ToUpper()
    $logEntry = "${timestamp} [${levelUpper}] [${Component}] ${Message}"

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
                     'ChunkStart', 'ChunkComplete', 'ChunkError', 'ConfigChange')]
        [string]$EventType,

        [hashtable]$Data = @{},

        [string]$SessionId = $script:CurrentSessionId
    )

    # Use current SIEM log path if available
    $siemPath = $script:CurrentSiemLogPath

    if (-not $siemPath) {
        Write-Warning "No log session initialized. Call Initialize-LogSession first."
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
        [int]$CompressAfterDays = 7,
        [int]$DeleteAfterDays = 30
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

#endregion

#region ==================== DIRECTORY PROFILING ====================

# Script-level cache for directory profiles
$script:ProfileCache = @{}

function Invoke-RobocopyList {
    <#
    .SYNOPSIS
        Runs robocopy in list-only mode (wrapper for testing/mocking)
    .PARAMETER Source
        Source path to list
    .OUTPUTS
        Array of output lines from robocopy
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Source
    )

    # Wrapper so we can mock this in tests
    $output = & robocopy $Source "\\?\NULL" /L /E /NJH /NJS /BYTES /R:0 /W:0 2>&1
    return $output
}

function Parse-RobocopyListOutput {
    <#
    .SYNOPSIS
        Parses robocopy /L output to extract file info
    .PARAMETER Output
        Array of robocopy output lines
    .OUTPUTS
        PSCustomObject with TotalSize, FileCount, DirCount, Files (array of file info)
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Output
    )

    $totalSize = 0
    $fileCount = 0
    $dirCount = 0
    $files = @()

    foreach ($line in $Output) {
        # Skip empty lines
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        # Lines starting with whitespace + number are files or directories
        # Format: "          123456789    path\to\file.txt"
        if ($line -match '^\s+(\d+)\s+(.+)$') {
            $size = [int64]$matches[1]
            $path = $matches[2].Trim()

            # Lines ending with \ are directories
            if ($path.EndsWith('\')) {
                $dirCount++
            }
            else {
                # This is a file
                $fileCount++
                $totalSize += $size

                $files += [PSCustomObject]@{
                    Path = $path
                    Size = $size
                }
            }
        }
    }

    return [PSCustomObject]@{
        TotalSize = $totalSize
        FileCount = $fileCount
        DirCount = $dirCount
        Files = $files
    }
}

function Get-DirectoryProfile {
    <#
    .SYNOPSIS
        Gets size and file count for a directory using robocopy /L
    .PARAMETER Path
        Directory path to profile
    .PARAMETER UseCache
        Check cache before scanning (default: true)
    .PARAMETER CacheMaxAgeHours
        Max cache age in hours (default: 24)
    .OUTPUTS
        PSCustomObject with: Path, TotalSize, FileCount, DirCount, AvgFileSize, LastScanned
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [bool]$UseCache = $true,

        [int]$CacheMaxAgeHours = 24
    )

    # Normalize path for cache lookup
    $normalizedPath = $Path.TrimEnd('\')

    # Check cache if enabled
    if ($UseCache) {
        $cached = Get-CachedProfile -Path $normalizedPath -MaxAgeHours $CacheMaxAgeHours
        if ($null -ne $cached) {
            Write-RobocurseLog "Using cached profile for: $Path" -Level Debug
            return $cached
        }
    }

    # Run robocopy list
    Write-RobocurseLog "Profiling directory: $Path" -Level Debug

    try {
        $output = Invoke-RobocopyList -Source $Path

        # Parse the output
        $parseResult = Parse-RobocopyListOutput -Output $output

        # Calculate average file size (handle division by zero)
        $avgFileSize = 0
        if ($parseResult.FileCount -gt 0) {
            $avgFileSize = [math]::Round($parseResult.TotalSize / $parseResult.FileCount, 0)
        }

        # Create profile object
        $profile = [PSCustomObject]@{
            Path = $normalizedPath
            TotalSize = $parseResult.TotalSize
            FileCount = $parseResult.FileCount
            DirCount = $parseResult.DirCount
            AvgFileSize = $avgFileSize
            LastScanned = Get-Date
        }

        # Store in cache
        Set-CachedProfile -Profile $profile

        return $profile
    }
    catch {
        Write-RobocurseLog "Error profiling directory '$Path': $_" -Level Warning

        # Return empty profile on error
        return [PSCustomObject]@{
            Path = $normalizedPath
            TotalSize = 0
            FileCount = 0
            DirCount = 0
            AvgFileSize = 0
            LastScanned = Get-Date
        }
    }
}

function Get-DirectoryChildren {
    <#
    .SYNOPSIS
        Gets immediate child directories of a path
    .PARAMETER Path
        Parent directory path
    .OUTPUTS
        Array of child directory paths
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $children = Get-ChildItem -Path $Path -Directory -ErrorAction Stop
        return $children | ForEach-Object { $_.FullName }
    }
    catch {
        Write-RobocurseLog "Error getting children of '$Path': $_" -Level Warning
        return @()
    }
}

function Get-CachedProfile {
    <#
    .SYNOPSIS
        Retrieves cached directory profile if valid
    .PARAMETER Path
        Directory path
    .PARAMETER MaxAgeHours
        Maximum cache age
    .OUTPUTS
        Cached profile or $null
    #>
    param(
        [string]$Path,
        [int]$MaxAgeHours = 24
    )

    # Check if path exists in cache
    if (-not $script:ProfileCache.ContainsKey($Path)) {
        return $null
    }

    $cachedProfile = $script:ProfileCache[$Path]

    # Check if cache is still valid
    $age = (Get-Date) - $cachedProfile.LastScanned
    if ($age.TotalHours -gt $MaxAgeHours) {
        Write-RobocurseLog "Cache expired for: $Path (age: $([math]::Round($age.TotalHours, 1))h)" -Level Debug
        return $null
    }

    return $cachedProfile
}

function Set-CachedProfile {
    <#
    .SYNOPSIS
        Stores directory profile in cache
    .PARAMETER Profile
        Profile object to cache
    #>
    param(
        [PSCustomObject]$Profile
    )

    $script:ProfileCache[$Profile.Path] = $Profile
    Write-RobocurseLog "Cached profile for: $($Profile.Path)" -Level Debug
}

#endregion

#region ==================== CHUNKING ====================

# Script-level counter for unique chunk IDs
$script:ChunkIdCounter = 0

function Get-DirectoryChunks {
    <#
    .SYNOPSIS
        Recursively splits a directory tree into manageable chunks
    .PARAMETER Path
        Root path to chunk
    .PARAMETER DestinationRoot
        Destination root (for building destination paths)
    .PARAMETER SourceRoot
        Source root that maps to DestinationRoot (defaults to Path if not specified)
    .PARAMETER MaxSizeBytes
        Maximum size per chunk (default: 10GB)
    .PARAMETER MaxFiles
        Maximum files per chunk (default: 50000)
    .PARAMETER MaxDepth
        Maximum recursion depth (default: 5)
    .PARAMETER MinSizeBytes
        Minimum size to create a chunk (default: 100MB)
    .PARAMETER CurrentDepth
        Current recursion depth (internal use)
    .OUTPUTS
        Array of chunk objects
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DestinationRoot,

        [string]$SourceRoot,

        [int64]$MaxSizeBytes = 10GB,
        [int]$MaxFiles = 50000,
        [int]$MaxDepth = 5,
        [int64]$MinSizeBytes = 100MB,
        [int]$CurrentDepth = 0
    )

    # Default SourceRoot to Path if not specified (for initial call)
    if ([string]::IsNullOrEmpty($SourceRoot)) {
        $SourceRoot = $Path
    }

    Write-RobocurseLog "Analyzing directory at depth $CurrentDepth : $Path" -Level Debug

    # Get profile for this directory
    $profile = Get-DirectoryProfile -Path $Path -UseCache $true

    # Check if this directory is small enough to be a chunk
    if ($profile.TotalSize -le $MaxSizeBytes -and $profile.FileCount -le $MaxFiles) {
        Write-RobocurseLog "Directory fits in single chunk: $Path (Size: $($profile.TotalSize), Files: $($profile.FileCount))" -Level Debug
        $destPath = Convert-ToDestinationPath -SourcePath $Path -SourceRoot $SourceRoot -DestRoot $DestinationRoot
        return @(New-Chunk -SourcePath $Path -DestinationPath $destPath -Profile $profile -IsFilesOnly $false)
    }

    # Check if we've hit max depth - must accept as chunk even if large
    if ($CurrentDepth -ge $MaxDepth) {
        Write-RobocurseLog "Directory exceeds thresholds but at max depth: $Path (Size: $($profile.TotalSize), Files: $($profile.FileCount))" -Level Warning
        $destPath = Convert-ToDestinationPath -SourcePath $Path -SourceRoot $SourceRoot -DestRoot $DestinationRoot
        return @(New-Chunk -SourcePath $Path -DestinationPath $destPath -Profile $profile -IsFilesOnly $false)
    }

    # Directory is too big - recurse into children
    $children = Get-DirectoryChildren -Path $Path

    if ($children.Count -eq 0) {
        # No subdirs but too many files - must accept as large chunk
        Write-RobocurseLog "No subdirectories to split, accepting large directory: $Path" -Level Warning
        $destPath = Convert-ToDestinationPath -SourcePath $Path -SourceRoot $SourceRoot -DestRoot $DestinationRoot
        return @(New-Chunk -SourcePath $Path -DestinationPath $destPath -Profile $profile -IsFilesOnly $false)
    }

    # Recurse into each child
    Write-RobocurseLog "Directory too large, recursing into $($children.Count) children: $Path" -Level Debug
    $chunks = @()
    foreach ($child in $children) {
        $childChunks = Get-DirectoryChunks `
            -Path $child `
            -DestinationRoot $DestinationRoot `
            -SourceRoot $SourceRoot `
            -MaxSizeBytes $MaxSizeBytes `
            -MaxFiles $MaxFiles `
            -MaxDepth $MaxDepth `
            -MinSizeBytes $MinSizeBytes `
            -CurrentDepth ($CurrentDepth + 1)

        $chunks += $childChunks
    }

    # Handle files at this level (not in any subdir)
    $filesAtLevel = Get-FilesAtLevel -Path $Path
    if ($filesAtLevel.Count -gt 0) {
        Write-RobocurseLog "Found $($filesAtLevel.Count) files at level: $Path" -Level Debug
        $destPath = Convert-ToDestinationPath -SourcePath $Path -SourceRoot $SourceRoot -DestRoot $DestinationRoot
        $chunks += New-FilesOnlyChunk -SourcePath $Path -DestinationPath $destPath
    }

    return $chunks
}

function Get-FilesAtLevel {
    <#
    .SYNOPSIS
        Gets files directly in a directory (not in subdirectories)
    .PARAMETER Path
        Directory path
    .OUTPUTS
        Array of file info objects
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $files = Get-ChildItem -Path $Path -File -ErrorAction Stop
        return $files
    }
    catch {
        Write-RobocurseLog "Error getting files at level '$Path': $_" -Level Warning
        return @()
    }
}

function New-Chunk {
    <#
    .SYNOPSIS
        Creates a chunk object
    .PARAMETER SourcePath
        Source directory path
    .PARAMETER DestinationPath
        Destination directory path
    .PARAMETER Profile
        Directory profile (size, file count)
    .PARAMETER IsFilesOnly
        Whether this chunk only copies files at one level
    .OUTPUTS
        Chunk object
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,

        [bool]$IsFilesOnly = $false
    )

    $script:ChunkIdCounter++

    $chunk = [PSCustomObject]@{
        ChunkId = $script:ChunkIdCounter
        SourcePath = $SourcePath
        DestinationPath = $DestinationPath
        EstimatedSize = $Profile.TotalSize
        EstimatedFiles = $Profile.FileCount
        Depth = 0  # Will be set by caller if needed
        IsFilesOnly = $IsFilesOnly
        Status = "Pending"
        RobocopyArgs = @()
    }

    Write-RobocurseLog "Created chunk #$($chunk.ChunkId): $SourcePath -> $DestinationPath (Size: $($chunk.EstimatedSize), Files: $($chunk.EstimatedFiles), FilesOnly: $IsFilesOnly)" -Level Debug

    return $chunk
}

function New-FilesOnlyChunk {
    <#
    .SYNOPSIS
        Creates a chunk that only copies files at a specific directory level
    .DESCRIPTION
        When a directory has both files and subdirectories, and the subdirs
        are being processed separately, we need a special chunk for just
        the files at that level. Uses robocopy /LEV:1 to copy only top level.
    .PARAMETER SourcePath
        Source directory path
    .PARAMETER DestinationPath
        Destination directory path
    .OUTPUTS
        Chunk object
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    # Create a minimal profile for files at this level
    # We don't need exact size since this is just for files at one level
    $filesAtLevel = Get-FilesAtLevel -Path $SourcePath
    $totalSize = ($filesAtLevel | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $totalSize) { $totalSize = 0 }

    $profile = [PSCustomObject]@{
        TotalSize = $totalSize
        FileCount = $filesAtLevel.Count
        DirCount = 0
        AvgFileSize = if ($filesAtLevel.Count -gt 0) { $totalSize / $filesAtLevel.Count } else { 0 }
        LastScanned = Get-Date
    }

    $chunk = New-Chunk -SourcePath $SourcePath -DestinationPath $DestinationPath -Profile $profile -IsFilesOnly $true

    # Add robocopy args to copy only files at this level
    $chunk.RobocopyArgs = @("/LEV:1")

    Write-RobocurseLog "Created files-only chunk #$($chunk.ChunkId): $SourcePath (Files: $($filesAtLevel.Count))" -Level Debug

    return $chunk
}

function Convert-ToDestinationPath {
    <#
    .SYNOPSIS
        Converts source path to destination path
    .PARAMETER SourcePath
        Full source path
    .PARAMETER SourceRoot
        Source root that maps to DestRoot
    .PARAMETER DestRoot
        Destination root
    .EXAMPLE
        Convert-ToDestinationPath -SourcePath "\\server\users$\john\docs" -SourceRoot "\\server\users$" -DestRoot "D:\Backup"
        # Returns: "D:\Backup\john\docs"
    .OUTPUTS
        String - destination path
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$DestRoot
    )

    # Normalize paths - remove trailing slashes for consistent comparison
    $normalizedSource = $SourcePath.TrimEnd('\', '/')
    $normalizedSourceRoot = $SourceRoot.TrimEnd('\', '/')
    $normalizedDestRoot = $DestRoot.TrimEnd('\', '/')

    # Check if SourcePath starts with SourceRoot
    if (-not $normalizedSource.StartsWith($normalizedSourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Write-RobocurseLog "SourcePath '$SourcePath' does not start with SourceRoot '$SourceRoot'" -Level Warning
        # If they don't match, just append source to dest
        return Join-Path $normalizedDestRoot (Split-Path $normalizedSource -Leaf)
    }

    # Get the relative path
    $relativePath = $normalizedSource.Substring($normalizedSourceRoot.Length).TrimStart('\', '/')

    # Build destination path
    if ([string]::IsNullOrEmpty($relativePath)) {
        # Source and SourceRoot are the same
        return $normalizedDestRoot
    }
    else {
        # Manually combine paths to avoid Join-Path validation issues on cross-platform testing
        $separator = if ($normalizedDestRoot.Contains('\')) { '\' } else { '/' }
        return "$normalizedDestRoot$separator$relativePath"
    }
}

#endregion

#region ==================== ROBOCOPY WRAPPER ====================

function Start-RobocopyJob {
    <#
    .SYNOPSIS
        Starts a robocopy process for a chunk
    .PARAMETER Chunk
        Chunk object with SourcePath, DestinationPath, RobocopyArgs
    .PARAMETER LogPath
        Path for robocopy log file
    .PARAMETER ThreadsPerJob
        Number of threads for robocopy (/MT:n)
    .OUTPUTS
        PSCustomObject with Process, Chunk, StartTime, LogPath
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Chunk,

        [Parameter(Mandatory)]
        [string]$LogPath,

        [int]$ThreadsPerJob = 8
    )

    # Build argument list with all required switches
    $argList = @(
        "`"$($Chunk.SourcePath)`"",
        "`"$($Chunk.DestinationPath)`"",
        "/MIR",
        "/COPY:DAT",
        "/DCOPY:T",
        "/MT:$ThreadsPerJob",
        "/R:3",
        "/W:10",
        "/LOG:`"$LogPath`"",
        "/TEE",
        "/NP",
        "/NDL",
        "/BYTES",
        "/256",
        "/XJD",
        "/XJF"
    )

    # Add chunk-specific arguments (like /LEV:1 for files-only chunks)
    if ($Chunk.RobocopyArgs) {
        $argList += $Chunk.RobocopyArgs
    }

    # Create process start info
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "robocopy.exe"
    $psi.Arguments = $argList -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $false  # Using /LOG and /TEE instead
    $psi.RedirectStandardError = $true

    # Start the process
    $process = [System.Diagnostics.Process]::Start($psi)

    return [PSCustomObject]@{
        Process = $process
        Chunk = $Chunk
        StartTime = [datetime]::Now
        LogPath = $LogPath
    }
}

function Get-RobocopyExitMeaning {
    <#
    .SYNOPSIS
        Interprets robocopy exit code using bitmask logic
    .PARAMETER ExitCode
        Robocopy exit code (bitmask)
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
    param(
        [Parameter(Mandatory)]
        [int]$ExitCode
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
        $result.ShouldRetry = $true  # Worth retrying once
    }
    elseif ($result.CopyErrors) {
        $result.Severity = "Error"
        $result.Message = "Some files could not be copied"
        $result.ShouldRetry = $true
    }
    elseif ($result.MismatchesFound) {
        $result.Severity = "Warning"
        $result.Message = "Mismatched files detected"
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

function Parse-RobocopyLog {
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
    param(
        [Parameter(Mandatory)]
        [string]$LogPath,

        [int]$TailLines = 100
    )

    # Initialize result with zero values
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
    }

    # Check if log file exists
    if (-not (Test-Path $LogPath)) {
        return $result
    }

    # Read log file with ReadWrite sharing to handle file locking
    try {
        $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)
        $content = $sr.ReadToEnd()
        $sr.Close()
        $fs.Close()
    }
    catch {
        # If we can't read the file, return zeros
        return $result
    }

    # Parse summary statistics using regex
    # Target format:
    #                Total    Copied   Skipped  Mismatch    FAILED    Extras
    #     Dirs :      100        10        90         0         0         0
    #    Files :     1000       500       500         0         5         0
    #    Bytes :   1.0 g   500.0 m   500.0 m         0    10.0 k         0

    # Parse Files line
    if ($content -match '\s+Files\s*:\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+\s+(\d+)') {
        $result.FilesCopied = [int]$matches[2]
        $result.FilesSkipped = [int]$matches[3]
        $result.FilesFailed = [int]$matches[4]
    }

    # Parse Dirs line
    if ($content -match '\s+Dirs\s*:\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+\s+(\d+)') {
        $result.DirsCopied = [int]$matches[2]
        $result.DirsSkipped = [int]$matches[3]
        $result.DirsFailed = [int]$matches[4]
    }

    # Parse Bytes line - extract number and convert units
    if ($content -match '\s+Bytes\s*:\s+[\d.]+\s+[kmgt]?\s+([\d.]+)\s+([kmgt]?)') {
        $byteValue = [double]$matches[1]
        $unit = $matches[2]

        switch ($unit) {
            'k' { $result.BytesCopied = [long]($byteValue * 1KB) }
            'm' { $result.BytesCopied = [long]($byteValue * 1MB) }
            'g' { $result.BytesCopied = [long]($byteValue * 1GB) }
            't' { $result.BytesCopied = [long]($byteValue * 1TB) }
            default { $result.BytesCopied = [long]$byteValue }
        }
    }

    # Parse Speed line (MegaBytes/min format)
    if ($content -match 'Speed\s*:\s*([\d.]+)\s+MegaBytes/min') {
        $result.Speed = "$($matches[1]) MB/min"
    }

    # Parse current file from progress lines (last occurrence)
    # Formats: "New File", "Newer", "*EXTRA File"
    $progressMatches = [regex]::Matches($content, '\s+(New File|Newer|\*EXTRA File)\s+[\d.]+\s+[kmgt]?\s+(.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($progressMatches.Count -gt 0) {
        $lastMatch = $progressMatches[$progressMatches.Count - 1]
        $result.CurrentFile = $lastMatch.Groups[2].Value.Trim()
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
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Job
    )

    # Use Parse-RobocopyLog with tail parsing to get current status
    return Parse-RobocopyLog -LogPath $Job.LogPath -TailLines 100
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
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Job,

        [int]$TimeoutSeconds = 0
    )

    # Wait for process to complete
    if ($TimeoutSeconds -gt 0) {
        $completed = $Job.Process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $completed) {
            $Job.Process.Kill()
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
    $finalStats = Parse-RobocopyLog -LogPath $Job.LogPath

    return [PSCustomObject]@{
        ExitCode = $exitCode
        ExitMeaning = $exitMeaning
        Duration = $duration
        Stats = $finalStats
    }
}

#endregion

#region ==================== ORCHESTRATION ====================

# Script-scoped orchestration state
$script:OrchestrationState = [PSCustomObject]@{
    SessionId        = ""
    CurrentProfile   = $null
    Phase            = "Idle"  # Idle, Scanning, Replicating, Complete, Stopped
    Profiles         = @()     # All profiles to process
    ProfileIndex     = 0       # Current profile index

    # Current profile state
    ChunkQueue       = [System.Collections.Generic.Queue[PSCustomObject]]::new()
    ActiveJobs       = [System.Collections.Generic.Dictionary[int,PSCustomObject]]::new()  # ProcessId -> Job
    CompletedChunks  = [System.Collections.Generic.List[PSCustomObject]]::new()
    FailedChunks     = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Statistics
    TotalChunks      = 0
    CompletedCount   = 0
    TotalBytes       = 0
    BytesComplete    = 0
    StartTime        = $null
    ProfileStartTime = $null

    # Control
    StopRequested    = $false
    PauseRequested   = $false
}

# Script-scoped callback handlers
$script:OnProgress = $null
$script:OnChunkComplete = $null
$script:OnProfileComplete = $null

function Initialize-OrchestrationState {
    <#
    .SYNOPSIS
        Resets orchestration state for a new run
    .DESCRIPTION
        Initializes or resets the orchestration state object
    #>

    $script:OrchestrationState = [PSCustomObject]@{
        SessionId        = [guid]::NewGuid().ToString()
        CurrentProfile   = $null
        Phase            = "Idle"
        Profiles         = @()
        ProfileIndex     = 0

        ChunkQueue       = [System.Collections.Generic.Queue[PSCustomObject]]::new()
        ActiveJobs       = [System.Collections.Generic.Dictionary[int,PSCustomObject]]::new()
        CompletedChunks  = [System.Collections.Generic.List[PSCustomObject]]::new()
        FailedChunks     = [System.Collections.Generic.List[PSCustomObject]]::new()

        TotalChunks      = 0
        CompletedCount   = 0
        TotalBytes       = 0
        BytesComplete    = 0
        StartTime        = $null
        ProfileStartTime = $null

        StopRequested    = $false
        PauseRequested   = $false
    }

    Write-RobocurseLog -Message "Orchestration state initialized: $($script:OrchestrationState.SessionId)" `
        -Level 'Info' -Component 'Orchestrator'
}

function Start-ReplicationRun {
    <#
    .SYNOPSIS
        Starts replication for specified profiles
    .PARAMETER Profiles
        Array of profile objects from config
    .PARAMETER MaxConcurrentJobs
        Maximum parallel robocopy processes
    .PARAMETER OnProgress
        Scriptblock called on progress updates
    .PARAMETER OnChunkComplete
        Scriptblock called when chunk finishes
    .PARAMETER OnProfileComplete
        Scriptblock called when profile finishes
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject[]]$Profiles,

        [int]$MaxConcurrentJobs = 4,

        [scriptblock]$OnProgress,
        [scriptblock]$OnChunkComplete,
        [scriptblock]$OnProfileComplete
    )

    # Initialize state
    Initialize-OrchestrationState

    # Store callbacks
    $script:OnProgress = $OnProgress
    $script:OnChunkComplete = $OnChunkComplete
    $script:OnProfileComplete = $OnProfileComplete

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
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,

        [int]$MaxConcurrentJobs = 4
    )

    $state = $script:OrchestrationState
    $state.CurrentProfile = $Profile
    $state.ProfileStartTime = [datetime]::Now

    Write-RobocurseLog -Message "Starting profile: $($Profile.Name)" `
        -Level 'Info' -Component 'Orchestrator'

    Write-SiemEvent -EventType 'ProfileStart' -Data @{
        profileName = $Profile.Name
        source = $Profile.Source
        destination = $Profile.Destination
    }

    # TODO: In future tasks, add VSS snapshot creation here if UseVSS is enabled
    # For now, just scan and chunk

    # Scan source directory
    $state.Phase = "Scanning"
    $scanResult = Get-DirectoryProfile -Path $Profile.Source

    # Generate chunks based on scan mode
    $chunks = switch ($Profile.ScanMode) {
        'Flat' {
            New-FlatChunks -Profile $scanResult -MaxChunkSizeMB $Profile.MaxChunkSizeMB
        }
        'Smart' {
            New-SmartChunks -Profile $scanResult -MaxChunkSizeMB $Profile.MaxChunkSizeMB
        }
        default {
            New-SmartChunks -Profile $scanResult -MaxChunkSizeMB $Profile.MaxChunkSizeMB
        }
    }

    # Update chunks with destination paths
    foreach ($chunk in $chunks) {
        # Map source path to destination
        $relativePath = $chunk.SourcePath.Substring($Profile.Source.Length).TrimStart('\', '/')
        $chunk | Add-Member -MemberType NoteProperty -Name 'DestinationPath' -Value (Join-Path $Profile.Destination $relativePath) -Force
        $chunk | Add-Member -MemberType NoteProperty -Name 'Status' -Value 'Pending' -Force
        $chunk | Add-Member -MemberType NoteProperty -Name 'RetryCount' -Value 0 -Force
    }

    # Initialize queue
    $state.ChunkQueue.Clear()
    foreach ($chunk in $chunks) {
        $state.ChunkQueue.Enqueue($chunk)
    }

    $state.TotalChunks = $chunks.Count
    $state.TotalBytes = $scanResult.TotalSize
    $state.CompletedCount = 0
    $state.BytesComplete = 0
    $state.CompletedChunks.Clear()
    $state.FailedChunks.Clear()
    $state.Phase = "Replicating"

    Write-RobocurseLog -Message "Profile scan complete: $($chunks.Count) chunks, $([math]::Round($scanResult.TotalSize/1GB, 2)) GB" `
        -Level 'Info' -Component 'Orchestrator'
}

function Start-ChunkJob {
    <#
    .SYNOPSIS
        Starts a robocopy job for a chunk
    .PARAMETER Chunk
        Chunk object to replicate
    .OUTPUTS
        Job object from Start-RobocopyJob
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Chunk
    )

    # Get log path for this chunk
    $logPath = Get-LogPath -Type 'ChunkJob' -ChunkId $Chunk.ChunkId

    Write-RobocurseLog -Message "Starting chunk $($Chunk.ChunkId): $($Chunk.SourcePath)" `
        -Level 'Debug' -Component 'Orchestrator'

    Write-SiemEvent -EventType 'ChunkStart' -Data @{
        chunkId = $Chunk.ChunkId
        source = $Chunk.SourcePath
        destination = $Chunk.DestinationPath
        estimatedSize = $Chunk.EstimatedSize
    }

    # Start the robocopy job
    $job = Start-RobocopyJob -Chunk $Chunk -LogPath $logPath -ThreadsPerJob 8

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
    param(
        [int]$MaxConcurrentJobs = 4
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

    # Check completed jobs
    $completedIds = @()
    foreach ($kvp in $state.ActiveJobs.GetEnumerator()) {
        $job = $kvp.Value
        if ($job.Process.HasExited) {
            # Process completion
            $result = Complete-RobocopyJob -Job $job
            $completedIds += $kvp.Key

            if ($result.ExitMeaning.Severity -in @('Error', 'Fatal')) {
                Handle-FailedChunk -Job $job -Result $result
            }
            else {
                $state.CompletedChunks.Add($job.Chunk)
            }
            $state.CompletedCount++

            # Invoke callback
            if ($script:OnChunkComplete) {
                & $script:OnChunkComplete $job $result
            }
        }
    }

    # Remove completed from active
    foreach ($id in $completedIds) {
        $state.ActiveJobs.Remove($id)
    }

    # Start new jobs
    while (($state.ActiveJobs.Count -lt $MaxConcurrentJobs) -and
           ($state.ChunkQueue.Count -gt 0)) {
        $chunk = $state.ChunkQueue.Dequeue()
        $job = Start-ChunkJob -Chunk $chunk
        $state.ActiveJobs[$job.Process.Id] = $job
    }

    # Check if profile complete
    if (($state.ChunkQueue.Count -eq 0) -and ($state.ActiveJobs.Count -eq 0)) {
        Complete-CurrentProfile
    }

    # Update progress
    Update-ProgressStats

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
    param(
        [PSCustomObject]$Job
    )

    $exitCode = $Job.Process.ExitCode
    $exitMeaning = Get-RobocopyExitMeaning -ExitCode $exitCode
    $stats = Parse-RobocopyLog -LogPath $Job.LogPath
    $duration = [datetime]::Now - $Job.StartTime

    # Update chunk status
    $Job.Chunk.Status = switch ($exitMeaning.Severity) {
        'Success' { 'Complete' }
        'Warning' { 'CompleteWithWarnings' }
        'Error'   { 'Failed' }
        'Fatal'   { 'Failed' }
    }

    # Log result
    Write-RobocurseLog -Message "Chunk $($Job.Chunk.ChunkId) completed: $($exitMeaning.Message)" `
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

function Handle-FailedChunk {
    <#
    .SYNOPSIS
        Handles a failed chunk - retry or mark failed
    .PARAMETER Job
        Failed job
    .PARAMETER Result
        Result from Complete-RobocopyJob
    #>
    param(
        [PSCustomObject]$Job,
        [PSCustomObject]$Result
    )

    $chunk = $Job.Chunk

    # Check retry count
    if (-not $chunk.RetryCount) { $chunk.RetryCount = 0 }
    $chunk.RetryCount++

    if ($chunk.RetryCount -lt 3 -and $Result.ExitMeaning.ShouldRetry) {
        # Re-queue for retry
        Write-RobocurseLog -Message "Chunk $($chunk.ChunkId) failed, retrying ($($chunk.RetryCount)/3)" `
            -Level 'Warning' -Component 'Orchestrator'

        $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
    }
    else {
        # Mark as failed
        $chunk.Status = 'Failed'
        $script:OrchestrationState.FailedChunks.Add($chunk)

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
    #>
    $state = $script:OrchestrationState

    if ($null -eq $state.CurrentProfile) {
        return
    }

    $profileDuration = [datetime]::Now - $state.ProfileStartTime

    Write-RobocurseLog -Message "Profile complete: $($state.CurrentProfile.Name) in $($profileDuration.ToString('hh\:mm\:ss'))" `
        -Level 'Info' -Component 'Orchestrator'

    Write-SiemEvent -EventType 'ProfileComplete' -Data @{
        profileName = $state.CurrentProfile.Name
        chunksCompleted = $state.CompletedChunks.Count
        chunksFailed = $state.FailedChunks.Count
        durationMs = $profileDuration.TotalMilliseconds
    }

    # Invoke callback
    if ($script:OnProfileComplete) {
        & $script:OnProfileComplete $state.CurrentProfile
    }

    # Move to next profile
    $state.ProfileIndex++
    if ($state.ProfileIndex -lt $state.Profiles.Count) {
        Start-ProfileReplication -Profile $state.Profiles[$state.ProfileIndex]
    }
    else {
        # All profiles complete
        $state.Phase = "Complete"
        $totalDuration = [datetime]::Now - $state.StartTime

        Write-RobocurseLog -Message "All profiles complete in $($totalDuration.ToString('hh\:mm\:ss'))" `
            -Level 'Info' -Component 'Orchestrator'

        Write-SiemEvent -EventType 'SessionEnd' -Data @{
            profileCount = $state.Profiles.Count
            totalChunks = $state.CompletedCount
            failedChunks = $state.FailedChunks.Count
            durationMs = $totalDuration.TotalMilliseconds
        }
    }
}

function Stop-AllJobs {
    <#
    .SYNOPSIS
        Stops all running robocopy processes
    #>
    $state = $script:OrchestrationState

    Write-RobocurseLog -Message "Stopping all jobs ($($state.ActiveJobs.Count) active)" `
        -Level 'Warning' -Component 'Orchestrator'

    foreach ($job in $state.ActiveJobs.Values) {
        if (-not $job.Process.HasExited) {
            try {
                $job.Process.Kill()
                Write-RobocurseLog -Message "Killed chunk $($job.Chunk.ChunkId)" -Level 'Warning' -Component 'Orchestrator'
            }
            catch {
                Write-RobocurseLog -Message "Failed to kill chunk $($job.Chunk.ChunkId): $_" -Level 'Error' -Component 'Orchestrator'
            }
        }
    }

    $state.ActiveJobs.Clear()
    $state.Phase = "Stopped"

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
    $script:OrchestrationState.StopRequested = $true

    Write-RobocurseLog -Message "Stop requested" `
        -Level 'Info' -Component 'Orchestrator'
}

function Request-Pause {
    <#
    .SYNOPSIS
        Pauses job queue (running jobs continue, no new starts)
    #>
    $script:OrchestrationState.PauseRequested = $true

    Write-RobocurseLog -Message "Pause requested" `
        -Level 'Info' -Component 'Orchestrator'
}

function Request-Resume {
    <#
    .SYNOPSIS
        Resumes paused job queue
    #>
    $script:OrchestrationState.PauseRequested = $false

    Write-RobocurseLog -Message "Resume requested" `
        -Level 'Info' -Component 'Orchestrator'
}

#endregion

#region ==================== PROGRESS ====================

function Update-ProgressStats {
    <#
    .SYNOPSIS
        Updates progress statistics from active jobs
    #>
    $state = $script:OrchestrationState

    # Calculate bytes complete from completed chunks + in-progress
    $bytesFromCompleted = 0
    foreach ($chunk in $state.CompletedChunks) {
        if ($chunk.EstimatedSize) {
            $bytesFromCompleted += $chunk.EstimatedSize
        }
    }

    $bytesFromActive = 0
    foreach ($job in $state.ActiveJobs.Values) {
        $progress = Get-RobocopyProgress -Job $job
        if ($progress) {
            $bytesFromActive += $progress.BytesCopied
        }
    }

    $state.BytesComplete = $bytesFromCompleted + $bytesFromActive
}

function Get-OrchestrationStatus {
    <#
    .SYNOPSIS
        Returns current orchestration status for GUI
    .OUTPUTS
        PSCustomObject with all status info
    #>
    $state = $script:OrchestrationState

    $elapsed = if ($state.StartTime) {
        [datetime]::Now - $state.StartTime
    } else { [timespan]::Zero }

    $eta = Get-ETAEstimate

    $currentProfileName = if ($state.CurrentProfile) { $state.CurrentProfile.Name } else { "" }

    $profileProgress = if ($state.TotalChunks -gt 0) {
        [math]::Round(($state.CompletedCount / $state.TotalChunks) * 100, 1)
    } else { 0 }

    # Calculate overall progress across all profiles
    $totalProfileCount = if ($state.Profiles.Count -gt 0) { $state.Profiles.Count } else { 1 }
    $overallProgress = [math]::Round((($state.ProfileIndex + ($profileProgress / 100)) / $totalProfileCount) * 100, 1)

    return [PSCustomObject]@{
        Phase = $state.Phase
        CurrentProfile = $currentProfileName
        ProfileProgress = $profileProgress
        OverallProgress = $overallProgress
        ChunksComplete = $state.CompletedCount
        ChunksTotal = $state.TotalChunks
        ChunksFailed = $state.FailedChunks.Count
        BytesComplete = $state.BytesComplete
        BytesTotal = $state.TotalBytes
        Elapsed = $elapsed
        ETA = $eta
        ActiveJobs = $state.ActiveJobs.Count
        QueuedJobs = $state.ChunkQueue.Count
    }
}

function Get-ETAEstimate {
    <#
    .SYNOPSIS
        Estimates completion time based on current progress
    .OUTPUTS
        TimeSpan estimate or $null if cannot estimate
    #>
    $state = $script:OrchestrationState

    if (-not $state.StartTime -or $state.BytesComplete -eq 0 -or $state.TotalBytes -eq 0) {
        return $null
    }

    $elapsed = [datetime]::Now - $state.StartTime
    $bytesPerSecond = $state.BytesComplete / $elapsed.TotalSeconds

    if ($bytesPerSecond -le 0) {
        return $null
    }

    $bytesRemaining = $state.TotalBytes - $state.BytesComplete
    $secondsRemaining = $bytesRemaining / $bytesPerSecond

    return [timespan]::FromSeconds($secondsRemaining)
}

#endregion

#region ==================== VSS ====================

function Get-VolumeFromPath {
    <#
    .SYNOPSIS
        Extracts the volume from a path
    .DESCRIPTION
        Parses a path and returns the volume (e.g., "C:", "D:").
        Returns $null for UNC paths as VSS must be created on the file server.
    .PARAMETER Path
        Local path (C:\...) or UNC path (\\server\share\...)
    .OUTPUTS
        Volume string (C:, D:, etc.) or $null for UNC paths
    .EXAMPLE
        Get-VolumeFromPath -Path "C:\Users\John"
        Returns: "C:"
    .EXAMPLE
        Get-VolumeFromPath -Path "\\server\share\folder"
        Returns: $null
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Match drive letter (case-insensitive)
    if ($Path -match '^([A-Za-z]:)') {
        return $Matches[1].ToUpper()
    }
    elseif ($Path -match '^\\\\') {
        # UNC path - VSS must be created on the server
        Write-RobocurseLog -Message "UNC path detected: $Path. VSS not supported for remote paths." -Level 'Debug' -Component 'VSS'
        return $null
    }

    Write-RobocurseLog -Message "Unable to determine volume from path: $Path" -Level 'Warning' -Component 'VSS'
    return $null
}

function New-VssSnapshot {
    <#
    .SYNOPSIS
        Creates a VSS shadow copy of a volume
    .DESCRIPTION
        Creates a Volume Shadow Copy snapshot using WMI. The snapshot is created as
        "ClientAccessible" type which can be read by applications.
    .PARAMETER SourcePath
        Path on the volume to snapshot (used to determine volume)
    .OUTPUTS
        PSCustomObject with ShadowId, ShadowPath, SourceVolume, CreatedAt
    .EXAMPLE
        $snapshot = New-VssSnapshot -SourcePath "C:\Users"
        Returns object with shadow copy details
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath
    )

    try {
        # Determine volume from path
        $volume = Get-VolumeFromPath -Path $SourcePath
        if (-not $volume) {
            throw "Cannot create VSS snapshot: Unable to determine volume from path '$SourcePath'"
        }

        Write-RobocurseLog -Message "Creating VSS snapshot for volume $volume (from path: $SourcePath)" -Level 'Info' -Component 'VSS'

        # Create shadow copy via WMI
        # Note: Requires Administrator privileges
        $shadowClass = [wmiclass]"root\cimv2:Win32_ShadowCopy"
        $result = $shadowClass.Create("$volume\", "ClientAccessible")

        if ($result.ReturnValue -ne 0) {
            # Common error codes:
            # 0x8004230F - Insufficient storage space
            # 0x80042316 - VSS service not running
            # 0x80042302 - Volume not supported for shadow copies
            $errorCode = "0x{0:X8}" -f $result.ReturnValue
            throw "Failed to create shadow copy: Error $errorCode (ReturnValue: $($result.ReturnValue))"
        }

        # Get shadow copy details
        $shadowId = $result.ShadowID
        Write-RobocurseLog -Message "VSS snapshot created with ID: $shadowId" -Level 'Debug' -Component 'VSS'

        $shadow = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowId }
        if (-not $shadow) {
            throw "Shadow copy created but could not retrieve details for ID: $shadowId"
        }

        $snapshotInfo = [PSCustomObject]@{
            ShadowId     = $shadowId
            ShadowPath   = $shadow.DeviceObject  # Format: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyN
            SourceVolume = $volume
            CreatedAt    = [datetime]::Now
        }

        Write-RobocurseLog -Message "VSS snapshot ready. Shadow path: $($snapshotInfo.ShadowPath)" -Level 'Info' -Component 'VSS'

        return $snapshotInfo
    }
    catch {
        Write-RobocurseLog -Message "Failed to create VSS snapshot: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        throw
    }
}

function Remove-VssSnapshot {
    <#
    .SYNOPSIS
        Deletes a VSS shadow copy
    .DESCRIPTION
        Removes a shadow copy using WMI by its ShadowId. This frees up storage space
        used by the snapshot.
    .PARAMETER ShadowId
        ID of shadow copy to delete (GUID string)
    .EXAMPLE
        Remove-VssSnapshot -ShadowId "{12345678-1234-1234-1234-123456789012}"
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ShadowId
    )

    try {
        Write-RobocurseLog -Message "Attempting to delete VSS snapshot: $ShadowId" -Level 'Debug' -Component 'VSS'

        $shadow = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $ShadowId }
        if ($shadow) {
            $shadow.Delete() | Out-Null
            Write-RobocurseLog -Message "Deleted VSS snapshot: $ShadowId" -Level 'Info' -Component 'VSS'
        }
        else {
            Write-RobocurseLog -Message "VSS snapshot not found: $ShadowId (may have been already deleted)" -Level 'Warning' -Component 'VSS'
        }
    }
    catch {
        Write-RobocurseLog -Message "Error deleting VSS snapshot $ShadowId : $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        throw
    }
}

function Get-VssPath {
    <#
    .SYNOPSIS
        Converts a regular path to its VSS shadow copy equivalent
    .DESCRIPTION
        Translates a path from the original volume to the shadow copy volume.
        Example: C:\Users\John\Documents -> \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Users\John\Documents
    .PARAMETER OriginalPath
        Original path (e.g., C:\Users\John\Documents)
    .PARAMETER ShadowPath
        VSS shadow path (e.g., \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1)
    .PARAMETER SourceVolume
        Source volume (e.g., C:)
    .OUTPUTS
        Converted path pointing to shadow copy
    .EXAMPLE
        Get-VssPath -OriginalPath "C:\Users\John\Documents" `
                    -ShadowPath "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1" `
                    -SourceVolume "C:"
        Returns: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Users\John\Documents
    #>
    param(
        [Parameter(Mandatory)]
        [string]$OriginalPath,

        [Parameter(Mandatory)]
        [string]$ShadowPath,

        [Parameter(Mandatory)]
        [string]$SourceVolume
    )

    # Ensure SourceVolume ends with colon (C:)
    $volumePrefix = $SourceVolume.TrimEnd('\', '/')
    if (-not $volumePrefix.EndsWith(':')) {
        $volumePrefix += ':'
    }

    # Extract the relative path after the volume
    # C:\Users\John\Documents -> \Users\John\Documents
    $relativePath = $OriginalPath.Substring($volumePrefix.Length)

    # Remove leading backslash if present
    $relativePath = $relativePath.TrimStart('\', '/')

    # Combine shadow path with relative path
    # Use string concatenation instead of Join-Path for compatibility with \\?\ style paths
    $shadowPathNormalized = $ShadowPath.TrimEnd('\', '/')
    if ($relativePath) {
        $vssPath = "$shadowPathNormalized\$relativePath"
    }
    else {
        # Root directory case (e.g., C:\)
        $vssPath = $shadowPathNormalized
    }

    Write-RobocurseLog -Message "Translated path: $OriginalPath -> $vssPath" -Level 'Debug' -Component 'VSS'

    return $vssPath
}

function Test-VssSupported {
    <#
    .SYNOPSIS
        Tests if VSS is supported for a given path
    .DESCRIPTION
        Checks if Volume Shadow Copy can be used for a path. Returns $false for UNC paths
        (network shares) as they require VSS to be created on the file server. For local paths,
        tests WMI availability.
    .PARAMETER Path
        Path to test
    .OUTPUTS
        $true if VSS can be used, $false otherwise
    .EXAMPLE
        Test-VssSupported -Path "C:\Users"
        Returns: $true (if WMI is available)
    .EXAMPLE
        Test-VssSupported -Path "\\server\share"
        Returns: $false (UNC path)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        # Check if local path
        $volume = Get-VolumeFromPath -Path $Path
        if (-not $volume) {
            # UNC path - would need remote WMI (complex, not supported in v1.0)
            Write-RobocurseLog -Message "VSS not supported for path: $Path (UNC path)" -Level 'Debug' -Component 'VSS'
            return $false
        }

        # Check if WMI is available and we can access Win32_ShadowCopy class
        $shadowClass = Get-WmiObject -List Win32_ShadowCopy -ErrorAction Stop
        if ($shadowClass) {
            Write-RobocurseLog -Message "VSS is supported for path: $Path" -Level 'Debug' -Component 'VSS'
            return $true
        }
        else {
            Write-RobocurseLog -Message "VSS not supported: Win32_ShadowCopy class not available" -Level 'Warning' -Component 'VSS'
            return $false
        }
    }
    catch {
        Write-RobocurseLog -Message "VSS not supported for path: $Path. Error: $($_.Exception.Message)" -Level 'Debug' -Component 'VSS'
        return $false
    }
}

function Invoke-WithVssSnapshot {
    <#
    .SYNOPSIS
        Executes a scriptblock with VSS snapshot, cleaning up afterward
    .DESCRIPTION
        Creates a VSS snapshot, executes the provided scriptblock, and ensures cleanup
        even if the scriptblock throws an error. The scriptblock receives a -VssPath parameter
        with the translated shadow copy path.
    .PARAMETER SourcePath
        Path to snapshot
    .PARAMETER ScriptBlock
        Code to execute (receives $VssPath parameter)
    .EXAMPLE
        Invoke-WithVssSnapshot -SourcePath "C:\Users" -ScriptBlock {
            param($VssPath)
            # Copy files from $VssPath (snapshot)
            Copy-Item -Path "$VssPath\*" -Destination "D:\Backup" -Recurse
        }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $snapshot = $null
    try {
        Write-RobocurseLog -Message "Creating VSS snapshot for $SourcePath" -Level 'Info' -Component 'VSS'
        $snapshot = New-VssSnapshot -SourcePath $SourcePath

        $vssPath = Get-VssPath -OriginalPath $SourcePath `
            -ShadowPath $snapshot.ShadowPath `
            -SourceVolume $snapshot.SourceVolume

        Write-RobocurseLog -Message "VSS path: $vssPath" -Level 'Debug' -Component 'VSS'

        # Execute the scriptblock with the VSS path
        & $ScriptBlock -VssPath $vssPath
    }
    catch {
        Write-RobocurseLog -Message "Error during VSS snapshot operation: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        throw
    }
    finally {
        if ($snapshot) {
            Write-RobocurseLog -Message "Cleaning up VSS snapshot" -Level 'Info' -Component 'VSS'
            try {
                Remove-VssSnapshot -ShadowId $snapshot.ShadowId
            }
            catch {
                Write-RobocurseLog -Message "Failed to cleanup VSS snapshot: $($_.Exception.Message)" -Level 'Warning' -Component 'VSS'
            }
        }
    }
}

#endregion

#region ==================== EMAIL ====================

# Initialize Windows Credential Manager P/Invoke types (Windows only)
$script:CredentialManagerTypeAdded = $false

function Initialize-CredentialManager {
    <#
    .SYNOPSIS
        Initializes Windows Credential Manager P/Invoke types
    .DESCRIPTION
        Adds the necessary .NET types for interacting with Windows Credential Manager
        via P/Invoke to advapi32.dll. Only works on Windows platform.
    #>

    if ($script:CredentialManagerTypeAdded) {
        return
    }

    # Only attempt on Windows
    if (-not $IsWindows -and $null -ne $IsWindows) {
        return
    }

    try {
        $credManagerCode = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class CredentialManager {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool CredFree(IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredWrite(ref CREDENTIAL credential, int flags);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredDelete(string target, int type, int flags);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    public const int CRED_TYPE_GENERIC = 1;
    public const int CRED_PERSIST_LOCAL_MACHINE = 2;
}
"@

        Add-Type -TypeDefinition $credManagerCode -Language CSharp -ErrorAction Stop
        $script:CredentialManagerTypeAdded = $true
    }
    catch {
        # Type might already be added or platform doesn't support it
        Write-RobocurseLog -Message "Could not initialize Credential Manager: $($_.Exception.Message)" -Level 'Debug' -Component 'Email'
    }
}

function Get-SmtpCredential {
    <#
    .SYNOPSIS
        Retrieves SMTP credential from Windows Credential Manager
    .DESCRIPTION
        Uses P/Invoke to advapi32.dll CredRead to retrieve stored credentials.
        Falls back to environment variable-based storage for non-Windows platforms.
    .PARAMETER Target
        Credential target name (default: Robocurse-SMTP)
    .OUTPUTS
        PSCredential object or $null if not found
    .EXAMPLE
        $cred = Get-SmtpCredential
        $cred = Get-SmtpCredential -Target "CustomSMTP"
    #>
    param(
        [string]$Target = "Robocurse-SMTP"
    )

    # Fallback: Check for environment variable credentials (for testing/non-Windows)
    $envUser = [Environment]::GetEnvironmentVariable("ROBOCURSE_SMTP_USER")
    $envPass = [Environment]::GetEnvironmentVariable("ROBOCURSE_SMTP_PASS")
    if ($envUser -and $envPass) {
        try {
            $securePass = ConvertTo-SecureString -String $envPass -AsPlainText -Force
            return New-Object System.Management.Automation.PSCredential($envUser, $securePass)
        }
        catch {
            Write-RobocurseLog -Message "Failed to read credential from environment: $_" -Level 'Warning' -Component 'Email'
        }
    }

    # Try Windows Credential Manager (Windows only)
    if ($IsWindows -or $null -eq $IsWindows) {
        try {
            Initialize-CredentialManager

            if (-not $script:CredentialManagerTypeAdded) {
                return $null
            }

            $credPtr = [IntPtr]::Zero
            $success = [CredentialManager]::CredRead($Target, [CredentialManager]::CRED_TYPE_GENERIC, 0, [ref]$credPtr)

            if ($success -and $credPtr -ne [IntPtr]::Zero) {
                try {
                    $credential = [System.Runtime.InteropServices.Marshal]::PtrToStructure($credPtr, [type][CredentialManager+CREDENTIAL])

                    if ($credential.CredentialBlobSize -gt 0) {
                        $passwordBytes = New-Object byte[] $credential.CredentialBlobSize
                        [System.Runtime.InteropServices.Marshal]::Copy($credential.CredentialBlob, $passwordBytes, 0, $credential.CredentialBlobSize)
                        $password = [System.Text.Encoding]::Unicode.GetString($passwordBytes)
                        $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force

                        return New-Object System.Management.Automation.PSCredential($credential.UserName, $securePassword)
                    }
                }
                finally {
                    [void][CredentialManager]::CredFree($credPtr)
                }
            }
        }
        catch {
            Write-RobocurseLog -Message "Failed to read credential from Credential Manager: $_" -Level 'Debug' -Component 'Email'
        }
    }

    return $null
}

function Save-SmtpCredential {
    <#
    .SYNOPSIS
        Saves SMTP credential to Windows Credential Manager
    .DESCRIPTION
        Uses P/Invoke to advapi32.dll CredWrite to securely store credentials.
        Falls back to warning message on non-Windows platforms.
    .PARAMETER Target
        Credential target name (default: Robocurse-SMTP)
    .PARAMETER Credential
        PSCredential to save
    .EXAMPLE
        $cred = Get-Credential
        Save-SmtpCredential -Credential $cred
    #>
    param(
        [string]$Target = "Robocurse-SMTP",

        [Parameter(Mandatory)]
        [PSCredential]$Credential
    )

    # Check if running on non-Windows
    if (-not $IsWindows -and $null -ne $IsWindows) {
        Write-RobocurseLog -Message "Credential Manager not available on non-Windows platforms. Use environment variables ROBOCURSE_SMTP_USER and ROBOCURSE_SMTP_PASS instead." -Level 'Warning' -Component 'Email'
        return
    }

    try {
        Initialize-CredentialManager

        if (-not $script:CredentialManagerTypeAdded) {
            throw "Credential Manager types not available"
        }

        $username = $Credential.UserName
        $password = $Credential.GetNetworkCredential().Password
        $passwordBytes = [System.Text.Encoding]::Unicode.GetBytes($password)

        $credPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($passwordBytes.Length)
        try {
            [System.Runtime.InteropServices.Marshal]::Copy($passwordBytes, 0, $credPtr, $passwordBytes.Length)

            $cred = New-Object CredentialManager+CREDENTIAL
            $cred.Type = [CredentialManager]::CRED_TYPE_GENERIC
            $cred.TargetName = $Target
            $cred.UserName = $username
            $cred.CredentialBlob = $credPtr
            $cred.CredentialBlobSize = $passwordBytes.Length
            $cred.Persist = [CredentialManager]::CRED_PERSIST_LOCAL_MACHINE
            $cred.Comment = "Robocurse SMTP Credentials"

            $success = [CredentialManager]::CredWrite([ref]$cred, 0)

            if ($success) {
                Write-RobocurseLog -Message "Credential saved to Credential Manager: $Target" -Level 'Info' -Component 'Email'
            }
            else {
                throw "CredWrite failed with error: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
        }
        finally {
            if ($credPtr -ne [IntPtr]::Zero) {
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($credPtr)
            }
        }
    }
    catch {
        Write-RobocurseLog -Message "Failed to save credential: $_" -Level 'Error' -Component 'Email'
        throw
    }
}

function Remove-SmtpCredential {
    <#
    .SYNOPSIS
        Removes SMTP credential from Windows Credential Manager
    .DESCRIPTION
        Uses P/Invoke to advapi32.dll CredDelete to remove stored credentials.
    .PARAMETER Target
        Credential target name (default: Robocurse-SMTP)
    .EXAMPLE
        Remove-SmtpCredential
        Remove-SmtpCredential -Target "CustomSMTP"
    #>
    param(
        [string]$Target = "Robocurse-SMTP"
    )

    # Check if running on non-Windows
    if (-not $IsWindows -and $null -ne $IsWindows) {
        Write-RobocurseLog -Message "Credential Manager not available on non-Windows platforms." -Level 'Warning' -Component 'Email'
        return
    }

    try {
        Initialize-CredentialManager

        if (-not $script:CredentialManagerTypeAdded) {
            throw "Credential Manager types not available"
        }

        $success = [CredentialManager]::CredDelete($Target, [CredentialManager]::CRED_TYPE_GENERIC, 0)

        if ($success) {
            Write-RobocurseLog -Message "Credential removed from Credential Manager: $Target" -Level 'Info' -Component 'Email'
        }
        else {
            Write-RobocurseLog -Message "Credential not found or could not be deleted: $Target" -Level 'Warning' -Component 'Email'
        }
    }
    catch {
        Write-RobocurseLog -Message "Failed to remove credential: $_" -Level 'Error' -Component 'Email'
        throw
    }
}

function Test-SmtpCredential {
    <#
    .SYNOPSIS
        Tests if SMTP credential exists and is valid
    .DESCRIPTION
        Checks if credential can be retrieved from Windows Credential Manager.
    .PARAMETER Target
        Credential target name (default: Robocurse-SMTP)
    .OUTPUTS
        $true if credential exists, $false otherwise
    .EXAMPLE
        if (Test-SmtpCredential) {
            # Credential exists
        }
    #>
    param(
        [string]$Target = "Robocurse-SMTP"
    )

    $cred = Get-SmtpCredential -Target $Target
    return ($null -ne $cred)
}

function Format-FileSize {
    <#
    .SYNOPSIS
        Formats a byte count into a human-readable string
    .PARAMETER Bytes
        Number of bytes
    .OUTPUTS
        Formatted string (e.g., "1.5 GB")
    .EXAMPLE
        Format-FileSize -Bytes 1073741824
        # Returns "1.00 GB"
    #>
    param(
        [Parameter(Mandatory)]
        [int64]$Bytes
    )

    if ($Bytes -ge 1TB) {
        return "{0:N2} TB" -f ($Bytes / 1TB)
    }
    elseif ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }
    elseif ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }
    elseif ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }
    else {
        return "{0:N0} bytes" -f $Bytes
    }
}

function New-CompletionEmailBody {
    <#
    .SYNOPSIS
        Creates HTML email body from results
    .DESCRIPTION
        Generates a styled HTML email with replication results, including
        status-colored header, statistics grid, profile list, and errors.
    .PARAMETER Results
        Replication results object
    .PARAMETER Status
        Overall status: Success, Warning, Failed
    .OUTPUTS
        HTML string
    .EXAMPLE
        $html = New-CompletionEmailBody -Results $results -Status 'Success'
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Results,

        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Warning', 'Failed')]
        [string]$Status
    )

    $statusColor = switch ($Status) {
        'Success' { '#4CAF50' }  # Green
        'Warning' { '#FF9800' }  # Orange
        'Failed'  { '#F44336' }  # Red
    }

    # Format duration
    $durationStr = if ($Results.Duration) {
        $Results.Duration.ToString('hh\:mm\:ss')
    } else {
        "00:00:00"
    }

    # Format bytes copied
    $bytesCopiedStr = Format-FileSize -Bytes $Results.TotalBytesCopied

    # Format files copied
    $filesCopiedStr = $Results.TotalFilesCopied.ToString('N0')

    # Build profile list HTML
    $profilesHtml = ""
    if ($Results.Profiles -and $Results.Profiles.Count -gt 0) {
        foreach ($profile in $Results.Profiles) {
            $profileClass = switch ($profile.Status) {
                'Success' { 'profile-success' }
                'Warning' { 'profile-warning' }
                'Failed'  { 'profile-failed' }
                default   { 'profile-success' }
            }

            $profileBytesCopied = Format-FileSize -Bytes $profile.BytesCopied
            $profileFilesCopied = $profile.FilesCopied.ToString('N0')

            $profilesHtml += @"
                <div class="profile-item $profileClass">
                    <strong>$([System.Web.HttpUtility]::HtmlEncode($profile.Name))</strong><br>
                    Chunks: $($profile.ChunksComplete)/$($profile.ChunksTotal) |
                    Files: $profileFilesCopied |
                    Size: $profileBytesCopied
                </div>
"@
        }
    }
    else {
        $profilesHtml = @"
                <div class="profile-item profile-success">
                    <em>No profiles executed</em>
                </div>
"@
    }

    # Build errors list HTML
    $errorsHtml = ""
    if ($Results.Errors -and $Results.Errors.Count -gt 0) {
        $errorItems = ""
        $errorCount = [Math]::Min($Results.Errors.Count, 10)
        for ($i = 0; $i -lt $errorCount; $i++) {
            $encodedError = [System.Web.HttpUtility]::HtmlEncode($Results.Errors[$i])
            $errorItems += "                <li>$encodedError</li>`n"
        }

        $additionalErrors = ""
        if ($Results.Errors.Count -gt 10) {
            $additionalErrors = "            <p><em>... and $($Results.Errors.Count - 10) more errors. See logs for details.</em></p>`n"
        }

        $errorsHtml = @"
            <h3 style="color: #F44336;">Errors</h3>
            <ul>
$errorItems            </ul>
$additionalErrors
"@
    }

    # Get current date/time and computer name
    $completionTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $computerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { $env:HOSTNAME }

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }
        .container { max-width: 600px; margin: 0 auto; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .header { background: $statusColor; color: white; padding: 20px; }
        .header h1 { margin: 0; font-size: 24px; }
        .content { padding: 20px; }
        .stat-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; margin: 20px 0; }
        .stat-box { background: #f9f9f9; padding: 15px; border-radius: 4px; }
        .stat-label { font-size: 12px; color: #666; text-transform: uppercase; }
        .stat-value { font-size: 24px; font-weight: bold; color: #333; }
        .profile-list { margin: 20px 0; }
        .profile-item { padding: 10px; border-bottom: 1px solid #eee; }
        .profile-success { border-left: 3px solid #4CAF50; }
        .profile-warning { border-left: 3px solid #FF9800; }
        .profile-failed { border-left: 3px solid #F44336; }
        .footer { background: #f5f5f5; padding: 15px; text-align: center; font-size: 12px; color: #666; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Robocurse Replication $Status</h1>
        </div>
        <div class="content">
            <p>Replication completed at <strong>$completionTime</strong></p>

            <div class="stat-grid">
                <div class="stat-box">
                    <div class="stat-label">Duration</div>
                    <div class="stat-value">$durationStr</div>
                </div>
                <div class="stat-box">
                    <div class="stat-label">Data Copied</div>
                    <div class="stat-value">$bytesCopiedStr</div>
                </div>
                <div class="stat-box">
                    <div class="stat-label">Files Copied</div>
                    <div class="stat-value">$filesCopiedStr</div>
                </div>
                <div class="stat-box">
                    <div class="stat-label">Errors</div>
                    <div class="stat-value">$($Results.TotalErrors)</div>
                </div>
            </div>

            <h3>Profile Summary</h3>
            <div class="profile-list">
$profilesHtml
            </div>

$errorsHtml
        </div>
        <div class="footer">
            Generated by Robocurse | Machine: $computerName
        </div>
    </div>
</body>
</html>
"@

    return $html
}

function Send-CompletionEmail {
    <#
    .SYNOPSIS
        Sends completion notification email
    .DESCRIPTION
        Sends an HTML email with replication results. Checks if email is enabled,
        retrieves credentials, builds HTML body, and sends via SMTP with TLS.
        Errors are logged but do not throw exceptions.
    .PARAMETER Config
        Email configuration from Robocurse config
    .PARAMETER Results
        Replication results summary
    .PARAMETER Status
        Overall status: Success, Warning, Failed
    .EXAMPLE
        Send-CompletionEmail -Config $config.Email -Results $results -Status 'Success'
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory)]
        [PSCustomObject]$Results,

        [ValidateSet('Success', 'Warning', 'Failed')]
        [string]$Status = 'Success'
    )

    # Check if email is enabled
    if (-not $Config.Enabled) {
        Write-RobocurseLog -Message "Email notifications disabled" -Level 'Debug' -Component 'Email'
        return
    }

    # Validate required configuration
    if (-not $Config.SmtpServer -or -not $Config.From -or -not $Config.To -or $Config.To.Count -eq 0) {
        Write-RobocurseLog -Message "Email configuration incomplete (missing SmtpServer, From, or To)" -Level 'Warning' -Component 'Email'
        return
    }

    # Get credential
    $credential = Get-SmtpCredential -Target $Config.CredentialTarget
    if (-not $credential) {
        Write-RobocurseLog -Message "SMTP credential not found: $($Config.CredentialTarget)" -Level 'Error' -Component 'Email'
        return
    }

    # Build email
    $subject = "Robocurse: Replication $Status - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $body = New-CompletionEmailBody -Results $Results -Status $Status

    # Set priority based on status
    $priority = switch ($Status) {
        'Success' { 'Normal' }
        'Warning' { 'Normal' }
        'Failed'  { 'High' }
    }

    try {
        $mailParams = @{
            SmtpServer = $Config.SmtpServer
            Port = $Config.Port
            UseSsl = $Config.UseTls
            Credential = $credential
            From = $Config.From
            To = $Config.To
            Subject = $subject
            Body = $body
            BodyAsHtml = $true
            Priority = $priority
        }

        Send-MailMessage @mailParams

        Write-RobocurseLog -Message "Completion email sent to $($Config.To -join ', ')" -Level 'Info' -Component 'Email'
        Write-SiemEvent -EventType 'EmailSent' -Data @{ recipients = $Config.To; status = $Status }
    }
    catch {
        Write-RobocurseLog -Message "Failed to send email: $($_.Exception.Message)" -Level 'Error' -Component 'Email'
    }
}

function Test-EmailConfiguration {
    <#
    .SYNOPSIS
        Sends a test email to verify configuration
    .DESCRIPTION
        Sends a test email with dummy replication results to verify that
        SMTP settings and credentials are working correctly.
    .PARAMETER Config
        Email configuration
    .OUTPUTS
        $true if successful, error message string if failed
    .EXAMPLE
        $result = Test-EmailConfiguration -Config $config.Email
        if ($result -eq $true) { Write-Host "Email test passed" }
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    # Create test results
    $testResults = [PSCustomObject]@{
        Duration = [timespan]::FromMinutes(5)
        TotalBytesCopied = 1073741824  # 1 GB
        TotalFilesCopied = 1000
        TotalErrors = 0
        Profiles = @(
            [PSCustomObject]@{
                Name = "Test Profile"
                Status = "Success"
                ChunksComplete = 10
                ChunksTotal = 10
                FilesCopied = 1000
                BytesCopied = 1073741824
            }
        )
        Errors = @()
    }

    try {
        Send-CompletionEmail -Config $Config -Results $testResults -Status 'Success'
        return $true
    }
    catch {
        return "Failed: $($_.Exception.Message)"
    }
}

#endregion

#region ==================== SCHEDULING ====================

function Register-RobocurseTask {
    <#
    .SYNOPSIS
        Creates or updates a scheduled task for Robocurse
    .DESCRIPTION
        Registers a Windows scheduled task to run Robocurse automatically.
        Supports daily, weekly, and hourly schedules with flexible configuration.
    .PARAMETER TaskName
        Name for the scheduled task. Default: "Robocurse-Replication"
    .PARAMETER ConfigPath
        Path to config file (mandatory)
    .PARAMETER Schedule
        Schedule type: Daily, Weekly, Hourly. Default: Daily
    .PARAMETER Time
        Time to run in HH:mm format. Default: "02:00"
    .PARAMETER DaysOfWeek
        Days for weekly schedule (Sunday, Monday, etc.). Default: @('Sunday')
    .PARAMETER RunAsSystem
        Run as SYSTEM account (requires admin). Default: $false
    .OUTPUTS
        Boolean indicating success or failure
    .EXAMPLE
        Register-RobocurseTask -ConfigPath "C:\config.json" -Schedule Daily -Time "03:00"
    .EXAMPLE
        Register-RobocurseTask -ConfigPath "C:\config.json" -Schedule Weekly -DaysOfWeek @('Monday', 'Friday') -RunAsSystem
    #>
    param(
        [string]$TaskName = "Robocurse-Replication",

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [ValidateSet('Daily', 'Weekly', 'Hourly')]
        [string]$Schedule = 'Daily',

        [string]$Time = "02:00",

        [string[]]$DaysOfWeek = @('Sunday'),

        [switch]$RunAsSystem
    )

    try {
        # Check if running on Windows
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            Write-RobocurseLog -Message "Scheduled tasks are only supported on Windows" -Level 'Warning' -Component 'Scheduler'
            return $false
        }

        # Get script path
        $scriptPath = $PSCommandPath
        if (-not $scriptPath) {
            $scriptPath = $MyInvocation.MyCommand.Path
        }

        # Build action - PowerShell command to run Robocurse in headless mode
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Headless -ConfigPath `"$ConfigPath`""

        $action = New-ScheduledTaskAction `
            -Execute "powershell.exe" `
            -Argument $arguments `
            -WorkingDirectory (Split-Path $scriptPath -Parent)

        # Build trigger based on schedule type
        $trigger = switch ($Schedule) {
            'Daily' {
                New-ScheduledTaskTrigger -Daily -At $Time
            }
            'Weekly' {
                New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DaysOfWeek -At $Time
            }
            'Hourly' {
                New-ScheduledTaskTrigger -Once -At $Time `
                    -RepetitionInterval (New-TimeSpan -Hours 1) `
                    -RepetitionDuration (New-TimeSpan -Days 1)
            }
        }

        # Build principal - determines user context for task execution
        $principal = if ($RunAsSystem) {
            New-ScheduledTaskPrincipal `
                -UserId "SYSTEM" `
                -LogonType ServiceAccount `
                -RunLevel Highest
        }
        else {
            New-ScheduledTaskPrincipal `
                -UserId $env:USERNAME `
                -LogonType S4U `
                -RunLevel Highest
        }

        # Build settings - task execution policies
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RunOnlyIfNetworkAvailable `
            -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Hours 72) `
            -Priority 7

        # Register task with all components
        $taskParams = @{
            TaskName = $TaskName
            Action = $action
            Trigger = $trigger
            Principal = $principal
            Settings = $settings
            Description = "Robocurse automatic directory replication"
            Force = $true
        }

        Register-ScheduledTask @taskParams | Out-Null
        Write-RobocurseLog -Message "Scheduled task '$TaskName' registered successfully" -Level 'Info' -Component 'Scheduler'
        return $true
    }
    catch {
        Write-RobocurseLog -Message "Failed to register scheduled task: $_" -Level 'Error' -Component 'Scheduler'
        return $false
    }
}

function Unregister-RobocurseTask {
    <#
    .SYNOPSIS
        Removes the Robocurse scheduled task
    .DESCRIPTION
        Unregisters the specified scheduled task from Windows Task Scheduler.
    .PARAMETER TaskName
        Name of task to remove. Default: "Robocurse-Replication"
    .OUTPUTS
        Boolean indicating success or failure
    .EXAMPLE
        Unregister-RobocurseTask
    .EXAMPLE
        Unregister-RobocurseTask -TaskName "Custom-Task"
    #>
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        # Check if running on Windows
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            Write-RobocurseLog -Message "Scheduled tasks are only supported on Windows" -Level 'Warning' -Component 'Scheduler'
            return $false
        }

        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-RobocurseLog -Message "Scheduled task '$TaskName' removed" -Level 'Info' -Component 'Scheduler'
        return $true
    }
    catch {
        Write-RobocurseLog -Message "Failed to remove scheduled task: $_" -Level 'Error' -Component 'Scheduler'
        return $false
    }
}

function Get-RobocurseTask {
    <#
    .SYNOPSIS
        Gets information about the Robocurse scheduled task
    .DESCRIPTION
        Retrieves detailed information about a scheduled task including state,
        next run time, last run time, and trigger configuration.
    .PARAMETER TaskName
        Name of task to query. Default: "Robocurse-Replication"
    .OUTPUTS
        PSCustomObject with task info or $null if not found
    .EXAMPLE
        Get-RobocurseTask
    .EXAMPLE
        $taskInfo = Get-RobocurseTask -TaskName "Custom-Task"
    #>
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        # Check if running on Windows
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            return $null
        }

        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop

        return [PSCustomObject]@{
            Name = $task.TaskName
            State = $task.State
            Enabled = ($task.State -eq 'Ready')
            NextRunTime = $info.NextRunTime
            LastRunTime = $info.LastRunTime
            LastResult = $info.LastTaskResult
            Triggers = $task.Triggers | ForEach-Object {
                [PSCustomObject]@{
                    Type = $_.CimClass.CimClassName -replace 'MSFT_Task', '' -replace 'Trigger', ''
                    Enabled = $_.Enabled
                }
            }
        }
    }
    catch {
        return $null
    }
}

function Start-RobocurseTask {
    <#
    .SYNOPSIS
        Manually triggers the scheduled task
    .DESCRIPTION
        Starts the scheduled task immediately, outside of its normal schedule.
    .PARAMETER TaskName
        Name of task to start. Default: "Robocurse-Replication"
    .OUTPUTS
        Boolean indicating success or failure
    .EXAMPLE
        Start-RobocurseTask
    #>
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        # Check if running on Windows
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            Write-RobocurseLog -Message "Scheduled tasks are only supported on Windows" -Level 'Warning' -Component 'Scheduler'
            return $false
        }

        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Write-RobocurseLog -Message "Manually triggered task '$TaskName'" -Level 'Info' -Component 'Scheduler'
        return $true
    }
    catch {
        Write-RobocurseLog -Message "Failed to start task: $_" -Level 'Error' -Component 'Scheduler'
        return $false
    }
}

function Enable-RobocurseTask {
    <#
    .SYNOPSIS
        Enables the scheduled task
    .DESCRIPTION
        Enables a disabled scheduled task so it will run on its schedule.
    .PARAMETER TaskName
        Name of task to enable. Default: "Robocurse-Replication"
    .OUTPUTS
        Boolean indicating success or failure
    .EXAMPLE
        Enable-RobocurseTask
    #>
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        # Check if running on Windows
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            Write-RobocurseLog -Message "Scheduled tasks are only supported on Windows" -Level 'Warning' -Component 'Scheduler'
            return $false
        }

        Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-RobocurseLog -Message "Enabled task '$TaskName'" -Level 'Info' -Component 'Scheduler'
        return $true
    }
    catch {
        Write-RobocurseLog -Message "Failed to enable task: $_" -Level 'Error' -Component 'Scheduler'
        return $false
    }
}

function Disable-RobocurseTask {
    <#
    .SYNOPSIS
        Disables the scheduled task
    .DESCRIPTION
        Disables a scheduled task so it won't run on its schedule.
        The task remains configured but won't execute until re-enabled.
    .PARAMETER TaskName
        Name of task to disable. Default: "Robocurse-Replication"
    .OUTPUTS
        Boolean indicating success or failure
    .EXAMPLE
        Disable-RobocurseTask
    #>
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        # Check if running on Windows
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            Write-RobocurseLog -Message "Scheduled tasks are only supported on Windows" -Level 'Warning' -Component 'Scheduler'
            return $false
        }

        Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-RobocurseLog -Message "Disabled task '$TaskName'" -Level 'Info' -Component 'Scheduler'
        return $true
    }
    catch {
        Write-RobocurseLog -Message "Failed to disable task: $_" -Level 'Error' -Component 'Scheduler'
        return $false
    }
}

function Test-RobocurseTaskExists {
    <#
    .SYNOPSIS
        Checks if a Robocurse scheduled task exists
    .DESCRIPTION
        Tests whether the specified scheduled task is registered in Task Scheduler.
    .PARAMETER TaskName
        Name of task to check. Default: "Robocurse-Replication"
    .OUTPUTS
        Boolean indicating if task exists
    .EXAMPLE
        if (Test-RobocurseTaskExists) { "Task exists" }
    #>
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        # Check if running on Windows
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            return $false
        }

        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        return $null -ne $task
    }
    catch {
        return $false
    }
}

#endregion

#region ==================== GUI ====================

$script:MainWindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Robocurse - Multi-Share Replication"
        Height="800" Width="1100"
        WindowStartupLocation="CenterScreen"
        Background="#1E1E1E">

    <Window.Resources>
        <!-- Dark Theme Styles -->
        <Style x:Key="DarkLabel" TargetType="Label">
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>

        <Style x:Key="DarkTextBox" TargetType="TextBox">
            <Setter Property="Background" Value="#2D2D2D"/>
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="BorderBrush" Value="#3E3E3E"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="CaretBrush" Value="#E0E0E0"/>
        </Style>

        <Style x:Key="DarkButton" TargetType="Button">
            <Setter Property="Background" Value="#0078D4"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#1084D8"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#4A4A4A"/>
                    <Setter Property="Foreground" Value="#808080"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="StopButton" TargetType="Button" BasedOn="{StaticResource DarkButton}">
            <Setter Property="Background" Value="#D32F2F"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#E53935"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="DarkCheckBox" TargetType="CheckBox">
            <Setter Property="Foreground" Value="#E0E0E0"/>
        </Style>

        <Style x:Key="DarkListBox" TargetType="ListBox">
            <Setter Property="Background" Value="#2D2D2D"/>
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="BorderBrush" Value="#3E3E3E"/>
        </Style>
    </Window.Resources>

    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="120"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
            <TextBlock Text="ROBOCURSE" FontSize="28" FontWeight="Bold" Foreground="#0078D4"/>
            <TextBlock Text=" | Multi-Share Replication" FontSize="14" Foreground="#808080"
                       VerticalAlignment="Bottom" Margin="0,0,0,4"/>
        </StackPanel>

        <!-- Profile and Settings Panel -->
        <Grid Grid.Row="1" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="250"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- Profile List -->
            <Border Grid.Column="0" Background="#252525" CornerRadius="4" Margin="0,0,10,0" Padding="10">
                <DockPanel>
                    <Label DockPanel.Dock="Top" Content="Sync Profiles" Style="{StaticResource DarkLabel}" FontWeight="Bold"/>
                    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0">
                        <Button x:Name="btnAddProfile" Content="+ Add" Style="{StaticResource DarkButton}" Width="70" Margin="0,0,5,0"
                                ToolTip="Add a new sync profile for a source/destination pair"/>
                        <Button x:Name="btnRemoveProfile" Content="Remove" Style="{StaticResource DarkButton}" Width="70"
                                ToolTip="Remove the selected sync profile"/>
                    </StackPanel>
                    <ListBox x:Name="lstProfiles" Style="{StaticResource DarkListBox}" Margin="0,5,0,0"
                             ToolTip="List of configured sync profiles. Check to enable, uncheck to disable.">
                        <ListBox.ItemTemplate>
                            <DataTemplate>
                                <CheckBox IsChecked="{Binding Enabled}" Content="{Binding Name}"
                                          Style="{StaticResource DarkCheckBox}"/>
                            </DataTemplate>
                        </ListBox.ItemTemplate>
                    </ListBox>
                </DockPanel>
            </Border>

            <!-- Selected Profile Settings -->
            <Border Grid.Column="1" Background="#252525" CornerRadius="4" Padding="15">
                <Grid x:Name="pnlProfileSettings">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="100"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="80"/>
                    </Grid.ColumnDefinitions>

                    <Label Grid.Row="0" Content="Name:" Style="{StaticResource DarkLabel}"/>
                    <TextBox Grid.Row="0" Grid.Column="1" Grid.ColumnSpan="2" x:Name="txtProfileName"
                             Style="{StaticResource DarkTextBox}" Margin="0,0,0,8"
                             ToolTip="Display name for this sync profile"/>

                    <Label Grid.Row="1" Content="Source:" Style="{StaticResource DarkLabel}"/>
                    <TextBox Grid.Row="1" Grid.Column="1" x:Name="txtSource" Style="{StaticResource DarkTextBox}" Margin="0,0,5,8"
                             ToolTip="The network share or local path to copy FROM.&#x0a;Example: \\fileserver\users$ or D:\SourceData"/>
                    <Button Grid.Row="1" Grid.Column="2" x:Name="btnBrowseSource" Content="Browse"
                            Style="{StaticResource DarkButton}"/>

                    <Label Grid.Row="2" Content="Destination:" Style="{StaticResource DarkLabel}"/>
                    <TextBox Grid.Row="2" Grid.Column="1" x:Name="txtDest" Style="{StaticResource DarkTextBox}" Margin="0,0,5,8"
                             ToolTip="Where files will be copied TO. Directory will be created if needed."/>
                    <Button Grid.Row="2" Grid.Column="2" x:Name="btnBrowseDest" Content="Browse"
                            Style="{StaticResource DarkButton}"/>

                    <StackPanel Grid.Row="3" Grid.ColumnSpan="3" Orientation="Horizontal" Margin="0,5,0,8">
                        <CheckBox x:Name="chkUseVss" Content="Use VSS" Style="{StaticResource DarkCheckBox}" Margin="0,0,20,0"
                                  ToolTip="Create a shadow copy snapshot before syncing.&#x0a;Allows copying locked files (like Outlook PST).&#x0a;Requires admin rights."/>
                        <Label Content="Scan Mode:" Style="{StaticResource DarkLabel}"/>
                        <ComboBox x:Name="cmbScanMode" Width="100" Margin="5,0,0,0"
                                  ToolTip="Smart: Scans and splits based on size (recommended).&#x0a;Quick: Fixed depth split, faster startup.">
                            <ComboBoxItem Content="Smart" IsSelected="True"/>
                            <ComboBoxItem Content="Quick"/>
                        </ComboBox>
                    </StackPanel>

                    <StackPanel Grid.Row="4" Grid.ColumnSpan="3" Orientation="Horizontal">
                        <Label Content="Max Size:" Style="{StaticResource DarkLabel}"/>
                        <TextBox x:Name="txtMaxSize" Width="50" Style="{StaticResource DarkTextBox}" Text="10"
                                 ToolTip="Split directories larger than this (GB).&#x0a;Smaller = more parallel jobs.&#x0a;Recommended: 5-20 GB"/>
                        <Label Content="GB" Style="{StaticResource DarkLabel}" Margin="0,0,15,0"/>

                        <Label Content="Max Files:" Style="{StaticResource DarkLabel}"/>
                        <TextBox x:Name="txtMaxFiles" Width="60" Style="{StaticResource DarkTextBox}" Text="50000"
                                 ToolTip="Split directories with more files than this.&#x0a;Recommended: 20,000-100,000"/>

                        <Label Content="Max Depth:" Style="{StaticResource DarkLabel}" Margin="15,0,0,0"/>
                        <TextBox x:Name="txtMaxDepth" Width="40" Style="{StaticResource DarkTextBox}" Text="5"
                                 ToolTip="How deep to split directories.&#x0a;Higher = more granular but slower scan.&#x0a;Recommended: 3-6"/>
                    </StackPanel>
                </Grid>
            </Border>
        </Grid>

        <!-- Progress Area -->
        <Grid Grid.Row="2">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Control Bar -->
            <Border Grid.Row="0" Background="#252525" CornerRadius="4" Padding="10" Margin="0,0,0,10">
                <StackPanel Orientation="Horizontal">
                    <Label Content="Workers:" Style="{StaticResource DarkLabel}"
                           ToolTip="Number of simultaneous robocopy processes.&#x0a;More = faster but uses more resources.&#x0a;Recommended: 2-8"/>
                    <Slider x:Name="sldWorkers" Width="100" Minimum="1" Maximum="16" Value="4" VerticalAlignment="Center"/>
                    <TextBlock x:Name="txtWorkerCount" Text="4" Foreground="#E0E0E0" Width="25" Margin="5,0,20,0" VerticalAlignment="Center"/>

                    <Button x:Name="btnRunAll" Content="▶ Run All" Style="{StaticResource DarkButton}" Width="100" Margin="0,0,10,0"
                            ToolTip="Start syncing all enabled profiles in sequence"/>
                    <Button x:Name="btnRunSelected" Content="▶ Run Selected" Style="{StaticResource DarkButton}" Width="120" Margin="0,0,10,0"
                            ToolTip="Run only the currently selected profile"/>
                    <Button x:Name="btnStop" Content="⏹ Stop" Style="{StaticResource StopButton}" Width="80" Margin="0,0,10,0" IsEnabled="False"
                            ToolTip="Stop all running robocopy jobs"/>
                    <Button x:Name="btnSchedule" Content="⚙ Schedule" Style="{StaticResource DarkButton}" Width="100"
                            ToolTip="Configure automated scheduled runs"/>
                </StackPanel>
            </Border>

            <!-- Chunk DataGrid -->
            <DataGrid Grid.Row="1" x:Name="dgChunks" AutoGenerateColumns="False"
                      Background="#2D2D2D" Foreground="#E0E0E0" BorderBrush="#3E3E3E"
                      GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#3E3E3E"
                      RowHeaderWidth="0" IsReadOnly="True" SelectionMode="Single">
                <DataGrid.Columns>
                    <DataGridTextColumn Header="ID" Binding="{Binding ChunkId}" Width="50"/>
                    <DataGridTextColumn Header="Path" Binding="{Binding SourcePath}" Width="400"/>
                    <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="100"/>
                    <DataGridTemplateColumn Header="Progress" Width="150">
                        <DataGridTemplateColumn.CellTemplate>
                            <DataTemplate>
                                <ProgressBar Value="{Binding Progress}" Maximum="100" Height="18"
                                             Background="#3E3E3E" Foreground="#4CAF50"/>
                            </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                    </DataGridTemplateColumn>
                    <DataGridTextColumn Header="Speed" Binding="{Binding Speed}" Width="80"/>
                </DataGrid.Columns>
            </DataGrid>

            <!-- Progress Summary -->
            <Border Grid.Row="2" Background="#252525" CornerRadius="4" Padding="10" Margin="0,10,0,0">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="200"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Grid.Column="0">
                        <TextBlock x:Name="txtProfileProgress" Text="Profile: --" Foreground="#E0E0E0" Margin="0,0,0,5"/>
                        <ProgressBar x:Name="pbProfile" Height="20" Background="#3E3E3E" Foreground="#0078D4"/>
                    </StackPanel>

                    <StackPanel Grid.Column="1" Margin="20,0,0,0">
                        <TextBlock x:Name="txtOverallProgress" Text="Overall: --" Foreground="#E0E0E0" Margin="0,0,0,5"/>
                        <ProgressBar x:Name="pbOverall" Height="20" Background="#3E3E3E" Foreground="#4CAF50"/>
                    </StackPanel>

                    <StackPanel Grid.Column="2" Margin="20,0,0,0">
                        <TextBlock x:Name="txtEta" Text="ETA: --:--:--" Foreground="#808080"/>
                        <TextBlock x:Name="txtSpeed" Text="Speed: -- MB/s" Foreground="#808080"/>
                        <TextBlock x:Name="txtChunks" Text="Chunks: 0/0" Foreground="#808080"/>
                    </StackPanel>
                </Grid>
            </Border>
        </Grid>

        <!-- Status Bar -->
        <TextBlock Grid.Row="3" x:Name="txtStatus" Text="Ready" Foreground="#808080" Margin="0,10,0,5"/>

        <!-- Log Panel -->
        <Border Grid.Row="4" Background="#1A1A1A" BorderBrush="#3E3E3E" BorderThickness="1" CornerRadius="4">
            <ScrollViewer x:Name="svLog" VerticalScrollBarVisibility="Auto">
                <TextBlock x:Name="txtLog" Foreground="#808080" FontFamily="Consolas" FontSize="11"
                           Padding="10" TextWrapping="Wrap"/>
            </ScrollViewer>
        </Border>
    </Grid>
</Window>
'@

function Initialize-RobocurseGui {
    <#
    .SYNOPSIS
        Initializes and displays the WPF GUI
    .DESCRIPTION
        Loads XAML, wires up event handlers, initializes the UI state
        Only works on Windows due to WPF dependency
    .OUTPUTS
        Window object if successful, $null if not supported
    #>

    # Check platform
    if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
        Write-Warning "WPF GUI is only supported on Windows. Use -Headless mode on other platforms."
        return $null
    }

    try {
        # Load WPF assemblies
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase
    }
    catch {
        Write-Warning "Failed to load WPF assemblies. GUI not available: $_"
        return $null
    }

    try {
        # Parse XAML
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($script:MainWindowXaml))
        $script:Window = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()
    }
    catch {
        Write-Error "Failed to load XAML: $_"
        return $null
    }

    # Get control references
    $script:Controls = @{}
    @(
        'lstProfiles', 'btnAddProfile', 'btnRemoveProfile',
        'txtProfileName', 'txtSource', 'txtDest', 'btnBrowseSource', 'btnBrowseDest',
        'chkUseVss', 'cmbScanMode', 'txtMaxSize', 'txtMaxFiles', 'txtMaxDepth',
        'sldWorkers', 'txtWorkerCount', 'btnRunAll', 'btnRunSelected', 'btnStop', 'btnSchedule',
        'dgChunks', 'pbProfile', 'pbOverall', 'txtProfileProgress', 'txtOverallProgress',
        'txtEta', 'txtSpeed', 'txtChunks', 'txtStatus', 'txtLog', 'svLog'
    ) | ForEach-Object {
        $script:Controls[$_] = $script:Window.FindName($_)
    }

    # Wire up event handlers
    Initialize-EventHandlers

    # Load config and populate UI
    $script:Config = Get-RobocurseConfig -Path $ConfigPath
    Update-ProfileList

    # Initialize progress timer
    $script:ProgressTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ProgressTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:ProgressTimer.Add_Tick({ Update-GuiProgress })

    Write-GuiLog "Robocurse GUI initialized"

    return $script:Window
}

function Initialize-EventHandlers {
    <#
    .SYNOPSIS
        Wires up all GUI event handlers
    #>

    # Profile list selection
    $script:Controls.lstProfiles.Add_SelectionChanged({
        $selected = $script:Controls.lstProfiles.SelectedItem
        if ($selected) {
            Load-ProfileToForm -Profile $selected
        }
    })

    # Add/Remove profile buttons
    $script:Controls.btnAddProfile.Add_Click({ Add-NewProfile })
    $script:Controls.btnRemoveProfile.Add_Click({ Remove-SelectedProfile })

    # Browse buttons
    $script:Controls.btnBrowseSource.Add_Click({
        $path = Show-FolderBrowser -Description "Select source folder"
        if ($path) { $script:Controls.txtSource.Text = $path }
    })
    $script:Controls.btnBrowseDest.Add_Click({
        $path = Show-FolderBrowser -Description "Select destination folder"
        if ($path) { $script:Controls.txtDest.Text = $path }
    })

    # Workers slider
    $script:Controls.sldWorkers.Add_ValueChanged({
        $script:Controls.txtWorkerCount.Text = [int]$script:Controls.sldWorkers.Value
    })

    # Run buttons
    $script:Controls.btnRunAll.Add_Click({ Start-GuiReplication -AllProfiles })
    $script:Controls.btnRunSelected.Add_Click({ Start-GuiReplication -SelectedOnly })
    $script:Controls.btnStop.Add_Click({ Request-Stop })

    # Schedule button
    $script:Controls.btnSchedule.Add_Click({ Show-ScheduleDialog })

    # Form field changes - save to profile
    @('txtProfileName', 'txtSource', 'txtDest', 'txtMaxSize', 'txtMaxFiles', 'txtMaxDepth') | ForEach-Object {
        $script:Controls[$_].Add_LostFocus({ Save-ProfileFromForm })
    }
    $script:Controls.chkUseVss.Add_Checked({ Save-ProfileFromForm })
    $script:Controls.chkUseVss.Add_Unchecked({ Save-ProfileFromForm })
    $script:Controls.cmbScanMode.Add_SelectionChanged({ Save-ProfileFromForm })

    # Window closing
    $script:Window.Add_Closing({
        param($sender, $e)

        if ($script:OrchestrationState.Phase -eq 'Replicating') {
            $result = [System.Windows.MessageBox]::Show(
                "Replication is in progress. Stop and exit?",
                "Confirm Exit",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($result -eq 'No') {
                $e.Cancel = $true
                return
            }
            Stop-AllJobs
        }
        $script:ProgressTimer.Stop()
        Save-RobocurseConfig -Config $script:Config -Path $ConfigPath
    })
}

function Update-ProfileList {
    <#
    .SYNOPSIS
        Populates the profile listbox from config
    #>

    $script:Controls.lstProfiles.Items.Clear()

    if ($script:Config.SyncProfiles) {
        foreach ($profile in $script:Config.SyncProfiles) {
            $script:Controls.lstProfiles.Items.Add($profile) | Out-Null
        }
    }

    # Select first profile if available
    if ($script:Controls.lstProfiles.Items.Count -gt 0) {
        $script:Controls.lstProfiles.SelectedIndex = 0
    }
}

function Load-ProfileToForm {
    <#
    .SYNOPSIS
        Loads selected profile data into form fields
    .PARAMETER Profile
        Profile object to load
    #>
    param([PSCustomObject]$Profile)

    $script:Controls.txtProfileName.Text = $Profile.Name
    $script:Controls.txtSource.Text = $Profile.Source
    $script:Controls.txtDest.Text = $Profile.Destination
    $script:Controls.chkUseVss.IsChecked = $Profile.UseVSS

    # Set scan mode
    $scanMode = if ($Profile.ScanMode) { $Profile.ScanMode } else { "Smart" }
    $script:Controls.cmbScanMode.SelectedIndex = if ($scanMode -eq "Quick") { 1 } else { 0 }

    # Load chunk settings
    $script:Controls.txtMaxSize.Text = $Profile.ChunkMaxSizeGB
    $script:Controls.txtMaxFiles.Text = $Profile.ChunkMaxFiles
    $script:Controls.txtMaxDepth.Text = $Profile.ChunkMaxDepth
}

function Save-ProfileFromForm {
    <#
    .SYNOPSIS
        Saves form fields back to selected profile
    #>

    $selected = $script:Controls.lstProfiles.SelectedItem
    if (-not $selected) { return }

    # Update profile object
    $selected.Name = $script:Controls.txtProfileName.Text
    $selected.Source = $script:Controls.txtSource.Text
    $selected.Destination = $script:Controls.txtDest.Text
    $selected.UseVSS = $script:Controls.chkUseVss.IsChecked
    $selected.ScanMode = $script:Controls.cmbScanMode.Text

    # Parse numeric values with validation
    try {
        $selected.ChunkMaxSizeGB = [int]$script:Controls.txtMaxSize.Text
    } catch {
        $selected.ChunkMaxSizeGB = 10
        $script:Controls.txtMaxSize.Text = "10"
    }

    try {
        $selected.ChunkMaxFiles = [int]$script:Controls.txtMaxFiles.Text
    } catch {
        $selected.ChunkMaxFiles = 50000
        $script:Controls.txtMaxFiles.Text = "50000"
    }

    try {
        $selected.ChunkMaxDepth = [int]$script:Controls.txtMaxDepth.Text
    } catch {
        $selected.ChunkMaxDepth = 5
        $script:Controls.txtMaxDepth.Text = "5"
    }

    # Refresh list display
    $script:Controls.lstProfiles.Items.Refresh()
}

function Add-NewProfile {
    <#
    .SYNOPSIS
        Creates a new profile with defaults
    #>

    $newProfile = [PSCustomObject]@{
        Name = "New Profile"
        Source = ""
        Destination = ""
        Enabled = $true
        UseVSS = $false
        ScanMode = "Smart"
        ChunkMaxSizeGB = 10
        ChunkMaxFiles = 50000
        ChunkMaxDepth = 5
    }

    # Add to config
    if (-not $script:Config.SyncProfiles) {
        $script:Config.SyncProfiles = @()
    }
    $script:Config.SyncProfiles += $newProfile

    # Update UI
    Update-ProfileList
    $script:Controls.lstProfiles.SelectedIndex = $script:Controls.lstProfiles.Items.Count - 1

    Write-GuiLog "New profile created"
}

function Remove-SelectedProfile {
    <#
    .SYNOPSIS
        Removes selected profile with confirmation
    #>

    $selected = $script:Controls.lstProfiles.SelectedItem
    if (-not $selected) {
        [System.Windows.MessageBox]::Show(
            "Please select a profile to remove.",
            "No Selection",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        return
    }

    $result = [System.Windows.MessageBox]::Show(
        "Remove profile '$($selected.Name)'?",
        "Confirm Removal",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )

    if ($result -eq 'Yes') {
        $script:Config.SyncProfiles = @($script:Config.SyncProfiles | Where-Object { $_ -ne $selected })
        Update-ProfileList
        Write-GuiLog "Profile '$($selected.Name)' removed"
    }
}

function Show-FolderBrowser {
    <#
    .SYNOPSIS
        Opens folder browser dialog
    .PARAMETER Description
        Dialog description
    .OUTPUTS
        Selected path or $null
    #>
    param([string]$Description = "Select folder")

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }
    return $null
}

function Start-GuiReplication {
    <#
    .SYNOPSIS
        Starts replication from GUI
    .PARAMETER AllProfiles
        Run all enabled profiles
    .PARAMETER SelectedOnly
        Run only selected profile
    #>
    param(
        [switch]$AllProfiles,
        [switch]$SelectedOnly
    )

    # Determine which profiles to run
    $profilesToRun = @()

    if ($AllProfiles) {
        $profilesToRun = @($script:Config.SyncProfiles | Where-Object { $_.Enabled -eq $true })
        if ($profilesToRun.Count -eq 0) {
            Show-GuiError -Message "No enabled profiles found. Please enable at least one profile."
            return
        }
    }
    elseif ($SelectedOnly) {
        $selected = $script:Controls.lstProfiles.SelectedItem
        if (-not $selected) {
            Show-GuiError -Message "No profile selected. Please select a profile to run."
            return
        }
        $profilesToRun = @($selected)
    }

    # Validate profiles
    foreach ($profile in $profilesToRun) {
        if ([string]::IsNullOrWhiteSpace($profile.Source) -or [string]::IsNullOrWhiteSpace($profile.Destination)) {
            Show-GuiError -Message "Profile '$($profile.Name)' has invalid source or destination paths."
            return
        }
    }

    # Update UI state
    $script:Controls.btnRunAll.IsEnabled = $false
    $script:Controls.btnRunSelected.IsEnabled = $false
    $script:Controls.btnStop.IsEnabled = $true
    $script:Controls.txtStatus.Text = "Replication in progress..."

    Write-GuiLog "Starting replication with $($profilesToRun.Count) profile(s)"

    # Get worker count
    $maxWorkers = [int]$script:Controls.sldWorkers.Value

    # Clear chunk display
    $script:Controls.dgChunks.ItemsSource = $null

    # Start timer
    $script:ProgressTimer.Start()

    # Start replication asynchronously
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("profilesToRun", $profilesToRun)
    $runspace.SessionStateProxy.SetVariable("maxWorkers", $maxWorkers)

    # Execute replication in background
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    $powershell.AddScript({
        param($profiles, $workers)
        Start-ReplicationRun -Profiles $profiles -MaxConcurrentJobs $workers
    }).AddArgument($profilesToRun).AddArgument($maxWorkers)

    $script:ReplicationHandle = $powershell.BeginInvoke()
    $script:ReplicationPowerShell = $powershell
}

function Complete-GuiReplication {
    <#
    .SYNOPSIS
        Called when replication completes
    #>

    # Stop timer
    $script:ProgressTimer.Stop()

    # Re-enable buttons
    $script:Controls.btnRunAll.IsEnabled = $true
    $script:Controls.btnRunSelected.IsEnabled = $true
    $script:Controls.btnStop.IsEnabled = $false

    # Update status
    $script:Controls.txtStatus.Text = "Replication complete"

    # Show completion message
    $status = Get-OrchestrationStatus
    $message = "Replication completed!`n`nChunks: $($status.ChunksComplete)/$($status.ChunksTotal)`nFailed: $($status.ChunksFailed)"

    [System.Windows.MessageBox]::Show(
        $message,
        "Replication Complete",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    )

    Write-GuiLog "Replication completed: $($status.ChunksComplete)/$($status.ChunksTotal) chunks, $($status.ChunksFailed) failed"
}

function Update-GuiProgress {
    <#
    .SYNOPSIS
        Called by timer to update GUI from orchestration state
    #>

    try {
        $status = Get-OrchestrationStatus

        # Update progress bars
        $script:Controls.pbProfile.Value = $status.ProfileProgress
        $script:Controls.pbOverall.Value = $status.OverallProgress

        # Update text
        $profileName = if ($status.CurrentProfile) { $status.CurrentProfile } else { "--" }
        $script:Controls.txtProfileProgress.Text = "Profile: $profileName - $($status.ProfileProgress)%"
        $script:Controls.txtOverallProgress.Text = "Overall: $($status.OverallProgress)%"

        # Update ETA
        if ($status.ETA) {
            $script:Controls.txtEta.Text = "ETA: $($status.ETA.ToString('hh\:mm\:ss'))"
        } else {
            $script:Controls.txtEta.Text = "ETA: --:--:--"
        }

        # Update speed (bytes per second from elapsed time)
        if ($status.Elapsed.TotalSeconds -gt 0 -and $status.BytesComplete -gt 0) {
            $speed = $status.BytesComplete / $status.Elapsed.TotalSeconds
            $script:Controls.txtSpeed.Text = "Speed: $(Format-FileSize $speed)/s"
        } else {
            $script:Controls.txtSpeed.Text = "Speed: -- MB/s"
        }

        $script:Controls.txtChunks.Text = "Chunks: $($status.ChunksComplete)/$($status.ChunksTotal)"

        # Update chunk grid (prepare display objects from orchestration state)
        if ($script:OrchestrationState) {
            $chunkDisplayItems = @()

            # Add active jobs
            foreach ($job in $script:OrchestrationState.ActiveJobs.Values) {
                $chunkDisplayItems += [PSCustomObject]@{
                    ChunkId = $job.Chunk.ChunkId
                    SourcePath = $job.Chunk.SourcePath
                    Status = "Running"
                    Progress = if ($job.Progress) { $job.Progress } else { 0 }
                    Speed = "--"
                }
            }

            # Add completed chunks (show last 10)
            $completed = $script:OrchestrationState.CompletedChunks | Select-Object -Last 10
            foreach ($chunk in $completed) {
                $chunkDisplayItems += [PSCustomObject]@{
                    ChunkId = $chunk.ChunkId
                    SourcePath = $chunk.SourcePath
                    Status = "Complete"
                    Progress = 100
                    Speed = "--"
                }
            }

            # Add failed chunks
            foreach ($chunk in $script:OrchestrationState.FailedChunks) {
                $chunkDisplayItems += [PSCustomObject]@{
                    ChunkId = $chunk.ChunkId
                    SourcePath = $chunk.SourcePath
                    Status = "Failed"
                    Progress = 0
                    Speed = "--"
                }
            }

            # Update DataGrid
            $script:Controls.dgChunks.ItemsSource = $chunkDisplayItems
        }

        # Check if complete
        if ($status.Phase -eq 'Complete') {
            Complete-GuiReplication
        }
    }
    catch {
        Write-GuiLog "Error updating progress: $_"
    }
}

function Write-GuiLog {
    <#
    .SYNOPSIS
        Writes a message to the GUI log panel
    .PARAMETER Message
        Message to log
    #>
    param([string]$Message)

    if (-not $script:Controls.txtLog) { return }

    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $Message`n"

    # Use Dispatcher for thread safety
    $script:Window.Dispatcher.Invoke([Action]{
        $script:Controls.txtLog.Text += $line
        $script:Controls.svLog.ScrollToEnd()
    })
}

function Show-GuiError {
    <#
    .SYNOPSIS
        Displays an error message in the GUI
    .PARAMETER Message
        Error message
    .PARAMETER Details
        Detailed error information
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$Details
    )

    $fullMessage = $Message
    if ($Details) {
        $fullMessage += "`n`nDetails: $Details"
    }

    [System.Windows.MessageBox]::Show(
        $fullMessage,
        "Error",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )

    Write-GuiLog "ERROR: $Message"
}

function Show-ScheduleDialog {
    <#
    .SYNOPSIS
        Shows schedule configuration dialog
    #>

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Configure Schedule"
        Height="300" Width="400"
        WindowStartupLocation="CenterScreen"
        Background="#1E1E1E">
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <CheckBox x:Name="chkEnabled" Content="Enable Scheduled Runs" Foreground="#E0E0E0" FontWeight="Bold"/>

        <StackPanel Grid.Row="1" Margin="0,15,0,0">
            <Label Content="Run Time:" Foreground="#E0E0E0"/>
            <TextBox x:Name="txtTime" Background="#2D2D2D" Foreground="#E0E0E0" Padding="5" Text="02:00"/>
        </StackPanel>

        <StackPanel Grid.Row="2" Margin="0,15,0,0">
            <Label Content="Run On:" Foreground="#E0E0E0"/>
            <ComboBox x:Name="cmbFrequency" Background="#2D2D2D" Foreground="#E0E0E0">
                <ComboBoxItem Content="Daily" IsSelected="True"/>
                <ComboBoxItem Content="Weekdays"/>
                <ComboBoxItem Content="Weekends"/>
            </ComboBox>
        </StackPanel>

        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnOk" Content="OK" Width="80" Margin="0,0,10,0" Background="#0078D4" Foreground="White" Padding="10,5"/>
            <Button x:Name="btnCancel" Content="Cancel" Width="80" Background="#4A4A4A" Foreground="White" Padding="10,5"/>
        </StackPanel>
    </Grid>
</Window>
'@

    try {
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()

        # Get controls
        $chkEnabled = $dialog.FindName("chkEnabled")
        $txtTime = $dialog.FindName("txtTime")
        $cmbFrequency = $dialog.FindName("cmbFrequency")
        $btnOk = $dialog.FindName("btnOk")
        $btnCancel = $dialog.FindName("btnCancel")

        # Load current settings
        $chkEnabled.IsChecked = $script:Config.Schedule.Enabled
        $txtTime.Text = $script:Config.Schedule.Time

        # Button handlers
        $btnOk.Add_Click({
            $script:Config.Schedule.Enabled = $chkEnabled.IsChecked
            $script:Config.Schedule.Time = $txtTime.Text
            $script:Config.Schedule.Days = @($cmbFrequency.Text)
            Save-RobocurseConfig -Config $script:Config -Path $ConfigPath
            Write-GuiLog "Schedule updated: Enabled=$($chkEnabled.IsChecked), Time=$($txtTime.Text)"
            $dialog.Close()
        })

        $btnCancel.Add_Click({ $dialog.Close() })

        $dialog.ShowDialog() | Out-Null
    }
    catch {
        Show-GuiError -Message "Failed to show schedule dialog" -Details $_.Exception.Message
    }
}

#endregion

#region ==================== MAIN ====================

function Show-RobocurseHelp {
    <#
    .SYNOPSIS
        Displays help information
    #>

    Write-Host @"
Robocurse - Multi-Share Parallel Robocopy Orchestrator
======================================================

USAGE:
    .\Robocurse.ps1 [options]

OPTIONS:
    -Headless           Run in headless mode without GUI
    -ConfigPath <path>  Path to configuration file (default: .\Robocurse.config.json)
    -Profile <name>     Profile name from configuration file
    -Help               Display this help message

EXAMPLES:
    .\Robocurse.ps1
        Launch GUI interface

    .\Robocurse.ps1 -Headless -Profile "DailyBackup"
        Run in headless mode with the DailyBackup profile

    .\Robocurse.ps1 -ConfigPath "C:\Configs\custom.json" -Headless
        Run with custom configuration file

For more information, see README.md
"@
}

# Main entry point
if ($Help) {
    Show-RobocurseHelp
    exit 0
}

# Prevent execution during test mode
if (-not $script:TestMode) {
    try {
        # Load configuration
        if (Test-Path $ConfigPath) {
            $config = Get-RobocurseConfig -Path $ConfigPath
        }
        else {
            Write-Warning "Configuration file not found: $ConfigPath"
            if (-not $Headless) {
                # GUI can create a new config
                $config = $null
            }
            else {
                throw "Configuration file required for headless mode"
            }
        }

        # Launch appropriate interface
        if ($Headless) {
            # Run in headless mode
            if ($Profile) {
                Start-ReplicationRun -Config $config -ProfileName $Profile
            }
            else {
                throw "Profile parameter required for headless mode"
            }
        }
        else {
            # Launch GUI
            Initialize-RobocurseGui -Config $config
        }
    }
    catch {
        Write-Error "Robocurse failed: $_"
        exit 1
    }
}

#endregion
