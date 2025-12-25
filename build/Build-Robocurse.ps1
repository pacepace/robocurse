<#
.SYNOPSIS
    Builds Robocurse.ps1 from module source files

.DESCRIPTION
    This build script assembles the modular Robocurse source files into a single
    monolithic script for easy deployment. It:
    - Reads the header (param block, requires statements) from Header.ps1
    - Concatenates all module files in dependency order
    - Outputs a single deployable Robocurse.ps1

.PARAMETER OutputPath
    Path for the output script. Defaults to ../dist/Robocurse.ps1

.PARAMETER MinifyComments
    Remove comment-based help blocks to reduce file size (keeps inline comments)

.EXAMPLE
    .\Build-Robocurse.ps1
    Builds the monolith script to ../dist/Robocurse.ps1

.EXAMPLE
    .\Build-Robocurse.ps1 -OutputPath "C:\Deploy\Robocurse.ps1"
    Builds to a custom location
#>
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "..\dist\Robocurse.ps1"),
    [switch]$MinifyComments
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSScriptRoot
$srcRoot = Join-Path $scriptRoot "src\Robocurse"
$resourcesRoot = Join-Path $srcRoot "Resources"

Write-Host "Building Robocurse monolith..." -ForegroundColor Cyan
Write-Host "Source: $srcRoot" -ForegroundColor Gray

# Load XAML resources for embedding
$xamlResources = @{}
$xamlFiles = Get-ChildItem -Path $resourcesRoot -Filter "*.xaml" -ErrorAction SilentlyContinue
foreach ($xamlFile in $xamlFiles) {
    $xamlContent = Get-Content -Path $xamlFile.FullName -Raw
    # Escape single quotes for PowerShell here-string embedding
    $xamlResources[$xamlFile.Name] = $xamlContent
    Write-Host "  Loaded XAML: $($xamlFile.Name)" -ForegroundColor Gray
}

# Define module load order (dependency order)
# Checkpoint must be loaded before Orchestration (Orchestration uses checkpoint functions)
# GUI modules are split into separate files for maintainability
$moduleOrder = @(
    'Public\Utility.ps1'
    'Public\Configuration.ps1'
    'Public\Logging.ps1'
    'Public\DirectoryProfiling.ps1'
    'Public\Chunking.ps1'
    'Public\Robocopy.ps1'
    'Public\Checkpoint.ps1'
    # Orchestration modules (split for maintainability)
    'Public\OrchestrationCore.ps1'  # C# types, state management, circuit breaker
    'Public\HealthCheck.ps1'        # Health monitoring (before JobManagement which uses it)
    'Public\CredentialStorage.ps1'  # DPAPI credential storage for network shares (before NetworkMapping)
    'Public\NetworkMapping.ps1'     # UNC path to drive letter mapping (before JobManagement)
    'Public\JobManagement.ps1'      # Job execution, profile management
    'Public\Progress.ps1'
    'Public\VssCore.ps1'
    'Public\VssLocal.ps1'
    'Public\VssRemote.ps1'
    'Public\SnapshotCli.ps1'        # CLI snapshot management
    'Public\Email.ps1'
    'Public\Scheduling.ps1'
    'Public\SnapshotSchedule.ps1'   # Scheduled snapshot operations
    'Public\ProfileSchedule.ps1'    # Scheduled profile operations
    # GUI modules (split from GUI.ps1 for maintainability)
    'Public\GuiResources.ps1'
    'Public\GuiValidation.ps1'      # GUI validation helpers
    'Public\GuiSettings.ps1'
    'Public\GuiProfiles.ps1'
    'Public\GuiChunkActions.ps1'    # Chunk action handlers
    'Public\GuiDialogs.ps1'
    'Public\GuiLogWindow.ps1'       # Popup log viewer window
    'Public\GuiRunspace.ps1'
    'Public\GuiReplication.ps1'
    'Public\GuiProgress.ps1'
    'Public\GuiSnapshotDialogs.ps1' # Snapshot dialog windows
    'Public\GuiSnapshots.ps1'
    'Public\GuiMain.ps1'
    # Entry point
    'Public\Main.ps1'
)

