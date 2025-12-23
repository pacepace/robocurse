# Task: CLI Snapshot Commands

## Objective
Add command-line interface for managing VSS snapshots, including listing, creating, deleting, and managing scheduled snapshots.

## Success Criteria
- [ ] `Robocurse.ps1 -ListSnapshots` lists all snapshots
- [ ] `Robocurse.ps1 -CreateSnapshot -Volume D:` creates a snapshot
- [ ] `Robocurse.ps1 -DeleteSnapshot -ShadowId {guid}` deletes a snapshot
- [ ] `Robocurse.ps1 -SnapshotSchedule -List` shows scheduled tasks
- [ ] `Robocurse.ps1 -SnapshotSchedule -Sync` syncs schedules with config
- [ ] Remote server support with `-Server` parameter
- [ ] Help text documents all snapshot commands
- [ ] Tests verify CLI parameter handling

## Research

### Existing CLI Pattern (Main.ps1)
```powershell
function Start-RobocurseMain {
    param(
        [switch]$Headless,
        [string]$ConfigPath,
        [string]$ProfileName,
        [switch]$AllProfiles,
        [switch]$DryRun,
        [switch]$ShowHelp
    )
    # Parameter validation and dispatch
}
```

### Existing Help Pattern
```powershell
function Show-RobocurseHelp {
    $helpText = @"
ROBOCURSE - Chunked Robocopy Orchestrator

USAGE:
    .\Robocurse.ps1 [options]

OPTIONS:
    -Headless           Run without GUI
    -Profile <name>     Run specific profile
    ...
"@
    Write-Host $helpText
}
```

### Console Output Pattern
```powershell
Write-Host "Profile: $name" -ForegroundColor Cyan
Write-Host "  Status: " -NoNewline
Write-Host "Success" -ForegroundColor Green
```

## Implementation

### Part 1: Parameter Updates

#### File: `src\Robocurse\Public\Main.ps1`

**Update parameter block in `Start-RobocurseMain`:**

```powershell
function Start-RobocurseMain {
    [CmdletBinding()]
    param(
        # Existing parameters
        [switch]$Headless,
        [string]$ConfigPath = ".\Robocurse.config.json",
        [string]$ProfileName,
        [switch]$AllProfiles,
        [switch]$DryRun,
        [switch]$ShowHelp,

        # New snapshot parameters
        [switch]$ListSnapshots,
        [switch]$CreateSnapshot,
        [switch]$DeleteSnapshot,
        [string]$Volume,
        [string]$ShadowId,
        [string]$Server,
        [int]$KeepCount = 3,
        [switch]$SnapshotSchedule,
        [switch]$List,
        [switch]$Sync,
        [switch]$Add,
        [switch]$Remove,
        [string]$ScheduleName
    )

    # ... existing logic ...

    # Snapshot command dispatch (add before GUI/headless logic)
    if ($ListSnapshots) {
        return Invoke-ListSnapshotsCommand -Volume $Volume -Server $Server
    }

    if ($CreateSnapshot) {
        if (-not $Volume) {
            Write-Host "Error: -Volume is required for -CreateSnapshot" -ForegroundColor Red
            return 1
        }
        return Invoke-CreateSnapshotCommand -Volume $Volume -Server $Server -KeepCount $KeepCount
    }

    if ($DeleteSnapshot) {
        if (-not $ShadowId) {
            Write-Host "Error: -ShadowId is required for -DeleteSnapshot" -ForegroundColor Red
            return 1
        }
        return Invoke-DeleteSnapshotCommand -ShadowId $ShadowId -Server $Server
    }

    if ($SnapshotSchedule) {
        return Invoke-SnapshotScheduleCommand -List:$List -Sync:$Sync -Add:$Add -Remove:$Remove -ScheduleName $ScheduleName -Config $config
    }

    # ... rest of existing logic (GUI/headless) ...
}
```

### Part 2: Snapshot CLI Functions

#### File: `src\Robocurse\Public\SnapshotCli.ps1` (NEW FILE)

```powershell
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
```

### Part 3: Help Text Update

#### File: `src\Robocurse\Public\Main.ps1`

**Update `Show-RobocurseHelp`:**

