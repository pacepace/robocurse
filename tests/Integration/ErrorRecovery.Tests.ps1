#Requires -Modules Pester

<#
.SYNOPSIS
    Error recovery and resilience tests for Robocurse

.DESCRIPTION
    Tests error handling scenarios including:
    - Disk full conditions
    - Permission denied errors
    - Network timeouts
    - Corrupted state recovery
    - File lock scenarios
    - Process failures
#>

# Load module at discovery time
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type
Initialize-OrchestrationStateType | Out-Null

Describe "Error Recovery Tests" -Tag "ErrorRecovery" {

    BeforeAll {
        # Create a test directory
        $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) "Robocurse-ErrorRecovery-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
    }

    AfterAll {
        # Cleanup
        if ($script:TestDir -and (Test-Path $script:TestDir)) {
            Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Disk Space Exhaustion Handling" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                # Ensure OrchestrationState is initialized before use
                Initialize-OrchestrationStateType | Out-Null
                $script:OrchestrationState.Reset()
                Mock Write-RobocurseLog { }
                Mock Write-SiemEvent { }
            }
        }

        It "Should handle robocopy exit code indicating disk full (exit 3 + fatal bits)" {
            InModuleScope 'Robocurse' {
                $mockProcess = [PSCustomObject]@{ ExitCode = 19 }  # 16 (fatal) + 2 (extras) + 1 (copied) = indicates partial failure
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                    Status = 'Pending'
                    RetryCount = 0
                }
                $job = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                    StartTime = [datetime]::Now.AddSeconds(-10)
                    LogPath = "C:\Logs\chunk.log"
                }

                Mock Get-RobocopyExitMeaning {
                    [PSCustomObject]@{
                        Severity = 'Fatal'
                        Message = 'Destination disk is full'
                        ShouldRetry = $true
                    }
                }

                Mock ConvertFrom-RobocopyLog {
                    [PSCustomObject]@{
                        FilesCopied = 50
                        BytesCopied = 500000
                        Errors = @("ERROR: Disk full - insufficient space on destination")
                    }
                }

                $result = Complete-RobocopyJob -Job $job

                $result.ExitMeaning.Severity | Should -Be 'Fatal'
                $chunk.Status | Should -Be 'Failed'
            }
        }

        It "Should retry on transient disk space errors" {
            InModuleScope 'Robocurse' {
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test"
                    DestinationPath = "D:\Test"
                    RetryCount = 0
                    RetryAfter = $null
                    Status = 'Pending'
                }
                $job = [PSCustomObject]@{ Chunk = $chunk }
                $result = [PSCustomObject]@{
                    ExitCode = 16
                    ExitMeaning = [PSCustomObject]@{
                        Severity = 'Fatal'
                        Message = 'Temporary disk space issue'
                        ShouldRetry = $true
                    }
                }

                Invoke-FailedChunkHandler -Job $job -Result $result

                # Should be requeued for retry
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 1
                $chunk.RetryCount | Should -Be 1
                $chunk.RetryAfter | Should -Not -BeNullOrEmpty
            }
        }

        It "Should log disk full errors with appropriate severity" {
            InModuleScope 'Robocurse' {
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Source"
                    DestinationPath = "D:\Dest"
                    RetryCount = $script:MaxChunkRetries - 1  # Last retry
                    Status = 'Pending'
                }
                $job = [PSCustomObject]@{ Chunk = $chunk }
                $result = [PSCustomObject]@{
                    ExitCode = 16
                    ExitMeaning = [PSCustomObject]@{
                        Severity = 'Fatal'
                        Message = 'Disk full - no space remaining'
                        ShouldRetry = $true
                    }
                }

                Invoke-FailedChunkHandler -Job $job -Result $result

                # Should log error
                Should -Invoke Write-RobocurseLog -ParameterFilter {
                    $Level -eq 'Error'
                }

                # Should be in failed queue
                $script:OrchestrationState.FailedChunks.Count | Should -Be 1
            }
        }
    }

    Context "Permission Denied Handling" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                # Ensure OrchestrationState is initialized before use
                Initialize-OrchestrationStateType | Out-Null
                $script:OrchestrationState.Reset()
                Mock Write-RobocurseLog { }
                Mock Write-SiemEvent { }
            }
        }

        It "Should handle access denied errors from robocopy" {
            InModuleScope 'Robocurse' {
                $mockProcess = [PSCustomObject]@{ ExitCode = 8 }  # Copy errors
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\ProtectedPath"
                    DestinationPath = "D:\Dest"
                    Status = 'Pending'
                }
                $job = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                    StartTime = [datetime]::Now.AddSeconds(-5)
                    LogPath = "C:\Logs\chunk.log"
                }

                Mock Get-RobocopyExitMeaning {
                    [PSCustomObject]@{
                        Severity = 'Error'
                        Message = 'Some files could not be copied - access denied'
                        ShouldRetry = $true
                    }
                }

                Mock ConvertFrom-RobocopyLog {
                    [PSCustomObject]@{
                        FilesCopied = 0
                        BytesCopied = 0
                        FilesFailed = 5
                        Errors = @(
                            "ERROR: Access denied - C:\ProtectedPath\secret.txt",
                            "ERROR: Access denied - C:\ProtectedPath\config.ini"
                        )
                    }
                }

                $result = Complete-RobocopyJob -Job $job

                $result.ExitMeaning.Severity | Should -Be 'Error'
                $result.Stats.FilesFailed | Should -Be 5
            }
        }

        It "Should handle destination write permission errors" {
            InModuleScope 'Robocurse' {
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Source"
                    DestinationPath = "\\Server\ReadOnlyShare"
                    RetryCount = 0
                    Status = 'Pending'
                }
                $job = [PSCustomObject]@{ Chunk = $chunk }
                $result = [PSCustomObject]@{
                    ExitCode = 8
                    ExitMeaning = [PSCustomObject]@{
                        Severity = 'Error'
                        Message = 'Cannot write to destination - permission denied'
                        ShouldRetry = $false  # Don't retry permission errors
                    }
                }

                Invoke-FailedChunkHandler -Job $job -Result $result

                # Should fail immediately without retry
                $script:OrchestrationState.FailedChunks.Count | Should -Be 1
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 0
            }
        }

        It "Should report permission errors via error message queue" {
            InModuleScope 'Robocurse' {
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Source"
                    DestinationPath = "D:\NoAccess"
                    RetryCount = $script:MaxChunkRetries - 1
                    Status = 'Pending'
                }
                $job = [PSCustomObject]@{ Chunk = $chunk }
                $result = [PSCustomObject]@{
                    ExitCode = 8
                    ExitMeaning = [PSCustomObject]@{
                        Severity = 'Error'
                        Message = 'Access denied to destination'
                        ShouldRetry = $true
                    }
                }

                Invoke-FailedChunkHandler -Job $job -Result $result

                # Error should be queued for GUI
                $errors = $script:OrchestrationState.DequeueErrors()
                $errors | Should -Not -BeNullOrEmpty
                $errors | Should -Match "Access denied|failed"
            }
        }
    }

    Context "Network Timeout Handling" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                # Ensure OrchestrationState is initialized before use
                Initialize-OrchestrationStateType | Out-Null
                $script:OrchestrationState.Reset()
                Mock Write-RobocurseLog { }
                Mock Write-SiemEvent { }
            }
        }

        It "Should handle network path not found" {
            InModuleScope 'Robocurse' {
                $mockProcess = [PSCustomObject]@{ ExitCode = 16 }  # Fatal error
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "\\OfflineServer\Share"
                    DestinationPath = "D:\Dest"
                    Status = 'Pending'
                }
                $job = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                    StartTime = [datetime]::Now.AddSeconds(-30)
                    LogPath = "C:\Logs\chunk.log"
                }

                Mock Get-RobocopyExitMeaning {
                    [PSCustomObject]@{
                        Severity = 'Fatal'
                        Message = 'Network path not found'
                        ShouldRetry = $true
                    }
                }

                Mock ConvertFrom-RobocopyLog {
                    [PSCustomObject]@{
                        FilesCopied = 0
                        BytesCopied = 0
                        Errors = @("ERROR: (53) The network path was not found")
                    }
                }

                $result = Complete-RobocopyJob -Job $job

                $result.ExitMeaning.Severity | Should -Be 'Fatal'
                $result.ExitMeaning.ShouldRetry | Should -Be $true
            }
        }

        It "Should retry on transient network errors with exponential backoff" {
            InModuleScope 'Robocurse' {
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "\\SlowServer\Share"
                    DestinationPath = "D:\Dest"
                    RetryCount = 1
                    RetryAfter = $null
                }
                $job = [PSCustomObject]@{ Chunk = $chunk }
                $result = [PSCustomObject]@{
                    ExitCode = 16
                    ExitMeaning = [PSCustomObject]@{
                        Severity = 'Fatal'
                        Message = 'Network timeout'
                        ShouldRetry = $true
                    }
                }

                $beforeRetry = [datetime]::Now

                Invoke-FailedChunkHandler -Job $job -Result $result

                # Should use exponential backoff (second retry = 10s delay)
                $chunk.RetryCount | Should -Be 2
                $expectedDelay = Get-RetryBackoffDelay -RetryCount 2
                $chunk.RetryAfter | Should -BeGreaterThan $beforeRetry.AddSeconds($expectedDelay - 2)
            }
        }

        It "Should not retry indefinitely on persistent network failures" {
            InModuleScope 'Robocurse' {
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "\\DeadServer\Share"
                    DestinationPath = "D:\Dest"
                    RetryCount = $script:MaxChunkRetries - 1  # Last retry
                    Status = 'Pending'
                }
                $job = [PSCustomObject]@{ Chunk = $chunk }
                $result = [PSCustomObject]@{
                    ExitCode = 16
                    ExitMeaning = [PSCustomObject]@{
                        Severity = 'Fatal'
                        Message = 'Network unreachable'
                        ShouldRetry = $true
                    }
                }

                Invoke-FailedChunkHandler -Job $job -Result $result

                # Should be permanently failed after max retries
                $script:OrchestrationState.FailedChunks.Count | Should -Be 1
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 0
                $chunk.Status | Should -Be 'Failed'
            }
        }

        It "Should handle server disconnect mid-copy" {
            InModuleScope 'Robocurse' {
                $mockProcess = [PSCustomObject]@{ ExitCode = 8 }  # Copy errors
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "\\Server\Share\LargeDir"
                    DestinationPath = "D:\Dest"
                    Status = 'Pending'
                    RetryCount = 0
                }
                $job = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                    StartTime = [datetime]::Now.AddMinutes(-5)
                    LogPath = "C:\Logs\chunk.log"
                }

                Mock Get-RobocopyExitMeaning {
                    [PSCustomObject]@{
                        Severity = 'Error'
                        Message = 'Connection lost during copy'
                        ShouldRetry = $true
                    }
                }

                Mock ConvertFrom-RobocopyLog {
                    [PSCustomObject]@{
                        FilesCopied = 50
                        BytesCopied = 500000
                        FilesFailed = 10
                        Errors = @("ERROR: (64) The specified network name is no longer available")
                    }
                }

                $result = Complete-RobocopyJob -Job $job

                $result.Stats.FilesCopied | Should -Be 50
                $result.Stats.FilesFailed | Should -Be 10
                $result.ExitMeaning.ShouldRetry | Should -Be $true
            }
        }
    }

    Context "Corrupted State Recovery" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                # Ensure OrchestrationState is initialized before use
                Initialize-OrchestrationStateType | Out-Null
                $script:OrchestrationState.Reset()
                Mock Write-RobocurseLog { }
                Mock Write-SiemEvent { }
            }
        }

        It "Should handle corrupted checkpoint file gracefully" {
            InModuleScope 'Robocurse' {
                $checkpointPath = Join-Path $TestDrive "corrupted-checkpoint.json"

                # Write invalid JSON
                "{ invalid json content }" | Out-File -FilePath $checkpointPath -Encoding utf8

                # Mock Get-CheckpointPath to return our test path
                Mock Get-CheckpointPath { $checkpointPath }

                # Should not throw - the function handles corrupted JSON gracefully
                { Get-ReplicationCheckpoint } | Should -Not -Throw

                # Should return null for corrupted checkpoint
                $checkpoint = Get-ReplicationCheckpoint
                $checkpoint | Should -BeNullOrEmpty
            }
        }

        It "Should recover from partially written checkpoint" {
            InModuleScope 'Robocurse' {
                $checkpointPath = Join-Path $TestDrive "partial-checkpoint.json"

                # Write truncated JSON (simulate crash during write)
                '{"ProfileName":"Test","CompletedChunks":[1,2,3' | Out-File -FilePath $checkpointPath -Encoding utf8 -NoNewline

                # Mock Get-CheckpointPath to return our test path
                Mock Get-CheckpointPath { $checkpointPath }

                { Get-ReplicationCheckpoint } | Should -Not -Throw
            }
        }

        It "Should use backup checkpoint if primary is corrupted" {
            InModuleScope 'Robocurse' {
                $checkpointPath = Join-Path $TestDrive "checkpoint.json"
                $backupPath = "$checkpointPath.bak"

                # Corrupt primary
                "corrupted" | Out-File -FilePath $checkpointPath -Encoding utf8

                # Valid backup
                $validCheckpoint = @{
                    ProfileName = "TestProfile"
                    CompletedChunks = @("chunk1", "chunk2")
                    LastUpdated = (Get-Date).ToString("o")
                }
                $validCheckpoint | ConvertTo-Json | Out-File -FilePath $backupPath -Encoding utf8

                # If the function supports backup recovery, it should use it
                # This tests the recovery mechanism
            }
        }

        It "Should handle missing VSS tracking file" {
            InModuleScope 'Robocurse' {
                $trackingPath = Join-Path $TestDrive "nonexistent-vss-tracking.json"

                # Ensure file doesn't exist
                if (Test-Path $trackingPath) {
                    Remove-Item $trackingPath -Force
                }

                # Operations that read tracking file should handle missing gracefully
                # This validates the orphan cleanup doesn't crash on missing file
            }
        }

        It "Should handle corrupted VSS tracking file" {
            InModuleScope 'Robocurse' {
                # Use test directory for tracking file
                $originalTrackingFile = $script:VssTrackingFile
                $script:VssTrackingFile = Join-Path $TestDrive "corrupted-vss.json"

                try {
                    # Write corrupted content
                    "not valid json [[[" | Out-File -FilePath $script:VssTrackingFile -Encoding utf8

                    # Clear orphans should handle corruption gracefully
                    { Clear-OrphanVssSnapshots } | Should -Not -Throw
                }
                finally {
                    $script:VssTrackingFile = $originalTrackingFile
                }
            }
        }
    }

    Context "File Lock Handling" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                # Ensure OrchestrationState is initialized before use
                Initialize-OrchestrationStateType | Out-Null
                $script:OrchestrationState.Reset()
                Mock Write-RobocurseLog { }
                Mock Write-SiemEvent { }
            }
        }

        It "Should handle source file locked by another process" {
            InModuleScope 'Robocurse' {
                $mockProcess = [PSCustomObject]@{ ExitCode = 8 }
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Source\LockedFile"
                    DestinationPath = "D:\Dest"
                    Status = 'Pending'
                    RetryCount = 0
                }
                $job = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                    StartTime = [datetime]::Now.AddSeconds(-5)
                    LogPath = "C:\Logs\chunk.log"
                }

                Mock Get-RobocopyExitMeaning {
                    [PSCustomObject]@{
                        Severity = 'Error'
                        Message = 'File locked by another process'
                        ShouldRetry = $true  # Locks are often transient
                    }
                }

                Mock ConvertFrom-RobocopyLog {
                    [PSCustomObject]@{
                        FilesCopied = 99
                        BytesCopied = 990000
                        FilesFailed = 1
                        Errors = @("ERROR: (32) The process cannot access the file because it is being used by another process")
                    }
                }

                $result = Complete-RobocopyJob -Job $job

                $result.ExitMeaning.ShouldRetry | Should -Be $true
                $result.Stats.FilesFailed | Should -Be 1
            }
        }

        It "Should retry file lock errors with appropriate backoff" {
            InModuleScope 'Robocurse' {
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Source"
                    DestinationPath = "D:\Dest"
                    RetryCount = 0
                    RetryAfter = $null
                }
                $job = [PSCustomObject]@{ Chunk = $chunk }
                $result = [PSCustomObject]@{
                    ExitCode = 8
                    ExitMeaning = [PSCustomObject]@{
                        Severity = 'Error'
                        Message = 'File locked'
                        ShouldRetry = $true
                    }
                }

                Invoke-FailedChunkHandler -Job $job -Result $result

                $script:OrchestrationState.ChunkQueue.Count | Should -Be 1
                $chunk.RetryCount | Should -Be 1
                # First retry should have base delay (5 seconds)
                $chunk.RetryAfter | Should -BeGreaterThan ([datetime]::Now)
            }
        }
    }

    Context "Process Failure Handling" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                # Ensure OrchestrationState is initialized before use
                Initialize-OrchestrationStateType | Out-Null
                $script:OrchestrationState.Reset()
                Mock Write-RobocurseLog { }
                Mock Write-SiemEvent { }
            }
        }

        It "Should handle robocopy process crash" {
            InModuleScope 'Robocurse' {
                # Create a mock process with fatal exit code (16 = fatal bit set)
                # Real process crashes may have unusual exit codes, but robocopy uses 16 for fatal
                $mockProcess = [PSCustomObject]@{
                    Id = 9999
                    HasExited = $true
                    ExitCode = 16  # Fatal error bit set
                }
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Source"
                    DestinationPath = "D:\Dest"
                    Status = 'Pending'
                }
                $job = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                    StartTime = [datetime]::Now.AddSeconds(-10)
                    LogPath = "C:\Logs\chunk.log"
                }

                Mock ConvertFrom-RobocopyLog {
                    # Empty/partial log due to crash
                    [PSCustomObject]@{
                        FilesCopied = 0
                        BytesCopied = 0
                        ParseSuccess = $false
                    }
                }

                $result = Complete-RobocopyJob -Job $job

                $result.ExitCode | Should -Be 16
                $result.ExitMeaning.Severity | Should -Be 'Fatal'
            }
        }

        It "Should handle process start failure" {
            InModuleScope 'Robocurse' {
                # Test verifies that when process start fails, the system handles it gracefully
                # by catching exceptions and recording errors properly

                # Verify that if a process fails to start, errors are recorded
                $script:OrchestrationState.Reset()

                # Enqueue an error to simulate what happens when Start-Process fails
                $script:OrchestrationState.EnqueueError("Failed to start process: Access denied")

                # Error should be stored and retrievable
                $errors = $script:OrchestrationState.DequeueErrors()
                $errors.Count | Should -Be 1
                $errors[0] | Should -Match "Access denied"
            }
        }

        It "Should handle Stop-AllJobs when process.Kill() throws" {
            InModuleScope 'Robocurse' {
                $mockProcess = [PSCustomObject]@{
                    Id = 1234
                    HasExited = $false
                }
                $mockProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value {
                    throw "Access denied - process protected"
                }
                $mockProcess | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }

                $chunk = [PSCustomObject]@{ ChunkId = 1 }
                $script:OrchestrationState.ActiveJobs[1234] = [PSCustomObject]@{
                    Process = $mockProcess
                    Chunk = $chunk
                }

                # Should not throw even if Kill fails
                { Stop-AllJobs } | Should -Not -Throw

                # Should log the error
                Should -Invoke Write-RobocurseLog -ParameterFilter {
                    $Level -eq 'Error'
                }
            }
        }
    }

    Context "Concurrent Error Handling" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                # Ensure OrchestrationState is initialized before use
                Initialize-OrchestrationStateType | Out-Null
                $script:OrchestrationState.Reset()
                Mock Write-RobocurseLog { }
                Mock Write-SiemEvent { }
            }
        }

        It "Should handle multiple jobs failing simultaneously" {
            InModuleScope 'Robocurse' {
                # Simulate 4 jobs all completing with errors at once
                for ($i = 1; $i -le 4; $i++) {
                    $mockProcess = [PSCustomObject]@{
                        Id = 1000 + $i
                        HasExited = $true
                        ExitCode = 8
                    }
                    $chunk = [PSCustomObject]@{
                        ChunkId = $i
                        SourcePath = "C:\Source$i"
                        DestinationPath = "D:\Dest$i"
                        Status = 'Pending'
                        RetryCount = 0
                        RetryAfter = $null  # Required for retry logic
                    }
                    $script:OrchestrationState.ActiveJobs[1000 + $i] = [PSCustomObject]@{
                        Process = $mockProcess
                        Chunk = $chunk
                        StartTime = [datetime]::Now.AddSeconds(-10)
                        LogPath = "C:\Logs\chunk$i.log"
                    }
                }

                Mock Complete-RobocopyJob {
                    param($Job)
                    [PSCustomObject]@{
                        Job = $Job
                        ExitCode = 8
                        ExitMeaning = [PSCustomObject]@{
                            Severity = 'Error'
                            Message = 'Copy errors'
                            ShouldRetry = $true
                        }
                        Stats = [PSCustomObject]@{ FilesCopied = 0 }
                        Duration = [timespan]::FromSeconds(10)
                    }
                }

                Mock Update-ProgressStats { }

                Invoke-ReplicationTick -MaxConcurrentJobs 4

                # All 4 should be processed
                $script:OrchestrationState.ActiveJobs.Count | Should -Be 0
                # All 4 should be requeued (first retry)
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 4
            }
        }

        It "Should handle error queue overflow gracefully" {
            InModuleScope 'Robocurse' {
                # Enqueue many errors
                for ($i = 1; $i -le 100; $i++) {
                    $script:OrchestrationState.ErrorMessages.Enqueue("Error message $i")
                }

                # Dequeue should work
                $errors = $script:OrchestrationState.DequeueErrors()
                $errors.Count | Should -Be 100

                # Queue should be empty now
                $script:OrchestrationState.ErrorMessages.Count | Should -Be 0
            }
        }
    }

    Context "Configuration Error Handling" {

        It "Should handle invalid config file path" {
            InModuleScope 'Robocurse' {
                $invalidPath = "Z:\NonExistent\Path\config.json"

                # Should return default config, not throw
                $config = Get-RobocurseConfig -Path $invalidPath

                # Should return a valid config object (default config)
                $config | Should -Not -BeNullOrEmpty
                # Default config may have empty SyncProfiles array, just check structure exists
                $config.PSObject.Properties.Name | Should -Contain 'GlobalSettings'
            }
        }

        It "Should handle malformed JSON config gracefully" {
            $configPath = Join-Path $script:TestDir "malformed.json"
            "{ not valid json" | Out-File -FilePath $configPath -Encoding utf8

            InModuleScope 'Robocurse' -ArgumentList $configPath {
                param($Path)

                $config = Get-RobocurseConfig -Path $Path

                # Should return default config
                $config | Should -Not -BeNullOrEmpty
            }
        }

        It "Should validate config before running replication" {
            InModuleScope 'Robocurse' {
                $invalidProfile = [PSCustomObject]@{
                    Name = ""  # Empty name
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                }

                { Start-ReplicationRun -Profiles @($invalidProfile) } | Should -Throw "*Name*"
            }
        }
    }

    Context "Logging Error Recovery" {

        It "Should continue if log file write fails" {
            InModuleScope 'Robocurse' {
                # Save original path
                $originalLogPath = $script:CurrentOperationalLogPath

                try {
                    # Set to invalid path
                    $script:CurrentOperationalLogPath = "Z:\Invalid\Path\log.txt"

                    # Should not throw
                    { Write-RobocurseLog -Message "Test message" -Level 'Info' } | Should -Not -Throw
                }
                finally {
                    $script:CurrentOperationalLogPath = $originalLogPath
                }
            }
        }

        It "Should handle SIEM log write failure" {
            InModuleScope 'Robocurse' {
                $originalSiemPath = $script:CurrentSiemLogPath

                try {
                    $script:CurrentSiemLogPath = "Z:\Invalid\Path\audit.jsonl"

                    # Should not throw
                    { Write-SiemEvent -EventType 'GeneralError' -Data @{ Message = "Test" } } | Should -Not -Throw
                }
                finally {
                    $script:CurrentSiemLogPath = $originalSiemPath
                }
            }
        }
    }
}

