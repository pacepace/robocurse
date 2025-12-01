# Task 01: Implement Missing Chunking Functions

## Priority: CRITICAL

## Problem Statement

The `Start-ProfileReplication` function (around line 1672-1681 in `Robocurse.ps1`) references two functions that do not exist:
- `New-FlatChunks`
- `New-SmartChunks`

This causes runtime failures when attempting to start profile replication.

```powershell
$chunks = switch ($Profile.ScanMode) {
    'Flat' {
        New-FlatChunks -Profile $scanResult -MaxChunkSizeMB $Profile.MaxChunkSizeMB
    }
    'Smart' {
        New-SmartChunks -Profile $scanResult -MaxChunkSizeMB $Profile.MaxChunkSizeMB
    }
    default {
        New-SmartChunks -Profile $scanResult -MaxChunkSizeMB $Profile.MaxChunkSizeMB
    }
}
```

## Research Required

### Code Research
1. Read `Robocurse.ps1` focusing on:
   - The `#region CHUNKING` section (lines ~928-1206)
   - The existing `Get-DirectoryChunks` function
   - The `Start-ProfileReplication` function to understand expected inputs/outputs
   - The chunk object structure created by `New-Chunk`

2. Read `tests/Unit/Chunking.Tests.ps1` to understand:
   - How chunks are expected to behave
   - What properties chunk objects should have
   - Test patterns to follow

3. Examine the `SyncProfiles` configuration structure to understand:
   - What `ScanMode` values are expected ("Flat", "Smart", "Quick")
   - What properties profiles have (Source, Destination, ChunkMaxSizeGB, etc.)

### Key Questions to Answer
- What is the difference between "Flat" and "Smart" chunking strategies?
- How does the existing `Get-DirectoryChunks` function relate to these?
- Should these functions wrap `Get-DirectoryChunks` or replace it?

## Implementation Options

### Option A: Create New Functions That Wrap Get-DirectoryChunks
Create `New-FlatChunks` and `New-SmartChunks` as wrappers around the existing `Get-DirectoryChunks` with different parameters.

### Option B: Refactor Start-ProfileReplication
Modify `Start-ProfileReplication` to use `Get-DirectoryChunks` directly with appropriate parameters based on `ScanMode`.

### Option C: Full Implementation
Create distinct chunking algorithms:
- **Flat**: Single-level chunking (don't recurse into subdirectories)
- **Smart**: Recursive chunking with size-based splitting (current `Get-DirectoryChunks` behavior)

## Recommended Approach

Option B is likely the cleanest solution - refactor `Start-ProfileReplication` to use `Get-DirectoryChunks` directly, since that function already implements smart recursive chunking.

For "Flat" mode, you may need to add a parameter to `Get-DirectoryChunks` to limit recursion to depth 0.

## Implementation Steps

1. Analyze the existing `Get-DirectoryChunks` function parameters
2. Determine how to differentiate Flat vs Smart behavior
3. Either:
   - Add wrapper functions, OR
   - Modify `Start-ProfileReplication` to call `Get-DirectoryChunks` correctly
4. Ensure chunk objects have all required properties for the orchestration layer
5. Add/update tests

## Files to Modify

- `Robocurse.ps1` - Add missing functions or fix `Start-ProfileReplication`
- `tests/Unit/Chunking.Tests.ps1` - Add tests for new/modified functionality
- Possibly `tests/Unit/Orchestration.Tests.ps1` - Add tests for profile replication

## Success Criteria

1. [ ] No undefined function errors when calling `Start-ProfileReplication`
2. [ ] "Flat" scan mode produces chunks that don't recurse into subdirectories
3. [ ] "Smart" scan mode produces recursive size-based chunks (existing behavior)
4. [ ] All existing Chunking.Tests.ps1 tests still pass
5. [ ] New tests added for the implemented/fixed functionality
6. [ ] Tests can be run with: `Invoke-Pester -Path tests/Unit/Chunking.Tests.ps1`

## Testing Commands

```powershell
# Run chunking tests
Invoke-Pester -Path tests/Unit/Chunking.Tests.ps1 -Output Detailed

# Run orchestration tests
Invoke-Pester -Path tests/Unit/Orchestration.Tests.ps1 -Output Detailed

# Run all tests to check for regressions
Invoke-Pester -Path tests/ -Output Detailed
```

## Estimated Complexity

Medium - Requires understanding existing chunking logic and making targeted changes.
