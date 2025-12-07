# Task: Pre-flight Validation UI

## Objective
Add a "Validate" button to the profiles panel that runs pre-flight checks before replication starts, displaying results in a user-friendly manner.

## Problem Statement
Currently, pre-flight validation only runs at the start of replication:
- Source path accessibility is checked in `Start-ProfileReplication`
- Destination disk space is checked (warning only)
- Robocopy options are validated
- Errors discovered at runtime disrupt the workflow

Users have NO way to:
- Test if source paths are accessible before starting
- Preview how directories will be chunked
- Verify VSS will work for a path
- Check destination disk space proactively

## Success Criteria
1. "Validate" button added to profile editor area
2. Clicking shows validation dialog with results for selected profile
3. Checks performed:
   - Source path exists and is accessible
   - Destination path exists (or parent exists for creation)
   - Disk space on destination (warning threshold configurable)
   - VSS availability (if UseVSS enabled)
   - Robocopy binary available
   - Chunk preview (estimated chunk count and sizes)
4. Results shown with status icons (green check, yellow warning, red X)
5. Dialog matches app dark theme
6. All tests pass

## Research: Current Implementation

### Pre-flight Checks in Start-ProfileReplication (JobManagement.ps1:177-203)
```powershell
# Pre-flight validation: Source path accessibility
$sourceCheck = Test-SourcePathAccessible -Path $Profile.Source
if (-not $sourceCheck.Success) {
    $errorMsg = "Profile '$($Profile.Name)' failed pre-flight check: $($sourceCheck.ErrorMessage)"
    $state.EnqueueError($errorMsg)
    Complete-CurrentProfile  # Skip to next
    return
}

# Pre-flight validation: Destination disk space (warning only)
$diskCheck = Test-DestinationDiskSpace -Path $Profile.Destination
if (-not $diskCheck.Success) {
    Write-RobocurseLog -Message "Profile '$($Profile.Name)' disk space warning: $($diskCheck.ErrorMessage)" `
        -Level 'Warning' -Component 'Orchestrator'
}

