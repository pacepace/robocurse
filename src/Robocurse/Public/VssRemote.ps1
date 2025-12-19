# Robocurse VSS Remote Functions
# Remote VSS operations via UNC paths and CIM sessions
# Requires VssCore.ps1 to be loaded first (handled by Robocurse.psm1)

function Get-UncPathComponents {
    <#
    .SYNOPSIS
        Parses a UNC path into its components
    .DESCRIPTION
        Extracts the server name, share name, and relative path from a UNC path.
        Also attempts to determine the local path on the server by querying the share.
    .PARAMETER UncPath
        The UNC path to parse (e.g., \\server\share\folder\file.txt)
    .OUTPUTS
        PSCustomObject with ServerName, ShareName, RelativePath, and optionally LocalPath
    .EXAMPLE
        Get-UncPathComponents -UncPath "\\FileServer01\Data\Projects\Report.docx"
        Returns: @{ ServerName = "FileServer01"; ShareName = "Data"; RelativePath = "Projects\Report.docx"; LocalPath = $null }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^\\\\[^\\]+\\[^\\]+')]
        [string]$UncPath
    )

    # Parse UNC path: \\server\share\path\to\file
    if ($UncPath -match '^\\\\([^\\]+)\\([^\\]+)(?:\\(.*))?$') {
        $serverName = $Matches[1]
        $shareName = $Matches[2]
        $relativePath = if ($Matches[3]) { $Matches[3] } else { "" }

        return [PSCustomObject]@{
            ServerName   = $serverName
            ShareName    = $shareName
            RelativePath = $relativePath
            UncPath      = $UncPath
        }
    }

    Write-RobocurseLog -Message "Failed to parse UNC path: $UncPath" -Level 'Error' -Component 'VSS'
    return $null
}


