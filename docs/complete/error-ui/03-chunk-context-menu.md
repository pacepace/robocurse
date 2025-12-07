# Task: Failed Chunk Context Menu

## Objective
Add a right-click context menu to the chunk DataGrid that provides recovery actions for failed chunks: Retry, Skip, and View Log.

## Problem Statement
Currently when a chunk fails:
- Automatic retry with exponential backoff runs (up to MaxChunkRetries)
- After max retries, chunk is marked permanently failed
- User has NO way to:
  - Manually retry a specific chunk
  - Skip a problematic chunk and continue
  - Quickly access the chunk's robocopy log file

## Success Criteria
1. Right-click on any row shows context menu
2. Failed chunk menu shows: "Retry This Chunk", "Skip This Chunk", "Open Log File"
3. Running chunk menu shows: "Open Log File" (disabled Retry/Skip)
4. Completed chunk menu shows: "Open Log File"
5. Retry re-enqueues the chunk to ChunkQueue
6. Skip removes chunk from FailedChunks (marks as skipped, not retried)
7. Open Log File launches the log in default text editor
8. Context menu matches dark theme
9. All tests pass

## Research: Current Implementation

### DataGrid Definition (MainWindow.xaml:558-594)
```xml
<DataGrid Grid.Row="1" x:Name="dgChunks" AutoGenerateColumns="False"
          Style="{StaticResource DarkDataGrid}"
          IsReadOnly="True" SelectionMode="Single">
```

### Chunk Object Structure
From `New-Chunk` (Chunking.ps1):
```powershell
[PSCustomObject]@{
    ChunkId = ...
    SourcePath = ...
    DestinationPath = ...
    Status = 'Pending'  # Pending, Running, Complete, Failed, Skipped
    RetryCount = 0
    RetryAfter = $null
    EstimatedSize = ...
}
```

### Failed Chunk Storage
From OrchestrationCore.ps1 C# class:
```csharp
public ConcurrentQueue<object> FailedChunks { get; private set; }
```

### Log Path Pattern
From JobManagement.ps1:333-374:
```powershell
$logPath = Get-LogPath -Type 'ChunkJob' -ChunkId $Chunk.ChunkId
```

Log files are at: `$LogDirectory\chunk-{ChunkId}.log`

## Implementation Plan

### Step 1: Add LogPath to Chunk Display Items
Extend `Get-ChunkDisplayItems` to include log path:

```powershell
# For active jobs - get log path from job object
foreach ($kvp in $script:OrchestrationState.ActiveJobs.ToArray()) {
    $job = $kvp.Value
    $chunkDisplayItems.Add([PSCustomObject]@{
        ChunkId = $job.Chunk.ChunkId
        SourcePath = $job.Chunk.SourcePath
        Status = "Running"
        # ... existing properties
        LogPath = $job.LogPath  # NEW - from job object
    })
}

# For failed chunks - reconstruct log path
foreach ($chunk in $script:OrchestrationState.FailedChunks.ToArray()) {
    $logPath = Get-LogPath -Type 'ChunkJob' -ChunkId $chunk.ChunkId
    $chunkDisplayItems.Add([PSCustomObject]@{
        # ... existing properties
        LogPath = $logPath  # NEW
    })
}

# For completed chunks
foreach ($chunk in $completedSnapshot) {
    $logPath = Get-LogPath -Type 'ChunkJob' -ChunkId $chunk.ChunkId
    $chunkDisplayItems.Add([PSCustomObject]@{
        # ... existing properties
        LogPath = $logPath  # NEW
    })
}
```

### Step 2: Create Context Menu Style in MainWindow.xaml
Add to Window.Resources:

```xml
<!-- Context Menu Style -->
<Style x:Key="DarkContextMenu" TargetType="ContextMenu">
    <Setter Property="Background" Value="#252525"/>
    <Setter Property="Foreground" Value="#E0E0E0"/>
    <Setter Property="BorderBrush" Value="#3E3E3E"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="2"/>
</Style>

<Style x:Key="DarkMenuItem" TargetType="MenuItem">
    <Setter Property="Foreground" Value="#E0E0E0"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="8,6"/>
    <Setter Property="Template">
        <Setter.Value>
            <ControlTemplate TargetType="MenuItem">
                <Border x:Name="border" Background="{TemplateBinding Background}"
                        Padding="{TemplateBinding Padding}">
                    <ContentPresenter ContentSource="Header"/>
                </Border>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="border" Property="Background" Value="#3E3E3E"/>
                    </Trigger>
                    <Trigger Property="IsEnabled" Value="False">
                        <Setter Property="Foreground" Value="#606060"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
        </Setter.Value>
    </Setter>
</Style>
```

