# Debug why Start-RobocopyJob returns null on first call
$ErrorActionPreference = 'Continue'
Import-Module 'C:\Users\pace\pub\dev-wsl\vscode\robocurse\src\Robocurse\Robocurse.psm1' -Force

# Ensure robocopy is available
Write-Host "Testing robocopy availability..."
$roboResult = Test-RobocopyAvailable
Write-Host "Robocopy available: $($roboResult.Success)"

# Create test dirs
$testDir = Join-Path $env:TEMP 'robocurse_debug_test'
$sourceDir = Join-Path $testDir 'source'
$destDir = Join-Path $testDir 'dest'
$logDir = Join-Path $testDir 'logs'
Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $sourceDir, $destDir, $logDir -ItemType Directory -Force | Out-Null

# Create a test file
'test content' | Out-File (Join-Path $sourceDir 'test.txt')

# Try to start a job
Write-Host "`nCalling Start-RobocopyJob..."
try {
    $chunk = [PSCustomObject]@{
        SourcePath = $sourceDir
        DestinationPath = $destDir
    }
    $logPath = Join-Path $logDir 'test.log'
    $job = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -ThreadsPerJob 4 -ErrorAction Stop

    if ($null -eq $job) {
        Write-Host "ERROR: Job is null!"
    } else {
        Write-Host "SUCCESS: Job returned"
        Write-Host "  Process ID: $($job.Process.Id)"
        Write-Host "  ProgressBuffer: $($job.ProgressBuffer)"
    }
} catch {
    Write-Host "EXCEPTION: $_"
    Write-Host "Stack trace: $($_.ScriptStackTrace)"
}

# Cleanup
Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
