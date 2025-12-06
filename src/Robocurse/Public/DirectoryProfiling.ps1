# Robocurse Directory profiling Functions
# Script-level cache for directory profiles (thread-safe)
# Uses OrdinalIgnoreCase comparer for Windows-style case-insensitive path matching
# This is more correct than ToLowerInvariant() for international characters
$script:ProfileCache = [System.Collections.Concurrent.ConcurrentDictionary[string, PSCustomObject]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

# Cache statistics tracking (thread-safe via Interlocked operations)
$script:ProfileCacheHits = 0
$script:ProfileCacheMisses = 0
$script:ProfileCacheEvictions = 0

function Get-ProfileCacheStatistics {
    <#
    .SYNOPSIS
        Returns statistics about the directory profile cache
    .DESCRIPTION
        Provides cache performance metrics including:
        - Entry count
        - Hit/miss counts and hit rate
        - Eviction count
        - Estimated memory usage
    .OUTPUTS
        PSCustomObject with cache statistics
    .EXAMPLE
        $stats = Get-ProfileCacheStatistics
        Write-Host "Cache hit rate: $($stats.HitRatePercent)%"
    #>
    [CmdletBinding()]
    param()

    $hits = [System.Threading.Interlocked]::CompareExchange([ref]$script:ProfileCacheHits, 0, 0)
    $misses = [System.Threading.Interlocked]::CompareExchange([ref]$script:ProfileCacheMisses, 0, 0)
    $evictions = [System.Threading.Interlocked]::CompareExchange([ref]$script:ProfileCacheEvictions, 0, 0)
    $entryCount = $script:ProfileCache.Count

    $totalRequests = $hits + $misses
    $hitRate = if ($totalRequests -gt 0) {
        [math]::Round(($hits / $totalRequests) * 100, 1)
    } else { 0 }

    # Estimate memory usage (rough approximation)
    # Each entry has: path string (~100 bytes avg) + profile object (~500 bytes avg)
    $estimatedBytesPerEntry = 600
    $estimatedMemoryBytes = $entryCount * $estimatedBytesPerEntry

    return [PSCustomObject]@{
        EntryCount = $entryCount
        MaxEntries = $script:ProfileCacheMaxEntries
        Hits = $hits
        Misses = $misses
        HitRatePercent = $hitRate
        Evictions = $evictions
        EstimatedMemoryMB = [math]::Round($estimatedMemoryBytes / 1MB, 2)
    }
}

function Reset-ProfileCacheStatistics {
    <#
    .SYNOPSIS
        Resets the cache statistics counters
    .DESCRIPTION
        Clears hit, miss, and eviction counters. Useful for benchmarking
        or measuring cache effectiveness over a specific time period.
    #>
    [CmdletBinding()]
    param()

    [System.Threading.Interlocked]::Exchange([ref]$script:ProfileCacheHits, 0) | Out-Null
    [System.Threading.Interlocked]::Exchange([ref]$script:ProfileCacheMisses, 0) | Out-Null
    [System.Threading.Interlocked]::Exchange([ref]$script:ProfileCacheEvictions, 0) | Out-Null

    Write-RobocurseLog "Profile cache statistics reset" -Level Debug -Component 'Cache'
}

function Invoke-RobocopyList {
    <#
    .SYNOPSIS
        Runs robocopy in list-only mode (wrapper for testing/mocking)
    .PARAMETER Source
        Source path to list
    .OUTPUTS
        Array of output lines from robocopy
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source
    )

    # Wrapper so we can mock this in tests
    # Use a non-existent temp path as destination - robocopy /L lists without creating it
    # Note: \\?\NULL doesn't work on all Windows versions, and src=dest doesn't list files
    $nullDest = Join-Path $env:TEMP "robocurse-null-$(Get-Random)"
    $output = & robocopy $Source $nullDest /L /E /NJH /NJS /BYTES /R:0 /W:0 2>&1
    # Ensure we always return an array (robocopy can return empty/null for root drives)
    if ($null -eq $output) {
        return @()
    }
    return @($output)
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [AllowEmptyString()]
        [string[]]$Output
    )

    # Handle null or empty output gracefully
    if ($null -eq $Output -or $Output.Count -eq 0) {
        return [PSCustomObject]@{
            TotalSize = 0
            FileCount = 0
            DirCount = 0
            Files = @()
        }
    }

    $totalSize = 0
    $fileCount = 0
    $dirCount = 0
    $files = @()

    foreach ($line in $Output) {
        # Skip empty lines
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        # New File format: "    New File           2048    filename"
        if ($line -match 'New File\s+(\d+)\s+(.+)$') {
            $size = [int64]$matches[1]
            $path = $matches[2].Trim()
            $fileCount++
            $totalSize += $size
            $files += [PSCustomObject]@{
                Path = $path
                Size = $size
            }
        }
        # New Dir format: "  New Dir          3    D:\path\"
        elseif ($line -match 'New Dir\s+\d+\s+(.+)$') {
            $dirCount++
        }
        # Fallback: old format "          123456789    path\to\file.txt" (for compatibility)
        elseif ($line -match '^\s+(\d+)\s+(.+)$') {
            $size = [int64]$matches[1]
            $path = $matches[2].Trim()
            if ($path.EndsWith('\')) {
                $dirCount++
            }
            else {
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
    [CmdletBinding()]
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
    [CmdletBinding()]
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
    [CmdletBinding()]
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
    [CmdletBinding()]
    param(
        [string]$Path,
        [int]$MaxAgeHours = 24
    )

    # Normalize path for cache lookup
    $cacheKey = Get-NormalizedCacheKey -Path $Path

    # Thread-safe retrieval from ConcurrentDictionary
    $cachedProfile = $null
    if (-not $script:ProfileCache.TryGetValue($cacheKey, [ref]$cachedProfile)) {
        # Track cache miss (thread-safe)
        [System.Threading.Interlocked]::Increment([ref]$script:ProfileCacheMisses) | Out-Null
        return $null
    }

    # Check if cache is still valid
    $age = (Get-Date) - $cachedProfile.LastScanned
    if ($age.TotalHours -gt $MaxAgeHours) {
        Write-RobocurseLog "Cache expired for: $Path (age: $([math]::Round($age.TotalHours, 1))h)" -Level Debug
        # Remove expired entry (thread-safe)
        $script:ProfileCache.TryRemove($cacheKey, [ref]$null) | Out-Null
        # Track as miss (expired entry)
        [System.Threading.Interlocked]::Increment([ref]$script:ProfileCacheMisses) | Out-Null
        return $null
    }

    # Track cache hit (thread-safe)
    [System.Threading.Interlocked]::Increment([ref]$script:ProfileCacheHits) | Out-Null
    return $cachedProfile
}

function Set-CachedProfile {
    <#
    .SYNOPSIS
        Stores directory profile in cache (thread-safe)
    .DESCRIPTION
        Adds or updates a profile in the thread-safe cache. When the cache
        exceeds the maximum entry count, uses approximate LRU eviction
        (similar to Redis's approach) to remove old entries.

        The eviction logic is designed to be safe under concurrent access:
        - Uses TryAdd to prevent duplicate evictions
        - Tolerates slight over-capacity during concurrent adds
        - Does not require locks (relies on ConcurrentDictionary guarantees)
    .PARAMETER Profile
        Profile object to cache
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject]$Profile
    )

    # Normalize path for cache key
    $cacheKey = Get-NormalizedCacheKey -Path $Profile.Path

    # Thread-safe add or update using ConcurrentDictionary indexer
    # Do this FIRST to ensure the profile is always cached, even if eviction has issues
    $script:ProfileCache[$cacheKey] = $Profile
    Write-RobocurseLog "Cached profile for: $($Profile.Path)" -Level Debug

    # Enforce cache size limit - if significantly over max, trigger eviction
    # Use a 10% buffer to reduce eviction frequency under concurrent load
    $maxWithBuffer = [int]($script:ProfileCacheMaxEntries * 1.1)
    $currentCount = $script:ProfileCache.Count

    if ($currentCount -gt $maxWithBuffer) {
        # Use random sampling for approximate LRU eviction (similar to Redis's approach)
        # Instead of O(n log n) full sort, we sample and sort O(k log k) where k << n
        # This provides good-enough LRU behavior with much better performance
        $entriesToRemove = $currentCount - $script:ProfileCacheMaxEntries

        # Only evict if we have a meaningful number to remove (reduces contention)
        if ($entriesToRemove -gt 0) {
            # Sample size: 5x the entries to remove (gives good statistical coverage)
            # Clamp to currentCount to handle edge cases
            $sampleSize = [math]::Min($entriesToRemove * 5, $currentCount)

            # Take a snapshot for eviction - this is an atomic operation on ConcurrentDictionary
            $allEntries = $script:ProfileCache.ToArray()
            $snapshotCount = $allEntries.Count

            if ($snapshotCount -le $sampleSize) {
                # Small cache - just sort everything (fast enough)
                $sample = $allEntries
            }
            else {
                # Large cache - take random sample for approximate LRU
                $sample = $allEntries | Get-Random -Count $sampleSize
            }

            # Sort only the sample and take oldest entries
            $oldestEntries = $sample |
                Sort-Object { $_.Value.LastScanned } |
                Select-Object -First $entriesToRemove

            $removed = 0
            foreach ($entry in $oldestEntries) {
                # TryRemove is atomic - if another thread already removed it, we just skip
                if ($script:ProfileCache.TryRemove($entry.Key, [ref]$null)) {
                    $removed++
                    # Track eviction (thread-safe)
                    [System.Threading.Interlocked]::Increment([ref]$script:ProfileCacheEvictions) | Out-Null
                }
            }

            if ($removed -gt 0) {
                Write-RobocurseLog "Cache eviction: removed $removed of $entriesToRemove targeted (sampled $sampleSize of $snapshotCount entries)" -Level Debug
            }
        }
    }
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
    [CmdletBinding()]
    param()

    $count = $script:ProfileCache.Count
    $script:ProfileCache.Clear()
    Write-RobocurseLog "Cleared profile cache ($count entries removed)" -Level Debug
}

function Get-DirectoryProfilesParallel {
    <#
    .SYNOPSIS
        Profiles multiple directories in parallel using runspaces
    .DESCRIPTION
        Profiles multiple directories concurrently for improved performance.
        Uses PowerShell runspaces for parallelism (works in PS 5.1+).

        For small numbers of directories (< 3), falls back to sequential
        profiling as the overhead of parallelism isn't worth it.
    .PARAMETER Paths
        Array of directory paths to profile
    .PARAMETER MaxDegreeOfParallelism
        Maximum concurrent profiling operations (default: 4)
    .PARAMETER UseCache
        Check cache before scanning (default: true)
    .OUTPUTS
        Hashtable mapping paths to profile objects
    .EXAMPLE
        $profiles = Get-DirectoryProfilesParallel -Paths @("C:\Data1", "C:\Data2", "C:\Data3")
        $profiles["C:\Data1"].TotalSize  # Access individual profile
    .EXAMPLE
        # Profile with higher parallelism for many directories
        $profiles = Get-DirectoryProfilesParallel -Paths $manyPaths -MaxDegreeOfParallelism 8
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths,

        [ValidateRange(1, 32)]
        [int]$MaxDegreeOfParallelism = 4,

        [bool]$UseCache = $true
    )

    $results = @{}

    # For small path counts, sequential is faster (avoids runspace overhead)
    if ($Paths.Count -lt 3) {
        foreach ($path in $Paths) {
            $results[$path] = Get-DirectoryProfile -Path $path -UseCache $UseCache
        }
        return $results
    }

    Write-RobocurseLog "Starting parallel profiling of $($Paths.Count) directories (max parallelism: $MaxDegreeOfParallelism)" -Level Debug

    # Check cache first for any paths that are already cached
    $pathsToProfile = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $Paths) {
        $normalizedPath = $path.TrimEnd('\')
        if ($UseCache) {
            $cached = Get-CachedProfile -Path $normalizedPath -MaxAgeHours $script:ProfileCacheMaxAgeHours
            if ($null -ne $cached) {
                $results[$path] = $cached
                continue
            }
        }
        $pathsToProfile.Add($path)
    }

    # If all paths were cached, return early
    if ($pathsToProfile.Count -eq 0) {
        Write-RobocurseLog "All $($Paths.Count) directories found in cache" -Level Debug
        return $results
    }

    Write-RobocurseLog "Profiling $($pathsToProfile.Count) directories (cached: $($results.Count))" -Level Debug

    try {
        # Create runspace pool
        $runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
            1,
            $MaxDegreeOfParallelism
        )
        $runspacePool.Open()

        $jobs = [System.Collections.Generic.List[PSCustomObject]]::new()

        # The script block to execute in each runspace
        $scriptBlock = {
            param($Path)

            try {
                # Run robocopy in list mode
                $output = & robocopy $Path "\\?\NULL" /L /E /NJH /NJS /BYTES /R:0 /W:0 2>&1

                $totalSize = 0
                $fileCount = 0
                $dirCount = 0

                foreach ($line in $output) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    if ($line -match '^\s+(\d+)\s+(.+)$') {
                        $size = [int64]$matches[1]
                        $filePath = $matches[2].Trim()
                        if ($filePath.EndsWith('\')) {
                            $dirCount++
                        }
                        else {
                            $fileCount++
                            $totalSize += $size
                        }
                    }
                }

                $avgFileSize = if ($fileCount -gt 0) { [math]::Round($totalSize / $fileCount, 0) } else { 0 }

                return [PSCustomObject]@{
                    Success = $true
                    Path = $Path.TrimEnd('\')
                    TotalSize = $totalSize
                    FileCount = $fileCount
                    DirCount = $dirCount
                    AvgFileSize = $avgFileSize
                    LastScanned = Get-Date
                }
            }
            catch {
                return [PSCustomObject]@{
                    Success = $false
                    Path = $Path.TrimEnd('\')
                    TotalSize = 0
                    FileCount = 0
                    DirCount = 0
                    AvgFileSize = 0
                    LastScanned = Get-Date
                    Error = $_.Exception.Message
                }
            }
        }

        # Start jobs for each path
        foreach ($path in $pathsToProfile) {
            $powershell = [System.Management.Automation.PowerShell]::Create()
            $powershell.RunspacePool = $runspacePool
            [void]$powershell.AddScript($scriptBlock)
            [void]$powershell.AddArgument($path)

            $jobs.Add([PSCustomObject]@{
                PowerShell = $powershell
                Handle = $powershell.BeginInvoke()
                Path = $path
            })
        }

        # Wait for all jobs to complete and collect results
        foreach ($job in $jobs) {
            try {
                $result = $job.PowerShell.EndInvoke($job.Handle)

                if ($result -and $result.Count -gt 0) {
                    $profile = $result[0]
                    if ($profile.Success) {
                        # Create profile object with success indicator
                        $profileObj = [PSCustomObject]@{
                            Path = $profile.Path
                            TotalSize = $profile.TotalSize
                            FileCount = $profile.FileCount
                            DirCount = $profile.DirCount
                            AvgFileSize = $profile.AvgFileSize
                            LastScanned = $profile.LastScanned
                            ProfileSuccess = $true
                        }
                        $results[$job.Path] = $profileObj
                        # Store in cache (without the ProfileSuccess property to save space)
                        $cacheObj = [PSCustomObject]@{
                            Path = $profile.Path
                            TotalSize = $profile.TotalSize
                            FileCount = $profile.FileCount
                            DirCount = $profile.DirCount
                            AvgFileSize = $profile.AvgFileSize
                            LastScanned = $profile.LastScanned
                        }
                        Set-CachedProfile -Profile $cacheObj
                    }
                    else {
                        Write-RobocurseLog "Error profiling '$($job.Path)': $($profile.Error)" -Level Warning
                        # Return profile with error indicator so callers can detect failure
                        $results[$job.Path] = [PSCustomObject]@{
                            Path = $job.Path.TrimEnd('\')
                            TotalSize = 0
                            FileCount = 0
                            DirCount = 0
                            AvgFileSize = 0
                            LastScanned = Get-Date
                            ProfileSuccess = $false
                            ProfileError = $profile.Error
                        }
                    }
                }
            }
            catch {
                Write-RobocurseLog "Error completing profile job for '$($job.Path)': $_" -Level Warning
                $results[$job.Path] = [PSCustomObject]@{
                    Path = $job.Path.TrimEnd('\')
                    TotalSize = 0
                    FileCount = 0
                    DirCount = 0
                    AvgFileSize = 0
                    LastScanned = Get-Date
                    ProfileSuccess = $false
                    ProfileError = $_.Exception.Message
                }
            }
            finally {
                # Wrap disposal in try-catch to prevent one failed disposal from
                # blocking cleanup of remaining jobs
                try { $job.PowerShell.Dispose() } catch { }
            }
        }

        Write-RobocurseLog "Completed parallel profiling of $($pathsToProfile.Count) directories" -Level Debug
    }
    finally {
        if ($runspacePool) {
            $runspacePool.Close()
            $runspacePool.Dispose()
        }
    }

    return $results
}
