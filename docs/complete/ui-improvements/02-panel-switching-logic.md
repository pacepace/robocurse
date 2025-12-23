# Task: Implement Panel Switching Logic

## Objective

Wire up the navigation rail buttons in `GuiMain.ps1` to switch between content panels. When a rail button is clicked, hide all panels except the selected one and update the button's visual state.

## Context

The navigation rail XAML has been created with RadioButton controls (btnNavProfiles, btnNavSettings, btnNavProgress, btnNavLogs) and content panels (panelProfiles, panelSettings, panelProgress, panelLogs). This task connects them with PowerShell event handlers.

## Files to Modify

| File | Action |
|------|--------|
| `src/Robocurse/Public/GuiMain.ps1` | Add panel switching event handlers |

## Research Required

### In Codebase
1. Read `src/Robocurse/Public/GuiMain.ps1` to understand:
   - How event handlers are currently wired (look for `Add_Click`, `Add_Loaded`, etc.)
   - The `Invoke-SafeEventHandler` wrapper pattern used for error handling
   - How control references are obtained from the XAML
   - The `$script:Controls` hashtable pattern

2. Read `src/Robocurse/Resources/MainWindow.xaml` (after task 01) to confirm:
   - Rail button names: btnNavProfiles, btnNavSettings, btnNavProgress, btnNavLogs
   - Panel names: panelProfiles, panelSettings, panelProgress, panelLogs

### Key Code Patterns from GuiMain.ps1

```powershell
# Control references are stored in $script:Controls hashtable
$script:Controls = @{}
$controlNames = @('lstProfiles', 'btnRunAll', ...)
foreach ($name in $controlNames) {
    $script:Controls[$name] = $window.FindName($name)
}

# Event handlers use this wrapper for error handling
function Invoke-SafeEventHandler {
    param([scriptblock]$Handler, [string]$EventName)
    try { & $Handler }
    catch { Show-GuiError -Message "Error in $EventName" -Details $_.Exception.Message }
}

# Events are wired like this
$script:Controls['btnRunAll'].Add_Click({
    Invoke-SafeEventHandler -Handler { Start-GuiReplication -AllProfiles } -EventName 'RunAll_Click'
})
```

## Implementation Steps

### Step 1: Add New Control Names to Collection

In the `Initialize-RobocurseGui` function, find where control names are collected and add the new rail buttons and panels:

```powershell
$controlNames = @(
    # Existing controls...
    'lstProfiles', 'btnAddProfile', 'btnRemoveProfile',
    # ... etc ...

    # NEW: Navigation rail buttons
    'btnNavProfiles', 'btnNavSettings', 'btnNavProgress', 'btnNavLogs',

    # NEW: Content panels
    'panelProfiles', 'panelSettings', 'panelProgress', 'panelLogs'
)
```

### Step 2: Create Panel Switching Function

Add a new function to handle panel visibility:

```powershell
function Set-ActivePanel {
    <#
    .SYNOPSIS
        Switches to the specified panel, hiding all others
    .PARAMETER PanelName
        Name of the panel to show: 'Profiles', 'Settings', 'Progress', or 'Logs'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Profiles', 'Settings', 'Progress', 'Logs')]
        [string]$PanelName
    )

    # Define all panels
    $panels = @('panelProfiles', 'panelSettings', 'panelProgress', 'panelLogs')
    $targetPanel = "panel$PanelName"

    # Hide all panels, show target
    foreach ($panel in $panels) {
        if ($script:Controls[$panel]) {
            if ($panel -eq $targetPanel) {
                $script:Controls[$panel].Visibility = [System.Windows.Visibility]::Visible
            }
            else {
                $script:Controls[$panel].Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
    }

    # Update rail button states (RadioButton handles this automatically via GroupName,
    # but explicitly set for programmatic switches)
    $buttons = @{
        'Profiles' = 'btnNavProfiles'
        'Settings' = 'btnNavSettings'
        'Progress' = 'btnNavProgress'
        'Logs'     = 'btnNavLogs'
    }

    foreach ($name in $buttons.Keys) {
        $btn = $script:Controls[$buttons[$name]]
        if ($btn) {
            $btn.IsChecked = ($name -eq $PanelName)
        }
    }

    # Store active panel for persistence
    $script:ActivePanel = $PanelName

    Write-RobocurseLog -Message "Switched to panel: $PanelName" -Level 'Debug' -Component 'GUI'
}
```

### Step 3: Wire Rail Button Events

In `Initialize-EventHandlers` function, add click handlers for rail buttons:

