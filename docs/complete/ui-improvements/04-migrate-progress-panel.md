# Task: Migrate Progress Panel Content

## Objective

Move the progress display controls (progress bars, chunk DataGrid, ETA/speed stats) from the old MainWindow.xaml layout into the new `panelProgress` container. Preserve all existing functionality and control names.

## Context

The Progress panel shows real-time replication status including profile/overall progress bars, the chunk DataGrid with custom progress bars, and statistics (ETA, speed, chunk counts). This is the panel users watch during active replication.

## Files to Modify

| File | Action |
|------|--------|
| `src/Robocurse/Resources/MainWindow.xaml` | Populate panelProgress content |

## Research Required

### In Codebase
1. Read current `MainWindow.xaml` progress area:
   - Progress summary section (pbProfile, pbOverall, txtEta, txtSpeed, txtChunks)
   - Chunk DataGrid with custom progress bar template
   - All control x:Name attributes

2. Read `src/Robocurse/Public/GuiProgress.ps1` to understand:
   - Which controls are updated by the progress timer
   - The custom ScaleTransform progress bar binding
   - Performance optimizations (caching, limiting displayed chunks)

### Current Progress Controls (from MainWindow.xaml)

**Progress Summary:**
```xml
<Border Background="#252525" CornerRadius="4" Padding="10">
    <Grid>
        <StackPanel Grid.Column="0">
            <TextBlock x:Name="txtProfileProgress" Text="Profile: --" .../>
            <ProgressBar x:Name="pbProfile" Height="20" .../>
        </StackPanel>
        <StackPanel Grid.Column="1">
            <TextBlock x:Name="txtOverallProgress" Text="Overall: --" .../>
            <ProgressBar x:Name="pbOverall" Height="20" .../>
        </StackPanel>
        <StackPanel Grid.Column="2">
            <TextBlock x:Name="txtEta" Text="ETA: --:--:--" .../>
            <TextBlock x:Name="txtSpeed" Text="Speed: -- MB/s" .../>
            <TextBlock x:Name="txtChunks" Text="Chunks: 0/0" .../>
        </StackPanel>
    </Grid>
</Border>
```

**Chunk DataGrid:**
```xml
<DataGrid x:Name="dgChunks" AutoGenerateColumns="False" ...>
    <DataGrid.Columns>
        <DataGridTextColumn Header="ID" Binding="{Binding ChunkId}" Width="50"/>
        <DataGridTextColumn Header="Path" Binding="{Binding SourcePath}" Width="400"/>
        <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="100"/>
        <DataGridTemplateColumn Header="Progress" Width="150">
            <!-- Custom progress bar using ScaleTransform -->
        </DataGridTemplateColumn>
        <DataGridTextColumn Header="Speed" Binding="{Binding Speed}" Width="80"/>
    </DataGrid.Columns>
</DataGrid>
```

### Critical: Custom Progress Bar Template

The DataGrid uses a custom progress bar because WPF ProgressBar doesn't render reliably in PowerShell. **This template must be preserved exactly:**

```xml
<DataGridTemplateColumn Header="Progress" Width="150">
    <DataGridTemplateColumn.CellTemplate>
        <DataTemplate>
            <Grid Height="18">
                <!-- Background track -->
                <Border Background="#3E3E3E" CornerRadius="2"/>
                <!-- Progress fill - ScaleX bound to ProgressScale (0.0-1.0) -->
                <Border Background="#4CAF50" CornerRadius="2" HorizontalAlignment="Stretch">
                    <Border.RenderTransform>
                        <ScaleTransform ScaleX="{Binding ProgressScale}" ScaleY="1"/>
                    </Border.RenderTransform>
                    <Border.RenderTransformOrigin>
                        <Point X="0" Y="0.5"/>
                    </Border.RenderTransformOrigin>
                </Border>
                <!-- Percentage text overlay -->
                <TextBlock Text="{Binding Progress, StringFormat={}{0}%}"
                           HorizontalAlignment="Center" VerticalAlignment="Center"
                           Foreground="White" FontWeight="Bold"/>
            </Grid>
        </DataTemplate>
    </DataGridTemplateColumn.CellTemplate>
</DataGridTemplateColumn>
```

## Implementation Steps

### Step 1: Design Layout for Progress Panel

The progress panel should fill available space and prioritize the chunk DataGrid:

```
┌─────────────────────────────────────────────────────┐
│ Profile: DailyBackup - 45%    Overall: 23%          │
│ [████████░░░░░░░░░░░░]        [████░░░░░░░░░░░░░░░] │
│                                                     │
│ ETA: 01:23:45    Speed: 125 MB/s    Chunks: 12/47  │
├─────────────────────────────────────────────────────┤
│ ID │ Path                    │ Status  │ Progress  │
│ 01 │ \\server\share\folder1  │ Running │ ████ 67%  │
│ 02 │ \\server\share\folder2  │ Complete│ ████ 100% │
│ 03 │ \\server\share\folder3  │ Pending │      0%   │
│ ...                                                 │
└─────────────────────────────────────────────────────┘
```

### Step 2: Implement panelProgress Content

```xml
<Grid x:Name="panelProgress" Visibility="Collapsed" Margin="10">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>  <!-- Progress summary -->
        <RowDefinition Height="*"/>     <!-- Chunk DataGrid -->
    </Grid.RowDefinitions>

    <!-- Progress Summary -->
    <Border Grid.Row="0" Background="#252525" CornerRadius="4" Padding="10" Margin="0,0,0,10">
        <Grid>
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <!-- Profile Progress -->
            <StackPanel Grid.Column="0" Margin="0,0,10,0">
                <TextBlock x:Name="txtProfileProgress" Text="Profile: --"
                           Foreground="#E0E0E0" Margin="0,0,0,5"/>
                <ProgressBar x:Name="pbProfile" Height="20"
                             Minimum="0" Maximum="100" Value="0"
                             Background="#1A1A1A" Foreground="#00BFFF"
                             BorderBrush="#555555" BorderThickness="1"/>
            </StackPanel>

            <!-- Overall Progress -->
            <StackPanel Grid.Column="1" Margin="10,0">
                <TextBlock x:Name="txtOverallProgress" Text="Overall: --"
                           Foreground="#E0E0E0" Margin="0,0,0,5"/>
                <ProgressBar x:Name="pbOverall" Height="20"
                             Minimum="0" Maximum="100" Value="0"
                             Background="#1A1A1A" Foreground="#00FF7F"
                             BorderBrush="#555555" BorderThickness="1"/>
            </StackPanel>

            <!-- Stats -->
            <StackPanel Grid.Column="2" Margin="10,0,0,0" MinWidth="120">
                <TextBlock x:Name="txtEta" Text="ETA: --:--:--" Foreground="#808080"/>
                <TextBlock x:Name="txtSpeed" Text="Speed: -- MB/s" Foreground="#808080"/>
                <TextBlock x:Name="txtChunks" Text="Chunks: 0/0" Foreground="#808080"/>
            </StackPanel>
        </Grid>
    </Border>

    <!-- Chunk DataGrid -->
    <DataGrid Grid.Row="1" x:Name="dgChunks" AutoGenerateColumns="False"
              Style="{StaticResource DarkDataGrid}"
              CellStyle="{StaticResource DarkDataGridCell}"
              RowStyle="{StaticResource DarkDataGridRow}"
              ColumnHeaderStyle="{StaticResource DarkDataGridColumnHeader}"
              AlternationCount="2"
              IsReadOnly="True" SelectionMode="Single">
        <DataGrid.Columns>
            <DataGridTextColumn Header="ID" Binding="{Binding ChunkId}" Width="40"/>
            <DataGridTextColumn Header="Path" Binding="{Binding SourcePath}" Width="*"/>
            <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="70"/>
            <DataGridTemplateColumn Header="Progress" Width="120">
                <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                        <Grid Height="18">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <!-- Background track -->
                            <Border Background="#3E3E3E" CornerRadius="2"/>
                            <!-- Progress fill -->
                            <Border Background="#4CAF50" CornerRadius="2"
                                    HorizontalAlignment="Stretch">
                                <Border.RenderTransform>
                                    <ScaleTransform ScaleX="{Binding ProgressScale}" ScaleY="1"/>
                                </Border.RenderTransform>
                                <Border.RenderTransformOrigin>
                                    <Point X="0" Y="0.5"/>
                                </Border.RenderTransformOrigin>
                            </Border>
                            <!-- Percentage text -->
                            <TextBlock Text="{Binding Progress, StringFormat={}{0}%}"
                                       HorizontalAlignment="Center" VerticalAlignment="Center"
                                       Foreground="White" FontWeight="Bold"/>
                        </Grid>
                    </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
            <DataGridTextColumn Header="Speed" Binding="{Binding Speed}" Width="70"/>
        </DataGrid.Columns>
    </DataGrid>
</Grid>
```

### Step 3: Adjust Column Widths for Smaller Window

Original widths (for ~800px):
- Path: 400px
- Progress: 150px

New widths (for ~600px):
- Path: `*` (fills remaining space)
- Progress: 120px
- ID: 40px (down from 50)
- Status: 70px (down from 100)
- Speed: 70px (down from 80)

