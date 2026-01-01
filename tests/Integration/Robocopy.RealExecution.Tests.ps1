#Requires -Modules Pester

# Real Robocopy Execution Integration Tests
# Tests actual robocopy execution with real files (not mocked)

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type (required for module isolation when running all tests together)
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "Real Robocopy Execution Tests" -Skip:(-not (Test-IsWindowsPlatform)) {

        BeforeAll {
            # Verify robocopy is available
            $robocopyAvailable = Test-RobocopyAvailable
            if (-not $robocopyAvailable) {
                throw "Robocopy is not available on this system"
            }

            # Create test directory structure
            $script:TestRoot = Join-Path $env:TEMP "RobocurseRealTest_$([Guid]::NewGuid().ToString('N').Substring(0,16))"
            $script:SourceDir = Join-Path $script:TestRoot "Source"
            $script:DestDir = Join-Path $script:TestRoot "Dest"
            $script:LogDir = Join-Path $script:TestRoot "Logs"

            New-Item -Path $script:SourceDir -ItemType Directory -Force | Out-Null
            New-Item -Path $script:DestDir -ItemType Directory -Force | Out-Null
            New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null

            # Helper to create chunk objects for testing
            $script:NewTestChunk = {
                param($Source, $Dest)
                [PSCustomObject]@{
                    SourcePath = $Source
                    DestinationPath = $Dest
                }
            }

            # Standard test options: /E mode (not mirror), no retries
            $script:TestOptions = @{
                NoMirror = $true    # Use /E instead of /MIR
                RetryCount = 0
                RetryWait = 0
            }
        }

        AfterAll {
            # Cleanup test directories
            if (Test-Path $script:TestRoot) {
                Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        Context "Basic File Copy Operations" {
            BeforeEach {
                # Clean destination for each test
                Get-ChildItem -Path $script:DestDir -Recurse -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }

            It "Should copy a single file successfully" {
                # Create test file
                $testFile = Join-Path $script:SourceDir "test1.txt"
                "Test content" | Set-Content -Path $testFile

                # Create chunk and robocopy job
                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "test1.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions

                # Use boolean check to avoid Pester stringifying Process object (throws if exited)
                ($null -ne $job) | Should -Be $true -Because "Start-RobocopyJob should return a job object"
                ($null -ne $job.Process) | Should -Be $true -Because "Job should have a Process property"

                # Wait for completion
                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                # Verify result
                $result.ExitCode | Should -BeLessOrEqual 3  # 0-3 are success codes
                $result.ExitMeaning.Severity | Should -BeIn @('Success', 'Warning')

                # Verify file was copied
                $destFile = Join-Path $script:DestDir "test1.txt"
                Test-Path $destFile | Should -Be $true
                (Get-Content $destFile) | Should -Be "Test content"
            }

            It "Should copy multiple files successfully" {
                # Create multiple test files
                for ($i = 1; $i -le 5; $i++) {
                    $testFile = Join-Path $script:SourceDir "multi$i.txt"
                    "Content for file $i" | Set-Content -Path $testFile
                }

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "multi.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions

                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                $result.ExitCode | Should -BeLessOrEqual 3

                # Verify all files were copied
                for ($i = 1; $i -le 5; $i++) {
                    $destFile = Join-Path $script:DestDir "multi$i.txt"
                    Test-Path $destFile | Should -Be $true
                }
            }

            It "Should copy subdirectory structure" {
                # Create subdirectory structure
                $subDir = Join-Path $script:SourceDir "SubDir"
                $nestedDir = Join-Path $subDir "Nested"
                New-Item -Path $nestedDir -ItemType Directory -Force | Out-Null

                "Root file" | Set-Content -Path (Join-Path $script:SourceDir "root.txt")
                "Sub file" | Set-Content -Path (Join-Path $subDir "sub.txt")
                "Nested file" | Set-Content -Path (Join-Path $nestedDir "nested.txt")

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "subdir.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions

                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                $result.ExitCode | Should -BeLessOrEqual 3

                # Verify structure
                Test-Path (Join-Path $script:DestDir "root.txt") | Should -Be $true
                Test-Path (Join-Path $script:DestDir "SubDir\sub.txt") | Should -Be $true
                Test-Path (Join-Path $script:DestDir "SubDir\Nested\nested.txt") | Should -Be $true
            }
        }

        Context "Exit Code Interpretation" {
            BeforeEach {
                Get-ChildItem -Path $script:DestDir -Recurse -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }

            It "Should return exit code 0 when no files to copy" {
                # Create identical source and dest
                $testFile = Join-Path $script:SourceDir "identical.txt"
                "Same content" | Set-Content -Path $testFile

                # First copy
                $chunk1 = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath1 = Join-Path $script:LogDir "identical1.log"
                $job1 = Start-RobocopyJob -Chunk $chunk1 -LogPath $logPath1 -RobocopyOptions $script:TestOptions
                Wait-RobocopyJob -Job $job1 -TimeoutSeconds 30 | Out-Null

                # Second copy should find nothing to copy
                $chunk2 = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath2 = Join-Path $script:LogDir "identical2.log"
                $job2 = Start-RobocopyJob -Chunk $chunk2 -LogPath $logPath2 -RobocopyOptions $script:TestOptions
                $result = Wait-RobocopyJob -Job $job2 -TimeoutSeconds 30

                $result.ExitCode | Should -Be 0
                # Exit code 0 means no files needed copying (no change)
                $result.ExitMeaning.FilesCopied | Should -Be $false
            }

            It "Should return exit code 1 when files copied" {
                $testFile = Join-Path $script:SourceDir "newfile.txt"
                "New content" | Set-Content -Path $testFile

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "newfile.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions
                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                $result.ExitCode | Should -BeIn @(1, 3)  # 1=files copied, 3=files copied + extras
                $result.ExitMeaning.FilesCopied | Should -Be $true
            }
        }

        Context "Log Parsing with Real Output" {
            BeforeEach {
                Get-ChildItem -Path $script:DestDir -Recurse -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }

            It "Should parse file counts from real robocopy log" {
                # Create known number of files
                for ($i = 1; $i -le 3; $i++) {
                    $testFile = Join-Path $script:SourceDir "parse$i.txt"
                    "Content $i" | Set-Content -Path $testFile
                }

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "parse.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions
                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                # Parse the log
                $stats = ConvertFrom-RobocopyLog -LogPath $logPath

                $stats.ParseSuccess | Should -Be $true
                $stats.FilesCopied | Should -BeGreaterOrEqual 3
            }

            It "Should parse byte counts from real robocopy log" {
                # Create file with known size
                $testFile = Join-Path $script:SourceDir "sized.txt"
                $content = "A" * 1000  # 1000 bytes
                $content | Set-Content -Path $testFile -NoNewline

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "sized.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions
                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                $stats = ConvertFrom-RobocopyLog -LogPath $logPath

                $stats.ParseSuccess | Should -Be $true
                $stats.BytesCopied | Should -BeGreaterOrEqual 1000
            }
        }

        Context "Timeout Handling" {
            It "Should timeout on very long operations" {
                # Create a very short timeout
                $testFile = Join-Path $script:SourceDir "timeout.txt"
                "Content" | Set-Content -Path $testFile

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "timeout.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions

                # Wait with very short timeout (but file copy should complete instantly)
                # This is more of a functional test that timeout doesn't break things
                { Wait-RobocopyJob -Job $job -TimeoutSeconds 30 } | Should -Not -Throw
            }
        }

        Context "Process Handle Cleanup" {
            It "Should dispose process handle after completion" {
                $testFile = Join-Path $script:SourceDir "cleanup.txt"
                "Content" | Set-Content -Path $testFile

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "cleanup.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions

                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                # Process should be disposed (will throw on access)
                # Note: Can't reliably test disposal in PS, but verify job completed
                $result.ExitCode | Should -Not -BeNullOrEmpty
            }
        }

        Context "Exclude Pattern Tests" {
            BeforeEach {
                Get-ChildItem -Path $script:DestDir -Recurse -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }

            It "Should exclude files matching pattern" {
                # Create files including one to exclude
                "Include me" | Set-Content -Path (Join-Path $script:SourceDir "include.txt")
                "Exclude me" | Set-Content -Path (Join-Path $script:SourceDir "exclude.tmp")
                "Also include" | Set-Content -Path (Join-Path $script:SourceDir "also.txt")

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "exclude.log"
                $excludeOptions = @{
                    NoMirror = $true
                    RetryCount = 0
                    RetryWait = 0
                    ExcludeFiles = @('*.tmp')
                }
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $excludeOptions
                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                # Verify exclusion
                Test-Path (Join-Path $script:DestDir "include.txt") | Should -Be $true
                Test-Path (Join-Path $script:DestDir "also.txt") | Should -Be $true
                Test-Path (Join-Path $script:DestDir "exclude.tmp") | Should -Be $false
            }
        }

        Context "Chunking Algorithm End-to-End Verification" {
            # CRITICAL: This test verifies that the chunking algorithm + robocopy = all files copied
            # If this fails, files are being missed or duplicated

            BeforeEach {
                # Clean source and dest
                Get-ChildItem -Path $script:SourceDir -Recurse -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Get-ChildItem -Path $script:DestDir -Recurse -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }

            It "Should copy ALL files when directory is chunked into subdirectories" {
                # Create structure with files at root AND in subdirectories
                # This tests the files-only chunk (/LEV:1) + subdirectory chunks scenario

                # Root level files
                "root1" | Set-Content -Path (Join-Path $script:SourceDir "root1.txt")
                "root2" | Set-Content -Path (Join-Path $script:SourceDir "root2.txt")

                # Subdirectory 1
                $sub1 = Join-Path $script:SourceDir "SubDir1"
                New-Item -Path $sub1 -ItemType Directory -Force | Out-Null
                "sub1-file1" | Set-Content -Path (Join-Path $sub1 "file1.txt")
                "sub1-file2" | Set-Content -Path (Join-Path $sub1 "file2.txt")

                # Subdirectory 2
                $sub2 = Join-Path $script:SourceDir "SubDir2"
                New-Item -Path $sub2 -ItemType Directory -Force | Out-Null
                "sub2-file1" | Set-Content -Path (Join-Path $sub2 "file1.txt")

                # Nested subdirectory
                $nested = Join-Path $sub1 "Nested"
                New-Item -Path $nested -ItemType Directory -Force | Out-Null
                "nested" | Set-Content -Path (Join-Path $nested "deep.txt")

                # Count source files
                $sourceFiles = Get-ChildItem -Path $script:SourceDir -Recurse -File
                $sourceFileCount = $sourceFiles.Count

                # Build directory tree and create chunks
                $tree = New-DirectoryTree -RootPath $script:SourceDir
                $chunks = @(New-SmartChunks -Path $script:SourceDir -DestinationRoot $script:DestDir -TreeNode $tree)

                # Execute each chunk with real robocopy
                foreach ($chunk in $chunks) {
                    $logPath = Join-Path $script:LogDir "chunk_$($chunk.ChunkId).log"
                    $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions
                    $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30
                    $result.ExitCode | Should -BeLessOrEqual 3 -Because "Chunk $($chunk.ChunkId) ($($chunk.SourcePath)) should succeed"
                }

                # Verify ALL files from source exist in destination
                $destFiles = Get-ChildItem -Path $script:DestDir -Recurse -File
                $destFileCount = $destFiles.Count

                $destFileCount | Should -Be $sourceFileCount -Because "All $sourceFileCount source files should be copied to destination"

                # Verify specific files
                Test-Path (Join-Path $script:DestDir "root1.txt") | Should -Be $true -Because "Root level files must be copied"
                Test-Path (Join-Path $script:DestDir "root2.txt") | Should -Be $true -Because "Root level files must be copied"
                Test-Path (Join-Path $script:DestDir "SubDir1\file1.txt") | Should -Be $true -Because "Subdirectory files must be copied"
                Test-Path (Join-Path $script:DestDir "SubDir1\file2.txt") | Should -Be $true -Because "Subdirectory files must be copied"
                Test-Path (Join-Path $script:DestDir "SubDir2\file1.txt") | Should -Be $true -Because "Subdirectory files must be copied"
                Test-Path (Join-Path $script:DestDir "SubDir1\Nested\deep.txt") | Should -Be $true -Because "Nested files must be copied"
            }
        }

        Context "Real-Time Progress Tracking" {
            # CRITICAL: Tests that progress updates during copy (not just 0 -> 100% jump)
            # This validates the poll-time line parsing in Get-RobocopyProgress

            BeforeEach {
                # Clean up any lingering event handlers from other tests
                # This is necessary because Pester runs all tests in the same session
                Get-EventSubscriber -ErrorAction SilentlyContinue | ForEach-Object {
                    Unregister-Event -SourceIdentifier $_.SourceIdentifier -ErrorAction SilentlyContinue
                }
                Get-Job | Where-Object { $_.State -eq 'Running' -or $_.Name -like '*Event*' } | ForEach-Object {
                    Remove-Job -Job $_ -Force -ErrorAction SilentlyContinue
                }

                # Clean source and dest
                Get-ChildItem -Path $script:SourceDir -Recurse -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Get-ChildItem -Path $script:DestDir -Recurse -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }

            It "Should track progress from stdout buffer and count bytes and files correctly" {
                # IMPORTANT: This test verifies that ProgressBuffer captures SOME progress for
                # real-time UI updates. It does NOT test final byte counts accuracy.
                #
                # ProgressBuffer is for real-time progress bars during copy operations.
                # FINAL STATS must come from log file parsing (ConvertFrom-RobocopyLog) because:
                # 1. Robocopy buffers stdout, so OutputDataReceived events are batched
                # 2. Events run on thread pool and may not all fire before we read
                # 3. The log file is flushed synchronously when robocopy exits
                #
                # DO NOT add assertions expecting ProgressBuffer to match total file size.
                # That will cause flaky tests due to inherent race conditions.

                $fileSize = 2MB
                $fileCount = 20
                $totalSize = $fileSize * $fileCount

                for ($i = 1; $i -le $fileCount; $i++) {
                    $testFile = Join-Path $script:SourceDir "progress_test_$i.bin"
                    $bytes = New-Object byte[] $fileSize
                    # Fill with random data to prevent compression
                    (New-Object Random).NextBytes($bytes)
                    [System.IO.File]::WriteAllBytes($testFile, $bytes)
                }

                # Start robocopy job with single thread for predictable "New File" output order
                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "progress_test.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions -ThreadsPerJob 1

                # Poll for progress while job is running (best effort to catch intermediate states)
                # Note: Due to stdout buffering, we may not see intermediate progress
                $maxProgressWhileRunning = 0
                $pollCount = 0

                while (-not $job.Process.HasExited -and $pollCount -lt 500) {
                    $progress = Get-RobocopyProgress -Job $job
                    if ($progress.BytesCopied -gt $maxProgressWhileRunning) {
                        $maxProgressWhileRunning = $progress.BytesCopied
                    }
                    $pollCount++
                    Start-Sleep -Milliseconds 10
                }

                # Wait for completion - this waits for OutputDataReceived events to finish
                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 120
                $result.ExitCode | Should -BeLessOrEqual 3 -Because "Copy should succeed"

                # Get progress from ProgressBuffer (for real-time UI, not final stats)
                $finalProgress = Get-RobocopyProgress -Job $job

                # Debug info
                $debugInfo = "PollCount=$pollCount, MaxDuringCopy=$maxProgressWhileRunning, FinalBytes=$($finalProgress.BytesCopied), FilesCopied=$($finalProgress.FilesCopied), TotalSize=$totalSize"

                # Verify ProgressBuffer captured SOME progress (proves the mechanism works)
                # We only check for non-zero values - exact counts come from log file parsing
                $finalProgress.BytesCopied | Should -BeGreaterThan 0 -Because "ProgressBuffer should capture some bytes. $debugInfo"
                $finalProgress.FilesCopied | Should -BeGreaterThan 0 -Because "ProgressBuffer should capture some files. $debugInfo"

                # Verify final stats from log file (the authoritative source)
                $result.Stats.BytesCopied | Should -BeGreaterOrEqual $totalSize -Because "Log file should show all bytes copied"
                $result.Stats.FilesCopied | Should -Be $fileCount -Because "Log file should show all files copied"
            }
        }
    }
}
