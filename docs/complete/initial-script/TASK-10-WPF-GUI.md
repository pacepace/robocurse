# Task 10: WPF GUI Implementation

## Overview
Implement the WPF graphical user interface with embedded XAML, data binding, tooltips, and real-time progress updates.

## Research Required

### Web Research
- WPF in PowerShell with embedded XAML
- `System.Windows.Markup.XamlReader`
- `Dispatcher.Invoke` for thread-safe UI updates
- WPF data binding basics
- DispatcherTimer for periodic updates

### Key Concepts
- **XAML**: XML markup for WPF UI
- **Dispatcher**: Thread synchronization for UI
- **DataBinding**: Automatic UI updates from data changes
- **Timer**: Periodic progress polling

## Task Description

This is a large task. Consider breaking into sub-tasks if needed.

### GUI Structure Overview
```
┌─ Main Window ────────────────────────────────────────────────────┐
│ ┌─ Menu Bar ─────────────────────────────────────────────────┐   │
│ │ File | Settings | Help                                      │   │
│ └─────────────────────────────────────────────────────────────┘   │
│ ┌─ Left Panel (Profiles) ──┐ ┌─ Right Panel (Details) ───────┐   │
│ │ [✓] User Dirs            │ │ Name: [________________]       │   │
│ │ [✓] Software             │ │ Source: [___________][Browse] │   │
│ │ [ ] Archive (disabled)   │ │ Dest:   [___________][Browse] │   │
│ │                          │ │ [✓] VSS  Mode: [Smart ▼]      │   │
│ │ [Add] [Remove]           │ │ Chunk: Size[__] Files[__]     │   │
│ └──────────────────────────┘ └────────────────────────────────┘   │
│ ┌─ Control Bar ───────────────────────────────────────────────┐   │
│ │ Workers: [====] [Run All] [Run Selected] [Stop] [Schedule]  │   │
│ └─────────────────────────────────────────────────────────────┘   │
│ ┌─ Progress Area ─────────────────────────────────────────────┐   │
│ │ ┌─ DataGrid (Chunks) ───────────────────────────────────┐   │   │
│ │ │ Path | Status | Progress | Speed                       │   │   │
│ │ │ ...                                                    │   │   │
│ │ └────────────────────────────────────────────────────────┘   │   │
│ │ Profile: [████████░░] 80%    Overall: [████░░░░] 40%        │   │
│ │ ETA: 01:23:45 | Speed: 150 MB/s | Chunks: 80/100            │   │
│ └─────────────────────────────────────────────────────────────┘   │
│ ┌─ Log Panel ─────────────────────────────────────────────────┐   │
│ │ [14:32:45] Starting profile "User Directories"...           │   │
│ │ [14:32:46] Scanning source directory...                     │   │
│ └─────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────────┘
```

