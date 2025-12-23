# Script Path Enforcement Tests
# Ensures the monolith captures script path correctly for scheduled tasks

Describe "Script Path Initialization" {
    BeforeAll {
        $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:BuildScript = Join-Path $script:ProjectRoot "build\Build-Robocurse.ps1"
        $script:DistScript = Join-Path $script:ProjectRoot "dist\Robocurse.ps1"
        $script:ProfileSchedulePs1 = Join-Path $script:ProjectRoot "src\Robocurse\Public\ProfileSchedule.ps1"
    }

    Context "Build script captures script path" {
        It "Build script includes RobocurseScriptPath initialization" {
            $buildContent = Get-Content $script:BuildScript -Raw
            $buildContent | Should -Match '\$script:RobocurseScriptPath\s*=\s*\$PSCommandPath'
        }
    }

    Context "Monolith has script path initialization" {
        It "Dist file contains RobocurseScriptPath assignment" {
            Test-Path $script:DistScript | Should -BeTrue -Because "dist file should exist"
            $distContent = Get-Content $script:DistScript -Raw
            $distContent | Should -Match '\$script:RobocurseScriptPath\s*=\s*\$PSCommandPath'
        }

        It "RobocurseScriptPath is set before any functions are called" {
            $distContent = Get-Content $script:DistScript -Raw

            # Find position of script path assignment
            $pathAssignmentMatch = [regex]::Match($distContent, '\$script:RobocurseScriptPath\s*=\s*\$PSCommandPath')
            $pathAssignmentMatch.Success | Should -BeTrue

            # Find position of first function definition
            $firstFunctionMatch = [regex]::Match($distContent, 'function\s+\w+-\w+')
            $firstFunctionMatch.Success | Should -BeTrue

            # Script path should be set before functions
            $pathAssignmentMatch.Index | Should -BeLessThan $firstFunctionMatch.Index -Because "script path must be captured before functions are defined"
        }
    }

    Context "ProfileSchedule uses script path variable" {
        It "New-ProfileScheduledTask uses script:RobocurseScriptPath" {
            $content = Get-Content $script:ProfileSchedulePs1 -Raw
            $content | Should -Match '\$script:RobocurseScriptPath'
        }

        It "Does not use PSScriptRoot for script path detection" {
            $content = Get-Content $script:ProfileSchedulePs1 -Raw
            # Should not have the old pattern that caused the bug
            $content | Should -Not -Match 'Split-Path\s+\$PSScriptRoot\s+-Parent.*Robocurse\.ps1' -Because "PSScriptRoot parent is wrong directory in monolith"
        }

        It "Has fallback if RobocurseScriptPath is not set" {
            $content = Get-Content $script:ProfileSchedulePs1 -Raw
            # Should have some fallback mechanism (uses [\s\S] for multiline)
            $content | Should -Match 'if\s*\(\s*\$script:RobocurseScriptPath\s*\)[\s\S]*?else'
        }

        It "Sets WorkingDirectory on scheduled task action" {
            $content = Get-Content $script:ProfileSchedulePs1 -Raw
            $content | Should -Match 'New-ScheduledTaskAction.*-WorkingDirectory' -Because "task needs working directory set for relative paths in config"
        }

        It "Includes -Headless flag in scheduled task command" {
            $content = Get-Content $script:ProfileSchedulePs1 -Raw
            $content | Should -Match '\$argument.*-Headless' -Because "Task Scheduler cannot run GUI, must use headless mode"
        }
    }
}
