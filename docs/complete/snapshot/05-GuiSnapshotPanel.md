# Task: GUI Snapshot Panel

## Objective
Add a new "Snapshots" panel to the GUI that displays existing VSS snapshots across all volumes. This panel provides the foundation for snapshot management in the GUI.

## Success Criteria
- [ ] New "Snapshots" navigation item in rail (between Settings and Logs)
- [ ] DataGrid displays snapshots with columns: Volume, Created, Size, Shadow ID
- [ ] Refresh button loads current snapshots
- [ ] Filter dropdown to select volume or show all
- [ ] Panel follows existing dark theme styling
- [ ] Tests verify control binding and data loading

## Research

### Existing GUI Patterns (file:line references)
- `GuiMain.ps1:214-303` - Panel navigation with `Set-ActivePanel`, `Show-Panel`
- `GuiMain.ps1:71-96` - Control reference pattern with `$script:Controls`
- `MainWindow.xaml:10-263` - Dark theme styles: `DarkLabel`, `DarkButton`, `DarkDataGrid`
- `MainWindow.xaml:164-196` - DataGrid with custom cell templates
- `GuiMain.ps1:305-660` - Event handler wiring with `Invoke-SafeEventHandler`

### Navigation Rail Structure (MainWindow.xaml)
```xaml
<StackPanel x:Name="NavRail" ...>
    <RadioButton x:Name="NavProfiles" Content="Profiles" GroupName="NavRail"/>
    <RadioButton x:Name="NavSettings" Content="Settings" GroupName="NavRail"/>
    <RadioButton x:Name="NavProgress" Content="Progress" GroupName="NavRail"/>
    <RadioButton x:Name="NavLogs" Content="Logs" GroupName="NavRail"/>
</StackPanel>
```

### Panel Switching Pattern
```powershell
function Set-ActivePanel {
    param([string]$PanelName)
    # Hide all panels
    @('ProfilesPanel', 'SettingsPanel', 'ProgressPanel', 'LogsPanel') | ForEach-Object {
        $script:Controls[$_].Visibility = [System.Windows.Visibility]::Collapsed
    }
    # Show selected
    $script:Controls["${PanelName}Panel"].Visibility = [System.Windows.Visibility]::Visible
}
```

### DataGrid Styling Example
```xaml
<DataGrid Style="{StaticResource DarkDataGrid}"
          AutoGenerateColumns="False"
          IsReadOnly="True"
          SelectionMode="Single">
    <DataGrid.Columns>
        <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="*"/>
    </DataGrid.Columns>
</DataGrid>
```

## Implementation

### Part 1: XAML Updates

#### File: `src\Robocurse\Resources\MainWindow.xaml`

**Add navigation button (after NavSettings, around line ~310):**

```xaml
<RadioButton x:Name="NavSnapshots" Content="Snapshots" GroupName="NavRail"
             Style="{StaticResource NavButtonStyle}"
             ToolTip="Manage VSS Snapshots (Ctrl+5)"/>
```

**Add Snapshots Panel (after SettingsPanel, before ProgressPanel):**

