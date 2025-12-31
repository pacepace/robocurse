# Robocurse

**Parallel Robocopy Orchestration for Windows**

Robocurse manages what robocopy alone cannot: large-scale file replication across multiple sources without falling over. It intelligently chunks directories, runs parallel jobs, handles VSS snapshots for locked files, and recovers from failures—all without requiring expensive enterprise backup software.

> **Status**: Production-tested in enterprise environments. The core functionality is stable.

## The Problem

Robocopy is the go-to tool for Windows file copying and migration. But at scale, it breaks down:

- **Single-threaded orchestration**: One massive directory tree overwhelms a single robocopy process
- **No parallel job management**: Running multiple robocopy instances manually is tedious and error-prone
- **Locked file failures**: Production servers have open files that robocopy can't copy
- **No recovery**: Crash mid-job and you're starting over

Robocurse solves these problems with a single deployable PowerShell script.

## Key Features

| Feature | What It Does |
|---------|--------------|
| **Intelligent Chunking** | Splits large directories into optimal parallel workloads |
| **Parallel Execution** | Runs 1-128 concurrent robocopy jobs with load balancing |
| **VSS Integration** | Backs up locked files via Volume Shadow Copy (local and remote) |
| **Crash Recovery** | Checkpoints progress; resumes from last completed chunk |
| **GUI + Headless** | Interactive WPF interface or CLI for scheduled tasks |
| **Email Notifications** | Completion reports with statistics |
| **Bandwidth Throttling** | Aggregate limit across all concurrent jobs |
| **Per-Profile Scheduling** | Independent schedules for each profile (Hourly, Daily, Weekly, Monthly) |

## Download

### Stable Release (Recommended)

```powershell
# Full bundle (script + helper utilities + batch launchers)
iwr https://github.com/pacepace/robocurse/releases/latest/download/Robocurse.zip -OutFile Robocurse.zip

# Script only
iwr https://github.com/pacepace/robocurse/releases/latest/download/Robocurse.ps1 -OutFile Robocurse.ps1
```

