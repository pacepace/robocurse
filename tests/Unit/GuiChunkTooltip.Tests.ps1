#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "Chunk Error Tooltip Tests" {

        BeforeAll {
            # Initialize the C# OrchestrationState class
            Initialize-OrchestrationState
        }

        BeforeEach {
            # Create a fresh orchestration state
            Initialize-OrchestrationState
            # Mock logging to prevent error output in tests
            Mock Write-RobocurseLog { }
            Mock Write-SiemEvent { }
        }

        AfterEach {
            # Clean up
            $script:OrchestrationState = $null
        }

        Context "Invoke-FailedChunkHandler - Error Details Storage" {
            It "Should store LastExitCode on failed chunk" {
                # Create mock chunk
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Source\Test"
                    DestinationPath = "D:\Dest\Test"
                    Status = "Running"
                    RetryCount = 0
                }

                # Create mock job
                $mockProcess = [PSCustomObject]@{
                    Id = 1234
                    HasExited = $true
                    ExitCode = 8
                }
                $job = [PSCustomObject]@{
                    Chunk = $chunk
                    Process = $mockProcess
                }

                # Create mock result with error
                $result = [PSCustomObject]@{
                    ExitCode = 8
                    ExitMeaning = [PSCustomObject]@{
                        Message = "Some files or directories could not be copied"
                        Severity = "Error"
                        ShouldRetry = $false
                    }
                }

                # Invoke handler
                Invoke-FailedChunkHandler -Job $job -Result $result

                # Verify error details were stored
                $chunk.LastExitCode | Should -Be 8
                $chunk.LastErrorMessage | Should -Be "Some files or directories could not be copied"
            }

            It "Should store LastErrorMessage on failed chunk" {
                # Create mock chunk
                $chunk = [PSCustomObject]@{
                    ChunkId = 2
                    SourcePath = "C:\Source\Test2"
                    DestinationPath = "D:\Dest\Test2"
                    Status = "Running"
                    RetryCount = 0
                }

                # Create mock job
                $mockProcess = [PSCustomObject]@{
                    Id = 5678
                    HasExited = $true
                    ExitCode = 16
                }
                $job = [PSCustomObject]@{
                    Chunk = $chunk
                    Process = $mockProcess
                }

                # Create mock result with fatal error
                $result = [PSCustomObject]@{
                    ExitCode = 16
                    ExitMeaning = [PSCustomObject]@{
                        Message = "Serious error - robocopy did not copy any files"
                        Severity = "Fatal"
                        ShouldRetry = $false
                    }
                }

                # Invoke handler
                Invoke-FailedChunkHandler -Job $job -Result $result

                # Verify error message was stored
                $chunk.LastErrorMessage | Should -Be "Serious error - robocopy did not copy any files"
            }

            It "Should overwrite error details on retried chunk" {
                # Create mock chunk with existing error details
                $chunk = [PSCustomObject]@{
                    ChunkId = 3
                    SourcePath = "C:\Source\Test3"
                    DestinationPath = "D:\Dest\Test3"
                    Status = "Running"
                    RetryCount = 0
                    LastExitCode = 2
                    LastErrorMessage = "Old error message"
                }

                # Create mock job
                $mockProcess = [PSCustomObject]@{
                    Id = 9999
                    HasExited = $true
                    ExitCode = 8
                }
                $job = [PSCustomObject]@{
                    Chunk = $chunk
                    Process = $mockProcess
                }

                # Create mock result with new error
                $result = [PSCustomObject]@{
                    ExitCode = 8
                    ExitMeaning = [PSCustomObject]@{
                        Message = "New error message"
                        Severity = "Error"
                        ShouldRetry = $false
                    }
                }

                # Invoke handler
                Invoke-FailedChunkHandler -Job $job -Result $result

                # Verify error details were updated
                $chunk.LastExitCode | Should -Be 8
                $chunk.LastErrorMessage | Should -Be "New error message"
            }

            It "Should store DestinationPath on failed chunk" {
                # Create mock chunk
                $chunk = [PSCustomObject]@{
                    ChunkId = 4
                    SourcePath = "C:\Source\Test4"
                    DestinationPath = "D:\Dest\Test4"
                    Status = "Running"
                    RetryCount = 0
                }

                # Create mock job
                $mockProcess = [PSCustomObject]@{
                    Id = 1111
                    HasExited = $true
                    ExitCode = 8
                }
                $job = [PSCustomObject]@{
                    Chunk = $chunk
                    Process = $mockProcess
                }

                # Create mock result
                $result = [PSCustomObject]@{
                    ExitCode = 8
                    ExitMeaning = [PSCustomObject]@{
                        Message = "Test error"
                        Severity = "Error"
                        ShouldRetry = $false
                    }
                }

                # Invoke handler
                Invoke-FailedChunkHandler -Job $job -Result $result

                # Verify destination path was stored
                $chunk.DestinationPath | Should -Be "D:\Dest\Test4"
            }
        }

        Context "Get-ChunkDisplayItems - Failed Chunks with Error Details" {
            It "Should include error details for failed chunks" {
                # Create a failed chunk with error details
                $failedChunk = [PSCustomObject]@{
                    ChunkId = 10
                    SourcePath = "C:\Source\Failed"
                    DestinationPath = "D:\Dest\Failed"
                    Status = "Failed"
                    RetryCount = 3
                    LastExitCode = 8
                    LastErrorMessage = "Permission denied on some files"
                }

                # Add to failed chunks queue
                $script:OrchestrationState.FailedChunks.Enqueue($failedChunk)

                # Get display items
                $displayItems = Get-ChunkDisplayItems

                # Verify failed chunk is included with error details
                $displayItems | Should -HaveCount 1
                $displayItems[0].ChunkId | Should -Be 10
                $displayItems[0].Status | Should -Be "Failed"
                $displayItems[0].LastExitCode | Should -Be 8
                $displayItems[0].LastErrorMessage | Should -Be "Permission denied on some files"
                $displayItems[0].DestinationPath | Should -Be "D:\Dest\Failed"
            }

            It "Should handle failed chunks without error details gracefully" {
                # Create a failed chunk without error details (older chunk format)
                $failedChunk = [PSCustomObject]@{
                    ChunkId = 11
                    SourcePath = "C:\Source\OldFailed"
                    DestinationPath = "D:\Dest\OldFailed"
                    Status = "Failed"
                    RetryCount = 3
                }

                # Add to failed chunks queue
                $script:OrchestrationState.FailedChunks.Enqueue($failedChunk)

                # Get display items
                $displayItems = Get-ChunkDisplayItems

                # Verify failed chunk is included with null error details
                $displayItems | Should -HaveCount 1
                $displayItems[0].ChunkId | Should -Be 11
                $displayItems[0].Status | Should -Be "Failed"
                $displayItems[0].LastExitCode | Should -BeNullOrEmpty
                $displayItems[0].LastErrorMessage | Should -BeNullOrEmpty
            }

            It "Should include multiple failed chunks with their respective error details" {
                # Create multiple failed chunks
                $failedChunk1 = [PSCustomObject]@{
                    ChunkId = 20
                    SourcePath = "C:\Source\Failed1"
                    DestinationPath = "D:\Dest\Failed1"
                    Status = "Failed"
                    LastExitCode = 8
                    LastErrorMessage = "Error 1"
                }
                $failedChunk2 = [PSCustomObject]@{
                    ChunkId = 21
                    SourcePath = "C:\Source\Failed2"
                    DestinationPath = "D:\Dest\Failed2"
                    Status = "Failed"
                    LastExitCode = 16
                    LastErrorMessage = "Error 2"
                }

                # Add to failed chunks queue
                $script:OrchestrationState.FailedChunks.Enqueue($failedChunk1)
                $script:OrchestrationState.FailedChunks.Enqueue($failedChunk2)

                # Get display items
                $displayItems = Get-ChunkDisplayItems

                # Verify both chunks are included
                $displayItems | Should -HaveCount 2

                # Verify first chunk
                $chunk1Display = $displayItems | Where-Object { $_.ChunkId -eq 20 }
                $chunk1Display.LastExitCode | Should -Be 8
                $chunk1Display.LastErrorMessage | Should -Be "Error 1"

                # Verify second chunk
                $chunk2Display = $displayItems | Where-Object { $_.ChunkId -eq 21 }
                $chunk2Display.LastExitCode | Should -Be 16
                $chunk2Display.LastErrorMessage | Should -Be "Error 2"
            }
        }

        Context "Get-ChunkDisplayItems - Completed Chunks" {
            It "Should not include error details for completed chunks" {
                # Create a completed chunk
                $completedChunk = [PSCustomObject]@{
                    ChunkId = 30
                    SourcePath = "C:\Source\Complete"
                    DestinationPath = "D:\Dest\Complete"
                    Status = "Complete"
                    EstimatedSize = 1000000
                }

                # Add to completed chunks queue
                $script:OrchestrationState.CompletedChunks.Enqueue($completedChunk)

                # Get display items
                $displayItems = Get-ChunkDisplayItems

                # Verify completed chunk doesn't have error detail properties
                $displayItems | Should -HaveCount 1
                $displayItems[0].ChunkId | Should -Be 30
                $displayItems[0].Status | Should -Be "Complete"
                # Completed chunks should not have LastExitCode or LastErrorMessage properties
                $displayItems[0].PSObject.Properties['LastExitCode'] | Should -BeNullOrEmpty
                $displayItems[0].PSObject.Properties['LastErrorMessage'] | Should -BeNullOrEmpty
            }
        }

        Context "Integration - Complete Error Flow" {
            It "Should store and display error details through complete workflow" {
                # Create mock chunk
                $chunk = [PSCustomObject]@{
                    ChunkId = 100
                    SourcePath = "C:\Source\Integration"
                    DestinationPath = "D:\Dest\Integration"
                    Status = "Running"
                    RetryCount = 0
                }

                # Create mock job
                $mockProcess = [PSCustomObject]@{
                    Id = 8888
                    HasExited = $true
                    ExitCode = 8
                }
                $job = [PSCustomObject]@{
                    Chunk = $chunk
                    Process = $mockProcess
                }

                # Create mock result
                $result = [PSCustomObject]@{
                    ExitCode = 8
                    ExitMeaning = [PSCustomObject]@{
                        Message = "Integration test error"
                        Severity = "Error"
                        ShouldRetry = $false
                    }
                }

                # Process the failure
                Invoke-FailedChunkHandler -Job $job -Result $result

                # Verify chunk was added to failed queue
                $failedChunks = $script:OrchestrationState.FailedChunks.ToArray()
                $failedChunks | Should -HaveCount 1
                $failedChunks[0].ChunkId | Should -Be 100

                # Get display items
                $displayItems = Get-ChunkDisplayItems

                # Verify display item includes error details
                $displayItems | Should -HaveCount 1
                $displayItems[0].ChunkId | Should -Be 100
                $displayItems[0].Status | Should -Be "Failed"
                $displayItems[0].LastExitCode | Should -Be 8
                $displayItems[0].LastErrorMessage | Should -Be "Integration test error"
                $displayItems[0].SourcePath | Should -Be "C:\Source\Integration"
                $displayItems[0].DestinationPath | Should -Be "D:\Dest\Integration"
            }
        }
    }
}