### Main XAML Definition
```powershell
$script:MainWindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Robocurse - Multi-Share Replication"
        Height="800" Width="1100"
        WindowStartupLocation="CenterScreen"
        Background="#1E1E1E">

    <Window.Resources>
        <!-- Dark Theme Styles -->
        <Style x:Key="DarkLabel" TargetType="Label">
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
        </Style>

        <Style x:Key="DarkTextBox" TargetType="TextBox">
            <Setter Property="Background" Value="#2D2D2D"/>
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="BorderBrush" Value="#3E3E3E"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="CaretBrush" Value="#E0E0E0"/>
        </Style>

        <Style x:Key="DarkButton" TargetType="Button">
            <Setter Property="Background" Value="#0078D4"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#1084D8"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#4A4A4A"/>
                    <Setter Property="Foreground" Value="#808080"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="StopButton" TargetType="Button" BasedOn="{StaticResource DarkButton}">
            <Setter Property="Background" Value="#D32F2F"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#E53935"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="DarkCheckBox" TargetType="CheckBox">
            <Setter Property="Foreground" Value="#E0E0E0"/>
        </Style>

        <Style x:Key="DarkListBox" TargetType="ListBox">
            <Setter Property="Background" Value="#2D2D2D"/>
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="BorderBrush" Value="#3E3E3E"/>
        </Style>
    </Window.Resources>

    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="120"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
            <TextBlock Text="ROBOCURSE" FontSize="28" FontWeight="Bold" Foreground="#0078D4"/>
            <TextBlock Text=" | Multi-Share Replication" FontSize="14" Foreground="#808080"
                       VerticalAlignment="Bottom" Margin="0,0,0,4"/>
        </StackPanel>

        <!-- Profile and Settings Panel -->
        <Grid Grid.Row="1" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="250"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- Profile List -->
            <Border Grid.Column="0" Background="#252525" CornerRadius="4" Margin="0,0,10,0" Padding="10">
                <DockPanel>
                    <Label DockPanel.Dock="Top" Content="Sync Profiles" Style="{StaticResource DarkLabel}" FontWeight="Bold"/>
                    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0">
                        <Button x:Name="btnAddProfile" Content="+ Add" Style="{StaticResource DarkButton}" Width="70" Margin="0,0,5,0"
                                ToolTip="Add a new sync profile for a source/destination pair"/>
                        <Button x:Name="btnRemoveProfile" Content="Remove" Style="{StaticResource DarkButton}" Width="70"
                                ToolTip="Remove the selected sync profile"/>
                    </StackPanel>
                    <ListBox x:Name="lstProfiles" Style="{StaticResource DarkListBox}" Margin="0,5,0,0"
                             ToolTip="List of configured sync profiles. Check to enable, uncheck to disable.">
                        <ListBox.ItemTemplate>
                            <DataTemplate>
                                <CheckBox IsChecked="{Binding Enabled}" Content="{Binding Name}"
                                          Style="{StaticResource DarkCheckBox}"/>
                            </DataTemplate>
                        </ListBox.ItemTemplate>
                    </ListBox>
                </DockPanel>
            </Border>

            <!-- Selected Profile Settings -->
            <Border Grid.Column="1" Background="#252525" CornerRadius="4" Padding="15">
                <Grid x:Name="pnlProfileSettings">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="100"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="80"/>
                    </Grid.ColumnDefinitions>

                    <Label Grid.Row="0" Content="Name:" Style="{StaticResource DarkLabel}"/>
                    <TextBox Grid.Row="0" Grid.Column="1" Grid.ColumnSpan="2" x:Name="txtProfileName"
                             Style="{StaticResource DarkTextBox}" Margin="0,0,0,8"
                             ToolTip="Display name for this sync profile"/>

                    <Label Grid.Row="1" Content="Source:" Style="{StaticResource DarkLabel}"/>
                    <TextBox Grid.Row="1" Grid.Column="1" x:Name="txtSource" Style="{StaticResource DarkTextBox}" Margin="0,0,5,8"
                             ToolTip="The network share or local path to copy FROM.&#x0a;Example: \\fileserver\users$ or D:\SourceData"/>
                    <Button Grid.Row="1" Grid.Column="2" x:Name="btnBrowseSource" Content="Browse"
                            Style="{StaticResource DarkButton}"/>

                    <Label Grid.Row="2" Content="Destination:" Style="{StaticResource DarkLabel}"/>
                    <TextBox Grid.Row="2" Grid.Column="1" x:Name="txtDest" Style="{StaticResource DarkTextBox}" Margin="0,0,5,8"
                             ToolTip="Where files will be copied TO. Directory will be created if needed."/>
                    <Button Grid.Row="2" Grid.Column="2" x:Name="btnBrowseDest" Content="Browse"
                            Style="{StaticResource DarkButton}"/>

                    <StackPanel Grid.Row="3" Grid.ColumnSpan="3" Orientation="Horizontal" Margin="0,5,0,8">
                        <CheckBox x:Name="chkUseVss" Content="Use VSS" Style="{StaticResource DarkCheckBox}" Margin="0,0,20,0"
                                  ToolTip="Create a shadow copy snapshot before syncing.&#x0a;Allows copying locked files (like Outlook PST).&#x0a;Requires admin rights."/>
                        <Label Content="Scan Mode:" Style="{StaticResource DarkLabel}"/>
                        <ComboBox x:Name="cmbScanMode" Width="100" Margin="5,0,0,0"
                                  ToolTip="Smart: Scans and splits based on size (recommended).&#x0a;Quick: Fixed depth split, faster startup.">
                            <ComboBoxItem Content="Smart" IsSelected="True"/>
                            <ComboBoxItem Content="Quick"/>
                        </ComboBox>
                    </StackPanel>

                    <StackPanel Grid.Row="4" Grid.ColumnSpan="3" Orientation="Horizontal">
                        <Label Content="Max Size:" Style="{StaticResource DarkLabel}"/>
                        <TextBox x:Name="txtMaxSize" Width="50" Style="{StaticResource DarkTextBox}" Text="10"
                                 ToolTip="Split directories larger than this (GB).&#x0a;Smaller = more parallel jobs.&#x0a;Recommended: 5-20 GB"/>
                        <Label Content="GB" Style="{StaticResource DarkLabel}" Margin="0,0,15,0"/>

                        <Label Content="Max Files:" Style="{StaticResource DarkLabel}"/>
                        <TextBox x:Name="txtMaxFiles" Width="60" Style="{StaticResource DarkTextBox}" Text="50000"
                                 ToolTip="Split directories with more files than this.&#x0a;Recommended: 20,000-100,000"/>

                        <Label Content="Max Depth:" Style="{StaticResource DarkLabel}" Margin="15,0,0,0"/>
                        <TextBox x:Name="txtMaxDepth" Width="40" Style="{StaticResource DarkTextBox}" Text="5"
                                 ToolTip="How deep to split directories.&#x0a;Higher = more granular but slower scan.&#x0a;Recommended: 3-6"/>
                    </StackPanel>
                </Grid>
            </Border>
        </Grid>

        <!-- Progress Area -->
        <Grid Grid.Row="2">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Control Bar -->
            <Border Grid.Row="0" Background="#252525" CornerRadius="4" Padding="10" Margin="0,0,0,10">
                <StackPanel Orientation="Horizontal">
                    <Label Content="Workers:" Style="{StaticResource DarkLabel}"
                           ToolTip="Number of simultaneous robocopy processes.&#x0a;More = faster but uses more resources.&#x0a;Recommended: 2-8"/>
                    <Slider x:Name="sldWorkers" Width="100" Minimum="1" Maximum="16" Value="4" VerticalAlignment="Center"/>
                    <TextBlock x:Name="txtWorkerCount" Text="4" Foreground="#E0E0E0" Width="25" Margin="5,0,20,0" VerticalAlignment="Center"/>

                    <Button x:Name="btnRunAll" Content="▶ Run All" Style="{StaticResource DarkButton}" Width="100" Margin="0,0,10,0"
                            ToolTip="Start syncing all enabled profiles in sequence"/>
                    <Button x:Name="btnRunSelected" Content="▶ Run Selected" Style="{StaticResource DarkButton}" Width="120" Margin="0,0,10,0"
                            ToolTip="Run only the currently selected profile"/>
                    <Button x:Name="btnStop" Content="⏹ Stop" Style="{StaticResource StopButton}" Width="80" Margin="0,0,10,0" IsEnabled="False"
                            ToolTip="Stop all running robocopy jobs"/>
                    <Button x:Name="btnSchedule" Content="⚙ Schedule" Style="{StaticResource DarkButton}" Width="100"
                            ToolTip="Configure automated scheduled runs"/>
                </StackPanel>
            </Border>

            <!-- Chunk DataGrid -->
            <DataGrid Grid.Row="1" x:Name="dgChunks" AutoGenerateColumns="False"
                      Background="#2D2D2D" Foreground="#E0E0E0" BorderBrush="#3E3E3E"
                      GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#3E3E3E"
                      RowHeaderWidth="0" IsReadOnly="True" SelectionMode="Single">
                <DataGrid.Columns>
                    <DataGridTextColumn Header="ID" Binding="{Binding ChunkId}" Width="50"/>
                    <DataGridTextColumn Header="Path" Binding="{Binding SourcePath}" Width="400"/>
                    <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="100"/>
                    <DataGridTemplateColumn Header="Progress" Width="150">
                        <DataGridTemplateColumn.CellTemplate>
                            <DataTemplate>
                                <ProgressBar Value="{Binding Progress}" Maximum="100" Height="18"
                                             Background="#3E3E3E" Foreground="#4CAF50"/>
                            </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                    </DataGridTemplateColumn>
                    <DataGridTextColumn Header="Speed" Binding="{Binding Speed}" Width="80"/>
                </DataGrid.Columns>
            </DataGrid>

            <!-- Progress Summary -->
            <Border Grid.Row="2" Background="#252525" CornerRadius="4" Padding="10" Margin="0,10,0,0">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="200"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Grid.Column="0">
                        <TextBlock x:Name="txtProfileProgress" Text="Profile: --" Foreground="#E0E0E0" Margin="0,0,0,5"/>
                        <ProgressBar x:Name="pbProfile" Height="20" Background="#3E3E3E" Foreground="#0078D4"/>
                    </StackPanel>

                    <StackPanel Grid.Column="1" Margin="20,0,0,0">
                        <TextBlock x:Name="txtOverallProgress" Text="Overall: --" Foreground="#E0E0E0" Margin="0,0,0,5"/>
                        <ProgressBar x:Name="pbOverall" Height="20" Background="#3E3E3E" Foreground="#4CAF50"/>
                    </StackPanel>

                    <StackPanel Grid.Column="2" Margin="20,0,0,0">
                        <TextBlock x:Name="txtEta" Text="ETA: --:--:--" Foreground="#808080"/>
                        <TextBlock x:Name="txtSpeed" Text="Speed: -- MB/s" Foreground="#808080"/>
                        <TextBlock x:Name="txtChunks" Text="Chunks: 0/0" Foreground="#808080"/>
                    </StackPanel>
                </Grid>
            </Border>
        </Grid>

        <!-- Status Bar -->
        <TextBlock Grid.Row="3" x:Name="txtStatus" Text="Ready" Foreground="#808080" Margin="0,10,0,5"/>

        <!-- Log Panel -->
        <Border Grid.Row="4" Background="#1A1A1A" BorderBrush="#3E3E3E" BorderThickness="1" CornerRadius="4">
            <ScrollViewer x:Name="svLog" VerticalScrollBarVisibility="Auto">
                <TextBlock x:Name="txtLog" Foreground="#808080" FontFamily="Consolas" FontSize="11"
                           Padding="10" TextWrapping="Wrap"/>
            </ScrollViewer>
        </Border>
    </Grid>
</Window>
'@
```

