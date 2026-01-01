#Requires -Modules Pester

# Integration tests for Chunking - run actual chunking operations against real directories
# These tests use real directory structures and real robocopy /L enumeration (no mocks)

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type
Initialize-OrchestrationStateType | Out-Null

Describe "Chunking Integration Tests - Split Behavior" -Tag "Integration" {
    BeforeAll {
        # Create temp directory structure for testing split behavior
        # Structure: Root with 3 subdirs, each with enough data to force splitting
        $script:SplitTestRoot = Join-Path $env:TEMP "RobocurseChunkSplit_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:SplitTestDest = Join-Path $env:TEMP "RobocurseChunkSplitDest_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:SplitTestRoot -ItemType Directory -Force | Out-Null
        New-Item -Path $script:SplitTestDest -ItemType Directory -Force | Out-Null

        # Create 3 subdirectories, each with ~500KB of files
        # With MaxSizeBytes of 1MB, the 1.5MB total should trigger splitting into child dirs
        for ($i = 1; $i -le 3; $i++) {
            $subdir = Join-Path $script:SplitTestRoot "Folder$i"
            New-Item -Path $subdir -ItemType Directory -Force | Out-Null

            # Create files in each subdirectory (each folder gets ~500KB)
            for ($j = 1; $j -le 5; $j++) {
                $content = "X" * 100000  # ~100KB per file
                Set-Content -Path (Join-Path $subdir "file$j.txt") -Value $content
            }
        }

        # Also create some files at root level (~100KB)
        Set-Content -Path (Join-Path $script:SplitTestRoot "root_file1.txt") -Value ("R" * 50000)
        Set-Content -Path (Join-Path $script:SplitTestRoot "root_file2.txt") -Value ("R" * 50000)
    }

    AfterAll {
        # Cleanup
        if ($script:SplitTestRoot -and (Test-Path $script:SplitTestRoot)) {
            Remove-Item -Path $script:SplitTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:SplitTestDest -and (Test-Path $script:SplitTestDest)) {
            Remove-Item -Path $script:SplitTestDest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should split directory into multiple chunks when over threshold" {
        # Build tree with real robocopy enumeration
        $tree = New-DirectoryTree -RootPath $script:SplitTestRoot

        # Set MaxSizeBytes to 1MB (minimum allowed) - total is ~1.6MB so should split
        # MinSizeBytes to 1KB to allow small chunks
        $chunks = @(Get-DirectoryChunks -Path $script:SplitTestRoot -DestinationRoot $script:SplitTestDest -TreeNode $tree -MaxSizeBytes 1MB -MinSizeBytes 1KB)

        # Should have more than one chunk due to splitting (3 subdirs + files-only for root)
        $chunks.Count | Should -BeGreaterThan 1 -Because "Directory structure (~1.6MB) exceeds 1MB chunk threshold and should split"

        # Verify each chunk path exists
        foreach ($chunk in $chunks) {
            Test-Path $chunk.SourcePath | Should -Be $true -Because "Chunk source '$($chunk.SourcePath)' should exist on filesystem"
        }
    }

    It "Should have all chunk source paths as valid existing directories" {
        $tree = New-DirectoryTree -RootPath $script:SplitTestRoot
        $chunks = @(Get-DirectoryChunks -Path $script:SplitTestRoot -DestinationRoot $script:SplitTestDest -TreeNode $tree -MaxSizeBytes 1MB -MinSizeBytes 1KB)

        foreach ($chunk in $chunks) {
            # Source path should exist
            Test-Path $chunk.SourcePath | Should -Be $true

            # Source path should not have doubled root (regression test for W:\W:\ bug)
            $escapedRoot = [regex]::Escape($script:SplitTestRoot)
            $matches = [regex]::Matches($chunk.SourcePath, $escapedRoot)
            $matches.Count | Should -Be 1 -Because "Path '$($chunk.SourcePath)' should contain root exactly once (no path doubling)"
        }
    }
}

Describe "Chunking Integration Tests - Single Chunk" -Tag "Integration" {
    BeforeAll {
        # Create small directory structure that should NOT split
        $script:SmallTestRoot = Join-Path $env:TEMP "RobocurseChunkSmall_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:SmallTestDest = Join-Path $env:TEMP "RobocurseChunkSmallDest_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:SmallTestRoot -ItemType Directory -Force | Out-Null
        New-Item -Path $script:SmallTestDest -ItemType Directory -Force | Out-Null

        # Create a small subdirectory with few files (total < 100KB)
        $subdir = Join-Path $script:SmallTestRoot "SmallSub"
        New-Item -Path $subdir -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $script:SmallTestRoot "tiny.txt") -Value "small content"
        Set-Content -Path (Join-Path $subdir "tiny2.txt") -Value "also small content"
    }

    AfterAll {
        if ($script:SmallTestRoot -and (Test-Path $script:SmallTestRoot)) {
            Remove-Item -Path $script:SmallTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:SmallTestDest -and (Test-Path $script:SmallTestDest)) {
            Remove-Item -Path $script:SmallTestDest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should keep small directory as single chunk" {
        $tree = New-DirectoryTree -RootPath $script:SmallTestRoot

        # With 10MB max, this tiny directory should be a single chunk
        $chunks = @(Get-DirectoryChunks -Path $script:SmallTestRoot -DestinationRoot $script:SmallTestDest -TreeNode $tree -MaxSizeBytes 10MB -MinSizeBytes 1KB)

        $chunks.Count | Should -Be 1 -Because "Small directory should remain as single chunk"
        $chunks[0].SourcePath | Should -Be $script:SmallTestRoot
    }

    It "Should have correct size from tree data" {
        $tree = New-DirectoryTree -RootPath $script:SmallTestRoot
        $chunks = @(Get-DirectoryChunks -Path $script:SmallTestRoot -DestinationRoot $script:SmallTestDest -TreeNode $tree -MaxSizeBytes 10MB -MinSizeBytes 1KB)

        # Tree total should match chunk estimated size
        $chunks[0].EstimatedSize | Should -Be $tree.TotalSize
        $chunks[0].EstimatedFiles | Should -Be $tree.TotalFileCount
    }
}

Describe "Chunking Integration Tests - Depth Limit" -Tag "Integration" {
    BeforeAll {
        # Create deep directory structure for testing MaxDepth
        # Structure: Root > L1 > L2 > L3 > L4 with large files at each level
        $script:DeepTestRoot = Join-Path $env:TEMP "RobocurseChunkDeep_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:DeepTestDest = Join-Path $env:TEMP "RobocurseChunkDeepDest_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:DeepTestRoot -ItemType Directory -Force | Out-Null
        New-Item -Path $script:DeepTestDest -ItemType Directory -Force | Out-Null

        # Create nested structure with ~300KB at each level to exceed 1MB total
        $currentPath = $script:DeepTestRoot
        for ($depth = 1; $depth -le 4; $depth++) {
            # Create files at this level (~300KB per level)
            for ($f = 1; $f -le 3; $f++) {
                Set-Content -Path (Join-Path $currentPath "level${depth}_file$f.txt") -Value ("D" * 100000)
            }

            # Create next level subdirectory
            $nextPath = Join-Path $currentPath "Level$depth"
            New-Item -Path $nextPath -ItemType Directory -Force | Out-Null
            $currentPath = $nextPath
        }

        # Add files at deepest level
        for ($f = 1; $f -le 3; $f++) {
            Set-Content -Path (Join-Path $currentPath "deep_file$f.txt") -Value ("X" * 100000)
        }
    }

    AfterAll {
        if ($script:DeepTestRoot -and (Test-Path $script:DeepTestRoot)) {
            Remove-Item -Path $script:DeepTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:DeepTestDest -and (Test-Path $script:DeepTestDest)) {
            Remove-Item -Path $script:DeepTestDest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should stop splitting at max depth" {
        $tree = New-DirectoryTree -RootPath $script:DeepTestRoot

        # Set MaxDepth to 2 - chunks should not be deeper than 2 levels from root
        # Use 1MB threshold which should trigger splitting
        $chunks = @(Get-DirectoryChunks -Path $script:DeepTestRoot -DestinationRoot $script:DeepTestDest -TreeNode $tree -MaxSizeBytes 1MB -MaxDepth 2 -MinSizeBytes 1KB)

        # Verify no chunk is deeper than depth 2 from root
        foreach ($chunk in $chunks) {
            # Calculate depth relative to root
            $relativePath = $chunk.SourcePath.Substring($script:DeepTestRoot.Length).TrimStart('\', '/')
            if ([string]::IsNullOrEmpty($relativePath)) {
                $depth = 0
            } else {
                $depth = ($relativePath -split '\\' | Where-Object { $_ }).Count
            }

            $depth | Should -BeLessOrEqual 2 -Because "Chunk '$($chunk.SourcePath)' should not be deeper than MaxDepth (2)"
        }
    }

    It "Should accept large directory at max depth even if over threshold" {
        $tree = New-DirectoryTree -RootPath $script:DeepTestRoot

        # MaxDepth 0 means no recursion - everything should be one chunk regardless of size
        $chunks = @(Get-DirectoryChunks -Path $script:DeepTestRoot -DestinationRoot $script:DeepTestDest -TreeNode $tree -MaxSizeBytes 1MB -MaxDepth 0 -MinSizeBytes 1KB)

        $chunks.Count | Should -Be 1 -Because "MaxDepth 0 should prevent any splitting"
        $chunks[0].SourcePath | Should -Be $script:DeepTestRoot
    }
}

Describe "Chunking Integration Tests - Destination Path Computation" -Tag "Integration" {
    BeforeAll {
        # Create directory structure for testing destination path computation
        $script:PathTestRoot = Join-Path $env:TEMP "RobocurseChunkPath_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:PathTestDest = Join-Path $env:TEMP "RobocurseChunkPathDest_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:PathTestRoot -ItemType Directory -Force | Out-Null
        New-Item -Path $script:PathTestDest -ItemType Directory -Force | Out-Null

        # Create subdirectories with files (small enough to stay as single chunk)
        $sub1 = Join-Path $script:PathTestRoot "ProjectA"
        $sub2 = Join-Path $script:PathTestRoot "ProjectB"
        $nested = Join-Path $sub1 "Data"

        New-Item -Path $sub1 -ItemType Directory -Force | Out-Null
        New-Item -Path $sub2 -ItemType Directory -Force | Out-Null
        New-Item -Path $nested -ItemType Directory -Force | Out-Null

        # Add small files
        Set-Content -Path (Join-Path $script:PathTestRoot "root.txt") -Value "root content"
        Set-Content -Path (Join-Path $sub1 "project_a.txt") -Value "project a content"
        Set-Content -Path (Join-Path $sub2 "project_b.txt") -Value "project b content"
        Set-Content -Path (Join-Path $nested "data.txt") -Value "nested data content"
    }

    AfterAll {
        if ($script:PathTestRoot -and (Test-Path $script:PathTestRoot)) {
            Remove-Item -Path $script:PathTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:PathTestDest -and (Test-Path $script:PathTestDest)) {
            Remove-Item -Path $script:PathTestDest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should compute correct destination paths for chunks" {
        $tree = New-DirectoryTree -RootPath $script:PathTestRoot
        $chunks = @(Get-DirectoryChunks -Path $script:PathTestRoot -DestinationRoot $script:PathTestDest -TreeNode $tree -MaxSizeBytes 10GB -MinSizeBytes 1KB)

        foreach ($chunk in $chunks) {
            # Destination should mirror source structure
            $relPath = $chunk.SourcePath.Substring($script:PathTestRoot.Length).TrimStart('\', '/')

            if ([string]::IsNullOrEmpty($relPath)) {
                $expectedDest = $script:PathTestDest
            } else {
                $expectedDest = Join-Path $script:PathTestDest $relPath
            }

            $chunk.DestinationPath | Should -Be $expectedDest -Because "Chunk destination should mirror source structure"
        }
    }

    It "Should maintain path structure when splitting" {
        # Create larger files to force splitting
        Set-Content -Path (Join-Path $script:PathTestRoot "large1.txt") -Value ("L" * 400000)
        Set-Content -Path (Join-Path $script:PathTestRoot "ProjectA\large_a.txt") -Value ("A" * 400000)
        Set-Content -Path (Join-Path $script:PathTestRoot "ProjectB\large_b.txt") -Value ("B" * 400000)

        $tree = New-DirectoryTree -RootPath $script:PathTestRoot

        # Force splitting with 1MB threshold
        $chunks = @(Get-DirectoryChunks -Path $script:PathTestRoot -DestinationRoot $script:PathTestDest -TreeNode $tree -MaxSizeBytes 1MB -MinSizeBytes 1KB -MaxDepth 5)

        foreach ($chunk in $chunks) {
            # Each chunk's destination path should be under PathTestDest
            $chunk.DestinationPath | Should -BeLike "$($script:PathTestDest)*" -Because "All destinations should be under destination root"

            # Verify no path doubling in destinations
            $escapedDest = [regex]::Escape($script:PathTestDest)
            $matches = [regex]::Matches($chunk.DestinationPath, $escapedDest)
            $matches.Count | Should -Be 1 -Because "Destination path should contain dest root exactly once"
        }
    }

    It "Should have consistent source-destination path mapping" {
        $tree = New-DirectoryTree -RootPath $script:PathTestRoot
        $chunks = @(Get-DirectoryChunks -Path $script:PathTestRoot -DestinationRoot $script:PathTestDest -TreeNode $tree -MaxSizeBytes 1MB -MinSizeBytes 1KB -MaxDepth 5)

        foreach ($chunk in $chunks) {
            # Get relative portion of source
            $sourceRel = $chunk.SourcePath.Substring($script:PathTestRoot.Length).TrimStart('\', '/')

            # Get relative portion of destination
            $destRel = $chunk.DestinationPath.Substring($script:PathTestDest.Length).TrimStart('\', '/')

            # They should match (case-insensitive for Windows)
            $sourceRel.ToLowerInvariant() | Should -Be $destRel.ToLowerInvariant() -Because "Source and destination relative paths should match"
        }
    }
}

Describe "Chunking Integration Tests - Tree Size Validation" -Tag "Integration" {
    BeforeAll {
        # Create directory structure where we can verify sizes match filesystem
        $script:SizeTestRoot = Join-Path $env:TEMP "RobocurseChunkSize_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:SizeTestDest = Join-Path $env:TEMP "RobocurseChunkSizeDest_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:SizeTestRoot -ItemType Directory -Force | Out-Null
        New-Item -Path $script:SizeTestDest -ItemType Directory -Force | Out-Null

        # Create files with known sizes (large enough to exceed 1MB for splitting tests)
        $sub1 = Join-Path $script:SizeTestRoot "SubA"
        $sub2 = Join-Path $script:SizeTestRoot "SubB"
        New-Item -Path $sub1 -ItemType Directory -Force | Out-Null
        New-Item -Path $sub2 -ItemType Directory -Force | Out-Null

        # Create files with predictable content sizes (~600KB each dir)
        Set-Content -Path (Join-Path $script:SizeTestRoot "root1.txt") -Value ("A" * 200000)
        Set-Content -Path (Join-Path $sub1 "sub1_file.txt") -Value ("B" * 400000)
        Set-Content -Path (Join-Path $sub2 "sub2_file.txt") -Value ("C" * 500000)
    }

    AfterAll {
        if ($script:SizeTestRoot -and (Test-Path $script:SizeTestRoot)) {
            Remove-Item -Path $script:SizeTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:SizeTestDest -and (Test-Path $script:SizeTestDest)) {
            Remove-Item -Path $script:SizeTestDest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should produce chunks with total size matching actual filesystem size" {
        $tree = New-DirectoryTree -RootPath $script:SizeTestRoot

        # Get actual size from filesystem
        $actualSize = (Get-ChildItem -Path $script:SizeTestRoot -Recurse -File | Measure-Object -Property Length -Sum).Sum

        # Tree total should match actual
        $tree.TotalSize | Should -Be $actualSize -Because "Tree total size should match filesystem"
    }

    It "Should produce chunks with total file count matching actual filesystem count" {
        $tree = New-DirectoryTree -RootPath $script:SizeTestRoot

        # Get actual file count from filesystem
        $actualCount = (Get-ChildItem -Path $script:SizeTestRoot -Recurse -File).Count

        # Tree total should match actual
        $tree.TotalFileCount | Should -Be $actualCount -Because "Tree file count should match filesystem"
    }

    It "Should have chunk estimated sizes summing to tree total when split" {
        $tree = New-DirectoryTree -RootPath $script:SizeTestRoot

        # Use 1MB threshold to force splitting (total is ~1.1MB)
        $chunks = @(Get-DirectoryChunks -Path $script:SizeTestRoot -DestinationRoot $script:SizeTestDest -TreeNode $tree -MaxSizeBytes 1MB -MinSizeBytes 1KB -MaxDepth 5)

        # Sum of all chunk sizes should equal tree total
        $chunkTotalSize = ($chunks | Measure-Object -Property EstimatedSize -Sum).Sum
        $chunkTotalSize | Should -Be $tree.TotalSize -Because "Sum of chunk sizes should equal tree total"
    }

    It "Should have chunk estimated file counts summing to tree total when split" {
        $tree = New-DirectoryTree -RootPath $script:SizeTestRoot

        # Use 1MB threshold to force splitting
        $chunks = @(Get-DirectoryChunks -Path $script:SizeTestRoot -DestinationRoot $script:SizeTestDest -TreeNode $tree -MaxSizeBytes 1MB -MinSizeBytes 1KB -MaxDepth 5)

        # Sum of all chunk file counts should equal tree total
        $chunkTotalFiles = ($chunks | Measure-Object -Property EstimatedFiles -Sum).Sum
        $chunkTotalFiles | Should -Be $tree.TotalFileCount -Because "Sum of chunk file counts should equal tree total"
    }
}

Describe "Chunking Integration Tests - Files-Only Chunks" -Tag "Integration" {
    BeforeAll {
        # Create directory structure with files at intermediate levels
        $script:FilesOnlyTestRoot = Join-Path $env:TEMP "RobocurseChunkFilesOnly_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:FilesOnlyTestDest = Join-Path $env:TEMP "RobocurseChunkFilesOnlyDest_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:FilesOnlyTestRoot -ItemType Directory -Force | Out-Null
        New-Item -Path $script:FilesOnlyTestDest -ItemType Directory -Force | Out-Null

        # Create structure: Root has files AND subdirs
        # When root is split, files at root need their own "files-only" chunk
        $sub1 = Join-Path $script:FilesOnlyTestRoot "SubFolder1"
        $sub2 = Join-Path $script:FilesOnlyTestRoot "SubFolder2"
        New-Item -Path $sub1 -ItemType Directory -Force | Out-Null
        New-Item -Path $sub2 -ItemType Directory -Force | Out-Null

        # Large files at root level (~500KB)
        Set-Content -Path (Join-Path $script:FilesOnlyTestRoot "root_large1.txt") -Value ("R" * 250000)
        Set-Content -Path (Join-Path $script:FilesOnlyTestRoot "root_large2.txt") -Value ("R" * 250000)

        # Large files in subdirectories (~500KB each)
        Set-Content -Path (Join-Path $sub1 "sub1_file.txt") -Value ("S" * 500000)
        Set-Content -Path (Join-Path $sub2 "sub2_file.txt") -Value ("S" * 500000)
    }

    AfterAll {
        if ($script:FilesOnlyTestRoot -and (Test-Path $script:FilesOnlyTestRoot)) {
            Remove-Item -Path $script:FilesOnlyTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:FilesOnlyTestDest -and (Test-Path $script:FilesOnlyTestDest)) {
            Remove-Item -Path $script:FilesOnlyTestDest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should create files-only chunk when directory has both files and subdirs and is split" {
        $tree = New-DirectoryTree -RootPath $script:FilesOnlyTestRoot

        # Force splitting with 1MB threshold (total is ~1.5MB)
        $chunks = @(Get-DirectoryChunks -Path $script:FilesOnlyTestRoot -DestinationRoot $script:FilesOnlyTestDest -TreeNode $tree -MaxSizeBytes 1MB -MinSizeBytes 1KB -MaxDepth 5)

        # Should have at least one files-only chunk for root level files
        $filesOnlyChunks = @($chunks | Where-Object { $_.IsFilesOnly -eq $true })
        $filesOnlyChunks.Count | Should -BeGreaterThan 0 -Because "Root level has files that need files-only chunk when subdirs are split out"
    }

    It "Should have /LEV:1 argument in files-only chunks" {
        $tree = New-DirectoryTree -RootPath $script:FilesOnlyTestRoot

        # Force splitting
        $chunks = @(Get-DirectoryChunks -Path $script:FilesOnlyTestRoot -DestinationRoot $script:FilesOnlyTestDest -TreeNode $tree -MaxSizeBytes 1MB -MinSizeBytes 1KB -MaxDepth 5)

        $filesOnlyChunks = @($chunks | Where-Object { $_.IsFilesOnly -eq $true })
        foreach ($chunk in $filesOnlyChunks) {
            $chunk.RobocopyArgs | Should -Contain "/LEV:1" -Because "Files-only chunks use /LEV:1 to copy only at that level"
        }
    }
}

Describe "Chunking Integration Tests - Path Doubling Regression" -Tag "Integration" {
    BeforeAll {
        # Create temp directory to test the path doubling bug regression
        $script:PathDoublingRoot = Join-Path $env:TEMP "RobocursePathDouble_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:PathDoublingDest = Join-Path $env:TEMP "RobocursePathDoubleDest_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:PathDoublingRoot -ItemType Directory -Force | Out-Null
        New-Item -Path $script:PathDoublingDest -ItemType Directory -Force | Out-Null

        # Create nested structure with large files to trigger splitting
        $nested = Join-Path $script:PathDoublingRoot "Level1\Level2\Level3"
        New-Item -Path $nested -ItemType Directory -Force | Out-Null

        # Add large files at various levels (~400KB each to total >1MB)
        Set-Content -Path (Join-Path $script:PathDoublingRoot "root.txt") -Value ("X" * 400000)
        Set-Content -Path (Join-Path $script:PathDoublingRoot "Level1\l1.txt") -Value ("X" * 400000)
        Set-Content -Path (Join-Path $script:PathDoublingRoot "Level1\Level2\l2.txt") -Value ("X" * 400000)
        Set-Content -Path (Join-Path $nested "l3.txt") -Value ("X" * 400000)
    }

    AfterAll {
        if ($script:PathDoublingRoot -and (Test-Path $script:PathDoublingRoot)) {
            Remove-Item -Path $script:PathDoublingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:PathDoublingDest -and (Test-Path $script:PathDoublingDest)) {
            Remove-Item -Path $script:PathDoublingDest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should not have path doubling in any chunk source path (regression test for W:\\W:\\ bug)" {
        $tree = New-DirectoryTree -RootPath $script:PathDoublingRoot

        # Force deep splitting with 1MB threshold (total is ~1.6MB)
        $chunks = @(Get-DirectoryChunks -Path $script:PathDoublingRoot -DestinationRoot $script:PathDoublingDest -TreeNode $tree -MaxSizeBytes 1MB -MinSizeBytes 1KB -MaxDepth 10)

        foreach ($chunk in $chunks) {
            # Path should not contain doubled backslashes (except UNC prefix)
            $pathWithoutUnc = $chunk.SourcePath
            if ($pathWithoutUnc.StartsWith("\\")) {
                $pathWithoutUnc = $pathWithoutUnc.Substring(2)
            }
            $pathWithoutUnc | Should -Not -Match '\\\\' -Because "Path '$($chunk.SourcePath)' should not have doubled backslashes"

            # Path should contain root exactly once
            $escapedRoot = [regex]::Escape($script:PathDoublingRoot)
            $matches = [regex]::Matches($chunk.SourcePath, $escapedRoot)
            $matches.Count | Should -Be 1 -Because "Path '$($chunk.SourcePath)' should contain root exactly once"
        }
    }

    It "Should not have path doubling in any chunk destination path" {
        $tree = New-DirectoryTree -RootPath $script:PathDoublingRoot

        $chunks = @(Get-DirectoryChunks -Path $script:PathDoublingRoot -DestinationRoot $script:PathDoublingDest -TreeNode $tree -MaxSizeBytes 1MB -MinSizeBytes 1KB -MaxDepth 10)

        foreach ($chunk in $chunks) {
            # Destination should contain dest root exactly once
            $escapedDest = [regex]::Escape($script:PathDoublingDest)
            $matches = [regex]::Matches($chunk.DestinationPath, $escapedDest)
            $matches.Count | Should -Be 1 -Because "Destination path '$($chunk.DestinationPath)' should contain dest root exactly once"
        }
    }
}
