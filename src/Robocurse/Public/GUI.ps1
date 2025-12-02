# Robocurse Gui Functions
# GUI XAML Structure (for maintainability):
# The main window XAML is embedded here as a heredoc to maintain single-file deployment.
# Structure overview:
#   1. Window.Resources    - Styles (DarkLabel, DarkTextBox, DarkButton, etc.) [lines ~5765-5850]
#   2. Main Grid           - Two-row layout (toolbar + main content) [line ~5860]
#   3. Toolbar             - Run/Stop buttons [lines ~5865-5885]
#   4. Main Content Grid   - Three columns (profiles | settings | progress) [line ~5890]
#   5. Profile Panel       - Left sidebar with profile list [lines ~5895-5920]
#   6. Settings Panel      - Center panel with profile editor [lines ~5925-6000]
#   7. Progress Panel      - Right panel with status, chunks, logs [lines ~6005-6060]
#
# To find a specific control, search for its x:Name attribute (e.g., x:Name="lstProfiles")

$script:MainWindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Robocurse - Multi-Share Replication"
        Height="800" Width="1100"
        WindowStartupLocation="CenterScreen"
        Background="#1E1E1E">

    <!-- ==================== RESOURCES: Theme Styles ==================== -->
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

    <!-- ==================== LAYOUT: Main Grid ==================== -->
    <!-- Row 0: Header, Row 1: Profile/Settings, Row 2: Progress, Row 3: Action Buttons, Row 4: Log -->
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="120"/>
        </Grid.RowDefinitions>

        <!-- ==================== ROW 0: Header ==================== -->
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
            <TextBlock Text="ROBOCURSE" FontSize="28" FontWeight="Bold" Foreground="#0078D4"/>
            <TextBlock Text=" | Multi-Share Replication" FontSize="14" Foreground="#808080"
                       VerticalAlignment="Bottom" Margin="0,0,0,4"/>
        </StackPanel>

        <!-- ==================== ROW 1: Profile and Settings Panel ==================== -->
        <Grid Grid.Row="1" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="250"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- ===== COLUMN 0: Profile List Sidebar ===== -->
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

function Get-GuiSettingsPath {
    <#
    .SYNOPSIS
        Gets the path to the GUI settings file
    #>
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
    return Join-Path $scriptDir "Robocurse.settings.json"
}

function Get-GuiState {
    <#
    .SYNOPSIS
        Loads GUI state from settings file
    .OUTPUTS
        PSCustomObject with saved state or $null if not found
    #>
    $settingsPath = Get-GuiSettingsPath
    if (-not (Test-Path $settingsPath)) {
        return $null
    }

    try {
        $json = Get-Content -Path $settingsPath -Raw -ErrorAction Stop
        return $json | ConvertFrom-Json
    }
    catch {
        Write-Verbose "Failed to load GUI settings: $_"
        return $null
    }
}

function Save-GuiState {
    <#
    .SYNOPSIS
        Saves GUI state to settings file
    .PARAMETER Window
        WPF Window object
    .PARAMETER WorkerCount
        Current worker slider value
    .PARAMETER SelectedProfileName
        Name of currently selected profile
    #>
    param(
        [Parameter(Mandatory)]
        [System.Windows.Window]$Window,

        [int]$WorkerCount,

        [string]$SelectedProfileName
    )

    try {
        $state = [PSCustomObject]@{
            WindowLeft = $Window.Left
            WindowTop = $Window.Top
            WindowWidth = $Window.Width
            WindowHeight = $Window.Height
            WindowState = $Window.WindowState.ToString()
            WorkerCount = $WorkerCount
            SelectedProfile = $SelectedProfileName
            SavedAt = [datetime]::Now.ToString('o')
        }

        $settingsPath = Get-GuiSettingsPath
        $state | ConvertTo-Json -Depth 3 | Set-Content -Path $settingsPath -Encoding UTF8 -ErrorAction Stop
        Write-Verbose "GUI state saved to $settingsPath"
    }
    catch {
        Write-Verbose "Failed to save GUI settings: $_"
    }
}

