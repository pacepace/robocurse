$content = Get-Content 'C:\Users\pace\pub\dev-wsl\vscode\robocurse\src\Robocurse\Public\GuiProgress.ps1' -Raw
$content = $content -replace '"', '"'
$content = $content -replace '"', '"'
$content = $content -replace ''', "'"
$content = $content -replace ''', "'"
Set-Content 'C:\Users\pace\pub\dev-wsl\vscode\robocurse\src\Robocurse\Public\GuiProgress.ps1' -Value $content -NoNewline
Write-Host "Fixed smart quotes in GuiProgress.ps1"
