#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

InModuleScope 'Robocurse' {
    Describe "Utility Functions" {

        Context "Test-IsWindowsPlatform" {
            It "Should return a boolean value" {
                $result = Test-IsWindowsPlatform
                $result | Should -BeOfType [bool]
            }

            It "Should return true on Windows" -Skip:(-not $IsWindows) {
                Test-IsWindowsPlatform | Should -Be $true
            }
        }

        Context "New-OperationResult" {
            It "Should create success result with data" {
                $result = New-OperationResult -Success $true -Data "test data"

                $result.Success | Should -Be $true
                $result.Data | Should -Be "test data"
                $result.ErrorMessage | Should -BeNullOrEmpty
            }

            It "Should create failure result with error message" {
                $result = New-OperationResult -Success $false -ErrorMessage "Something went wrong"

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Be "Something went wrong"
            }

            It "Should include error record when provided" {
                try { throw "Test error" } catch { $err = $_ }
                $result = New-OperationResult -Success $false -ErrorMessage "Failed" -ErrorRecord $err

                $result.ErrorRecord | Should -Not -BeNullOrEmpty
                $result.ErrorRecord.Exception.Message | Should -Be "Test error"
            }
        }

        Context "Test-SafeRobocopyArgument" {
            It "Should accept normal paths" {
                Test-SafeRobocopyArgument -Value "C:\Users\John\Documents" | Should -Be $true
                Test-SafeRobocopyArgument -Value "\\SERVER\Share\Folder" | Should -Be $true
                Test-SafeRobocopyArgument -Value "D:\Backups\2024-01-15" | Should -Be $true
            }

            It "Should accept normal file patterns" {
                Test-SafeRobocopyArgument -Value "*.tmp" | Should -Be $true
                Test-SafeRobocopyArgument -Value "*.log" | Should -Be $true
                Test-SafeRobocopyArgument -Value "~*" | Should -Be $true
            }

            It "Should reject command separators" {
                Test-SafeRobocopyArgument -Value "path; del *" | Should -Be $false
                Test-SafeRobocopyArgument -Value "path & calc" | Should -Be $false
                Test-SafeRobocopyArgument -Value "path | cmd" | Should -Be $false
            }

            It "Should reject shell redirectors" {
                Test-SafeRobocopyArgument -Value "path > file" | Should -Be $false
                Test-SafeRobocopyArgument -Value "path < input" | Should -Be $false
            }

            It "Should reject command substitution patterns" {
                Test-SafeRobocopyArgument -Value 'path $(whoami)' | Should -Be $false
                Test-SafeRobocopyArgument -Value 'path `ls`' | Should -Be $false
            }

            It "Should reject environment variable expansion" {
                Test-SafeRobocopyArgument -Value '%TEMP%\path' | Should -Be $false
            }

            It "Should reject arguments starting with dash" {
                Mock Write-RobocurseLog { }
                Test-SafeRobocopyArgument -Value "-malicious" | Should -Be $false
            }

            It "Should accept empty strings" {
                Test-SafeRobocopyArgument -Value "" | Should -Be $true
            }

            It "Should allow double-dots in filenames (not traversal)" {
                # Files with ".." in the name (not at path boundaries) should be allowed
                Test-SafeRobocopyArgument -Value "C:\Data\file..name.txt" | Should -Be $true
                Test-SafeRobocopyArgument -Value "C:\Data\archive..backup.zip" | Should -Be $true
                Test-SafeRobocopyArgument -Value "report..final..v2.docx" | Should -Be $true
            }

            It "Should reject parent directory traversal patterns" {
                # Actual traversal at path boundaries should be blocked
                Test-SafeRobocopyArgument -Value "..\secret" | Should -Be $false
                Test-SafeRobocopyArgument -Value "C:\Data\..\secret" | Should -Be $false
                Test-SafeRobocopyArgument -Value "folder/../escape" | Should -Be $false
                Test-SafeRobocopyArgument -Value "path\.." | Should -Be $false
            }
        }

        Context "Test-SourcePathAccessible" {
            It "Should return success for existing readable path" {
                $testPath = $TestDrive
                $result = Test-SourcePathAccessible -Path $testPath

                $result.Success | Should -Be $true
            }

            It "Should return failure for non-existent path" {
                $result = Test-SourcePathAccessible -Path "C:\NonExistentPath\DoesNotExist\AtAll"

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "does not exist"
            }

            It "Should return failure with helpful message for UNC paths" {
                $result = Test-SourcePathAccessible -Path "\\NonExistentServer\FakeShare"

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "network connectivity"
            }
        }

        Context "Test-DestinationDiskSpace" {
            It "Should return success for paths with sufficient space" {
                # Use TestDrive which should have space
                $testPath = $TestDrive
                $result = Test-DestinationDiskSpace -Path $testPath

                $result.Success | Should -Be $true
            }

            It "Should skip disk space check for UNC paths" {
                Mock Test-Path { $true }

                $result = Test-DestinationDiskSpace -Path "\\SERVER\Share\Backup"

                $result.Success | Should -Be $true
                $result.Data | Should -Match "UNC path"
            }

            It "Should return failure when parent path does not exist for UNC" {
                Mock Test-Path { param($Path) $false }

                $result = Test-DestinationDiskSpace -Path "\\SERVER\Share\NonExistent\Path"

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "parent does not exist"
            }

            It "Should handle estimated size parameter" -Skip:(-not $IsWindows) {
                # This test needs a real path on Windows to check disk space
                $result = Test-DestinationDiskSpace -Path $TestDrive -EstimatedSizeBytes 1MB

                # Should succeed because TestDrive should have at least 1MB
                $result.Success | Should -Be $true
            }
        }

        Context "Test-RobocopyOptionsValid" {
            It "Should accept null options" {
                $result = Test-RobocopyOptionsValid -Options $null

                $result.Success | Should -Be $true
            }

            It "Should accept empty options hashtable" {
                $result = Test-RobocopyOptionsValid -Options @{}

                $result.Success | Should -Be $true
            }

            It "Should accept safe options" {
                $options = @{
                    Switches = @('/MIR', '/COPYALL', '/DCOPY:DAT')
                    ExcludeFiles = @('*.tmp')
                    ExcludeDirs = @('$RECYCLE.BIN')
                }

                $result = Test-RobocopyOptionsValid -Options $options

                $result.Success | Should -Be $true
            }

            It "Should warn about /PURGE without /MIR" {
                $options = @{
                    Switches = @('/PURGE', '/E')
                }

                $result = Test-RobocopyOptionsValid -Options $options

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "PURGE.*without.*MIR"
            }

            It "Should warn about /MOVE" {
                $options = @{
                    Switches = @('/MOVE')
                }

                $result = Test-RobocopyOptionsValid -Options $options

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "DELETE source files"
            }

            It "Should warn about /MOV (short form)" {
                $options = @{
                    Switches = @('/MOV')
                }

                $result = Test-RobocopyOptionsValid -Options $options

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "DELETE source files"
            }

            It "Should warn about conflicting /XX with /MIR" {
                $options = @{
                    Switches = @('/MIR', '/XX')
                }

                $result = Test-RobocopyOptionsValid -Options $options

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "conflict"
            }

            It "Should warn about managed switches being overridden" {
                $options = @{
                    Switches = @('/MT:16', '/LOG:custom.log')
                }

                $result = Test-RobocopyOptionsValid -Options $options

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "Robocurse-managed"
            }

            It "Should accept /PURGE with /MIR" {
                $options = @{
                    Switches = @('/MIR', '/PURGE')
                }

                $result = Test-RobocopyOptionsValid -Options $options

                # /PURGE with /MIR is fine (redundant but not dangerous)
                $result.Success | Should -Be $true
            }
        }

        Context "Get-SanitizedPath" {
            It "Should return safe paths unchanged" {
                $result = Get-SanitizedPath -Path "C:\Users\Test" -ParameterName "Source"
                $result | Should -Be "C:\Users\Test"
            }

            It "Should throw for unsafe paths" {
                { Get-SanitizedPath -Path "C:\Users; del *" -ParameterName "Source" } | Should -Throw
            }
        }

        Context "Get-SanitizedExcludePatterns" {
            BeforeEach {
                Mock Write-RobocurseLog { }
            }

            It "Should return safe patterns unchanged" {
                $patterns = @('*.tmp', '*.log', '~*')
                $result = Get-SanitizedExcludePatterns -Patterns $patterns -Type 'Files'

                $result.Count | Should -Be 3
                $result | Should -Contain '*.tmp'
            }

            It "Should filter out unsafe patterns" {
                $patterns = @('*.tmp', 'safe; del *', '*.log')
                $result = Get-SanitizedExcludePatterns -Patterns $patterns -Type 'Files'

                $result.Count | Should -Be 2
                $result | Should -Not -Contain 'safe; del *'
            }

            It "Should handle empty array" {
                $result = Get-SanitizedExcludePatterns -Patterns @() -Type 'Files'

                $result.Count | Should -Be 0
            }
        }

        Context "Test-SafeConfigPath" {
            It "Should accept relative paths" {
                Test-SafeConfigPath -Path ".\config.json" | Should -Be $true
            }

            It "Should accept absolute paths" {
                Test-SafeConfigPath -Path "C:\Configs\robocurse.json" | Should -Be $true
            }

            It "Should reject paths with shell metacharacters" {
                Test-SafeConfigPath -Path "config.json; rm -rf /" | Should -Be $false
                Test-SafeConfigPath -Path "config.json & calc" | Should -Be $false
            }

            It "Should reject paths with command substitution" {
                Test-SafeConfigPath -Path 'config$(whoami).json' | Should -Be $false
            }

            It "Should accept empty path" {
                # Empty path will fail at file load, but is technically safe
                Test-SafeConfigPath -Path "" | Should -Be $true
            }
        }

        Context "Get-SanitizedChunkArgs" {
            BeforeEach {
                Mock Write-RobocurseLog { }
            }

            It "Should accept valid /LEV:n arguments" {
                $result = Get-SanitizedChunkArgs -ChunkArgs @('/LEV:1', '/LEV:5')
                $result.Count | Should -Be 2
                $result | Should -Contain '/LEV:1'
                $result | Should -Contain '/LEV:5'
            }

            It "Should accept valid /S and /E switches" {
                $result = Get-SanitizedChunkArgs -ChunkArgs @('/S', '/E')
                $result.Count | Should -Be 2
                $result | Should -Contain '/S'
                $result | Should -Contain '/E'
            }

            It "Should accept valid age switches" {
                $result = Get-SanitizedChunkArgs -ChunkArgs @('/MAXAGE:7', '/MINAGE:1')
                $result.Count | Should -Be 2
                $result | Should -Contain '/MAXAGE:7'
                $result | Should -Contain '/MINAGE:1'
            }

            It "Should reject arbitrary robocopy switches" {
                $result = Get-SanitizedChunkArgs -ChunkArgs @('/LEV:1', '/MIR', '/PURGE')
                $result.Count | Should -Be 1
                $result | Should -Contain '/LEV:1'
                $result | Should -Not -Contain '/MIR'
                $result | Should -Not -Contain '/PURGE'
            }

            It "Should reject command injection attempts" {
                $result = Get-SanitizedChunkArgs -ChunkArgs @('/LEV:1; calc', '&& del *')
                $result.Count | Should -Be 0
            }

            It "Should handle empty array" {
                $result = Get-SanitizedChunkArgs -ChunkArgs @()
                $result.Count | Should -Be 0
            }

            It "Should skip whitespace-only arguments" {
                # Note: Empty strings in array are filtered by the function
                $result = Get-SanitizedChunkArgs -ChunkArgs @('/LEV:1', '   ', '  ', '/S')
                $result.Count | Should -Be 2
                $result | Should -Contain '/LEV:1'
                $result | Should -Contain '/S'
            }
        }
    }
}
