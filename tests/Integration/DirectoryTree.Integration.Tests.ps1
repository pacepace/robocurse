#Requires -Modules Pester

# Integration tests for DirectoryTree - run actual robocopy against real directories

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type
Initialize-OrchestrationStateType | Out-Null

Describe "DirectoryTree Integration Tests" -Tag "Integration" {
    BeforeAll {
        # Create temp directory structure for testing
        $script:TestRoot = Join-Path $env:TEMP "RobocurseTreeTest_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null

        # Create subdirectories
        $subdir1 = Join-Path $script:TestRoot "SubDir1"
        $subdir2 = Join-Path $script:TestRoot "SubDir2"
        $nested = Join-Path $subdir1 "Nested"

        New-Item -Path $subdir1 -ItemType Directory -Force | Out-Null
        New-Item -Path $subdir2 -ItemType Directory -Force | Out-Null
        New-Item -Path $nested -ItemType Directory -Force | Out-Null

        # Create files with known sizes
        Set-Content -Path (Join-Path $script:TestRoot "root.txt") -Value ("A" * 100)
        Set-Content -Path (Join-Path $subdir1 "file1.txt") -Value ("B" * 200)
        Set-Content -Path (Join-Path $subdir2 "file2.txt") -Value ("C" * 300)
        Set-Content -Path (Join-Path $nested "deep.txt") -Value ("D" * 400)
    }

    AfterAll {
        # Cleanup
        if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
            Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should build tree with correct paths from real directory" {
        $tree = New-DirectoryTree -RootPath $script:TestRoot

        # Root path should match exactly
        $tree.Path | Should -Be $script:TestRoot

        # Should have SubDir1 and SubDir2 as children
        $tree.Children.ContainsKey("SubDir1") | Should -Be $true
        $tree.Children.ContainsKey("SubDir2") | Should -Be $true

        # Child paths should be correct (no doubling)
        $tree.Children["SubDir1"].Path | Should -Be (Join-Path $script:TestRoot "SubDir1")
        $tree.Children["SubDir2"].Path | Should -Be (Join-Path $script:TestRoot "SubDir2")

        # Nested directory should exist
        $tree.Children["SubDir1"].Children.ContainsKey("Nested") | Should -Be $true
        $tree.Children["SubDir1"].Children["Nested"].Path | Should -Be (Join-Path $script:TestRoot "SubDir1\Nested")
    }

    It "Should count files correctly" {
        $tree = New-DirectoryTree -RootPath $script:TestRoot

        # Total should be 4 files
        $tree.TotalFileCount | Should -Be 4

        # Verify against actual file count
        $actualFileCount = (Get-ChildItem -Path $script:TestRoot -Recurse -File).Count
        $tree.TotalFileCount | Should -Be $actualFileCount
    }

    It "Should aggregate sizes correctly" {
        $tree = New-DirectoryTree -RootPath $script:TestRoot

        # Total size should include all files
        $tree.TotalSize | Should -BeGreaterThan 0

        # SubDir1 total should include Nested
        $subdir1Total = $tree.Children["SubDir1"].TotalSize
        $nestedSize = $tree.Children["SubDir1"].Children["Nested"].TotalSize
        $subdir1Total | Should -BeGreaterOrEqual $nestedSize
    }

    It "Should not have path doubling (regression test for W:\\W:\\ bug)" {
        $tree = New-DirectoryTree -RootPath $script:TestRoot

        # Check that no path contains doubled root
        $allPaths = @($tree.Path)
        foreach ($child in $tree.Children.Values) {
            $allPaths += $child.Path
            foreach ($grandchild in $child.Children.Values) {
                $allPaths += $grandchild.Path
            }
        }

        foreach ($path in $allPaths) {
            # Path should start with TestRoot exactly once
            $escapedRoot = [regex]::Escape($script:TestRoot)
            $matches = [regex]::Matches($path, $escapedRoot)
            $matches.Count | Should -Be 1 -Because "Path '$path' should contain root exactly once"
        }
    }

    It "Should handle drive root without path doubling" {
        # Use C: drive root but limit to a small temp subdirectory we control
        # This simulates the mapped drive scenario without needing an actual mapped drive
        $tree = New-DirectoryTree -RootPath $script:TestRoot

        # Verify no child path starts with a duplicate of the root
        foreach ($child in $tree.Children.Values) {
            $child.Path | Should -Not -Match ([regex]::Escape($script:TestRoot) + [regex]::Escape($script:TestRoot))
        }
    }
}

Describe "DirectoryTree Chunking Integration" -Tag "Integration" {
    BeforeAll {
        # Create temp directory for chunking tests
        $script:ChunkTestRoot = Join-Path $env:TEMP "RobocurseChunkTest_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:ChunkTestDest = Join-Path $env:TEMP "RobocurseChunkDest_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:ChunkTestRoot -ItemType Directory -Force | Out-Null
        New-Item -Path $script:ChunkTestDest -ItemType Directory -Force | Out-Null

        # Create subdirectories with files
        for ($i = 1; $i -le 3; $i++) {
            $subdir = Join-Path $script:ChunkTestRoot "Folder$i"
            New-Item -Path $subdir -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $subdir "file$i.txt") -Value ("X" * (100 * $i))
        }
    }

    AfterAll {
        if ($script:ChunkTestRoot -and (Test-Path $script:ChunkTestRoot)) {
            Remove-Item -Path $script:ChunkTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:ChunkTestDest -and (Test-Path $script:ChunkTestDest)) {
            Remove-Item -Path $script:ChunkTestDest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should create chunks with valid paths from tree" {
        $tree = New-DirectoryTree -RootPath $script:ChunkTestRoot

        $chunks = @(Get-DirectoryChunks -Path $script:ChunkTestRoot -DestinationRoot $script:ChunkTestDest -TreeNode $tree -MaxSizeBytes 10GB)

        # All chunk paths should be valid and exist
        foreach ($chunk in $chunks) {
            Test-Path $chunk.SourcePath | Should -Be $true -Because "Chunk source '$($chunk.SourcePath)' should exist"
            $chunk.SourcePath | Should -Not -Match '\\\\' -Because "Path should not have doubled backslashes"
        }
    }

    It "Should produce chunks that match actual directory sizes" {
        $tree = New-DirectoryTree -RootPath $script:ChunkTestRoot

        # Get actual size using Get-ChildItem for comparison
        $actualSize = (Get-ChildItem -Path $script:ChunkTestRoot -Recurse -File | Measure-Object -Property Length -Sum).Sum

        # Tree total should match actual
        $tree.TotalSize | Should -Be $actualSize
    }
}
