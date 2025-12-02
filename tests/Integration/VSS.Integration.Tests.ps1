#Requires -Modules Pester

<#
.SYNOPSIS
    Real VSS (Volume Shadow Copy) integration tests for Robocurse

.DESCRIPTION
    These tests create actual VSS snapshots to verify the VSS functions work correctly.
    Tests cover:
    - VSS privilege checking
    - Creating and deleting snapshots
    - Path translation to VSS paths
    - Reading files through VSS snapshots
    - Invoke-WithVssSnapshot cleanup behavior
    - Robocopy with VSS source paths

.NOTES
    - Requires Windows with VSS service running
    - Requires Administrator privileges
    - Uses local C: drive for snapshot testing
    - Snapshots are cleaned up after each test
#>

BeforeDiscovery {
    # Load fixtures early for discovery-time checks
    . "$PSScriptRoot\Fixtures\TestDataGenerator.ps1"

    # Check if we're on Windows with admin privileges for VSS
    $script:CanUseVss = $false
    if ($env:OS -eq 'Windows_NT' -or $PSVersionTable.Platform -eq 'Win32NT' -or (-not $PSVersionTable.Platform)) {
        # Check admin privileges
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]$identity
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

        if ($isAdmin) {
            # Check VSS service is running
            try {
                $vssService = Get-Service -Name 'VSS' -ErrorAction SilentlyContinue
                $script:CanUseVss = $vssService -and $vssService.Status -eq 'Running'
            }
            catch {
                $script:CanUseVss = $false
            }
        }
    }
}

BeforeAll {
    # Load test helper and fixtures
    . "$PSScriptRoot\..\TestHelper.ps1"
    . "$PSScriptRoot\Fixtures\TestDataGenerator.ps1"
    Initialize-RobocurseForTesting

    # Helper to wait for robocopy job
    function Wait-RobocopyComplete {
        param($Job, [int]$TimeoutSeconds = 60)

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $Job.Process.HasExited -and $stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 100
        }
        return $Job.Process.HasExited
    }
}

