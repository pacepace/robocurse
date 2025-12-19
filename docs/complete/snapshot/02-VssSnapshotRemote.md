# Task: VSS Snapshot Remote Functions

## Objective
Add remote versions of snapshot listing and retention enforcement via CIM sessions. These mirror the local functions from Task 01 but operate on remote servers.

## Success Criteria
- [ ] `Get-RemoteVssSnapshots` lists snapshots on a remote server
- [ ] `Invoke-RemoteVssRetentionPolicy` enforces retention on a remote server
- [ ] Functions use existing CIM session patterns from `VssRemote.ps1`
- [ ] Tests pass with mocked CIM sessions
- [ ] Error handling provides actionable guidance

## Research

### Existing Remote VSS Patterns (file:line references)
- `VssRemote.ps1:183` - `New-RemoteVssSnapshot` - Creates via remote CIM
- `VssRemote.ps1:339` - `Remove-RemoteVssSnapshot` - Deletes via remote CIM
- `VssRemote.ps1:108` - `Test-RemoteVssSupported` - Connectivity checks with guidance
- `VssRemote.ps1:46` - `Get-RemoteShareLocalPath` - Share resolution pattern

### Remote CIM Query Pattern
```powershell
$cimSession = New-CimSession -ComputerName $ServerName -ErrorAction Stop
try {
    $snapshots = Get-CimInstance -CimSession $cimSession -ClassName Win32_ShadowCopy
}
finally {
    Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
}
```

### Error Guidance Patterns (from Test-RemoteVssSupported)
- Access denied -> "Ensure administrative rights on remote server"
- RPC/unavailable -> "Ensure WinRM service is running"
- Network path not found -> "Verify server name and connectivity"
- Firewall blocked -> "Check firewall rules for WinRM"

## Implementation

### File: `src\Robocurse\Public\VssRemote.ps1`

Add after `Invoke-WithRemoteVssJunction` (end of file, around line 748):

