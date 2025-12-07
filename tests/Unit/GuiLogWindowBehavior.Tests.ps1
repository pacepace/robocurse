#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "GUI Log Window Behavior Tests" {

        BeforeAll {
            # Mock logging functions to prevent actual logging during tests
            Mock Write-RobocurseLog { }
            Mock Write-SiemEvent { }
            Mock Write-GuiLog { }
        }

        Context "Window Independence - No Owner Assignment" {
            BeforeAll {
                # Read source code to verify Owner is not set
                $testRoot = $PSScriptRoot
                $projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
                $sourceFile = Join-Path $projectRoot "src\Robocurse\Public\GuiLogWindow.ps1"
                $sourceContent = Get-Content -Path $sourceFile -Raw
            }

            It "Source code should NOT have active Owner assignment" {
                # The line should be removed or commented out
                # We check for the pattern that would set Owner
                $hasActiveOwnerAssignment = $sourceContent -match '^\s*\$script:LogWindow\.Owner\s*=\s*\$script:Window\s*$' -and
                                            $sourceContent -notmatch '^\s*#.*\$script:LogWindow\.Owner\s*=\s*\$script:Window'

                $hasActiveOwnerAssignment | Should -BeFalse -Because "Log window should not use Owner to avoid always-on-top behavior"
            }

            It "Source code should have explanation comment about Owner" {
                # Should have a comment explaining why Owner is not set
                $hasComment = $sourceContent -match 'Owner.*not.*set' -or
                              $sourceContent -match 'intentionally.*NOT.*set' -or
                              $sourceContent -match 'non-modal.*Owner'

                $hasComment | Should -BeTrue -Because "Code should document why Owner is not set for non-modal windows"
            }
        }

        Context "Close-LogWindow Function" {
            BeforeEach {
                # Create mock window object
                $script:LogWindow = [PSCustomObject]@{
                    IsLoaded = $true
                    IsClosed = $false
                } | Add-Member -MemberType ScriptMethod -Name Close -Value {
                    $this.IsClosed = $true
                } -PassThru

                $script:LogControls = @{
                    'txtLog' = [PSCustomObject]@{ Text = 'Test log content' }
                }
            }

            AfterEach {
                # Clean up
                $script:LogWindow = $null
                $script:LogControls = @{}
            }

            It "Should close the window and clear reference" {
                # Act
                Close-LogWindow

                # Assert
                $script:LogWindow | Should -BeNullOrEmpty
                $script:LogControls.Count | Should -Be 0
            }

            It "Should handle already-closed window gracefully" {
                # Arrange - Mock a window that throws on Close()
                $script:LogWindow = [PSCustomObject]@{
                    IsLoaded = $false
                } | Add-Member -MemberType ScriptMethod -Name Close -Value {
                    throw "Window is already closed"
                } -PassThru

                # Act - should not throw
                { Close-LogWindow } | Should -Not -Throw

                # Assert - reference should still be cleared
                $script:LogWindow | Should -BeNullOrEmpty
            }

            It "Should handle null window gracefully" {
                # Arrange
                $script:LogWindow = $null

                # Act - should not throw
                { Close-LogWindow } | Should -Not -Throw
            }
        }

        Context "Position Memory - Save-LogWindowPosition" {
            BeforeEach {
                # Create mock window with position properties
                $script:LogWindow = [PSCustomObject]@{
                    IsLoaded = $true
                    Left = 100
                    Top = 150
                    Width = 800
                    Height = 600
                    WindowState = 'Normal'
                }
                $script:LogWindowPosition = $null
            }

            AfterEach {
                $script:LogWindow = $null
                $script:LogWindowPosition = $null
            }

            It "Should save window position data" {
                # Act
                Save-LogWindowPosition

                # Assert
                $script:LogWindowPosition | Should -Not -BeNullOrEmpty
                $script:LogWindowPosition.Left | Should -Be 100
                $script:LogWindowPosition.Top | Should -Be 150
                $script:LogWindowPosition.Width | Should -Be 800
                $script:LogWindowPosition.Height | Should -Be 600
                $script:LogWindowPosition.State | Should -Be 'Normal'
            }

            It "Should save Maximized state" {
                # Arrange
                $script:LogWindow.WindowState = 'Maximized'

                # Act
                Save-LogWindowPosition

                # Assert
                $script:LogWindowPosition.State | Should -Be 'Maximized'
            }

            It "Should save Minimized state" {
                # Arrange
                $script:LogWindow.WindowState = 'Minimized'

                # Act
                Save-LogWindowPosition

                # Assert
                $script:LogWindowPosition.State | Should -Be 'Minimized'
            }

            It "Should not save if window is null" {
                # Arrange
                $script:LogWindow = $null
                $script:LogWindowPosition = $null

                # Act
                Save-LogWindowPosition

                # Assert
                $script:LogWindowPosition | Should -BeNullOrEmpty
            }

            It "Should not save if window is not loaded" {
                # Arrange
                $script:LogWindow.IsLoaded = $false

                # Act
                Save-LogWindowPosition

                # Assert
                $script:LogWindowPosition | Should -BeNullOrEmpty
            }
        }

        Context "Position Memory - Restore-LogWindowPosition" {
            BeforeEach {
                # Create mock window that can accept position values
                $script:LogWindow = [PSCustomObject]@{
                    IsLoaded = $true
                    Left = 0
                    Top = 0
                    Width = 400
                    Height = 300
                    WindowState = 'Normal'
                }

                # Create saved position
                $script:LogWindowPosition = @{
                    Left = 200
                    Top = 250
                    Width = 900
                    Height = 700
                    State = 'Normal'
                }
            }

            AfterEach {
                $script:LogWindow = $null
                $script:LogWindowPosition = $null
            }

            It "Should restore window position" {
                # Act
                Restore-LogWindowPosition

                # Assert
                $script:LogWindow.Left | Should -Be 200
                $script:LogWindow.Top | Should -Be 250
                $script:LogWindow.Width | Should -Be 900
                $script:LogWindow.Height | Should -Be 700
            }

            It "Should restore Normal state" {
                # Arrange
                $script:LogWindowPosition.State = 'Normal'

                # Act
                Restore-LogWindowPosition

                # Assert
                $script:LogWindow.WindowState | Should -Be 'Normal'
            }

            It "Should restore Maximized state" {
                # Arrange
                $script:LogWindowPosition.State = 'Maximized'

                # Act
                Restore-LogWindowPosition

                # Assert
                $script:LogWindow.WindowState | Should -Be 'Maximized'
            }

            It "Should NOT restore Minimized state to avoid invisible window" {
                # Arrange
                $script:LogWindowPosition.State = 'Minimized'
                $script:LogWindow.WindowState = 'Normal'

                # Act
                Restore-LogWindowPosition

                # Assert - state should remain Normal, not become Minimized
                $script:LogWindow.WindowState | Should -Be 'Normal'
            }

            It "Should not restore if saved position is null" {
                # Arrange
                $script:LogWindowPosition = $null
                $originalLeft = $script:LogWindow.Left

                # Act
                Restore-LogWindowPosition

                # Assert - position should not change
                $script:LogWindow.Left | Should -Be $originalLeft
            }

            It "Should not restore if window is null" {
                # Arrange
                $script:LogWindow = $null

                # Act - should not throw
                { Restore-LogWindowPosition } | Should -Not -Throw
            }
        }

        Context "Function Existence Tests" {
            It "Should have Show-LogWindow function" {
                Get-Command Show-LogWindow -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Close-LogWindow function" {
                Get-Command Close-LogWindow -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Save-LogWindowPosition function" {
                Get-Command Save-LogWindowPosition -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Restore-LogWindowPosition function" {
                Get-Command Restore-LogWindowPosition -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Initialize-LogWindow function" {
                Get-Command Initialize-LogWindow -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Update-LogWindowContent function" {
                Get-Command Update-LogWindowContent -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }
        }
    }
}
