# Error Recovery UI Enhancement Tasks

This directory contains self-contained task specifications for enhancing Robocurse's error recovery UI. Each task is designed to be completed within a single AI context window, including all research, TDD, and implementation.

## Task Overview

| # | Task | Priority | Complexity | Dependencies |
|---|------|----------|------------|--------------|
| 01 | [Chunk Error Tooltip](01-chunk-error-tooltip.md) | High | Low | None |
| 02 | [Error Status Indicator](02-error-status-indicator.md) | High | Medium | None |
| 03 | [Chunk Context Menu](03-chunk-context-menu.md) | High | Medium | None |
| 04 | [Pre-flight Validation UI](04-preflight-validation-ui.md) | Medium | Medium | None |
| 05 | [Profile Error Summary](05-profile-error-summary.md) | Medium | Low | None |
| 06 | [Completion Error Details](06-completion-error-details.md) | Medium | Medium | Task 01 |
| 07 | [Fix Log Window Always-On-Top](07-fix-log-window-topmost.md) | High | Low | None |

## Suggested Order

1. **Task 07** (Fix Log Window) - Quick win, fixes annoying bug
2. **Task 01** (Chunk Error Tooltip) - Foundation for error visibility
3. **Task 02** (Error Status Indicator) - Clickable error status bar
4. **Task 03** (Chunk Context Menu) - User recovery actions
5. **Task 06** (Completion Error Details) - Depends on Task 01
6. **Task 04** (Pre-flight Validation) - Proactive error prevention
7. **Task 05** (Profile Error Summary) - Nice-to-have polish

## Task Structure

Each task file includes:

### 1. Objective & Problem Statement
Clear description of what needs to be built and why.

### 2. Success Criteria
Specific, testable outcomes that define "done".

### 3. Research Section
- Current implementation code snippets
- File locations and line numbers
- Relevant patterns from existing code

### 4. Implementation Plan
Step-by-step instructions with code examples:
- PowerShell function implementations
- XAML modifications
- Event wiring

### 5. Test Plan
Complete Pester test file that can be copy-pasted and run.

### 6. Files to Modify
Explicit list of files that need changes.

### 7. Verification Commands
Commands to run tests and verify the implementation.

## Development Notes

### TDD Approach
Each task includes tests that should be written FIRST. The pattern:
1. Create the test file from the task specification
2. Run tests (they will fail)
3. Implement the feature
4. Run tests (they should pass)
5. Verify manually

### Naming Conventions
Task names describe WHAT the feature does, not WHEN it was created:
- "ChunkErrorTooltip" not "Phase1Task1"
- "ValidationDialog" not "PreflightCheck"

### Testing
```powershell
# Run all tests
.\scripts\run-tests.ps1

# Run specific test file
Invoke-Pester -Path tests\Unit\GuiChunkTooltip.Tests.ps1 -Output Detailed

# Run with coverage
Invoke-Pester -Path tests -CodeCoverage src\Robocurse\Public\*.ps1
```

### Building
After completing any task:
```powershell
.\build\Build-Robocurse.ps1
```

## Architecture Context

### GUI Architecture
- WPF-based with dark theme
- Navigation rail with 4 panels (Profiles, Settings, Progress, Logs)
- Background replication runs in separate runspace
- Timer-based progress updates (Forms.Timer, not DispatcherTimer)

### Error Handling Layers
1. **Pre-flight validation** - Checks before starting
2. **Runtime retry** - Exponential backoff for transient failures
3. **Circuit breaker** - Stops on cascading failures
4. **GUI display** - Status bar color + error count

### Thread Safety
- `OrchestrationState` is a C# class with Interlocked operations
- `ConcurrentQueue` for error messages
- GUI updates via timer polling (not callbacks)

### Key Files
| Purpose | File |
|---------|------|
| Progress display | `GuiProgress.ps1` |
| Dialogs | `GuiDialogs.ps1` |
| Job management | `JobManagement.ps1` |
| Orchestration | `OrchestrationCore.ps1` |
| Main window | `MainWindow.xaml` |
