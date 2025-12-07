#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "GUI Chunk Actions Tests" {

        BeforeAll {
            # Load WPF assemblies for MessageBox tests
            Add-Type -AssemblyName PresentationCore, PresentationFramework
        }

        BeforeEach {
            # Initialize fresh orchestration state
            Initialize-OrchestrationState
            # Mock logging to prevent output in tests
            Mock Write-RobocurseLog { }
            Mock Write-GuiLog { }
            Mock Write-SiemEvent { }
            # Mock dialog to prevent UI popups in tests
            Mock Show-AlertDialog { }
        }

        AfterEach {
            # Clean up
            $script:OrchestrationState = $null
        }

        Context "Invoke-ChunkRetry" {
            It "Should move failed chunk back to chunk queue" {
                # Create a failed chunk
                $chunk = [PSCustomObject]@{
                    ChunkId = 42
                    SourcePath = "C:\Source\Test"
                    DestinationPath = "D:\Dest\Test"
                    Status = "Failed"
                    RetryCount = 2
                    LastExitCode = 8
                    LastErrorMessage = "Some files could not be copied"
                }

                # Add to failed chunks
                $script:OrchestrationState.FailedChunks.Enqueue($chunk)

                # Verify chunk is in failed queue
                $script:OrchestrationState.FailedChunks.Count | Should -Be 1

                # Retry the chunk
                Invoke-ChunkRetry -ChunkId 42

                # Verify chunk was removed from failed queue
                $script:OrchestrationState.FailedChunks.Count | Should -Be 0

                # Verify chunk was added to chunk queue
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 1

                # Verify chunk state was reset
                $queuedChunk = $null
                $script:OrchestrationState.ChunkQueue.TryDequeue([ref]$queuedChunk) | Should -Be $true
                $queuedChunk.ChunkId | Should -Be 42
                $queuedChunk.Status | Should -Be 'Pending'
                $queuedChunk.RetryCount | Should -Be 0
                # Error details should be removed
                $queuedChunk.PSObject.Properties['LastExitCode'] | Should -BeNullOrEmpty
                $queuedChunk.PSObject.Properties['LastErrorMessage'] | Should -BeNullOrEmpty
            }

            It "Should preserve other failed chunks when retrying one" {
                # Create multiple failed chunks
                $chunk1 = [PSCustomObject]@{
                    ChunkId = 10
                    SourcePath = "C:\Source\Test1"
                    DestinationPath = "D:\Dest\Test1"
                    Status = "Failed"
                    RetryCount = 1
                }
                $chunk2 = [PSCustomObject]@{
                    ChunkId = 20
                    SourcePath = "C:\Source\Test2"
                    DestinationPath = "D:\Dest\Test2"
                    Status = "Failed"
                    RetryCount = 2
                }
                $chunk3 = [PSCustomObject]@{
                    ChunkId = 30
                    SourcePath = "C:\Source\Test3"
                    DestinationPath = "D:\Dest\Test3"
                    Status = "Failed"
                    RetryCount = 3
                }

                # Add all to failed chunks
                $script:OrchestrationState.FailedChunks.Enqueue($chunk1)
                $script:OrchestrationState.FailedChunks.Enqueue($chunk2)
                $script:OrchestrationState.FailedChunks.Enqueue($chunk3)

                # Retry chunk 20
                Invoke-ChunkRetry -ChunkId 20

                # Verify failed queue still has 2 chunks (10 and 30)
                $script:OrchestrationState.FailedChunks.Count | Should -Be 2
                $remainingIds = $script:OrchestrationState.FailedChunks.ToArray() | ForEach-Object { $_.ChunkId }
                $remainingIds | Should -Contain 10
                $remainingIds | Should -Contain 30
                $remainingIds | Should -Not -Contain 20

                # Verify chunk queue has the retried chunk
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 1
                $queuedChunk = $null
                $script:OrchestrationState.ChunkQueue.TryDequeue([ref]$queuedChunk) | Should -Be $true
                $queuedChunk.ChunkId | Should -Be 20
            }

            It "Should handle retry when chunk not found" {
                # No chunks in failed queue
                $script:OrchestrationState.FailedChunks.Count | Should -Be 0

                # Attempt to retry non-existent chunk (should not throw)
                { Invoke-ChunkRetry -ChunkId 999 } | Should -Not -Throw

                # Verify logging was called (mocked)
                Should -Invoke Write-GuiLog -Times 1 -ParameterFilter {
                    $Message -like "*not found*"
                }
            }

            It "Should handle retry when orchestration state is null" {
                # Clear orchestration state
                $script:OrchestrationState = $null

                # Attempt retry (should not throw)
                { Invoke-ChunkRetry -ChunkId 42 } | Should -Not -Throw

                # Verify logging was called
                Should -Invoke Write-GuiLog -Times 1 -ParameterFilter {
                    $Message -like "*No orchestration state*"
                }
            }

            It "Should log retry action" {
                # Create a failed chunk
                $chunk = [PSCustomObject]@{
                    ChunkId = 100
                    SourcePath = "C:\Source\LogTest"
                    DestinationPath = "D:\Dest\LogTest"
                    Status = "Failed"
                    RetryCount = 1
                }
                $script:OrchestrationState.FailedChunks.Enqueue($chunk)

                # Retry the chunk
                Invoke-ChunkRetry -ChunkId 100

                # Verify logging calls
                Should -Invoke Write-GuiLog -Times 1 -ParameterFilter {
                    $Message -like "*moved from failed to pending*"
                }
                Should -Invoke Write-RobocurseLog -Times 1 -ParameterFilter {
                    $Level -eq 'Info' -and $Message -like "*retry*"
                }
                Should -Invoke Write-SiemEvent -Times 1 -ParameterFilter {
                    $EventType -eq 'ChunkWarning' -and $Data.Action -eq 'UserRetry'
                }
            }
        }

        Context "Invoke-ChunkSkip" {
            It "Should remove failed chunk and mark as skipped" {
                # Create a failed chunk
                $chunk = [PSCustomObject]@{
                    ChunkId = 50
                    SourcePath = "C:\Source\Skip"
                    DestinationPath = "D:\Dest\Skip"
                    Status = "Failed"
                    RetryCount = 3
                    LastExitCode = 16
                    LastErrorMessage = "Fatal error"
                }

                # Add to failed chunks
                $script:OrchestrationState.FailedChunks.Enqueue($chunk)

                # Skip the chunk
                Invoke-ChunkSkip -ChunkId 50

                # Verify chunk was removed from failed queue
                $script:OrchestrationState.FailedChunks.Count | Should -Be 0

                # Verify chunk status was set to Skipped
                $chunk.Status | Should -Be 'Skipped'
            }

            It "Should preserve other failed chunks when skipping one" {
                # Create multiple failed chunks
                $chunk1 = [PSCustomObject]@{
                    ChunkId = 11
                    SourcePath = "C:\Source\Test1"
                    DestinationPath = "D:\Dest\Test1"
                    Status = "Failed"
                    RetryCount = 1
                }
                $chunk2 = [PSCustomObject]@{
                    ChunkId = 22
                    SourcePath = "C:\Source\Test2"
                    DestinationPath = "D:\Dest\Test2"
                    Status = "Failed"
                    RetryCount = 2
                }

                # Add to failed chunks
                $script:OrchestrationState.FailedChunks.Enqueue($chunk1)
                $script:OrchestrationState.FailedChunks.Enqueue($chunk2)

                # Skip chunk 11
                Invoke-ChunkSkip -ChunkId 11

                # Verify failed queue still has 1 chunk (22)
                $script:OrchestrationState.FailedChunks.Count | Should -Be 1
                $remainingChunk = $script:OrchestrationState.FailedChunks.ToArray()[0]
                $remainingChunk.ChunkId | Should -Be 22
            }

            It "Should handle skip when chunk not found" {
                # No chunks in failed queue
                $script:OrchestrationState.FailedChunks.Count | Should -Be 0

                # Attempt to skip non-existent chunk (should not throw)
                { Invoke-ChunkSkip -ChunkId 999 } | Should -Not -Throw

                # Verify logging was called
                Should -Invoke Write-GuiLog -Times 1 -ParameterFilter {
                    $Message -like "*not found*"
                }
            }

            It "Should handle skip when orchestration state is null" {
                # Clear orchestration state
                $script:OrchestrationState = $null

                # Attempt skip (should not throw)
                { Invoke-ChunkSkip -ChunkId 50 } | Should -Not -Throw

                # Verify logging was called
                Should -Invoke Write-GuiLog -Times 1 -ParameterFilter {
                    $Message -like "*No orchestration state*"
                }
            }

            It "Should log skip action" {
                # Create a failed chunk
                $chunk = [PSCustomObject]@{
                    ChunkId = 200
                    SourcePath = "C:\Source\SkipLog"
                    DestinationPath = "D:\Dest\SkipLog"
                    Status = "Failed"
                    RetryCount = 2
                }
                $script:OrchestrationState.FailedChunks.Enqueue($chunk)

                # Skip the chunk
                Invoke-ChunkSkip -ChunkId 200

                # Verify logging calls
                Should -Invoke Write-GuiLog -Times 1 -ParameterFilter {
                    $Message -like "*removed from failed*"
                }
                Should -Invoke Write-RobocurseLog -Times 1 -ParameterFilter {
                    $Level -eq 'Info' -and $Message -like "*skipped*"
                }
                Should -Invoke Write-SiemEvent -Times 1 -ParameterFilter {
                    $EventType -eq 'ChunkWarning' -and $Data.Action -eq 'UserSkip'
                }
            }
        }

        Context "Open-ChunkLog" {
            It "Should open log file when it exists" {
                # Create a temp log file
                $tempLog = Join-Path $TestDrive "chunk_001.log"
                "Test log content" | Set-Content -Path $tempLog

                # Mock Start-Process
                Mock Start-Process { }

                # Open the log
                Open-ChunkLog -LogPath $tempLog

                # Verify Start-Process was called with correct path
                Should -Invoke Start-Process -Times 1 -ParameterFilter {
                    $FilePath -eq $tempLog
                }

                # Verify logging
                Should -Invoke Write-GuiLog -Times 1 -ParameterFilter {
                    $Message -like "*Opened chunk log*"
                }
            }

            It "Should show error when log path is empty" {
                # Try to open with empty path (should not throw)
                { Open-ChunkLog -LogPath "" } | Should -Not -Throw

                # Verify error was logged
                Should -Invoke Write-GuiLog -Times 1 -ParameterFilter {
                    $Message -like "*Log path is empty*"
                }
            }

            It "Should show error when log file does not exist" {
                # Try to open non-existent file (should not throw)
                { Open-ChunkLog -LogPath "C:\NonExistent\chunk.log" } | Should -Not -Throw

                # Verify error was logged
                Should -Invoke Write-GuiLog -Times 1 -ParameterFilter {
                    $Message -like "*File not found*"
                }
            }

            It "Should handle Start-Process failure gracefully" {
                # Create a temp log file
                $tempLog = Join-Path $TestDrive "chunk_error.log"
                "Test log" | Set-Content -Path $tempLog

                # Mock Start-Process to throw
                Mock Start-Process { throw "Access denied" }

                # Try to open (should not throw)
                { Open-ChunkLog -LogPath $tempLog } | Should -Not -Throw

                # Verify error was logged
                Should -Invoke Write-GuiLog -Times 1 -ParameterFilter {
                    $Message -like "*Failed to open*"
                }
            }

            It "Should log debug message when opening log" {
                # Create a temp log file
                $tempLog = Join-Path $TestDrive "chunk_debug.log"
                "Debug test" | Set-Content -Path $tempLog

                # Mock Start-Process
                Mock Start-Process { }

                # Open the log
                Open-ChunkLog -LogPath $tempLog

                # Verify debug logging
                Should -Invoke Write-RobocurseLog -Times 1 -ParameterFilter {
                    $Level -eq 'Debug' -and $Message -like "*opened chunk log*"
                }
            }
        }

        Context "Integration - Complete Workflow" {
            It "Should support retry, fail again, then skip workflow" {
                # Create a failed chunk
                $chunk = [PSCustomObject]@{
                    ChunkId = 999
                    SourcePath = "C:\Source\Integration"
                    DestinationPath = "D:\Dest\Integration"
                    Status = "Failed"
                    RetryCount = 1
                    LastExitCode = 8
                    LastErrorMessage = "Integration test error"
                }

                # Add to failed chunks
                $script:OrchestrationState.FailedChunks.Enqueue($chunk)

                # Step 1: Retry the chunk
                Invoke-ChunkRetry -ChunkId 999
                $script:OrchestrationState.FailedChunks.Count | Should -Be 0
                $script:OrchestrationState.ChunkQueue.Count | Should -Be 1

                # Simulate chunk failing again
                $retriedChunk = $null
                $script:OrchestrationState.ChunkQueue.TryDequeue([ref]$retriedChunk) | Should -Be $true
                $retriedChunk.Status = 'Failed'
                $retriedChunk.RetryCount = 2
                $retriedChunk | Add-Member -NotePropertyName 'LastExitCode' -NotePropertyValue 8 -Force
                $retriedChunk | Add-Member -NotePropertyName 'LastErrorMessage' -NotePropertyValue 'Still failing' -Force
                $script:OrchestrationState.FailedChunks.Enqueue($retriedChunk)

                # Step 2: Skip the chunk
                Invoke-ChunkSkip -ChunkId 999
                $script:OrchestrationState.FailedChunks.Count | Should -Be 0
                $retriedChunk.Status | Should -Be 'Skipped'
            }
        }
    }
}
