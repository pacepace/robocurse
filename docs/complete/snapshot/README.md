# VSS Snapshot Feature - Task Documents

## Overview
This directory contains context-sharded task documents for implementing the VSS Snapshot feature in Robocurse. Tasks are designed to be ~500 LOC each, suitable for execution by AI subagents.

## Feature Summary
Add persistent VSS snapshot management with:
- Create/list/delete snapshots (local and remote)
- Retention policies per volume
- Profile integration (snapshot at backup start)
- Independent scheduled snapshots
- Full GUI management panel
- CLI commands

## Execution Order
Tasks must be executed sequentially in order:

| # | Task | Description | Est. LOC |
|---|------|-------------|----------|
| 01 | [VssSnapshotCore](01-VssSnapshotCore.md) | Core functions: `Get-VssSnapshots`, `Invoke-VssRetentionPolicy` | ~300 |
| 02 | [VssSnapshotRemote](02-VssSnapshotRemote.md) | Remote versions via CIM sessions | ~250 |
| 03 | [ProfileSnapshotIntegration](03-ProfileSnapshotIntegration.md) | Config schema, profile execution hook | ~400 |
| 04 | [SnapshotScheduler](04-SnapshotScheduler.md) | Windows Task Scheduler integration | ~350 |
| 05 | [GuiSnapshotPanel](05-GuiSnapshotPanel.md) | New Snapshots panel with DataGrid | ~400 |
| 06 | [GuiSnapshotActions](06-GuiSnapshotActions.md) | Create/Delete dialogs and actions | ~350 |
| 07 | [GuiProfileSnapshotSettings](07-GuiProfileSnapshotSettings.md) | Profile and Settings panel controls | ~300 |
| 08 | [CliSnapshotCommands](08-CliSnapshotCommands.md) | CLI commands for snapshot management | ~350 |

## Task Document Structure
Each task follows EAD format:
- **Objective** - What the task accomplishes
- **Success Criteria** - Checkboxes for completion
- **Research** - File:line references to existing code
- **Implementation** - Code to add/modify
- **Test Plan** - Pester test code
- **Files to Modify/Create** - Exact paths
- **Verification** - Manual test commands
- **Dependencies** - Previous tasks required

## Running Tests
After completing each task:
```powershell
# Run specific task's tests
Invoke-Pester -Path tests\Unit\<TestFile>.Tests.ps1 -Output Detailed

# Or use the test runner (avoids truncation)
.\scripts\run-tests.ps1
```

## Key Dependencies
- Tasks build incrementally - complete in order
- Tasks 01-02 are pure VSS functions (no GUI/CLI)
- Tasks 03-04 add integration (profile execution, schedules)
- Tasks 05-07 add GUI
- Task 08 adds CLI

## Configuration Example
After all tasks complete, config will support:
```json
{
  "profiles": {
    "DailyBackup": {
      "source": { "path": "D:\\Data", "useVss": true },
      "destination": { "path": "E:\\Backup" },
      "persistentSnapshot": { "enabled": true }
    }
  },
  "global": {
    "snapshotRetention": {
      "defaultKeepCount": 3,
      "volumeOverrides": { "D:": 5, "E:": 10 }
    },
    "snapshotSchedules": [
      {
        "name": "HourlyD",
        "volume": "D:",
        "schedule": "Hourly",
        "time": "00:00",
        "keepCount": 24,
        "enabled": true
      }
    ]
  }
}
```

## CLI Usage (After Task 08)
```powershell
# List snapshots
.\Robocurse.ps1 -ListSnapshots
.\Robocurse.ps1 -ListSnapshots -Volume D: -Server FileServer01

# Create snapshot
.\Robocurse.ps1 -CreateSnapshot -Volume D: -KeepCount 5

# Delete snapshot
.\Robocurse.ps1 -DeleteSnapshot -ShadowId "{guid}"

# Manage schedules
.\Robocurse.ps1 -SnapshotSchedule -List
.\Robocurse.ps1 -SnapshotSchedule -Sync
```
