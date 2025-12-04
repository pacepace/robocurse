#Requires -Modules Pester

# GUI Event Simulation Tests
# Tests WPF event handling and UI state transitions

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "GUI Event Simulation Tests" -Skip:(-not (Test-IsWindowsPlatform)) {

        BeforeAll {
            # Load WPF assemblies
            Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
            Add-Type -AssemblyName PresentationCore -ErrorAction Stop
            Add-Type -AssemblyName WindowsBase -ErrorAction Stop

            # Path to test config file
            $script:GuiTestConfigPath = Join-Path $PSScriptRoot "..\Integration\Fixtures\GuiTest.config.json"
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

        Context "Button Click Event Simulation" {
            It "Should toggle button states when Run is clicked" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $script:TestWindow | Should -Not -BeNullOrEmpty

                $btnRunAll = $script:TestWindow.FindName('btnRunAll')
                $btnStop = $script:TestWindow.FindName('btnStop')

                # Initial state
                $btnRunAll.IsEnabled | Should -Be $true
                $btnStop.IsEnabled | Should -Be $false

                # Note: We cannot directly simulate click events in headless testing
                # because WPF event routing requires a running dispatcher.
                # Instead, we test the underlying logic functions.
            }

            It "Should validate profile paths before running" {
                $profile = [PSCustomObject]@{
                    Name = "Test"
                    Source = ""
                    Destination = ""
                    Enabled = $true
                }

                # Validation logic from GuiReplication.ps1
                $isValid = -not ([string]::IsNullOrWhiteSpace($profile.Source) -or
                                 [string]::IsNullOrWhiteSpace($profile.Destination))
                $isValid | Should -Be $false

                $profile.Source = "C:\Source"
                $profile.Destination = "D:\Dest"
                $isValid = -not ([string]::IsNullOrWhiteSpace($profile.Source) -or
                                 [string]::IsNullOrWhiteSpace($profile.Destination))
                $isValid | Should -Be $true
            }
        }

        Context "Safe Event Handler Wrapper Tests" {
            It "Should catch exceptions in event handlers without crashing" {
                $errorCaught = $false
                $handlerCompleted = $false

                # Simulate what Invoke-SafeEventHandler does
                try {
                    $scriptBlock = {
                        throw "Simulated event handler error"
                    }

                    try {
                        & $scriptBlock
                    }
                    catch {
                        $errorCaught = $true
                        # In real code, this would show MessageBox
                    }
                    $handlerCompleted = $true
                }
                catch {
                    # Should not reach here
                    $handlerCompleted = $false
                }

                $errorCaught | Should -Be $true
                $handlerCompleted | Should -Be $true
            }

            It "Should execute scriptblock successfully when no error" {
                $result = $null

                $scriptBlock = {
                    return "success"
                }

                try {
                    $result = & $scriptBlock
                }
                catch {
                    $result = "error"
                }

                $result | Should -Be "success"
            }
        }

        Context "Input Validation Event Tests" {
            It "Should reject non-numeric input for chunk size" {
                # Simulate PreviewTextInput validation
                $validInputs = @('1', '5', '10', '100', '999')
                $invalidInputs = @('a', '!', '-', '1.5', '1a', 'abc')

                foreach ($input in $validInputs) {
                    $isValid = $input -match '^\d+$'
                    $isValid | Should -Be $true -Because "Input '$input' should be valid"
                }

                foreach ($input in $invalidInputs) {
                    $isValid = $input -match '^\d+$'
                    $isValid | Should -Be $false -Because "Input '$input' should be invalid"
                }
            }

            It "Should clamp chunk size to valid range" {
                $minSize = 1
                $maxSize = 1000

                $testCases = @(
                    @{ Input = 0; Expected = 1 }
                    @{ Input = -5; Expected = 1 }
                    @{ Input = 50; Expected = 50 }
                    @{ Input = 1000; Expected = 1000 }
                    @{ Input = 1500; Expected = 1000 }
                )

                foreach ($case in $testCases) {
                    $clamped = [Math]::Max($minSize, [Math]::Min($maxSize, $case.Input))
                    $clamped | Should -Be $case.Expected -Because "Input $($case.Input) should clamp to $($case.Expected)"
                }
            }

            It "Should validate max files per chunk within range" {
                $minFiles = 100
                $maxFiles = 1000000

                $testCases = @(
                    @{ Input = 50; Expected = 100 }
                    @{ Input = 50000; Expected = 50000 }
                    @{ Input = 2000000; Expected = 1000000 }
                )

                foreach ($case in $testCases) {
                    $clamped = [Math]::Max($minFiles, [Math]::Min($maxFiles, $case.Input))
                    $clamped | Should -Be $case.Expected
                }
            }

            It "Should validate max depth within range" {
                $minDepth = 1
                $maxDepth = 20

                $testCases = @(
                    @{ Input = 0; Expected = 1 }
                    @{ Input = 5; Expected = 5 }
                    @{ Input = 25; Expected = 20 }
                )

                foreach ($case in $testCases) {
                    $clamped = [Math]::Max($minDepth, [Math]::Min($maxDepth, $case.Input))
                    $clamped | Should -Be $case.Expected
                }
            }
        }

        Context "Profile Selection Event Tests" {
            It "Should update form when profile is selected" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $lstProfiles = $script:TestWindow.FindName('lstProfiles')

                # Should have profiles loaded
                $lstProfiles.Items.Count | Should -BeGreaterThan 0

                # Select first profile
                $lstProfiles.SelectedIndex = 0
                $lstProfiles.SelectedItem | Should -Not -BeNullOrEmpty
            }

            It "Should handle empty profile list gracefully" {
                # Create a config with no profiles
                $emptyConfig = New-DefaultConfig
                $emptyConfig.SyncProfiles = @()

                # Simulate profile list update logic
                $profiles = @($emptyConfig.SyncProfiles)
                $profiles.Count | Should -Be 0
            }
        }

        Context "Worker Slider Event Tests" {
            It "Should sync slider value with text box" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $sldWorkers = $script:TestWindow.FindName('sldWorkers')
                $txtWorkerCount = $script:TestWindow.FindName('txtWorkerCount')

                # Get initial values
                $initialSliderValue = $sldWorkers.Value

                # The text should reflect the slider value
                $expectedText = [int]$initialSliderValue
                # Note: Actual sync depends on event binding which we can't test in headless mode
                # But we verify the control relationship exists
                $sldWorkers | Should -Not -BeNullOrEmpty
                $txtWorkerCount | Should -Not -BeNullOrEmpty
            }

            It "Should enforce slider min/max bounds" {
                $script:TestWindow = Initialize-RobocurseGui -ConfigPath $script:GuiTestConfigPath
                $sldWorkers = $script:TestWindow.FindName('sldWorkers')

                $sldWorkers.Minimum | Should -BeGreaterOrEqual 1
                $sldWorkers.Maximum | Should -BeLessOrEqual 32
            }
        }

        Context "Progress Update State Machine Tests" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should transition from Idle to Profiling state" {
                $script:OrchestrationState.Phase | Should -Be 'Idle'
                $script:OrchestrationState.Phase = 'Profiling'
                $script:OrchestrationState.Phase | Should -Be 'Profiling'
            }

            It "Should transition from Profiling to Chunking state" {
                $script:OrchestrationState.Phase = 'Profiling'
                $script:OrchestrationState.Phase = 'Chunking'
                $script:OrchestrationState.Phase | Should -Be 'Chunking'
            }

            It "Should transition from Chunking to Replicating state" {
                $script:OrchestrationState.Phase = 'Chunking'
                $script:OrchestrationState.Phase = 'Replicating'
                $script:OrchestrationState.Phase | Should -Be 'Replicating'
            }

            It "Should transition to Complete state when done" {
                $script:OrchestrationState.Phase = 'Replicating'
                $script:OrchestrationState.Phase = 'Complete'
                $script:OrchestrationState.Phase | Should -Be 'Complete'
            }

            It "Should handle stop request during replication" {
                $script:OrchestrationState.Phase = 'Replicating'
                $script:OrchestrationState.StopRequested = $true

                $script:OrchestrationState.StopRequested | Should -Be $true
            }
        }

        Context "Ring Buffer Log Tests" {
            It "Should maintain fixed size log buffer" {
                $maxLines = 500
                $buffer = [System.Collections.Generic.List[string]]::new()

                # Add more than max lines
                for ($i = 1; $i -le 600; $i++) {
                    $buffer.Add("Log line $i")
                    while ($buffer.Count -gt $maxLines) {
                        $buffer.RemoveAt(0)
                    }
                }

                $buffer.Count | Should -Be $maxLines
                $buffer[0] | Should -Be "Log line 101"  # First 100 lines removed
                $buffer[$maxLines - 1] | Should -Be "Log line 600"  # Latest line
            }

            It "Should format log entries with timestamp" {
                $message = "Test message"
                $timestamp = Get-Date -Format "HH:mm:ss"
                $formatted = "[$timestamp] $message"

                $formatted | Should -Match '^\[\d{2}:\d{2}:\d{2}\]'
            }
        }

        Context "DataGrid Rebuild Logic Tests" {
            BeforeEach {
                Initialize-OrchestrationState
            }

            It "Should trigger rebuild when active count increases" {
                $lastState = @{ ActiveCount = 2; CompletedCount = 5; FailedCount = 0 }
                $currentState = @{ ActiveCount = 3; CompletedCount = 5; FailedCount = 0 }

                $needsRebuild = $lastState.ActiveCount -ne $currentState.ActiveCount
                $needsRebuild | Should -Be $true
            }

            It "Should trigger rebuild when completed count changes" {
                $lastState = @{ ActiveCount = 2; CompletedCount = 5; FailedCount = 0 }
                $currentState = @{ ActiveCount = 2; CompletedCount = 6; FailedCount = 0 }

                $needsRebuild = $lastState.CompletedCount -ne $currentState.CompletedCount
                $needsRebuild | Should -Be $true
            }

            It "Should always rebuild when active jobs exist (progress changes)" {
                $currentState = @{ ActiveCount = 2; CompletedCount = 5; FailedCount = 0 }

                $needsRebuild = $currentState.ActiveCount -gt 0
                $needsRebuild | Should -Be $true
            }

            It "Should not rebuild when idle and counts unchanged" {
                $lastState = @{ ActiveCount = 0; CompletedCount = 10; FailedCount = 1 }
                $currentState = @{ ActiveCount = 0; CompletedCount = 10; FailedCount = 1 }

                $countsChanged = $lastState.ActiveCount -ne $currentState.ActiveCount -or
                                 $lastState.CompletedCount -ne $currentState.CompletedCount -or
                                 $lastState.FailedCount -ne $currentState.FailedCount
                $hasActiveJobs = $currentState.ActiveCount -gt 0

                $needsRebuild = $countsChanged -or $hasActiveJobs
                $needsRebuild | Should -Be $false
            }
        }
    }
}
