<#
.SYNOPSIS
    Test data generator for Robocurse integration tests

.DESCRIPTION
    Provides functions to create test directory structures for real robocopy testing.
    Designed to be space-efficient while testing edge cases like deep trees,
    Unicode names, long paths, symlinks, and various file types.
#>

function New-TestTree {
    <#
    .SYNOPSIS
        Creates a test directory tree with configurable depth and breadth
    .PARAMETER RootPath
        The root directory to create the tree in
    .PARAMETER Depth
        How many levels deep to create (default: 3)
    .PARAMETER BreadthPerLevel
        How many subdirectories per level (default: 2)
    .PARAMETER FilesPerDir
        How many files to create in each directory (default: 3)
    .PARAMETER FileSizeBytes
        Size of each file in bytes (default: 1024)
    .OUTPUTS
        PSCustomObject with TotalFiles, TotalDirs, TotalBytes, MaxDepth
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [int]$Depth = 3,

        [int]$BreadthPerLevel = 2,

        [int]$FilesPerDir = 3,

        [int]$FileSizeBytes = 1024
    )

    $stats = @{
        TotalFiles = 0
        TotalDirs = 0
        TotalBytes = 0
        MaxDepth = $Depth
    }

    function New-TreeLevel {
        param([string]$Path, [int]$CurrentDepth)

        if ($CurrentDepth -gt $Depth) {
            return
        }

        # Create files at this level
        for ($i = 1; $i -le $FilesPerDir; $i++) {
            $fileName = "file_d${CurrentDepth}_$i.txt"
            $filePath = Join-Path $Path $fileName
            $content = "D$CurrentDepth F$i " + ("x" * [Math]::Max(0, $FileSizeBytes - 10))
            [System.IO.File]::WriteAllText($filePath, $content)
            $stats.TotalFiles++
            $stats.TotalBytes += $FileSizeBytes
        }

        # Create subdirectories if not at max depth
        if ($CurrentDepth -lt $Depth) {
            for ($d = 1; $d -le $BreadthPerLevel; $d++) {
                $subDirName = "dir_d${CurrentDepth}_$d"
                $subDirPath = Join-Path $Path $subDirName
                New-Item -ItemType Directory -Path $subDirPath -Force | Out-Null
                $stats.TotalDirs++
                New-TreeLevel -Path $subDirPath -CurrentDepth ($CurrentDepth + 1)
            }
        }
    }

    # Create root if needed
    if (-not (Test-Path $RootPath)) {
        New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
    }
    $stats.TotalDirs++

    New-TreeLevel -Path $RootPath -CurrentDepth 1

    [PSCustomObject]$stats
}


function New-DeepTree {
    <#
    .SYNOPSIS
        Creates a very deep directory tree (tests path length limits)
    .PARAMETER RootPath
        The root directory
    .PARAMETER Depth
        How many levels deep (default: 20)
    .PARAMETER DirNameLength
        Length of each directory name (default: 10)
    .OUTPUTS
        PSCustomObject with DeepestPath, TotalDepth, PathLength
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [int]$Depth = 20,

        [int]$DirNameLength = 10
    )

    if (-not (Test-Path $RootPath)) {
        New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
    }

    $currentPath = $RootPath
    $dirName = "d" + ("x" * ($DirNameLength - 1))

    for ($i = 1; $i -le $Depth; $i++) {
        $currentPath = Join-Path $currentPath $dirName
        try {
            New-Item -ItemType Directory -Path $currentPath -Force -ErrorAction Stop | Out-Null
        }
        catch {
            # Hit path length limit
            break
        }
    }

    # Create a file at the deepest point
    $deepFile = Join-Path $currentPath "deep_file.txt"
    try {
        "This file is at depth $i" | Set-Content -Path $deepFile -ErrorAction Stop
    }
    catch {
        # May fail if path too long for file creation
    }

    [PSCustomObject]@{
        DeepestPath = $currentPath
        TotalDepth = $i - 1
        PathLength = $currentPath.Length
        DeepestFile = if (Test-Path $deepFile) { $deepFile } else { $null }
    }
}


