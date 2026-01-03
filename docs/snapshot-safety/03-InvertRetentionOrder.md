# Task: Invert Retention Deletion Order

## Process Requirements (EAD)

**TDD is mandatory**: Write tests FIRST, then implementation.

**Logging conventions**:
- Use `Write-RobocurseLog -Message "..." -Level 'Error|Warning|Info|Debug' -Component 'VSS'`
- Warning level for crash cleanup (unexpected state)
- Info level for normal retention (expected operation)

**Return values**: All functions return `OperationResult` via `New-OperationResult -Success $bool -Data $obj -ErrorMessage $msg`

**Important**: Don't remove `Invoke-VssRetentionPolicy` - keep it for CLI tools/scripts that may use it directly.

---

## Objective

Change retention logic so:
1. **Over limit on startup**: Delete NEWEST snapshot (crashed run cleanup)
2. **After successful backup**: Delete OLDEST snapshot (normal retention)

This protects known-good snapshots until the new backup completes.

## Success Criteria

1. New `Remove-NewestRegisteredSnapshot` function for crash cleanup
2. New `Remove-OldestRegisteredSnapshot` function for post-success cleanup
3. `Invoke-LocalPersistentSnapshot` calls newest cleanup instead of `Invoke-VssRetentionPolicy`
4. `Complete-CurrentProfile` calls oldest cleanup after success
5. Remote equivalents for both

## Research

- VssLocal.ps1:564-692 - Current `Invoke-VssRetentionPolicy` implementation (deletes oldest)
- VssCore.ps1:815-847 - `Get-RegisteredSnapshots` already exists
- JobManagement.ps1:323-341 - Current pre-creation retention (to be replaced)
- JobManagement.ps1:1486-1493 - Profile status determination in `Complete-CurrentProfile`
- JobManagement.ps1:1590-1597 - After cleanup, before next profile (insert post-success retention here)

## Test Plan (WRITE FIRST)

File: `tests/Unit/SnapshotSafetyRetention.Tests.ps1`

