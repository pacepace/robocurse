# Task: Hard Cap Enforcement (Fail-Fast)

## Process Requirements (EAD)

**TDD is mandatory**: Write tests FIRST, then implementation.

**Logging conventions**: Use `Write-RobocurseLog -Message "..." -Level 'Error|Warning|Info|Debug' -Component 'VSS'`

**Return values**: All functions return `OperationResult` via `New-OperationResult -Success $bool -Data $obj -ErrorMessage $msg`

**Mock patterns**: Follow existing tests in `tests/Unit/VssSnapshotCore.Tests.ps1` for mocking VSS functions.

---

## Objective

Before any snapshot creation, count ALL snapshots on the volume. If total exceeds `MaxTotalSnapshots`, fail immediately with Error-level logging and email notification.

## Success Criteria

1. New function `Test-SnapshotHardCap` checks total vs limit
2. Returns failure with clear "manual intervention required" message
3. Error-level logging
4. Email sent if configured (matching existing email style)
5. Called at start of `Invoke-LocalPersistentSnapshot` and `Invoke-RemotePersistentSnapshot`

## Research

- VssLocal.ps1:451-524 - `Get-VssSnapshots` returns all snapshots on volume
- VssRemote.ps1:200-280 - `Get-RemoteVssSnapshots` for remote
- JobManagement.ps1:275-316 - `Invoke-LocalPersistentSnapshot` entry point (add check after line 316)
- JobManagement.ps1:363-427 - `Invoke-RemotePersistentSnapshot` entry point
- Email.ps1:5-30 - `$script:EmailCssTemplate` and `$script:EmailStatusColors`
- Email.ps1:868-997 - `Send-MultipartEmail` pattern

## Test Plan (WRITE FIRST)

File: `tests/Unit/SnapshotSafetyHardCap.Tests.ps1`

```powershell
Describe 'Test-SnapshotHardCap' {
    BeforeAll {
        . "$PSScriptRoot\..\..\src\Robocurse\Public\VssCore.ps1"
        . "$PSScriptRoot\..\..\src\Robocurse\Public\VssLocal.ps1"
        . "$PSScriptRoot\..\..\src\Robocurse\Public\Logging.ps1"
    }

    Context 'When MaxTotalSnapshots is 0 (unlimited)' {
        It 'returns success without counting snapshots' {
            $config = New-DefaultConfig
            $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots = 0

            # Should NOT call Get-VssSnapshots when unlimited
            Mock Get-VssSnapshots { throw "Should not be called" }

            $result = Test-SnapshotHardCap -Volume 'D:' -Config $config
            $result.Success | Should -BeTrue
            $result.Data.Unlimited | Should -BeTrue
        }
    }

    Context 'When under the cap' {
        It 'returns success' {
            Mock Get-VssSnapshots {
                New-OperationResult -Success $true -Data @(
                    @{ ShadowId = 'a' }, @{ ShadowId = 'b' }
                )
            }

            $config = New-DefaultConfig
            $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots = 5

            $result = Test-SnapshotHardCap -Volume 'D:' -Config $config
            $result.Success | Should -BeTrue
            $result.Data.CurrentTotal | Should -Be 2
        }
    }

    Context 'When over the cap' {
        It 'returns failure with manual intervention message' {
            Mock Get-VssSnapshots {
                New-OperationResult -Success $true -Data @(
                    @{ ShadowId = 'a' }, @{ ShadowId = 'b' }, @{ ShadowId = 'c' },
                    @{ ShadowId = 'd' }, @{ ShadowId = 'e' }, @{ ShadowId = 'f' }
                )
            }
            Mock Write-RobocurseLog {}

            $config = New-DefaultConfig
            $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots = 5

            $result = Test-SnapshotHardCap -Volume 'D:' -Config $config
            $result.Success | Should -BeFalse
            $result.ErrorMessage | Should -Match 'Manual intervention required'
            $result.ErrorMessage | Should -Match 'vssadmin'
            $result.Data.RequiresManualIntervention | Should -BeTrue

            # Verify Error level logging
            Should -Invoke Write-RobocurseLog -ParameterFilter { $Level -eq 'Error' }
        }
    }

    Context 'When Get-VssSnapshots fails' {
        It 'fails safe with error' {
            Mock Get-VssSnapshots {
                New-OperationResult -Success $false -ErrorMessage "VSS unavailable"
            }

            $config = New-DefaultConfig
            $config.GlobalSettings.SnapshotRetention.MaxTotalSnapshots = 5

            $result = Test-SnapshotHardCap -Volume 'D:' -Config $config
            $result.Success | Should -BeFalse
        }
    }
}

Describe 'Send-SnapshotFailureEmail' {
    It 'does not send when email disabled' {
        $config = New-DefaultConfig
        $config.Email.Enabled = $false

        Mock Send-MultipartEmail { throw "Should not be called" }

        $result = Send-SnapshotFailureEmail -Config $config -Volume 'D:' -CurrentCount 10 -MaxCount 5
        $result.Success | Should -BeTrue
    }

    It 'sends with correct subject when email enabled' {
        $config = New-DefaultConfig
        $config.Email.Enabled = $true

        Mock Send-MultipartEmail { New-OperationResult -Success $true }

        Send-SnapshotFailureEmail -Config $config -Volume 'D:' -CurrentCount 10 -MaxCount 5

        Should -Invoke Send-MultipartEmail -ParameterFilter {
            $Subject -match 'SNAPSHOT LIMIT EXCEEDED'
        }
    }
}
```

