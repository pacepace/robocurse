#Requires -Modules Pester

<#
.SYNOPSIS
    Enforcement test for OperationResult pattern consistency
.DESCRIPTION
    Ensures all functions returning success/failure results use the standardized
    New-OperationResult function instead of raw hashtables with Success key.

    Pattern enforcement:
    - CORRECT: return New-OperationResult -Success $true -Data $result
    - INCORRECT: return @{ Success = $true; Data = $result }

    Known exceptions:
    - Remote script blocks (Invoke-Command -ScriptBlock) cannot use module functions
    - These must use raw hashtables but should use consistent property names (ErrorMessage not Error)
#>

BeforeDiscovery {
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SourcePath = Join-Path $script:ProjectRoot "src\Robocurse\Public"
    $script:SourceFiles = Get-ChildItem -Path $script:SourcePath -Filter "*.ps1" -Recurse
}

Describe "OperationResult Pattern Enforcement" {

    Context "No raw hashtable Success returns" {
        It "Should not use raw @{ Success = } hashtables in <_.Name>" -ForEach $script:SourceFiles {
            $file = $_.FullName
            $fileName = $_.Name

            # Parse the file
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file,
                [ref]$null,
                [ref]$null
            )

            # Find all hashtable literals that contain a Success key in return statements
            $violations = @()

            # Find all return statements
            $returnStatements = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.ReturnStatementAst]
            }, $true)

            foreach ($returnStmt in $returnStatements) {
                # Check if this return statement is inside an Invoke-Command ScriptBlock parameter
                $parent = $returnStmt.Parent
                $isInsideRemoteBlock = $false

                while ($parent) {
                    # Check if we're in a ScriptBlock that's a parameter to Invoke-Command
                    if ($parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                        $scriptBlockParent = $parent.Parent

                        # Check if parent is a CommandParameterAst or part of a command that calls Invoke-Command
                        if ($scriptBlockParent -is [System.Management.Automation.Language.CommandAst]) {
                            $commandName = $scriptBlockParent.GetCommandName()
                            if ($commandName -eq 'Invoke-Command') {
                                $isInsideRemoteBlock = $true
                                break
                            }
                        }
                    }
                    $parent = $parent.Parent
                }

                # Skip if inside a remote script block (known exception)
                if ($isInsideRemoteBlock) {
                    continue
                }

                # Find hashtable literals in this return statement
                $hashtables = $returnStmt.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.HashtableAst]
                }, $false)

                foreach ($hashtable in $hashtables) {
                    # Skip if this hashtable is inside a [PSCustomObject] cast
                    # [PSCustomObject]@{ Success = ... } is a valid pattern for structured returns
                    $hashtableParent = $hashtable.Parent
                    $isInsidePSCustomObject = $false
                    if ($hashtableParent -is [System.Management.Automation.Language.ConvertExpressionAst]) {
                        $typeName = $hashtableParent.Type.TypeName.Name
                        if ($typeName -eq 'PSCustomObject') {
                            $isInsidePSCustomObject = $true
                        }
                    }

                    if ($isInsidePSCustomObject) {
                        continue
                    }

                    # Check if this hashtable has a Success key
                    $hasSuccessKey = $false
                    foreach ($kvp in $hashtable.KeyValuePairs) {
                        $keyText = $kvp.Item1.Extent.Text -replace '[''"]', ''
                        if ($keyText -eq 'Success') {
                            $hasSuccessKey = $true
                            break
                        }
                    }

                    if ($hasSuccessKey) {
                        $line = $hashtable.Extent.StartLineNumber
                        $violations += "${fileName}:${line}: Raw hashtable with Success key found in return statement. Use New-OperationResult instead."
                    }
                }
            }

            if ($violations.Count -gt 0) {
                $message = "Found $($violations.Count) violation(s):`n" + ($violations -join "`n")
                $message | Should -BeNullOrEmpty
            }
        }
    }

    Context "Known Exceptions - Remote Script Blocks" {
        It "VssRemote.ps1 remote blocks use consistent ErrorMessage property" {
            $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $sourcePath = Join-Path $projectRoot "src\Robocurse\Public"
            $vssRemoteFile = Join-Path $sourcePath "VssRemote.ps1"

            if (-not (Test-Path $vssRemoteFile)) {
                Set-ItResult -Skipped -Because "VssRemote.ps1 not found"
                return
            }

            $content = Get-Content $vssRemoteFile -Raw

            # Check for old pattern: @{ Success = $false; Error = "..." }
            # Should be: @{ Success = $false; ErrorMessage = "..." }
            $violationPattern = '@\{\s*Success\s*=\s*\$false\s*;\s*Error\s*='

            if ($content -match $violationPattern) {
                $lines = Get-Content $vssRemoteFile
                $violatingLines = @()
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match $violationPattern) {
                        $violatingLines += "Line $($i + 1): $($lines[$i].Trim())"
                    }
                }

                $message = "VssRemote.ps1 remote blocks use 'Error' property instead of 'ErrorMessage':`n" + ($violatingLines -join "`n")
                $message | Should -BeNullOrEmpty
            }
        }

        It "VssRemote.ps1 callers use .ErrorMessage not .Error" {
            $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $sourcePath = Join-Path $projectRoot "src\Robocurse\Public"
            $vssRemoteFile = Join-Path $sourcePath "VssRemote.ps1"

            if (-not (Test-Path $vssRemoteFile)) {
                Set-ItResult -Skipped -Because "VssRemote.ps1 not found"
                return
            }

            $content = Get-Content $vssRemoteFile -Raw

            # Check for callers accessing $result.Error
            # Should be: $result.ErrorMessage
            $violationPattern = '\$result\.Error[^M]'  # ErrorMessage is okay, Error alone is not

            if ($content -match $violationPattern) {
                $lines = Get-Content $vssRemoteFile
                $violatingLines = @()
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '\$result\.Error[^M]') {
                        $violatingLines += "Line $($i + 1): $($lines[$i].Trim())"
                    }
                }

                $message = "VssRemote.ps1 callers use '.Error' instead of '.ErrorMessage':`n" + ($violatingLines -join "`n")
                $message | Should -BeNullOrEmpty
            }
        }
    }
}
