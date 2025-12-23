# Task: Profile Snapshot Integration

## Objective
Integrate persistent VSS snapshots into the profile execution flow. Add configuration options to enable persistent snapshots per profile with retention settings per volume.

## Success Criteria
- [ ] Profile schema supports `PersistentSnapshot` settings (enabled, retention count)
- [ ] Config file schema supports per-volume retention settings
- [ ] Snapshot creation + retention enforcement happens at profile start (before existing temp VSS)
- [ ] Both local and remote paths are handled appropriately
- [ ] Tests verify integration points
- [ ] Existing temporary VSS behavior unchanged when persistent snapshots disabled

## Research

### Profile Execution Flow (file:line references)
- `JobManagement.ps1:154` - `Start-ProfileReplication` - Entry point for profile execution
- `JobManagement.ps1:238-270` - Existing VSS snapshot setup (temporary, for backup consistency)
- `JobManagement.ps1:229` - Log "Starting profile: $($Profile.Name)"

### Configuration Structure (file:line references)
- `Configuration.ps1:56` - `New-DefaultConfig` - Default configuration
- `Configuration.ps1:332-344` - SyncProfile object structure
- `Configuration.ps1:280` - `ConvertFrom-FriendlyConfig` - JSON to internal format

### Current Profile Properties
```powershell
$syncProfile = [PSCustomObject]@{
    Name             = $profileName
    Description      = ""
    Source           = ""
    Destination      = ""
    UseVss           = $false      # Existing: temp VSS for backup consistency
    ScanMode         = "Smart"
    ChunkMaxSizeGB   = 10
    ChunkMaxFiles    = 50000
    ChunkMaxDepth    = 5
    RobocopyOptions  = @{}
    Enabled          = $true
}
```

### Hook Point
Insert persistent snapshot logic at `JobManagement.ps1` around line 237, BEFORE the existing temporary VSS snapshot creation. The flow should be:

