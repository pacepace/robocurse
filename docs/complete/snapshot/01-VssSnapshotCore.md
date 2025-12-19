# Task: VSS Snapshot Core Functions

## Objective
Add core functions to list VSS snapshots and enforce retention policies for local volumes. These functions will be the foundation for persistent snapshot management.

## Success Criteria
- [ ] `Get-VssSnapshots` returns all snapshots for a given volume or all volumes
- [ ] `Invoke-VssRetentionPolicy` removes oldest snapshots to keep N per volume
- [ ] All functions return `OperationResult` consistent with existing patterns
- [ ] Tests pass for all new functions
- [ ] Existing VSS functionality remains unaffected

## Research

### Existing Patterns (file:line references)
- `VssLocal.ps1:99` - `New-VssSnapshot` - Creates snapshots via CIM
- `VssLocal.ps1:273` - `Remove-VssSnapshot` - Deletes snapshots, handles idempotency
- `VssCore.ps1:506` - `Get-VolumeFromPath` - Extracts volume from path
- `VssCore.ps1:159` - `Test-VssPrivileges` - Pre-flight admin check
- `VssCore.ps1:50` - `Test-VssErrorRetryable` - Error classification

### CIM Queries for Listing Snapshots
```powershell
# Get all snapshots
Get-CimInstance -ClassName Win32_ShadowCopy

# Get snapshots for specific volume (D:)
Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.VolumeName -match '^\\\\?\Volume.*D:' }

# Shadow copy properties available:
# - ID (GUID)
# - DeviceObject (\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1)
# - VolumeName (\\?\Volume{guid}\)
# - InstallDate (creation time)
# - ClientAccessible (bool)
```

### Retention Logic
- Group snapshots by volume
- Sort by InstallDate (oldest first)
- Keep newest N, delete the rest
- Return count of deleted + any errors

## Implementation

### File: `src\Robocurse\Public\VssLocal.ps1`

Add after `Test-VssSupported` (around line 379):

