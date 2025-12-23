# Task 03: Directory Profiling

## Overview
Implement fast directory size/file count scanning using `robocopy /L` (list-only mode) to profile directories without copying.

## Research Required

### Web Research
- `robocopy /L /E /NJH /NJS /BYTES` output format
- Robocopy exit codes (0-16 bitmask meanings)
- Performance: robocopy /L vs Get-ChildItem -Recurse for large directories
- UNC path handling in PowerShell

### Key Concepts
- `/L` = List only, don't copy
- `/E` = Include empty subdirectories
- `/NJH` = No job header
- `/NJS` = No job summary
- `/BYTES` = Print sizes in bytes (easier to parse)
- `/R:0 /W:0` = No retries (faster scanning)

### Robocopy /L Output Format
```
                4096    \\server\users$\Anderson.John\Documents\
          123456789    \\server\users$\Anderson.John\Documents\report.docx
            1048576    \\server\users$\Anderson.John\Documents\photo.jpg
```

## Task Description

Implement the Directory Profiling region:

### Function: Get-DirectoryProfile
```powershell
function Get-DirectoryProfile {
    <#
    .SYNOPSIS
        Gets size and file count for a directory using robocopy /L
    .PARAMETER Path
        Directory path to profile
    .PARAMETER UseCache
        Check cache before scanning (default: true)
    .PARAMETER CacheMaxAgeHours
        Max cache age in hours (default: 24)
    .OUTPUTS
        PSCustomObject with: Path, TotalSize, FileCount, DirCount, AvgFileSize, LastScanned
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [bool]$UseCache = $true,

        [int]$CacheMaxAgeHours = 24
    )
    # Implementation here
}
```

**Implementation Notes:**
- Run `robocopy "$Path" "\\?\NULL" /L /E /NJH /NJS /BYTES /R:0 /W:0`
- `\\?\NULL` is a null destination that works on Windows
- Parse output lines to extract file sizes
- Sum sizes, count files
- Cache result for future use

### Function: Invoke-RobocopyList
```powershell
function Invoke-RobocopyList {
    <#
    .SYNOPSIS
        Runs robocopy in list-only mode (wrapper for testing/mocking)
    .PARAMETER Source
        Source path to list
    .OUTPUTS
        Array of output lines from robocopy
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Source
    )
    # Wrapper so we can mock this in tests
    $output = & robocopy $Source "\\?\NULL" /L /E /NJH /NJS /BYTES /R:0 /W:0 2>&1
    return $output
}
```

### Function: Parse-RobocopyListOutput
```powershell
function Parse-RobocopyListOutput {
    <#
    .SYNOPSIS
        Parses robocopy /L output to extract file info
    .PARAMETER Output
        Array of robocopy output lines
    .OUTPUTS
        PSCustomObject with TotalSize, FileCount, Files (array of file info)
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Output
    )
    # Implementation here
}
```

**Parsing Logic:**
```
Lines starting with whitespace + number = files
    "          123456789    path\to\file.txt"
    → Size: 123456789, Path: path\to\file.txt

Lines ending with \ = directories (size shown is usually 0 or dir entry size)
    "                0    path\to\directory\"
    → Directory, don't count as file

Sample count / variance calculation for chunk sizing
```

### Function: Get-DirectoryChildren
```powershell
function Get-DirectoryChildren {
    <#
    .SYNOPSIS
        Gets immediate child directories of a path
    .PARAMETER Path
        Parent directory path
    .OUTPUTS
        Array of child directory paths
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    # Implementation - simpler than profiling, just Get-ChildItem -Directory
}
```

### Function: Get-CachedProfile
```powershell
function Get-CachedProfile {
    <#
    .SYNOPSIS
        Retrieves cached directory profile if valid
    .PARAMETER Path
        Directory path
    .PARAMETER MaxAgeHours
        Maximum cache age
    .OUTPUTS
        Cached profile or $null
    #>
    param(
        [string]$Path,
        [int]$MaxAgeHours = 24
    )
    # Check script-level cache hashtable
}
```

### Function: Set-CachedProfile
```powershell
function Set-CachedProfile {
    <#
    .SYNOPSIS
        Stores directory profile in cache
    .PARAMETER Profile
        Profile object to cache
    #>
    param(
        [PSCustomObject]$Profile
    )
    # Store in script-level cache hashtable
}
```

### Cache Structure
```powershell
$script:ProfileCache = @{
    "\\server\users$\Anderson.John" = @{
        TotalSize = 5368709120
        FileCount = 12500
        DirCount = 450
        AvgFileSize = 429496
        LastScanned = [datetime]"2024-01-15T14:32:45"
    }
}
```

