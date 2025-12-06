# Task: Create Navigation Rail XAML Structure

## Objective

Rewrite `MainWindow.xaml` to implement a VS Code-style navigation rail layout. The new design replaces the current monolithic 800x1100 layout with a compact, panel-based design where a thin icon rail on the left switches between content panels.

## Context

Robocurse is a PowerShell-based parallel robocopy orchestrator with a WPF GUI. The current GUI displays everything at once (profiles, settings, progress, status) in a large fixed window. This redesign creates a modern navigation pattern where users see only the relevant panel for their current task.

**Current state**: 800x1100 window with all controls visible simultaneously
**Target state**: 650x550 window with 50px icon rail + switchable content panels

## Files to Modify

| File | Action |
|------|--------|
| `src/Robocurse/Resources/MainWindow.xaml` | Complete rewrite |

## Research Required

### In Codebase
1. Read the current `MainWindow.xaml` to understand existing:
   - Style definitions in `Window.Resources` (preserve these)
   - Control names (x:Name attributes) that other code references
   - DataGrid template for custom progress bars
   - Color scheme (#1E1E1E background, #252525 panels, etc.)

2. Read `src/Robocurse/Public/GuiMain.ps1` to identify:
   - Which control names are referenced (lstProfiles, txtSource, dgChunks, etc.)
   - These names must be preserved or mapped to new names

### Web Research (if needed)
- WPF StackPanel with RadioButton-style toggle behavior
- WPF Grid with Visibility toggling for panel switching
- Icon fonts or Unicode characters for rail buttons

## Target Layout Structure

```
┌─────┬────────────────────────────────────────────────┐
│     │                                                │
│ [P] │   Content Area                                 │
│     │   (One of 4 panels visible at a time)         │
│ [S] │                                                │
│     │   Visibility controlled by rail selection     │
│ [R] │                                                │
│     │                                                │
│ [L] │                                                │
│     │                                                │
├─────┴────────────────────────────────────────────────┤
│ [Run All] [Run Selected] [Stop]       Workers: [4]   │
└──────────────────────────────────────────────────────┘

Rail Icons:
[P] = Profiles (📋 or folder icon)
[S] = Settings (⚙️ or gear icon)
[R] = Progress (📊 or chart icon)
[L] = Logs (📜 or document icon)
```

## Implementation Steps

### Step 1: Preserve Window.Resources
Copy all existing style definitions from current MainWindow.xaml:
- DarkLabel, DarkTextBox, DarkButton styles
- RunButton, StopButton, ScheduleButton, LogsButton styles
- DarkCheckBox, DarkListBox styles
- DarkDataGrid, DarkDataGridCell, DarkDataGridRow, DarkDataGridColumnHeader styles

### Step 2: Create New Window Structure
```xml
<Window ...
    Height="550" Width="650"
    MinHeight="400" MinWidth="500"
    WindowStartupLocation="CenterScreen"
    Background="#1E1E1E">

    <Window.Resources>
        <!-- All existing styles -->

        <!-- NEW: Rail button style -->
        <Style x:Key="RailButton" TargetType="RadioButton">
            <!-- Styled like a button but with toggle behavior -->
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>      <!-- Content area -->
            <RowDefinition Height="Auto"/>   <!-- Bottom control bar -->
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="50"/>   <!-- Rail -->
            <ColumnDefinition Width="*"/>    <!-- Content -->
        </Grid.ColumnDefinitions>

        <!-- Navigation Rail -->
        <!-- Content Panels (stacked, visibility toggled) -->
        <!-- Bottom Control Bar -->
    </Grid>
</Window>
```

### Step 3: Create Navigation Rail
The rail should be a vertical stack of RadioButtons styled as icon buttons:

```xml
<Border Grid.Row="0" Grid.Column="0" Background="#252525">
    <StackPanel>
        <RadioButton x:Name="btnNavProfiles"
                     GroupName="NavRail"
                     IsChecked="True"
                     Style="{StaticResource RailButton}"
                     Content="📋"
                     ToolTip="Profiles"/>
        <RadioButton x:Name="btnNavSettings"
                     GroupName="NavRail"
                     Style="{StaticResource RailButton}"
                     Content="⚙️"
                     ToolTip="Settings"/>
        <RadioButton x:Name="btnNavProgress"
                     GroupName="NavRail"
                     Style="{StaticResource RailButton}"
                     Content="📊"
                     ToolTip="Progress"/>
        <RadioButton x:Name="btnNavLogs"
                     GroupName="NavRail"
                     Style="{StaticResource RailButton}"
                     Content="📜"
                     ToolTip="Logs"/>
    </StackPanel>
</Border>
```

### Step 4: Create Rail Button Style
```xml
<Style x:Key="RailButton" TargetType="RadioButton">
    <Setter Property="Width" Value="50"/>
    <Setter Property="Height" Value="50"/>
    <Setter Property="FontSize" Value="20"/>
    <Setter Property="Foreground" Value="#808080"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="RadioButton">
                <Border x:Name="border"
                        Background="{TemplateBinding Background}"
                        BorderThickness="3,0,0,0"
                        BorderBrush="Transparent">
                    <ContentPresenter HorizontalAlignment="Center"
                                      VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsChecked" Value="True">
                        <Setter Property="Background" Value="#3E3E3E"/>
                        <Setter Property="Foreground" Value="#E0E0E0"/>
                        <Setter TargetName="border" Property="BorderBrush" Value="#0078D4"/>
                    </Trigger>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter Property="Background" Value="#2D2D2D"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
```

### Step 5: Create Content Panel Container
Create a Grid that holds all 4 panels, with only one visible at a time:

```xml
<Grid Grid.Row="0" Grid.Column="1">
    <!-- Profiles Panel -->
    <Grid x:Name="panelProfiles" Visibility="Visible">
        <!-- Will contain profile list + editor from current XAML -->
    </Grid>

    <!-- Settings Panel -->
    <Grid x:Name="panelSettings" Visibility="Collapsed">
        <!-- New panel - global settings -->
    </Grid>

    <!-- Progress Panel -->
    <Grid x:Name="panelProgress" Visibility="Collapsed">
        <!-- Will contain progress controls from current XAML -->
    </Grid>

    <!-- Logs Panel -->
    <Grid x:Name="panelLogs" Visibility="Collapsed">
        <!-- Will contain log viewer controls -->
    </Grid>
</Grid>
```

### Step 6: Create Bottom Control Bar
Move control buttons to a fixed bottom bar that spans full width:

```xml
<Border Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2"
        Background="#252525" Padding="10">
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <!-- Run/Stop buttons -->
        <StackPanel Grid.Column="0" Orientation="Horizontal">
            <Button x:Name="btnRunAll" Content="▶ Run All"
                    Style="{StaticResource RunButton}" Width="90" Margin="0,0,5,0"/>
            <Button x:Name="btnRunSelected" Content="▶ Run Sel"
                    Style="{StaticResource RunButton}" Width="90" Margin="0,0,5,0"/>
            <Button x:Name="btnStop" Content="⏹ Stop"
                    Style="{StaticResource StopButton}" Width="90" IsEnabled="False"/>
        </StackPanel>

        <!-- Status text -->
        <TextBlock Grid.Column="1" x:Name="txtStatus" Text="Ready"
                   Foreground="#808080" VerticalAlignment="Center" Margin="15,0"/>

        <!-- Workers slider -->
        <StackPanel Grid.Column="2" Orientation="Horizontal">
            <Label Content="Workers:" Style="{StaticResource DarkLabel}"/>
            <Slider x:Name="sldWorkers" Width="80" Minimum="1" Maximum="16" Value="4"
                    VerticalAlignment="Center"/>
            <TextBlock x:Name="txtWorkerCount" Text="4" Foreground="#E0E0E0"
                       Width="20" VerticalAlignment="Center" Margin="5,0,0,0"/>
        </StackPanel>
    </Grid>
</Border>
```

### Step 7: Stub Out Panel Contents
For this task, create empty placeholder panels. Subsequent tasks will populate them:

**panelProfiles**: Add comment `<!-- Profile list + editor - see task 03 -->`
**panelSettings**: Add comment `<!-- Global settings form - see task 06 -->`
**panelProgress**: Add comment `<!-- Progress display - see task 04 -->`
**panelLogs**: Add comment `<!-- Log viewer - see task 05 -->`

## Control Name Mapping

Preserve these control names for backward compatibility:

| Current Name | Keep/Change | Notes |
|--------------|-------------|-------|
| lstProfiles | Keep | In panelProfiles |
| btnAddProfile | Keep | In panelProfiles |
| btnRemoveProfile | Keep | In panelProfiles |
| txtProfileName | Keep | In panelProfiles |
| txtSource | Keep | In panelProfiles |
| txtDest | Keep | In panelProfiles |
| btnBrowseSource | Keep | In panelProfiles |
| btnBrowseDest | Keep | In panelProfiles |
| chkUseVss | Keep | In panelProfiles |
| cmbScanMode | Keep | In panelProfiles |
| txtMaxSize | Keep | In panelProfiles |
| txtMaxFiles | Keep | In panelProfiles |
| txtMaxDepth | Keep | In panelProfiles |
| dgChunks | Keep | In panelProgress |
| pbProfile | Keep | In panelProgress |
| pbOverall | Keep | In panelProgress |
| txtProfileProgress | Keep | In panelProgress |
| txtOverallProgress | Keep | In panelProgress |
| txtEta | Keep | In panelProgress |
| txtSpeed | Keep | In panelProgress |
| txtChunks | Keep | In panelProgress |
| btnRunAll | Keep | In bottom bar |
| btnRunSelected | Keep | In bottom bar |
| btnStop | Keep | In bottom bar |
| sldWorkers | Keep | In bottom bar |
| txtWorkerCount | Keep | In bottom bar |
| txtStatus | Keep | In bottom bar |
| btnSchedule | Move to Settings | Or keep in bottom bar |
| btnLogs | Remove | Replaced by rail button |

**New control names to add:**
- btnNavProfiles, btnNavSettings, btnNavProgress, btnNavLogs (rail buttons)
- panelProfiles, panelSettings, panelProgress, panelLogs (content panels)

## Success Criteria

1. **Window opens** at 650x550 with dark theme
2. **Navigation rail visible** on left side with 4 icon buttons
3. **Rail buttons toggle** - clicking one shows different panel
4. **Only one panel visible** at a time (Visibility="Visible" vs "Collapsed")
5. **Bottom control bar** shows Run/Stop buttons and Workers slider
6. **All existing styles preserved** - colors match current design
7. **No XAML parse errors** - window loads without exceptions

## Testing

1. Build the monolith: `.\build\Build-Robocurse.ps1`
2. Run: `.\dist\Robocurse.ps1`
3. Verify window opens at correct size
4. Click each rail button - verify only one panel shows at a time
5. Verify bottom bar buttons are visible and styled correctly

## Notes

- **Unicode icons**: The emoji icons (📋, ⚙️, 📊, 📜) may not render on all systems. Consider using Segoe MDL2 Assets font or simple text labels as fallback.
- **RadioButton for toggle**: Using RadioButton with GroupName ensures only one can be selected. Style it to look like a button.
- **Panel visibility**: Use Visibility="Collapsed" not "Hidden" - Collapsed doesn't reserve space.
- **WPF in PowerShell quirks**: Some WPF features don't work reliably in PowerShell. Test thoroughly.
