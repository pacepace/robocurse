# Robocurse GUI Profile Management
# Handles profile CRUD operations and form synchronization.

function Update-ProfileSettingsVisibility {
    <#
    .SYNOPSIS
        Shows or hides the profile settings panel based on whether a profile is selected
    #>
    [CmdletBinding()]
    param()

    $hasProfile = $null -ne $script:Controls.lstProfiles.SelectedItem

    if ($script:Controls['pnlProfileSettingsContent'] -and $script:Controls['pnlNoProfileMessage']) {
        if ($hasProfile) {
            $script:Controls.pnlProfileSettingsContent.Visibility = [System.Windows.Visibility]::Visible
            $script:Controls.pnlNoProfileMessage.Visibility = [System.Windows.Visibility]::Collapsed
        } else {
            $script:Controls.pnlProfileSettingsContent.Visibility = [System.Windows.Visibility]::Collapsed
            $script:Controls.pnlNoProfileMessage.Visibility = [System.Windows.Visibility]::Visible
        }
    }

    # Update schedule button state
    Update-ProfileScheduleButtonState
}

function Update-ProfileScheduleButtonState {
    <#
    .SYNOPSIS
        Updates the Schedule button appearance based on current profile's schedule status
    #>
    [CmdletBinding()]
    param()

    if (-not $script:Controls['btnProfileSchedule']) { return }

    $selectedProfile = $script:Controls.lstProfiles.SelectedItem
    if (-not $selectedProfile) {
        $script:Controls.btnProfileSchedule.IsEnabled = $false
        $script:Controls.btnProfileSchedule.Content = "Schedule"
        return
    }

    $script:Controls.btnProfileSchedule.IsEnabled = $true

    # Check schedule on selected profile (SelectedItem is already the profile object)
    if ($selectedProfile.Schedule -and $selectedProfile.Schedule.Enabled) {
        # Show schedule is active
        $script:Controls.btnProfileSchedule.Content = "Scheduled"
        $freq = $selectedProfile.Schedule.Frequency
        $time = $selectedProfile.Schedule.Time
        $script:Controls.btnProfileSchedule.ToolTip = "Schedule enabled - $freq at $time"
    } else {
        $script:Controls.btnProfileSchedule.Content = "Schedule"
        $script:Controls.btnProfileSchedule.ToolTip = "Configure scheduled runs for this profile"
    }
}

function Update-ProfileList {
    <#
    .SYNOPSIS
        Populates the profile listbox from config
    #>
    [CmdletBinding()]
    param()

    $script:Controls.lstProfiles.Items.Clear()

    if ($script:Config.SyncProfiles) {
        foreach ($profile in $script:Config.SyncProfiles) {
            $script:Controls.lstProfiles.Items.Add($profile) | Out-Null
        }
    }

    # Select first profile if available
    if ($script:Controls.lstProfiles.Items.Count -gt 0) {
        $script:Controls.lstProfiles.SelectedIndex = 0
    }

    # Update visibility of settings panel
    Update-ProfileSettingsVisibility
}

