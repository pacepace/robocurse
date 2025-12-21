#Requires -Modules Pester

<#
.SYNOPSIS
    Enforcement test for chunk object schema consistency
.DESCRIPTION
    Ensures all properties accessed on chunk objects are defined in New-Chunk.

    This catches bugs where code tries to access/set properties that don't exist
    on PSCustomObject chunks (e.g., setting $chunk.RetryAfter when RetryAfter
    wasn't defined in the chunk creation).

    Pattern enforcement:
    - All properties accessed via $chunk.<property> must exist in New-Chunk definition
    - New properties must be added to both the chunk creation AND this test's known list
#>

BeforeDiscovery {
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SourcePath = Join-Path $script:ProjectRoot "src\Robocurse\Public"
    $script:ChunkingFile = Join-Path $script:SourcePath "Chunking.ps1"
    $script:SourceFiles = Get-ChildItem -Path $script:SourcePath -Filter "*.ps1"
}

Describe "Chunk Schema Enforcement" {

    Context "Chunk property definitions match usage" {

        BeforeAll {
            # Recalculate paths in BeforeAll (Pester 5 doesn't share BeforeDiscovery vars)
            $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $sourcePath = Join-Path $projectRoot "src\Robocurse\Public"
            $chunkingFile = Join-Path $sourcePath "Chunking.ps1"

            # Parse Chunking.ps1 to extract chunk properties from New-Chunk function
            $chunkingContent = Get-Content $chunkingFile -Raw
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $chunkingFile,
                [ref]$null,
                [ref]$null
            )

            # Find the New-Chunk function
            $newChunkFunc = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'New-Chunk'
            }, $true) | Select-Object -First 1

            if (-not $newChunkFunc) {
                throw "New-Chunk function not found in Chunking.ps1"
            }

            # Find the PSCustomObject creation with chunk properties
            $chunkCreation = $newChunkFunc.FindAll({
                param($node)
                # Looking for [PSCustomObject]@{ ... } or variable assignment with hashtable
                if ($node -is [System.Management.Automation.Language.ConvertExpressionAst]) {
                    $typeName = $node.Type.TypeName.Name
                    return $typeName -eq 'PSCustomObject'
                }
                return $false
            }, $true) | Select-Object -First 1

            if (-not $chunkCreation) {
                throw "Chunk PSCustomObject creation not found in New-Chunk"
            }

            # Extract property names from the hashtable
            $hashtable = $chunkCreation.Child
            $script:DefinedProperties = @()

            foreach ($kvp in $hashtable.KeyValuePairs) {
                $keyText = $kvp.Item1.Extent.Text -replace '[''"]', ''
                $script:DefinedProperties += $keyText
            }

            Write-Host "Chunk defined properties: $($script:DefinedProperties -join ', ')"
        }

        It "New-Chunk defines expected core properties" {
            # Core properties that must exist
            $requiredProperties = @(
                'ChunkId',
                'SourcePath',
                'DestinationPath',
                'Status',
                'RetryCount',
                'RetryAfter',
                'LastExitCode',
                'LastErrorMessage',
                'RobocopyArgs'
            )

            foreach ($prop in $requiredProperties) {
                $script:DefinedProperties | Should -Contain $prop -Because "Chunk must have '$prop' property"
            }
        }

        It "All chunk property accesses use defined properties in <_.Name>" -ForEach $script:SourceFiles {
            $file = $_.FullName
            $fileName = $_.Name

            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file,
                [ref]$null,
                [ref]$null
            )

            $violations = @()

            # Find all member accesses where the target looks like a chunk variable
            $memberAccesses = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.MemberExpressionAst]
            }, $true)

            foreach ($access in $memberAccesses) {
                # Check if the variable name suggests it's a chunk
                $varExpr = $access.Expression
                if ($varExpr -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $varName = $varExpr.VariablePath.UserPath.ToLower()

                    # Variable names that indicate chunk objects
                    $chunkVarPatterns = @('chunk', 'c')
                    $isChunkVar = $false

                    foreach ($pattern in $chunkVarPatterns) {
                        if ($varName -eq $pattern -or $varName -match "^${pattern}s?\[" -or $varName -match "${pattern}$") {
                            $isChunkVar = $true
                            break
                        }
                    }

                    if ($isChunkVar) {
                        $memberName = $access.Member.Extent.Text -replace '[''"]', ''

                        # Skip method calls (detected by trailing parenthesis in context)
                        $nextChar = ''
                        $extent = $access.Extent
                        $fullText = (Get-Content $file -Raw)
                        $endPos = $extent.EndOffset
                        if ($endPos -lt $fullText.Length) {
                            $nextChar = $fullText[$endPos]
                        }
                        if ($nextChar -eq '(') {
                            continue  # Skip method calls
                        }

                        # Skip built-in PowerShell object properties
                        $builtInProperties = @('PSObject', 'PSTypeNames', 'GetType', 'ToString', 'GetHashCode', 'Equals')
                        if ($memberName -in $builtInProperties) {
                            continue
                        }

                        # Check if this property is defined
                        if ($memberName -notin $script:DefinedProperties) {
                            $line = $access.Extent.StartLineNumber
                            $violations += "${fileName}:${line}: Access to undefined chunk property '$memberName' via `$${varName}.${memberName}"
                        }
                    }
                }
            }

            if ($violations.Count -gt 0) {
                $message = "Found $($violations.Count) access(es) to undefined chunk properties:`n" + ($violations -join "`n")
                $message | Should -BeNullOrEmpty
            }
        }
    }
}
