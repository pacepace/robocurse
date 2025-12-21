# 06-ProfileScheduleCli

Add CLI commands for managing profile schedules.

## Objective

Add command-line parameters to Robocurse.ps1 for listing, configuring, enabling, and disabling profile schedules.

## Success Criteria

- [ ] `-ListProfileSchedules` parameter shows all profile schedules
- [ ] `-SetProfileSchedule` configures schedule for a profile
- [ ] `-EnableProfileSchedule` enables existing schedule
- [ ] `-DisableProfileSchedule` disables existing schedule
- [ ] Help text updated with new commands
- [ ] Commands return appropriate exit codes

## Research

### CLI Pattern Reference
- `src\Robocurse\Main.ps1` - Main entry point with parameter handling
- `dist\Robocurse.ps1` - Distribution entry point

### Existing CLI Parameters
Look at how other CLI-only operations are handled:
- `-TestEmail` - Sends test email
- `-SyncSchedules` - Syncs snapshot schedules
- `-ListSchedules` - Lists snapshot schedules

### Output Formatting
- Use `Format-Table` for list output
- Return `OperationResult` from functions
- Set `$LASTEXITCODE` appropriately

## Implementation

### 1. Add Parameters to Main.ps1

Add new parameters to the param block at the top of `Main.ps1`:

```powershell
param(
    # ... existing parameters ...

    # Profile Schedule Management
    [switch]$ListProfileSchedules,

    [switch]$SetProfileSchedule,
    [string]$ProfileName,
    [ValidateSet("Hourly", "Daily", "Weekly", "Monthly")]
    [string]$Frequency = "Daily",
    [string]$Time = "02:00",
    [int]$Interval = 1,
    [ValidateSet("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")]
    [string]$DayOfWeek = "Sunday",
    [int]$DayOfMonth = 1,

    [switch]$EnableProfileSchedule,
    [switch]$DisableProfileSchedule,
    [switch]$SyncProfileSchedules
)
```

### 2. Add CLI Handler Functions

Add to `Main.ps1` or create a new section for profile schedule CLI handling:

```powershell
# Profile Schedule CLI Commands
if ($ListProfileSchedules) {
    Write-Host "`nProfile Schedules:" -ForegroundColor Cyan
    Write-Host "==================" -ForegroundColor Cyan

    $schedules = Get-AllProfileScheduledTasks
    if ($schedules.Count -eq 0) {
        Write-Host "No profile schedules configured." -ForegroundColor Yellow
    } else {
        $schedules | Format-Table -Property @(
            @{Label="Profile"; Expression={$_.Name}},
            @{Label="State"; Expression={$_.State}},
            @{Label="Next Run"; Expression={if($_.NextRunTime){$_.NextRunTime.ToString("g")}else{"N/A"}}},
            @{Label="Last Run"; Expression={if($_.LastRunTime){$_.LastRunTime.ToString("g")}else{"Never"}}},
            @{Label="Last Result"; Expression={$_.LastResult}}
        ) -AutoSize
    }

    # Also show profiles with schedules in config but no task
    $config = Get-RobocurseConfig -Path $ConfigPath
    $configuredProfiles = $config.SyncProfiles | Where-Object { $_.Schedule -and $_.Schedule.Enabled }
    $taskNames = $schedules | ForEach-Object { $_.Name }

    $missingTasks = $configuredProfiles | Where-Object { $_.Name -notin $taskNames }
    if ($missingTasks.Count -gt 0) {
        Write-Host "`nProfiles with schedule in config but no task:" -ForegroundColor Yellow
        $missingTasks | ForEach-Object {
            Write-Host "  - $($_.Name): $($_.Schedule.Frequency) at $($_.Schedule.Time)" -ForegroundColor Yellow
        }
        Write-Host "Run -SyncProfileSchedules to create missing tasks." -ForegroundColor Gray
    }

    exit 0
}

