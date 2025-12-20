#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Enables or disables PowerShell Remoting (WinRM).

.DESCRIPTION
    Configures PowerShell Remoting with optional IP address restrictions.
    When enabling with -AllowedIPs, firewall rules are scoped to those addresses only.

.PARAMETER Enable
    Enable PowerShell Remoting and start WinRM service.

.PARAMETER Disable
    Disable PowerShell Remoting and stop WinRM service.

.PARAMETER AllowedIPs
    IP addresses or subnets allowed to connect (e.g., "192.168.1.100", "10.0.0.0/24").
    Only used with -Enable. If omitted, allows any IP.

.PARAMETER Status
    Show current WinRM status without making changes.

.EXAMPLE
    .\Set-PsRemoting.ps1 -Enable

.EXAMPLE
    .\Set-PsRemoting.ps1 -Enable -AllowedIPs "192.168.1.100"

.EXAMPLE
    .\Set-PsRemoting.ps1 -Enable -AllowedIPs "192.168.1.100","10.0.0.0/24"

.EXAMPLE
    .\Set-PsRemoting.ps1 -Disable

.EXAMPLE
    .\Set-PsRemoting.ps1 -Status
#>
[CmdletBinding()]
param(
    [switch]$Enable,
    [switch]$Disable,
    [string[]]$AllowedIPs,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'

$customRuleName = 'Robocurse-WinRM-HTTP'

function Get-RemotingStatus {
    Write-Host "`nPowerShell Remoting Status:" -ForegroundColor Cyan

    # WinRM service
    $svc = Get-Service -Name WinRM -ErrorAction SilentlyContinue
    if ($svc) {
        $startType = (Get-WmiObject Win32_Service -Filter "Name='WinRM'").StartMode
        Write-Host "  WinRM Service: $($svc.Status) ($startType)"
    } else {
        Write-Host "  WinRM Service: NOT FOUND" -ForegroundColor Red
        return
    }

    # Listener
    $listener = Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue |
        Where-Object { $_.Keys -contains 'Transport=HTTP' }
    if ($listener) {
        Write-Host "  HTTP Listener: Configured" -ForegroundColor Green
    } else {
        Write-Host "  HTTP Listener: Not configured" -ForegroundColor Yellow
    }

    # Firewall rules
    $customRule = Get-NetFirewallRule -Name $customRuleName -ErrorAction SilentlyContinue
    $defaultRules = Get-NetFirewallRule -DisplayGroup "Windows Remote Management" -ErrorAction SilentlyContinue |
        Where-Object { $_.Enabled -eq $true }

    if ($customRule) {
        $filter = $customRule | Get-NetFirewallAddressFilter
        Write-Host "  Firewall: Custom rule active" -ForegroundColor Green
        if ($filter.RemoteAddress -and $filter.RemoteAddress -ne 'Any') {
            Write-Host "  Allowed IPs: $($filter.RemoteAddress -join ', ')" -ForegroundColor Cyan
        } else {
            Write-Host "  Allowed IPs: Any" -ForegroundColor Yellow
        }
    } elseif ($defaultRules) {
        Write-Host "  Firewall: Default WinRM rules enabled" -ForegroundColor Green
        Write-Host "  Allowed IPs: Any (default rules)" -ForegroundColor Yellow
    } else {
        Write-Host "  Firewall: No WinRM rules enabled" -ForegroundColor Yellow
    }

    # Overall status
    if ($svc.Status -eq 'Running' -and ($listener -or $customRule -or $defaultRules)) {
        Write-Host "`n  PS Remoting: ENABLED" -ForegroundColor Green
    } else {
        Write-Host "`n  PS Remoting: DISABLED" -ForegroundColor Yellow
    }
}

if (-not $Enable -and -not $Disable -and -not $Status) {
    Write-Host "Specify -Enable, -Disable, or -Status" -ForegroundColor Red
    Get-RemotingStatus
    exit 1
}

if ($Enable -and $Disable) {
    throw "Cannot specify both -Enable and -Disable"
}

if ($AllowedIPs -and -not $Enable) {
    throw "-AllowedIPs can only be used with -Enable"
}

if ($Status) {
    Get-RemotingStatus
    exit 0
}

if ($Enable) {
    Write-Host "Enabling PowerShell Remoting..." -ForegroundColor Cyan

    # Enable PS Remoting (creates listener, starts service, sets startup type)
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Write-Host "  PSRemoting enabled" -ForegroundColor Green

    # Handle firewall rules
    if ($AllowedIPs) {
        Write-Host "  Configuring IP restrictions..." -ForegroundColor Cyan

        # Disable default WinRM rules
        $defaultRules = Get-NetFirewallRule -DisplayGroup "Windows Remote Management" -ErrorAction SilentlyContinue
        foreach ($rule in $defaultRules) {
            Set-NetFirewallRule -Name $rule.Name -Enabled False
        }
        Write-Host "  Disabled default WinRM firewall rules" -ForegroundColor Cyan

        # Remove existing custom rule if present
        $existing = Get-NetFirewallRule -Name $customRuleName -ErrorAction SilentlyContinue
        if ($existing) {
            Remove-NetFirewallRule -Name $customRuleName
        }

        # Create custom rule with IP restrictions
        New-NetFirewallRule -Name $customRuleName `
            -DisplayName "WinRM HTTP (Robocurse - Restricted)" `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort 5985 `
            -Action Allow `
            -Profile Any `
            -RemoteAddress $AllowedIPs `
            -Description "Created by Robocurse Set-PsRemoting.ps1" | Out-Null

        Write-Host "  Created firewall rule for: $($AllowedIPs -join ', ')" -ForegroundColor Green
    } else {
        # Remove custom rule if it exists, re-enable defaults
        $existing = Get-NetFirewallRule -Name $customRuleName -ErrorAction SilentlyContinue
        if ($existing) {
            Remove-NetFirewallRule -Name $customRuleName
            Write-Host "  Removed custom IP-restricted rule" -ForegroundColor Cyan
        }

        # Re-enable default rules
        $defaultRules = Get-NetFirewallRule -DisplayGroup "Windows Remote Management" -ErrorAction SilentlyContinue
        foreach ($rule in $defaultRules) {
            Set-NetFirewallRule -Name $rule.Name -Enabled True
        }
        Write-Host "  Using default WinRM firewall rules (any IP)" -ForegroundColor Yellow
    }

    Write-Host "`nPowerShell Remoting enabled" -ForegroundColor Green
    Get-RemotingStatus
}

if ($Disable) {
    Write-Host "Disabling PowerShell Remoting..." -ForegroundColor Cyan

    # Remove custom firewall rule
    $existing = Get-NetFirewallRule -Name $customRuleName -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-NetFirewallRule -Name $customRuleName
        Write-Host "  Removed custom firewall rule" -ForegroundColor Cyan
    }

    # Disable default WinRM firewall rules
    $defaultRules = Get-NetFirewallRule -DisplayGroup "Windows Remote Management" -ErrorAction SilentlyContinue
    foreach ($rule in $defaultRules) {
        Set-NetFirewallRule -Name $rule.Name -Enabled False
    }
    Write-Host "  Disabled WinRM firewall rules" -ForegroundColor Cyan

    # Stop and disable WinRM service
    $svc = Get-Service -Name WinRM
    if ($svc.Status -eq 'Running') {
        Stop-Service -Name WinRM -Force
    }
    Set-Service -Name WinRM -StartupType Disabled
    Write-Host "  Stopped and disabled WinRM service" -ForegroundColor Green

    # Disable PSRemoting config
    Disable-PSRemoting -Force -WarningAction SilentlyContinue | Out-Null
    Write-Host "  Disabled PSRemoting configuration" -ForegroundColor Green

    Write-Host "`nPowerShell Remoting disabled" -ForegroundColor Green
    Get-RemotingStatus
}
