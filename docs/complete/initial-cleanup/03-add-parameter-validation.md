# Task 03: Add Parameter Validation to Critical Functions

## Priority: HIGH

## Problem Statement

Critical functions lack input validation, which can cause cryptic errors when malformed data is passed. For example:

```powershell
function Start-RobocopyJob {
    param([PSCustomObject]$Chunk, ...)

    # No validation that $Chunk has required properties!
    $argList = @("`"$($Chunk.SourcePath)`"", ...)  # Fails cryptically if SourcePath is null
```

## Research Required

### Code Research
1. Identify all public/critical functions in `Robocurse.ps1`:
   - `Start-RobocopyJob`
   - `Start-ReplicationRun`
   - `Get-DirectoryChunks`
   - `New-VssSnapshot`
   - `Send-CompletionEmail`
   - `Register-RobocurseTask`
   - And others that accept complex objects

2. For each function, identify:
   - Required parameters
   - Expected types
   - Valid value ranges
   - Required object properties

3. Review existing validation patterns in the codebase:
   - `Test-RobocurseConfig` already validates config structure
   - Use similar patterns for consistency

### PowerShell Validation Attributes Reference
```powershell
[ValidateNotNull()]
[ValidateNotNullOrEmpty()]
[ValidateRange(1, 100)]
[ValidateSet('Option1', 'Option2')]
[ValidateScript({ Test-Path $_ })]
[ValidatePattern('^[A-Z]:\\')]
```

## Functions Requiring Validation

### High Priority
1. **Start-RobocopyJob** - Validate Chunk has SourcePath, DestinationPath
2. **Start-ReplicationRun** - Validate Profiles array is not empty
3. **Get-DirectoryChunks** - Validate Path exists, MaxSizeBytes > 0
4. **New-VssSnapshot** - Validate SourcePath is local (not UNC)

### Medium Priority
5. **Send-CompletionEmail** - Validate Config has required email properties
6. **Register-RobocurseTask** - Validate ConfigPath exists
7. **Write-RobocurseLog** - Validate Message is not empty
8. **Save-RobocurseConfig** - Validate Config object structure

## Implementation Pattern

### For Simple Parameters
```powershell
function Start-RobocopyJob {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSCustomObject]$Chunk,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [ValidateRange(1, 128)]
        [int]$ThreadsPerJob = 8
    )

    # Additional validation for object properties
    if ([string]::IsNullOrWhiteSpace($Chunk.SourcePath)) {
        throw "Chunk.SourcePath is required"
    }
    if ([string]::IsNullOrWhiteSpace($Chunk.DestinationPath)) {
        throw "Chunk.DestinationPath is required"
    }
```

### For Complex Objects - Use ValidateScript
```powershell
function Start-ReplicationRun {
    param(
        [Parameter(Mandatory)]
        [ValidateScript({
            if ($_.Count -eq 0) {
                throw "At least one profile is required"
            }
            foreach ($p in $_) {
                if (-not $p.Name) { throw "Profile missing Name property" }
                if (-not $p.Source) { throw "Profile missing Source property" }
                if (-not $p.Destination) { throw "Profile missing Destination property" }
            }
            $true
        })]
        [PSCustomObject[]]$Profiles
    )
```

## Files to Modify

- `Robocurse.ps1` - Add validation to functions
- `tests/Unit/*.Tests.ps1` - Add tests for validation behavior

## Test Cases to Add

For each function with validation:
1. Test that valid input is accepted
2. Test that null/empty input throws appropriate error
3. Test that invalid ranges throw appropriate error
4. Test error message clarity

Example:
```powershell
Describe "Start-RobocopyJob Validation" {
    It "Should throw when Chunk is null" {
        { Start-RobocopyJob -Chunk $null -LogPath "test.log" } |
            Should -Throw "*Chunk*"
    }

    It "Should throw when Chunk.SourcePath is empty" {
        $badChunk = [PSCustomObject]@{
            SourcePath = ""
            DestinationPath = "D:\Test"
        }
        { Start-RobocopyJob -Chunk $badChunk -LogPath "test.log" } |
            Should -Throw "*SourcePath*"
    }
}
```

## Success Criteria

1. [ ] At least 6 critical functions have parameter validation added
2. [ ] Validation throws clear, actionable error messages
3. [ ] Validation uses PowerShell attributes where possible
4. [ ] Complex object validation uses ValidateScript or explicit checks
5. [ ] Tests verify validation behavior for each function
6. [ ] All existing tests still pass
7. [ ] Tests can be run with: `Invoke-Pester -Path tests/ -Output Detailed`

## Testing Commands

```powershell
# Run all unit tests
Invoke-Pester -Path tests/Unit/ -Output Detailed

# Run specific test file
Invoke-Pester -Path tests/Unit/RobocopyWrapper.Tests.ps1 -Output Detailed
```

## Estimated Complexity

Medium - Straightforward additions but requires touching many functions.
