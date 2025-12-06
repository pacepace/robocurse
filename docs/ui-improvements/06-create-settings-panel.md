# Task: Create Settings Panel

## Objective

Create a new Settings panel that exposes global configuration options currently only accessible via the JSON config file. The panel should have an explicit Save button (unlike profiles which auto-save).

## Context

Global settings like concurrent workers, bandwidth limits, log paths, and email configuration are currently only editable by manually editing Robocurse.config.json. This panel brings these settings into the GUI for easier management.

## Files to Modify

| File | Action |
|------|--------|
| `src/Robocurse/Resources/MainWindow.xaml` | Populate panelSettings content |
| `src/Robocurse/Public/GuiMain.ps1` | Wire settings panel controls and Save button |
| `src/Robocurse/Public/Configuration.ps1` | May need function to save global settings |

## Research Required

### In Codebase
1. Read `src/Robocurse/Public/Configuration.ps1`:
   - How config is loaded (Get-RobocurseConfig)
   - Config structure (GlobalSettings, SyncProfiles)
   - How to save config changes

2. Read `Robocurse.config.json` for current GlobalSettings structure:
   - MaxConcurrentJobs
   - ThreadsPerJob
   - BandwidthLimitMbps
   - LogPath
   - EmailSettings (SmtpServer, SmtpPort, UseTls, CredentialName, From, To)

3. Read `src/Robocurse/Public/Scheduling.ps1`:
   - Current scheduled task status
   - How to display schedule info

### Config File GlobalSettings Structure

From typical Robocurse.config.json:
```json
{
  "Version": "1.0",
  "GlobalSettings": {
    "MaxConcurrentJobs": 4,
    "ThreadsPerJob": 8,
    "BandwidthLimitMbps": 0,
    "LogPath": ".\\Logs",
    "SiemLogEnabled": false,
    "SiemLogPath": ".\\Logs\\siem.jsonl",
    "EmailSettings": {
      "Enabled": false,
      "SmtpServer": "smtp.example.com",
      "SmtpPort": 587,
      "UseTls": true,
      "CredentialName": "Robocurse-SMTP",
      "From": "robocurse@example.com",
      "To": ["admin@example.com"]
    }
  }
}
```

## Implementation Steps

### Step 1: Design Settings Panel Layout

Organize settings into logical groups:

```
┌─────────────────────────────────────────────────────┐
│ PERFORMANCE                                         │
│ ┌─────────────────────────────────────────────────┐│
│ │ Concurrent Jobs:  [====|====] 4                 ││
│ │ Threads per Job:  [====|====] 8                 ││
│ │ Bandwidth Limit:  [________] MB/s (0=unlimited) ││
│ └─────────────────────────────────────────────────┘│
│                                                     │
│ LOGGING                                             │
│ ┌─────────────────────────────────────────────────┐│
│ │ Log Path:  [________________________] [Browse]  ││
│ │ ☐ Enable SIEM logging                           ││
│ │ SIEM Path: [________________________] [Browse]  ││
│ └─────────────────────────────────────────────────┘│
│                                                     │
│ EMAIL NOTIFICATIONS                                 │
│ ┌─────────────────────────────────────────────────┐│
│ │ ☐ Enable email notifications                    ││
│ │ SMTP Server: [______________] Port: [___]       ││
│ │ ☑ Use TLS   Credential: [______________]        ││
│ │ From: [____________________]                    ││
│ │ To:   [____________________]                    ││
│ └─────────────────────────────────────────────────┘│
│                                                     │
│ SCHEDULE                                            │
│ ┌─────────────────────────────────────────────────┐│
│ │ Status: Enabled - Daily at 02:00               ││
│ │ [Configure Schedule...]                         ││
│ └─────────────────────────────────────────────────┘│
│                                                     │
│                              [Revert] [Save Settings]│
└─────────────────────────────────────────────────────┘
```

### Step 2: Implement panelSettings Content