function Import-ProfileToForm {
    <#
    .SYNOPSIS
        Imports selected profile data into form fields
    .PARAMETER Profile
        Profile object to import
    #>
    [CmdletBinding()]
    param([PSCustomObject]$Profile)

    # Guard against null profile
    if ($null -eq $Profile) { return }

    # Load basic properties with null safety
    $script:Controls.txtProfileName.Text = if ($Profile.Name) { $Profile.Name } else { "" }
    $script:Controls.txtSource.Text = if ($Profile.Source) { $Profile.Source } else { "" }
    $script:Controls.txtDest.Text = if ($Profile.Destination) { $Profile.Destination } else { "" }
    $script:Controls.chkUseVss.IsChecked = if ($null -ne $Profile.UseVSS) { $Profile.UseVSS } else { $false }

    # Load Source Snapshot settings
    if ($script:Controls['chkSourcePersistentSnapshot']) {
        $srcEnabled = $false
        $srcRetention = 3
        if ($Profile.SourceSnapshot) {
            $srcEnabled = [bool]$Profile.SourceSnapshot.PersistentEnabled
            if ($Profile.SourceSnapshot.RetentionCount) {
                $srcRetention = $Profile.SourceSnapshot.RetentionCount
            }
        }
        $script:Controls.chkSourcePersistentSnapshot.IsChecked = $srcEnabled
        $script:Controls.txtSourceRetentionCount.Text = $srcRetention.ToString()
    }

    # Load Destination Snapshot settings
    if ($script:Controls['chkDestPersistentSnapshot']) {
        $destEnabled = $false
        $destRetention = 3
        if ($Profile.DestinationSnapshot) {
            $destEnabled = [bool]$Profile.DestinationSnapshot.PersistentEnabled
            if ($Profile.DestinationSnapshot.RetentionCount) {
                $destRetention = $Profile.DestinationSnapshot.RetentionCount
            }
        }
        $script:Controls.chkDestPersistentSnapshot.IsChecked = $destEnabled
        $script:Controls.txtDestRetentionCount.Text = $destRetention.ToString()
    }

    # Refresh snapshot lists for this profile
    Update-ProfileSnapshotLists

    # Set scan mode
    $scanMode = if ($Profile.ScanMode) { $Profile.ScanMode } else { "Smart" }
    $script:Controls.cmbScanMode.SelectedIndex = if ($scanMode -eq "Quick") { 1 } else { 0 }

    # Load chunk settings with defaults from module constants
    $maxSize = if ($null -ne $Profile.ChunkMaxSizeGB) { $Profile.ChunkMaxSizeGB } else { $script:DefaultMaxChunkSizeBytes / 1GB }
    $maxFiles = if ($null -ne $Profile.ChunkMaxFiles) { $Profile.ChunkMaxFiles } else { $script:DefaultMaxFilesPerChunk }
    $maxDepth = if ($null -ne $Profile.ChunkMaxDepth) { $Profile.ChunkMaxDepth } else { $script:DefaultMaxChunkDepth }

    # Debug: log what we're loading
    Write-GuiLog "Loading profile '$($Profile.Name)': ChunkMaxSizeGB=$($Profile.ChunkMaxSizeGB) (display: $maxSize), ChunkMaxFiles=$($Profile.ChunkMaxFiles), ChunkMaxDepth=$($Profile.ChunkMaxDepth)"

    $script:Controls.txtMaxSize.Text = $maxSize.ToString()
    $script:Controls.txtMaxFiles.Text = $maxFiles.ToString()
    $script:Controls.txtMaxDepth.Text = $maxDepth.ToString()
}

