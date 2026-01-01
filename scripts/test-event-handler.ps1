# Minimal test to verify event handler is capturing stdout lines
$ErrorActionPreference = 'Stop'

# Load module
. "$PSScriptRoot\..\dist\Robocurse.ps1"

# Create test directories
$testDir = Join-Path $env:TEMP "robocurse-event-test"
$src = Join-Path $testDir "src"
$dst = Join-Path $testDir "dst"
$logDir = Join-Path $testDir "logs"

Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $src -Force | Out-Null
New-Item -ItemType Directory -Path $dst -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

# Create test file (2MB for slower copy)
$fileSize = 2MB
$bytes = [byte[]]::new($fileSize)
(New-Object Random).NextBytes($bytes)
[IO.File]::WriteAllBytes("$src\testfile.bin", $bytes)

Write-Host "Created test file: $fileSize bytes"

# Initialize logging
Initialize-LogSession -LogRoot $logDir
Test-RobocopyAvailable | Out-Null

# Start robocopy job
$chunk = [PSCustomObject]@{
    ChunkId = 1
    SourcePath = $src
    DestinationPath = $dst
    EstimatedSize = $fileSize
    EstimatedFiles = 1
    Depth = 0
    IsFilesOnly = $false
    Status = 'Pending'
    RetryCount = 0
    RetryAfter = $null
    LastExitCode = $null
    LastErrorMessage = $null
    RobocopyArgs = @()
}

$logPath = Join-Path $logDir "test.log"
$job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -ThreadsPerJob 1

Write-Host "Job started, PID: $($job.Process.Id)"
Write-Host "ProgressBuffer type: $($job.ProgressBuffer.GetType().FullName)"

# Poll while running
$pollCount = 0
while (-not $job.Process.HasExited -and $pollCount -lt 100) {
    $buffer = $job.ProgressBuffer
    Write-Host ("Poll {0,3}: Lines={1} BytesCopied={2} FilesCopied={3} CurrentFile={4}" -f `
        $pollCount, $buffer.LineCount, $buffer.BytesCopied, $buffer.FilesCopied, $buffer.CurrentFile)
    $pollCount++
    Start-Sleep -Milliseconds 50
}

Write-Host ""
Write-Host "=== Process exited ==="
$result = Wait-RobocopyJob -Job $job -TimeoutSeconds 30
Write-Host "Exit code: $($result.ExitCode)"

# Final buffer state
$buffer = $job.ProgressBuffer
Write-Host ""
Write-Host "=== Final buffer state ==="
Write-Host "LineCount: $($buffer.LineCount)"
Write-Host "BytesCopied: $($buffer.BytesCopied)"
Write-Host "FilesCopied: $($buffer.FilesCopied)"
Write-Host "CompletedFilesBytes: $($buffer.CompletedFilesBytes)"
Write-Host "CurrentFileSize: $($buffer.CurrentFileSize)"
Write-Host "CurrentFileBytes: $($buffer.CurrentFileBytes)"
Write-Host "CurrentFile: $($buffer.CurrentFile)"

Write-Host ""
Write-Host "=== All captured lines ==="
$lines = $buffer.GetAllLines()
foreach ($line in $lines) {
    Write-Host "[$line]"
}

# Cleanup
Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