```powershell
Describe 'Remove-NewestRegisteredSnapshot' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\Robocurse\Public\VssLocal.ps1"
        . "$PSScriptRoot\..\..\src\Robocurse\Public\VssCore.ps1"
    }

    BeforeEach {
        # Mock 4 snapshots, 3 registered - newest is {guid-4}
        Mock Get-VssSnapshots {
            New-OperationResult -Success $true -Data @(
                [PSCustomObject]@{ ShadowId = '{guid-1}'; CreatedAt = (Get-Date).AddDays(-4) }
                [PSCustomObject]@{ ShadowId = '{guid-2}'; CreatedAt = (Get-Date).AddDays(-3) }
                [PSCustomObject]@{ ShadowId = '{guid-3}'; CreatedAt = (Get-Date).AddDays(-2) }  # external
                [PSCustomObject]@{ ShadowId = '{guid-4}'; CreatedAt = (Get-Date).AddDays(-1) }
            )
        }
        Mock Get-RegisteredSnapshots { @('{guid-1}', '{guid-2}', '{guid-4}') }
        Mock Remove-VssSnapshot { New-OperationResult -Success $true }
        Mock Unregister-PersistentSnapshot { $true }
        Mock Write-RobocurseLog {}
    }

    It 'deletes NEWEST when over limit' {
        $config = [PSCustomObject]@{ SnapshotRegistry = @{} }

        $result = Remove-NewestRegisteredSnapshot -Volume 'D:' -RetentionCount 2 -Config $config -ConfigPath 'test.json'

        $result.Success | Should -BeTrue
        $result.Data.DeletedCount | Should -Be 1
        # Should delete guid-4 (newest registered), NOT guid-1 (oldest)
        Should -Invoke Remove-VssSnapshot -ParameterFilter { $ShadowId -eq '{guid-4}' }
        Should -Not -Invoke Remove-VssSnapshot -ParameterFilter { $ShadowId -eq '{guid-1}' }
    }

    It 'does nothing when at or under limit' {
        $config = [PSCustomObject]@{ SnapshotRegistry = @{} }
        Mock Get-RegisteredSnapshots { @('{guid-1}', '{guid-2}') }

        $result = Remove-NewestRegisteredSnapshot -Volume 'D:' -RetentionCount 3 -Config $config -ConfigPath 'test.json'

        $result.Success | Should -BeTrue
        $result.Data.DeletedCount | Should -Be 0
        Should -Not -Invoke Remove-VssSnapshot
    }

    It 'does NOT delete external snapshots' {
        $config = [PSCustomObject]@{ SnapshotRegistry = @{} }

        Remove-NewestRegisteredSnapshot -Volume 'D:' -RetentionCount 2 -Config $config -ConfigPath 'test.json'

        # {guid-3} is external - should never be deleted
        Should -Not -Invoke Remove-VssSnapshot -ParameterFilter { $ShadowId -eq '{guid-3}' }
    }

    It 'logs at Warning level for crash cleanup' {
        $config = [PSCustomObject]@{ SnapshotRegistry = @{} }

        Remove-NewestRegisteredSnapshot -Volume 'D:' -RetentionCount 2 -Config $config -ConfigPath 'test.json'

        Should -Invoke Write-RobocurseLog -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'crashed run' }
    }
}

Describe 'Remove-OldestRegisteredSnapshot' {
    BeforeEach {
        Mock Get-VssSnapshots {
            New-OperationResult -Success $true -Data @(
                [PSCustomObject]@{ ShadowId = '{guid-1}'; CreatedAt = (Get-Date).AddDays(-4) }
                [PSCustomObject]@{ ShadowId = '{guid-2}'; CreatedAt = (Get-Date).AddDays(-1) }
            )
        }
        Mock Get-RegisteredSnapshots { @('{guid-1}', '{guid-2}') }
        Mock Remove-VssSnapshot { New-OperationResult -Success $true }
        Mock Unregister-PersistentSnapshot { $true }
        Mock Write-RobocurseLog {}
    }

    It 'deletes OLDEST when over limit' {
        $config = [PSCustomObject]@{ SnapshotRegistry = @{} }

        $result = Remove-OldestRegisteredSnapshot -Volume 'D:' -RetentionCount 1 -Config $config -ConfigPath 'test.json'

        $result.Data.DeletedCount | Should -Be 1
        # Should delete guid-1 (oldest), NOT guid-2 (newest)
        Should -Invoke Remove-VssSnapshot -ParameterFilter { $ShadowId -eq '{guid-1}' }
    }

    It 'logs at Info level for normal retention' {
        $config = [PSCustomObject]@{ SnapshotRegistry = @{} }

        Remove-OldestRegisteredSnapshot -Volume 'D:' -RetentionCount 1 -Config $config -ConfigPath 'test.json'

        Should -Invoke Write-RobocurseLog -ParameterFilter { $Level -eq 'Info' }
    }
}
```

### Edge Cases to Test
- Empty registry (no registered snapshots)
- Registered snapshot no longer exists in Windows (orphan registry entry)
- Multiple deletions needed (over by 2+)
- Remote server failures

## Implementation

### 1. Add Remove-NewestRegisteredSnapshot (VssLocal.ps1)

