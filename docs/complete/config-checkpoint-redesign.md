# Task: Config Snapshot and Checkpoint Architecture Redesign

## Objective
Eliminate the fragile config snapshot/merge system and ensure all configuration changes (especially VSS snapshot registry) are persisted immediately to the original config file. This prevents data loss on crash and simplifies the architecture.

## Problem Statement

### Current Architecture (Broken)
```
Start Replication:
1. GUI saves in-memory $script:Config to disk
2. GUI creates temp copy: Logs/{date}/Robocurse-ConfigSnapshot-{guid}.json
3. Background runspace receives path to TEMP copy
4. Runspace writes VSS snapshot registry to TEMP copy
5. On successful completion only: merge temp → original config
6. Delete temp file

Checkpoint (separate system):
- Saves: SessionId, ProfileIndex, CompletedChunkPaths, BytesComplete
- Does NOT save: VSS snapshot registry, temp config path
```

### Failure Scenarios

**Scenario 1: System crash during replication**
1. VSS snapshot created at step 4, registered in temp config
2. Crash happens
3. On restart, checkpoint has chunk progress
4. BUT temp config with snapshot registry is orphaned
5. Original config doesn't know about the snapshot
6. Snapshot exists on disk but isn't tracked → wasted space or orphan cleanup deletes it

**Scenario 2: Application close without completion**
1. User closes GUI during replication
2. Temp config has snapshot registry updates
3. Merge never happens (only runs in Complete-GuiReplication)
4. Same orphan problem as Scenario 1

**Scenario 3: Multiple profiles with snapshots**
1. Profile 1 creates snapshot, registered in temp config
2. Profile 2 starts, creates snapshot
3. Crash during Profile 2
4. Neither snapshot is in original config

## Success Criteria
1. VSS snapshot registry is persisted to original config immediately when snapshot is created
2. No temp config snapshot file needed
3. Crash at any point preserves all snapshot registry entries
4. Checkpoint recovery works with correct snapshot information
5. No orphaned snapshots after crash recovery
6. All existing tests pass

## Research: Current Implementation

### Config Snapshot Creation (GuiReplication.ps1:153-163)
```powershell
# Create a snapshot of the config to prevent external modifications during replication
$script:ConfigSnapshotPath = $null
try {
    $script:ConfigSnapshotPath = Join-Path $snapshotDir "Robocurse-ConfigSnapshot-$([Guid]::NewGuid().ToString('N')).json"
    Copy-Item -Path $script:ConfigPath -Destination $script:ConfigSnapshotPath -Force
}
catch {
    Write-GuiLog "Warning: Could not create config snapshot, using live config: $($_.Exception.Message)"
    $script:ConfigSnapshotPath = $script:ConfigPath  # Fall back to original
}
```

### Runspace Receives Temp Path (GuiReplication.ps1:170)
```powershell
$runspaceInfo = New-ReplicationRunspace -Profiles $profilesToRun -MaxWorkers $maxWorkers -ConfigPath $script:ConfigSnapshotPath -LogRoot $logRoot -LogPath $currentLogPath
```

### Merge on Completion (GuiReplication.ps1:362-388)
```powershell
# Merge snapshot registry from temp config back to original config
try {
    if ($script:ConfigSnapshotPath -and ($script:ConfigSnapshotPath -ne $script:ConfigPath) -and (Test-Path $script:ConfigSnapshotPath)) {
        $snapshotConfig = Get-Content $script:ConfigSnapshotPath -Raw | ConvertFrom-Json
        if ($snapshotConfig.snapshotRegistry) {
            # Merge snapshot registry entries into the live config
            $snapshotConfig.snapshotRegistry.PSObject.Properties | ForEach-Object {
                $volumeKey = $_.Name
                $snapshotIds = $_.Value
                if ($snapshotIds -and $snapshotIds.Count -gt 0) {
                    $script:Config.SnapshotRegistry | Add-Member -NotePropertyName $volumeKey -NotePropertyValue $snapshotIds -Force
                }
            }
            # Save the merged config to the original path
            $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
            ...
        }
    }
}
```

### Snapshot Registration (VssCore.ps1:663-720)
```powershell
function Register-PersistentSnapshot {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory)]
        [string]$Volume,

        [Parameter(Mandatory)]
        [string]$ShadowId,

        [string]$ConfigPath  # <-- This receives the TEMP path during replication
    )

    # ... adds to $Config.SnapshotRegistry ...

    # Persist to disk if ConfigPath provided
    if ($ConfigPath) {
        $saveResult = Save-RobocurseConfig -Config $Config -Path $ConfigPath
        # <-- Writes to TEMP file, not original!
    }
}
```

### Checkpoint Save (Checkpoint.ps1:29-117)
```powershell
$checkpoint = [PSCustomObject]@{
    Version = "1.0"
    SessionId = $state.SessionId
    SavedAt = (Get-Date).ToString('o')
    ProfileIndex = $state.ProfileIndex
    CurrentProfileName = if ($state.CurrentProfile) { $state.CurrentProfile.Name } else { "" }
    CompletedChunkPaths = $completedPaths
    CompletedCount = $state.CompletedCount
    FailedCount = $state.FailedChunks.Count
    BytesComplete = $state.BytesComplete
    StartTime = if ($state.StartTime) { $state.StartTime.ToString('o') } else { $null }
    # NOTE: No snapshot registry info!
}
```

