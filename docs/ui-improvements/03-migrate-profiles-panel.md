# Task: Migrate Profiles Panel Content

## Objective

Move the profile list and profile editor controls from the old MainWindow.xaml layout into the new `panelProfiles` container. This preserves all existing functionality while fitting the new navigation rail layout.

## Context

The Profiles panel is the primary configuration interface where users manage sync profiles (add, edit, remove) and configure source/destination paths, VSS settings, and chunking options. All existing controls must be preserved with the same `x:Name` attributes so existing PowerShell code continues to work.

## Files to Modify

| File | Action |
|------|--------|
| `src/Robocurse/Resources/MainWindow.xaml` | Populate panelProfiles content |

## Research Required

### In Codebase
1. Read the current `MainWindow.xaml` and extract:
   - Profile list sidebar (lstProfiles, btnAddProfile, btnRemoveProfile)
   - Profile settings form (txtProfileName, txtSource, txtDest, etc.)
   - All control x:Name attributes
   - Layout structure (Grid columns, margins, etc.)

2. Read `src/Robocurse/Public/GuiProfiles.ps1` to understand:
   - Which controls are accessed by name
   - Event handlers that depend on specific control structure

### Current Profile Controls (from MainWindow.xaml)

**Profile List Sidebar:**
```xml
<Border Background="#252525" CornerRadius="4" Padding="10">
    <DockPanel>
        <Label DockPanel.Dock="Top" Content="Sync Profiles" .../>
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal">
            <Button x:Name="btnAddProfile" Content="+ Add" .../>
            <Button x:Name="btnRemoveProfile" Content="Remove" .../>
        </StackPanel>
        <ListBox x:Name="lstProfiles" ...>
            <ListBox.ItemTemplate>
                <DataTemplate>
                    <CheckBox IsChecked="{Binding Enabled}" Content="{Binding Name}" .../>
                </DataTemplate>
            </ListBox.ItemTemplate>
        </ListBox>
    </DockPanel>
</Border>
```

**Profile Editor Form:**
```xml
<Border Background="#252525" CornerRadius="4" Padding="15">
    <Grid x:Name="pnlProfileSettings">
        <!-- Name row -->
        <Label Content="Name:" .../> <TextBox x:Name="txtProfileName" .../>
        <!-- Source row -->
        <Label Content="Source:" .../> <TextBox x:Name="txtSource" .../> <Button x:Name="btnBrowseSource" .../>
        <!-- Destination row -->
        <Label Content="Destination:" .../> <TextBox x:Name="txtDest" .../> <Button x:Name="btnBrowseDest" .../>
        <!-- Options row -->
        <CheckBox x:Name="chkUseVss" .../> <ComboBox x:Name="cmbScanMode" .../>
        <!-- Chunking row -->
        <TextBox x:Name="txtMaxSize" .../> <TextBox x:Name="txtMaxFiles" .../> <TextBox x:Name="txtMaxDepth" .../>
    </Grid>
</Border>
```

## Implementation Steps

### Step 1: Design New Layout for Smaller Window

The new window is 650x550 vs 800x1100. The content area (minus 50px rail) is ~600px wide. Redesign the layout to fit:

**Option A: Stacked (profile list above editor)**
```
┌─────────────────────────────────────┐
│ Sync Profiles         [+Add][Remove]│
│ ┌─────────────────────────────────┐ │
│ │ ☑ Profile1                      │ │
│ │ ☐ Profile2                      │ │
│ │ ☑ Profile3                      │ │
│ └─────────────────────────────────┘ │
├─────────────────────────────────────┤
│ Name:     [________________________]│
│ Source:   [__________________][Brw] │
│ Dest:     [__________________][Brw] │
│ ☑ Use VSS    Scan: [Smart ▼]       │
│ Chunking: [10]GB [50000]files [5]dp │
└─────────────────────────────────────┘
```

**Option B: Side-by-side (narrower list)**
Keeps current layout but with smaller widths.

**Recommended: Option A** - Works better in smaller window.

### Step 2: Implement panelProfiles Content

Replace the placeholder in panelProfiles with actual controls:

