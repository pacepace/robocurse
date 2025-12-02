@{
    # Module manifest for Robocurse

    # Script module file associated with this manifest
    RootModule = 'Robocurse.psm1'

    # Version number of this module
    ModuleVersion = '1.0.0'

    # ID used to uniquely identify this module
    GUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'

    # Author of this module
    Author = 'Mark Pace'

    # Company or vendor of this module
    CompanyName = 'pace.org'

    # Copyright statement for this module
    Copyright = '(c) 2024 Mark Pace. All rights reserved.'

    # Description of the functionality provided by this module
    Description = 'Multi-share parallel robocopy orchestrator for Windows environments.'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '5.1'

    # Functions to export from this module
    FunctionsToExport = @(
        # Utility
        'Test-IsWindowsPlatform'
        'Test-IsBeingDotSourced'
        'Test-RobocopyAvailable'
        'Set-RobocopyPath'
        'Clear-RobocopyPath'
        'ConvertTo-SafeFilename'
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

        # Chunking
        'Get-DirectoryChunks'
        'New-SmartChunks'
        'New-FlatChunks'

        # Robocopy Wrapper
        'Start-RobocopyJob'
        'Get-RobocopyExitMeaning'
        'ConvertFrom-RobocopyLog'
        'Build-RobocopyArguments'
        'Start-ChunkJob'

        # Orchestration
        'Initialize-OrchestrationState'
        'Start-ReplicationRun'
        'Invoke-ReplicationTick'
        'Stop-AllJobs'
        'Request-Stop'
        'Get-OrchestrationStatus'

        # Checkpoint
        'Save-Checkpoint'
        'Get-Checkpoint'
        'Resume-FromCheckpoint'
        'Remove-Checkpoint'

        # Progress
        'Get-RobocopyProgress'
        'Update-ProgressStats'
        'Get-ETAEstimate'

        # VSS
        'Test-VssPrivileges'
        'New-VssSnapshot'
        'Remove-VssSnapshot'
        'Get-VssPath'
        'Get-VssShadowCopyId'

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

        # GUI
        'Initialize-RobocurseGui'
        'Update-GuiProgress'
        'Show-GuiError'
        'Write-GuiLog'

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
