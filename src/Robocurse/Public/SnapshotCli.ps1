# Robocurse Snapshot CLI Commands
# Command-line interface for VSS snapshot management

function Invoke-ListSnapshotsCommand {
    <#
    .SYNOPSIS
        CLI command to list VSS snapshots
    #>
    [CmdletBinding()]
    param(
        [string]$Volume,
        [string]$Server
    )

    Write-Host ""
    Write-Host "VSS Snapshots" -ForegroundColor Cyan
    Write-Host "=============" -ForegroundColor Cyan
    Write-Host ""

    try {
        if ($Server) {
            Write-Host "Server: $Server" -ForegroundColor Gray
            $result = Get-RemoteVssSnapshots -ServerName $Server -Volume $Volume
        }
        else {
            Write-Host "Server: Local" -ForegroundColor Gray
            $result = Get-VssSnapshots -Volume $Volume
        }

        if (-not $result.Success) {
            Write-Host "Error: $($result.ErrorMessage)" -ForegroundColor Red
            return 1
        }

        $snapshots = @($result.Data)

        if ($snapshots.Count -eq 0) {
            Write-Host "No snapshots found." -ForegroundColor Yellow
            return 0
        }

        Write-Host "Found $($snapshots.Count) snapshot(s):" -ForegroundColor Gray
        Write-Host ""

        # Table header
        $format = "{0,-8} {1,-20} {2,-40}"
        Write-Host ($format -f "Volume", "Created", "Shadow ID") -ForegroundColor White
        Write-Host ($format -f "------", "-------", "---------") -ForegroundColor DarkGray

        foreach ($snap in $snapshots) {
            $volume = $snap.SourceVolume
            $created = $snap.CreatedAt.ToString("yyyy-MM-dd HH:mm:ss")
            $shadowId = $snap.ShadowId

            Write-Host ($format -f $volume, $created, $shadowId)
        }

        Write-Host ""
        return 0
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        return 1
    }
}

function Invoke-CreateSnapshotCommand {
    <#
    .SYNOPSIS
        CLI command to create a VSS snapshot
    .DESCRIPTION
        Creates a VSS snapshot on the specified volume, optionally on a remote server.
        Enforces retention policy before creating the new snapshot.
    .PARAMETER Volume
        The volume letter to snapshot (e.g., "D:")
    .PARAMETER Server
        Optional remote server name for remote snapshots
    .PARAMETER KeepCount
        Number of snapshots to retain after cleanup (default: 3)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Volume,

        [string]$Server,

        [int]$KeepCount = 3
    )

    Write-Host ""
    Write-Host "Creating VSS Snapshot" -ForegroundColor Cyan
    Write-Host "=====================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Volume: $Volume" -ForegroundColor Gray
    Write-Host "Server: $(if ($Server) { $Server } else { 'Local' })" -ForegroundColor Gray
    Write-Host "Retention: Keep $KeepCount" -ForegroundColor Gray
    Write-Host ""

    try {
        # Enforce retention first
        Write-Host "Enforcing retention policy..." -ForegroundColor Gray

        if ($Server) {
            $retResult = Invoke-RemoteVssRetentionPolicy -ServerName $Server -Volume $Volume -KeepCount $KeepCount
        }
        else {
            $retResult = Invoke-VssRetentionPolicy -Volume $Volume -KeepCount $KeepCount
        }

        if ($retResult.Success) {
            Write-Host "  Deleted: $($retResult.Data.DeletedCount) old snapshot(s)" -ForegroundColor Gray
            Write-Host "  Kept: $($retResult.Data.KeptCount) snapshot(s)" -ForegroundColor Gray
        }
        else {
            Write-Host "  Warning: $($retResult.ErrorMessage)" -ForegroundColor Yellow
        }

        # Create snapshot
        Write-Host ""
        Write-Host "Creating snapshot..." -ForegroundColor Gray

        if ($Server) {
            # Use admin share for remote
            $uncPath = "\\$Server\$($Volume -replace ':', '$')"
            $snapResult = New-RemoteVssSnapshot -UncPath $uncPath
        }
        else {
            $snapResult = New-VssSnapshot -SourcePath "$Volume\"
        }

        if ($snapResult.Success) {
            Write-Host ""
            Write-Host "Snapshot created successfully!" -ForegroundColor Green
            Write-Host "  Shadow ID: $($snapResult.Data.ShadowId)" -ForegroundColor White
            Write-Host "  Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
            Write-Host ""
            return 0
        }
        else {
            Write-Host ""
            Write-Host "Failed to create snapshot:" -ForegroundColor Red
            Write-Host "  $($snapResult.ErrorMessage)" -ForegroundColor Red
            Write-Host ""
            return 1
        }
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        return 1
    }
}

