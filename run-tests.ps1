cd 'C:\Users\pace\pub\dev-wsl\vscode\robocurse'
$r = Invoke-Pester -Path tests -PassThru -Output None
'Total: ' + $r.TotalCount + ', Passed: ' + $r.PassedCount + ', Failed: ' + $r.FailedCount + ', Skipped: ' + $r.SkippedCount | Out-File -FilePath $env:TEMP\pester-summary.txt -Encoding utf8

# Write failed test details
$failures = @()
foreach ($f in $r.Failed) {
    $failures += 'TEST: ' + $f.ExpandedName
    $failures += 'ERROR: ' + $f.ErrorRecord.Exception.Message
    $failures += '---'
}
$failures -join [Environment]::NewLine | Out-File -FilePath $env:TEMP\pester-failures.txt -Encoding utf8

Get-Content $env:TEMP\pester-summary.txt
