# Robocurse Directory profiling Functions
# Script-level cache for directory profiles (thread-safe)
# Uses OrdinalIgnoreCase comparer for Windows-style case-insensitive path matching
# This is more correct than ToLowerInvariant() for international characters
$script:ProfileCache = [System.Collections.Concurrent.ConcurrentDictionary[string, PSCustomObject]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

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

function ConvertFrom-RobocopyListOutput {
    <#
    .SYNOPSIS
        Parses robocopy /L output to extract file info
    .PARAMETER Output
        Array of robocopy output lines
    .OUTPUTS
        PSCustomObject with TotalSize, FileCount, DirCount, Files (array of file info)
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Output
    )

    $totalSize = 0
    $fileCount = 0
    $dirCount = 0
    $files = @()

    foreach ($line in $Output) {
        # Skip empty lines
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        # Lines starting with whitespace + number are files or directories
        # Format: "          123456789    path\to\file.txt"
        if ($line -match '^\s+(\d+)\s+(.+)$') {
            $size = [int64]$matches[1]
            $path = $matches[2].Trim()

            # Lines ending with \ are directories
            if ($path.EndsWith('\')) {
                $dirCount++
            }
            else {
                # This is a file
                $fileCount++
                $totalSize += $size

                $files += [PSCustomObject]@{
                    Path = $path
                    Size = $size
                }
            }
        }
    }

    return [PSCustomObject]@{
        TotalSize = $totalSize
        FileCount = $fileCount
        DirCount = $dirCount
        Files = $files
    }
}

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

        [int]$CacheMaxAgeHours = $script:ProfileCacheMaxAgeHours
    )

    # Normalize path for cache lookup
    $normalizedPath = $Path.TrimEnd('\')

    # Check cache if enabled
    if ($UseCache) {
        $cached = Get-CachedProfile -Path $normalizedPath -MaxAgeHours $CacheMaxAgeHours
        if ($null -ne $cached) {
            Write-RobocurseLog "Using cached profile for: $Path" -Level Debug
            return $cached
        }
    }

    # Run robocopy list
    Write-RobocurseLog "Profiling directory: $Path" -Level Debug

    try {
        $output = Invoke-RobocopyList -Source $Path

        # Parse the output
        $parseResult = ConvertFrom-RobocopyListOutput -Output $output

        # Calculate average file size (handle division by zero)
        $avgFileSize = 0
        if ($parseResult.FileCount -gt 0) {
            $avgFileSize = [math]::Round($parseResult.TotalSize / $parseResult.FileCount, 0)
        }

        # Create profile object
        $profile = [PSCustomObject]@{
            Path = $normalizedPath
            TotalSize = $parseResult.TotalSize
            FileCount = $parseResult.FileCount
            DirCount = $parseResult.DirCount
            AvgFileSize = $avgFileSize
            LastScanned = Get-Date
        }

        # Store in cache
        Set-CachedProfile -Profile $profile

        return $profile
    }
    catch {
        Write-RobocurseLog "Error profiling directory '$Path': $_" -Level Warning

        # Return empty profile on error
        return [PSCustomObject]@{
            Path = $normalizedPath
            TotalSize = 0
            FileCount = 0
            DirCount = 0
            AvgFileSize = 0
            LastScanned = Get-Date
        }
    }
}

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

    try {
        $children = Get-ChildItem -Path $Path -Directory -ErrorAction Stop
        return $children | ForEach-Object { $_.FullName }
    }
    catch {
        Write-RobocurseLog "Error getting children of '$Path': $_" -Level Warning
        return @()
    }
}

function Get-NormalizedCacheKey {
    <#
    .SYNOPSIS
        Normalizes a path for use as a cache key
    .DESCRIPTION
        Wrapper around Get-NormalizedPath for backward compatibility.
        The ProfileCache uses StringComparer.OrdinalIgnoreCase for
        case-insensitive matching.
    .PARAMETER Path
        Path to normalize
    .OUTPUTS
        Normalized path string suitable for cache key
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Delegate to unified path normalization function
    return Get-NormalizedPath -Path $Path
}

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

    # Normalize path for cache lookup
    $cacheKey = Get-NormalizedCacheKey -Path $Path

    # Thread-safe retrieval from ConcurrentDictionary
    $cachedProfile = $null
    if (-not $script:ProfileCache.TryGetValue($cacheKey, [ref]$cachedProfile)) {
        return $null
    }

    # Check if cache is still valid
    $age = (Get-Date) - $cachedProfile.LastScanned
    if ($age.TotalHours -gt $MaxAgeHours) {
        Write-RobocurseLog "Cache expired for: $Path (age: $([math]::Round($age.TotalHours, 1))h)" -Level Debug
        # Remove expired entry (thread-safe)
        $script:ProfileCache.TryRemove($cacheKey, [ref]$null) | Out-Null
        return $null
    }

    return $cachedProfile
}

function Set-CachedProfile {
    <#
    .SYNOPSIS
        Stores directory profile in cache (thread-safe)
    .PARAMETER Profile
        Profile object to cache
    #>
    param(
        [PSCustomObject]$Profile
    )

    # Normalize path for cache key
    $cacheKey = Get-NormalizedCacheKey -Path $Profile.Path

    # Enforce cache size limit - if at max, remove oldest entries
    if ($script:ProfileCache.Count -ge $script:ProfileCacheMaxEntries) {
        # Remove oldest 10% of entries based on LastScanned
        $entriesToRemove = [math]::Ceiling($script:ProfileCacheMaxEntries * 0.1)
        $oldestEntries = $script:ProfileCache.ToArray() |
            Sort-Object { $_.Value.LastScanned } |
            Select-Object -First $entriesToRemove

        foreach ($entry in $oldestEntries) {
            $script:ProfileCache.TryRemove($entry.Key, [ref]$null) | Out-Null
        }
        Write-RobocurseLog "Cache at capacity, removed $entriesToRemove oldest entries" -Level Debug
    }

    # Thread-safe add or update using ConcurrentDictionary indexer
    $script:ProfileCache[$cacheKey] = $Profile
    Write-RobocurseLog "Cached profile for: $($Profile.Path)" -Level Debug
}

function Clear-ProfileCache {
    <#
    .SYNOPSIS
        Clears the directory profile cache
    .DESCRIPTION
        Removes all entries from the profile cache. Call this between
        replication runs or when memory pressure is a concern.
    .EXAMPLE
        Clear-ProfileCache
    #>

    $count = $script:ProfileCache.Count
    $script:ProfileCache.Clear()
    Write-RobocurseLog "Cleared profile cache ($count entries removed)" -Level Debug
}