```xml
<Grid x:Name="panelSettings" Visibility="Collapsed" Margin="10">
    <Grid.RowDefinitions>
        <RowDefinition Height="*"/>     <!-- Scrollable content -->
        <RowDefinition Height="Auto"/>  <!-- Save button bar -->
    </Grid.RowDefinitions>

    <!-- Scrollable Settings Content -->
    <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto">
        <StackPanel>

            <!-- Performance Section -->
            <TextBlock Text="PERFORMANCE" FontWeight="Bold" Foreground="#0078D4"
                       Margin="0,0,0,10"/>
            <Border Background="#252525" CornerRadius="4" Padding="15" Margin="0,0,0,15">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="130"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="40"/>
                    </Grid.ColumnDefinitions>

                    <!-- Concurrent Jobs -->
                    <Label Grid.Row="0" Content="Concurrent Jobs:"
                           Style="{StaticResource DarkLabel}" VerticalAlignment="Center"/>
                    <Slider Grid.Row="0" Grid.Column="1" x:Name="sldSettingsJobs"
                            Minimum="1" Maximum="16" Value="4"
                            VerticalAlignment="Center"
                            ToolTip="Number of parallel robocopy processes"/>
                    <TextBlock Grid.Row="0" Grid.Column="2" x:Name="txtSettingsJobs"
                               Text="4" Foreground="#E0E0E0" VerticalAlignment="Center"/>

                    <!-- Threads per Job -->
                    <Label Grid.Row="1" Content="Threads per Job:"
                           Style="{StaticResource DarkLabel}" VerticalAlignment="Center"
                           Margin="0,10,0,0"/>
                    <Slider Grid.Row="1" Grid.Column="1" x:Name="sldSettingsThreads"
                            Minimum="1" Maximum="32" Value="8"
                            VerticalAlignment="Center" Margin="0,10,0,0"
                            ToolTip="Robocopy /MT thread count"/>
                    <TextBlock Grid.Row="1" Grid.Column="2" x:Name="txtSettingsThreads"
                               Text="8" Foreground="#E0E0E0" VerticalAlignment="Center"
                               Margin="0,10,0,0"/>

                    <!-- Bandwidth Limit -->
                    <Label Grid.Row="2" Content="Bandwidth Limit:"
                           Style="{StaticResource DarkLabel}" VerticalAlignment="Center"
                           Margin="0,10,0,0"/>
                    <StackPanel Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="2"
                                Orientation="Horizontal" Margin="0,10,0,0">
                        <TextBox x:Name="txtSettingsBandwidth" Width="60"
                                 Style="{StaticResource DarkTextBox}" Text="0"
                                 ToolTip="MB/s limit across all jobs. 0 = unlimited"/>
                        <Label Content="MB/s (0 = unlimited)"
                               Style="{StaticResource DarkLabel}"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- Logging Section -->
            <TextBlock Text="LOGGING" FontWeight="Bold" Foreground="#0078D4"
                       Margin="0,0,0,10"/>
            <Border Background="#252525" CornerRadius="4" Padding="15" Margin="0,0,0,15">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="80"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="60"/>
                    </Grid.ColumnDefinitions>

                    <Label Grid.Row="0" Content="Log Path:"
                           Style="{StaticResource DarkLabel}" VerticalAlignment="Center"/>
                    <TextBox Grid.Row="0" Grid.Column="1" x:Name="txtSettingsLogPath"
                             Style="{StaticResource DarkTextBox}" Margin="0,0,5,0"
                             ToolTip="Directory for operational logs"/>
                    <Button Grid.Row="0" Grid.Column="2" x:Name="btnSettingsLogBrowse"
                            Content="..." Style="{StaticResource DarkButton}"/>

                    <CheckBox Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="3"
                              x:Name="chkSettingsSiem" Content="Enable SIEM logging"
                              Style="{StaticResource DarkCheckBox}" Margin="0,10,0,0"
                              ToolTip="Output JSON Lines format for security monitoring"/>

                    <Label Grid.Row="2" Content="SIEM Path:"
                           Style="{StaticResource DarkLabel}" VerticalAlignment="Center"
                           Margin="0,10,0,0"/>
                    <TextBox Grid.Row="2" Grid.Column="1" x:Name="txtSettingsSiemPath"
                             Style="{StaticResource DarkTextBox}" Margin="0,10,5,0"/>
                    <Button Grid.Row="2" Grid.Column="2" x:Name="btnSettingsSiemBrowse"
                            Content="..." Style="{StaticResource DarkButton}" Margin="0,10,0,0"/>
                </Grid>
            </Border>

            <!-- Email Section -->
            <TextBlock Text="EMAIL NOTIFICATIONS" FontWeight="Bold" Foreground="#0078D4"
                       Margin="0,0,0,10"/>
            <Border Background="#252525" CornerRadius="4" Padding="15" Margin="0,0,0,15">
                <StackPanel>
                    <CheckBox x:Name="chkSettingsEmailEnabled" Content="Enable email notifications"
                              Style="{StaticResource DarkCheckBox}" Margin="0,0,0,10"/>

                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="80"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="50"/>
                            <ColumnDefinition Width="60"/>
                        </Grid.ColumnDefinitions>

                        <Label Grid.Row="0" Content="SMTP:"
                               Style="{StaticResource DarkLabel}" VerticalAlignment="Center"/>
                        <TextBox Grid.Row="0" Grid.Column="1" x:Name="txtSettingsSmtp"
                                 Style="{StaticResource DarkTextBox}" Margin="0,0,5,5"/>
                        <Label Grid.Row="0" Grid.Column="2" Content="Port:"
                               Style="{StaticResource DarkLabel}" VerticalAlignment="Center"/>
                        <TextBox Grid.Row="0" Grid.Column="3" x:Name="txtSettingsSmtpPort"
                                 Style="{StaticResource DarkTextBox}" Text="587" Margin="0,0,0,5"/>

                        <CheckBox Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2"
                                  x:Name="chkSettingsTls" Content="Use TLS"
                                  Style="{StaticResource DarkCheckBox}" IsChecked="True"
                                  Margin="0,5,0,5"/>

                        <Label Grid.Row="2" Content="Credential:"
                               Style="{StaticResource DarkLabel}" VerticalAlignment="Center"/>
                        <TextBox Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="3"
                                 x:Name="txtSettingsCredential"
                                 Style="{StaticResource DarkTextBox}" Margin="0,0,0,5"
                                 ToolTip="Windows Credential Manager entry name"/>

                        <Label Grid.Row="3" Content="From:"
                               Style="{StaticResource DarkLabel}" VerticalAlignment="Center"/>
                        <TextBox Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="3"
                                 x:Name="txtSettingsEmailFrom"
                                 Style="{StaticResource DarkTextBox}" Margin="0,0,0,5"/>
                    </Grid>

                    <Label Content="To (comma-separated):" Style="{StaticResource DarkLabel}"
                           Margin="0,5,0,0"/>
                    <TextBox x:Name="txtSettingsEmailTo" Style="{StaticResource DarkTextBox}"
                             ToolTip="Recipient email addresses, comma-separated"/>
                </StackPanel>
            </Border>

            <!-- Schedule Section -->
            <TextBlock Text="SCHEDULE" FontWeight="Bold" Foreground="#0078D4"
                       Margin="0,0,0,10"/>
            <Border Background="#252525" CornerRadius="4" Padding="15">
                <DockPanel>
                    <Button DockPanel.Dock="Right" x:Name="btnSettingsSchedule"
                            Content="Configure..." Style="{StaticResource ScheduleButton}"
                            Width="100"/>
                    <TextBlock x:Name="txtSettingsScheduleStatus"
                               Text="Status: Not configured"
                               Foreground="#808080" VerticalAlignment="Center"/>
                </DockPanel>
            </Border>

        </StackPanel>
    </ScrollViewer>

    <!-- Button Bar -->
    <Border Grid.Row="1" Background="#252525" CornerRadius="4" Padding="10" Margin="0,10,0,0">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnSettingsRevert" Content="Revert"
                    Style="{StaticResource DarkButton}" Width="80" Margin="0,0,10,0"
                    ToolTip="Discard changes and reload from config file"/>
            <Button x:Name="btnSettingsSave" Content="Save Settings"
                    Style="{StaticResource RunButton}" Width="100"
                    ToolTip="Save changes to config file"/>
        </StackPanel>
    </Border>
</Grid>
```

