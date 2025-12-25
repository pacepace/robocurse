#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type (required for module isolation when running all tests together)
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "CredentialStorage" {
        BeforeAll {
            # Create temp config directory for tests
            $script:tempConfigDir = Join-Path $TestDrive "config"
            New-Item -ItemType Directory -Path $script:tempConfigDir -Force | Out-Null
            $script:tempConfigPath = Join-Path $script:tempConfigDir "test-config.json"
            '{}' | Set-Content $script:tempConfigPath

            Mock Write-RobocurseLog { }
        }

        AfterEach {
            # Clean up credentials directory after each test
            $credDir = Join-Path $script:tempConfigDir ".credentials"
            if (Test-Path $credDir) {
                Remove-Item $credDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        Context "Get-CredentialStoragePath" {
            It "Should return .credentials subfolder next to config" {
                $result = Get-CredentialStoragePath -ConfigPath $script:tempConfigPath
                $result | Should -Be (Join-Path $script:tempConfigDir ".credentials")
            }
        }

        Context "Save-NetworkCredential" {
            It "Should save credential successfully" {
                $cred = [PSCredential]::new('DOMAIN\user', (ConvertTo-SecureString 'password123' -AsPlainText -Force))

                $result = Save-NetworkCredential -ProfileName 'TestProfile' -Credential $cred -ConfigPath $script:tempConfigPath

                $result.Success | Should -Be $true
                $result.Data | Should -Match '\.credential$'
                Test-Path $result.Data | Should -Be $true
            }

            It "Should create credentials directory if missing" {
                $cred = [PSCredential]::new('user', (ConvertTo-SecureString 'pass' -AsPlainText -Force))
                $credDir = Join-Path $script:tempConfigDir ".credentials"

                # Ensure it doesn't exist
                if (Test-Path $credDir) { Remove-Item $credDir -Recurse -Force }

                Save-NetworkCredential -ProfileName 'TestProfile' -Credential $cred -ConfigPath $script:tempConfigPath

                Test-Path $credDir | Should -Be $true
            }

            It "Should sanitize profile names with invalid characters" {
                $cred = [PSCredential]::new('user', (ConvertTo-SecureString 'pass' -AsPlainText -Force))

                $result = Save-NetworkCredential -ProfileName 'Test/Profile:With*Bad?Chars' -Credential $cred -ConfigPath $script:tempConfigPath

                $result.Success | Should -Be $true
                $result.Data | Should -Match 'Test_Profile_With_Bad_Chars\.credential$'
            }
        }

        Context "Get-NetworkCredential" {
            It "Should load saved credential" {
                $originalCred = [PSCredential]::new('DOMAIN\testuser', (ConvertTo-SecureString 'secretpass' -AsPlainText -Force))
                Save-NetworkCredential -ProfileName 'LoadTest' -Credential $originalCred -ConfigPath $script:tempConfigPath

                $loaded = Get-NetworkCredential -ProfileName 'LoadTest' -ConfigPath $script:tempConfigPath

                $loaded | Should -Not -BeNullOrEmpty
                $loaded.UserName | Should -Be 'DOMAIN\testuser'
                $loaded.GetNetworkCredential().Password | Should -Be 'secretpass'
            }

            It "Should return null for non-existent profile" {
                $result = Get-NetworkCredential -ProfileName 'DoesNotExist' -ConfigPath $script:tempConfigPath

                $result | Should -BeNullOrEmpty
            }

            It "Should handle special characters in password" {
                $specialPassword = 'P@ss!w0rd#$%^&*()_+-=[]{}|;:,.<>?'
                $cred = [PSCredential]::new('user', (ConvertTo-SecureString $specialPassword -AsPlainText -Force))
                Save-NetworkCredential -ProfileName 'SpecialChars' -Credential $cred -ConfigPath $script:tempConfigPath

                $loaded = Get-NetworkCredential -ProfileName 'SpecialChars' -ConfigPath $script:tempConfigPath

                $loaded.GetNetworkCredential().Password | Should -Be $specialPassword
            }
        }

        Context "Remove-NetworkCredential" {
            It "Should remove existing credential" {
                $cred = [PSCredential]::new('user', (ConvertTo-SecureString 'pass' -AsPlainText -Force))
                Save-NetworkCredential -ProfileName 'ToDelete' -Credential $cred -ConfigPath $script:tempConfigPath

                $result = Remove-NetworkCredential -ProfileName 'ToDelete' -ConfigPath $script:tempConfigPath

                $result.Success | Should -Be $true

                # Verify it's gone
                $loaded = Get-NetworkCredential -ProfileName 'ToDelete' -ConfigPath $script:tempConfigPath
                $loaded | Should -BeNullOrEmpty
            }

            It "Should succeed when credential doesn't exist" {
                $result = Remove-NetworkCredential -ProfileName 'NeverExisted' -ConfigPath $script:tempConfigPath

                $result.Success | Should -Be $true
            }
        }

        Context "Test-NetworkCredentialExists" {
            It "Should return true when credential exists" {
                $cred = [PSCredential]::new('user', (ConvertTo-SecureString 'pass' -AsPlainText -Force))
                Save-NetworkCredential -ProfileName 'ExistsTest' -Credential $cred -ConfigPath $script:tempConfigPath

                $result = Test-NetworkCredentialExists -ProfileName 'ExistsTest' -ConfigPath $script:tempConfigPath

                $result | Should -Be $true
            }

            It "Should return false when credential does not exist" {
                $result = Test-NetworkCredentialExists -ProfileName 'DoesNotExist' -ConfigPath $script:tempConfigPath

                $result | Should -Be $false
            }
        }

        Context "Round-trip with various credential formats" {
            It "Should handle domain\\user format" {
                $cred = [PSCredential]::new('DOMAIN\Administrator', (ConvertTo-SecureString 'AdminPass' -AsPlainText -Force))
                Save-NetworkCredential -ProfileName 'DomainUser' -Credential $cred -ConfigPath $script:tempConfigPath

                $loaded = Get-NetworkCredential -ProfileName 'DomainUser' -ConfigPath $script:tempConfigPath

                $loaded.UserName | Should -Be 'DOMAIN\Administrator'
            }

            It "Should handle user@domain format" {
                $cred = [PSCredential]::new('admin@contoso.com', (ConvertTo-SecureString 'Pass123' -AsPlainText -Force))
                Save-NetworkCredential -ProfileName 'UPNUser' -Credential $cred -ConfigPath $script:tempConfigPath

                $loaded = Get-NetworkCredential -ProfileName 'UPNUser' -ConfigPath $script:tempConfigPath

                $loaded.UserName | Should -Be 'admin@contoso.com'
            }

            It "Should handle local user format" {
                $cred = [PSCredential]::new('localadmin', (ConvertTo-SecureString 'LocalPass' -AsPlainText -Force))
                Save-NetworkCredential -ProfileName 'LocalUser' -Credential $cred -ConfigPath $script:tempConfigPath

                $loaded = Get-NetworkCredential -ProfileName 'LocalUser' -ConfigPath $script:tempConfigPath

                $loaded.UserName | Should -Be 'localadmin'
            }
        }
    }
}
