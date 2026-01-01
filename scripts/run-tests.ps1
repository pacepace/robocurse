# Run all Pester tests with output to temp files to avoid truncation issues
# Results are written to $env:TEMP\pester-summary.txt and $env:TEMP\pester-failures.txt

$result = Invoke-Pester -Path 'C:\Users\pace\pub\dev-wsl\vscode\robocurse\tests' -PassThru -Output None

# Write summary to temp file
$summary = "Total: $($result.TotalCount), Passed: $($result.PassedCount), Failed: $($result.FailedCount), Skipped: $($result.SkippedCount)"
$summary | Out-File -FilePath "$env:TEMP\pester-summary.txt" -Encoding utf8

# Write failed test details to temp file
$failures = @()
foreach ($f in $result.Failed) {
    $failures += "TEST: $($f.ExpandedName)"
    $failures += "ERROR: $($f.ErrorRecord.Exception.Message)"
    $failures += "---"
}
if ($failures.Count -gt 0) {
    $failures -join [Environment]::NewLine | Out-File -FilePath "$env:TEMP\pester-failures.txt" -Encoding utf8
} else {
    "" | Out-File -FilePath "$env:TEMP\pester-failures.txt" -Encoding utf8
}

# Also output summary to console
Write-Host ""
Write-Host "=== SUMMARY ==="
Write-Host $summary
Write-Host ""
Write-Host "Results written to:"
Write-Host "  $env:TEMP\pester-summary.txt"
Write-Host "  $env:TEMP\pester-failures.txt"

# Set exit code based on Pester results, not robocopy exit codes
exit $(if ($result.FailedCount -gt 0) { 1 } else { 0 })
