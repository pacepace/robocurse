# Task: MaxTotalSnapshots Config Setting

## Process Requirements (EAD)

**TDD is mandatory**: Write tests FIRST, then implementation.

**Logging conventions**: Use `Write-RobocurseLog -Message "..." -Level 'Error|Warning|Info|Debug' -Component 'VSS'`

**Return values**: All functions return `OperationResult` via `New-OperationResult -Success $bool -Data $obj -ErrorMessage $msg`

**Test execution**: Use `.\scripts\run-tests.ps1` to avoid truncation.

---

## Objective

Add `MaxTotalSnapshots` configuration setting to `GlobalSettings.SnapshotRetention` to control the hard cap on total VSS snapshots per volume.

## Success Criteria

1. Config schema includes `GlobalSettings.SnapshotRetention.MaxTotalSnapshots` (default 0 = unlimited)
2. Existing configs without the setting get default value on load (migration)
3. Tests verify schema, defaults, and migration

## Research

- Configuration.ps1:85-88 - Existing `SnapshotRetention` structure under `GlobalSettings`
- Configuration.ps1:107-111 - `SnapshotRegistry` at config root (NOT under GlobalSettings)
- VssCore.ps1:472-560 - `Get-EffectiveVolumeRetention` pattern to follow for similar function

## Test Plan (WRITE FIRST)

File: `tests/Unit/SnapshotSafetyConfig.Tests.ps1`

```powershell
Describe 'MaxTotalSnapshots Config' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\Robocurse\Public\Configuration.ps1"
        . "$PSScriptRoot\..\..\src\Robocurse\Public\VssCore.ps1"
    }

    Context 'New-DefaultConfig' {
        It 'includes MaxTotalSnapshots defaulting to 0' {
            $config = New-DefaultConfig
            $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots | Should -Be 0
        }
    }

    Context 'Get-EffectiveMaxTotalSnapshots' {
        It 'returns 0 when not configured (unlimited)' {
            $config = New-DefaultConfig
            Get-EffectiveMaxTotalSnapshots -Volume 'C:' -Config $config | Should -Be 0
        }

        It 'returns configured value' {
            $config = New-DefaultConfig
            $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots = 10
            Get-EffectiveMaxTotalSnapshots -Volume 'C:' -Config $config | Should -Be 10
        }
    }

    Context 'Config Migration' {
        It 'adds MaxTotalSnapshots to old configs without it' {
            # Simulate old config without MaxTotalSnapshots
            $oldConfig = @{
                globalSettings = @{
                    snapshotRetention = @{
                        defaultKeepCount = 3
                        volumeOverrides = @{}
                    }
                }
            }
            $tempPath = Join-Path $env:TEMP "test-config-$(Get-Random).json"
            $oldConfig | ConvertTo-Json -Depth 10 | Set-Content $tempPath

            $loaded = Get-RobocurseConfig -Path $tempPath
            $loaded.GlobalSettings.SnapshotRetention.MaxTotalSnapshots | Should -Be 0

            Remove-Item $tempPath -Force
        }
    }
}
```

## Implementation

### 1. Update New-DefaultConfig (Configuration.ps1:85-88)

```powershell
SnapshotRetention = [PSCustomObject]@{
    DefaultKeepCount = 3
    VolumeOverrides = @{}
    MaxTotalSnapshots = 0       # NEW: 0 = unlimited, >0 = hard cap (all snapshots on volume)
}
```

### 2. Add Get-EffectiveMaxTotalSnapshots function (VssCore.ps1, after Get-EffectiveVolumeRetention)

```powershell
function Get-EffectiveMaxTotalSnapshots {
    <#
    .SYNOPSIS
        Gets the effective max total snapshots limit for a volume
    .DESCRIPTION
        Returns MaxTotalSnapshots from GlobalSettings.SnapshotRetention.
        This is a hard cap on ALL snapshots (ours + external).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Volume,

        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $retention = $Config.GlobalSettings.SnapshotRetention
    if (-not $retention) {
        return 0  # Unlimited if not configured
    }

    return if ($retention.MaxTotalSnapshots) { $retention.MaxTotalSnapshots } else { 0 }
}
```

### 3. Add config migration in ConvertFrom-RobocurseConfigInternal (Configuration.ps1:459-464 area)

```powershell
# Ensure MaxTotalSnapshots exists (migration for existing configs)
if (-not $config.GlobalSettings.SnapshotRetention.PSObject.Properties['MaxTotalSnapshots']) {
    $config.GlobalSettings.SnapshotRetention | Add-Member -NotePropertyName MaxTotalSnapshots -NotePropertyValue 0 -Force
}
```

## Files to Modify

- `src/Robocurse/Public/Configuration.ps1` - Default config + migration
- `src/Robocurse/Public/VssCore.ps1` - New function
- `tests/Unit/SnapshotSafetyConfig.Tests.ps1` (new)

## Verification

```powershell
.\scripts\run-tests.ps1
powershell -NoProfile -Command 'Get-Content $env:TEMP\pester-summary.txt'
```
