# Modal Dialog Style Enforcement Tests
# Ensures all modal dialogs use consistent styling:
# - WindowStyle="None" for borderless window
# - AllowsTransparency="True" for rounded corners
# - Background="Transparent" so Border is visible
# - Content wrapped in Border with CornerRadius for rounded corners

Describe "Modal Dialog Style Enforcement" {
    BeforeAll {
        $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:ResourcesPath = Join-Path $script:ProjectRoot "src\Robocurse\Resources"

        # Modal dialog files that must use the standard modal style
        # Excludes: MainWindow.xaml (app window), LogWindow.xaml (resizable window)
        $script:ModalDialogs = @(
            'AlertDialog.xaml',
            'CompletionDialog.xaml',
            'ConfirmDialog.xaml',
            'CreateSnapshotDialog.xaml',
            'CredentialInputDialog.xaml',
            'ErrorPopup.xaml',
            'ProfileScheduleDialog.xaml',
            'ScheduleDialog.xaml',
            'ValidationDialog.xaml'
        )
    }

    Context "Modal dialog files exist" {
        It "Resources folder exists" {
            Test-Path $script:ResourcesPath | Should -BeTrue
        }

        It "<DialogName> exists" -ForEach @(
            @{ DialogName = 'AlertDialog.xaml' }
            @{ DialogName = 'CompletionDialog.xaml' }
            @{ DialogName = 'ConfirmDialog.xaml' }
            @{ DialogName = 'CreateSnapshotDialog.xaml' }
            @{ DialogName = 'CredentialInputDialog.xaml' }
            @{ DialogName = 'ErrorPopup.xaml' }
            @{ DialogName = 'ProfileScheduleDialog.xaml' }
            @{ DialogName = 'ScheduleDialog.xaml' }
            @{ DialogName = 'ValidationDialog.xaml' }
        ) {
            $path = Join-Path $script:ResourcesPath $DialogName
            Test-Path $path | Should -BeTrue -Because "$DialogName should exist in Resources folder"
        }
    }

    Context "WindowStyle=None requirement" {
        It "<DialogName> has WindowStyle='None'" -ForEach @(
            @{ DialogName = 'AlertDialog.xaml' }
            @{ DialogName = 'CompletionDialog.xaml' }
            @{ DialogName = 'ConfirmDialog.xaml' }
            @{ DialogName = 'CreateSnapshotDialog.xaml' }
            @{ DialogName = 'CredentialInputDialog.xaml' }
            @{ DialogName = 'ErrorPopup.xaml' }
            @{ DialogName = 'ProfileScheduleDialog.xaml' }
            @{ DialogName = 'ScheduleDialog.xaml' }
            @{ DialogName = 'ValidationDialog.xaml' }
        ) {
            $path = Join-Path $script:ResourcesPath $DialogName
            $content = Get-Content $path -Raw
            $content | Should -Match 'WindowStyle\s*=\s*"None"' -Because "$DialogName must be borderless for modern rounded-corner appearance"
        }
    }

    Context "AllowsTransparency=True requirement" {
        It "<DialogName> has AllowsTransparency='True'" -ForEach @(
            @{ DialogName = 'AlertDialog.xaml' }
            @{ DialogName = 'CompletionDialog.xaml' }
            @{ DialogName = 'ConfirmDialog.xaml' }
            @{ DialogName = 'CreateSnapshotDialog.xaml' }
            @{ DialogName = 'CredentialInputDialog.xaml' }
            @{ DialogName = 'ErrorPopup.xaml' }
            @{ DialogName = 'ProfileScheduleDialog.xaml' }
            @{ DialogName = 'ScheduleDialog.xaml' }
            @{ DialogName = 'ValidationDialog.xaml' }
        ) {
            $path = Join-Path $script:ResourcesPath $DialogName
            $content = Get-Content $path -Raw
            $content | Should -Match 'AllowsTransparency\s*=\s*"True"' -Because "$DialogName must allow transparency for rounded corners to work"
        }
    }

    Context "Background=Transparent requirement" {
        It "<DialogName> has Background='Transparent' on Window" -ForEach @(
            @{ DialogName = 'AlertDialog.xaml' }
            @{ DialogName = 'CompletionDialog.xaml' }
            @{ DialogName = 'ConfirmDialog.xaml' }
            @{ DialogName = 'CreateSnapshotDialog.xaml' }
            @{ DialogName = 'CredentialInputDialog.xaml' }
            @{ DialogName = 'ErrorPopup.xaml' }
            @{ DialogName = 'ProfileScheduleDialog.xaml' }
            @{ DialogName = 'ScheduleDialog.xaml' }
            @{ DialogName = 'ValidationDialog.xaml' }
        ) {
            $path = Join-Path $script:ResourcesPath $DialogName
            $content = Get-Content $path -Raw
            # Check that Window element has Background="Transparent"
            $windowElement = [regex]::Match($content, '<Window[^>]*>')
            $windowElement.Success | Should -BeTrue -Because "$DialogName should have a Window element"
            $windowElement.Value | Should -Match 'Background\s*=\s*"Transparent"' -Because "$DialogName Window must have transparent background so Border is visible"
        }
    }

    Context "Border wrapper with CornerRadius requirement" {
        It "<DialogName> has Border child with CornerRadius" -ForEach @(
            @{ DialogName = 'AlertDialog.xaml' }
            @{ DialogName = 'CompletionDialog.xaml' }
            @{ DialogName = 'ConfirmDialog.xaml' }
            @{ DialogName = 'CreateSnapshotDialog.xaml' }
            @{ DialogName = 'CredentialInputDialog.xaml' }
            @{ DialogName = 'ErrorPopup.xaml' }
            @{ DialogName = 'ProfileScheduleDialog.xaml' }
            @{ DialogName = 'ScheduleDialog.xaml' }
            @{ DialogName = 'ValidationDialog.xaml' }
        ) {
            $path = Join-Path $script:ResourcesPath $DialogName
            $content = Get-Content $path -Raw
            # Border should have CornerRadius for rounded corners
            $content | Should -Match '<Border[^>]*CornerRadius\s*=\s*"[^"]*8[^"]*"' -Because "$DialogName must have a Border with CornerRadius='8' for rounded corners"
        }
    }

    Context "Border wrapper has dark background" {
        It "<DialogName> has Border with Background='#1E1E1E'" -ForEach @(
            @{ DialogName = 'AlertDialog.xaml' }
            @{ DialogName = 'CompletionDialog.xaml' }
            @{ DialogName = 'ConfirmDialog.xaml' }
            @{ DialogName = 'CreateSnapshotDialog.xaml' }
            @{ DialogName = 'CredentialInputDialog.xaml' }
            @{ DialogName = 'ErrorPopup.xaml' }
            @{ DialogName = 'ProfileScheduleDialog.xaml' }
            @{ DialogName = 'ScheduleDialog.xaml' }
            @{ DialogName = 'ValidationDialog.xaml' }
        ) {
            $path = Join-Path $script:ResourcesPath $DialogName
            $content = Get-Content $path -Raw
            # Border should have the dark theme background
            $content | Should -Match '<Border[^>]*Background\s*=\s*"#1E1E1E"' -Because "$DialogName must have a Border with dark background #1E1E1E"
        }
    }

    Context "No Background on Window pointing to dark color (anti-pattern)" {
        It "<DialogName> Window does not have Background='#1E1E1E' directly" -ForEach @(
            @{ DialogName = 'AlertDialog.xaml' }
            @{ DialogName = 'CompletionDialog.xaml' }
            @{ DialogName = 'ConfirmDialog.xaml' }
            @{ DialogName = 'CreateSnapshotDialog.xaml' }
            @{ DialogName = 'CredentialInputDialog.xaml' }
            @{ DialogName = 'ErrorPopup.xaml' }
            @{ DialogName = 'ProfileScheduleDialog.xaml' }
            @{ DialogName = 'ScheduleDialog.xaml' }
            @{ DialogName = 'ValidationDialog.xaml' }
        ) {
            $path = Join-Path $script:ResourcesPath $DialogName
            $content = Get-Content $path -Raw
            # Check Window element specifically
            $windowElement = [regex]::Match($content, '<Window[^>]*>')
            if ($windowElement.Success) {
                $windowElement.Value | Should -Not -Match 'Background\s*=\s*"#1E1E1E"' -Because "$DialogName Window should NOT have dark background directly - use Border wrapper instead"
            }
        }
    }

    Context "No direct MessageBox usage outside catch blocks" {
        BeforeAll {
            $script:GuiFiles = Get-ChildItem -Path (Join-Path $script:ProjectRoot "src\Robocurse\Public") -Filter "Gui*.ps1" -File
        }

        It "GUI code should use styled dialogs instead of MessageBox (except in catch fallbacks)" {
            $violations = @()

            foreach ($file in $script:GuiFiles) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)

                # Find all MessageBox::Show invocations
                $messageBoxCalls = $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $node.Member.Value -eq 'Show' -and
                    $node.Expression.Extent.Text -match 'MessageBox'
                }, $true)

                foreach ($call in $messageBoxCalls) {
                    # Check if this call is inside a catch block
                    $parent = $call.Parent
                    $inCatch = $false
                    while ($parent) {
                        if ($parent -is [System.Management.Automation.Language.CatchClauseAst]) {
                            $inCatch = $true
                            break
                        }
                        $parent = $parent.Parent
                    }

                    if (-not $inCatch) {
                        $violations += "$($file.Name):$($call.Extent.StartLineNumber) - MessageBox::Show used outside catch block"
                    }
                }
            }

            $violations | Should -BeNullOrEmpty -Because "GUI code should use Show-ConfirmDialog, Show-AlertDialog, etc. instead of MessageBox. MessageBox is only allowed in catch blocks as fallback."
        }
    }

    Context "Non-modal windows are excluded from requirements" {
        It "MainWindow.xaml is NOT checked (main app window)" {
            # MainWindow.xaml is the main application window, not a modal
            # It doesn't need WindowStyle=None because it has standard window chrome
            $path = Join-Path $script:ResourcesPath "MainWindow.xaml"
            Test-Path $path | Should -BeTrue
            # Just verify it's a standard window, not enforcing modal style
            $content = Get-Content $path -Raw
            $content | Should -Match '<Window' -Because "MainWindow.xaml should be a Window"
        }

        It "LogWindow.xaml is NOT checked (resizable window)" {
            # LogWindow.xaml is a resizable utility window, not a modal
            # It uses standard window chrome because users need to resize it
            $path = Join-Path $script:ResourcesPath "LogWindow.xaml"
            Test-Path $path | Should -BeTrue
            # Just verify it exists and is resizable
            $content = Get-Content $path -Raw
            $content | Should -Not -Match 'ResizeMode\s*=\s*"NoResize"' -Because "LogWindow should be resizable"
        }
    }
}
