# Task: Integrate Log Viewer Panel

## Objective

Create an inline log viewer in `panelLogs` that displays real-time log entries with level filtering. Also add a "Pop Out" button that opens the existing log popup window for detached viewing.

## Context

Currently, logs are displayed in a separate popup window (LogWindow.xaml). This task integrates a log viewer into the main window as one of the navigation panels, while keeping the popup available as an option for users who want a detached view.

## Files to Modify

| File | Action |
|------|--------|
| `src/Robocurse/Resources/MainWindow.xaml` | Populate panelLogs content |
| `src/Robocurse/Public/GuiLogWindow.ps1` | Add function to update inline log panel |
| `src/Robocurse/Public/GuiMain.ps1` | Wire log panel controls and Pop Out button |

## Research Required

### In Codebase
1. Read `src/Robocurse/Resources/LogWindow.xaml`:
   - Log display area structure (TextBox or TextBlock?)
   - Level filter checkboxes
   - Auto-scroll checkbox
   - Button controls (Clear, Copy, Save)

2. Read `src/Robocurse/Public/GuiLogWindow.ps1`:
   - `Write-GuiLog` function - how logs are added to the ring buffer
   - `Update-LogWindowContent` - how display is updated
   - Filtering logic
   - Copy/Save functionality

3. Read `src/Robocurse/Public/GuiMain.ps1`:
   - How btnLogs currently opens the popup
   - Ring buffer implementation (`$script:GuiLogBuffer`)

### Current LogWindow Structure

From LogWindow.xaml:
```xml
<!-- Header with filters -->
<CheckBox x:Name="chkDebug" Content="Debug" IsChecked="True"/>
<CheckBox x:Name="chkInfo" Content="Info" IsChecked="True"/>
<CheckBox x:Name="chkWarning" Content="Warning" IsChecked="True"/>
<CheckBox x:Name="chkError" Content="Error" IsChecked="True"/>
<CheckBox x:Name="chkAutoScroll" Content="Auto-scroll" IsChecked="True"/>
<TextBlock x:Name="txtLineCount" Text="Lines: 0"/>

<!-- Log display -->
<TextBox x:Name="txtLogContent" IsReadOnly="True" TextWrapping="NoWrap"
         FontFamily="Consolas" FontSize="12"
         Background="#1E1E1E" Foreground="#E0E0E0"
         VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>

<!-- Buttons -->
<Button x:Name="btnClearLog" Content="Clear Log"/>
<Button x:Name="btnCopyLog" Content="Copy All"/>
<Button x:Name="btnSaveLog" Content="Save to File"/>
```

## Implementation Steps

### Step 1: Create panelLogs Content

```xml
<Grid x:Name="panelLogs" Visibility="Collapsed" Margin="10">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>  <!-- Filter bar -->
        <RowDefinition Height="*"/>     <!-- Log content -->
        <RowDefinition Height="Auto"/>  <!-- Button bar -->
    </Grid.RowDefinitions>

    <!-- Filter Bar -->
    <Border Grid.Row="0" Background="#252525" CornerRadius="4" Padding="10" Margin="0,0,0,10">
        <DockPanel>
            <!-- Level filters (left) -->
            <StackPanel DockPanel.Dock="Left" Orientation="Horizontal">
                <CheckBox x:Name="chkLogDebug" Content="Debug"
                          Style="{StaticResource DarkCheckBox}"
                          IsChecked="True" Margin="0,0,10,0"/>
                <CheckBox x:Name="chkLogInfo" Content="Info"
                          Style="{StaticResource DarkCheckBox}"
                          IsChecked="True" Margin="0,0,10,0"/>
                <CheckBox x:Name="chkLogWarning" Content="Warning"
                          Style="{StaticResource DarkCheckBox}"
                          IsChecked="True" Margin="0,0,10,0"/>
                <CheckBox x:Name="chkLogError" Content="Error"
                          Style="{StaticResource DarkCheckBox}"
                          IsChecked="True" Margin="0,0,10,0"/>
            </StackPanel>

            <!-- Auto-scroll and line count (right) -->
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <CheckBox x:Name="chkLogAutoScroll" Content="Auto-scroll"
                          Style="{StaticResource DarkCheckBox}"
                          IsChecked="True" Margin="0,0,15,0"/>
                <TextBlock x:Name="txtLogLineCount" Text="Lines: 0"
                           Foreground="#808080" VerticalAlignment="Center"/>
            </StackPanel>

            <!-- Spacer -->
            <Border/>
        </DockPanel>
    </Border>

    <!-- Log Content -->
    <Border Grid.Row="1" Background="#1E1E1E" CornerRadius="4">
        <TextBox x:Name="txtLogContent"
                 IsReadOnly="True"
                 TextWrapping="NoWrap"
                 FontFamily="Consolas"
                 FontSize="11"
                 Background="#1E1E1E"
                 Foreground="#E0E0E0"
                 BorderThickness="0"
                 Padding="10"
                 VerticalScrollBarVisibility="Auto"
                 HorizontalScrollBarVisibility="Auto"
                 AcceptsReturn="True"/>
    </Border>

    <!-- Button Bar -->
    <Border Grid.Row="2" Background="#252525" CornerRadius="4" Padding="10" Margin="0,10,0,0">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnLogClear" Content="Clear"
                    Style="{StaticResource DarkButton}" Width="70" Margin="0,0,5,0"
                    ToolTip="Clear log buffer"/>
            <Button x:Name="btnLogCopy" Content="Copy All"
                    Style="{StaticResource DarkButton}" Width="70" Margin="0,0,5,0"
                    ToolTip="Copy log to clipboard"/>
            <Button x:Name="btnLogSave" Content="Save"
                    Style="{StaticResource DarkButton}" Width="70" Margin="0,0,5,0"
                    ToolTip="Save log to file"/>
            <Button x:Name="btnLogPopOut" Content="Pop Out"
                    Style="{StaticResource LogsButton}" Width="80"
                    ToolTip="Open log in separate window"/>
        </StackPanel>
    </Border>
</Grid>
```

