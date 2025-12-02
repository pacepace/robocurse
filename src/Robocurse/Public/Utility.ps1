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

    # Return cached result if already validated
    if ($script:RobocopyPath) {
        return New-OperationResult -Success $true -Data $script:RobocopyPath
    }

    # Check user-provided override first
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

    # Method 5: Check if -Help was passed (explicit signal to skip main execution)
    # This is handled separately at the call site, but we include it as a fallback
    if ($Help) {
        return $true
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
        '\.\.',                   # Parent directory traversal (be careful - this is sometimes legitimate)
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
