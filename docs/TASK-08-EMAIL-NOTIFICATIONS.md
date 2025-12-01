# Task 08: Email Notifications

## Overview
Implement authenticated SMTP email notifications with secure credential storage via Windows Credential Manager.

## Research Required

### Web Research
- Windows Credential Manager cmdlets (`cmdkey`, CredentialManager module)
- `Send-MailMessage` with TLS authentication
- PowerShell `[System.Net.NetworkCredential]` class
- HTML email templates

### Key Concepts
- **Credential Manager**: Windows secure credential storage
- **DPAPI**: Data Protection API (encrypts credentials per-user/machine)
- **TLS/STARTTLS**: Secure SMTP on port 587

## Task Description

### Function: Get-SmtpCredential
```powershell
function Get-SmtpCredential {
    <#
    .SYNOPSIS
        Retrieves SMTP credential from Windows Credential Manager
    .PARAMETER Target
        Credential target name (default: Robocurse-SMTP)
    .OUTPUTS
        PSCredential object or $null if not found
    #>
    param(
        [string]$Target = "Robocurse-SMTP"
    )

    # Use cmdkey to check if credential exists
    # Or use .NET CredentialManager APIs

    # Option 1: Using stored credential via cmdkey
    # cmdkey /list:$Target

    # Option 2: Using .NET (more reliable)
    Add-Type -AssemblyName System.Runtime.InteropServices

    # P/Invoke to CredRead
    # ... (implementation details)

    # For simplicity, use the CredentialManager module if available
    # Or implement native P/Invoke
}
```

### Native Credential Manager Implementation
```powershell
# Add the necessary .NET types for Credential Manager
$credManagerCode = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class CredentialManager {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool CredFree(IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredWrite(ref CREDENTIAL credential, int flags);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool CredDelete(string target, int type, int flags);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    public const int CRED_TYPE_GENERIC = 1;
    public const int CRED_PERSIST_LOCAL_MACHINE = 2;
}
"@

Add-Type -TypeDefinition $credManagerCode -Language CSharp
```

### Function: Save-SmtpCredential
```powershell
function Save-SmtpCredential {
    <#
    .SYNOPSIS
        Saves SMTP credential to Windows Credential Manager
    .PARAMETER Target
        Credential target name
    .PARAMETER Credential
        PSCredential to save
    #>
    param(
        [string]$Target = "Robocurse-SMTP",

        [Parameter(Mandatory)]
        [PSCredential]$Credential
    )

    # Save using CredWrite or cmdkey
    # cmdkey /add:$Target /user:$username /pass:$password
}
```

### Function: Remove-SmtpCredential
```powershell
function Remove-SmtpCredential {
    <#
    .SYNOPSIS
        Removes SMTP credential from Credential Manager
    .PARAMETER Target
        Credential target name
    #>
    param(
        [string]$Target = "Robocurse-SMTP"
    )

    # cmdkey /delete:$Target
}
```

### Function: Test-SmtpCredential
```powershell
function Test-SmtpCredential {
    <#
    .SYNOPSIS
        Tests if SMTP credential exists and is valid
    .PARAMETER Target
        Credential target name
    .OUTPUTS
        $true if credential exists, $false otherwise
    #>
    param(
        [string]$Target = "Robocurse-SMTP"
    )

    $cred = Get-SmtpCredential -Target $Target
    return ($null -ne $cred)
}
```