### Step 2: Update Control References

Add new control names to the collection in GuiMain.ps1:

```powershell
$controlNames = @(
    # ... existing controls ...

    # Log panel controls
    'chkLogDebug', 'chkLogInfo', 'chkLogWarning', 'chkLogError',
    'chkLogAutoScroll', 'txtLogLineCount', 'txtLogContent',
    'btnLogClear', 'btnLogCopy', 'btnLogSave', 'btnLogPopOut'
)
```

### Step 3: Create Log Panel Update Function

In GuiLogWindow.ps1, add function to update inline panel:

```powershell
function Update-InlineLogContent {
    <#
    .SYNOPSIS
        Updates the inline log panel in the main window
    .DESCRIPTION
        Filters log entries based on level checkboxes and updates txtLogContent.
        Called by the progress timer or when filters change.
    #>
    [CmdletBinding()]
    param()

    # Check if inline log controls exist
    if (-not $script:Controls['txtLogContent']) { return }

    # Get filter states
    $showDebug = $script:Controls['chkLogDebug'].IsChecked
    $showInfo = $script:Controls['chkLogInfo'].IsChecked
    $showWarning = $script:Controls['chkLogWarning'].IsChecked
    $showError = $script:Controls['chkLogError'].IsChecked

    # Filter log buffer
    $filteredLines = @()
    foreach ($entry in $script:GuiLogBuffer) {
        $include = $false
        if ($entry -match '\[DEBUG\]' -and $showDebug) { $include = $true }
        elseif ($entry -match '\[INFO\]' -and $showInfo) { $include = $true }
        elseif ($entry -match '\[WARNING\]' -and $showWarning) { $include = $true }
        elseif ($entry -match '\[ERROR\]' -and $showError) { $include = $true }
        elseif ($entry -notmatch '\[(DEBUG|INFO|WARNING|ERROR)\]') { $include = $true }

        if ($include) { $filteredLines += $entry }
    }

    # Update display
    $script:Controls['txtLogContent'].Text = $filteredLines -join "`r`n"
    $script:Controls['txtLogLineCount'].Text = "Lines: $($filteredLines.Count)"

    # Auto-scroll
    if ($script:Controls['chkLogAutoScroll'].IsChecked) {
        $script:Controls['txtLogContent'].ScrollToEnd()
    }
}
```

### Step 4: Wire Event Handlers

In GuiMain.ps1, add event handlers for log panel:

```powershell
# Filter checkboxes - update display when changed
foreach ($filterName in @('chkLogDebug', 'chkLogInfo', 'chkLogWarning', 'chkLogError')) {
    if ($script:Controls[$filterName]) {
        $script:Controls[$filterName].Add_Checked({
            Invoke-SafeEventHandler -Handler { Update-InlineLogContent } -EventName 'LogFilter_Changed'
        })
        $script:Controls[$filterName].Add_Unchecked({
            Invoke-SafeEventHandler -Handler { Update-InlineLogContent } -EventName 'LogFilter_Changed'
        })
    }
}

# Clear button
$script:Controls['btnLogClear'].Add_Click({
    Invoke-SafeEventHandler -Handler {
        Clear-GuiLogBuffer
        Update-InlineLogContent
    } -EventName 'LogClear_Click'
})

# Copy button
$script:Controls['btnLogCopy'].Add_Click({
    Invoke-SafeEventHandler -Handler {
        $script:Controls['txtLogContent'].Text | Set-Clipboard
        $script:Controls['txtStatus'].Text = "Log copied to clipboard"
    } -EventName 'LogCopy_Click'
})

# Save button
$script:Controls['btnLogSave'].Add_Click({
    Invoke-SafeEventHandler -Handler {
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Filter = "Log files (*.log)|*.log|Text files (*.txt)|*.txt"
        $dialog.DefaultExt = ".log"
        $dialog.FileName = "robocurse_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

        if ($dialog.ShowDialog()) {
            $script:Controls['txtLogContent'].Text | Out-File -FilePath $dialog.FileName -Encoding UTF8
            $script:Controls['txtStatus'].Text = "Log saved to $($dialog.FileName)"
        }
    } -EventName 'LogSave_Click'
})

# Pop Out button - opens separate window
$script:Controls['btnLogPopOut'].Add_Click({
    Invoke-SafeEventHandler -Handler {
        Show-LogWindow
    } -EventName 'LogPopOut_Click'
})
```

### Step 5: Update Write-GuiLog

Modify Write-GuiLog to also update inline panel:

```powershell
# In Write-GuiLog, after adding to buffer:
if ($script:Controls['txtLogContent'] -and $script:ActivePanel -eq 'Logs') {
    Update-InlineLogContent
}
```

### Step 6: Update Progress Timer

Add inline log update to the progress timer (if not already updating per-message):

```powershell
# In progress timer tick handler, add:
if ($script:ActivePanel -eq 'Logs') {
    Update-InlineLogContent
}
```

## Tests to Write

**File**: `tests/Unit/GuiLogViewer.Tests.ps1` (new file)

The `Update-InlineLogContent` function contains testable filtering logic.

### Test: Log Filtering Logic

```powershell
Describe 'Update-InlineLogContent' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\src\Robocurse\Public\GuiLogWindow.ps1')

        # Mock controls
        $script:Controls = @{
            'chkLogDebug'    = [PSCustomObject]@{ IsChecked = $true }
            'chkLogInfo'     = [PSCustomObject]@{ IsChecked = $true }
            'chkLogWarning'  = [PSCustomObject]@{ IsChecked = $true }
            'chkLogError'    = [PSCustomObject]@{ IsChecked = $true }
            'chkLogAutoScroll' = [PSCustomObject]@{ IsChecked = $true }
            'txtLogContent'  = [PSCustomObject]@{ Text = '' }
            'txtLogLineCount' = [PSCustomObject]@{ Text = '' }
        }

        # Add ScrollToEnd method mock
        $script:Controls['txtLogContent'] | Add-Member -MemberType ScriptMethod -Name 'ScrollToEnd' -Value { } -Force

        # Setup log buffer with test data
        $script:GuiLogBuffer = @(
            '2024-01-15 10:00:00 [DEBUG] Debug message 1',
            '2024-01-15 10:00:01 [INFO] Info message 1',
            '2024-01-15 10:00:02 [WARNING] Warning message 1',
            '2024-01-15 10:00:03 [ERROR] Error message 1',
            '2024-01-15 10:00:04 [INFO] Info message 2'
        )
    }

    Context 'with all filters enabled' {
        BeforeEach {
            $script:Controls['chkLogDebug'].IsChecked = $true
            $script:Controls['chkLogInfo'].IsChecked = $true
            $script:Controls['chkLogWarning'].IsChecked = $true
            $script:Controls['chkLogError'].IsChecked = $true
            Update-InlineLogContent
        }

        It 'should include all log entries' {
            $script:Controls['txtLogContent'].Text | Should -Match 'Debug message 1'
            $script:Controls['txtLogContent'].Text | Should -Match 'Info message 1'
            $script:Controls['txtLogContent'].Text | Should -Match 'Warning message 1'
            $script:Controls['txtLogContent'].Text | Should -Match 'Error message 1'
        }

        It 'should show correct line count' {
            $script:Controls['txtLogLineCount'].Text | Should -Be 'Lines: 5'
        }
    }

    Context 'with DEBUG filter disabled' {
        BeforeEach {
            $script:Controls['chkLogDebug'].IsChecked = $false
            $script:Controls['chkLogInfo'].IsChecked = $true
            $script:Controls['chkLogWarning'].IsChecked = $true
            $script:Controls['chkLogError'].IsChecked = $true
            Update-InlineLogContent
        }

        It 'should exclude DEBUG messages' {
            $script:Controls['txtLogContent'].Text | Should -Not -Match 'Debug message'
        }

        It 'should include other levels' {
            $script:Controls['txtLogContent'].Text | Should -Match 'Info message'
            $script:Controls['txtLogContent'].Text | Should -Match 'Warning message'
            $script:Controls['txtLogContent'].Text | Should -Match 'Error message'
        }

        It 'should show correct filtered line count' {
            $script:Controls['txtLogLineCount'].Text | Should -Be 'Lines: 4'
        }
    }

    Context 'with only ERROR filter enabled' {
        BeforeEach {
            $script:Controls['chkLogDebug'].IsChecked = $false
            $script:Controls['chkLogInfo'].IsChecked = $false
            $script:Controls['chkLogWarning'].IsChecked = $false
            $script:Controls['chkLogError'].IsChecked = $true
            Update-InlineLogContent
        }

        It 'should only include ERROR messages' {
            $script:Controls['txtLogContent'].Text | Should -Match 'Error message'
            $script:Controls['txtLogContent'].Text | Should -Not -Match 'Debug message'
            $script:Controls['txtLogContent'].Text | Should -Not -Match 'Info message'
            $script:Controls['txtLogContent'].Text | Should -Not -Match 'Warning message'
        }

        It 'should show correct line count' {
            $script:Controls['txtLogLineCount'].Text | Should -Be 'Lines: 1'
        }
    }

    Context 'with empty log buffer' {
        BeforeEach {
            $script:GuiLogBuffer = @()
            Update-InlineLogContent
        }

        It 'should show empty content' {
            $script:Controls['txtLogContent'].Text | Should -BeNullOrEmpty
        }

        It 'should show zero lines' {
            $script:Controls['txtLogLineCount'].Text | Should -Be 'Lines: 0'
        }
    }

    Context 'with missing controls' {
        BeforeEach {
            $script:Controls['txtLogContent'] = $null
        }

        It 'should handle missing controls gracefully' {
            { Update-InlineLogContent } | Should -Not -Throw
        }
    }
}
```