### Step 3: Add Control References

In GuiMain.ps1, add settings controls:

```powershell
$controlNames = @(
    # ... existing ...

    # Settings panel controls
    'sldSettingsJobs', 'txtSettingsJobs',
    'sldSettingsThreads', 'txtSettingsThreads',
    'txtSettingsBandwidth',
    'txtSettingsLogPath', 'btnSettingsLogBrowse',
    'chkSettingsSiem', 'txtSettingsSiemPath', 'btnSettingsSiemBrowse',
    'chkSettingsEmailEnabled', 'txtSettingsSmtp', 'txtSettingsSmtpPort',
    'chkSettingsTls', 'txtSettingsCredential',
    'txtSettingsEmailFrom', 'txtSettingsEmailTo',
    'btnSettingsSchedule', 'txtSettingsScheduleStatus',
    'btnSettingsRevert', 'btnSettingsSave'
)
```

### Step 4: Create Load/Save Functions

```powershell
function Import-SettingsToForm {
    <#
    .SYNOPSIS
        Loads global settings from config into the settings panel controls
    #>
    [CmdletBinding()]
    param()

    $config = Get-RobocurseConfig -Path $script:ConfigPath
    $global = $config.GlobalSettings

    # Performance
    $script:Controls['sldSettingsJobs'].Value = $global.MaxConcurrentJobs
    $script:Controls['txtSettingsJobs'].Text = $global.MaxConcurrentJobs
    $script:Controls['sldSettingsThreads'].Value = $global.ThreadsPerJob
    $script:Controls['txtSettingsThreads'].Text = $global.ThreadsPerJob
    $script:Controls['txtSettingsBandwidth'].Text = $global.BandwidthLimitMbps

    # Logging
    $script:Controls['txtSettingsLogPath'].Text = $global.LogPath
    $script:Controls['chkSettingsSiem'].IsChecked = $global.SiemLogEnabled
    $script:Controls['txtSettingsSiemPath'].Text = $global.SiemLogPath

    # Email
    $email = $global.EmailSettings
    if ($email) {
        $script:Controls['chkSettingsEmailEnabled'].IsChecked = $email.Enabled
        $script:Controls['txtSettingsSmtp'].Text = $email.SmtpServer
        $script:Controls['txtSettingsSmtpPort'].Text = $email.SmtpPort
        $script:Controls['chkSettingsTls'].IsChecked = $email.UseTls
        $script:Controls['txtSettingsCredential'].Text = $email.CredentialName
        $script:Controls['txtSettingsEmailFrom'].Text = $email.From
        $script:Controls['txtSettingsEmailTo'].Text = ($email.To -join ', ')
    }

    # Schedule status
    Update-ScheduleStatus
}

function Save-SettingsFromForm {
    <#
    .SYNOPSIS
        Saves settings panel values to the config file
    #>
    [CmdletBinding()]
    param()

    $config = Get-RobocurseConfig -Path $script:ConfigPath

    # Update GlobalSettings
    $config.GlobalSettings.MaxConcurrentJobs = [int]$script:Controls['sldSettingsJobs'].Value
    $config.GlobalSettings.ThreadsPerJob = [int]$script:Controls['sldSettingsThreads'].Value
    $config.GlobalSettings.BandwidthLimitMbps = [int]$script:Controls['txtSettingsBandwidth'].Text
    $config.GlobalSettings.LogPath = $script:Controls['txtSettingsLogPath'].Text
    $config.GlobalSettings.SiemLogEnabled = $script:Controls['chkSettingsSiem'].IsChecked
    $config.GlobalSettings.SiemLogPath = $script:Controls['txtSettingsSiemPath'].Text

    # Email
    if (-not $config.GlobalSettings.EmailSettings) {
        $config.GlobalSettings.EmailSettings = @{}
    }
    $config.GlobalSettings.EmailSettings.Enabled = $script:Controls['chkSettingsEmailEnabled'].IsChecked
    $config.GlobalSettings.EmailSettings.SmtpServer = $script:Controls['txtSettingsSmtp'].Text
    $config.GlobalSettings.EmailSettings.SmtpPort = [int]$script:Controls['txtSettingsSmtpPort'].Text
    $config.GlobalSettings.EmailSettings.UseTls = $script:Controls['chkSettingsTls'].IsChecked
    $config.GlobalSettings.EmailSettings.CredentialName = $script:Controls['txtSettingsCredential'].Text
    $config.GlobalSettings.EmailSettings.From = $script:Controls['txtSettingsEmailFrom'].Text
    $config.GlobalSettings.EmailSettings.To = @($script:Controls['txtSettingsEmailTo'].Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    # Save to file
    Save-RobocurseConfig -Config $config -Path $script:ConfigPath

    $script:Controls['txtStatus'].Text = "Settings saved"
}
```

