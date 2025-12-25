# Task: Scheduled Task Network Share Access Fix

## Objective
Fix scheduled tasks failing to access network shares (especially IP-based UNCs) by implementing explicit credential-based drive mapping.

## Problem
1. Task Scheduler runs in Session 0 (non-interactive, isolated)
2. IP-based UNC paths (e.g., `\\192.168.123.1\share`) can't use Kerberos (no SPN)
3. NTLM doesn't properly delegate credentials in Session 0
4. Result: SMB server sees ANONYMOUS LOGON → Access Denied

## Solution
Before accessing any UNC path, explicitly map it to a drive letter with `New-PSDrive`. Use stored credentials if available (scheduled tasks), otherwise use current user context (interactive GUI).

**Single code path** - works identically for GUI and headless execution.

## Success Criteria
- [ ] Scheduled tasks can access IP-based UNC shares
- [ ] Interactive GUI sessions continue to work without requiring stored credentials
- [ ] Drive letters are cleaned up after job completion
- [ ] Stale drive mappings from crashed runs are cleaned up
- [ ] Optional user setting for preferred drive letters
- [ ] All existing tests pass
- [ ] New tests cover credential storage and network mapping

## Files to Create

### 1. `src/Robocurse/Public/CredentialStorage.ps1`

```powershell
# Robocurse Network Credential Storage
# Machine-bound encryption - any process on machine can decrypt

function Save-NetworkCredential {
    <#
    .SYNOPSIS
        Saves credentials for a profile using machine-bound encryption
    .PARAMETER ProfileName
        Name of the profile
    .PARAMETER Credential
        PSCredential object to save
    .PARAMETER ConfigPath
        Path to the Robocurse config file (credentials stored alongside)
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

    # Derive key from machine identity (stable, machine-specific)
    $machineId = (Get-CimInstance Win32_ComputerSystemProduct).UUID
    $key = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [Text.Encoding]::UTF8.GetBytes($machineId)
    )[0..31]

    # Encrypt password with machine key
    $encrypted = ConvertFrom-SecureString -SecureString $Credential.Password -Key $key

    # Store in .credentials subfolder
    $credDir = Join-Path (Split-Path $ConfigPath) ".credentials"
    if (-not (Test-Path $credDir)) {
        New-Item -ItemType Directory -Path $credDir -Force | Out-Null
    }

    $credPath = Join-Path $credDir "$ProfileName.cred"
    @{
        Username = $Credential.UserName
        Password = $encrypted
    } | ConvertTo-Json | Set-Content $credPath -Force

    Write-RobocurseLog -Message "Saved network credentials for profile '$ProfileName'" -Level 'Debug' -Component 'CredentialStorage'
}

function Get-NetworkCredential {
    <#
    .SYNOPSIS
        Loads stored credentials for a profile
    .PARAMETER ProfileName
        Name of the profile
    .PARAMETER ConfigPath
        Path to the Robocurse config file
    .OUTPUTS
        PSCredential or $null if not found
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $credPath = Join-Path (Split-Path $ConfigPath) ".credentials\$ProfileName.cred"
    if (-not (Test-Path $credPath)) {
        return $null
    }

    try {
        # Same key derivation
        $machineId = (Get-CimInstance Win32_ComputerSystemProduct).UUID
        $key = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($machineId)
        )[0..31]

        $data = Get-Content $credPath -Raw | ConvertFrom-Json
        $securePass = ConvertTo-SecureString -String $data.Password -Key $key
        return [PSCredential]::new($data.Username, $securePass)
    }
    catch {
        Write-RobocurseLog -Message "Failed to load credentials for '$ProfileName': $($_.Exception.Message)" -Level 'Warning' -Component 'CredentialStorage'
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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $credPath = Join-Path (Split-Path $ConfigPath) ".credentials\$ProfileName.cred"
    if (Test-Path $credPath) {
        Remove-Item $credPath -Force
        Write-RobocurseLog -Message "Removed network credentials for profile '$ProfileName'" -Level 'Debug' -Component 'CredentialStorage'
    }
}
```

