# Task 04: Recursive Directory Chunking

## Overview
Implement the recursive algorithm that splits large directory trees into manageable chunks based on size and file count thresholds. This is the core logic that makes robocopy work on massive directory structures.

## Research Required

### Web Research
- Tree traversal algorithms (depth-first)
- Bin packing problem basics
- PowerShell recursive function patterns
- Handling files at intermediate directory levels

### Key Concepts
- **Chunk**: A directory path that will become one robocopy job
- **Threshold-based splitting**: Split only when size/count exceeds limits
- **Depth limiting**: Don't recurse forever
- **Files-at-level**: Directories that have both files AND subdirectories

## Task Description

### The Problem
```
\\server\users$\Anderson.John\           (50 GB total - TOO BIG)
├── Documents\                           (2 GB - OK as chunk)
├── Desktop\                             (500 MB - OK as chunk)
├── Downloads\                           (15 GB - needs splitting)
│   ├── 2023\                            (8 GB - OK as chunk)
│   └── 2024\                            (7 GB - OK as chunk)
├── AppData\                             (30 GB - needs splitting)
│   ├── Local\                           (20 GB - needs splitting)
│   │   ├── Microsoft\                   (5 GB - OK as chunk)
│   │   ├── Google\                      (8 GB - OK as chunk)
│   │   └── Temp\                        (7 GB - OK as chunk)
│   └── Roaming\                         (10 GB - OK as chunk)
└── random_file.txt                      (100 KB - files at root!)
```

### Function: Get-DirectoryChunks
```powershell
function Get-DirectoryChunks {
    <#
    .SYNOPSIS
        Recursively splits a directory tree into manageable chunks
    .PARAMETER Path
        Root path to chunk
    .PARAMETER DestinationRoot
        Destination root (for building destination paths)
    .PARAMETER MaxSizeBytes
        Maximum size per chunk (default: 10GB)
    .PARAMETER MaxFiles
        Maximum files per chunk (default: 50000)
    .PARAMETER MaxDepth
        Maximum recursion depth (default: 5)
    .PARAMETER MinSizeBytes
        Minimum size to create a chunk (default: 100MB)
    .PARAMETER CurrentDepth
        Current recursion depth (internal use)
    .OUTPUTS
        Array of chunk objects
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DestinationRoot,

        [int64]$MaxSizeBytes = 10GB,
        [int]$MaxFiles = 50000,
        [int]$MaxDepth = 5,
        [int64]$MinSizeBytes = 100MB,
        [int]$CurrentDepth = 0
    )
    # Implementation here
}
```

### Chunk Object Structure
```powershell
[PSCustomObject]@{
    ChunkId          = 1
    SourcePath       = "\\server\users$\Anderson.John\Documents"
    DestinationPath  = "D:\Backup\Users\Anderson.John\Documents"
    EstimatedSize    = 2147483648  # 2 GB
    EstimatedFiles   = 5000
    Depth            = 2
    IsFilesOnly      = $false      # True if copying only files at this level
    Status           = "Pending"   # Pending, Running, Complete, Failed
    RobocopyArgs     = @()         # Additional args like /LEV:1 for files-only
}
```

### Algorithm Pseudocode
```
function Get-DirectoryChunks(path, depth):
    profile = Get-DirectoryProfile(path)

    # Check if this directory is small enough to be a chunk
    if profile.size <= MaxSize AND profile.files <= MaxFiles:
        return [CreateChunk(path)]

    # Check if we've hit max depth - must accept as chunk even if large
    if depth >= MaxDepth:
        Log-Warning "Directory exceeds thresholds but at max depth: $path"
        return [CreateChunk(path)]

    # Directory is too big - recurse into children
    chunks = []
    children = Get-DirectoryChildren(path)

    if children.Count == 0:
        # No subdirs but too many files - must accept as large chunk
        return [CreateChunk(path)]

    foreach child in children:
        chunks += Get-DirectoryChunks(child, depth + 1)

    # Handle files at this level (not in any subdir)
    filesAtLevel = Get-FilesAtLevel(path)
    if filesAtLevel.Count > 0:
        chunks += CreateFilesOnlyChunk(path, filesAtLevel)

    return chunks
```

