# Robocurse Development Notes

## EAD (Enforcement-Accelerated Development)

**Three Pillars:**
1. **Context Sharding** - ~500 LOC per task, fits in one AI context window
2. **Enforcement Tests** - AST-based, verify patterns not behavior, <15s, catch drift early
3. **Evidence-Based Debugging** - Logs have file:line:function. No guessing.

**Task Files** (`docs/` subdirectories):
- Self-contained, subagent finishes without questions
- Name = WHAT it does (`ChunkErrorTooltip` not `Phase1Task1`)
- TDD: test code in task, written first
- Sections: Objective, Success Criteria, Research (file:line refs), Implementation, Test Plan, Files to Modify, Verification

**Enforcement Test Pattern:**
```powershell
$ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
$violations = $ast.FindAll({ param($node) <# pattern check #> }, $true)
```

## Troubleshooting

**No speculation. Evidence only.**

1. Reproduce it
2. Check logs (`Write-RobocurseLog` with `-Level` and `-Component`)
3. Find file:line
4. Fix it

**Logs unclear? Add better logging, not guesses.**

Log locations:
- GUI: `LogPath` from config (default `.\Logs`)
- Tests: `$env:TEMP\pester-failures.txt`

## Build & Test

```powershell
.\scripts\run-tests.ps1                    # USE THIS - avoids truncation
Invoke-Pester -Path tests\Unit\Configuration.Tests.ps1 -Output Detailed
Invoke-Pester -Path tests\Unit -Output Detailed
Invoke-Pester -Path tests -CodeCoverage src\Robocurse\Public\*.ps1
$r = Invoke-Pester -Path tests -PassThru -Output None; $r.Skipped.ExpandedPath
.\build\Build-Robocurse.ps1
```

**Use `.\scripts\run-tests.ps1`** - writes to temp files, avoids truncation that causes infinite retry loops.

Output files:
- `$env:TEMP\pester-summary.txt` - pass/fail counts
- `$env:TEMP\pester-failures.txt` - failed test names and errors

**Reading test results from bash** (use single quotes so PowerShell expands $env:TEMP):
```bash
powershell -NoProfile -Command 'Get-Content "$env:TEMP\pester-summary.txt"; Get-Content "$env:TEMP\pester-failures.txt"'
```

**Skipped tests:**
- Remote VSS tests need `$env:ROBOCURSE_TEST_REMOTE_SHARE` set to UNC path
- Platform-specific tests skip on non-Windows (scheduling, VSS, robocopy)

## PowerShell Runspace Object Passing

PSCustomObject NoteProperties survive `AddArgument()`. For cleaner code, background runspace re-reads profiles by name:

```powershell
# Pass names, not objects
$profileNames = @($profilesToRun | ForEach-Object { $_.Name })
$powershell.AddArgument($profileNames)

# In background - look up from fresh config
$bgConfig = Get-RobocurseConfig -Path $ConfigPath
$profiles = @($bgConfig.SyncProfiles | Where-Object { $ProfileNames -contains $_.Name })
```

For mutable shared state (progress updates), use C# class with locking. See `OrchestrationState` in Orchestration.ps1.

## Robocopy /L List Mode

Use random temp path as destination. `\\?\NULL` breaks on some Windows. src=dest doesn't list files.

```powershell
$nullDest = Join-Path $env:TEMP "robocurse-null-$(Get-Random)"
$output = & robocopy $Source $nullDest /L /E /NJH /NJS /BYTES /R:0 /W:0 2>&1
```

Output format: `New File [size] [name]` and `New Dir [count] [path]`

## VSS Retry Logic

Local and remote VSS use same retry pattern. See `Test-VssErrorRetryable` in VssCore.ps1.

**Retryable HRESULT codes:**
- `0x8004230F` - VSS_E_INSUFFICIENT_STORAGE
- `0x80042316` - VSS_E_SNAPSHOT_SET_IN_PROGRESS
- `0x80042302` - VSS_E_OBJECT_NOT_FOUND
- `0x80042317` - VSS_E_MAXIMUM_NUMBER_OF_VOLUMES_REACHED
- `0x8004231F` - VSS_E_WRITERERROR_TIMEOUT
- `0x80042325` - VSS_E_FLUSH_WRITES_TIMEOUT

**Fallback patterns** (errors without HRESULT): `busy`, `timeout`, `lock`, `in use`, `try again`

## Scheduled Tasks and Network Shares

**S4U vs Password Logon:**
- Default: `LogonType S4U` - runs without password but **cannot access network shares**
- With credential: `LogonType Password` - has network credentials for `\\server\share` access

When creating scheduled tasks for profiles with network paths:
- GUI prompts for credentials automatically when Source or Destination starts with `\\`
- CLI `-SetProfileSchedule` prompts via `Get-Credential` for network paths
- `New-ProfileScheduledTask -Credential $cred` uses Password logon

**Pre-flight failures:**
- If source path is inaccessible, profile `Status` = `'Failed'` with `PreflightError` property
- Email status = `'Failed'` when any profile has pre-flight error (not just chunk failures)
- GUI completion dialog shows red failure state with pre-flight error details

## Security

DEBUG logs contain full paths (project names, robocopy commands, VSS junctions). Keep secure or redact in production. SIEM logs (JSON Lines) have structured path data.
