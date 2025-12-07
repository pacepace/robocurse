# Task: Per-Profile Error Summary

## Objective
Add a per-profile error counter to the progress panel that shows error breakdown by profile during multi-profile replication runs.

## Problem Statement
Currently during replication:
- Status bar shows total error count "(5 error(s))"
- No breakdown of which profiles are failing
- User must wait for completion or dig through logs to understand error distribution
- If running 5 profiles and only 1 is failing, this is not visible

## Success Criteria
1. Progress panel shows per-profile error breakdown during replication
2. Display format: "Profile A: 2 errors, Profile B: 0, Profile C: 3"
3. Only shows when multiple profiles are being run
4. Updates in real-time as errors occur
5. Color-coded: green for 0 errors, orange/red for errors
6. Visible in the progress summary area (not just status bar)
7. All tests pass

## Research: Current Implementation

### Profile Results Tracking (OrchestrationCore.ps1)
```csharp
// ProfileResults is a ConcurrentQueue that stores completed profile summaries
public ConcurrentQueue<object> ProfileResults { get; private set; }
```

From Complete-CurrentProfile (JobManagement.ps1:804-818):
```powershell
$profileResult = [PSCustomObject]@{
    Name = $state.CurrentProfile.Name
    Status = if ($failedChunksArray.Count -gt 0) { 'Warning' } else { 'Success' }
    ChunksComplete = $totalCompleted
    ChunksSkipped = $skippedChunkCount
    ChunksTotal = $state.TotalChunks
    ChunksFailed = $failedChunksArray.Count
    # ... more fields
}
$state.ProfileResults.Enqueue($profileResult)
```

### Current Progress Panel Summary (MainWindow.xaml:528-555)
```xml
<Border Grid.Row="0" Background="#252525" CornerRadius="4" Padding="10" Margin="0,0,0,10">
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="150"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Column="0">
            <TextBlock x:Name="txtProfileProgress" Text="Profile: --"/>
            <ProgressBar x:Name="pbProfile" .../>
        </StackPanel>
        <!-- Overall, ETA, Speed, Chunks... -->
    </Grid>
</Border>
```

### Error Tracking Per-Chunk (not per-profile)
Errors are currently tracked globally via `$script:GuiErrorCount` (GuiProgress.ps1:279).

## Implementation Plan

### Step 1: Add Per-Profile Error Tracking
Add script-level tracking in GuiProgress.ps1:

```powershell
# Per-profile error tracking (reset each run)
$script:ProfileErrorCounts = [System.Collections.Generic.Dictionary[string, int]]::new()

function Reset-ProfileErrorTracking {
    $script:ProfileErrorCounts.Clear()
}

function Add-ProfileError {
    param([string]$ProfileName)

    if (-not $script:ProfileErrorCounts.ContainsKey($ProfileName)) {
        $script:ProfileErrorCounts[$ProfileName] = 0
    }
    $script:ProfileErrorCounts[$ProfileName]++
}

function Get-ProfileErrorSummary {
    <#
    .SYNOPSIS
        Returns formatted per-profile error summary
    .OUTPUTS
        Array of objects with Name and ErrorCount properties
    #>
    $summary = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($kvp in $script:ProfileErrorCounts.GetEnumerator()) {
        $summary.Add([PSCustomObject]@{
            Name = $kvp.Key
            ErrorCount = $kvp.Value
        })
    }

    return $summary.ToArray()
}
```

### Step 2: Track Current Profile in Error Dequeue
Modify the error dequeue section in Update-GuiProgress:

```powershell
$errors = $script:OrchestrationState.DequeueErrors()
foreach ($err in $errors) {
    Write-GuiLog "[ERROR] $err"
    Add-ErrorToHistory -Message $err
    $script:GuiErrorCount++

    # NEW: Track error against current profile
    $currentProfile = $script:OrchestrationState.CurrentProfile
    if ($currentProfile -and $currentProfile.Name) {
        Add-ProfileError -ProfileName $currentProfile.Name
    }
}
```

### Step 3: Add Profile Summary Row to Progress Panel
Update MainWindow.xaml to add a profile summary row:

```xml
<Grid x:Name="panelProgress" Visibility="Collapsed" Margin="10">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>  <!-- Existing progress summary -->
        <RowDefinition Height="Auto"/>  <!-- NEW: Profile error summary -->
        <RowDefinition Height="*"/>     <!-- Chunk grid -->
    </Grid.RowDefinitions>

    <!-- Existing Progress Summary (unchanged) -->
    <Border Grid.Row="0" Background="#252525" CornerRadius="4" Padding="10" Margin="0,0,0,10">
        <!-- ... existing content ... -->
    </Border>

    <!-- NEW: Profile Error Summary (only visible during multi-profile runs) -->
    <Border Grid.Row="1" x:Name="pnlProfileErrors" Background="#252525"
            CornerRadius="4" Padding="8" Margin="0,0,0,10" Visibility="Collapsed">
        <StackPanel>
            <TextBlock Text="Profile Status" FontWeight="SemiBold" Foreground="#808080"
                       FontSize="11" Margin="0,0,0,6"/>
            <WrapPanel x:Name="pnlProfileErrorItems">
                <!-- Items added dynamically -->
            </WrapPanel>
        </StackPanel>
    </Border>

    <!-- Chunk DataGrid (shifted to Row="2") -->
    <DataGrid Grid.Row="2" x:Name="dgChunks" ...>
```

### Step 4: Update Profile Summary Display
Add function to update the profile summary panel:

```powershell
function Update-ProfileErrorSummary {
    <#
    .SYNOPSIS
        Updates the profile error summary panel in the progress view
    #>
    [CmdletBinding()]
    param()

    # Only show if multiple profiles are configured
    $profileCount = if ($script:OrchestrationState.Profiles) {
        $script:OrchestrationState.Profiles.Count
    } else { 0 }

    if ($profileCount -le 1) {
        $script:Controls.pnlProfileErrors.Visibility = 'Collapsed'
        return
    }

    $script:Controls.pnlProfileErrors.Visibility = 'Visible'
    $panel = $script:Controls.pnlProfileErrorItems
    $panel.Children.Clear()

    # Get all profiles from the run
    foreach ($profile in $script:OrchestrationState.Profiles) {
        $errorCount = 0
        if ($script:ProfileErrorCounts.ContainsKey($profile.Name)) {
            $errorCount = $script:ProfileErrorCounts[$profile.Name]
        }

        # Create pill-style indicator
        $border = New-Object System.Windows.Controls.Border
        $border.CornerRadius = [System.Windows.CornerRadius]::new(12)
        $border.Padding = [System.Windows.Thickness]::new(10, 4, 10, 4)
        $border.Margin = [System.Windows.Thickness]::new(0, 0, 8, 4)

        # Color based on error count
        if ($errorCount -eq 0) {
            $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#2D4A2D")  # Dark green
        } else {
            $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#4A2D2D")  # Dark red
        }

        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.Orientation = 'Horizontal'

        $nameText = New-Object System.Windows.Controls.TextBlock
        $nameText.Text = $profile.Name
        $nameText.Foreground = [System.Windows.Media.Brushes]::White
        $nameText.FontSize = 11
        $nameText.VerticalAlignment = 'Center'

        $countText = New-Object System.Windows.Controls.TextBlock
        $countText.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
        $countText.FontWeight = 'Bold'
        $countText.FontSize = 11
        $countText.VerticalAlignment = 'Center'

        if ($errorCount -eq 0) {
            $countText.Text = [char]0x2713  # Checkmark
            $countText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#4CAF50")
        } else {
            $countText.Text = $errorCount.ToString()
            $countText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#FF6B6B")
        }

        $stack.Children.Add($nameText)
        $stack.Children.Add($countText)
        $border.Child = $stack

        $panel.Children.Add($border)
    }

    $script:Window.UpdateLayout()
}
```

### Step 5: Integrate into Update-GuiProgress
Call the summary update after processing errors:

```powershell
# In Update-GuiProgress, after error dequeue section:
if ($script:GuiErrorCount -gt 0 -or $script:ProfileErrorCounts.Count -gt 0) {
    Update-ProfileErrorSummary
}
```

### Step 6: Reset Tracking on New Run
In Initialize-GuiReplication or Start-GuiReplication:

```powershell
# Reset per-profile error tracking
Reset-ProfileErrorTracking
$script:GuiErrorCount = 0
```

## Test Plan

Create `tests/Unit/GuiProfileErrorSummary.Tests.ps1`:

```powershell
#Requires -Modules Pester

$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "Per-Profile Error Summary Tests" {

        BeforeAll {
            $script:ProfileErrorCounts = [System.Collections.Generic.Dictionary[string, int]]::new()
        }

        AfterEach {
            Reset-ProfileErrorTracking
        }

        Context "Add-ProfileError" {
            It "Should create entry for new profile" {
                Add-ProfileError -ProfileName "TestProfile"

                $script:ProfileErrorCounts["TestProfile"] | Should -Be 1
            }

            It "Should increment existing profile count" {
                Add-ProfileError -ProfileName "Profile1"
                Add-ProfileError -ProfileName "Profile1"
                Add-ProfileError -ProfileName "Profile1"

                $script:ProfileErrorCounts["Profile1"] | Should -Be 3
            }

            It "Should track multiple profiles independently" {
                Add-ProfileError -ProfileName "ProfileA"
                Add-ProfileError -ProfileName "ProfileA"
                Add-ProfileError -ProfileName "ProfileB"

                $script:ProfileErrorCounts["ProfileA"] | Should -Be 2
                $script:ProfileErrorCounts["ProfileB"] | Should -Be 1
            }
        }

        Context "Reset-ProfileErrorTracking" {
            It "Should clear all error counts" {
                Add-ProfileError -ProfileName "Profile1"
                Add-ProfileError -ProfileName "Profile2"

                Reset-ProfileErrorTracking

                $script:ProfileErrorCounts.Count | Should -Be 0
            }
        }

        Context "Get-ProfileErrorSummary" {
            It "Should return empty array when no errors" {
                $summary = Get-ProfileErrorSummary

                $summary.Count | Should -Be 0
            }

            It "Should return all profiles with error counts" {
                Add-ProfileError -ProfileName "ProfileA"
                Add-ProfileError -ProfileName "ProfileA"
                Add-ProfileError -ProfileName "ProfileB"

                $summary = Get-ProfileErrorSummary

                $summary.Count | Should -Be 2
                ($summary | Where-Object { $_.Name -eq "ProfileA" }).ErrorCount | Should -Be 2
                ($summary | Where-Object { $_.Name -eq "ProfileB" }).ErrorCount | Should -Be 1
            }
        }

        Context "Integration with Error Dequeue" {
            BeforeEach {
                Initialize-OrchestrationState

                # Set up current profile
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{
                    Name = "ActiveProfile"
                }
            }

            It "Should track errors against current profile" {
                $script:OrchestrationState.EnqueueError("Test error 1")
                $script:OrchestrationState.EnqueueError("Test error 2")

                # Simulate what Update-GuiProgress does
                $errors = $script:OrchestrationState.DequeueErrors()
                foreach ($err in $errors) {
                    $currentProfile = $script:OrchestrationState.CurrentProfile
                    if ($currentProfile -and $currentProfile.Name) {
                        Add-ProfileError -ProfileName $currentProfile.Name
                    }
                }

                $script:ProfileErrorCounts["ActiveProfile"] | Should -Be 2
            }

            It "Should handle profile changes mid-run" {
                $script:OrchestrationState.EnqueueError("Error during Profile1")

                $errors = $script:OrchestrationState.DequeueErrors()
                foreach ($err in $errors) {
                    Add-ProfileError -ProfileName $script:OrchestrationState.CurrentProfile.Name
                }

                # Change profile
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{
                    Name = "Profile2"
                }
                $script:OrchestrationState.EnqueueError("Error during Profile2")

                $errors = $script:OrchestrationState.DequeueErrors()
                foreach ($err in $errors) {
                    Add-ProfileError -ProfileName $script:OrchestrationState.CurrentProfile.Name
                }

                $script:ProfileErrorCounts["ActiveProfile"] | Should -Be 1
                $script:ProfileErrorCounts["Profile2"] | Should -Be 1
            }
        }
    }
}
```

## Files to Modify
1. `src/Robocurse/Public/GuiProgress.ps1` - Add profile error tracking functions
2. `src/Robocurse/Resources/MainWindow.xaml` - Add profile summary panel
3. `src/Robocurse/Public/GuiReplication.ps1` - Reset tracking on new run
4. `tests/Unit/GuiProfileErrorSummary.Tests.ps1` - New test file

## Verification Commands
```powershell
.\scripts\run-tests.ps1
Invoke-Pester -Path tests\Unit\GuiProfileErrorSummary.Tests.ps1 -Output Detailed
```

## Notes
- Panel is only visible when running 2+ profiles (single profile runs don't need this)
- Uses pill-style badges matching modern UI patterns
- Green background with checkmark for profiles with 0 errors
- Red background with error count for profiles with errors
- Dictionary-based tracking is fast and thread-safe for GUI timer updates
- Summary updates only when errors exist (performance optimization)
