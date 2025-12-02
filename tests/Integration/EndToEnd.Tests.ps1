BeforeAll {
    # Load the main script - it auto-detects dot-sourcing and skips main execution
    $mainScriptPath = Join-Path $PSScriptRoot ".." ".." "Robocurse.ps1"
    . $mainScriptPath -Help

    # Create temporary test directories using TestDrive or system temp
    $tempBase = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { "/tmp" }
    $script:TestDir = Join-Path $tempBase "RobocurseTests_E2E_$(Get-Random)"
    New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null

    $script:SourceDir = Join-Path $script:TestDir "source"
    $script:DestDir = Join-Path $script:TestDir "destination"
    $script:LogDir = Join-Path $script:TestDir "logs"

    New-Item -ItemType Directory -Path $script:SourceDir -Force | Out-Null
    New-Item -ItemType Directory -Path $script:DestDir -Force | Out-Null
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null

    # Initialize log session for tests
    Initialize-LogSession -LogRoot $script:LogDir | Out-Null

    # Mock Test-RobocopyAvailable for cross-platform testing (robocopy is Windows-only)
    Mock -ModuleName $null Test-RobocopyAvailable {
        return New-OperationResult -Success $true -Data "robocopy.exe"
    }

    # Mock Start-RobocopyJob for cross-platform testing
    Mock -ModuleName $null Start-RobocopyJob {
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

AfterAll {
    # Cleanup test directories
    if (Test-Path $script:TestDir) {
        Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "End-to-End Integration Tests" {
    Context "Complete Replication Workflow" {
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
                ChunkMaxSizeGB = 10
                ChunkMaxFiles = 50000
                ChunkMaxDepth = 5
                UseVSS = $false
            }

            # Run replication
            { Start-ReplicationRun -Profiles @($profile) -MaxConcurrentJobs 1 } | Should -Not -Throw

            # Process the replication tick to complete jobs
            Invoke-ReplicationTick -MaxConcurrentJobs 1

            # Verify orchestration state was initialized
            $script:OrchestrationState | Should -Not -BeNullOrEmpty
            $script:OrchestrationState.Profiles.Count | Should -Be 1
        }

        It "Should handle chunked replication" {
            # Create profile object with chunking settings
            $profile = [PSCustomObject]@{
                Name = "TestProfile"
                Source = $script:SourceDir
                Destination = $script:DestDir
                ScanMode = 'Smart'  # Smart mode respects folder structure
                ChunkMaxSizeGB = 10
                ChunkMaxFiles = 50000
                ChunkMaxDepth = 5
                UseVSS = $false
            }

            { Start-ReplicationRun -Profiles @($profile) -MaxConcurrentJobs 2 } | Should -Not -Throw

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
                ChunkMaxSizeGB = 10
                UseVSS = $false
            }

            Start-ReplicationRun -Profiles @($profile) -MaxConcurrentJobs 1
            Invoke-ReplicationTick -MaxConcurrentJobs 1

            # Verify robocopy log files were created by our mock
            # The mock creates logs in the path returned by Get-LogPath
            # which uses the initialized log session directory
            $dateFolder = Get-Date -Format "yyyy-MM-dd"
            $logSessionDir = Join-Path $script:LogDir $dateFolder

            $logFiles = Get-ChildItem -Path $logSessionDir -Filter "*.log" -Recurse -ErrorAction SilentlyContinue

            # Mock creates log files, so we should have at least one
            $logFiles.Count | Should -BeGreaterThan 0

            # Verify log has content
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
            $script:OrchestrationState.StartTime = (Get-Date).AddMinutes(-10)
            $script:OrchestrationState.TotalBytes = 1000MB
            $script:OrchestrationState.BytesComplete = 500MB
            $script:OrchestrationState.Phase = "Replicating"

            $eta = Get-ETAEstimate

            # Should return a TimeSpan
            $eta | Should -Not -BeNullOrEmpty
            $eta.GetType().Name | Should -Be "TimeSpan"
            # Should be approximately 10 minutes (since we're 50% done after 10 minutes)
            $eta.TotalMinutes | Should -BeGreaterThan 5
            $eta.TotalMinutes | Should -BeLessThan 15
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
            { Start-ReplicationRun -Profiles @($invalidProfile) -MaxConcurrentJobs 1 } | Should -Throw
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
            { Start-ReplicationRun -Profiles @($profile) -MaxConcurrentJobs 1 } | Should -Throw
        }
    }

    Context "Multiple Source Handling" {
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
                ChunkMaxSizeGB = 10
                UseVSS = $false
            }

            $profile2 = [PSCustomObject]@{
                Name = "Source2Profile"
                Source = $script:Source2
                Destination = $script:DestDir
                ScanMode = 'Smart'
                ChunkMaxSizeGB = 10
                UseVSS = $false
            }

            # Run replication with multiple profiles
            { Start-ReplicationRun -Profiles @($profile1, $profile2) -MaxConcurrentJobs 1 } | Should -Not -Throw

            # Verify both profiles were registered
            $script:OrchestrationState.Profiles.Count | Should -Be 2
        }
    }
}
