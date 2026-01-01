# Test regex matching against actual robocopy stdout format
$line = "`t    New File  `t`t 1048576`tC:\test\file.bin"
Write-Host "Testing line: [$line]"
Write-Host "Hex dump:" -NoNewline
$line.ToCharArray() | ForEach-Object { Write-Host (" {0:X2}" -f [int]$_) -NoNewline }
Write-Host ""

$pattern = '^\s*(New File|Newer|Older|Changed)\s+(\d+)\s+(.+)$'
Write-Host "Pattern: $pattern"

if ($line -match $pattern) {
    Write-Host "MATCHED!"
    Write-Host "  Full match: $($Matches[0])"
    Write-Host "  Group 1 (type): $($Matches[1])"
    Write-Host "  Group 2 (size): $($Matches[2])"
    Write-Host "  Group 3 (path): $($Matches[3])"
} else {
    Write-Host "NO MATCH"
}
