# Robocurse Chunking Functions
# Script-level counter for unique chunk IDs (plain integer, use [ref] when calling Interlocked)
$script:ChunkIdCounter = 0

function Get-DirectoryChunks {
    <#
    .SYNOPSIS
        Recursively splits a directory tree into manageable chunks
    .DESCRIPTION
        Analyzes directory structure and intelligently divides it into chunks suitable for parallel
        replication. Uses directory profiling to determine optimal split points based on size, file
        count, and depth constraints. Recursively subdivides large directories while respecting
        minimum chunk sizes to avoid overhead. Handles both directory-based chunks and files-only
        chunks for optimal parallelization. This is the core chunking algorithm for the replication
        orchestrator.

        PERFORMANCE: When a TreeNode is provided, uses pre-built tree data for O(1) size lookups
        instead of calling Get-DirectoryProfile repeatedly. This avoids re-enumerating overlapping
        subtrees which was the main performance bottleneck.
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
    .PARAMETER TreeNode
        Pre-built DirectoryNode from New-DirectoryTree. When provided, uses tree data
        for O(1) size lookups instead of calling Get-DirectoryProfile (major performance improvement).
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

        [ValidateRange(-1, 20)]
        [int]$MaxDepth = $script:DefaultMaxChunkDepth,

        [ValidateRange(1KB, 1TB)]
        [int64]$MinSizeBytes = $script:DefaultMinChunkSizeBytes,

        [ValidateRange(0, 20)]
        [int]$CurrentDepth = 0,

        # Optional OrchestrationState for progress counter updates (pass from caller in background runspace)
        [object]$State = $null,

        # Pre-built directory tree node for O(1) size lookups (avoids repeated enumeration)
        [object]$TreeNode = $null
    )

    # Validate path exists (inside function body so mocks can intercept)
    # Skip validation if we have a TreeNode (tree was already built from valid enumeration)
    if (-not $TreeNode -and -not (Test-Path -Path $Path -PathType Container)) {
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

    Write-RobocurseLog "Analyzing directory at depth $CurrentDepth : $Path" -Level 'Debug' -Component 'Chunking'

    # Get size and file count - either from tree (O(1)) or profile (I/O)
    if ($TreeNode) {
        # Use pre-built tree data - no I/O needed!
        $totalSize = $TreeNode.TotalSize
        $fileCount = $TreeNode.TotalFileCount
        $profile = [PSCustomObject]@{
            TotalSize = $totalSize
            FileCount = $fileCount
            DirCount = $TreeNode.Children.Count
            AvgFileSize = if ($fileCount -gt 0) { [math]::Round($totalSize / $fileCount, 0) } else { 0 }
            LastScanned = Get-Date
        }
    } else {
        # Fallback to old behavior (for backward compatibility)
        $profile = Get-DirectoryProfile -Path $Path -UseCache $true -State $State
        $totalSize = $profile.TotalSize
        $fileCount = $profile.FileCount
    }

    # Check if this directory is small enough to be a chunk
    if ($totalSize -le $MaxSizeBytes -and $fileCount -le $MaxFiles) {
        Write-RobocurseLog "Directory fits in single chunk: $Path (Size: $totalSize, Files: $fileCount)" -Level 'Debug' -Component 'Chunking'
        $destPath = Convert-ToDestinationPath -SourcePath $Path -SourceRoot $SourceRoot -DestRoot $DestinationRoot
        return @(New-Chunk -SourcePath $Path -DestinationPath $destPath -Profile $profile -IsFilesOnly $false -State $State)
    }

    # Check if we've hit max depth - must accept as chunk even if large
    # MaxDepth = -1 means unlimited (Smart mode), so skip this check
    if ($MaxDepth -ge 0 -and $CurrentDepth -ge $MaxDepth) {
        Write-RobocurseLog "Directory exceeds thresholds but at max depth: $Path (Size: $totalSize, Files: $fileCount)" -Level 'Warning' -Component 'Chunking'
        $destPath = Convert-ToDestinationPath -SourcePath $Path -SourceRoot $SourceRoot -DestRoot $DestinationRoot
        return @(New-Chunk -SourcePath $Path -DestinationPath $destPath -Profile $profile -IsFilesOnly $false -State $State)
    }

    # Check if directory is above MinSizeBytes - if not, accept as single chunk to reduce overhead
    # This prevents creating many tiny chunks which add more overhead than benefit
    if ($totalSize -lt $MinSizeBytes) {
        Write-RobocurseLog "Directory below minimum chunk size ($MinSizeBytes bytes), accepting as single chunk: $Path (Size: $totalSize)" -Level 'Debug' -Component 'Chunking'
        $destPath = Convert-ToDestinationPath -SourcePath $Path -SourceRoot $SourceRoot -DestRoot $DestinationRoot
        return @(New-Chunk -SourcePath $Path -DestinationPath $destPath -Profile $profile -IsFilesOnly $false -State $State)
    }

    # Directory is too big - recurse into children
    # Get children from tree if available, otherwise from filesystem
    if ($TreeNode) {
        # Use tree data exclusively - no filesystem fallback
        $childNodes = $TreeNode.Children.Values
        $childCount = $TreeNode.Children.Count
    } else {
        # Fallback to filesystem (backward compatibility)
        $children = Get-DirectoryChildren -Path $Path
        $childCount = $children.Count
        $childNodes = $null
    }

    if ($childCount -eq 0) {
        # No subdirs but too many files - must accept as large chunk
        Write-RobocurseLog "No subdirectories to split, accepting large directory: $Path" -Level 'Debug' -Component 'Chunking'
        $destPath = Convert-ToDestinationPath -SourcePath $Path -SourceRoot $SourceRoot -DestRoot $DestinationRoot
        return @(New-Chunk -SourcePath $Path -DestinationPath $destPath -Profile $profile -IsFilesOnly $false -State $State)
    }

    # Recurse into each child
    # Use List<> instead of array concatenation for O(N) instead of O(N²) performance
    Write-RobocurseLog "Directory too large, recursing into $childCount children: $Path" -Level 'Debug' -Component 'Chunking'
    $chunkList = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($childNodes) {
        # Use tree nodes - no I/O for child enumeration!
        foreach ($childNode in $childNodes) {
            $childChunks = Get-DirectoryChunks `
                -Path $childNode.Path `
                -DestinationRoot $DestinationRoot `
                -SourceRoot $SourceRoot `
                -MaxSizeBytes $MaxSizeBytes `
                -MaxFiles $MaxFiles `
                -MaxDepth $MaxDepth `
                -MinSizeBytes $MinSizeBytes `
                -CurrentDepth ($CurrentDepth + 1) `
                -State $State `
                -TreeNode $childNode

            foreach ($chunk in $childChunks) {
                $chunkList.Add($chunk)
            }
        }
    } else {
        # Fallback to old behavior
        foreach ($child in $children) {
            $childChunks = Get-DirectoryChunks `
                -Path $child `
                -DestinationRoot $DestinationRoot `
                -SourceRoot $SourceRoot `
                -MaxSizeBytes $MaxSizeBytes `
                -MaxFiles $MaxFiles `
                -MaxDepth $MaxDepth `
                -MinSizeBytes $MinSizeBytes `
                -CurrentDepth ($CurrentDepth + 1) `
                -State $State

            foreach ($chunk in $childChunks) {
                $chunkList.Add($chunk)
            }
        }
    }

    # Handle files at this level (not in any subdir)
    # Check if there are direct files using tree data or filesystem
    $hasFilesAtLevel = if ($TreeNode) {
        $TreeNode.DirectFileCount -gt 0
    } else {
        (Get-FilesAtLevel -Path $Path).Count -gt 0
    }

    if ($hasFilesAtLevel) {
        $directFileCount = if ($TreeNode) { $TreeNode.DirectFileCount } else { (Get-FilesAtLevel -Path $Path).Count }
        Write-RobocurseLog "Found $directFileCount files at level: $Path" -Level 'Debug' -Component 'Chunking'
        $destPath = Convert-ToDestinationPath -SourcePath $Path -SourceRoot $SourceRoot -DestRoot $DestinationRoot

        # Pass tree data to avoid filesystem I/O when using tree
        if ($TreeNode) {
            $chunkList.Add((New-FilesOnlyChunk -SourcePath $Path -DestinationPath $destPath -State $State -DirectSize $TreeNode.DirectSize -DirectFileCount $TreeNode.DirectFileCount))
        } else {
            $chunkList.Add((New-FilesOnlyChunk -SourcePath $Path -DestinationPath $destPath -State $State))
        }
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
        # Wrap in @() to ensure array return even for single file (PS 5.1 compatibility)
        return @($files)
    }
    catch {
        Write-RobocurseLog "Error getting files at level '$Path': $_" -Level 'Warning' -Component 'Chunking'
        return @()
    }
}

function New-Chunk {
    <#
    .SYNOPSIS
        Creates a chunk object
    .DESCRIPTION
        Constructs a standardized chunk object with unique ID, source/destination paths, size
        estimates, and replication metadata. Thread-safe chunk ID assignment using Interlocked
        increment. Used by the chunking algorithm to create work units for the orchestrator.
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

        [bool]$IsFilesOnly = $false,

        # Optional OrchestrationState for progress counter updates (pass from caller in background runspace)
        [object]$State = $null
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
        RetryAfter = $null  # Timestamp for delayed retry (exponential backoff)
        LastExitCode = $null  # Last robocopy exit code for this chunk
        LastErrorMessage = $null  # Last error message for display in UI
        RobocopyArgs = @()
    }

    Write-RobocurseLog "Created chunk #$($chunk.ChunkId): $SourcePath -> $DestinationPath (Size: $($chunk.EstimatedSize), Files: $($chunk.EstimatedFiles), FilesOnly: $IsFilesOnly)" -Level 'Debug' -Component 'Chunking'

    # Update chunk creation progress counter for GUI display
    # Use passed State parameter (required for background runspace where $script: scope differs)
    if ($State) {
        $State.IncrementScanProgress() | Out-Null
    }

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
    .PARAMETER DirectSize
        Optional pre-calculated size of files at this level (from tree data)
    .PARAMETER DirectFileCount
        Optional pre-calculated file count at this level (from tree data)
    .OUTPUTS
        Chunk object
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        # Optional OrchestrationState for progress counter updates (pass from caller in background runspace)
        [object]$State = $null,

        # Pre-calculated values from tree (avoids filesystem I/O)
        [int64]$DirectSize = -1,
        [int]$DirectFileCount = -1
    )

    # Use pre-calculated values if provided, otherwise hit filesystem
    if ($DirectSize -ge 0 -and $DirectFileCount -ge 0) {
        $totalSize = $DirectSize
        $fileCount = $DirectFileCount
    } else {
        # Fallback to filesystem enumeration
        $filesAtLevel = Get-FilesAtLevel -Path $SourcePath
        $totalSize = ($filesAtLevel | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $totalSize) { $totalSize = 0 }
        $fileCount = $filesAtLevel.Count
    }

    $profile = [PSCustomObject]@{
        TotalSize = $totalSize
        FileCount = $fileCount
        DirCount = 0
        AvgFileSize = if ($fileCount -gt 0) { $totalSize / $fileCount } else { 0 }
        LastScanned = Get-Date
    }

    $chunk = New-Chunk -SourcePath $SourcePath -DestinationPath $DestinationPath -Profile $profile -IsFilesOnly $true -State $State

    # Add robocopy args to copy only files at this level
    $chunk.RobocopyArgs = @("/LEV:1")

    Write-RobocurseLog "Created files-only chunk #$($chunk.ChunkId): $SourcePath (Files: $fileCount)" -Level 'Debug' -Component 'Chunking'

    return $chunk
}

function New-FlatChunks {
    <#
    .SYNOPSIS
        Creates chunks using flat scanning strategy with configurable depth
    .DESCRIPTION
        Generates chunks by recursing to a specified depth. Each directory at that
        depth becomes one chunk. Use MaxDepth=0 for top-level only, or higher values
        for more granular chunking with predictable boundaries.
    .PARAMETER Path
        Root path to chunk
    .PARAMETER DestinationRoot
        Destination root path
    .PARAMETER MaxDepth
        Maximum recursion depth (0-20, default from profile)
    .OUTPUTS
        Array of chunk objects
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DestinationRoot,

        [ValidateRange(0, 20)]
        [int]$MaxDepth = $script:DefaultMaxChunkDepth,

        # Optional OrchestrationState for progress counter updates (pass from caller in background runspace)
        [object]$State = $null,

        # Pre-built directory tree for O(1) size lookups (optional, built if not provided)
        [DirectoryNode]$TreeNode = $null
    )

    # Flat mode: use specified depth limit
    return Get-DirectoryChunks `
        -Path $Path `
        -DestinationRoot $DestinationRoot `
        -MaxDepth $MaxDepth `
        -State $State `
        -TreeNode $TreeNode
}

function New-SmartChunks {
    <#
    .SYNOPSIS
        Creates chunks using smart (unlimited depth) scanning strategy
    .DESCRIPTION
        Generates chunks by recursively analyzing the directory tree with no depth limit.
        Continues recursing until each chunk fits within thresholds or no more subdirectories
        exist. This is the recommended mode for optimal chunk balancing.
    .PARAMETER Path
        Root path to chunk
    .PARAMETER DestinationRoot
        Destination root path
    .OUTPUTS
        Array of chunk objects
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DestinationRoot,

        # Optional OrchestrationState for progress counter updates (pass from caller in background runspace)
        [object]$State = $null,

        # Pre-built directory tree for O(1) size lookups (optional, built if not provided)
        [DirectoryNode]$TreeNode = $null
    )

    # Smart mode: unlimited depth (-1) for optimal chunk balancing
    return Get-DirectoryChunks `
        -Path $Path `
        -DestinationRoot $DestinationRoot `
        -MaxDepth -1 `
        -State $State `
        -TreeNode $TreeNode
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
        # This is a configuration error - fail fast rather than silently creating unexpected paths
        throw "Path mismatch: SourcePath '$SourcePath' does not start with SourceRoot '$SourceRoot'. Cannot compute relative destination path."
    }

    # Get the relative path from the NORMALIZED source path using NORMALIZED root length
    # This ensures consistency since StartsWith check already validated against normalized paths
    # Using normalized length prevents off-by-one errors if Get-NormalizedPath does more than TrimEnd
    $relativePath = $normalizedSource.Substring($normalizedSourceRoot.Length).TrimStart('\', '/')

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
