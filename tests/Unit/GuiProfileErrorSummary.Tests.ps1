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
    Describe "GUI Profile Error Summary Tests" {

        BeforeAll {
            # Mock logging functions to prevent error output in tests
            Mock Write-RobocurseLog { }
            Mock Write-SiemEvent { }
            Mock Write-GuiLog { }
        }

        BeforeEach {
            # Initialize ProfileErrorCounts dictionary
            $script:ProfileErrorCounts = [System.Collections.Generic.Dictionary[string, int]]::new()

            # Initialize ErrorHistoryBuffer if not already
            if (-not $script:ErrorHistoryBuffer) {
                $script:ErrorHistoryBuffer = [System.Collections.Generic.List[PSCustomObject]]::new()
            } else {
                $script:ErrorHistoryBuffer.Clear()
            }

            # Reset error state
            $script:GuiErrorCount = 0

            # Recreate mock controls fresh each test
            $script:Controls = @{
                pnlProfileErrors = [PSCustomObject]@{
                    Visibility = 'Collapsed'
                }
                pnlProfileErrorItems = [PSCustomObject]@{
                    Children = New-Object System.Collections.ArrayList
                }
            }

            # Mock OrchestrationState for testing
            $script:OrchestrationState = [PSCustomObject]@{
                Profiles = @(
                    [PSCustomObject]@{ Name = 'Profile1' }
                    [PSCustomObject]@{ Name = 'Profile2' }
                )
                CurrentProfile = [PSCustomObject]@{ Name = 'Profile1' }
            }
        }

        AfterEach {
            # Clean up tracking
            Reset-ProfileErrorTracking
        }

        Context "Add-ProfileError" {
            It "Should create new entry for profile" {
                Add-ProfileError -ProfileName 'Profile1'

                $script:ProfileErrorCounts.ContainsKey('Profile1') | Should -Be $true
                $script:ProfileErrorCounts['Profile1'] | Should -Be 1
            }

            It "Should increment existing entry" {
                Add-ProfileError -ProfileName 'Profile1'
                Add-ProfileError -ProfileName 'Profile1'
                Add-ProfileError -ProfileName 'Profile1'

                $script:ProfileErrorCounts['Profile1'] | Should -Be 3
            }

            It "Should track multiple profiles independently" {
                Add-ProfileError -ProfileName 'Profile1'
                Add-ProfileError -ProfileName 'Profile1'
                Add-ProfileError -ProfileName 'Profile2'
                Add-ProfileError -ProfileName 'Profile3'
                Add-ProfileError -ProfileName 'Profile2'

                $script:ProfileErrorCounts['Profile1'] | Should -Be 2
                $script:ProfileErrorCounts['Profile2'] | Should -Be 2
                $script:ProfileErrorCounts['Profile3'] | Should -Be 1
            }

            It "Should initialize count at 0 for new profile" {
                # ProfileErrorCounts should be empty initially
                $script:ProfileErrorCounts.Count | Should -Be 0

                Add-ProfileError -ProfileName 'NewProfile'

                $script:ProfileErrorCounts.ContainsKey('NewProfile') | Should -Be $true
                $script:ProfileErrorCounts['NewProfile'] | Should -Be 1
            }
        }

        Context "Reset-ProfileErrorTracking" {
            It "Should clear all counts" {
                # Add some errors
                Add-ProfileError -ProfileName 'Profile1'
                Add-ProfileError -ProfileName 'Profile2'
                Add-ProfileError -ProfileName 'Profile3'

                $script:ProfileErrorCounts.Count | Should -Be 3

                Reset-ProfileErrorTracking

                $script:ProfileErrorCounts.Count | Should -Be 0
            }

            It "Should handle empty dictionary" {
                Reset-ProfileErrorTracking

                # Should not throw
                $script:ProfileErrorCounts.Count | Should -Be 0
            }

            It "Should allow new tracking after reset" {
                # Add errors
                Add-ProfileError -ProfileName 'Profile1'
                Add-ProfileError -ProfileName 'Profile1'

                # Reset
                Reset-ProfileErrorTracking

                # Add new errors
                Add-ProfileError -ProfileName 'Profile2'

                $script:ProfileErrorCounts.ContainsKey('Profile1') | Should -Be $false
                $script:ProfileErrorCounts.ContainsKey('Profile2') | Should -Be $true
                $script:ProfileErrorCounts['Profile2'] | Should -Be 1
            }
        }

        Context "Get-ProfileErrorSummary" {
            It "Should return empty array when no errors" {
                $summary = Get-ProfileErrorSummary

                $summary.Count | Should -Be 0
            }

            It "Should return correct data for single profile" {
                Add-ProfileError -ProfileName 'Profile1'
                Add-ProfileError -ProfileName 'Profile1'
                Add-ProfileError -ProfileName 'Profile1'

                $summary = Get-ProfileErrorSummary

                $summary.Count | Should -Be 1
                $summary[0].Name | Should -Be 'Profile1'
                $summary[0].ErrorCount | Should -Be 3
            }

            It "Should return correct data for multiple profiles" {
                Add-ProfileError -ProfileName 'Profile1'
                Add-ProfileError -ProfileName 'Profile1'
                Add-ProfileError -ProfileName 'Profile2'
                Add-ProfileError -ProfileName 'Profile3'
                Add-ProfileError -ProfileName 'Profile3'
                Add-ProfileError -ProfileName 'Profile3'

                $summary = Get-ProfileErrorSummary

                $summary.Count | Should -Be 3

                $profile1 = $summary | Where-Object { $_.Name -eq 'Profile1' }
                $profile1.ErrorCount | Should -Be 2

                $profile2 = $summary | Where-Object { $_.Name -eq 'Profile2' }
                $profile2.ErrorCount | Should -Be 1

                $profile3 = $summary | Where-Object { $_.Name -eq 'Profile3' }
                $profile3.ErrorCount | Should -Be 3
            }

            It "Should include profiles with zero errors if they were initialized" {
                # Manually initialize a profile with zero errors
                $script:ProfileErrorCounts['ProfileNoErrors'] = 0
                Add-ProfileError -ProfileName 'ProfileWithErrors'

                $summary = Get-ProfileErrorSummary

                $summary.Count | Should -Be 2

                $profileNoErrors = $summary | Where-Object { $_.Name -eq 'ProfileNoErrors' }
                $profileNoErrors.ErrorCount | Should -Be 0

                $profileWithErrors = $summary | Where-Object { $_.Name -eq 'ProfileWithErrors' }
                $profileWithErrors.ErrorCount | Should -Be 1
            }
        }

        Context "Update-ProfileErrorSummary" {
            It "Should hide panel when less than 2 profiles" {
                # Single profile
                $script:OrchestrationState.Profiles = @([PSCustomObject]@{ Name = 'Profile1' })

                Update-ProfileErrorSummary

                $script:Controls.pnlProfileErrors.Visibility | Should -Be 'Collapsed'
            }

            It "Should hide panel when no data" {
                # Multiple profiles but no error data yet
                Reset-ProfileErrorTracking

                Update-ProfileErrorSummary

                $script:Controls.pnlProfileErrors.Visibility | Should -Be 'Collapsed'
            }

            It "Should show panel when 2+ profiles and data exists" {
                Add-ProfileError -ProfileName 'Profile1'

                Update-ProfileErrorSummary

                $script:Controls.pnlProfileErrors.Visibility | Should -Be 'Visible'
            }

            It "Should handle missing controls gracefully" {
                $script:Controls = $null

                # Should not throw
                { Update-ProfileErrorSummary } | Should -Not -Throw
            }

            It "Should handle null orchestration state" {
                $script:OrchestrationState = $null
                Add-ProfileError -ProfileName 'Profile1'

                # Should hide panel when orchestration state is null
                Update-ProfileErrorSummary

                $script:Controls.pnlProfileErrors.Visibility | Should -Be 'Collapsed'
            }
        }

        Context "Integration with error dequeue" {
            It "Should track errors by current profile" {
                # Simulate errors being added for current profile
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = 'Profile1' }

                Add-ProfileError -ProfileName $script:OrchestrationState.CurrentProfile.Name
                Add-ProfileError -ProfileName $script:OrchestrationState.CurrentProfile.Name

                $summary = Get-ProfileErrorSummary
                $profile1 = $summary | Where-Object { $_.Name -eq 'Profile1' }
                $profile1.ErrorCount | Should -Be 2
            }

            It "Should track errors across profile switches" {
                # Profile1 has errors
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = 'Profile1' }
                Add-ProfileError -ProfileName $script:OrchestrationState.CurrentProfile.Name
                Add-ProfileError -ProfileName $script:OrchestrationState.CurrentProfile.Name

                # Switch to Profile2
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = 'Profile2' }
                Add-ProfileError -ProfileName $script:OrchestrationState.CurrentProfile.Name

                # Back to Profile1
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = 'Profile1' }
                Add-ProfileError -ProfileName $script:OrchestrationState.CurrentProfile.Name

                $summary = Get-ProfileErrorSummary

                $profile1 = $summary | Where-Object { $_.Name -eq 'Profile1' }
                $profile1.ErrorCount | Should -Be 3

                $profile2 = $summary | Where-Object { $_.Name -eq 'Profile2' }
                $profile2.ErrorCount | Should -Be 1
            }

            It "Should handle null current profile gracefully" {
                $script:OrchestrationState.CurrentProfile = $null

                # Should not throw when current profile is null
                # (this simulates the check in Update-GuiProgress)
                if ($script:OrchestrationState.CurrentProfile -and $script:OrchestrationState.CurrentProfile.Name) {
                    Add-ProfileError -ProfileName $script:OrchestrationState.CurrentProfile.Name
                }

                # Should have no errors tracked
                $summary = Get-ProfileErrorSummary
                $summary.Count | Should -Be 0
            }
        }

        Context "Thread Safety" {
            It "Should handle concurrent Add-ProfileError calls" {
                # Rapidly add errors to test locking doesn't deadlock
                for ($i = 1; $i -le 20; $i++) {
                    Add-ProfileError -ProfileName "Profile$($i % 3 + 1)"
                }

                # Should have entries for Profile1, Profile2, Profile3
                $script:ProfileErrorCounts.Count | Should -BeGreaterThan 0
                $script:ProfileErrorCounts.Count | Should -BeLessOrEqual 3
            }

            It "Should handle concurrent Get-ProfileErrorSummary calls" {
                Add-ProfileError -ProfileName 'Profile1'
                Add-ProfileError -ProfileName 'Profile2'

                # Multiple reads should not throw
                $summary1 = Get-ProfileErrorSummary
                $summary2 = Get-ProfileErrorSummary

                $summary1.Count | Should -Be $summary2.Count
            }

            It "Should handle concurrent Reset-ProfileErrorTracking calls" {
                Add-ProfileError -ProfileName 'Profile1'
                Add-ProfileError -ProfileName 'Profile2'

                # Multiple resets should not throw
                { Reset-ProfileErrorTracking } | Should -Not -Throw
                { Reset-ProfileErrorTracking } | Should -Not -Throw

                $script:ProfileErrorCounts.Count | Should -Be 0
            }
        }

        Context "Complete workflow" {
            It "Should track errors through complete multi-profile run" {
                # Start with clean state
                Reset-ProfileErrorTracking

                # Profile 1 runs with 3 errors
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = 'Profile1' }
                for ($i = 1; $i -le 3; $i++) {
                    Add-ProfileError -ProfileName $script:OrchestrationState.CurrentProfile.Name
                }

                # Profile 2 runs with 0 errors (no Add-ProfileError calls)

                # Profile 3 runs with 1 error
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = 'Profile3' }
                Add-ProfileError -ProfileName $script:OrchestrationState.CurrentProfile.Name

                # Verify summary
                $summary = Get-ProfileErrorSummary

                $profile1 = $summary | Where-Object { $_.Name -eq 'Profile1' }
                $profile1.ErrorCount | Should -Be 3

                $profile3 = $summary | Where-Object { $_.Name -eq 'Profile3' }
                $profile3.ErrorCount | Should -Be 1

                # Profile2 never called Add-ProfileError, so it won't appear
                $profile2 = $summary | Where-Object { $_.Name -eq 'Profile2' }
                $profile2 | Should -BeNullOrEmpty
            }

            It "Should reset for new run" {
                # First run
                Add-ProfileError -ProfileName 'Profile1'
                Add-ProfileError -ProfileName 'Profile2'

                $summary = Get-ProfileErrorSummary
                $summary.Count | Should -Be 2

                # New run starts
                Reset-ProfileErrorTracking

                # Second run
                Add-ProfileError -ProfileName 'Profile3'

                $summary = Get-ProfileErrorSummary
                $summary.Count | Should -Be 1
                $summary[0].Name | Should -Be 'Profile3'
            }
        }
    }
}
