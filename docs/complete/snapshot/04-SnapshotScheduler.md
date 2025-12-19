# Task: Independent Snapshot Scheduler

## Objective
Add support for scheduled VSS snapshots independent of backup profile execution. This enables point-in-time snapshots on a schedule (e.g., hourly, daily) separate from backup runs.

## Success Criteria
- [ ] Configuration supports snapshot schedule definitions
- [ ] `New-SnapshotScheduledTask` creates Windows Task Scheduler task
- [ ] `Remove-SnapshotScheduledTask` removes the scheduled task
- [ ] Schedule supports multiple volumes with different retention
- [ ] CLI command to manage snapshot schedules
- [ ] Tests verify task creation/removal

## Research

### Windows Task Scheduler PowerShell
```powershell
# Create a scheduled task
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command ..."
$trigger = New-ScheduledTaskTrigger -Daily -At "02:00"
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
Register-ScheduledTask -TaskName "Robocurse-Snapshot-D" -Action $action -Trigger $trigger -Principal $principal

# Remove a scheduled task
Unregister-ScheduledTask -TaskName "Robocurse-Snapshot-D" -Confirm:$false

# List tasks
Get-ScheduledTask -TaskName "Robocurse-*"
```

### Existing Schedule Pattern (file:line references)
- `Schedule.ps1` - Existing backup schedule management (if exists)
- The backup already uses Windows Task Scheduler for scheduled runs

### Configuration Approach
Add to GlobalSettings:
```json
"snapshotSchedules": [
  {
    "name": "HourlyD",
    "volume": "D:",
    "schedule": "Hourly",
    "time": "00:00",
    "keepCount": 24
  },
  {
    "name": "DailyE",
    "volume": "E:",
    "schedule": "Daily",
    "time": "02:00",
    "keepCount": 7
  }
]
```

## Implementation

### Part 1: Configuration Schema

#### File: `src\Robocurse\Public\Configuration.ps1`

**Update `New-DefaultConfig`:**

```powershell
GlobalSettings = [PSCustomObject]@{
    # ... existing settings ...
    SnapshotSchedules = @()  # Array of schedule definitions
}
```

**Update `ConvertFrom-GlobalSettings`:**

```powershell
# Add after snapshotRetention handling
if ($RawGlobal.snapshotSchedules) {
    $schedules = @()
    foreach ($rawSched in $RawGlobal.snapshotSchedules) {
        $schedules += [PSCustomObject]@{
            Name = $rawSched.name
            Volume = $rawSched.volume.ToUpper()
            Schedule = $rawSched.schedule  # "Hourly", "Daily", "Weekly"
            Time = $rawSched.time          # "HH:MM" format
            DaysOfWeek = if ($rawSched.daysOfWeek) { @($rawSched.daysOfWeek) } else { @() }
            KeepCount = if ($rawSched.keepCount) { [int]$rawSched.keepCount } else { 3 }
            Enabled = if ($null -ne $rawSched.enabled) { [bool]$rawSched.enabled } else { $true }
            ServerName = $rawSched.serverName  # For remote volumes
        }
    }
    $Config.GlobalSettings.SnapshotSchedules = $schedules
}
```

### Part 2: Schedule Management Functions

#### File: `src\Robocurse\Public\SnapshotSchedule.ps1` (NEW FILE)

