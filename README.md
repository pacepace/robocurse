# Robocurse

**Multi-Share Parallel Robocopy Orchestrator**

Robocurse is a PowerShell-based tool designed to manage multiple robocopy instances for replicating large directory structures that would otherwise overwhelm a single robocopy process. It intelligently chunks large directories and runs parallel robocopy jobs to improve performance and reliability.

## Features

- **Intelligent Directory Chunking**: Automatically analyzes and divides large directory structures into optimal chunks
- **Parallel Execution**: Runs multiple robocopy instances simultaneously with configurable concurrency
- **Volume Shadow Copy (VSS) Support**: Backup locked files using VSS snapshots
- **Flexible Configuration**: JSON-based configuration with support for multiple profiles
- **Comprehensive Logging**: Operational logs, robocopy logs, and SIEM integration
- **Progress Tracking**: Real-time progress monitoring with ETA calculations
- **Email Notifications**: Automated completion emails with detailed statistics
- **Scheduled Execution**: Built-in support for Windows Task Scheduler integration
- **GUI and Headless Modes**: Run interactively with a GUI or in headless mode for automation
- **Retry Logic**: Configurable retry policies for transient failures
- **Credential Management**: Secure credential storage for network shares
- **Aggregate Bandwidth Throttling**: Dynamic bandwidth limiting across all concurrent jobs
- **VSS Orphan Cleanup**: Automatic cleanup of VSS snapshots from crashed runs
- **Enhanced Logging**: Function name and line number tracing for troubleshooting
- **Dry-Run Mode**: Preview what would be copied without actually copying
- **Configurable Mismatch Severity**: Control how robocopy exit code 4 (mismatches) is treated
- **GUI State Persistence**: Window position, size, and settings remembered between sessions
- **Real-Time Error Display**: Errors from background replication shown immediately in GUI

## Prerequisites

- **Operating System**: Windows Server 2016+ or Windows 10+
- **PowerShell**: Version 5.1 or higher
- **Privileges**: Administrator rights (required for VSS operations)
- **Pester**: Version 5.x (for running tests)

### Installing Pester

```powershell
Install-Module -Name Pester -Force -SkipPublisherCheck
```

## Installation

**For Deployment:**
1. Copy `dist/Robocurse.ps1` to your target server
2. Copy and customize `Robocurse.config.json` to the same directory
3. Ensure you have administrator privileges (required for VSS)

**For Development:**
1. Clone this repository
2. Edit modules in `src/Robocurse/Public/`
3. Run tests: `Invoke-Pester ./tests`
4. Build monolith: `.\build\Build-Robocurse.ps1`

## Configuration

Edit `Robocurse.config.json` to configure your replication profiles. The configuration file supports:

- **Multiple Profiles**: Define different backup/replication scenarios
- **Source/Destination Paths**: Local or UNC paths
- **Robocopy Options**: Full control over robocopy switches
- **Chunking Strategy**: Configure chunk sizes and parallel execution
- **Scheduling**: Set up automated execution times
- **Logging**: Configure operational and robocopy log locations
- **Email Settings**: SMTP configuration for notifications
- **Retry Policies**: Define how failures are handled

**Note**: Robocurse supports two configuration formats and auto-detects which you're using:
- **Enterprise format** (`profiles`/`global`): The full JSON structure in `Robocurse.config.json`
- **Simplified format** (`SyncProfiles`/`GlobalSettings`): Flatter structure for programmatic use

### Example Profile (Simplified Format)

For headless/CLI operation, profiles use this simplified structure:

```json
{
  "Version": "1.0",
  "GlobalSettings": {
    "MaxConcurrentJobs": 4,
    "ThreadsPerJob": 8,
    "BandwidthLimitMbps": 0,
    "LogPath": ".\\Logs"
  },
  "SyncProfiles": [
    {
      "Name": "DailyBackup",
      "Source": "\\\\FILESERVER01\\Share1",
      "Destination": "D:\\Backups\\FileServer01",
      "UseVss": true,
      "ScanMode": "Smart",
      "ChunkMaxSizeGB": 10,
      "ChunkMaxFiles": 50000,
      "RobocopyOptions": {
        "Switches": ["/COPYALL", "/DCOPY:DAT"],
        "ExcludeFiles": ["*.tmp", "*.temp", "~*"],
        "ExcludeDirs": ["$RECYCLE.BIN", "System Volume Information"],
        "NoMirror": false,
        "SkipJunctions": true,
        "RetryCount": 3,
        "RetryWait": 10
      }
    }
  ]
}
```

### Robocopy Options Reference

