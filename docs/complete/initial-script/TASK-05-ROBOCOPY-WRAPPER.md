# Task 05: Robocopy Wrapper

## Overview
Implement wrapper functions for running robocopy processes, interpreting exit codes, and parsing log output for progress tracking.

## Research Required

### Web Research
- Robocopy exit codes (bitmask): https://ss64.com/nt/robocopy-exit.html
- Robocopy log format and switches
- `System.Diagnostics.Process` in PowerShell
- Capturing stdout/stderr from external processes

### Robocopy Exit Codes (Bitmask)
```
Bit 0 (1)  = Files copied successfully
Bit 1 (2)  = Extra files/dirs in destination
Bit 2 (4)  = Mismatched files/dirs detected
Bit 3 (8)  = Some files could NOT be copied (copy errors)
Bit 4 (16) = Fatal error (no files copied, serious error)

Common combinations:
0  = No files copied, no errors (nothing to do)
1  = Files copied successfully
2  = Extra files in destination (deleted if /MIR)
3  = Files copied + extras detected
4  = Mismatches found
8  = Some copy errors
16 = Fatal error
```

### Key Robocopy Switches
```
/MIR     = Mirror (delete extras in dest)
/COPY:DAT = Copy Data, Attributes, Timestamps
/DCOPY:T  = Copy directory timestamps
/MT:8     = 8 threads
/R:3      = 3 retries
/W:10     = 10 second wait between retries
/LOG:file = Log to file
/TEE      = Output to console AND log
/NP       = No progress percentage
/NDL      = No directory list
/BYTES    = Print sizes in bytes
/256      = Support long paths
/XJD      = Exclude junction directories
/XJF      = Exclude junction files
/LEV:1    = Only top level (for files-only chunks)
```

## Task Description

### Function: Start-RobocopyJob
```powershell
function Start-RobocopyJob {
    <#
    .SYNOPSIS
        Starts a robocopy process for a chunk
    .PARAMETER Chunk
        Chunk object with SourcePath, DestinationPath, etc.
    .PARAMETER LogPath
        Path for robocopy log file
    .PARAMETER ThreadsPerJob
        Number of threads (/MT:n)
    .OUTPUTS
        PSCustomObject with Process, Chunk, StartTime, LogPath
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Chunk,

        [Parameter(Mandatory)]
        [string]$LogPath,

        [int]$ThreadsPerJob = 8
    )

    # Build argument list
    $args = @(
        "`"$($Chunk.SourcePath)`"",
        "`"$($Chunk.DestinationPath)`"",
        "/MIR",
        "/COPY:DAT",
        "/DCOPY:T",
        "/MT:$ThreadsPerJob",
        "/R:3",
        "/W:10",
        "/LOG:`"$LogPath`"",
        "/TEE",
        "/NP",
        "/NDL",
        "/BYTES",
        "/256",
        "/XJD",
        "/XJF"
    )

    # Add chunk-specific args (like /LEV:1 for files-only)
    $args += $Chunk.RobocopyArgs

    # Start process
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "robocopy.exe"
    $psi.Arguments = $args -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $false  # Using /LOG instead
    $psi.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::Start($psi)

    return [PSCustomObject]@{
        Process = $process
        Chunk = $Chunk
        StartTime = [datetime]::Now
        LogPath = $LogPath
    }
}
```

### Function: Get-RobocopyExitMeaning
```powershell
function Get-RobocopyExitMeaning {
    <#
    .SYNOPSIS
        Interprets robocopy exit code
    .PARAMETER ExitCode
        Robocopy exit code
    .OUTPUTS
        PSCustomObject with Severity (Success/Warning/Error/Fatal), Message, ShouldRetry
    #>
    param(
        [Parameter(Mandatory)]
        [int]$ExitCode
    )

    # Implementation
    $result = [PSCustomObject]@{
        ExitCode = $ExitCode
        Severity = "Success"
        Message = ""
        ShouldRetry = $false
        FilesCopied = ($ExitCode -band 1) -ne 0
        ExtrasDetected = ($ExitCode -band 2) -ne 0
        MismatchesFound = ($ExitCode -band 4) -ne 0
        CopyErrors = ($ExitCode -band 8) -ne 0
        FatalError = ($ExitCode -band 16) -ne 0
    }

    if ($result.FatalError) {
        $result.Severity = "Fatal"
        $result.Message = "Fatal error occurred"
        $result.ShouldRetry = $true  # Worth retrying once
    }
    elseif ($result.CopyErrors) {
        $result.Severity = "Error"
        $result.Message = "Some files could not be copied"
        $result.ShouldRetry = $true
    }
    elseif ($result.MismatchesFound) {
        $result.Severity = "Warning"
        $result.Message = "Mismatched files detected"
    }
    elseif ($result.ExtrasDetected) {
        $result.Severity = "Success"
        $result.Message = "Extra files cleaned from destination"
    }
    elseif ($result.FilesCopied) {
        $result.Severity = "Success"
        $result.Message = "Files copied successfully"
    }
    else {
        $result.Severity = "Success"
        $result.Message = "No changes needed"
    }

    return $result
}
```

### Function: Parse-RobocopyLog
```powershell
function Parse-RobocopyLog {
    <#
    .SYNOPSIS
        Parses a robocopy log file for progress and statistics
    .PARAMETER LogPath
        Path to log file
    .PARAMETER TailLines
        Number of lines to read from end (for in-progress parsing)
    .OUTPUTS
        PSCustomObject with statistics
    #>
    param(
        [Parameter(Mandatory)]
        [string]$LogPath,

        [int]$TailLines = 100
    )

    # Read last N lines (for progress) or entire file (for final stats)
    # Parse for:
    # - Current file being copied
    # - File counts (copied, skipped, failed)
    # - Byte counts (copied, skipped, failed)
    # - Speed
    # - Errors
}
```

**Log Parsing Targets:**
```
# Header section (at end of log):
------------------------------------------------------------------------------

               Total    Copied   Skipped  Mismatch    FAILED    Extras
    Dirs :      1234       123      1111         0         0         5
   Files :     45678     12345     33333         0         3        10
   Bytes :   1.234 g   500.0 m   734.0 m         0    10.0 k    50.0 k
   Times :   0:05:23   0:03:12                       0:00:00   0:02:10

   Speed :            50.123 MegaBytes/min.
   Speed :          2,621,440 Bytes/sec.