Or browse [GitHub Releases](https://github.com/pacepace/robocurse/releases) for specific versions.

### Development Build

For the latest (potentially unstable) changes from the develop branch:
- Clone the repo and use `dist/Robocurse.ps1` (auto-built on every push to develop)
- Or build fresh: `.\build\Build-Robocurse.ps1`

---

## Quick Start

### 1. Deploy

Copy two files to your server:
```
Robocurse.ps1               # From Releases or dist/
Robocurse.config.json       # Your configuration (customize from template)
```

### 2. Configure

Edit `Robocurse.config.json`:

```json
{
  "Version": "1.0",
  "GlobalSettings": {
    "MaxConcurrentJobs": 4,
    "LogPath": ".\\Logs"
  },
  "SyncProfiles": [
    {
      "Name": "DailyBackup",
      "Source": "\\\\FILESERVER\\Share",
      "Destination": "D:\\Backups\\FileServer",
      "UseVss": true,
      "SourceSnapshot": {
        "PersistentEnabled": false,
        "RetentionCount": 3
      },
      "DestinationSnapshot": {
        "PersistentEnabled": true,
        "RetentionCount": 7
      },
      "RobocopyOptions": {
        "Switches": ["/COPYALL"],
        "ExcludeDirs": ["$RECYCLE.BIN", "System Volume Information"]
      }
    }
  ]
}
```

### 3. Run

**GUI mode:**
```powershell
.\Robocurse.ps1
```

**Headless (for scheduled tasks):**
```powershell
.\Robocurse.ps1 -Headless -Profile "DailyBackup"
```

**Dry run (preview without copying):**
```powershell
.\Robocurse.ps1 -Headless -Profile "DailyBackup" -DryRun
```

## Requirements

- Windows Server 2016+ or Windows 10+
- PowerShell 5.1+
- Administrator rights (for VSS)
- Robocopy (included with Windows)

No external dependencies. No modules to install. One file.

---

## Installation

### Step 1: Enable Script Execution

PowerShell's default execution policy blocks scripts. Choose one of these approaches:

**Option A: Code signing (recommended for production)**

Sign the script with a certificate so Windows trusts it. Run as Administrator:

```powershell
.\scripts\Sign-Robocurse.ps1 .\Robocurse.ps1
Set-ExecutionPolicy AllSigned -Scope LocalMachine
```

This creates a self-signed certificate, installs it to the trusted stores, and signs the script.
Re-run the signing script after each update to Robocurse.ps1.

**Option B: RemoteSigned policy**

Allows local scripts to run without signing:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
Unblock-File .\Robocurse.ps1
```

**Option C: Per-session bypass**

Run without changing any policies (useful for scheduled tasks):

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Robocurse.ps1
```

### Step 2: Deploy Files

Copy to your server:
```
Robocurse.ps1           # From Releases (stable) or dist/ (development)
Robocurse.config.json   # Your configuration (customize from template)
```

### Step 3: Configure SMTP Credentials (Optional)

If using email notifications, store SMTP credentials in Windows Credential Manager:

```powershell
# Interactive prompt for password
cmdkey /add:Robocurse-SMTP /user:smtp-user@example.com /pass

# Or specify password directly (less secure - visible in history)
cmdkey /add:Robocurse-SMTP /user:smtp-user@example.com /pass:YourPassword
```

Then reference in your config:
```json
"EmailSettings": {
  "SmtpServer": "smtp.example.com",
  "SmtpPort": 587,
  "UseTls": true,
  "CredentialName": "Robocurse-SMTP",
  "From": "robocurse@example.com",
  "To": ["admin@example.com"]
}
```

To verify stored credentials:
```powershell
cmdkey /list:Robocurse-SMTP
```

To remove credentials:
```powershell
cmdkey /delete:Robocurse-SMTP
```

### Server Setup Utilities

The `scripts/` folder includes utilities for configuring servers. All require Administrator privileges.

| Script | Purpose |
|--------|---------|
| `Sign-Robocurse.ps1` | Sign the script with a self-signed certificate for AllSigned execution policy |
| `Set-PsRemoting.ps1` | Enable/disable PowerShell Remoting with optional IP restrictions |
| `Set-FileSharing.ps1` | Enable/disable the LanmanServer service (SMB file sharing) |
| `Set-SmbFirewall.ps1` | Block/allow SMB ports 139 and 445 at the firewall level |

**Code signing** (for production servers):
```powershell
.\scripts\Sign-Robocurse.ps1 .\Robocurse.ps1
Set-ExecutionPolicy AllSigned -Scope LocalMachine
```

**Remote VSS setup** (on file servers you're backing up):
```powershell
.\scripts\Set-PsRemoting.ps1 -Enable -AllowedIPs "192.168.1.100"
```

**Connecting by IP address** (on the Robocurse machine):
```powershell
Start-Service WinRM
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.123.1" -Force
```

Run `Get-Help .\scripts\<script>.ps1 -Full` for detailed documentation.

---

## Configuration Reference

### Chunk Settings

Control how directories are split for parallel processing:

| Setting | Range | Default | Description |
|---------|-------|---------|-------------|
| `ChunkMaxSizeGB` | 0.001 - 1024 | 10 | Maximum GB per chunk |
| `ChunkMinSizeGB` | 0.001 - 1024 | 0.1 | Minimum GB to create a chunk |
| `ChunkMaxFiles` | 1 - 10M | 50,000 | Maximum files per chunk |
| `ChunkMaxDepth` | 0 - 20 | 5 | Maximum directory recursion |

### Robocopy Options

Per-profile robocopy customization:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `Switches` | string[] | `/COPY:DAT /DCOPY:T` | Additional robocopy flags |
| `ExcludeFiles` | string[] | `[]` | File patterns to skip (e.g., `*.tmp`) |
| `ExcludeDirs` | string[] | `[]` | Directory names to skip |
| `NoMirror` | bool | `false` | Use `/E` instead of `/MIR` |
| `SkipJunctions` | bool | `true` | Skip junction points |
| `RetryCount` | int | `3` | Retries per failed file |
| `RetryWait` | int | `10` | Seconds between retries |

**Note**: Robocurse manages `/MT:`, `/LOG:`, and progress flags automatically.

### Bandwidth Throttling

Limit aggregate bandwidth across all concurrent jobs:

```json
"GlobalSettings": {
  "MaxConcurrentJobs": 4,
  "BandwidthLimitMbps": 100
}
```

Bandwidth is dynamically divided among active jobs. Set to `0` for unlimited.

### Mismatch Handling

Control how robocopy exit code 4 (mismatches) is treated:

| Value | Behavior |
|-------|----------|
| `Warning` | (Default) Log warning, continue |
| `Error` | Treat as failure, trigger retry |
| `Success` | Ignore entirely |

Set globally or per-profile via `MismatchSeverity`.

### VSS Configuration

Robocurse offers two types of VSS snapshots:

| Type | Purpose | Lifetime |
|------|---------|----------|
| **Temporary (UseVss)** | Copy locked/open files during sync | Deleted immediately after job |
| **Persistent Snapshots** | Point-in-time recovery | Retained per your retention policy |

#### Per-Profile Snapshot Settings

Each profile can independently configure snapshots for both source and destination volumes:

```json
{
  "SyncProfiles": [
    {
      "Name": "DailyBackup",
      "Source": "\\\\FILESERVER\\Share",
      "Destination": "D:\\Backups",
      "UseVss": true,
      "SourceSnapshot": {
        "PersistentEnabled": true,
        "RetentionCount": 5
      },
      "DestinationSnapshot": {
        "PersistentEnabled": true,
        "RetentionCount": 7
      }
    }
  ]
}
```

| Setting | Description |
|---------|-------------|
| `UseVss` | Create temporary snapshot on source to copy locked files (deleted after sync) |
| `SourceSnapshot.PersistentEnabled` | Create persistent snapshot on source volume before backup |
| `SourceSnapshot.RetentionCount` | Number of snapshots to retain on source volume (1-100) |
| `DestinationSnapshot.PersistentEnabled` | Create persistent snapshot on destination volume before backup |
| `DestinationSnapshot.RetentionCount` | Number of snapshots to retain on destination volume (1-100) |

#### Intelligent MAX Retention

When multiple profiles share the same volume (source or destination), Robocurse uses the **maximum retention count** from all profiles targeting that volume during cleanup.

**Example:** Profile A backs up from `D:\Data1` with retention 3, Profile B backs up from `D:\Data2` with retention 7. Both target volume `D:`. When either profile runs, it creates a snapshot and cleans up old ones keeping **7** (the max).

This prevents snapshot accumulation while respecting each profile's declared retention requirements.

#### Pre-flight Check

```powershell
$check = Test-VssPrivileges
if (-not $check.Success) {
    Write-Warning "VSS not available: $($check.ErrorMessage)"
}
```

#### Local VSS

```powershell
$result = Invoke-WithVssJunction -SourcePath "C:\Data" -ScriptBlock {
    param($SourcePath)
    robocopy $SourcePath "D:\Backup" /MIR /R:0 /W:0
}
```

#### Remote VSS (Network Shares)

```powershell
$result = Invoke-WithRemoteVssJunction -UncPath "\\FileServer\Share" -ScriptBlock {
    param($SourcePath)
    robocopy $SourcePath "D:\Backup" /MIR /R:0 /W:0
}
```

**Remote Server Setup** (run these on the file server):

```powershell
# 1. Enable PowerShell remoting (requires admin)
Enable-PSRemoting -Force

# 2. Verify WinRM service is running
Get-Service WinRM

# 3. If firewalled, allow WinRM (TCP 5985 for HTTP, 5986 for HTTPS)
Enable-NetFirewallRule -DisplayGroup "Windows Remote Management"
```

**Requirements**:
- Administrator rights on the remote file server
- WinRM service running (`Enable-PSRemoting` starts it)
- Firewall allows WinRM (TCP 5985/5986)
- Your account must be in the Administrators group on the remote server

**Test connectivity before use**:
```powershell
# Dot-source the script to load functions without running
. .\Robocurse.ps1

# Then test remote VSS connectivity
Test-RemoteVssSupported -UncPath "\\FileServer\Share"
```

### Retry Behavior

Failed chunks retry with exponential backoff: 5s → 10s → 20s → ... (capped at 120s).

VSS operations retry automatically for transient failures (lock contention, VSS busy).

---

## Snapshot Management

Robocurse provides both GUI and CLI interfaces for managing VSS snapshots.

### GUI Management

In the GUI, each profile has **Source Snapshots** and **Destination Snapshots** tabs showing existing snapshots for the respective volumes. From these tabs you can:
- View snapshot creation dates and shadow IDs
- Delete individual snapshots
- Refresh the snapshot list

### CLI Commands

The CLI provides commands for managing VSS snapshots independently of replication jobs.

### List Snapshots

```powershell
# List all local snapshots
.\Robocurse.ps1 -ListSnapshots

# List snapshots for specific volume
.\Robocurse.ps1 -ListSnapshots -Volume D:

# List snapshots on remote server
.\Robocurse.ps1 -ListSnapshots -Server FileServer01
.\Robocurse.ps1 -ListSnapshots -Volume D: -Server FileServer01
```

### Create Snapshots

```powershell
# Create snapshot on local volume
.\Robocurse.ps1 -CreateSnapshot -Volume D:

# Create on remote server
.\Robocurse.ps1 -CreateSnapshot -Volume D: -Server FileServer01

# Create with retention (keeps only N newest snapshots)
.\Robocurse.ps1 -CreateSnapshot -Volume D: -KeepCount 5
```

### Delete Snapshots

```powershell
# Delete by shadow ID (get ID from -ListSnapshots)
.\Robocurse.ps1 -DeleteSnapshot -ShadowId "{abc12345-...}"

# Delete on remote server
.\Robocurse.ps1 -DeleteSnapshot -ShadowId "{abc12345-...}" -Server FileServer01
```

### Snapshot Schedules

Define schedules in your config file under `GlobalSettings.SnapshotSchedules`:

```json
{
  "GlobalSettings": {
    "SnapshotSchedules": [
      {
        "Name": "HourlyD",
        "Volume": "D:",
        "Schedule": "Hourly",
        "Time": "00:00",
        "KeepCount": 24,
        "Enabled": true
      },
      {
        "Name": "DailyE",
        "Volume": "E:",
        "Schedule": "Daily",
        "Time": "02:00",
        "KeepCount": 7,
        "Enabled": true
      }
    ]
  }
}
```

Manage schedules via CLI:

```powershell
# List configured schedules
.\Robocurse.ps1 -SnapshotSchedule

# Sync schedules from config to Windows Task Scheduler
.\Robocurse.ps1 -SnapshotSchedule -Sync

# Remove a schedule
.\Robocurse.ps1 -SnapshotSchedule -Remove -ScheduleName HourlyD
```

Schedule options: `Hourly`, `Daily`, `Weekly`, `Monthly`.

---

## Profile Scheduling

Each sync profile can have its own independent schedule. Schedules are managed via Windows Task Scheduler.

### GUI Configuration

1. Select a profile from the list
2. Click the **Schedule** button (next to Validate)
3. Enable scheduling and configure:
   - **Frequency**: Hourly, Daily, Weekly, or Monthly
   - **Time**: When to run (24-hour format, e.g., 02:00)
   - **Interval**: For Hourly - run every N hours
   - **Day of Week**: For Weekly - which day
   - **Day of Month**: For Monthly - which date (1-28)
4. Click **Save** to create the scheduled task

The Schedule button shows **Scheduled** when a schedule is active for the selected profile.

### CLI Commands

```powershell
# List all profile schedules
.\Robocurse.ps1 -ListProfileSchedules

# Set a daily schedule
.\Robocurse.ps1 -SetProfileSchedule -ProfileName "MyBackup" -Frequency Daily -Time "03:00"

# Set an hourly schedule (every 4 hours)
.\Robocurse.ps1 -SetProfileSchedule -ProfileName "FrequentSync" -Frequency Hourly -Interval 4

# Set a weekly schedule
.\Robocurse.ps1 -SetProfileSchedule -ProfileName "WeeklyArchive" -Frequency Weekly -DayOfWeek Saturday -Time "02:00"

# Set a monthly schedule
.\Robocurse.ps1 -SetProfileSchedule -ProfileName "MonthlyReport" -Frequency Monthly -DayOfMonth 1 -Time "01:00"

# Enable/disable a schedule
.\Robocurse.ps1 -EnableProfileSchedule -ProfileName "MyBackup"
.\Robocurse.ps1 -DisableProfileSchedule -ProfileName "MyBackup"

# Sync tasks with config (create missing, remove orphaned)
.\Robocurse.ps1 -SyncProfileSchedules
```

### Task Naming

Scheduled tasks are created with the naming convention: `Robocurse-Profile-{ProfileName}`

You can view these tasks in Windows Task Scheduler under the root folder.

### Network Share Access

Scheduled tasks run in Windows Session 0 where network credentials don't delegate properly. When a profile uses network paths (UNC like `\\server\share`), you must provide credentials:

**GUI**: The Schedule dialog prompts for credentials when the profile has network paths.

**CLI**: You'll be prompted for credentials:
```powershell
.\Robocurse.ps1 -SetProfileSchedule -ProfileName "NetworkBackup" -Frequency Daily -Time "02:00"
# Enter credentials when prompted
```

**Security**: Credentials are encrypted using Windows DPAPI, bound to both the user account AND machine. Only the same user on the same machine can decrypt them. This is the most secure storage option available.

**Important**: The scheduled task must run as the SAME user who saved the credentials. If you configure the task to run as a different account, credentials cannot be decrypted.

---

## Logging

Robocurse generates three log types:

| Log | Purpose |
|-----|---------|
| **Operational** | Application events with function:line tracing |
| **Robocopy** | Per-job robocopy output |
| **SIEM** | JSON Lines format for security monitoring |

Example operational log entry:
```
2024-01-15 14:32:45 [INFO] [Orchestrator] Start-ReplicationJob:1234 - Starting profile 'DailyBackup'
```

### SIEM Event Schema

SIEM logs are written in JSON Lines format for easy ingestion by security monitoring tools. Each line is a self-contained JSON object.

#### Event Types

| Event Type | Trigger | Key Fields |
|------------|---------|------------|
| `ChunkComplete` | Chunk replication finished | `chunkId`, `profileName`, `filesCopied`, `bytesCopied`, `durationSeconds` |
| `ChunkError` | Chunk failed with error | `chunkId`, `profileName`, `exitCode`, `errorMessage`, `flags` |
| `VSSSnapshot` | Snapshot created/deleted | `action`, `volumePath`, `shadowId`, `isRemote` |
| `EmailSent` | Notification email sent | `recipients`, `status` |
| `SecurityWarning` | Potential security issue | `type`, `field` (e.g., CRLF injection attempt) |
| `ConfigChange` | Configuration/credential access | `action`, `source`, `target` |

#### Example Events

**ChunkComplete:**
```json
{
  "timestamp": "2024-01-15T14:32:45.123Z",
  "eventType": "ChunkComplete",
  "sessionId": "abc123",
  "data": {
    "chunkId": 42,
    "profileName": "DailyBackup",
    "sourcePath": "\\\\server\\share\\data",
    "destinationPath": "D:\\Backups\\data",
    "exitCode": 1,
    "exitSeverity": "Success",
    "durationSeconds": 45.2,
    "filesCopied": 1250,
    "filesSkipped": 50,
    "filesFailed": 0,
    "bytesCopied": 5368709120,
    "bytesPerSecond": 118755424,
    "dryRun": false,
    "flags": {
      "filesCopied": true,
      "extrasDetected": false,
      "mismatchesFound": false,
      "copyErrors": false,
      "fatalError": false
    }
  }
}
```

**SecurityWarning:**
```json
{
  "timestamp": "2024-01-15T14:32:45.123Z",
  "eventType": "SecurityWarning",
  "sessionId": "abc123",
  "data": {
    "type": "CRLFInjectionAttempt",
    "field": "From"
  }
}
```

#### Integration Notes

- **File rotation**: New file created daily (`Audit_YYYY-MM-DD.jsonl`)
- **Compression**: Files older than 7 days are gzipped (configurable)
- **Retention**: Files older than 30 days are deleted (configurable)
- **Path redaction**: Enable `PathRedaction` to obscure sensitive paths in SIEM events

---

## Architecture

### System Overview

```mermaid
flowchart TB
    subgraph Entry["Entry Points"]
        GUI["GUI Mode<br/>(WPF/XAML)"]
        Headless["Headless Mode<br/>(Scheduled)"]
        CLI["Snapshot CLI<br/>Management"]
    end

    subgraph Orchestration["Orchestration Layer"]
        direction TB
        ProfileMgr["Profile Manager"]
        ChunkQueue["Chunk Queue"]
        CircuitBreaker["Circuit Breaker"]
        Checkpoint["Checkpoint Recovery"]

        subgraph State["OrchestrationState (C# Thread-Safe)"]
            ConcurrentQueue["ConcurrentQueue&lt;Chunk&gt;"]
            ConcurrentDict["ConcurrentDictionary&lt;Jobs&gt;"]
            Interlocked["Interlocked Counters"]
            Volatile["Volatile Flags"]
        end
    end

    subgraph Core["Core Services"]
        DirProfile["Directory Profiling<br/>+ Chunking"]
        Robocopy["Robocopy Wrapper<br/>(Parallel Jobs)"]
        VSS["VSS Manager<br/>(Local/Remote)"]
    end

    subgraph Infra["Infrastructure Layer"]
        Logging["Logging<br/>(3 types)"]
        Email["Email<br/>Notifier"]
        Config["Config<br/>Manager"]
        Health["Health<br/>Monitor"]
    end

    subgraph External["External Systems"]
        Source[("Source<br/>Volumes")]
        Dest[("Destination<br/>Volumes")]
        SIEM[("SIEM<br/>System")]
    end

    GUI --> Orchestration
    Headless --> Orchestration
    CLI --> Orchestration

    Orchestration --> DirProfile
    Orchestration --> Robocopy
    Orchestration --> VSS

    DirProfile --> Infra
    Robocopy --> Infra
    VSS --> Infra

    Robocopy --> Source
    Robocopy --> Dest
    Logging --> SIEM
```

### Key Design Patterns

| Pattern | Implementation | Purpose |
|---------|----------------|---------|
| **Circuit Breaker** | `OrchestrationCore.ps1` | Stops after 10 consecutive failures |
| **Exponential Backoff** | `JobManagement.ps1` | Retry delays: 5s → 10s → 20s → ... |
| **Lazy Loading** | `Initialize-OrchestrationStateType` | Defer C# compilation until needed |
| **Thread-Safe State** | C# `OrchestrationState` class | Cross-runspace communication |
| **Atomic File Writes** | VSS tracking, checkpoints | Write-to-temp then rename |

### Module Dependencies

```mermaid
flowchart LR
    Main["Main.ps1"] --> Orch["Orchestration"]
    Main --> Config["Configuration"]
    Main --> Log["Logging"]
    Main --> GUI["GUI*<br/>(13 modules)"]

    Orch --> Job["JobManagement"]
    Orch --> Chunk["Chunking"]
    Orch --> VSS["VSS<br/>(Core/Local/Remote)"]

    Job --> Robo["Robocopy"]
    Chunk --> DirProf["DirectoryProfiling"]
    Log --> SIEM["SIEM Events"]
```

---

## Development

### Project Structure

```
src/Robocurse/           # Module source (edit here)
├── Public/              # 35 function files
├── Resources/           # 11 XAML templates
├── Robocurse.psm1       # Module loader + 36 constants
└── Robocurse.psd1       # Module manifest

build/                   # Build tools
dist/                    # Built monolith (deploy this)
tests/                   # Pester test suite
├── Unit/                # 47 unit test files
├── Integration/         # 9 integration tests
└── Enforcement/         # 10 AST-based pattern tests
scripts/                 # Utility scripts
schemas/                 # JSON schema for config validation
docs/                    # Task-based development docs
```

### Building

```powershell
.\build\Build-Robocurse.ps1
```

Output: `dist/Robocurse.ps1` with SHA256 hash.

### Testing

```powershell
# All tests (recommended - avoids output truncation)
.\scripts\run-tests.ps1

# View test results
Get-Content $env:TEMP\pester-summary.txt   # Quick pass/fail counts
Get-Content $env:TEMP\pester-failures.txt  # Failure details if any

# Specific test categories
Invoke-Pester ./tests/Unit -Output Detailed
Invoke-Pester ./tests/Integration -Output Detailed
Invoke-Pester ./tests/Enforcement -Output Detailed

# Code coverage report
Invoke-Pester ./tests -CodeCoverage src/Robocurse/Public/*.ps1
```

#### Test Categories

| Category | Count | Purpose |
|----------|-------|---------|
| **Unit** | 47 files | Individual function testing with mocks |
| **Integration** | 14 files | End-to-end workflows, real robocopy |
| **Enforcement** | 10 files | AST-based pattern verification |

#### Skipped Tests

Some tests require environment setup and are skipped by default:

| Requirement | Environment Variable | Description |
|-------------|---------------------|-------------|
| Remote VSS | `ROBOCURSE_TEST_REMOTE_SHARE` | UNC path to test share (e.g., `\\server\share`) |
| Email | `ROBOCURSE_TEST_SMTP_*` | SMTP server, port, user, password, recipient |
| Scheduling | N/A | Requires Administrator privileges |
| Platform | N/A | VSS/scheduling tests skip on non-Windows |

To run remote VSS tests:
```powershell
$env:ROBOCURSE_TEST_REMOTE_SHARE = "\\FileServer\TestShare"
.\scripts\run-tests.ps1
```

---

## Security Notes

### Log Confidentiality

DEBUG logs contain full file paths. Restrict access to log directories.

### Credentials

- SMTP credentials use Windows Credential Manager
- Credential access is logged to SIEM for auditing
- Use dedicated service accounts with minimal permissions

**Note**: The Windows Credential Manager API requires passwords to briefly exist as plaintext in memory before conversion to `SecureString`. Mitigations: byte arrays are explicitly zeroed via `[Array]::Clear()` immediately after use, and credentials are only retrieved at send time (not cached).

### Pre-flight Validations

Before replication, Robocurse checks:
- Source path accessibility
- Destination disk space (warns at 90% full)
- Dangerous robocopy switch combinations

---

## Troubleshooting

### Common Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| **VSS errors** | Insufficient privileges | Run as Administrator; verify with `Test-VssPrivileges` |
| **Script won't load** | Execution policy | `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` |
| **Exit code confusion** | Robocopy bitmask codes | Use `Get-RobocopyExitMeaning -ExitCode <n>` |
| **Remote VSS fails** | WinRM not enabled | Run `Enable-PSRemoting -Force` on remote server |
| **Chunks too large** | Default 10GB limit | Adjust `ChunkMaxSizeGB` in profile config |
| **Email not sending** | Missing credentials | Run `cmdkey /list:Robocurse-SMTP` to verify |
| **Circuit breaker trips** | 10+ consecutive failures | Check logs for root cause; may be access/path issue |

### Diagnostic Commands

```powershell
# Check VSS prerequisites
Test-VssPrivileges

# Test remote server connectivity
Test-RemoteVssSupported -UncPath "\\Server\Share"

# Interpret robocopy exit codes
Get-RobocopyExitMeaning -ExitCode 8

# View active log session
Get-LogPath -Type Operational

# Check profile cache statistics
Get-ProfileCacheStatistics
```

### Log Locations

| Log Type | Location | Format |
|----------|----------|--------|
| Operational | `{LogPath}/{date}/Session_*.log` | Timestamped text with caller info |
| Robocopy | `{LogPath}/{date}/Jobs/Chunk_*.log` | Per-chunk robocopy output |
| SIEM | `{LogPath}/{date}/Audit_*.jsonl` | JSON Lines for ingestion |

### Custom Robocopy Path

```powershell
Set-RobocopyPath -Path "D:\Tools\robocopy.exe"
Clear-RobocopyPath  # Revert to auto-detection
```

### Debug Mode

For verbose debugging, set the log level before running:

```powershell
# In your script or before calling Robocurse functions
Set-RobocurseLogLevel -Level 'Debug'
```

### Path Redaction for Sensitive Environments

To redact server names and paths from logs (useful for sharing logs or SIEM compliance):

```powershell
Enable-PathRedaction -ServerNames @('PRODSERVER01', 'FILESERVER')
# Logs will show [UNC]\filename instead of \\PRODSERVER01\share\path\filename
```

---

## License

MIT License - see [LICENSE](LICENSE) file.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Run `.\scripts\run-tests.ps1` - all tests must pass
5. Submit a pull request

## Developed with EAD

AI generates code faster than humans can review it. Architectural drift compounds. Type systems fragment. This is the verification bottleneck.

Robocurse was built with [Enforcement-Accelerated Development](https://doi.org/10.5281/zenodo.17968797), a methodology that makes AI-assisted development tractable.

**Three pillars:**

| Pillar | Implementation |
|--------|----------------|
| Context Sharding | Task docs in `docs/` (~500 LOC each) |
| Enforcement Tests | AST verification in `tests/Enforcement/` |
| Evidence-Based Debugging | `function:line` in all logs |

Violations caught at commit time. Not production.

- [EAD Whitepaper](https://doi.org/10.5281/zenodo.17968797) — Full methodology
- [Mark Pace](https://pace.org) — Author

## References

- [Robocopy Documentation](https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy)
- [Volume Shadow Copy Service](https://docs.microsoft.com/en-us/windows/win32/vss/volume-shadow-copy-service-portal)
- [Pester Testing Framework](https://pester.dev/)
