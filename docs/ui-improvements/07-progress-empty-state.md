# Task: Implement Progress Panel Empty State

## Objective

When no replication is running, the Progress panel should display a summary of the last completed run instead of empty/zeroed controls. This provides useful context and avoids a "broken" appearance.

## Context

Currently, the Progress panel shows default values (0%, empty DataGrid) when idle. After the navigation rail redesign, users will switch to the Progress panel expecting to see status. Showing the last run's results provides value even when nothing is active.

## Files to Modify

| File | Action |
|------|--------|
| `src/Robocurse/Public/GuiProgress.ps1` | Add empty state display logic |
| `src/Robocurse/Public/GuiSettings.ps1` | Persist last run summary to settings file |
| `src/Robocurse/Resources/MainWindow.xaml` | May need empty state overlay in panelProgress |

## Research Required

### In Codebase
1. Read `src/Robocurse/Public/GuiProgress.ps1`:
   - How progress is currently updated (Update-GuiProgress)
   - What data is available at end of run
   - Current idle state behavior

2. Read `src/Robocurse/Public/GuiSettings.ps1`:
   - Settings file structure (Robocurse.settings.json)
   - How to add new persisted properties
   - Load/save patterns

3. Read `src/Robocurse/Public/GuiReplication.ps1`:
   - Complete-GuiReplication function
   - What summary data is available at completion

### Data Available at Run Completion

From orchestration state at completion:
- Profile names that ran
- Total chunks attempted
- Chunks completed successfully
- Chunks failed
- Total bytes copied
- Duration
- Completion timestamp

## Implementation Steps

### Step 1: Define Last Run Data Structure

```powershell
# In GuiSettings.ps1, define the structure:
$lastRunTemplate = @{
    Timestamp = $null           # [datetime] When run completed
    ProfilesRun = @()           # [string[]] Names of profiles executed
    ChunksTotal = 0             # [int] Total chunks
    ChunksCompleted = 0         # [int] Successfully completed
    ChunksFailed = 0            # [int] Failed chunks
    BytesCopied = 0             # [long] Total bytes
    Duration = $null            # [timespan] as string "hh:mm:ss"
    Status = 'Unknown'          # [string] 'Success', 'PartialFailure', 'Failed'
}
```

### Step 2: Save Last Run on Completion

In GuiReplication.ps1, modify `Complete-GuiReplication`:

```powershell
function Complete-GuiReplication {
    # ... existing completion logic ...

    # Capture last run summary
    $lastRun = @{
        Timestamp = Get-Date
        ProfilesRun = @($script:OrchestrationState.ProfilesRun | ForEach-Object { $_.Name })
        ChunksTotal = $script:OrchestrationState.TotalChunks
        ChunksCompleted = $script:OrchestrationState.CompletedChunks
        ChunksFailed = $script:OrchestrationState.FailedChunks.Count
        BytesCopied = $script:OrchestrationState.TotalBytesCopied
        Duration = $script:OrchestrationState.Duration.ToString('hh\:mm\:ss')
        Status = if ($script:OrchestrationState.FailedChunks.Count -eq 0) { 'Success' }
                 elseif ($script:OrchestrationState.CompletedChunks -gt 0) { 'PartialFailure' }
                 else { 'Failed' }
    }

    # Save to settings
    Save-LastRunSummary -Summary $lastRun

    # ... rest of completion logic ...
}
```

### Step 3: Add Settings Persistence Functions

In GuiSettings.ps1:

```powershell
function Save-LastRunSummary {
    <#
    .SYNOPSIS
        Saves the last run summary to the settings file
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Summary
    )

    $settings = Get-GuiState
    $settings.LastRun = $Summary
    Save-GuiState -State $settings
}

function Get-LastRunSummary {
    <#
    .SYNOPSIS
        Retrieves the last run summary from settings
    .OUTPUTS
        Hashtable with last run data, or $null if no previous run
    #>
    [CmdletBinding()]
    param()

    $settings = Get-GuiState
    return $settings.LastRun
}
```

### Step 4: Create Empty State Display Function

In GuiProgress.ps1:

