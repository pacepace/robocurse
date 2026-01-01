# Task: Drive Cleanup on Stop

## Objective
Add network drive mapping cleanup to the `Stop-AllJobs` function so that when a user stops a running job, the mapped drives are properly unmapped.

## Problem Statement
Currently, `Stop-AllJobs` (JobManagement.ps1:1581-1676) cleans up:
- Running robocopy processes (killed)
- Remote VSS junctions (removed)
- VSS snapshots (deleted)

But it does NOT clean up network drive mappings. These remain after stopping, consuming drive letters and potentially causing issues on the next run.

## Success Criteria
1. `Stop-AllJobs` dismounts network drives after VSS cleanup
2. State references are cleared (`CurrentNetworkMappings`, `NetworkMappedSource`, `NetworkMappedDest`)
3. Cleanup happens even if VSS cleanup fails
4. All tests pass

## Research: Current Implementation

### Stop-AllJobs (JobManagement.ps1:1581-1676)
```powershell
function Stop-AllJobs {
    $state = $script:OrchestrationState

    # 1. Kill running processes (lines 1594-1611)
    foreach ($job in $state.ActiveJobs.Values) {
        $job.Process.Kill()
    }
    $state.ActiveJobs.Clear()
    $state.Phase = "Stopped"

    # 2. Clean up remote VSS junction (lines 1616-1634)
    if ($state.CurrentVssJunction) {
        Remove-RemoteVssJunction ...
        $state.CurrentVssJunction = $null
    }

    # 3. Clean up VSS snapshot (lines 1636-1669)
    if ($state.CurrentVssSnapshot) {
        if ($state.CurrentVssSnapshot.IsRemote) {
            Remove-RemoteVssSnapshot ...
        } else {
            Remove-VssSnapshot ...
        }
        $state.CurrentVssSnapshot = $null
    }

    # 4. MISSING: Network mapping cleanup
    # $state.CurrentNetworkMappings is NOT cleaned up here!

    Write-SiemEvent ...
}
```

### Complete-CurrentProfile (JobManagement.ps1:1527-1535)
This is where network cleanup currently happens (but only on normal completion):
```powershell
# Clean up network mappings
if ($state.CurrentNetworkMappings -and $state.CurrentNetworkMappings.Count -gt 0) {
    Write-RobocurseLog -Message "Cleaning up network mappings" -Level 'Debug' -Component 'NetworkMapping'
    Dismount-NetworkPaths -Mappings $state.CurrentNetworkMappings
    $state.CurrentNetworkMappings = $null
    $state.NetworkMappedSource = $null
    $state.NetworkMappedDest = $null
}
$state.NetworkCredential = $null
```

## Implementation Plan

### Step 1: Add Network Cleanup to Stop-AllJobs
After the VSS snapshot cleanup block (after line 1669), add:

```powershell
    # Clean up network drive mappings
    if ($state.CurrentNetworkMappings -and $state.CurrentNetworkMappings.Count -gt 0) {
        Write-RobocurseLog -Message "Cleaning up network mappings after stop ($($state.CurrentNetworkMappings.Count) mapping(s))" `
            -Level 'Info' -Component 'NetworkMapping'
        try {
            Dismount-NetworkPaths -Mappings $state.CurrentNetworkMappings
        }
        catch {
            Write-RobocurseLog -Message "Failed to cleanup network mappings: $($_.Exception.Message)" `
                -Level 'Warning' -Component 'NetworkMapping'
        }
        finally {
            $state.CurrentNetworkMappings = $null
            $state.NetworkMappedSource = $null
            $state.NetworkMappedDest = $null
        }
    }
    $state.NetworkCredential = $null
```

## Test Plan

Add to `tests/Unit/JobManagement.Tests.ps1` (or create new test context):

```powershell
Context "Stop-AllJobs Network Cleanup" {
    BeforeAll {
        # Mock network functions
        Mock Dismount-NetworkPaths { } -ModuleName Robocurse
        Mock Write-RobocurseLog { } -ModuleName Robocurse
        Mock Write-SiemEvent { } -ModuleName Robocurse
    }

    BeforeEach {
        # Initialize state with mock network mappings
        Initialize-OrchestrationState
        $script:OrchestrationState.CurrentNetworkMappings = @(
            [PSCustomObject]@{ DriveLetter = "Y:"; Root = "\\server\share" }
        )
        $script:OrchestrationState.NetworkMappedSource = "Y:\folder"
        $script:OrchestrationState.NetworkMappedDest = "D:\backup"
    }

    It "Should dismount network paths when stopping" {
        Stop-AllJobs

        Should -Invoke Dismount-NetworkPaths -Times 1 -ModuleName Robocurse
    }

    It "Should clear network state references after stop" {
        Stop-AllJobs

        $script:OrchestrationState.CurrentNetworkMappings | Should -BeNullOrEmpty
        $script:OrchestrationState.NetworkMappedSource | Should -BeNullOrEmpty
        $script:OrchestrationState.NetworkMappedDest | Should -BeNullOrEmpty
        $script:OrchestrationState.NetworkCredential | Should -BeNullOrEmpty
    }

    It "Should clear state even if dismount fails" {
        Mock Dismount-NetworkPaths { throw "Network error" } -ModuleName Robocurse

        { Stop-AllJobs } | Should -Not -Throw

        $script:OrchestrationState.CurrentNetworkMappings | Should -BeNullOrEmpty
    }

    It "Should not call dismount if no mappings exist" {
        $script:OrchestrationState.CurrentNetworkMappings = $null

        Stop-AllJobs

        Should -Invoke Dismount-NetworkPaths -Times 0 -ModuleName Robocurse
    }
}
```

## Files to Modify
1. `src/Robocurse/Public/JobManagement.ps1` - Add network cleanup to Stop-AllJobs (~line 1670)

## Verification Commands
```powershell
# Run tests
.\scripts\run-tests.ps1

# Manual test
# 1. Configure a profile with UNC source (\\server\share)
# 2. Start replication
# 3. Verify drive mapped (net use)
# 4. Stop the job
# 5. Verify drive unmapped (net use)
```

## Notes
- Cleanup uses try/finally to ensure state is cleared even if dismount fails
- Matches the pattern used in Complete-CurrentProfile
- Credential is cleared last (may be needed for remote VSS cleanup)
