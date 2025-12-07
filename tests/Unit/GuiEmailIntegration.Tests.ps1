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
                }
            }

            It "Should call Send-CompletionEmail when email is enabled" {
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

                Mock Send-CompletionEmail {
                    return [PSCustomObject]@{ Success = $true }
                }

                Complete-GuiReplication

                Should -Invoke Send-CompletionEmail -Times 1
            }

            It "Should NOT call Send-CompletionEmail when email is disabled" {
                # Setup config with email disabled
                $script:Config = [PSCustomObject]@{
                    Email = [PSCustomObject]@{
                        Enabled = $false
                    }
                }

                Mock Send-CompletionEmail { }

                Complete-GuiReplication

                Should -Not -Invoke Send-CompletionEmail
            }

            It "Should NOT call Send-CompletionEmail when Email config is null" {
                # Setup config with no email section
                $script:Config = [PSCustomObject]@{}

                Mock Send-CompletionEmail { }

                Complete-GuiReplication

                Should -Not -Invoke Send-CompletionEmail
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

                Mock Send-CompletionEmail {
                    return [PSCustomObject]@{ Success = $true }
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

                Mock Send-CompletionEmail {
                    return [PSCustomObject]@{ Success = $false; ErrorMessage = "Credential not found" }
                }

                $logMessages = @()
                Mock Write-GuiLog { param($Message) $script:logMessages += $Message }

                Complete-GuiReplication

                $script:logMessages -join "`n" | Should -Match "ERROR.*Failed to send completion email.*Credential not found"
            }

            It "Should build results object with correct structure" {
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

                $capturedResults = $null
                Mock Send-CompletionEmail {
                    param($Config, $Results, $Status)
                    $script:capturedResults = $Results
                    return [PSCustomObject]@{ Success = $true }
                }

                Complete-GuiReplication

                # Verify the results object has expected properties
                Should -Invoke Send-CompletionEmail -Times 1
                $script:capturedResults | Should -Not -BeNullOrEmpty
                $script:capturedResults.Duration | Should -Not -BeNullOrEmpty
                $script:capturedResults.TotalBytesCopied | Should -BeGreaterOrEqual 0
                $script:capturedResults.TotalFilesCopied | Should -BeGreaterOrEqual 0
                $script:capturedResults.Profiles | Should -Not -BeNullOrEmpty
            }
        }
    }
}
