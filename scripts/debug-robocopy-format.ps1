# Debug script to see actual robocopy output format
# Run from PowerShell to see what regexes should match

$testPath = 'C:\Windows\Logs'  # A small, readable directory
$nullDest = Join-Path $env:TEMP 'robocurse-test-null'

Write-Host "=== Running robocopy with: /L /E /NJH /NJS /BYTES /R:0 /W:0 /NODCOPY ===" -ForegroundColor Cyan
Write-Host "Source: $testPath"
Write-Host ""

# Run robocopy with the same flags as Invoke-RobocopyList
$output = & robocopy $testPath $nullDest /L /E /NJH /NJS /BYTES /R:0 /W:0 /NODCOPY 2>&1

Write-Host "=== First 20 non-empty lines ===" -ForegroundColor Yellow
$count = 0
foreach ($line in $output) {
    if (-not [string]::IsNullOrWhiteSpace($line)) {
        $count++
        Write-Host "Line $count : [$line]"
        if ($count -ge 20) { break }
    }
}

Write-Host ""
Write-Host "=== Test regex matches ===" -ForegroundColor Yellow
$matchCount = 0
foreach ($line in $output | Select-Object -First 30) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $matchCount++

    if ($line -match 'New File\s+(\d+)\s+(.+)$') {
        Write-Host "[$matchCount] NEW FILE match: size=$($matches[1]) path=$($matches[2])" -ForegroundColor Green
    }
    elseif ($line -match 'New Dir\s+\d+\s+(.+)$') {
        Write-Host "[$matchCount] NEW DIR match: path=$($matches[1])" -ForegroundColor Green
    }
    elseif ($line -match '^\s+(\d+)\s+(.+)$') {
        Write-Host "[$matchCount] FALLBACK match: size=$($matches[1]) path=$($matches[2])" -ForegroundColor Green
    }
    else {
        Write-Host "[$matchCount] NO MATCH: [$line]" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Total output lines: $($output.Count)"