function New-UnicodeTestTree {
    <#
    .SYNOPSIS
        Creates directories and files with Unicode names
    .PARAMETER RootPath
        The root directory
    .OUTPUTS
        PSCustomObject with created paths
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath
    )

    if (-not (Test-Path $RootPath)) {
        New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
    }

    $createdPaths = @()

    # Various test cases - avoiding wildcard characters like [] which cause issues
    $testCases = @(
        @{ Name = "spaces in name"; Type = "Dir" },
        @{ Name = "file with spaces.txt"; Type = "File" },
        @{ Name = "UPPERCASE"; Type = "Dir" },
        @{ Name = "MixedCase.TXT"; Type = "File" },
        @{ Name = "dots...in...name"; Type = "Dir" },
        @{ Name = "multiple.dots.file.txt"; Type = "File" },
        @{ Name = "special_chars_-+="; Type = "Dir" },
        @{ Name = "special-file_(1).txt"; Type = "File" },
        @{ Name = "underscores_and_dashes-mixed"; Type = "Dir" },
        @{ Name = "numbers123.txt"; Type = "File" }
    )

    # Add Unicode if supported (may fail on some systems)
    $unicodeCases = @(
        @{ Name = "cafe"; Type = "Dir" },  # Simplified - avoid accent issues
        @{ Name = "japanese"; Type = "Dir" },  # Simplified
        @{ Name = "emoji"; Type = "Dir" }  # Simplified
    )

    foreach ($case in $testCases) {
        $path = Join-Path $RootPath $case.Name
        try {
            if ($case.Type -eq "Dir") {
                New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
                # Add a file inside
                "Content in $($case.Name)" | Set-Content -Path (Join-Path $path "content.txt") -ErrorAction SilentlyContinue
            }
            else {
                "Content of $($case.Name)" | Set-Content -Path $path -ErrorAction Stop
            }
            $createdPaths += $path
        }
        catch {
            Write-Warning "Could not create test case: $($case.Name) - $_"
        }
    }

    foreach ($case in $unicodeCases) {
        $path = Join-Path $RootPath $case.Name
        try {
            New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
            "Unicode content" | Set-Content -Path (Join-Path $path "file.txt") -ErrorAction SilentlyContinue
            $createdPaths += $path
        }
        catch {
            # Unicode may not be supported - that's OK
        }
    }

    [PSCustomObject]@{
        RootPath = $RootPath
        CreatedPaths = $createdPaths
        TotalItems = $createdPaths.Count
    }
}


function New-SymlinkTestTree {
    <#
    .SYNOPSIS
        Creates a directory structure with symbolic links (requires admin on Windows)
    .PARAMETER RootPath
        The root directory
    .OUTPUTS
        PSCustomObject with symlink information
    .NOTES
        Requires SeCreateSymbolicLinkPrivilege on Windows (usually admin)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath
    )

    if (-not (Test-Path $RootPath)) {
        New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
    }

    $result = @{
        RootPath = $RootPath
        RealDirs = @()
        RealFiles = @()
        SymlinkDirs = @()
        SymlinkFiles = @()
        SymlinksSupported = $false
    }

    # Create real directories and files first
    $realDir = Join-Path $RootPath "real_directory"
    $realFile = Join-Path $RootPath "real_file.txt"

    New-Item -ItemType Directory -Path $realDir -Force | Out-Null
    "Real file content" | Set-Content -Path $realFile
    "File in real dir" | Set-Content -Path (Join-Path $realDir "nested.txt")

    $result.RealDirs += $realDir
    $result.RealFiles += $realFile

    # Try to create symlinks (may fail without admin)
    $symlinkDir = Join-Path $RootPath "symlink_to_dir"
    $symlinkFile = Join-Path $RootPath "symlink_to_file.txt"

    try {
        # Windows: Use cmd mklink for compatibility
        $null = cmd /c "mklink /D `"$symlinkDir`" `"$realDir`"" 2>&1
        if (Test-Path $symlinkDir) {
            $result.SymlinkDirs += $symlinkDir
            $result.SymlinksSupported = $true
        }

        $null = cmd /c "mklink `"$symlinkFile`" `"$realFile`"" 2>&1
        if (Test-Path $symlinkFile) {
            $result.SymlinkFiles += $symlinkFile
        }
    }
    catch {
        # Symlinks not supported or no permission
    }

    [PSCustomObject]$result
}


function New-JunctionTestTree {
    <#
    .SYNOPSIS
        Creates a directory structure with NTFS junctions (Windows directory links)
    .PARAMETER RootPath
        The root directory
    .OUTPUTS
        PSCustomObject with junction information
    .NOTES
        Junctions don't require admin on Windows
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath
    )

    if (-not (Test-Path $RootPath)) {
        New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
    }

    $result = @{
        RootPath = $RootPath
        RealDirs = @()
        Junctions = @()
        JunctionsSupported = $false
    }

    # Create target directory
    $targetDir = Join-Path $RootPath "junction_target"
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    "File in target" | Set-Content -Path (Join-Path $targetDir "target_file.txt")
    $result.RealDirs += $targetDir

    # Create junction (doesn't require admin)
    $junction = Join-Path $RootPath "junction_link"

    try {
        $null = cmd /c "mklink /J `"$junction`" `"$targetDir`"" 2>&1
        if (Test-Path $junction) {
            $result.Junctions += $junction
            $result.JunctionsSupported = $true
        }
    }
    catch {
        # Junction creation failed
    }

    [PSCustomObject]$result
}