```powershell
function Show-RobocurseHelp {
    $helpText = @"
ROBOCURSE - Chunked Robocopy Orchestrator with VSS Support

USAGE:
    .\Robocurse.ps1 [options]

GENERAL OPTIONS:
    -Help               Show this help message
    -ConfigPath <path>  Path to configuration file (default: .\Robocurse.config.json)

GUI MODE (default):
    .\Robocurse.ps1

HEADLESS MODE:
    -Headless           Run without GUI
    -Profile <name>     Run specific profile
    -AllProfiles        Run all enabled profiles
    -DryRun             Preview changes without copying

SNAPSHOT MANAGEMENT:
    -ListSnapshots                      List all VSS snapshots
    -ListSnapshots -Volume D:           List snapshots for specific volume
    -ListSnapshots -Server Server01     List snapshots on remote server

    -CreateSnapshot -Volume D:          Create snapshot on local volume
    -CreateSnapshot -Volume D: -Server Server01    Create on remote server
    -CreateSnapshot -Volume D: -KeepCount 5        Create with retention

    -DeleteSnapshot -ShadowId {guid}    Delete snapshot by ID
    -DeleteSnapshot -ShadowId {guid} -Server Server01    Delete remote snapshot

SNAPSHOT SCHEDULES:
    -SnapshotSchedule                   List configured schedules
    -SnapshotSchedule -List             List configured schedules
    -SnapshotSchedule -Sync             Sync schedules with config file
    -SnapshotSchedule -Remove -ScheduleName DailyD    Remove a schedule

EXAMPLES:
    # GUI mode
    .\Robocurse.ps1

    # Run specific profile headless
    .\Robocurse.ps1 -Headless -Profile "DailyBackup"

    # List all local snapshots
    .\Robocurse.ps1 -ListSnapshots

    # Create snapshot with retention
    .\Robocurse.ps1 -CreateSnapshot -Volume D: -KeepCount 5

    # Sync snapshot schedules from config
    .\Robocurse.ps1 -SnapshotSchedule -Sync

"@
    Write-Host $helpText
}
```

## Test Plan

### File: `tests\Unit\SnapshotCli.Tests.ps1`