if ($SetProfileSchedule) {
    if (-not $ProfileName) {
        Write-Host "Error: -ProfileName is required with -SetProfileSchedule" -ForegroundColor Red
        exit 1
    }

    # Load config
    $config = Get-RobocurseConfig -Path $ConfigPath
    $profile = $config.SyncProfiles | Where-Object { $_.Name -eq $ProfileName } | Select-Object -First 1

    if (-not $profile) {
        Write-Host "Error: Profile '$ProfileName' not found" -ForegroundColor Red
        exit 1
    }

    # Validate time format
    if ($Time -notmatch '^([01]?\d|2[0-3]):([0-5]\d)$') {
        Write-Host "Error: Invalid time format. Use HH:MM (24-hour)" -ForegroundColor Red
        exit 1
    }

    # Build schedule object
    $schedule = [PSCustomObject]@{
        Enabled = $true
        Frequency = $Frequency
        Time = $Time
        Interval = $Interval
        DayOfWeek = $DayOfWeek
        DayOfMonth = $DayOfMonth
    }

    # Update profile
    $profile.Schedule = $schedule

    # Save config
    $saveResult = Save-RobocurseConfig -Config $config -Path $ConfigPath
    if (-not $saveResult.Success) {
        Write-Host "Error: Failed to save config: $($saveResult.ErrorMessage)" -ForegroundColor Red
        exit 1
    }

    # Create task
    $result = New-ProfileScheduledTask -Profile $profile -ConfigPath $ConfigPath
    if ($result.Success) {
        Write-Host "Profile schedule set for '$ProfileName':" -ForegroundColor Green
        Write-Host "  Frequency: $Frequency"
        Write-Host "  Time: $Time"
        switch ($Frequency) {
            "Hourly" { Write-Host "  Interval: Every $Interval hour(s)" }
            "Weekly" { Write-Host "  Day: $DayOfWeek" }
            "Monthly" { Write-Host "  Day: $DayOfMonth" }
        }
        Write-Host "  Task: $($result.Data)"
        exit 0
    } else {
        Write-Host "Error: Failed to create task: $($result.ErrorMessage)" -ForegroundColor Red
        exit 1
    }
}

if ($EnableProfileSchedule) {
    if (-not $ProfileName) {
        Write-Host "Error: -ProfileName is required with -EnableProfileSchedule" -ForegroundColor Red
        exit 1
    }

    $result = Enable-ProfileScheduledTask -ProfileName $ProfileName
    if ($result.Success) {
        Write-Host "Profile schedule enabled for '$ProfileName'" -ForegroundColor Green
        exit 0
    } else {
        Write-Host "Error: Failed to enable schedule: $($result.ErrorMessage)" -ForegroundColor Red
        exit 1
    }
}

if ($DisableProfileSchedule) {
    if (-not $ProfileName) {
        Write-Host "Error: -ProfileName is required with -DisableProfileSchedule" -ForegroundColor Red
        exit 1
    }

    $result = Disable-ProfileScheduledTask -ProfileName $ProfileName
    if ($result.Success) {
        Write-Host "Profile schedule disabled for '$ProfileName'" -ForegroundColor Green
        exit 0
    } else {
        Write-Host "Error: Failed to disable schedule: $($result.ErrorMessage)" -ForegroundColor Red
        exit 1
    }
}

if ($SyncProfileSchedules) {
    $config = Get-RobocurseConfig -Path $ConfigPath
    $result = Sync-ProfileSchedules -Config $config -ConfigPath $ConfigPath

    if ($result.Success) {
        Write-Host "Profile schedules synced:" -ForegroundColor Green
        Write-Host "  Created: $($result.Data.Created)"
        Write-Host "  Removed: $($result.Data.Removed)"
        Write-Host "  Total active: $($result.Data.Total)"
        exit 0
    } else {
        Write-Host "Error syncing schedules: $($result.ErrorMessage)" -ForegroundColor Red
        if ($result.Data.Errors) {
            $result.Data.Errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        }
        exit 1
    }
}
```

### 3. Update Help Text

If there's a help section in Main.ps1 or a separate help file, add:

```
Profile Schedule Commands:
  -ListProfileSchedules              List all profile scheduled tasks
  -SetProfileSchedule                Configure schedule for a profile
    -ProfileName <name>              Required: Name of the profile
    -Frequency <type>                Hourly, Daily, Weekly, or Monthly (default: Daily)
    -Time <HH:MM>                    Run time in 24-hour format (default: 02:00)
    -Interval <N>                    For Hourly: run every N hours (default: 1)
    -DayOfWeek <day>                 For Weekly: day name (default: Sunday)
    -DayOfMonth <N>                  For Monthly: day 1-28 (default: 1)
  -EnableProfileSchedule             Enable schedule for a profile
    -ProfileName <name>              Required: Name of the profile
  -DisableProfileSchedule            Disable schedule for a profile
    -ProfileName <name>              Required: Name of the profile
  -SyncProfileSchedules              Sync tasks with config (create missing, remove orphaned)

