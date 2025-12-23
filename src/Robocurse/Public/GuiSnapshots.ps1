# Robocurse GUI Snapshot Management
# Handles the Snapshots panel in the GUI

function Initialize-SnapshotsPanel {
    <#
    .SYNOPSIS
        Initializes the Snapshots panel controls and event handlers
    #>
    [CmdletBinding()]
    param()

    # Populate volume filter with local drives
    Update-VolumeFilterDropdown

    # Wire event handlers
    $script:Controls['btnRefreshSnapshots'].Add_Click({
        Invoke-SafeEventHandler -HandlerName "RefreshSnapshots" -ScriptBlock {
            Update-SnapshotList
        }
    })

    $script:Controls['cmbSnapshotVolume'].Add_SelectionChanged({
        Invoke-SafeEventHandler -HandlerName "VolumeFilterChanged" -ScriptBlock {
            Update-SnapshotList
        }
    })

    $script:Controls['cmbSnapshotServer'].Add_SelectionChanged({
        Invoke-SafeEventHandler -HandlerName "ServerFilterChanged" -ScriptBlock {
            Update-SnapshotList
        }
    })

    $script:Controls['dgSnapshots'].Add_SelectionChanged({
        Invoke-SafeEventHandler -HandlerName "SnapshotSelectionChanged" -ScriptBlock {
            $selected = $script:Controls['dgSnapshots'].SelectedItem
            $script:Controls['btnDeleteSnapshot'].IsEnabled = ($null -ne $selected)
        }
    })

    # Wire Create Snapshot button
    $script:Controls['btnCreateSnapshot'].Add_Click({
        Invoke-SafeEventHandler -HandlerName "CreateSnapshot" -ScriptBlock {
            $dialogResult = Show-CreateSnapshotDialog
            if ($dialogResult) {
                # Disable buttons during operation
                $script:Controls['btnCreateSnapshot'].IsEnabled = $false
                $script:Controls['btnDeleteSnapshot'].IsEnabled = $false

                try {
                    $result = Invoke-CreateSnapshotFromDialog -DialogResult $dialogResult

                    if ($result.Success) {
                        Show-AlertDialog -Title "Snapshot Created" -Message "Snapshot created successfully.`n`nShadow ID: $($result.Data.ShadowId)" -Icon 'Info'
                    }
                    else {
                        Show-AlertDialog -Title "Error" -Message "Failed to create snapshot:`n`n$($result.ErrorMessage)" -Icon 'Error'
                    }
                }
                finally {
                    # Re-enable and refresh
                    $script:Controls['btnCreateSnapshot'].IsEnabled = $true
                    Update-SnapshotList
                }
            }
        }
    })

    # Wire Delete Snapshot button
    $script:Controls['btnDeleteSnapshot'].Add_Click({
        Invoke-SafeEventHandler -HandlerName "DeleteSnapshot" -ScriptBlock {
            $result = Invoke-DeleteSelectedSnapshot

            if ($result.Success -and $result.Data -ne "Cancelled") {
                # Refresh list
                Update-SnapshotList
            }
            elseif (-not $result.Success) {
                Show-AlertDialog -Title "Error" -Message "Failed to delete snapshot:`n`n$($result.ErrorMessage)" -Icon 'Error'
            }
        }
    })

    # Initial load
    Update-SnapshotList

    Write-RobocurseLog -Message "Snapshots panel initialized" -Level 'Debug' -Component 'GUI'
}

function Update-VolumeFilterDropdown {
    <#
    .SYNOPSIS
        Populates the volume filter dropdown with available volumes
    #>
    [CmdletBinding()]
    param()

    $combo = $script:Controls['cmbSnapshotVolume']
    $combo.Items.Clear()

    # Add "All Volumes" option
    $allItem = [System.Windows.Controls.ComboBoxItem]::new()
    $allItem.Content = "All Volumes"
    $allItem.IsSelected = $true
    $combo.Items.Add($allItem) | Out-Null

    # Add local volumes
    try {
        $volumes = Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } |
            Sort-Object DriveLetter

        foreach ($vol in $volumes) {
            $item = [System.Windows.Controls.ComboBoxItem]::new()
            $item.Content = $vol.DriveLetter
            $combo.Items.Add($item) | Out-Null
        }
    }
    catch {
        Write-RobocurseLog -Message "Failed to enumerate volumes: $($_.Exception.Message)" -Level 'Warning' -Component 'GUI'
    }
}

