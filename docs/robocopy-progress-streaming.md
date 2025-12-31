# Task: Stream Robocopy Progress via Stdout Instead of Log File

## Objective
Replace log file reading for live robocopy progress with streaming stdout capture. Currently, `Get-RobocopyProgress` tries to read the log file while robocopy has it open, which fails or returns stale data. The stdout approach already works for directory enumeration (`Invoke-RobocopyList`) and should be used for actual copying too.

## Problem Statement

### Current Architecture (Broken for Live Progress)
```
Start-RobocopyJob:
  - Creates Process with RedirectStandardOutput = true
  - Uses ReadToEndAsync() for stdout capture
  - Problem: ReadToEndAsync() blocks until process EXITS
  - No way to get partial stdout during execution

Get-RobocopyProgress:
  - Tries to read log file: ConvertFrom-RobocopyLog -LogPath $Job.LogPath
  - Problem: Log file is locked by robocopy process
  - Reading fails or gets incomplete/stale data
  - Progress bar doesn't update during copy
```

### What Works (Directory Enumeration)
```powershell
# DirectoryProfiling.ps1 - Invoke-RobocopyList
$psi.RedirectStandardOutput = $true
$process.OutputDataReceived += {
    # Process each line as it arrives
    $output.Add($_.Data)
    $lineCount++
    if ($State -and ($lineCount % 100 -eq 0)) {
        $State.ScanProgress = $lineCount
    }
}
$process.BeginOutputReadLine()  # Start async streaming
$process.WaitForExit()
```

This pattern provides real-time progress updates during enumeration.

## Success Criteria
1. Progress bar updates in real-time during robocopy execution
2. No log file reading while robocopy is running
3. Final stats still parsed correctly after completion
4. No performance regression (streaming should be faster than file polling)
5. Works for all robocopy jobs (single file, directory, mirror)
6. All existing tests pass

## Research: Current Implementation

### Start-RobocopyJob (Robocopy.ps1:370-420)
```powershell
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $robocopyPath
$psi.Arguments = $fullArgs
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true   # <-- Already redirecting
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
$process.Start() | Out-Null

# Start async stdout read immediately to prevent buffer overflow
# Uses ReadToEndAsync - blocks until process exits!
$stdoutTask = $process.StandardOutput.ReadToEndAsync()

return [PSCustomObject]@{
    Process = $process
    LogPath = $LogPath
    Chunk = $Chunk
    StartTime = [datetime]::Now
    StdoutTask = $stdoutTask  # <-- Can only read AFTER exit
}
```

### Get-RobocopyProgress (Robocopy.ps1:772-789)
```powershell
function Get-RobocopyProgress {
    param([PSCustomObject]$Job)

    # Tries to read log file - fails because robocopy has it open!
    return ConvertFrom-RobocopyLog -LogPath $Job.LogPath -TailLines 100
}
```

### ConvertFrom-RobocopyLog File Reading (Robocopy.ps1:570-580)
```powershell
# Open with FileShare.ReadWrite to allow concurrent access
# This SHOULD work but often fails or gets incomplete data
$fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
```

### Working Pattern - Invoke-RobocopyList (DirectoryProfiling.ps1:355-410)
```powershell
$output = [System.Collections.Generic.List[string]]::new()
$lineCount = 0

$process.add_OutputDataReceived({
    param($sender, $e)
    if ($null -ne $e.Data) {
        $output.Add($e.Data)
        $lineCount++
        # Real-time progress update
        if ($State -and ($lineCount % 100 -eq 0)) {
            $State.CurrentActivity = "Enumerating..."
            $State.ScanProgress = $lineCount
        }
    }
})

$process.BeginOutputReadLine()  # Start streaming
$process.WaitForExit()
```

## Implementation Plan

### Phase 1: Add Streaming Infrastructure to Job Object

#### Step 1: Create Thread-Safe Output Buffer
```powershell
# New class for thread-safe progress tracking
class RobocopyProgressBuffer {
    [System.Collections.Concurrent.ConcurrentQueue[string]]$Lines
    [int64]$BytesCopied
    [int]$FilesCopied
    [string]$CurrentFile
    [datetime]$LastUpdate

    RobocopyProgressBuffer() {
        $this.Lines = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $this.BytesCopied = 0
        $this.FilesCopied = 0
        $this.CurrentFile = ""
        $this.LastUpdate = [datetime]::Now
    }
}
```

#### Step 2: Modify Start-RobocopyJob
```powershell
function Start-RobocopyJob {
    # ... existing setup ...

    # Create progress buffer for streaming
    $progressBuffer = [RobocopyProgressBuffer]::new()

    # Set up streaming output handler
    $process.add_OutputDataReceived({
        param($sender, $eventArgs)
        if ($null -ne $eventArgs.Data) {
            $line = $eventArgs.Data

            # Add to buffer for final parsing
            $progressBuffer.Lines.Enqueue($line)

            # Parse progress indicators in real-time
            # Look for: "New File", bytes copied, file names
            if ($line -match '^\s+New File\s+(\d+)\s+(.+)$') {
                $progressBuffer.CurrentFile = $matches[2]
            }
            elseif ($line -match '^\s+(\d+)\s+') {
                # Byte count line
                $progressBuffer.BytesCopied += [int64]$matches[1]
            }
            # ... more parsing ...

            $progressBuffer.LastUpdate = [datetime]::Now
        }
    })

    $process.BeginOutputReadLine()  # Start streaming!

    return [PSCustomObject]@{
        Process = $process
        LogPath = $LogPath
        Chunk = $Chunk
        StartTime = [datetime]::Now
        ProgressBuffer = $progressBuffer  # NEW: Live progress
        # StdoutTask removed - using streaming instead
    }
}
```

