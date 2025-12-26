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
    }
}
