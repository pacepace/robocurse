# Robocurse Development Notes

## PowerShell Runspace Object Passing

PSCustomObject NoteProperties DO survive `AddArgument()`. However, for cleaner code, the background runspace re-reads profiles from config file by name:

```powershell
# Pass profile names (strings), not objects
$profileNames = @($profilesToRun | ForEach-Object { $_.Name })
$powershell.AddArgument($profileNames)

# In background - look up from fresh config
$bgConfig = Get-RobocurseConfig -Path $ConfigPath
$profiles = @($bgConfig.SyncProfiles | Where-Object { $ProfileNames -contains $_.Name })
```

For mutable shared state (progress updates), use C# class with locking - see `OrchestrationState` in Orchestration.ps1.

## Robocopy /L List Mode

For directory profiling, use a random temp path as destination (not `\\?\NULL` which doesn't work on all Windows versions, and not src=dest which doesn't list files):

```powershell
$nullDest = Join-Path $env:TEMP "robocurse-null-$(Get-Random)"
$output = & robocopy $Source $nullDest /L /E /NJH /NJS /BYTES /R:0 /W:0 2>&1
```

Output format is `New File [size] [name]` and `New Dir [count] [path]` - parse accordingly.

## Build Commands

```powershell
Invoke-Pester -Path tests -PassThru -Output Detailed
.\build\Build-Robocurse.ps1
```