Examples:
  .\Robocurse.ps1 -ListProfileSchedules
  .\Robocurse.ps1 -SetProfileSchedule -ProfileName "DailyBackup" -Frequency Daily -Time "03:00"
  .\Robocurse.ps1 -SetProfileSchedule -ProfileName "HourlySync" -Frequency Hourly -Interval 4
  .\Robocurse.ps1 -SetProfileSchedule -ProfileName "WeeklyArchive" -Frequency Weekly -DayOfWeek Saturday
  .\Robocurse.ps1 -EnableProfileSchedule -ProfileName "DailyBackup"
  .\Robocurse.ps1 -DisableProfileSchedule -ProfileName "DailyBackup"
  .\Robocurse.ps1 -SyncProfileSchedules
```

## Test Plan

Manual testing:

```powershell
# List schedules (empty)
.\dist\Robocurse.ps1 -ListProfileSchedules

# Set a daily schedule
.\dist\Robocurse.ps1 -SetProfileSchedule -ProfileName "TestProfile" -Frequency Daily -Time "03:00"

# Verify task created
Get-ScheduledTask -TaskName "Robocurse-Profile-TestProfile"

# List schedules (should show the new one)
.\dist\Robocurse.ps1 -ListProfileSchedules

# Disable schedule
.\dist\Robocurse.ps1 -DisableProfileSchedule -ProfileName "TestProfile"

# Enable schedule
.\dist\Robocurse.ps1 -EnableProfileSchedule -ProfileName "TestProfile"

# Set hourly schedule
.\dist\Robocurse.ps1 -SetProfileSchedule -ProfileName "TestProfile" -Frequency Hourly -Time "00:00" -Interval 4

# Set weekly schedule
.\dist\Robocurse.ps1 -SetProfileSchedule -ProfileName "TestProfile" -Frequency Weekly -DayOfWeek Saturday -Time "02:00"

# Sync schedules
.\dist\Robocurse.ps1 -SyncProfileSchedules

# Error cases
.\dist\Robocurse.ps1 -SetProfileSchedule  # Should error: missing ProfileName
.\dist\Robocurse.ps1 -SetProfileSchedule -ProfileName "NonExistent"  # Should error: profile not found
.\dist\Robocurse.ps1 -SetProfileSchedule -ProfileName "TestProfile" -Time "25:00"  # Should error: invalid time
```

## Files to Modify

- `src\Robocurse\Main.ps1`
  - Add profile schedule parameters
  - Add CLI command handlers
  - Update help text

- `dist\Robocurse.ps1` (if parameters need to be passed through)
  - Ensure parameters are forwarded to Main.ps1

## Verification

```powershell
# Run help
.\dist\Robocurse.ps1 -Help | Select-String "Schedule"

# Test list command
.\dist\Robocurse.ps1 -ListProfileSchedules

# Test with actual profile
.\dist\Robocurse.ps1 -SetProfileSchedule -ProfileName "MyProfile" -Frequency Daily -Time "02:30"

# Verify exit codes
.\dist\Robocurse.ps1 -ListProfileSchedules; Write-Host "Exit code: $LASTEXITCODE"
.\dist\Robocurse.ps1 -SetProfileSchedule -ProfileName "NonExistent"; Write-Host "Exit code: $LASTEXITCODE"
```
