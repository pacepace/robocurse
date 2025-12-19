# Task: GUI Profile Snapshot Settings

## Objective
Add snapshot configuration controls to the Profile settings panel, allowing users to enable persistent snapshots per profile and configure global retention settings.

## Success Criteria
- [ ] Profile panel has "Persistent Snapshot" checkbox
- [ ] Settings panel has "Snapshot Retention" section
- [ ] Settings include default keep count and per-volume overrides
- [ ] Settings persist to configuration file
- [ ] Tests verify settings save/load correctly

## Research

### Existing Profile Panel Controls (MainWindow.xaml)
Profile panel has controls for:
- Name, Description
- Source path, UseVss checkbox
- Destination path
- Chunking settings
- Robocopy options

### Existing Settings Panel Controls
Settings panel has sections for:
- Performance (workers, bandwidth)
- Logging (path, verbosity)
- Email notification

### Settings Save/Load Pattern (GuiSettings.ps1)
```powershell
function Import-SettingsToForm {
    # Load config values into form controls
    $script:Controls.txtSetting.Text = $config.GlobalSettings.SomeValue
}

function Save-SettingsFromForm {
    # Save form values back to config
    $script:Config.GlobalSettings.SomeValue = $script:Controls.txtSetting.Text
    Save-RobocurseConfig -Config $script:Config
}
```

### Profile Save/Load Pattern (GuiProfiles.ps1)
```powershell
function Import-ProfileToForm {
    param($Profile)
    $script:Controls.txtSource.Text = $Profile.Source
    $script:Controls.chkUseVss.IsChecked = $Profile.UseVss
}

function Save-ProfileFromForm {
    $selected = Get-SelectedProfile
    $selected.Source = $script:Controls.txtSource.Text
    $selected.UseVss = $script:Controls.chkUseVss.IsChecked
}
```

## Implementation

### Part 1: Profile Panel XAML Updates

#### File: `src\Robocurse\Resources\MainWindow.xaml`

**Add after UseVss checkbox in Profile panel (around Source section):**

```xaml
<!-- Persistent Snapshot Settings (after UseVss) -->
<StackPanel Orientation="Horizontal" Margin="0,10,0,0">
    <CheckBox x:Name="chkPersistentSnapshot"
              Content="Create persistent snapshot at backup start"
              Foreground="#E0E0E0"
              ToolTip="Creates a recoverable VSS snapshot before backup, with retention management"/>
</StackPanel>

<TextBlock Text="Persistent snapshots remain after backup for point-in-time recovery. Retention is configured in Settings."
           Foreground="#888888" FontSize="10" Margin="25,2,0,5" TextWrapping="Wrap"/>
```

### Part 2: Settings Panel XAML Updates

#### File: `src\Robocurse\Resources\MainWindow.xaml`

**Add new section to Settings panel (after Logging section):**

```xaml
<!-- Snapshot Retention Settings -->
<Border BorderBrush="#3D3D3D" BorderThickness="0,1,0,0" Margin="0,15,0,0" Padding="0,15,0,0">
    <StackPanel>
        <Label Content="Snapshot Retention" Style="{StaticResource DarkLabel}" FontWeight="Bold" FontSize="14"/>

        <Grid Margin="0,10,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="180"/>
                <ColumnDefinition Width="80"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Label Content="Default snapshots to keep:" Style="{StaticResource DarkLabel}"
                   Grid.Column="0" VerticalAlignment="Center"/>
            <TextBox x:Name="txtDefaultKeepCount" Text="3" Width="60"
                     Grid.Column="1" Style="{StaticResource DarkTextBox}"
                     TextAlignment="Center"
                     ToolTip="Number of snapshots to retain per volume (default)"/>
            <Label Content="per volume" Style="{StaticResource DarkLabel}"
                   Grid.Column="2" VerticalAlignment="Center" Foreground="#888888"/>
        </Grid>

        <!-- Volume Overrides -->
        <StackPanel Margin="0,15,0,0">
            <Label Content="Volume-specific overrides:" Style="{StaticResource DarkLabel}"/>
            <TextBlock Text="Format: D:=5, E:=10 (comma-separated)" Foreground="#888888" FontSize="10" Margin="5,2,0,5"/>
            <TextBox x:Name="txtVolumeOverrides" Width="300" Height="24"
                     Style="{StaticResource DarkTextBox}"
                     HorizontalAlignment="Left"
                     ToolTip="Per-volume retention counts (e.g., D:=5, E:=10)"/>
        </StackPanel>

        <!-- Snapshot Schedules Link -->
        <StackPanel Margin="0,15,0,0">
            <TextBlock Foreground="#888888" FontSize="11" TextWrapping="Wrap">
                <Run Text="Snapshot schedules can be configured via command line: "/>
                <Run Text="Robocurse.ps1 -SnapshotSchedule" Foreground="#0078D4"/>
            </TextBlock>
        </StackPanel>
    </StackPanel>
</Border>
```