function Restore-GuiState {
    <#
    .SYNOPSIS
        Restores GUI state from settings file
    .PARAMETER Window
        WPF Window object to restore state to
    #>
    param(
        [Parameter(Mandatory)]
        [System.Windows.Window]$Window
    )

    $state = Get-GuiState
    if ($null -eq $state) {
        return
    }

    try {
        # Restore window position and size (validate bounds are on screen)
        if ($state.WindowLeft -ne $null -and $state.WindowTop -ne $null) {
            # Basic bounds check - ensure window is at least partially visible
            $screenWidth = [System.Windows.SystemParameters]::VirtualScreenWidth
            $screenHeight = [System.Windows.SystemParameters]::VirtualScreenHeight

            if ($state.WindowLeft -ge -100 -and $state.WindowLeft -lt $screenWidth -and
                $state.WindowTop -ge -100 -and $state.WindowTop -lt $screenHeight) {
                $Window.Left = $state.WindowLeft
                $Window.Top = $state.WindowTop
            }
        }

        if ($state.WindowWidth -gt 0 -and $state.WindowHeight -gt 0) {
            $Window.Width = $state.WindowWidth
            $Window.Height = $state.WindowHeight
        }

        # Restore window state (but not Minimized - that would be annoying)
        if ($state.WindowState -eq 'Maximized') {
            $Window.WindowState = [System.Windows.WindowState]::Maximized
        }

        # Restore worker count
        if ($state.WorkerCount -gt 0 -and $script:Controls.sldWorkers) {
            $script:Controls.sldWorkers.Value = [math]::Min($state.WorkerCount, $script:Controls.sldWorkers.Maximum)
        }

        # Restore selected profile (after profile list is populated)
        if ($state.SelectedProfile -and $script:Controls.lstProfiles) {
            $profileToSelect = $script:Controls.lstProfiles.Items | Where-Object { $_.Name -eq $state.SelectedProfile }
            if ($profileToSelect) {
                $script:Controls.lstProfiles.SelectedItem = $profileToSelect
            }
        }

        Write-Verbose "GUI state restored"
    }
    catch {
        Write-Verbose "Failed to restore GUI settings: $_"
    }
}

function Initialize-RobocurseGui {
    <#
    .SYNOPSIS
        Initializes and displays the WPF GUI
    .DESCRIPTION
        Loads XAML, wires up event handlers, initializes the UI state
        Only works on Windows due to WPF dependency
    .OUTPUTS
        Window object if successful, $null if not supported
    #>

    # Check platform
    if (-not (Test-IsWindowsPlatform)) {
        Write-Warning "WPF GUI is only supported on Windows. Use -Headless mode on other platforms."
        return $null
    }

    try {
        # Load WPF assemblies
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase
    }
    catch {
        Write-Warning "Failed to load WPF assemblies. GUI not available: $_"
        return $null
    }

    try {
        # Parse XAML
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($script:MainWindowXaml))
        $script:Window = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()
    }
    catch {
        Write-Error "Failed to load XAML: $_"
        return $null
    }

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
        $script:Controls[$_] = $script:Window.FindName($_)
    }

    # Wire up event handlers
    Initialize-EventHandlers

    # Load config and populate UI
    $script:Config = Get-RobocurseConfig -Path $ConfigPath
    Update-ProfileList

    # Restore saved GUI state (window position, size, worker count, selected profile)
    Restore-GuiState -Window $script:Window

    # Save GUI state on window close
    $script:Window.Add_Closing({
        $selectedProfile = $script:Controls.lstProfiles.SelectedItem
        $selectedName = if ($selectedProfile) { $selectedProfile.Name } else { $null }
        $workerCount = [int]$script:Controls.sldWorkers.Value

        Save-GuiState -Window $script:Window -WorkerCount $workerCount -SelectedProfileName $selectedName
    })

    # Initialize progress timer
    $script:ProgressTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ProgressTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:ProgressTimer.Add_Tick({ Update-GuiProgress })

    Write-GuiLog "Robocurse GUI initialized"

    return $script:Window
}

function Initialize-EventHandlers {
    <#
    .SYNOPSIS
        Wires up all GUI event handlers
    #>

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
    $script:Window.Add_Closing({ Invoke-WindowClosingHandler -EventArgs $args[1] })
}

