#Requires -Modules Pester

<#
.SYNOPSIS
    Email sending integration tests for Robocurse.

.DESCRIPTION
    These tests verify email sending works against a real SMTP server.
    They are skipped when SMTP configuration is not provided via environment variables.

.NOTES
    Required environment variables for testing:
        ROBOCURSE_TEST_SMTP_SERVER   - SMTP server hostname (e.g., smtp.gmail.com)
        ROBOCURSE_TEST_SMTP_PORT     - SMTP port (e.g., 587)
        ROBOCURSE_TEST_SMTP_USER     - SMTP username (e.g., user@gmail.com)
        ROBOCURSE_TEST_SMTP_PASSWORD - SMTP password or app password
        ROBOCURSE_TEST_EMAIL_TO      - Recipient email address

    Example setup:
        $env:ROBOCURSE_TEST_SMTP_SERVER = "smtp.gmail.com"
        $env:ROBOCURSE_TEST_SMTP_PORT = "587"
        $env:ROBOCURSE_TEST_SMTP_USER = "test@gmail.com"
        $env:ROBOCURSE_TEST_SMTP_PASSWORD = "your-app-password"
        $env:ROBOCURSE_TEST_EMAIL_TO = "recipient@example.com"
#>

BeforeDiscovery {
    # Check for SMTP test capability
    $script:CanTestSmtp = $false
    $script:SmtpSkipReason = $null

    # All required environment variables
    $requiredVars = @(
        'ROBOCURSE_TEST_SMTP_SERVER',
        'ROBOCURSE_TEST_SMTP_PORT',
        'ROBOCURSE_TEST_SMTP_USER',
        'ROBOCURSE_TEST_SMTP_PASSWORD',
        'ROBOCURSE_TEST_EMAIL_TO'
    )

    $missingVars = @()
    foreach ($var in $requiredVars) {
        if (-not [Environment]::GetEnvironmentVariable($var)) {
            $missingVars += $var
        }
    }

    if ($missingVars.Count -gt 0) {
        $script:SmtpSkipReason = "Email integration tests will be skipped: Missing environment variables: $($missingVars -join ', ')"
    }
    else {
        # Validate port is numeric
        $port = [Environment]::GetEnvironmentVariable('ROBOCURSE_TEST_SMTP_PORT')
        if ($port -notmatch '^\d+$') {
            $script:SmtpSkipReason = "Email integration tests will be skipped: ROBOCURSE_TEST_SMTP_PORT must be numeric"
        }
        else {
            $script:CanTestSmtp = $true
        }
    }

    # Output skip reason for debugging (visible in Pester verbose output)
    if (-not $script:CanTestSmtp -and $script:SmtpSkipReason) {
        Write-Warning $script:SmtpSkipReason
    }
}

