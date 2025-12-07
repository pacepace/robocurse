# Task: Clickable Error Status Indicator

## Objective
Transform the status bar error indicator from a passive text display into an interactive element that allows users to view error details during an active replication run.

## Problem Statement
Currently when errors occur during replication:
- Status bar turns OrangeRed and shows "(3 error(s))"
- User cannot click to see what the errors are
- Must wait for completion or manually check logs panel
- No quick "at a glance" error summary

## Success Criteria
1. Status bar error text becomes clickable when errors > 0
2. Clicking opens a popup/flyout showing last N errors (max 10)
3. Each error shows: timestamp, chunk ID, brief message
4. Popup auto-closes when clicking elsewhere
5. Visual affordance (underline or cursor change) indicates clickability
6. Popup matches app dark theme
7. All tests pass

## Research: Current Implementation

### Status Bar Location (MainWindow.xaml:701-703)
```xml
<!-- Status text -->
<TextBlock Grid.Column="1" x:Name="txtStatus" Text="Ready"
           Foreground="#808080" VerticalAlignment="Center" Margin="15,0"/>
```

### Error Tracking (GuiProgress.ps1:274-286)
```powershell
# Dequeue errors (thread-safe) and update error indicator
if ($script:OrchestrationState) {
    $errors = $script:OrchestrationState.DequeueErrors()
    foreach ($err in $errors) {
        Write-GuiLog "[ERROR] $err"
        $script:GuiErrorCount++
    }

    # Update status bar with error indicator if errors occurred
    if ($script:GuiErrorCount -gt 0) {
        $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::OrangeRed
        $script:Controls.txtStatus.Text = "Replication in progress... ($($script:GuiErrorCount) error(s))"
    }
}
```

### Error Message Format
Errors are enqueued from `Invoke-FailedChunkHandler` (JobManagement.ps1:743-744):
```powershell
$errorMsg = "Chunk $($chunk.ChunkId) failed: $($chunk.SourcePath) - $($Result.ExitMeaning.Message) (Exit code: $($Result.ExitCode))"
$script:OrchestrationState.EnqueueError($errorMsg)
```

## Implementation Plan

### Step 1: Add Error History Buffer
Create a ring buffer to store recent errors for display (not just count):

```powershell
# In GuiProgress.ps1 - add at module scope
$script:ErrorHistoryBuffer = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:MaxErrorHistoryItems = 10

function Add-ErrorToHistory {
    param([string]$Message)

    $entry = [PSCustomObject]@{
        Timestamp = [datetime]::Now.ToString('HH:mm:ss')
        Message = $Message
    }

    $script:ErrorHistoryBuffer.Add($entry)

    # Trim to max size
    while ($script:ErrorHistoryBuffer.Count -gt $script:MaxErrorHistoryItems) {
        $script:ErrorHistoryBuffer.RemoveAt(0)
    }
}
```

### Step 2: Update Error Dequeue to Store History
Modify the error dequeue section in `Update-GuiProgress`:

```powershell
$errors = $script:OrchestrationState.DequeueErrors()
foreach ($err in $errors) {
    Write-GuiLog "[ERROR] $err"
    Add-ErrorToHistory -Message $err  # NEW
    $script:GuiErrorCount++
}
```

### Step 3: Create Error Popup XAML Resource
Add `src/Robocurse/Resources/ErrorPopup.xaml`:

```xml
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="popupBorder"
        Background="#1E1E1E"
        BorderBrush="#3E3E3E"
        BorderThickness="1"
        CornerRadius="6"
        Padding="12"
        MaxWidth="500"
        MaxHeight="300">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
            <TextBlock Text="Recent Errors" FontWeight="Bold" FontSize="14"
                       Foreground="#FF6B6B"/>
            <TextBlock x:Name="txtErrorCount" Text=" (0)" FontSize="14"
                       Foreground="#808080" Margin="4,0,0,0"/>
        </StackPanel>

        <!-- Error list -->
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <ItemsControl x:Name="lstErrors">
                <ItemsControl.ItemTemplate>
                    <DataTemplate>
                        <Border Background="#252525" CornerRadius="4" Padding="8" Margin="0,0,0,6">
                            <StackPanel>
                                <TextBlock Text="{Binding Timestamp}" Foreground="#808080"
                                           FontSize="10" FontFamily="Consolas"/>
                                <TextBlock Text="{Binding Message}" Foreground="#E0E0E0"
                                           TextWrapping="Wrap" FontSize="12" Margin="0,4,0,0"/>
                            </StackPanel>
                        </Border>
                    </DataTemplate>
                </ItemsControl.ItemTemplate>
            </ItemsControl>
        </ScrollViewer>
    </Grid>
</Border>
```

