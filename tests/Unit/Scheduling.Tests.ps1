#Requires -Modules Pester

# NOTE: These tests are designed to run on Windows where ScheduledTask cmdlets are available.
# When running on non-Windows platforms, stub functions are created but many tests will fail
# because the actual implementation detects the platform and returns early.
# This is expected behavior - the tests document the correct Windows behavior.

# Mock ScheduledTask cmdlets before loading the module - these are only available on Windows
if (-not (Get-Command New-ScheduledTaskAction -ErrorAction SilentlyContinue)) {
    function global:New-ScheduledTaskAction { }
    function global:New-ScheduledTaskTrigger { }
    function global:New-ScheduledTaskPrincipal { }
    function global:New-ScheduledTaskSettingsSet { }
    function global:Register-ScheduledTask { }
    function global:Unregister-ScheduledTask { }
    function global:Get-ScheduledTask { }
    function global:Get-ScheduledTaskInfo { }
    function global:Start-ScheduledTask { }
    function global:Enable-ScheduledTask { }
    function global:Disable-ScheduledTask { }
}

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

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

            It "Should throw when ConfigPath does not exist" -Skip:(-not $IsWindows) {
                # Skip on non-Windows as the function returns early before validation
                {
                    Register-RobocurseTask -ConfigPath "C:\NonExistent\Path\config.json"
                } | Should -Throw "*does not exist*"
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
        }

        Context "Register-RobocurseTask" -Skip:(-not $IsWindows) {
            It "Should create task with daily trigger" {
                Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Daily" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = "TestUser" } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Write-RobocurseLog { }

                $result = Register-RobocurseTask -ConfigPath "C:\test\config.json" -Schedule "Daily" -Time "03:00"

                $result.Success | Should -Be $true
                Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Robocurse-Replication" -and
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

                $result = Register-RobocurseTask -ConfigPath "C:\test\config.json" -Schedule "Weekly" -DaysOfWeek @('Monday', 'Friday')

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

                $result = Register-RobocurseTask -ConfigPath "C:\test\config.json" -Schedule "Hourly" -Time "10:00"

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

                $result = Register-RobocurseTask -ConfigPath "C:\test\config.json" -RunAsSystem

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

                $result = Register-RobocurseTask -ConfigPath "C:\test\config.json"

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

                $result = Register-RobocurseTask -ConfigPath "C:\test\config.json"

                Should -Invoke New-ScheduledTaskAction -Times 1 -ParameterFilter {
                    $Execute -eq "powershell.exe" -and
                    $Argument -match "-NoProfile" -and
                    $Argument -match "-ExecutionPolicy Bypass" -and
                    $Argument -match "-Headless" -and
                    $Argument -match "-ConfigPath"
                }
            }

            It "Should return false on error" {
                Mock New-ScheduledTaskAction { throw "Mock error" }
                Mock Write-RobocurseLog { }

                $result = Register-RobocurseTask -ConfigPath "C:\test\config.json"

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

                $result = Register-RobocurseTask -TaskName "Custom-Task" -ConfigPath "C:\test\config.json"

                $result.Success | Should -Be $true
                Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Custom-Task"
                }
            }
        }

        Context "Unregister-RobocurseTask" -Skip:(-not $IsWindows) {
            It "Should remove task successfully" {
                Mock Unregister-ScheduledTask { }
                Mock Write-RobocurseLog { }

                $result = Unregister-RobocurseTask

                $result.Success | Should -Be $true
                Should -Invoke Unregister-ScheduledTask -Times 1 -ParameterFilter {
                    $TaskName -eq "Robocurse-Replication" -and
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

                $result = Unregister-RobocurseTask

                $result.Success | Should -Be $false
                Should -Invoke Write-RobocurseLog -Times 1 -ParameterFilter {
                    $Level -eq "Error"
                }
            }
        }

        Context "Get-RobocurseTask" {
            It "Should return null when task doesn't exist" {
                Mock Get-ScheduledTask { throw "Task not found" }

                $result = Get-RobocurseTask -TaskName "NonExistent"

                $result | Should -Be $null
            }

            It "Should return task info when exists" -Skip:(-not $IsWindows) {
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

            It "Should parse trigger information" -Skip:(-not $IsWindows) {
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
                $result.Triggers.Count | Should -Be 1
                $result.Triggers[0].Type | Should -Be "Weekly"
                $result.Triggers[0].Enabled | Should -Be $true
            }

            It "Should handle multiple triggers" -Skip:(-not $IsWindows) {
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

        Context "Start-RobocurseTask" -Skip:(-not $IsWindows) {
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

        Context "Enable-RobocurseTask" -Skip:(-not $IsWindows) {
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

        Context "Disable-RobocurseTask" -Skip:(-not $IsWindows) {
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
            It "Should return true when task exists" -Skip:(-not $IsWindows) {
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

            It "Should check custom task name" -Skip:(-not $IsWindows) {
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

        Context "WhatIf Support" -Skip:(-not $IsWindows) {
            BeforeEach {
                $script:tempConfigPath = "$TestDrive/test-config.json"
                '{}' | Set-Content $script:tempConfigPath
            }

            It "Register-RobocurseTask should support -WhatIf" {
                Mock New-ScheduledTaskAction { [PSCustomObject]@{ Execute = "powershell.exe" } }
                Mock New-ScheduledTaskTrigger { [PSCustomObject]@{ Type = "Daily" } }
                Mock New-ScheduledTaskPrincipal { [PSCustomObject]@{ UserId = "TestUser" } }
                Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ } }
                Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = "Test" } }
                Mock Write-RobocurseLog { }

                $result = Register-RobocurseTask -ConfigPath $script:tempConfigPath -WhatIf

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
        }

        Context "Platform Detection" {
            It "Should handle non-Windows platform gracefully for Register" {
                # On non-Windows platforms, functions should return false without trying to execute
                if (-not $IsWindows) {
                    Mock Write-RobocurseLog { }

                    $result = Register-RobocurseTask -ConfigPath "C:\test\config.json"

                    $result.Success | Should -Be $false
                    Should -Invoke Write-RobocurseLog -Times 1 -ParameterFilter {
                        $Level -eq "Warning" -and
                        $Message -match "Windows"
                    }
                }
            }

            It "Should handle non-Windows platform gracefully for Unregister" {
                if (-not $IsWindows) {
                    Mock Write-RobocurseLog { }

                    $result = Unregister-RobocurseTask

                    $result.Success | Should -Be $false
                }
            }

            It "Should return null on non-Windows for Get-RobocurseTask" {
                if (-not $IsWindows) {
                    $result = Get-RobocurseTask

                    $result | Should -Be $null
                }
            }
        }
    }
}