```powershell
# Robocurse VSS Snapshot Scheduling
# Manages Windows Task Scheduler tasks for automated snapshot creation

$script:SnapshotTaskPrefix = "Robocurse-Snapshot-"

function New-SnapshotScheduledTask {
    <#
    .SYNOPSIS
        Creates a Windows scheduled task for VSS snapshot creation
    .DESCRIPTION
        Registers a scheduled task that runs PowerShell to create VSS snapshots
        and enforce retention for a specific volume.
    .PARAMETER Schedule
        A schedule definition object from config
    .PARAMETER RobocurseModulePath
        Path to the Robocurse module (for task script)
    .OUTPUTS
        OperationResult with Data = task name
    .EXAMPLE
        $schedule = [PSCustomObject]@{ Name = "HourlyD"; Volume = "D:"; Schedule = "Hourly"; Time = "00:00"; KeepCount = 24 }
        New-SnapshotScheduledTask -Schedule $schedule
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Schedule,

        [string]$RobocurseModulePath = $PSScriptRoot
    )

    $taskName = "$script:SnapshotTaskPrefix$($Schedule.Name)"

    Write-RobocurseLog -Message "Creating snapshot schedule '$taskName' for $($Schedule.Volume)" -Level 'Info' -Component 'Schedule'

    try {
        # Build the PowerShell command to run
        $isRemote = [bool]$Schedule.ServerName
        $command = Build-SnapshotTaskCommand -Schedule $Schedule -ModulePath $RobocurseModulePath

        # Create action
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$command`""

        # Create trigger based on schedule type
        $trigger = switch ($Schedule.Schedule) {
            "Hourly" {
                # Hourly requires repetition
                $t = New-ScheduledTaskTrigger -Once -At $Schedule.Time
                $t.Repetition = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 9999)
                $t
            }
            "Daily" {
                New-ScheduledTaskTrigger -Daily -At $Schedule.Time
            }
            "Weekly" {
                $days = if ($Schedule.DaysOfWeek.Count -gt 0) {
                    $Schedule.DaysOfWeek
                } else {
                    @("Sunday")
                }
                New-ScheduledTaskTrigger -Weekly -DaysOfWeek $days -At $Schedule.Time
            }
            default {
                throw "Unknown schedule type: $($Schedule.Schedule)"
            }
        }

        # Run as SYSTEM with highest privileges (required for VSS)
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

        # Settings
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RunOnlyIfNetworkAvailable:$isRemote `
            -MultipleInstances IgnoreNew

        # Remove existing task if present
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-RobocurseLog -Message "Removed existing task '$taskName'" -Level 'Debug' -Component 'Schedule'
        }

        # Register the task
        $task = Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Description "Robocurse VSS Snapshot for $($Schedule.Volume)"

        Write-RobocurseLog -Message "Created snapshot schedule '$taskName'" -Level 'Info' -Component 'Schedule'

        return New-OperationResult -Success $true -Data $taskName
    }
    catch {
        Write-RobocurseLog -Message "Failed to create snapshot schedule: $($_.Exception.Message)" -Level 'Error' -Component 'Schedule'
        return New-OperationResult -Success $false -ErrorMessage "Failed to create schedule '$taskName': $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Build-SnapshotTaskCommand {
    <#
    .SYNOPSIS
        Builds the PowerShell command for the scheduled task
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Schedule,

        [string]$ModulePath
    )

    $volume = $Schedule.Volume
    $keepCount = $Schedule.KeepCount
    $isRemote = [bool]$Schedule.ServerName
    $serverName = $Schedule.ServerName

    if ($isRemote) {
        # Remote snapshot command
        $cmd = @"
Import-Module '$ModulePath\Robocurse.psd1' -Force;
`$r = Invoke-RemoteVssRetentionPolicy -ServerName '$serverName' -Volume '$volume' -KeepCount $keepCount;
if (`$r.Success) { `$s = New-RemoteVssSnapshot -UncPath '\\$serverName\$volume`$' };
exit ([int](-not `$r.Success))
"@
    }
    else {
        # Local snapshot command
        $cmd = @"
Import-Module '$ModulePath\Robocurse.psd1' -Force;
`$r = Invoke-VssRetentionPolicy -Volume '$volume' -KeepCount $keepCount;
if (`$r.Success) { `$s = New-VssSnapshot -SourcePath '$volume\' };
exit ([int](-not `$r.Success))
"@
    }

    return $cmd -replace "`r`n", "; " -replace "`n", "; "
}

function Remove-SnapshotScheduledTask {
    <#
    .SYNOPSIS
        Removes a snapshot scheduled task
    .PARAMETER ScheduleName
        The schedule name (without prefix)
    .OUTPUTS
        OperationResult
    .EXAMPLE
        Remove-SnapshotScheduledTask -ScheduleName "HourlyD"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ScheduleName
    )

    $taskName = "$script:SnapshotTaskPrefix$ScheduleName"

    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        if (-not $task) {
            Write-RobocurseLog -Message "Snapshot schedule '$taskName' not found" -Level 'Debug' -Component 'Schedule'
            return New-OperationResult -Success $true -Data "Task not found (already removed)"
        }

        if ($PSCmdlet.ShouldProcess($taskName, "Remove Scheduled Task")) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-RobocurseLog -Message "Removed snapshot schedule '$taskName'" -Level 'Info' -Component 'Schedule'
            return New-OperationResult -Success $true -Data $taskName
        }

        return New-OperationResult -Success $true -Data "WhatIf: Would remove $taskName"
    }
    catch {
        Write-RobocurseLog -Message "Failed to remove schedule '$taskName': $($_.Exception.Message)" -Level 'Error' -Component 'Schedule'
        return New-OperationResult -Success $false -ErrorMessage "Failed to remove schedule: $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Get-SnapshotScheduledTasks {
    <#
    .SYNOPSIS
        Lists all Robocurse snapshot scheduled tasks
    .OUTPUTS
        Array of scheduled task objects
    #>
    [CmdletBinding()]
    param()

    try {
        $tasks = Get-ScheduledTask -TaskName "$script:SnapshotTaskPrefix*" -ErrorAction SilentlyContinue

        if (-not $tasks) {
            return @()
        }

        return @($tasks | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.TaskName -replace "^$([regex]::Escape($script:SnapshotTaskPrefix))", ""
                TaskName = $_.TaskName
                State = $_.State
                Description = $_.Description
                LastRunTime = $_.LastRunTime
                NextRunTime = $_.Triggers[0].StartBoundary
            }
        })
    }
    catch {
        Write-RobocurseLog -Message "Failed to list snapshot schedules: $($_.Exception.Message)" -Level 'Warning' -Component 'Schedule'
        return @()
    }
}

