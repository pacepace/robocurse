# Robocurse GUI Validation
# Pre-flight validation UI for checking profile configuration before replication

function Test-ProfileValidation {
    <#
    .SYNOPSIS
        Runs pre-flight validation checks on a replication profile
    .DESCRIPTION
        Performs a series of validation checks to ensure the profile is ready for replication:
        1. Robocopy availability
        2. Source path accessibility
        3. Destination path existence or parent path exists
        4. Disk space on destination (if accessible)
        5. VSS support if UseVSS is enabled
        6. Chunk estimate to verify source can be profiled
    .PARAMETER Profile
        The sync profile to validate (PSCustomObject with Name, Source, Destination, UseVSS properties)
    .OUTPUTS
        Array of validation result objects with CheckName, Status, Message, Severity properties
    .EXAMPLE
        $results = Test-ProfileValidation -Profile $profile
        $results | Where-Object { $_.Status -eq 'Fail' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile
    )

    $results = @()

    Write-RobocurseLog "Starting validation for profile: $($Profile.Name)" -Level 'Info' -Component 'Validation'

    # Check 1: Robocopy available
    try {
        $robocopyCheck = Test-RobocopyAvailable
        if ($robocopyCheck.Success) {
            $results += [PSCustomObject]@{
                CheckName = "Robocopy Available"
                Status = "Pass"
                Message = "Robocopy.exe found at: $($robocopyCheck.Data)"
                Severity = "Success"
            }
        }
        else {
            $results += [PSCustomObject]@{
                CheckName = "Robocopy Available"
                Status = "Fail"
                Message = $robocopyCheck.ErrorMessage
                Severity = "Error"
            }
        }
    }
    catch {
        $results += [PSCustomObject]@{
            CheckName = "Robocopy Available"
            Status = "Fail"
            Message = "Error checking robocopy: $($_.Exception.Message)"
            Severity = "Error"
        }
    }

    # Check 2: Source path accessible
    try {
        if ([string]::IsNullOrWhiteSpace($Profile.Source)) {
            $results += [PSCustomObject]@{
                CheckName = "Source Path"
                Status = "Fail"
                Message = "Source path is empty or not configured"
                Severity = "Error"
            }
        }
        elseif (Test-Path -Path $Profile.Source -PathType Container) {
            $results += [PSCustomObject]@{
                CheckName = "Source Path"
                Status = "Pass"
                Message = "Source path is accessible: $($Profile.Source)"
                Severity = "Success"
            }
        }
        else {
            $results += [PSCustomObject]@{
                CheckName = "Source Path"
                Status = "Fail"
                Message = "Source path does not exist or is not accessible: $($Profile.Source)"
                Severity = "Error"
            }
        }
    }
    catch {
        $results += [PSCustomObject]@{
            CheckName = "Source Path"
            Status = "Fail"
            Message = "Error accessing source path: $($_.Exception.Message)"
            Severity = "Error"
        }
    }

    # Check 3: Destination path or parent exists
    try {
        if ([string]::IsNullOrWhiteSpace($Profile.Destination)) {
            $results += [PSCustomObject]@{
                CheckName = "Destination Path"
                Status = "Fail"
                Message = "Destination path is empty or not configured"
                Severity = "Error"
            }
        }
        elseif (Test-Path -Path $Profile.Destination -PathType Container) {
            $results += [PSCustomObject]@{
                CheckName = "Destination Path"
                Status = "Pass"
                Message = "Destination path exists: $($Profile.Destination)"
                Severity = "Success"
            }
        }
        else {
            # Check if parent directory exists (destination will be created)
            $parentPath = Split-Path -Path $Profile.Destination -Parent
            if ($parentPath -and (Test-Path -Path $parentPath -PathType Container)) {
                $results += [PSCustomObject]@{
                    CheckName = "Destination Path"
                    Status = "Warning"
                    Message = "Destination will be created at: $($Profile.Destination)"
                    Severity = "Warning"
                }
            }
            else {
                $results += [PSCustomObject]@{
                    CheckName = "Destination Path"
                    Status = "Fail"
                    Message = "Destination parent path does not exist: $parentPath"
                    Severity = "Error"
                }
            }
        }
    }
    catch {
        $results += [PSCustomObject]@{
            CheckName = "Destination Path"
            Status = "Fail"
            Message = "Error checking destination path: $($_.Exception.Message)"
            Severity = "Error"
        }
    }

    # Check 4: Disk space on destination (if accessible)
    try {
        $destPathToCheck = if (Test-Path -Path $Profile.Destination -PathType Container) {
            $Profile.Destination
        }
        else {
            $parentPath = Split-Path -Path $Profile.Destination -Parent
            if ($parentPath -and (Test-Path -Path $parentPath -PathType Container)) {
                $parentPath
            }
            else {
                $null
            }
        }

        if ($destPathToCheck) {
            $drive = Get-PSDrive -PSProvider FileSystem | Where-Object {
                $destPathToCheck.StartsWith($_.Root, [System.StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1

            if ($drive) {
                $freeSpaceGB = [math]::Round($drive.Free / 1GB, 2)
                if ($freeSpaceGB -lt 1) {
                    $results += [PSCustomObject]@{
                        CheckName = "Destination Disk Space"
                        Status = "Warning"
                        Message = "Low disk space on destination: ${freeSpaceGB} GB free"
                        Severity = "Warning"
                    }
                }
                else {
                    $results += [PSCustomObject]@{
                        CheckName = "Destination Disk Space"
                        Status = "Pass"
                        Message = "Destination has ${freeSpaceGB} GB free space"
                        Severity = "Success"
                    }
                }
            }
            else {
                $results += [PSCustomObject]@{
                    CheckName = "Destination Disk Space"
                    Status = "Info"
                    Message = "Unable to determine disk space for destination"
                    Severity = "Info"
                }
            }
        }
        else {
            $results += [PSCustomObject]@{
                CheckName = "Destination Disk Space"
                Status = "Info"
                Message = "Skipped - destination path not accessible"
                Severity = "Info"
            }
        }
    }
    catch {
        $results += [PSCustomObject]@{
            CheckName = "Destination Disk Space"
            Status = "Info"
            Message = "Unable to check disk space: $($_.Exception.Message)"
            Severity = "Info"
        }
    }

    # Check 5: VSS support if UseVSS is enabled
    if ($Profile.UseVSS) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($Profile.Source) -and (Test-Path -Path $Profile.Source)) {
                # Check if this is a UNC path (network share)
                $isUncPath = $Profile.Source -match '^\\\\[^\\]+\\[^\\]+'

                if ($isUncPath) {
                    # Use remote VSS check which provides detailed error messages
                    $remoteResult = Test-RemoteVssSupported -UncPath $Profile.Source
                    if ($remoteResult.Success) {
                        $results += [PSCustomObject]@{
                            CheckName = "VSS Support (Remote)"
                            Status = "Pass"
                            Message = "Remote VSS is supported on server '$($remoteResult.Data.ServerName)'"
                            Severity = "Success"
                        }
                    }
                    else {
                        $results += [PSCustomObject]@{
                            CheckName = "VSS Support (Remote)"
                            Status = "Fail"
                            Message = $remoteResult.ErrorMessage
                            Severity = "Error"
                        }
                    }
                }
                else {
                    # Local path - use local VSS check
                    $vssSupported = Test-VssSupported -Path $Profile.Source
                    if ($vssSupported) {
                        $results += [PSCustomObject]@{
                            CheckName = "VSS Support"
                            Status = "Pass"
                            Message = "Volume Shadow Copy is supported for source path"
                            Severity = "Success"
                        }
                    }
                    else {
                        $results += [PSCustomObject]@{
                            CheckName = "VSS Support"
                            Status = "Fail"
                            Message = "VSS is not supported for this local path"
                            Severity = "Error"
                        }
                    }
                }
            }
            else {
                $results += [PSCustomObject]@{
                    CheckName = "VSS Support"
                    Status = "Warning"
                    Message = "Cannot verify VSS support - source path not accessible"
                    Severity = "Warning"
                }
            }
        }
        catch {
            $results += [PSCustomObject]@{
                CheckName = "VSS Support"
                Status = "Warning"
                Message = "Error checking VSS support: $($_.Exception.Message)"
                Severity = "Warning"
            }
        }
    }
    else {
        $results += [PSCustomObject]@{
            CheckName = "VSS Support"
            Status = "Info"
            Message = "VSS not enabled for this profile"
            Severity = "Info"
        }
    }

    # Check 6: Source can be profiled (chunk estimate)
    try {
        if (-not [string]::IsNullOrWhiteSpace($Profile.Source) -and (Test-Path -Path $Profile.Source)) {
            Write-RobocurseLog "Profiling source directory: $($Profile.Source)" -Level 'Debug' -Component 'Validation'
            $dirProfile = Get-DirectoryProfile -Path $Profile.Source -UseCache $true
            if ($dirProfile) {
                $sizeGB = [math]::Round($dirProfile.TotalSize / 1GB, 2)
                $fileCount = $dirProfile.FileCount
                $results += [PSCustomObject]@{
                    CheckName = "Source Profile"
                    Status = "Pass"
                    Message = "Source contains ${sizeGB} GB ($fileCount files)"
                    Severity = "Success"
                }
            }
            else {
                $results += [PSCustomObject]@{
                    CheckName = "Source Profile"
                    Status = "Warning"
                    Message = "Unable to profile source directory"
                    Severity = "Warning"
                }
            }
        }
        else {
            $results += [PSCustomObject]@{
                CheckName = "Source Profile"
                Status = "Info"
                Message = "Skipped - source path not accessible"
                Severity = "Info"
            }
        }
    }
    catch {
        $results += [PSCustomObject]@{
            CheckName = "Source Profile"
            Status = "Warning"
            Message = "Error profiling source: $($_.Exception.Message)"
            Severity = "Warning"
        }
    }

    Write-RobocurseLog "Validation complete for profile: $($Profile.Name)" -Level 'Info' -Component 'Validation'
    return $results
}

