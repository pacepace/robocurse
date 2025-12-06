<#
.SYNOPSIS
    Test helper for loading Robocurse functions

.DESCRIPTION
    Provides a unified way to load Robocurse functions for testing.
    Supports loading from either:
    - The monolithic Robocurse.ps1 (if it exists)
    - The modular src/Robocurse/ structure

    Tests should dot-source this file instead of the main script directly.

.EXAMPLE
    BeforeAll {
        . $PSScriptRoot\TestHelper.ps1
        Initialize-RobocurseForTesting
    }
#>

function Initialize-RobocurseForTesting {
    <#
    .SYNOPSIS
        Loads Robocurse functions for testing
    .DESCRIPTION
        Loads from the module structure (src/Robocurse/) which is the source of truth.
        Falls back to dist/Robocurse.ps1 for CI testing of built artifacts.
    .PARAMETER UseBuiltMonolith
        If set, loads from dist/Robocurse.ps1 instead of modules (for testing builds)
    #>
    param(
        [switch]$UseBuiltMonolith
    )

    $testRoot = $PSScriptRoot
    $projectRoot = Split-Path -Parent $testRoot
    $modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
    $distPath = Join-Path $projectRoot "dist\Robocurse.ps1"

    # Determine which source to use
    $sourceToLoad = $null

    if ($UseBuiltMonolith) {
        # Test the built artifact
        if (Test-Path $distPath) {
            $sourceToLoad = $distPath
            Write-Verbose "Loading from dist: $distPath"
        }
        else {
            throw "Built monolith not found at: $distPath`nRun build/Build-Robocurse.ps1 first."
        }
    }
    else {
        # Default: load from modules (source of truth)
        if (Test-Path $modulePath) {
            $sourceToLoad = $modulePath
            Write-Verbose "Loading from module: $modulePath"
        }
        elseif (Test-Path $distPath) {
            Write-Warning "Modules not found, falling back to dist: $distPath"
            $sourceToLoad = $distPath
        }
        else {
            throw "Could not find Robocurse source. Checked:`n  - $modulePath`n  - $distPath"
        }
    }

    # Load the source
    if ($sourceToLoad -like "*.psm1") {
        # Import as module
        Import-Module $sourceToLoad -Force -Global -DisableNameChecking
    }
    else {
        # Dot-source the script
        . $sourceToLoad -Help
    }

    Write-Verbose "Robocurse loaded from: $sourceToLoad"
}

function Get-RobocurseTestRoot {
    <#
    .SYNOPSIS
        Returns the test root directory
    #>
    return $PSScriptRoot
}

function Get-RobocurseProjectRoot {
    <#
    .SYNOPSIS
        Returns the project root directory
    #>
    return Split-Path -Parent $PSScriptRoot
}

function New-TempTestDirectory {
    <#
    .SYNOPSIS
        Creates a temporary test directory
    .OUTPUTS
        Path to the created directory
    #>
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "Robocurse-Test-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
    return $tempPath
}

function Remove-TempTestDirectory {
    <#
    .SYNOPSIS
        Removes a temporary test directory
    .PARAMETER Path
        Path to remove
    #>
    param([string]$Path)

    if ($Path -and (Test-Path $Path) -and $Path -like "*Robocurse-Test-*") {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Export for module use (only when loaded as a module)
if ($MyInvocation.MyCommand.ScriptBlock.Module) {
    Export-ModuleMember -Function @(
        'Initialize-RobocurseForTesting'
        'Get-RobocurseTestRoot'
        'Get-RobocurseProjectRoot'
        'New-TempTestDirectory'
        'Remove-TempTestDirectory'
    )
}