# Pre-flight validation: Robocopy options
$optionsCheck = Test-RobocopyOptionsValid -Options $robocopyOptions
if (-not $optionsCheck.Success) {
    Write-RobocurseLog -Message "Profile '$($Profile.Name)' robocopy options warning: $($optionsCheck.ErrorMessage)" `
        -Level 'Warning' -Component 'Orchestrator'
}
```

### Existing Test Functions (Utility.ps1)
```powershell
function Test-SourcePathAccessible {
    param([string]$Path)
    # Returns: @{ Success = $bool; ErrorMessage = $string; Data = $null }
}

function Test-DestinationDiskSpace {
    param([string]$Path, [long]$RequiredBytes = 0)
    # Returns: @{ Success = $bool; ErrorMessage = $string; Data = @{ FreeBytes = $long } }
}

function Test-RobocopyOptionsValid {
    param([hashtable]$Options)
    # Returns: @{ Success = $bool; ErrorMessage = $string }
}

function Test-RobocopyAvailable {
    # Returns: @{ Success = $bool; ErrorMessage = $string; Data = $robocopyPath }
}
```

### VSS Test (VssCore.ps1)
```powershell
function Test-VssSupported {
    param([string]$Path)
    # Returns $true/$false
}
```

### Profile Editor Location (MainWindow.xaml:283-340)
The profile settings panel has row definitions for Name, Source, Destination, Options, and Chunking.

## Implementation Plan

### Step 1: Create Validation Dialog XAML
Add `src/Robocurse/Resources/ValidationDialog.xaml`:

```xml
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Profile Validation"
        Height="400" Width="500"
        WindowStartupLocation="CenterOwner"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize">

    <Window.Resources>
        <Style x:Key="ModernButton" TargetType="Button">
            <Setter Property="Background" Value="#0078D4"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="20,8"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="#0078D4" CornerRadius="4" Padding="20,8">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#1084D8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Border Background="#1E1E1E" CornerRadius="8" BorderBrush="#3E3E3E" BorderThickness="1">
        <Grid Margin="20">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Header -->
            <StackPanel Grid.Row="0" Margin="0,0,0,15">
                <TextBlock x:Name="txtTitle" Text="Validating Profile..."
                           FontSize="18" FontWeight="SemiBold" Foreground="#E0E0E0"/>
                <TextBlock x:Name="txtSubtitle" Text=""
                           FontSize="12" Foreground="#808080" Margin="0,4,0,0"/>
            </StackPanel>

            <!-- Separator -->
            <Border Grid.Row="1" Height="1" Background="#3E3E3E" Margin="0,0,0,15"/>

            <!-- Validation Results -->
            <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="pnlResults">
                    <!-- Items added dynamically -->
                </StackPanel>
            </ScrollViewer>

            <!-- Button -->
            <Button Grid.Row="3" x:Name="btnClose" Content="Close"
                    Style="{StaticResource ModernButton}"
                    HorizontalAlignment="Center" Margin="0,15,0,0"/>
        </Grid>
    </Border>
</Window>
```

### Step 2: Create Validation Function
Add to a new file `src/Robocurse/Public/GuiValidation.ps1`:

```powershell
function Test-ProfileValidation {
    <#
    .SYNOPSIS
        Runs all pre-flight validation checks for a profile
    .PARAMETER Profile
        Profile object to validate
    .OUTPUTS
        Array of validation result objects
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Profile)

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    # 1. Robocopy available
    $robocopyCheck = Test-RobocopyAvailable
    $results.Add([PSCustomObject]@{
        CheckName = "Robocopy Available"
        Status = if ($robocopyCheck.Success) { 'Pass' } else { 'Fail' }
        Message = if ($robocopyCheck.Success) { "Found at: $($robocopyCheck.Data)" } else { $robocopyCheck.ErrorMessage }
        Severity = if ($robocopyCheck.Success) { 'Success' } else { 'Error' }
    })

    # 2. Source path accessible
    $sourceCheck = Test-SourcePathAccessible -Path $Profile.Source
    $results.Add([PSCustomObject]@{
        CheckName = "Source Path Accessible"
        Status = if ($sourceCheck.Success) { 'Pass' } else { 'Fail' }
        Message = if ($sourceCheck.Success) { $Profile.Source } else { $sourceCheck.ErrorMessage }
        Severity = if ($sourceCheck.Success) { 'Success' } else { 'Error' }
    })

    # 3. Destination path (check parent if doesn't exist)
    $destExists = Test-Path $Profile.Destination
    $destParent = Split-Path $Profile.Destination -Parent
    $destParentExists = Test-Path $destParent

    if ($destExists) {
        $destStatus = 'Pass'
        $destMessage = "Destination exists: $($Profile.Destination)"
        $destSeverity = 'Success'
    } elseif ($destParentExists) {
        $destStatus = 'Warning'
        $destMessage = "Will be created: $($Profile.Destination)"
        $destSeverity = 'Warning'
    } else {
        $destStatus = 'Fail'
        $destMessage = "Parent directory does not exist: $destParent"
        $destSeverity = 'Error'
    }

    $results.Add([PSCustomObject]@{
        CheckName = "Destination Path"
        Status = $destStatus
        Message = $destMessage
        Severity = $destSeverity
    })

    # 4. Disk space (only if source exists)
    if ($sourceCheck.Success) {
        $diskCheck = Test-DestinationDiskSpace -Path $Profile.Destination
        $freeGB = if ($diskCheck.Data.FreeBytes) { [math]::Round($diskCheck.Data.FreeBytes / 1GB, 2) } else { 0 }

        $results.Add([PSCustomObject]@{
            CheckName = "Destination Disk Space"
            Status = if ($diskCheck.Success) { 'Pass' } else { 'Warning' }
            Message = if ($diskCheck.Success) { "Free space: $freeGB GB" } else { $diskCheck.ErrorMessage }
            Severity = if ($diskCheck.Success) { 'Success' } else { 'Warning' }
        })
    }

    # 5. VSS (if enabled)
    if ($Profile.UseVSS) {
        $vssSupported = Test-VssSupported -Path $Profile.Source
        $results.Add([PSCustomObject]@{
            CheckName = "VSS Support"
            Status = if ($vssSupported) { 'Pass' } else { 'Fail' }
            Message = if ($vssSupported) { "VSS is supported for this path" } else { "VSS not available (network path or non-NTFS)" }
            Severity = if ($vssSupported) { 'Success' } else { 'Warning' }
        })
    }

    # 6. Chunk preview (estimate)
    if ($sourceCheck.Success) {
        try {
            $profile = $Profile  # Avoid scoping issues
            $maxChunkBytes = if ($profile.ChunkMaxSizeGB) { $profile.ChunkMaxSizeGB * 1GB } else { 10GB }
            $maxFiles = if ($profile.ChunkMaxFiles) { $profile.ChunkMaxFiles } else { 50000 }

            # Quick profile scan
            $scanResult = Get-DirectoryProfile -Path $Profile.Source

            $estimatedChunks = [math]::Max(1, [math]::Ceiling($scanResult.TotalSize / $maxChunkBytes))
            $totalSizeGB = [math]::Round($scanResult.TotalSize / 1GB, 2)

            $results.Add([PSCustomObject]@{
                CheckName = "Chunk Estimate"
                Status = 'Info'
                Message = "~$estimatedChunks chunks, $totalSizeGB GB total, $($scanResult.FileCount) files"
                Severity = 'Info'
            })
        }
        catch {
            $results.Add([PSCustomObject]@{
                CheckName = "Chunk Estimate"
                Status = 'Warning'
                Message = "Could not scan source: $($_.Exception.Message)"
                Severity = 'Warning'
            })
        }
    }

    return $results.ToArray()
}

function Show-ValidationDialog {
    <#
    .SYNOPSIS
        Shows the validation dialog for a profile
    .PARAMETER Profile
        Profile to validate
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Profile)

    try {
        # Load XAML
        $xaml = Get-XamlResource -ResourceName 'ValidationDialog.xaml'
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()

        # Get controls
        $txtTitle = $dialog.FindName("txtTitle")
        $txtSubtitle = $dialog.FindName("txtSubtitle")
        $pnlResults = $dialog.FindName("pnlResults")
        $btnClose = $dialog.FindName("btnClose")

        $txtTitle.Text = "Profile Validation"
        $txtSubtitle.Text = $Profile.Name

        # Run validation
        $results = Test-ProfileValidation -Profile $Profile

        # Build result items
        foreach ($result in $results) {
            $item = New-Object System.Windows.Controls.Border
            $item.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#252525")
            $item.CornerRadius = [System.Windows.CornerRadius]::new(4)
            $item.Padding = [System.Windows.Thickness]::new(12)
            $item.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)

            $stack = New-Object System.Windows.Controls.StackPanel
            $stack.Orientation = 'Horizontal'

            # Status icon
            $icon = New-Object System.Windows.Controls.TextBlock
            $icon.FontSize = 16
            $icon.Width = 24
            $icon.VerticalAlignment = 'Center'

            switch ($result.Severity) {
                'Success' {
                    $icon.Text = [char]0x2713  # Checkmark
                    $icon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#4CAF50")
                }
                'Warning' {
                    $icon.Text = [char]0x26A0  # Warning triangle
                    $icon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FFB340")
                }
                'Error' {
                    $icon.Text = [char]0x2717  # X mark
                    $icon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF6B6B")
                }
                'Info' {
                    $icon.Text = [char]0x2139  # Info
                    $icon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#0078D4")
                }
            }

            # Text content
            $textStack = New-Object System.Windows.Controls.StackPanel

            $checkName = New-Object System.Windows.Controls.TextBlock
            $checkName.Text = $result.CheckName
            $checkName.FontWeight = 'SemiBold'
            $checkName.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#E0E0E0")

            $message = New-Object System.Windows.Controls.TextBlock
            $message.Text = $result.Message
            $message.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#808080")
            $message.FontSize = 11
            $message.TextWrapping = 'Wrap'
            $message.MaxWidth = 380

            $textStack.Children.Add($checkName)
            $textStack.Children.Add($message)

            $stack.Children.Add($icon)
            $stack.Children.Add($textStack)
            $item.Child = $stack

            $pnlResults.Children.Add($item)
        }

        # Close button
        $btnClose.Add_Click({ $dialog.Close() })

        # Allow dragging
        $dialog.Add_MouseLeftButtonDown({
            param($sender, $e)
            if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
                $dialog.DragMove()
            }
        })

        # Owner for modal
        if ($script:Window) {
            $dialog.Owner = $script:Window
        }

        $dialog.ShowDialog() | Out-Null
    }
    catch {
        Write-GuiLog "Error showing validation dialog: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "Validation failed:`n$($_.Exception.Message)",
            "Error",
            "OK",
            "Error"
        )
    }
}
```

### Step 3: Add Validate Button to Profile Panel
Update MainWindow.xaml profile settings area:

```xml
<!-- After the Chunking row (Row 4), add a new row -->
<Grid.RowDefinitions>
    <RowDefinition Height="Auto"/>  <!-- Name -->
    <RowDefinition Height="Auto"/>  <!-- Source -->
    <RowDefinition Height="Auto"/>  <!-- Dest -->
    <RowDefinition Height="Auto"/>  <!-- Options -->
    <RowDefinition Height="Auto"/>  <!-- Chunking -->
    <RowDefinition Height="Auto"/>  <!-- NEW: Validate button -->
