# Task 09: Task Scheduler Integration

## Overview
Implement Windows Task Scheduler integration to enable automated daily/weekly sync runs.

## Research Required

### Web Research
- `Register-ScheduledTask` cmdlet
- `New-ScheduledTaskTrigger` options
- `New-ScheduledTaskPrincipal` for running as SYSTEM
- Task Scheduler security contexts

### Key Concepts
- **Principal**: User context task runs under
- **Trigger**: When task runs (time, schedule)
- **Action**: What task executes (PowerShell script)
- **Settings**: Execution policies, timeouts, etc.

## Task Description

### Function: Register-RobocurseTask
```powershell
function Register-RobocurseTask {
    <#
    .SYNOPSIS
        Creates or updates a scheduled task for Robocurse
    .PARAMETER TaskName
        Name for the scheduled task
    .PARAMETER ConfigPath
        Path to config file
    .PARAMETER Schedule
        Schedule type: Daily, Weekly, Hourly
    .PARAMETER Time
        Time to run (HH:mm format)
    .PARAMETER DaysOfWeek
        Days for weekly schedule (Sunday, Monday, etc.)
    .PARAMETER RunAsSystem
        Run as SYSTEM account (requires admin)
    #>
    param(
        [string]$TaskName = "Robocurse-Replication",

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [ValidateSet('Daily', 'Weekly', 'Hourly')]
        [string]$Schedule = 'Daily',

        [string]$Time = "02:00",

        [string[]]$DaysOfWeek = @('Sunday'),

        [switch]$RunAsSystem
    )

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = $MyInvocation.MyCommand.Path
    }

    # Build action
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Headless -ConfigPath `"$ConfigPath`""

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument $arguments `
        -WorkingDirectory (Split-Path $scriptPath -Parent)

    # Build trigger based on schedule
    $trigger = switch ($Schedule) {
        'Daily' {
            New-ScheduledTaskTrigger -Daily -At $Time
        }
        'Weekly' {
            New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DaysOfWeek -At $Time
        }
        'Hourly' {
            New-ScheduledTaskTrigger -Once -At $Time `
                -RepetitionInterval (New-TimeSpan -Hours 1) `
                -RepetitionDuration (New-TimeSpan -Days 1)
        }
    }

    # Build principal
    $principal = if ($RunAsSystem) {
        New-ScheduledTaskPrincipal `
            -UserId "SYSTEM" `
            -LogonType ServiceAccount `
            -RunLevel Highest
    }
    else {
        New-ScheduledTaskPrincipal `
            -UserId $env:USERNAME `
            -LogonType S4U `
            -RunLevel Highest
    }

    # Build settings
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 72) `
        -Priority 7

    # Register task
    $taskParams = @{
        TaskName = $TaskName
        Action = $action
        Trigger = $trigger
        Principal = $principal
        Settings = $settings
        Description = "Robocurse automatic directory replication"
        Force = $true
    }

    try {
        Register-ScheduledTask @taskParams
        Write-RobocurseLog -Message "Scheduled task '$TaskName' registered successfully" -Level 'Info' -Component 'Scheduler'
        return $true
    }
    catch {
        Write-RobocurseLog -Message "Failed to register scheduled task: $_" -Level 'Error' -Component 'Scheduler'
        return $false
    }
}
```

### Function: Unregister-RobocurseTask
```powershell
function Unregister-RobocurseTask {
    <#
    .SYNOPSIS
        Removes the Robocurse scheduled task
    .PARAMETER TaskName
        Name of task to remove
    #>
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-RobocurseLog -Message "Scheduled task '$TaskName' removed" -Level 'Info' -Component 'Scheduler'
        return $true
    }
    catch {
        Write-RobocurseLog -Message "Failed to remove scheduled task: $_" -Level 'Error' -Component 'Scheduler'
        return $false
    }
}
```

### Function: Get-RobocurseTask
```powershell
function Get-RobocurseTask {
    <#
    .SYNOPSIS
        Gets information about the Robocurse scheduled task
    .PARAMETER TaskName
        Name of task to query
    .OUTPUTS
        Task info object or $null if not found
    #>
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $TaskName

        return [PSCustomObject]@{
            Name = $task.TaskName
            State = $task.State
            Enabled = ($task.State -eq 'Ready')
            NextRunTime = $info.NextRunTime
            LastRunTime = $info.LastRunTime
            LastResult = $info.LastTaskResult
            Triggers = $task.Triggers | ForEach-Object {
                [PSCustomObject]@{
                    Type = $_.CimClass.CimClassName -replace 'MSFT_Task', '' -replace 'Trigger', ''
                    Enabled = $_.Enabled
                }
            }
        }
    }
    catch {
        return $null
    }
}
```

### Function: Start-RobocurseTask
```powershell
function Start-RobocurseTask {
    <#
    .SYNOPSIS
        Manually triggers the scheduled task
    .PARAMETER TaskName
        Name of task to start
    #>
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        Start-ScheduledTask -TaskName $TaskName
        Write-RobocurseLog -Message "Manually triggered task '$TaskName'" -Level 'Info' -Component 'Scheduler'
        return $true
    }
    catch {
        Write-RobocurseLog -Message "Failed to start task: $_" -Level 'Error' -Component 'Scheduler'
        return $false
    }
}
```

### Function: Enable-RobocurseTask
```powershell
function Enable-RobocurseTask {
    <#
    .SYNOPSIS
        Enables the scheduled task
    #>
    param([string]$TaskName = "Robocurse-Replication")

    Enable-ScheduledTask -TaskName $TaskName
}
```

### Function: Disable-RobocurseTask
```powershell
function Disable-RobocurseTask {
    <#
    .SYNOPSIS
        Disables the scheduled task (keeps it but won't run)
    #>
    param([string]$TaskName = "Robocurse-Replication")

    Disable-ScheduledTask -TaskName $TaskName
}
```

### Headless Mode Entry Point
```powershell
# In main script entry point
if ($Headless) {
    Write-Host "Robocurse starting in headless mode..."
    Write-Host "Config: $ConfigPath"
    Write-Host "Profile filter: $(if ($Profile) { $Profile } else { 'All enabled' })"

    # Load config
    $config = Get-RobocurseConfig -Path $ConfigPath
    if (-not $config) {
        Write-Error "Failed to load config from $ConfigPath"
        exit 1
    }

    # Initialize logging
    $session = Initialize-LogSession -LogRoot $config.GlobalSettings.LogPath

    # Run log rotation
    Invoke-LogRotation -LogRoot $config.GlobalSettings.LogPath `
        -DeleteAfterDays $config.GlobalSettings.LogRetentionDays

    # Get profiles to run
    $profilesToRun = if ($Profile) {
        $config.SyncProfiles | Where-Object { $_.Name -eq $Profile -and $_.Enabled }
    }
    else {
        $config.SyncProfiles | Where-Object { $_.Enabled }
    }

    if ($profilesToRun.Count -eq 0) {
        Write-Error "No enabled profiles found"
        exit 1
    }

    # Run replication
    $results = Start-ReplicationRun -Profiles $profilesToRun -MaxConcurrentJobs $config.GlobalSettings.MaxConcurrentJobs

    # Send notification
    if ($config.Email.Enabled) {
        $status = if ($results.FailedCount -gt 0) { 'Failed' }
                  elseif ($results.WarningCount -gt 0) { 'Warning' }
                  else { 'Success' }

        Send-CompletionEmail -Config $config.Email -Results $results -Status $status
    }

    # Exit with appropriate code
    exit $(if ($results.FailedCount -gt 0) { 1 } else { 0 })
}
```

## Success Criteria

1. [ ] Task created with correct schedule
2. [ ] Task runs PowerShell with correct arguments
3. [ ] Task runs as SYSTEM when specified
4. [ ] Task can be enabled/disabled
5. [ ] Task info can be queried
6. [ ] Manual task trigger works
7. [ ] Headless mode executes successfully

## Pester Tests Required

Create `tests/Unit/Scheduling.Tests.ps1`:

```powershell
Describe "Scheduling" {
    BeforeAll {
        . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
    }

    Context "Register-RobocurseTask" {
        It "Should create task with daily trigger" {
            Mock Register-ScheduledTask { return $true }

            $result = Register-RobocurseTask -ConfigPath "C:\test\config.json" -Schedule "Daily" -Time "03:00"

            $result | Should -Be $true
            Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                $Trigger -ne $null
            }
        }
    }

    Context "Get-RobocurseTask" {
        It "Should return null when task doesn't exist" {
            Mock Get-ScheduledTask { throw "Task not found" }

            $result = Get-RobocurseTask -TaskName "NonExistent"

            $result | Should -Be $null
        }

        It "Should return task info when exists" {
            Mock Get-ScheduledTask {
                [PSCustomObject]@{
                    TaskName = "Robocurse-Replication"
                    State = "Ready"
                    Triggers = @()
                }
            }
            Mock Get-ScheduledTaskInfo {
                [PSCustomObject]@{
                    NextRunTime = (Get-Date).AddDays(1)
                    LastRunTime = (Get-Date).AddDays(-1)
                    LastTaskResult = 0
                }
            }

            $result = Get-RobocurseTask

            $result | Should -Not -Be $null
            $result.Name | Should -Be "Robocurse-Replication"
            $result.Enabled | Should -Be $true
        }
    }
}
```

## Dependencies
- Task 00 (Project Structure)
- Task 01 (Configuration)
- Task 02 (Logging)
- Task 06 (Orchestration)
- Task 08 (Email) - for notifications

## Estimated Complexity
- Low-Medium
- Standard Task Scheduler cmdlets
