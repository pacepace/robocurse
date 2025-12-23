# Task 06: Fix Logging Before Session Initialization

## Priority: MEDIUM

## Problem Statement

Several functions call `Write-RobocurseLog` before a logging session has been initialized, causing warning spam:

```powershell
function Write-RobocurseLog {
    ...
    $logPath = $script:CurrentOperationalLogPath

    if (-not $logPath) {
        Write-Warning "No log session initialized. Call Initialize-LogSession first."
        return  # Warning output but nothing logged
    }
```

Functions that may log before initialization:
- `Get-DirectoryProfile` - Called during scanning phase
- `Get-CachedProfile` - Called by Get-DirectoryProfile
- `Set-CachedProfile` - Called by Get-DirectoryProfile
- `Convert-ToDestinationPath` - Called during chunking
- Various VSS functions

## Research Required

### Code Research
1. Trace the initialization flow:
   - When is `Initialize-LogSession` called?
   - What happens if the script is dot-sourced for testing?
   - What happens in GUI mode vs headless mode?

2. Find all `Write-RobocurseLog` calls and categorize by:
   - Called during initialization (before log session exists)
   - Called during normal operation (after log session exists)
   - Called during testing (may not have log session)

3. Review test setup:
   - Do tests call `Initialize-LogSession`?
   - How do tests handle logging?

### Key Questions
- Should logging silently fail before initialization, or buffer messages?
- Should we auto-initialize on first log write?
- How should test mode handle logging?

## Implementation Options

### Option A: Auto-Initialize Logging
If no log session exists, create one automatically:

```powershell
function Write-RobocurseLog {
    ...
    if (-not $script:CurrentOperationalLogPath) {
        # Auto-initialize with defaults
        Initialize-LogSession | Out-Null
    }
    ...
}
```

**Pros**: Always works, no warning spam
**Cons**: May create logs in unexpected locations

### Option B: Silent Failure with Verbose
Change from Write-Warning to Write-Verbose:

```powershell
function Write-RobocurseLog {
    ...
    if (-not $script:CurrentOperationalLogPath) {
        Write-Verbose "Logging skipped: No log session initialized"
        return
    }
    ...
}
```

**Pros**: Clean output, still diagnosable with -Verbose
**Cons**: Silent loss of log messages

### Option C: Test Mode Flag
Add a test mode that suppresses logging:

```powershell
# At script level
$script:SuppressLogging = $false

function Write-RobocurseLog {
    ...
    if ($script:SuppressLogging) { return }
    if (-not $script:CurrentOperationalLogPath) {
        Write-Verbose "Logging skipped: No log session initialized"
        return
    }
    ...
}
```

Tests would set `$script:SuppressLogging = $true`.

### Option D: Console Fallback
If no log file, write to console with prefix:

```powershell
function Write-RobocurseLog {
    ...
    $logEntry = "${timestamp} [${levelUpper}] [${Component}] ${Message}"

    if (-not $script:CurrentOperationalLogPath) {
        # Fallback to console
        switch ($Level) {
            'Error'   { Write-Error $logEntry }
            'Warning' { Write-Warning $logEntry }
            'Debug'   { Write-Debug $logEntry }
            default   { Write-Host $logEntry }
        }
        return
    }
    ...
}
```

**Pros**: No lost messages, appropriate output streams
**Cons**: May be noisy in some scenarios

## Recommended Approach

**Combination of Option B and D:**
1. Change the "no session" warning to Write-Verbose
2. For Error and Warning levels, use console output as fallback
3. For Info and Debug levels, silently skip if no session

```powershell
function Write-RobocurseLog {
    param(...)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $levelUpper = $Level.ToUpper()
    $logEntry = "${timestamp} [${levelUpper}] [${Component}] ${Message}"

    # Check if log session is initialized
    if (-not $script:CurrentOperationalLogPath) {
        # For important messages, fall back to console
        if ($Level -in @('Error', 'Warning')) {
            switch ($Level) {
                'Error'   { Write-Error $logEntry }
                'Warning' { Write-Warning $logEntry }
            }
        }
        # For Info/Debug, silently skip (or use Write-Verbose)
        return
    }

    # ... rest of function
}
```

## Files to Modify

- `Robocurse.ps1` - Update `Write-RobocurseLog` and possibly `Write-SiemEvent`
- `tests/Unit/Logging.Tests.ps1` - Add tests for pre-initialization behavior

## Test Cases to Add

```powershell
Context "Logging Before Initialization" {
    BeforeEach {
        # Ensure no session
        $script:CurrentOperationalLogPath = $null
    }

    It "Should not throw when logging before initialization" {
        { Write-RobocurseLog -Message "Test" -Level "Info" } | Should -Not -Throw
    }

    It "Should output warnings to console when no session" {
        $output = Write-RobocurseLog -Message "Test warning" -Level "Warning" 3>&1
        $output | Should -Match "Test warning"
    }

    It "Should silently skip debug messages when no session" {
        $output = Write-RobocurseLog -Message "Debug msg" -Level "Debug" 5>&1
        # No output expected (or Write-Verbose output if -Verbose)
    }
}
```

## Success Criteria

1. [ ] No more "No log session initialized" warnings during normal operation
2. [ ] Error and Warning messages still visible even without log session
3. [ ] Info and Debug messages silently skip if no session
4. [ ] Tests work correctly without initializing log sessions
5. [ ] Normal operation still logs to files correctly
6. [ ] All existing tests still pass
7. [ ] Tests can be run with: `Invoke-Pester -Path tests/Unit/Logging.Tests.ps1`

## Testing Commands

```powershell
# Run logging tests
Invoke-Pester -Path tests/Unit/Logging.Tests.ps1 -Output Detailed

# Test pre-initialization behavior manually
. .\Robocurse.ps1 -Help
Write-RobocurseLog -Message "Test before init" -Level "Warning"
# Should see warning on console, no error
```

## Estimated Complexity

Low - Focused change to one or two functions.
