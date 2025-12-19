# Task: GUI Snapshot Actions

## Objective
Implement the Create and Delete snapshot actions for the Snapshots panel, including dialogs for user input and confirmation.

## Success Criteria
- [ ] "Create Snapshot" button opens dialog to select volume/server
- [ ] Dialog validates input and shows progress
- [ ] "Delete Selected" button confirms before deleting
- [ ] Both actions refresh the snapshot list on completion
- [ ] Error messages displayed in user-friendly dialogs
- [ ] Tests verify dialog behavior and action execution

## Research

### Existing Dialog Patterns (file:line references)
- `GuiDialogs.ps1` - Dialog utility functions
- `Resources/ConfirmDialog.xaml` - Confirmation dialog template
- `Resources/AlertDialog.xaml` - Alert/error dialog template
- `GuiMain.ps1:173-212` - `Invoke-SafeEventHandler` pattern

### Existing Button Wiring Pattern
```powershell
$script:Controls['btnSomeAction'].Add_Click({
    Invoke-SafeEventHandler -HandlerName "SomeAction" -ScriptBlock {
        # Action logic here
    }
})
```

### Dialog Show Pattern
```powershell
$result = Show-ConfirmDialog -Title "Confirm Action" -Message "Are you sure?" -OkText "Yes" -CancelText "No"
if ($result -eq 'OK') {
    # User confirmed
}
```

## Implementation

### Part 1: Create Snapshot Dialog XAML

#### File: `src\Robocurse\Resources\CreateSnapshotDialog.xaml` (NEW FILE)

```xml
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Create VSS Snapshot"
        Width="400" Height="280"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        Background="#1E1E1E">

    <Window.Resources>
        <!-- Inherit dark theme styles -->
        <Style x:Key="DialogLabel" TargetType="Label">
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
        <Style x:Key="DialogComboBox" TargetType="ComboBox">
            <Setter Property="Background" Value="#2D2D2D"/>
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="BorderBrush" Value="#3D3D3D"/>
            <Setter Property="Height" Value="28"/>
        </Style>
        <Style x:Key="DialogButton" TargetType="Button">
            <Setter Property="Background" Value="#0078D4"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="15,8"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
    </Window.Resources>

    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <TextBlock Grid.Row="0" Text="Create a new VSS snapshot" Foreground="#E0E0E0" FontSize="14" Margin="0,0,0,15"/>

        <!-- Server Selection -->
        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,5">
            <Label Content="Server:" Style="{StaticResource DialogLabel}" Width="80"/>
            <ComboBox x:Name="cmbDialogServer" Width="250" Style="{StaticResource DialogComboBox}">
                <ComboBoxItem Content="Local" IsSelected="True"/>
            </ComboBox>
        </StackPanel>

        <!-- Volume Selection -->
        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,10">
            <Label Content="Volume:" Style="{StaticResource DialogLabel}" Width="80"/>
            <ComboBox x:Name="cmbDialogVolume" Width="250" Style="{StaticResource DialogComboBox}"/>
        </StackPanel>

        <!-- Retention Option -->
        <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,10">
            <CheckBox x:Name="chkEnforceRetention" Content="Enforce retention before creating"
                      Foreground="#E0E0E0" IsChecked="True" VerticalAlignment="Center"/>
            <TextBox x:Name="txtRetentionCount" Text="3" Width="40" Margin="10,0"
                     Background="#2D2D2D" Foreground="#E0E0E0" BorderBrush="#3D3D3D"
                     TextAlignment="Center" VerticalContentAlignment="Center"/>
            <Label Content="snapshots" Style="{StaticResource DialogLabel}"/>
        </StackPanel>

        <!-- Status Message -->
        <TextBlock x:Name="txtDialogStatus" Grid.Row="4" Foreground="#888888"
                   TextWrapping="Wrap" Margin="0,10"/>

        <!-- Buttons -->
        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnDialogCancel" Content="Cancel" Width="80"
                    Background="#3D3D3D" Foreground="#E0E0E0" BorderThickness="0" Padding="15,8" Cursor="Hand"/>
            <Button x:Name="btnDialogCreate" Content="Create" Width="100" Margin="10,0,0,0"
                    Style="{StaticResource DialogButton}"/>
        </StackPanel>
    </Grid>
</Window>
```

