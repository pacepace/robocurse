# Diagnostic script - run this WHILE the GUI is running a copy
# It will check the shared state and active job buffers

param(
    [string]$ModulePath = "C:\Users\pace\pub\dev-wsl\vscode\robocurse\src\Robocurse\Robocurse.psm1"
)

Write-Host "=== Progress Diagnostics ===" -ForegroundColor Cyan
Write-Host "This script checks the OrchestrationState while GUI is running"
Write-Host ""

# Load module
Import-Module $ModulePath -Force

# Check if orchestration state exists
if (-not $script:OrchestrationState) {
    Write-Host "[ERROR] No OrchestrationState found - is the GUI running?" -ForegroundColor Red
    Write-Host "Note: This script must share the same PowerShell session as the GUI"
    exit 1
}

$state = $script:OrchestrationState

Write-Host "Phase: $($state.Phase)"
Write-Host "TotalChunks: $($state.TotalChunks)"
Write-Host "CompletedCount: $($state.CompletedCount)"
Write-Host "BytesComplete: $($state.BytesComplete)"
Write-Host "ActiveJobs.Count: $($state.ActiveJobs.Count)"
Write-Host ""

if ($state.ActiveJobs.Count -eq 0) {
    Write-Host "[INFO] No active jobs - try again while copy is in progress" -ForegroundColor Yellow
    exit 0
}

Write-Host "=== Active Jobs ===" -ForegroundColor Cyan
foreach ($kvp in $state.ActiveJobs.ToArray()) {
    $job = $kvp.Value
    $pid = $kvp.Key

    Write-Host ""
    Write-Host "Job PID: $pid"
    Write-Host "  Chunk: $($job.Chunk.SourcePath)"
    Write-Host "  EstimatedSize: $($job.Chunk.EstimatedSize)"

    if ($job.ProgressBuffer) {
        $buffer = $job.ProgressBuffer
        Write-Host "  ProgressBuffer exists: YES"
        Write-Host "  LineCount: $($buffer.LineCount)"

        $lines = $buffer.GetAllLines()
        Write-Host "  GetAllLines() count: $($lines.Count)"

        if ($lines.Count -gt 0) {
            Write-Host "  Sample lines (first 10):" -ForegroundColor Green
            $lines | Select-Object -First 10 | ForEach-Object {
                Write-Host "    $_"
            }

            # Check for "New File" lines
            $newFileLines = $lines | Where-Object { $_ -match '^\s*(New File|Newer|Older|Changed)\s+(\d+)' }
            Write-Host ""
            Write-Host "  'New File' pattern matches: $($newFileLines.Count)" -ForegroundColor Yellow
            $newFileLines | Select-Object -First 5 | ForEach-Object {
                Write-Host "    MATCH: $_" -ForegroundColor Green
            }
        }
        else {
            Write-Host "  [WARNING] Buffer is empty!" -ForegroundColor Red
        }

        # Try Get-RobocopyProgress
        try {
            $progress = Get-RobocopyProgress -Job $job
            Write-Host ""
            Write-Host "  Get-RobocopyProgress result:"
            Write-Host "    BytesCopied: $($progress.BytesCopied)"
            Write-Host "    FilesCopied: $($progress.FilesCopied)"
            Write-Host "    CurrentFile: $($progress.CurrentFile)"
        }
        catch {
            Write-Host "  [ERROR] Get-RobocopyProgress failed: $_" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  [ERROR] No ProgressBuffer on job!" -ForegroundColor Red
    }
}
