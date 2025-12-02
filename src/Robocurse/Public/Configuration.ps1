# Robocurse Configuration Functions
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
            BandwidthLimitMbps = 0  # 0 = unlimited; set to limit aggregate bandwidth across all jobs
            LogPath = ".\Logs"
            LogCompressAfterDays = $script:LogCompressAfterDays
            LogRetentionDays = $script:LogDeleteAfterDays
            MismatchSeverity = $script:DefaultMismatchSeverity  # "Warning", "Error", or "Success"
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

function ConvertTo-RobocopyOptionsInternal {
    <#
    .SYNOPSIS
        Helper to convert raw robocopy config to internal options format
    #>
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
    param(
        [PSCustomObject]$Profile,
        [PSCustomObject]$RawChunking
    )

    if ($RawChunking) {
        if ($RawChunking.maxChunkSizeGB) {
            $Profile.ChunkMaxSizeGB = $RawChunking.maxChunkSizeGB
        }
        if ($RawChunking.parallelChunks) {
            $Profile | Add-Member -MemberType NoteProperty -Name 'ParallelChunks' -Value $RawChunking.parallelChunks -Force
        }
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
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$RawGlobal,

        [Parameter(Mandatory)]
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
    if ($RawGlobal.logging -and $RawGlobal.logging.operationalLog) {
        if ($RawGlobal.logging.operationalLog.path) {
            $logPath = Split-Path -Path $RawGlobal.logging.operationalLog.path -Parent
            $Config.GlobalSettings.LogPath = $logPath
        }
        if ($RawGlobal.logging.operationalLog.rotation -and $RawGlobal.logging.operationalLog.rotation.maxAgeDays) {
            $Config.GlobalSettings.LogRetentionDays = $RawGlobal.logging.operationalLog.rotation.maxAgeDays
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

function ConvertFrom-ProfileSources {
    <#
    .SYNOPSIS
        Expands multi-source profiles into separate sync profiles
    .PARAMETER ProfileName
        Name of the parent profile
    .PARAMETER RawProfile
        Raw profile object from JSON
    .OUTPUTS
        Array of expanded sync profile objects
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName,

        [Parameter(Mandatory)]
        [PSCustomObject]$RawProfile
    )

    $expandedProfiles = @()
    $description = if ($RawProfile.description) { $RawProfile.description } else { "" }

    # Handle null or missing sources array
    if ($null -eq $RawProfile.sources -or $RawProfile.sources.Count -eq 0) {
        Write-RobocurseLog -Message "Profile '$ProfileName' has no sources defined, skipping" -Level 'Warning' -Component 'Config'
        return $expandedProfiles
    }

    for ($i = 0; $i -lt $RawProfile.sources.Count; $i++) {
        $sourceInfo = $RawProfile.sources[$i]
        $expandedProfile = [PSCustomObject]@{
            Name = "$ProfileName-Source$($i + 1)"
            Description = "$description (Source $($i + 1))"
            Source = $sourceInfo.path
            Destination = Get-DestinationPathFromRaw -RawDestination $RawProfile.destination
            UseVss = [bool]$sourceInfo.useVss
            ScanMode = "Smart"
            ChunkMaxSizeGB = 10
            ChunkMaxFiles = 50000
            ChunkMaxDepth = 5
            RobocopyOptions = ConvertTo-RobocopyOptionsInternal -RawRobocopy $RawProfile.robocopy
            Enabled = $true
            ParentProfile = $ProfileName
        }

        ConvertTo-ChunkSettingsInternal -Profile $expandedProfile -RawChunking $RawProfile.chunking
        $expandedProfiles += $expandedProfile
    }

    return $expandedProfiles
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
        ConvertFrom-GlobalSettings -RawGlobal $RawConfig.global -Config $config
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

            # Handle multi-source profiles (expand into separate sync profiles)
            if ($rawProfile.sources -and $rawProfile.sources.Count -gt 1) {
                Write-Verbose "Profile '$profileName' has $($rawProfile.sources.Count) sources - expanding"
                $syncProfiles += ConvertFrom-ProfileSources -ProfileName $profileName -RawProfile $rawProfile
                continue
            }

            # Build single sync profile
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

            # Handle source - single source from array or direct property
            if ($rawProfile.sources -and $rawProfile.sources.Count -eq 1) {
                $syncProfile.Source = $rawProfile.sources[0].path
                $syncProfile.UseVss = [bool]$rawProfile.sources[0].useVss
            }
            elseif ($rawProfile.source) {
                $syncProfile.Source = $rawProfile.source
            }

            # Handle destination using helper
            $syncProfile.Destination = Get-DestinationPathFromRaw -RawDestination $rawProfile.destination

            # Apply chunking settings using helper
            ConvertTo-ChunkSettingsInternal -Profile $syncProfile -RawChunking $rawProfile.chunking

            # Handle robocopy settings using helper
            $robocopyOptions = ConvertTo-RobocopyOptionsInternal -RawRobocopy $rawProfile.robocopy

            # Handle retry policy (alternative location in config)
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
        Saves configuration to a JSON file
    .DESCRIPTION
        Saves the configuration object to a JSON file with pretty formatting.
        Creates the parent directory if it doesn't exist.
    .PARAMETER Config
        Configuration object to save (PSCustomObject)
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
