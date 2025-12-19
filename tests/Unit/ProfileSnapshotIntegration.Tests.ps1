BeforeAll {
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Utility.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Logging.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssCore.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssLocal.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssRemote.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Configuration.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\JobManagement.ps1"

    Mock Write-RobocurseLog {}
}

Describe "Get-EffectiveVolumeRetention" {
    Context "When single profile targets volume" {
        It "Returns the profile retention count for Source" {
            $config = [PSCustomObject]@{
                SyncProfiles = @(
                    [PSCustomObject]@{
                        Name = "Profile1"
                        Source = "D:\Data"
                        Destination = "E:\Backup"
                        SourceSnapshot = [PSCustomObject]@{
                            PersistentEnabled = $true
                            RetentionCount = 5
                        }
                        DestinationSnapshot = [PSCustomObject]@{
                            PersistentEnabled = $true
                            RetentionCount = 3
                        }
                    }
                )
            }

            $count = Get-EffectiveVolumeRetention -Volume "D:" -Side "Source" -Config $config
            $count | Should -Be 5
        }

        It "Returns the profile retention count for Destination" {
            $config = [PSCustomObject]@{
                SyncProfiles = @(
                    [PSCustomObject]@{
                        Name = "Profile1"
                        Source = "D:\Data"
                        Destination = "E:\Backup"
                        SourceSnapshot = [PSCustomObject]@{
                            PersistentEnabled = $true
                            RetentionCount = 5
                        }
                        DestinationSnapshot = [PSCustomObject]@{
                            PersistentEnabled = $true
                            RetentionCount = 7
                        }
                    }
                )
            }

            $count = Get-EffectiveVolumeRetention -Volume "E:" -Side "Destination" -Config $config
            $count | Should -Be 7
        }
    }

    Context "When multiple profiles target same volume" {
        It "Returns MAX retention across profiles" {
            $config = [PSCustomObject]@{
                SyncProfiles = @(
                    [PSCustomObject]@{
                        Name = "Profile1"
                        Source = "D:\Data1"
                        Destination = "E:\Backup1"
                        SourceSnapshot = [PSCustomObject]@{
                            PersistentEnabled = $true
                            RetentionCount = 3
                        }
                        DestinationSnapshot = [PSCustomObject]@{
                            PersistentEnabled = $true
                            RetentionCount = 5
                        }
                    },
                    [PSCustomObject]@{
                        Name = "Profile2"
                        Source = "D:\Data2"
                        Destination = "E:\Backup2"
                        SourceSnapshot = [PSCustomObject]@{
                            PersistentEnabled = $true
                            RetentionCount = 7
                        }
                        DestinationSnapshot = [PSCustomObject]@{
                            PersistentEnabled = $true
                            RetentionCount = 10
                        }
                    }
                )
            }

            # Both profiles target D: for source, max is 7
            $count = Get-EffectiveVolumeRetention -Volume "D:" -Side "Source" -Config $config
            $count | Should -Be 7

            # Both profiles target E: for destination, max is 10
            $count = Get-EffectiveVolumeRetention -Volume "E:" -Side "Destination" -Config $config
            $count | Should -Be 10
        }
    }

    Context "When profile has snapshots disabled" {
        It "Ignores disabled profiles in MAX calculation" {
            $config = [PSCustomObject]@{
                SyncProfiles = @(
                    [PSCustomObject]@{
                        Name = "Profile1"
                        Source = "D:\Data1"
                        Destination = "E:\Backup1"
                        SourceSnapshot = [PSCustomObject]@{
                            PersistentEnabled = $true
                            RetentionCount = 3
                        }
                        DestinationSnapshot = [PSCustomObject]@{
                            PersistentEnabled = $true
                            RetentionCount = 5
                        }
                    },
                    [PSCustomObject]@{
                        Name = "Profile2"
                        Source = "D:\Data2"
                        Destination = "E:\Backup2"
                        SourceSnapshot = [PSCustomObject]@{
                            PersistentEnabled = $false  # Disabled
                            RetentionCount = 100
                        }
                        DestinationSnapshot = [PSCustomObject]@{
                            PersistentEnabled = $false  # Disabled
                            RetentionCount = 100
                        }
                    }
                )
            }

            # Profile2 is disabled, so only Profile1's count (3) applies
            $count = Get-EffectiveVolumeRetention -Volume "D:" -Side "Source" -Config $config
            $count | Should -Be 3
        }
    }

    Context "Case insensitivity" {
        It "Handles lowercase volume input" {
            $config = [PSCustomObject]@{
                SyncProfiles = @(
                    [PSCustomObject]@{
                        Name = "Profile1"
                        Source = "D:\Data"
                        Destination = "E:\Backup"
                        SourceSnapshot = [PSCustomObject]@{
                            PersistentEnabled = $true
                            RetentionCount = 8
                        }
                        DestinationSnapshot = [PSCustomObject]@{
                            PersistentEnabled = $true
                            RetentionCount = 4
                        }
                    }
                )
            }

            $count = Get-EffectiveVolumeRetention -Volume "d:" -Side "Source" -Config $config
            $count | Should -Be 8
        }
    }
}

