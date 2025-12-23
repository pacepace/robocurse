# Task 01: Configuration Management

## Overview
Implement JSON configuration loading, saving, and validation for multi-profile sync settings.

## Research Required

### Web Research
- PowerShell `ConvertFrom-Json` and `ConvertTo-Json` depth parameter
- JSON schema validation in PowerShell
- Secure string handling for credential references

### Code Research
- Review the config schema defined in the plan file
- Look at `Get-Content -Raw` for file reading

## Task Description

Implement the Configuration region with these functions:

### Function: Get-RobocurseConfig
```powershell
function Get-RobocurseConfig {
    <#
    .SYNOPSIS
        Loads configuration from JSON file
    .PARAMETER Path
        Path to config file. Defaults to .\Robocurse.config.json
    .OUTPUTS
        PSCustomObject with configuration
    #>
    param(
        [string]$Path = ".\Robocurse.config.json"
    )
    # Implementation here
}
```

**Requirements:**
- Return default config if file doesn't exist
- Parse JSON with sufficient depth (use `-Depth 10`)
- Handle malformed JSON gracefully (try/catch, return error object)

### Function: Save-RobocurseConfig
```powershell
function Save-RobocurseConfig {
    <#
    .SYNOPSIS
        Saves configuration to JSON file
    .PARAMETER Config
        Configuration object to save
    .PARAMETER Path
        Path to save to
    #>
    param(
        [PSCustomObject]$Config,
        [string]$Path = ".\Robocurse.config.json"
    )
    # Implementation here
}
```

**Requirements:**
- Pretty-print JSON (use `-Depth 10`)
- Create parent directory if needed
- Return success/failure

### Function: Test-RobocurseConfig
```powershell
function Test-RobocurseConfig {
    <#
    .SYNOPSIS
        Validates configuration object
    .PARAMETER Config
        Configuration object to validate
    .OUTPUTS
        PSCustomObject with IsValid (bool) and Errors (string[])
    #>
    param(
        [PSCustomObject]$Config
    )
    # Implementation here
}
```

**Validation Rules:**
- Required fields present: GlobalSettings, SyncProfiles
- Each SyncProfile has: Name, Source, Destination
- Source paths are valid UNC or local paths (format check, not existence)
- Numeric values are within range (MaxConcurrentJobs: 1-32, etc.)
- Email config complete if notifications enabled

### Function: New-DefaultConfig
```powershell
function New-DefaultConfig {
    <#
    .SYNOPSIS
        Creates a new configuration with sensible defaults
    .OUTPUTS
        PSCustomObject with default configuration
    #>
    # Implementation here
}
```

### Config Schema
```json
{
  "Version": "1.0",
  "GlobalSettings": {
    "MaxConcurrentJobs": 4,
    "ThreadsPerJob": 8,
    "DefaultScanMode": "Smart",
    "LogRetentionDays": 30,
    "LogPath": ".\\Logs"
  },
  "Email": {
    "Enabled": false,
    "SmtpServer": "",
    "Port": 587,
    "UseTls": true,
    "CredentialTarget": "Robocurse-SMTP",
    "From": "",
    "To": []
  },
  "Schedule": {
    "Enabled": false,
    "Time": "02:00",
    "Days": ["Daily"]
  },
  "SyncProfiles": []
}
```

### SyncProfile Schema
```json
{
  "Name": "User Directories",
  "Enabled": true,
  "Source": "\\\\server\\share$",
  "Destination": "D:\\Backup\\Users",
  "UseVSS": true,
  "ChunkConfig": {
    "MaxSizeGB": 10,
    "MaxFiles": 50000,
    "MaxDepth": 5,
    "MinSizeMB": 100
  }
}
```

## Success Criteria

1. [ ] `Get-RobocurseConfig` loads JSON file correctly
2. [ ] `Get-RobocurseConfig` returns default config when file missing
3. [ ] `Get-RobocurseConfig` handles malformed JSON without crashing
4. [ ] `Save-RobocurseConfig` creates valid JSON file
5. [ ] `Test-RobocurseConfig` validates all required fields
6. [ ] `Test-RobocurseConfig` returns meaningful error messages
7. [ ] `New-DefaultConfig` returns complete default structure

## Pester Tests Required

Create `tests/Unit/Configuration.Tests.ps1`:

```powershell
Describe "Configuration" {
    BeforeAll {
        . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
        $script:TestConfigPath = "$TestDrive\test-config.json"
    }

    Context "Get-RobocurseConfig" {
        It "Should return default config when file doesn't exist" {
            $config = Get-RobocurseConfig -Path "$TestDrive\nonexistent.json"
            $config | Should -Not -BeNullOrEmpty
            $config.Version | Should -Be "1.0"
        }

        It "Should load valid config file" {
            $testConfig = @{ Version = "1.0"; GlobalSettings = @{} }
            $testConfig | ConvertTo-Json | Set-Content $script:TestConfigPath

            $config = Get-RobocurseConfig -Path $script:TestConfigPath
            $config.Version | Should -Be "1.0"
        }

        It "Should handle malformed JSON gracefully" {
            "{ invalid json" | Set-Content $script:TestConfigPath

            { Get-RobocurseConfig -Path $script:TestConfigPath } | Should -Not -Throw
        }
    }

    Context "Test-RobocurseConfig" {
        It "Should validate required fields" {
            $config = @{ }  # Missing required fields
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $false
            $result.Errors | Should -Not -BeNullOrEmpty
        }

        It "Should accept valid config" {
            $config = New-DefaultConfig
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $true
        }

        It "Should reject invalid paths" {
            $config = New-DefaultConfig
            $config.SyncProfiles = @(
                @{ Name = "Test"; Source = "invalid|path"; Destination = "C:\Backup" }
            )
            $result = Test-RobocurseConfig -Config $config

            $result.IsValid | Should -Be $false
        }
    }

    Context "Save-RobocurseConfig" {
        It "Should create valid JSON file" {
            $config = New-DefaultConfig
            Save-RobocurseConfig -Config $config -Path $script:TestConfigPath

            Test-Path $script:TestConfigPath | Should -Be $true
            { Get-Content $script:TestConfigPath | ConvertFrom-Json } | Should -Not -Throw
        }
    }
}
```

## Dependencies
- Task 00 (Project Structure) must be complete

## Estimated Complexity
- Low
- Standard JSON handling, no external dependencies