function Save-ProfileFromForm {
    <#
    .SYNOPSIS
        Saves form fields back to selected profile
    #>
    [CmdletBinding()]
    param()

    # Skip saving during GUI initialization (checkbox/combo events fire when setting values)
    if ($script:GuiInitializing) {
        return
    }

    $selected = $script:Controls.lstProfiles.SelectedItem
    if (-not $selected) { return }

    # Update profile object
    $selected.Name = $script:Controls.txtProfileName.Text
    $selected.Source = $script:Controls.txtSource.Text
    $selected.Destination = $script:Controls.txtDest.Text
    $selected.UseVSS = $script:Controls.chkUseVss.IsChecked
    $selected.ScanMode = $script:Controls.cmbScanMode.Text

    # Update Source Snapshot settings
    if ($script:Controls['chkSourcePersistentSnapshot']) {
        if (-not $selected.SourceSnapshot) {
            $selected | Add-Member -NotePropertyName SourceSnapshot -NotePropertyValue ([PSCustomObject]@{
                PersistentEnabled = $false
                RetentionCount = 3
            }) -Force
        }
        $selected.SourceSnapshot.PersistentEnabled = $script:Controls.chkSourcePersistentSnapshot.IsChecked
        try {
            $srcRetention = [int]$script:Controls.txtSourceRetentionCount.Text
            $selected.SourceSnapshot.RetentionCount = [Math]::Max(1, [Math]::Min(100, $srcRetention))
        } catch {
            $selected.SourceSnapshot.RetentionCount = 3
        }
    }

    # Update Destination Snapshot settings
    if ($script:Controls['chkDestPersistentSnapshot']) {
        if (-not $selected.DestinationSnapshot) {
            $selected | Add-Member -NotePropertyName DestinationSnapshot -NotePropertyValue ([PSCustomObject]@{
                PersistentEnabled = $false
                RetentionCount = 3
            }) -Force
        }
        $selected.DestinationSnapshot.PersistentEnabled = $script:Controls.chkDestPersistentSnapshot.IsChecked
        try {
            $destRetention = [int]$script:Controls.txtDestRetentionCount.Text
            $selected.DestinationSnapshot.RetentionCount = [Math]::Max(1, [Math]::Min(100, $destRetention))
        } catch {
            $selected.DestinationSnapshot.RetentionCount = 3
        }
    }

    # Parse numeric values with validation and bounds checking
    # Helper function to provide visual feedback for input corrections
    $showInputCorrected = {
        param($control, $originalValue, $correctedValue, $fieldName)
        $control.Text = $correctedValue.ToString()
        $control.ToolTip = "Value '$originalValue' was corrected to '$correctedValue'"
        # Flash the background briefly to indicate correction (uses existing theme colors)
        $originalBg = $control.Background
        $control.Background = [System.Windows.Media.Brushes]::DarkOrange
        # Reset after 1.5 seconds using a dispatcher timer
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(1500)
        $timer.Add_Tick({
            $control.Background = $originalBg
            $control.ToolTip = $null
            $this.Stop()
        })
        $timer.Start()
        Write-GuiLog "Input corrected: $fieldName '$originalValue' -> '$correctedValue'"
    }

    # ChunkMaxSizeGB: valid range 1-1000 GB
    try {
        $value = [int]$script:Controls.txtMaxSize.Text
        $selected.ChunkMaxSizeGB = [Math]::Max(1, [Math]::Min(1000, $value))
        if ($value -ne $selected.ChunkMaxSizeGB) {
            & $showInputCorrected $script:Controls.txtMaxSize $value $selected.ChunkMaxSizeGB "Max Size (GB)"
        }
    } catch {
        $originalText = $script:Controls.txtMaxSize.Text
        $selected.ChunkMaxSizeGB = 10
        & $showInputCorrected $script:Controls.txtMaxSize $originalText 10 "Max Size (GB)"
    }

    # ChunkMaxFiles: valid range 1000-10000000
    try {
        $value = [int]$script:Controls.txtMaxFiles.Text
        $selected.ChunkMaxFiles = [Math]::Max(1000, [Math]::Min(10000000, $value))
        if ($value -ne $selected.ChunkMaxFiles) {
            & $showInputCorrected $script:Controls.txtMaxFiles $value $selected.ChunkMaxFiles "Max Files"
        }
    } catch {
        $originalText = $script:Controls.txtMaxFiles.Text
        $selected.ChunkMaxFiles = $script:DefaultMaxFilesPerChunk
        & $showInputCorrected $script:Controls.txtMaxFiles $originalText $script:DefaultMaxFilesPerChunk "Max Files"
    }

    # ChunkMaxDepth: valid range 1-20
    try {
        $value = [int]$script:Controls.txtMaxDepth.Text
        $selected.ChunkMaxDepth = [Math]::Max(1, [Math]::Min(20, $value))
        if ($value -ne $selected.ChunkMaxDepth) {
            & $showInputCorrected $script:Controls.txtMaxDepth $value $selected.ChunkMaxDepth "Max Depth"
        }
    } catch {
        $originalText = $script:Controls.txtMaxDepth.Text
        $selected.ChunkMaxDepth = $script:DefaultMaxChunkDepth
        & $showInputCorrected $script:Controls.txtMaxDepth $originalText $script:DefaultMaxChunkDepth "Max Depth"
    }

    # Refresh list display
    $script:Controls.lstProfiles.Items.Refresh()

    # Auto-save config to disk
    $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
    if (-not $saveResult.Success) {
        Write-GuiLog "Warning: Auto-save failed: $($saveResult.ErrorMessage)"
    }
}