function Invoke-WindowClosingHandler {
    <#
    .SYNOPSIS
        Handles the window closing event
    .DESCRIPTION
        Prompts for confirmation if replication is in progress,
        stops jobs if confirmed, cleans up resources, and saves config.
    .PARAMETER EventArgs
        The CancelEventArgs from the Closing event
    #>
    param($EventArgs)

    # Check if replication is running and confirm exit
    if ($script:OrchestrationState -and $script:OrchestrationState.Phase -eq 'Replicating') {
        $result = [System.Windows.MessageBox]::Show(
            "Replication is in progress. Stop and exit?",
            "Confirm Exit",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($result -eq 'No') {
            $EventArgs.Cancel = $true
            return
        }
        Stop-AllJobs
    }

    # Stop the progress timer
    if ($script:ProgressTimer) {
        $script:ProgressTimer.Stop()
    }

    # Clean up background runspace to prevent memory leaks
    Close-ReplicationRunspace

    # Save configuration
    $saveResult = Save-RobocurseConfig -Config $script:Config -Path $ConfigPath
    if (-not $saveResult.Success) {
        Write-GuiLog "Warning: Failed to save config on exit: $($saveResult.ErrorMessage)"
    }
}

function Close-ReplicationRunspace {
    <#
    .SYNOPSIS
        Cleans up the background replication runspace
    .DESCRIPTION
        Safely stops and disposes the PowerShell instance and runspace
        used for background replication. Called during window close
        and when replication completes.
    #>

    if (-not $script:ReplicationPowerShell) { return }

    try {
        # Stop the PowerShell instance if still running
        if ($script:ReplicationHandle -and -not $script:ReplicationHandle.IsCompleted) {
            $script:ReplicationPowerShell.Stop()
        }

        # Close and dispose the runspace
        if ($script:ReplicationPowerShell.Runspace) {
            $script:ReplicationPowerShell.Runspace.Close()
            $script:ReplicationPowerShell.Runspace.Dispose()
        }

        # Dispose the PowerShell instance
        $script:ReplicationPowerShell.Dispose()
    }
    catch {
        # Silently ignore cleanup errors during window close
        Write-Verbose "Runspace cleanup error (ignored): $($_.Exception.Message)"
    }
    finally {
        $script:ReplicationPowerShell = $null
        $script:ReplicationHandle = $null
    }
}

function Update-ProfileList {
    <#
    .SYNOPSIS
        Populates the profile listbox from config
    #>

    $script:Controls.lstProfiles.Items.Clear()

    if ($script:Config.SyncProfiles) {
        foreach ($profile in $script:Config.SyncProfiles) {
            $script:Controls.lstProfiles.Items.Add($profile) | Out-Null
        }
    }

    # Select first profile if available
    if ($script:Controls.lstProfiles.Items.Count -gt 0) {
        $script:Controls.lstProfiles.SelectedIndex = 0
    }
}

function Load-ProfileToForm {
    <#
    .SYNOPSIS
        Loads selected profile data into form fields
    .PARAMETER Profile
        Profile object to load
    #>
    param([PSCustomObject]$Profile)

    $script:Controls.txtProfileName.Text = $Profile.Name
    $script:Controls.txtSource.Text = $Profile.Source
    $script:Controls.txtDest.Text = $Profile.Destination
    $script:Controls.chkUseVss.IsChecked = $Profile.UseVSS

    # Set scan mode
    $scanMode = if ($Profile.ScanMode) { $Profile.ScanMode } else { "Smart" }
    $script:Controls.cmbScanMode.SelectedIndex = if ($scanMode -eq "Quick") { 1 } else { 0 }

    # Load chunk settings
    $script:Controls.txtMaxSize.Text = $Profile.ChunkMaxSizeGB
    $script:Controls.txtMaxFiles.Text = $Profile.ChunkMaxFiles
    $script:Controls.txtMaxDepth.Text = $Profile.ChunkMaxDepth
}

function Save-ProfileFromForm {
    <#
    .SYNOPSIS
        Saves form fields back to selected profile
    #>

    $selected = $script:Controls.lstProfiles.SelectedItem
    if (-not $selected) { return }

    # Update profile object
    $selected.Name = $script:Controls.txtProfileName.Text
    $selected.Source = $script:Controls.txtSource.Text
    $selected.Destination = $script:Controls.txtDest.Text
    $selected.UseVSS = $script:Controls.chkUseVss.IsChecked
    $selected.ScanMode = $script:Controls.cmbScanMode.Text

    # Parse numeric values with validation and bounds checking
    # ChunkMaxSizeGB: valid range 1-1000 GB
    try {
        $value = [int]$script:Controls.txtMaxSize.Text
        $selected.ChunkMaxSizeGB = [Math]::Max(1, [Math]::Min(1000, $value))
        if ($value -ne $selected.ChunkMaxSizeGB) {
            $script:Controls.txtMaxSize.Text = $selected.ChunkMaxSizeGB.ToString()
        }
    } catch {
        $selected.ChunkMaxSizeGB = 10
        $script:Controls.txtMaxSize.Text = "10"
    }

    # ChunkMaxFiles: valid range 1000-10000000
    try {
        $value = [int]$script:Controls.txtMaxFiles.Text
        $selected.ChunkMaxFiles = [Math]::Max(1000, [Math]::Min(10000000, $value))
        if ($value -ne $selected.ChunkMaxFiles) {
            $script:Controls.txtMaxFiles.Text = $selected.ChunkMaxFiles.ToString()
        }
    } catch {
        $selected.ChunkMaxFiles = 50000
        $script:Controls.txtMaxFiles.Text = "50000"
    }

    # ChunkMaxDepth: valid range 1-20
    try {
        $value = [int]$script:Controls.txtMaxDepth.Text
        $selected.ChunkMaxDepth = [Math]::Max(1, [Math]::Min(20, $value))
        if ($value -ne $selected.ChunkMaxDepth) {
            $script:Controls.txtMaxDepth.Text = $selected.ChunkMaxDepth.ToString()
        }
    } catch {
        $selected.ChunkMaxDepth = 5
        $script:Controls.txtMaxDepth.Text = "5"
    }

    # Refresh list display
    $script:Controls.lstProfiles.Items.Refresh()
}

function Add-NewProfile {
    <#
    .SYNOPSIS
        Creates a new profile with defaults
    #>

    $newProfile = [PSCustomObject]@{
        Name = "New Profile"
        Source = ""
        Destination = ""
        Enabled = $true
        UseVSS = $false
        ScanMode = "Smart"
        ChunkMaxSizeGB = 10
        ChunkMaxFiles = 50000
        ChunkMaxDepth = 5
    }

    # Add to config
    if (-not $script:Config.SyncProfiles) {
        $script:Config.SyncProfiles = @()
    }
    $script:Config.SyncProfiles += $newProfile

    # Update UI
    Update-ProfileList
    $script:Controls.lstProfiles.SelectedIndex = $script:Controls.lstProfiles.Items.Count - 1

    Write-GuiLog "New profile created"
}

function Remove-SelectedProfile {
    <#
    .SYNOPSIS
        Removes selected profile with confirmation
    #>

    $selected = $script:Controls.lstProfiles.SelectedItem
    if (-not $selected) {
        [System.Windows.MessageBox]::Show(
            "Please select a profile to remove.",
            "No Selection",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        return
    }

    $result = [System.Windows.MessageBox]::Show(
        "Remove profile '$($selected.Name)'?",
        "Confirm Removal",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )

    if ($result -eq 'Yes') {
        $script:Config.SyncProfiles = @($script:Config.SyncProfiles | Where-Object { $_ -ne $selected })
        Update-ProfileList
        Write-GuiLog "Profile '$($selected.Name)' removed"
    }
}

function Show-FolderBrowser {
    <#
    .SYNOPSIS
        Opens folder browser dialog
    .PARAMETER Description
        Dialog description
    .OUTPUTS
        Selected path or $null
    #>
    param([string]$Description = "Select folder")

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }
    return $null
}

function Get-ProfilesToRun {
    <#
    .SYNOPSIS
        Determines which profiles to run based on selection mode
    .PARAMETER AllProfiles
        Include all enabled profiles
    .PARAMETER SelectedOnly
        Include only the currently selected profile
    .OUTPUTS
        Array of profile objects, or $null if validation fails
    #>
    param(
        [switch]$AllProfiles,
        [switch]$SelectedOnly
    )

    $profilesToRun = @()

    if ($AllProfiles) {
        $profilesToRun = @($script:Config.SyncProfiles | Where-Object { $_.Enabled -eq $true })
        if ($profilesToRun.Count -eq 0) {
            Show-GuiError -Message "No enabled profiles found. Please enable at least one profile."
            return $null
        }
    }
    elseif ($SelectedOnly) {
        $selected = $script:Controls.lstProfiles.SelectedItem
        if (-not $selected) {
            Show-GuiError -Message "No profile selected. Please select a profile to run."
            return $null
        }
        $profilesToRun = @($selected)
    }

    # Validate profiles have required paths
    foreach ($profile in $profilesToRun) {
        if ([string]::IsNullOrWhiteSpace($profile.Source) -or [string]::IsNullOrWhiteSpace($profile.Destination)) {
            Show-GuiError -Message "Profile '$($profile.Name)' has invalid source or destination paths."
            return $null
        }
    }

    return $profilesToRun
}

function New-ReplicationRunspace {
    <#
    .SYNOPSIS
        Creates and configures a background runspace for replication
    .PARAMETER Profiles
        Array of profiles to run
    .PARAMETER MaxWorkers
        Maximum concurrent robocopy jobs
    .OUTPUTS
        PSCustomObject with PowerShell, Handle, and Runspace properties
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject[]]$Profiles,

        [Parameter(Mandatory)]
        [int]$MaxWorkers
    )

    # Get the path to this script for dot-sourcing into the runspace
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = Join-Path (Get-Location) "Robocurse.ps1"
    }

    $runspace = [runspacefactory]::CreateRunspace()
    # Use MTA for background I/O work (STA is only needed for COM/UI operations)
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace

    # Build a script that loads the main script and runs replication
    # Note: We pass the C# OrchestrationState object which is inherently thread-safe
    # Callbacks are intentionally NOT shared - GUI uses timer-based polling instead
    $backgroundScript = @"
        param(`$ScriptPath, `$SharedState, `$Profiles, `$MaxWorkers, `$ConfigPath)

        # Load the script to get all functions (with -Help to prevent main execution)
        . `$ScriptPath -Help

        # Use the shared C# OrchestrationState instance (thread-safe by design)
        `$script:OrchestrationState = `$SharedState

        # Clear callbacks - GUI mode uses timer-based polling, not callbacks
        `$script:OnProgress = `$null
        `$script:OnChunkComplete = `$null
        `$script:OnProfileComplete = `$null

        # Start replication with -SkipInitialization since UI thread already initialized
        Start-ReplicationRun -Profiles `$Profiles -MaxConcurrentJobs `$MaxWorkers -SkipInitialization

        # Run the orchestration loop until complete
        while (`$script:OrchestrationState.Phase -notin @('Complete', 'Stopped', 'Idle')) {
            Invoke-ReplicationTick -MaxConcurrentJobs `$MaxWorkers
            Start-Sleep -Milliseconds 250
        }
"@

    $powershell.AddScript($backgroundScript)
    $powershell.AddArgument($scriptPath)
    $powershell.AddArgument($script:OrchestrationState)
    $powershell.AddArgument($Profiles)
    $powershell.AddArgument($MaxWorkers)
    $powershell.AddArgument($ConfigPath)

    $handle = $powershell.BeginInvoke()

    return [PSCustomObject]@{
        PowerShell = $powershell
        Handle = $handle
        Runspace = $runspace
    }
}

