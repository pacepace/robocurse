# Task: Implement Keyboard Shortcuts

## Objective

Add keyboard shortcuts for common actions: Ctrl+L (open log popup), Ctrl+R (run selected profiles), Escape (stop replication), and 1-4 (switch panels).

## Context

Keyboard shortcuts improve efficiency for power users and make the app feel more professional. The shortcuts should work regardless of which panel is active.

## Files to Modify

| File | Action |
|------|--------|
| `src/Robocurse/Public/GuiMain.ps1` | Add keyboard event handler to main window |

## Research Required

### In Codebase
1. Read `src/Robocurse/Public/GuiMain.ps1`:
   - How the main window is initialized
   - Existing event handler patterns
   - Window reference (`$window` variable)

2. Read `src/Robocurse/Public/GuiLogWindow.ps1`:
   - `Show-LogWindow` function signature

3. Read `src/Robocurse/Public/GuiReplication.ps1`:
   - `Start-GuiReplication` function
   - Stop replication mechanism

### WPF Keyboard Events

WPF windows handle keyboard input via the `PreviewKeyDown` or `KeyDown` events:

```powershell
$window.Add_PreviewKeyDown({
    param($sender, $e)
    # $e.Key contains the key pressed
    # $e.KeyboardDevice.Modifiers contains Ctrl/Shift/Alt state
})
```

Key codes are in `[System.Windows.Input.Key]`:
- `D1`, `D2`, `D3`, `D4` - Number keys 1-4
- `L`, `R` - Letter keys
- `Escape` - Escape key

Modifier check:
```powershell
$ctrl = $e.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control
```

## Implementation Steps

### Step 1: Add PreviewKeyDown Handler

In `Initialize-RobocurseGui`, after the window is created but before ShowDialog:

```powershell
# Keyboard shortcuts
$window.Add_PreviewKeyDown({
    param($sender, $e)

    Invoke-SafeEventHandler -Handler {
        $ctrl = $e.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control

        # Ctrl+L: Open log popup
        if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::L) {
            Show-LogWindow
            $e.Handled = $true
            return
        }

        # Ctrl+R: Run selected profiles
        if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::R) {
            # Only if not already running
            if ($script:Controls['btnRunSelected'].IsEnabled) {
                Start-GuiReplication -SelectedOnly
            }
            $e.Handled = $true
            return
        }

        # Escape: Stop replication (with confirmation)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            # Only if running
            if ($script:Controls['btnStop'].IsEnabled) {
                $confirm = Show-ConfirmDialog -Title "Stop Replication" `
                    -Message "Are you sure you want to stop the running replication?" `
                    -ConfirmText "Stop" -CancelText "Continue"
                if ($confirm) {
                    Stop-GuiReplication
                }
            }
            $e.Handled = $true
            return
        }

        # 1-4: Switch panels (without Ctrl)
        if (-not $ctrl) {
            switch ($e.Key) {
                ([System.Windows.Input.Key]::D1) {
                    Set-ActivePanel -PanelName 'Profiles'
                    $e.Handled = $true
                }
                ([System.Windows.Input.Key]::D2) {
                    Set-ActivePanel -PanelName 'Settings'
                    $e.Handled = $true
                }
                ([System.Windows.Input.Key]::D3) {
                    Set-ActivePanel -PanelName 'Progress'
                    $e.Handled = $true
                }
                ([System.Windows.Input.Key]::D4) {
                    Set-ActivePanel -PanelName 'Logs'
                    $e.Handled = $true
                }
            }
        }
    } -EventName 'Window_PreviewKeyDown'
})
```

### Step 2: Handle TextBox Focus Edge Case

When a TextBox has focus, number keys should type into the TextBox, not switch panels. Check for focused TextBox:

```powershell
# 1-4: Switch panels (only if not in a TextBox)
if (-not $ctrl) {
    # Check if a TextBox has focus
    $focusedElement = [System.Windows.Input.Keyboard]::FocusedElement
    $isTextBox = $focusedElement -is [System.Windows.Controls.TextBox]

    if (-not $isTextBox) {
        switch ($e.Key) {
            ([System.Windows.Input.Key]::D1) {
                Set-ActivePanel -PanelName 'Profiles'
                $e.Handled = $true
            }
            # ... etc
        }
    }
}
```

### Step 3: Add Keyboard Hint to Tooltips

Update button tooltips to show keyboard shortcuts:

```xml
<!-- In MainWindow.xaml -->
<Button x:Name="btnRunSelected" Content="▶ Run Sel"
        ToolTip="Run selected profile (Ctrl+R)"/>

<Button x:Name="btnStop" Content="⏹ Stop"
        ToolTip="Stop replication (Escape)"/>

<!-- Rail buttons -->
<RadioButton x:Name="btnNavProfiles" ToolTip="Profiles (1)"/>
<RadioButton x:Name="btnNavSettings" ToolTip="Settings (2)"/>
<RadioButton x:Name="btnNavProgress" ToolTip="Progress (3)"/>
<RadioButton x:Name="btnNavLogs" ToolTip="Logs (4)"/>
```

