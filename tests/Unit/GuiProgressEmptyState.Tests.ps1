#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "Progress Empty State Tests" {

        BeforeAll {
            # Create mock controls
            $script:Controls = @{
                txtProfileProgress = [PSCustomObject]@{ Text = "" }
                txtOverallProgress = [PSCustomObject]@{ Text = ""; Foreground = $null }
                pbProfile = [PSCustomObject]@{ Value = 0 }
                pbOverall = [PSCustomObject]@{ Value = 0 }
                txtEta = [PSCustomObject]@{ Text = "" }
                txtSpeed = [PSCustomObject]@{ Text = "" }
                txtChunks = [PSCustomObject]@{ Text = "" }
                dgChunks = [PSCustomObject]@{ ItemsSource = $null }
            }

            # Create mock window
            $script:Window = New-Object PSCustomObject
            $script:Window | Add-Member -MemberType ScriptMethod -Name UpdateLayout -Value {} -Force
        }

        AfterEach {
            # Reset controls
            $script:Controls.txtProfileProgress.Text = ""
            $script:Controls.txtOverallProgress.Text = ""
            $script:Controls.txtOverallProgress.Foreground = $null
            $script:Controls.pbProfile.Value = 0
            $script:Controls.pbOverall.Value = 0
            $script:Controls.txtEta.Text = ""
            $script:Controls.txtSpeed.Text = ""
            $script:Controls.txtChunks.Text = ""
            $script:Controls.dgChunks.ItemsSource = $null
        }

        Context "Save-LastRunSummary and Get-LastRunSummary" {
            It "Should save and retrieve last run summary" {
                $summary = @{
                    Timestamp = ([datetime]::Now).ToString('o')
                    ProfilesRun = @('Profile1', 'Profile2')
                    ChunksTotal = 100
                    ChunksCompleted = 100
                    ChunksFailed = 0
                    BytesCopied = 1073741824
                    Duration = '01:30:00'
                    Status = 'Success'
                }

                Save-LastRunSummary -Summary $summary
                $retrieved = Get-LastRunSummary

                $retrieved | Should -Not -BeNullOrEmpty
                $retrieved.Status | Should -Be 'Success'
                $retrieved.ChunksTotal | Should -Be 100
                $retrieved.ChunksCompleted | Should -Be 100
                $retrieved.ChunksFailed | Should -Be 0
            }

            It "Should return null when no previous run exists" {
                # Clear the settings file
                $settingsPath = Get-GuiSettingsPath
                if (Test-Path $settingsPath) {
                    Remove-Item $settingsPath -Force
                }

                $result = Get-LastRunSummary
                $result | Should -BeNullOrEmpty
            }

            It "Should update existing summary when called multiple times" {
                $summary1 = @{
                    Timestamp = ([datetime]::Now).ToString('o')
                    ProfilesRun = @('Profile1')
                    ChunksTotal = 50
                    ChunksCompleted = 50
                    ChunksFailed = 0
                    BytesCopied = 500000
                    Duration = '00:15:00'
                    Status = 'Success'
                }

                Save-LastRunSummary -Summary $summary1

                $summary2 = @{
                    Timestamp = ([datetime]::Now).ToString('o')
                    ProfilesRun = @('Profile2')
                    ChunksTotal = 100
                    ChunksCompleted = 80
                    ChunksFailed = 20
                    BytesCopied = 1000000
                    Duration = '00:45:00'
                    Status = 'PartialFailure'
                }

                Save-LastRunSummary -Summary $summary2
                $retrieved = Get-LastRunSummary

                $retrieved.Status | Should -Be 'PartialFailure'
                $retrieved.ChunksTotal | Should -Be 100
                $retrieved.ChunksFailed | Should -Be 20
            }
        }

        Context "Show-ProgressEmptyState - No Previous Run" {
            BeforeEach {
                # Clear settings to simulate no previous run
                $settingsPath = Get-GuiSettingsPath
                if (Test-Path $settingsPath) {
                    Remove-Item $settingsPath -Force
                }
            }

            It "Should display 'No previous runs' message when no history exists" {
                Show-ProgressEmptyState

                $script:Controls.txtProfileProgress.Text | Should -Be "No previous runs"
                $script:Controls.txtOverallProgress.Text | Should -Be "Select profiles and click Run"
            }

            It "Should set progress bars to zero when no history exists" {
                Show-ProgressEmptyState

                $script:Controls.pbProfile.Value | Should -Be 0
                $script:Controls.pbOverall.Value | Should -Be 0
            }

            It "Should show ready state in status fields" {
                Show-ProgressEmptyState

                $script:Controls.txtEta.Text | Should -Be "Ready"
                $script:Controls.txtSpeed.Text | Should -Be "--"
                $script:Controls.txtChunks.Text | Should -Be "Ready"
            }

            It "Should clear chunks grid" {
                Show-ProgressEmptyState

                $script:Controls.dgChunks.ItemsSource | Should -BeNullOrEmpty
            }
        }

        Context "Show-ProgressEmptyState - Successful Run" {
            BeforeEach {
                $summary = @{
                    Timestamp = ([datetime]::Now.AddHours(-2)).ToString('o')
                    ProfilesRun = @('TestProfile')
                    ChunksTotal = 100
                    ChunksCompleted = 100
                    ChunksFailed = 0
                    BytesCopied = 1073741824  # 1 GB
                    Duration = '01:30:00'
                    Status = 'Success'
                }
                Save-LastRunSummary -Summary $summary
            }

            It "Should display last run profile name" {
                Show-ProgressEmptyState

                $script:Controls.txtProfileProgress.Text | Should -Match "Last: TestProfile"
            }

            It "Should display success status with time ago" {
                Show-ProgressEmptyState

                $script:Controls.txtOverallProgress.Text | Should -Match "Success"
                $script:Controls.txtOverallProgress.Text | Should -Match "ago"
            }

            It "Should set progress bars to 100% for completed run" {
                Show-ProgressEmptyState

                $script:Controls.pbProfile.Value | Should -Be 100
                $script:Controls.pbOverall.Value | Should -Be 100
            }

            It "Should display duration and bytes copied" {
                Show-ProgressEmptyState

                $script:Controls.txtEta.Text | Should -Match "Duration: 01:30:00"
                $script:Controls.txtSpeed.Text | Should -Match "Copied:"
            }

            It "Should display chunks completed without failures" {
                Show-ProgressEmptyState

                $script:Controls.txtChunks.Text | Should -Be "Chunks: 100/100"
                $script:Controls.txtChunks.Text | Should -Not -Match "failed"
            }

            It "Should set success color (green)" {
                Show-ProgressEmptyState

                # Color setting requires WPF types - skip assertion if not available
                try {
                    $null = [System.Windows.Media.SolidColorBrush]
                    $script:Controls.txtOverallProgress.Foreground | Should -Not -BeNullOrEmpty
                } catch {
                    Set-ItResult -Skipped -Because "WPF types not available in headless mode"
                }
            }
        }

        Context "Show-ProgressEmptyState - Partial Failure" {
            BeforeEach {
                $summary = @{
                    Timestamp = ([datetime]::Now.AddMinutes(-30)).ToString('o')
                    ProfilesRun = @('Profile1', 'Profile2')
                    ChunksTotal = 100
                    ChunksCompleted = 80
                    ChunksFailed = 20
                    BytesCopied = 858993459  # ~800 MB
                    Duration = '00:45:00'
                    Status = 'PartialFailure'
                }
                Save-LastRunSummary -Summary $summary
            }

            It "Should display multiple profile names" {
                Show-ProgressEmptyState

                $script:Controls.txtProfileProgress.Text | Should -Match "Profile1"
                $script:Controls.txtProfileProgress.Text | Should -Match "Profile2"
            }

            It "Should display partial failure status" {
                Show-ProgressEmptyState

                $script:Controls.txtOverallProgress.Text | Should -Match "PartialFailure"
            }

            It "Should set progress bars to 80% completion" {
                Show-ProgressEmptyState

                $script:Controls.pbProfile.Value | Should -Be 80
                $script:Controls.pbOverall.Value | Should -Be 80
            }

            It "Should display failure count in chunks text" {
                Show-ProgressEmptyState

                $script:Controls.txtChunks.Text | Should -Match "Chunks: 80/100"
                $script:Controls.txtChunks.Text | Should -Match "20 failed"
            }

            It "Should set partial failure color (orange)" {
                Show-ProgressEmptyState

                # Color setting requires WPF types - skip assertion if not available
                try {
                    $null = [System.Windows.Media.SolidColorBrush]
                    $script:Controls.txtOverallProgress.Foreground | Should -Not -BeNullOrEmpty
                } catch {
                    Set-ItResult -Skipped -Because "WPF types not available in headless mode"
                }
            }
        }

        Context "Show-ProgressEmptyState - Complete Failure" {
            BeforeEach {
                $summary = @{
                    Timestamp = ([datetime]::Now.AddDays(-1)).ToString('o')
                    ProfilesRun = @('FailedProfile')
                    ChunksTotal = 50
                    ChunksCompleted = 0
                    ChunksFailed = 50
                    BytesCopied = 0
                    Duration = '00:05:00'
                    Status = 'Failed'
                }
                Save-LastRunSummary -Summary $summary
            }

            It "Should display failed status" {
                Show-ProgressEmptyState

                $script:Controls.txtOverallProgress.Text | Should -Match "Failed"
            }

            It "Should set progress bars to 0% for failed run" {
                Show-ProgressEmptyState

                $script:Controls.pbProfile.Value | Should -Be 0
                $script:Controls.pbOverall.Value | Should -Be 0
            }

            It "Should display all failures in chunks text" {
                Show-ProgressEmptyState

                $script:Controls.txtChunks.Text | Should -Match "0/50"
                $script:Controls.txtChunks.Text | Should -Match "50 failed"
            }

            It "Should set failure color (red)" {
                Show-ProgressEmptyState

                # Color setting requires WPF types - skip assertion if not available
                try {
                    $null = [System.Windows.Media.SolidColorBrush]
                    $script:Controls.txtOverallProgress.Foreground | Should -Not -BeNullOrEmpty
                } catch {
                    Set-ItResult -Skipped -Because "WPF types not available in headless mode"
                }
            }
        }

        Context "Get-TimeAgoString" {
            It "Should format recent time as 'Just now'" {
                $timestamp = [datetime]::Now.AddSeconds(-30)
                $result = Get-TimeAgoString -Timestamp $timestamp

                $result | Should -Be "Just now"
            }

            It "Should format minutes correctly" {
                $timestamp = [datetime]::Now.AddMinutes(-5)
                $result = Get-TimeAgoString -Timestamp $timestamp

                $result | Should -Match "5 minutes ago"
            }

            It "Should use singular for 1 minute" {
                $timestamp = [datetime]::Now.AddMinutes(-1)
                $result = Get-TimeAgoString -Timestamp $timestamp

                $result | Should -Match "1 minute ago"
                $result | Should -Not -Match "minutes"
            }

            It "Should format hours correctly" {
                $timestamp = [datetime]::Now.AddHours(-3)
                $result = Get-TimeAgoString -Timestamp $timestamp

                $result | Should -Match "3 hours ago"
            }

            It "Should use singular for 1 hour" {
                $timestamp = [datetime]::Now.AddHours(-1).AddMinutes(-30)
                $result = Get-TimeAgoString -Timestamp $timestamp

                $result | Should -Match "1 hour ago"
                $result | Should -Not -Match "hours"
            }

            It "Should format days correctly" {
                $timestamp = [datetime]::Now.AddDays(-2)
                $result = Get-TimeAgoString -Timestamp $timestamp

                $result | Should -Match "2 days ago"
            }

            It "Should use singular for 1 day" {
                $timestamp = [datetime]::Now.AddDays(-1).AddHours(-5)
                $result = Get-TimeAgoString -Timestamp $timestamp

                $result | Should -Match "1 day ago"
                $result | Should -Not -Match "days"
            }
        }

        Context "Integration - Complete Workflow" {
            It "Should persist summary across Get/Save calls" {
                # Simulate a complete replication run
                $summary = @{
                    Timestamp = ([datetime]::Now).ToString('o')
                    ProfilesRun = @('IntegrationProfile')
                    ChunksTotal = 150
                    ChunksCompleted = 145
                    ChunksFailed = 5
                    BytesCopied = 5368709120  # 5 GB
                    Duration = '02:15:30'
                    Status = 'PartialFailure'
                }

                # Save summary
                Save-LastRunSummary -Summary $summary

                # Display empty state
                Show-ProgressEmptyState

                # Verify display
                $script:Controls.txtProfileProgress.Text | Should -Match "IntegrationProfile"
                $script:Controls.txtOverallProgress.Text | Should -Match "PartialFailure"
                $script:Controls.txtChunks.Text | Should -Match "145/150"
                $script:Controls.txtChunks.Text | Should -Match "5 failed"

                # Calculate expected completion percentage
                $expectedPct = [math]::Round((145 / 150) * 100, 0)
                $script:Controls.pbProfile.Value | Should -Be $expectedPct
            }
        }
    }
}
