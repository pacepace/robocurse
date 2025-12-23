# 04-ProfileScheduleDialog

Create GUI dialog for configuring profile schedules.

## Objective

Create a XAML dialog and PowerShell handler for configuring per-profile schedules with Hourly/Daily/Weekly/Monthly options.

## Success Criteria

- [ ] XAML dialog created matching app's dark theme
- [ ] All frequency options implemented with appropriate controls
- [ ] Controls show/hide based on frequency selection
- [ ] Time validation with visual feedback
- [ ] Dialog saves schedule to profile and config
- [ ] Dialog creates/removes Windows Task when saved

## Research

### Dialog Pattern Reference
- `src\Robocurse\Resources\ScheduleDialog.xaml` - Existing schedule dialog (global scheduling)
- `src\Robocurse\Public\GuiDialogs.ps1:452-614` - `Show-ScheduleDialog` function pattern
- `src\Robocurse\Resources\ConfirmDialog.xaml` - Dark theme styling reference

### Control Patterns
- Time input with validation: `GuiDialogs.ps1:484-498`
- Combo box for frequency: `GuiDialogs.ps1:474`
- Owner/modal setup: `GuiDialogs.ps1:606-609`

### Schedule Object Structure
```powershell
Schedule = [PSCustomObject]@{
    Enabled = $true
    Frequency = "Daily"      # Hourly, Daily, Weekly, Monthly
    Time = "02:00"           # HH:MM
    Interval = 1             # Hourly: every N hours (1-24)
    DayOfWeek = "Sunday"     # Weekly
    DayOfMonth = 1           # Monthly (1-28)
}
```

## Implementation

### 1. Create XAML Dialog

Create `src\Robocurse\Resources\ProfileScheduleDialog.xaml`:

