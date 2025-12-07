#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Load WPF assemblies for type references
Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "GUI Error Indicator Tests" {

        BeforeAll {
            # Mock logging functions to prevent error output in tests
            Mock Write-RobocurseLog { }
            Mock Write-SiemEvent { }
            Mock Write-GuiLog { }
        }

        BeforeEach {
            # Reset error state
            $script:GuiErrorCount = 0

            # Initialize ErrorHistoryBuffer if not already
            if (-not $script:ErrorHistoryBuffer) {
                $script:ErrorHistoryBuffer = [System.Collections.Generic.List[PSCustomObject]]::new()
            } else {
                $script:ErrorHistoryBuffer.Clear()
            }

            # Recreate mock controls fresh each test
            $script:Controls = @{
                txtStatus = [PSCustomObject]@{
                    Text = "Ready"
                    Foreground = $null
                    Cursor = $null
                    TextDecorations = $null
                }
            }

            # Recreate mock window
            $script:Window = New-Object PSCustomObject
            $script:Window | Add-Member -MemberType ScriptMethod -Name UpdateLayout -Value {} -Force
        }

        Context "Add-ErrorToHistory" {
            It "Should add error to history buffer" {
                Add-ErrorToHistory -Message "Test error 1"

                $script:ErrorHistoryBuffer.Count | Should -Be 1
                $script:ErrorHistoryBuffer[0].Message | Should -Be "Test error 1"
                $script:ErrorHistoryBuffer[0].Timestamp | Should -Not -BeNullOrEmpty
            }

            It "Should add multiple errors to history" {
                Add-ErrorToHistory -Message "Error 1"
                Add-ErrorToHistory -Message "Error 2"
                Add-ErrorToHistory -Message "Error 3"

                $script:ErrorHistoryBuffer.Count | Should -Be 3
                $script:ErrorHistoryBuffer[0].Message | Should -Be "Error 1"
                $script:ErrorHistoryBuffer[1].Message | Should -Be "Error 2"
                $script:ErrorHistoryBuffer[2].Message | Should -Be "Error 3"
            }

            It "Should maintain MaxErrorHistoryItems limit" {
                # Add more than MaxErrorHistoryItems (10) errors
                for ($i = 1; $i -le 15; $i++) {
                    Add-ErrorToHistory -Message "Error $i"
                }

                # Should only keep last 10
                $script:ErrorHistoryBuffer.Count | Should -Be 10
                # First error should be "Error 6" (oldest kept)
                $script:ErrorHistoryBuffer[0].Message | Should -Be "Error 6"
                # Last error should be "Error 15"
                $script:ErrorHistoryBuffer[9].Message | Should -Be "Error 15"
            }

            It "Should remove oldest errors when limit exceeded" {
                # Add exactly MaxErrorHistoryItems
                for ($i = 1; $i -le 10; $i++) {
                    Add-ErrorToHistory -Message "Error $i"
                }

                # Add one more
                Add-ErrorToHistory -Message "Error 11"

                # Should still be at limit
                $script:ErrorHistoryBuffer.Count | Should -Be 10
                # "Error 1" should be gone
                $script:ErrorHistoryBuffer[0].Message | Should -Be "Error 2"
                # "Error 11" should be last
                $script:ErrorHistoryBuffer[9].Message | Should -Be "Error 11"
            }

            It "Should format timestamp as HH:mm:ss" {
                Add-ErrorToHistory -Message "Test error"

                $timestamp = $script:ErrorHistoryBuffer[0].Timestamp
                # Should match HH:mm:ss pattern (e.g., "14:35:22")
                $timestamp | Should -Match '^\d{2}:\d{2}:\d{2}$'
            }
        }

        Context "Update-ErrorIndicatorState" {
            It "Should update status when errors exist" {
                $script:GuiErrorCount = 3

                Update-ErrorIndicatorState

                # Should show error count and be clickable
                $script:Controls.txtStatus.Text | Should -Match "3 error\(s\)"
                $script:Controls.txtStatus.Text | Should -Match "click to view"
            }

            It "Should make control clickable when errors exist" {
                $script:GuiErrorCount = 1

                Update-ErrorIndicatorState

                # Cursor should be Hand (we can't test the actual WPF enum in unit tests,
                # but we verify the property is set)
                $script:Controls.txtStatus.Cursor | Should -Not -BeNullOrEmpty
            }

            It "Should reset state when no errors" {
                # First set error state
                $script:GuiErrorCount = 5
                Update-ErrorIndicatorState

                # Then clear errors and update
                $script:GuiErrorCount = 0
                Update-ErrorIndicatorState

                # Should reset cursor
                $script:Controls.txtStatus.Cursor | Should -Not -BeNullOrEmpty
            }

            It "Should handle missing controls gracefully" {
                $script:Controls = $null
                $script:GuiErrorCount = 1

                # Should not throw
                { Update-ErrorIndicatorState } | Should -Not -Throw
            }
        }

        Context "Clear-ErrorHistory" {
            It "Should clear error history buffer" {
                # Add some errors
                Add-ErrorToHistory -Message "Error 1"
                Add-ErrorToHistory -Message "Error 2"
                Add-ErrorToHistory -Message "Error 3"

                $script:ErrorHistoryBuffer.Count | Should -Be 3

                Clear-ErrorHistory

                $script:ErrorHistoryBuffer.Count | Should -Be 0
            }

            It "Should reset error count" {
                $script:GuiErrorCount = 5

                Clear-ErrorHistory

                $script:GuiErrorCount | Should -Be 0
            }

            It "Should update status control" {
                # Set error state
                $script:GuiErrorCount = 3
                $script:Controls.txtStatus.Text = "Errors exist"

                Clear-ErrorHistory

                $script:Controls.txtStatus.Text | Should -Be "Replication in progress..."
            }

            It "Should reset cursor to arrow" {
                # Set clickable state
                $script:GuiErrorCount = 1
                Update-ErrorIndicatorState

                Clear-ErrorHistory

                # Cursor should be reset
                $script:Controls.txtStatus.Cursor | Should -Not -BeNullOrEmpty
            }
        }

        Context "Integration - Error Flow" {
            It "Should track errors through complete workflow" {
                # Simulate error being added
                Add-ErrorToHistory -Message "Integration test error"
                $script:GuiErrorCount = 1

                # Update indicator
                Update-ErrorIndicatorState

                # Verify state
                $script:ErrorHistoryBuffer.Count | Should -Be 1
                $script:ErrorHistoryBuffer[0].Message | Should -Be "Integration test error"
                $script:GuiErrorCount | Should -Be 1
                $script:Controls.txtStatus.Text | Should -Match "1 error\(s\)"
            }

            It "Should handle multiple errors in sequence" {
                # Simulate multiple errors
                for ($i = 1; $i -le 5; $i++) {
                    Add-ErrorToHistory -Message "Error $i"
                    $script:GuiErrorCount++
                    Update-ErrorIndicatorState
                }

                # Verify final state
                $script:ErrorHistoryBuffer.Count | Should -Be 5
                $script:GuiErrorCount | Should -Be 5
                $script:Controls.txtStatus.Text | Should -Match "5 error\(s\)"
            }

            It "Should clear all state when clearing history" {
                # Set up error state
                Add-ErrorToHistory -Message "Error 1"
                Add-ErrorToHistory -Message "Error 2"
                $script:GuiErrorCount = 2
                Update-ErrorIndicatorState

                # Clear
                Clear-ErrorHistory

                # Verify everything is reset
                $script:ErrorHistoryBuffer.Count | Should -Be 0
                $script:GuiErrorCount | Should -Be 0
                $script:Controls.txtStatus.Text | Should -Match "Replication in progress"
            }
        }

        Context "Thread Safety" {
            It "Should handle concurrent Add-ErrorToHistory calls" {
                # This is a basic test - full thread safety testing would require
                # actual concurrent execution which is difficult in Pester

                # Rapidly add errors to test locking doesn't deadlock
                for ($i = 1; $i -le 20; $i++) {
                    Add-ErrorToHistory -Message "Concurrent error $i"
                }

                # Should have added all errors up to the limit
                $script:ErrorHistoryBuffer.Count | Should -BeGreaterThan 0
                $script:ErrorHistoryBuffer.Count | Should -BeLessOrEqual 10
            }

            It "Should handle concurrent Clear-ErrorHistory calls" {
                # Add errors
                Add-ErrorToHistory -Message "Error 1"
                Add-ErrorToHistory -Message "Error 2"

                # Multiple clears should not throw
                { Clear-ErrorHistory } | Should -Not -Throw
                { Clear-ErrorHistory } | Should -Not -Throw

                $script:ErrorHistoryBuffer.Count | Should -Be 0
            }
        }
    }
}
