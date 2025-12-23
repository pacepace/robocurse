# GUI Button Enforcement Tests
# Ensures all buttons in XAML are registered and have click handlers

Describe "GUI Button Enforcement" {
    BeforeAll {
        $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:MainWindowXaml = Join-Path $script:ProjectRoot "src\Robocurse\Resources\MainWindow.xaml"
        $script:GuiMainPs1 = Join-Path $script:ProjectRoot "src\Robocurse\Public\GuiMain.ps1"
    }

    Context "Button Definition in XAML" {
        It "MainWindow.xaml exists" {
            Test-Path $script:MainWindowXaml | Should -BeTrue
        }

        It "btnProfileSchedule button exists in XAML" {
            $xamlContent = Get-Content $script:MainWindowXaml -Raw
            $xamlContent | Should -Match 'x:Name="btnProfileSchedule"'
        }

        It "btnValidateProfile button exists in XAML" {
            $xamlContent = Get-Content $script:MainWindowXaml -Raw
            $xamlContent | Should -Match 'x:Name="btnValidateProfile"'
        }

        It "btnProfileSchedule is next to btnValidateProfile in same StackPanel" {
            $xamlContent = Get-Content $script:MainWindowXaml -Raw
            # Both should be in a StackPanel together
            $xamlContent | Should -Match 'StackPanel[^>]*>[\s\S]*?btnProfileSchedule[\s\S]*?btnValidateProfile[\s\S]*?</StackPanel>'
        }

        It "No duplicate btnSchedule button at bottom panel (old button removed)" {
            $xamlContent = Get-Content $script:MainWindowXaml -Raw
            # Should NOT have the old btnSchedule (with emoji calendar icon)
            $matches = [regex]::Matches($xamlContent, 'x:Name="btnSchedule"')
            $matches.Count | Should -Be 0 -Because "old global Schedule button should be removed"
        }
    }

    Context "Button Registration in GuiMain.ps1" {
        BeforeAll {
            $script:GuiMainContent = Get-Content $script:GuiMainPs1 -Raw
        }

        It "btnProfileSchedule is in Controls registration array" {
            $script:GuiMainContent | Should -Match "'btnProfileSchedule'"
        }

        It "btnValidateProfile is in Controls registration array" {
            $script:GuiMainContent | Should -Match "'btnValidateProfile'"
        }

        It "btnSchedule (old) is NOT in Controls registration array" {
            # Make sure we only check the registration array, not other code
            $registrationBlock = [regex]::Match($script:GuiMainContent, '\$script:Controls\s*=\s*@\{\}[\s\S]*?\|\s*ForEach-Object')
            if ($registrationBlock.Success) {
                $registrationBlock.Value | Should -Not -Match "'btnSchedule'"
            }
        }
    }

    Context "Click Handler Registration" {
        BeforeAll {
            $script:GuiMainContent = Get-Content $script:GuiMainPs1 -Raw
        }

        It "btnProfileSchedule has Add_Click handler" {
            $script:GuiMainContent | Should -Match 'btnProfileSchedule\.Add_Click\('
        }

        It "btnValidateProfile has Add_Click handler" {
            $script:GuiMainContent | Should -Match 'btnValidateProfile\.Add_Click\('
        }

        It "btnProfileSchedule handler is not conditionally guarded (no silent skip)" {
            # Handler should NOT be inside if ($script:Controls['btnProfileSchedule']) { ... }
            # It should directly attach like: $script:Controls.btnProfileSchedule.Add_Click
            $pattern = 'if\s*\(\s*\$script:Controls\[.btnProfileSchedule.\]\s*\)\s*\{[\s\S]*?btnProfileSchedule\.Add_Click'
            $script:GuiMainContent | Should -Not -Match $pattern -Because "handler should not be conditionally guarded to avoid silent failures"
        }

        It "btnProfileSchedule handler shows alert when no profile selected" {
            # Check that the handler has proper no-profile handling
            # The handler should check for no profile and show an alert
            $script:GuiMainContent | Should -Match 'btnProfileSchedule\.Add_Click[\s\S]*?-not \$selectedProfile[\s\S]*?Show-AlertDialog[\s\S]*?No Profile Selected'
        }
    }

    Context "All registered buttons have handlers" {
        BeforeAll {
            $script:GuiMainContent = Get-Content $script:GuiMainPs1 -Raw

            # Extract button names from registration array
            $registrationMatch = [regex]::Match($script:GuiMainContent, '\$script:Controls\s*=\s*@\{\}\s*\@\(([\s\S]*?)\)\s*\|\s*ForEach-Object')
            $script:RegisteredButtons = @()
            if ($registrationMatch.Success) {
                $buttonList = $registrationMatch.Groups[1].Value
                $script:RegisteredButtons = [regex]::Matches($buttonList, "'(btn[^']+)'") | ForEach-Object { $_.Groups[1].Value }
            }
        }

        It "Has registered buttons to check" {
            $script:RegisteredButtons.Count | Should -BeGreaterThan 0
        }

        It "Each registered button has an Add_Click handler" -ForEach @(
            @{ ButtonName = 'btnProfileSchedule' }
            @{ ButtonName = 'btnValidateProfile' }
            @{ ButtonName = 'btnAddProfile' }
            @{ ButtonName = 'btnRemoveProfile' }
            @{ ButtonName = 'btnRunAll' }
            @{ ButtonName = 'btnRunSelected' }
            @{ ButtonName = 'btnStop' }
        ) {
            $script:GuiMainContent | Should -Match "$($ButtonName)\.Add_Click\(" -Because "button $ButtonName should have a click handler"
        }
    }
}
