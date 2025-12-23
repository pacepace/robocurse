# Task 02: Enable End-to-End Integration Tests

## Priority: CRITICAL

## Problem Statement

All tests in `tests/Integration/EndToEnd.Tests.ps1` are marked with `-Skip`, making them non-functional placeholders. These tests are critical for validating the complete replication workflow.

Current state - every test has `-Skip`:
```powershell
It "Should complete a simple replication" -Skip {
It "Should handle chunked replication" -Skip {
It "Should generate proper logs" -Skip {
# ... all 12 tests are skipped
```

## Research Required

### Code Research
1. Read `tests/Integration/EndToEnd.Tests.ps1` completely to understand:
   - Test structure and setup/teardown
   - What each test is trying to validate
   - Why tests might have been skipped (missing functionality? platform issues?)

2. Read the orchestration functions in `Robocurse.ps1`:
   - `Start-ReplicationRun`
   - `Start-ProfileReplication`
   - `Invoke-ReplicationTick`
   - `Complete-CurrentProfile`

3. Understand dependencies:
   - Does the test require actual robocopy.exe? (Windows-only)
   - Can we mock robocopy for cross-platform testing?
   - What test infrastructure is needed?

### Key Questions to Answer
- Can these tests run on macOS/Linux with mocks, or are they Windows-only?
- What is the minimum viable test that validates the replication flow?
- Which tests should remain skipped due to platform limitations?

## Implementation Strategy

### Phase 1: Assess and Categorize Tests
Categorize each test as:
- **Mockable**: Can run anywhere with proper mocks
- **Windows-Only**: Requires actual robocopy, should skip on other platforms
- **Broken**: Needs fixes beyond just enabling

### Phase 2: Create Mock Infrastructure
Create mocks for:
- `Start-RobocopyJob` - Return fake job objects
- `robocopy.exe` - Not directly called if we mock the wrapper
- File system operations - Use `TestDrive:` (Pester's temp drive)

### Phase 3: Enable Tests Incrementally
Start with the simplest tests and work toward complex ones:
1. Configuration validation tests
2. Simple replication (mocked)
3. Chunked replication (mocked)
4. Error handling
5. Progress tracking

## Files to Modify

- `tests/Integration/EndToEnd.Tests.ps1` - Enable and fix tests

## Implementation Notes

### Test Structure Already Present
The file already has good structure:
- `BeforeAll` creates temp directories
- `AfterAll` cleans up
- `BeforeEach`/`AfterEach` manage test data

### Platform Handling
Use conditional skip for Windows-only tests:
```powershell
It "Should complete a simple replication" -Skip:(-not $IsWindows) {
```

Or use mocks to make tests platform-agnostic:
```powershell
BeforeAll {
    Mock Start-RobocopyJob {
        return [PSCustomObject]@{
            Process = [PSCustomObject]@{
                Id = 1234
                HasExited = $true
                ExitCode = 1
            }
            Chunk = $Chunk
            StartTime = [datetime]::Now
            LogPath = "TestDrive:\mock.log"
        }
    }
}
```

## Success Criteria

1. [ ] At least 6 of the 12 tests are enabled and passing
2. [ ] Tests properly handle Windows vs non-Windows platforms
3. [ ] Mocks are used appropriately for cross-platform compatibility
4. [ ] Tests validate the actual replication workflow logic
5. [ ] Tests clean up after themselves (no leftover temp files)
6. [ ] Tests can be run with: `Invoke-Pester -Path tests/Integration/`

## Testing Commands

```powershell
# Run integration tests
Invoke-Pester -Path tests/Integration/EndToEnd.Tests.ps1 -Output Detailed

# Run with tags if you add them
Invoke-Pester -Path tests/Integration/ -Tag "Mockable" -Output Detailed

# Run all tests
Invoke-Pester -Path tests/ -Output Detailed
```

## Estimated Complexity

Medium-High - Requires understanding the full replication flow and creating appropriate mocks.

## Dependencies

This task depends on Task 01 (Missing Chunking Functions) being completed first, as the replication flow uses those functions.
