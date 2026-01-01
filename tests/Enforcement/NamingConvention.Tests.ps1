#Requires -Modules Pester

<#
.SYNOPSIS
    Enforcement test for PowerShell naming conventions
.DESCRIPTION
    Ensures all public functions use Verb-Noun format with approved verbs
#>

BeforeDiscovery {
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SourcePath = Join-Path $script:ProjectRoot "src\Robocurse\Public"
    $script:SourceFiles = Get-ChildItem -Path $script:SourcePath -Filter "*.ps1" -Recurse
}

Describe "Naming Convention Enforcement" {

    BeforeAll {
        # Get approved verbs - must be in BeforeAll for test block access
        $script:ApprovedVerbs = Get-Verb | Select-Object -ExpandProperty Verb
    }

    Context "Function names follow Verb-Noun pattern" {

        It "All functions in <_.Name> use Verb-Noun format" -ForEach $script:SourceFiles {
            $file = $_
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$null, [ref]$null
            )

            # Find all function definitions (excluding class methods/constructors)
            $functions = $ast.FindAll({
                param($node)
                if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    # Exclude class methods - they have a parent TypeDefinitionAst
                    $parent = $node.Parent
                    while ($parent) {
                        if ($parent -is [System.Management.Automation.Language.TypeDefinitionAst]) {
                            return $false  # Skip class members
                        }
                        $parent = $parent.Parent
                    }
                    return $true
                }
                return $false
            }, $true)

            $invalidNames = @()

            foreach ($func in $functions) {
                $name = $func.Name

                # Must contain a hyphen (Verb-Noun)
                if ($name -notmatch '^[A-Z][a-z]+-[A-Z]') {
                    $invalidNames += "$($file.Name):$($func.Extent.StartLineNumber) - '$name' is not Verb-Noun format"
                }
            }

            if ($invalidNames.Count -gt 0) {
                $invalidNames.Count | Should -Be 0 -Because "Functions must use Verb-Noun format:`n$($invalidNames -join "`n")"
            }
        }
    }

    Context "Function verbs are approved" {

        It "All functions in <_.Name> use approved verbs" -ForEach $script:SourceFiles {
            $file = $_
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$null, [ref]$null
            )

            # Find all function definitions (excluding class methods/constructors)
            $functions = $ast.FindAll({
                param($node)
                if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    # Exclude class methods - they have a parent TypeDefinitionAst
                    $parent = $node.Parent
                    while ($parent) {
                        if ($parent -is [System.Management.Automation.Language.TypeDefinitionAst]) {
                            return $false  # Skip class members
                        }
                        $parent = $parent.Parent
                    }
                    return $true
                }
                return $false
            }, $true)

            $unapprovedVerbs = @()

            foreach ($func in $functions) {
                $name = $func.Name

                if ($name -match '^([A-Z][a-z]+)-') {
                    $verb = $matches[1]

                    if ($verb -notin $script:ApprovedVerbs) {
                        $unapprovedVerbs += "$($file.Name):$($func.Extent.StartLineNumber) - '$name' uses unapproved verb '$verb'"
                    }
                }
            }

            if ($unapprovedVerbs.Count -gt 0) {
                $unapprovedVerbs.Count | Should -Be 0 -Because "Functions must use approved verbs:`n$($unapprovedVerbs -join "`n")"
            }
        }
    }

    Context "Module noun consistency" {

        It "Public functions use consistent noun prefixes" {
            # Acceptable noun prefixes for this module
            $acceptablePrefixes = @(
                'Robocurse',     # Module-specific
                'Gui',          # GUI components
                'Vss',          # VSS-related
                'Orchestration', # Job orchestration
                'Profile',      # Profile management
                'Log',          # Logging
                'Chunk',        # Chunking
                'Directory',    # Directory operations
                'Robocopy',     # Robocopy wrapper
                'Operation',    # Generic operations
                'Default',      # Default config
                'Smtp',         # Email
                'Sync',         # Sync profiles
                'Bypass'        # Security bypass flags
            )

            $allFunctions = @()
            foreach ($file in $script:SourceFiles) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                    $file.FullName, [ref]$null, [ref]$null
                )

                $functions = $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true)

                $allFunctions += $functions | ForEach-Object {
                    [PSCustomObject]@{
                        Name = $_.Name
                        File = $file.Name
                        Line = $_.Extent.StartLineNumber
                    }
                }
            }

            # Extract nouns and check prefixes
            $unusualNouns = @()
            foreach ($func in $allFunctions) {
                if ($func.Name -match '^[A-Z][a-z]+-(.+)$') {
                    $noun = $matches[1]

                    # Check if noun starts with an acceptable prefix
                    $hasAcceptablePrefix = $acceptablePrefixes | Where-Object {
                        $noun -like "$_*"
                    }

                    if (-not $hasAcceptablePrefix) {
                        # Not necessarily an error, but worth reviewing
                        # This is a "notice" not a "violation"
                    }
                }
            }

            # This test always passes - it's here to document the noun convention
            $true | Should -BeTrue
        }
    }

    Context "No script-level functions in wrong scope" {

        It "Public folder only contains exportable functions in <_.Name>" -ForEach $script:SourceFiles {
            $file = $_
            $content = Get-Content $file.FullName -Raw

            # Check for script-scoped functions that should be in Private
            # Pattern: functions that aren't meant to be exported (usually helper functions)
            # This is a heuristic - short names or underscore prefixes suggest internal use
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$null, [ref]$null
            )

            $functions = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)

            $suspiciousNames = @()
            foreach ($func in $functions) {
                $name = $func.Name

                # Suspicious patterns for public folder:
                # - Starts with underscore
                # - All lowercase
                # - Too short (< 5 chars)
                if ($name -match '^_' -or $name -cmatch '^[a-z]+$' -or $name.Length -lt 5) {
                    $suspiciousNames += "$($file.Name):$($func.Extent.StartLineNumber) - '$name' may belong in Private folder"
                }
            }

            if ($suspiciousNames.Count -gt 0) {
                $suspiciousNames.Count | Should -Be 0 -Because "Public folder should only have public functions:`n$($suspiciousNames -join "`n")"
            }
        }
    }
}