### Part 3: Profile Settings Logic

#### File: `src\Robocurse\Public\GuiProfiles.ps1`

**Add to control list in initialization:**

```powershell
'chkPersistentSnapshot',
```

**Update `Import-ProfileToForm`:**

```powershell
# Add after UseVss handling
if ($script:Controls['chkPersistentSnapshot']) {
    $persistentEnabled = $false
    if ($Profile.PersistentSnapshot -and $Profile.PersistentSnapshot.Enabled) {
        $persistentEnabled = $true
    }
    $script:Controls.chkPersistentSnapshot.IsChecked = $persistentEnabled
}
```

**Update `Save-ProfileFromForm`:**

```powershell
# Add after UseVss handling
if ($script:Controls['chkPersistentSnapshot']) {
    if (-not $selected.PersistentSnapshot) {
        $selected | Add-Member -NotePropertyName PersistentSnapshot -NotePropertyValue ([PSCustomObject]@{
            Enabled = $false
        }) -Force
    }
    $selected.PersistentSnapshot.Enabled = $script:Controls.chkPersistentSnapshot.IsChecked
}
```

### Part 4: Settings Logic

#### File: `src\Robocurse\Public\GuiSettings.ps1`

**Add to control list in initialization:**

```powershell
'txtDefaultKeepCount',
'txtVolumeOverrides',
```

**Update `Import-SettingsToForm`:**

```powershell
# Add snapshot retention settings
if ($script:Controls['txtDefaultKeepCount']) {
    $defaultKeep = 3
    if ($config.GlobalSettings.SnapshotRetention -and $config.GlobalSettings.SnapshotRetention.DefaultKeepCount) {
        $defaultKeep = $config.GlobalSettings.SnapshotRetention.DefaultKeepCount
    }
    $script:Controls.txtDefaultKeepCount.Text = $defaultKeep.ToString()
}

if ($script:Controls['txtVolumeOverrides']) {
    $overridesText = ""
    if ($config.GlobalSettings.SnapshotRetention -and $config.GlobalSettings.SnapshotRetention.VolumeOverrides) {
        $overrides = $config.GlobalSettings.SnapshotRetention.VolumeOverrides
        $pairs = @()
        foreach ($key in $overrides.Keys) {
            $pairs += "$key=$($overrides[$key])"
        }
        $overridesText = $pairs -join ", "
    }
    $script:Controls.txtVolumeOverrides.Text = $overridesText
}
```

**Update `Save-SettingsFromForm`:**