### Step 4: Verify Control Names

| Control | Purpose |
|---------|---------|
| txtProfileProgress | Current profile name + percentage |
| pbProfile | Profile progress bar (cyan) |
| txtOverallProgress | Overall text |
| pbOverall | Overall progress bar (lime) |
| txtEta | ETA display |
| txtSpeed | Speed display |
| txtChunks | Chunk counter |
| dgChunks | Chunk DataGrid |

## Tests to Write

**File**: `tests/Unit/GuiProgress.Tests.ps1` (update existing)

This task is primarily XAML migration. Ensure existing progress update tests still pass.

### Test: Progress Control Names Preserved

```powershell
Describe 'Progress Panel - Control Names' {
    BeforeAll {
        $xamlPath = Join-Path $PSScriptRoot '..\..\src\Robocurse\Resources\MainWindow.xaml'
        $xamlContent = Get-Content $xamlPath -Raw
        $script:window = [System.Windows.Markup.XamlReader]::Parse($xamlContent)
    }

    # All progress controls must exist with exact same names
    @(
        'txtProfileProgress',
        'pbProfile',
        'txtOverallProgress',
        'pbOverall',
        'txtEta',
        'txtSpeed',
        'txtChunks',
        'dgChunks'
    ) | ForEach-Object {
        It "should preserve control '$_'" {
            $script:window.FindName($_) | Should -Not -BeNullOrEmpty
        }
    }
}
```

### Test: DataGrid Has Required Columns

```powershell
Describe 'Progress Panel - DataGrid Structure' {
    BeforeAll {
        $xamlPath = Join-Path $PSScriptRoot '..\..\src\Robocurse\Resources\MainWindow.xaml'
        $xamlContent = Get-Content $xamlPath -Raw
        $script:window = [System.Windows.Markup.XamlReader]::Parse($xamlContent)
        $script:dgChunks = $script:window.FindName('dgChunks')
    }

    It 'should have dgChunks DataGrid' {
        $script:dgChunks | Should -Not -BeNullOrEmpty
    }

    It 'should have 5 columns' {
        $script:dgChunks.Columns.Count | Should -Be 5
    }

    It 'should have ID column' {
        $script:dgChunks.Columns[0].Header | Should -Be 'ID'
    }

    It 'should have Path column' {
        $script:dgChunks.Columns[1].Header | Should -Be 'Path'
    }

    It 'should have Status column' {
        $script:dgChunks.Columns[2].Header | Should -Be 'Status'
    }

    It 'should have Progress column' {
        $script:dgChunks.Columns[3].Header | Should -Be 'Progress'
    }

    It 'should have Speed column' {
        $script:dgChunks.Columns[4].Header | Should -Be 'Speed'
    }
}
```

### Test: Existing Progress Tests Pass (Regression)

```powershell
Describe 'Progress Panel Migration - Regression Tests' {
    It 'should pass all existing GuiProgress tests' {
        $result = Invoke-Pester -Path 'tests/Unit/GuiProgress.Tests.ps1' -PassThru -Output None
        $result.FailedCount | Should -Be 0
    }
}
```

**Note**: The custom ScaleTransform progress bar is in the XAML template - verify visually that it renders correctly during manual testing.

## Success Criteria

1. **All controls present**: Every progress-related x:Name exists
2. **DataGrid renders**: Chunk grid shows with all columns
3. **Custom progress bars work**: ScaleTransform binding displays correctly
4. **Progress updates**: When replication runs, all indicators update
5. **Layout fits**: No horizontal scrolling needed in normal use
6. **Path column flexible**: Long paths truncate gracefully
7. **Styles applied**: Dark theme colors consistent
8. **Existing tests pass**: All GuiProgress.Tests.ps1 tests still pass

## Testing

1. Build: `.\build\Build-Robocurse.ps1`
2. Run: `.\dist\Robocurse.ps1`
3. Switch to Progress panel (via rail button)
4. Start a replication job
5. Verify progress bars update
6. Verify chunk grid populates with jobs
7. Verify custom progress bars render correctly
8. Verify ETA/speed/chunks update
9. Resize window - verify DataGrid adapts

## Notes

- **ScaleTransform is critical**: Do NOT replace with standard ProgressBar - it won't work in PowerShell.
- **ProgressScale binding**: Data objects must have a `ProgressScale` property (0.0-1.0) in addition to `Progress` (0-100).
- **Performance**: GuiProgress.ps1 limits displayed completed chunks to 20 - this prevents UI lag.
- **Path column**: Using `Width="*"` makes it fill available space and truncate long paths.
