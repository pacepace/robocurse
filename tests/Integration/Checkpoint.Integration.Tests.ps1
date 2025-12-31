#Requires -Modules Pester

# Integration tests for Checkpoint - verify real checkpoint file save/restore operations
# These tests write actual checkpoint files to disk and verify JSON serialization,
# file encoding, and recovery scenarios (no mocks)

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type
Initialize-OrchestrationStateType | Out-Null

Describe "Checkpoint Integration Tests - Save/Restore Round-Trip" -Tag "Integration" {
    BeforeAll {
        # Create temp directory for checkpoint files
        $script:TestRoot = Join-Path $env:TEMP "RobocurseCheckpoint_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
            Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should save and restore checkpoint with all properties intact" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            # Set up test log directory for checkpoint storage
            $logDir = Join-Path $TestRoot "Logs"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            # Create fresh orchestration state
            Initialize-OrchestrationState
            $script:OrchestrationState.SessionId = "test-session-roundtrip"
            $script:OrchestrationState.StartTime = [datetime]::Now.AddMinutes(-5)
            $script:OrchestrationState.ProfileIndex = 2
            $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "TestProfile" }

            # Add completed chunks with various paths
            $chunk1 = [PSCustomObject]@{ SourcePath = "C:\Source\Folder1"; ChunkId = 1 }
            $chunk2 = [PSCustomObject]@{ SourcePath = "D:\Data\Backup\Project"; ChunkId = 2 }
            $chunk3 = [PSCustomObject]@{ SourcePath = "\\Server\Share\Files"; ChunkId = 3 }
            $script:OrchestrationState.CompletedChunks.Enqueue($chunk1)
            $script:OrchestrationState.CompletedChunks.Enqueue($chunk2)
            $script:OrchestrationState.CompletedChunks.Enqueue($chunk3)

            # Update counters
            $script:OrchestrationState.IncrementCompletedCount()
            $script:OrchestrationState.IncrementCompletedCount()
            $script:OrchestrationState.IncrementCompletedCount()

            # Save checkpoint
            $result = Save-ReplicationCheckpoint

            $result.Success | Should -Be $true -Because "Save should succeed"
            $checkpointPath = $result.Data

            # Verify file exists
            Test-Path $checkpointPath | Should -Be $true -Because "Checkpoint file should exist on disk"

            # Verify file content is valid JSON
            $json = Get-Content $checkpointPath -Raw -Encoding UTF8
            { $json | ConvertFrom-Json } | Should -Not -Throw -Because "Checkpoint should contain valid JSON"

            # Restore and verify all properties
            $restored = Get-ReplicationCheckpoint

            $restored | Should -Not -BeNullOrEmpty -Because "Restored checkpoint should not be null"
            $restored.SessionId | Should -Be "test-session-roundtrip"
            $restored.ProfileIndex | Should -Be 2
            $restored.CurrentProfileName | Should -Be "TestProfile"
            $restored.CompletedCount | Should -Be 3
            $restored.CompletedChunkPaths.Count | Should -Be 3
            $restored.CompletedChunkPaths | Should -Contain "C:\Source\Folder1"
            $restored.CompletedChunkPaths | Should -Contain "D:\Data\Backup\Project"
            $restored.CompletedChunkPaths | Should -Contain "\\Server\Share\Files"
            $restored.Version | Should -Be "1.0"
        }
    }

    It "Should preserve timestamp in ISO 8601 format" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsTimestamp"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            Initialize-OrchestrationState
            $script:OrchestrationState.SessionId = "test-session-timestamp"
            $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "Test" }

            $beforeSave = Get-Date
            $result = Save-ReplicationCheckpoint

            $restored = Get-ReplicationCheckpoint

            # SavedAt should be a valid ISO 8601 timestamp
            { [datetime]::Parse($restored.SavedAt) } | Should -Not -Throw
            $savedAt = [datetime]::Parse($restored.SavedAt)
            $savedAt | Should -BeGreaterOrEqual $beforeSave.AddSeconds(-1)
        }
    }
}

