# Task: Drive Orphan Cleanup at Startup

## Objective
Add a function to clean up orphaned network drive mappings at application startup, following the same pattern as `Clear-OrphanVssSnapshots`.

## Problem Statement
If the application crashes or is terminated unexpectedly, mapped network drives remain. On next startup, these orphaned mappings:
- Consume available drive letters (Z, Y, X...)
- May conflict with new mapping attempts
- Require manual cleanup via `net use /delete`

## Success Criteria
1. `Clear-OrphanNetworkMappings` function cleans up tracked mappings at startup
2. Function is called from `Initialize-OrchestrationState` (like VSS cleanup)
3. Only tracked mappings are removed (not user's other mapped drives)
4. Tracking file is updated after cleanup
5. All tests pass

## Research: Current Implementation

### Clear-OrphanVssSnapshots Pattern (VssLocal.ps1:5-97)
```powershell
function Clear-OrphanVssSnapshots {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not (Test-Path $script:VssTrackingFile)) {
        return 0
    }

    $cleaned = 0
    $failedSnapshots = @()

    try {
        $trackedSnapshots = Get-Content $script:VssTrackingFile -Raw | ConvertFrom-Json
        $trackedSnapshots = @($trackedSnapshots)

        foreach ($snapshot in $trackedSnapshots) {
            if ($PSCmdlet.ShouldProcess($snapshot.ShadowId, "Remove orphan VSS snapshot")) {
                $removeResult = Remove-VssSnapshot -ShadowId $snapshot.ShadowId
                if ($removeResult.Success) {
                    $cleaned++
                } else {
                    $failedSnapshots += $snapshot
                }
            }
        }

        # Update tracking file
        if ($failedSnapshots.Count -eq 0) {
            Remove-Item $script:VssTrackingFile -Force
        } else {
            $failedSnapshots | ConvertTo-Json | Set-Content $script:VssTrackingFile
        }
    }
    catch { ... }

    return $cleaned
}
```

### Initialize-OrchestrationState Call (OrchestrationCore.ps1:709)
```powershell
$orphansCleared = Clear-OrphanVssSnapshots
```

## Implementation Plan

### Step 1: Add Clear-OrphanNetworkMappings Function
Add to NetworkMapping.ps1:

```powershell
function Clear-OrphanNetworkMappings {
    <#
    .SYNOPSIS
        Cleans up network drive mappings that may have been left behind from crashed runs
    .DESCRIPTION
        Reads the network mapping tracking file and removes any mappings that are still present.
        This should be called at startup to clean up after unexpected terminations.

        Only mappings tracked by Robocurse are removed - other user-created mappings are left alone.
    .OUTPUTS
        Number of mappings cleaned up
    .EXAMPLE
        $cleaned = Clear-OrphanNetworkMappings
        if ($cleaned -gt 0) { Write-Host "Cleaned up $cleaned orphan drive mappings" }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $script:NetworkMappingTrackingFile) {
        Initialize-NetworkMappingTracking
    }

    if (-not (Test-Path $script:NetworkMappingTrackingFile)) {
        return 0
    }

    $cleaned = 0
    $failedMappings = @()

    try {
        $trackedMappings = Get-Content $script:NetworkMappingTrackingFile -Raw | ConvertFrom-Json
        $trackedMappings = @($trackedMappings)

        foreach ($mapping in $trackedMappings) {
            $letter = $mapping.DriveLetter.TrimEnd(':')
            $displayName = "$($mapping.DriveLetter) -> $($mapping.Root)"

            if ($PSCmdlet.ShouldProcess($displayName, "Remove orphan network mapping")) {
                try {
                    # Check if drive is actually mapped
                    $existingDrive = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue

                    if ($existingDrive) {
                        # Verify it's the same mapping (not a different user mapping)
                        if ($existingDrive.Root -eq $mapping.Root) {
                            Remove-PSDrive -Name $letter -Force -ErrorAction Stop
                            Write-RobocurseLog -Message "Cleaned up orphan network mapping: $displayName" `
                                -Level 'Info' -Component 'NetworkMapping'
                            $cleaned++
                        }
                        else {
                            # Drive exists but points elsewhere - remove from tracking only
                            Write-RobocurseLog -Message "Drive $letter exists but points to different location, removing from tracking" `
                                -Level 'Debug' -Component 'NetworkMapping'
                        }
                    }
                    else {
                        # Drive not mapped - just clean up tracking
                        Write-RobocurseLog -Message "Tracked mapping $letter no longer exists, cleaning up tracking" `
                            -Level 'Debug' -Component 'NetworkMapping'
                    }
                }
                catch {
                    Write-RobocurseLog -Message "Failed to cleanup orphan mapping $displayName`: $($_.Exception.Message)" `
                        -Level 'Warning' -Component 'NetworkMapping'
                    $failedMappings += $mapping
                }
            }
        }

        # Update tracking file
        if ($PSCmdlet.ShouldProcess($script:NetworkMappingTrackingFile, "Update tracking file")) {
            if ($failedMappings.Count -eq 0) {
                Remove-Item $script:NetworkMappingTrackingFile -Force -ErrorAction SilentlyContinue
                Write-RobocurseLog -Message "All orphan mappings cleaned - removed tracking file" `
                    -Level 'Debug' -Component 'NetworkMapping'
            }
            elseif ($cleaned -gt 0) {
                # Some succeeded, some failed - keep failed entries
                $failedMappings | ConvertTo-Json -Depth 5 | Set-Content $script:NetworkMappingTrackingFile -Encoding UTF8
                Write-RobocurseLog -Message "Updated tracking file: $($failedMappings.Count) mappings remain for retry" `
                    -Level 'Warning' -Component 'NetworkMapping'
            }
        }
    }
    catch {
        Write-RobocurseLog -Message "Error during orphan mapping cleanup: $($_.Exception.Message)" `
            -Level 'Warning' -Component 'NetworkMapping'
    }

    return $cleaned
}
```

### Step 2: Call from Initialize-OrchestrationState
In OrchestrationCore.ps1, after the VSS cleanup call (around line 710):

```powershell
# Clean up orphan VSS snapshots
$vssOrphansCleared = Clear-OrphanVssSnapshots