function Get-RemoteShareLocalPath {
    <#
    .SYNOPSIS
        Gets the local path on a remote server for a given share
    .DESCRIPTION
        Uses CIM to query the Win32_Share class on the remote server to find
        the local path that the share points to.
    .PARAMETER ServerName
        The remote server name
    .PARAMETER ShareName
        The share name to look up
    .PARAMETER CimSession
        Optional existing CIM session to use
    .OUTPUTS
        The local path on the server, or $null if not found
    .EXAMPLE
        Get-RemoteShareLocalPath -ServerName "FileServer01" -ShareName "Data"
        Returns: "D:\SharedData"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerName,

        [Parameter(Mandatory)]
        [string]$ShareName,

        [Microsoft.Management.Infrastructure.CimSession]$CimSession
    )

    try {
        $ownSession = $false
        if (-not $CimSession) {
            $CimSession = New-CimSession -ComputerName $ServerName -ErrorAction Stop
            $ownSession = $true
        }

        try {
            $share = Get-CimInstance -CimSession $CimSession -ClassName Win32_Share |
                Where-Object { $_.Name -eq $ShareName }

            if ($share) {
                Write-RobocurseLog -Message "Share '$ShareName' on '$ServerName' maps to local path: $($share.Path)" -Level 'Debug' -Component 'VSS'
                return $share.Path
            }

            Write-RobocurseLog -Message "Share '$ShareName' not found on server '$ServerName'" -Level 'Warning' -Component 'VSS'
            return $null
        }
        finally {
            if ($ownSession -and $CimSession) {
                Remove-CimSession -CimSession $CimSession -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-RobocurseLog -Message "Failed to get share info from '$ServerName': $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return $null
    }
}


function Test-RemoteVssSupported {
    <#
    .SYNOPSIS
        Tests if remote VSS operations are supported for a given UNC path
    .DESCRIPTION
        Checks if we can establish a CIM session to the remote server and
        if the Win32_ShadowCopy class is available.
    .PARAMETER UncPath
        The UNC path to test
    .OUTPUTS
        OperationResult - Success=$true if remote VSS is supported
    .EXAMPLE
        $result = Test-RemoteVssSupported -UncPath "\\FileServer01\Data"
        if ($result.Success) { "Remote VSS available" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UncPath
    )

    $components = Get-UncPathComponents -UncPath $UncPath
    if (-not $components) {
        return New-OperationResult -Success $false -ErrorMessage "Invalid UNC path: $UncPath"
    }

    $serverName = $components.ServerName

    try {
        # Test CIM connectivity
        $cimSession = New-CimSession -ComputerName $serverName -ErrorAction Stop

        try {
            # Check if Win32_ShadowCopy is available
            $shadowClass = Get-CimClass -CimSession $cimSession -ClassName Win32_ShadowCopy -ErrorAction Stop

            if ($shadowClass) {
                Write-RobocurseLog -Message "Remote VSS supported on server '$serverName'" -Level 'Debug' -Component 'VSS'
                return New-OperationResult -Success $true -Data @{
                    ServerName = $serverName
                    ShareName  = $components.ShareName
                }
            }

            return New-OperationResult -Success $false -ErrorMessage "Win32_ShadowCopy class not available on '$serverName'. Ensure VSS service is not disabled on the remote server."
        }
        finally {
            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
        $guidance = ""

        # Provide actionable guidance based on common error patterns
        if ($errorMsg -match 'Access is denied|Access denied') {
            $guidance = " Ensure you have administrative rights on the remote server."
        }
        elseif ($errorMsg -match 'RPC server|unavailable|endpoint mapper') {
            $guidance = " Ensure WinRM service is running on '$serverName'. Run 'Enable-PSRemoting -Force' on the remote server."
        }
        elseif ($errorMsg -match 'network path|not found|host.*unknown') {
            $guidance = " Verify the server name is correct and network connectivity is available."
        }
        elseif ($errorMsg -match 'firewall|blocked') {
            $guidance = " Check firewall rules on '$serverName' - WinRM (TCP 5985/5986) and WMI/DCOM must be allowed."
        }

        $fullError = "Cannot connect to remote server '$serverName': $errorMsg$guidance"
        Write-RobocurseLog -Message $fullError -Level 'Warning' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage $fullError
    }
}


function New-RemoteVssSnapshot {
    <#
    .SYNOPSIS
        Creates a VSS snapshot on a remote server
    .DESCRIPTION
        Uses a remote CIM session to create a VSS shadow copy on the file server
        that hosts the specified UNC path.
    .PARAMETER UncPath
        The UNC path to the share/folder to snapshot
    .PARAMETER RetryCount
        Number of retry attempts for transient failures (default: 3)
    .PARAMETER RetryDelaySeconds
        Delay between retry attempts (default: 5)
    .OUTPUTS
        OperationResult with Data containing:
        - ShadowId: The shadow copy ID
        - ShadowPath: The shadow device path (local to the server)
        - ServerName: The remote server name
        - ShareName: The share name
        - ShareLocalPath: The local path on the server the share points to
        - SourceVolume: The volume on the server
        - CreatedAt: Timestamp
    .EXAMPLE
        $result = New-RemoteVssSnapshot -UncPath "\\FileServer01\Data\Projects"
        if ($result.Success) { $snapshot = $result.Data }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^\\\\[^\\]+\\[^\\]+')]
        [string]$UncPath,

        [ValidateRange(0, 10)]
        [int]$RetryCount = 3,

        [ValidateRange(1, 60)]
        [int]$RetryDelaySeconds = 5
    )

    $components = Get-UncPathComponents -UncPath $UncPath
    if (-not $components) {
        return New-OperationResult -Success $false -ErrorMessage "Invalid UNC path: $UncPath"
    }

    $serverName = $components.ServerName
    $shareName = $components.ShareName

    Write-RobocurseLog -Message "Creating remote VSS snapshot on '$serverName' for share '$shareName'" -Level 'Info' -Component 'VSS'

    $cimSession = $null
    try {
        # Establish CIM session
        $cimSession = New-CimSession -ComputerName $serverName -ErrorAction Stop
        Write-RobocurseLog -Message "CIM session established to '$serverName'" -Level 'Debug' -Component 'VSS'

        # Get the local path for the share
        $shareLocalPath = Get-RemoteShareLocalPath -ServerName $serverName -ShareName $shareName -CimSession $cimSession
        if (-not $shareLocalPath) {
            return New-OperationResult -Success $false -ErrorMessage "Cannot determine local path for share '$shareName' on server '$serverName'"
        }

        # Determine volume from the share's local path
        if ($shareLocalPath -match '^([A-Za-z]:)') {
            $volume = $Matches[1].ToUpper()
        }
        else {
            return New-OperationResult -Success $false -ErrorMessage "Cannot determine volume from share local path: $shareLocalPath"
        }

        # Retry loop
        $attempt = 0
        $lastError = $null

        while ($attempt -le $RetryCount) {
            $attempt++
            $isRetry = $attempt -gt 1

            if ($isRetry) {
                Write-RobocurseLog -Message "Remote VSS snapshot retry $($attempt - 1)/$RetryCount after ${RetryDelaySeconds}s delay" `
                    -Level 'Warning' -Component 'VSS'
                Start-Sleep -Seconds $RetryDelaySeconds
            }

            try {
                # Create shadow copy on remote server
                $result = Invoke-CimMethod -CimSession $cimSession -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{
                    Volume  = "$volume\"
                    Context = "ClientAccessible"
                }

                if ($result.ReturnValue -ne 0) {
                    $errorCode = "0x{0:X8}" -f $result.ReturnValue
                    $lastError = "Failed to create remote shadow copy: Error $errorCode"

                    # Check if retryable using shared function (VssCore.ps1)
                    if (Test-VssErrorRetryable -ErrorMessage $lastError -HResult $result.ReturnValue) {
                        continue  # Retry
                    }
                    return New-OperationResult -Success $false -ErrorMessage $lastError
                }

                # Get shadow copy details
                $shadowId = $result.ShadowID
                Write-RobocurseLog -Message "Remote VSS snapshot created with ID: $shadowId" -Level 'Debug' -Component 'VSS'

                $shadow = Get-CimInstance -CimSession $cimSession -ClassName Win32_ShadowCopy |
                    Where-Object { $_.ID -eq $shadowId }

                if (-not $shadow) {
                    return New-OperationResult -Success $false -ErrorMessage "Remote shadow copy created but could not retrieve details for ID: $shadowId"
                }

                $snapshotInfo = [PSCustomObject]@{
                    ShadowId       = $shadowId
                    ShadowPath     = $shadow.DeviceObject
                    ServerName     = $serverName
                    ShareName      = $shareName
                    ShareLocalPath = $shareLocalPath
                    SourceVolume   = $volume
                    CreatedAt      = [datetime]::Now
                    IsRemote       = $true
                }

                Write-RobocurseLog -Message "Remote VSS snapshot ready on '$serverName'. Shadow path: $($snapshotInfo.ShadowPath)" -Level 'Info' -Component 'VSS'

                # Track for orphan cleanup
                Add-VssToTracking -SnapshotInfo ([PSCustomObject]@{
                    ShadowId     = $shadowId
                    SourceVolume = "$serverName`:$volume"  # Include server name for remote tracking
                    CreatedAt    = $snapshotInfo.CreatedAt
                    ServerName   = $serverName
                    IsRemote     = $true
                })

                return New-OperationResult -Success $true -Data $snapshotInfo
            }
            catch {
                $lastError = $_.Exception.Message
                Write-RobocurseLog -Message "Remote VSS attempt $attempt failed: $lastError" -Level 'Warning' -Component 'VSS'
            }
        }

        return New-OperationResult -Success $false -ErrorMessage "Remote VSS snapshot failed after $RetryCount retries: $lastError"
    }
    catch {
        Write-RobocurseLog -Message "Failed to create remote VSS snapshot: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "Failed to create remote VSS snapshot: $($_.Exception.Message)" -ErrorRecord $_
    }
    finally {
        if ($cimSession) {
            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
        }
    }
}