```xaml
<!-- Snapshots Panel -->
<Grid x:Name="SnapshotsPanel" Visibility="Collapsed">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="10,10,10,5">
        <Label Content="VSS Snapshots" Style="{StaticResource DarkLabel}" FontSize="16" FontWeight="Bold"/>
    </StackPanel>

    <!-- Filter Bar -->
    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="10,5">
        <Label Content="Volume:" Style="{StaticResource DarkLabel}" VerticalAlignment="Center"/>
        <ComboBox x:Name="cmbSnapshotVolume" Width="100" Margin="5,0"
                  Style="{StaticResource DarkComboBox}"
                  ToolTip="Filter by volume">
            <ComboBoxItem Content="All Volumes" IsSelected="True"/>
        </ComboBox>

        <Label Content="Server:" Style="{StaticResource DarkLabel}" VerticalAlignment="Center" Margin="20,0,0,0"/>
        <ComboBox x:Name="cmbSnapshotServer" Width="150" Margin="5,0"
                  Style="{StaticResource DarkComboBox}"
                  ToolTip="Filter by server (local or remote)">
            <ComboBoxItem Content="Local" IsSelected="True"/>
        </ComboBox>

        <Button x:Name="btnRefreshSnapshots" Content="Refresh" Width="80" Margin="20,0,0,0"
                Style="{StaticResource DarkButton}"
                ToolTip="Reload snapshot list"/>
    </StackPanel>

    <!-- Snapshot DataGrid -->
    <DataGrid x:Name="dgSnapshots" Grid.Row="2" Margin="10,5"
              Style="{StaticResource DarkDataGrid}"
              AutoGenerateColumns="False"
              IsReadOnly="True"
              SelectionMode="Single"
              CanUserSortColumns="True"
              CanUserReorderColumns="False">
        <DataGrid.Columns>
            <DataGridTextColumn Header="Volume" Binding="{Binding SourceVolume}" Width="70"/>
            <DataGridTextColumn Header="Created" Binding="{Binding CreatedAt, StringFormat='{}{0:yyyy-MM-dd HH:mm}'}" Width="140"/>
            <DataGridTextColumn Header="Server" Binding="{Binding ServerName}" Width="120"/>
            <DataGridTextColumn Header="Shadow ID" Binding="{Binding ShadowId}" Width="*">
                <DataGridTextColumn.ElementStyle>
                    <Style TargetType="TextBlock">
                        <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
                        <Setter Property="ToolTip" Value="{Binding ShadowId}"/>
                    </Style>
                </DataGridTextColumn.ElementStyle>
            </DataGridTextColumn>
        </DataGrid.Columns>
    </DataGrid>

    <!-- Action Buttons -->
    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="10">
        <Button x:Name="btnCreateSnapshot" Content="Create Snapshot" Width="120"
                Style="{StaticResource RunButton}"
                ToolTip="Create a new VSS snapshot"/>
        <Button x:Name="btnDeleteSnapshot" Content="Delete Selected" Width="120" Margin="10,0,0,0"
                Style="{StaticResource StopButton}"
                IsEnabled="False"
                ToolTip="Delete the selected snapshot"/>
    </StackPanel>
</Grid>
```

### Part 2: GUI Logic

#### File: `src\Robocurse\Public\GuiSnapshots.ps1` (NEW FILE)

