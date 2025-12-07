# Task: Fix Log Window Always-On-Top Behavior

## Objective
Remove the always-on-top behavior from the log viewer popup window so it behaves like a normal window that can be sent behind other applications.

## Problem Statement
The log viewer popup window (opened via "Pop Out" button or Ctrl+L) currently stays on top of ALL windows, including other applications. This is annoying when:
- User wants to reference other documentation while viewing logs
- User switches to another app but log window blocks their view
- Multiple monitors where user expects normal window stacking

## Root Cause
In `GuiLogWindow.ps1:31`, the window's `Owner` property is set:
```powershell
$script:LogWindow.Owner = $script:Window
```

In WPF, when a window has an `Owner`:
- **Modal windows** (`ShowDialog()`) - behaves correctly, blocking input to owner
- **Non-modal windows** (`Show()`) - the owned window ALWAYS stays on top of its owner

Since the log window uses `Show()` (non-modal), setting `Owner` causes it to always float above the main window, AND since the main window might be on top of other apps, the log window appears always-on-top of everything.

## Success Criteria
1. Log window can be sent behind other applications
2. Log window can be minimized independently
3. Log window still appears when initially opened (normal activation)
4. Log window remembers its position between open/close (optional enhancement)
5. Clicking main window does NOT auto-bring log window to front
6. All tests pass

## Research: Current Implementation

### Log Window Creation (GuiLogWindow.ps1:27-37)
```powershell
try {
    $script:LogWindow = Initialize-LogWindow
    if ($script:LogWindow) {
        # Set owner to main window so it stays on top of it
        $script:LogWindow.Owner = $script:Window

        # Show non-modal
        $script:LogWindow.Show()

        # Populate with current buffer contents
        Update-LogWindowContent
    }
}
```

### WPF Window.Owner Behavior
From Microsoft Docs:
> When a child window is opened by a parent window by calling Show, the child window has no relationship with the parent window. This means that:
> - The child window does not have a reference to the parent window.
> - The behavior of the child window is not affected by the behavior of the parent window; either window can cover the other, or be minimized, maximized, and restored independently of the other.
>
> **However**, when you set Owner:
> - The owned window is ALWAYS on top of its owner.
> - The owned window minimizes/restores with its owner.

This is exactly the bug - the comment says "so it stays on top of it" but that creates the always-on-top problem.

## Implementation Plan

### Step 1: Remove Owner Assignment
In `Show-LogWindow` (GuiLogWindow.ps1), remove the Owner line:

```powershell
function Show-LogWindow {
    [CmdletBinding()]
    param()

    # If window exists and is loaded, just bring to front
    if ($script:LogWindow -and $script:LogWindow.IsLoaded) {
        $script:LogWindow.Activate()
        return
    }

    # Create new window
    try {
        $script:LogWindow = Initialize-LogWindow
        if ($script:LogWindow) {
            # REMOVED: $script:LogWindow.Owner = $script:Window
            # Setting Owner on non-modal windows causes always-on-top behavior.
            # For true modeless window behavior, we don't set Owner.

            # Show non-modal
            $script:LogWindow.Show()

            # Populate with current buffer contents
            Update-LogWindowContent
        }
    }
    catch {
        Write-GuiLog "Error showing log window: $($_.Exception.Message)"
        Show-GuiError -Message "Failed to open log window" -Details $_.Exception.Message
    }
}
```

### Step 2: Handle Main Window Closing
Without Owner, the log window won't auto-close when main window closes. Add explicit cleanup:

```powershell
# In GuiMain.ps1, Window_Closing handler (already exists around line 613):
$script:Window.Add_Closing({
    # ... existing cleanup ...
    Close-LogWindow  # This already exists - verify it's being called
})
```

Verify `Close-LogWindow` function works correctly without Owner:

```powershell
function Close-LogWindow {
    <#
    .SYNOPSIS
        Closes the log window if it's open
    #>
    [CmdletBinding()]
    param()

    if ($script:LogWindow) {
        try {
            $script:LogWindow.Close()
        }
        catch {
            # Window may already be closed
        }
        $script:LogWindow = $null
    }
}
```

### Step 3: Update Built Monolith
After fixing source, rebuild:
```powershell
.\build\Build-Robocurse.ps1
```

### Step 4: Optional Enhancement - Position Memory
Store window position when closing, restore when opening:

```powershell
$script:LogWindowPosition = $null

function Save-LogWindowPosition {
    if ($script:LogWindow -and $script:LogWindow.IsLoaded) {
        $script:LogWindowPosition = @{
            Left = $script:LogWindow.Left
            Top = $script:LogWindow.Top
            Width = $script:LogWindow.Width
            Height = $script:LogWindow.Height
            State = $script:LogWindow.WindowState
        }
    }
}

function Restore-LogWindowPosition {
    if ($script:LogWindowPosition -and $script:LogWindow) {
        $script:LogWindow.Left = $script:LogWindowPosition.Left
        $script:LogWindow.Top = $script:LogWindowPosition.Top
        $script:LogWindow.Width = $script:LogWindowPosition.Width
        $script:LogWindow.Height = $script:LogWindowPosition.Height
        # Don't restore Minimized state
        if ($script:LogWindowPosition.State -ne 'Minimized') {
            $script:LogWindow.WindowState = $script:LogWindowPosition.State
        }
    }
}

# In Initialize-LogWindowEventHandlers, add:
$Window.Add_Closing({
    Save-LogWindowPosition
})

# In Show-LogWindow, after creating window:
Restore-LogWindowPosition
```

## Test Plan

Create `tests/Unit/GuiLogWindowBehavior.Tests.ps1`:

```powershell
#Requires -Modules Pester

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

InModuleScope 'Robocurse' {
    Describe "Log Window Behavior Tests" {

        Context "Window Independence" {
            It "Should NOT set Owner property on log window" {
                # Check the source code doesn't set Owner
                $sourceFile = Join-Path $PSScriptRoot "..\..\src\Robocurse\Public\GuiLogWindow.ps1"
                $content = Get-Content $sourceFile -Raw

                # Should not have active Owner assignment (commented out is OK)
                $content | Should -Not -Match '\$script:LogWindow\.Owner\s*=\s*\$script:Window\s*$'
            }
        }

        Context "Close-LogWindow Function" {
            BeforeEach {
                # Mock log window
                $script:LogWindow = New-Object PSObject
                $script:LogWindow | Add-Member -MemberType NoteProperty -Name 'IsClosed' -Value $false
                $script:LogWindow | Add-Member -MemberType ScriptMethod -Name 'Close' -Value {
                    $this.IsClosed = $true
                }
            }

            It "Should close window and clear reference" {
                Close-LogWindow

                $script:LogWindow | Should -BeNullOrEmpty
            }

            It "Should handle already-closed window gracefully" {
                $script:LogWindow | Add-Member -MemberType ScriptMethod -Name 'Close' -Value {
                    throw "Window already closed"
                } -Force

                { Close-LogWindow } | Should -Not -Throw
                $script:LogWindow | Should -BeNullOrEmpty
            }
        }

        Context "Position Memory (if implemented)" {
            BeforeEach {
                $script:LogWindowPosition = $null
            }

            It "Should save window position" {
                $script:LogWindow = New-Object PSObject
                $script:LogWindow | Add-Member -NotePropertyName 'IsLoaded' -NotePropertyValue $true
                $script:LogWindow | Add-Member -NotePropertyName 'Left' -NotePropertyValue 100
                $script:LogWindow | Add-Member -NotePropertyName 'Top' -NotePropertyValue 200
                $script:LogWindow | Add-Member -NotePropertyName 'Width' -NotePropertyValue 800
                $script:LogWindow | Add-Member -NotePropertyName 'Height' -NotePropertyValue 600
                $script:LogWindow | Add-Member -NotePropertyName 'WindowState' -NotePropertyValue 'Normal'

                Save-LogWindowPosition

                $script:LogWindowPosition | Should -Not -BeNullOrEmpty
                $script:LogWindowPosition.Left | Should -Be 100
                $script:LogWindowPosition.Top | Should -Be 200
            }
        }
    }
}
```

## Files to Modify
1. `src/Robocurse/Public/GuiLogWindow.ps1` - Remove Owner assignment, add position memory (optional)
2. `tests/Unit/GuiLogWindowBehavior.Tests.ps1` - New test file

## Verification Commands
```powershell
.\scripts\run-tests.ps1
Invoke-Pester -Path tests\Unit\GuiLogWindowBehavior.Tests.ps1 -Output Detailed

# Rebuild monolith
.\build\Build-Robocurse.ps1
```

## Manual Testing
1. Open Robocurse GUI
2. Click "Pop Out" to open log window
3. Click on another application (browser, notepad, etc.)
4. Verify log window goes BEHIND the other application
5. Click on log window - verify it comes to front normally
6. Minimize log window - verify it minimizes independently
7. Close main Robocurse window - verify log window also closes

## Notes
- This is a one-line fix plus removing the comment
- The Owner pattern is CORRECT for modal dialogs (confirmation dialogs, etc.) - don't change those
- Only the log window uses `Show()` instead of `ShowDialog()` so only it has this issue
- Position memory is optional but nice for UX
- No UI changes required - purely behavioral fix