Or update tooltips in PowerShell:

```powershell
# In Initialize-RobocurseGui, after controls are loaded:
$script:Controls['btnRunSelected'].ToolTip = "Run selected profile (Ctrl+R)"
$script:Controls['btnStop'].ToolTip = "Stop replication (Escape)"
$script:Controls['btnNavProfiles'].ToolTip = "Profiles (1)"
$script:Controls['btnNavSettings'].ToolTip = "Settings (2)"
$script:Controls['btnNavProgress'].ToolTip = "Progress (3)"
$script:Controls['btnNavLogs'].ToolTip = "Logs (4)"
```

### Step 4: Log Popup Shortcut in Log Panel

Update the "Pop Out" button tooltip:

```powershell
$script:Controls['btnLogPopOut'].ToolTip = "Open log in separate window (Ctrl+L)"
```

### Step 5: Consider NumPad Keys

For consistency, also handle NumPad 1-4:

```powershell
switch ($e.Key) {
    { $_ -in @([System.Windows.Input.Key]::D1, [System.Windows.Input.Key]::NumPad1) } {
        Set-ActivePanel -PanelName 'Profiles'
        $e.Handled = $true
    }
    { $_ -in @([System.Windows.Input.Key]::D2, [System.Windows.Input.Key]::NumPad2) } {
        Set-ActivePanel -PanelName 'Settings'
        $e.Handled = $true
    }
    # ... etc
}
```

## Shortcut Summary

| Shortcut | Action | Condition |
|----------|--------|-----------|
| `1` | Switch to Profiles panel | When not in TextBox |
| `2` | Switch to Settings panel | When not in TextBox |
| `3` | Switch to Progress panel | When not in TextBox |
| `4` | Switch to Logs panel | When not in TextBox |
| `Ctrl+L` | Open log popup window | Always |
| `Ctrl+R` | Run selected profiles | When not running |
| `Escape` | Stop replication | When running (with confirm) |

## Tests to Write

**File**: `tests/Unit/GuiKeyboardShortcuts.Tests.ps1` (new file)

The keyboard handler logic can be extracted into a testable function. Test the decision logic without requiring a live WPF window.

### Test: Keyboard Handler Logic

```powershell
Describe 'Invoke-KeyboardShortcut' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\src\Robocurse\Public\GuiMain.ps1')

        # Mock controls
        $script:Controls = @{
            'btnRunSelected' = [PSCustomObject]@{ IsEnabled = $true }
            'btnStop' = [PSCustomObject]@{ IsEnabled = $false }
        }

        # Track function calls
        $script:CalledFunctions = @()

        Mock Show-LogWindow { $script:CalledFunctions += 'Show-LogWindow' }
        Mock Start-GuiReplication { $script:CalledFunctions += 'Start-GuiReplication' }
        Mock Stop-GuiReplication { $script:CalledFunctions += 'Stop-GuiReplication' }
        Mock Set-ActivePanel { param($PanelName) $script:CalledFunctions += "Set-ActivePanel:$PanelName" }
        Mock Show-ConfirmDialog { return $true }
    }

    BeforeEach {
        $script:CalledFunctions = @()
    }

    Context 'Ctrl+L shortcut' {
        It 'should open log window' {
            Invoke-KeyboardShortcut -Key 'L' -Ctrl $true -IsTextBoxFocused $false

            $script:CalledFunctions | Should -Contain 'Show-LogWindow'
        }

        It 'should work even when in TextBox' {
            Invoke-KeyboardShortcut -Key 'L' -Ctrl $true -IsTextBoxFocused $true

            $script:CalledFunctions | Should -Contain 'Show-LogWindow'
        }
    }

    Context 'Ctrl+R shortcut' {
        It 'should start replication when not running' {
            $script:Controls['btnRunSelected'].IsEnabled = $true

            Invoke-KeyboardShortcut -Key 'R' -Ctrl $true -IsTextBoxFocused $false

            $script:CalledFunctions | Should -Contain 'Start-GuiReplication'
        }

        It 'should not start replication when already running' {
            $script:Controls['btnRunSelected'].IsEnabled = $false

            Invoke-KeyboardShortcut -Key 'R' -Ctrl $true -IsTextBoxFocused $false

            $script:CalledFunctions | Should -Not -Contain 'Start-GuiReplication'
        }
    }

    Context 'Escape shortcut' {
        It 'should stop replication when running' {
            $script:Controls['btnStop'].IsEnabled = $true

            Invoke-KeyboardShortcut -Key 'Escape' -Ctrl $false -IsTextBoxFocused $false

            $script:CalledFunctions | Should -Contain 'Stop-GuiReplication'
        }

        It 'should not stop when not running' {
            $script:Controls['btnStop'].IsEnabled = $false

            Invoke-KeyboardShortcut -Key 'Escape' -Ctrl $false -IsTextBoxFocused $false

            $script:CalledFunctions | Should -Not -Contain 'Stop-GuiReplication'
        }
    }

    Context 'Number key panel switching' {
        It 'should switch to Profiles on key 1' {
            Invoke-KeyboardShortcut -Key 'D1' -Ctrl $false -IsTextBoxFocused $false

            $script:CalledFunctions | Should -Contain 'Set-ActivePanel:Profiles'
        }

        It 'should switch to Settings on key 2' {
            Invoke-KeyboardShortcut -Key 'D2' -Ctrl $false -IsTextBoxFocused $false

            $script:CalledFunctions | Should -Contain 'Set-ActivePanel:Settings'
        }

        It 'should switch to Progress on key 3' {
            Invoke-KeyboardShortcut -Key 'D3' -Ctrl $false -IsTextBoxFocused $false

            $script:CalledFunctions | Should -Contain 'Set-ActivePanel:Progress'
        }

        It 'should switch to Logs on key 4' {
            Invoke-KeyboardShortcut -Key 'D4' -Ctrl $false -IsTextBoxFocused $false

            $script:CalledFunctions | Should -Contain 'Set-ActivePanel:Logs'
        }

        It 'should NOT switch panels when TextBox is focused' {
            Invoke-KeyboardShortcut -Key 'D1' -Ctrl $false -IsTextBoxFocused $true

            $script:CalledFunctions | Should -Not -Match 'Set-ActivePanel'
        }

        It 'should handle NumPad keys' {
            Invoke-KeyboardShortcut -Key 'NumPad1' -Ctrl $false -IsTextBoxFocused $false

            $script:CalledFunctions | Should -Contain 'Set-ActivePanel:Profiles'
        }
    }
}
```

