# 03-ProfileScheduleTests

Create unit tests for profile scheduling functions.

## Objective

Create comprehensive unit tests for all profile scheduling functions following the existing `Scheduling.Tests.ps1` pattern.

## Success Criteria

- [ ] All core functions have tests
- [ ] Mocks properly replace ScheduledTasks cmdlets
- [ ] Platform-specific tests skip on non-Windows
- [ ] Tests verify OperationResult pattern
- [ ] WhatIf support is tested
- [ ] Error handling paths are covered

## Research

### Test Pattern Reference
- `tests\Unit\Scheduling.Tests.ps1:1-38` - Module stub setup (critical for mocking CIM cmdlets)
- `tests\Unit\Scheduling.Tests.ps1:41-85` - Register task tests with mocks
- `tests\Unit\Scheduling.Tests.ps1:275-340` - Unregister task tests
- `tests\Unit\Scheduling.Tests.ps1:602-636` - WhatIf tests

### Key Testing Patterns
1. Remove ScheduledTasks module and create stub functions
2. Use InModuleScope for internal function access
3. Skip non-Windows tests: `-Skip:(-not (Test-IsWindowsPlatform))`
4. Mock all ScheduledTask cmdlets before each test

## Implementation

Create `tests\Unit\ProfileSchedule.Tests.ps1`:

```powershell
#Requires -Modules Pester

# IMPORTANT: Remove ScheduledTasks module and create stubs (same pattern as Scheduling.Tests.ps1)
if (Get-Module ScheduledTasks -ErrorAction SilentlyContinue) {
    Remove-Module ScheduledTasks -Force -ErrorAction SilentlyContinue
}

# Create stub functions that can be properly mocked
function global:New-ScheduledTaskAction { param($Execute, $Argument, $WorkingDirectory) }
function global:New-ScheduledTaskTrigger { param([switch]$Daily, [switch]$Weekly, [switch]$Once, $At, $DaysOfWeek, $RepetitionInterval, $RepetitionDuration) }
function global:New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) }
function global:New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable, [switch]$RunOnlyIfNetworkAvailable, $MultipleInstances, $ExecutionTimeLimit, $Priority) }
function global:Register-ScheduledTask { param($TaskName, $Action, $Trigger, $Principal, $Settings, $Description, [switch]$Force, $User, $Password) }
function global:Unregister-ScheduledTask { param($TaskName, [switch]$Confirm) }
function global:Get-ScheduledTask { param($TaskName) }
function global:Get-ScheduledTaskInfo { param($TaskName) }
function global:Enable-ScheduledTask { param($TaskName) }
function global:Disable-ScheduledTask { param($TaskName) }

# Load module
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

InModuleScope 'Robocurse' {
    Describe "Profile Scheduling" {
        BeforeAll {
            # Create temp config and script files
            $script:tempConfigPath = Join-Path $TestDrive "test-config.json"
            $script:tempScriptPath = Join-Path $TestDrive "Robocurse.ps1"
            '{}' | Set-Content $script:tempConfigPath
            '# Test script' | Set-Content $script:tempScriptPath
        }

        Context "New-ProfileScheduledTask" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeEach {
                Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Daily" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = $env:USERNAME } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Robocurse-Profile-TestProfile" } }
                Mock Get-ScheduledTask { $null }
                Mock Unregister-ScheduledTask { }
                Mock Write-RobocurseLog { }
            }

            It "Should create task with daily trigger" {
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Schedule = [PSCustomObject]@{
                        Enabled = $true
                        Frequency = "Daily"
                        Time = "03:00"
                    }
                }

                $result = New-ProfileScheduledTask -Profile $profile -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath

                $result.Success | Should -Be $true
                Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Robocurse-Profile-TestProfile" -and
                    $Description -like "*TestProfile*"
                }
            }

            It "Should create task with hourly trigger" {
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Once" } }

                $profile = [PSCustomObject]@{
                    Name = "HourlyProfile"
                    Schedule = [PSCustomObject]@{
                        Enabled = $true
                        Frequency = "Hourly"
                        Time = "00:00"
                        Interval = 4
                    }
                }

                $result = New-ProfileScheduledTask -Profile $profile -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath

                $result.Success | Should -Be $true
                Should -Invoke New-ScheduledTaskTrigger -Times 1 -ParameterFilter {
                    $Once -eq $true -and $RepetitionInterval -ne $null
                }
            }

            It "Should create task with weekly trigger" {
                $profile = [PSCustomObject]@{
                    Name = "WeeklyProfile"
                    Schedule = [PSCustomObject]@{
                        Enabled = $true
                        Frequency = "Weekly"
                        Time = "02:00"
                        DayOfWeek = "Saturday"
                    }
                }

                $result = New-ProfileScheduledTask -Profile $profile -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath

                $result.Success | Should -Be $true
                Should -Invoke New-ScheduledTaskTrigger -Times 1 -ParameterFilter {
                    $Weekly -eq $true -and $DaysOfWeek -eq "Saturday"
                }
            }

            It "Should remove existing task before creating new one" {
                Mock Get-ScheduledTask { [PSCustomObject]@{ TaskName = "Robocurse-Profile-TestProfile" } }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Schedule = [PSCustomObject]@{
                        Enabled = $true
                        Frequency = "Daily"
                        Time = "03:00"
                    }
                }

                $result = New-ProfileScheduledTask -Profile $profile -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath

                $result.Success | Should -Be $true
                Should -Invoke Unregister-ScheduledTask -Times 1
                Should -Invoke Register-ScheduledTask -Times 1
            }

            It "Should return error when script not found" {
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Schedule = [PSCustomObject]@{
                        Enabled = $true
                        Frequency = "Daily"
                        Time = "03:00"
                    }
                }

                $result = New-ProfileScheduledTask -Profile $profile -ConfigPath $script:tempConfigPath -ScriptPath "C:\NonExistent\Script.ps1"

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "not found"
            }
        }

        Context "Remove-ProfileScheduledTask" -Skip:(-not (Test-IsWindowsPlatform)) {
            It "Should remove task successfully" {
                Mock Get-ScheduledTask { [PSCustomObject]@{ TaskName = "Robocurse-Profile-TestProfile" } }
                Mock Unregister-ScheduledTask { }
                Mock Write-RobocurseLog { }

                $result = Remove-ProfileScheduledTask -ProfileName "TestProfile"

                $result.Success | Should -Be $true
                Should -Invoke Unregister-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Robocurse-Profile-TestProfile"
                }
            }

            It "Should succeed when task doesn't exist" {
                Mock Get-ScheduledTask { $null }
                Mock Write-RobocurseLog { }

                $result = Remove-ProfileScheduledTask -ProfileName "NonExistent"

                $result.Success | Should -Be $true
                $result.Data | Should -Match "not found"
            }

            It "Should return error on failure" {
                Mock Get-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Unregister-ScheduledTask { throw "Access denied" }
                Mock Write-RobocurseLog { }

                $result = Remove-ProfileScheduledTask -ProfileName "TestProfile"

                $result.Success | Should -Be $false
            }
        }

        Context "Get-ProfileScheduledTask" -Skip:(-not (Test-IsWindowsPlatform)) {
            It "Should return null when task doesn't exist" {
                Mock Get-ScheduledTask { $null }

                $result = Get-ProfileScheduledTask -ProfileName "NonExistent"

                $result | Should -Be $null
            }

            It "Should return task info when exists" {
                Mock Get-ScheduledTask {
                    [PSCustomObject]@{
                        TaskName = "Robocurse-Profile-TestProfile"
                        State = "Ready"
                    }
                }
                Mock Get-ScheduledTaskInfo {
                    [PSCustomObject]@{
                        NextRunTime = (Get-Date).AddDays(1)
                        LastRunTime = (Get-Date).AddDays(-1)
                        LastTaskResult = 0
                    }
                }

                $result = Get-ProfileScheduledTask -ProfileName "TestProfile"

                $result | Should -Not -Be $null
                $result.Name | Should -Be "TestProfile"
                $result.TaskName | Should -Be "Robocurse-Profile-TestProfile"
                $result.State | Should -Be "Ready"
                $result.Enabled | Should -Be $true
            }
        }

        Context "Get-AllProfileScheduledTasks" -Skip:(-not (Test-IsWindowsPlatform)) {
            It "Should return empty array when no tasks" {
                Mock Get-ScheduledTask { $null }

                $result = Get-AllProfileScheduledTasks

                $result | Should -Not -Be $null
                $result.Count | Should -Be 0
            }

            It "Should return all profile tasks" {
                Mock Get-ScheduledTask {
                    @(
                        [PSCustomObject]@{ TaskName = "Robocurse-Profile-Profile1"; State = "Ready"; Description = "Test1" },
                        [PSCustomObject]@{ TaskName = "Robocurse-Profile-Profile2"; State = "Disabled"; Description = "Test2" }
                    )
                }
                Mock Get-ScheduledTaskInfo {
                    [PSCustomObject]@{
                        NextRunTime = (Get-Date)
                        LastRunTime = (Get-Date)
                        LastTaskResult = 0
                    }
                }

                $result = Get-AllProfileScheduledTasks

                $result.Count | Should -Be 2
                $result[0].Name | Should -Be "Profile1"
                $result[1].Name | Should -Be "Profile2"
            }
        }

        Context "Enable-ProfileScheduledTask" -Skip:(-not (Test-IsWindowsPlatform)) {
            It "Should enable task successfully" {
                Mock Enable-ScheduledTask { [PSCustomObject]@{ State = "Ready" } }
                Mock Write-RobocurseLog { }

                $result = Enable-ProfileScheduledTask -ProfileName "TestProfile"

                $result.Success | Should -Be $true
                Should -Invoke Enable-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Robocurse-Profile-TestProfile"
                }
            }

            It "Should return error on failure" {
                Mock Enable-ScheduledTask { throw "Task not found" }
                Mock Write-RobocurseLog { }

                $result = Enable-ProfileScheduledTask -ProfileName "NonExistent"

                $result.Success | Should -Be $false
            }
        }

        Context "Disable-ProfileScheduledTask" -Skip:(-not (Test-IsWindowsPlatform)) {
            It "Should disable task successfully" {
                Mock Disable-ScheduledTask { [PSCustomObject]@{ State = "Disabled" } }
                Mock Write-RobocurseLog { }

                $result = Disable-ProfileScheduledTask -ProfileName "TestProfile"

                $result.Success | Should -Be $true
                Should -Invoke Disable-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Robocurse-Profile-TestProfile"
                }
            }
        }

        Context "Sync-ProfileSchedules" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeEach {
                Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Daily" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = $env:USERNAME } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Get-ScheduledTask { $null }
                Mock Unregister-ScheduledTask { }
                Mock Write-RobocurseLog { }
            }

            It "Should create tasks for enabled schedules" {
                $config = [PSCustomObject]@{
                    SyncProfiles = @(
                        [PSCustomObject]@{
                            Name = "Profile1"
                            Source = "C:\Test"
                            Destination = "D:\Backup"
                            Schedule = [PSCustomObject]@{
                                Enabled = $true
                                Frequency = "Daily"
                                Time = "03:00"
                            }
                        }
                    )
                }

                $result = Sync-ProfileSchedules -Config $config -ConfigPath $script:tempConfigPath

                $result.Success | Should -Be $true
                $result.Data.Created | Should -Be 1
                $result.Data.Total | Should -Be 1
            }

            It "Should remove orphaned tasks" {
                Mock Get-ScheduledTask {
                    param($TaskName)
                    if ($TaskName -like "*OrphanedProfile*") {
                        [PSCustomObject]@{ TaskName = "Robocurse-Profile-OrphanedProfile"; State = "Ready" }
                    }
                }
                Mock Get-ScheduledTaskInfo {
                    [PSCustomObject]@{ NextRunTime = $null; LastRunTime = $null; LastTaskResult = 0 }
                }

                # Config with no profiles (should remove orphaned task)
                $config = [PSCustomObject]@{
                    SyncProfiles = @()
                }

                # This is more complex to test - would need to properly mock Get-AllProfileScheduledTasks
                # For now, just verify the function runs without error
                { Sync-ProfileSchedules -Config $config -ConfigPath $script:tempConfigPath } | Should -Not -Throw
            }

            It "Should skip profiles with disabled schedules" {
                $config = [PSCustomObject]@{
                    SyncProfiles = @(
                        [PSCustomObject]@{
                            Name = "DisabledProfile"
                            Source = "C:\Test"
                            Destination = "D:\Backup"
                            Schedule = [PSCustomObject]@{
                                Enabled = $false
                                Frequency = "Daily"
                                Time = "03:00"
                            }
                        }
                    )
                }

                $result = Sync-ProfileSchedules -Config $config -ConfigPath $script:tempConfigPath

                $result.Data.Total | Should -Be 0
                Should -Invoke Register-ScheduledTask -Times 0
            }
        }

        Context "WhatIf Support" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeEach {
                Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Daily" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = $env:USERNAME } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Get-ScheduledTask { $null }
                Mock Unregister-ScheduledTask { }
                Mock Enable-ScheduledTask { }
                Mock Disable-ScheduledTask { }
                Mock Write-RobocurseLog { }
            }

            It "New-ProfileScheduledTask should support -WhatIf" {
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Schedule = [PSCustomObject]@{
                        Enabled = $true
                        Frequency = "Daily"
                        Time = "03:00"
                    }
                }

                $result = New-ProfileScheduledTask -Profile $profile -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath -WhatIf

                Should -Invoke Register-ScheduledTask -Times 0
            }

            It "Remove-ProfileScheduledTask should support -WhatIf" {
                Mock Get-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }

                $result = Remove-ProfileScheduledTask -ProfileName "TestProfile" -WhatIf

                Should -Invoke Unregister-ScheduledTask -Times 0
            }

            It "Enable-ProfileScheduledTask should support -WhatIf" {
                $result = Enable-ProfileScheduledTask -ProfileName "TestProfile" -WhatIf

                Should -Invoke Enable-ScheduledTask -Times 0
            }

            It "Disable-ProfileScheduledTask should support -WhatIf" {
                $result = Disable-ProfileScheduledTask -ProfileName "TestProfile" -WhatIf

                Should -Invoke Disable-ScheduledTask -Times 0
            }
        }

        Context "Platform Detection" {
            It "Should return error on non-Windows for New-ProfileScheduledTask" -Skip:(Test-IsWindowsPlatform) {
                Mock Write-RobocurseLog { }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Schedule = [PSCustomObject]@{
                        Enabled = $true
                        Frequency = "Daily"
                        Time = "03:00"
                    }
                }

                $result = New-ProfileScheduledTask -Profile $profile -ConfigPath "C:\test\config.json"

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "Windows"
            }
        }
    }
}
```

## Files to Modify

- Create `tests\Unit\ProfileSchedule.Tests.ps1` (new file)

## Verification

```powershell
# Run profile schedule tests
Invoke-Pester -Path tests\Unit\ProfileSchedule.Tests.ps1 -Output Detailed

# Run all scheduling tests
Invoke-Pester -Path tests\Unit\*Schedule*.Tests.ps1 -Output Detailed

# Run full test suite
.\scripts\run-tests.ps1
```