Describe "Checkpoint Integration Tests - Partial Completion Recovery" -Tag "Integration" {
    BeforeAll {
        $script:TestRoot = Join-Path $env:TEMP "RobocurseCheckpointPartial_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
            Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should restore partial progress for crash recovery" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsPartial"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            Initialize-OrchestrationState
            $script:OrchestrationState.SessionId = "test-session-partial"
            $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "PartialTest" }
            $script:OrchestrationState.ProfileIndex = 1

            # Simulate mid-replication state: some chunks completed, some failed, some pending
            # Add 5 completed chunks
            for ($i = 1; $i -le 5; $i++) {
                $chunk = [PSCustomObject]@{ SourcePath = "C:\Data\Completed$i"; ChunkId = $i }
                $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
                $script:OrchestrationState.IncrementCompletedCount()
            }

            # Add 2 failed chunks
            $failedChunk1 = [PSCustomObject]@{ SourcePath = "C:\Data\Failed1"; ChunkId = 6; LastError = "Access denied" }
            $failedChunk2 = [PSCustomObject]@{ SourcePath = "C:\Data\Failed2"; ChunkId = 7; LastError = "Network timeout" }
            $script:OrchestrationState.FailedChunks.Enqueue($failedChunk1)
            $script:OrchestrationState.FailedChunks.Enqueue($failedChunk2)

            # Save checkpoint (pending chunks are not tracked in checkpoint - they are re-enumerated on resume)
            $result = Save-ReplicationCheckpoint

            $result.Success | Should -Be $true

            # Restore and verify we can identify completed chunks
            $restored = Get-ReplicationCheckpoint

            $restored.CompletedChunkPaths.Count | Should -Be 5 -Because "Should have 5 completed chunk paths"
            $restored.CompletedCount | Should -Be 5
            $restored.FailedCount | Should -Be 2

            # Verify we can use Test-ChunkAlreadyCompleted to skip completed chunks
            $hashSet = New-CompletedPathsHashSet -Checkpoint $restored

            # Completed chunks should be detected
            $completedChunk = [PSCustomObject]@{ SourcePath = "C:\Data\Completed3" }
            $isCompleted = Test-ChunkAlreadyCompleted -Chunk $completedChunk -Checkpoint $restored -CompletedPathsHashSet $hashSet
            $isCompleted | Should -Be $true -Because "Completed chunk should be detected as already completed"

            # New/pending chunks should not be detected as completed
            $pendingChunk = [PSCustomObject]@{ SourcePath = "C:\Data\Pending1" }
            $isPending = Test-ChunkAlreadyCompleted -Chunk $pendingChunk -Checkpoint $restored -CompletedPathsHashSet $hashSet
            $isPending | Should -Be $false -Because "Pending chunk should not be detected as completed"
        }
    }

    It "Should track progress incrementally across multiple saves" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsIncremental"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            Initialize-OrchestrationState
            $script:OrchestrationState.SessionId = "test-session-incremental"
            $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "IncrementalTest" }

            # First checkpoint: 2 completed
            for ($i = 1; $i -le 2; $i++) {
                $chunk = [PSCustomObject]@{ SourcePath = "C:\Batch1\Folder$i"; ChunkId = $i }
                $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
                $script:OrchestrationState.IncrementCompletedCount()
            }
            Save-ReplicationCheckpoint | Out-Null

            $checkpoint1 = Get-ReplicationCheckpoint
            $checkpoint1.CompletedChunkPaths.Count | Should -Be 2

            # Second checkpoint: add 3 more completed
            for ($i = 3; $i -le 5; $i++) {
                $chunk = [PSCustomObject]@{ SourcePath = "C:\Batch2\Folder$i"; ChunkId = $i }
                $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
                $script:OrchestrationState.IncrementCompletedCount()
            }
            Save-ReplicationCheckpoint | Out-Null

            $checkpoint2 = Get-ReplicationCheckpoint
            $checkpoint2.CompletedChunkPaths.Count | Should -Be 5
            $checkpoint2.CompletedCount | Should -Be 5
        }
    }
}

