# Robocurse Development Notes

## PowerShell Runspace Object Passing

PSCustomObject NoteProperties DO survive `AddArgument()`. However, for cleaner code, the background runspace re-reads profiles from config file by name:

```powershell
# Pass profile names (strings), not objects
$profileNames = @($profilesToRun | ForEach-Object { $_.Name })
$powershell.AddArgument($profileNames)

# In background - look up from fresh config
$bgConfig = Get-RobocurseConfig -Path $ConfigPath
$profiles = @($bgConfig.SyncProfiles | Where-Object { $ProfileNames -contains $_.Name })
```

For mutable shared state (progress updates), use C# class with locking - see `OrchestrationState` in Orchestration.ps1.

## Robocopy /L List Mode

For directory profiling, use a random temp path as destination (not `\\?\NULL` which doesn't work on all Windows versions, and not src=dest which doesn't list files):

```powershell
$nullDest = Join-Path $env:TEMP "robocurse-null-$(Get-Random)"
$output = & robocopy $Source $nullDest /L /E /NJH /NJS /BYTES /R:0 /W:0 2>&1
```

Output format is `New File [size] [name]` and `New Dir [count] [path]` - parse accordingly.

## Build Commands

```powershell
# Run all tests (USE THIS - writes to temp files to avoid truncation)
.\scripts\run-tests.ps1

# Run specific test file
Invoke-Pester -Path tests\Unit\Configuration.Tests.ps1 -Output Detailed

# Run only unit tests (faster)
Invoke-Pester -Path tests\Unit -Output Detailed

# Run with code coverage
Invoke-Pester -Path tests -CodeCoverage src\Robocurse\Public\*.ps1

# List skipped tests only
$r = Invoke-Pester -Path tests -PassThru -Output None; $r.Skipped.ExpandedPath

# Build monolith
.\build\Build-Robocurse.ps1
```

## Avoiding Test Output Truncation

**IMPORTANT:** When running tests, use `.\scripts\run-tests.ps1` instead of `Invoke-Pester` directly. This script writes results to temp files to avoid truncation issues that cause infinite retry loops.

Output files:
- `$env:TEMP\pester-summary.txt` - Pass/fail counts
- `$env:TEMP\pester-failures.txt` - Failed test names and error messages

To read failure details after running tests:
```powershell
Get-Content $env:TEMP\pester-failures.txt
```

**Note:** Some tests skip based on environment:
- Remote VSS tests require `$env:ROBOCURSE_TEST_REMOTE_SHARE` set to a UNC path
- Platform-specific tests skip on non-Windows (scheduling, VSS, robocopy)

## Logging Security Considerations

**DEBUG logs contain sensitive path information** and should be treated as confidential:
- Full file paths including project/directory names are logged at DEBUG level
- Robocopy command lines with source/destination paths are logged
- VSS junction paths and shadow copy IDs are logged

**Recommendations:**
- Keep DEBUG-level logs secure and restrict access
- Consider redacting paths in production environments if logs are shared
- SIEM logs (JSON Lines format) contain structured path data for auditing

## VSS Retry Logic

Both local and remote VSS operations use the same retry pattern for transient errors:

**Retryable HRESULT codes:**
- `0x8004230F` - VSS_E_INSUFFICIENT_STORAGE (might clear up)
- `0x80042316` - VSS_E_SNAPSHOT_SET_IN_PROGRESS (another snapshot in progress)
- `0x80042302` - VSS_E_OBJECT_NOT_FOUND (transient state)
- `0x80042317` - VSS_E_MAXIMUM_NUMBER_OF_VOLUMES_REACHED (might clear after cleanup)
- `0x8004231F` - VSS_E_WRITERERROR_TIMEOUT (writer timeout)
- `0x80042325` - VSS_E_FLUSH_WRITES_TIMEOUT (flush timeout)

**English fallback patterns** (for errors without HRESULT):
- `busy`, `timeout`, `lock`, `in use`, `try again`

See `Test-VssErrorRetryable` in VssCore.ps1 for the shared implementation.