</Grid.RowDefinitions>

<!-- Add validate button row -->
<Button Grid.Row="5" Grid.Column="1" Grid.ColumnSpan="2"
        x:Name="btnValidateProfile"
        Content="Validate Profile"
        Style="{StaticResource DarkButton}"
        HorizontalAlignment="Left"
        Width="130"
        Margin="0,15,0,0"
        ToolTip="Test source/destination accessibility and preview chunks"/>
```

### Step 4: Wire Up Button Handler
In GuiMain.ps1:

```powershell
# Validate profile button
$script:Controls.btnValidateProfile.Add_Click({
    $selectedProfile = $script:Controls.lstProfiles.SelectedItem
    if (-not $selectedProfile) {
        [System.Windows.MessageBox]::Show(
            "Please select a profile to validate.",
            "No Profile Selected",
            "OK",
            "Information"
        )
        return
    }

    Show-ValidationDialog -Profile $selectedProfile
})
```

## Test Plan

Create `tests/Unit/GuiValidation.Tests.ps1`:

```powershell
#Requires -Modules Pester

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

InModuleScope 'Robocurse' {
    Describe "Profile Validation Tests" {

        Context "Test-ProfileValidation" {
            It "Should return Pass for robocopy when available" {
                Mock Test-RobocopyAvailable { @{ Success = $true; Data = "C:\Windows\System32\robocopy.exe" } }
                Mock Test-SourcePathAccessible { @{ Success = $true } }
                Mock Test-Path { $true }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Test"
                    Destination = "D:\Backup"
                    UseVSS = $false
                }

                $results = Test-ProfileValidation -Profile $profile

                $robocopyResult = $results | Where-Object { $_.CheckName -eq "Robocopy Available" }
                $robocopyResult.Status | Should -Be 'Pass'
                $robocopyResult.Severity | Should -Be 'Success'
            }

            It "Should return Fail for inaccessible source" {
                Mock Test-RobocopyAvailable { @{ Success = $true; Data = "robocopy.exe" } }
                Mock Test-SourcePathAccessible {
                    @{ Success = $false; ErrorMessage = "Access denied" }
                }
                Mock Test-Path { $false }

                $profile = [PSCustomObject]@{
                    Name = "BadSource"
                    Source = "C:\NoAccess"
                    Destination = "D:\Backup"
                    UseVSS = $false
                }

                $results = Test-ProfileValidation -Profile $profile

                $sourceResult = $results | Where-Object { $_.CheckName -eq "Source Path Accessible" }
                $sourceResult.Status | Should -Be 'Fail'
                $sourceResult.Severity | Should -Be 'Error'
            }

            It "Should return Warning when destination will be created" {
                Mock Test-RobocopyAvailable { @{ Success = $true; Data = "robocopy.exe" } }
                Mock Test-SourcePathAccessible { @{ Success = $true } }
                Mock Test-Path {
                    param($Path)
                    if ($Path -eq "D:\NewBackup") { return $false }
                    if ($Path -eq "D:\") { return $true }
                    return $false
                }
                Mock Split-Path { "D:\" }

                $profile = [PSCustomObject]@{
                    Name = "NewDest"
                    Source = "C:\Data"
                    Destination = "D:\NewBackup"
                    UseVSS = $false
                }

                $results = Test-ProfileValidation -Profile $profile

                $destResult = $results | Where-Object { $_.CheckName -eq "Destination Path" }
                $destResult.Status | Should -Be 'Warning'
                $destResult.Message | Should -Match "Will be created"
            }

            It "Should check VSS when UseVSS is enabled" {
                Mock Test-RobocopyAvailable { @{ Success = $true; Data = "robocopy.exe" } }
                Mock Test-SourcePathAccessible { @{ Success = $true } }
                Mock Test-Path { $true }
                Mock Test-VssSupported { $true }

                $profile = [PSCustomObject]@{
                    Name = "VssProfile"
                    Source = "C:\Data"
                    Destination = "D:\Backup"
                    UseVSS = $true
                }

                $results = Test-ProfileValidation -Profile $profile

                $vssResult = $results | Where-Object { $_.CheckName -eq "VSS Support" }
                $vssResult | Should -Not -BeNullOrEmpty
                $vssResult.Status | Should -Be 'Pass'
            }

            It "Should not check VSS when UseVSS is disabled" {
                Mock Test-RobocopyAvailable { @{ Success = $true; Data = "robocopy.exe" } }
                Mock Test-SourcePathAccessible { @{ Success = $true } }
                Mock Test-Path { $true }

                $profile = [PSCustomObject]@{
                    Name = "NoVss"
                    Source = "C:\Data"
                    Destination = "D:\Backup"
                    UseVSS = $false
                }

                $results = Test-ProfileValidation -Profile $profile

                $vssResult = $results | Where-Object { $_.CheckName -eq "VSS Support" }
                $vssResult | Should -BeNullOrEmpty
            }
        }
    }
}
```

## Files to Modify
1. `src/Robocurse/Resources/ValidationDialog.xaml` - New dialog template
2. `src/Robocurse/Public/GuiValidation.ps1` - New validation functions
3. `src/Robocurse/Resources/MainWindow.xaml` - Add Validate button
4. `src/Robocurse/Public/GuiMain.ps1` - Wire up button handler
5. `src/Robocurse/Robocurse.psm1` - Add GuiValidation.ps1 to module
6. `tests/Unit/GuiValidation.Tests.ps1` - New test file

## Verification Commands
```powershell
.\scripts\run-tests.ps1
Invoke-Pester -Path tests\Unit\GuiValidation.Tests.ps1 -Output Detailed
```

## Notes
- Chunk estimate uses quick scan (Get-DirectoryProfile) which may take a few seconds for large directories
- VSS check is skipped if UseVSS is false on the profile
- Disk space check returns free bytes which is displayed in GB
- Icons use Unicode characters for cross-platform compatibility within WPF
- Dialog is modal (ShowDialog) to block profile editing while validating
