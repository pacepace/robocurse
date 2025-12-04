# Robocurse GUI Replication Management
# Background runspace management and replication control.

function Get-ProfilesToRun {
    <#
    .SYNOPSIS
        Determines which profiles to run based on selection mode
    .PARAMETER AllProfiles
        Include all enabled profiles
    .PARAMETER SelectedOnly
        Include only the currently selected profile
    .OUTPUTS
        Array of profile objects, or $null if validation fails
    #>
    [CmdletBinding()]
    param(
        [switch]$AllProfiles,
        [switch]$SelectedOnly
    )

    $profilesToRun = @()

    if ($AllProfiles) {
        $profilesToRun = @($script:Config.SyncProfiles | Where-Object { $_.Enabled -eq $true })
        if ($profilesToRun.Count -eq 0) {
            Show-GuiError -Message "No enabled profiles found. Please enable at least one profile."
            return $null
        }
    }
    elseif ($SelectedOnly) {
        $selected = $script:Controls.lstProfiles.SelectedItem
        if (-not $selected) {
            Show-GuiError -Message "No profile selected. Please select a profile to run."
            return $null
        }
        $profilesToRun = @($selected)
    }

    # Validate profiles have required paths
    foreach ($profile in $profilesToRun) {
        if ([string]::IsNullOrWhiteSpace($profile.Source) -or [string]::IsNullOrWhiteSpace($profile.Destination)) {
            Show-GuiError -Message "Profile '$($profile.Name)' has invalid source or destination paths."
            return $null
        }
    }

    return $profilesToRun
}

