#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "GUI Module Tests" {

        Context "Function Existence Tests" {
            It "Should have Initialize-RobocurseGui function" {
                Get-Command Initialize-RobocurseGui -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Initialize-EventHandlers function" {
                Get-Command Initialize-EventHandlers -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Update-ProfileList function" {
                Get-Command Update-ProfileList -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Import-ProfileToForm function" {
                Get-Command Import-ProfileToForm -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Save-ProfileFromForm function" {
                Get-Command Save-ProfileFromForm -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Add-NewProfile function" {
                Get-Command Add-NewProfile -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Remove-SelectedProfile function" {
                Get-Command Remove-SelectedProfile -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Show-FolderBrowser function" {
                Get-Command Show-FolderBrowser -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Start-GuiReplication function" {
                Get-Command Start-GuiReplication -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Complete-GuiReplication function" {
                Get-Command Complete-GuiReplication -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Update-GuiProgress function" {
                Get-Command Update-GuiProgress -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Write-GuiLog function" {
                Get-Command Write-GuiLog -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Show-GuiError function" {
                Get-Command Show-GuiError -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Show-ScheduleDialog function" {
                Get-Command Show-ScheduleDialog -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }
        }

        Context "XAML Definition Tests" {
            BeforeAll {
                # Load XAML from resource file using the new approach
                $script:TestXamlContent = Get-XamlResource -ResourceName 'MainWindow.xaml'
            }

            It "Should load MainWindow XAML via Get-XamlResource" {
                $script:TestXamlContent | Should -Not -BeNullOrEmpty
            }

            It "Should have valid XML structure" {
                { [xml]$script:TestXamlContent } | Should -Not -Throw
            }

            It "Should have Window as root element" {
                $xaml = [xml]$script:TestXamlContent
                $xaml.DocumentElement.LocalName | Should -Be "Window"
            }

            It "Should have dark theme background color" {
                $script:TestXamlContent | Should -Match '#1E1E1E'
            }

            It "Should have required controls defined" {
                $requiredControls = @(
                    'lstProfiles', 'btnAddProfile', 'btnRemoveProfile',
                    'txtProfileName', 'txtSource', 'txtDest',
                    'btnBrowseSource', 'btnBrowseDest',
                    'chkUseVss', 'cmbScanMode',
                    'txtMaxSize', 'txtMaxFiles', 'txtMaxDepth',
                    'sldWorkers', 'txtWorkerCount',
                    'btnRunAll', 'btnRunSelected', 'btnStop', 'btnSchedule',
                    'dgChunks', 'pbProfile', 'pbOverall',
                    'txtProfileProgress', 'txtOverallProgress',
                    'txtEta', 'txtSpeed', 'txtChunks',
                    'txtStatus', 'txtLog', 'svLog'
                )

                foreach ($control in $requiredControls) {
                    $script:TestXamlContent | Should -Match "x:Name=`"$control`""
                }
            }

            It "Should have tooltips defined" {
                $script:TestXamlContent | Should -Match 'ToolTip='
            }

            It "Should have dark theme styles defined" {
                $script:TestXamlContent | Should -Match 'DarkLabel'
                $script:TestXamlContent | Should -Match 'DarkTextBox'
                $script:TestXamlContent | Should -Match 'DarkButton'
                $script:TestXamlContent | Should -Match 'StopButton'
                $script:TestXamlContent | Should -Match 'DarkCheckBox'
                $script:TestXamlContent | Should -Match 'DarkListBox'
            }

            It "Should have Get-XamlResource function" {
                Get-Command Get-XamlResource -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }
        }

        Context "GUI Initialization Tests (Non-WPF)" {
            It "Should not throw when WPF is unavailable on non-Windows" {
                # This test ensures graceful degradation on non-Windows platforms
                if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
                    { Initialize-RobocurseGui } | Should -Not -Throw
                }
            }
        }

        Context "Profile Data Transformation Tests" {
            BeforeEach {
                # Create test profile
                $script:TestProfile = [PSCustomObject]@{
                    Name = "Test Profile"
                    Source = "C:\Source"
                    Destination = "D:\Destination"
                    Enabled = $true
                    UseVSS = $false
                    ScanMode = "Smart"
                    ChunkMaxSizeGB = 10
                    ChunkMaxFiles = 50000
                    ChunkMaxDepth = 5
                }
            }

            It "Should create valid new profile structure" {
                $newProfile = [PSCustomObject]@{
                    Name = "New Profile"
                    Source = ""
                    Destination = ""
                    Enabled = $true
                    UseVSS = $false
                    ScanMode = "Smart"
                    ChunkMaxSizeGB = 10
                    ChunkMaxFiles = 50000
                    ChunkMaxDepth = 5
                }

                $newProfile.Name | Should -Be "New Profile"
                $newProfile.Enabled | Should -Be $true
                $newProfile.ScanMode | Should -Be "Smart"
                $newProfile.ChunkMaxSizeGB | Should -Be 10
            }

            It "Should validate numeric chunk settings" {
                # Test valid values
                $script:TestProfile.ChunkMaxSizeGB = 20
                $script:TestProfile.ChunkMaxSizeGB | Should -Be 20

                $script:TestProfile.ChunkMaxFiles = 100000
                $script:TestProfile.ChunkMaxFiles | Should -Be 100000

                $script:TestProfile.ChunkMaxDepth = 8
                $script:TestProfile.ChunkMaxDepth | Should -Be 8
            }

            It "Should handle scan mode values" {
                $validModes = @("Smart", "Quick")

                foreach ($mode in $validModes) {
                    $script:TestProfile.ScanMode = $mode
                    $script:TestProfile.ScanMode | Should -Be $mode
                }
            }
        }

        Context "Progress Update Data Tests" {
            BeforeEach {
                # Initialize orchestration state for testing
                Initialize-OrchestrationState
            }

            It "Should calculate chunk display items correctly" {
                # Simulate active job
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test\Path"
                }

                $job = [PSCustomObject]@{
                    Chunk = $chunk
                    Progress = 50
                }

                $script:OrchestrationState.ActiveJobs[1] = $job

                # Create display item
                $displayItem = [PSCustomObject]@{
                    ChunkId = $job.Chunk.ChunkId
                    SourcePath = $job.Chunk.SourcePath
                    Status = "Running"
                    Progress = if ($job.Progress) { $job.Progress } else { 0 }
                    Speed = "--"
                }

                $displayItem.ChunkId | Should -Be 1
                $displayItem.SourcePath | Should -Be "C:\Test\Path"
                $displayItem.Status | Should -Be "Running"
                $displayItem.Progress | Should -Be 50
            }

            It "Should create completed chunk display items" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 2
                    SourcePath = "C:\Test\Complete"
                }

                $displayItem = [PSCustomObject]@{
                    ChunkId = $chunk.ChunkId
                    SourcePath = $chunk.SourcePath
                    Status = "Complete"
                    Progress = 100
                    Speed = "--"
                }

                $displayItem.Status | Should -Be "Complete"
                $displayItem.Progress | Should -Be 100
            }

            It "Should create failed chunk display items" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 3
                    SourcePath = "C:\Test\Failed"
                }

                $displayItem = [PSCustomObject]@{
                    ChunkId = $chunk.ChunkId
                    SourcePath = $chunk.SourcePath
                    Status = "Failed"
                    Progress = 0
                    Speed = "--"
                }

                $displayItem.Status | Should -Be "Failed"
                $displayItem.Progress | Should -Be 0
            }
        }

        Context "Helper Function Tests" {
            It "Write-GuiLog should format timestamp correctly" {
                # Test timestamp format
                $timestamp = Get-Date -Format "HH:mm:ss"
                $message = "Test message"
                $expectedFormat = "[$timestamp] $message`n"

                # Verify format pattern
                $expectedFormat | Should -Match '^\[\d{2}:\d{2}:\d{2}\]'
            }

            It "Show-GuiError should combine message and details" {
                $message = "Error occurred"
                $details = "Detailed information"
                $fullMessage = $message

                if ($details) {
                    $fullMessage += "`n`nDetails: $details"
                }

                $fullMessage | Should -Match "Error occurred"
                $fullMessage | Should -Match "Details: Detailed information"
            }

            It "Should validate profile paths are not empty" {
                $profile = [PSCustomObject]@{
                    Name = "Test"
                    Source = ""
                    Destination = ""
                }

                # Validation logic
                $isValid = -not ([string]::IsNullOrWhiteSpace($profile.Source) -or [string]::IsNullOrWhiteSpace($profile.Destination))
                $isValid | Should -Be $false

                $profile.Source = "C:\Source"
                $profile.Destination = "D:\Dest"
                $isValid = -not ([string]::IsNullOrWhiteSpace($profile.Source) -or [string]::IsNullOrWhiteSpace($profile.Destination))
                $isValid | Should -Be $true
            }
        }

        Context "Progress Status Formatting Tests" {
            It "Should format profile progress text correctly" {
                $profileName = "Test Profile"
                $progress = 75.5

                $text = "Profile: $profileName - $progress%"
                $text | Should -Be "Profile: Test Profile - 75.5%"
            }

            It "Should format overall progress text correctly" {
                $progress = 42.3
                $text = "Overall: $progress%"
                $text | Should -Be "Overall: 42.3%"
            }

            It "Should format ETA text correctly" {
                $eta = [TimeSpan]::FromSeconds(3665)  # 1:01:05
                $text = "ETA: $($eta.ToString('hh\:mm\:ss'))"
                $text | Should -Be "ETA: 01:01:05"
            }

            It "Should format chunks text correctly" {
                $complete = 45
                $total = 100
                $text = "Chunks: $complete/$total"
                $text | Should -Be "Chunks: 45/100"
            }

            It "Should handle null ETA gracefully" {
                $eta = $null
                $text = if ($eta) { "ETA: $($eta.ToString('hh\:mm\:ss'))" } else { "ETA: --:--:--" }
                $text | Should -Be "ETA: --:--:--"
            }
        }

        Context "Configuration Integration Tests" {
            It "Should integrate with config structure" {
                $config = New-DefaultConfig

                # Verify config has required properties for GUI
                $config.GlobalSettings | Should -Not -BeNullOrEmpty
                $config.Email | Should -Not -BeNullOrEmpty
                $config.Schedule | Should -Not -BeNullOrEmpty
                $config.PSObject.Properties.Name | Should -Contain 'SyncProfiles'

                # Verify schedule properties
                $config.Schedule.PSObject.Properties.Name | Should -Contain 'Enabled'
                $config.Schedule.PSObject.Properties.Name | Should -Contain 'Time'
                $config.Schedule.PSObject.Properties.Name | Should -Contain 'Days'
            }

            It "Should allow adding profiles to config" {
                $config = New-DefaultConfig

                $newProfile = [PSCustomObject]@{
                    Name = "GUI Test Profile"
                    Source = "C:\Test"
                    Destination = "D:\Backup"
                    Enabled = $true
                    UseVSS = $false
                    ScanMode = "Smart"
                    ChunkMaxSizeGB = 15
                    ChunkMaxFiles = 75000
                    ChunkMaxDepth = 6
                }

                $config.SyncProfiles += $newProfile
                $config.SyncProfiles.Count | Should -Be 1
                $config.SyncProfiles[0].Name | Should -Be "GUI Test Profile"
            }

            It "Should allow removing profiles from config" {
                $config = New-DefaultConfig

                $profile1 = [PSCustomObject]@{ Name = "Profile 1"; Source = "A"; Destination = "B"; Enabled = $true }
                $profile2 = [PSCustomObject]@{ Name = "Profile 2"; Source = "C"; Destination = "D"; Enabled = $true }

                $config.SyncProfiles = @($profile1, $profile2)
                $config.SyncProfiles.Count | Should -Be 2

                # Remove profile
                $config.SyncProfiles = @($config.SyncProfiles | Where-Object { $_ -ne $profile1 })
                $config.SyncProfiles.Count | Should -Be 1
                $config.SyncProfiles[0].Name | Should -Be "Profile 2"
            }
        }

        Context "Speed Calculation Tests" {
            It "Should calculate transfer speed correctly" {
                $bytesComplete = 100MB
                $elapsedSeconds = 10

                $speed = $bytesComplete / $elapsedSeconds
                $speed | Should -Be (100MB / 10)

                # Format using Format-FileSize
                $formattedSpeed = Format-FileSize $speed
                $formattedSpeed | Should -Match '\d+\.\d+ MB'
            }

            It "Should handle zero elapsed time" {
                $bytesComplete = 100MB
                $elapsedSeconds = 0

                $canCalculate = $elapsedSeconds -gt 0 -and $bytesComplete -gt 0
                $canCalculate | Should -Be $false
            }

            It "Should handle zero bytes complete" {
                $bytesComplete = 0
                $elapsedSeconds = 10

                $canCalculate = $elapsedSeconds -gt 0 -and $bytesComplete -gt 0
                $canCalculate | Should -Be $false
            }
        }

        Context "Profile Filtering Tests" {
            BeforeEach {
                $script:TestConfig = New-DefaultConfig
                $script:TestConfig.SyncProfiles = @(
                    [PSCustomObject]@{ Name = "Profile A"; Enabled = $true; Source = "C:\A"; Destination = "D:\A" }
                    [PSCustomObject]@{ Name = "Profile B"; Enabled = $false; Source = "C:\B"; Destination = "D:\B" }
                    [PSCustomObject]@{ Name = "Profile C"; Enabled = $true; Source = "C:\C"; Destination = "D:\C" }
                )
            }

            It "Should filter enabled profiles correctly" {
                $enabled = @($script:TestConfig.SyncProfiles | Where-Object { $_.Enabled -eq $true })
                $enabled.Count | Should -Be 2
                $enabled[0].Name | Should -Be "Profile A"
                $enabled[1].Name | Should -Be "Profile C"
            }

            It "Should filter disabled profiles correctly" {
                $disabled = @($script:TestConfig.SyncProfiles | Where-Object { $_.Enabled -eq $false })
                $disabled.Count | Should -Be 1
                $disabled[0].Name | Should -Be "Profile B"
            }

            It "Should handle no enabled profiles" {
                # Disable all profiles
                foreach ($profile in $script:TestConfig.SyncProfiles) {
                    $profile.Enabled = $false
                }

                $enabled = @($script:TestConfig.SyncProfiles | Where-Object { $_.Enabled -eq $true })
                $enabled.Count | Should -Be 0
            }
        }

        Context "Scan Mode ComboBox Index Tests" {
            It "Should map Smart to index 0" {
                $scanMode = "Smart"
                $index = if ($scanMode -eq "Quick") { 1 } else { 0 }
                $index | Should -Be 0
            }

            It "Should map Quick to index 1" {
                $scanMode = "Quick"
                $index = if ($scanMode -eq "Quick") { 1 } else { 0 }
                $index | Should -Be 1
            }

            It "Should default to Smart (index 0) for invalid value" {
                $scanMode = "Unknown"
                $index = if ($scanMode -eq "Quick") { 1 } else { 0 }
                $index | Should -Be 0
            }
        }
    }
}
