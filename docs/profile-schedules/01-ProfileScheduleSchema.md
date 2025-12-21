# 01-ProfileScheduleSchema

Add Schedule property to profile configuration schema.

## Objective

Extend the profile schema in `Configuration.ps1` to include a Schedule property that stores per-profile scheduling configuration.

## Success Criteria

- [ ] Schedule property added to profile schema with all required fields
- [ ] Default values set correctly (Enabled=$false, Frequency="Daily", Time="02:00")
- [ ] ConvertFrom-FriendlyConfig correctly parses schedule from JSON
- [ ] ConvertTo-FriendlyConfig correctly serializes schedule to JSON
- [ ] Existing profiles without schedule property work (migration path)
- [ ] Tests pass for new schema

## Research

### Profile Schema Location
- `src\Robocurse\Public\Configuration.ps1:360-380` - Profile object creation in `ConvertFrom-FriendlyConfig`
- `src\Robocurse\Public\Configuration.ps1:517-537` - Profile serialization in `ConvertTo-FriendlyConfig`

### Schedule Property Structure
```powershell
Schedule = [PSCustomObject]@{
    Enabled = $false           # Whether schedule is active
    Frequency = "Daily"        # Hourly, Daily, Weekly, Monthly
    Time = "02:00"             # HH:MM format
    Interval = 1               # For Hourly: every N hours (1-24)
    DayOfWeek = "Sunday"       # For Weekly: day name
    DayOfMonth = 1             # For Monthly: day of month (1-28)
}
```

### Related Code Patterns
- `src\Robocurse\Public\Configuration.ps1:399-414` - SourceSnapshot/DestinationSnapshot pattern
- `src\Robocurse\Public\Configuration.ps1:539-553` - Snapshot serialization pattern

## Implementation

### 1. Add Schedule property to profile object (Configuration.ps1:~379)

After line 379 (after DestinationSnapshot), add:
```powershell
Schedule = [PSCustomObject]@{
    Enabled = $false
    Frequency = "Daily"
    Time = "02:00"
    Interval = 1
    DayOfWeek = "Sunday"
    DayOfMonth = 1
}
```

### 2. Parse schedule from JSON (Configuration.ps1:~426)

After destinationSnapshot handling (~line 414), add:
```powershell
# Handle schedule settings
if ($rawProfile.schedule) {
    $syncProfile.Schedule = [PSCustomObject]@{
        Enabled = [bool]$rawProfile.schedule.enabled
        Frequency = if ($rawProfile.schedule.frequency) { $rawProfile.schedule.frequency } else { "Daily" }
        Time = if ($rawProfile.schedule.time) { $rawProfile.schedule.time } else { "02:00" }
        Interval = if ($rawProfile.schedule.interval) { [int]$rawProfile.schedule.interval } else { 1 }
        DayOfWeek = if ($rawProfile.schedule.dayOfWeek) { $rawProfile.schedule.dayOfWeek } else { "Sunday" }
        DayOfMonth = if ($rawProfile.schedule.dayOfMonth) { [int]$rawProfile.schedule.dayOfMonth } else { 1 }
    }
}
```

### 3. Serialize schedule to JSON (Configuration.ps1:~554)

After destination snapshot serialization (~line 553), add:
```powershell
# Add schedule settings if configured
if ($profile.Schedule -and $profile.Schedule.Enabled) {
    $friendlyProfile.schedule = [ordered]@{
        enabled = $profile.Schedule.Enabled
        frequency = $profile.Schedule.Frequency
        time = $profile.Schedule.Time
    }
    # Add frequency-specific fields
    switch ($profile.Schedule.Frequency) {
        "Hourly" {
            $friendlyProfile.schedule.interval = $profile.Schedule.Interval
        }
        "Weekly" {
            $friendlyProfile.schedule.dayOfWeek = $profile.Schedule.DayOfWeek
        }
        "Monthly" {
            $friendlyProfile.schedule.dayOfMonth = $profile.Schedule.DayOfMonth
        }
    }
}
```

## Test Plan

Add to `tests\Unit\Configuration.Tests.ps1`:

```powershell
Context "Profile Schedule Schema" {
    It "Should have default Schedule property on new profile" {
        $config = New-DefaultConfig
        $profile = [PSCustomObject]@{
            Name = "TestProfile"
            Source = "C:\Test"
            Destination = "D:\Backup"
        }
        # Simulate conversion
        $config.SyncProfiles = @($profile)

        # Schedule should have defaults
        $profile.Schedule | Should -Not -BeNullOrEmpty
        $profile.Schedule.Enabled | Should -Be $false
        $profile.Schedule.Frequency | Should -Be "Daily"
        $profile.Schedule.Time | Should -Be "02:00"
    }

    It "Should parse schedule from JSON config" {
        $json = @'
{
    "profiles": {
        "TestProfile": {
            "source": "C:\\Test",
            "destination": "D:\\Backup",
            "schedule": {
                "enabled": true,
                "frequency": "Weekly",
                "time": "03:00",
                "dayOfWeek": "Saturday"
            }
        }
    }
}
'@
        $tempPath = Join-Path $TestDrive "schedule-test.json"
        $json | Set-Content $tempPath

        $config = Get-RobocurseConfig -Path $tempPath
        $profile = $config.SyncProfiles[0]

        $profile.Schedule.Enabled | Should -Be $true
        $profile.Schedule.Frequency | Should -Be "Weekly"
        $profile.Schedule.Time | Should -Be "03:00"
        $profile.Schedule.DayOfWeek | Should -Be "Saturday"
    }

    It "Should serialize schedule to JSON" {
        $config = New-DefaultConfig
        $config.SyncProfiles = @([PSCustomObject]@{
            Name = "TestProfile"
            Source = "C:\Test"
            Destination = "D:\Backup"
            Schedule = [PSCustomObject]@{
                Enabled = $true
                Frequency = "Hourly"
                Time = "00:00"
                Interval = 4
                DayOfWeek = "Sunday"
                DayOfMonth = 1
            }
        })

        $friendly = ConvertTo-FriendlyConfig -Config $config

        $friendly.profiles.TestProfile.schedule | Should -Not -BeNullOrEmpty
        $friendly.profiles.TestProfile.schedule.enabled | Should -Be $true
        $friendly.profiles.TestProfile.schedule.frequency | Should -Be "Hourly"
        $friendly.profiles.TestProfile.schedule.interval | Should -Be 4
    }

    It "Should handle profiles without schedule property" {
        $json = @'
{
    "profiles": {
        "LegacyProfile": {
            "source": "C:\\Legacy",
            "destination": "D:\\Backup"
        }
    }
}
'@
        $tempPath = Join-Path $TestDrive "legacy-test.json"
        $json | Set-Content $tempPath

        $config = Get-RobocurseConfig -Path $tempPath
        $profile = $config.SyncProfiles[0]

        # Should have default schedule
        $profile.Schedule.Enabled | Should -Be $false
        $profile.Schedule.Frequency | Should -Be "Daily"
    }
}
```

## Files to Modify

- `src\Robocurse\Public\Configuration.ps1`
  - Add Schedule property to profile creation (~line 379)
  - Add schedule parsing in ConvertFrom-FriendlyConfig (~line 426)
  - Add schedule serialization in ConvertTo-FriendlyConfig (~line 554)

- `tests\Unit\Configuration.Tests.ps1`
  - Add "Profile Schedule Schema" context with tests

## Verification

```powershell
# Run tests
.\scripts\run-tests.ps1

# Verify specific tests
Invoke-Pester -Path tests\Unit\Configuration.Tests.ps1 -Output Detailed

# Manual verification
$config = New-DefaultConfig
$config.SyncProfiles = @([PSCustomObject]@{
    Name = "Test"
    Source = "C:\Test"
    Destination = "D:\Backup"
    Schedule = [PSCustomObject]@{
        Enabled = $true
        Frequency = "Daily"
        Time = "03:00"
        Interval = 1
        DayOfWeek = "Sunday"
        DayOfMonth = 1
    }
})
$friendly = ConvertTo-FriendlyConfig -Config $config
$friendly.profiles.Test.schedule
```
