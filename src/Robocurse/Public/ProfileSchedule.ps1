# Robocurse Profile Scheduling
# Manages Windows Task Scheduler tasks for automated profile execution

$script:ProfileTaskPrefix = "Robocurse-Profile-"

function New-ProfileScheduledTask {
    <#
    .SYNOPSIS
        Creates a Windows scheduled task for profile execution
    .DESCRIPTION
        Registers a scheduled task that runs the specified profile at the configured schedule.
        When Credential is provided, uses Password logon type which allows access to network
        shares. Without Credential, uses S4U logon which only has local access.
    .PARAMETER Profile
        The profile object with Schedule property
    .PARAMETER ConfigPath
        Path to the Robocurse config file
    .PARAMETER ScriptPath
        Path to Robocurse.ps1 (optional, auto-detected)
    .PARAMETER Credential
        Optional credential for Password logon type. Required for network share access.
        If not provided, uses S4U logon (local access only).
    .OUTPUTS
        OperationResult with Data = task name
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [string]$ScriptPath,

        [System.Management.Automation.PSCredential]$Credential
    )

    # Platform check
    if (-not (Test-IsWindowsPlatform)) {
        Write-RobocurseLog -Message "Profile scheduling is only supported on Windows" -Level 'Warning' -Component 'ProfileSchedule'
        return New-OperationResult -Success $false -ErrorMessage "Profile scheduling is only supported on Windows"
    }

    $taskName = "$script:ProfileTaskPrefix$($Profile.Name)"
    $schedule = $Profile.Schedule

    Write-RobocurseLog -Message "Creating profile schedule '$taskName' (Frequency: $($schedule.Frequency))" -Level 'Info' -Component 'ProfileSchedule'

    try {
        # Auto-detect script path if not provided
        if (-not $ScriptPath) {
            # Use script-level variable set at initialization (works for monolith)
            if ($script:RobocurseScriptPath) {
                $ScriptPath = $script:RobocurseScriptPath
            } else {
                # Fallback: look in same directory as config
                $ScriptPath = Join-Path (Split-Path $ConfigPath -Parent) "Robocurse.ps1"
            }
        }

        # Validate script exists
        if (-not (Test-Path $ScriptPath)) {
            return New-OperationResult -Success $false -ErrorMessage "Script not found: $ScriptPath"
        }

        # Build PowerShell command (must include -Headless for Task Scheduler)
        $argument = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" -Headless -ConfigPath `"$ConfigPath`" -Profile `"$($Profile.Name)`""

        # Set working directory to config file's directory (for relative paths in config)
        $workingDir = Split-Path -Parent (Resolve-Path $ConfigPath)

        # Create action with working directory
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argument -WorkingDirectory $workingDir

        # Create trigger based on frequency
        $trigger = switch ($schedule.Frequency) {
            "Hourly" {
                $interval = if ($schedule.Interval -and $schedule.Interval -ge 1 -and $schedule.Interval -le 24) {
                    $schedule.Interval
                } else { 1 }
                New-ScheduledTaskTrigger -Once -At $schedule.Time -RepetitionInterval (New-TimeSpan -Hours $interval) -RepetitionDuration (New-TimeSpan -Days 9999)
            }
            "Daily" {
                New-ScheduledTaskTrigger -Daily -At $schedule.Time
            }
            "Weekly" {
                $day = if ($schedule.DayOfWeek) { $schedule.DayOfWeek } else { "Sunday" }
                New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At $schedule.Time
            }
            "Monthly" {
                # Monthly requires special handling with CIM
                $day = if ($schedule.DayOfMonth -and $schedule.DayOfMonth -ge 1 -and $schedule.DayOfMonth -le 28) {
                    $schedule.DayOfMonth
                } else { 1 }
                # Create monthly trigger using CIM
                $trigger = New-CimInstance -CimClass (Get-CimClass -ClassName MSFT_TaskMonthlyTrigger -Namespace Root/Microsoft/Windows/TaskScheduler) -ClientOnly
                $trigger.DaysOfMonth = @($day)
                $trigger.MonthsOfYear = @(1,2,3,4,5,6,7,8,9,10,11,12)  # All months
                $trigger.StartBoundary = (Get-Date -Format "yyyy-MM-ddT$($schedule.Time):00")
                $trigger.Enabled = $true
                $trigger
            }
            default {
                throw "Unknown frequency: $($schedule.Frequency)"
            }
        }

        # Settings
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -MultipleInstances IgnoreNew

        # Remove existing task if present
        if ($PSCmdlet.ShouldProcess($taskName, "Create Scheduled Task")) {
            $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($existing) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
                Write-RobocurseLog -Message "Removed existing task '$taskName'" -Level 'Debug' -Component 'ProfileSchedule'
            }

            # Register the task - use Password logon if credential provided (for network access)
            if ($Credential) {
                # Password logon type - has network credentials for accessing shares
                $taskUser = $Credential.UserName
                $taskPassword = $Credential.GetNetworkCredential().Password

                Write-RobocurseLog -Message "Registering task with Password logon (user: $taskUser)" -Level 'Debug' -Component 'ProfileSchedule'

                # Use User parameter set with RunLevel Highest for elevated execution + network access
                # Note: -Principal and -User/-Password are mutually exclusive parameter sets
                Register-ScheduledTask `
                    -TaskName $taskName `
                    -Action $action `
                    -Trigger $trigger `
                    -Settings $settings `
                    -Description "Robocurse profile: $($Profile.Name)" `
                    -User $taskUser `
                    -Password $taskPassword `
                    -RunLevel Highest | Out-Null

                # =====================================================================================
                # SAVE CREDENTIALS FOR NETWORK PATH MOUNTING
                # =====================================================================================
                # Task Scheduler Password logon only authenticates the TASK execution context.
                # Session 0 still has NTLM credential delegation issues for SMB/UNC access.
                # We save the credential using DPAPI so JobManagement.ps1 can load it and
                # explicitly mount UNC paths with the credential at runtime.
                # See: src/Robocurse/Public/NetworkMapping.ps1 for full explanation.
                # =====================================================================================
                $saveResult = Save-NetworkCredential -ProfileName $Profile.Name -Credential $Credential -ConfigPath $ConfigPath
                if ($saveResult.Success) {
                    Write-RobocurseLog -Message "Saved network credentials for profile '$($Profile.Name)' (for UNC path mounting)" -Level 'Info' -Component 'ProfileSchedule'
                }
                else {
                    Write-RobocurseLog -Message "Warning: Failed to save network credentials: $($saveResult.ErrorMessage)" -Level 'Warning' -Component 'ProfileSchedule'
                }
            }
            else {
                # S4U logon type - runs without password but no network credentials
                # WARNING: S4U cannot access network shares requiring authentication
                Write-RobocurseLog -Message "Registering task with S4U logon (local access only - no network share access)" -Level 'Warning' -Component 'ProfileSchedule'
                $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest
                Register-ScheduledTask `
                    -TaskName $taskName `
                    -Action $action `
                    -Trigger $trigger `
                    -Principal $principal `
                    -Settings $settings `
                    -Description "Robocurse profile: $($Profile.Name)" | Out-Null
            }

            Write-RobocurseLog -Message "Created profile schedule '$taskName'" -Level 'Info' -Component 'ProfileSchedule'
        }

        return New-OperationResult -Success $true -Data $taskName
    }
    catch {
        Write-RobocurseLog -Message "Failed to create profile schedule: $($_.Exception.Message)" -Level 'Error' -Component 'ProfileSchedule'
        return New-OperationResult -Success $false -ErrorMessage "Failed to create schedule '$taskName': $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Remove-ProfileScheduledTask {
    <#
    .SYNOPSIS
        Removes a profile scheduled task
    .PARAMETER ProfileName
        The profile name (task prefix added automatically)
    .OUTPUTS
        OperationResult
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName
    )

    $taskName = "$script:ProfileTaskPrefix$ProfileName"

    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        if (-not $task) {
            Write-RobocurseLog -Message "Profile schedule '$taskName' not found" -Level 'Debug' -Component 'ProfileSchedule'
            return New-OperationResult -Success $true -Data "Task not found (already removed)"
        }

        if ($PSCmdlet.ShouldProcess($taskName, "Remove Scheduled Task")) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-RobocurseLog -Message "Removed profile schedule '$taskName'" -Level 'Info' -Component 'ProfileSchedule'
            return New-OperationResult -Success $true -Data $taskName
        }

        return New-OperationResult -Success $true -Data "WhatIf: Would remove $taskName"
    }
    catch {
        Write-RobocurseLog -Message "Failed to remove schedule '$taskName': $($_.Exception.Message)" -Level 'Error' -Component 'ProfileSchedule'
        return New-OperationResult -Success $false -ErrorMessage "Failed to remove schedule: $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Get-ProfileScheduledTask {
    <#
    .SYNOPSIS
        Gets information about a profile scheduled task
    .PARAMETER ProfileName
        The profile name
    .OUTPUTS
        Task info object or $null
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName
    )

    $taskName = "$script:ProfileTaskPrefix$ProfileName"

    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task) {
            return $null
        }

        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue

        return [PSCustomObject]@{
            Name = $ProfileName
            TaskName = $taskName
            State = $task.State
            Enabled = ($task.State -eq 'Ready')
            NextRunTime = $taskInfo.NextRunTime
            LastRunTime = $taskInfo.LastRunTime
            LastResult = $taskInfo.LastTaskResult
        }
    }
    catch {
        Write-RobocurseLog -Message "Failed to get profile schedule '$taskName': $($_.Exception.Message)" -Level 'Warning' -Component 'ProfileSchedule'
        return $null
    }
}

