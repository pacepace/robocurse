Describe "Directory Profiling" {
    BeforeAll {
        . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
    }

    Context "ConvertFrom-RobocopyListOutput" {
        It "Should extract file sizes correctly" {
            $output = @(
                "          1000    test\file1.txt",
                "          2000    test\file2.txt",
                "             0    test\subdir\"
            )

            $result = ConvertFrom-RobocopyListOutput -Output $output

            $result.TotalSize | Should -Be 3000
            $result.FileCount | Should -Be 2
        }

        It "Should not count directories as files" {
            $output = @(
                "          1000    test\file.txt",
                "             0    test\dir1\",
                "             0    test\dir2\"
            )

            $result = ConvertFrom-RobocopyListOutput -Output $output

            $result.FileCount | Should -Be 1
            $result.DirCount | Should -Be 2
        }

        It "Should handle empty output" {
            $output = @()

            $result = ConvertFrom-RobocopyListOutput -Output $output

            $result.TotalSize | Should -Be 0
            $result.FileCount | Should -Be 0
        }

        It "Should handle large file sizes" {
            $output = @(
                "   10737418240    test\largefile.iso"  # 10 GB
            )

            $result = ConvertFrom-RobocopyListOutput -Output $output

            $result.TotalSize | Should -Be 10737418240
        }

        It "Should skip non-matching lines" {
            $output = @(
                "Some header text",
                "          1000    test\file.txt",
                "More text that doesn't match",
                "          2000    test\file2.txt"
            )

            $result = ConvertFrom-RobocopyListOutput -Output $output

            $result.TotalSize | Should -Be 3000
            $result.FileCount | Should -Be 2
        }

        It "Should handle whitespace in paths" {
            $output = @(
                "          1000    test\file with spaces.txt"
            )

            $result = ConvertFrom-RobocopyListOutput -Output $output

            $result.FileCount | Should -Be 1
            $result.Files[0].Path | Should -Be "test\file with spaces.txt"
        }
    }

    Context "Get-DirectoryProfile" {
        BeforeEach {
            # Clear cache
            $script:ProfileCache = [System.Collections.Concurrent.ConcurrentDictionary[string, PSCustomObject]]::new()
        }

        It "Should call robocopy and parse output" {
            Mock Invoke-RobocopyList {
                return @(
                    "          1000    file1.txt",
                    "          2000    file2.txt"
                )
            }

            $result = Get-DirectoryProfile -Path "C:\Test" -UseCache $false

            $result.TotalSize | Should -Be 3000
            $result.FileCount | Should -Be 2
            Should -Invoke Invoke-RobocopyList -Times 1
        }

        It "Should use cache when available" {
            Mock Invoke-RobocopyList { return @() }

            # First call - populates cache
            $result1 = Get-DirectoryProfile -Path "C:\Test" -UseCache $true
            # Second call - should use cache
            $result2 = Get-DirectoryProfile -Path "C:\Test" -UseCache $true

            Should -Invoke Invoke-RobocopyList -Times 1  # Only called once
        }

        It "Should skip cache when disabled" {
            Mock Invoke-RobocopyList { return @("          1000    file.txt") }

            Get-DirectoryProfile -Path "C:\Test" -UseCache $false
            Get-DirectoryProfile -Path "C:\Test" -UseCache $false

            Should -Invoke Invoke-RobocopyList -Times 2  # Called twice
        }

        It "Should calculate average file size correctly" {
            Mock Invoke-RobocopyList {
                return @(
                    "          1000    file1.txt",
                    "          2000    file2.txt",
                    "          3000    file3.txt"
                )
            }

            $result = Get-DirectoryProfile -Path "C:\Test" -UseCache $false

            $result.AvgFileSize | Should -Be 2000
        }

        It "Should handle division by zero for empty directories" {
            Mock Invoke-RobocopyList { return @() }

            $result = Get-DirectoryProfile -Path "C:\Test" -UseCache $false

            $result.AvgFileSize | Should -Be 0
            $result.TotalSize | Should -Be 0
            $result.FileCount | Should -Be 0
        }

        It "Should normalize paths for cache" {
            Mock Invoke-RobocopyList { return @("          1000    file.txt") }

            # Call with trailing slash
            $result1 = Get-DirectoryProfile -Path "C:\Test\" -UseCache $true
            # Call without trailing slash - should use same cache
            $result2 = Get-DirectoryProfile -Path "C:\Test" -UseCache $true

            Should -Invoke Invoke-RobocopyList -Times 1  # Only called once
        }
    }

    Context "Cache Functions" {
        BeforeEach {
            # Clear cache
            $script:ProfileCache = [System.Collections.Concurrent.ConcurrentDictionary[string, PSCustomObject]]::new()
        }

        It "Should store and retrieve cached profiles" {
            $profile = [PSCustomObject]@{
                Path = "C:\Test"
                TotalSize = 1000
                FileCount = 1
                DirCount = 0
                AvgFileSize = 1000
                LastScanned = Get-Date
            }

            Set-CachedProfile -Profile $profile
            $cached = Get-CachedProfile -Path "C:\Test" -MaxAgeHours 24

            $cached | Should -Not -BeNullOrEmpty
            $cached.TotalSize | Should -Be 1000
        }

        It "Should return null for non-existent cache" {
            $cached = Get-CachedProfile -Path "C:\NonExistent" -MaxAgeHours 24

            $cached | Should -BeNullOrEmpty
        }

        It "Should invalidate expired cache" {
            $profile = [PSCustomObject]@{
                Path = "C:\Test"
                TotalSize = 1000
                FileCount = 1
                DirCount = 0
                AvgFileSize = 1000
                LastScanned = (Get-Date).AddHours(-25)  # 25 hours ago
            }

            Set-CachedProfile -Profile $profile
            $cached = Get-CachedProfile -Path "C:\Test" -MaxAgeHours 24

            $cached | Should -BeNullOrEmpty
        }

        It "Clear-ProfileCache should remove all entries" {
            # Add some entries
            $profile1 = [PSCustomObject]@{
                Path = "C:\Test1"
                TotalSize = 1000
                FileCount = 1
                DirCount = 0
                AvgFileSize = 1000
                LastScanned = Get-Date
            }
            $profile2 = [PSCustomObject]@{
                Path = "C:\Test2"
                TotalSize = 2000
                FileCount = 2
                DirCount = 0
                AvgFileSize = 1000
                LastScanned = Get-Date
            }
            Set-CachedProfile -Profile $profile1
            Set-CachedProfile -Profile $profile2

            # Verify entries exist
            $script:ProfileCache.Count | Should -Be 2

            # Clear the cache
            Clear-ProfileCache

            # Verify cache is empty
            $script:ProfileCache.Count | Should -Be 0
        }

        It "Clear-ProfileCache should not throw on empty cache" {
            # Ensure cache is empty
            $script:ProfileCache.Clear()

            { Clear-ProfileCache } | Should -Not -Throw
        }

        It "Clear-ProfileCache should have correct function signature" {
            $cmd = Get-Command Clear-ProfileCache
            $cmd | Should -Not -BeNullOrEmpty
        }
    }

    Context "Get-DirectoryChildren" {
        It "Should return child directories" {
            $testDir = New-Item -Path (Join-Path $TestDrive "Parent") -ItemType Directory
            $child1 = New-Item -Path (Join-Path $testDir "Child1") -ItemType Directory
            $child2 = New-Item -Path (Join-Path $testDir "Child2") -ItemType Directory
            New-Item -Path (Join-Path $testDir "file.txt") -ItemType File

            $result = Get-DirectoryChildren -Path $testDir.FullName

            $result.Count | Should -Be 2
            $result | Should -Contain $child1.FullName
            $result | Should -Contain $child2.FullName
        }
    }
}