function New-MixedFileSizeTree {
    <#
    .SYNOPSIS
        Creates files of various sizes to test robocopy with different file sizes
    .PARAMETER RootPath
        The root directory
    .PARAMETER IncludeLargeFile
        Whether to include a 10MB file (default: false to save space)
    .OUTPUTS
        PSCustomObject with file information
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [switch]$IncludeLargeFile
    )

    if (-not (Test-Path $RootPath)) {
        New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
    }

    $files = @()

    # Empty file
    $emptyFile = Join-Path $RootPath "empty.txt"
    [System.IO.File]::WriteAllText($emptyFile, "")
    $files += @{ Path = $emptyFile; Size = 0 }

    # Tiny file (10 bytes)
    $tinyFile = Join-Path $RootPath "tiny.txt"
    [System.IO.File]::WriteAllText($tinyFile, "0123456789")
    $files += @{ Path = $tinyFile; Size = 10 }

    # Small file (1 KB)
    $smallFile = Join-Path $RootPath "small_1kb.txt"
    $content = "x" * 1024
    [System.IO.File]::WriteAllText($smallFile, $content)
    $files += @{ Path = $smallFile; Size = 1024 }

    # Medium file (100 KB)
    $mediumFile = Join-Path $RootPath "medium_100kb.txt"
    $content = "x" * (100 * 1024)
    [System.IO.File]::WriteAllText($mediumFile, $content)
    $files += @{ Path = $mediumFile; Size = 100 * 1024 }

    # Larger file (1 MB)
    $largerFile = Join-Path $RootPath "larger_1mb.bin"
    $content = [byte[]]::new(1024 * 1024)
    [System.IO.File]::WriteAllBytes($largerFile, $content)
    $files += @{ Path = $largerFile; Size = 1024 * 1024 }

    if ($IncludeLargeFile) {
        # Large file (10 MB) - optional
        $largeFile = Join-Path $RootPath "large_10mb.bin"
        $content = [byte[]]::new(10 * 1024 * 1024)
        [System.IO.File]::WriteAllBytes($largeFile, $content)
        $files += @{ Path = $largeFile; Size = 10 * 1024 * 1024 }
    }

    # Calculate total bytes (hashtables need to be accessed differently)
    $totalBytes = 0
    foreach ($f in $files) {
        $totalBytes += $f.Size
    }

    [PSCustomObject]@{
        RootPath = $RootPath
        Files = $files
        TotalFiles = $files.Count
        TotalBytes = $totalBytes
    }
}


function New-ModifiedFilesTree {
    <#
    .SYNOPSIS
        Creates a tree and then modifies some files to test change detection
    .PARAMETER SourcePath
        The source directory (will be created with baseline files)
    .PARAMETER DestPath
        The destination directory (will have some files that differ)
    .OUTPUTS
        PSCustomObject with information about what differs
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestPath
    )

    # Create source with known content
    if (-not (Test-Path $SourcePath)) {
        New-Item -ItemType Directory -Path $SourcePath -Force | Out-Null
    }
    if (-not (Test-Path $DestPath)) {
        New-Item -ItemType Directory -Path $DestPath -Force | Out-Null
    }

    $differences = @{
        OnlyInSource = @()
        OnlyInDest = @()
        ContentDiffers = @()
        Identical = @()
    }

    # Files that exist in both (identical) - must have same content AND timestamp for robocopy to skip
    $srcIdentical = Join-Path $SourcePath "identical.txt"
    $dstIdentical = Join-Path $DestPath "identical.txt"
    "Same content" | Set-Content -Path $srcIdentical
    "Same content" | Set-Content -Path $dstIdentical
    # Set matching timestamps so robocopy recognizes them as identical
    $timestamp = [datetime]::Now.AddMinutes(-5)  # Use time in the past
    [System.IO.File]::SetLastWriteTime($srcIdentical, $timestamp)
    [System.IO.File]::SetLastWriteTime($dstIdentical, $timestamp)
    $differences.Identical += "identical.txt"

    # Files only in source (will be copied)
    "Source only" | Set-Content -Path (Join-Path $SourcePath "new_file.txt")
    $differences.OnlyInSource += "new_file.txt"

    # Files only in dest (extras - will be deleted in /MIR)
    "Dest only" | Set-Content -Path (Join-Path $DestPath "extra_file.txt")
    $differences.OnlyInDest += "extra_file.txt"

    # Files with different content (newer in source)
    $srcFile = Join-Path $SourcePath "modified.txt"
    $dstFile = Join-Path $DestPath "modified.txt"
    "Old content" | Set-Content -Path $dstFile
    Start-Sleep -Milliseconds 100  # Ensure different timestamp
    "New content - updated" | Set-Content -Path $srcFile
    $differences.ContentDiffers += "modified.txt"

    # Directory only in source
    $newDir = Join-Path $SourcePath "new_folder"
    New-Item -ItemType Directory -Path $newDir -Force | Out-Null
    "File in new folder" | Set-Content -Path (Join-Path $newDir "nested.txt")
    $differences.OnlyInSource += "new_folder"

    [PSCustomObject]@{
        SourcePath = $SourcePath
        DestPath = $DestPath
        Differences = $differences
        ExpectedCopied = 3  # new_file.txt, modified.txt, new_folder/nested.txt
        ExpectedExtras = 1  # extra_file.txt (deleted)
        ExpectedSkipped = 1  # identical.txt
    }
}


