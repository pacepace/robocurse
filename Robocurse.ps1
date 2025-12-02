<#
.TITLE
    Robocurse

.DESCRIPTION
    Multi-share parallel robocopy orchestrator for Windows environments.

    Robocurse intelligently splits large directory trees into manageable chunks
    and orchestrates multiple parallel robocopy processes for high-throughput
    file replication. Designed for enterprise scenarios where single robocopy
    instances become bottlenecked by massive directory structures.

    Features:
    - Smart chunking based on directory size and file count
    - Parallel robocopy execution with configurable concurrency
    - VSS snapshot support for copying locked files
    - SIEM-compatible JSON logging for audit trails
    - Email notifications on completion
    - Windows Task Scheduler integration
    - WPF GUI or headless CLI operation

.AUTHOR
    Mark Pace <pace@pace.org>

.COPYRIGHT
    (c) 2024 Mark Pace. All rights reserved.

.VERSION
    1.0.0

.LICENSEURI
    https://opensource.org/licenses/MIT

.PROJECTURI
    https://github.com/pacepace/robocurse

.TAGS
    robocopy, backup, replication, parallel, orchestration, file-sync

.RELEASENOTES
    1.0.0 - Initial release
#>

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
    [switch]$AllProfiles,
    [switch]$Help
)

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

# Logging
# Compress log files older than this many days to save disk space.
# 7 days keeps recent logs readily accessible while compressing older logs.
$script:LogCompressAfterDays = 7

# Delete compressed log files older than this many days.
# 30 days aligns with typical retention policies and provides adequate audit history.
$script:LogDeleteAfterDays = 30

#endregion

#region ==================== UTILITY ====================

function Test-IsWindowsPlatform {
    <#
    .SYNOPSIS
        Tests if the current platform is Windows
    .DESCRIPTION
        Provides a consistent way to check if running on Windows.
        Works across PowerShell 5.1 (where $IsWindows doesn't exist) and PowerShell 7+.
    .OUTPUTS
        Boolean - $true if running on Windows, $false otherwise
    .EXAMPLE
        if (Test-IsWindowsPlatform) { "Running on Windows" }
    #>

    # In PowerShell 5.1, $IsWindows doesn't exist (it's always Windows)
    # In PowerShell 7+, $IsWindows is defined
    if ($null -eq $IsWindows) {
        return $true  # PowerShell 5.1 only runs on Windows
    }
    return $IsWindows
}

function New-OperationResult {
    <#
    .SYNOPSIS
        Creates a standardized operation result object
    .DESCRIPTION
        Provides a consistent pattern for functions that may succeed or fail.
        Use this for operations where the caller needs to know both success status
        and any error details without throwing exceptions.
    .PARAMETER Success
        Whether the operation succeeded
    .PARAMETER Data
        Result data on success (optional)
    .PARAMETER ErrorMessage
        Error message on failure (optional)
    .PARAMETER ErrorRecord
        Original error record for debugging (optional)
    .OUTPUTS
        PSCustomObject with Success, Data, ErrorMessage, ErrorRecord
    .EXAMPLE
        return New-OperationResult -Success $true -Data $config
    .EXAMPLE
        return New-OperationResult -Success $false -ErrorMessage "File not found" -ErrorRecord $_
    #>
    param(
        [Parameter(Mandatory)]
        [bool]$Success,

        [object]$Data = $null,

        [string]$ErrorMessage = "",

        [System.Management.Automation.ErrorRecord]$ErrorRecord = $null
    )

    return [PSCustomObject]@{
        Success      = $Success
        Data         = $Data
        ErrorMessage = $ErrorMessage
        ErrorRecord  = $ErrorRecord
    }
}

function Test-IsBeingDotSourced {
    <#
    .SYNOPSIS
        Detects if the script is being dot-sourced vs executed directly
    .DESCRIPTION
        Used to prevent main execution when loading functions for testing.
        Returns $true if the script is being dot-sourced (. .\script.ps1)
        Returns $false if the script is being executed directly (.\script.ps1)
    .OUTPUTS
        Boolean
    #>
    # When dot-sourced, $MyInvocation.InvocationName is "." or the script path
    # When executed directly, $MyInvocation.InvocationName is the script path
    # We check if we're being called from another script's context
    $callStack = Get-PSCallStack
    # If there's more than just the current scope and global, we're being dot-sourced
    return $callStack.Count -gt 2
}

#endregion

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
            MaxConcurrentJobs = $script:DefaultMaxConcurrentJobs
            ThreadsPerJob = $script:DefaultThreadsPerJob
            DefaultScanMode = "Smart"
            LogPath = ".\Logs"
            LogCompressAfterDays = $script:LogCompressAfterDays
            LogRetentionDays = $script:LogDeleteAfterDays
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

function ConvertFrom-ConfigFileFormat {
    <#
    .SYNOPSIS
        Converts JSON config file format to internal format
    .DESCRIPTION
        The JSON config file uses a user-friendly format with:
        - "profiles" as an object with profile names as keys
        - "global" with nested settings

        This function converts to the internal format with:
        - "SyncProfiles" as an array of profile objects
        - "GlobalSettings" with flattened settings
    .PARAMETER RawConfig
        Raw config object loaded from JSON
    .OUTPUTS
        PSCustomObject in internal format
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$RawConfig
    )

    # Check if already in internal format (has SyncProfiles)
    $props = $RawConfig.PSObject.Properties.Name
    if ($props -contains 'SyncProfiles') {
        Write-Verbose "Config already in internal format"
        return $RawConfig
    }

    # Start with default config as base
    $config = New-DefaultConfig

    # Transform global settings
    if ($props -contains 'global') {
        $global = $RawConfig.global

        # Performance settings
        if ($global.performance) {
            if ($global.performance.maxConcurrentJobs) {
                $config.GlobalSettings.MaxConcurrentJobs = $global.performance.maxConcurrentJobs
            }
        }

        # Logging settings
        if ($global.logging -and $global.logging.operationalLog -and $global.logging.operationalLog.path) {
            $logPath = Split-Path -Path $global.logging.operationalLog.path -Parent
            $config.GlobalSettings.LogPath = $logPath
        }
        if ($global.logging -and $global.logging.operationalLog -and $global.logging.operationalLog.rotation) {
            if ($global.logging.operationalLog.rotation.maxAgeDays) {
                $config.GlobalSettings.LogRetentionDays = $global.logging.operationalLog.rotation.maxAgeDays
            }
        }

        # Email settings
        if ($global.email) {
            $config.Email.Enabled = if ($global.email.enabled) { $true } else { $false }
            if ($global.email.smtp) {
                $config.Email.SmtpServer = $global.email.smtp.server
                $config.Email.Port = if ($global.email.smtp.port) { $global.email.smtp.port } else { 587 }
                $config.Email.UseTls = if ($global.email.smtp.useSsl) { $true } else { $false }
                if ($global.email.smtp.credentialName) {
                    $config.Email.CredentialTarget = $global.email.smtp.credentialName
                }
            }
            if ($global.email.from) { $config.Email.From = $global.email.from }
            if ($global.email.to) { $config.Email.To = @($global.email.to) }
        }
    }

    # Transform profiles
    $syncProfiles = @()
    if ($props -contains 'profiles' -and $RawConfig.profiles) {
        $profileNames = $RawConfig.profiles.PSObject.Properties.Name
        foreach ($profileName in $profileNames) {
            $rawProfile = $RawConfig.profiles.$profileName

            # Skip disabled profiles
            if ($rawProfile.enabled -eq $false) {
                Write-Verbose "Skipping disabled profile: $profileName"
                continue
            }

            # Build sync profile
            $syncProfile = [PSCustomObject]@{
                Name = $profileName
                Description = if ($rawProfile.description) { $rawProfile.description } else { "" }
                Source = ""
                Destination = ""
                UseVss = $false
                ScanMode = "Smart"
                ChunkMaxSizeGB = 10
                ChunkMaxFiles = 50000
                ChunkMaxDepth = 5
                RobocopyOptions = @{}
            }

            # Handle source - can be single path or sources array
            # Multi-source profiles are expanded into separate sync profiles
            if ($rawProfile.sources -and $rawProfile.sources.Count -gt 0) {
                if ($rawProfile.sources.Count -eq 1) {
                    # Single source - use the profile name as-is
                    $syncProfile.Source = $rawProfile.sources[0].path
                    if ($rawProfile.sources[0].useVss) {
                        $syncProfile.UseVss = $true
                    }
                }
                else {
                    # Multiple sources - create separate profiles for each
                    Write-Verbose "Profile '$profileName' has $($rawProfile.sources.Count) sources - expanding"
                    for ($i = 0; $i -lt $rawProfile.sources.Count; $i++) {
                        $sourceInfo = $rawProfile.sources[$i]
                        $expandedProfile = [PSCustomObject]@{
                            Name = "$profileName-Source$($i + 1)"
                            Description = "$($syncProfile.Description) (Source $($i + 1))"
                            Source = $sourceInfo.path
                            Destination = ""  # Will be set below
                            UseVss = if ($sourceInfo.useVss) { $true } else { $false }
                            ScanMode = "Smart"
                            ChunkMaxSizeGB = 10
                            ChunkMaxFiles = 50000
                            ChunkMaxDepth = 5
                            RobocopyOptions = @{}
                            Enabled = $true
                            ParentProfile = $profileName  # Track origin for logging
                        }

                        # Handle destination (shared across all sources in the profile)
                        if ($rawProfile.destination -and $rawProfile.destination.path) {
                            $expandedProfile.Destination = $rawProfile.destination.path
                        }
                        elseif ($rawProfile.destination -is [string]) {
                            $expandedProfile.Destination = $rawProfile.destination
                        }

                        # Copy chunking settings
                        if ($rawProfile.chunking) {
                            if ($rawProfile.chunking.maxChunkSizeGB) {
                                $expandedProfile.ChunkMaxSizeGB = $rawProfile.chunking.maxChunkSizeGB
                            }
                            if ($rawProfile.chunking.parallelChunks) {
                                $expandedProfile | Add-Member -MemberType NoteProperty -Name 'ParallelChunks' -Value $rawProfile.chunking.parallelChunks -Force
                            }
                            if ($rawProfile.chunking.maxDepthToScan) {
                                $expandedProfile.ChunkMaxDepth = $rawProfile.chunking.maxDepthToScan
                            }
                            if ($rawProfile.chunking.strategy) {
                                $expandedProfile.ScanMode = switch ($rawProfile.chunking.strategy) {
                                    'auto' { 'Smart' }
                                    'balanced' { 'Smart' }
                                    'aggressive' { 'Smart' }
                                    'flat' { 'Flat' }
                                    default { 'Smart' }
                                }
                            }
                        }

                        # Copy robocopy options
                        $expandedRobocopyOptions = @{
                            Switches = @()
                            ExcludeFiles = @()
                            ExcludeDirs = @()
                        }
                        if ($rawProfile.robocopy) {
                            if ($rawProfile.robocopy.switches) {
                                $expandedRobocopyOptions.Switches = @($rawProfile.robocopy.switches)
                            }
                            if ($rawProfile.robocopy.excludeFiles) {
                                $expandedRobocopyOptions.ExcludeFiles = @($rawProfile.robocopy.excludeFiles)
                            }
                            if ($rawProfile.robocopy.excludeDirs) {
                                $expandedRobocopyOptions.ExcludeDirs = @($rawProfile.robocopy.excludeDirs)
                            }
                        }
                        $expandedProfile.RobocopyOptions = $expandedRobocopyOptions

                        $syncProfiles += $expandedProfile
                    }
                    # Skip adding the original syncProfile since we've expanded it
                    continue
                }
            }
            elseif ($rawProfile.source) {
                $syncProfile.Source = $rawProfile.source
            }

            # Handle destination
            if ($rawProfile.destination -and $rawProfile.destination.path) {
                $syncProfile.Destination = $rawProfile.destination.path
            }
            elseif ($rawProfile.destination -is [string]) {
                $syncProfile.Destination = $rawProfile.destination
            }

            # Handle chunking settings
            if ($rawProfile.chunking) {
                if ($rawProfile.chunking.maxChunkSizeGB) {
                    $syncProfile.ChunkMaxSizeGB = $rawProfile.chunking.maxChunkSizeGB
                }
                if ($rawProfile.chunking.parallelChunks) {
                    # This is actually max concurrent, but store for reference
                    $syncProfile | Add-Member -MemberType NoteProperty -Name 'ParallelChunks' -Value $rawProfile.chunking.parallelChunks -Force
                }
                if ($rawProfile.chunking.maxDepthToScan) {
                    $syncProfile.ChunkMaxDepth = $rawProfile.chunking.maxDepthToScan
                }
                # Handle strategy -> ScanMode mapping
                if ($rawProfile.chunking.strategy) {
                    $syncProfile.ScanMode = switch ($rawProfile.chunking.strategy) {
                        'auto' { 'Smart' }
                        'balanced' { 'Smart' }
                        'aggressive' { 'Smart' }
                        'flat' { 'Flat' }
                        default { 'Smart' }
                    }
                }
            }

            # Handle robocopy settings
            $robocopyOptions = @{
                Switches = @()
                ExcludeFiles = @()
                ExcludeDirs = @()
            }

            if ($rawProfile.robocopy) {
                if ($rawProfile.robocopy.switches) {
                    $robocopyOptions.Switches = @($rawProfile.robocopy.switches)
                }
                if ($rawProfile.robocopy.excludeFiles) {
                    $robocopyOptions.ExcludeFiles = @($rawProfile.robocopy.excludeFiles)
                }
                if ($rawProfile.robocopy.excludeDirs) {
                    $robocopyOptions.ExcludeDirs = @($rawProfile.robocopy.excludeDirs)
                }
            }

            # Handle retry policy
            if ($rawProfile.retryPolicy) {
                if ($rawProfile.retryPolicy.maxRetries) {
                    $robocopyOptions.RetryCount = $rawProfile.retryPolicy.maxRetries
                }
                if ($rawProfile.retryPolicy.retryDelayMinutes) {
                    # Convert minutes to seconds for robocopy /W:
                    $robocopyOptions.RetryWait = $rawProfile.retryPolicy.retryDelayMinutes * 60
                }
            }

            $syncProfile.RobocopyOptions = $robocopyOptions
            $syncProfiles += $syncProfile
        }
    }

    $config.SyncProfiles = $syncProfiles

    Write-Verbose "Converted config: $($syncProfiles.Count) profiles loaded"
    return $config
}

