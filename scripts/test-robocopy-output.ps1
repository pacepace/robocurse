$src = Join-Path $env:TEMP 'rc_test_src'
$dst = Join-Path $env:TEMP 'rc_test_dst'
New-Item -ItemType Directory -Path $src -Force | Out-Null
New-Item -ItemType Directory -Path $dst -Force | Out-Null
'test content for file 1' | Out-File "$src\test1.txt"
'test content for file 2' | Out-File "$src\test2.txt"
Write-Host '=== Robocopy stdout output (with /BYTES /NDL, no /NFL) ==='
robocopy $src $dst /E /BYTES /NDL 2>&1 | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host '=== Checking for New File pattern ==='
$output = robocopy $src $dst /E /BYTES /NDL 2>&1
$output | Where-Object { $_ -match 'New File|Newer|Older|Changed' } | ForEach-Object { Write-Host "MATCHED: $_" }
Remove-Item -Path $src -Recurse -Force
Remove-Item -Path $dst -Recurse -Force