function Add-NewProfile {
    <#
    .SYNOPSIS
        Creates a new profile with defaults
    #>
    [CmdletBinding()]
    param()

    $newProfile = [PSCustomObject]@{
        Name = "New Profile"
        Source = ""
        Destination = ""
        Enabled = $true
        UseVSS = $false
        ScanMode = "Smart"
        ChunkMaxSizeGB = $script:DefaultMaxChunkSizeBytes / 1GB
        ChunkMaxFiles = $script:DefaultMaxFilesPerChunk
        ChunkMaxDepth = $script:DefaultMaxChunkDepth
        SourceSnapshot = [PSCustomObject]@{
            PersistentEnabled = $false
            RetentionCount = 3
        }
        DestinationSnapshot = [PSCustomObject]@{
            PersistentEnabled = $false
            RetentionCount = 3
        }
    }

    # Add to config
    if (-not $script:Config.SyncProfiles) {
        $script:Config.SyncProfiles = @()
    }
    $script:Config.SyncProfiles += $newProfile

    # Update UI
    Update-ProfileList
    $script:Controls.lstProfiles.SelectedIndex = $script:Controls.lstProfiles.Items.Count - 1

    # Auto-save config to disk
    $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
    if (-not $saveResult.Success) {
        Write-GuiLog "Warning: Auto-save failed: $($saveResult.ErrorMessage)"
    }

    Write-GuiLog "New profile created"
}