```xml
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Profile Schedule"
        Height="420" Width="450"
        WindowStartupLocation="CenterOwner"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize">

    <Window.Resources>
        <!-- Standard dark theme button -->
        <Style x:Key="StandardButton" TargetType="Button">
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="#3E3E3E" CornerRadius="4" Padding="20,8">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#4E4E4E"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#2E2E2E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Primary action button (teal) -->
        <Style x:Key="PrimaryButton" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="#17A2B8" CornerRadius="4" Padding="20,8">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#1AB8D0"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#148A9C"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Border x:Name="dialogBorder" Background="#1E1E1E" CornerRadius="8" BorderBrush="#0078D4" BorderThickness="2">
        <Grid Margin="24">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Header -->
            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,20">
                <Border Width="40" Height="40" CornerRadius="20" Background="#9B59B6" Margin="0,0,14,0">
                    <TextBlock Text="&#x1F4C5;" FontSize="20" Foreground="White"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <StackPanel VerticalAlignment="Center">
                    <TextBlock x:Name="txtTitle" Text="Profile Schedule" FontSize="16" FontWeight="SemiBold"
                               Foreground="#E0E0E0"/>
                    <TextBlock x:Name="txtProfileName" Text="" FontSize="11"
                               Foreground="#808080" Margin="0,2,0,0"/>
                </StackPanel>
            </StackPanel>

            <!-- Form Content -->
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                <StackPanel>
                    <!-- Enable checkbox -->
                    <CheckBox x:Name="chkEnabled" Content="Enable scheduled runs" Foreground="#E0E0E0"
                              FontSize="13" Margin="0,0,0,16"/>

                    <!-- Frequency selection -->
                    <TextBlock Text="Frequency:" Foreground="#B0B0B0" FontSize="12" Margin="0,0,0,6"/>
                    <ComboBox x:Name="cmbFrequency" FontSize="13" Padding="8,6" Margin="0,0,0,16">
                        <ComboBoxItem Content="Hourly" IsSelected="False"/>
                        <ComboBoxItem Content="Daily" IsSelected="True"/>
                        <ComboBoxItem Content="Weekly" IsSelected="False"/>
                        <ComboBoxItem Content="Monthly" IsSelected="False"/>
                    </ComboBox>

                    <!-- Time input -->
                    <TextBlock Text="Time (HH:MM, 24-hour format):" Foreground="#B0B0B0" FontSize="12" Margin="0,0,0,6"/>
                    <TextBox x:Name="txtTime" Text="02:00" FontSize="13" Padding="8,6" Margin="0,0,0,16"
                             Background="#2D2D2D" Foreground="#E0E0E0" BorderBrush="#3E3E3E"/>

                    <!-- Hourly: Interval -->
                    <StackPanel x:Name="pnlHourlyOptions" Visibility="Collapsed">
                        <TextBlock Text="Run every N hours:" Foreground="#B0B0B0" FontSize="12" Margin="0,0,0,6"/>
                        <ComboBox x:Name="cmbInterval" FontSize="13" Padding="8,6" Margin="0,0,0,16">
                            <ComboBoxItem Content="1" IsSelected="True"/>
                            <ComboBoxItem Content="2"/>
                            <ComboBoxItem Content="3"/>
                            <ComboBoxItem Content="4"/>
                            <ComboBoxItem Content="6"/>
                            <ComboBoxItem Content="8"/>
                            <ComboBoxItem Content="12"/>
                        </ComboBox>
                    </StackPanel>

                    <!-- Weekly: Day of week -->
                    <StackPanel x:Name="pnlWeeklyOptions" Visibility="Collapsed">
                        <TextBlock Text="Day of week:" Foreground="#B0B0B0" FontSize="12" Margin="0,0,0,6"/>
                        <ComboBox x:Name="cmbDayOfWeek" FontSize="13" Padding="8,6" Margin="0,0,0,16">
                            <ComboBoxItem Content="Sunday" IsSelected="True"/>
                            <ComboBoxItem Content="Monday"/>
                            <ComboBoxItem Content="Tuesday"/>
                            <ComboBoxItem Content="Wednesday"/>
                            <ComboBoxItem Content="Thursday"/>
                            <ComboBoxItem Content="Friday"/>
                            <ComboBoxItem Content="Saturday"/>
                        </ComboBox>
                    </StackPanel>

                    <!-- Monthly: Day of month -->
                    <StackPanel x:Name="pnlMonthlyOptions" Visibility="Collapsed">
                        <TextBlock Text="Day of month (1-28):" Foreground="#B0B0B0" FontSize="12" Margin="0,0,0,6"/>
                        <ComboBox x:Name="cmbDayOfMonth" FontSize="13" Padding="8,6" Margin="0,0,0,16">
                            <!-- Days 1-28 added programmatically -->
                        </ComboBox>
                    </StackPanel>

                    <!-- Task status -->
                    <Border Background="#2D2D2D" CornerRadius="4" Padding="12" Margin="0,8,0,0">
                        <TextBlock x:Name="txtStatus" Text="No schedule configured" FontSize="11"
                                   Foreground="#808080" TextWrapping="Wrap"/>
                    </Border>
                </StackPanel>
            </ScrollViewer>

            <!-- Buttons -->
            <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
                <Button x:Name="btnCancel" Content="Cancel" Style="{StaticResource StandardButton}" Margin="0,0,10,0"/>
                <Button x:Name="btnSave" Content="Save" Style="{StaticResource PrimaryButton}"/>
            </StackPanel>
        </Grid>
    </Border>
</Window>
```

### 2. Add Dialog Function to GuiDialogs.ps1

Add to `src\Robocurse\Public\GuiDialogs.ps1` after `Show-CredentialInputDialog`:

