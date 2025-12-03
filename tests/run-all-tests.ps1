# Run All Robocurse Tests
# This script sets up the environment for full test coverage including Remote VSS tests

param(
    [switch]$SkipRemoteVss,
    [string]$RemoteShare = "\\localhost\C$\Windows\Temp"
)

$ErrorActionPreference = 'Continue'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Robocurse Full Test Suite" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Set up Remote VSS testing (unless skipped)
if (-not $SkipRemoteVss) {
    $env:ROBOCURSE_TEST_REMOTE_SHARE = $RemoteShare
    Write-Host "Remote VSS testing enabled: $env:ROBOCURSE_TEST_REMOTE_SHARE" -ForegroundColor Gray
} else {
    $env:ROBOCURSE_TEST_REMOTE_SHARE = $null
    Write-Host "Remote VSS testing: Skipped" -ForegroundColor Yellow
}

# Run all tests
Write-Host "`nRunning tests..." -ForegroundColor Cyan
$result = Invoke-Pester -Path "$PSScriptRoot" -PassThru -Output Detailed

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Test Summary:" -ForegroundColor Cyan
Write-Host "  Total:   $($result.TotalCount)" -ForegroundColor White
Write-Host "  Passed:  $($result.PassedCount)" -ForegroundColor Green
Write-Host "  Failed:  $($result.FailedCount)" -ForegroundColor $(if ($result.FailedCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Skipped: $($result.SkippedCount)" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan

# Return exit code based on failures
exit $result.FailedCount