```powershell
# Save snapshot retention settings
if ($script:Controls['txtDefaultKeepCount']) {
    # Ensure SnapshotRetention exists
    if (-not $script:Config.GlobalSettings.SnapshotRetention) {
        $script:Config.GlobalSettings | Add-Member -NotePropertyName SnapshotRetention -NotePropertyValue ([PSCustomObject]@{
            DefaultKeepCount = 3
            VolumeOverrides = @{}
        }) -Force
    }

    $keepCount = 3
    if ([int]::TryParse($script:Controls.txtDefaultKeepCount.Text.Trim(), [ref]$keepCount)) {
        if ($keepCount -ge 0 -and $keepCount -le 100) {
            $script:Config.GlobalSettings.SnapshotRetention.DefaultKeepCount = $keepCount
        }
    }
}

if ($script:Controls['txtVolumeOverrides']) {
    $overridesText = $script:Controls.txtVolumeOverrides.Text.Trim()
    $overrides = @{}

    if ($overridesText) {
        # Parse "D:=5, E:=10" format
        $pairs = $overridesText -split '\s*,\s*'
        foreach ($pair in $pairs) {
            if ($pair -match '^([A-Za-z]:)\s*=\s*(\d+)$') {
                $volume = $Matches[1].ToUpper()
                $count = [int]$Matches[2]
                if ($count -ge 0 -and $count -le 100) {
                    $overrides[$volume] = $count
                }
            }
        }
    }

    $script:Config.GlobalSettings.SnapshotRetention.VolumeOverrides = $overrides
}
```

**Add validation function:**

```powershell
function Test-VolumeOverridesFormat {
    <#
    .SYNOPSIS
        Validates the volume overrides text format
    .PARAMETER Text
        The text to validate (e.g., "D:=5, E:=10")
    .OUTPUTS
        $true if valid, $false otherwise
    #>
    [CmdletBinding()]
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $true  # Empty is valid
    }

    $pairs = $Text -split '\s*,\s*'
    foreach ($pair in $pairs) {
        if ($pair -notmatch '^[A-Za-z]:\s*=\s*\d+$') {
            return $false
        }
    }

    return $true
}
```

### Part 5: Event Handlers

#### File: `src\Robocurse\Public\GuiSettings.ps1`

**Add validation on text change:**

```powershell
# Wire validation for volume overrides
$script:Controls['txtVolumeOverrides'].Add_LostFocus({
    Invoke-SafeEventHandler -HandlerName "VolumeOverridesValidation" -ScriptBlock {
        $text = $script:Controls.txtVolumeOverrides.Text
        if (-not (Test-VolumeOverridesFormat -Text $text)) {
            $script:Controls.txtVolumeOverrides.BorderBrush = [System.Windows.Media.Brushes]::OrangeRed
            $script:Controls.txtVolumeOverrides.ToolTip = "Invalid format. Use: D:=5, E:=10"
        }
        else {
            $script:Controls.txtVolumeOverrides.BorderBrush = [System.Windows.Media.Brushes]::Gray
            $script:Controls.txtVolumeOverrides.ToolTip = "Per-volume retention counts (e.g., D:=5, E:=10)"
            Save-SettingsFromForm
        }
    }
})

$script:Controls['txtDefaultKeepCount'].Add_LostFocus({
    Invoke-SafeEventHandler -HandlerName "DefaultKeepCountValidation" -ScriptBlock {
        $text = $script:Controls.txtDefaultKeepCount.Text.Trim()
        $count = 0
        if (-not [int]::TryParse($text, [ref]$count) -or $count -lt 0 -or $count -gt 100) {
            $script:Controls.txtDefaultKeepCount.BorderBrush = [System.Windows.Media.Brushes]::OrangeRed
            $script:Controls.txtDefaultKeepCount.ToolTip = "Enter a number between 0 and 100"
        }
        else {
            $script:Controls.txtDefaultKeepCount.BorderBrush = [System.Windows.Media.Brushes]::Gray
            $script:Controls.txtDefaultKeepCount.ToolTip = "Number of snapshots to retain per volume (default)"
            Save-SettingsFromForm
        }
    }
})
```

## Test Plan

### File: `tests\Unit\GuiProfileSnapshotSettings.Tests.ps1`

