#Requires -Modules Pester

# Load module at discovery time for InModuleScope
$testRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $testRoot)
$modulePath = Join-Path $projectRoot "src\Robocurse\Robocurse.psm1"
Import-Module $modulePath -Force -Global -DisableNameChecking

# Initialize the C# OrchestrationState type (required for module isolation when running all tests together)
Initialize-OrchestrationStateType | Out-Null

InModuleScope 'Robocurse' {
    Describe "Email Notifications" {
        Context "Send-CompletionEmail Validation" {
            It "Should throw when Config is null" {
                $results = [PSCustomObject]@{ Duration = [timespan]::Zero }
                {
                    Send-CompletionEmail -Config $null -Results $results -Status 'Success'
                } | Should -Throw "*Config*"
            }

            It "Should throw when Results is null" {
                $config = [PSCustomObject]@{ Enabled = $true; SmtpServer = "smtp.test.com"; From = "test@test.com"; To = @("user@test.com"); Port = 587 }
                {
                    Send-CompletionEmail -Config $config -Results $null -Status 'Success'
                } | Should -Throw "*Results*"
            }

            It "Should return error when Config.Enabled is null" {
                $config = [PSCustomObject]@{ SmtpServer = "smtp.test.com" }
                $results = [PSCustomObject]@{ Duration = [timespan]::Zero }

                $result = Send-CompletionEmail -Config $config -Results $results -Status 'Success'

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "Enabled"
            }

            It "Should return success when email is disabled" {
                $config = [PSCustomObject]@{ Enabled = $false }
                $results = [PSCustomObject]@{ Duration = [timespan]::Zero }

                $result = Send-CompletionEmail -Config $config -Results $results -Status 'Success'

                $result.Success | Should -Be $true
            }

            It "Should return error when Config.SmtpServer is missing and email is enabled" {
                $config = [PSCustomObject]@{ Enabled = $true; From = "test@test.com"; To = @("user@test.com"); Port = 587 }
                $results = [PSCustomObject]@{ Duration = [timespan]::Zero }

                $result = Send-CompletionEmail -Config $config -Results $results -Status 'Success'

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "SmtpServer"
            }

            It "Should return error when Config.From is missing and email is enabled" {
                $config = [PSCustomObject]@{ Enabled = $true; SmtpServer = "smtp.test.com"; To = @("user@test.com"); Port = 587 }
                $results = [PSCustomObject]@{ Duration = [timespan]::Zero }

                $result = Send-CompletionEmail -Config $config -Results $results -Status 'Success'

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "From"
            }

            It "Should return error when Config.To is missing and email is enabled" {
                $config = [PSCustomObject]@{ Enabled = $true; SmtpServer = "smtp.test.com"; From = "test@test.com"; Port = 587 }
                $results = [PSCustomObject]@{ Duration = [timespan]::Zero }

                $result = Send-CompletionEmail -Config $config -Results $results -Status 'Success'

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "To"
            }

            It "Should return error when Config.Port is missing and email is enabled" {
                $config = [PSCustomObject]@{ Enabled = $true; SmtpServer = "smtp.test.com"; From = "test@test.com"; To = @("user@test.com") }
                $results = [PSCustomObject]@{ Duration = [timespan]::Zero }

                $result = Send-CompletionEmail -Config $config -Results $results -Status 'Success'

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "Port"
            }
        }

        Context "Format-FileSize" {
            It "Should format bytes correctly" {
                Format-FileSize -Bytes 512 | Should -Be "512 bytes"
            }

            It "Should format kilobytes correctly" {
                Format-FileSize -Bytes 2048 | Should -Be "2.00 KB"
            }

            It "Should format megabytes correctly" {
                Format-FileSize -Bytes (10 * 1MB) | Should -Be "10.00 MB"
            }

            It "Should format gigabytes correctly" {
                Format-FileSize -Bytes (5 * 1GB) | Should -Be "5.00 GB"
            }

            It "Should format terabytes correctly" {
                Format-FileSize -Bytes (2 * 1TB) | Should -Be "2.00 TB"
            }
        }

        Context "New-CompletionEmailBody" {
            It "Should generate valid HTML" {
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromHours(1)
                    TotalBytesCopied = 5GB
                    TotalFilesCopied = 10000
                    TotalErrors = 2
                    Profiles = @()
                    Errors = @("Error 1", "Error 2")
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Warning'

                $html | Should -Match "<html>"
                $html | Should -Match "</html>"
                $html | Should -Match "Warning"
                $html | Should -Match "Error 1"
                $html | Should -Match "Error 2"
            }

            It "Should use correct status colors" {
                $results = [PSCustomObject]@{
                    Duration = [timespan]::Zero
                    TotalBytesCopied = 0
                    TotalFilesCopied = 0
                    TotalErrors = 0
                    Profiles = @()
                    Errors = @()
                }

                $successHtml = New-CompletionEmailBody -Results $results -Status 'Success'
                $warningHtml = New-CompletionEmailBody -Results $results -Status 'Warning'
                $failedHtml = New-CompletionEmailBody -Results $results -Status 'Failed'

                $successHtml | Should -Match "#4CAF50"
                $warningHtml | Should -Match "#FF9800"
                $failedHtml | Should -Match "#F44336"
            }

            It "Should include profile information" {
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(30)
                    TotalBytesCopied = 1GB
                    TotalFilesCopied = 5000
                    TotalErrors = 0
                    Profiles = @(
                        [PSCustomObject]@{
                            Name = "Test Profile"
                            Status = "Success"
                            ChunksComplete = 5
                            ChunksTotal = 5
                            FilesCopied = 5000
                            BytesCopied = 1GB
                        }
                    )
                    Errors = @()
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Success'

                $html | Should -Match "Test Profile"
                $html | Should -Match "Chunks: 5/5"
            }

            It "Should limit error display to 10 items" {
                $errors = 1..15 | ForEach-Object { "Error $_" }
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(10)
                    TotalBytesCopied = 0
                    TotalFilesCopied = 0
                    TotalErrors = 15
                    Profiles = @()
                    Errors = $errors
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Failed'

                $html | Should -Match "Error 1"
                $html | Should -Match "Error 10"
                $html | Should -Match "and 5 more errors"
            }

            It "Should HTML encode error messages" {
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(1)
                    TotalBytesCopied = 0
                    TotalFilesCopied = 0
                    TotalErrors = 1
                    Profiles = @()
                    Errors = @("Error with <script>alert('xss')</script>")
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Failed'

                $html | Should -Not -Match "<script>"
                $html | Should -Match "&lt;script&gt;"
            }

            It "Should format duration correctly" {
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromSeconds(3661)
                    TotalBytesCopied = 0
                    TotalFilesCopied = 0
                    TotalErrors = 0
                    Profiles = @()
                    Errors = @()
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Success'

                $html | Should -Match "01:01:01"
            }
        }

        Context "Send-CompletionEmail" {
            BeforeEach {
                $script:mockConfig = [PSCustomObject]@{
                    Enabled = $true
                    SmtpServer = "smtp.example.com"
                    Port = 587
                    UseTls = $true
                    CredentialTarget = "Test-SMTP"
                    From = "test@example.com"
                    To = @("recipient@example.com")
                }

                $script:mockResults = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(5)
                    TotalBytesCopied = 1GB
                    TotalFilesCopied = 1000
                    TotalErrors = 0
                    Profiles = @()
                    Errors = @()
                }
            }

            It "Should not send when disabled" {
                Mock Send-MultipartEmail { }

                $config = [PSCustomObject]@{ Enabled = $false }
                Send-CompletionEmail -Config $config -Results $script:mockResults -Status 'Success'

                Should -Not -Invoke Send-MultipartEmail
            }

            It "Should return error on missing credential" {
                Mock Get-SmtpCredential { $null }
                Mock Send-MultipartEmail { }

                $result = Send-CompletionEmail -Config $script:mockConfig -Results $script:mockResults -Status 'Success'

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "credential"
                Should -Not -Invoke Send-MultipartEmail
            }

            It "Should send email with correct parameters when enabled" {
                $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
                Mock Get-SmtpCredential { $mockCred }
                Mock Send-MultipartEmail { }

                Send-CompletionEmail -Config $script:mockConfig -Results $script:mockResults -Status 'Success'

                Should -Invoke Send-MultipartEmail -Times 1 -ParameterFilter {
                    $SmtpServer -eq "smtp.example.com" -and
                    $Port -eq 587 -and
                    $UseSsl -eq $true -and
                    $From -eq "test@example.com" -and
                    $TextBody -ne $null -and
                    $HtmlBody -ne $null
                }
            }

            It "Should set priority to High for Failed status" {
                $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
                Mock Get-SmtpCredential { $mockCred }
                Mock Send-MultipartEmail { }

                Send-CompletionEmail -Config $script:mockConfig -Results $script:mockResults -Status 'Failed'

                Should -Invoke Send-MultipartEmail -Times 1 -ParameterFilter {
                    $Priority -eq [System.Net.Mail.MailPriority]::High
                }
            }

            It "Should set priority to Normal for Success status" {
                $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
                Mock Get-SmtpCredential { $mockCred }
                Mock Send-MultipartEmail { }

                Send-CompletionEmail -Config $script:mockConfig -Results $script:mockResults -Status 'Success'

                Should -Invoke Send-MultipartEmail -Times 1 -ParameterFilter {
                    $Priority -eq [System.Net.Mail.MailPriority]::Normal
                }
            }

            It "Should return error on send failure" {
                $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
                Mock Get-SmtpCredential { $mockCred }
                Mock Send-MultipartEmail { throw "SMTP connection failed" }

                # Use -ErrorAction SilentlyContinue to suppress Write-Error output from Write-RobocurseLog
                $result = Send-CompletionEmail -Config $script:mockConfig -Results $script:mockResults -Status 'Success' -ErrorAction SilentlyContinue

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "SMTP connection failed"
            }

            It "Should return error with incomplete configuration (empty SmtpServer)" {
                Mock Get-SmtpCredential { }
                Mock Send-MultipartEmail { }

                $incompleteConfig = [PSCustomObject]@{
                    Enabled = $true
                    SmtpServer = ""
                    Port = 587
                    UseTls = $true
                    CredentialTarget = "Test-SMTP"
                    From = "test@example.com"
                    To = @("user@test.com")
                }

                $result = Send-CompletionEmail -Config $incompleteConfig -Results $script:mockResults -Status 'Success'

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "SmtpServer"
            }
        }

        Context "Test-SmtpCredential" {
            It "Should return false when no credential exists" {
                Mock Get-SmtpCredential { $null }

                $result = Test-SmtpCredential -Target "NonExistent"

                $result | Should -Be $false
            }

            It "Should return true when credential exists" {
                $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
                Mock Get-SmtpCredential { $mockCred }

                $result = Test-SmtpCredential -Target "Exists"

                $result | Should -Be $true
            }
        }

        Context "Test-EmailConfiguration" {
            BeforeEach {
                $script:testConfig = [PSCustomObject]@{
                    Enabled = $true
                    SmtpServer = "smtp.example.com"
                    Port = 587
                    UseTls = $true
                    CredentialTarget = "Test-SMTP"
                    From = "test@example.com"
                    To = @("recipient@example.com")
                }
            }

            It "Should return success on successful send" {
                $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
                Mock Get-SmtpCredential { $mockCred }
                Mock Send-MultipartEmail { }

                $result = Test-EmailConfiguration -Config $script:testConfig

                $result.Success | Should -Be $true
            }

            It "Should return error when Send-MultipartEmail fails" {
                $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
                Mock Get-SmtpCredential { $mockCred }
                Mock Send-MultipartEmail { throw "Connection refused" }

                # Use -ErrorAction SilentlyContinue to suppress Write-Error output from Write-RobocurseLog
                $result = Test-EmailConfiguration -Config $script:testConfig -ErrorAction SilentlyContinue

                $result.Success | Should -Be $false
                $result.ErrorMessage | Should -Match "Connection refused"
            }

            It "Should send test email with dummy results" {
                $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
                Mock Get-SmtpCredential { $mockCred }
                Mock Send-MultipartEmail { }

                Test-EmailConfiguration -Config $script:testConfig

                Should -Invoke Send-MultipartEmail -Times 1 -ParameterFilter {
                    $Subject -match "Success" -and
                    $TextBody -ne $null -and
                    $HtmlBody -ne $null
                }
            }
        }

        Context "Get-SmtpCredential (Environment Variable Fallback)" {
            It "Should retrieve credential from environment variables" {
                try {
                    [Environment]::SetEnvironmentVariable("ROBOCURSE_SMTP_USER", "testuser", "Process")
                    [Environment]::SetEnvironmentVariable("ROBOCURSE_SMTP_PASS", "testpass", "Process")

                    $cred = Get-SmtpCredential -Target "NonExistent"

                    $cred | Should -Not -BeNullOrEmpty
                    $cred.UserName | Should -Be "testuser"
                    $cred.GetNetworkCredential().Password | Should -Be "testpass"
                }
                finally {
                    [Environment]::SetEnvironmentVariable("ROBOCURSE_SMTP_USER", $null, "Process")
                    [Environment]::SetEnvironmentVariable("ROBOCURSE_SMTP_PASS", $null, "Process")
                }
            }

            It "Should return null when no credentials found" {
                [Environment]::SetEnvironmentVariable("ROBOCURSE_SMTP_USER", $null, "Process")
                [Environment]::SetEnvironmentVariable("ROBOCURSE_SMTP_PASS", $null, "Process")

                Mock Initialize-CredentialManager { }

                $cred = Get-SmtpCredential -Target "NonExistent"

                $cred | Should -BeNullOrEmpty
            }
        }

        Context "New-CompletionEmailBody ProfileNames" {
            It "Accepts ProfileNames parameter" {
                $cmd = Get-Command New-CompletionEmailBody -ErrorAction SilentlyContinue
                $cmd.Parameters.Keys | Should -Contain 'ProfileNames'
            }

            It "Includes single profile name in header" {
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(5)
                    TotalBytesCopied = 1000
                    TotalFilesCopied = 10
                    TotalErrors = 0
                    Profiles = @()
                    Errors = @()
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Success' -ProfileNames @('TestProfile')

                $html | Should -Match 'TestProfile'
            }

            It "Includes profile names as list items" {
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(5)
                    TotalBytesCopied = 1000
                    TotalFilesCopied = 10
                    TotalErrors = 0
                    Profiles = @()
                    Errors = @()
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Success' -ProfileNames @('Profile1', 'Profile2', 'Profile3')

                # Profile names should be in list items
                $html | Should -Match '<li[^>]*>Profile1</li>'
                $html | Should -Match '<li[^>]*>Profile2</li>'
                $html | Should -Match '<li[^>]*>Profile3</li>'
            }

            It "Profile names appear in header div" {
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(5)
                    TotalBytesCopied = 1000
                    TotalFilesCopied = 10
                    TotalErrors = 0
                    Profiles = @()
                    Errors = @()
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Success' -ProfileNames @('MyProfile')

                # Profile names should be in a styled div inside the header (use (?s) to match across newlines)
                $html | Should -Match '(?s)<div class="header">.*MyProfile.*</div>'
            }
        }

        Context "New-CompletionEmailBody FilesSkipped" {
            It "Accepts FilesSkipped parameter" {
                $cmd = Get-Command New-CompletionEmailBody -ErrorAction SilentlyContinue
                $cmd.Parameters.Keys | Should -Contain 'FilesSkipped'
            }

            It "Includes FilesSkipped in stats section" {
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(5)
                    TotalBytesCopied = 1000
                    TotalFilesCopied = 10
                    TotalErrors = 0
                    Profiles = @()
                    Errors = @()
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Success' -FilesSkipped 42

                $html | Should -Match 'Files Skipped'
                $html | Should -Match '42'
            }

            It "Shows 0 skipped when none skipped" {
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(5)
                    TotalBytesCopied = 1000
                    TotalFilesCopied = 10
                    TotalErrors = 0
                    Profiles = @()
                    Errors = @()
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Success' -FilesSkipped 0

                $html | Should -Match 'Files Skipped'
            }
        }

        Context "New-CompletionEmailBody Total Files and Success Rate" {
            It "Includes Total Files in stats section" {
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(5)
                    TotalBytesCopied = 1000
                    TotalFilesCopied = 100
                    TotalErrors = 0
                    Profiles = @()
                    Errors = @()
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Success' -FilesSkipped 20 -FilesFailed 5

                $html | Should -Match 'Total Files'
                # Total = 100 copied + 20 skipped + 5 failed = 125
                $html | Should -Match '125'
            }

            It "Includes Success Rate in stats section" {
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(5)
                    TotalBytesCopied = 1000
                    TotalFilesCopied = 80
                    TotalErrors = 0
                    Profiles = @()
                    Errors = @()
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Success' -FilesSkipped 10 -FilesFailed 10

                $html | Should -Match 'Success Rate'
                # Success = (80 copied + 10 skipped) / 100 total = 90%
                $html | Should -Match '90%'
            }

            It "Shows 100% success rate when no files" {
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(1)
                    TotalBytesCopied = 0
                    TotalFilesCopied = 0
                    TotalErrors = 0
                    Profiles = @()
                    Errors = @()
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Success' -FilesSkipped 0 -FilesFailed 0

                $html | Should -Match 'Success Rate'
                $html | Should -Match '100%'
            }

            It "Calculates correct success rate with only failures" {
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(5)
                    TotalBytesCopied = 0
                    TotalFilesCopied = 0
                    TotalErrors = 5
                    Profiles = @()
                    Errors = @()
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Failed' -FilesSkipped 0 -FilesFailed 100

                $html | Should -Match 'Success Rate'
                # Success = 0 / 100 = 0%
                $html | Should -Match '0%'
            }

            It "Caps success rate at 99.9% when files failed but rate rounds to 100%" {
                # Simulate scenario: 21083 skipped, 1 failed = 99.995% which rounds to 100%
                # But we cap at 99.9% when any failures exist
                $results = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(5)
                    TotalBytesCopied = 1000
                    TotalFilesCopied = 0
                    TotalErrors = 0
                    Profiles = @()
                    Errors = @()
                }

                $html = New-CompletionEmailBody -Results $results -Status 'Success' -FilesSkipped 21083 -FilesFailed 1

                $html | Should -Match 'Success Rate'
                # Should show 99.9%, not 100%
                $html | Should -Match '99\.9%'
                $html | Should -Not -Match '>100%<'
            }
        }

        Context "Send-CompletionEmail Attachments" {
            BeforeEach {
                $script:mockConfig = [PSCustomObject]@{
                    Enabled = $true
                    SmtpServer = "smtp.example.com"
                    Port = 587
                    UseTls = $true
                    From = "noreply@example.com"
                    To = @("user@example.com")
                    CredentialTarget = "TestTarget"
                }
                $script:mockResults = [PSCustomObject]@{
                    Duration = [timespan]::FromMinutes(30)
                    TotalBytesCopied = 1024
                    TotalFilesCopied = 10
                    TotalErrors = 0
                    Profiles = @()
                    Errors = @()
                }
                Mock Write-RobocurseLog { }
                Mock Write-SiemEvent { }
            }

            It "Attaches FailedFilesSummaryPath when provided" {
                $mockCred = New-Object PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
                Mock Get-SmtpCredential { $mockCred }
                Mock Send-MultipartEmail { } -ParameterFilter { $Attachments -and $Attachments.Count -gt 0 }

                # Create temp file
                $tempFile = Join-Path $TestDrive "FailedFiles.txt"
                "Test content" | Out-File -FilePath $tempFile

                Send-CompletionEmail -Config $script:mockConfig -Results $script:mockResults -Status 'Success' -FailedFilesSummaryPath $tempFile

                Should -Invoke Send-MultipartEmail -Times 1 -ParameterFilter { $Attachments.Count -eq 1 }
            }

            It "Does not attach when FailedFilesSummaryPath is null" {
                $mockCred = New-Object PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
                Mock Get-SmtpCredential { $mockCred }
                Mock Send-MultipartEmail { }

                Send-CompletionEmail -Config $script:mockConfig -Results $script:mockResults -Status 'Success' -FailedFilesSummaryPath $null

                Should -Invoke Send-MultipartEmail -Times 1 -ParameterFilter { $Attachments.Count -eq 0 }
            }
        }
    }
}
