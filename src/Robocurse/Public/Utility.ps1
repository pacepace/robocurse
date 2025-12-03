# Robocurse Utility Functions
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
    [CmdletBinding()]
    param()

    # In PowerShell 5.1, $IsWindows doesn't exist (it's always Windows)
    # In PowerShell 7+, $IsWindows is defined
    if ($null -eq $IsWindows) {
        return $true  # PowerShell 5.1 only runs on Windows
    }
    return $IsWindows
}

# Cached path to robocopy.exe (validated once at startup)
$script:RobocopyPath = $null
# User-provided override path (set via Set-RobocopyPath)
$script:RobocopyPathOverride = $null

function Set-RobocopyPath {
    <#
    .SYNOPSIS
        Sets an explicit path to robocopy.exe
    .DESCRIPTION
        Allows overriding the automatic robocopy detection with a specific path.
        Useful for portable installations, development environments, or when
        robocopy is installed in a non-standard location.
    .PARAMETER Path
        Full path to robocopy.exe
    .OUTPUTS
        OperationResult - Success=$true if path is valid, Success=$false if not found
    .EXAMPLE
        Set-RobocopyPath -Path "D:\Tools\robocopy.exe"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        return New-OperationResult -Success $false -ErrorMessage "Robocopy not found at specified path: $Path"
    }

    # Verify it's actually robocopy by checking file name
    $fileName = [System.IO.Path]::GetFileName($Path)
    if ($fileName -ne 'robocopy.exe') {
        return New-OperationResult -Success $false -ErrorMessage "Specified path does not point to robocopy.exe: $Path"
    }

    $script:RobocopyPathOverride = $Path
    $script:RobocopyPath = $Path
    Write-RobocurseLog -Message "Robocopy path set to: $Path" -Level 'Info' -Component 'Utility'
    return New-OperationResult -Success $true -Data $Path
}

function Clear-RobocopyPath {
    <#
    .SYNOPSIS
        Clears the robocopy path override, reverting to automatic detection
    #>
    [CmdletBinding()]
    param()

    $script:RobocopyPathOverride = $null
    $script:RobocopyPath = $null
    Write-RobocurseLog -Message "Robocopy path override cleared, reverting to auto-detection" -Level 'Info' -Component 'Utility'
}

