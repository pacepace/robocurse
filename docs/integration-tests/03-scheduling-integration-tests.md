# Task: Scheduling Integration Tests

## Objective
Add integration tests that create, verify, and clean up real Windows scheduled tasks. Currently, scheduling tests use `-WhatIf` which prevents actual task creation, so they don't catch issues with Task Scheduler compatibility, permission problems, or task configuration errors.

## Problem Statement
The scheduling system has unit tests that:
- Use `-WhatIf` on all task operations (Register, Unregister, Enable, Disable)
- Mock task existence checks
- Never actually create tasks in Task Scheduler

Real-world issues that could slip through:
- Task XML schema compatibility issues
- Permission/privilege requirements
- Task action path resolution
- Trigger configuration edge cases
- Task cleanup failures

## Success Criteria
1. Integration tests create real scheduled tasks
2. Tests verify tasks appear in Task Scheduler
3. Tests verify task properties match configuration
4. Tests clean up tasks after verification
5. Tests require elevated privileges (skip if not admin)
6. Tests use unique task names to avoid conflicts

## Research: Current Implementation

### Task Creation (src/Robocurse/Public/ProfileSchedule.ps1)
```powershell
function New-ProfileScheduledTask {
    param(
        [string]$ProfileName,
        [string]$Frequency,
        [string]$Time,
        ...
    )

    $taskName = "Robocurse-Profile-$ProfileName"

    # Build trigger based on frequency
    $trigger = switch ($Frequency) {
        'Hourly' { New-ScheduledTaskTrigger -Once -At $Time -RepetitionInterval ... }
        'Daily'  { New-ScheduledTaskTrigger -Daily -At $Time }
        ...
    }

    # Create action
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "..."

    # Register task
    Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action ...
}
```

### Current Unit Tests (tests/Unit/ProfileSchedule.Tests.ps1)
```powershell
# Uses WhatIf to prevent actual task creation
Register-ScheduledTask @params -WhatIf

It "Should create daily schedule" {
    # Only verifies WhatIf output message
    Assert-MockCalled Register-ScheduledTask
}
```

### Admin Check Pattern
```powershell
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
```

## Implementation Plan

### Step 1: Create Admin Skip Logic
```powershell
BeforeAll {
    $script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )

    if (-not $script:IsAdmin) {
        Write-Warning "Scheduling integration tests require administrator privileges - skipping"
    }

    # Unique prefix for test tasks
    $script:TestTaskPrefix = "RobocurseTest_$([guid]::NewGuid().ToString('N').Substring(0,8))"
}

AfterAll {
    # Cleanup any test tasks that might have been left behind
    if ($script:IsAdmin) {
        Get-ScheduledTask -TaskName "$($script:TestTaskPrefix)*" -ErrorAction SilentlyContinue |
            Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    }
}
```

### Step 2: Add Task Creation Test
```powershell
Describe "Scheduled Task Creation" -Tag "Integration", "Scheduling" {
    It "Should create a daily scheduled task" -Skip:(-not $script:IsAdmin) {
        $taskName = "$script:TestTaskPrefix-Daily"

        # Create the task
        $trigger = New-ScheduledTaskTrigger -Daily -At "03:00"
        $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c echo test"
        Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Force

        # Verify task exists
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        $task | Should -Not -BeNullOrEmpty
        $task.TaskName | Should -Be $taskName

        # Cleanup
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
}
```

### Step 3: Add Profile Schedule Test
```powershell
It "Should create profile scheduled task with correct properties" -Skip:(-not $script:IsAdmin) {
    # Create temp config for test
    $testConfig = @{
        SyncProfiles = @(
            @{
                Name = "$script:TestTaskPrefix-Profile"
                Source = "C:\Temp\Source"
                Destination = "C:\Temp\Dest"
                Enabled = $true
            }
        )
    }
    $configPath = Join-Path $env:TEMP "$script:TestTaskPrefix-config.json"
    $testConfig | ConvertTo-Json -Depth 10 | Set-Content $configPath

    try {
        # Create scheduled task for profile
        New-ProfileScheduledTask `
            -ProfileName "$script:TestTaskPrefix-Profile" `
            -ConfigPath $configPath `
            -Frequency Daily `
            -Time "02:00"

        # Verify task exists and has correct properties
        $taskName = "Robocurse-Profile-$script:TestTaskPrefix-Profile"
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        $task | Should -Not -BeNullOrEmpty

        # Verify trigger
        $task.Triggers[0].CimClass.CimClassName | Should -Match "Daily"

        # Cleanup
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    finally {
        Remove-Item $configPath -Force -ErrorAction SilentlyContinue
    }
}
```

### Step 4: Add Enable/Disable Test
```powershell
It "Should enable and disable scheduled task" -Skip:(-not $script:IsAdmin) {
    $taskName = "$script:TestTaskPrefix-Toggle"

    # Create disabled task
    $trigger = New-ScheduledTaskTrigger -Daily -At "03:00"
    $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c echo test"
    Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Force
    Disable-ScheduledTask -TaskName $taskName

    # Verify disabled
    $task = Get-ScheduledTask -TaskName $taskName
    $task.State | Should -Be "Disabled"

    # Enable and verify
    Enable-ScheduledTask -TaskName $taskName
    $task = Get-ScheduledTask -TaskName $taskName
    $task.State | Should -Be "Ready"

    # Cleanup
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
```

### Step 5: Add Hourly Interval Test
```powershell
It "Should create hourly task with correct interval" -Skip:(-not $script:IsAdmin) {
    $taskName = "$script:TestTaskPrefix-Hourly"

    # Create task with 4-hour interval
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Hours 4) `
        -RepetitionDuration (New-TimeSpan -Days 365)

    $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c echo test"
    Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -Force

    # Verify
    $task = Get-ScheduledTask -TaskName $taskName
    $task | Should -Not -BeNullOrEmpty

    # Cleanup
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
```

## Test Plan
```powershell
# Must run as administrator
# Open elevated PowerShell

# Run scheduling integration tests
Invoke-Pester -Path tests/Integration/Scheduling.Integration.Tests.ps1 -Output Detailed
```

## Files to Create
| File | Purpose |
|------|---------|
| `tests/Integration/Scheduling.Integration.Tests.ps1` | New integration test file |

## Verification
1. Tests skip cleanly when not running as admin
2. Tests create real scheduled tasks visible in Task Scheduler
3. Tasks have correct triggers and actions
4. Tests clean up all created tasks
5. No orphan test tasks left behind after test run
