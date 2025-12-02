$result = Invoke-Pester -Path 'C:\Users\pace\pub\dev-wsl\vscode\robocurse\tests' -PassThru -Output None
Write-Host ""
Write-Host "=== SUMMARY ==="
Write-Host ("Passed: " + $result.PassedCount)
Write-Host ("Failed: " + $result.FailedCount)
Write-Host ("Skipped: " + $result.SkippedCount)
Write-Host ""
Write-Host "=== FAILED TESTS ==="
foreach ($test in $result.Failed) {
    Write-Host ("- " + ($test.Path -join " > "))
    Write-Host ("  ERROR: " + $test.ErrorRecord.Exception.Message.Substring(0, [Math]::Min(200, $test.ErrorRecord.Exception.Message.Length)))
    Write-Host ""
}