1. Profile starts
2. **NEW: Create persistent snapshot + enforce retention** (if enabled)
3. Create temporary VSS snapshot (existing behavior, if UseVss=true)
4. Scan source directory
5. Execute robocopy chunks
6. Cleanup temporary VSS (existing)
7. **Persistent snapshot remains** (that's the point)

## Implementation

### Part 1: Configuration Schema Updates

#### File: `src\Robocurse\Public\Configuration.ps1`

**Update `New-DefaultConfig` (around line 71):**

Add to GlobalSettings:
```powershell
GlobalSettings = [PSCustomObject]@{
    # ... existing settings ...
    SnapshotRetention = [PSCustomObject]@{
        DefaultKeepCount = 3          # Default snapshots to keep per volume
        VolumeOverrides = @{}         # Per-volume overrides: @{ "D:" = 5; "E:" = 10 }
    }
}
```

**Update SyncProfile structure in `ConvertFrom-FriendlyConfig` (around line 332):**

Add to profile object:
```powershell
$syncProfile = [PSCustomObject]@{
    # ... existing properties ...
    PersistentSnapshot = [PSCustomObject]@{
        Enabled = $false              # Enable persistent snapshots for this profile
        # Retention uses GlobalSettings.SnapshotRetention by default
    }
}
```

**Update `ConvertFrom-FriendlyConfig` to parse new settings (around line 347):**

```powershell
# After existing source parsing
if ($rawProfile.persistentSnapshot) {
    $syncProfile.PersistentSnapshot = [PSCustomObject]@{
        Enabled = [bool]$rawProfile.persistentSnapshot.enabled
    }
}
```

**Update `ConvertTo-FriendlyConfig` to serialize new settings (around line 443):**

```powershell
# Add to $friendlyProfile
if ($profile.PersistentSnapshot -and $profile.PersistentSnapshot.Enabled) {
    $friendlyProfile.persistentSnapshot = [ordered]@{
        enabled = $profile.PersistentSnapshot.Enabled
    }
}
```

**Update `ConvertFrom-GlobalSettings` (around line 208):**

```powershell
# Add after existing logging settings
if ($RawGlobal.snapshotRetention) {
    $Config.GlobalSettings.SnapshotRetention = [PSCustomObject]@{
        DefaultKeepCount = if ($RawGlobal.snapshotRetention.defaultKeepCount) {
            $RawGlobal.snapshotRetention.defaultKeepCount
        } else { 3 }
        VolumeOverrides = @{}
    }
    if ($RawGlobal.snapshotRetention.volumeOverrides) {
        $overrides = @{}
        $RawGlobal.snapshotRetention.volumeOverrides.PSObject.Properties | ForEach-Object {
            $overrides[$_.Name.ToUpper()] = [int]$_.Value
        }
        $Config.GlobalSettings.SnapshotRetention.VolumeOverrides = $overrides
    }
}
```

### Part 2: Profile Execution Integration

#### File: `src\Robocurse\Public\JobManagement.ps1`

**Add new function (before `Start-ProfileReplication`):**

```powershell
function Invoke-ProfilePersistentSnapshot {
    <#
    .SYNOPSIS
        Creates a persistent VSS snapshot at profile start with retention enforcement
    .DESCRIPTION
        If the profile has PersistentSnapshot.Enabled = $true, this function:
        1. Determines the source volume (local or remote)
        2. Enforces retention policy (deletes old snapshots to make room)
        3. Creates a new persistent snapshot
        The snapshot remains after backup completes for point-in-time recovery.
    .PARAMETER Profile
        The sync profile object
    .PARAMETER Config
        The full configuration object (for retention settings)
    .OUTPUTS
        OperationResult with Data = snapshot info (or $null if not enabled)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,

        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    # Check if persistent snapshots are enabled for this profile
    if (-not $Profile.PersistentSnapshot -or -not $Profile.PersistentSnapshot.Enabled) {
        Write-RobocurseLog -Message "Persistent snapshots not enabled for profile '$($Profile.Name)'" -Level 'Debug' -Component 'Orchestration'
        return New-OperationResult -Success $true -Data $null
    }

    $sourcePath = $Profile.Source
    Write-RobocurseLog -Message "Creating persistent snapshot for profile '$($Profile.Name)' source: $sourcePath" -Level 'Info' -Component 'Orchestration'

    # Determine if local or remote
    $isRemote = $sourcePath -match '^\\\\[^\\]+\\[^\\]+'

    if ($isRemote) {
        return Invoke-RemotePersistentSnapshot -SourcePath $sourcePath -Config $Config
    }
    else {
        return Invoke-LocalPersistentSnapshot -SourcePath $sourcePath -Config $Config
    }
}

function Invoke-LocalPersistentSnapshot {
    [CmdletBinding()]
    param(
        [string]$SourcePath,
        [PSCustomObject]$Config
    )

    # Get volume from path
    $volume = Get-VolumeFromPath -Path $SourcePath
    if (-not $volume) {
        return New-OperationResult -Success $false -ErrorMessage "Cannot determine volume from path: $SourcePath"
    }

    # Get retention count for this volume
    $keepCount = Get-VolumeRetentionCount -Volume $volume -Config $Config

    Write-RobocurseLog -Message "Enforcing retention for $volume (keep: $keepCount)" -Level 'Info' -Component 'Orchestration'

    # Step 1: Enforce retention BEFORE creating new snapshot
    $retentionResult = Invoke-VssRetentionPolicy -Volume $volume -KeepCount $keepCount
    if (-not $retentionResult.Success) {
        Write-RobocurseLog -Message "Retention enforcement failed: $($retentionResult.ErrorMessage)" -Level 'Warning' -Component 'Orchestration'
        # Continue anyway - we'll try to create the snapshot
    }
    else {
        Write-RobocurseLog -Message "Retention: deleted $($retentionResult.Data.DeletedCount), kept $($retentionResult.Data.KeptCount)" -Level 'Debug' -Component 'Orchestration'
    }

    # Step 2: Create new persistent snapshot
    $snapshotResult = New-VssSnapshot -SourcePath $SourcePath
    if (-not $snapshotResult.Success) {
        return New-OperationResult -Success $false -ErrorMessage "Failed to create persistent snapshot: $($snapshotResult.ErrorMessage)"
    }

    # Note: We do NOT track this snapshot for orphan cleanup - it's meant to persist
    # Actually, we should still track it but mark it as persistent so Clear-OrphanVssSnapshots skips it
    # For now, we'll remove it from tracking so it survives restarts

    Write-RobocurseLog -Message "Created persistent snapshot: $($snapshotResult.Data.ShadowId)" -Level 'Info' -Component 'Orchestration'

    return $snapshotResult
}

function Invoke-RemotePersistentSnapshot {
    [CmdletBinding()]
    param(
        [string]$SourcePath,
        [PSCustomObject]$Config
    )

    # Parse UNC path
    $components = Get-UncPathComponents -UncPath $SourcePath
    if (-not $components) {
        return New-OperationResult -Success $false -ErrorMessage "Invalid UNC path: $SourcePath"
    }

    $serverName = $components.ServerName
    $shareName = $components.ShareName

    # Get share's local path to determine volume
    $shareLocalPath = Get-RemoteShareLocalPath -ServerName $serverName -ShareName $shareName
    if (-not $shareLocalPath) {
        return New-OperationResult -Success $false -ErrorMessage "Cannot determine local path for share '$shareName' on '$serverName'"
    }

    # Extract volume
    if ($shareLocalPath -match '^([A-Za-z]:)') {
        $volume = $Matches[1].ToUpper()
    }
    else {
        return New-OperationResult -Success $false -ErrorMessage "Cannot determine volume from share path: $shareLocalPath"
    }

    # Get retention count
    $keepCount = Get-VolumeRetentionCount -Volume $volume -Config $Config

    Write-RobocurseLog -Message "Enforcing remote retention on '$serverName' for $volume (keep: $keepCount)" -Level 'Info' -Component 'Orchestration'

    # Step 1: Enforce retention
    $retentionResult = Invoke-RemoteVssRetentionPolicy -ServerName $serverName -Volume $volume -KeepCount $keepCount
    if (-not $retentionResult.Success) {
        Write-RobocurseLog -Message "Remote retention failed: $($retentionResult.ErrorMessage)" -Level 'Warning' -Component 'Orchestration'
    }

    # Step 2: Create new persistent snapshot
    $snapshotResult = New-RemoteVssSnapshot -UncPath $SourcePath
    if (-not $snapshotResult.Success) {
        return New-OperationResult -Success $false -ErrorMessage "Failed to create remote persistent snapshot: $($snapshotResult.ErrorMessage)"
    }

    Write-RobocurseLog -Message "Created remote persistent snapshot on '$serverName': $($snapshotResult.Data.ShadowId)" -Level 'Info' -Component 'Orchestration'

    return $snapshotResult
}

function Get-VolumeRetentionCount {
    <#
    .SYNOPSIS
        Gets the retention count for a specific volume from config
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Volume,

        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $volumeUpper = $Volume.ToUpper()
    $retention = $Config.GlobalSettings.SnapshotRetention

    # Check for volume-specific override
    if ($retention.VolumeOverrides -and $retention.VolumeOverrides.ContainsKey($volumeUpper)) {
        return $retention.VolumeOverrides[$volumeUpper]
    }

    # Return default
    return $retention.DefaultKeepCount
}
```

**Modify `Start-ProfileReplication` (around line 237):**

Insert call to persistent snapshot function BEFORE the existing VSS logic:

```powershell
# Around line 237, BEFORE "if ($Profile.UseVss) {"

# Create persistent snapshot if enabled (separate from temp VSS for backup)
$persistentSnapshotResult = Invoke-ProfilePersistentSnapshot -Profile $Profile -Config $script:Config
if (-not $persistentSnapshotResult.Success) {
    Write-RobocurseLog -Message "Persistent snapshot creation failed: $($persistentSnapshotResult.ErrorMessage)" -Level 'Warning' -Component 'Orchestration'
    # Don't fail the profile - persistent snapshots are optional enhancement
}
elseif ($persistentSnapshotResult.Data) {
    Write-RobocurseLog -Message "Persistent snapshot ready for point-in-time recovery" -Level 'Info' -Component 'Orchestration'
}

# Existing VSS logic for backup consistency continues below...
# if ($Profile.UseVss) { ... }
```

## Test Plan

### File: `tests\Unit\ProfileSnapshotIntegration.Tests.ps1`

```powershell
BeforeAll {
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Utility.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Logging.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssCore.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssLocal.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssRemote.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Configuration.ps1"
    # Note: JobManagement.ps1 would need to be loadable standalone for full testing

    Mock Write-RobocurseLog {}
}

Describe "Get-VolumeRetentionCount" {
    Context "When volume has specific override" {
        It "Returns the override value" {
            $config = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    SnapshotRetention = [PSCustomObject]@{
                        DefaultKeepCount = 3
                        VolumeOverrides = @{ "D:" = 10; "E:" = 5 }
                    }
                }
            }

            $count = Get-VolumeRetentionCount -Volume "D:" -Config $config
            $count | Should -Be 10
        }
    }

    Context "When volume has no override" {
        It "Returns the default value" {
            $config = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    SnapshotRetention = [PSCustomObject]@{
                        DefaultKeepCount = 7
                        VolumeOverrides = @{ "E:" = 5 }
                    }
                }
            }

            $count = Get-VolumeRetentionCount -Volume "D:" -Config $config
            $count | Should -Be 7
        }
    }

    Context "Case insensitivity" {
        It "Handles lowercase volume input" {
            $config = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    SnapshotRetention = [PSCustomObject]@{
                        DefaultKeepCount = 3
                        VolumeOverrides = @{ "D:" = 10 }
                    }
                }
            }

            $count = Get-VolumeRetentionCount -Volume "d:" -Config $config
            $count | Should -Be 10
        }
    }
}

Describe "Invoke-ProfilePersistentSnapshot" {
    Context "When PersistentSnapshot is not enabled" {
        It "Returns success with null data" {
            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = "D:\Data"
                PersistentSnapshot = [PSCustomObject]@{ Enabled = $false }
            }
            $config = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    SnapshotRetention = [PSCustomObject]@{
                        DefaultKeepCount = 3
                        VolumeOverrides = @{}
                    }
                }
            }

            $result = Invoke-ProfilePersistentSnapshot -Profile $profile -Config $config
            $result.Success | Should -Be $true
            $result.Data | Should -BeNull
        }
    }

    Context "When PersistentSnapshot is enabled for local path" {
        BeforeAll {
            Mock Invoke-VssRetentionPolicy { New-OperationResult -Success $true -Data @{ DeletedCount = 0; KeptCount = 2 } }
            Mock New-VssSnapshot { New-OperationResult -Success $true -Data @{ ShadowId = "{new-snap}" } }
            Mock Get-VolumeFromPath { "D:" }
        }

        It "Enforces retention and creates snapshot" {
            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = "D:\Data"
                PersistentSnapshot = [PSCustomObject]@{ Enabled = $true }
            }
            $config = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    SnapshotRetention = [PSCustomObject]@{
                        DefaultKeepCount = 3
                        VolumeOverrides = @{}
                    }
                }
            }

            $result = Invoke-ProfilePersistentSnapshot -Profile $profile -Config $config
            $result.Success | Should -Be $true

            Should -Invoke Invoke-VssRetentionPolicy -Times 1
            Should -Invoke New-VssSnapshot -Times 1
        }
    }

    Context "When PersistentSnapshot is enabled for UNC path" {
        BeforeAll {
            Mock Get-UncPathComponents {
                [PSCustomObject]@{ ServerName = "Server1"; ShareName = "Share1"; RelativePath = "Folder" }
            }
            Mock Get-RemoteShareLocalPath { "D:\ShareRoot" }
            Mock Invoke-RemoteVssRetentionPolicy { New-OperationResult -Success $true -Data @{ DeletedCount = 1 } }
            Mock New-RemoteVssSnapshot { New-OperationResult -Success $true -Data @{ ShadowId = "{remote-snap}" } }
        }

        It "Uses remote functions" {
            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = "\\Server1\Share1\Folder"
                PersistentSnapshot = [PSCustomObject]@{ Enabled = $true }
            }
            $config = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    SnapshotRetention = [PSCustomObject]@{
                        DefaultKeepCount = 5
                        VolumeOverrides = @{}
                    }
                }
            }

            $result = Invoke-ProfilePersistentSnapshot -Profile $profile -Config $config
            $result.Success | Should -Be $true

            Should -Invoke Invoke-RemoteVssRetentionPolicy -Times 1
            Should -Invoke New-RemoteVssSnapshot -Times 1
        }
    }
}

Describe "Configuration Schema" {
    Context "New-DefaultConfig includes snapshot retention" {
        It "Has SnapshotRetention in GlobalSettings" {
            $config = New-DefaultConfig
            $config.GlobalSettings.SnapshotRetention | Should -Not -BeNull
            $config.GlobalSettings.SnapshotRetention.DefaultKeepCount | Should -Be 3
        }
    }
}
```

## Files to Modify
- `src\Robocurse\Public\Configuration.ps1` - Add SnapshotRetention settings and PersistentSnapshot profile property
- `src\Robocurse\Public\JobManagement.ps1` - Add persistent snapshot functions and hook into profile start

## Files to Create
- `tests\Unit\ProfileSnapshotIntegration.Tests.ps1` - Unit tests

## Verification
```powershell
# Run unit tests
Invoke-Pester -Path tests\Unit\ProfileSnapshotIntegration.Tests.ps1 -Output Detailed

# Example config with persistent snapshots enabled:
# {
#   "profiles": {
#     "DailyBackup": {
#       "source": { "path": "D:\\Data", "useVss": true },
#       "destination": { "path": "E:\\Backup" },
#       "persistentSnapshot": { "enabled": true }
#     }
#   },
#   "global": {
#     "snapshotRetention": {
#       "defaultKeepCount": 3,
#       "volumeOverrides": { "D:": 5, "E:": 10 }
#     }
#   }
# }
```

## Dependencies
- Task 01 (VssSnapshotCore) - For `Invoke-VssRetentionPolicy`
- Task 02 (VssSnapshotRemote) - For `Invoke-RemoteVssRetentionPolicy`

## Notes
- Persistent snapshots are created BEFORE temporary backup VSS (if both enabled)
- Persistent snapshots do NOT get cleaned up after backup - that's the point
- Retention enforcement happens BEFORE creating new snapshot (to make room)
- Volume overrides allow different retention per volume (server might have more snapshots for critical volumes)
- If persistent snapshot creation fails, backup continues (it's an enhancement, not a blocker)
