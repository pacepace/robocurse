BeforeAll {
    # Get the path to the main script
    $mainScriptPath = Join-Path $PSScriptRoot ".." "Robocurse.ps1"

    # Dot-source the script to load functions
    # The script now auto-detects dot-sourcing and skips main execution
    . $mainScriptPath -Help
}

Describe "Robocurse Main Script" {
    Context "Script Loading" {
        It "Should load without errors" {
            $mainScriptPath = Join-Path $PSScriptRoot ".." "Robocurse.ps1"
            Test-Path $mainScriptPath | Should -Be $true
        }

        It "Should have all required regions defined" {
            $mainScriptPath = Join-Path $PSScriptRoot ".." "Robocurse.ps1"
            $scriptContent = Get-Content $mainScriptPath -Raw

            $scriptContent | Should -Match "#region.*CONFIGURATION"
            $scriptContent | Should -Match "#region.*LOGGING"
            $scriptContent | Should -Match "#region.*DIRECTORY PROFILING"
            $scriptContent | Should -Match "#region.*CHUNKING"
            $scriptContent | Should -Match "#region.*ROBOCOPY WRAPPER"
            $scriptContent | Should -Match "#region.*ORCHESTRATION"
            $scriptContent | Should -Match "#region.*PROGRESS"
            $scriptContent | Should -Match "#region.*VSS"
            $scriptContent | Should -Match "#region.*EMAIL"
            $scriptContent | Should -Match "#region.*SCHEDULING"
            $scriptContent | Should -Match "#region.*GUI"
            $scriptContent | Should -Match "#region.*MAIN"
        }
    }

    Context "Configuration Functions" {
        It "Should have Get-RobocurseConfig function" {
            Get-Command Get-RobocurseConfig -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Save-RobocurseConfig function" {
            Get-Command Save-RobocurseConfig -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Test-RobocurseConfig function" {
            Get-Command Test-RobocurseConfig -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "Logging Functions" {
        It "Should have Write-RobocurseLog function" {
            Get-Command Write-RobocurseLog -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Write-SiemEvent function" {
            Get-Command Write-SiemEvent -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Invoke-LogRotation function" {
            Get-Command Invoke-LogRotation -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "Directory Profiling Functions" {
        It "Should have Get-DirectoryProfile function" {
            Get-Command Get-DirectoryProfile -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Invoke-RobocopyList function" {
            Get-Command Invoke-RobocopyList -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Get-DirectoryChildren function" {
            Get-Command Get-DirectoryChildren -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "Chunking Functions" {
        It "Should have Get-DirectoryChunks function" {
            Get-Command Get-DirectoryChunks -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have New-SmartChunks function" {
            Get-Command New-SmartChunks -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have New-FlatChunks function" {
            Get-Command New-FlatChunks -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "Robocopy Wrapper Functions" {
        It "Should have Start-RobocopyJob function" {
            Get-Command Start-RobocopyJob -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Get-RobocopyExitMeaning function" {
            Get-Command Get-RobocopyExitMeaning -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have ConvertFrom-RobocopyLog function" {
            Get-Command ConvertFrom-RobocopyLog -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "Orchestration Functions" {
        It "Should have Start-ReplicationRun function" {
            Get-Command Start-ReplicationRun -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Invoke-ReplicationTick function" {
            Get-Command Invoke-ReplicationTick -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Stop-AllJobs function" {
            Get-Command Stop-AllJobs -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "Progress Functions" {
        It "Should have Get-RobocopyProgress function" {
            Get-Command Get-RobocopyProgress -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Update-ProgressStats function" {
            Get-Command Update-ProgressStats -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Get-ETAEstimate function" {
            Get-Command Get-ETAEstimate -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Get-OrchestrationStatus function" {
            Get-Command Get-OrchestrationStatus -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "VSS Functions" {
        It "Should have New-VssSnapshot function" {
            Get-Command New-VssSnapshot -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Remove-VssSnapshot function" {
            Get-Command Remove-VssSnapshot -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Get-VssPath function" {
            Get-Command Get-VssPath -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "Email Functions" {
        It "Should have Get-SmtpCredential function" {
            Get-Command Get-SmtpCredential -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Save-SmtpCredential function" {
            Get-Command Save-SmtpCredential -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Send-CompletionEmail function" {
            Get-Command Send-CompletionEmail -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "Scheduling Functions" {
        It "Should have Register-RobocurseTask function" {
            Get-Command Register-RobocurseTask -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Unregister-RobocurseTask function" {
            Get-Command Unregister-RobocurseTask -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "GUI Functions" {
        It "Should have Initialize-RobocurseGui function" {
            Get-Command Initialize-RobocurseGui -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Update-GuiProgress function" {
            Get-Command Update-GuiProgress -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Should have Show-GuiError function" {
            Get-Command Show-GuiError -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Configuration File" {
    Context "Example Configuration" {
        It "Should have example config file" {
            $configPath = Join-Path $PSScriptRoot ".." "Robocurse.config.json"
            Test-Path $configPath | Should -Be $true
        }

        It "Should be valid JSON" {
            $configPath = Join-Path $PSScriptRoot ".." "Robocurse.config.json"
            { Get-Content $configPath -Raw | ConvertFrom-Json } | Should -Not -Throw
        }

        It "Should have required top-level properties" {
            $configPath = Join-Path $PSScriptRoot ".." "Robocurse.config.json"
            $config = Get-Content $configPath -Raw | ConvertFrom-Json

            $config.PSObject.Properties.Name | Should -Contain "profiles"
            $config.PSObject.Properties.Name | Should -Contain "global"
        }
    }
}