function Get-RobocurseConfig {
    <#
    .SYNOPSIS
        Loads configuration from JSON file
    .DESCRIPTION
        Loads and parses the Robocurse configuration from a JSON file.
        Automatically detects and converts between JSON file format and internal format.
        If the file doesn't exist, returns a default configuration.
        Handles malformed JSON gracefully by returning default config with a verbose message.
    .PARAMETER Path
        Path to the configuration JSON file. Defaults to .\Robocurse.config.json
    .OUTPUTS
        PSCustomObject with configuration in internal format
    .NOTES
        Error Behavior: Returns default configuration on error. Never throws.
        Use -Verbose to see error details.

        Supports two config formats:
        1. JSON file format: profiles/global structure (user-friendly)
        2. Internal format: SyncProfiles/GlobalSettings structure
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
        $rawConfig = $jsonContent | ConvertFrom-Json -Depth 10 -ErrorAction Stop

        # Convert to internal format (handles both formats)
        $config = ConvertFrom-ConfigFileFormat -RawConfig $rawConfig

        Write-Verbose "Configuration loaded successfully from '$Path'"
        return $config
    }
    catch {
        # Use Write-Verbose since logging may not be initialized yet
        Write-Verbose "Failed to load configuration from '$Path': $($_.Exception.Message)"
        Write-Verbose "Returning default configuration."
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
    .NOTES
        Error Behavior: Returns $false on error. Never throws.
        Use -Verbose to see error details.
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
        Write-Verbose "Failed to save configuration to '$Path': $($_.Exception.Message)"
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

    # Format the log entry
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $levelUpper = $Level.ToUpper()
    $logEntry = "${timestamp} [${levelUpper}] [${Component}] ${Message}"

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

#endregion

#region ==================== DIRECTORY PROFILING ====================

# Script-level cache for directory profiles (thread-safe)
$script:ProfileCache = [System.Collections.Concurrent.ConcurrentDictionary[string, PSCustomObject]]::new()

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

function ConvertFrom-RobocopyListOutput {
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

        [int]$CacheMaxAgeHours = $script:ProfileCacheMaxAgeHours
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
        $parseResult = ConvertFrom-RobocopyListOutput -Output $output

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

function Get-NormalizedCacheKey {
    <#
    .SYNOPSIS
        Normalizes a path for use as a cache key
    .DESCRIPTION
        Creates a consistent cache key from a path by:
        - Converting to lowercase (Windows paths are case-insensitive)
        - Removing trailing slashes
        - Normalizing path separators
    .PARAMETER Path
        Path to normalize
    .OUTPUTS
        Normalized path string suitable for cache key
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Remove trailing slashes and normalize
    $normalized = $Path.TrimEnd('\', '/')

    # Convert to lowercase for case-insensitive matching on Windows
    # This ensures C:\Users and c:\users hit the same cache entry
    $normalized = $normalized.ToLowerInvariant()

    return $normalized
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

    # Normalize path for cache lookup
    $cacheKey = Get-NormalizedCacheKey -Path $Path

    # Thread-safe retrieval from ConcurrentDictionary
    $cachedProfile = $null
    if (-not $script:ProfileCache.TryGetValue($cacheKey, [ref]$cachedProfile)) {
        return $null
    }

    # Check if cache is still valid
    $age = (Get-Date) - $cachedProfile.LastScanned
    if ($age.TotalHours -gt $MaxAgeHours) {
        Write-RobocurseLog "Cache expired for: $Path (age: $([math]::Round($age.TotalHours, 1))h)" -Level Debug
        # Remove expired entry (thread-safe)
        $script:ProfileCache.TryRemove($cacheKey, [ref]$null) | Out-Null
        return $null
    }

    return $cachedProfile
}

function Set-CachedProfile {
    <#
    .SYNOPSIS
        Stores directory profile in cache (thread-safe)
    .PARAMETER Profile
        Profile object to cache
    #>
    param(
        [PSCustomObject]$Profile
    )

    # Normalize path for cache key
    $cacheKey = Get-NormalizedCacheKey -Path $Profile.Path

    # Thread-safe add or update using ConcurrentDictionary indexer
    $script:ProfileCache[$cacheKey] = $Profile
    Write-RobocurseLog "Cached profile for: $($Profile.Path)" -Level Debug
}

#endregion

#region ==================== CHUNKING ====================

# Script-level counter for unique chunk IDs (using [ref] for thread-safe Interlocked operations)
$script:ChunkIdCounter = [ref]0

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
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationRoot,

        [ValidateNotNullOrEmpty()]
        [string]$SourceRoot,

        [ValidateRange(1MB, 1TB)]
        [int64]$MaxSizeBytes = $script:DefaultMaxChunkSizeBytes,

        [ValidateRange(1, 10000000)]
        [int]$MaxFiles = $script:DefaultMaxFilesPerChunk,

        [ValidateRange(0, 20)]
        [int]$MaxDepth = $script:DefaultMaxChunkDepth,

        [ValidateRange(1KB, 1TB)]
        [int64]$MinSizeBytes = $script:DefaultMinChunkSizeBytes,

        [ValidateRange(0, 20)]
        [int]$CurrentDepth = 0
    )

    # Validate path exists (inside function body so mocks can intercept)
    if (-not (Test-Path -Path $Path -PathType Container)) {
        throw "Path '$Path' does not exist or is not a directory"
    }

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

    # Thread-safe increment using Interlocked
    $chunkId = [System.Threading.Interlocked]::Increment($script:ChunkIdCounter)

    $chunk = [PSCustomObject]@{
        ChunkId = $chunkId
        SourcePath = $SourcePath
        DestinationPath = $DestinationPath
        EstimatedSize = $Profile.TotalSize
        EstimatedFiles = $Profile.FileCount
        Depth = 0  # Will be set by caller if needed
        IsFilesOnly = $IsFilesOnly
        Status = "Pending"
        RetryCount = 0  # Track retry attempts for failed chunks
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

function New-FlatChunks {
    <#
    .SYNOPSIS
        Creates chunks using flat (non-recursive) scanning strategy
    .DESCRIPTION
        Generates chunks without recursing into subdirectories.
        This is a fast scanning mode that treats each top-level directory as a chunk.
    .PARAMETER Path
        Root path to chunk
    .PARAMETER DestinationRoot
        Destination root path
    .PARAMETER MaxChunkSizeBytes
        Maximum size per chunk (default: 10GB)
    .PARAMETER MaxFiles
        Maximum files per chunk (default: 50000)
    .OUTPUTS
        Array of chunk objects
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DestinationRoot,

        [int64]$MaxChunkSizeBytes = $script:DefaultMaxChunkSizeBytes,
        [int]$MaxFiles = $script:DefaultMaxFilesPerChunk
    )

    # Flat mode: MaxDepth = 0 (no recursion into subdirectories)
    return Get-DirectoryChunks `
        -Path $Path `
        -DestinationRoot $DestinationRoot `
        -MaxSizeBytes $MaxChunkSizeBytes `
        -MaxFiles $MaxFiles `
        -MaxDepth 0
}

function New-SmartChunks {
    <#
    .SYNOPSIS
        Creates chunks using smart (recursive) scanning strategy
    .DESCRIPTION
        Generates chunks by recursively analyzing the directory tree and
        splitting based on size and file count thresholds.
        This is the recommended mode for most use cases.
    .PARAMETER Path
        Root path to chunk
    .PARAMETER DestinationRoot
        Destination root path
    .PARAMETER MaxChunkSizeBytes
        Maximum size per chunk (default: 10GB)
    .PARAMETER MaxFiles
        Maximum files per chunk (default: 50000)
    .PARAMETER MaxDepth
        Maximum recursion depth (default: 5)
    .OUTPUTS
        Array of chunk objects
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DestinationRoot,

        [int64]$MaxChunkSizeBytes = $script:DefaultMaxChunkSizeBytes,
        [int]$MaxFiles = $script:DefaultMaxFilesPerChunk,
        [int]$MaxDepth = $script:DefaultMaxChunkDepth
    )

    # Smart mode: recursive chunking with configurable depth
    return Get-DirectoryChunks `
        -Path $Path `
        -DestinationRoot $DestinationRoot `
        -MaxSizeBytes $MaxChunkSizeBytes `
        -MaxFiles $MaxFiles `
        -MaxDepth $MaxDepth
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
    .PARAMETER RobocopyOptions
        Hashtable of robocopy options from profile. Supports:
        - Switches: Array of robocopy switches (e.g., @("/MIR", "/COPYALL"))
        - ExcludeFiles: Array of file patterns to exclude (e.g., @("*.tmp", "~*"))
        - ExcludeDirs: Array of directory names to exclude
        - RetryCount: Override default retry count
        - RetryWait: Override default retry wait seconds
        - NoMirror: Set to $true to use /E instead of /MIR (copy without deleting)
        - SkipJunctions: Set to $false to include junction points (default: skip)
    .OUTPUTS
        PSCustomObject with Process, Chunk, StartTime, LogPath
    .EXAMPLE
        $options = @{
            Switches = @("/COPYALL", "/DCOPY:DAT")
            ExcludeFiles = @("*.tmp", "*.log")
            ExcludeDirs = @("temp", "cache")
            NoMirror = $true
        }
        Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $options
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSCustomObject]$Chunk,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [ValidateRange(1, 128)]
        [int]$ThreadsPerJob = $script:DefaultThreadsPerJob,

        [hashtable]$RobocopyOptions = @{}
    )

    # Validate Chunk properties
    if ([string]::IsNullOrWhiteSpace($Chunk.SourcePath)) {
        throw "Chunk.SourcePath is required and cannot be null or empty"
    }
    if ([string]::IsNullOrWhiteSpace($Chunk.DestinationPath)) {
        throw "Chunk.DestinationPath is required and cannot be null or empty"
    }

    # Extract options with defaults
    $retryCount = if ($RobocopyOptions.RetryCount) { $RobocopyOptions.RetryCount } else { $script:RobocopyRetryCount }
    $retryWait = if ($RobocopyOptions.RetryWait) { $RobocopyOptions.RetryWait } else { $script:RobocopyRetryWaitSeconds }
    $skipJunctions = if ($RobocopyOptions.ContainsKey('SkipJunctions')) { $RobocopyOptions.SkipJunctions } else { $true }
    $noMirror = if ($RobocopyOptions.NoMirror) { $true } else { $false }

    # Build base argument list (source, dest, essential logging)
    $argList = @(
        "`"$($Chunk.SourcePath)`"",
        "`"$($Chunk.DestinationPath)`""
    )

    # Add copy mode: /MIR (mirror with delete) or /E (copy subdirs including empty)
    if ($noMirror) {
        $argList += "/E"
    }
    else {
        $argList += "/MIR"
    }

    # Add profile-specified switches if provided, otherwise use defaults
    if ($RobocopyOptions.Switches -and $RobocopyOptions.Switches.Count -gt 0) {
        # Filter out switches we handle separately (/MT, /R, /W, /LOG, /MIR, /E)
        $customSwitches = $RobocopyOptions.Switches | Where-Object {
            $_ -notmatch '^/(MT|R|W|LOG|MIR|E|TEE|NP|BYTES)' -and
            $_ -notmatch '^/LOG:'
        }
        $argList += $customSwitches
    }
    else {
        # Default copy options when none specified
        $argList += @(
            "/COPY:DAT",
            "/DCOPY:T"
        )
    }

    # Threading, retry, and logging (always applied)
    $argList += @(
        "/MT:$ThreadsPerJob",
        "/R:$retryCount",
        "/W:$retryWait",
        "/LOG:`"$LogPath`"",
        "/TEE",
        "/NP",
        "/BYTES"
    )

    # Junction handling
    if ($skipJunctions) {
        $argList += @("/XJD", "/XJF")
    }

    # Exclude files
    if ($RobocopyOptions.ExcludeFiles -and $RobocopyOptions.ExcludeFiles.Count -gt 0) {
        $argList += "/XF"
        $argList += $RobocopyOptions.ExcludeFiles | ForEach-Object { "`"$_`"" }
    }

    # Exclude directories
    if ($RobocopyOptions.ExcludeDirs -and $RobocopyOptions.ExcludeDirs.Count -gt 0) {
        $argList += "/XD"
        $argList += $RobocopyOptions.ExcludeDirs | ForEach-Object { "`"$_`"" }
    }

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

    Write-RobocurseLog -Message "Robocopy args: $($argList -join ' ')" -Level 'Debug' -Component 'Robocopy'

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
        # If we can't read the file, log the error and return zeros
        Write-RobocurseLog "Failed to read robocopy log file '$LogPath': $_" -Level Warning
        return $result
    }

    # Parse summary statistics using regex
    # Target format:
    #                Total    Copied   Skipped  Mismatch    FAILED    Extras
    #     Dirs :      100        10        90         0         0         0
    #    Files :     1000       500       500         0         5         0
    #    Bytes :   1.0 g   500.0 m   500.0 m         0    10.0 k         0

    try {
        # Parse Files line
        if ($content -match '\s+Files\s*:\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+\s+(\d+)') {
            $parsedValue = 0
            if ([int]::TryParse($matches[2], [ref]$parsedValue)) { $result.FilesCopied = $parsedValue }
            if ([int]::TryParse($matches[3], [ref]$parsedValue)) { $result.FilesSkipped = $parsedValue }
            if ([int]::TryParse($matches[4], [ref]$parsedValue)) { $result.FilesFailed = $parsedValue }
        }

        # Parse Dirs line
        if ($content -match '\s+Dirs\s*:\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+\s+(\d+)') {
            $parsedValue = 0
            if ([int]::TryParse($matches[2], [ref]$parsedValue)) { $result.DirsCopied = $parsedValue }
            if ([int]::TryParse($matches[3], [ref]$parsedValue)) { $result.DirsSkipped = $parsedValue }
            if ([int]::TryParse($matches[4], [ref]$parsedValue)) { $result.DirsFailed = $parsedValue }
        }

        # Parse Bytes line - extract number and convert units
        if ($content -match '\s+Bytes\s*:\s+[\d.]+\s+[kmgt]?\s+([\d.]+)\s+([kmgt]?)') {
            $parsedDouble = 0.0
            if ([double]::TryParse($matches[1], [ref]$parsedDouble)) {
                $byteValue = $parsedDouble
                $unit = $matches[2].ToLower()

                $result.BytesCopied = switch ($unit) {
                    'k' { [long]($byteValue * 1KB) }
                    'm' { [long]($byteValue * 1MB) }
                    'g' { [long]($byteValue * 1GB) }
                    't' { [long]($byteValue * 1TB) }
                    default { [long]$byteValue }
                }
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
    }
    catch {
        # Log parsing errors but don't fail - return partial results
        Write-RobocurseLog "Error parsing robocopy log '$LogPath': $_" -Level Warning
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
    $finalStats = ConvertFrom-RobocopyLog -LogPath $Job.LogPath

    return [PSCustomObject]@{
        ExitCode = $exitCode
        ExitMeaning = $exitMeaning
        Duration = $duration
        Stats = $finalStats
    }
}

#endregion

#region ==================== ORCHESTRATION ====================

# Script-scoped orchestration state (using concurrent collections for thread safety)
$script:OrchestrationState = [PSCustomObject]@{
    SessionId        = ""
    CurrentProfile   = $null
    Phase            = "Idle"  # Idle, Scanning, Replicating, Complete, Stopped
    Profiles         = @()     # All profiles to process
    ProfileIndex     = 0       # Current profile index

    # Current profile state (thread-safe collections)
    ChunkQueue       = [System.Collections.Concurrent.ConcurrentQueue[PSCustomObject]]::new()
    ActiveJobs       = [System.Collections.Concurrent.ConcurrentDictionary[int,PSCustomObject]]::new()  # ProcessId -> Job
    CompletedChunks  = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
    FailedChunks     = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

    # Profile-specific robocopy options (set by Start-ProfileReplication)
    CurrentRobocopyOptions = @{}

    # VSS snapshot for current profile (if UseVSS is enabled)
    CurrentVssSnapshot = $null  # Holds snapshot info from New-VssSnapshot

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

        # Thread-safe collections for cross-runspace access
        ChunkQueue       = [System.Collections.Concurrent.ConcurrentQueue[PSCustomObject]]::new()
        ActiveJobs       = [System.Collections.Concurrent.ConcurrentDictionary[int,PSCustomObject]]::new()
        CompletedChunks  = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
        FailedChunks     = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

        CurrentRobocopyOptions = @{}

        # VSS snapshot for current profile (if UseVSS is enabled)
        CurrentVssSnapshot = $null

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

        [int]$MaxConcurrentJobs = $script:DefaultMaxConcurrentJobs
    )

    $state = $script:OrchestrationState
    $state.CurrentProfile = $Profile
    $state.ProfileStartTime = [datetime]::Now

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
            try {
                Write-RobocurseLog -Message "Creating VSS snapshot for: $($Profile.Source)" -Level 'Info' -Component 'VSS'
                $snapshot = New-VssSnapshot -SourcePath $Profile.Source
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
            catch {
                Write-RobocurseLog -Message "Failed to create VSS snapshot, continuing without VSS: $($_.Exception.Message)" -Level 'Warning' -Component 'VSS'
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

    # Initialize fresh concurrent collections (ConcurrentQueue/Bag don't have Clear())
    $state.ChunkQueue = [System.Collections.Concurrent.ConcurrentQueue[PSCustomObject]]::new()
    $state.CompletedChunks = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
    $state.FailedChunks = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

    # Enqueue all chunks (RetryCount is now part of New-Chunk)
    foreach ($chunk in $chunks) {
        $state.ChunkQueue.Enqueue($chunk)
    }

    $state.TotalChunks = $chunks.Count
    $state.TotalBytes = $scanResult.TotalSize
    $state.CompletedCount = 0
    $state.BytesComplete = 0
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

    # Start the robocopy job with profile-specific options
    $job = Start-RobocopyJob -Chunk $Chunk -LogPath $logPath `
        -ThreadsPerJob $script:DefaultThreadsPerJob `
        -RobocopyOptions $script:OrchestrationState.CurrentRobocopyOptions

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
        if ($job.Process.HasExited) {
            # Process completion
            $result = Complete-RobocopyJob -Job $job

            # Thread-safe removal from ConcurrentDictionary
            $removedJob = $null
            $state.ActiveJobs.TryRemove($kvp.Key, [ref]$removedJob) | Out-Null

            if ($result.ExitMeaning.Severity -in @('Error', 'Fatal')) {
                Invoke-FailedChunkHandler -Job $job -Result $result
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

    # Start new jobs - use TryDequeue for thread-safe queue access
    while (($state.ActiveJobs.Count -lt $MaxConcurrentJobs) -and
           ($state.ChunkQueue.Count -gt 0)) {
        $chunk = $null
        if ($state.ChunkQueue.TryDequeue([ref]$chunk)) {
            $job = Start-ChunkJob -Chunk $chunk
            $state.ActiveJobs[$job.Process.Id] = $job
        }
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
    $stats = ConvertFrom-RobocopyLog -LogPath $Job.LogPath
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

function Invoke-FailedChunkHandler {
    <#
    .SYNOPSIS
        Processes a failed chunk - retry or mark as permanently failed
    .PARAMETER Job
        Failed job object
    .PARAMETER Result
        Result from Complete-RobocopyJob
    #>
    param(
        [PSCustomObject]$Job,
        [PSCustomObject]$Result
    )

    $chunk = $Job.Chunk

    # Increment retry count (RetryCount is initialized in New-Chunk)
    $chunk.RetryCount++

    if ($chunk.RetryCount -lt $script:MaxChunkRetries -and $Result.ExitMeaning.ShouldRetry) {
        # Re-queue for retry (thread-safe ConcurrentQueue)
        Write-RobocurseLog -Message "Chunk $($chunk.ChunkId) failed, retrying ($($chunk.RetryCount)/$script:MaxChunkRetries)" `
            -Level 'Warning' -Component 'Orchestrator'

        $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
    }
    else {
        # Mark as permanently failed (thread-safe ConcurrentBag)
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
    .DESCRIPTION
        Handles profile completion: logs results, cleans up VSS snapshots,
        stores profile results for email reporting, and advances to next profile.
        Also clears completed chunks to prevent memory growth during long runs.
    #>
    $state = $script:OrchestrationState

    if ($null -eq $state.CurrentProfile) {
        return
    }

    $profileDuration = [datetime]::Now - $state.ProfileStartTime

    # Calculate profile statistics before clearing
    $completedChunksArray = $state.CompletedChunks.ToArray()
    $failedChunksArray = $state.FailedChunks.ToArray()

    $profileBytesCopied = 0
    foreach ($chunk in $completedChunksArray) {
        if ($chunk.EstimatedSize) {
            $profileBytesCopied += $chunk.EstimatedSize
        }
    }

    # Store profile result for email/reporting (prevents memory leak by summarizing)
    $profileResult = [PSCustomObject]@{
        Name = $state.CurrentProfile.Name
        Status = if ($failedChunksArray.Count -gt 0) { 'Warning' } else { 'Success' }
        ChunksComplete = $completedChunksArray.Count
        ChunksTotal = $state.TotalChunks
        ChunksFailed = $failedChunksArray.Count
        BytesCopied = $profileBytesCopied
        FilesCopied = 0  # Would need per-chunk tracking to calculate accurately
        Duration = $profileDuration
        Errors = @($failedChunksArray | ForEach-Object { "Chunk $($_.ChunkId): $($_.SourcePath)" })
    }

    # Initialize ProfileResults array if needed
    if ($null -eq $state.ProfileResults) {
        $state | Add-Member -MemberType NoteProperty -Name 'ProfileResults' -Value @() -Force
    }
    $state.ProfileResults += $profileResult

    Write-RobocurseLog -Message "Profile complete: $($state.CurrentProfile.Name) in $($profileDuration.ToString('hh\:mm\:ss'))" `
        -Level 'Info' -Component 'Orchestrator'

    Write-SiemEvent -EventType 'ProfileComplete' -Data @{
        profileName = $state.CurrentProfile.Name
        chunksCompleted = $completedChunksArray.Count
        chunksFailed = $failedChunksArray.Count
        durationMs = $profileDuration.TotalMilliseconds
    }

    # Clean up VSS snapshot if one was created for this profile
    if ($state.CurrentVssSnapshot) {
        try {
            Write-RobocurseLog -Message "Cleaning up VSS snapshot: $($state.CurrentVssSnapshot.ShadowId)" -Level 'Info' -Component 'VSS'
            Remove-VssSnapshot -ShadowId $state.CurrentVssSnapshot.ShadowId

            Write-SiemEvent -EventType 'VssSnapshotRemoved' -Data @{
                profileName = $state.CurrentProfile.Name
                shadowId = $state.CurrentVssSnapshot.ShadowId
            }
        }
        catch {
            Write-RobocurseLog -Message "Failed to clean up VSS snapshot: $($_.Exception.Message)" -Level 'Warning' -Component 'VSS'
        }
        finally {
            $state.CurrentVssSnapshot = $null
        }
    }

    # Invoke callback
    if ($script:OnProfileComplete) {
        & $script:OnProfileComplete $state.CurrentProfile
    }

    # Clear completed/failed chunks to prevent memory leak during multi-profile runs
    # Results are preserved in ProfileResults for email/reporting
    $state.CompletedChunks = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
    $state.FailedChunks = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

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
            failedChunks = ($state.ProfileResults | Measure-Object -Property ChunksFailed -Sum).Sum
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

    # Clean up VSS snapshot if one exists
    if ($state.CurrentVssSnapshot) {
        try {
            Write-RobocurseLog -Message "Cleaning up VSS snapshot after stop: $($state.CurrentVssSnapshot.ShadowId)" -Level 'Info' -Component 'VSS'
            Remove-VssSnapshot -ShadowId $state.CurrentVssSnapshot.ShadowId
        }
        catch {
            Write-RobocurseLog -Message "Failed to clean up VSS snapshot: $($_.Exception.Message)" -Level 'Warning' -Component 'VSS'
        }
        finally {
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
    # Use ToArray() for thread-safe snapshot of ConcurrentBag
    $bytesFromCompleted = 0
    foreach ($chunk in $state.CompletedChunks.ToArray()) {
        if ($chunk.EstimatedSize) {
            $bytesFromCompleted += $chunk.EstimatedSize
        }
    }

    # Snapshot ActiveJobs for safe iteration
    $bytesFromActive = 0
    foreach ($kvp in $state.ActiveJobs.ToArray()) {
        $progress = Get-RobocopyProgress -Job $kvp.Value
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
    .NOTES
        Error Behavior: Throws exception with context on failure.
        Requires Administrator privileges.
    .EXAMPLE
        $snapshot = New-VssSnapshot -SourcePath "C:\Users"
        Returns object with shadow copy details
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            if ($_ -match '^\\\\') {
                throw "SourcePath '$_' is a UNC path. VSS snapshots can only be created for local paths (e.g., C:\path)"
            }
            if (-not ($_ -match '^[A-Za-z]:')) {
                throw "SourcePath '$_' must be a local path with a drive letter (e.g., C:\path)"
            }
            $true
        })]
        [string]$SourcePath
    )

    try {
        # Determine volume from path
        $volume = Get-VolumeFromPath -Path $SourcePath
        if (-not $volume) {
            throw "Cannot create VSS snapshot: Unable to determine volume from path '$SourcePath'"
        }

        Write-RobocurseLog -Message "Creating VSS snapshot for volume $volume (from path: $SourcePath)" -Level 'Info' -Component 'VSS'

        # Create shadow copy via CIM (modern replacement for WMI)
        # Note: Requires Administrator privileges
        $result = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{
            Volume = "$volume\"
            Context = "ClientAccessible"
        }

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

        $shadow = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowId }
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
        Write-RobocurseLog -Message "Failed to create VSS snapshot for '$SourcePath': $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        $contextError = [System.Exception]::new(
            "Failed to create VSS snapshot for '$SourcePath': $($_.Exception.Message)",
            $_.Exception
        )
        throw $contextError
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
    .NOTES
        Error Behavior: Throws exception with context on failure.
    .EXAMPLE
        Remove-VssSnapshot -ShadowId "{12345678-1234-1234-1234-123456789012}"
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ShadowId
    )

    try {
        Write-RobocurseLog -Message "Attempting to delete VSS snapshot: $ShadowId" -Level 'Debug' -Component 'VSS'

        $shadow = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $ShadowId }
        if ($shadow) {
            Remove-CimInstance -InputObject $shadow
            Write-RobocurseLog -Message "Deleted VSS snapshot: $ShadowId" -Level 'Info' -Component 'VSS'
        }
        else {
            Write-RobocurseLog -Message "VSS snapshot not found: $ShadowId (may have been already deleted)" -Level 'Warning' -Component 'VSS'
        }
    }
    catch {
        Write-RobocurseLog -Message "Error deleting VSS snapshot $ShadowId : $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        $contextError = [System.Exception]::new(
            "Failed to delete VSS snapshot '$ShadowId': $($_.Exception.Message)",
            $_.Exception
        )
        throw $contextError
    }
}

function Get-VssPath {
    <#
    .SYNOPSIS
        Converts a regular path to its VSS shadow copy equivalent
    .DESCRIPTION
        Translates a path from the original volume to the shadow copy volume.
        Example: C:\Users\John\Documents -> \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Users\John\Documents

        Supports two calling conventions:
        1. With VssSnapshot object (preferred):
           Get-VssPath -OriginalPath "C:\Users" -VssSnapshot $snapshot
        2. With individual parameters (legacy/testing):
           Get-VssPath -OriginalPath "C:\Users" -ShadowPath "\\?\..." -SourceVolume "C:"
    .PARAMETER OriginalPath
        Original path (e.g., C:\Users\John\Documents)
    .PARAMETER VssSnapshot
        VSS snapshot object from New-VssSnapshot (contains ShadowPath and SourceVolume)
    .PARAMETER ShadowPath
        VSS shadow path (e.g., \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1)
        Only required if VssSnapshot is not provided.
    .PARAMETER SourceVolume
        Source volume (e.g., C:)
        Only required if VssSnapshot is not provided.
    .OUTPUTS
        Converted path pointing to shadow copy
    .EXAMPLE
        Get-VssPath -OriginalPath "C:\Users\John\Documents" -VssSnapshot $snapshot
        Returns: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Users\John\Documents
    .EXAMPLE
        Get-VssPath -OriginalPath "C:\Users\John\Documents" `
                    -ShadowPath "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1" `
                    -SourceVolume "C:"
        Returns: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Users\John\Documents
    #>
    param(
        [Parameter(Mandatory)]
        [string]$OriginalPath,

        [Parameter(Mandatory, ParameterSetName = 'VssSnapshot')]
        [PSCustomObject]$VssSnapshot,

        [Parameter(Mandatory, ParameterSetName = 'Individual')]
        [string]$ShadowPath,

        [Parameter(Mandatory, ParameterSetName = 'Individual')]
        [string]$SourceVolume
    )

    # Extract values from VssSnapshot if provided
    if ($PSCmdlet.ParameterSetName -eq 'VssSnapshot') {
        $ShadowPath = $VssSnapshot.ShadowPath
        $SourceVolume = $VssSnapshot.SourceVolume
    }

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
            # UNC path - would need remote CIM session (complex, not supported in v1.0)
            Write-RobocurseLog -Message "VSS not supported for path: $Path (UNC path)" -Level 'Debug' -Component 'VSS'
            return $false
        }

        # Check if CIM is available and we can access Win32_ShadowCopy class
        $shadowClass = Get-CimClass -ClassName Win32_ShadowCopy -ErrorAction Stop
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
    .NOTES
        Error Behavior: Throws exception with context on failure.
        Cleanup is guaranteed via finally block.
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

        $vssPath = Get-VssPath -OriginalPath $SourcePath -VssSnapshot $snapshot

        Write-RobocurseLog -Message "VSS path: $vssPath" -Level 'Debug' -Component 'VSS'

        # Execute the scriptblock with the VSS path
        & $ScriptBlock -VssPath $vssPath
    }
    catch {
        Write-RobocurseLog -Message "Error during VSS snapshot operation for '$SourcePath': $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        $contextError = [System.Exception]::new(
            "Failed to execute VSS snapshot operation for '$SourcePath': $($_.Exception.Message)",
            $_.Exception
        )
        throw $contextError
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
    if (-not (Test-IsWindowsPlatform)) {
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
            Write-RobocurseLog -Message "Failed to read credential from environment: $_" -Level 'Debug' -Component 'Email'
        }
    }

    # Try Windows Credential Manager (Windows only)
    if (Test-IsWindowsPlatform) {
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
    if (-not (Test-IsWindowsPlatform)) {
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
    if (-not (Test-IsWindowsPlatform)) {
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
        [ValidateNotNull()]
        [PSCustomObject]$Config,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSCustomObject]$Results,

        [ValidateSet('Success', 'Warning', 'Failed')]
        [string]$Status = 'Success'
    )

    # Validate Config has required properties
    if ($null -eq $Config.Enabled) {
        throw "Config.Enabled property is required"
    }

    # Check if email is enabled
    if (-not $Config.Enabled) {
        Write-RobocurseLog -Message "Email notifications disabled" -Level 'Debug' -Component 'Email'
        return
    }

    # Validate required configuration properties
    if ([string]::IsNullOrWhiteSpace($Config.SmtpServer)) {
        throw "Config.SmtpServer is required when email is enabled"
    }
    if ([string]::IsNullOrWhiteSpace($Config.From)) {
        throw "Config.From is required when email is enabled"
    }
    if ($null -eq $Config.To -or $Config.To.Count -eq 0) {
        throw "Config.To must contain at least one email address when email is enabled"
    }
    if ($null -eq $Config.Port -or $Config.Port -le 0) {
        throw "Config.Port must be a valid port number when email is enabled"
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
        [ValidateNotNullOrEmpty()]
        [string]$TaskName = "Robocurse-Replication",

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath,

        [ValidateSet('Daily', 'Weekly', 'Hourly')]
        [string]$Schedule = 'Daily',

        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
        [string]$Time = "02:00",

        [ValidateNotNullOrEmpty()]
        [string[]]$DaysOfWeek = @('Sunday'),

        [switch]$RunAsSystem
    )

    try {
        # Check if running on Windows
        if (-not (Test-IsWindowsPlatform)) {
            Write-RobocurseLog -Message "Scheduled tasks are only supported on Windows" -Level 'Warning' -Component 'Scheduler'
            return $false
        }

        # Validate config path exists (inside function body so mocks can intercept)
        if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
            throw "ConfigPath '$ConfigPath' does not exist or is not a file"
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
        if (-not (Test-IsWindowsPlatform)) {
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
        if (-not (Test-IsWindowsPlatform)) {
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
        if (-not (Test-IsWindowsPlatform)) {
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
        if (-not (Test-IsWindowsPlatform)) {
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
        if (-not (Test-IsWindowsPlatform)) {
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
        if (-not (Test-IsWindowsPlatform)) {
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
    if (-not (Test-IsWindowsPlatform)) {
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

    # Parse numeric values with validation and bounds checking
    # ChunkMaxSizeGB: valid range 1-1000 GB
    try {
        $value = [int]$script:Controls.txtMaxSize.Text
        $selected.ChunkMaxSizeGB = [Math]::Max(1, [Math]::Min(1000, $value))
        if ($value -ne $selected.ChunkMaxSizeGB) {
            $script:Controls.txtMaxSize.Text = $selected.ChunkMaxSizeGB.ToString()
        }
    } catch {
        $selected.ChunkMaxSizeGB = 10
        $script:Controls.txtMaxSize.Text = "10"
    }

    # ChunkMaxFiles: valid range 1000-10000000
    try {
        $value = [int]$script:Controls.txtMaxFiles.Text
        $selected.ChunkMaxFiles = [Math]::Max(1000, [Math]::Min(10000000, $value))
        if ($value -ne $selected.ChunkMaxFiles) {
            $script:Controls.txtMaxFiles.Text = $selected.ChunkMaxFiles.ToString()
        }
    } catch {
        $selected.ChunkMaxFiles = 50000
        $script:Controls.txtMaxFiles.Text = "50000"
    }

    # ChunkMaxDepth: valid range 1-20
    try {
        $value = [int]$script:Controls.txtMaxDepth.Text
        $selected.ChunkMaxDepth = [Math]::Max(1, [Math]::Min(20, $value))
        if ($value -ne $selected.ChunkMaxDepth) {
            $script:Controls.txtMaxDepth.Text = $selected.ChunkMaxDepth.ToString()
        }
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

    # Initialize orchestration state before starting background runspace
    # This ensures the same state object is referenced by both threads
    Initialize-OrchestrationState

    # Start replication in a background runspace
    # IMPORTANT: We must dot-source the script to load all functions into the runspace
    # The orchestration state uses concurrent collections for thread-safe sharing

    # Get the path to this script for dot-sourcing into the runspace
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = Join-Path (Get-Location) "Robocurse.ps1"
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    # Execute replication in background
    # We dot-source the script to load functions, pass the shared state, and run
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace

    # Build a script that loads the main script and runs replication
    # Note: We pass the orchestration state as a reference so both threads share it
    # Callbacks are intentionally NOT shared - GUI uses timer-based polling instead
    $backgroundScript = @"
        param(`$ScriptPath, `$SharedState, `$Profiles, `$MaxWorkers, `$ConfigPath)

        # Load the script to get all functions (with -Help to prevent main execution)
        . `$ScriptPath -Help

        # Override the script-scoped state with our shared instance
        # This is safe because ConcurrentDictionary/ConcurrentQueue/ConcurrentBag are thread-safe
        `$script:OrchestrationState = `$SharedState

        # Clear callbacks - GUI mode uses timer-based polling, not callbacks
        # This prevents any thread-safety issues with callback invocation
        `$script:OnProgress = `$null
        `$script:OnChunkComplete = `$null
        `$script:OnProfileComplete = `$null

        # Start replication
        Start-ReplicationRun -Profiles `$Profiles -MaxConcurrentJobs `$MaxWorkers

        # Run the orchestration loop until complete
        while (`$script:OrchestrationState.Phase -notin @('Complete', 'Stopped', 'Idle')) {
            Invoke-ReplicationTick -MaxConcurrentJobs `$MaxWorkers
            Start-Sleep -Milliseconds 250
        }
"@

    $powershell.AddScript($backgroundScript)
    $powershell.AddArgument($scriptPath)
    $powershell.AddArgument($script:OrchestrationState)
    $powershell.AddArgument($profilesToRun)
    $powershell.AddArgument($maxWorkers)
    $powershell.AddArgument($ConfigPath)

    $script:ReplicationHandle = $powershell.BeginInvoke()
    $script:ReplicationPowerShell = $powershell
    $script:ReplicationRunspace = $runspace
}

function Complete-GuiReplication {
    <#
    .SYNOPSIS
        Called when replication completes
    .DESCRIPTION
        Handles GUI cleanup after replication: stops timer, re-enables buttons,
        disposes of background runspace resources, and shows completion message.
    #>

    # Stop timer
    $script:ProgressTimer.Stop()

    # Dispose of background runspace resources to prevent memory leaks
    if ($script:ReplicationPowerShell) {
        try {
            # End the async invocation if still running
            if ($script:ReplicationHandle -and -not $script:ReplicationHandle.IsCompleted) {
                $script:ReplicationPowerShell.Stop()
            }
            elseif ($script:ReplicationHandle) {
                # Collect any remaining output
                $script:ReplicationPowerShell.EndInvoke($script:ReplicationHandle) | Out-Null
            }

            # Dispose the runspace
            if ($script:ReplicationPowerShell.Runspace) {
                $script:ReplicationPowerShell.Runspace.Close()
                $script:ReplicationPowerShell.Runspace.Dispose()
            }

            # Dispose the PowerShell instance
            $script:ReplicationPowerShell.Dispose()
        }
        catch {
            Write-GuiLog "Warning: Error disposing runspace: $($_.Exception.Message)"
        }
        finally {
            $script:ReplicationPowerShell = $null
            $script:ReplicationHandle = $null
        }
    }

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
        Shows schedule configuration dialog and registers/unregisters the scheduled task
    .DESCRIPTION
        Displays a dialog for configuring scheduled runs. When OK is clicked,
        the configuration is saved AND the Windows Task Scheduler task is
        actually created or removed based on the enabled state.
    #>

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Configure Schedule"
        Height="350" Width="450"
        WindowStartupLocation="CenterScreen"
        Background="#1E1E1E">
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <CheckBox x:Name="chkEnabled" Content="Enable Scheduled Runs" Foreground="#E0E0E0" FontWeight="Bold"/>

        <StackPanel Grid.Row="1" Margin="0,15,0,0">
            <Label Content="Run Time (HH:MM):" Foreground="#E0E0E0"/>
            <TextBox x:Name="txtTime" Background="#2D2D2D" Foreground="#E0E0E0" Padding="5" Text="02:00" Width="100" HorizontalAlignment="Left"/>
        </StackPanel>

        <StackPanel Grid.Row="2" Margin="0,15,0,0">
            <Label Content="Frequency:" Foreground="#E0E0E0"/>
            <ComboBox x:Name="cmbFrequency" Background="#2D2D2D" Foreground="#E0E0E0" Width="150" HorizontalAlignment="Left">
                <ComboBoxItem Content="Daily" IsSelected="True"/>
                <ComboBoxItem Content="Weekdays"/>
                <ComboBoxItem Content="Hourly"/>
            </ComboBox>
        </StackPanel>

        <TextBlock Grid.Row="3" x:Name="txtStatus" Foreground="#808080" Margin="0,15,0,0" TextWrapping="Wrap"/>

        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnOk" Content="Apply" Width="80" Margin="0,0,10,0" Background="#0078D4" Foreground="White" Padding="10,5"/>
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
        $txtStatus = $dialog.FindName("txtStatus")
        $btnOk = $dialog.FindName("btnOk")
        $btnCancel = $dialog.FindName("btnCancel")

        # Load current settings
        $chkEnabled.IsChecked = $script:Config.Schedule.Enabled
        $txtTime.Text = if ($script:Config.Schedule.Time) { $script:Config.Schedule.Time } else { "02:00" }

        # Check current task status
        $taskExists = Test-RobocurseTaskExists
        if ($taskExists) {
            $taskInfo = Get-RobocurseTaskStatus
            if ($taskInfo) {
                $txtStatus.Text = "Current task status: $($taskInfo.State)`nNext run: $($taskInfo.NextRunTime)"
            }
        }
        else {
            $txtStatus.Text = "No scheduled task currently configured."
        }

        # Button handlers
        $btnOk.Add_Click({
            try {
                # Parse time
                $timeParts = $txtTime.Text -split ':'
                if ($timeParts.Count -ne 2) {
                    [System.Windows.MessageBox]::Show("Invalid time format. Use HH:MM", "Error", "OK", "Error")
                    return
                }
                $hour = [int]$timeParts[0]
                $minute = [int]$timeParts[1]

                if ($hour -lt 0 -or $hour -gt 23 -or $minute -lt 0 -or $minute -gt 59) {
                    [System.Windows.MessageBox]::Show("Invalid time. Hour must be 0-23, minute must be 0-59", "Error", "OK", "Error")
                    return
                }

                # Determine schedule type
                $scheduleType = switch ($cmbFrequency.Text) {
                    "Daily" { "Daily" }
                    "Weekdays" { "Weekdays" }
                    "Hourly" { "Hourly" }
                    default { "Daily" }
                }

                # Update config
                $script:Config.Schedule.Enabled = $chkEnabled.IsChecked
                $script:Config.Schedule.Time = $txtTime.Text
                $script:Config.Schedule.ScheduleType = $scheduleType

                if ($chkEnabled.IsChecked) {
                    # Register/update the task
                    Write-GuiLog "Registering scheduled task..."

                    # Get the script path for the scheduled task
                    $scriptPath = $PSCommandPath
                    if (-not $scriptPath) {
                        $scriptPath = Join-Path (Get-Location) "Robocurse.ps1"
                    }

                    $result = Register-RobocurseTask `
                        -ScriptPath $scriptPath `
                        -ConfigPath $ConfigPath `
                        -ScheduleType $scheduleType `
                        -Time "$($hour.ToString('00')):$($minute.ToString('00'))"

                    if ($result) {
                        Write-GuiLog "Scheduled task registered successfully"
                        [System.Windows.MessageBox]::Show(
                            "Scheduled task has been registered.`n`nThe task will run $scheduleType at $($txtTime.Text).",
                            "Schedule Configured",
                            "OK",
                            "Information"
                        )
                    }
                    else {
                        Write-GuiLog "Failed to register scheduled task"
                        [System.Windows.MessageBox]::Show(
                            "Failed to register scheduled task.`nCheck that you have administrator privileges.",
                            "Error",
                            "OK",
                            "Error"
                        )
                    }
                }
                else {
                    # Remove the task if it exists
                    if ($taskExists) {
                        Write-GuiLog "Removing scheduled task..."
                        $result = Unregister-RobocurseTask
                        if ($result) {
                            Write-GuiLog "Scheduled task removed"
                            [System.Windows.MessageBox]::Show(
                                "Scheduled task has been removed.",
                                "Schedule Disabled",
                                "OK",
                                "Information"
                            )
                        }
                        else {
                            Write-GuiLog "Failed to remove scheduled task"
                        }
                    }
                }

                Save-RobocurseConfig -Config $script:Config -Path $ConfigPath
                $dialog.Close()
            }
            catch {
                [System.Windows.MessageBox]::Show(
                    "Error configuring schedule: $($_.Exception.Message)",
                    "Error",
                    "OK",
                    "Error"
                )
                Write-GuiLog "Error configuring schedule: $($_.Exception.Message)"
            }
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
    -Profile <name>     Run a specific profile by name
    -AllProfiles        Run all enabled profiles (headless mode only)
    -Help               Display this help message

EXAMPLES:
    .\Robocurse.ps1
        Launch GUI interface

    .\Robocurse.ps1 -Headless -Profile "DailyBackup"
        Run in headless mode with the DailyBackup profile

    .\Robocurse.ps1 -Headless -AllProfiles
        Run all enabled profiles in headless mode

    .\Robocurse.ps1 -ConfigPath "C:\Configs\custom.json" -Headless -AllProfiles
        Run with custom configuration file

For more information, see README.md
"@
}

function Invoke-HeadlessReplication {
    <#
    .SYNOPSIS
        Runs replication in headless mode with progress output and email notification
    .PARAMETER Config
        Configuration object
    .PARAMETER ProfilesToRun
        Array of profile objects to run
    .PARAMETER MaxConcurrentJobs
        Maximum concurrent robocopy processes
    .OUTPUTS
        Exit code: 0 for success, 1 for failures
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory)]
        [PSCustomObject[]]$ProfilesToRun,

        [int]$MaxConcurrentJobs
    )

    $profileNames = ($ProfilesToRun | ForEach-Object { $_.Name }) -join ", "
    Write-Host "Starting replication for profile(s): $profileNames"
    Write-Host "Max concurrent jobs: $MaxConcurrentJobs"
    Write-Host ""

    # Start replication
    Start-ReplicationRun -Profiles $ProfilesToRun -MaxConcurrentJobs $MaxConcurrentJobs

    # Track last progress output time for throttling
    $lastProgressOutput = [datetime]::MinValue
    $progressInterval = [timespan]::FromSeconds(10)

    # Run the orchestration loop with progress output
    while ($script:OrchestrationState.Phase -notin @('Complete', 'Stopped', 'Idle')) {
        Invoke-ReplicationTick -MaxConcurrentJobs $MaxConcurrentJobs

        # Output progress every 10 seconds
        $now = [datetime]::Now
        if (($now - $lastProgressOutput) -gt $progressInterval) {
            $status = Get-OrchestrationStatus
            $progressPct = if ($status.ChunksTotal -gt 0) {
                [math]::Round(($status.ChunksComplete / $status.ChunksTotal) * 100, 1)
            } else { 0 }

            $etaStr = if ($status.ETA) { $status.ETA.ToString('hh\:mm\:ss') } else { "--:--:--" }
            $elapsedStr = $status.Elapsed.ToString('hh\:mm\:ss')
            $bytesStr = Format-FileSize -Bytes $status.BytesComplete

            Write-Host "[${elapsedStr}] Profile: $($status.CurrentProfile) | Progress: ${progressPct}% | Chunks: $($status.ChunksComplete)/$($status.ChunksTotal) | Copied: $bytesStr | ETA: $etaStr"

            $lastProgressOutput = $now
        }

        Start-Sleep -Milliseconds 500
    }

    # Get final status
    $status = Get-OrchestrationStatus
    $totalFailed = if ($script:OrchestrationState.ProfileResults) {
        ($script:OrchestrationState.ProfileResults | Measure-Object -Property ChunksFailed -Sum).Sum
    } else { $status.ChunksFailed }

    # Build results object for email
    $totalBytesCopied = if ($script:OrchestrationState.ProfileResults) {
        ($script:OrchestrationState.ProfileResults | Measure-Object -Property BytesCopied -Sum).Sum
    } else { $status.BytesComplete }

    $allErrors = @()
    if ($script:OrchestrationState.ProfileResults) {
        foreach ($pr in $script:OrchestrationState.ProfileResults) {
            $allErrors += $pr.Errors
        }
    }

    $results = [PSCustomObject]@{
        Duration = $status.Elapsed
        TotalBytesCopied = $totalBytesCopied
        TotalFilesCopied = 0  # Would need chunk-level tracking
        TotalErrors = $totalFailed
        Profiles = $script:OrchestrationState.ProfileResults
        Errors = $allErrors
    }

    # Determine overall status
    $emailStatus = if ($totalFailed -gt 0) { 'Warning' } else { 'Success' }
    if ($script:OrchestrationState.Phase -eq 'Stopped') {
        $emailStatus = 'Failed'
    }

    # Report results to console
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "Replication Complete"
    Write-Host "=========================================="
    Write-Host "  Duration: $($status.Elapsed.ToString('hh\:mm\:ss'))"
    Write-Host "  Total data copied: $(Format-FileSize -Bytes $totalBytesCopied)"
    Write-Host "  Total chunks failed: $totalFailed"
    Write-Host ""

    if ($script:OrchestrationState.ProfileResults) {
        Write-Host "Profile Summary:"
        foreach ($pr in $script:OrchestrationState.ProfileResults) {
            $prStatus = if ($pr.ChunksFailed -gt 0) { "[WARN]" } else { "[OK]" }
            Write-Host "  $prStatus $($pr.Name): $($pr.ChunksComplete)/$($pr.ChunksTotal) chunks, $(Format-FileSize -Bytes $pr.BytesCopied)"
        }
        Write-Host ""
    }

    # Send email notification if configured
    if ($Config.Email -and $Config.Email.Enabled) {
        Write-Host "Sending completion email..."
        try {
            Send-CompletionEmail -Config $Config.Email -Results $results -Status $emailStatus
            Write-Host "Email sent successfully."
        }
        catch {
            Write-Warning "Failed to send email: $($_.Exception.Message)"
        }
    }

    # Return exit code
    if ($totalFailed -gt 0 -or $script:OrchestrationState.Phase -eq 'Stopped') {
        return 1
    }
    return 0
}

