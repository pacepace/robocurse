#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type (required for module isolation when running all tests together)
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "Logging" {
        BeforeEach {
            $script:TestLogRoot = "$TestDrive\Logs"
        }

        Context "Initialize-LogSession" {
            It "Should create log directory structure" {
                $session = Initialize-LogSession -LogRoot $script:TestLogRoot

                Test-Path $session.OperationalLogPath | Should -Be $true
                Test-Path $session.SiemLogPath | Should -Be $true
                $session.SessionId | Should -Not -BeNullOrEmpty
            }

            It "Should generate unique session IDs" {
                $session1 = Initialize-LogSession -LogRoot $script:TestLogRoot
                Start-Sleep -Milliseconds 100
                $session2 = Initialize-LogSession -LogRoot $script:TestLogRoot

                $session1.SessionId | Should -Not -Be $session2.SessionId
            }
        }

        Context "Write-RobocurseLog" {
            BeforeEach {
                $script:Session = Initialize-LogSession -LogRoot $script:TestLogRoot
            }

            It "Should write formatted log entry" {
                Write-RobocurseLog -Message "Test message" -Level "Info" -Component "Test"

                $content = Get-Content $script:Session.OperationalLogPath
                $content | Should -Match "Test message"
                $content | Should -Match "\[INFO\]"
                $content | Should -Match "\[Test\]"
            }

            It "Should include timestamp" {
                Write-RobocurseLog -Message "Timestamp test" -Level "Info"

                $content = Get-Content $script:Session.OperationalLogPath
                $content | Should -Match "\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"
            }
        }

        Context "Logging Before Initialization" {
            BeforeEach {
                # Ensure no session
                $script:CurrentOperationalLogPath = $null
                $script:CurrentSiemLogPath = $null
            }

            It "Should not throw when logging Info before initialization" {
                { Write-RobocurseLog -Message "Test" -Level "Info" } | Should -Not -Throw
            }

            It "Should not throw when logging Debug before initialization" {
                { Write-RobocurseLog -Message "Test" -Level "Debug" } | Should -Not -Throw
            }

            It "Should output warnings to console when no session" {
                $output = Write-RobocurseLog -Message "Test warning" -Level "Warning" 3>&1
                $output | Should -Match "Test warning"
            }

            It "Should output errors to console when no session" {
                # Use -ErrorVariable to capture the error without triggering test failure
                $output = Write-RobocurseLog -Message "Test error" -Level "Error" -ErrorAction SilentlyContinue -ErrorVariable capturedError
                # The error should be captured in the error variable
                $capturedError | Should -Match "Test error"
            }

            It "Should silently skip Info messages when no session" {
                # Should not produce any output
                $warningOutput = Write-RobocurseLog -Message "Info msg" -Level "Info" 3>&1
                $warningOutput | Should -BeNullOrEmpty
            }

            It "Should silently skip Debug messages when no session" {
                # Should not produce any output
                $warningOutput = Write-RobocurseLog -Message "Debug msg" -Level "Debug" 3>&1
                $warningOutput | Should -BeNullOrEmpty
            }

            It "Should not throw when writing SIEM event before initialization" {
                { Write-SiemEvent -EventType "SessionStart" -Data @{ test = "value" } } | Should -Not -Throw
            }
        }

        Context "MinLogLevel Filtering" {
            BeforeEach {
                $script:Session = Initialize-LogSession -LogRoot $script:TestLogRoot
            }

            AfterEach {
                # Reset to default
                $script:MinLogLevel = 'Info'
            }

            It "Should filter Debug messages when MinLogLevel is Info" {
                $script:MinLogLevel = 'Info'

                Write-RobocurseLog -Message "Debug message" -Level "Debug"
                Write-RobocurseLog -Message "Info message" -Level "Info"

                $content = Get-Content $script:Session.OperationalLogPath -Raw
                $content | Should -Not -Match "Debug message"
                $content | Should -Match "Info message"
            }

            It "Should allow Debug messages when MinLogLevel is Debug" {
                $script:MinLogLevel = 'Debug'

                Write-RobocurseLog -Message "Debug message" -Level "Debug"

                $content = Get-Content $script:Session.OperationalLogPath -Raw
                $content | Should -Match "Debug message"
            }

            It "Should filter Info and Debug when MinLogLevel is Warning" {
                $script:MinLogLevel = 'Warning'

                Write-RobocurseLog -Message "Debug msg" -Level "Debug"
                Write-RobocurseLog -Message "Info msg" -Level "Info"
                Write-RobocurseLog -Message "Warning msg" -Level "Warning"

                $content = Get-Content $script:Session.OperationalLogPath -Raw
                $content | Should -Not -Match "Debug msg"
                $content | Should -Not -Match "Info msg"
                $content | Should -Match "Warning msg"
            }

            It "Should only allow Error when MinLogLevel is Error" {
                $script:MinLogLevel = 'Error'

                Write-RobocurseLog -Message "Warning msg" -Level "Warning"
                Write-RobocurseLog -Message "Error msg" -Level "Error"

                $content = Get-Content $script:Session.OperationalLogPath -Raw
                $content | Should -Not -Match "Warning msg"
                $content | Should -Match "Error msg"
            }

            It "Test-ShouldLog should return correct values" {
                $script:MinLogLevel = 'Info'

                Test-ShouldLog -Level 'Debug' | Should -Be $false
                Test-ShouldLog -Level 'Info' | Should -Be $true
                Test-ShouldLog -Level 'Warning' | Should -Be $true
                Test-ShouldLog -Level 'Error' | Should -Be $true
            }
        }

        Context "Caller Information in Logs" {
            BeforeEach {
                $script:Session = Initialize-LogSession -LogRoot $script:TestLogRoot
            }

            It "Should include caller function name in log entry" {
                # Define a wrapper function to test caller detection
                function Test-CallerLogging {
                    Write-RobocurseLog -Message "Called from Test-CallerLogging" -Level "Info"
                }

                Test-CallerLogging

                $content = Get-Content $script:Session.OperationalLogPath -Raw
                $content | Should -Match "Test-CallerLogging"
            }

            It "Should include line number in log entry" {
                Write-RobocurseLog -Message "Line number test" -Level "Info"

                $content = Get-Content $script:Session.OperationalLogPath -Raw
                # Should contain a line reference like ":XX" where XX is the line number
                $content | Should -Match ":\d+"
            }

            It "Should format caller info consistently" {
                function Test-FormattedCaller {
                    Write-RobocurseLog -Message "Format test" -Level "Warning"
                }

                Test-FormattedCaller

                $content = Get-Content $script:Session.OperationalLogPath -Raw
                # Should contain caller info in format "FunctionName:LineNumber"
                $content | Should -Match "Test-FormattedCaller:\d+"
            }

            It "Should handle nested function calls" {
                function Outer-Function {
                    Inner-Function
                }
                function Inner-Function {
                    Write-RobocurseLog -Message "Nested call" -Level "Info"
                }

                Outer-Function

                $content = Get-Content $script:Session.OperationalLogPath -Raw
                # Should show the immediate caller (Inner-Function), not Outer-Function
                $content | Should -Match "Inner-Function"
            }
        }

        Context "Write-SiemEvent" {
            BeforeEach {
                $script:Session = Initialize-LogSession -LogRoot $script:TestLogRoot
            }

            It "Should write valid JSON" {
                Write-SiemEvent -EventType "SessionStart" -Data @{ test = "value" }

                $content = Get-Content $script:Session.SiemLogPath
                { $content | ConvertFrom-Json } | Should -Not -Throw
            }

            It "Should include required SIEM fields" {
                Write-SiemEvent -EventType "SessionStart" -Data @{ }

                $content = Get-Content $script:Session.SiemLogPath
                $event = $content | ConvertFrom-Json

                $event.timestamp | Should -Not -BeNullOrEmpty
                $event.event | Should -Be "SessionStart"
                $event.sessionId | Should -Not -BeNullOrEmpty
                $event.user | Should -Not -BeNullOrEmpty
                $event.machine | Should -Not -BeNullOrEmpty
            }

            It "Should use ISO 8601 timestamp format" {
                Write-SiemEvent -EventType "SessionStart"

                $content = Get-Content $script:Session.SiemLogPath -Raw

                # ISO 8601 format: 2024-01-15T14:32:45.123Z
                # Check the raw JSON string before ConvertFrom-Json converts it to DateTime
                $content | Should -Match '"timestamp":"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z)"'
            }
        }

        Context "Invoke-LogRotation" {
            It "Should compress old directories" {
                # Create old log directory
                $oldDate = (Get-Date).AddDays(-10).ToString("yyyy-MM-dd")
                $oldDir = New-Item -Path "$script:TestLogRoot\$oldDate" -ItemType Directory
                "test" | Set-Content "$oldDir\test.log"

                Invoke-LogRotation -LogRoot $script:TestLogRoot -CompressAfterDays 7

                Test-Path "$script:TestLogRoot\$oldDate.zip" | Should -Be $true
                Test-Path "$script:TestLogRoot\$oldDate" | Should -Be $false
            }

            It "Should delete ancient archives" {
                # Create very old archive
                $ancientDate = (Get-Date).AddDays(-60).ToString("yyyy-MM-dd")
                $null = New-Item -Path "$script:TestLogRoot\$ancientDate.zip" -ItemType File

                Invoke-LogRotation -LogRoot $script:TestLogRoot -DeleteAfterDays 30

                Test-Path "$script:TestLogRoot\$ancientDate.zip" | Should -Be $false
            }
        }

        Context "CompressAfterDays Validation" {
            It "Should emit verbose message when CompressAfterDays >= DeleteAfterDays" {
                # CompressAfterDays should be less than DeleteAfterDays
                # Auto-adjustment is logged via Write-Verbose (not noisy Write-Warning)
                Mock Write-Verbose { }

                $null = Initialize-LogSession -LogRoot $script:TestLogRoot `
                    -CompressAfterDays 30 -DeleteAfterDays 30

                Should -Invoke Write-Verbose -Times 1 -ParameterFilter {
                    $Message -match "Auto-adjusted CompressAfterDays"
                }
            }

            It "Should adjust CompressAfterDays when it equals DeleteAfterDays" {
                # This should not throw, but should adjust internally
                { Initialize-LogSession -LogRoot $script:TestLogRoot `
                    -CompressAfterDays 30 -DeleteAfterDays 30 } | Should -Not -Throw
            }

            It "Should work correctly when CompressAfterDays < DeleteAfterDays" {
                { Initialize-LogSession -LogRoot $script:TestLogRoot `
                    -CompressAfterDays 7 -DeleteAfterDays 30 } | Should -Not -Throw
            }

            It "Should reject CompressAfterDays out of range (too high)" {
                { Initialize-LogSession -LogRoot $script:TestLogRoot `
                    -CompressAfterDays 500 -DeleteAfterDays 30 } | Should -Throw
            }

            It "Should reject DeleteAfterDays out of range (too high)" {
                { Initialize-LogSession -LogRoot $script:TestLogRoot `
                    -CompressAfterDays 7 -DeleteAfterDays 5000 } | Should -Throw
            }
        }

        Context "Log Path Resolution" {
            # Tests for the fix ensuring log paths are resolved from original config location,
            # not from temp snapshot location (which would put logs in TEMP instead of .\Logs)

            It "Should resolve relative log path from config directory" {
                # Setup: Create a config in a specific directory with relative LogPath
                $configDir = Join-Path $TestDrive "MyApp"
                $null = New-Item -ItemType Directory -Path $configDir -Force
                $configPath = Join-Path $configDir "Robocurse.config.json"

                $config = @{
                    version = "1.0"
                    global = @{
                        logging = @{
                            operationalLog = @{ path = ".\Logs" }
                        }
                    }
                    profiles = @{}
                }
                $config | ConvertTo-Json -Depth 10 | Set-Content $configPath

                # Read config and resolve path the same way GUI does
                $loadedConfig = Get-RobocurseConfig -Path $configPath
                $logRoot = if ($loadedConfig.GlobalSettings.LogPath) { $loadedConfig.GlobalSettings.LogPath } else { '.\Logs' }
                if (-not [System.IO.Path]::IsPathRooted($logRoot)) {
                    $resolvedConfigDir = Split-Path -Parent $configPath
                    $logRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedConfigDir $logRoot))
                }

                # Should resolve to MyApp\Logs, not current directory\Logs
                $expectedPath = Join-Path $configDir "Logs"
                $logRoot | Should -Be $expectedPath
            }

            It "Should preserve absolute log paths unchanged" {
                $configDir = Join-Path $TestDrive "Config"
                $null = New-Item -ItemType Directory -Path $configDir -Force
                $configPath = Join-Path $configDir "Robocurse.config.json"

                # Use absolute path in config
                $absoluteLogPath = Join-Path $TestDrive "AbsoluteLogs"
                $config = @{
                    version = "1.0"
                    global = @{
                        logging = @{
                            operationalLog = @{ path = $absoluteLogPath }
                        }
                    }
                    profiles = @{}
                }
                $config | ConvertTo-Json -Depth 10 | Set-Content $configPath

                $loadedConfig = Get-RobocurseConfig -Path $configPath
                $logRoot = $loadedConfig.GlobalSettings.LogPath

                # Absolute path should be preserved as-is
                $logRoot | Should -Be $absoluteLogPath
            }

            It "Should NOT resolve relative path from temp snapshot location" {
                # This tests the bug fix: when config is copied to TEMP as a snapshot,
                # .\Logs should still resolve relative to ORIGINAL config location

                # Setup original config
                $originalConfigDir = Join-Path $TestDrive "OriginalLocation"
                $null = New-Item -ItemType Directory -Path $originalConfigDir -Force
                $originalConfigPath = Join-Path $originalConfigDir "Robocurse.config.json"

                $config = @{
                    version = "1.0"
                    global = @{
                        logging = @{
                            operationalLog = @{ path = ".\Logs" }
                        }
                    }
                    profiles = @{}
                }
                $config | ConvertTo-Json -Depth 10 | Set-Content $originalConfigPath

                # Simulate creating a temp snapshot (like GUI does)
                $tempSnapshotPath = Join-Path $TestDrive "TempSnapshot\config-snapshot.json"
                $null = New-Item -ItemType Directory -Path (Split-Path $tempSnapshotPath -Parent) -Force
                Copy-Item $originalConfigPath $tempSnapshotPath

                # Compute LogRoot the CORRECT way (from original config location)
                $loadedConfig = Get-RobocurseConfig -Path $originalConfigPath
                $logRoot = if ($loadedConfig.GlobalSettings.LogPath) { $loadedConfig.GlobalSettings.LogPath } else { '.\Logs' }
                if (-not [System.IO.Path]::IsPathRooted($logRoot)) {
                    $configDir = Split-Path -Parent $originalConfigPath  # Use ORIGINAL path
                    $logRoot = [System.IO.Path]::GetFullPath((Join-Path $configDir $logRoot))
                }

                # Should resolve to OriginalLocation\Logs, NOT TempSnapshot\Logs
                $expectedPath = Join-Path $originalConfigDir "Logs"
                $logRoot | Should -Be $expectedPath

                # And definitely NOT the temp location
                $wrongPath = Join-Path (Split-Path $tempSnapshotPath -Parent) "Logs"
                $logRoot | Should -Not -Be $wrongPath
            }

            It "Should use default .\Logs when LogPath not specified in config" {
                $configDir = Join-Path $TestDrive "NoLogPath"
                $null = New-Item -ItemType Directory -Path $configDir -Force
                $configPath = Join-Path $configDir "Robocurse.config.json"

                # Config without logging.operationalLog.path
                $config = @{
                    version = "1.0"
                    global = @{}
                    profiles = @{}
                }
                $config | ConvertTo-Json -Depth 10 | Set-Content $configPath

                $loadedConfig = Get-RobocurseConfig -Path $configPath
                $logRoot = if ($loadedConfig.GlobalSettings.LogPath) { $loadedConfig.GlobalSettings.LogPath } else { '.\Logs' }
                if (-not [System.IO.Path]::IsPathRooted($logRoot)) {
                    $resolvedConfigDir = Split-Path -Parent $configPath
                    $logRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedConfigDir $logRoot))
                }

                $expectedPath = Join-Path $configDir "Logs"
                $logRoot | Should -Be $expectedPath
            }
        }

        Context "Set-OrchestrationSessionId" {
            It "Should set the orchestration session ID" {
                $testSessionId = "test-guid-12345"
                Set-OrchestrationSessionId -SessionId $testSessionId

                $script:CurrentOrchestrationSessionId | Should -Be $testSessionId
            }

            It "Should accept GUID format session IDs" {
                $guidSessionId = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
                Set-OrchestrationSessionId -SessionId $guidSessionId

                $script:CurrentOrchestrationSessionId | Should -Be $guidSessionId
            }
        }

        Context "Get-LogPath with Session ID" {
            BeforeEach {
                $script:Session = Initialize-LogSession -LogRoot $script:TestLogRoot
            }

            It "Should include session ID in ChunkJob path when set" {
                $testSessionId = "test-session-id"
                Set-OrchestrationSessionId -SessionId $testSessionId

                $chunkPath = Get-LogPath -Type 'ChunkJob' -ChunkId 1

                $chunkPath | Should -Match "${testSessionId}_Chunk_001\.log$"
            }

            It "Should not include session prefix when session ID is not set" {
                # Clear the session ID
                $script:CurrentOrchestrationSessionId = $null

                $chunkPath = Get-LogPath -Type 'ChunkJob' -ChunkId 5

                $chunkPath | Should -Match "Chunk_005\.log$"
                $chunkPath | Should -Not -Match "_Chunk_"
            }

            It "Should format chunk ID with leading zeros" {
                $testSessionId = "session-xyz"
                Set-OrchestrationSessionId -SessionId $testSessionId

                $chunkPath1 = Get-LogPath -Type 'ChunkJob' -ChunkId 1
                $chunkPath10 = Get-LogPath -Type 'ChunkJob' -ChunkId 10
                $chunkPath100 = Get-LogPath -Type 'ChunkJob' -ChunkId 100

                $chunkPath1 | Should -Match "Chunk_001\.log$"
                $chunkPath10 | Should -Match "Chunk_010\.log$"
                $chunkPath100 | Should -Match "Chunk_100\.log$"
            }

            It "Should place chunk logs in Jobs folder" {
                $testSessionId = "session-abc"
                Set-OrchestrationSessionId -SessionId $testSessionId

                $chunkPath = Get-LogPath -Type 'ChunkJob' -ChunkId 1

                $parentFolder = Split-Path -Leaf (Split-Path -Parent $chunkPath)
                $parentFolder | Should -Be "Jobs"
            }
        }
    }
}