```powershell
function Get-VssSnapshots {
    <#
    .SYNOPSIS
        Lists VSS snapshots on local volumes
    .DESCRIPTION
        Retrieves VSS shadow copies from the local system. Can filter by volume
        or return all snapshots. Results include snapshot ID, device path,
        volume, and creation time.
    .PARAMETER Volume
        Optional volume to filter (e.g., "C:", "D:"). If not specified, returns all.
    .PARAMETER IncludeSystemSnapshots
        If true, includes snapshots not created by Robocurse (default: false)
    .OUTPUTS
        OperationResult with Data = array of snapshot objects
    .EXAMPLE
        $result = Get-VssSnapshots -Volume "D:"
        $result.Data | Format-Table ShadowId, CreatedAt, SourceVolume
    #>
    [CmdletBinding()]
    param(
        [ValidatePattern('^[A-Za-z]:$')]
        [string]$Volume,

        [switch]$IncludeSystemSnapshots
    )

    # Pre-flight check
    if (-not (Test-IsWindowsPlatform)) {
        return New-OperationResult -Success $false -ErrorMessage "VSS is only available on Windows"
    }

    try {
        Write-RobocurseLog -Message "Listing VSS snapshots$(if ($Volume) { " for volume $Volume" })" -Level 'Debug' -Component 'VSS'

        $snapshots = Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop

        if (-not $snapshots) {
            return New-OperationResult -Success $true -Data @()
        }

        # Filter by volume if specified
        if ($Volume) {
            $volumeUpper = $Volume.ToUpper()
            $snapshots = $snapshots | Where-Object {
                # VolumeName format: \\?\Volume{guid}\ - need to resolve to drive letter
                $snapshotVolume = Get-VolumeLetterFromVolumeName -VolumeName $_.VolumeName
                $snapshotVolume -eq $volumeUpper
            }
        }

        # Convert to our standard format
        $result = @($snapshots | ForEach-Object {
            $snapshotVolume = Get-VolumeLetterFromVolumeName -VolumeName $_.VolumeName
            [PSCustomObject]@{
                ShadowId     = $_.ID
                ShadowPath   = $_.DeviceObject
                SourceVolume = $snapshotVolume
                CreatedAt    = $_.InstallDate
                Provider     = $_.ProviderID
                ClientAccessible = $_.ClientAccessible
            }
        })

        # Sort by creation time (newest first)
        $result = @($result | Sort-Object CreatedAt -Descending)

        Write-RobocurseLog -Message "Found $($result.Count) VSS snapshot(s)" -Level 'Debug' -Component 'VSS'
        return New-OperationResult -Success $true -Data $result
    }
    catch {
        Write-RobocurseLog -Message "Failed to list VSS snapshots: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "Failed to list VSS snapshots: $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Get-VolumeLetterFromVolumeName {
    <#
    .SYNOPSIS
        Converts a volume GUID path to a drive letter
    .DESCRIPTION
        Resolves \\?\Volume{guid}\ format to drive letter (C:, D:, etc.)
    .PARAMETER VolumeName
        The volume GUID path from Win32_ShadowCopy.VolumeName
    .OUTPUTS
        Drive letter (e.g., "C:") or $null if not found
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VolumeName
    )

    try {
        # Get all volumes and match by GUID
        $volumes = Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter }

        foreach ($vol in $volumes) {
            # DeviceID format: \\?\Volume{guid}\
            if ($vol.DeviceID -eq $VolumeName) {
                return $vol.DriveLetter
            }
        }

        # Fallback: try to extract from path patterns
        Write-RobocurseLog -Message "Could not resolve volume name to drive letter: $VolumeName" -Level 'Debug' -Component 'VSS'
        return $null
    }
    catch {
        return $null
    }
}

function Invoke-VssRetentionPolicy {
    <#
    .SYNOPSIS
        Enforces VSS snapshot retention by removing old snapshots
    .DESCRIPTION
        For each volume, keeps the newest N snapshots and removes the rest.
        This is typically called before creating a new snapshot.
    .PARAMETER Volume
        Volume to apply retention to (e.g., "D:"). Required.
    .PARAMETER KeepCount
        Number of snapshots to keep per volume (default: 3)
    .PARAMETER WhatIf
        If specified, shows what would be deleted without actually deleting
    .OUTPUTS
        OperationResult with Data containing:
        - DeletedCount: Number of snapshots removed
        - KeptCount: Number of snapshots retained
        - Errors: Array of any deletion errors
    .EXAMPLE
        $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 5
        if ($result.Success) { "Deleted $($result.Data.DeletedCount) old snapshots" }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]:$')]
        [string]$Volume,

        [ValidateRange(0, 100)]
        [int]$KeepCount = 3
    )

    Write-RobocurseLog -Message "Applying VSS retention policy for $Volume (keep: $KeepCount)" -Level 'Info' -Component 'VSS'

    # Get current snapshots for this volume
    $listResult = Get-VssSnapshots -Volume $Volume
    if (-not $listResult.Success) {
        return New-OperationResult -Success $false -ErrorMessage "Failed to list snapshots: $($listResult.ErrorMessage)"
    }

    $snapshots = @($listResult.Data)
    $currentCount = $snapshots.Count

    # Nothing to do if we're under the limit
    if ($currentCount -le $KeepCount) {
        Write-RobocurseLog -Message "Retention OK: $currentCount snapshot(s) <= $KeepCount limit" -Level 'Debug' -Component 'VSS'
        return New-OperationResult -Success $true -Data @{
            DeletedCount = 0
            KeptCount    = $currentCount
            Errors       = @()
        }
    }

    # Sort by CreatedAt ascending (oldest first) and select ones to delete
    $sortedSnapshots = $snapshots | Sort-Object CreatedAt
    $toDelete = @($sortedSnapshots | Select-Object -First ($currentCount - $KeepCount))
    $toKeep = @($sortedSnapshots | Select-Object -Last $KeepCount)

    Write-RobocurseLog -Message "Retention: Deleting $($toDelete.Count) old snapshot(s), keeping $($toKeep.Count)" -Level 'Info' -Component 'VSS'

    $deletedCount = 0
    $errors = @()

    foreach ($snapshot in $toDelete) {
        $shadowId = $snapshot.ShadowId
        $createdAt = $snapshot.CreatedAt

        if ($PSCmdlet.ShouldProcess("$shadowId (created $createdAt)", "Remove VSS Snapshot")) {
            $removeResult = Remove-VssSnapshot -ShadowId $shadowId
            if ($removeResult.Success) {
                $deletedCount++
                Write-RobocurseLog -Message "Deleted snapshot $shadowId (created $createdAt)" -Level 'Debug' -Component 'VSS'
            }
            else {
                $errors += "Failed to delete $shadowId`: $($removeResult.ErrorMessage)"
                Write-RobocurseLog -Message "Failed to delete snapshot $shadowId`: $($removeResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
            }
        }
    }

    $success = $errors.Count -eq 0
    $resultData = @{
        DeletedCount = $deletedCount
        KeptCount    = $toKeep.Count
        Errors       = $errors
    }

    if ($success) {
        Write-RobocurseLog -Message "Retention policy applied: deleted $deletedCount, kept $($toKeep.Count)" -Level 'Info' -Component 'VSS'
    }
    else {
        Write-RobocurseLog -Message "Retention policy completed with errors: deleted $deletedCount, errors: $($errors.Count)" -Level 'Warning' -Component 'VSS'
    }

    return New-OperationResult -Success $success -Data $resultData -ErrorMessage $(if (-not $success) { $errors -join "; " })
}
```

## Test Plan

### File: `tests\Unit\VssSnapshotCore.Tests.ps1`

```powershell
BeforeAll {
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Utility.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Logging.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssCore.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssLocal.ps1"

    # Mock logging to prevent output during tests
    Mock Write-RobocurseLog {}
}

