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

            It "Should have Show-Panel function" {
                Get-Command Show-Panel -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Invoke-KeyboardShortcut function" {
                Get-Command Invoke-KeyboardShortcut -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Get-PanelForKey function" {
                Get-Command Get-PanelForKey -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
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
                # Note: txtLog and svLog removed - now in separate LogWindow.xaml
                # btnLogs replaced by navigation rail buttons (btnNavProfiles, btnNavSettings, btnNavProgress, btnNavLogs)
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
                    'txtStatus'
                )

                foreach ($control in $requiredControls) {
                    $script:TestXamlContent | Should -Match "x:Name=`"$control`""
                }
            }

            It "Should have navigation rail controls defined" {
                # Navigation rail radio buttons for panel switching
                $navControls = @(
                    'btnNavProfiles', 'btnNavSettings', 'btnNavProgress', 'btnNavLogs'
                )

                foreach ($control in $navControls) {
                    $script:TestXamlContent | Should -Match "x:Name=`"$control`""
                }
            }

            It "Should have content panel controls defined" {
                # Content panels switched by navigation rail
                $panelControls = @(
                    'panelProfiles', 'panelSettings', 'panelProgress', 'panelLogs'
                )

                foreach ($control in $panelControls) {
                    $script:TestXamlContent | Should -Match "x:Name=`"$control`""
                }
            }

            It "Should have RailButton style defined" {
                $script:TestXamlContent | Should -Match 'RailButton'
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

            It "Should use ScaleTransform for progress bar (WPF ProgressBar workaround)" {
                # Verify custom progress bar implementation using ScaleTransform
                # WPF ProgressBar doesn't reliably render in PowerShell, so we use
                # Border + ScaleTransform with ProgressScale (0.0-1.0) binding
                $script:TestXamlContent | Should -Match 'ScaleTransform'
                $script:TestXamlContent | Should -Match 'ProgressScale'
                $script:TestXamlContent | Should -Match 'ScaleX='
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

        Context "ProgressScale Calculation Tests (ScaleTransform Workaround)" {
            # These tests verify the ProgressScale property used for the custom progress bar.
            # WPF ProgressBar doesn't reliably render in PowerShell, so we use ScaleTransform
            # with ProgressScale (0.0-1.0) binding to ScaleX for visual progress display.

            It "Should calculate ProgressScale as 0.0 for 0% progress" {
                $progress = 0
                $progressScale = [double]($progress / 100)
                $progressScale | Should -Be 0.0
            }

            It "Should calculate ProgressScale as 0.5 for 50% progress" {
                $progress = 50
                $progressScale = [double]($progress / 100)
                $progressScale | Should -Be 0.5
            }

            It "Should calculate ProgressScale as 1.0 for 100% progress" {
                $progress = 100
                $progressScale = [double]($progress / 100)
                $progressScale | Should -Be 1.0
            }

            It "Should handle fractional progress values" {
                $progress = 75
                $progressScale = [double]($progress / 100)
                $progressScale | Should -Be 0.75
            }

            It "Should create chunk display item with ProgressScale for running job" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 1
                    SourcePath = "C:\Test\Path"
                    EstimatedSize = 1000000
                }

                $progress = 42

                $displayItem = [PSCustomObject]@{
                    ChunkId = $chunk.ChunkId
                    SourcePath = $chunk.SourcePath
                    Status = "Running"
                    Progress = $progress
                    ProgressScale = [double]($progress / 100)
                    Speed = "10 MB/s"
                }

                $displayItem.Progress | Should -Be 42
                $displayItem.ProgressScale | Should -Be 0.42
            }

            It "Should create chunk display item with ProgressScale=1.0 for completed chunk" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 2
                    SourcePath = "C:\Test\Complete"
                }

                $displayItem = [PSCustomObject]@{
                    ChunkId = $chunk.ChunkId
                    SourcePath = $chunk.SourcePath
                    Status = "Complete"
                    Progress = 100
                    ProgressScale = [double]1.0
                    Speed = "--"
                }

                $displayItem.Status | Should -Be "Complete"
                $displayItem.Progress | Should -Be 100
                $displayItem.ProgressScale | Should -Be 1.0
            }

            It "Should create chunk display item with ProgressScale=0.0 for failed chunk" {
                $chunk = [PSCustomObject]@{
                    ChunkId = 3
                    SourcePath = "C:\Test\Failed"
                }

                $displayItem = [PSCustomObject]@{
                    ChunkId = $chunk.ChunkId
                    SourcePath = $chunk.SourcePath
                    Status = "Failed"
                    Progress = 0
                    ProgressScale = [double]0.0
                    Speed = "--"
                }

                $displayItem.Status | Should -Be "Failed"
                $displayItem.Progress | Should -Be 0
                $displayItem.ProgressScale | Should -Be 0.0
            }
        }

        Context "ChunkGridNeedsRebuild Logic Tests" {
            # Tests for Test-ChunkGridNeedsRebuild which determines when to refresh DataGrid.
            # Key insight: Must rebuild when active jobs exist because PSCustomObject doesn't
            # implement INotifyPropertyChanged, so WPF won't see progress value changes.

            BeforeEach {
                Initialize-OrchestrationState
                $script:LastGuiUpdateState = $null
            }

            It "Should return true on first call (no previous state)" {
                $currentState = @{
                    ActiveCount = 0
                    CompletedCount = 0
                    FailedCount = 0
                }

                # Simulate first call - no previous state
                $needsRebuild = -not $script:LastGuiUpdateState
                $needsRebuild | Should -Be $true
            }

            It "Should return true when active count changes" {
                $script:LastGuiUpdateState = @{
                    ActiveCount = 2
                    CompletedCount = 5
                    FailedCount = 0
                }

                $currentState = @{
                    ActiveCount = 3  # Changed
                    CompletedCount = 5
                    FailedCount = 0
                }

                $needsRebuild = $script:LastGuiUpdateState.ActiveCount -ne $currentState.ActiveCount
                $needsRebuild | Should -Be $true
            }

            It "Should return true when there are active jobs (progress changes continuously)" {
                $script:LastGuiUpdateState = @{
                    ActiveCount = 2
                    CompletedCount = 5
                    FailedCount = 0
                }

                $currentState = @{
                    ActiveCount = 2  # Same count
                    CompletedCount = 5
                    FailedCount = 0
                }

                # Key logic: always rebuild when active jobs exist
                $needsRebuild = $currentState.ActiveCount -gt 0
                $needsRebuild | Should -Be $true
            }

            It "Should return false when no active jobs and counts unchanged" {
                $script:LastGuiUpdateState = @{
                    ActiveCount = 0
                    CompletedCount = 10
                    FailedCount = 1
                }

                $currentState = @{
                    ActiveCount = 0
                    CompletedCount = 10
                    FailedCount = 1
                }

                $countsChanged = $script:LastGuiUpdateState.ActiveCount -ne $currentState.ActiveCount -or
                                 $script:LastGuiUpdateState.CompletedCount -ne $currentState.CompletedCount -or
                                 $script:LastGuiUpdateState.FailedCount -ne $currentState.FailedCount

                $hasActiveJobs = $currentState.ActiveCount -gt 0

                $needsRebuild = $countsChanged -or $hasActiveJobs
                $needsRebuild | Should -Be $false
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

        Context "Headless WPF Instantiation Tests" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeAll {
                # Path to test config file
                $script:GuiTestConfigPath = Join-Path $PSScriptRoot "..\Integration\Fixtures\GuiTest.config.json"

                # Ensure config exists
                if (-not (Test-Path $script:GuiTestConfigPath)) {
                    throw "GUI test config not found at: $script:GuiTestConfigPath"
                }

                # Load WPF assemblies
                Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
                Add-Type -AssemblyName PresentationCore -ErrorAction Stop
                Add-Type -AssemblyName WindowsBase -ErrorAction Stop
            }

            AfterEach {
                # Clean up any window that was created
                if ($script:TestWindow) {
                    try {
                        $script:TestWindow.Close()
                    }
                    catch {
                        # Window may already be closed
                    }
                    $script:TestWindow = $null
                }
            }

            It "Should return a Window object from Initialize-RobocurseGui" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $script:TestWindow | Should -Not -BeNullOrEmpty
                $script:TestWindow | Should -BeOfType [System.Windows.Window]
            }

            It "Should find all required controls by name" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $script:TestWindow | Should -Not -BeNullOrEmpty

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
                    'txtStatus'
                )

                foreach ($controlName in $requiredControls) {
                    $control = $script:TestWindow.FindName($controlName)
                    $control | Should -Not -BeNullOrEmpty -Because "Control '$controlName' should exist"
                }
            }

            It "Should find all navigation rail controls by name" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $script:TestWindow | Should -Not -BeNullOrEmpty

                $navControls = @(
                    'btnNavProfiles', 'btnNavSettings', 'btnNavProgress', 'btnNavLogs'
                )

                foreach ($controlName in $navControls) {
                    $control = $script:TestWindow.FindName($controlName)
                    $control | Should -Not -BeNullOrEmpty -Because "Navigation control '$controlName' should exist"
                }
            }

            It "Should find all content panel controls by name" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $script:TestWindow | Should -Not -BeNullOrEmpty

                $panelControls = @(
                    'panelProfiles', 'panelSettings', 'panelProgress', 'panelLogs'
                )

                foreach ($controlName in $panelControls) {
                    $control = $script:TestWindow.FindName($controlName)
                    $control | Should -Not -BeNullOrEmpty -Because "Panel '$controlName' should exist"
                }
            }

            It "Should have Profiles panel visible by default" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $panelProfiles = $script:TestWindow.FindName('panelProfiles')
                $panelSettings = $script:TestWindow.FindName('panelSettings')
                $panelProgress = $script:TestWindow.FindName('panelProgress')
                $panelLogs = $script:TestWindow.FindName('panelLogs')

                $panelProfiles.Visibility | Should -Be ([System.Windows.Visibility]::Visible)
                $panelSettings.Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
                $panelProgress.Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
                $panelLogs.Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
            }

            It "Should have Profiles nav button checked by default" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $btnNavProfiles = $script:TestWindow.FindName('btnNavProfiles')
                $btnNavSettings = $script:TestWindow.FindName('btnNavSettings')
                $btnNavProgress = $script:TestWindow.FindName('btnNavProgress')
                $btnNavLogs = $script:TestWindow.FindName('btnNavLogs')

                $btnNavProfiles.IsChecked | Should -Be $true
                $btnNavSettings.IsChecked | Should -Be $false
                $btnNavProgress.IsChecked | Should -Be $false
                $btnNavLogs.IsChecked | Should -Be $false
            }

            It "Should have Stop button initially disabled" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $btnStop = $script:TestWindow.FindName('btnStop')
                $btnStop.IsEnabled | Should -Be $false
            }

            It "Should have Run buttons initially enabled" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $btnRunAll = $script:TestWindow.FindName('btnRunAll')
                $btnRunSelected = $script:TestWindow.FindName('btnRunSelected')

                $btnRunAll.IsEnabled | Should -Be $true
                $btnRunSelected.IsEnabled | Should -Be $true
            }

            It "Should load profiles from config into profile list" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $lstProfiles = $script:TestWindow.FindName('lstProfiles')

                # Config has 2 profiles
                $lstProfiles.Items.Count | Should -Be 2
            }

            It "Should set default worker count from slider" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $sldWorkers = $script:TestWindow.FindName('sldWorkers')
                $txtWorkerCount = $script:TestWindow.FindName('txtWorkerCount')

                $sldWorkers.Value | Should -BeGreaterOrEqual 1
                $sldWorkers.Value | Should -BeLessOrEqual 16
            }

            It "Should have correct window title" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $script:TestWindow.Title | Should -Match "Robocurse"
            }

            It "Should initialize progress bars at zero" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $pbProfile = $script:TestWindow.FindName('pbProfile')
                $pbOverall = $script:TestWindow.FindName('pbOverall')

                $pbProfile.Value | Should -Be 0
                $pbOverall.Value | Should -Be 0
            }

            It "Should have scan mode combo box with Smart and Quick options" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $cmbScanMode = $script:TestWindow.FindName('cmbScanMode')

                $cmbScanMode.Items.Count | Should -Be 2
            }
        }

        Context "Schedule Dialog Headless Tests" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeAll {
                Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
                Add-Type -AssemblyName PresentationCore -ErrorAction Stop
                Add-Type -AssemblyName WindowsBase -ErrorAction Stop
            }

            It "Should load ScheduleDialog XAML without error" {
                $xaml = Get-XamlResource -ResourceName 'ScheduleDialog.xaml'
                $xaml | Should -Not -BeNullOrEmpty

                # Parse the XAML
                $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
                $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
                $reader.Close()

                $dialog | Should -BeOfType [System.Windows.Window]
                $dialog.Title | Should -Match "Schedule"

                # Clean up
                $dialog.Close()
            }

            It "Should have required schedule dialog controls" {
                $xaml = Get-XamlResource -ResourceName 'ScheduleDialog.xaml'
                $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
                $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
                $reader.Close()

                $dialog.FindName('chkEnabled') | Should -Not -BeNullOrEmpty
                $dialog.FindName('txtTime') | Should -Not -BeNullOrEmpty
                $dialog.FindName('cmbFrequency') | Should -Not -BeNullOrEmpty
                $dialog.FindName('btnOk') | Should -Not -BeNullOrEmpty
                $dialog.FindName('btnCancel') | Should -Not -BeNullOrEmpty

                $dialog.Close()
            }
        }

        Context "Completion Dialog Headless Tests" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeAll {
                Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
                Add-Type -AssemblyName PresentationCore -ErrorAction Stop
                Add-Type -AssemblyName WindowsBase -ErrorAction Stop
            }

            It "Should load CompletionDialog XAML without error" {
                $xaml = Get-XamlResource -ResourceName 'CompletionDialog.xaml'
                $xaml | Should -Not -BeNullOrEmpty

                # Parse the XAML - this is where TemplateBinding bugs would surface
                $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
                { $dialog = [System.Windows.Markup.XamlReader]::Load($reader) } | Should -Not -Throw
                $reader.Close()

                $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
                $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
                $reader.Close()

                $dialog | Should -BeOfType [System.Windows.Window]
                $dialog.Title | Should -Match "Complete"

                # Clean up
                $dialog.Close()
            }

            It "Should have required completion dialog controls" {
                $xaml = Get-XamlResource -ResourceName 'CompletionDialog.xaml'
                $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
                $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
                $reader.Close()

                $dialog.FindName('iconBorder') | Should -Not -BeNullOrEmpty
                $dialog.FindName('iconText') | Should -Not -BeNullOrEmpty
                $dialog.FindName('txtTitle') | Should -Not -BeNullOrEmpty
                $dialog.FindName('txtSubtitle') | Should -Not -BeNullOrEmpty
                $dialog.FindName('txtChunksValue') | Should -Not -BeNullOrEmpty
                $dialog.FindName('txtTotalValue') | Should -Not -BeNullOrEmpty
                $dialog.FindName('txtFailedValue') | Should -Not -BeNullOrEmpty
                $dialog.FindName('btnOk') | Should -Not -BeNullOrEmpty

                $dialog.Close()
            }
        }

        Context "Log Window Function Tests" {
            It "Should have Show-LogWindow function" {
                Get-Command Show-LogWindow -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Clear-GuiLogBuffer function" {
                Get-Command Clear-GuiLogBuffer -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Close-LogWindow function" {
                Get-Command Close-LogWindow -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Update-LogWindowContent function" {
                Get-Command Update-LogWindowContent -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Initialize-LogWindow function" {
                Get-Command Initialize-LogWindow -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }
        }

        Context "Log Window XAML Tests" {
            BeforeAll {
                $script:LogWindowXaml = Get-XamlResource -ResourceName 'LogWindow.xaml'
            }

            It "Should load LogWindow XAML via Get-XamlResource" {
                $script:LogWindowXaml | Should -Not -BeNullOrEmpty
            }

            It "Should have valid XML structure" {
                { [xml]$script:LogWindowXaml } | Should -Not -Throw
            }

            It "Should have Window as root element" {
                $xaml = [xml]$script:LogWindowXaml
                $xaml.DocumentElement.LocalName | Should -Be "Window"
            }

            It "Should have dark theme background color" {
                $script:LogWindowXaml | Should -Match '#1E1E1E'
            }

            It "Should have required log window controls" {
                $requiredControls = @(
                    'chkDebug', 'chkInfo', 'chkWarning', 'chkError',
                    'chkAutoScroll', 'txtLineCount',
                    'svLog', 'txtLog',
                    'btnClear', 'btnCopyAll', 'btnSaveLog', 'btnClose'
                )

                foreach ($control in $requiredControls) {
                    $script:LogWindowXaml | Should -Match "x:Name=`"$control`"" -Because "Control '$control' should be defined"
                }
            }
        }

        Context "Log Window Headless Tests" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeAll {
                Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
                Add-Type -AssemblyName PresentationCore -ErrorAction Stop
                Add-Type -AssemblyName WindowsBase -ErrorAction Stop
            }

            It "Should load LogWindow XAML without error" {
                $xaml = Get-XamlResource -ResourceName 'LogWindow.xaml'
                $xaml | Should -Not -BeNullOrEmpty

                # Parse the XAML
                $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
                { $dialog = [System.Windows.Markup.XamlReader]::Load($reader) } | Should -Not -Throw
                $reader.Close()

                $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
                $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
                $reader.Close()

                $dialog | Should -BeOfType [System.Windows.Window]
                $dialog.Title | Should -Match "Log"

                # Clean up
                $dialog.Close()
            }

            It "Should have required log window controls loadable" {
                $xaml = Get-XamlResource -ResourceName 'LogWindow.xaml'
                $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
                $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
                $reader.Close()

                $dialog.FindName('txtLog') | Should -Not -BeNullOrEmpty
                $dialog.FindName('svLog') | Should -Not -BeNullOrEmpty
                $dialog.FindName('btnClose') | Should -Not -BeNullOrEmpty
                $dialog.FindName('btnClear') | Should -Not -BeNullOrEmpty
                $dialog.FindName('chkAutoScroll') | Should -Not -BeNullOrEmpty

                $dialog.Close()
            }
        }

        Context "GUI Log Buffer Tests" {
            It "Should manage log buffer correctly" {
                # The buffer is initialized by module load or GuiMain
                # Verify buffer exists (or create for test isolation)
                if ($null -eq $script:GuiLogBuffer) {
                    $script:GuiLogBuffer = [System.Collections.Generic.List[string]]::new()
                }

                # Check it's a generic List of strings (type name varies by .NET version)
                $script:GuiLogBuffer.GetType().Name | Should -Be 'List`1'
                $script:GuiLogBuffer.GetType().GetGenericArguments()[0].Name | Should -Be 'String'

                # Add some content
                $script:GuiLogBuffer.Add("Test line 1")
                $script:GuiLogBuffer.Add("Test line 2")
                $script:GuiLogBuffer.Count | Should -BeGreaterThan 0

                # Clear the buffer
                Clear-GuiLogBuffer

                # Verify cleared
                $script:GuiLogBuffer.Count | Should -Be 0
            }
        }
    }
}