# Clean up orphan network mappings
$mappingOrphansCleared = Clear-OrphanNetworkMappings
if ($mappingOrphansCleared -gt 0) {
    Write-RobocurseLog -Message "Cleaned up $mappingOrphansCleared orphan network mapping(s) from previous run" `
        -Level 'Info' -Component 'Orchestrator'
}
```

## Test Plan

Add to `tests/Unit/NetworkMapping.Tests.ps1`:

```powershell
Context "Clear-OrphanNetworkMappings" {
    BeforeEach {
        $script:TestLogPath = Join-Path $env:TEMP "RobocurseOrphanTest_$(Get-Random)"
        New-Item -Path $script:TestLogPath -ItemType Directory -Force | Out-Null
        $script:LogPath = $script:TestLogPath
        Initialize-NetworkMappingTracking
    }

    AfterEach {
        if (Test-Path $script:TestLogPath) {
            Remove-Item $script:TestLogPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should return 0 when no tracking file exists" {
        $result = Clear-OrphanNetworkMappings
        $result | Should -Be 0
    }

    It "Should clean up tracking file when all mappings are gone" {
        # Create tracking file with non-existent mapping
        $trackingData = @(
            @{ DriveLetter = "Q:"; Root = "\\nonexistent\share"; OriginalPath = "\\nonexistent\share"; MappedPath = "Q:\" }
        )
        $trackingData | ConvertTo-Json | Set-Content $script:NetworkMappingTrackingFile

        Mock Get-PSDrive { $null } -ModuleName Robocurse

        Clear-OrphanNetworkMappings

        Test-Path $script:NetworkMappingTrackingFile | Should -Be $false
    }

    It "Should remove drive if it matches tracked mapping" {
        Mock Get-PSDrive {
            [PSCustomObject]@{ Name = "Q"; Root = "\\server\share" }
        } -ModuleName Robocurse
        Mock Remove-PSDrive { } -ModuleName Robocurse

        $trackingData = @(
            @{ DriveLetter = "Q:"; Root = "\\server\share"; OriginalPath = "\\server\share"; MappedPath = "Q:\" }
        )
        $trackingData | ConvertTo-Json | Set-Content $script:NetworkMappingTrackingFile

        $result = Clear-OrphanNetworkMappings

        $result | Should -Be 1
        Should -Invoke Remove-PSDrive -Times 1 -ModuleName Robocurse
    }

    It "Should not remove drive if it points to different location" {
        Mock Get-PSDrive {
            [PSCustomObject]@{ Name = "Q"; Root = "\\different\server" }
        } -ModuleName Robocurse
        Mock Remove-PSDrive { } -ModuleName Robocurse

        $trackingData = @(
            @{ DriveLetter = "Q:"; Root = "\\server\share"; OriginalPath = "\\server\share"; MappedPath = "Q:\" }
        )
        $trackingData | ConvertTo-Json | Set-Content $script:NetworkMappingTrackingFile

        $result = Clear-OrphanNetworkMappings

        Should -Invoke Remove-PSDrive -Times 0 -ModuleName Robocurse
    }

    It "Should support -WhatIf" {
        Mock Get-PSDrive {
            [PSCustomObject]@{ Name = "Q"; Root = "\\server\share" }
        } -ModuleName Robocurse
        Mock Remove-PSDrive { } -ModuleName Robocurse

        $trackingData = @(
            @{ DriveLetter = "Q:"; Root = "\\server\share" }
        )
        $trackingData | ConvertTo-Json | Set-Content $script:NetworkMappingTrackingFile

        Clear-OrphanNetworkMappings -WhatIf

        Should -Invoke Remove-PSDrive -Times 0 -ModuleName Robocurse
        Test-Path $script:NetworkMappingTrackingFile | Should -Be $true
    }
}
```

## Files to Modify
1. `src/Robocurse/Public/NetworkMapping.ps1` - Add Clear-OrphanNetworkMappings function
2. `src/Robocurse/Public/OrchestrationCore.ps1` - Call from Initialize-OrchestrationState (~line 710)
3. `tests/Unit/NetworkMapping.Tests.ps1` - Add orphan cleanup tests

## Verification Commands
```powershell
# Run tests
.\scripts\run-tests.ps1

# Manual test
# 1. Map a drive manually: net use Y: \\server\share
# 2. Create tracking file with that mapping
# 3. Call Clear-OrphanNetworkMappings
# 4. Verify drive unmapped: net use
```

## Notes
- Only removes drives that match BOTH letter AND root from tracking
- Other user-mapped drives are left untouched
- Supports -WhatIf for safe testing
- Follows same error handling pattern as VSS cleanup