function Get-AllProfileScheduledTasks {
    <#
    .SYNOPSIS
        Lists all Robocurse profile scheduled tasks
    .OUTPUTS
        Array of task info objects
    #>
    [CmdletBinding()]
    param()

    try {
        $tasks = Get-ScheduledTask -TaskName "$script:ProfileTaskPrefix*" -ErrorAction SilentlyContinue

        if (-not $tasks) {
            return @()
        }

        return @($tasks | ForEach-Object {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $_.TaskName -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                Name = $_.TaskName -replace "^$([regex]::Escape($script:ProfileTaskPrefix))", ""
                TaskName = $_.TaskName
                State = $_.State
                Enabled = ($_.State -eq 'Ready')
                NextRunTime = $taskInfo.NextRunTime
                LastRunTime = $taskInfo.LastRunTime
                LastResult = $taskInfo.LastTaskResult
                Description = $_.Description
            }
        })
    }
    catch {
        Write-RobocurseLog -Message "Failed to list profile schedules: $($_.Exception.Message)" -Level 'Warning' -Component 'ProfileSchedule'
        return @()
    }
}

function Enable-ProfileScheduledTask {
    <#
    .SYNOPSIS
        Enables a profile scheduled task
    .PARAMETER ProfileName
        The profile name
    .OUTPUTS
        OperationResult
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName
    )

    $taskName = "$script:ProfileTaskPrefix$ProfileName"

    try {
        if ($PSCmdlet.ShouldProcess($taskName, "Enable Scheduled Task")) {
            Enable-ScheduledTask -TaskName $taskName | Out-Null
            Write-RobocurseLog -Message "Enabled profile schedule '$taskName'" -Level 'Info' -Component 'ProfileSchedule'
        }
        return New-OperationResult -Success $true -Data $taskName
    }
    catch {
        Write-RobocurseLog -Message "Failed to enable schedule '$taskName': $($_.Exception.Message)" -Level 'Error' -Component 'ProfileSchedule'
        return New-OperationResult -Success $false -ErrorMessage $_.Exception.Message -ErrorRecord $_
    }
}