```powershell
# Robocurse GUI Snapshot Management
# Handles the Snapshots panel in the GUI

function Initialize-SnapshotsPanel {
    <#
    .SYNOPSIS
        Initializes the Snapshots panel controls and event handlers
    #>
    [CmdletBinding()]
    param()

    # Populate volume filter with local drives
    Update-VolumeFilterDropdown

    # Wire event handlers
    $script:Controls['btnRefreshSnapshots'].Add_Click({
        Invoke-SafeEventHandler -HandlerName "RefreshSnapshots" -ScriptBlock {
            Update-SnapshotList
        }
    })

    $script:Controls['cmbSnapshotVolume'].Add_SelectionChanged({
        Invoke-SafeEventHandler -HandlerName "VolumeFilterChanged" -ScriptBlock {
            Update-SnapshotList
        }
    })

    $script:Controls['cmbSnapshotServer'].Add_SelectionChanged({
        Invoke-SafeEventHandler -HandlerName "ServerFilterChanged" -ScriptBlock {
            Update-SnapshotList
        }
    })

    $script:Controls['dgSnapshots'].Add_SelectionChanged({
        Invoke-SafeEventHandler -HandlerName "SnapshotSelectionChanged" -ScriptBlock {
            $selected = $script:Controls['dgSnapshots'].SelectedItem
            $script:Controls['btnDeleteSnapshot'].IsEnabled = ($null -ne $selected)
        }
    })

    # Initial load
    Update-SnapshotList

    Write-RobocurseLog -Message "Snapshots panel initialized" -Level 'Debug' -Component 'GUI'
}

function Update-VolumeFilterDropdown {
    <#
    .SYNOPSIS
        Populates the volume filter dropdown with available volumes
    #>
    [CmdletBinding()]
    param()

    $combo = $script:Controls['cmbSnapshotVolume']
    $combo.Items.Clear()

    # Add "All Volumes" option
    $allItem = [System.Windows.Controls.ComboBoxItem]::new()
    $allItem.Content = "All Volumes"
    $allItem.IsSelected = $true
    $combo.Items.Add($allItem) | Out-Null

    # Add local volumes
    try {
        $volumes = Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } |
            Sort-Object DriveLetter

        foreach ($vol in $volumes) {
            $item = [System.Windows.Controls.ComboBoxItem]::new()
            $item.Content = $vol.DriveLetter
            $combo.Items.Add($item) | Out-Null
        }
    }
    catch {
        Write-RobocurseLog -Message "Failed to enumerate volumes: $($_.Exception.Message)" -Level 'Warning' -Component 'GUI'
    }
}

function Update-SnapshotList {
    <#
    .SYNOPSIS
        Refreshes the snapshot DataGrid with current snapshots
    #>
    [CmdletBinding()]
    param()

    $grid = $script:Controls['dgSnapshots']

    try {
        # Get filter values
        $volumeFilter = $script:Controls['cmbSnapshotVolume'].SelectedItem.Content
        $serverFilter = $script:Controls['cmbSnapshotServer'].SelectedItem.Content

        Write-RobocurseLog -Message "Loading snapshots (volume: $volumeFilter, server: $serverFilter)" -Level 'Debug' -Component 'GUI'

        $snapshots = @()

        if ($serverFilter -eq "Local") {
            # Get local snapshots
            if ($volumeFilter -eq "All Volumes") {
                $result = Get-VssSnapshots
            }
            else {
                $result = Get-VssSnapshots -Volume $volumeFilter
            }

            if ($result.Success) {
                $snapshots = @($result.Data | ForEach-Object {
                    [PSCustomObject]@{
                        ShadowId     = $_.ShadowId
                        SourceVolume = $_.SourceVolume
                        CreatedAt    = $_.CreatedAt
                        ServerName   = "Local"
                        ShadowPath   = $_.ShadowPath
                    }
                })
            }
            else {
                Write-RobocurseLog -Message "Failed to load snapshots: $($result.ErrorMessage)" -Level 'Warning' -Component 'GUI'
            }
        }
        else {
            # Get remote snapshots
            if ($volumeFilter -eq "All Volumes") {
                $result = Get-RemoteVssSnapshots -ServerName $serverFilter
            }
            else {
                $result = Get-RemoteVssSnapshots -ServerName $serverFilter -Volume $volumeFilter
            }

            if ($result.Success) {
                $snapshots = @($result.Data)
            }
            else {
                Write-RobocurseLog -Message "Failed to load remote snapshots: $($result.ErrorMessage)" -Level 'Warning' -Component 'GUI'
            }
        }

        # Update grid
        $grid.ItemsSource = $snapshots
        $script:Controls['btnDeleteSnapshot'].IsEnabled = $false

        Write-RobocurseLog -Message "Loaded $($snapshots.Count) snapshot(s)" -Level 'Debug' -Component 'GUI'
    }
    catch {
        Write-RobocurseLog -Message "Error updating snapshot list: $($_.Exception.Message)" -Level 'Error' -Component 'GUI'
        $grid.ItemsSource = @()
    }
}

function Add-RemoteServerToFilter {
    <#
    .SYNOPSIS
        Adds a remote server to the server filter dropdown
    .PARAMETER ServerName
        The server name to add
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerName
    )

    $combo = $script:Controls['cmbSnapshotServer']

    # Check if already exists
    $existing = $combo.Items | Where-Object { $_.Content -eq $ServerName }
    if ($existing) {
        return
    }

    $item = [System.Windows.Controls.ComboBoxItem]::new()
    $item.Content = $ServerName
    $combo.Items.Add($item) | Out-Null

    Write-RobocurseLog -Message "Added server '$ServerName' to snapshot filter" -Level 'Debug' -Component 'GUI'
}

function Get-SelectedSnapshot {
    <#
    .SYNOPSIS
        Gets the currently selected snapshot from the DataGrid
    .OUTPUTS
        The selected snapshot object or $null
    #>
    [CmdletBinding()]
    param()

    return $script:Controls['dgSnapshots'].SelectedItem
}
```

