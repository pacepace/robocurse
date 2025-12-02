# Robocurse Chunking Functions
# Script-level counter for unique chunk IDs (plain integer, use [ref] when calling Interlocked)
$script:ChunkIdCounter = 0

function Get-DirectoryChunks {
    <#
    .SYNOPSIS
        Recursively splits a directory tree into manageable chunks
    .PARAMETER Path
        Root path to chunk
    .PARAMETER DestinationRoot
        Destination root (for building destination paths)
    .PARAMETER SourceRoot
        Source root that maps to DestinationRoot (defaults to Path if not specified)
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationRoot,

        [ValidateNotNullOrEmpty()]
        [string]$SourceRoot,

        [ValidateRange(1MB, 1TB)]
        [int64]$MaxSizeBytes = $script:DefaultMaxChunkSizeBytes,

        [ValidateRange(1, 10000000)]
        [int]$MaxFiles = $script:DefaultMaxFilesPerChunk,

        [ValidateRange(0, 20)]
        [int]$MaxDepth = $script:DefaultMaxChunkDepth,

        [ValidateRange(1KB, 1TB)]
        [int64]$MinSizeBytes = $script:DefaultMinChunkSizeBytes,

        [ValidateRange(0, 20)]
        [int]$CurrentDepth = 0
    )

    # Validate path exists (inside function body so mocks can intercept)
    if (-not (Test-Path -Path $Path -PathType Container)) {
        throw "Path '$Path' does not exist or is not a directory"
    }

    # Validate chunk size constraints
    if ($MaxSizeBytes -le $MinSizeBytes) {
        throw "MaxSizeBytes ($MaxSizeBytes) must be greater than MinSizeBytes ($MinSizeBytes)"
    }

    # Default SourceRoot to Path if not specified (for initial call)
    if ([string]::IsNullOrEmpty($SourceRoot)) {
        $SourceRoot = $Path
    }

    Write-RobocurseLog "Analyzing directory at depth $CurrentDepth : $Path" -Level Debug

    # Get profile for this directory
    $profile = Get-DirectoryProfile -Path $Path -UseCache $true

    # Check if this directory is small enough to be a chunk
    if ($profile.TotalSize -le $MaxSizeBytes -and $profile.FileCount -le $MaxFiles) {
        Write-RobocurseLog "Directory fits in single chunk: $Path (Size: $($profile.TotalSize), Files: $($profile.FileCount))" -Level Debug
        $destPath = Convert-ToDestinationPath -SourcePath $Path -SourceRoot $SourceRoot -DestRoot $DestinationRoot
        return @(New-Chunk -SourcePath $Path -DestinationPath $destPath -Profile $profile -IsFilesOnly $false)
    }

    # Check if we've hit max depth - must accept as chunk even if large
    if ($CurrentDepth -ge $MaxDepth) {
        Write-RobocurseLog "Directory exceeds thresholds but at max depth: $Path (Size: $($profile.TotalSize), Files: $($profile.FileCount))" -Level Warning
        $destPath = Convert-ToDestinationPath -SourcePath $Path -SourceRoot $SourceRoot -DestRoot $DestinationRoot
        return @(New-Chunk -SourcePath $Path -DestinationPath $destPath -Profile $profile -IsFilesOnly $false)
    }

    # Check if directory is above MinSizeBytes - if not, accept as single chunk to reduce overhead
    # This prevents creating many tiny chunks which add more overhead than benefit
    if ($profile.TotalSize -lt $MinSizeBytes) {
        Write-RobocurseLog "Directory below minimum chunk size ($MinSizeBytes bytes), accepting as single chunk: $Path (Size: $($profile.TotalSize))" -Level Debug
        $destPath = Convert-ToDestinationPath -SourcePath $Path -SourceRoot $SourceRoot -DestRoot $DestinationRoot
        return @(New-Chunk -SourcePath $Path -DestinationPath $destPath -Profile $profile -IsFilesOnly $false)
    }

    # Directory is too big - recurse into children
    $children = Get-DirectoryChildren -Path $Path

    if ($children.Count -eq 0) {
        # No subdirs but too many files - must accept as large chunk
        Write-RobocurseLog "No subdirectories to split, accepting large directory: $Path" -Level Warning
        $destPath = Convert-ToDestinationPath -SourcePath $Path -SourceRoot $SourceRoot -DestRoot $DestinationRoot
        return @(New-Chunk -SourcePath $Path -DestinationPath $destPath -Profile $profile -IsFilesOnly $false)
    }

    # Recurse into each child
    # Use List<> instead of array concatenation for O(N) instead of O(N²) performance
    Write-RobocurseLog "Directory too large, recursing into $($children.Count) children: $Path" -Level Debug
    $chunkList = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($child in $children) {
        $childChunks = Get-DirectoryChunks `
            -Path $child `
            -DestinationRoot $DestinationRoot `
            -SourceRoot $SourceRoot `
            -MaxSizeBytes $MaxSizeBytes `
            -MaxFiles $MaxFiles `
            -MaxDepth $MaxDepth `
            -MinSizeBytes $MinSizeBytes `
            -CurrentDepth ($CurrentDepth + 1)

        foreach ($chunk in $childChunks) {
            $chunkList.Add($chunk)
        }
    }

    # Handle files at this level (not in any subdir)
    $filesAtLevel = Get-FilesAtLevel -Path $Path
    if ($filesAtLevel.Count -gt 0) {
        Write-RobocurseLog "Found $($filesAtLevel.Count) files at level: $Path" -Level Debug
        $destPath = Convert-ToDestinationPath -SourcePath $Path -SourceRoot $SourceRoot -DestRoot $DestinationRoot
        $chunkList.Add((New-FilesOnlyChunk -SourcePath $Path -DestinationPath $destPath))
    }

    return $chunkList.ToArray()
}

