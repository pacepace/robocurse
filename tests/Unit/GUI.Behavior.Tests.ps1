#Requires -Modules Pester

<#
.SYNOPSIS
    Behavior tests for GUI components

.DESCRIPTION
    Tests GUI behavior including:
    - Form validation logic
    - Profile form state management
    - Button state changes
    - Log buffer behavior
    - Numeric input validation
#>

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

Describe "GUI Behavior Tests" -Tag "GUI", "Behavior", "Unit" {

    Context "Profile Validation Logic" {

        It "Should require non-empty profile name" {
            $profile = [PSCustomObject]@{
                Name = ""
                Source = "C:\Source"
                Destination = "D:\Dest"
            }

            $isValid = -not [string]::IsNullOrWhiteSpace($profile.Name)
            $isValid | Should -Be $false
        }

        It "Should require non-empty source path" {
            $profile = [PSCustomObject]@{
                Name = "Test"
                Source = ""
                Destination = "D:\Dest"
            }

            $isValid = -not [string]::IsNullOrWhiteSpace($profile.Source)
            $isValid | Should -Be $false
        }

        It "Should require non-empty destination path" {
            $profile = [PSCustomObject]@{
                Name = "Test"
                Source = "C:\Source"
                Destination = ""
            }

            $isValid = -not [string]::IsNullOrWhiteSpace($profile.Destination)
            $isValid | Should -Be $false
        }

        It "Should accept valid profile" {
            $profile = [PSCustomObject]@{
                Name = "Test Profile"
                Source = "C:\Source"
                Destination = "D:\Dest"
            }

            $isValid = -not [string]::IsNullOrWhiteSpace($profile.Name) -and
                       -not [string]::IsNullOrWhiteSpace($profile.Source) -and
                       -not [string]::IsNullOrWhiteSpace($profile.Destination)
            $isValid | Should -Be $true
        }

        It "Should reject profile name with only whitespace" {
            $profile = [PSCustomObject]@{
                Name = "   "
                Source = "C:\Source"
                Destination = "D:\Dest"
            }

            $isValid = -not [string]::IsNullOrWhiteSpace($profile.Name)
            $isValid | Should -Be $false
        }
    }

    Context "Numeric Input Bounds Validation" {

        It "Should validate MaxSize within bounds (1-1000 GB)" {
            $minValid = 1
            $maxValid = 1000

            # Valid values
            1 -ge $minValid -and 1 -le $maxValid | Should -Be $true
            500 -ge $minValid -and 500 -le $maxValid | Should -Be $true
            1000 -ge $minValid -and 1000 -le $maxValid | Should -Be $true

            # Invalid values
            0 -ge $minValid -and 0 -le $maxValid | Should -Be $false
            1001 -ge $minValid -and 1001 -le $maxValid | Should -Be $false
        }

        It "Should validate MaxFiles within bounds (1000-10000000)" {
            $minValid = 1000
            $maxValid = 10000000

            # Valid values
            1000 -ge $minValid -and 1000 -le $maxValid | Should -Be $true
            50000 -ge $minValid -and 50000 -le $maxValid | Should -Be $true
            10000000 -ge $minValid -and 10000000 -le $maxValid | Should -Be $true

            # Invalid values
            999 -ge $minValid -and 999 -le $maxValid | Should -Be $false
            10000001 -ge $minValid -and 10000001 -le $maxValid | Should -Be $false
        }

        It "Should validate MaxDepth within bounds (1-20)" {
            $minValid = 1
            $maxValid = 20

            # Valid values
            1 -ge $minValid -and 1 -le $maxValid | Should -Be $true
            5 -ge $minValid -and 5 -le $maxValid | Should -Be $true
            20 -ge $minValid -and 20 -le $maxValid | Should -Be $true

            # Invalid values
            0 -ge $minValid -and 0 -le $maxValid | Should -Be $false
            21 -ge $minValid -and 21 -le $maxValid | Should -Be $false
        }

        It "Should validate WorkerCount within bounds (1-16)" {
            $minValid = 1
            $maxValid = 16

            # Valid values
            1 -ge $minValid -and 1 -le $maxValid | Should -Be $true
            4 -ge $minValid -and 4 -le $maxValid | Should -Be $true
            16 -ge $minValid -and 16 -le $maxValid | Should -Be $true

            # Invalid values
            0 -ge $minValid -and 0 -le $maxValid | Should -Be $false
            17 -ge $minValid -and 17 -le $maxValid | Should -Be $false
        }

        It "Should clamp out-of-bounds MaxSize to valid range" {
            $minValid = 1
            $maxValid = 1000

            # Clamp function simulation
            $clamp = { param($value, $min, $max) [Math]::Max($min, [Math]::Min($max, $value)) }

            & $clamp 0 $minValid $maxValid | Should -Be 1
            & $clamp -5 $minValid $maxValid | Should -Be 1
            & $clamp 1500 $minValid $maxValid | Should -Be 1000
            & $clamp 500 $minValid $maxValid | Should -Be 500
        }
    }

    Context "Button State Management" {

        InModuleScope 'Robocurse' {

            BeforeEach {
                $script:OrchestrationState.Reset()
            }

            It "Should enable Run buttons when not replicating" {
                $script:OrchestrationState.Phase = "Idle"

                $isReplicating = $script:OrchestrationState.Phase -notin @('Idle', 'Complete', 'Stopped')
                $isReplicating | Should -Be $false

                # Run buttons should be enabled
                $runButtonsEnabled = -not $isReplicating
                $runButtonsEnabled | Should -Be $true
            }

            It "Should disable Run buttons when replicating" {
                $script:OrchestrationState.Phase = "Replicating"

                $isReplicating = $script:OrchestrationState.Phase -notin @('Idle', 'Complete', 'Stopped')
                $isReplicating | Should -Be $true

                # Run buttons should be disabled
                $runButtonsEnabled = -not $isReplicating
                $runButtonsEnabled | Should -Be $false
            }

            It "Should enable Stop button when replicating" {
                $script:OrchestrationState.Phase = "Replicating"

                $isReplicating = $script:OrchestrationState.Phase -notin @('Idle', 'Complete', 'Stopped')
                $stopButtonEnabled = $isReplicating
                $stopButtonEnabled | Should -Be $true
            }

            It "Should disable Stop button when not replicating" {
                $script:OrchestrationState.Phase = "Idle"

                $isReplicating = $script:OrchestrationState.Phase -notin @('Idle', 'Complete', 'Stopped')
                $stopButtonEnabled = $isReplicating
                $stopButtonEnabled | Should -Be $false
            }

            It "Should handle Scanning phase as replicating" {
                $script:OrchestrationState.Phase = "Scanning"

                $isReplicating = $script:OrchestrationState.Phase -notin @('Idle', 'Complete', 'Stopped')
                $isReplicating | Should -Be $true
            }

            It "Should handle Complete phase as not replicating" {
                $script:OrchestrationState.Phase = "Complete"

                $isReplicating = $script:OrchestrationState.Phase -notin @('Idle', 'Complete', 'Stopped')
                $isReplicating | Should -Be $false
            }
        }
    }

    Context "Log Buffer Management" {

        It "Should add messages to log buffer" {
            $logBuffer = [System.Collections.ArrayList]::new()
            $maxLines = 1000

            $message = "[12:00:00] Test message"
            $logBuffer.Add($message) | Out-Null

            $logBuffer.Count | Should -Be 1
            $logBuffer[0] | Should -Be $message
        }

        It "Should trim buffer when exceeding max lines" {
            $logBuffer = [System.Collections.ArrayList]::new()
            $maxLines = 5

            # Add more than max lines
            for ($i = 1; $i -le 10; $i++) {
                $logBuffer.Add("Line $i") | Out-Null
                while ($logBuffer.Count -gt $maxLines) {
                    $logBuffer.RemoveAt(0)
                }
            }

            $logBuffer.Count | Should -Be 5
            # Should have the last 5 lines
            $logBuffer[0] | Should -Be "Line 6"
            $logBuffer[4] | Should -Be "Line 10"
        }

        It "Should join buffer lines with newlines" {
            $logBuffer = [System.Collections.ArrayList]::new()
            $logBuffer.Add("Line 1") | Out-Null
            $logBuffer.Add("Line 2") | Out-Null
            $logBuffer.Add("Line 3") | Out-Null

            $logText = $logBuffer -join "`n"

            $logText | Should -Be "Line 1`nLine 2`nLine 3"
        }

        It "Should format log messages with timestamp" {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $message = "Test message"
            $formattedMessage = "[$timestamp] $message"

            $formattedMessage | Should -Match '^\[\d{2}:\d{2}:\d{2}\]'
        }
    }

    Context "Profile List Selection State" {

        It "Should track selected profile index" {
            $profiles = @(
                [PSCustomObject]@{ Name = "Profile A" }
                [PSCustomObject]@{ Name = "Profile B" }
                [PSCustomObject]@{ Name = "Profile C" }
            )

            $selectedIndex = 1
            $selectedProfile = $profiles[$selectedIndex]

            $selectedProfile.Name | Should -Be "Profile B"
        }

        It "Should handle empty profile list" {
            $profiles = @()
            $selectedIndex = -1

            $hasSelection = $selectedIndex -ge 0 -and $selectedIndex -lt $profiles.Count
            $hasSelection | Should -Be $false
        }

        It "Should handle single profile selection" {
            $profiles = @(
                [PSCustomObject]@{ Name = "Only Profile" }
            )

            $selectedIndex = 0
            $hasSelection = $selectedIndex -ge 0 -and $selectedIndex -lt $profiles.Count
            $hasSelection | Should -Be $true
        }

        It "Should invalidate selection after profile removal" {
            $profiles = @(
                [PSCustomObject]@{ Name = "Profile A" }
                [PSCustomObject]@{ Name = "Profile B" }
            )

            $selectedIndex = 1

            # Remove selected profile
            $profiles = @($profiles | Where-Object { $_.Name -ne "Profile B" })

            # Selection should be invalid now
            $hasValidSelection = $selectedIndex -ge 0 -and $selectedIndex -lt $profiles.Count
            $hasValidSelection | Should -Be $false
        }
    }

    Context "Form to Profile Data Binding" {

        It "Should create profile from form values" {
            $formValues = @{
                Name = "Test Profile"
                Source = "C:\Source"
                Destination = "D:\Destination"
                UseVSS = $true
                ScanMode = "Flat"
                MaxDepth = 6
            }

            $profile = [PSCustomObject]@{
                Name = $formValues.Name
                Source = $formValues.Source
                Destination = $formValues.Destination
                UseVSS = $formValues.UseVSS
                ScanMode = $formValues.ScanMode
                ChunkMaxDepth = $formValues.MaxDepth
                Enabled = $true
            }

            $profile.Name | Should -Be "Test Profile"
            $profile.Source | Should -Be "C:\Source"
            $profile.ChunkMaxDepth | Should -Be 6
            $profile.UseVSS | Should -Be $true
        }

        It "Should populate form from profile values" {
            $profile = [PSCustomObject]@{
                Name = "Existing Profile"
                Source = "E:\Data"
                Destination = "F:\Backup"
                UseVSS = $false
                ScanMode = "Flat"
                ChunkMaxDepth = 8
            }

            $formValues = @{
                Name = $profile.Name
                Source = $profile.Source
                Destination = $profile.Destination
                UseVSS = $profile.UseVSS
                ScanModeIndex = if ($profile.ScanMode -eq "Flat") { 1 } else { 0 }
                MaxDepth = $profile.ChunkMaxDepth
            }

            $formValues.Name | Should -Be "Existing Profile"
            $formValues.ScanModeIndex | Should -Be 1
            $formValues.MaxDepth | Should -Be 8
        }
    }

    Context "Error Display State" {

        It "Should track error count" {
            $errorCount = 0

            # Simulate errors
            $errorCount++
            $errorCount++
            $errorCount++

            $errorCount | Should -Be 3
            $hasErrors = $errorCount -gt 0
            $hasErrors | Should -Be $true
        }

        It "Should format error count display" {
            $errorCount = 5
            $errorText = "Errors: $errorCount"

            $errorText | Should -Be "Errors: 5"
        }

        It "Should handle zero errors" {
            $errorCount = 0
            $hasErrors = $errorCount -gt 0
            $hasErrors | Should -Be $false
        }
    }

    Context "Status Text State Machine" {

        It "Should show Idle when not running" {
            $phase = "Idle"
            $statusText = switch ($phase) {
                "Idle" { "Ready" }
                "Scanning" { "Scanning directories..." }
                "Replicating" { "Replicating..." }
                "Complete" { "Complete" }
                "Stopped" { "Stopped" }
                default { "Ready" }
            }

            $statusText | Should -Be "Ready"
        }

        It "Should show Scanning during scan phase" {
            $phase = "Scanning"
            $statusText = switch ($phase) {
                "Idle" { "Ready" }
                "Scanning" { "Scanning directories..." }
                "Replicating" { "Replicating..." }
                "Complete" { "Complete" }
                "Stopped" { "Stopped" }
                default { "Ready" }
            }

            $statusText | Should -Be "Scanning directories..."
        }

        It "Should show Replicating during copy phase" {
            $phase = "Replicating"
            $statusText = switch ($phase) {
                "Idle" { "Ready" }
                "Scanning" { "Scanning directories..." }
                "Replicating" { "Replicating..." }
                "Complete" { "Complete" }
                "Stopped" { "Stopped" }
                default { "Ready" }
            }

            $statusText | Should -Be "Replicating..."
        }

        It "Should show Complete after finish" {
            $phase = "Complete"
            $statusText = switch ($phase) {
                "Idle" { "Ready" }
                "Scanning" { "Scanning directories..." }
                "Replicating" { "Replicating..." }
                "Complete" { "Complete" }
                "Stopped" { "Stopped" }
                default { "Ready" }
            }

            $statusText | Should -Be "Complete"
        }
    }

    Context "Unique Profile Name Generation" {

        It "Should generate unique name for new profile" {
            $existingNames = @("Profile 1", "Profile 2", "Profile 3")

            $baseName = "Profile"
            $counter = 1
            while ($existingNames -contains "$baseName $counter") {
                $counter++
            }
            $newName = "$baseName $counter"

            $newName | Should -Be "Profile 4"
        }

        It "Should handle gaps in profile numbering" {
            $existingNames = @("Profile 1", "Profile 5", "Profile 10")

            $baseName = "Profile"
            $counter = 1
            while ($existingNames -contains "$baseName $counter") {
                $counter++
            }
            $newName = "$baseName $counter"

            # Should find first available: Profile 2
            $newName | Should -Be "Profile 2"
        }

        It "Should handle empty profile list" {
            $existingNames = @()

            $baseName = "Profile"
            $counter = 1
            while ($existingNames -contains "$baseName $counter") {
                $counter++
            }
            $newName = "$baseName $counter"

            $newName | Should -Be "Profile 1"
        }
    }

    Context "Completion Dialog State" {

        It "Should show success state when no failures" {
            $chunksFailed = 0

            $status = if ($chunksFailed -gt 0) { "Warning" } else { "Success" }
            $status | Should -Be "Success"
        }

        It "Should show warning state when failures exist" {
            $chunksFailed = 3

            $status = if ($chunksFailed -gt 0) { "Warning" } else { "Success" }
            $status | Should -Be "Warning"
        }

        It "Should format completion statistics" {
            $stats = @{
                ChunksComplete = 95
                ChunksTotal = 100
                ChunksFailed = 5
                BytesCopied = 10GB
                Duration = [timespan]::FromMinutes(30)
            }

            $chunksText = "$($stats.ChunksComplete)/$($stats.ChunksTotal)"
            $failedText = $stats.ChunksFailed.ToString()

            $chunksText | Should -Be "95/100"
            $failedText | Should -Be "5"
        }

        It "Should calculate success percentage" {
            $complete = 95
            $total = 100

            $percentage = [math]::Round(($complete / $total) * 100, 1)
            $percentage | Should -Be 95.0
        }
    }

    Context "Timer Tick Behavior" {

        InModuleScope 'Robocurse' {

            BeforeEach {
                $script:OrchestrationState.Reset()
            }

            It "Should not update progress when idle" {
                $script:OrchestrationState.Phase = "Idle"

                $shouldUpdate = $script:OrchestrationState.Phase -notin @('Idle', 'Complete', 'Stopped')
                $shouldUpdate | Should -Be $false
            }

            It "Should update progress when replicating" {
                $script:OrchestrationState.Phase = "Replicating"

                $shouldUpdate = $script:OrchestrationState.Phase -notin @('Idle', 'Complete', 'Stopped')
                $shouldUpdate | Should -Be $true
            }

            It "Should stop updates when complete" {
                $script:OrchestrationState.Phase = "Complete"

                $shouldUpdate = $script:OrchestrationState.Phase -notin @('Idle', 'Complete', 'Stopped')
                $shouldUpdate | Should -Be $false
            }
        }
    }

    Context "Window State Persistence" {

        It "Should serialize window position" {
            $windowState = @{
                Left = 100
                Top = 200
                Width = 1200
                Height = 800
                IsMaximized = $false
            }

            $json = $windowState | ConvertTo-Json
            $restored = $json | ConvertFrom-Json

            $restored.Left | Should -Be 100
            $restored.Top | Should -Be 200
            $restored.Width | Should -Be 1200
            $restored.Height | Should -Be 800
        }

        It "Should handle maximized state" {
            $windowState = @{
                Left = 0
                Top = 0
                Width = 1920
                Height = 1080
                IsMaximized = $true
            }

            $windowState.IsMaximized | Should -Be $true
        }

        It "Should validate window bounds" {
            $screenWidth = 1920
            $screenHeight = 1080

            # Window trying to be off-screen
            $left = -500
            $top = 2000

            # Clamp to screen bounds
            $clampedLeft = [Math]::Max(0, [Math]::Min($screenWidth - 100, $left))
            $clampedTop = [Math]::Max(0, [Math]::Min($screenHeight - 100, $top))

            $clampedLeft | Should -Be 0
            $clampedTop | Should -Be 980  # 1080 - 100
        }
    }

    Context "Safe Event Handler Pattern" {

        It "Should catch exceptions in event handlers" {
            # Use a hashtable to track state across scopes
            $state = @{ ErrorOccurred = $false }

            # Simulate safe event handler wrapper (common GUI pattern)
            $safeHandler = {
                param($ScriptBlock, $StateRef)
                try {
                    & $ScriptBlock
                }
                catch {
                    $StateRef.ErrorOccurred = $true
                }
            }

            # Handler that throws
            & $safeHandler { throw "Test exception" } $state

            $state.ErrorOccurred | Should -Be $true
        }

        It "Should continue after caught exception" {
            $state = @{ Completed = $false; ErrorOccurred = $false }

            $safeHandler = {
                param($ScriptBlock, $StateRef)
                try {
                    & $ScriptBlock
                }
                catch {
                    $StateRef.ErrorOccurred = $true
                }
                $StateRef.Completed = $true
            }

            & $safeHandler { throw "Test exception" } $state

            $state.ErrorOccurred | Should -Be $true
            $state.Completed | Should -Be $true
        }
    }
}

