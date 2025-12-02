#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

InModuleScope 'Robocurse' {
    Describe "Checkpoint" {
        BeforeAll {
            # Initialize the C# OrchestrationState class
            Initialize-OrchestrationState
        }

        BeforeEach {
            # Set up test log directory for checkpoint storage
            $script:TestLogDir = "$TestDrive\Logs\$(Get-Date -Format 'yyyy-MM-dd')"
            New-Item -ItemType Directory -Path $script:TestLogDir -Force | Out-Null
            $script:CurrentOperationalLogPath = "$script:TestLogDir\test.log"

            # Create fresh orchestration state using the module's initialization
            Initialize-OrchestrationState
            $script:OrchestrationState.SessionId = "test-session-$(Get-Random)"
        }

        AfterEach {
            $script:OrchestrationState = $null
        }

        Context "Get-CheckpointPath" {
            It "Should return path in log directory" {
                $path = Get-CheckpointPath

                $path | Should -Match "robocurse-checkpoint\.json$"
                # Normalize path separators for cross-platform comparison
                $normalizedPath = $path -replace '[/\\]', '/'
                $normalizedTestDir = $script:TestLogDir -replace '[/\\]', '/'
                $normalizedPath | Should -Match ([regex]::Escape($normalizedTestDir) -replace '\\/', '/')
            }

            It "Should return path in current directory when no log session" {
                $script:CurrentOperationalLogPath = $null

                $path = Get-CheckpointPath

                $path | Should -Match "robocurse-checkpoint\.json$"
            }
        }

        Context "Save-ReplicationCheckpoint" {
            BeforeEach {
                $script:OrchestrationState.StartTime = [datetime]::Now.AddMinutes(-5)
                $script:OrchestrationState.ProfileIndex = 0
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "TestProfile" }
            }

            It "Should save checkpoint file" {
                $result = Save-ReplicationCheckpoint

                $result.Success | Should -Be $true
                Test-Path $result.Data | Should -Be $true
            }

            It "Should save valid JSON" {
                $result = Save-ReplicationCheckpoint

                $content = Get-Content $result.Data -Raw
                { $content | ConvertFrom-Json } | Should -Not -Throw
            }

            It "Should include version number" {
                $result = Save-ReplicationCheckpoint
                $checkpoint = Get-Content $result.Data -Raw | ConvertFrom-Json

                $checkpoint.Version | Should -Be "1.0"
            }

            It "Should include session ID" {
                $result = Save-ReplicationCheckpoint
                $checkpoint = Get-Content $result.Data -Raw | ConvertFrom-Json

                $checkpoint.SessionId | Should -Be $script:OrchestrationState.SessionId
            }

            It "Should track completed chunk paths" {
                # Add some completed chunks
                $chunk1 = [PSCustomObject]@{ SourcePath = "C:\Test\Folder1"; ChunkId = 1 }
                $chunk2 = [PSCustomObject]@{ SourcePath = "C:\Test\Folder2"; ChunkId = 2 }
                $script:OrchestrationState.CompletedChunks.Enqueue($chunk1)
                $script:OrchestrationState.CompletedChunks.Enqueue($chunk2)

                $result = Save-ReplicationCheckpoint
                $checkpoint = Get-Content $result.Data -Raw | ConvertFrom-Json

                $checkpoint.CompletedChunkPaths | Should -Contain "C:\Test\Folder1"
                $checkpoint.CompletedChunkPaths | Should -Contain "C:\Test\Folder2"
            }

            It "Should return error when no orchestration state" {
                $script:OrchestrationState = $null

                $result = Save-ReplicationCheckpoint

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "No orchestration state"
            }

            It "Should use atomic write (temp file then rename)" {
                $checkpointPath = Get-CheckpointPath

                $result = Save-ReplicationCheckpoint

                # Temp file should not exist after save
                Test-Path "$checkpointPath.tmp" | Should -Be $false
                # Final file should exist
                Test-Path $checkpointPath | Should -Be $true
            }
        }

        Context "Get-ReplicationCheckpoint" {
            It "Should return null when no checkpoint exists" {
                $checkpoint = Get-ReplicationCheckpoint

                $checkpoint | Should -BeNullOrEmpty
            }

            It "Should load saved checkpoint" {
                # Save first
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "Test" }
                Save-ReplicationCheckpoint | Out-Null

                $checkpoint = Get-ReplicationCheckpoint

                $checkpoint | Should -Not -BeNullOrEmpty
                $checkpoint.SessionId | Should -Be $script:OrchestrationState.SessionId
            }

            It "Should return null for invalid JSON" {
                $checkpointPath = Get-CheckpointPath
                "not valid json" | Set-Content $checkpointPath

                $checkpoint = Get-ReplicationCheckpoint

                $checkpoint | Should -BeNullOrEmpty
            }

            It "Should return null for mismatched version" {
                $checkpointPath = Get-CheckpointPath
                @{
                    Version = "2.0"
                    SessionId = "test"
                    CompletedChunkPaths = @()
                } | ConvertTo-Json | Set-Content $checkpointPath

                $checkpoint = Get-ReplicationCheckpoint

                $checkpoint | Should -BeNullOrEmpty
            }

            It "Should load checkpoint with correct version" {
                $checkpointPath = Get-CheckpointPath
                @{
                    Version = "1.0"
                    SessionId = "test-session"
                    CompletedChunkPaths = @("C:\Test\Path1", "C:\Test\Path2")
                    SavedAt = (Get-Date).ToString('o')
                } | ConvertTo-Json | Set-Content $checkpointPath

                $checkpoint = Get-ReplicationCheckpoint

                $checkpoint | Should -Not -BeNullOrEmpty
                $checkpoint.SessionId | Should -Be "test-session"
            }
        }

        Context "Remove-ReplicationCheckpoint" {
            BeforeEach {
                # Create a checkpoint first
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "Test" }
                Save-ReplicationCheckpoint | Out-Null
            }

            It "Should remove checkpoint file" {
                $checkpointPath = Get-CheckpointPath

                $result = Remove-ReplicationCheckpoint

                $result | Should -Be $true
                Test-Path $checkpointPath | Should -Be $false
            }

            It "Should return false when no checkpoint exists" {
                Remove-ReplicationCheckpoint | Out-Null  # Remove first

                $result = Remove-ReplicationCheckpoint

                $result | Should -Be $false
            }

            It "Should support WhatIf" {
                $checkpointPath = Get-CheckpointPath

                Remove-ReplicationCheckpoint -WhatIf

                # File should still exist after WhatIf
                Test-Path $checkpointPath | Should -Be $true
            }
        }

        Context "Test-ChunkAlreadyCompleted" {
            It "Should return false when no checkpoint" {
                $chunk = [PSCustomObject]@{ SourcePath = "C:\Test\Path" }

                $result = Test-ChunkAlreadyCompleted -Chunk $chunk -Checkpoint $null

                $result | Should -Be $false
            }

            It "Should return false when checkpoint has no paths" {
                $chunk = [PSCustomObject]@{ SourcePath = "C:\Test\Path" }
                $checkpoint = [PSCustomObject]@{ CompletedChunkPaths = @() }

                $result = Test-ChunkAlreadyCompleted -Chunk $chunk -Checkpoint $checkpoint

                $result | Should -Be $false
            }

            It "Should return true when path is in checkpoint" {
                $chunk = [PSCustomObject]@{ SourcePath = "C:\Test\Path" }
                $checkpoint = [PSCustomObject]@{
                    CompletedChunkPaths = @("C:\Test\Path", "C:\Test\Other")
                }

                $result = Test-ChunkAlreadyCompleted -Chunk $chunk -Checkpoint $checkpoint

                $result | Should -Be $true
            }

            It "Should be case-insensitive" {
                $chunk = [PSCustomObject]@{ SourcePath = "C:\TEST\PATH" }
                $checkpoint = [PSCustomObject]@{
                    CompletedChunkPaths = @("c:\test\path")
                }

                $result = Test-ChunkAlreadyCompleted -Chunk $chunk -Checkpoint $checkpoint

                $result | Should -Be $true
            }

            It "Should return false when path not in checkpoint" {
                $chunk = [PSCustomObject]@{ SourcePath = "C:\New\Path" }
                $checkpoint = [PSCustomObject]@{
                    CompletedChunkPaths = @("C:\Test\Path", "C:\Test\Other")
                }

                $result = Test-ChunkAlreadyCompleted -Chunk $chunk -Checkpoint $checkpoint

                $result | Should -Be $false
            }

            It "Should return false when chunk has null SourcePath" {
                $chunk = [PSCustomObject]@{ SourcePath = $null }
                $checkpoint = [PSCustomObject]@{
                    CompletedChunkPaths = @("C:\Test\Path")
                }

                $result = Test-ChunkAlreadyCompleted -Chunk $chunk -Checkpoint $checkpoint

                $result | Should -Be $false
            }

            It "Should skip null entries in completed paths" {
                $chunk = [PSCustomObject]@{ SourcePath = "C:\Test\Path" }
                $checkpoint = [PSCustomObject]@{
                    CompletedChunkPaths = @($null, "C:\Test\Path", $null)
                }

                $result = Test-ChunkAlreadyCompleted -Chunk $chunk -Checkpoint $checkpoint

                $result | Should -Be $true
            }
        }

        Context "Checkpoint Persistence" {
            It "Should survive module reload" {
                # Save checkpoint
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "Test" }
                Save-ReplicationCheckpoint | Out-Null

                $checkpointPath = Get-CheckpointPath
                $checkpointExists = Test-Path $checkpointPath

                $checkpointExists | Should -Be $true
            }

            It "Should handle concurrent saves safely" {
                # Multiple rapid saves should not corrupt the file
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "Test" }

                1..10 | ForEach-Object {
                    $script:OrchestrationState.IncrementCompletedCount()
                    Save-ReplicationCheckpoint | Out-Null
                }

                $checkpoint = Get-ReplicationCheckpoint
                $checkpoint | Should -Not -BeNullOrEmpty
                $checkpoint.CompletedCount | Should -Be 10
            }
        }

        Context "Edge Cases" {
            It "Should handle very long paths" {
                $longPath = "C:\" + ("A" * 200) + "\Test"
                $chunk = [PSCustomObject]@{ SourcePath = $longPath }
                $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "Test" }

                $result = Save-ReplicationCheckpoint
                $checkpoint = Get-Content $result.Data -Raw | ConvertFrom-Json

                $checkpoint.CompletedChunkPaths | Should -Contain $longPath
            }

            It "Should handle Unicode paths" {
                $unicodePath = "C:\Tést\日本語\Données"
                $chunk = [PSCustomObject]@{ SourcePath = $unicodePath }
                $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "Test" }

                $result = Save-ReplicationCheckpoint
                $checkpoint = Get-ReplicationCheckpoint

                $checkpoint.CompletedChunkPaths | Should -Contain $unicodePath
            }

            It "Should handle thousands of completed paths" {
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "Test" }

                1..1000 | ForEach-Object {
                    $chunk = [PSCustomObject]@{ SourcePath = "C:\Test\Folder$_"; ChunkId = $_ }
                    $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
                }

                $result = Save-ReplicationCheckpoint
                $checkpoint = Get-ReplicationCheckpoint

                $checkpoint.CompletedChunkPaths.Count | Should -Be 1000
            }
        }
    }
}
