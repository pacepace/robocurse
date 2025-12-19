BeforeAll {
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Utility.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Logging.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssCore.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssLocal.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssRemote.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\GuiSnapshots.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\GuiSnapshotDialogs.ps1"

    Mock Write-RobocurseLog {}
}

Describe "Invoke-CreateSnapshotFromDialog" {
    Context "Local snapshot creation" {
        BeforeAll {
            Mock Invoke-VssRetentionPolicy { New-OperationResult -Success $true -Data @{ DeletedCount = 0 } }
            Mock New-VssSnapshot { New-OperationResult -Success $true -Data @{ ShadowId = "{new-snap}" } }
        }

        It "Creates local snapshot without retention" {
            $dialogResult = [PSCustomObject]@{
                Volume = "D:"
                ServerName = "Local"
                EnforceRetention = $false
                KeepCount = 3
            }

            $result = Invoke-CreateSnapshotFromDialog -DialogResult $dialogResult
            $result.Success | Should -Be $true

            Should -Not -Invoke Invoke-VssRetentionPolicy
            Should -Invoke New-VssSnapshot -Times 1
        }

        It "Enforces retention before creating when requested" {
            $dialogResult = [PSCustomObject]@{
                Volume = "D:"
                ServerName = "Local"
                EnforceRetention = $true
                KeepCount = 5
            }

            $result = Invoke-CreateSnapshotFromDialog -DialogResult $dialogResult

            Should -Invoke Invoke-VssRetentionPolicy -Times 1 -ParameterFilter {
                $Volume -eq "D:" -and $KeepCount -eq 5
            }
        }
    }

    Context "Remote snapshot creation" {
        BeforeAll {
            Mock Invoke-RemoteVssRetentionPolicy { New-OperationResult -Success $true }
            Mock New-RemoteVssSnapshot { New-OperationResult -Success $true -Data @{ ShadowId = "{remote-snap}" } }
        }

        It "Uses remote functions for non-local server" {
            $dialogResult = [PSCustomObject]@{
                Volume = "E:"
                ServerName = "FileServer01"
                EnforceRetention = $true
                KeepCount = 3
            }

            $result = Invoke-CreateSnapshotFromDialog -DialogResult $dialogResult
            $result.Success | Should -Be $true

            Should -Invoke Invoke-RemoteVssRetentionPolicy -ParameterFilter {
                $ServerName -eq "FileServer01"
            }
            Should -Invoke New-RemoteVssSnapshot -Times 1
        }
    }
}

Describe "Invoke-DeleteSelectedSnapshot" {
    BeforeAll {
        Mock Get-SelectedSnapshot {
            [PSCustomObject]@{
                ShadowId = "{delete-me}"
                SourceVolume = "C:"
                ServerName = "Local"
                CreatedAt = (Get-Date)
            }
        }
        Mock Show-DeleteSnapshotConfirmation { $true }
        Mock Remove-VssSnapshot { New-OperationResult -Success $true -Data "{delete-me}" }
    }

    It "Deletes snapshot when confirmed" {
        $result = Invoke-DeleteSelectedSnapshot
        $result.Success | Should -Be $true
        Should -Invoke Remove-VssSnapshot -Times 1
    }

    Context "When user cancels" {
        BeforeAll {
            Mock Show-DeleteSnapshotConfirmation { $false }
        }

        It "Returns success without deleting" {
            $result = Invoke-DeleteSelectedSnapshot
            $result.Success | Should -Be $true
            $result.Data | Should -Be "Cancelled"
            Should -Not -Invoke Remove-VssSnapshot
        }
    }

    Context "When no snapshot selected" {
        BeforeAll {
            Mock Get-SelectedSnapshot { $null }
        }

        It "Returns error" {
            $result = Invoke-DeleteSelectedSnapshot
            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Match "No snapshot selected"
        }
    }
}
