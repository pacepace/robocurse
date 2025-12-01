# Robocurse Task Index

## Overview

This document indexes all implementation tasks for Robocurse. Each task is designed to be completed by an AI agent with minimal context loss.

## Task Summary

| Task | Name | Complexity | Dependencies | Est. Lines |
|------|------|------------|--------------|------------|
| 00 | Project Structure | Low-Medium | None | 200 |
| 01 | Configuration | Low | 00 | 150 |
| 02 | Logging | Medium | 00, 01 | 250 |
| 03 | Directory Profiling | Medium | 00, 02 | 200 |
| 04 | Recursive Chunking | High | 00, 02, 03 | 300 |
| 05 | Robocopy Wrapper | Medium | 00, 02, 04 | 250 |
| 06 | Orchestration | High | 00-05 | 400 |
| 07 | VSS Snapshots | Medium | 00, 02 | 200 |
| 08 | Email Notifications | Medium | 00, 02, 06 | 300 |
| 09 | Scheduling | Low-Medium | 00-08 | 150 |
| 10 | WPF GUI | High | All | 800 |

**Total estimated lines: ~3,200**

## Recommended Execution Order

### Phase 1: Foundation
```
Task 00: Project Structure  →  Task 01: Configuration  →  Task 02: Logging
```
These are prerequisite for everything else.

### Phase 2: Core Logic
```
Task 03: Directory Profiling  →  Task 04: Recursive Chunking  →  Task 05: Robocopy Wrapper
```
This is the heart of the chunking algorithm.

### Phase 3: Orchestration
```
Task 06: Orchestration  →  Task 07: VSS Snapshots
```
Job management and VSS support.

### Phase 4: Integration
```
Task 08: Email  →  Task 09: Scheduling
```
Notifications and automation.

### Phase 5: GUI
```
Task 10: WPF GUI
```
Should be done last as it ties everything together.

## Task File Structure

Each task file contains:

1. **Overview** - What the task accomplishes
2. **Research Required** - Web resources and concepts to understand
3. **Task Description** - Detailed function specifications with signatures
4. **Success Criteria** - Checklist of requirements
5. **Pester Tests Required** - Test code to implement
6. **Dependencies** - Which tasks must be complete first
7. **Estimated Complexity** - Difficulty level

## Testing Strategy

### Unit Tests
- Each task includes Pester test specifications
- Tests should be written alongside or before implementation
- Mock external dependencies (robocopy, WMI, file system)

### Integration Tests
- Tagged with `-Tag "Integration"`
- Require actual file system access
- Some require admin rights (VSS, Task Scheduler)

### Running Tests
```powershell
# All unit tests
Invoke-Pester ./tests -Output Detailed

# Specific module
Invoke-Pester ./tests/Unit/Configuration.Tests.ps1

# Integration tests (requires admin)
Invoke-Pester ./tests -Tag "Integration"
```

## Agent Instructions

When working on a task:

1. **Read the task file completely** before starting
2. **Check dependencies** - ensure prerequisite tasks are complete
3. **Follow function signatures** exactly as specified
4. **Write tests first** or alongside implementation
5. **Run existing tests** after changes to avoid regressions
6. **Update this index** when task is complete

## Completion Checklist

- [ ] Task 00: Project Structure
- [ ] Task 01: Configuration
- [ ] Task 02: Logging
- [ ] Task 03: Directory Profiling
- [ ] Task 04: Recursive Chunking
- [ ] Task 05: Robocopy Wrapper
- [ ] Task 06: Orchestration
- [ ] Task 07: VSS Snapshots
- [ ] Task 08: Email Notifications
- [ ] Task 09: Scheduling
- [ ] Task 10: WPF GUI
- [ ] Integration Testing
- [ ] Manual Testing on Windows Server

## Key Files

After completion, the repository should contain:

```
robocurse/
├── Robocurse.ps1              # Main script (~3000 lines)
├── Robocurse.config.json      # Example configuration
├── README.md                  # User documentation
├── LICENSE                    # MIT License (existing)
├── tests/
│   ├── Robocurse.Tests.ps1
│   └── Unit/
│       ├── Configuration.Tests.ps1
│       ├── Logging.Tests.ps1
│       ├── DirectoryProfiling.Tests.ps1
│       ├── Chunking.Tests.ps1
│       ├── RobocopyWrapper.Tests.ps1
│       ├── Orchestration.Tests.ps1
│       ├── VssSnapshots.Tests.ps1
│       ├── EmailNotifications.Tests.ps1
│       └── Scheduling.Tests.ps1
└── docs/
    ├── TASK-INDEX.md          # This file
    ├── TASK-00-*.md           # Task definitions
    └── ...
```

## Notes for AI Agents

- **Context limit**: Each task is sized to fit within typical AI context windows
- **Self-contained**: Tasks include all necessary research links and specifications
- **Testable**: Every function should be testable with Pester
- **Incremental**: Build on previous tasks, don't rewrite
- **Snark-free code**: Keep the personality in comments/docs only, not in code

## Version History

- **v1.0** - Initial task breakdown (2024-01)
