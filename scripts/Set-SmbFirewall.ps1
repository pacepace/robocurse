#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Blocks or allows SMB ports 139 and 445 in Windows Firewall.

.DESCRIPTION
    Creates or removes firewall rules to block inbound traffic on ports 139 and 445.
    Use -Block to deny SMB access, -Allow to permit it.

.PARAMETER Block
    Create firewall rules blocking ports 139 and 445.

.PARAMETER Allow
    Remove the blocking rules (allows SMB traffic).

.PARAMETER Status
    Show current firewall rule status without making changes.

.EXAMPLE
    .\Set-SmbFirewall.ps1 -Block

.EXAMPLE
    .\Set-SmbFirewall.ps1 -Allow

.EXAMPLE
    .\Set-SmbFirewall.ps1 -Status
#>
[CmdletBinding()]
param(
    [switch]$Block,
    [switch]$Allow,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'

$rules = @(
    @{
        Name = 'Robocurse-Block-SMB-139'
        DisplayName = 'Block SMB NetBIOS (139)'
        Port = 139
    },
    @{
        Name = 'Robocurse-Block-SMB-445'
        DisplayName = 'Block SMB Direct (445)'
        Port = 445
    }
)

function Get-FirewallStatus {
    Write-Host "`nSMB Firewall Rules Status:" -ForegroundColor Cyan

    $allBlocked = $true
    foreach ($rule in $rules) {
        $existing = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "  $($rule.DisplayName): BLOCKED" -ForegroundColor Yellow
        } else {
            Write-Host "  $($rule.DisplayName): ALLOWED (no block rule)" -ForegroundColor Green
            $allBlocked = $false
        }
    }

    if ($allBlocked) {
        Write-Host "`n  SMB Access: BLOCKED" -ForegroundColor Yellow
    } else {
        Write-Host "`n  SMB Access: ALLOWED" -ForegroundColor Green
    }
}

if (-not $Block -and -not $Allow -and -not $Status) {
    Write-Host "Specify -Block, -Allow, or -Status" -ForegroundColor Red
    Get-FirewallStatus
    exit 1
}

if ($Block -and $Allow) {
    throw "Cannot specify both -Block and -Allow"
}

if ($Status) {
    Get-FirewallStatus
    exit 0
}

if ($Block) {
    Write-Host "Blocking SMB ports 139 and 445..." -ForegroundColor Cyan

    foreach ($rule in $rules) {
        $existing = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue

        if ($existing) {
            Write-Host "  $($rule.DisplayName) rule already exists" -ForegroundColor Cyan
        } else {
            New-NetFirewallRule -Name $rule.Name `
                -DisplayName $rule.DisplayName `
                -Direction Inbound `
                -Protocol TCP `
                -LocalPort $rule.Port `
                -Action Block `
                -Profile Any `
                -Description "Created by Robocurse Set-SmbFirewall.ps1" | Out-Null

            Write-Host "  Created: $($rule.DisplayName)" -ForegroundColor Green
        }
    }

    Write-Host "`nSMB ports blocked" -ForegroundColor Green
    Get-FirewallStatus
}

if ($Allow) {
    Write-Host "Removing SMB block rules..." -ForegroundColor Cyan

    foreach ($rule in $rules) {
        $existing = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue

        if ($existing) {
            Remove-NetFirewallRule -Name $rule.Name
            Write-Host "  Removed: $($rule.DisplayName)" -ForegroundColor Green
        } else {
            Write-Host "  $($rule.DisplayName) rule not found (already allowed)" -ForegroundColor Cyan
        }
    }

    Write-Host "`nSMB block rules removed" -ForegroundColor Green
    Get-FirewallStatus
}
