#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "GUI Settings Panel Tests" {

        Context "Function Existence Tests" {
            It "Should have Import-SettingsToForm function" {
                Get-Command Import-SettingsToForm -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }

            It "Should have Save-SettingsFromForm function" {
                Get-Command Save-SettingsFromForm -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }
        }

        Context "XAML Settings Panel Control Tests" {
            BeforeAll {
                $script:TestXamlContent = Get-XamlResource -ResourceName 'MainWindow.xaml'
            }

            It "Should have panelSettings defined" {
                $script:TestXamlContent | Should -Match 'x:Name="panelSettings"'
            }

            # Performance controls
            It "Should have sldSettingsJobs slider control" {
                $script:TestXamlContent | Should -Match 'x:Name="sldSettingsJobs"'
            }

            It "Should have txtSettingsJobs text display" {
                $script:TestXamlContent | Should -Match 'x:Name="txtSettingsJobs"'
            }

            It "Should have sldSettingsThreads slider control" {
                $script:TestXamlContent | Should -Match 'x:Name="sldSettingsThreads"'
            }

            It "Should have txtSettingsThreads text display" {
                $script:TestXamlContent | Should -Match 'x:Name="txtSettingsThreads"'
            }

            It "Should have txtSettingsBandwidth textbox" {
                $script:TestXamlContent | Should -Match 'x:Name="txtSettingsBandwidth"'
            }

            # Logging controls
            It "Should have txtSettingsLogPath textbox" {
                $script:TestXamlContent | Should -Match 'x:Name="txtSettingsLogPath"'
            }

            It "Should have btnSettingsLogBrowse button" {
                $script:TestXamlContent | Should -Match 'x:Name="btnSettingsLogBrowse"'
            }

            It "Should have chkSettingsSiem checkbox" {
                $script:TestXamlContent | Should -Match 'x:Name="chkSettingsSiem"'
            }

            It "Should have txtSettingsSiemPath textbox" {
                $script:TestXamlContent | Should -Match 'x:Name="txtSettingsSiemPath"'
            }

            It "Should have btnSettingsSiemBrowse button" {
                $script:TestXamlContent | Should -Match 'x:Name="btnSettingsSiemBrowse"'
            }

            # Email controls
            It "Should have chkSettingsEmailEnabled checkbox" {
                $script:TestXamlContent | Should -Match 'x:Name="chkSettingsEmailEnabled"'
            }

            It "Should have txtSettingsSmtp textbox" {
                $script:TestXamlContent | Should -Match 'x:Name="txtSettingsSmtp"'
            }

            It "Should have txtSettingsSmtpPort textbox" {
                $script:TestXamlContent | Should -Match 'x:Name="txtSettingsSmtpPort"'
            }

            It "Should have chkSettingsTls checkbox" {
                $script:TestXamlContent | Should -Match 'x:Name="chkSettingsTls"'
            }

            It "Should have txtSettingsCredential textbox" {
                $script:TestXamlContent | Should -Match 'x:Name="txtSettingsCredential"'
            }

            It "Should have txtSettingsEmailFrom textbox" {
                $script:TestXamlContent | Should -Match 'x:Name="txtSettingsEmailFrom"'
            }

            It "Should have txtSettingsEmailTo textbox" {
                $script:TestXamlContent | Should -Match 'x:Name="txtSettingsEmailTo"'
            }

            # Schedule controls
            It "Should have btnSettingsSchedule button" {
                $script:TestXamlContent | Should -Match 'x:Name="btnSettingsSchedule"'
            }

            It "Should have txtSettingsScheduleStatus textblock" {
                $script:TestXamlContent | Should -Match 'x:Name="txtSettingsScheduleStatus"'
            }

            # Save/Revert buttons
            It "Should have btnSettingsRevert button" {
                $script:TestXamlContent | Should -Match 'x:Name="btnSettingsRevert"'
            }

            It "Should have btnSettingsSave button" {
                $script:TestXamlContent | Should -Match 'x:Name="btnSettingsSave"'
            }

            It "Should use RunButton style for Save button" {
                $script:TestXamlContent | Should -Match 'x:Name="btnSettingsSave"'
                $script:TestXamlContent | Should -Match 'Style="\{StaticResource RunButton\}"'
            }

            It "Should use DarkButton style for Revert button" {
                $script:TestXamlContent | Should -Match 'x:Name="btnSettingsRevert"'
                $script:TestXamlContent | Should -Match 'Style="\{StaticResource DarkButton\}"'
            }

            It "Should use ScheduleButton style for Schedule button" {
                $script:TestXamlContent | Should -Match 'x:Name="btnSettingsSchedule"'
                $script:TestXamlContent | Should -Match 'Style="\{StaticResource ScheduleButton\}"'
            }
        }

        Context "Import-SettingsToForm Tests" {
            BeforeAll {
                # Mock dependencies
                Mock Get-RobocurseConfig {
                    return [PSCustomObject]@{
                        GlobalSettings = [PSCustomObject]@{
                            MaxConcurrentJobs = 8
                            ThreadsPerJob = 16
                            BandwidthLimitMbps = 100
                            LogPath = "C:\TestLogs"
                        }
                        Email = [PSCustomObject]@{
                            Enabled = $true
                            SmtpServer = "smtp.test.com"
                            Port = 587
                            UseTls = $true
                            CredentialTarget = "Test-SMTP"
                            From = "test@test.com"
                            To = @("user1@test.com", "user2@test.com")
                        }
                        Schedule = [PSCustomObject]@{
                            Enabled = $true
                            Time = "03:00"
                            Days = @("Monday", "Wednesday", "Friday")
                        }
                    }
                }

                Mock Write-GuiLog { }

                # Setup script variables
                $script:ConfigPath = "C:\test\config.json"
                $script:Controls = @{
                    sldSettingsJobs = [PSCustomObject]@{ Value = 0 }
                    txtSettingsJobs = [PSCustomObject]@{ Text = "" }
                    sldSettingsThreads = [PSCustomObject]@{ Value = 0 }
                    txtSettingsThreads = [PSCustomObject]@{ Text = "" }
                    txtSettingsBandwidth = [PSCustomObject]@{ Text = "" }
                    txtSettingsLogPath = [PSCustomObject]@{ Text = "" }
                    chkSettingsSiem = [PSCustomObject]@{ IsChecked = $false }
                    txtSettingsSiemPath = [PSCustomObject]@{ Text = "" }
                    chkSettingsEmailEnabled = [PSCustomObject]@{ IsChecked = $false }
                    txtSettingsSmtp = [PSCustomObject]@{ Text = "" }
                    txtSettingsSmtpPort = [PSCustomObject]@{ Text = "" }
                    chkSettingsTls = [PSCustomObject]@{ IsChecked = $false }
                    txtSettingsCredential = [PSCustomObject]@{ Text = "" }
                    txtSettingsEmailFrom = [PSCustomObject]@{ Text = "" }
                    txtSettingsEmailTo = [PSCustomObject]@{ Text = "" }
                    txtSettingsScheduleStatus = [PSCustomObject]@{ Text = "" }
                }
            }

            It "Should load MaxConcurrentJobs into slider and text" {
                Import-SettingsToForm
                $script:Controls.sldSettingsJobs.Value | Should -Be 8
                $script:Controls.txtSettingsJobs.Text | Should -Be "8"
            }

            It "Should load ThreadsPerJob into slider and text" {
                Import-SettingsToForm
                $script:Controls.sldSettingsThreads.Value | Should -Be 16
                $script:Controls.txtSettingsThreads.Text | Should -Be "16"
            }

            It "Should load BandwidthLimitMbps into textbox" {
                Import-SettingsToForm
                $script:Controls.txtSettingsBandwidth.Text | Should -Be "100"
            }

            It "Should load LogPath into textbox" {
                Import-SettingsToForm
                $script:Controls.txtSettingsLogPath.Text | Should -Be "C:\TestLogs"
            }

            It "Should load email enabled state" {
                Import-SettingsToForm
                $script:Controls.chkSettingsEmailEnabled.IsChecked | Should -Be $true
            }

            It "Should load SMTP server" {
                Import-SettingsToForm
                $script:Controls.txtSettingsSmtp.Text | Should -Be "smtp.test.com"
            }

            It "Should load SMTP port" {
                Import-SettingsToForm
                $script:Controls.txtSettingsSmtpPort.Text | Should -Be "587"
            }

            It "Should load TLS setting" {
                Import-SettingsToForm
                $script:Controls.chkSettingsTls.IsChecked | Should -Be $true
            }

            It "Should load credential target" {
                Import-SettingsToForm
                $script:Controls.txtSettingsCredential.Text | Should -Be "Test-SMTP"
            }

            It "Should load email from address" {
                Import-SettingsToForm
                $script:Controls.txtSettingsEmailFrom.Text | Should -Be "test@test.com"
            }

            It "Should convert email To array to newline-separated string" {
                Import-SettingsToForm
                $script:Controls.txtSettingsEmailTo.Text | Should -Be "user1@test.com`r`nuser2@test.com"
            }

            It "Should format schedule status when enabled" {
                Import-SettingsToForm
                $script:Controls.txtSettingsScheduleStatus.Text | Should -Match "Enabled"
                $script:Controls.txtSettingsScheduleStatus.Text | Should -Match "03:00"
            }

            It "Should show 'Not configured' when schedule disabled" {
                Mock Get-RobocurseConfig {
                    return [PSCustomObject]@{
                        GlobalSettings = [PSCustomObject]@{ MaxConcurrentJobs = 4; ThreadsPerJob = 8; BandwidthLimitMbps = 0; LogPath = ".\Logs" }
                        Email = [PSCustomObject]@{ Enabled = $false; SmtpServer = ""; Port = 587; UseTls = $true; CredentialTarget = ""; From = ""; To = @() }
                        Schedule = [PSCustomObject]@{ Enabled = $false; Time = ""; Days = @() }
                    }
                }
                Import-SettingsToForm
                $script:Controls.txtSettingsScheduleStatus.Text | Should -Be "Not configured"
            }
        }

        Context "Save-SettingsFromForm Tests" {
            BeforeAll {
                # Mock dependencies
                Mock Save-RobocurseConfig {
                    return [PSCustomObject]@{ Success = $true; ErrorMessage = "" }
                }

                Mock Write-GuiLog { }
                Mock Show-GuiError { }

                # Setup script variables with a config object
                $script:ConfigPath = "C:\test\config.json"
                $script:Config = [PSCustomObject]@{
                    GlobalSettings = [PSCustomObject]@{
                        MaxConcurrentJobs = 4
                        ThreadsPerJob = 8
                        BandwidthLimitMbps = 0
                        LogPath = ".\Logs"
                    }
                    Email = [PSCustomObject]@{
                        Enabled = $false
                        SmtpServer = ""
                        Port = 587
                        UseTls = $true
                        CredentialTarget = "Robocurse-SMTP"
                        From = ""
                        To = @()
                    }
                }

                $script:Controls = @{
                    sldSettingsJobs = [PSCustomObject]@{ Value = 12 }
                    sldSettingsThreads = [PSCustomObject]@{ Value = 24 }
                    txtSettingsBandwidth = [PSCustomObject]@{ Text = "  200  " }
                    txtSettingsLogPath = [PSCustomObject]@{ Text = "  C:\NewLogs  " }
                    chkSettingsEmailEnabled = [PSCustomObject]@{ IsChecked = $true }
                    txtSettingsSmtp = [PSCustomObject]@{ Text = "  smtp.new.com  " }
                    txtSettingsSmtpPort = [PSCustomObject]@{ Text = "  465  " }
                    chkSettingsTls = [PSCustomObject]@{ IsChecked = $false }
                    txtSettingsCredential = [PSCustomObject]@{ Text = "  New-Cred  " }
                    txtSettingsEmailFrom = [PSCustomObject]@{ Text = "  new@test.com  " }
                    txtSettingsEmailTo = [PSCustomObject]@{ Text = "  user1@test.com , user2@test.com , user3@test.com  " }
                    txtStatus = [PSCustomObject]@{ Text = "" }
                }
            }

            It "Should save MaxConcurrentJobs from slider" {
                Save-SettingsFromForm
                $script:Config.GlobalSettings.MaxConcurrentJobs | Should -Be 12
            }

            It "Should save ThreadsPerJob from slider" {
                Save-SettingsFromForm
                $script:Config.GlobalSettings.ThreadsPerJob | Should -Be 24
            }

            It "Should save BandwidthLimitMbps and trim whitespace" {
                Save-SettingsFromForm
                $script:Config.GlobalSettings.BandwidthLimitMbps | Should -Be 200
            }

            It "Should save LogPath and trim whitespace" {
                Save-SettingsFromForm
                $script:Config.GlobalSettings.LogPath | Should -Be "C:\NewLogs"
            }

            It "Should save email enabled state" {
                Save-SettingsFromForm
                $script:Config.Email.Enabled | Should -Be $true
            }

            It "Should save SMTP server and trim whitespace" {
                Save-SettingsFromForm
                $script:Config.Email.SmtpServer | Should -Be "smtp.new.com"
            }

            It "Should save SMTP port as integer" {
                Save-SettingsFromForm
                $script:Config.Email.Port | Should -Be 465
            }

            It "Should save TLS setting" {
                Save-SettingsFromForm
                $script:Config.Email.UseTls | Should -Be $false
            }

            It "Should save credential target and trim whitespace" {
                Save-SettingsFromForm
                $script:Config.Email.CredentialTarget | Should -Be "New-Cred"
            }

            It "Should save email from and trim whitespace" {
                Save-SettingsFromForm
                $script:Config.Email.From | Should -Be "new@test.com"
            }

            It "Should parse comma-separated email To into array" {
                Save-SettingsFromForm
                $script:Config.Email.To | Should -HaveCount 3
                $script:Config.Email.To[0] | Should -Be "user1@test.com"
                $script:Config.Email.To[1] | Should -Be "user2@test.com"
                $script:Config.Email.To[2] | Should -Be "user3@test.com"
            }

            It "Should handle empty email To field" {
                $script:Controls.txtSettingsEmailTo.Text = "   "
                Save-SettingsFromForm
                $script:Config.Email.To | Should -HaveCount 0
            }

            It "Should call Save-RobocurseConfig" {
                Save-SettingsFromForm
                Should -Invoke Save-RobocurseConfig -Times 1
            }

            It "Should update status text on successful save" {
                Save-SettingsFromForm
                $script:Controls.txtStatus.Text | Should -Be "Settings saved"
            }

            It "Should show error on failed save" {
                Mock Save-RobocurseConfig {
                    return [PSCustomObject]@{ Success = $false; ErrorMessage = "Test error" }
                }
                Save-SettingsFromForm
                Should -Invoke Show-GuiError -Times 1
            }
        }

        Context "Email To Parsing Edge Cases" {
            BeforeAll {
                Mock Save-RobocurseConfig { return [PSCustomObject]@{ Success = $true; ErrorMessage = "" } }
                Mock Write-GuiLog { }

                $script:ConfigPath = "C:\test\config.json"
                $script:Config = [PSCustomObject]@{
                    GlobalSettings = [PSCustomObject]@{ MaxConcurrentJobs = 4; ThreadsPerJob = 8; BandwidthLimitMbps = 0; LogPath = ".\Logs" }
                    Email = [PSCustomObject]@{ Enabled = $false; SmtpServer = ""; Port = 587; UseTls = $true; CredentialTarget = ""; From = ""; To = @() }
                }

                $script:Controls = @{
                    sldSettingsJobs = [PSCustomObject]@{ Value = 4 }
                    sldSettingsThreads = [PSCustomObject]@{ Value = 8 }
                    txtSettingsBandwidth = [PSCustomObject]@{ Text = "0" }
                    txtSettingsLogPath = [PSCustomObject]@{ Text = ".\Logs" }
                    chkSettingsEmailEnabled = [PSCustomObject]@{ IsChecked = $false }
                    txtSettingsSmtp = [PSCustomObject]@{ Text = "" }
                    txtSettingsSmtpPort = [PSCustomObject]@{ Text = "587" }
                    chkSettingsTls = [PSCustomObject]@{ IsChecked = $true }
                    txtSettingsCredential = [PSCustomObject]@{ Text = "" }
                    txtSettingsEmailFrom = [PSCustomObject]@{ Text = "" }
                    txtSettingsEmailTo = [PSCustomObject]@{ Text = "" }
                    txtStatus = [PSCustomObject]@{ Text = "" }
                }
            }

            It "Should handle single email address" {
                $script:Controls.txtSettingsEmailTo.Text = "single@test.com"
                Save-SettingsFromForm
                $script:Config.Email.To | Should -HaveCount 1
                $script:Config.Email.To[0] | Should -Be "single@test.com"
            }

            It "Should handle trailing commas" {
                $script:Controls.txtSettingsEmailTo.Text = "user1@test.com, user2@test.com,"
                Save-SettingsFromForm
                $script:Config.Email.To | Should -HaveCount 2
            }

            It "Should handle multiple consecutive commas" {
                $script:Controls.txtSettingsEmailTo.Text = "user1@test.com,,,user2@test.com"
                Save-SettingsFromForm
                $script:Config.Email.To | Should -HaveCount 2
            }

            It "Should trim whitespace from each address" {
                $script:Controls.txtSettingsEmailTo.Text = "  user1@test.com  ,  user2@test.com  "
                Save-SettingsFromForm
                $script:Config.Email.To[0] | Should -Be "user1@test.com"
                $script:Config.Email.To[1] | Should -Be "user2@test.com"
            }
        }
    }
}
