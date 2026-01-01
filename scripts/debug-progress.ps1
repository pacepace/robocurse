# Debug script to test log file progress parsing during a real copy
$ErrorActionPreference = 'Stop'

# Load the module
. "$PSScriptRoot\..\dist\Robocurse.ps1"

# Create test directories
$testRoot = Join-Path $env:TEMP "robocurse-progress-debug"
$src = Join-Path $testRoot "source"
$dst = Join-Path $testRoot "dest"
$logDir = Join-Path $testRoot "logs"

Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $src -Force | Out-Null
New-Item -ItemType Directory -Path $dst -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

# Create 5 x 100MB files (500MB total - should take a few seconds even on SSD)
Write-Host "Creating test files..."
$fileSize = 100MB
$fileCount = 5
for ($i = 1; $i -le $fileCount; $i++) {
    $bytes = [byte[]]::new($fileSize)
    (New-Object Random).NextBytes($bytes)
    [IO.File]::WriteAllBytes("$src\file$i.bin", $bytes)
    Write-Host "  Created file$i.bin ($($fileSize / 1MB) MB)"
}

$totalSize = $fileSize * $fileCount
Write-Host "`nTotal size: $($totalSize / 1MB) MB"

# Initialize robocopy
Test-RobocopyAvailable | Out-Null

# Create chunk and start job
$chunk = [PSCustomObject]@{
    ChunkId = 1
    SourcePath = $src
    DestinationPath = $dst
    EstimatedSize = $totalSize
    EstimatedFiles = $fileCount
}

$logPath = Join-Path $logDir "copy.log"
$options = @{
    RetryCount = 0
    RetryWait = 0
    SkipJunctions = $true
    ExcludeFiles = @()
    ExcludeDirs = @()
}

Write-Host "`nStarting robocopy job..."
$job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions $options -ThreadsPerJob 1

Write-Host "Polling progress every 200ms..."
Write-Host ""

$pollCount = 0
while (-not $job.Process.HasExited) {
    $pollCount++

    # Check log file size
    $logSize = if (Test-Path $logPath) { (Get-Item $logPath).Length } else { 0 }

    # Also check log file content for "New File" lines
    $fileLineCount = 0
    if (Test-Path $logPath) {
        try {
            $fs = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs)
            $content = $sr.ReadToEnd()
            $sr.Dispose()
            $fs.Dispose()
            $fileLineCount = ([regex]::Matches($content, 'New File')).Count
        } catch {}
    }

    # Get progress
    $progress = Get-RobocopyProgress -Job $job

    $pct = if ($totalSize -gt 0) { [math]::Round(($progress.BytesCopied / $totalSize) * 100, 1) } else { 0 }

    Write-Host ("Poll {0,3}: LogSize={1,8}, NewFiles={2,2}, BytesCopied={3,12}, FilesCopied={4,2}, Progress={5,5}%, ParseSuccess={6}" -f `
        $pollCount, $logSize, $fileLineCount, $progress.BytesCopied, $progress.FilesCopied, $pct, $progress.ParseSuccess)

    Start-Sleep -Milliseconds 50  # More frequent polling
}

Write-Host "`nJob completed. Final poll:"
$progress = Get-RobocopyProgress -Job $job
$pct = if ($totalSize -gt 0) { [math]::Round(($progress.BytesCopied / $totalSize) * 100, 1) } else { 0 }
Write-Host ("  BytesCopied={0}, FilesCopied={1}, Progress={2}%" -f $progress.BytesCopied, $progress.FilesCopied, $pct)

# Show log file content
Write-Host "`n=== Log file content (last 30 lines) ==="
if (Test-Path $logPath) {
    Get-Content $logPath -Tail 30
}

# Cleanup
Write-Host "`nCleaning up..."
Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Done."