function Remove-RemoteVssSnapshot {
    <#
    .SYNOPSIS
        Removes a VSS snapshot from a remote server
    .DESCRIPTION
        Uses a remote CIM session to delete a shadow copy on the remote server.
    .PARAMETER ShadowId
        The shadow copy ID to remove
    .PARAMETER ServerName
        The remote server where the snapshot exists
    .OUTPUTS
        OperationResult
    .EXAMPLE
        Remove-RemoteVssSnapshot -ShadowId "{guid}" -ServerName "FileServer01"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ShadowId,

        [Parameter(Mandatory)]
        [string]$ServerName
    )

    $cimSession = $null
    try {
        Write-RobocurseLog -Message "Removing remote VSS snapshot '$ShadowId' from '$ServerName'" -Level 'Debug' -Component 'VSS'

        $cimSession = New-CimSession -ComputerName $ServerName -ErrorAction Stop

        $shadow = Get-CimInstance -CimSession $cimSession -ClassName Win32_ShadowCopy |
            Where-Object { $_.ID -eq $ShadowId }

        if ($shadow) {
            if ($PSCmdlet.ShouldProcess("$ShadowId on $ServerName", "Remove Remote VSS Snapshot")) {
                Remove-CimInstance -CimSession $cimSession -InputObject $shadow
                Write-RobocurseLog -Message "Deleted remote VSS snapshot: $ShadowId" -Level 'Info' -Component 'VSS'
                Remove-VssFromTracking -ShadowId $ShadowId
                return New-OperationResult -Success $true -Data $ShadowId
            }
            else {
                return New-OperationResult -Success $true -Data "WhatIf: Would remove $ShadowId"
            }
        }
        else {
            Write-RobocurseLog -Message "Remote VSS snapshot not found: $ShadowId on $ServerName" -Level 'Warning' -Component 'VSS'
            Remove-VssFromTracking -ShadowId $ShadowId
            return New-OperationResult -Success $true -Data $ShadowId
        }
    }
    catch {
        Write-RobocurseLog -Message "Error removing remote VSS snapshot: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "Failed to remove remote VSS snapshot: $($_.Exception.Message)" -ErrorRecord $_
    }
    finally {
        if ($cimSession) {
            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
        }
    }
}