```powershell
# Navigation Rail - Panel Switching
# Note: RadioButton uses Checked event, not Click
$script:Controls['btnNavProfiles'].Add_Checked({
    Invoke-SafeEventHandler -Handler {
        Set-ActivePanel -PanelName 'Profiles'
    } -EventName 'NavProfiles_Checked'
})

$script:Controls['btnNavSettings'].Add_Checked({
    Invoke-SafeEventHandler -Handler {
        Set-ActivePanel -PanelName 'Settings'
    } -EventName 'NavSettings_Checked'
})

$script:Controls['btnNavProgress'].Add_Checked({
    Invoke-SafeEventHandler -Handler {
        Set-ActivePanel -PanelName 'Progress'
    } -EventName 'NavProgress_Checked'
})

$script:Controls['btnNavLogs'].Add_Checked({
    Invoke-SafeEventHandler -Handler {
        Set-ActivePanel -PanelName 'Logs'
    } -EventName 'NavLogs_Checked'
})
```

### Step 4: Set Default Panel on Load

In the window Loaded event handler, set the initial panel:

```powershell
$window.Add_Loaded({
    Invoke-SafeEventHandler -Handler {
        # ... existing load logic ...

        # Set initial panel (or restore from saved state)
        $savedPanel = Get-GuiState | Select-Object -ExpandProperty ActivePanel -ErrorAction SilentlyContinue
        if ($savedPanel -and $savedPanel -in @('Profiles', 'Settings', 'Progress', 'Logs')) {
            Set-ActivePanel -PanelName $savedPanel
        }
        else {
            Set-ActivePanel -PanelName 'Profiles'  # Default
        }
    } -EventName 'Window_Loaded'
})
```

### Step 5: Auto-Switch to Progress When Running

When replication starts, automatically switch to Progress panel so user can watch:

Find the existing `Start-GuiReplication` function call and add:

```powershell
# In btnRunAll click handler or Start-GuiReplication function
Set-ActivePanel -PanelName 'Progress'
```

### Step 6: Handle Edge Cases

**Null checks**: Always verify controls exist before accessing:
```powershell
if ($script:Controls['btnNavProfiles']) {
    $script:Controls['btnNavProfiles'].Add_Checked({ ... })
}
```

**Initialization order**: Ensure Set-ActivePanel isn't called before controls are loaded.

## Tests to Write

**File**: `tests/Unit/GuiPanelSwitching.Tests.ps1` (new file)

The `Set-ActivePanel` function contains testable logic that doesn't require a live window.

### Test: Set-ActivePanel Function

```powershell
Describe 'Set-ActivePanel' {
    BeforeAll {
        # Load the module
        . (Join-Path $PSScriptRoot '..\..\src\Robocurse\Public\GuiMain.ps1')

        # Mock the controls with test doubles
        $script:Controls = @{
            'panelProfiles' = [PSCustomObject]@{ Visibility = 'Collapsed' }
            'panelSettings' = [PSCustomObject]@{ Visibility = 'Collapsed' }
            'panelProgress' = [PSCustomObject]@{ Visibility = 'Collapsed' }
            'panelLogs'     = [PSCustomObject]@{ Visibility = 'Collapsed' }
            'btnNavProfiles' = [PSCustomObject]@{ IsChecked = $false }
            'btnNavSettings' = [PSCustomObject]@{ IsChecked = $false }
            'btnNavProgress' = [PSCustomObject]@{ IsChecked = $false }
            'btnNavLogs'     = [PSCustomObject]@{ IsChecked = $false }
        }

        # Mock logging
        Mock Write-RobocurseLog { }
    }

    Context 'when switching to Profiles panel' {
        BeforeEach {
            Set-ActivePanel -PanelName 'Profiles'
        }

        It 'should show Profiles panel' {
            $script:Controls['panelProfiles'].Visibility | Should -Be 'Visible'
        }

        It 'should hide Settings panel' {
            $script:Controls['panelSettings'].Visibility | Should -Be 'Collapsed'
        }

        It 'should hide Progress panel' {
            $script:Controls['panelProgress'].Visibility | Should -Be 'Collapsed'
        }

        It 'should hide Logs panel' {
            $script:Controls['panelLogs'].Visibility | Should -Be 'Collapsed'
        }

        It 'should check Profiles nav button' {
            $script:Controls['btnNavProfiles'].IsChecked | Should -BeTrue
        }

        It 'should uncheck other nav buttons' {
            $script:Controls['btnNavSettings'].IsChecked | Should -BeFalse
            $script:Controls['btnNavProgress'].IsChecked | Should -BeFalse
            $script:Controls['btnNavLogs'].IsChecked | Should -BeFalse
        }

        It 'should set ActivePanel script variable' {
            $script:ActivePanel | Should -Be 'Profiles'
        }
    }

    Context 'when switching to Settings panel' {
        BeforeEach {
            Set-ActivePanel -PanelName 'Settings'
        }

        It 'should show only Settings panel' {
            $script:Controls['panelSettings'].Visibility | Should -Be 'Visible'
            $script:Controls['panelProfiles'].Visibility | Should -Be 'Collapsed'
            $script:Controls['panelProgress'].Visibility | Should -Be 'Collapsed'
            $script:Controls['panelLogs'].Visibility | Should -Be 'Collapsed'
        }
    }

    Context 'when switching to Progress panel' {
        BeforeEach {
            Set-ActivePanel -PanelName 'Progress'
        }

        It 'should show only Progress panel' {
            $script:Controls['panelProgress'].Visibility | Should -Be 'Visible'
            $script:Controls['panelProfiles'].Visibility | Should -Be 'Collapsed'
            $script:Controls['panelSettings'].Visibility | Should -Be 'Collapsed'
            $script:Controls['panelLogs'].Visibility | Should -Be 'Collapsed'
        }
    }

    Context 'when switching to Logs panel' {
        BeforeEach {
            Set-ActivePanel -PanelName 'Logs'
        }

        It 'should show only Logs panel' {
            $script:Controls['panelLogs'].Visibility | Should -Be 'Visible'
            $script:Controls['panelProfiles'].Visibility | Should -Be 'Collapsed'
            $script:Controls['panelSettings'].Visibility | Should -Be 'Collapsed'
            $script:Controls['panelProgress'].Visibility | Should -Be 'Collapsed'
        }
    }

    Context 'with invalid panel name' {
        It 'should throw for invalid panel name' {
            { Set-ActivePanel -PanelName 'InvalidPanel' } | Should -Throw
        }
    }

    Context 'with missing controls' {
        BeforeEach {
            $script:Controls['panelProfiles'] = $null
        }

        It 'should handle missing controls gracefully' {
            { Set-ActivePanel -PanelName 'Settings' } | Should -Not -Throw
        }
    }
}
```

