# Initial Cleanup Tasks Index

## Overview

This directory contains task files for AI agents to address issues identified during the initial code review of the Robocurse PowerShell project.

## Task Execution Order

Tasks should be executed in priority order. Some tasks have dependencies on others.

### Critical Priority (Execute First)
| Task | File | Dependencies | Est. Complexity |
|------|------|--------------|-----------------|
| 01 | `01-implement-missing-chunking-functions.md` | None | Medium |
| 02 | `02-enable-e2e-integration-tests.md` | Task 01 | Medium-High |

### High Priority
| Task | File | Dependencies | Est. Complexity |
|------|------|--------------|-----------------|
| 03 | `03-add-parameter-validation.md` | None | Medium |

### Medium Priority (Can Run in Parallel)
| Task | File | Dependencies | Est. Complexity |
|------|------|--------------|-----------------|
| 04 | `04-fix-error-handling-consistency.md` | None | Medium |
| 05 | `05-extract-configuration-constants.md` | None | Low-Medium |
| 06 | `06-fix-logging-initialization-issue.md` | None | Low |
| 08 | `08-complete-credential-manager.md` | None | Medium |

### Low Priority
| Task | File | Dependencies | Est. Complexity |
|------|------|--------------|-----------------|
| 07 | `07-fix-thread-safe-chunk-id.md` | None | Low |

## Task File Structure

Each task file contains:

1. **Priority** - Critical/High/Medium/Low
2. **Problem Statement** - What's wrong and why it matters
3. **Research Required** - Code to read, questions to answer
4. **Implementation Options** - Different approaches considered
5. **Recommended Approach** - Suggested solution
6. **Files to Modify** - Specific files that need changes
7. **Success Criteria** - Checkboxes for completion validation
8. **Testing Commands** - How to verify the fix

## Running Tests

All tests use Pester. From the project root:

```powershell
# Run all tests
Invoke-Pester -Path tests/ -Output Detailed

# Run specific test file
Invoke-Pester -Path tests/Unit/Chunking.Tests.ps1 -Output Detailed

# Run with coverage (if configured)
Invoke-Pester -Path tests/ -CodeCoverage Robocurse.ps1 -Output Detailed
```

## Agent Instructions

When executing a task:

1. **Read the full task file** before starting
2. **Perform the research** outlined in the task
3. **Implement the recommended approach** (or a better alternative if justified)
4. **Update or create tests** as specified
5. **Run the tests** and fix any failures
6. **Verify all success criteria** are met
7. **Commit with a descriptive message** referencing the task number

## Notes

- Tasks 01 and 02 are blockers - they must be completed before the project is functional
- Tasks 04-08 can be parallelized if multiple agents are available
- Always run the full test suite after any change to check for regressions
- The main script is `Robocurse.ps1` in the project root
- Tests are in `tests/` with Unit and Integration subdirectories

## Project Context

Robocurse is a PowerShell-based multi-share parallel robocopy orchestrator. It:
- Chunks large directory trees into manageable pieces
- Runs multiple robocopy processes in parallel
- Provides a WPF GUI for Windows users
- Supports VSS snapshots for consistent backups
- Sends email notifications on completion
- Can be scheduled via Windows Task Scheduler
