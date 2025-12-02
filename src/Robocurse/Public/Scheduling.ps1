# Robocurse Scheduling Functions
function Register-RobocurseTask {
    <#
    .SYNOPSIS
        Creates or updates a scheduled task for Robocurse
    .DESCRIPTION
        Registers a Windows scheduled task to run Robocurse automatically.
        Supports daily, weekly, and hourly schedules with flexible configuration.
    .PARAMETER TaskName
        Name for the scheduled task. Default: "Robocurse-Replication"
    .PARAMETER ConfigPath
        Path to config file (mandatory)
    .PARAMETER Schedule
        Schedule type: Daily, Weekly, Hourly. Default: Daily
    .PARAMETER Time
        Time to run in HH:mm format. Default: "02:00"
    .PARAMETER DaysOfWeek
        Days for weekly schedule (Sunday, Monday, etc.). Default: @('Sunday')
    .PARAMETER RunAsSystem
        Run as SYSTEM account (requires admin). Default: $false
    .OUTPUTS
        OperationResult - Success=$true with Data=$TaskName on success, Success=$false with ErrorMessage on failure
    .EXAMPLE
        $result = Register-RobocurseTask -ConfigPath "C:\config.json" -Schedule Daily -Time "03:00"
        if ($result.Success) { "Task registered: $($result.Data)" }
    .EXAMPLE
        $result = Register-RobocurseTask -ConfigPath "C:\config.json" -Schedule Weekly -DaysOfWeek @('Monday', 'Friday') -RunAsSystem
        if (-not $result.Success) { Write-Error $result.ErrorMessage }
    .EXAMPLE
        Register-RobocurseTask -ConfigPath "C:\config.json" -WhatIf
        # Shows what task would be created without actually registering it
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$TaskName = "Robocurse-Replication",

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath,

        [ValidateSet('Daily', 'Weekly', 'Hourly')]
        [string]$Schedule = 'Daily',

        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
        [string]$Time = "02:00",

        [ValidateNotNullOrEmpty()]
        [string[]]$DaysOfWeek = @('Sunday'),

        [switch]$RunAsSystem
    )

    try {
        # Check if running on Windows
        if (-not (Test-IsWindowsPlatform)) {
            Write-RobocurseLog -Message "Scheduled tasks are only supported on Windows" -Level 'Warning' -Component 'Scheduler'
            return New-OperationResult -Success $false -ErrorMessage "Scheduled tasks are only supported on Windows"
        }

        # Validate config path exists (inside function body so mocks can intercept)
        if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
            return New-OperationResult -Success $false -ErrorMessage "ConfigPath '$ConfigPath' does not exist or is not a file"
        }

        # Get script path - required to build the scheduled task action
        $scriptPath = $PSCommandPath
        if (-not $scriptPath) {
            $scriptPath = $MyInvocation.MyCommand.Path
        }
        if (-not $scriptPath) {
            return New-OperationResult -Success $false -ErrorMessage "Cannot determine Robocurse script path. When running interactively, use -ScriptPath parameter to specify the path to Robocurse.ps1"
        }

        # Build action - PowerShell command to run Robocurse in headless mode
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Headless -ConfigPath `"$ConfigPath`""

        $action = New-ScheduledTaskAction `
            -Execute "powershell.exe" `
            -Argument $arguments `
            -WorkingDirectory (Split-Path $scriptPath -Parent)

        # Build trigger based on schedule type
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

        # Build principal - determines user context for task execution
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

        # Build settings - task execution policies
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RunOnlyIfNetworkAvailable `
            -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Hours 72) `
            -Priority 7

        # Register task with all components
        $taskParams = @{
            TaskName = $TaskName
            Action = $action
            Trigger = $trigger
            Principal = $principal
            Settings = $settings
            Description = "Robocurse automatic directory replication"
            Force = $true
        }

        if ($PSCmdlet.ShouldProcess($TaskName, "Register scheduled task (Schedule: $Schedule, Time: $Time)")) {
            Register-ScheduledTask @taskParams | Out-Null
            Write-RobocurseLog -Message "Scheduled task '$TaskName' registered successfully" -Level 'Info' -Component 'Scheduler'
        }
        return New-OperationResult -Success $true -Data $TaskName
    }
    catch {
        Write-RobocurseLog -Message "Failed to register scheduled task: $_" -Level 'Error' -Component 'Scheduler'
        return New-OperationResult -Success $false -ErrorMessage "Failed to register scheduled task: $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Unregister-RobocurseTask {
    <#
    .SYNOPSIS
        Removes the Robocurse scheduled task
    .DESCRIPTION
        Unregisters the specified scheduled task from Windows Task Scheduler.
    .PARAMETER TaskName
        Name of task to remove. Default: "Robocurse-Replication"
    .OUTPUTS
        OperationResult - Success=$true with Data=$TaskName on success, Success=$false with ErrorMessage on failure
    .EXAMPLE
        $result = Unregister-RobocurseTask
        if ($result.Success) { "Task removed" }
    .EXAMPLE
        $result = Unregister-RobocurseTask -TaskName "Custom-Task"
        if (-not $result.Success) { Write-Error $result.ErrorMessage }
    .EXAMPLE
        Unregister-RobocurseTask -WhatIf
        # Shows what would be removed without actually deleting
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        # Check if running on Windows
        if (-not (Test-IsWindowsPlatform)) {
            Write-RobocurseLog -Message "Scheduled tasks are only supported on Windows" -Level 'Warning' -Component 'Scheduler'
            return New-OperationResult -Success $false -ErrorMessage "Scheduled tasks are only supported on Windows"
        }

        if ($PSCmdlet.ShouldProcess($TaskName, "Unregister scheduled task")) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-RobocurseLog -Message "Scheduled task '$TaskName' removed" -Level 'Info' -Component 'Scheduler'
        }
        return New-OperationResult -Success $true -Data $TaskName
    }
    catch {
        Write-RobocurseLog -Message "Failed to remove scheduled task: $_" -Level 'Error' -Component 'Scheduler'
        return New-OperationResult -Success $false -ErrorMessage "Failed to remove scheduled task '$TaskName': $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Get-RobocurseTask {
    <#
    .SYNOPSIS
        Gets information about the Robocurse scheduled task
    .DESCRIPTION
        Retrieves detailed information about a scheduled task including state,
        next run time, last run time, and trigger configuration.
    .PARAMETER TaskName
        Name of task to query. Default: "Robocurse-Replication"
    .OUTPUTS
        PSCustomObject with task info or $null if not found
    .EXAMPLE
        Get-RobocurseTask
    .EXAMPLE
        $taskInfo = Get-RobocurseTask -TaskName "Custom-Task"
    #>
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        # Check if running on Windows
        if (-not (Test-IsWindowsPlatform)) {
            return $null
        }

        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop

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

function Start-RobocurseTask {
    <#
    .SYNOPSIS
        Manually triggers the scheduled task
    .DESCRIPTION
        Starts the scheduled task immediately, outside of its normal schedule.
    .PARAMETER TaskName
        Name of task to start. Default: "Robocurse-Replication"
    .OUTPUTS
        OperationResult - Success=$true with Data=$TaskName on success, Success=$false with ErrorMessage on failure
    .EXAMPLE
        $result = Start-RobocurseTask
        if ($result.Success) { "Task started" }
    #>
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        # Check if running on Windows
        if (-not (Test-IsWindowsPlatform)) {
            Write-RobocurseLog -Message "Scheduled tasks are only supported on Windows" -Level 'Warning' -Component 'Scheduler'
            return New-OperationResult -Success $false -ErrorMessage "Scheduled tasks are only supported on Windows"
        }

        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Write-RobocurseLog -Message "Manually triggered task '$TaskName'" -Level 'Info' -Component 'Scheduler'
        return New-OperationResult -Success $true -Data $TaskName
    }
    catch {
        Write-RobocurseLog -Message "Failed to start task: $_" -Level 'Error' -Component 'Scheduler'
        return New-OperationResult -Success $false -ErrorMessage "Failed to start task '$TaskName': $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Enable-RobocurseTask {
    <#
    .SYNOPSIS
        Enables the scheduled task
    .DESCRIPTION
        Enables a disabled scheduled task so it will run on its schedule.
    .PARAMETER TaskName
        Name of task to enable. Default: "Robocurse-Replication"
    .OUTPUTS
        OperationResult - Success=$true with Data=$TaskName on success, Success=$false with ErrorMessage on failure
    .EXAMPLE
        $result = Enable-RobocurseTask
        if ($result.Success) { "Task enabled" }
    #>
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        # Check if running on Windows
        if (-not (Test-IsWindowsPlatform)) {
            Write-RobocurseLog -Message "Scheduled tasks are only supported on Windows" -Level 'Warning' -Component 'Scheduler'
            return New-OperationResult -Success $false -ErrorMessage "Scheduled tasks are only supported on Windows"
        }

        Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-RobocurseLog -Message "Enabled task '$TaskName'" -Level 'Info' -Component 'Scheduler'
        return New-OperationResult -Success $true -Data $TaskName
    }
    catch {
        Write-RobocurseLog -Message "Failed to enable task: $_" -Level 'Error' -Component 'Scheduler'
        return New-OperationResult -Success $false -ErrorMessage "Failed to enable task '$TaskName': $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Disable-RobocurseTask {
    <#
    .SYNOPSIS
        Disables the scheduled task
    .DESCRIPTION
        Disables a scheduled task so it won't run on its schedule.
        The task remains configured but won't execute until re-enabled.
    .PARAMETER TaskName
        Name of task to disable. Default: "Robocurse-Replication"
    .OUTPUTS
        OperationResult - Success=$true with Data=$TaskName on success, Success=$false with ErrorMessage on failure
    .EXAMPLE
        $result = Disable-RobocurseTask
        if ($result.Success) { "Task disabled" }
    .EXAMPLE
        Disable-RobocurseTask -WhatIf
        # Shows what would be disabled without actually disabling
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        # Check if running on Windows
        if (-not (Test-IsWindowsPlatform)) {
            Write-RobocurseLog -Message "Scheduled tasks are only supported on Windows" -Level 'Warning' -Component 'Scheduler'
            return New-OperationResult -Success $false -ErrorMessage "Scheduled tasks are only supported on Windows"
        }

        if ($PSCmdlet.ShouldProcess($TaskName, "Disable scheduled task")) {
            Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
            Write-RobocurseLog -Message "Disabled task '$TaskName'" -Level 'Info' -Component 'Scheduler'
        }
        return New-OperationResult -Success $true -Data $TaskName
    }
    catch {
        Write-RobocurseLog -Message "Failed to disable task: $_" -Level 'Error' -Component 'Scheduler'
        return New-OperationResult -Success $false -ErrorMessage "Failed to disable task '$TaskName': $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Test-RobocurseTaskExists {
    <#
    .SYNOPSIS
        Checks if a Robocurse scheduled task exists
    .DESCRIPTION
        Tests whether the specified scheduled task is registered in Task Scheduler.
    .PARAMETER TaskName
        Name of task to check. Default: "Robocurse-Replication"
    .OUTPUTS
        Boolean indicating if task exists
    .EXAMPLE
        if (Test-RobocurseTaskExists) { "Task exists" }
    #>
    param(
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        # Check if running on Windows
        if (-not (Test-IsWindowsPlatform)) {
            return $false
        }

        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        return $null -ne $task
    }
    catch {
        return $false
    }
}
