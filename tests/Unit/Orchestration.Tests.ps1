#Requires -Modules Pester

# Load module at discovery time so InModuleScope can find it
# This must happen before InModuleScope is evaluated
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type (needed before tests run)
Initialize-OrchestrationStateType | Out-Null

# Use InModuleScope to access module-internal $script:OrchestrationState
InModuleScope 'Robocurse' {
    Describe "Orchestration" {
        BeforeEach {
            # Reset state before each test using the C# class's Reset() method
            $script:OrchestrationState.Reset()

            # Clear callbacks
            $script:OnProgress = $null
            $script:OnChunkComplete = $null
            $script:OnProfileComplete = $null

            # Mock logging functions to prevent actual file writes
            Mock Write-RobocurseLog { }
            Mock Write-SiemEvent { }
        }

        Context "Start-ReplicationRun Validation" {
            It "Should throw when Profiles is null" {
                {
                    Start-ReplicationRun -Profiles $null
                } | Should -Throw "*Profiles*"
            }

            It "Should throw when Profiles array is empty" {
                {
                    Start-ReplicationRun -Profiles @()
                } | Should -Throw  # PowerShell rejects empty arrays at binding time
            }

            It "Should throw when Profile is missing Name property" {
                $badProfile = [PSCustomObject]@{
                    Source = "C:\Test"
                    Destination = "D:\Test"
                }
                {
                    Start-ReplicationRun -Profiles @($badProfile)
                } | Should -Throw "*Name*"
            }

            It "Should throw when Profile is missing Source property" {
                $badProfile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Destination = "D:\Test"
                }
                {
                    Start-ReplicationRun -Profiles @($badProfile)
                } | Should -Throw "*Source*"
            }

            It "Should throw when Profile is missing Destination property" {
                $badProfile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Test"
                }
                {
                    Start-ReplicationRun -Profiles @($badProfile)
                } | Should -Throw "*Destination*"
            }

            It "Should throw when MaxConcurrentJobs is out of range (too low)" {
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Test"
                    Destination = "D:\Test"
                }
                {
                    Start-ReplicationRun -Profiles @($profile) -MaxConcurrentJobs 0
                } | Should -Throw
            }

            It "Should throw when MaxConcurrentJobs is out of range (too high)" {
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Test"
                    Destination = "D:\Test"
                }
                {
                    Start-ReplicationRun -Profiles @($profile) -MaxConcurrentJobs 129
                } | Should -Throw
            }
        }

        Context "Initialize-OrchestrationState" {
            It "Should initialize state with default values" {
                Initialize-OrchestrationState

                $script:OrchestrationState.SessionId | Should -Not -BeNullOrEmpty
                $script:OrchestrationState.Phase | Should -Be "Idle"
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 0
                $script:OrchestrationState.ActiveJobs.Count | Should -Be 0
                $script:OrchestrationState.TotalChunks | Should -Be 0
                $script:OrchestrationState.StopRequested | Should -Be $false
                $script:OrchestrationState.PauseRequested | Should -Be $false
            }

            It "Should generate a new SessionId" {
                Initialize-OrchestrationState
                $sessionId1 = $script:OrchestrationState.SessionId

                Initialize-OrchestrationState
                $sessionId2 = $script:OrchestrationState.SessionId

                $sessionId1 | Should -Not -Be $sessionId2
            }

            It "Should reset CompletedChunkBytes counter" {
                # Set a value
                $script:OrchestrationState.AddCompletedChunkBytes(1000000)
                $script:OrchestrationState.CompletedChunkBytes | Should -BeGreaterThan 0

                # Reset should clear it
                Initialize-OrchestrationState
                $script:OrchestrationState.CompletedChunkBytes | Should -Be 0
            }

            It "Should reset ChunkIdCounter correctly for multi-run scenarios" {
                # This test verifies the fix for the [ref]0 bug in Initialize-OrchestrationState
                # Previously, $script:ChunkIdCounter was incorrectly set to [ref]0 which would
                # cause Interlocked.Increment to fail on subsequent runs

                # First run - initialize state which resets the counter
                Initialize-OrchestrationState

                # Verify ChunkIdCounter is a plain integer (not wrapped in [ref])
                $script:ChunkIdCounter | Should -BeOfType [int]
                $script:ChunkIdCounter | Should -Be 0

                # Simulate what New-Chunk does - increment the counter
                $firstId = [System.Threading.Interlocked]::Increment([ref]$script:ChunkIdCounter)
                $firstId | Should -Be 1

                # Second run - reinitialize (this is where the [ref]0 bug would manifest)
                # If [ref]0 bug exists, this would set ChunkIdCounter to a reference object
                Initialize-OrchestrationState

                # Verify counter is still a plain integer after reset
                $script:ChunkIdCounter | Should -BeOfType [int]
                $script:ChunkIdCounter | Should -Be 0

                # This increment would fail with [ref]0 bug because Interlocked.Increment
                # would receive [ref][ref]0 instead of [ref]0
                { $script:secondId = [System.Threading.Interlocked]::Increment([ref]$script:ChunkIdCounter) } | Should -Not -Throw
                $script:secondId | Should -Be 1
            }
        }

        Context "OrchestrationState - CompletedChunkBytes Counter" {
            It "Should atomically add completed chunk bytes" {
                $script:OrchestrationState.CompletedChunkBytes | Should -Be 0

                $result = $script:OrchestrationState.AddCompletedChunkBytes(1000000)

                $result | Should -Be 1000000
                $script:OrchestrationState.CompletedChunkBytes | Should -Be 1000000
            }

            It "Should accumulate multiple adds" {
                $script:OrchestrationState.AddCompletedChunkBytes(1000)
                $script:OrchestrationState.AddCompletedChunkBytes(2000)
                $script:OrchestrationState.AddCompletedChunkBytes(3000)

                $script:OrchestrationState.CompletedChunkBytes | Should -Be 6000
            }

            It "Should reset via CompletedChunkBytes setter" {
                $script:OrchestrationState.AddCompletedChunkBytes(5000)
                $script:OrchestrationState.CompletedChunkBytes | Should -Be 5000

                $script:OrchestrationState.CompletedChunkBytes = 0

                $script:OrchestrationState.CompletedChunkBytes | Should -Be 0
            }
        }

        Context "Invoke-ReplicationTick" {
            It "Should start jobs up to max concurrent" {
                # Add chunks to queue
                1..10 | ForEach-Object {
                    $chunk = [PSCustomObject]@{
                        ChunkId = $_
                        SourcePath = "C:\Test$_"
                        DestinationPath = "D:\Test$_"
                    }
                    $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
                }
                $script:OrchestrationState.TotalChunks = 10

                # Mock Start-ChunkJob to return a mock job
                Mock Start-ChunkJob {
                    param($Chunk)
                    $mockProcess = [PSCustomObject]@{
                        Id = Get-Random -Minimum 1000 -Maximum 9999
                        HasExited = $false
                    }
                    [PSCustomObject]@{
                        Process = $mockProcess
                        Chunk = $Chunk
                        StartTime = [datetime]::Now
                        LogPath = "C:\Logs\chunk.log"
                    }
                }

                Mock Update-ProgressStats { }

                Invoke-ReplicationTick -MaxConcurrentJobs 4

                $script:OrchestrationState.ActiveJobs.Count | Should -Be 4
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 6
            }

            It "Should handle null job return gracefully and requeue chunk" {
                # Add a chunk to queue with all required properties
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                    RetryCount = 0
                    RetryAfter = $null
                }
                $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
                $script:OrchestrationState.TotalChunks = 1

                # Mock Start-ChunkJob to return null (simulating process start failure)
                Mock Start-ChunkJob { return $null }
                Mock Update-ProgressStats { }

                Invoke-ReplicationTick -MaxConcurrentJobs 4

                # Job should not be added to active jobs
                $script:OrchestrationState.ActiveJobs.Count | Should -Be 0
                # Chunk should be requeued for retry
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 1
            }

            It "Should not start new jobs when paused" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                }
                $script:OrchestrationState.ChunkQueue.Enqueue($chunk)
                $script:OrchestrationState.PauseRequested = $true

                Mock Start-ChunkJob { }
                Mock Update-ProgressStats { }

                Invoke-ReplicationTick -MaxConcurrentJobs 4

                Should -Not -Invoke Start-ChunkJob
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 1
            }

            It "Should skip chunks in backoff delay period" {
                # Chunk with future RetryAfter should be re-queued, not started
                $chunkInBackoff = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test1"
                    DestinationPath = "D:\Test1"
                    RetryAfter = [datetime]::Now.AddSeconds(30)  # 30 seconds in the future
                }
                # Chunk without RetryAfter should start normally
                $chunkReady = [PSCustomObject]@{
                    ChunkId = 2
                    SourcePath = "C:\Test2"
                    DestinationPath = "D:\Test2"
                }
                $script:OrchestrationState.ChunkQueue.Enqueue($chunkInBackoff)
                $script:OrchestrationState.ChunkQueue.Enqueue($chunkReady)
                $script:OrchestrationState.TotalChunks = 2

                Mock Start-ChunkJob {
                    param($Chunk)
                    $mockProcess = [PSCustomObject]@{
                        Id = Get-Random -Minimum 1000 -Maximum 9999
                        HasExited = $false
                    }
                    [PSCustomObject]@{
                        Process = $mockProcess
                        Chunk = $Chunk
                        StartTime = [datetime]::Now
                        LogPath = "C:\Logs\chunk.log"
                    }
                }
                Mock Update-ProgressStats { }

                Invoke-ReplicationTick -MaxConcurrentJobs 4

                # Only the ready chunk should have started
                Should -Invoke Start-ChunkJob -Times 1
                $script:OrchestrationState.ActiveJobs.Count | Should -Be 1
                # The backoff chunk should be re-queued
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 1
            }

            It "Should start chunks after backoff period expires" {
                # Chunk with past RetryAfter should start
                $chunkReady = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test1"
                    DestinationPath = "D:\Test1"
                    RetryAfter = [datetime]::Now.AddSeconds(-5)  # 5 seconds in the past
                }
                $script:OrchestrationState.ChunkQueue.Enqueue($chunkReady)
                $script:OrchestrationState.TotalChunks = 1

                Mock Start-ChunkJob {
                    param($Chunk)
                    $mockProcess = [PSCustomObject]@{
                        Id = Get-Random -Minimum 1000 -Maximum 9999
                        HasExited = $false
                    }
                    [PSCustomObject]@{
                        Process = $mockProcess
                        Chunk = $Chunk
                        StartTime = [datetime]::Now
                        LogPath = "C:\Logs\chunk.log"
                    }
                }
                Mock Update-ProgressStats { }

                Invoke-ReplicationTick -MaxConcurrentJobs 4

                Should -Invoke Start-ChunkJob -Times 1
                $script:OrchestrationState.ActiveJobs.Count | Should -Be 1
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 0
            }

            It "Should stop all jobs when stop requested" {
                $script:OrchestrationState.StopRequested = $true

                Mock Stop-AllJobs { }
                Mock Update-ProgressStats { }

                Invoke-ReplicationTick -MaxConcurrentJobs 4

                Should -Invoke Stop-AllJobs -Times 1
            }

            It "Should process completed jobs" {
                # Create a mock job that has exited
                $mockProcess = [PSCustomObject]@{
                    Id = 1234
                    HasExited = $true
                    ExitCode = 1
                }
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                }
                $job = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                    StartTime = [datetime]::Now.AddSeconds(-10)
                    LogPath = "C:\Logs\chunk.log"
                }
                $script:OrchestrationState.ActiveJobs[1234] = $job

                # Mock Complete-RobocopyJob to return success result
                Mock Complete-RobocopyJob {
                    param($Job)
                    [PSCustomObject]@{
                        Job = $Job
                        ExitCode = 1
                        ExitMeaning = [PSCustomObject]@{
                            Severity = 'Success'
                            Message = 'Files copied successfully'
                            ShouldRetry = $false
                        }
                        Stats = [PSCustomObject]@{
                            FilesCopied = 100
                            BytesCopied = 1000000
                        }
                        Duration = [timespan]::FromSeconds(10)
                    }
                }

                Mock Update-ProgressStats { }

                Invoke-ReplicationTick -MaxConcurrentJobs 4

                # Job should be removed from active
                $script:OrchestrationState.ActiveJobs.Count | Should -Be 0
                # Chunk should be in completed
                $script:OrchestrationState.CompletedChunks.Count | Should -Be 1
                $script:OrchestrationState.CompletedCount | Should -Be 1
            }

            It "Should invoke OnChunkComplete callback when chunk completes" {
                $script:callbackInvoked = $false
                $script:OnChunkComplete = {
                    param($Job, $Result)
                    $script:callbackInvoked = $true
                }

                # Create a mock job that has exited
                $mockProcess = [PSCustomObject]@{
                    Id = 1234
                    HasExited = $true
                    ExitCode = 1
                }
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                }
                $job = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                    StartTime = [datetime]::Now.AddSeconds(-10)
                    LogPath = "C:\Logs\chunk.log"
                }
                $script:OrchestrationState.ActiveJobs[1234] = $job

                Mock Complete-RobocopyJob {
                    [PSCustomObject]@{
                        ExitCode = 1
                        ExitMeaning = [PSCustomObject]@{ Severity = 'Success'; ShouldRetry = $false }
                        Stats = [PSCustomObject]@{}
                        Duration = [timespan]::FromSeconds(10)
                    }
                }
                Mock Update-ProgressStats { }

                Invoke-ReplicationTick -MaxConcurrentJobs 4

                $script:callbackInvoked | Should -Be $true
            }
        }

        Context "Get-RetryBackoffDelay" {
            It "Should return base delay for first retry" {
                $delay = Get-RetryBackoffDelay -RetryCount 1

                $delay | Should -Be $script:RetryBackoffBaseSeconds
            }

            It "Should double delay for second retry" {
                $delay = Get-RetryBackoffDelay -RetryCount 2

                # base * multiplier = 5 * 2 = 10
                $expected = $script:RetryBackoffBaseSeconds * $script:RetryBackoffMultiplier
                $delay | Should -Be $expected
            }

            It "Should quadruple delay for third retry" {
                $delay = Get-RetryBackoffDelay -RetryCount 3

                # base * multiplier^2 = 5 * 4 = 20
                $expected = [math]::Ceiling($script:RetryBackoffBaseSeconds * [math]::Pow($script:RetryBackoffMultiplier, 2))
                $delay | Should -Be $expected
            }

            It "Should cap at maximum delay" {
                $delay = Get-RetryBackoffDelay -RetryCount 10

                $delay | Should -Be $script:RetryBackoffMaxSeconds
            }

            It "Should throw for invalid retry count" {
                { Get-RetryBackoffDelay -RetryCount 0 } | Should -Throw
            }
        }

        Context "Invoke-FailedChunkHandler" {
            It "Should retry failed chunk up to 3 times with backoff delay" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                    RetryCount = 0
                    RetryAfter = $null
                }
                $job = [PSCustomObject]@{ Chunk = $chunk }
                $result = [PSCustomObject]@{
                    ExitCode = 8
                    ExitMeaning = [PSCustomObject]@{
                        Severity = 'Error'
                        ShouldRetry = $true
                    }
                }

                Invoke-FailedChunkHandler -Job $job -Result $result

                $script:OrchestrationState.ChunkQueue.Count | Should -Be 1
                $chunk.RetryCount | Should -Be 1
                $chunk.RetryAfter | Should -Not -BeNullOrEmpty
                $chunk.RetryAfter | Should -BeGreaterThan ([datetime]::Now)
                $script:OrchestrationState.FailedChunks.Count | Should -Be 0
            }

            It "Should set increasing backoff delay for subsequent retries" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                    RetryCount = 1
                    RetryAfter = $null
                }
                $job = [PSCustomObject]@{ Chunk = $chunk }
                $result = [PSCustomObject]@{
                    ExitCode = 8
                    ExitMeaning = [PSCustomObject]@{
                        Severity = 'Error'
                        ShouldRetry = $true
                    }
                }

                $beforeRetry = [datetime]::Now

                Invoke-FailedChunkHandler -Job $job -Result $result

                $script:OrchestrationState.ChunkQueue.Count | Should -Be 1
                $chunk.RetryCount | Should -Be 2
                # Second retry should have longer delay than first (10s vs 5s with default settings)
                $expectedDelay = Get-RetryBackoffDelay -RetryCount 2
                $expectedRetryAfter = $beforeRetry.AddSeconds($expectedDelay)
                # Allow 1 second tolerance for test execution time
                $chunk.RetryAfter | Should -BeGreaterThan $beforeRetry.AddSeconds($expectedDelay - 1)
                $script:OrchestrationState.FailedChunks.Count | Should -Be 0
            }

            It "Should mark as failed after max retries" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                    RetryCount = 2
                    Status = 'Pending'
                }
                $job = [PSCustomObject]@{ Chunk = $chunk }
                $result = [PSCustomObject]@{
                    ExitCode = 8
                    ExitMeaning = [PSCustomObject]@{
                        Severity = 'Error'
                        ShouldRetry = $true
                    }
                }

                Invoke-FailedChunkHandler -Job $job -Result $result

                $script:OrchestrationState.FailedChunks.Count | Should -Be 1
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 0
                $chunk.RetryCount | Should -Be 3
                $chunk.Status | Should -Be 'Failed'
            }

            It "Should not retry if ShouldRetry is false" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                    RetryCount = 0
                    Status = 'Pending'
                }
                $job = [PSCustomObject]@{ Chunk = $chunk }
                $result = [PSCustomObject]@{
                    ExitCode = 8
                    ExitMeaning = [PSCustomObject]@{
                        Severity = 'Error'
                        ShouldRetry = $false
                    }
                }

                Invoke-FailedChunkHandler -Job $job -Result $result

                $script:OrchestrationState.FailedChunks.Count | Should -Be 1
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 0
            }
        }

        Context "Stop-AllJobs" {
            It "Should kill all running processes" {
                # Create mock processes with Kill method
                $mockProcess1 = [PSCustomObject]@{
                    Id = 1234
                    HasExited = $false
                }
                $mockProcess1 | Add-Member -MemberType ScriptMethod -Name Kill -Value {
                    $this.HasExited = $true
                }

                $mockProcess2 = [PSCustomObject]@{
                    Id = 5678
                    HasExited = $false
                }
                $mockProcess2 | Add-Member -MemberType ScriptMethod -Name Kill -Value {
                    $this.HasExited = $true
                }

                $chunk1 = [PSCustomObject]@{ ChunkId = 1 }
                $chunk2 = [PSCustomObject]@{ ChunkId = 2 }

                $script:OrchestrationState.ActiveJobs[1234] = [PSCustomObject]@{
                    Process = $mockProcess1
                    Chunk = $chunk1
                }
                $script:OrchestrationState.ActiveJobs[5678] = [PSCustomObject]@{
                    Process = $mockProcess2
                    Chunk = $chunk2
                }

                Stop-AllJobs

                $mockProcess1.HasExited | Should -Be $true
                $mockProcess2.HasExited | Should -Be $true
                $script:OrchestrationState.ActiveJobs.Count | Should -Be 0
                $script:OrchestrationState.Phase | Should -Be "Stopped"
            }

            It "Should not throw if process has already exited" {
                $mockProcess = [PSCustomObject]@{
                    Id = 1234
                    HasExited = $true
                }
                $mockProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value {
                    throw "Process already exited"
                }

                $chunk = [PSCustomObject]@{ ChunkId = 1 }
                $script:OrchestrationState.ActiveJobs[1234] = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                }

                { Stop-AllJobs } | Should -Not -Throw
                $script:OrchestrationState.ActiveJobs.Count | Should -Be 0
            }

            It "Should log errors if Kill fails" {
                $mockProcess = [PSCustomObject]@{
                    Id = 1234
                    HasExited = $false
                }
                $mockProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value {
                    throw "Access denied"
                }

                $chunk = [PSCustomObject]@{ ChunkId = 1 }
                $script:OrchestrationState.ActiveJobs[1234] = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                }

                Stop-AllJobs

                Should -Invoke Write-RobocurseLog -ParameterFilter {
                    $Level -eq 'Error' -and $Message -like "*Failed to kill*"
                }
            }
        }

        Context "Request-Stop" {
            It "Should set StopRequested flag" {
                $script:OrchestrationState.StopRequested | Should -Be $false

                Request-Stop

                $script:OrchestrationState.StopRequested | Should -Be $true
            }
        }

        Context "Request-Pause" {
            It "Should set PauseRequested flag" {
                $script:OrchestrationState.PauseRequested | Should -Be $false

                Request-Pause

                $script:OrchestrationState.PauseRequested | Should -Be $true
            }
        }

        Context "Request-Resume" {
            It "Should clear PauseRequested flag" {
                $script:OrchestrationState.PauseRequested = $true

                Request-Resume

                $script:OrchestrationState.PauseRequested | Should -Be $false
            }
        }

        Context "Update-ProgressStats" {
            It "Should calculate bytes from completed chunks" {
                # Simulate chunk completion - add to both queue AND counter
                # (In production, Invoke-ReplicationTick does both when a chunk completes)
                $chunk1 = [PSCustomObject]@{
                    ChunkId = 1
                    EstimatedSize = 1000000
                }
                $chunk2 = [PSCustomObject]@{
                    ChunkId = 2
                    EstimatedSize = 2000000
                }
                $script:OrchestrationState.CompletedChunks.Enqueue($chunk1)
                $script:OrchestrationState.AddCompletedChunkBytes($chunk1.EstimatedSize)
                $script:OrchestrationState.CompletedChunks.Enqueue($chunk2)
                $script:OrchestrationState.AddCompletedChunkBytes($chunk2.EstimatedSize)

                Mock Get-RobocopyProgress { }

                Update-ProgressStats

                $script:OrchestrationState.BytesComplete | Should -Be 3000000
            }

            It "Should include bytes from active jobs" {
                # Simulate a completed chunk - add to both queue AND counter
                $chunk1 = [PSCustomObject]@{
                    ChunkId = 1
                    EstimatedSize = 1000000
                }
                $script:OrchestrationState.CompletedChunks.Enqueue($chunk1)
                $script:OrchestrationState.AddCompletedChunkBytes($chunk1.EstimatedSize)

                # Mock active job
                $mockProcess = [PSCustomObject]@{ Id = 1234 }
                $job = [PSCustomObject]@{
                    Process = $mockProcess
                    LogPath = "C:\Logs\chunk.log"
                }
                $script:OrchestrationState.ActiveJobs[1234] = $job

                Mock Get-RobocopyProgress {
                    param($Job)
                    [PSCustomObject]@{
                        BytesCopied = 500000
                    }
                }

                Update-ProgressStats

                $script:OrchestrationState.BytesComplete | Should -Be 1500000
            }
        }

        Context "Get-OrchestrationStatus" {
            It "Should return status object with all fields" {
                $script:OrchestrationState.Phase = "Replicating"
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "TestProfile" }
                $script:OrchestrationState.TotalChunks = 10
                $script:OrchestrationState.CompletedCount = 5
                $script:OrchestrationState.StartTime = [datetime]::Now.AddMinutes(-5)

                Mock Get-ETAEstimate { [timespan]::FromMinutes(5) }

                $status = Get-OrchestrationStatus

                $status.Phase | Should -Be "Replicating"
                $status.CurrentProfile | Should -Be "TestProfile"
                $status.ProfileProgress | Should -Be 50.0
                $status.ChunksComplete | Should -Be 5
                $status.ChunksTotal | Should -Be 10
                $status.Elapsed | Should -Not -BeNullOrEmpty
                $status.ETA | Should -Not -BeNullOrEmpty
            }

            It "Should handle null CurrentProfile" {
                $script:OrchestrationState.CurrentProfile = $null

                Mock Get-ETAEstimate { $null }

                $status = Get-OrchestrationStatus

                $status.CurrentProfile | Should -Be ""
            }
        }

        Context "Get-ETAEstimate" {
            It "Should calculate ETA based on progress" {
                $script:OrchestrationState.StartTime = [datetime]::Now.AddSeconds(-100)
                $script:OrchestrationState.TotalBytes = 10000000
                $script:OrchestrationState.BytesComplete = 5000000

                $eta = Get-ETAEstimate

                $eta | Should -Not -BeNullOrEmpty
                $eta.TotalSeconds | Should -BeGreaterThan 0
                # Should be approximately 100 seconds (same time as elapsed)
                $eta.TotalSeconds | Should -BeGreaterThan 50
                $eta.TotalSeconds | Should -BeLessThan 150
            }

            It "Should return null if no progress" {
                $script:OrchestrationState.StartTime = [datetime]::Now.AddSeconds(-100)
                $script:OrchestrationState.TotalBytes = 10000000
                $script:OrchestrationState.BytesComplete = 0

                $eta = Get-ETAEstimate

                $eta | Should -BeNullOrEmpty
            }

            It "Should return null if no start time" {
                $script:OrchestrationState.StartTime = $null
                $script:OrchestrationState.TotalBytes = 10000000
                $script:OrchestrationState.BytesComplete = 5000000

                $eta = Get-ETAEstimate

                $eta | Should -BeNullOrEmpty
            }

            It "Should return null if elapsed time is nearly zero (avoid division by zero)" {
                # Start time is now - should have near-zero elapsed
                $script:OrchestrationState.StartTime = [datetime]::Now
                $script:OrchestrationState.TotalBytes = 10000000
                $script:OrchestrationState.BytesComplete = 5000000

                $eta = Get-ETAEstimate

                # With nearly zero elapsed time, should return null to avoid division by zero
                $eta | Should -BeNullOrEmpty
            }

            It "Should return zero timespan when all bytes are complete" {
                $script:OrchestrationState.StartTime = [datetime]::Now.AddSeconds(-100)
                $script:OrchestrationState.TotalBytes = 10000000
                $script:OrchestrationState.BytesComplete = 10000000  # All complete

                $eta = Get-ETAEstimate

                # When complete, should return zero (no time remaining)
                $eta | Should -Not -BeNullOrEmpty
                $eta.TotalSeconds | Should -Be 0
            }
        }

        Context "Complete-RobocopyJob" {
            It "Should process completed job and return result" {
                $mockProcess = [PSCustomObject]@{
                    ExitCode = 1
                }
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                    Status = 'Pending'
                }
                $job = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                    StartTime = [datetime]::Now.AddSeconds(-10)
                    LogPath = "C:\Logs\chunk.log"
                }

                Mock Get-RobocopyExitMeaning {
                    [PSCustomObject]@{
                        Severity = 'Success'
                        Message = 'Files copied successfully'
                        ShouldRetry = $false
                    }
                }

                Mock ConvertFrom-RobocopyLog {
                    [PSCustomObject]@{
                        FilesCopied = 100
                        BytesCopied = 1000000
                    }
                }

                $result = Complete-RobocopyJob -Job $job

                $result.ExitCode | Should -Be 1
                $result.ExitMeaning.Severity | Should -Be 'Success'
                $result.Stats.FilesCopied | Should -Be 100
                $chunk.Status | Should -Be 'Complete'
            }

            It "Should mark chunk as failed for error severity" {
                $mockProcess = [PSCustomObject]@{ ExitCode = 8 }
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                    Status = 'Pending'
                }
                $job = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                    StartTime = [datetime]::Now.AddSeconds(-10)
                    LogPath = "C:\Logs\chunk.log"
                }

                Mock Get-RobocopyExitMeaning {
                    [PSCustomObject]@{
                        Severity = 'Error'
                        Message = 'Some files could not be copied'
                        ShouldRetry = $true
                    }
                }

                Mock ConvertFrom-RobocopyLog {
                    [PSCustomObject]@{
                        FilesCopied = 50
                        BytesCopied = 500000
                    }
                }

                $result = Complete-RobocopyJob -Job $job

                $chunk.Status | Should -Be 'Failed'
            }

            It "Should use per-profile MismatchSeverity when set" {
                $mockProcess = [PSCustomObject]@{ ExitCode = 4 }
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                    Status = 'Pending'
                }
                $job = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                    StartTime = [datetime]::Now.AddSeconds(-10)
                    LogPath = "C:\Logs\chunk.log"
                }

                # Set profile-level MismatchSeverity override
                $script:OrchestrationState.CurrentRobocopyOptions = @{
                    MismatchSeverity = 'Success'
                }

                Mock Get-RobocopyExitMeaning {
                    param($ExitCode, $MismatchSeverity)
                    # Verify the profile override was passed
                    $MismatchSeverity | Should -Be 'Success'
                    [PSCustomObject]@{
                        Severity = 'Success'
                        Message = 'Mismatches ignored per profile config'
                        ShouldRetry = $false
                    }
                }

                Mock ConvertFrom-RobocopyLog {
                    [PSCustomObject]@{
                        FilesCopied = 100
                        BytesCopied = 1000000
                    }
                }

                $result = Complete-RobocopyJob -Job $job

                Should -Invoke Get-RobocopyExitMeaning -ParameterFilter {
                    $MismatchSeverity -eq 'Success'
                }
            }

            It "Should use global default MismatchSeverity when profile has no override" {
                $mockProcess = [PSCustomObject]@{ ExitCode = 4 }
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                    Status = 'Pending'
                }
                $job = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                    StartTime = [datetime]::Now.AddSeconds(-10)
                    LogPath = "C:\Logs\chunk.log"
                }

                # No MismatchSeverity in profile options
                $script:OrchestrationState.CurrentRobocopyOptions = @{
                    Switches = @('/COPYALL')
                }

                Mock Get-RobocopyExitMeaning {
                    param($ExitCode, $MismatchSeverity)
                    [PSCustomObject]@{
                        Severity = $MismatchSeverity
                        Message = 'Mismatches detected'
                        ShouldRetry = $false
                    }
                }

                Mock ConvertFrom-RobocopyLog {
                    [PSCustomObject]@{
                        FilesCopied = 100
                        BytesCopied = 1000000
                    }
                }

                $result = Complete-RobocopyJob -Job $job

                # Should use the global default (Warning)
                Should -Invoke Get-RobocopyExitMeaning -ParameterFilter {
                    $MismatchSeverity -eq $script:DefaultMismatchSeverity
                }
            }
        }

        Context "Complete-CurrentProfile" {
            BeforeEach {
                # Set up a running profile
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                }
                $script:OrchestrationState.ProfileStartTime = [datetime]::Now.AddMinutes(-5)
                $script:OrchestrationState.StartTime = [datetime]::Now.AddMinutes(-10)
                $script:OrchestrationState.Phase = "Replicating"
                $script:OrchestrationState.TotalChunks = 10
                $script:OrchestrationState.ProfileIndex = 0
                $script:OrchestrationState.Profiles = @($script:OrchestrationState.CurrentProfile)

                # Add some completed chunks
                $script:OrchestrationState.CompletedChunks.Enqueue([PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Source\Dir1"
                    EstimatedSize = 1000000
                })
                $script:OrchestrationState.CompletedChunks.Enqueue([PSCustomObject]@{
                    ChunkId = 2
                    SourcePath = "C:\Source\Dir2"
                    EstimatedSize = 2000000
                })

                # Add a failed chunk
                $script:OrchestrationState.FailedChunks.Enqueue([PSCustomObject]@{
                    ChunkId = 3
                    SourcePath = "C:\Source\Dir3"
                })
            }

            It "Should create ProfileResults with statistics" {
                Complete-CurrentProfile

                $results = $script:OrchestrationState.GetProfileResultsArray()
                $results | Should -Not -BeNullOrEmpty
                $results.Count | Should -Be 1

                $pr = $results[0]
                $pr.Name | Should -Be "TestProfile"
                $pr.ChunksComplete | Should -Be 2
                $pr.ChunksFailed | Should -Be 1
                $pr.BytesCopied | Should -Be 3000000
            }

            It "Should clear CompletedChunks after profile completes" {
                $script:OrchestrationState.CompletedChunks.Count | Should -Be 2

                Complete-CurrentProfile

                $script:OrchestrationState.CompletedChunks.Count | Should -Be 0
            }

            It "Should clear FailedChunks after profile completes" {
                $script:OrchestrationState.FailedChunks.Count | Should -Be 1

                Complete-CurrentProfile

                $script:OrchestrationState.FailedChunks.Count | Should -Be 0
            }

            It "Should set status to Warning when there are failed chunks" {
                Complete-CurrentProfile

                $results = $script:OrchestrationState.GetProfileResultsArray()
                $results[0].Status | Should -Be 'Warning'
            }

            It "Should set status to Success when all chunks succeed" {
                # Clear failed chunks using the C# class method
                $script:OrchestrationState.ClearChunkCollections()
                # Re-add the completed chunks after clearing
                $script:OrchestrationState.CompletedChunks.Enqueue([PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Source\Dir1"
                    EstimatedSize = 1000000
                })
                $script:OrchestrationState.CompletedChunks.Enqueue([PSCustomObject]@{
                    ChunkId = 2
                    SourcePath = "C:\Source\Dir2"
                    EstimatedSize = 2000000
                })

                Complete-CurrentProfile

                $results = $script:OrchestrationState.GetProfileResultsArray()
                $results[0].Status | Should -Be 'Success'
            }

            It "Should invoke OnProfileComplete callback" {
                $script:callbackInvoked = $false
                $script:OnProfileComplete = {
                    param($Profile)
                    $script:callbackInvoked = $true
                }

                Complete-CurrentProfile

                $script:callbackInvoked | Should -Be $true
            }

            It "Should advance to next profile if more profiles exist" {
                $script:OrchestrationState.Profiles = @(
                    [PSCustomObject]@{ Name = "Profile1"; Source = "C:\S1"; Destination = "D:\D1" },
                    [PSCustomObject]@{ Name = "Profile2"; Source = "C:\S2"; Destination = "D:\D2" }
                )
                $script:OrchestrationState.ProfileIndex = 0
                $script:OrchestrationState.CurrentProfile = $script:OrchestrationState.Profiles[0]

                Mock Start-ProfileReplication { }

                Complete-CurrentProfile

                $script:OrchestrationState.ProfileIndex | Should -Be 1
                Should -Invoke Start-ProfileReplication -Times 1
            }

            It "Should set Phase to Complete when all profiles done" {
                # Single profile, already at index 0
                $script:OrchestrationState.ProfileIndex = 0
                $script:OrchestrationState.Profiles = @($script:OrchestrationState.CurrentProfile)
                $script:OrchestrationState.StartTime = [datetime]::Now.AddMinutes(-5)

                Complete-CurrentProfile

                $script:OrchestrationState.Phase | Should -Be "Complete"
            }
        }

        Context "New-OperationResult" {
            It "Should create success result" {
                $result = New-OperationResult -Success $true -Data "TestData"

                $result.Success | Should -Be $true
                $result.Data | Should -Be "TestData"
                $result.ErrorMessage | Should -BeNullOrEmpty
            }

            It "Should create failure result with error message" {
                $result = New-OperationResult -Success $false -ErrorMessage "Something went wrong"

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Be "Something went wrong"
                $result.Data | Should -BeNullOrEmpty
            }

            It "Should include ErrorRecord when provided" {
                try {
                    throw "Test error"
                }
                catch {
                    $result = New-OperationResult -Success $false -ErrorMessage "Caught error" -ErrorRecord $_
                }

                $result.Success | Should -Be $false
                $result.ErrorRecord | Should -Not -BeNullOrEmpty
                $result.ErrorRecord.Exception.Message | Should -Be "Test error"
            }
        }

        Context "Health Check Functions" {
            BeforeEach {
                # Clear health check state
                $script:LastHealthCheckUpdate = $null
                # Use test-specific path
                $script:HealthCheckStatusFile = Join-Path $TestDrive "Robocurse-Health.json"
            }

            AfterEach {
                # Clean up
                if (Test-Path $script:HealthCheckStatusFile) {
                    Remove-Item $script:HealthCheckStatusFile -Force -ErrorAction SilentlyContinue
                }
            }

            It "Should write health status to file" {
                $script:OrchestrationState.Reset()
                $script:OrchestrationState.Phase = "Replicating"

                $result = Write-HealthCheckStatus -Force

                $result.Success | Should -Be $true
                Test-Path $script:HealthCheckStatusFile | Should -Be $true
            }

            It "Should include correct phase in health status" {
                $script:OrchestrationState.Reset()
                $script:OrchestrationState.Phase = "Replicating"

                Write-HealthCheckStatus -Force

                $status = Get-HealthCheckStatus

                $status | Should -Not -BeNullOrEmpty
                $status.Phase | Should -Be "Replicating"
            }

            It "Should respect interval when Force is not specified" {
                $script:OrchestrationState.Reset()

                Write-HealthCheckStatus -Force

                # Immediate second call should be skipped (interval not elapsed)
                $result = Write-HealthCheckStatus

                $result.Data | Should -Be "Skipped - interval not elapsed"
            }

            It "Should report healthy when no failures" {
                $script:OrchestrationState.Reset()
                $script:OrchestrationState.Phase = "Replicating"

                Write-HealthCheckStatus -Force
                $status = Get-HealthCheckStatus

                $status.Healthy | Should -Be $true
                $status.Message | Should -Be "OK"
            }

            It "Should report unhealthy when stopped" {
                $script:OrchestrationState.Reset()
                $script:OrchestrationState.Phase = "Stopped"

                Write-HealthCheckStatus -Force
                $status = Get-HealthCheckStatus

                $status.Healthy | Should -Be $false
                $status.Message | Should -Be "Replication stopped"
            }

            It "Remove-HealthCheckStatus should delete file" {
                $script:OrchestrationState.Reset()
                Write-HealthCheckStatus -Force

                Test-Path $script:HealthCheckStatusFile | Should -Be $true

                Remove-HealthCheckStatus

                Test-Path $script:HealthCheckStatusFile | Should -Be $false
            }

            It "Get-HealthCheckStatus should return null if file not exists" {
                $status = Get-HealthCheckStatus

                $status | Should -BeNullOrEmpty
            }
        }
    }
}
