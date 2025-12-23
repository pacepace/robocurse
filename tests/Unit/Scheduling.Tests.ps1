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
function global:Register-ScheduledTask { param($TaskName, $Action, $Trigger, $Principal, $Settings, $Description, [switch]$Force, $User, $Password) }
function global:Unregister-ScheduledTask { param($TaskName, [switch]$Confirm) }
function global:Get-ScheduledTask { param($TaskName) }
function global:Get-ScheduledTaskInfo { param($TaskName) }
function global:Start-ScheduledTask { param($TaskName) }
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
    Describe "Scheduling" {
        Context "Register-RobocurseTask Validation" {
            BeforeEach {
                # Create a temporary config file for testing
                $script:tempConfigPath = "$TestDrive/test-config.json"
                '{}' | Set-Content $script:tempConfigPath
            }

            It "Should throw when ConfigPath is null or empty" {
                {
                    Register-RobocurseTask -ConfigPath ""
                } | Should -Throw
            }

            It "Should throw when ConfigPath does not exist" -Skip:(-not (Test-IsWindowsPlatform)) {
                # Skip on non-Windows as the function returns early before validation
                $result = Register-RobocurseTask -ConfigPath "C:\NonExistent\Path\config.json"
                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "does not exist"
            }

            It "Should throw when Time format is invalid" {
                {
                    Register-RobocurseTask -ConfigPath $script:tempConfigPath -Time "25:00"
                } | Should -Throw
            }

            It "Should throw when Time format is invalid (no colon)" {
                {
                    Register-RobocurseTask -ConfigPath $script:tempConfigPath -Time "0300"
                } | Should -Throw
            }

            It "Should accept valid Time format HH:mm" {
                Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Daily" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = "TestUser" } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Write-RobocurseLog { }

                {
                    Register-RobocurseTask -ConfigPath $script:tempConfigPath -Time "14:30"
                } | Should -Not -Throw
            }

            # Note: Testing null script path is difficult because $PSCommandPath and
            # $MyInvocation.MyCommand.Path are automatic variables set by PowerShell.
            # The validation exists to handle edge cases like running from memory or
            # interactive sessions. Manual testing verified the error path works.

            It "Should accept explicit ScriptPath parameter" -Skip:(-not (Test-IsWindowsPlatform)) {
                Mock New-ScheduledTaskAction {
                    param($Execute, $Argument)
                    [PSCustomObject]@{
                        Execute = $Execute
                        Argument = $Argument
                    }
                }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Daily" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = "TestUser" } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Write-RobocurseLog { }

                # Create a temp script file to use as ScriptPath
                $tempScript = Join-Path $TestDrive "Robocurse.ps1"
                '# Test script' | Set-Content $tempScript

                $result = Register-RobocurseTask -ConfigPath $script:tempConfigPath -ScriptPath $tempScript -Confirm:$false

                $result.Success | Should -Be $true
                # Use a looser match since path may have different separators
                Should -Invoke New-ScheduledTaskAction -Times 1 -ParameterFilter {
                    $Argument -match "Robocurse\.ps1"
                }
            }

            It "Should throw when ScriptPath does not exist" {
                {
                    Register-RobocurseTask -ConfigPath $script:tempConfigPath -ScriptPath "C:\NonExistent\Script.ps1"
                } | Should -Throw "*does not exist*"
            }
        }

        Context "Register-RobocurseTask" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeEach {
                # Create test config and script files
                $script:tempConfigPath = Join-Path $TestDrive "test-config.json"
                $script:tempScriptPath = Join-Path $TestDrive "Robocurse.ps1"
                '{}' | Set-Content $script:tempConfigPath
                '# Test script' | Set-Content $script:tempScriptPath
            }

            It "Should create task with daily trigger" {
                Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Daily" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = "TestUser" } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Write-RobocurseLog { }

                $result = Register-RobocurseTask -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath -Schedule "Daily" -Time "03:00" -Confirm:$false

                $result.Success | Should -Be $true
                # TaskName is now auto-generated from config path hash (e.g., "Robocurse-A1B2C3D4")
                Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -like "Robocurse-*" -and
                    $Description -eq "Robocurse automatic directory replication"
                }
            }

            It "Should create task with weekly trigger" {
                Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Weekly" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = "TestUser" } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Write-RobocurseLog { }

                $result = Register-RobocurseTask -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath -Schedule "Weekly" -DaysOfWeek @('Monday', 'Friday') -Confirm:$false

                $result.Success | Should -Be $true
                Should -Invoke New-ScheduledTaskTrigger -Times 1 -ParameterFilter {
                    $Weekly -eq $true -and
                    $DaysOfWeek -contains 'Monday' -and
                    $DaysOfWeek -contains 'Friday'
                }
            }

            It "Should create task with hourly trigger" {
                Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Once" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = "TestUser" } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Write-RobocurseLog { }

                $result = Register-RobocurseTask -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath -Schedule "Hourly" -Time "10:00" -Confirm:$false

                $result.Success | Should -Be $true
                Should -Invoke New-ScheduledTaskTrigger -Times 1 -ParameterFilter {
                    $Once -eq $true -and
                    $RepetitionInterval -ne $null
                }
            }

            It "Should use SYSTEM principal when RunAsSystem specified" {
                Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Daily" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = "SYSTEM" } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Write-RobocurseLog { }

                $result = Register-RobocurseTask -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath -RunAsSystem -Confirm:$false

                $result.Success | Should -Be $true
                Should -Invoke New-ScheduledTaskPrincipal -Times 1 -ParameterFilter {
                    $UserId -eq "SYSTEM" -and
                    $LogonType -eq "ServiceAccount"
                }
            }

            It "Should use current user principal when RunAsSystem not specified" {
                Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Daily" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = $env:USERNAME } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Write-RobocurseLog { }

                $result = Register-RobocurseTask -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath -Confirm:$false

                $result.Success | Should -Be $true
                Should -Invoke New-ScheduledTaskPrincipal -Times 1 -ParameterFilter {
                    $UserId -eq $env:USERNAME -and
                    $LogonType -eq "S4U"
                }
            }

            It "Should build correct PowerShell arguments" {
                Mock New-ScheduledTaskAction {
                    param($Execute, $Argument)
                    [PSCustomObject]@{
                        Execute = $Execute
                        Argument = $Argument
                    }
                }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Daily" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = "TestUser" } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Write-RobocurseLog { }

                $result = Register-RobocurseTask -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath -Confirm:$false

                Should -Invoke New-ScheduledTaskAction -Times 1 -ParameterFilter {
                    $Execute -eq "powershell.exe" -and
                    $Argument -match "-NoProfile" -and
                    $Argument -match "-ExecutionPolicy Bypass" -and
                    $Argument -match "-ConfigPath"
                }
            }

            It "Should return false on error" {
                Mock New-ScheduledTaskAction { throw "Mock error" }
                Mock Write-RobocurseLog { }

                $result = Register-RobocurseTask -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath -Confirm:$false

                $result.Success | Should -Be $false
                Should -Invoke Write-RobocurseLog -Times 1 -ParameterFilter {
                    $Level -eq "Error" -and
                    $Component -eq "Scheduler"
                }
            }

            It "Should accept custom task name" {
                Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Daily" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = "TestUser" } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Custom-Task" } }
                Mock Write-RobocurseLog { }

                $result = Register-RobocurseTask -TaskName "Custom-Task" -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath -Confirm:$false

                $result.Success | Should -Be $true
                Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Custom-Task"
                }
            }
        }

        Context "Unregister-RobocurseTask" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeEach {
                # Create test config file for deriving task name
                $script:tempConfigPath = Join-Path $TestDrive "unregister-test-config.json"
                '{}' | Set-Content $script:tempConfigPath
            }

            It "Should remove task successfully" {
                Mock Unregister-ScheduledTask { }
                Mock Write-RobocurseLog { }

                # Use explicit TaskName since ConfigPath derivation is tested separately
                $result = Unregister-RobocurseTask -TaskName "Test-Task"

                $result.Success | Should -Be $true
                Should -Invoke Unregister-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Test-Task" -and
                    $Confirm -eq $false
                }
            }

            It "Should remove custom task name" {
                Mock Unregister-ScheduledTask { }
                Mock Write-RobocurseLog { }

                $result = Unregister-RobocurseTask -TaskName "Custom-Task"

                $result.Success | Should -Be $true
                Should -Invoke Unregister-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Custom-Task"
                }
            }

            It "Should return false on error" {
                Mock Unregister-ScheduledTask { throw "Task not found" }
                Mock Write-RobocurseLog { }

                $result = Unregister-RobocurseTask -TaskName "Failing-Task"

                $result.Success | Should -Be $false
                Should -Invoke Write-RobocurseLog -Times 1 -ParameterFilter {
                    $Level -eq "Error"
                }
            }

            It "Should derive task name from ConfigPath" {
                Mock Unregister-ScheduledTask { }
                Mock Write-RobocurseLog { }

                $result = Unregister-RobocurseTask -ConfigPath $script:tempConfigPath

                $result.Success | Should -Be $true
                # Task name should be auto-derived from config path
                Should -Invoke Unregister-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -like "Robocurse-*"
                }
            }

            It "Should return error when neither TaskName nor ConfigPath provided" {
                $result = Unregister-RobocurseTask

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -BeLike "*Either TaskName or ConfigPath must be specified*"
            }
        }

        Context "Get-RobocurseTask" {
            It "Should return null when task doesn't exist" {
                Mock Get-ScheduledTask { throw "Task not found" }

                $result = Get-RobocurseTask -TaskName "NonExistent"

                $result | Should -Be $null
            }

            It "Should return task info when exists" -Skip:(-not (Test-IsWindowsPlatform)) {
                Mock Get-ScheduledTask {
                    [PSCustomObject]@{
                        TaskName = "Robocurse-Replication"
                        State = "Ready"
                        Triggers = @(
                            [PSCustomObject]@{
                                Enabled = $true
                                CimClass = [PSCustomObject]@{
                                    CimClassName = "MSFT_TaskDailyTrigger"
                                }
                            }
                        )
                    }
                }
                Mock Get-ScheduledTaskInfo {
                    [PSCustomObject]@{
                        NextRunTime = (Get-Date).AddDays(1)
                        LastRunTime = (Get-Date).AddDays(-1)
                        LastTaskResult = 0
                    }
                }

                $result = Get-RobocurseTask

                $result | Should -Not -Be $null
                $result.Name | Should -Be "Robocurse-Replication"
                $result.State | Should -Be "Ready"
                $result.Enabled | Should -Be $true
                $result.NextRunTime | Should -Not -Be $null
                $result.LastRunTime | Should -Not -Be $null
                $result.LastResult | Should -Be 0
            }

            It "Should parse trigger information" -Skip:(-not (Test-IsWindowsPlatform)) {
                Mock Get-ScheduledTask {
                    [PSCustomObject]@{
                        TaskName = "Test-Task"
                        State = "Disabled"
                        Triggers = @(
                            [PSCustomObject]@{
                                Enabled = $true
                                CimClass = [PSCustomObject]@{
                                    CimClassName = "MSFT_TaskWeeklyTrigger"
                                }
                            }
                        )
                    }
                }
                Mock Get-ScheduledTaskInfo {
                    [PSCustomObject]@{
                        NextRunTime = $null
                        LastRunTime = $null
                        LastTaskResult = 267011
                    }
                }

                $result = Get-RobocurseTask -TaskName "Test-Task"

                $result | Should -Not -Be $null
                $result.State | Should -Be "Disabled"
                $result.Enabled | Should -Be $false
                # Check the triggers array - wrap in @() for PS 5.1 compatibility
                @($result.Triggers).Count | Should -Be 1
                $result.Triggers[0].Type | Should -Be "Weekly"
                $result.Triggers[0].Enabled | Should -Be $true
            }

            It "Should handle multiple triggers" -Skip:(-not (Test-IsWindowsPlatform)) {
                Mock Get-ScheduledTask {
                    [PSCustomObject]@{
                        TaskName = "Multi-Trigger"
                        State = "Ready"
                        Triggers = @(
                            [PSCustomObject]@{
                                Enabled = $true
                                CimClass = [PSCustomObject]@{
                                    CimClassName = "MSFT_TaskDailyTrigger"
                                }
                            },
                            [PSCustomObject]@{
                                Enabled = $false
                                CimClass = [PSCustomObject]@{
                                    CimClassName = "MSFT_TaskWeeklyTrigger"
                                }
                            }
                        )
                    }
                }
                Mock Get-ScheduledTaskInfo {
                    [PSCustomObject]@{
                        NextRunTime = (Get-Date)
                        LastRunTime = (Get-Date)
                        LastTaskResult = 0
                    }
                }

                $result = Get-RobocurseTask -TaskName "Multi-Trigger"

                $result.Triggers.Count | Should -Be 2
                $result.Triggers[0].Type | Should -Be "Daily"
                $result.Triggers[1].Type | Should -Be "Weekly"
                $result.Triggers[0].Enabled | Should -Be $true
                $result.Triggers[1].Enabled | Should -Be $false
            }
        }

        Context "Start-RobocurseTask" -Skip:(-not (Test-IsWindowsPlatform)) {
            It "Should start task successfully" {
                Mock Start-ScheduledTask { }
                Mock Write-RobocurseLog { }

                $result = Start-RobocurseTask

                $result.Success | Should -Be $true
                Should -Invoke Start-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Robocurse-Replication"
                }
            }

            It "Should start custom task name" {
                Mock Start-ScheduledTask { }
                Mock Write-RobocurseLog { }

                $result = Start-RobocurseTask -TaskName "Custom-Task"

                $result.Success | Should -Be $true
                Should -Invoke Start-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Custom-Task"
                }
            }

            It "Should return false on error" {
                Mock Start-ScheduledTask { throw "Task not found" }
                Mock Write-RobocurseLog { }

                $result = Start-RobocurseTask

                $result.Success | Should -Be $false
            }
        }

        Context "Enable-RobocurseTask" -Skip:(-not (Test-IsWindowsPlatform)) {
            It "Should enable task successfully" {
                Mock Enable-ScheduledTask { [PSCustomObject]@{ State = "Ready" } }
                Mock Write-RobocurseLog { }

                $result = Enable-RobocurseTask

                $result.Success | Should -Be $true
                Should -Invoke Enable-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Robocurse-Replication"
                }
            }

            It "Should enable custom task name" {
                Mock Enable-ScheduledTask { [PSCustomObject]@{ State = "Ready" } }
                Mock Write-RobocurseLog { }

                $result = Enable-RobocurseTask -TaskName "Custom-Task"

                $result.Success | Should -Be $true
                Should -Invoke Enable-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Custom-Task"
                }
            }

            It "Should return false on error" {
                Mock Enable-ScheduledTask { throw "Task not found" }
                Mock Write-RobocurseLog { }

                $result = Enable-RobocurseTask

                $result.Success | Should -Be $false
            }
        }

        Context "Disable-RobocurseTask" -Skip:(-not (Test-IsWindowsPlatform)) {
            It "Should disable task successfully" {
                Mock Disable-ScheduledTask { [PSCustomObject]@{ State = "Disabled" } }
                Mock Write-RobocurseLog { }

                $result = Disable-RobocurseTask

                $result.Success | Should -Be $true
                Should -Invoke Disable-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Robocurse-Replication"
                }
            }

            It "Should disable custom task name" {
                Mock Disable-ScheduledTask { [PSCustomObject]@{ State = "Disabled" } }
                Mock Write-RobocurseLog { }

                $result = Disable-RobocurseTask -TaskName "Custom-Task"

                $result.Success | Should -Be $true
                Should -Invoke Disable-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Custom-Task"
                }
            }

            It "Should return false on error" {
                Mock Disable-ScheduledTask { throw "Task not found" }
                Mock Write-RobocurseLog { }

                $result = Disable-RobocurseTask

                $result.Success | Should -Be $false
            }
        }

        Context "Test-RobocurseTaskExists" {
            It "Should return true when task exists" -Skip:(-not (Test-IsWindowsPlatform)) {
                Mock Get-ScheduledTask {
                    [PSCustomObject]@{
                        TaskName = "Robocurse-Replication"
                    }
                }

                $result = Test-RobocurseTaskExists

                $result | Should -Be $true
            }

            It "Should return false when task doesn't exist" {
                Mock Get-ScheduledTask { throw "Task not found" }

                $result = Test-RobocurseTaskExists

                $result | Should -Be $false
            }

            It "Should check custom task name" -Skip:(-not (Test-IsWindowsPlatform)) {
                Mock Get-ScheduledTask {
                    param($TaskName)
                    if ($TaskName -eq "Custom-Task") {
                        [PSCustomObject]@{ TaskName = "Custom-Task" }
                    }
                    else {
                        throw "Task not found"
                    }
                }

                $result = Test-RobocurseTaskExists -TaskName "Custom-Task"
                $result | Should -Be $true

                $result = Test-RobocurseTaskExists -TaskName "Other-Task"
                $result | Should -Be $false
            }
        }

        Context "WhatIf Support" -Skip:(-not (Test-IsWindowsPlatform)) {
            BeforeEach {
                $script:tempConfigPath = Join-Path $TestDrive "test-config.json"
                $script:tempScriptPath = Join-Path $TestDrive "Robocurse.ps1"
                '{}' | Set-Content $script:tempConfigPath
                '# Test script' | Set-Content $script:tempScriptPath
            }

            It "Register-RobocurseTask should support -WhatIf" {
                Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Daily" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = "TestUser" } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Write-RobocurseLog { }

                $result = Register-RobocurseTask -ConfigPath $script:tempConfigPath -ScriptPath $script:tempScriptPath -WhatIf

                # Task should NOT be registered when using -WhatIf
                Should -Invoke Register-ScheduledTask -Times 0
                $result.Success | Should -Be $true
            }

            It "Unregister-RobocurseTask should support -WhatIf" {
                Mock Get-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Unregister-ScheduledTask { }
                Mock Write-RobocurseLog { }

                $result = Unregister-RobocurseTask -TaskName "Test-Task" -WhatIf

                # Task should NOT be unregistered when using -WhatIf
                Should -Invoke Unregister-ScheduledTask -Times 0
                $result.Success | Should -Be $true
            }

            It "Disable-RobocurseTask should support -WhatIf" {
                Mock Get-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Disable-ScheduledTask { }
                Mock Write-RobocurseLog { }

                $result = Disable-RobocurseTask -TaskName "Test-Task" -WhatIf

                # Task should NOT be disabled when using -WhatIf
                Should -Invoke Disable-ScheduledTask -Times 0
                $result.Success | Should -Be $true
            }

            It "Enable-RobocurseTask should support -WhatIf" {
                Mock Get-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Enable-ScheduledTask { [PSCustomObject]@{ State = "Ready" } }
                Mock Write-RobocurseLog { }

                $result = Enable-RobocurseTask -TaskName "Test-Task" -WhatIf

                # Task should NOT be enabled when using -WhatIf
                Should -Invoke Enable-ScheduledTask -Times 0
                $result.Success | Should -Be $true
            }

            It "Start-RobocurseTask should support -WhatIf" {
                Mock Get-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Start-ScheduledTask { }
                Mock Write-RobocurseLog { }

                $result = Start-RobocurseTask -TaskName "Test-Task" -WhatIf

                # Task should NOT be started when using -WhatIf
                Should -Invoke Start-ScheduledTask -Times 0
                $result.Success | Should -Be $true
            }
        }

        Context "Platform Detection" {
            # Note: These tests only run on non-Windows platforms (PowerShell Core on Linux/Mac)
            # On Windows (including PS 5.1 where $IsWindows is undefined), these are skipped
            # Use Test-IsWindowsPlatform for reliable cross-version detection

            It "Should handle non-Windows platform gracefully for Register" -Skip:(Test-IsWindowsPlatform) {
                # On non-Windows platforms, functions should return false without trying to execute
                Mock Write-RobocurseLog { }

                $result = Register-RobocurseTask -ConfigPath "C:\test\config.json"

                $result.Success | Should -Be $false
                Should -Invoke Write-RobocurseLog -Times 1 -ParameterFilter {
                    $Level -eq "Warning" -and
                    $Message -match "Windows"
                }
            }

            It "Should handle non-Windows platform gracefully for Unregister" -Skip:(Test-IsWindowsPlatform) {
                Mock Write-RobocurseLog { }

                $result = Unregister-RobocurseTask

                $result.Success | Should -Be $false
            }

            It "Should return null on non-Windows for Get-RobocurseTask" -Skip:(Test-IsWindowsPlatform) {
                $result = Get-RobocurseTask

                $result | Should -Be $null
            }
        }
    }
}
