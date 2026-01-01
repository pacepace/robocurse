# Debug by mimicking Pester's module loading pattern
$ErrorActionPreference = 'Continue'

# Mimic TestHelper's Initialize-RobocurseForTesting
$modulePath = 'C:\Users\pace\pub\dev-wsl\vscode\robocurse\src\Robocurse\Robocurse.psm1'
Import-Module $modulePath -Force -Global -DisableNameChecking

Write-Host "Module loaded"

# Ensure robocopy is available (this is what the first test context does)
$result = Test-RobocopyAvailable
Write-Host "Robocopy available: $($result.Success)"

# Now create test dirs and try the first test scenario
$testDir = Join-Path $env:TEMP 'robocurse_pester_debug'
$sourceDir = Join-Path $testDir 'source'
$destDir = Join-Path $testDir 'dest'
$logDir = Join-Path $testDir 'logs'

Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $sourceDir, $destDir, $logDir -ItemType Directory -Force | Out-Null

# Create test files like Pester would
1..3 | ForEach-Object {
    "Test content $_" | Out-File (Join-Path $sourceDir "file$_.txt")
}

Write-Host "`n=== First call to Start-RobocopyJob ==="
$chunk = [PSCustomObject]@{
    SourcePath = $sourceDir
    DestinationPath = $destDir
}
$logPath = Join-Path $logDir 'test1.log'

$job1 = $null
try {
    $job1 = Start-RobocopyJob -Chunk $chunk -LogPath $logPath -ThreadsPerJob 4 -ErrorAction Stop
} catch {
    Write-Host "EXCEPTION on first call: $_"
    Write-Host $_.ScriptStackTrace
}

if ($null -eq $job1) {
    Write-Host "FIRST CALL: Job is NULL"
    # Check $Error for any non-terminating errors
    if ($Error.Count -gt 0) {
        Write-Host "Recent errors:"
        $Error[0..2] | ForEach-Object { Write-Host "  - $_" }
    }
} else {
    Write-Host "FIRST CALL: Job returned successfully, PID=$($job1.Process.Id)"
    # Wait and cleanup
    $job1.Process.WaitForExit(5000) | Out-Null
}

Write-Host "`n=== Second call to Start-RobocopyJob ==="
$logPath2 = Join-Path $logDir 'test2.log'
Remove-Item $destDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item $destDir -ItemType Directory -Force | Out-Null

$job2 = $null
try {
    $job2 = Start-RobocopyJob -Chunk $chunk -LogPath $logPath2 -ThreadsPerJob 4 -ErrorAction Stop
} catch {
    Write-Host "EXCEPTION on second call: $_"
}

if ($null -eq $job2) {
    Write-Host "SECOND CALL: Job is NULL"
} else {
    Write-Host "SECOND CALL: Job returned successfully, PID=$($job2.Process.Id)"
    $job2.Process.WaitForExit(5000) | Out-Null
}

# Cleanup
Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