```powershell
function Show-ProfileScheduleDialog {
    <#
    .SYNOPSIS
        Shows profile schedule configuration dialog
    .DESCRIPTION
        Displays a dialog for configuring scheduled runs for a specific profile.
        When saved, updates the profile's Schedule property and creates/removes
        the corresponding Windows Task Scheduler task.
    .PARAMETER Profile
        The profile object to configure scheduling for
    .OUTPUTS
        $true if schedule was saved, $false if cancelled
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile
    )

    try {
        # Load XAML
        $xaml = Get-XamlResource -ResourceName 'ProfileScheduleDialog.xaml'
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()

        # Get controls
        $txtProfileName = $dialog.FindName("txtProfileName")
        $chkEnabled = $dialog.FindName("chkEnabled")
        $cmbFrequency = $dialog.FindName("cmbFrequency")
        $txtTime = $dialog.FindName("txtTime")
        $pnlHourlyOptions = $dialog.FindName("pnlHourlyOptions")
        $pnlWeeklyOptions = $dialog.FindName("pnlWeeklyOptions")
        $pnlMonthlyOptions = $dialog.FindName("pnlMonthlyOptions")
        $cmbInterval = $dialog.FindName("cmbInterval")
        $cmbDayOfWeek = $dialog.FindName("cmbDayOfWeek")
        $cmbDayOfMonth = $dialog.FindName("cmbDayOfMonth")
        $txtStatus = $dialog.FindName("txtStatus")
        $btnSave = $dialog.FindName("btnSave")
        $btnCancel = $dialog.FindName("btnCancel")

        # Set profile name
        $txtProfileName.Text = "Configure schedule for: $($Profile.Name)"

        # Populate day of month dropdown (1-28)
        1..28 | ForEach-Object {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $_.ToString()
            $cmbDayOfMonth.Items.Add($item) | Out-Null
        }
        $cmbDayOfMonth.SelectedIndex = 0

        # Load current settings
        if ($Profile.Schedule) {
            $chkEnabled.IsChecked = $Profile.Schedule.Enabled
            $txtTime.Text = if ($Profile.Schedule.Time) { $Profile.Schedule.Time } else { "02:00" }

            # Set frequency
            $freqIndex = switch ($Profile.Schedule.Frequency) {
                "Hourly" { 0 }
                "Daily" { 1 }
                "Weekly" { 2 }
                "Monthly" { 3 }
                default { 1 }
            }
            $cmbFrequency.SelectedIndex = $freqIndex

            # Set frequency-specific values
            if ($Profile.Schedule.Interval) {
                $intervalIndex = @(1,2,3,4,6,8,12).IndexOf([int]$Profile.Schedule.Interval)
                if ($intervalIndex -ge 0) { $cmbInterval.SelectedIndex = $intervalIndex }
            }
            if ($Profile.Schedule.DayOfWeek) {
                $dayIndex = @("Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday").IndexOf($Profile.Schedule.DayOfWeek)
                if ($dayIndex -ge 0) { $cmbDayOfWeek.SelectedIndex = $dayIndex }
            }
            if ($Profile.Schedule.DayOfMonth) {
                $cmbDayOfMonth.SelectedIndex = [Math]::Max(0, [int]$Profile.Schedule.DayOfMonth - 1)
            }
        }

        # Function to update visible options
        $updateOptions = {
            $frequency = $cmbFrequency.SelectedItem.Content
            $pnlHourlyOptions.Visibility = if ($frequency -eq "Hourly") { 'Visible' } else { 'Collapsed' }
            $pnlWeeklyOptions.Visibility = if ($frequency -eq "Weekly") { 'Visible' } else { 'Collapsed' }
            $pnlMonthlyOptions.Visibility = if ($frequency -eq "Monthly") { 'Visible' } else { 'Collapsed' }
        }

        # Frequency change handler
        $cmbFrequency.Add_SelectionChanged({
            & $updateOptions
        })

        # Initialize visibility
        & $updateOptions

        # Time validation
        $txtTime.Add_TextChanged({
            param($sender, $e)
            $isValid = $sender.Text -match '^([01]?\d|2[0-3]):([0-5]\d)$'
            if ($isValid) {
                $sender.BorderBrush = [System.Windows.Media.Brushes]::Gray
                $sender.ToolTip = "Time in 24-hour format (HH:MM)"
            } else {
                $sender.BorderBrush = [System.Windows.Media.Brushes]::Red
                $sender.ToolTip = "Invalid format. Use HH:MM (24-hour, e.g., 02:00, 14:30)"
            }
        })

        # Check current task status
        $taskInfo = Get-ProfileScheduledTask -ProfileName $Profile.Name
        if ($taskInfo) {
            $nextRun = if ($taskInfo.NextRunTime) { $taskInfo.NextRunTime.ToString("g") } else { "N/A" }
            $txtStatus.Text = "Current task status: $($taskInfo.State)`nNext run: $nextRun"
        } else {
            $txtStatus.Text = "No scheduled task currently configured."
        }

        # Track result
        $script:ProfileScheduleDialogResult = $false

        # Save button
        $btnSave.Add_Click({
            # Validate time
            if ($txtTime.Text -notmatch '^([01]?\d|2[0-3]):([0-5]\d)$') {
                [System.Windows.MessageBox]::Show("Invalid time format. Use HH:MM (24-hour)", "Validation Error", "OK", "Warning")
                return
            }

            try {
                # Build schedule object
                $frequency = $cmbFrequency.SelectedItem.Content
                $newSchedule = [PSCustomObject]@{
                    Enabled = $chkEnabled.IsChecked
                    Frequency = $frequency
                    Time = $txtTime.Text
                    Interval = [int]$cmbInterval.SelectedItem.Content
                    DayOfWeek = $cmbDayOfWeek.SelectedItem.Content
                    DayOfMonth = [int]$cmbDayOfMonth.SelectedItem.Content
                }

                # Update profile
                $Profile.Schedule = $newSchedule

                # Create or remove task
                if ($chkEnabled.IsChecked) {
                    Write-GuiLog "Creating profile schedule for $($Profile.Name)"
                    $result = New-ProfileScheduledTask -Profile $Profile -ConfigPath $script:ConfigPath
                    if ($result.Success) {
                        Write-GuiLog "Profile schedule created: $($result.Data)"
                    } else {
                        Write-GuiLog "Failed to create profile schedule: $($result.ErrorMessage)"
                        [System.Windows.MessageBox]::Show(
                            "Failed to create scheduled task:`n$($result.ErrorMessage)",
                            "Error", "OK", "Error"
                        )
                        return
                    }
                } else {
                    # Remove task if it exists
                    $existingTask = Get-ProfileScheduledTask -ProfileName $Profile.Name
                    if ($existingTask) {
                        Write-GuiLog "Removing profile schedule for $($Profile.Name)"
                        Remove-ProfileScheduledTask -ProfileName $Profile.Name | Out-Null
                    }
                }

                # Save config
                $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
                if (-not $saveResult.Success) {
                    Write-GuiLog "Warning: Failed to save config: $($saveResult.ErrorMessage)"
                }

                $script:ProfileScheduleDialogResult = $true
                $dialog.Close()
            }
            catch {
                Write-GuiLog "Error saving profile schedule: $($_.Exception.Message)"
                [System.Windows.MessageBox]::Show(
                    "Error saving schedule: $($_.Exception.Message)",
                    "Error", "OK", "Error"
                )
            }
        })

        # Cancel button
        $btnCancel.Add_Click({
            $script:ProfileScheduleDialogResult = $false
            $dialog.Close()
        })

        # Dragging
        $dialog.Add_MouseLeftButtonDown({
            param($sender, $e)
            if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
                $dialog.DragMove()
            }
        })

        # Escape to close
        $dialog.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                $script:ProfileScheduleDialogResult = $false
                $dialog.Close()
            }
        })

        # Set owner
        if ($script:Window) {
            $dialog.Owner = $script:Window
        }
        $dialog.ShowDialog() | Out-Null

        return $script:ProfileScheduleDialogResult
    }
    catch {
        Write-GuiLog "Error showing profile schedule dialog: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "Failed to show schedule dialog:`n$($_.Exception.Message)",
            "Error", "OK", "Error"
        )
        return $false
    }
}
```

## Test Plan

See `07-ProfileScheduleGuiTests.md` for GUI test coverage.

Manual testing:
1. Open GUI with profile selected
2. Click Schedule button
3. Verify dialog shows current settings
4. Toggle frequency, verify correct options appear
5. Save with enabled=true, verify task created
6. Save with enabled=false, verify task removed
7. Test time validation (invalid formats should show red border)

## Files to Modify

- Create `src\Robocurse\Resources\ProfileScheduleDialog.xaml` (new file)
- `src\Robocurse\Public\GuiDialogs.ps1` - Add `Show-ProfileScheduleDialog` function

## Verification

```powershell
# Import module
Import-Module .\src\Robocurse\Robocurse.psd1 -Force

# Verify XAML loads
$xaml = Get-XamlResource -ResourceName 'ProfileScheduleDialog.xaml'
$xaml | Should -Not -BeNullOrEmpty

# Verify function exists
Get-Command Show-ProfileScheduleDialog -ErrorAction Stop

# Run GUI and manually test
.\dist\Robocurse.ps1
```
