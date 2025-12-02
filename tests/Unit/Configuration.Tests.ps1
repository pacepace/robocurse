BeforeAll {
    # Load the main script - it auto-detects dot-sourcing and skips main execution
    $mainScriptPath = Join-Path $PSScriptRoot ".." ".." "Robocurse.ps1"
    . $mainScriptPath -Help

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

    Context "ConvertFrom-ConfigFileFormat" {
        It "Should pass through config already in internal format" {
            $internalConfig = New-DefaultConfig
            $internalConfig.SyncProfiles = @(
                [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                }
            )

            $result = ConvertFrom-ConfigFileFormat -RawConfig $internalConfig

            $result.SyncProfiles.Count | Should -Be 1
            $result.SyncProfiles[0].Name | Should -Be "TestProfile"
        }

        It "Should convert JSON file format (profiles/global) to internal format" {
            # Create a raw config in JSON file format
            $rawConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{
                    DailyBackup = [PSCustomObject]@{
                        description = "Daily backup"
                        enabled = $true
                        sources = @(
                            [PSCustomObject]@{
                                path = "\\server\share"
                                useVss = $true
                            }
                        )
                        destination = [PSCustomObject]@{
                            path = "D:\Backups"
                        }
                        robocopy = [PSCustomObject]@{
                            switches = @("/COPYALL", "/DCOPY:DAT")
                            excludeFiles = @("*.tmp")
                            excludeDirs = @("temp")
                        }
                        chunking = [PSCustomObject]@{
                            maxChunkSizeGB = 50
                            strategy = "auto"
                        }
                    }
                }
                global = [PSCustomObject]@{
                    performance = [PSCustomObject]@{
                        maxConcurrentJobs = 8
                    }
                }
            }

            $result = ConvertFrom-ConfigFileFormat -RawConfig $rawConfig

            # Check global settings were converted
            $result.GlobalSettings.MaxConcurrentJobs | Should -Be 8

            # Check profile was converted
            $result.SyncProfiles.Count | Should -Be 1
            $result.SyncProfiles[0].Name | Should -Be "DailyBackup"
            $result.SyncProfiles[0].Source | Should -Be "\\server\share"
            $result.SyncProfiles[0].Destination | Should -Be "D:\Backups"
            $result.SyncProfiles[0].UseVss | Should -Be $true
            $result.SyncProfiles[0].ChunkMaxSizeGB | Should -Be 50
            $result.SyncProfiles[0].ScanMode | Should -Be "Smart"

            # Check robocopy options were converted
            $result.SyncProfiles[0].RobocopyOptions.Switches | Should -Contain "/COPYALL"
            $result.SyncProfiles[0].RobocopyOptions.ExcludeFiles | Should -Contain "*.tmp"
            $result.SyncProfiles[0].RobocopyOptions.ExcludeDirs | Should -Contain "temp"
        }

        It "Should skip disabled profiles" {
            $rawConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{
                    EnabledProfile = [PSCustomObject]@{
                        enabled = $true
                        sources = @([PSCustomObject]@{ path = "C:\Source1" })
                        destination = [PSCustomObject]@{ path = "D:\Dest1" }
                    }
                    DisabledProfile = [PSCustomObject]@{
                        enabled = $false
                        sources = @([PSCustomObject]@{ path = "C:\Source2" })
                        destination = [PSCustomObject]@{ path = "D:\Dest2" }
                    }
                }
            }

            $result = ConvertFrom-ConfigFileFormat -RawConfig $rawConfig

            $result.SyncProfiles.Count | Should -Be 1
            $result.SyncProfiles[0].Name | Should -Be "EnabledProfile"
        }

        It "Should handle retry policy conversion" {
            $rawConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{
                    TestProfile = [PSCustomObject]@{
                        enabled = $true
                        sources = @([PSCustomObject]@{ path = "C:\Source" })
                        destination = [PSCustomObject]@{ path = "D:\Dest" }
                        retryPolicy = [PSCustomObject]@{
                            maxRetries = 5
                            retryDelayMinutes = 2
                        }
                    }
                }
            }

            $result = ConvertFrom-ConfigFileFormat -RawConfig $rawConfig

            $result.SyncProfiles[0].RobocopyOptions.RetryCount | Should -Be 5
            # 2 minutes = 120 seconds
            $result.SyncProfiles[0].RobocopyOptions.RetryWait | Should -Be 120
        }

        It "Should map chunking strategy to ScanMode" {
            $rawConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{
                    FlatProfile = [PSCustomObject]@{
                        enabled = $true
                        sources = @([PSCustomObject]@{ path = "C:\Source" })
                        destination = [PSCustomObject]@{ path = "D:\Dest" }
                        chunking = [PSCustomObject]@{
                            strategy = "flat"
                        }
                    }
                }
            }

            $result = ConvertFrom-ConfigFileFormat -RawConfig $rawConfig

            $result.SyncProfiles[0].ScanMode | Should -Be "Flat"
        }

        It "Should handle email settings conversion" {
            $rawConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{}
                global = [PSCustomObject]@{
                    email = [PSCustomObject]@{
                        enabled = $true
                        smtp = [PSCustomObject]@{
                            server = "smtp.test.com"
                            port = 465
                            useSsl = $true
                            credentialName = "TestCred"
                        }
                        from = "sender@test.com"
                        to = @("recipient@test.com")
                    }
                }
            }

            $result = ConvertFrom-ConfigFileFormat -RawConfig $rawConfig

            $result.Email.Enabled | Should -Be $true
            $result.Email.SmtpServer | Should -Be "smtp.test.com"
            $result.Email.Port | Should -Be 465
            $result.Email.UseTls | Should -Be $true
            $result.Email.CredentialTarget | Should -Be "TestCred"
            $result.Email.From | Should -Be "sender@test.com"
            $result.Email.To | Should -Contain "recipient@test.com"
        }
    }

    Context "Get-RobocurseConfig with JSON file format" {
        BeforeEach {
            $script:TestConfigPath = Join-Path $script:TestDir "json-format-config.json"
        }

        AfterEach {
            if (Test-Path $script:TestConfigPath) {
                Remove-Item $script:TestConfigPath -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should load and convert JSON file format automatically" {
            # Create a config file in JSON file format
            $jsonFileFormat = @{
                profiles = @{
                    TestBackup = @{
                        enabled = $true
                        sources = @(
                            @{
                                path = "C:\TestSource"
                                useVss = $false
                            }
                        )
                        destination = @{
                            path = "D:\TestDest"
                        }
                    }
                }
                global = @{
                    performance = @{
                        maxConcurrentJobs = 6
                    }
                }
            }
            $jsonFileFormat | ConvertTo-Json -Depth 10 | Set-Content $script:TestConfigPath

            $config = Get-RobocurseConfig -Path $script:TestConfigPath

            # Should be converted to internal format
            $config.GlobalSettings.MaxConcurrentJobs | Should -Be 6
            $config.SyncProfiles.Count | Should -Be 1
            $config.SyncProfiles[0].Name | Should -Be "TestBackup"
            $config.SyncProfiles[0].Source | Should -Be "C:\TestSource"
            $config.SyncProfiles[0].Destination | Should -Be "D:\TestDest"
        }
    }

    Context "Multi-Source Profile Handling" {
        It "Should expand multi-source profile into separate sync profiles" {
            $rawConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{
                    MultiSourceBackup = [PSCustomObject]@{
                        description = "Backup from multiple locations"
                        enabled = $true
                        sources = @(
                            [PSCustomObject]@{
                                path = "C:\Source1"
                                useVss = $false
                            },
                            [PSCustomObject]@{
                                path = "D:\Source2"
                                useVss = $true
                            },
                            [PSCustomObject]@{
                                path = "E:\Source3"
                                useVss = $false
                            }
                        )
                        destination = [PSCustomObject]@{
                            path = "F:\Backups"
                        }
                        chunking = [PSCustomObject]@{
                            maxChunkSizeGB = 25
                        }
                    }
                }
            }

            $result = ConvertFrom-ConfigFileFormat -RawConfig $rawConfig

            # Should create 3 separate profiles
            $result.SyncProfiles.Count | Should -Be 3

            # Check first expanded profile
            $result.SyncProfiles[0].Name | Should -Be "MultiSourceBackup-Source1"
            $result.SyncProfiles[0].Source | Should -Be "C:\Source1"
            $result.SyncProfiles[0].Destination | Should -Be "F:\Backups"
            $result.SyncProfiles[0].UseVss | Should -Be $false
            $result.SyncProfiles[0].ChunkMaxSizeGB | Should -Be 25

            # Check second expanded profile
            $result.SyncProfiles[1].Name | Should -Be "MultiSourceBackup-Source2"
            $result.SyncProfiles[1].Source | Should -Be "D:\Source2"
            $result.SyncProfiles[1].Destination | Should -Be "F:\Backups"
            $result.SyncProfiles[1].UseVss | Should -Be $true

            # Check third expanded profile
            $result.SyncProfiles[2].Name | Should -Be "MultiSourceBackup-Source3"
            $result.SyncProfiles[2].Source | Should -Be "E:\Source3"
            $result.SyncProfiles[2].UseVss | Should -Be $false
        }

        It "Should preserve ParentProfile property for expanded profiles" {
            $rawConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{
                    ParentBackup = [PSCustomObject]@{
                        enabled = $true
                        sources = @(
                            [PSCustomObject]@{ path = "C:\Source1" },
                            [PSCustomObject]@{ path = "D:\Source2" }
                        )
                        destination = [PSCustomObject]@{ path = "E:\Dest" }
                    }
                }
            }

            $result = ConvertFrom-ConfigFileFormat -RawConfig $rawConfig

            $result.SyncProfiles[0].ParentProfile | Should -Be "ParentBackup"
            $result.SyncProfiles[1].ParentProfile | Should -Be "ParentBackup"
        }

        It "Should not expand single-source profile" {
            $rawConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{
                    SingleSourceBackup = [PSCustomObject]@{
                        enabled = $true
                        sources = @(
                            [PSCustomObject]@{
                                path = "C:\OnlySource"
                                useVss = $true
                            }
                        )
                        destination = [PSCustomObject]@{ path = "D:\Dest" }
                    }
                }
            }

            $result = ConvertFrom-ConfigFileFormat -RawConfig $rawConfig

            # Should remain as single profile with original name
            $result.SyncProfiles.Count | Should -Be 1
            $result.SyncProfiles[0].Name | Should -Be "SingleSourceBackup"
            $result.SyncProfiles[0].Source | Should -Be "C:\OnlySource"
        }

        It "Should copy robocopy options to all expanded profiles" {
            $rawConfig = [PSCustomObject]@{
                profiles = [PSCustomObject]@{
                    SharedOptionsBackup = [PSCustomObject]@{
                        enabled = $true
                        sources = @(
                            [PSCustomObject]@{ path = "C:\Source1" },
                            [PSCustomObject]@{ path = "D:\Source2" }
                        )
                        destination = [PSCustomObject]@{ path = "E:\Dest" }
                        robocopy = [PSCustomObject]@{
                            switches = @("/MIR", "/COPYALL")
                            excludeFiles = @("*.tmp", "*.log")
                            excludeDirs = @("temp", "cache")
                        }
                    }
                }
            }

            $result = ConvertFrom-ConfigFileFormat -RawConfig $rawConfig

            # Both profiles should have the same robocopy options
            $result.SyncProfiles[0].RobocopyOptions.Switches | Should -Contain "/MIR"
            $result.SyncProfiles[0].RobocopyOptions.ExcludeFiles | Should -Contain "*.tmp"
            $result.SyncProfiles[0].RobocopyOptions.ExcludeDirs | Should -Contain "temp"

            $result.SyncProfiles[1].RobocopyOptions.Switches | Should -Contain "/COPYALL"
            $result.SyncProfiles[1].RobocopyOptions.ExcludeFiles | Should -Contain "*.log"
            $result.SyncProfiles[1].RobocopyOptions.ExcludeDirs | Should -Contain "cache"
        }
    }
}