Describe "Checkpoint Integration Tests - Corrupt File Handling" -Tag "Integration" {
    BeforeAll {
        $script:TestRoot = Join-Path $env:TEMP "RobocurseCheckpointCorrupt_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
            Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should handle corrupt JSON checkpoint file gracefully" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsCorrupt"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            $checkpointPath = Get-CheckpointPath

            # Write invalid JSON
            "{ invalid json content, missing closing brace" | Set-Content $checkpointPath -Encoding UTF8

            # Should not throw, should return null
            $restored = Get-ReplicationCheckpoint -ErrorAction SilentlyContinue

            $restored | Should -BeNullOrEmpty -Because "Corrupt JSON should result in null checkpoint"
        }
    }

    It "Should handle truncated JSON file" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsTruncated"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            $checkpointPath = Get-CheckpointPath

            # Write truncated JSON (simulating crash during write)
            '{"Version":"1.0","SessionId":"test","CompletedChun' | Set-Content $checkpointPath -Encoding UTF8

            $restored = Get-ReplicationCheckpoint -ErrorAction SilentlyContinue

            $restored | Should -BeNullOrEmpty -Because "Truncated JSON should result in null checkpoint"
        }
    }

    It "Should handle empty file" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsEmpty"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            $checkpointPath = Get-CheckpointPath

            # Write empty file
            "" | Set-Content $checkpointPath -Encoding UTF8

            $restored = Get-ReplicationCheckpoint -ErrorAction SilentlyContinue

            $restored | Should -BeNullOrEmpty -Because "Empty file should result in null checkpoint"
        }
    }

    It "Should handle binary garbage data" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsBinary"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            $checkpointPath = Get-CheckpointPath

            # Write binary garbage
            $bytes = [byte[]]@(0x00, 0xFF, 0x80, 0x7F, 0x01, 0xFE)
            [System.IO.File]::WriteAllBytes($checkpointPath, $bytes)

            $restored = Get-ReplicationCheckpoint -ErrorAction SilentlyContinue

            $restored | Should -BeNullOrEmpty -Because "Binary garbage should result in null checkpoint"
        }
    }
}

Describe "Checkpoint Integration Tests - Cleanup" -Tag "Integration" {
    BeforeAll {
        $script:TestRoot = Join-Path $env:TEMP "RobocurseCheckpointCleanup_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
            Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should remove checkpoint on successful completion using Remove-ReplicationCheckpoint" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsCleanup"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            Initialize-OrchestrationState
            $script:OrchestrationState.SessionId = "test-session-cleanup"
            $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "CleanupTest" }

            # Create checkpoint
            $result = Save-ReplicationCheckpoint
            $checkpointPath = Get-CheckpointPath

            Test-Path $checkpointPath | Should -Be $true -Because "Checkpoint should exist after save"

            # Clear checkpoint (simulating successful completion)
            $removed = Remove-ReplicationCheckpoint

            $removed | Should -Be $true -Because "Remove should return true when file existed"
            Test-Path $checkpointPath | Should -Be $false -Because "Checkpoint should be removed after clear"
        }
    }

    It "Should handle removing non-existent checkpoint gracefully" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsNoFile"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            $checkpointPath = Get-CheckpointPath

            # Ensure no checkpoint exists
            if (Test-Path $checkpointPath) {
                Remove-Item $checkpointPath -Force
            }

            # Should not throw, should return false
            $removed = Remove-ReplicationCheckpoint

            $removed | Should -Be $false -Because "Remove should return false when no file exists"
        }
    }

    It "Should clean up temp files after atomic write" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsAtomic"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            Initialize-OrchestrationState
            $script:OrchestrationState.SessionId = "test-session-atomic"
            $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "AtomicTest" }

            Save-ReplicationCheckpoint | Out-Null

            $checkpointPath = Get-CheckpointPath
            $tempPath = "$checkpointPath.tmp"
            $backupPath = "$checkpointPath.bak"

            # Temp and backup files should not exist after successful save
            Test-Path $tempPath | Should -Be $false -Because "Temp file should be cleaned up"
            Test-Path $backupPath | Should -Be $false -Because "Backup file should be cleaned up"
        }
    }
}

