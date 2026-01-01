#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type (required for module isolation when running all tests together)
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "NetworkMapping" {
        BeforeAll {
            Mock Write-RobocurseLog { }
        }

        Context "Get-UncRoot" {
            It "Should extract root from UNC path with subfolder" {
                Get-UncRoot '\\192.168.1.1\share\subfolder\file.txt' | Should -Be '\\192.168.1.1\share'
            }

            It "Should extract root from UNC path with just share" {
                Get-UncRoot '\\server\share' | Should -Be '\\server\share'
            }

            It "Should handle hostname-based UNC paths" {
                Get-UncRoot '\\fileserver.domain.local\backups\daily' | Should -Be '\\fileserver.domain.local\backups'
            }

            It "Should return original path if not valid UNC" {
                Get-UncRoot 'C:\local\path' | Should -Be 'C:\local\path'
            }
        }

        Context "Mount-NetworkPaths with local paths" {
            It "Should return original paths for local source and destination" {
                $result = Mount-NetworkPaths -SourcePath 'C:\Source' -DestinationPath 'D:\Dest'

                $result.SourcePath | Should -Be 'C:\Source'
                $result.DestinationPath | Should -Be 'D:\Dest'
                $result.Mappings.Count | Should -Be 0
            }

            It "Should return original paths for relative paths" {
                $result = Mount-NetworkPaths -SourcePath '.\Source' -DestinationPath '.\Dest'

                $result.SourcePath | Should -Be '.\Source'
                $result.DestinationPath | Should -Be '.\Dest'
                $result.Mappings.Count | Should -Be 0
            }
        }

        Context "Mount-NetworkPaths with UNC paths" {
            BeforeEach {
                # Mock Get-PSDrive to return typical drives (no network mappings)
                Mock Get-PSDrive {
                    @(
                        [PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null },
                        [PSCustomObject]@{ Name = 'D'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null }
                    )
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                # Mock New-PSDrive to succeed
                Mock New-PSDrive { }

                # Mock Remove-PSDrive
                Mock Remove-PSDrive { }

                # Mock Get-ChildItem to simulate successful mount verification
                Mock Get-ChildItem { @() }
            }

            It "Should mount UNC source path" {
                $result = Mount-NetworkPaths -SourcePath '\\192.168.1.1\share\data' -DestinationPath 'D:\Backup'

                $result.Mappings.Count | Should -Be 1
                $result.Mappings[0].Root | Should -Be '\\192.168.1.1\share'
                $result.Mappings[0].DriveLetter | Should -Be 'Z'
                $result.SourcePath | Should -Be 'Z:\data'
                $result.DestinationPath | Should -Be 'D:\Backup'

                Should -Invoke New-PSDrive -Times 1 -ParameterFilter {
                    $Name -eq 'Z' -and $Root -eq '\\192.168.1.1\share'
                }
            }

            It "Should mount UNC destination path" {
                $result = Mount-NetworkPaths -SourcePath 'C:\Data' -DestinationPath '\\192.168.1.1\backup\daily'

                $result.Mappings.Count | Should -Be 1
                $result.Mappings[0].Root | Should -Be '\\192.168.1.1\backup'
                $result.SourcePath | Should -Be 'C:\Data'
                $result.DestinationPath | Should -Be 'Z:\daily'
            }

            It "Should mount both source and destination UNC paths" {
                $result = Mount-NetworkPaths -SourcePath '\\10.0.0.1\source\files' -DestinationPath '\\10.0.0.2\dest\backup'

                $result.Mappings.Count | Should -Be 2
                $result.SourcePath | Should -Match '^[A-Z]:\\files$'
                $result.DestinationPath | Should -Match '^[A-Z]:\\backup$'
            }

            It "Should reuse mapping when source and dest share same root" {
                $result = Mount-NetworkPaths -SourcePath '\\192.168.1.1\share\source' -DestinationPath '\\192.168.1.1\share\dest'

                $result.Mappings.Count | Should -Be 1
                $result.SourcePath | Should -Be 'Z:\source'
                $result.DestinationPath | Should -Be 'Z:\dest'

                # Should only call New-PSDrive once
                Should -Invoke New-PSDrive -Times 1
            }
        }

        Context "Mount-SingleNetworkPath drive letter selection" {
            BeforeEach {
                # Mock Get-ChildItem to simulate successful mount verification
                Mock Get-ChildItem { @() }
            }

            It "Should select Z as first available letter" {
                Mock Get-PSDrive {
                    @(
                        [PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null }
                    )
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }
                Mock New-PSDrive { }
                Mock Remove-PSDrive { }

                $result = Mount-SingleNetworkPath -UncPath '\\server\share'

                $result.DriveLetter | Should -Be 'Z'
            }

            It "Should skip used letters and pick next available" {
                Mock Get-PSDrive {
                    @(
                        [PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null },
                        [PSCustomObject]@{ Name = 'Z'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null },
                        [PSCustomObject]@{ Name = 'Y'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null }
                    )
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }
                Mock New-PSDrive { }
                Mock Remove-PSDrive { }

                $result = Mount-SingleNetworkPath -UncPath '\\server\share'

                $result.DriveLetter | Should -Be 'X'
            }

            It "Should throw when no drive letters available" {
                # Mock all letters D-Z as used
                Mock Get-PSDrive {
                    $allLetters = @('C') + [char[]](68..90)  # C + D through Z
                    $allLetters | ForEach-Object {
                        [PSCustomObject]@{ Name = $_; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null }
                    }
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                { Mount-SingleNetworkPath -UncPath '\\server\share' } | Should -Throw "*No available drive letters*"
            }
        }

        Context "Mount-SingleNetworkPath stale mapping cleanup" {
            BeforeEach {
                # Mock Get-ChildItem to simulate successful mount verification
                Mock Get-ChildItem { @() }
            }

            It "Should remove existing mapping to same root before mounting" {
                Mock Get-PSDrive {
                    @(
                        [PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null },
                        [PSCustomObject]@{ Name = 'X'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = '\\192.168.1.1\share' }
                    )
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }
                Mock New-PSDrive { }
                Mock Remove-PSDrive { }

                Mount-SingleNetworkPath -UncPath '\\192.168.1.1\share\subfolder'

                Should -Invoke Remove-PSDrive -Times 1 -ParameterFilter { $Name -eq 'X' }
            }
        }

        Context "Dismount-NetworkPaths" {
            BeforeEach {
                Mock Remove-PSDrive { }
            }

            It "Should remove all mapped drives" {
                $mappings = @(
                    [PSCustomObject]@{ DriveLetter = 'Z'; Root = '\\server1\share' },
                    [PSCustomObject]@{ DriveLetter = 'Y'; Root = '\\server2\share' }
                )

                Dismount-NetworkPaths -Mappings $mappings

                Should -Invoke Remove-PSDrive -Times 1 -ParameterFilter { $Name -eq 'Z' }
                Should -Invoke Remove-PSDrive -Times 1 -ParameterFilter { $Name -eq 'Y' }
            }

            It "Should handle empty mappings gracefully" {
                { Dismount-NetworkPaths -Mappings @() } | Should -Not -Throw
            }

            It "Should handle null mappings gracefully" {
                { Dismount-NetworkPaths -Mappings $null } | Should -Not -Throw
            }

            It "Should continue if one unmount fails" {
                Mock Remove-PSDrive { throw "Drive in use" } -ParameterFilter { $Name -eq 'Z' }
                Mock Remove-PSDrive { } -ParameterFilter { $Name -eq 'Y' }

                $mappings = @(
                    [PSCustomObject]@{ DriveLetter = 'Z'; Root = '\\server1\share' },
                    [PSCustomObject]@{ DriveLetter = 'Y'; Root = '\\server2\share' }
                )

                { Dismount-NetworkPaths -Mappings $mappings } | Should -Not -Throw

                # Should still try to unmount Y after Z fails
                Should -Invoke Remove-PSDrive -Times 1 -ParameterFilter { $Name -eq 'Y' }
            }
        }

        Context "Mount-NetworkPaths error handling" {
            It "Should throw when New-PSDrive fails" {
                Mock Get-PSDrive {
                    @([PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null })
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }
                Mock New-PSDrive { throw "Access denied" }
                Mock Remove-PSDrive { }

                { Mount-NetworkPaths -SourcePath '\\192.168.1.1\share' -DestinationPath 'D:\Backup' } |
                    Should -Throw "*Access denied*"
            }
        }

        Context "Network Mapping Tracking" {
            BeforeEach {
                # Set up isolated tracking directory
                $script:TestTrackingDir = Join-Path $env:TEMP "RobocurseTrackingTest_$(Get-Random)"
                New-Item -Path $script:TestTrackingDir -ItemType Directory -Force | Out-Null
                $script:LogPath = $script:TestTrackingDir
                Initialize-NetworkMappingTracking
            }

            AfterEach {
                if (Test-Path $script:TestTrackingDir) {
                    Remove-Item $script:TestTrackingDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            It "Add-NetworkMappingTracking should create tracking file" {
                $mapping = [PSCustomObject]@{
                    DriveLetter = 'Z'
                    Root = '\\server\share'
                    OriginalPath = '\\server\share\data'
                    MappedPath = 'Z:\data'
                }

                Add-NetworkMappingTracking -Mapping $mapping

                Test-Path $script:NetworkMappingTrackingFile | Should -Be $true
                $content = Get-Content $script:NetworkMappingTrackingFile -Raw | ConvertFrom-Json
                @($content).Count | Should -Be 1
                $content.DriveLetter | Should -Be 'Z'
                $content.Root | Should -Be '\\server\share'
            }

            It "Add-NetworkMappingTracking should append to existing file" {
                $mapping1 = [PSCustomObject]@{
                    DriveLetter = 'Z'
                    Root = '\\server1\share'
                    OriginalPath = '\\server1\share\data'
                    MappedPath = 'Z:\data'
                }
                $mapping2 = [PSCustomObject]@{
                    DriveLetter = 'Y'
                    Root = '\\server2\share'
                    OriginalPath = '\\server2\share\backup'
                    MappedPath = 'Y:\backup'
                }

                Add-NetworkMappingTracking -Mapping $mapping1
                Add-NetworkMappingTracking -Mapping $mapping2

                $content = Get-Content $script:NetworkMappingTrackingFile -Raw | ConvertFrom-Json
                @($content).Count | Should -Be 2
            }

            It "Remove-NetworkMappingTracking should remove mapping from file" {
                $mapping1 = [PSCustomObject]@{
                    DriveLetter = 'Z'
                    Root = '\\server1\share'
                    OriginalPath = '\\server1\share'
                    MappedPath = 'Z:\'
                }
                $mapping2 = [PSCustomObject]@{
                    DriveLetter = 'Y'
                    Root = '\\server2\share'
                    OriginalPath = '\\server2\share'
                    MappedPath = 'Y:\'
                }

                Add-NetworkMappingTracking -Mapping $mapping1
                Add-NetworkMappingTracking -Mapping $mapping2

                Remove-NetworkMappingTracking -DriveLetter 'Z'

                $content = @(Get-Content $script:NetworkMappingTrackingFile -Raw | ConvertFrom-Json)
                $content.Count | Should -Be 1
                $content[0].DriveLetter | Should -Be 'Y'
            }

            It "Remove-NetworkMappingTracking should delete file when last mapping removed" {
                $mapping = [PSCustomObject]@{
                    DriveLetter = 'Z'
                    Root = '\\server\share'
                    OriginalPath = '\\server\share'
                    MappedPath = 'Z:\'
                }

                Add-NetworkMappingTracking -Mapping $mapping
                Remove-NetworkMappingTracking -DriveLetter 'Z'

                Test-Path $script:NetworkMappingTrackingFile | Should -Be $false
            }
        }

        Context "Clear-OrphanNetworkMappings" {
            BeforeEach {
                # Set up isolated tracking directory
                $script:TestTrackingDir = Join-Path $env:TEMP "RobocurseOrphanTest_$(Get-Random)"
                New-Item -Path $script:TestTrackingDir -ItemType Directory -Force | Out-Null
                $script:LogPath = $script:TestTrackingDir
                Initialize-NetworkMappingTracking
            }

            AfterEach {
                if (Test-Path $script:TestTrackingDir) {
                    Remove-Item $script:TestTrackingDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            It "Should return 0 when no tracking file exists" {
                $result = Clear-OrphanNetworkMappings
                $result | Should -Be 0
            }

            It "Should clean up tracking file when drives no longer exist" {
                # Create tracking file with non-existent mapping
                $trackingData = @(
                    @{ DriveLetter = "Q:"; Root = "\\nonexistent\share"; OriginalPath = "\\nonexistent\share"; MappedPath = "Q:\" }
                )
                $trackingData | ConvertTo-Json | Set-Content $script:NetworkMappingTrackingFile

                Mock Get-PSDrive { $null } -ParameterFilter { $Name -eq 'Q' }

                Clear-OrphanNetworkMappings

                Test-Path $script:NetworkMappingTrackingFile | Should -Be $false
            }

            It "Should remove drive if it matches tracked mapping" {
                Mock Get-PSDrive {
                    [PSCustomObject]@{ Name = "Q"; Root = "\\server\share" }
                } -ParameterFilter { $Name -eq 'Q' }
                Mock Remove-PSDrive { }

                $trackingData = @(
                    @{ DriveLetter = "Q:"; Root = "\\server\share"; OriginalPath = "\\server\share"; MappedPath = "Q:\" }
                )
                $trackingData | ConvertTo-Json | Set-Content $script:NetworkMappingTrackingFile

                $result = Clear-OrphanNetworkMappings

                $result | Should -Be 1
                Should -Invoke Remove-PSDrive -Times 1 -ParameterFilter { $Name -eq 'Q' }
            }

            It "Should not remove drive if it points to different location" {
                Mock Get-PSDrive {
                    [PSCustomObject]@{ Name = "Q"; Root = "\\different\server" }
                } -ParameterFilter { $Name -eq 'Q' }
                Mock Remove-PSDrive { }

                $trackingData = @(
                    @{ DriveLetter = "Q:"; Root = "\\server\share"; OriginalPath = "\\server\share"; MappedPath = "Q:\" }
                )
                $trackingData | ConvertTo-Json | Set-Content $script:NetworkMappingTrackingFile

                $result = Clear-OrphanNetworkMappings

                $result | Should -Be 0
                Should -Invoke Remove-PSDrive -Times 0
            }

            It "Should support -WhatIf" {
                Mock Get-PSDrive {
                    [PSCustomObject]@{ Name = "Q"; Root = "\\server\share" }
                } -ParameterFilter { $Name -eq 'Q' }
                Mock Remove-PSDrive { }

                $trackingData = @(
                    @{ DriveLetter = "Q:"; Root = "\\server\share" }
                )
                $trackingData | ConvertTo-Json | Set-Content $script:NetworkMappingTrackingFile

                Clear-OrphanNetworkMappings -WhatIf

                Should -Invoke Remove-PSDrive -Times 0
                Test-Path $script:NetworkMappingTrackingFile | Should -Be $true
            }
        }

        Context "Mount-SingleNetworkPath tracking integration" {
            BeforeEach {
                # Set up isolated tracking directory
                $script:TestTrackingDir = Join-Path $env:TEMP "RobocurseMountTrackTest_$(Get-Random)"
                New-Item -Path $script:TestTrackingDir -ItemType Directory -Force | Out-Null
                $script:LogPath = $script:TestTrackingDir
                Initialize-NetworkMappingTracking

                Mock Get-PSDrive {
                    @([PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null })
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }
                Mock New-PSDrive { }
                Mock Get-ChildItem { @() }
            }

            AfterEach {
                if (Test-Path $script:TestTrackingDir) {
                    Remove-Item $script:TestTrackingDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            It "Should add mapping to tracking file when mounted" {
                Mount-SingleNetworkPath -UncPath '\\server\share\data'

                Test-Path $script:NetworkMappingTrackingFile | Should -Be $true
                $content = Get-Content $script:NetworkMappingTrackingFile -Raw | ConvertFrom-Json
                @($content).Count | Should -Be 1
                $content.Root | Should -Be '\\server\share'
            }
        }

        Context "Dismount-NetworkPaths tracking integration" {
            BeforeEach {
                # Set up isolated tracking directory
                $script:TestTrackingDir = Join-Path $env:TEMP "RobocurseDismountTrackTest_$(Get-Random)"
                New-Item -Path $script:TestTrackingDir -ItemType Directory -Force | Out-Null
                $script:LogPath = $script:TestTrackingDir
                Initialize-NetworkMappingTracking

                Mock Remove-PSDrive { }
            }

            AfterEach {
                if (Test-Path $script:TestTrackingDir) {
                    Remove-Item $script:TestTrackingDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            It "Should remove mapping from tracking file when dismounted" {
                # Pre-populate tracking file
                $trackingData = @(
                    @{ DriveLetter = "Z:"; Root = "\\server\share"; OriginalPath = "\\server\share"; MappedPath = "Z:\" }
                )
                $trackingData | ConvertTo-Json | Set-Content $script:NetworkMappingTrackingFile

                $mappings = @(
                    [PSCustomObject]@{ DriveLetter = 'Z'; Root = '\\server\share' }
                )

                Dismount-NetworkPaths -Mappings $mappings

                Test-Path $script:NetworkMappingTrackingFile | Should -Be $false
            }
        }

        Context "Get-NextAvailableDriveLetter" {
            It "Should return Z when no drives are reserved" {
                Mock Get-PSDrive {
                    @(
                        [PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null }
                    )
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                # Clear any reserved letters
                $script:ReservedDriveLetters.Clear()

                $letter = Get-NextAvailableDriveLetter

                $letter | Should -Be 'Z'
            }

            It "Should skip reserved letters" {
                Mock Get-PSDrive {
                    @(
                        [PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null }
                    )
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                # Reserve Z and Y
                $script:ReservedDriveLetters.Clear()
                $script:ReservedDriveLetters.Add('Z') | Out-Null
                $script:ReservedDriveLetters.Add('Y') | Out-Null

                $letter = Get-NextAvailableDriveLetter

                $letter | Should -Be 'X'

                # Cleanup
                $script:ReservedDriveLetters.Clear()
            }

            It "Should skip both used and reserved letters" {
                Mock Get-PSDrive {
                    @(
                        [PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null },
                        [PSCustomObject]@{ Name = 'Z'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null }
                    )
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                # Reserve Y
                $script:ReservedDriveLetters.Clear()
                $script:ReservedDriveLetters.Add('Y') | Out-Null

                $letter = Get-NextAvailableDriveLetter

                $letter | Should -Be 'X'

                # Cleanup
                $script:ReservedDriveLetters.Clear()
            }

            It "Should return null when all letters are used or reserved" {
                Mock Get-PSDrive {
                    # Return all letters D-Z as used
                    $allLetters = @('C') + [char[]](68..90)  # C + D through Z
                    $allLetters | ForEach-Object {
                        [PSCustomObject]@{ Name = $_; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null }
                    }
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                $script:ReservedDriveLetters.Clear()

                $letter = Get-NextAvailableDriveLetter

                $letter | Should -Be $null
            }
        }

        Context "Concurrent drive letter allocation" {
            BeforeEach {
                Mock Get-ChildItem { @() }
                Mock New-PSDrive { }
                Mock Remove-PSDrive { }
                $script:ReservedDriveLetters.Clear()
            }

            It "Should allocate different letters to concurrent requests" {
                # This test simulates what happens when two mount operations happen concurrently
                # by manually reserving letters as they would be during the mount operation

                Mock Get-PSDrive {
                    @(
                        [PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null }
                    )
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                # First allocation gets Z
                $letter1 = Get-NextAvailableDriveLetter
                $script:ReservedDriveLetters.Add([string]$letter1) | Out-Null

                # Second allocation should get Y (Z is reserved)
                $letter2 = Get-NextAvailableDriveLetter

                $letter1 | Should -Be 'Z'
                $letter2 | Should -Be 'Y'
                $letter1 | Should -Not -Be $letter2

                # Cleanup
                $script:ReservedDriveLetters.Clear()
            }

            It "Reserved letters should be cleaned up on mount failure" {
                Mock Get-PSDrive {
                    @(
                        [PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null }
                    )
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                Mock New-PSDrive { throw "Access denied" }

                $script:ReservedDriveLetters.Clear()

                # This should fail and clean up the reserved letter
                { Mount-SingleNetworkPath -UncPath '\\server\share' } | Should -Throw

                # Reserved letters should be empty after failure
                $script:ReservedDriveLetters.Count | Should -Be 0
            }
        }
    }
}