### Step 5: Wire Event Handlers

```powershell
# Slider value display sync
$script:Controls['sldSettingsJobs'].Add_ValueChanged({
    $script:Controls['txtSettingsJobs'].Text = [int]$script:Controls['sldSettingsJobs'].Value
})
$script:Controls['sldSettingsThreads'].Add_ValueChanged({
    $script:Controls['txtSettingsThreads'].Text = [int]$script:Controls['sldSettingsThreads'].Value
})

# Browse buttons
$script:Controls['btnSettingsLogBrowse'].Add_Click({
    Invoke-SafeEventHandler -Handler {
        $path = Show-FolderBrowser -Description "Select log directory"
        if ($path) { $script:Controls['txtSettingsLogPath'].Text = $path }
    } -EventName 'SettingsLogBrowse_Click'
})

# Save/Revert buttons
$script:Controls['btnSettingsSave'].Add_Click({
    Invoke-SafeEventHandler -Handler { Save-SettingsFromForm } -EventName 'SettingsSave_Click'
})
$script:Controls['btnSettingsRevert'].Add_Click({
    Invoke-SafeEventHandler -Handler { Import-SettingsToForm } -EventName 'SettingsRevert_Click'
})

# Schedule button (opens existing schedule dialog)
$script:Controls['btnSettingsSchedule'].Add_Click({
    Invoke-SafeEventHandler -Handler { Show-ScheduleDialog } -EventName 'SettingsSchedule_Click'
})

# Load settings when switching to Settings panel
# (in Set-ActivePanel function)
if ($PanelName -eq 'Settings') {
    Import-SettingsToForm
}
```

