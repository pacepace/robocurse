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

## Build Commands

```powershell
Invoke-Pester -Path tests -PassThru -Output Detailed
.\build\Build-Robocurse.ps1
```
