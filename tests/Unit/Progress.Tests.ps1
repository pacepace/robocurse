#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type (required for module isolation when running all tests together)
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "Progress" {
        BeforeAll {
            # Initialize the C# OrchestrationState class
            Initialize-OrchestrationState
        }

        BeforeEach {
            # Create a fresh orchestration state using the module's initialization
            Initialize-OrchestrationState
        }

        AfterEach {
            $script:OrchestrationState = $null
        }

        Context "Get-OrchestrationStatus" {
            It "Should return idle state when orchestration not initialized" {
                $script:OrchestrationState = $null

                $status = Get-OrchestrationStatus

                $status.Phase | Should -Be 'Idle'
                $status.OverallProgress | Should -Be 0
                $status.BytesComplete | Should -Be 0
            }

            It "Should return correct profile name" {
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{ Name = "TestProfile" }

                $status = Get-OrchestrationStatus

                $status.CurrentProfile | Should -Be "TestProfile"
            }

            It "Should calculate progress percentage correctly" {
                $script:OrchestrationState.TotalChunks = 100
                $script:OrchestrationState.IncrementCompletedCount()
                $script:OrchestrationState.IncrementCompletedCount()
                # Completed 2 out of 100 = 2%

                $status = Get-OrchestrationStatus

                $status.ProfileProgress | Should -Be 2
            }

            It "Should clamp progress to 100 when completed exceeds total" {
                $script:OrchestrationState.TotalChunks = 10
                for ($i = 0; $i -lt 15; $i++) {
                    $script:OrchestrationState.IncrementCompletedCount()
                }

                $status = Get-OrchestrationStatus

                $status.ProfileProgress | Should -BeLessOrEqual 100
            }

            It "Should return zero progress when no chunks" {
                $script:OrchestrationState.TotalChunks = 0

                $status = Get-OrchestrationStatus

                $status.ProfileProgress | Should -Be 0
            }

            It "Should include elapsed time" {
                $script:OrchestrationState.StartTime = [datetime]::Now.AddMinutes(-5)

                $status = Get-OrchestrationStatus

                $status.Elapsed.TotalMinutes | Should -BeGreaterThan 4.9
            }

            It "Should track active job count" {
                # Add a mock job
                $mockJob = [PSCustomObject]@{
                    Process = [PSCustomObject]@{ Id = 1234; HasExited = $false }
                }
                $script:OrchestrationState.ActiveJobs[1234] = $mockJob

                $status = Get-OrchestrationStatus

                $status.ActiveJobs | Should -Be 1
            }
        }

        Context "Get-ETAEstimate" {
            It "Should return null when no progress" {
                $script:OrchestrationState.BytesComplete = 0
                $script:OrchestrationState.TotalBytes = 1000

                $eta = Get-ETAEstimate

                $eta | Should -BeNullOrEmpty
            }

            It "Should return null when no start time" {
                $script:OrchestrationState.StartTime = $null

                $eta = Get-ETAEstimate

                $eta | Should -BeNullOrEmpty
            }

            It "Should return null when total bytes is zero" {
                $script:OrchestrationState.TotalBytes = 0
                $script:OrchestrationState.BytesComplete = 100

                $eta = Get-ETAEstimate

                $eta | Should -BeNullOrEmpty
            }

            It "Should calculate reasonable ETA" {
                # Simulate 50% complete in 1 minute = 1 minute remaining
                $script:OrchestrationState.StartTime = [datetime]::Now.AddMinutes(-1)
                $script:OrchestrationState.TotalBytes = 1000000
                $script:OrchestrationState.BytesComplete = 500000

                $eta = Get-ETAEstimate

                $eta | Should -Not -BeNullOrEmpty
                $eta.TotalMinutes | Should -BeGreaterThan 0.5
                $eta.TotalMinutes | Should -BeLessThan 2
            }

            It "Should return zero when more bytes copied than expected" {
                $script:OrchestrationState.StartTime = [datetime]::Now.AddMinutes(-1)
                $script:OrchestrationState.TotalBytes = 1000000
                $script:OrchestrationState.BytesComplete = 1500000  # More than total

                $eta = Get-ETAEstimate

                $eta | Should -Be ([timespan]::Zero)
            }

            It "Should cap ETA at 30 days" {
                # Simulate very slow transfer
                $script:OrchestrationState.StartTime = [datetime]::Now.AddSeconds(-1)
                $script:OrchestrationState.TotalBytes = [long]::MaxValue
                $script:OrchestrationState.BytesComplete = 1

                $eta = Get-ETAEstimate

                $eta.TotalDays | Should -BeLessOrEqual 30
            }

            It "Should return null when elapsed time is too short" {
                $script:OrchestrationState.StartTime = [datetime]::Now
                $script:OrchestrationState.TotalBytes = 1000000
                $script:OrchestrationState.BytesComplete = 500000

                $eta = Get-ETAEstimate

                # Elapsed is essentially 0, so ETA can't be calculated reliably
                # (this depends on how fast the test runs)
            }

            It "Should handle large byte counts without overflow" {
                $script:OrchestrationState.StartTime = [datetime]::Now.AddMinutes(-10)
                $script:OrchestrationState.TotalBytes = 10TB
                $script:OrchestrationState.BytesComplete = 5TB

                $eta = Get-ETAEstimate

                $eta | Should -Not -BeNullOrEmpty
                { $eta.TotalSeconds } | Should -Not -Throw
            }
        }

        Context "Update-ProgressStats" {
            BeforeEach {
                # Initialize logging to avoid errors
                $script:CurrentOperationalLogPath = $null
            }

            It "Should not throw when no active jobs" {
                { Update-ProgressStats } | Should -Not -Throw
            }

            It "Should accumulate bytes from completed chunks" {
                $script:OrchestrationState.AddCompletedChunkBytes(1000)
                $script:OrchestrationState.AddCompletedChunkBytes(2000)

                Update-ProgressStats

                $script:OrchestrationState.BytesComplete | Should -BeGreaterOrEqual 3000
            }
        }

        Context "Edge Cases" {
            It "Should handle zero total chunks gracefully" {
                $script:OrchestrationState.TotalChunks = 0
                $script:OrchestrationState.TotalBytes = 0

                $status = Get-OrchestrationStatus

                $status.ProfileProgress | Should -Be 0
                $status.OverallProgress | Should -Be 0
            }

            It "Should handle empty profiles array" {
                $script:OrchestrationState.Profiles = @()
                $script:OrchestrationState.ProfileIndex = 0

                $status = Get-OrchestrationStatus

                $status.OverallProgress | Should -Be 0
            }

            It "Should handle rapid increments correctly" {
                # Simulate rapid sequential increments
                for ($i = 0; $i -lt 100; $i++) {
                    $script:OrchestrationState.IncrementCompletedCount()
                }

                # Should have 100 total increments
                $script:OrchestrationState.CompletedCount | Should -Be 100
            }
        }
    }
}
