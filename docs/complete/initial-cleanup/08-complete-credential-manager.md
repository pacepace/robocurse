# Task 08: Complete and Test Credential Manager Implementation

## Priority: MEDIUM

## Problem Statement

The credential manager code in `Robocurse.ps1` appears to be incomplete. The P/Invoke struct definition is truncated, and it's unclear if `Get-SmtpCredential` and `Save-SmtpCredential` are fully implemented.

From what was visible:
```powershell
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CREDENTIAL {
    public int Flags;
    public int Type;
    public string TargetName;
    public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public int CredentialBlobSize;
    public IntPtr CredentialBlob;
    # ... possibly truncated ...
```

## Research Required

### Code Research
1. Read the complete EMAIL region in `Robocurse.ps1`:
   - Find `Initialize-CredentialManager` and read the full C# code
   - Find `Get-SmtpCredential` function
   - Find `Save-SmtpCredential` function
   - Find `Test-SmtpCredential` function

2. Review `tests/Unit/EmailNotifications.Tests.ps1`:
   - What credential tests exist?
   - How are credentials mocked?
   - Is there coverage for environment variable fallback?

3. Check for Windows Credential Manager structure:
   - CREDENTIAL struct needs: Persist, UserName, TargetAlias
   - Verify complete definition

### Expected Credential Manager Functions
```powershell
function Initialize-CredentialManager { }  # Sets up P/Invoke types
function Get-SmtpCredential { }             # Retrieves from Windows Credential Manager
function Save-SmtpCredential { }            # Stores in Windows Credential Manager
function Test-SmtpCredential { }            # Checks if credential exists
function Remove-SmtpCredential { }          # Deletes credential (may not exist)
```

### Windows Credential Manager API
The complete CREDENTIAL struct should be:
```csharp
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
```

## Implementation Verification Checklist

### 1. Initialize-CredentialManager
- [ ] Complete CREDENTIAL struct with all fields
- [ ] CredRead function import
- [ ] CredWrite function import
- [ ] CredFree function import
- [ ] CredDelete function import
- [ ] Only runs on Windows

### 2. Get-SmtpCredential
- [ ] Takes Target parameter
- [ ] Returns PSCredential object or $null
- [ ] Falls back to environment variables (ROBOCURSE_SMTP_USER, ROBOCURSE_SMTP_PASS)
- [ ] Handles Windows Credential Manager unavailable (non-Windows)
- [ ] Properly frees memory after CredRead

### 3. Save-SmtpCredential
- [ ] Takes Target and Credential parameters
- [ ] Converts PSCredential to CREDENTIAL struct
- [ ] Handles Persist type (LocalMachine vs Session)
- [ ] Returns $true on success, $false on failure
- [ ] Only works on Windows (logs warning otherwise)

### 4. Test-SmtpCredential
- [ ] Takes Target parameter
- [ ] Returns $true if credential exists
- [ ] Returns $false if not found or error
- [ ] Works with environment variable fallback

## Files to Review

- `Robocurse.ps1` - Email region (approximately lines 2449+)
- `tests/Unit/EmailNotifications.Tests.ps1` - Existing credential tests

## Files to Modify

- `Robocurse.ps1` - Complete any missing credential functions
- `tests/Unit/EmailNotifications.Tests.ps1` - Add missing tests

## Test Cases Required

```powershell
Describe "Credential Manager" {
    Context "Get-SmtpCredential" {
        It "Should return null when no credential exists" {
            Mock Initialize-CredentialManager { }
            $cred = Get-SmtpCredential -Target "NonExistent"
            $cred | Should -BeNullOrEmpty
        }

        It "Should fall back to environment variables" {
            try {
                $env:ROBOCURSE_SMTP_USER = "testuser"
                $env:ROBOCURSE_SMTP_PASS = "testpass"

                $cred = Get-SmtpCredential -Target "NonExistent"

                $cred | Should -Not -BeNullOrEmpty
                $cred.UserName | Should -Be "testuser"
            }
            finally {
                $env:ROBOCURSE_SMTP_USER = $null
                $env:ROBOCURSE_SMTP_PASS = $null
            }
        }
    }

    Context "Save-SmtpCredential" -Skip:(-not $IsWindows) {
        It "Should save and retrieve credential" {
            $testTarget = "Robocurse-Test-$(Get-Random)"
            $securePass = ConvertTo-SecureString "TestPassword" -AsPlainText -Force
            $cred = New-Object PSCredential("TestUser", $securePass)

            try {
                $saved = Save-SmtpCredential -Target $testTarget -Credential $cred
                $saved | Should -Be $true

                $retrieved = Get-SmtpCredential -Target $testTarget
                $retrieved.UserName | Should -Be "TestUser"
            }
            finally {
                # Cleanup
                Remove-SmtpCredential -Target $testTarget -ErrorAction SilentlyContinue
            }
        }
    }
}
```

## Success Criteria

1. [ ] CREDENTIAL struct is complete with all 12 fields
2. [ ] Initialize-CredentialManager compiles without errors
3. [ ] Get-SmtpCredential returns PSCredential on success, $null on failure
4. [ ] Environment variable fallback works correctly
5. [ ] Save-SmtpCredential works on Windows
6. [ ] Test-SmtpCredential works correctly
7. [ ] Non-Windows platforms handle gracefully (no crashes)
8. [ ] All EmailNotifications tests pass
9. [ ] Tests can be run with: `Invoke-Pester -Path tests/Unit/EmailNotifications.Tests.ps1`

## Testing Commands

```powershell
# Run email notification tests
Invoke-Pester -Path tests/Unit/EmailNotifications.Tests.ps1 -Output Detailed

# Test credential functions manually (Windows only)
. .\Robocurse.ps1 -Help

# Test environment variable fallback
$env:ROBOCURSE_SMTP_USER = "test"
$env:ROBOCURSE_SMTP_PASS = "pass"
$cred = Get-SmtpCredential -Target "Test"
$cred.UserName  # Should be "test"
```

## Estimated Complexity

Medium - Requires understanding P/Invoke patterns and Windows Credential Manager.

## Platform Notes

- **Windows**: Full functionality with Credential Manager
- **macOS/Linux**: Only environment variable fallback works
- Tests should skip Windows-specific tests on other platforms
