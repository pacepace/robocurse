# Task 05: Extract Magic Numbers to Configuration Constants

## Priority: MEDIUM

## Problem Statement

The codebase contains hardcoded "magic numbers" scattered throughout, making them hard to find, understand, and modify:

```powershell
$MaxSizeBytes = 10GB      # Why 10GB?
$MaxFiles = 50000         # Why 50000?
$MaxDepth = 5             # Why 5?
$chunk.RetryCount -lt 3   # Why 3 retries?
$ThreadsPerJob = 8        # Why 8?
$CacheMaxAgeHours = 24    # Why 24?
```

## Research Required

### Code Research
1. Search `Robocurse.ps1` for numeric literals:
   - Default parameter values
   - Comparison values in conditionals
   - Array/collection sizes
   - Time-related values

2. Identify constants in these categories:
   - **Chunking**: Size limits, file counts, depth limits
   - **Retry Logic**: Retry counts, delays
   - **Threading**: Thread counts, concurrent jobs
   - **Caching**: Cache durations
   - **Logging**: Retention periods, rotation thresholds
   - **Timeouts**: Various operation timeouts

3. Review `New-DefaultConfig` to see what's already configurable:
   ```powershell
   MaxConcurrentJobs = 4
   ThreadsPerJob = 8
   LogRetentionDays = 30
   ```

### Search Patterns
```powershell
# Find numeric literals
Select-String -Path Robocurse.ps1 -Pattern '\d+GB|\d+MB|\d+KB|\b\d{2,}\b'

# Find default parameter values
Select-String -Path Robocurse.ps1 -Pattern '=\s*\d+[,\)]'
```

## Constants to Extract

### Chunking Constants
| Current Location | Value | Suggested Constant Name |
|-----------------|-------|------------------------|
| `Get-DirectoryChunks` param | `10GB` | `$script:DefaultMaxChunkSizeBytes` |
| `Get-DirectoryChunks` param | `50000` | `$script:DefaultMaxFilesPerChunk` |
| `Get-DirectoryChunks` param | `5` | `$script:DefaultMaxChunkDepth` |
| `Get-DirectoryChunks` param | `100MB` | `$script:DefaultMinChunkSizeBytes` |

### Retry Constants
| Current Location | Value | Suggested Constant Name |
|-----------------|-------|------------------------|
| `Handle-FailedChunk` | `3` | `$script:MaxChunkRetries` |
| `Start-RobocopyJob` args | `3` | `$script:RobocopyRetryCount` |
| `Start-RobocopyJob` args | `10` | `$script:RobocopyRetryWaitSeconds` |

### Threading Constants
| Current Location | Value | Suggested Constant Name |
|-----------------|-------|------------------------|
| `Start-RobocopyJob` param | `8` | `$script:DefaultThreadsPerJob` |
| Various | `4` | `$script:DefaultMaxConcurrentJobs` |

### Cache/Time Constants
| Current Location | Value | Suggested Constant Name |
|-----------------|-------|------------------------|
| `Get-DirectoryProfile` | `24` | `$script:ProfileCacheMaxAgeHours` |
| `Invoke-LogRotation` | `7` | `$script:LogCompressAfterDays` |
| `Invoke-LogRotation` | `30` | `$script:LogDeleteAfterDays` |

## Implementation Pattern

### Create a Constants Region
Add near the top of the script, after the param block:

```powershell
#region ==================== CONSTANTS ====================

# Chunking defaults
$script:DefaultMaxChunkSizeBytes = 10GB
$script:DefaultMaxFilesPerChunk = 50000
$script:DefaultMaxChunkDepth = 5
$script:DefaultMinChunkSizeBytes = 100MB

# Retry policy
$script:MaxChunkRetries = 3
$script:RobocopyRetryCount = 3
$script:RobocopyRetryWaitSeconds = 10

# Threading
$script:DefaultThreadsPerJob = 8
$script:DefaultMaxConcurrentJobs = 4

# Caching
$script:ProfileCacheMaxAgeHours = 24

# Logging
$script:LogCompressAfterDays = 7
$script:LogDeleteAfterDays = 30

#endregion
```

### Update Function Defaults
```powershell
function Get-DirectoryChunks {
    param(
        [int64]$MaxSizeBytes = $script:DefaultMaxChunkSizeBytes,
        [int]$MaxFiles = $script:DefaultMaxFilesPerChunk,
        [int]$MaxDepth = $script:DefaultMaxChunkDepth,
        [int64]$MinSizeBytes = $script:DefaultMinChunkSizeBytes,
        ...
    )
```

### Update Hardcoded Comparisons
```powershell
# Before
if ($chunk.RetryCount -lt 3 -and $Result.ExitMeaning.ShouldRetry) {

# After
if ($chunk.RetryCount -lt $script:MaxChunkRetries -and $Result.ExitMeaning.ShouldRetry) {
```

## Files to Modify

- `Robocurse.ps1` - Add constants region, update all references
- `tests/Unit/*.Tests.ps1` - Update tests if they rely on specific values

## Documentation

Add comments explaining each constant:

```powershell
# Maximum size for a single chunk. Larger directories will be split.
# 10GB is chosen to balance parallelism vs. overhead.
$script:DefaultMaxChunkSizeBytes = 10GB

# Maximum retry attempts for failed chunks before marking as permanently failed.
# 3 retries handles transient network issues without indefinite loops.
$script:MaxChunkRetries = 3
```

## Success Criteria

1. [ ] All magic numbers identified and documented
2. [ ] Constants region created with descriptive names
3. [ ] All function defaults reference constants
4. [ ] All hardcoded comparisons use constants
5. [ ] Each constant has a comment explaining its purpose
6. [ ] Constants are script-scoped (not global)
7. [ ] All existing tests still pass
8. [ ] Tests can be run with: `Invoke-Pester -Path tests/ -Output Detailed`

## Testing Commands

```powershell
# Run all tests to ensure no regressions
Invoke-Pester -Path tests/ -Output Detailed

# Verify constants are accessible
. .\Robocurse.ps1 -Help
$script:DefaultMaxChunkSizeBytes  # Should return 10737418240 (10GB)
```

## Estimated Complexity

Low-Medium - Mostly mechanical changes but requires thoroughness.