### Step 3: Add ContextMenu to DataGrid
Update the DataGrid in MainWindow.xaml:

```xml
<DataGrid Grid.Row="1" x:Name="dgChunks" AutoGenerateColumns="False"
          Style="{StaticResource DarkDataGrid}"
          IsReadOnly="True" SelectionMode="Single">
    <DataGrid.ContextMenu>
        <ContextMenu x:Name="ctxChunk" Style="{StaticResource DarkContextMenu}">
            <MenuItem x:Name="mnuRetryChunk" Header="Retry This Chunk"
                      Style="{StaticResource DarkMenuItem}"/>
            <MenuItem x:Name="mnuSkipChunk" Header="Skip This Chunk"
                      Style="{StaticResource DarkMenuItem}"/>
            <Separator Background="#3E3E3E"/>
            <MenuItem x:Name="mnuOpenLog" Header="Open Log File"
                      Style="{StaticResource DarkMenuItem}"/>
        </ContextMenu>
    </DataGrid.ContextMenu>
    <!-- existing columns... -->
</DataGrid>
```

### Step 4: Create Chunk Action Functions
Add to a new file `src/Robocurse/Public/GuiChunkActions.ps1`:

```powershell
function Invoke-ChunkRetry {
    <#
    .SYNOPSIS
        Manually retries a failed chunk by re-enqueuing it
    .PARAMETER ChunkId
        The chunk ID to retry
    #>
    [CmdletBinding()]
    param([int]$ChunkId)

    $failedChunks = $script:OrchestrationState.FailedChunks.ToArray()
    $targetChunk = $failedChunks | Where-Object { $_.ChunkId -eq $ChunkId }

    if (-not $targetChunk) {
        Write-GuiLog "Cannot retry: Chunk $ChunkId not found in failed chunks"
        return $false
    }

    # Create new queue without this chunk
    $newFailedQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    foreach ($chunk in $failedChunks) {
        if ($chunk.ChunkId -ne $ChunkId) {
            $newFailedQueue.Enqueue($chunk)
        }
    }

    # Reset the chunk for retry
    $targetChunk.Status = 'Pending'
    $targetChunk.RetryCount = 0  # Reset retry count for manual retry
    $targetChunk.RetryAfter = $null

    # Re-enqueue for processing
    $script:OrchestrationState.ChunkQueue.Enqueue($targetChunk)

    Write-GuiLog "Chunk $ChunkId queued for manual retry"
    Write-RobocurseLog -Message "Manual retry requested for chunk $ChunkId" `
        -Level 'Info' -Component 'GUI'

    return $true
}

