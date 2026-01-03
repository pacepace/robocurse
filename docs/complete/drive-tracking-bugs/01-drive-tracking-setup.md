# Task: Drive Mapping Tracking Setup

## Objective
Add tracking infrastructure for network drive mappings so they can be cleaned up after crashes or unexpected terminations, following the same pattern as VSS snapshot tracking.

## Problem Statement
When a job is canceled or the application crashes, mapped network drives (Y:, Z:, etc.) remain mapped on the system. Unlike VSS snapshots which have tracking via `$script:VssTrackingFile`, network mappings have no persistence and cannot be cleaned up on restart.

## Success Criteria
1. A tracking file exists at `$script:NetworkMappingTrackingFile` (in logs directory)
2. Mappings are added to tracking when `Mount-SingleNetworkPath` succeeds
3. Mappings are removed from tracking when `Dismount-NetworkPaths` runs
4. Tracking file format matches VSS tracking (JSON array of objects)
5. All tests pass

## Research: Current Implementation

### VSS Tracking Pattern (VssLocal.ps1:5-97)
```powershell
$script:VssTrackingFile = Join-Path $script:LogPath "robocurse-vss-active.json"

# On snapshot creation - add to tracking
$trackedSnapshots += @{
    ShadowId = $snapshot.ShadowId
    Volume = $Volume
    CreatedAt = [datetime]::Now.ToString('o')
}
$trackedSnapshots | ConvertTo-Json -Depth 5 | Set-Content $script:VssTrackingFile

# On snapshot removal - remove from tracking
# (handled in Clear-OrphanVssSnapshots)
```