function New-RemoteVssJunction {
    <#
    .SYNOPSIS
        Creates a junction on a remote server pointing to a VSS shadow path
    .DESCRIPTION
        Uses PowerShell remoting to create a junction on the remote server.
        The junction is created inside the share's directory so it's accessible
        via UNC path from the client.
    .PARAMETER VssSnapshot
        The remote VSS snapshot object from New-RemoteVssSnapshot
    .PARAMETER JunctionName
        Optional name for the junction. Defaults to a GUID-based name.
    .OUTPUTS
        OperationResult with Data containing:
        - JunctionLocalPath: The local path to the junction on the server
        - JunctionUncPath: The UNC path to access the junction from the client
    .NOTES
        The junction is created inside the share directory (e.g., \\server\share\.robocurse-vss-xxx)
        so that clients can access it via the existing share.
    .EXAMPLE
        $junction = New-RemoteVssJunction -VssSnapshot $snapshot
        robocopy $junction.Data.JunctionUncPath $destination /MIR
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$VssSnapshot,

        [string]$JunctionName
    )

    if (-not $VssSnapshot.IsRemote) {
        return New-OperationResult -Success $false -ErrorMessage "VssSnapshot is not a remote snapshot"
    }

    $serverName = $VssSnapshot.ServerName
    $shareName = $VssSnapshot.ShareName
    $shareLocalPath = $VssSnapshot.ShareLocalPath
    $shadowPath = $VssSnapshot.ShadowPath

    # Generate junction name if not provided
    # Use 16-char GUID prefix for better collision resistance in high-concurrency scenarios
    if (-not $JunctionName) {
        $JunctionName = ".robocurse-vss-$([Guid]::NewGuid().ToString('N').Substring(0,16))"
    }

    # Junction will be created inside the share directory
    $junctionLocalPath = Join-Path $shareLocalPath $JunctionName
    $junctionUncPath = "\\$serverName\$shareName\$JunctionName"

    # Calculate the VSS path for the share's local path
    # Shadow path is like: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy5
    # Share local path is like: D:\SharedData
    # We need: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy5\SharedData

    $volume = $VssSnapshot.SourceVolume
    $relativePath = $shareLocalPath.Substring($volume.Length).TrimStart('\')
    $vssTargetPath = if ($relativePath) {
        "$shadowPath\$relativePath"
    } else {
        $shadowPath
    }

    Write-RobocurseLog -Message "Creating remote junction on '$serverName': '$junctionLocalPath' -> '$vssTargetPath'" -Level 'Debug' -Component 'VSS'

    try {
        # Use Invoke-Command with timeout to create the junction on the remote server
        # Timeout prevents indefinite hangs on slow or unreachable servers
        $sessionOption = New-PSSessionOption -OperationTimeout $script:RemoteOperationTimeoutMs -OpenTimeout $script:RemoteOperationTimeoutMs
        $result = Invoke-Command -ComputerName $serverName -SessionOption $sessionOption -ScriptBlock {
            param($JunctionPath, $TargetPath)

            # Check if junction already exists
            if (Test-Path $JunctionPath) {
                return @{ Success = $false; ErrorMessage = "Junction path already exists: $JunctionPath" }
            }

            # Create junction using cmd mklink /J
            $output = cmd /c "mklink /J `"$JunctionPath`" `"$TargetPath`"" 2>&1

            if ($LASTEXITCODE -ne 0) {
                return @{ Success = $false; ErrorMessage = "mklink failed: $output" }
            }

            # Verify
            if (-not (Test-Path $JunctionPath)) {
                return @{ Success = $false; ErrorMessage = "Junction created but not accessible" }
            }

            return @{ Success = $true; JunctionPath = $JunctionPath }
        } -ArgumentList $junctionLocalPath, $vssTargetPath -ErrorAction Stop

        if (-not $result.Success) {
            return New-OperationResult -Success $false -ErrorMessage "Failed to create remote junction: $($result.ErrorMessage)"
        }

        # Verify we can access it via UNC
        if (-not (Test-Path $junctionUncPath)) {
            Write-RobocurseLog -Message "Remote junction created but UNC path not accessible: $junctionUncPath" -Level 'Warning' -Component 'VSS'
        }

        Write-RobocurseLog -Message "Created remote VSS junction: $junctionUncPath" -Level 'Info' -Component 'VSS'

        return New-OperationResult -Success $true -Data ([PSCustomObject]@{
            JunctionLocalPath = $junctionLocalPath
            JunctionUncPath   = $junctionUncPath
            ServerName        = $serverName
        })
    }
    catch {
        Write-RobocurseLog -Message "Error creating remote junction: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "Failed to create remote junction: $($_.Exception.Message)" -ErrorRecord $_
    }
}


