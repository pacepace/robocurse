# Quick test to see actual robocopy stdout format
$testDir = Join-Path $env:TEMP "robocopy-stdout-test"
$src = Join-Path $testDir "src"
$dst = Join-Path $testDir "dst"
Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $src -Force | Out-Null
New-Item -ItemType Directory -Path $dst -Force | Out-Null

# Create a small test file
$bytes = [byte[]]::new(1MB)
[IO.File]::WriteAllBytes("$src\testfile.bin", $bytes)

# Run robocopy and capture stdout (no log file)
Write-Host "=== STDOUT OUTPUT ==="
& robocopy $src $dst /E /NDL /NJH /NJS /BYTES 2>&1 | ForEach-Object { "LINE: [$_]" }
Write-Host "=== END ==="

Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
