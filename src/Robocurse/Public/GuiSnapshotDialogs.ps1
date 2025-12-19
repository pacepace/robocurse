# Robocurse GUI Snapshot Dialogs
# Handles create/delete snapshot dialogs

function Show-CreateSnapshotDialog {
    <#
    .SYNOPSIS
        Shows the Create Snapshot dialog and returns the result
    .OUTPUTS
        PSCustomObject with: Success, Volume, ServerName, EnforceRetention, KeepCount
        or $null if cancelled
    #>
    [CmdletBinding()]
    param()

    try {
        # Load dialog XAML
        $xamlPath = Join-Path $PSScriptRoot "..\Resources\CreateSnapshotDialog.xaml"
        $xaml = Get-Content $xamlPath -Raw
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)

        # Get controls
        $cmbServer = $dialog.FindName('cmbDialogServer')
        $cmbVolume = $dialog.FindName('cmbDialogVolume')
        $chkRetention = $dialog.FindName('chkEnforceRetention')
        $txtRetention = $dialog.FindName('txtRetentionCount')
        $txtStatus = $dialog.FindName('txtDialogStatus')
        $btnCancel = $dialog.FindName('btnDialogCancel')
        $btnCreate = $dialog.FindName('btnDialogCreate')

        # Populate servers from main panel
        $mainServerCombo = $script:Controls['cmbSnapshotServer']
        foreach ($item in $mainServerCombo.Items) {
            $newItem = [System.Windows.Controls.ComboBoxItem]::new()
            $newItem.Content = $item.Content
            $cmbServer.Items.Add($newItem) | Out-Null
        }
        $cmbServer.SelectedIndex = 0

        # Populate volumes
        $volumes = Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } |
            Sort-Object DriveLetter
        foreach ($vol in $volumes) {
            $item = [System.Windows.Controls.ComboBoxItem]::new()
            $item.Content = $vol.DriveLetter
            $cmbVolume.Items.Add($item) | Out-Null
        }
        if ($cmbVolume.Items.Count -gt 0) {
            $cmbVolume.SelectedIndex = 0
        }

        # Result variable
        $script:DialogResult = $null

        # Button handlers
        $btnCancel.Add_Click({
            $dialog.DialogResult = $false
            $dialog.Close()
        })

        $btnCreate.Add_Click({
            # Validate
            if ($cmbVolume.SelectedItem -eq $null) {
                $txtStatus.Text = "Please select a volume"
                $txtStatus.Foreground = [System.Windows.Media.Brushes]::OrangeRed
                return
            }

            $keepCount = 0
            if ($chkRetention.IsChecked -and -not [int]::TryParse($txtRetention.Text, [ref]$keepCount)) {
                $txtStatus.Text = "Invalid retention count"
                $txtStatus.Foreground = [System.Windows.Media.Brushes]::OrangeRed
                return
            }

            $script:DialogResult = [PSCustomObject]@{
                Success = $true
                Volume = $cmbVolume.SelectedItem.Content
                ServerName = $cmbServer.SelectedItem.Content
                EnforceRetention = $chkRetention.IsChecked
                KeepCount = $keepCount
            }

            $dialog.DialogResult = $true
            $dialog.Close()
        })

        # Show dialog
        $dialog.Owner = $script:Window
        $result = $dialog.ShowDialog()

        if ($result -eq $true) {
            return $script:DialogResult
        }
        return $null
    }
    catch {
        Write-RobocurseLog -Message "Error showing create snapshot dialog: $($_.Exception.Message)" -Level 'Error' -Component 'GUI'
        return $null
    }
}

