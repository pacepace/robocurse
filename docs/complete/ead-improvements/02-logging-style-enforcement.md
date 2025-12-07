# Task: Logging Parameter Style Enforcement

## Objective
Create an enforcement test that ensures all `Write-RobocurseLog` calls use consistent parameter style: quoted strings for `-Level` and explicit `-Component` parameter.

## Problem Statement
Logging calls throughout the codebase use inconsistent parameter styles:

**Style A (Correct - Quoted with Component):**
```powershell
Write-RobocurseLog -Message "text" -Level 'Debug' -Component 'VSS'
```

**Style B (Incorrect - Bareword):**
```powershell
Write-RobocurseLog "text" -Level Debug
```

**Style C (Incorrect - Missing Component):**
```powershell
Write-RobocurseLog -Message "text" -Level 'Debug'
```

This inconsistency causes:
- Harder to grep for logging patterns
- Inconsistent log output (missing component context)
- Potential issues if `Debug` becomes a reserved word or variable

## Success Criteria
1. Enforcement test identifies bareword `-Level` parameters
2. Enforcement test identifies missing `-Component` parameters
3. Test provides file:line locations for each violation
4. Test runs in under 5 seconds
5. All violations are fixed
6. Test passes after fixes

## Research: Current State

### Logging Pattern Analysis
```
Quoted -Level 'String' with -Component: ~100 occurrences (correct)
Bareword -Level Debug: ~50 occurrences (incorrect)
Missing -Component: Variable (some files don't use it)
```

### Files with Bareword -Level (from grep)
- `Chunking.ps1` - uses `-Level Debug` (bareword)
- `DirectoryProfiling.ps1` - uses `-Level Debug` (bareword)

### Files with Correct Pattern
- `VssLocal.ps1` - uses `-Level 'Debug' -Component 'VSS'`
- `Email.ps1` - uses `-Level 'Warning' -Component 'Email'`
- `VssCore.ps1` - uses `-Level 'Debug' -Component 'VSS'`

### Write-RobocurseLog Signature (from Logging.ps1)
```powershell
function Write-RobocurseLog {
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [Parameter()]
        [string]$Component = 'General'
    )
}
```

## Implementation Plan

### Step 1: Create Enforcement Test
Create `tests/Enforcement/LoggingStyle.Tests.ps1`:

```powershell
#Requires -Modules Pester

<#
.SYNOPSIS
    Enforcement test for Write-RobocurseLog call consistency
.DESCRIPTION
    Ensures all logging calls use:
    1. Quoted string for -Level parameter
    2. Explicit -Component parameter
#>

BeforeDiscovery {
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SourcePath = Join-Path $script:ProjectRoot "src\Robocurse\Public"
    $script:SourceFiles = Get-ChildItem -Path $script:SourcePath -Filter "*.ps1" -Recurse |
        Where-Object { $_.Name -ne 'Logging.ps1' }  # Exclude the logging module itself
}

Describe "Logging Style Enforcement" {

    Context "Level parameter uses quoted strings" {

        It "Should use quoted -Level in <_.Name>" -ForEach $script:SourceFiles {
            $file = $_
            $content = Get-Content $file.FullName -Raw

            # Pattern for bareword -Level (not quoted)
            # Matches: -Level Debug  but not: -Level 'Debug' or -Level "Debug"
            $barewordPattern = '-Level\s+(?![\x27"])([A-Za-z]+)(?!\s*[\x27"])'

            $matches = [regex]::Matches($content, $barewordPattern)

            if ($matches.Count -gt 0) {
                # Get line numbers for violations
                $lines = $content -split "`n"
                $violations = @()

                foreach ($match in $matches) {
                    $lineNum = ($content.Substring(0, $match.Index) -split "`n").Count
                    $violations += "$($file.Name):$lineNum - $($match.Value)"
                }

                $matches.Count | Should -Be 0 -Because "Level parameter should be quoted:`n$($violations -join "`n")"
            }
        }
    }

    Context "Component parameter is explicit" {

        It "Should include -Component in <_.Name>" -ForEach $script:SourceFiles {
            $file = $_
            $content = Get-Content $file.FullName -Raw

            # Find all Write-RobocurseLog calls
            $logCallPattern = 'Write-RobocurseLog\s+[^`n]*'
            $logCalls = [regex]::Matches($content, $logCallPattern)

            $missingComponent = @()
            $lines = $content -split "`n"

            foreach ($call in $logCalls) {
                # Check if call includes -Component
                if ($call.Value -notmatch '-Component') {
                    $lineNum = ($content.Substring(0, $call.Index) -split "`n").Count
                    $callPreview = $call.Value.Substring(0, [Math]::Min(60, $call.Value.Length))
                    $missingComponent += "$($file.Name):$lineNum - $callPreview..."
                }
            }

            if ($missingComponent.Count -gt 0) {
                $missingComponent.Count | Should -Be 0 -Because "Write-RobocurseLog calls should include -Component:`n$($missingComponent -join "`n")"
            }
        }
    }
}
```

### Step 2: Fix Violations in Chunking.ps1

Before:
```powershell
Write-RobocurseLog "Analyzing directory at depth $CurrentDepth : $Path" -Level Debug
```

After:
```powershell
Write-RobocurseLog -Message "Analyzing directory at depth $CurrentDepth : $Path" -Level 'Debug' -Component 'Chunking'
```

### Step 3: Fix Violations in DirectoryProfiling.ps1

Before:
```powershell
Write-RobocurseLog "Using cached profile for: $Path" -Level Debug
```

After:
```powershell
Write-RobocurseLog -Message "Using cached profile for: $Path" -Level 'Debug' -Component 'Profiling'
```

### Step 4: Bulk Fix Script (Optional Helper)

For mass fixing, this regex replacement helps:
```powershell
# Find: Write-RobocurseLog\s+(".*?")\s+-Level\s+(\w+)\s*$
# Replace: Write-RobocurseLog -Message $1 -Level '$2' -Component 'TODO'
```

## Test Plan

The enforcement test itself is the test:

```powershell
Invoke-Pester -Path tests\Enforcement\LoggingStyle.Tests.ps1 -Output Detailed
```

Expected output before fix:
```
[-] Should use quoted -Level in Chunking.ps1
   Level parameter should be quoted:
   Chunking.ps1:72 - -Level Debug
   Chunking.ps1:79 - -Level Debug
   ...

[-] Should include -Component in Chunking.ps1
   Write-RobocurseLog calls should include -Component:
   Chunking.ps1:72 - Write-RobocurseLog "Analyzing directory at depth...
   ...
```

## Files to Modify
1. `tests/Enforcement/LoggingStyle.Tests.ps1` - New enforcement test
2. `src/Robocurse/Public/Chunking.ps1` - Fix logging calls
3. `src/Robocurse/Public/DirectoryProfiling.ps1` - Fix logging calls
4. Any other files identified by test

## Verification Commands
```powershell
# Run enforcement test
Invoke-Pester -Path tests\Enforcement\LoggingStyle.Tests.ps1 -Output Detailed

# Verify no regressions
.\scripts\run-tests.ps1
```

## Notes
- Quoted strings prevent potential issues with reserved words
- Explicit `-Component` improves log filtering and debugging
- `-Message` parameter name should be explicit for clarity
- Test uses regex for speed (faster than AST for this pattern)
- Estimated fix: ~50 lines across 2-3 files