function Remove-RemoteVssJunction {
    <#
    .SYNOPSIS
        Removes a junction from a remote server
    .DESCRIPTION
        Uses PowerShell remoting to safely remove a junction on the remote server
        without following it or deleting the target contents.
    .PARAMETER JunctionLocalPath
        The local path to the junction on the remote server
    .PARAMETER ServerName
        The remote server name
    .OUTPUTS
        OperationResult
    .EXAMPLE
        Remove-RemoteVssJunction -JunctionLocalPath "D:\Share\.robocurse-vss-abc123" -ServerName "FileServer01"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$JunctionLocalPath,

        [Parameter(Mandatory)]
        [string]$ServerName
    )

    Write-RobocurseLog -Message "Removing remote junction '$JunctionLocalPath' from '$ServerName'" -Level 'Debug' -Component 'VSS'

    try {
        # Use timeout to prevent indefinite hangs on slow or unreachable servers
        $sessionOption = New-PSSessionOption -OperationTimeout $script:RemoteOperationTimeoutMs -OpenTimeout $script:RemoteOperationTimeoutMs
        $result = Invoke-Command -ComputerName $ServerName -SessionOption $sessionOption -ScriptBlock {
            param($JunctionPath)

            if (-not (Test-Path $JunctionPath)) {
                return @{ Success = $true; Message = "Junction already removed" }
            }

            # Use rmdir to remove junction without following it
            $output = cmd /c "rmdir `"$JunctionPath`"" 2>&1

            if ($LASTEXITCODE -ne 0) {
                # Try .NET method
                try {
                    [System.IO.Directory]::Delete($JunctionPath, $false)
                }
                catch {
                    return @{ Success = $false; ErrorMessage = "rmdir failed: $output" }
                }
            }

            if (Test-Path $JunctionPath) {
                return @{ Success = $false; ErrorMessage = "Junction still exists after removal" }
            }

            return @{ Success = $true }
        } -ArgumentList $JunctionLocalPath -ErrorAction Stop

        if (-not $result.Success) {
            return New-OperationResult -Success $false -ErrorMessage "Failed to remove remote junction: $($result.ErrorMessage)"
        }

        Write-RobocurseLog -Message "Removed remote VSS junction from '$ServerName'" -Level 'Info' -Component 'VSS'
        return New-OperationResult -Success $true -Data $JunctionLocalPath
    }
    catch {
        Write-RobocurseLog -Message "Error removing remote junction: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage "Failed to remove remote junction: $($_.Exception.Message)" -ErrorRecord $_
    }
}


function Get-RemoteVssPath {
    <#
    .SYNOPSIS
        Converts a UNC path to its VSS shadow copy equivalent UNC path
    .DESCRIPTION
        Given a UNC path and a remote VSS snapshot, returns the UNC path through
        the VSS junction that provides access to the point-in-time snapshot.
    .PARAMETER OriginalUncPath
        The original UNC path (e.g., \\server\share\folder)
    .PARAMETER VssSnapshot
        The remote VSS snapshot object
    .PARAMETER JunctionInfo
        The junction info from New-RemoteVssJunction
    .OUTPUTS
        The UNC path through the junction to access the VSS copy
    .EXAMPLE
        $vssUncPath = Get-RemoteVssPath -OriginalUncPath "\\server\share\folder" -VssSnapshot $snap -JunctionInfo $junction
        # Returns: \\server\share\.robocurse-vss-xxx\folder
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OriginalUncPath,

        [Parameter(Mandatory)]
        [PSCustomObject]$VssSnapshot,

        [Parameter(Mandatory)]
        [PSCustomObject]$JunctionInfo
    )

    $components = Get-UncPathComponents -UncPath $OriginalUncPath
    if (-not $components) {
        Write-RobocurseLog -Message "Invalid UNC path: $OriginalUncPath" -Level 'Error' -Component 'VSS'
        return $null
    }

    # The junction provides access to the share's root in VSS
    # So we append the relative path from the original UNC
    $junctionUncPath = $JunctionInfo.JunctionUncPath
    $relativePath = $components.RelativePath

    if ($relativePath) {
        $vssUncPath = "$junctionUncPath\$relativePath"
    }
    else {
        $vssUncPath = $junctionUncPath
    }

    Write-RobocurseLog -Message "Translated remote path: $OriginalUncPath -> $vssUncPath" -Level 'Debug' -Component 'VSS'
    return $vssUncPath
}


function Invoke-WithRemoteVssJunction {
    <#
    .SYNOPSIS
        Executes a scriptblock with remote VSS snapshot accessible via UNC junction
    .DESCRIPTION
        Creates a VSS snapshot on the remote server, creates a junction accessible
        via UNC, executes the provided scriptblock, and ensures cleanup of both
        junction and snapshot even if the scriptblock throws.

        This enables robocopy to copy from a point-in-time snapshot of a remote
        file share.
    .PARAMETER UncPath
        The UNC path to the source (e.g., \\server\share\folder)
    .PARAMETER ScriptBlock
        Code to execute. Receives $SourcePath parameter with the UNC path to the
        VSS junction that provides access to the snapshot.
    .OUTPUTS
        OperationResult with Data containing the scriptblock result
    .NOTES
        Cleanup order: junction first, then snapshot.
        Requires:
        - Admin rights on the remote server
        - PowerShell remoting enabled on the remote server
        - CIM access to the remote server
    .EXAMPLE
        $result = Invoke-WithRemoteVssJunction -UncPath "\\FileServer01\Data\Projects" -ScriptBlock {
            param($SourcePath)
            robocopy $SourcePath "D:\Backup\Projects" /MIR /LOG:backup.log
            return $LASTEXITCODE
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^\\\\[^\\]+\\[^\\]+')]
        [string]$UncPath,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $snapshot = $null
    $junctionInfo = $null

    try {
        # Step 1: Create remote VSS snapshot
        Write-RobocurseLog -Message "Creating remote VSS snapshot for '$UncPath'" -Level 'Info' -Component 'VSS'
        $snapshotResult = New-RemoteVssSnapshot -UncPath $UncPath

        if (-not $snapshotResult.Success) {
            return New-OperationResult -Success $false `
                -ErrorMessage "Failed to create remote VSS snapshot: $($snapshotResult.ErrorMessage)" `
                -ErrorRecord $snapshotResult.ErrorRecord
        }
        $snapshot = $snapshotResult.Data

        # Step 2: Create junction on remote server
        $junctionResult = New-RemoteVssJunction -VssSnapshot $snapshot
        if (-not $junctionResult.Success) {
            return New-OperationResult -Success $false `
                -ErrorMessage "Failed to create remote VSS junction: $($junctionResult.ErrorMessage)" `
                -ErrorRecord $junctionResult.ErrorRecord
        }
        $junctionInfo = $junctionResult.Data

        # Step 3: Get the UNC path through the junction
        $vssUncPath = Get-RemoteVssPath -OriginalUncPath $UncPath -VssSnapshot $snapshot -JunctionInfo $junctionInfo
        Write-RobocurseLog -Message "Remote VSS accessible at: $vssUncPath" -Level 'Info' -Component 'VSS'

        # Step 4: Execute scriptblock with the VSS UNC path
        $scriptResult = & $ScriptBlock -SourcePath $vssUncPath

        return New-OperationResult -Success $true -Data $scriptResult
    }
    catch {
        Write-RobocurseLog -Message "Error during remote VSS operation: $($_.Exception.Message)" -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false `
            -ErrorMessage "Remote VSS operation failed: $($_.Exception.Message)" `
            -ErrorRecord $_
    }
    finally {
        # Cleanup in correct order: junction first, then snapshot

        # Step 5a: Remove junction
        if ($junctionInfo) {
            Write-RobocurseLog -Message "Cleaning up remote VSS junction" -Level 'Info' -Component 'VSS'
            $removeJunctionResult = Remove-RemoteVssJunction `
                -JunctionLocalPath $junctionInfo.JunctionLocalPath `
                -ServerName $junctionInfo.ServerName
            if (-not $removeJunctionResult.Success) {
                Write-RobocurseLog -Message "Failed to cleanup remote junction: $($removeJunctionResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
            }
        }

        # Step 5b: Remove snapshot
        if ($snapshot) {
            Write-RobocurseLog -Message "Cleaning up remote VSS snapshot" -Level 'Info' -Component 'VSS'
            $removeSnapshotResult = Remove-RemoteVssSnapshot `
                -ShadowId $snapshot.ShadowId `
                -ServerName $snapshot.ServerName
            if (-not $removeSnapshotResult.Success) {
                Write-RobocurseLog -Message "Failed to cleanup remote snapshot: $($removeSnapshotResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
            }
        }
    }
}


function Get-RemoteVssSnapshots {
    <#
    .SYNOPSIS
        Lists VSS snapshots on a remote server
    .DESCRIPTION
        Uses a CIM session to query VSS shadow copies on a remote server.
        Can filter by volume or return all snapshots on the server.
    .PARAMETER ServerName
        The remote server name to query
    .PARAMETER Volume
        Optional volume to filter (e.g., "D:"). If not specified, returns all.
    .OUTPUTS
        OperationResult with Data = array of snapshot objects
    .EXAMPLE
        $result = Get-RemoteVssSnapshots -ServerName "FileServer01" -Volume "D:"
        $result.Data | Format-Table ShadowId, CreatedAt, SourceVolume
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerName,

        [ValidatePattern('^[A-Za-z]:$')]
        [string]$Volume
    )

    Write-RobocurseLog -Message "Listing VSS snapshots on '$ServerName'$(if ($Volume) { " for volume $Volume" })" -Level 'Debug' -Component 'VSS'

    $cimSession = $null
    try {
        $cimSession = New-CimSession -ComputerName $ServerName -ErrorAction Stop

        $snapshots = Get-CimInstance -CimSession $cimSession -ClassName Win32_ShadowCopy -ErrorAction Stop

        if (-not $snapshots) {
            return New-OperationResult -Success $true -Data @()
        }

        # Get volume mapping for filtering
        $volumeMap = @{}
        $volumes = Get-CimInstance -CimSession $cimSession -ClassName Win32_Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter }
        foreach ($vol in $volumes) {
            $volumeMap[$vol.DeviceID] = $vol.DriveLetter
        }

        # Convert and filter
        $result = @($snapshots | ForEach-Object {
            $snapshotVolume = $volumeMap[$_.VolumeName]

            # Skip if filtering by volume and doesn't match
            if ($Volume -and $snapshotVolume -ne $Volume.ToUpper()) {
                return
            }

            [PSCustomObject]@{
                ShadowId     = $_.ID
                ShadowPath   = $_.DeviceObject
                SourceVolume = $snapshotVolume
                CreatedAt    = $_.InstallDate
                ServerName   = $ServerName
                IsRemote     = $true
            }
        } | Where-Object { $_ })

        # Sort by creation time (newest first)
        $result = @($result | Sort-Object CreatedAt -Descending)

        Write-RobocurseLog -Message "Found $($result.Count) VSS snapshot(s) on '$ServerName'" -Level 'Debug' -Component 'VSS'
        return New-OperationResult -Success $true -Data $result
    }
    catch {
        $errorMsg = $_.Exception.Message
        $guidance = Get-RemoteVssErrorGuidance -ErrorMessage $errorMsg -ServerName $ServerName
        $fullError = "Failed to list snapshots on '$ServerName': $errorMsg$guidance"

        Write-RobocurseLog -Message $fullError -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage $fullError -ErrorRecord $_
    }
    finally {
        if ($cimSession) {
            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
        }
    }
}

function Get-RemoteVssErrorGuidance {
    <#
    .SYNOPSIS
        Returns actionable guidance for remote VSS errors
    #>
    [CmdletBinding()]
    param(
        [string]$ErrorMessage,
        [string]$ServerName
    )

    if ($ErrorMessage -match 'Access is denied|Access denied') {
        return " Ensure you have administrative rights on '$ServerName'."
    }
    elseif ($ErrorMessage -match 'RPC server|unavailable|endpoint mapper') {
        return " Ensure WinRM service is running on '$ServerName'. Run 'Enable-PSRemoting -Force' on the remote server."
    }
    elseif ($ErrorMessage -match 'network path|not found|host.*unknown') {
        return " Verify the server name is correct and network connectivity is available."
    }
    elseif ($ErrorMessage -match 'firewall|blocked') {
        return " Check firewall rules on '$ServerName' - WinRM (TCP 5985/5986) and WMI/DCOM must be allowed."
    }
    return ""
}

function Invoke-RemoteVssRetentionPolicy {
    <#
    .SYNOPSIS
        Enforces VSS snapshot retention on a remote server
    .DESCRIPTION
        For a specified volume on a remote server, keeps the newest N snapshots
        and removes the rest. Uses CIM sessions for remote operations.
    .PARAMETER ServerName
        The remote server name
    .PARAMETER Volume
        Volume to apply retention to (e.g., "D:")
    .PARAMETER KeepCount
        Number of snapshots to keep (default: 3)
    .OUTPUTS
        OperationResult with Data containing DeletedCount, KeptCount, Errors
    .EXAMPLE
        $result = Invoke-RemoteVssRetentionPolicy -ServerName "FileServer01" -Volume "D:" -KeepCount 5
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ServerName,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]:$')]
        [string]$Volume,

        [ValidateRange(0, 100)]
        [int]$KeepCount = 3
    )

    Write-RobocurseLog -Message "Applying VSS retention on '$ServerName' for $Volume (keep: $KeepCount)" -Level 'Info' -Component 'VSS'

    # Get current snapshots
    $listResult = Get-RemoteVssSnapshots -ServerName $ServerName -Volume $Volume
    if (-not $listResult.Success) {
        return New-OperationResult -Success $false -ErrorMessage "Failed to list snapshots: $($listResult.ErrorMessage)"
    }

    $snapshots = @($listResult.Data)
    $currentCount = $snapshots.Count

    # Nothing to do if under limit
    if ($currentCount -le $KeepCount) {
        Write-RobocurseLog -Message "Retention OK on '$ServerName': $currentCount snapshot(s) <= $KeepCount limit" -Level 'Debug' -Component 'VSS'
        return New-OperationResult -Success $true -Data @{
            DeletedCount = 0
            KeptCount    = $currentCount
            Errors       = @()
        }
    }

    # Sort by CreatedAt ascending (oldest first) and select ones to delete
    $sortedSnapshots = $snapshots | Sort-Object CreatedAt
    $toDelete = @($sortedSnapshots | Select-Object -First ($currentCount - $KeepCount))
    $toKeep = @($sortedSnapshots | Select-Object -Last $KeepCount)

    Write-RobocurseLog -Message "Retention on '$ServerName': Deleting $($toDelete.Count) old snapshot(s), keeping $($toKeep.Count)" -Level 'Info' -Component 'VSS'

    $deletedCount = 0
    $errors = @()

    foreach ($snapshot in $toDelete) {
        $shadowId = $snapshot.ShadowId
        $createdAt = $snapshot.CreatedAt

        if ($PSCmdlet.ShouldProcess("$shadowId on $ServerName (created $createdAt)", "Remove Remote VSS Snapshot")) {
            $removeResult = Remove-RemoteVssSnapshot -ShadowId $shadowId -ServerName $ServerName
            if ($removeResult.Success) {
                $deletedCount++
                Write-RobocurseLog -Message "Deleted remote snapshot $shadowId on '$ServerName'" -Level 'Debug' -Component 'VSS'
            }
            else {
                $errors += "Failed to delete $shadowId on '$ServerName': $($removeResult.ErrorMessage)"
                Write-RobocurseLog -Message "Failed to delete remote snapshot: $($removeResult.ErrorMessage)" -Level 'Warning' -Component 'VSS'
            }
        }
    }

    $success = $errors.Count -eq 0
    $resultData = @{
        DeletedCount = $deletedCount
        KeptCount    = $toKeep.Count
        Errors       = $errors
    }

    if ($success) {
        Write-RobocurseLog -Message "Remote retention applied on '$ServerName': deleted $deletedCount, kept $($toKeep.Count)" -Level 'Info' -Component 'VSS'
    }
    else {
        Write-RobocurseLog -Message "Remote retention on '$ServerName' completed with errors: $($errors.Count)" -Level 'Warning' -Component 'VSS'
    }

    return New-OperationResult -Success $success -Data $resultData -ErrorMessage $(if (-not $success) { $errors -join "; " })
}
