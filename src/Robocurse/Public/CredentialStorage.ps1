# Robocurse Network Credential Storage
# Secure storage for network share credentials using DPAPI (Export-Clixml)
#
# =====================================================================================
# SECURITY MODEL - IMPORTANT
# =====================================================================================
# This uses Export-Clixml which encrypts credentials via Windows DPAPI.
# DPAPI encryption is bound to:
#   1. The USER ACCOUNT that created the credential file
#   2. The MACHINE where it was created
#
# ONLY the same user on the same machine can decrypt these credentials.
#
# IMPLICATIONS:
#   - The credential file MUST be created by the same user that runs scheduled tasks
#   - If the scheduled task runs as "DOMAIN\ServiceAccount", credentials must be
#     saved while logged in as "DOMAIN\ServiceAccount"
#   - GUI can save credentials if running as the same account
#   - If the service account changes, credentials must be re-saved
#
# This is the MOST SECURE option for storing credentials - far better than:
#   - Machine-bound keys (any process on machine can decrypt)
#   - Plaintext in config files
#   - Environment variables
#
# Reference: https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/export-clixml
# =====================================================================================

function Get-CredentialStoragePath {
    <#
    .SYNOPSIS
        Gets the path to credential storage directory
    .PARAMETER ConfigPath
        Path to the Robocurse config file (credentials stored alongside in .credentials subfolder)
    .OUTPUTS
        Full path to credentials directory
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $configDir = Split-Path $ConfigPath -Parent
    if ([string]::IsNullOrEmpty($configDir)) {
        $configDir = $PWD.Path
    }
    return Join-Path $configDir ".credentials"
}

function Save-NetworkCredential {
    <#
    .SYNOPSIS
        Saves credentials for a profile using DPAPI encryption (Export-Clixml)
    .DESCRIPTION
        Stores PSCredential encrypted with DPAPI. The credential can ONLY be
        decrypted by the same user on the same machine that created it.
    .PARAMETER ProfileName
        Name of the profile (used as filename)
    .PARAMETER Credential
        PSCredential object to save
    .PARAMETER ConfigPath
        Path to the Robocurse config file (credentials stored alongside)
    .OUTPUTS
        OperationResult
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName,

        [Parameter(Mandatory)]
        [PSCredential]$Credential,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    try {
        $credDir = Get-CredentialStoragePath -ConfigPath $ConfigPath

        # Create credentials directory if it doesn't exist
        if (-not (Test-Path $credDir)) {
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            Write-RobocurseLog -Message "Created credential storage directory: $credDir" -Level 'Debug' -Component 'CredentialStorage'
        }

        # Sanitize profile name for filename
        $safeProfileName = $ProfileName -replace '[\\/:*?"<>|]', '_'
        $credPath = Join-Path $credDir "$safeProfileName.credential"

        # Export using DPAPI (user+machine bound)
        $Credential | Export-Clixml -Path $credPath -Force

        Write-RobocurseLog -Message "Saved network credentials for profile '$ProfileName' (user: $($Credential.UserName))" -Level 'Info' -Component 'CredentialStorage'

        return New-OperationResult -Success $true -Data $credPath
    }
    catch {
        Write-RobocurseLog -Message "Failed to save credentials for '$ProfileName': $($_.Exception.Message)" -Level 'Error' -Component 'CredentialStorage'
        return New-OperationResult -Success $false -ErrorMessage "Failed to save credentials: $($_.Exception.Message)" -ErrorRecord $_
    }
}

function Get-NetworkCredential {
    <#
    .SYNOPSIS
        Loads stored credentials for a profile
    .DESCRIPTION
        Retrieves PSCredential encrypted with DPAPI. Will ONLY succeed if called
        by the same user on the same machine that created the credential.
    .PARAMETER ProfileName
        Name of the profile
    .PARAMETER ConfigPath
        Path to the Robocurse config file
    .OUTPUTS
        PSCredential or $null if not found or decryption fails
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $credDir = Get-CredentialStoragePath -ConfigPath $ConfigPath
    $safeProfileName = $ProfileName -replace '[\\/:*?"<>|]', '_'
    $credPath = Join-Path $credDir "$safeProfileName.credential"

    if (-not (Test-Path $credPath)) {
        Write-RobocurseLog -Message "No stored credentials found for profile '$ProfileName'" -Level 'Debug' -Component 'CredentialStorage'
        return $null
    }

    try {
        $credential = Import-Clixml -Path $credPath
        Write-RobocurseLog -Message "Loaded network credentials for profile '$ProfileName' (user: $($credential.UserName))" -Level 'Debug' -Component 'CredentialStorage'
        return $credential
    }
    catch {
        # DPAPI decryption fails if wrong user or different machine
        Write-RobocurseLog -Message "Failed to load credentials for '$ProfileName': $($_.Exception.Message). This usually means the credential was created by a different user or on a different machine." -Level 'Warning' -Component 'CredentialStorage'
        return $null
    }
}

function Remove-NetworkCredential {
    <#
    .SYNOPSIS
        Removes stored credentials for a profile
    .PARAMETER ProfileName
        Name of the profile
    .PARAMETER ConfigPath
        Path to the Robocurse config file
    .OUTPUTS
        OperationResult
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $credDir = Get-CredentialStoragePath -ConfigPath $ConfigPath
    $safeProfileName = $ProfileName -replace '[\\/:*?"<>|]', '_'
    $credPath = Join-Path $credDir "$safeProfileName.credential"

    if (Test-Path $credPath) {
        try {
            Remove-Item $credPath -Force
            Write-RobocurseLog -Message "Removed network credentials for profile '$ProfileName'" -Level 'Info' -Component 'CredentialStorage'
            return New-OperationResult -Success $true
        }
        catch {
            Write-RobocurseLog -Message "Failed to remove credentials for '$ProfileName': $($_.Exception.Message)" -Level 'Error' -Component 'CredentialStorage'
            return New-OperationResult -Success $false -ErrorMessage "Failed to remove credentials: $($_.Exception.Message)" -ErrorRecord $_
        }
    }
    else {
        # Not an error - credential didn't exist
        return New-OperationResult -Success $true
    }
}

function Test-NetworkCredentialExists {
    <#
    .SYNOPSIS
        Checks if credentials exist for a profile (doesn't try to decrypt)
    .PARAMETER ProfileName
        Name of the profile
    .PARAMETER ConfigPath
        Path to the Robocurse config file
    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $credDir = Get-CredentialStoragePath -ConfigPath $ConfigPath
    $safeProfileName = $ProfileName -replace '[\\/:*?"<>|]', '_'
    $credPath = Join-Path $credDir "$safeProfileName.credential"

    return Test-Path $credPath
}
