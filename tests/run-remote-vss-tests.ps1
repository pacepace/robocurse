# Run Remote VSS Integration Tests
# This script sets up the environment and runs the remote VSS tests against localhost

$ErrorActionPreference = 'Continue'

Write-Host "Setting up Remote VSS test environment..." -ForegroundColor Cyan

# Set the environment variable to use localhost admin share
$env:ROBOCURSE_TEST_REMOTE_SHARE = "\\localhost\C$\Windows\Temp"
Write-Host "ROBOCURSE_TEST_REMOTE_SHARE = $env:ROBOCURSE_TEST_REMOTE_SHARE" -ForegroundColor Gray

# Run just the VSS integration tests
Write-Host "`nRunning VSS Integration Tests..." -ForegroundColor Cyan
$result = Invoke-Pester -Path "$PSScriptRoot\Integration\VSS.Integration.Tests.ps1" -PassThru -Output Detailed

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Test Summary:" -ForegroundColor Cyan
Write-Host "  Total:   $($result.TotalCount)" -ForegroundColor White
Write-Host "  Passed:  $($result.PassedCount)" -ForegroundColor Green
Write-Host "  Failed:  $($result.FailedCount)" -ForegroundColor $(if ($result.FailedCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Skipped: $($result.SkippedCount)" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan

# Return exit code
exit $result.FailedCount
