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
