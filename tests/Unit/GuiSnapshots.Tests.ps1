BeforeAll {
    # Load required modules/functions
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Utility.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Logging.ps1"

    Mock Write-RobocurseLog {}

    # Mock WPF types
    if (-not ([System.Management.Automation.PSTypeName]'System.Windows.Controls.ComboBoxItem').Type) {
        Add-Type -TypeDefinition @"
namespace System.Windows.Controls {
    public class ComboBoxItem {
        public object Content { get; set; }
        public bool IsSelected { get; set; }
        public ComboBoxItem() { }
    }
}
"@
    }

    # Mock VSS functions
    function Get-VssSnapshots {
        param([string]$Volume)
    }
    function Get-RemoteVssSnapshots {
        param([string]$ServerName, [string]$Volume)
    }

    # Mock script-scope controls
    $script:Controls = @{}
}

Describe "Update-VolumeFilterDropdown" {
    BeforeAll {
        # Create mock ComboBox
        $mockCombo = [PSCustomObject]@{
            Items = [System.Collections.ArrayList]::new()
        }
        Add-Member -InputObject $mockCombo -MemberType ScriptMethod -Name Clear -Value { $this.Items.Clear() }
        $script:Controls['cmbSnapshotVolume'] = $mockCombo

        Mock Get-CimInstance {
            @(
                [PSCustomObject]@{ DriveLetter = "C:" },
                [PSCustomObject]@{ DriveLetter = "D:" }
            )
        } -ParameterFilter { $ClassName -eq 'Win32_Volume' }
    }

    It "Adds 'All Volumes' as first item" {
        . "$PSScriptRoot\..\..\src\Robocurse\Public\GuiSnapshots.ps1"
        Update-VolumeFilterDropdown

        $script:Controls['cmbSnapshotVolume'].Items[0].Content | Should -Be "All Volumes"
    }

    It "Adds detected volumes" {
        . "$PSScriptRoot\..\..\src\Robocurse\Public\GuiSnapshots.ps1"
        Update-VolumeFilterDropdown

        $items = $script:Controls['cmbSnapshotVolume'].Items
        ($items | Where-Object { $_.Content -eq "C:" }) | Should -Not -BeNull
        ($items | Where-Object { $_.Content -eq "D:" }) | Should -Not -BeNull
    }
}

Describe "Update-SnapshotList" {
    BeforeAll {
        # Mock controls
        $mockVolumeCombo = [PSCustomObject]@{
            SelectedItem = [PSCustomObject]@{ Content = "All Volumes" }
        }
        $mockServerCombo = [PSCustomObject]@{
            SelectedItem = [PSCustomObject]@{ Content = "Local" }
        }
        $mockGrid = [PSCustomObject]@{
            ItemsSource = $null
        }
        $mockDeleteBtn = [PSCustomObject]@{
            IsEnabled = $true
        }

        $script:Controls = @{
            'cmbSnapshotVolume' = $mockVolumeCombo
            'cmbSnapshotServer' = $mockServerCombo
            'dgSnapshots' = $mockGrid
            'btnDeleteSnapshot' = $mockDeleteBtn
        }

        Mock Get-VssSnapshots {
            New-OperationResult -Success $true -Data @(
                [PSCustomObject]@{
                    ShadowId = "{test-id}"
                    SourceVolume = "C:"
                    CreatedAt = (Get-Date)
                    ShadowPath = "\\?\GLOBALROOT\..."
                }
            )
        }
    }

    It "Populates grid with snapshots" {
        . "$PSScriptRoot\..\..\src\Robocurse\Public\GuiSnapshots.ps1"
        Update-SnapshotList

        $script:Controls['dgSnapshots'].ItemsSource | Should -Not -BeNullOrEmpty
        $script:Controls['dgSnapshots'].ItemsSource.Count | Should -Be 1
    }

    It "Sets ServerName to 'Local' for local snapshots" {
        . "$PSScriptRoot\..\..\src\Robocurse\Public\GuiSnapshots.ps1"
        Update-SnapshotList

        $script:Controls['dgSnapshots'].ItemsSource[0].ServerName | Should -Be "Local"
    }

    It "Disables delete button after refresh" {
        . "$PSScriptRoot\..\..\src\Robocurse\Public\GuiSnapshots.ps1"
        Update-SnapshotList

        $script:Controls['btnDeleteSnapshot'].IsEnabled | Should -Be $false
    }
}

Describe "Add-RemoteServerToFilter" {
    BeforeAll {
        $mockCombo = [PSCustomObject]@{
            Items = [System.Collections.ArrayList]@(
                [PSCustomObject]@{ Content = "Local" }
            )
        }
        $script:Controls = @{
            'cmbSnapshotServer' = $mockCombo
        }
    }

    It "Adds new server to dropdown" {
        . "$PSScriptRoot\..\..\src\Robocurse\Public\GuiSnapshots.ps1"
        Add-RemoteServerToFilter -ServerName "FileServer01"

        $items = $script:Controls['cmbSnapshotServer'].Items
        ($items | Where-Object { $_.Content -eq "FileServer01" }) | Should -Not -BeNull
    }

    It "Does not add duplicate servers" {
        . "$PSScriptRoot\..\..\src\Robocurse\Public\GuiSnapshots.ps1"
        Add-RemoteServerToFilter -ServerName "FileServer01"
        Add-RemoteServerToFilter -ServerName "FileServer01"

        $count = ($script:Controls['cmbSnapshotServer'].Items | Where-Object { $_.Content -eq "FileServer01" }).Count
        $count | Should -Be 1
    }
}
