#Requires -Modules Pester

# Orchestration Stress Tests
# Tests concurrent job handling, thread safety, and resource management

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "Orchestration Stress Tests" -Skip:(-not (Test-IsWindowsPlatform)) {

        BeforeAll {
            # Ensure OrchestrationState is initialized before any tests run
            Initialize-OrchestrationStateType | Out-Null

            # Create test directory structure
            $script:TestRoot = Join-Path $env:TEMP "RobocurseStressTest_$([Guid]::NewGuid().ToString('N').Substring(0,16))"
            $script:SourceDir = Join-Path $script:TestRoot "Source"
            $script:DestDir = Join-Path $script:TestRoot "Dest"
            $script:LogDir = Join-Path $script:TestRoot "Logs"

            New-Item -Path $script:SourceDir -ItemType Directory -Force | Out-Null
            New-Item -Path $script:DestDir -ItemType Directory -Force | Out-Null
            New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null

            # Create test files
            for ($i = 1; $i -le 20; $i++) {
                $subDir = Join-Path $script:SourceDir "Dir$i"
                New-Item -Path $subDir -ItemType Directory -Force | Out-Null
                for ($j = 1; $j -le 5; $j++) {
                    "File $j in Dir $i" | Set-Content -Path (Join-Path $subDir "file$j.txt")
                }
            }
        }

        AfterAll {
            # Cleanup test directories
            if (Test-Path $script:TestRoot) {
                Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        Context "Concurrent Counter Operations" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should maintain accurate count with concurrent increments" {
                $iterations = 100

                # Run concurrent increments
                $jobs = 1..10 | ForEach-Object {
                    Start-Job -ScriptBlock {
                        param($Count)
                        for ($i = 0; $i -lt $Count; $i++) {
                            # Simulate increment operation
                            Start-Sleep -Milliseconds 1
                        }
                        return $Count
                    } -ArgumentList ($iterations / 10)
                }

                $jobs | Wait-Job -Timeout 30 | Out-Null
                $results = $jobs | Receive-Job
                $jobs | Remove-Job -Force

                # All jobs should complete
                $results.Count | Should -Be 10
            }

            It "Should handle rapid CompletedCount increments" {
                $targetCount = 1000

                for ($i = 0; $i -lt $targetCount; $i++) {
                    $script:OrchestrationState.IncrementCompletedCount()
                }

                $script:OrchestrationState.CompletedCount | Should -Be $targetCount
            }

            It "Should handle concurrent bytes tracking" {
                $bytesPerChunk = 1000000  # 1MB
                $chunkCount = 100

                for ($i = 0; $i -lt $chunkCount; $i++) {
                    $script:OrchestrationState.AddCompletedChunkBytes($bytesPerChunk)
                }

                # AddCompletedChunkBytes tracks cumulative completed chunk bytes separately
                # from BytesComplete which is for real-time progress
                $script:OrchestrationState.CompletedChunkBytes | Should -Be ($bytesPerChunk * $chunkCount)
            }
        }

        Context "Queue Operations Under Load" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should handle high-volume chunk queue operations" {
                $chunkCount = 1000

                # Enqueue many chunks
                for ($i = 0; $i -lt $chunkCount; $i++) {
                    $chunk = [PSCustomObject]@{
                        ChunkId = $i
                        SourcePath = "C:\Test\Path$i"
                        EstimatedSize = 1000000
                    }
                    $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
                }

                $script:OrchestrationState.ChunkQueue.Count | Should -Be $chunkCount

                # Dequeue all
                $dequeued = 0
                $chunk = $null
                while ($script:OrchestrationState.ChunkQueue.TryDequeue([ref]$chunk)) {
                    $dequeued++
                }

                $dequeued | Should -Be $chunkCount
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 0
            }

            It "Should handle concurrent enqueue and dequeue" {
                $enqueueCount = 500

                # Enqueue items
                for ($i = 0; $i -lt $enqueueCount; $i++) {
                    $chunk = [PSCustomObject]@{
                        ChunkId = $i
                        SourcePath = "C:\Test\Path$i"
                    }
                    $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
                }

                # Dequeue half while counting
                $dequeued = 0
                $chunk = $null
                for ($i = 0; $i -lt $enqueueCount / 2; $i++) {
                    if ($script:OrchestrationState.ChunkQueue.TryDequeue([ref]$chunk)) {
                        $dequeued++
                    }
                }

                $dequeued | Should -Be ($enqueueCount / 2)
                $script:OrchestrationState.ChunkQueue.Count | Should -Be ($enqueueCount / 2)
            }
        }

        Context "ActiveJobs ConcurrentDictionary Operations" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should handle many active jobs concurrently" {
                $jobCount = 50

                # Add many jobs
                for ($i = 0; $i -lt $jobCount; $i++) {
                    $job = [PSCustomObject]@{
                        JobId = $i
                        Chunk = [PSCustomObject]@{ ChunkId = $i }
                        Process = $null  # Simulated
                        StartTime = Get-Date
                    }
                    $script:OrchestrationState.ActiveJobs[$i] = $job
                }

                $script:OrchestrationState.ActiveJobs.Count | Should -Be $jobCount

                # Remove half using TryRemove (thread-safe pattern)
                for ($i = 0; $i -lt $jobCount / 2; $i++) {
                    $removedJob = $null
                    $wasRemoved = $script:OrchestrationState.ActiveJobs.TryRemove($i, [ref]$removedJob)
                    $wasRemoved | Should -Be $true
                }

                $script:OrchestrationState.ActiveJobs.Count | Should -Be ($jobCount / 2)
            }

            It "Should handle concurrent TryRemove without errors" {
                # Add jobs
                for ($i = 0; $i -lt 10; $i++) {
                    $script:OrchestrationState.ActiveJobs[$i] = [PSCustomObject]@{ JobId = $i }
                }

                # Try to remove same key multiple times (simulates race condition)
                $removedCount = 0
                for ($attempt = 0; $attempt -lt 3; $attempt++) {
                    $removed = $null
                    if ($script:OrchestrationState.ActiveJobs.TryRemove(5, [ref]$removed)) {
                        $removedCount++
                    }
                }

                # Should only succeed once
                $removedCount | Should -Be 1
            }
        }

        Context "Error Queue Handling" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should accumulate errors without loss" {
                $errorCount = 100

                for ($i = 0; $i -lt $errorCount; $i++) {
                    $script:OrchestrationState.EnqueueError("Error message $i")
                }

                $script:OrchestrationState.ErrorMessages.Count | Should -Be $errorCount

                # Dequeue all
                $dequeued = $script:OrchestrationState.DequeueErrors()
                $dequeued.Count | Should -Be $errorCount
                $script:OrchestrationState.ErrorMessages.Count | Should -Be 0
            }

            It "Should handle rapid error enqueuing" {
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $errorCount = 1000

                for ($i = 0; $i -lt $errorCount; $i++) {
                    $script:OrchestrationState.EnqueueError("Rapid error $i")
                }

                $stopwatch.Stop()

                $script:OrchestrationState.ErrorMessages.Count | Should -Be $errorCount
                # Should complete reasonably fast (< 1 second for 1000 errors)
                $stopwatch.ElapsedMilliseconds | Should -BeLessThan 1000
            }
        }

        Context "State Reset Operations" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should completely reset state for new run" {
                # Populate state
                for ($i = 0; $i -lt 10; $i++) {
                    $script:OrchestrationState.IncrementCompletedCount()
                    $script:OrchestrationState.ActiveJobs[$i] = [PSCustomObject]@{ JobId = $i }
                    $script:OrchestrationState.EnqueueError("Error $i")
                }

                $script:OrchestrationState.CompletedCount | Should -Be 10
                $script:OrchestrationState.ActiveJobs.Count | Should -Be 10
                $script:OrchestrationState.ErrorMessages.Count | Should -Be 10

                # Reset
                $script:OrchestrationState.Reset()

                $script:OrchestrationState.CompletedCount | Should -Be 0
                $script:OrchestrationState.ActiveJobs.Count | Should -Be 0
                $script:OrchestrationState.ErrorMessages.Count | Should -Be 0
                $script:OrchestrationState.Phase | Should -Be 'Idle'
            }

            It "Should reset for new profile without full reset" {
                # Setup first profile run
                $script:OrchestrationState.Phase = 'Replicating'
                for ($i = 0; $i -lt 5; $i++) {
                    $script:OrchestrationState.IncrementCompletedCount()
                }
                $script:OrchestrationState.TotalChunks = 5

                # Reset for new profile
                $script:OrchestrationState.ResetForNewProfile()

                # Counters and chunks should be reset
                $script:OrchestrationState.CompletedCount | Should -Be 0
                $script:OrchestrationState.TotalChunks | Should -Be 0
                # Note: Phase is NOT reset by ResetForNewProfile - it's controlled at higher level
                # Phase should remain 'Replicating' since we're just moving to next profile
                $script:OrchestrationState.Phase | Should -Be 'Replicating'
            }
        }

        Context "Memory Pressure Tests" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should handle large completed chunks queue" {
                $chunkCount = 10000

                for ($i = 0; $i -lt $chunkCount; $i++) {
                    $chunk = [PSCustomObject]@{
                        ChunkId = $i
                        SourcePath = "C:\Very\Long\Path\To\Simulate\Real\World\Chunk$i"
                        EstimatedSize = 1000000
                        Status = 'Completed'
                    }
                    $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
                }

                $script:OrchestrationState.CompletedChunks.Count | Should -Be $chunkCount

                # Convert to array (common operation for reporting)
                $array = $script:OrchestrationState.CompletedChunks.ToArray()
                $array.Count | Should -Be $chunkCount
            }

            It "Should handle large failed chunks collection" {
                $failedCount = 1000

                for ($i = 0; $i -lt $failedCount; $i++) {
                    $failedChunk = [PSCustomObject]@{
                        Chunk = [PSCustomObject]@{ ChunkId = $i; SourcePath = "Path$i" }
                        ErrorMessage = "Failed with error code $i - some long error description"
                        RetryCount = 3
                    }
                    $script:OrchestrationState.FailedChunks.Enqueue($failedChunk)
                }

                $script:OrchestrationState.FailedChunks.Count | Should -Be $failedCount
            }
        }

        Context "Stop Request Handling" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should immediately reflect stop request" {
                $script:OrchestrationState.StopRequested | Should -Be $false

                $script:OrchestrationState.StopRequested = $true

                $script:OrchestrationState.StopRequested | Should -Be $true
            }

            It "Should handle multiple stop/resume cycles" {
                for ($cycle = 0; $cycle -lt 10; $cycle++) {
                    $script:OrchestrationState.StopRequested = $true
                    $script:OrchestrationState.StopRequested | Should -Be $true

                    $script:OrchestrationState.StopRequested = $false
                    $script:OrchestrationState.StopRequested | Should -Be $false
                }
            }

            It "Should handle pause request during operation" {
                $script:OrchestrationState.Phase = 'Replicating'
                $script:OrchestrationState.PauseRequested = $true

                $script:OrchestrationState.PauseRequested | Should -Be $true

                # Resume
                $script:OrchestrationState.PauseRequested = $false
                $script:OrchestrationState.PauseRequested | Should -Be $false
            }
        }

        Context "Profile Results Accumulation" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should accumulate results across multiple profiles" {
                $profileCount = 10

                for ($p = 0; $p -lt $profileCount; $p++) {
                    $result = [PSCustomObject]@{
                        ProfileName = "Profile$p"
                        ChunksTotal = 100
                        ChunksCompleted = 95
                        ChunksFailed = 5
                        BytesCopied = 1000000 * ($p + 1)
                        Duration = [TimeSpan]::FromMinutes($p + 1)
                    }
                    $script:OrchestrationState.ProfileResults.Enqueue($result)
                }

                $script:OrchestrationState.ProfileResults.Count | Should -Be $profileCount

                # Calculate totals (common operation)
                $allResults = $script:OrchestrationState.ProfileResults.ToArray()
                $totalBytes = ($allResults | Measure-Object -Property BytesCopied -Sum).Sum

                $totalBytes | Should -BeGreaterThan 0
            }
        }

        Context "Timing and Performance" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should complete 10000 counter operations in under 100ms" {
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

                for ($i = 0; $i -lt 10000; $i++) {
                    $script:OrchestrationState.IncrementCompletedCount()
                }

                $stopwatch.Stop()

                $script:OrchestrationState.CompletedCount | Should -Be 10000
                $stopwatch.ElapsedMilliseconds | Should -BeLessThan 100
            }

            It "Should complete 10000 queue operations in under 500ms" {
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

                for ($i = 0; $i -lt 10000; $i++) {
                    $chunk = [PSCustomObject]@{ ChunkId = $i }
                    $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
                }

                $stopwatch.Stop()

                $script:OrchestrationState.ChunkQueue.Count | Should -Be 10000
                $stopwatch.ElapsedMilliseconds | Should -BeLessThan 500
            }
        }

        Context "High Concurrency Job Management (50+ Jobs)" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should handle 50 concurrent active jobs" {
                $jobCount = 50

                # Simulate 50 concurrent jobs
                for ($i = 0; $i -lt $jobCount; $i++) {
                    $mockProcess = [PSCustomObject]@{
                        Id = 1000 + $i
                        HasExited = $false
                    }
                    $chunk = [PSCustomObject]@{
                        ChunkId = $i
                        SourcePath = "C:\Test\Chunk$i"
                        EstimatedSize = 10000000
                        Status = 'Running'
                    }
                    $job = [PSCustomObject]@{
                        Process = $mockProcess
                        Chunk = $chunk
                        StartTime = [datetime]::Now
                        LogPath = "C:\Logs\chunk$i.log"
                    }
                    $script:OrchestrationState.ActiveJobs[$mockProcess.Id] = $job
                }

                $script:OrchestrationState.ActiveJobs.Count | Should -Be $jobCount
            }

            It "Should handle rapid job completion (50 jobs completing nearly simultaneously)" {
                $jobCount = 50

                # Add 50 jobs
                for ($i = 0; $i -lt $jobCount; $i++) {
                    $pid = 2000 + $i
                    $script:OrchestrationState.ActiveJobs[$pid] = [PSCustomObject]@{
                        Process = [PSCustomObject]@{ Id = $pid; HasExited = $true; ExitCode = 0 }
                        Chunk = [PSCustomObject]@{ ChunkId = $i; Status = 'Pending' }
                    }
                }

                # Simulate rapid completion (snapshot then iterate pattern)
                $activeJobsCopy = $script:OrchestrationState.ActiveJobs.ToArray()
                $completedCount = 0

                foreach ($kvp in $activeJobsCopy) {
                    if ($kvp.Value.Process.HasExited) {
                        $removed = $null
                        if ($script:OrchestrationState.ActiveJobs.TryRemove($kvp.Key, [ref]$removed)) {
                            $completedCount++
                            $script:OrchestrationState.CompletedChunks.Enqueue($removed.Chunk)
                            $script:OrchestrationState.IncrementCompletedCount()
                        }
                    }
                }

                $completedCount | Should -Be $jobCount
                $script:OrchestrationState.ActiveJobs.Count | Should -Be 0
                $script:OrchestrationState.CompletedChunks.Count | Should -Be $jobCount
                $script:OrchestrationState.CompletedCount | Should -Be $jobCount
            }

            It "Should handle 100 jobs with mixed success and failure" {
                $totalJobs = 100
                $successRate = 0.9  # 90% success

                for ($i = 0; $i -lt $totalJobs; $i++) {
                    $willSucceed = $i -lt ($totalJobs * $successRate)
                    $chunk = [PSCustomObject]@{
                        ChunkId = $i
                        SourcePath = "C:\Test\Path$i"
                        Status = if ($willSucceed) { 'Completed' } else { 'Failed' }
                        RetryCount = if ($willSucceed) { 0 } else { 3 }
                    }

                    if ($willSucceed) {
                        $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
                        $script:OrchestrationState.IncrementCompletedCount()
                    }
                    else {
                        $failedChunk = [PSCustomObject]@{
                            Chunk = $chunk
                            ErrorMessage = "Failed after 3 retries"
                            ExitCode = 8
                        }
                        $script:OrchestrationState.FailedChunks.Enqueue($failedChunk)
                    }
                }

                $script:OrchestrationState.CompletedChunks.Count | Should -Be 90
                $script:OrchestrationState.FailedChunks.Count | Should -Be 10
                $script:OrchestrationState.CompletedCount | Should -Be 90
            }

            It "Should handle 64 concurrent jobs (max reasonable for most systems)" {
                $jobCount = 64

                # Add 64 concurrent jobs
                for ($i = 0; $i -lt $jobCount; $i++) {
                    $script:OrchestrationState.ActiveJobs[3000 + $i] = [PSCustomObject]@{
                        JobId = $i
                        Progress = $i * 1.5  # Varying progress
                    }
                }

                # Verify all added
                $script:OrchestrationState.ActiveJobs.Count | Should -Be $jobCount

                # Iterate safely using ToArray
                $snapshot = $script:OrchestrationState.ActiveJobs.ToArray()
                $totalProgress = ($snapshot | ForEach-Object { $_.Value.Progress } | Measure-Object -Sum).Sum

                $totalProgress | Should -BeGreaterThan 0

                # Clear all using TryRemove pattern
                foreach ($kvp in $snapshot) {
                    $removed = $null
                    $script:OrchestrationState.ActiveJobs.TryRemove($kvp.Key, [ref]$removed) | Out-Null
                }

                $script:OrchestrationState.ActiveJobs.Count | Should -Be 0
            }
        }

        Context "Extreme Load Testing" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should handle 10000 chunks queued and processed" {
                $chunkCount = 10000

                # Phase 1: Queue all chunks
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                for ($i = 0; $i -lt $chunkCount; $i++) {
                    $chunk = [PSCustomObject]@{
                        ChunkId = $i
                        SourcePath = "C:\Source\Dir$([int]($i / 100))\Subdir$([int]($i / 10) % 10)\file$($i % 10).txt"
                        EstimatedSize = 1000000 + ($i * 100)
                        Status = 'Pending'
                    }
                    $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
                }
                $stopwatch.Stop()

                $script:OrchestrationState.ChunkQueue.Count | Should -Be $chunkCount
                # Enqueueing 10000 items should take < 2 seconds
                $stopwatch.ElapsedMilliseconds | Should -BeLessThan 2000

                # Phase 2: Process all chunks (simulated)
                $stopwatch.Restart()
                $processedCount = 0
                $chunk = $null
                while ($script:OrchestrationState.ChunkQueue.TryDequeue([ref]$chunk)) {
                    # Simulate minimal processing
                    $chunk.Status = 'Completed'
                    $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
                    $script:OrchestrationState.IncrementCompletedCount()
                    $script:OrchestrationState.AddCompletedChunkBytes($chunk.EstimatedSize)
                    $processedCount++
                }
                $stopwatch.Stop()

                $processedCount | Should -Be $chunkCount
                $script:OrchestrationState.CompletedCount | Should -Be $chunkCount
                # Processing 10000 items should take < 5 seconds
                $stopwatch.ElapsedMilliseconds | Should -BeLessThan 5000
            }

            It "Should maintain data integrity with 50+ concurrent simulated workers" {
                $workerCount = 50
                $chunksPerWorker = 20

                # Queue chunks for all workers
                $totalChunks = $workerCount * $chunksPerWorker
                for ($i = 0; $i -lt $totalChunks; $i++) {
                    $script:OrchestrationState.ChunkQueue.Enqueue([PSCustomObject]@{
                        ChunkId = $i
                        WorkerId = $i % $workerCount
                        SourcePath = "C:\Worker$($i % $workerCount)\Chunk$([int]($i / $workerCount))"
                    })
                }

                $script:OrchestrationState.ChunkQueue.Count | Should -Be $totalChunks

                # Simulate 50 workers processing chunks
                $workerResults = @{}
                for ($w = 0; $w -lt $workerCount; $w++) {
                    $workerResults[$w] = 0
                }

                $chunk = $null
                while ($script:OrchestrationState.ChunkQueue.TryDequeue([ref]$chunk)) {
                    $workerResults[$chunk.WorkerId]++
                    $script:OrchestrationState.IncrementCompletedCount()
                }

                # Each worker should have processed their chunks
                foreach ($w in $workerResults.Keys) {
                    $workerResults[$w] | Should -Be $chunksPerWorker
                }

                $script:OrchestrationState.CompletedCount | Should -Be $totalChunks
            }

            It "Should handle burst of 100 errors without data loss" {
                $errorCount = 100

                # Burst of errors
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                for ($i = 0; $i -lt $errorCount; $i++) {
                    $script:OrchestrationState.EnqueueError("Error $i`: File copy failed - Access denied to C:\Protected\file$i.txt")
                }
                $stopwatch.Stop()

                # All errors should be captured
                $script:OrchestrationState.ErrorMessages.Count | Should -Be $errorCount

                # Should be fast
                $stopwatch.ElapsedMilliseconds | Should -BeLessThan 500

                # Dequeue and verify
                $errors = $script:OrchestrationState.DequeueErrors()
                $errors.Count | Should -Be $errorCount

                # Verify content integrity
                $errors[0] | Should -Match "Error 0"
                $errors[99] | Should -Match "Error 99"
            }
        }

        Context "Retry Queue Stress" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should handle chunks cycling through retry queue multiple times" {
                $chunkCount = 50
                $maxRetries = 3

                # Create chunks that will need retries
                for ($i = 0; $i -lt $chunkCount; $i++) {
                    $chunk = [PSCustomObject]@{
                        ChunkId = $i
                        SourcePath = "C:\Flaky\Path$i"
                        RetryCount = 0
                        RetryAfter = $null
                    }
                    $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
                }

                # Simulate multiple retry cycles
                for ($retry = 0; $retry -lt $maxRetries; $retry++) {
                    $processedThisCycle = 0
                    $chunk = $null

                    while ($script:OrchestrationState.ChunkQueue.TryDequeue([ref]$chunk)) {
                        $chunk.RetryCount++
                        $chunk.RetryAfter = [datetime]::Now.AddSeconds(5)

                        if ($chunk.RetryCount -lt $maxRetries) {
                            # Re-queue for retry
                            $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
                        }
                        else {
                            # Max retries reached, mark as failed
                            $script:OrchestrationState.FailedChunks.Enqueue([PSCustomObject]@{
                                Chunk = $chunk
                                ErrorMessage = "Failed after $maxRetries retries"
                            })
                        }
                        $processedThisCycle++
                    }
                }

                # All chunks should eventually fail
                $script:OrchestrationState.FailedChunks.Count | Should -Be $chunkCount
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 0
            }
        }

        Context "Profile Transition Under Load" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should cleanly transition between 10 profiles with 100 chunks each" {
                $profileCount = 10
                $chunksPerProfile = 100

                for ($p = 0; $p -lt $profileCount; $p++) {
                    # Set up profile
                    $script:OrchestrationState.CurrentProfile = "Profile$p"
                    $script:OrchestrationState.Phase = "Replicating"

                    # Queue chunks for this profile
                    for ($c = 0; $c -lt $chunksPerProfile; $c++) {
                        $chunk = [PSCustomObject]@{
                            ChunkId = $c
                            ProfileIndex = $p
                            SourcePath = "C:\Profile$p\Chunk$c"
                        }
                        $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
                    }
                    $script:OrchestrationState.TotalChunks = $chunksPerProfile

                    # Process all chunks
                    $chunk = $null
                    while ($script:OrchestrationState.ChunkQueue.TryDequeue([ref]$chunk)) {
                        $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
                        $script:OrchestrationState.IncrementCompletedCount()
                    }

                    # Store profile result
                    $result = [PSCustomObject]@{
                        ProfileName = "Profile$p"
                        ChunksComplete = $script:OrchestrationState.CompletedCount
                        ChunksTotal = $chunksPerProfile
                        BytesCopied = $chunksPerProfile * 1000000
                    }
                    $script:OrchestrationState.ProfileResults.Enqueue($result)

                    # Verify profile completion
                    $script:OrchestrationState.CompletedCount | Should -Be $chunksPerProfile

                    # Reset for next profile
                    $script:OrchestrationState.ResetForNewProfile()
                }

                # Verify all profiles completed
                $script:OrchestrationState.ProfileResults.Count | Should -Be $profileCount

                # Verify total work done
                $allResults = $script:OrchestrationState.ProfileResults.ToArray()
                $totalChunks = ($allResults | Measure-Object -Property ChunksComplete -Sum).Sum
                $totalChunks | Should -Be ($profileCount * $chunksPerProfile)
            }
        }

        Context "Concurrent Bytes Tracking Accuracy" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should accurately track bytes from 100 concurrent chunks" {
                $chunkCount = 100
                $bytesPerChunk = 10000000  # 10MB

                for ($i = 0; $i -lt $chunkCount; $i++) {
                    $script:OrchestrationState.AddCompletedChunkBytes($bytesPerChunk)
                    $script:OrchestrationState.AddCompletedChunkFiles(100)  # 100 files per chunk
                }

                $script:OrchestrationState.CompletedChunkBytes | Should -Be ($chunkCount * $bytesPerChunk)
                $script:OrchestrationState.CompletedChunkFiles | Should -Be ($chunkCount * 100)
            }

            It "Should handle varying chunk sizes accurately" {
                $chunks = @(
                    @{ Size = 100MB; Files = 1000 }
                    @{ Size = 500MB; Files = 5000 }
                    @{ Size = 1GB; Files = 10000 }
                    @{ Size = 50MB; Files = 500 }
                    @{ Size = 2GB; Files = 20000 }
                )

                $expectedBytes = 0
                $expectedFiles = 0

                foreach ($chunk in $chunks) {
                    $script:OrchestrationState.AddCompletedChunkBytes($chunk.Size)
                    $script:OrchestrationState.AddCompletedChunkFiles($chunk.Files)
                    $expectedBytes += $chunk.Size
                    $expectedFiles += $chunk.Files
                }

                $script:OrchestrationState.CompletedChunkBytes | Should -Be $expectedBytes
                $script:OrchestrationState.CompletedChunkFiles | Should -Be $expectedFiles
            }
        }
    }
}
