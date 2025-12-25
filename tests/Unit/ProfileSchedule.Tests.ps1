#Requires -Modules Pester

# NOTE: These tests are designed to run on Windows where ScheduledTask cmdlets are available.
# When running on non-Windows platforms, stub functions are created but many tests will fail
# because the actual implementation detects the platform and returns early.
# This is expected behavior - the tests document the correct Windows behavior.

# IMPORTANT: On Windows, the ScheduledTasks module has CIM-based cmdlets that cannot be easily mocked
# because PowerShell validates parameter types BEFORE calling the function.
# We need to REMOVE the module and replace with stub functions that CAN be mocked.
if (Get-Module ScheduledTasks -ErrorAction SilentlyContinue) {
    Remove-Module ScheduledTasks -Force -ErrorAction SilentlyContinue
}

# Create stub functions that can be properly mocked
# These replace the real CIM cmdlets with simple PowerShell functions
# IMPORTANT: Parameters must match what the source code uses (including switch params)
function global:New-ScheduledTaskAction { param($Execute, $Argument, $WorkingDirectory) }
function global:New-ScheduledTaskTrigger { param([switch]$Daily, [switch]$Weekly, [switch]$Once, $At, $DaysOfWeek, $RepetitionInterval, $RepetitionDuration) }
function global:New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) }
function global:New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable, [switch]$RunOnlyIfNetworkAvailable, $MultipleInstances, $ExecutionTimeLimit, $Priority) }
function global:New-ScheduledTask { param($Action, $Trigger, $Settings, $Principal, $Description) }
function global:Register-ScheduledTask { param([Parameter(ValueFromPipeline)]$InputObject, $TaskName, $Action, $Trigger, $Principal, $Settings, $Description, [switch]$Force, $User, $Password, $RunLevel) }
function global:Unregister-ScheduledTask { param($TaskName, [switch]$Confirm) }
function global:Get-ScheduledTask { param($TaskName) }
function global:Get-ScheduledTaskInfo { param($TaskName) }
function global:Enable-ScheduledTask { param($TaskName) }
function global:Disable-ScheduledTask { param($TaskName) }

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type (required for module isolation when running all tests together)
Initialize-OrchestrationStateType | Out-Null

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
            BeforeAll {
                # Remove ScheduledTasks module if loaded by other tests to prevent stub conflicts
                if (Get-Module ScheduledTasks -ErrorAction SilentlyContinue) {
                    Remove-Module ScheduledTasks -Force -ErrorAction SilentlyContinue
                }
            }

            BeforeEach {
                Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Daily" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = $env:USERNAME } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock New-ScheduledTask { [PSCustomObject]@{ Actions = @(); Triggers = @(); Settings = @{} } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Robocurse-Profile-TestProfile"; Principal = [PSCustomObject]@{ UserId = $env:USERNAME; LogonType = 'Password' } } }
                Mock Get-ScheduledTask { $null }
                Mock Unregister-ScheduledTask { }
                Mock Write-RobocurseLog { }
                # Mock Save-NetworkCredential for tests that use credentials
                Mock Save-NetworkCredential { New-OperationResult -Success $true }
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

            It "Should return OperationResult with task name on success" {
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
                $result.Data | Should -Be "Robocurse-Profile-TestProfile"
            }

            It "Should use full domain\username format for principal UserId" {
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
                Should -Invoke New-ScheduledTaskPrincipal -Times 1 -ParameterFilter {
                    $UserId -match '\\'  # Must contain backslash (domain\user or computer\user)
                }
            }

            It "Should use S4U logon when no credential provided" {
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
                Should -Invoke New-ScheduledTaskPrincipal -Times 1 -ParameterFilter {
                    $LogonType -eq 'S4U'
                }
                Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                    $Principal -ne $null -and $User -eq $null
                }
            }

            It "Should use Password logon when credential provided" {
                $securePassword = ConvertTo-SecureString "TestPassword123" -AsPlainText -Force
                $credential = [System.Management.Automation.PSCredential]::new("DOMAIN\TestUser", $securePassword)

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Schedule = [PSCustomObject]@{
                        Enabled = $true
                        Frequency = "Daily"
                        Time = "03:00"
                    }
                }

                $result = New-ProfileScheduledTask -Profile $profile -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath -Credential $credential

                $result.Success | Should -Be $true
                # With credentials, we do NOT call New-ScheduledTaskPrincipal
                # Instead we use -User, -Password, -RunLevel directly on Register-ScheduledTask
                # (because -Principal and -User/-Password are mutually exclusive parameter sets)
                Should -Invoke New-ScheduledTaskPrincipal -Times 0
                # Register-ScheduledTask called with -User, -Password, -RunLevel
                Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                    $User -eq "DOMAIN\TestUser" -and $Password -eq "TestPassword123" -and $RunLevel -eq "Highest"
                }
            }
        }

        Context "Remove-ProfileScheduledTask" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeEach {
                Mock Write-RobocurseLog { }
            }

            It "Should remove task successfully" {
                Mock Get-ScheduledTask { [PSCustomObject]@{ TaskName = "Robocurse-Profile-TestProfile" } }
                Mock Unregister-ScheduledTask { }

                $result = Remove-ProfileScheduledTask -ProfileName "TestProfile"

                $result.Success | Should -Be $true
                Should -Invoke Unregister-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Robocurse-Profile-TestProfile"
                }
            }

            It "Should succeed when task doesn't exist" {
                Mock Get-ScheduledTask { $null }

                $result = Remove-ProfileScheduledTask -ProfileName "NonExistent"

                $result.Success | Should -Be $true
                $result.Data | Should -Match "not found"
            }

            It "Should return error on failure" {
                Mock Get-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Unregister-ScheduledTask { throw "Access denied" }

                $result = Remove-ProfileScheduledTask -ProfileName "TestProfile"

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "Access denied|Failed to remove"
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

            It "Should return Enabled=false when task state is Disabled" {
                Mock Get-ScheduledTask {
                    [PSCustomObject]@{
                        TaskName = "Robocurse-Profile-TestProfile"
                        State = "Disabled"
                    }
                }
                Mock Get-ScheduledTaskInfo {
                    [PSCustomObject]@{
                        NextRunTime = $null
                        LastRunTime = $null
                        LastTaskResult = 0
                    }
                }

                $result = Get-ProfileScheduledTask -ProfileName "TestProfile"

                $result.Enabled | Should -Be $false
            }
        }

        Context "Get-AllProfileScheduledTasks" -Skip:(-not (Test-IsWindowsPlatform)) {
            It "Should return empty array when no tasks" {
                Mock Get-ScheduledTask { $null }

                $result = @(Get-AllProfileScheduledTasks)

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

            It "Should strip task prefix from names" {
                Mock Get-ScheduledTask {
                    @(
                        [PSCustomObject]@{ TaskName = "Robocurse-Profile-MyBackupProfile"; State = "Ready"; Description = "Test" }
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

                $result[0].Name | Should -Be "MyBackupProfile"
                $result[0].TaskName | Should -Be "Robocurse-Profile-MyBackupProfile"
            }
        }

        Context "Enable-ProfileScheduledTask" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeEach {
                Mock Write-RobocurseLog { }
            }

            It "Should enable task successfully" {
                Mock Enable-ScheduledTask { [PSCustomObject]@{ State = "Ready" } }

                $result = Enable-ProfileScheduledTask -ProfileName "TestProfile"

                $result.Success | Should -Be $true
                Should -Invoke Enable-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Robocurse-Profile-TestProfile"
                }
            }

            It "Should return error on failure" {
                Mock Enable-ScheduledTask { throw "Task not found" }

                $result = Enable-ProfileScheduledTask -ProfileName "NonExistent"

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "Task not found"
            }
        }

        Context "Disable-ProfileScheduledTask" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeEach {
                Mock Write-RobocurseLog { }
            }

            It "Should disable task successfully" {
                Mock Disable-ScheduledTask { [PSCustomObject]@{ State = "Disabled" } }

                $result = Disable-ProfileScheduledTask -ProfileName "TestProfile"

                $result.Success | Should -Be $true
                Should -Invoke Disable-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Robocurse-Profile-TestProfile"
                }
            }

            It "Should return error on failure" {
                Mock Disable-ScheduledTask { throw "Access denied" }

                $result = Disable-ProfileScheduledTask -ProfileName "TestProfile"

                $result.Success | Should -Be $false
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
                # Mock Test-Path to return true for script path validation
                Mock Test-Path { $true }
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

            It "Should skip profiles without schedule property" {
                $config = [PSCustomObject]@{
                    SyncProfiles = @(
                        [PSCustomObject]@{
                            Name = "NoScheduleProfile"
                            Source = "C:\Test"
                            Destination = "D:\Backup"
                        }
                    )
                }

                $result = Sync-ProfileSchedules -Config $config -ConfigPath $script:tempConfigPath

                $result.Data.Total | Should -Be 0
                Should -Invoke Register-ScheduledTask -Times 0
            }

            It "Should handle multiple profiles with mixed schedules" {
                $config = [PSCustomObject]@{
                    SyncProfiles = @(
                        [PSCustomObject]@{
                            Name = "EnabledProfile"
                            Source = "C:\Test1"
                            Destination = "D:\Backup1"
                            Schedule = [PSCustomObject]@{
                                Enabled = $true
                                Frequency = "Daily"
                                Time = "03:00"
                            }
                        },
                        [PSCustomObject]@{
                            Name = "DisabledProfile"
                            Source = "C:\Test2"
                            Destination = "D:\Backup2"
                            Schedule = [PSCustomObject]@{
                                Enabled = $false
                                Frequency = "Weekly"
                                Time = "04:00"
                            }
                        },
                        [PSCustomObject]@{
                            Name = "NoScheduleProfile"
                            Source = "C:\Test3"
                            Destination = "D:\Backup3"
                        }
                    )
                }

                $result = Sync-ProfileSchedules -Config $config -ConfigPath $script:tempConfigPath

                $result.Data.Total | Should -Be 1
                Should -Invoke Register-ScheduledTask -Times 1
            }

            It "Should return errors in Data when task creation fails" {
                Mock Register-ScheduledTask { throw "Registration failed" }

                $config = [PSCustomObject]@{
                    SyncProfiles = @(
                        [PSCustomObject]@{
                            Name = "FailingProfile"
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

                $result.Success | Should -Be $false
                $result.Data.Errors.Count | Should -BeGreaterThan 0
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