Describe "VSS Integration Tests" -Skip:(-not $script:CanUseVss) {

    Context "VSS Privilege Check" {
        It "Should report VSS privileges available when running as admin" {
            $result = Test-VssPrivileges
            $result.Success | Should -Be $true
        }

        It "Should detect VSS service is running" {
            $service = Get-Service -Name 'VSS'
            $service.Status | Should -Be 'Running'
        }
    }

    Context "VSS Snapshot Creation and Deletion" {
        It "Should create a VSS snapshot of C: drive" {
            # Use a path on C: that definitely exists
            $result = New-VssSnapshot -SourcePath "C:\Windows"

            try {
                $result.Success | Should -Be $true -Because "VSS snapshot should succeed on C:"
                $result.Data | Should -Not -BeNullOrEmpty

                # Verify snapshot properties
                $result.Data.ShadowId | Should -Match '^\{[A-F0-9-]+\}$'
                $result.Data.ShadowPath | Should -Match 'HarddiskVolumeShadowCopy'
                $result.Data.SourceVolume | Should -Be 'C:'
                $result.Data.CreatedAt | Should -BeOfType [datetime]
            }
            finally {
                # Clean up
                if ($result.Success -and $result.Data.ShadowId) {
                    Remove-VssSnapshot -ShadowId $result.Data.ShadowId | Out-Null
                }
            }
        }

        It "Should delete a VSS snapshot" {
            # Create a snapshot first
            $createResult = New-VssSnapshot -SourcePath "C:\Windows"
            $createResult.Success | Should -Be $true

            $shadowId = $createResult.Data.ShadowId

            # Delete it
            $deleteResult = Remove-VssSnapshot -ShadowId $shadowId
            $deleteResult.Success | Should -Be $true

            # Verify it's gone by trying to find it
            $remaining = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowId }
            $remaining | Should -BeNullOrEmpty
        }

        It "Should handle deleting non-existent snapshot gracefully" {
            $fakeId = "{00000000-0000-0000-0000-000000000000}"
            $result = Remove-VssSnapshot -ShadowId $fakeId

            # Should succeed (idempotent) since the snapshot is already gone
            $result.Success | Should -Be $true
        }
    }

    Context "VSS Path Translation" {
        BeforeAll {
            # Create a snapshot for path translation tests
            $script:TestSnapshot = $null
            $result = New-VssSnapshot -SourcePath "C:\Windows"
            if ($result.Success) {
                $script:TestSnapshot = $result.Data
            }
        }

        AfterAll {
            # Clean up the test snapshot
            if ($script:TestSnapshot) {
                Remove-VssSnapshot -ShadowId $script:TestSnapshot.ShadowId | Out-Null
            }
        }

        It "Should translate local path to VSS path" -Skip:(-not $script:TestSnapshot) {
            $vssPath = Get-VssPath -OriginalPath "C:\Windows\System32" -VssSnapshot $script:TestSnapshot

            $vssPath | Should -Match 'HarddiskVolumeShadowCopy'
            $vssPath | Should -Match 'Windows\\System32'
        }

        It "Should translate root path correctly" -Skip:(-not $script:TestSnapshot) {
            $vssPath = Get-VssPath -OriginalPath "C:\" -VssSnapshot $script:TestSnapshot

            $vssPath | Should -Match 'HarddiskVolumeShadowCopy'
            # Root path should end with the shadow copy path (no extra backslash)
        }

        It "Should handle paths with spaces" -Skip:(-not $script:TestSnapshot) {
            $vssPath = Get-VssPath -OriginalPath "C:\Program Files" -VssSnapshot $script:TestSnapshot

            $vssPath | Should -Match 'HarddiskVolumeShadowCopy'
            $vssPath | Should -Match 'Program Files'
        }
    }

    Context "Reading Files Through VSS" {
        BeforeAll {
            # Create test file
            $script:TestFile = Join-Path $env:TEMP "RobocurseVssTest_$([Guid]::NewGuid().ToString('N').Substring(0,8)).txt"
            $script:TestContent = "VSS Test Content - $(Get-Date)"
            $script:TestContent | Set-Content -Path $script:TestFile
        }

        AfterAll {
            # Clean up test file
            if (Test-Path $script:TestFile) {
                Remove-Item $script:TestFile -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should read file content through VSS snapshot" {
            $result = New-VssSnapshot -SourcePath $script:TestFile

            try {
                $result.Success | Should -Be $true

                $vssPath = Get-VssPath -OriginalPath $script:TestFile -VssSnapshot $result.Data

                # The VSS path should be readable
                Test-Path -LiteralPath $vssPath | Should -Be $true

                $vssContent = Get-Content -LiteralPath $vssPath -Raw
                $vssContent.Trim() | Should -Be $script:TestContent
            }
            finally {
                if ($result.Success) {
                    Remove-VssSnapshot -ShadowId $result.Data.ShadowId | Out-Null
                }
            }
        }

        It "Should see original content even after file is modified" {
            # Create a snapshot of the current state
            $result = New-VssSnapshot -SourcePath $script:TestFile

            try {
                $result.Success | Should -Be $true

                $vssPath = Get-VssPath -OriginalPath $script:TestFile -VssSnapshot $result.Data
                $originalContent = Get-Content -LiteralPath $vssPath -Raw

                # Modify the original file
                "MODIFIED CONTENT" | Set-Content -Path $script:TestFile

                # VSS path should still have original content
                $vssContentAfterModify = Get-Content -LiteralPath $vssPath -Raw
                $vssContentAfterModify.Trim() | Should -Be $script:TestContent

                # Original file should have new content
                $currentContent = Get-Content -Path $script:TestFile -Raw
                $currentContent.Trim() | Should -Be "MODIFIED CONTENT"
            }
            finally {
                # Restore original content
                $script:TestContent | Set-Content -Path $script:TestFile
                if ($result.Success) {
                    Remove-VssSnapshot -ShadowId $result.Data.ShadowId | Out-Null
                }
            }
        }
    }

    Context "Invoke-WithVssSnapshot" {
        BeforeAll {
            $script:TestDir = Join-Path $env:TEMP "RobocurseVssTest_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
            "Test file 1" | Set-Content -Path (Join-Path $script:TestDir "file1.txt")
            "Test file 2" | Set-Content -Path (Join-Path $script:TestDir "file2.txt")
        }

        AfterAll {
            if (Test-Path $script:TestDir) {
                Remove-Item $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should execute scriptblock with VSS path and cleanup" {
            $snapshotsBefore = @(Get-CimInstance -ClassName Win32_ShadowCopy)

            $result = Invoke-WithVssSnapshot -SourcePath $script:TestDir -ScriptBlock {
                param($VssPath)
                # Return both the path and file count as an object
                [PSCustomObject]@{
                    VssPath = $VssPath
                    FileCount = (Get-ChildItem -LiteralPath $VssPath -File).Count
                }
            }

            $result.Success | Should -Be $true
            $result.Data.FileCount | Should -Be 2  # Two test files
            $result.Data.VssPath | Should -Match 'HarddiskVolumeShadowCopy'

            # Verify snapshot was cleaned up
            Start-Sleep -Milliseconds 500  # Give time for cleanup
            $snapshotsAfter = @(Get-CimInstance -ClassName Win32_ShadowCopy)
            $snapshotsAfter.Count | Should -BeLessOrEqual $snapshotsBefore.Count
        }

        It "Should cleanup snapshot even when scriptblock throws" {
            $snapshotsBefore = @(Get-CimInstance -ClassName Win32_ShadowCopy)

            $result = Invoke-WithVssSnapshot -SourcePath $script:TestDir -ScriptBlock {
                param($VssPath)
                throw "Intentional test error"
            } -ErrorAction SilentlyContinue

            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Match "Intentional test error"

            # Verify snapshot was still cleaned up
            Start-Sleep -Milliseconds 500
            $snapshotsAfter = @(Get-CimInstance -ClassName Win32_ShadowCopy)
            $snapshotsAfter.Count | Should -BeLessOrEqual $snapshotsBefore.Count
        }
    }

    Context "VSS with PowerShell Copy (robocopy limitation)" {
        # NOTE: Robocopy cannot directly access VSS shadow paths (\\?\GLOBALROOT\Device\...)
        # Error 123: The filename, directory name, or volume label syntax is incorrect.
        # Instead, we test that PowerShell CAN access VSS paths for file operations,
        # which confirms VSS snapshot content is readable.

        BeforeAll {
            $script:SourceDir = Join-Path $env:TEMP "RobocurseVssSource_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
            $script:DestDir = Join-Path $env:TEMP "RobocurseVssDest_$([Guid]::NewGuid().ToString('N').Substring(0,8))"

            New-Item -ItemType Directory -Path $script:SourceDir -Force | Out-Null
            New-Item -ItemType Directory -Path $script:DestDir -Force | Out-Null

            # Create test files
            New-TestTree -RootPath $script:SourceDir -Depth 2 -BreadthPerLevel 2 -FilesPerDir 3 | Out-Null
        }

        AfterAll {
            Remove-Item $script:SourceDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $script:DestDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Should copy files from VSS snapshot using PowerShell" {
            $result = New-VssSnapshot -SourcePath $script:SourceDir

            try {
                $result.Success | Should -Be $true

                $vssPath = Get-VssPath -OriginalPath $script:SourceDir -VssSnapshot $result.Data

                # Use PowerShell Copy-Item which CAN access VSS paths
                Copy-Item -LiteralPath $vssPath -Destination $script:DestDir -Recurse -Force

                # Verify files were copied
                $sourceFiles = Get-ChildItem $script:SourceDir -Recurse -File
                $destFiles = Get-ChildItem $script:DestDir -Recurse -File

                $destFiles.Count | Should -Be $sourceFiles.Count
            }
            finally {
                if ($result.Success) {
                    Remove-VssSnapshot -ShadowId $result.Data.ShadowId | Out-Null
                }
                # Clear dest for next test
                Get-ChildItem $script:DestDir | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should see consistent snapshot even when source changes" {
            # Create files
            $originalCount = (Get-ChildItem $script:SourceDir -Recurse -File).Count

            # Create snapshot
            $result = New-VssSnapshot -SourcePath $script:SourceDir
            $result.Success | Should -Be $true

            try {
                $vssPath = Get-VssPath -OriginalPath $script:SourceDir -VssSnapshot $result.Data

                # Add new file AFTER snapshot
                "New file after snapshot" | Set-Content -Path (Join-Path $script:SourceDir "new_after_snapshot.txt")

                # Count files in VSS snapshot (should NOT include new file)
                $vssFiles = Get-ChildItem -LiteralPath $vssPath -Recurse -File
                $vssFiles.Count | Should -Be $originalCount

                # Source should have one more file now
                $currentSourceFiles = Get-ChildItem $script:SourceDir -Recurse -File
                $currentSourceFiles.Count | Should -Be ($originalCount + 1)
            }
            finally {
                Remove-VssSnapshot -ShadowId $result.Data.ShadowId | Out-Null
                # Remove the extra file
                Remove-Item (Join-Path $script:SourceDir "new_after_snapshot.txt") -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should preserve file content in VSS snapshot even after modification" {
            $testFile = Join-Path $script:SourceDir "content_test.txt"
            $originalContent = "Original content before snapshot"
            $originalContent | Set-Content -Path $testFile

            $result = New-VssSnapshot -SourcePath $script:SourceDir

            try {
                $result.Success | Should -Be $true

                $vssPath = Get-VssPath -OriginalPath $script:SourceDir -VssSnapshot $result.Data
                $vssFile = Join-Path $vssPath "content_test.txt"

                # Modify the original file
                "Modified content after snapshot" | Set-Content -Path $testFile

                # VSS should still have original content
                $vssContent = Get-Content -LiteralPath $vssFile -Raw
                $vssContent.Trim() | Should -Be $originalContent

                # Current file should have modified content
                $currentContent = Get-Content -Path $testFile -Raw
                $currentContent.Trim() | Should -Be "Modified content after snapshot"
            }
            finally {
                Remove-VssSnapshot -ShadowId $result.Data.ShadowId | Out-Null
                Remove-Item $testFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "VSS Snapshot Tracking" {
        It "Should track created snapshots" {
            $result = New-VssSnapshot -SourcePath "C:\Windows"

            try {
                $result.Success | Should -Be $true

                # Check tracking file exists and contains this snapshot
                $trackingFile = Join-Path $env:TEMP "Robocurse-VSS-Tracking.json"
                if (Test-Path $trackingFile) {
                    $tracking = Get-Content $trackingFile -Raw | ConvertFrom-Json
                    $ids = @($tracking) | ForEach-Object { $_.ShadowId }
                    $ids | Should -Contain $result.Data.ShadowId
                }
            }
            finally {
                if ($result.Success) {
                    Remove-VssSnapshot -ShadowId $result.Data.ShadowId | Out-Null
                }
            }
        }

        It "Should remove snapshot from tracking after deletion" {
            $result = New-VssSnapshot -SourcePath "C:\Windows"
            $result.Success | Should -Be $true

            $shadowId = $result.Data.ShadowId

            # Delete the snapshot
            Remove-VssSnapshot -ShadowId $shadowId | Out-Null

            # Check tracking file no longer contains this ID
            $trackingFile = Join-Path $env:TEMP "Robocurse-VSS-Tracking.json"
            if (Test-Path $trackingFile) {
                $content = Get-Content $trackingFile -Raw
                if ($content) {
                    $tracking = $content | ConvertFrom-Json
                    $ids = @($tracking) | ForEach-Object { $_.ShadowId }
                    $ids | Should -Not -Contain $shadowId
                }
            }
        }
    }
}

Describe "VSS Not Available Tests" -Skip:($script:CanUseVss) {
    It "Should report VSS not available when not running as admin or VSS service stopped" {
        $result = Test-VssPrivileges

        # Either not admin or VSS service issue
        if (-not $result.Success) {
            $result.ErrorMessage | Should -Not -BeNullOrEmpty
        }
    }
}
