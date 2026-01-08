#Requires -Modules Pester

<#
.SYNOPSIS
    Unit tests for Main.ps1 entry point functions
.DESCRIPTION
    Tests for Show-RobocurseHelp, Start-RobocurseMain, and Invoke-HeadlessReplication
    covering parameter validation, mode selection, and error handling.
#>

# Load module at discovery time so InModuleScope can find it
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

InModuleScope 'Robocurse' {
    Describe "Main Entry Point" {
        BeforeAll {
            # Create a temp directory for test configs
            $script:testTempDir = Join-Path $env:TEMP "RobocurseMainTests_$(Get-Random)"
            New-Item -Path $script:testTempDir -ItemType Directory -Force | Out-Null
        }

        AfterAll {
            # Cleanup temp directory
            if (Test-Path $script:testTempDir) {
                Remove-Item -Path $script:testTempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        BeforeEach {
            # Mock functions that would have side effects
            Mock Write-RobocurseLog { }
            Mock Write-SiemEvent { }
            Mock Initialize-LogSession { }
            Mock Initialize-RobocurseGui { return $null }  # Prevent GUI from launching
        }

        Context "Show-RobocurseHelp" {
            It "Should output help text containing usage information" {
                $output = Show-RobocurseHelp 6>&1
                $outputText = $output -join "`n"
                $outputText | Should -Match "USAGE"
            }

            It "Should output help text containing OPTIONS section" {
                $output = Show-RobocurseHelp 6>&1
                $outputText = $output -join "`n"
                $outputText | Should -Match "OPTIONS"
            }

            It "Should mention -Headless option" {
                $output = Show-RobocurseHelp 6>&1
                $outputText = $output -join "`n"
                $outputText | Should -Match "-Headless"
            }

            It "Should mention -ConfigPath option" {
                $output = Show-RobocurseHelp 6>&1
                $outputText = $output -join "`n"
                $outputText | Should -Match "-ConfigPath"
            }

            It "Should mention -Profile option" {
                $output = Show-RobocurseHelp 6>&1
                $outputText = $output -join "`n"
                $outputText | Should -Match "-Profile"
            }

            It "Should mention -DryRun option" {
                $output = Show-RobocurseHelp 6>&1
                $outputText = $output -join "`n"
                $outputText | Should -Match "-DryRun"
            }

            It "Should contain examples section" {
                $output = Show-RobocurseHelp 6>&1
                $outputText = $output -join "`n"
                $outputText | Should -Match "EXAMPLES"
            }
        }

        Context "Start-RobocurseMain with -ShowHelp" {
            It "Should return exit code 0 when -ShowHelp is specified" {
                $exitCode = Start-RobocurseMain -ShowHelp -ConfigPath "dummy.json" 6>&1 | Out-Null
                $exitCode = Start-RobocurseMain -ShowHelp -ConfigPath "dummy.json"
                $exitCode | Should -Be 0
            }

            It "Should not attempt to load config when -ShowHelp is specified" {
                Mock Get-RobocurseConfig { throw "Should not be called" }
                Start-RobocurseMain -ShowHelp -ConfigPath "dummy.json" 6>&1 | Out-Null
                Should -Invoke Get-RobocurseConfig -Times 0
            }
        }

        Context "Start-RobocurseMain Config Path Security" {
            It "Should reject config path with pipe character and return 1" {
                # Use -ErrorAction SilentlyContinue to prevent Write-Error from becoming terminating
                $exitCode = Start-RobocurseMain -ConfigPath "config|malicious.json" -Headless -AllProfiles -ErrorAction SilentlyContinue 2>$null 3>$null
                $exitCode | Should -Be 1
            }

            It "Should reject config path with angle brackets and return 1" {
                $exitCode = Start-RobocurseMain -ConfigPath "config<script>.json" -Headless -AllProfiles -ErrorAction SilentlyContinue 2>$null 3>$null
                $exitCode | Should -Be 1
            }

            It "Should accept valid config path format" {
                # Test that a normal path passes the security check
                # Even though file doesn't exist, the path itself is valid
                $result = Test-SafeConfigPath -Path "C:\ValidPath\config.json"
                $result | Should -Be $true
            }
        }

        Context "Start-RobocurseMain Headless Mode Validation" {
            BeforeEach {
                # Create a valid test config file
                $script:testConfigPath = Join-Path $script:testTempDir "test.config.json"
                $testConfig = @{
                    version = "1.0"
                    profiles = @{
                        TestProfile = @{
                            source = @{ path = "C:\Source" }
                            destination = @{ path = "C:\Dest" }
                        }
                        DisabledProfile = @{
                            enabled = $false
                            source = @{ path = "C:\Source2" }
                            destination = @{ path = "C:\Dest2" }
                        }
                    }
                    global = @{
                        performance = @{ maxConcurrentJobs = 4 }
                        logging = @{ operationalLog = @{ path = ".\Logs" } }
                    }
                }
                $testConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $script:testConfigPath
            }

            It "Should return exit code 1 when headless mode without -Profile or -AllProfiles" {
                $exitCode = Start-RobocurseMain -Headless -ConfigPath $script:testConfigPath -ErrorAction SilentlyContinue 2>$null 3>$null
                $exitCode | Should -Be 1
            }

            It "Should error when headless mode missing profile parameter" {
                { Start-RobocurseMain -Headless -ConfigPath $script:testConfigPath -ErrorAction Stop } | Should -Throw "*-Profile*-AllProfiles*"
            }

            It "Should return exit code 1 when config file not found in headless mode" {
                $exitCode = Start-RobocurseMain -Headless -ConfigPath "C:\NonExistent\config.json" -AllProfiles -ErrorAction SilentlyContinue 2>$null 3>$null
                $exitCode | Should -Be 1
            }

            It "Should return exit code 1 when specified profile not found" {
                $exitCode = Start-RobocurseMain -Headless -ConfigPath $script:testConfigPath -ProfileName "NonExistentProfile" -ErrorAction SilentlyContinue 2>$null 3>$null
                $exitCode | Should -Be 1
            }

            It "Should throw with available profiles when specified profile not found" {
                { Start-RobocurseMain -Headless -ConfigPath $script:testConfigPath -ProfileName "NonExistentProfile" -ErrorAction Stop } | Should -Throw "*TestProfile*"
            }

            It "Should warn when both -Profile and -AllProfiles specified" {
                # Mock to prevent actual replication
                Mock Invoke-HeadlessReplication { return 0 }
                $warnings = Start-RobocurseMain -Headless -ConfigPath $script:testConfigPath -ProfileName "TestProfile" -AllProfiles 3>&1 2>$null
                $warningText = $warnings -join " "
                $warningText | Should -Match "-Profile.*-AllProfiles"
            }
        }

        Context "Start-RobocurseMain No Enabled Profiles" {
            It "Should return exit code 1 when no enabled profiles exist" {
                # Create config with only disabled profiles
                $disabledConfigPath = Join-Path $script:testTempDir "disabled.config.json"
                $disabledConfig = @{
                    version = "1.0"
                    profiles = @{
                        Profile1 = @{
                            enabled = $false
                            source = @{ path = "C:\Source1" }
                            destination = @{ path = "C:\Dest1" }
                        }
                        Profile2 = @{
                            enabled = $false
                            source = @{ path = "C:\Source2" }
                            destination = @{ path = "C:\Dest2" }
                        }
                    }
                    global = @{
                        performance = @{ maxConcurrentJobs = 4 }
                        logging = @{ operationalLog = @{ path = ".\Logs" } }
                    }
                }
                $disabledConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $disabledConfigPath

                $exitCode = Start-RobocurseMain -Headless -ConfigPath $disabledConfigPath -AllProfiles -ErrorAction SilentlyContinue 2>$null 3>$null
                $exitCode | Should -Be 1
            }

            It "Should throw about no enabled profiles" {
                $disabledConfigPath = Join-Path $script:testTempDir "disabled2.config.json"
                $disabledConfig = @{
                    version = "1.0"
                    profiles = @{
                        Profile1 = @{
                            enabled = $false
                            source = @{ path = "C:\Source1" }
                            destination = @{ path = "C:\Dest1" }
                        }
                    }
                    global = @{
                        performance = @{ maxConcurrentJobs = 4 }
                        logging = @{ operationalLog = @{ path = ".\Logs" } }
                    }
                }
                $disabledConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $disabledConfigPath

                { Start-RobocurseMain -Headless -ConfigPath $disabledConfigPath -AllProfiles -ErrorAction Stop } | Should -Throw "*No enabled profiles*"
            }
        }

        Context "Start-RobocurseMain GUI Mode" {
            It "Should use default config when config file not found in GUI mode" {
                Mock New-DefaultConfig { return [PSCustomObject]@{ SyncProfiles = @() } } -Verifiable
                Mock Initialize-RobocurseGui { return $null }

                Start-RobocurseMain -ConfigPath "C:\NonExistent\config.json" -ErrorAction SilentlyContinue 2>$null 3>$null
                Should -Invoke New-DefaultConfig -Times 1
            }

            It "Should return exit code 1 when GUI initialization fails" {
                Mock Initialize-RobocurseGui { return $null }

                # Create a valid config so we get to GUI init
                $guiConfigPath = Join-Path $script:testTempDir "gui.config.json"
                $guiConfig = @{
                    version = "1.0"
                    profiles = @{}
                    global = @{ performance = @{ maxConcurrentJobs = 4 } }
                }
                $guiConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $guiConfigPath

                $exitCode = Start-RobocurseMain -ConfigPath $guiConfigPath -ErrorAction SilentlyContinue 2>$null 3>$null
                $exitCode | Should -Be 1
            }

            It "Should throw with suggestion for headless mode when GUI fails" {
                Mock Initialize-RobocurseGui { return $null }

                $guiConfigPath = Join-Path $script:testTempDir "gui2.config.json"
                $guiConfig = @{
                    version = "1.0"
                    profiles = @{}
                    global = @{ performance = @{ maxConcurrentJobs = 4 } }
                }
                $guiConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $guiConfigPath

                { Start-RobocurseMain -ConfigPath $guiConfigPath -ErrorAction Stop } | Should -Throw "*-Headless*"
            }
        }

        Context "Start-RobocurseMain Logging Initialization" {
            It "Should initialize logging before replication in headless mode" {
                $logInitCalled = $false
                Mock Initialize-LogSession { $script:logInitCalled = $true }
                Mock Invoke-HeadlessReplication {
                    if (-not $script:logInitCalled) { throw "Logging not initialized" }
                    return 0
                }

                $configPath = Join-Path $script:testTempDir "logging.config.json"
                $config = @{
                    version = "1.0"
                    profiles = @{
                        Test = @{
                            source = @{ path = "C:\Source" }
                            destination = @{ path = "C:\Dest" }
                        }
                    }
                    global = @{
                        performance = @{ maxConcurrentJobs = 4 }
                        logging = @{ operationalLog = @{ path = ".\Logs" } }
                    }
                }
                $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath

                Start-RobocurseMain -Headless -ConfigPath $configPath -AllProfiles 2>$null 3>$null
                Should -Invoke Initialize-LogSession -Times 1
            }
        }
    }

    Describe "Invoke-HeadlessReplication" {
        BeforeAll {
            # Initialize C# type for orchestration state
            Initialize-OrchestrationStateType | Out-Null

            # Create our own temp directory (separate from Main Entry Point tests)
            $script:HeadlessTempDir = Join-Path $env:TEMP "RobocurseHeadlessTests_$(Get-Random)"
            New-Item -Path $script:HeadlessTempDir -ItemType Directory -Force | Out-Null

            # Create a test config file for ConfigPath parameter
            $script:HeadlessTestConfigPath = Join-Path $script:HeadlessTempDir "headless-test-config.json"
            @{ Version = "1.0"; SyncProfiles = @() } | ConvertTo-Json | Out-File -FilePath $script:HeadlessTestConfigPath -Encoding utf8
        }

        AfterAll {
            # Cleanup temp directory
            if (Test-Path $script:HeadlessTempDir) {
                Remove-Item -Path $script:HeadlessTempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        BeforeEach {
            # Reset orchestration state
            $script:OrchestrationState.Reset()

            # Mock dependencies
            Mock Write-RobocurseLog { }
            Mock Write-SiemEvent { }
            Mock Start-ReplicationRun { }
            Mock Invoke-ReplicationTick { }
            Mock Set-OrchestrationSessionId { }
            Mock Get-LogPath {
                param($Type, $ChunkId)
                if ($Type -eq 'ChunkJob') {
                    return "C:\Logs\2025-12-25\Jobs\test-session_Chunk_001.log"
                }
                return $null
            }
            Mock Get-OrchestrationStatus {
                return [PSCustomObject]@{
                    ChunksComplete = 10
                    ChunksTotal = 10
                    ChunksFailed = 0
                    BytesComplete = 1000000
                    FilesCopied = 100
                    Elapsed = [timespan]::FromMinutes(5)
                    ETA = [timespan]::Zero
                    CurrentProfile = "TestProfile"
                }
            }
            Mock Format-FileSize { return "1 MB" }
            Mock Send-CompletionEmail { return [PSCustomObject]@{ Success = $true } }
        }

        Context "Exit Code Determination" {
            It "Should return 0 when replication succeeds with no failures" {
                # Set phase to Complete immediately
                $script:OrchestrationState.Phase = "Complete"

                $config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{ Enabled = $false }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "C:\Dest"
                }

                $exitCode = Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 6>&1 | Out-Null
                $exitCode = Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4
                $exitCode | Should -Be 0
            }

            It "Should return 1 when chunks failed" {
                $script:OrchestrationState.Phase = "Complete"

                # Mock to return failed chunks
                Mock Get-OrchestrationStatus {
                    return [PSCustomObject]@{
                        ChunksComplete = 8
                        ChunksTotal = 10
                        ChunksFailed = 2
                        BytesComplete = 800000
                        FilesCopied = 80
                        Elapsed = [timespan]::FromMinutes(5)
                        ETA = [timespan]::Zero
                        CurrentProfile = "TestProfile"
                    }
                }

                $config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{ Enabled = $false }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "C:\Dest"
                }

                $exitCode = Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 6>&1 | Out-Null
                $exitCode = Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4
                $exitCode | Should -Be 1
            }

            It "Should return 1 when orchestration was stopped" {
                $script:OrchestrationState.Phase = "Stopped"

                $config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{ Enabled = $false }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "C:\Dest"
                }

                $exitCode = Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 6>&1 | Out-Null
                $exitCode = Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4
                $exitCode | Should -Be 1
            }
        }

        Context "DryRun Mode" {
            It "Should display dry-run message when DryRun is enabled" {
                $script:OrchestrationState.Phase = "Complete"

                $config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{ Enabled = $false }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "C:\Dest"
                }

                $output = Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 -DryRun 6>&1
                $outputText = $output -join "`n"
                $outputText | Should -Match "DRY-RUN"
            }

            It "Should pass DryRun flag to Start-ReplicationRun" {
                $script:OrchestrationState.Phase = "Complete"
                Mock Start-ReplicationRun { } -Verifiable

                $config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{ Enabled = $false }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "C:\Dest"
                }

                Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 -DryRun 6>&1 | Out-Null
                Should -Invoke Start-ReplicationRun -ParameterFilter { $DryRun -eq $true }
            }
        }

        Context "Email Notification" {
            It "Should send email when email is enabled and configured" {
                $script:OrchestrationState.Phase = "Complete"
                Mock Send-CompletionEmail { return [PSCustomObject]@{ Success = $true } } -Verifiable

                $config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{
                        Enabled = $true
                        SmtpServer = "smtp.test.com"
                        From = "test@test.com"
                        To = @("recipient@test.com")
                    }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "C:\Dest"
                }

                Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 6>&1 | Out-Null
                Should -Invoke Send-CompletionEmail -Times 1
            }

            It "Should not send email when email is disabled" {
                $script:OrchestrationState.Phase = "Complete"
                Mock Send-CompletionEmail { throw "Should not be called" }

                $config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{ Enabled = $false }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "C:\Dest"
                }

                Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 6>&1 | Out-Null
                Should -Invoke Send-CompletionEmail -Times 0
            }

            It "Should still return 0 when email fails but replication succeeds" {
                $script:OrchestrationState.Phase = "Complete"
                Mock Send-CompletionEmail { return [PSCustomObject]@{ Success = $false; ErrorMessage = "SMTP error" } }

                $config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{
                        Enabled = $true
                        To = @("test@test.com")
                    }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "C:\Dest"
                }

                $exitCode = Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 6>&1 | Out-Null
                $exitCode = Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4
                # Email failure alone should not cause exit code 1
                $exitCode | Should -Be 0
            }
        }

        Context "Bandwidth Limit Display" {
            It "Should display bandwidth limit when configured" {
                $script:OrchestrationState.Phase = "Complete"

                $config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{ Enabled = $false }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "C:\Dest"
                }

                $output = Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 -BandwidthLimitMbps 100 6>&1
                $outputText = $output -join "`n"
                $outputText | Should -Match "Bandwidth limit.*100"
            }

            It "Should not display bandwidth limit when set to 0" {
                $script:OrchestrationState.Phase = "Complete"

                $config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{ Enabled = $false }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "C:\Dest"
                }

                $output = Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 -BandwidthLimitMbps 0 6>&1
                $outputText = $output -join "`n"
                $outputText | Should -Not -Match "Bandwidth limit"
            }
        }

        Context "Multiple Profiles Display" {
            It "Should display all profile names at start" {
                $script:OrchestrationState.Phase = "Complete"

                $config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{ Enabled = $false }
                }
                $profile1 = [PSCustomObject]@{ Name = "Profile1"; Source = "C:\S1"; Destination = "C:\D1" }
                $profile2 = [PSCustomObject]@{ Name = "Profile2"; Source = "C:\S2"; Destination = "C:\D2" }

                $output = Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile1, $profile2) -MaxConcurrentJobs 4 6>&1
                $outputText = $output -join "`n"
                $outputText | Should -Match "Profile1.*Profile2"
            }
        }

        Context "Failed Files Summary Attachment" {
            It "Should generate failed files summary when FilesFailed > 0" {
                $script:OrchestrationState.Phase = "Complete"

                # Mock status with failed files
                Mock Get-OrchestrationStatus {
                    return [PSCustomObject]@{
                        ChunksComplete = 10
                        ChunksTotal = 10
                        ChunksFailed = 0
                        BytesComplete = 1000000
                        FilesCopied = 100
                        FilesSkipped = 50
                        FilesFailed = 1
                        Elapsed = [timespan]::FromMinutes(5)
                        ETA = [timespan]::Zero
                        CurrentProfile = "TestProfile"
                    }
                }

                Mock New-FailedFilesSummary { return "C:\Logs\2025-12-25\FailedFiles.txt" }
                Mock Send-ReplicationCompletionNotification { return [PSCustomObject]@{ Success = $true; Skipped = $false } }

                $config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{ Enabled = $true }
                    GlobalSettings = [PSCustomObject]@{ LogPath = ".\Logs" }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "C:\Dest"
                }

                Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 6>&1 | Out-Null

                Should -Invoke New-FailedFilesSummary -Times 1
            }

            It "Should pass FailedFilesSummaryPath to Send-ReplicationCompletionNotification" {
                $script:OrchestrationState.Phase = "Complete"

                Mock Get-OrchestrationStatus {
                    return [PSCustomObject]@{
                        ChunksComplete = 10
                        ChunksTotal = 10
                        ChunksFailed = 0
                        BytesComplete = 1000000
                        FilesCopied = 100
                        FilesSkipped = 50
                        FilesFailed = 1
                        Elapsed = [timespan]::FromMinutes(5)
                        ETA = [timespan]::Zero
                        CurrentProfile = "TestProfile"
                    }
                }

                $expectedPath = "C:\Logs\2025-12-25\FailedFiles.txt"
                Mock New-FailedFilesSummary { return $expectedPath }
                Mock Send-ReplicationCompletionNotification { return [PSCustomObject]@{ Success = $true; Skipped = $false } }

                $config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{ Enabled = $true }
                    GlobalSettings = [PSCustomObject]@{ LogPath = ".\Logs" }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "C:\Dest"
                }

                Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 6>&1 | Out-Null

                Should -Invoke Send-ReplicationCompletionNotification -Times 1 -ParameterFilter {
                    $FailedFilesSummaryPath -eq $expectedPath
                }
            }

            It "Should not generate failed files summary when FilesFailed is 0" {
                $script:OrchestrationState.Phase = "Complete"

                Mock Get-OrchestrationStatus {
                    return [PSCustomObject]@{
                        ChunksComplete = 10
                        ChunksTotal = 10
                        ChunksFailed = 0
                        BytesComplete = 1000000
                        FilesCopied = 100
                        FilesSkipped = 50
                        FilesFailed = 0
                        Elapsed = [timespan]::FromMinutes(5)
                        ETA = [timespan]::Zero
                        CurrentProfile = "TestProfile"
                    }
                }

                Mock New-FailedFilesSummary { throw "Should not be called" }
                Mock Send-ReplicationCompletionNotification { return [PSCustomObject]@{ Success = $true; Skipped = $false } }

                $config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{ Enabled = $true }
                    GlobalSettings = [PSCustomObject]@{ LogPath = ".\Logs" }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "C:\Dest"
                }

                Invoke-HeadlessReplication -Config $config -ConfigPath $script:HeadlessTestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 6>&1 | Out-Null

                Should -Invoke New-FailedFilesSummary -Times 0
            }
        }
    }
}
