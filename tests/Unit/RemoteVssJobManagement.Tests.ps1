#Requires -Modules Pester

# Load module at discovery time so InModuleScope can find it
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type (needed before tests run)
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "Remote VSS Support in JobManagement" {
        BeforeEach {
            # Reset state before each test
            $script:OrchestrationState.Reset()

            # Set up script-scope config variables that Start-ProfileReplication needs
            $script:Config = [PSCustomObject]@{
                SyncProfiles = @()
            }
            $script:ConfigPath = "C:\test\config.json"

            # Mock logging functions
            Mock Write-RobocurseLog { }
            Mock Write-SiemEvent { }

            # Mock pre-flight validation functions
            Mock Test-SourcePathAccessible {
                New-OperationResult -Success $true
            }
            Mock Test-DestinationDiskSpace {
                New-OperationResult -Success $true
            }
            Mock Test-RobocopyOptionsValid {
                New-OperationResult -Success $true
            }

            # Mock directory profiling to prevent actual file system access
            Mock Get-DirectoryProfile {
                [PSCustomObject]@{
                    TotalSize = 1GB
                    FileCount = 100
                }
            }

            # Mock chunking functions
            Mock New-SmartChunks { @() }
            Mock New-FlatChunks { @() }

            # Mock persistent snapshot handling
            Mock Invoke-ProfileSnapshots {
                New-OperationResult -Success $true -Data @{
                    SourceSnapshotCreated = $false
                    DestinationSnapshotCreated = $false
                }
            }

            # Mock Test-Path to allow source paths
            Mock Test-Path { $true }

            # Mock network path handling (added for Session 0 scheduled task support)
            Mock Get-NetworkCredential { $null }
            Mock Mount-NetworkPaths {
                @{
                    Mappings = @()
                    SourcePath = $SourcePath
                    DestinationPath = $DestinationPath
                }
            }
            Mock Dismount-NetworkPaths { }
        }

        Context "UNC Path Detection" {
            It "Should detect standard UNC paths" {
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "\\192.168.1.100\share\folder"
                    Destination = "D:\Backup"
                    UseVSS = $true
                }

                # Verify UNC regex pattern matches
                $isUncPath = $profile.Source -match '^\\\\[^\\]+\\[^\\]+'
                $isUncPath | Should -Be $true
            }

            It "Should detect UNC paths with hostnames" {
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "\\fileserver\data"
                    Destination = "D:\Backup"
                    UseVSS = $true
                }

                $isUncPath = $profile.Source -match '^\\\\[^\\]+\\[^\\]+'
                $isUncPath | Should -Be $true
            }

            It "Should NOT detect local paths as UNC" {
                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Users\Documents"
                    Destination = "D:\Backup"
                    UseVSS = $true
                }

                $isUncPath = $profile.Source -match '^\\\\[^\\]+\\[^\\]+'
                $isUncPath | Should -Be $false
            }
        }

        Context "Remote VSS Function Calls for UNC Paths" {
            BeforeAll {
                $script:testProfile = [PSCustomObject]@{
                    Name = "RemoteVSSProfile"
                    Source = "\\192.168.123.1\data"
                    Destination = "D:\Backup"
                    UseVSS = $true
                    ScanMode = "Smart"
                    ChunkMaxDepth = 3
                }
            }

            It "Should call Test-RemoteVssSupported for UNC paths" {
                Mock Test-RemoteVssSupported {
                    New-OperationResult -Success $false -ErrorMessage "Server not accessible"
                }

                Start-ProfileReplication -Profile $script:testProfile -MaxConcurrentJobs 2

                Should -Invoke Test-RemoteVssSupported -Times 1 -ParameterFilter {
                    $UncPath -eq "\\192.168.123.1\data"
                }
            }

            It "Should NOT call Test-VssSupported for UNC paths" {
                Mock Test-RemoteVssSupported {
                    New-OperationResult -Success $false -ErrorMessage "Not supported"
                }
                Mock Test-VssSupported { $true }

                Start-ProfileReplication -Profile $script:testProfile -MaxConcurrentJobs 2

                Should -Not -Invoke Test-VssSupported
            }

            It "Should create remote VSS snapshot when remote VSS is supported" {
                Mock Test-RemoteVssSupported {
                    New-OperationResult -Success $true -Data @{ ServerName = "192.168.123.1" }
                }
                Mock New-RemoteVssSnapshot {
                    New-OperationResult -Success $true -Data ([PSCustomObject]@{
                        ShadowId = "{remote-test-id}"
                        ShadowPath = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1"
                        ServerName = "192.168.123.1"
                        ShareName = "data"
                        ShareLocalPath = "D:\SharedData"
                        IsRemote = $true
                    })
                }
                Mock New-RemoteVssJunction {
                    New-OperationResult -Success $true -Data ([PSCustomObject]@{
                        JunctionLocalPath = "D:\SharedData\.robocurse-vss-12345"
                        ServerName = "192.168.123.1"
                    })
                }
                Mock Get-RemoteVssPath { "\\192.168.123.1\data\.robocurse-vss-12345\folder" }

                Start-ProfileReplication -Profile $script:testProfile -MaxConcurrentJobs 2

                Should -Invoke New-RemoteVssSnapshot -Times 1
                Should -Invoke New-RemoteVssJunction -Times 1
            }

            It "Should continue without VSS when remote check fails" {
                Mock Test-RemoteVssSupported {
                    New-OperationResult -Success $false -ErrorMessage "WinRM not enabled"
                }

                Start-ProfileReplication -Profile $script:testProfile -MaxConcurrentJobs 2

                Should -Invoke Write-RobocurseLog -ParameterFilter {
                    $Message -like "*Remote VSS not supported*"
                }
                $script:OrchestrationState.CurrentVssSnapshot | Should -BeNullOrEmpty
            }

            It "Should clean up snapshot if junction creation fails" {
                Mock Test-RemoteVssSupported {
                    New-OperationResult -Success $true -Data @{ ServerName = "192.168.123.1" }
                }
                Mock New-RemoteVssSnapshot {
                    New-OperationResult -Success $true -Data ([PSCustomObject]@{
                        ShadowId = "{remote-test-id}"
                        ServerName = "192.168.123.1"
                        IsRemote = $true
                    })
                }
                Mock New-RemoteVssJunction {
                    New-OperationResult -Success $false -ErrorMessage "Junction creation failed"
                }
                Mock Remove-RemoteVssSnapshot {
                    New-OperationResult -Success $true
                }

                Start-ProfileReplication -Profile $script:testProfile -MaxConcurrentJobs 2

                Should -Invoke Remove-RemoteVssSnapshot -Times 1 -ParameterFilter {
                    $ShadowId -eq "{remote-test-id}" -and $ServerName -eq "192.168.123.1"
                }
                $script:OrchestrationState.CurrentVssSnapshot | Should -BeNullOrEmpty
            }
        }

        Context "Local VSS Still Works" {
            BeforeAll {
                $script:localProfile = [PSCustomObject]@{
                    Name = "LocalVSSProfile"
                    Source = "C:\Users\Documents"
                    Destination = "D:\Backup"
                    UseVSS = $true
                    ScanMode = "Smart"
                    ChunkMaxDepth = 3
                }
            }

            It "Should call Test-VssSupported for local paths" {
                Mock Test-VssSupported { $false }

                Start-ProfileReplication -Profile $script:localProfile -MaxConcurrentJobs 2

                Should -Invoke Test-VssSupported -Times 1 -ParameterFilter {
                    $Path -eq "C:\Users\Documents"
                }
            }

            It "Should NOT call Test-RemoteVssSupported for local paths" {
                Mock Test-VssSupported { $false }
                Mock Test-RemoteVssSupported { throw "Should not be called" }

                Start-ProfileReplication -Profile $script:localProfile -MaxConcurrentJobs 2

                Should -Not -Invoke Test-RemoteVssSupported
            }

            It "Should create local VSS snapshot when supported" {
                Mock Test-VssSupported { $true }
                Mock New-VssSnapshot {
                    New-OperationResult -Success $true -Data ([PSCustomObject]@{
                        ShadowId = "{local-test-id}"
                        ShadowPath = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1"
                        SourceVolume = "C:"
                    })
                }
                Mock Get-VssPath { "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Users\Documents" }

                Start-ProfileReplication -Profile $script:localProfile -MaxConcurrentJobs 2

                Should -Invoke New-VssSnapshot -Times 1
                $script:OrchestrationState.CurrentVssSnapshot | Should -Not -BeNullOrEmpty
            }
        }

        Context "OrchestrationState Properties" {
            It "Should have CurrentVssJunction property" {
                $script:OrchestrationState | Get-Member -Name CurrentVssJunction | Should -Not -BeNullOrEmpty
            }

            It "CurrentVssJunction should be null after Reset" {
                $script:OrchestrationState.CurrentVssJunction = [PSCustomObject]@{ Test = "value" }
                $script:OrchestrationState.Reset()
                $script:OrchestrationState.CurrentVssJunction | Should -BeNullOrEmpty
            }

            It "CurrentVssJunction should be null after ResetForNewProfile" {
                $script:OrchestrationState.CurrentVssJunction = [PSCustomObject]@{ Test = "value" }
                $script:OrchestrationState.ResetForNewProfile()
                $script:OrchestrationState.CurrentVssJunction | Should -BeNullOrEmpty
            }
        }
    }

    Describe "Remote VSS Cleanup in JobManagement" {
        BeforeEach {
            $script:OrchestrationState.Reset()
            Mock Write-RobocurseLog { }
            Mock Write-SiemEvent { }
        }

        Context "Complete-CurrentProfile Cleanup" {
            BeforeEach {
                # Set up state as if a profile with remote VSS is completing
                $script:OrchestrationState.CurrentProfile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "\\server\share"
                    Destination = "D:\Backup"
                }
                # ProfileStartTime must be a proper DateTime for the subtraction operation
                $script:OrchestrationState.ProfileStartTime = [datetime]::Now.AddMinutes(-5)
                # StartTime is also used when all profiles complete
                $script:OrchestrationState.StartTime = [datetime]::Now.AddMinutes(-10)
                # Set Profiles array to empty so no next profile is started
                $script:OrchestrationState.Profiles = @()
                $script:OrchestrationState.ProfileIndex = 0
                # Mock the profile completion callback
                $script:OnProfileComplete = $null
                # Mock Remove-ReplicationCheckpoint since it's called on completion
                Mock Remove-ReplicationCheckpoint { New-OperationResult -Success $true }
                # Mock Write-HealthCheckStatus since it's called on completion
                Mock Write-HealthCheckStatus { }
                Mock Remove-HealthCheckStatus { }
            }

            It "Should clean up remote junction before snapshot" {
                $script:OrchestrationState.CurrentVssJunction = [PSCustomObject]@{
                    JunctionLocalPath = "D:\SharedData\.robocurse-vss-12345"
                    ServerName = "fileserver"
                }
                $script:OrchestrationState.CurrentVssSnapshot = [PSCustomObject]@{
                    ShadowId = "{remote-snap-id}"
                    ServerName = "fileserver"
                    IsRemote = $true
                }

                Mock Remove-RemoteVssJunction { New-OperationResult -Success $true }
                Mock Remove-RemoteVssSnapshot { New-OperationResult -Success $true }

                Complete-CurrentProfile

                # Both should be called
                Should -Invoke Remove-RemoteVssJunction -Times 1
                Should -Invoke Remove-RemoteVssSnapshot -Times 1

                # State should be cleared
                $script:OrchestrationState.CurrentVssJunction | Should -BeNullOrEmpty
                $script:OrchestrationState.CurrentVssSnapshot | Should -BeNullOrEmpty
            }

            It "Should use Remove-VssSnapshot for local snapshots" {
                $script:OrchestrationState.CurrentVssSnapshot = [PSCustomObject]@{
                    ShadowId = "{local-snap-id}"
                    SourceVolume = "C:"
                    # IsRemote not set = local
                }

                Mock Remove-VssSnapshot { New-OperationResult -Success $true }
                Mock Remove-RemoteVssSnapshot { throw "Should not be called for local" }

                Complete-CurrentProfile

                Should -Invoke Remove-VssSnapshot -Times 1
                Should -Not -Invoke Remove-RemoteVssSnapshot
            }

            It "Should log SIEM event with isRemote flag" {
                $script:OrchestrationState.CurrentVssSnapshot = [PSCustomObject]@{
                    ShadowId = "{remote-snap-id}"
                    ServerName = "fileserver"
                    IsRemote = $true
                }

                Mock Remove-RemoteVssSnapshot { New-OperationResult -Success $true }

                Complete-CurrentProfile

                Should -Invoke Write-SiemEvent -ParameterFilter {
                    $EventType -eq 'VssSnapshotRemoved' -and $Data.isRemote -eq $true
                }
            }
        }
    }
}