## Implementation

### 1. Add Test-SnapshotHardCap function (VssCore.ps1)

```powershell
function Test-SnapshotHardCap {
    <#
    .SYNOPSIS
        Checks if total snapshots on volume exceed the hard cap
    .OUTPUTS
        OperationResult - Success=$true if OK, Success=$false if cap exceeded with Data containing details
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Volume,
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [switch]$IsRemote,
        [string]$ServerName,
        [PSCredential]$Credential
    )

    $maxTotal = Get-EffectiveMaxTotalSnapshots -Volume $Volume -Config $Config

    if ($maxTotal -eq 0) {
        Write-RobocurseLog -Message "MaxTotalSnapshots=0 (unlimited) for $Volume, skipping hard cap check" -Level 'Debug' -Component 'VSS'
        return New-OperationResult -Success $true -Data @{ Unlimited = $true }
    }

    # Count ALL snapshots on volume (not just ours)
    if ($IsRemote) {
        $listResult = Get-RemoteVssSnapshots -ServerName $ServerName -Volume $Volume -Credential $Credential
    } else {
        $listResult = Get-VssSnapshots -Volume $Volume
    }

    if (-not $listResult.Success) {
        $msg = "Cannot verify snapshot count for $Volume - failing safe: $($listResult.ErrorMessage)"
        Write-RobocurseLog -Message $msg -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage $msg
    }

    $totalCount = @($listResult.Data).Count

    if ($totalCount -gt $maxTotal) {
        $msg = "SNAPSHOT HARD CAP EXCEEDED: $Volume has $totalCount snapshots (max: $maxTotal). " +
               "Manual intervention required. Use 'vssadmin list shadows /for=$Volume' to view and " +
               "'vssadmin delete shadows /for=$Volume /oldest' to remove unwanted snapshots."
        Write-RobocurseLog -Message $msg -Level 'Error' -Component 'VSS'
        return New-OperationResult -Success $false -ErrorMessage $msg -Data @{
            Volume = $Volume
            CurrentTotal = $totalCount
            MaxTotal = $maxTotal
            RequiresManualIntervention = $true
        }
    }

    Write-RobocurseLog -Message "Hard cap check passed for $Volume`: $totalCount/$maxTotal snapshots" -Level 'Debug' -Component 'VSS'
    return New-OperationResult -Success $true -Data @{ CurrentTotal = $totalCount; MaxTotal = $maxTotal }
}
```

### 2. Add Send-SnapshotFailureEmail function (Email.ps1)

Uses existing `$script:EmailCssTemplate` and `$script:EmailStatusColors.Failed` for consistent styling. Follow `Send-CompletionEmail` pattern for HTML structure.

### 3. Update Invoke-LocalPersistentSnapshot (JobManagement.ps1:318, before retention)

```powershell
# HARD CAP CHECK - fail fast if too many total snapshots on volume
$hardCapResult = Test-SnapshotHardCap -Volume $volume -Config $Config
if (-not $hardCapResult.Success) {
    Send-SnapshotFailureEmail -Config $Config -Volume $volume `
        -CurrentCount $hardCapResult.Data.CurrentTotal `
        -MaxCount $hardCapResult.Data.MaxTotal | Out-Null
    return New-OperationResult -Success $false -ErrorMessage $hardCapResult.ErrorMessage
}
```

### 4. Update Invoke-RemotePersistentSnapshot similarly (JobManagement.ps1:430)

Same pattern with `-IsRemote` flag and server parameters.

## Files to Modify

- `src/Robocurse/Public/VssCore.ps1` - Add `Test-SnapshotHardCap`
- `src/Robocurse/Public/Email.ps1` - Add `Send-SnapshotFailureEmail`
- `src/Robocurse/Public/JobManagement.ps1` - Call hard cap check
- `tests/Unit/SnapshotSafetyHardCap.Tests.ps1` (new)

## Verification

```powershell
.\scripts\run-tests.ps1
powershell -NoProfile -Command 'Get-Content $env:TEMP\pester-summary.txt'
```
