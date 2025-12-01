# VssSnapshots.Tests.ps1
# Unit tests for VSS (Volume Shadow Copy) snapshot functions

BeforeAll {
    # Source the main script to load functions
    . "$PSScriptRoot/../../Robocurse.ps1" -Help
}

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
                return [PSCustomObject]@{
                    ShadowId     = "{12345678-1234-1234-1234-123456789012}"
                    ShadowPath   = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1"
                    SourceVolume = "C:"
                    CreatedAt    = [datetime]::Now
                }
            }
            Mock Remove-VssSnapshot { }

            Invoke-WithVssSnapshot -SourcePath "C:\Test" -ScriptBlock {
                param($VssPath)
                $script:executed = $true
                $script:receivedVssPath = $VssPath
                $VssPath | Should -Not -BeNullOrEmpty
            }

            $script:executed | Should -Be $true
            $script:receivedVssPath | Should -Match "HarddiskVolumeShadowCopy1"
            Should -Invoke Remove-VssSnapshot -Times 1
        }

        It "Should cleanup VSS snapshot after successful execution" {
            Mock New-VssSnapshot {
                return [PSCustomObject]@{
                    ShadowId     = "{ABCD1234-5678-90AB-CDEF-123456789012}"
                    ShadowPath   = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy2"
                    SourceVolume = "D:"
                    CreatedAt    = [datetime]::Now
                }
            }
            Mock Remove-VssSnapshot { $script:cleanedUp = $true }

            Invoke-WithVssSnapshot -SourcePath "D:\Data" -ScriptBlock {
                param($VssPath)
                # Successful operation
                $script:executed = $true
            }

            $script:executed | Should -Be $true
            Should -Invoke Remove-VssSnapshot -Times 1 -ParameterFilter {
                $ShadowId -eq "{ABCD1234-5678-90AB-CDEF-123456789012}"
            }
        }

        It "Should cleanup VSS snapshot even on error" {
            Mock New-VssSnapshot {
                return [PSCustomObject]@{
                    ShadowId     = "{ERROR123-1234-1234-1234-123456789012}"
                    ShadowPath   = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy3"
                    SourceVolume = "C:"
                    CreatedAt    = [datetime]::Now
                }
            }
            Mock Remove-VssSnapshot { }

            {
                Invoke-WithVssSnapshot -SourcePath "C:\Test" -ScriptBlock {
                    throw "Simulated error during processing"
                }
            } | Should -Throw "*Simulated error during processing*"

            Should -Invoke Remove-VssSnapshot -Times 1
        }

        It "Should not attempt cleanup if snapshot creation fails" {
            Mock New-VssSnapshot {
                throw "Failed to create VSS snapshot"
            }
            Mock Remove-VssSnapshot { }

            {
                Invoke-WithVssSnapshot -SourcePath "C:\Test" -ScriptBlock {
                    param($VssPath)
                    # This should never execute
                    $script:executed = $true
                }
            } | Should -Throw "*Failed to create VSS snapshot*"

            $script:executed | Should -Be $false
            Should -Invoke Remove-VssSnapshot -Times 0
        }

        It "Should pass correct VSS path to scriptblock" {
            Mock New-VssSnapshot {
                return [PSCustomObject]@{
                    ShadowId     = "{PATH-TEST-1234-1234-123456789012}"
                    ShadowPath   = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy10"
                    SourceVolume = "E:"
                    CreatedAt    = [datetime]::Now
                }
            }
            Mock Remove-VssSnapshot { }

            $script:capturedPath = $null
            Invoke-WithVssSnapshot -SourcePath "E:\Projects\MyApp" -ScriptBlock {
                param($VssPath)
                $script:capturedPath = $VssPath
            }

            $script:capturedPath | Should -Be "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy10\Projects\MyApp"
            Should -Invoke Remove-VssSnapshot -Times 1
        }

        It "Should handle cleanup failure gracefully" {
            Mock New-VssSnapshot {
                return [PSCustomObject]@{
                    ShadowId     = "{CLEANUP-FAIL-1234-1234-123456789012}"
                    ShadowPath   = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy7"
                    SourceVolume = "C:"
                    CreatedAt    = [datetime]::Now
                }
            }
            Mock Remove-VssSnapshot {
                throw "Failed to delete snapshot"
            }

            # Should not throw even if cleanup fails
            {
                Invoke-WithVssSnapshot -SourcePath "C:\Test" -ScriptBlock {
                    param($VssPath)
                    $script:executed = $true
                }
            } | Should -Not -Throw

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
