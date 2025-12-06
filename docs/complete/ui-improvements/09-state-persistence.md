# Task: Update State Persistence

## Objective

Update the GUI state persistence to save and restore the active panel, new window dimensions, and last run summary. Ensure all new UI state survives application restart.

## Context

Robocurse already persists some GUI state (window position/size, worker count, selected profile) to `Robocurse.settings.json`. This task extends that to include the new navigation rail state and last run information.

## Files to Modify

| File | Action |
|------|--------|
| `src/Robocurse/Public/GuiSettings.ps1` | Add new properties, update defaults |
| `src/Robocurse/Public/GuiMain.ps1` | Restore active panel on load, save on close |

## Research Required

### In Codebase
1. Read `src/Robocurse/Public/GuiSettings.ps1`:
   - `Get-GuiState` function - how settings are loaded
   - `Save-GuiState` function - how settings are saved
   - `Restore-GuiState` function - how settings are applied to window
   - Current settings structure

2. Read `Robocurse.settings.json` (if exists):
   - Current properties saved
   - JSON structure

### Current Settings Structure

From GuiSettings.ps1:
```powershell
$defaultState = @{
    WindowLeft = 100
    WindowTop = 100
    WindowWidth = 1100    # Old default
    WindowHeight = 800    # Old default
    WindowState = 'Normal'
    SelectedProfile = ''
    WorkerCount = 4
}
```

## Implementation Steps

### Step 1: Update Default Settings

Modify the default state in `Get-GuiState`:

```powershell
function Get-GuiState {
    <#
    .SYNOPSIS
        Loads GUI state from settings file
    #>
    [CmdletBinding()]
    param()

    # Updated defaults for new layout
    $defaultState = @{
        WindowLeft = 100
        WindowTop = 100
        WindowWidth = 650       # NEW: Smaller default
        WindowHeight = 550      # NEW: Smaller default
        WindowState = 'Normal'
        SelectedProfile = ''
        WorkerCount = 4
        ActivePanel = 'Profiles'  # NEW: Which panel is shown
        LastRun = $null           # NEW: Last run summary (hashtable)
    }

    $settingsPath = Join-Path $PSScriptRoot 'Robocurse.settings.json'

    if (Test-Path $settingsPath) {
        try {
            $saved = Get-Content $settingsPath -Raw | ConvertFrom-Json

            # Merge saved values with defaults (handles missing properties)
            foreach ($prop in $saved.PSObject.Properties) {
                if ($defaultState.ContainsKey($prop.Name)) {
                    $defaultState[$prop.Name] = $prop.Value
                }
            }
        }
        catch {
            Write-Warning "Failed to load GUI settings: $($_.Exception.Message)"
        }
    }

    return $defaultState
}
```

### Step 2: Update Save Function

Modify `Save-GuiState` to include new properties:

```powershell
function Save-GuiState {
    <#
    .SYNOPSIS
        Saves GUI state to settings file
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $settingsPath = Join-Path $PSScriptRoot 'Robocurse.settings.json'

    try {
        # Ensure all expected properties exist
        $stateToSave = @{
            WindowLeft = $State.WindowLeft
            WindowTop = $State.WindowTop
            WindowWidth = $State.WindowWidth
            WindowHeight = $State.WindowHeight
            WindowState = $State.WindowState
            SelectedProfile = $State.SelectedProfile
            WorkerCount = $State.WorkerCount
            ActivePanel = $State.ActivePanel        # NEW
            LastRun = $State.LastRun                # NEW
        }

        $stateToSave | ConvertTo-Json -Depth 5 | Out-File $settingsPath -Encoding UTF8
    }
    catch {
        Write-Warning "Failed to save GUI settings: $($_.Exception.Message)"
    }
}
```

### Step 3: Restore Active Panel on Load

In `Restore-GuiState` or the window Loaded handler:

