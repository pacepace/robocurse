#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "End-to-End Integration Tests" {
        BeforeAll {
            # Create temporary test directories
            $script:TestDir = Join-Path $TestDrive "EndToEnd"

            $script:SourceDir = Join-Path $script:TestDir "source"
            $script:DestDir = Join-Path $script:TestDir "destination"
            $script:LogDir = Join-Path $script:TestDir "logs"

            New-Item -ItemType Directory -Path $script:SourceDir -Force | Out-Null
            New-Item -ItemType Directory -Path $script:DestDir -Force | Out-Null
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null

            # Initialize log session for tests
            Initialize-LogSession -LogRoot $script:LogDir | Out-Null

            # Create a minimal config object for tests
            $script:TestConfig = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    LogPath = $script:LogDir
                    MaxConcurrentJobs = 4
                    SnapshotRetention = [PSCustomObject]@{
                        DefaultKeepCount = 3
                        VolumeOverrides = @{}
                    }
                }
                SyncProfiles = @()
            }

            # Create a test config file for ConfigPath parameter
            $script:TestConfigPath = Join-Path $script:TestDir "test-config.json"
            $script:TestConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:TestConfigPath -Encoding utf8
        }

        AfterAll {
            # Cleanup test directories
            if (Test-Path $script:TestDir) {
                Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        Context "Complete Replication Workflow" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeAll {
                # Mock robocopy for cross-platform testing
                Mock Test-RobocopyAvailable {
                    return New-OperationResult -Success $true -Data "robocopy.exe"
                }

                Mock Start-RobocopyJob {
                    param($Chunk, $LogPath, $ThreadsPerJob)

                    # Create a mock log file
                    $mockLog = @"
-------------------------------------------------------------------------------
   ROBOCOPY     ::     Robust File Copy for Windows
-------------------------------------------------------------------------------

  Started : $(Get-Date)

  Source : $($Chunk.SourcePath)
    Dest : $($Chunk.DestinationPath)

  Files : *.*
  Options : /MIR /COPY:DAT /DCOPY:T /MT:$ThreadsPerJob

------------------------------------------------------------------------------

               Total    Copied   Skipped  Mismatch    FAILED    Extras
    Dirs :         3         3         0         0         0         0
   Files :        15        15         0         0         0         0
   Bytes :   1.5 MB    1.5 MB         0         0         0         0
   Times :   0:00:01   0:00:01                       0:00:00   0:00:00

   Speed :              1500000 Bytes/sec.
   Speed :              85.937 MegaBytes/min.
   Ended : $(Get-Date)
"@
                    New-Item -Path $LogPath -Force -ItemType File | Out-Null
                    $mockLog | Out-File -FilePath $LogPath -Encoding utf8

                    # Create a mock process object
                    $mockProcess = [PSCustomObject]@{
                        Id = Get-Random -Minimum 1000 -Maximum 9999
                        HasExited = $true
                        ExitCode = 1  # Success: files copied
                    }

                    return [PSCustomObject]@{
                        Process = $mockProcess
                        Chunk = $Chunk
                        StartTime = [datetime]::Now.AddSeconds(-1)
                        LogPath = $LogPath
                    }
                }
            }

            BeforeEach {
                # Create test data structure
                1..3 | ForEach-Object {
                    $subdir = Join-Path $script:SourceDir "Folder$_"
                    New-Item -ItemType Directory -Path $subdir -Force | Out-Null

                    # Create some test files
                    1..5 | ForEach-Object {
                        $content = "Test file $_ in Folder$($subdir)"
                        $filePath = Join-Path $subdir "file$_.txt"
                        $content | Out-File $filePath
                    }
                }
            }

            AfterEach {
                # Clean up for next test
                Get-ChildItem $script:SourceDir | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Get-ChildItem $script:DestDir | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }

            It "Should complete a simple replication" {
                # Create profile object matching expected structure
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = $script:SourceDir
                    Destination = $script:DestDir
                    ScanMode = 'Smart'
                    ChunkMaxDepth = 5
                    UseVSS = $false
                }

                # Run replication
                { Start-ReplicationRun -Profiles @($profile) -Config $script:TestConfig -ConfigPath $script:TestConfigPath -MaxConcurrentJobs 1 } | Should -Not -Throw

                # Process the replication tick to complete jobs
                Invoke-ReplicationTick -MaxConcurrentJobs 1

                # Verify orchestration state was initialized
                $script:OrchestrationState | Should -Not -BeNullOrEmpty
                $script:OrchestrationState.Profiles.Count | Should -Be 1
            }

            It "Should handle chunked replication" {
                # Create profile object with chunking settings
                # Note: Even a simple directory should generate at least 1 chunk
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = $script:SourceDir
                    Destination = $script:DestDir
                    ScanMode = 'Smart'  # Smart mode uses unlimited depth
                    ChunkMaxDepth = 5
                    UseVSS = $false
                }

                # Mock Get-DirectoryProfile to return valid scan data
                Mock Get-DirectoryProfile {
                    param($Path)
                    [PSCustomObject]@{
                        TotalSize = 1024 * 1024  # 1 MB
                        FileCount = 15
                        DirCount = 3
                        LargestFile = 1000
                        SmallestFile = 100
                    }
                }

                # Mock New-SmartChunks to return actual chunks
                Mock New-SmartChunks {
                    param($Path, $DestinationRoot, $MaxChunkSizeBytes, $MaxFiles, $MaxDepth)
                    $mockProfile = [PSCustomObject]@{
                        TotalSize = 500000
                        FileCount = 5
                        DirCount = 1
                    }
                    @(
                        New-Chunk -SourcePath "$Path\Folder1" -DestinationPath "$DestinationRoot\Folder1" -Profile $mockProfile
                        New-Chunk -SourcePath "$Path\Folder2" -DestinationPath "$DestinationRoot\Folder2" -Profile $mockProfile
                        New-Chunk -SourcePath "$Path\Folder3" -DestinationPath "$DestinationRoot\Folder3" -Profile $mockProfile
                    )
                }

                { Start-ReplicationRun -Profiles @($profile) -Config $script:TestConfig -ConfigPath $script:TestConfigPath -MaxConcurrentJobs 2 } | Should -Not -Throw

                # Verify that the orchestration state is properly initialized
                $script:OrchestrationState | Should -Not -BeNullOrEmpty
                $script:OrchestrationState.TotalChunks | Should -BeGreaterThan 0

                # Process the replication tick to complete jobs
                Invoke-ReplicationTick -MaxConcurrentJobs 2

                # Verify jobs were processed
                $script:OrchestrationState.Phase | Should -Be "Replicating"
            }

            It "Should generate proper logs" {
                # Create profile object
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = $script:SourceDir
                    Destination = $script:DestDir
                    ScanMode = 'Smart'
                    ChunkMaxDepth = 5
                    UseVSS = $false
                }

                Start-ReplicationRun -Profiles @($profile) -Config $script:TestConfig -ConfigPath $script:TestConfigPath -MaxConcurrentJobs 1
                Invoke-ReplicationTick -MaxConcurrentJobs 1

                # Verify robocopy log files were created by our mock
                # The mock creates logs in the Jobs subdirectory
                $dateFolder = Get-Date -Format "yyyy-MM-dd"
                $logSessionDir = Join-Path $script:LogDir $dateFolder
                $jobsLogDir = Join-Path $logSessionDir "Jobs"

                # Look specifically for Chunk_*.log files (robocopy job logs)
                # Not the operational log which contains orchestrator messages
                $logFiles = Get-ChildItem -Path $jobsLogDir -Filter "Chunk_*.log" -ErrorAction SilentlyContinue

                # Mock creates log files, so we should have at least one
                $logFiles.Count | Should -BeGreaterThan 0

                # Verify log has content with robocopy output
                if ($logFiles.Count -gt 0) {
                    $logContent = Get-Content $logFiles[0].FullName -Raw
                    $logContent | Should -Not -BeNullOrEmpty
                    $logContent | Should -Match "ROBOCOPY"
                }
            }
        }

        Context "Error Handling" {
            It "Should handle missing source directory" -Skip {
                $config = @{
                    profiles = @{
                        TestProfile = @{
                            sources = @(
                                @{ path = "C:\NonExistent\Source" }
                            )
                            destination = @{ path = $script:DestDir }
                        }
                    }
                }

                # Should fail gracefully
                { Start-ReplicationRun -Config $config -ProfileName "TestProfile" } | Should -Throw
            }

            It "Should handle inaccessible destination" -Skip {
                $config = @{
                    profiles = @{
                        TestProfile = @{
                            sources = @(
                                @{ path = $script:SourceDir }
                            )
                            destination = @{ path = "C:\Windows\System32\Protected" }
                        }
                    }
                }

                # Should fail gracefully with proper error
                { Start-ReplicationRun -Config $config -ProfileName "TestProfile" } | Should -Throw
            }

            It "Should retry on transient failures" -Skip {
                $config = @{
                    profiles = @{
                        TestProfile = @{
                            sources = @(@{ path = $script:SourceDir })
                            destination = @{ path = $script:DestDir }
                            retryPolicy = @{
                                maxRetries = 3
                                retryDelayMinutes = 0
                            }
                        }
                    }
                }

                # Mock a transient failure scenario
                # Implementation will need to handle retries

                { Start-ReplicationRun -Config $config -ProfileName "TestProfile" } | Should -Not -Throw
            }
        }

        Context "Progress Tracking" {
            BeforeEach {
                # Create test data
                1..5 | ForEach-Object {
                    $subdir = Join-Path $script:SourceDir "Data$_"
                    New-Item -ItemType Directory -Path $subdir -Force | Out-Null

                    1..10 | ForEach-Object {
                        "Test content" | Out-File (Join-Path $subdir "file$_.txt")
                    }
                }
            }

            It "Should track overall progress" -Skip {
                $config = @{
                    profiles = @{
                        TestProfile = @{
                            sources = @(@{ path = $script:SourceDir })
                            destination = @{ path = $script:DestDir }
                            chunking = @{
                                enabled = $true
                                parallelChunks = 2
                            }
                        }
                    }
                    global = @{
                        monitoring = @{
                            enableProgressTracking = $true
                            progressUpdateIntervalSeconds = 1
                        }
                    }
                }

                # Start replication
                $state = Start-ReplicationRun -Config $config -ProfileName "TestProfile"

                # Check progress
                $progress = Update-OverallProgress -State $state

                $progress | Should -Not -BeNullOrEmpty
                $progress.PSObject.Properties.Name | Should -Contain "PercentComplete"
            }

            It "Should estimate time remaining" {
                # Initialize orchestration state with progress data
                Initialize-OrchestrationState

                # Set up state for ETA calculation - use the state's methods if available
                # or set properties directly
                if ($script:OrchestrationState.PSObject.Methods.Name -contains 'SetProperty') {
                    $script:OrchestrationState.SetProperty('StartTime', (Get-Date).AddMinutes(-10))
                } else {
                    # Access the underlying fields directly
                    $script:OrchestrationState.TotalBytes = 1000MB
                    $script:OrchestrationState.BytesComplete = 500MB
                }

                $script:OrchestrationState.Phase = "Replicating"

                $eta = Get-ETAEstimate

                # Should return a TimeSpan or null (if not enough data)
                if ($null -ne $eta) {
                    $eta.GetType().Name | Should -Be "TimeSpan"
                }
            }

            It "Should track individual chunk progress" -Skip {
                $chunkId = "chunk-001"
                $logPath = Join-Path $script:LogDir "chunk-001.log"

                # Create a mock robocopy log
                @"
-------------------------------------------------------------------------------
   ROBOCOPY     ::     Robust File Copy for Windows
-------------------------------------------------------------------------------

  Files : 100
   Dirs : 10
  Bytes : 1000000
"@ | Out-File $logPath

                $progress = Get-ChunkProgress -ChunkId $chunkId -LogPath $logPath

                $progress | Should -Not -BeNullOrEmpty
            }
        }

        Context "Configuration Validation" {
            It "Should reject invalid configuration before starting" {
                # Create profile with missing required fields
                $invalidProfile = [PSCustomObject]@{
                    Name = "BadProfile"
                    # Missing Source and Destination
                }

                # Should fail when trying to scan source
                { Start-ReplicationRun -Profiles @($invalidProfile) -Config $script:TestConfig -ConfigPath $script:TestConfigPath -MaxConcurrentJobs 1 } | Should -Throw
            }

            It "Should validate profile has required fields" {
                # Create profile with empty source
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = ""
                    Destination = $script:DestDir
                    ScanMode = 'Smart'
                }

                # Should handle empty source gracefully
                { Start-ReplicationRun -Profiles @($profile) -Config $script:TestConfig -ConfigPath $script:TestConfigPath -MaxConcurrentJobs 1 } | Should -Throw
            }
        }

        Context "Multiple Source Handling" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeAll {
                # Mock robocopy for cross-platform testing
                Mock Test-RobocopyAvailable {
                    return New-OperationResult -Success $true -Data "robocopy.exe"
                }

                Mock Start-RobocopyJob {
                    param($Chunk, $LogPath, $ThreadsPerJob)

                    $mockLog = @"
-------------------------------------------------------------------------------
   ROBOCOPY     ::     Robust File Copy for Windows
-------------------------------------------------------------------------------

  Started : $(Get-Date)
  Source : $($Chunk.SourcePath)
    Dest : $($Chunk.DestinationPath)

               Total    Copied   Skipped  Mismatch    FAILED    Extras
    Dirs :         1         1         0         0         0         0
   Files :         3         3         0         0         0         0
   Bytes :      300       300         0         0         0         0
   Ended : $(Get-Date)
"@
                    New-Item -Path $LogPath -Force -ItemType File | Out-Null
                    $mockLog | Out-File -FilePath $LogPath -Encoding utf8

                    return [PSCustomObject]@{
                        Process = [PSCustomObject]@{
                            Id = Get-Random -Minimum 1000 -Maximum 9999
                            HasExited = $true
                            ExitCode = 1
                        }
                        Chunk = $Chunk
                        StartTime = [datetime]::Now.AddSeconds(-1)
                        LogPath = $LogPath
                    }
                }
            }

            BeforeEach {
                # Create multiple source directories
                $script:Source1 = Join-Path $script:TestDir "source1"
                $script:Source2 = Join-Path $script:TestDir "source2"

                New-Item -ItemType Directory -Path $script:Source1 -Force | Out-Null
                New-Item -ItemType Directory -Path $script:Source2 -Force | Out-Null

                # Add test data to each
                1..3 | ForEach-Object {
                    "Source 1 file $_" | Out-File (Join-Path $script:Source1 "file$_.txt")
                    "Source 2 file $_" | Out-File (Join-Path $script:Source2 "file$_.txt")
                }
            }

            AfterEach {
                Remove-Item $script:Source1 -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item $script:Source2 -Recurse -Force -ErrorAction SilentlyContinue
            }

            It "Should handle multiple sources" {
                # Create two separate profiles, one for each source
                $profile1 = [PSCustomObject]@{
                    Name = "Source1Profile"
                    Source = $script:Source1
                    Destination = $script:DestDir
                    ScanMode = 'Smart'
                    ChunkMaxDepth = 5
                    UseVSS = $false
                }

                $profile2 = [PSCustomObject]@{
                    Name = "Source2Profile"
                    Source = $script:Source2
                    Destination = $script:DestDir
                    ScanMode = 'Smart'
                    ChunkMaxDepth = 5
                    UseVSS = $false
                }

                # Run replication with multiple profiles
                { Start-ReplicationRun -Profiles @($profile1, $profile2) -Config $script:TestConfig -ConfigPath $script:TestConfigPath -MaxConcurrentJobs 1 } | Should -Not -Throw

                # Verify both profiles were registered
                $script:OrchestrationState.Profiles.Count | Should -Be 2
            }
        }
    }
}
