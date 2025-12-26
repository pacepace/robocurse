# Robocurse Main Entry Point Functions

function Show-RobocurseHelp {
    <#
    .SYNOPSIS
        Displays help information
    #>
    [CmdletBinding()]
    param()

    Write-Host @"
ROBOCURSE - Chunked Robocopy Orchestrator with VSS Support

USAGE:
    .\Robocurse.ps1 [options]

GENERAL OPTIONS:
    -Help               Show this help message
    -ConfigPath <path>  Path to configuration file (default: .\Robocurse.config.json)

GUI MODE (default):
    .\Robocurse.ps1

HEADLESS MODE:
    -Headless           Run without GUI
    -Profile <name>     Run specific profile
    -AllProfiles        Run all enabled profiles
    -DryRun             Preview changes without copying

SNAPSHOT MANAGEMENT:
    -ListSnapshots                      List all VSS snapshots
    -ListSnapshots -Volume D:           List snapshots for specific volume
    -ListSnapshots -Server Server01     List snapshots on remote server

    -CreateSnapshot -Volume D:          Create snapshot on local volume
    -CreateSnapshot -Volume D: -Server Server01    Create on remote server
    -CreateSnapshot -Volume D: -KeepCount 5        Create with retention

    -DeleteSnapshot -ShadowId {guid}    Delete snapshot by ID
    -DeleteSnapshot -ShadowId {guid} -Server Server01    Delete remote snapshot

SNAPSHOT SCHEDULES:
    -SnapshotSchedule                   List configured schedules
    -SnapshotSchedule -List             List configured schedules
    -SnapshotSchedule -Sync             Sync schedules with config file
    -SnapshotSchedule -Remove -ScheduleName DailyD    Remove a schedule

PROFILE SCHEDULES:
    -ListProfileSchedules               List all profile scheduled tasks
    -SetProfileSchedule -ProfileName <name> -Frequency <type> [-Time HH:MM] [options]
                                        Configure schedule for a profile
        Frequency options: Hourly, Daily, Weekly, Monthly
        -Time HH:MM                     Time to run (24-hour format, default: 02:00)
        -Interval N                     Hours between runs (Hourly only)
        -DayOfWeek <day>                Day of week (Weekly only)
        -DayOfMonth N                   Day of month 1-28 (Monthly only)
    -EnableProfileSchedule -ProfileName <name>    Enable a profile schedule
    -DisableProfileSchedule -ProfileName <name>   Disable a profile schedule
    -SyncProfileSchedules               Sync all profile schedules with config

DIAGNOSTICS:
    -TestRemote -Server <name>          Test remote VSS prerequisites
                                        Checks: network, WinRM, CIM, VSS service

EXAMPLES:
    # GUI mode
    .\Robocurse.ps1

    # Run specific profile headless
    .\Robocurse.ps1 -Headless -Profile "DailyBackup"

    # List all local snapshots
    .\Robocurse.ps1 -ListSnapshots

    # Create snapshot with retention
    .\Robocurse.ps1 -CreateSnapshot -Volume D: -KeepCount 5

    # Sync snapshot schedules from config
    .\Robocurse.ps1 -SnapshotSchedule -Sync

    # Test remote VSS prerequisites before deployment
    .\Robocurse.ps1 -TestRemote -Server FileServer01

    # List profile schedules
    .\Robocurse.ps1 -ListProfileSchedules

    # Set a daily profile schedule
    .\Robocurse.ps1 -SetProfileSchedule -ProfileName "DailyBackup" -Frequency Daily -Time "03:00"

    # Set an hourly schedule (every 4 hours)
    .\Robocurse.ps1 -SetProfileSchedule -ProfileName "FrequentSync" -Frequency Hourly -Interval 4

    # Set a weekly schedule
    .\Robocurse.ps1 -SetProfileSchedule -ProfileName "WeeklyArchive" -Frequency Weekly -DayOfWeek Saturday -Time "02:00"

"@
}