function Remove-SelectedProfile {
    <#
    .SYNOPSIS
        Removes selected profile with confirmation
    #>
    [CmdletBinding()]
    param()

    $selected = $script:Controls.lstProfiles.SelectedItem
    if (-not $selected) {
        [System.Windows.MessageBox]::Show(
            "Please select a profile to remove.",
            "No Selection",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        return
    }

    $confirmed = Show-ConfirmDialog `
        -Title "Remove Profile" `
        -Message "Are you sure you want to remove the profile '$($selected.Name)'?" `
        -ConfirmText "Remove" `
        -CancelText "Cancel"

    if ($confirmed) {
        $script:Config.SyncProfiles = @($script:Config.SyncProfiles | Where-Object { $_ -ne $selected })
        Update-ProfileList
        Update-ProfileSettingsVisibility

        # Auto-save config to disk
        $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
        if (-not $saveResult.Success) {
            Write-GuiLog "Warning: Auto-save failed: $($saveResult.ErrorMessage)"
        }

        Write-GuiLog "Profile '$($selected.Name)' removed"
    }
}

function Update-ProfileSnapshotLists {
    <#
    .SYNOPSIS
        Refreshes the per-profile snapshot DataGrids based on selected profile's volumes
    .DESCRIPTION
        Loads existing VSS snapshots for the source and destination volumes of the
        currently selected profile and populates the respective DataGrids.
        Adds a Status property to indicate tracked (Robocurse) vs external snapshots.
    #>
    [CmdletBinding()]
    param()

    $profile = $script:Controls.lstProfiles.SelectedItem
    if (-not $profile) {
        # Clear grids if no profile selected
        if ($script:Controls['dgSourceSnapshots']) {
            $script:Controls.dgSourceSnapshots.ItemsSource = @()
        }
        if ($script:Controls['dgDestSnapshots']) {
            $script:Controls.dgDestSnapshots.ItemsSource = @()
        }
        return
    }

    # Helper function to add Status property to snapshots
    $addStatusToSnapshots = {
        param($snapshots)
        $result = @()
        foreach ($snap in $snapshots) {
            $isTracked = if ($script:Config) {
                Test-SnapshotRegistered -Config $script:Config -ShadowId $snap.ShadowId
            } else { $false }
            $snapWithStatus = [PSCustomObject]@{
                ShadowId = $snap.ShadowId
                SourceVolume = $snap.SourceVolume
                CreatedAt = $snap.CreatedAt
                DeviceObject = $snap.DeviceObject
                Status = if ($isTracked) { "Tracked" } else { "EXTERNAL" }
            }
            $result += $snapWithStatus
        }
        return $result
    }

    # Get source volume and load snapshots
    if ($script:Controls['dgSourceSnapshots'] -and $profile.Source) {
        try {
            $sourceVolume = Get-VolumeFromPath -Path $profile.Source
            if ($sourceVolume) {
                $result = Get-VssSnapshots -Volume $sourceVolume
                if ($result.Success) {
                    $snapsWithStatus = & $addStatusToSnapshots @($result.Data)
                    $script:Controls.dgSourceSnapshots.ItemsSource = @($snapsWithStatus)
                } else {
                    $script:Controls.dgSourceSnapshots.ItemsSource = @()
                }
            } else {
                $script:Controls.dgSourceSnapshots.ItemsSource = @()
            }
        } catch {
            Write-GuiLog "Error loading source snapshots: $($_.Exception.Message)"
            $script:Controls.dgSourceSnapshots.ItemsSource = @()
        }
    }

    # Get destination volume and load snapshots
    if ($script:Controls['dgDestSnapshots'] -and $profile.Destination) {
        try {
            $destVolume = Get-VolumeFromPath -Path $profile.Destination
            if ($destVolume) {
                $result = Get-VssSnapshots -Volume $destVolume
                if ($result.Success) {
                    $snapsWithStatus = & $addStatusToSnapshots @($result.Data)
                    $script:Controls.dgDestSnapshots.ItemsSource = @($snapsWithStatus)
                } else {
                    $script:Controls.dgDestSnapshots.ItemsSource = @()
                }
            } else {
                $script:Controls.dgDestSnapshots.ItemsSource = @()
            }
        } catch {
            Write-GuiLog "Error loading destination snapshots: $($_.Exception.Message)"
            $script:Controls.dgDestSnapshots.ItemsSource = @()
        }
    }
}

function Invoke-DeleteProfileSnapshot {
    <#
    .SYNOPSIS
        Deletes the selected snapshot from a profile's snapshot grid
    .DESCRIPTION
        Deletes the snapshot and unregisters it from the config's snapshot registry
        if Config and ConfigPath are available in script scope.
    .PARAMETER SnapshotGrid
        The DataGrid control containing the selected snapshot
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SnapshotGrid
    )

    $selected = $SnapshotGrid.SelectedItem
    if (-not $selected) {
        return
    }

    $confirmed = Show-ConfirmDialog `
        -Title "Delete Snapshot" `
        -Message "Are you sure you want to delete this VSS snapshot?`n`nShadow ID: $($selected.ShadowId)`nCreated: $($selected.CreatedAt)" `
        -ConfirmText "Delete" `
        -CancelText "Cancel"

    if ($confirmed) {
        $result = Remove-VssSnapshot -ShadowId $selected.ShadowId
        if ($result.Success) {
            Write-GuiLog "Snapshot deleted: $($selected.ShadowId)"
            # Unregister from snapshot registry if config is available
            if ($script:Config -and $script:ConfigPath) {
                $null = Unregister-PersistentSnapshot -Config $script:Config -ShadowId $selected.ShadowId -ConfigPath $script:ConfigPath
            }
            Update-ProfileSnapshotLists
        } else {
            [System.Windows.MessageBox]::Show(
                "Failed to delete snapshot: $($result.ErrorMessage)",
                "Error",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
        }
    }
}