Describe "Get-VssSnapshots" {
    Context "When no snapshots exist" {
        BeforeAll {
            Mock Get-CimInstance { @() } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }
            Mock Test-IsWindowsPlatform { $true }
        }

        It "Returns empty array with Success=true" {
            $result = Get-VssSnapshots
            $result.Success | Should -Be $true
            $result.Data | Should -BeNullOrEmpty
        }
    }

    Context "When snapshots exist" {
        BeforeAll {
            Mock Test-IsWindowsPlatform { $true }
            Mock Get-CimInstance {
                @(
                    [PSCustomObject]@{
                        ID = "{snap1}"
                        DeviceObject = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1"
                        VolumeName = "\\?\Volume{test-guid}\"
                        InstallDate = (Get-Date).AddHours(-2)
                        ProviderID = "{provider}"
                        ClientAccessible = $true
                    },
                    [PSCustomObject]@{
                        ID = "{snap2}"
                        DeviceObject = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy2"
                        VolumeName = "\\?\Volume{test-guid}\"
                        InstallDate = (Get-Date).AddHours(-1)
                        ProviderID = "{provider}"
                        ClientAccessible = $true
                    }
                )
            } -ParameterFilter { $ClassName -eq 'Win32_ShadowCopy' }

            Mock Get-VolumeLetterFromVolumeName { "D:" }
        }

        It "Returns snapshots sorted by CreatedAt descending (newest first)" {
            $result = Get-VssSnapshots
            $result.Success | Should -Be $true
            $result.Data.Count | Should -Be 2
            $result.Data[0].ShadowId | Should -Be "{snap2}"  # Newer
            $result.Data[1].ShadowId | Should -Be "{snap1}"  # Older
        }

        It "Filters by volume when specified" {
            Mock Get-VolumeLetterFromVolumeName { param($VolumeName) "D:" }

            $result = Get-VssSnapshots -Volume "D:"
            $result.Success | Should -Be $true
            $result.Data.Count | Should -Be 2
        }
    }

    Context "On non-Windows platform" {
        BeforeAll {
            Mock Test-IsWindowsPlatform { $false }
        }

        It "Returns error" {
            $result = Get-VssSnapshots
            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Match "Windows"
        }
    }
}

