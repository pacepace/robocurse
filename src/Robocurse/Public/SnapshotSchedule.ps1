# Robocurse VSS Snapshot Scheduling
# Manages Windows Task Scheduler tasks for automated snapshot creation

$script:SnapshotTaskPrefix = "Robocurse-Snapshot-"

# Pattern for valid hostnames: letters, numbers, hyphens, dots (no shell metacharacters)
$script:SafeHostnamePattern = '^[a-zA-Z0-9]([a-zA-Z0-9\-\.]{0,253}[a-zA-Z0-9])?$'

# Pattern for valid file paths: no shell metacharacters that could escape single quotes
$script:SafePathPattern = '^[^''`$;|&<>]+$'

function Test-SafeScheduleParameter {
    <#
    .SYNOPSIS
        Validates that a schedule parameter is safe for embedding in a command string
    .DESCRIPTION
        Prevents command injection by validating that parameters don't contain
        shell metacharacters that could escape single-quoted strings.
    .PARAMETER Value
        The value to validate
    .PARAMETER ParameterName
        Name of the parameter (for error messages)
    .PARAMETER Pattern
        Regex pattern the value must match
    .OUTPUTS
        OperationResult - Success=$true if safe, Success=$false with error message if not
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$ParameterName,

        [Parameter(Mandatory)]
        [string]$Pattern
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return New-OperationResult -Success $true
    }

    if ($Value -notmatch $Pattern) {
        $msg = "Invalid $ParameterName '$Value': contains unsafe characters. " +
               "Only alphanumeric characters, hyphens, and dots are allowed."
        Write-RobocurseLog -Message $msg -Level 'Error' -Component 'Schedule'
        return New-OperationResult -Success $false -ErrorMessage $msg
    }

    return New-OperationResult -Success $true
}

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
    .PARAMETER ConfigPath
        Path to the Robocurse config file (required for snapshot registry)
    .OUTPUTS
        OperationResult with Data = task name
    .EXAMPLE
        $schedule = [PSCustomObject]@{ Name = "HourlyD"; Volume = "D:"; Schedule = "Hourly"; Time = "00:00"; KeepCount = 24 }
        New-SnapshotScheduledTask -Schedule $schedule -ConfigPath "C:\Robocurse\config.json"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Schedule,

        [string]$RobocurseModulePath = $PSScriptRoot,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $taskName = "$script:SnapshotTaskPrefix$($Schedule.Name)"

    Write-RobocurseLog -Message "Creating snapshot schedule '$taskName' for $($Schedule.Volume)" -Level 'Info' -Component 'Schedule'

    try {
        # Build the PowerShell command to run
        $isRemote = [bool]$Schedule.ServerName
        $command = New-SnapshotTaskCommand -Schedule $Schedule -ModulePath $RobocurseModulePath -ConfigPath $ConfigPath

        # Create action
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$command`""

        # Create trigger based on schedule type
        $trigger = switch ($Schedule.Schedule) {
            "Hourly" {
                # Hourly requires repetition
                $t = New-ScheduledTaskTrigger -Once -At $Schedule.Time -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 9999)
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

function New-SnapshotTaskCommand {
    <#
    .SYNOPSIS
        Creates the PowerShell command string for a snapshot scheduled task
    .DESCRIPTION
        Generates the PowerShell command that will be executed by the scheduled task.
        Handles both local and remote snapshot creation with retention enforcement.
        Validates all parameters to prevent command injection.
    .PARAMETER Schedule
        A schedule definition object containing Volume, KeepCount, and optional ServerName
    .PARAMETER ModulePath
        Path to the Robocurse module for Import-Module in the task
    .PARAMETER ConfigPath
        Path to the Robocurse config file (required for snapshot registry)
    .OUTPUTS
        String containing the PowerShell command, or $null if validation fails
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Schedule,

        [string]$ModulePath,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $volume = $Schedule.Volume
    $keepCount = $Schedule.KeepCount
    $isRemote = [bool]$Schedule.ServerName
    $serverName = $Schedule.ServerName

    # Security: Validate parameters to prevent command injection
    # These values are embedded in single-quoted strings in the command
    if ($isRemote) {
        $serverCheck = Test-SafeScheduleParameter -Value $serverName -ParameterName "ServerName" -Pattern $script:SafeHostnamePattern
        if (-not $serverCheck.Success) {
            throw $serverCheck.ErrorMessage
        }
    }

    $pathCheck = Test-SafeScheduleParameter -Value $ModulePath -ParameterName "ModulePath" -Pattern $script:SafePathPattern
    if (-not $pathCheck.Success) {
        throw $pathCheck.ErrorMessage
    }

    $configPathCheck = Test-SafeScheduleParameter -Value $ConfigPath -ParameterName "ConfigPath" -Pattern $script:SafePathPattern
    if (-not $configPathCheck.Success) {
        throw $configPathCheck.ErrorMessage
    }

    # Volume is already validated by ValidatePattern in the calling functions

    if ($isRemote) {
        # Remote snapshot command
        $cmd = @"
Import-Module '$ModulePath\Robocurse.psd1' -Force;
`$cfg = Get-RobocurseConfig -Path '$ConfigPath';
`$r = Invoke-RemoteVssRetentionPolicy -ServerName '$serverName' -Volume '$volume' -KeepCount $keepCount -Config `$cfg -ConfigPath '$ConfigPath';
if (`$r.Success) { `$s = New-RemoteVssSnapshot -UncPath '\\$serverName\$volume`$'; if (`$s.Success) { Register-PersistentSnapshot -Config `$cfg -Volume '$volume' -ShadowId `$s.Data.ShadowId -ConfigPath '$ConfigPath' } };
exit ([int](-not `$r.Success))
"@
    }
    else {
        # Local snapshot command
        $cmd = @"
Import-Module '$ModulePath\Robocurse.psd1' -Force;
`$cfg = Get-RobocurseConfig -Path '$ConfigPath';
`$r = Invoke-VssRetentionPolicy -Volume '$volume' -KeepCount $keepCount -Config `$cfg -ConfigPath '$ConfigPath';
if (`$r.Success) { `$s = New-VssSnapshot -SourcePath '$volume\'; if (`$s.Success) { Register-PersistentSnapshot -Config `$cfg -Volume '$volume' -ShadowId `$s.Data.ShadowId -ConfigPath '$ConfigPath' } };
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
    .PARAMETER ConfigPath
        Path to the configuration file (required for snapshot registry in scheduled tasks)
    .OUTPUTS
        OperationResult with Data = summary of changes
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory)]
        [string]$ConfigPath
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
        $result = New-SnapshotScheduledTask -Schedule $schedule -ConfigPath $ConfigPath
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
