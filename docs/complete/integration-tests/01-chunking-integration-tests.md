# Task: Chunking Integration Tests

## Objective
Add integration tests that run actual chunking operations against real directory structures. Currently, chunking unit tests mock `Get-DirectoryProfile` and `New-DirectoryTree`, so they don't catch bugs caused by mismatches between mocked data and real robocopy output (like the W:\W:\ path doubling bug).

## Problem Statement
The chunking system has unit tests that:
- Mock directory profile data with fake sizes/counts
- Mock tree nodes with synthetic paths
- Never actually run robocopy enumeration

This gap allowed the path doubling bug to ship - the mock format didn't match real robocopy output.

## Success Criteria
1. Integration tests create real temp directories with known structures
2. Tests run actual `New-DirectoryTree` (which invokes real robocopy /L)
3. Tests run actual `Get-DirectoryChunks` with the real tree
4. Tests verify chunk paths exist and are valid
5. Tests verify chunk sizes match actual directory sizes
6. Tests verify chunking decisions match expected behavior for known structures
7. All tests pass and are included in standard test runs

## Research: Current Implementation

### Existing Chunking Tests (tests/Unit/Chunking.Tests.ps1)
```powershell
# All tests mock the profiling functions
Mock Get-DirectoryProfile { ... mock data ... }
Mock New-DirectoryTree { ... mock tree ... }

# Tests verify logic but not real-world behavior
$chunks = Get-DirectoryChunks -Path "C:\Test" -TreeNode $mockTree
```

### Real Chunking Flow (src/Robocurse/Public/Chunking.ps1)
```powershell
function Get-DirectoryChunks {
    param(
        [string]$Path,
        [DirectoryNode]$TreeNode,  # If provided, use tree data
        ...
    )

    # If no tree provided, build one (calls robocopy)
    if (-not $TreeNode) {
        $TreeNode = New-DirectoryTree -RootPath $Path
    }

    # Use tree data for size/count decisions
    $totalSize = $TreeNode.TotalSize
    ...
}
```

### Directory Tree Integration Tests (tests/Integration/DirectoryTree.Integration.Tests.ps1)
Already exists with pattern to follow:
```powershell
BeforeAll {
    $script:TestRoot = Join-Path $env:TEMP "RobocurseTreeTest_..."
    # Create directories and files
}

It "Should build tree with correct paths from real directory" {
    $tree = New-DirectoryTree -RootPath $script:TestRoot
    # Verify real behavior
}
```

## Implementation Plan

### Step 1: Add Chunking Split Test
Create test that verifies a large directory structure gets split correctly:

```powershell
Describe "Chunking Split Behavior" -Tag "Integration" {
    BeforeAll {
        $script:SplitTestRoot = Join-Path $env:TEMP "RobocurseChunkSplit_..."
        # Create structure that should split:
        # - Root with 3 subdirs
        # - Each subdir has 1MB of files
        # - Set MaxSizeBytes to 2MB so it must split
    }

    It "Should split directory into multiple chunks when over threshold" {
        $tree = New-DirectoryTree -RootPath $script:SplitTestRoot
        $chunks = @(Get-DirectoryChunks -Path $script:SplitTestRoot -TreeNode $tree -MaxSizeBytes 2MB)

        $chunks.Count | Should -BeGreaterThan 1
        # Verify each chunk path exists
        foreach ($chunk in $chunks) {
            Test-Path $chunk.SourcePath | Should -Be $true
        }
    }
}
```

### Step 2: Add Single Chunk Test
Test that small directories stay as single chunk:

```powershell
It "Should keep small directory as single chunk" {
    # Create dir with < 1MB total
    $tree = New-DirectoryTree -RootPath $script:SmallTestRoot
    $chunks = @(Get-DirectoryChunks -Path $script:SmallTestRoot -TreeNode $tree -MaxSizeBytes 10MB)

    $chunks.Count | Should -Be 1
    $chunks[0].SourcePath | Should -Be $script:SmallTestRoot
}
```

### Step 3: Add Depth Limit Test
Test that chunking respects MaxDepth:

```powershell
It "Should stop splitting at max depth" {
    # Create deep structure: Root > L1 > L2 > L3 > L4 with large files at L4
    $tree = New-DirectoryTree -RootPath $script:DeepTestRoot
    $chunks = @(Get-DirectoryChunks -Path $script:DeepTestRoot -TreeNode $tree -MaxSizeBytes 1KB -MaxDepth 2)

    # Should not have chunks deeper than depth 2
    foreach ($chunk in $chunks) {
        $relativePath = $chunk.SourcePath.Replace($script:DeepTestRoot, "")
        $depth = ($relativePath -split '\\' | Where-Object { $_ }).Count
        $depth | Should -BeLessOrEqual 2
    }
}
```

### Step 4: Add Destination Path Test
Verify destination paths are computed correctly:

```powershell
It "Should compute correct destination paths for chunks" {
    $destRoot = Join-Path $env:TEMP "ChunkDest_..."
    $tree = New-DirectoryTree -RootPath $script:TestRoot
    $chunks = @(Get-DirectoryChunks -Path $script:TestRoot -DestinationRoot $destRoot -TreeNode $tree)

    foreach ($chunk in $chunks) {
        # Destination should mirror source structure
        $relPath = $chunk.SourcePath.Replace($script:TestRoot, "")
        $expectedDest = Join-Path $destRoot $relPath
        $chunk.DestinationPath | Should -Be $expectedDest
    }
}
```

## Test Plan
```powershell
# Run just chunking integration tests
Invoke-Pester -Path tests/Integration/Chunking.Integration.Tests.ps1 -Output Detailed

# Run all integration tests
Invoke-Pester -Path tests/Integration -Output Detailed
```

## Files to Create
| File | Purpose |
|------|---------|
| `tests/Integration/Chunking.Integration.Tests.ps1` | New integration test file |

## Verification
1. All new integration tests pass
2. Tests create real directories with real files
3. Tests call real `New-DirectoryTree` and `Get-DirectoryChunks`
4. No mocks for profiling/tree functions
5. Existing unit tests still pass (they use mocks intentionally)
