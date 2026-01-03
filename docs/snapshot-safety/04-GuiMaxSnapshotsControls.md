# Task: GUI Max Snapshots Controls

## Process Requirements (EAD)

**TDD is mandatory**: Write tests FIRST, then implementation.

**XAML Enforcement Test**: Add AST-based test to verify XAML control names exist.

---

## Objective

Add GUI controls for `MaxTotalSnapshots` setting in the Settings panel.

## Success Criteria

1. Checkbox "Limit total snapshots per volume" in Settings panel
2. Number field for max count (enabled when checked)
3. Unchecked = MaxTotalSnapshots = 0 (unlimited)
4. Saved to config on Save button

## Research

- MainWindow.xaml:762-815 - Settings panel structure (PERFORMANCE section pattern)
- MainWindow.xaml:817-890 - LOGGING section pattern to follow
- GuiMain.ps1 - Settings load/save handlers

## Test Plan (WRITE FIRST)

File: `tests/Unit/GuiSnapshotSettings.Tests.ps1`

Note: GUI tests are limited without full WPF context. Focus on the save/load logic.

```powershell
Describe 'MaxTotalSnapshots GUI Settings Logic' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\Robocurse\Public\Configuration.ps1"
    }

    Context 'Save-MaxTotalSnapshotsSettings' {
        It 'saves 0 when checkbox unchecked' {
            $config = New-DefaultConfig
            # Simulate unchecked checkbox
            $isChecked = $false
            $textValue = "10"

            if ($isChecked) {
                $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots = [int]$textValue
            } else {
                $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots = 0
            }

            $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots | Should -Be 0
        }

        It 'saves entered value when checkbox checked' {
            $config = New-DefaultConfig
            $isChecked = $true
            $textValue = "15"

            if ($isChecked) {
                $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots = [Math]::Max(1, [int]$textValue)
            } else {
                $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots = 0
            }

            $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots | Should -Be 15
        }

        It 'enforces minimum of 1 when checked' {
            $config = New-DefaultConfig
            $isChecked = $true
            $textValue = "0"  # Invalid

            if ($isChecked) {
                $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots = [Math]::Max(1, [int]$textValue)
            }

            $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots | Should -Be 1
        }
    }

    Context 'Load-MaxTotalSnapshotsSettings' {
        It 'checkbox unchecked when value is 0' {
            $config = New-DefaultConfig
            $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots = 0

            $isChecked = ($config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots -gt 0)

            $isChecked | Should -BeFalse
        }

        It 'checkbox checked when value > 0' {
            $config = New-DefaultConfig
            $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots = 10

            $isChecked = ($config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots -gt 0)
            $displayValue = $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots

            $isChecked | Should -BeTrue
            $displayValue | Should -Be 10
        }
    }
}
```

### XAML Enforcement Test

Add to existing enforcement test suite to verify XAML control naming:

```powershell
It 'MainWindow.xaml has required snapshot settings controls' {
    $xamlPath = "$PSScriptRoot\..\..\src\Robocurse\Resources\MainWindow.xaml"
    $xaml = Get-Content $xamlPath -Raw

    $xaml | Should -Match 'x:Name="chkSettingsLimitSnapshots"'
    $xaml | Should -Match 'x:Name="txtSettingsMaxSnapshots"'
}
```

## Implementation

### 1. Add SNAPSHOTS section to Settings panel (MainWindow.xaml, after LOGGING section ~line 890)

```xml
<!-- SNAPSHOTS Section -->
<TextBlock Text="SNAPSHOTS" FontWeight="Bold" Foreground="#0078D4" Margin="0,0,0,10"/>
<Border Background="#1E1E1E" CornerRadius="4" Padding="15" Margin="0,0,0,20">
    <StackPanel>
        <CheckBox x:Name="chkSettingsLimitSnapshots"
                  Content="Limit total snapshots per volume (prevents runaway from crashes)"
                  Style="{StaticResource DarkCheckBox}" Margin="0,0,0,10"/>
        <StackPanel Orientation="Horizontal" Margin="20,0,0,0">
            <Label Content="Maximum:" Style="{StaticResource DarkLabel}" VerticalAlignment="Center"/>
            <TextBox x:Name="txtSettingsMaxSnapshots" Text="10" Width="60"
                     Style="{StaticResource DarkTextBox}"
                     IsEnabled="{Binding IsChecked, ElementName=chkSettingsLimitSnapshots}"
                     Margin="5,0,0,0"/>
            <Label Content="(job fails if exceeded, requiring manual cleanup)"
                   Style="{StaticResource DarkLabel}" Foreground="#808080"
                   VerticalAlignment="Center" Margin="10,0,0,0"/>
        </StackPanel>
    </StackPanel>
</Border>
```

### 2. Load settings in GUI initialization (GuiMain.ps1 or GuiSettings.ps1)

Find the settings load function and add:

```powershell
# Load MaxTotalSnapshots setting
$maxTotal = $script:Config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots
$script:Controls.chkSettingsLimitSnapshots.IsChecked = ($maxTotal -gt 0)
$script:Controls.txtSettingsMaxSnapshots.Text = if ($maxTotal -gt 0) { $maxTotal.ToString() } else { "10" }
```

### 3. Save settings handler

Find the settings save function and add:

```powershell
# Save MaxTotalSnapshots setting
if ($script:Controls.chkSettingsLimitSnapshots.IsChecked) {
    $value = 0
    if ([int]::TryParse($script:Controls.txtSettingsMaxSnapshots.Text, [ref]$value)) {
        $script:Config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots = [Math]::Max(1, $value)
    }
} else {
    $script:Config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots = 0
}
```

## Files to Modify

- `src/Robocurse/Resources/MainWindow.xaml` - Add SNAPSHOTS section to Settings panel
- `src/Robocurse/Public/GuiMain.ps1` or `GuiSettings.ps1` - Load/save handlers
- `tests/Unit/GuiSnapshotSettings.Tests.ps1` (new)

## Verification

```powershell
.\scripts\run-tests.ps1
powershell -NoProfile -Command 'Get-Content $env:TEMP\pester-summary.txt'
```