```powershell
function Restore-GuiState {
    <#
    .SYNOPSIS
        Restores saved GUI state to the window
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Window,
        [Parameter(Mandatory)]
        [hashtable]$Controls
    )

    $state = Get-GuiState

    # Restore window position/size (existing logic)
    # ... bounds checking for off-screen windows ...

    $Window.Left = $state.WindowLeft
    $Window.Top = $state.WindowTop
    $Window.Width = $state.WindowWidth
    $Window.Height = $state.WindowHeight

    if ($state.WindowState -ne 'Minimized') {
        $Window.WindowState = $state.WindowState
    }

    # Restore worker count
    if ($Controls['sldWorkers']) {
        $Controls['sldWorkers'].Value = $state.WorkerCount
        $Controls['txtWorkerCount'].Text = $state.WorkerCount
    }

    # Restore selected profile
    if ($state.SelectedProfile -and $Controls['lstProfiles']) {
        # Find and select the profile
        $items = $Controls['lstProfiles'].Items
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($items[$i].Name -eq $state.SelectedProfile) {
                $Controls['lstProfiles'].SelectedIndex = $i
                break
            }
        }
    }

    # NEW: Restore active panel
    $validPanels = @('Profiles', 'Settings', 'Progress', 'Logs')
    if ($state.ActivePanel -and $state.ActivePanel -in $validPanels) {
        Set-ActivePanel -PanelName $state.ActivePanel
    }
    else {
        Set-ActivePanel -PanelName 'Profiles'  # Default
    }

    # Store state for later saving
    $script:CurrentGuiState = $state
}
```

### Step 4: Capture State on Close

Update the window Closing handler to capture current state:

```powershell
$window.Add_Closing({
    Invoke-SafeEventHandler -Handler {
        # Capture current window state
        $state = @{
            WindowLeft = $window.Left
            WindowTop = $window.Top
            WindowWidth = $window.Width
            WindowHeight = $window.Height
            WindowState = $window.WindowState.ToString()
            SelectedProfile = ''
            WorkerCount = [int]$script:Controls['sldWorkers'].Value
            ActivePanel = $script:ActivePanel  # NEW: Current panel
            LastRun = $script:CurrentGuiState.LastRun  # Preserve last run
        }

        # Get selected profile name
        if ($script:Controls['lstProfiles'].SelectedItem) {
            $state.SelectedProfile = $script:Controls['lstProfiles'].SelectedItem.Name
        }

        Save-GuiState -State $state
    } -EventName 'Window_Closing'
})
```

### Step 5: Update Last Run on Completion

Ensure last run is saved (may already be in task 07):

```powershell
function Save-LastRunSummary {
    param([hashtable]$Summary)

    # Get current state
    $state = Get-GuiState

    # Update last run
    $state.LastRun = $Summary

    # Save
    Save-GuiState -State $state
}
```

### Step 6: Bounds Checking for New Window Size

Update bounds checking for the smaller default window:

```powershell
# In Restore-GuiState, validate window is visible on screen
$screen = [System.Windows.Forms.Screen]::FromPoint(
    [System.Drawing.Point]::new($state.WindowLeft, $state.WindowTop)
)

# Ensure window is at least partially visible
$minVisible = 50
if ($state.WindowLeft + $minVisible -lt $screen.Bounds.Left -or
    $state.WindowLeft -gt $screen.Bounds.Right - $minVisible -or
    $state.WindowTop + $minVisible -lt $screen.Bounds.Top -or
    $state.WindowTop -gt $screen.Bounds.Bottom - $minVisible) {

    # Reset to center of screen
    $state.WindowLeft = ($screen.Bounds.Width - $state.WindowWidth) / 2
    $state.WindowTop = ($screen.Bounds.Height - $state.WindowHeight) / 2
}

# Ensure minimum size
$state.WindowWidth = [Math]::Max($state.WindowWidth, 500)
$state.WindowHeight = [Math]::Max($state.WindowHeight, 400)
```

### Step 7: Handle Settings Migration

For users upgrading from old version, handle missing properties gracefully:

```powershell
# In Get-GuiState, after loading saved settings:

# Migration: If window size is old default (1100x800), update to new default
if ($defaultState.WindowWidth -eq 1100 -and $defaultState.WindowHeight -eq 800) {
    Write-Verbose "Migrating window size to new defaults"
    $defaultState.WindowWidth = 650
    $defaultState.WindowHeight = 550
}

# Migration: If ActivePanel is missing, default to Profiles
if (-not $defaultState.ActivePanel) {
    $defaultState.ActivePanel = 'Profiles'
}
```

## Settings File Structure (After Update)

```json
{
  "WindowLeft": 100,
  "WindowTop": 100,
  "WindowWidth": 650,
  "WindowHeight": 550,
  "WindowState": "Normal",
  "SelectedProfile": "DailyBackup",
  "WorkerCount": 4,
  "ActivePanel": "Progress",
  "LastRun": {
    "Timestamp": "2024-01-15T14:32:45",
    "ProfilesRun": ["DailyBackup"],
    "ChunksTotal": 47,
    "ChunksCompleted": 47,
    "ChunksFailed": 0,
    "BytesCopied": 1234567890,
    "Duration": "01:23:45",
    "Status": "Success"
  }
}
```

