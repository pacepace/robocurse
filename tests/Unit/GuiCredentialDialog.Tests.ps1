#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize OrchestrationState type before InModuleScope
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "GUI Credential Input Dialog Tests" {

        Context "Function Existence Tests" {
            It "Should have Show-CredentialInputDialog function" {
                Get-Command Show-CredentialInputDialog -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }
        }

        Context "XAML CredentialInputDialog Control Tests" {
            BeforeAll {
                $script:TestXamlContent = Get-XamlResource -ResourceName 'CredentialInputDialog.xaml'
            }

            It "Should have txtUsername textbox" {
                $script:TestXamlContent | Should -Match 'x:Name="txtUsername"'
            }

            It "Should have pwdPassword password box" {
                $script:TestXamlContent | Should -Match 'x:Name="pwdPassword"'
            }

            It "Should have btnSave button" {
                $script:TestXamlContent | Should -Match 'x:Name="btnSave"'
            }

            It "Should have btnCancel button" {
                $script:TestXamlContent | Should -Match 'x:Name="btnCancel"'
            }

            It "Should have txtTitle text block" {
                $script:TestXamlContent | Should -Match 'x:Name="txtTitle"'
            }

            It "Should use PasswordBox for password input" {
                $script:TestXamlContent | Should -Match '<PasswordBox'
            }
        }

        Context "MainWindow Credential Button Tests" {
            BeforeAll {
                $script:MainWindowXaml = Get-XamlResource -ResourceName 'MainWindow.xaml'
            }

            It "Should have btnSettingsSetCredential button" {
                $script:MainWindowXaml | Should -Match 'x:Name="btnSettingsSetCredential"'
            }
        }

        Context "Show-CredentialInputDialog Parameter Tests" {
            It "Should accept CredentialTarget parameter" {
                $cmd = Get-Command Show-CredentialInputDialog -ErrorAction SilentlyContinue
                $cmd.Parameters.Keys | Should -Contain 'CredentialTarget'
            }
        }
    }
}