### Phase 2: Update Progress Reading

#### Step 3: Modify Get-RobocopyProgress
```powershell
function Get-RobocopyProgress {
    param([PSCustomObject]$Job)

    $buffer = $Job.ProgressBuffer
    if (-not $buffer) {
        # Fallback for old-style jobs
        return ConvertFrom-RobocopyLog -LogPath $Job.LogPath -TailLines 100
    }

    # Return live progress from buffer
    return [PSCustomObject]@{
        BytesCopied = $buffer.BytesCopied
        FilesCopied = $buffer.FilesCopied
        CurrentFile = $buffer.CurrentFile
        LastUpdate = $buffer.LastUpdate
        IsComplete = $Job.Process.HasExited
    }
}
```

### Phase 3: Update Job Completion

#### Step 4: Modify Wait-RobocopyJob
```powershell
function Wait-RobocopyJob {
    param([PSCustomObject]$Job, [int]$TimeoutSeconds = 0)

    # Wait for process
    if ($TimeoutSeconds -gt 0) {
        $completed = $Job.Process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $completed) {
            try { $Job.Process.Kill() } catch { }
            throw "Robocopy job timed out"
        }
    }
    else {
        $Job.Process.WaitForExit()
    }

    # Get final stats from buffered output (no file reading needed!)
    $allLines = @()
    while ($Job.ProgressBuffer.Lines.TryDequeue([ref]$line)) {
        $allLines += $line
    }
    $capturedOutput = $allLines -join "`n"

    # Parse final statistics from captured output
    $finalStats = ConvertFrom-RobocopyLog -Content $capturedOutput -LogPath $Job.LogPath

    return [PSCustomObject]@{
        ExitCode = $Job.Process.ExitCode
        ExitMeaning = Get-RobocopyExitMeaning -ExitCode $Job.Process.ExitCode
        Duration = [datetime]::Now - $Job.StartTime
        Stats = $finalStats
    }
}
```

### Phase 4: GUI Integration

#### Step 5: Update GUI Progress Display
The GUI already polls `Get-RobocopyProgress` - no changes needed if the function signature stays the same. Just ensure returned object has same properties.

## Robocopy Output Format Reference

```
-------------------------------------------------------------------------------
   ROBOCOPY     ::     Robust File Copy for Windows
-------------------------------------------------------------------------------

  Started : Monday, December 30, 2025 6:30:00 PM
   Source : C:\Source\
     Dest : D:\Dest\

    Files : *.*

  Options : /S /E /DCOPY:T /COPY:DAT /R:3 /W:10

------------------------------------------------------------------------------

	                   1	C:\Source\
	    New File  		    1024	file1.txt
	    New File  		    2048	subdir\file2.txt
100%
	    New File  		    4096	large.bin
  50%
 100%

------------------------------------------------------------------------------

               Total    Copied   Skipped  Mismatch    FAILED    Extras
    Dirs :         3         3         0         0         0         0
   Files :        10         8         2         0         0         0
   Bytes :     1.5 m     1.2 m   300.0 k         0         0         0
   Times :   0:00:05   0:00:03                       0:00:00   0:00:02
```

Key patterns to parse:
- `New File [size] [path]` - new file being copied
- `100%` or `50%` - per-file progress (when /NP not used)
- Summary table at end for final stats

## Files to Modify

| File | Changes |
|------|---------|
| `src/Robocurse/Public/Robocopy.ps1` | Major: streaming in Start-RobocopyJob, update Get-RobocopyProgress, update Wait-RobocopyJob |
| `src/Robocurse/Public/OrchestrationCore.ps1` | May need RobocopyProgressBuffer class definition |
| `tests/Unit/RobocopyWrapper.Tests.ps1` | Update tests for new streaming behavior |

## Test Plan

### Unit Tests
```powershell
Describe "Robocopy Streaming Progress" {
    It "Should capture output in real-time" {
        # Start job, wait briefly, check buffer has content
    }

    It "Should parse file progress from stream" {
        # Verify BytesCopied, FilesCopied update during execution
    }

    It "Should have complete output at end" {
        # Verify all lines captured, final stats correct
    }
}
```

### Integration Tests
```powershell
Describe "Robocopy Progress Integration" {
    It "Should show progress during actual file copy" {
        # Create large temp file
        # Start robocopy
        # Poll Get-RobocopyProgress several times
        # Verify BytesCopied increases
    }
}
```

### Manual Testing
1. Start GUI, run profile with large files
2. Verify progress bar updates during copy (not just at start/end)
3. Verify final stats are correct
4. Verify no "file locked" errors in logs

## Verification
1. Progress bar updates continuously during copy
2. No log file reading during active robocopy
3. Final statistics match actual files copied
4. No performance regression
5. All existing tests pass
6. Log file still created (for historical reference)

## Performance Notes
- Streaming should be faster than file polling (no disk I/O during copy)
- ConcurrentQueue is lock-free for single producer/consumer
- Event handler runs on thread pool - keep it fast
- Buffer memory usage: ~100 bytes per line, typically < 10MB total

## Rollback Plan
If issues found:
1. Revert to StdoutTask approach
2. Add retry logic to log file reading
3. Accept slightly delayed progress updates
