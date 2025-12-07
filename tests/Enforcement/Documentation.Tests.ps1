#Requires -Modules Pester

<#
.SYNOPSIS
    Enforcement test for function documentation consistency
.DESCRIPTION
    Ensures all public functions have consistent comment-based help documentation:
    - All functions must have .SYNOPSIS
    - Complex functions (3+ parameters) must have .DESCRIPTION
    - No placeholder documentation (empty synopses, "TODO document", etc.)
    - All mandatory parameters must be documented with .PARAMETER

    Pattern enforcement:
    - Uses AST's GetHelpContent() method for reliable parsing
    - Validates documentation quality and completeness
    - Enforces documentation standards across the codebase
#>

BeforeDiscovery {
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SourcePath = Join-Path $script:ProjectRoot "src\Robocurse\Public"
    $script:SourceFiles = Get-ChildItem -Path $script:SourcePath -Filter "*.ps1" -Recurse
}

Describe "Documentation Coverage Enforcement" {

    Context "All functions have SYNOPSIS" {
        It "Every function in <_.Name> has .SYNOPSIS" -ForEach $script:SourceFiles {
            $file = $_.FullName
            $fileName = $_.Name

            # Parse the file
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file,
                [ref]$null,
                [ref]$null
            )

            # Find all function definitions
            $functions = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)

            $violations = @()

            foreach ($func in $functions) {
                $funcName = $func.Name
                $helpContent = $func.GetHelpContent()

                # Check if synopsis exists and is not empty
                if (-not $helpContent -or -not $helpContent.Synopsis -or [string]::IsNullOrWhiteSpace($helpContent.Synopsis)) {
                    $line = $func.Extent.StartLineNumber
                    $violations += "${fileName}:${line}: Function '$funcName' is missing .SYNOPSIS"
                }
            }

            if ($violations.Count -gt 0) {
                $message = "Found $($violations.Count) missing .SYNOPSIS violation(s):`n" + ($violations -join "`n")
                $message | Should -BeNullOrEmpty
            }
        }
    }

    Context "Complex functions have DESCRIPTION" {
        It "Functions with 3+ parameters in <_.Name> have .DESCRIPTION" -ForEach $script:SourceFiles {
            $file = $_.FullName
            $fileName = $_.Name

            # Parse the file
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file,
                [ref]$null,
                [ref]$null
            )

            # Find all function definitions
            $functions = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)

            $violations = @()

            foreach ($func in $functions) {
                $funcName = $func.Name
                $paramCount = 0

                # Count parameters
                if ($func.Body.ParamBlock -and $func.Body.ParamBlock.Parameters) {
                    $paramCount = $func.Body.ParamBlock.Parameters.Count
                }

                # If function has 3+ parameters, it should have a description
                if ($paramCount -ge 3) {
                    $helpContent = $func.GetHelpContent()

                    if (-not $helpContent -or -not $helpContent.Description -or [string]::IsNullOrWhiteSpace($helpContent.Description)) {
                        $line = $func.Extent.StartLineNumber
                        $violations += "${fileName}:${line}: Function '$funcName' has $paramCount parameters but is missing .DESCRIPTION"
                    }
                }
            }

            if ($violations.Count -gt 0) {
                $message = "Found $($violations.Count) missing .DESCRIPTION violation(s):`n" + ($violations -join "`n")
                $message | Should -BeNullOrEmpty
            }
        }
    }

    Context "Documentation quality checks" {
        It "No placeholder documentation in <_.Name>" -ForEach $script:SourceFiles {
            $file = $_.FullName
            $fileName = $_.Name

            # Parse the file
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file,
                [ref]$null,
                [ref]$null
            )

            # Find all function definitions
            $functions = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)

            $violations = @()

            # Placeholder patterns to check for
            $placeholderPatterns = @(
                'TODO',
                'FIXME',
                'TBD',
                'Not implemented',
                'Coming soon'
            )

            foreach ($func in $functions) {
                $funcName = $func.Name
                $helpContent = $func.GetHelpContent()

                if ($helpContent -and $helpContent.Synopsis) {
                    $synopsis = $helpContent.Synopsis

                    # Check for placeholder text
                    foreach ($pattern in $placeholderPatterns) {
                        if ($synopsis -match $pattern) {
                            $line = $func.Extent.StartLineNumber
                            $violations += "${fileName}:${line}: Function '$funcName' has placeholder text in .SYNOPSIS: '$pattern'"
                        }
                    }

                    # Check for very short synopses (less than 10 characters, likely incomplete)
                    if ($synopsis.Trim().Length -lt 10) {
                        $line = $func.Extent.StartLineNumber
                        $violations += "${fileName}:${line}: Function '$funcName' has suspiciously short .SYNOPSIS (less than 10 characters)"
                    }
                }
            }

            if ($violations.Count -gt 0) {
                $message = "Found $($violations.Count) placeholder documentation violation(s):`n" + ($violations -join "`n")
                $message | Should -BeNullOrEmpty
            }
        }
    }

    Context "Parameter documentation" {
        It "Mandatory parameters in <_.Name> are documented" -ForEach $script:SourceFiles {
            $file = $_.FullName
            $fileName = $_.Name

            # Parse the file
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file,
                [ref]$null,
                [ref]$null
            )

            # Find all function definitions
            $functions = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)

            $violations = @()

            foreach ($func in $functions) {
                $funcName = $func.Name
                $helpContent = $func.GetHelpContent()

                # Skip if no help content at all (will be caught by SYNOPSIS check)
                if (-not $helpContent) {
                    continue
                }

                # Get mandatory parameters
                if ($func.Body.ParamBlock -and $func.Body.ParamBlock.Parameters) {
                    foreach ($param in $func.Body.ParamBlock.Parameters) {
                        $paramName = $param.Name.VariablePath.UserPath
                        $isMandatory = $false

                        # Check if parameter is mandatory
                        if ($param.Attributes) {
                            foreach ($attr in $param.Attributes) {
                                if ($attr.TypeName.Name -eq 'Parameter') {
                                    # Check for Mandatory = $true
                                    foreach ($namedArg in $attr.NamedArguments) {
                                        if ($namedArg.ArgumentName -eq 'Mandatory' -and $namedArg.Argument.SafeGetValue() -eq $true) {
                                            $isMandatory = $true
                                            break
                                        }
                                    }
                                }
                            }
                        }

                        # If mandatory, check if documented
                        if ($isMandatory) {
                            $isDocumented = $false

                            if ($helpContent.Parameters) {
                                # Parameters is a hashtable of parameter names to descriptions
                                foreach ($key in $helpContent.Parameters.Keys) {
                                    if ($key -eq $paramName) {
                                        $paramDoc = $helpContent.Parameters[$key]
                                        if (-not [string]::IsNullOrWhiteSpace($paramDoc)) {
                                            $isDocumented = $true
                                            break
                                        }
                                    }
                                }
                            }

                            if (-not $isDocumented) {
                                $line = $param.Extent.StartLineNumber
                                $violations += "${fileName}:${line}: Mandatory parameter '$paramName' in function '$funcName' is not documented with .PARAMETER"
                            }
                        }
                    }
                }
            }

            if ($violations.Count -gt 0) {
                $message = "Found $($violations.Count) missing .PARAMETER violation(s):`n" + ($violations -join "`n")
                $message | Should -BeNullOrEmpty
            }
        }
    }
}
