$testLines = @(
    "	    New File  		      52	C:\Users\pace\AppData\Local\Temp\rc_test_src\test1.txt"
    "100%  "
    "	    New File  		      52	C:\Users\pace\AppData\Local\Temp\rc_test_src\test2.txt"
)

$pattern = '^\s*(New File|Newer|Older|Changed)\s+(\d+)\s+(.+)$'

foreach ($line in $testLines) {
    Write-Host "Testing: '$line'"
    Write-Host "  Hex: $(($line.ToCharArray() | ForEach-Object { [int]$_ }) -join ',')"
    if ($line -match $pattern) {
        Write-Host "  MATCHED! Size=$($Matches[2]), Path=$($Matches[3])"
    } else {
        Write-Host "  NO MATCH"
    }
    Write-Host ""
}