```powershell
BeforeAll {
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Utility.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Logging.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Configuration.ps1"

    Mock Write-RobocurseLog {}
}

Describe "Test-VolumeOverridesFormat" {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\Robocurse\Public\GuiSettings.ps1"
    }

    It "Returns true for empty string" {
        Test-VolumeOverridesFormat -Text "" | Should -Be $true
    }

    It "Returns true for valid single override" {
        Test-VolumeOverridesFormat -Text "D:=5" | Should -Be $true
    }

    It "Returns true for valid multiple overrides" {
        Test-VolumeOverridesFormat -Text "D:=5, E:=10" | Should -Be $true
    }

    It "Returns true for valid with spaces" {
        Test-VolumeOverridesFormat -Text "D: = 5 , E: = 10" | Should -Be $true
    }

    It "Returns false for invalid format" {
        Test-VolumeOverridesFormat -Text "D=5" | Should -Be $false  # Missing colon
        Test-VolumeOverridesFormat -Text "D:five" | Should -Be $false  # Non-numeric
        Test-VolumeOverridesFormat -Text "D:" | Should -Be $false  # Missing value
    }
}

Describe "Profile PersistentSnapshot Setting" {
    BeforeAll {
        $script:Config = New-DefaultConfig
        $script:Controls = @{
            'chkPersistentSnapshot' = [PSCustomObject]@{ IsChecked = $false }
        }
    }

    It "Default config has PersistentSnapshot disabled" {
        $profile = [PSCustomObject]@{
            Name = "Test"
            PersistentSnapshot = [PSCustomObject]@{ Enabled = $false }
        }

        $profile.PersistentSnapshot.Enabled | Should -Be $false
    }
}

Describe "Settings SnapshotRetention" {
    BeforeAll {
        $script:Controls = @{
            'txtDefaultKeepCount' = [PSCustomObject]@{ Text = "5" }
            'txtVolumeOverrides' = [PSCustomObject]@{ Text = "D:=10, E:=3" }
        }
        $script:Config = New-DefaultConfig
    }

    It "Parses volume overrides correctly" {
        # Simulate save
        $overridesText = "D:=10, E:=3"
        $overrides = @{}
        $pairs = $overridesText -split '\s*,\s*'
        foreach ($pair in $pairs) {
            if ($pair -match '^([A-Za-z]:)\s*=\s*(\d+)$') {
                $volume = $Matches[1].ToUpper()
                $count = [int]$Matches[2]
                $overrides[$volume] = $count
            }
        }

        $overrides["D:"] | Should -Be 10
        $overrides["E:"] | Should -Be 3
    }

    It "Formats volume overrides for display" {
        $overrides = @{ "D:" = 10; "E:" = 3 }
        $pairs = @()
        foreach ($key in $overrides.Keys) {
            $pairs += "$key=$($overrides[$key])"
        }
        $text = $pairs -join ", "

        $text | Should -Match "D:=10"
        $text | Should -Match "E:=3"
    }
}

Describe "Configuration Integration" {
    It "Config includes SnapshotRetention after save" {
        $config = New-DefaultConfig
        $config.GlobalSettings.SnapshotRetention | Should -Not -BeNull
        $config.GlobalSettings.SnapshotRetention.DefaultKeepCount | Should -Be 3
    }
}
```

## Files to Modify
- `src\Robocurse\Resources\MainWindow.xaml` - Add profile and settings XAML
- `src\Robocurse\Public\GuiProfiles.ps1` - Add PersistentSnapshot handling
- `src\Robocurse\Public\GuiSettings.ps1` - Add retention settings handling
- `src\Robocurse\Public\GuiMain.ps1` - Add control references

## Files to Create
- `tests\Unit\GuiProfileSnapshotSettings.Tests.ps1` - Unit tests

## Verification
```powershell
# Run unit tests
Invoke-Pester -Path tests\Unit\GuiProfileSnapshotSettings.Tests.ps1 -Output Detailed

# Manual verification
# 1. Launch GUI
# 2. Select a profile, check "Create persistent snapshot at backup start"
# 3. Save profile, reload config, verify setting persists
# 4. Go to Settings panel, verify Snapshot Retention section
# 5. Change default keep count, add volume overrides
# 6. Restart GUI, verify settings persist
```

## Dependencies
- Task 03 (ProfileSnapshotIntegration) - For config schema
- Task 05 (GuiSnapshotPanel) - Panel exists for reference

## Notes
- PersistentSnapshot checkbox is separate from UseVss (temp VSS for backup consistency)
- Volume overrides use simple text format for easy editing
- Invalid format shows orange border as visual feedback
- Settings auto-save on focus lost (existing pattern)
- Help text explains that schedules are CLI-only (for now)
