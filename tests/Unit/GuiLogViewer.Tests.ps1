#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "GUI Inline Log Viewer Tests" {

        BeforeAll {
            # Mock Write-RobocurseLog to prevent actual logging during tests
            Mock Write-RobocurseLog { }

            # Initialize test log buffer
            $script:GuiLogBuffer = [System.Collections.Generic.List[string]]::new()
            $script:ActivePanel = 'Logs'
        }

        Context "Update-InlineLogContent Function Existence" {
            It "Should have Update-InlineLogContent function" {
                Get-Command Update-InlineLogContent -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }
        }

        Context "Update-InlineLogContent Filtering Logic" {
            BeforeEach {
                # Clear buffer
                $script:GuiLogBuffer.Clear()

                # Create mock controls
                $script:Controls = @{
                    'txtLogContent' = [PSCustomObject]@{
                        Text = ''
                        Dispatcher = [PSCustomObject]@{
                            Invoke = { }
                        }
                    } | Add-Member -MemberType ScriptMethod -Name ScrollToEnd -Value { } -PassThru

                    'txtLogLineCount' = [PSCustomObject]@{
                        Text = ''
                    }

                    'chkLogDebug' = [PSCustomObject]@{
                        IsChecked = $true
                    }

                    'chkLogInfo' = [PSCustomObject]@{
                        IsChecked = $true
                    }

                    'chkLogWarning' = [PSCustomObject]@{
                        IsChecked = $true
                    }

                    'chkLogError' = [PSCustomObject]@{
                        IsChecked = $true
                    }

                    'chkLogAutoScroll' = [PSCustomObject]@{
                        IsChecked = $false
                    }
                }
            }

            It "Should display all log levels when all filters are enabled" {
                # Arrange
                $script:GuiLogBuffer.Add("[12:00:00] [DEBUG] Debug message")
                $script:GuiLogBuffer.Add("[12:00:01] [INFO] Info message")
                $script:GuiLogBuffer.Add("[12:00:02] [WARNING] Warning message")
                $script:GuiLogBuffer.Add("[12:00:03] [ERROR] Error message")

                # Act
                Update-InlineLogContent

                # Assert
                $script:Controls.txtLogContent.Text | Should -Match "Debug message"
                $script:Controls.txtLogContent.Text | Should -Match "Info message"
                $script:Controls.txtLogContent.Text | Should -Match "Warning message"
                $script:Controls.txtLogContent.Text | Should -Match "Error message"
                $script:Controls.txtLogLineCount.Text | Should -Be "4 lines"
            }

            It "Should filter out DEBUG messages when debug filter is disabled" {
                # Arrange
                $script:GuiLogBuffer.Add("[12:00:00] [DEBUG] Debug message")
                $script:GuiLogBuffer.Add("[12:00:01] [INFO] Info message")
                $script:GuiLogBuffer.Add("[12:00:02] [WARNING] Warning message")
                $script:Controls.chkLogDebug.IsChecked = $false

                # Act
                Update-InlineLogContent

                # Assert
                $script:Controls.txtLogContent.Text | Should -Not -Match "Debug message"
                $script:Controls.txtLogContent.Text | Should -Match "Info message"
                $script:Controls.txtLogContent.Text | Should -Match "Warning message"
                $script:Controls.txtLogLineCount.Text | Should -Be "2 lines"
            }

            It "Should show only ERROR messages when only error filter is enabled" {
                # Arrange
                $script:GuiLogBuffer.Add("[12:00:00] [DEBUG] Debug message")
                $script:GuiLogBuffer.Add("[12:00:01] [INFO] Info message")
                $script:GuiLogBuffer.Add("[12:00:02] [WARNING] Warning message")
                $script:GuiLogBuffer.Add("[12:00:03] [ERROR] Error message")
                $script:Controls.chkLogDebug.IsChecked = $false
                $script:Controls.chkLogInfo.IsChecked = $false
                $script:Controls.chkLogWarning.IsChecked = $false
                $script:Controls.chkLogError.IsChecked = $true

                # Act
                Update-InlineLogContent

                # Assert
                $script:Controls.txtLogContent.Text | Should -Not -Match "Debug message"
                $script:Controls.txtLogContent.Text | Should -Not -Match "Info message"
                $script:Controls.txtLogContent.Text | Should -Not -Match "Warning message"
                $script:Controls.txtLogContent.Text | Should -Match "Error message"
                $script:Controls.txtLogLineCount.Text | Should -Be "1 lines"
            }

            It "Should always show lines without level markers" {
                # Arrange
                $script:GuiLogBuffer.Add("[12:00:00] Plain message without level")
                $script:GuiLogBuffer.Add("[12:00:01] [DEBUG] Debug message")
                $script:Controls.chkLogDebug.IsChecked = $false
                $script:Controls.chkLogInfo.IsChecked = $false
                $script:Controls.chkLogWarning.IsChecked = $false
                $script:Controls.chkLogError.IsChecked = $false

                # Act
                Update-InlineLogContent

                # Assert
                $script:Controls.txtLogContent.Text | Should -Match "Plain message without level"
                $script:Controls.txtLogContent.Text | Should -Not -Match "Debug message"
                $script:Controls.txtLogLineCount.Text | Should -Be "1 lines"
            }

            It "Should recognize WARN as WARNING" {
                # Arrange
                $script:GuiLogBuffer.Add("[12:00:00] [WARN] Warning message")
                $script:Controls.chkLogWarning.IsChecked = $true
                $script:Controls.chkLogDebug.IsChecked = $false
                $script:Controls.chkLogInfo.IsChecked = $false
                $script:Controls.chkLogError.IsChecked = $false

                # Act
                Update-InlineLogContent

                # Assert
                $script:Controls.txtLogContent.Text | Should -Match "Warning message"
                $script:Controls.txtLogLineCount.Text | Should -Be "1 lines"
            }

            It "Should recognize ERR as ERROR" {
                # Arrange
                $script:GuiLogBuffer.Add("[12:00:00] [ERR] Error message")
                $script:Controls.chkLogError.IsChecked = $true
                $script:Controls.chkLogDebug.IsChecked = $false
                $script:Controls.chkLogInfo.IsChecked = $false
                $script:Controls.chkLogWarning.IsChecked = $false

                # Act
                Update-InlineLogContent

                # Assert
                $script:Controls.txtLogContent.Text | Should -Match "Error message"
                $script:Controls.txtLogLineCount.Text | Should -Be "1 lines"
            }
        }

        Context "Update-InlineLogContent Edge Cases" {
            BeforeEach {
                # Clear buffer
                $script:GuiLogBuffer.Clear()

                # Create mock controls
                $script:Controls = @{
                    'txtLogContent' = [PSCustomObject]@{
                        Text = ''
                        Dispatcher = [PSCustomObject]@{
                            Invoke = { }
                        }
                    } | Add-Member -MemberType ScriptMethod -Name ScrollToEnd -Value { } -PassThru

                    'txtLogLineCount' = [PSCustomObject]@{
                        Text = ''
                    }

                    'chkLogDebug' = [PSCustomObject]@{
                        IsChecked = $true
                    }

                    'chkLogInfo' = [PSCustomObject]@{
                        IsChecked = $true
                    }

                    'chkLogWarning' = [PSCustomObject]@{
                        IsChecked = $true
                    }

                    'chkLogError' = [PSCustomObject]@{
                        IsChecked = $true
                    }

                    'chkLogAutoScroll' = [PSCustomObject]@{
                        IsChecked = $false
                    }
                }
            }

            It "Should handle empty log buffer gracefully" {
                # Act
                Update-InlineLogContent

                # Assert
                $script:Controls.txtLogContent.Text | Should -Be ""
                $script:Controls.txtLogLineCount.Text | Should -Be "0 lines"
            }

            It "Should handle missing txtLogContent control gracefully" {
                # Arrange
                $script:Controls.Remove('txtLogContent')

                # Act - should not throw
                { Update-InlineLogContent } | Should -Not -Throw
            }

            It "Should handle missing filter controls gracefully" {
                # Arrange
                $script:GuiLogBuffer.Add("[12:00:00] [INFO] Info message")
                $script:Controls.Remove('chkLogDebug')
                $script:Controls.Remove('chkLogInfo')
                $script:Controls.Remove('chkLogWarning')
                $script:Controls.Remove('chkLogError')

                # Act - should not throw and should default to showing all
                { Update-InlineLogContent } | Should -Not -Throw
                $script:Controls.txtLogContent.Text | Should -Match "Info message"
            }

            It "Should handle missing line count control gracefully" {
                # Arrange
                $script:GuiLogBuffer.Add("[12:00:00] [INFO] Info message")
                $script:Controls.Remove('txtLogLineCount')

                # Act - should not throw
                { Update-InlineLogContent } | Should -Not -Throw
                $script:Controls.txtLogContent.Text | Should -Match "Info message"
            }
        }

        Context "XAML Control Names Validation" {
            BeforeAll {
                # Load XAML from resource file
                $script:TestXamlContent = Get-XamlResource -ResourceName 'MainWindow.xaml'
            }

            It "Should have chkLogDebug control in XAML" {
                $script:TestXamlContent | Should -Match 'x:Name="chkLogDebug"'
            }

            It "Should have chkLogInfo control in XAML" {
                $script:TestXamlContent | Should -Match 'x:Name="chkLogInfo"'
            }

            It "Should have chkLogWarning control in XAML" {
                $script:TestXamlContent | Should -Match 'x:Name="chkLogWarning"'
            }

            It "Should have chkLogError control in XAML" {
                $script:TestXamlContent | Should -Match 'x:Name="chkLogError"'
            }

            It "Should have chkLogAutoScroll control in XAML" {
                $script:TestXamlContent | Should -Match 'x:Name="chkLogAutoScroll"'
            }

            It "Should have txtLogLineCount control in XAML" {
                $script:TestXamlContent | Should -Match 'x:Name="txtLogLineCount"'
            }

            It "Should have txtLogContent control in XAML" {
                $script:TestXamlContent | Should -Match 'x:Name="txtLogContent"'
            }

            It "Should have btnLogClear control in XAML" {
                $script:TestXamlContent | Should -Match 'x:Name="btnLogClear"'
            }

            It "Should have btnLogCopy control in XAML" {
                $script:TestXamlContent | Should -Match 'x:Name="btnLogCopy"'
            }

            It "Should have btnLogSave control in XAML" {
                $script:TestXamlContent | Should -Match 'x:Name="btnLogSave"'
            }

            It "Should have btnLogPopOut control in XAML" {
                $script:TestXamlContent | Should -Match 'x:Name="btnLogPopOut"'
            }

            It "Should use Consolas font for log content" {
                $script:TestXamlContent | Should -Match 'FontFamily="Consolas"'
            }

            It "Should have LogsButton style for Pop Out button" {
                $script:TestXamlContent | Should -Match 'Style="\{StaticResource LogsButton\}"'
            }
        }
    }
}
