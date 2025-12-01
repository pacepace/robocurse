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

1. Clone or download this repository
2. Review and customize `Robocurse.config.json` for your environment
3. Ensure you have administrator privileges

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

**Note**: Threading (`/MT:`), logging (`/LOG:`), and progress (`/TEE /BYTES`) flags are always applied by Robocurse and cannot be overridden.

## Usage

### GUI Mode

Launch the graphical interface:

```powershell
.\Robocurse.ps1
```

### Headless Mode

Run a specific profile in headless mode (ideal for scheduled tasks):

```powershell
.\Robocurse.ps1 -Headless -Profile "DailyBackup"
```

### Custom Configuration File

Specify a different configuration file:

```powershell
.\Robocurse.ps1 -ConfigPath "C:\Configs\custom-config.json" -Headless -Profile "WeeklyFull"
```

### Display Help

```powershell
.\Robocurse.ps1 -Help
```

## Testing

This project uses Pester 5 for testing. All tests are located in the `tests/` directory.

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

### Run Tests with Coverage

```powershell
Invoke-Pester ./tests -CodeCoverage .\Robocurse.ps1 -Output Detailed
```

## Project Structure

```
robocurse/
├── Robocurse.ps1              # Main script
├── Robocurse.config.json      # Configuration file
├── tests/                     # Test directory
│   ├── Robocurse.Tests.ps1    # Main test suite
│   ├── Unit/                  # Unit tests
│   │   ├── Configuration.Tests.ps1
│   │   ├── Logging.Tests.ps1
│   │   ├── Chunking.Tests.ps1
│   │   └── ...
│   └── Integration/           # Integration tests
│       └── EndToEnd.Tests.ps1
├── docs/                      # Documentation and task files
└── README.md                  # This file
```

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
- **SIEM Integration**: Optional Windows Event Log or syslog integration

Log locations are configured in the `global.logging` section of the configuration file.

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

## License

See LICENSE file for details.

## Support

For issues, questions, or contributions, please use the project's issue tracker.

## References

- [Robocopy Documentation](https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy)
- [Pester Testing Framework](https://pester.dev/)
- [VSS (Volume Shadow Copy Service)](https://docs.microsoft.com/en-us/windows/win32/vss/volume-shadow-copy-service-portal)
- [PowerShell Documentation](https://docs.microsoft.com/en-us/powershell/)