function Get-FilesAtLevel {
    <#
    .SYNOPSIS
        Gets files directly in a directory (not in subdirectories)
    .PARAMETER Path
        Directory path
    .OUTPUTS
        Array of file info objects
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $files = Get-ChildItem -Path $Path -File -ErrorAction Stop
        return $files
    }
    catch {
        Write-RobocurseLog "Error getting files at level '$Path': $_" -Level Warning
        return @()
    }
}

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
    .OUTPUTS
        Chunk object
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [PSCustomObject]$Profile,

        [bool]$IsFilesOnly = $false
    )

    # Thread-safe increment using Interlocked (pass [ref] to the plain integer)
    $chunkId = [System.Threading.Interlocked]::Increment([ref]$script:ChunkIdCounter)

    $chunk = [PSCustomObject]@{
        ChunkId = $chunkId
        SourcePath = $SourcePath
        DestinationPath = $DestinationPath
        EstimatedSize = $Profile.TotalSize
        EstimatedFiles = $Profile.FileCount
        Depth = 0  # Will be set by caller if needed
        IsFilesOnly = $IsFilesOnly
        Status = "Pending"
        RetryCount = 0  # Track retry attempts for failed chunks
        RobocopyArgs = @()
    }

    Write-RobocurseLog "Created chunk #$($chunk.ChunkId): $SourcePath -> $DestinationPath (Size: $($chunk.EstimatedSize), Files: $($chunk.EstimatedFiles), FilesOnly: $IsFilesOnly)" -Level Debug

    return $chunk
}

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
    .OUTPUTS
        Chunk object
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    # Create a minimal profile for files at this level
    # We don't need exact size since this is just for files at one level
    $filesAtLevel = Get-FilesAtLevel -Path $SourcePath
    $totalSize = ($filesAtLevel | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $totalSize) { $totalSize = 0 }

    $profile = [PSCustomObject]@{
        TotalSize = $totalSize
        FileCount = $filesAtLevel.Count
        DirCount = 0
        AvgFileSize = if ($filesAtLevel.Count -gt 0) { $totalSize / $filesAtLevel.Count } else { 0 }
        LastScanned = Get-Date
    }

    $chunk = New-Chunk -SourcePath $SourcePath -DestinationPath $DestinationPath -Profile $profile -IsFilesOnly $true

    # Add robocopy args to copy only files at this level
    $chunk.RobocopyArgs = @("/LEV:1")

    Write-RobocurseLog "Created files-only chunk #$($chunk.ChunkId): $SourcePath (Files: $($filesAtLevel.Count))" -Level Debug

    return $chunk
}

function New-FlatChunks {
    <#
    .SYNOPSIS
        Creates chunks using flat (non-recursive) scanning strategy
    .DESCRIPTION
        Generates chunks without recursing into subdirectories.
        This is a fast scanning mode that treats each top-level directory as a chunk.
    .PARAMETER Path
        Root path to chunk
    .PARAMETER DestinationRoot
        Destination root path
    .PARAMETER MaxChunkSizeBytes
        Maximum size per chunk (default: 10GB)
    .PARAMETER MaxFiles
        Maximum files per chunk (default: 50000)
    .OUTPUTS
        Array of chunk objects
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DestinationRoot,

        [int64]$MaxChunkSizeBytes = $script:DefaultMaxChunkSizeBytes,
        [int]$MaxFiles = $script:DefaultMaxFilesPerChunk
    )

    # Flat mode: MaxDepth = 0 (no recursion into subdirectories)
    return Get-DirectoryChunks `
        -Path $Path `
        -DestinationRoot $DestinationRoot `
        -MaxSizeBytes $MaxChunkSizeBytes `
        -MaxFiles $MaxFiles `
        -MaxDepth 0
}

function New-SmartChunks {
    <#
    .SYNOPSIS
        Creates chunks using smart (recursive) scanning strategy
    .DESCRIPTION
        Generates chunks by recursively analyzing the directory tree and
        splitting based on size and file count thresholds.
        This is the recommended mode for most use cases.
    .PARAMETER Path
        Root path to chunk
    .PARAMETER DestinationRoot
        Destination root path
    .PARAMETER MaxChunkSizeBytes
        Maximum size per chunk (default: 10GB)
    .PARAMETER MaxFiles
        Maximum files per chunk (default: 50000)
    .PARAMETER MaxDepth
        Maximum recursion depth (default: 5)
    .OUTPUTS
        Array of chunk objects
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DestinationRoot,

        [int64]$MaxChunkSizeBytes = $script:DefaultMaxChunkSizeBytes,
        [int]$MaxFiles = $script:DefaultMaxFilesPerChunk,
        [int]$MaxDepth = $script:DefaultMaxChunkDepth
    )

    # Smart mode: recursive chunking with configurable depth
    return Get-DirectoryChunks `
        -Path $Path `
        -DestinationRoot $DestinationRoot `
        -MaxSizeBytes $MaxChunkSizeBytes `
        -MaxFiles $MaxFiles `
        -MaxDepth $MaxDepth
}

