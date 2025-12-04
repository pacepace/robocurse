# Robocurse Configuration Functions

function Format-Json {
    <#
    .SYNOPSIS
        Formats JSON with proper 2-space indentation
    .DESCRIPTION
        PowerShell's ConvertTo-Json produces ugly formatting with 4-space indentation
        and inconsistent spacing. This function reformats JSON to use 2-space indentation
        and consistent property spacing.
    .PARAMETER Json
        The JSON string to format
    .PARAMETER Indent
        Number of spaces per indentation level (default 2)
    .OUTPUTS
        Properly formatted JSON string
    .EXAMPLE
        $obj | ConvertTo-Json -Depth 10 | Format-Json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Json,

        [ValidateRange(1, 8)]
        [int]$Indent = 2
    )

    $indentStr = ' ' * $Indent
    $indentLevel = 0

    $lines = $Json -split "`n"
    $result = foreach ($line in $lines) {
        # Decrease indent for closing brackets
        if ($line -match '^\s*[\}\]]') {
            $indentLevel--
        }

        # Build the formatted line
        $trimmed = $line.TrimStart()
        # Fix spacing: PowerShell adds extra spaces after colons
        $trimmed = $trimmed -replace '":  ', '": '
        $formattedLine = ($indentStr * $indentLevel) + $trimmed

        # Increase indent for opening brackets
        if ($line -match '[\{\[]\s*$') {
            $indentLevel++
        }

        $formattedLine
    }

    $result -join "`n"
}

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
    [CmdletBinding()]
    param()

    $config = [PSCustomObject]@{
        Version = "1.0"
        GlobalSettings = [PSCustomObject]@{
            MaxConcurrentJobs = $script:DefaultMaxConcurrentJobs
            ThreadsPerJob = $script:DefaultThreadsPerJob
            DefaultScanMode = "Smart"
            BandwidthLimitMbps = 0  # 0 = unlimited; set to limit aggregate bandwidth across all jobs
            LogPath = ".\Logs"
            LogCompressAfterDays = $script:LogCompressAfterDays
            LogRetentionDays = $script:LogDeleteAfterDays
            MismatchSeverity = $script:DefaultMismatchSeverity  # "Warning", "Error", or "Success"
            VerboseFileLogging = $false  # If true, log every file copied; if false, only log summary
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
            TaskName = ""  # Custom task name; empty = auto-generate unique name
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

function ConvertTo-RobocopyOptionsInternal {
    <#
    .SYNOPSIS
        Helper to convert raw robocopy config to internal options format
    #>
    [CmdletBinding()]
    param([PSCustomObject]$RawRobocopy)

    $options = @{
        Switches = @()
        ExcludeFiles = @()
        ExcludeDirs = @()
    }

    if ($RawRobocopy) {
        if ($RawRobocopy.switches) {
            $options.Switches = @($RawRobocopy.switches)
        }
        if ($RawRobocopy.excludeFiles) {
            $options.ExcludeFiles = @($RawRobocopy.excludeFiles)
        }
        if ($RawRobocopy.excludeDirs) {
            $options.ExcludeDirs = @($RawRobocopy.excludeDirs)
        }
        if ($RawRobocopy.retryPolicy) {
            if ($RawRobocopy.retryPolicy.count) {
                $options.RetryCount = $RawRobocopy.retryPolicy.count
            }
            if ($RawRobocopy.retryPolicy.wait) {
                $options.RetryWait = $RawRobocopy.retryPolicy.wait
            }
        }
    }

    return $options
}

function ConvertTo-ChunkSettingsInternal {
    <#
    .SYNOPSIS
        Helper to apply chunking settings from raw config to a profile
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject]$Profile,
        [PSCustomObject]$RawChunking
    )

    if ($RawChunking) {
        if ($RawChunking.maxChunkSizeGB) {
            $Profile.ChunkMaxSizeGB = $RawChunking.maxChunkSizeGB
        }
        # Note: parallelChunks from config is intentionally not mapped.
        # Parallelism is controlled by MaxConcurrentJobs at the orchestration level.
        if ($RawChunking.maxDepthToScan) {
            $Profile.ChunkMaxDepth = $RawChunking.maxDepthToScan
        }
        if ($RawChunking.strategy) {
            $Profile.ScanMode = switch ($RawChunking.strategy) {
                'auto' { 'Smart' }
                'balanced' { 'Smart' }
                'aggressive' { 'Smart' }
                'flat' { 'Flat' }
                default { 'Smart' }
            }
        }
    }
}