Describe "Invoke-ProfileSnapshots" {
    Context "When both snapshots are disabled" {
        It "Returns success with no snapshots created" {
            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = "D:\Data"
                Destination = "E:\Backup"
                SourceSnapshot = [PSCustomObject]@{
                    PersistentEnabled = $false
                    RetentionCount = 3
                }
                DestinationSnapshot = [PSCustomObject]@{
                    PersistentEnabled = $false
                    RetentionCount = 3
                }
            }
            $config = [PSCustomObject]@{
                SyncProfiles = @($profile)
            }

            $result = Invoke-ProfileSnapshots -Profile $profile -Config $config
            $result.Success | Should -Be $true
            $result.Data.SourceSnapshot | Should -BeNull
            $result.Data.DestinationSnapshot | Should -BeNull
        }
    }

    Context "When SourceSnapshot is enabled for local path" {
        BeforeAll {
            Mock Invoke-VssRetentionPolicy { New-OperationResult -Success $true -Data @{ DeletedCount = 0; KeptCount = 2 } }
            Mock New-VssSnapshot { New-OperationResult -Success $true -Data @{ ShadowId = "{new-snap}" } }
            Mock Get-VolumeFromPath { "D:" }
        }

        It "Enforces retention and creates source snapshot" {
            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = "D:\Data"
                Destination = "E:\Backup"
                SourceSnapshot = [PSCustomObject]@{
                    PersistentEnabled = $true
                    RetentionCount = 5
                }
                DestinationSnapshot = [PSCustomObject]@{
                    PersistentEnabled = $false
                    RetentionCount = 3
                }
            }
            $config = [PSCustomObject]@{
                SyncProfiles = @($profile)
            }

            $result = Invoke-ProfileSnapshots -Profile $profile -Config $config
            $result.Success | Should -Be $true

            Should -Invoke Invoke-VssRetentionPolicy -Times 1
            Should -Invoke New-VssSnapshot -Times 1
        }
    }

    Context "When DestinationSnapshot is enabled for local path" {
        BeforeAll {
            Mock Invoke-VssRetentionPolicy { New-OperationResult -Success $true -Data @{ DeletedCount = 0; KeptCount = 2 } }
            Mock New-VssSnapshot { New-OperationResult -Success $true -Data @{ ShadowId = "{new-snap}" } }
            Mock Get-VolumeFromPath { "E:" }
        }

        It "Enforces retention and creates destination snapshot" {
            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = "D:\Data"
                Destination = "E:\Backup"
                SourceSnapshot = [PSCustomObject]@{
                    PersistentEnabled = $false
                    RetentionCount = 3
                }
                DestinationSnapshot = [PSCustomObject]@{
                    PersistentEnabled = $true
                    RetentionCount = 7
                }
            }
            $config = [PSCustomObject]@{
                SyncProfiles = @($profile)
            }

            $result = Invoke-ProfileSnapshots -Profile $profile -Config $config
            $result.Success | Should -Be $true

            Should -Invoke Invoke-VssRetentionPolicy -Times 1
            Should -Invoke New-VssSnapshot -Times 1
        }
    }

    Context "When SourceSnapshot is enabled for UNC path" {
        BeforeAll {
            Mock Get-UncPathComponents {
                [PSCustomObject]@{ ServerName = "Server1"; ShareName = "Share1"; RelativePath = "Folder" }
            }
            Mock Get-RemoteShareLocalPath { "D:\ShareRoot" }
            Mock Invoke-RemoteVssRetentionPolicy { New-OperationResult -Success $true -Data @{ DeletedCount = 1 } }
            Mock New-RemoteVssSnapshot { New-OperationResult -Success $true -Data @{ ShadowId = "{remote-snap}" } }
        }

        It "Uses remote functions for source" {
            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = "\\Server1\Share1\Folder"
                Destination = "E:\LocalBackup"
                SourceSnapshot = [PSCustomObject]@{
                    PersistentEnabled = $true
                    RetentionCount = 5
                }
                DestinationSnapshot = [PSCustomObject]@{
                    PersistentEnabled = $false
                    RetentionCount = 3
                }
            }
            $config = [PSCustomObject]@{
                SyncProfiles = @($profile)
            }

            $result = Invoke-ProfileSnapshots -Profile $profile -Config $config
            $result.Success | Should -Be $true

            Should -Invoke Invoke-RemoteVssRetentionPolicy -Times 1
            Should -Invoke New-RemoteVssSnapshot -Times 1
        }
    }
}

