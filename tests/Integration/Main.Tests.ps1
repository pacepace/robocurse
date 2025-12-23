#Requires -Modules Pester

<#
.SYNOPSIS
    Integration tests for Main.ps1 entry point

.DESCRIPTION
    Tests the main entry point functions including:
    - Start-RobocurseMain parameter handling
    - Headless mode execution
    - Configuration loading
    - Profile resolution
    - Error handling and exit codes
#>

# Load module at discovery time
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type (required for module isolation when running all tests together)
Initialize-OrchestrationStateType | Out-Null

Describe "Main Entry Point Tests" -Tag "Main", "Integration" {

    BeforeAll {
        # Ensure OrchestrationState is initialized before any tests run
        InModuleScope 'Robocurse' {
            Initialize-OrchestrationStateType | Out-Null
        }

        # Create test directory
        $script:TestDir = Join-Path ([System.IO.Path]::GetTempPath()) "Robocurse-Main-Test-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null

        # Create a valid test config
        $script:TestConfigPath = Join-Path $script:TestDir "test-config.json"
        $testConfig = @{
            version = "1.0"
            profiles = @{
                TestProfile = @{
                    description = "Test profile"
                    enabled = $true
                    source = @{ path = "C:\TestSource" }
                    destination = @{ path = "C:\TestDest" }
                }
                DisabledProfile = @{
                    description = "Disabled profile"
                    enabled = $false
                    source = @{ path = "C:\Source2" }
                    destination = @{ path = "C:\Dest2" }
                }
            }
            global = @{
                performance = @{
                    maxConcurrentJobs = 2
                }
                logging = @{
                    operationalLog = @{
                        path = ".\Logs"
                    }
                }
            }
        }
        $testConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:TestConfigPath -Encoding utf8
    }

    AfterAll {
        # Cleanup
        if ($script:TestDir -and (Test-Path $script:TestDir)) {
            Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        # Ensure OrchestrationState is initialized before each test
        InModuleScope 'Robocurse' {
            Initialize-OrchestrationStateType | Out-Null
        }
    }

    Context "Show-RobocurseHelp" {

        It "Should display help text without errors" {
            InModuleScope 'Robocurse' {
                $output = Show-RobocurseHelp 6>&1

                # Should contain key help elements
                $outputText = $output -join "`n"
                $outputText | Should -Match "Robocurse"
                $outputText | Should -Match "-Headless"
                $outputText | Should -Match "-Profile"
                $outputText | Should -Match "-ConfigPath"
            }
        }

        It "Should return exit code 0 from Start-RobocurseMain -ShowHelp" {
            InModuleScope 'Robocurse' {
                $result = Start-RobocurseMain -ShowHelp

                $result | Should -Be 0
            }
        }
    }

    Context "Start-RobocurseMain Parameter Validation" {

        It "Should require either -Profile or -AllProfiles in headless mode" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                # Temporarily allow Continue so Write-Error doesn't terminate
                $oldEAP = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $result = Start-RobocurseMain -Headless -ConfigPath $ConfigPath 2>&1
                $ErrorActionPreference = $oldEAP

                # Should return error exit code - convert ErrorRecord to string
                ($result | Out-String) | Should -Match "requires either -Profile|AllProfiles"
            }
        }

        It "Should warn when both -Profile and -AllProfiles are specified" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Initialize-OrchestrationStateType | Out-Null
                Mock Write-Warning { $script:WarningCalled = $true }
                Mock Start-ReplicationRun { }
                Mock Invoke-ReplicationTick { }
                Mock Get-OrchestrationStatus { @{ Phase = 'Complete'; ChunksTotal = 1; ChunksComplete = 1; ChunksFailed = 0; Elapsed = [timespan]::FromSeconds(10); FilesCopied = 1; BytesComplete = 1000 } }
                Mock Initialize-LogSession { @{ SessionId = "test" } }

                # Set state to complete to exit loop
                $script:OrchestrationState.Phase = "Complete"

                Start-RobocurseMain -Headless -ConfigPath $ConfigPath -ProfileName "TestProfile" -AllProfiles 2>$null

                $script:WarningCalled | Should -Be $true
            }
        }

        It "Should reject unsafe config paths" {
            InModuleScope 'Robocurse' {
                # Path with shell injection attempt
                $unsafePath = "C:\Config; malicious-command"

                $oldEAP = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $result = Start-RobocurseMain -Headless -ConfigPath $unsafePath -AllProfiles 2>&1
                $ErrorActionPreference = $oldEAP

                ($result | Out-String) | Should -Match "unsafe"
            }
        }

        It "Should reject config paths with command substitution" {
            InModuleScope 'Robocurse' {
                $unsafePath = 'C:\Config\$(whoami).json'

                $oldEAP = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $result = Start-RobocurseMain -Headless -ConfigPath $unsafePath -AllProfiles 2>&1
                $ErrorActionPreference = $oldEAP

                ($result | Out-String) | Should -Match "unsafe"
            }
        }
    }

    Context "Configuration Loading" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                Initialize-OrchestrationStateType | Out-Null
            }
        }

        It "Should load valid configuration file" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Initialize-OrchestrationStateType | Out-Null
                Mock Start-ReplicationRun { }
                Mock Invoke-ReplicationTick { }
                Mock Get-OrchestrationStatus { @{ Phase = 'Complete'; ChunksTotal = 1; ChunksComplete = 1; ChunksFailed = 0; Elapsed = [timespan]::FromSeconds(10); FilesCopied = 1; BytesComplete = 1000 } }
                Mock Initialize-LogSession { @{ SessionId = "test" } }
                Mock Send-CompletionEmail { @{ Success = $true } }

                $script:OrchestrationState.Reset()
                $script:OrchestrationState.Phase = "Complete"

                # Should not throw
                { Start-RobocurseMain -Headless -ConfigPath $ConfigPath -ProfileName "TestProfile" 2>&1 } | Should -Not -Throw
            }
        }

        It "Should return error for missing config in headless mode" {
            InModuleScope 'Robocurse' {
                $missingPath = Join-Path $TestDrive "nonexistent.json"

                $oldEAP = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $result = Start-RobocurseMain -Headless -ConfigPath $missingPath -AllProfiles 2>&1
                $ErrorActionPreference = $oldEAP

                ($result | Out-String) | Should -Match "Configuration file required|not found"
            }
        }

        It "Should handle malformed JSON config" {
            $badConfigPath = Join-Path $script:TestDir "bad-config.json"
            "{ invalid json" | Out-File -FilePath $badConfigPath -Encoding utf8

            InModuleScope 'Robocurse' -ArgumentList $badConfigPath {
                param($ConfigPath)

                Mock Initialize-LogSession { @{ SessionId = "test" } }

                $oldEAP = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                # Get-RobocurseConfig returns default on parse error with no profiles
                # so Start-RobocurseMain should fail with "no enabled profiles"
                $result = Start-RobocurseMain -Headless -ConfigPath $ConfigPath -AllProfiles 2>&1
                $ErrorActionPreference = $oldEAP

                ($result | Out-String) | Should -Match "No enabled profiles|parse error"
            }
        }
    }

    Context "Profile Resolution" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                Initialize-OrchestrationStateType | Out-Null
            }
        }

        It "Should find profile by name" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Initialize-OrchestrationStateType | Out-Null
                Mock Start-ReplicationRun {
                    param($Profiles)
                    $script:ResolvedProfiles = $Profiles
                }
                Mock Invoke-ReplicationTick { }
                Mock Get-OrchestrationStatus { @{ Phase = 'Complete'; ChunksTotal = 1; ChunksComplete = 1; ChunksFailed = 0; Elapsed = [timespan]::FromSeconds(10); FilesCopied = 1; BytesComplete = 1000 } }
                Mock Initialize-LogSession { @{ SessionId = "test" } }

                $script:OrchestrationState.Reset()
                $script:OrchestrationState.Phase = "Complete"

                Start-RobocurseMain -Headless -ConfigPath $ConfigPath -ProfileName "TestProfile" 2>&1 | Out-Null

                $script:ResolvedProfiles | Should -Not -BeNullOrEmpty
                $script:ResolvedProfiles[0].Name | Should -Be "TestProfile"
            }
        }

        It "Should return error for non-existent profile" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Mock Initialize-LogSession { @{ SessionId = "test" } }

                $oldEAP = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $result = Start-RobocurseMain -Headless -ConfigPath $ConfigPath -ProfileName "NonExistent" 2>&1
                $ErrorActionPreference = $oldEAP

                ($result | Out-String) | Should -Match "not found|Available profiles"
            }
        }

        It "Should list available profiles when profile not found" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Mock Initialize-LogSession { @{ SessionId = "test" } }

                $oldEAP = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $result = Start-RobocurseMain -Headless -ConfigPath $ConfigPath -ProfileName "NonExistent" 2>&1
                $ErrorActionPreference = $oldEAP

                ($result | Out-String) | Should -Match "TestProfile"
            }
        }

        It "Should filter disabled profiles with -AllProfiles" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Initialize-OrchestrationStateType | Out-Null
                Mock Start-ReplicationRun {
                    param($Profiles)
                    $script:AllResolvedProfiles = $Profiles
                }
                Mock Invoke-ReplicationTick { }
                Mock Get-OrchestrationStatus { @{ Phase = 'Complete'; ChunksTotal = 1; ChunksComplete = 1; ChunksFailed = 0; Elapsed = [timespan]::FromSeconds(10); FilesCopied = 1; BytesComplete = 1000 } }
                Mock Initialize-LogSession { @{ SessionId = "test" } }

                $script:OrchestrationState.Reset()
                $script:OrchestrationState.Phase = "Complete"

                Start-RobocurseMain -Headless -ConfigPath $ConfigPath -AllProfiles 2>&1 | Out-Null

                # Should only include enabled profile
                $script:AllResolvedProfiles.Count | Should -Be 1
                $script:AllResolvedProfiles[0].Name | Should -Be "TestProfile"
            }
        }

        It "Should return error when no enabled profiles exist" {
            # Create config with all profiles disabled
            $disabledConfigPath = Join-Path $script:TestDir "all-disabled.json"
            $disabledConfig = @{
                version = "1.0"
                profiles = @{
                    Profile1 = @{
                        enabled = $false
                        source = @{ path = "C:\S1" }
                        destination = @{ path = "C:\D1" }
                    }
                }
            }
            $disabledConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath $disabledConfigPath -Encoding utf8

            InModuleScope 'Robocurse' -ArgumentList $disabledConfigPath {
                param($ConfigPath)

                Mock Initialize-LogSession { @{ SessionId = "test" } }

                $oldEAP = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $result = Start-RobocurseMain -Headless -ConfigPath $ConfigPath -AllProfiles 2>&1
                $ErrorActionPreference = $oldEAP

                ($result | Out-String) | Should -Match "No enabled profiles"
            }
        }
    }

    Context "Headless Replication Execution" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                Initialize-OrchestrationStateType | Out-Null
                $script:OrchestrationState.Reset()
                Mock Write-RobocurseLog { }
                Mock Write-SiemEvent { }
            }
        }

        It "Should pass DryRun flag to replication" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Initialize-OrchestrationStateType | Out-Null
                Mock Start-ReplicationRun {
                    param($Profiles, $MaxConcurrentJobs, $BandwidthLimitMbps, $DryRun)
                    $script:DryRunPassed = $DryRun
                }
                Mock Invoke-ReplicationTick { }
                Mock Get-OrchestrationStatus { @{ Phase = 'Complete'; ChunksTotal = 1; ChunksComplete = 1; ChunksFailed = 0; Elapsed = [timespan]::FromSeconds(10); FilesCopied = 1; BytesComplete = 1000 } }
                Mock Initialize-LogSession { @{ SessionId = "test" } }

                $script:OrchestrationState.Phase = "Complete"

                Start-RobocurseMain -Headless -ConfigPath $ConfigPath -ProfileName "TestProfile" -DryRun 2>&1 | Out-Null

                $script:DryRunPassed | Should -Be $true
            }
        }

        It "Should use configured MaxConcurrentJobs" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Initialize-OrchestrationStateType | Out-Null
                Mock Start-ReplicationRun {
                    param($Profiles, $MaxConcurrentJobs)
                    $script:MaxJobsPassed = $MaxConcurrentJobs
                }
                Mock Invoke-ReplicationTick { }
                Mock Get-OrchestrationStatus { @{ Phase = 'Complete'; ChunksTotal = 1; ChunksComplete = 1; ChunksFailed = 0; Elapsed = [timespan]::FromSeconds(10); FilesCopied = 1; BytesComplete = 1000 } }
                Mock Initialize-LogSession { @{ SessionId = "test" } }

                $script:OrchestrationState.Phase = "Complete"

                Start-RobocurseMain -Headless -ConfigPath $ConfigPath -ProfileName "TestProfile" 2>&1 | Out-Null

                # Config has maxConcurrentJobs = 2
                $script:MaxJobsPassed | Should -Be 2
            }
        }

        It "Should return 0 on successful completion" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Initialize-OrchestrationStateType | Out-Null
                Mock Start-ReplicationRun { }
                Mock Invoke-ReplicationTick { }
                Mock Get-OrchestrationStatus {
                    @{
                        Phase = 'Complete'
                        ChunksTotal = 10
                        ChunksComplete = 10
                        ChunksFailed = 0
                        Elapsed = [timespan]::FromMinutes(5)
                        FilesCopied = 100
                        BytesComplete = 1000000
                    }
                }
                Mock Initialize-LogSession { @{ SessionId = "test" } }
                Mock Format-FileSize { "1 MB" }

                $script:OrchestrationState.Reset()
                $script:OrchestrationState.Phase = "Complete"

                $result = Start-RobocurseMain -Headless -ConfigPath $ConfigPath -ProfileName "TestProfile" 2>&1 | Select-Object -Last 1

                # Last output should be exit code 0
                $result | Should -Be 0
            }
        }

        It "Should return 1 when chunks fail" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Initialize-OrchestrationStateType | Out-Null
                Mock Start-ReplicationRun { }
                Mock Invoke-ReplicationTick { }
                Mock Get-OrchestrationStatus {
                    @{
                        Phase = 'Complete'
                        ChunksTotal = 10
                        ChunksComplete = 8
                        ChunksFailed = 2
                        Elapsed = [timespan]::FromMinutes(5)
                        FilesCopied = 80
                        BytesComplete = 800000
                    }
                }
                Mock Initialize-LogSession { @{ SessionId = "test" } }
                Mock Format-FileSize { "800 KB" }

                $script:OrchestrationState.Reset()
                $script:OrchestrationState.Phase = "Complete"

                $result = Start-RobocurseMain -Headless -ConfigPath $ConfigPath -ProfileName "TestProfile" 2>&1 | Select-Object -Last 1

                $result | Should -Be 1
            }
        }

        It "Should return 1 when stopped" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Initialize-OrchestrationStateType | Out-Null
                Mock Start-ReplicationRun { }
                Mock Invoke-ReplicationTick { }
                Mock Get-OrchestrationStatus {
                    @{
                        Phase = 'Stopped'
                        ChunksTotal = 10
                        ChunksComplete = 3
                        ChunksFailed = 0
                        Elapsed = [timespan]::FromMinutes(2)
                        FilesCopied = 30
                        BytesComplete = 300000
                    }
                }
                Mock Initialize-LogSession { @{ SessionId = "test" } }
                Mock Format-FileSize { "300 KB" }

                $script:OrchestrationState.Reset()
                $script:OrchestrationState.Phase = "Stopped"

                $result = Start-RobocurseMain -Headless -ConfigPath $ConfigPath -ProfileName "TestProfile" 2>&1 | Select-Object -Last 1

                $result | Should -Be 1
            }
        }
    }

    Context "Invoke-HeadlessReplication" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                Initialize-OrchestrationStateType | Out-Null
                $script:OrchestrationState.Reset()
                Mock Write-RobocurseLog { }
                Mock Write-SiemEvent { }
            }
        }

        It "Should output progress during replication" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($TestConfigPath)
                Initialize-OrchestrationStateType | Out-Null
                $script:OrchestrationState.Reset()
                $config = [PSCustomObject]@{
                    Email = @{ Enabled = $false }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                }

                $tickCount = 0
                Mock Start-ReplicationRun { }
                Mock Invoke-ReplicationTick {
                    $tickCount++
                    if ($tickCount -ge 2) {
                        $script:OrchestrationState.Phase = "Complete"
                    }
                }
                Mock Get-OrchestrationStatus {
                    @{
                        Phase = 'Complete'
                        CurrentProfile = "TestProfile"
                        ChunksTotal = 10
                        ChunksComplete = 5
                        ChunksFailed = 0
                        Elapsed = [timespan]::FromMinutes(1)
                        ETA = [timespan]::FromMinutes(1)
                        FilesCopied = 50
                        BytesComplete = 500000
                    }
                }
                Mock Format-FileSize { "500 KB" }

                # Capture Write-Host output
                $output = Invoke-HeadlessReplication -Config $config -ConfigPath $TestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 6>&1

                $outputText = $output -join "`n"
                $outputText | Should -Match "Starting replication"
                $outputText | Should -Match "TestProfile"
            }
        }

        It "Should send email on completion when configured" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($TestConfigPath)
                $config = [PSCustomObject]@{
                    Email = @{
                        Enabled = $true
                        SmtpServer = "smtp.test.com"
                        From = "from@test.com"
                        To = @("to@test.com")
                    }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                }

                Mock Start-ReplicationRun { }
                Mock Invoke-ReplicationTick {
                    $script:OrchestrationState.Phase = "Complete"
                }
                Mock Get-OrchestrationStatus {
                    @{
                        CurrentProfile = "TestProfile"
                        ChunksTotal = 1
                        ChunksComplete = 1
                        ChunksFailed = 0
                        Elapsed = [timespan]::FromSeconds(30)
                        BytesComplete = 1000
                        FilesCopied = 10
                    }
                }
                Mock Send-CompletionEmail {
                    $script:EmailSent = $true
                    @{ Success = $true }
                }
                Mock Format-FileSize { "1 KB" }

                Invoke-HeadlessReplication -Config $config -ConfigPath $TestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4

                $script:EmailSent | Should -Be $true
            }
        }

        It "Should handle email send failure gracefully" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($TestConfigPath)
                $config = [PSCustomObject]@{
                    Email = @{
                        Enabled = $true
                        SmtpServer = "smtp.test.com"
                        From = "from@test.com"
                        To = @("to@test.com")
                    }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                }

                Mock Start-ReplicationRun { }
                Mock Invoke-ReplicationTick {
                    $script:OrchestrationState.Phase = "Complete"
                }
                Mock Get-OrchestrationStatus {
                    @{
                        CurrentProfile = "TestProfile"
                        ChunksTotal = 1
                        ChunksComplete = 1
                        ChunksFailed = 0
                        Elapsed = [timespan]::FromSeconds(30)
                        BytesComplete = 1000
                        FilesCopied = 10
                    }
                }
                Mock Send-CompletionEmail {
                    @{ Success = $false; ErrorMessage = "SMTP connection failed" }
                }
                Mock Format-FileSize { "1 KB" }

                # Should not throw
                { Invoke-HeadlessReplication -Config $config -ConfigPath $TestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 } | Should -Not -Throw
            }
        }

        It "Should display DryRun mode indicator" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($TestConfigPath)
                $config = [PSCustomObject]@{
                    Email = @{ Enabled = $false }
                }
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                }

                Mock Start-ReplicationRun { }
                Mock Invoke-ReplicationTick {
                    $script:OrchestrationState.Phase = "Complete"
                }
                Mock Get-OrchestrationStatus {
                    @{
                        CurrentProfile = "TestProfile"
                        ChunksTotal = 1
                        ChunksComplete = 1
                        Elapsed = [timespan]::FromSeconds(10)
                        BytesComplete = 0
                        FilesCopied = 0
                    }
                }
                Mock Format-FileSize { "0 B" }

                $output = Invoke-HeadlessReplication -Config $config -ConfigPath $TestConfigPath -ProfilesToRun @($profile) -MaxConcurrentJobs 4 -DryRun 6>&1

                $outputText = $output -join "`n"
                $outputText | Should -Match "DRY-RUN"
            }
        }
    }

    Context "Logging Initialization" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                Initialize-OrchestrationStateType | Out-Null
            }
        }

        It "Should initialize logging before replication" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Initialize-OrchestrationStateType | Out-Null
                Mock Initialize-LogSession {
                    $script:LogSessionCalled = $true
                    @{ SessionId = "test-session" }
                }
                Mock Start-ReplicationRun { }
                Mock Invoke-ReplicationTick { }
                Mock Get-OrchestrationStatus { @{ Phase = 'Complete'; ChunksTotal = 1; ChunksComplete = 1; ChunksFailed = 0; Elapsed = [timespan]::FromSeconds(10); FilesCopied = 1; BytesComplete = 1000 } }

                $script:OrchestrationState.Reset()
                $script:OrchestrationState.Phase = "Complete"
                $script:LogSessionCalled = $false

                Start-RobocurseMain -Headless -ConfigPath $ConfigPath -ProfileName "TestProfile" 2>&1 | Out-Null

                $script:LogSessionCalled | Should -Be $true
            }
        }

        It "Should resolve relative log path from config directory" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Initialize-OrchestrationStateType | Out-Null
                Mock Initialize-LogSession {
                    param($LogRoot, $CompressAfterDays, $DeleteAfterDays)
                    $script:ResolvedLogRoot = $LogRoot
                    @{ SessionId = "test" }
                }
                Mock Start-ReplicationRun { }
                Mock Invoke-ReplicationTick { }
                Mock Get-OrchestrationStatus { @{ Phase = 'Complete'; ChunksTotal = 1; ChunksComplete = 1; ChunksFailed = 0; Elapsed = [timespan]::FromSeconds(10); FilesCopied = 1; BytesComplete = 1000 } }

                $script:OrchestrationState.Reset()
                $script:OrchestrationState.Phase = "Complete"

                Start-RobocurseMain -Headless -ConfigPath $ConfigPath -ProfileName "TestProfile" 2>&1 | Out-Null

                # Log path should be resolved relative to config file
                $script:ResolvedLogRoot | Should -Not -BeNullOrEmpty
                [System.IO.Path]::IsPathRooted($script:ResolvedLogRoot) | Should -Be $true
            }
        }
    }

    Context "Error Handling" {

        BeforeEach {
            InModuleScope 'Robocurse' {
                Initialize-OrchestrationStateType | Out-Null
            }
        }

        It "Should handle exception during replication" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Mock Initialize-LogSession { @{ SessionId = "test" } }
                Mock Start-ReplicationRun {
                    throw "Simulated replication failure"
                }

                $oldEAP = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $result = Start-RobocurseMain -Headless -ConfigPath $ConfigPath -ProfileName "TestProfile" 2>&1
                $ErrorActionPreference = $oldEAP

                ($result | Out-String) | Should -Match "Replication failed|Simulated"
            }
        }

        It "Should clean up health check file on exit" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath, $script:TestDir {
                param($ConfigPath, $TestDir)

                Initialize-OrchestrationStateType | Out-Null
                $healthFile = Join-Path $TestDir "health-test.json"
                $script:HealthCheckStatusFile = $healthFile

                # Create a health file
                @{ Phase = "Running" } | ConvertTo-Json | Out-File -FilePath $healthFile -Encoding utf8

                Mock Initialize-LogSession { @{ SessionId = "test" } }
                Mock Start-ReplicationRun { }
                Mock Invoke-ReplicationTick { }
                Mock Get-OrchestrationStatus { @{ Phase = 'Complete'; ChunksTotal = 1; ChunksComplete = 1; ChunksFailed = 0; Elapsed = [timespan]::FromSeconds(10); FilesCopied = 1; BytesComplete = 1000 } }

                $script:OrchestrationState.Reset()
                $script:OrchestrationState.Phase = "Complete"

                Start-RobocurseMain -Headless -ConfigPath $ConfigPath -ProfileName "TestProfile" 2>&1 | Out-Null

                # Health file should be cleaned up
                Test-Path $healthFile | Should -Be $false
            }
        }
    }

    Context "GUI Mode" -Skip:(-not (Test-Path "C:\Windows\System32\PresentationFramework.dll")) {

        It "Should attempt to initialize GUI when not in headless mode" {
            InModuleScope 'Robocurse' -ArgumentList $script:TestConfigPath {
                param($ConfigPath)

                Mock Initialize-RobocurseGui {
                    $script:GuiInitCalled = $true
                    $null  # Return null to simulate GUI init failure gracefully
                }

                $script:GuiInitCalled = $false

                Start-RobocurseMain -ConfigPath $ConfigPath 2>&1 | Out-Null

                $script:GuiInitCalled | Should -Be $true
            }
        }
    }
}

Describe "Format-FileSize Helper" -Tag "Main", "Unit" {

    BeforeAll {
        $testRoot = $PSScriptRoot
        $projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
        $modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
        Import-Module $modulePath -Force -Global -DisableNameChecking
    }

    Context "Size Formatting" {

        It "Should format bytes correctly" {
            InModuleScope 'Robocurse' {
                $result = Format-FileSize -Bytes 500

                $result | Should -Match "500.*B"
            }
        }

        It "Should format kilobytes correctly" {
            InModuleScope 'Robocurse' {
                $result = Format-FileSize -Bytes 5120

                $result | Should -Match "5.*KB"
            }
        }

        It "Should format megabytes correctly" {
            InModuleScope 'Robocurse' {
                $result = Format-FileSize -Bytes 5242880

                $result | Should -Match "5.*MB"
            }
        }

        It "Should format gigabytes correctly" {
            InModuleScope 'Robocurse' {
                $result = Format-FileSize -Bytes 5368709120

                $result | Should -Match "5.*GB"
            }
        }

        It "Should handle zero bytes" {
            InModuleScope 'Robocurse' {
                $result = Format-FileSize -Bytes 0

                $result | Should -Match "0"
            }
        }
    }
}
