# Task: Chunk Error Tooltip Display

## Objective
Add tooltip functionality to the chunk DataGrid that displays detailed error information when hovering over failed chunks. Currently, the grid shows "Failed" status but provides no insight into WHY the chunk failed.

## Problem Statement
When a chunk fails, users see:
- Status column: "Failed" (red)
- No error message
- No robocopy exit code
- No guidance on what went wrong

Users must dig through log files to understand failures, which is poor UX for a GUI application.

## Success Criteria
1. Hovering over a failed chunk row displays a tooltip with:
   - Robocopy exit code (e.g., "Exit Code: 16")
   - Exit code meaning (e.g., "Serious error - no files were copied")
   - Last error message from the job
   - Source and destination paths
2. Tooltip does not appear for running or completed chunks (optional: show "In progress..." or "Completed successfully")
3. Tooltip styling matches app dark theme (#1E1E1E background, #E0E0E0 text)
4. All tests pass

## Research: Current Implementation

### Chunk Display Object (GuiProgress.ps1:147-167)
```powershell
# Failed chunks currently only have basic info
$chunkDisplayItems.Add([PSCustomObject]@{
    ChunkId = $chunk.ChunkId
    SourcePath = $chunk.SourcePath
    Status = "Failed"
    Progress = 0
    ProgressScale = [double]0.0
    Speed = "--"
})
```

### DataGrid Definition (MainWindow.xaml:558-593)
```xml
<DataGrid x:Name="dgChunks" AutoGenerateColumns="False"
          Style="{StaticResource DarkDataGrid}"
          IsReadOnly="True" SelectionMode="Single">
    <DataGrid.Columns>
        <DataGridTextColumn Header="ID" Binding="{Binding ChunkId}" Width="50"/>
        <DataGridTextColumn Header="Path" Binding="{Binding SourcePath}" Width="250"/>
        <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="100"/>
        <!-- Progress column template... -->
        <DataGridTextColumn Header="Speed" Binding="{Binding Speed}" Width="80"/>
    </DataGrid.Columns>
</DataGrid>
```

### Error Information Source
Error details are stored in the chunk object after `Complete-RobocopyJob` (JobManagement.ps1:620-661):
```powershell
$exitMeaning = Get-RobocopyExitMeaning -ExitCode $exitCode
$stats = ConvertFrom-RobocopyLog -LogPath $Job.LogPath

$Job.Chunk.Status = switch ($exitMeaning.Severity) {
    'Error'   { 'Failed' }
    'Fatal'   { 'Failed' }
}
```

Currently, the exit code and error message are logged but NOT stored on the chunk object.

## Implementation Plan

### Step 1: Extend Chunk Object with Error Details
Modify `Invoke-FailedChunkHandler` (JobManagement.ps1:701-758) to store error info on the chunk:

```powershell
function Invoke-FailedChunkHandler {
    param([PSCustomObject]$Job, [PSCustomObject]$Result)

    $chunk = $Job.Chunk

    # NEW: Store error details on chunk for GUI tooltip
    $chunk | Add-Member -NotePropertyName 'LastExitCode' -NotePropertyValue $Result.ExitCode -Force
    $chunk | Add-Member -NotePropertyName 'LastErrorMessage' -NotePropertyValue $Result.ExitMeaning.Message -Force
    $chunk | Add-Member -NotePropertyName 'DestinationPath' -NotePropertyValue $Job.Chunk.DestinationPath -Force

    # ... rest of existing logic
}
```

### Step 2: Update Display Object with Error Info
Modify `Get-ChunkDisplayItems` (GuiProgress.ps1:88-185) to include error details:

```powershell
# In the failed chunks section:
foreach ($chunk in $script:OrchestrationState.FailedChunks.ToArray()) {
    $chunkDisplayItems.Add([PSCustomObject]@{
        ChunkId = $chunk.ChunkId
        SourcePath = $chunk.SourcePath
        DestinationPath = $chunk.DestinationPath  # NEW
        Status = "Failed"
        Progress = 0
        ProgressScale = [double]0.0
        Speed = "--"
        LastExitCode = $chunk.LastExitCode         # NEW
        LastErrorMessage = $chunk.LastErrorMessage # NEW
    })
}
```

### Step 3: Add RowStyle with Tooltip Trigger
Update MainWindow.xaml DataGrid to include conditional tooltip:

```xml
<Style x:Key="DarkDataGridRowWithTooltip" TargetType="DataGridRow" BasedOn="{StaticResource DarkDataGridRow}">
    <Style.Triggers>
        <!-- Only show tooltip when Status is Failed -->
        <DataTrigger Binding="{Binding Status}" Value="Failed">
            <Setter Property="ToolTip">
                <Setter.Value>
                    <Border Background="#1E1E1E" BorderBrush="#3E3E3E" BorderThickness="1"
                            CornerRadius="4" Padding="10">
                        <StackPanel>
                            <TextBlock Text="Chunk Failed" FontWeight="Bold"
                                       Foreground="#FF6B6B" Margin="0,0,0,8"/>
                            <TextBlock Foreground="#808080">
                                <Run Text="Exit Code: "/>
                                <Run Text="{Binding LastExitCode}" Foreground="#E0E0E0"/>
                            </TextBlock>
                            <TextBlock Foreground="#808080" TextWrapping="Wrap" MaxWidth="300">
                                <Run Text="Error: "/>
                                <Run Text="{Binding LastErrorMessage}" Foreground="#E0E0E0"/>
                            </TextBlock>
                            <TextBlock Foreground="#808080" Margin="0,8,0,0">
                                <Run Text="Source: "/>
                                <Run Text="{Binding SourcePath}" Foreground="#E0E0E0"/>
                            </TextBlock>
                            <TextBlock Foreground="#808080">
                                <Run Text="Dest: "/>
                                <Run Text="{Binding DestinationPath}" Foreground="#E0E0E0"/>
                            </TextBlock>
                        </StackPanel>
                    </Border>
                </Setter.Value>
            </Setter>
        </DataTrigger>
    </Style.Triggers>
</Style>
```

Then reference it in the DataGrid:
```xml
<DataGrid ... RowStyle="{StaticResource DarkDataGridRowWithTooltip}">
```

## Test Plan

Create `tests/Unit/GuiChunkTooltip.Tests.ps1`:

```powershell
#Requires -Modules Pester

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "Chunk Error Tooltip Tests" {

        BeforeAll {
            # Initialize orchestration state
            Initialize-OrchestrationState
        }

        Context "Failed Chunk Error Details" {
            It "Should include error details in failed chunk display items" {
                # Create a chunk with error info
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Source\Data"
                    DestinationPath = "D:\Backup\Data"
                    Status = "Failed"
                    LastExitCode = 16
                    LastErrorMessage = "Serious error. No files were copied."
                }

                $script:OrchestrationState.FailedChunks.Enqueue($chunk)

                $displayItems = Get-ChunkDisplayItems
                $failedItem = $displayItems | Where-Object { $_.Status -eq "Failed" }

                $failedItem.LastExitCode | Should -Be 16
                $failedItem.LastErrorMessage | Should -Be "Serious error. No files were copied."
                $failedItem.DestinationPath | Should -Be "D:\Backup\Data"
            }

            It "Should not include error details in completed chunk display items" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 2
                    SourcePath = "C:\Source\Other"
                    DestinationPath = "D:\Backup\Other"
                    Status = "Complete"
                    EstimatedSize = 1000
                }

                $script:OrchestrationState.CompletedChunks.Enqueue($chunk)

                $displayItems = Get-ChunkDisplayItems
                $completedItem = $displayItems | Where-Object { $_.Status -eq "Complete" }

                $completedItem.LastExitCode | Should -BeNullOrEmpty
                $completedItem.LastErrorMessage | Should -BeNullOrEmpty
            }
        }

        Context "Invoke-FailedChunkHandler Error Storage" {
            It "Should store error details on chunk object" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 3
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                    RetryCount = 0
                    Status = "Running"
                }

                $job = [PSCustomObject]@{
                    Chunk = $chunk
                    Process = [PSCustomObject]@{ Id = 123 }
                    LogPath = "C:\Logs\test.log"
                }

                $result = [PSCustomObject]@{
                    ExitCode = 8
                    ExitMeaning = [PSCustomObject]@{
                        Severity = "Error"
                        Message = "Some files could not be copied"
                        ShouldRetry = $false
                    }
                }

                # Set max retries to 0 so chunk fails permanently
                $script:MaxChunkRetries = 1
                $chunk.RetryCount = 1

                Invoke-FailedChunkHandler -Job $job -Result $result

                $chunk.LastExitCode | Should -Be 8
                $chunk.LastErrorMessage | Should -Be "Some files could not be copied"
            }
        }
    }
}
```

## Files to Modify
1. `src/Robocurse/Public/JobManagement.ps1` - Add error storage in `Invoke-FailedChunkHandler`
2. `src/Robocurse/Public/GuiProgress.ps1` - Update `Get-ChunkDisplayItems` to include error info
3. `src/Robocurse/Resources/MainWindow.xaml` - Add tooltip style and binding
4. `tests/Unit/GuiChunkTooltip.Tests.ps1` - New test file

## Verification Commands
```powershell
# Run tests
.\scripts\run-tests.ps1

# Run specific test file
Invoke-Pester -Path tests\Unit\GuiChunkTooltip.Tests.ps1 -Output Detailed
```

## Notes
- The tooltip uses WPF's built-in tooltip system, which handles positioning and timing
- Error info is added as NoteProperties to existing PSCustomObject chunks (no schema change needed)
- Completed chunks don't have error info, so their tooltip fields will be null (tooltip won't show)
- Consider max width on error message text to prevent huge tooltips