function Start-GuiReplication {
    <#
    .SYNOPSIS
        Starts replication from GUI
    .PARAMETER AllProfiles
        Run all enabled profiles
    .PARAMETER SelectedOnly
        Run only selected profile
    #>
    param(
        [switch]$AllProfiles,
        [switch]$SelectedOnly
    )

    # Get and validate profiles
    $profilesToRun = Get-ProfilesToRun -AllProfiles:$AllProfiles -SelectedOnly:$SelectedOnly
    if (-not $profilesToRun) { return }

    # Update UI state for replication mode
    $script:Controls.btnRunAll.IsEnabled = $false
    $script:Controls.btnRunSelected.IsEnabled = $false
    $script:Controls.btnStop.IsEnabled = $true
    $script:Controls.txtStatus.Text = "Replication in progress..."
    $script:LastGuiUpdateState = $null
    $script:Controls.dgChunks.ItemsSource = $null

    Write-GuiLog "Starting replication with $($profilesToRun.Count) profile(s)"

    # Get worker count and start progress timer
    $maxWorkers = [int]$script:Controls.sldWorkers.Value
    $script:ProgressTimer.Start()

    # Initialize orchestration state (must happen before runspace creation)
    Initialize-OrchestrationState

    # Create and start background runspace
    $runspaceInfo = New-ReplicationRunspace -Profiles $profilesToRun -MaxWorkers $maxWorkers

    $script:ReplicationHandle = $runspaceInfo.Handle
    $script:ReplicationPowerShell = $runspaceInfo.PowerShell
    $script:ReplicationRunspace = $runspaceInfo.Runspace
}

