#Requires -Modules Pester

<#
.SYNOPSIS
    Unit tests for JSON Schema configuration validation

.DESCRIPTION
    Tests that the JSON Schema correctly validates config files and
    catches invalid configurations.
#>

# Load module at discovery time
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

Describe "Config JSON Schema Tests" -Tag "Schema", "Unit" {

    BeforeAll {
        # Determine project root from test file location
        $testDir = Split-Path -Parent $PSCommandPath
        $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $testDir)
        $script:SchemaPath = Join-Path $script:ProjectRoot "schemas\robocurse.config.schema.json"
        $script:SampleConfigPath = Join-Path $script:ProjectRoot "Robocurse.config.json"
    }

    Context "Schema File Structure" {

        It "Should have a valid JSON schema file" {
            Test-Path $script:SchemaPath | Should -Be $true
        }

        It "Should be valid JSON" {
            $content = Get-Content $script:SchemaPath -Raw
            { $content | ConvertFrom-Json } | Should -Not -Throw
        }

        It "Should be a draft-07 schema" {
            $schema = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json
            $schema.'$schema' | Should -Be "http://json-schema.org/draft-07/schema#"
        }

        It "Should have required root properties defined" {
            $schema = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json
            $schema.required | Should -Contain "version"
            $schema.required | Should -Contain "profiles"
        }

        It "Should define profile as required fields" {
            $schema = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json
            $profileDef = $schema.definitions.profile
            $profileDef.required | Should -Contain "source"
            $profileDef.required | Should -Contain "destination"
        }
    }

    Context "Schema Definitions" {

        BeforeAll {
            $script:Schema = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json
        }

        It "Should define profile type" {
            $script:Schema.definitions.profile | Should -Not -BeNullOrEmpty
            $script:Schema.definitions.profile.type | Should -Be "object"
        }

        It "Should define sourceConfig type" {
            $script:Schema.definitions.sourceConfig | Should -Not -BeNullOrEmpty
            $script:Schema.definitions.sourceConfig.properties.path | Should -Not -BeNullOrEmpty
            $script:Schema.definitions.sourceConfig.properties.useVss | Should -Not -BeNullOrEmpty
        }

        It "Should define destinationConfig type" {
            $script:Schema.definitions.destinationConfig | Should -Not -BeNullOrEmpty
            $script:Schema.definitions.destinationConfig.required | Should -Contain "path"
        }

        It "Should define chunkingConfig with valid constraints" {
            $chunking = $script:Schema.definitions.chunkingConfig
            $chunking | Should -Not -BeNullOrEmpty
            $chunking.properties.maxChunkSizeGB.minimum | Should -BeGreaterThan 0
            $chunking.properties.maxFiles.minimum | Should -BeGreaterThan 0
            $chunking.properties.strategy.enum | Should -Contain "auto"
        }

        It "Should define robocopyConfig type" {
            $robocopy = $script:Schema.definitions.robocopyConfig
            $robocopy | Should -Not -BeNullOrEmpty
            $robocopy.properties.switches.type | Should -Be "array"
            $robocopy.properties.excludeFiles.type | Should -Be "array"
            $robocopy.properties.excludeDirs.type | Should -Be "array"
        }

        It "Should define globalSettings type" {
            $global = $script:Schema.definitions.globalSettings
            $global | Should -Not -BeNullOrEmpty
            $global.properties.performance | Should -Not -BeNullOrEmpty
            $global.properties.logging | Should -Not -BeNullOrEmpty
            $global.properties.email | Should -Not -BeNullOrEmpty
        }

        It "Should define email settings with conditional requirements" {
            $email = $script:Schema.definitions.globalSettings.properties.email
            $email | Should -Not -BeNullOrEmpty
            $email.properties.enabled.type | Should -Be "boolean"
            $email.properties.smtp | Should -Not -BeNullOrEmpty
            $email.properties.to.items.format | Should -Be "email"
        }

        It "Should define schedule settings" {
            $schedule = $script:Schema.definitions.globalSettings.properties.schedule
            $schedule | Should -Not -BeNullOrEmpty
            $schedule.properties.time.pattern | Should -Not -BeNullOrEmpty
            $schedule.properties.days.items.enum | Should -Contain "Daily"
        }
    }

    Context "Sample Config Validation" {

        It "Should have a sample config file" {
            Test-Path $script:SampleConfigPath | Should -Be $true
        }

        It "Sample config should be valid JSON" {
            $content = Get-Content $script:SampleConfigPath -Raw
            { $content | ConvertFrom-Json } | Should -Not -Throw
        }

        It "Sample config should reference the schema" {
            $config = Get-Content $script:SampleConfigPath -Raw | ConvertFrom-Json
            $config.'$schema' | Should -Not -BeNullOrEmpty
        }

        It "Sample config should have valid version" {
            $config = Get-Content $script:SampleConfigPath -Raw | ConvertFrom-Json
            $config.version | Should -Match "^[0-9]+\.[0-9]+$"
        }

        It "Sample config should have profiles" {
            $config = Get-Content $script:SampleConfigPath -Raw | ConvertFrom-Json
            $config.profiles | Should -Not -BeNullOrEmpty
        }

        It "Sample config profiles should have source and destination" {
            $config = Get-Content $script:SampleConfigPath -Raw | ConvertFrom-Json
            foreach ($profileName in $config.profiles.PSObject.Properties.Name) {
                $profile = $config.profiles.$profileName
                $profile.source | Should -Not -BeNullOrEmpty -Because "Profile '$profileName' needs source"
                $profile.source.path | Should -Not -BeNullOrEmpty -Because "Profile '$profileName' needs source.path"
                $profile.destination | Should -Not -BeNullOrEmpty -Because "Profile '$profileName' needs destination"
                $profile.destination.path | Should -Not -BeNullOrEmpty -Because "Profile '$profileName' needs destination.path"
            }
        }
    }

    Context "Schema Constraint Validation" {

        It "Should enforce valid version pattern" {
            $schema = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json
            $versionPattern = $schema.properties.version.pattern

            # Valid versions
            "1.0" -match $versionPattern | Should -Be $true
            "2.5" -match $versionPattern | Should -Be $true
            "10.20" -match $versionPattern | Should -Be $true

            # Invalid versions
            "1" -match $versionPattern | Should -Be $false
            "v1.0" -match $versionPattern | Should -Be $false
            "1.0.0" -match $versionPattern | Should -Be $false
        }

        It "Should enforce valid time pattern for schedules" {
            $schema = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json
            $timePattern = $schema.definitions.globalSettings.properties.schedule.properties.time.pattern

            # Valid times
            "00:00" -match $timePattern | Should -Be $true
            "02:00" -match $timePattern | Should -Be $true
            "12:30" -match $timePattern | Should -Be $true
            "23:59" -match $timePattern | Should -Be $true

            # Invalid times
            "24:00" -match $timePattern | Should -Be $false
            "2:00" -match $timePattern | Should -Be $false
            "02:60" -match $timePattern | Should -Be $false
        }

        It "Should define valid chunking strategy enum values" {
            $schema = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json
            $strategies = $schema.definitions.chunkingConfig.properties.strategy.enum

            $strategies | Should -Contain "auto"
            $strategies | Should -Contain "none"
            $strategies | Should -Contain "size"
            $strategies | Should -Contain "count"
        }

        It "Should define valid mismatch severity enum values" {
            $schema = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json
            $severities = $schema.definitions.robocopyConfig.properties.mismatchSeverity.enum

            $severities | Should -Contain "Warning"
            $severities | Should -Contain "Error"
            $severities | Should -Contain "Success"
        }

        It "Should define valid schedule days enum values" {
            $schema = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json
            $days = $schema.definitions.globalSettings.properties.schedule.properties.days.items.enum

            $days | Should -Contain "Daily"
            $days | Should -Contain "Monday"
            $days | Should -Contain "Tuesday"
            $days | Should -Contain "Wednesday"
            $days | Should -Contain "Thursday"
            $days | Should -Contain "Friday"
            $days | Should -Contain "Saturday"
            $days | Should -Contain "Sunday"
        }
    }

    Context "Schema Defaults" {

        BeforeAll {
            $script:Schema = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json
        }

        It "Should have sensible default for maxConcurrentJobs" {
            $default = $script:Schema.definitions.globalSettings.properties.performance.properties.maxConcurrentJobs.default
            $default | Should -Be 4
        }

        It "Should have sensible default for maxChunkSizeGB" {
            $default = $script:Schema.definitions.chunkingConfig.properties.maxChunkSizeGB.default
            $default | Should -Be 10
        }

        It "Should have sensible default for SMTP port" {
            $default = $script:Schema.definitions.globalSettings.properties.email.properties.smtp.properties.port.default
            $default | Should -Be 587
        }

        It "Should have sensible default for schedule time" {
            $default = $script:Schema.definitions.globalSettings.properties.schedule.properties.time.default
            $default | Should -Be "02:00"
        }
    }
}
