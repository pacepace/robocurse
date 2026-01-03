# Task: Path Validation Fix for Ampersand

## Objective
Fix the `Test-SafeRobocopyArgument` function to allow ampersand (`&`) in paths, which is a valid Windows filename character commonly used in business names (AT&T, R&D, Ben & Jerry's).

## Problem Statement
Log shows:
```
2025-12-31 10:54:29 [WARNING] [Security] [Test-SafeRobocopyArgument:551] Rejected unsafe argument containing pattern '[;&|]': Y:\AT&T
```

The regex pattern `[;&|]` blocks the `&` character, but:
1. `&` is a valid NTFS filename character
2. Robocopy is called via `Start-Process`, not shell interpretation
3. Common business names use `&` (AT&T, R&D, Ben & Jerry's)

## Success Criteria
1. `Y:\AT&T` passes validation
2. `C:\R&D\Projects` passes validation
3. `D:\Ben & Jerry's` passes validation
4. Semicolon `;` still blocked (rare in filenames, potential injection)
5. Pipe `|` still blocked (invalid Windows character anyway)
6. All existing security protections remain intact
7. All tests pass

## Research: Current Implementation

### Test-SafeRobocopyArgument (Utility.ps1:274-329)
```powershell
$dangerousPatterns = @(
    '[\x00-\x1F]',           # Control characters (null, newline, etc.)
    '[;&|]',                  # Command separators  <-- PROBLEM
    '[<>]',                   # Shell redirectors
    '`',                      # Backtick (PowerShell escape/execution)
    '\$\(',                   # Command substitution
    '\$\{',                   # Variable expansion with braces
    '%[^%]+%',                # Environment variable expansion (cmd.exe style)
    '(^|[/\\])\.\.([/\\]|$)', # Parent directory traversal
    '^\s*-'                   # Arguments starting with dash
)
```

### Security Analysis
| Character | Valid in Windows? | Actually Dangerous? |
|-----------|-------------------|---------------------|
| `;` | YES (rare) | Keep blocking (injection) |
| `&` | **YES** (common) | **NO** - Start-Process doesn't interpret |
| `\|` | NO (invalid) | Keep blocking |

### How Robocopy is Called (Robocopy.ps1:505+)
```powershell
$process = Start-Process -FilePath $RobocopyExe -ArgumentList $argList ...
```
Since `Start-Process` is used (not `Invoke-Expression` or `cmd /c`), shell metacharacters are passed literally, not interpreted.

## Implementation Plan

### Step 1: Update Dangerous Patterns
Change `[;&|]` to separate patterns:

**Before (Utility.ps1:310):**
```powershell
'[;&|]',                  # Command separators
```

**After:**
```powershell
'[;<>]',                  # Semicolon (rare, potential injection) and shell redirectors
'\|',                     # Pipe (invalid in Windows paths anyway)
```

This:
- Removes `&` from blocked characters
- Combines `;` with `<>` in one character class
- Keeps `|` as separate pattern (already invalid in Windows)

### Step 2: Update Comment
Update the comment block to explain the change:

```powershell
# Check for dangerous patterns that could enable command injection
# Note: & is NOT blocked because:
# 1. It's a valid Windows filename character (AT&T, R&D, etc.)
# 2. We use Start-Process, not Invoke-Expression, so shell metacharacters aren't interpreted
$dangerousPatterns = @(
    '[\x00-\x1F]',           # Control characters (null, newline, etc.)
    '[;<>]',                  # Semicolon (rare), shell redirectors (< > invalid in paths)
    '\|',                     # Pipe (invalid in Windows paths anyway)
    '`',                      # Backtick (PowerShell escape/execution)
    '\$\(',                   # Command substitution
    '\$\{',                   # Variable expansion with braces
    '%[^%]+%',                # Environment variable expansion (cmd.exe style)
    '(^|[/\\])\.\.([/\\]|$)', # Parent directory traversal at path boundaries
    '^\s*-'                   # Arguments starting with dash (could inject robocopy flags)
)
```

## Test Plan

### Update Utility.Tests.ps1 (lines 64-67)

**Before:**
```powershell
It "Should reject command separators" {
    Test-SafeRobocopyArgument -Value "path; del *" | Should -Be $false
    Test-SafeRobocopyArgument -Value "path & calc" | Should -Be $false
    Test-SafeRobocopyArgument -Value "path | cmd" | Should -Be $false
}
```

**After:**
```powershell
It "Should allow ampersand in paths (valid Windows character)" {
    Test-SafeRobocopyArgument -Value "Y:\AT&T" | Should -Be $true
    Test-SafeRobocopyArgument -Value "C:\R&D" | Should -Be $true
    Test-SafeRobocopyArgument -Value "D:\Ben & Jerry's" | Should -Be $true
    Test-SafeRobocopyArgument -Value "C:\path & more" | Should -Be $true
}

It "Should reject semicolon (potential injection)" {
    Test-SafeRobocopyArgument -Value "path; del *" | Should -Be $false
    Test-SafeRobocopyArgument -Value "C:\data;backup" | Should -Be $false
}

It "Should reject pipe (invalid Windows character)" {
    Test-SafeRobocopyArgument -Value "path | cmd" | Should -Be $false
    Test-SafeRobocopyArgument -Value "C:\bad|path" | Should -Be $false
}
```

### Update RobocopyWrapper.Tests.ps1 (lines 958-967)

**Before:**
```powershell
It "Should reject command separator semicolon" {
    Test-SafeRobocopyArgument -Value "C:\path; del *" | Should -Be $false
}

It "Should reject command separator ampersand" {
    Test-SafeRobocopyArgument -Value "C:\path & malicious" | Should -Be $false
}

It "Should reject command separator pipe" {
    Test-SafeRobocopyArgument -Value "C:\path | format C:" | Should -Be $false
}
```

**After:**
```powershell
It "Should reject command separator semicolon" {
    Test-SafeRobocopyArgument -Value "C:\path; del *" | Should -Be $false
}

It "Should allow ampersand in paths (valid Windows character)" {
    Test-SafeRobocopyArgument -Value "C:\AT&T\Data" | Should -Be $true
    Test-SafeRobocopyArgument -Value "D:\R&D\Projects" | Should -Be $true
}

It "Should reject command separator pipe" {
    Test-SafeRobocopyArgument -Value "C:\path | format C:" | Should -Be $false
}
```

## Files to Modify
1. `src/Robocurse/Public/Utility.ps1` - Line 310: Change `[;&|]` to `[;<>]` + `'\|'`
2. `tests/Unit/Utility.Tests.ps1` - Lines 64-67: Update command separator tests
3. `tests/Unit/RobocopyWrapper.Tests.ps1` - Lines 958-967: Update command separator tests

## Verification Commands
```powershell
# Run tests
.\scripts\run-tests.ps1

# Quick verification
Import-Module .\src\Robocurse\Robocurse.psm1 -Force
Test-SafeRobocopyArgument -Value "Y:\AT&T"          # Should be $true
Test-SafeRobocopyArgument -Value "C:\R&D"           # Should be $true
Test-SafeRobocopyArgument -Value "D:\Ben & Jerry's" # Should be $true
Test-SafeRobocopyArgument -Value "path; del *"      # Should be $false
Test-SafeRobocopyArgument -Value "C:\bad|path"      # Should be $false
```

## Notes
- This is a minimal, targeted fix that only allows `&`
- All other security patterns remain intact
- The `|` character is invalid in Windows paths anyway, so blocking it is harmless
- Semicolon `;` is technically valid but extremely rare in real paths, keeping it blocked is safe
