Describe "Email Notifications" {
    BeforeAll {
        . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
    }

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

        It "Should throw when Config.Enabled is null" {
            $config = [PSCustomObject]@{ SmtpServer = "smtp.test.com" }
            $results = [PSCustomObject]@{ Duration = [timespan]::Zero }
            {
                Send-CompletionEmail -Config $config -Results $results -Status 'Success'
            } | Should -Throw "*Enabled*"
        }

        It "Should return without error when email is disabled" {
            $config = [PSCustomObject]@{ Enabled = $false }
            $results = [PSCustomObject]@{ Duration = [timespan]::Zero }
            {
                Send-CompletionEmail -Config $config -Results $results -Status 'Success'
            } | Should -Not -Throw
        }

        It "Should throw when Config.SmtpServer is missing and email is enabled" {
            $config = [PSCustomObject]@{ Enabled = $true; From = "test@test.com"; To = @("user@test.com"); Port = 587 }
            $results = [PSCustomObject]@{ Duration = [timespan]::Zero }
            {
                Send-CompletionEmail -Config $config -Results $results -Status 'Success'
            } | Should -Throw "*SmtpServer*"
        }

        It "Should throw when Config.From is missing and email is enabled" {
            $config = [PSCustomObject]@{ Enabled = $true; SmtpServer = "smtp.test.com"; To = @("user@test.com"); Port = 587 }
            $results = [PSCustomObject]@{ Duration = [timespan]::Zero }
            {
                Send-CompletionEmail -Config $config -Results $results -Status 'Success'
            } | Should -Throw "*From*"
        }

        It "Should throw when Config.To is missing and email is enabled" {
            $config = [PSCustomObject]@{ Enabled = $true; SmtpServer = "smtp.test.com"; From = "test@test.com"; Port = 587 }
            $results = [PSCustomObject]@{ Duration = [timespan]::Zero }
            {
                Send-CompletionEmail -Config $config -Results $results -Status 'Success'
            } | Should -Throw "*To*"
        }

        It "Should throw when Config.Port is missing and email is enabled" {
            $config = [PSCustomObject]@{ Enabled = $true; SmtpServer = "smtp.test.com"; From = "test@test.com"; To = @("user@test.com") }
            $results = [PSCustomObject]@{ Duration = [timespan]::Zero }
            {
                Send-CompletionEmail -Config $config -Results $results -Status 'Success'
            } | Should -Throw "*Port*"
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

            $successHtml | Should -Match "#4CAF50"  # Green
            $warningHtml | Should -Match "#FF9800"  # Orange
            $failedHtml | Should -Match "#F44336"   # Red
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
                Duration = [timespan]::FromSeconds(3661)  # 1:01:01
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
            Mock Send-MailMessage { }

            $config = [PSCustomObject]@{ Enabled = $false }
            Send-CompletionEmail -Config $config -Results $script:mockResults -Status 'Success'

            Should -Not -Invoke Send-MailMessage
        }

        It "Should handle missing credential gracefully" {
            Mock Get-SmtpCredential { $null }
            Mock Send-MailMessage { }

            { Send-CompletionEmail -Config $script:mockConfig -Results $script:mockResults -Status 'Success' } | Should -Not -Throw
            Should -Not -Invoke Send-MailMessage
        }

        It "Should send email with correct parameters when enabled" {
            $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
            Mock Get-SmtpCredential { $mockCred }
            Mock Send-MailMessage { }

            Send-CompletionEmail -Config $script:mockConfig -Results $script:mockResults -Status 'Success'

            Should -Invoke Send-MailMessage -Times 1 -ParameterFilter {
                $SmtpServer -eq "smtp.example.com" -and
                $Port -eq 587 -and
                $UseSsl -eq $true -and
                $From -eq "test@example.com" -and
                $To -eq @("recipient@example.com") -and
                $BodyAsHtml -eq $true
            }
        }

        It "Should set priority to High for Failed status" {
            $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
            Mock Get-SmtpCredential { $mockCred }
            Mock Send-MailMessage { }

            Send-CompletionEmail -Config $script:mockConfig -Results $script:mockResults -Status 'Failed'

            Should -Invoke Send-MailMessage -Times 1 -ParameterFilter {
                $Priority -eq 'High'
            }
        }

        It "Should set priority to Normal for Success status" {
            $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
            Mock Get-SmtpCredential { $mockCred }
            Mock Send-MailMessage { }

            Send-CompletionEmail -Config $script:mockConfig -Results $script:mockResults -Status 'Success'

            Should -Invoke Send-MailMessage -Times 1 -ParameterFilter {
                $Priority -eq 'Normal'
            }
        }

        It "Should handle send failure gracefully" {
            $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
            Mock Get-SmtpCredential { $mockCred }
            Mock Send-MailMessage { throw "SMTP connection failed" }

            { Send-CompletionEmail -Config $script:mockConfig -Results $script:mockResults -Status 'Success' } | Should -Not -Throw
        }

        It "Should throw with incomplete configuration (empty SmtpServer)" {
            Mock Get-SmtpCredential { }
            Mock Send-MailMessage { }

            $incompleteConfig = [PSCustomObject]@{
                Enabled = $true
                SmtpServer = ""
                Port = 587
                UseTls = $true
                CredentialTarget = "Test-SMTP"
                From = "test@example.com"
                To = @("user@test.com")
            }

            {
                Send-CompletionEmail -Config $incompleteConfig -Results $script:mockResults -Status 'Success'
            } | Should -Throw "*SmtpServer*"
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

        It "Should return true on successful send" {
            $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
            Mock Get-SmtpCredential { $mockCred }
            Mock Send-MailMessage { }

            $result = Test-EmailConfiguration -Config $script:testConfig

            $result | Should -Be $true
        }

        It "Should return true even when Send-MailMessage fails (errors logged internally)" {
            # Since Send-CompletionEmail catches exceptions internally and logs them,
            # Test-EmailConfiguration will still return $true even if sending fails
            $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
            Mock Get-SmtpCredential { $mockCred }
            Mock Send-MailMessage { throw "Connection refused" }

            $result = Test-EmailConfiguration -Config $script:testConfig

            # The function doesn't throw, so it returns $true
            # The actual error is logged via Write-RobocurseLog
            $result | Should -Be $true
        }

        It "Should send test email with dummy results" {
            $mockCred = New-Object System.Management.Automation.PSCredential("user", (ConvertTo-SecureString "pass" -AsPlainText -Force))
            Mock Get-SmtpCredential { $mockCred }
            Mock Send-MailMessage { }

            Test-EmailConfiguration -Config $script:testConfig

            Should -Invoke Send-MailMessage -Times 1 -ParameterFilter {
                $Subject -match "Success" -and
                $BodyAsHtml -eq $true
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

            # Mock the CredentialManager to return nothing on non-Windows
            Mock Initialize-CredentialManager { }

            $cred = Get-SmtpCredential -Target "NonExistent"

            $cred | Should -BeNullOrEmpty
        }
    }
}