function Get-NormalizedPath {
    <#
    .SYNOPSIS
        Normalizes a Windows path for consistent comparison
    .DESCRIPTION
        Handles UNC paths, drive letters, and various edge cases:
        - Removes trailing slashes (except for drive roots like "C:\")
        - Converts forward slashes to backslashes
        - Preserves case (use case-insensitive comparison when comparing)

        NOTE: This function does NOT lowercase paths because:
        1. ToLowerInvariant() can give unexpected results for Unicode characters
        2. Windows file system uses ordinal case-insensitive comparison
        3. Consistent with Get-NormalizedCacheKey behavior

        For path comparisons, use: $path1.Equals($path2, [StringComparison]::OrdinalIgnoreCase)
        Or use [StringComparer]::OrdinalIgnoreCase in collections.
    .PARAMETER Path
        Path to normalize
    .OUTPUTS
        Normalized path string (case-preserved)
    .EXAMPLE
        Get-NormalizedPath -Path "\\SERVER\Share$\"
        # Returns: "\\SERVER\Share$"
    .EXAMPLE
        Get-NormalizedPath -Path "C:\"
        # Returns: "C:\" (drive root preserved)
    .EXAMPLE
        # For comparison, use case-insensitive:
        (Get-NormalizedPath "C:\Foo").Equals((Get-NormalizedPath "C:\FOO"), [StringComparison]::OrdinalIgnoreCase)
        # Returns: $true
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Convert forward slashes to backslashes
    $normalized = $Path.Replace('/', '\')

    # Remove trailing slashes, but preserve drive roots like "C:\"
    # A drive root is exactly 3 characters: letter + colon + backslash (e.g., "C:\")
    if ($normalized.Length -gt 3 -or -not ($normalized -match '^[A-Za-z]:\\$')) {
        $normalized = $normalized.TrimEnd('\')
    }

    # Note: Case is preserved - callers should use OrdinalIgnoreCase comparison
    return $normalized
}

function Convert-ToDestinationPath {
    <#
    .SYNOPSIS
        Converts source path to destination path
    .DESCRIPTION
        Maps a source path to its equivalent destination path by:
        - Normalizing both paths for consistent comparison (case, slashes)
        - Extracting the relative portion after SourceRoot
        - Appending it to DestRoot
    .PARAMETER SourcePath
        Full source path
    .PARAMETER SourceRoot
        Source root that maps to DestRoot
    .PARAMETER DestRoot
        Destination root
    .EXAMPLE
        Convert-ToDestinationPath -SourcePath "\\server\users$\john\docs" -SourceRoot "\\server\users$" -DestRoot "D:\Backup"
        # Returns: "D:\Backup\john\docs"
    .EXAMPLE
        Convert-ToDestinationPath -SourcePath "\\SERVER\Share$\Data" -SourceRoot "\\server\share$" -DestRoot "E:\Replicas"
        # Returns: "E:\Replicas\Data" (handles case mismatch)
    .OUTPUTS
        String - destination path
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$DestRoot
    )

    # Normalize paths for comparison (handles case, trailing slashes, forward slashes)
    $normalizedSource = Get-NormalizedPath -Path $SourcePath
    $normalizedSourceRoot = Get-NormalizedPath -Path $SourceRoot
    $normalizedDestRoot = $DestRoot.TrimEnd('\', '/')

    # Check if SourcePath starts with SourceRoot (case-insensitive for Windows paths)
    if (-not $normalizedSource.StartsWith($normalizedSourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Write-RobocurseLog "SourcePath '$SourcePath' does not start with SourceRoot '$SourceRoot'" -Level Warning
        # If they don't match, just append source to dest
        return Join-Path $normalizedDestRoot (Split-Path $SourcePath -Leaf)
    }

    # Get the relative path (using original SourcePath to preserve original casing in output)
    # We need to calculate the substring length from the normalized root
    $relativePath = $SourcePath.Substring($SourceRoot.TrimEnd('\', '/').Length).TrimStart('\', '/')

    # Build destination path
    if ([string]::IsNullOrEmpty($relativePath)) {
        # Source and SourceRoot are the same
        return $normalizedDestRoot
    }
    else {
        # Manually combine paths to avoid Join-Path validation issues on cross-platform testing
        $separator = if ($normalizedDestRoot.Contains('\')) { '\' } else { '/' }
        return "$normalizedDestRoot$separator$relativePath"
    }
}
