#Requires -Modules Pester

BeforeAll {
    # Load the main script in non-interactive mode
    . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
}

Describe "Orchestration" {
    BeforeEach {
        # Reset state before each test
        $script:OrchestrationState = [PSCustomObject]@{
            SessionId        = ""
            CurrentProfile   = $null
            Phase            = "Idle"
            Profiles         = @()
            ProfileIndex     = 0

            ChunkQueue       = [System.Collections.Generic.Queue[PSCustomObject]]::new()
            ActiveJobs       = [System.Collections.Generic.Dictionary[int,PSCustomObject]]::new()
            CompletedChunks  = [System.Collections.Generic.List[PSCustomObject]]::new()
            FailedChunks     = [System.Collections.Generic.List[PSCustomObject]]::new()

            TotalChunks      = 0
            CompletedCount   = 0
            TotalBytes       = 0
            BytesComplete    = 0
            StartTime        = $null
            ProfileStartTime = $null

            StopRequested    = $false
            PauseRequested   = $false
        }

        # Clear callbacks
        $script:OnProgress = $null
        $script:OnChunkComplete = $null
        $script:OnProfileComplete = $null

        # Mock logging functions to prevent actual file writes
        Mock Write-RobocurseLog { }
        Mock Write-SiemEvent { }
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
            $callbackInvoked = $false
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

    Context "Handle-FailedChunk" {
        It "Should retry failed chunk up to 3 times" {
            $chunk = [PSCustomObject]@{
                ChunkId = 1
                SourcePath = "C:\Test"
                DestinationPath = "D:\Test"
                RetryCount = 0
            }
            $job = [PSCustomObject]@{ Chunk = $chunk }
            $result = [PSCustomObject]@{
                ExitCode = 8
                ExitMeaning = [PSCustomObject]@{
                    Severity = 'Error'
                    ShouldRetry = $true
                }
            }

            Handle-FailedChunk -Job $job -Result $result

            $script:OrchestrationState.ChunkQueue.Count | Should -Be 1
            $chunk.RetryCount | Should -Be 1
            $script:OrchestrationState.FailedChunks.Count | Should -Be 0
        }

        It "Should retry chunk on second failure" {
            $chunk = [PSCustomObject]@{
                ChunkId = 1
                SourcePath = "C:\Test"
                DestinationPath = "D:\Test"
                RetryCount = 1
            }
            $job = [PSCustomObject]@{ Chunk = $chunk }
            $result = [PSCustomObject]@{
                ExitCode = 8
                ExitMeaning = [PSCustomObject]@{
                    Severity = 'Error'
                    ShouldRetry = $true
                }
            }

            Handle-FailedChunk -Job $job -Result $result

            $script:OrchestrationState.ChunkQueue.Count | Should -Be 1
            $chunk.RetryCount | Should -Be 2
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

            Handle-FailedChunk -Job $job -Result $result

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

            Handle-FailedChunk -Job $job -Result $result

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
            $chunk1 = [PSCustomObject]@{
                ChunkId = 1
                EstimatedSize = 1000000
            }
            $chunk2 = [PSCustomObject]@{
                ChunkId = 2
                EstimatedSize = 2000000
            }
            $script:OrchestrationState.CompletedChunks.Add($chunk1)
            $script:OrchestrationState.CompletedChunks.Add($chunk2)

            Mock Get-RobocopyProgress { }

            Update-ProgressStats

            $script:OrchestrationState.BytesComplete | Should -Be 3000000
        }

        It "Should include bytes from active jobs" {
            $chunk1 = [PSCustomObject]@{
                ChunkId = 1
                EstimatedSize = 1000000
            }
            $script:OrchestrationState.CompletedChunks.Add($chunk1)

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

            Mock Parse-RobocopyLog {
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

            Mock Parse-RobocopyLog {
                [PSCustomObject]@{
                    FilesCopied = 50
                    BytesCopied = 500000
                }
            }

            $result = Complete-RobocopyJob -Job $job

            $chunk.Status | Should -Be 'Failed'
        }
    }
}