function Complete-GuiReplication {
    <#
    .SYNOPSIS
        Called when replication completes
    .DESCRIPTION
        Handles GUI cleanup after replication: stops timer, re-enables buttons,
        disposes of background runspace resources, and shows completion message.
    #>

    # Stop timer
    $script:ProgressTimer.Stop()

    # Dispose of background runspace resources to prevent memory leaks
    if ($script:ReplicationPowerShell) {
        try {
            # End the async invocation if still running
            if ($script:ReplicationHandle -and -not $script:ReplicationHandle.IsCompleted) {
                $script:ReplicationPowerShell.Stop()
            }
            elseif ($script:ReplicationHandle) {
                # Collect any remaining output
                $script:ReplicationPowerShell.EndInvoke($script:ReplicationHandle) | Out-Null
            }

            # Check for errors from the background runspace and surface them
            if ($script:ReplicationPowerShell.HadErrors) {
                Write-GuiLog "Background replication encountered errors:"
                foreach ($err in $script:ReplicationPowerShell.Streams.Error) {
                    $errorLocation = if ($err.InvocationInfo) {
                        "$($err.InvocationInfo.ScriptName):$($err.InvocationInfo.ScriptLineNumber)"
                    } else { "Unknown" }
                    Write-GuiLog "  [$errorLocation] $($err.Exception.Message)"
                }
            }

            # Dispose the runspace
            if ($script:ReplicationPowerShell.Runspace) {
                $script:ReplicationPowerShell.Runspace.Close()
                $script:ReplicationPowerShell.Runspace.Dispose()
            }

            # Dispose the PowerShell instance
            $script:ReplicationPowerShell.Dispose()
        }
        catch {
            Write-GuiLog "Warning: Error disposing runspace: $($_.Exception.Message)"
        }
        finally {
            $script:ReplicationPowerShell = $null
            $script:ReplicationHandle = $null
        }
    }

    # Re-enable buttons
    $script:Controls.btnRunAll.IsEnabled = $true
    $script:Controls.btnRunSelected.IsEnabled = $true
    $script:Controls.btnStop.IsEnabled = $false

    # Update status
    $script:Controls.txtStatus.Text = "Replication complete"

    # Show completion message
    $status = Get-OrchestrationStatus
    $message = "Replication completed!`n`nChunks: $($status.ChunksComplete)/$($status.ChunksTotal)`nFailed: $($status.ChunksFailed)"

    [System.Windows.MessageBox]::Show(
        $message,
        "Replication Complete",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    )

    Write-GuiLog "Replication completed: $($status.ChunksComplete)/$($status.ChunksTotal) chunks, $($status.ChunksFailed) failed"
}

# Cache for GUI progress updates - avoids unnecessary rebuilds
$script:LastGuiUpdateState = $null

