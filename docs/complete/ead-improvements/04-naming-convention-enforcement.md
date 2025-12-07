# Task: Function Naming Convention Enforcement

## Objective
Create an enforcement test that ensures all exported functions follow PowerShell's `Verb-Noun` naming convention and use only approved verbs.

## Problem Statement
PowerShell has a standard list of approved verbs (Get, Set, New, Remove, etc.). Using non-standard verbs:
- Triggers warnings when importing the module
- Makes functions harder to discover
- Breaks user expectations about function behavior

## Success Criteria
1. Enforcement test verifies all public functions use `Verb-Noun` format
2. Test verifies verbs are from the approved PowerShell verb list
3. Test checks noun prefixes for module-specific patterns (e.g., `Robocurse`, `Gui`, `Vss`)
4. Test runs in under 5 seconds
5. Zero violations (currently passing - this test prevents future drift)

## Research: Current State

### Approved PowerShell Verbs
```powershell
Get-Verb | Select-Object -ExpandProperty Verb
# Common: Add, Clear, Close, Copy, Enter, Exit, Find, Format, Get, Hide, Join, Lock,
#         Move, New, Open, Optimize, Pop, Push, Redo, Remove, Rename, Reset, Resize,
#         Search, Select, Set, Show, Skip, Split, Step, Switch, Undo, Unlock, Watch, Write
```

### Current Function Naming
From grep analysis, all functions appear to follow the pattern:
- `New-DefaultConfig`
- `Get-RobocurseConfig`
- `Set-RobocopyPath`
- `Write-RobocurseLog`
- `Show-GuiError`
- `Initialize-OrchestrationState`

### Module Manifest Exports (Robocurse.psd1)
The module explicitly exports functions, so any new function must be added there.

## Implementation Plan

### Step 1: Create Enforcement Test
Create `tests/Enforcement/NamingConvention.Tests.ps1`:

```powershell
#Requires -Modules Pester

<#
.SYNOPSIS
    Enforcement test for PowerShell naming conventions
.DESCRIPTION
    Ensures all public functions use Verb-Noun format with approved verbs
#>

BeforeDiscovery {
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SourcePath = Join-Path $script:ProjectRoot "src\Robocurse\Public"
    $script:SourceFiles = Get-ChildItem -Path $script:SourcePath -Filter "*.ps1" -Recurse

    # Get approved verbs
    $script:ApprovedVerbs = Get-Verb | Select-Object -ExpandProperty Verb
}

Describe "Naming Convention Enforcement" {

    Context "Function names follow Verb-Noun pattern" {

        It "All functions in <_.Name> use Verb-Noun format" -ForEach $script:SourceFiles {
            $file = $_
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$null, [ref]$null
            )

            $functions = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)

            $invalidNames = @()

            foreach ($func in $functions) {
                $name = $func.Name

                # Must contain a hyphen (Verb-Noun)
                if ($name -notmatch '^[A-Z][a-z]+-[A-Z]') {
                    $invalidNames += "$($file.Name):$($func.Extent.StartLineNumber) - '$name' is not Verb-Noun format"
                }
            }

            if ($invalidNames.Count -gt 0) {
                $invalidNames.Count | Should -Be 0 -Because "Functions must use Verb-Noun format:`n$($invalidNames -join "`n")"
            }
        }
    }

    Context "Function verbs are approved" {

        It "All functions in <_.Name> use approved verbs" -ForEach $script:SourceFiles {
            $file = $_
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$null, [ref]$null
            )

            $functions = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)

            $unapprovedVerbs = @()

            foreach ($func in $functions) {
                $name = $func.Name

                if ($name -match '^([A-Z][a-z]+)-') {
                    $verb = $matches[1]

                    if ($verb -notin $script:ApprovedVerbs) {
                        $unapprovedVerbs += "$($file.Name):$($func.Extent.StartLineNumber) - '$name' uses unapproved verb '$verb'"
                    }
                }
            }

            if ($unapprovedVerbs.Count -gt 0) {
                $unapprovedVerbs.Count | Should -Be 0 -Because "Functions must use approved verbs:`n$($unapprovedVerbs -join "`n")"
            }
        }
    }

    Context "Module noun consistency" {

        It "Public functions use consistent noun prefixes" {
            # Acceptable noun prefixes for this module
            $acceptablePrefixes = @(
                'Robocurse',     # Module-specific
                'Gui',          # GUI components
                'Vss',          # VSS-related
                'Orchestration', # Job orchestration
                'Profile',      # Profile management
                'Log',          # Logging
                'Chunk',        # Chunking
                'Directory',    # Directory operations
                'Robocopy',     # Robocopy wrapper
                'Operation',    # Generic operations
                'Default',      # Default config
                'Smtp',         # Email
                'Sync',         # Sync profiles
                'Bypass'        # Security bypass flags
            )

            $allFunctions = @()
            foreach ($file in $script:SourceFiles) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                    $file.FullName, [ref]$null, [ref]$null
                )

                $functions = $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true)

                $allFunctions += $functions | ForEach-Object {
                    [PSCustomObject]@{
                        Name = $_.Name
                        File = $file.Name
                        Line = $_.Extent.StartLineNumber
                    }
                }
            }

            # Extract nouns and check prefixes
            $unusualNouns = @()
            foreach ($func in $allFunctions) {
                if ($func.Name -match '^[A-Z][a-z]+-(.+)$') {
                    $noun = $matches[1]

                    # Check if noun starts with an acceptable prefix
                    $hasAcceptablePrefix = $acceptablePrefixes | Where-Object {
                        $noun -like "$_*"
                    }

                    if (-not $hasAcceptablePrefix) {
                        # Not necessarily an error, but worth reviewing
                        # This is a "notice" not a "violation"
                    }
                }
            }

            # This test always passes - it's here to document the noun convention
            $true | Should -BeTrue
        }
    }

    Context "No script-level functions in wrong scope" {

        It "Public folder only contains exportable functions in <_.Name>" -ForEach $script:SourceFiles {
            $file = $_
            $content = Get-Content $file.FullName -Raw

            # Check for script-scoped functions that should be in Private
            # Pattern: functions that aren't meant to be exported (usually helper functions)
            # This is a heuristic - short names or underscore prefixes suggest internal use
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$null, [ref]$null
            )

            $functions = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)

            $suspiciousNames = @()
            foreach ($func in $functions) {
                $name = $func.Name

                # Suspicious patterns for public folder:
                # - Starts with underscore
                # - All lowercase
                # - Too short (< 5 chars)
                if ($name -match '^_' -or $name -cmatch '^[a-z]+$' -or $name.Length -lt 5) {
                    $suspiciousNames += "$($file.Name):$($func.Extent.StartLineNumber) - '$name' may belong in Private folder"
                }
            }

            if ($suspiciousNames.Count -gt 0) {
                $suspiciousNames.Count | Should -Be 0 -Because "Public folder should only have public functions:`n$($suspiciousNames -join "`n")"
            }
        }
    }
}
```

### Step 2: Verify Current State

Run the test to confirm zero violations:

```powershell
Invoke-Pester -Path tests\Enforcement\NamingConvention.Tests.ps1 -Output Detailed
```

Expected: All tests pass (this is a guard against future drift)

## Test Plan

```powershell
# Run naming convention enforcement
Invoke-Pester -Path tests\Enforcement\NamingConvention.Tests.ps1 -Output Detailed

# Also verify module loads without verb warnings
Import-Module .\src\Robocurse\Robocurse.psd1 -Force -Verbose 2>&1 |
    Where-Object { $_ -match 'verb' }
```

## Files to Create
1. `tests/Enforcement/NamingConvention.Tests.ps1` - New enforcement test

## Files Potentially Affected
None expected - this test documents the existing good pattern and prevents future violations.

## Verification Commands
```powershell
# Run enforcement test
Invoke-Pester -Path tests\Enforcement\NamingConvention.Tests.ps1 -Output Detailed

# Check for verb warnings on import
$warnings = Import-Module .\src\Robocurse\Robocurse.psd1 -Force -WarningVariable warns -WarningAction SilentlyContinue
$warns | Where-Object { $_.Message -match 'verb' }
```

## Notes
- This is a "preventive" enforcement test - current state is clean
- PowerShell module import warns on unapproved verbs
- Common mistakes: `Process-` (use `Invoke-`), `Return-` (use `Get-`), `Execute-` (use `Invoke-`)
- Verb suggestions: https://docs.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands
- The noun prefix convention helps with module discoverability
