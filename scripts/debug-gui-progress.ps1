# Debug script to test GUI-like progress polling
$ErrorActionPreference = 'Stop'

# Load the module
. "$PSScriptRoot\..\dist\Robocurse.ps1"

# Create test directories
$testRoot = Join-Path $env:TEMP "robocurse-gui-debug"
$src = Join-Path $testRoot "source"
$dst = Join-Path $testRoot "dest"
$logDir = Join-Path $testRoot "logs"

Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $src -Force | Out-Null
New-Item -ItemType Directory -Path $dst -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

# Create 10 x 50MB files (500MB total)
Write-Host "Creating test files..."
$fileSize = 50MB
$fileCount = 10
for ($i = 1; $i -le $fileCount; $i++) {
    $bytes = [byte[]]::new($fileSize)
    (New-Object Random).NextBytes($bytes)
    [IO.File]::WriteAllBytes("$src\file$i.bin", $bytes)
    Write-Host "  Created file$i.bin ($($fileSize / 1MB) MB)"
}

$totalSize = $fileSize * $fileCount
Write-Host "`nTotal size: $($totalSize / 1MB) MB"

# Initialize log session (required by orchestration)
Initialize-LogSession -LogRoot $logDir

# Initialize orchestration state (like GUI does)
Initialize-OrchestrationState
$state = $script:OrchestrationState
$state.Phase = 'Preparing'

Write-Host "`n=== Simulating GUI flow ==="

# Create a simple profile
$profile = [PSCustomObject]@{
    Name = "DebugProfile"
    Source = $src
    Destination = $dst
    Enabled = $true
}

# Initialize robocopy
Test-RobocopyAvailable | Out-Null

# Create chunk
$chunk = [PSCustomObject]@{
    ChunkId = 1
    SourcePath = $src
    DestinationPath = $dst
    EstimatedSize = $totalSize
    EstimatedFiles = $fileCount
    Depth = 0
    IsFilesOnly = $false
    Status = 'Pending'
    RetryCount = 0
    RetryAfter = $null
    LastExitCode = $null
    LastErrorMessage = $null
    RobocopyArgs = @()
}

# Set up state like Start-ProfileReplication does
$state.TotalChunks = 1
$state.TotalBytes = $totalSize
$state.CompletedCount = 0
$state.BytesComplete = 0
$state.Phase = "Replicating"
$state.ChunkQueue.Enqueue($chunk)

Write-Host "TotalBytes set to: $($state.TotalBytes)"
Write-Host "Phase: $($state.Phase)"
Write-Host "ChunkQueue count: $($state.ChunkQueue.Count)"

# Start the job via Invoke-ReplicationTick (like background thread does)
Write-Host "`nStarting replication tick loop..."

$startTime = [DateTime]::Now
$pollCount = 0

while ($state.Phase -notin @('Complete', 'Stopped', 'Idle')) {
    $pollCount++

    # Call Invoke-ReplicationTick (this is what background thread does)
    Invoke-ReplicationTick -MaxConcurrentJobs 1

    # Read status (this is what GUI does)
    $status = Get-OrchestrationStatus

    # Calculate percentage
    $pct = if ($state.TotalBytes -gt 0) {
        [math]::Round(($state.BytesComplete / $state.TotalBytes) * 100, 1)
    } else { 0 }

    $activeCount = $state.ActiveJobs.Count
    $completedCount = $state.CompletedCount

    Write-Host ("Poll {0,3}: Phase={1,-12} Active={2} Completed={3} BytesComplete={4,12} TotalBytes={5,12} Progress={6,5}%" -f `
        $pollCount, $state.Phase, $activeCount, $completedCount, $state.BytesComplete, $state.TotalBytes, $pct)

    Start-Sleep -Milliseconds 250

    # Safety timeout after 60 seconds
    if (([DateTime]::Now - $startTime).TotalSeconds -gt 60) {
        Write-Host "Timeout!"
        break
    }
}

Write-Host "`n=== Final Status ==="
Write-Host "Phase: $($state.Phase)"
Write-Host "BytesComplete: $($state.BytesComplete)"
Write-Host "TotalBytes: $($state.TotalBytes)"
Write-Host "CompletedCount: $($state.CompletedCount)"
Write-Host "CompletedChunkBytes: $($state.CompletedChunkBytes)"

# Cleanup
Write-Host "`nCleaning up..."
Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Done."
