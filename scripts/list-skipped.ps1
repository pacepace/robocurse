$result = Invoke-Pester -Path 'C:\Users\pace\pub\dev-wsl\vscode\robocurse\tests' -PassThru -Output None
Write-Host "=== SKIPPED TESTS ($($result.SkippedCount) total) ==="
foreach ($test in $result.Skipped) {
    Write-Host "- $($test.Path -join ' > ')"
}
