# Robocurse Main Entry Point Functions

function Show-RobocurseHelp {
    <#
    .SYNOPSIS
        Displays help information
    #>
    [CmdletBinding()]
    param()

    Write-Host @"
Robocurse - Multi-Share Parallel Robocopy Orchestrator
======================================================

USAGE:
    .\Robocurse.ps1 [options]

OPTIONS:
    -Headless           Run in headless mode without GUI
    -ConfigPath <path>  Path to configuration file (default: .\Robocurse.config.json)
    -Profile <name>     Run a specific profile by name
    -AllProfiles        Run all enabled profiles (headless mode only)
    -DryRun             Preview mode - show what would be copied without copying
    -Help               Display this help message

EXAMPLES:
    .\Robocurse.ps1
        Launch GUI interface

    .\Robocurse.ps1 -Headless -Profile "DailyBackup"
        Run in headless mode with the DailyBackup profile

    .\Robocurse.ps1 -Headless -AllProfiles
        Run all enabled profiles in headless mode

    .\Robocurse.ps1 -Headless -Profile "DailyBackup" -DryRun
        Preview what would be copied without actually copying

    .\Robocurse.ps1 -ConfigPath "C:\Configs\custom.json" -Headless -AllProfiles
        Run with custom configuration file

For more information, see README.md
"@
}

function Invoke-HeadlessReplication {
    <#
    .SYNOPSIS
        Runs replication in headless mode with progress output and email notification
    .PARAMETER Config
        Configuration object
    .PARAMETER ProfilesToRun
        Array of profile objects to run
    .PARAMETER MaxConcurrentJobs
        Maximum concurrent robocopy processes
    .PARAMETER BandwidthLimitMbps
        Aggregate bandwidth limit in Mbps (0 = unlimited)
    .PARAMETER DryRun
        Preview mode - show what would be copied without copying
    .OUTPUTS
        Exit code: 0 for success, 1 for failures
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory)]
        [PSCustomObject[]]$ProfilesToRun,

        [int]$MaxConcurrentJobs,

        [int]$BandwidthLimitMbps = 0,

        [switch]$DryRun
    )

    $profileNames = ($ProfilesToRun | ForEach-Object { $_.Name }) -join ", "
    $modeStr = if ($DryRun) { " (DRY-RUN MODE)" } else { "" }
    Write-Host "Starting replication for profile(s): $profileNames$modeStr"
    Write-Host "Max concurrent jobs: $MaxConcurrentJobs"
    if ($BandwidthLimitMbps -gt 0) {
        Write-Host "Bandwidth limit: $BandwidthLimitMbps Mbps (aggregate)"
    }
    if ($DryRun) {
        Write-Host "*** DRY-RUN MODE: No files will be copied ***" -ForegroundColor Yellow
    }
    Write-Host ""

    # Start replication with bandwidth throttling
    Start-ReplicationRun -Profiles $ProfilesToRun -MaxConcurrentJobs $MaxConcurrentJobs -BandwidthLimitMbps $BandwidthLimitMbps -DryRun:$DryRun

    # Track last progress output time for throttling
    $lastProgressOutput = [datetime]::MinValue
    $progressInterval = [timespan]::FromSeconds($script:HeadlessProgressIntervalSeconds)

    # Run the orchestration loop with progress output
    while ($script:OrchestrationState.Phase -notin @('Complete', 'Stopped', 'Idle')) {
        Invoke-ReplicationTick -MaxConcurrentJobs $MaxConcurrentJobs

        # Output progress every 10 seconds
        $now = [datetime]::Now
        if (($now - $lastProgressOutput) -gt $progressInterval) {
            $status = Get-OrchestrationStatus
            $progressPct = if ($status.ChunksTotal -gt 0) {
                [math]::Round(($status.ChunksComplete / $status.ChunksTotal) * 100, 1)
            } else { 0 }

            $etaStr = if ($status.ETA) { $status.ETA.ToString('hh\:mm\:ss') } else { "--:--:--" }
            $elapsedStr = $status.Elapsed.ToString('hh\:mm\:ss')
            $bytesStr = Format-FileSize -Bytes $status.BytesComplete

            Write-Host "[${elapsedStr}] Profile: $($status.CurrentProfile) | Progress: ${progressPct}% | Chunks: $($status.ChunksComplete)/$($status.ChunksTotal) | Copied: $bytesStr | ETA: $etaStr"

            $lastProgressOutput = $now
        }

        Start-Sleep -Milliseconds $script:ReplicationTickIntervalMs
    }

    # Get final status
    $status = Get-OrchestrationStatus
    $profileResultsArray = $script:OrchestrationState.GetProfileResultsArray()

    $totalFailed = if ($profileResultsArray.Count -gt 0) {
        ($profileResultsArray | Measure-Object -Property ChunksFailed -Sum).Sum
    } else { $status.ChunksFailed }

    # Build results object for email
    $totalBytesCopied = if ($profileResultsArray.Count -gt 0) {
        ($profileResultsArray | Measure-Object -Property BytesCopied -Sum).Sum
    } else { $status.BytesComplete }

    $allErrors = @()
    if ($profileResultsArray.Count -gt 0) {
        foreach ($pr in $profileResultsArray) {
            $allErrors += $pr.Errors
        }
    }

    $results = [PSCustomObject]@{
        Duration = $status.Elapsed
        TotalBytesCopied = $totalBytesCopied
        TotalFilesCopied = $status.FilesCopied
        TotalErrors = $totalFailed
        Profiles = $profileResultsArray
        Errors = $allErrors
    }

    # Determine overall status
    $emailStatus = if ($totalFailed -gt 0) { 'Warning' } else { 'Success' }
    if ($script:OrchestrationState.Phase -eq 'Stopped') {
        $emailStatus = 'Failed'
    }

    # Report results to console
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "Replication Complete"
    Write-Host "=========================================="
    Write-Host "  Duration: $($status.Elapsed.ToString('hh\:mm\:ss'))"
    Write-Host "  Total data copied: $(Format-FileSize -Bytes $totalBytesCopied)"
    Write-Host "  Total files copied: $($status.FilesCopied.ToString('N0'))"
    Write-Host "  Total chunks failed: $totalFailed"
    Write-Host ""

    if ($profileResultsArray.Count -gt 0) {
        Write-Host "Profile Summary:"
        foreach ($pr in $profileResultsArray) {
            $prStatus = if ($pr.ChunksFailed -gt 0) { "[WARN]" } else { "[OK]" }
            Write-Host "  $prStatus $($pr.Name): $($pr.ChunksComplete)/$($pr.ChunksTotal) chunks, $(Format-FileSize -Bytes $pr.BytesCopied)"
        }
        Write-Host ""
    }

    # Track email status for exit code consideration
    $emailFailed = $false

    # Send email notification if configured
    if ($Config.Email -and $Config.Email.Enabled) {
        Write-Host "Sending completion email..."
        $emailResult = Send-CompletionEmail -Config $Config.Email -Results $results -Status $emailStatus
        if ($emailResult.Success) {
            Write-Host "Email sent successfully." -ForegroundColor Green
        }
        else {
            $emailFailed = $true
            Write-RobocurseLog -Message "Failed to send completion email: $($emailResult.ErrorMessage)" -Level 'Error' -Component 'Email'
            Write-SiemEvent -EventType 'ChunkError' -Data @{
                errorType = 'EmailDeliveryFailure'
                errorMessage = $emailResult.ErrorMessage
                recipients = ($Config.Email.To -join ', ')
            }
            # Make email failure VERY visible in console
            Write-Host ""
            Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Red
            Write-Host "║  EMAIL NOTIFICATION FAILED                                 ║" -ForegroundColor Red
            Write-Host "╠════════════════════════════════════════════════════════════╣" -ForegroundColor Red
            Write-Host "║  Error: $($emailResult.ErrorMessage.PadRight(50).Substring(0,50)) ║" -ForegroundColor Red
            Write-Host "║                                                            ║" -ForegroundColor Red
            Write-Host "║  Replication completed but notification was NOT sent.      ║" -ForegroundColor Red
            Write-Host "║  Check SMTP settings and credentials.                      ║" -ForegroundColor Red
            Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Red
            Write-Host ""
        }
    }

    # Return exit code
    # Email failure alone doesn't cause exit code 1, but is logged prominently
    # Uncomment the following to treat email failure as a failure condition:
    # if ($emailFailed) { return 2 }  # Exit code 2 = email delivery failure
    if ($totalFailed -gt 0 -or $script:OrchestrationState.Phase -eq 'Stopped') {
        return 1
    }
    return 0
}