```powershell
function Get-RemoteVssSnapshots {
    <#
    .SYNOPSIS
        Lists VSS snapshots on a remote server
    .DESCRIPTION
        Uses a CIM session to query VSS shadow copies on a remote server.
        Can filter by volume or return all snapshots on the server.
    .PARAMETER ServerName
        The remote server name to query
    .PARAMETER Volume
        Optional volume to filter (e.g., "D:"). If not specified, returns all.
    .OUTPUTS
        OperationResult with Data = array of snapshot objects
    .EXAMPLE
        $result = Get-RemoteVssSnapshots -ServerName "FileServer01" -Volume "D:"
        $result.Data | Format-Table ShadowId, CreatedAt, SourceVolume
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerName,

        [ValidatePattern('^[A-Za-z]:$')]
        [string]$Volume
    )

    Write-RobocurseLog -Message "Listing VSS snapshots on '$ServerName'$(if ($Volume) { " for volume $Volume" })" -Level 'Debug' -Component 'VSS'

    $cimSession = $null
    try {
        $cimSession = New-CimSession -ComputerName $ServerName -ErrorAction Stop

        $snapshots = Get-CimInstance -CimSession $cimSession -ClassName Win32_ShadowCopy -ErrorAction Stop

        if (-not $snapshots) {
            return New-OperationResult -Success $true -Data @()
        }

        # Get volume mapping for filtering
        $volumeMap = @{}
        $volumes = Get-CimInstance -CimSession $cimSession -ClassName Win32_Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter }
        foreach ($vol in $volumes) {
            $volumeMap[$vol.DeviceID] = $vol.DriveLetter
        }

        # Convert and filter
        $result = @($snapshots | ForEach-Object {
            $snapshotVolume = $volumeMap[$_.VolumeName]

            # Skip if filtering by volume and doesn't match
            if ($Volume -and $snapshotVolume -ne $Volume.ToUpper()) {
                return
            }

            [PSCustomObject]@{
                ShadowId     = $_.ID
                ShadowPath   = $_.DeviceObject
                SourceVolume = $snapshotVolume
                CreatedAt    = $_.InstallDate
                ServerName   = $ServerName
                IsRemote     = $true
            }
        } | Where-Object { $_ })

        # Sort by creation time (newest first)
        $result = @($result | Sort-Object CreatedAt -Descending)

        Write-RobocurseLog -Message "Found $($result.Count) VSS snapshot(s) on '$ServerName'" -Level 'Debug' -Component 'VSS'
        return New-OperationResult -Success $true -Data $result
    }
    catch {
        $errorMsg = $_.Exception.Message
        $guidance = Get-RemoteVssErrorGuidance -ErrorMessage $errorMsg -ServerName $ServerName
        $fullError = "Failed to list snapshots on '$ServerName': $errorMsg$guidance"

        Write-RobocurseLog -Message $fullError -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage $fullError -ErrorRecord $_
    }
    finally {
        if ($cimSession) {
            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
        }
    }
}

function Get-RemoteVssErrorGuidance {
    <#
    .SYNOPSIS
        Returns actionable guidance for remote VSS errors
    #>
    [CmdletBinding()]
    param(
        [string]$ErrorMessage,
        [string]$ServerName
    )

    if ($ErrorMessage -match 'Access is denied|Access denied') {
        return " Ensure you have administrative rights on '$ServerName'."
    }
    elseif ($ErrorMessage -match 'RPC server|unavailable|endpoint mapper') {
        return " Ensure WinRM service is running on '$ServerName'. Run 'Enable-PSRemoting -Force' on the remote server."
    }
    elseif ($ErrorMessage -match 'network path|not found|host.*unknown') {
        return " Verify the server name is correct and network connectivity is available."
    }
    elseif ($ErrorMessage -match 'firewall|blocked') {
        return " Check firewall rules on '$ServerName' - WinRM (TCP 5985/5986) and WMI/DCOM must be allowed."
    }
    return ""
}

function Invoke-RemoteVssRetentionPolicy {
    <#
    .SYNOPSIS
        Enforces VSS snapshot retention on a remote server
    .DESCRIPTION
        For a specified volume on a remote server, keeps the newest N snapshots
        and removes the rest. Uses CIM sessions for remote operations.
    .PARAMETER ServerName
        The remote server name
    .PARAMETER Volume
        Volume to apply retention to (e.g., "D:")
    .PARAMETER KeepCount
        Number of snapshots to keep (default: 3)
    .OUTPUTS
        OperationResult with Data containing DeletedCount, KeptCount, Errors
    .EXAMPLE
        $result = Invoke-RemoteVssRetentionPolicy -ServerName "FileServer01" -Volume "D:" -KeepCount 5
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ServerName,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]:$')]
        [string]$Volume,

        [ValidateRange(0, 100)]
        [int]$KeepCount = 3
    )

    Write-RobocurseLog -Message "Applying VSS retention on '$ServerName' for $Volume (keep: $KeepCount)" -Level 'Info' -Component 'VSS'

    # Get current snapshots
    $listResult = Get-RemoteVssSnapshots -ServerName $ServerName -Volume $Volume
    if (-not $listResult.Success) {
        return New-OperationResult -Success $false -ErrorMessage "Failed to list snapshots: $($listResult.ErrorMessage)"
    }

    $snapshots = @($listResult.Data)
    $currentCount = $snapshots.Count

    # Nothing to do if under limit
    if ($currentCount -le $KeepCount) {
        Write-RobocurseLog -Message "Retention OK on '$ServerName': $currentCount snapshot(s) <= $KeepCount limit" -Level 'Debug' -Component 'VSS'
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

    Write-RobocurseLog -Message "Retention on '$ServerName': Deleting $($toDelete.Count) old snapshot(s), keeping $($toKeep.Count)" -Level 'Info' -Component 'VSS'

    $deletedCount = 0
    $errors = @()

    foreach ($snapshot in $toDelete) {
        $shadowId = $snapshot.ShadowId
        $createdAt = $snapshot.CreatedAt

        if ($PSCmdlet.ShouldProcess("$shadowId on $ServerName (created $createdAt)", "Remove Remote VSS Snapshot")) {
            $removeResult = Remove-RemoteVssSnapshot -ShadowId $shadowId -ServerName $ServerName
            if ($removeResult.Success) {
                $deletedCount++
                Write-RobocurseLog -Message "Deleted remote snapshot $shadowId on '$ServerName'" -Level 'Debug' -Component 'VSS'
            }
            else {
                $errors += "Failed to delete $shadowId on '$ServerName': $($removeResult.ErrorMessage)"
                Write-RobocurseLog -Message "Failed to delete remote snapshot: $($removeResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
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
        Write-RobocurseLog -Message "Remote retention applied on '$ServerName': deleted $deletedCount, kept $($toKeep.Count)" -Level 'Info' -Component 'VSS'
    }
    else {
        Write-RobocurseLog -Message "Remote retention on '$ServerName' completed with errors: $($errors.Count)" -Level 'Warning' -Component 'VSS'
    }

    return New-OperationResult -Success $success -Data $resultData -ErrorMessage $(if (-not $success) { $errors -join "; " })
}
```

