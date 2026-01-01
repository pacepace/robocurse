# Test that the progress buffer actually receives stdout

Import-Module "C:\Users\pace\pub\dev-wsl\vscode\robocurse\src\Robocurse\Robocurse.psm1" -Force

# Validate robocopy first
$roboResult = Test-RobocopyAvailable
if (-not $roboResult.Success) {
    Write-Error "Robocopy not available"
    exit 1
}

# Create test directories
$src = Join-Path $env:TEMP 'rc_progress_test_src'
$dst = Join-Path $env:TEMP 'rc_progress_test_dst'
$logDir = Join-Path $env:TEMP 'rc_progress_test_logs'
New-Item -ItemType Directory -Path $src -Force | Out-Null
New-Item -ItemType Directory -Path $dst -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

# Create test files
1..5 | ForEach-Object { "Test content for file $_" | Out-File "$src\file$_.txt" }

# Create a chunk
$chunk = [PSCustomObject]@{
    ChunkId = 1
    SourcePath = $src
    DestinationPath = $dst
    EstimatedSize = 1000
    EstimatedFiles = 5
    RobocopyArgs = @()
}

$logPath = "$logDir\test.log"

Write-Host "Starting robocopy job..."
$job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -RobocopyOptions @{ NoMirror = $true; RetryCount = 0; RetryWait = 0 }

# Poll progress every 100ms
for ($i = 0; $i -lt 50; $i++) {
    Start-Sleep -Milliseconds 100
    $progress = Get-RobocopyProgress -Job $job

    if ($job.Process.HasExited) {
        Write-Host "Process exited after $i iterations"
        break
    }

    if ($progress.BytesCopied -gt 0 -or $progress.FilesCopied -gt 0) {
        Write-Host "Progress at iteration $i BytesCopied=$($progress.BytesCopied), FilesCopied=$($progress.FilesCopied), CurrentFile=$($progress.CurrentFile)"
    }
}

Write-Host ""
Write-Host "=== Final Progress ==="
$finalProgress = Get-RobocopyProgress -Job $job
Write-Host "BytesCopied: $($finalProgress.BytesCopied)"
Write-Host "FilesCopied: $($finalProgress.FilesCopied)"
Write-Host "CurrentFile: $($finalProgress.CurrentFile)"
Write-Host "LineCount: $($finalProgress.LineCount)"

Write-Host ""
Write-Host "=== Raw Buffer Lines (first 20) ==="
$lines = $job.ProgressBuffer.GetAllLines()
Write-Host "Total lines captured: $($lines.Count)"
$lines | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }

# Cleanup
Remove-Item -Path $src -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $dst -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $logDir -Recurse -Force -ErrorAction SilentlyContinue