### 2. `src/Robocurse/Public/NetworkMapping.ps1`

```powershell
# Robocurse Network Path Mapping
# Maps UNC paths to drive letters with explicit credentials

function Mount-NetworkPaths {
    <#
    .SYNOPSIS
        Mounts UNC paths to drive letters for reliable network access
    .DESCRIPTION
        Maps source and/or destination UNC paths to drive letters.
        Uses explicit credentials if provided (for Session 0 reliability),
        otherwise uses current user context (for interactive sessions).
    .PARAMETER SourcePath
        Source path (may be UNC or local)
    .PARAMETER DestinationPath
        Destination path (may be UNC or local)
    .PARAMETER Credential
        Optional PSCredential for authentication
    .PARAMETER PreferredSourceLetter
        Optional preferred drive letter for source (from settings)
    .PARAMETER PreferredDestLetter
        Optional preferred drive letter for destination (from settings)
    .OUTPUTS
        Hashtable with Mappings array, translated SourcePath and DestinationPath
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [PSCredential]$Credential,

        [string]$PreferredSourceLetter,

        [string]$PreferredDestLetter
    )

    $mappings = @()
    $translatedSource = $SourcePath
    $translatedDest = $DestinationPath

    # Map source if UNC
    if ($SourcePath -match '^\\\\') {
        $mapping = Mount-SingleNetworkPath -UncPath $SourcePath -Credential $Credential -PreferredLetter $PreferredSourceLetter
        $mappings += $mapping
        $translatedSource = $mapping.MappedPath
        Write-RobocurseLog -Message "Mapped source '$SourcePath' to '$translatedSource'" -Level 'Info' -Component 'NetworkMapping'
    }

    # Map destination if UNC (may share same root as source)
    if ($DestinationPath -match '^\\\\') {
        $destRoot = if ($DestinationPath -match '^(\\\\[^\\]+\\[^\\]+)') { $Matches[1] } else { $DestinationPath }
        $existing = $mappings | Where-Object { $_.Root -eq $destRoot }

        if ($existing) {
            # Reuse existing mapping for same root
            $remainder = $DestinationPath.Substring($destRoot.Length)
            $translatedDest = "$($existing.DriveLetter):$remainder"
            Write-RobocurseLog -Message "Reusing source mapping for destination: '$translatedDest'" -Level 'Debug' -Component 'NetworkMapping'
        } else {
            $mapping = Mount-SingleNetworkPath -UncPath $DestinationPath -Credential $Credential -PreferredLetter $PreferredDestLetter
            $mappings += $mapping
            $translatedDest = $mapping.MappedPath
            Write-RobocurseLog -Message "Mapped destination '$DestinationPath' to '$translatedDest'" -Level 'Info' -Component 'NetworkMapping'
        }
    }

    return @{
        Mappings = $mappings
        SourcePath = $translatedSource
        DestinationPath = $translatedDest
    }
}

function Mount-SingleNetworkPath {
    <#
    .SYNOPSIS
        Mounts a single UNC path to a drive letter
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UncPath,

        [PSCredential]$Credential,

        [string]$PreferredLetter
    )

    # Extract \\server\share root
    if ($UncPath -match '^(\\\\[^\\]+\\[^\\]+)(.*)$') {
        $root = $Matches[1]
        $remainder = $Matches[2]
    } else {
        $root = $UncPath
        $remainder = ""
    }

    # CLEANUP: Remove any existing mapping to this root (stale from previous runs)
    $existingDrive = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayRoot -eq $root }
    if ($existingDrive) {
        Write-RobocurseLog -Message "Removing stale mapping $($existingDrive.Name): to '$root'" -Level 'Debug' -Component 'NetworkMapping'
        Remove-PSDrive -Name $existingDrive.Name -Force -ErrorAction SilentlyContinue
    }

    # Determine drive letter to use
    $used = @((Get-PSDrive -PSProvider FileSystem).Name)

    if ($PreferredLetter -and ([string]$PreferredLetter -notin $used)) {
        $letter = $PreferredLetter
    } else {
        # Auto-detect: find available letter (Z down to D)
        $letter = [char[]](90..68) | Where-Object { [string]$_ -notin $used } | Select-Object -First 1
        if (-not $letter) {
            throw "No available drive letters for network mapping"
        }
    }

    # Establish connection
    if ($Credential) {
        Write-RobocurseLog -Message "Mounting '$root' as $letter`: with explicit credentials" -Level 'Debug' -Component 'NetworkMapping'
        New-PSDrive -Name $letter -PSProvider FileSystem -Root $root -Credential $Credential -Scope Global -ErrorAction Stop | Out-Null
    } else {
        Write-RobocurseLog -Message "Mounting '$root' as $letter`: with current user context" -Level 'Debug' -Component 'NetworkMapping'
        New-PSDrive -Name $letter -PSProvider FileSystem -Root $root -Scope Global -ErrorAction Stop | Out-Null
    }

    return [PSCustomObject]@{
        DriveLetter = [string]$letter
        Root = $root
        OriginalPath = $UncPath
        MappedPath = "${letter}:$remainder"
    }
}

