$src = Join-Path $env:TEMP 'rc_test_src2'
$dst = Join-Path $env:TEMP 'rc_test_dst2'
New-Item -ItemType Directory -Path $src -Force | Out-Null
New-Item -ItemType Directory -Path $dst -Force | Out-Null

# Create a 5MB file to see progress percentages
Write-Host "Creating 5MB test file..."
$bytes = [byte[]]::new(5*1024*1024)
[IO.File]::WriteAllBytes("$src\bigfile.bin", $bytes)

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = "robocopy"
$psi.Arguments = "`"$src`" `"$dst`" /E /BYTES /NDL"
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true

$p = [System.Diagnostics.Process]::new()
$p.StartInfo = $psi
$p.EnableRaisingEvents = $true

$lines = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$handler = { param($s, $e); if ($e.Data) { $lines.Enqueue($e.Data) } }
Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action $handler | Out-Null

$p.Start() | Out-Null
$p.BeginOutputReadLine()
$p.WaitForExit()

# Wait for pending events to complete
Start-Sleep -Milliseconds 500

Write-Host "=== Lines received during copy ==="
$arr = $lines.ToArray()
Write-Host "Total lines: $($arr.Count)"
$i = 0
foreach ($line in $arr) {
    $i++
    Write-Host "[$i] Length=$($line.Length): $line"
    # Show hex dump of first 100 chars
    if ($line.Length -gt 0) {
        $hex = ($line.Substring(0, [Math]::Min(100, $line.Length)).ToCharArray() | ForEach-Object { '{0:X2}' -f [int]$_ }) -join ' '
        Write-Host "    HEX: $hex"
    }
}

Remove-Item -Path $src -Recurse -Force
Remove-Item -Path $dst -Recurse -Force
