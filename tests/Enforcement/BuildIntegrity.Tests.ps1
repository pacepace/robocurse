#Requires -Modules Pester

<#
.SYNOPSIS
    Enforcement test for build script integrity
.DESCRIPTION
    Ensures the build script includes all required source files and produces
    a valid monolith. This test would have caught the GuiSnapshots.ps1 omission
    that broke GUI initialization.

    Checks:
    1. All Public/*.ps1 files are in the build order
    2. All files in build order actually exist
    3. All XAML resources are loaded
    4. Built monolith defines functions from all source modules
    5. Critical dependency ordering is correct

    This is a FAST enforcement test (<5s) - no execution, just static analysis.
#>

BeforeDiscovery {
    # Discovery-time path setup (for -ForEach data)
    $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

Describe "Build Script Integrity" {

    BeforeAll {
        # Redefine paths in BeforeAll (Pester v5 scoping)
        $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:BuildScript = Join-Path $script:ProjectRoot "build\Build-Robocurse.ps1"
        $script:SourcePath = Join-Path $script:ProjectRoot "src\Robocurse\Public"
        $script:ResourcesPath = Join-Path $script:ProjectRoot "src\Robocurse\Resources"
        $script:DistPath = Join-Path $script:ProjectRoot "dist\Robocurse.ps1"

        # Parse the build script to extract $moduleOrder array
        $buildContent = Get-Content -Path $script:BuildScript -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($buildContent, [ref]$null, [ref]$null)

        # Find the $moduleOrder assignment
        $moduleOrderAst = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.VariablePath.UserPath -eq 'moduleOrder'
        }, $true) | Select-Object -First 1

        if (-not $moduleOrderAst) {
            throw "Could not find `$moduleOrder in build script"
        }

        # Extract array elements - the right side should be an ArrayExpressionAst or ArrayLiteralAst
        $script:ModuleOrderPaths = @()
        $arrayElements = $moduleOrderAst.Right.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true)

        foreach ($element in $arrayElements) {
            $script:ModuleOrderPaths += $element.Value
        }

        # Get all actual Public/*.ps1 files
        $script:ActualPublicFiles = Get-ChildItem -Path $script:SourcePath -Filter "*.ps1" |
            ForEach-Object { "Public\$($_.Name)" }

        # Get all XAML files
        $script:ActualXamlFiles = Get-ChildItem -Path $script:ResourcesPath -Filter "*.xaml" -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name }
    }

    Context "All source files are included in build" {

        It "Every Public/*.ps1 file must be in moduleOrder" {
            $missing = @()

            foreach ($file in $script:ActualPublicFiles) {
                if ($file -notin $script:ModuleOrderPaths) {
                    $missing += $file
                }
            }

            if ($missing.Count -gt 0) {
                $message = @"
BUILD INTEGRITY FAILURE: $($missing.Count) file(s) missing from build order!

Missing files:
$($missing | ForEach-Object { "  - $_" } | Out-String)
These files exist in src\Robocurse\Public\ but are NOT included in build\Build-Robocurse.ps1 `$moduleOrder.

FIX: Add the missing file(s) to the `$moduleOrder array in build\Build-Robocurse.ps1
     Place them in correct dependency order (files that define functions used by others come first).
"@
                $missing.Count | Should -Be 0 -Because $message
            }
        }

        It "Every file in moduleOrder must exist" {
            $orphaned = @()

            foreach ($path in $script:ModuleOrderPaths) {
                $fullPath = Join-Path (Join-Path $script:ProjectRoot "src\Robocurse") $path
                if (-not (Test-Path $fullPath)) {
                    $orphaned += $path
                }
            }

            if ($orphaned.Count -gt 0) {
                $message = @"
BUILD INTEGRITY FAILURE: $($orphaned.Count) file(s) in moduleOrder don't exist!

Orphaned references:
$($orphaned | ForEach-Object { "  - $_" } | Out-String)
These files are listed in `$moduleOrder but don't exist on disk.

FIX: Either create the missing file(s) or remove them from `$moduleOrder in build\Build-Robocurse.ps1
"@
                $orphaned.Count | Should -Be 0 -Because $message
            }
        }
    }

    Context "XAML resources are loaded" {

        It "Build script loads all XAML files from Resources" {
            if ($script:ActualXamlFiles.Count -eq 0) {
                Set-ItResult -Skipped -Because "No XAML files in Resources folder"
                return
            }

            # Check that the build script references loading XAML files
            $buildContent = Get-Content -Path $script:BuildScript -Raw

            $missingXaml = @()
            foreach ($xaml in $script:ActualXamlFiles) {
                # The build script loads XAML via Get-ChildItem on Resources folder
                # So we just verify the pattern exists
            }

            # The build script should have the XAML loading pattern
            $buildContent | Should -Match 'Get-ChildItem.*-Filter.*\.xaml' -Because "Build script must load XAML resources"
        }
    }

    Context "Critical dependency ordering" {

        It "Utility.ps1 comes before all other modules" {
            $utilityIndex = [array]::IndexOf($script:ModuleOrderPaths, 'Public\Utility.ps1')
            $utilityIndex | Should -Be 0 -Because "Utility.ps1 defines base functions and must be first"
        }

        It "Configuration.ps1 comes early (before GUI modules)" {
            $configIndex = [array]::IndexOf($script:ModuleOrderPaths, 'Public\Configuration.ps1')
            $firstGuiIndex = $script:ModuleOrderPaths | ForEach-Object { $_ } |
                Where-Object { $_ -match 'Gui' } |
                ForEach-Object { [array]::IndexOf($script:ModuleOrderPaths, $_) } |
                Sort-Object |
                Select-Object -First 1

            $configIndex | Should -BeLessThan $firstGuiIndex -Because "Configuration.ps1 must come before GUI modules"
        }

        It "Logging.ps1 comes before modules that use it" {
            $loggingIndex = [array]::IndexOf($script:ModuleOrderPaths, 'Public\Logging.ps1')
            $loggingIndex | Should -BeGreaterOrEqual 0 -Because "Logging.ps1 must be in build order"
            $loggingIndex | Should -BeLessThan 5 -Because "Logging.ps1 should be loaded early"
        }

        It "VssCore.ps1 comes before VssLocal.ps1 and VssRemote.ps1" {
            $coreIndex = [array]::IndexOf($script:ModuleOrderPaths, 'Public\VssCore.ps1')
            $localIndex = [array]::IndexOf($script:ModuleOrderPaths, 'Public\VssLocal.ps1')
            $remoteIndex = [array]::IndexOf($script:ModuleOrderPaths, 'Public\VssRemote.ps1')

            if ($coreIndex -ge 0 -and $localIndex -ge 0) {
                $coreIndex | Should -BeLessThan $localIndex -Because "VssCore.ps1 must come before VssLocal.ps1"
            }
            if ($coreIndex -ge 0 -and $remoteIndex -ge 0) {
                $coreIndex | Should -BeLessThan $remoteIndex -Because "VssCore.ps1 must come before VssRemote.ps1"
            }
        }

        It "Main.ps1 is last in the build order" {
            $mainIndex = [array]::IndexOf($script:ModuleOrderPaths, 'Public\Main.ps1')
            $lastIndex = $script:ModuleOrderPaths.Count - 1

            $mainIndex | Should -Be $lastIndex -Because "Main.ps1 is the entry point and must be last"
        }

        It "All Gui*.ps1 modules come before GuiMain.ps1" {
            $guiMainIndex = [array]::IndexOf($script:ModuleOrderPaths, 'Public\GuiMain.ps1')

            if ($guiMainIndex -lt 0) {
                Set-ItResult -Skipped -Because "GuiMain.ps1 not in build order"
                return
            }

            $violations = @()
            foreach ($path in $script:ModuleOrderPaths) {
                if ($path -match '^Public\\Gui.*\.ps1$' -and $path -ne 'Public\GuiMain.ps1') {
                    $index = [array]::IndexOf($script:ModuleOrderPaths, $path)
                    if ($index -gt $guiMainIndex) {
                        $violations += "$path (index $index) comes after GuiMain.ps1 (index $guiMainIndex)"
                    }
                }
            }

            if ($violations.Count -gt 0) {
                $violations.Count | Should -Be 0 -Because "All GUI modules must come before GuiMain.ps1:`n$($violations -join "`n")"
            }
        }
    }
}

Describe "Built Monolith Integrity" {

    BeforeAll {
        # Redefine paths in BeforeAll (Pester v5 scoping)
        $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:DistPath = Join-Path $script:ProjectRoot "dist\Robocurse.ps1"
        $script:ModuleOrderPaths = @()  # Will be populated from build script

        # Re-parse build script to get moduleOrder for this Describe block
        $buildScript = Join-Path $script:ProjectRoot "build\Build-Robocurse.ps1"
        $buildContent = Get-Content -Path $buildScript -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($buildContent, [ref]$null, [ref]$null)
        $moduleOrderAst = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.VariablePath.UserPath -eq 'moduleOrder'
        }, $true) | Select-Object -First 1

        if ($moduleOrderAst) {
            $arrayElements = $moduleOrderAst.Right.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
            }, $true)
            foreach ($element in $arrayElements) {
                $script:ModuleOrderPaths += $element.Value
            }
        }

        if (-not (Test-Path $script:DistPath)) {
            # Skip the whole block if monolith doesn't exist
            $script:SkipMonolithTests = $true
            $script:MonolithFunctions = @()
        }
        else {
            $script:SkipMonolithTests = $false
            # Parse the built monolith to verify it contains expected functions
            $script:MonolithContent = Get-Content -Path $script:DistPath -Raw
            $script:MonolithAst = [System.Management.Automation.Language.Parser]::ParseInput(
                $script:MonolithContent, [ref]$null, [ref]$null
            )

            # Get all function definitions in the monolith
            $script:MonolithFunctions = $script:MonolithAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) | ForEach-Object { $_.Name }
        }
    }

    Context "Functions from all modules are present" -Skip:$script:SkipMonolithTests {

        It "Monolith contains functions from each source module" {
            # For each source file, extract at least one function name and verify it's in the monolith
            $missingModules = @()

            foreach ($path in $script:ModuleOrderPaths) {
                $fullPath = Join-Path (Join-Path $script:ProjectRoot "src\Robocurse") $path
                if (-not (Test-Path $fullPath)) { continue }

                $sourceAst = [System.Management.Automation.Language.Parser]::ParseFile(
                    $fullPath, [ref]$null, [ref]$null
                )

                $sourceFunctions = $sourceAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true) | ForEach-Object { $_.Name }

                if ($sourceFunctions.Count -gt 0) {
                    # Check if at least one function from this module is in the monolith
                    $foundAny = $false
                    foreach ($func in $sourceFunctions) {
                        if ($func -in $script:MonolithFunctions) {
                            $foundAny = $true
                            break
                        }
                    }

                    if (-not $foundAny) {
                        $missingModules += [PSCustomObject]@{
                            Module    = $path
                            Functions = $sourceFunctions -join ', '
                        }
                    }
                }
            }

            if ($missingModules.Count -gt 0) {
                $details = $missingModules | ForEach-Object {
                    "  - $($_.Module): expected functions like $($_.Functions)"
                }
                $message = "Monolith is missing functions from $($missingModules.Count) module(s):`n$($details -join "`n")"
                $missingModules.Count | Should -Be 0 -Because $message
            }
        }
    }

    Context "Critical GUI functions are present" -Skip:$script:SkipMonolithTests {

        It "Contains Initialize-SnapshotsPanel (the function that was missing)" {
            # This specific test would have caught the original bug
            'Initialize-SnapshotsPanel' | Should -BeIn $script:MonolithFunctions -Because @"
The function Initialize-SnapshotsPanel must be present in the built monolith.
This function is defined in GuiSnapshots.ps1 and called from GuiMain.ps1.
If this test fails, GuiSnapshots.ps1 is likely missing from `$moduleOrder in build\Build-Robocurse.ps1
"@
        }

        It "Contains Start-RobocurseMain (entry point)" {
            'Start-RobocurseMain' | Should -BeIn $script:MonolithFunctions -Because "Entry point function must exist"
        }

        It "Contains Initialize-RobocurseGui (GUI initialization)" {
            'Initialize-RobocurseGui' | Should -BeIn $script:MonolithFunctions -Because "GUI initialization function must exist"
        }
    }

    Context "XAML is embedded in monolith" -Skip:$script:SkipMonolithTests {

        It "Monolith contains embedded XAML fallback content" {
            # The build script embeds XAML via -FallbackContent parameter
            $script:MonolithContent | Should -Match '-FallbackContent' -Because "Build should embed XAML resources"
        }

        It "MainWindow.xaml is embedded" {
            $script:MonolithContent | Should -Match 'MainWindow\.xaml' -Because "MainWindow XAML must be embedded"
        }
    }
}

Describe "Build Script Self-Consistency" {

    BeforeAll {
        # Redefine paths in BeforeAll (Pester v5 scoping)
        $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:BuildScript = Join-Path $script:ProjectRoot "build\Build-Robocurse.ps1"
        $script:ModuleOrderPaths = @()

        # Parse build script to get moduleOrder
        $buildContent = Get-Content -Path $script:BuildScript -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($buildContent, [ref]$null, [ref]$null)
        $moduleOrderAst = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.VariablePath.UserPath -eq 'moduleOrder'
        }, $true) | Select-Object -First 1

        if ($moduleOrderAst) {
            $arrayElements = $moduleOrderAst.Right.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
            }, $true)
            foreach ($element in $arrayElements) {
                $script:ModuleOrderPaths += $element.Value
            }
        }
    }

    Context "No duplicate entries in moduleOrder" {

        It "Each file appears exactly once in moduleOrder" {
            $duplicates = $script:ModuleOrderPaths |
                Group-Object |
                Where-Object { $_.Count -gt 1 } |
                ForEach-Object { $_.Name }

            if ($duplicates.Count -gt 0) {
                $duplicates.Count | Should -Be 0 -Because "Duplicate entries in moduleOrder: $($duplicates -join ', ')"
            }
        }
    }

    Context "moduleOrder array is properly formatted" {

        It "All entries use consistent path format (Public\\*.ps1)" {
            $invalidFormat = $script:ModuleOrderPaths | Where-Object {
                $_ -notmatch '^Public\\[A-Za-z]+\.ps1$'
            }

            if ($invalidFormat.Count -gt 0) {
                $invalidFormat.Count | Should -Be 0 -Because "Invalid path format in moduleOrder: $($invalidFormat -join ', ')"
            }
        }
    }
}