Describe "Checkpoint Integration Tests - Unicode Paths" -Tag "Integration" {
    BeforeAll {
        $script:TestRoot = Join-Path $env:TEMP "RobocurseCheckpointUnicode_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
            Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should handle unicode paths in chunk SourcePath" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsUnicode"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            Initialize-OrchestrationState
            $script:OrchestrationState.SessionId = "test-session-unicode"
            $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "UnicodeTest" }

            # Add chunks with various unicode paths
            $unicodePaths = @(
                "C:\Donnees\Projet",                    # French accented characters
                "D:\Backup\$([char]0x65E5)$([char]0x672C)$([char]0x8A9E)",  # Japanese characters
                "E:\Data\$([char]0x041F)$([char]0x0440)$([char]0x0438)$([char]0x0432)$([char]0x0435)$([char]0x0442)",  # Russian (Privet)
                "F:\Files\$([char]0x4E2D)$([char]0x6587)",  # Chinese characters
                "G:\Storage\$([char]0x00E4)$([char]0x00F6)$([char]0x00FC)",  # German umlauts
                "H:\Archive\$([char]0x0391)$([char]0x0392)$([char]0x0393)"   # Greek characters
            )

            $chunkId = 1
            foreach ($path in $unicodePaths) {
                $chunk = [PSCustomObject]@{ SourcePath = $path; ChunkId = $chunkId }
                $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
                $script:OrchestrationState.IncrementCompletedCount()
                $chunkId++
            }

            # Save checkpoint
            $result = Save-ReplicationCheckpoint

            $result.Success | Should -Be $true

            # Verify file is valid UTF-8 JSON
            $checkpointPath = Get-CheckpointPath
            $json = Get-Content $checkpointPath -Raw -Encoding UTF8
            { $json | ConvertFrom-Json } | Should -Not -Throw

            # Restore and verify unicode paths preserved
            $restored = Get-ReplicationCheckpoint

            $restored.CompletedChunkPaths.Count | Should -Be $unicodePaths.Count

            foreach ($path in $unicodePaths) {
                $restored.CompletedChunkPaths | Should -Contain $path -Because "Unicode path '$path' should be preserved"
            }
        }
    }

    It "Should handle unicode in profile name" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsUnicodeProfile"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            Initialize-OrchestrationState
            $script:OrchestrationState.SessionId = "test-session-unicode-profile"
            # Profile name with unicode characters
            $unicodeProfileName = "Backup-$([char]0x65E5)$([char]0x672C)-Server"
            $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = $unicodeProfileName }

            Save-ReplicationCheckpoint | Out-Null

            $restored = Get-ReplicationCheckpoint

            $restored.CurrentProfileName | Should -Be $unicodeProfileName
        }
    }
}

