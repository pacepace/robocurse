$content = Get-Content 'C:\Users\pace\pub\dev-wsl\vscode\robocurse\src\Robocurse\Public\GuiProgress.ps1' -Raw
# Replace left and right double quotes with straight double quote
$content = $content -replace [char]0x201C, [char]0x0022
$content = $content -replace [char]0x201D, [char]0x0022
# Replace left and right single quotes with straight single quote
$content = $content -replace [char]0x2018, [char]0x0027
$content = $content -replace [char]0x2019, [char]0x0027
Set-Content 'C:\Users\pace\pub\dev-wsl\vscode\robocurse\src\Robocurse\Public\GuiProgress.ps1' -Value $content -NoNewline
Write-Host "Fixed smart quotes in GuiProgress.ps1"