## Implementation Plan

### Phase 1: Remove Config Snapshot System

#### Step 1: Update GuiReplication.ps1 - Remove Snapshot Creation
```powershell
# REMOVE lines 153-163 (config snapshot creation)
# REMOVE lines 362-388 (merge logic)
# REMOVE lines 427-438 (cleanup logic)

# CHANGE line 170 from:
$runspaceInfo = New-ReplicationRunspace ... -ConfigPath $script:ConfigSnapshotPath ...

# TO:
$runspaceInfo = New-ReplicationRunspace ... -ConfigPath $script:ConfigPath ...
```

#### Step 2: Update New-ReplicationRunspace (GuiRunspace.ps1)
The function already accepts ConfigPath - just verify it works with the original path.

### Phase 2: Ensure Immediate Persistence

#### Step 3: Verify Register-PersistentSnapshot Writes to Original
Currently writes to whatever ConfigPath is passed. After Phase 1, this will be the original config path automatically.

#### Step 4: Add File Locking for Safety
Consider adding file locking to prevent corruption if external edits happen:

```powershell
function Save-RobocurseConfig {
    param(...)

    # Use file locking to prevent concurrent writes
    $lockPath = "$Path.lock"
    try {
        $lockStream = [System.IO.File]::Open($lockPath, 'Create', 'Write', 'None')
        try {
            # Atomic write with temp file
            $tempPath = "$Path.tmp"
            $json | Set-Content -Path $tempPath -Encoding UTF8
            [System.IO.File]::Move($tempPath, $Path, $true)
        }
        finally {
            $lockStream.Close()
            Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Handle lock acquisition failure
    }
}
```

### Phase 3: Update Checkpoint for Completeness (Optional)

#### Step 5: Add Snapshot Info to Checkpoint
While not strictly necessary after Phase 1 (config is authoritative), adding snapshot info to checkpoint provides defense in depth:

```powershell
$checkpoint = [PSCustomObject]@{
    # ... existing fields ...

    # NEW: Track snapshots created during this session for recovery verification
    CreatedSnapshots = @(
        @{ Volume = "C:"; ShadowId = "{guid}"; Side = "Source" }
        @{ Volume = "D:"; ShadowId = "{guid}"; Side = "Destination" }
    )
}
```

This allows crash recovery to verify snapshots are still valid and in the registry.

### Phase 4: Handle Edge Cases

#### Step 6: External Edit Warning
Add detection for external config modifications during replication:

```powershell
# At start of replication, record config file timestamp
$script:ConfigTimestampAtStart = (Get-Item $script:ConfigPath).LastWriteTimeUtc

# Before any config save during replication, check timestamp
function Test-ConfigModifiedExternally {
    $currentTimestamp = (Get-Item $script:ConfigPath).LastWriteTimeUtc
    return $currentTimestamp -ne $script:ConfigTimestampAtStart
}

# In Register-PersistentSnapshot or Save-RobocurseConfig:
if (Test-ConfigModifiedExternally) {
    Write-RobocurseLog -Message "Config file was modified externally during replication. Reloading and merging." -Level 'Warning'
    # Reload from disk, merge our changes, save
}
```

## Files to Modify

| File | Changes |
|------|---------|
| `src/Robocurse/Public/GuiReplication.ps1` | Remove config snapshot creation, merge, and cleanup logic |
| `src/Robocurse/Public/GuiRunspace.ps1` | Verify works with original config path (likely no changes) |
| `src/Robocurse/Public/Configuration.ps1` | Optional: Add file locking to Save-RobocurseConfig |
| `src/Robocurse/Public/Checkpoint.ps1` | Optional: Add CreatedSnapshots field |
| `src/Robocurse/Public/VssCore.ps1` | Optional: Add external modification detection |

## Test Plan

### Unit Tests
```powershell
# Existing tests should continue to pass
Invoke-Pester -Path tests/Unit -Output Detailed
```

### Integration Tests
```powershell
# New test: Verify snapshot registry persists immediately
Describe "Snapshot Registry Persistence" {
    It "Should persist snapshot registry to original config immediately" {
        # Create snapshot
        # Verify original config file contains the registry entry
        # (Not waiting for replication completion)
    }

    It "Should preserve snapshot registry after simulated crash" {
        # Start replication
        # Create snapshot
        # Kill process (simulate crash)
        # Reload config
        # Verify snapshot is in registry
    }
}
```

### Manual Testing
1. Start replication with VSS snapshot enabled
2. While running, check original config file for snapshotRegistry
3. Force-close the application (Task Manager kill)
4. Restart and verify snapshot is still tracked

## Verification
1. No temp config files created during replication
2. Snapshot registry appears in original config immediately after snapshot creation
3. Crash during replication preserves all snapshot registry entries
4. Orphan cleanup doesn't delete snapshots that were just created
5. All existing tests pass
6. No regression in normal completion flow

## Rollback Plan
If issues are found:
1. Revert GuiReplication.ps1 changes
2. Config snapshot system will work as before
3. Known issues remain but functionality is preserved

## Dependencies
- None - this is an internal refactor

## Estimated Scope
- Lines of code removed: ~50 (snapshot creation/merge/cleanup)
- Lines of code added: ~20 (optional safety features)
- Net reduction in complexity
- Medium risk due to touching replication flow