function Dismount-NetworkPaths {
    <#
    .SYNOPSIS
        Removes drive mappings created by Mount-NetworkPaths
    .PARAMETER Mappings
        Array of mapping objects from Mount-NetworkPaths
    #>
    [CmdletBinding()]
    param(
        [array]$Mappings
    )

    foreach ($mapping in $Mappings) {
        try {
            Remove-PSDrive -Name $mapping.DriveLetter -Force -ErrorAction Stop
            Write-RobocurseLog -Message "Unmapped $($mapping.DriveLetter): from '$($mapping.Root)'" -Level 'Debug' -Component 'NetworkMapping'
        }
        catch {
            Write-RobocurseLog -Message "Failed to unmount $($mapping.DriveLetter):: $($_.Exception.Message)" -Level 'Warning' -Component 'NetworkMapping'
        }
    }
}
```

## Files to Modify

### 3. `src/Robocurse/Public/ProfileSchedule.ps1`

In `New-ProfileScheduledTask`, after registering the task, save credentials:

```powershell
# After task registration succeeds, save credentials for network mounting
if ($Credential) {
    Save-NetworkCredential -ProfileName $Profile.Name -Credential $Credential -ConfigPath $ConfigPath
}
```

### 4. `src/Robocurse/Public/Main.ps1`

Before running orchestration (both GUI and headless paths), mount network paths:

```powershell
# Mount network paths if UNC
$networkMappings = $null
$effectiveSource = $profile.Source
$effectiveDest = $profile.Destination