### Function: Initialize-Gui
```powershell
function Initialize-Gui {
    <#
    .SYNOPSIS
        Initializes and displays the WPF GUI
    #>

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    # Parse XAML
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($script:MainWindowXaml))
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    # Get control references
    $script:Controls = @{}
    @(
        'lstProfiles', 'btnAddProfile', 'btnRemoveProfile',
        'txtProfileName', 'txtSource', 'txtDest', 'btnBrowseSource', 'btnBrowseDest',
        'chkUseVss', 'cmbScanMode', 'txtMaxSize', 'txtMaxFiles', 'txtMaxDepth',
        'sldWorkers', 'txtWorkerCount', 'btnRunAll', 'btnRunSelected', 'btnStop', 'btnSchedule',
        'dgChunks', 'pbProfile', 'pbOverall', 'txtProfileProgress', 'txtOverallProgress',
        'txtEta', 'txtSpeed', 'txtChunks', 'txtStatus', 'txtLog', 'svLog'
    ) | ForEach-Object {
        $script:Controls[$_] = $window.FindName($_)
    }

    # Wire up event handlers
    Initialize-EventHandlers -Window $window

    # Load config and populate UI
    $script:Config = Get-RobocurseConfig
    Update-ProfileList

    # Initialize progress timer
    $script:ProgressTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ProgressTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:ProgressTimer.Add_Tick({ Update-GuiProgress })

    return $window
}
```