Describe "Checkpoint Integration Tests - Large Checkpoint" -Tag "Integration" {
    BeforeAll {
        $script:TestRoot = Join-Path $env:TEMP "RobocurseCheckpointLarge_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
            Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should handle checkpoint with many chunks (1000+)" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsLarge"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            Initialize-OrchestrationState
            $script:OrchestrationState.SessionId = "test-session-large"
            $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "LargeTest" }

            $chunkCount = 1000

            # Add many completed chunks
            for ($i = 1; $i -le $chunkCount; $i++) {
                $chunk = [PSCustomObject]@{
                    SourcePath = "C:\Data\Project$i\Folder$($i % 10)\Subfolder$($i % 100)"
                    ChunkId = $i
                }
                $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
                $script:OrchestrationState.IncrementCompletedCount()
            }

            # Save checkpoint
            $result = Save-ReplicationCheckpoint

            $result.Success | Should -Be $true

            # Verify file is valid JSON
            $checkpointPath = Get-CheckpointPath
            $json = Get-Content $checkpointPath -Raw -Encoding UTF8
            { $json | ConvertFrom-Json } | Should -Not -Throw

            # Restore and verify count
            $restored = Get-ReplicationCheckpoint

            $restored.CompletedChunkPaths.Count | Should -Be $chunkCount
            $restored.CompletedCount | Should -Be $chunkCount
        }
    }

    It "Should have O(1) lookup performance with HashSet for large checkpoints" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsHashSet"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            Initialize-OrchestrationState
            $script:OrchestrationState.SessionId = "test-session-hashset"
            $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "HashSetTest" }

            # Add many completed chunks
            for ($i = 1; $i -le 500; $i++) {
                $chunk = [PSCustomObject]@{ SourcePath = "C:\Large\Path$i"; ChunkId = $i }
                $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
                $script:OrchestrationState.IncrementCompletedCount()
            }

            Save-ReplicationCheckpoint | Out-Null
            $restored = Get-ReplicationCheckpoint

            # Create HashSet for O(1) lookups
            $hashSet = New-CompletedPathsHashSet -Checkpoint $restored

            $hashSet | Should -Not -BeNullOrEmpty
            $hashSet.Count | Should -Be 500

            # Verify lookups work
            $testChunk = [PSCustomObject]@{ SourcePath = "C:\Large\Path250" }
            $found = Test-ChunkAlreadyCompleted -Chunk $testChunk -Checkpoint $restored -CompletedPathsHashSet $hashSet
            $found | Should -Be $true

            $notFoundChunk = [PSCustomObject]@{ SourcePath = "C:\Large\Path9999" }
            $notFound = Test-ChunkAlreadyCompleted -Chunk $notFoundChunk -Checkpoint $restored -CompletedPathsHashSet $hashSet
            $notFound | Should -Be $false
        }
    }

    It "Should handle very long paths" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsLongPath"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            Initialize-OrchestrationState
            $script:OrchestrationState.SessionId = "test-session-longpath"
            $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "LongPathTest" }

            # Create path close to MAX_PATH limit (260 characters)
            $longPath = "C:\" + ("VeryLongDirectoryName" * 10) + "\FinalFolder"

            $chunk = [PSCustomObject]@{ SourcePath = $longPath; ChunkId = 1 }
            $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
            $script:OrchestrationState.IncrementCompletedCount()

            Save-ReplicationCheckpoint | Out-Null

            $restored = Get-ReplicationCheckpoint

            $restored.CompletedChunkPaths | Should -Contain $longPath
        }
    }
}

Describe "Checkpoint Integration Tests - Missing File Handling" -Tag "Integration" {
    BeforeAll {
        $script:TestRoot = Join-Path $env:TEMP "RobocurseCheckpointMissing_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
            Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should handle non-existent checkpoint file gracefully" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsMissing"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            $checkpointPath = Get-CheckpointPath

            # Ensure no checkpoint exists
            if (Test-Path $checkpointPath) {
                Remove-Item $checkpointPath -Force
            }

            # Should return null, not throw
            $restored = Get-ReplicationCheckpoint

            $restored | Should -BeNullOrEmpty -Because "Non-existent checkpoint should return null"
        }
    }

    It "Should handle missing parent directory gracefully for restore" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            # Point to a non-existent directory
            $nonExistentDir = Join-Path $TestRoot "NonExistent_$(Get-Random)"
            $script:CurrentOperationalLogPath = Join-Path $nonExistentDir "test.log"

            # Should return null, not throw
            $restored = Get-ReplicationCheckpoint

            $restored | Should -BeNullOrEmpty
        }
    }

    It "Should create parent directory when saving checkpoint" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            # Point to a non-existent directory
            $newDir = Join-Path $TestRoot "NewDir_$(Get-Random)"
            $script:CurrentOperationalLogPath = Join-Path $newDir "test.log"

            Initialize-OrchestrationState
            $script:OrchestrationState.SessionId = "test-session-newdir"
            $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "NewDirTest" }

            # Save should create the directory
            $result = Save-ReplicationCheckpoint

            $result.Success | Should -Be $true
            Test-Path $newDir | Should -Be $true -Because "Save should create parent directory if needed"
        }
    }
}

