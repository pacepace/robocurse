# EAD Enforcement Tests for Robocurse

This directory contains tasks for implementing Enforcement-Accelerated Development (EAD) architectural tests for Robocurse. These tests enforce pattern consistency and prevent architectural drift.

## Drift Patterns Identified

From codebase analysis, the following drift patterns were found:

| # | Pattern | Severity | Violations | Description |
|---|---------|----------|------------|-------------|
| 01 | OperationResult Consistency | High | 8 | VssRemote.ps1 returns raw `@{ Success; Error }` instead of `New-OperationResult` |
| 02 | Error Property Naming | High | 8 | `.Error` vs `.ErrorMessage` inconsistency |
| 03 | Logging Parameter Style | Medium | ~50 | Mix of bareword `-Level Debug` vs quoted `-Level 'Debug'` |
| 04 | Documentation Coverage | Medium | Variable | Some functions missing `.SYNOPSIS` or `.DESCRIPTION` blocks |
| 05 | Parameter Validation | Low | Variable | Mix of `[ValidateNotNullOrEmpty()]` vs manual `if (-not $x)` checks |
| 06 | Function Naming | Low | 0 | All functions follow Verb-Noun convention (enforced) |

## Task Overview

| # | Task | Priority | Complexity | Dependencies |
|---|------|----------|------------|--------------|
| 01 | [OperationResult Enforcement](01-operation-result-enforcement.md) | High | Low | None |
| 02 | [Logging Style Enforcement](02-logging-style-enforcement.md) | Medium | Low | None |
| 03 | [Documentation Coverage](03-documentation-coverage.md) | Medium | Low | None |
| 04 | [Naming Convention Enforcement](04-naming-convention-enforcement.md) | Low | Low | None |

## How Enforcement Tests Work

Unlike unit tests that verify behavior, enforcement tests verify **patterns**. They use AST (Abstract Syntax Tree) parsing to analyze source code structure:

```powershell
# Example: Find all functions returning hashtables with Success key
$ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
$violations = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.HashtableAst] -and
    $node.KeyValuePairs.Item1.Value -eq 'Success'
}, $true)
```

## Design Principles

1. **Fast** - Tests run in under 15 seconds (no I/O, network, or heavy processing)
2. **Deterministic** - Same code = same results, no flakiness
3. **Self-Documenting** - Failure messages include file:line:violation details
4. **Actionable** - Each violation has a clear fix path

## Running Enforcement Tests

```powershell
# Run all enforcement tests
Invoke-Pester -Path tests\Enforcement -Output Detailed

# Run specific enforcement test
Invoke-Pester -Path tests\Enforcement\OperationResult.Tests.ps1 -Output Detailed
```

## Test Location

All enforcement tests live in `tests/Enforcement/` to keep them separate from unit and integration tests.

## Implementation Order

1. **Task 01** (OperationResult) - Highest impact, clearest violations, 8 fixes
2. **Task 02** (Logging Style) - Medium impact, ~50 fixes across 2-3 files
3. **Task 04** (Naming Convention) - Zero violations, preventive guard
4. **Task 03** (Documentation) - Variable scope, helps onboarding

## Estimated Effort

| Task | Fixes Needed | Time Estimate |
|------|--------------|---------------|
| 01 | 8 lines | 30 min |
| 02 | ~50 lines | 1 hour |
| 03 | Variable | 1-2 hours |
| 04 | 0 (guard) | 15 min |

**Total:** ~3 hours to achieve full enforcement coverage

## Related Documentation

- [EAD Whitepaper](../../ead-whitepaper.md) - Full methodology description
- [Error UI Tasks](../error-ui/README.md) - UI improvement tasks