```powershell
BeforeAll {
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Utility.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Logging.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssCore.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssLocal.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\VssRemote.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\SnapshotSchedule.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\SnapshotCli.ps1"

    Mock Write-RobocurseLog {}
    Mock Write-Host {}
}

Describe "Invoke-ListSnapshotsCommand" {
    Context "Local snapshots" {
        BeforeAll {
            Mock Get-VssSnapshots {
                New-OperationResult -Success $true -Data @(
                    [PSCustomObject]@{
                        ShadowId = "{snap1}"
                        SourceVolume = "C:"
                        CreatedAt = (Get-Date)
                    }
                )
            }
        }

        It "Calls Get-VssSnapshots for local" {
            Invoke-ListSnapshotsCommand
            Should -Invoke Get-VssSnapshots -Times 1
        }

        It "Returns 0 on success" {
            $result = Invoke-ListSnapshotsCommand
            $result | Should -Be 0
        }
    }

    Context "Remote snapshots" {
        BeforeAll {
            Mock Get-RemoteVssSnapshots {
                New-OperationResult -Success $true -Data @()
            }
        }

        It "Calls Get-RemoteVssSnapshots when -Server specified" {
            Invoke-ListSnapshotsCommand -Server "Server01"
            Should -Invoke Get-RemoteVssSnapshots -Times 1 -ParameterFilter {
                $ServerName -eq "Server01"
            }
        }
    }

    Context "When error occurs" {
        BeforeAll {
            Mock Get-VssSnapshots {
                New-OperationResult -Success $false -ErrorMessage "Access denied"
            }
        }

        It "Returns 1 on error" {
            $result = Invoke-ListSnapshotsCommand
            $result | Should -Be 1
        }
    }
}

Describe "Invoke-CreateSnapshotCommand" {
    BeforeAll {
        Mock Invoke-VssRetentionPolicy { New-OperationResult -Success $true -Data @{ DeletedCount = 0; KeptCount = 2 } }
        Mock New-VssSnapshot { New-OperationResult -Success $true -Data @{ ShadowId = "{new-snap}" } }
    }

    It "Enforces retention before creating" {
        Invoke-CreateSnapshotCommand -Volume "D:" -KeepCount 5

        Should -Invoke Invoke-VssRetentionPolicy -Times 1 -ParameterFilter {
            $Volume -eq "D:" -and $KeepCount -eq 5
        }
    }

    It "Creates snapshot after retention" {
        Invoke-CreateSnapshotCommand -Volume "D:"
        Should -Invoke New-VssSnapshot -Times 1
    }

    It "Returns 0 on success" {
        $result = Invoke-CreateSnapshotCommand -Volume "D:"
        $result | Should -Be 0
    }

    Context "Remote creation" {
        BeforeAll {
            Mock Invoke-RemoteVssRetentionPolicy { New-OperationResult -Success $true }
            Mock New-RemoteVssSnapshot { New-OperationResult -Success $true -Data @{ ShadowId = "{remote}" } }
        }

        It "Uses remote functions when -Server specified" {
            Invoke-CreateSnapshotCommand -Volume "D:" -Server "Server01"
            Should -Invoke Invoke-RemoteVssRetentionPolicy -Times 1
            Should -Invoke New-RemoteVssSnapshot -Times 1
        }
    }
}

Describe "Invoke-DeleteSnapshotCommand" {
    BeforeAll {
        Mock Read-Host { "y" }  # Auto-confirm
        Mock Remove-VssSnapshot { New-OperationResult -Success $true -Data "{deleted}" }
    }

    It "Prompts for confirmation" {
        Invoke-DeleteSnapshotCommand -ShadowId "{test}"
        Should -Invoke Read-Host -Times 1
    }

    It "Deletes when confirmed" {
        Invoke-DeleteSnapshotCommand -ShadowId "{test}"
        Should -Invoke Remove-VssSnapshot -Times 1
    }

    Context "When user cancels" {
        BeforeAll {
            Mock Read-Host { "n" }
        }

        It "Does not delete" {
            Invoke-DeleteSnapshotCommand -ShadowId "{test}"
            Should -Not -Invoke Remove-VssSnapshot
        }

        It "Returns 0 (not an error)" {
            $result = Invoke-DeleteSnapshotCommand -ShadowId "{test}"
            $result | Should -Be 0
        }
    }
}

Describe "Invoke-SnapshotScheduleCommand" {
    BeforeAll {
        Mock Get-SnapshotScheduledTasks { @() }
    }

    Context "-List (default)" {
        It "Lists schedules" {
            Invoke-SnapshotScheduleCommand -List
            Should -Invoke Get-SnapshotScheduledTasks -Times 1
        }
    }

    Context "-Sync" {
        BeforeAll {
            Mock Sync-SnapshotSchedules {
                New-OperationResult -Success $true -Data @{ Created = 1; Removed = 0; Total = 1 }
            }
        }

        It "Syncs schedules from config" {
            $config = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    SnapshotSchedules = @()
                }
            }

            Invoke-SnapshotScheduleCommand -Sync -Config $config
            Should -Invoke Sync-SnapshotSchedules -Times 1
        }
    }

    Context "-Remove" {
        BeforeAll {
            Mock Remove-SnapshotScheduledTask { New-OperationResult -Success $true }
        }

        It "Removes schedule by name" {
            Invoke-SnapshotScheduleCommand -Remove -ScheduleName "TestSchedule"
            Should -Invoke Remove-SnapshotScheduledTask -Times 1 -ParameterFilter {
                $ScheduleName -eq "TestSchedule"
            }
        }
    }
}
```

## Files to Create
- `src\Robocurse\Public\SnapshotCli.ps1` - CLI command functions
- `tests\Unit\SnapshotCli.Tests.ps1` - Unit tests

## Files to Modify
- `src\Robocurse\Public\Main.ps1` - Add parameters and help text
- `src\Robocurse\Robocurse.psd1` - Add SnapshotCli.ps1 to module

## Verification
```powershell
# Run unit tests
Invoke-Pester -Path tests\Unit\SnapshotCli.Tests.ps1 -Output Detailed

# Manual verification (requires admin)
.\Robocurse.ps1 -Help

.\Robocurse.ps1 -ListSnapshots
.\Robocurse.ps1 -ListSnapshots -Volume C:

.\Robocurse.ps1 -CreateSnapshot -Volume C: -KeepCount 3

.\Robocurse.ps1 -SnapshotSchedule -List
.\Robocurse.ps1 -SnapshotSchedule -Sync
```

## Dependencies
- Task 01 (VssSnapshotCore) - For snapshot operations
- Task 02 (VssSnapshotRemote) - For remote operations
- Task 04 (SnapshotScheduler) - For schedule management

## Notes
- Delete command requires interactive confirmation (y/N)
- Remote snapshots use admin share format (\\server\D$)
- Exit codes: 0 = success, 1 = error
- -SnapshotSchedule without sub-command defaults to -List
- -Add for schedules shows config example (interactive add is complex)
- Console output uses color coding: Cyan=headers, Green=success, Red=error, Yellow=warning