Describe "Configuration Schema" {
    Context "Profile created via ConvertFrom-FriendlyConfig includes snapshot settings" {
        It "Has SourceSnapshot and DestinationSnapshot" {
            # Create a profile via the friendly config format
            $friendlyConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{
                    TestProfile = [PSCustomObject]@{
                        source = "D:\Data"
                        destination = "E:\Backup"
                    }
                }
            }

            $config = ConvertFrom-FriendlyConfig -RawConfig $friendlyConfig
            $profile = $config.SyncProfiles[0]
            $profile.SourceSnapshot | Should -Not -BeNull
            $profile.SourceSnapshot.PersistentEnabled | Should -Be $false
            $profile.SourceSnapshot.RetentionCount | Should -Be 3
            $profile.DestinationSnapshot | Should -Not -BeNull
            $profile.DestinationSnapshot.PersistentEnabled | Should -Be $false
            $profile.DestinationSnapshot.RetentionCount | Should -Be 3
        }
    }

    Context "Legacy schema migration" {
        It "Migrates old PersistentSnapshot format to new schema" {
            # Create legacy config structure in friendly format
            $legacyConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{
                    OldProfile = [PSCustomObject]@{
                        source = "D:\Data"
                        destination = "E:\Backup"
                        persistentSnapshot = [PSCustomObject]@{
                            enabled = $true
                        }
                    }
                }
                global = [PSCustomObject]@{
                    snapshotRetention = [PSCustomObject]@{
                        defaultKeepCount = 5
                    }
                }
            }

            # Convert through the friendly format (simulates loading old config)
            $migrated = ConvertFrom-FriendlyConfig -RawConfig $legacyConfig

            # Should have new schema - legacy persistentSnapshot.enabled maps to sourceSnapshot.persistentEnabled
            $profile = $migrated.SyncProfiles[0]
            $profile.SourceSnapshot.PersistentEnabled | Should -Be $true
            $profile.SourceSnapshot.RetentionCount | Should -Be 5
            $profile.DestinationSnapshot.PersistentEnabled | Should -Be $false
        }
    }
}
