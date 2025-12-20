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
            # Create a mock CIM session object that can be used in the test
            $script:mockCimSession = New-MockObject -Type 'Microsoft.Management.Infrastructure.CimSession'

            Mock New-CimSession { return $script:mockCimSession }
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
    BeforeAll {
        # Common mock config for all tests - treat all snapshots as registered
        $script:testConfig = [PSCustomObject]@{ PersistentSnapshots = @() }
        Mock Test-SnapshotRegistered { $true }
        Mock Unregister-PersistentSnapshot { New-OperationResult -Success $true }
    }

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
            $result = Invoke-RemoteVssRetentionPolicy -ServerName "TestServer" -Volume "D:" -KeepCount 1 -Config $script:testConfig -ConfigPath "test.json"
            $result.Success | Should -Be $true
            $result.Data.DeletedCount | Should -Be 2
        }

        It "Passes ServerName to Remove-RemoteVssSnapshot" {
            Invoke-RemoteVssRetentionPolicy -ServerName "TestServer" -Volume "D:" -KeepCount 1 -Config $script:testConfig -ConfigPath "test.json"
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
            $result = Invoke-RemoteVssRetentionPolicy -ServerName "TestServer" -Volume "D:" -KeepCount 5 -Config $script:testConfig -ConfigPath "test.json"
            $result.Success | Should -Be $true
            $result.Data.DeletedCount | Should -Be 0
        }
    }

    Context "Registry-aware retention (Config provided)" {
        BeforeAll {
            # Mix of registered and external snapshots on remote server
            Mock Get-RemoteVssSnapshots {
                New-OperationResult -Success $true -Data @(
                    [PSCustomObject]@{ ShadowId = "{reg-remote-1}"; CreatedAt = (Get-Date).AddHours(-4); ServerName = "TestServer" },
                    [PSCustomObject]@{ ShadowId = "{ext-remote-1}"; CreatedAt = (Get-Date).AddHours(-3); ServerName = "TestServer" },
                    [PSCustomObject]@{ ShadowId = "{reg-remote-2}"; CreatedAt = (Get-Date).AddHours(-2); ServerName = "TestServer" },
                    [PSCustomObject]@{ ShadowId = "{ext-remote-2}"; CreatedAt = (Get-Date).AddHours(-1); ServerName = "TestServer" }
                )
            }

            # Only reg-remote-* are in the registry
            Mock Test-SnapshotRegistered {
                param($Config, $ShadowId)
                $ShadowId -like "{reg-remote-*}"
            }

            Mock Remove-RemoteVssSnapshot { New-OperationResult -Success $true -Data $ShadowId }
            Mock Unregister-PersistentSnapshot { New-OperationResult -Success $true }
        }

        It "Should NOT delete external snapshots on remote server" {
            $config = [PSCustomObject]@{ SnapshotRegistry = @() }

            $result = Invoke-RemoteVssRetentionPolicy -ServerName "TestServer" -Volume "D:" -KeepCount 1 -Config $config -ConfigPath "test.json"
            $result.Success | Should -Be $true

            # External snapshots should NEVER be deleted
            Should -Not -Invoke Remove-RemoteVssSnapshot -ParameterFilter { $ShadowId -eq "{ext-remote-1}" }
            Should -Not -Invoke Remove-RemoteVssSnapshot -ParameterFilter { $ShadowId -eq "{ext-remote-2}" }
        }

        It "Should only count registered snapshots against remote retention" {
            $config = [PSCustomObject]@{ SnapshotRegistry = @() }

            # 2 registered, KeepCount=1, so delete 1
            $result = Invoke-RemoteVssRetentionPolicy -ServerName "TestServer" -Volume "D:" -KeepCount 1 -Config $config -ConfigPath "test.json"
            $result.Success | Should -Be $true
            $result.Data.DeletedCount | Should -Be 1
            $result.Data.KeptCount | Should -Be 1

            # Only the oldest registered snapshot should be deleted
            Should -Invoke Remove-RemoteVssSnapshot -Times 1 -ParameterFilter { $ShadowId -eq "{reg-remote-1}" }
        }

        It "Should return ExternalCount for remote snapshots" {
            $config = [PSCustomObject]@{ SnapshotRegistry = @() }

            $result = Invoke-RemoteVssRetentionPolicy -ServerName "TestServer" -Volume "D:" -KeepCount 2 -Config $config -ConfigPath "test.json"
            $result.Success | Should -Be $true
            $result.Data.ExternalCount | Should -Be 2
        }

        It "Should unregister deleted remote snapshots" {
            $config = [PSCustomObject]@{ SnapshotRegistry = @() }
            $configPath = "C:\test\config.json"

            $result = Invoke-RemoteVssRetentionPolicy -ServerName "TestServer" -Volume "D:" -KeepCount 1 -Config $config -ConfigPath $configPath
            $result.Success | Should -Be $true

            Should -Invoke Unregister-PersistentSnapshot -ParameterFilter { $ShadowId -eq "{reg-remote-1}" }
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