## Tests to Write

**File**: `tests/Unit/GuiStatePersistence.Tests.ps1` (new file)

### Test: Get-GuiState Function

```powershell
Describe 'Get-GuiState' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\src\Robocurse\Public\GuiSettings.ps1')
    }

    BeforeEach {
        $script:TestSettingsPath = Join-Path $TestDrive 'test-settings.json'
        Mock Get-GuiSettingsPath { return $script:TestSettingsPath }
    }

    Context 'when settings file does not exist' {
        It 'should return default values' {
            $state = Get-GuiState

            $state.WindowWidth | Should -Be 650
            $state.WindowHeight | Should -Be 550
            $state.ActivePanel | Should -Be 'Profiles'
            $state.WorkerCount | Should -Be 4
        }

        It 'should have null LastRun by default' {
            $state = Get-GuiState

            $state.LastRun | Should -BeNullOrEmpty
        }
    }

    Context 'when settings file exists' {
        BeforeEach {
            @{
                WindowWidth = 800
                WindowHeight = 600
                ActivePanel = 'Progress'
                WorkerCount = 8
                LastRun = @{ Status = 'Success' }
            } | ConvertTo-Json -Depth 5 | Out-File $script:TestSettingsPath
        }

        It 'should load saved values' {
            $state = Get-GuiState

            $state.WindowWidth | Should -Be 800
            $state.WindowHeight | Should -Be 600
            $state.ActivePanel | Should -Be 'Progress'
            $state.WorkerCount | Should -Be 8
        }

        It 'should load LastRun data' {
            $state = Get-GuiState

            $state.LastRun.Status | Should -Be 'Success'
        }
    }

    Context 'when migrating from old settings' {
        BeforeEach {
            # Old format without new properties
            @{
                WindowWidth = 1100
                WindowHeight = 800
                WorkerCount = 4
            } | ConvertTo-Json | Out-File $script:TestSettingsPath
        }

        It 'should add missing ActivePanel with default' {
            $state = Get-GuiState

            $state.ActivePanel | Should -Be 'Profiles'
        }

        It 'should migrate old window size to new defaults' {
            $state = Get-GuiState

            # Old 1100x800 should be detected and migrated
            $state.WindowWidth | Should -Be 650
            $state.WindowHeight | Should -Be 550
        }
    }

    Context 'when settings file is corrupted' {
        BeforeEach {
            'not valid json { broken' | Out-File $script:TestSettingsPath
        }

        It 'should return defaults without throwing' {
            { Get-GuiState } | Should -Not -Throw
            $state = Get-GuiState
            $state.WindowWidth | Should -Be 650
        }
    }
}
```

### Test: Save-GuiState Function

```powershell
Describe 'Save-GuiState' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\src\Robocurse\Public\GuiSettings.ps1')
    }

    BeforeEach {
        $script:TestSettingsPath = Join-Path $TestDrive 'test-settings.json'
        Mock Get-GuiSettingsPath { return $script:TestSettingsPath }
    }

    It 'should save all properties' {
        $state = @{
            WindowLeft = 100
            WindowTop = 200
            WindowWidth = 700
            WindowHeight = 500
            WindowState = 'Normal'
            SelectedProfile = 'TestProfile'
            WorkerCount = 6
            ActivePanel = 'Settings'
            LastRun = @{
                Timestamp = '2024-01-15T10:00:00'
                Status = 'Success'
            }
        }

        Save-GuiState -State $state

        $saved = Get-Content $script:TestSettingsPath -Raw | ConvertFrom-Json
        $saved.WindowWidth | Should -Be 700
        $saved.ActivePanel | Should -Be 'Settings'
        $saved.LastRun.Status | Should -Be 'Success'
    }

    It 'should handle LastRun with nested data' {
        $state = @{
            WindowWidth = 650
            WindowHeight = 550
            ActivePanel = 'Profiles'
            LastRun = @{
                ProfilesRun = @('Profile1', 'Profile2')
                ChunksTotal = 10
                ChunksCompleted = 8
            }
        }

        Save-GuiState -State $state

        $saved = Get-Content $script:TestSettingsPath -Raw | ConvertFrom-Json
        $saved.LastRun.ProfilesRun.Count | Should -Be 2
        $saved.LastRun.ChunksTotal | Should -Be 10
    }
}
```

### Test: Active Panel Validation