### Part 2: Dialog Logic

#### File: `src\Robocurse\Public\GuiSnapshotDialogs.ps1` (NEW FILE)

```powershell
# Robocurse GUI Snapshot Dialogs
# Handles create/delete snapshot dialogs

function Show-CreateSnapshotDialog {
    <#
    .SYNOPSIS
        Shows the Create Snapshot dialog and returns the result
    .OUTPUTS
        PSCustomObject with: Success, Volume, ServerName, EnforceRetention, KeepCount
        or $null if cancelled
    #>
    [CmdletBinding()]
    param()

    try {
        # Load dialog XAML
        $xamlPath = Join-Path $PSScriptRoot "..\Resources\CreateSnapshotDialog.xaml"
        $xaml = Get-Content $xamlPath -Raw
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)

        # Get controls
        $cmbServer = $dialog.FindName('cmbDialogServer')
        $cmbVolume = $dialog.FindName('cmbDialogVolume')
        $chkRetention = $dialog.FindName('chkEnforceRetention')
        $txtRetention = $dialog.FindName('txtRetentionCount')
        $txtStatus = $dialog.FindName('txtDialogStatus')
        $btnCancel = $dialog.FindName('btnDialogCancel')
        $btnCreate = $dialog.FindName('btnDialogCreate')

        # Populate servers from main panel
        $mainServerCombo = $script:Controls['cmbSnapshotServer']
        foreach ($item in $mainServerCombo.Items) {
            $newItem = [System.Windows.Controls.ComboBoxItem]::new()
            $newItem.Content = $item.Content
            $cmbServer.Items.Add($newItem) | Out-Null
        }
        $cmbServer.SelectedIndex = 0

        # Populate volumes
        $volumes = Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } |
            Sort-Object DriveLetter
        foreach ($vol in $volumes) {
            $item = [System.Windows.Controls.ComboBoxItem]::new()
            $item.Content = $vol.DriveLetter
            $cmbVolume.Items.Add($item) | Out-Null
        }
        if ($cmbVolume.Items.Count -gt 0) {
            $cmbVolume.SelectedIndex = 0
        }

        # Result variable
        $script:DialogResult = $null

        # Button handlers
        $btnCancel.Add_Click({
            $dialog.DialogResult = $false
            $dialog.Close()
        })

        $btnCreate.Add_Click({
            # Validate
            if ($cmbVolume.SelectedItem -eq $null) {
                $txtStatus.Text = "Please select a volume"
                $txtStatus.Foreground = [System.Windows.Media.Brushes]::OrangeRed
                return
            }

            $keepCount = 0
            if ($chkRetention.IsChecked -and -not [int]::TryParse($txtRetention.Text, [ref]$keepCount)) {
                $txtStatus.Text = "Invalid retention count"
                $txtStatus.Foreground = [System.Windows.Media.Brushes]::OrangeRed
                return
            }

            $script:DialogResult = [PSCustomObject]@{
                Success = $true
                Volume = $cmbVolume.SelectedItem.Content
                ServerName = $cmbServer.SelectedItem.Content
                EnforceRetention = $chkRetention.IsChecked
                KeepCount = $keepCount
            }

            $dialog.DialogResult = $true
            $dialog.Close()
        })

        # Show dialog
        $dialog.Owner = $script:Window
        $result = $dialog.ShowDialog()

        if ($result -eq $true) {
            return $script:DialogResult
        }
        return $null
    }
    catch {
        Write-RobocurseLog -Message "Error showing create snapshot dialog: $($_.Exception.Message)" -Level 'Error' -Component 'GUI'
        return $null
    }
}

function Invoke-CreateSnapshotFromDialog {
    <#
    .SYNOPSIS
        Creates a snapshot based on dialog input
    .PARAMETER DialogResult
        The result from Show-CreateSnapshotDialog
    .OUTPUTS
        OperationResult
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$DialogResult
    )

    $volume = $DialogResult.Volume
    $serverName = $DialogResult.ServerName
    $isLocal = ($serverName -eq "Local")

    Write-RobocurseLog -Message "Creating snapshot: Volume=$volume, Server=$serverName" -Level 'Info' -Component 'GUI'

    try {
        # Enforce retention if requested
        if ($DialogResult.EnforceRetention) {
            Write-RobocurseLog -Message "Enforcing retention (keep $($DialogResult.KeepCount))" -Level 'Debug' -Component 'GUI'

            if ($isLocal) {
                $retResult = Invoke-VssRetentionPolicy -Volume $volume -KeepCount $DialogResult.KeepCount
            }
            else {
                $retResult = Invoke-RemoteVssRetentionPolicy -ServerName $serverName -Volume $volume -KeepCount $DialogResult.KeepCount
            }

            if (-not $retResult.Success) {
                Write-RobocurseLog -Message "Retention enforcement failed: $($retResult.ErrorMessage)" -Level 'Warning' -Component 'GUI'
                # Continue anyway - snapshot might still work
            }
        }

        # Create snapshot
        if ($isLocal) {
            $result = New-VssSnapshot -SourcePath "$volume\"
        }
        else {
            # For remote, we need to construct a UNC path
            # Use admin share format: \\server\D$
            $uncPath = "\\$serverName\$($volume -replace ':', '$')"
            $result = New-RemoteVssSnapshot -UncPath $uncPath
        }

        if ($result.Success) {
            Write-RobocurseLog -Message "Snapshot created: $($result.Data.ShadowId)" -Level 'Info' -Component 'GUI'
        }

        return $result
    }
    catch {
        Write-RobocurseLog -Message "Failed to create snapshot: $($_.Exception.Message)" -Level 'Error' -Component 'GUI'
        return New-OperationResult -Success $false -ErrorMessage $_.Exception.Message -ErrorRecord $_
    }
}

function Show-DeleteSnapshotConfirmation {
    <#
    .SYNOPSIS
        Shows confirmation dialog for snapshot deletion
    .PARAMETER Snapshot
        The snapshot object to delete
    .OUTPUTS
        $true if user confirmed, $false otherwise
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Snapshot
    )

    $volume = $Snapshot.SourceVolume
    $created = $Snapshot.CreatedAt.ToString('yyyy-MM-dd HH:mm')
    $server = $Snapshot.ServerName
    $shadowId = $Snapshot.ShadowId

    $message = @"
Are you sure you want to delete this snapshot?

Volume: $volume
Created: $created
Server: $server
Shadow ID: $shadowId

This action cannot be undone.
"@

    $result = [System.Windows.MessageBox]::Show(
        $message,
        "Confirm Delete Snapshot",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )

    return ($result -eq [System.Windows.MessageBoxResult]::Yes)
}

function Invoke-DeleteSelectedSnapshot {
    <#
    .SYNOPSIS
        Deletes the currently selected snapshot
    .OUTPUTS
        OperationResult
    #>
    [CmdletBinding()]
    param()

    $snapshot = Get-SelectedSnapshot
    if (-not $snapshot) {
        return New-OperationResult -Success $false -ErrorMessage "No snapshot selected"
    }

    # Confirm
    if (-not (Show-DeleteSnapshotConfirmation -Snapshot $snapshot)) {
        return New-OperationResult -Success $true -Data "Cancelled"
    }

    Write-RobocurseLog -Message "Deleting snapshot: $($snapshot.ShadowId)" -Level 'Info' -Component 'GUI'

    try {
        if ($snapshot.ServerName -eq "Local") {
            $result = Remove-VssSnapshot -ShadowId $snapshot.ShadowId
        }
        else {
            $result = Remove-RemoteVssSnapshot -ShadowId $snapshot.ShadowId -ServerName $snapshot.ServerName
        }

        if ($result.Success) {
            Write-RobocurseLog -Message "Snapshot deleted" -Level 'Info' -Component 'GUI'
        }
        else {
            Write-RobocurseLog -Message "Failed to delete snapshot: $($result.ErrorMessage)" -Level 'Error' -Component 'GUI'
        }

        return $result
    }
    catch {
        Write-RobocurseLog -Message "Error deleting snapshot: $($_.Exception.Message)" -Level 'Error' -Component 'GUI'
        return New-OperationResult -Success $false -ErrorMessage $_.Exception.Message -ErrorRecord $_
    }
}
```

