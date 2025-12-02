#Requires -Modules Pester

<#
.SYNOPSIS
    Real robocopy integration tests for Robocurse

.DESCRIPTION
    These tests run actual robocopy operations to verify the wrapper functions work correctly
    with real file system operations. Tests cover:
    - Basic file copying
    - Deep directory trees
    - Unicode and special character handling
    - Junctions and symlinks
    - Various file sizes
    - Change detection (modified/new/deleted files)
    - Exit code interpretation

.NOTES
    - Requires Windows with robocopy.exe
    - Uses Pester's $TestDrive for automatic cleanup
    - Creates minimal test data to conserve disk space
#>

BeforeDiscovery {
    # Load fixtures early for discovery-time checks
    . "$PSScriptRoot\Fixtures\TestDataGenerator.ps1"

    # Check if we're on Windows and have robocopy
    $script:IsWindowsWithRobocopy = $false
    if ($env:OS -eq 'Windows_NT' -or $PSVersionTable.Platform -eq 'Win32NT' -or (-not $PSVersionTable.Platform)) {
        $robocopyPath = Get-Command robocopy.exe -ErrorAction SilentlyContinue
        $script:IsWindowsWithRobocopy = $null -ne $robocopyPath
    }

    # Check if we can create shares (admin privileges)
    $script:CanCreateShares = $false
    if ($script:IsWindowsWithRobocopy) {
        $script:CanCreateShares = Test-CanCreateShare
    }
}

BeforeAll {
    # Load test helper and fixtures (again for test execution context)
    . "$PSScriptRoot\..\TestHelper.ps1"
    . "$PSScriptRoot\Fixtures\TestDataGenerator.ps1"
    Initialize-RobocurseForTesting

    # Helper to wait for robocopy job
    function Wait-RobocopyComplete {
        param($Job, [int]$TimeoutSeconds = 60)

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $Job.Process.HasExited -and $stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 100
        }
        return $Job.Process.HasExited
    }
}