function Update-GuiProgressText {
    <#
    .SYNOPSIS
        Updates the progress text labels from status object
    .PARAMETER Status
        Orchestration status object from Get-OrchestrationStatus
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Status
    )

    # Update progress bars
    $script:Controls.pbProfile.Value = $Status.ProfileProgress
    $script:Controls.pbOverall.Value = $Status.OverallProgress

    # Update text labels
    $profileName = if ($Status.CurrentProfile) { $Status.CurrentProfile } else { "--" }
    $script:Controls.txtProfileProgress.Text = "Profile: $profileName - $($Status.ProfileProgress)%"
    $script:Controls.txtOverallProgress.Text = "Overall: $($Status.OverallProgress)%"

    # Update ETA
    $script:Controls.txtEta.Text = if ($Status.ETA) {
        "ETA: $($Status.ETA.ToString('hh\:mm\:ss'))"
    } else {
        "ETA: --:--:--"
    }

    # Update speed (bytes per second from elapsed time)
    $script:Controls.txtSpeed.Text = if ($Status.Elapsed.TotalSeconds -gt 0 -and $Status.BytesComplete -gt 0) {
        $speed = $Status.BytesComplete / $Status.Elapsed.TotalSeconds
        "Speed: $(Format-FileSize $speed)/s"
    } else {
        "Speed: -- MB/s"
    }

    $script:Controls.txtChunks.Text = "Chunks: $($Status.ChunksComplete)/$($Status.ChunksTotal)"
}

function Get-ChunkDisplayItems {
    <#
    .SYNOPSIS
        Builds the chunk display items list for the GUI grid
    .DESCRIPTION
        Creates display objects from active, failed, and completed chunks.
        Limits completed chunks to last 20 to prevent UI lag.
    .PARAMETER MaxCompletedItems
        Maximum number of completed chunks to display (default 20)
    .OUTPUTS
        Array of display objects for DataGrid binding
    #>
    param(
        [int]$MaxCompletedItems = $script:GuiMaxCompletedChunksDisplay
    )

    $chunkDisplayItems = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Add active jobs (typically small - MaxConcurrentJobs)
    foreach ($kvp in $script:OrchestrationState.ActiveJobs.ToArray()) {
        $job = $kvp.Value
        $chunkDisplayItems.Add([PSCustomObject]@{
            ChunkId = $job.Chunk.ChunkId
            SourcePath = $job.Chunk.SourcePath
            Status = "Running"
            Progress = if ($job.Progress) { $job.Progress } else { 0 }
            Speed = "--"
        })
    }

    # Add failed chunks (show all - usually small or indicates problems)
    foreach ($chunk in $script:OrchestrationState.FailedChunks.ToArray()) {
        $chunkDisplayItems.Add([PSCustomObject]@{
            ChunkId = $chunk.ChunkId
            SourcePath = $chunk.SourcePath
            Status = "Failed"
            Progress = 0
            Speed = "--"
        })
    }

    # Add completed chunks - limit to last N to prevent UI lag
    $completedSnapshot = $script:OrchestrationState.CompletedChunks.ToArray()
    $startIndex = [Math]::Max(0, $completedSnapshot.Length - $MaxCompletedItems)
    for ($i = $startIndex; $i -lt $completedSnapshot.Length; $i++) {
        $chunk = $completedSnapshot[$i]
        $chunkDisplayItems.Add([PSCustomObject]@{
            ChunkId = $chunk.ChunkId
            SourcePath = $chunk.SourcePath
            Status = "Complete"
            Progress = 100
            Speed = "--"
        })
    }

    return $chunkDisplayItems.ToArray()
}

function Test-ChunkGridNeedsRebuild {
    <#
    .SYNOPSIS
        Determines if the chunk grid needs to be rebuilt
    .OUTPUTS
        $true if grid needs rebuild, $false otherwise
    #>

    $currentState = @{
        ActiveCount = $script:OrchestrationState.ActiveJobs.Count
        CompletedCount = $script:OrchestrationState.CompletedCount
        FailedCount = $script:OrchestrationState.FailedChunks.Count
    }

    $needsRebuild = $false
    if (-not $script:LastGuiUpdateState) {
        $needsRebuild = $true
    }
    elseif ($script:LastGuiUpdateState.ActiveCount -ne $currentState.ActiveCount -or
            $script:LastGuiUpdateState.CompletedCount -ne $currentState.CompletedCount -or
            $script:LastGuiUpdateState.FailedCount -ne $currentState.FailedCount) {
        $needsRebuild = $true
    }

    if ($needsRebuild) {
        $script:LastGuiUpdateState = $currentState
    }

    return $needsRebuild
}