## Test Plan

### File: `tests\Unit\VssSnapshotRemote.Tests.ps1`

```powershell
BeforeAll {
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Utility.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Logging.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssCore.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssRemote.ps1"

    Mock Write-RobocurseLog {}
}

Describe "Get-RemoteVssSnapshots" {
    Context "When snapshots exist on remote server" {
        BeforeAll {
            Mock New-CimSession { [PSCustomObject]@{ Id = 1; ComputerName = "TestServer" } }
            Mock Remove-CimSession {}
            Mock Get-CimInstance {
                if ($ClassName -eq 'Win32_ShadowCopy') {
                    return @(
                        [PSCustomObject]@{
                            ID = "{remote-snap1}"
                            DeviceObject = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1"
                            VolumeName = "\\?\Volume{test-guid}\"
                            InstallDate = (Get-Date).AddHours(-2)
                        },
                        [PSCustomObject]@{
                            ID = "{remote-snap2}"
                            DeviceObject = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy2"
                            VolumeName = "\\?\Volume{test-guid}\"
                            InstallDate = (Get-Date).AddHours(-1)
                        }
                    )
                }
                elseif ($ClassName -eq 'Win32_Volume') {
                    return @(
                        [PSCustomObject]@{
                            DeviceID = "\\?\Volume{test-guid}\"
                            DriveLetter = "D:"
                        }
                    )
                }
            }
        }

        It "Returns snapshots with IsRemote=true" {
            $result = Get-RemoteVssSnapshots -ServerName "TestServer"
            $result.Success | Should -Be $true
            $result.Data.Count | Should -Be 2
            $result.Data[0].IsRemote | Should -Be $true
            $result.Data[0].ServerName | Should -Be "TestServer"
        }

        It "Filters by volume" {
            $result = Get-RemoteVssSnapshots -ServerName "TestServer" -Volume "D:"
            $result.Success | Should -Be $true
            $result.Data.Count | Should -Be 2
        }

        It "Creates and cleans up CIM session" {
            Get-RemoteVssSnapshots -ServerName "TestServer"
            Should -Invoke New-CimSession -Times 1
            Should -Invoke Remove-CimSession -Times 1
        }
    }

    Context "When connection fails" {
        BeforeAll {
            Mock New-CimSession { throw "RPC server unavailable" }
        }

        It "Returns error with guidance" {
            $result = Get-RemoteVssSnapshots -ServerName "BadServer"
            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Match "WinRM"
        }
    }
}

Describe "Invoke-RemoteVssRetentionPolicy" {
    Context "When over retention limit" {
        BeforeAll {
            Mock Get-RemoteVssSnapshots {
                New-OperationResult -Success $true -Data @(
                    [PSCustomObject]@{ ShadowId = "{rsnap1}"; CreatedAt = (Get-Date).AddHours(-3); ServerName = "TestServer" },
                    [PSCustomObject]@{ ShadowId = "{rsnap2}"; CreatedAt = (Get-Date).AddHours(-2); ServerName = "TestServer" },
                    [PSCustomObject]@{ ShadowId = "{rsnap3}"; CreatedAt = (Get-Date).AddHours(-1); ServerName = "TestServer" }
                )
            }
            Mock Remove-RemoteVssSnapshot { New-OperationResult -Success $true -Data $ShadowId }
        }

        It "Deletes oldest snapshots" {
            $result = Invoke-RemoteVssRetentionPolicy -ServerName "TestServer" -Volume "D:" -KeepCount 1
            $result.Success | Should -Be $true
            $result.Data.DeletedCount | Should -Be 2
        }

        It "Passes ServerName to Remove-RemoteVssSnapshot" {
            Invoke-RemoteVssRetentionPolicy -ServerName "TestServer" -Volume "D:" -KeepCount 1
            Should -Invoke Remove-RemoteVssSnapshot -ParameterFilter { $ServerName -eq "TestServer" }
        }
    }

    Context "When under retention limit" {
        BeforeAll {
            Mock Get-RemoteVssSnapshots {
                New-OperationResult -Success $true -Data @(
                    [PSCustomObject]@{ ShadowId = "{rsnap1}"; CreatedAt = (Get-Date) }
                )
            }
        }

        It "Does not delete any snapshots" {
            $result = Invoke-RemoteVssRetentionPolicy -ServerName "TestServer" -Volume "D:" -KeepCount 5
            $result.Success | Should -Be $true
            $result.Data.DeletedCount | Should -Be 0
        }
    }
}

Describe "Get-RemoteVssErrorGuidance" {
    It "Returns WinRM guidance for RPC errors" {
        $guidance = Get-RemoteVssErrorGuidance -ErrorMessage "RPC server unavailable" -ServerName "Server1"
        $guidance | Should -Match "WinRM"
    }

    It "Returns admin guidance for access denied" {
        $guidance = Get-RemoteVssErrorGuidance -ErrorMessage "Access denied" -ServerName "Server1"
        $guidance | Should -Match "administrative"
    }

    It "Returns network guidance for path not found" {
        $guidance = Get-RemoteVssErrorGuidance -ErrorMessage "network path not found" -ServerName "Server1"
        $guidance | Should -Match "connectivity"
    }

    It "Returns empty for unknown errors" {
        $guidance = Get-RemoteVssErrorGuidance -ErrorMessage "Unknown error xyz" -ServerName "Server1"
        $guidance | Should -BeNullOrEmpty
    }
}
```

## Files to Modify
- `src\Robocurse\Public\VssRemote.ps1` - Add new functions at end of file

## Files to Create
- `tests\Unit\VssSnapshotRemote.Tests.ps1` - Unit tests

## Verification
```powershell
# Run unit tests
Invoke-Pester -Path tests\Unit\VssSnapshotRemote.Tests.ps1 -Output Detailed

# Manual verification (requires admin on remote server, set env var first)
# $env:ROBOCURSE_TEST_REMOTE_SHARE = "\\FileServer01\Data"
$result = Get-RemoteVssSnapshots -ServerName "FileServer01" -Volume "D:"
$result.Data | Format-Table

# Test retention (dry run)
Invoke-RemoteVssRetentionPolicy -ServerName "FileServer01" -Volume "D:" -KeepCount 3 -WhatIf
```

## Dependencies
- Task 01 (VssSnapshotCore) must be completed first (for pattern consistency)

## Notes
- Uses same patterns as existing `New-RemoteVssSnapshot` and `Remove-RemoteVssSnapshot`
- Error guidance extracted to helper function for consistency
- CIM session cleanup in finally block ensures no leaks
- Volume mapping done per-call to handle dynamic drive assignments
