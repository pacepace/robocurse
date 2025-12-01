Describe "Logging" {
    BeforeAll {
        . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
    }

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
}