function Invoke-CreateSnapshotFromDialog {
    <#
    .SYNOPSIS
        Creates a snapshot based on dialog input
    .PARAMETER DialogResult
        The result from Show-CreateSnapshotDialog
    .OUTPUTS
        OperationResult
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$DialogResult
    )

    $volume = $DialogResult.Volume
    $serverName = $DialogResult.ServerName
    $isLocal = ($serverName -eq "Local")

    Write-RobocurseLog -Message "Creating snapshot: Volume=$volume, Server=$serverName" -Level 'Info' -Component 'GUI'

    try {
        # Enforce retention if requested
        if ($DialogResult.EnforceRetention) {
            Write-RobocurseLog -Message "Enforcing retention (keep $($DialogResult.KeepCount))" -Level 'Debug' -Component 'GUI'

            if ($isLocal) {
                $retResult = Invoke-VssRetentionPolicy -Volume $volume -KeepCount $DialogResult.KeepCount
            }
            else {
                $retResult = Invoke-RemoteVssRetentionPolicy -ServerName $serverName -Volume $volume -KeepCount $DialogResult.KeepCount
            }

            if (-not $retResult.Success) {
                Write-RobocurseLog -Message "Retention enforcement failed: $($retResult.ErrorMessage)" -Level 'Warning' -Component 'GUI'
                # Continue anyway - snapshot might still work
            }
        }

        # Create snapshot
        if ($isLocal) {
            $result = New-VssSnapshot -SourcePath "$volume\"
        }
        else {
            # For remote, we need to construct a UNC path
            # Use admin share format: \\server\D$
            $uncPath = "\\$serverName\$($volume -replace ':', '$')"
            $result = New-RemoteVssSnapshot -UncPath $uncPath
        }

        if ($result.Success) {
            Write-RobocurseLog -Message "Snapshot created: $($result.Data.ShadowId)" -Level 'Info' -Component 'GUI'
        }

        return $result
    }
    catch {
        Write-RobocurseLog -Message "Failed to create snapshot: $($_.Exception.Message)" -Level 'Error' -Component 'GUI'
        return New-OperationResult -Success $false -ErrorMessage $_.Exception.Message -ErrorRecord $_
    }
}

function Show-DeleteSnapshotConfirmation {
    <#
    .SYNOPSIS
        Shows confirmation dialog for snapshot deletion
    .PARAMETER Snapshot
        The snapshot object to delete
    .OUTPUTS
        $true if user confirmed, $false otherwise
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Snapshot
    )

    $volume = $Snapshot.SourceVolume
    $created = $Snapshot.CreatedAt.ToString('yyyy-MM-dd HH:mm')
    $server = $Snapshot.ServerName
    $shadowId = $Snapshot.ShadowId

    $message = @"
Are you sure you want to delete this snapshot?

Volume: $volume
Created: $created
Server: $server
Shadow ID: $shadowId

This action cannot be undone.
"@

    $result = [System.Windows.MessageBox]::Show(
        $message,
        "Confirm Delete Snapshot",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )

    return ($result -eq [System.Windows.MessageBoxResult]::Yes)
}

function Invoke-DeleteSelectedSnapshot {
    <#
    .SYNOPSIS
        Deletes the currently selected snapshot
    .OUTPUTS
        OperationResult
    #>
    [CmdletBinding()]
    param()

    $snapshot = Get-SelectedSnapshot
    if (-not $snapshot) {
        return New-OperationResult -Success $false -ErrorMessage "No snapshot selected"
    }

    # Confirm
    if (-not (Show-DeleteSnapshotConfirmation -Snapshot $snapshot)) {
        return New-OperationResult -Success $true -Data "Cancelled"
    }

    Write-RobocurseLog -Message "Deleting snapshot: $($snapshot.ShadowId)" -Level 'Info' -Component 'GUI'

    try {
        if ($snapshot.ServerName -eq "Local") {
            $result = Remove-VssSnapshot -ShadowId $snapshot.ShadowId
        }
        else {
            $result = Remove-RemoteVssSnapshot -ShadowId $snapshot.ShadowId -ServerName $snapshot.ServerName
        }

        if ($result.Success) {
            Write-RobocurseLog -Message "Snapshot deleted" -Level 'Info' -Component 'GUI'
        }
        else {
            Write-RobocurseLog -Message "Failed to delete snapshot: $($result.ErrorMessage)" -Level 'Error' -Component 'GUI'
        }

        return $result
    }
    catch {
        Write-RobocurseLog -Message "Error deleting snapshot: $($_.Exception.Message)" -Level 'Error' -Component 'GUI'
        return New-OperationResult -Success $false -ErrorMessage $_.Exception.Message -ErrorRecord $_
    }
}
