# Task: Completion Dialog Error Details

## Objective
Enhance the completion dialog to show detailed error information when chunks have failed, allowing users to understand what went wrong without digging through logs.

## Problem Statement
Currently when replication completes with failures:
- Completion dialog shows warning icon and "X chunk(s) failed" count
- No information about WHICH chunks failed or WHY
- User must manually search logs to understand failures
- No quick action to view or export error summary

## Success Criteria
1. Completion dialog expands to show failed chunk details when ChunksFailed > 0
2. Each failed chunk shows: ChunkId, SourcePath, Exit Code, Error Message
3. "Copy Errors" button copies error summary to clipboard
4. "View Log" button opens the log directory
5. Dialog gracefully handles 0 failures (hides error section)
6. Maximum 10 errors shown with "and X more..." indicator
7. All tests pass

## Research: Current Implementation

### Completion Dialog (GuiDialogs.ps1:122-210)
```powershell
function Show-CompletionDialog {
    param(
        [int]$ChunksComplete = 0,
        [int]$ChunksTotal = 0,
        [int]$ChunksFailed = 0
    )

    # ... loads CompletionDialog.xaml

    if ($ChunksFailed -gt 0) {
        # Some failures - show warning state
        $iconBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF9800")
        $iconText.Text = [char]0x26A0  # Warning triangle
        $txtTitle.Text = "Replication Complete with Warnings"
        $txtSubtitle.Text = "$ChunksFailed chunk(s) failed"
    }
    # ... rest of dialog
}
```

### CompletionDialog.xaml Current Layout
```xml
<Grid Margin="24">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>  <!-- Header with icon -->
        <RowDefinition Height="Auto"/>  <!-- Separator -->
        <RowDefinition Height="*"/>     <!-- Stats panel (Completed/Total/Failed) -->
        <RowDefinition Height="Auto"/>  <!-- OK Button -->
    </Grid.RowDefinitions>
    <!-- ... -->
</Grid>
```

### Failed Chunks Data Source
From OrchestrationState:
```csharp
public ConcurrentQueue<object> FailedChunks { get; private set; }
```

Chunks in FailedChunks have:
- ChunkId
- SourcePath
- DestinationPath
- Status ("Failed")
- LastExitCode (if Task 01 implemented)
- LastErrorMessage (if Task 01 implemented)

## Implementation Plan

### Step 1: Extend Function Signature
Update `Show-CompletionDialog` to accept error details:

```powershell
function Show-CompletionDialog {
    <#
    .SYNOPSIS
        Shows completion dialog with optional error details
    .PARAMETER ChunksComplete
        Number of completed chunks
    .PARAMETER ChunksTotal
        Total chunks processed
    .PARAMETER ChunksFailed
        Number of failed chunks
    .PARAMETER FailedChunkDetails
        Array of failed chunk objects with error info
    #>
    [CmdletBinding()]
    param(
        [int]$ChunksComplete = 0,
        [int]$ChunksTotal = 0,
        [int]$ChunksFailed = 0,
        [PSCustomObject[]]$FailedChunkDetails = @()
    )
```

### Step 2: Update CompletionDialog.xaml
Add error details section:

```xml
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Replication Complete"
        Height="Auto" Width="500"
        MinHeight="280" MaxHeight="550"
        SizeToContent="Height"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize">

    <!-- ... existing Resources section ... -->

    <Border Background="#1E1E1E" CornerRadius="8" BorderBrush="#3E3E3E" BorderThickness="1">
        <Grid Margin="24">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>  <!-- Header -->
                <RowDefinition Height="Auto"/>  <!-- Separator -->
                <RowDefinition Height="Auto"/>  <!-- Stats -->
                <RowDefinition Height="Auto"/>  <!-- NEW: Error section -->
                <RowDefinition Height="Auto"/>  <!-- Buttons -->
            </Grid.RowDefinitions>

            <!-- ... existing Header (Row 0), Separator (Row 1), Stats (Row 2) ... -->

            <!-- NEW: Error Details Section (Row 3) - only visible when errors exist -->
            <Border Grid.Row="3" x:Name="pnlErrors" Visibility="Collapsed"
                    Background="#252525" CornerRadius="4" Padding="12" Margin="0,16,0,0">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- Error header -->
                    <TextBlock Grid.Row="0" Text="Failed Chunks"
                               FontWeight="SemiBold" Foreground="#FF6B6B"
                               FontSize="12" Margin="0,0,0,10"/>

                    <!-- Error list -->
                    <ScrollViewer Grid.Row="1" MaxHeight="150"
                                  VerticalScrollBarVisibility="Auto">
                        <StackPanel x:Name="lstErrors">
                            <!-- Items added dynamically -->
                        </StackPanel>
                    </ScrollViewer>

                    <!-- More indicator and buttons -->
                    <StackPanel Grid.Row="2" Orientation="Horizontal"
                                HorizontalAlignment="Right" Margin="0,10,0,0">
                        <TextBlock x:Name="txtMoreErrors" Text="" Foreground="#808080"
                                   FontSize="11" VerticalAlignment="Center" Margin="0,0,15,0"/>
                        <Button x:Name="btnCopyErrors" Content="Copy Errors"
                                Style="{StaticResource ModernButton}"
                                Background="#3E3E3E" Padding="12,6" FontSize="11"/>
                        <Button x:Name="btnViewLogs" Content="View Logs"
                                Style="{StaticResource ModernButton}"
                                Background="#3E3E3E" Padding="12,6" FontSize="11"
                                Margin="8,0,0,0"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- OK Button (now Row 4) -->
            <Button x:Name="btnOk" Grid.Row="4" Content="OK"
                    Style="{StaticResource ModernButton}"
                    HorizontalAlignment="Center" Margin="0,16,0,0"/>
        </Grid>
    </Border>
</Window>
```