### Part 3: Wire Buttons in GuiSnapshots.ps1

#### File: `src\Robocurse\Public\GuiSnapshots.ps1`

**Add to `Initialize-SnapshotsPanel`:**

```powershell
# Wire Create Snapshot button
$script:Controls['btnCreateSnapshot'].Add_Click({
    Invoke-SafeEventHandler -HandlerName "CreateSnapshot" -ScriptBlock {
        $dialogResult = Show-CreateSnapshotDialog
        if ($dialogResult) {
            # Disable buttons during operation
            $script:Controls['btnCreateSnapshot'].IsEnabled = $false
            $script:Controls['btnDeleteSnapshot'].IsEnabled = $false

            try {
                $result = Invoke-CreateSnapshotFromDialog -DialogResult $dialogResult

                if ($result.Success) {
                    [System.Windows.MessageBox]::Show(
                        "Snapshot created successfully.`n`nShadow ID: $($result.Data.ShadowId)",
                        "Snapshot Created",
                        [System.Windows.MessageBoxButton]::OK,
                        [System.Windows.MessageBoxImage]::Information
                    )
                }
                else {
                    [System.Windows.MessageBox]::Show(
                        "Failed to create snapshot:`n`n$($result.ErrorMessage)",
                        "Error",
                        [System.Windows.MessageBoxButton]::OK,
                        [System.Windows.MessageBoxImage]::Error
                    )
                }
            }
            finally {
                # Re-enable and refresh
                $script:Controls['btnCreateSnapshot'].IsEnabled = $true
                Update-SnapshotList
            }
        }
    }
})

# Wire Delete Snapshot button
$script:Controls['btnDeleteSnapshot'].Add_Click({
    Invoke-SafeEventHandler -HandlerName "DeleteSnapshot" -ScriptBlock {
        $result = Invoke-DeleteSelectedSnapshot

        if ($result.Success -and $result.Data -ne "Cancelled") {
            # Refresh list
            Update-SnapshotList
        }
        elseif (-not $result.Success) {
            [System.Windows.MessageBox]::Show(
                "Failed to delete snapshot:`n`n$($result.ErrorMessage)",
                "Error",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
        }
    }
})
```

