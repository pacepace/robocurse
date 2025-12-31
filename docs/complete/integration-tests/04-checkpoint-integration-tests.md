# Task: Checkpoint Recovery Integration Tests

## Objective
Add integration tests that verify checkpoint save/restore functionality with real files. Currently, checkpoint tests mock file operations, so they don't catch issues with JSON serialization, file locking, partial writes, or cross-process recovery.

## Problem Statement
The checkpoint system has unit tests that:
- Mock `Set-Content` and `Get-Content`
- Use synthetic checkpoint data
- Never write real checkpoint files
- Never test actual recovery across process restarts

Real-world issues that could slip through:
- JSON serialization of complex objects (chunks, VSS snapshots)
- File encoding issues
- Concurrent access/file locking
- Recovery after partial writes
- Cross-session state restoration

## Success Criteria
1. Integration tests write real checkpoint files
2. Tests verify file content is valid JSON
3. Tests verify restored state matches saved state
4. Tests simulate crash recovery scenarios
5. Tests verify checkpoint cleanup on completion
6. Tests handle corrupt checkpoint files gracefully

## Research: Current Implementation

### Checkpoint Functions (src/Robocurse/Public/Checkpoint.ps1)
```powershell
function Save-ReplicationCheckpoint {
    param(
        [string]$Path,
        [PSCustomObject]$State
    )

    $checkpoint = @{
        Timestamp = Get-Date -Format "o"
        ProfileName = $State.ProfileName
        Chunks = $State.Chunks | ForEach-Object {
            @{
                ChunkId = $_.ChunkId
                SourcePath = $_.SourcePath
                Status = $_.Status
                ...
            }
        }
        VssSnapshot = if ($State.VssSnapshot) { ... } else { $null }
    }

    $checkpoint | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function Restore-ReplicationCheckpoint {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $null }

    $json = Get-Content -Path $Path -Raw
    $checkpoint = $json | ConvertFrom-Json

    # Reconstruct state from checkpoint
    ...
}
```

### Current Unit Tests (tests/Unit/Checkpoint.Tests.ps1)
```powershell
Mock Set-Content { }
Mock Get-Content { return $mockJson }

It "Should save checkpoint" {
    Save-ReplicationCheckpoint -Path "C:\test.json" -State $mockState
    Assert-MockCalled Set-Content
}
```

### Checkpoint File Location
```
{LogPath}\{Date}\robocurse-checkpoint.json
```

## Implementation Plan

### Step 1: Create Test Infrastructure
```powershell
Describe "Checkpoint Integration Tests" -Tag "Integration" {
    BeforeAll {
        $script:TestRoot = Join-Path $env:TEMP "RobocurseCheckpoint_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
            Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
```

### Step 2: Add Save/Restore Round-Trip Test
```powershell
It "Should save and restore checkpoint with all properties intact" {
    $checkpointPath = Join-Path $script:TestRoot "checkpoint.json"

    # Create realistic state
    $chunks = @(
        [PSCustomObject]@{
            ChunkId = 1
            SourcePath = "C:\Source\Folder1"
            DestinationPath = "D:\Dest\Folder1"
            Status = "Completed"
            EstimatedSize = 1GB
            EstimatedFiles = 1000
        },
        [PSCustomObject]@{
            ChunkId = 2
            SourcePath = "C:\Source\Folder2"
            DestinationPath = "D:\Dest\Folder2"
            Status = "Running"
            EstimatedSize = 2GB
            EstimatedFiles = 2000
        },
        [PSCustomObject]@{
            ChunkId = 3
            SourcePath = "C:\Source\Folder3"
            DestinationPath = "D:\Dest\Folder3"
            Status = "Pending"
            EstimatedSize = 500MB
            EstimatedFiles = 500
        }
    )

    $state = [PSCustomObject]@{
        ProfileName = "TestProfile"
        Chunks = $chunks
        VssSnapshot = [PSCustomObject]@{
            ShadowId = [guid]::NewGuid()
            VolumePath = "C:\"
            ShadowPath = "\\?\GLOBALROOT\Device\..."
        }
    }

    # Save
    Save-ReplicationCheckpoint -Path $checkpointPath -State $state

    # Verify file exists and is valid JSON
    Test-Path $checkpointPath | Should -Be $true
    $json = Get-Content $checkpointPath -Raw
    { $json | ConvertFrom-Json } | Should -Not -Throw

    # Restore
    $restored = Restore-ReplicationCheckpoint -Path $checkpointPath

    # Verify all properties
    $restored.ProfileName | Should -Be "TestProfile"
    $restored.Chunks.Count | Should -Be 3
    $restored.Chunks[0].Status | Should -Be "Completed"
    $restored.Chunks[1].Status | Should -Be "Running"
    $restored.VssSnapshot | Should -Not -BeNullOrEmpty
}
```

