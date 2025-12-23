# Task: OperationResult Pattern Enforcement

## Objective
Create an enforcement test that ensures all functions returning success/failure results use the `New-OperationResult` pattern consistently, preventing raw hashtable drift.

## Problem Statement
VssRemote.ps1 contains functions that return raw hashtables:
```powershell
return @{ Success = $false; Error = "message" }
```

While the rest of the codebase uses the canonical pattern:
```powershell
return New-OperationResult -Success $false -ErrorMessage "message"
```

This causes:
- Consumer code checking `.ErrorMessage` fails when code returns `.Error`
- Inconsistent API surface across modules
- Harder to grep for error handling patterns

## Success Criteria
1. Enforcement test identifies all raw hashtable returns with `Success` key
2. Test provides file:line locations for each violation
3. Test runs in under 5 seconds
4. VssRemote.ps1 violations are fixed to use `New-OperationResult`
5. Test passes after fixes

## Research: Current Violations

### VssRemote.ps1 Violations (8 locations)
```
Line 475: return @{ Success = $false; Error = "Junction path already exists: $JunctionPath" }
Line 482: return @{ Success = $false; Error = "mklink failed: $output" }
Line 487: return @{ Success = $false; Error = "Junction created but not accessible" }
Line 490: return @{ Success = $true; JunctionPath = $JunctionPath }
Line 551: return @{ Success = $true; Message = "Junction already removed" }
Line 563: return @{ Success = $false; Error = "rmdir failed: $output" }
Line 568: return @{ Success = $false; Error = "Junction still exists after removal" }
Line 571: return @{ Success = $true }
```

These are in script blocks executed remotely via `Invoke-Command`. The consumer at line 494 handles this:
```powershell
if (-not $result.Success) {
    return New-OperationResult -Success $false -ErrorMessage "Failed to create remote junction: $($result.Error)"
}
```

### Canonical Pattern (from VssLocal.ps1, Utility.ps1, etc.)
```powershell
return New-OperationResult -Success $false -ErrorMessage "message" -ErrorRecord $_
return New-OperationResult -Success $true -Data $result
```

Properties available on OperationResult:
- `Success` (bool)
- `ErrorMessage` (string)
- `ErrorRecord` (ErrorRecord, optional)
- `Data` (object, optional)

## Implementation Plan

### Step 1: Create Enforcement Test Directory
```powershell
mkdir tests\Enforcement
```

### Step 2: Create OperationResult Enforcement Test
Create `tests/Enforcement/OperationResult.Tests.ps1`:

```powershell
#Requires -Modules Pester

<#
.SYNOPSIS
    Enforcement test for OperationResult pattern consistency
.DESCRIPTION
    Scans all PowerShell files for raw hashtable returns with Success key,
    which should use New-OperationResult instead.
#>

BeforeDiscovery {
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SourcePath = Join-Path $script:ProjectRoot "src\Robocurse\Public"
    $script:SourceFiles = Get-ChildItem -Path $script:SourcePath -Filter "*.ps1" -Recurse
}

Describe "OperationResult Pattern Enforcement" {

    Context "No raw hashtable Success returns" {

        It "Should not use raw @{ Success = } hashtables in <_.Name>" -ForEach $script:SourceFiles {
            $file = $_
            $content = Get-Content $file.FullName -Raw
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$null, [ref]$null
            )

            # Find all hashtable literals in return statements
            $violations = $ast.FindAll({
                param($node)

                # Must be a hashtable
                if ($node -isnot [System.Management.Automation.Language.HashtableAst]) {
                    return $false
                }

                # Must have a 'Success' key
                $hasSuccessKey = $node.KeyValuePairs | Where-Object {
                    $_.Item1.Value -eq 'Success'
                }
                if (-not $hasSuccessKey) { return $false }

                # Must be in a return statement
                $parent = $node.Parent
                while ($parent) {
                    if ($parent -is [System.Management.Automation.Language.ReturnStatementAst]) {
                        return $true
                    }
                    $parent = $parent.Parent
                }
                return $false
            }, $true)

            if ($violations.Count -gt 0) {
                $details = $violations | ForEach-Object {
                    "$($file.Name):$($_.Extent.StartLineNumber) - $($_.Extent.Text.Substring(0, [Math]::Min(60, $_.Extent.Text.Length)))..."
                }
                $violations.Count | Should -Be 0 -Because "Raw hashtable returns should use New-OperationResult:`n$($details -join "`n")"
            }
        }
    }

    Context "Allowed remote script blocks" {

        It "Documents known exceptions for remote Invoke-Command blocks" {
            # Remote script blocks cannot call module functions like New-OperationResult
            # These are acceptable IF the calling function wraps the result properly
            #
            # Known exceptions:
            # - VssRemote.ps1 lines 475-571 (remote junction create/remove)
            #
            # Verify the calling code properly wraps these:
            $vssRemotePath = Join-Path $script:SourcePath "VssRemote.ps1"
            $content = Get-Content $vssRemotePath -Raw

            # Check that New-Remote-VssJunction wraps the raw result
            $content | Should -Match 'New-OperationResult.*\$result\.Error' `
                -Because "Remote script block results must be wrapped with New-OperationResult"
        }
    }
}
```

### Step 3: Fix VssRemote.ps1 Violations

The remote script blocks cannot use `New-OperationResult` since it's not available in the remote session. However, we should:

1. **Standardize the error property name** in remote blocks to `ErrorMessage` (not `Error`)
2. **Document this exception** in the test

Update VssRemote.ps1 remote script blocks (lines 475-571):

```powershell
# BEFORE (inconsistent):
return @{ Success = $false; Error = "message" }

# AFTER (consistent property name):
return @{ Success = $false; ErrorMessage = "message" }
```

Update the caller at line 494:
```powershell
# BEFORE:
return New-OperationResult -Success $false -ErrorMessage "Failed to create remote junction: $($result.Error)"

# AFTER:
return New-OperationResult -Success $false -ErrorMessage "Failed to create remote junction: $($result.ErrorMessage)"
```

### Step 4: Update Enforcement Test for Exception

Add a "known exception" context that documents WHY remote blocks are different:

```powershell
Context "Known Exceptions - Remote Script Blocks" {
    It "VssRemote.ps1 remote blocks use consistent ErrorMessage property" {
        $vssRemotePath = Join-Path $script:SourcePath "VssRemote.ps1"
        $content = Get-Content $vssRemotePath -Raw

        # Remote blocks should use ErrorMessage, not Error
        $content | Should -Not -Match '@\{\s*Success\s*=.*;\s*Error\s*=' `
            -Because "Remote script blocks should use ErrorMessage property for consistency"
    }
}
```

## Test Plan

The enforcement test itself is the test. Run with:

```powershell
Invoke-Pester -Path tests\Enforcement\OperationResult.Tests.ps1 -Output Detailed
```

Expected output before fix:
```
[-] Should not use raw @{ Success = } hashtables in VssRemote.ps1
   Raw hashtable returns should use New-OperationResult:
   VssRemote.ps1:475 - @{ Success = $false; Error = "Junction path already...
   VssRemote.ps1:482 - @{ Success = $false; Error = "mklink failed: $outpu...
   ...
```

Expected output after fix:
```
[+] Should not use raw @{ Success = } hashtables in VssRemote.ps1
```

## Files to Modify
1. `tests/Enforcement/OperationResult.Tests.ps1` - New enforcement test
2. `src/Robocurse/Public/VssRemote.ps1` - Fix property name `Error` -> `ErrorMessage`

## Verification Commands
```powershell
# Run enforcement test
Invoke-Pester -Path tests\Enforcement\OperationResult.Tests.ps1 -Output Detailed

# Verify no regressions
.\scripts\run-tests.ps1
```

## Notes
- Remote script blocks (Invoke-Command -ScriptBlock) cannot use module functions
- The pattern is to use consistent property names (`ErrorMessage` not `Error`) in remote blocks
- Callers are responsible for wrapping remote results with `New-OperationResult`
- This enforcement test runs via AST parsing, no execution required
- Test completes in under 2 seconds