if ($profile.Source -match '^\\\\' -or $profile.Destination -match '^\\\\') {
    $cred = Get-NetworkCredential -ProfileName $profile.Name -ConfigPath $ConfigPath

    # Get optional preferred letters from config
    $srcLetter = $config.NetworkMappingSettings.SourceDriveLetter
    $destLetter = $config.NetworkMappingSettings.DestinationDriveLetter

    $result = Mount-NetworkPaths -SourcePath $profile.Source -DestinationPath $profile.Destination `
        -Credential $cred -PreferredSourceLetter $srcLetter -PreferredDestLetter $destLetter

    $networkMappings = $result.Mappings
    $effectiveSource = $result.SourcePath
    $effectiveDest = $result.DestinationPath
}

# Pass $effectiveSource and $effectiveDest to orchestration instead of $profile.Source/Destination
```

After job completion, cleanup:

```powershell
if ($networkMappings) {
    Dismount-NetworkPaths -Mappings $networkMappings
}
```

### 5. `src/Robocurse/Public/GuiReplication.ps1`

Same mount/unmount logic as Main.ps1 for GUI replication path.

### 6. `build/Build-Robocurse.ps1`

Add new files to build order (before Main.ps1):
- `CredentialStorage.ps1`
- `NetworkMapping.ps1`

### 7. Configuration Schema

Add optional NetworkMappingSettings to config:

```json
{
  "NetworkMappingSettings": {
    "SourceDriveLetter": null,
    "DestinationDriveLetter": null
  }
}
```

## Test Plan

### Unit Tests: `tests/Unit/CredentialStorage.Tests.ps1`

```powershell
Describe 'CredentialStorage' {
    BeforeAll {
        $testConfigPath = Join-Path $TestDrive 'test-config.json'
        '{}' | Set-Content $testConfigPath
    }

    AfterEach {
        $credDir = Join-Path $TestDrive '.credentials'
        if (Test-Path $credDir) { Remove-Item $credDir -Recurse -Force }
    }

    It 'Should save and load credentials' {
        $cred = [PSCredential]::new('DOMAIN\user', (ConvertTo-SecureString 'password' -AsPlainText -Force))
        Save-NetworkCredential -ProfileName 'TestProfile' -Credential $cred -ConfigPath $testConfigPath

        $loaded = Get-NetworkCredential -ProfileName 'TestProfile' -ConfigPath $testConfigPath
        $loaded | Should -Not -BeNullOrEmpty
        $loaded.UserName | Should -Be 'DOMAIN\user'
        $loaded.GetNetworkCredential().Password | Should -Be 'password'
    }

    It 'Should return null for non-existent profile' {
        $loaded = Get-NetworkCredential -ProfileName 'NonExistent' -ConfigPath $testConfigPath
        $loaded | Should -BeNullOrEmpty
    }

    It 'Should remove credentials' {
        $cred = [PSCredential]::new('user', (ConvertTo-SecureString 'pass' -AsPlainText -Force))
        Save-NetworkCredential -ProfileName 'ToDelete' -Credential $cred -ConfigPath $testConfigPath

        Remove-NetworkCredential -ProfileName 'ToDelete' -ConfigPath $testConfigPath

        $loaded = Get-NetworkCredential -ProfileName 'ToDelete' -ConfigPath $testConfigPath
        $loaded | Should -BeNullOrEmpty
    }
}
```

### Unit Tests: `tests/Unit/NetworkMapping.Tests.ps1`

```powershell
Describe 'NetworkMapping' {
    It 'Should return original paths for local paths' {
        $result = Mount-NetworkPaths -SourcePath 'C:\Source' -DestinationPath 'D:\Dest'
        $result.SourcePath | Should -Be 'C:\Source'
        $result.DestinationPath | Should -Be 'D:\Dest'
        $result.Mappings.Count | Should -Be 0
    }

    It 'Should detect available drive letters' {
        # Test the letter detection logic
        $used = @('C', 'D', 'E')
        $available = [char[]](90..68) | Where-Object { [string]$_ -notin $used } | Select-Object -First 1
        $available | Should -Be 'Z'
    }

    It 'Should extract UNC root correctly' {
        $testPath = '\\192.168.1.1\share\subfolder\file.txt'
        $testPath -match '^(\\\\[^\\]+\\[^\\]+)(.*)$' | Should -BeTrue
        $Matches[1] | Should -Be '\\192.168.1.1\share'
        $Matches[2] | Should -Be '\subfolder\file.txt'
    }
}
```

## Verification

1. Build the monolith: `.\build\Build-Robocurse.ps1`
2. Run tests: `.\scripts\run-tests.ps1`
3. Deploy to test machine
4. Schedule a profile with IP-based UNC path
5. Verify task runs successfully and accesses network share
6. Verify interactive GUI still works without stored credentials