function Invoke-HeadlessReplication {
    <#
    .SYNOPSIS
        Runs replication in headless mode with progress output and email notification
    .DESCRIPTION
        Orchestrates complete replication run in non-GUI mode with console progress updates,
        email notifications, and proper cleanup. Manages the orchestration loop, tick processing,
        progress output throttling, completion detection, and final result reporting. Supports
        dry-run mode and bandwidth limiting. Returns exit code 0 for success or 1 for failures
        suitable for scripting and automation.
    .PARAMETER Config
        Configuration object
    .PARAMETER ConfigPath
        Path to configuration file (for snapshot registry updates)
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
        [string]$ConfigPath,

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

    # Pre-flight check: Warn if email is enabled but credentials are missing
    # This gives immediate feedback rather than discovering at completion time
    if ($Config.Email -and $Config.Email.Enabled) {
        if (-not (Test-SmtpCredential -Target $Config.Email.CredentialTarget)) {
            Write-Host ""
            Write-Host "WARNING: Email notifications enabled but SMTP credentials not configured." -ForegroundColor Yellow
            Write-Host "         Credential target: $($Config.Email.CredentialTarget)" -ForegroundColor Yellow
            Write-Host "         Headless: Save-SmtpCredential -Target '$($Config.Email.CredentialTarget)'" -ForegroundColor Yellow
            Write-Host "         GUI: Settings panel > Configure SMTP Credentials" -ForegroundColor Yellow
            Write-Host ""
            Write-RobocurseLog -Message "Email enabled but SMTP credential not found: $($Config.Email.CredentialTarget). Emails will not be sent." -Level 'Warning' -Component 'Email'
        }
    }

    Write-Host ""

    # Start replication with bandwidth throttling
    Start-ReplicationRun -Profiles $ProfilesToRun -Config $Config -ConfigPath $ConfigPath -MaxConcurrentJobs $MaxConcurrentJobs -BandwidthLimitMbps $BandwidthLimitMbps -DryRun:$DryRun

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

    # Build snapshot summary for email (tracked vs external per volume)
    $snapshotSummary = Get-SnapshotSummaryForEmail -Config $Config

    $results = [PSCustomObject]@{
        Duration = $status.Elapsed
        TotalBytesCopied = $totalBytesCopied
        TotalFilesCopied = $status.FilesCopied
        TotalErrors = $totalFailed
        Profiles = $profileResultsArray
        Errors = $allErrors
        SnapshotSummary = $snapshotSummary
    }

    # Determine overall status - check for failed profiles (pre-flight errors) and chunk failures
    $failedProfiles = @($profileResultsArray | Where-Object { $_.Status -eq 'Failed' })
    $emailStatus = if ($failedProfiles.Count -gt 0) {
        'Failed'  # Pre-flight failure (e.g., source path not accessible)
    } elseif ($totalFailed -gt 0) {
        'Warning'  # Chunk failures
    } else {
        'Success'
    }
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

    # Generate failed files summary if there were failures
    $failedFilesSummaryPath = $null
    if ($status.FilesFailed -gt 0) {
        try {
            $logRoot = if ($Config.GlobalSettings.LogPath) { $Config.GlobalSettings.LogPath } else { '.\Logs' }
            if (-not [System.IO.Path]::IsPathRooted($logRoot)) {
                $configDir = Split-Path -Parent $ConfigPath
                $logRoot = [System.IO.Path]::GetFullPath((Join-Path $configDir $logRoot))
            }
            $dateFolderName = (Get-Date).ToString('yyyy-MM-dd')
            $failedFilesSummaryPath = New-FailedFilesSummary -LogPath $logRoot -Date $dateFolderName
            if ($failedFilesSummaryPath) {
                Write-Host "  Failed files summary: $failedFilesSummaryPath"
            }
        }
        catch {
            Write-RobocurseLog -Message "Failed to generate failed files summary: $($_.Exception.Message)" -Level 'Warning' -Component 'Email'
        }
    }

    # Send email notification using shared function
    Write-Host "Sending completion email..."
    $emailResult = Send-ReplicationCompletionNotification -Config $Config -OrchestrationState $script:OrchestrationState -FailedFilesSummaryPath $failedFilesSummaryPath

    if ($emailResult.Skipped) {
        Write-Host "Email notifications not enabled, skipping."
    }
    elseif ($emailResult.Success) {
        Write-Host "Email sent successfully." -ForegroundColor Green
    }
    else {
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

    # Return exit code
    # Email failure alone doesn't cause exit code 1, but is logged prominently
    # Uncomment the following to treat email failure as a failure condition:
    # if ($emailFailed) { return 2 }  # Exit code 2 = email delivery failure
    if ($failedProfiles.Count -gt 0 -or $totalFailed -gt 0 -or $script:OrchestrationState.Phase -eq 'Stopped') {
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
        [switch]$ShowHelp,

        # Snapshot parameters
        [switch]$ListSnapshots,
        [switch]$CreateSnapshot,
        [switch]$DeleteSnapshot,
        [string]$Volume,
        [string]$ShadowId,
        [string]$Server,
        [int]$KeepCount = 3,
        [switch]$SnapshotSchedule,
        [switch]$List,
        [switch]$Sync,
        [switch]$Add,
        [switch]$Remove,
        [string]$ScheduleName,

        # Diagnostic parameters
        [switch]$TestRemote,

        # Profile Schedule parameters
        [switch]$ListProfileSchedules,
        [switch]$SetProfileSchedule,
        [switch]$EnableProfileSchedule,
        [switch]$DisableProfileSchedule,
        [switch]$SyncProfileSchedules,
        [ValidateSet("Hourly", "Daily", "Weekly", "Monthly")]
        [string]$Frequency = "Daily",
        [string]$Time = "02:00",
        [int]$Interval = 1,
        [ValidateSet("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")]
        [string]$DayOfWeek = "Sunday",
        [int]$DayOfMonth = 1
    )

    if ($ShowHelp) {
        Show-RobocurseHelp
        return 0
    }

    # Snapshot command dispatch (before GUI/headless logic)
    if ($ListSnapshots) {
        # Load config to show tracked/untracked status
        $listConfig = $null
        if (Test-Path $ConfigPath) {
            $listConfig = Get-RobocurseConfig -Path $ConfigPath
        }
        return Invoke-ListSnapshotsCommand -Volume $Volume -Server $Server -Config $listConfig
    }

    if ($CreateSnapshot) {
        if (-not $Volume) {
            Write-Host "Error: -Volume is required for -CreateSnapshot" -ForegroundColor Red
            return 1
        }
        # Load config for snapshot registry
        if (-not (Test-Path $ConfigPath)) {
            Write-Host "Error: Configuration file not found: $ConfigPath" -ForegroundColor Red
            return 1
        }
        $createConfig = Get-RobocurseConfig -Path $ConfigPath
        return Invoke-CreateSnapshotCommand -Volume $Volume -Server $Server -KeepCount $KeepCount -Config $createConfig -ConfigPath $ConfigPath
    }

    if ($DeleteSnapshot) {
        if (-not $ShadowId) {
            Write-Host "Error: -ShadowId is required for -DeleteSnapshot" -ForegroundColor Red
            return 1
        }
        # Load config to unregister snapshot from registry
        $deleteConfig = $null
        if (Test-Path $ConfigPath) {
            $deleteConfig = Get-RobocurseConfig -Path $ConfigPath
        }
        return Invoke-DeleteSnapshotCommand -ShadowId $ShadowId -Server $Server -Config $deleteConfig -ConfigPath $ConfigPath
    }

    if ($SnapshotSchedule) {
        # Load config for schedule operations
        if (-not (Test-Path $ConfigPath)) {
            Write-Host "Error: Configuration file not found: $ConfigPath" -ForegroundColor Red
            return 1
        }
        $config = Get-RobocurseConfig -Path $ConfigPath
        return Invoke-SnapshotScheduleCommand -List:$List -Sync:$Sync -Add:$Add -Remove:$Remove -ScheduleName $ScheduleName -Config $config -ConfigPath $ConfigPath
    }

    # Remote VSS prerequisites test
    if ($TestRemote) {
        if (-not $Server) {
            Write-Host "Error: -Server is required for -TestRemote" -ForegroundColor Red
            Write-Host "Usage: .\Robocurse.ps1 -TestRemote -Server <ServerName>" -ForegroundColor Gray
            return 1
        }
        $result = Test-RemoteVssPrerequisites -ServerName $Server -Detailed
        return $(if ($result.Success) { 0 } else { 1 })
    }

    # Profile Schedule CLI commands
    if ($ListProfileSchedules) {
        $tasks = Get-AllProfileScheduledTasks
        if ($tasks.Count -eq 0) {
            Write-Host "No profile schedules configured."
        } else {
            Write-Host "Profile Scheduled Tasks:" -ForegroundColor Cyan
            Write-Host ""
            foreach ($task in $tasks) {
                $status = if ($task.Enabled) { "[Enabled]" } else { "[Disabled]" }
                $statusColor = if ($task.Enabled) { "Green" } else { "Yellow" }
                Write-Host "  $status " -ForegroundColor $statusColor -NoNewline
                Write-Host "$($task.Name)" -ForegroundColor White
                if ($task.NextRunTime) {
                    Write-Host "    Next Run: $($task.NextRunTime)" -ForegroundColor Gray
                }
            }
        }
        return 0
    }

    if ($SetProfileSchedule) {
        if (-not $ProfileName) {
            Write-Host "Error: -ProfileName is required for -SetProfileSchedule" -ForegroundColor Red
            return 1
        }
        if (-not (Test-Path $ConfigPath)) {
            Write-Host "Error: Configuration file not found: $ConfigPath" -ForegroundColor Red
            return 1
        }
        $config = Get-RobocurseConfig -Path $ConfigPath
        $profile = $config.SyncProfiles | Where-Object { $_.Name -eq $ProfileName }
        if (-not $profile) {
            Write-Host "Error: Profile '$ProfileName' not found in configuration" -ForegroundColor Red
            return 1
        }

        # Validate time format
        if ($Time -notmatch '^([01]?\d|2[0-3]):([0-5]\d)$') {
            Write-Host "Error: Invalid time format '$Time'. Use HH:MM (24-hour format, e.g., 02:00, 14:30)" -ForegroundColor Red
            return 1
        }

        # Update the profile's Schedule property
        $profile.Schedule = [PSCustomObject]@{
            Enabled = $true
            Frequency = $Frequency
            Time = $Time
            Interval = $Interval
            DayOfWeek = $DayOfWeek
            DayOfMonth = $DayOfMonth
        }

        # Save the updated config
        $saveResult = Save-RobocurseConfig -Config $config -Path $ConfigPath
        if (-not $saveResult.Success) {
            Write-Host "Error: Failed to save config: $($saveResult.ErrorMessage)" -ForegroundColor Red
            return 1
        }

        # Check if profile uses network paths - if so, require credentials
        $credential = $null
        if (($profile.Source -match '^\\\\') -or ($profile.Destination -match '^\\\\')) {
            Write-Host "Profile uses network paths - credentials required for scheduled task" -ForegroundColor Yellow
            Write-Host "Enter credentials for the user that will run the scheduled task:" -ForegroundColor Yellow
            $credential = Get-Credential -Message "Credentials for scheduled task (network access)" -UserName "$env:USERDOMAIN\$env:USERNAME"
            if (-not $credential) {
                Write-Host "Error: Credentials are required for scheduled tasks that access network shares" -ForegroundColor Red
                return 1
            }
        }

        # Create the scheduled task
        $result = New-ProfileScheduledTask -Profile $profile -ConfigPath $ConfigPath -Credential $credential
        if ($result.Success) {
            Write-Host "Profile schedule created for '$ProfileName'" -ForegroundColor Green
            Write-Host "  Frequency: $Frequency"
            Write-Host "  Time: $Time"
            if ($credential) {
                Write-Host "  Logon: Password (network access enabled)" -ForegroundColor Green
            } else {
                Write-Host "  Logon: S4U (local access only)" -ForegroundColor Yellow
            }
            return 0
        } else {
            Write-Host "Error: $($result.ErrorMessage)" -ForegroundColor Red
            return 1
        }
    }

    if ($EnableProfileSchedule) {
        if (-not $ProfileName) {
            Write-Host "Error: -ProfileName is required for -EnableProfileSchedule" -ForegroundColor Red
            return 1
        }
        $result = Enable-ProfileScheduledTask -ProfileName $ProfileName
        if ($result.Success) {
            Write-Host "Profile schedule enabled for '$ProfileName'" -ForegroundColor Green
            return 0
        } else {
            Write-Host "Error: $($result.ErrorMessage)" -ForegroundColor Red
            return 1
        }
    }

    if ($DisableProfileSchedule) {
        if (-not $ProfileName) {
            Write-Host "Error: -ProfileName is required for -DisableProfileSchedule" -ForegroundColor Red
            return 1
        }
        $result = Disable-ProfileScheduledTask -ProfileName $ProfileName
        if ($result.Success) {
            Write-Host "Profile schedule disabled for '$ProfileName'" -ForegroundColor Green
            return 0
        } else {
            Write-Host "Error: $($result.ErrorMessage)" -ForegroundColor Red
            return 1
        }
    }

    if ($SyncProfileSchedules) {
        if (-not (Test-Path $ConfigPath)) {
            Write-Host "Error: Configuration file not found: $ConfigPath" -ForegroundColor Red
            return 1
        }
        $config = Get-RobocurseConfig -Path $ConfigPath
        $result = Sync-ProfileSchedules -Config $config -ConfigPath $ConfigPath
        if ($result.Success) {
            Write-Host "Profile schedules synced successfully" -ForegroundColor Green
            if ($result.Data.Created -gt 0) { Write-Host "  Created: $($result.Data.Created)" }
            if ($result.Data.Removed -gt 0) { Write-Host "  Removed: $($result.Data.Removed)" }
            Write-Host "  Total: $($result.Data.Total)"
            return 0
        } else {
            Write-Host "Error: $($result.ErrorMessage)" -ForegroundColor Red
            return 1
        }
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
            Write-Error 'Headless mode requires either -Profile <name> or -AllProfiles parameter.'
            return 1
        }

        if ($ProfileName -and $AllProfiles) {
            Write-Warning "-Profile and -AllProfiles both specified. Using -Profile '$ProfileName'."
        }

        # Phase 3b: Initialize logging
        try {
            $logRoot = if ($config.GlobalSettings.LogPath) { $config.GlobalSettings.LogPath } else { '.\Logs' }
            # Resolve relative paths based on config file directory (same as GUI mode)
            if (-not [System.IO.Path]::IsPathRooted($logRoot)) {
                $configDir = Split-Path -Parent $ConfigPath
                $logRoot = [System.IO.Path]::GetFullPath((Join-Path $configDir $logRoot))
            }
            $compressDays = if ($config.GlobalSettings.LogCompressAfterDays) { $config.GlobalSettings.LogCompressAfterDays } else { $script:LogCompressAfterDays }
            $deleteDays = if ($config.GlobalSettings.LogRetentionDays) { $config.GlobalSettings.LogRetentionDays } else { $script:LogDeleteAfterDays }
            Initialize-LogSession -LogRoot $logRoot -CompressAfterDays $compressDays -DeleteAfterDays $deleteDays
            $logSessionInitialized = $true

            # Enable path redaction if configured (for security/privacy)
            if ($config.GlobalSettings.RedactPaths) {
                $serverNames = if ($config.GlobalSettings.RedactServerNames) { @($config.GlobalSettings.RedactServerNames) } else { @() }
                Enable-PathRedaction -ServerNames $serverNames
            }
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

        # Phase 3c.5: Early VSS privilege check for profiles that require VSS
        # Fail fast before starting replication if VSS prerequisites are not met
        $vssProfiles = @($profilesToRun | Where-Object { $_.UseVSS -eq $true })
        if ($vssProfiles.Count -gt 0) {
            $vssCheck = Test-VssPrivileges
            if (-not $vssCheck.Success) {
                $vssProfileNames = ($vssProfiles | ForEach-Object { $_.Name }) -join ", "
                Write-Error "VSS is required for profile(s) '$vssProfileNames' but VSS prerequisites are not met: $($vssCheck.ErrorMessage)"
                return 1
            }
            Write-Host "VSS privileges verified for $($vssProfiles.Count) profile(s)"
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

            return Invoke-HeadlessReplication -Config $config -ConfigPath $ConfigPath -ProfilesToRun $profilesToRun `
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
                # Use ShowDialog() for modal window - Forms.Timer works reliably with this
                # (unlike DispatcherTimer which got starved in the modal loop)
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