```xml
<Grid x:Name="panelProfiles" Visibility="Visible" Margin="10">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>      <!-- Header -->
        <RowDefinition Height="150"/>       <!-- Profile list (fixed height) -->
        <RowDefinition Height="Auto"/>      <!-- Separator -->
        <RowDefinition Height="*"/>         <!-- Profile editor -->
    </Grid.RowDefinitions>

    <!-- Profile List Header -->
    <DockPanel Grid.Row="0" Margin="0,0,0,5">
        <Label Content="Sync Profiles" Style="{StaticResource DarkLabel}"
               FontWeight="Bold" DockPanel.Dock="Left"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnAddProfile" Content="+ Add"
                    Style="{StaticResource DarkButton}" Width="60" Margin="0,0,5,0"
                    ToolTip="Add a new sync profile"/>
            <Button x:Name="btnRemoveProfile" Content="Remove"
                    Style="{StaticResource DarkButton}" Width="60"
                    ToolTip="Remove selected profile"/>
        </StackPanel>
    </DockPanel>

    <!-- Profile List -->
    <Border Grid.Row="1" Background="#252525" CornerRadius="4" Padding="5">
        <ListBox x:Name="lstProfiles" Style="{StaticResource DarkListBox}"
                 ToolTip="Check to enable, uncheck to disable">
            <ListBox.ItemTemplate>
                <DataTemplate>
                    <CheckBox IsChecked="{Binding Enabled}" Content="{Binding Name}"
                              Style="{StaticResource DarkCheckBox}"/>
                </DataTemplate>
            </ListBox.ItemTemplate>
        </ListBox>
    </Border>

    <!-- Separator -->
    <Border Grid.Row="2" Height="1" Background="#3E3E3E" Margin="0,10"/>

    <!-- Profile Editor -->
    <Border Grid.Row="3" Background="#252525" CornerRadius="4" Padding="10">
        <Grid x:Name="pnlProfileSettings">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>  <!-- Name -->
                <RowDefinition Height="Auto"/>  <!-- Source -->
                <RowDefinition Height="Auto"/>  <!-- Destination -->
                <RowDefinition Height="Auto"/>  <!-- Options -->
                <RowDefinition Height="Auto"/>  <!-- Chunking -->
            </Grid.RowDefinitions>
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="80"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="60"/>
            </Grid.ColumnDefinitions>

            <!-- Name -->
            <Label Grid.Row="0" Content="Name:" Style="{StaticResource DarkLabel}"
                   VerticalAlignment="Center"/>
            <TextBox Grid.Row="0" Grid.Column="1" Grid.ColumnSpan="2"
                     x:Name="txtProfileName" Style="{StaticResource DarkTextBox}"
                     Margin="0,0,0,8" ToolTip="Display name for this profile"/>

            <!-- Source -->
            <Label Grid.Row="1" Content="Source:" Style="{StaticResource DarkLabel}"
                   VerticalAlignment="Center"/>
            <TextBox Grid.Row="1" Grid.Column="1" x:Name="txtSource"
                     Style="{StaticResource DarkTextBox}" Margin="0,0,5,8"
                     ToolTip="Network share or local path to copy FROM"/>
            <Button Grid.Row="1" Grid.Column="2" x:Name="btnBrowseSource"
                    Content="..." Style="{StaticResource DarkButton}"
                    Width="50" Margin="0,0,0,8"/>

            <!-- Destination -->
            <Label Grid.Row="2" Content="Dest:" Style="{StaticResource DarkLabel}"
                   VerticalAlignment="Center"/>
            <TextBox Grid.Row="2" Grid.Column="1" x:Name="txtDest"
                     Style="{StaticResource DarkTextBox}" Margin="0,0,5,8"
                     ToolTip="Where files will be copied TO"/>
            <Button Grid.Row="2" Grid.Column="2" x:Name="btnBrowseDest"
                    Content="..." Style="{StaticResource DarkButton}"
                    Width="50" Margin="0,0,0,8"/>

            <!-- Options -->
            <Label Grid.Row="3" Content="Options:" Style="{StaticResource DarkLabel}"
                   VerticalAlignment="Center"/>
            <StackPanel Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="2"
                        Orientation="Horizontal" Margin="0,0,0,8">
                <CheckBox x:Name="chkUseVss" Content="Use VSS"
                          Style="{StaticResource DarkCheckBox}"
                          ToolTip="Create shadow copy for locked files"/>
                <Label Content="Scan:" Style="{StaticResource DarkLabel}" Margin="15,0,0,0"/>
                <ComboBox x:Name="cmbScanMode" Width="80">
                    <ComboBoxItem Content="Smart" IsSelected="True"/>
                    <ComboBoxItem Content="Quick"/>
                </ComboBox>
            </StackPanel>

            <!-- Chunking -->
            <Label Grid.Row="4" Content="Chunking:" Style="{StaticResource DarkLabel}"
                   VerticalAlignment="Center"/>
            <StackPanel Grid.Row="4" Grid.Column="1" Grid.ColumnSpan="2"
                        Orientation="Horizontal">
                <TextBox x:Name="txtMaxSize" Width="40" Style="{StaticResource DarkTextBox}"
                         Text="10" ToolTip="Max GB per chunk"/>
                <Label Content="GB" Style="{StaticResource DarkLabel}"/>
                <TextBox x:Name="txtMaxFiles" Width="50" Style="{StaticResource DarkTextBox}"
                         Text="50000" Margin="10,0,0,0" ToolTip="Max files per chunk"/>
                <Label Content="files" Style="{StaticResource DarkLabel}"/>
                <TextBox x:Name="txtMaxDepth" Width="30" Style="{StaticResource DarkTextBox}"
                         Text="5" Margin="10,0,0,0" ToolTip="Max directory depth"/>
                <Label Content="depth" Style="{StaticResource DarkLabel}"/>
            </StackPanel>
        </Grid>
    </Border>
</Grid>
```