## Tests to Write

**File**: `tests/Unit/GuiSettingsPanel.Tests.ps1` (new file)

The `Import-SettingsToForm` and `Save-SettingsFromForm` functions contain testable logic.

### Test: Import-SettingsToForm

```powershell
Describe 'Import-SettingsToForm' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\src\Robocurse\Public\GuiMain.ps1')

        # Mock Get-RobocurseConfig
        Mock Get-RobocurseConfig {
            return @{
                GlobalSettings = @{
                    MaxConcurrentJobs = 6
                    ThreadsPerJob = 12
                    BandwidthLimitMbps = 100
                    LogPath = 'C:\Logs'
                    SiemLogEnabled = $true
                    SiemLogPath = 'C:\Logs\siem.jsonl'
                    EmailSettings = @{
                        Enabled = $true
                        SmtpServer = 'smtp.test.com'
                        SmtpPort = 465
                        UseTls = $false
                        CredentialName = 'TestCred'
                        From = 'test@test.com'
                        To = @('admin1@test.com', 'admin2@test.com')
                    }
                }
            }
        }

        # Mock controls
        $script:Controls = @{
            'sldSettingsJobs'       = [PSCustomObject]@{ Value = 0 }
            'txtSettingsJobs'       = [PSCustomObject]@{ Text = '' }
            'sldSettingsThreads'    = [PSCustomObject]@{ Value = 0 }
            'txtSettingsThreads'    = [PSCustomObject]@{ Text = '' }
            'txtSettingsBandwidth'  = [PSCustomObject]@{ Text = '' }
            'txtSettingsLogPath'    = [PSCustomObject]@{ Text = '' }
            'chkSettingsSiem'       = [PSCustomObject]@{ IsChecked = $false }
            'txtSettingsSiemPath'   = [PSCustomObject]@{ Text = '' }
            'chkSettingsEmailEnabled' = [PSCustomObject]@{ IsChecked = $false }
            'txtSettingsSmtp'       = [PSCustomObject]@{ Text = '' }
            'txtSettingsSmtpPort'   = [PSCustomObject]@{ Text = '' }
            'chkSettingsTls'        = [PSCustomObject]@{ IsChecked = $false }
            'txtSettingsCredential' = [PSCustomObject]@{ Text = '' }
            'txtSettingsEmailFrom'  = [PSCustomObject]@{ Text = '' }
            'txtSettingsEmailTo'    = [PSCustomObject]@{ Text = '' }
        }

        $script:ConfigPath = 'test.json'
    }

    BeforeEach {
        Import-SettingsToForm
    }

    It 'should load MaxConcurrentJobs to slider' {
        $script:Controls['sldSettingsJobs'].Value | Should -Be 6
    }

    It 'should load MaxConcurrentJobs to text' {
        $script:Controls['txtSettingsJobs'].Text | Should -Be '6'
    }

    It 'should load ThreadsPerJob' {
        $script:Controls['sldSettingsThreads'].Value | Should -Be 12
    }

    It 'should load BandwidthLimitMbps' {
        $script:Controls['txtSettingsBandwidth'].Text | Should -Be '100'
    }

    It 'should load LogPath' {
        $script:Controls['txtSettingsLogPath'].Text | Should -Be 'C:\Logs'
    }

    It 'should load SiemLogEnabled' {
        $script:Controls['chkSettingsSiem'].IsChecked | Should -BeTrue
    }

    It 'should load email settings' {
        $script:Controls['chkSettingsEmailEnabled'].IsChecked | Should -BeTrue
        $script:Controls['txtSettingsSmtp'].Text | Should -Be 'smtp.test.com'
        $script:Controls['txtSettingsSmtpPort'].Text | Should -Be '465'
        $script:Controls['chkSettingsTls'].IsChecked | Should -BeFalse
    }

    It 'should format email To as comma-separated' {
        $script:Controls['txtSettingsEmailTo'].Text | Should -Be 'admin1@test.com, admin2@test.com'
    }
}
```

