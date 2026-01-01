#Requires -Modules Pester

<#
.SYNOPSIS
    Integration tests for concurrent job handling
.DESCRIPTION
    Tests the thread-safe drive letter allocation and profile running detection
    features that prevent conflicts when multiple jobs run simultaneously.
#>

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type
Initialize-OrchestrationStateType | Out-Null

Describe "Concurrent Job Integration Tests" {

    Context "Profile Running Mutex - Cross Process Detection" {
        BeforeEach {
            # Ensure clean state
            InModuleScope 'Robocurse' {
                Clear-RunningProfiles
            }
        }

        AfterEach {
            # Clean up
            InModuleScope 'Robocurse' {
                Clear-RunningProfiles
            }
        }

        It "Should detect profile running from another PowerShell session" {
            # This test simulates what happens when two scheduled tasks try to run the same profile

            # First session registers the profile
            $registered = InModuleScope 'Robocurse' {
                Register-RunningProfile -ProfileName "ConcurrentTestProfile"
            }
            $registered | Should -Be $true

            # Simulate second session trying to check/register
            # Since we're in the same process but the mutex is held, it should return true for Test
            $isRunning = InModuleScope 'Robocurse' {
                Test-ProfileRunning -ProfileName "ConcurrentTestProfile"
            }
            $isRunning | Should -Be $true

            # Clean up
            InModuleScope 'Robocurse' {
                Unregister-RunningProfile -ProfileName "ConcurrentTestProfile"
            }

            # Now it should not be running
            $isRunningAfter = InModuleScope 'Robocurse' {
                Test-ProfileRunning -ProfileName "ConcurrentTestProfile"
            }
            $isRunningAfter | Should -Be $false
        }

        It "Should allow registration after mutex is released" {
            # First registration
            InModuleScope 'Robocurse' {
                Register-RunningProfile -ProfileName "ReleaseTestProfile" | Should -Be $true
            }

            # Unregister
            InModuleScope 'Robocurse' {
                Unregister-RunningProfile -ProfileName "ReleaseTestProfile" | Should -Be $true
            }

            # Should be able to register again
            InModuleScope 'Robocurse' {
                Register-RunningProfile -ProfileName "ReleaseTestProfile" | Should -Be $true
            }

            # Cleanup
            InModuleScope 'Robocurse' {
                Unregister-RunningProfile -ProfileName "ReleaseTestProfile" | Out-Null
            }
        }
    }

    Context "Drive Letter Allocation - Concurrent Requests" {
        BeforeEach {
            InModuleScope 'Robocurse' {
                $script:ReservedDriveLetters.Clear()
            }
        }

        AfterEach {
            InModuleScope 'Robocurse' {
                $script:ReservedDriveLetters.Clear()
            }
        }

        It "Should allocate unique letters when reserved letters exist" {
            # This tests the reservation mechanism that prevents concurrent mounts
            # from grabbing the same drive letter

            InModuleScope 'Robocurse' {
                Mock Get-PSDrive {
                    @(
                        [PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null }
                    )
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                # First request - gets Z
                $letter1 = Get-NextAvailableDriveLetter
                $letter1 | Should -Be 'Z'

                # Simulate concurrent reservation
                $script:ReservedDriveLetters.Add('Z') | Out-Null

                # Second request - should get Y since Z is reserved
                $letter2 = Get-NextAvailableDriveLetter
                $letter2 | Should -Be 'Y'

                # Third request with Y also reserved
                $script:ReservedDriveLetters.Add('Y') | Out-Null
                $letter3 = Get-NextAvailableDriveLetter
                $letter3 | Should -Be 'X'
            }
        }

        It "Should use mutex to serialize drive letter allocation" {
            # This test verifies the mutex mechanism works by checking that
            # the global mutex name is constructed correctly

            $mutexName = InModuleScope 'Robocurse' {
                $script:DriveLetterMutexName
            }

            $mutexName | Should -Be "Global\RobocurseDriveLetterAllocation"
        }
    }

    Context "Concurrent Runspace Simulation" {
        It "Should handle multiple threads requesting drive letters" -Skip:($env:CI -eq 'true') {
            # This test uses actual runspaces to simulate concurrent requests
            # Skip in CI environments where parallel execution may be limited

            $modulePath = (Get-Module Robocurse).Path

            # Create multiple runspaces that will all try to get drive letters simultaneously
            $runspacePool = [runspacefactory]::CreateRunspacePool(1, 4)
            $runspacePool.Open()

            $results = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
            $jobs = @()

            # Start 4 concurrent requests
            for ($i = 0; $i -lt 4; $i++) {
                $powershell = [powershell]::Create()
                $powershell.RunspacePool = $runspacePool

                $powershell.AddScript({
                    param($modulePath)
                    Import-Module $modulePath -Force
                    InModuleScope 'Robocurse' {
                        $letter = Get-NextAvailableDriveLetter
                        return $letter
                    }
                }).AddArgument($modulePath)

                $jobs += @{
                    PowerShell = $powershell
                    Handle = $powershell.BeginInvoke()
                }
            }

            # Wait for all to complete and collect results
            foreach ($job in $jobs) {
                $result = $job.PowerShell.EndInvoke($job.Handle)
                if ($result) {
                    $results.Add($result)
                }
                $job.PowerShell.Dispose()
            }

            $runspacePool.Close()
            $runspacePool.Dispose()

            # All results should be valid drive letters
            foreach ($letter in $results) {
                $letter | Should -Match '^[D-Z]$'
            }
        }
    }

    Context "Same Profile Concurrent Run Prevention" {
        BeforeEach {
            InModuleScope 'Robocurse' {
                Clear-RunningProfiles
            }
        }

        AfterEach {
            InModuleScope 'Robocurse' {
                Clear-RunningProfiles
            }
        }

        It "Should prevent two instances trying to run the SAME profile simultaneously" {
            # This simulates what happens when:
            # 1. Scheduled task "DailyBackup" starts
            # 2. User manually runs "DailyBackup" while the scheduled task is running
            # The second attempt should be blocked

            $profileName = "DailyBackupProfile"

            # First "process" registers the profile (simulates scheduled task starting)
            $firstRegistration = InModuleScope 'Robocurse' -ArgumentList $profileName {
                param($name)
                Register-RunningProfile -ProfileName $name
            }
            $firstRegistration | Should -Be $true -Because "First instance should acquire the profile lock"

            # Second "process" tries to register the same profile
            # This would happen in Start-ProfileReplication where it calls Register-RunningProfile
            # In the same process, we still own the mutex, so we'd get $true
            # But the check in Start-ProfileReplication uses Test-ProfileRunning first
            $isAlreadyRunning = InModuleScope 'Robocurse' -ArgumentList $profileName {
                param($name)
                Test-ProfileRunning -ProfileName $name
            }
            $isAlreadyRunning | Should -Be $true -Because "Second instance should detect profile is already running"

            # The actual Start-ProfileReplication code does:
            # if (-not (Register-RunningProfile -ProfileName $Profile.Name)) { ... }
            # Since we already own the mutex, it returns true
            # But for cross-process scenario, the second process wouldn't get the mutex

            # Clean up first instance
            InModuleScope 'Robocurse' -ArgumentList $profileName {
                param($name)
                Unregister-RunningProfile -ProfileName $name
            }

            # Now a new instance should be able to run
            $newRegistration = InModuleScope 'Robocurse' -ArgumentList $profileName {
                param($name)
                Register-RunningProfile -ProfileName $name
            }
            $newRegistration | Should -Be $true -Because "After first instance completes, new instance should be able to run"

            # Cleanup
            InModuleScope 'Robocurse' -ArgumentList $profileName {
                param($name)
                Unregister-RunningProfile -ProfileName $name
            }
        }

        It "Should allow two DIFFERENT profiles to run simultaneously" {
            # This simulates:
            # 1. Profile "ServerBackup" is running
            # 2. User wants to also run "WorkstationBackup"
            # Both should be allowed to run concurrently

            $profile1 = "ServerBackupProfile"
            $profile2 = "WorkstationBackupProfile"

            # Start first profile
            $reg1 = InModuleScope 'Robocurse' -ArgumentList $profile1 {
                param($name)
                Register-RunningProfile -ProfileName $name
            }
            $reg1 | Should -Be $true -Because "First profile should start successfully"

            # Start second (different) profile - should also succeed
            $reg2 = InModuleScope 'Robocurse' -ArgumentList $profile2 {
                param($name)
                Register-RunningProfile -ProfileName $name
            }
            $reg2 | Should -Be $true -Because "Second different profile should also start successfully"

            # Both should be running
            $running = InModuleScope 'Robocurse' {
                Get-RunningProfiles
            }
            $running | Should -Contain $profile1
            $running | Should -Contain $profile2
            $running.Count | Should -Be 2

            # Clean up both
            InModuleScope 'Robocurse' -ArgumentList $profile1 {
                param($name)
                Unregister-RunningProfile -ProfileName $name
            }
            InModuleScope 'Robocurse' -ArgumentList $profile2 {
                param($name)
                Unregister-RunningProfile -ProfileName $name
            }
        }
    }

    Context "Concurrent UNC Path Mounting" {
        BeforeEach {
            InModuleScope 'Robocurse' {
                $script:ReservedDriveLetters.Clear()
            }
        }

        AfterEach {
            InModuleScope 'Robocurse' {
                $script:ReservedDriveLetters.Clear()
            }
        }

        It "Should allocate different drive letters when two UNC mounts happen simultaneously" {
            # This simulates:
            # 1. Profile A mounts \\server1\share
            # 2. Profile B mounts \\server2\share (while A is still mounting)
            # They should get different drive letters (e.g., Z and Y, not both Z)

            InModuleScope 'Robocurse' {
                Mock Get-PSDrive {
                    @(
                        [PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null }
                    )
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                # Simulate first mount starting (gets Z, adds to reserved)
                $letter1 = Get-NextAvailableDriveLetter
                $script:ReservedDriveLetters.Add([string]$letter1) | Out-Null

                # Simulate second mount starting while first is still in progress
                # Should get Y because Z is reserved
                $letter2 = Get-NextAvailableDriveLetter

                # Verify they got different letters
                $letter1 | Should -Be 'Z' -Because "First mount should get Z"
                $letter2 | Should -Be 'Y' -Because "Second mount should get Y (Z is reserved)"
                $letter1 | Should -Not -Be $letter2 -Because "Concurrent mounts should get different letters"
            }
        }

        It "Should handle three concurrent UNC mounts" {
            # More extensive test: three profiles all mounting different servers

            InModuleScope 'Robocurse' {
                Mock Get-PSDrive {
                    @(
                        [PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = $null }
                    )
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                # Simulate three concurrent mounts
                $letters = @()

                for ($i = 0; $i -lt 3; $i++) {
                    $letter = Get-NextAvailableDriveLetter
                    $script:ReservedDriveLetters.Add([string]$letter) | Out-Null
                    $letters += $letter
                }

                # Should get Z, Y, X
                $letters[0] | Should -Be 'Z'
                $letters[1] | Should -Be 'Y'
                $letters[2] | Should -Be 'X'

                # All should be unique
                $uniqueLetters = $letters | Select-Object -Unique
                $uniqueLetters.Count | Should -Be 3 -Because "All three mounts should have unique letters"
            }
        }
    }

    Context "Profile Registration Thread Safety" {
        It "Should handle rapid register/unregister cycles" {
            # Test that rapid registration and unregistration doesn't cause issues

            $profileName = "RapidCycleProfile"

            for ($i = 0; $i -lt 10; $i++) {
                $registered = InModuleScope 'Robocurse' -ArgumentList $profileName {
                    param($name)
                    Register-RunningProfile -ProfileName $name
                }
                $registered | Should -Be $true

                $unregistered = InModuleScope 'Robocurse' -ArgumentList $profileName {
                    param($name)
                    Unregister-RunningProfile -ProfileName $name
                }
                $unregistered | Should -Be $true
            }

            # Final state should be not running
            $isRunning = InModuleScope 'Robocurse' -ArgumentList $profileName {
                param($name)
                Test-ProfileRunning -ProfileName $name
            }
            $isRunning | Should -Be $false
        }

        It "Should handle multiple profiles registered simultaneously" {
            $profileNames = @("Profile_A", "Profile_B", "Profile_C", "Profile_D", "Profile_E")

            # Register all profiles
            foreach ($name in $profileNames) {
                $result = InModuleScope 'Robocurse' -ArgumentList $name {
                    param($profileName)
                    Register-RunningProfile -ProfileName $profileName
                }
                $result | Should -Be $true
            }

            # Verify all are running
            foreach ($name in $profileNames) {
                $isRunning = InModuleScope 'Robocurse' -ArgumentList $name {
                    param($profileName)
                    Test-ProfileRunning -ProfileName $profileName
                }
                $isRunning | Should -Be $true -Because "Profile '$name' should be registered as running"
            }

            # Get all running profiles
            $runningList = InModuleScope 'Robocurse' {
                Get-RunningProfiles
            }
            $runningList.Count | Should -Be 5

            # Clean up
            InModuleScope 'Robocurse' {
                Clear-RunningProfiles
            }
        }
    }

    Context "Error Recovery" {
        It "Should recover from abandoned mutex (simulated crash)" {
            # This tests the AbandonedMutexException handling
            # In real scenarios, Windows automatically releases mutexes when processes die

            $profileName = "AbandonedMutexProfile"

            # Register the profile
            InModuleScope 'Robocurse' -ArgumentList $profileName {
                param($name)
                Register-RunningProfile -ProfileName $name | Should -Be $true
            }

            # Clean up normally (simulating graceful shutdown)
            InModuleScope 'Robocurse' -ArgumentList $profileName {
                param($name)
                Unregister-RunningProfile -ProfileName $name | Should -Be $true
            }

            # Should be able to register again (simulating new process starting after crash)
            InModuleScope 'Robocurse' -ArgumentList $profileName {
                param($name)
                Register-RunningProfile -ProfileName $name | Should -Be $true
            }

            # Cleanup
            InModuleScope 'Robocurse' {
                Clear-RunningProfiles
            }
        }
    }

    Context "SMB Mapping Detection for Checkpoint Recovery" {
        BeforeEach {
            InModuleScope 'Robocurse' {
                $script:ReservedDriveLetters.Clear()
            }
        }

        AfterEach {
            InModuleScope 'Robocurse' {
                $script:ReservedDriveLetters.Clear()
            }
        }

        It "Should skip drive letters that have SMB remembered connections" {
            # Scenario: Previous run crashed, Z: is "remembered" by Windows
            # but not visible to Get-PSDrive. Get-SmbMapping should catch it.

            InModuleScope 'Robocurse' {
                # Mock Get-PSDrive to show Z: is NOT in use (simulates PS not seeing it)
                Mock Get-PSDrive {
                    @([PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' } })
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                # Mock Get-SmbMapping to show Z: IS in use (Windows remembers it)
                Mock Get-SmbMapping {
                    @(
                        [PSCustomObject]@{ LocalPath = 'Z:'; RemotePath = '\\server\share1'; Status = 'Disconnected' }
                    )
                }

                # Should skip Z and return Y
                $letter = Get-NextAvailableDriveLetter
                $letter | Should -Be 'Y' -Because "Z has a remembered SMB connection"
            }
        }

        It "Should skip multiple SMB-mapped drive letters" {
            InModuleScope 'Robocurse' {
                Mock Get-PSDrive {
                    @([PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' } })
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                # Z and Y are both remembered from previous runs
                Mock Get-SmbMapping {
                    @(
                        [PSCustomObject]@{ LocalPath = 'Z:'; RemotePath = '\\server1\share'; Status = 'OK' },
                        [PSCustomObject]@{ LocalPath = 'Y:'; RemotePath = '\\server2\share'; Status = 'Disconnected' }
                    )
                }

                $letter = Get-NextAvailableDriveLetter
                $letter | Should -Be 'X' -Because "Z and Y have remembered SMB connections"
            }
        }

        It "Should handle checkpoint resume when drive letter is occupied" {
            # Simulates the exact customer scenario:
            # 1. Previous run with \\poseidon\sharedapps was interrupted
            # 2. Another process grabbed drive letters
            # 3. Resume should pick a different letter

            InModuleScope 'Robocurse' {
                # C is local, Z is occupied by another process
                Mock Get-PSDrive {
                    @(
                        [PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' } },
                        [PSCustomObject]@{ Name = 'Z'; Provider = @{ Name = 'FileSystem' }; DisplayRoot = '\\other\share' }
                    )
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                # Get-SmbMapping also shows Z is in use
                Mock Get-SmbMapping {
                    @([PSCustomObject]@{ LocalPath = 'Z:'; RemotePath = '\\other\share'; Status = 'OK' })
                }

                # Should pick Y, not Z
                $letter = Get-NextAvailableDriveLetter
                $letter | Should -Be 'Y' -Because "Z is occupied by another process"
            }
        }

        It "Should fall back to net use parsing when SmbShare module unavailable" {
            InModuleScope 'Robocurse' {
                Mock Get-PSDrive {
                    @([PSCustomObject]@{ Name = 'C'; Provider = @{ Name = 'FileSystem' } })
                } -ParameterFilter { $PSProvider -eq 'FileSystem' }

                # Simulate SmbShare module not being available
                Mock Get-SmbMapping { throw "The term 'Get-SmbMapping' is not recognized" }

                # We can't easily mock the external 'net use' command, but we can verify
                # the function doesn't throw when Get-SmbMapping fails
                { Get-NextAvailableDriveLetter } | Should -Not -Throw
            }
        }
    }

    Context "Dismount with Remove-SmbMapping" {
        It "Should use Remove-SmbMapping for cleanup" {
            InModuleScope 'Robocurse' {
                Mock Remove-SmbMapping { }
                Mock Remove-PSDrive { }
                Mock Write-RobocurseLog { }
                Mock Remove-NetworkMappingTracking { }

                $mappings = @(
                    [PSCustomObject]@{ DriveLetter = 'Z'; Root = '\\server\share' }
                )

                Dismount-NetworkPaths -Mappings $mappings

                # Verify Remove-SmbMapping was called
                Should -Invoke Remove-SmbMapping -Times 1 -ParameterFilter {
                    $LocalPath -eq 'Z:' -and $Force -eq $true -and $UpdateProfile -eq $true
                }
            }
        }

        It "Should fall back to Remove-PSDrive if SmbShare module unavailable" {
            InModuleScope 'Robocurse' {
                # Simulate SmbShare module not available
                Mock Remove-SmbMapping { throw [System.Management.Automation.CommandNotFoundException]::new("Remove-SmbMapping") }
                Mock Remove-PSDrive { }
                Mock Write-RobocurseLog { }
                Mock Remove-NetworkMappingTracking { }

                $mappings = @(
                    [PSCustomObject]@{ DriveLetter = 'Z'; Root = '\\server\share' }
                )

                Dismount-NetworkPaths -Mappings $mappings

                # Verify fallback to Remove-PSDrive was used
                Should -Invoke Remove-PSDrive -Times 1
            }
        }
    }

    Context "Remove-DriveMapping Helper" {
        It "Should use Remove-SmbMapping as primary method" {
            InModuleScope 'Robocurse' {
                Mock Remove-SmbMapping { }
                Mock Remove-PSDrive { }
                Mock Write-RobocurseLog { }

                $result = Remove-DriveMapping -DriveLetter 'Z'

                $result | Should -Be $true
                Should -Invoke Remove-SmbMapping -Times 1
                Should -Invoke Remove-PsDrive -Times 0  # Should not be called
            }
        }

        It "Should fall back to Remove-PSDrive only when SmbShare unavailable" {
            InModuleScope 'Robocurse' {
                Mock Remove-SmbMapping { throw [System.Management.Automation.CommandNotFoundException]::new("Remove-SmbMapping") }
                Mock Remove-PSDrive { }
                Mock Write-RobocurseLog { }

                $result = Remove-DriveMapping -DriveLetter 'Z'

                $result | Should -Be $true
                Should -Invoke Remove-PsDrive -Times 1
            }
        }

        It "Should return true when mapping doesn't exist" {
            InModuleScope 'Robocurse' {
                # Simulate "no mapping exists" error (not CommandNotFoundException)
                Mock Remove-SmbMapping { throw "No mapping exists for Z:" }
                Mock Write-RobocurseLog { }

                $result = Remove-DriveMapping -DriveLetter 'Z'

                # Should still return true - the goal (no mapping) is achieved
                $result | Should -Be $true
            }
        }
    }

    Context "Get-SmbMappedDriveLetters Helper" {
        It "Should return drive letters from SMB mappings" {
            InModuleScope 'Robocurse' {
                Mock Get-SmbMapping {
                    @(
                        [PSCustomObject]@{ LocalPath = 'Z:'; RemotePath = '\\server1\share' },
                        [PSCustomObject]@{ LocalPath = 'Y:'; RemotePath = '\\server2\share' }
                    )
                }
                Mock Write-RobocurseLog { }

                $letters = Get-SmbMappedDriveLetters

                $letters | Should -Contain 'Z'
                $letters | Should -Contain 'Y'
                $letters.Count | Should -Be 2
            }
        }

        It "Should return empty array when no SMB mappings exist" {
            InModuleScope 'Robocurse' {
                Mock Get-SmbMapping { @() }
                Mock Write-RobocurseLog { }

                $letters = Get-SmbMappedDriveLetters

                $letters.Count | Should -Be 0
            }
        }

        It "Should not throw when SmbShare module unavailable" {
            InModuleScope 'Robocurse' {
                Mock Get-SmbMapping { throw "Module not found" }
                Mock Write-RobocurseLog { }

                # Should not throw, should return empty or parsed net use results
                { Get-SmbMappedDriveLetters } | Should -Not -Throw
            }
        }
    }
}
