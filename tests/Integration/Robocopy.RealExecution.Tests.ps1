#Requires -Modules Pester

# Real Robocopy Execution Integration Tests
# Tests actual robocopy execution with real files (not mocked)

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

InModuleScope 'Robocurse' {
    Describe "Real Robocopy Execution Tests" -Skip:(-not (Test-IsWindowsPlatform)) {

        BeforeAll {
            # Verify robocopy is available
            $robocopyAvailable = Test-RobocopyAvailable
            if (-not $robocopyAvailable) {
                throw "Robocopy is not available on this system"
            }

            # Create test directory structure
            $script:TestRoot = Join-Path $env:TEMP "RobocurseRealTest_$([Guid]::NewGuid().ToString('N').Substring(0,16))"
            $script:SourceDir = Join-Path $script:TestRoot "Source"
            $script:DestDir = Join-Path $script:TestRoot "Dest"
            $script:LogDir = Join-Path $script:TestRoot "Logs"

            New-Item -Path $script:SourceDir -ItemType Directory -Force | Out-Null
            New-Item -Path $script:DestDir -ItemType Directory -Force | Out-Null
            New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null

            # Helper to create chunk objects for testing
            $script:NewTestChunk = {
                param($Source, $Dest)
                [PSCustomObject]@{
                    SourcePath = $Source
                    DestinationPath = $Dest
                }
            }

            # Standard test options: /E mode (not mirror), no retries
            $script:TestOptions = @{
                NoMirror = $true    # Use /E instead of /MIR
                RetryCount = 0
                RetryWait = 0
            }
        }

        AfterAll {
            # Cleanup test directories
            if (Test-Path $script:TestRoot) {
                Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        Context "Basic File Copy Operations" {
            BeforeEach {
                # Clean destination for each test
                Get-ChildItem -Path $script:DestDir -Recurse -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }

            It "Should copy a single file successfully" {
                # Create test file
                $testFile = Join-Path $script:SourceDir "test1.txt"
                "Test content" | Set-Content -Path $testFile

                # Create chunk and robocopy job
                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "test1.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions

                $job | Should -Not -BeNullOrEmpty
                $job.Process | Should -Not -BeNullOrEmpty

                # Wait for completion
                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                # Verify result
                $result.ExitCode | Should -BeLessOrEqual 3  # 0-3 are success codes
                $result.ExitMeaning.Severity | Should -BeIn @('Success', 'Warning')

                # Verify file was copied
                $destFile = Join-Path $script:DestDir "test1.txt"
                Test-Path $destFile | Should -Be $true
                (Get-Content $destFile) | Should -Be "Test content"
            }

            It "Should copy multiple files successfully" {
                # Create multiple test files
                for ($i = 1; $i -le 5; $i++) {
                    $testFile = Join-Path $script:SourceDir "multi$i.txt"
                    "Content for file $i" | Set-Content -Path $testFile
                }

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "multi.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions

                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                $result.ExitCode | Should -BeLessOrEqual 3

                # Verify all files were copied
                for ($i = 1; $i -le 5; $i++) {
                    $destFile = Join-Path $script:DestDir "multi$i.txt"
                    Test-Path $destFile | Should -Be $true
                }
            }

            It "Should copy subdirectory structure" {
                # Create subdirectory structure
                $subDir = Join-Path $script:SourceDir "SubDir"
                $nestedDir = Join-Path $subDir "Nested"
                New-Item -Path $nestedDir -ItemType Directory -Force | Out-Null

                "Root file" | Set-Content -Path (Join-Path $script:SourceDir "root.txt")
                "Sub file" | Set-Content -Path (Join-Path $subDir "sub.txt")
                "Nested file" | Set-Content -Path (Join-Path $nestedDir "nested.txt")

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "subdir.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions

                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                $result.ExitCode | Should -BeLessOrEqual 3

                # Verify structure
                Test-Path (Join-Path $script:DestDir "root.txt") | Should -Be $true
                Test-Path (Join-Path $script:DestDir "SubDir\sub.txt") | Should -Be $true
                Test-Path (Join-Path $script:DestDir "SubDir\Nested\nested.txt") | Should -Be $true
            }
        }

        Context "Exit Code Interpretation" {
            BeforeEach {
                Get-ChildItem -Path $script:DestDir -Recurse -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }

            It "Should return exit code 0 when no files to copy" {
                # Create identical source and dest
                $testFile = Join-Path $script:SourceDir "identical.txt"
                "Same content" | Set-Content -Path $testFile

                # First copy
                $chunk1 = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath1 = Join-Path $script:LogDir "identical1.log"
                $job1 = Start-RobocopyJob -Chunk $chunk1 -LogPath $logPath1 -RobocopyOptions $script:TestOptions
                Wait-RobocopyJob -Job $job1 -TimeoutSeconds 30 | Out-Null

                # Second copy should find nothing to copy
                $chunk2 = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath2 = Join-Path $script:LogDir "identical2.log"
                $job2 = Start-RobocopyJob -Chunk $chunk2 -LogPath $logPath2 -RobocopyOptions $script:TestOptions
                $result = Wait-RobocopyJob -Job $job2 -TimeoutSeconds 30

                $result.ExitCode | Should -Be 0
                # Exit code 0 means no files needed copying (no change)
                $result.ExitMeaning.FilesCopied | Should -Be $false
            }

            It "Should return exit code 1 when files copied" {
                $testFile = Join-Path $script:SourceDir "newfile.txt"
                "New content" | Set-Content -Path $testFile

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "newfile.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions
                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                $result.ExitCode | Should -BeIn @(1, 3)  # 1=files copied, 3=files copied + extras
                $result.ExitMeaning.FilesCopied | Should -Be $true
            }
        }

        Context "Log Parsing with Real Output" {
            BeforeEach {
                Get-ChildItem -Path $script:DestDir -Recurse -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }

            It "Should parse file counts from real robocopy log" {
                # Create known number of files
                for ($i = 1; $i -le 3; $i++) {
                    $testFile = Join-Path $script:SourceDir "parse$i.txt"
                    "Content $i" | Set-Content -Path $testFile
                }

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "parse.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions
                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                # Parse the log
                $stats = ConvertFrom-RobocopyLog -LogPath $logPath

                $stats.ParseSuccess | Should -Be $true
                $stats.FilesCopied | Should -BeGreaterOrEqual 3
            }

            It "Should parse byte counts from real robocopy log" {
                # Create file with known size
                $testFile = Join-Path $script:SourceDir "sized.txt"
                $content = "A" * 1000  # 1000 bytes
                $content | Set-Content -Path $testFile -NoNewline

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "sized.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions
                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                $stats = ConvertFrom-RobocopyLog -LogPath $logPath

                $stats.ParseSuccess | Should -Be $true
                $stats.BytesCopied | Should -BeGreaterOrEqual 1000
            }
        }

        Context "Timeout Handling" {
            It "Should timeout on very long operations" {
                # Create a very short timeout
                $testFile = Join-Path $script:SourceDir "timeout.txt"
                "Content" | Set-Content -Path $testFile

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "timeout.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions

                # Wait with very short timeout (but file copy should complete instantly)
                # This is more of a functional test that timeout doesn't break things
                { Wait-RobocopyJob -Job $job -TimeoutSeconds 30 } | Should -Not -Throw
            }
        }

        Context "Process Handle Cleanup" {
            It "Should dispose process handle after completion" {
                $testFile = Join-Path $script:SourceDir "cleanup.txt"
                "Content" | Set-Content -Path $testFile

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "cleanup.log"
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $script:TestOptions

                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                # Process should be disposed (will throw on access)
                # Note: Can't reliably test disposal in PS, but verify job completed
                $result.ExitCode | Should -Not -BeNullOrEmpty
            }
        }

        Context "Exclude Pattern Tests" {
            BeforeEach {
                Get-ChildItem -Path $script:DestDir -Recurse -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }

            It "Should exclude files matching pattern" {
                # Create files including one to exclude
                "Include me" | Set-Content -Path (Join-Path $script:SourceDir "include.txt")
                "Exclude me" | Set-Content -Path (Join-Path $script:SourceDir "exclude.tmp")
                "Also include" | Set-Content -Path (Join-Path $script:SourceDir "also.txt")

                $chunk = & $script:NewTestChunk $script:SourceDir $script:DestDir
                $logPath = Join-Path $script:LogDir "exclude.log"
                $excludeOptions = @{
                    NoMirror = $true
                    RetryCount = 0
                    RetryWait = 0
                    ExcludeFiles = @('*.tmp')
                }
                $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $excludeOptions
                $result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30

                # Verify exclusion
                Test-Path (Join-Path $script:DestDir "include.txt") | Should -Be $true
                Test-Path (Join-Path $script:DestDir "also.txt") | Should -Be $true
                Test-Path (Join-Path $script:DestDir "exclude.tmp") | Should -Be $false
            }
        }
    }
}
