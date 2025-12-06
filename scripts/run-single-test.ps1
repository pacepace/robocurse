$result = Invoke-Pester -Path 'C:\Users\pace\pub\dev-wsl\vscode\robocurse\tests\Unit\Chunking.Tests.ps1' -PassThru -Output Detailed
Write-Host "`n=== RESULTS ==="
Write-Host "Passed: $($result.PassedCount)"
Write-Host "Failed: $($result.FailedCount)"