```powershell
function Remove-NewestRegisteredSnapshot {
    <#
    .SYNOPSIS
        Removes the NEWEST registered snapshot when over retention limit
    .DESCRIPTION
        Used at startup to clean up crashed run. The newest snapshot
        is most likely from an incomplete backup.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Volume,
        [Parameter(Mandatory)][int]$RetentionCount,
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$ConfigPath
    )

    $registeredIds = Get-RegisteredSnapshots -Config $Config -Volume $Volume
    if ($registeredIds.Count -le $RetentionCount) {
        return New-OperationResult -Success $true -Data @{ DeletedCount = 0 }
    }

    # Get snapshot details to find newest by CreatedAt
    $listResult = Get-VssSnapshots -Volume $Volume
    if (-not $listResult.Success) {
        return $listResult
    }

    # Filter to our registered, sort descending (newest first)
    $ourSnapshots = @($listResult.Data | Where-Object { $_.ShadowId -in $registeredIds } | Sort-Object CreatedAt -Descending)
    $deleteCount = $ourSnapshots.Count - $RetentionCount

    $deleted = 0
    foreach ($snap in ($ourSnapshots | Select-Object -First $deleteCount)) {
        Write-RobocurseLog -Message "Deleting NEWEST snapshot $($snap.ShadowId) (likely from crashed run)" -Level 'Warning' -Component 'VSS'
        $removeResult = Remove-VssSnapshot -ShadowId $snap.ShadowId
        if ($removeResult.Success) {
            Unregister-PersistentSnapshot -Config $Config -ShadowId $snap.ShadowId -ConfigPath $ConfigPath | Out-Null
            $deleted++
        }
    }

    return New-OperationResult -Success $true -Data @{ DeletedCount = $deleted }
}
```

### 2. Add Remove-OldestRegisteredSnapshot (VssLocal.ps1)

Similar but sorts ascending (oldest first) and uses Info level logging:
```powershell
Write-RobocurseLog -Message "Deleting OLDEST snapshot $($snap.ShadowId) (retention cleanup after success)" -Level 'Info' -Component 'VSS'
```

### 3. Update Invoke-LocalPersistentSnapshot (JobManagement.ps1:323-341)

Replace:
```powershell
# OLD: $retentionResult = Invoke-VssRetentionPolicy -Volume $volume -KeepCount ($keepCount - 1) ...
```
With:
```powershell
# NEW: Delete NEWEST if over limit (crashed run cleanup)
$cleanupResult = Remove-NewestRegisteredSnapshot -Volume $volume -RetentionCount $keepCount -Config $Config -ConfigPath $ConfigPath
if ($cleanupResult.Data.DeletedCount -gt 0) {
    Write-RobocurseLog -Message "Cleaned up $($cleanupResult.Data.DeletedCount) snapshot(s) from likely crashed run" -Level 'Warning' -Component 'VSS'
}
```

### 4. Update Complete-CurrentProfile (JobManagement.ps1, after line 1592)

```powershell
# Post-success: delete oldest snapshots if over retention
if ($profileStatus -eq 'Success' -and $state.LastSnapshotResult) {
    if ($state.LastSnapshotResult.SourceSnapshot) {
        $srcVolume = $state.LastSnapshotResult.SourceSnapshot.SourceVolume
        $srcRetention = Get-EffectiveVolumeRetention -Volume $srcVolume -Side 'Source' -Config $script:Config
        Remove-OldestRegisteredSnapshot -Volume $srcVolume -RetentionCount $srcRetention -Config $script:Config -ConfigPath $script:ConfigPath | Out-Null
    }
    if ($state.LastSnapshotResult.DestinationSnapshot) {
        $destVolume = $state.LastSnapshotResult.DestinationSnapshot.SourceVolume
        $destRetention = Get-EffectiveVolumeRetention -Volume $destVolume -Side 'Destination' -Config $script:Config
        Remove-OldestRegisteredSnapshot -Volume $destVolume -RetentionCount $destRetention -Config $script:Config -ConfigPath $script:ConfigPath | Out-Null
    }
}
```

### 5. Add remote equivalents in VssRemote.ps1

- `Remove-NewestRemoteRegisteredSnapshot` using `Get-RemoteVssSnapshots` and `Remove-RemoteVssSnapshot`
- `Remove-OldestRemoteRegisteredSnapshot` similarly

## Files to Modify

- `src/Robocurse/Public/VssLocal.ps1` - Add two new functions
- `src/Robocurse/Public/VssRemote.ps1` - Remote equivalents
- `src/Robocurse/Public/JobManagement.ps1` - Update both Invoke functions + Complete-CurrentProfile
- `tests/Unit/SnapshotSafetyRetention.Tests.ps1` (new)

## Verification

```powershell
.\scripts\run-tests.ps1
powershell -NoProfile -Command 'Get-Content $env:TEMP\pester-summary.txt'
```