### Function: Send-CompletionEmail
```powershell
function Send-CompletionEmail {
    <#
    .SYNOPSIS
        Sends completion notification email
    .PARAMETER Config
        Email configuration from Robocurse config
    .PARAMETER Results
        Replication results summary
    .PARAMETER Status
        Overall status: Success, Warning, Failed
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory)]
        [PSCustomObject]$Results,

        [ValidateSet('Success', 'Warning', 'Failed')]
        [string]$Status = 'Success'
    )

    if (-not $Config.Enabled) {
        Write-RobocurseLog -Message "Email notifications disabled" -Level 'Debug' -Component 'Email'
        return
    }

    # Get credential
    $credential = Get-SmtpCredential -Target $Config.CredentialTarget
    if (-not $credential) {
        Write-RobocurseLog -Message "SMTP credential not found" -Level 'Error' -Component 'Email'
        return
    }

    # Build email
    $subject = "Robocurse: Replication $Status - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $body = New-CompletionEmailBody -Results $Results -Status $Status

    # Set priority based on status
    $priority = switch ($Status) {
        'Success' { 'Normal' }
        'Warning' { 'Normal' }
        'Failed'  { 'High' }
    }

    try {
        $mailParams = @{
            SmtpServer = $Config.SmtpServer
            Port = $Config.Port
            UseSsl = $Config.UseTls
            Credential = $credential
            From = $Config.From
            To = $Config.To
            Subject = $subject
            Body = $body
            BodyAsHtml = $true
            Priority = $priority
        }

        Send-MailMessage @mailParams

        Write-RobocurseLog -Message "Completion email sent to $($Config.To -join ', ')" -Level 'Info' -Component 'Email'
        Write-SiemEvent -EventType 'EmailSent' -Data @{ recipients = $Config.To; status = $Status }
    }
    catch {
        Write-RobocurseLog -Message "Failed to send email: $_" -Level 'Error' -Component 'Email'
    }
}
```

### Function: New-CompletionEmailBody
```powershell
function New-CompletionEmailBody {
    <#
    .SYNOPSIS
        Creates HTML email body from results
    .PARAMETER Results
        Replication results
    .PARAMETER Status
        Overall status
    .OUTPUTS
        HTML string
    #>
    param(
        [PSCustomObject]$Results,
        [string]$Status
    )

    $statusColor = switch ($Status) {
        'Success' { '#4CAF50' }  # Green
        'Warning' { '#FF9800' }  # Orange
        'Failed'  { '#F44336' }  # Red
    }

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }
        .container { max-width: 600px; margin: 0 auto; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .header { background: $statusColor; color: white; padding: 20px; }
        .header h1 { margin: 0; font-size: 24px; }
        .content { padding: 20px; }
        .stat-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; margin: 20px 0; }
        .stat-box { background: #f9f9f9; padding: 15px; border-radius: 4px; }
        .stat-label { font-size: 12px; color: #666; text-transform: uppercase; }
        .stat-value { font-size: 24px; font-weight: bold; color: #333; }
        .profile-list { margin: 20px 0; }
        .profile-item { padding: 10px; border-bottom: 1px solid #eee; }
        .profile-success { border-left: 3px solid #4CAF50; }
        .profile-warning { border-left: 3px solid #FF9800; }
        .profile-failed { border-left: 3px solid #F44336; }
        .footer { background: #f5f5f5; padding: 15px; text-align: center; font-size: 12px; color: #666; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Robocurse Replication $Status</h1>
        </div>
        <div class="content">
            <p>Replication completed at <strong>$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</strong></p>

            <div class="stat-grid">
                <div class="stat-box">
                    <div class="stat-label">Duration</div>
                    <div class="stat-value">$($Results.Duration.ToString('hh\:mm\:ss'))</div>
                </div>
                <div class="stat-box">
                    <div class="stat-label">Data Copied</div>
                    <div class="stat-value">$(Format-FileSize $Results.TotalBytesCopied)</div>
                </div>
                <div class="stat-box">
                    <div class="stat-label">Files Copied</div>
                    <div class="stat-value">$($Results.TotalFilesCopied.ToString('N0'))</div>
                </div>
                <div class="stat-box">
                    <div class="stat-label">Errors</div>
                    <div class="stat-value">$($Results.TotalErrors)</div>
                </div>
            </div>

            <h3>Profile Summary</h3>
            <div class="profile-list">
$(foreach ($profile in $Results.Profiles) {
    $class = switch ($profile.Status) { 'Success' { 'profile-success' } 'Warning' { 'profile-warning' } 'Failed' { 'profile-failed' } }
@"
                <div class="profile-item $class">
                    <strong>$($profile.Name)</strong><br>
                    Chunks: $($profile.ChunksComplete)/$($profile.ChunksTotal) |
                    Files: $($profile.FilesCopied.ToString('N0')) |
                    Size: $(Format-FileSize $profile.BytesCopied)
                </div>
"@
})
            </div>

            $(if ($Results.Errors.Count -gt 0) {
@"
            <h3 style="color: #F44336;">Errors</h3>
            <ul>
$(foreach ($error in $Results.Errors | Select-Object -First 10) {
                "<li>$([System.Web.HttpUtility]::HtmlEncode($error))</li>"
})
            </ul>
            $(if ($Results.Errors.Count -gt 10) { "<p><em>... and $($Results.Errors.Count - 10) more errors. See logs for details.</em></p>" })
"@
            })
        </div>
        <div class="footer">
            Generated by Robocurse | Machine: $env:COMPUTERNAME
        </div>
    </div>
</body>
</html>
"@

    return $html
}
```