### Function: Initialize-EventHandlers
```powershell
function Initialize-EventHandlers {
    param([System.Windows.Window]$Window)

    # Profile list selection
    $script:Controls.lstProfiles.Add_SelectionChanged({
        $selected = $script:Controls.lstProfiles.SelectedItem
        if ($selected) {
            Load-ProfileToForm -Profile $selected
        }
    })

    # Add/Remove profile buttons
    $script:Controls.btnAddProfile.Add_Click({ Add-NewProfile })
    $script:Controls.btnRemoveProfile.Add_Click({ Remove-SelectedProfile })

    # Browse buttons
    $script:Controls.btnBrowseSource.Add_Click({
        $path = Show-FolderBrowser -Description "Select source folder"
        if ($path) { $script:Controls.txtSource.Text = $path }
    })
    $script:Controls.btnBrowseDest.Add_Click({
        $path = Show-FolderBrowser -Description "Select destination folder"
        if ($path) { $script:Controls.txtDest.Text = $path }
    })

    # Workers slider
    $script:Controls.sldWorkers.Add_ValueChanged({
        $script:Controls.txtWorkerCount.Text = [int]$script:Controls.sldWorkers.Value
    })

    # Run buttons
    $script:Controls.btnRunAll.Add_Click({ Start-GuiReplication -AllProfiles })
    $script:Controls.btnRunSelected.Add_Click({ Start-GuiReplication -SelectedOnly })
    $script:Controls.btnStop.Add_Click({ Request-Stop })

    # Schedule button
    $script:Controls.btnSchedule.Add_Click({ Show-ScheduleDialog })

    # Form field changes - save to profile
    @('txtProfileName', 'txtSource', 'txtDest', 'txtMaxSize', 'txtMaxFiles', 'txtMaxDepth') | ForEach-Object {
        $script:Controls[$_].Add_LostFocus({ Save-ProfileFromForm })
    }
    $script:Controls.chkUseVss.Add_Checked({ Save-ProfileFromForm })
    $script:Controls.chkUseVss.Add_Unchecked({ Save-ProfileFromForm })
    $script:Controls.cmbScanMode.Add_SelectionChanged({ Save-ProfileFromForm })

    # Window closing
    $Window.Add_Closing({
        if ($script:OrchestrationState.Phase -eq 'Replicating') {
            $result = [System.Windows.MessageBox]::Show(
                "Replication is in progress. Stop and exit?",
                "Confirm Exit",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($result -eq 'No') {
                $_.Cancel = $true
                return
            }
            Stop-AllJobs
        }
        $script:ProgressTimer.Stop()
        Save-RobocurseConfig -Config $script:Config
    })
}
```

