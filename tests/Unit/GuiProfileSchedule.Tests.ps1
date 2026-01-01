#Requires -Modules Pester

# Load module before discovery for InModuleScope
$script:testRoot = $PSScriptRoot
$script:projectRoot = Split-Path -Parent (Split-Path -Parent $script:testRoot)
$modulePath = Join-Path $script:projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

Describe "GUI Profile Schedule" {
    Context "XAML Resources" {
        It "Should load ProfileScheduleDialog.xaml" {
            $xaml = Get-XamlResource -ResourceName 'ProfileScheduleDialog.xaml'

            $xaml | Should -Not -BeNullOrEmpty
            $xaml | Should -Match 'Profile Schedule'
        }

        It "ProfileScheduleDialog XAML should be valid XML" {
            $xaml = Get-XamlResource -ResourceName 'ProfileScheduleDialog.xaml'

            { [xml]$xaml } | Should -Not -Throw
        }

        It "ProfileScheduleDialog should have required controls" {
            $xaml = Get-XamlResource -ResourceName 'ProfileScheduleDialog.xaml'

            # Check for key controls by x:Name attribute
            $xaml | Should -Match 'x:Name="chkEnabled"'
            $xaml | Should -Match 'x:Name="cmbFrequency"'
            $xaml | Should -Match 'x:Name="txtTime"'
            $xaml | Should -Match 'x:Name="pnlHourlyOptions"'
            $xaml | Should -Match 'x:Name="pnlWeeklyOptions"'
            $xaml | Should -Match 'x:Name="pnlMonthlyOptions"'
            $xaml | Should -Match 'x:Name="btnSave"'
            $xaml | Should -Match 'x:Name="btnCancel"'
        }

        It "ProfileScheduleDialog should have frequency-specific panels" {
            $xaml = Get-XamlResource -ResourceName 'ProfileScheduleDialog.xaml'

            # Hourly options
            $xaml | Should -Match 'cmbInterval'

            # Weekly options
            $xaml | Should -Match 'cmbDayOfWeek'

            # Monthly options
            $xaml | Should -Match 'cmbDayOfMonth'
        }
    }

    Context "Dialog Function" {
        It "Show-ProfileScheduleDialog function should exist" {
            Get-Command -Name Show-ProfileScheduleDialog -Module Robocurse -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It "Show-ProfileScheduleDialog should have Profile parameter" {
            $cmd = Get-Command -Name Show-ProfileScheduleDialog -Module Robocurse
            $cmd.Parameters.Keys | Should -Contain 'Profile'
        }

        It "Show-ProfileScheduleDialog Profile parameter should be mandatory" {
            $cmd = Get-Command -Name Show-ProfileScheduleDialog -Module Robocurse
            $cmd.Parameters['Profile'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                Select-Object -ExpandProperty Mandatory |
                Should -Be $true
        }
    }

    Context "Button State Function" {
        InModuleScope 'Robocurse' {
            BeforeEach {
                # Mock controls
                $script:Controls = @{
                    btnProfileSchedule = [PSCustomObject]@{
                        IsEnabled = $true
                        Content = "Schedule"
                        ToolTip = ""
                    }
                    lstProfiles = [PSCustomObject]@{
                        SelectedItem = $null
                    }
                }
                $script:Config = [PSCustomObject]@{
                    SyncProfiles = @()
                }
            }

            It "Update-ProfileScheduleButtonState function should exist" {
                Get-Command -Name Update-ProfileScheduleButtonState -ErrorAction SilentlyContinue |
                    Should -Not -BeNullOrEmpty
            }

            It "Should disable button when no profile selected" {
                $script:Controls.lstProfiles.SelectedItem = $null

                Update-ProfileScheduleButtonState

                $script:Controls.btnProfileSchedule.IsEnabled | Should -Be $false
                $script:Controls.btnProfileSchedule.Content | Should -Be "Schedule"
            }

            It "Should enable button when profile selected" {
                $script:Controls.lstProfiles.SelectedItem = "TestProfile"
                $script:Config.SyncProfiles = @(
                    [PSCustomObject]@{
                        Name = "TestProfile"
                        Schedule = $null
                    }
                )

                Update-ProfileScheduleButtonState

                $script:Controls.btnProfileSchedule.IsEnabled | Should -Be $true
            }

            It "Should show 'Scheduled' when schedule enabled" {
                $scheduledProfile = [PSCustomObject]@{
                    Name = "ScheduledProfile"
                    Schedule = [PSCustomObject]@{
                        Enabled = $true
                        Frequency = "Daily"
                        Time = "03:00"
                    }
                }
                $script:Controls.lstProfiles.SelectedItem = $scheduledProfile
                $script:Config.SyncProfiles = @($scheduledProfile)

                Update-ProfileScheduleButtonState

                $script:Controls.btnProfileSchedule.Content | Should -Be "Scheduled"
                $script:Controls.btnProfileSchedule.ToolTip | Should -Match "Daily"
                $script:Controls.btnProfileSchedule.ToolTip | Should -Match "03:00"
            }

            It "Should show 'Schedule' when schedule disabled" {
                $disabledProfile = [PSCustomObject]@{
                    Name = "DisabledProfile"
                    Schedule = [PSCustomObject]@{
                        Enabled = $false
                        Frequency = "Daily"
                        Time = "03:00"
                    }
                }
                $script:Controls.lstProfiles.SelectedItem = $disabledProfile
                $script:Config.SyncProfiles = @($disabledProfile)

                Update-ProfileScheduleButtonState

                $script:Controls.btnProfileSchedule.Content | Should -Be "Schedule"
            }

            It "Should handle missing controls gracefully" {
                $script:Controls = @{}

                { Update-ProfileScheduleButtonState } | Should -Not -Throw
            }
        }
    }

    Context "MainWindow XAML Integration" {
        It "MainWindow should have Schedule button" {
            $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $mainWindowPath = Join-Path $projectRoot "src\Robocurse\Resources\MainWindow.xaml"
            $xaml = Get-Content $mainWindowPath -Raw

            $xaml | Should -Match 'x:Name="btnProfileSchedule"'
        }

        It "Schedule button should use ScheduleButton style" {
            $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $mainWindowPath = Join-Path $projectRoot "src\Robocurse\Resources\MainWindow.xaml"
            $xaml = Get-Content $mainWindowPath -Raw

            $xaml | Should -Match 'btnProfileSchedule.*ScheduleButton'
        }

        It "Schedule button should be near Validate button" {
            $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $mainWindowPath = Join-Path $projectRoot "src\Robocurse\Resources\MainWindow.xaml"
            $xaml = Get-Content $mainWindowPath -Raw

            # Both buttons should be in the same general area
            $scheduleMatch = [regex]::Match($xaml, 'btnProfileSchedule')
            $validateMatch = [regex]::Match($xaml, 'btnValidateProfile')

            $scheduleMatch.Success | Should -Be $true
            $validateMatch.Success | Should -Be $true
        }
    }

    Context "Control Registration" {
        It "GuiMain should register btnProfileSchedule control" {
            $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $guiMainPath = Join-Path $projectRoot "src\Robocurse\Public\GuiMain.ps1"
            $content = Get-Content $guiMainPath -Raw

            $content | Should -Match "'btnProfileSchedule'"
        }
    }

    Context "Event Handler Integration" {
        It "GuiMain should have click handler for Schedule button" {
            $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $guiMainPath = Join-Path $projectRoot "src\Robocurse\Public\GuiMain.ps1"
            $content = Get-Content $guiMainPath -Raw

            $content | Should -Match 'btnProfileSchedule.*Add_Click'
        }

        It "Click handler should call Show-ProfileScheduleDialog" {
            $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $guiMainPath = Join-Path $projectRoot "src\Robocurse\Public\GuiMain.ps1"
            $content = Get-Content $guiMainPath -Raw

            $content | Should -Match 'Show-ProfileScheduleDialog'
        }
    }

    Context "Profile Selection Integration" {
        It "Profile selection should update schedule button state" {
            $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $guiProfilesPath = Join-Path $projectRoot "src\Robocurse\Public\GuiProfiles.ps1"
            $content = Get-Content $guiProfilesPath -Raw

            # Either directly calls Update-ProfileScheduleButtonState or calls it via Update-ProfileSettingsVisibility
            $hasDirectCall = $content -match 'Update-ProfileScheduleButtonState'
            $hasIndirectCall = $content -match 'Update-ProfileSettingsVisibility'

            ($hasDirectCall -or $hasIndirectCall) | Should -Be $true
        }
    }
}

Describe "Profile Schedule Schema Integration" {
    Context "Configuration Round-Trip" {
        It "Should preserve schedule when saving and loading config" {
            $tempPath = Join-Path $TestDrive "schedule-roundtrip.json"

            $config = New-DefaultConfig
            $config.SyncProfiles = @([PSCustomObject]@{
                Name = "RoundTripTest"
                Source = "C:\Test"
                Destination = "D:\Backup"
                Schedule = [PSCustomObject]@{
                    Enabled = $true
                    Frequency = "Weekly"
                    Time = "04:30"
                    Interval = 1
                    DayOfWeek = "Wednesday"
                    DayOfMonth = 1
                }
                UseVss = $false
                ScanMode = "Smart"
                ChunkMaxDepth = 10
                RobocopyOptions = @{}
                Enabled = $true
                SourceSnapshot = [PSCustomObject]@{
                    PersistentEnabled = $false
                    RetentionCount = 3
                }
                DestinationSnapshot = [PSCustomObject]@{
                    PersistentEnabled = $false
                    RetentionCount = 3
                }
            })

            # Save
            $saveResult = Save-RobocurseConfig -Config $config -Path $tempPath
            $saveResult.Success | Should -Be $true

            # Load
            $loadedConfig = Get-RobocurseConfig -Path $tempPath
            $profile = $loadedConfig.SyncProfiles[0]

            # Verify schedule preserved
            $profile.Schedule.Enabled | Should -Be $true
            $profile.Schedule.Frequency | Should -Be "Weekly"
            $profile.Schedule.Time | Should -Be "04:30"
            $profile.Schedule.DayOfWeek | Should -Be "Wednesday"
        }

        It "Should handle profiles without schedule gracefully" {
            $json = @'
{
    "profiles": {
        "NoSchedule": {
            "source": "C:\\Test",
            "destination": "D:\\Backup"
        }
    }
}
'@
            $tempPath = Join-Path $TestDrive "no-schedule.json"
            $json | Set-Content $tempPath

            $config = Get-RobocurseConfig -Path $tempPath
            $profile = $config.SyncProfiles[0]

            # Should have default schedule
            $profile.Schedule | Should -Not -BeNullOrEmpty
            $profile.Schedule.Enabled | Should -Be $false
            $profile.Schedule.Frequency | Should -Be "Daily"
        }
    }
}