function Update-SnapshotList {
    <#
    .SYNOPSIS
        Refreshes the snapshot DataGrid with current snapshots
    .DESCRIPTION
        Loads snapshots from local or remote server and adds Status property
        to indicate tracked (Robocurse) vs external snapshots.
    #>
    [CmdletBinding()]
    param()

    $grid = $script:Controls['dgSnapshots']

    try {
        # Get filter values
        $volumeFilter = $script:Controls['cmbSnapshotVolume'].SelectedItem.Content
        $serverFilter = $script:Controls['cmbSnapshotServer'].SelectedItem.Content

        Write-RobocurseLog -Message "Loading snapshots (volume: $volumeFilter, server: $serverFilter)" -Level 'Debug' -Component 'GUI'

        $snapshots = @()

        if ($serverFilter -eq "Local") {
            # Get local snapshots
            if ($volumeFilter -eq "All Volumes") {
                $result = Get-VssSnapshots
            }
            else {
                $result = Get-VssSnapshots -Volume $volumeFilter
            }

            if ($result.Success) {
                $snapshots = @($result.Data | ForEach-Object {
                    $isTracked = if ($script:Config) {
                        Test-SnapshotRegistered -Config $script:Config -ShadowId $_.ShadowId
                    } else { $false }
                    [PSCustomObject]@{
                        ShadowId     = $_.ShadowId
                        SourceVolume = $_.SourceVolume
                        CreatedAt    = $_.CreatedAt
                        ServerName   = "Local"
                        ShadowPath   = $_.ShadowPath
                        Status       = if ($isTracked) { "Tracked" } else { "EXTERNAL" }
                    }
                })
            }
            else {
                Write-RobocurseLog -Message "Failed to load snapshots: $($result.ErrorMessage)" -Level 'Warning' -Component 'GUI'
            }
        }
        else {
            # Get remote snapshots
            if ($volumeFilter -eq "All Volumes") {
                $result = Get-RemoteVssSnapshots -ServerName $serverFilter
            }
            else {
                $result = Get-RemoteVssSnapshots -ServerName $serverFilter -Volume $volumeFilter
            }

            if ($result.Success) {
                $snapshots = @($result.Data | ForEach-Object {
                    $isTracked = if ($script:Config) {
                        Test-SnapshotRegistered -Config $script:Config -ShadowId $_.ShadowId
                    } else { $false }
                    [PSCustomObject]@{
                        ShadowId     = $_.ShadowId
                        SourceVolume = $_.SourceVolume
                        CreatedAt    = $_.CreatedAt
                        ServerName   = $_.ServerName
                        ShadowPath   = $_.ShadowPath
                        Status       = if ($isTracked) { "Tracked" } else { "EXTERNAL" }
                    }
                })
            }
            else {
                Write-RobocurseLog -Message "Failed to load remote snapshots: $($result.ErrorMessage)" -Level 'Warning' -Component 'GUI'
            }
        }

        # Update grid
        $grid.ItemsSource = $snapshots
        $script:Controls['btnDeleteSnapshot'].IsEnabled = $false

        # Log summary of tracked vs untracked
        $trackedCount = @($snapshots | Where-Object { $_.Status -eq "Tracked" }).Count
        $externalCount = @($snapshots | Where-Object { $_.Status -eq "EXTERNAL" }).Count
        Write-RobocurseLog -Message "Loaded $($snapshots.Count) snapshot(s): $trackedCount tracked, $externalCount external" -Level 'Debug' -Component 'GUI'
    }
    catch {
        Write-RobocurseLog -Message "Error updating snapshot list: $($_.Exception.Message)" -Level 'Error' -Component 'GUI'
        $grid.ItemsSource = @()
    }
}

function Add-RemoteServerToFilter {
    <#
    .SYNOPSIS
        Adds a remote server to the server filter dropdown
    .PARAMETER ServerName
        The server name to add
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerName
    )

    $combo = $script:Controls['cmbSnapshotServer']

    # Check if already exists
    $existing = $combo.Items | Where-Object { $_.Content -eq $ServerName }
    if ($existing) {
        return
    }

    $item = [System.Windows.Controls.ComboBoxItem]::new()
    $item.Content = $ServerName
    $combo.Items.Add($item) | Out-Null

    Write-RobocurseLog -Message "Added server '$ServerName' to snapshot filter" -Level 'Debug' -Component 'GUI'
}

function Get-SelectedSnapshot {
    <#
    .SYNOPSIS
        Gets the currently selected snapshot from the DataGrid
    .OUTPUTS
        The selected snapshot object or $null
    #>
    [CmdletBinding()]
    param()

    return $script:Controls['dgSnapshots'].SelectedItem
}
