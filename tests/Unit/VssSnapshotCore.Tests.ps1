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
    BeforeAll {
        # Common mock config for all tests - treat all snapshots as registered
        $script:testConfig = [PSCustomObject]@{ PersistentSnapshots = @() }
        Mock Test-SnapshotRegistered { $true }
        Mock Unregister-PersistentSnapshot { New-OperationResult -Success $true }
    }

    Context "When under retention limit" {
        BeforeAll {
            Mock Get-VssSnapshots {
                New-OperationResult -Success $true -Data @(
                    [PSCustomObject]@{ ShadowId = "{snap1}"; CreatedAt = (Get-Date).AddHours(-1) }
                )
            }
        }

        It "Does not delete any snapshots" {
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 3 -Config $script:testConfig -ConfigPath "test.json"
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
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 1 -Config $script:testConfig -ConfigPath "test.json"
            $result.Success | Should -Be $true
            $result.Data.DeletedCount | Should -Be 2
            $result.Data.KeptCount | Should -Be 1
        }

        It "Keeps newest snapshot" {
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 1 -Config $script:testConfig -ConfigPath "test.json"

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
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 1 -Config $script:testConfig -ConfigPath "test.json"
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
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 1 -Config $script:testConfig -ConfigPath "test.json" -WhatIf
            Should -Not -Invoke Remove-VssSnapshot
        }
    }

    Context "Registry-aware retention (Config provided)" {
        BeforeAll {
            # Mix of registered and external snapshots
            Mock Get-VssSnapshots {
                New-OperationResult -Success $true -Data @(
                    [PSCustomObject]@{ ShadowId = "{registered-1}"; CreatedAt = (Get-Date).AddHours(-5) },
                    [PSCustomObject]@{ ShadowId = "{external-1}"; CreatedAt = (Get-Date).AddHours(-4) },
                    [PSCustomObject]@{ ShadowId = "{registered-2}"; CreatedAt = (Get-Date).AddHours(-3) },
                    [PSCustomObject]@{ ShadowId = "{external-2}"; CreatedAt = (Get-Date).AddHours(-2) },
                    [PSCustomObject]@{ ShadowId = "{registered-3}"; CreatedAt = (Get-Date).AddHours(-1) }
                )
            }

            # Only registered-* are in the registry
            Mock Test-SnapshotRegistered {
                param($Config, $ShadowId)
                $ShadowId -like "{registered-*}"
            }

            Mock Remove-VssSnapshot { New-OperationResult -Success $true -Data $ShadowId }
            Mock Unregister-PersistentSnapshot { New-OperationResult -Success $true }
        }

        It "Should NOT delete external snapshots" {
            $config = [PSCustomObject]@{ SnapshotRegistry = @() }

            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 1 -Config $config -ConfigPath "test.json"
            $result.Success | Should -Be $true

            # External snapshots should NEVER be deleted
            Should -Not -Invoke Remove-VssSnapshot -ParameterFilter { $ShadowId -eq "{external-1}" }
            Should -Not -Invoke Remove-VssSnapshot -ParameterFilter { $ShadowId -eq "{external-2}" }
        }

        It "Should only count registered snapshots against retention" {
            $config = [PSCustomObject]@{ SnapshotRegistry = @() }

            # With KeepCount=2, only 1 registered snapshot should be deleted (oldest registered)
            # Even though there are 5 total snapshots, only 3 are registered
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 2 -Config $config -ConfigPath "test.json"
            $result.Success | Should -Be $true
            $result.Data.DeletedCount | Should -Be 1
            $result.Data.KeptCount | Should -Be 2

            # Only the oldest registered snapshot should be deleted
            Should -Invoke Remove-VssSnapshot -Times 1 -ParameterFilter { $ShadowId -eq "{registered-1}" }
        }

        It "Should return ExternalCount correctly" {
            $config = [PSCustomObject]@{ SnapshotRegistry = @() }

            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 3 -Config $config -ConfigPath "test.json"
            $result.Success | Should -Be $true
            $result.Data.ExternalCount | Should -Be 2
        }

        It "Should call Unregister-PersistentSnapshot when deleting" {
            $config = [PSCustomObject]@{ SnapshotRegistry = @() }
            $configPath = "C:\test\config.json"

            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 1 -Config $config -ConfigPath $configPath
            $result.Success | Should -Be $true

            # Should unregister deleted snapshots
            Should -Invoke Unregister-PersistentSnapshot -Times 2 -ParameterFilter {
                $ShadowId -eq "{registered-1}" -or $ShadowId -eq "{registered-2}"
            }
        }

        It "Should NOT delete any snapshots when registered count is under limit" {
            $config = [PSCustomObject]@{ SnapshotRegistry = @() }

            # 3 registered snapshots, KeepCount=5, should delete nothing
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 5 -Config $config -ConfigPath "test.json"
            $result.Success | Should -Be $true
            $result.Data.DeletedCount | Should -Be 0
            $result.Data.KeptCount | Should -Be 3
            $result.Data.ExternalCount | Should -Be 2

            Should -Not -Invoke Remove-VssSnapshot
        }
    }
}
