# Tests for GUI state persistence (window size, position, active panel, last run)
# Uses InModuleScope to access internal functions

BeforeAll {
    # Import module
    $modulePath = Join-Path $PSScriptRoot "..\..\src\Robocurse\Robocurse.psd1"
    Import-Module $modulePath -Force
}

Describe "GUI State Persistence" -Tag 'Unit', 'GUI' {

    BeforeAll {
        # Platform check
        $isWindows = $IsWindows -or ($PSVersionTable.PSVersion.Major -le 5)
        if (-not $isWindows) {
            Write-Warning "GUI state tests are Windows-only (WPF dependency)"
        }
    }

    Context "Get-GuiState - Default Values" {

        It "Returns defaults when no settings file exists" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                # Use TestDrive for temp settings
                $tempSettings = Join-Path $TestDrive "nonexistent.json"
                Mock Get-GuiSettingsPath { return $tempSettings }

                $state = Get-GuiState

                $state | Should -Not -BeNullOrEmpty
                $state.WindowWidth | Should -Be 650
                $state.WindowHeight | Should -Be 550
                $state.WindowLeft | Should -Be 100
                $state.WindowTop | Should -Be 100
                $state.WindowState | Should -Be 'Normal'
                $state.WorkerCount | Should -Be 4
                $state.ActivePanel | Should -Be 'Profiles'
                $state.LastRun | Should -BeNullOrEmpty
            }
        }

        It "Returns defaults when settings file is corrupted" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $tempSettings = Join-Path $TestDrive "corrupted.json"
                "{ invalid json }" | Set-Content -Path $tempSettings
                Mock Get-GuiSettingsPath { return $tempSettings }

                $state = Get-GuiState

                $state | Should -Not -BeNullOrEmpty
                $state.WindowWidth | Should -Be 650
                $state.WindowHeight | Should -Be 550
            }
        }
    }

    Context "Get-GuiState - Loading Saved Values" {

        It "Loads saved values from file" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $tempSettings = Join-Path $TestDrive "saved.json"
                $savedState = @{
                    WindowLeft = 200
                    WindowTop = 150
                    WindowWidth = 800
                    WindowHeight = 600
                    WindowState = 'Maximized'
                    WorkerCount = 8
                    SelectedProfile = 'MyProfile'
                    ActivePanel = 'Settings'
                    LastRun = @{
                        Profile = 'TestProfile'
                        Status = 'Success'
                        Duration = 120
                    }
                    SavedAt = '2024-01-15T10:30:00'
                }
                $savedState | ConvertTo-Json -Depth 5 | Set-Content -Path $tempSettings
                Mock Get-GuiSettingsPath { return $tempSettings }

                $state = Get-GuiState

                $state.WindowLeft | Should -Be 200
                $state.WindowTop | Should -Be 150
                $state.WindowWidth | Should -Be 800
                $state.WindowHeight | Should -Be 600
                $state.WindowState | Should -Be 'Maximized'
                $state.WorkerCount | Should -Be 8
                $state.SelectedProfile | Should -Be 'MyProfile'
                $state.ActivePanel | Should -Be 'Settings'
                $state.LastRun | Should -Not -BeNullOrEmpty
                $state.LastRun.Profile | Should -Be 'TestProfile'
            }
        }

        It "Merges defaults for missing properties" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $tempSettings = Join-Path $TestDrive "partial.json"
                $partialState = @{
                    WindowWidth = 900
                    WindowHeight = 700
                    WorkerCount = 6
                    # Missing: ActivePanel, LastRun, etc.
                }
                $partialState | ConvertTo-Json | Set-Content -Path $tempSettings
                Mock Get-GuiSettingsPath { return $tempSettings }

                $state = Get-GuiState

                # Saved values
                $state.WindowWidth | Should -Be 900
                $state.WindowHeight | Should -Be 700
                $state.WorkerCount | Should -Be 6
                # Defaults for missing
                $state.ActivePanel | Should -Be 'Profiles'
                $state.LastRun | Should -BeNullOrEmpty
            }
        }
    }

    Context "Get-GuiState - Migration Logic" {

        It "Migrates old 1100x800 window size to 650x550" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $tempSettings = Join-Path $TestDrive "old-size.json"
                $oldState = @{
                    WindowLeft = 100
                    WindowTop = 100
                    WindowWidth = 1100
                    WindowHeight = 800
                    WindowState = 'Normal'
                    WorkerCount = 4
                }
                $oldState | ConvertTo-Json | Set-Content -Path $tempSettings
                Mock Get-GuiSettingsPath { return $tempSettings }

                $state = Get-GuiState

                $state.WindowWidth | Should -Be 650
                $state.WindowHeight | Should -Be 550
            }
        }

        It "Does not migrate non-1100x800 sizes" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $tempSettings = Join-Path $TestDrive "custom-size.json"
                $customState = @{
                    WindowWidth = 1000
                    WindowHeight = 750
                    WindowState = 'Normal'
                }
                $customState | ConvertTo-Json | Set-Content -Path $tempSettings
                Mock Get-GuiSettingsPath { return $tempSettings }

                $state = Get-GuiState

                $state.WindowWidth | Should -Be 1000
                $state.WindowHeight | Should -Be 750
            }
        }
    }

    Context "Save-GuiState - Saving All Properties" {

        It "Saves state object with all properties including nested LastRun" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $tempSettings = Join-Path $TestDrive "save-test.json"
                Mock Get-GuiSettingsPath { return $tempSettings }

                $stateObj = [PSCustomObject]@{
                    WindowLeft = 250
                    WindowTop = 175
                    WindowWidth = 750
                    WindowHeight = 650
                    WindowState = 'Normal'
                    WorkerCount = 6
                    SelectedProfile = 'SavedProfile'
                    ActivePanel = 'Progress'
                    LastRun = @{
                        Profile = 'TestProfile'
                        Status = 'Success'
                        StartTime = '2024-01-15T10:00:00'
                        EndTime = '2024-01-15T10:05:00'
                        Duration = 300
                        FilesProcessed = 1500
                    }
                }

                Save-GuiState -StateObject $stateObj

                # Verify file was written
                Test-Path $tempSettings | Should -Be $true

                # Load and verify
                $loaded = Get-Content -Path $tempSettings -Raw | ConvertFrom-Json
                $loaded.WindowWidth | Should -Be 750
                $loaded.WindowHeight | Should -Be 650
                $loaded.ActivePanel | Should -Be 'Progress'
                $loaded.LastRun | Should -Not -BeNullOrEmpty
                $loaded.LastRun.Profile | Should -Be 'TestProfile'
                $loaded.LastRun.FilesProcessed | Should -Be 1500
            }
        }

        It "Uses Depth 5 for proper nested serialization" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $tempSettings = Join-Path $TestDrive "depth-test.json"
                Mock Get-GuiSettingsPath { return $tempSettings }

                $deepState = [PSCustomObject]@{
                    WindowWidth = 650
                    WindowHeight = 550
                    LastRun = @{
                        Profiles = @(
                            @{ Name = 'Profile1'; Files = @{ Total = 100; Copied = 90 } }
                            @{ Name = 'Profile2'; Files = @{ Total = 200; Copied = 180 } }
                        )
                    }
                }

                Save-GuiState -StateObject $deepState

                # Verify deep nesting is preserved
                $loaded = Get-Content -Path $tempSettings -Raw | ConvertFrom-Json
                $loaded.LastRun.Profiles.Count | Should -Be 2
                $loaded.LastRun.Profiles[0].Files.Total | Should -Be 100
            }
        }
    }

    Context "Active Panel Validation" {

        It "Accepts valid panel names" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $tempSettings = Join-Path $TestDrive "valid-panel.json"
                Mock Get-GuiSettingsPath { return $tempSettings }

                foreach ($panel in @('Profiles', 'Settings', 'Progress', 'Logs')) {
                    $state = @{ ActivePanel = $panel; WindowWidth = 650; WindowHeight = 550 }
                    $state | ConvertTo-Json | Set-Content -Path $tempSettings

                    $loaded = Get-GuiState
                    $loaded.ActivePanel | Should -Be $panel
                }
            }
        }

        It "Defaults to Profiles for invalid panel names" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $tempSettings = Join-Path $TestDrive "invalid-panel.json"
                Mock Get-GuiSettingsPath { return $tempSettings }

                $state = @{ ActivePanel = 'InvalidPanel'; WindowWidth = 650; WindowHeight = 550 }
                $state | ConvertTo-Json | Set-Content -Path $tempSettings

                $loaded = Get-GuiState
                $loaded.ActivePanel | Should -Be 'Profiles'
            }
        }

        It "Defaults to Profiles when ActivePanel is null" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $tempSettings = Join-Path $TestDrive "null-panel.json"
                Mock Get-GuiSettingsPath { return $tempSettings }

                $state = @{ WindowWidth = 650; WindowHeight = 550 }
                $state | ConvertTo-Json | Set-Content -Path $tempSettings

                $loaded = Get-GuiState
                $loaded.ActivePanel | Should -Be 'Profiles'
            }
        }
    }

    Context "Window Bounds Validation" {

        It "Enforces minimum width of 500" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                # Create mock window object
                $window = [PSCustomObject]@{
                    Left = 100
                    Top = 100
                    Width = 0
                    Height = 0
                    WindowState = [PSCustomObject]@{ ToString = { 'Normal' } }
                }

                # Mock Controls for Restore-GuiState
                $script:Controls = @{}

                # Create state with too-small dimensions
                $tempSettings = Join-Path $TestDrive "small-width.json"
                $state = @{ WindowLeft = 100; WindowTop = 100; WindowWidth = 300; WindowHeight = 600 }
                $state | ConvertTo-Json | Set-Content -Path $tempSettings
                Mock Get-GuiSettingsPath { return $tempSettings }

                Restore-GuiState -Window $window

                $window.Width | Should -BeGreaterOrEqual 500
            }
        }

        It "Enforces minimum height of 400" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                # Create mock window object
                $window = [PSCustomObject]@{
                    Left = 100
                    Top = 100
                    Width = 0
                    Height = 0
                    WindowState = [PSCustomObject]@{ ToString = { 'Normal' } }
                }

                # Mock Controls
                $script:Controls = @{}

                # Create state with too-small dimensions
                $tempSettings = Join-Path $TestDrive "small-height.json"
                $state = @{ WindowLeft = 100; WindowTop = 100; WindowWidth = 800; WindowHeight = 200 }
                $state | ConvertTo-Json | Set-Content -Path $tempSettings
                Mock Get-GuiSettingsPath { return $tempSettings }

                Restore-GuiState -Window $window

                $window.Height | Should -BeGreaterOrEqual 400
            }
        }
    }

    Context "Round-Trip Persistence" {

        It "Preserves all data through save/load cycle" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $tempSettings = Join-Path $TestDrive "round-trip.json"
                Mock Get-GuiSettingsPath { return $tempSettings }

                # Create comprehensive state
                $originalState = [PSCustomObject]@{
                    WindowLeft = 300
                    WindowTop = 200
                    WindowWidth = 900
                    WindowHeight = 700
                    WindowState = 'Maximized'
                    WorkerCount = 10
                    SelectedProfile = 'RoundTripProfile'
                    ActivePanel = 'Logs'
                    LastRun = @{
                        Profile = 'TestProfile'
                        Status = 'Success'
                        StartTime = '2024-01-15T09:00:00'
                        EndTime = '2024-01-15T09:30:00'
                        Duration = 1800
                        FilesProcessed = 5000
                        BytesCopied = 1073741824
                        Errors = @()
                    }
                }

                # Save
                Save-GuiState -StateObject $originalState

                # Load
                $loadedState = Get-GuiState

                # Verify all properties preserved
                $loadedState.WindowLeft | Should -Be 300
                $loadedState.WindowTop | Should -Be 200
                $loadedState.WindowWidth | Should -Be 900
                $loadedState.WindowHeight | Should -Be 700
                $loadedState.WindowState | Should -Be 'Maximized'
                $loadedState.WorkerCount | Should -Be 10
                $loadedState.SelectedProfile | Should -Be 'RoundTripProfile'
                $loadedState.ActivePanel | Should -Be 'Logs'
                $loadedState.LastRun | Should -Not -BeNullOrEmpty
                $loadedState.LastRun.Profile | Should -Be 'TestProfile'
                $loadedState.LastRun.Status | Should -Be 'Success'
                $loadedState.LastRun.Duration | Should -Be 1800
                $loadedState.LastRun.FilesProcessed | Should -Be 5000
                $loadedState.LastRun.BytesCopied | Should -Be 1073741824
            }
        }
    }

    Context "Restore-GuiState - Active Panel Restoration" {

        It "Stores restored active panel in script scope" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                # Create mock window
                $window = [PSCustomObject]@{
                    Left = 100
                    Top = 100
                    Width = 0
                    Height = 0
                    WindowState = [PSCustomObject]@{ ToString = { 'Normal' } }
                }

                # Mock Controls
                $script:Controls = @{}

                # Create state with specific panel
                $tempSettings = Join-Path $TestDrive "panel-restore.json"
                $state = @{
                    WindowLeft = 100
                    WindowTop = 100
                    WindowWidth = 650
                    WindowHeight = 550
                    ActivePanel = 'Progress'
                }
                $state | ConvertTo-Json | Set-Content -Path $tempSettings
                Mock Get-GuiSettingsPath { return $tempSettings }

                Restore-GuiState -Window $window

                $script:RestoredActivePanel | Should -Be 'Progress'
            }
        }

        It "Stores 'Profiles' default when panel is invalid" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $window = [PSCustomObject]@{
                    Left = 100
                    Top = 100
                    Width = 0
                    Height = 0
                    WindowState = [PSCustomObject]@{ ToString = { 'Normal' } }
                }

                $script:Controls = @{}

                $tempSettings = Join-Path $TestDrive "invalid-restore.json"
                $state = @{
                    WindowWidth = 650
                    WindowHeight = 550
                    ActivePanel = 'BadPanel'
                }
                $state | ConvertTo-Json | Set-Content -Path $tempSettings
                Mock Get-GuiSettingsPath { return $tempSettings }

                Restore-GuiState -Window $window

                $script:RestoredActivePanel | Should -Be 'Profiles'
            }
        }
    }

    Context "Save-LastRunSummary and Get-LastRunSummary" {

        It "Saves and retrieves last run summary" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $tempSettings = Join-Path $TestDrive "last-run.json"
                Mock Get-GuiSettingsPath { return $tempSettings }

                $summary = @{
                    Profile = 'TestProfile'
                    Status = 'Success'
                    Duration = 450
                    FilesProcessed = 2000
                }

                Save-LastRunSummary -Summary $summary

                $retrieved = Get-LastRunSummary
                $retrieved | Should -Not -BeNullOrEmpty
                $retrieved.Profile | Should -Be 'TestProfile'
                $retrieved.Status | Should -Be 'Success'
                $retrieved.Duration | Should -Be 450
                $retrieved.FilesProcessed | Should -Be 2000
            }
        }

        It "Returns null when no last run exists" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $tempSettings = Join-Path $TestDrive "no-last-run.json"
                Mock Get-GuiSettingsPath { return $tempSettings }

                $retrieved = Get-LastRunSummary
                $retrieved | Should -BeNullOrEmpty
            }
        }

        It "Preserves other state when saving last run" -Skip:(-not $isWindows) {
            InModuleScope 'Robocurse' {
                $tempSettings = Join-Path $TestDrive "preserve-state.json"
                Mock Get-GuiSettingsPath { return $tempSettings }

                # Create initial state
                $initialState = [PSCustomObject]@{
                    WindowWidth = 800
                    WindowHeight = 600
                    ActivePanel = 'Settings'
                    WorkerCount = 8
                }
                Save-GuiState -StateObject $initialState

                # Save last run
                $summary = @{ Profile = 'TestProfile'; Status = 'Success' }
                Save-LastRunSummary -Summary $summary

                # Verify state preserved
                $loaded = Get-GuiState
                $loaded.WindowWidth | Should -Be 800
                $loaded.WindowHeight | Should -Be 600
                $loaded.ActivePanel | Should -Be 'Settings'
                $loaded.WorkerCount | Should -Be 8
                $loaded.LastRun | Should -Not -BeNullOrEmpty
                $loaded.LastRun.Profile | Should -Be 'TestProfile'
            }
        }
    }
}