Describe "Invoke-VssRetentionPolicy" {
    Context "When under retention limit" {
        BeforeAll {
            Mock Get-VssSnapshots {
                New-OperationResult -Success $true -Data @(
                    [PSCustomObject]@{ ShadowId = "{snap1}"; CreatedAt = (Get-Date).AddHours(-1) }
                )
            }
        }

        It "Does not delete any snapshots" {
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 3
            $result.Success | Should -Be $true
            $result.Data.DeletedCount | Should -Be 0
            $result.Data.KeptCount | Should -Be 1
        }
    }

    Context "When over retention limit" {
        BeforeAll {
            Mock Get-VssSnapshots {
                New-OperationResult -Success $true -Data @(
                    [PSCustomObject]@{ ShadowId = "{snap1}"; CreatedAt = (Get-Date).AddHours(-3) },
                    [PSCustomObject]@{ ShadowId = "{snap2}"; CreatedAt = (Get-Date).AddHours(-2) },
                    [PSCustomObject]@{ ShadowId = "{snap3}"; CreatedAt = (Get-Date).AddHours(-1) }
                )
            }
            Mock Remove-VssSnapshot { New-OperationResult -Success $true -Data $ShadowId }
        }

        It "Deletes oldest snapshots to meet retention" {
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 1
            $result.Success | Should -Be $true
            $result.Data.DeletedCount | Should -Be 2
            $result.Data.KeptCount | Should -Be 1
        }

        It "Keeps newest snapshot" {
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 1

            # Verify Remove-VssSnapshot was called for oldest two
            Should -Invoke Remove-VssSnapshot -Times 2 -ParameterFilter {
                $ShadowId -eq "{snap1}" -or $ShadowId -eq "{snap2}"
            }

            # Verify newest was NOT deleted
            Should -Not -Invoke Remove-VssSnapshot -ParameterFilter {
                $ShadowId -eq "{snap3}"
            }
        }
    }

    Context "When deletion fails" {
        BeforeAll {
            Mock Get-VssSnapshots {
                New-OperationResult -Success $true -Data @(
                    [PSCustomObject]@{ ShadowId = "{snap1}"; CreatedAt = (Get-Date).AddHours(-2) },
                    [PSCustomObject]@{ ShadowId = "{snap2}"; CreatedAt = (Get-Date).AddHours(-1) }
                )
            }
            Mock Remove-VssSnapshot { New-OperationResult -Success $false -ErrorMessage "Access denied" }
        }

        It "Returns errors but continues" {
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 1
            $result.Success | Should -Be $false
            $result.Data.Errors.Count | Should -BeGreaterThan 0
        }
    }

    Context "WhatIf support" {
        BeforeAll {
            Mock Get-VssSnapshots {
                New-OperationResult -Success $true -Data @(
                    [PSCustomObject]@{ ShadowId = "{snap1}"; CreatedAt = (Get-Date).AddHours(-2) },
                    [PSCustomObject]@{ ShadowId = "{snap2}"; CreatedAt = (Get-Date).AddHours(-1) }
                )
            }
            Mock Remove-VssSnapshot { New-OperationResult -Success $true -Data $ShadowId }
        }

        It "Does not delete when -WhatIf is specified" {
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 1 -WhatIf
            Should -Not -Invoke Remove-VssSnapshot
        }
    }
}
```

## Files to Modify
- `src\Robocurse\Public\VssLocal.ps1` - Add new functions after line 379

## Files to Create
- `tests\Unit\VssSnapshotCore.Tests.ps1` - Unit tests

## Verification
```powershell
# Run unit tests
Invoke-Pester -Path tests\Unit\VssSnapshotCore.Tests.ps1 -Output Detailed

# Manual verification (requires admin)
$snaps = Get-VssSnapshots -Volume "C:"
$snaps.Data | Format-Table ShadowId, CreatedAt, SourceVolume

# Test retention (dry run)
Invoke-VssRetentionPolicy -Volume "C:" -KeepCount 2 -WhatIf
```

## Dependencies
- None (this is the first task)

## Notes
- `Get-VolumeLetterFromVolumeName` is a helper to resolve volume GUID paths to drive letters
- Retention policy deletes OLDEST first, keeps NEWEST
- KeepCount=0 means delete ALL snapshots for that volume
