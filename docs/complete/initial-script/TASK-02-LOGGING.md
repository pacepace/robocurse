# Task 02: Logging System

## Overview
Implement dual-format logging: human-readable operational logs and SIEM-compatible JSON Lines audit logs, plus log rotation.

## Research Required

### Web Research
- JSON Lines format specification: https://jsonlines.org/
- PowerShell transcript logging
- File locking considerations for concurrent writes
- SIEM log field best practices (timestamp format, event types)

### Key Concepts
- ISO 8601 timestamp format: `2024-01-15T14:32:45.123Z`
- JSON Lines: one JSON object per line, newline-delimited
- Log rotation: compress old, delete ancient

## Task Description

Implement the Logging region with these functions:

### Function: Write-RobocurseLog
```powershell
function Write-RobocurseLog {
    <#
    .SYNOPSIS
        Writes to operational log and optionally SIEM log
    .PARAMETER Message
        Log message
    .PARAMETER Level
        Log level: Debug, Info, Warning, Error
    .PARAMETER Component
        Which component is logging (Orchestrator, Chunker, etc.)
    .PARAMETER SessionId
        Correlation ID for the current session
    .PARAMETER WriteSiem
        Also write a SIEM event (default: true for Warning/Error)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [string]$Component = 'General',

        [string]$SessionId = $script:CurrentSessionId,

        [bool]$WriteSiem = ($Level -in @('Warning', 'Error'))
    )
    # Implementation here
}
```

**Log Format (Operational):**
```
2024-01-15 14:32:45 [INFO] [Orchestrator] Starting sync for profile "User Directories"
2024-01-15 14:32:46 [INFO] [Chunker] Found 234 chunks to process
2024-01-15 14:35:12 [WARNING] [Robocopy] Chunk 15 completed with warnings (exit code 4)
2024-01-15 14:40:00 [ERROR] [Robocopy] Chunk 23 failed: Access denied
```

### Function: Write-SiemEvent
```powershell
function Write-SiemEvent {
    <#
    .SYNOPSIS
        Writes a SIEM-compatible JSON event
    .PARAMETER EventType
        Event type: SessionStart, SessionEnd, ChunkStart, ChunkComplete, ChunkError, etc.
    .PARAMETER Data
        Hashtable of event-specific data
    .PARAMETER SessionId
        Correlation ID
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('SessionStart', 'SessionEnd', 'ProfileStart', 'ProfileComplete',
                     'ChunkStart', 'ChunkComplete', 'ChunkError', 'ConfigChange')]
        [string]$EventType,

        [hashtable]$Data = @{},

        [string]$SessionId = $script:CurrentSessionId
    )
    # Implementation here
}
```

**SIEM Event Schema:**
```json
{"timestamp":"2024-01-15T14:32:45.123Z","event":"SessionStart","sessionId":"abc-123","user":"DOMAIN\\user","machine":"SERVER01","data":{}}
{"timestamp":"2024-01-15T14:32:46.001Z","event":"ChunkStart","sessionId":"abc-123","chunkId":1,"source":"\\\\server\\users$\\Anderson.John\\Documents","destination":"D:\\Backup\\Users\\Anderson.John\\Documents"}
{"timestamp":"2024-01-15T14:35:12.445Z","event":"ChunkComplete","sessionId":"abc-123","chunkId":1,"status":"Success","exitCode":1,"filesCopied":2341,"bytesCopied":4294967296,"durationMs":146444}
{"timestamp":"2024-01-15T14:35:12.500Z","event":"ChunkError","sessionId":"abc-123","chunkId":2,"errorType":"AccessDenied","path":"\\\\server\\users$\\Baker.Mary\\locked.pst","message":"Access denied"}
```

### Function: Initialize-LogSession
```powershell
function Initialize-LogSession {
    <#
    .SYNOPSIS
        Creates log directory for today, generates session ID, initializes log files
    .PARAMETER LogRoot
        Root directory for logs
    .OUTPUTS
        Hashtable with SessionId, OperationalLogPath, SiemLogPath
    #>
    param(
        [string]$LogRoot = ".\Logs"
    )
    # Implementation here
}
```

**Directory Structure:**
```
Logs/
├── 2024-01-15/
│   ├── Session_143245.log        # Operational log
│   ├── Audit_143245.jsonl        # SIEM log
│   └── Jobs/
│       ├── Chunk_001.log         # Robocopy output
│       └── Chunk_002.log
├── 2024-01-14.zip                # Compressed old logs
└── 2024-01-10.zip
```

### Function: Invoke-LogRotation
```powershell
function Invoke-LogRotation {
    <#
    .SYNOPSIS
        Compresses old logs and deletes ancient ones
    .PARAMETER LogRoot
        Root directory for logs
    .PARAMETER CompressAfterDays
        Compress logs older than this (default: 7)
    .PARAMETER DeleteAfterDays
        Delete logs older than this (default: 30)
    #>
    param(
        [string]$LogRoot = ".\Logs",
        [int]$CompressAfterDays = 7,
        [int]$DeleteAfterDays = 30
    )
    # Implementation here
}
```

**Requirements:**
- Compress daily folders to .zip after CompressAfterDays
- Delete .zip files after DeleteAfterDays
- Log rotation errors should not crash the main sync
- Skip currently-in-use log directories

