$result = Invoke-Pester -Path 'C:\Users\pace\pub\dev-wsl\vscode\robocurse\tests' -PassThru -Output None
Write-Host "=== SUMMARY ==="
Write-Host "Passed: $($result.PassedCount)"
Write-Host "Failed: $($result.FailedCount)"
Write-Host "Skipped: $($result.SkippedCount)"
if ($result.Failed.Count -gt 0) {
    Write-Host ""
    Write-Host "=== FAILED TESTS ==="
    foreach ($t in $result.Failed) {
        Write-Host "- $($t.Path -join ' > ')"
        Write-Host "  Error: $($t.ErrorRecord.Exception.Message)"
    }
}