### Mount-SingleNetworkPath (NetworkMapping.ps1:48-129)
Currently creates mapping but doesn't track it:
```powershell
$mapping = New-PSDrive -Name $letter -PSProvider FileSystem -Root $root -Persist -Scope Global
return [PSCustomObject]@{
    DriveLetter = "$letter`:"
    Root = $root
    OriginalPath = $UncPath
    MappedPath = $mappedPath
}
```

### Dismount-NetworkPaths (NetworkMapping.ps1:201-222)
Currently removes mapping but doesn't update tracking:
```powershell
foreach ($mapping in $Mappings) {
    $letter = $mapping.DriveLetter.TrimEnd(':')
    Remove-PSDrive -Name $letter -Force -ErrorAction SilentlyContinue
}
```

## Implementation Plan

### Step 1: Add Tracking File Variable
Add to NetworkMapping.ps1 near the top (after comment block):
```powershell
# Tracking file for network mappings - enables cleanup after crash
$script:NetworkMappingTrackingFile = $null  # Initialized in Initialize-NetworkMappingTracking
```

### Step 2: Add Initialize-NetworkMappingTracking Function
```powershell
function Initialize-NetworkMappingTracking {
    <#
    .SYNOPSIS
        Initializes the network mapping tracking file path
    .DESCRIPTION
        Sets up the tracking file path in the logs directory. Must be called
        after logging is initialized.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:LogPath) {
        # Use default if logging not initialized
        $script:LogPath = ".\Logs"
    }

    $script:NetworkMappingTrackingFile = Join-Path $script:LogPath "robocurse-mappings-active.json"
}
```

### Step 3: Add Add-NetworkMappingTracking Function
```powershell
function Add-NetworkMappingTracking {
    <#
    .SYNOPSIS
        Adds a network mapping to the tracking file
    .PARAMETER Mapping
        The mapping object from Mount-SingleNetworkPath
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Mapping
    )

    if (-not $script:NetworkMappingTrackingFile) {
        Initialize-NetworkMappingTracking
    }

    $trackedMappings = @()

    if (Test-Path $script:NetworkMappingTrackingFile) {
        try {
            $content = Get-Content $script:NetworkMappingTrackingFile -Raw | ConvertFrom-Json
            $trackedMappings = @($content)
        }
        catch {
            Write-RobocurseLog -Message "Failed to read mapping tracking file, starting fresh: $($_.Exception.Message)" `
                -Level 'Warning' -Component 'NetworkMapping'
        }
    }

    $trackedMappings += @{
        DriveLetter = $Mapping.DriveLetter
        Root = $Mapping.Root
        OriginalPath = $Mapping.OriginalPath
        MappedPath = $Mapping.MappedPath
        CreatedAt = [datetime]::Now.ToString('o')
    }

    # Ensure directory exists
    $trackingDir = Split-Path $script:NetworkMappingTrackingFile -Parent
    if (-not (Test-Path $trackingDir)) {
        New-Item -Path $trackingDir -ItemType Directory -Force | Out-Null
    }

    $trackedMappings | ConvertTo-Json -Depth 5 | Set-Content $script:NetworkMappingTrackingFile -Encoding UTF8

    Write-RobocurseLog -Message "Added mapping to tracking: $($Mapping.DriveLetter) -> $($Mapping.Root)" `
        -Level 'Debug' -Component 'NetworkMapping'
}
```

### Step 4: Add Remove-NetworkMappingTracking Function
```powershell
function Remove-NetworkMappingTracking {
    <#
    .SYNOPSIS
        Removes a network mapping from the tracking file
    .PARAMETER DriveLetter
        The drive letter to remove (e.g., "Y:" or "Y")
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DriveLetter
    )

    if (-not $script:NetworkMappingTrackingFile -or -not (Test-Path $script:NetworkMappingTrackingFile)) {
        return
    }

    $letter = $DriveLetter.TrimEnd(':')

    try {
        $trackedMappings = @(Get-Content $script:NetworkMappingTrackingFile -Raw | ConvertFrom-Json)
        $remainingMappings = @($trackedMappings | Where-Object { $_.DriveLetter -ne "$letter`:" -and $_.DriveLetter -ne $letter })

        if ($remainingMappings.Count -eq 0) {
            Remove-Item $script:NetworkMappingTrackingFile -Force -ErrorAction SilentlyContinue
            Write-RobocurseLog -Message "All mappings removed, deleted tracking file" `
                -Level 'Debug' -Component 'NetworkMapping'
        }
        else {
            $remainingMappings | ConvertTo-Json -Depth 5 | Set-Content $script:NetworkMappingTrackingFile -Encoding UTF8
        }

        Write-RobocurseLog -Message "Removed mapping from tracking: $letter" `
            -Level 'Debug' -Component 'NetworkMapping'
    }
    catch {
        Write-RobocurseLog -Message "Failed to update mapping tracking: $($_.Exception.Message)" `
            -Level 'Warning' -Component 'NetworkMapping'
    }
}
```

### Step 5: Update Mount-SingleNetworkPath to Track
Add after successful mount (around line 107):
```powershell
# Track the mapping for crash recovery
Add-NetworkMappingTracking -Mapping $result
```

### Step 6: Update Dismount-NetworkPaths to Remove from Tracking
Add inside the foreach loop (around line 214):
```powershell
# Remove from tracking
Remove-NetworkMappingTracking -DriveLetter $mapping.DriveLetter
```

## Test Plan

Add to `tests/Unit/NetworkMapping.Tests.ps1`:

```powershell
Context "Network Mapping Tracking" {
    BeforeEach {
        $script:TestLogPath = Join-Path $env:TEMP "RobocurseTrackingTest_$(Get-Random)"
        New-Item -Path $script:TestLogPath -ItemType Directory -Force | Out-Null
        $script:LogPath = $script:TestLogPath
        Initialize-NetworkMappingTracking
    }

    AfterEach {
        if (Test-Path $script:TestLogPath) {
            Remove-Item $script:TestLogPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should create tracking file when mapping is added" {
        $mapping = [PSCustomObject]@{
            DriveLetter = "Y:"
            Root = "\\server\share"
            OriginalPath = "\\server\share\folder"
            MappedPath = "Y:\folder"
        }

        Add-NetworkMappingTracking -Mapping $mapping

        Test-Path $script:NetworkMappingTrackingFile | Should -Be $true
        $tracked = Get-Content $script:NetworkMappingTrackingFile -Raw | ConvertFrom-Json
        $tracked.DriveLetter | Should -Be "Y:"
    }

    It "Should remove mapping from tracking file" {
        $mapping = [PSCustomObject]@{
            DriveLetter = "Y:"
            Root = "\\server\share"
            OriginalPath = "\\server\share"
            MappedPath = "Y:\"
        }

        Add-NetworkMappingTracking -Mapping $mapping
        Remove-NetworkMappingTracking -DriveLetter "Y:"

        Test-Path $script:NetworkMappingTrackingFile | Should -Be $false
    }

    It "Should handle multiple mappings" {
        $mapping1 = [PSCustomObject]@{ DriveLetter = "Y:"; Root = "\\s1\share"; OriginalPath = "\\s1\share"; MappedPath = "Y:\" }
        $mapping2 = [PSCustomObject]@{ DriveLetter = "Z:"; Root = "\\s2\share"; OriginalPath = "\\s2\share"; MappedPath = "Z:\" }

        Add-NetworkMappingTracking -Mapping $mapping1
        Add-NetworkMappingTracking -Mapping $mapping2

        $tracked = @(Get-Content $script:NetworkMappingTrackingFile -Raw | ConvertFrom-Json)
        $tracked.Count | Should -Be 2

        Remove-NetworkMappingTracking -DriveLetter "Y:"
        $tracked = @(Get-Content $script:NetworkMappingTrackingFile -Raw | ConvertFrom-Json)
        $tracked.Count | Should -Be 1
        $tracked[0].DriveLetter | Should -Be "Z:"
    }
}
```

## Files to Modify
1. `src/Robocurse/Public/NetworkMapping.ps1` - Add tracking functions and integrate
2. `tests/Unit/NetworkMapping.Tests.ps1` - Add tracking tests

## Verification Commands
```powershell
# Run tests
.\scripts\run-tests.ps1

# Run specific test file
Invoke-Pester -Path tests\Unit\NetworkMapping.Tests.ps1 -Output Detailed
```
