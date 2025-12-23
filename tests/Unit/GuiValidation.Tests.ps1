#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

InModuleScope 'Robocurse' {
    Describe "GUI Validation Tests" {

        BeforeAll {
            # Load WPF assemblies for dialog tests
            Add-Type -AssemblyName PresentationCore, PresentationFramework
        }

        BeforeEach {
            # Mock logging to prevent output in tests
            Mock Write-RobocurseLog { }
            Mock Write-GuiLog { }
            Mock Write-SiemEvent { }
            # Mock dialog to prevent UI popups in tests
            Mock Show-ValidationDialog { }
            Mock Show-AlertDialog { }
            # Mock VSS check - define in BeforeEach so it's always available
            Mock Test-VssSupported { return $false }
        }

        Context "Test-ProfileValidation" {
            It "Should pass when robocopy is available" {
                # Mock successful robocopy check
                Mock Test-RobocopyAvailable {
                    return [PSCustomObject]@{
                        Success = $true
                        Data = "C:\Windows\System32\robocopy.exe"
                        ErrorMessage = ""
                    }
                }

                # Mock other checks
                Mock Test-Path { return $false }
                Mock Test-VssSupported { return $false }
                Mock Get-DirectoryProfile { return $null }
                Mock Get-PSDrive { return $null }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                    UseVSS = $false
                }

                $results = Test-ProfileValidation -Profile $profile

                # Find the robocopy check result
                $robocopyCheck = $results | Where-Object { $_.CheckName -eq "Robocopy Available" }
                $robocopyCheck.Status | Should -Be "Pass"
                $robocopyCheck.Severity | Should -Be "Success"
            }

            It "Should fail when robocopy is not available" {
                # Mock failed robocopy check
                Mock Test-RobocopyAvailable {
                    return [PSCustomObject]@{
                        Success = $false
                        Data = $null
                        ErrorMessage = "robocopy.exe not found"
                    }
                }

                # Mock other checks
                Mock Test-Path { return $false }
                Mock Test-VssSupported { return $false }
                Mock Get-DirectoryProfile { return $null }
                Mock Get-PSDrive { return $null }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                    UseVSS = $false
                }

                $results = Test-ProfileValidation -Profile $profile

                # Find the robocopy check result
                $robocopyCheck = $results | Where-Object { $_.CheckName -eq "Robocopy Available" }
                $robocopyCheck.Status | Should -Be "Fail"
                $robocopyCheck.Severity | Should -Be "Error"
            }

            It "Should fail when source path does not exist" {
                # Mock robocopy available
                Mock Test-RobocopyAvailable {
                    return [PSCustomObject]@{
                        Success = $true
                        Data = "C:\Windows\System32\robocopy.exe"
                    }
                }

                # Mock source path not existing
                Mock Test-Path { param($Path, $PathType)
                    return $false
                }

                Mock Test-VssSupported { return $false }
                Mock Get-DirectoryProfile { return $null }
                Mock Get-PSDrive { return $null }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\NonExistent"
                    Destination = "D:\Dest"
                    UseVSS = $false
                }

                $results = Test-ProfileValidation -Profile $profile

                # Find the source path check result
                $sourceCheck = $results | Where-Object { $_.CheckName -eq "Source Path" }
                $sourceCheck.Status | Should -Be "Fail"
                $sourceCheck.Severity | Should -Be "Error"
                $sourceCheck.Message | Should -Match "does not exist"
            }

            It "Should warn when destination will be created" {
                # Mock robocopy available
                Mock Test-RobocopyAvailable {
                    return [PSCustomObject]@{
                        Success = $true
                        Data = "C:\Windows\System32\robocopy.exe"
                    }
                }

                # Mock source exists, destination doesn't, but parent does
                Mock Test-Path { param($Path, $PathType)
                    if ($Path -like "*\Source") { return $true }
                    if ($Path -like "*\Dest") { return $false }
                    if ($Path -like "D:\") { return $true }  # Parent exists
                    return $false
                }

                Mock Split-Path { param($Path, $Parent)
                    if ($Parent) { return "D:\" }
                    return $null
                }

                Mock Test-VssSupported { return $false }
                Mock Get-DirectoryProfile { return $null }
                Mock Get-PSDrive { return $null }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                    UseVSS = $false
                }

                $results = Test-ProfileValidation -Profile $profile

                # Find the destination path check result
                $destCheck = $results | Where-Object { $_.CheckName -eq "Destination Path" }
                $destCheck.Status | Should -Be "Warning"
                $destCheck.Severity | Should -Be "Warning"
                $destCheck.Message | Should -Match "will be created"
            }

            It "Should check VSS support when UseVSS is enabled" {
                # Mock robocopy available
                Mock Test-RobocopyAvailable {
                    return [PSCustomObject]@{
                        Success = $true
                        Data = "C:\Windows\System32\robocopy.exe"
                    }
                }

                # Mock paths exist
                Mock Test-Path { param($Path, $PathType)
                    return $true
                }

                # Mock VSS supported
                Mock Test-VssSupported { param($Path)
                    return $true
                }

                Mock Get-DirectoryProfile { return $null }
                Mock Get-PSDrive { return $null }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                    UseVSS = $true
                }

                $results = Test-ProfileValidation -Profile $profile

                # Find the VSS check result
                $vssCheck = $results | Where-Object { $_.CheckName -eq "VSS Support" }
                $vssCheck.Status | Should -Be "Pass"
                $vssCheck.Severity | Should -Be "Success"
                $vssCheck.Message | Should -Match "supported"
            }

            It "Should not check VSS support when UseVSS is disabled" {
                # Mock robocopy available
                Mock Test-RobocopyAvailable {
                    return [PSCustomObject]@{
                        Success = $true
                        Data = "C:\Windows\System32\robocopy.exe"
                    }
                }

                # Mock paths exist
                Mock Test-Path { param($Path, $PathType)
                    return $true
                }

                Mock Get-DirectoryProfile { return $null }
                Mock Get-PSDrive { return $null }
                Mock Test-VssSupported { return $false }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                    UseVSS = $false
                }

                $results = Test-ProfileValidation -Profile $profile

                # Find the VSS check result
                $vssCheck = $results | Where-Object { $_.CheckName -eq "VSS Support" }
                $vssCheck.Status | Should -Be "Info"
                $vssCheck.Severity | Should -Be "Info"
                $vssCheck.Message | Should -Match "not enabled"
            }

            It "Should profile source directory when accessible" {
                # Mock robocopy available
                Mock Test-RobocopyAvailable {
                    return [PSCustomObject]@{
                        Success = $true
                        Data = "C:\Windows\System32\robocopy.exe"
                    }
                }

                # Mock paths exist
                Mock Test-Path { param($Path, $PathType)
                    return $true
                }

                # Mock directory profile
                Mock Get-DirectoryProfile { param($Path)
                    return [PSCustomObject]@{
                        TotalSize = 10GB
                        FileCount = 1000
                    }
                }

                Mock Get-PSDrive { return $null }
                Mock Test-VssSupported { return $false }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                    UseVSS = $false
                }

                $results = Test-ProfileValidation -Profile $profile

                # Find the source profile check result
                $profileCheck = $results | Where-Object { $_.CheckName -eq "Source Profile" }
                $profileCheck.Status | Should -Be "Pass"
                $profileCheck.Severity | Should -Be "Success"
                $profileCheck.Message | Should -Match "10 GB"
                $profileCheck.Message | Should -Match "1000 files"
            }

            It "Should handle empty source path" {
                Mock Test-RobocopyAvailable {
                    return [PSCustomObject]@{
                        Success = $true
                        Data = "C:\Windows\System32\robocopy.exe"
                    }
                }

                Mock Test-Path { return $false }
                Mock Get-PSDrive { return $null }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = ""
                    Destination = "D:\Dest"
                    UseVSS = $false
                }

                $results = Test-ProfileValidation -Profile $profile

                # Find the source path check result
                $sourceCheck = $results | Where-Object { $_.CheckName -eq "Source Path" }
                $sourceCheck.Status | Should -Be "Fail"
                $sourceCheck.Severity | Should -Be "Error"
                $sourceCheck.Message | Should -Match "empty"
            }

            It "Should handle empty destination path" {
                Mock Test-RobocopyAvailable {
                    return [PSCustomObject]@{
                        Success = $true
                        Data = "C:\Windows\System32\robocopy.exe"
                    }
                }

                Mock Test-Path { return $true }
                Mock Get-DirectoryProfile { return $null }
                Mock Get-PSDrive { return $null }
                Mock Test-VssSupported { return $false }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = ""
                    UseVSS = $false
                }

                $results = Test-ProfileValidation -Profile $profile

                # Find the destination path check result
                $destCheck = $results | Where-Object { $_.CheckName -eq "Destination Path" }
                $destCheck.Status | Should -Be "Fail"
                $destCheck.Severity | Should -Be "Error"
                $destCheck.Message | Should -Match "empty"
            }

            It "Should return all validation checks" {
                Mock Test-RobocopyAvailable {
                    return [PSCustomObject]@{
                        Success = $true
                        Data = "C:\Windows\System32\robocopy.exe"
                    }
                }

                Mock Test-Path { return $true }
                Mock Get-DirectoryProfile {
                    return [PSCustomObject]@{
                        TotalSize = 1GB
                        FileCount = 100
                    }
                }
                Mock Get-PSDrive {
                    return [PSCustomObject]@{
                        Free = 100GB
                        Root = "D:\"
                    }
                }
                Mock Test-VssSupported { return $false }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                    UseVSS = $false
                }

                $results = Test-ProfileValidation -Profile $profile

                # Should have all expected checks
                $results | Should -Not -BeNullOrEmpty
                $checkNames = $results | ForEach-Object { $_.CheckName }
                $checkNames | Should -Contain "Robocopy Available"
                $checkNames | Should -Contain "Source Path"
                $checkNames | Should -Contain "Destination Path"
                $checkNames | Should -Contain "Destination Disk Space"
                $checkNames | Should -Contain "VSS Support"
                $checkNames | Should -Contain "Source Profile"
            }
        }

        Context "Show-ValidationDialog" {
            It "Should not throw when called with valid profile" {
                # Mock Get-XamlResource to prevent actual dialog loading
                Mock Get-XamlResource { throw "Mock prevents dialog" }

                # Mock logging
                Mock Write-GuiLog { }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                    UseVSS = $false
                }

                # Should not throw even if dialog loading fails
                { Show-ValidationDialog -Profile $profile } | Should -Not -Throw
            }

            It "Should not throw when provided with precomputed results" {
                # Mock Get-XamlResource to prevent actual dialog loading
                Mock Get-XamlResource { throw "Mock prevents dialog" }

                # Mock logging
                Mock Write-GuiLog { }

                $profile = [PSCustomObject]@{
                    Name = "TestProfile"
                    Source = "C:\Source"
                    Destination = "D:\Dest"
                    UseVSS = $false
                }

                $precomputedResults = @(
                    [PSCustomObject]@{
                        CheckName = "Precomputed Check"
                        Status = "Pass"
                        Message = "Precomputed message"
                        Severity = "Success"
                    }
                )

                # Should not throw
                { Show-ValidationDialog -Profile $profile -Results $precomputedResults } | Should -Not -Throw
            }
        }
    }
}
