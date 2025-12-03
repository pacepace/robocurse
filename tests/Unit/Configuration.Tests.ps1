BeforeAll {
    # Load Robocurse functions using TestHelper
    . "$PSScriptRoot\..\TestHelper.ps1"
    Initialize-RobocurseForTesting

    # Create temporary test directory
    $script:TestDir = New-TempTestDirectory
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
            $saved.Success | Should -Be $true

            # Verify the JSON file saves in friendly format with empty profiles object
            $jsonContent = Get-Content $tempPath -Raw
            $jsonContent | Should -Match '"profiles":\s*\{'

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

            $result.Success | Should -Be $true
            Test-Path $script:TestConfigPath | Should -Be $true
        }

        It "Should create valid JSON" {
            $config = New-DefaultConfig
            Save-RobocurseConfig -Config $config -Path $script:TestConfigPath

            { Get-Content $script:TestConfigPath -Raw | ConvertFrom-Json } | Should -Not -Throw
        }

        It "Should preserve configuration structure in friendly format" {
            $config = New-DefaultConfig
            Save-RobocurseConfig -Config $config -Path $script:TestConfigPath
            $loaded = Get-Content $script:TestConfigPath -Raw | ConvertFrom-Json

            # Saved in friendly format (profiles/global)
            $loaded.PSObject.Properties.Name | Should -Contain "version"
            $loaded.PSObject.Properties.Name | Should -Contain "profiles"
            $loaded.PSObject.Properties.Name | Should -Contain "global"
        }

        It "Should create parent directory if it doesn't exist" {
            $nestedPath = Join-Path $script:TestDir "subdir\config.json"
            $config = New-DefaultConfig

            $result = Save-RobocurseConfig -Config $config -Path $nestedPath

            $result.Success | Should -Be $true
            Test-Path $nestedPath | Should -Be $true
        }

        It "Should return OperationResult on save" {
            # Test that the function returns an OperationResult with expected properties
            $config = New-DefaultConfig
            $result = Save-RobocurseConfig -Config $config -Path $script:TestConfigPath

            $result.PSObject.Properties.Name | Should -Contain "Success"
            $result.Success | Should -Be $true
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

    # ConvertFrom-FriendlyConfig tests are in the dedicated context below

    Context "Get-RobocurseConfig with friendly format" {
        BeforeEach {
            $script:TestConfigPath = Join-Path $script:TestDir "json-format-config.json"
        }

        AfterEach {
            if (Test-Path $script:TestConfigPath) {
                Remove-Item $script:TestConfigPath -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should load and convert friendly format automatically" {
            # Create a config file in friendly format (single source per profile)
            $jsonFileFormat = @{
                profiles = @{
                    TestBackup = @{
                        enabled = $true
                        source = @{
                            path = "C:\TestSource"
                            useVss = $false
                        }
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

    # Multi-source profile handling removed - each profile now has exactly one source

    Context "Config Helper Functions" {
        Context "ConvertTo-RobocopyOptionsInternal" {
            It "Should return empty options when input is null" {
                $result = ConvertTo-RobocopyOptionsInternal -RawRobocopy $null

                $result.Switches | Should -BeNullOrEmpty
                $result.ExcludeFiles | Should -BeNullOrEmpty
                $result.ExcludeDirs | Should -BeNullOrEmpty
            }

            It "Should convert switches array" {
                $raw = [PSCustomObject]@{
                    switches = @("/COPYALL", "/DCOPY:DAT")
                }
                $result = ConvertTo-RobocopyOptionsInternal -RawRobocopy $raw

                $result.Switches | Should -Contain "/COPYALL"
                $result.Switches | Should -Contain "/DCOPY:DAT"
            }

            It "Should convert exclude patterns" {
                $raw = [PSCustomObject]@{
                    excludeFiles = @("*.tmp", "*.log")
                    excludeDirs = @("temp", "cache")
                }
                $result = ConvertTo-RobocopyOptionsInternal -RawRobocopy $raw

                $result.ExcludeFiles | Should -Contain "*.tmp"
                $result.ExcludeDirs | Should -Contain "cache"
            }

            It "Should convert retry policy" {
                $raw = [PSCustomObject]@{
                    retryPolicy = [PSCustomObject]@{
                        count = 5
                        wait = 30
                    }
                }
                $result = ConvertTo-RobocopyOptionsInternal -RawRobocopy $raw

                $result.RetryCount | Should -Be 5
                $result.RetryWait | Should -Be 30
            }
        }

        Context "ConvertTo-ChunkSettingsInternal" {
            It "Should apply chunking settings to profile" {
                $profile = [PSCustomObject]@{
                    ScanMode = "Smart"
                    ChunkMaxSizeGB = 10
                    ChunkMaxFiles = 50000
                    ChunkMaxDepth = 5
                }
                $rawChunking = [PSCustomObject]@{
                    maxChunkSizeGB = 50
                    maxDepthToScan = 8
                    strategy = "flat"
                }

                ConvertTo-ChunkSettingsInternal -Profile $profile -RawChunking $rawChunking

                $profile.ChunkMaxSizeGB | Should -Be 50
                $profile.ChunkMaxDepth | Should -Be 8
                $profile.ScanMode | Should -Be "Flat"
            }

            It "Should handle null chunking gracefully" {
                $profile = [PSCustomObject]@{
                    ScanMode = "Smart"
                    ChunkMaxSizeGB = 10
                }

                ConvertTo-ChunkSettingsInternal -Profile $profile -RawChunking $null

                # Should remain unchanged
                $profile.ScanMode | Should -Be "Smart"
                $profile.ChunkMaxSizeGB | Should -Be 10
            }

            It "Should map strategy values correctly" {
                $testCases = @(
                    @{ Strategy = "auto"; Expected = "Smart" }
                    @{ Strategy = "balanced"; Expected = "Smart" }
                    @{ Strategy = "aggressive"; Expected = "Smart" }
                    @{ Strategy = "flat"; Expected = "Flat" }
                    @{ Strategy = "unknown"; Expected = "Smart" }
                )

                foreach ($case in $testCases) {
                    $profile = [PSCustomObject]@{ ScanMode = "Initial" }
                    $rawChunking = [PSCustomObject]@{ strategy = $case.Strategy }

                    ConvertTo-ChunkSettingsInternal -Profile $profile -RawChunking $rawChunking

                    $profile.ScanMode | Should -Be $case.Expected -Because "Strategy '$($case.Strategy)' should map to '$($case.Expected)'"
                }
            }
        }

        Context "Get-DestinationPathFromRaw" {
            It "Should extract path from object with path property" {
                $raw = [PSCustomObject]@{ path = "D:\Backup" }
                $result = Get-DestinationPathFromRaw -RawDestination $raw

                $result | Should -Be "D:\Backup"
            }

            It "Should handle string destination directly" {
                $result = Get-DestinationPathFromRaw -RawDestination "E:\Replicas"

                $result | Should -Be "E:\Replicas"
            }

            It "Should return empty string for null input" {
                $result = Get-DestinationPathFromRaw -RawDestination $null

                $result | Should -Be ""
            }
        }
    }

    Context "ConvertFrom-GlobalSettings" {
        It "Should convert performance settings to GlobalSettings" {
            # Note: Function reads performance.maxConcurrentJobs and performance.bandwidthLimitMbps
            # ThreadsPerJob is not a configurable JSON setting (uses default)
            $rawGlobal = [PSCustomObject]@{
                performance = [PSCustomObject]@{
                    maxConcurrentJobs = 12
                    bandwidthLimitMbps = 500
                }
            }
            $config = New-DefaultConfig

            ConvertFrom-GlobalSettings -RawGlobal $rawGlobal -Config $config

            $config.GlobalSettings.MaxConcurrentJobs | Should -Be 12
            $config.GlobalSettings.BandwidthLimitMbps | Should -Be 500
        }

        It "Should convert logging settings" {
            # Function expects logging.operationalLog.path structure
            # LogPath is extracted as parent directory of the log file path
            $rawGlobal = [PSCustomObject]@{
                logging = [PSCustomObject]@{
                    operationalLog = [PSCustomObject]@{
                        path = "D:\CustomLogs\robocurse.log"
                        rotation = [PSCustomObject]@{
                            maxAgeDays = 60
                        }
                    }
                }
            }
            $config = New-DefaultConfig

            ConvertFrom-GlobalSettings -RawGlobal $rawGlobal -Config $config

            # Normalize path separators for cross-platform testing
            ($config.GlobalSettings.LogPath -replace '[/\\]', '/') | Should -Be "D:/CustomLogs"
            $config.GlobalSettings.LogRetentionDays | Should -Be 60
        }

        It "Should convert email settings" {
            $rawGlobal = [PSCustomObject]@{
                email = [PSCustomObject]@{
                    enabled = $true
                    smtp = [PSCustomObject]@{
                        server = "mail.example.com"
                        port = 587
                        useSsl = $true
                        credentialName = "MyEmailCred"
                    }
                    from = "backup@example.com"
                    to = @("admin@example.com", "ops@example.com")
                }
            }
            $config = New-DefaultConfig

            ConvertFrom-GlobalSettings -RawGlobal $rawGlobal -Config $config

            $config.Email.Enabled | Should -Be $true
            $config.Email.SmtpServer | Should -Be "mail.example.com"
            $config.Email.Port | Should -Be 587
            $config.Email.UseTls | Should -Be $true
            $config.Email.CredentialTarget | Should -Be "MyEmailCred"
            $config.Email.From | Should -Be "backup@example.com"
            $config.Email.To | Should -Contain "admin@example.com"
        }

        It "Should handle empty rawGlobal gracefully" {
            # Note: RawGlobal is mandatory, but an empty object should work
            $config = New-DefaultConfig
            $rawGlobal = [PSCustomObject]@{}

            { ConvertFrom-GlobalSettings -RawGlobal $rawGlobal -Config $config } | Should -Not -Throw

            # Should keep defaults
            $config.GlobalSettings.MaxConcurrentJobs | Should -Be 4
        }

        It "Should have correct function signature" {
            $cmd = Get-Command ConvertFrom-GlobalSettings

            $cmd.Parameters.ContainsKey('RawGlobal') | Should -Be $true
            $cmd.Parameters.ContainsKey('Config') | Should -Be $true
        }
    }

    Context "ConvertFrom-FriendlyConfig" {
        It "Should convert friendly config with single source profile" {
            $rawConfig = [PSCustomObject]@{
                version = "1.0"
                profiles = [PSCustomObject]@{
                    TestProfile = [PSCustomObject]@{
                        description = "Test profile"
                        enabled = $true
                        source = [PSCustomObject]@{
                            path = "C:\TestSource"
                            useVss = $true
                        }
                        destination = [PSCustomObject]@{
                            path = "D:\TestDest"
                        }
                    }
                }
                global = [PSCustomObject]@{}
            }

            $result = ConvertFrom-FriendlyConfig -RawConfig $rawConfig

            $result.SyncProfiles.Count | Should -Be 1
            $result.SyncProfiles[0].Name | Should -Be "TestProfile"
            $result.SyncProfiles[0].Source | Should -Be "C:\TestSource"
            $result.SyncProfiles[0].Destination | Should -Be "D:\TestDest"
            $result.SyncProfiles[0].UseVss | Should -Be $true
        }

        It "Should convert multiple profiles" {
            $rawConfig = [PSCustomObject]@{
                version = "1.0"
                profiles = [PSCustomObject]@{
                    Profile1 = [PSCustomObject]@{
                        source = [PSCustomObject]@{ path = "C:\Source1" }
                        destination = [PSCustomObject]@{ path = "D:\Dest1" }
                    }
                    Profile2 = [PSCustomObject]@{
                        source = [PSCustomObject]@{ path = "C:\Source2" }
                        destination = [PSCustomObject]@{ path = "D:\Dest2" }
                    }
                }
                global = [PSCustomObject]@{}
            }

            $result = ConvertFrom-FriendlyConfig -RawConfig $rawConfig

            $result.SyncProfiles.Count | Should -Be 2
            $result.SyncProfiles.Name | Should -Contain "Profile1"
            $result.SyncProfiles.Name | Should -Contain "Profile2"
        }

        It "Should skip disabled profiles" {
            $rawConfig = [PSCustomObject]@{
                version = "1.0"
                profiles = [PSCustomObject]@{
                    EnabledProfile = [PSCustomObject]@{
                        enabled = $true
                        source = [PSCustomObject]@{ path = "C:\Source1" }
                        destination = [PSCustomObject]@{ path = "D:\Dest1" }
                    }
                    DisabledProfile = [PSCustomObject]@{
                        enabled = $false
                        source = [PSCustomObject]@{ path = "C:\Source2" }
                        destination = [PSCustomObject]@{ path = "D:\Dest2" }
                    }
                }
                global = [PSCustomObject]@{}
            }

            $result = ConvertFrom-FriendlyConfig -RawConfig $rawConfig

            $result.SyncProfiles.Count | Should -Be 1
            $result.SyncProfiles[0].Name | Should -Be "EnabledProfile"
        }

        It "Should handle string source path" {
            $rawConfig = [PSCustomObject]@{
                version = "1.0"
                profiles = [PSCustomObject]@{
                    SimpleProfile = [PSCustomObject]@{
                        source = "C:\SimpleSource"
                        destination = [PSCustomObject]@{ path = "D:\Dest" }
                    }
                }
                global = [PSCustomObject]@{}
            }

            $result = ConvertFrom-FriendlyConfig -RawConfig $rawConfig

            $result.SyncProfiles[0].Source | Should -Be "C:\SimpleSource"
        }

        It "Should throw when profiles property is missing" {
            $rawConfig = [PSCustomObject]@{
                version = "1.0"
                global = [PSCustomObject]@{}
            }

            { ConvertFrom-FriendlyConfig -RawConfig $rawConfig } | Should -Throw "*missing 'profiles' property*"
        }

        It "Should have correct function signature" {
            $cmd = Get-Command ConvertFrom-FriendlyConfig

            $cmd.Parameters.ContainsKey('RawConfig') | Should -Be $true
            $cmd.Parameters['RawConfig'].ParameterType.Name | Should -Be 'PSObject'
        }
    }

    Context "ConvertTo-FriendlyConfig" {
        It "Should convert internal config to friendly format" {
            $config = New-DefaultConfig
            $config.SyncProfiles = @(
                [PSCustomObject]@{
                    Name = "TestProfile"
                    Description = "Test description"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                    UseVss = $true
                    ScanMode = "Smart"
                    ChunkMaxSizeGB = 50
                    ChunkMaxFiles = 10000
                    ChunkMaxDepth = 3
                    RobocopyOptions = @{
                        Switches = @("/MIR")
                        ExcludeFiles = @("*.tmp")
                        ExcludeDirs = @("Temp")
                    }
                    Enabled = $true
                }
            )

            $result = ConvertTo-FriendlyConfig -Config $config

            $result.profiles.TestProfile | Should -Not -BeNullOrEmpty
            $result.profiles.TestProfile.source.path | Should -Be "C:\Source"
            $result.profiles.TestProfile.source.useVss | Should -Be $true
            $result.profiles.TestProfile.destination.path | Should -Be "D:\Dest"
            $result.profiles.TestProfile.chunking.maxChunkSizeGB | Should -Be 50
            $result.profiles.TestProfile.robocopy.switches | Should -Contain "/MIR"
        }

        It "Should convert global settings to friendly format" {
            $config = New-DefaultConfig
            $config.GlobalSettings.MaxConcurrentJobs = 8
            $config.GlobalSettings.BandwidthLimitMbps = 100
            $config.Email.Enabled = $true
            $config.Email.SmtpServer = "smtp.test.com"

            $result = ConvertTo-FriendlyConfig -Config $config

            $result.global.performance.maxConcurrentJobs | Should -Be 8
            $result.global.performance.throttleNetworkMbps | Should -Be 100
            $result.global.email.enabled | Should -Be $true
            $result.global.email.smtp.server | Should -Be "smtp.test.com"
        }

        It "Should round-trip config without data loss" {
            # Create a config, convert to friendly, serialize/deserialize via JSON, convert back
            $original = New-DefaultConfig
            $original.SyncProfiles = @(
                [PSCustomObject]@{
                    Name = "RoundTrip"
                    Description = "Round trip test"
                    Source = "C:\Data"
                    Destination = "D:\Backup"
                    UseVss = $true
                    ScanMode = "Smart"
                    ChunkMaxSizeGB = 25
                    ChunkMaxFiles = 5000
                    ChunkMaxDepth = 4
                    RobocopyOptions = @{}
                    Enabled = $true
                }
            )

            $friendly = ConvertTo-FriendlyConfig -Config $original
            # Simulate JSON serialization round-trip (as would happen with config files)
            $json = $friendly | ConvertTo-Json -Depth 10
            $friendlyObj = $json | ConvertFrom-Json
            $restored = ConvertFrom-FriendlyConfig -RawConfig $friendlyObj

            $restored.SyncProfiles[0].Name | Should -Be "RoundTrip"
            $restored.SyncProfiles[0].Source | Should -Be "C:\Data"
            $restored.SyncProfiles[0].Destination | Should -Be "D:\Backup"
            $restored.SyncProfiles[0].UseVss | Should -Be $true
            $restored.SyncProfiles[0].ChunkMaxSizeGB | Should -Be 25
        }

        It "Should have correct function signature" {
            $cmd = Get-Command ConvertTo-FriendlyConfig

            $cmd.Parameters.ContainsKey('Config') | Should -Be $true
            $cmd.Parameters['Config'].ParameterType.Name | Should -Be 'PSObject'
        }
    }

    Context "Get-NormalizedCacheKey" {
        It "Should remove trailing backslashes" {
            $result = Get-NormalizedCacheKey -Path "C:\Data\"
            $result | Should -Be "C:\Data"
        }

        It "Should convert forward slashes to backslashes" {
            $result = Get-NormalizedCacheKey -Path "C:/Data/Folder"
            $result | Should -Be "C:\Data\Folder"
        }

        It "Should preserve case (case is handled by dictionary comparer)" {
            $result = Get-NormalizedCacheKey -Path "C:\DATA\Folder"
            $result | Should -Be "C:\DATA\Folder"
        }

        It "Should handle UNC paths" {
            $result = Get-NormalizedCacheKey -Path "\\server\share\"
            $result | Should -Be "\\server\share"
        }

        It "Should handle mixed slashes" {
            $result = Get-NormalizedCacheKey -Path "\\server/share/folder\"
            $result | Should -Be "\\server\share\folder"
        }
    }

    Context "Test-SafeConfigPath - Security Validation" {
        It "Should accept valid absolute path" {
            Test-SafeConfigPath -Path "C:\Config\robocurse.json" | Should -Be $true
        }

        It "Should accept valid relative path" {
            Test-SafeConfigPath -Path ".\config.json" | Should -Be $true
        }

        It "Should accept valid path with parent directory reference" {
            # Parent directory references are allowed but logged
            Test-SafeConfigPath -Path "..\config.json" | Should -Be $true
        }

        It "Should accept valid UNC path" {
            Test-SafeConfigPath -Path "\\server\share\config.json" | Should -Be $true
        }

        It "Should accept empty path (will fail later at Test-Path)" {
            Test-SafeConfigPath -Path "" | Should -Be $true
        }

        It "Should reject path with semicolon (command separator)" {
            Test-SafeConfigPath -Path "C:\config.json; del *" | Should -Be $false
        }

        It "Should reject path with ampersand (command separator)" {
            Test-SafeConfigPath -Path "C:\config.json & malicious" | Should -Be $false
        }

        It "Should reject path with pipe (command separator)" {
            Test-SafeConfigPath -Path "C:\config.json | format C:" | Should -Be $false
        }

        It "Should reject path with greater-than (redirection)" {
            Test-SafeConfigPath -Path "C:\config.json > output" | Should -Be $false
        }

        It "Should reject path with less-than (redirection)" {
            Test-SafeConfigPath -Path "C:\config.json < input" | Should -Be $false
        }

        It "Should reject path with backtick" {
            Test-SafeConfigPath -Path "C:\path`nmalicious" | Should -Be $false
        }

        It "Should reject path with PowerShell command substitution" {
            Test-SafeConfigPath -Path 'C:\$(Get-Process).json' | Should -Be $false
        }

        It "Should reject path with PowerShell variable expansion" {
            Test-SafeConfigPath -Path 'C:\${env:USERPROFILE}\config.json' | Should -Be $false
        }

        It "Should reject path with cmd.exe environment variable" {
            Test-SafeConfigPath -Path "C:\%TEMP%\config.json" | Should -Be $false
        }

        It "Should reject path with null byte" {
            Test-SafeConfigPath -Path "C:\config`0.json" | Should -Be $false
        }

        It "Should reject path with newline" {
            Test-SafeConfigPath -Path "C:\config`n.json" | Should -Be $false
        }

        It "Should reject path with carriage return" {
            Test-SafeConfigPath -Path "C:\config`r.json" | Should -Be $false
        }
    }

    Context "Test-RobocurseConfig - Chunk Configuration Validation" {
        It "Should validate ChunkMaxFiles range (too low)" {
            $config = New-DefaultConfig
            $config.SyncProfiles = @(
                [PSCustomObject]@{
                    Name = "Test"
                    Source = "C:\Source"
                    Destination = "D:\Backup"
                    ChunkMaxFiles = 0
                }
            )
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $false
            $result.Errors | Should -Match "ChunkMaxFiles must be between 1 and 10000000"
        }

        It "Should validate ChunkMaxFiles range (too high)" {
            $config = New-DefaultConfig
            $config.SyncProfiles = @(
                [PSCustomObject]@{
                    Name = "Test"
                    Source = "C:\Source"
                    Destination = "D:\Backup"
                    ChunkMaxFiles = 20000000
                }
            )
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $false
            $result.Errors | Should -Match "ChunkMaxFiles must be between 1 and 10000000"
        }

        It "Should validate ChunkMaxSizeGB range (too low)" {
            $config = New-DefaultConfig
            $config.SyncProfiles = @(
                [PSCustomObject]@{
                    Name = "Test"
                    Source = "C:\Source"
                    Destination = "D:\Backup"
                    ChunkMaxSizeGB = 0
                }
            )
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $false
            $result.Errors | Should -Match "ChunkMaxSizeGB must be between 0.001 and 1024"
        }

        It "Should validate ChunkMaxSizeGB > ChunkMinSizeGB" {
            $config = New-DefaultConfig
            $config.SyncProfiles = @(
                [PSCustomObject]@{
                    Name = "Test"
                    Source = "C:\Source"
                    Destination = "D:\Backup"
                    ChunkMaxSizeGB = 1
                    ChunkMinSizeGB = 5
                }
            )
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $false
            $result.Errors | Should -Match "ChunkMaxSizeGB.*greater than.*ChunkMinSizeGB"
        }

        It "Should accept valid chunk configuration" {
            $config = New-DefaultConfig
            $config.SyncProfiles = @(
                [PSCustomObject]@{
                    Name = "Test"
                    Source = "C:\Source"
                    Destination = "D:\Backup"
                    ChunkMaxSizeGB = 10
                    ChunkMinSizeGB = 0.1
                    ChunkMaxFiles = 50000
                }
            )
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $true
        }
    }

    Context "ConvertFrom-FriendlyConfig - Null Safety" {
        It "Should handle null source gracefully" {
            # Profile with null source should still be converted (will have empty Source)
            $rawConfig = [PSCustomObject]@{
                version = "1.0"
                profiles = [PSCustomObject]@{
                    TestProfile = [PSCustomObject]@{
                        description = "Test profile"
                        source = $null
                        destination = "D:\Backup"
                    }
                }
                global = [PSCustomObject]@{}
            }

            $result = ConvertFrom-FriendlyConfig -RawConfig $rawConfig
            $result.SyncProfiles | Should -HaveCount 1
            $result.SyncProfiles[0].Source | Should -BeNullOrEmpty
        }

        It "Should handle empty profiles gracefully" {
            $rawConfig = [PSCustomObject]@{
                version = "1.0"
                profiles = [PSCustomObject]@{}
                global = [PSCustomObject]@{}
            }

            $result = ConvertFrom-FriendlyConfig -RawConfig $rawConfig
            $result.SyncProfiles | Should -HaveCount 0
        }
    }
}