### Function: Update-GuiProgress
```powershell
function Update-GuiProgress {
    <#
    .SYNOPSIS
        Called by timer to update GUI from orchestration state
    #>

    $status = Get-OrchestrationStatus

    # Update progress bars
    $script:Controls.pbProfile.Value = $status.ProfileProgress
    $script:Controls.pbOverall.Value = $status.OverallProgress

    # Update text
    $script:Controls.txtProfileProgress.Text = "Profile: $($status.CurrentProfile) - $($status.ProfileProgress)%"
    $script:Controls.txtOverallProgress.Text = "Overall: $($status.OverallProgress)%"
    $script:Controls.txtEta.Text = "ETA: $($status.ETA.ToString('hh\:mm\:ss'))"
    $script:Controls.txtSpeed.Text = "Speed: $(Format-FileSize $status.Speed)/s"
    $script:Controls.txtChunks.Text = "Chunks: $($status.ChunksComplete)/$($status.ChunksTotal)"

    # Refresh DataGrid
    $script:Controls.dgChunks.Items.Refresh()

    # Check if complete
    if ($status.Phase -eq 'Complete') {
        Complete-GuiReplication
    }
}
```

### Function: Write-GuiLog
```powershell
function Write-GuiLog {
    <#
    .SYNOPSIS
        Writes a message to the GUI log panel
    #>
    param([string]$Message)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $Message`n"

    $script:Controls.Window.Dispatcher.Invoke([Action]{
        $script:Controls.txtLog.Text += $line
        $script:Controls.svLog.ScrollToEnd()
    })
}
```

## Success Criteria

1. [ ] Window displays with dark theme
2. [ ] Profile list shows configured profiles
3. [ ] Profile selection populates form fields
4. [ ] Adding/removing profiles works
5. [ ] Browse buttons open folder dialogs
6. [ ] Run buttons start replication
7. [ ] Progress bars update in real-time
8. [ ] DataGrid shows chunk status
9. [ ] Stop button stops replication
10. [ ] Window close saves config
11. [ ] Tooltips display on hover

## Pester Tests

GUI testing is challenging with Pester. Focus on testing:
- Non-GUI helper functions
- Data transformation functions
- Event handler logic (mocked)

```powershell
Describe "GUI Helpers" {
    Context "Format-FileSize" {
        It "Should format bytes correctly" {
            Format-FileSize 1024 | Should -Be "1.00 KB"
            Format-FileSize 1073741824 | Should -Be "1.00 GB"
        }
    }
}
```

## Dependencies
- Task 00 (Project Structure)
- Task 01 (Configuration)
- Task 06 (Orchestration)
- All other tasks for full functionality

## Estimated Complexity
- High
- Large XAML, many event handlers, threading considerations