Each profile can specify `RobocopyOptions` to customize robocopy behavior:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `Switches` | string[] | `/COPY:DAT /DCOPY:T` | Additional robocopy switches |
| `ExcludeFiles` | string[] | `[]` | File patterns to exclude (e.g., `*.tmp`) |
| `ExcludeDirs` | string[] | `[]` | Directory names to exclude |
| `NoMirror` | bool | `false` | Use `/E` instead of `/MIR` (don't delete extras) |
| `SkipJunctions` | bool | `true` | Skip junction points (`/XJD /XJF`) |
| `RetryCount` | int | `3` | Retry count for failed files (`/R:`) |
| `RetryWait` | int | `10` | Wait seconds between retries (`/W:`) |
| `InterPacketGapMs` | int | `null` | Bandwidth throttling - ms between packets (`/IPG:`) |

**Note**: Threading (`/MT:`), logging (`/LOG:`), and progress (`/TEE /BYTES`) flags are always applied by Robocurse and cannot be overridden.

### Aggregate Bandwidth Throttling

Set `BandwidthLimitMbps` in `GlobalSettings` to limit total bandwidth consumption across all concurrent robocopy jobs. This is useful when replicating over WAN links or shared network infrastructure.

```json
"GlobalSettings": {
  "MaxConcurrentJobs": 4,
  "BandwidthLimitMbps": 100
}
```

The bandwidth is dynamically divided among active jobs. For example:
- 100 Mbps limit with 4 concurrent jobs = ~25 Mbps per job
- As jobs complete, remaining jobs get more bandwidth
- Set to `0` for unlimited (default)

**Implementation Note**: Robocurse uses robocopy's `/IPG` (Inter-Packet Gap) flag, which introduces a delay between 512-byte packets. The IPG value is automatically calculated based on the per-job bandwidth allocation.

### Mismatch Severity Configuration

Control how robocopy exit code 4 (mismatches detected) is treated:

```json
"GlobalSettings": {
  "MismatchSeverity": "Warning"
}
```

| Value | Behavior |
|-------|----------|
| `Warning` | (Default) Log as warning, don't trigger retry |
| `Error` | Treat as error, trigger retry logic |
| `Success` | Ignore mismatches entirely |

This is useful for sync scenarios where mismatches are expected (e.g., bidirectional sync, or when destination files are intentionally modified).

### VSS Orphan Cleanup

If Robocurse crashes or is terminated while VSS snapshots are active, those snapshots may be left behind consuming disk space. Robocurse automatically cleans up orphaned snapshots from previous failed runs at startup.

The tracking file is stored at `$PSScriptRoot\vss_active.json` and records all active VSS snapshots. On startup, any snapshots still in this file are removed.

To manually trigger orphan cleanup:

```powershell
# After dot-sourcing the script
Clear-OrphanVssSnapshots
```

## Usage

Use `dist/Robocurse.ps1` for deployment (or import the module from `src/Robocurse/` for development).

### GUI Mode

Launch the graphical interface:

```powershell
.\dist\Robocurse.ps1
```

### Headless Mode

Run a specific profile in headless mode (ideal for scheduled tasks):

```powershell
.\dist\Robocurse.ps1 -Headless -Profile "DailyBackup"
```

### Custom Configuration File

Specify a different configuration file:

```powershell
.\dist\Robocurse.ps1 -ConfigPath "C:\Configs\custom-config.json" -Headless -Profile "WeeklyFull"
```

### Dry-Run Mode

Preview what would be copied without actually performing the copy:

```powershell
.\dist\Robocurse.ps1 -Headless -Profile "DailyBackup" -DryRun
```

This runs robocopy with the `/L` flag, which lists files that would be copied without actually copying them. Useful for:
- Verifying your profile configuration before a real run
- Estimating how long a replication will take
- Checking what files have changed since the last sync

### Display Help

```powershell
.\dist\Robocurse.ps1 -Help
```

## Testing

This project uses Pester 5 for testing. Tests load from the modular source (`src/Robocurse/`).

### Run All Tests

```powershell
Invoke-Pester ./tests -Output Detailed
```

### Run Specific Test Categories

```powershell
# Unit tests only
Invoke-Pester ./tests/Unit -Output Detailed

# Integration tests only
Invoke-Pester ./tests/Integration -Output Detailed

# Specific test file
Invoke-Pester ./tests/Unit/Configuration.Tests.ps1 -Output Detailed
```

### Test the Built Monolith

To test the built artifact instead of the modules:

```powershell
# In test file BeforeAll block, use:
Initialize-RobocurseForTesting -UseBuiltMonolith
```

## Project Structure

```
robocurse/
├── src/Robocurse/             # SOURCE OF TRUTH - Module files
│   ├── Robocurse.psd1         # Module manifest
│   ├── Robocurse.psm1         # Module loader + constants
│   └── Public/                # Exported functions
│       ├── Utility.ps1
│       ├── Configuration.ps1
│       ├── Logging.ps1
│       ├── DirectoryProfiling.ps1
│       ├── Chunking.ps1
│       ├── Robocopy.ps1
│       ├── Orchestration.ps1
│       ├── Progress.ps1
│       ├── VSS.ps1
│       ├── Email.ps1
│       ├── Scheduling.ps1
│       ├── GUI.ps1
│       └── Main.ps1
├── build/                     # Build tools
│   ├── Build-Robocurse.ps1    # Assembles modules into monolith
│   └── README.md              # Build documentation
├── dist/                      # Built artifacts
│   └── Robocurse.ps1          # DEPLOYABLE MONOLITH
├── tests/                     # Test directory
│   ├── TestHelper.ps1         # Test loader (uses modules)
│   ├── Robocurse.Tests.ps1    # Main test suite
│   ├── Unit/                  # Unit tests
│   └── Integration/           # Integration tests
├── Robocurse.config.json      # Configuration file
├── docs/                      # Documentation
└── README.md                  # This file
```

**Development Workflow:**
- Edit files in `src/Robocurse/Public/`
- Run tests: `Invoke-Pester ./tests -Output Detailed`
- Build monolith: `.\build\Build-Robocurse.ps1`
- Deploy: Copy `dist/Robocurse.ps1` to target server

See [build/README.md](build/README.md) for detailed build documentation.

## Development Status

This project is currently under active development. The following features are implemented or planned:

- [x] Project structure and testing framework
- [x] Configuration management (auto-converts between JSON and internal formats)
- [x] Logging system (operational logs + SIEM JSON Lines)
- [x] Directory profiling (robocopy /L based scanning with caching)
- [x] Chunking algorithms (Smart + Flat modes)
- [x] Robocopy wrapper with configurable options per profile
- [x] Job orchestration (parallel execution, retry logic)
- [x] Progress tracking (ETA, byte/file counts)
- [x] VSS integration (snapshot creation/cleanup)
- [x] Email notifications (SMTP with Credential Manager)
- [x] Scheduling support (Windows Task Scheduler)
- [x] GUI interface (WPF dark theme)
- [x] Headless/CLI mode with full orchestration loop

## Contributing

1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Ensure all tests pass: `Invoke-Pester ./tests`
5. Submit a pull request

## Logging

Robocurse generates several types of logs:

- **Operational Log**: High-level application events and errors
- **Robocopy Logs**: Detailed per-job robocopy output
- **SIEM Integration**: JSON Lines format for security monitoring tools

Log locations are configured in the `global.logging` section of the configuration file.

### Log Format

Each operational log entry includes:
- Timestamp (local time)
- Log level (`DEBUG`, `INFO`, `WARNING`, `ERROR`)
- Component name
- **Caller info**: Function name and line number (e.g., `Start-ReplicationJob:1234`)
- Message

Example log entry:
```
2024-01-15 14:32:45 [INFO] [Orchestrator] Start-ReplicationJob:1234 - Starting profile 'DailyBackup'
```

This caller tracing makes debugging significantly easier when tracking down issues.

## Credential Management

Network credentials can be stored securely using Windows Credential Manager:

```powershell
# Store credentials (from GUI or manually)
cmdkey /add:FILESERVER01 /user:DOMAIN\Username /pass:Password
```

Reference credentials in your configuration using the `credentialName` field.

## Troubleshooting

### Tests Fail to Load Script

Ensure you have administrator privileges and PowerShell execution policy allows script execution:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### VSS Errors

VSS operations require administrator privileges. Run PowerShell as Administrator.

### Robocopy Exit Codes

Robocopy uses bit-flag exit codes. Consult the `Get-RobocopyExitMeaning` function for interpretation.

## Security Considerations

### SMTP Credentials

When retrieving SMTP credentials from Windows Credential Manager, the password briefly exists as a plaintext string in memory before being converted to a `SecureString`. This is an unavoidable limitation of the Windows Credential Manager P/Invoke API.

**Mitigations:**
- The plaintext string is immediately eligible for garbage collection after `SecureString` creation
- Credentials are only retrieved when sending email notifications (not at startup)
- The credential retrieval code runs in the main PowerShell process, not persisted to disk

**Recommendations:**
- Use a dedicated SMTP account with limited permissions for Robocurse notifications
- Consider using an application-specific password if your email provider supports it
- On high-security systems, disable email notifications and use log file monitoring instead

### Network Share Credentials

For network share access, Robocurse relies on the Windows security context of the executing user. Use a service account with minimal required permissions when running as a scheduled task.

## License

See LICENSE file for details.

## Support

For issues, questions, or contributions, please use the project's issue tracker.

## References

- [Robocopy Documentation](https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy)
- [Pester Testing Framework](https://pester.dev/)
- [VSS (Volume Shadow Copy Service)](https://docs.microsoft.com/en-us/windows/win32/vss/volume-shadow-copy-service-portal)
- [PowerShell Documentation](https://docs.microsoft.com/en-us/powershell/)