## Test Plan

### File: `tests\Unit\GuiSnapshotDialogs.Tests.ps1`

```powershell
BeforeAll {
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Utility.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Logging.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssCore.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssLocal.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssRemote.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\GuiSnapshotDialogs.ps1"

    Mock Write-RobocurseLog {}
}

Describe "Invoke-CreateSnapshotFromDialog" {
    Context "Local snapshot creation" {
        BeforeAll {
            Mock Invoke-VssRetentionPolicy { New-OperationResult -Success $true -Data @{ DeletedCount = 0 } }
            Mock New-VssSnapshot { New-OperationResult -Success $true -Data @{ ShadowId = "{new-snap}" } }
        }

        It "Creates local snapshot without retention" {
            $dialogResult = [PSCustomObject]@{
                Volume = "D:"
                ServerName = "Local"
                EnforceRetention = $false
                KeepCount = 3
            }

            $result = Invoke-CreateSnapshotFromDialog -DialogResult $dialogResult
            $result.Success | Should -Be $true

            Should -Not -Invoke Invoke-VssRetentionPolicy
            Should -Invoke New-VssSnapshot -Times 1
        }

        It "Enforces retention before creating when requested" {
            $dialogResult = [PSCustomObject]@{
                Volume = "D:"
                ServerName = "Local"
                EnforceRetention = $true
                KeepCount = 5
            }

            $result = Invoke-CreateSnapshotFromDialog -DialogResult $dialogResult

            Should -Invoke Invoke-VssRetentionPolicy -Times 1 -ParameterFilter {
                $Volume -eq "D:" -and $KeepCount -eq 5
            }
        }
    }

    Context "Remote snapshot creation" {
        BeforeAll {
            Mock Invoke-RemoteVssRetentionPolicy { New-OperationResult -Success $true }
            Mock New-RemoteVssSnapshot { New-OperationResult -Success $true -Data @{ ShadowId = "{remote-snap}" } }
        }

        It "Uses remote functions for non-local server" {
            $dialogResult = [PSCustomObject]@{
                Volume = "E:"
                ServerName = "FileServer01"
                EnforceRetention = $true
                KeepCount = 3
            }

            $result = Invoke-CreateSnapshotFromDialog -DialogResult $dialogResult
            $result.Success | Should -Be $true

            Should -Invoke Invoke-RemoteVssRetentionPolicy -ParameterFilter {
                $ServerName -eq "FileServer01"
            }
            Should -Invoke New-RemoteVssSnapshot -Times 1
        }
    }
}

Describe "Invoke-DeleteSelectedSnapshot" {
    BeforeAll {
        Mock Get-SelectedSnapshot {
            [PSCustomObject]@{
                ShadowId = "{delete-me}"
                SourceVolume = "C:"
                ServerName = "Local"
                CreatedAt = (Get-Date)
            }
        }
        Mock Show-DeleteSnapshotConfirmation { $true }
        Mock Remove-VssSnapshot { New-OperationResult -Success $true -Data "{delete-me}" }
    }

    It "Deletes snapshot when confirmed" {
        $result = Invoke-DeleteSelectedSnapshot
        $result.Success | Should -Be $true
        Should -Invoke Remove-VssSnapshot -Times 1
    }

    Context "When user cancels" {
        BeforeAll {
            Mock Show-DeleteSnapshotConfirmation { $false }
        }

        It "Returns success without deleting" {
            $result = Invoke-DeleteSelectedSnapshot
            $result.Success | Should -Be $true
            $result.Data | Should -Be "Cancelled"
            Should -Not -Invoke Remove-VssSnapshot
        }
    }

    Context "When no snapshot selected" {
        BeforeAll {
            Mock Get-SelectedSnapshot { $null }
        }

        It "Returns error" {
            $result = Invoke-DeleteSelectedSnapshot
            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Match "No snapshot selected"
        }
    }
}
```

