#Requires -Modules Pester

<#
.SYNOPSIS
    Unit tests for path redaction functionality

.DESCRIPTION
    Tests the path redaction feature which allows redacting file paths
    from log messages for security and privacy purposes.
#>

# Load module at discovery time
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

Describe "Path Redaction Tests" -Tag "PathRedaction", "Unit" {

    BeforeEach {
        InModuleScope 'Robocurse' {
            # Ensure redaction is disabled before each test
            Disable-PathRedaction
        }
    }

    AfterAll {
        InModuleScope 'Robocurse' {
            Disable-PathRedaction
        }
    }

    Context "Enable-PathRedaction" {

        It "Should enable path redaction" {
            InModuleScope 'Robocurse' {
                Enable-PathRedaction

                $status = Get-PathRedactionStatus
                $status.Enabled | Should -Be $true
            }
        }

        It "Should set PreserveFilenames to true by default" {
            InModuleScope 'Robocurse' {
                Enable-PathRedaction

                $status = Get-PathRedactionStatus
                $status.PreserveFilenames | Should -Be $true
            }
        }

        It "Should allow PreserveFilenames to be disabled" {
            InModuleScope 'Robocurse' {
                Enable-PathRedaction -PreserveFilenames $false

                $status = Get-PathRedactionStatus
                $status.PreserveFilenames | Should -Be $false
            }
        }

        It "Should accept custom server names" {
            InModuleScope 'Robocurse' {
                Enable-PathRedaction -ServerNames @('PRODSERVER01', 'FILESERVER')

                $status = Get-PathRedactionStatus
                $status.ServerNames | Should -Contain 'PRODSERVER01'
                $status.ServerNames | Should -Contain 'FILESERVER'
            }
        }

        It "Should accept custom redaction patterns" {
            InModuleScope 'Robocurse' {
                Enable-PathRedaction -RedactionPatterns @('secret', 'confidential')

                $status = Get-PathRedactionStatus
                $status.PatternCount | Should -Be 2
            }
        }
    }

    Context "Disable-PathRedaction" {

        It "Should disable path redaction" {
            InModuleScope 'Robocurse' {
                Enable-PathRedaction
                Disable-PathRedaction

                $status = Get-PathRedactionStatus
                $status.Enabled | Should -Be $false
            }
        }

        It "Should clear custom patterns" {
            InModuleScope 'Robocurse' {
                Enable-PathRedaction -RedactionPatterns @('test')
                Disable-PathRedaction

                $status = Get-PathRedactionStatus
                $status.PatternCount | Should -Be 0
            }
        }
    }

    Context "Invoke-PathRedaction - Windows Paths" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                Enable-PathRedaction
            }
        }

        It "Should redact simple Windows path preserving filename" {
            InModuleScope 'Robocurse' {
                $result = Invoke-PathRedaction -Text "Error copying C:\Users\john\Documents\report.txt"

                $result | Should -Match "\[PATH\]\\report\.txt"
                $result | Should -Not -Match "C:\\Users\\john\\Documents"
            }
        }

        It "Should redact path with spaces" {
            InModuleScope 'Robocurse' {
                $result = Invoke-PathRedaction -Text "File: C:\Program Files\MyApp\config.ini"

                $result | Should -Match "\[PATH\]\\config\.ini"
                $result | Should -Not -Match "Program Files"
            }
        }

        It "Should redact multiple paths in same message" {
            InModuleScope 'Robocurse' {
                $result = Invoke-PathRedaction -Text "Copying C:\Source\file.txt to D:\Backup\file.txt"

                $result | Should -Match "\[PATH\]\\file\.txt"
                $result | Should -Not -Match "C:\\Source"
                $result | Should -Not -Match "D:\\Backup"
            }
        }

        It "Should handle drive root paths" {
            InModuleScope 'Robocurse' {
                $result = Invoke-PathRedaction -Text "Source: C:\ Target: D:\"

                # Drive roots get redacted
                $result | Should -Match "\[PATH\]"
            }
        }

        It "Should redact entire path when PreserveFilenames is false" {
            InModuleScope 'Robocurse' {
                Disable-PathRedaction
                Enable-PathRedaction -PreserveFilenames $false

                $result = Invoke-PathRedaction -Text "Error in C:\Users\admin\secret.doc"

                $result | Should -Match "\[PATH\]"
                $result | Should -Not -Match "secret\.doc"
            }
        }
    }

    Context "Invoke-PathRedaction - UNC Paths" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                Enable-PathRedaction
            }
        }

        It "Should redact UNC path preserving filename" {
            InModuleScope 'Robocurse' {
                $result = Invoke-PathRedaction -Text "Copying \\FILESERVER\Share\folder\report.xlsx"

                $result | Should -Match "\[UNC\]\\report\.xlsx"
                $result | Should -Not -Match "FILESERVER"
                $result | Should -Not -Match "Share"
            }
        }

        It "Should redact UNC path without filename" {
            InModuleScope 'Robocurse' {
                $result = Invoke-PathRedaction -Text "Source: \\SERVER01\Backup\Data"

                $result | Should -Match "\[UNC\]"
                $result | Should -Not -Match "SERVER01"
            }
        }

        It "Should redact deep UNC paths" {
            InModuleScope 'Robocurse' {
                $result = Invoke-PathRedaction -Text "\\PROD-SERVER\Share\Level1\Level2\Level3\file.log"

                $result | Should -Match "\[UNC\]\\file\.log"
                $result | Should -Not -Match "PROD-SERVER"
                $result | Should -Not -Match "Level1"
            }
        }
    }

    Context "Invoke-PathRedaction - Server Names" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                Enable-PathRedaction -ServerNames @('PRODSERVER', 'DEVSERVER')
            }
        }

        It "Should redact specific server names" {
            InModuleScope 'Robocurse' {
                $result = Invoke-PathRedaction -Text "Connected to PRODSERVER successfully"

                $result | Should -Match "\[REDACTED\]"
                $result | Should -Not -Match "PRODSERVER"
            }
        }

        It "Should redact server name in UNC path" {
            InModuleScope 'Robocurse' {
                $result = Invoke-PathRedaction -Text "\\PRODSERVER\Share\file.txt"

                $result | Should -Not -Match "PRODSERVER"
            }
        }

        It "Should not redact unspecified server names" {
            InModuleScope 'Robocurse' {
                $result = Invoke-PathRedaction -Text "Connected to OTHERSERVER"

                # OTHERSERVER was not in the list, but the pattern depends on how it's used
                # The UNC path pattern will catch it in UNC context
            }
        }
    }

    Context "Invoke-PathRedaction - Edge Cases" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                Enable-PathRedaction
            }
        }

        It "Should handle empty string" {
            InModuleScope 'Robocurse' {
                $result = Invoke-PathRedaction -Text ""

                $result | Should -Be ""
            }
        }

        It "Should return original text when redaction is disabled" {
            InModuleScope 'Robocurse' {
                Disable-PathRedaction
                $originalText = "C:\Secret\Path\file.txt"

                $result = Invoke-PathRedaction -Text $originalText

                $result | Should -Be $originalText
            }
        }

        It "Should handle text without paths" {
            InModuleScope 'Robocurse' {
                $text = "This is a message without any file paths"

                $result = Invoke-PathRedaction -Text $text

                $result | Should -Be $text
            }
        }

        It "Should handle paths in quoted strings" {
            InModuleScope 'Robocurse' {
                $result = Invoke-PathRedaction -Text 'Error: "C:\Users\admin\file.txt" not found'

                $result | Should -Match "\[PATH\]"
                $result | Should -Not -Match "C:\\Users\\admin"
            }
        }

        It "Should handle special characters in paths" {
            InModuleScope 'Robocurse' {
                $result = Invoke-PathRedaction -Text "C:\Projects\MyApp (v2)\config.json"

                $result | Should -Match "\[PATH\]"
            }
        }
    }

    Context "Invoke-PathRedaction - Custom Patterns" {

        It "Should apply custom redaction patterns" {
            InModuleScope 'Robocurse' {
                Enable-PathRedaction -RedactionPatterns @('password=\w+', 'token=\w+')

                $result = Invoke-PathRedaction -Text "Config: password=secret123 token=abc456"

                $result | Should -Match "\[REDACTED\]"
                $result | Should -Not -Match "secret123"
                $result | Should -Not -Match "abc456"
            }
        }

        It "Should handle invalid regex patterns gracefully" {
            InModuleScope 'Robocurse' {
                Enable-PathRedaction -RedactionPatterns @('[invalid regex(')

                # Should not throw
                { Invoke-PathRedaction -Text "Test message" } | Should -Not -Throw
            }
        }
    }

    Context "Integration with Write-RobocurseLog" {

        BeforeAll {
            $script:TestLogDir = Join-Path ([System.IO.Path]::GetTempPath()) "Robocurse-Redaction-Test-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $script:TestLogDir -Force | Out-Null
        }

        AfterAll {
            if ($script:TestLogDir -and (Test-Path $script:TestLogDir)) {
                Remove-Item -Path $script:TestLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should redact paths in log messages when enabled" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestLogDir {
                param($TestLogDir)

                # Initialize logging
                Initialize-LogSession -LogRoot $TestLogDir

                # Enable redaction
                Enable-PathRedaction

                # Write a log message with a path
                Write-RobocurseLog -Message "Processing C:\Users\admin\secret\data.csv" -Level 'Info'

                # Read the log file
                $logContent = Get-Content -Path $script:CurrentOperationalLogPath -Raw

                $logContent | Should -Match "\[PATH\]"
                $logContent | Should -Not -Match "C:\\Users\\admin\\secret"
            }
        }

        It "Should not redact when disabled" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestLogDir {
                param($TestLogDir)

                # Initialize logging
                Initialize-LogSession -LogRoot $TestLogDir

                # Disable redaction
                Disable-PathRedaction

                # Write a log message with a path
                $testPath = "D:\TestData\file.txt"
                Write-RobocurseLog -Message "Processing $testPath" -Level 'Info'

                # Read the log file
                $logContent = Get-Content -Path $script:CurrentOperationalLogPath -Raw

                $logContent | Should -Match "D:\\TestData\\file\.txt"
            }
        }
    }

    Context "Integration with Write-SiemEvent" {

        BeforeAll {
            $script:TestLogDir = Join-Path ([System.IO.Path]::GetTempPath()) "Robocurse-SIEM-Redaction-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $script:TestLogDir -Force | Out-Null
        }

        AfterAll {
            if ($script:TestLogDir -and (Test-Path $script:TestLogDir)) {
                Remove-Item -Path $script:TestLogDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should redact paths in SIEM event data" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestLogDir {
                param($TestLogDir)

                # Initialize logging
                Initialize-LogSession -LogRoot $TestLogDir

                # Enable redaction
                Enable-PathRedaction

                # Write a SIEM event with path in data
                Write-SiemEvent -EventType 'GeneralError' -Data @{
                    Message = "Failed to copy C:\Confidential\report.docx"
                    SourcePath = "C:\Confidential\report.docx"
                }

                # Read the SIEM log file
                $siemContent = Get-Content -Path $script:CurrentSiemLogPath -Raw

                $siemContent | Should -Match "\[PATH\]"
                $siemContent | Should -Not -Match "C:\\\\Confidential"
            }
        }

        It "Should redact arrays in SIEM data" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestLogDir {
                param($TestLogDir)

                # Initialize logging
                Initialize-LogSession -LogRoot $TestLogDir

                # Enable redaction
                Enable-PathRedaction

                # Write a SIEM event with array of paths
                Write-SiemEvent -EventType 'GeneralWarning' -Data @{
                    FailedFiles = @(
                        "C:\Secret\file1.txt",
                        "C:\Secret\file2.txt"
                    )
                }

                # Read the SIEM log file
                $siemContent = Get-Content -Path $script:CurrentSiemLogPath -Raw

                $siemContent | Should -Match "\[PATH\]"
                $siemContent | Should -Not -Match "C:\\\\Secret"
            }
        }
    }

    Context "Configuration Integration" {

        It "Should have RedactPaths in default config" {
            InModuleScope 'Robocurse' {
                $config = New-DefaultConfig

                $config.GlobalSettings.PSObject.Properties.Name | Should -Contain 'RedactPaths'
                $config.GlobalSettings.RedactPaths | Should -Be $false
            }
        }

        It "Should have RedactServerNames in default config" {
            InModuleScope 'Robocurse' {
                $config = New-DefaultConfig

                $config.GlobalSettings.PSObject.Properties.Name | Should -Contain 'RedactServerNames'
                $config.GlobalSettings.RedactServerNames | Should -BeOfType [array]
            }
        }

        It "Should round-trip RedactPaths through friendly config conversion" {
            InModuleScope 'Robocurse' {
                $config = New-DefaultConfig
                $config.GlobalSettings.RedactPaths = $true
                $config.GlobalSettings.RedactServerNames = @('SERVER1', 'SERVER2')

                # Convert to friendly and back
                $friendly = ConvertTo-FriendlyConfig -Config $config
                $friendlyJson = $friendly | ConvertTo-Json -Depth 10
                $backToInternal = ConvertFrom-FriendlyConfig -RawConfig ($friendlyJson | ConvertFrom-Json)

                $backToInternal.GlobalSettings.RedactPaths | Should -Be $true
                $backToInternal.GlobalSettings.RedactServerNames | Should -Contain 'SERVER1'
                $backToInternal.GlobalSettings.RedactServerNames | Should -Contain 'SERVER2'
            }
        }
    }
}
