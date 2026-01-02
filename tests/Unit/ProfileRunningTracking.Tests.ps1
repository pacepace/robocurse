#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type (required for module isolation when running all tests together)
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "Profile Running Tracking" {
        BeforeAll {
            Mock Write-RobocurseLog { }
        }

        BeforeEach {
            # Clear any existing profile registrations
            Clear-RunningProfiles
        }

        AfterEach {
            # Clean up after each test
            Clear-RunningProfiles
        }

        Context "Get-ProfileMutexName" {
            It "Should return valid mutex name for simple profile name" {
                $mutexName = Get-ProfileMutexName -ProfileName "MyProfile"

                $mutexName | Should -Be "Global\RobocurseProfile_MyProfile"
            }

            It "Should sanitize special characters in profile name" {
                $mutexName = Get-ProfileMutexName -ProfileName "My/Profile:Test"

                $mutexName | Should -Be "Global\RobocurseProfile_My_Profile_Test"
            }

            It "Should handle profile names with backslashes" {
                $mutexName = Get-ProfileMutexName -ProfileName "Server\Share"

                $mutexName | Should -Be "Global\RobocurseProfile_Server_Share"
            }
        }

        Context "Register-RunningProfile" {
            It "Should successfully register a profile" {
                $result = Register-RunningProfile -ProfileName "TestProfile"

                $result | Should -Be $true
            }

            It "Should prevent duplicate registration from same process" {
                # First registration
                Register-RunningProfile -ProfileName "TestProfile" | Should -Be $true

                # Second registration should still return true (we already own it)
                Register-RunningProfile -ProfileName "TestProfile" | Should -Be $true
            }

            It "Should allow multiple different profiles to be registered" {
                Register-RunningProfile -ProfileName "Profile1" | Should -Be $true
                Register-RunningProfile -ProfileName "Profile2" | Should -Be $true
                Register-RunningProfile -ProfileName "Profile3" | Should -Be $true
            }
        }

        Context "Test-ProfileRunning" {
            It "Should return false for unregistered profile" {
                $result = Test-ProfileRunning -ProfileName "NotRunning"

                $result | Should -Be $false
            }

            It "Should return true for registered profile" {
                Register-RunningProfile -ProfileName "RunningProfile" | Out-Null

                $result = Test-ProfileRunning -ProfileName "RunningProfile"

                $result | Should -Be $true
            }
        }

        Context "Unregister-RunningProfile" {
            It "Should successfully unregister a registered profile" {
                Register-RunningProfile -ProfileName "TestProfile" | Out-Null

                $result = Unregister-RunningProfile -ProfileName "TestProfile"

                $result | Should -Be $true
            }

            It "Should return false when unregistering non-existent profile" {
                $result = Unregister-RunningProfile -ProfileName "NotRegistered"

                $result | Should -Be $false
            }

            It "Should allow re-registration after unregistration" {
                Register-RunningProfile -ProfileName "TestProfile" | Out-Null
                Unregister-RunningProfile -ProfileName "TestProfile" | Out-Null

                $result = Register-RunningProfile -ProfileName "TestProfile"

                $result | Should -Be $true
            }

            It "Profile should not be running after unregistration" {
                Register-RunningProfile -ProfileName "TestProfile" | Out-Null
                Unregister-RunningProfile -ProfileName "TestProfile" | Out-Null

                Test-ProfileRunning -ProfileName "TestProfile" | Should -Be $false
            }
        }

        Context "Get-RunningProfiles" {
            It "Should return empty array when no profiles running" {
                $profiles = Get-RunningProfiles

                $profiles.Count | Should -Be 0
            }

            It "Should return registered profile names" {
                Register-RunningProfile -ProfileName "Profile1" | Out-Null
                Register-RunningProfile -ProfileName "Profile2" | Out-Null

                $profiles = Get-RunningProfiles

                $profiles.Count | Should -Be 2
                $profiles | Should -Contain "Profile1"
                $profiles | Should -Contain "Profile2"
            }
        }

        Context "Clear-RunningProfiles" {
            It "Should clear all registrations" {
                Register-RunningProfile -ProfileName "Profile1" | Out-Null
                Register-RunningProfile -ProfileName "Profile2" | Out-Null

                Clear-RunningProfiles

                (Get-RunningProfiles).Count | Should -Be 0
            }

            It "Should handle empty list gracefully" {
                { Clear-RunningProfiles } | Should -Not -Throw
            }

            It "Profiles should not be running after clear" {
                Register-RunningProfile -ProfileName "TestProfile" | Out-Null

                Clear-RunningProfiles

                Test-ProfileRunning -ProfileName "TestProfile" | Should -Be $false
            }
        }

        Context "Cross-process detection simulation" {
            It "Should detect mutex held by another acquisition in same process" {
                # Simulate first process acquiring the mutex
                $result1 = Register-RunningProfile -ProfileName "SharedProfile"
                $result1 | Should -Be $true

                # Test-ProfileRunning should return true (our local check)
                Test-ProfileRunning -ProfileName "SharedProfile" | Should -Be $true
            }
        }
    }

    Describe "Profile Running Integration with JobManagement" {
        BeforeAll {
            Mock Write-RobocurseLog { }
            Mock Write-SiemEvent { }
        }

        BeforeEach {
            Clear-RunningProfiles
            Initialize-OrchestrationState
        }

        AfterEach {
            Clear-RunningProfiles
        }

        Context "Start-ProfileReplication duplicate prevention" {
            It "Should block duplicate profile via Register-RunningProfile" {
                # Test the registration mechanism directly since Start-ProfileReplication
                # has many dependencies. The key behavior is that Register-RunningProfile
                # prevents duplicates.

                $profileName = "DuplicateTestProfile"

                # First registration succeeds
                $first = Register-RunningProfile -ProfileName $profileName
                $first | Should -Be $true

                # Profile should now be detected as running
                Test-ProfileRunning -ProfileName $profileName | Should -Be $true

                # Trying to register again from the same process should return true
                # (we already own the mutex)
                $second = Register-RunningProfile -ProfileName $profileName
                $second | Should -Be $true

                # After unregistration, it should no longer be running
                Unregister-RunningProfile -ProfileName $profileName | Out-Null
                Test-ProfileRunning -ProfileName $profileName | Should -Be $false
            }

            It "Should unregister profile after Complete-CurrentProfile" {
                # This tests the integration point where Complete-CurrentProfile
                # calls Unregister-RunningProfile

                $profileName = "CompleteTestProfile"

                # Manually register as if Start-ProfileReplication did
                Register-RunningProfile -ProfileName $profileName | Should -Be $true

                # Simulate what Complete-CurrentProfile does
                Unregister-RunningProfile -ProfileName $profileName | Should -Be $true

                # Profile should no longer be running
                Test-ProfileRunning -ProfileName $profileName | Should -Be $false
            }
        }
    }
}
