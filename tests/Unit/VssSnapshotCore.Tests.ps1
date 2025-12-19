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
    Context "When under retention limit" {
        BeforeAll {
            Mock Get-VssSnapshots {
                New-OperationResult -Success $true -Data @(
                    [PSCustomObject]@{ ShadowId = "{snap1}"; CreatedAt = (Get-Date).AddHours(-1) }
                )
            }
        }

        It "Does not delete any snapshots" {
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 3
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
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 1
            $result.Success | Should -Be $true
            $result.Data.DeletedCount | Should -Be 2
            $result.Data.KeptCount | Should -Be 1
        }

        It "Keeps newest snapshot" {
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 1

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
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 1
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
            $result = Invoke-VssRetentionPolicy -Volume "D:" -KeepCount 1 -WhatIf
            Should -Not -Invoke Remove-VssSnapshot
        }
    }
}