function Start-RobocurseMain {
    <#
    .SYNOPSIS
        Main entry point function for Robocurse
    .DESCRIPTION
        Handles parameter validation, configuration loading, and launches
        either GUI or headless mode. Separated from script body for testability.
    #>
    param(
        [switch]$Headless,
        [string]$ConfigPath,
        [string]$ProfileName,
        [switch]$AllProfiles,
        [switch]$ShowHelp
    )

    if ($ShowHelp) {
        Show-RobocurseHelp
        return 0
    }

    try {
        # Load configuration
        if (Test-Path $ConfigPath) {
            $config = Get-RobocurseConfig -Path $ConfigPath
        }
        else {
            Write-Warning "Configuration file not found: $ConfigPath"
            if (-not $Headless) {
                # GUI can create a new config
                $config = New-DefaultConfig
            }
            else {
                throw "Configuration file required for headless mode: $ConfigPath"
            }
        }

        # Launch appropriate interface
        if ($Headless) {
            # Validate headless parameters
            if (-not $ProfileName -and -not $AllProfiles) {
                throw "Headless mode requires either -Profile <name> or -AllProfiles parameter."
            }

            if ($ProfileName -and $AllProfiles) {
                Write-Warning "-Profile and -AllProfiles both specified. Using -Profile '$ProfileName'."
            }

            # Initialize logging for headless mode
            $logRoot = if ($config.GlobalSettings.LogPath) { $config.GlobalSettings.LogPath } else { ".\Logs" }
            $compressDays = if ($config.GlobalSettings.LogCompressAfterDays) { $config.GlobalSettings.LogCompressAfterDays } else { $script:LogCompressAfterDays }
            $deleteDays = if ($config.GlobalSettings.LogRetentionDays) { $config.GlobalSettings.LogRetentionDays } else { $script:LogDeleteAfterDays }
            Initialize-LogSession -LogRoot $logRoot -CompressAfterDays $compressDays -DeleteAfterDays $deleteDays

            # Determine which profiles to run
            $profilesToRun = @()
            if ($ProfileName) {
                # Run specific profile
                $targetProfile = $config.SyncProfiles | Where-Object { $_.Name -eq $ProfileName }
                if (-not $targetProfile) {
                    $availableProfiles = ($config.SyncProfiles | ForEach-Object { $_.Name }) -join ", "
                    throw "Profile '$ProfileName' not found. Available profiles: $availableProfiles"
                }
                $profilesToRun = @($targetProfile)
            }
            else {
                # Run all enabled profiles
                $profilesToRun = @($config.SyncProfiles | Where-Object {
                    # Check for explicit Enabled property, default to true if not present
                    $_.PSObject.Properties['Enabled'] -eq $null -or $_.Enabled -eq $true
                })
                if ($profilesToRun.Count -eq 0) {
                    throw "No enabled profiles found in configuration."
                }
            }

            # Get concurrency settings
            $maxJobs = if ($config.GlobalSettings.MaxConcurrentJobs) {
                $config.GlobalSettings.MaxConcurrentJobs
            } else {
                $script:DefaultMaxConcurrentJobs
            }

            # Run headless replication
            return Invoke-HeadlessReplication -Config $config -ProfilesToRun $profilesToRun -MaxConcurrentJobs $maxJobs
        }
        else {
            # Launch GUI
            $window = Initialize-RobocurseGui
            if ($window) {
                $window.ShowDialog() | Out-Null
                return 0
            }
            else {
                throw "Failed to initialize GUI. Try running with -Headless mode."
            }
        }
    }
    catch {
        Write-Error "Robocurse failed: $_"
        return 1
    }
}

# Main entry point - only execute if not being dot-sourced for testing
# Check if -Help was passed (always process help)
if ($Help) {
    Show-RobocurseHelp
    exit 0
}

# Detect if we're being dot-sourced by checking the call stack
# When dot-sourced, there will be additional stack frames from the calling script
$callStack = Get-PSCallStack
$isBeingDotSourced = $callStack.Count -gt 2

if (-not $isBeingDotSourced) {
    $exitCode = Start-RobocurseMain -Headless:$Headless -ConfigPath $ConfigPath -ProfileName $Profile -AllProfiles:$AllProfiles -ShowHelp:$Help
    exit $exitCode
}

#endregion