function Get-DestinationPathFromRaw {
    <#
    .SYNOPSIS
        Helper to extract destination path from raw config (handles multiple formats)
    #>
    [CmdletBinding()]
    param([object]$RawDestination)

    if ($RawDestination -and $RawDestination.path) {
        return $RawDestination.path
    }
    elseif ($RawDestination -is [string]) {
        return $RawDestination
    }
    return ""
}

function ConvertFrom-GlobalSettings {
    <#
    .SYNOPSIS
        Converts global settings from user-friendly to internal format
    .PARAMETER RawGlobal
        Raw global settings object from JSON
    .PARAMETER Config
        Config object to update
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSCustomObject]$RawGlobal,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSCustomObject]$Config
    )

    # Performance settings
    if ($RawGlobal.performance) {
        if ($RawGlobal.performance.maxConcurrentJobs) {
            $Config.GlobalSettings.MaxConcurrentJobs = $RawGlobal.performance.maxConcurrentJobs
        }
        if ($RawGlobal.performance.bandwidthLimitMbps) {
            $Config.GlobalSettings.BandwidthLimitMbps = $RawGlobal.performance.bandwidthLimitMbps
        }
    }

    # Logging settings
    if ($RawGlobal.logging) {
        if ($RawGlobal.logging.operationalLog) {
            if ($RawGlobal.logging.operationalLog.path) {
                # Use the log path directly (don't use Split-Path which breaks relative paths like ".\Logs")
                $Config.GlobalSettings.LogPath = $RawGlobal.logging.operationalLog.path
            }
            if ($RawGlobal.logging.operationalLog.rotation -and $RawGlobal.logging.operationalLog.rotation.maxAgeDays) {
                $Config.GlobalSettings.LogRetentionDays = $RawGlobal.logging.operationalLog.rotation.maxAgeDays
            }
        }
        # Verbose file logging - log every file name if true (default: false for smaller logs)
        if ($null -ne $RawGlobal.logging.verboseFileLogging) {
            $Config.GlobalSettings.VerboseFileLogging = [bool]$RawGlobal.logging.verboseFileLogging
        }
    }

    # Email settings
    if ($RawGlobal.email) {
        $Config.Email.Enabled = [bool]$RawGlobal.email.enabled
        if ($RawGlobal.email.smtp) {
            $Config.Email.SmtpServer = $RawGlobal.email.smtp.server
            $Config.Email.Port = if ($RawGlobal.email.smtp.port) { $RawGlobal.email.smtp.port } else { 587 }
            $Config.Email.UseTls = [bool]$RawGlobal.email.smtp.useSsl
            if ($RawGlobal.email.smtp.credentialName) {
                $Config.Email.CredentialTarget = $RawGlobal.email.smtp.credentialName
            }
        }
        if ($RawGlobal.email.from) { $Config.Email.From = $RawGlobal.email.from }
        if ($RawGlobal.email.to) { $Config.Email.To = @($RawGlobal.email.to) }
    }
}


