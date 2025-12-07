#Requires -Modules Pester

<#
.SYNOPSIS
    Enforcement test for Write-RobocurseLog parameter style consistency
.DESCRIPTION
    Ensures all Write-RobocurseLog calls follow consistent style:
    - Level parameter uses quoted strings (e.g., 'Debug' not Debug)
    - Component parameter is explicitly specified

    Pattern enforcement:
    - CORRECT: Write-RobocurseLog -Message "text" -Level 'Debug' -Component 'ComponentName'
    - INCORRECT: Write-RobocurseLog "text" -Level Debug (bareword)
    - INCORRECT: Write-RobocurseLog -Message "text" -Level 'Debug' (missing -Component)

    Known exceptions:
    - Logging.ps1 is excluded (it defines the function)
#>

BeforeDiscovery {
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SourcePath = Join-Path $script:ProjectRoot "src\Robocurse\Public"
    $script:SourceFiles = Get-ChildItem -Path $script:SourcePath -Filter "*.ps1" -Recurse |
        Where-Object { $_.Name -ne 'Logging.ps1' }  # Exclude the logging module itself
}

Describe "Logging Style Enforcement" {

    Context "Level parameter uses quoted strings" {
        It "Should use quoted -Level in <_.Name>" -ForEach $script:SourceFiles {
            $file = $_.FullName
            $fileName = $_.Name

            # Read file content
            $content = Get-Content -Path $file -Raw

            # Pattern for bareword -Level: -Level followed by Debug|Info|Warning|Error|Critical without quotes
            # This matches: -Level Debug, -Level Info, etc.
            # But NOT: -Level 'Debug', -Level "Debug", -Level $variable
            $barewordPattern = '-Level\s+(Debug|Info|Warning|Error|Critical)\b'

            $violations = @()

            if ($content -match $barewordPattern) {
                $lines = Get-Content -Path $file
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match $barewordPattern -and $lines[$i] -match 'Write-RobocurseLog') {
                        $lineNum = $i + 1
                        $violations += "${fileName}:${lineNum}: Bareword -Level parameter found. Use quoted string instead (e.g., -Level 'Debug')"
                    }
                }
            }

            if ($violations.Count -gt 0) {
                $message = "Found $($violations.Count) bareword -Level violation(s):`n" + ($violations -join "`n")
                $message | Should -BeNullOrEmpty
            }
        }
    }

    Context "Component parameter is explicit" {
        It "Should include -Component in <_.Name>" -ForEach $script:SourceFiles {
            $file = $_.FullName
            $fileName = $_.Name

            # Read file content
            $content = Get-Content -Path $file -Raw

            $violations = @()

            # Find all Write-RobocurseLog calls
            $lines = Get-Content -Path $file
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]

                # Skip comments
                if ($line -match '^\s*#') {
                    continue
                }

                # Check if line contains Write-RobocurseLog
                if ($line -match 'Write-RobocurseLog') {
                    # Check if this line or continuation has -Component
                    # We need to handle multi-line calls
                    $hasComponent = $false
                    $currentLine = $i

                    # Look ahead up to 5 lines for multi-line statements
                    for ($j = $i; $j -lt [Math]::Min($i + 5, $lines.Count); $j++) {
                        if ($lines[$j] -match '-Component') {
                            $hasComponent = $true
                            break
                        }
                        # Stop if we hit a new statement (ends with closing paren or is a new command)
                        if ($j -gt $i -and $lines[$j] -match '^\s*[a-zA-Z]' -and $lines[$j] -notmatch '^\s*-') {
                            break
                        }
                    }

                    if (-not $hasComponent) {
                        $lineNum = $i + 1
                        $violations += "${fileName}:${lineNum}: Write-RobocurseLog missing -Component parameter"
                    }
                }
            }

            if ($violations.Count -gt 0) {
                $message = "Found $($violations.Count) missing -Component violation(s):`n" + ($violations -join "`n")
                $message | Should -BeNullOrEmpty
            }
        }
    }
}
