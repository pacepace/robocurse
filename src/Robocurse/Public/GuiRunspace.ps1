# Robocurse GUI Runspace Management
# Background PowerShell runspace creation and cleanup for replication.

function New-ReplicationRunspace {
    <#
    .SYNOPSIS
        Creates and configures a background runspace for replication
    .DESCRIPTION
        Initializes a PowerShell runspace with Robocurse module loaded for background replication.
        Configures the runspace to import the Robocurse module (or dot-source monolith script)
        and passes profile names for execution. Returns runspace handle for async management.
    .PARAMETER Profiles
        Array of profiles to run
    .PARAMETER MaxWorkers
        Maximum concurrent robocopy jobs
    .PARAMETER ConfigPath
        Path to config file (can be a snapshot for isolation from external changes)
    .OUTPUTS
        PSCustomObject with PowerShell, Handle, and Runspace properties
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject[]]$Profiles,

        [Parameter(Mandatory)]
        [int]$MaxWorkers,

        [string]$ConfigPath = $script:ConfigPath
    )

    # Determine how to load Robocurse in the background runspace
    # Two modes: 1) Module mode (Import-Module), 2) Monolith mode (dot-source script)
    $loadMode = $null
    $loadPath = $null

    # Check if we're running from a module (RobocurseModulePath is set by psm1)
    if ($script:RobocurseModulePath -and (Test-Path (Join-Path $script:RobocurseModulePath "Robocurse.psd1"))) {
        $loadMode = "Module"
        $loadPath = $script:RobocurseModulePath
    }
    # Check if we have a stored script path (set by monolith)
    elseif ($script:RobocurseScriptPath -and (Test-Path $script:RobocurseScriptPath)) {
        $loadMode = "Script"
        $loadPath = $script:RobocurseScriptPath
    }
    # Try PSCommandPath (works when running as standalone script)
    elseif ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        $loadMode = "Script"
        $loadPath = $PSCommandPath
    }
    # Fall back to looking for Robocurse.ps1 in current directory
    else {
        $fallbackPath = Join-Path (Get-Location) "Robocurse.ps1"
        if (Test-Path $fallbackPath) {
            $loadMode = "Script"
            $loadPath = $fallbackPath
        }
    }

    if (-not $loadMode -or -not $loadPath) {
        $errorMsg = "Cannot find Robocurse module or script to load in background runspace. loadPath='$loadPath'"
        Write-Host "[ERROR] $errorMsg"
        Write-GuiLog "ERROR: $errorMsg"
        throw $errorMsg
    }

    $runspace = [runspacefactory]::CreateRunspace()
    # Use MTA for background I/O work (STA is only needed for COM/UI operations)
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace

    # Build a script that loads Robocurse and runs replication
    # Note: We pass the C# OrchestrationState object which is inherently thread-safe
    # Callbacks are intentionally NOT shared - GUI uses timer-based polling instead
    if ($loadMode -eq "Module") {
        $backgroundScript = New-ModuleModeBackgroundScript
    }
    else {
        # Script/monolith mode
        $backgroundScript = New-ScriptModeBackgroundScript
    }

    $powershell.AddScript($backgroundScript)
    $powershell.AddArgument($loadPath)
    $powershell.AddArgument($script:OrchestrationState)
    # Pass profile names (strings) - background will look up from config (see CLAUDE.md)
    $profileNames = @($Profiles | ForEach-Object { $_.Name })
    $powershell.AddArgument($profileNames)
    $powershell.AddArgument($MaxWorkers)
    # Use the provided ConfigPath (may be a snapshot for isolation from external changes)
    $powershell.AddArgument($ConfigPath)

    $handle = $powershell.BeginInvoke()

    return [PSCustomObject]@{
        PowerShell = $powershell
        Handle = $handle
        Runspace = $runspace
    }
}

