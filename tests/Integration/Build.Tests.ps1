# Build validation tests to ensure the monolith is built correctly
# These tests verify that all required modules are included and functions are exported

BeforeDiscovery {
    # Define paths at discovery time for -Skip evaluation and data-driven tests
    $script:projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:buildScript = Join-Path $script:projectRoot "build\Build-Robocurse.ps1"
    $script:distPath = Join-Path $script:projectRoot "dist\Robocurse.ps1"
    $script:srcPath = Join-Path $script:projectRoot "src\Robocurse\Public"
}

BeforeAll {
    # Re-assign for test execution
    $script:projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:buildScript = Join-Path $script:projectRoot "build\Build-Robocurse.ps1"
    $script:distPath = Join-Path $script:projectRoot "dist\Robocurse.ps1"
    $script:srcPath = Join-Path $script:projectRoot "src\Robocurse\Public"
}

Describe "Build Script Configuration" {
    It "Should have build script present" {
        Test-Path $script:buildScript | Should -Be $true
    }

    It "Should include Checkpoint.ps1 in module order" {
        $buildContent = Get-Content $script:buildScript -Raw
        $buildContent | Should -Match "Checkpoint\.ps1"
    }

    It "Should include all required modules in correct order" {
        $buildContent = Get-Content $script:buildScript -Raw

        # These modules MUST be in the build script
        $requiredModules = @(
            'Utility.ps1',
            'Configuration.ps1',
            'Logging.ps1',
            'DirectoryProfiling.ps1',
            'Chunking.ps1',
            'Robocopy.ps1',
            'Checkpoint.ps1',  # Must be before Orchestration
            'Orchestration.ps1',
            'Progress.ps1',
            'VSS.ps1',
            'Email.ps1',
            'Scheduling.ps1',
            'GUI.ps1',
            'Main.ps1'
        )

        foreach ($module in $requiredModules) {
            $buildContent | Should -Match $module -Because "$module should be in build script"
        }
    }

    It "Should have Checkpoint.ps1 before Orchestration.ps1" {
        $buildContent = Get-Content $script:buildScript -Raw

        # Find positions of both modules in the content
        $checkpointPos = $buildContent.IndexOf('Checkpoint.ps1')
        $orchestrationPos = $buildContent.IndexOf('Orchestration.ps1')

        $checkpointPos | Should -BeLessThan $orchestrationPos -Because "Checkpoint must load before Orchestration"
    }
}

Describe "Built Monolith Validation" -Skip:(-not (Test-Path $script:distPath)) {
    BeforeAll {
        # Read the monolith content for analysis
        $script:monolithContent = Get-Content $script:distPath -Raw
    }

    Context "Module Inclusion" {
        It "Should contain Utility functions" {
            $script:monolithContent | Should -Match "function Test-IsWindowsPlatform"
            $script:monolithContent | Should -Match "function New-OperationResult"
        }

        It "Should contain Configuration functions" {
            $script:monolithContent | Should -Match "function Get-RobocurseConfig"
            $script:monolithContent | Should -Match "function Save-RobocurseConfig"
        }

        It "Should contain Checkpoint functions" {
            $script:monolithContent | Should -Match "function Save-ReplicationCheckpoint"
            $script:monolithContent | Should -Match "function Get-ReplicationCheckpoint"
            $script:monolithContent | Should -Match "function Remove-ReplicationCheckpoint"
            $script:monolithContent | Should -Match "function Test-ChunkAlreadyCompleted"
        }

        It "Should contain Orchestration functions" {
            $script:monolithContent | Should -Match "function Initialize-OrchestrationState"
            $script:monolithContent | Should -Match "function Start-ReplicationRun"
        }

        It "Should contain VSS functions" {
            $script:monolithContent | Should -Match "function New-VssSnapshot"
            $script:monolithContent | Should -Match "function Remove-VssSnapshot"
        }

        It "Should contain Email functions" {
            $script:monolithContent | Should -Match "function Send-CompletionEmail"
        }

        It "Should contain Scheduling functions" {
            $script:monolithContent | Should -Match "function Register-RobocurseTask"
        }

        It "Should contain GUI functions" {
            $script:monolithContent | Should -Match "function Initialize-RobocurseGui"
        }

        It "Should contain Main functions" {
            $script:monolithContent | Should -Match "function Start-RobocurseMain"
        }
    }

    Context "Function Definitions Before Use" {
        It "Should define checkpoint functions before they are called in Orchestration" {
            # Find the first definition of Save-ReplicationCheckpoint
            $checkpointDefPos = $script:monolithContent.IndexOf("function Save-ReplicationCheckpoint")

            # Find first call to Save-ReplicationCheckpoint in Orchestration code
            $checkpointCallPos = $script:monolithContent.IndexOf("Save-ReplicationCheckpoint -")

            # Definition must come before first call
            if ($checkpointCallPos -gt 0) {
                $checkpointDefPos | Should -BeLessThan $checkpointCallPos -Because "Checkpoint function must be defined before use"
            }
        }
    }
}

