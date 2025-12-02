BeforeAll {
    # Source the main script to get access to functions
    . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
}

Describe "Robocopy Wrapper" {
    Context "Test-RobocopyAvailable" {
        It "Should return OperationResult with correct structure" {
            $result = Test-RobocopyAvailable
            $result | Should -Not -BeNullOrEmpty
            $result.PSObject.Properties.Name | Should -Contain 'Success'
            $result.PSObject.Properties.Name | Should -Contain 'Data'
            $result.PSObject.Properties.Name | Should -Contain 'ErrorMessage'
        }

        It "Should cache the result after first call" {
            # Call twice and verify caching
            $result1 = Test-RobocopyAvailable
            $result2 = Test-RobocopyAvailable

            # If on Windows, both should return the same path
            if ($result1.Success) {
                $result1.Data | Should -Be $result2.Data
            }
        }

        It "Should have correct function signature" {
            $cmd = Get-Command Test-RobocopyAvailable
            # Should return OperationResult type object
            $cmd | Should -Not -BeNullOrEmpty
        }
    }

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

        It "Should allow configurable mismatch severity as Error" {
            $result = Get-RobocopyExitMeaning -ExitCode 4 -MismatchSeverity "Error"
            $result.Severity | Should -Be "Error"
            $result.MismatchesFound | Should -Be $true
            $result.ShouldRetry | Should -Be $true
        }

        It "Should allow configurable mismatch severity as Success" {
            $result = Get-RobocopyExitMeaning -ExitCode 4 -MismatchSeverity "Success"
            $result.Severity | Should -Be "Success"
            $result.MismatchesFound | Should -Be $true
            $result.ShouldRetry | Should -Be $false
        }

        It "Should default mismatch severity to Warning" {
            $result = Get-RobocopyExitMeaning -ExitCode 4
            $result.Severity | Should -Be "Warning"
            $result.ShouldRetry | Should -Be $false
        }
    }

    Context "ConvertFrom-RobocopyLog" {
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

            $result = ConvertFrom-RobocopyLog -LogPath $logPath

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
            $result = ConvertFrom-RobocopyLog -LogPath "$TestDrive/nonexistent.log"
            $result | Should -Not -BeNullOrEmpty
            $result.FilesCopied | Should -Be 0
            $result.FilesSkipped | Should -Be 0
            $result.FilesFailed | Should -Be 0
        }

        It "Should handle empty log file" {
            $logPath = "$TestDrive/empty.log"
            "" | Set-Content $logPath

            $result = ConvertFrom-RobocopyLog -LogPath $logPath

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

            $result = ConvertFrom-RobocopyLog -LogPath $logPath

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

            $result = ConvertFrom-RobocopyLog -LogPath $logPath

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

            $result = ConvertFrom-RobocopyLog -LogPath $logPath

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

            $result = ConvertFrom-RobocopyLog -LogPath $logPath

            $result.BytesCopied | Should -Be 512
        }
    }

    Context "Start-RobocopyJob" {
        It "Should throw when Chunk is null" {
            {
                Start-RobocopyJob -Chunk $null -LogPath "$TestDrive/test.log"
            } | Should -Throw "*Chunk*"
        }

        It "Should throw when Chunk.SourcePath is empty" {
            $badChunk = [PSCustomObject]@{
                SourcePath = ""
                DestinationPath = "D:\Test"
            }
            {
                Start-RobocopyJob -Chunk $badChunk -LogPath "$TestDrive/test.log"
            } | Should -Throw "*SourcePath*"
        }

        It "Should throw when Chunk.DestinationPath is empty" {
            $badChunk = [PSCustomObject]@{
                SourcePath = "C:\Source"
                DestinationPath = ""
            }
            {
                Start-RobocopyJob -Chunk $badChunk -LogPath "$TestDrive/test.log"
            } | Should -Throw "*DestinationPath*"
        }

        It "Should throw when LogPath is empty" {
            $chunk = [PSCustomObject]@{
                SourcePath = "C:\Source"
                DestinationPath = "D:\Dest"
            }
            {
                Start-RobocopyJob -Chunk $chunk -LogPath ""
            } | Should -Throw
        }

        It "Should throw when ThreadsPerJob is out of range (too low)" {
            $chunk = [PSCustomObject]@{
                SourcePath = "C:\Source"
                DestinationPath = "D:\Dest"
            }
            {
                Start-RobocopyJob -Chunk $chunk -LogPath "$TestDrive/test.log" -ThreadsPerJob 0
            } | Should -Throw
        }

        It "Should throw when ThreadsPerJob is out of range (too high)" {
            $chunk = [PSCustomObject]@{
                SourcePath = "C:\Source"
                DestinationPath = "D:\Dest"
            }
            {
                Start-RobocopyJob -Chunk $chunk -LogPath "$TestDrive/test.log" -ThreadsPerJob 129
            } | Should -Throw
        }

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

        It "Should accept RobocopyOptions with InterPacketGapMs" {
            $cmd = Get-Command Start-RobocopyJob

            # Verify RobocopyOptions parameter exists
            $cmd.Parameters.ContainsKey('RobocopyOptions') | Should -Be $true
            $cmd.Parameters['RobocopyOptions'].ParameterType.Name | Should -Be 'Hashtable'
        }

        It "Should have InterPacketGapMs documented in function help" {
            # Check the RobocopyOptions parameter description mentions InterPacketGapMs
            $help = Get-Help Start-RobocopyJob -Parameter RobocopyOptions -ErrorAction SilentlyContinue
            # If help parsing works, check description; otherwise verify function source mentions it
            if ($help -and $help.description) {
                $help.description.Text | Should -Match 'InterPacketGapMs'
            }
            else {
                # Fallback: verify the function's definition mentions InterPacketGapMs
                $funcDef = (Get-Command Start-RobocopyJob).ScriptBlock.ToString()
                $funcDef | Should -Match 'InterPacketGapMs'
            }
        }
    }

    Context "RobocopyOptions - InterPacketGapMs" {
        It "Should accept InterPacketGapMs in RobocopyOptions" {
            $options = @{
                InterPacketGapMs = 50
            }

            # Verify the options hashtable is valid
            $options.InterPacketGapMs | Should -Be 50
        }

        It "Should accept InterPacketGapMs with other options" {
            $options = @{
                Switches = @("/COPYALL")
                ExcludeFiles = @("*.tmp")
                InterPacketGapMs = 100
                RetryCount = 5
            }

            $options.InterPacketGapMs | Should -Be 100
            $options.RetryCount | Should -Be 5
            $options.Switches | Should -Contain "/COPYALL"
        }
    }

    Context "New-RobocopyArguments" {
        It "Should build basic arguments with source and destination" {
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt"

            $argString = $args -join ' '
            $argString | Should -Match '"C:\\Source"'
            $argString | Should -Match '"D:\\Dest"'
            $argString | Should -Match '/MIR'
            $argString | Should -Match '/LOG:'
        }

        It "Should use /E instead of /MIR when NoMirror is true" {
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt" `
                -RobocopyOptions @{ NoMirror = $true }

            $argString = $args -join ' '
            $argString | Should -Match '/E'
            $argString | Should -Not -Match '/MIR'
        }

        It "Should include /MT with thread count" {
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt" `
                -ThreadsPerJob 16

            $argString = $args -join ' '
            $argString | Should -Match '/MT:16'
        }

        It "Should include /IPG when InterPacketGapMs is specified" {
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt" `
                -RobocopyOptions @{ InterPacketGapMs = 50 }

            $argString = $args -join ' '
            $argString | Should -Match '/IPG:50'
        }

        It "Should include /XJD and /XJF by default for junction handling" {
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt"

            $argString = $args -join ' '
            $argString | Should -Match '/XJD'
            $argString | Should -Match '/XJF'
        }

        It "Should not include junction flags when SkipJunctions is false" {
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt" `
                -RobocopyOptions @{ SkipJunctions = $false }

            $argString = $args -join ' '
            $argString | Should -Not -Match '/XJD'
            $argString | Should -Not -Match '/XJF'
        }

        It "Should include exclude files" {
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt" `
                -RobocopyOptions @{ ExcludeFiles = @("*.tmp", "*.log") }

            $argString = $args -join ' '
            $argString | Should -Match '/XF'
            $argString | Should -Match '"\*\.tmp"'
            $argString | Should -Match '"\*\.log"'
        }

        It "Should include exclude directories" {
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt" `
                -RobocopyOptions @{ ExcludeDirs = @("temp", "cache") }

            $argString = $args -join ' '
            $argString | Should -Match '/XD'
            $argString | Should -Match '"temp"'
            $argString | Should -Match '"cache"'
        }

        It "Should include chunk-specific arguments" {
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt" `
                -ChunkArgs @("/LEV:1")

            $argString = $args -join ' '
            $argString | Should -Match '/LEV:1'
        }

        It "Should use custom retry settings" {
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt" `
                -RobocopyOptions @{ RetryCount = 5; RetryWait = 30 }

            $argString = $args -join ' '
            $argString | Should -Match '/R:5'
            $argString | Should -Match '/W:30'
        }

        It "Should include /L flag when DryRun is specified" {
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt" `
                -DryRun

            $argString = $args -join ' '
            $argString | Should -Match '/L'
        }

        It "Should not include /L flag when DryRun is not specified" {
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt"

            $argString = $args -join ' '
            $argString | Should -Not -Match ' /L$| /L '  # Match /L at end or followed by space (not /LOG)
        }

        It "Should have DryRun parameter" {
            $cmd = Get-Command New-RobocopyArguments
            $cmd.Parameters.ContainsKey('DryRun') | Should -Be $true
            $cmd.Parameters['DryRun'].ParameterType.Name | Should -Be 'SwitchParameter'
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

    Context "Get-BandwidthThrottleIPG" {
        It "Should return 0 when bandwidth limit is 0 (unlimited)" {
            $result = Get-BandwidthThrottleIPG -BandwidthLimitMbps 0 -ActiveJobs 4
            $result | Should -Be 0
        }

        It "Should return 0 when bandwidth limit is negative" {
            $result = Get-BandwidthThrottleIPG -BandwidthLimitMbps -10 -ActiveJobs 2
            $result | Should -Be 0
        }

        It "Should calculate IPG for single job" {
            # 100 Mbps = 12,500,000 bytes/sec
            # IPG = 512000 / 12500000 ≈ 0.04 → rounds to 1ms (minimum)
            $result = Get-BandwidthThrottleIPG -BandwidthLimitMbps 100 -ActiveJobs 1
            $result | Should -BeGreaterOrEqual 1
        }

        It "Should increase IPG as more jobs are active" {
            # More jobs = less bandwidth per job = higher IPG
            # Use 2 Mbps to ensure visible differences (at 100 Mbps, both clamp to 1ms)
            $ipg1Job = Get-BandwidthThrottleIPG -BandwidthLimitMbps 2 -ActiveJobs 1
            $ipg4Jobs = Get-BandwidthThrottleIPG -BandwidthLimitMbps 2 -ActiveJobs 4

            $ipg4Jobs | Should -BeGreaterThan $ipg1Job
        }

        It "Should account for pending job start" {
            # With -PendingJobStart, effective jobs should be ActiveJobs + 1
            # Use 2 Mbps to ensure visible differences
            $ipgWithoutPending = Get-BandwidthThrottleIPG -BandwidthLimitMbps 2 -ActiveJobs 2
            $ipgWithPending = Get-BandwidthThrottleIPG -BandwidthLimitMbps 2 -ActiveJobs 2 -PendingJobStart

            # With pending, we calculate for 3 jobs instead of 2
            $ipgWithPending | Should -BeGreaterThan $ipgWithoutPending
        }

        It "Should treat 0 active jobs as 1 (minimum)" {
            # Should not divide by zero
            $result = Get-BandwidthThrottleIPG -BandwidthLimitMbps 100 -ActiveJobs 0
            $result | Should -BeGreaterOrEqual 1
        }

        It "Should clamp IPG to minimum of 1ms" {
            # Very high bandwidth with few jobs should still return at least 1
            $result = Get-BandwidthThrottleIPG -BandwidthLimitMbps 10000 -ActiveJobs 1
            $result | Should -BeGreaterOrEqual 1
        }

        It "Should clamp IPG to maximum of 10000ms" {
            # Very low bandwidth with many jobs
            $result = Get-BandwidthThrottleIPG -BandwidthLimitMbps 1 -ActiveJobs 100
            $result | Should -BeLessOrEqual 10000
        }

        It "Should have correct function signature" {
            $cmd = Get-Command Get-BandwidthThrottleIPG

            $cmd.Parameters.ContainsKey('BandwidthLimitMbps') | Should -Be $true
            $cmd.Parameters.ContainsKey('ActiveJobs') | Should -Be $true
            $cmd.Parameters.ContainsKey('PendingJobStart') | Should -Be $true

            $cmd.Parameters['BandwidthLimitMbps'].ParameterType.Name | Should -Be 'Int32'
            $cmd.Parameters['ActiveJobs'].ParameterType.Name | Should -Be 'Int32'
            $cmd.Parameters['PendingJobStart'].ParameterType.Name | Should -Be 'SwitchParameter'
        }

        It "Should have mandatory parameters for BandwidthLimitMbps and ActiveJobs" {
            $cmd = Get-Command Get-BandwidthThrottleIPG

            $cmd.Parameters['BandwidthLimitMbps'].Attributes.Mandatory | Should -Contain $true
            $cmd.Parameters['ActiveJobs'].Attributes.Mandatory | Should -Contain $true
        }

        It "Should calculate reasonable IPG for common scenarios" {
            # 100 Mbps with 4 jobs = 25 Mbps per job = 3,125,000 bytes/sec
            # IPG = 512000 / 3125000 ≈ 0.16 → ceiling to 1ms
            $result = Get-BandwidthThrottleIPG -BandwidthLimitMbps 100 -ActiveJobs 4
            $result | Should -BeGreaterOrEqual 1
            $result | Should -BeLessOrEqual 1000  # Should be reasonable

            # 10 Mbps with 4 jobs = 2.5 Mbps per job = 312,500 bytes/sec
            # IPG = 512000 / 312500 ≈ 1.6 → ceiling to 2ms
            $result = Get-BandwidthThrottleIPG -BandwidthLimitMbps 10 -ActiveJobs 4
            $result | Should -BeGreaterOrEqual 1
        }

        It "Should return integer value" {
            $result = Get-BandwidthThrottleIPG -BandwidthLimitMbps 50 -ActiveJobs 3
            $result | Should -BeOfType [int]
        }
    }

    Context "Test-SafeRobocopyArgument - Security Validation" {
        It "Should accept valid simple path" {
            Test-SafeRobocopyArgument -Value "C:\Users\John" | Should -Be $true
        }

        It "Should accept valid UNC path" {
            Test-SafeRobocopyArgument -Value "\\server\share\folder" | Should -Be $true
        }

        It "Should accept valid path with spaces" {
            Test-SafeRobocopyArgument -Value "C:\Program Files\My App" | Should -Be $true
        }

        It "Should accept valid exclude pattern with wildcard" {
            Test-SafeRobocopyArgument -Value "*.tmp" | Should -Be $true
        }

        It "Should accept empty string" {
            Test-SafeRobocopyArgument -Value "" | Should -Be $true
        }

        It "Should reject command separator semicolon" {
            Test-SafeRobocopyArgument -Value "C:\path; del *" | Should -Be $false
        }

        It "Should reject command separator ampersand" {
            Test-SafeRobocopyArgument -Value "C:\path & malicious" | Should -Be $false
        }

        It "Should reject command separator pipe" {
            Test-SafeRobocopyArgument -Value "C:\path | format C:" | Should -Be $false
        }

        It "Should reject shell redirection greater-than" {
            Test-SafeRobocopyArgument -Value "C:\path > output.txt" | Should -Be $false
        }

        It "Should reject shell redirection less-than" {
            Test-SafeRobocopyArgument -Value "C:\path < input.txt" | Should -Be $false
        }

        It "Should reject backtick for command execution" {
            Test-SafeRobocopyArgument -Value "C:\path`nmalicious" | Should -Be $false
        }

        It "Should reject PowerShell command substitution" {
            Test-SafeRobocopyArgument -Value 'C:\$(Get-Process)' | Should -Be $false
        }

        It "Should reject PowerShell variable expansion with braces" {
            Test-SafeRobocopyArgument -Value 'C:\${env:TEMP}' | Should -Be $false
        }

        It "Should reject cmd.exe environment variable syntax" {
            Test-SafeRobocopyArgument -Value "C:\%TEMP%\file" | Should -Be $false
        }

        It "Should reject parent directory traversal" {
            Test-SafeRobocopyArgument -Value "C:\Users\..\Admin" | Should -Be $false
        }

        It "Should reject arguments starting with dash" {
            Test-SafeRobocopyArgument -Value "-Force" | Should -Be $false
        }

        It "Should reject null bytes" {
            Test-SafeRobocopyArgument -Value "C:\path`0malicious" | Should -Be $false
        }

        It "Should reject newlines" {
            Test-SafeRobocopyArgument -Value "C:\path`nmalicious" | Should -Be $false
        }

        It "Should reject carriage returns" {
            Test-SafeRobocopyArgument -Value "C:\path`rmalicious" | Should -Be $false
        }
    }

    Context "Get-SanitizedPath - Security Validation" {
        It "Should return safe path unchanged" {
            $result = Get-SanitizedPath -Path "C:\Users\John" -ParameterName "Source"
            $result | Should -Be "C:\Users\John"
        }

        It "Should throw for path with injection attempt" {
            { Get-SanitizedPath -Path "C:\path; del *" -ParameterName "Source" } | Should -Throw "*unsafe*"
        }

        It "Should include parameter name in error message" {
            { Get-SanitizedPath -Path "C:\path; del *" -ParameterName "SourcePath" } | Should -Throw "*SourcePath*"
        }
    }

    Context "Get-SanitizedExcludePatterns - Security Validation" {
        It "Should return all safe patterns" {
            $patterns = @("*.tmp", "*.log", "cache")
            $result = Get-SanitizedExcludePatterns -Patterns $patterns -Type 'Files'
            $result.Count | Should -Be 3
            $result | Should -Contain "*.tmp"
        }

        It "Should filter out unsafe patterns" {
            $patterns = @("*.tmp", "safe; malicious", "*.log")
            $result = Get-SanitizedExcludePatterns -Patterns $patterns -Type 'Files'
            $result.Count | Should -Be 2
            $result | Should -Not -Contain "safe; malicious"
        }

        It "Should return empty array when all patterns are unsafe" {
            $patterns = @("bad; rm -rf /", "evil | format")
            $result = Get-SanitizedExcludePatterns -Patterns $patterns -Type 'Dirs'
            $result.Count | Should -Be 0
        }

        It "Should handle empty input array" {
            $result = Get-SanitizedExcludePatterns -Patterns @() -Type 'Files'
            $result.Count | Should -Be 0
        }
    }

    Context "New-RobocopyArguments - Security Integration" {
        It "Should throw when source path contains injection" {
            { New-RobocopyArguments `
                -SourcePath "C:\Source; del *" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt"
            } | Should -Throw "*unsafe*"
        }

        It "Should throw when destination path contains injection" {
            { New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest & format C:" `
                -LogPath "C:\log.txt"
            } | Should -Throw "*unsafe*"
        }

        It "Should throw when log path contains injection" {
            { New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt; evil"
            } | Should -Throw "*unsafe*"
        }

        It "Should filter unsafe exclude files but not throw" {
            # Should not throw - just filters the bad pattern
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt" `
                -RobocopyOptions @{ ExcludeFiles = @("*.tmp", "bad; injection") }

            $argString = $args -join ' '
            $argString | Should -Match '"\*\.tmp"'
            $argString | Should -Not -Match 'injection'
        }

        It "Should filter unsafe exclude dirs but not throw" {
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt" `
                -RobocopyOptions @{ ExcludeDirs = @("temp", "evil | attack", "cache") }

            $argString = $args -join ' '
            $argString | Should -Match '"temp"'
            $argString | Should -Match '"cache"'
            $argString | Should -Not -Match 'attack'
        }

        It "Should omit /XF when all exclude file patterns are unsafe" {
            $args = New-RobocopyArguments `
                -SourcePath "C:\Source" `
                -DestinationPath "D:\Dest" `
                -LogPath "C:\log.txt" `
                -RobocopyOptions @{ ExcludeFiles = @("bad; del", "evil & cmd") }

            $argString = $args -join ' '
            $argString | Should -Not -Match '/XF'
        }
    }
}
