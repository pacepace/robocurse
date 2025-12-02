#Requires -Modules Pester

# VssSnapshots.Tests.ps1
# Unit tests for VSS (Volume Shadow Copy) snapshot functions

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

InModuleScope 'Robocurse' {
    Describe "VSS Snapshots - Platform Independent Tests" {

        Context "New-VssSnapshot Validation" {
            It "Should throw when SourcePath is null or empty" {
                {
                    New-VssSnapshot -SourcePath ""
                } | Should -Throw
            }

            It "Should throw when SourcePath is a UNC path" {
                {
                    New-VssSnapshot -SourcePath "\\server\share\folder"
                } | Should -Throw "*UNC path*"
            }

            It "Should throw when SourcePath does not have a drive letter" {
                {
                    New-VssSnapshot -SourcePath "\Relative\Path"
                } | Should -Throw "*local path*"
            }
        }

        Context "Get-VolumeFromPath" {
            It "Should extract volume from local path with drive C" {
                $result = Get-VolumeFromPath -Path "C:\Users\John"
                $result | Should -Be "C:"
            }

            It "Should extract volume from local path with drive D" {
                $result = Get-VolumeFromPath -Path "D:\Data\Files"
                $result | Should -Be "D:"
            }

            It "Should extract volume from path with lowercase drive letter" {
                $result = Get-VolumeFromPath -Path "c:\temp"
                $result | Should -Be "C:"
            }

            It "Should extract volume from path with multiple subdirectories" {
                $result = Get-VolumeFromPath -Path "E:\Projects\Robocurse\Source\Code"
                $result | Should -Be "E:"
            }

            It "Should return null for UNC path with server and share" {
                $result = Get-VolumeFromPath -Path "\\server\share\folder"
                $result | Should -Be $null
            }

            It "Should return null for UNC path with IP address" {
                $result = Get-VolumeFromPath -Path "\\192.168.1.100\share"
                $result | Should -Be $null
            }

            It "Should return null for invalid path format" {
                $result = Get-VolumeFromPath -Path "NotAValidPath"
                $result | Should -Be $null
            }

            It "Should handle path with trailing backslash" {
                $result = Get-VolumeFromPath -Path "C:\Users\"
                $result | Should -Be "C:"
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

            It "Should handle path with trailing backslash" {
                $result = Get-VssPath `
                    -OriginalPath "C:\Users\John\" `
                    -ShadowPath "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1" `
                    -SourceVolume "C:"

                $result | Should -Match "HarddiskVolumeShadowCopy1\\Users\\John"
            }

            It "Should handle different drive letters" {
                $result = Get-VssPath `
                    -OriginalPath "D:\Data\Files\Archive" `
                    -ShadowPath "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy2" `
                    -SourceVolume "D:"

                $result | Should -Be "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy2\Data\Files\Archive"
            }

            It "Should handle root directory of volume" {
                $result = Get-VssPath `
                    -OriginalPath "C:\" `
                    -ShadowPath "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1" `
                    -SourceVolume "C:"

                # Should result in shadow path with minimal extra content
                $result | Should -Be "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1"
            }

            It "Should handle deep nested paths" {
                $result = Get-VssPath `
                    -OriginalPath "C:\Program Files\Microsoft\Windows\System32\Drivers" `
                    -ShadowPath "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy5" `
                    -SourceVolume "C:"

                $result | Should -Be "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy5\Program Files\Microsoft\Windows\System32\Drivers"
            }

            It "Should handle SourceVolume without backslash" {
                $result = Get-VssPath `
                    -OriginalPath "C:\Windows\System32" `
                    -ShadowPath "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1" `
                    -SourceVolume "C"

                $result | Should -Match "HarddiskVolumeShadowCopy1\\Windows\\System32"
            }

            It "Should accept VssSnapshot object parameter" {
                $snapshot = [PSCustomObject]@{
                    ShadowId     = "{TEST-1234-5678-90AB-CDEF12345678}"
                    ShadowPath   = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy99"
                    SourceVolume = "E:"
                    CreatedAt    = [datetime]::Now
                }

                $result = Get-VssPath -OriginalPath "E:\Data\MyFiles" -VssSnapshot $snapshot

                $result | Should -Be "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy99\Data\MyFiles"
            }

            It "Should produce same result with VssSnapshot object vs individual parameters" {
                $snapshot = [PSCustomObject]@{
                    ShadowId     = "{TEST-SAME-5678-90AB-CDEF12345678}"
                    ShadowPath   = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy50"
                    SourceVolume = "D:"
                    CreatedAt    = [datetime]::Now
                }

                $resultWithObject = Get-VssPath -OriginalPath "D:\Projects\Code" -VssSnapshot $snapshot
                $resultWithParams = Get-VssPath -OriginalPath "D:\Projects\Code" `
                    -ShadowPath $snapshot.ShadowPath `
                    -SourceVolume $snapshot.SourceVolume

                $resultWithObject | Should -Be $resultWithParams
            }
        }

        Context "Test-VssSupported" {
            It "Should return false for UNC path" {
                $result = Test-VssSupported -Path "\\server\share"
                $result | Should -Be $false
            }

            It "Should return false for UNC path with subdirectories" {
                $result = Test-VssSupported -Path "\\server\share\folder\subfolder"
                $result | Should -Be $false
            }

            # Note: Testing actual VSS support requires WMI on Windows and admin rights
            # On non-Windows platforms (like macOS), WMI won't be available
            # These tests verify the function returns false gracefully on unsupported platforms

            It "Should handle non-Windows platforms gracefully" {
                # On macOS/Linux, Get-WmiObject will fail, function should return false
                if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
                    $result = Test-VssSupported -Path "C:\TestPath"
                    $result | Should -Be $false
                }
            }
        }

        Context "Invoke-WithVssSnapshot - Mocked Tests" {
            BeforeEach {
                # Reset mock tracking variables
                $script:executed = $false
                $script:cleanedUp = $false
                $script:receivedVssPath = $null
            }

            It "Should execute scriptblock with VSS path parameter" {
                Mock New-VssSnapshot {
                    return New-OperationResult -Success $true -Data ([PSCustomObject]@{
                        ShadowId     = "{12345678-1234-1234-1234-123456789012}"
                        ShadowPath   = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1"
                        SourceVolume = "C:"
                        CreatedAt    = [datetime]::Now
                    })
                }
                Mock Remove-VssSnapshot { New-OperationResult -Success $true -Data $ShadowId }

                $result = Invoke-WithVssSnapshot -SourcePath "C:\Test" -ScriptBlock {
                    param($VssPath)
                    $script:executed = $true
                    $script:receivedVssPath = $VssPath
                    $VssPath | Should -Not -BeNullOrEmpty
                }

                $result.Success | Should -Be $true
                $script:executed | Should -Be $true
                $script:receivedVssPath | Should -Match "HarddiskVolumeShadowCopy1"
                Should -Invoke Remove-VssSnapshot -Times 1
            }

            It "Should cleanup VSS snapshot after successful execution" {
                Mock New-VssSnapshot {
                    return New-OperationResult -Success $true -Data ([PSCustomObject]@{
                        ShadowId     = "{ABCD1234-5678-90AB-CDEF-123456789012}"
                        ShadowPath   = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy2"
                        SourceVolume = "D:"
                        CreatedAt    = [datetime]::Now
                    })
                }
                Mock Remove-VssSnapshot { $script:cleanedUp = $true; New-OperationResult -Success $true -Data $ShadowId }

                $result = Invoke-WithVssSnapshot -SourcePath "D:\Data" -ScriptBlock {
                    param($VssPath)
                    # Successful operation
                    $script:executed = $true
                }

                $result.Success | Should -Be $true
                $script:executed | Should -Be $true
                Should -Invoke Remove-VssSnapshot -Times 1 -ParameterFilter {
                    $ShadowId -eq "{ABCD1234-5678-90AB-CDEF-123456789012}"
                }
            }

            It "Should cleanup VSS snapshot even on error in scriptblock" {
                Mock New-VssSnapshot {
                    return New-OperationResult -Success $true -Data ([PSCustomObject]@{
                        ShadowId     = "{ERROR123-1234-1234-1234-123456789012}"
                        ShadowPath   = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy3"
                        SourceVolume = "C:"
                        CreatedAt    = [datetime]::Now
                    })
                }
                Mock Remove-VssSnapshot { New-OperationResult -Success $true -Data $ShadowId }

                $result = Invoke-WithVssSnapshot -SourcePath "C:\Test" -ScriptBlock {
                    throw "Simulated error during processing"
                }

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "Simulated error during processing"
                Should -Invoke Remove-VssSnapshot -Times 1
            }

            It "Should not attempt cleanup if snapshot creation fails" {
                Mock New-VssSnapshot {
                    return New-OperationResult -Success $false -ErrorMessage "Failed to create VSS snapshot"
                }
                Mock Remove-VssSnapshot { New-OperationResult -Success $true -Data $ShadowId }

                $result = Invoke-WithVssSnapshot -SourcePath "C:\Test" -ScriptBlock {
                    param($VssPath)
                    # This should never execute
                    $script:executed = $true
                }

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "Failed to create VSS snapshot"
                $script:executed | Should -Be $false
                Should -Invoke Remove-VssSnapshot -Times 0
            }

            It "Should pass correct VSS path to scriptblock" {
                Mock New-VssSnapshot {
                    return New-OperationResult -Success $true -Data ([PSCustomObject]@{
                        ShadowId     = "{PATH-TEST-1234-1234-123456789012}"
                        ShadowPath   = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy10"
                        SourceVolume = "E:"
                        CreatedAt    = [datetime]::Now
                    })
                }
                Mock Remove-VssSnapshot { New-OperationResult -Success $true -Data $ShadowId }

                $script:capturedPath = $null
                $result = Invoke-WithVssSnapshot -SourcePath "E:\Projects\MyApp" -ScriptBlock {
                    param($VssPath)
                    $script:capturedPath = $VssPath
                }

                $result.Success | Should -Be $true
                $script:capturedPath | Should -Be "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy10\Projects\MyApp"
                Should -Invoke Remove-VssSnapshot -Times 1
            }

            It "Should handle cleanup failure gracefully" {
                Mock New-VssSnapshot {
                    return New-OperationResult -Success $true -Data ([PSCustomObject]@{
                        ShadowId     = "{CLEANUP-FAIL-1234-1234-123456789012}"
                        ShadowPath   = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy7"
                        SourceVolume = "C:"
                        CreatedAt    = [datetime]::Now
                    })
                }
                Mock Remove-VssSnapshot {
                    return New-OperationResult -Success $false -ErrorMessage "Failed to delete snapshot"
                }

                # Should still return success since the scriptblock succeeded
                $result = Invoke-WithVssSnapshot -SourcePath "C:\Test" -ScriptBlock {
                    param($VssPath)
                    $script:executed = $true
                }

                $result.Success | Should -Be $true
                $script:executed | Should -Be $true
                Should -Invoke Remove-VssSnapshot -Times 1
            }
        }

        Context "New-VssSnapshot - Function Structure" {
            It "Should be defined and have correct parameters" {
                # Note: Actual New-VssSnapshot testing requires Windows with WMI
                # This test verifies the function signature and basic structure
                Get-Command New-VssSnapshot | Should -Not -BeNullOrEmpty

                $params = (Get-Command New-VssSnapshot).Parameters
                $params.Keys | Should -Contain 'SourcePath'
            }

            It "Should accept SourcePath parameter" {
                $cmd = Get-Command New-VssSnapshot
                $cmd.Parameters['SourcePath'].ParameterType.Name | Should -Be 'String'
                $cmd.Parameters['SourcePath'].Attributes.Mandatory | Should -Contain $true
            }

            It "Should have RetryCount parameter with valid range" {
                $cmd = Get-Command New-VssSnapshot
                $cmd.Parameters.Keys | Should -Contain 'RetryCount'
                $cmd.Parameters['RetryCount'].ParameterType.Name | Should -Be 'Int32'
            }

            It "Should have RetryDelaySeconds parameter with valid range" {
                $cmd = Get-Command New-VssSnapshot
                $cmd.Parameters.Keys | Should -Contain 'RetryDelaySeconds'
                $cmd.Parameters['RetryDelaySeconds'].ParameterType.Name | Should -Be 'Int32'
            }
        }

        Context "Test-VssPrivileges - Function Structure" {
            It "Should be defined" {
                Get-Command Test-VssPrivileges | Should -Not -BeNullOrEmpty
            }

            It "Should return OperationResult object" {
                $result = Test-VssPrivileges
                $result.PSObject.Properties.Name | Should -Contain 'Success'
                $result.PSObject.Properties.Name | Should -Contain 'ErrorMessage'
            }

            It "Should return false on non-Windows platforms" {
                if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
                    $result = Test-VssPrivileges
                    $result.Success | Should -Be $false
                    $result.ErrorMessage | Should -Match "Windows"
                }
            }
        }

        Context "Remove-VssSnapshot - Function Structure" {
            It "Should have ShadowId parameter" {
                $cmd = Get-Command Remove-VssSnapshot
                $cmd.Parameters['ShadowId'].ParameterType.Name | Should -Be 'String'
                $cmd.Parameters['ShadowId'].Attributes.Mandatory | Should -Contain $true
            }

            It "Should be defined and callable" {
                Get-Command Remove-VssSnapshot | Should -Not -BeNullOrEmpty
            }
        }
    }

    Describe "VSS Path Manipulation Edge Cases" {
        Context "Get-VssPath - Edge Cases" {
            It "Should handle path with spaces" {
                $result = Get-VssPath `
                    -OriginalPath "C:\Program Files\My Application\Data Files" `
                    -ShadowPath "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1" `
                    -SourceVolume "C:"

                $result | Should -Be "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Program Files\My Application\Data Files"
            }

            It "Should handle path with special characters" {
                $result = Get-VssPath `
                    -OriginalPath "C:\Users\John (Admin)\Documents & Settings" `
                    -ShadowPath "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1" `
                    -SourceVolume "C:"

                $result | Should -Match "HarddiskVolumeShadowCopy1\\Users\\John"
            }

            It "Should handle very long paths" {
                $longPath = "C:\" + ("SubFolder\" * 30) + "File.txt"
                $result = Get-VssPath `
                    -OriginalPath $longPath `
                    -ShadowPath "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1" `
                    -SourceVolume "C:"

                $result | Should -Match "HarddiskVolumeShadowCopy1"
                $result | Should -Match "SubFolder"
            }
        }

        Context "Get-VolumeFromPath - Edge Cases" {
            It "Should handle mixed case in drive letter" {
                $result = Get-VolumeFromPath -Path "d:\MixedCase\Path"
                $result | Should -Be "D:"
            }

            It "Should handle path starting with just drive letter and colon" {
                $result = Get-VolumeFromPath -Path "Z:"
                $result | Should -Be "Z:"
            }

            It "Should return null for relative paths" {
                $result = Get-VolumeFromPath -Path "RelativePath\File.txt"
                $result | Should -Be $null
            }

            It "Should return null for network UNC with FQDN" {
                $result = Get-VolumeFromPath -Path "\\server.domain.com\share\folder"
                $result | Should -Be $null
            }
        }
    }

    Describe "VSS Snapshot Tracking" {
        BeforeAll {
            # Save original tracking file path
            $script:OriginalTrackingFile = $script:VssTrackingFile
        }

        BeforeEach {
            # Use test drive for tracking file
            $script:VssTrackingFile = "$TestDrive\vss_tracking.json"

            # Clean up any existing tracking file
            if (Test-Path $script:VssTrackingFile) {
                Remove-Item $script:VssTrackingFile -Force
            }
        }

        AfterAll {
            # Restore original tracking file path
            $script:VssTrackingFile = $script:OriginalTrackingFile
        }

        Context "Add-VssToTracking" {
            It "Should create tracking file if it does not exist" {
                $snapshot = [PSCustomObject]@{
                    ShadowId = "{TEST-1234-5678-90AB-CDEF12345678}"
                    SourceVolume = "C:"
                    CreatedAt = [datetime]::Now
                }

                Add-VssToTracking -SnapshotInfo $snapshot

                Test-Path $script:VssTrackingFile | Should -Be $true
            }

            It "Should add snapshot info to tracking file" {
                $snapshot = [PSCustomObject]@{
                    ShadowId = "{SNAP-1111-2222-3333-444455556666}"
                    SourceVolume = "D:"
                    CreatedAt = [datetime]"2024-01-15T10:30:00"
                }

                Add-VssToTracking -SnapshotInfo $snapshot

                $content = Get-Content $script:VssTrackingFile -Raw | ConvertFrom-Json
                $content.ShadowId | Should -Contain "{SNAP-1111-2222-3333-444455556666}"
            }

            It "Should append to existing tracking file" {
                $snapshot1 = [PSCustomObject]@{
                    ShadowId = "{FIRST-1234-5678-90AB-CDEF12345678}"
                    SourceVolume = "C:"
                    CreatedAt = [datetime]::Now
                }
                $snapshot2 = [PSCustomObject]@{
                    ShadowId = "{SECOND-ABCD-EFGH-IJKL-MNOPQRSTUVWX}"
                    SourceVolume = "D:"
                    CreatedAt = [datetime]::Now
                }

                Add-VssToTracking -SnapshotInfo $snapshot1
                Add-VssToTracking -SnapshotInfo $snapshot2

                $content = Get-Content $script:VssTrackingFile -Raw | ConvertFrom-Json
                $content.Count | Should -Be 2
            }

            It "Should store CreatedAt in ISO 8601 format" {
                $testDate = [datetime]"2024-06-15T14:30:45.123"
                $snapshot = [PSCustomObject]@{
                    ShadowId = "{DATE-TEST-5678-90AB-CDEF12345678}"
                    SourceVolume = "E:"
                    CreatedAt = $testDate
                }

                Add-VssToTracking -SnapshotInfo $snapshot

                $rawContent = Get-Content $script:VssTrackingFile -Raw
                $rawContent | Should -Match "2024-06-15T14:30:45"
            }

            It "Should have correct function signature" {
                $cmd = Get-Command Add-VssToTracking

                $cmd.Parameters.ContainsKey('SnapshotInfo') | Should -Be $true
                $cmd.Parameters['SnapshotInfo'].ParameterType.Name | Should -Be 'PSObject'
                $cmd.Parameters['SnapshotInfo'].Attributes.Mandatory | Should -Contain $true
            }
        }

        Context "Remove-VssFromTracking" {
            It "Should remove snapshot from tracking file" {
                # First add a snapshot
                $snapshot = [PSCustomObject]@{
                    ShadowId = "{REMOVE-TEST-5678-90AB-CDEF12345678}"
                    SourceVolume = "C:"
                    CreatedAt = [datetime]::Now
                }
                Add-VssToTracking -SnapshotInfo $snapshot

                # Verify it was added
                $before = Get-Content $script:VssTrackingFile -Raw | ConvertFrom-Json
                $before.ShadowId | Should -Contain "{REMOVE-TEST-5678-90AB-CDEF12345678}"

                # Remove it
                Remove-VssFromTracking -ShadowId "{REMOVE-TEST-5678-90AB-CDEF12345678}"

                # Verify it was removed
                if (Test-Path $script:VssTrackingFile) {
                    $after = Get-Content $script:VssTrackingFile -Raw
                    if ($after) {
                        $afterParsed = $after | ConvertFrom-Json
                        $afterParsed.ShadowId | Should -Not -Contain "{REMOVE-TEST-5678-90AB-CDEF12345678}"
                    }
                }
            }

            It "Should not throw when tracking file does not exist" {
                { Remove-VssFromTracking -ShadowId "{NONEXISTENT-1234-5678-90AB}" } | Should -Not -Throw
            }

            It "Should preserve other snapshots when removing one" {
                # Add two snapshots
                $snapshot1 = [PSCustomObject]@{
                    ShadowId = "{KEEP-ME-1234-5678-90AB-CDEF12345678}"
                    SourceVolume = "C:"
                    CreatedAt = [datetime]::Now
                }
                $snapshot2 = [PSCustomObject]@{
                    ShadowId = "{DELETE-ME-ABCD-EFGH-IJKL-MNOP}"
                    SourceVolume = "D:"
                    CreatedAt = [datetime]::Now
                }
                Add-VssToTracking -SnapshotInfo $snapshot1
                Add-VssToTracking -SnapshotInfo $snapshot2

                # Remove only the second one
                Remove-VssFromTracking -ShadowId "{DELETE-ME-ABCD-EFGH-IJKL-MNOP}"

                # First should still exist
                $content = Get-Content $script:VssTrackingFile -Raw | ConvertFrom-Json
                # Handle both array and single object cases
                $shadowIds = @($content) | ForEach-Object { $_.ShadowId }
                $shadowIds | Should -Contain "{KEEP-ME-1234-5678-90AB-CDEF12345678}"
            }

            It "Should have correct function signature" {
                $cmd = Get-Command Remove-VssFromTracking

                $cmd.Parameters.ContainsKey('ShadowId') | Should -Be $true
                $cmd.Parameters['ShadowId'].ParameterType.Name | Should -Be 'String'
                $cmd.Parameters['ShadowId'].Attributes.Mandatory | Should -Contain $true
            }
        }

        Context "Clear-OrphanVssSnapshots" {
            It "Should return 0 when tracking file does not exist" {
                # Ensure no tracking file
                if (Test-Path $script:VssTrackingFile) {
                    Remove-Item $script:VssTrackingFile -Force
                }

                $result = Clear-OrphanVssSnapshots
                $result | Should -Be 0
            }

            It "Should have correct function signature" {
                $cmd = Get-Command Clear-OrphanVssSnapshots
                $cmd | Should -Not -BeNullOrEmpty
            }

            It "Should return 0 on non-Windows platforms" {
                # On macOS/Linux, should return 0 gracefully
                if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
                    # Create a tracking file with some content
                    @(
                        @{ ShadowId = "{ORPHAN-1234-5678}"; SourceVolume = "C:"; CreatedAt = "2024-01-01T00:00:00Z" }
                    ) | ConvertTo-Json | Set-Content $script:VssTrackingFile

                    $result = Clear-OrphanVssSnapshots
                    $result | Should -Be 0
                }
            }

            It "Should handle empty tracking file gracefully" {
                "" | Set-Content $script:VssTrackingFile

                { Clear-OrphanVssSnapshots } | Should -Not -Throw
            }

            It "Should handle malformed JSON in tracking file" {
                "{ invalid json" | Set-Content $script:VssTrackingFile

                { Clear-OrphanVssSnapshots } | Should -Not -Throw
            }
        }
    }
}