### Step 3: Add Partial Completion Test
```powershell
It "Should restore partial progress for crash recovery" {
    $checkpointPath = Join-Path $script:TestRoot "partial.json"

    # Simulate state at mid-replication
    $chunks = @(
        [PSCustomObject]@{ ChunkId = 1; Status = "Completed" },
        [PSCustomObject]@{ ChunkId = 2; Status = "Failed"; LastErrorMessage = "Access denied" },
        [PSCustomObject]@{ ChunkId = 3; Status = "Pending" }
    )

    $state = [PSCustomObject]@{ ProfileName = "Test"; Chunks = $chunks }
    Save-ReplicationCheckpoint -Path $checkpointPath -State $state

    # Restore and verify pending chunks can be identified
    $restored = Restore-ReplicationCheckpoint -Path $checkpointPath
    $pendingChunks = $restored.Chunks | Where-Object { $_.Status -eq "Pending" }
    $failedChunks = $restored.Chunks | Where-Object { $_.Status -eq "Failed" }

    $pendingChunks.Count | Should -Be 1
    $failedChunks.Count | Should -Be 1
    $failedChunks[0].LastErrorMessage | Should -Be "Access denied"
}
```

### Step 4: Add Corrupt File Test
```powershell
It "Should handle corrupt checkpoint file gracefully" {
    $checkpointPath = Join-Path $script:TestRoot "corrupt.json"

    # Write invalid JSON
    "{ invalid json content" | Set-Content $checkpointPath

    # Should not throw, should return null or empty
    $restored = Restore-ReplicationCheckpoint -Path $checkpointPath -ErrorAction SilentlyContinue
    # Depending on implementation, might be null or have error property
}
```

### Step 5: Add Cleanup Test
```powershell
It "Should remove checkpoint on successful completion" {
    $checkpointPath = Join-Path $script:TestRoot "cleanup.json"

    # Create checkpoint
    $state = [PSCustomObject]@{ ProfileName = "Test"; Chunks = @() }
    Save-ReplicationCheckpoint -Path $checkpointPath -State $state
    Test-Path $checkpointPath | Should -Be $true

    # Clear checkpoint (simulating completion)
    Clear-ReplicationCheckpoint -Path $checkpointPath

    # Should be gone
    Test-Path $checkpointPath | Should -Be $false
}
```

### Step 6: Add Unicode Path Test
```powershell
It "Should handle unicode paths in checkpoint" {
    $checkpointPath = Join-Path $script:TestRoot "unicode.json"

    $chunks = @(
        [PSCustomObject]@{
            ChunkId = 1
            SourcePath = "C:\Données\Привет\文件夹"
            DestinationPath = "D:\Backup\Données\Привет\文件夹"
            Status = "Pending"
        }
    )

    $state = [PSCustomObject]@{ ProfileName = "Unicode Test"; Chunks = $chunks }
    Save-ReplicationCheckpoint -Path $checkpointPath -State $state

    $restored = Restore-ReplicationCheckpoint -Path $checkpointPath
    $restored.Chunks[0].SourcePath | Should -Be "C:\Données\Привет\文件夹"
}
```

## Test Plan
```powershell
# Run checkpoint integration tests
Invoke-Pester -Path tests/Integration/Checkpoint.Integration.Tests.ps1 -Output Detailed

# Run all integration tests
Invoke-Pester -Path tests/Integration -Output Detailed
```

## Files to Create
| File | Purpose |
|------|---------|
| `tests/Integration/Checkpoint.Integration.Tests.ps1` | New integration test file |

## Verification
1. Tests write real files to temp directory
2. Tests verify JSON is valid and parseable
3. Restored state matches saved state exactly
4. Corrupt files are handled gracefully
5. Cleanup removes checkpoint files
6. Unicode paths are preserved correctly
7. All temp files are cleaned up after tests
