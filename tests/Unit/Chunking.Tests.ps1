#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type (required for module isolation when running all tests together)
Initialize-OrchestrationStateType | Out-Null

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
                    # -2 is invalid (below -1), -1 is valid (unlimited for Smart mode)
                    Get-DirectoryChunks -Path $testDir.FullName -DestinationRoot "D:\Backup" -MaxDepth -2
                } | Should -Throw
            }

            It "Should accept MaxDepth of -1 for unlimited recursion (Smart mode)" {
                $testDir = New-Item -ItemType Directory -Path "$TestDrive/testdir-unlimited" -Force
                {
                    # -1 is valid for unlimited depth
                    Get-DirectoryChunks -Path $testDir.FullName -DestinationRoot "D:\Backup" -MaxDepth -1
                } | Should -Not -Throw
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
                $chunks = @(Get-DirectoryChunks -Path "C:\Test" -DestinationRoot "D:\Backup" `
                    -MaxSizeBytes 1GB -MinSizeBytes 100MB)

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

                $chunks = @(Get-DirectoryChunks -Path "C:\Small" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB)

                @($chunks).Count | Should -Be 1
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

                $chunks = @(Get-DirectoryChunks -Path "C:\Large" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB)

                @($chunks).Count | Should -Be 2
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

                $chunks = @(Get-DirectoryChunks -Path "C:\NoSubdirs" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB)

                @($chunks).Count | Should -Be 1
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

                $chunks = @(Get-DirectoryChunks -Path "C:\Deep" -DestinationRoot "D:\Backup" -MaxDepth 2 -MaxSizeBytes 10GB)

                @($chunks).Count | Should -BeGreaterThan 0
                @($chunks).Count | Should -BeLessOrEqual 10
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

                $chunks = @(Get-DirectoryChunks -Path "C:\AtDepth" -DestinationRoot "D:\Backup" -MaxDepth 0 -MaxSizeBytes 10GB)

                @($chunks).Count | Should -Be 1
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
                        # Use Write-Output to preserve array through pipeline
                        Write-Output @([PSCustomObject]@{ Name = "file.txt"; Length = 1000; FullName = "C:\Mixed\file.txt" }) -NoEnumerate
                    }
                    else { Write-Output @() -NoEnumerate }
                }

                $chunks = @(Get-DirectoryChunks -Path "C:\Mixed" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB)

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

                $chunks = @(Get-DirectoryChunks -Path "C:\OnlySubdirs" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB)

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

                $chunks = @(New-FlatChunks -Path "C:\TestFlat" -DestinationRoot "D:\Backup")

                @($chunks).Count | Should -Be 1
                $chunks[0].SourcePath | Should -Be "C:\TestFlat"
                $chunks[0].DestinationPath | Should -Be "D:\Backup"
            }

            It "Should use provided MaxDepth parameter" {
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

                # Flat mode with MaxDepth=0 means top-level only
                $chunks = @(New-FlatChunks -Path "C:\Test" -DestinationRoot "D:\Backup" -MaxDepth 0)

                @($chunks).Count | Should -Be 1
                $chunks[0].EstimatedSize | Should -Be 5GB
            }
        }

        Context "New-SmartChunks" {
            It "Should create chunks recursively" {
                Mock Test-Path { $true }
                # Use values relative to actual defaults so test adapts when defaults change
                $maxSize = $script:DefaultMaxChunkSizeBytes
                $maxFiles = $script:DefaultMaxFilesPerChunk
                Mock Get-DirectoryProfile {
                    param($Path)
                    if ($Path -eq "C:\TestSmart") {
                        # Exceeds thresholds to trigger splitting (2x defaults)
                        [PSCustomObject]@{
                            Path = $Path
                            TotalSize = $maxSize * 2
                            FileCount = $maxFiles * 2
                            DirCount = 2
                            AvgFileSize = 500KB
                            LastScanned = Get-Date
                        }
                    }
                    else {
                        # Child directories are under thresholds (20% of defaults)
                        [PSCustomObject]@{
                            Path = $Path
                            TotalSize = [int64]($maxSize * 0.2)
                            FileCount = [int]($maxFiles * 0.2)
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

                # Smart mode uses unlimited depth (-1) automatically
                $chunks = @(New-SmartChunks -Path "C:\TestSmart" -DestinationRoot "D:\Backup")

                @($chunks).Count | Should -Be 2
                $chunks[0].SourcePath | Should -BeLike "*Child*"
                $chunks[1].SourcePath | Should -BeLike "*Child*"
            }

            It "Should use unlimited depth by default" {
                Mock Test-Path { $true }
                # Create a deep structure: Root -> Level1 -> Level2 -> Level3 (leaf)
                Mock Get-DirectoryProfile {
                    param($Path)
                    switch -Wildcard ($Path) {
                        "*Level3" {
                            [PSCustomObject]@{
                                Path = $Path
                                TotalSize = 5GB
                                FileCount = 10000
                                DirCount = 0
                                AvgFileSize = 500KB
                                LastScanned = Get-Date
                            }
                        }
                        default {
                            [PSCustomObject]@{
                                Path = $Path
                                TotalSize = 100GB
                                FileCount = 500000
                                DirCount = 1
                                AvgFileSize = 200KB
                                LastScanned = Get-Date
                            }
                        }
                    }
                }
                Mock Get-DirectoryChildren {
                    param($Path)
                    switch -Wildcard ($Path) {
                        "*Level3" { @() }
                        "*Level2" { @("$Path\Level3") }
                        "*Level1" { @("$Path\Level2") }
                        default { @("$Path\Level1") }
                    }
                }
                Mock Get-FilesAtLevel { @() }

                # Smart mode should recurse all the way to Level3 (unlimited depth)
                $chunks = @(New-SmartChunks -Path "C:\Deep" -DestinationRoot "D:\Backup")

                @($chunks).Count | Should -Be 1
                $chunks[0].SourcePath | Should -BeLike "*Level3"
            }

            It "Should only accept Path, DestinationRoot, State, and TreeNode parameters" {
                # New-SmartChunks is fully automatic with no tuning parameters
                $cmd = Get-Command New-SmartChunks
                $paramNames = $cmd.Parameters.Keys | Where-Object { $_ -notmatch '^(Verbose|Debug|ErrorAction|WarningAction|InformationAction|ErrorVariable|WarningVariable|InformationVariable|OutVariable|OutBuffer|PipelineVariable)$' }
                $paramNames | Should -Contain 'Path'
                $paramNames | Should -Contain 'DestinationRoot'
                $paramNames | Should -Contain 'State'
                $paramNames | Should -Contain 'TreeNode'
                $paramNames | Should -Not -Contain 'MaxChunkSizeBytes'
                $paramNames | Should -Not -Contain 'MaxFiles'
                $paramNames | Should -Not -Contain 'MaxDepth'
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

                $chunks = @(New-SmartChunks -Path "C:\Test" -DestinationRoot "D:\Backup")

                @($chunks).Count | Should -Be 1
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
                        Write-Output @([PSCustomObject]@{ Name = "root_file.txt"; Length = 5000; FullName = "$Path\root_file.txt" }) -NoEnumerate
                    }
                    else { Write-Output @() -NoEnumerate }
                }

                $chunks = @(Get-DirectoryChunks -Path "C:\Root" -DestinationRoot "D:\Backup" -MaxSizeBytes 10GB)

                @($chunks).Count | Should -Be 4

                $regularChunks = @($chunks | Where-Object { -not $_.IsFilesOnly })
                @($regularChunks).Count | Should -Be 3

                $filesOnlyChunks = @($chunks | Where-Object { $_.IsFilesOnly })
                @($filesOnlyChunks).Count | Should -Be 1
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
                $chunks = @(Get-DirectoryChunks -Path "C:\Small" -DestinationRoot "D:\Backup" `
                    -MaxSizeBytes 1GB -MinSizeBytes 100MB)

                @($chunks).Count | Should -Be 1
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
                $chunks = @(Get-DirectoryChunks -Path "C:\Medium" -DestinationRoot "D:\Backup" `
                    -MaxSizeBytes 1GB -MaxFiles 10000 -MinSizeBytes 100MB)

                @($chunks).Count | Should -Be 2  # Two subdirectory chunks
            }
        }

        Context "Get-DirectoryChunks with TreeNode Parameter" {
            It "Should use TreeNode data instead of calling Get-DirectoryProfile" {
                $tree = [DirectoryNode]::new("C:\Test")
                $tree.DirectSize = 2GB
                $tree.DirectFileCount = 500
                $tree.TotalSize = 2GB
                $tree.TotalFileCount = 500

                # Get-DirectoryProfile should NOT be called when TreeNode is provided
                Mock Get-DirectoryProfile { throw "Get-DirectoryProfile should not be called when TreeNode is provided" }
                Mock Test-Path { $true }

                $chunks = @(Get-DirectoryChunks -Path "C:\Test" -DestinationRoot "D:\Backup" -TreeNode $tree)

                @($chunks).Count | Should -Be 1
                $chunks[0].EstimatedSize | Should -Be 2GB
                $chunks[0].EstimatedFiles | Should -Be 500
            }

            It "Should use tree children for recursion instead of Get-DirectoryChildren" {
                $tree = [DirectoryNode]::new("C:\Test")
                $tree.DirectSize = 0
                $tree.DirectFileCount = 0

                $child1 = [DirectoryNode]::new("C:\Test\Child1")
                $child1.DirectSize = 3GB
                $child1.DirectFileCount = 1000
                $child1.TotalSize = 3GB
                $child1.TotalFileCount = 1000
                $tree.Children["Child1"] = $child1

                $child2 = [DirectoryNode]::new("C:\Test\Child2")
                $child2.DirectSize = 4GB
                $child2.DirectFileCount = 2000
                $child2.TotalSize = 4GB
                $child2.TotalFileCount = 2000
                $tree.Children["Child2"] = $child2

                Update-TreeTotals -Node $tree

                Mock Get-DirectoryProfile { throw "Should not be called" }
                Mock Get-DirectoryChildren { throw "Should not be called" }
                Mock Test-Path { $true }

                # With 10GB max, both children fit in one chunk each
                $chunks = @(Get-DirectoryChunks -Path "C:\Test" -DestinationRoot "D:\Backup" -TreeNode $tree -MaxSizeBytes 10GB)

                # Tree is 7GB total, which fits in one 10GB chunk
                @($chunks).Count | Should -Be 1
            }

            It "Should produce chunks with total size matching tree total" {
                $tree = [DirectoryNode]::new("C:\Test")
                $tree.DirectSize = 1GB
                $tree.DirectFileCount = 100

                $child1 = [DirectoryNode]::new("C:\Test\Small")
                $child1.DirectSize = 2GB
                $child1.DirectFileCount = 200
                $child1.TotalSize = 2GB
                $child1.TotalFileCount = 200
                $tree.Children["Small"] = $child1

                $child2 = [DirectoryNode]::new("C:\Test\Large")
                $child2.DirectSize = 15GB  # Exceeds 10GB chunk size
                $child2.DirectFileCount = 1500
                $child2.TotalSize = 15GB
                $child2.TotalFileCount = 1500
                $tree.Children["Large"] = $child2

                Update-TreeTotals -Node $tree

                Mock Get-DirectoryProfile { throw "Should not be called" }
                Mock Test-Path { $true }
                Mock Get-DirectoryChildren { throw "Should not be called" }

                $chunks = @(Get-DirectoryChunks -Path "C:\Test" -DestinationRoot "D:\Backup" -TreeNode $tree -MaxSizeBytes 10GB)

                # Verify total size matches tree
                $chunkTotalSize = ($chunks | Measure-Object -Property EstimatedSize -Sum).Sum
                $chunkTotalSize | Should -Be $tree.TotalSize
            }

            It "Should produce chunks with total file count matching tree total" {
                $tree = [DirectoryNode]::new("C:\Test")
                $tree.DirectSize = 500MB
                $tree.DirectFileCount = 50

                $child = [DirectoryNode]::new("C:\Test\Sub")
                $child.DirectSize = 1GB
                $child.DirectFileCount = 150
                $child.TotalSize = 1GB
                $child.TotalFileCount = 150
                $tree.Children["Sub"] = $child

                Update-TreeTotals -Node $tree

                Mock Get-DirectoryProfile { throw "Should not be called" }
                Mock Test-Path { $true }

                $chunks = @(Get-DirectoryChunks -Path "C:\Test" -DestinationRoot "D:\Backup" -TreeNode $tree)

                $chunkTotalFiles = ($chunks | Measure-Object -Property EstimatedFiles -Sum).Sum
                $chunkTotalFiles | Should -Be $tree.TotalFileCount
            }

            It "Should handle tree with files at root level using DirectFileCount" {
                $tree = [DirectoryNode]::new("C:\Test")
                $tree.DirectSize = 2GB
                $tree.DirectFileCount = 200

                $child = [DirectoryNode]::new("C:\Test\Sub")
                $child.DirectSize = 3GB
                $child.DirectFileCount = 300
                $child.TotalSize = 3GB
                $child.TotalFileCount = 300
                $tree.Children["Sub"] = $child

                Update-TreeTotals -Node $tree

                Mock Get-DirectoryProfile { throw "Should not be called" }
                Mock Get-FilesAtLevel { throw "Should not be called when using tree" }
                Mock Test-Path { $true }

                $chunks = @(Get-DirectoryChunks -Path "C:\Test" -DestinationRoot "D:\Backup" -TreeNode $tree -MaxSizeBytes 10GB)

                # Total should still match
                $chunkTotalSize = ($chunks | Measure-Object -Property EstimatedSize -Sum).Sum
                $chunkTotalSize | Should -Be $tree.TotalSize
            }

            It "New-SmartChunks should pass TreeNode to Get-DirectoryChunks" {
                $tree = [DirectoryNode]::new("C:\Test")
                $tree.DirectSize = 500MB
                $tree.DirectFileCount = 50
                $tree.TotalSize = 500MB
                $tree.TotalFileCount = 50

                Mock Get-DirectoryProfile { throw "Should not be called" }
                Mock Test-Path { $true }

                $chunks = @(New-SmartChunks -Path "C:\Test" -DestinationRoot "D:\Backup" -TreeNode $tree)

                @($chunks).Count | Should -Be 1
                $chunks[0].EstimatedSize | Should -Be 500MB
            }

            It "New-FlatChunks should pass TreeNode to Get-DirectoryChunks" {
                $tree = [DirectoryNode]::new("C:\Test")
                $tree.DirectSize = 500MB
                $tree.DirectFileCount = 50
                $tree.TotalSize = 500MB
                $tree.TotalFileCount = 50

                Mock Get-DirectoryProfile { throw "Should not be called" }
                Mock Test-Path { $true }

                $chunks = @(New-FlatChunks -Path "C:\Test" -DestinationRoot "D:\Backup" -TreeNode $tree)

                @($chunks).Count | Should -Be 1
            }

            It "Should handle deeply nested tree without calling Get-DirectoryProfile" {
                $root = [DirectoryNode]::new("C:\Root")
                $root.DirectSize = 100MB
                $root.DirectFileCount = 10

                $l1 = [DirectoryNode]::new("C:\Root\L1")
                $l1.DirectSize = 200MB
                $l1.DirectFileCount = 20

                $l2 = [DirectoryNode]::new("C:\Root\L1\L2")
                $l2.DirectSize = 300MB
                $l2.DirectFileCount = 30
                $l2.TotalSize = 300MB
                $l2.TotalFileCount = 30

                $l1.Children["L2"] = $l2
                $root.Children["L1"] = $l1

                Update-TreeTotals -Node $root

                Mock Get-DirectoryProfile { throw "Should never be called with TreeNode" }
                Mock Get-DirectoryChildren { throw "Should never be called with TreeNode" }
                Mock Test-Path { $true }

                $chunks = @(Get-DirectoryChunks -Path "C:\Root" -DestinationRoot "D:\Backup" -TreeNode $root -MaxDepth 5)

                $chunkTotalSize = ($chunks | Measure-Object -Property EstimatedSize -Sum).Sum
                $chunkTotalSize | Should -Be $root.TotalSize
                $root.TotalSize | Should -Be 600MB  # 100 + 200 + 300
            }
        }

        Context "Chunk Correctness - No Overlap and Complete Coverage" {
            # CRITICAL: These tests verify that chunks don't overlap (copy files twice)
            # and don't have gaps (miss files). Failures here indicate data integrity issues.

            It "Should NOT create overlapping chunks (no path is parent of another non-files-only chunk)" {
                # Setup: Root with children that get recursively chunked
                $root = [DirectoryNode]::new("C:\Data")
                $root.DirectSize = 500MB
                $root.DirectFileCount = 50

                $child1 = [DirectoryNode]::new("C:\Data\Projects")
                $child1.DirectSize = 8GB
                $child1.DirectFileCount = 10000
                $child1.TotalSize = 8GB
                $child1.TotalFileCount = 10000
                $root.Children["Projects"] = $child1

                $child2 = [DirectoryNode]::new("C:\Data\Archive")
                $child2.DirectSize = 5GB
                $child2.DirectFileCount = 5000
                $child2.TotalSize = 5GB
                $child2.TotalFileCount = 5000
                $root.Children["Archive"] = $child2

                Update-TreeTotals -Node $root

                Mock Test-Path { $true }

                $chunks = @(Get-DirectoryChunks -Path "C:\Data" -DestinationRoot "D:\Backup" -TreeNode $root -MaxSizeBytes 10GB)

                # Verify: No regular chunk's path should be a parent of another chunk's path
                # (files-only chunks are OK to share a path because they use /LEV:1)
                $regularChunks = @($chunks | Where-Object { -not $_.IsFilesOnly })

                for ($i = 0; $i -lt $regularChunks.Count; $i++) {
                    for ($j = 0; $j -lt $regularChunks.Count; $j++) {
                        if ($i -ne $j) {
                            $pathA = $regularChunks[$i].SourcePath
                            $pathB = $regularChunks[$j].SourcePath
                            # Check if pathA is a parent of pathB (would cause overlap)
                            $pathANorm = $pathA.TrimEnd('\') + '\'
                            $isParent = $pathB.StartsWith($pathANorm, [StringComparison]::OrdinalIgnoreCase)
                            $isParent | Should -Be $false -Because "Chunk $pathA should not be parent of chunk $pathB (would copy files twice)"
                        }
                    }
                }
            }

            It "Should create files-only chunk when parent is subdivided (prevents missing files)" {
                # When a directory is split into children, files at the root level need their own chunk
                $root = [DirectoryNode]::new("C:\Data")
                $root.DirectSize = 1GB  # Files directly in C:\Data
                $root.DirectFileCount = 100

                $child = [DirectoryNode]::new("C:\Data\SubDir")
                $child.DirectSize = 5GB
                $child.DirectFileCount = 5000
                $child.TotalSize = 5GB
                $child.TotalFileCount = 5000
                $root.Children["SubDir"] = $child

                Update-TreeTotals -Node $root

                Mock Test-Path { $true }

                # Force subdivision by making root exceed threshold
                $chunks = @(Get-DirectoryChunks -Path "C:\Data" -DestinationRoot "D:\Backup" -TreeNode $root -MaxSizeBytes 4GB)

                # Should have: 1 files-only chunk for C:\Data root files, 1 regular chunk for SubDir
                $filesOnlyChunks = @($chunks | Where-Object { $_.IsFilesOnly -eq $true })
                $regularChunks = @($chunks | Where-Object { $_.IsFilesOnly -ne $true })

                $filesOnlyChunks.Count | Should -Be 1 -Because "Root has files that need a files-only chunk"
                $filesOnlyChunks[0].SourcePath | Should -Be "C:\Data"
                $filesOnlyChunks[0].RobocopyArgs | Should -Contain "/LEV:1" -Because "Files-only chunks must use /LEV:1 to avoid recursing"

                $regularChunks.Count | Should -Be 1
                $regularChunks[0].SourcePath | Should -Be "C:\Data\SubDir"
            }

            It "Should have total estimated size equal to source total (no gaps)" {
                $root = [DirectoryNode]::new("C:\Source")
                $root.DirectSize = 2GB
                $root.DirectFileCount = 200

                $sub1 = [DirectoryNode]::new("C:\Source\A")
                $sub1.DirectSize = 3GB
                $sub1.DirectFileCount = 300
                $sub1.TotalSize = 3GB
                $sub1.TotalFileCount = 300
                $root.Children["A"] = $sub1

                $sub2 = [DirectoryNode]::new("C:\Source\B")
                $sub2.DirectSize = 4GB
                $sub2.DirectFileCount = 400
                $sub2.TotalSize = 4GB
                $sub2.TotalFileCount = 400
                $root.Children["B"] = $sub2

                Update-TreeTotals -Node $root

                Mock Test-Path { $true }

                $chunks = @(Get-DirectoryChunks -Path "C:\Source" -DestinationRoot "D:\Dest" -TreeNode $root -MaxSizeBytes 5GB)

                $totalChunkSize = ($chunks | Measure-Object -Property EstimatedSize -Sum).Sum
                $totalChunkFiles = ($chunks | Measure-Object -Property EstimatedFiles -Sum).Sum

                $totalChunkSize | Should -Be $root.TotalSize -Because "Sum of chunk sizes must equal source total (no gaps)"
                $totalChunkFiles | Should -Be $root.TotalFileCount -Because "Sum of chunk files must equal source total (no gaps)"
            }

            It "Should handle deep nesting without overlap or gaps" {
                # Create: Root -> L1 -> L2 -> L3, each level has files
                $root = [DirectoryNode]::new("C:\Deep")
                $root.DirectSize = 100MB
                $root.DirectFileCount = 10

                $l1 = [DirectoryNode]::new("C:\Deep\L1")
                $l1.DirectSize = 200MB
                $l1.DirectFileCount = 20

                $l2 = [DirectoryNode]::new("C:\Deep\L1\L2")
                $l2.DirectSize = 300MB
                $l2.DirectFileCount = 30

                $l3 = [DirectoryNode]::new("C:\Deep\L1\L2\L3")
                $l3.DirectSize = 15GB  # Large enough to be its own chunk
                $l3.DirectFileCount = 15000
                $l3.TotalSize = 15GB
                $l3.TotalFileCount = 15000

                $l2.Children["L3"] = $l3
                $l1.Children["L2"] = $l2
                $root.Children["L1"] = $l1

                Update-TreeTotals -Node $root

                Mock Test-Path { $true }

                $chunks = @(Get-DirectoryChunks -Path "C:\Deep" -DestinationRoot "D:\Backup" -TreeNode $root -MaxSizeBytes 10GB)

                # Verify no regular chunk overlap
                $regularChunks = @($chunks | Where-Object { -not $_.IsFilesOnly })
                for ($i = 0; $i -lt $regularChunks.Count; $i++) {
                    for ($j = 0; $j -lt $regularChunks.Count; $j++) {
                        if ($i -ne $j) {
                            $pathA = $regularChunks[$i].SourcePath.TrimEnd('\') + '\'
                            $pathB = $regularChunks[$j].SourcePath
                            $pathB.StartsWith($pathA, [StringComparison]::OrdinalIgnoreCase) | Should -Be $false
                        }
                    }
                }

                # Verify total coverage
                $totalChunkSize = ($chunks | Measure-Object -Property EstimatedSize -Sum).Sum
                $totalChunkSize | Should -Be $root.TotalSize
            }

            It "Should NOT have duplicate source paths (each path appears at most once per type)" {
                $root = [DirectoryNode]::new("C:\Data")
                $root.DirectSize = 1GB
                $root.DirectFileCount = 100

                $child = [DirectoryNode]::new("C:\Data\Sub")
                $child.DirectSize = 2GB
                $child.DirectFileCount = 200
                $child.TotalSize = 2GB
                $child.TotalFileCount = 200
                $root.Children["Sub"] = $child

                Update-TreeTotals -Node $root

                Mock Test-Path { $true }

                $chunks = @(Get-DirectoryChunks -Path "C:\Data" -DestinationRoot "D:\Backup" -TreeNode $root -MaxSizeBytes 1GB)

                # Group by source path and check for duplicates within same IsFilesOnly category
                $grouped = $chunks | Group-Object -Property SourcePath, IsFilesOnly
                foreach ($group in $grouped) {
                    $group.Count | Should -Be 1 -Because "Path $($group.Name) should not appear multiple times with same IsFilesOnly value"
                }
            }
        }
    }
}