### Function: Test-EmailConfiguration
```powershell
function Test-EmailConfiguration {
    <#
    .SYNOPSIS
        Sends a test email to verify configuration
    .PARAMETER Config
        Email configuration
    .OUTPUTS
        $true if successful, error message if failed
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $testResults = [PSCustomObject]@{
        Duration = [timespan]::FromMinutes(5)
        TotalBytesCopied = 1073741824
        TotalFilesCopied = 1000
        TotalErrors = 0
        Profiles = @(
            [PSCustomObject]@{ Name = "Test Profile"; Status = "Success"; ChunksComplete = 10; ChunksTotal = 10; FilesCopied = 1000; BytesCopied = 1073741824 }
        )
        Errors = @()
    }

    try {
        Send-CompletionEmail -Config $Config -Results $testResults -Status 'Success'
        return $true
    }
    catch {
        return "Failed: $_"
    }
}
```

## Success Criteria

1. [ ] Credentials stored securely in Windows Credential Manager
2. [ ] Credentials retrieved correctly for sending
3. [ ] Authenticated SMTP with TLS works
4. [ ] HTML emails render correctly
5. [ ] Test email function works
6. [ ] Errors handled gracefully (don't crash if email fails)

## Pester Tests Required

Create `tests/Unit/EmailNotifications.Tests.ps1`:

```powershell
Describe "Email Notifications" {
    BeforeAll {
        . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
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
            $html | Should -Match "Warning"
            $html | Should -Match "Error 1"
        }

        It "Should use correct status colors" {
            $results = [PSCustomObject]@{ Duration = [timespan]::Zero; TotalBytesCopied = 0; TotalFilesCopied = 0; TotalErrors = 0; Profiles = @(); Errors = @() }

            $successHtml = New-CompletionEmailBody -Results $results -Status 'Success'
            $failedHtml = New-CompletionEmailBody -Results $results -Status 'Failed'

            $successHtml | Should -Match "#4CAF50"  # Green
            $failedHtml | Should -Match "#F44336"   # Red
        }
    }

    Context "Send-CompletionEmail" {
        It "Should not send when disabled" {
            Mock Send-MailMessage { }

            $config = [PSCustomObject]@{ Enabled = $false }
            Send-CompletionEmail -Config $config -Results @{} -Status 'Success'

            Should -Not -Invoke Send-MailMessage
        }

        It "Should handle missing credential gracefully" {
            Mock Get-SmtpCredential { $null }
            Mock Send-MailMessage { }

            $config = [PSCustomObject]@{ Enabled = $true; CredentialTarget = "NonExistent" }

            { Send-CompletionEmail -Config $config -Results @{} -Status 'Success' } | Should -Not -Throw
            Should -Not -Invoke Send-MailMessage
        }
    }
}
```

## Dependencies
- Task 00 (Project Structure)
- Task 02 (Logging)
- Task 06 (Orchestration) - for results format

## Estimated Complexity
- Medium
- Windows API interaction, HTML generation