## Success Criteria

1. [ ] `Invoke-RobocopyList` runs robocopy /L without errors
2. [ ] `Parse-RobocopyListOutput` correctly extracts file sizes
3. [ ] `Parse-RobocopyListOutput` correctly counts files vs directories
4. [ ] `Get-DirectoryProfile` returns accurate size/count
5. [ ] Cache prevents redundant scans within age limit
6. [ ] Handles UNC paths correctly
7. [ ] Handles paths with spaces and special characters
8. [ ] Handles empty directories
9. [ ] Handles access denied errors gracefully

## Pester Tests Required

Create `tests/Unit/DirectoryProfiling.Tests.ps1`:

```powershell
Describe "Directory Profiling" {
    BeforeAll {
        . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
    }

    Context "Parse-RobocopyListOutput" {
        It "Should extract file sizes correctly" {
            $output = @(
                "          1000    test\file1.txt",
                "          2000    test\file2.txt",
                "             0    test\subdir\"
            )

            $result = Parse-RobocopyListOutput -Output $output

            $result.TotalSize | Should -Be 3000
            $result.FileCount | Should -Be 2
        }

        It "Should not count directories as files" {
            $output = @(
                "          1000    test\file.txt",
                "             0    test\dir1\",
                "             0    test\dir2\"
            )

            $result = Parse-RobocopyListOutput -Output $output

            $result.FileCount | Should -Be 1
            $result.DirCount | Should -Be 2
        }

        It "Should handle empty output" {
            $output = @()

            $result = Parse-RobocopyListOutput -Output $output

            $result.TotalSize | Should -Be 0
            $result.FileCount | Should -Be 0
        }

        It "Should handle large file sizes" {
            $output = @(
                "   10737418240    test\largefile.iso"  # 10 GB
            )

            $result = Parse-RobocopyListOutput -Output $output

            $result.TotalSize | Should -Be 10737418240
        }
    }

    Context "Get-DirectoryProfile" {
        BeforeEach {
            # Clear cache
            $script:ProfileCache = @{}
        }

        It "Should call robocopy and parse output" {
            Mock Invoke-RobocopyList {
                return @(
                    "          1000    file1.txt",
                    "          2000    file2.txt"
                )
            }

            $result = Get-DirectoryProfile -Path "C:\Test" -UseCache $false

            $result.TotalSize | Should -Be 3000
            $result.FileCount | Should -Be 2
            Should -Invoke Invoke-RobocopyList -Times 1
        }

        It "Should use cache when available" {
            Mock Invoke-RobocopyList { return @() }

            # First call - populates cache
            $result1 = Get-DirectoryProfile -Path "C:\Test" -UseCache $true
            # Second call - should use cache
            $result2 = Get-DirectoryProfile -Path "C:\Test" -UseCache $true

            Should -Invoke Invoke-RobocopyList -Times 1  # Only called once
        }

        It "Should skip cache when disabled" {
            Mock Invoke-RobocopyList { return @("          1000    file.txt") }

            Get-DirectoryProfile -Path "C:\Test" -UseCache $false
            Get-DirectoryProfile -Path "C:\Test" -UseCache $false

            Should -Invoke Invoke-RobocopyList -Times 2  # Called twice
        }
    }

    Context "Get-DirectoryChildren" {
        It "Should return child directories" {
            $testDir = New-Item -Path "$TestDrive\Parent" -ItemType Directory
            New-Item -Path "$testDir\Child1" -ItemType Directory
            New-Item -Path "$testDir\Child2" -ItemType Directory
            New-Item -Path "$testDir\file.txt" -ItemType File

            $result = Get-DirectoryChildren -Path $testDir.FullName

            $result.Count | Should -Be 2
            $result | Should -Contain "$testDir\Child1"
            $result | Should -Contain "$testDir\Child2"
        }
    }
}
```

## Edge Cases to Handle

1. **Very long paths**: Use `\\?\` prefix for paths > 260 chars
2. **Access denied**: Log warning, return partial results or zeroes
3. **Network timeout**: Set reasonable timeout, retry once
4. **Empty directories**: Return 0 size, 0 files (valid result)
5. **Symbolic links/junctions**: Skip to avoid infinite loops (robocopy handles this with /XJ)

## Dependencies
- Task 00 (Project Structure)
- Task 02 (Logging) - for logging scan progress/errors

## Estimated Complexity
- Medium
- External process interaction, output parsing