function New-ModuleModeBackgroundScript {
    <#
    .SYNOPSIS
        Creates the background script for module loading mode
    .DESCRIPTION
        Returns a script block string that loads Robocurse as a module and runs replication.
        NOTE: We pass ProfileNames (strings) instead of Profile objects because
        PSCustomObject properties don't reliably survive runspace boundaries.
        See CLAUDE.md for details on this pattern.
    #>
    [CmdletBinding()]
    param()

    return @"
        param(`$ModulePath, `$SharedState, `$ProfileNames, `$MaxWorkers, `$ConfigPath)

        try {
            Write-Host "[BACKGROUND] Loading module from: `$ModulePath"
            Import-Module `$ModulePath -Force -ErrorAction Stop
            Write-Host "[BACKGROUND] Module loaded successfully"
        }
        catch {
            Write-Host "[BACKGROUND] ERROR loading module: `$(`$_.Exception.Message)"
            `$SharedState.EnqueueError("Failed to load module: `$(`$_.Exception.Message)")
            `$SharedState.Phase = 'Complete'
            return
        }

        # Initialize logging session (required for Write-RobocurseLog)
        try {
            Write-Host "[BACKGROUND] Initializing log session..."
            `$config = Get-RobocurseConfig -Path `$ConfigPath
            `$logRoot = if (`$config.GlobalSettings.LogPath) { `$config.GlobalSettings.LogPath } else { '.\Logs' }
            # Resolve relative paths based on config file directory and normalize
            if (-not [System.IO.Path]::IsPathRooted(`$logRoot)) {
                `$configDir = Split-Path -Parent `$ConfigPath
                `$logRoot = [System.IO.Path]::GetFullPath((Join-Path `$configDir `$logRoot))
            }
            Write-Host "[BACKGROUND] Log root: `$logRoot"
            Initialize-LogSession -LogRoot `$logRoot
            Write-Host "[BACKGROUND] Log session initialized"
        }
        catch {
            Write-Host "[BACKGROUND] WARNING: Failed to initialize logging: `$(`$_.Exception.Message)"
            # Continue anyway - logging is not critical for replication
        }

        # Use the shared C# OrchestrationState instance (thread-safe by design)
        `$script:OrchestrationState = `$SharedState

        # Clear callbacks - GUI mode uses timer-based polling, not callbacks
        `$script:OnProgress = `$null
        `$script:OnChunkComplete = `$null
        `$script:OnProfileComplete = `$null

        try {
            Write-Host "[BACKGROUND] Starting replication run"
            # Re-read config to get fresh profile data with all properties intact
            # (PSCustomObject properties don't survive runspace boundaries - see CLAUDE.md)
            `$bgConfig = Get-RobocurseConfig -Path `$ConfigPath
            `$verboseLogging = [bool]`$bgConfig.GlobalSettings.VerboseFileLogging

            # Look up profiles by name from freshly-loaded config
            `$profiles = @(`$bgConfig.SyncProfiles | Where-Object { `$ProfileNames -contains `$_.Name })
            Write-Host "[BACKGROUND] Loaded `$(`$profiles.Count) profile(s) from config"

            # Start replication with -SkipInitialization since UI thread already initialized
            Start-ReplicationRun -Profiles `$profiles -Config `$bgConfig -MaxConcurrentJobs `$MaxWorkers -SkipInitialization -VerboseFileLogging:`$verboseLogging

            # Run the orchestration loop until complete
            # Note: 250ms matches GuiProgressUpdateIntervalMs constant (hardcoded for runspace isolation)
            while (`$script:OrchestrationState.Phase -notin @('Complete', 'Stopped', 'Idle')) {
                Invoke-ReplicationTick -MaxConcurrentJobs `$MaxWorkers
                Start-Sleep -Milliseconds 250
            }
            Write-Host "[BACKGROUND] Replication loop complete, phase: `$(`$script:OrchestrationState.Phase)"
        }
        catch {
            Write-Host "[BACKGROUND] ERROR in replication: `$(`$_.Exception.Message)"
            `$SharedState.EnqueueError("Replication error: `$(`$_.Exception.Message)")
            `$SharedState.Phase = 'Complete'
        }
"@
}

function New-ScriptModeBackgroundScript {
    <#
    .SYNOPSIS
        Creates the background script for monolith/script loading mode
    .DESCRIPTION
        Returns a script block string that dot-sources the Robocurse script and runs replication.
        NOTE: We use $GuiConfigPath (not $ConfigPath) because dot-sourcing the script
        would shadow our parameter with the script's own $ConfigPath parameter.
        NOTE: We pass ProfileNames (strings) instead of Profile objects for consistency
        with module mode. See CLAUDE.md for the pattern.
    #>
    [CmdletBinding()]
    param()

    return @"
        param(`$ScriptPath, `$SharedState, `$ProfileNames, `$MaxWorkers, `$GuiConfigPath)

        try {
            Write-Host "[BACKGROUND] Loading script from: `$ScriptPath"
            Write-Host "[BACKGROUND] Config path: `$GuiConfigPath"
            # Load the script to get all functions (with -LoadOnly to prevent main execution)
            . `$ScriptPath -LoadOnly
            Write-Host "[BACKGROUND] Script loaded successfully"
        }
        catch {
            Write-Host "[BACKGROUND] ERROR loading script: `$(`$_.Exception.Message)"
            `$SharedState.EnqueueError("Failed to load script: `$(`$_.Exception.Message)")
            `$SharedState.Phase = 'Complete'
            return
        }

        # Initialize logging session (required for Write-RobocurseLog)
        try {
            Write-Host "[BACKGROUND] Initializing log session..."
            `$config = Get-RobocurseConfig -Path `$GuiConfigPath
            `$logRoot = if (`$config.GlobalSettings.LogPath) { `$config.GlobalSettings.LogPath } else { '.\Logs' }
            # Resolve relative paths based on config file directory and normalize
            if (-not [System.IO.Path]::IsPathRooted(`$logRoot)) {
                `$configDir = Split-Path -Parent `$GuiConfigPath
                `$logRoot = [System.IO.Path]::GetFullPath((Join-Path `$configDir `$logRoot))
            }
            Write-Host "[BACKGROUND] Log root: `$logRoot"
            Initialize-LogSession -LogRoot `$logRoot
            Write-Host "[BACKGROUND] Log session initialized"
        }
        catch {
            Write-Host "[BACKGROUND] WARNING: Failed to initialize logging: `$(`$_.Exception.Message)"
            # Continue anyway - logging is not critical for replication
        }

        # Use the shared C# OrchestrationState instance (thread-safe by design)
        `$script:OrchestrationState = `$SharedState

        # Clear callbacks - GUI mode uses timer-based polling, not callbacks
        `$script:OnProgress = `$null
        `$script:OnChunkComplete = `$null
        `$script:OnProfileComplete = `$null

        try {
            Write-Host "[BACKGROUND] Starting replication run"
            # Re-read config to get fresh profile data (see CLAUDE.md for pattern)
            `$bgConfig = Get-RobocurseConfig -Path `$GuiConfigPath
            `$verboseLogging = [bool]`$bgConfig.GlobalSettings.VerboseFileLogging

            # Look up profiles by name from freshly-loaded config
            `$profiles = @(`$bgConfig.SyncProfiles | Where-Object { `$ProfileNames -contains `$_.Name })
            Write-Host "[BACKGROUND] Loaded `$(`$profiles.Count) profile(s) from config"

            # Start replication with -SkipInitialization since UI thread already initialized
            Start-ReplicationRun -Profiles `$profiles -Config `$bgConfig -MaxConcurrentJobs `$MaxWorkers -SkipInitialization -VerboseFileLogging:`$verboseLogging

            # Run the orchestration loop until complete
            # Note: 250ms matches GuiProgressUpdateIntervalMs constant (hardcoded for runspace isolation)
            while (`$script:OrchestrationState.Phase -notin @('Complete', 'Stopped', 'Idle')) {
                Invoke-ReplicationTick -MaxConcurrentJobs `$MaxWorkers
                Start-Sleep -Milliseconds 250
            }
            Write-Host "[BACKGROUND] Replication loop complete, phase: `$(`$script:OrchestrationState.Phase)"
        }
        catch {
            Write-Host "[BACKGROUND] ERROR in replication: `$(`$_.Exception.Message)"
            `$SharedState.EnqueueError("Replication error: `$(`$_.Exception.Message)")
            `$SharedState.Phase = 'Complete'
        }
"@
}

function Close-ReplicationRunspace {
    <#
    .SYNOPSIS
        Cleans up the background replication runspace
    .DESCRIPTION
        Safely stops and disposes the PowerShell instance and runspace
        used for background replication. Called during window close
        and when replication completes.

        Uses Interlocked.Exchange for atomic capture-and-clear to prevent
        race conditions when multiple threads attempt cleanup simultaneously
        (e.g., window close + completion handler firing at the same time).
    #>
    [CmdletBinding()]
    param()

    # Early exit if nothing to clean up
    if (-not $script:ReplicationPowerShell) { return }

    # Atomically capture and clear the PowerShell instance reference
    # Interlocked.Exchange ensures only ONE thread gets the reference;
    # all other threads will get $null and exit early
    $psInstance = [System.Threading.Interlocked]::Exchange([ref]$script:ReplicationPowerShell, $null)
    $handle = [System.Threading.Interlocked]::Exchange([ref]$script:ReplicationHandle, $null)
    $runspace = [System.Threading.Interlocked]::Exchange([ref]$script:ReplicationRunspace, $null)

    # If another thread already claimed the instance, exit
    if (-not $psInstance) { return }

    try {
        # Stop the PowerShell instance if still running
        if ($handle -and -not $handle.IsCompleted) {
            try {
                $psInstance.Stop()
            }
            catch [System.Management.Automation.PipelineStoppedException] {
                # Expected when pipeline is already stopped
            }
            catch [System.ObjectDisposedException] {
                # Already disposed by another thread
                return
            }
        }

        # Close and dispose the runspace
        if ($psInstance.Runspace) {
            try {
                $psInstance.Runspace.Close()
                $psInstance.Runspace.Dispose()
            }
            catch [System.ObjectDisposedException] {
                # Already disposed
            }
        }

        # Dispose the PowerShell instance
        try {
            $psInstance.Dispose()
        }
        catch [System.ObjectDisposedException] {
            # Already disposed
        }
    }
    catch {
        # Silently ignore cleanup errors during window close
        Write-Verbose "Runspace cleanup error (ignored): $($_.Exception.Message)"
    }
}