function ConvertFrom-FriendlyConfig {
    <#
    .SYNOPSIS
        Converts user-friendly JSON config format to internal format
    .DESCRIPTION
        The JSON config file uses a user-friendly format with:
        - "profiles" as an object with profile names as keys (one source per profile)
        - "global" with nested settings

        This function converts to the internal format with:
        - "SyncProfiles" as an array of profile objects
        - "GlobalSettings" with flattened settings
    .PARAMETER RawConfig
        Raw config object loaded from JSON
    .OUTPUTS
        PSCustomObject in internal format
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$RawConfig
    )

    $props = $RawConfig.PSObject.Properties.Name

    # Validate this is the friendly format
    if ($props -notcontains 'profiles') {
        throw "Invalid config format: missing 'profiles' property. Config must use the friendly format."
    }

    # Start with default config as base
    $config = New-DefaultConfig

    # Transform global settings
    if ($props -contains 'global') {
        ConvertFrom-GlobalSettings -RawGlobal $RawConfig.global -Config $config
    }

    # Transform profiles - each profile has exactly one source
    $syncProfiles = @()
    if ($RawConfig.profiles) {
        $profileNames = $RawConfig.profiles.PSObject.Properties.Name
        foreach ($profileName in $profileNames) {
            $rawProfile = $RawConfig.profiles.$profileName

            # Skip disabled profiles
            if ($null -ne $rawProfile.enabled -and $rawProfile.enabled -eq $false) {
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
                ChunkMaxSizeGB = $script:DefaultMaxChunkSizeBytes / 1GB
                ChunkMaxFiles = $script:DefaultMaxFilesPerChunk
                ChunkMaxDepth = $script:DefaultMaxChunkDepth
                RobocopyOptions = @{}
                Enabled = $true
            }

            # Handle source - "source" property (string or object with path/useVss)
            if ($rawProfile.source) {
                if ($rawProfile.source -is [string]) {
                    $syncProfile.Source = $rawProfile.source
                }
                elseif ($rawProfile.source.path) {
                    $syncProfile.Source = $rawProfile.source.path
                    if ($null -ne $rawProfile.source.useVss) {
                        $syncProfile.UseVss = [bool]$rawProfile.source.useVss
                    }
                }
            }

            # Handle destination
            $syncProfile.Destination = Get-DestinationPathFromRaw -RawDestination $rawProfile.destination

            # Apply chunking settings
            ConvertTo-ChunkSettingsInternal -Profile $syncProfile -RawChunking $rawProfile.chunking

            # Handle robocopy settings
            $robocopyOptions = ConvertTo-RobocopyOptionsInternal -RawRobocopy $rawProfile.robocopy

            # Handle retry policy
            if ($rawProfile.retryPolicy) {
                if ($rawProfile.retryPolicy.maxRetries) {
                    $robocopyOptions.RetryCount = $rawProfile.retryPolicy.maxRetries
                }
                if ($rawProfile.retryPolicy.retryDelayMinutes) {
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

function ConvertTo-FriendlyConfig {
    <#
    .SYNOPSIS
        Converts internal config format to user-friendly JSON format
    .DESCRIPTION
        Converts the internal format (SyncProfiles array, GlobalSettings) back to
        the user-friendly format (profiles object, global nested settings).
    .PARAMETER Config
        Internal config object
    .OUTPUTS
        PSCustomObject in friendly format ready for JSON serialization
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    # Build friendly format
    $friendly = [ordered]@{
        version = "1.0"
        profiles = [ordered]@{}
        global = [ordered]@{
            performance = [ordered]@{
                maxConcurrentJobs = $Config.GlobalSettings.MaxConcurrentJobs
                throttleNetworkMbps = $Config.GlobalSettings.BandwidthLimitMbps
            }
            logging = [ordered]@{
                operationalLog = [ordered]@{
                    path = $Config.GlobalSettings.LogPath
                    rotation = [ordered]@{
                        maxAgeDays = $Config.GlobalSettings.LogRetentionDays
                    }
                }
                verboseFileLogging = $Config.GlobalSettings.VerboseFileLogging
            }
            email = [ordered]@{
                enabled = $Config.Email.Enabled
                smtp = [ordered]@{
                    server = $Config.Email.SmtpServer
                    port = $Config.Email.Port
                    useSsl = $Config.Email.UseTls
                    credentialName = $Config.Email.CredentialTarget
                }
                from = $Config.Email.From
                to = @($Config.Email.To)
            }
        }
    }

    # Convert each sync profile
    foreach ($profile in $Config.SyncProfiles) {
        $friendlyProfile = [ordered]@{
            description = $profile.Description
            enabled = if ($null -ne $profile.Enabled) { $profile.Enabled } else { $true }
            source = [ordered]@{
                path = $profile.Source
                useVss = $profile.UseVss
            }
            destination = [ordered]@{
                path = $profile.Destination
            }
            chunking = [ordered]@{
                maxChunkSizeGB = $profile.ChunkMaxSizeGB
                maxFiles = $profile.ChunkMaxFiles
                maxDepthToScan = $profile.ChunkMaxDepth
                strategy = switch ($profile.ScanMode) {
                    'Smart' { 'auto' }
                    'Flat' { 'flat' }
                    default { 'auto' }
                }
            }
        }

        # Add robocopy options if present
        if ($profile.RobocopyOptions) {
            $robocopy = [ordered]@{}
            if ($profile.RobocopyOptions.Switches) {
                $robocopy.switches = @($profile.RobocopyOptions.Switches)
            }
            if ($profile.RobocopyOptions.ExcludeFiles) {
                $robocopy.excludeFiles = @($profile.RobocopyOptions.ExcludeFiles)
            }
            if ($profile.RobocopyOptions.ExcludeDirs) {
                $robocopy.excludeDirs = @($profile.RobocopyOptions.ExcludeDirs)
            }
            if ($robocopy.Count -gt 0) {
                $friendlyProfile.robocopy = $robocopy
            }
        }

        $friendly.profiles[$profile.Name] = [PSCustomObject]$friendlyProfile
    }

    return [PSCustomObject]$friendly
}

function Get-RobocurseConfig {
    <#
    .SYNOPSIS
        Loads configuration from JSON file
    .DESCRIPTION
        Loads and parses the Robocurse configuration from a JSON file.
        The config file must use the friendly format with:
        - "profiles" object containing named profiles (one source per profile)
        - "global" object with nested settings

        If the file doesn't exist, returns a default configuration.
        Handles malformed JSON gracefully by returning default config with a verbose message.
    .PARAMETER Path
        Path to the configuration JSON file. Defaults to .\Robocurse.config.json
    .OUTPUTS
        PSCustomObject with configuration in internal format
    .NOTES
        Error Behavior: Returns default configuration on error. Never throws.
        Use -Verbose to see error details.
    .EXAMPLE
        $config = Get-RobocurseConfig
        Loads configuration from default path
    .EXAMPLE
        $config = Get-RobocurseConfig -Path "C:\Configs\custom.json"
        Loads configuration from custom path
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = ".\Robocurse.config.json"
    )

    # Validate path safety to prevent path traversal attacks
    if (-not (Test-SafeConfigPath -Path $Path)) {
        Write-Warning "Configuration path '$Path' contains unsafe characters or patterns. Using default configuration."
        return New-DefaultConfig
    }

    # Return default config if file doesn't exist
    if (-not (Test-Path -Path $Path)) {
        Write-Verbose "Configuration file not found at '$Path'. Returning default configuration."
        return New-DefaultConfig
    }

    # Try to load and parse the JSON file
    try {
        $jsonContent = Get-Content -Path $Path -Raw -ErrorAction Stop
        $rawConfig = $jsonContent | ConvertFrom-Json -ErrorAction Stop

        # Convert from friendly format to internal format
        $config = ConvertFrom-FriendlyConfig -RawConfig $rawConfig

        # Validate configuration and log any warnings
        $validation = Test-RobocurseConfig -Config $config
        if (-not $validation.IsValid) {
            foreach ($err in $validation.Errors) {
                Write-Warning "Configuration validation: $err"
            }
            # Still return the config - let the caller decide if validation errors are fatal
        }

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
        Saves configuration to a JSON file in friendly format
    .DESCRIPTION
        Saves the configuration object to a JSON file with pretty formatting.
        The config is always saved in the user-friendly format with:
        - "profiles" object containing named profiles
        - "global" object with nested settings

        Creates the parent directory if it doesn't exist.
    .PARAMETER Config
        Configuration object to save (PSCustomObject in internal format)
    .PARAMETER Path
        Path to save the configuration file. Defaults to .\Robocurse.config.json
    .OUTPUTS
        OperationResult - Success=$true with Data=$Path on success, Success=$false with ErrorMessage on failure
    .EXAMPLE
        $config = New-DefaultConfig
        $result = Save-RobocurseConfig -Config $config
        if ($result.Success) { "Saved to $($result.Data)" }
    .EXAMPLE
        $result = Save-RobocurseConfig -Config $config -Path "C:\Configs\custom.json"
        if (-not $result.Success) { Write-Error $result.ErrorMessage }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $false)]
        [string]$Path = ".\Robocurse.config.json"
    )

    # Validate path safety to prevent writing to unauthorized locations
    if (-not (Test-SafeConfigPath -Path $Path)) {
        return New-OperationResult -Success $false -ErrorMessage "Configuration path '$Path' contains unsafe characters or patterns"
    }

    try {
        # Get the parent directory
        $parentDir = Split-Path -Path $Path -Parent

        # Create parent directory if it doesn't exist
        if ($parentDir -and -not (Test-Path -Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction Stop | Out-Null
            Write-Verbose "Created directory: $parentDir"
        }

        # Convert to friendly format before saving
        $friendlyConfig = ConvertTo-FriendlyConfig -Config $Config

        # Convert to JSON with proper 2-space indentation
        $jsonContent = $friendlyConfig | ConvertTo-Json -Depth 10 | Format-Json
        $jsonContent | Set-Content -Path $Path -Encoding UTF8 -ErrorAction Stop

        Write-Verbose "Configuration saved successfully to '$Path'"
        return New-OperationResult -Success $true -Data $Path
    }
    catch {
        Write-Verbose "Failed to save configuration to '$Path': $($_.Exception.Message)"
        return New-OperationResult -Success $false -ErrorMessage "Failed to save configuration to '$Path': $($_.Exception.Message)" -ErrorRecord $_
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
    [CmdletBinding()]
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

        # Validate BandwidthLimitMbps (0 = unlimited, positive = limit in Mbps)
        if ($gsPropertyNames -contains 'BandwidthLimitMbps') {
            $bandwidthLimit = $gs.BandwidthLimitMbps
            if ($null -ne $bandwidthLimit -and $bandwidthLimit -lt 0) {
                $errors += "GlobalSettings.BandwidthLimitMbps must be non-negative (current: $bandwidthLimit)"
            }
        }
    }

    # Validate Email configuration if enabled
    if (($configPropertyNames -contains 'Email') -and $Config.Email.Enabled -eq $true) {
        $email = $Config.Email
        $emailPropertyNames = if ($email.PSObject) { $email.PSObject.Properties.Name } else { @() }

        if ([string]::IsNullOrWhiteSpace($email.SmtpServer)) {
            $errors += "Email.SmtpServer is required when Email.Enabled is true"
        }

        if ([string]::IsNullOrWhiteSpace($email.From)) {
            $errors += "Email.From is required when Email.Enabled is true"
        }
        elseif ($email.From -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            # Stricter pattern: no multiple @ symbols, no whitespace
            $errors += "Email.From is not a valid email address format: $($email.From)"
        }

        if (-not $email.To -or $email.To.Count -eq 0) {
            $errors += "Email.To must contain at least one recipient when Email.Enabled is true"
        }
        else {
            # Validate each recipient email format (stricter: no multiple @, no whitespace)
            $toArray = @($email.To)
            for ($j = 0; $j -lt $toArray.Count; $j++) {
                if ($toArray[$j] -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                    $errors += "Email.To[$j] is not a valid email address format: $($toArray[$j])"
                }
            }
        }

        # Validate port if specified
        if ($emailPropertyNames -contains 'Port' -and $null -ne $email.Port) {
            if ($email.Port -lt 1 -or $email.Port -gt 65535) {
                $errors += "Email.Port must be between 1 and 65535 (current: $($email.Port))"
            }
        }
    }

    # Validate SyncProfiles
    # Wrap in @() to ensure array-like behavior even if a single profile object is provided
    # PowerShell's .Count on a single object can be unreliable
    if (($configPropertyNames -contains 'SyncProfiles') -and $Config.SyncProfiles) {
        $profilesArray = @($Config.SyncProfiles)
        for ($i = 0; $i -lt $profilesArray.Count; $i++) {
            $profile = $profilesArray[$i]
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

            # Validate chunk configuration if present
            if ($propertyNames -contains 'ChunkMaxFiles') {
                $maxFiles = $profile.ChunkMaxFiles
                if ($null -ne $maxFiles -and ($maxFiles -lt 1 -or $maxFiles -gt 10000000)) {
                    $errors += "$profilePrefix.ChunkMaxFiles must be between 1 and 10000000 (current: $maxFiles)"
                }
            }

            if ($propertyNames -contains 'ChunkMaxSizeGB') {
                $maxSizeGB = $profile.ChunkMaxSizeGB
                if ($null -ne $maxSizeGB -and ($maxSizeGB -lt 0.001 -or $maxSizeGB -gt 1024)) {
                    $errors += "$profilePrefix.ChunkMaxSizeGB must be between 0.001 and 1024 (current: $maxSizeGB)"
                }
            }

            # Validate that ChunkMaxSizeGB > ChunkMinSizeGB if both are specified
            if (($propertyNames -contains 'ChunkMaxSizeGB') -and ($propertyNames -contains 'ChunkMinSizeGB')) {
                $maxSizeGB = $profile.ChunkMaxSizeGB
                $minSizeGB = $profile.ChunkMinSizeGB
                if ($null -ne $maxSizeGB -and $null -ne $minSizeGB -and $maxSizeGB -le $minSizeGB) {
                    $errors += "$profilePrefix.ChunkMaxSizeGB ($maxSizeGB) must be greater than ChunkMinSizeGB ($minSizeGB)"
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
    [CmdletBinding()]
    param(
        [string]$Path
    )

    # Empty or whitespace paths are invalid
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    # Check for invalid characters that are not allowed in Windows paths
    # Valid paths can be: UNC (\\server\share) or local (C:\path or .\path or relative)
    $invalidChars = [System.IO.Path]::GetInvalidPathChars() + @('|', '>', '<', '"', '?', '*')

    foreach ($char in $invalidChars) {
        if ($Path.Contains($char)) {
            return $false
        }
    }

    # Basic format validation for UNC or local paths
    # UNC: \\server\share or \\server\share\path
    # Absolute: C:\ or C:\path
    # Relative explicit: .\ or .\path or ..\ or ..\path
    # Relative implicit: folder\subfolder or folder (no leading specifier)
    if ($Path -match '^\\\\[^\\]+\\[^\\]+' -or     # UNC path (\\server\share...)
        $Path -match '^[a-zA-Z]:\\' -or             # Absolute local path (C:\...)
        $Path -match '^[a-zA-Z]:$' -or              # Drive root without backslash (C:)
        $Path -match '^\.\\' -or                    # Explicit relative path (.\...)
        $Path -match '^\.\.[\\]?' -or               # Parent relative path (..\... or ..)
        $Path -match '^\.$' -or                     # Current directory (.)
        $Path -match '^[a-zA-Z0-9_\-]') {           # Implicit relative path (folder\... or folder)
        return $true
    }

    return $false
}