### Test: Panel State Consistency

```powershell
Describe 'Panel State Consistency' {
    BeforeAll {
        # Setup mocks as above
    }

    It 'should always have exactly one panel visible' {
        foreach ($panel in @('Profiles', 'Settings', 'Progress', 'Logs')) {
            Set-ActivePanel -PanelName $panel

            $visibleCount = @(
                $script:Controls['panelProfiles'].Visibility,
                $script:Controls['panelSettings'].Visibility,
                $script:Controls['panelProgress'].Visibility,
                $script:Controls['panelLogs'].Visibility
            ) | Where-Object { $_ -eq 'Visible' } | Measure-Object | Select-Object -ExpandProperty Count

            $visibleCount | Should -Be 1 -Because "switching to $panel should leave exactly one panel visible"
        }
    }

    It 'should always have exactly one nav button checked' {
        foreach ($panel in @('Profiles', 'Settings', 'Progress', 'Logs')) {
            Set-ActivePanel -PanelName $panel

            $checkedCount = @(
                $script:Controls['btnNavProfiles'].IsChecked,
                $script:Controls['btnNavSettings'].IsChecked,
                $script:Controls['btnNavProgress'].IsChecked,
                $script:Controls['btnNavLogs'].IsChecked
            ) | Where-Object { $_ -eq $true } | Measure-Object | Select-Object -ExpandProperty Count

            $checkedCount | Should -Be 1 -Because "switching to $panel should leave exactly one button checked"
        }
    }
}
```

## Success Criteria

1. **Rail buttons work**: Clicking each rail button shows only that panel
2. **Only one panel visible**: At any time, exactly one panel has Visibility="Visible"
3. **Button state updates**: Selected rail button shows highlighted (checked) state
4. **Default panel**: On startup, Profiles panel is shown (or last saved panel)
5. **Auto-switch**: When Run is clicked, switches to Progress panel
6. **No errors**: No exceptions when switching panels
7. **Logging**: Panel switches are logged at Debug level
8. **All unit tests pass**: GuiPanelSwitching.Tests.ps1 passes completely

## Testing

1. Build: `.\build\Build-Robocurse.ps1`
2. Run: `.\dist\Robocurse.ps1`
3. Click each rail button - verify correct panel shows
4. Verify only one panel visible at a time
5. Click Run - verify auto-switch to Progress
6. Close and reopen - verify last panel is restored (after task 09)

## Notes

- **RadioButton vs Button**: RadioButtons have `Checked` event, not `Click`. The GroupName ensures mutual exclusivity.
- **Visibility enum**: Must use `[System.Windows.Visibility]::Visible` and `::Collapsed` - not strings.
- **Script scope**: `$script:ActivePanel` stores state for persistence (task 09).
- **WPF threading**: Panel switching should happen on UI thread (already handled by event handlers).