function Start-RobocurseMain {
    <#
    .SYNOPSIS
        Main entry point function for Robocurse
    .DESCRIPTION
        Handles parameter validation, configuration loading, and launches
        either GUI or headless mode. Separated from script body for testability.
        Uses granular error handling for distinct failure phases.
    #>
    [CmdletBinding()]
    param(
        [switch]$Headless,
        [string]$ConfigPath,
        [string]$ProfileName,
        [switch]$AllProfiles,
        [switch]$DryRun,
        [switch]$ShowHelp
    )

    if ($ShowHelp) {
        Show-RobocurseHelp
        return 0
    }

    # Track state for cleanup
    $logSessionInitialized = $false
    $config = $null

    # Validate config path for security before using it
    if (-not (Test-SafeConfigPath -Path $ConfigPath)) {
        Write-Error "Configuration path '$ConfigPath' contains unsafe characters or patterns."
        return 1
    }

    # Phase 1: Resolve and validate configuration path
    try {
        if ($ConfigPath -match '^\.[\\/]' -or -not [System.IO.Path]::IsPathRooted($ConfigPath)) {
            $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
            $scriptRelativePath = Join-Path $scriptDir ($ConfigPath -replace '^\.[\\\/]', '')

            if ((Test-Path $scriptRelativePath) -and -not (Test-Path $ConfigPath)) {
                Write-Verbose "Using config from script directory: $scriptRelativePath"
                $ConfigPath = $scriptRelativePath
            }
        }
    }
    catch {
        Write-Error "Failed to resolve configuration path '$ConfigPath': $($_.Exception.Message)"
        return 1
    }

    # Phase 2: Load configuration
    try {
        if (Test-Path $ConfigPath) {
            $config = Get-RobocurseConfig -Path $ConfigPath
        }
        else {
            Write-Warning "Configuration file not found: $ConfigPath"
            if (-not $Headless) {
                $config = New-DefaultConfig
            }
            else {
                Write-Error "Configuration file required for headless mode: $ConfigPath"
                return 1
            }
        }
    }
    catch {
        Write-Error "Failed to load configuration from '$ConfigPath': $($_.Exception.Message)"
        return 1
    }

    # Phase 3: Launch appropriate interface
    if ($Headless) {
        # Phase 3a: Validate headless parameters
        if (-not $ProfileName -and -not $AllProfiles) {
            Write-Error "Headless mode requires either -Profile <name> or -AllProfiles parameter."
            return 1
        }

        if ($ProfileName -and $AllProfiles) {
            Write-Warning "-Profile and -AllProfiles both specified. Using -Profile '$ProfileName'."
        }

        # Phase 3b: Initialize logging
        try {
            $logRoot = if ($config.GlobalSettings.LogPath) { $config.GlobalSettings.LogPath } else { ".\Logs" }
            $compressDays = if ($config.GlobalSettings.LogCompressAfterDays) { $config.GlobalSettings.LogCompressAfterDays } else { $script:LogCompressAfterDays }
            $deleteDays = if ($config.GlobalSettings.LogRetentionDays) { $config.GlobalSettings.LogRetentionDays } else { $script:LogDeleteAfterDays }
            Initialize-LogSession -LogRoot $logRoot -CompressAfterDays $compressDays -DeleteAfterDays $deleteDays
            $logSessionInitialized = $true
        }
        catch {
            Write-Error "Failed to initialize logging: $($_.Exception.Message)"
            return 1
        }

        # Phase 3c: Determine which profiles to run
        $profilesToRun = @()
        try {
            if ($ProfileName) {
                $targetProfile = $config.SyncProfiles | Where-Object { $_.Name -eq $ProfileName }
                if (-not $targetProfile) {
                    $availableProfiles = ($config.SyncProfiles | ForEach-Object { $_.Name }) -join ", "
                    Write-Error "Profile '$ProfileName' not found. Available profiles: $availableProfiles"
                    return 1
                }
                $profilesToRun = @($targetProfile)
            }
            else {
                $profilesToRun = @($config.SyncProfiles | Where-Object {
                    ($null -eq $_.PSObject.Properties['Enabled']) -or ($_.Enabled -eq $true)
                })
                if ($profilesToRun.Count -eq 0) {
                    Write-Error "No enabled profiles found in configuration."
                    return 1
                }
            }
        }
        catch {
            Write-Error "Failed to resolve profiles: $($_.Exception.Message)"
            return 1
        }

        # Phase 3d: Run headless replication
        try {
            $maxJobs = if ($config.GlobalSettings.MaxConcurrentJobs) {
                $config.GlobalSettings.MaxConcurrentJobs
            } else {
                $script:DefaultMaxConcurrentJobs
            }

            $bandwidthLimit = if ($config.GlobalSettings.BandwidthLimitMbps) {
                $config.GlobalSettings.BandwidthLimitMbps
            } else {
                0
            }

            return Invoke-HeadlessReplication -Config $config -ProfilesToRun $profilesToRun `
                -MaxConcurrentJobs $maxJobs -BandwidthLimitMbps $bandwidthLimit -DryRun:$DryRun
        }
        catch {
            Write-Error "Replication failed: $($_.Exception.Message)"
            if ($logSessionInitialized) {
                Write-RobocurseLog -Message "Replication failed with exception: $($_.Exception.Message)" -Level 'Error' -Component 'Main'
            }
            return 1
        }
        finally {
            # Cleanup: Ensure any partial state is handled
            if ($logSessionInitialized -and $script:OrchestrationState) {
                # Log final state if orchestration was started
                if ($script:OrchestrationState.Phase -notin @('Idle', 'Complete')) {
                    Write-RobocurseLog -Message "Main exit with orchestration in phase: $($script:OrchestrationState.Phase)" -Level 'Warning' -Component 'Main'
                }
            }
            # Clean up health check file on exit
            if (Test-Path $script:HealthCheckStatusFile) {
                Remove-Item -Path $script:HealthCheckStatusFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
    else {
        # Phase 3: Launch GUI
        try {
            $window = Initialize-RobocurseGui -ConfigPath $ConfigPath
            if ($window) {
                $window.ShowDialog() | Out-Null
                return 0
            }
            else {
                Write-Error "Failed to initialize GUI window. Try running with -Headless mode."
                return 1
            }
        }
        catch {
            Write-Error "GUI initialization failed: $($_.Exception.Message)"
            return 1
        }
    }
}