function Update-GuiProgress {
    <#
    .SYNOPSIS
        Called by timer to update GUI from orchestration state
    .DESCRIPTION
        Optimized for performance with large chunk counts:
        - Only rebuilds display list when chunk counts change
        - Uses efficient ToArray() snapshot for thread-safe iteration
        - Limits displayed items to prevent UI sluggishness
        - Dequeues and displays real-time error messages from background thread
    #>

    try {
        $status = Get-OrchestrationStatus

        # Update progress text (always - lightweight)
        Update-GuiProgressText -Status $status

        # Dequeue and display any pending error messages from background thread
        if ($script:OrchestrationState) {
            $errors = $script:OrchestrationState.DequeueErrors()
            foreach ($err in $errors) {
                Write-GuiLog "[ERROR] $err"
            }
        }

        # Update chunk grid - only when state changes
        if ($script:OrchestrationState -and (Test-ChunkGridNeedsRebuild)) {
            $script:Controls.dgChunks.ItemsSource = Get-ChunkDisplayItems
        }

        # Check if complete
        if ($status.Phase -eq 'Complete') {
            Complete-GuiReplication
        }
    }
    catch {
        Write-GuiLog "Error updating progress: $_"
    }
}

# GUI Log ring buffer (uses $script:GuiLogMaxLines from constants)
$script:GuiLogBuffer = [System.Collections.Generic.List[string]]::new()
$script:GuiLogDirty = $false  # Track if buffer needs to be flushed to UI

function Write-GuiLog {
    <#
    .SYNOPSIS
        Writes a message to the GUI log panel using a ring buffer
    .DESCRIPTION
        Uses a fixed-size ring buffer to prevent O(n²) string concatenation
        performance issues. When the buffer exceeds GuiLogMaxLines, oldest
        entries are removed. This keeps the GUI responsive during long runs.
    .PARAMETER Message
        Message to log
    #>
    param([string]$Message)

    if (-not $script:Controls.txtLog) { return }

    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $Message"

    # Add to ring buffer
    $script:GuiLogBuffer.Add($line)

    # Trim if over limit (remove oldest entries)
    while ($script:GuiLogBuffer.Count -gt $script:GuiLogMaxLines) {
        $script:GuiLogBuffer.RemoveAt(0)
    }

    # Use Dispatcher for thread safety - rebuild text from buffer
    $script:Window.Dispatcher.Invoke([Action]{
        # Join all lines - more efficient than repeated concatenation
        $script:Controls.txtLog.Text = $script:GuiLogBuffer -join "`n"
        $script:Controls.svLog.ScrollToEnd()
    })
}

function Show-GuiError {
    <#
    .SYNOPSIS
        Displays an error message in the GUI
    .PARAMETER Message
        Error message
    .PARAMETER Details
        Detailed error information
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$Details
    )

    $fullMessage = $Message
    if ($Details) {
        $fullMessage += "`n`nDetails: $Details"
    }

    [System.Windows.MessageBox]::Show(
        $fullMessage,
        "Error",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )

    Write-GuiLog "ERROR: $Message"
}