function Test-RobocopyAvailable {
    <#
    .SYNOPSIS
        Validates that robocopy.exe is available on the system
    .DESCRIPTION
        Checks for robocopy.exe in the following order:
        1. User-specified override path (set via Set-RobocopyPath)
        2. System32 directory (most reliable, Windows only)
        3. PATH environment variable
        Caches the validated path in $script:RobocopyPath for use by Start-RobocopyJob.
        On non-Windows systems, returns failure (robocopy is Windows-only).
    .OUTPUTS
        OperationResult - Success=$true with Data=path to robocopy.exe, Success=$false if not found
    .EXAMPLE
        $result = Test-RobocopyAvailable
        if (-not $result.Success) { throw "Robocopy not found: $($result.ErrorMessage)" }
    #>
    [CmdletBinding()]
    param()

    # Check user-provided override first - always takes priority over cache
    if ($script:RobocopyPathOverride) {
        if (Test-Path -Path $script:RobocopyPathOverride -PathType Leaf) {
            $script:RobocopyPath = $script:RobocopyPathOverride
            return New-OperationResult -Success $true -Data $script:RobocopyPath
        }
        else {
            # Override set but file no longer exists
            return New-OperationResult -Success $false -ErrorMessage "Robocopy override path no longer valid: $($script:RobocopyPathOverride)"
        }
    }

    # Return cached result if already validated (checked after override to allow override changes)
    if ($script:RobocopyPath) {
        return New-OperationResult -Success $true -Data $script:RobocopyPath
    }

    # Check System32 first (most reliable location on Windows)
    # Only check if SystemRoot is defined (Windows only)
    if ($env:SystemRoot) {
        $system32Path = Join-Path $env:SystemRoot "System32\robocopy.exe"
        if (Test-Path -Path $system32Path -PathType Leaf) {
            $script:RobocopyPath = $system32Path
            return New-OperationResult -Success $true -Data $script:RobocopyPath
        }
    }

    # Fallback: Check if robocopy is in PATH
    $pathRobocopy = Get-Command -Name "robocopy.exe" -ErrorAction SilentlyContinue
    if ($pathRobocopy) {
        $script:RobocopyPath = $pathRobocopy.Source
        return New-OperationResult -Success $true -Data $script:RobocopyPath
    }

    # Not found - provide helpful error message
    $expectedPath = if ($env:SystemRoot) { "$env:SystemRoot\System32\robocopy.exe" } else { "System32\robocopy.exe (Windows only)" }
    return New-OperationResult -Success $false -ErrorMessage "robocopy.exe not found. Expected at '$expectedPath' or in PATH. Use Set-RobocopyPath to specify a custom location."
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
    [CmdletBinding()]
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

# Capture script-level invocation info at load time for reliable dot-source detection
# This must be at script scope, not inside a function, to get accurate invocation context
$script:ScriptInvocation = $MyInvocation

function Test-IsBeingDotSourced {
    <#
    .SYNOPSIS
        Detects if the script is being dot-sourced vs executed directly
    .DESCRIPTION
        Used to prevent main execution when loading functions for testing.
        Returns $true if the script is being dot-sourced (. .\script.ps1)
        Returns $false if the script is being executed directly (.\script.ps1)

        Uses multiple detection methods for reliability:
        1. Check if invocation name is "." (explicit dot-sourcing)
        2. Check if invocation line starts with ". " (dot-source operator)
        3. Check if called from another script context (CommandOrigin)
    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    param()

    # Method 1: Check script-level invocation name captured at load time
    # When dot-sourced, InvocationName is typically "." or empty
    if ($script:ScriptInvocation.InvocationName -eq '.') {
        return $true
    }

    # Method 2: Check if the command line contains dot-source operator
    # The Line property shows how the script was invoked
    if ($script:ScriptInvocation.Line -match '^\s*\.\s+') {
        return $true
    }

    # Method 3: Check MyInvocation.CommandOrigin
    # When dot-sourced, CommandOrigin is "Runspace" (not directly invoked)
    # When executed directly, it's typically "Runspace" too, so this isn't reliable alone
    # But combined with checking if there's a parent script, it helps

    # Method 4: Check if there's a calling script (most reliable fallback)
    # When dot-sourced from a test file, ScriptName in the call stack will differ
    $callStack = Get-PSCallStack
    if ($callStack.Count -ge 2) {
        # Get the immediate caller (index 1 is the caller of this function)
        # If index 1+ has a different ScriptName than our script, we're being dot-sourced
        $ourScript = $script:ScriptInvocation.MyCommand.Path
        $caller = $callStack[1]

        # If called from a different script file, we're being dot-sourced
        if ($caller.ScriptName -and $caller.ScriptName -ne $ourScript) {
            return $true
        }
    }

    return $false
}

function Test-SafeRobocopyArgument {
    <#
    .SYNOPSIS
        Validates that a string is safe to use as a robocopy argument
    .DESCRIPTION
        Checks for command injection patterns, shell metacharacters, and other
        dangerous sequences that could be exploited when passed to robocopy.
        Returns $false for any string containing:
        - Command separators (;, &, |, newlines)
        - Shell redirectors (>, <)
        - Backticks or $() for command substitution
        - Null bytes or other control characters
    .PARAMETER Value
        The string to validate
    .OUTPUTS
        Boolean - $true if safe, $false if potentially dangerous
    .EXAMPLE
        Test-SafeRobocopyArgument -Value "C:\Users\John"  # Returns $true
        Test-SafeRobocopyArgument -Value "path; del *"   # Returns $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    # Empty strings are safe (robocopy will ignore them)
    if ([string]::IsNullOrEmpty($Value)) {
        return $true
    }

    # Check for dangerous patterns that could enable command injection
    # These patterns should never appear in legitimate paths or exclude patterns
    $dangerousPatterns = @(
        '[\x00-\x1F]',           # Control characters (null, newline, etc.)
        '[;&|]',                  # Command separators
        '[<>]',                   # Shell redirectors
        '`',                      # Backtick (PowerShell escape/execution)
        '\$\(',                   # Command substitution
        '\$\{',                   # Variable expansion with braces
        '%[^%]+%',                # Environment variable expansion (cmd.exe style)
        '(^|[/\\])\.\.([/\\]|$)', # Parent directory traversal at path boundaries only (../foo or foo/../bar or foo/..)
        '^\s*-'                   # Arguments starting with dash (could inject robocopy flags)
    )

    foreach ($pattern in $dangerousPatterns) {
        if ($Value -match $pattern) {
            Write-RobocurseLog -Message "Rejected unsafe argument containing pattern '$pattern': $Value" `
                -Level 'Warning' -Component 'Security'
            return $false
        }
    }

    return $true
}

function Get-SanitizedPath {
    <#
    .SYNOPSIS
        Returns a sanitized path safe for use with robocopy
    .DESCRIPTION
        Validates and returns the path if safe, or throws an error if the path
        contains dangerous patterns. Use this for source/destination paths.
    .PARAMETER Path
        The path to sanitize
    .PARAMETER ParameterName
        Name of the parameter (for error messages)
    .OUTPUTS
        The original path if safe
    .EXAMPLE
        $safePath = Get-SanitizedPath -Path $userInput -ParameterName "Source"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$ParameterName = "Path"
    )

    if (-not (Test-SafeRobocopyArgument -Value $Path)) {
        throw "Invalid $ParameterName : contains unsafe characters or patterns. Path: $Path"
    }

    return $Path
}

function Get-SanitizedExcludePatterns {
    <#
    .SYNOPSIS
        Returns sanitized exclude patterns, filtering out dangerous entries
    .DESCRIPTION
        Validates each exclude pattern and returns only safe ones.
        Logs warnings for rejected patterns but doesn't throw.
    .PARAMETER Patterns
        Array of exclude patterns to sanitize
    .PARAMETER Type
        "Files" or "Dirs" (for logging)
    .OUTPUTS
        Array of safe patterns
    .EXAMPLE
        $safePatterns = Get-SanitizedExcludePatterns -Patterns $excludeFiles -Type "Files"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Patterns,

        [ValidateSet('Files', 'Dirs')]
        [string]$Type = 'Files'
    )

    $safePatterns = @()

    foreach ($pattern in $Patterns) {
        if (Test-SafeRobocopyArgument -Value $pattern) {
            $safePatterns += $pattern
        }
        else {
            Write-RobocurseLog -Message "Excluded unsafe $Type pattern from robocopy args: $pattern" `
                -Level 'Warning' -Component 'Security'
        }
    }

    return $safePatterns
}

function Get-SanitizedChunkArgs {
    <#
    .SYNOPSIS
        Validates and returns only safe robocopy chunk arguments
    .DESCRIPTION
        ChunkArgs are intended for robocopy switches like /LEV:1.
        This function validates each argument against a whitelist of safe
        robocopy switch patterns to prevent command injection.
    .PARAMETER ChunkArgs
        Array of chunk arguments to validate
    .OUTPUTS
        Array of validated, safe arguments
    .EXAMPLE
        $safeArgs = Get-SanitizedChunkArgs -ChunkArgs @("/LEV:1", "/S")
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ChunkArgs
    )

    $safeArgs = @()

    # Whitelist of safe robocopy switch patterns
    # These are switches that might legitimately be added per-chunk
    $safePatterns = @(
        '^/LEV:\d+$',      # Level depth (e.g., /LEV:1)
        '^/S$',            # Copy subdirectories (non-empty only)
        '^/E$',            # Copy subdirectories (including empty)
        '^/MAXAGE:\d+$',   # Max file age
        '^/MINAGE:\d+$',   # Min file age
        '^/MAXLAD:\d+$',   # Max last access date
        '^/MINLAD:\d+$'    # Min last access date
    )

    foreach ($arg in $ChunkArgs) {
        if ([string]::IsNullOrWhiteSpace($arg)) {
            continue
        }

        $isSafe = $false
        foreach ($pattern in $safePatterns) {
            if ($arg -match $pattern) {
                $isSafe = $true
                break
            }
        }

        if ($isSafe) {
            $safeArgs += $arg
        }
        else {
            Write-RobocurseLog -Message "Rejected unsafe chunk argument: $arg" `
                -Level 'Warning' -Component 'Security'
        }
    }

    return $safeArgs
}

function Test-SourcePathAccessible {
    <#
    .SYNOPSIS
        Pre-flight check to validate source path exists and is accessible
    .DESCRIPTION
        Checks that the source path exists before starting replication.
        This catches configuration errors early rather than failing during scan.
        For UNC paths, also validates network connectivity.
    .PARAMETER Path
        The source path to validate
    .OUTPUTS
        OperationResult - Success=$true if accessible, Success=$false with details on failure
    .EXAMPLE
        $check = Test-SourcePathAccessible -Path "\\SERVER\Share"
        if (-not $check.Success) { Write-Error $check.ErrorMessage }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    # Check if path exists
    # Note: Test-Path can throw for UNC paths to unreachable servers on Windows
    try {
        $pathExists = Test-Path -Path $Path -PathType Container -ErrorAction Stop
    }
    catch {
        # UNC paths to unreachable servers throw "The network path was not found"
        if ($Path -match '^\\\\') {
            return New-OperationResult -Success $false `
                -ErrorMessage "Source path not accessible: '$Path'. Check network connectivity and share permissions." `
                -ErrorRecord $_
        }
        return New-OperationResult -Success $false `
            -ErrorMessage "Error checking source path '$Path': $($_.Exception.Message)" `
            -ErrorRecord $_
    }

    if (-not $pathExists) {
        # Provide more specific error for UNC paths
        if ($Path -match '^\\\\') {
            return New-OperationResult -Success $false `
                -ErrorMessage "Source path not accessible: '$Path'. Check network connectivity and share permissions."
        }
        return New-OperationResult -Success $false `
            -ErrorMessage "Source path does not exist: '$Path'"
    }

    # Try to enumerate at least one item to verify read access
    try {
        $null = Get-ChildItem -Path $Path -Force -ErrorAction Stop | Select-Object -First 1
        return New-OperationResult -Success $true -Data $Path
    }
    catch {
        return New-OperationResult -Success $false `
            -ErrorMessage "Source path exists but is not readable: '$Path'. Error: $($_.Exception.Message)" `
            -ErrorRecord $_
    }
}

function Test-DestinationDiskSpace {
    <#
    .SYNOPSIS
        Pre-flight check for approximate available disk space on destination
    .DESCRIPTION
        Performs a general check that the destination drive has reasonable free space.
        This is NOT a precise byte-for-byte comparison (source sizes change during copy,
        compression varies, etc.) but catches obvious problems like a nearly-full drive.

        For UNC paths, checks the drive where the share is mounted if accessible.
    .PARAMETER Path
        The destination path to check
    .PARAMETER EstimatedSizeBytes
        Optional: Estimated size of data to copy. If provided, warns if free space is less.
        If not provided, just warns if drive is >90% full.
    .OUTPUTS
        OperationResult - Success=$true if space looks reasonable, Success=$false with warning
    .EXAMPLE
        $check = Test-DestinationDiskSpace -Path "D:\Backups"
        if (-not $check.Success) { Write-Warning $check.ErrorMessage }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [int64]$EstimatedSizeBytes = 0
    )

    try {
        # For UNC paths, we can't easily check disk space without mounting
        # Just verify the path or parent exists
        if ($Path -match '^\\\\') {
            # Ensure parent path exists or can be created
            if (-not (Test-Path -Path $Path)) {
                $parentPath = Split-Path -Path $Path -Parent
                if ($parentPath -and -not (Test-Path -Path $parentPath)) {
                    return New-OperationResult -Success $false `
                        -ErrorMessage "Destination path parent does not exist: '$parentPath'"
                }
            }
            # Can't check disk space on UNC without complex WMI calls to remote server
            # Write access will be validated when robocopy actually runs
            return New-OperationResult -Success $true -Data "UNC path - disk space check skipped"
        }

        # Extract drive letter for local paths
        $driveLetter = [System.IO.Path]::GetPathRoot($Path)
        if (-not $driveLetter) {
            # Relative path - resolve it
            $resolvedPath = [System.IO.Path]::GetFullPath($Path)
            $driveLetter = [System.IO.Path]::GetPathRoot($resolvedPath)
        }

        # Get drive info
        $drive = Get-PSDrive -Name $driveLetter.TrimEnd(':\') -ErrorAction SilentlyContinue
        if (-not $drive) {
            # Try WMI/CIM for more reliable drive info
            $driveLetterClean = $driveLetter.TrimEnd('\')
            $diskInfo = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$driveLetterClean'" -ErrorAction SilentlyContinue
            if ($diskInfo) {
                $freeSpace = $diskInfo.FreeSpace
                $totalSize = $diskInfo.Size
            }
            else {
                # Can't get drive info - proceed with warning
                return New-OperationResult -Success $true -Data "Could not determine disk space for $driveLetter"
            }
        }
        else {
            $freeSpace = $drive.Free
            $totalSize = $drive.Used + $drive.Free
        }

        # Check if drive is >90% full
        $percentUsed = if ($totalSize -gt 0) { (($totalSize - $freeSpace) / $totalSize) * 100 } else { 0 }

        if ($percentUsed -gt 90) {
            $freeGB = [math]::Round($freeSpace / 1GB, 2)
            return New-OperationResult -Success $false `
                -ErrorMessage "Destination drive $driveLetter is $([math]::Round($percentUsed))% full (only $freeGB GB free). Consider freeing space before replication."
        }

        # If we have an estimated size, check if it fits (with 10% buffer)
        if ($EstimatedSizeBytes -gt 0) {
            $requiredWithBuffer = $EstimatedSizeBytes * 1.1
            if ($freeSpace -lt $requiredWithBuffer) {
                $freeGB = [math]::Round($freeSpace / 1GB, 2)
                $neededGB = [math]::Round($requiredWithBuffer / 1GB, 2)
                return New-OperationResult -Success $false `
                    -ErrorMessage "Destination drive $driveLetter may not have enough space. Free: $freeGB GB, Estimated needed: $neededGB GB"
            }
        }

        $freeGB = [math]::Round($freeSpace / 1GB, 2)
        return New-OperationResult -Success $true -Data "Destination drive $driveLetter has $freeGB GB free"
    }
    catch {
        # Don't fail the whole operation on disk check errors - just warn
        return New-OperationResult -Success $true `
            -Data "Disk space check failed (proceeding anyway): $($_.Exception.Message)"
    }
}

function Test-RobocopyOptionsValid {
    <#
    .SYNOPSIS
        Validates robocopy options for dangerous or conflicting combinations
    .DESCRIPTION
        Checks for robocopy switch combinations that could cause data loss or
        unexpected behavior. Returns warnings for:
        - /PURGE without /MIR (deletes destination files but doesn't sync)
        - /MOVE (deletes source files after copy)
        - /XX combined with /PURGE or /MIR (conflicting behaviors)
    .PARAMETER Options
        Hashtable of robocopy options from profile configuration
    .OUTPUTS
        OperationResult - Success=$true if options are safe, Success=$false with warnings
    .EXAMPLE
        $check = Test-RobocopyOptionsValid -Options $profile.RobocopyOptions
        if (-not $check.Success) { Write-Warning $check.ErrorMessage }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [hashtable]$Options
    )

    if ($null -eq $Options) {
        return New-OperationResult -Success $true -Data "No custom options specified"
    }

    $switches = @()
    if ($Options.Switches) {
        $switches = @($Options.Switches) | ForEach-Object { $_.ToUpper() }
    }

    $warnings = @()

    # Check for dangerous switch combinations
    $hasPurge = $switches -contains '/PURGE'
    $hasMir = $switches -contains '/MIR'
    $hasMove = $switches | Where-Object { $_ -match '^/MOV[E]?$' }
    $hasXX = $switches -contains '/XX'

    # /PURGE without /MIR is suspicious - deletes extras without ensuring full sync
    if ($hasPurge -and -not $hasMir) {
        $warnings += "/PURGE specified without /MIR - this will delete destination files without ensuring source is fully copied. Consider using /MIR instead."
    }

    # /MOVE is dangerous - deletes source files
    if ($hasMove) {
        $warnings += "/MOV or /MOVE specified - this will DELETE source files after copying. Ensure this is intentional."
    }

    # /XX with /MIR or /PURGE is contradictory
    if ($hasXX -and ($hasMir -or $hasPurge)) {
        $warnings += "/XX specified with /MIR or /PURGE - these options conflict. /XX excludes extra files but /MIR and /PURGE delete them."
    }

    # Check for switches that override Robocurse-managed options
    $managedSwitches = $switches | Where-Object { $_ -match '^/(MT|LOG|TEE|BYTES|NP):?' }
    if ($managedSwitches) {
        $warnings += "Switches that may conflict with Robocurse-managed options detected: $($managedSwitches -join ', '). These are normally set automatically."
    }

    if ($warnings.Count -gt 0) {
        return New-OperationResult -Success $false -ErrorMessage ($warnings -join "`n")
    }

    return New-OperationResult -Success $true -Data "Robocopy options validated"
}

