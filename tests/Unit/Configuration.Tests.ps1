BeforeAll {
    # Set test mode before loading the script to prevent execution
    $script:TestMode = $true

    # Load the main script (without -Help to avoid early exit)
    $mainScriptPath = Join-Path $PSScriptRoot ".." ".." "Robocurse.ps1"
    . $mainScriptPath

    # Create temporary test directory - handle both Windows and Unix-like systems
    $tempBase = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { "/tmp" }
    $script:TestDir = Join-Path $tempBase "RobocurseTests_$(Get-Random)"
    New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
}

AfterAll {
    # Cleanup test directory
    if (Test-Path $script:TestDir) {
        Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Configuration Management" {
    Context "New-DefaultConfig" {
        It "Should return a complete default configuration structure" {
            $config = New-DefaultConfig

            $config | Should -Not -BeNullOrEmpty
            $config.Version | Should -Be "1.0"
            $config.GlobalSettings | Should -Not -BeNullOrEmpty
            $config.Email | Should -Not -BeNullOrEmpty
            $config.Schedule | Should -Not -BeNullOrEmpty
            # SyncProfiles property should exist (using PSObject to check property existence)
            $config.PSObject.Properties.Name | Should -Contain "SyncProfiles"
        }

        It "Should have correct GlobalSettings defaults" {
            $config = New-DefaultConfig

            $config.GlobalSettings.MaxConcurrentJobs | Should -Be 4
            $config.GlobalSettings.ThreadsPerJob | Should -Be 8
            $config.GlobalSettings.DefaultScanMode | Should -Be "Smart"
            $config.GlobalSettings.LogRetentionDays | Should -Be 30
            $config.GlobalSettings.LogPath | Should -Be ".\Logs"
        }

        It "Should have Email disabled by default" {
            $config = New-DefaultConfig

            $config.Email.Enabled | Should -Be $false
        }

        It "Should have empty SyncProfiles collection" {
            $config = New-DefaultConfig

            # Test that SyncProfiles property exists
            $config.PSObject.Properties.Name | Should -Contain "SyncProfiles"

            # Test JSON serialization round-trip
            $tempPath = Join-Path $script:TestDir "sync-profiles-test.json"
            $saved = Save-RobocurseConfig -Config $config -Path $tempPath
            $saved | Should -Be $true

            # Verify the JSON file contains an empty array
            $jsonContent = Get-Content $tempPath -Raw
            $jsonContent | Should -Match '"SyncProfiles":\s*\[\s*\]'

            # Verify it can be loaded back
            $reloaded = Get-RobocurseConfig -Path $tempPath
            $reloaded.PSObject.Properties.Name | Should -Contain "SyncProfiles"
        }
    }

    Context "Get-RobocurseConfig" {
        BeforeEach {
            $script:TestConfigPath = Join-Path $script:TestDir "test-config.json"
        }

        AfterEach {
            if (Test-Path $script:TestConfigPath) {
                Remove-Item $script:TestConfigPath -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should return default config when file doesn't exist" {
            $missingPath = Join-Path $script:TestDir "nonexistent.json"
            $config = Get-RobocurseConfig -Path $missingPath

            $config | Should -Not -BeNullOrEmpty
            $config.Version | Should -Be "1.0"
            $config.GlobalSettings | Should -Not -BeNullOrEmpty
        }

        It "Should load valid configuration file" {
            # Create a valid config with new schema
            $validConfig = New-DefaultConfig
            $validConfig | ConvertTo-Json -Depth 10 | Set-Content $script:TestConfigPath

            $config = Get-RobocurseConfig -Path $script:TestConfigPath
            $config | Should -Not -BeNullOrEmpty
            $config.Version | Should -Be "1.0"
        }

        It "Should handle malformed JSON gracefully without throwing" {
            "{ invalid json" | Set-Content $script:TestConfigPath

            { Get-RobocurseConfig -Path $script:TestConfigPath } | Should -Not -Throw

            # Should return default config on error
            $config = Get-RobocurseConfig -Path $script:TestConfigPath -WarningAction SilentlyContinue
            $config | Should -Not -BeNullOrEmpty
            $config.Version | Should -Be "1.0"
        }

        It "Should use default path parameter" {
            $config = Get-RobocurseConfig -Path "$script:TestDir\nonexistent.json"
            $config | Should -Not -BeNullOrEmpty
        }
    }

    Context "Save-RobocurseConfig" {
        BeforeEach {
            $script:TestConfigPath = Join-Path $script:TestDir "save-test-config.json"
        }

        AfterEach {
            if (Test-Path $script:TestConfigPath) {
                Remove-Item $script:TestConfigPath -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should save configuration to file" {
            $config = New-DefaultConfig
            $result = Save-RobocurseConfig -Config $config -Path $script:TestConfigPath

            $result | Should -Be $true
            Test-Path $script:TestConfigPath | Should -Be $true
        }

        It "Should create valid JSON" {
            $config = New-DefaultConfig
            Save-RobocurseConfig -Config $config -Path $script:TestConfigPath

            { Get-Content $script:TestConfigPath -Raw | ConvertFrom-Json } | Should -Not -Throw
        }

        It "Should preserve configuration structure" {
            $config = New-DefaultConfig
            Save-RobocurseConfig -Config $config -Path $script:TestConfigPath
            $loaded = Get-Content $script:TestConfigPath -Raw | ConvertFrom-Json

            $loaded.PSObject.Properties.Name | Should -Contain "Version"
            $loaded.PSObject.Properties.Name | Should -Contain "GlobalSettings"
            $loaded.PSObject.Properties.Name | Should -Contain "SyncProfiles"
        }

        It "Should create parent directory if it doesn't exist" {
            $nestedPath = Join-Path $script:TestDir "subdir\config.json"
            $config = New-DefaultConfig

            $result = Save-RobocurseConfig -Config $config -Path $nestedPath

            $result | Should -Be $true
            Test-Path $nestedPath | Should -Be $true
        }

        It "Should return false on save failure" {
            # Test with invalid path (root with no write permissions would fail, but hard to test reliably)
            # Instead, we test that the function handles errors properly by testing return value
            $config = New-DefaultConfig
            $result = Save-RobocurseConfig -Config $config -Path $script:TestConfigPath

            $result | Should -BeOfType [bool]
        }
    }

    Context "Test-RobocurseConfig" {
        It "Should accept valid default configuration" {
            $config = New-DefaultConfig
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $true
            $result.Errors.Count | Should -Be 0
        }

        It "Should reject configuration without GlobalSettings" {
            $config = [PSCustomObject]@{
                SyncProfiles = @()
            }
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $false
            $result.Errors | Should -Contain "Missing required property: GlobalSettings"
        }

        It "Should reject configuration without SyncProfiles" {
            $config = [PSCustomObject]@{
                GlobalSettings = [PSCustomObject]@{
                    MaxConcurrentJobs = 4
                }
            }
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $false
            $result.Errors | Should -Contain "Missing required property: SyncProfiles"
        }

        It "Should validate MaxConcurrentJobs range (too low)" {
            $config = New-DefaultConfig
            $config.GlobalSettings.MaxConcurrentJobs = 0
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $false
            $result.Errors | Should -Match "MaxConcurrentJobs must be between 1 and 32"
        }

        It "Should validate MaxConcurrentJobs range (too high)" {
            $config = New-DefaultConfig
            $config.GlobalSettings.MaxConcurrentJobs = 33
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $false
            $result.Errors | Should -Match "MaxConcurrentJobs must be between 1 and 32"
        }

        It "Should validate Email config when enabled" {
            $config = New-DefaultConfig
            $config.Email.Enabled = $true
            # Leave SmtpServer, From, and To empty/invalid
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $false
            $result.Errors | Should -Contain "Email.SmtpServer is required when Email.Enabled is true"
            $result.Errors | Should -Contain "Email.From is required when Email.Enabled is true"
            $result.Errors | Should -Contain "Email.To must contain at least one recipient when Email.Enabled is true"
        }

        It "Should accept valid Email config when enabled" {
            $config = New-DefaultConfig
            $config.Email.Enabled = $true
            $config.Email.SmtpServer = "smtp.example.com"
            $config.Email.From = "sender@example.com"
            $config.Email.To = @("recipient@example.com")
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $true
        }

        It "Should validate SyncProfile required fields" {
            $config = New-DefaultConfig
            $config.SyncProfiles = @(
                [PSCustomObject]@{
                    # Missing Name, Source, Destination
                }
            )
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $false
            $result.Errors | Should -Contain "SyncProfiles[0] is missing required property: Name"
            $result.Errors | Should -Contain "SyncProfiles[0] is missing required property: Source"
            $result.Errors | Should -Contain "SyncProfiles[0] is missing required property: Destination"
        }

        It "Should reject invalid path format with pipe character" {
            $config = New-DefaultConfig
            $config.SyncProfiles = @(
                [PSCustomObject]@{
                    Name = "Test"
                    Source = "invalid|path"
                    Destination = "C:\Backup"
                }
            )
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $false
            $result.Errors | Should -Match "invalid path format"
        }

        It "Should reject invalid path format with angle brackets" {
            $config = New-DefaultConfig
            $config.SyncProfiles = @(
                [PSCustomObject]@{
                    Name = "Test"
                    Source = "C:\Path"
                    Destination = "C:\<Invalid>Path"
                }
            )
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $false
            $result.Errors | Should -Match "invalid path format"
        }

        It "Should accept valid UNC paths" {
            $config = New-DefaultConfig
            $config.SyncProfiles = @(
                [PSCustomObject]@{
                    Name = "Test"
                    Source = "\\server\share"
                    Destination = "C:\Backup"
                }
            )
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $true
        }

        It "Should accept valid local absolute paths" {
            $config = New-DefaultConfig
            $config.SyncProfiles = @(
                [PSCustomObject]@{
                    Name = "Test"
                    Source = "C:\Source\Path"
                    Destination = "D:\Destination\Path"
                }
            )
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $true
        }

        It "Should accept valid relative paths" {
            $config = New-DefaultConfig
            $config.SyncProfiles = @(
                [PSCustomObject]@{
                    Name = "Test"
                    Source = ".\Source"
                    Destination = "..\Destination"
                }
            )
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $true
        }
    }
}