function Show-ScheduleDialog {
    <#
    .SYNOPSIS
        Shows schedule configuration dialog and registers/unregisters the scheduled task
    .DESCRIPTION
        Displays a dialog for configuring scheduled runs. When OK is clicked,
        the configuration is saved AND the Windows Task Scheduler task is
        actually created or removed based on the enabled state.
    #>

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Configure Schedule"
        Height="350" Width="450"
        WindowStartupLocation="CenterScreen"
        Background="#1E1E1E">
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <CheckBox x:Name="chkEnabled" Content="Enable Scheduled Runs" Foreground="#E0E0E0" FontWeight="Bold"/>

        <StackPanel Grid.Row="1" Margin="0,15,0,0">
            <Label Content="Run Time (HH:MM):" Foreground="#E0E0E0"/>
            <TextBox x:Name="txtTime" Background="#2D2D2D" Foreground="#E0E0E0" Padding="5" Text="02:00" Width="100" HorizontalAlignment="Left"/>
        </StackPanel>

        <StackPanel Grid.Row="2" Margin="0,15,0,0">
            <Label Content="Frequency:" Foreground="#E0E0E0"/>
            <ComboBox x:Name="cmbFrequency" Background="#2D2D2D" Foreground="#E0E0E0" Width="150" HorizontalAlignment="Left">
                <ComboBoxItem Content="Daily" IsSelected="True"/>
                <ComboBoxItem Content="Weekdays"/>
                <ComboBoxItem Content="Hourly"/>
            </ComboBox>
        </StackPanel>

        <TextBlock Grid.Row="3" x:Name="txtStatus" Foreground="#808080" Margin="0,15,0,0" TextWrapping="Wrap"/>

        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnOk" Content="Apply" Width="80" Margin="0,0,10,0" Background="#0078D4" Foreground="White" Padding="10,5"/>
            <Button x:Name="btnCancel" Content="Cancel" Width="80" Background="#4A4A4A" Foreground="White" Padding="10,5"/>
        </StackPanel>
    </Grid>
</Window>
'@

    try {
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()

        # Get controls
        $chkEnabled = $dialog.FindName("chkEnabled")
        $txtTime = $dialog.FindName("txtTime")
        $cmbFrequency = $dialog.FindName("cmbFrequency")
        $txtStatus = $dialog.FindName("txtStatus")
        $btnOk = $dialog.FindName("btnOk")
        $btnCancel = $dialog.FindName("btnCancel")

        # Load current settings
        $chkEnabled.IsChecked = $script:Config.Schedule.Enabled
        $txtTime.Text = if ($script:Config.Schedule.Time) { $script:Config.Schedule.Time } else { "02:00" }

        # Add real-time time validation with visual feedback
        $txtTime.Add_TextChanged({
            param($sender, $e)
            $isValid = $false
            $text = $sender.Text
            if ($text -match '^([01]?\d|2[0-3]):([0-5]\d)$') {
                $isValid = $true
            }
            if ($isValid) {
                $sender.BorderBrush = [System.Windows.Media.Brushes]::Gray
                $sender.ToolTip = "Time in 24-hour format (HH:MM)"
            } else {
                $sender.BorderBrush = [System.Windows.Media.Brushes]::Red
                $sender.ToolTip = "Invalid format. Use HH:MM (24-hour, e.g., 02:00, 14:30)"
            }
        })

        # Check current task status
        $taskExists = Test-RobocurseTaskExists
        if ($taskExists) {
            $taskInfo = Get-RobocurseTaskStatus
            if ($taskInfo) {
                $txtStatus.Text = "Current task status: $($taskInfo.State)`nNext run: $($taskInfo.NextRunTime)"
            }
        }
        else {
            $txtStatus.Text = "No scheduled task currently configured."
        }

        # Button handlers
        $btnOk.Add_Click({
            try {
                # Parse time
                $timeParts = $txtTime.Text -split ':'
                if ($timeParts.Count -ne 2) {
                    [System.Windows.MessageBox]::Show("Invalid time format. Use HH:MM", "Error", "OK", "Error")
                    return
                }
                $hour = [int]$timeParts[0]
                $minute = [int]$timeParts[1]

                if ($hour -lt 0 -or $hour -gt 23 -or $minute -lt 0 -or $minute -gt 59) {
                    [System.Windows.MessageBox]::Show("Invalid time. Hour must be 0-23, minute must be 0-59", "Error", "OK", "Error")
                    return
                }

                # Determine schedule type
                $scheduleType = switch ($cmbFrequency.Text) {
                    "Daily" { "Daily" }
                    "Weekdays" { "Weekdays" }
                    "Hourly" { "Hourly" }
                    default { "Daily" }
                }

                # Update config
                $script:Config.Schedule.Enabled = $chkEnabled.IsChecked
                $script:Config.Schedule.Time = $txtTime.Text
                $script:Config.Schedule.ScheduleType = $scheduleType

                if ($chkEnabled.IsChecked) {
                    # Register/update the task
                    Write-GuiLog "Registering scheduled task..."

                    $result = Register-RobocurseTask `
                        -ConfigPath $ConfigPath `
                        -Schedule $scheduleType `
                        -Time "$($hour.ToString('00')):$($minute.ToString('00'))"

                    if ($result.Success) {
                        Write-GuiLog "Scheduled task registered successfully"
                        [System.Windows.MessageBox]::Show(
                            "Scheduled task has been registered.`n`nThe task will run $scheduleType at $($txtTime.Text).",
                            "Schedule Configured",
                            "OK",
                            "Information"
                        )
                    }
                    else {
                        Write-GuiLog "Failed to register scheduled task: $($result.ErrorMessage)"
                        [System.Windows.MessageBox]::Show(
                            "Failed to register scheduled task.`n$($result.ErrorMessage)",
                            "Error",
                            "OK",
                            "Error"
                        )
                    }
                }
                else {
                    # Remove the task if it exists
                    if ($taskExists) {
                        Write-GuiLog "Removing scheduled task..."
                        $result = Unregister-RobocurseTask
                        if ($result.Success) {
                            Write-GuiLog "Scheduled task removed"
                            [System.Windows.MessageBox]::Show(
                                "Scheduled task has been removed.",
                                "Schedule Disabled",
                                "OK",
                                "Information"
                            )
                        }
                        else {
                            Write-GuiLog "Failed to remove scheduled task: $($result.ErrorMessage)"
                        }
                    }
                }

                $saveResult = Save-RobocurseConfig -Config $script:Config -Path $ConfigPath
                if (-not $saveResult.Success) {
                    Write-GuiLog "Warning: Failed to save config: $($saveResult.ErrorMessage)"
                }
                $dialog.Close()
            }
            catch {
                [System.Windows.MessageBox]::Show(
                    "Error configuring schedule: $($_.Exception.Message)",
                    "Error",
                    "OK",
                    "Error"
                )
                Write-GuiLog "Error configuring schedule: $($_.Exception.Message)"
            }
        })

        $btnCancel.Add_Click({ $dialog.Close() })

        $dialog.ShowDialog() | Out-Null
    }
    catch {
        Show-GuiError -Message "Failed to show schedule dialog" -Details $_.Exception.Message
    }
}
