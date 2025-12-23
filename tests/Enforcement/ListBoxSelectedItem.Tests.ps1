# ListBox SelectedItem Usage Enforcement Tests
# Prevents bugs where SelectedItem (an object) is compared as a string

Describe "ListBox SelectedItem Usage" {
    BeforeAll {
        $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:GuiFiles = Get-ChildItem -Path (Join-Path $script:ProjectRoot "src\Robocurse\Public") -Filter "Gui*.ps1"
    }

    Context "SelectedItem not used in string comparisons" {
        It "Does not compare SelectedItem directly with -eq in Where-Object" {
            $violations = @()

            foreach ($file in $script:GuiFiles) {
                $content = Get-Content $file.FullName -Raw

                # Pattern: assigns SelectedItem to variable, then uses that variable in Where-Object comparison
                # Bad: $selected = $x.SelectedItem; ... Where-Object { $_.Name -eq $selected }
                # Good: $selected = $x.SelectedItem; ... Where-Object { $_.Name -eq $selected.Name }

                # Find variable assignments from SelectedItem
                $assignments = [regex]::Matches($content, '\$(\w+)\s*=\s*\$\w+\.(?:Controls\.)?lst\w+\.SelectedItem')

                foreach ($assignment in $assignments) {
                    $varName = $assignment.Groups[1].Value

                    # Check if this variable is used in a Where-Object comparison without .Name
                    # Bad pattern: $_.Name -eq $varName (without .Name on $varName)
                    # Also bad: $_.SomeProperty -eq $varName
                    $badPattern = "Where-Object\s*\{[^}]*\`$_\.\w+\s*-eq\s*\`$$varName\s*[^.]"

                    if ($content -match $badPattern) {
                        $violations += "$($file.Name): Variable '$varName' from SelectedItem used in string comparison without .Name accessor"
                    }
                }
            }

            $violations | Should -BeNullOrEmpty -Because "SelectedItem returns an object, not a string - use .Name or .PropertyName for comparisons"
        }

        It "Profile lookup from SelectedItem uses object directly or accesses .Name" {
            $violations = @()

            foreach ($file in $script:GuiFiles) {
                $content = Get-Content $file.FullName -Raw

                # Find patterns where SelectedItem is assigned then used in Config.SyncProfiles lookup
                # This is the exact bug pattern we hit
                $pattern = 'lstProfiles\.SelectedItem[\s\S]{0,500}SyncProfiles\s*\|\s*Where-Object\s*\{[^}]*-eq\s*\$selected\w*\s*\}'

                $matches = [regex]::Matches($content, $pattern)
                foreach ($match in $matches) {
                    # Check if it properly uses .Name
                    if ($match.Value -notmatch '-eq\s*\$\w+\.Name') {
                        $violations += "$($file.Name): SyncProfiles lookup uses SelectedItem without .Name accessor"
                    }
                }
            }

            $violations | Should -BeNullOrEmpty -Because "lstProfiles.SelectedItem is an object - lookup should use .Name property"
        }
    }

    Context "Consistent SelectedItem handling patterns" {
        It "All lstProfiles.SelectedItem usages follow same pattern as btnValidateProfile" {
            # The Validate button works correctly - it passes $selectedProfile directly to the dialog
            # All other handlers using lstProfiles.SelectedItem should do the same

            $guiMainContent = Get-Content (Join-Path $script:ProjectRoot "src\Robocurse\Public\GuiMain.ps1") -Raw

            # Find all handlers that use lstProfiles.SelectedItem
            $handlerBlocks = [regex]::Matches($guiMainContent, 'Add_Click\(\{[\s\S]*?lstProfiles\.SelectedItem[\s\S]*?\}\s*\)\s*\}')

            foreach ($handler in $handlerBlocks) {
                $block = $handler.Value

                # If it accesses SyncProfiles with Where-Object, it should use .Name
                if ($block -match 'SyncProfiles.*Where-Object') {
                    $block | Should -Match '\$\w+\.Name' -Because "SyncProfiles lookup should use .Name property of SelectedItem"
                }
            }
        }
    }

    Context "No redundant profile lookups" {
        It "Does not re-lookup profile when SelectedItem is already the profile object" {
            $guiMainContent = Get-Content (Join-Path $script:ProjectRoot "src\Robocurse\Public\GuiMain.ps1") -Raw

            # Pattern: assigning SelectedItem then immediately looking it up in SyncProfiles
            # This is redundant because SelectedItem IS the profile object
            $redundantPattern = 'lstProfiles\.SelectedItem[\s\S]{0,200}Config\.SyncProfiles\s*\|\s*Where-Object'

            $guiMainContent | Should -Not -Match $redundantPattern -Because "lstProfiles.SelectedItem is already the profile object - no need to look it up again"
        }
    }
}
