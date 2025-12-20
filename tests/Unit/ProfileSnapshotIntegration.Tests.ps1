BeforeAll {
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Utility.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Logging.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssCore.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssLocal.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssRemote.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Configuration.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\JobManagement.ps1"

    Mock Write-RobocurseLog {}

    # Create a test config path for ConfigPath parameter
    $script:TestConfigPath = Join-Path $env:TEMP "Robocurse-Test-Config-$([Guid]::NewGuid().ToString('N').Substring(0,8)).json"
    @{ Version = "1.0"; SyncProfiles = @() } | ConvertTo-Json | Out-File -FilePath $script:TestConfigPath -Encoding utf8
}

AfterAll {
    if ($script:TestConfigPath -and (Test-Path $script:TestConfigPath)) {
        Remove-Item $script:TestConfigPath -Force -ErrorAction SilentlyContinue
    }
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

            $result = Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath
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

            $result = Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath
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

            $result = Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath
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

            $result = Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath
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

Describe "Retention Policy Accumulation" {
    BeforeAll {
        # Track snapshot creation calls
        $script:CreatedSnapshots = @()
        $script:ExistingSnapshots = @()

        Mock Get-VolumeFromPath { "D:" }
        Mock Write-RobocurseLog {}
    }

    BeforeEach {
        $script:CreatedSnapshots = @()
        $script:ExistingSnapshots = @()
    }

    Context "Multiple backup runs should accumulate snapshots up to KeepCount" {
        BeforeAll {
            Mock Get-VssSnapshots {
                param($Volume)
                # Return current "existing" snapshots
                New-OperationResult -Success $true -Data @($script:ExistingSnapshots)
            }

            Mock New-VssSnapshot {
                param($SourcePath)
                # Create a new snapshot
                $newSnap = [PSCustomObject]@{
                    ShadowId = "{snap-$([guid]::NewGuid().ToString('N').Substring(0,8))}"
                    CreatedAt = [datetime]::Now
                    SourceVolume = "D:"
                }
                $script:CreatedSnapshots += $newSnap
                $script:ExistingSnapshots += $newSnap
                New-OperationResult -Success $true -Data $newSnap
            }

            Mock Remove-VssSnapshot {
                param($ShadowId)
                $script:ExistingSnapshots = @($script:ExistingSnapshots | Where-Object { $_.ShadowId -ne $ShadowId })
                New-OperationResult -Success $true
            }
        }

        It "Accumulates snapshots correctly over multiple runs with KeepCount=3" {
            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = "D:\Data"
                Destination = "D:\Backup"
                SourceSnapshot = [PSCustomObject]@{ PersistentEnabled = $false; RetentionCount = 3 }
                DestinationSnapshot = [PSCustomObject]@{ PersistentEnabled = $true; RetentionCount = 3 }
            }
            $config = [PSCustomObject]@{ SyncProfiles = @($profile) }

            # Run 1: Start with 0 snapshots
            $result1 = Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath
            $result1.Success | Should -Be $true
            $script:ExistingSnapshots.Count | Should -Be 1 -Because "First run creates 1 snapshot"

            # Run 2: Now have 1 snapshot
            $result2 = Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath
            $result2.Success | Should -Be $true
            $script:ExistingSnapshots.Count | Should -Be 2 -Because "Second run creates another, total 2"

            # Run 3: Now have 2 snapshots
            $result3 = Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath
            $result3.Success | Should -Be $true
            $script:ExistingSnapshots.Count | Should -Be 3 -Because "Third run creates another, total 3"

            # Run 4: Now have 3 snapshots, should delete 1 to make room for new one
            $result4 = Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath
            $result4.Success | Should -Be $true
            # Retention enforces BEFORE create with KeepCount-1 to make room:
            # 3 snapshots exist, retention targets KeepCount-1=2, so delete 1, then create 1 = 3 total
            $script:ExistingSnapshots.Count | Should -Be 3 -Because "Fourth run: retention deletes 1, creates 1, maintains KeepCount=3"

            # Run 5: Still have 3 snapshots, steady state
            $result5 = Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath
            $result5.Success | Should -Be $true
            $script:ExistingSnapshots.Count | Should -Be 3 -Because "Fifth run: maintains KeepCount=3 steady state"
        }

        It "With KeepCount=1, only keeps 1 snapshot in steady state" {
            $script:ExistingSnapshots = @()

            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = "D:\Data"
                Destination = "D:\Backup"
                SourceSnapshot = [PSCustomObject]@{ PersistentEnabled = $false; RetentionCount = 1 }
                DestinationSnapshot = [PSCustomObject]@{ PersistentEnabled = $true; RetentionCount = 1 }
            }
            $config = [PSCustomObject]@{ SyncProfiles = @($profile) }

            # Run 1: Start with 0 snapshots, retention targets 0, creates 1
            Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath
            $script:ExistingSnapshots.Count | Should -Be 1

            # Run 2: 1 snapshot exists, retention targets KeepCount-1=0, deletes 1, creates 1 = 1
            Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath
            $script:ExistingSnapshots.Count | Should -Be 1 -Because "Retention deletes old before creating new, maintains KeepCount=1"

            # Run 3: Still 1 snapshot (steady state)
            Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath
            $script:ExistingSnapshots.Count | Should -Be 1 -Because "Maintains KeepCount=1 steady state"

            # Run 4: Still 1 snapshot (steady state)
            Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath
            $script:ExistingSnapshots.Count | Should -Be 1 -Because "Stays at 1 in steady state"
        }
    }

    Context "Retention count comes from config, not hardcoded" {
        BeforeAll {
            Mock Invoke-VssRetentionPolicy {
                param($Volume, $KeepCount)
                # Just record what was called
                $script:LastKeepCount = $KeepCount
                New-OperationResult -Success $true -Data @{ DeletedCount = 0; KeptCount = 0 }
            }
            Mock New-VssSnapshot {
                New-OperationResult -Success $true -Data @{ ShadowId = "{test}" }
            }
        }

        It "Passes correct KeepCount from profile config (minus 1 to make room for new snapshot)" {
            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = "D:\Data"
                Destination = "D:\Backup"
                SourceSnapshot = [PSCustomObject]@{ PersistentEnabled = $false; RetentionCount = 3 }
                DestinationSnapshot = [PSCustomObject]@{ PersistentEnabled = $true; RetentionCount = 7 }
            }
            $config = [PSCustomObject]@{ SyncProfiles = @($profile) }

            Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath

            # Retention is called with KeepCount-1 to make room for the new snapshot about to be created
            Should -Invoke Invoke-VssRetentionPolicy -Times 1 -ParameterFilter { $KeepCount -eq 6 }
        }
    }

    Context "Persistent snapshots skip orphan tracking" {
        BeforeAll {
            Mock Invoke-VssRetentionPolicy {
                New-OperationResult -Success $true -Data @{ DeletedCount = 0; KeptCount = 0 }
            }
            # Track whether SkipTracking was passed
            $script:SkipTrackingCalled = $false
            Mock New-VssSnapshot {
                param($SourcePath, [switch]$SkipTracking)
                $script:SkipTrackingCalled = $SkipTracking.IsPresent
                New-OperationResult -Success $true -Data @{ ShadowId = "{test}" }
            }
        }

        It "Calls New-VssSnapshot with -SkipTracking for persistent destination snapshots" {
            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = "D:\Data"
                Destination = "D:\Backup"
                SourceSnapshot = [PSCustomObject]@{ PersistentEnabled = $false; RetentionCount = 3 }
                DestinationSnapshot = [PSCustomObject]@{ PersistentEnabled = $true; RetentionCount = 3 }
            }
            $config = [PSCustomObject]@{ SyncProfiles = @($profile) }

            Invoke-ProfileSnapshots -Profile $profile -Config $config -ConfigPath $script:TestConfigPath

            # Verify SkipTracking was passed
            $script:SkipTrackingCalled | Should -Be $true -Because "Persistent snapshots must skip tracking to survive restarts"
        }
    }
}