function Sync-SnapshotSchedules {
    <#
    .SYNOPSIS
        Synchronizes scheduled tasks with configuration
    .DESCRIPTION
        Creates/updates/removes scheduled tasks to match the current configuration.
        Removes tasks not in config, creates tasks that are missing, updates changed tasks.
    .PARAMETER Config
        The Robocurse configuration object
    .OUTPUTS
        OperationResult with Data = summary of changes
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $schedules = @($Config.GlobalSettings.SnapshotSchedules | Where-Object { $_.Enabled })
    $existingTasks = Get-SnapshotScheduledTasks
    $existingNames = @($existingTasks | ForEach-Object { $_.Name })
    $configNames = @($schedules | ForEach-Object { $_.Name })

    $created = 0
    $removed = 0
    $errors = @()

    # Remove tasks not in config
    foreach ($existing in $existingTasks) {
        if ($existing.Name -notin $configNames) {
            $result = Remove-SnapshotScheduledTask -ScheduleName $existing.Name
            if ($result.Success) {
                $removed++
            }
            else {
                $errors += $result.ErrorMessage
            }
        }
    }

    # Create/update tasks from config
    foreach ($schedule in $schedules) {
        # Always recreate to ensure settings are current
        $result = New-SnapshotScheduledTask -Schedule $schedule
        if ($result.Success) {
            if ($schedule.Name -notin $existingNames) {
                $created++
            }
        }
        else {
            $errors += $result.ErrorMessage
        }
    }

    $summary = @{
        Created = $created
        Removed = $removed
        Total = $schedules.Count
        Errors = $errors
    }

    $success = $errors.Count -eq 0

    Write-RobocurseLog -Message "Snapshot schedules synced: $created created, $removed removed, $($schedules.Count) total" -Level 'Info' -Component 'Schedule'

    return New-OperationResult -Success $success -Data $summary -ErrorMessage $(if (-not $success) { $errors -join "; " })
}
```

## Test Plan

### File: `tests\Unit\SnapshotSchedule.Tests.ps1`

```powershell
BeforeAll {
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Utility.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Logging.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\SnapshotSchedule.ps1"

    Mock Write-RobocurseLog {}
}