### Step 3: Verify Control Names Match

Cross-reference with GuiProfiles.ps1 to ensure all accessed controls exist:

| Control | Used In | Purpose |
|---------|---------|---------|
| lstProfiles | Update-ProfileList, SelectionChanged | Profile list |
| btnAddProfile | Click handler | Add profile |
| btnRemoveProfile | Click handler | Remove profile |
| txtProfileName | Import-ProfileToForm, Save-ProfileFromForm | Profile name |
| txtSource | Import-ProfileToForm, Save-ProfileFromForm | Source path |
| txtDest | Import-ProfileToForm, Save-ProfileFromForm | Dest path |
| btnBrowseSource | Click handler | Browse dialog |
| btnBrowseDest | Click handler | Browse dialog |
| chkUseVss | Import-ProfileToForm, Save-ProfileFromForm | VSS toggle |
| cmbScanMode | Import-ProfileToForm, Save-ProfileFromForm | Scan mode |
| txtMaxSize | Import-ProfileToForm, Save-ProfileFromForm | Chunk size |
| txtMaxFiles | Import-ProfileToForm, Save-ProfileFromForm | Chunk files |
| txtMaxDepth | Import-ProfileToForm, Save-ProfileFromForm | Chunk depth |
| pnlProfileSettings | Used as container reference | Settings panel |

## Success Criteria

1. **All controls present**: Every x:Name from the original is in panelProfiles
2. **Layout fits**: Content displays correctly in ~600px width
3. **Profile list works**: Can see, select, enable/disable profiles
4. **Profile editor works**: Selecting a profile populates the form
5. **Add/Remove work**: Can add new profiles and remove existing ones
6. **Form saves**: Editing fields and losing focus saves changes
7. **Browse buttons work**: Can browse for source/destination folders
8. **No visual overflow**: Nothing gets cut off or needs scrolling

## Testing

1. Build: `.\build\Build-Robocurse.ps1`
2. Run: `.\dist\Robocurse.ps1`
3. Verify Profiles panel shows by default
4. Add a new profile - verify it appears in list
5. Select a profile - verify form populates
6. Edit fields - verify changes save
7. Enable/disable profiles with checkboxes
8. Remove a profile - verify it's deleted
9. Resize window - verify layout adapts

## Notes

- **Fixed list height**: Using `Height="150"` for profile list ensures it doesn't consume all space. Adjust based on testing.
- **Browse button text**: Changed from "Browse" to "..." to save space.
- **Label width**: Reduced from 100px to 80px to fit smaller window.
- **Keep pnlProfileSettings name**: Some code may reference this Grid by name.
