#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "GUI Panel Switching Tests" -Skip:(-not (Test-IsWindowsPlatform)) {

        BeforeAll {
            # Load WPF assemblies for Visibility enum
            Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
            Add-Type -AssemblyName PresentationCore -ErrorAction Stop
            Add-Type -AssemblyName WindowsBase -ErrorAction Stop
        }

        BeforeEach {
            # Mock Write-RobocurseLog to avoid log output during tests
            Mock Write-RobocurseLog { }

            # Mock Import-SettingsToForm to avoid config file dependency
            Mock Import-SettingsToForm { }

            # Mock Show-ProgressEmptyState to avoid control dependency
            Mock Show-ProgressEmptyState { }

            # Create mock controls with Visibility and IsChecked properties
            $script:Controls = @{
                'panelProfiles' = [PSCustomObject]@{
                    Visibility = [System.Windows.Visibility]::Visible
                }
                'panelSettings' = [PSCustomObject]@{
                    Visibility = [System.Windows.Visibility]::Collapsed
                }
                'panelProgress' = [PSCustomObject]@{
                    Visibility = [System.Windows.Visibility]::Collapsed
                }
                'panelLogs' = [PSCustomObject]@{
                    Visibility = [System.Windows.Visibility]::Collapsed
                }
                'btnNavProfiles' = [PSCustomObject]@{
                    IsChecked = $true
                }
                'btnNavSettings' = [PSCustomObject]@{
                    IsChecked = $false
                }
                'btnNavProgress' = [PSCustomObject]@{
                    IsChecked = $false
                }
                'btnNavLogs' = [PSCustomObject]@{
                    IsChecked = $false
                }
            }

            # Initialize ActivePanel state
            $script:ActivePanel = $null
        }

        Context "Set-ActivePanel Function" {
            It "Should exist and be callable" {
                Get-Command Set-ActivePanel -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should show Profiles panel and hide all others" {
                Set-ActivePanel -PanelName 'Profiles'

                $script:Controls['panelProfiles'].Visibility | Should -Be ([System.Windows.Visibility]::Visible)
                $script:Controls['panelSettings'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
                $script:Controls['panelProgress'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
                $script:Controls['panelLogs'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
            }

            It "Should show Settings panel and hide all others" {
                Set-ActivePanel -PanelName 'Settings'

                $script:Controls['panelProfiles'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
                $script:Controls['panelSettings'].Visibility | Should -Be ([System.Windows.Visibility]::Visible)
                $script:Controls['panelProgress'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
                $script:Controls['panelLogs'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
            }

            It "Should show Progress panel and hide all others" {
                Set-ActivePanel -PanelName 'Progress'

                $script:Controls['panelProfiles'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
                $script:Controls['panelSettings'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
                $script:Controls['panelProgress'].Visibility | Should -Be ([System.Windows.Visibility]::Visible)
                $script:Controls['panelLogs'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
            }

            It "Should show Logs panel and hide all others" {
                Set-ActivePanel -PanelName 'Logs'

                $script:Controls['panelProfiles'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
                $script:Controls['panelSettings'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
                $script:Controls['panelProgress'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
                $script:Controls['panelLogs'].Visibility | Should -Be ([System.Windows.Visibility]::Visible)
            }
        }

        Context "Button State Updates" {
            It "Should check Profiles button and uncheck all others" {
                Set-ActivePanel -PanelName 'Profiles'

                $script:Controls['btnNavProfiles'].IsChecked | Should -Be $true
                $script:Controls['btnNavSettings'].IsChecked | Should -Be $false
                $script:Controls['btnNavProgress'].IsChecked | Should -Be $false
                $script:Controls['btnNavLogs'].IsChecked | Should -Be $false
            }

            It "Should check Settings button and uncheck all others" {
                Set-ActivePanel -PanelName 'Settings'

                $script:Controls['btnNavProfiles'].IsChecked | Should -Be $false
                $script:Controls['btnNavSettings'].IsChecked | Should -Be $true
                $script:Controls['btnNavProgress'].IsChecked | Should -Be $false
                $script:Controls['btnNavLogs'].IsChecked | Should -Be $false
            }

            It "Should check Progress button and uncheck all others" {
                Set-ActivePanel -PanelName 'Progress'

                $script:Controls['btnNavProfiles'].IsChecked | Should -Be $false
                $script:Controls['btnNavSettings'].IsChecked | Should -Be $false
                $script:Controls['btnNavProgress'].IsChecked | Should -Be $true
                $script:Controls['btnNavLogs'].IsChecked | Should -Be $false
            }

            It "Should check Logs button and uncheck all others" {
                Set-ActivePanel -PanelName 'Logs'

                $script:Controls['btnNavProfiles'].IsChecked | Should -Be $false
                $script:Controls['btnNavSettings'].IsChecked | Should -Be $false
                $script:Controls['btnNavProgress'].IsChecked | Should -Be $false
                $script:Controls['btnNavLogs'].IsChecked | Should -Be $true
            }
        }

        Context "Missing Controls Handling" {
            It "Should handle missing panel controls gracefully" {
                $script:Controls['panelSettings'] = $null

                { Set-ActivePanel -PanelName 'Settings' } | Should -Not -Throw
            }

            It "Should handle missing button controls gracefully" {
                $script:Controls['btnNavSettings'] = $null

                { Set-ActivePanel -PanelName 'Settings' } | Should -Not -Throw
            }

            It "Should still show correct panel when button is missing" {
                $script:Controls['btnNavProgress'] = $null

                Set-ActivePanel -PanelName 'Progress'

                $script:Controls['panelProgress'].Visibility | Should -Be ([System.Windows.Visibility]::Visible)
            }

            It "Should still update buttons when panel is missing" {
                $script:Controls['panelLogs'] = $null

                Set-ActivePanel -PanelName 'Logs'

                $script:Controls['btnNavLogs'].IsChecked | Should -Be $true
            }
        }

        Context "Invalid Panel Name Validation" {
            It "Should throw for invalid panel name" {
                { Set-ActivePanel -PanelName 'InvalidPanel' } | Should -Throw
            }

            It "Should throw for empty panel name" {
                { Set-ActivePanel -PanelName '' } | Should -Throw
            }

            It "Should throw for null panel name" {
                { Set-ActivePanel -PanelName $null } | Should -Throw
            }
        }

        Context "State Consistency" {
            It "Should have exactly one panel visible after switch" {
                Set-ActivePanel -PanelName 'Progress'

                $visiblePanels = @(@(
                    $script:Controls['panelProfiles'],
                    $script:Controls['panelSettings'],
                    $script:Controls['panelProgress'],
                    $script:Controls['panelLogs']
                ) | Where-Object { $_.Visibility -eq [System.Windows.Visibility]::Visible })

                $visiblePanels.Count | Should -Be 1
            }

            It "Should have exactly one button checked after switch" {
                Set-ActivePanel -PanelName 'Settings'

                $checkedButtons = @(@(
                    $script:Controls['btnNavProfiles'],
                    $script:Controls['btnNavSettings'],
                    $script:Controls['btnNavProgress'],
                    $script:Controls['btnNavLogs']
                ) | Where-Object { $_.IsChecked -eq $true })

                $checkedButtons.Count | Should -Be 1
            }

            It "Should maintain consistency across multiple switches" {
                Set-ActivePanel -PanelName 'Progress'
                Set-ActivePanel -PanelName 'Logs'
                Set-ActivePanel -PanelName 'Profiles'

                # Only Profiles should be visible
                $script:Controls['panelProfiles'].Visibility | Should -Be ([System.Windows.Visibility]::Visible)
                $script:Controls['panelSettings'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
                $script:Controls['panelProgress'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
                $script:Controls['panelLogs'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)

                # Only Profiles button should be checked
                $script:Controls['btnNavProfiles'].IsChecked | Should -Be $true
                $script:Controls['btnNavSettings'].IsChecked | Should -Be $false
                $script:Controls['btnNavProgress'].IsChecked | Should -Be $false
                $script:Controls['btnNavLogs'].IsChecked | Should -Be $false
            }
        }

        Context "ActivePanel State Tracking" {
            It "Should store active panel in script scope" {
                Set-ActivePanel -PanelName 'Progress'

                $script:ActivePanel | Should -Be 'Progress'
            }

            It "Should update active panel when switching" {
                Set-ActivePanel -PanelName 'Profiles'
                $script:ActivePanel | Should -Be 'Profiles'

                Set-ActivePanel -PanelName 'Logs'
                $script:ActivePanel | Should -Be 'Logs'
            }
        }

        Context "Debug Logging" {
            It "Should log panel switch with Debug level" {
                Set-ActivePanel -PanelName 'Progress'

                Assert-MockCalled Write-RobocurseLog -Times 1 -ParameterFilter {
                    $Level -eq 'Debug' -and
                    $Component -eq 'GUI' -and
                    $Message -match 'Progress'
                }
            }

            It "Should log each panel switch separately" {
                Set-ActivePanel -PanelName 'Profiles'
                Set-ActivePanel -PanelName 'Settings'
                Set-ActivePanel -PanelName 'Progress'

                Assert-MockCalled Write-RobocurseLog -Times 3 -ParameterFilter {
                    $Level -eq 'Debug' -and $Component -eq 'GUI'
                }
            }
        }

        Context "Panel Switching Without All Controls" {
            It "Should work when only some panels exist" {
                # Remove some panel controls
                $script:Controls.Remove('panelSettings')
                $script:Controls.Remove('panelLogs')

                { Set-ActivePanel -PanelName 'Progress' } | Should -Not -Throw
                $script:Controls['panelProgress'].Visibility | Should -Be ([System.Windows.Visibility]::Visible)
            }

            It "Should work when only some buttons exist" {
                # Remove some button controls
                $script:Controls.Remove('btnNavSettings')
                $script:Controls.Remove('btnNavLogs')

                { Set-ActivePanel -PanelName 'Progress' } | Should -Not -Throw
                $script:Controls['btnNavProgress'].IsChecked | Should -Be $true
            }
        }

        Context "Visibility Enum Values" {
            It "Should use correct Visibility enum for visible panels" {
                Set-ActivePanel -PanelName 'Profiles'

                $script:Controls['panelProfiles'].Visibility | Should -BeOfType [System.Windows.Visibility]
                $script:Controls['panelProfiles'].Visibility | Should -Be ([System.Windows.Visibility]::Visible)
            }

            It "Should use correct Visibility enum for hidden panels" {
                Set-ActivePanel -PanelName 'Profiles'

                $script:Controls['panelSettings'].Visibility | Should -BeOfType [System.Windows.Visibility]
                $script:Controls['panelSettings'].Visibility | Should -Be ([System.Windows.Visibility]::Collapsed)
            }

            It "Should not use string values for Visibility" {
                Set-ActivePanel -PanelName 'Progress'

                # Ensure we're not using strings like "Visible" or "Collapsed"
                $script:Controls['panelProgress'].Visibility | Should -Not -BeOfType [string]
            }
        }
    }
}