```powershell
Describe 'Active Panel Restoration' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\src\Robocurse\Public\GuiSettings.ps1')
        . (Join-Path $PSScriptRoot '..\..\src\Robocurse\Public\GuiMain.ps1')

        Mock Set-ActivePanel { param($PanelName) $script:RestoredPanel = $PanelName }
    }

    BeforeEach {
        $script:TestSettingsPath = Join-Path $TestDrive 'test-settings.json'
        Mock Get-GuiSettingsPath { return $script:TestSettingsPath }
        $script:RestoredPanel = $null
    }

    It 'should restore valid panel names' {
        @{ ActivePanel = 'Progress' } | ConvertTo-Json | Out-File $script:TestSettingsPath

        Restore-ActivePanel

        $script:RestoredPanel | Should -Be 'Progress'
    }

    It 'should default to Profiles for invalid panel name' {
        @{ ActivePanel = 'InvalidPanel' } | ConvertTo-Json | Out-File $script:TestSettingsPath

        Restore-ActivePanel

        $script:RestoredPanel | Should -Be 'Profiles'
    }

    It 'should default to Profiles when ActivePanel is null' {
        @{ WindowWidth = 650 } | ConvertTo-Json | Out-File $script:TestSettingsPath

        Restore-ActivePanel

        $script:RestoredPanel | Should -Be 'Profiles'
    }
}
```

### Test: Window Bounds Checking

```powershell
Describe 'Window Bounds Validation' {
    It 'should enforce minimum width of 500' {
        $state = @{ WindowWidth = 300; WindowHeight = 400 }

        $validated = Get-ValidatedWindowSize -State $state

        $validated.WindowWidth | Should -BeGreaterOrEqual 500
    }

    It 'should enforce minimum height of 400' {
        $state = @{ WindowWidth = 600; WindowHeight = 200 }

        $validated = Get-ValidatedWindowSize -State $state

        $validated.WindowHeight | Should -BeGreaterOrEqual 400
    }

    It 'should preserve valid sizes' {
        $state = @{ WindowWidth = 800; WindowHeight = 600 }

        $validated = Get-ValidatedWindowSize -State $state

        $validated.WindowWidth | Should -Be 800
        $validated.WindowHeight | Should -Be 600
    }
}
```

### Test: Round-Trip Persistence

```powershell
Describe 'State Persistence Round-Trip' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\src\Robocurse\Public\GuiSettings.ps1')
    }

    BeforeEach {
        $script:TestSettingsPath = Join-Path $TestDrive 'test-settings.json'
        Mock Get-GuiSettingsPath { return $script:TestSettingsPath }
    }

    It 'should survive save and load cycle' {
        $original = @{
            WindowLeft = 150
            WindowTop = 250
            WindowWidth = 720
            WindowHeight = 580
            WindowState = 'Maximized'
            SelectedProfile = 'MyProfile'
            WorkerCount = 3
            ActivePanel = 'Logs'
            LastRun = @{
                Timestamp = '2024-01-20T15:30:00'
                ProfilesRun = @('A', 'B')
                Status = 'PartialFailure'
            }
        }

        Save-GuiState -State $original
        $loaded = Get-GuiState

        $loaded.WindowWidth | Should -Be 720
        $loaded.ActivePanel | Should -Be 'Logs'
        $loaded.LastRun.Status | Should -Be 'PartialFailure'
        $loaded.LastRun.ProfilesRun | Should -Contain 'A'
    }
}
```

## Success Criteria

1. **Panel persists**: Closing on Progress panel, reopening shows Progress
2. **Window size persists**: New 650x550 size saved and restored
3. **Last run persists**: Last run summary survives restart
4. **Migration works**: Old settings files upgraded gracefully
5. **Bounds checking**: Window positioned correctly on multi-monitor
6. **Minimum size**: Window can't be restored smaller than 500x400
7. **No data loss**: Existing settings (profile, workers) still persist
8. **All unit tests pass**: GuiStatePersistence.Tests.ps1 passes completely

## Testing

1. Run app, switch to Settings panel, close
2. Reopen - verify Settings panel shows
3. Resize window, close
4. Reopen - verify size restored
5. Run a replication, close after completion
6. Reopen - verify last run shows in Progress panel
7. Delete settings file, run app
8. Verify defaults (Profiles panel, 650x550)
9. Test on multi-monitor - drag to second screen, close, reopen

## Notes

- **JSON depth**: Use `ConvertTo-Json -Depth 5` to properly serialize LastRun hashtable
- **WindowState enum**: Save as string ("Normal", "Maximized") not enum value
- **Minimized prevention**: Don't restore Minimized state - users expect visible window
- **Error handling**: Gracefully handle corrupt or missing settings file
- **$script:CurrentGuiState**: Track current state to preserve LastRun during close