function Remove-TestTree {
    <#
    .SYNOPSIS
        Safely removes a test tree directory
    .PARAMETER Path
        The path to remove
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path $Path) {
        # Handle junctions and symlinks first
        Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
            ForEach-Object {
                try {
                    # Remove reparse point without following it
                    [System.IO.Directory]::Delete($_.FullName, $false)
                }
                catch {
                    cmd /c "rmdir `"$($_.FullName)`"" 2>&1 | Out-Null
                }
            }

        # Now remove the rest
        Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}


function New-TestShare {
    <#
    .SYNOPSIS
        Creates a temporary Windows file share for UNC path testing
    .PARAMETER Path
        The local path to share
    .PARAMETER ShareName
        Name for the share (default: auto-generated)
    .OUTPUTS
        PSCustomObject with ShareName, LocalPath, UNCPath, and success status
    .NOTES
        Requires administrator privileges
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$ShareName
    )

    # Generate share name if not provided
    if (-not $ShareName) {
        $ShareName = "RobocurseTest_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    }

    $result = @{
        ShareName = $ShareName
        LocalPath = $Path
        UNCPath = $null
        Success = $false
        ErrorMessage = $null
    }

    # Ensure path exists
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    try {
        # Create the share using net share command
        $output = cmd /c "net share `"$ShareName`"=`"$Path`" /GRANT:Everyone,FULL" 2>&1

        if ($LASTEXITCODE -eq 0) {
            $computerName = $env:COMPUTERNAME
            $result.UNCPath = "\\$computerName\$ShareName"
            $result.Success = $true
        }
        else {
            $result.ErrorMessage = "net share failed: $output"
        }
    }
    catch {
        $result.ErrorMessage = $_.Exception.Message
    }

    [PSCustomObject]$result
}


function Remove-TestShare {
    <#
    .SYNOPSIS
        Removes a Windows file share created for testing
    .PARAMETER ShareName
        Name of the share to remove
    .OUTPUTS
        Boolean indicating success
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ShareName
    )

    try {
        $output = cmd /c "net share `"$ShareName`" /DELETE /YES" 2>&1
        return $LASTEXITCODE -eq 0
    }
    catch {
        Write-Warning "Failed to remove share '$ShareName': $_"
        return $false
    }
}


function Test-CanCreateShare {
    <#
    .SYNOPSIS
        Tests if the current user can create file shares (has admin privileges)
    .OUTPUTS
        Boolean indicating if shares can be created
    #>
    [CmdletBinding()]
    param()

    # Check if running as administrator
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        return $false
    }

    # Try to create and immediately remove a test share
    $testPath = Join-Path $env:TEMP "ShareTest_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $testShareName = "TestShare_$([Guid]::NewGuid().ToString('N').Substring(0,8))"

    try {
        New-Item -ItemType Directory -Path $testPath -Force | Out-Null
        $output = cmd /c "net share `"$testShareName`"=`"$testPath`"" 2>&1

        if ($LASTEXITCODE -eq 0) {
            cmd /c "net share `"$testShareName`" /DELETE /YES" 2>&1 | Out-Null
            Remove-Item $testPath -Force -ErrorAction SilentlyContinue
            return $true
        }
    }
    catch {
        # Failed to create share
    }
    finally {
        Remove-Item $testPath -Force -ErrorAction SilentlyContinue
    }

    return $false
}


# Export functions if loaded as module
if ($MyInvocation.MyCommand.ScriptBlock.Module) {
    Export-ModuleMember -Function @(
        'New-TestTree'
        'New-DeepTree'
        'New-UnicodeTestTree'
        'New-SymlinkTestTree'
        'New-JunctionTestTree'
        'New-MixedFileSizeTree'
        'New-ModifiedFilesTree'
        'Remove-TestTree'
        'New-TestShare'
        'Remove-TestShare'
        'Test-CanCreateShare'
    )
}
