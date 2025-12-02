#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

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
                $output = Write-RobocurseLog -Message "Test error" -Level "Error" 2>&1
                $output | Should -Match "Test error"
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
            It "Should emit warning when CompressAfterDays >= DeleteAfterDays" {
                # CompressAfterDays should be less than DeleteAfterDays
                # Use Pester's Should -Invoke to verify Write-Warning is called
                Mock Write-Warning { }

                $null = Initialize-LogSession -LogRoot $script:TestLogRoot `
                    -CompressAfterDays 30 -DeleteAfterDays 30

                Should -Invoke Write-Warning -Times 1 -ParameterFilter {
                    $Message -match "CompressAfterDays.*should be less than"
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
    }
}
