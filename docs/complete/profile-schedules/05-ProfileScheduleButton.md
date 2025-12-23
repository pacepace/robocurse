# 05-ProfileScheduleButton

Add Schedule button to profile panel in main window.

## Objective

Add a Schedule button next to the Validate button in the profile settings panel that opens the profile schedule dialog.

## Success Criteria

- [ ] Schedule button added to MainWindow.xaml in correct position
- [ ] Button uses purple ScheduleButton style (already exists)
- [ ] Click handler opens ProfileScheduleDialog for selected profile
- [ ] Button is disabled when no profile is selected
- [ ] Button updates visual state based on schedule status

## Research

### Button Location Reference
- `src\Robocurse\Resources\MainWindow.xaml:~320-330` - Row 4 with Scan combo and Validate button
- Current layout: `[Scan Label] [Scan Combo] [Validate Button]`
- Target layout: `[Scan Label] [Scan Combo] [Schedule Button] [Validate Button]`

### Existing Button Styles
- `MainWindow.xaml:~150-165` - ValidateButton style (teal #17A2B8)
- `MainWindow.xaml:~180-195` - ScheduleButton style (purple #9B59B6) - **USE THIS**

### Event Handler Pattern
- `src\Robocurse\Public\GuiMain.ps1` - Control registration and event handlers
- `src\Robocurse\Public\GuiProfiles.ps1` - Profile-related event handlers

## Implementation

### 1. Add Schedule Button to MainWindow.xaml

Find the row with Scan combo and Validate button (approximately line 320-330). The current structure is:

```xml
<!-- Scan Mode and Validate -->
<TextBlock Grid.Row="4" Grid.Column="0" Text="Scan Mode:" ... />
<ComboBox x:Name="cmbScanMode" Grid.Row="4" Grid.Column="1" ... />
<Button x:Name="btnValidateProfile" Grid.Row="4" Grid.Column="2" Content="Validate" Style="{StaticResource ValidateButton}" ... />
```

Update to add Schedule button (adjust column spans as needed):

```xml
<!-- Scan Mode, Schedule, and Validate -->
<TextBlock Grid.Row="4" Grid.Column="0" Text="Scan Mode:" ... />
<ComboBox x:Name="cmbScanMode" Grid.Row="4" Grid.Column="1" ... />
<StackPanel Grid.Row="4" Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right">
    <Button x:Name="btnProfileSchedule" Content="Schedule" Style="{StaticResource ScheduleButton}"
            Margin="0,0,8,0" ToolTip="Configure scheduled runs for this profile"/>
    <Button x:Name="btnValidateProfile" Content="Validate" Style="{StaticResource ValidateButton}"
            ToolTip="Validate profile settings"/>
</StackPanel>
```

### 2. Register Button Control in GuiMain.ps1

In the `Initialize-RobocurseGui` function, find the control registration array and add:

```powershell
'btnProfileSchedule',
```

### 3. Add Click Handler in GuiMain.ps1

In the section where button handlers are wired up (look for `btnValidateProfile.Add_Click`), add:

```powershell
# Profile Schedule button
if ($script:Controls['btnProfileSchedule']) {
    $script:Controls.btnProfileSchedule.Add_Click({
        $selectedProfile = $script:Controls.lstProfiles.SelectedItem
        if ($selectedProfile) {
            # Find the profile object in config
            $profile = $script:Config.SyncProfiles | Where-Object { $_.Name -eq $selectedProfile } | Select-Object -First 1
            if ($profile) {
                $result = Show-ProfileScheduleDialog -Profile $profile
                if ($result) {
                    Write-GuiLog "Profile schedule updated for $($profile.Name)"
                    # Update button visual if schedule is enabled
                    Update-ProfileScheduleButtonState
                }
            }
        }
    })
}
```

### 4. Add Button State Update Function in GuiProfiles.ps1

Add a new function to update the schedule button's visual state:

```powershell
function Update-ProfileScheduleButtonState {
    <#
    .SYNOPSIS
        Updates the Schedule button appearance based on current profile's schedule status
    #>
    [CmdletBinding()]
    param()

    if (-not $script:Controls['btnProfileSchedule']) { return }

    $selectedProfile = $script:Controls.lstProfiles.SelectedItem
    if (-not $selectedProfile) {
        $script:Controls.btnProfileSchedule.IsEnabled = $false
        $script:Controls.btnProfileSchedule.Content = "Schedule"
        return
    }

    $script:Controls.btnProfileSchedule.IsEnabled = $true

    # Find profile and check schedule
    $profile = $script:Config.SyncProfiles | Where-Object { $_.Name -eq $selectedProfile } | Select-Object -First 1
    if ($profile -and $profile.Schedule -and $profile.Schedule.Enabled) {
        # Show schedule is active
        $script:Controls.btnProfileSchedule.Content = "Schedule ✓"
        $script:Controls.btnProfileSchedule.ToolTip = "Schedule enabled: $($profile.Schedule.Frequency) at $($profile.Schedule.Time)"
    } else {
        $script:Controls.btnProfileSchedule.Content = "Schedule"
        $script:Controls.btnProfileSchedule.ToolTip = "Configure scheduled runs for this profile"
    }
}
```

### 5. Call State Update on Profile Selection

In the profile selection handler (in `GuiProfiles.ps1`), add a call to update the button state:

Find `$script:Controls.lstProfiles.Add_SelectionChanged` and add inside the handler:

```powershell
# Update schedule button state
Update-ProfileScheduleButtonState
```

Also update `Update-ProfileSettingsVisibility` to call it:

```powershell
function Update-ProfileSettingsVisibility {
    # ... existing code ...

    # Update schedule button state
    Update-ProfileScheduleButtonState
}
```

## Test Plan

Manual testing:
1. Start GUI with no profiles - Schedule button should be disabled
2. Add a profile - Schedule button should be enabled
3. Click Schedule - dialog should open
4. Enable schedule and save - button should show "Schedule ✓"
5. Disable schedule and save - button should show "Schedule"
6. Switch between profiles - button state should update correctly

## Files to Modify

- `src\Robocurse\Resources\MainWindow.xaml`
  - Add Schedule button in row 4, column 2 (wrap in StackPanel with Validate)

- `src\Robocurse\Public\GuiMain.ps1`
  - Add 'btnProfileSchedule' to control registration
  - Add click handler for Schedule button

- `src\Robocurse\Public\GuiProfiles.ps1`
  - Add `Update-ProfileScheduleButtonState` function
  - Update profile selection handler to call state update

## Verification

```powershell
# Run GUI
.\dist\Robocurse.ps1

# Verify button exists and functions:
# 1. Button visible next to Validate
# 2. Button disabled when no profile selected
# 3. Button opens schedule dialog when clicked
# 4. Button shows checkmark when schedule is enabled

# Run tests
.\scripts\run-tests.ps1
```