function New-ReplicationRunspace {
    <#
    .SYNOPSIS
        Creates and configures a background runspace for replication
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
        # NOTE: We pass ProfileNames (strings) instead of Profile objects because
        # PSCustomObject properties don't reliably survive runspace boundaries.
        # See CLAUDE.md for details on this pattern.
        $backgroundScript = @"
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
                Start-ReplicationRun -Profiles `$profiles -MaxConcurrentJobs `$MaxWorkers -SkipInitialization -VerboseFileLogging:`$verboseLogging

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
    else {
        # Script/monolith mode
        # NOTE: We use $GuiConfigPath (not $ConfigPath) because dot-sourcing the script
        # would shadow our parameter with the script's own $ConfigPath parameter
        # NOTE: We pass ProfileNames (strings) instead of Profile objects for consistency
        # with module mode. See CLAUDE.md for the pattern.
        $backgroundScript = @"
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
                Start-ReplicationRun -Profiles `$profiles -MaxConcurrentJobs `$MaxWorkers -SkipInitialization -VerboseFileLogging:`$verboseLogging

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

function Start-GuiReplication {
    <#
    .SYNOPSIS
        Starts replication from GUI
    .PARAMETER AllProfiles
        Run all enabled profiles
    .PARAMETER SelectedOnly
        Run only selected profile
    #>
    [CmdletBinding()]
    param(
        [switch]$AllProfiles,
        [switch]$SelectedOnly
    )

    # Save any pending form changes before reading profiles
    # This ensures changes like chunk size are captured even if user clicks Run
    # without first clicking elsewhere to trigger LostFocus
    Save-ProfileFromForm

    # Get and validate profiles (force array context to handle PowerShell's single-item unwrapping)
    $profilesToRun = @(Get-ProfilesToRun -AllProfiles:$AllProfiles -SelectedOnly:$SelectedOnly)
    if ($profilesToRun.Count -eq 0) { return }

    # Update UI state for replication mode
    $script:Controls.btnRunAll.IsEnabled = $false
    $script:Controls.btnRunSelected.IsEnabled = $false
    $script:Controls.btnStop.IsEnabled = $true
    $script:Controls.txtStatus.Text = "Replication in progress..."
    $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::Gray  # Reset error color
    $script:GuiErrorCount = 0  # Reset error count for new run
    $script:LastGuiUpdateState = $null
    $script:Controls.dgChunks.ItemsSource = $null

    Write-GuiLog "Starting replication with $($profilesToRun.Count) profile(s)"

    # Get worker count and start progress timer
    $maxWorkers = [int]$script:Controls.sldWorkers.Value
    $script:ProgressTimer.Start()

    # Initialize orchestration state (must happen before runspace creation)
    Initialize-OrchestrationState

    # Create a snapshot of the config to prevent external modifications during replication
    # This ensures the running replication uses the config state at the time of start
    $script:ConfigSnapshotPath = $null
    try {
        $snapshotDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
        $script:ConfigSnapshotPath = Join-Path $snapshotDir "Robocurse-ConfigSnapshot-$([Guid]::NewGuid().ToString('N')).json"
        Copy-Item -Path $script:ConfigPath -Destination $script:ConfigSnapshotPath -Force
    }
    catch {
        Write-GuiLog "Warning: Could not create config snapshot, using live config: $($_.Exception.Message)"
        $script:ConfigSnapshotPath = $script:ConfigPath  # Fall back to original
    }

    # Create and start background runspace (using snapshot path)
    try {
        $runspaceInfo = New-ReplicationRunspace -Profiles $profilesToRun -MaxWorkers $maxWorkers -ConfigPath $script:ConfigSnapshotPath

        $script:ReplicationHandle = $runspaceInfo.Handle
        $script:ReplicationPowerShell = $runspaceInfo.PowerShell
        $script:ReplicationRunspace = $runspaceInfo.Runspace
    }
    catch {
        Write-Host "[ERROR] Failed to create background runspace: $($_.Exception.Message)"
        Write-GuiLog "ERROR: Failed to start replication: $($_.Exception.Message)"
        # Reset UI state
        $script:Controls.btnRunAll.IsEnabled = $true
        $script:Controls.btnRunSelected.IsEnabled = $true
        $script:Controls.btnStop.IsEnabled = $false
        $script:Controls.txtStatus.Text = "Ready"
        $script:ProgressTimer.Stop()
    }
}

function Complete-GuiReplication {
    <#
    .SYNOPSIS
        Called when replication completes
    .DESCRIPTION
        Handles GUI cleanup after replication: stops timer, re-enables buttons,
        disposes of background runspace resources, and shows completion message.
    #>
    [CmdletBinding()]
    param()

    # Stop timer
    $script:ProgressTimer.Stop()

    # Dispose of background runspace resources to prevent memory leaks
    if ($script:ReplicationPowerShell) {
        try {
            # End the async invocation if still running
            if ($script:ReplicationHandle -and -not $script:ReplicationHandle.IsCompleted) {
                $script:ReplicationPowerShell.Stop()
            }
            elseif ($script:ReplicationHandle) {
                # Collect any remaining output
                $script:ReplicationPowerShell.EndInvoke($script:ReplicationHandle) | Out-Null
            }

            # Check for errors from the background runspace and surface them
            # Note: HadErrors can be true even with empty Error stream, so check count
            if ($script:ReplicationPowerShell.Streams.Error.Count -gt 0) {
                Write-GuiLog "Background replication encountered errors:"
                foreach ($err in $script:ReplicationPowerShell.Streams.Error) {
                    $errorLocation = if ($err.InvocationInfo) {
                        "$($err.InvocationInfo.ScriptName):$($err.InvocationInfo.ScriptLineNumber)"
                    } else { "Unknown" }
                    Write-GuiLog "  [$errorLocation] $($err.Exception.Message)"
                }
            }

            # Dispose the runspace
            if ($script:ReplicationPowerShell.Runspace) {
                $script:ReplicationPowerShell.Runspace.Close()
                $script:ReplicationPowerShell.Runspace.Dispose()
            }

            # Dispose the PowerShell instance
            $script:ReplicationPowerShell.Dispose()
        }
        catch {
            Write-GuiLog "Warning: Error disposing runspace: $($_.Exception.Message)"
        }
        finally {
            $script:ReplicationPowerShell = $null
            $script:ReplicationHandle = $null
            $script:ReplicationRunspace = $null  # Clear runspace reference for GC
        }
    }

    # Re-enable buttons
    $script:Controls.btnRunAll.IsEnabled = $true
    $script:Controls.btnRunSelected.IsEnabled = $true
    $script:Controls.btnStop.IsEnabled = $false

    # Update status with error indicator if applicable
    if ($script:GuiErrorCount -gt 0) {
        $script:Controls.txtStatus.Text = "Replication complete ($($script:GuiErrorCount) error(s))"
        $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::OrangeRed
    } else {
        $script:Controls.txtStatus.Text = "Replication complete"
        $script:Controls.txtStatus.Foreground = [System.Windows.Media.Brushes]::LimeGreen
    }

    # Show completion message
    $status = Get-OrchestrationStatus
    Show-CompletionDialog -ChunksComplete $status.ChunksComplete -ChunksTotal $status.ChunksTotal -ChunksFailed $status.ChunksFailed

    Write-GuiLog "Replication completed: $($status.ChunksComplete)/$($status.ChunksTotal) chunks, $($status.ChunksFailed) failed"

    # Clean up config snapshot if it was created
    if ($script:ConfigSnapshotPath -and ($script:ConfigSnapshotPath -ne $script:ConfigPath)) {
        try {
            if (Test-Path $script:ConfigSnapshotPath) {
                Remove-Item $script:ConfigSnapshotPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            # Non-critical - temp files will be cleaned up eventually
        }
        $script:ConfigSnapshotPath = $null
    }
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
