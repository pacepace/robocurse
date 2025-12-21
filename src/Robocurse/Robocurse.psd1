@{
    # Module manifest for Robocurse

    # Script module file associated with this manifest
    RootModule = 'Robocurse.psm1'

    # Version number of this module
    ModuleVersion = '1.0.0'

    # ID used to uniquely identify this module
    GUID = 'f228b3b9-963b-4125-bc4c-ce82856cb6fd'

    # Author of this module
    Author = 'Mark Pace'

    # Company or vendor of this module
    CompanyName = 'pace.org'

    # Copyright statement for this module
    Copyright = '(c) 2025 Mark Pace. All rights reserved.'

    # Description of the functionality provided by this module
    Description = 'Multi-share parallel robocopy orchestrator for Windows environments.'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '5.1'

    # Supported PowerShell editions (Desktop = Windows PowerShell 5.1, Core = PowerShell 7+)
    # Note: This module requires Windows due to robocopy.exe, VSS, and Task Scheduler dependencies
    CompatiblePSEditions = @('Desktop', 'Core')

    # Functions to export from this module
    # Note: Internal helper functions (e.g., Get-CachedProfile, New-Chunk, Test-PathFormat, etc.)
    # are intentionally NOT exported. They remain accessible within the module but are not part
    # of the public API. Only functions intended for external use are listed below.
    FunctionsToExport = @(
        # Utility
        'Test-IsWindowsPlatform'
        'Test-IsBeingDotSourced'
        'Test-RobocopyAvailable'
        'Set-RobocopyPath'
        'Clear-RobocopyPath'
        'Get-NormalizedCacheKey'
        'New-OperationResult'

        # Configuration
        'New-DefaultConfig'
        'Get-RobocurseConfig'
        'Save-RobocurseConfig'
        'Test-RobocurseConfig'
        'Test-SafeConfigPath'
        'ConvertFrom-ConfigFileFormat'
        'ConvertFrom-GlobalSettings'
        'ConvertFrom-ProfileSources'
        'ConvertTo-RobocopyOptionsInternal'
        'ConvertTo-ChunkSettingsInternal'
        'Get-DestinationPathFromRaw'

        # Logging
        'Initialize-LogSession'
        'Write-RobocurseLog'
        'Write-SiemEvent'
        'Invoke-LogRotation'

        # Directory Profiling
        'Get-DirectoryProfile'
        'Invoke-RobocopyList'
        'Get-DirectoryChildren'
        'Get-DirectoryProfilesParallel'
        'Clear-ProfileCache'

        # Chunking
        'Get-DirectoryChunks'
        'New-SmartChunks'
        'New-FlatChunks'

        # Robocopy Wrapper
        'Start-RobocopyJob'
        'Get-RobocopyExitMeaning'
        'ConvertFrom-RobocopyLog'
        'New-RobocopyArguments'
        'Get-BandwidthThrottleIPG'
        'Start-ChunkJob'

        # Orchestration Core
        'Initialize-OrchestrationState'
        'Initialize-OrchestrationStateType'
        'Get-OrchestrationState'
        'Reset-CircuitBreaker'
        'Test-CircuitBreakerTripped'

        # Job Management
        'Start-ReplicationRun'
        'Invoke-ReplicationTick'
        'Stop-AllJobs'
        'Request-Stop'
        'Request-Pause'
        'Request-Resume'
        'Get-OrchestrationStatus'

        # Health Check
        'Write-HealthCheckStatus'
        'Get-HealthCheckStatus'
        'Remove-HealthCheckStatus'

        # Checkpoint
        'Save-ReplicationCheckpoint'
        'Get-ReplicationCheckpoint'
        'Remove-ReplicationCheckpoint'
        'Test-ChunkAlreadyCompleted'

        # Progress
        'Get-RobocopyProgress'
        'Update-ProgressStats'
        'Get-ETAEstimate'

        # VSS Local
        'Test-VssPrivileges'
        'New-VssSnapshot'
        'Remove-VssSnapshot'
        'Get-VssPath'
        'Clear-OrphanVssSnapshots'
        'Get-VssSnapshots'
        'Invoke-VssRetentionPolicy'

        # VSS Remote
        'Get-RemoteVssSnapshots'
        'Invoke-RemoteVssRetentionPolicy'
        'Get-RemoteVssErrorGuidance'

        # Profile Snapshot Integration
        'Invoke-ProfilePersistentSnapshot'

        # Email
        'Initialize-CredentialManager'
        'Get-SmtpCredential'
        'Save-SmtpCredential'
        'Remove-SmtpCredential'
        'Test-SmtpCredential'
        'Send-CompletionEmail'
        'Test-EmailConfiguration'
        'New-CompletionEmailBody'
        'Format-FileSize'

        # Scheduling
        'Register-RobocurseTask'
        'Unregister-RobocurseTask'
        'Get-RobocurseTask'
        'Start-RobocurseTask'
        'Enable-RobocurseTask'
        'Disable-RobocurseTask'
        'Test-RobocurseTaskExists'

        # Snapshot Scheduling
        'New-SnapshotScheduledTask'
        'New-SnapshotTaskCommand'
        'Remove-SnapshotScheduledTask'
        'Get-SnapshotScheduledTasks'
        'Sync-SnapshotSchedules'

        # Profile Scheduling
        'New-ProfileScheduledTask'
        'Remove-ProfileScheduledTask'
        'Get-ProfileScheduledTask'
        'Get-AllProfileScheduledTasks'
        'Enable-ProfileScheduledTask'
        'Disable-ProfileScheduledTask'
        'Sync-ProfileSchedules'

        # Snapshot CLI
        'Invoke-ListSnapshotsCommand'
        'Invoke-CreateSnapshotCommand'
        'Invoke-DeleteSnapshotCommand'
        'Invoke-SnapshotScheduleCommand'

        # GUI
        'Initialize-RobocurseGui'
        'Update-GuiProgress'
        'Show-GuiError'
        'Write-GuiLog'
        'Show-ConfirmDialog'
        'Show-AlertDialog'
        'Show-ProfileScheduleDialog'

        # GUI Log Window
        'Show-LogWindow'
        'Clear-GuiLogBuffer'
        'Close-LogWindow'

        # GUI Validation
        'Test-ProfileValidation'
        'Show-ValidationDialog'

        # GUI Snapshots
        'Initialize-SnapshotsPanel'
        'Update-VolumeFilterDropdown'
        'Update-SnapshotList'
        'Add-RemoteServerToFilter'
        'Get-SelectedSnapshot'

        # GUI Snapshot Dialogs
        'Show-CreateSnapshotDialog'
        'Invoke-CreateSnapshotFromDialog'
        'Show-DeleteSnapshotConfirmation'
        'Invoke-DeleteSelectedSnapshot'

        # Main
        'Start-RobocurseMain'
        'Show-RobocurseHelp'
        'Invoke-HeadlessReplication'
    )

    # Cmdlets to export from this module
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module
    AliasesToExport = @()

    # Private data to pass to the module
    PrivateData = @{
        PSData = @{
            Tags = @('robocopy', 'backup', 'replication', 'parallel', 'orchestration', 'file-sync')
            LicenseUri = 'https://opensource.org/licenses/MIT'
            ProjectUri = 'https://github.com/pacepace/robocurse'
            ReleaseNotes = '1.0.0 - Initial release'
        }
    }
}