Describe "Module Manifest Validation" {
    BeforeAll {
        $manifestPath = Join-Path $script:projectRoot "src\Robocurse\Robocurse.psd1"
        $script:manifestContent = Get-Content $manifestPath -Raw
    }

    It "Should have correct checkpoint function names in FunctionsToExport" {
        $script:manifestContent | Should -Match "'Save-ReplicationCheckpoint'"
        $script:manifestContent | Should -Match "'Get-ReplicationCheckpoint'"
        $script:manifestContent | Should -Match "'Remove-ReplicationCheckpoint'"
    }

    It "Should NOT have old incorrect checkpoint function names" {
        $script:manifestContent | Should -Not -Match "'Save-Checkpoint'"
        $script:manifestContent | Should -Not -Match "'Get-Checkpoint'"
        $script:manifestContent | Should -Not -Match "'Resume-FromCheckpoint'"
    }

    It "Should NOT declare non-existent functions" {
        $script:manifestContent | Should -Not -Match "'ConvertTo-SafeFilename'"
        $script:manifestContent | Should -Not -Match "'Build-RobocopyArguments'"
        $script:manifestContent | Should -Not -Match "'Get-VssShadowCopyId'"
    }

    It "Should have correct robocopy function names" {
        $script:manifestContent | Should -Match "'New-RobocopyArguments'"
    }
}

Describe "Source Module Validation" {
    Context "All Required Module Files Exist" {
        $requiredModules = @(
            'Utility.ps1',
            'Configuration.ps1',
            'Logging.ps1',
            'DirectoryProfiling.ps1',
            'Chunking.ps1',
            'Robocopy.ps1',
            'Checkpoint.ps1',
            'Orchestration.ps1',
            'Progress.ps1',
            'VSS.ps1',
            'Email.ps1',
            'Scheduling.ps1',
            'GUI.ps1',
            'Main.ps1'
        )

        foreach ($module in $requiredModules) {
            It "Should have $module" {
                $modulePath = Join-Path $script:srcPath $module
                Test-Path $modulePath | Should -Be $true
            }
        }
    }
}

