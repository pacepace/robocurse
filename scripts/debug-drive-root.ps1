# Debug what robocopy outputs for a drive root
$testPath = 'D:\'
$nullDest = Join-Path $env:TEMP 'robocurse-test-null'

Write-Host "=== Running robocopy on DRIVE ROOT: $testPath ===" -ForegroundColor Cyan
Write-Host "Command: robocopy `"$testPath`" `"$nullDest`" /L /E /NJH /NJS /BYTES /R:0 /W:0 /NODCOPY"
Write-Host ""

# Run robocopy with the same flags as Invoke-RobocopyList
$output = & robocopy $testPath $nullDest /L /E /NJH /NJS /BYTES /R:0 /W:0 /NODCOPY 2>&1

Write-Host "=== Total lines returned: $($output.Count) ===" -ForegroundColor Yellow
Write-Host ""

Write-Host "=== First 30 non-empty lines (with character codes for debugging) ===" -ForegroundColor Yellow
$count = 0
foreach ($line in $output) {
    if (-not [string]::IsNullOrWhiteSpace($line)) {
        $count++
        # Show the line and its character codes for the first few chars
        $firstChars = $line.Substring(0, [Math]::Min(60, $line.Length))
        Write-Host "Line $count : [$firstChars]"

        # Test regex matches
        if ($line -match 'New Dir\s+\d+\s+(.+)$') {
            Write-Host "  -> NEW DIR match: $($matches[1])" -ForegroundColor Green
        }
        elseif ($line -match 'New File\s+(\d+)\s+(.+)$') {
            Write-Host "  -> NEW FILE match: size=$($matches[1]) file=$($matches[2])" -ForegroundColor Green
        }
        elseif ($line -match '^\s+(\d+)\s+(.+)$') {
            Write-Host "  -> FALLBACK match: size=$($matches[1]) path=$($matches[2])" -ForegroundColor Green
        }
        else {
            Write-Host "  -> NO MATCH" -ForegroundColor Red
        }

        if ($count -ge 30) { break }
    }
}

Write-Host ""
Write-Host "=== Robocopy exit code: $LASTEXITCODE ===" -ForegroundColor Yellow