function Invoke-ChunkSkip {
    <#
    .SYNOPSIS
        Permanently skips a failed chunk (removes from failed queue, marks as skipped)
    .PARAMETER ChunkId
        The chunk ID to skip
    #>
    [CmdletBinding()]
    param([int]$ChunkId)

    $failedChunks = $script:OrchestrationState.FailedChunks.ToArray()
    $targetChunk = $failedChunks | Where-Object { $_.ChunkId -eq $ChunkId }

    if (-not $targetChunk) {
        Write-GuiLog "Cannot skip: Chunk $ChunkId not found in failed chunks"
        return $false
    }

    # Drain and rebuild queue without this chunk
    $item = $null
    while ($script:OrchestrationState.FailedChunks.TryDequeue([ref]$item)) {
        if ($item.ChunkId -ne $ChunkId) {
            $script:OrchestrationState.FailedChunks.Enqueue($item)
        }
    }

    # Mark as skipped (for reporting)
    $targetChunk.Status = 'Skipped'
    $script:OrchestrationState.IncrementSkippedCount()

    Write-GuiLog "Chunk $ChunkId marked as skipped"
    Write-RobocurseLog -Message "Chunk $ChunkId manually skipped by user" `
        -Level 'Warning' -Component 'GUI'

    return $true
}

function Open-ChunkLog {
    <#
    .SYNOPSIS
        Opens the chunk's robocopy log file in the default text editor
    .PARAMETER LogPath
        Full path to the log file
    #>
    [CmdletBinding()]
    param([string]$LogPath)

    if (-not $LogPath) {
        Write-GuiLog "No log path available for this chunk"
        return
    }

    if (-not (Test-Path $LogPath)) {
        Write-GuiLog "Log file not found: $LogPath"
        [System.Windows.MessageBox]::Show(
            "Log file not found:`n$LogPath",
            "File Not Found",
            "OK",
            "Warning"
        )
        return
    }

    try {
        Start-Process -FilePath $LogPath
        Write-GuiLog "Opened log file: $LogPath"
    }
    catch {
        Write-GuiLog "Failed to open log file: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            "Failed to open log file:`n$($_.Exception.Message)",
            "Error",
            "OK",
            "Error"
        )
    }
}
```

### Step 5: Wire Up Context Menu Events
In GuiMain.ps1, add context menu handlers:

```powershell
# Context menu opening - enable/disable items based on selection
$script:Controls.ctxChunk.Add_Opened({
    $selectedItem = $script:Controls.dgChunks.SelectedItem

    if (-not $selectedItem) {
        $script:Controls.mnuRetryChunk.IsEnabled = $false
        $script:Controls.mnuSkipChunk.IsEnabled = $false
        $script:Controls.mnuOpenLog.IsEnabled = $false
        return
    }

    # Enable/disable based on status
    $isFailed = $selectedItem.Status -eq 'Failed'
    $hasLog = -not [string]::IsNullOrEmpty($selectedItem.LogPath)

    $script:Controls.mnuRetryChunk.IsEnabled = $isFailed
    $script:Controls.mnuSkipChunk.IsEnabled = $isFailed
    $script:Controls.mnuOpenLog.IsEnabled = $hasLog
})

# Retry handler
$script:Controls.mnuRetryChunk.Add_Click({
    $selectedItem = $script:Controls.dgChunks.SelectedItem
    if ($selectedItem -and $selectedItem.Status -eq 'Failed') {
        Invoke-ChunkRetry -ChunkId $selectedItem.ChunkId
    }
})

# Skip handler
$script:Controls.mnuSkipChunk.Add_Click({
    $selectedItem = $script:Controls.dgChunks.SelectedItem
    if ($selectedItem -and $selectedItem.Status -eq 'Failed') {
        $confirm = Show-ConfirmDialog -Title "Skip Chunk" `
            -Message "Skip chunk $($selectedItem.ChunkId)?`n`nThis chunk will not be retried and may result in incomplete replication." `
            -ConfirmText "Skip" -CancelText "Cancel"

        if ($confirm) {
            Invoke-ChunkSkip -ChunkId $selectedItem.ChunkId
        }
    }
})

# Open log handler
$script:Controls.mnuOpenLog.Add_Click({
    $selectedItem = $script:Controls.dgChunks.SelectedItem
    if ($selectedItem -and $selectedItem.LogPath) {
        Open-ChunkLog -LogPath $selectedItem.LogPath
    }
})
```

## Test Plan

Create `tests/Unit/GuiChunkActions.Tests.ps1`:

```powershell
#Requires -Modules Pester

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "Chunk Context Menu Actions" {

        BeforeAll {
            Initialize-OrchestrationState
        }

        AfterEach {
            $script:OrchestrationState.ClearChunkCollections()
        }

        Context "Invoke-ChunkRetry" {
            It "Should move chunk from FailedChunks to ChunkQueue" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 42
                    SourcePath = "C:\Test"
                    Status = "Failed"
                    RetryCount = 3
                    RetryAfter = [datetime]::Now.AddMinutes(5)
                }
                $script:OrchestrationState.FailedChunks.Enqueue($chunk)

                $result = Invoke-ChunkRetry -ChunkId 42

                $result | Should -Be $true
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 1
                $script:OrchestrationState.FailedChunks.Count | Should -Be 0
            }

            It "Should reset RetryCount and RetryAfter" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 43
                    SourcePath = "C:\Test2"
                    Status = "Failed"
                    RetryCount = 5
                    RetryAfter = [datetime]::Now.AddMinutes(10)
                }
                $script:OrchestrationState.FailedChunks.Enqueue($chunk)

                Invoke-ChunkRetry -ChunkId 43

                $queuedChunk = $null
                $script:OrchestrationState.ChunkQueue.TryDequeue([ref]$queuedChunk)

                $queuedChunk.RetryCount | Should -Be 0
                $queuedChunk.RetryAfter | Should -BeNullOrEmpty
                $queuedChunk.Status | Should -Be 'Pending'
            }

            It "Should return false for non-existent chunk" {
                $result = Invoke-ChunkRetry -ChunkId 999

                $result | Should -Be $false
            }

            It "Should preserve other failed chunks" {
                $chunk1 = [PSCustomObject]@{ ChunkId = 1; Status = "Failed" }
                $chunk2 = [PSCustomObject]@{ ChunkId = 2; Status = "Failed" }
                $chunk3 = [PSCustomObject]@{ ChunkId = 3; Status = "Failed" }

                $script:OrchestrationState.FailedChunks.Enqueue($chunk1)
                $script:OrchestrationState.FailedChunks.Enqueue($chunk2)
                $script:OrchestrationState.FailedChunks.Enqueue($chunk3)

                Invoke-ChunkRetry -ChunkId 2

                $script:OrchestrationState.FailedChunks.Count | Should -Be 2
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 1
            }
        }

        Context "Invoke-ChunkSkip" {
            It "Should remove chunk from FailedChunks" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 50
                    Status = "Failed"
                }
                $script:OrchestrationState.FailedChunks.Enqueue($chunk)

                $result = Invoke-ChunkSkip -ChunkId 50

                $result | Should -Be $true
                $script:OrchestrationState.FailedChunks.Count | Should -Be 0
            }

            It "Should mark chunk status as Skipped" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 51
                    Status = "Failed"
                }
                $script:OrchestrationState.FailedChunks.Enqueue($chunk)

                Invoke-ChunkSkip -ChunkId 51

                $chunk.Status | Should -Be 'Skipped'
            }

            It "Should increment SkippedChunkCount" {
                $initialCount = $script:OrchestrationState.SkippedChunkCount

                $chunk = [PSCustomObject]@{ ChunkId = 52; Status = "Failed" }
                $script:OrchestrationState.FailedChunks.Enqueue($chunk)

                Invoke-ChunkSkip -ChunkId 52

                $script:OrchestrationState.SkippedChunkCount | Should -Be ($initialCount + 1)
            }

            It "Should return false for non-existent chunk" {
                $result = Invoke-ChunkSkip -ChunkId 888

                $result | Should -Be $false
            }
        }

        Context "Get-ChunkDisplayItems with LogPath" {
            It "Should include LogPath for failed chunks" {
                Mock Get-LogPath { return "C:\Logs\chunk-$ChunkId.log" }

                $chunk = [PSCustomObject]@{
                    ChunkId = 100
                    SourcePath = "C:\Source"
                    Status = "Failed"
                }
                $script:OrchestrationState.FailedChunks.Enqueue($chunk)

                $displayItems = Get-ChunkDisplayItems

                $failedItem = $displayItems | Where-Object { $_.ChunkId -eq 100 }
                $failedItem.LogPath | Should -Not -BeNullOrEmpty
            }
        }
    }
}
```

## Files to Modify
1. `src/Robocurse/Public/GuiProgress.ps1` - Add LogPath to display items
2. `src/Robocurse/Resources/MainWindow.xaml` - Add context menu and styles
3. `src/Robocurse/Public/GuiChunkActions.ps1` - New file with action functions
4. `src/Robocurse/Public/GuiMain.ps1` - Wire up context menu handlers
5. `src/Robocurse/Robocurse.psm1` - Add GuiChunkActions.ps1 to module
6. `tests/Unit/GuiChunkActions.Tests.ps1` - New test file

## Verification Commands
```powershell
.\scripts\run-tests.ps1
Invoke-Pester -Path tests\Unit\GuiChunkActions.Tests.ps1 -Output Detailed
```

## Notes
- Manual retry resets RetryCount to 0, giving the chunk a fresh set of attempts
- Skip is logged as Warning level for audit trail
- Context menu dynamically enables/disables items based on chunk status
- ConcurrentQueue doesn't have Remove, so we drain and rebuild (safe for small queues)
- Log file opening uses Start-Process which respects system file associations
