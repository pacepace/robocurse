#Requires -Modules Pester

# Load WPF assemblies for GUI types
Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "GUI Email Integration Tests" {

        Context "Complete-GuiReplication Email Sending" {
            BeforeAll {
                # Mock GUI dependencies
                Mock Write-GuiLog { }
                Mock Show-CompletionDialog { }
                Mock Save-LastRunSummary { }
                Mock Close-ReplicationRunspace { }
                Mock Get-OrchestrationStatus {
                    [PSCustomObject]@{
                        ChunksComplete = 5
                        ChunksTotal = 5
                        ChunksFailed = 0
                        BytesComplete = 1GB
                        FilesCopied = 100
                    }
                }

                # Setup script-scoped variables that Complete-GuiReplication expects
                $script:ProgressTimer = [PSCustomObject]@{}
                $script:ProgressTimer | Add-Member -MemberType ScriptMethod -Name 'Stop' -Value { }

                $script:Controls = @{
                    btnRunAll = [PSCustomObject]@{ IsEnabled = $false }
                    btnRunSelected = [PSCustomObject]@{ IsEnabled = $false }
                    btnStop = [PSCustomObject]@{ IsEnabled = $true }
                    txtStatus = [PSCustomObject]@{ Text = ""; Foreground = $null }
                }

                $script:GuiErrorCount = 0
                $script:ReplicationPowerShell = $null
                $script:ConfigSnapshotPath = $null

                $script:OrchestrationState = [PSCustomObject]@{
                    StartTime = [datetime]::Now.AddMinutes(-5)
                    Profiles = @(
                        [PSCustomObject]@{ Name = "TestProfile" }
                    )
                    SessionId = "test-session-id"
                    FailedChunks = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
                    WarningChunks = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
                }
                # Add method for getting profile results
                $script:OrchestrationState | Add-Member -MemberType ScriptMethod -Name 'GetProfileResultsArray' -Value {
                    return @([PSCustomObject]@{
                        Name = "TestProfile"
                        Status = "Success"
                        PreflightError = $null
                        ChunksComplete = 5
                        ChunksTotal = 5
                        ChunksFailed = 0
                    })
                }
            }

            It "Should call Send-ReplicationCompletionNotification when email is enabled" {
                # Setup config with email enabled
                $script:Config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{
                        Enabled = $true
                        SmtpServer = "smtp.test.com"
                        Port = 587
                        UseTls = $true
                        CredentialTarget = "Test-SMTP"
                        From = "test@test.com"
                        To = @("user@test.com")
                    }
                }

                Mock Send-ReplicationCompletionNotification {
                    return [PSCustomObject]@{ Success = $true; Skipped = $false }
                }

                Complete-GuiReplication

                Should -Invoke Send-ReplicationCompletionNotification -Times 1
            }

            It "Should skip email when email is disabled" {
                # Setup config with email disabled
                $script:Config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{
                        Enabled = $false
                    }
                }

                Mock Send-ReplicationCompletionNotification {
                    return [PSCustomObject]@{ Success = $true; Skipped = $true }
                }

                $script:logMessages = @()
                Mock Write-GuiLog { param($Message) $script:logMessages += $Message }

                Complete-GuiReplication

                Should -Invoke Send-ReplicationCompletionNotification -Times 1
                ($script:logMessages -join "`n") | Should -Match "not enabled, skipping"
            }

            It "Should skip email when Email config is null" {
                # Setup config with no email section
                $script:Config = [PSCustomObject]@{}

                Mock Send-ReplicationCompletionNotification {
                    return [PSCustomObject]@{ Success = $true; Skipped = $true }
                }

                $script:logMessages = @()
                Mock Write-GuiLog { param($Message) $script:logMessages += $Message }

                Complete-GuiReplication

                Should -Invoke Send-ReplicationCompletionNotification -Times 1
                ($script:logMessages -join "`n") | Should -Match "not enabled, skipping"
            }

            It "Should log success when email sends successfully" {
                $script:Config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{
                        Enabled = $true
                        SmtpServer = "smtp.test.com"
                        Port = 587
                        UseTls = $true
                        CredentialTarget = "Test-SMTP"
                        From = "test@test.com"
                        To = @("user@test.com")
                    }
                }

                Mock Send-ReplicationCompletionNotification {
                    return [PSCustomObject]@{ Success = $true; Skipped = $false }
                }

                $script:logMessages = @()
                Mock Write-GuiLog { param($Message) $script:logMessages += $Message }

                Complete-GuiReplication

                ($script:logMessages -join "`n") | Should -Match "Completion email sent successfully"
            }

            It "Should log error when email fails" {
                $script:Config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{
                        Enabled = $true
                        SmtpServer = "smtp.test.com"
                        Port = 587
                        UseTls = $true
                        CredentialTarget = "Test-SMTP"
                        From = "test@test.com"
                        To = @("user@test.com")
                    }
                }

                Mock Send-ReplicationCompletionNotification {
                    return [PSCustomObject]@{ Success = $false; Skipped = $false; ErrorMessage = "Credential not found" }
                }

                $logMessages = @()
                Mock Write-GuiLog { param($Message) $script:logMessages += $Message }

                Complete-GuiReplication

                $script:logMessages -join "`n" | Should -Match "ERROR.*Failed to send completion email.*Credential not found"
            }

            It "Should call Send-ReplicationCompletionNotification with correct parameters" {
                $script:Config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{
                        Enabled = $true
                        SmtpServer = "smtp.test.com"
                        Port = 587
                        UseTls = $true
                        CredentialTarget = "Test-SMTP"
                        From = "test@test.com"
                        To = @("user@test.com")
                    }
                }

                Mock Send-ReplicationCompletionNotification {
                    param($Config, $OrchestrationState, $FailedFilesSummaryPath)
                    # Verify parameters are passed correctly
                    $Config | Should -Not -BeNullOrEmpty
                    $OrchestrationState | Should -Not -BeNullOrEmpty
                    return [PSCustomObject]@{ Success = $true; Skipped = $false }
                }

                Complete-GuiReplication

                Should -Invoke Send-ReplicationCompletionNotification -Times 1
            }
        }
    }
}