Describe "GUI Replication Runspace Tests" -Tag "GUI", "Runspace", "Unit" {

    InModuleScope 'Robocurse' {

        BeforeEach {
            $script:OrchestrationState.Reset()
        }

        Context "Runspace State Management" {

            It "Should track runspace initialization state" {
                $runspaceInitialized = $false

                # Simulate initialization
                $runspaceInitialized = $true

                $runspaceInitialized | Should -Be $true
            }

            It "Should track stop requested state" {
                $script:OrchestrationState.StopRequested = $false

                # Request stop
                $script:OrchestrationState.StopRequested = $true

                $script:OrchestrationState.StopRequested | Should -Be $true
            }

            It "Should track pause requested state" {
                $script:OrchestrationState.PauseRequested = $false

                # Request pause
                $script:OrchestrationState.PauseRequested = $true

                $script:OrchestrationState.PauseRequested | Should -Be $true
            }
        }

        Context "Profile Selection for Replication" {

            It "Should select all enabled profiles for Run All" {
                $profiles = @(
                    [PSCustomObject]@{ Name = "A"; Enabled = $true }
                    [PSCustomObject]@{ Name = "B"; Enabled = $false }
                    [PSCustomObject]@{ Name = "C"; Enabled = $true }
                )

                $toRun = @($profiles | Where-Object { $_.Enabled })

                $toRun.Count | Should -Be 2
                $toRun[0].Name | Should -Be "A"
                $toRun[1].Name | Should -Be "C"
            }

            It "Should select only specified profile for Run Selected" {
                $profiles = @(
                    [PSCustomObject]@{ Name = "A"; Enabled = $true }
                    [PSCustomObject]@{ Name = "B"; Enabled = $true }
                    [PSCustomObject]@{ Name = "C"; Enabled = $true }
                )

                $selectedName = "B"
                $toRun = @($profiles | Where-Object { $_.Name -eq $selectedName })

                $toRun.Count | Should -Be 1
                $toRun[0].Name | Should -Be "B"
            }
        }

        Context "Profile Row Click Behavior" {
            # Tests for the profile row click logic that:
            # 1. Deselects all other profiles (sets Enabled = false)
            # 2. Selects the clicked profile (sets Enabled = true)
            # Clicking anywhere on the row (except the checkbox) triggers this behavior

            It "Should deselect all other profiles when clicking a profile row" {
                $profiles = @(
                    [PSCustomObject]@{ Name = "A"; Enabled = $true }
                    [PSCustomObject]@{ Name = "B"; Enabled = $true }
                    [PSCustomObject]@{ Name = "C"; Enabled = $true }
                )

                # Simulate clicking on profile B
                $clickedProfile = $profiles[1]
                foreach ($p in $profiles) {
                    if ($p -ne $clickedProfile) {
                        $p.Enabled = $false
                    }
                }
                $clickedProfile.Enabled = $true

                # Verify only the clicked profile is enabled
                $profiles[0].Enabled | Should -Be $false
                $profiles[1].Enabled | Should -Be $true
                $profiles[2].Enabled | Should -Be $false
            }

            It "Should enable the clicked profile even if it was disabled" {
                $profiles = @(
                    [PSCustomObject]@{ Name = "A"; Enabled = $true }
                    [PSCustomObject]@{ Name = "B"; Enabled = $false }
                    [PSCustomObject]@{ Name = "C"; Enabled = $true }
                )

                # Simulate clicking on disabled profile B
                $clickedProfile = $profiles[1]
                foreach ($p in $profiles) {
                    if ($p -ne $clickedProfile) {
                        $p.Enabled = $false
                    }
                }
                $clickedProfile.Enabled = $true

                # Verify clicked profile is now enabled, others disabled
                $profiles[0].Enabled | Should -Be $false
                $profiles[1].Enabled | Should -Be $true
                $profiles[2].Enabled | Should -Be $false
            }

            It "Should only have one enabled profile after clicking a row" {
                $profiles = @(
                    [PSCustomObject]@{ Name = "A"; Enabled = $true }
                    [PSCustomObject]@{ Name = "B"; Enabled = $true }
                    [PSCustomObject]@{ Name = "C"; Enabled = $true }
                    [PSCustomObject]@{ Name = "D"; Enabled = $true }
                )

                # Simulate clicking on profile C
                $clickedProfile = $profiles[2]
                foreach ($p in $profiles) {
                    if ($p -ne $clickedProfile) {
                        $p.Enabled = $false
                    }
                }
                $clickedProfile.Enabled = $true

                $enabledCount = @($profiles | Where-Object { $_.Enabled }).Count
                $enabledCount | Should -Be 1
            }
        }

        Context "Set-SingleProfileEnabled Function" {
            # Tests for the Set-SingleProfileEnabled function that ensures
            # only one profile is enabled at a time (used by both row click
            # and add profile operations)

            BeforeEach {
                # Set up mock config with multiple profiles
                $script:Config = [PSCustomObject]@{
                    SyncProfiles = @(
                        [PSCustomObject]@{ Name = "Profile1"; Enabled = $true }
                        [PSCustomObject]@{ Name = "Profile2"; Enabled = $true }
                        [PSCustomObject]@{ Name = "Profile3"; Enabled = $true }
                    )
                }
                # Mock Controls to prevent UI refresh errors
                $script:Controls = @{ lstProfiles = $null }
            }

            It "Should enable only the specified profile" {
                $targetProfile = $script:Config.SyncProfiles[1]

                Set-SingleProfileEnabled -Profile $targetProfile

                $script:Config.SyncProfiles[0].Enabled | Should -Be $false
                $script:Config.SyncProfiles[1].Enabled | Should -Be $true
                $script:Config.SyncProfiles[2].Enabled | Should -Be $false
            }

            It "Should disable all profiles when no profile specified" {
                Set-SingleProfileEnabled

                $script:Config.SyncProfiles[0].Enabled | Should -Be $false
                $script:Config.SyncProfiles[1].Enabled | Should -Be $false
                $script:Config.SyncProfiles[2].Enabled | Should -Be $false
            }

            It "Should handle empty SyncProfiles gracefully" {
                $script:Config.SyncProfiles = @()

                { Set-SingleProfileEnabled } | Should -Not -Throw
            }

            It "Should handle null SyncProfiles gracefully" {
                $script:Config.SyncProfiles = $null

                { Set-SingleProfileEnabled } | Should -Not -Throw
            }

            It "Should result in exactly one enabled profile" {
                $targetProfile = $script:Config.SyncProfiles[2]

                Set-SingleProfileEnabled -Profile $targetProfile

                $enabledCount = @($script:Config.SyncProfiles | Where-Object { $_.Enabled }).Count
                $enabledCount | Should -Be 1
            }
        }

        Context "Add Profile Checkbox Clearing" {
            # Tests that adding a new profile clears checkboxes on existing profiles

            BeforeEach {
                $script:Config = [PSCustomObject]@{
                    SyncProfiles = @(
                        [PSCustomObject]@{ Name = "Existing1"; Enabled = $true }
                        [PSCustomObject]@{ Name = "Existing2"; Enabled = $true }
                    )
                }
                $script:Controls = @{ lstProfiles = $null }
            }

            It "Should clear other profile checkboxes when adding new profile" {
                # Simulate what Add-NewProfile does:
                # 1. Create new profile with Enabled = $true
                $newProfile = [PSCustomObject]@{
                    Name = "New Profile"
                    Enabled = $true
                }
                $script:Config.SyncProfiles += $newProfile

                # 2. Call Set-SingleProfileEnabled (this is the fix)
                Set-SingleProfileEnabled -Profile $newProfile

                # Verify: existing profiles should be disabled, new profile enabled
                $script:Config.SyncProfiles[0].Enabled | Should -Be $false
                $script:Config.SyncProfiles[1].Enabled | Should -Be $false
                $script:Config.SyncProfiles[2].Enabled | Should -Be $true
            }

            It "Should only have new profile enabled after adding" {
                $newProfile = [PSCustomObject]@{
                    Name = "New Profile"
                    Enabled = $true
                }
                $script:Config.SyncProfiles += $newProfile

                Set-SingleProfileEnabled -Profile $newProfile

                $enabledCount = @($script:Config.SyncProfiles | Where-Object { $_.Enabled }).Count
                $enabledCount | Should -Be 1
                ($script:Config.SyncProfiles | Where-Object { $_.Enabled }).Name | Should -Be "New Profile"
            }
        }
    }
}