Describe "Checkpoint Integration Tests - Version Compatibility" -Tag "Integration" {
    BeforeAll {
        $script:TestRoot = Join-Path $env:TEMP "RobocurseCheckpointVersion_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
            Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should reject checkpoint with incompatible version" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsVersion"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            $checkpointPath = Get-CheckpointPath

            # Write checkpoint with future version
            @{
                Version = "2.0"
                SessionId = "future-session"
                CompletedChunkPaths = @("C:\Test\Path1")
                SavedAt = (Get-Date).ToString('o')
            } | ConvertTo-Json | Set-Content $checkpointPath -Encoding UTF8

            $restored = Get-ReplicationCheckpoint

            $restored | Should -BeNullOrEmpty -Because "Incompatible version should be rejected"
        }
    }

    It "Should accept checkpoint with current version" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsCurrentVersion"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            $checkpointPath = Get-CheckpointPath

            # Write checkpoint with current version
            @{
                Version = "1.0"
                SessionId = "current-session"
                CompletedChunkPaths = @("C:\Test\Path1", "C:\Test\Path2")
                SavedAt = (Get-Date).ToString('o')
            } | ConvertTo-Json | Set-Content $checkpointPath -Encoding UTF8

            $restored = Get-ReplicationCheckpoint

            $restored | Should -Not -BeNullOrEmpty
            $restored.SessionId | Should -Be "current-session"
            $restored.CompletedChunkPaths.Count | Should -Be 2
        }
    }
}

Describe "Checkpoint Integration Tests - Concurrent Access" -Tag "Integration" {
    BeforeAll {
        $script:TestRoot = Join-Path $env:TEMP "RobocurseCheckpointConcurrent_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
            Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Should handle rapid sequential saves without corruption" {
        InModuleScope 'Robocurse' -Parameters @{ TestRoot = $script:TestRoot } {
            param($TestRoot)

            $logDir = Join-Path $TestRoot "LogsConcurrent"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $script:CurrentOperationalLogPath = Join-Path $logDir "test.log"

            Initialize-OrchestrationState
            $script:OrchestrationState.SessionId = "test-session-concurrent"
            $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "ConcurrentTest" }

            # Rapid saves
            for ($i = 1; $i -le 20; $i++) {
                $chunk = [PSCustomObject]@{ SourcePath = "C:\Rapid\Path$i"; ChunkId = $i }
                $script:OrchestrationState.CompletedChunks.Enqueue($chunk)
                $script:OrchestrationState.IncrementCompletedCount()
                Save-ReplicationCheckpoint | Out-Null
            }

            # Final checkpoint should be valid and complete
            $restored = Get-ReplicationCheckpoint

            $restored | Should -Not -BeNullOrEmpty
            $restored.CompletedChunkPaths.Count | Should -Be 20
            $restored.CompletedCount | Should -Be 20

            # Verify JSON is valid
            $checkpointPath = Get-CheckpointPath
            $json = Get-Content $checkpointPath -Raw -Encoding UTF8
            { $json | ConvertFrom-Json } | Should -Not -Throw
        }
    }
}