```powershell
function Show-ProgressEmptyState {
    <#
    .SYNOPSIS
        Displays the last run summary when no replication is active
    #>
    [CmdletBinding()]
    param()

    $lastRun = Get-LastRunSummary

    if (-not $lastRun -or -not $lastRun.Timestamp) {
        # No previous run - show "ready" message
        $script:Controls['txtProfileProgress'].Text = "No previous runs"
        $script:Controls['txtOverallProgress'].Text = "Select profiles and click Run"
        $script:Controls['pbProfile'].Value = 0
        $script:Controls['pbOverall'].Value = 0
        $script:Controls['txtEta'].Text = "ETA: --"
        $script:Controls['txtSpeed'].Text = "Speed: --"
        $script:Controls['txtChunks'].Text = "Ready"
        $script:Controls['dgChunks'].ItemsSource = $null
        return
    }

    # Format last run timestamp
    $timestamp = [datetime]$lastRun.Timestamp
    $timeAgo = (Get-Date) - $timestamp
    $timeAgoStr = if ($timeAgo.TotalDays -ge 1) {
        "{0:N0} days ago" -f $timeAgo.TotalDays
    } elseif ($timeAgo.TotalHours -ge 1) {
        "{0:N0} hours ago" -f $timeAgo.TotalHours
    } else {
        "{0:N0} minutes ago" -f $timeAgo.TotalMinutes
    }

    # Status color indicator
    $statusColor = switch ($lastRun.Status) {
        'Success' { '#00FF7F' }        # Lime green
        'PartialFailure' { '#FFB340' } # Orange
        'Failed' { '#FF6B6B' }         # Red
        default { '#808080' }          # Gray
    }

    # Update display
    $profileNames = $lastRun.ProfilesRun -join ', '
    $script:Controls['txtProfileProgress'].Text = "Last: $profileNames"
    $script:Controls['txtOverallProgress'].Text = "$($lastRun.Status) - $timeAgoStr"
    $script:Controls['txtOverallProgress'].Foreground = $statusColor

    # Progress bars show completion percentage
    $completionPct = if ($lastRun.ChunksTotal -gt 0) {
        [int](($lastRun.ChunksCompleted / $lastRun.ChunksTotal) * 100)
    } else { 0 }
    $script:Controls['pbProfile'].Value = $completionPct
    $script:Controls['pbOverall'].Value = $completionPct

    # Stats
    $script:Controls['txtEta'].Text = "Duration: $($lastRun.Duration)"
    $bytesStr = Format-ByteSize -Bytes $lastRun.BytesCopied
    $script:Controls['txtSpeed'].Text = "Copied: $bytesStr"
    $script:Controls['txtChunks'].Text = "Chunks: $($lastRun.ChunksCompleted)/$($lastRun.ChunksTotal)"

    # Show completion summary in DataGrid (optional)
    if ($lastRun.ChunksFailed -gt 0) {
        $script:Controls['txtChunks'].Text += " ($($lastRun.ChunksFailed) failed)"
        $script:Controls['txtChunks'].Foreground = '#FF6B6B'
    }

    # Clear the chunk grid for empty state
    $script:Controls['dgChunks'].ItemsSource = $null
}
```

### Step 5: Integrate with Progress Timer

Modify the progress update logic to check for idle state:

```powershell
function Update-GuiProgress {
    # Check if replication is active
    if (-not $script:OrchestrationState -or
        $script:OrchestrationState.Phase -in @('Idle', 'Complete', $null)) {

        # Show empty state / last run summary
        Show-ProgressEmptyState
        return
    }

    # ... existing active progress update logic ...
}
```

### Step 6: Clear Distinction Between States

Add visual indicators to distinguish "showing last run" from "actively running":

**Idle/Last Run State:**
- Progress bars show final values (frozen)
- Text shows "Last: ..." prefix
- DataGrid is empty or shows summary
- Bottom bar shows "Ready" status

**Active Running State:**
- Progress bars animate
- Text shows "Profile: ..." (no prefix)
- DataGrid shows live chunks
- Bottom bar shows "Running..." status

```powershell
# In the running state:
$script:Controls['txtProfileProgress'].Text = "Profile: $currentProfile - $pct%"
$script:Controls['txtOverallProgress'].Foreground = '#E0E0E0'  # Normal color

# In idle state showing last run:
$script:Controls['txtProfileProgress'].Text = "Last: $profileNames"
$script:Controls['txtOverallProgress'].Foreground = $statusColor  # Status color
```

### Step 7: Handle Panel Switch

When switching to Progress panel, determine which state to show:

```powershell
# In Set-ActivePanel when switching to Progress:
if ($PanelName -eq 'Progress') {
    if ($script:OrchestrationState -and
        $script:OrchestrationState.Phase -notin @('Idle', 'Complete', $null)) {
        # Active run - let timer handle updates
    } else {
        # Idle - show last run summary
        Show-ProgressEmptyState
    }
}
```

## Success Criteria

1. **First launch**: Progress panel shows "No previous runs" message
2. **After completion**: Progress panel shows last run summary
3. **Time display**: Shows how long ago the run completed
4. **Status color**: Success=green, PartialFailure=orange, Failed=red
5. **Persists restart**: Last run info survives app restart
6. **Clear distinction**: Easy to tell "showing history" vs "actively running"
7. **Running takes over**: When replication starts, live progress replaces history

## Testing

1. Build and run
2. Switch to Progress panel before any runs - verify "No previous runs"
3. Run a successful replication
4. When complete, verify last run summary displays
5. Close and reopen app - verify last run still shows
6. Run again - verify live progress replaces summary
7. Force a failure - verify PartialFailure/Failed status shows correctly

## Notes

- **Settings file location**: Robocurse.settings.json in same directory as script
- **Byte formatting**: Use existing Format-ByteSize function if available, or implement
- **Foreground color**: May need to use `[System.Windows.Media.Brushes]::` for WPF color assignment
- **Thread safety**: Last run summary is read-only during display, no locking needed
