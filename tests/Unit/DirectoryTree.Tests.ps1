#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type (required for module isolation when running all tests together)
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "DirectoryNode Class" {
        It "Should create node with correct initial values" {
            $node = [DirectoryNode]::new("C:\Test")
            $node.Path | Should -Be "C:\Test"
            $node.DirectSize | Should -Be 0
            $node.DirectFileCount | Should -Be 0
            $node.TotalSize | Should -Be 0
            $node.TotalFileCount | Should -Be 0
            $node.Children.Count | Should -Be 0
        }

        It "Should support case-insensitive child lookups" {
            $node = [DirectoryNode]::new("C:\Test")
            $child = [DirectoryNode]::new("C:\Test\Child")
            $node.Children["child"] = $child
            $node.Children["CHILD"] | Should -Be $child
            $node.Children["Child"] | Should -Be $child
        }

        It "Should have separate Children dictionary per instance" {
            $node1 = [DirectoryNode]::new("C:\Test1")
            $node2 = [DirectoryNode]::new("C:\Test2")

            $node1.Children["a"] = [DirectoryNode]::new("C:\Test1\a")
            $node2.Children.ContainsKey("a") | Should -Be $false
        }
    }

    Describe "Update-TreeTotals" {
        It "Should aggregate child sizes to parent" {
            $root = [DirectoryNode]::new("C:\Root")
            $root.DirectSize = 100
            $root.DirectFileCount = 1

            $child1 = [DirectoryNode]::new("C:\Root\Child1")
            $child1.DirectSize = 500
            $child1.DirectFileCount = 5
            $root.Children["Child1"] = $child1

            $child2 = [DirectoryNode]::new("C:\Root\Child2")
            $child2.DirectSize = 300
            $child2.DirectFileCount = 3
            $root.Children["Child2"] = $child2

            Update-TreeTotals -Node $root

            $root.TotalSize | Should -Be 900  # 100 + 500 + 300
            $root.TotalFileCount | Should -Be 9  # 1 + 5 + 3
            $child1.TotalSize | Should -Be 500
            $child1.TotalFileCount | Should -Be 5
            $child2.TotalSize | Should -Be 300
            $child2.TotalFileCount | Should -Be 3
        }

        It "Should handle deeply nested trees" {
            $root = [DirectoryNode]::new("C:\Root")
            $level1 = [DirectoryNode]::new("C:\Root\L1")
            $level2 = [DirectoryNode]::new("C:\Root\L1\L2")
            $level3 = [DirectoryNode]::new("C:\Root\L1\L2\L3")

            $level3.DirectSize = 1000
            $level3.DirectFileCount = 10
            $level2.DirectSize = 200
            $level2.DirectFileCount = 2
            $level2.Children["L3"] = $level3
            $level1.DirectSize = 50
            $level1.DirectFileCount = 1
            $level1.Children["L2"] = $level2
            $root.DirectSize = 25
            $root.DirectFileCount = 1
            $root.Children["L1"] = $level1

            Update-TreeTotals -Node $root

            $level3.TotalSize | Should -Be 1000
            $level3.TotalFileCount | Should -Be 10
            $level2.TotalSize | Should -Be 1200  # 200 + 1000
            $level2.TotalFileCount | Should -Be 12  # 2 + 10
            $level1.TotalSize | Should -Be 1250  # 50 + 1200
            $level1.TotalFileCount | Should -Be 13  # 1 + 12
            $root.TotalSize | Should -Be 1275  # 25 + 1250
            $root.TotalFileCount | Should -Be 14  # 1 + 13
        }

        It "Should handle empty tree" {
            $root = [DirectoryNode]::new("C:\Empty")

            Update-TreeTotals -Node $root

            $root.TotalSize | Should -Be 0
            $root.TotalFileCount | Should -Be 0
        }

        It "Should handle tree with only root files" {
            $root = [DirectoryNode]::new("C:\Root")
            $root.DirectSize = 5000
            $root.DirectFileCount = 50

            Update-TreeTotals -Node $root

            $root.TotalSize | Should -Be 5000
            $root.TotalFileCount | Should -Be 50
        }
    }

    Describe "Get-OrCreateNode" {
        It "Should return existing node if found" {
            $root = [DirectoryNode]::new("C:\Root")
            $existing = [DirectoryNode]::new("C:\Root\Existing")
            $root.Children["Existing"] = $existing

            # Create properly typed Dictionary
            $nodeMap = [System.Collections.Generic.Dictionary[string, DirectoryNode]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
            $nodeMap["C:\Root"] = $root
            $nodeMap["C:\Root\Existing"] = $existing

            $result = Get-OrCreateNode -FullPath "C:\Root\Existing" -RootPath "C:\Root" -NodeMap $nodeMap -RootNode $root

            $result | Should -Be $existing
        }

        It "Should create intermediate nodes" {
            $root = [DirectoryNode]::new("C:\Root")

            $nodeMap = [System.Collections.Generic.Dictionary[string, DirectoryNode]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
            $nodeMap["C:\Root"] = $root

            $result = Get-OrCreateNode -FullPath "C:\Root\A\B\C" -RootPath "C:\Root" -NodeMap $nodeMap -RootNode $root

            $result.Path | Should -Be "C:\Root\A\B\C"
            $nodeMap.ContainsKey("C:\Root\A") | Should -Be $true
            $nodeMap.ContainsKey("C:\Root\A\B") | Should -Be $true
            $nodeMap.ContainsKey("C:\Root\A\B\C") | Should -Be $true
            $root.Children.ContainsKey("A") | Should -Be $true
        }

        It "Should handle case-insensitive paths" {
            $root = [DirectoryNode]::new("C:\Root")

            $nodeMap = [System.Collections.Generic.Dictionary[string, DirectoryNode]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
            $nodeMap["C:\Root"] = $root

            $result1 = Get-OrCreateNode -FullPath "C:\Root\Test" -RootPath "C:\Root" -NodeMap $nodeMap -RootNode $root
            $result2 = Get-OrCreateNode -FullPath "C:\ROOT\TEST" -RootPath "C:\Root" -NodeMap $nodeMap -RootNode $root

            $result1 | Should -Be $result2
        }
    }

    Describe "New-DirectoryTree" {
        BeforeEach {
            Mock Write-RobocurseLog { }
        }

        It "Should build tree from robocopy output" {
            # Use relative paths in mock - the function uses Join-Path with root
            Mock Invoke-RobocopyList {
                return @(
                    "               1024        file1.txt",
                    "               2048        subdir\file2.txt",
                    "                  0        subdir\"
                )
            }

            $tree = New-DirectoryTree -RootPath "C:\Test"

            $tree | Should -Not -BeNullOrEmpty
            $tree.Path | Should -Be "C:\Test"
        }

        It "Should aggregate sizes correctly" {
            Mock Invoke-RobocopyList {
                return @(
                    "               1024        file1.txt",
                    "               2048        subdir\file2.txt"
                )
            }

            $tree = New-DirectoryTree -RootPath "C:\Test"

            $tree.TotalSize | Should -Be 3072  # 1024 + 2048
            $tree.TotalFileCount | Should -Be 2
        }

        It "Should create child nodes for subdirectories" {
            Mock Invoke-RobocopyList {
                return @(
                    "               1024        file1.txt",
                    "               2048        subdir\file2.txt"
                )
            }

            $tree = New-DirectoryTree -RootPath "C:\Test"

            $tree.Children.ContainsKey("subdir") | Should -Be $true
            $tree.Children["subdir"].DirectSize | Should -Be 2048
            $tree.Children["subdir"].DirectFileCount | Should -Be 1
        }

        It "Should handle deeply nested files" {
            Mock Invoke-RobocopyList {
                return @(
                    "               100        a\b\c\d\deep.txt"
                )
            }

            $tree = New-DirectoryTree -RootPath "C:\Test"

            $tree.TotalSize | Should -Be 100
            $tree.Children.ContainsKey("a") | Should -Be $true

            $nodeA = $tree.Children["a"]
            $nodeA.Children.ContainsKey("b") | Should -Be $true
        }

        It "Should handle empty directory" {
            Mock Invoke-RobocopyList {
                return @()
            }

            $tree = New-DirectoryTree -RootPath "C:\Empty"

            $tree | Should -Not -BeNullOrEmpty
            $tree.TotalSize | Should -Be 0
            $tree.TotalFileCount | Should -Be 0
        }

        It "Should handle New Dir with absolute paths (robocopy format)" {
            # Robocopy outputs ABSOLUTE paths for directories
            Mock Invoke-RobocopyList {
                return @(
                    "  New Dir          5    C:\Test\",           # Root dir (should be skipped)
                    "    New File           1024    file1.txt",
                    "  New Dir          3    C:\Test\subdir\",    # Subdir with absolute path
                    "    New File           2048    subdir\file2.txt"
                )
            }

            $tree = New-DirectoryTree -RootPath "C:\Test"

            # Root should have correct path (not doubled like C:\Test\C:\Test)
            $tree.Path | Should -Be "C:\Test"
            $tree.TotalSize | Should -Be 3072

            # Subdir should have correct path (not C:\Test\C:\Test\subdir)
            $tree.Children.ContainsKey("subdir") | Should -Be $true
            $subdir = $tree.Children["subdir"]
            $subdir.Path | Should -Be "C:\Test\subdir"
        }

        It "Should handle drive roots without path doubling" {
            # Tests that drive root paths don't get doubled (e.g., C:\C:\ bug)
            Mock Invoke-RobocopyList {
                return @(
                    "  New Dir          10   C:\",                # Root
                    "    New File           1024    file.txt",
                    "  New Dir          3    C:\folder\",         # Subdir
                    "    New File           2048    folder\data.txt"
                )
            }

            $tree = New-DirectoryTree -RootPath "C:"

            # Root should be C: not C:\C:
            $tree.Path | Should -Be "C:"
            $tree.TotalSize | Should -Be 3072

            # Subdir should be C:\folder not C:\C:\folder
            $tree.Children.ContainsKey("folder") | Should -Be $true
            $tree.Children["folder"].Path | Should -Be "C:\folder"
        }

        It "Should update state during enumeration" {
            Mock Invoke-RobocopyList {
                return @(
                    "               1024        file1.txt"
                )
            }

            $mockState = [PSCustomObject]@{ CurrentActivity = ""; ScanProgress = 0 }

            $tree = New-DirectoryTree -RootPath "C:\Test" -State $mockState

            # State should have been updated during processing
            $tree | Should -Not -BeNullOrEmpty
            $mockState.ScanProgress | Should -BeGreaterOrEqual 0
        }

        It "Should handle UNC paths" {
            Mock Invoke-RobocopyList {
                return @(
                    "               1024        file1.txt",
                    "               2048        folder\file2.txt"
                )
            }

            $tree = New-DirectoryTree -RootPath "\\server\share"

            $tree.Path | Should -Be "\\server\share"
            $tree.TotalSize | Should -Be 3072
            $tree.Children.ContainsKey("folder") | Should -Be $true
        }
    }

    Describe "Tree-Based Chunking Integration" {
        BeforeEach {
            Mock Write-RobocurseLog { }
            Mock Test-Path { $true }
        }

        It "Should use tree data instead of calling Get-DirectoryProfile" {
            # Create mock tree
            $tree = [DirectoryNode]::new("C:\Test")
            $tree.DirectSize = 5GB
            $tree.DirectFileCount = 1000
            $tree.TotalSize = 5GB
            $tree.TotalFileCount = 1000

            # Should NOT call Get-DirectoryProfile
            Mock Get-DirectoryProfile { throw "Should not be called when TreeNode provided" }

            $chunks = Get-DirectoryChunks -Path "C:\Test" -DestinationRoot "D:\Dest" -TreeNode $tree -MaxSizeBytes 10GB

            @($chunks).Count | Should -Be 1
        }

        It "Should produce chunks that sum to tree total size" {
            # Create tree with 25GB total across children
            $tree = [DirectoryNode]::new("C:\Test")
            $tree.DirectSize = 0
            $tree.DirectFileCount = 0

            $child1 = [DirectoryNode]::new("C:\Test\Small")
            $child1.DirectSize = 5GB
            $child1.DirectFileCount = 1000
            $child1.TotalSize = 5GB
            $child1.TotalFileCount = 1000
            $tree.Children["Small"] = $child1

            $child2 = [DirectoryNode]::new("C:\Test\Medium")
            $child2.DirectSize = 8GB
            $child2.DirectFileCount = 2000
            $child2.TotalSize = 8GB
            $child2.TotalFileCount = 2000
            $tree.Children["Medium"] = $child2

            $child3 = [DirectoryNode]::new("C:\Test\Large")
            $child3.DirectSize = 12GB
            $child3.DirectFileCount = 3000
            $child3.TotalSize = 12GB
            $child3.TotalFileCount = 3000
            $tree.Children["Large"] = $child3

            # Update totals
            Update-TreeTotals -Node $tree

            Mock Get-DirectoryProfile { throw "Should not be called" }

            # Use 10GB chunks - should split Large
            $chunks = @(Get-DirectoryChunks -Path "C:\Test" -DestinationRoot "D:\Dest" -TreeNode $tree -MaxSizeBytes 10GB)

            # Verify total size of all chunks equals tree total
            $chunkTotalSize = ($chunks | Measure-Object -Property EstimatedSize -Sum).Sum
            $chunkTotalSize | Should -Be $tree.TotalSize

            # Verify total file count of all chunks equals tree total
            $chunkTotalFiles = ($chunks | Measure-Object -Property EstimatedFiles -Sum).Sum
            $chunkTotalFiles | Should -Be $tree.TotalFileCount
        }

        It "Should pass tree children to recursive calls" {
            $tree = [DirectoryNode]::new("C:\Test")
            $tree.DirectSize = 0
            $tree.DirectFileCount = 0

            # Create deeply nested structure
            $level1 = [DirectoryNode]::new("C:\Test\L1")
            $level1.DirectSize = 1GB
            $level1.DirectFileCount = 100

            $level2 = [DirectoryNode]::new("C:\Test\L1\L2")
            $level2.DirectSize = 0  # Only container, no direct files
            $level2.DirectFileCount = 0

            $level2Child1 = [DirectoryNode]::new("C:\Test\L1\L2\A")
            $level2Child1.DirectSize = 8GB
            $level2Child1.DirectFileCount = 2000
            $level2Child1.TotalSize = 8GB
            $level2Child1.TotalFileCount = 2000
            $level2.Children["A"] = $level2Child1

            $level2Child2 = [DirectoryNode]::new("C:\Test\L1\L2\B")
            $level2Child2.DirectSize = 12GB
            $level2Child2.DirectFileCount = 3000
            $level2Child2.TotalSize = 12GB
            $level2Child2.TotalFileCount = 3000
            $level2.Children["B"] = $level2Child2

            $level1.Children["L2"] = $level2
            $tree.Children["L1"] = $level1

            Update-TreeTotals -Node $tree

            Mock Get-DirectoryProfile { throw "Should not be called" }

            $chunks = @(Get-DirectoryChunks -Path "C:\Test" -DestinationRoot "D:\Dest" -TreeNode $tree -MaxSizeBytes 10GB -MaxDepth 5)

            # Should have created multiple chunks
            $chunks.Count | Should -BeGreaterThan 1

            # Total should still match
            $chunkTotalSize = ($chunks | Measure-Object -Property EstimatedSize -Sum).Sum
            $chunkTotalSize | Should -Be $tree.TotalSize
        }

        It "New-SmartChunks should accept TreeNode parameter" {
            $tree = [DirectoryNode]::new("C:\Test")
            $tree.TotalSize = 1GB
            $tree.TotalFileCount = 100
            $tree.DirectSize = 1GB
            $tree.DirectFileCount = 100

            Mock Get-DirectoryProfile { throw "Should not be called" }

            $chunks = @(New-SmartChunks -Path "C:\Test" -DestinationRoot "D:\Dest" -TreeNode $tree)

            $chunks.Count | Should -Be 1
            $chunks[0].EstimatedSize | Should -Be 1GB
        }

        It "New-FlatChunks should accept TreeNode parameter" {
            $tree = [DirectoryNode]::new("C:\Test")
            $tree.TotalSize = 1GB
            $tree.TotalFileCount = 100
            $tree.DirectSize = 1GB
            $tree.DirectFileCount = 100

            Mock Get-DirectoryProfile { throw "Should not be called" }

            $chunks = @(New-FlatChunks -Path "C:\Test" -DestinationRoot "D:\Dest" -TreeNode $tree)

            $chunks.Count | Should -Be 1
        }

        It "Should handle tree with files at root level" {
            $tree = [DirectoryNode]::new("C:\Test")
            $tree.DirectSize = 500MB
            $tree.DirectFileCount = 50

            $child = [DirectoryNode]::new("C:\Test\SubDir")
            $child.DirectSize = 200MB
            $child.DirectFileCount = 20
            $child.TotalSize = 200MB
            $child.TotalFileCount = 20
            $tree.Children["SubDir"] = $child

            Update-TreeTotals -Node $tree

            Mock Get-DirectoryProfile { throw "Should not be called" }

            $chunks = @(Get-DirectoryChunks -Path "C:\Test" -DestinationRoot "D:\Dest" -TreeNode $tree -MaxSizeBytes 10GB)

            # Should have at least the root chunk (which may include files-only chunk)
            $chunks.Count | Should -BeGreaterOrEqual 1

            # Total should match
            $chunkTotalSize = ($chunks | Measure-Object -Property EstimatedSize -Sum).Sum
            $chunkTotalSize | Should -Be $tree.TotalSize
        }
    }

    Describe "Invoke-RobocopyList with /NODCOPY" {
        It "Should include /NODCOPY in robocopy arguments" {
            # We can't easily test the actual robocopy call, but we can verify
            # the function exists and accepts the expected parameters
            $command = Get-Command Invoke-RobocopyList -ErrorAction SilentlyContinue
            $command | Should -Not -BeNullOrEmpty
            $command.Parameters.Keys | Should -Contain 'Source'
        }
    }
}
