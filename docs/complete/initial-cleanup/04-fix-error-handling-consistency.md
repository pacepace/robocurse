# Task 04: Standardize Error Handling Strategy

## Priority: MEDIUM

## Problem Statement

The codebase has inconsistent error handling patterns:

**Pattern A - Graceful Return (Swallow errors):**
```powershell
# Get-RobocurseConfig
catch {
    Write-Warning "Failed to load configuration..."
    return New-DefaultConfig  # Returns default, doesn't throw
}
```

**Pattern B - Throw (Propagate errors):**
```powershell
# New-VssSnapshot
catch {
    Write-RobocurseLog -Message "Failed to create VSS snapshot..." -Level 'Error'
    throw  # Re-throws the error
}
```

**Pattern C - Silent Failure:**
```powershell
# Some functions just return $null or empty on error
catch {
    return @()  # Caller has no idea an error occurred
}
```

This inconsistency makes it hard to know how to handle errors at call sites.

## Research Required

### Code Research
1. Audit all try/catch blocks in `Robocurse.ps1`:
   - Document current error handling pattern for each
   - Categorize by: Throws, Returns Default, Returns Null, Logs Only

2. Identify error categories:
   - **Recoverable**: Missing file, network timeout (retry makes sense)
   - **Configuration**: Bad input, validation failure (fail fast)
   - **System**: VSS failure, permission denied (may need user action)

3. Review how callers handle errors:
   - Do they check return values?
   - Do they wrap calls in try/catch?

### Functions to Audit
Search for: `catch {` in Robocurse.ps1

Expected locations:
- Configuration functions
- Logging functions
- VSS functions
- Email functions
- Robocopy wrapper functions
- Orchestration functions

## Recommended Error Handling Strategy

### Principle: Fail Fast for Configuration, Graceful for Runtime

| Function Category | Strategy | Rationale |
|------------------|----------|-----------|
| Config loading | Return default + warning | Script should still run |
| Config validation | Return error object | Caller decides what to do |
| VSS operations | Throw | Critical failure, can't proceed |
| Robocopy operations | Return result object with error info | Job management needs to handle failures |
| Email operations | Log + return false | Non-critical, shouldn't stop replication |
| Logging operations | Write-Warning only | Can't log the logging failure! |

### Implementation Pattern - Result Objects

For functions that can fail in expected ways, return a result object:

```powershell
function Invoke-SomeOperation {
    param(...)

    try {
        # ... operation ...
        return [PSCustomObject]@{
            Success = $true
            Result = $actualResult
            Error = $null
        }
    }
    catch {
        Write-RobocurseLog -Message "Operation failed: $_" -Level 'Error'
        return [PSCustomObject]@{
            Success = $false
            Result = $null
            Error = $_.Exception.Message
        }
    }
}
```

### Implementation Pattern - Throw with Context

For functions that should propagate errors, add context:

```powershell
function New-VssSnapshot {
    param([string]$SourcePath)

    try {
        # ... VSS creation ...
    }
    catch {
        $contextError = [System.Exception]::new(
            "Failed to create VSS snapshot for '$SourcePath': $($_.Exception.Message)",
            $_.Exception
        )
        throw $contextError
    }
}
```

## Files to Modify

- `Robocurse.ps1` - Standardize error handling in all try/catch blocks
- Possibly add a helper function for consistent error result creation

## Specific Changes Needed

### 1. Configuration Functions
- `Get-RobocurseConfig` - Current: return default. Keep, but log at Info level not Warning.
- `Save-RobocurseConfig` - Current: return $false. Keep, appropriate pattern.
- `Test-RobocurseConfig` - Current: returns object. Keep, good pattern.

### 2. Logging Functions
- `Write-RobocurseLog` - Current: Write-Warning. Keep, can't throw in logger.
- `Write-SiemEvent` - Current: Write-Warning. Keep, can't throw in logger.

### 3. VSS Functions
- `New-VssSnapshot` - Current: throws. Keep, but add context.
- `Remove-VssSnapshot` - Current: throws. Keep, but add context.
- `Invoke-WithVssSnapshot` - Current: throws from inner. Add better cleanup on error.

### 4. Email Functions
- `Send-CompletionEmail` - Should catch all exceptions and return false (never throw).
- `Get-SmtpCredential` - Should return $null on error, not throw.

### 5. Robocopy Functions
- `Start-RobocopyJob` - Should throw on startup failure (can't recover).
- `Parse-RobocopyLog` - Current: returns zeros on error. Keep, appropriate.

## Success Criteria

1. [ ] All try/catch blocks audited and documented
2. [ ] Error handling follows consistent patterns by category
3. [ ] Thrown errors include context (what operation, what input)
4. [ ] Functions that return on error are documented in their help
5. [ ] No "silent failures" - all errors at least logged
6. [ ] Tests verify error behavior where appropriate
7. [ ] All existing tests still pass

## Testing Commands

```powershell
# Run all tests to ensure no regressions
Invoke-Pester -Path tests/ -Output Detailed
```

## Estimated Complexity

Medium - Requires careful analysis but changes are straightforward.
