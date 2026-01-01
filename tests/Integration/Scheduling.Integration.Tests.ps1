#Requires -Modules Pester

<#
.SYNOPSIS
    Real Windows Task Scheduler integration tests for Robocurse

.DESCRIPTION
    These tests create actual scheduled tasks to verify the scheduling functions work correctly.
    Tests cover:
    - Creating daily, hourly, and weekly scheduled tasks
    - Profile scheduled task creation with correct properties
    - Enabling and disabling scheduled tasks
    - Task cleanup after tests

.NOTES
    - Requires Windows with Task Scheduler service running
    - Requires Administrator privileges
    - Uses unique task name prefix with GUID to avoid conflicts
    - All test tasks are cleaned up in AfterAll block
#>

BeforeDiscovery {
    # Check if we're on Windows with admin privileges
    $script:CanCreateTasks = $false
    $script:IsWindows = $env:OS -eq 'Windows_NT' -or $PSVersionTable.Platform -eq 'Win32NT' -or (-not $PSVersionTable.Platform)

    if ($script:IsWindows) {
        # Check admin privileges
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]$identity
        $script:IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

        if ($script:IsAdmin) {
            # Check Task Scheduler service
            try {
                $taskService = Get-Service -Name 'Schedule' -ErrorAction SilentlyContinue
                $script:CanCreateTasks = $taskService -and $taskService.Status -eq 'Running'
            }
            catch {
                $script:CanCreateTasks = $false
            }
        }
        else {
            Write-Warning "Scheduling integration tests require administrator privileges - tests will be skipped"
        }
    }
}