### Test: Save-SettingsFromForm

```powershell
Describe 'Save-SettingsFromForm' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\src\Robocurse\Public\GuiMain.ps1')

        $script:savedConfig = $null

        # Mock Get-RobocurseConfig
        Mock Get-RobocurseConfig {
            return @{
                GlobalSettings = @{
                    MaxConcurrentJobs = 4
                    EmailSettings = @{}
                }
                SyncProfiles = @()
            }
        }

        # Mock Save-RobocurseConfig to capture what's saved
        Mock Save-RobocurseConfig {
            param($Config, $Path)
            $script:savedConfig = $Config
        }

        # Setup controls with test values
        $script:Controls = @{
            'sldSettingsJobs'       = [PSCustomObject]@{ Value = 8 }
            'sldSettingsThreads'    = [PSCustomObject]@{ Value = 16 }
            'txtSettingsBandwidth'  = [PSCustomObject]@{ Text = '50' }
            'txtSettingsLogPath'    = [PSCustomObject]@{ Text = 'D:\Logs' }
            'chkSettingsSiem'       = [PSCustomObject]@{ IsChecked = $true }
            'txtSettingsSiemPath'   = [PSCustomObject]@{ Text = 'D:\Logs\siem.log' }
            'chkSettingsEmailEnabled' = [PSCustomObject]@{ IsChecked = $true }
            'txtSettingsSmtp'       = [PSCustomObject]@{ Text = 'mail.example.com' }
            'txtSettingsSmtpPort'   = [PSCustomObject]@{ Text = '587' }
            'chkSettingsTls'        = [PSCustomObject]@{ IsChecked = $true }
            'txtSettingsCredential' = [PSCustomObject]@{ Text = 'MyCred' }
            'txtSettingsEmailFrom'  = [PSCustomObject]@{ Text = 'noreply@example.com' }
            'txtSettingsEmailTo'    = [PSCustomObject]@{ Text = 'user1@example.com, user2@example.com' }
            'txtStatus'             = [PSCustomObject]@{ Text = '' }
        }

        $script:ConfigPath = 'test.json'
    }

    BeforeEach {
        Save-SettingsFromForm
    }

    It 'should save MaxConcurrentJobs' {
        $script:savedConfig.GlobalSettings.MaxConcurrentJobs | Should -Be 8
    }

    It 'should save ThreadsPerJob' {
        $script:savedConfig.GlobalSettings.ThreadsPerJob | Should -Be 16
    }

    It 'should save BandwidthLimitMbps as integer' {
        $script:savedConfig.GlobalSettings.BandwidthLimitMbps | Should -Be 50
        $script:savedConfig.GlobalSettings.BandwidthLimitMbps | Should -BeOfType [int]
    }

    It 'should save LogPath' {
        $script:savedConfig.GlobalSettings.LogPath | Should -Be 'D:\Logs'
    }

    It 'should parse email To as array' {
        $script:savedConfig.GlobalSettings.EmailSettings.To | Should -HaveCount 2
        $script:savedConfig.GlobalSettings.EmailSettings.To[0] | Should -Be 'user1@example.com'
        $script:savedConfig.GlobalSettings.EmailSettings.To[1] | Should -Be 'user2@example.com'
    }

    It 'should update status text' {
        $script:Controls['txtStatus'].Text | Should -Be 'Settings saved'
    }
}
```