Describe "Monolith Background Runspace Support" -Skip:(-not (Test-Path $script:distPath)) {
    BeforeAll {
        $script:monolithContent = Get-Content $script:distPath -Raw
        # Define Test-IsWindowsPlatform locally if not available (for -Skip evaluation)
        if (-not (Get-Command 'Test-IsWindowsPlatform' -ErrorAction SilentlyContinue)) {
            function script:Test-IsWindowsPlatform { return ($env:OS -eq 'Windows_NT') }
        }
    }

    It "Should set RobocurseScriptPath for background runspace loading" {
        # The monolith must set $script:RobocurseScriptPath so the GUI can load
        # the script in a background runspace
        $script:monolithContent | Should -Match '\$script:RobocurseScriptPath\s*=' -Because "Monolith must set RobocurseScriptPath for background runspace"
    }

    It "Should set RobocurseScriptPath before main execution" {
        # Find position of RobocurseScriptPath assignment
        $scriptPathPos = $script:monolithContent.IndexOf('$script:RobocurseScriptPath')

        # Find position of Start-RobocurseMain call
        $mainPos = $script:monolithContent.IndexOf('Start-RobocurseMain')

        $scriptPathPos | Should -BeGreaterThan 0 -Because "RobocurseScriptPath should be set"
        $scriptPathPos | Should -BeLessThan $mainPos -Because "RobocurseScriptPath must be set before main execution"
    }

    Context "Monolith Background Runspace Execution" -Skip:($env:OS -ne 'Windows_NT') {
        BeforeAll {
            # Create temp directories for test
            $script:MonolithTestDir = Join-Path $env:TEMP "RobocurseMonolithTest_$(Get-Random)"
            $script:MonolithLogDir = Join-Path $script:MonolithTestDir "Logs"
            New-Item -ItemType Directory -Path $script:MonolithLogDir -Force | Out-Null

            # Create a simple config file
            $script:MonolithConfigPath = Join-Path $script:MonolithTestDir "test.config.json"
            $config = @{
                global = @{ concurrency = @{ maxJobs = 2 } }
                profiles = @{
                    TestProfile = @{
                        source = "C:\TestSource"
                        destination = "C:\TestDest"
                        enabled = $true
                    }
                }
            }
            $config | ConvertTo-Json -Depth 10 | Out-File $script:MonolithConfigPath -Encoding utf8
        }

        AfterAll {
            if (Test-Path $script:MonolithTestDir) {
                Remove-Item -Path $script:MonolithTestDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should be loadable in a background runspace with -Help" {
            # This tests that the monolith can be dot-sourced with -Help
            # which is how the GUI loads it in a background runspace

            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
            $runspace.Open()

            $powershell = [powershell]::Create()
            $powershell.Runspace = $runspace

            $testScript = @"
                param(`$ScriptPath)

                try {
                    # This is exactly what the GUI background script does
                    . `$ScriptPath -Help

                    # Check that key functions are available
                    if (-not (Get-Command 'Start-ReplicationRun' -ErrorAction SilentlyContinue)) {
                        return "FAILED: Start-ReplicationRun not found"
                    }
                    if (-not (Get-Command 'Initialize-LogSession' -ErrorAction SilentlyContinue)) {
                        return "FAILED: Initialize-LogSession not found"
                    }
                    if (-not (Get-Command 'Get-RobocurseConfig' -ErrorAction SilentlyContinue)) {
                        return "FAILED: Get-RobocurseConfig not found"
                    }

                    # Check that RobocurseScriptPath was set
                    if (-not `$script:RobocurseScriptPath) {
                        return "FAILED: RobocurseScriptPath not set"
                    }

                    return "SUCCESS"
                }
                catch {
                    return "ERROR: `$(`$_.Exception.Message)"
                }
"@

            $powershell.AddScript($testScript)
            $powershell.AddArgument($script:distPath)

            $handle = $powershell.BeginInvoke()
            $timeout = [TimeSpan]::FromSeconds(30)
            $completed = $handle.AsyncWaitHandle.WaitOne($timeout)

            $completed | Should -Be $true -Because "Monolith should load within timeout"

            $result = $powershell.EndInvoke($handle)
            $result | Should -Be "SUCCESS" -Because "Monolith should load all required functions in background runspace"

            $powershell.Dispose()
            $runspace.Close()
            $runspace.Dispose()
        }

        It "Should be able to initialize log session after loading" {
            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
            $runspace.Open()

            $powershell = [powershell]::Create()
            $powershell.Runspace = $runspace

            $testScript = @"
                param(`$ScriptPath, `$LogDir)

                try {
                    . `$ScriptPath -Help

                    # Initialize log session (this is what was missing and caused the original bug)
                    Initialize-LogSession -LogRoot `$LogDir

                    # Verify we can now write logs
                    Write-RobocurseLog -Message "Test from monolith" -Level Info -Component Test

                    return "SUCCESS"
                }
                catch {
                    return "ERROR: `$(`$_.Exception.Message)"
                }
"@

            $powershell.AddScript($testScript)
            $powershell.AddArgument($script:distPath)
            $powershell.AddArgument($script:MonolithLogDir)

            $handle = $powershell.BeginInvoke()
            $timeout = [TimeSpan]::FromSeconds(30)
            $handle.AsyncWaitHandle.WaitOne($timeout) | Out-Null

            $result = $powershell.EndInvoke($handle)
            # EndInvoke returns an array, get the last item (the return value)
            $returnValue = @($result)[-1]
            $returnValue | Should -Be "SUCCESS" -Because "Should be able to initialize logging in monolith background runspace"

            $powershell.Dispose()
            $runspace.Close()
            $runspace.Dispose()
        }
    }
}
