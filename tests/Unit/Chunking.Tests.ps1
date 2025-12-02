#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

InModuleScope 'Robocurse' {
    Describe "Recursive Chunking" {
        Context "Get-DirectoryChunks Validation" {
            It "Should throw when Path is null or empty" {
                {
                    Get-DirectoryChunks -Path "" -DestinationRoot "D:\Backup"
                } | Should -Throw
            }

            It "Should throw when Path does not exist" {
                {
                    Get-DirectoryChunks -Path "C:\NonExistent\Path\12345" -DestinationRoot "D:\Backup"
                } | Should -Throw "*does not exist*"
            }

            It "Should throw when DestinationRoot is empty" {
                $testDir = New-Item -ItemType Directory -Path "$TestDrive/testdir" -Force
                {
                    Get-DirectoryChunks -Path $testDir.FullName -DestinationRoot ""
                } | Should -Throw
            }

            It "Should throw when MaxSizeBytes is out of range (too low)" {
                $testDir = New-Item -ItemType Directory -Path "$TestDrive/testdir2" -Force
                {
                    Get-DirectoryChunks -Path $testDir.FullName -DestinationRoot "D:\Backup" -MaxSizeBytes 0
                } | Should -Throw
            }

            It "Should throw when MaxFiles is out of range (too low)" {
                $testDir = New-Item -ItemType Directory -Path "$TestDrive/testdir3" -Force
                {
                    Get-DirectoryChunks -Path $testDir.FullName -DestinationRoot "D:\Backup" -MaxFiles 0
                } | Should -Throw
            }

            It "Should throw when MaxDepth is out of range (too low)" {
                $testDir = New-Item -ItemType Directory -Path "$TestDrive/testdir4" -Force
                {
                    Get-DirectoryChunks -Path $testDir.FullName -DestinationRoot "D:\Backup" -MaxDepth -1
                } | Should -Throw
            }

            It "Should throw when MaxSizeBytes is less than or equal to MinSizeBytes" {
                $testDir = New-Item -ItemType Directory -Path "$TestDrive/testdir5" -Force
                {
                    Get-DirectoryChunks -Path $testDir.FullName -DestinationRoot "D:\Backup" `
                        -MaxSizeBytes 100MB -MinSizeBytes 200MB
                } | Should -Throw "*MaxSizeBytes*greater than*MinSizeBytes*"
            }

            It "Should throw when MaxSizeBytes equals MinSizeBytes" {
                $testDir = New-Item -ItemType Directory -Path "$TestDrive/testdir6" -Force
                {
                    Get-DirectoryChunks -Path $testDir.FullName -DestinationRoot "D:\Backup" `
                        -MaxSizeBytes 100MB -MinSizeBytes 100MB
                } | Should -Throw "*MaxSizeBytes*greater than*MinSizeBytes*"
            }

            It "Should accept valid chunk size constraints" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    [PSCustomObject]@{
                        Path = $Path
                        TotalSize = 50MB
                        FileCount = 100
                        DirCount = 0
                        AvgFileSize = 500KB
                        LastScanned = Get-Date
                    }
                }

                # MaxSizeBytes > MinSizeBytes should work
                $chunks = Get-DirectoryChunks -Path "C:\Test" -DestinationRoot "D:\Backup" `
                    -MaxSizeBytes 1GB -MinSizeBytes 100MB

                $chunks | Should -Not -BeNullOrEmpty
            }
        }

        Context "Get-DirectoryChunks - Simple Cases" {
            It "Should return single chunk for small directory" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    [PSCustomObject]@{
                        Path = $Path
                        TotalSize = 1GB
                        FileCount = 1000
                        DirCount = 0
                        AvgFileSize = 1MB
                        LastScanned = Get-Date
                    }
                }
                Mock Get-DirectoryChildren { @() }

                $chunks = Get-DirectoryChunks -Path "C:\Small" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB

                $chunks.Count | Should -Be 1
                $chunks[0].SourcePath | Should -Be "C:\Small"
                $chunks[0].DestinationPath | Should -Be "D:\Backup"
                $chunks[0].EstimatedSize | Should -Be 1GB
                $chunks[0].EstimatedFiles | Should -Be 1000
            }

            It "Should split large directory into child chunks" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    param($Path)
                    if ($Path -eq "C:\Large") {
                        [PSCustomObject]@{
                            Path = $Path
                            TotalSize = 50GB
                            FileCount = 100000
                            DirCount = 2
                            AvgFileSize = 500KB
                            LastScanned = Get-Date
                        }
                    }
                    else {
                        [PSCustomObject]@{
                            Path = $Path
                            TotalSize = 5GB
                            FileCount = 10000
                            DirCount = 0
                            AvgFileSize = 500KB
                            LastScanned = Get-Date
                        }
                    }
                }
                Mock Get-DirectoryChildren {
                    param($Path)
                    if ($Path -eq "C:\Large") {
                        @("C:\Large\Child1", "C:\Large\Child2")
                    }
                    else { @() }
                }
                Mock Get-FilesAtLevel { @() }

                $chunks = Get-DirectoryChunks -Path "C:\Large" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB

                $chunks.Count | Should -Be 2
                $chunks[0].SourcePath | Should -BeLike "*Child*"
                $chunks[1].SourcePath | Should -BeLike "*Child*"
            }

            It "Should handle directory with no subdirectories but large size" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    [PSCustomObject]@{
                        Path = $Path
                        TotalSize = 100GB
                        FileCount = 500000
                        DirCount = 0
                        AvgFileSize = 200KB
                        LastScanned = Get-Date
                    }
                }
                Mock Get-DirectoryChildren { @() }

                $chunks = Get-DirectoryChunks -Path "C:\NoSubdirs" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB

                $chunks.Count | Should -Be 1
                $chunks[0].SourcePath | Should -Be "C:\NoSubdirs"
            }
        }

        Context "Get-DirectoryChunks - Depth Limiting" {
            It "Should stop at max depth even if directory is large" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    [PSCustomObject]@{
                        Path = $Path
                        TotalSize = 100GB
                        FileCount = 500000
                        DirCount = 1
                        AvgFileSize = 200KB
                        LastScanned = Get-Date
                    }
                }
                Mock Get-DirectoryChildren {
                    param($Path)
                    @("$Path\Child")
                }
                Mock Get-FilesAtLevel { @() }

                $chunks = Get-DirectoryChunks -Path "C:\Deep" -DestinationRoot "D:\Backup" -MaxDepth 2 -MaxSizeBytes 10GB

                $chunks.Count | Should -BeGreaterThan 0
                $chunks.Count | Should -BeLessOrEqual 10
            }

            It "Should accept large directory at max depth" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    [PSCustomObject]@{
                        Path = $Path
                        TotalSize = 100GB
                        FileCount = 500000
                        DirCount = 0
                        AvgFileSize = 200KB
                        LastScanned = Get-Date
                    }
                }
                Mock Get-DirectoryChildren { @() }

                $chunks = Get-DirectoryChunks -Path "C:\AtDepth" -DestinationRoot "D:\Backup" -MaxDepth 0 -MaxSizeBytes 10GB

                $chunks.Count | Should -Be 1
                $chunks[0].SourcePath | Should -Be "C:\AtDepth"
            }
        }

        Context "Get-DirectoryChunks - Files at Level" {
            It "Should create files-only chunk for intermediate directories" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    param($Path)
                    if ($Path -eq "C:\Mixed") {
                        [PSCustomObject]@{
                            Path = $Path
                            TotalSize = 20GB
                            FileCount = 50000
                            DirCount = 1
                            AvgFileSize = 400KB
                            LastScanned = Get-Date
                        }
                    }
                    else {
                        [PSCustomObject]@{
                            Path = $Path
                            TotalSize = 5GB
                            FileCount = 10000
                            DirCount = 0
                            AvgFileSize = 500KB
                            LastScanned = Get-Date
                        }
                    }
                }
                Mock Get-DirectoryChildren {
                    param($Path)
                    if ($Path -eq "C:\Mixed") { @("C:\Mixed\SubDir") } else { @() }
                }
                Mock Get-FilesAtLevel {
                    param($Path)
                    if ($Path -eq "C:\Mixed") {
                        @([PSCustomObject]@{ Name = "file.txt"; Length = 1000; FullName = "C:\Mixed\file.txt" })
                    }
                    else { @() }
                }

                $chunks = Get-DirectoryChunks -Path "C:\Mixed" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB

                $filesOnlyChunk = $chunks | Where-Object { $_.IsFilesOnly -eq $true }
                $filesOnlyChunk | Should -Not -BeNullOrEmpty
                $filesOnlyChunk.RobocopyArgs | Should -Contain "/LEV:1"
                $filesOnlyChunk.SourcePath | Should -Be "C:\Mixed"
            }

            It "Should not create files-only chunk when no files at level" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    param($Path)
                    if ($Path -eq "C:\OnlySubdirs") {
                        [PSCustomObject]@{
                            Path = $Path
                            TotalSize = 20GB
                            FileCount = 50000
                            DirCount = 2
                            AvgFileSize = 400KB
                            LastScanned = Get-Date
                        }
                    }
                    else {
                        [PSCustomObject]@{
                            Path = $Path
                            TotalSize = 5GB
                            FileCount = 10000
                            DirCount = 0
                            AvgFileSize = 500KB
                            LastScanned = Get-Date
                        }
                    }
                }
                Mock Get-DirectoryChildren {
                    param($Path)
                    if ($Path -eq "C:\OnlySubdirs") { @("C:\OnlySubdirs\Sub1", "C:\OnlySubdirs\Sub2") } else { @() }
                }
                Mock Get-FilesAtLevel { @() }

                $chunks = Get-DirectoryChunks -Path "C:\OnlySubdirs" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB

                $filesOnlyChunks = $chunks | Where-Object { $_.IsFilesOnly -eq $true }
                $filesOnlyChunks.Count | Should -Be 0
            }
        }

        Context "Get-NormalizedPath" {
            It "Should preserve case (callers should use case-insensitive comparison)" {
                $result = Get-NormalizedPath -Path "\\SERVER\Share$"
                $result | Should -Be "\\SERVER\Share$"
            }

            It "Should remove trailing backslashes" {
                $result = Get-NormalizedPath -Path "\\server\share\"
                $result | Should -Be "\\server\share"
            }

            It "Should convert forward slashes to backslashes" {
                $result = Get-NormalizedPath -Path "\\server/share/folder"
                $result | Should -Be "\\server\share\folder"
            }

            It "Should handle multiple trailing slashes" {
                $result = Get-NormalizedPath -Path "C:\Data\\\\"
                $result | Should -Be "C:\Data"
            }

            It "Should handle mixed slashes while preserving case" {
                $result = Get-NormalizedPath -Path "\\SERVER/Share$\Folder/"
                $result | Should -Be "\\SERVER\Share$\Folder"
            }

            It "Should allow case-insensitive comparison with Equals" {
                $path1 = Get-NormalizedPath -Path "C:\Data\Folder"
                $path2 = Get-NormalizedPath -Path "C:\DATA\FOLDER"
                $path1.Equals($path2, [StringComparison]::OrdinalIgnoreCase) | Should -Be $true
            }
        }

        Context "Convert-ToDestinationPath" {
            It "Should correctly map UNC to local path" {
                $result = Convert-ToDestinationPath `
                    -SourcePath "\\server\users$\john\docs" `
                    -SourceRoot "\\server\users$" `
                    -DestRoot "D:\Backup"

                $result | Should -Be "D:\Backup\john\docs"
            }

            It "Should handle trailing slashes" {
                $result = Convert-ToDestinationPath `
                    -SourcePath "\\server\share\folder\" `
                    -SourceRoot "\\server\share\" `
                    -DestRoot "E:\Dest\"

                $result | Should -Match "E:\\Dest\\folder"
            }

            It "Should handle when source equals source root" {
                $result = Convert-ToDestinationPath `
                    -SourcePath "C:\Source" `
                    -SourceRoot "C:\Source" `
                    -DestRoot "D:\Dest"

                $result | Should -Be "D:\Dest"
            }

            It "Should handle nested paths correctly" {
                $result = Convert-ToDestinationPath `
                    -SourcePath "\\server\users$\john\docs\work\project1" `
                    -SourceRoot "\\server\users$" `
                    -DestRoot "D:\Backup"

                $result | Should -Be "D:\Backup\john\docs\work\project1"
            }

            It "Should handle local paths" {
                $result = Convert-ToDestinationPath `
                    -SourcePath "C:\Data\Projects\MyProject" `
                    -SourceRoot "C:\Data" `
                    -DestRoot "E:\Backup"

                $result | Should -Be "E:\Backup\Projects\MyProject"
            }

            It "Should handle case mismatch in UNC paths" {
                $result = Convert-ToDestinationPath `
                    -SourcePath "\\SERVER\Share$\Data\Files" `
                    -SourceRoot "\\server\share$" `
                    -DestRoot "D:\Backup"

                $result | Should -Be "D:\Backup\Data\Files"
            }

            It "Should handle mixed case with admin shares" {
                $result = Convert-ToDestinationPath `
                    -SourcePath "\\FILESERVER01\Users$\JohnDoe" `
                    -SourceRoot "\\fileserver01\users$" `
                    -DestRoot "E:\Replicas"

                $result | Should -Be "E:\Replicas\JohnDoe"
            }

            It "Should handle forward slashes in source path" {
                $result = Convert-ToDestinationPath `
                    -SourcePath "\\server/share/folder/subfolder" `
                    -SourceRoot "\\server\share" `
                    -DestRoot "D:\Backup"

                $result | Should -Match "D:\\Backup.*folder.*subfolder"
            }
        }

        Context "New-Chunk" {
            It "Should create chunk with correct properties" {
                $profile = [PSCustomObject]@{
                    TotalSize = 5GB
                    FileCount = 10000
                    DirCount = 5
                    AvgFileSize = 500KB
                    LastScanned = Get-Date
                }

                $chunk = New-Chunk -SourcePath "C:\Test" -DestinationPath "D:\Test" -Profile $profile

                $chunk.SourcePath | Should -Be "C:\Test"
                $chunk.DestinationPath | Should -Be "D:\Test"
                $chunk.EstimatedSize | Should -Be 5GB
                $chunk.EstimatedFiles | Should -Be 10000
                $chunk.IsFilesOnly | Should -Be $false
                $chunk.Status | Should -Be "Pending"
                $chunk.ChunkId | Should -BeGreaterThan 0
            }

            It "Should increment chunk ID for each chunk" {
                $profile = [PSCustomObject]@{
                    TotalSize = 1GB
                    FileCount = 1000
                    DirCount = 0
                    AvgFileSize = 1MB
                    LastScanned = Get-Date
                }

                $chunk1 = New-Chunk -SourcePath "C:\Test1" -DestinationPath "D:\Test1" -Profile $profile
                $chunk2 = New-Chunk -SourcePath "C:\Test2" -DestinationPath "D:\Test2" -Profile $profile

                $chunk2.ChunkId | Should -Be ($chunk1.ChunkId + 1)
            }
        }

        Context "New-FilesOnlyChunk" {
            It "Should set IsFilesOnly flag" {
                Mock Get-FilesAtLevel {
                    @([PSCustomObject]@{ Name = "file.txt"; Length = 1000; FullName = "C:\Test\file.txt" })
                }

                $chunk = New-FilesOnlyChunk -SourcePath "C:\Test" -DestinationPath "D:\Test"

                $chunk.IsFilesOnly | Should -Be $true
            }

            It "Should include /LEV:1 in robocopy args" {
                Mock Get-FilesAtLevel {
                    @([PSCustomObject]@{ Name = "file.txt"; Length = 1000; FullName = "C:\Test\file.txt" })
                }

                $chunk = New-FilesOnlyChunk -SourcePath "C:\Test" -DestinationPath "D:\Test"

                $chunk.RobocopyArgs | Should -Contain "/LEV:1"
            }

            It "Should calculate size from files at level" {
                Mock Get-FilesAtLevel {
                    @(
                        [PSCustomObject]@{ Name = "file1.txt"; Length = 1000; FullName = "C:\Test\file1.txt" }
                        [PSCustomObject]@{ Name = "file2.txt"; Length = 2000; FullName = "C:\Test\file2.txt" }
                    )
                }

                $chunk = New-FilesOnlyChunk -SourcePath "C:\Test" -DestinationPath "D:\Test"

                $chunk.EstimatedSize | Should -Be 3000
                $chunk.EstimatedFiles | Should -Be 2
            }

            It "Should handle empty directory" {
                Mock Get-FilesAtLevel { @() }

                $chunk = New-FilesOnlyChunk -SourcePath "C:\Test" -DestinationPath "D:\Test"

                $chunk.EstimatedSize | Should -Be 0
                $chunk.EstimatedFiles | Should -Be 0
                $chunk.IsFilesOnly | Should -Be $true
            }
        }

        Context "Get-FilesAtLevel" {
            BeforeEach {
                $tempPath = [System.IO.Path]::GetTempPath()
                $script:FilesAtLevelTestDir = Join-Path $tempPath "RobocurseTests_FilesAtLevel_$(Get-Random)"
                New-Item -ItemType Directory -Path $script:FilesAtLevelTestDir -Force | Out-Null
            }

            AfterEach {
                if ($null -ne $script:FilesAtLevelTestDir -and (Test-Path $script:FilesAtLevelTestDir)) {
                    Remove-Item -Path $script:FilesAtLevelTestDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            It "Should return only files, not subdirectories" {
                "test" | Out-File (Join-Path $script:FilesAtLevelTestDir "file1.txt")
                "test" | Out-File (Join-Path $script:FilesAtLevelTestDir "file2.txt")
                New-Item -ItemType Directory -Path (Join-Path $script:FilesAtLevelTestDir "SubDir") -Force | Out-Null

                $files = Get-FilesAtLevel -Path $script:FilesAtLevelTestDir

                $files.Count | Should -Be 2
                $files[0] | Should -BeOfType [System.IO.FileInfo]
            }

            It "Should return empty array when no files" {
                New-Item -ItemType Directory -Path (Join-Path $script:FilesAtLevelTestDir "SubDir") -Force | Out-Null

                $files = Get-FilesAtLevel -Path $script:FilesAtLevelTestDir

                $files.Count | Should -Be 0
            }

            It "Should not recurse into subdirectories" {
                $subdir = Join-Path $script:FilesAtLevelTestDir "SubDir"
                New-Item -ItemType Directory -Path $subdir -Force | Out-Null
                "test" | Out-File (Join-Path $subdir "file_in_subdir.txt")
                "test" | Out-File (Join-Path $script:FilesAtLevelTestDir "file_at_level.txt")

                $files = Get-FilesAtLevel -Path $script:FilesAtLevelTestDir

                $files.Count | Should -Be 1
                $files[0].Name | Should -Be "file_at_level.txt"
            }
        }

        Context "New-FlatChunks" {
            It "Should create chunks without recursing into subdirectories" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    param($Path)
                    [PSCustomObject]@{
                        Path = $Path
                        TotalSize = 100GB
                        FileCount = 200000
                        DirCount = 0
                        AvgFileSize = 500KB
                        LastScanned = Get-Date
                    }
                }
                Mock Get-DirectoryChildren { @() }

                $chunks = New-FlatChunks -Path "C:\TestFlat" -DestinationRoot "D:\Backup" -MaxChunkSizeBytes 10GB

                $chunks.Count | Should -Be 1
                $chunks[0].SourcePath | Should -Be "C:\TestFlat"
                $chunks[0].DestinationPath | Should -Be "D:\Backup"
            }

            It "Should use provided MaxChunkSizeBytes parameter" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    [PSCustomObject]@{
                        Path = $Path
                        TotalSize = 5GB
                        FileCount = 10000
                        DirCount = 0
                        AvgFileSize = 500KB
                        LastScanned = Get-Date
                    }
                }
                Mock Get-DirectoryChildren { @() }

                $chunks = New-FlatChunks -Path "C:\Test" -DestinationRoot "D:\Backup" -MaxChunkSizeBytes 20GB

                $chunks.Count | Should -Be 1
                $chunks[0].EstimatedSize | Should -Be 5GB
            }

            It "Should use provided MaxFiles parameter" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    [PSCustomObject]@{
                        Path = $Path
                        TotalSize = 1GB
                        FileCount = 5000
                        DirCount = 0
                        AvgFileSize = 200KB
                        LastScanned = Get-Date
                    }
                }
                Mock Get-DirectoryChildren { @() }

                $chunks = New-FlatChunks -Path "C:\Test" -DestinationRoot "D:\Backup" -MaxFiles 10000

                $chunks.Count | Should -Be 1
            }
        }

        Context "New-SmartChunks" {
            It "Should create chunks recursively" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    param($Path)
                    if ($Path -eq "C:\TestSmart") {
                        [PSCustomObject]@{
                            Path = $Path
                            TotalSize = 50GB
                            FileCount = 100000
                            DirCount = 2
                            AvgFileSize = 500KB
                            LastScanned = Get-Date
                        }
                    }
                    else {
                        [PSCustomObject]@{
                            Path = $Path
                            TotalSize = 5GB
                            FileCount = 10000
                            DirCount = 0
                            AvgFileSize = 500KB
                            LastScanned = Get-Date
                        }
                    }
                }
                Mock Get-DirectoryChildren {
                    param($Path)
                    if ($Path -eq "C:\TestSmart") {
                        @("C:\TestSmart\Child1", "C:\TestSmart\Child2")
                    }
                    else { @() }
                }
                Mock Get-FilesAtLevel { @() }

                $chunks = New-SmartChunks -Path "C:\TestSmart" -DestinationRoot "D:\Backup" -MaxChunkSizeBytes 10GB

                $chunks.Count | Should -Be 2
                $chunks[0].SourcePath | Should -BeLike "*Child*"
                $chunks[1].SourcePath | Should -BeLike "*Child*"
            }

            It "Should respect MaxDepth parameter" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    [PSCustomObject]@{
                        Path = $Path
                        TotalSize = 100GB
                        FileCount = 500000
                        DirCount = 1
                        AvgFileSize = 200KB
                        LastScanned = Get-Date
                    }
                }
                Mock Get-DirectoryChildren {
                    param($Path)
                    @("$Path\Child")
                }
                Mock Get-FilesAtLevel { @() }

                $chunks = New-SmartChunks -Path "C:\Deep" -DestinationRoot "D:\Backup" -MaxDepth 0 -MaxChunkSizeBytes 10GB

                $chunks.Count | Should -Be 1
                $chunks[0].SourcePath | Should -Be "C:\Deep"
            }

            It "Should use provided MaxChunkSizeBytes parameter" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    [PSCustomObject]@{
                        Path = $Path
                        TotalSize = 15GB
                        FileCount = 30000
                        DirCount = 0
                        AvgFileSize = 500KB
                        LastScanned = Get-Date
                    }
                }
                Mock Get-DirectoryChildren { @() }

                $chunks = New-SmartChunks -Path "C:\Test" -DestinationRoot "D:\Backup" -MaxChunkSizeBytes 20GB

                $chunks.Count | Should -Be 1
                $chunks[0].EstimatedSize | Should -Be 15GB
            }

            It "Should use default parameters when not specified" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    [PSCustomObject]@{
                        Path = $Path
                        TotalSize = 5GB
                        FileCount = 10000
                        DirCount = 0
                        AvgFileSize = 500KB
                        LastScanned = Get-Date
                    }
                }
                Mock Get-DirectoryChildren { @() }

                $chunks = New-SmartChunks -Path "C:\Test" -DestinationRoot "D:\Backup"

                $chunks.Count | Should -Be 1
                $chunks[0].SourcePath | Should -Be "C:\Test"
                $chunks[0].DestinationPath | Should -Be "D:\Backup"
            }
        }

        Context "Integration - Complex Directory Structure" {
            It "Should handle complex multi-level structure" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    param($Path)
                    switch -Wildcard ($Path) {
                        "*Root" {
                            [PSCustomObject]@{
                                Path = $Path
                                TotalSize = 100GB
                                FileCount = 200000
                                DirCount = 3
                                AvgFileSize = 500KB
                                LastScanned = Get-Date
                            }
                        }
                        "*Level1_*" {
                            [PSCustomObject]@{
                                Path = $Path
                                TotalSize = 8GB
                                FileCount = 10000
                                DirCount = 0
                                AvgFileSize = 800KB
                                LastScanned = Get-Date
                            }
                        }
                        default {
                            [PSCustomObject]@{
                                Path = $Path
                                TotalSize = 1GB
                                FileCount = 1000
                                DirCount = 0
                                AvgFileSize = 1MB
                                LastScanned = Get-Date
                            }
                        }
                    }
                }
                Mock Get-DirectoryChildren {
                    param($Path)
                    if ($Path -match "Root$") {
                        @("C:\Root\Level1_A", "C:\Root\Level1_B", "C:\Root\Level1_C")
                    }
                    else { @() }
                }
                Mock Get-FilesAtLevel {
                    param($Path)
                    if ($Path -match "Root$") {
                        @([PSCustomObject]@{ Name = "root_file.txt"; Length = 5000; FullName = "$Path\root_file.txt" })
                    }
                    else { @() }
                }

                $chunks = Get-DirectoryChunks -Path "C:\Root" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB

                $chunks.Count | Should -Be 4

                $regularChunks = $chunks | Where-Object { -not $_.IsFilesOnly }
                $regularChunks.Count | Should -Be 3

                $filesOnlyChunks = $chunks | Where-Object { $_.IsFilesOnly }
                $filesOnlyChunks.Count | Should -Be 1
                $filesOnlyChunks[0].SourcePath | Should -Be "C:\Root"
            }
        }

        Context "Get-DirectoryChunks - MinSizeBytes Behavior" {
            It "Should accept small directory as single chunk when below MinSizeBytes" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    [PSCustomObject]@{
                        Path = $Path
                        TotalSize = 50MB  # Below MinSizeBytes of 100MB
                        FileCount = 100
                        DirCount = 2
                        AvgFileSize = 500KB
                        LastScanned = Get-Date
                    }
                }
                Mock Get-DirectoryChildren { @("C:\Small\Sub1", "C:\Small\Sub2") }

                # MinSizeBytes = 100MB, so 50MB directory should be accepted as single chunk
                $chunks = Get-DirectoryChunks -Path "C:\Small" -DestinationRoot "D:\Backup" `
                    -MaxSizeBytes 1GB -MinSizeBytes 100MB

                $chunks.Count | Should -Be 1
                $chunks[0].SourcePath | Should -Be "C:\Small"
            }

            It "Should recurse into children when directory is above MinSizeBytes but below MaxSizeBytes" {
                Mock Test-Path { $true }
                Mock Get-DirectoryProfile {
                    param($Path)
                    if ($Path -eq "C:\Medium") {
                        [PSCustomObject]@{
                            Path = $Path
                            TotalSize = 500MB  # Above MinSizeBytes (100MB) and below MaxSizeBytes (1GB)
                            FileCount = 20000   # But above MaxFiles threshold
                            DirCount = 2
                            AvgFileSize = 25KB
                            LastScanned = Get-Date
                        }
                    }
                    else {
                        [PSCustomObject]@{
                            Path = $Path
                            TotalSize = 200MB
                            FileCount = 5000
                            DirCount = 0
                            AvgFileSize = 40KB
                            LastScanned = Get-Date
                        }
                    }
                }
                Mock Get-DirectoryChildren {
                    param($Path)
                    if ($Path -eq "C:\Medium") { @("C:\Medium\Sub1", "C:\Medium\Sub2") } else { @() }
                }
                Mock Get-FilesAtLevel { @() }

                # Size is above MinSizeBytes but FileCount exceeds MaxFiles, so it should recurse
                $chunks = Get-DirectoryChunks -Path "C:\Medium" -DestinationRoot "D:\Backup" `
                    -MaxSizeBytes 1GB -MaxFiles 10000 -MinSizeBytes 100MB

                $chunks.Count | Should -Be 2  # Two subdirectory chunks
            }
        }
    }
}
