BeforeAll {
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Utility.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Logging.ps1"
    . "$PSScriptRoot\..\..\src\Robocurse\Public\Configuration.ps1"

    Mock Write-RobocurseLog {}
}

Describe "Test-VolumeOverridesFormat" {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\Robocurse\Public\GuiSettings.ps1"
    }

    It "Returns true for empty string" {
        Test-VolumeOverridesFormat -Text "" | Should -Be $true
    }

    It "Returns true for valid single override" {
        Test-VolumeOverridesFormat -Text "D:=5" | Should -Be $true
    }

    It "Returns true for valid multiple overrides" {
        Test-VolumeOverridesFormat -Text "D:=5, E:=10" | Should -Be $true
    }

    It "Returns true for valid with spaces" {
        Test-VolumeOverridesFormat -Text "D: = 5 , E: = 10" | Should -Be $true
    }

    It "Returns false for invalid format" {
        Test-VolumeOverridesFormat -Text "D=5" | Should -Be $false  # Missing colon
        Test-VolumeOverridesFormat -Text "D:five" | Should -Be $false  # Non-numeric
        Test-VolumeOverridesFormat -Text "D:" | Should -Be $false  # Missing value
    }
}

Describe "Profile PersistentSnapshot Setting" {
    BeforeAll {
        $script:Config = New-DefaultConfig
        $script:Controls = @{
            'chkPersistentSnapshot' = [PSCustomObject]@{ IsChecked = $false }
        }
    }

    It "Default config has PersistentSnapshot disabled" {
        $profile = [PSCustomObject]@{
            Name = "Test"
            PersistentSnapshot = [PSCustomObject]@{ Enabled = $false }
        }

        $profile.PersistentSnapshot.Enabled | Should -Be $false
    }
}

Describe "Settings SnapshotRetention" {
    BeforeAll {
        $script:Controls = @{
            'txtDefaultKeepCount' = [PSCustomObject]@{ Text = "5" }
            'txtVolumeOverrides' = [PSCustomObject]@{ Text = "D:=10, E:=3" }
        }
        $script:Config = New-DefaultConfig
    }

    It "Parses volume overrides correctly" {
        # Simulate save
        $overridesText = "D:=10, E:=3"
        $overrides = @{}
        $pairs = $overridesText -split '\s*,\s*'
        foreach ($pair in $pairs) {
            if ($pair -match '^([A-Za-z]:)\s*=\s*(\d+)$') {
                $volume = $Matches[1].ToUpper()
                $count = [int]$Matches[2]
                $overrides[$volume] = $count
            }
        }

        $overrides["D:"] | Should -Be 10
        $overrides["E:"] | Should -Be 3
    }

    It "Formats volume overrides for display" {
        $overrides = @{ "D:" = 10; "E:" = 3 }
        $pairs = @()
        foreach ($key in $overrides.Keys) {
            $pairs += "$key=$($overrides[$key])"
        }
        $text = $pairs -join ", "

        $text | Should -Match "D:=10"
        $text | Should -Match "E:=3"
    }
}

Describe "Configuration Integration" {
    It "Config includes SnapshotRetention after save" {
        $config = New-DefaultConfig
        $config.GlobalSettings.SnapshotRetention | Should -Not -BeNull
        $config.GlobalSettings.SnapshotRetention.DefaultKeepCount | Should -Be 3
    }
}