### Test: Settings Panel Control Names

```powershell
Describe 'Settings Panel - Control Names' {
    BeforeAll {
        $xamlPath = Join-Path $PSScriptRoot '..\..\src\Robocurse\Resources\MainWindow.xaml'
        $xamlContent = Get-Content $xamlPath -Raw
        $script:window = [System.Windows.Markup.XamlReader]::Parse($xamlContent)
    }

    @(
        'sldSettingsJobs', 'txtSettingsJobs',
        'sldSettingsThreads', 'txtSettingsThreads',
        'txtSettingsBandwidth', 'txtSettingsLogPath',
        'btnSettingsLogBrowse', 'chkSettingsSiem',
        'txtSettingsSiemPath', 'chkSettingsEmailEnabled',
        'txtSettingsSmtp', 'txtSettingsSmtpPort',
        'chkSettingsTls', 'txtSettingsCredential',
        'txtSettingsEmailFrom', 'txtSettingsEmailTo',
        'btnSettingsSchedule', 'txtSettingsScheduleStatus',
        'btnSettingsRevert', 'btnSettingsSave'
    ) | ForEach-Object {
        It "should have control '$_'" {
            $script:window.FindName($_) | Should -Not -BeNullOrEmpty
        }
    }
}
```

## Success Criteria

1. **Settings panel displays**: All controls render correctly
2. **Load from config**: Switching to Settings panel loads current values
3. **Sliders update display**: Slider movement updates text value
4. **Browse buttons work**: Open folder browser dialogs
5. **Save works**: Clicking Save writes to config file
6. **Revert works**: Clicking Revert reloads from file
7. **Schedule status shows**: Displays current schedule status
8. **Schedule button works**: Opens schedule configuration dialog
9. **All unit tests pass**: GuiSettingsPanel.Tests.ps1 passes completely

## Testing

1. Build and run
2. Switch to Settings panel
3. Verify all values loaded from config
4. Change slider values - verify text updates
5. Change text values
6. Click Save - verify config file updated
7. Change values again
8. Click Revert - verify original values restored
9. Click Configure Schedule - verify dialog opens

## Notes

- **Explicit Save**: Unlike profiles, settings require clicking Save. This prevents accidental changes to critical settings.
- **Validation**: Add validation for numeric fields (port, bandwidth) before saving.
- **ScrollViewer**: Settings panel has ScrollViewer in case window is small.
- **Email To field**: Comma-separated, parsed to array on save.