function Show-ValidationDialog {
    <#
    .SYNOPSIS
        Shows the validation results dialog
    .DESCRIPTION
        Displays a modal dialog with validation check results. Runs Test-ProfileValidation
        if results are not provided.
    .PARAMETER Profile
        The profile to validate (if Results not provided)
    .PARAMETER Results
        Pre-computed validation results to display
    .EXAMPLE
        Show-ValidationDialog -Profile $selectedProfile
    .EXAMPLE
        $results = Test-ProfileValidation -Profile $profile
        Show-ValidationDialog -Results $results -Profile $profile
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,

        [PSCustomObject[]]$Results
    )

    try {
        # Run validation if results not provided
        if (-not $Results) {
            $Results = Test-ProfileValidation -Profile $Profile
        }

        # Load XAML from resource file
        $xaml = Get-XamlResource -ResourceName 'ValidationDialog.xaml'
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()

        # Get controls
        $txtTitle = $dialog.FindName("txtTitle")
        $txtSubtitle = $dialog.FindName("txtSubtitle")
        $lstResults = $dialog.FindName("lstResults")
        $dialogBorder = $dialog.FindName("dialogBorder")
        $btnClose = $dialog.FindName("btnClose")

        # Set title
        $txtTitle.Text = "Validation: $($Profile.Name)"
        $txtSubtitle.Text = "Pre-flight checks for replication profile"

        # Determine overall status
        $hasFailed = ($Results | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0
        $hasWarnings = ($Results | Where-Object { $_.Status -eq 'Warning' }).Count -gt 0

        # Update border color based on overall status
        if ($hasFailed) {
            $dialogBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF6B6B")
        }
        elseif ($hasWarnings) {
            $dialogBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FFB340")
        }
        else {
            $dialogBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#34C759")
        }

        # Populate results list
        $lstResults.ItemsSource = $Results

        # Close button handler
        $btnClose.Add_Click({
            $dialog.Close()
        })

        # Allow dragging the window
        $dialog.Add_MouseLeftButtonDown({
            param($sender, $e)
            if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
                $dialog.DragMove()
            }
        })

        # Escape key to close
        $dialog.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
                $dialog.Close()
            }
        })

        # Set owner to main window for proper modal behavior
        if ($script:Window) {
            $dialog.Owner = $script:Window
        }

        $dialog.ShowDialog() | Out-Null
    }
    catch {
        Write-GuiLog "Error showing validation dialog: $($_.Exception.Message)"
        # Fallback to simple message
        $failCount = ($Results | Where-Object { $_.Status -eq 'Fail' }).Count
        $passCount = ($Results | Where-Object { $_.Status -eq 'Pass' }).Count
        $warnCount = ($Results | Where-Object { $_.Status -eq 'Warning' }).Count

        [System.Windows.MessageBox]::Show(
            "Validation Results:`n`nPassed: $passCount`nWarnings: $warnCount`nFailed: $failCount",
            "Validation: $($Profile.Name)",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    }
}
