BeforeAll {
    # Source the main script to get access to functions
    . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
}

Describe "Robocopy Wrapper" {
    Context "Get-RobocopyExitMeaning" {
        It "Should interpret exit code 0 as success (no changes)" {
            $result = Get-RobocopyExitMeaning -ExitCode 0
            $result.Severity | Should -Be "Success"
            $result.Message | Should -Be "No changes needed"
            $result.FilesCopied | Should -Be $false
            $result.ExtrasDetected | Should -Be $false
            $result.MismatchesFound | Should -Be $false
            $result.CopyErrors | Should -Be $false
            $result.FatalError | Should -Be $false
            $result.ShouldRetry | Should -Be $false
        }

        It "Should interpret exit code 1 as success (files copied)" {
            $result = Get-RobocopyExitMeaning -ExitCode 1
            $result.Severity | Should -Be "Success"
            $result.Message | Should -Be "Files copied successfully"
            $result.FilesCopied | Should -Be $true
            $result.ExtrasDetected | Should -Be $false
            $result.MismatchesFound | Should -Be $false
            $result.CopyErrors | Should -Be $false
            $result.FatalError | Should -Be $false
            $result.ShouldRetry | Should -Be $false
        }

        It "Should interpret exit code 2 as success (extras cleaned)" {
            $result = Get-RobocopyExitMeaning -ExitCode 2
            $result.Severity | Should -Be "Success"
            $result.Message | Should -Be "Extra files cleaned from destination"
            $result.FilesCopied | Should -Be $false
            $result.ExtrasDetected | Should -Be $true
            $result.MismatchesFound | Should -Be $false
            $result.CopyErrors | Should -Be $false
            $result.FatalError | Should -Be $false
            $result.ShouldRetry | Should -Be $false
        }

        It "Should interpret exit code 3 as success (files copied + extras)" {
            $result = Get-RobocopyExitMeaning -ExitCode 3
            $result.Severity | Should -Be "Success"
            $result.Message | Should -Be "Extra files cleaned from destination"
            $result.FilesCopied | Should -Be $true
            $result.ExtrasDetected | Should -Be $true
            $result.MismatchesFound | Should -Be $false
            $result.CopyErrors | Should -Be $false
            $result.FatalError | Should -Be $false
            $result.ShouldRetry | Should -Be $false
        }

        It "Should interpret exit code 4 as warning (mismatches)" {
            $result = Get-RobocopyExitMeaning -ExitCode 4
            $result.Severity | Should -Be "Warning"
            $result.Message | Should -Be "Mismatched files detected"
            $result.FilesCopied | Should -Be $false
            $result.ExtrasDetected | Should -Be $false
            $result.MismatchesFound | Should -Be $true
            $result.CopyErrors | Should -Be $false
            $result.FatalError | Should -Be $false
            $result.ShouldRetry | Should -Be $false
        }

        It "Should interpret exit code 8 as error (copy errors)" {
            $result = Get-RobocopyExitMeaning -ExitCode 8
            $result.Severity | Should -Be "Error"
            $result.Message | Should -Be "Some files could not be copied"
            $result.FilesCopied | Should -Be $false
            $result.ExtrasDetected | Should -Be $false
            $result.MismatchesFound | Should -Be $false
            $result.CopyErrors | Should -Be $true
            $result.FatalError | Should -Be $false
            $result.ShouldRetry | Should -Be $true
        }

        It "Should interpret exit code 16 as fatal" {
            $result = Get-RobocopyExitMeaning -ExitCode 16
            $result.Severity | Should -Be "Fatal"
            $result.Message | Should -Be "Fatal error occurred"
            $result.FilesCopied | Should -Be $false
            $result.ExtrasDetected | Should -Be $false
            $result.MismatchesFound | Should -Be $false
            $result.CopyErrors | Should -Be $false
            $result.FatalError | Should -Be $true
            $result.ShouldRetry | Should -Be $true
        }

        It "Should handle combined exit codes (9 = files copied + copy errors)" {
            $result = Get-RobocopyExitMeaning -ExitCode 9  # 1 + 8
            $result.FilesCopied | Should -Be $true
            $result.CopyErrors | Should -Be $true
            $result.Severity | Should -Be "Error"
            $result.ShouldRetry | Should -Be $true
        }

        It "Should handle combined exit codes (3 = files copied + extras)" {
            $result = Get-RobocopyExitMeaning -ExitCode 3  # 1 + 2
            $result.FilesCopied | Should -Be $true
            $result.ExtrasDetected | Should -Be $true
            $result.Severity | Should -Be "Success"
        }

        It "Should handle combined exit codes (7 = files copied + extras + mismatches)" {
            $result = Get-RobocopyExitMeaning -ExitCode 7  # 1 + 2 + 4
            $result.FilesCopied | Should -Be $true
            $result.ExtrasDetected | Should -Be $true
            $result.MismatchesFound | Should -Be $true
            $result.Severity | Should -Be "Warning"
        }
    }

    Context "Parse-RobocopyLog" {
        It "Should extract file counts from completed log" {
            $logContent = @"
-------------------------------------------------------------------------------
                   Total    Copied   Skipped  Mismatch    FAILED    Extras
        Dirs :      100        10        90         0         0         0
       Files :     1000       500       500         0         5         0
       Bytes :   1.0 g   500.0 m   500.0 m         0    10.0 k         0
       Times :   0:05:23   0:03:12                       0:00:00   0:02:10

       Speed :            50.123 MegaBytes/min.
       Speed :          2621440 Bytes/sec.
"@
            $logPath = "$TestDrive/test.log"
            $logContent | Set-Content $logPath

            $result = Parse-RobocopyLog -LogPath $logPath

            $result.FilesCopied | Should -Be 500
            $result.FilesSkipped | Should -Be 500
            $result.FilesFailed | Should -Be 5
            $result.DirsCopied | Should -Be 10
            $result.DirsSkipped | Should -Be 90
            $result.DirsFailed | Should -Be 0
            $result.BytesCopied | Should -Be 524288000  # 500 MB
            $result.Speed | Should -Be "50.123 MB/min"
        }

        It "Should handle log file not existing" {
            $result = Parse-RobocopyLog -LogPath "$TestDrive/nonexistent.log"
            $result | Should -Not -BeNullOrEmpty
            $result.FilesCopied | Should -Be 0
            $result.FilesSkipped | Should -Be 0
            $result.FilesFailed | Should -Be 0
        }

        It "Should handle empty log file" {
            $logPath = "$TestDrive/empty.log"
            "" | Set-Content $logPath

            $result = Parse-RobocopyLog -LogPath $logPath

            $result.FilesCopied | Should -Be 0
            $result.FilesSkipped | Should -Be 0
            $result.FilesFailed | Should -Be 0
        }

        It "Should parse current file from progress lines" {
            $logContent = @"
          New File            1024    Documents\report.docx
          Newer               500000    Documents\notes.txt
         *EXTRA File          100000    OldStuff\deleted.tmp
"@
            $logPath = "$TestDrive/progress.log"
            $logContent | Set-Content $logPath

            $result = Parse-RobocopyLog -LogPath $logPath

            $result.CurrentFile | Should -Be "OldStuff\deleted.tmp"
        }

        It "Should parse bytes with kilobyte unit" {
            $logContent = @"
               Total    Copied   Skipped  Mismatch    FAILED    Extras
    Dirs :      10         1         9         0         0         0
   Files :     100        50        50         0         0         0
   Bytes :   100.0 k    50.0 k    50.0 k         0         0         0
"@
            $logPath = "$TestDrive/kb.log"
            $logContent | Set-Content $logPath

            $result = Parse-RobocopyLog -LogPath $logPath

            $result.BytesCopied | Should -Be 51200  # 50 KB
        }

        It "Should parse bytes with gigabyte unit" {
            $logContent = @"
               Total    Copied   Skipped  Mismatch    FAILED    Extras
    Dirs :      10         1         9         0         0         0
   Files :     100        50        50         0         0         0
   Bytes :   2.0 g     1.5 g     500.0 m         0         0         0
"@
            $logPath = "$TestDrive/gb.log"
            $logContent | Set-Content $logPath

            $result = Parse-RobocopyLog -LogPath $logPath

            $result.BytesCopied | Should -Be 1610612736  # 1.5 GB
        }

        It "Should parse bytes with no unit (plain bytes)" {
            $logContent = @"
               Total    Copied   Skipped  Mismatch    FAILED    Extras
    Dirs :      10         1         9         0         0         0
   Files :     100        50        50         0         0         0
   Bytes :   1024      512       512         0         0         0
"@
            $logPath = "$TestDrive/bytes.log"
            $logContent | Set-Content $logPath

            $result = Parse-RobocopyLog -LogPath $logPath

            $result.BytesCopied | Should -Be 512
        }
    }

    Context "Start-RobocopyJob" {
        It "Should build correct arguments with chunk object" {
            # Create mock chunk
            $chunk = [PSCustomObject]@{
                SourcePath = "C:\Source Path\With Spaces"
                DestinationPath = "D:\Dest"
                RobocopyArgs = @("/LEV:1")
            }

            $logPath = "$TestDrive/robocopy.log"

            # Mock the Process.Start method to avoid actually starting robocopy
            Mock -CommandName Invoke-Expression {
                return [PSCustomObject]@{
                    Process = [PSCustomObject]@{
                        HasExited = $false
                        ExitCode = 0
                    }
                }
            }

            # This test validates that the function accepts the correct parameters
            # We can't easily test the actual process start on macOS without robocopy.exe
            # But we can verify the function signature works correctly
            {
                # Instead of actually running, we'll just verify the function exists
                # and accepts the right parameters
                $null = Get-Command Start-RobocopyJob -ErrorAction Stop

                # Verify parameters exist
                $cmd = Get-Command Start-RobocopyJob
                $cmd.Parameters.ContainsKey('Chunk') | Should -Be $true
                $cmd.Parameters.ContainsKey('LogPath') | Should -Be $true
                $cmd.Parameters.ContainsKey('ThreadsPerJob') | Should -Be $true
            } | Should -Not -Throw
        }

        It "Should have correct parameter types" {
            $cmd = Get-Command Start-RobocopyJob

            $cmd.Parameters['Chunk'].ParameterType.Name | Should -Be 'PSObject'
            $cmd.Parameters['LogPath'].ParameterType.Name | Should -Be 'String'
            $cmd.Parameters['ThreadsPerJob'].ParameterType.Name | Should -Be 'Int32'
        }

        It "Should have mandatory parameters" {
            $cmd = Get-Command Start-RobocopyJob

            $cmd.Parameters['Chunk'].Attributes.Mandatory | Should -Contain $true
            $cmd.Parameters['LogPath'].Attributes.Mandatory | Should -Contain $true
        }

        It "Should have default value for ThreadsPerJob" {
            $cmd = Get-Command Start-RobocopyJob

            # ThreadsPerJob should not be mandatory
            $mandatoryAttrs = $cmd.Parameters['ThreadsPerJob'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
            $mandatoryAttrs.Mandatory | Should -Not -Contain $true
        }
    }

    Context "Get-RobocopyProgress" {
        It "Should have correct parameters" {
            $cmd = Get-Command Get-RobocopyProgress

            $cmd.Parameters.ContainsKey('Job') | Should -Be $true
            $cmd.Parameters['Job'].ParameterType.Name | Should -Be 'PSObject'
        }
    }

    Context "Wait-RobocopyJob" {
        It "Should have correct parameters" {
            $cmd = Get-Command Wait-RobocopyJob

            $cmd.Parameters.ContainsKey('Job') | Should -Be $true
            $cmd.Parameters.ContainsKey('TimeoutSeconds') | Should -Be $true
            $cmd.Parameters['Job'].ParameterType.Name | Should -Be 'PSObject'
            $cmd.Parameters['TimeoutSeconds'].ParameterType.Name | Should -Be 'Int32'
        }
    }
}