### Test: Log Panel Control Names

```powershell
Describe 'Log Panel - Control Names' {
    BeforeAll {
        $xamlPath = Join-Path $PSScriptRoot '..\..\src\Robocurse\Resources\MainWindow.xaml'
        $xamlContent = Get-Content $xamlPath -Raw
        $script:window = [System.Windows.Markup.XamlReader]::Parse($xamlContent)
    }

    @(
        'chkLogDebug', 'chkLogInfo', 'chkLogWarning', 'chkLogError',
        'chkLogAutoScroll', 'txtLogLineCount', 'txtLogContent',
        'btnLogClear', 'btnLogCopy', 'btnLogSave', 'btnLogPopOut'
    ) | ForEach-Object {
        It "should have control '$_'" {
            $script:window.FindName($_) | Should -Not -BeNullOrEmpty
        }
    }
}
```

### Test: Clear-GuiLogBuffer Function

```powershell
Describe 'Clear-GuiLogBuffer' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\src\Robocurse\Public\GuiLogWindow.ps1')
    }

    It 'should clear the log buffer' {
        $script:GuiLogBuffer = @('entry1', 'entry2', 'entry3')
        Clear-GuiLogBuffer
        $script:GuiLogBuffer.Count | Should -Be 0
    }
}
```

## Success Criteria

1. **Log panel displays**: Switching to Logs rail button shows log content
2. **Filters work**: Unchecking Debug/Info/Warning/Error filters content
3. **Auto-scroll works**: New entries scroll into view when enabled
4. **Line count updates**: Shows current filtered line count
5. **Clear works**: Empties log buffer and display
6. **Copy works**: Copies log text to clipboard
7. **Save works**: Opens save dialog and writes file
8. **Pop Out works**: Opens separate log window
9. **Real-time updates**: New log entries appear as they're generated
10. **All unit tests pass**: GuiLogViewer.Tests.ps1 passes completely

## Testing

1. Build: `.\build\Build-Robocurse.ps1`
2. Run: `.\dist\Robocurse.ps1`
3. Switch to Logs panel
4. Start replication - verify logs appear
5. Toggle filter checkboxes - verify filtering
6. Toggle auto-scroll - verify behavior
7. Click Clear - verify log cleared
8. Click Copy - verify clipboard
9. Click Save - verify file save
10. Click Pop Out - verify popup opens
11. Verify popup and inline panel show same content

## Notes

- **Ring buffer size**: GuiLogMaxLines = 500 - logs older than this are discarded
- **Performance**: Only update inline log when Logs panel is active
- **Thread safety**: Log buffer may be written from background thread - use thread-safe access
- **Monospace font**: Consolas at 11pt for compact but readable log display
- **Naming convention**: Prefixed with `Log` (chkLogDebug vs chkDebug) to avoid conflicts with popup window controls