function Disable-ProfileScheduledTask {
    <#
    .SYNOPSIS
        Disables a profile scheduled task
    .PARAMETER ProfileName
        The profile name
    .OUTPUTS
        OperationResult
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName
    )

    $taskName = "$script:ProfileTaskPrefix$ProfileName"

    try {
        if ($PSCmdlet.ShouldProcess($taskName, "Disable Scheduled Task")) {
            Disable-ScheduledTask -TaskName $taskName | Out-Null
            Write-RobocurseLog -Message "Disabled profile schedule '$taskName'" -Level 'Info' -Component 'ProfileSchedule'
        }
        return New-OperationResult -Success $true -Data $taskName
    }
    catch {
        Write-RobocurseLog -Message "Failed to disable schedule '$taskName': $($_.Exception.Message)" -Level 'Error' -Component 'ProfileSchedule'
        return New-OperationResult -Success $false -ErrorMessage $_.Exception.Message -ErrorRecord $_
    }
}

function Sync-ProfileSchedules {
    <#
    .SYNOPSIS
        Synchronizes scheduled tasks with profile configuration
    .DESCRIPTION
        Creates/updates/removes scheduled tasks to match profile schedules.
        Removes tasks for profiles that no longer exist or have disabled schedules.
    .PARAMETER Config
        The Robocurse configuration object
    .PARAMETER ConfigPath
        Path to the configuration file
    .PARAMETER Credential
        Optional credential for Password logon type. Required for network share access.
        If not provided, uses S4U logon (local access only).
    .OUTPUTS
        OperationResult with Data = summary of changes
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [System.Management.Automation.PSCredential]$Credential
    )

    # Get profiles with enabled schedules
    $scheduledProfiles = @($Config.SyncProfiles | Where-Object { $_.Schedule -and $_.Schedule.Enabled })
    $existingTasks = Get-AllProfileScheduledTasks
    $existingNames = @($existingTasks | ForEach-Object { $_.Name })
    $configNames = @($scheduledProfiles | ForEach-Object { $_.Name })

    $created = 0
    $removed = 0
    $errors = @()

    # Remove tasks not in config
    foreach ($existing in $existingTasks) {
        if ($existing.Name -notin $configNames) {
            $result = Remove-ProfileScheduledTask -ProfileName $existing.Name
            if ($result.Success) {
                $removed++
            }
            else {
                $errors += $result.ErrorMessage
            }
        }
    }

    # Create/update tasks from config
    foreach ($profile in $scheduledProfiles) {
        $result = New-ProfileScheduledTask -Profile $profile -ConfigPath $ConfigPath -Credential $Credential
        if ($result.Success) {
            if ($profile.Name -notin $existingNames) {
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
        Total = $scheduledProfiles.Count
        Errors = $errors
    }

    $success = $errors.Count -eq 0

    Write-RobocurseLog -Message "Profile schedules synced: $created created, $removed removed, $($scheduledProfiles.Count) total" -Level 'Info' -Component 'ProfileSchedule'

    return New-OperationResult -Success $success -Data $summary -ErrorMessage $(if (-not $success) { $errors -join "; " })
}