### Function: Get-LogPath
```powershell
function Get-LogPath {
    <#
    .SYNOPSIS
        Gets path for a specific log type
    .PARAMETER Type
        Log type: Operational, Siem, ChunkJob
    .PARAMETER ChunkId
        Required for ChunkJob type
    #>
    param(
        [ValidateSet('Operational', 'Siem', 'ChunkJob')]
        [string]$Type,

        [int]$ChunkId
    )
    # Implementation here
}
```

## Success Criteria

1. [ ] `Write-RobocurseLog` writes formatted lines to operational log
2. [ ] `Write-SiemEvent` writes valid JSON Lines to audit log
3. [ ] `Initialize-LogSession` creates directory structure and returns paths
4. [ ] `Invoke-LogRotation` compresses old directories
5. [ ] `Invoke-LogRotation` deletes archives past retention
6. [ ] Log files can be written to concurrently (from multiple chunks)
7. [ ] Malformed/missing log directory doesn't crash the system

## Pester Tests Required

Create `tests/Unit/Logging.Tests.ps1`:

```powershell
Describe "Logging" {
    BeforeAll {
        . "$PSScriptRoot\..\..\Robocurse.ps1" -Help
    }

    BeforeEach {
        $script:TestLogRoot = "$TestDrive\Logs"
    }

    Context "Initialize-LogSession" {
        It "Should create log directory structure" {
            $session = Initialize-LogSession -LogRoot $script:TestLogRoot

            Test-Path $session.OperationalLogPath | Should -Be $true
            Test-Path $session.SiemLogPath | Should -Be $true
            $session.SessionId | Should -Not -BeNullOrEmpty
        }

        It "Should generate unique session IDs" {
            $session1 = Initialize-LogSession -LogRoot $script:TestLogRoot
            Start-Sleep -Milliseconds 100
            $session2 = Initialize-LogSession -LogRoot $script:TestLogRoot

            $session1.SessionId | Should -Not -Be $session2.SessionId
        }
    }

    Context "Write-RobocurseLog" {
        BeforeEach {
            $script:Session = Initialize-LogSession -LogRoot $script:TestLogRoot
        }

        It "Should write formatted log entry" {
            Write-RobocurseLog -Message "Test message" -Level "Info" -Component "Test"

            $content = Get-Content $script:Session.OperationalLogPath
            $content | Should -Match "Test message"
            $content | Should -Match "\[INFO\]"
            $content | Should -Match "\[Test\]"
        }

        It "Should include timestamp" {
            Write-RobocurseLog -Message "Timestamp test" -Level "Info"

            $content = Get-Content $script:Session.OperationalLogPath
            $content | Should -Match "\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"
        }
    }

    Context "Write-SiemEvent" {
        BeforeEach {
            $script:Session = Initialize-LogSession -LogRoot $script:TestLogRoot
        }

        It "Should write valid JSON" {
            Write-SiemEvent -EventType "SessionStart" -Data @{ test = "value" }

            $content = Get-Content $script:Session.SiemLogPath
            { $content | ConvertFrom-Json } | Should -Not -Throw
        }

        It "Should include required SIEM fields" {
            Write-SiemEvent -EventType "SessionStart" -Data @{ }

            $content = Get-Content $script:Session.SiemLogPath
            $event = $content | ConvertFrom-Json

            $event.timestamp | Should -Not -BeNullOrEmpty
            $event.event | Should -Be "SessionStart"
            $event.sessionId | Should -Not -BeNullOrEmpty
            $event.user | Should -Not -BeNullOrEmpty
            $event.machine | Should -Not -BeNullOrEmpty
        }

        It "Should use ISO 8601 timestamp format" {
            Write-SiemEvent -EventType "SessionStart"

            $content = Get-Content $script:Session.SiemLogPath
            $event = $content | ConvertFrom-Json

            # ISO 8601 format: 2024-01-15T14:32:45.123Z
            $event.timestamp | Should -Match "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"
        }
    }

    Context "Invoke-LogRotation" {
        It "Should compress old directories" {
            # Create old log directory
            $oldDate = (Get-Date).AddDays(-10).ToString("yyyy-MM-dd")
            $oldDir = New-Item -Path "$script:TestLogRoot\$oldDate" -ItemType Directory
            "test" | Set-Content "$oldDir\test.log"

            Invoke-LogRotation -LogRoot $script:TestLogRoot -CompressAfterDays 7

            Test-Path "$script:TestLogRoot\$oldDate.zip" | Should -Be $true
            Test-Path "$script:TestLogRoot\$oldDate" | Should -Be $false
        }

        It "Should delete ancient archives" {
            # Create very old archive
            $ancientDate = (Get-Date).AddDays(-60).ToString("yyyy-MM-dd")
            $null = New-Item -Path "$script:TestLogRoot\$ancientDate.zip" -ItemType File

            Invoke-LogRotation -LogRoot $script:TestLogRoot -DeleteAfterDays 30

            Test-Path "$script:TestLogRoot\$ancientDate.zip" | Should -Be $false
        }
    }
}
```

## Dependencies
- Task 00 (Project Structure)
- Task 01 (Configuration) - for log path settings

## Estimated Complexity
- Medium
- File I/O, date handling, compression