### Step 4: Replace TextBlock with Clickable Button
Update MainWindow.xaml status bar:

```xml
<!-- Status text - now a button when errors exist -->
<Button Grid.Column="1" x:Name="btnStatus"
        Background="Transparent"
        BorderThickness="0"
        HorizontalContentAlignment="Left"
        Margin="15,0"
        Cursor="Arrow">
    <Button.Style>
        <Style TargetType="Button">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <TextBlock x:Name="txtStatusInner" Text="{TemplateBinding Content}"
                                   Foreground="#808080" VerticalAlignment="Center"/>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="txtStatusInner" Property="TextDecorations"
                                        Value="Underline"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Button.Style>
</Button>
```

### Step 5: Create Show/Hide Popup Functions
Add to GuiProgress.ps1:

```powershell
function Show-ErrorPopup {
    <#
    .SYNOPSIS
        Shows the error history popup near the status bar
    #>
    [CmdletBinding()]
    param()

    if ($script:ErrorHistoryBuffer.Count -eq 0) {
        return
    }

    try {
        # Load popup XAML
        $xaml = Get-XamlResource -ResourceName 'ErrorPopup.xaml'
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $popup = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()

        # Get controls
        $txtErrorCount = $popup.FindName("txtErrorCount")
        $lstErrors = $popup.FindName("lstErrors")

        # Populate
        $txtErrorCount.Text = " ($($script:GuiErrorCount))"
        $lstErrors.ItemsSource = @($script:ErrorHistoryBuffer | ForEach-Object { $_ })

        # Create popup window
        $popupWindow = New-Object System.Windows.Window
        $popupWindow.WindowStyle = 'None'
        $popupWindow.AllowsTransparency = $true
        $popupWindow.Background = [System.Windows.Media.Brushes]::Transparent
        $popupWindow.ResizeMode = 'NoResize'
        $popupWindow.Topmost = $true
        $popupWindow.SizeToContent = 'WidthAndHeight'
        $popupWindow.Content = $popup

        # Position near status bar
        $statusButton = $script:Controls.btnStatus
        $point = $statusButton.PointToScreen([System.Windows.Point]::new(0, 0))
        $popupWindow.Left = $point.X
        $popupWindow.Top = $point.Y - 320  # Above the status bar

        # Close on deactivate
        $popupWindow.Add_Deactivated({
            $popupWindow.Close()
        })

        # Close on Escape
        $popupWindow.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                $popupWindow.Close()
            }
        })

        $popupWindow.Show()
        $popupWindow.Activate()

        $script:CurrentErrorPopup = $popupWindow
    }
    catch {
        Write-GuiLog "Error showing error popup: $($_.Exception.Message)"
    }
}

function Close-ErrorPopup {
    if ($script:CurrentErrorPopup -and $script:CurrentErrorPopup.IsVisible) {
        $script:CurrentErrorPopup.Close()
    }
    $script:CurrentErrorPopup = $null
}
```

### Step 6: Wire Up Click Handler
In GuiMain.ps1 (during control binding):

```powershell
# Error status click handler
$script:Controls.btnStatus.Add_Click({
    if ($script:GuiErrorCount -gt 0) {
        if ($script:CurrentErrorPopup -and $script:CurrentErrorPopup.IsVisible) {
            Close-ErrorPopup
        } else {
            Show-ErrorPopup
        }
    }
})
```

### Step 7: Update Cursor Based on Error State
In Update-GuiProgress, after updating error text:

```powershell
if ($script:GuiErrorCount -gt 0) {
    $script:Controls.btnStatus.Cursor = [System.Windows.Input.Cursors]::Hand
    $script:Controls.btnStatus.Foreground = [System.Windows.Media.Brushes]::OrangeRed
    $script:Controls.btnStatus.Content = "Replication in progress... ($($script:GuiErrorCount) error(s))"
} else {
    $script:Controls.btnStatus.Cursor = [System.Windows.Input.Cursors]::Arrow
}
```