### Part 3: Integration into GuiMain.ps1

#### File: `src\Robocurse\Public\GuiMain.ps1`

**Add control references (around line 72-96):**

```powershell
# Add to the control list
'NavSnapshots',
'SnapshotsPanel',
'cmbSnapshotVolume',
'cmbSnapshotServer',
'btnRefreshSnapshots',
'dgSnapshots',
'btnCreateSnapshot',
'btnDeleteSnapshot',
```

**Update Set-ActivePanel (around line 214):**

```powershell
function Set-ActivePanel {
    param([string]$PanelName)
    # Hide all panels
    @('ProfilesPanel', 'SettingsPanel', 'SnapshotsPanel', 'ProgressPanel', 'LogsPanel') | ForEach-Object {
        $script:Controls[$_].Visibility = [System.Windows.Visibility]::Collapsed
    }
    # Show selected
    $script:Controls["${PanelName}Panel"].Visibility = [System.Windows.Visibility]::Visible

    # Refresh snapshot list when panel becomes visible
    if ($PanelName -eq 'Snapshots') {
        Update-SnapshotList
    }
}
```

**Add navigation handler (in Initialize-EventHandlers):**

```powershell
$script:Controls['NavSnapshots'].Add_Checked({
    Invoke-SafeEventHandler -HandlerName "NavSnapshots" -ScriptBlock {
        Set-ActivePanel -PanelName 'Snapshots'
    }
})
```

**Add keyboard shortcut (around line 660):**

```powershell
# In the KeyDown handler
'D5' { $script:Controls['NavSnapshots'].IsChecked = $true }  # Ctrl+5 for Snapshots
```

**Initialize snapshots panel (in main initialization):**

```powershell
# After other panel initializations
Initialize-SnapshotsPanel
```

## Test Plan

### File: `tests\Unit\GuiSnapshots.Tests.ps1`

```powershell
BeforeAll {
    # Load required modules/functions
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Utility.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Logging.ps1"

    Mock Write-RobocurseLog {}

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
```

## Files to Create
- `src\Robocurse\Public\GuiSnapshots.ps1` - Snapshot panel logic
- `tests\Unit\GuiSnapshots.Tests.ps1` - Unit tests

## Files to Modify
- `src\Robocurse\Resources\MainWindow.xaml` - Add navigation and panel XAML
- `src\Robocurse\Public\GuiMain.ps1` - Add control references and event handlers
- `src\Robocurse\Robocurse.psd1` - Add GuiSnapshots.ps1 to module

## Verification
```powershell
# Run unit tests
Invoke-Pester -Path tests\Unit\GuiSnapshots.Tests.ps1 -Output Detailed

# Manual verification
# 1. Launch GUI: .\Robocurse.ps1
# 2. Click "Snapshots" in navigation rail
# 3. Verify DataGrid shows existing snapshots
# 4. Test volume filter dropdown
# 5. Test Ctrl+5 keyboard shortcut
```

## Dependencies
- Task 01 (VssSnapshotCore) - For `Get-VssSnapshots`
- Task 02 (VssSnapshotRemote) - For `Get-RemoteVssSnapshots`

## Notes
- Panel is read-only in this task; create/delete buttons are wired in Task 06
- Server filter starts with "Local" only; remote servers added dynamically
- DataGrid uses virtualization for performance with many snapshots
- Shadow ID column truncates with tooltip for full value
- Keyboard shortcut Ctrl+5 matches existing Ctrl+1-4 pattern