Describe "Build-SnapshotTaskCommand" {
    It "Builds local snapshot command" {
        $schedule = [PSCustomObject]@{
            Name = "TestLocal"
            Volume = "D:"
            KeepCount = 5
            ServerName = $null
        }

        $cmd = Build-SnapshotTaskCommand -Schedule $schedule -ModulePath "C:\Test"
        $cmd | Should -Match "Invoke-VssRetentionPolicy"
        $cmd | Should -Match "-Volume 'D:'"
        $cmd | Should -Match "-KeepCount 5"
    }

    It "Builds remote snapshot command" {
        $schedule = [PSCustomObject]@{
            Name = "TestRemote"
            Volume = "E:"
            KeepCount = 10
            ServerName = "Server1"
        }

        $cmd = Build-SnapshotTaskCommand -Schedule $schedule -ModulePath "C:\Test"
        $cmd | Should -Match "Invoke-RemoteVssRetentionPolicy"
        $cmd | Should -Match "-ServerName 'Server1'"
        $cmd | Should -Match "New-RemoteVssSnapshot"
    }
}

Describe "New-SnapshotScheduledTask" {
    BeforeAll {
        Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
        Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Repetition = $null } }
        Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = "SYSTEM" } }
        Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{} }
        Mock Get-ScheduledTask { $null }
        Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Robocurse-Snapshot-Test" } }
    }

    It "Creates a daily schedule" {
        $schedule = [PSCustomObject]@{
            Name = "DailyD"
            Volume = "D:"
            Schedule = "Daily"
            Time = "02:00"
            KeepCount = 7
            Enabled = $true
            ServerName = $null
            DaysOfWeek = @()
        }

        $result = New-SnapshotScheduledTask -Schedule $schedule
        $result.Success | Should -Be $true

        Should -Invoke New-ScheduledTaskTrigger -ParameterFilter { $Daily -eq $true }
        Should -Invoke Register-ScheduledTask -Times 1
    }

    It "Removes existing task before creating" {
        Mock Get-ScheduledTask { [PSCustomObject]@{ TaskName = "Robocurse-Snapshot-Existing" } }
        Mock Unregister-ScheduledTask {}

        $schedule = [PSCustomObject]@{
            Name = "Existing"
            Volume = "D:"
            Schedule = "Daily"
            Time = "02:00"
            KeepCount = 3
            Enabled = $true
            ServerName = $null
            DaysOfWeek = @()
        }

        New-SnapshotScheduledTask -Schedule $schedule

        Should -Invoke Unregister-ScheduledTask -Times 1
    }
}

Describe "Remove-SnapshotScheduledTask" {
    Context "When task exists" {
        BeforeAll {
            Mock Get-ScheduledTask { [PSCustomObject]@{ TaskName = "Robocurse-Snapshot-Test" } }
            Mock Unregister-ScheduledTask {}
        }

        It "Removes the task" {
            $result = Remove-SnapshotScheduledTask -ScheduleName "Test"
            $result.Success | Should -Be $true
            Should -Invoke Unregister-ScheduledTask -Times 1
        }
    }

    Context "When task does not exist" {
        BeforeAll {
            Mock Get-ScheduledTask { $null }
        }

        It "Returns success (idempotent)" {
            $result = Remove-SnapshotScheduledTask -ScheduleName "NonExistent"
            $result.Success | Should -Be $true
        }
    }
}

