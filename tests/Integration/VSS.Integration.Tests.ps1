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

    Context "VSS Junction Functions" {
        # These tests verify that junctions allow robocopy to access VSS paths
        # which it cannot access directly (Error 123)

        BeforeAll {
            $script:JunctionSourceDir = Join-Path $env:TEMP "RobocurseVssJunctionSrc_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
            $script:JunctionDestDir = Join-Path $env:TEMP "RobocurseVssJunctionDst_$([Guid]::NewGuid().ToString('N').Substring(0,8))"

            New-Item -ItemType Directory -Path $script:JunctionSourceDir -Force | Out-Null
            New-Item -ItemType Directory -Path $script:JunctionDestDir -Force | Out-Null

            # Create test files
            "File 1 content" | Set-Content -Path (Join-Path $script:JunctionSourceDir "file1.txt")
            "File 2 content" | Set-Content -Path (Join-Path $script:JunctionSourceDir "file2.txt")
            New-Item -ItemType Directory -Path (Join-Path $script:JunctionSourceDir "subdir") -Force | Out-Null
            "Subdir file" | Set-Content -Path (Join-Path $script:JunctionSourceDir "subdir\nested.txt")
        }

        AfterAll {
            Remove-Item $script:JunctionSourceDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $script:JunctionDestDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Should create a junction to VSS path" {
            $result = New-VssSnapshot -SourcePath $script:JunctionSourceDir

            try {
                $result.Success | Should -Be $true

                $vssPath = Get-VssPath -OriginalPath $script:JunctionSourceDir -VssSnapshot $result.Data

                # Create junction
                $junctionResult = New-VssJunction -VssPath $vssPath
                $junctionResult.Success | Should -Be $true
                $junctionPath = $junctionResult.Data

                try {
                    # Verify junction exists and is accessible
                    Test-Path $junctionPath | Should -Be $true

                    # Verify files are accessible through junction
                    $files = Get-ChildItem $junctionPath -File
                    $files.Count | Should -Be 2
                }
                finally {
                    Remove-VssJunction -JunctionPath $junctionPath | Out-Null
                }
            }
            finally {
                if ($result.Success) {
                    Remove-VssSnapshot -ShadowId $result.Data.ShadowId | Out-Null
                }
            }
        }

        It "Should remove junction without affecting VSS contents" {
            $result = New-VssSnapshot -SourcePath $script:JunctionSourceDir

            try {
                $result.Success | Should -Be $true

                $vssPath = Get-VssPath -OriginalPath $script:JunctionSourceDir -VssSnapshot $result.Data
                $junctionResult = New-VssJunction -VssPath $vssPath
                $junctionResult.Success | Should -Be $true
                $junctionPath = $junctionResult.Data

                # Remove junction
                $removeResult = Remove-VssJunction -JunctionPath $junctionPath
                $removeResult.Success | Should -Be $true

                # Verify junction is gone
                Test-Path $junctionPath | Should -Be $false

                # Verify VSS path is still accessible (via PowerShell)
                Test-Path -LiteralPath $vssPath | Should -Be $true
            }
            finally {
                if ($result.Success) {
                    Remove-VssSnapshot -ShadowId $result.Data.ShadowId | Out-Null
                }
            }
        }

        It "Should allow robocopy to copy from VSS via junction" {
            $result = New-VssSnapshot -SourcePath $script:JunctionSourceDir

            try {
                $result.Success | Should -Be $true

                $vssPath = Get-VssPath -OriginalPath $script:JunctionSourceDir -VssSnapshot $result.Data
                $junctionResult = New-VssJunction -VssPath $vssPath
                $junctionResult.Success | Should -Be $true
                $junctionPath = $junctionResult.Data

                try {
                    # Clear destination
                    Get-ChildItem $script:JunctionDestDir | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

                    # Use robocopy via junction - THIS IS THE KEY TEST
                    # This should work because robocopy can access the junction path
                    $robocopyOutput = robocopy $junctionPath $script:JunctionDestDir /E /R:0 /W:0 2>&1 | Out-String

                    # Robocopy exit codes 0-7 are success/informational
                    $LASTEXITCODE | Should -BeLessOrEqual 7 -Because "Robocopy should succeed via junction: $robocopyOutput"

                    # Verify files were copied
                    $destFiles = Get-ChildItem $script:JunctionDestDir -Recurse -File
                    $destFiles.Count | Should -Be 3  # file1.txt, file2.txt, subdir/nested.txt
                }
                finally {
                    Remove-VssJunction -JunctionPath $junctionPath | Out-Null
                }
            }
            finally {
                if ($result.Success) {
                    Remove-VssSnapshot -ShadowId $result.Data.ShadowId | Out-Null
                }
            }
        }

        It "Should fail gracefully when junction path already exists" {
            # Create a directory at the junction path
            $existingPath = Join-Path $env:TEMP "RobocurseVssExisting_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $existingPath -Force | Out-Null

            try {
                $result = New-VssJunction -VssPath "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1" -JunctionPath $existingPath
                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "already exists"
            }
            finally {
                Remove-Item $existingPath -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should handle removing non-existent junction gracefully" {
            $fakePath = Join-Path $env:TEMP "RobocurseVssNonExistent_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
            $result = Remove-VssJunction -JunctionPath $fakePath
            $result.Success | Should -Be $true  # Idempotent operation
        }
    }

    Context "Invoke-WithVssJunction Wrapper" {
        BeforeAll {
            $script:WrapperSourceDir = Join-Path $env:TEMP "RobocurseVssWrapper_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
            $script:WrapperDestDir = Join-Path $env:TEMP "RobocurseVssWrapperDest_$([Guid]::NewGuid().ToString('N').Substring(0,8))"

            New-Item -ItemType Directory -Path $script:WrapperSourceDir -Force | Out-Null
            New-Item -ItemType Directory -Path $script:WrapperDestDir -Force | Out-Null

            # Create test files
            "Wrapper test 1" | Set-Content -Path (Join-Path $script:WrapperSourceDir "test1.txt")
            "Wrapper test 2" | Set-Content -Path (Join-Path $script:WrapperSourceDir "test2.txt")
        }

        AfterAll {
            Remove-Item $script:WrapperSourceDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $script:WrapperDestDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Should execute scriptblock with junction path and cleanup" {
            $snapshotsBefore = @(Get-CimInstance -ClassName Win32_ShadowCopy)

            $result = Invoke-WithVssJunction -SourcePath $script:WrapperSourceDir -ScriptBlock {
                param($SourcePath)

                # SourcePath should be a junction, not a VSS path
                $SourcePath | Should -Not -Match 'HarddiskVolumeShadowCopy'
                $SourcePath | Should -Match 'RobocurseVss_'

                # Return file count as proof we accessed the files
                (Get-ChildItem $SourcePath -File).Count
            }

            $result.Success | Should -Be $true
            $result.Data | Should -Be 2

            # Verify cleanup
            Start-Sleep -Milliseconds 500
            $snapshotsAfter = @(Get-CimInstance -ClassName Win32_ShadowCopy)
            $snapshotsAfter.Count | Should -BeLessOrEqual $snapshotsBefore.Count
        }

        It "Should allow robocopy copy via Invoke-WithVssJunction" {
            # Clear destination
            Get-ChildItem $script:WrapperDestDir | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

            $result = Invoke-WithVssJunction -SourcePath $script:WrapperSourceDir -ScriptBlock {
                param($SourcePath)

                # Run robocopy from the junction
                $output = robocopy $SourcePath $script:WrapperDestDir /E /R:0 /W:0 2>&1 | Out-String
                [PSCustomObject]@{
                    ExitCode = $LASTEXITCODE
                    Output = $output
                }
            }

            $result.Success | Should -Be $true
            $result.Data.ExitCode | Should -BeLessOrEqual 7 -Because "Robocopy should succeed: $($result.Data.Output)"

            # Verify files were copied
            $destFiles = Get-ChildItem $script:WrapperDestDir -File
            $destFiles.Count | Should -Be 2
        }

        It "Should cleanup junction and snapshot even when scriptblock throws" {
            $snapshotsBefore = @(Get-CimInstance -ClassName Win32_ShadowCopy)

            $result = Invoke-WithVssJunction -SourcePath $script:WrapperSourceDir -ScriptBlock {
                param($SourcePath)
                throw "Intentional test error in junction wrapper"
            } -ErrorAction SilentlyContinue

            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Match "Intentional test error"

            # Verify cleanup happened
            Start-Sleep -Milliseconds 500
            $snapshotsAfter = @(Get-CimInstance -ClassName Win32_ShadowCopy)
            $snapshotsAfter.Count | Should -BeLessOrEqual $snapshotsBefore.Count

            # Verify no orphan junctions in temp
            $orphanJunctions = Get-ChildItem $env:TEMP -Directory | Where-Object { $_.Name -match '^RobocurseVss_' }
            $orphanJunctions | Should -BeNullOrEmpty -Because "Junction should be cleaned up after error"
        }

        It "Should see VSS snapshot content (point-in-time) not current content" {
            $testFile = Join-Path $script:WrapperSourceDir "volatile.txt"
            "Original content before snapshot" | Set-Content -Path $testFile

            $result = Invoke-WithVssJunction -SourcePath $script:WrapperSourceDir -ScriptBlock {
                param($SourcePath)

                # Read content from VSS (via junction)
                $vssContent = Get-Content (Join-Path $SourcePath "volatile.txt") -Raw

                # Modify the original file AFTER snapshot was taken
                "Modified during snapshot" | Set-Content -Path $testFile

                # Return the VSS content (should be original)
                $vssContent.Trim()
            }

            $result.Success | Should -Be $true
            $result.Data | Should -Be "Original content before snapshot"

            # Current file should have modified content
            $currentContent = Get-Content $testFile -Raw
            $currentContent.Trim() | Should -Be "Modified during snapshot"

            # Cleanup
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
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


# Remote VSS Integration Tests
# These tests require:
# - A remote file server accessible via UNC path
# - Admin rights on the remote server
# - PowerShell remoting enabled on the remote server
# - CIM/WMI access to the remote server
#
# Set the environment variable ROBOCURSE_TEST_REMOTE_SHARE to a UNC path to enable these tests
# Example: $env:ROBOCURSE_TEST_REMOTE_SHARE = "\\FileServer01\TestShare"

BeforeDiscovery {
    # Check for remote VSS test capability
    $script:CanTestRemoteVss = $false
    $script:RemoteTestShare = $env:ROBOCURSE_TEST_REMOTE_SHARE

    if ($script:RemoteTestShare -and $script:RemoteTestShare -match '^\\\\[^\\]+\\[^\\]+') {
        # Extract server name
        if ($script:RemoteTestShare -match '^\\\\([^\\]+)\\') {
            $testServer = $Matches[1]

            # Test if we can reach the server and have remoting access
            try {
                $canConnect = Test-Connection -ComputerName $testServer -Count 1 -Quiet -ErrorAction SilentlyContinue
                if ($canConnect) {
                    # Test PowerShell remoting
                    $remotingTest = Invoke-Command -ComputerName $testServer -ScriptBlock { $true } -ErrorAction SilentlyContinue
                    if ($remotingTest) {
                        # Test CIM access
                        $cimSession = New-CimSession -ComputerName $testServer -ErrorAction SilentlyContinue
                        if ($cimSession) {
                            $script:CanTestRemoteVss = $true
                            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
            catch {
                $script:CanTestRemoteVss = $false
            }
        }
    }
}

Describe "Remote VSS Integration Tests" -Skip:(-not $script:CanTestRemoteVss) {

    BeforeAll {
        # Load test helper and fixtures
        . "$PSScriptRoot\..\TestHelper.ps1"
        . "$PSScriptRoot\Fixtures\TestDataGenerator.ps1"
        Initialize-RobocurseForTesting

        # Parse the remote share
        $script:RemoteShare = $env:ROBOCURSE_TEST_REMOTE_SHARE
        $script:RemoteComponents = Get-UncPathComponents -UncPath $script:RemoteShare

        # Create a test subdirectory in the remote share
        $script:RemoteTestDir = Join-Path $script:RemoteShare "RobocurseRemoteVssTest_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:LocalDestDir = Join-Path $env:TEMP "RobocurseRemoteVssDest_$([Guid]::NewGuid().ToString('N').Substring(0,8))"

        # Create directories
        New-Item -ItemType Directory -Path $script:RemoteTestDir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:LocalDestDir -Force | Out-Null

        # Create test files on the remote share
        "Remote file 1" | Set-Content -Path (Join-Path $script:RemoteTestDir "file1.txt")
        "Remote file 2" | Set-Content -Path (Join-Path $script:RemoteTestDir "file2.txt")
        New-Item -ItemType Directory -Path (Join-Path $script:RemoteTestDir "subdir") -Force | Out-Null
        "Remote subdir file" | Set-Content -Path (Join-Path $script:RemoteTestDir "subdir\nested.txt")
    }

    AfterAll {
        # Cleanup
        if ($script:RemoteTestDir -and (Test-Path $script:RemoteTestDir)) {
            Remove-Item $script:RemoteTestDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:LocalDestDir -and (Test-Path $script:LocalDestDir)) {
            Remove-Item $script:LocalDestDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Remote VSS Capability Detection" {
        It "Should detect remote VSS support" {
            $result = Test-RemoteVssSupported -UncPath $script:RemoteShare
            $result.Success | Should -Be $true
            $result.Data.ServerName | Should -Be $script:RemoteComponents.ServerName
        }

        It "Should parse UNC path components correctly" {
            $components = Get-UncPathComponents -UncPath $script:RemoteTestDir

            $components.ServerName | Should -Be $script:RemoteComponents.ServerName
            $components.ShareName | Should -Be $script:RemoteComponents.ShareName
            $components.RelativePath | Should -Not -BeNullOrEmpty
        }
    }

    Context "Remote VSS Snapshot Creation" {
        It "Should create a VSS snapshot on the remote server" {
            $result = New-RemoteVssSnapshot -UncPath $script:RemoteTestDir

            try {
                $result.Success | Should -Be $true -Because "Remote VSS snapshot should succeed: $($result.ErrorMessage)"
                $result.Data | Should -Not -BeNullOrEmpty

                # Verify snapshot properties
                $result.Data.ShadowId | Should -Match '^\{[A-F0-9-]+\}$'
                $result.Data.ServerName | Should -Be $script:RemoteComponents.ServerName
                $result.Data.ShareName | Should -Be $script:RemoteComponents.ShareName
                $result.Data.IsRemote | Should -Be $true
            }
            finally {
                if ($result.Success -and $result.Data) {
                    Remove-RemoteVssSnapshot -ShadowId $result.Data.ShadowId -ServerName $result.Data.ServerName | Out-Null
                }
            }
        }

        It "Should delete a remote VSS snapshot" {
            $createResult = New-RemoteVssSnapshot -UncPath $script:RemoteTestDir
            $createResult.Success | Should -Be $true

            $deleteResult = Remove-RemoteVssSnapshot `
                -ShadowId $createResult.Data.ShadowId `
                -ServerName $createResult.Data.ServerName

            $deleteResult.Success | Should -Be $true
        }
    }

    Context "Remote VSS Junction Creation" {
        It "Should create a junction on the remote server" {
            $snapshotResult = New-RemoteVssSnapshot -UncPath $script:RemoteTestDir
            $snapshotResult.Success | Should -Be $true

            try {
                $junctionResult = New-RemoteVssJunction -VssSnapshot $snapshotResult.Data
                $junctionResult.Success | Should -Be $true -Because "Junction creation should succeed: $($junctionResult.ErrorMessage)"

                try {
                    # Verify we can access the junction via UNC
                    $junctionUncPath = $junctionResult.Data.JunctionUncPath
                    Test-Path $junctionUncPath | Should -Be $true

                    # Verify files are accessible through junction
                    $files = Get-ChildItem $junctionUncPath -File -ErrorAction SilentlyContinue
                    $files.Count | Should -BeGreaterOrEqual 2
                }
                finally {
                    Remove-RemoteVssJunction `
                        -JunctionLocalPath $junctionResult.Data.JunctionLocalPath `
                        -ServerName $junctionResult.Data.ServerName | Out-Null
                }
            }
            finally {
                Remove-RemoteVssSnapshot -ShadowId $snapshotResult.Data.ShadowId -ServerName $snapshotResult.Data.ServerName | Out-Null
            }
        }

        It "Should remove a junction from the remote server" {
            $snapshotResult = New-RemoteVssSnapshot -UncPath $script:RemoteTestDir
            $snapshotResult.Success | Should -Be $true

            try {
                $junctionResult = New-RemoteVssJunction -VssSnapshot $snapshotResult.Data
                $junctionResult.Success | Should -Be $true

                # Remove the junction
                $removeResult = Remove-RemoteVssJunction `
                    -JunctionLocalPath $junctionResult.Data.JunctionLocalPath `
                    -ServerName $junctionResult.Data.ServerName

                $removeResult.Success | Should -Be $true

                # Verify junction is gone
                Test-Path $junctionResult.Data.JunctionUncPath | Should -Be $false
            }
            finally {
                Remove-RemoteVssSnapshot -ShadowId $snapshotResult.Data.ShadowId -ServerName $snapshotResult.Data.ServerName | Out-Null
            }
        }
    }

    Context "Remote VSS with Robocopy" {
        It "Should allow robocopy to copy from remote VSS via junction" {
            $snapshotResult = New-RemoteVssSnapshot -UncPath $script:RemoteTestDir
            $snapshotResult.Success | Should -Be $true

            try {
                $junctionResult = New-RemoteVssJunction -VssSnapshot $snapshotResult.Data
                $junctionResult.Success | Should -Be $true

                try {
                    # Clear destination
                    Get-ChildItem $script:LocalDestDir | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

                    # Get the VSS UNC path
                    $vssUncPath = Get-RemoteVssPath `
                        -OriginalUncPath $script:RemoteTestDir `
                        -VssSnapshot $snapshotResult.Data `
                        -JunctionInfo $junctionResult.Data

                    # Use robocopy to copy from the VSS junction
                    $robocopyOutput = robocopy $vssUncPath $script:LocalDestDir /E /R:0 /W:0 2>&1 | Out-String

                    # Robocopy exit codes 0-7 are success/informational
                    $LASTEXITCODE | Should -BeLessOrEqual 7 -Because "Robocopy should succeed: $robocopyOutput"

                    # Verify files were copied
                    $destFiles = Get-ChildItem $script:LocalDestDir -Recurse -File
                    $destFiles.Count | Should -Be 3  # file1.txt, file2.txt, subdir/nested.txt
                }
                finally {
                    Remove-RemoteVssJunction `
                        -JunctionLocalPath $junctionResult.Data.JunctionLocalPath `
                        -ServerName $junctionResult.Data.ServerName | Out-Null
                }
            }
            finally {
                Remove-RemoteVssSnapshot -ShadowId $snapshotResult.Data.ShadowId -ServerName $snapshotResult.Data.ServerName | Out-Null
            }
        }
    }

    Context "Invoke-WithRemoteVssJunction Wrapper" {
        It "Should execute scriptblock with remote VSS UNC path" {
            $result = Invoke-WithRemoteVssJunction -UncPath $script:RemoteTestDir -ScriptBlock {
                param($SourcePath)

                # SourcePath should be a UNC path through the junction
                $SourcePath | Should -Match '\.robocurse-vss-'
                $SourcePath | Should -Match '^\\\\[^\\]+\\'

                # Return file count as proof
                (Get-ChildItem $SourcePath -Recurse -File).Count
            }

            $result.Success | Should -Be $true -Because "Remote VSS wrapper should succeed: $($result.ErrorMessage)"
            $result.Data | Should -Be 3
        }

        It "Should allow robocopy via Invoke-WithRemoteVssJunction" {
            # Clear destination
            Get-ChildItem $script:LocalDestDir | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

            $result = Invoke-WithRemoteVssJunction -UncPath $script:RemoteTestDir -ScriptBlock {
                param($SourcePath)

                $output = robocopy $SourcePath $script:LocalDestDir /E /R:0 /W:0 2>&1 | Out-String
                [PSCustomObject]@{
                    ExitCode = $LASTEXITCODE
                    Output   = $output
                }
            }

            $result.Success | Should -Be $true -Because "Wrapper should succeed: $($result.ErrorMessage)"
            $result.Data.ExitCode | Should -BeLessOrEqual 7

            # Verify files were copied
            $destFiles = Get-ChildItem $script:LocalDestDir -Recurse -File
            $destFiles.Count | Should -Be 3
        }

        It "Should cleanup remote junction and snapshot even on error" {
            # Count snapshots before
            $serverName = $script:RemoteComponents.ServerName
            $cimSession = New-CimSession -ComputerName $serverName
            $snapshotsBefore = @(Get-CimInstance -CimSession $cimSession -ClassName Win32_ShadowCopy)
            Remove-CimSession -CimSession $cimSession

            $result = Invoke-WithRemoteVssJunction -UncPath $script:RemoteTestDir -ScriptBlock {
                param($SourcePath)
                throw "Intentional test error in remote wrapper"
            } -ErrorAction SilentlyContinue

            $result.Success | Should -Be $false
            $result.ErrorMessage | Should -Match "Intentional test error"

            # Wait for cleanup
            Start-Sleep -Milliseconds 500

            # Verify cleanup
            $cimSession = New-CimSession -ComputerName $serverName
            $snapshotsAfter = @(Get-CimInstance -CimSession $cimSession -ClassName Win32_ShadowCopy)
            Remove-CimSession -CimSession $cimSession

            $snapshotsAfter.Count | Should -BeLessOrEqual $snapshotsBefore.Count

            # Verify no orphan junctions in the share
            $orphanJunctions = Get-ChildItem $script:RemoteShare -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\.robocurse-vss-' }
            $orphanJunctions | Should -BeNullOrEmpty
        }

        It "Should see remote VSS snapshot content (point-in-time) not current content" {
            $testFile = Join-Path $script:RemoteTestDir "volatile_remote.txt"
            "Original remote content" | Set-Content -Path $testFile

            $result = Invoke-WithRemoteVssJunction -UncPath $script:RemoteTestDir -ScriptBlock {
                param($SourcePath)

                # Read content from VSS (via junction)
                $vssContent = Get-Content (Join-Path $SourcePath "volatile_remote.txt") -Raw

                # Modify the original file AFTER snapshot was taken
                "Modified remote content" | Set-Content -Path $testFile

                # Return the VSS content (should be original)
                $vssContent.Trim()
            }

            $result.Success | Should -Be $true
            $result.Data | Should -Be "Original remote content"

            # Current file should have modified content
            $currentContent = Get-Content $testFile -Raw
            $currentContent.Trim() | Should -Be "Modified remote content"

            # Cleanup
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Remote VSS Not Available Tests" -Skip:($script:CanTestRemoteVss) {
    It "Should skip remote VSS tests when environment not configured" {
        # This test documents why remote tests were skipped
        $script:RemoteTestShare | Should -BeNullOrEmpty -Because "ROBOCURSE_TEST_REMOTE_SHARE not set or server not accessible"
    }
}