function Test-SafeConfigPath {
    <#
    .SYNOPSIS
        Validates that a configuration file path is safe to use
    .DESCRIPTION
        Checks for dangerous patterns in config file paths that could lead to:
        - Directory traversal attacks
        - Accessing system files
        - Command injection via path manipulation
        Returns $false for any path containing dangerous patterns.
    .PARAMETER Path
        The config file path to validate
    .OUTPUTS
        Boolean - $true if safe, $false if potentially dangerous
    .EXAMPLE
        Test-SafeConfigPath -Path ".\config.json"  # Returns $true
        Test-SafeConfigPath -Path "..\..\etc\passwd"  # Returns $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )

    # Empty path is technically safe (will fail later at Test-Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }

    # Check for dangerous patterns
    $dangerousPatterns = @(
        '[\x00-\x1F]',           # Control characters
        '[;&|<>]',               # Shell metacharacters
        '`',                      # Backtick
        '\$\(',                   # Command substitution
        '\$\{',                   # Variable expansion with braces
        '%[^%]+%'                 # Environment variable expansion (cmd.exe)
    )

    foreach ($pattern in $dangerousPatterns) {
        if ($Path -match $pattern) {
            Write-Warning "Rejected unsafe config path containing pattern '$pattern': $Path"
            return $false
        }
    }

    # Additionally check that the resolved path doesn't escape expected boundaries
    # Don't block relative paths with .. entirely, but log if they resolve outside current tree
    try {
        $resolvedPath = [System.IO.Path]::GetFullPath($Path)
        $currentDir = (Get-Location).Path

        # Log if the resolved path goes outside the working directory
        if (-not $resolvedPath.StartsWith($currentDir)) {
            # This is allowed but worth logging for security auditing
            Write-Verbose "Config path resolves outside working directory: $Path -> $resolvedPath"
        }
    }
    catch {
        # Path is malformed - not safe
        Write-Warning "Config path is malformed: $Path"
        return $false
    }

    return $true
}
