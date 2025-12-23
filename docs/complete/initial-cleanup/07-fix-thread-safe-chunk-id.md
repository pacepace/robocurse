# Task 07: Make Chunk ID Generation Thread-Safe

## Priority: LOW

## Problem Statement

The chunk ID counter uses simple increment which could cause race conditions if parallelization is increased:

```powershell
$script:ChunkIdCounter = 0

function New-Chunk {
    ...
    $script:ChunkIdCounter++

    $chunk = [PSCustomObject]@{
        ChunkId = $script:ChunkIdCounter
        ...
    }
```

If multiple threads call `New-Chunk` simultaneously, they could get duplicate IDs.

## Research Required

### Code Research
1. Determine current threading model:
   - Is `Get-DirectoryChunks` ever called in parallel?
   - Are chunks created from multiple threads?
   - Current implementation appears single-threaded for chunk creation

2. Identify future parallelization plans:
   - Could directory scanning be parallelized?
   - Could chunk creation happen from background jobs?

3. Review PowerShell thread-safety mechanisms:
   - `[System.Threading.Interlocked]::Increment()`
   - `[System.Threading.Mutex]`
   - Thread-safe collections

### Current Risk Assessment
**Current Risk: LOW** - Chunk creation appears to be single-threaded during the scanning phase. The parallelism happens during chunk *execution* (multiple robocopy processes), not creation.

However, fixing this is low-cost and prevents future issues.

## Implementation

### Using Interlocked.Increment

```powershell
# At script level - change from simple int to ref-able variable
$script:ChunkIdCounter = [ref]0

function New-Chunk {
    param(...)

    # Thread-safe increment
    $newId = [System.Threading.Interlocked]::Increment($script:ChunkIdCounter)

    $chunk = [PSCustomObject]@{
        ChunkId = $newId
        SourcePath = $SourcePath
        ...
    }
    ...
}
```

### Alternative: GUID-based IDs
Use GUIDs instead of sequential integers:

```powershell
function New-Chunk {
    param(...)

    $chunk = [PSCustomObject]@{
        ChunkId = [guid]::NewGuid().ToString("N").Substring(0, 8)  # Short unique ID
        SourcePath = $SourcePath
        ...
    }
    ...
}
```

**Pros**: Guaranteed unique, no shared state
**Cons**: Not sequential, harder to read in logs

### Recommended Approach
Use `Interlocked.Increment` for simplicity and maintaining sequential IDs:

```powershell
# Initialize as [ref] for Interlocked
$script:ChunkIdCounter = [ref]0

function New-Chunk {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        ...
    )

    # Thread-safe increment, returns the new value
    $chunkId = [System.Threading.Interlocked]::Increment($script:ChunkIdCounter)

    $chunk = [PSCustomObject]@{
        ChunkId = $chunkId
        SourcePath = $SourcePath
        DestinationPath = $DestinationPath
        EstimatedSize = $Profile.TotalSize
        EstimatedFiles = $Profile.FileCount
        Depth = 0
        IsFilesOnly = $IsFilesOnly
        Status = "Pending"
        RobocopyArgs = @()
    }

    Write-RobocurseLog "Created chunk #$chunkId: $SourcePath" -Level Debug

    return $chunk
}
```

### Reset Function Update
Also update any reset logic:

```powershell
function Reset-ChunkCounter {
    # Thread-safe reset
    [System.Threading.Interlocked]::Exchange($script:ChunkIdCounter, 0) | Out-Null
}
```

Or in test setup:
```powershell
BeforeEach {
    [System.Threading.Interlocked]::Exchange($script:ChunkIdCounter, 0) | Out-Null
}
```

## Files to Modify

- `Robocurse.ps1` - Update chunk ID generation in `New-Chunk`
- `tests/Unit/Chunking.Tests.ps1` - Update tests that rely on chunk ID behavior

## Test Considerations

The tests already reset the counter in `BeforeEach`:
```powershell
BeforeEach {
    $script:ChunkIdCounter = 0
}
```

This needs to change to:
```powershell
BeforeEach {
    [System.Threading.Interlocked]::Exchange($script:ChunkIdCounter, 0) | Out-Null
}
```

Or if using `[ref]`:
```powershell
BeforeEach {
    $script:ChunkIdCounter.Value = 0
}
```

## Success Criteria

1. [ ] Chunk ID generation uses `Interlocked.Increment` or equivalent
2. [ ] No race condition possible even with parallel chunk creation
3. [ ] Chunk IDs still sequential (1, 2, 3, ...)
4. [ ] Counter can still be reset for testing
5. [ ] All existing Chunking tests pass
6. [ ] Tests can be run with: `Invoke-Pester -Path tests/Unit/Chunking.Tests.ps1`

## Testing Commands

```powershell
# Run chunking tests
Invoke-Pester -Path tests/Unit/Chunking.Tests.ps1 -Output Detailed

# Verify thread-safety manually (stress test)
. .\Robocurse.ps1 -Help
$jobs = 1..100 | ForEach-Object {
    Start-Job -ScriptBlock {
        param($scriptPath)
        . $scriptPath -Help
        $profile = [PSCustomObject]@{
            TotalSize = 1GB
            FileCount = 1000
            DirCount = 0
            AvgFileSize = 1MB
            LastScanned = Get-Date
        }
        New-Chunk -SourcePath "C:\Test$using:_" -DestinationPath "D:\Test$using:_" -Profile $profile
    } -ArgumentList (Resolve-Path .\Robocurse.ps1)
}
$results = $jobs | Wait-Job | Receive-Job
$ids = $results.ChunkId
$ids.Count -eq ($ids | Select-Object -Unique).Count  # Should be True (no duplicates)
```

## Estimated Complexity

Low - Simple change with well-defined scope.
