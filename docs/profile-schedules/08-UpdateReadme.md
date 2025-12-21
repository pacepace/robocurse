# 08-UpdateReadme

Update README documentation with per-profile scheduling feature.

## Objective

Update the project README to document the new per-profile scheduling feature including GUI usage and CLI commands.

## Success Criteria

- [ ] README updated with Profile Scheduling section
- [ ] GUI usage documented (Schedule button, dialog)
- [ ] CLI commands documented with examples
- [ ] Feature listed in capabilities/features section

## Research

### README Location
- `README.md` in project root

### Documentation Pattern
Review existing README sections for style/format consistency.

## Implementation

### 1. Add to Features Section

Add under existing features list:

```markdown
- **Per-Profile Scheduling** - Configure individual schedules for each profile (Hourly, Daily, Weekly, Monthly)
```

### 2. Add Profile Scheduling Section

Add a new section (e.g., after existing scheduling documentation):

```markdown
## Profile Scheduling

Each profile can have its own independent schedule. Schedules are managed via Windows Task Scheduler.

### GUI Configuration

1. Select a profile from the list
2. Click the **Schedule** button (next to Validate)
3. Enable scheduling and configure:
   - **Frequency**: Hourly, Daily, Weekly, or Monthly
   - **Time**: When to run (24-hour format, e.g., 02:00)
   - **Interval**: For Hourly - run every N hours
   - **Day of Week**: For Weekly - which day
   - **Day of Month**: For Monthly - which date (1-28)
4. Click **Save** to create the scheduled task

The Schedule button shows a checkmark (✓) when a schedule is active.

### CLI Commands

```powershell
# List all profile schedules
.\Robocurse.ps1 -ListProfileSchedules

# Set a daily schedule
.\Robocurse.ps1 -SetProfileSchedule -ProfileName "MyBackup" -Frequency Daily -Time "03:00"

# Set an hourly schedule (every 4 hours)
.\Robocurse.ps1 -SetProfileSchedule -ProfileName "FrequentSync" -Frequency Hourly -Interval 4

# Set a weekly schedule
.\Robocurse.ps1 -SetProfileSchedule -ProfileName "WeeklyArchive" -Frequency Weekly -DayOfWeek Saturday -Time "02:00"

# Set a monthly schedule
.\Robocurse.ps1 -SetProfileSchedule -ProfileName "MonthlyReport" -Frequency Monthly -DayOfMonth 1 -Time "01:00"

# Enable/disable a schedule
.\Robocurse.ps1 -EnableProfileSchedule -ProfileName "MyBackup"
.\Robocurse.ps1 -DisableProfileSchedule -ProfileName "MyBackup"

# Sync tasks with config (create missing, remove orphaned)
.\Robocurse.ps1 -SyncProfileSchedules
```

### Task Naming

Scheduled tasks are created with the naming convention: `Robocurse-Profile-{ProfileName}`

You can view these tasks in Windows Task Scheduler under the root folder.
```

## Test Plan

Manual verification:
1. Review README for accuracy
2. Verify all CLI examples work
3. Check formatting renders correctly in markdown preview

## Files to Modify

- `README.md` - Add profile scheduling documentation

## Verification

```powershell
# Preview README (if you have a markdown viewer)
code README.md

# Verify CLI examples from README work
.\dist\Robocurse.ps1 -ListProfileSchedules
```

## Dependencies

This task should be executed LAST, after all other implementation tasks are complete:
- 01-ProfileScheduleSchema
- 02-ProfileScheduleCore
- 03-ProfileScheduleTests
- 04-ProfileScheduleDialog
- 05-ProfileScheduleButton
- 06-ProfileScheduleCli
- 07-ProfileScheduleGuiTests
