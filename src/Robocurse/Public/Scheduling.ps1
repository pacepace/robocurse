# Robocurse Scheduling Functions
function Get-UniqueTaskName {
    <#
    .SYNOPSIS
        Generates a unique task name based on config path
    .DESCRIPTION
        Creates a unique scheduled task name by hashing the config file path.
        This prevents collisions when multiple Robocurse instances are deployed
        with different configurations on the same machine.
    .PARAMETER ConfigPath
        Path to the configuration file
    .PARAMETER Prefix
        Optional prefix for the task name. Default: "Robocurse"
    .OUTPUTS
        String - Unique task name like "Robocurse-A1B2C3D4E5F6A7B8"
    .EXAMPLE
        Get-UniqueTaskName -ConfigPath "C:\configs\backup.json"
        # Returns something like "Robocurse-7F3A2B1C9D4E5F6A"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [string]$Prefix = "Robocurse"
    )

    # Normalize path for consistent hashing
    $normalizedPath = [System.IO.Path]::GetFullPath($ConfigPath).ToLowerInvariant()

    # Create a hash (first 16 chars of SHA256 for collision resistance)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalizedPath))
        $hashString = [BitConverter]::ToString($hashBytes).Replace("-", "").Substring(0, 16)
    }
    finally {
        $sha256.Dispose()
    }

    return "$Prefix-$hashString"
}

