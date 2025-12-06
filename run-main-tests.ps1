cd 'C:\Users\pace\pub\dev-wsl\vscode\robocurse'
$r = Invoke-Pester -Path 'tests\Integration\Main.Tests.ps1' -PassThru -Output Detailed
Write-Host ""
Write-Host "=============================================="
Write-Host "Total: $($r.TotalCount), Passed: $($r.PassedCount), Failed: $($r.FailedCount)"