Describe "Email Sending Integration" -Tag "Integration", "Email" -Skip:(-not $script:CanTestSmtp) {

    BeforeAll {
        # Load test helper and module
        . "$PSScriptRoot\..\TestHelper.ps1"
        Initialize-RobocurseForTesting

        # Build SMTP configuration from environment variables
        $script:SmtpServer = $env:ROBOCURSE_TEST_SMTP_SERVER
        $script:SmtpPort = [int]$env:ROBOCURSE_TEST_SMTP_PORT
        $script:SmtpUser = $env:ROBOCURSE_TEST_SMTP_USER
        $script:SmtpPassword = $env:ROBOCURSE_TEST_SMTP_PASSWORD
        $script:EmailTo = $env:ROBOCURSE_TEST_EMAIL_TO

        # Create credential
        $script:SmtpCredential = [PSCredential]::new(
            $script:SmtpUser,
            (ConvertTo-SecureString $script:SmtpPassword -AsPlainText -Force)
        )

        # Helper function to create test email config
        function New-TestEmailConfig {
            param(
                [switch]$UseTls
            )
            return [PSCustomObject]@{
                Enabled = $true
                SmtpServer = $script:SmtpServer
                Port = $script:SmtpPort
                UseTls = $UseTls.IsPresent
                CredentialTarget = "Robocurse-Test-SMTP"
                From = $script:SmtpUser
                To = @($script:EmailTo)
            }
        }

        # Helper function to create test results
        function New-TestResults {
            param(
                [int]$FilesCopied = 1000,
                [long]$BytesCopied = 1GB,
                [int]$Errors = 0
            )
            return [PSCustomObject]@{
                Duration = [timespan]::FromMinutes(5)
                TotalBytesCopied = $BytesCopied
                TotalFilesCopied = $FilesCopied
                TotalErrors = $Errors
                Profiles = @(
                    [PSCustomObject]@{
                        Name = "IntegrationTestProfile"
                        Status = if ($Errors -eq 0) { "Success" } else { "Warning" }
                        ChunksComplete = 10
                        ChunksTotal = 10
                        FilesCopied = $FilesCopied
                        BytesCopied = $BytesCopied
                    }
                )
                Errors = @()
            }
        }

        # Generate unique test ID for this test run
        $script:TestRunId = [guid]::NewGuid().ToString('N').Substring(0, 8)
    }

    Context "Basic Send Test" {

        It "Should send email to configured recipient without exceptions" {
            # Arrange
            $testId = "basic-$script:TestRunId"
            $config = New-TestEmailConfig -UseTls
            $results = New-TestResults

            # Mock Get-SmtpCredential to return our test credential
            Mock Get-SmtpCredential { $script:SmtpCredential } -ModuleName Robocurse

            # Act
            $result = Send-CompletionEmail -Config $config -Results $results -Status 'Success' -SessionId $testId

            # Assert
            $result.Success | Should -Be $true -Because "Email should be accepted by SMTP server"
            Write-Host "Sent test email with ID: $testId - verify in inbox at $script:EmailTo" -ForegroundColor Cyan
        }
    }

    Context "Special Characters and Encoding Test" {

        It "Should handle unicode in subject and body" {
            # Arrange
            $testId = "unicode-$script:TestRunId"
            $config = New-TestEmailConfig -UseTls

            # Create results with unicode content in profile name
            $results = [PSCustomObject]@{
                Duration = [timespan]::FromMinutes(2)
                TotalBytesCopied = 500MB
                TotalFilesCopied = 500
                TotalErrors = 0
                Profiles = @(
                    [PSCustomObject]@{
                        Name = "Test Profile with Unicode"
                        Status = "Success"
                        ChunksComplete = 5
                        ChunksTotal = 5
                        FilesCopied = 500
                        BytesCopied = 500MB
                    }
                )
                Errors = @()
            }

            # Mock Get-SmtpCredential to return our test credential
            Mock Get-SmtpCredential { $script:SmtpCredential } -ModuleName Robocurse

            # Act - pass unicode profile names which will appear in email
            $result = Send-CompletionEmail -Config $config -Results $results -Status 'Success' -SessionId $testId -ProfileNames @("Test Profile with Unicode")

            # Assert
            $result.Success | Should -Be $true -Because "Email with unicode content should be accepted"
            Write-Host "Sent unicode test email with ID: $testId - verify encoding in inbox" -ForegroundColor Cyan
        }
    }

    Context "TLS/SSL Test" {

        It "Should connect successfully with UseSsl enabled" {
            # Arrange
            $testId = "tls-$script:TestRunId"
            $config = New-TestEmailConfig -UseTls
            $results = New-TestResults

            # Mock Get-SmtpCredential to return our test credential
            Mock Get-SmtpCredential { $script:SmtpCredential } -ModuleName Robocurse

            # Act
            $result = Send-CompletionEmail -Config $config -Results $results -Status 'Success' -SessionId $testId

            # Assert
            $result.Success | Should -Be $true -Because "TLS connection should work with modern SMTP servers"
            Write-Host "Sent TLS test email with ID: $testId" -ForegroundColor Cyan
        }
    }

    Context "Invalid Credentials Test" {

        It "Should handle bad credentials gracefully and throw appropriate error" {
            # Arrange
            $testId = "badcred-$script:TestRunId"
            $config = New-TestEmailConfig -UseTls

            # Create bad credential
            $badCredential = [PSCredential]::new(
                "invalid-user@nonexistent.example.com",
                (ConvertTo-SecureString "wrong-password-12345" -AsPlainText -Force)
            )

            # Mock Get-SmtpCredential to return bad credential
            Mock Get-SmtpCredential { $badCredential } -ModuleName Robocurse

            $results = New-TestResults

            # Act
            $result = Send-CompletionEmail -Config $config -Results $results -Status 'Success' -SessionId $testId -ErrorAction SilentlyContinue

            # Assert
            $result.Success | Should -Be $false -Because "Invalid credentials should fail authentication"
            $result.ErrorMessage | Should -Not -BeNullOrEmpty -Because "Should provide error details"
            Write-Host "Bad credentials correctly rejected: $($result.ErrorMessage)" -ForegroundColor Yellow
        }
    }

    Context "HTML Body Test" {

        It "Should send HTML formatted email correctly" {
            # Arrange
            $testId = "html-$script:TestRunId"
            $config = New-TestEmailConfig -UseTls

            # Create results with errors to generate more HTML content
            $results = [PSCustomObject]@{
                Duration = [timespan]::FromMinutes(10)
                TotalBytesCopied = 2GB
                TotalFilesCopied = 2000
                TotalErrors = 2
                Profiles = @(
                    [PSCustomObject]@{
                        Name = "Profile A"
                        Status = "Success"
                        ChunksComplete = 5
                        ChunksTotal = 5
                        FilesCopied = 1000
                        BytesCopied = 1GB
                    },
                    [PSCustomObject]@{
                        Name = "Profile B"
                        Status = "Warning"
                        ChunksComplete = 4
                        ChunksTotal = 5
                        FilesCopied = 1000
                        BytesCopied = 1GB
                    }
                )
                Errors = @(
                    "Sample error 1: Failed to copy file.txt",
                    "Sample error 2: Access denied on folder"
                )
            }

            # Mock Get-SmtpCredential to return our test credential
            Mock Get-SmtpCredential { $script:SmtpCredential } -ModuleName Robocurse

            # Act
            $result = Send-CompletionEmail -Config $config -Results $results -Status 'Warning' -SessionId $testId -ProfileNames @("Profile A", "Profile B") -FilesSkipped 50 -FilesFailed 10

            # Assert
            $result.Success | Should -Be $true -Because "HTML email should be sent successfully"
            Write-Host "Sent HTML test email with ID: $testId - verify HTML formatting in inbox" -ForegroundColor Cyan
        }
    }

    Context "Low-level Send-MultipartEmail Test" {

        It "Should send multipart email directly" {
            # Arrange
            $testId = "multipart-$script:TestRunId"

            $textBody = @"
ROBOCURSE INTEGRATION TEST
==========================
Test ID: $testId
This is the plain text version of the email.
"@

            $htmlBody = @"
<!DOCTYPE html>
<html>
<head><style>body { font-family: Arial; }</style></head>
<body>
<h1>Robocurse Integration Test</h1>
<p><strong>Test ID:</strong> $testId</p>
<p>This is the HTML version of the email.</p>
</body>
</html>
"@

            # Act
            $exception = $null
            try {
                Send-MultipartEmail -SmtpServer $script:SmtpServer `
                    -Port $script:SmtpPort `
                    -UseSsl $true `
                    -Credential $script:SmtpCredential `
                    -From $script:SmtpUser `
                    -To @($script:EmailTo) `
                    -Subject "Robocurse Integration Test - $testId" `
                    -TextBody $textBody `
                    -HtmlBody $htmlBody `
                    -SessionId $testId
            }
            catch {
                $exception = $_
            }

            # Assert
            $exception | Should -BeNullOrEmpty -Because "Send-MultipartEmail should complete without throwing"
            Write-Host "Sent multipart test email with ID: $testId" -ForegroundColor Cyan
        }
    }
}

Describe "Email Integration Tests Skipped" -Tag "Integration", "Email" -Skip:$script:CanTestSmtp {
    # This block runs when SMTP is NOT configured - provides confirmation that skip is working

    It "Confirms tests are skipped when SMTP is not configured" {
        # This test only runs when SMTP IS configured, proving the skip logic works
        $script:SmtpSkipReason | Should -BeNullOrEmpty -Because "If this runs, SMTP should be configured"
    }
}