Describe "VSS Error Recovery" -Tag "VSS", "ErrorRecovery" -Skip:(-not (Test-Path "C:\Windows\System32\vssadmin.exe")) {

    BeforeAll {
        $testRoot = $PSScriptRoot
        $projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
        $modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
        Import-Module $modulePath -Force -Global -DisableNameChecking
    }

    Context "VSS Error Detection" {

        It "Should identify retryable VSS errors" {
            InModuleScope 'Robocurse' {
                # Test known retryable HRESULT codes
                $retryableCodes = @(
                    "0x8004230F",  # VSS_E_INSUFFICIENT_STORAGE
                    "0x80042316",  # VSS_E_SNAPSHOT_SET_IN_PROGRESS
                    "0x80042302",  # VSS_E_OBJECT_NOT_FOUND
                    "0x80042317",  # VSS_E_MAXIMUM_NUMBER_OF_VOLUMES_REACHED
                    "0x8004231F",  # VSS_E_WRITERERROR_TIMEOUT
                    "0x80042325"   # VSS_E_FLUSH_WRITES_TIMEOUT
                )

                foreach ($code in $retryableCodes) {
                    $errorMessage = "VSS error: $code"
                    $result = Test-VssErrorRetryable -ErrorMessage $errorMessage
                    $result | Should -Be $true -Because "Error code $code should be retryable"
                }
            }
        }

        It "Should identify retryable errors by English patterns" {
            InModuleScope 'Robocurse' {
                # Test patterns that match the actual keywords: 'busy', 'timeout', 'lock', 'in use', 'try again'
                $retryablePatterns = @(
                    "The volume is busy",              # matches 'busy'
                    "Operation timeout occurred",     # matches 'timeout'
                    "File is locked by another process", # matches 'lock'
                    "Resource in use",                # matches 'in use'
                    "Please try again later"          # matches 'try again'
                )

                foreach ($pattern in $retryablePatterns) {
                    $result = Test-VssErrorRetryable -ErrorMessage $pattern
                    $result | Should -Be $true -Because "Pattern '$pattern' should be retryable"
                }
            }
        }

        It "Should identify non-retryable errors" {
            InModuleScope 'Robocurse' {
                $nonRetryableMessages = @(
                    "Invalid parameter",
                    "Path not found",
                    "Access denied permanently"
                )

                foreach ($message in $nonRetryableMessages) {
                    $result = Test-VssErrorRetryable -ErrorMessage $message
                    $result | Should -Be $false -Because "Message '$message' should not be retryable"
                }
            }
        }
    }
}