### Function: Get-FilesAtLevel
```powershell
function Get-FilesAtLevel {
    <#
    .SYNOPSIS
        Gets files directly in a directory (not in subdirectories)
    .PARAMETER Path
        Directory path
    .OUTPUTS
        Array of file info objects
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    # Get-ChildItem -Path $Path -File (not -Recurse)
}
```

### Function: New-Chunk
```powershell
function New-Chunk {
    <#
    .SYNOPSIS
        Creates a chunk object
    .PARAMETER SourcePath
        Source directory path
    .PARAMETER DestinationPath
        Destination directory path
    .PARAMETER Profile
        Directory profile (size, file count)
    .PARAMETER IsFilesOnly
        Whether this chunk only copies files at one level
    #>
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [PSCustomObject]$Profile,
        [bool]$IsFilesOnly = $false
    )
    # Implementation here
}
```

### Function: New-FilesOnlyChunk
```powershell
function New-FilesOnlyChunk {
    <#
    .SYNOPSIS
        Creates a chunk that only copies files at a specific directory level
    .DESCRIPTION
        When a directory has both files and subdirectories, and the subdirs
        are being processed separately, we need a special chunk for just
        the files at that level. Uses robocopy /LEV:1 to copy only top level.
    .PARAMETER SourcePath
        Source directory path
    .PARAMETER DestinationPath
        Destination directory path
    #>
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    # This chunk will use /LEV:1 to only copy files at this level
    # and /XD * to exclude all subdirectories
}
```

### Robocopy Args for Files-Only Chunks
```powershell
# To copy only files at one level (not recursing into subdirs):
robocopy "source" "dest" /LEV:1 /XD *

# Or explicitly:
robocopy "source" "dest" *.* /LEV:1
```

### Function: Convert-ToDestinationPath
```powershell
function Convert-ToDestinationPath {
    <#
    .SYNOPSIS
        Converts source path to destination path
    .PARAMETER SourcePath
        Full source path
    .PARAMETER SourceRoot
        Source root that maps to DestRoot
    .PARAMETER DestRoot
        Destination root
    .EXAMPLE
        Convert-ToDestinationPath -SourcePath "\\server\users$\john\docs" -SourceRoot "\\server\users$" -DestRoot "D:\Backup"
        # Returns: "D:\Backup\john\docs"
    #>
    param(
        [string]$SourcePath,
        [string]$SourceRoot,
        [string]$DestRoot
    )
    # Implementation: replace SourceRoot prefix with DestRoot
}
```

## Success Criteria

1. [ ] Small directories return single chunk
2. [ ] Large directories are recursively split
3. [ ] Max depth is respected (returns large chunk at limit)
4. [ ] Files at intermediate levels get their own chunk
5. [ ] Files-only chunks have correct robocopy args (/LEV:1)
6. [ ] Destination paths are correctly calculated
7. [ ] Empty directories don't create unnecessary chunks
8. [ ] Chunk IDs are sequential and unique
9. [ ] Performance: scanning 1000 directories completes in < 5 minutes

## Pester Tests Required

Create `tests/Unit/Chunking.Tests.ps1`:

```powershell
Describe "Recursive Chunking" {
    BeforeAll {
        . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
    }

    Context "Get-DirectoryChunks - Simple Cases" {
        It "Should return single chunk for small directory" {
            Mock Get-DirectoryProfile {
                [PSCustomObject]@{
                    Path = $Path
                    TotalSize = 1GB
                    FileCount = 1000
                }
            }
            Mock Get-DirectoryChildren { @() }

            $chunks = Get-DirectoryChunks -Path "C:\Small" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB

            $chunks.Count | Should -Be 1
            $chunks[0].SourcePath | Should -Be "C:\Small"
        }

        It "Should split large directory into child chunks" {
            Mock Get-DirectoryProfile {
                param($Path)
                if ($Path -eq "C:\Large") {
                    [PSCustomObject]@{ Path = $Path; TotalSize = 50GB; FileCount = 100000 }
                } else {
                    [PSCustomObject]@{ Path = $Path; TotalSize = 5GB; FileCount = 10000 }
                }
            }
            Mock Get-DirectoryChildren {
                param($Path)
                if ($Path -eq "C:\Large") {
                    @("C:\Large\Child1", "C:\Large\Child2")
                } else { @() }
            }
            Mock Get-FilesAtLevel { @() }

            $chunks = Get-DirectoryChunks -Path "C:\Large" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB

            $chunks.Count | Should -Be 2
            $chunks[0].SourcePath | Should -BeLike "*Child*"
        }
    }

    Context "Get-DirectoryChunks - Depth Limiting" {
        It "Should stop at max depth even if directory is large" {
            Mock Get-DirectoryProfile {
                [PSCustomObject]@{ Path = $Path; TotalSize = 100GB; FileCount = 500000 }
            }
            Mock Get-DirectoryChildren { @("$Path\Child") }
            Mock Get-FilesAtLevel { @() }

            $chunks = Get-DirectoryChunks -Path "C:\Deep" -DestinationRoot "D:\Backup" -MaxDepth 2

            # Should not infinitely recurse
            $chunks.Count | Should -BeGreaterThan 0
            $chunks.Count | Should -BeLessOrEqual 10  # Reasonable limit
        }
    }

    Context "Get-DirectoryChunks - Files at Level" {
        It "Should create files-only chunk for intermediate directories" {
            Mock Get-DirectoryProfile {
                [PSCustomObject]@{ Path = $Path; TotalSize = 20GB; FileCount = 50000 }
            }
            Mock Get-DirectoryChildren {
                param($Path)
                if ($Path -eq "C:\Mixed") { @("C:\Mixed\SubDir") } else { @() }
            }
            Mock Get-FilesAtLevel {
                param($Path)
                if ($Path -eq "C:\Mixed") {
                    @([PSCustomObject]@{ Name = "file.txt"; Length = 1000 })
                } else { @() }
            }

            $chunks = Get-DirectoryChunks -Path "C:\Mixed" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB

            $filesOnlyChunk = $chunks | Where-Object { $_.IsFilesOnly -eq $true }
            $filesOnlyChunk | Should -Not -BeNullOrEmpty
            $filesOnlyChunk.RobocopyArgs | Should -Contain "/LEV:1"
        }
    }

    Context "Convert-ToDestinationPath" {
        It "Should correctly map UNC to local path" {
            $result = Convert-ToDestinationPath `
                -SourcePath "\\server\users$\john\docs" `
                -SourceRoot "\\server\users$" `
                -DestRoot "D:\Backup"

            $result | Should -Be "D:\Backup\john\docs"
        }

        It "Should handle trailing slashes" {
            $result = Convert-ToDestinationPath `
                -SourcePath "\\server\share\folder\" `
                -SourceRoot "\\server\share\" `
                -DestRoot "E:\Dest\"

            $result | Should -Match "E:\\Dest\\folder"
        }
    }

    Context "New-FilesOnlyChunk" {
        It "Should set IsFilesOnly flag" {
            $chunk = New-FilesOnlyChunk -SourcePath "C:\Test" -DestinationPath "D:\Test"

            $chunk.IsFilesOnly | Should -Be $true
        }

        It "Should include /LEV:1 in robocopy args" {
            $chunk = New-FilesOnlyChunk -SourcePath "C:\Test" -DestinationPath "D:\Test"

            $chunk.RobocopyArgs | Should -Contain "/LEV:1"
        }
    }
}
```

## Edge Cases to Handle

1. **Circular references**: Skip junctions/symlinks (robocopy /XJ handles this)
2. **Single huge file**: A directory with one 100GB file - must accept as chunk
3. **Millions of tiny files**: May exceed file count before size threshold
4. **Access denied**: Log and skip, don't crash
5. **Empty root**: Return empty chunk array
6. **Very deep nesting**: Depth limit prevents stack overflow

## Performance Considerations

- Use caching aggressively (Get-DirectoryProfile with UseCache)
- Don't re-scan directories that were already profiled
- Parallelize scanning of sibling directories (future enhancement)

## Dependencies
- Task 00 (Project Structure)
- Task 02 (Logging)
- Task 03 (Directory Profiling) - critical dependency

## Estimated Complexity
- High
- Recursive algorithm, multiple edge cases
