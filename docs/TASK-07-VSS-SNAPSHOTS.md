# Task 07: VSS Shadow Copy Support

## Overview
Implement Volume Shadow Copy (VSS) snapshot creation to capture locked files during replication. This allows copying files that are open by users (like Outlook PST files).

## Research Required

### Web Research
- Win32_ShadowCopy WMI class
- vssadmin command-line tool
- Accessing shadow copies via `\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy`
- VSS limitations (64 shadows per volume)
- PowerShell WMI/CIM cmdlets

### Key Concepts
- **Shadow Copy**: Point-in-time snapshot of a volume
- **VSS Provider**: System component that creates snapshots
- **Shadow Path**: `\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\`
- **Client Accessible**: Shadow that can be read by applications

## Task Description

### Function: New-VssSnapshot
```powershell
function New-VssSnapshot {
    <#
    .SYNOPSIS
        Creates a VSS shadow copy of a volume
    .PARAMETER SourcePath
        Path on the volume to snapshot (used to determine volume)
    .OUTPUTS
        PSCustomObject with ShadowId, ShadowPath, SourceVolume
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath
    )

    # Determine volume from path
    # For UNC: \\server\share -> must run on server, or use remote WMI
    # For local: C:\folder -> volume is C:

    # Create shadow copy via WMI
    $shadowClass = [wmiclass]"root\cimv2:Win32_ShadowCopy"
    $result = $shadowClass.Create("C:\", "ClientAccessible")

    if ($result.ReturnValue -ne 0) {
        throw "Failed to create shadow copy: Error $($result.ReturnValue)"
    }

    # Get shadow copy details
    $shadowId = $result.ShadowID
    $shadow = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowId }

    return [PSCustomObject]@{
        ShadowId = $shadowId
        ShadowPath = $shadow.DeviceObject  # \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyN
        SourceVolume = "C:"  # Extracted from path
        CreatedAt = [datetime]::Now
    }
}
```

### Function: Remove-VssSnapshot
```powershell
function Remove-VssSnapshot {
    <#
    .SYNOPSIS
        Deletes a VSS shadow copy
    .PARAMETER ShadowId
        ID of shadow copy to delete
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ShadowId
    )

    $shadow = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $ShadowId }
    if ($shadow) {
        $shadow.Delete()
        Write-RobocurseLog -Message "Deleted VSS snapshot: $ShadowId" -Level 'Info' -Component 'VSS'
    }
}
```

### Function: Get-VssPath
```powershell
function Get-VssPath {
    <#
    .SYNOPSIS
        Converts a regular path to its VSS shadow copy equivalent
    .PARAMETER OriginalPath
        Original path (e.g., C:\Users\John\Documents)
    .PARAMETER ShadowPath
        VSS shadow path (e.g., \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1)
    .PARAMETER SourceVolume
        Source volume (e.g., C:)
    .OUTPUTS
        Converted path pointing to shadow copy
    #>
    param(
        [Parameter(Mandatory)]
        [string]$OriginalPath,

        [Parameter(Mandatory)]
        [string]$ShadowPath,

        [Parameter(Mandatory)]
        [string]$SourceVolume
    )

    # C:\Users\John\Documents
    # -> \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Users\John\Documents

    $relativePath = $OriginalPath.Substring($SourceVolume.Length)
    return Join-Path $ShadowPath $relativePath.TrimStart('\')
}
```

### Function: Get-VolumeFromPath
```powershell
function Get-VolumeFromPath {
    <#
    .SYNOPSIS
        Extracts volume from a path
    .PARAMETER Path
        Local path (C:\...) or UNC path (\\server\share\...)
    .OUTPUTS
        Volume string (C:, D:, etc.) or $null for UNC
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Path -match '^([A-Z]:)') {
        return $Matches[1]
    }
    elseif ($Path -match '^\\\\') {
        # UNC path - VSS must be created on the server
        return $null
    }

    return $null
}
```

### Function: Test-VssSupported
```powershell
function Test-VssSupported {
    <#
    .SYNOPSIS
        Tests if VSS is supported for a given path
    .PARAMETER Path
        Path to test
    .OUTPUTS
        $true if VSS can be used, $false otherwise
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Check if local path
    $volume = Get-VolumeFromPath -Path $Path
    if (-not $volume) {
        # UNC path - would need remote WMI (complex)
        return $false
    }

    # Check if volume supports VSS
    try {
        $shadowClass = Get-WmiObject -List Win32_ShadowCopy -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}
```

### Function: Invoke-WithVssSnapshot
```powershell
function Invoke-WithVssSnapshot {
    <#
    .SYNOPSIS
        Executes a scriptblock with VSS snapshot, cleaning up afterward
    .PARAMETER SourcePath
        Path to snapshot
    .PARAMETER ScriptBlock
        Code to execute (receives $VssPath parameter)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $snapshot = $null
    try {
        Write-RobocurseLog -Message "Creating VSS snapshot for $SourcePath" -Level 'Info' -Component 'VSS'
        $snapshot = New-VssSnapshot -SourcePath $SourcePath

        $vssPath = Get-VssPath -OriginalPath $SourcePath `
            -ShadowPath $snapshot.ShadowPath `
            -SourceVolume $snapshot.SourceVolume

        Write-RobocurseLog -Message "VSS path: $vssPath" -Level 'Debug' -Component 'VSS'

        # Execute the scriptblock
        & $ScriptBlock -VssPath $vssPath
    }
    finally {
        if ($snapshot) {
            Write-RobocurseLog -Message "Cleaning up VSS snapshot" -Level 'Info' -Component 'VSS'
            Remove-VssSnapshot -ShadowId $snapshot.ShadowId
        }
    }
}
```

### UNC Path Considerations

For UNC paths (network shares), VSS must be created on the **file server**, not the client. Options:

1. **Remote WMI**: Connect to server's WMI to create snapshot (requires admin rights on server)
2. **Pre-existing snapshots**: Use snapshots created by backup software
3. **Server-side script**: Run a helper script on the server

```powershell
# Remote WMI example (if we implement it)
function New-RemoteVssSnapshot {
    param(
        [string]$Server,
        [string]$Volume
    )

    $shadowClass = [wmiclass]"\\$Server\root\cimv2:Win32_ShadowCopy"
    $result = $shadowClass.Create($Volume, "ClientAccessible")
    # ...
}
```

**For v1.0**: Support local VSS only. UNC sources with VSS require running on the file server.

## Success Criteria

1. [ ] `New-VssSnapshot` creates snapshot on local volume
2. [ ] `Remove-VssSnapshot` deletes snapshot
3. [ ] `Get-VssPath` correctly translates paths
4. [ ] `Test-VssSupported` identifies supported scenarios
5. [ ] `Invoke-WithVssSnapshot` handles cleanup on error
6. [ ] VSS snapshot allows copying locked files
7. [ ] Graceful handling when VSS unavailable

## Pester Tests Required

Create `tests/Unit/VssSnapshots.Tests.ps1`:

```powershell
Describe "VSS Snapshots" {
    BeforeAll {
        . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
    }

    Context "Get-VolumeFromPath" {
        It "Should extract volume from local path" {
            Get-VolumeFromPath -Path "C:\Users\John" | Should -Be "C:"
            Get-VolumeFromPath -Path "D:\Data\Files" | Should -Be "D:"
        }

        It "Should return null for UNC paths" {
            Get-VolumeFromPath -Path "\\server\share\folder" | Should -Be $null
        }
    }

    Context "Get-VssPath" {
        It "Should convert local path to VSS path" {
            $result = Get-VssPath `
                -OriginalPath "C:\Users\John\Documents" `
                -ShadowPath "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1" `
                -SourceVolume "C:"

            $result | Should -Be "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Users\John\Documents"
        }

        It "Should handle paths with trailing slashes" {
            $result = Get-VssPath `
                -OriginalPath "C:\Users\John\" `
                -ShadowPath "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1" `
                -SourceVolume "C:"

            $result | Should -Match "HarddiskVolumeShadowCopy1\\Users\\John"
        }
    }

    Context "Test-VssSupported" {
        It "Should return false for UNC paths" {
            Test-VssSupported -Path "\\server\share" | Should -Be $false
        }

        # Note: Testing actual VSS creation requires admin rights and real volumes
        # These would be integration tests
    }

    Context "Invoke-WithVssSnapshot - Mocked" {
        It "Should execute scriptblock and cleanup" {
            $executed = $false
            $cleanedUp = $false

            Mock New-VssSnapshot {
                [PSCustomObject]@{
                    ShadowId = "test-id"
                    ShadowPath = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1"
                    SourceVolume = "C:"
                }
            }
            Mock Remove-VssSnapshot { $script:cleanedUp = $true }

            Invoke-WithVssSnapshot -SourcePath "C:\Test" -ScriptBlock {
                param($VssPath)
                $script:executed = $true
                $VssPath | Should -Not -BeNullOrEmpty
            }

            $executed | Should -Be $true
            Should -Invoke Remove-VssSnapshot -Times 1
        }

        It "Should cleanup even on error" {
            Mock New-VssSnapshot {
                [PSCustomObject]@{
                    ShadowId = "test-id"
                    ShadowPath = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1"
                    SourceVolume = "C:"
                }
            }
            Mock Remove-VssSnapshot { }

            { Invoke-WithVssSnapshot -SourcePath "C:\Test" -ScriptBlock { throw "Test error" } } |
                Should -Throw "Test error"

            Should -Invoke Remove-VssSnapshot -Times 1
        }
    }
}
```

## Integration Test (Requires Admin)

```powershell
# Run as Administrator
Describe "VSS Integration" -Tag "Integration" {
    It "Should create and delete shadow copy" {
        $snapshot = New-VssSnapshot -SourcePath "C:\Windows"

        $snapshot.ShadowId | Should -Not -BeNullOrEmpty
        $snapshot.ShadowPath | Should -Match "HarddiskVolumeShadowCopy"

        # Verify we can access the shadow
        Test-Path $snapshot.ShadowPath | Should -Be $true

        # Cleanup
        Remove-VssSnapshot -ShadowId $snapshot.ShadowId

        # Verify it's gone
        Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $snapshot.ShadowId } |
            Should -Be $null
    }
}
```

## Error Handling

| Error | Cause | Handling |
|-------|-------|----------|
| 0x8004230F | Insufficient storage | Log warning, proceed without VSS |
| 0x80042316 | VSS service not running | Start service or skip VSS |
| 0x80042302 | Volume not supported | Skip VSS for this profile |
| Access denied | Not running as admin | Log error, require admin |

## Dependencies
- Task 00 (Project Structure)
- Task 02 (Logging)

## Estimated Complexity
- Medium
- WMI interaction, path manipulation
- Requires admin rights for testing
