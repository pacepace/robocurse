# Task: Documentation Pattern Enforcement

## Objective
Create an enforcement test that ensures all public functions have consistent comment-based help documentation including `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.OUTPUTS`, and `.EXAMPLE` blocks.

## Problem Statement
PowerShell comment-based help is critical for:
- `Get-Help` functionality
- IDE intellisense
- Code discoverability
- Onboarding new developers

Current state: Most functions have documentation, but coverage varies. Some functions may be missing required sections.

## Success Criteria
1. Enforcement test verifies every `function Verb-Noun` has a comment block
2. Test checks for required sections: `.SYNOPSIS`, `.DESCRIPTION`
3. Test checks for recommended sections: `.PARAMETER` (if params exist), `.OUTPUTS`, `.EXAMPLE`
4. Test provides file:line locations for violations
5. Test runs in under 5 seconds
6. 100% coverage of public functions

## Research: Documentation Pattern

### Standard Pattern (from Configuration.ps1)
```powershell
function Format-Json {
    <#
    .SYNOPSIS
        Formats JSON with proper 2-space indentation
    .DESCRIPTION
        PowerShell's ConvertTo-Json produces ugly formatting with 4-space indentation
        and inconsistent spacing. This function reformats JSON to use 2-space indentation
        and consistent property spacing.
    .PARAMETER Json
        The JSON string to format
    .PARAMETER Indent
        Number of spaces per indentation level (default 2)
    .OUTPUTS
        Properly formatted JSON string
    .EXAMPLE
        $obj | ConvertTo-Json -Depth 10 | Format-Json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Json,
        ...
    )
}
```

### Required Sections
1. `.SYNOPSIS` - One-line description (REQUIRED)
2. `.DESCRIPTION` - Detailed explanation (REQUIRED for complex functions)

### Recommended Sections
3. `.PARAMETER` - For each parameter with non-obvious purpose
4. `.OUTPUTS` - What the function returns
5. `.EXAMPLE` - At least one usage example

### Current Stats
- Total functions: ~191
- Functions with .SYNOPSIS: ~198 (count from grep)
- This suggests good coverage but verification needed

## Implementation Plan

### Step 1: Create Enforcement Test
Create `tests/Enforcement/Documentation.Tests.ps1`:

```powershell
#Requires -Modules Pester

<#
.SYNOPSIS
    Enforcement test for function documentation coverage
.DESCRIPTION
    Ensures all public functions have comment-based help with required sections
#>

BeforeDiscovery {
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SourcePath = Join-Path $script:ProjectRoot "src\Robocurse\Public"
    $script:SourceFiles = Get-ChildItem -Path $script:SourcePath -Filter "*.ps1" -Recurse
}

Describe "Documentation Coverage Enforcement" {

    Context "All functions have SYNOPSIS" {

        It "Every function in <_.Name> has .SYNOPSIS" -ForEach $script:SourceFiles {
            $file = $_
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$null, [ref]$null
            )

            # Find all function definitions
            $functions = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)

            $missingDocs = @()

            foreach ($func in $functions) {
                # Check for comment-based help
                $helpContent = $func.GetHelpContent()

                if (-not $helpContent) {
                    $missingDocs += "$($file.Name):$($func.Extent.StartLineNumber) - $($func.Name) has no comment help"
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($helpContent.Synopsis)) {
                    $missingDocs += "$($file.Name):$($func.Extent.StartLineNumber) - $($func.Name) missing .SYNOPSIS"
                }
            }

            if ($missingDocs.Count -gt 0) {
                $missingDocs.Count | Should -Be 0 -Because "All functions need .SYNOPSIS:`n$($missingDocs -join "`n")"
            }
        }
    }

    Context "Complex functions have DESCRIPTION" {

        It "Functions with 3+ parameters in <_.Name> have .DESCRIPTION" -ForEach $script:SourceFiles {
            $file = $_
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$null, [ref]$null
            )

            $functions = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)

            $missingDesc = @()

            foreach ($func in $functions) {
                # Only check functions with 3+ parameters (complex functions)
                $paramCount = 0
                if ($func.Body.ParamBlock) {
                    $paramCount = $func.Body.ParamBlock.Parameters.Count
                }

                if ($paramCount -ge 3) {
                    $helpContent = $func.GetHelpContent()

                    if (-not $helpContent -or [string]::IsNullOrWhiteSpace($helpContent.Description)) {
                        $missingDesc += "$($file.Name):$($func.Extent.StartLineNumber) - $($func.Name) ($paramCount params) missing .DESCRIPTION"
                    }
                }
            }

            if ($missingDesc.Count -gt 0) {
                $missingDesc.Count | Should -Be 0 -Because "Complex functions need .DESCRIPTION:`n$($missingDesc -join "`n")"
            }
        }
    }

    Context "Documentation quality checks" {

        It "No placeholder documentation in <_.Name>" -ForEach $script:SourceFiles {
            $file = $_
            $content = Get-Content $file.FullName -Raw

            # Check for common placeholder patterns
            $placeholders = @(
                'TODO:?\s*document',
                'FIXME:?\s*add\s+doc',
                '\.SYNOPSIS\s*\n\s*\n',  # Empty synopsis
                '\.DESCRIPTION\s*\n\s*\n'  # Empty description
            )

            foreach ($pattern in $placeholders) {
                $content | Should -Not -Match $pattern -Because "No placeholder documentation allowed"
            }
        }
    }

    Context "Parameter documentation" {

        It "Mandatory parameters in <_.Name> are documented" -ForEach $script:SourceFiles {
            $file = $_
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$null, [ref]$null
            )

            $functions = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)

            $undocumentedParams = @()

            foreach ($func in $functions) {
                if (-not $func.Body.ParamBlock) { continue }

                $helpContent = $func.GetHelpContent()
                if (-not $helpContent) { continue }

                foreach ($param in $func.Body.ParamBlock.Parameters) {
                    # Check if parameter is mandatory
                    $isMandatory = $param.Attributes | Where-Object {
                        $_.TypeName.Name -eq 'Parameter' -and
                        $_.NamedArguments | Where-Object { $_.ArgumentName -eq 'Mandatory' }
                    }

                    if ($isMandatory) {
                        $paramName = $param.Name.VariablePath.UserPath
                        $hasParamDoc = $helpContent.Parameters.Keys -contains $paramName

                        if (-not $hasParamDoc) {
                            $undocumentedParams += "$($file.Name):$($func.Extent.StartLineNumber) - $($func.Name).$paramName (mandatory)"
                        }
                    }
                }
            }

            if ($undocumentedParams.Count -gt 0) {
                $undocumentedParams.Count | Should -Be 0 -Because "Mandatory parameters need .PARAMETER docs:`n$($undocumentedParams -join "`n")"
            }
        }
    }
}
```

### Step 2: Run Initial Assessment

```powershell
# See current violations
Invoke-Pester -Path tests\Enforcement\Documentation.Tests.ps1 -Output Detailed
```

### Step 3: Fix Violations

For each violation, add the missing documentation section:

**Missing SYNOPSIS:**
```powershell
function Some-Function {
    <#
    .SYNOPSIS
        Brief description of what this function does
    #>
    ...
}
```

**Missing DESCRIPTION (for complex functions):**
```powershell
function Complex-Function {
    <#
    .SYNOPSIS
        Brief description
    .DESCRIPTION
        Detailed explanation of behavior, side effects,
        error conditions, and usage context.
    #>
    ...
}
```

## Test Plan

```powershell
# Run documentation enforcement
Invoke-Pester -Path tests\Enforcement\Documentation.Tests.ps1 -Output Detailed

# Check Get-Help works for all public functions
Get-Command -Module Robocurse | ForEach-Object {
    $help = Get-Help $_.Name -ErrorAction SilentlyContinue
    if (-not $help.Synopsis -or $help.Synopsis -eq $_.Name) {
        Write-Warning "Missing help for: $($_.Name)"
    }
}
```

## Files to Modify
1. `tests/Enforcement/Documentation.Tests.ps1` - New enforcement test
2. Any source files identified with missing documentation

## Verification Commands
```powershell
# Run enforcement test
Invoke-Pester -Path tests\Enforcement\Documentation.Tests.ps1 -Output Detailed

# Verify module loads correctly
Import-Module .\src\Robocurse\Robocurse.psd1 -Force

# Spot check help
Get-Help New-OperationResult -Full
```

## Notes
- PowerShell's `GetHelpContent()` method parses comment-based help from the AST
- `.SYNOPSIS` is the minimum requirement for discoverability
- `.DESCRIPTION` is required for functions with complex behavior
- `.PARAMETER` documentation helps IDE intellisense
- This test catches documentation rot before it spreads
- Estimated time: Test creation ~15 min, fixes ~1-2 hours depending on violations