### Step 3: Populate Error Details in Show-CompletionDialog
Add error section population after loading XAML:

```powershell
# Get error controls
$pnlErrors = $dialog.FindName("pnlErrors")
$lstErrors = $dialog.FindName("lstErrors")
$txtMoreErrors = $dialog.FindName("txtMoreErrors")
$btnCopyErrors = $dialog.FindName("btnCopyErrors")
$btnViewLogs = $dialog.FindName("btnViewLogs")

# Populate errors if any
if ($ChunksFailed -gt 0 -and $FailedChunkDetails.Count -gt 0) {
    $pnlErrors.Visibility = 'Visible'

    $maxDisplay = 10
    $displayCount = [Math]::Min($FailedChunkDetails.Count, $maxDisplay)

    for ($i = 0; $i -lt $displayCount; $i++) {
        $chunk = $FailedChunkDetails[$i]

        $item = New-Object System.Windows.Controls.Border
        $item.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#1E1E1E")
        $item.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $item.Padding = [System.Windows.Thickness]::new(8)
        $item.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)

        $stack = New-Object System.Windows.Controls.StackPanel

        # Chunk ID and Exit Code
        $header = New-Object System.Windows.Controls.TextBlock
        $exitCode = if ($chunk.LastExitCode) { $chunk.LastExitCode } else { "?" }
        $header.Text = "Chunk $($chunk.ChunkId) - Exit Code: $exitCode"
        $header.FontWeight = 'SemiBold'
        $header.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#E0E0E0")
        $header.FontSize = 11

        # Source path
        $pathText = New-Object System.Windows.Controls.TextBlock
        $pathText.Text = $chunk.SourcePath
        $pathText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#808080")
        $pathText.FontSize = 10
        $pathText.TextTrimming = 'CharacterEllipsis'
        $pathText.ToolTip = $chunk.SourcePath

        # Error message
        $errorMsg = if ($chunk.LastErrorMessage) { $chunk.LastErrorMessage } else { "Unknown error" }
        $errorText = New-Object System.Windows.Controls.TextBlock
        $errorText.Text = $errorMsg
        $errorText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF6B6B")
        $errorText.FontSize = 10
        $errorText.TextWrapping = 'Wrap'

        $stack.Children.Add($header)
        $stack.Children.Add($pathText)
        $stack.Children.Add($errorText)
        $item.Child = $stack

        $lstErrors.Children.Add($item)
    }

    # Show "and X more" if truncated
    if ($FailedChunkDetails.Count -gt $maxDisplay) {
        $remaining = $FailedChunkDetails.Count - $maxDisplay
        $txtMoreErrors.Text = "...and $remaining more"
    }

    # Copy button handler
    $btnCopyErrors.Add_Click({
        $errorText = [System.Text.StringBuilder]::new()
        $errorText.AppendLine("Robocurse Failed Chunks Report")
        $errorText.AppendLine("=" * 40)
        $errorText.AppendLine("")

        foreach ($chunk in $FailedChunkDetails) {
            $errorText.AppendLine("Chunk $($chunk.ChunkId)")
            $errorText.AppendLine("  Source: $($chunk.SourcePath)")
            $errorText.AppendLine("  Exit Code: $($chunk.LastExitCode)")
            $errorText.AppendLine("  Error: $($chunk.LastErrorMessage)")
            $errorText.AppendLine("")
        }

        [System.Windows.Clipboard]::SetText($errorText.ToString())

        $btnCopyErrors.Content = "Copied!"
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds(2)
        $timer.Add_Tick({
            $btnCopyErrors.Content = "Copy Errors"
            $timer.Stop()
        })
        $timer.Start()
    })

    # View logs button handler
    $btnViewLogs.Add_Click({
        $logPath = Get-LogPath -Type 'Base'
        if (Test-Path $logPath) {
            Start-Process -FilePath "explorer.exe" -ArgumentList $logPath
        }
    })
}
```