# Start with the script header
$output = [System.Text.StringBuilder]::new()

# Add header with requires and param block
[void]$output.AppendLine(@'
#Requires -Version 5.1
<#
.SYNOPSIS
    Robocurse - Multi-share parallel robocopy orchestrator

.DESCRIPTION
    A parallel replication orchestrator for robocopy that handles multiple source/destination
    pairs with intelligent directory chunking, progress tracking, and email notifications.

    Features:
    - Parallel robocopy jobs with configurable concurrency
    - Smart directory chunking based on size and file count
    - VSS snapshot support for locked files
    - JSON configuration with profile management
    - SIEM-compatible JSON logging
    - Email notifications with HTML reports
    - Windows Task Scheduler integration
    - Dark-themed WPF GUI

.PARAMETER ConfigPath
    Path to JSON configuration file. Default: .\Robocurse.config.json

.PARAMETER Headless
    Run without GUI (for scheduled tasks and scripts)

.PARAMETER SyncProfile
    Name of specific profile to run (alias: -Profile)

.PARAMETER AllProfiles
    Run all enabled profiles (headless mode only)

.PARAMETER DryRun
    Preview mode - shows what would be copied without copying

.PARAMETER Help
    Show this help message

.EXAMPLE
    .\Robocurse.ps1
    Launches the GUI

.EXAMPLE
    .\Robocurse.ps1 -Headless -Profile "DailyBackup"
    Run specific profile in headless mode

.EXAMPLE
    .\Robocurse.ps1 -Headless -AllProfiles
    Run all enabled profiles in headless mode

.EXAMPLE
    .\Robocurse.ps1 -Headless -DryRun -Profile "DailyBackup"
    Preview what would be replicated

.NOTES
    Author: Mark Pace
    License: MIT
    Built: BUILDDATE

.LINK
    https://github.com/pacepace/robocurse
#>
param(
    [switch]$Headless,
    [string]$ConfigPath = ".\Robocurse.config.json",
    # Note: Named $SyncProfile to avoid shadowing PowerShell's built-in $Profile variable
    [Alias('Profile')]
    [string]$SyncProfile,
    [switch]$AllProfiles,
    [switch]$DryRun,
    [switch]$Help,
    # Internal: Load functions only without executing main entry point (for background runspace)
    [switch]$LoadOnly
)

# Capture script path at initialization for use by functions
$script:RobocurseScriptPath = $PSCommandPath

'@)

# Replace build date placeholder
$buildDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$headerContent = $output.ToString()
$headerContent = $headerContent -replace 'BUILDDATE', $buildDate
$output.Clear()
[void]$output.Append($headerContent)

# Read and extract constants from .psm1
$psmPath = Join-Path $srcRoot "Robocurse.psm1"
if (Test-Path $psmPath) {
    $psmContent = Get-Content $psmPath -Raw

    # Extract the CONSTANTS region (use [\s\S] to match across newlines)
    if ($psmContent -match '(?s)#region ==================== CONSTANTS ====================(.*?)#endregion') {
        [void]$output.AppendLine("#region ==================== CONSTANTS ====================")
        [void]$output.AppendLine($matches[1].Trim())
        [void]$output.AppendLine("#endregion")
        [void]$output.AppendLine()
        Write-Host "  Added CONSTANTS region" -ForegroundColor Gray
    }
    else {
        Write-Warning "CONSTANTS region not found in Robocurse.psm1"
    }
}

# Process each module file
foreach ($modulePath in $moduleOrder) {
    $fullPath = Join-Path $srcRoot $modulePath

    if (-not (Test-Path $fullPath)) {
        Write-Warning "Module not found: $modulePath (skipping)"
        continue
    }

    Write-Host "  Adding: $modulePath" -ForegroundColor Gray

    $content = Get-Content $fullPath -Raw

    # Remove the module header comment (first # Robocurse... line)
    $content = $content -replace '^#\s*Robocurse[^\r\n]*[\r\n]+', ''

    # Optionally minify by removing comment-based help
    if ($MinifyComments) {
        # Remove <# ... #> blocks
        $content = $content -replace '<#[\s\S]*?#>', ''
    }

    # For GUI modules (Gui*.ps1), embed XAML resources as fallback content
    # XAML calls are in: GuiMain.ps1 (MainWindow.xaml), GuiDialogs.ps1 (CompletionDialog.xaml, ScheduleDialog.xaml)
    if ($modulePath -match '^Public\\Gui.*\.ps1$') {
        foreach ($xamlName in $xamlResources.Keys) {
            # Create escaped XAML content for embedding in a here-string
            $escapedXaml = $xamlResources[$xamlName] -replace "'", "''"

            # Pattern to find: Get-XamlResource -ResourceName 'FileName.xaml'
            # Replace with: Get-XamlResource -ResourceName 'FileName.xaml' -FallbackContent @'...'@
            $pattern = "Get-XamlResource -ResourceName '$xamlName'"
            $replacement = "Get-XamlResource -ResourceName '$xamlName' -FallbackContent @'`n$($xamlResources[$xamlName])`n'@"

            if ($content -match [regex]::Escape($pattern)) {
                $content = $content -replace [regex]::Escape($pattern), $replacement
                Write-Host "    Embedded XAML: $xamlName in $([System.IO.Path]::GetFileName($modulePath))" -ForegroundColor DarkGray
            }
        }
    }

    # Add region wrapper
    $regionName = [System.IO.Path]::GetFileNameWithoutExtension($modulePath).ToUpper()
    [void]$output.AppendLine("#region ==================== $regionName ====================")
    [void]$output.AppendLine()
    [void]$output.AppendLine($content.Trim())
    [void]$output.AppendLine()
    [void]$output.AppendLine("#endregion")
    [void]$output.AppendLine()
}

# Note: Main.ps1 contains Start-RobocurseMain which is the entry point
# The entry point code below calls it with the script parameters

# Add script path initialization for background runspace loading
[void]$output.AppendLine(@'

# Store script path for background runspace loading (GUI mode)
# This is needed because the background runspace needs to know where to load the script from
$script:RobocurseScriptPath = $PSCommandPath

'@)

# Add main execution block (matches original monolith behavior)
[void]$output.AppendLine(@'
# Main entry point - only execute if not being dot-sourced for testing
# LoadOnly mode: Just load functions without any execution (for background runspace loading)
if ($LoadOnly) {
    return
}

# Check if -Help was passed (always process help)
if ($Help) {
    Show-RobocurseHelp
    exit 0
}

# Use the Test-IsBeingDotSourced function to detect dot-sourcing
# This avoids duplicating the call stack detection logic
if (-not (Test-IsBeingDotSourced)) {
    $exitCode = Start-RobocurseMain -Headless:$Headless -ConfigPath $ConfigPath -ProfileName $SyncProfile -AllProfiles:$AllProfiles -DryRun:$DryRun -ShowHelp:$Help
    exit $exitCode
}

'@)

# Ensure output directory exists
$outputDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Write output file
$output.ToString() | Set-Content -Path $OutputPath -Encoding UTF8

$fileSize = (Get-Item $OutputPath).Length
$fileSizeKB = [math]::Round($fileSize / 1KB, 1)

# Generate SHA256 hash for integrity verification
$fileHash = Get-FileHash -Path $OutputPath -Algorithm SHA256
$hashPath = "$OutputPath.sha256"
"$($fileHash.Hash)  $(Split-Path $OutputPath -Leaf)" | Set-Content -Path $hashPath -Encoding UTF8

Write-Host ""
Write-Host "Build complete!" -ForegroundColor Green
Write-Host "  Output: $OutputPath" -ForegroundColor Gray
Write-Host "  Size: $fileSizeKB KB" -ForegroundColor Gray
Write-Host "  SHA256: $($fileHash.Hash)" -ForegroundColor Gray
Write-Host "  Hash file: $hashPath" -ForegroundColor Gray