## Test Plan

Create `tests/Unit/GuiErrorIndicator.Tests.ps1`:

```powershell
#Requires -Modules Pester

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "Error Status Indicator Tests" {

        BeforeAll {
            $script:ErrorHistoryBuffer = [System.Collections.Generic.List[PSCustomObject]]::new()
            $script:MaxErrorHistoryItems = 10
        }

        AfterEach {
            $script:ErrorHistoryBuffer.Clear()
        }

        Context "Add-ErrorToHistory" {
            It "Should add error entry with timestamp" {
                Add-ErrorToHistory -Message "Test error message"

                $script:ErrorHistoryBuffer.Count | Should -Be 1
                $script:ErrorHistoryBuffer[0].Message | Should -Be "Test error message"
                $script:ErrorHistoryBuffer[0].Timestamp | Should -Match '\d{2}:\d{2}:\d{2}'
            }

            It "Should maintain max 10 items in buffer" {
                for ($i = 1; $i -le 15; $i++) {
                    Add-ErrorToHistory -Message "Error $i"
                }

                $script:ErrorHistoryBuffer.Count | Should -Be 10
                $script:ErrorHistoryBuffer[0].Message | Should -Be "Error 6"  # Oldest after trim
                $script:ErrorHistoryBuffer[9].Message | Should -Be "Error 15" # Newest
            }

            It "Should preserve chronological order" {
                Add-ErrorToHistory -Message "First"
                Start-Sleep -Milliseconds 10
                Add-ErrorToHistory -Message "Second"
                Start-Sleep -Milliseconds 10
                Add-ErrorToHistory -Message "Third"

                $script:ErrorHistoryBuffer[0].Message | Should -Be "First"
                $script:ErrorHistoryBuffer[2].Message | Should -Be "Third"
            }
        }

        Context "Error History Integration with Update-GuiProgress" {
            BeforeEach {
                Initialize-OrchestrationState
                $script:GuiErrorCount = 0
                $script:ErrorHistoryBuffer.Clear()

                # Mock GUI controls
                $script:Controls = @{
                    txtStatus = [PSCustomObject]@{
                        Text = "Ready"
                        Foreground = $null
                    }
                    dgChunks = [PSCustomObject]@{ ItemsSource = $null }
                }
                $script:Window = New-Object PSCustomObject
                $script:Window | Add-Member -MemberType ScriptMethod -Name UpdateLayout -Value {} -Force
            }

            It "Should populate error history from dequeued errors" {
                $script:OrchestrationState.EnqueueError("Chunk 1 failed: Access denied")
                $script:OrchestrationState.EnqueueError("Chunk 2 failed: Disk full")

                # Simulate what Update-GuiProgress does
                $errors = $script:OrchestrationState.DequeueErrors()
                foreach ($err in $errors) {
                    Add-ErrorToHistory -Message $err
                    $script:GuiErrorCount++
                }

                $script:ErrorHistoryBuffer.Count | Should -Be 2
                $script:GuiErrorCount | Should -Be 2
            }
        }
    }
}
```

## Files to Modify
1. `src/Robocurse/Public/GuiProgress.ps1` - Add error history buffer and popup functions
2. `src/Robocurse/Resources/MainWindow.xaml` - Convert status TextBlock to Button
3. `src/Robocurse/Resources/ErrorPopup.xaml` - New popup template
4. `src/Robocurse/Public/GuiMain.ps1` - Wire up click handler
5. `tests/Unit/GuiErrorIndicator.Tests.ps1` - New test file

## Verification Commands
```powershell
.\scripts\run-tests.ps1
Invoke-Pester -Path tests\Unit\GuiErrorIndicator.Tests.ps1 -Output Detailed
```

## Notes
- Popup is positioned above status bar to avoid covering bottom controls
- Uses WPF Popup pattern (separate window) for proper layering
- Auto-closes on deactivate prevents orphaned popups
- Ring buffer prevents unbounded memory growth during long runs
- Matches existing dialog patterns (ConfirmDialog, CompletionDialog)
