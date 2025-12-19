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

Describe "Get-VolumeRetentionCount" {
    Context "When volume has specific override" {
        It "Returns the override value" {
            $config = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    SnapshotRetention = [PSCustomObject]@{
                        DefaultKeepCount = 3
                        VolumeOverrides = @{ "D:" = 10; "E:" = 5 }
                    }
                }
            }

            $count = Get-VolumeRetentionCount -Volume "D:" -Config $config
            $count | Should -Be 10
        }
    }

    Context "When volume has no override" {
        It "Returns the default value" {
            $config = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    SnapshotRetention = [PSCustomObject]@{
                        DefaultKeepCount = 7
                        VolumeOverrides = @{ "E:" = 5 }
                    }
                }
            }

            $count = Get-VolumeRetentionCount -Volume "D:" -Config $config
            $count | Should -Be 7
        }
    }

    Context "Case insensitivity" {
        It "Handles lowercase volume input" {
            $config = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    SnapshotRetention = [PSCustomObject]@{
                        DefaultKeepCount = 3
                        VolumeOverrides = @{ "D:" = 10 }
                    }
                }
            }

            $count = Get-VolumeRetentionCount -Volume "d:" -Config $config
            $count | Should -Be 10
        }
    }
}

Describe "Invoke-ProfilePersistentSnapshot" {
    Context "When PersistentSnapshot is not enabled" {
        It "Returns success with null data" {
            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = "D:\Data"
                PersistentSnapshot = [PSCustomObject]@{ Enabled = $false }
            }
            $config = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    SnapshotRetention = [PSCustomObject]@{
                        DefaultKeepCount = 3
                        VolumeOverrides = @{}
                    }
                }
            }

            $result = Invoke-ProfilePersistentSnapshot -Profile $profile -Config $config
            $result.Success | Should -Be $true
            $result.Data | Should -BeNull
        }
    }

    Context "When PersistentSnapshot is enabled for local path" {
        BeforeAll {
            Mock Invoke-VssRetentionPolicy { New-OperationResult -Success $true -Data @{ DeletedCount = 0; KeptCount = 2 } }
            Mock New-VssSnapshot { New-OperationResult -Success $true -Data @{ ShadowId = "{new-snap}" } }
            Mock Get-VolumeFromPath { "D:" }
        }

        It "Enforces retention and creates snapshot" {
            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = "D:\Data"
                PersistentSnapshot = [PSCustomObject]@{ Enabled = $true }
            }
            $config = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    SnapshotRetention = [PSCustomObject]@{
                        DefaultKeepCount = 3
                        VolumeOverrides = @{}
                    }
                }
            }

            $result = Invoke-ProfilePersistentSnapshot -Profile $profile -Config $config
            $result.Success | Should -Be $true

            Should -Invoke Invoke-VssRetentionPolicy -Times 1
            Should -Invoke New-VssSnapshot -Times 1
        }
    }

    Context "When PersistentSnapshot is enabled for UNC path" {
        BeforeAll {
            Mock Get-UncPathComponents {
                [PSCustomObject]@{ ServerName = "Server1"; ShareName = "Share1"; RelativePath = "Folder" }
            }
            Mock Get-RemoteShareLocalPath { "D:\ShareRoot" }
            Mock Invoke-RemoteVssRetentionPolicy { New-OperationResult -Success $true -Data @{ DeletedCount = 1 } }
            Mock New-RemoteVssSnapshot { New-OperationResult -Success $true -Data @{ ShadowId = "{remote-snap}" } }
        }

        It "Uses remote functions" {
            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = "\\Server1\Share1\Folder"
                PersistentSnapshot = [PSCustomObject]@{ Enabled = $true }
            }
            $config = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    SnapshotRetention = [PSCustomObject]@{
                        DefaultKeepCount = 5
                        VolumeOverrides = @{}
                    }
                }
            }

            $result = Invoke-ProfilePersistentSnapshot -Profile $profile -Config $config
            $result.Success | Should -Be $true

            Should -Invoke Invoke-RemoteVssRetentionPolicy -Times 1
            Should -Invoke New-RemoteVssSnapshot -Times 1
        }
    }
}

Describe "Configuration Schema" {
    Context "New-DefaultConfig includes snapshot retention" {
        It "Has SnapshotRetention in GlobalSettings" {
            $config = New-DefaultConfig
            $config.GlobalSettings.SnapshotRetention | Should -Not -BeNull
            $config.GlobalSettings.SnapshotRetention.DefaultKeepCount | Should -Be 3
        }
    }
}
