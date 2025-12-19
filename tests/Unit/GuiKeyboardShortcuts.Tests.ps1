#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "GUI Keyboard Shortcuts Tests" {

        Context "Get-PanelForKey Function Tests" {
            It "Should map D1 to Profiles panel" {
                $result = Get-PanelForKey -Key 'D1'
                $result | Should -Be 'Profiles'
            }

            It "Should map D2 to Settings panel" {
                $result = Get-PanelForKey -Key 'D2'
                $result | Should -Be 'Settings'
            }

            It "Should map D3 to Progress panel" {
                $result = Get-PanelForKey -Key 'D3'
                $result | Should -Be 'Progress'
            }

            It "Should map D4 to Logs panel" {
                $result = Get-PanelForKey -Key 'D4'
                $result | Should -Be 'Logs'
            }

            It "Should map NumPad1 to Profiles panel" {
                $result = Get-PanelForKey -Key 'NumPad1'
                $result | Should -Be 'Profiles'
            }

            It "Should map NumPad2 to Settings panel" {
                $result = Get-PanelForKey -Key 'NumPad2'
                $result | Should -Be 'Settings'
            }

            It "Should map NumPad3 to Progress panel" {
                $result = Get-PanelForKey -Key 'NumPad3'
                $result | Should -Be 'Progress'
            }

            It "Should map NumPad4 to Logs panel" {
                $result = Get-PanelForKey -Key 'NumPad4'
                $result | Should -Be 'Logs'
            }

            It "Should return null for unmapped key" {
                $result = Get-PanelForKey -Key 'A'
                $result | Should -BeNullOrEmpty
            }

            It "Should map D5 to Snapshots panel" {
                $result = Get-PanelForKey -Key 'D5'
                $result | Should -Be 'Snapshots'
            }
        }

        Context "Invoke-KeyboardShortcut Function Tests" {
            BeforeEach {
                # Mock the functions that keyboard shortcuts call
                Mock Show-LogWindow {}
                Mock Start-GuiReplication {}
                Mock Request-Stop {}
                Mock Set-ActivePanel {}

                # Mock the Controls dictionary with button states
                $script:Controls = @{
                    btnRunSelected = [PSCustomObject]@{ IsEnabled = $true }
                    btnStop = [PSCustomObject]@{ IsEnabled = $false }
                }
            }

            It "Should handle Ctrl+L to open log window" {
                $result = Invoke-KeyboardShortcut -Key 'L' -Ctrl $true -IsTextBoxFocused $false

                $result | Should -Be $true
                Assert-MockCalled Show-LogWindow -Times 1
            }

            It "Should handle Ctrl+L even when TextBox is focused" {
                $result = Invoke-KeyboardShortcut -Key 'L' -Ctrl $true -IsTextBoxFocused $true

                $result | Should -Be $true
                Assert-MockCalled Show-LogWindow -Times 1
            }

            It "Should handle Ctrl+R when Run button is enabled" {
                $script:Controls.btnRunSelected.IsEnabled = $true

                $result = Invoke-KeyboardShortcut -Key 'R' -Ctrl $true -IsTextBoxFocused $false

                $result | Should -Be $true
                Assert-MockCalled Start-GuiReplication -Times 1 -ParameterFilter { $SelectedOnly -eq $true }
            }

            It "Should not call Start-GuiReplication when Run button is disabled" {
                $script:Controls.btnRunSelected.IsEnabled = $false

                $result = Invoke-KeyboardShortcut -Key 'R' -Ctrl $true -IsTextBoxFocused $false

                $result | Should -Be $true
                Assert-MockCalled Start-GuiReplication -Times 0
            }

            It "Should handle Escape when Stop button is enabled" {
                $script:Controls.btnStop.IsEnabled = $true

                $result = Invoke-KeyboardShortcut -Key 'Escape' -Ctrl $false -IsTextBoxFocused $false

                $result | Should -Be $true
                Assert-MockCalled Request-Stop -Times 1
            }

            It "Should not call Request-Stop when Stop button is disabled" {
                $script:Controls.btnStop.IsEnabled = $false

                $result = Invoke-KeyboardShortcut -Key 'Escape' -Ctrl $false -IsTextBoxFocused $false

                $result | Should -Be $true
                Assert-MockCalled Request-Stop -Times 0
            }

            It "Should handle D1 to switch to Profiles panel when not in TextBox" {
                $result = Invoke-KeyboardShortcut -Key 'D1' -Ctrl $false -IsTextBoxFocused $false

                $result | Should -Be $true
                Assert-MockCalled Set-ActivePanel -Times 1 -ParameterFilter { $PanelName -eq 'Profiles' }
            }

            It "Should not switch panels with D1 when TextBox is focused" {
                $result = Invoke-KeyboardShortcut -Key 'D1' -Ctrl $false -IsTextBoxFocused $true

                $result | Should -Be $false
                Assert-MockCalled Set-ActivePanel -Times 0
            }

            It "Should handle D2 to switch to Settings panel" {
                $result = Invoke-KeyboardShortcut -Key 'D2' -Ctrl $false -IsTextBoxFocused $false

                $result | Should -Be $true
                Assert-MockCalled Set-ActivePanel -Times 1 -ParameterFilter { $PanelName -eq 'Settings' }
            }

            It "Should handle D3 to switch to Progress panel" {
                $result = Invoke-KeyboardShortcut -Key 'D3' -Ctrl $false -IsTextBoxFocused $false

                $result | Should -Be $true
                Assert-MockCalled Set-ActivePanel -Times 1 -ParameterFilter { $PanelName -eq 'Progress' }
            }

            It "Should handle D4 to switch to Logs panel" {
                $result = Invoke-KeyboardShortcut -Key 'D4' -Ctrl $false -IsTextBoxFocused $false

                $result | Should -Be $true
                Assert-MockCalled Set-ActivePanel -Times 1 -ParameterFilter { $PanelName -eq 'Logs' }
            }

            It "Should handle NumPad1 to switch to Profiles panel" {
                $result = Invoke-KeyboardShortcut -Key 'NumPad1' -Ctrl $false -IsTextBoxFocused $false

                $result | Should -Be $true
                Assert-MockCalled Set-ActivePanel -Times 1 -ParameterFilter { $PanelName -eq 'Profiles' }
            }

            It "Should handle NumPad2 to switch to Settings panel" {
                $result = Invoke-KeyboardShortcut -Key 'NumPad2' -Ctrl $false -IsTextBoxFocused $false

                $result | Should -Be $true
                Assert-MockCalled Set-ActivePanel -Times 1 -ParameterFilter { $PanelName -eq 'Settings' }
            }

            It "Should handle NumPad3 to switch to Progress panel" {
                $result = Invoke-KeyboardShortcut -Key 'NumPad3' -Ctrl $false -IsTextBoxFocused $false

                $result | Should -Be $true
                Assert-MockCalled Set-ActivePanel -Times 1 -ParameterFilter { $PanelName -eq 'Progress' }
            }

            It "Should handle NumPad4 to switch to Logs panel" {
                $result = Invoke-KeyboardShortcut -Key 'NumPad4' -Ctrl $false -IsTextBoxFocused $false

                $result | Should -Be $true
                Assert-MockCalled Set-ActivePanel -Times 1 -ParameterFilter { $PanelName -eq 'Logs' }
            }

            It "Should not switch panels with Ctrl+1" {
                $result = Invoke-KeyboardShortcut -Key 'D1' -Ctrl $true -IsTextBoxFocused $false

                $result | Should -Be $false
                Assert-MockCalled Set-ActivePanel -Times 0
            }

            It "Should return false for unmapped key" {
                $result = Invoke-KeyboardShortcut -Key 'A' -Ctrl $false -IsTextBoxFocused $false

                $result | Should -Be $false
            }

            It "Should not interfere with normal TextBox input" {
                # When typing 'L' in a TextBox without Ctrl, it should not trigger log window
                $result = Invoke-KeyboardShortcut -Key 'L' -Ctrl $false -IsTextBoxFocused $true

                $result | Should -Be $false
                Assert-MockCalled Show-LogWindow -Times 0
            }
        }

        Context "Keyboard Shortcut Integration Tests" {
            It "Should have Invoke-KeyboardShortcut function available" {
                Get-Command Invoke-KeyboardShortcut -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Get-PanelForKey function available" {
                Get-Command Get-PanelForKey -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should handle all shortcuts independently" {
                Mock Show-LogWindow {}
                Mock Start-GuiReplication {}
                Mock Request-Stop {}
                Mock Set-ActivePanel {}

                $script:Controls = @{
                    btnRunSelected = [PSCustomObject]@{ IsEnabled = $true }
                    btnStop = [PSCustomObject]@{ IsEnabled = $true }
                }

                # Test each shortcut
                $shortcuts = @(
                    @{ Key = 'L'; Ctrl = $true; Expected = 'Show-LogWindow' }
                    @{ Key = 'R'; Ctrl = $true; Expected = 'Start-GuiReplication' }
                    @{ Key = 'Escape'; Ctrl = $false; Expected = 'Request-Stop' }
                    @{ Key = 'D1'; Ctrl = $false; Expected = 'Set-ActivePanel' }
                    @{ Key = 'D2'; Ctrl = $false; Expected = 'Set-ActivePanel' }
                    @{ Key = 'D3'; Ctrl = $false; Expected = 'Set-ActivePanel' }
                    @{ Key = 'D4'; Ctrl = $false; Expected = 'Set-ActivePanel' }
                )

                foreach ($shortcut in $shortcuts) {
                    $result = Invoke-KeyboardShortcut -Key $shortcut.Key -Ctrl $shortcut.Ctrl -IsTextBoxFocused $false
                    $result | Should -Be $true -Because "Shortcut $($shortcut.Key) should be handled"
                }
            }
        }

        Context "XAML Tooltip Tests" {
            BeforeAll {
                $script:XamlContent = Get-XamlResource -ResourceName 'MainWindow.xaml'
            }

            It "Should have keyboard shortcut in btnNavProfiles tooltip" {
                $script:XamlContent | Should -Match 'ToolTip="Profiles \(1\)"'
            }

            It "Should have keyboard shortcut in btnNavSettings tooltip" {
                $script:XamlContent | Should -Match 'ToolTip="Settings \(2\)"'
            }

            It "Should have keyboard shortcut in btnNavProgress tooltip" {
                $script:XamlContent | Should -Match 'ToolTip="Progress \(3\)"'
            }

            It "Should have keyboard shortcut in btnNavLogs tooltip" {
                $script:XamlContent | Should -Match 'ToolTip="Logs \(4\)"'
            }

            It "Should have keyboard shortcut in btnRunSelected tooltip" {
                $script:XamlContent | Should -Match 'ToolTip="Run selected profile \(Ctrl\+R\)"'
            }

            It "Should have keyboard shortcut in btnStop tooltip" {
                $script:XamlContent | Should -Match 'ToolTip="Stop replication \(Escape\)"'
            }

            It "Should have keyboard shortcut in btnLogPopOut tooltip" {
                $script:XamlContent | Should -Match 'ToolTip="Open log in separate window \(Ctrl\+L\)"'
            }
        }
    }
}