## Files to Create
- `src\Robocurse\Resources\CreateSnapshotDialog.xaml` - Create dialog XAML
- `src\Robocurse\Public\GuiSnapshotDialogs.ps1` - Dialog logic
- `tests\Unit\GuiSnapshotDialogs.Tests.ps1` - Unit tests

## Files to Modify
- `src\Robocurse\Public\GuiSnapshots.ps1` - Wire button handlers
- `src\Robocurse\Robocurse.psd1` - Add GuiSnapshotDialogs.ps1 to module

## Verification
```powershell
# Run unit tests
Invoke-Pester -Path tests\Unit\GuiSnapshotDialogs.Tests.ps1 -Output Detailed

# Manual verification
# 1. Launch GUI
# 2. Go to Snapshots panel
# 3. Click "Create Snapshot" - verify dialog appears
# 4. Select volume, toggle retention, click Create
# 5. Verify snapshot appears in list
# 6. Select snapshot, click "Delete Selected"
# 7. Confirm deletion, verify snapshot removed from list
```

## Dependencies
- Task 01 (VssSnapshotCore) - For `Invoke-VssRetentionPolicy`, `New-VssSnapshot`, `Remove-VssSnapshot`
- Task 02 (VssSnapshotRemote) - For remote equivalents
- Task 05 (GuiSnapshotPanel) - For panel and `Get-SelectedSnapshot`

## Notes
- Dialog uses same dark theme as main window
- Retention checkbox defaults to ON with keep=3
- Remote snapshots use admin share format (\\server\D$) for UNC path
- Confirmation dialog shows full snapshot details before delete
- Buttons disabled during operation to prevent double-clicks
- List auto-refreshes after create/delete operations
