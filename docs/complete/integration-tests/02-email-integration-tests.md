# Task: Email Sending Integration Tests

## Objective
Add integration tests that verify email sending works with a real SMTP server. Currently, email tests mock `Send-MailMessage` and SMTP connections, so they don't catch real-world issues like TLS negotiation failures, authentication problems, or encoding issues.

## Problem Statement
The email notification system has unit tests that:
- Mock `Send-MailMessage` to always succeed
- Mock credential retrieval
- Never actually connect to an SMTP server

Real-world issues that could slip through:
- TLS/SSL configuration problems
- Credential encoding issues
- Body/subject encoding for special characters
- Attachment handling
- SMTP server compatibility

## Success Criteria
1. Integration tests can be run against a real SMTP server (configurable)
2. Tests skip gracefully when SMTP not configured (like remote VSS tests)
3. Tests verify actual email delivery to a test mailbox
4. Tests verify email content (subject, body, attachments) is correct
5. Tests are tagged appropriately for selective execution

## Research: Current Implementation

### Email Function (src/Robocurse/Public/Email.ps1)
```powershell
function Send-CompletionEmail {
    param(
        [string]$SmtpServer,
        [int]$SmtpPort,
        [string]$From,
        [string[]]$To,
        [PSCredential]$Credential,
        ...
    )

    # Build email message
    $mailParams = @{
        SmtpServer = $SmtpServer
        Port = $SmtpPort
        From = $From
        To = $To
        Subject = $subject
        Body = $body
        BodyAsHtml = $true
    }

    # Send with TLS
    if ($UseSsl) {
        $mailParams['UseSsl'] = $true
    }

    Send-MailMessage @mailParams -Credential $Credential
}
```

### Current Unit Tests (tests/Unit/EmailNotifications.Tests.ps1)
```powershell
Mock Send-MailMessage { }  # Always succeeds
Mock Get-StoredCredential { ... mock credential ... }

It "Should send email on successful completion" {
    # Only verifies mock was called, not actual delivery
    Assert-MockCalled Send-MailMessage -Times 1
}
```

### Remote VSS Skip Pattern (tests/Unit/VssSnapshotRemote.Tests.ps1)
```powershell
BeforeAll {
    if (-not $env:ROBOCURSE_TEST_REMOTE_SHARE) {
        Write-Warning "Remote VSS tests will be skipped..."
    }
}

It "Should create remote snapshot" -Skip:(-not $env:ROBOCURSE_TEST_REMOTE_SHARE) {
    ...
}
```

## Implementation Plan

### Step 1: Define Environment Variables
Tests require SMTP configuration via environment:
```
ROBOCURSE_TEST_SMTP_SERVER=smtp.example.com
ROBOCURSE_TEST_SMTP_PORT=587
ROBOCURSE_TEST_SMTP_USER=test@example.com
ROBOCURSE_TEST_SMTP_PASSWORD=secretpassword
ROBOCURSE_TEST_EMAIL_TO=recipient@example.com
```

### Step 2: Create Skip Logic
```powershell
BeforeAll {
    $script:SmtpConfigured = (
        $env:ROBOCURSE_TEST_SMTP_SERVER -and
        $env:ROBOCURSE_TEST_SMTP_USER -and
        $env:ROBOCURSE_TEST_SMTP_PASSWORD -and
        $env:ROBOCURSE_TEST_EMAIL_TO
    )

    if (-not $script:SmtpConfigured) {
        Write-Warning "Email integration tests will be skipped: SMTP environment not configured"
    }
}
```

### Step 3: Add Basic Send Test
```powershell
Describe "Email Sending Integration" -Tag "Integration", "Email" {
    It "Should send email to configured recipient" -Skip:(-not $script:SmtpConfigured) {
        $credential = [PSCredential]::new(
            $env:ROBOCURSE_TEST_SMTP_USER,
            (ConvertTo-SecureString $env:ROBOCURSE_TEST_SMTP_PASSWORD -AsPlainText -Force)
        )

        $testId = [guid]::NewGuid().ToString('N').Substring(0,8)
        $subject = "Robocurse Test Email - $testId"

        $result = Send-CompletionEmail `
            -SmtpServer $env:ROBOCURSE_TEST_SMTP_SERVER `
            -SmtpPort ($env:ROBOCURSE_TEST_SMTP_PORT -as [int] ?? 587) `
            -From $env:ROBOCURSE_TEST_SMTP_USER `
            -To $env:ROBOCURSE_TEST_EMAIL_TO `
            -Credential $credential `
            -Subject $subject `
            -ProfileName "TestProfile" `
            -Status "Completed" `
            -UseSsl

        # If no exception, email was accepted by SMTP server
        # Manual verification: check inbox for email with $testId
        Write-Host "Sent test email with ID: $testId - verify in inbox"
    }
}
```

### Step 4: Add Encoding Test
```powershell
It "Should handle special characters in subject/body" -Skip:(-not $script:SmtpConfigured) {
    $subject = "Test: Привет 你好 🎉 Special Chars"
    # Send email with unicode content
    # Verify no encoding exceptions
}
```

### Step 5: Add TLS Test
```powershell
It "Should connect with TLS" -Skip:(-not $script:SmtpConfigured) {
    # Verify UseSsl parameter works
    # Most modern SMTP servers require TLS
}
```

### Step 6: Add Failure Scenario Test
```powershell
It "Should handle invalid credentials gracefully" -Skip:(-not $script:SmtpConfigured) {
    $badCredential = [PSCredential]::new("wrong", (ConvertTo-SecureString "wrong" -AsPlainText -Force))

    { Send-CompletionEmail -Credential $badCredential ... } | Should -Throw
}
```

## Test Plan
```powershell
# Set environment first
$env:ROBOCURSE_TEST_SMTP_SERVER = "smtp.gmail.com"
$env:ROBOCURSE_TEST_SMTP_PORT = "587"
$env:ROBOCURSE_TEST_SMTP_USER = "test@gmail.com"
$env:ROBOCURSE_TEST_SMTP_PASSWORD = "app-password"
$env:ROBOCURSE_TEST_EMAIL_TO = "recipient@example.com"

# Run email integration tests
Invoke-Pester -Path tests/Integration/Email.Integration.Tests.ps1 -Output Detailed
```

## Files to Create
| File | Purpose |
|------|---------|
| `tests/Integration/Email.Integration.Tests.ps1` | New integration test file |

## Verification
1. Tests skip cleanly when SMTP not configured
2. Tests send real emails when SMTP is configured
3. Emails arrive in recipient inbox with correct content
4. Invalid credentials are handled gracefully
5. Warning message appears when tests are skipped