function Invoke-DeleteSnapshotCommand {
    <#
    .SYNOPSIS
        CLI command to delete a VSS snapshot
    .DESCRIPTION
        Deletes a VSS snapshot by its Shadow ID, with confirmation prompt.
    .PARAMETER ShadowId
        The GUID of the shadow copy to delete
    .PARAMETER Server
        Optional remote server name for remote snapshots
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ShadowId,

        [string]$Server
    )

    Write-Host ""
    Write-Host "Deleting VSS Snapshot" -ForegroundColor Cyan
    Write-Host "=====================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Shadow ID: $ShadowId" -ForegroundColor Gray
    Write-Host "Server: $(if ($Server) { $Server } else { 'Local' })" -ForegroundColor Gray
    Write-Host ""

    # Confirm
    Write-Host "Are you sure you want to delete this snapshot? (y/N): " -NoNewline -ForegroundColor Yellow
    $confirm = Read-Host

    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Cancelled." -ForegroundColor Gray
        return 0
    }

    try {
        Write-Host ""
        Write-Host "Deleting..." -ForegroundColor Gray

        if ($Server) {
            $result = Remove-RemoteVssSnapshot -ShadowId $ShadowId -ServerName $Server
        }
        else {
            $result = Remove-VssSnapshot -ShadowId $ShadowId
        }

        if ($result.Success) {
            Write-Host "Snapshot deleted successfully!" -ForegroundColor Green
            Write-Host ""
            return 0
        }
        else {
            Write-Host "Failed to delete snapshot:" -ForegroundColor Red
            Write-Host "  $($result.ErrorMessage)" -ForegroundColor Red
            Write-Host ""
            return 1
        }
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        return 1
    }
}

function Invoke-SnapshotScheduleCommand {
    <#
    .SYNOPSIS
        CLI command to manage snapshot schedules
    .DESCRIPTION
        Lists, syncs, adds, or removes Windows scheduled tasks for automated
        VSS snapshot creation. Use -Sync to synchronize scheduled tasks with
        the configuration file.
    .PARAMETER List
        List all configured snapshot schedules
    .PARAMETER Sync
        Synchronize scheduled tasks with configuration file
    .PARAMETER Add
        Show instructions for adding a new schedule
    .PARAMETER Remove
        Remove a scheduled task by name
    .PARAMETER ScheduleName
        Name of the schedule (required for -Remove)
    .PARAMETER Config
        The Robocurse configuration object (required for -Sync)
    #>
    [CmdletBinding()]
    param(
        [switch]$List,
        [switch]$Sync,
        [switch]$Add,
        [switch]$Remove,
        [string]$ScheduleName,
        [PSCustomObject]$Config
    )

    Write-Host ""
    Write-Host "Snapshot Schedules" -ForegroundColor Cyan
    Write-Host "==================" -ForegroundColor Cyan
    Write-Host ""

    if ($List -or (-not $Sync -and -not $Add -and -not $Remove)) {
        # Default to list
        $tasks = Get-SnapshotScheduledTasks

        if ($tasks.Count -eq 0) {
            Write-Host "No snapshot schedules configured." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "To add schedules, configure snapshotSchedules in your config file and run:" -ForegroundColor Gray
            Write-Host "  .\Robocurse.ps1 -SnapshotSchedule -Sync" -ForegroundColor White
            Write-Host ""
            return 0
        }

        $format = "{0,-20} {1,-10} {2,-20}"
        Write-Host ($format -f "Name", "State", "Next Run") -ForegroundColor White
        Write-Host ($format -f "----", "-----", "--------") -ForegroundColor DarkGray

        foreach ($task in $tasks) {
            $stateColor = if ($task.State -eq 'Ready') { 'Green' } else { 'Yellow' }
            Write-Host ($format -f $task.Name, $task.State, $task.NextRunTime) -ForegroundColor $stateColor
        }

        Write-Host ""
        return 0
    }

    if ($Sync) {
        Write-Host "Synchronizing schedules with configuration..." -ForegroundColor Gray

        $result = Sync-SnapshotSchedules -Config $Config

        if ($result.Success) {
            Write-Host ""
            Write-Host "Sync completed:" -ForegroundColor Green
            Write-Host "  Created: $($result.Data.Created)" -ForegroundColor Gray
            Write-Host "  Removed: $($result.Data.Removed)" -ForegroundColor Gray
            Write-Host "  Total: $($result.Data.Total)" -ForegroundColor Gray
            Write-Host ""
            return 0
        }
        else {
            Write-Host "Sync completed with errors:" -ForegroundColor Yellow
            foreach ($err in $result.Data.Errors) {
                Write-Host "  - $err" -ForegroundColor Red
            }
            Write-Host ""
            return 1
        }
    }

    if ($Remove) {
        if (-not $ScheduleName) {
            Write-Host "Error: -ScheduleName is required for -Remove" -ForegroundColor Red
            return 1
        }

        $result = Remove-SnapshotScheduledTask -ScheduleName $ScheduleName

        if ($result.Success) {
            Write-Host "Schedule '$ScheduleName' removed." -ForegroundColor Green
            return 0
        }
        else {
            Write-Host "Failed to remove schedule: $($result.ErrorMessage)" -ForegroundColor Red
            return 1
        }
    }

    # -Add would need interactive prompts or config file - defer to Sync
    if ($Add) {
        Write-Host "To add a schedule, edit your config file and add to 'snapshotSchedules', then run:" -ForegroundColor Gray
        Write-Host "  .\Robocurse.ps1 -SnapshotSchedule -Sync" -ForegroundColor White
        Write-Host ""
        Write-Host "Example config:" -ForegroundColor Gray
        Write-Host @"
  "snapshotSchedules": [
    {
      "name": "DailyD",
      "volume": "D:",
      "schedule": "Daily",
      "time": "02:00",
      "keepCount": 7,
      "enabled": true
    }
  ]
"@ -ForegroundColor DarkGray
        Write-Host ""
        return 0
    }

    return 0
}
