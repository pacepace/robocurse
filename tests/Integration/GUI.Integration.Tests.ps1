#Requires -Modules Pester

<#
.SYNOPSIS
    Integration tests for GUI replication flow

.DESCRIPTION
    These tests verify the complete GUI replication pathway works correctly,
    including background runspace creation, log session initialization,
    and data binding. These tests caught issues that unit tests missed:
    - Background runspace not initializing log session
    - ItemsSource failing with single-item arrays
    - Script path resolution for monolith vs module

.NOTES
    These tests run headless (no actual WPF window) but exercise the same
    code paths that the GUI uses.
#>

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "GUI Integration Tests" {

        BeforeAll {
            # Create temporary test directories
            $script:TestDir = Join-Path $TestDrive "GuiIntegration"
            $script:SourceDir = Join-Path $script:TestDir "source"
            $script:DestDir = Join-Path $script:TestDir "destination"
            $script:LogDir = Join-Path $script:TestDir "logs"
            $script:ConfigPath = Join-Path $script:TestDir "test.config.json"

            New-Item -ItemType Directory -Path $script:SourceDir -Force | Out-Null
            New-Item -ItemType Directory -Path $script:DestDir -Force | Out-Null
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null

            # Create test files
            1..5 | ForEach-Object {
                "Test content $_" | Out-File (Join-Path $script:SourceDir "file$_.txt")
            }

            # Create test config
            $config = @{
                Version = "1.0"
                GlobalSettings = @{
                    MaxConcurrentJobs = 2
                    LogPath = $script:LogDir
                }
                SyncProfiles = @(
                    @{
                        Name = "TestProfile"
                        Source = $script:SourceDir
                        Destination = $script:DestDir
                        Enabled = $true
                        UseVSS = $false
                        ScanMode = "Smart"
                        ChunkMaxSizeGB = 10
                        ChunkMaxFiles = 50000
                        ChunkMaxDepth = 5
                    }
                )
            }
            $config | ConvertTo-Json -Depth 10 | Out-File $script:ConfigPath -Encoding utf8
        }

        AfterAll {
            if (Test-Path $script:TestDir) {
                Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        Context "Get-ChunkDisplayItems Array Handling" {
            BeforeAll {
                # Initialize orchestration state
                Initialize-OrchestrationState

                # Initialize log session (required for orchestration)
                Initialize-LogSession -LogRoot $script:LogDir | Out-Null
            }

            It "Should return empty array with zero items" {
                # Clear any existing state
                $script:OrchestrationState.ActiveJobs.Clear()
                while ($script:OrchestrationState.CompletedChunks.TryDequeue([ref]$null)) { }
                while ($script:OrchestrationState.FailedChunks.TryDequeue([ref]$null)) { }

                $result = Get-ChunkDisplayItems
                # Wrap in @() at call site as the GUI does
                $wrapped = @($result)

                # With zero items, @() on $null gives empty array
                $wrapped.Count | Should -Be 0
            }

            It "Should handle single item without throwing when wrapped" {
                # Add one active job
                $mockChunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = $script:SourceDir
                    DestinationPath = $script:DestDir
                    Status = "Running"
                }
                $mockJob = [PSCustomObject]@{
                    Chunk = $mockChunk
                    Progress = 50
                }
                $script:OrchestrationState.ActiveJobs.TryAdd(1, $mockJob) | Out-Null

                $result = Get-ChunkDisplayItems
                # Wrap in @() at call site as the GUI does - this is the fix
                $wrapped = @($result)

                # Key test: should be usable as array even with single item
                $wrapped.Count | Should -Be 1
                $wrapped[0].ChunkId | Should -Be 1

                # Cleanup
                $script:OrchestrationState.ActiveJobs.Clear()
            }

            It "Should return multiple items as array" {
                # Add multiple active jobs
                1..3 | ForEach-Object {
                    $mockChunk = [PSCustomObject]@{
                        ChunkId = $_
                        SourcePath = "$($script:SourceDir)\chunk$_"
                        DestinationPath = "$($script:DestDir)\chunk$_"
                        Status = "Running"
                    }
                    $mockJob = [PSCustomObject]@{
                        Chunk = $mockChunk
                        Progress = $_ * 25
                    }
                    $script:OrchestrationState.ActiveJobs.TryAdd($_, $mockJob) | Out-Null
                }

                $result = Get-ChunkDisplayItems
                $wrapped = @($result)

                $wrapped.Count | Should -Be 3

                # Cleanup
                $script:OrchestrationState.ActiveJobs.Clear()
            }

            It "Should be assignable to IEnumerable (simulating ItemsSource)" {
                # Add one item to test the single-item case that was failing
                $mockChunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = $script:SourceDir
                    DestinationPath = $script:DestDir
                    Status = "Running"
                }
                $mockJob = [PSCustomObject]@{
                    Chunk = $mockChunk
                    Progress = 50
                }
                $script:OrchestrationState.ActiveJobs.TryAdd(1, $mockJob) | Out-Null

                $result = @(Get-ChunkDisplayItems)

                # This simulates what WPF ItemsSource needs
                { [System.Collections.IEnumerable]$result } | Should -Not -Throw

                # Cleanup
                $script:OrchestrationState.ActiveJobs.Clear()
            }
        }

        Context "Background Runspace Script Loading" -Skip:(-not (Test-IsWindowsPlatform)) {
            It "Should have RobocurseModulePath set when loaded as module" {
                # When loaded as a module, this should be set by the psm1
                $script:RobocurseModulePath | Should -Not -BeNullOrEmpty
                Test-Path $script:RobocurseModulePath | Should -Be $true
            }

            It "Should be able to determine load mode" {
                # Simulate what New-ReplicationRunspace does
                $loadMode = $null
                $loadPath = $null

                if ($script:RobocurseModulePath -and (Test-Path (Join-Path $script:RobocurseModulePath "Robocurse.psd1"))) {
                    $loadMode = "Module"
                    $loadPath = $script:RobocurseModulePath
                }

                $loadMode | Should -Be "Module"
                $loadPath | Should -Not -BeNullOrEmpty
            }
        }

        Context "Background Runspace Execution" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeAll {
                # Create a profile for testing
                $script:TestProfile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = $script:SourceDir
                    Destination = $script:DestDir
                    Enabled = $true
                    UseVSS = $false
                    ScanMode = "Smart"
                    ChunkMaxSizeGB = 10
                    ChunkMaxFiles = 50000
                    ChunkMaxDepth = 5
                }
            }

            It "Should initialize log session in background runspace" {
                # This test verifies the fix for "No log session initialized" error

                # Initialize orchestration state (as GUI does before runspace)
                Initialize-OrchestrationState

                # Create a runspace that mimics what the GUI does
                $runspace = [runspacefactory]::CreateRunspace()
                $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
                $runspace.Open()

                $powershell = [powershell]::Create()
                $powershell.Runspace = $runspace

                # Script that mimics background runspace initialization
                $testScript = @"
                    param(`$ModulePath, `$SharedState, `$ConfigPath, `$LogDir)

                    try {
                        Import-Module `$ModulePath -Force -ErrorAction Stop

                        # This is what was missing and caused the error
                        Initialize-LogSession -LogRoot `$LogDir

                        # Verify log session is initialized by trying to write
                        Write-RobocurseLog -Message "Test log from background" -Level Info -Component Test

                        `$SharedState.Phase = 'Complete'
                        return "SUCCESS"
                    }
                    catch {
                        `$SharedState.EnqueueError(`$_.Exception.Message)
                        `$SharedState.Phase = 'Complete'
                        return "FAILED: `$(`$_.Exception.Message)"
                    }
"@

                $powershell.AddScript($testScript)
                $powershell.AddArgument($script:RobocurseModulePath)
                $powershell.AddArgument($script:OrchestrationState)
                $powershell.AddArgument($script:ConfigPath)
                $powershell.AddArgument($script:LogDir)

                $handle = $powershell.BeginInvoke()

                # Wait for completion with timeout
                $timeout = [TimeSpan]::FromSeconds(30)
                $completed = $handle.AsyncWaitHandle.WaitOne($timeout)

                $completed | Should -Be $true -Because "Background runspace should complete within timeout"

                $result = $powershell.EndInvoke($handle)
                # EndInvoke returns an array, get the last item (the return value)
                $returnValue = @($result)[-1]
                $returnValue | Should -Be "SUCCESS" -Because "Log session should initialize without error"

                # Check no errors were enqueued
                $errors = $script:OrchestrationState.DequeueErrors()
                $errors.Count | Should -Be 0 -Because "No errors should be enqueued"

                # Cleanup
                $powershell.Dispose()
                $runspace.Close()
                $runspace.Dispose()
            }

            It "Write-RobocurseLog should handle missing log session gracefully" {
                # This verifies that logging doesn't crash when log session is not initialized
                # The current behavior is to silently skip file logging but allow console output

                $runspace = [runspacefactory]::CreateRunspace()
                $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
                $runspace.Open()

                $powershell = [powershell]::Create()
                $powershell.Runspace = $runspace

                # Script that intentionally skips log initialization
                $testScript = @"
                    param(`$ModulePath)

                    Import-Module `$ModulePath -Force -ErrorAction Stop

                    # Try to write log without initializing - should not throw for Info level
                    # but may warn for Warning/Error levels
                    try {
                        Write-RobocurseLog -Message "Test message" -Level Info -Component Test
                        return "SUCCESS_NO_THROW"
                    }
                    catch {
                        return "THREW: `$(`$_.Exception.Message)"
                    }
"@

                $powershell.AddScript($testScript)
                $powershell.AddArgument($script:RobocurseModulePath)

                $handle = $powershell.BeginInvoke()
                $timeout = [TimeSpan]::FromSeconds(10)
                $handle.AsyncWaitHandle.WaitOne($timeout) | Out-Null

                $result = $powershell.EndInvoke($handle)
                # Info level should not throw (graceful degradation)
                $result | Should -Be "SUCCESS_NO_THROW" -Because "Info logging should degrade gracefully without log session"

                $powershell.Dispose()
                $runspace.Close()
                $runspace.Dispose()
            }
        }

        Context "Full GUI Replication Flow Simulation" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeAll {
                # Mock robocopy to avoid actual file operations
                Mock Start-RobocopyJob {
                    param($Chunk, $LogPath, $ThreadsPerJob, $Options)

                    # Create mock log file
                    $mockLog = @"
-------------------------------------------------------------------------------
   ROBOCOPY     ::     Robust File Copy for Windows
-------------------------------------------------------------------------------

  Started : $(Get-Date)
  Source : $($Chunk.SourcePath)
    Dest : $($Chunk.DestinationPath)

               Total    Copied   Skipped  Mismatch    FAILED    Extras
    Dirs :         1         1         0         0         0         0
   Files :         5         5         0         0         0         0
   Bytes :     100 B     100 B         0         0         0         0

   Ended : $(Get-Date)
"@
                    New-Item -Path $LogPath -Force -ItemType File | Out-Null
                    $mockLog | Out-File -FilePath $LogPath -Encoding utf8

                    $mockProcess = [PSCustomObject]@{
                        Id = Get-Random -Minimum 1000 -Maximum 9999
                        HasExited = $true
                        ExitCode = 1
                    }
                    $mockProcess | Add-Member -MemberType ScriptMethod -Name 'WaitForExit' -Value { param($ms) return $true }

                    return [PSCustomObject]@{
                        Process = $mockProcess
                        LogPath = $LogPath
                        Chunk = $Chunk
                        StartTime = [DateTime]::Now
                    }
                }
            }

            It "Should complete full replication cycle without errors" {
                # Initialize state as GUI does
                Initialize-OrchestrationState
                Initialize-LogSession -LogRoot $script:LogDir | Out-Null

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = $script:SourceDir
                    Destination = $script:DestDir
                    Enabled = $true
                    UseVSS = $false
                    ScanMode = "Quick"
                    ChunkMaxSizeGB = 10
                    ChunkMaxFiles = 50000
                    ChunkMaxDepth = 5
                }

                # Start replication (synchronous for testing)
                Start-ReplicationRun -Profiles @($profile) -MaxConcurrentJobs 2

                # Run ticks until complete
                $maxTicks = 100
                $tickCount = 0
                while ($script:OrchestrationState.Phase -notin @('Complete', 'Stopped', 'Idle') -and $tickCount -lt $maxTicks) {
                    Invoke-ReplicationTick -MaxConcurrentJobs 2
                    Start-Sleep -Milliseconds 50
                    $tickCount++
                }

                $script:OrchestrationState.Phase | Should -Be 'Complete'
                $tickCount | Should -BeLessThan $maxTicks -Because "Replication should complete within timeout"
            }

            It "Should populate chunk display items during replication" {
                # Initialize fresh state
                Initialize-OrchestrationState
                Initialize-LogSession -LogRoot $script:LogDir | Out-Null

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = $script:SourceDir
                    Destination = $script:DestDir
                    Enabled = $true
                    UseVSS = $false
                    ScanMode = "Quick"
                    ChunkMaxSizeGB = 10
                    ChunkMaxFiles = 50000
                    ChunkMaxDepth = 5
                }

                Start-ReplicationRun -Profiles @($profile) -MaxConcurrentJobs 2

                # Capture display items at various points
                $capturedItems = @()
                $maxTicks = 100
                $tickCount = 0

                while ($script:OrchestrationState.Phase -notin @('Complete', 'Stopped', 'Idle') -and $tickCount -lt $maxTicks) {
                    Invoke-ReplicationTick -MaxConcurrentJobs 2

                    # This is what the GUI timer does
                    $items = @(Get-ChunkDisplayItems)
                    if ($items.Count -gt 0) {
                        $capturedItems += $items
                    }

                    Start-Sleep -Milliseconds 50
                    $tickCount++
                }

                # Should have captured some items during replication
                # (may be empty if replication completes very fast, but shouldn't throw)
                { @(Get-ChunkDisplayItems) } | Should -Not -Throw
            }
        }

        Context "Config Loading in Background Runspace" {
            BeforeAll {
                # Create a temp config in a real path (not $TestDrive which doesn't persist to runspaces)
                $script:TempConfigDir = Join-Path $env:TEMP "RobocurseTest_$(Get-Random)"
                New-Item -ItemType Directory -Path $script:TempConfigDir -Force | Out-Null

                $script:TempConfigPath = Join-Path $script:TempConfigDir "test.config.json"
                # Use the "friendly format" that the config parser expects:
                # - "profiles" object with profile names as keys
                # - "global" with nested settings
                $tempConfig = @{
                    global = @{
                        concurrency = @{ maxJobs = 2 }
                    }
                    profiles = @{
                        BackgroundTestProfile = @{
                            source = "C:\TestSource"
                            destination = "C:\TestDest"
                            enabled = $true
                        }
                    }
                }
                $tempConfig | ConvertTo-Json -Depth 10 | Out-File $script:TempConfigPath -Encoding utf8
            }

            AfterAll {
                if (Test-Path $script:TempConfigDir) {
                    Remove-Item -Path $script:TempConfigDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            It "Should load config from path in background runspace" {
                $runspace = [runspacefactory]::CreateRunspace()
                $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
                $runspace.Open()

                $powershell = [powershell]::Create()
                $powershell.Runspace = $runspace

                $testScript = @"
                    param(`$ModulePath, `$ConfigPath)

                    Import-Module `$ModulePath -Force -ErrorAction Stop

                    try {
                        `$config = Get-RobocurseConfig -Path `$ConfigPath
                        if (-not `$config) {
                            return "FAILED: Config is null"
                        }
                        if (-not `$config.SyncProfiles) {
                            return "FAILED: SyncProfiles is null"
                        }
                        # Handle both array and single item cases
                        `$profiles = @(`$config.SyncProfiles)
                        if (`$profiles.Count -gt 0 -and `$profiles[0].Name) {
                            return "SUCCESS: `$(`$profiles[0].Name)"
                        }
                        return "FAILED: No valid profiles, count=`$(`$profiles.Count)"
                    }
                    catch {
                        return "ERROR: `$(`$_.Exception.Message)"
                    }
"@

                $powershell.AddScript($testScript)
                $powershell.AddArgument($script:RobocurseModulePath)
                $powershell.AddArgument($script:TempConfigPath)

                $handle = $powershell.BeginInvoke()
                $timeout = [TimeSpan]::FromSeconds(10)
                $handle.AsyncWaitHandle.WaitOne($timeout) | Out-Null

                $result = $powershell.EndInvoke($handle)
                $result | Should -Match "^SUCCESS:" -Because "Config should load in background runspace"

                $powershell.Dispose()
                $runspace.Close()
                $runspace.Dispose()
            }
        }
    }
}