BeforeAll {
    # IMPORTANT: Ensure the REAL ScheduledTasks cmdlets are available for integration tests
    # The unit tests create global stub functions that would interfere with real task creation.
    # We need to remove any stubs and load the real module.
    #
    # Note: When running alongside unit tests, this affects the module state. The unit tests
    # should also restore their stubs in their own BeforeAll blocks to handle this.
    $scheduledTaskCmdlets = @(
        'New-ScheduledTaskAction',
        'New-ScheduledTaskTrigger',
        'New-ScheduledTaskPrincipal',
        'New-ScheduledTaskSettingsSet',
        'New-ScheduledTask',
        'Register-ScheduledTask',
        'Unregister-ScheduledTask',
        'Get-ScheduledTask',
        'Get-ScheduledTaskInfo',
        'Enable-ScheduledTask',
        'Disable-ScheduledTask'
    )

    # Check if stub functions exist (created by unit tests)
    $hasStubs = $scheduledTaskCmdlets | ForEach-Object {
        $null -ne (Get-Item -Path "function:global:$_" -ErrorAction SilentlyContinue)
    } | Where-Object { $_ } | Select-Object -First 1

    if ($hasStubs) {
        # Remove stub functions
        foreach ($cmdlet in $scheduledTaskCmdlets) {
            if (Get-Item -Path "function:global:$cmdlet" -ErrorAction SilentlyContinue) {
                Remove-Item -Path "function:global:$cmdlet" -Force -ErrorAction SilentlyContinue
            }
        }
        # Force reload the real ScheduledTasks module
        Import-Module ScheduledTasks -Force -ErrorAction SilentlyContinue
    }
    elseif (-not (Get-Module ScheduledTasks -ErrorAction SilentlyContinue)) {
        # Module not loaded, load it
        Import-Module ScheduledTasks -Force -ErrorAction SilentlyContinue
    }

    # Load test helper
    . "$PSScriptRoot\..\TestHelper.ps1"
    Initialize-RobocurseForTesting

    # Unique prefix for all test tasks - ensures no conflicts with existing tasks
    $script:TestTaskPrefix = "RobocurseTest_$([guid]::NewGuid().ToString('N').Substring(0,8))"

    # Track created tasks for cleanup
    $script:CreatedTasks = [System.Collections.Generic.List[string]]::new()

    # Create temp directories for config and script files
    $script:TempDir = Join-Path $env:TEMP "RobocurseScheduleTest_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    # Create a dummy Robocurse.ps1 script for task action
    $script:TempScriptPath = Join-Path $script:TempDir "Robocurse.ps1"
    '# Test Robocurse script for scheduling tests' | Set-Content $script:TempScriptPath

    # Create a dummy config file
    $script:TempConfigPath = Join-Path $script:TempDir "test-config.json"
    @{
        SyncProfiles = @()
        GlobalSettings = @{
            LogPath = $script:TempDir
        }
    } | ConvertTo-Json -Depth 10 | Set-Content $script:TempConfigPath

    # Helper function to register a task name for cleanup
    function Register-TestTaskForCleanup {
        param([string]$TaskName)
        if (-not $script:CreatedTasks.Contains($TaskName)) {
            $script:CreatedTasks.Add($TaskName)
        }
    }

    # Helper function to cleanup a specific task
    function Remove-TestTask {
        param([string]$TaskName)
        try {
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($task) {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
        catch {
            # Ignore cleanup errors
        }
    }

    # Clean up ANY orphaned test tasks from previous runs (different GUIDs)
    # This ensures we start with a clean slate regardless of previous test failures
    # Run unconditionally - if we can query tasks, we can delete them
    try {
        $orphanedTasks = Get-ScheduledTask -ErrorAction Stop |
            Where-Object { $_.TaskName -like 'RobocurseTest_*' -or $_.TaskName -like 'Robocurse-Profile-RobocurseTest_*' }

        $orphanCount = 0
        $failedCount = 0
        foreach ($task in $orphanedTasks) {
            try {
                Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
                $orphanCount++
            }
            catch {
                $failedCount++
            }
        }

        if ($orphanCount -gt 0) {
            Write-Warning "Cleaned up $orphanCount orphaned test task(s) from previous runs"
        }
        if ($failedCount -gt 0) {
            Write-Warning "Failed to clean up $failedCount orphaned test task(s) - may require elevated permissions"
        }
    }
    catch {
        Write-Warning "Could not query scheduled tasks for cleanup: $($_.Exception.Message)"
    }
}

AfterAll {
    # Cleanup ALL test tasks that were created during this run
    if ($script:CreatedTasks) {
        foreach ($taskName in $script:CreatedTasks) {
            Remove-TestTask -TaskName $taskName
        }
    }

    # Final cleanup: Remove ALL RobocurseTest tasks to ensure we leave no orphans
    # This catches any tasks that might have been created but not tracked
    # Run unconditionally - if we can query tasks, we can delete them
    try {
        $allTestTasks = Get-ScheduledTask -ErrorAction Stop |
            Where-Object { $_.TaskName -like 'RobocurseTest_*' -or $_.TaskName -like 'Robocurse-Profile-RobocurseTest_*' }

        $cleanedCount = 0
        $failedCount = 0
        foreach ($task in $allTestTasks) {
            try {
                Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
                $cleanedCount++
            }
            catch {
                $failedCount++
            }
        }

        if ($failedCount -gt 0) {
            Write-Warning "AfterAll: Failed to clean up $failedCount test task(s) - may require elevated permissions"
        }
    }
    catch {
        Write-Warning "AfterAll: Could not query scheduled tasks for cleanup: $($_.Exception.Message)"
    }

    # Cleanup temp directory
    if ($script:TempDir -and (Test-Path $script:TempDir)) {
        Remove-Item $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Scheduled Task Creation" -Tag "Integration", "Scheduling" -Skip:(-not $script:CanCreateTasks) {

    Context "Daily Scheduled Task Creation" {
        It "Should create a daily scheduled task" {
            $taskName = "$script:TestTaskPrefix-Daily"
            Register-TestTaskForCleanup -TaskName $taskName

            # Create the task
            $trigger = New-ScheduledTaskTrigger -Daily -At "03:00"
            $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c echo test"
            Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Force | Out-Null

            # Verify task exists
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $task | Should -Not -BeNullOrEmpty
            $task.TaskName | Should -Be $taskName

            # Verify trigger type
            $task.Triggers[0].CimClass.CimClassName | Should -Match "Daily"
        }

        It "Should create daily task with specific time" {
            $taskName = "$script:TestTaskPrefix-DailyTime"
            Register-TestTaskForCleanup -TaskName $taskName

            $scheduleTime = "14:30"
            $trigger = New-ScheduledTaskTrigger -Daily -At $scheduleTime
            $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c echo test"
            Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Force | Out-Null

            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $task | Should -Not -BeNullOrEmpty

            # Verify the trigger exists
            $task.Triggers.Count | Should -BeGreaterOrEqual 1
        }
    }

    Context "Hourly Interval Task" {
        It "Should create hourly task with 4-hour repetition interval" {
            $taskName = "$script:TestTaskPrefix-Hourly"
            Register-TestTaskForCleanup -TaskName $taskName

            # Create task with 4-hour interval (matching Robocurse hourly schedule pattern)
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
                -RepetitionInterval (New-TimeSpan -Hours 4) `
                -RepetitionDuration (New-TimeSpan -Days 365)

            $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c echo test"
            Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Force | Out-Null

            # Verify task exists
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $task | Should -Not -BeNullOrEmpty
            $task.TaskName | Should -Be $taskName

            # Verify it's a Once trigger with repetition
            $task.Triggers[0].CimClass.CimClassName | Should -Match "Time|Once"
            $task.Triggers[0].Repetition | Should -Not -BeNullOrEmpty
        }

        It "Should create hourly task with 1-hour repetition interval" {
            $taskName = "$script:TestTaskPrefix-Hourly1"
            Register-TestTaskForCleanup -TaskName $taskName

            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
                -RepetitionInterval (New-TimeSpan -Hours 1) `
                -RepetitionDuration (New-TimeSpan -Days 9999)

            $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c echo test"
            Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Force | Out-Null

            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $task | Should -Not -BeNullOrEmpty
        }
    }

    Context "Weekly Schedule Test" {
        It "Should create weekly task for Saturday" {
            $taskName = "$script:TestTaskPrefix-Weekly"
            Register-TestTaskForCleanup -TaskName $taskName

            $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At "02:00"
            $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c echo test"
            Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Force | Out-Null

            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $task | Should -Not -BeNullOrEmpty

            # Verify trigger type
            $task.Triggers[0].CimClass.CimClassName | Should -Match "Weekly"
            $task.Triggers[0].DaysOfWeek | Should -Be 64  # Saturday = 64
        }

        It "Should create weekly task for Sunday" {
            $taskName = "$script:TestTaskPrefix-WeeklySun"
            Register-TestTaskForCleanup -TaskName $taskName

            $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "03:00"
            $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c echo test"
            Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Force | Out-Null

            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $task | Should -Not -BeNullOrEmpty
            $task.Triggers[0].DaysOfWeek | Should -Be 1  # Sunday = 1
        }
    }

    Context "Enable and Disable Scheduled Task" {
        It "Should enable and disable a scheduled task" {
            $taskName = "$script:TestTaskPrefix-Toggle"
            Register-TestTaskForCleanup -TaskName $taskName

            # Create and then disable the task
            $trigger = New-ScheduledTaskTrigger -Daily -At "03:00"
            $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c echo test"
            Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Force | Out-Null
            Disable-ScheduledTask -TaskName $taskName | Out-Null

            # Verify disabled
            $task = Get-ScheduledTask -TaskName $taskName
            $task.State | Should -Be "Disabled"

            # Enable and verify
            Enable-ScheduledTask -TaskName $taskName | Out-Null
            $task = Get-ScheduledTask -TaskName $taskName
            $task.State | Should -Be "Ready"

            # Disable again and verify
            Disable-ScheduledTask -TaskName $taskName | Out-Null
            $task = Get-ScheduledTask -TaskName $taskName
            $task.State | Should -Be "Disabled"
        }
    }

    Context "Task Cleanup Test" {
        It "Should properly remove scheduled tasks" {
            $taskName = "$script:TestTaskPrefix-Cleanup"

            # Create a task
            $trigger = New-ScheduledTaskTrigger -Daily -At "03:00"
            $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c echo test"
            Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Force | Out-Null

            # Verify it exists
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $task | Should -Not -BeNullOrEmpty

            # Remove it
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false

            # Verify it's gone
            $taskAfter = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $taskAfter | Should -BeNullOrEmpty
        }

        It "Should handle removing non-existent task gracefully" {
            $fakeName = "$script:TestTaskPrefix-NonExistent-$([Guid]::NewGuid().ToString('N').Substring(0,8))"

            # Unregistering a non-existent task should not throw when using -ErrorAction SilentlyContinue
            { Unregister-ScheduledTask -TaskName $fakeName -Confirm:$false -ErrorAction SilentlyContinue } | Should -Not -Throw
        }
    }
}

Describe "Profile Scheduled Task Integration" -Tag "Integration", "Scheduling" -Skip:(-not $script:CanCreateTasks) {

    Context "New-ProfileScheduledTask" {
        It "Should create profile scheduled task with correct properties" {
            $profileName = "$script:TestTaskPrefix-Profile"
            $taskName = "Robocurse-Profile-$profileName"
            Register-TestTaskForCleanup -TaskName $taskName

            # Create profile object
            $profile = [PSCustomObject]@{
                Name = $profileName
                Source = "C:\Temp\Source"
                Destination = "C:\Temp\Dest"
                Schedule = [PSCustomObject]@{
                    Enabled = $true
                    Frequency = "Daily"
                    Time = "02:00"
                }
            }

            # Create scheduled task using the Robocurse function
            $result = New-ProfileScheduledTask `
                -Profile $profile `
                -ConfigPath $script:TempConfigPath `
                -ScriptPath $script:TempScriptPath

            $result.Success | Should -Be $true -Because "Task creation should succeed: $($result.ErrorMessage)"
            $result.Data | Should -Be $taskName

            # Verify task exists and has correct properties
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $task | Should -Not -BeNullOrEmpty

            # Verify trigger is daily
            $task.Triggers[0].CimClass.CimClassName | Should -Match "Daily"

            # Verify action is PowerShell
            $task.Actions[0].Execute | Should -Match "powershell"

            # Verify description contains profile name
            $task.Description | Should -Match $profileName
        }

        It "Should create profile scheduled task with hourly frequency" {
            $profileName = "$script:TestTaskPrefix-HourlyProfile"
            $taskName = "Robocurse-Profile-$profileName"
            Register-TestTaskForCleanup -TaskName $taskName

            $profile = [PSCustomObject]@{
                Name = $profileName
                Source = "C:\Temp\Source"
                Destination = "C:\Temp\Dest"
                Schedule = [PSCustomObject]@{
                    Enabled = $true
                    Frequency = "Hourly"
                    Time = "00:00"
                    Interval = 4
                }
            }

            $result = New-ProfileScheduledTask `
                -Profile $profile `
                -ConfigPath $script:TempConfigPath `
                -ScriptPath $script:TempScriptPath

            $result.Success | Should -Be $true

            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $task | Should -Not -BeNullOrEmpty

            # Hourly uses Once trigger with repetition
            $task.Triggers[0].CimClass.CimClassName | Should -Match "Time|Once"
            $task.Triggers[0].Repetition | Should -Not -BeNullOrEmpty
        }

        It "Should create profile scheduled task with weekly frequency" {
            $profileName = "$script:TestTaskPrefix-WeeklyProfile"
            $taskName = "Robocurse-Profile-$profileName"
            Register-TestTaskForCleanup -TaskName $taskName

            $profile = [PSCustomObject]@{
                Name = $profileName
                Source = "C:\Temp\Source"
                Destination = "C:\Temp\Dest"
                Schedule = [PSCustomObject]@{
                    Enabled = $true
                    Frequency = "Weekly"
                    Time = "04:00"
                    DayOfWeek = "Saturday"
                }
            }

            $result = New-ProfileScheduledTask `
                -Profile $profile `
                -ConfigPath $script:TempConfigPath `
                -ScriptPath $script:TempScriptPath

            $result.Success | Should -Be $true

            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $task | Should -Not -BeNullOrEmpty
            $task.Triggers[0].CimClass.CimClassName | Should -Match "Weekly"
        }

        It "Should replace existing task when recreating" {
            $profileName = "$script:TestTaskPrefix-Replace"
            $taskName = "Robocurse-Profile-$profileName"
            Register-TestTaskForCleanup -TaskName $taskName

            $profile = [PSCustomObject]@{
                Name = $profileName
                Source = "C:\Temp\Source"
                Destination = "C:\Temp\Dest"
                Schedule = [PSCustomObject]@{
                    Enabled = $true
                    Frequency = "Daily"
                    Time = "02:00"
                }
            }

            # Create first time
            $result1 = New-ProfileScheduledTask `
                -Profile $profile `
                -ConfigPath $script:TempConfigPath `
                -ScriptPath $script:TempScriptPath

            $result1.Success | Should -Be $true

            # Create again (should replace)
            $profile.Schedule.Time = "05:00"  # Different time
            $result2 = New-ProfileScheduledTask `
                -Profile $profile `
                -ConfigPath $script:TempConfigPath `
                -ScriptPath $script:TempScriptPath

            $result2.Success | Should -Be $true

            # Should still only have one task with this name
            $tasks = @(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
            $tasks.Count | Should -Be 1
        }
    }

    Context "Remove-ProfileScheduledTask" {
        It "Should remove profile scheduled task" {
            $profileName = "$script:TestTaskPrefix-Remove"
            $taskName = "Robocurse-Profile-$profileName"

            # Create the task first
            $profile = [PSCustomObject]@{
                Name = $profileName
                Source = "C:\Temp\Source"
                Destination = "C:\Temp\Dest"
                Schedule = [PSCustomObject]@{
                    Enabled = $true
                    Frequency = "Daily"
                    Time = "02:00"
                }
            }

            New-ProfileScheduledTask `
                -Profile $profile `
                -ConfigPath $script:TempConfigPath `
                -ScriptPath $script:TempScriptPath | Out-Null

            # Verify it exists
            $taskBefore = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $taskBefore | Should -Not -BeNullOrEmpty

            # Remove it
            $result = Remove-ProfileScheduledTask -ProfileName $profileName
            $result.Success | Should -Be $true

            # Verify it's gone
            $taskAfter = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $taskAfter | Should -BeNullOrEmpty
        }

        It "Should succeed when removing non-existent profile task" {
            $profileName = "$script:TestTaskPrefix-NonExistentProfile"

            $result = Remove-ProfileScheduledTask -ProfileName $profileName

            # Should succeed (idempotent operation)
            $result.Success | Should -Be $true
        }
    }

    Context "Get-ProfileScheduledTask" {
        It "Should return task info for existing profile task" {
            $profileName = "$script:TestTaskPrefix-GetInfo"
            $taskName = "Robocurse-Profile-$profileName"
            Register-TestTaskForCleanup -TaskName $taskName

            $profile = [PSCustomObject]@{
                Name = $profileName
                Source = "C:\Temp\Source"
                Destination = "C:\Temp\Dest"
                Schedule = [PSCustomObject]@{
                    Enabled = $true
                    Frequency = "Daily"
                    Time = "02:00"
                }
            }

            New-ProfileScheduledTask `
                -Profile $profile `
                -ConfigPath $script:TempConfigPath `
                -ScriptPath $script:TempScriptPath | Out-Null

            $taskInfo = Get-ProfileScheduledTask -ProfileName $profileName

            $taskInfo | Should -Not -BeNullOrEmpty
            $taskInfo.Name | Should -Be $profileName
            $taskInfo.TaskName | Should -Be $taskName
            $taskInfo.State | Should -Be "Ready"
            $taskInfo.Enabled | Should -Be $true
        }

        It "Should return null for non-existent profile task" {
            $profileName = "$script:TestTaskPrefix-NonExistent"

            $taskInfo = Get-ProfileScheduledTask -ProfileName $profileName

            $taskInfo | Should -BeNullOrEmpty
        }
    }

    Context "Enable-ProfileScheduledTask and Disable-ProfileScheduledTask" {
        It "Should enable and disable profile scheduled task" {
            $profileName = "$script:TestTaskPrefix-EnableDisable"
            $taskName = "Robocurse-Profile-$profileName"
            Register-TestTaskForCleanup -TaskName $taskName

            $profile = [PSCustomObject]@{
                Name = $profileName
                Source = "C:\Temp\Source"
                Destination = "C:\Temp\Dest"
                Schedule = [PSCustomObject]@{
                    Enabled = $true
                    Frequency = "Daily"
                    Time = "02:00"
                }
            }

            New-ProfileScheduledTask `
                -Profile $profile `
                -ConfigPath $script:TempConfigPath `
                -ScriptPath $script:TempScriptPath | Out-Null

            # Disable it
            $disableResult = Disable-ProfileScheduledTask -ProfileName $profileName
            $disableResult.Success | Should -Be $true

            $taskInfo = Get-ProfileScheduledTask -ProfileName $profileName
            $taskInfo.State | Should -Be "Disabled"
            $taskInfo.Enabled | Should -Be $false

            # Enable it
            $enableResult = Enable-ProfileScheduledTask -ProfileName $profileName
            $enableResult.Success | Should -Be $true

            $taskInfo = Get-ProfileScheduledTask -ProfileName $profileName
            $taskInfo.State | Should -Be "Ready"
            $taskInfo.Enabled | Should -Be $true
        }
    }

    Context "Get-AllProfileScheduledTasks" {
        It "Should list all profile scheduled tasks" {
            # Create a couple of profile tasks
            $profileName1 = "$script:TestTaskPrefix-List1"
            $profileName2 = "$script:TestTaskPrefix-List2"
            $taskName1 = "Robocurse-Profile-$profileName1"
            $taskName2 = "Robocurse-Profile-$profileName2"
            Register-TestTaskForCleanup -TaskName $taskName1
            Register-TestTaskForCleanup -TaskName $taskName2

            $profile1 = [PSCustomObject]@{
                Name = $profileName1
                Source = "C:\Temp\Source1"
                Destination = "C:\Temp\Dest1"
                Schedule = [PSCustomObject]@{
                    Enabled = $true
                    Frequency = "Daily"
                    Time = "02:00"
                }
            }

            $profile2 = [PSCustomObject]@{
                Name = $profileName2
                Source = "C:\Temp\Source2"
                Destination = "C:\Temp\Dest2"
                Schedule = [PSCustomObject]@{
                    Enabled = $true
                    Frequency = "Weekly"
                    Time = "03:00"
                    DayOfWeek = "Sunday"
                }
            }

            New-ProfileScheduledTask -Profile $profile1 -ConfigPath $script:TempConfigPath -ScriptPath $script:TempScriptPath | Out-Null
            New-ProfileScheduledTask -Profile $profile2 -ConfigPath $script:TempConfigPath -ScriptPath $script:TempScriptPath | Out-Null

            $allTasks = Get-AllProfileScheduledTasks

            # Filter to just our test tasks
            $ourTasks = @($allTasks | Where-Object { $_.Name -like "$script:TestTaskPrefix*" })

            $ourTasks.Count | Should -BeGreaterOrEqual 2
            $ourTasks.Name | Should -Contain $profileName1
            $ourTasks.Name | Should -Contain $profileName2
        }
    }
}

Describe "Scheduling Not Available Tests" -Tag "Integration", "Scheduling" -Skip:($script:CanCreateTasks) {
    It "Should skip scheduling tests when not running as admin or Task Scheduler not available" {
        # This test documents why scheduling tests were skipped
        if (-not $script:IsWindows) {
            $script:IsWindows | Should -Be $false -Because "Not running on Windows"
        }
        elseif (-not $script:IsAdmin) {
            $script:IsAdmin | Should -Be $false -Because "Not running as administrator"
        }
        else {
            $script:CanCreateTasks | Should -Be $false -Because "Task Scheduler service not running"
        }
    }
}
