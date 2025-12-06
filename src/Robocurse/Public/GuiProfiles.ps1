# Robocurse GUI Profile Management
# Handles profile CRUD operations and form synchronization.

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

    # Set scan mode
    $scanMode = if ($Profile.ScanMode) { $Profile.ScanMode } else { "Smart" }
    $script:Controls.cmbScanMode.SelectedIndex = if ($scanMode -eq "Quick") { 1 } else { 0 }

    # Load chunk settings with defaults from module constants
    $maxSize = if ($null -ne $Profile.ChunkMaxSizeGB) { $Profile.ChunkMaxSizeGB } else { $script:DefaultMaxChunkSizeBytes / 1GB }
    $maxFiles = if ($null -ne $Profile.ChunkMaxFiles) { $Profile.ChunkMaxFiles } else { $script:DefaultMaxFilesPerChunk }
    $maxDepth = if ($null -ne $Profile.ChunkMaxDepth) { $Profile.ChunkMaxDepth } else { $script:DefaultMaxChunkDepth }

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

    $selected = $script:Controls.lstProfiles.SelectedItem
    if (-not $selected) { return }

    # Update profile object
    $selected.Name = $script:Controls.txtProfileName.Text
    $selected.Source = $script:Controls.txtSource.Text
    $selected.Destination = $script:Controls.txtDest.Text
    $selected.UseVSS = $script:Controls.chkUseVss.IsChecked
    $selected.ScanMode = $script:Controls.cmbScanMode.Text

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

        # Auto-save config to disk
        $saveResult = Save-RobocurseConfig -Config $script:Config -Path $script:ConfigPath
        if (-not $saveResult.Success) {
            Write-GuiLog "Warning: Auto-save failed: $($saveResult.ErrorMessage)"
        }

        Write-GuiLog "Profile '$($selected.Name)' removed"
    }
}