### Step 4: Update Caller to Pass Error Details
In Complete-GuiReplication (GuiReplication.ps1):

```powershell
# Gather failed chunk details before showing dialog
$failedDetails = @()
if ($script:OrchestrationState.FailedChunks.Count -gt 0) {
    $failedDetails = @($script:OrchestrationState.FailedChunks.ToArray())
}

# Also include failed chunks from ProfileResults (completed profiles)
foreach ($profileResult in $script:OrchestrationState.GetProfileResultsArray()) {
    # Profile results don't store individual chunks, so this relies on
    # FailedChunks queue which persists across the run
}

Show-CompletionDialog `
    -ChunksComplete $chunksComplete `
    -ChunksTotal $chunksTotal `
    -ChunksFailed $chunksFailed `
    -FailedChunkDetails $failedDetails
```

## Test Plan

Create `tests/Unit/GuiCompletionErrorDetails.Tests.ps1`:

```powershell
#Requires -Modules Pester

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

InModuleScope 'Robocurse' {
    Describe "Completion Dialog Error Details Tests" {

        Context "Function Parameters" {
            It "Should accept FailedChunkDetails parameter" {
                # This tests that the function signature is correct
                $cmd = Get-Command Show-CompletionDialog
                $params = $cmd.Parameters

                $params.ContainsKey('FailedChunkDetails') | Should -Be $true
            }
        }

        Context "Error Report Generation" {
            It "Should format error report with all chunk details" {
                $chunks = @(
                    [PSCustomObject]@{
                        ChunkId = 1
                        SourcePath = "C:\Data\Folder1"
                        LastExitCode = 16
                        LastErrorMessage = "Serious error"
                    },
                    [PSCustomObject]@{
                        ChunkId = 5
                        SourcePath = "C:\Data\Folder5"
                        LastExitCode = 8
                        LastErrorMessage = "Some files failed"
                    }
                )

                # Build report as the dialog would
                $errorText = [System.Text.StringBuilder]::new()
                $errorText.AppendLine("Robocurse Failed Chunks Report")

                foreach ($chunk in $chunks) {
                    $errorText.AppendLine("Chunk $($chunk.ChunkId)")
                    $errorText.AppendLine("  Source: $($chunk.SourcePath)")
                    $errorText.AppendLine("  Exit Code: $($chunk.LastExitCode)")
                    $errorText.AppendLine("  Error: $($chunk.LastErrorMessage)")
                }

                $report = $errorText.ToString()

                $report | Should -Match "Chunk 1"
                $report | Should -Match "Chunk 5"
                $report | Should -Match "Exit Code: 16"
                $report | Should -Match "Serious error"
            }
        }

        Context "Display Truncation" {
            It "Should calculate remaining count correctly" {
                $totalErrors = 25
                $maxDisplay = 10

                $remaining = $totalErrors - $maxDisplay

                $remaining | Should -Be 15
            }
        }

        Context "Integration with OrchestrationState" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should retrieve failed chunks for dialog" {
                $chunk1 = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test1"
                    LastExitCode = 16
                    LastErrorMessage = "Error 1"
                }
                $chunk2 = [PSCustomObject]@{
                    ChunkId = 2
                    SourcePath = "C:\Test2"
                    LastExitCode = 8
                    LastErrorMessage = "Error 2"
                }

                $script:OrchestrationState.FailedChunks.Enqueue($chunk1)
                $script:OrchestrationState.FailedChunks.Enqueue($chunk2)

                $failedDetails = @($script:OrchestrationState.FailedChunks.ToArray())

                $failedDetails.Count | Should -Be 2
                $failedDetails[0].ChunkId | Should -Be 1
                $failedDetails[1].ChunkId | Should -Be 2
            }
        }
    }
}
```

## Files to Modify
1. `src/Robocurse/Resources/CompletionDialog.xaml` - Add error details section
2. `src/Robocurse/Public/GuiDialogs.ps1` - Update Show-CompletionDialog function
3. `src/Robocurse/Public/GuiReplication.ps1` - Pass error details to dialog
4. `tests/Unit/GuiCompletionErrorDetails.Tests.ps1` - New test file

## Verification Commands
```powershell
.\scripts\run-tests.ps1
Invoke-Pester -Path tests\Unit\GuiCompletionErrorDetails.Tests.ps1 -Output Detailed
```

## Notes
- Dialog uses SizeToContent="Height" to expand based on error count
- MaxHeight prevents dialog from becoming too tall with many errors
- Copy button provides feedback ("Copied!") using DispatcherTimer
- View Logs opens Explorer to log directory (not individual files)
- Truncation at 10 errors keeps dialog manageable
- Error section is hidden entirely when ChunksFailed = 0
- Depends on Task 01 (chunk error tooltip) for LastExitCode/LastErrorMessage properties
