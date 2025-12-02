# Robocurse Build System

This directory contains build tools for managing the Robocurse codebase.

## Architecture

- **Development**: Edit modules in `src/Robocurse/`
- **Deployment**: Build creates `dist/Robocurse.ps1` - single file, just copy to server

## Directory Structure

```
robocurse/
├── src/Robocurse/             # SOURCE OF TRUTH
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
│       └── GUI.ps1
├── build/
│   └── Build-Robocurse.ps1    # Assembles modules → monolith
├── dist/
│   └── Robocurse.ps1          # BUILT ARTIFACT (for deployment)
└── tests/
    ├── TestHelper.ps1         # Loads modules for testing
    └── ...
```

## Build Script

### Build-Robocurse.ps1

Assembles modules into a single deployable script.

```powershell
# Build to dist/Robocurse.ps1
.\Build-Robocurse.ps1

# Build to custom location
.\Build-Robocurse.ps1 -OutputPath "\\server\deploy\Robocurse.ps1"

# Build with minified comments (smaller file)
.\Build-Robocurse.ps1 -MinifyComments
```

## Testing

Tests load from modules by default:

```powershell
# Run all tests
Invoke-Pester .\tests\ -Output Detailed

# Run specific test file
Invoke-Pester .\tests\Unit\Configuration.Tests.ps1

# Test the built artifact (CI validation)
# Set $UseBuiltMonolith = $true in test or use:
Initialize-RobocurseForTesting -UseBuiltMonolith
```

## Workflow

1. **Edit** files in `src/Robocurse/Public/`
2. **Test** - tests automatically use modules
3. **Build** - run `.\build\Build-Robocurse.ps1`
4. **Deploy** - copy `dist/Robocurse.ps1` to server

## Deployment

```powershell
# Build and deploy
.\build\Build-Robocurse.ps1
Copy-Item .\dist\Robocurse.ps1 "\\server\deploy\"

# Or build directly to server
.\build\Build-Robocurse.ps1 -OutputPath "\\server\deploy\Robocurse.ps1"
```