### Test: Key Mapping

```powershell
Describe 'Keyboard Shortcut Key Mapping' {
    It 'should map D1 and NumPad1 to same action' {
        $d1Panel = Get-PanelForKey -Key 'D1'
        $np1Panel = Get-PanelForKey -Key 'NumPad1'

        $d1Panel | Should -Be $np1Panel
        $d1Panel | Should -Be 'Profiles'
    }

    It 'should map all number keys correctly' {
        Get-PanelForKey -Key 'D1' | Should -Be 'Profiles'
        Get-PanelForKey -Key 'D2' | Should -Be 'Settings'
        Get-PanelForKey -Key 'D3' | Should -Be 'Progress'
        Get-PanelForKey -Key 'D4' | Should -Be 'Logs'
    }

    It 'should return $null for unmapped keys' {
        Get-PanelForKey -Key 'D5' | Should -BeNullOrEmpty
        Get-PanelForKey -Key 'A' | Should -BeNullOrEmpty
    }
}
```

### Test: Tooltip Updates

```powershell
Describe 'Keyboard Shortcut Tooltips' {
    BeforeAll {
        $xamlPath = Join-Path $PSScriptRoot '..\..\src\Robocurse\Resources\MainWindow.xaml'
        $xamlContent = Get-Content $xamlPath -Raw
    }

    It 'should have Ctrl+R hint on run button' {
        # Check XAML or post-load tooltip
        $xamlContent | Should -Match 'btnRunSelected.*ToolTip.*Ctrl\+R'
    }

    It 'should have Escape hint on stop button' {
        $xamlContent | Should -Match 'btnStop.*ToolTip.*Escape'
    }

    It 'should have number hints on nav buttons' {
        $xamlContent | Should -Match 'btnNavProfiles.*ToolTip.*\(1\)'
        $xamlContent | Should -Match 'btnNavSettings.*ToolTip.*\(2\)'
    }
}
```

## Success Criteria

1. **Ctrl+L opens logs**: From any panel, Ctrl+L opens log popup
2. **Ctrl+R runs**: When idle, Ctrl+R starts selected profile replication
3. **Escape stops**: When running, Escape prompts to stop
4. **1-4 switch panels**: Number keys change active panel
5. **TextBox exception**: Number keys don't switch panels when typing
6. **Tooltips updated**: Shortcuts shown in button tooltips
7. **No conflicts**: Shortcuts don't interfere with normal typing
8. **NumPad works**: Both main number row and numpad work
9. **All unit tests pass**: GuiKeyboardShortcuts.Tests.ps1 passes completely

## Testing

1. Build and run
2. Press 1, 2, 3, 4 - verify panel switching
3. Click in a TextBox, press 1 - verify number types, doesn't switch
4. Press Ctrl+L - verify log popup opens
5. Press Ctrl+R - verify replication starts
6. While running, press Escape - verify confirmation dialog
7. Hover over buttons - verify tooltips show shortcuts
8. Test with NumPad keys

## Notes

- **PreviewKeyDown vs KeyDown**: Use `PreviewKeyDown` to catch keys before controls handle them. Set `$e.Handled = $true` to prevent further processing.
- **Modal dialogs**: Shortcuts won't work when a modal dialog is open (by design).
- **Focus management**: If focus is in a ComboBox or other control, some keys may be consumed.
- **Escape in dialogs**: The Escape-to-stop shortcut shouldn't conflict with Escape-to-close dialogs since dialogs are modal.