Describe "Get-SnapshotScheduledTasks" {
    It "Returns empty array when no tasks exist" {
        Mock Get-ScheduledTask { $null }

        $tasks = Get-SnapshotScheduledTasks
        $tasks | Should -BeNullOrEmpty
    }

    It "Strips prefix from task names" {
        Mock Get-ScheduledTask {
            @(
                [PSCustomObject]@{
                    TaskName = "Robocurse-Snapshot-DailyD"
                    State = "Ready"
                    Description = "Test"
                    LastRunTime = (Get-Date).AddDays(-1)
                    Triggers = @([PSCustomObject]@{ StartBoundary = "02:00" })
                }
            )
        }

        $tasks = Get-SnapshotScheduledTasks
        $tasks.Count | Should -Be 1
        $tasks[0].Name | Should -Be "DailyD"
    }
}

Describe "Sync-SnapshotSchedules" {
    BeforeAll {
        Mock Get-SnapshotScheduledTasks { @() }
        Mock New-SnapshotScheduledTask { New-OperationResult -Success $true -Data "Created" }
        Mock Remove-SnapshotScheduledTask { New-OperationResult -Success $true -Data "Removed" }
    }

    It "Creates tasks from config" {
        $config = [PSCustomObject]@{
            GlobalSettings = [PSCustomObject]@{
                SnapshotSchedules = @(
                    [PSCustomObject]@{ Name = "Test1"; Volume = "D:"; Schedule = "Daily"; Time = "02:00"; KeepCount = 3; Enabled = $true }
                )
            }
        }

        $result = Sync-SnapshotSchedules -Config $config
        $result.Success | Should -Be $true
        $result.Data.Created | Should -Be 1
    }

    It "Removes tasks not in config" {
        Mock Get-SnapshotScheduledTasks {
            @([PSCustomObject]@{ Name = "Orphan"; TaskName = "Robocurse-Snapshot-Orphan" })
        }

        $config = [PSCustomObject]@{
            GlobalSettings = [PSCustomObject]@{
                SnapshotSchedules = @()
            }
        }

        $result = Sync-SnapshotSchedules -Config $config
        Should -Invoke Remove-SnapshotScheduledTask -Times 1 -ParameterFilter { $ScheduleName -eq "Orphan" }
    }
}
```

## Files to Create
- `src\Robocurse\Public\SnapshotSchedule.ps1` - Schedule management functions
- `tests\Unit\SnapshotSchedule.Tests.ps1` - Unit tests

## Files to Modify
- `src\Robocurse\Public\Configuration.ps1` - Add SnapshotSchedules to GlobalSettings
- `src\Robocurse\Robocurse.psd1` - Add SnapshotSchedule.ps1 to FunctionsToExport

## Verification
```powershell
# Run unit tests
Invoke-Pester -Path tests\Unit\SnapshotSchedule.Tests.ps1 -Output Detailed

# Manual verification (requires admin)
$schedule = [PSCustomObject]@{
    Name = "TestDaily"
    Volume = "C:"
    Schedule = "Daily"
    Time = "03:00"
    KeepCount = 3
    Enabled = $true
    ServerName = $null
    DaysOfWeek = @()
}
New-SnapshotScheduledTask -Schedule $schedule

# Verify in Task Scheduler
Get-ScheduledTask -TaskName "Robocurse-Snapshot-*"

# Clean up
Remove-SnapshotScheduledTask -ScheduleName "TestDaily"
```

## Dependencies
- Task 01 (VssSnapshotCore) - For `Invoke-VssRetentionPolicy`, `New-VssSnapshot`
- Task 02 (VssSnapshotRemote) - For `Invoke-RemoteVssRetentionPolicy`, `New-RemoteVssSnapshot`

## Notes
- Scheduled tasks run as SYSTEM for admin privileges
- Hourly schedules use repetition on a daily trigger
- Tasks are idempotent - re-creating updates the existing task
- `Sync-SnapshotSchedules` is called when config changes (GUI/CLI)
- Remote schedules require network availability setting