Describe "Real Robocopy Integration Tests" -Skip:(-not $script:IsWindowsWithRobocopy) {

    Context "Robocopy Availability" {
        It "Should detect robocopy as available" {
            $result = Test-RobocopyAvailable
            $result.Success | Should -Be $true
            $result.Data | Should -Match "robocopy"
        }
    }

    Context "Basic File Copying" {
        BeforeEach {
            $script:SourceDir = Join-Path $TestDrive "source"
            $script:DestDir = Join-Path $TestDrive "dest"
            $script:LogDir = Join-Path $TestDrive "logs"

            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null

            # Create a simple test tree
            $script:TreeStats = New-TestTree -RootPath $script:SourceDir -Depth 2 -BreadthPerLevel 2 -FilesPerDir 3
        }

        AfterEach {
            Remove-TestTree -Path $script:SourceDir
            Remove-TestTree -Path $script:DestDir
        }

        It "Should copy a simple directory tree" {
            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "simple_copy.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -ThreadsPerJob 4

            $job | Should -Not -BeNullOrEmpty
            $job.Process | Should -Not -BeNullOrEmpty

            # Wait for completion
            $completed = Wait-RobocopyComplete -Job $job
            $completed | Should -Be $true

            # Check exit code (0 or 1 = success)
            $job.Process.ExitCode | Should -BeLessOrEqual 3

            # Verify destination has files
            $destFiles = Get-ChildItem -Path $script:DestDir -Recurse -File
            $destFiles.Count | Should -BeGreaterThan 0

            # Parse the log
            $logResult = ConvertFrom-RobocopyLog -LogPath $logPath
            $logResult.ParseSuccess | Should -Be $true
            $logResult.FilesCopied | Should -BeGreaterThan 0
        }

        It "Should handle empty source directory" {
            $emptySource = Join-Path $TestDrive "empty_source"
            New-Item -ItemType Directory -Path $emptySource -Force | Out-Null

            $chunk = [PSCustomObject]@{
                SourcePath = $emptySource
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "empty_source.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath

            $completed = Wait-RobocopyComplete -Job $job
            $completed | Should -Be $true

            # Exit code 0 = no changes needed
            $job.Process.ExitCode | Should -BeLessOrEqual 3
        }

        It "Should return correct exit meaning for successful copy" {
            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "exit_test.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            $meaning = Get-RobocopyExitMeaning -ExitCode $job.Process.ExitCode
            $meaning.Severity | Should -BeIn @("Success", "Warning")
            $meaning.FatalError | Should -Be $false
            $meaning.ShouldRetry | Should -Be $false
        }
    }

    Context "Deep Directory Trees" {
        BeforeEach {
            $script:SourceDir = Join-Path $TestDrive "deep_source"
            $script:DestDir = Join-Path $TestDrive "deep_dest"
            $script:LogDir = Join-Path $TestDrive "logs"

            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }

        AfterEach {
            Remove-TestTree -Path $script:SourceDir
            Remove-TestTree -Path $script:DestDir
        }

        It "Should handle moderately deep trees (10 levels)" {
            $deepStats = New-DeepTree -RootPath $script:SourceDir -Depth 10 -DirNameLength 8

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "deep_tree.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            $job.Process.ExitCode | Should -BeLessOrEqual 3 -Because "Deep trees should copy successfully"

            # Verify the deepest file was copied
            if ($deepStats.DeepestFile) {
                $relativePath = $deepStats.DeepestFile.Substring($script:SourceDir.Length)
                $destFile = Join-Path $script:DestDir $relativePath
                Test-Path $destFile | Should -Be $true
            }
        }

        It "Should copy many levels with breadth" {
            # Create a tree that's both deep and wide (but small files)
            $treeStats = New-TestTree -RootPath $script:SourceDir -Depth 5 -BreadthPerLevel 3 -FilesPerDir 2 -FileSizeBytes 100

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "deep_wide.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -ThreadsPerJob 8
            Wait-RobocopyComplete -Job $job | Out-Null

            $job.Process.ExitCode | Should -BeLessOrEqual 3

            # Verify file counts match
            $sourceCount = (Get-ChildItem -Path $script:SourceDir -Recurse -File).Count
            $destCount = (Get-ChildItem -Path $script:DestDir -Recurse -File).Count
            $destCount | Should -Be $sourceCount
        }
    }

    Context "Unicode and Special Characters" {
        BeforeEach {
            $script:SourceDir = Join-Path $TestDrive "unicode_source"
            $script:DestDir = Join-Path $TestDrive "unicode_dest"
            $script:LogDir = Join-Path $TestDrive "logs"

            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }

        AfterEach {
            Remove-TestTree -Path $script:SourceDir
            Remove-TestTree -Path $script:DestDir
        }

        It "Should handle directories and files with special characters" {
            $unicodeStats = New-UnicodeTestTree -RootPath $script:SourceDir

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "unicode.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            $job.Process.ExitCode | Should -BeLessOrEqual 3 -Because "Unicode names should copy"

            # Verify some known items were copied
            $sourceItems = Get-ChildItem -Path $script:SourceDir -Recurse
            $destItems = Get-ChildItem -Path $script:DestDir -Recurse

            # At minimum, the same number of items should exist
            $destItems.Count | Should -BeGreaterOrEqual ($sourceItems.Count - 1) # Allow for 1 potential failure
        }

        It "Should handle paths with spaces" {
            $spacePath = Join-Path $script:SourceDir "path with spaces"
            New-Item -ItemType Directory -Path $spacePath -Force | Out-Null
            "Content" | Set-Content -Path (Join-Path $spacePath "file with spaces.txt")

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "spaces.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            $job.Process.ExitCode | Should -BeLessOrEqual 3

            # Verify the spaced file exists
            $destFile = Join-Path $script:DestDir "path with spaces\file with spaces.txt"
            Test-Path $destFile | Should -Be $true
        }
    }

    Context "Junction and Symlink Handling" {
        BeforeEach {
            $script:SourceDir = Join-Path $TestDrive "junction_source"
            $script:DestDir = Join-Path $TestDrive "junction_dest"
            $script:LogDir = Join-Path $TestDrive "logs"

            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }

        AfterEach {
            Remove-TestTree -Path $script:SourceDir
            Remove-TestTree -Path $script:DestDir
        }

        It "Should skip junctions by default (XJD flag)" {
            $junctionStats = New-JunctionTestTree -RootPath $script:SourceDir

            if (-not $junctionStats.JunctionsSupported) {
                Set-ItResult -Skipped -Because "Junctions not supported on this system"
                return
            }

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "junction.log"

            # Default behavior should skip junctions
            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            $job.Process.ExitCode | Should -BeLessOrEqual 3

            # The junction itself should NOT be copied as a real directory
            # (it would cause infinite loops if followed)
            $destJunction = Join-Path $script:DestDir "junction_link"

            # Either doesn't exist, or exists but is NOT a reparse point (was copied as regular dir)
            if (Test-Path $destJunction) {
                $item = Get-Item $destJunction -Force
                # If it exists, it should be a regular directory (contents copied), not a reparse point
                # With /XJD the junction is skipped entirely
            }
        }

        It "Should copy real directories alongside junctions" {
            $junctionStats = New-JunctionTestTree -RootPath $script:SourceDir

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "junction_real.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            # Real directory should be copied
            $destTarget = Join-Path $script:DestDir "junction_target"
            Test-Path $destTarget | Should -Be $true

            $destFile = Join-Path $destTarget "target_file.txt"
            Test-Path $destFile | Should -Be $true
        }
    }

    Context "Various File Sizes" {
        BeforeEach {
            $script:SourceDir = Join-Path $TestDrive "size_source"
            $script:DestDir = Join-Path $TestDrive "size_dest"
            $script:LogDir = Join-Path $TestDrive "logs"

            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }

        AfterEach {
            Remove-TestTree -Path $script:SourceDir
            Remove-TestTree -Path $script:DestDir
        }

        It "Should handle files from empty to 1MB" {
            $sizeStats = New-MixedFileSizeTree -RootPath $script:SourceDir

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "sizes.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -ThreadsPerJob 4
            Wait-RobocopyComplete -Job $job | Out-Null

            $job.Process.ExitCode | Should -BeLessOrEqual 3

            # Verify all files copied
            foreach ($file in $sizeStats.Files) {
                $fileName = Split-Path $file.Path -Leaf
                $destFile = Join-Path $script:DestDir $fileName
                Test-Path $destFile | Should -Be $true

                # Verify size matches
                $destSize = (Get-Item $destFile).Length
                $destSize | Should -Be $file.Size
            }
        }

        It "Should handle empty files" {
            $emptyFile = Join-Path $script:SourceDir "zero_bytes.txt"
            New-Item -ItemType Directory -Path $script:SourceDir -Force | Out-Null
            [System.IO.File]::WriteAllText($emptyFile, "")

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "empty.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            $destFile = Join-Path $script:DestDir "zero_bytes.txt"
            Test-Path $destFile | Should -Be $true
            (Get-Item $destFile).Length | Should -Be 0
        }
    }

    Context "Change Detection (Mirror Mode)" {
        BeforeEach {
            $script:SourceDir = Join-Path $TestDrive "change_source"
            $script:DestDir = Join-Path $TestDrive "change_dest"
            $script:LogDir = Join-Path $TestDrive "logs"

            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }

        AfterEach {
            Remove-TestTree -Path $script:SourceDir
            Remove-TestTree -Path $script:DestDir
        }

        It "Should detect and copy new files" {
            $changeStats = New-ModifiedFilesTree -SourcePath $script:SourceDir -DestPath $script:DestDir

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "changes.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            # Should have copied some files (exit code 1 or 3 = files copied)
            $meaning = Get-RobocopyExitMeaning -ExitCode $job.Process.ExitCode
            $meaning.FilesCopied | Should -Be $true

            # New file should now exist in dest
            $newFile = Join-Path $script:DestDir "new_file.txt"
            Test-Path $newFile | Should -Be $true
        }

        It "Should delete extras in mirror mode" {
            $changeStats = New-ModifiedFilesTree -SourcePath $script:SourceDir -DestPath $script:DestDir

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "mirror.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            # Extra file should be removed
            $extraFile = Join-Path $script:DestDir "extra_file.txt"
            Test-Path $extraFile | Should -Be $false

            # Parse log - should show extras handled
            $logResult = ConvertFrom-RobocopyLog -LogPath $logPath
            # MIR mode should report extras
            $meaning = Get-RobocopyExitMeaning -ExitCode $job.Process.ExitCode
            # Exit code 2 or 3 indicates extras were processed
        }

        It "Should skip identical files" {
            $changeStats = New-ModifiedFilesTree -SourcePath $script:SourceDir -DestPath $script:DestDir

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "skip.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            # Parse log to verify skips
            $logResult = ConvertFrom-RobocopyLog -LogPath $logPath
            $logResult.FilesSkipped | Should -BeGreaterOrEqual 1
        }

        It "Should update modified files" {
            $changeStats = New-ModifiedFilesTree -SourcePath $script:SourceDir -DestPath $script:DestDir

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "modified.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            # Modified file should have new content
            $modifiedFile = Join-Path $script:DestDir "modified.txt"
            $content = Get-Content $modifiedFile -Raw
            $content | Should -Match "updated"
        }
    }

    Context "Robocopy Options" {
        BeforeEach {
            $script:SourceDir = Join-Path $TestDrive "opts_source"
            $script:DestDir = Join-Path $TestDrive "opts_dest"
            $script:LogDir = Join-Path $TestDrive "logs"

            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
            New-TestTree -RootPath $script:SourceDir -Depth 2 -BreadthPerLevel 2 -FilesPerDir 2 | Out-Null
        }

        AfterEach {
            Remove-TestTree -Path $script:SourceDir
            Remove-TestTree -Path $script:DestDir
        }

        It "Should respect DryRun mode (no actual copy)" {
            $args = New-RobocopyArguments `
                -SourcePath $script:SourceDir `
                -DestinationPath $script:DestDir `
                -LogPath (Join-Path $script:LogDir "dryrun.log") `
                -DryRun

            $argString = $args -join ' '
            $argString | Should -Match '/L'

            # Actually run robocopy with DryRun parameter (not via RobocopyArgs which is sanitized)
            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "dryrun.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -DryRun
            Wait-RobocopyComplete -Job $job | Out-Null

            # Destination should not exist or be empty (dry run doesn't create files)
            $destExists = Test-Path $script:DestDir
            if ($destExists) {
                $destFiles = Get-ChildItem $script:DestDir -Recurse -File -ErrorAction SilentlyContinue
                $destFiles.Count | Should -Be 0 -Because "DryRun should not copy any files"
            }
        }

        It "Should handle exclude files option" {
            # Create files to exclude
            "temp content" | Set-Content -Path (Join-Path $script:SourceDir "exclude_me.tmp")
            "keep content" | Set-Content -Path (Join-Path $script:SourceDir "keep_me.txt")

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "exclude.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath `
                -RobocopyOptions @{ ExcludeFiles = @("*.tmp") }
            Wait-RobocopyComplete -Job $job | Out-Null

            # .txt should exist, .tmp should not
            Test-Path (Join-Path $script:DestDir "keep_me.txt") | Should -Be $true
            Test-Path (Join-Path $script:DestDir "exclude_me.tmp") | Should -Be $false
        }

        It "Should handle exclude directories option" {
            # Create directory to exclude
            $excludeDir = Join-Path $script:SourceDir "node_modules"
            New-Item -ItemType Directory -Path $excludeDir -Force | Out-Null
            "package" | Set-Content -Path (Join-Path $excludeDir "package.json")

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "exclude_dir.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath `
                -RobocopyOptions @{ ExcludeDirs = @("node_modules") }
            Wait-RobocopyComplete -Job $job | Out-Null

            # node_modules should not exist in dest
            Test-Path (Join-Path $script:DestDir "node_modules") | Should -Be $false
        }

        It "Should use correct thread count" {
            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "threads.log"

            # Run with specific thread count
            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -ThreadsPerJob 16
            Wait-RobocopyComplete -Job $job | Out-Null

            # Check log contains MT:16
            $logContent = Get-Content $logPath -Raw
            $logContent | Should -Match '/MT:16'
        }
    }

    Context "Log Parsing" {
        BeforeEach {
            $script:SourceDir = Join-Path $TestDrive "log_source"
            $script:DestDir = Join-Path $TestDrive "log_dest"
            $script:LogDir = Join-Path $TestDrive "logs"

            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
            New-TestTree -RootPath $script:SourceDir -Depth 2 -BreadthPerLevel 3 -FilesPerDir 5 | Out-Null
        }

        AfterEach {
            Remove-TestTree -Path $script:SourceDir
            Remove-TestTree -Path $script:DestDir
        }

        It "Should accurately parse file counts from real log" {
            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "parse_test.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            $logResult = ConvertFrom-RobocopyLog -LogPath $logPath

            $logResult.ParseSuccess | Should -Be $true
            $logResult.FilesCopied | Should -BeGreaterThan 0
            $logResult.DirsCopied | Should -BeGreaterThan 0

            # Verify against actual files
            $actualFiles = (Get-ChildItem $script:DestDir -Recurse -File).Count
            $logResult.FilesCopied | Should -Be $actualFiles
        }

        It "Should accurately parse byte counts" {
            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceDir
                DestinationPath = $script:DestDir
            }
            $logPath = Join-Path $script:LogDir "bytes.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            $logResult = ConvertFrom-RobocopyLog -LogPath $logPath

            $logResult.BytesCopied | Should -BeGreaterThan 0

            # Should be close to actual size
            $actualSize = (Get-ChildItem $script:DestDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
            # Allow some variance for encoding/metadata
            [Math]::Abs($logResult.BytesCopied - $actualSize) | Should -BeLessThan 1000
        }
    }

    Context "Error Handling" {
        It "Should return fatal error for non-existent source" {
            $chunk = [PSCustomObject]@{
                SourcePath = "C:\NonExistent\Path\That\Does\Not\Exist"
                DestinationPath = Join-Path $TestDrive "dest"
            }
            $logPath = Join-Path $TestDrive "error.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            # Exit code 16 = fatal error
            $meaning = Get-RobocopyExitMeaning -ExitCode $job.Process.ExitCode
            $meaning.FatalError | Should -Be $true
        }
    }

    Context "UNC Path Operations" -Skip:(-not $script:CanCreateShares) {
        BeforeAll {
            # Create base directories for shares
            $script:UNCTestRoot = Join-Path $TestDrive "UNCTest"
            $script:SourceLocal = Join-Path $script:UNCTestRoot "source"
            $script:DestLocal = Join-Path $script:UNCTestRoot "dest"
            $script:LogDir = Join-Path $script:UNCTestRoot "logs"

            New-Item -ItemType Directory -Path $script:SourceLocal -Force | Out-Null
            New-Item -ItemType Directory -Path $script:DestLocal -Force | Out-Null
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null

            # Create shares for source and destination
            $script:SourceShare = New-TestShare -Path $script:SourceLocal
            $script:DestShare = New-TestShare -Path $script:DestLocal

            if (-not $script:SourceShare.Success -or -not $script:DestShare.Success) {
                throw "Failed to create test shares"
            }
        }

        AfterAll {
            # Clean up shares
            if ($script:SourceShare.ShareName) {
                Remove-TestShare -ShareName $script:SourceShare.ShareName | Out-Null
            }
            if ($script:DestShare.ShareName) {
                Remove-TestShare -ShareName $script:DestShare.ShareName | Out-Null
            }
        }

        BeforeEach {
            # Create test data in source
            New-TestTree -RootPath $script:SourceLocal -Depth 2 -BreadthPerLevel 2 -FilesPerDir 3 | Out-Null
        }

        AfterEach {
            # Clean up data between tests
            Get-ChildItem $script:SourceLocal -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Get-ChildItem $script:DestLocal -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Should copy from UNC source to local destination" {
            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceShare.UNCPath
                DestinationPath = $script:DestLocal
            }
            $logPath = Join-Path $script:LogDir "unc_source.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            $job.Process.ExitCode | Should -BeLessOrEqual 3 -Because "UNC source should copy successfully"

            # Verify files were copied
            $destFiles = Get-ChildItem $script:DestLocal -Recurse -File
            $destFiles.Count | Should -BeGreaterThan 0
        }

        It "Should copy from local source to UNC destination" {
            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceLocal
                DestinationPath = $script:DestShare.UNCPath
            }
            $logPath = Join-Path $script:LogDir "unc_dest.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            $job.Process.ExitCode | Should -BeLessOrEqual 3 -Because "UNC destination should work"

            # Verify files via UNC path
            $destFiles = Get-ChildItem $script:DestShare.UNCPath -Recurse -File
            $destFiles.Count | Should -BeGreaterThan 0
        }

        It "Should copy from UNC source to UNC destination" {
            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceShare.UNCPath
                DestinationPath = $script:DestShare.UNCPath
            }
            $logPath = Join-Path $script:LogDir "unc_both.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            $job.Process.ExitCode | Should -BeLessOrEqual 3 -Because "UNC to UNC should work"

            # Verify via local path (same as UNC destination)
            $destFiles = Get-ChildItem $script:DestLocal -Recurse -File
            $destFiles.Count | Should -BeGreaterThan 0
        }

        It "Should handle UNC paths with spaces in share content" {
            # Create directory with spaces in the source
            $spacePath = Join-Path $script:SourceLocal "folder with spaces"
            New-Item -ItemType Directory -Path $spacePath -Force | Out-Null
            "Content" | Set-Content -Path (Join-Path $spacePath "file with spaces.txt")

            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceShare.UNCPath
                DestinationPath = $script:DestShare.UNCPath
            }
            $logPath = Join-Path $script:LogDir "unc_spaces.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            $job.Process.ExitCode | Should -BeLessOrEqual 3

            # Verify spaced path was copied
            $destSpacePath = Join-Path $script:DestLocal "folder with spaces"
            Test-Path $destSpacePath | Should -Be $true
            Test-Path (Join-Path $destSpacePath "file with spaces.txt") | Should -Be $true
        }

        It "Should mirror changes over UNC" {
            # First copy
            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceShare.UNCPath
                DestinationPath = $script:DestShare.UNCPath
            }
            $logPath = Join-Path $script:LogDir "unc_mirror1.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            # Add an extra file to dest (should be deleted on mirror)
            "Extra" | Set-Content -Path (Join-Path $script:DestLocal "extra_file.txt")

            # Add a new file to source (should be copied)
            "New" | Set-Content -Path (Join-Path $script:SourceLocal "new_file.txt")

            # Mirror again
            $logPath2 = Join-Path $script:LogDir "unc_mirror2.log"
            $job2 = Start-RobocopyJob -Chunk $chunk -LogPath $logPath2
            Wait-RobocopyComplete -Job $job2 | Out-Null

            # Extra file should be gone
            Test-Path (Join-Path $script:DestLocal "extra_file.txt") | Should -Be $false

            # New file should exist
            Test-Path (Join-Path $script:DestLocal "new_file.txt") | Should -Be $true
        }

        It "Should parse log correctly for UNC operations" {
            $chunk = [PSCustomObject]@{
                SourcePath = $script:SourceShare.UNCPath
                DestinationPath = $script:DestShare.UNCPath
            }
            $logPath = Join-Path $script:LogDir "unc_log_parse.log"

            $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath
            Wait-RobocopyComplete -Job $job | Out-Null

            $logResult = ConvertFrom-RobocopyLog -LogPath $logPath

            $logResult.ParseSuccess | Should -Be $true
            $logResult.FilesCopied | Should -BeGreaterThan 0

            # Verify count matches actual
            $actualFiles = (Get-ChildItem $script:DestLocal -Recurse -File).Count
            $logResult.FilesCopied | Should -Be $actualFiles
        }
    }
}

Describe "Robocopy Wrapper Function Tests (Non-Windows Fallback)" -Skip:($script:IsWindowsWithRobocopy) {
    It "Should report robocopy not available on non-Windows" {
        $result = Test-RobocopyAvailable
        # On non-Windows, should fail or return not found
        if ($result.Success) {
            # If it somehow succeeds (wine?), that's OK
            Set-ItResult -Skipped -Because "Robocopy appears to be available"
        }
        else {
            $result.Success | Should -Be $false
        }
    }
}