function Test-ConfigHasUncPaths {
    <#
    .SYNOPSIS
        Checks if a configuration file contains UNC paths
    .DESCRIPTION
        Loads the configuration and checks if any profile source or destination
        uses UNC paths (paths starting with \\). This is used to warn users that
        scheduled tasks with S4U logon cannot access network shares.
    .PARAMETER ConfigPath
        Path to the configuration file
    .OUTPUTS
        PSCustomObject with HasUncPaths (bool) and UncPaths (array of paths found)
    .EXAMPLE
        $result = Test-ConfigHasUncPaths -ConfigPath "C:\config.json"
        if ($result.HasUncPaths) { "Config uses UNC paths: $($result.UncPaths -join ', ')" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $uncPaths = @()

    try {
        # Load the config file
        $content = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop
        $config = $content | ConvertFrom-Json -ErrorAction Stop

        # Check each profile for UNC paths
        if ($config.profiles) {
            foreach ($profileName in $config.profiles.PSObject.Properties.Name) {
                $profile = $config.profiles.$profileName

                # Check source path
                if ($profile.source -and $profile.source.path) {
                    $sourcePath = $profile.source.path
                    if ($sourcePath -match '^\\\\') {
                        $uncPaths += $sourcePath
                    }
                }

                # Check destination path
                if ($profile.destination -and $profile.destination.path) {
                    $destPath = $profile.destination.path
                    if ($destPath -match '^\\\\') {
                        $uncPaths += $destPath
                    }
                }
            }
        }
    }
    catch {
        Write-RobocurseLog -Message "Could not parse config for UNC path check: $($_.Exception.Message)" `
            -Level 'Warning' -Component 'Scheduler'
    }

    return [PSCustomObject]@{
        HasUncPaths = ($uncPaths.Count -gt 0)
        UncPaths    = $uncPaths
    }
}

function Register-RobocurseTask {
    <#
    .SYNOPSIS
        Creates or updates a scheduled task for Robocurse
    .DESCRIPTION
        Registers a Windows scheduled task to run Robocurse automatically.
        Supports daily, weekly, and hourly schedules with flexible configuration.

        When TaskName is not specified, a unique name is auto-generated based on
        the config file path hash. This prevents collisions when multiple Robocurse
        instances are deployed with different configurations on the same machine.

        SECURITY NOTE: When using -RunAsSystem, the script path is validated to ensure
        it exists and has a .ps1 extension. For additional security, consider placing
        scripts in protected directories (e.g., Program Files) that require admin to modify.
    .PARAMETER TaskName
        Name for the scheduled task. If not specified, a unique name is auto-generated
        based on the config file path (e.g., "Robocurse-7F3A2B1C9D4E5F6A"). This ensures
        multiple Robocurse instances can coexist without task name collisions.
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
        WARNING: This runs the script with SYSTEM privileges. Ensure the script path
        points to a trusted, protected location.
        NOTE: SYSTEM account cannot access network resources (UNC paths) by default.
    .PARAMETER Credential
        PSCredential object for a domain or local user account. Required for accessing
        UNC paths (network shares) during scheduled replication.
        Use: $cred = Get-Credential; Register-RobocurseTask -Credential $cred ...
        The password is securely stored in Windows Task Scheduler.
    .PARAMETER ScriptPath
        Explicit path to Robocurse.ps1 script. Use when running interactively
        or when automatic path detection fails.
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
    .EXAMPLE
        Register-RobocurseTask -ConfigPath "C:\config.json" -ScriptPath "C:\Scripts\Robocurse.ps1"
        # Explicitly specify the script path for interactive sessions
    .EXAMPLE
        $cred = Get-Credential -Message "Enter domain credentials for UNC access"
        Register-RobocurseTask -ConfigPath "C:\config.json" -Credential $cred
        # Use domain credentials to enable UNC path access during scheduled runs
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string]$TaskName,  # If not specified, auto-generated from ConfigPath hash

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

        [switch]$RunAsSystem,

        [Parameter(ParameterSetName = 'DomainUser')]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential,

        [ValidateScript({
            if ($_ -and -not (Test-Path -Path $_ -PathType Leaf)) {
                throw "ScriptPath '$_' does not exist or is not a file"
            }
            $true
        })]
        [string]$ScriptPath
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

        # Check if config has UNC paths - these require proper credentials to access
        # S4U logon (default) cannot access network shares
        if (-not $RunAsSystem -and -not $Credential) {
            $uncCheck = Test-ConfigHasUncPaths -ConfigPath $ConfigPath
            if ($uncCheck.HasUncPaths) {
                $uncPathList = $uncCheck.UncPaths -join ', '
                $errorMsg = "Configuration contains UNC paths ($uncPathList) but no credentials were provided. " +
                    "Scheduled tasks using S4U logon cannot access network shares. " +
                    "Use -Credential parameter to provide domain/local credentials for network access, " +
                    "or use -RunAsSystem if the computer account has access to the shares."
                Write-RobocurseLog -Message $errorMsg -Level 'Error' -Component 'Scheduler'
                return New-OperationResult -Success $false -ErrorMessage $errorMsg
            }
        }

        # Auto-generate unique task name if not specified
        # This prevents collisions when multiple Robocurse instances use different configs
        if ([string]::IsNullOrWhiteSpace($TaskName)) {
            $TaskName = Get-UniqueTaskName -ConfigPath $ConfigPath
            Write-RobocurseLog -Message "Auto-generated task name: $TaskName" -Level 'Info' -Component 'Scheduler'
        }

        # Get script path - use explicit parameter if provided, otherwise auto-detect
        $effectiveScriptPath = if ($ScriptPath) {
            $ScriptPath
        }
        else {
            # Auto-detection: Look for Robocurse.ps1 in common locations
            # Priority: 1) dist folder relative to module, 2) same folder as config, 3) current directory
            $autoPath = $null

            # Try dist folder relative to module location
            $moduleRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { $null }
            if ($moduleRoot) {
                $distPath = Join-Path (Split-Path -Parent $moduleRoot) "dist\Robocurse.ps1"
                if (Test-Path $distPath) {
                    $autoPath = $distPath
                }
            }

            # Try same folder as config file
            if (-not $autoPath) {
                $configDir = Split-Path -Parent $ConfigPath
                $configDirScript = Join-Path $configDir "Robocurse.ps1"
                if (Test-Path $configDirScript) {
                    $autoPath = $configDirScript
                }
            }

            # Try current directory
            if (-not $autoPath) {
                $cwdScript = Join-Path (Get-Location) "Robocurse.ps1"
                if (Test-Path $cwdScript) {
                    $autoPath = $cwdScript
                }
            }

            $autoPath
        }

        if (-not $effectiveScriptPath -or -not (Test-Path $effectiveScriptPath)) {
            return New-OperationResult -Success $false -ErrorMessage "Cannot determine Robocurse script path. Use -ScriptPath parameter to specify the path to Robocurse.ps1"
        }

        # Security validation for script path
        # Validate the script has a .ps1 extension (prevent executing arbitrary files)
        if ([System.IO.Path]::GetExtension($effectiveScriptPath) -ne '.ps1') {
            return New-OperationResult -Success $false -ErrorMessage "Script path must have a .ps1 extension: $effectiveScriptPath"
        }

        # Validate paths don't contain dangerous characters that could enable command injection
        # These characters could break out of the quoted argument
        $dangerousChars = @('`', '$', '"', ';', '&', '|', '>', '<', [char]0x0000, [char]0x000A, [char]0x000D)
        foreach ($char in $dangerousChars) {
            if ($effectiveScriptPath.Contains($char) -or $ConfigPath.Contains($char)) {
                return New-OperationResult -Success $false -ErrorMessage "Script path or config path contains invalid characters that could pose a security risk"
            }
        }

        # Additional warning for SYSTEM-level tasks
        if ($RunAsSystem) {
            $resolvedScriptPath = [System.IO.Path]::GetFullPath($effectiveScriptPath)
            Write-RobocurseLog -Message "SECURITY: Registering task to run as SYSTEM with script: $resolvedScriptPath" -Level 'Warning' -Component 'Scheduler'

            # Check if the script is in a protected location (Program Files or Windows)
            $protectedPaths = @(
                $env:ProgramFiles,
                ${env:ProgramFiles(x86)},
                $env:SystemRoot
            ) | Where-Object { $_ }

            $isProtected = $false
            foreach ($protectedPath in $protectedPaths) {
                if ($resolvedScriptPath.StartsWith($protectedPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $isProtected = $true
                    break
                }
            }

            if (-not $isProtected) {
                Write-RobocurseLog -Message "WARNING: Script '$resolvedScriptPath' is not in a protected directory. Consider moving to Program Files for enhanced security." -Level 'Warning' -Component 'Scheduler'
            }
        }

        # Build action - PowerShell command to run Robocurse in headless mode
        # Use single quotes for inner paths to prevent variable expansion, then escape for the argument string
        $escapedScriptPath = $effectiveScriptPath -replace "'", "''"
        $escapedConfigPath = $ConfigPath -replace "'", "''"
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$escapedScriptPath`" -Headless -ConfigPath `"$escapedConfigPath`""

        $action = New-ScheduledTaskAction `
            -Execute "powershell.exe" `
            -Argument $arguments `
            -WorkingDirectory (Split-Path $effectiveScriptPath -Parent)

        # Build trigger based on schedule type
        $trigger = switch ($Schedule) {
            'Daily' {
                New-ScheduledTaskTrigger -Daily -At $Time
            }
            'Weekly' {
                New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DaysOfWeek -At $Time
            }
            'Hourly' {
                # Use indefinite duration for hourly tasks (runs forever until disabled)
                New-ScheduledTaskTrigger -Once -At $Time `
                    -RepetitionInterval (New-TimeSpan -Hours 1) `
                    -RepetitionDuration ([TimeSpan]::MaxValue)
            }
        }

        # Build principal - determines user context for task execution
        # IMPORTANT: S4U logon does NOT have network credentials and cannot access UNC paths
        # For UNC path access, use -Credential parameter with a domain account
        $principal = if ($RunAsSystem) {
            # SYSTEM account - no network credentials, but useful for local-only operations
            Write-RobocurseLog -Message "Using SYSTEM account - note: SYSTEM cannot access network resources by default" `
                -Level 'Info' -Component 'Scheduler'
            New-ScheduledTaskPrincipal `
                -UserId "SYSTEM" `
                -LogonType ServiceAccount `
                -RunLevel Highest
        }
        elseif ($Credential) {
            # Domain/local user with credentials - enables network access (UNC paths)
            Write-RobocurseLog -Message "Using credential-based logon for network access capability" `
                -Level 'Info' -Component 'Scheduler'
            New-ScheduledTaskPrincipal `
                -UserId $Credential.UserName `
                -LogonType Password `
                -RunLevel Highest
        }
        else {
            # S4U logon - current user, but NO network credentials
            # This will NOT work for UNC paths!
            Write-RobocurseLog -Message "Using S4U logon (current user) - WARNING: Cannot access network/UNC paths. Use -Credential for network access." `
                -Level 'Warning' -Component 'Scheduler'
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

        # If credentials provided, add them to task registration
        # This is required for Password logon type to enable network access
        #
        # SECURITY NOTE: GetNetworkCredential().Password returns plaintext. This is UNAVOIDABLE
        # when using Register-ScheduledTask with password-based authentication - the Windows API
        # requires the plaintext password to store in the credential vault. The password is
        # passed directly to the Windows Task Scheduler service which encrypts it internally.
        # There is no way to pass a SecureString to Register-ScheduledTask.
        if ($Credential) {
            $taskParams['User'] = $Credential.UserName
            $taskParams['Password'] = $Credential.GetNetworkCredential().Password
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
        If TaskName is not specified and ConfigPath is provided, derives the
        task name from the config path hash (same logic as Register-RobocurseTask).
    .PARAMETER TaskName
        Name of task to remove. If not specified, must provide ConfigPath.
    .PARAMETER ConfigPath
        Path to config file. Used to derive task name if TaskName not specified.
    .OUTPUTS
        OperationResult - Success=$true with Data=$TaskName on success, Success=$false with ErrorMessage on failure
    .EXAMPLE
        $result = Unregister-RobocurseTask -TaskName "Robocurse-7F3A2B1C9D4E5F6A"
        if ($result.Success) { "Task removed" }
    .EXAMPLE
        $result = Unregister-RobocurseTask -ConfigPath "C:\config.json"
        # Derives task name from config path, same as Register-RobocurseTask
    .EXAMPLE
        Unregister-RobocurseTask -TaskName "Custom-Task" -WhatIf
        # Shows what would be removed without actually deleting
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$TaskName,

        [string]$ConfigPath
    )

    try {
        # Check if running on Windows
        if (-not (Test-IsWindowsPlatform)) {
            Write-RobocurseLog -Message "Scheduled tasks are only supported on Windows" -Level 'Warning' -Component 'Scheduler'
            return New-OperationResult -Success $false -ErrorMessage "Scheduled tasks are only supported on Windows"
        }

        # Derive task name from ConfigPath if not specified
        if ([string]::IsNullOrWhiteSpace($TaskName)) {
            if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
                return New-OperationResult -Success $false -ErrorMessage "Either TaskName or ConfigPath must be specified"
            }
            $TaskName = Get-UniqueTaskName -ConfigPath $ConfigPath
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
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
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
    .EXAMPLE
        Start-RobocurseTask -WhatIf
        # Shows what would be started without actually triggering
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        # Check if running on Windows
        if (-not (Test-IsWindowsPlatform)) {
            Write-RobocurseLog -Message "Scheduled tasks are only supported on Windows" -Level 'Warning' -Component 'Scheduler'
            return New-OperationResult -Success $false -ErrorMessage "Scheduled tasks are only supported on Windows"
        }

        if ($PSCmdlet.ShouldProcess($TaskName, "Start scheduled task")) {
            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            Write-RobocurseLog -Message "Manually triggered task '$TaskName'" -Level 'Info' -Component 'Scheduler'
        }
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
    .EXAMPLE
        Enable-RobocurseTask -WhatIf
        # Shows what would be enabled without actually enabling
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$TaskName = "Robocurse-Replication"
    )

    try {
        # Check if running on Windows
        if (-not (Test-IsWindowsPlatform)) {
            Write-RobocurseLog -Message "Scheduled tasks are only supported on Windows" -Level 'Warning' -Component 'Scheduler'
            return New-OperationResult -Success $false -ErrorMessage "Scheduled tasks are only supported on Windows"
        }

        if ($PSCmdlet.ShouldProcess($TaskName, "Enable scheduled task")) {
            Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
            Write-RobocurseLog -Message "Enabled task '$TaskName'" -Level 'Info' -Component 'Scheduler'
        }
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
        [ValidateNotNullOrEmpty()]
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
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
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
