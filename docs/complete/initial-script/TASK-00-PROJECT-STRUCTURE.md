# Task 00: Project Structure and Testing Framework

## Overview
Set up the project structure, Pester testing framework, and the main script skeleton with region placeholders.

## Research Required

### Web Research
- Pester framework basics: https://pester.dev/docs/quick-start
- PowerShell module structure best practices
- Pester mocking for external commands (robocopy, cmdkey)

### Key Concepts
- Pester v5 syntax (different from v4)
- `BeforeAll`, `BeforeEach`, `It`, `Should` blocks
- Mocking with `Mock` command
- Test file naming: `*.Tests.ps1`

## Task Description

Create the foundational project structure:

```
robocurse/
├── Robocurse.ps1              # Main script (skeleton with regions)
├── Robocurse.config.json      # Example config file
├── tests/
│   ├── Robocurse.Tests.ps1    # Main test file
│   ├── Unit/
│   │   ├── Configuration.Tests.ps1
│   │   ├── Logging.Tests.ps1
│   │   ├── Chunking.Tests.ps1
│   │   └── ... (one per module)
│   └── Integration/
│       └── EndToEnd.Tests.ps1
├── docs/
│   └── (task files)
└── README.md
```

### Main Script Skeleton

Create `Robocurse.ps1` with these regions (empty functions with proper signatures):

```powershell
#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Robocurse - Multi-share parallel robocopy orchestrator
.DESCRIPTION
    Manages multiple robocopy instances to replicate large directory
    structures that would otherwise overwhelm a single robocopy process.
#>

param(
    [switch]$Headless,
    [string]$ConfigPath = ".\Robocurse.config.json",
    [string]$Profile,
    [switch]$Help
)

#region ==================== CONFIGURATION ====================
# Functions: Get-RobocurseConfig, Save-RobocurseConfig, Test-RobocurseConfig
#endregion

#region ==================== LOGGING ====================
# Functions: Write-RobocurseLog, Write-SiemEvent, Invoke-LogRotation
#endregion

#region ==================== DIRECTORY PROFILING ====================
# Functions: Get-DirectoryProfile, Get-DirectorySize
#endregion

#region ==================== CHUNKING ====================
# Functions: Get-DirectoryChunks, Split-LargeDirectory
#endregion

#region ==================== ROBOCOPY WRAPPER ====================
# Functions: Start-RobocopyJob, Get-RobocopyExitMeaning, Parse-RobocopyLog
#endregion

#region ==================== ORCHESTRATION ====================
# Functions: Start-ReplicationRun, Invoke-ReplicationTick, Stop-AllJobs
#endregion

#region ==================== PROGRESS ====================
# Functions: Get-ChunkProgress, Update-OverallProgress, Get-ETAEstimate
#endregion

#region ==================== VSS ====================
# Functions: New-VssSnapshot, Remove-VssSnapshot, Get-VssPath
#endregion

#region ==================== EMAIL ====================
# Functions: Get-SmtpCredential, Save-SmtpCredential, Send-CompletionEmail
#endregion

#region ==================== SCHEDULING ====================
# Functions: Register-RobocurseTask, Unregister-RobocurseTask
#endregion

#region ==================== GUI ====================
# WPF XAML and GUI functions (largest section)
#endregion

#region ==================== MAIN ====================
# Entry point logic
#endregion
```

### Pester Test Skeleton

Create `tests/Robocurse.Tests.ps1`:

```powershell
BeforeAll {
    # Dot-source the main script to load functions
    # We'll need to handle the GUI not launching during tests
    $script:TestMode = $true
    . "$PSScriptRoot\..\Robocurse.ps1" -Help  # Load without executing
}

Describe "Robocurse" {
    Context "Configuration" {
        It "Should load valid config file" {
            # Test will be in Unit/Configuration.Tests.ps1
        }
    }

    Context "Logging" {
        It "Should write operational log" {
            # Test will be in Unit/Logging.Tests.ps1
        }
    }
}
```

## Success Criteria

1. [ ] `Robocurse.ps1` exists with all region placeholders
2. [ ] `tests/` directory structure exists
3. [ ] Running `Invoke-Pester ./tests` completes without errors (tests can be pending/skipped)
4. [ ] `Robocurse.config.json` example file exists with full schema
5. [ ] README.md updated with:
   - Project description
   - How to run tests: `Invoke-Pester ./tests -Output Detailed`
   - How to run the tool

## Testing Notes

### Making Code Testable
- All external calls (robocopy, cmdkey, WMI) should be in small wrapper functions that can be mocked
- Avoid direct `Write-Host` - use a logging function that can be mocked
- GUI code should be separated from logic code
- Use dependency injection pattern where possible

### Example Testable Pattern
```powershell
# BAD - hard to test
function Start-Sync {
    $output = robocopy $src $dst /MIR
    Write-Host "Done: $output"
}

# GOOD - testable
function Invoke-Robocopy {
    param($Source, $Destination, $Args)
    & robocopy $Source $Destination @Args
}

function Start-Sync {
    param($Source, $Destination)
    $output = Invoke-Robocopy -Source $Source -Destination $Destination -Args @('/MIR')
    Write-RobocurseLog -Message "Done: $output"
}

# Test can mock Invoke-Robocopy
Mock Invoke-Robocopy { return "Mocked output" }
```

## Dependencies
- None (this is the first task)

## Estimated Complexity
- Low-Medium
- Mostly boilerplate and structure