# Progress lines (during copy):
          New File            1.2 m    Documents\report.docx
          Newer               500 k    Documents\notes.txt
         *EXTRA File          100 k    OldStuff\deleted.tmp
```

### Function: Get-RobocopyProgress
```powershell
function Get-RobocopyProgress {
    <#
    .SYNOPSIS
        Gets current progress from a running robocopy job
    .PARAMETER Job
        Job object from Start-RobocopyJob
    .OUTPUTS
        PSCustomObject with CurrentFile, BytesCopied, FilesCopied, etc.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Job
    )

    # Read log file tail (handle file locking!)
    # Parse for current activity
}
```

**File Locking Note:**
```powershell
# Robocopy has the log file open - use FileShare.ReadWrite
$fs = [System.IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite')
$sr = New-Object System.IO.StreamReader($fs)
# Read content
$sr.Close()
$fs.Close()
```

### Function: Wait-RobocopyJob
```powershell
function Wait-RobocopyJob {
    <#
    .SYNOPSIS
        Waits for a robocopy job to complete
    .PARAMETER Job
        Job object from Start-RobocopyJob
    .PARAMETER TimeoutSeconds
        Max wait time (0 = infinite)
    .OUTPUTS
        PSCustomObject with ExitCode, Duration, FinalStats
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Job,

        [int]$TimeoutSeconds = 0
    )

    if ($TimeoutSeconds -gt 0) {
        $completed = $Job.Process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $completed) {
            $Job.Process.Kill()
            throw "Robocopy job timed out"
        }
    }
    else {
        $Job.Process.WaitForExit()
    }

    $duration = [datetime]::Now - $Job.StartTime
    $exitCode = $Job.Process.ExitCode
    $finalStats = Parse-RobocopyLog -LogPath $Job.LogPath

    return [PSCustomObject]@{
        ExitCode = $exitCode
        ExitMeaning = Get-RobocopyExitMeaning -ExitCode $exitCode
        Duration = $duration
        Stats = $finalStats
    }
}
```

## Success Criteria

1. [ ] `Start-RobocopyJob` spawns robocopy process correctly
2. [ ] `Start-RobocopyJob` handles paths with spaces
3. [ ] `Start-RobocopyJob` includes chunk-specific args (e.g., /LEV:1)
4. [ ] `Get-RobocopyExitMeaning` correctly interprets all exit codes
5. [ ] `Parse-RobocopyLog` extracts file/byte counts
6. [ ] `Parse-RobocopyLog` handles in-progress logs (file locking)
7. [ ] `Get-RobocopyProgress` returns current file being copied
8. [ ] `Wait-RobocopyJob` returns final statistics

## Pester Tests Required

Create `tests/Unit/RobocopyWrapper.Tests.ps1`:

```powershell
Describe "Robocopy Wrapper" {
    BeforeAll {
        . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
    }

    Context "Get-RobocopyExitMeaning" {
        It "Should interpret exit code 0 as success (no changes)" {
            $result = Get-RobocopyExitMeaning -ExitCode 0
            $result.Severity | Should -Be "Success"
            $result.FilesCopied | Should -Be $false
        }

        It "Should interpret exit code 1 as success (files copied)" {
            $result = Get-RobocopyExitMeaning -ExitCode 1
            $result.Severity | Should -Be "Success"
            $result.FilesCopied | Should -Be $true
        }

        It "Should interpret exit code 2 as success (extras cleaned)" {
            $result = Get-RobocopyExitMeaning -ExitCode 2
            $result.Severity | Should -Be "Success"
            $result.ExtrasDetected | Should -Be $true
        }

        It "Should interpret exit code 8 as error (copy errors)" {
            $result = Get-RobocopyExitMeaning -ExitCode 8
            $result.Severity | Should -Be "Error"
            $result.CopyErrors | Should -Be $true
            $result.ShouldRetry | Should -Be $true
        }

        It "Should interpret exit code 16 as fatal" {
            $result = Get-RobocopyExitMeaning -ExitCode 16
            $result.Severity | Should -Be "Fatal"
            $result.FatalError | Should -Be $true
        }

        It "Should handle combined exit codes" {
            $result = Get-RobocopyExitMeaning -ExitCode 9  # 1 + 8 = files copied but some errors
            $result.FilesCopied | Should -Be $true
            $result.CopyErrors | Should -Be $true
            $result.Severity | Should -Be "Error"
        }
    }

    Context "Parse-RobocopyLog" {
        It "Should extract file counts from completed log" {
            $logContent = @"
               Total    Copied   Skipped  Mismatch    FAILED    Extras
    Dirs :      100        10        90         0         0         0
   Files :     1000       500       500         0         5         0
   Bytes :   1.0 g   500.0 m   500.0 m         0    10.0 k         0
"@
            $logPath = "$TestDrive\test.log"
            $logContent | Set-Content $logPath

            $result = Parse-RobocopyLog -LogPath $logPath

            $result.FilesCopied | Should -Be 500
            $result.FilesSkipped | Should -Be 500
            $result.FilesFailed | Should -Be 5
            $result.DirsCopied | Should -Be 10
        }

        It "Should handle log file not existing" {
            { Parse-RobocopyLog -LogPath "$TestDrive\nonexistent.log" } | Should -Not -Throw
        }
    }

    Context "Start-RobocopyJob" {
        It "Should create process with correct arguments" {
            # We can't easily test actual robocopy execution
            # but we can test argument building

            $chunk = [PSCustomObject]@{
                SourcePath = "C:\Source Path\With Spaces"
                DestinationPath = "D:\Dest"
                RobocopyArgs = @("/LEV:1")
            }

            # Mock Process.Start
            Mock Start-Process { }

            # This test validates argument construction
            # Actual process start would require integration test
        }
    }
}
```

## Integration Test (Manual)

Create a test directory structure and verify actual copying:

```powershell
# Setup test data
$testSource = "$TestDrive\Source"
$testDest = "$TestDrive\Dest"
New-Item -Path $testSource -ItemType Directory
1..10 | ForEach-Object {
    "Content $_" | Set-Content "$testSource\file$_.txt"
}

# Run actual robocopy
$chunk = [PSCustomObject]@{
    SourcePath = $testSource
    DestinationPath = $testDest
    RobocopyArgs = @()
}
$job = Start-RobocopyJob -Chunk $chunk -LogPath "$TestDrive\test.log"
$result = Wait-RobocopyJob -Job $job

# Verify
$result.ExitMeaning.Severity | Should -Be "Success"
(Get-ChildItem $testDest).Count | Should -Be 10
```

## Dependencies
- Task 00 (Project Structure)
- Task 02 (Logging)
- Task 04 (Chunking) - for chunk object structure

## Estimated Complexity
- Medium
- External process management, log parsing
